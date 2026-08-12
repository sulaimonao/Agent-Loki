import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class ConnectorSourcesControllerTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testLaunchRequiresExplicitResumeWithoutClaimingConnected() throws {
        let stack = try makeStack()
        try stack.store.saveConnectorStatus(.init(
            id: "discord:guild-fixture",
            kind: .discord,
            stableAccountIdentifier: "guild-fixture",
            displayName: "Synthetic Discord",
            state: .connected,
            credentialReference: "keychain:discord:fixture",
            selectedSourceIdentifiers: ["channel-fixture"],
            privacyClassification: .localSelectedSource
        ))

        let controller = ConnectorSourcesController(
            store: stack.store,
            vaultController: stack.vault
        )
        let status = try XCTUnwrap(
            controller.status(id: "discord:guild-fixture")
        )
        XCTAssertEqual(status.state, .disconnected)
        XCTAssertEqual(
            status.lastErrorReasonCode,
            "connector_explicit_resume_required"
        )
        XCTAssertEqual(status.credentialReference, "keychain:discord:fixture")
        XCTAssertFalse(controller.hasUpdateBlockingWork)
    }

    func testRemoveLocalDataDeletesPreviouslySelectedContainersOnlyAfterConfirmationPath() async throws {
        let stack = try makeStack()
        let accountIdentifier = "guild-fixture"
        let oldPage = try page(
            kind: .discord,
            accountIdentifier: accountIdentifier,
            containerIdentifier: "channel-old",
            messageIdentifier: "message-old",
            text: "Old synthetic message"
        )
        let currentPage = try page(
            kind: .discord,
            accountIdentifier: accountIdentifier,
            containerIdentifier: "channel-current",
            messageIdentifier: "message-current",
            text: "Current synthetic message"
        )
        _ = try await stack.vault.admitConnectorPage(oldPage)
        _ = try await stack.vault.admitConnectorPage(currentPage)
        let authority = try DiscordConnectorAuthority(
            applicationID: "111111111111111111",
            botUserID: "222222222222222222",
            guildAllowlist: ["333333333333333333"],
            channelAllowlist: ["444444444444444444"],
            messageContentAccess: .enabled
        )
        let selection = try DiscordSourceSelection(
            guildID: "333333333333333333",
            channelID: "444444444444444444"
        )
        let syncCursor = try DiscordSelectionSyncCursor(
            highWatermarkMessageID: "555555555555555555",
            incrementalPollsSinceFullReconciliation: 2,
            lastCompletedCoverage: .incremental
        )
        let configuration = StoredDiscordConnectorConfiguration(
            authority: authority,
            selections: [selection],
            reconciliationState: .init(
                missingCompleteObservations: ["message-fixture": 1],
                selectionCursors: [selection.id: syncCursor]
            )
        )
        try stack.store.saveConnectorStatus(.init(
            id: "discord:guild-fixture",
            kind: .discord,
            stableAccountIdentifier: accountIdentifier,
            displayName: "Synthetic Discord",
            state: .disconnected,
            credentialReference: "keychain:discord:fixture",
            selectedSourceIdentifiers: [selection.sourceContainerIdentifier],
            cursorData: try JSONEncoder().encode(configuration),
            importedItemCount: 2,
            privacyClassification: .localSelectedSource
        ))
        let controller = ConnectorSourcesController(
            store: stack.store,
            vaultController: stack.vault
        )

        let removed = await controller.removeLocalData(
            statusID: "discord:guild-fixture"
        )
        XCTAssertTrue(removed)
        let accounts = try await stack.vault.database.accounts()
        let containers = try await stack.vault.database.containers()
        XCTAssertEqual(accounts, [])
        XCTAssertEqual(containers, [])
        let status = try XCTUnwrap(
            controller.status(id: "discord:guild-fixture")
        )
        XCTAssertEqual(status.importedItemCount, 0)
        XCTAssertEqual(status.credentialReference, "keychain:discord:fixture")
        XCTAssertEqual(
            status.selectedSourceIdentifiers,
            [selection.sourceContainerIdentifier]
        )
        let resetConfiguration = try JSONDecoder().decode(
            StoredDiscordConnectorConfiguration.self,
            from: try XCTUnwrap(status.cursorData)
        )
        XCTAssertEqual(
            resetConfiguration.reconciliationState,
            DiscordReconciliationState()
        )
    }

    func testEmailAuthorizationRemovalPreservesAdmittedLocalData() async throws {
        let stack = try makeStack()
        let statusID = "support-email:source-fixture"
        let page = try page(
            kind: .supportEmail,
            accountIdentifier: "mailbox-fixture",
            containerIdentifier: "source-fixture",
            messageIdentifier: "email-fixture",
            text: "Synthetic support request"
        )
        _ = try await stack.vault.admitConnectorPage(page)
        try stack.store.saveConnectorStatus(.init(
            id: statusID,
            kind: .supportEmail,
            stableAccountIdentifier: "mailbox-fixture",
            displayName: "Synthetic mailbox",
            state: .degraded,
            selectedSourceIdentifiers: ["source-fixture"],
            importedItemCount: 1,
            privacyClassification: .localArchiveOnly
        ))
        try stack.store.saveEmailImportAccess(.init(
            id: statusID,
            mailboxIdentity: "mailbox-fixture",
            securityScopedBookmark: Data([0x01, 0x02]),
            fileIdentityHash: "source-fixture",
            committedByteOffset: 128,
            highWatermarkHash: String(repeating: "a", count: 64),
            updatedAt: anchor
        ))
        let controller = ConnectorSourcesController(
            store: stack.store,
            vaultController: stack.vault
        )

        XCTAssertEqual(
            controller.emailAccessState(statusID: statusID),
            .available
        )
        XCTAssertTrue(controller.disconnectEmail(statusID: statusID))
        XCTAssertNil(try stack.store.emailImportAccess(id: statusID))
        XCTAssertEqual(
            controller.emailAccessState(statusID: statusID),
            .removed
        )
        let stored = try await stack.vault.database.record(
            id: "connector:\(page.records[0].envelope.deduplicationKey)"
        )
        XCTAssertEqual(stored?.body, "Synthetic support request")
        XCTAssertEqual(controller.status(id: statusID)?.state, .disconnected)
        XCTAssertEqual(controller.status(id: statusID)?.importedItemCount, 1)
    }

    func testEmailLocalModelConsentCanBeRevokedButArchiveOnlyDataCannotBeElevated() throws {
        let stack = try makeStack()
        let localStatusID = "support-email:local-index"
        let archiveStatusID = "support-email:archive-only"
        try stack.store.saveConnectorStatus(.init(
            id: localStatusID,
            kind: .supportEmail,
            stableAccountIdentifier: "mailbox-local",
            displayName: "Synthetic local-index mailbox",
            state: .connected,
            privacyClassification: .localImportedMailbox,
            localModelConsentEnabled: true
        ))
        try stack.store.saveConnectorStatus(.init(
            id: archiveStatusID,
            kind: .supportEmail,
            stableAccountIdentifier: "mailbox-archive",
            displayName: "Synthetic archive mailbox",
            state: .connected,
            privacyClassification: .localArchiveOnly,
            localModelConsentEnabled: false
        ))
        let controller = ConnectorSourcesController(
            store: stack.store,
            vaultController: stack.vault
        )

        XCTAssertTrue(controller.setEmailLocalModelConsent(
            statusID: localStatusID,
            enabled: false
        ))
        XCTAssertFalse(
            try XCTUnwrap(controller.status(id: localStatusID))
                .localModelConsentEnabled
        )
        XCTAssertFalse(controller.setEmailLocalModelConsent(
            statusID: archiveStatusID,
            enabled: true
        ))
        XCTAssertFalse(
            try XCTUnwrap(controller.status(id: archiveStatusID))
                .localModelConsentEnabled
        )
    }

    func testWholeAppDeletionPreparationHoldsConnectorMutationBarrierUntilCompletionOrAbort() async throws {
        let stack = try makeStack()
        let controller = ConnectorSourcesController(
            store: stack.store,
            vaultController: stack.vault
        )

        let prepared = await controller.prepareForWholeAppDataDeletion()
        XCTAssertTrue(prepared)
        XCTAssertTrue(controller.wholeAppDeletionInProgress)
        XCTAssertFalse(controller.disconnectEmail(statusID: "missing-email"))
        XCTAssertEqual(
            controller.errorMessage,
            ConnectorSourcesFailure.operationInProgress.localizedDescription
        )

        controller.resumeAfterWholeAppDataDeletionAbort()
        XCTAssertFalse(controller.wholeAppDeletionInProgress)
        XCTAssertFalse(controller.disconnectEmail(statusID: "missing-email"))
        XCTAssertEqual(
            controller.errorMessage,
            ConnectorSourcesFailure.statusUnavailable.localizedDescription
        )
    }

    func testTaskOwnedEmailSecurityScopedBookmarkCaptureAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "loki-email-bookmark-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let url = directory.appendingPathComponent("synthetic-support.eml")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fixture = Data(
            "From: sender@example.invalid\r\nTo: support@example.invalid\r\nSubject: Synthetic\r\n\r\nLocal fixture.\r\n"
                .utf8
        )
        try fixture.write(to: url, options: .atomic)

        let captured: (
            data: Data,
            bookmark: Data,
            observedModificationDate: Date?
        )
        do {
            captured = try await ConnectorSourcesController
                .captureSecurityScopedFile(url)
        } catch ConnectorSourcesFailure.fileAuthorizationFailed {
            throw XCTSkip("email_security_scope_missing_entitlement")
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFeatureUnsupportedError]
                .contains(value.code) {
                throw XCTSkip("email_security_scope_unavailable_\(value.code)")
            }
            throw error
        }
        XCTAssertEqual(captured.data, fixture)
        XCTAssertFalse(captured.bookmark.isEmpty)
        XCTAssertNotNil(captured.observedModificationDate)

        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: captured.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let reopened = try await ConnectorSourcesController
            .readSecurityScopedFile(resolved, refreshBookmark: stale)
        XCTAssertEqual(reopened.data, fixture)
        if stale { XCTAssertNotNil(reopened.refreshedBookmark) }
    }

    private func makeStack() throws -> (
        store: LocalStore,
        vault: VaultController
    ) {
        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(store: store, clientID: nil)
        let vault = try VaultController(
            store: store,
            slackController: slack,
            inMemory: true
        )
        return (store, vault)
    }

    private func page(
        kind: ConnectorKind,
        accountIdentifier: String,
        containerIdentifier: String,
        messageIdentifier: String,
        text: String
    ) throws -> ConnectorVaultPage {
        let provider: VaultProviderKind = kind == .discord
            ? .discord : .supportEmail
        let receipt = try ConnectorPaginationReceipt(
            checkpointIdentifier: "checkpoint-\(containerIdentifier)",
            streamIdentifier: "stream-\(containerIdentifier)",
            pageOrdinal: 0,
            requestCursor: nil,
            nextCursor: nil,
            sourceHighWatermark: messageIdentifier,
            isComplete: true
        )
        let normalizedText = ConnectorTextNormalization.text(text)
        let envelope = try ConnectorRecordEnvelope(
            provider: provider.rawValue,
            pseudonymousAccountIdentifier: accountIdentifier,
            remoteRecordIdentifier: messageIdentifier,
            recordType: kind == .discord
                ? "discord_message" : "support_email_message",
            sourceTimestamp: anchor,
            ingestionTimestamp: anchor.addingTimeInterval(1),
            normalizedText: normalizedText,
            attachments: [],
            editOrVersionIdentifier: "fixture-v1",
            sourceHash: ConnectorEnvelopeDigest.sha256(normalizedText),
            paginationReceipt: receipt,
            provenance: try .init(
                sourceSystem: provider.rawValue,
                sourceContainerIdentifier: containerIdentifier,
                sourceURL: nil,
                retrievedAt: anchor.addingTimeInterval(1),
                policyBasis: "explicit_synthetic_fixture"
            ),
            policyClassification: kind == .discord
                ? .localIndexAllowed : .archiveOnly
        )
        return try ConnectorVaultPage(
            kind: kind,
            provider: provider,
            providerAccountIdentifier: accountIdentifier,
            accountDisplayName: "Synthetic source",
            providerContainerIdentifier: containerIdentifier,
            containerDisplayName: "Synthetic container",
            containerKind: kind == .discord ? .discordChannel : .mailbox,
            paginationReceipt: receipt,
            records: [try .init(
                envelope: envelope,
                title: "Synthetic record"
            )]
        )
    }
}
