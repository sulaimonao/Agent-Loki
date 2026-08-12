import Foundation

enum ConnectorVaultAdmissionFailure: String, Error, LocalizedError, Sendable {
    case emptyPage = "connector_vault_page_empty"
    case providerMismatch = "connector_vault_provider_mismatch"
    case accountMismatch = "connector_vault_account_mismatch"
    case containerMismatch = "connector_vault_container_mismatch"
    case paginationMismatch = "connector_vault_pagination_mismatch"
    case duplicateRecord = "connector_vault_duplicate_record"
    case invalidMetadata = "connector_vault_metadata_invalid"
    case existingRecordBudgetExceeded = "connector_vault_existing_record_budget_exceeded"

    var errorDescription: String? { rawValue }
}

enum ConnectorEnvelopeMaterializationBudget {
    static let maximumTotalBytes = 128 * 1_024 * 1_024
    private static let estimatedEnvelopeOverheadBytes = 1_024
    private static let estimatedAttachmentOverheadBytes = 256

    static func estimatedBytes(_ envelope: ConnectorRecordEnvelope) -> Int {
        var bytes = estimatedEnvelopeOverheadBytes
        let values = [
            envelope.provider,
            envelope.pseudonymousAccountIdentifier,
            envelope.remoteRecordIdentifier,
            envelope.recordType,
            envelope.parentOrThreadIdentifier ?? "",
            envelope.normalizedText,
            envelope.editOrVersionIdentifier,
            envelope.sourceHash,
            envelope.paginationReceipt.checkpointIdentifier,
            envelope.paginationReceipt.streamIdentifier,
            envelope.paginationReceipt.requestCursor ?? "",
            envelope.paginationReceipt.nextCursor ?? "",
            envelope.paginationReceipt.sourceHighWatermark ?? "",
            envelope.paginationReceipt.receiptHash,
            envelope.provenance.sourceSystem,
            envelope.provenance.sourceContainerIdentifier ?? "",
            envelope.provenance.sourceURL?.absoluteString ?? "",
            envelope.provenance.policyBasis,
        ]
        bytes += values.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) }
        for attachment in envelope.attachments {
            bytes += estimatedAttachmentOverheadBytes
            bytes += attachment.attachmentIdentifier.lengthOfBytes(using: .utf8)
            bytes += attachment.mediaType.lengthOfBytes(using: .utf8)
            bytes += attachment.sourceHash.lengthOfBytes(using: .utf8)
        }
        return bytes
    }

    static func admits(
        _ envelopes: [ConnectorRecordEnvelope],
        maximumBytes: Int = maximumTotalBytes
    ) -> Bool {
        guard maximumBytes > 0, maximumBytes <= maximumTotalBytes else {
            return false
        }
        var total = 0
        for envelope in envelopes {
            let estimate = estimatedBytes(envelope)
            guard estimate <= maximumBytes - total else { return false }
            total += estimate
        }
        return true
    }
}

extension VaultDatabase {
    func connectorEnvelopes(
        accountID: String,
        containerIDs: Set<String>,
        maximumCount: Int = VaultLimits.maximumRecordsPerContainer,
        maximumTotalCount: Int = VaultLimits.maximumRecordsPerContainer,
        maximumTotalMaterializedBytes: Int =
            ConnectorEnvelopeMaterializationBudget.maximumTotalBytes
    ) throws -> [ConnectorRecordEnvelope] {
        guard !containerIDs.isEmpty,
              maximumCount > 0,
              maximumCount <= VaultLimits.maximumRecordsPerContainer,
              maximumTotalCount > 0,
              maximumTotalCount <= VaultLimits.maximumRecordsPerContainer,
              maximumTotalMaterializedBytes > 0,
              maximumTotalMaterializedBytes <=
                ConnectorEnvelopeMaterializationBudget.maximumTotalBytes
        else { throw ConnectorVaultAdmissionFailure.existingRecordBudgetExceeded }

        var envelopes: [ConnectorRecordEnvelope] = []
        var materializedBytes = 0
        for containerID in containerIDs.sorted() {
            var offset = 0
            var containerEnvelopeCount = 0
            while true {
                if envelopes.count == maximumTotalCount {
                    let probe = try search(.init(
                        text: "",
                        accountID: accountID,
                        containerID: containerID,
                        deleted: false,
                        limit: 1,
                        offset: offset,
                        preference: .likeOnly
                    ))
                    guard probe.results.isEmpty else {
                        throw ConnectorVaultAdmissionFailure
                            .existingRecordBudgetExceeded
                    }
                    break
                }
                if containerEnvelopeCount == maximumCount {
                    let probe = try search(.init(
                        text: "",
                        accountID: accountID,
                        containerID: containerID,
                        deleted: false,
                        limit: 1,
                        offset: offset,
                        preference: .likeOnly
                    ))
                    guard probe.results.isEmpty else {
                        throw ConnectorVaultAdmissionFailure
                            .existingRecordBudgetExceeded
                    }
                    break
                }
                let requestedLimit = min(
                    VaultLimits.maximumSearchResults,
                    maximumCount - containerEnvelopeCount,
                    maximumTotalCount - envelopes.count
                )
                let page = try search(.init(
                    text: "",
                    accountID: accountID,
                    containerID: containerID,
                    deleted: false,
                    limit: requestedLimit,
                    offset: offset,
                    preference: .likeOnly
                ))
                guard !page.results.isEmpty else { break }
                for result in page.results {
                    guard let record = try record(id: result.id) else {
                        throw ConnectorVaultAdmissionFailure.invalidMetadata
                    }
                    let envelope = try ConnectorVaultStoredEnvelope.reconstruct(
                        from: record
                    )
                    let estimatedBytes = ConnectorEnvelopeMaterializationBudget
                        .estimatedBytes(envelope)
                    guard estimatedBytes <=
                        maximumTotalMaterializedBytes - materializedBytes
                    else {
                        throw ConnectorVaultAdmissionFailure
                            .existingRecordBudgetExceeded
                    }
                    envelopes.append(envelope)
                    materializedBytes += estimatedBytes
                    containerEnvelopeCount += 1
                }
                offset += page.results.count
                if page.results.count < requestedLimit {
                    break
                }
            }
        }
        return envelopes
    }

    func connectorEnvelopeCounts(
        accountID: String,
        containerIDs: Set<String>,
        maximumCount: Int = VaultLimits.maximumRecordsPerContainer
    ) throws -> (items: Int, attachments: Int) {
        guard !containerIDs.isEmpty,
              maximumCount > 0,
              maximumCount <= VaultLimits.maximumRecordsPerContainer
        else { throw ConnectorVaultAdmissionFailure.existingRecordBudgetExceeded }

        var itemCount = 0
        var attachmentCount = 0
        for containerID in containerIDs.sorted() {
            var offset = 0
            var containerEnvelopeCount = 0
            while true {
                if containerEnvelopeCount == maximumCount {
                    let probe = try search(.init(
                        text: "",
                        accountID: accountID,
                        containerID: containerID,
                        deleted: false,
                        limit: 1,
                        offset: offset,
                        preference: .likeOnly
                    ))
                    guard probe.results.isEmpty else {
                        throw ConnectorVaultAdmissionFailure
                            .existingRecordBudgetExceeded
                    }
                    break
                }
                let requestedLimit = min(
                    VaultLimits.maximumSearchResults,
                    maximumCount - containerEnvelopeCount
                )
                let page = try search(.init(
                    text: "",
                    accountID: accountID,
                    containerID: containerID,
                    deleted: false,
                    limit: requestedLimit,
                    offset: offset,
                    preference: .likeOnly
                ))
                guard !page.results.isEmpty else { break }
                for result in page.results {
                    guard let record = try record(id: result.id) else {
                        throw ConnectorVaultAdmissionFailure.invalidMetadata
                    }
                    let envelope = try ConnectorVaultStoredEnvelope.reconstruct(
                        from: record
                    )
                    itemCount += 1
                    attachmentCount += envelope.attachments.count
                    containerEnvelopeCount += 1
                }
                offset += page.results.count
                if page.results.count < requestedLimit {
                    break
                }
            }
        }
        return (itemCount, attachmentCount)
    }
}

private struct ConnectorVaultEnvelopeSidecar: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let provider: String
    let pseudonymousAccountIdentifier: String
    let remoteRecordIdentifier: String
    let recordType: String
    let parentOrThreadIdentifier: String?
    let sourceTimestamp: Date
    let ingestionTimestamp: Date
    let attachments: [ConnectorAttachmentMetadata]
    let deletionState: ConnectorRecordDeletionState
    let editOrVersionIdentifier: String
    let sourceHash: String
    let paginationReceipt: ConnectorPaginationReceipt
    let provenance: ConnectorRecordProvenance
    let policyClassification: ConnectorRecordPolicyClassification
    let contentClassification: ConnectorRecordContentClassification
    let containsSensitiveMaterial: Bool

    init(_ envelope: ConnectorRecordEnvelope) {
        schemaVersion = envelope.schemaVersion
        provider = envelope.provider
        pseudonymousAccountIdentifier = envelope.pseudonymousAccountIdentifier
        remoteRecordIdentifier = envelope.remoteRecordIdentifier
        recordType = envelope.recordType
        parentOrThreadIdentifier = envelope.parentOrThreadIdentifier
        sourceTimestamp = envelope.sourceTimestamp
        ingestionTimestamp = envelope.ingestionTimestamp
        attachments = envelope.attachments
        deletionState = envelope.deletionState
        editOrVersionIdentifier = envelope.editOrVersionIdentifier
        sourceHash = envelope.sourceHash
        paginationReceipt = envelope.paginationReceipt
        provenance = envelope.provenance
        policyClassification = envelope.policyClassification
        contentClassification = envelope.contentClassification
        containsSensitiveMaterial = envelope.containsSensitiveMaterial
    }

    func envelope(normalizedText: String) throws -> ConnectorRecordEnvelope {
        try .init(
            schemaVersion: schemaVersion,
            provider: provider,
            pseudonymousAccountIdentifier: pseudonymousAccountIdentifier,
            remoteRecordIdentifier: remoteRecordIdentifier,
            recordType: recordType,
            parentOrThreadIdentifier: parentOrThreadIdentifier,
            sourceTimestamp: sourceTimestamp,
            ingestionTimestamp: ingestionTimestamp,
            normalizedText: normalizedText,
            attachments: attachments,
            deletionState: deletionState,
            editOrVersionIdentifier: editOrVersionIdentifier,
            sourceHash: sourceHash,
            paginationReceipt: paginationReceipt,
            provenance: provenance,
            policyClassification: policyClassification,
            contentClassification: contentClassification,
            containsSensitiveMaterial: containsSensitiveMaterial
        )
    }
}

enum ConnectorVaultStoredEnvelope {
    static let metadataKey = "connector_envelope_sidecar_json"

    static func reconstruct(from record: VaultRecord) throws
        -> ConnectorRecordEnvelope
    {
        guard let encoded = record.metadata[metadataKey]?.data(using: .utf8)
        else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
        let sidecar: ConnectorVaultEnvelopeSidecar
        do {
            sidecar = try JSONDecoder().decode(
                ConnectorVaultEnvelopeSidecar.self,
                from: encoded
            )
        } catch {
            throw ConnectorVaultAdmissionFailure.invalidMetadata
        }
        let envelope = try sidecar.envelope(normalizedText: record.body)
        guard record.provider == envelope.provider,
              record.providerRecordID == envelope.remoteRecordIdentifier,
              ConnectorEnvelopeDigest.milliseconds(record.occurredAt)
                == ConnectorEnvelopeDigest.milliseconds(
                    envelope.sourceTimestamp
                ),
              ConnectorEnvelopeDigest.milliseconds(record.capturedAt)
                == ConnectorEnvelopeDigest.milliseconds(
                    envelope.ingestionTimestamp
                ),
              record.metadata["connector_envelope_sha256"]
                == envelope.canonicalEnvelopeHash
        else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
        return envelope
    }
}

struct ConnectorVaultRecordDescriptor: Hashable, Sendable {
    let envelope: ConnectorRecordEnvelope
    let title: String
    let authorReference: String?
    let additionalMetadata: [String: String]

    init(
        envelope: ConnectorRecordEnvelope,
        title: String,
        authorReference: String? = nil,
        additionalMetadata: [String: String] = [:]
    ) throws {
        guard additionalMetadata.count <= 32,
              additionalMetadata.keys.allSatisfy({
                  !$0.isEmpty && $0.lengthOfBytes(using: .utf8) <= 128
              }),
              additionalMetadata.values.allSatisfy({
                  $0.lengthOfBytes(using: .utf8)
                    <= VaultLimits.maximumMetadataBytes
              })
        else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
        self.envelope = envelope
        self.title = String(title.prefix(VaultLimits.maximumTitleCharacters))
        self.authorReference = authorReference.map {
            String($0.prefix(VaultLimits.maximumAuthorCharacters))
        }
        self.additionalMetadata = additionalMetadata
    }
}

struct ConnectorVaultPage: Sendable {
    let kind: ConnectorKind
    let provider: VaultProviderKind
    let providerAccountIdentifier: String
    let accountDisplayName: String
    let providerContainerIdentifier: String
    let containerDisplayName: String
    let containerKind: VaultContainerKind
    let paginationReceipt: ConnectorPaginationReceipt
    let records: [ConnectorVaultRecordDescriptor]

    init(
        kind: ConnectorKind,
        provider: VaultProviderKind,
        providerAccountIdentifier: String,
        accountDisplayName: String,
        providerContainerIdentifier: String,
        containerDisplayName: String,
        containerKind: VaultContainerKind,
        paginationReceipt: ConnectorPaginationReceipt,
        records: [ConnectorVaultRecordDescriptor]
    ) throws {
        guard !records.isEmpty else {
            throw ConnectorVaultAdmissionFailure.emptyPage
        }
        guard (kind == .discord && provider == .discord)
                || (kind == .supportEmail && provider == .supportEmail)
                || (kind == .attachedData && provider == .localImport)
        else { throw ConnectorVaultAdmissionFailure.providerMismatch }
        guard records.allSatisfy({
            $0.envelope.provider == provider.rawValue
                && $0.envelope.pseudonymousAccountIdentifier
                    == providerAccountIdentifier
        }) else { throw ConnectorVaultAdmissionFailure.accountMismatch }
        guard records.allSatisfy({
            $0.envelope.provenance.sourceContainerIdentifier
                == providerContainerIdentifier
        }) else { throw ConnectorVaultAdmissionFailure.containerMismatch }
        guard records.allSatisfy({
            $0.envelope.paginationReceipt == paginationReceipt
        }) else { throw ConnectorVaultAdmissionFailure.paginationMismatch }
        guard Set(records.map { $0.envelope.deduplicationKey }).count
                == records.count
        else { throw ConnectorVaultAdmissionFailure.duplicateRecord }
        try paginationReceipt.validateIntegrity()

        self.kind = kind
        self.provider = provider
        self.providerAccountIdentifier = providerAccountIdentifier
        self.accountDisplayName = String(
            accountDisplayName.prefix(VaultLimits.maximumDisplayNameCharacters)
        )
        self.providerContainerIdentifier = providerContainerIdentifier
        self.containerDisplayName = String(
            containerDisplayName.prefix(VaultLimits.maximumDisplayNameCharacters)
        )
        self.containerKind = containerKind
        self.paginationReceipt = paginationReceipt
        self.records = records
    }

    var accountID: String {
        VaultIdentity.accountID(
            provider: provider.rawValue,
            providerAccountID: providerAccountIdentifier
        )
    }

    var containerID: String {
        VaultIdentity.containerID(
            provider: provider.rawValue,
            accountID: accountID,
            providerContainerID: providerContainerIdentifier
        )
    }

    func mutation(at date: Date = .now) throws -> VaultConnectorPageMutation {
        let sidecarEncoder = JSONEncoder()
        sidecarEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var available: [VaultRecordInput] = []
        var tombstones: [VaultConnectorTombstoneInput] = []

        for descriptor in records {
            let envelope = descriptor.envelope
            let recordID = "connector:\(envelope.deduplicationKey)"
            if envelope.deletionState == .tombstone {
                tombstones.append(.init(
                    recordID: recordID,
                    providerRecordID: envelope.remoteRecordIdentifier,
                    deletedAt: envelope.sourceTimestamp
                ))
                continue
            }

            let sidecarData = try sidecarEncoder.encode(
                ConnectorVaultEnvelopeSidecar(envelope)
            )
            guard let sidecarJSON = String(data: sidecarData, encoding: .utf8)
            else { throw ConnectorVaultAdmissionFailure.invalidMetadata }
            var metadata = descriptor.additionalMetadata
            metadata["connector_schema_version"] = String(envelope.schemaVersion)
            metadata["connector_record_type"] = envelope.recordType
            metadata["connector_edit_version"] = envelope.editOrVersionIdentifier
            metadata["connector_source_sha256"] = envelope.sourceHash
            metadata["connector_envelope_sha256"] = envelope.canonicalEnvelopeHash
            metadata["connector_page_receipt_sha256"] = envelope.paginationReceipt.receiptHash
            metadata["connector_policy"] = envelope.policyClassification.rawValue
            metadata["connector_content_classification"] = envelope.contentClassification.rawValue
            metadata[ConnectorVaultStoredEnvelope.metadataKey] = sidecarJSON
            let encodedMetadata = try sidecarEncoder.encode(metadata)
            guard metadata.count <= VaultLimits.maximumMetadataEntries,
                  encodedMetadata.count <= VaultLimits.maximumMetadataBytes
            else { throw ConnectorVaultAdmissionFailure.invalidMetadata }

            available.append(.init(
                id: recordID,
                accountID: accountID,
                containerID: containerID,
                providerRecordID: envelope.remoteRecordIdentifier,
                kind: envelope.recordType,
                title: descriptor.title,
                body: envelope.normalizedText,
                author: descriptor.authorReference,
                sourceURL: envelope.provenance.sourceURL,
                occurredAt: envelope.sourceTimestamp,
                capturedAt: envelope.ingestionTimestamp,
                modifiedAt: max(envelope.sourceTimestamp, envelope.ingestionTimestamp),
                metadata: metadata,
                contentOrigin: .source,
                providerMetadataVersion: envelope.schemaVersion,
                threadRootID: envelope.parentOrThreadIdentifier,
                replyCount: 0
            ))
        }

        return .init(
            account: .init(
                id: accountID,
                provider: provider.rawValue,
                providerAccountID: providerAccountIdentifier,
                displayName: accountDisplayName,
                createdAt: date,
                updatedAt: date
            ),
            container: .init(
                id: containerID,
                accountID: accountID,
                providerContainerID: providerContainerIdentifier,
                kind: containerKind.rawValue,
                displayName: containerDisplayName,
                createdAt: date,
                updatedAt: date
            ),
            records: available,
            tombstones: tombstones,
            paginationReceiptHash: paginationReceipt.receiptHash
        )
    }
}

struct VaultConnectorTombstoneInput: Hashable, Sendable {
    let recordID: String
    let providerRecordID: String
    let deletedAt: Date
}

struct VaultConnectorPageMutation: Sendable {
    let account: VaultAccountInput
    let container: VaultContainerInput
    let records: [VaultRecordInput]
    let tombstones: [VaultConnectorTombstoneInput]
    let paginationReceiptHash: String
}

struct VaultConnectorCommitResult: Hashable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
    let resurrectedCount: Int
    let tombstonedCount: Int
    let tombstoneNotFoundCount: Int
    let paginationReceiptHash: String

    var changedCount: Int {
        insertedCount + updatedCount + resurrectedCount + tombstonedCount
    }
}

/// A complete connector generation prepared outside Loki Vault. The Vault
/// commits every container and record in one transaction, and tombstones any
/// previously admitted record omitted from the replacement. External SQLite
/// connections are never shared with this mutation.
struct VaultConnectorGenerationMutation: Sendable {
    let account: VaultAccountInput
    let containers: [VaultContainerInput]
    let records: [VaultRecordInput]
    let generationReceiptHash: String
    let attachmentBlobCount: Int
    let truncationCount: Int
    let materializedByteCount: Int64

    init(
        account: VaultAccountInput,
        containers: [VaultContainerInput],
        records: [VaultRecordInput],
        generationReceiptHash: String,
        attachmentBlobCount: Int = 0,
        truncationCount: Int = 0,
        materializedByteCount: Int64 = 0
    ) {
        self.account = account
        self.containers = containers
        self.records = records
        self.generationReceiptHash = generationReceiptHash
        self.attachmentBlobCount = attachmentBlobCount
        self.truncationCount = truncationCount
        self.materializedByteCount = materializedByteCount
    }
}

struct VaultConnectorGenerationCommitResult: Hashable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
    let resurrectedCount: Int
    let tombstonedCount: Int
    let generationReceiptHash: String

    var changedCount: Int {
        insertedCount + updatedCount + resurrectedCount + tombstonedCount
    }
}

/// Durable evidence written in the same SQLite transaction as a complete
/// connector generation. It lets the private application store reconcile a
/// process interruption without guessing whether the Vault commit happened.
struct VaultConnectorGenerationMarker: Hashable, Sendable {
    let accountID: String
    let generationReceiptHash: String
    let containerCount: Int
    let recordCount: Int
    let insertedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
    let resurrectedCount: Int
    let tombstonedCount: Int
    let attachmentBlobCount: Int
    let truncationCount: Int
    let materializedByteCount: Int64
    let committedAt: Date
}

struct ConnectorLocalDataRemovalResult: Hashable, Sendable {
    let accountID: String
    let containersDeleted: Int
    let recordsDeleted: Int
    let revisionsDeleted: Int
    let tombstonesDeleted: Int
}

@MainActor
extension VaultController {
    func admitConnectorPage(
        _ page: ConnectorVaultPage,
        trace: VaultTraceContext = .init()
    ) async throws -> VaultConnectorCommitResult {
        guard beginForegroundDatabaseOperation() else {
            throw VaultControllerFailure.archiveUnavailable
        }
        defer { endForegroundDatabaseOperation() }
        let result = try await database.commit(
            connectorPage: page.mutation(),
            trace: trace
        )
        await refresh()
        return result
    }

    func admitConnectorGeneration(
        _ generation: VaultConnectorGenerationMutation,
        trace: VaultTraceContext = .init()
    ) async throws -> VaultConnectorGenerationCommitResult {
        guard beginForegroundDatabaseOperation() else {
            throw VaultControllerFailure.archiveUnavailable
        }
        defer { endForegroundDatabaseOperation() }
        let result = try await database.replaceConnectorGeneration(
            generation,
            trace: trace
        )
        await refresh()
        return result
    }

    func removeConnectorLocalData(
        provider: VaultProviderKind,
        providerAccountIdentifier: String
    ) async throws -> ConnectorLocalDataRemovalResult {
        guard beginForegroundDatabaseOperation()
        else { throw VaultControllerFailure.archiveUnavailable }
        defer { endForegroundDatabaseOperation() }

        let accountID = VaultIdentity.accountID(
            provider: provider.rawValue,
            providerAccountID: providerAccountIdentifier
        )
        await onEvidenceDeletionWillBegin?()
        do {
            // A connector status represents one provider account. Removing its
            // local data must include containers selected in earlier sessions,
            // not only the connector's current allowlist.
            let summary = try await database.deleteAccount(id: accountID)
            await refresh()
            await onEvidenceDeletionCompleted?(accountID)
            return .init(
                accountID: accountID,
                containersDeleted: summary.containersDeleted,
                recordsDeleted: summary.recordsDeleted,
                revisionsDeleted: summary.revisionsDeleted,
                tombstonesDeleted: summary.tombstonesDeleted
            )
        } catch {
            await onEvidenceDeletionCompleted?(accountID)
            throw error
        }
    }
}
