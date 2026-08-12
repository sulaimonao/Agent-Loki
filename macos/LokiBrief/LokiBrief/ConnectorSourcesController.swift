import Foundation

enum ConnectorSourcesFailure: String, Error, LocalizedError, Sendable {
    case statusUnavailable = "connector_status_unavailable"
    case configurationUnavailable = "connector_configuration_unavailable"
    case unsupportedEmailFormat = "email_import_format_unsupported"
    case fileAuthorizationFailed = "email_file_authorization_failed"
    case fileUnavailable = "email_file_unavailable"
    case fileTooLarge = "email_source_too_large"
    case persistenceFailed = "connector_control_persistence_failed"
    case operationInProgress = "connector_operation_in_progress"
    case connectorAlreadyConfigured = "connector_already_configured"

    var errorDescription: String? {
        switch self {
        case .statusUnavailable: "The connector status is unavailable."
        case .configurationUnavailable: "The connector configuration is unavailable or invalid."
        case .unsupportedEmailFormat: "Choose an RFC 5322 .eml file or an .mbox mailbox."
        case .fileAuthorizationFailed: "Loki Brief could not retain read-only access to the selected file."
        case .fileUnavailable: "The selected email source is unavailable."
        case .fileTooLarge: "The selected email source exceeds the local import size limit."
        case .persistenceFailed: "The connector control state could not be saved safely."
        case .operationInProgress: "Another connector operation is already running."
        case .connectorAlreadyConfigured: "Disconnect the existing credential before replacing this connector authorization."
        }
    }
}

enum EmailFileAccessState: String, Sendable {
    case available
    case removed
    case unavailable
}

enum EmailVaultStoredMetadata {
    static let metadataKey = "email_preserved_metadata_json"

    static func reconstruct(from record: VaultRecord) throws
        -> EmailPreservedMetadata
    {
        guard let encoded = record.metadata[metadataKey]?.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                EmailPreservedMetadata.self,
                from: encoded
              ),
              record.metadata["email_raw_message_sha256"]
                == value.rawMessageSHA256,
              record.metadata["email_mailbox_id_sha256"]
                == value.mailboxIdentifierHash,
              record.metadata["email_import_source_id_sha256"]
                == value.importSourceIdentifierHash
        else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
        return value
    }
}

struct StoredDiscordConnectorConfiguration: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let applicationID: String
    let botUserID: String
    let guildIDs: [String]
    let channelIDs: [String]
    let threadIDs: [String]
    let messageContentAccess: DiscordMessageContentAccess
    let selections: [DiscordSourceSelection]
    let reconciliationState: DiscordReconciliationState
    let checkpointIdentifier: String

    init(
        authority: DiscordConnectorAuthority,
        selections: [DiscordSourceSelection] = [],
        reconciliationState: DiscordReconciliationState = .init(),
        checkpointIdentifier: String? = nil
    ) {
        schemaVersion = 1
        applicationID = authority.applicationID
        botUserID = authority.botUserID
        guildIDs = authority.guildAllowlist.sorted()
        channelIDs = authority.channelAllowlist.sorted()
        threadIDs = authority.threadAllowlist.sorted()
        messageContentAccess = authority.messageContentAccess
        self.selections = selections.sorted { $0.id < $1.id }
        self.reconciliationState = reconciliationState
        self.checkpointIdentifier = checkpointIdentifier
            ?? "discord-sync:\(authority.accountIdentifier)"
    }

    func authority() throws -> DiscordConnectorAuthority {
        guard schemaVersion == 1 else {
            throw ConnectorSourcesFailure.configurationUnavailable
        }
        return try .init(
            applicationID: applicationID,
            botUserID: botUserID,
            guildAllowlist: Set(guildIDs),
            channelAllowlist: Set(channelIDs),
            threadAllowlist: Set(threadIDs),
            messageContentAccess: messageContentAccess
        )
    }
}

struct StoredEmailConnectorConfiguration: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let source: EmailImportSource
    let checkpoint: EmailImportCheckpoint?
}

private struct EmailConnectorRunReceiptMaterial: Codable, Sendable {
    let schemaVersion: Int
    let sourceIdentifierHash: String
    let pageReceipts: [EmailImportReceipt]
    let checkpoint: EmailImportCheckpoint
    let insertedItemCount: Int
    let updatedItemCount: Int
    let skippedItemCount: Int
    let attachmentCount: Int
}

@MainActor
final class ConnectorSourcesController: ObservableObject {
    @Published private(set) var statuses: [ConnectorStatusSnapshot] = []
    @Published private(set) var discordDiscoveryByStatusID:
        [String: DiscordDiscoveryResult] = [:]
    @Published private(set) var activeStatusIdentifiers: Set<String> = []
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    private(set) var wholeAppDeletionInProgress = false

    let store: LocalStore
    let vaultController: VaultController
    let attachedDataSourcesController: AttachedDataSourcesController
    private let discordController: DiscordConnectorController
    private let emailController: EmailImportController
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var hasUpdateBlockingWork: Bool {
        !activeStatusIdentifiers.isEmpty
            || attachedDataSourcesController.hasUpdateBlockingWork
    }

    init(store: LocalStore, vaultController: VaultController) {
        self.store = store
        self.vaultController = vaultController
        attachedDataSourcesController = AttachedDataSourcesController(
            store: store,
            vaultController: vaultController
        )
        discordController = DiscordConnectorController()
        emailController = EmailImportController()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        reload(reportFailure: false)
        reconcilePersistedRuntimeStates()
    }

    func status(id: String) -> ConnectorStatusSnapshot? {
        statuses.first { $0.id == id }
    }

    func discordConfigurationExists(statusID: String) -> Bool {
        (try? discordConfiguration(statusID: statusID)) != nil
    }

    func discordSelections(statusID: String) -> [DiscordSourceSelection] {
        (try? discordConfiguration(statusID: statusID).selections) ?? []
    }

    func emailAccessState(statusID: String) -> EmailFileAccessState {
        do {
            return try store.emailImportAccess(id: statusID) == nil
                ? .removed : .available
        } catch {
            return .unavailable
        }
    }

    func emailAccessAvailable(statusID: String) -> Bool {
        emailAccessState(statusID: statusID) == .available
    }

    func reportEmailFilePickerFailure() {
        present(ConnectorSourcesFailure.fileAuthorizationFailed)
    }

    func connectDiscord(
        displayName: String,
        applicationID: String,
        botUserID: String,
        token: String,
        guildIDs: Set<String>,
        messageContentEnabled: Bool
    ) async -> Bool {
        let temporaryID = "discord-connection"
        guard begin(temporaryID) else { return false }
        defer { end(temporaryID) }
        var persistedStatusID: String?
        do {
            let authority = try DiscordConnectorAuthority(
                applicationID: applicationID,
                botUserID: botUserID,
                guildAllowlist: guildIDs,
                channelAllowlist: [],
                messageContentAccess: messageContentEnabled
                    ? .enabled : .limitedByPrivilegedIntent
            )
            let credential = try DiscordBotCredential(
                applicationID: applicationID,
                botUserID: botUserID,
                token: token
            )
            let statusID = "discord:\(authority.accountIdentifier)"
            persistedStatusID = statusID
            let configuration = StoredDiscordConnectorConfiguration(
                authority: authority
            )
            let configurationData = try encoder.encode(configuration)
            let existing = try store.connectorStatus(id: statusID)
            guard existing?.credentialReference == nil else {
                throw ConnectorSourcesFailure.connectorAlreadyConfigured
            }
            var snapshot = existing ?? ConnectorStatusSnapshot(
                id: statusID,
                kind: .discord,
                stableAccountIdentifier: authority.accountIdentifier,
                displayName: "Discord",
                privacyClassification: .localSelectedSource
            )
            snapshot.displayName = boundedDisplayName(
                displayName,
                fallback: "Discord"
            )
            snapshot.state = .connecting
            if existing == nil { snapshot.cursorData = configurationData }
            snapshot.lastAttemptedSync = .now
            snapshot.lastErrorReasonCode = nil
            snapshot.retryAfter = nil
            snapshot.updatedAt = .now
            try store.saveConnectorStatus(snapshot)
            reload()
            let connected = try await discordController.connect(
                credential: credential,
                authority: authority
            )
            snapshot.state = connected.state.connectorState
            snapshot.credentialReference = connected.credentialReference
            snapshot.selectedSourceIdentifiers = []
            snapshot.cursorData = configurationData
            snapshot.lastAttemptedSync = connected.lastAttemptedAt
            snapshot.lastSuccessfulSync = connected.lastSuccessfulSyncAt
            snapshot.lastErrorReasonCode = connected.latestReasonCode
            snapshot.retryAfter = connected.rateLimitState?.retryAt
            snapshot.updatedAt = .now
            try store.saveConnectorStatus(snapshot)
            reload()
            statusMessage = connected.state == .degraded
                ? "Discord connected with limited Message Content access."
                : "Discord connected. Choose explicit channels before syncing."
            errorMessage = nil
            return true
        } catch {
            if let persistedStatusID {
                await recordFailure(error, statusID: persistedStatusID)
            } else {
                present(error)
            }
            return false
        }
    }

    func resumeDiscord(statusID: String) async -> Bool {
        guard begin(statusID) else { return false }
        defer { end(statusID) }
        do {
            var status = try requiredStatus(statusID)
            let configuration = try discordConfiguration(statusID: statusID)
            let snapshot = try await discordController.resume(
                authority: configuration.authority()
            )
            status.state = snapshot.state.connectorState
            status.credentialReference = snapshot.credentialReference
            status.lastAttemptedSync = snapshot.lastAttemptedAt
            status.lastErrorReasonCode = snapshot.latestReasonCode
            status.retryAfter = snapshot.rateLimitState?.retryAt
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Discord authorization was revalidated."
            errorMessage = nil
            return true
        } catch {
            await recordFailure(error, statusID: statusID)
            return false
        }
    }

    func discoverDiscord(statusID: String) async -> Bool {
        guard begin(statusID) else { return false }
        defer { end(statusID) }
        do {
            var status = try requiredStatus(statusID)
            let configuration = try discordConfiguration(statusID: statusID)
            let authority = try configuration.authority()
            status.state = .connecting
            status.lastAttemptedSync = .now
            try store.saveConnectorStatus(status)
            reload()
            _ = try await discordController.resume(authority: authority)
            let discovery = try await discordController.discoverSources(
                authority: authority
            )
            discordDiscoveryByStatusID[statusID] = discovery
            status.state = discovery.isComplete
                && discovery.messageContentAccess == .enabled
                ? .connected : .degraded
            status.lastErrorReasonCode = discovery.isComplete
                && discovery.messageContentAccess == .enabled
                ? nil : discovery.reasonCode
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Discord source discovery completed. Select channels or threads before syncing."
            errorMessage = nil
            return true
        } catch {
            await recordFailure(error, statusID: statusID)
            return false
        }
    }

    func saveDiscordSelection(
        statusID: String,
        selectedChannelIDs: Set<String>,
        selectedThreadIDs: Set<String>
    ) -> Bool {
        do {
            var status = try requiredStatus(statusID)
            let current = try discordConfiguration(statusID: statusID)
            let discovery = try requiredDiscordDiscovery(statusID)
            let selectedChannels = discovery.channels.filter {
                selectedChannelIDs.contains($0.id)
                    && $0.permitsDirectHistorySelection
            }
            let selectedThreads = discovery.threads.filter {
                selectedThreadIDs.contains($0.id)
            }
            var selections = try selectedChannels.map {
                try DiscordSourceSelection(
                    guildID: $0.guildID,
                    channelID: $0.id,
                    parentChannelType: $0.type
                )
            }
            selections += try selectedThreads.map { thread in
                guard let parentID = thread.parentChannelID,
                      let parent = discovery.channels.first(where: {
                          $0.id == parentID && $0.guildID == thread.guildID
                      })
                else {
                    throw ConnectorSourcesFailure.configurationUnavailable
                }
                return try DiscordSourceSelection(
                    guildID: thread.guildID,
                    channelID: parentID,
                    threadID: thread.id,
                    parentChannelType: parent.type
                )
            }
            let channelAllowlist = Set(selections.map(\.channelID))
            let threadAllowlist = Set(selections.compactMap(\.threadID))
            let authority = try DiscordConnectorAuthority(
                applicationID: current.applicationID,
                botUserID: current.botUserID,
                guildAllowlist: Set(current.guildIDs),
                channelAllowlist: channelAllowlist,
                threadAllowlist: threadAllowlist,
                messageContentAccess: current.messageContentAccess
            )
            let updated = StoredDiscordConnectorConfiguration(
                authority: authority,
                selections: selections,
                reconciliationState: current.reconciliationState,
                checkpointIdentifier: current.checkpointIdentifier
            )
            status.cursorData = try encoder.encode(updated)
            status.selectedSourceIdentifiers = selections.map(
                \.sourceContainerIdentifier
            ).sorted()
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Discord source selection saved."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func syncDiscord(statusID: String) async -> Bool {
        guard begin(statusID) else { return false }
        defer { end(statusID) }
        let trace = DiscordTraceContext()
        do {
            var status = try requiredStatus(statusID)
            var configuration = try discordConfiguration(statusID: statusID)
            let authority = try configuration.authority()
            guard !configuration.selections.isEmpty else {
                throw ConnectorSourcesFailure.configurationUnavailable
            }
            status.state = .syncing
            status.lastAttemptedSync = .now
            try store.saveConnectorStatus(status)
            reload()
            _ = try await discordController.resume(
                authority: authority,
                trace: trace.child()
            )

            let accountID = VaultIdentity.accountID(
                provider: VaultProviderKind.discord.rawValue,
                providerAccountID: authority.accountIdentifier
            )
            let containerIDs = Set(status.selectedSourceIdentifiers.map {
                VaultIdentity.containerID(
                    provider: VaultProviderKind.discord.rawValue,
                    accountID: accountID,
                    providerContainerID: $0
                )
            })
            let existing = try await vaultController.database.connectorEnvelopes(
                accountID: accountID,
                containerIDs: containerIDs,
                maximumTotalCount: DiscordLimits.maximumExistingEnvelopes,
                maximumTotalMaterializedBytes:
                    DiscordLimits.maximumExistingEnvelopeBytes
            )
            let result = try await discordController.sync(
                authority: authority,
                selections: configuration.selections,
                existingEnvelopes: existing,
                reconciliationState: configuration.reconciliationState,
                checkpointIdentifier: configuration.checkpointIdentifier,
                trace: trace.child()
            )
            let groups = try DiscordVaultAdmissionAdapter.groups(from: result)
            var inserted = 0
            var updated = 0
            var tombstoned = 0
            for group in groups {
                let page = try discordVaultPage(
                    group: group,
                    status: status,
                    discovery: discordDiscoveryByStatusID[statusID]
                )
                let committed = try await vaultController.admitConnectorPage(page)
                inserted += committed.insertedCount
                updated += committed.updatedCount + committed.resurrectedCount
                tombstoned += committed.tombstonedCount
            }
            configuration = StoredDiscordConnectorConfiguration(
                authority: authority,
                selections: configuration.selections,
                reconciliationState: result.reconciliationState,
                checkpointIdentifier: configuration.checkpointIdentifier
            )
            status.cursorData = try encoder.encode(configuration)
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            status.state = result.receipt.isComplete
                && authority.messageContentAccess == .enabled
                ? .connected : .degraded
            status.lastSuccessfulSync = result.receipt.isComplete
                ? result.receipt.completedAt : status.lastSuccessfulSync
            status.lastAttemptedSync = result.receipt.startedAt
            let vaultCounts = try await connectorVaultCounts(
                provider: .discord,
                providerAccountIdentifier: status.stableAccountIdentifier
            )
            status.importedItemCount = vaultCounts.items
            status.skippedItemCount = result.receipt.skippedCount
            status.attachmentCount = vaultCounts.attachments
            if !result.receipt.isComplete {
                status.lastErrorReasonCode = result.receipt.reasonCode
            } else if authority.messageContentAccess != .enabled {
                status.lastErrorReasonCode =
                    DiscordFailureCode.messageContentIntentMissing.rawValue
            } else {
                status.lastErrorReasonCode = nil
            }
            status.retryAfter = nil
            status.updatedAt = .now
            let receipt = try makeConnectorReceipt(
                status: status,
                discord: result.receipt,
                inserted: inserted,
                updated: updated,
                tombstoned: tombstoned,
                pageCount: groups.count
            )
            status.latestReceiptIdentifier = receipt.id
            try store.saveConnectorStatus(status)
            try store.saveConnectorSyncReceipt(receipt)
            reload()
            statusMessage = result.receipt.isComplete
                ? "Discord sync completed and was admitted to the local Vault."
                : "Discord sync was partial; retained data and resumable progress were preserved."
            errorMessage = nil
            return true
        } catch {
            await recordFailure(error, statusID: statusID)
            return false
        }
    }

    func cancel(statusID: String) async {
        await discordController.cancel()
        statusMessage = "Connector operation cancellation requested."
    }

    func disconnectDiscord(
        statusID: String,
        forWholeAppDeletion: Bool = false
    ) async -> Bool {
        guard begin(
            statusID,
            allowDuringWholeAppDeletion: forWholeAppDeletion
        ) else { return false }
        defer { end(statusID) }
        do {
            var status = try requiredStatus(statusID)
            let authority = try discordConfiguration(statusID: statusID).authority()
            let result = await discordController.disconnect(authority: authority)
            guard result.credentialDeleted,
                  result.localDataDisposition == .preserved,
                  !result.remoteMutationAttempted
            else { throw DiscordFailure(.credentialDeleteFailed) }
            status.state = .disconnected
            status.credentialReference = nil
            status.lastErrorReasonCode = nil
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Discord disconnected. Its Keychain token was removed and local data was preserved."
            errorMessage = nil
            return true
        } catch {
            await recordFailure(error, statusID: statusID)
            return false
        }
    }

    func importEmail(
        from url: URL,
        allowLocalModel: Bool
    ) async -> Bool {
        let operationID = "email-import"
        guard begin(operationID) else { return false }
        defer { end(operationID) }
        var persistedStatusID: String?
        do {
            let format = try emailFormat(for: url)
            let captured = try await Self.captureSecurityScopedFile(url)
            let source = EmailImportSource(
                sourceIdentifier: url.standardizedFileURL.path,
                displayName: url.lastPathComponent,
                format: format,
                observedModificationDate: captured.observedModificationDate,
                indexingPolicy: allowLocalModel
                    ? .localSemanticIndex : .archiveOnly
            )
            let statusID = "support-email:\(source.sourceIdentifierHash)"
            persistedStatusID = statusID
            activeStatusIdentifiers.insert(statusID)
            defer { activeStatusIdentifiers.remove(statusID) }
            try await importEmailData(
                captured.data,
                bookmark: captured.bookmark,
                source: source,
                statusID: statusID,
                checkpoint: nil
            )
            return true
        } catch {
            if let persistedStatusID {
                await recordFailure(error, statusID: persistedStatusID)
            } else {
                present(error)
            }
            return false
        }
    }

    func syncEmail(statusID: String) async -> Bool {
        guard begin(statusID) else { return false }
        defer { end(statusID) }
        do {
            let configuration = try emailConfiguration(statusID: statusID)
            let access = try requiredEmailAccess(statusID)
            var stale = false
            let url = try URL(
                resolvingBookmarkData: access.securityScopedBookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let captured = try await Self.readSecurityScopedFile(
                url,
                refreshBookmark: stale
            )
            let bookmark = captured.refreshedBookmark
                ?? access.securityScopedBookmark
            try await importEmailData(
                captured.data,
                bookmark: bookmark,
                source: configuration.source,
                statusID: statusID,
                checkpoint: configuration.checkpoint
            )
            return true
        } catch {
            await recordFailure(error, statusID: statusID)
            return false
        }
    }

    func disconnectEmail(
        statusID: String,
        forWholeAppDeletion: Bool = false
    ) -> Bool {
        guard begin(
            statusID,
            allowDuringWholeAppDeletion: forWholeAppDeletion
        ) else { return false }
        defer { end(statusID) }
        do {
            var status = try requiredStatus(statusID)
            try store.removeEmailImportAccess(id: statusID)
            status.state = .disconnected
            status.lastErrorReasonCode = nil
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Email file access was removed. Imported local data was preserved."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func setDiscordLocalModelConsent(statusID: String, enabled: Bool) -> Bool {
        do {
            var status = try requiredStatus(statusID)
            guard status.kind == .discord else {
                throw ConnectorSourcesFailure.statusUnavailable
            }
            status.localModelConsentEnabled = enabled
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = enabled
                ? "Selected Discord excerpts may enter explicitly rebuilt local-model indexes."
                : "Discord excerpts are excluded from local-model indexes."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func setEmailLocalModelConsent(statusID: String, enabled: Bool) -> Bool {
        do {
            var status = try requiredStatus(statusID)
            guard status.kind == .supportEmail,
                  !enabled
                    || status.privacyClassification == .localImportedMailbox
            else { throw ConnectorSourcesFailure.configurationUnavailable }
            status.localModelConsentEnabled = enabled
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = enabled
                ? "Imported email text may enter explicitly rebuilt local-model indexes."
                : "Imported email text is excluded from local-model indexes."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func removeLocalData(statusID: String) async -> Bool {
        guard begin(statusID) else { return false }
        defer { end(statusID) }
        do {
            var status = try requiredStatus(statusID)
            let provider: VaultProviderKind = status.kind == .discord
                ? .discord : .supportEmail
            let result = try await vaultController.removeConnectorLocalData(
                provider: provider,
                providerAccountIdentifier: status.stableAccountIdentifier
            )
            if status.kind == .discord,
               let configuration = try? discordConfiguration(
                    statusID: statusID
               ) {
                status.cursorData = try encoder.encode(
                    StoredDiscordConnectorConfiguration(
                        authority: configuration.authority(),
                        selections: configuration.selections,
                        reconciliationState: .init(),
                        checkpointIdentifier:
                            configuration.checkpointIdentifier
                    )
                )
            } else if status.kind == .supportEmail,
                      let configuration = try? emailConfiguration(
                        statusID: statusID
                      ) {
                status.cursorData = try encoder.encode(
                    StoredEmailConnectorConfiguration(
                        schemaVersion: 1,
                        source: configuration.source,
                        checkpoint: nil
                    )
                )
            }
            status.importedItemCount = 0
            status.skippedItemCount = 0
            status.attachmentCount = 0
            status.lastSuccessfulSync = nil
            status.latestReceiptIdentifier = nil
            status.updatedAt = .now
            try store.saveConnectorStatus(status)
            reload()
            statusMessage = "Removed \(result.recordsDeleted) retained connector records. Credentials and source authorization were unchanged."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func prepareForWholeAppDataDeletion() async -> Bool {
        guard !hasUpdateBlockingWork, !wholeAppDeletionInProgress,
              attachedDataSourcesController.prepareForWholeAppDataDeletion()
        else {
            present(ConnectorSourcesFailure.operationInProgress)
            return false
        }
        wholeAppDeletionInProgress = true
        var prepared = false
        defer {
            if !prepared {
                wholeAppDeletionInProgress = false
                attachedDataSourcesController
                    .resumeAfterWholeAppDataDeletionAbort()
            }
        }
        for status in statuses where status.kind == .discord {
            if !(await disconnectDiscord(
                statusID: status.id,
                forWholeAppDeletion: true
            )) { return false }
        }
        for status in statuses where status.kind == .supportEmail {
            if (try? store.emailImportAccess(id: status.id)) != nil,
               !disconnectEmail(
                    statusID: status.id,
                    forWholeAppDeletion: true
               ) {
                return false
            }
        }
        prepared = true
        return true
    }

    func prepareForUpdateInstallation() async -> Bool {
        guard !hasUpdateBlockingWork, !wholeAppDeletionInProgress,
              attachedDataSourcesController.prepareForUpdateInstallation()
        else {
            return false
        }
        await discordController.cancel()
        return true
    }

    func resumeAfterWholeAppDataDeletionAbort() {
        wholeAppDeletionInProgress = false
        attachedDataSourcesController.resumeAfterWholeAppDataDeletionAbort()
    }

    func reloadAfterWholeAppDataDeletion() {
        wholeAppDeletionInProgress = false
        discordDiscoveryByStatusID = [:]
        attachedDataSourcesController.reloadAfterWholeAppDataDeletion()
        reload()
    }
}

private extension ConnectorSourcesController {
    func begin(
        _ statusID: String,
        allowDuringWholeAppDeletion: Bool = false
    ) -> Bool {
        guard activeStatusIdentifiers.isEmpty,
              !wholeAppDeletionInProgress || allowDuringWholeAppDeletion
        else {
            present(ConnectorSourcesFailure.operationInProgress)
            return false
        }
        activeStatusIdentifiers.insert(statusID)
        return true
    }

    func end(_ statusID: String) {
        activeStatusIdentifiers.remove(statusID)
    }

    func reload(reportFailure: Bool = true) {
        do {
            statuses = try store.connectorStatuses()
        } catch {
            if reportFailure { present(error) }
        }
    }

    func reconcilePersistedRuntimeStates() {
        for var status in statuses
        where [.connecting, .connected, .syncing].contains(status.state) {
            status.state = .disconnected
            status.lastErrorReasonCode = "connector_explicit_resume_required"
            status.updatedAt = .now
            try? store.saveConnectorStatus(status)
        }
        reload(reportFailure: false)
    }

    func requiredStatus(_ id: String) throws -> ConnectorStatusSnapshot {
        guard let value = try store.connectorStatus(id: id) else {
            throw ConnectorSourcesFailure.statusUnavailable
        }
        return value
    }

    func discordConfiguration(
        statusID: String
    ) throws -> StoredDiscordConnectorConfiguration {
        let status = try requiredStatus(statusID)
        guard status.kind == .discord,
              let data = status.cursorData,
              let value = try? decoder.decode(
                StoredDiscordConnectorConfiguration.self,
                from: data
              ),
              value.schemaVersion == 1
        else { throw ConnectorSourcesFailure.configurationUnavailable }
        return value
    }

    func emailConfiguration(
        statusID: String
    ) throws -> StoredEmailConnectorConfiguration {
        let status = try requiredStatus(statusID)
        guard status.kind == .supportEmail,
              let data = status.cursorData,
              let value = try? decoder.decode(
                StoredEmailConnectorConfiguration.self,
                from: data
              ),
              value.schemaVersion == 1
        else { throw ConnectorSourcesFailure.configurationUnavailable }
        return value
    }

    func requiredEmailAccess(_ statusID: String) throws
        -> EmailImportAccessSnapshot
    {
        guard let access = try store.emailImportAccess(id: statusID) else {
            throw ConnectorSourcesFailure.fileAuthorizationFailed
        }
        return access
    }

    func requiredDiscordDiscovery(_ statusID: String) throws
        -> DiscordDiscoveryResult
    {
        guard let value = discordDiscoveryByStatusID[statusID] else {
            throw ConnectorSourcesFailure.configurationUnavailable
        }
        return value
    }

    func recordFailure(_ error: Error, statusID: String) async {
        if var status = try? requiredStatus(statusID) {
            status.state = isCancellation(error) ? .degraded : .failed
            status.lastAttemptedSync = .now
            status.lastErrorReasonCode = reasonCode(error)
            if let discord = error as? DiscordFailure,
               let retry = discord.retryAfterSeconds {
                status.retryAfter = Date().addingTimeInterval(retry)
            }
            let provider: VaultProviderKind = status.kind == .discord
                ? .discord : .supportEmail
            if status.kind != .slack,
               let counts = try? await connectorVaultCounts(
                   provider: provider,
                   providerAccountIdentifier: status.stableAccountIdentifier
               ) {
                status.importedItemCount = counts.items
                status.attachmentCount = counts.attachments
            }
            status.updatedAt = .now
            try? store.saveConnectorStatus(status)
            reload(reportFailure: false)
        }
        present(error)
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }

    func reasonCode(_ error: Error) -> String {
        if let value = error as? DiscordFailure { return value.reasonCode }
        if let value = error as? EmailImportFailureCode { return value.rawValue }
        if let value = error as? ConnectorSourcesFailure { return value.rawValue }
        if let value = error as? ConnectorVaultAdmissionFailure {
            return value.rawValue
        }
        return "connector_operation_failed"
    }

    func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? DiscordFailure)?.code == .cancelled
            || (error as? EmailImportFailureCode) == .cancelled
    }

    func boundedDisplayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(trimmed.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(200))
        return safe.isEmpty ? fallback : safe
    }

    func discordVaultPage(
        group: DiscordVaultAdmissionGroup,
        status: ConnectorStatusSnapshot,
        discovery: DiscordDiscoveryResult?
    ) throws -> ConnectorVaultPage {
        guard let first = group.descriptors.first,
              let containerID = first.envelope.provenance
                .sourceContainerIdentifier
        else { throw ConnectorSourcesFailure.configurationUnavailable }
        let selection = try? discordConfiguration(statusID: status.id)
            .selections.first {
                $0.sourceContainerIdentifier == containerID
            }
        let displayName: String
        if let selection,
           let threadID = selection.threadID,
           let thread = discovery?.threads.first(where: { $0.id == threadID }) {
            displayName = thread.displayName
        } else if let selection,
                  let channel = discovery?.channels.first(where: {
                      $0.id == selection.channelID
                  }) {
            displayName = channel.displayName
        } else {
            displayName = "Discord channel or thread"
        }
        let descriptors = try group.descriptors.map { value in
            var metadata: [String: String] = [
                "discord_message_id_sha256": value.messageIdentifierHash,
                "discord_attachment_count": String(value.attachments.count),
            ]
            metadata["discord_author_id_sha256"] =
                value.pseudonymousAuthorIdentifier
            metadata["discord_author_display_name"] = value.authorDisplayName
            metadata["discord_author_is_bot"] = value.authorIsBot.map(String.init)
            metadata["discord_guild_id_sha256"] = value.guildIdentifierHash
            metadata["discord_channel_id_sha256"] = value.channelIdentifierHash
            metadata["discord_thread_id_sha256"] = value.threadIdentifierHash
            metadata["discord_reply_to_id_sha256"] =
                value.replyToMessageIdentifierHash
            metadata["discord_body_state"] = value.bodyState?.rawValue
            if !value.attachments.isEmpty {
                metadata["discord_attachment_metadata_json"] = String(
                    data: try encoder.encode(value.attachments),
                    encoding: .utf8
                )
            }
            return try ConnectorVaultRecordDescriptor(
                envelope: value.envelope,
                title: value.privacyBoundedTitle,
                authorReference: value.authorDisplayName
                    ?? value.pseudonymousAuthorIdentifier,
                additionalMetadata: metadata.compactMapValues { $0 }
            )
        }
        return try .init(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: status.stableAccountIdentifier,
            accountDisplayName: status.displayName,
            providerContainerIdentifier: containerID,
            containerDisplayName: displayName,
            containerKind: .discordChannel,
            paginationReceipt: first.envelope.paginationReceipt,
            records: descriptors
        )
    }

    func makeConnectorReceipt(
        status: ConnectorStatusSnapshot,
        discord: DiscordSyncReceipt,
        inserted: Int,
        updated: Int,
        tombstoned: Int,
        pageCount: Int
    ) throws -> ConnectorSyncReceipt {
        let allowlistHash = ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed(
                status.selectedSourceIdentifiers.sorted()
            )
        )
        let receiptData = try encoder.encode(discord)
        let receiptHash = ConnectorEnvelopeDigest.sha256(receiptData)
        return .init(
            id: "discord-receipt:\(receiptHash)",
            connectorStatusIdentifier: status.id,
            kind: .discord,
            traceID: discord.traceID,
            startedAt: discord.startedAt,
            completedAt: discord.completedAt,
            status: status.state,
            reasonCode: discord.reasonCode,
            importedItemCount: inserted,
            updatedItemCount: updated,
            tombstonedItemCount: tombstoned,
            skippedItemCount: discord.skippedCount,
            attachmentCount: discord.attachmentCount,
            pageCount: pageCount,
            sourceAllowlistHash: allowlistHash,
            receiptHash: receiptHash
        )
    }

    func emailFormat(for url: URL) throws -> EmailImportSourceFormat {
        switch url.pathExtension.lowercased() {
        case "eml": .eml
        case "mbox": .mbox
        default: throw ConnectorSourcesFailure.unsupportedEmailFormat
        }
    }

    nonisolated static func performReadSecurityScopedFile(
        _ url: URL,
        refreshBookmark: Bool = false
    ) async throws -> (data: Data, refreshedBookmark: Data?)
    {
        let worker = Task.detached(priority: .userInitiated) {
            guard url.startAccessingSecurityScopedResource() else {
                throw ConnectorSourcesFailure.fileAuthorizationFailed
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmark = refreshBookmark
                ? try url.bookmarkData(
                    options: [
                        .withSecurityScope,
                        .securityScopeAllowOnlyReadAccess,
                    ],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                : nil
            return (
                try EmailBoundedFileReader.readAuthorizedFile(at: url).data,
                bookmark
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func performCaptureSecurityScopedFile(_ url: URL) async throws
        -> (data: Data, bookmark: Data, observedModificationDate: Date?)
    {
        let worker = Task.detached(priority: .userInitiated) {
            guard url.startAccessingSecurityScopedResource() else {
                throw ConnectorSourcesFailure.fileAuthorizationFailed
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmark = try url.bookmarkData(
                options: [
                    .withSecurityScope,
                    .securityScopeAllowOnlyReadAccess,
                ],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let snapshot = try EmailBoundedFileReader.readAuthorizedFile(
                at: url
            )
            return (
                snapshot.data,
                bookmark,
                snapshot.observedModificationDate
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func prepareEmailImport(
        controller: EmailImportController,
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint?,
        mboxSession: EmailMBoxReadSession?
    ) async throws -> EmailImportResult {
        let worker = Task.detached(priority: .userInitiated) {
            switch source.format {
            case .eml:
                return try controller.prepareEMLImport(
                    data: data,
                    source: source
                )
            case .mbox:
                guard let mboxSession else {
                    throw ConnectorSourcesFailure.configurationUnavailable
                }
                return try controller.prepareMBoxImport(
                    session: mboxSession,
                    source: source,
                    checkpoint: checkpoint
                )
            case .maildir:
                throw ConnectorSourcesFailure.unsupportedEmailFormat
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func makeEmailMBoxImportSession(
        controller: EmailImportController,
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint?
    ) async throws -> EmailMBoxReadSession {
        let worker = Task.detached(priority: .userInitiated) {
            try controller.makeMBoxImportSession(
                data: data,
                source: source,
                checkpoint: checkpoint
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func importEmailData(
        _ data: Data,
        bookmark: Data,
        source: EmailImportSource,
        statusID: String,
        checkpoint initialCheckpoint: EmailImportCheckpoint?
    ) async throws {
        var checkpoint = initialCheckpoint
        var status = (try? requiredStatus(statusID)) ?? ConnectorStatusSnapshot(
            id: statusID,
            kind: .supportEmail,
            stableAccountIdentifier: source.mailboxIdentifierHash,
            displayName: source.displayName,
            state: .syncing,
            selectedSourceIdentifiers: [source.sourceIdentifierHash],
            privacyClassification: source.indexingPolicy == .localSemanticIndex
                ? .localImportedMailbox : .localArchiveOnly,
            automaticSyncEnabled: false,
            localModelConsentEnabled:
                source.indexingPolicy == .localSemanticIndex
        )
        status.displayName = source.displayName
        status.selectedSourceIdentifiers = [source.sourceIdentifierHash]
        status.privacyClassification = source.indexingPolicy == .localSemanticIndex
            ? .localImportedMailbox : .localArchiveOnly
        status.localModelConsentEnabled =
            source.indexingPolicy == .localSemanticIndex
        status.state = .syncing
        status.skippedItemCount = 0
        status.lastErrorReasonCode = nil
        status.retryAfter = nil
        let runStartedAt = Date.now
        let runIdentifier = UUID().uuidString.lowercased()
        status.lastAttemptedSync = runStartedAt
        try store.saveConnectorStatus(status)
        reload()

        let mboxSession: EmailMBoxReadSession?
        if source.format == .mbox {
            mboxSession = try await Self.makeEmailMBoxImportSession(
                controller: emailController,
                data: data,
                source: source,
                checkpoint: checkpoint
            )
        } else {
            mboxSession = nil
        }
        var runInserted = 0
        var runUpdated = 0
        var runSkipped = 0
        var runAttachmentCount = 0
        var runPageReceipts: [EmailImportReceipt] = []
        var shouldContinue = true
        while shouldContinue {
            try Task.checkCancellation()
            let result = try await Self.prepareEmailImport(
                controller: emailController,
                data: data,
                source: source,
                checkpoint: checkpoint,
                mboxSession: mboxSession
            )

            var inserted = 0
            var updated = 0
            for group in result.vaultPageGroups {
                let page = try emailVaultPage(group)
                let committed = try await vaultController.admitConnectorPage(page)
                inserted += committed.insertedCount
                updated += committed.updatedCount + committed.resurrectedCount
            }
            runInserted += inserted
            runUpdated += updated
            runSkipped += result.admissionPage.receipt.skippedItemCount
            runAttachmentCount += result.admissionPage.receipt.attachmentCount
            runPageReceipts.append(result.admissionPage.receipt)
            checkpoint = result.checkpointAfterCommit
            status.cursorData = try encoder.encode(
                StoredEmailConnectorConfiguration(
                    schemaVersion: 1,
                    source: source,
                    checkpoint: result.checkpointAfterCommit
                )
            )
            let completed = result.checkpointAfterCommit.completed
            status.state = completed
                ? (runSkipped == 0 ? .connected : .degraded)
                : .syncing
            if completed { status.lastSuccessfulSync = .now }
            status.lastAttemptedSync = runStartedAt
            let vaultCounts = try await connectorVaultCounts(
                provider: .supportEmail,
                providerAccountIdentifier: status.stableAccountIdentifier
            )
            status.importedItemCount = vaultCounts.items
            status.skippedItemCount = runSkipped
            status.attachmentCount = vaultCounts.attachments
            status.lastErrorReasonCode = completed && runSkipped > 0
                ? "email_import_completed_with_skips" : nil
            status.updatedAt = .now
            let receipt = try makeEmailConnectorReceipt(
                status: status,
                source: source,
                checkpoint: result.checkpointAfterCommit,
                pageReceipts: runPageReceipts,
                inserted: runInserted,
                updated: runUpdated,
                skipped: runSkipped,
                attachments: runAttachmentCount,
                runIdentifier: runIdentifier,
                startedAt: runStartedAt
            )
            status.latestReceiptIdentifier = receipt.id
            try store.saveEmailImportAccess(.init(
                id: statusID,
                mailboxIdentity: source.mailboxIdentifierHash,
                securityScopedBookmark: bookmark,
                fileIdentityHash: source.sourceIdentifierHash,
                committedByteOffset: Int64(
                    result.checkpointAfterCommit.committedByteCount ?? data.count
                ),
                highWatermarkHash:
                    result.checkpointAfterCommit.committedPrefixSHA256,
                updatedAt: .now
            ))
            try store.saveConnectorStatus(status)
            try store.saveConnectorSyncReceipt(receipt)
            reload()
            shouldContinue = source.format == .mbox
                && !result.checkpointAfterCommit.completed
        }
        statusMessage = "Email import completed locally. No remote resource or attachment body was fetched."
        errorMessage = nil
    }

    func emailVaultPage(_ group: EmailVaultPageGroup) throws
        -> ConnectorVaultPage
    {
        let records = try group.records.map { record in
            let metadata = record.metadata
            let preservedMetadata = try metadata.canonicalJSONData()
            guard let preservedMetadataJSON = String(
                data: preservedMetadata,
                encoding: .utf8
            ) else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
            var additional: [String: String] = [
                "email_thread_basis": metadata.thread.basis.rawValue,
                "email_raw_message_sha256": metadata.rawMessageSHA256,
                "email_mailbox_id_sha256": metadata.mailboxIdentifierHash,
                "email_import_source_id_sha256":
                    metadata.importSourceIdentifierHash,
                "email_warning_codes": metadata.warnings.map(\.rawValue)
                    .sorted().joined(separator: ","),
                EmailVaultStoredMetadata.metadataKey: preservedMetadataJSON,
            ]
            additional["email_message_id_sha256"] = metadata.headers.messageID.map {
                EmailDigest.sha256("message-id\u{1f}\($0)")
            }
            additional["email_in_reply_to_sha256"] = metadata.headers.inReplyTo.map {
                EmailDigest.sha256("message-id\u{1f}\($0)")
            }
            if !metadata.headers.references.isEmpty {
                additional["email_references_sha256"] = EmailDigest.sha256(
                    metadata.headers.references.joined(separator: "\u{1f}")
                )
            }
            return try ConnectorVaultRecordDescriptor(
                envelope: record.envelope,
                title: metadata.headers.subject.isEmpty
                    ? "Support email" : metadata.headers.subject,
                authorReference: metadata.headers.from.first,
                additionalMetadata: additional.compactMapValues { $0 }
            )
        }
        return try .init(
            kind: .supportEmail,
            provider: .supportEmail,
            providerAccountIdentifier: group.providerAccountIdentifier,
            accountDisplayName: group.accountDisplayName,
            providerContainerIdentifier: group.providerContainerIdentifier,
            containerDisplayName: group.containerDisplayName,
            containerKind: .mailbox,
            paginationReceipt: group.paginationReceipt,
            records: records
        )
    }

    func makeEmailConnectorReceipt(
        status: ConnectorStatusSnapshot,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint,
        pageReceipts: [EmailImportReceipt],
        inserted: Int,
        updated: Int,
        skipped: Int,
        attachments: Int,
        runIdentifier: String,
        startedAt: Date
    ) throws -> ConnectorSyncReceipt {
        let receiptMaterial = EmailConnectorRunReceiptMaterial(
            schemaVersion: 1,
            sourceIdentifierHash: source.sourceIdentifierHash,
            pageReceipts: pageReceipts,
            checkpoint: checkpoint,
            insertedItemCount: inserted,
            updatedItemCount: updated,
            skippedItemCount: skipped,
            attachmentCount: attachments
        )
        let receiptHash = ConnectorEnvelopeDigest.sha256(
            try encoder.encode(receiptMaterial)
        )
        let completed = checkpoint.completed
        let reasonCode: String
        if !completed {
            reasonCode = "email_import_progress"
        } else if skipped == 0 {
            reasonCode = "email_import_completed"
        } else {
            reasonCode = "email_import_completed_with_skips"
        }
        return .init(
            id: "email-receipt:\(runIdentifier):page-\(pageReceipts.count)",
            connectorStatusIdentifier: status.id,
            kind: .supportEmail,
            traceID: "email-import:\(runIdentifier)",
            startedAt: startedAt,
            completedAt: .now,
            status: status.state,
            reasonCode: reasonCode,
            importedItemCount: inserted,
            updatedItemCount: updated,
            tombstonedItemCount: 0,
            skippedItemCount: skipped,
            attachmentCount: attachments,
            pageCount: pageReceipts.count,
            sourceAllowlistHash: ConnectorEnvelopeDigest.sha256(
                ConnectorEnvelopeDigest.lengthPrefixed(
                    status.selectedSourceIdentifiers
                )
            ),
            receiptHash: receiptHash
        )
    }

    func connectorVaultCounts(
        provider: VaultProviderKind,
        providerAccountIdentifier: String
    ) async throws -> (items: Int, attachments: Int) {
        let accountID = VaultIdentity.accountID(
            provider: provider.rawValue,
            providerAccountID: providerAccountIdentifier
        )
        let containers = try await vaultController.database.containers(
            accountID: accountID
        )
        guard !containers.isEmpty else { return (0, 0) }
        return try await vaultController.database.connectorEnvelopeCounts(
            accountID: accountID,
            containerIDs: Set(containers.map(\.id))
        )
    }
}

extension ConnectorSourcesController {
    nonisolated static func readSecurityScopedFile(
        _ url: URL,
        refreshBookmark: Bool = false
    ) async throws -> (data: Data, refreshedBookmark: Data?) {
        try await performReadSecurityScopedFile(
            url,
            refreshBookmark: refreshBookmark
        )
    }

    nonisolated static func captureSecurityScopedFile(_ url: URL) async throws
        -> (data: Data, bookmark: Data, observedModificationDate: Date?)
    {
        try await performCaptureSecurityScopedFile(url)
    }
}

private extension DiscordConnectionState {
    var connectorState: ConnectorConnectionState {
        ConnectorConnectionState(rawValue: rawValue) ?? .failed
    }
}
