import Foundation
import XCTest
@testable import LokiBrief

final class ConnectorVaultAdmissionTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testConnectorPageCommitIsAtomicReplaySafeUpdatesAndTombstones() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let first = try page(
            envelope: envelope(text: "Synthetic first message", version: "v1")
        )

        let inserted = try await database.commit(connectorPage: first.mutation())
        XCTAssertEqual(inserted.insertedCount, 1)
        XCTAssertEqual(inserted.changedCount, 1)

        let replayed = try await database.commit(connectorPage: first.mutation())
        XCTAssertEqual(replayed.unchangedCount, 1)
        XCTAssertEqual(replayed.changedCount, 0)

        let edited = try page(
            envelope: envelope(text: "Synthetic edited message", version: "v2")
        )
        let updated = try await database.commit(connectorPage: edited.mutation())
        XCTAssertEqual(updated.updatedCount, 1)
        let loadedRecord = try await database.record(
            id: "connector:\(edited.records[0].envelope.deduplicationKey)"
        )
        let stored = try XCTUnwrap(loadedRecord)
        XCTAssertEqual(stored.body, "Synthetic edited message")
        let reconstructed = try ConnectorVaultStoredEnvelope.reconstruct(
            from: stored
        )
        XCTAssertEqual(
            reconstructed.canonicalEnvelopeHash,
            edited.records[0].envelope.canonicalEnvelopeHash
        )
        let reloaded = try await database.connectorEnvelopes(
            accountID: edited.accountID,
            containerIDs: [edited.containerID]
        )
        XCTAssertEqual(reloaded, [edited.records[0].envelope])
        let revisions = try await database.revisions(recordID: stored.id)
        XCTAssertEqual(revisions.count, 1)

        let deleted = try page(envelope: envelope(
            text: "",
            version: "v3",
            deletionState: .tombstone
        ))
        let tombstoned = try await database.commit(connectorPage: deleted.mutation())
        XCTAssertEqual(tombstoned.tombstonedCount, 1)
        let deletedRecord = try await database.record(id: stored.id)
        let tombstones = try await database.tombstones()
        XCTAssertNil(deletedRecord)
        XCTAssertEqual(tombstones.count, 1)
    }

    func testConnectorGenerationAtomicallyReplacesAndTombstonesOmittedRecords() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let firstEnvelope = try envelope(
            text: "Synthetic first attached record",
            version: "v1",
            remoteRecordIdentifier: "attached-first",
            containerIdentifier: "attached-table"
        )
        let secondEnvelope = try envelope(
            text: "Synthetic second attached record",
            version: "v1",
            remoteRecordIdentifier: "attached-second",
            containerIdentifier: "attached-table"
        )
        let initialPage = try generationPage(envelopes: [
            firstEnvelope, secondEnvelope,
        ])
        let initialMutation = try initialPage.mutation(at: anchor)
        let initialReceipt = ConnectorEnvelopeDigest.sha256(
            Data("attached-generation-v1".utf8)
        )
        let initial = try await database.replaceConnectorGeneration(.init(
            account: initialMutation.account,
            containers: [initialMutation.container],
            records: initialMutation.records,
            generationReceiptHash: initialReceipt,
            attachmentBlobCount: 3,
            truncationCount: 1,
            materializedByteCount: 1_234
        ))
        XCTAssertEqual(initial.insertedCount, 2)
        XCTAssertEqual(initial.tombstonedCount, 0)
        let storedInitialMarker = try await database.connectorGenerationMarker(
            accountID: initialMutation.account.id
        )
        let initialMarker = try XCTUnwrap(storedInitialMarker)
        XCTAssertEqual(initialMarker.generationReceiptHash, initialReceipt)
        XCTAssertEqual(initialMarker.containerCount, 1)
        XCTAssertEqual(initialMarker.recordCount, 2)
        XCTAssertEqual(initialMarker.insertedCount, 2)
        XCTAssertEqual(initialMarker.attachmentBlobCount, 3)
        XCTAssertEqual(initialMarker.truncationCount, 1)
        XCTAssertEqual(initialMarker.materializedByteCount, 1_234)

        let editedEnvelope = try envelope(
            text: "Synthetic edited attached record",
            version: "v2",
            remoteRecordIdentifier: "attached-first",
            containerIdentifier: "attached-table"
        )
        let replacementPage = try generationPage(envelopes: [editedEnvelope])
        let replacementMutation = try replacementPage.mutation(
            at: anchor.addingTimeInterval(60)
        )
        let replacementReceipt = ConnectorEnvelopeDigest.sha256(
            Data("attached-generation-v2".utf8)
        )
        let replacement = try await database.replaceConnectorGeneration(.init(
            account: replacementMutation.account,
            containers: [replacementMutation.container],
            records: replacementMutation.records,
            generationReceiptHash: replacementReceipt,
            materializedByteCount: 567
        ))
        XCTAssertEqual(replacement.updatedCount, 1)
        XCTAssertEqual(replacement.tombstonedCount, 1)
        XCTAssertEqual(replacement.generationReceiptHash, replacementReceipt)

        let editedID = try XCTUnwrap(replacementMutation.records.first?.id)
        let deletedID = try XCTUnwrap(initialMutation.records.last?.id)
        let editedRecord = try await database.record(id: editedID)
        let deletedRecord = try await database.record(id: deletedID)
        let tombstones = try await database.tombstones()
        XCTAssertEqual(editedRecord?.body, "Synthetic edited attached record")
        XCTAssertNil(deletedRecord)
        XCTAssertTrue(tombstones.contains {
            $0.recordID == deletedID && $0.reason == .sourceDeleted
        })
        let storedReplacementMarker = try await database
            .connectorGenerationMarker(
                accountID: replacementMutation.account.id
            )
        let replacementMarker = try XCTUnwrap(storedReplacementMarker)
        XCTAssertEqual(
            replacementMarker.generationReceiptHash,
            replacementReceipt
        )
        XCTAssertEqual(replacementMarker.recordCount, 1)
        XCTAssertEqual(replacementMarker.updatedCount, 1)
        XCTAssertEqual(replacementMarker.tombstonedCount, 1)
        XCTAssertEqual(replacementMarker.materializedByteCount, 567)
        let accountExistsBeforeDeletion = try await database.accountExists(
            id: replacementMutation.account.id
        )
        XCTAssertTrue(accountExistsBeforeDeletion)

        _ = try await database.deleteAccount(id: replacementMutation.account.id)
        let accountExistsAfterDeletion = try await database.accountExists(
            id: replacementMutation.account.id
        )
        let markerAfterDeletion = try await database.connectorGenerationMarker(
            accountID: replacementMutation.account.id
        )
        XCTAssertFalse(accountExistsAfterDeletion)
        XCTAssertNil(markerAfterDeletion)
    }

    func testInvalidConnectorGenerationLeavesPriorGenerationUntouched() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let originalEnvelope = try envelope(
            text: "Synthetic retained generation",
            version: "v1",
            remoteRecordIdentifier: "attached-retained",
            containerIdentifier: "attached-table"
        )
        let page = try generationPage(envelopes: [originalEnvelope])
        let mutation = try page.mutation(at: anchor)
        _ = try await database.replaceConnectorGeneration(.init(
            account: mutation.account,
            containers: [mutation.container],
            records: mutation.records,
            generationReceiptHash: ConnectorEnvelopeDigest.sha256(
                Data("attached-valid-generation".utf8)
            )
        ))

        let invalidContainer = VaultContainerInput(
            id: mutation.container.id,
            accountID: "wrong-account",
            providerContainerID: mutation.container.providerContainerID,
            kind: mutation.container.kind,
            displayName: mutation.container.displayName,
            createdAt: anchor,
            updatedAt: anchor
        )
        do {
            _ = try await database.replaceConnectorGeneration(.init(
                account: mutation.account,
                containers: [invalidContainer],
                records: mutation.records,
                generationReceiptHash: ConnectorEnvelopeDigest.sha256(
                    Data("attached-invalid-generation".utf8)
                )
            ))
            XCTFail("Expected generation scope validation to fail")
        } catch {}

        let retainedID = try XCTUnwrap(mutation.records.first?.id)
        let retained = try await database.record(id: retainedID)
        let tombstones = try await database.tombstones()
        XCTAssertEqual(retained?.body, "Synthetic retained generation")
        XCTAssertEqual(tombstones, [])
    }

    func testReplayWithFreshRetrievalReceiptDoesNotManufactureRevision() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let original = try page(
            envelope: envelope(text: "Synthetic unchanged message", version: "v1")
        )
        _ = try await database.commit(connectorPage: original.mutation())

        let replayEnvelope = try envelope(
            text: "Synthetic unchanged message",
            version: "v1",
            ingestionTimestamp: anchor.addingTimeInterval(600)
        )
        XCTAssertNotEqual(
            original.records[0].envelope.ingestionTimestamp,
            replayEnvelope.ingestionTimestamp
        )
        XCTAssertEqual(
            original.records[0].envelope.canonicalEnvelopeHash,
            replayEnvelope.canonicalEnvelopeHash
        )
        let replay = try page(envelope: replayEnvelope)
        let result = try await database.commit(connectorPage: replay.mutation())

        XCTAssertEqual(result.unchangedCount, 1)
        let revisions = try await database.revisions(
            recordID: "connector:\(replayEnvelope.deduplicationKey)"
        )
        XCTAssertEqual(revisions, [])
        let replayedRecord = try await database.record(
            id: "connector:\(replayEnvelope.deduplicationKey)"
        )
        let stored = try XCTUnwrap(replayedRecord)
        let reconstructed = try ConnectorVaultStoredEnvelope.reconstruct(
            from: stored
        )
        XCTAssertEqual(
            reconstructed.canonicalEnvelopeHash,
            original.records[0].envelope.canonicalEnvelopeHash
        )
        let envelopes = try await database.connectorEnvelopes(
            accountID: original.accountID,
            containerIDs: [original.containerID]
        )
        XCTAssertEqual(envelopes, [original.records[0].envelope])
    }

    func testStoredEnvelopeRoundTripUsesVaultMillisecondTimestampPrecision() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let highPrecisionTimestamp = anchor.addingTimeInterval(0.123456)
        let value = try envelope(
            text: "Synthetic high precision timestamp",
            version: "v1",
            ingestionTimestamp: highPrecisionTimestamp
        )
        let mutation = try page(envelope: value).mutation(at: anchor)
        _ = try await database.commit(connectorPage: mutation)

        let recordID = try XCTUnwrap(mutation.records.first?.id)
        let loaded = try await database.record(id: recordID)
        let stored = try XCTUnwrap(loaded)
        let reconstructed = try ConnectorVaultStoredEnvelope.reconstruct(
            from: stored
        )

        XCTAssertEqual(
            ConnectorEnvelopeDigest.milliseconds(stored.capturedAt),
            ConnectorEnvelopeDigest.milliseconds(
                reconstructed.ingestionTimestamp
            )
        )
        XCTAssertEqual(reconstructed.canonicalEnvelopeHash,
                       value.canonicalEnvelopeHash)
    }

    func testPageRejectsProviderAccountContainerPaginationAndDuplicateDrift() throws {
        let value = try envelope(text: "Synthetic message", version: "v1")
        let descriptor = try ConnectorVaultRecordDescriptor(
            envelope: value,
            title: "Synthetic"
        )
        XCTAssertThrowsError(try ConnectorVaultPage(
            kind: .supportEmail,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic",
            providerContainerIdentifier: "channel-fixture",
            containerDisplayName: "Synthetic",
            containerKind: .discordChannel,
            paginationReceipt: value.paginationReceipt,
            records: [descriptor]
        ))
        XCTAssertThrowsError(try ConnectorVaultPage(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "another-account",
            accountDisplayName: "Synthetic",
            providerContainerIdentifier: "channel-fixture",
            containerDisplayName: "Synthetic",
            containerKind: .discordChannel,
            paginationReceipt: value.paginationReceipt,
            records: [descriptor]
        ))
        XCTAssertThrowsError(try ConnectorVaultPage(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic",
            providerContainerIdentifier: "another-container",
            containerDisplayName: "Synthetic",
            containerKind: .discordChannel,
            paginationReceipt: value.paginationReceipt,
            records: [descriptor]
        ))
        XCTAssertThrowsError(try ConnectorVaultPage(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic",
            providerContainerIdentifier: "channel-fixture",
            containerDisplayName: "Synthetic",
            containerKind: .discordChannel,
            paginationReceipt: value.paginationReceipt,
            records: [descriptor, descriptor]
        ))
    }

    func testInvalidMutationDoesNotCreateAccountOrContainer() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let page = try page(
            envelope: envelope(text: "Synthetic message", version: "v1")
        )
        let valid = try page.mutation()
        let invalid = VaultConnectorPageMutation(
            account: valid.account,
            container: .init(
                id: valid.container.id,
                accountID: "wrong-account",
                providerContainerID: valid.container.providerContainerID,
                kind: valid.container.kind,
                displayName: valid.container.displayName,
                createdAt: anchor,
                updatedAt: anchor
            ),
            records: valid.records,
            tombstones: [],
            paginationReceiptHash: valid.paginationReceiptHash
        )

        do {
            _ = try await database.commit(connectorPage: invalid)
            XCTFail("Expected scope mismatch")
        } catch {}
        let accounts = try await database.accounts()
        let containers = try await database.containers()
        XCTAssertEqual(accounts, [])
        XCTAssertEqual(containers, [])
    }

    func testConnectorVaultMetadataDoesNotContainCredentialOrRawTransport() throws {
        let value = try envelope(text: "Synthetic message", version: "v1")
        let mutation = try page(envelope: value).mutation()
        let metadata = try XCTUnwrap(mutation.records.first?.metadata)
        XCTAssertNil(metadata["authorization"])
        XCTAssertNil(metadata["token"])
        XCTAssertNil(metadata["raw_response"])
        XCTAssertEqual(
            metadata["connector_envelope_sha256"],
            value.canonicalEnvelopeHash
        )
        XCTAssertEqual(
            metadata["connector_page_receipt_sha256"],
            value.paginationReceipt.receiptHash
        )
    }

    func testExistingEnvelopeBudgetAppliesPerContainerNotAcrossAccount() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let first = try page(
            envelope: envelope(
                text: "Synthetic first container",
                version: "v1"
            )
        )
        _ = try await database.commit(connectorPage: first.mutation())

        let secondEnvelope = try envelope(
            text: "Synthetic second container",
            version: "v1",
            remoteRecordIdentifier: "message-second",
            containerIdentifier: "channel-second"
        )
        let second = try ConnectorVaultPage(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic Community",
            providerContainerIdentifier: "channel-second",
            containerDisplayName: "synthetic-second",
            containerKind: .discordChannel,
            paginationReceipt: secondEnvelope.paginationReceipt,
            records: [try .init(
                envelope: secondEnvelope,
                title: "Synthetic message"
            )]
        )
        _ = try await database.commit(connectorPage: second.mutation())

        let loaded = try await database.connectorEnvelopes(
            accountID: first.accountID,
            containerIDs: [first.containerID, second.containerID],
            maximumCount: 1
        )
        XCTAssertEqual(loaded.count, 2)
    }

    func testExistingEnvelopeAggregateBudgetFailsBeforeAppendingPastLimit() async throws {
        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let first = try page(
            envelope: envelope(
                text: "Synthetic first aggregate record",
                version: "v1",
                attachments: [try ConnectorAttachmentMetadata(
                    attachmentIdentifier: "attachment-fixture",
                    mediaType: "text/plain",
                    byteCount: 17,
                    sourceHash: ConnectorEnvelopeDigest.sha256(
                        Data("synthetic-attachment".utf8)
                    )
                )]
            )
        )
        _ = try await database.commit(connectorPage: first.mutation())

        let secondEnvelope = try envelope(
            text: "Synthetic second aggregate record",
            version: "v1",
            remoteRecordIdentifier: "message-aggregate-second",
            containerIdentifier: "channel-aggregate-second"
        )
        let second = try ConnectorVaultPage(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic Community",
            providerContainerIdentifier: "channel-aggregate-second",
            containerDisplayName: "synthetic-aggregate-second",
            containerKind: .discordChannel,
            paginationReceipt: secondEnvelope.paginationReceipt,
            records: [try .init(
                envelope: secondEnvelope,
                title: "Synthetic aggregate message"
            )]
        )
        _ = try await database.commit(connectorPage: second.mutation())

        do {
            _ = try await database.connectorEnvelopes(
                accountID: first.accountID,
                containerIDs: [first.containerID, second.containerID],
                maximumTotalCount: 1
            )
            XCTFail("Expected the aggregate envelope budget to fail closed")
        } catch let error as ConnectorVaultAdmissionFailure {
            XCTAssertEqual(error, .existingRecordBudgetExceeded)
        }

        do {
            _ = try await database.connectorEnvelopes(
                accountID: first.accountID,
                containerIDs: [first.containerID, second.containerID],
                maximumTotalCount: 2,
                maximumTotalMaterializedBytes: 1
            )
            XCTFail("Expected the materialized byte budget to fail closed")
        } catch let error as ConnectorVaultAdmissionFailure {
            XCTAssertEqual(error, .existingRecordBudgetExceeded)
        }

        let counts = try await database.connectorEnvelopeCounts(
            accountID: first.accountID,
            containerIDs: [first.containerID, second.containerID]
        )
        XCTAssertEqual(counts.items, 2)
        XCTAssertEqual(counts.attachments, 1)
    }

    private func page(
        envelope: ConnectorRecordEnvelope
    ) throws -> ConnectorVaultPage {
        try .init(
            kind: .discord,
            provider: .discord,
            providerAccountIdentifier: "guild-fixture",
            accountDisplayName: "Synthetic Community",
            providerContainerIdentifier: "channel-fixture",
            containerDisplayName: "synthetic-support",
            containerKind: .discordChannel,
            paginationReceipt: envelope.paginationReceipt,
            records: [try .init(
                envelope: envelope,
                title: "Synthetic message",
                authorReference: "author-fixture",
                additionalMetadata: ["fixture_classification": "synthetic"]
            )]
        )
    }

    private func generationPage(
        envelopes: [ConnectorRecordEnvelope]
    ) throws -> ConnectorVaultPage {
        let receipt = try XCTUnwrap(envelopes.first?.paginationReceipt)
        return try .init(
            kind: .attachedData,
            provider: .localImport,
            providerAccountIdentifier: "attached-source-fixture",
            accountDisplayName: "Synthetic Attached Source",
            providerContainerIdentifier: "attached-table",
            containerDisplayName: "Synthetic Table",
            containerKind: .importedCollection,
            paginationReceipt: receipt,
            records: try envelopes.map { envelope in
                let attached = try ConnectorRecordEnvelope(
                    provider: VaultProviderKind.localImport.rawValue,
                    pseudonymousAccountIdentifier: "attached-source-fixture",
                    remoteRecordIdentifier: envelope.remoteRecordIdentifier,
                    recordType: "attached_record",
                    sourceTimestamp: envelope.sourceTimestamp,
                    ingestionTimestamp: envelope.ingestionTimestamp,
                    normalizedText: envelope.normalizedText,
                    editOrVersionIdentifier: envelope.editOrVersionIdentifier,
                    sourceHash: envelope.sourceHash,
                    paginationReceipt: receipt,
                    provenance: try .init(
                        sourceSystem: VaultProviderKind.localImport.rawValue,
                        sourceContainerIdentifier: "attached-table",
                        sourceURL: nil,
                        retrievedAt: envelope.ingestionTimestamp,
                        policyBasis: "explicit_attached_source_selection"
                    ),
                    policyClassification: .localIndexAllowed
                )
                return try .init(
                    envelope: attached,
                    title: "Synthetic attached record"
                )
            }
        )
    }

    private func envelope(
        text: String,
        version: String,
        deletionState: ConnectorRecordDeletionState = .available,
        remoteRecordIdentifier: String = "message-fixture",
        containerIdentifier: String = "channel-fixture",
        ingestionTimestamp: Date? = nil,
        pageOrdinal: Int = 0,
        attachments: [ConnectorAttachmentMetadata] = []
    ) throws -> ConnectorRecordEnvelope {
        let normalized = ConnectorTextNormalization.text(text)
        let receipt = try ConnectorPaginationReceipt(
            checkpointIdentifier: "checkpoint-fixture",
            streamIdentifier: containerIdentifier,
            pageOrdinal: pageOrdinal,
            requestCursor: nil,
            nextCursor: nil,
            sourceHighWatermark: remoteRecordIdentifier,
            isComplete: true
        )
        return try .init(
            provider: "discord",
            pseudonymousAccountIdentifier: "guild-fixture",
            remoteRecordIdentifier: remoteRecordIdentifier,
            recordType: "message",
            parentOrThreadIdentifier: "thread-fixture",
            sourceTimestamp: anchor,
            ingestionTimestamp: ingestionTimestamp
                ?? anchor.addingTimeInterval(1),
            normalizedText: normalized,
            attachments: attachments,
            deletionState: deletionState,
            editOrVersionIdentifier: version,
            sourceHash: ConnectorEnvelopeDigest.sha256(Data(normalized.utf8)),
            paginationReceipt: receipt,
            provenance: try .init(
                sourceSystem: "discord",
                sourceContainerIdentifier: containerIdentifier,
                sourceURL: URL(string: "https://discord.com/channels/guild-fixture/\(containerIdentifier)/\(remoteRecordIdentifier)"),
                retrievedAt: ingestionTimestamp
                    ?? anchor.addingTimeInterval(1),
                policyBasis: "explicit_guild_channel_allowlist"
            ),
            policyClassification: .localIndexAllowed
        )
    }
}
