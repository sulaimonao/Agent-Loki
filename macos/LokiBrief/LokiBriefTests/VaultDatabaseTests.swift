import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import LokiBrief

private actor VaultTestCredentialStore: SlackCredentialStoring {
    func create(_ credential: SlackOAuthCredential) async throws { }
    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        throw SlackCredentialStoreFailure(code: .notFound)
    }
    func replace(_ credential: SlackOAuthCredential) async throws { }
    func delete(teamID: String, userID: String) async throws { }
}

private actor VaultScheduledCommitGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor VaultUpdatePreparationGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

final class VaultDatabaseTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_785_000_000)

    @MainActor
    func testUpdatePreparationBarrierRejectsNewWorkBeforeSuspendedCloseAndRecovers() async throws {
        let fixture = temporaryDatabase(named: "update-preparation-barrier")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: VaultTestCredentialStore()
        )
        let gate = VaultUpdatePreparationGate()
        let controller = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: fixture.database,
            updatePreparationCheckpoint: { await gate.arriveAndWait() }
        )

        let preparation = Task { await controller.prepareForUpdateInstall() }
        await gate.waitUntilArrived()

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let databaseOpenWhilePreparationIsSuspended = await controller.database.isOpen()
        XCTAssertTrue(databaseOpenWhilePreparationIsSuspended)
        XCTAssertFalse(controller.beginForegroundDatabaseOperation())
        await controller.bootstrap()
        XCTAssertFalse(controller.isReconciling)
        let deletionDuringPreparation = await controller.deleteAllVaultData()
        XCTAssertFalse(deletionDuringPreparation)

        await gate.release()
        let preparationFailure = await preparation.value
        XCTAssertNil(preparationFailure)
        let databaseOpenAfterPreparation = await controller.database.isOpen()
        XCTAssertFalse(databaseOpenAfterPreparation)

        let recoverySucceeded = await controller.resumeAfterUpdateInstallAbort()
        XCTAssertTrue(recoverySucceeded)
        let databaseOpenAfterRecovery = await controller.database.isOpen()
        XCTAssertTrue(databaseOpenAfterRecovery)
        XCTAssertTrue(controller.beginForegroundDatabaseOperation())
        controller.endForegroundDatabaseOperation()
        try await controller.database.close()
    }

    @MainActor
    func testDeleteAllRejectsExistingAndNewForegroundDatabaseOperations() async throws {
        let fixture = temporaryDatabase(named: "delete-all-foreground-barrier")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: VaultTestCredentialStore()
        )
        let gate = VaultUpdatePreparationGate()
        let controller = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: fixture.database,
            deletionCheckpoint: { await gate.arriveAndWait() }
        )

        XCTAssertTrue(controller.beginForegroundDatabaseOperation())
        let deletionWhileForegroundActive = await controller.deleteAllVaultData()
        XCTAssertFalse(deletionWhileForegroundActive)
        controller.endForegroundDatabaseOperation()

        let deletion = Task { await controller.deleteAllVaultData() }
        await gate.waitUntilArrived()
        XCTAssertTrue(controller.deletionInProgress)
        XCTAssertFalse(controller.beginForegroundDatabaseOperation())
        await controller.search(text: "must-not-enter")
        XCTAssertTrue(controller.deletionInProgress)

        await gate.release()
        let deletionSucceeded = await deletion.value
        XCTAssertTrue(deletionSucceeded)
        let databaseOpen = await controller.database.isOpen()
        XCTAssertFalse(databaseOpen)
    }

    func testCreateReopenPragmasSchemaPermissionsAndIntegrity() async throws {
        let fixture = temporaryDatabase(named: "create-reopen")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let created = try VaultDatabase(url: fixture.database)
        let createdDisposition = await created.openDisposition
        XCTAssertEqual(createdDisposition, .created(schemaVersion: VaultLimits.schemaVersion))

        let diagnostics = try await created.diagnostics()
        XCTAssertEqual(diagnostics.schemaVersion, VaultLimits.schemaVersion)
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal")
        XCTAssertTrue(diagnostics.foreignKeysEnabled)
        XCTAssertEqual(diagnostics.synchronousLevel, 2)
        XCTAssertTrue(diagnostics.secureDeleteEnabled)
        XCTAssertEqual(diagnostics.busyTimeoutMilliseconds, Int(VaultLimits.busyTimeoutMilliseconds))
        XCTAssertTrue(Self.requiredTables.isSubset(of: diagnostics.requiredTables))

        let integrity = try await created.integrityCheck()
        XCTAssertTrue(integrity.sqliteIntegrityOK)
        XCTAssertTrue(integrity.foreignKeysOK)
        XCTAssertTrue(integrity.ftsIntegrityOK)
        XCTAssertEqual(integrity.recoveryClassification, .healthy)

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o077, 0)
        try await created.close()

        let reopened = try VaultDatabase(url: fixture.database)
        let reopenedDisposition = await reopened.openDisposition
        XCTAssertEqual(reopenedDisposition, .opened(schemaVersion: VaultLimits.schemaVersion))
        let reopenedDiagnostics = try await reopened.diagnostics()
        XCTAssertEqual(reopenedDiagnostics.schemaVersion, VaultLimits.schemaVersion)
        try await reopened.close()
    }

    func testRecordRoundTripDedupRevisionBoundAndPreparedStatementPayloads() async throws {
        let fixture = temporaryDatabase(named: "record-round-trip")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let scope = try await installScope(in: database, suffix: "one")

        let original = record(
            id: "record-1",
            scope: scope,
            body: "A quoted value ' survives; SQL text -- is inert.",
            metadata: ["z": "last", "a": "first"],
            directlyMentionsUser: true,
            isRead: true,
            contentOrigin: .generated,
            threadRootID: "thread-1",
            replyCount: 3
        )
        let inserted = try await database.upsert(record: original)
        XCTAssertEqual(inserted.disposition, .inserted)
        XCTAssertEqual(inserted.revision, 1)

        let unchanged = try await database.upsert(record: original)
        XCTAssertEqual(unchanged.disposition, .unchanged)
        XCTAssertEqual(unchanged.contentChecksum, inserted.contentChecksum)
        let unchangedRevisions = try await database.revisions(recordID: original.id)
        XCTAssertTrue(unchangedRevisions.isEmpty)

        for revision in 2...13 {
            let updated = record(
                id: original.id,
                scope: scope,
                body: "revision-\(revision)",
                modifiedAt: Self.anchor.addingTimeInterval(TimeInterval(revision)),
                metadata: ["revision": String(revision)]
            )
            let result = try await database.upsert(record: updated)
            XCTAssertEqual(result.disposition, .updated)
            XCTAssertEqual(result.revision, revision)
        }

        let storedRecord = try await database.record(id: original.id)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.body, "revision-13")
        XCTAssertEqual(stored.revision, 13)
        XCTAssertEqual(stored.provider, "slack")
        XCTAssertEqual(stored.contentOrigin, .source)
        let revisions = try await database.revisions(recordID: original.id)
        XCTAssertEqual(revisions.count, VaultLimits.maximumRevisionsPerItem)
        XCTAssertEqual(revisions.map(\.revision), Array(3...12))
        XCTAssertEqual(Set(revisions.map(\.contentChecksum)).count, revisions.count)
        try await database.close()
    }

    func testAttachedSearchProjectsSQLiteRowAndJSONPointerProvenanceWithoutRawMetadata()
        async throws
    {
        let fixture = temporaryDatabase(named: "attached-provenance")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let sourceID = "attached-source-provenance"
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID
        )
        _ = try await database.upsert(account: .init(
            id: accountID,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            displayName: "Attached provenance fixture",
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        ))

        let sourceDigest = String(repeating: "a", count: 64)
        let schemaDigest = String(repeating: "b", count: 64)
        let generationReceipt = String(repeating: "c", count: 64)
        let pageReceipt = String(repeating: "d", count: 64)
        let privatePath = ["", "Users", "private", "Documents", "secret.sqlite"]
            .joined(separator: "/")
        let cases: [(
            selectionID: String,
            selectionSource: String,
            stableID: String,
            locator: String,
            kind: String,
            identity: String
        )] = [
            (
                "selection-sqlite",
                "tasks",
                "task_id=42",
                "tasks",
                "sqlite",
                "declared_primary_key"
            ),
            (
                "selection-json",
                "/items",
                "json-id-7",
                "/items/7",
                "json",
                "explicit_json_id"
            ),
        ]
        for (index, item) in cases.enumerated() {
            let containerID = VaultIdentity.containerID(
                provider: VaultProviderKind.localImport.rawValue,
                accountID: accountID,
                providerContainerID: item.selectionID
            )
            _ = try await database.upsert(container: .init(
                id: containerID,
                accountID: accountID,
                providerContainerID: item.selectionID,
                kind: VaultContainerKind.importedCollection.rawValue,
                displayName: "Selection \(index)",
                createdAt: Self.anchor,
                updatedAt: Self.anchor
            ))
            _ = try await database.upsert(record: .init(
                id: "attached-provenance-\(index)",
                accountID: accountID,
                containerID: containerID,
                providerRecordID: item.stableID,
                kind: "attached_\(item.kind)_record",
                title: "Attached citation \(index)",
                body: "bounded attached citation fixture",
                occurredAt: Self.anchor,
                capturedAt: Self.anchor,
                modifiedAt: Self.anchor,
                metadata: [
                    "attached_source_id": sourceID,
                    "attached_source_kind": item.kind,
                    "attached_source_epoch": "3",
                    "attached_source_sha256": sourceDigest,
                    "attached_selection_id": item.selectionID,
                    "attached_selection_source": item.selectionSource,
                    "attached_schema_sha256": schemaDigest,
                    "attached_record_locator": item.locator,
                    "attached_identity_strategy": item.identity,
                    "attached_generation_id": "generation:3:fixture",
                    "attached_generation_receipt_sha256": generationReceipt,
                    "connector_page_receipt_sha256": pageReceipt,
                    "attached_truncated": index == 0 ? "false" : "true",
                    "private_source_path": privatePath,
                ]
            ))
        }

        let response = try await database.search(.init(
            text: "citation fixture",
            accountID: accountID,
            limit: 10,
            preference: .likeOnly
        ))
        XCTAssertEqual(response.results.count, 2)
        let projections = response.results.compactMap(
            \.attachedSourceProvenance
        )
        XCTAssertEqual(projections.count, 2)
        let sqlite = try XCTUnwrap(
            projections.first(where: { $0.sourceKind == "sqlite" })
        )
        XCTAssertEqual(sqlite.selectionSourceIdentifier, "tasks")
        XCTAssertEqual(sqlite.stableRecordIdentifier, "task_id=42")
        XCTAssertEqual(sqlite.recordLocator, "tasks")
        XCTAssertEqual(sqlite.sourceEpoch, 3)
        XCTAssertFalse(sqlite.wasTruncated)
        let json = try XCTUnwrap(
            projections.first(where: { $0.sourceKind == "json" })
        )
        XCTAssertEqual(json.selectionSourceIdentifier, "/items")
        XCTAssertEqual(json.recordLocator, "/items/7")
        XCTAssertEqual(json.stableRecordIdentifier, "json-id-7")
        XCTAssertTrue(json.wasTruncated)

        let encoded = String(
            decoding: try JSONEncoder().encode(response),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains(privatePath))
        XCTAssertFalse(encoded.contains("private_source_path"))
        try await database.close()
    }

    func testBatchFailureRollsBackEveryRecord() async throws {
        let fixture = temporaryDatabase(named: "transaction-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let scope = try await installScope(in: database, suffix: "rollback")
        let valid = record(id: "valid-before-failure", scope: scope, body: "must roll back")
        let invalidScope = Scope(accountID: scope.accountID, containerID: "missing-container")
        let invalid = record(id: "invalid-scope", scope: invalidScope, body: "cannot persist")

        do {
            _ = try await database.upsert(records: [valid, invalid])
            XCTFail("Expected the missing container to fail the transaction")
        } catch let failure as VaultDatabaseFailure {
            XCTAssertEqual(failure.reasonCode, "vault_record_scope_not_found")
        }

        let validAfterRollback = try await database.record(id: valid.id)
        let invalidAfterRollback = try await database.record(id: invalid.id)
        let summaryAfterRollback = try await database.storageSummary()
        XCTAssertNil(validAfterRollback)
        XCTAssertNil(invalidAfterRollback)
        XCTAssertEqual(summaryAfterRollback.recordCount, 0)
        try await database.close()
    }

    func testTombstonePurgesPriorContentAndResurrectionClearsTombstone() async throws {
        let fixture = temporaryDatabase(named: "tombstone-resurrection")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let scope = try await installScope(in: database, suffix: "tombstone")
        let item = record(id: "deleted-record", scope: scope, body: "private prior content")
        _ = try await database.upsert(record: item)

        let tombstoneResult = try await database.tombstone(
            recordID: item.id,
            reason: .sourceDeleted,
            deletedAt: Self.anchor.addingTimeInterval(60)
        )
        let tombstone = try XCTUnwrap(tombstoneResult)
        XCTAssertTrue(tombstone.priorContentPurged)
        let deletedRecord = try await database.record(id: item.id)
        let deletedRevisions = try await database.revisions(recordID: item.id)
        let storedTombstones = try await database.tombstones(accountID: scope.accountID)
        XCTAssertNil(deletedRecord)
        XCTAssertTrue(deletedRevisions.isEmpty)
        XCTAssertEqual(storedTombstones, [tombstone])

        let resurrected = try await database.upsert(record: record(
            id: item.id,
            scope: scope,
            body: "authorized source content returned"
        ))
        XCTAssertEqual(resurrected.disposition, .resurrected)
        let resurrectedRecord = try await database.record(id: item.id)
        let tombstonesAfterResurrection = try await database.tombstones(accountID: scope.accountID)
        XCTAssertNotNil(resurrectedRecord)
        XCTAssertTrue(tombstonesAfterResurrection.isEmpty)
        try await database.close()
    }

    func testStandaloneBackfillTombstonePreservesTruthAndCanResurrect() async throws {
        let fixture = temporaryDatabase(named: "standalone-backfill-tombstone")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let backfill = backfillFixture(
            jobID: "standalone-tombstone-job",
            accountID: "workspace-tombstone",
            sourceID: "channel-tombstone",
            itemID: "standalone-tombstone",
            isTombstone: true
        )

        _ = try await database.commit(job: backfill.job, checkpoint: backfill.checkpoint, items: [backfill.item])
        let archiveAccountID = VaultIdentity.accountID(provider: "slack", providerAccountID: "workspace-tombstone")
        let archiveContainerID = VaultIdentity.containerID(
            provider: "slack",
            accountID: archiveAccountID,
            providerContainerID: "channel-tombstone"
        )
        let tombstones = try await database.tombstones(accountID: archiveAccountID)
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertFalse(try XCTUnwrap(tombstones.first).priorContentPurged, "No prior content existed to purge.")
        let missingRecord = try await database.record(id: backfill.item.id)
        XCTAssertNil(missingRecord)

        let resurrected = try await database.upsert(record: record(
            id: backfill.item.id,
            scope: .init(accountID: archiveAccountID, containerID: archiveContainerID),
            body: "Source content became available later."
        ))
        XCTAssertEqual(resurrected.disposition, .resurrected)
        let tombstonesAfterResurrection = try await database.tombstones(accountID: archiveAccountID)
        XCTAssertTrue(tombstonesAfterResurrection.isEmpty)
        let integrity = try await database.integrityCheck()
        XCTAssertTrue(integrity.sqliteIntegrityOK)
        XCTAssertTrue(integrity.foreignKeysOK)
        try await database.close()
    }

    func testScopeTriggersRejectCrossAccountChildren() async throws {
        let fixture = temporaryDatabase(named: "scope-triggers")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = try await installScope(in: database, suffix: "scope-first")
        let second = try await installScope(in: database, suffix: "scope-second")

        XCTAssertThrowsError(try executeSQL(
            at: fixture.database,
            sql: "INSERT INTO vault_sync_cursors(account_id, container_id, direction, exhausted) VALUES('\(first.accountID)', '\(second.containerID)', 'historical', 0)"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("vault_scope_mismatch"))
        }
        try executeSQL(
            at: fixture.database,
            sql: "INSERT INTO vault_sync_cursors(account_id, container_id, direction, exhausted) VALUES('\(first.accountID)', '\(first.containerID)', 'historical', 0)"
        )
        XCTAssertEqual(try scalarInt(
            at: fixture.database,
            sql: "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'vault_%_scope_%'"
        ), 8)
        let integrity = try await database.integrityCheck()
        XCTAssertTrue(integrity.foreignKeysOK)
        try await database.close()
    }

    func testAccountDeletionRemovesOnlyMatchingBackfillJobs() async throws {
        let fixture = temporaryDatabase(named: "account-backfill-job-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = backfillFixture(
            jobID: "first-account-job",
            accountID: "workspace-first",
            sourceID: "channel-first",
            itemID: "first-account-item"
        )
        let second = backfillFixture(
            jobID: "second-account-job",
            accountID: "workspace-second",
            sourceID: "channel-second",
            itemID: "second-account-item"
        )
        _ = try await database.commit(job: first.job, checkpoint: first.checkpoint, items: [first.item])
        _ = try await database.commit(job: second.job, checkpoint: second.checkpoint, items: [second.item])

        let deletedAccountID = VaultIdentity.accountID(provider: "slack", providerAccountID: "workspace-first")
        _ = try await database.deleteAccount(id: deletedAccountID)
        let deletedJob = try await database.load(jobID: first.job.id)
        let preservedJob = try await database.load(jobID: second.job.id)
        let remainingJobIDs = try await database.backfillRuns().map(\.job.id)
        let remainingAccountIDs = try await database.accounts().map(\.id)
        XCTAssertNil(deletedJob)
        XCTAssertEqual(preservedJob?.job.id, second.job.id)
        XCTAssertEqual(remainingJobIDs, [second.job.id])
        let preservedAccountID = VaultIdentity.accountID(provider: "slack", providerAccountID: "workspace-second")
        XCTAssertEqual(remainingAccountIDs, [preservedAccountID])
        try await database.close()
    }

    func testAccountAndContainerDeletionPreserveUnrelatedScopes() async throws {
        let fixture = temporaryDatabase(named: "scope-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = try await installScope(in: database, suffix: "first")
        let second = try await installScope(in: database, suffix: "second")
        let firstItem = record(id: "first-item", scope: first, body: "first")
        let secondItem = record(id: "second-item", scope: second, body: "second")
        _ = try await database.upsert(records: [firstItem, secondItem])
        _ = try await database.upsert(record: record(id: firstItem.id, scope: first, body: "first edited"))

        let deletedContainer = try await database.deleteContainer(id: first.containerID)
        XCTAssertEqual(deletedContainer.accountsDeleted, 0)
        XCTAssertEqual(deletedContainer.containersDeleted, 1)
        XCTAssertEqual(deletedContainer.recordsDeleted, 1)
        XCTAssertEqual(deletedContainer.revisionsDeleted, 1)
        let deletedFirstRecord = try await database.record(id: firstItem.id)
        let preservedSecondRecord = try await database.record(id: secondItem.id)
        XCTAssertNil(deletedFirstRecord)
        XCTAssertEqual(preservedSecondRecord?.body, "second")

        let deletedAccount = try await database.deleteAccount(id: second.accountID)
        XCTAssertEqual(deletedAccount.accountsDeleted, 1)
        XCTAssertEqual(deletedAccount.recordsDeleted, 1)
        let summary = try await database.storageSummary()
        XCTAssertEqual(summary.recordCount, 0)
        XCTAssertEqual(summary.accountCount, 1, "Deleting the second account must preserve the first account metadata.")
        try await database.close()
    }

    func testMigrationIsIdempotentAndPreservesExistingContent() async throws {
        let fixture = temporaryDatabase(named: "migration")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var database: VaultDatabase? = try VaultDatabase(url: fixture.database)
        let scope = try await installScope(in: try XCTUnwrap(database), suffix: "migration")
        let item = record(id: "migration-record", scope: scope, body: "preserved")
        _ = try await database?.upsert(record: item)
        try await database?.close()
        database = nil

        try executeSQL(at: fixture.database, sql: "PRAGMA user_version = 1")
        let migrated = try VaultDatabase(url: fixture.database)
        let migratedDisposition = await migrated.openDisposition
        XCTAssertEqual(migratedDisposition, .migrated(from: 1, to: VaultLimits.schemaVersion))
        let migratedRecord = try await migrated.record(id: item.id)
        XCTAssertEqual(migratedRecord?.body, "preserved")
        try await migrated.close()

        let reopened = try VaultDatabase(url: fixture.database)
        let reopenedDisposition = await reopened.openDisposition
        XCTAssertEqual(reopenedDisposition, .opened(schemaVersion: VaultLimits.schemaVersion))
        let reopenedRecord = try await reopened.record(id: item.id)
        XCTAssertEqual(reopenedRecord?.body, "preserved")
        try await reopened.close()
    }

    func testMalformedAndNewerSchemaArchivesAreNotDestructivelyReplaced() throws {
        let malformed = temporaryDatabase(named: "malformed")
        defer { try? FileManager.default.removeItem(at: malformed.directory) }
        try FileManager.default.createDirectory(at: malformed.directory, withIntermediateDirectories: true)
        let sentinel = Data("not-a-sqlite-database-private-sentinel".utf8)
        try sentinel.write(to: malformed.database)

        XCTAssertThrowsError(try VaultDatabase(url: malformed.database)) { error in
            let failure = error as? VaultDatabaseFailure
            XCTAssertEqual(failure?.recoveryClassification, .corruptionPreserveOriginal)
        }
        XCTAssertEqual(try Data(contentsOf: malformed.database), sentinel)

        let newer = temporaryDatabase(named: "newer-schema")
        defer { try? FileManager.default.removeItem(at: newer.directory) }
        try FileManager.default.createDirectory(at: newer.directory, withIntermediateDirectories: true)
        try executeSQL(
            at: newer.database,
            sql: "CREATE TABLE preservation_sentinel(value TEXT NOT NULL); INSERT INTO preservation_sentinel VALUES('keep'); PRAGMA user_version = 999"
        )
        XCTAssertThrowsError(try VaultDatabase(url: newer.database)) { error in
            let failure = error as? VaultDatabaseFailure
            XCTAssertEqual(failure?.recoveryClassification, .unsupportedNewerSchemaPreserveOriginal)
        }
        XCTAssertEqual(try scalarText(at: newer.database, sql: "SELECT value FROM preservation_sentinel"), "keep")
        XCTAssertEqual(try scalarInt(at: newer.database, sql: "PRAGMA user_version"), 999)
    }

    @MainActor
    func testScheduledReconciliationFiltersEvidenceToPlanScope() async throws {
        let fixture = temporaryDatabase(named: "scheduled-plan-scope")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "feed-in-plan", entryIDs: ["selected"])
        try seedScheduledFeedEvidence(store, subscriptionID: "feed-outside-plan", entryIDs: ["excluded"])
        try seedScheduledSlackEvidence(store, workspaceID: "workspace-in-plan", evidenceID: "selected")
        try seedScheduledSlackEvidence(store, workspaceID: "workspace-outside-plan", evidenceID: "excluded")
        let controller = try makeScheduledVaultController(store: store, databaseURL: fixture.database)
        let plan = try scheduledPlan(
            feedSubscriptionIDs: ["feed-in-plan"],
            slackWorkspaceIDs: ["workspace-in-plan"]
        )
        let ledger = ScheduledBriefingBudgetLedger(budget: plan.budget)

        let outcome = await controller.reconcileScheduledEvidence(plan: plan, budget: ledger)
        let selectedFeed = try await controller.database.record(id: "rss:feed-in-plan-selected")
        let excludedFeed = try await controller.database.record(id: "rss:feed-outside-plan-excluded")
        let selectedSlack = try await controller.database.record(id: "slack:selected")
        let excludedSlack = try await controller.database.record(id: "slack:excluded")

        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.changedItemCount, 2)
        XCTAssertNotNil(selectedFeed)
        XCTAssertNil(excludedFeed)
        XCTAssertNotNil(selectedSlack)
        XCTAssertNil(excludedSlack)
        try await controller.database.close()
    }

    @MainActor
    func testScheduledReconciliationResumesAtCommittedPrefixAcrossItemBudgets() async throws {
        let fixture = temporaryDatabase(named: "scheduled-item-budget")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "bounded-feed", entryIDs: ["a", "b", "c"])
        let controller = try makeScheduledVaultController(store: store, databaseURL: fixture.database)
        let boundedBudget = ScheduledBriefingBudget(
            maximumNewArchiveItems: 1,
            maximumStorageGrowthBytes: 1_000_000
        )
        let plan = try scheduledPlan(feedSubscriptionIDs: ["bounded-feed"], budget: boundedBudget)

        let firstLedger = ScheduledBriefingBudgetLedger(budget: plan.budget)
        let first = await controller.reconcileScheduledEvidence(plan: plan, budget: firstLedger)
        let second = await controller.reconcileScheduledEvidence(
            plan: plan,
            budget: ScheduledBriefingBudgetLedger(budget: plan.budget)
        )
        let third = await controller.reconcileScheduledEvidence(
            plan: plan,
            budget: ScheduledBriefingBudgetLedger(budget: plan.budget)
        )
        let firstUsage = await firstLedger.usage()
        let storedA = try await controller.database.record(id: "rss:bounded-feed-a")
        let storedB = try await controller.database.record(id: "rss:bounded-feed-b")
        let storedC = try await controller.database.record(id: "rss:bounded-feed-c")

        XCTAssertEqual(first.status, .degraded)
        XCTAssertEqual(first.changedItemCount, 1)
        XCTAssertEqual(first.reasonCodes, [ScheduledBriefingBudgetReason.archiveItemsExhausted])
        XCTAssertEqual(second.status, .degraded)
        XCTAssertEqual(second.changedItemCount, 1)
        XCTAssertEqual(second.reasonCodes, [ScheduledBriefingBudgetReason.archiveItemsExhausted])
        XCTAssertEqual(third.status, .success)
        XCTAssertEqual(third.changedItemCount, 1)
        XCTAssertEqual(firstUsage.archiveItemCount, 1)
        XCTAssertGreaterThan(firstUsage.archiveStorageBytes, 0)
        XCTAssertNotNil(storedA)
        XCTAssertNotNil(storedB)
        XCTAssertNotNil(storedC)
        try await controller.database.close()
    }

    @MainActor
    func testScheduledStorageBudgetRejectsBeforeAnyArchiveScopeOrRecordWrite() async throws {
        let fixture = temporaryDatabase(named: "scheduled-storage-budget")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "storage-feed", entryIDs: ["too-large"])
        let controller = try makeScheduledVaultController(store: store, databaseURL: fixture.database)
        let boundedBudget = ScheduledBriefingBudget(
            maximumNewArchiveItems: 10,
            maximumStorageGrowthBytes: 0
        )
        let plan = try scheduledPlan(feedSubscriptionIDs: ["storage-feed"], budget: boundedBudget)
        let ledger = ScheduledBriefingBudgetLedger(budget: plan.budget)

        let outcome = await controller.reconcileScheduledEvidence(plan: plan, budget: ledger)
        let record = try await controller.database.record(id: "rss:storage-feed-too-large")
        let accounts = try await controller.database.accounts()
        let containers = try await controller.database.containers()

        XCTAssertEqual(outcome.status, .degraded)
        XCTAssertEqual(outcome.changedItemCount, 0)
        XCTAssertEqual(outcome.reasonCodes, [ScheduledBriefingBudgetReason.archiveStorageExhausted])
        XCTAssertNil(record)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(containers.isEmpty)
        try await controller.database.close()
    }

    @MainActor
    func testScheduledCompleteUnchangedBatchConsumesNoFuturePermit() async throws {
        let fixture = temporaryDatabase(named: "scheduled-unchanged")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "unchanged-feed", entryIDs: ["one"])
        let controller = try makeScheduledVaultController(store: store, databaseURL: fixture.database)
        let initialPlan = try scheduledPlan(feedSubscriptionIDs: ["unchanged-feed"])
        let initial = await controller.reconcileScheduledEvidence(
            plan: initialPlan,
            budget: ScheduledBriefingBudgetLedger(budget: initialPlan.budget)
        )
        let zeroItemBudget = ScheduledBriefingBudget(maximumNewArchiveItems: 0)
        let repeatPlan = try scheduledPlan(feedSubscriptionIDs: ["unchanged-feed"], budget: zeroItemBudget)
        let repeatLedger = ScheduledBriefingBudgetLedger(budget: repeatPlan.budget)

        let repeated = await controller.reconcileScheduledEvidence(plan: repeatPlan, budget: repeatLedger)
        let repeatedUsage = await repeatLedger.usage()

        XCTAssertEqual(initial.status, .success)
        XCTAssertEqual(initial.changedItemCount, 1)
        XCTAssertEqual(repeated.status, .success)
        XCTAssertEqual(repeated.changedItemCount, 0)
        XCTAssertEqual(repeated.reasonCodes, ["scheduled_vault_reconciliation_no_new_evidence"])
        XCTAssertEqual(repeatedUsage.archiveItemCount, 0)
        XCTAssertTrue(repeatedUsage.exhaustionReasonCodes.isEmpty)
        try await controller.database.close()
    }

    @MainActor
    func testScheduledChangedFingerprintReplayChargesOnlyNewEvidence() async throws {
        let fixture = temporaryDatabase(named: "scheduled-changed-fingerprint")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "growing-feed", entryIDs: ["a"])
        let controller = try makeScheduledVaultController(store: store, databaseURL: fixture.database)
        let initialPlan = try scheduledPlan(feedSubscriptionIDs: ["growing-feed"])
        let initial = await controller.reconcileScheduledEvidence(
            plan: initialPlan,
            budget: ScheduledBriefingBudgetLedger(budget: initialPlan.budget)
        )
        try seedScheduledFeedEvidence(store, subscriptionID: "growing-feed", entryIDs: ["a", "b"])
        let replayBudget = ScheduledBriefingBudget(
            maximumNewArchiveItems: 1,
            maximumStorageGrowthBytes: 1_000_000
        )
        let replayPlan = try scheduledPlan(feedSubscriptionIDs: ["growing-feed"], budget: replayBudget)
        let replayLedger = ScheduledBriefingBudgetLedger(budget: replayPlan.budget)

        let replay = await controller.reconcileScheduledEvidence(plan: replayPlan, budget: replayLedger)
        let usage = await replayLedger.usage()
        let storedA = try await controller.database.record(id: "rss:growing-feed-a")
        let storedB = try await controller.database.record(id: "rss:growing-feed-b")

        XCTAssertEqual(initial.status, .success)
        XCTAssertEqual(initial.changedItemCount, 1)
        XCTAssertEqual(replay.status, .success)
        XCTAssertEqual(replay.changedItemCount, 1)
        XCTAssertEqual(replay.reasonCodes, ["scheduled_vault_reconciliation_complete"])
        XCTAssertEqual(usage.archiveItemCount, 1)
        XCTAssertGreaterThan(usage.archiveStorageBytes, 0)
        XCTAssertTrue(usage.exhaustionReasonCodes.isEmpty)
        XCTAssertNotNil(storedA)
        XCTAssertNotNil(storedB)
        try await controller.database.close()
    }

    @MainActor
    func testScheduledCancellationAfterRecordCommitCannotRecreateDeletedCheckpointState() async throws {
        let fixture = temporaryDatabase(named: "scheduled-post-commit-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalStore(inMemory: true)
        try seedScheduledFeedEvidence(store, subscriptionID: "cancelled-feed", entryIDs: ["committed"])
        let gate = VaultScheduledCommitGate()
        let controller = try makeScheduledVaultController(
            store: store,
            databaseURL: fixture.database,
            scheduledRecordCommitBoundary: { await gate.arriveAndWait() }
        )
        let plan = try scheduledPlan(feedSubscriptionIDs: ["cancelled-feed"])
        let ledger = ScheduledBriefingBudgetLedger(budget: plan.budget)
        let run = Task {
            await controller.reconcileScheduledEvidence(plan: plan, budget: ledger)
        }

        await gate.waitUntilArrived()
        controller.cancelScheduledReconciliation()
        try store.deleteAllLocalData()
        await gate.release()
        let outcome = await run.value
        let committedRecord = try await controller.database.record(id: "rss:cancelled-feed-committed")
        let checkpoints = try store.container.mainContext.fetch(FetchDescriptor<StoredVaultImportCheckpoint>())
        let accounts = try store.container.mainContext.fetch(FetchDescriptor<StoredVaultAccount>())
        let containers = try store.container.mainContext.fetch(FetchDescriptor<StoredVaultContainer>())

        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.changedItemCount, 0)
        XCTAssertNotNil(committedRecord, "The gate must suspend after the archive transaction committed.")
        XCTAssertTrue(checkpoints.isEmpty, "A late result must not recreate checkpoint state after Delete All.")
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(containers.isEmpty)
        try await controller.database.close()
    }

    private struct Scope {
        let accountID: String
        let containerID: String
    }

    private static let requiredTables: Set<String> = [
        "vault_schema_migrations", "vault_features", "vault_accounts",
        "vault_connector_generations", "vault_containers",
        "vault_records", "vault_revisions", "vault_tombstones", "vault_participants",
        "vault_item_participants", "vault_provenance", "vault_sync_cursors", "vault_sync_runs",
        "vault_backfill_jobs", "vault_storage_statistics",
    ]

    private func installScope(in database: VaultDatabase, suffix: String) async throws -> Scope {
        let accountID = "account-\(suffix)"
        let containerID = "container-\(suffix)"
        _ = try await database.upsert(account: .init(
            id: accountID,
            provider: "slack",
            providerAccountID: "provider-account-\(suffix)",
            displayName: "Workspace \(suffix)",
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        ))
        _ = try await database.upsert(container: .init(
            id: containerID,
            accountID: accountID,
            providerContainerID: "provider-container-\(suffix)",
            kind: "channel",
            displayName: "Channel \(suffix)",
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        ))
        return .init(accountID: accountID, containerID: containerID)
    }

    @MainActor
    private func makeScheduledVaultController(
        store: LocalStore,
        databaseURL: URL,
        scheduledRecordCommitBoundary: (@MainActor @Sendable () async -> Void)? = nil
    ) throws -> VaultController {
        let slackController = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: VaultTestCredentialStore()
        )
        return try VaultController(
            store: store,
            slackController: slackController,
            databaseURL: databaseURL,
            scheduledRecordCommitBoundary: scheduledRecordCommitBoundary
        )
    }

    private func scheduledPlan(
        feedSubscriptionIDs: [String],
        slackWorkspaceIDs: [String] = [],
        budget: ScheduledBriefingBudget = .init()
    ) throws -> ScheduledBriefingPlan {
        try ScheduledBriefingPlan(
            id: "scheduled-vault-plan",
            occurrenceID: "scheduled-vault-occurrence",
            scheduledFor: Self.anchor,
            trigger: .scheduled,
            feedSubscriptionIDs: feedSubscriptionIDs,
            slackWorkspaceIDs: slackWorkspaceIDs,
            refreshFeedsEnabled: true,
            refreshSlackEnabled: true,
            slackSelections: slackWorkspaceIDs.map { .init(workspaceID: $0, channelIDs: []) },
            localPresentationEnabled: false,
            localPresentationConsentedWorkspaceIDs: [],
            notificationsEnabled: false,
            notificationAuthorization: .notDetermined,
            notificationPrivacyMode: .minimal,
            entitlementDecisions: [],
            budget: budget
        )
    }

    @MainActor
    private func seedScheduledFeedEvidence(
        _ store: LocalStore,
        subscriptionID: String,
        entryIDs: [String]
    ) throws {
        let feedURL = try XCTUnwrap(URL(string: "https://example.invalid/feeds/\(subscriptionID).xml"))
        let subscription = FeedSubscription(
            id: subscriptionID,
            title: "Scheduled \(subscriptionID)",
            canonicalURL: feedURL,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: Self.anchor,
            lastSuccessfulAt: Self.anchor,
            lastHTTPStatus: 200,
            eTag: nil,
            lastModified: nil,
            state: .connected,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        )
        let entries = entryIDs.enumerated().map { offset, entryID in
            let recordID = "\(subscriptionID)-\(entryID)"
            let itemURL = URL(string: "https://example.invalid/items/\(recordID)")!
            return NormalizedFeedEntry(
                id: recordID,
                identity: .init(value: recordID, basis: .upstreamIdentifier),
                subscriptionID: subscriptionID,
                sourceTitle: subscription.title,
                title: "Scheduled item \(entryID)",
                summary: "Deterministic scheduled Vault budget evidence \(entryID).",
                canonicalURL: itemURL,
                author: "Vault test fixture",
                publishedAt: Self.anchor.addingTimeInterval(Double(offset)),
                updatedAt: nil,
                retrievedAt: Self.anchor.addingTimeInterval(Double(offset)),
                originalPosition: offset,
                provenance: .init(
                    subscriptionID: subscriptionID,
                    feedURL: feedURL,
                    format: .rss2,
                    upstreamIdentifier: recordID,
                    retrievedAt: Self.anchor.addingTimeInterval(Double(offset)),
                    originalPosition: offset
                )
            )
        }
        try store.persistFeedFetchResult(.init(
            subscription: subscription,
            entries: entries,
            record: .init(
                id: "scheduled-fetch-\(subscriptionID)",
                subscriptionID: subscriptionID,
                traceID: "scheduled-vault-trace",
                attemptedAt: Self.anchor,
                completedAt: Self.anchor,
                httpStatus: 200,
                responseByteCount: 1_024,
                parsedEntryCount: entries.count,
                finalURL: feedURL,
                eTag: nil,
                lastModified: nil,
                wasNotModified: false
            ),
            warnings: []
        ), settings: try store.p2Settings())
    }

    @MainActor
    private func seedScheduledSlackEvidence(
        _ store: LocalStore,
        workspaceID: String,
        evidenceID: String
    ) throws {
        try store.persistSlackEvidence(.init(
            id: evidenceID,
            workspaceID: workspaceID,
            workspaceName: "Scheduled \(workspaceID)",
            channelID: "channel-\(workspaceID)",
            channelName: "scheduled",
            channelKind: .privateChannel,
            messageTimestamp: SlackTimestamp(date: Self.anchor),
            excerpt: "Deterministic scheduled Slack Vault evidence \(evidenceID).",
            author: .init(id: "author", displayName: "Vault test fixture", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: false,
            replyCount: 0,
            isEdited: false,
            editedAt: nil,
            permalink: nil,
            retrievedAt: Self.anchor,
            selectedChannelWeight: 1,
            state: .available
        ))
    }

    private func record(
        id: String,
        scope: Scope,
        body: String,
        modifiedAt: Date = anchor,
        metadata: [String: String] = [:],
        directlyMentionsUser: Bool = false,
        isRead: Bool = false,
        contentOrigin: VaultContentOrigin = .source,
        threadRootID: String? = nil,
        replyCount: Int = 0
    ) -> VaultRecordInput {
        .init(
            id: id,
            accountID: scope.accountID,
            containerID: scope.containerID,
            providerRecordID: "provider-\(id)",
            kind: "message",
            title: "Title \(id)",
            body: body,
            author: "Fixture Author",
            sourceURL: URL(string: "https://example.invalid/items/\(id)"),
            occurredAt: Self.anchor,
            capturedAt: Self.anchor,
            modifiedAt: modifiedAt,
            metadata: metadata,
            directlyMentionsUser: directlyMentionsUser,
            isRead: isRead,
            contentOrigin: contentOrigin,
            providerMetadataVersion: 1,
            threadRootID: threadRootID,
            replyCount: replyCount
        )
    }

    private func backfillFixture(
        jobID: String,
        accountID: String,
        sourceID: String,
        itemID: String,
        isTombstone: Bool = false
    ) -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint, item: VaultBackfillArchiveItem) {
        let source = VaultBackfillSourceCheckpoint(
            id: "\(accountID):\(sourceID)",
            accountID: accountID,
            sourceID: sourceID,
            forwardCursor: "forward-cursor",
            historyCursor: nil,
            historyUpperBound: Self.anchor,
            isHistoryComplete: false,
            failureReasonCode: nil
        )
        let checkpoint = VaultBackfillCheckpoint(sources: [source], updatedAt: Self.anchor)
        let job = VaultBackfillJob(
            id: jobID,
            provider: "slack",
            createdAt: Self.anchor,
            updatedAt: Self.anchor,
            startedAt: Self.anchor,
            finishedAt: nil,
            state: .paused,
            stopReason: .pausedByUser,
            budget: .init(
                maximumRequests: 2,
                maximumItems: 30,
                maximumDuration: 30,
                maximumStorageBytes: 1_000_000,
                maximumRetries: 1
            ),
            nextRetryAt: nil,
            generation: 1,
            failedSourceCount: 0
        )
        let item = VaultBackfillArchiveItem(
            id: itemID,
            provider: "slack",
            accountID: accountID,
            sourceID: sourceID,
            sourceName: "Channel \(sourceID)",
            occurredAt: Self.anchor,
            title: isTombstone ? "" : "Backfill item",
            body: isTombstone ? "" : "Backfill body",
            authorName: isTombstone ? nil : "Fixture Author",
            providerItemID: "provider-\(itemID)",
            isTombstone: isTombstone,
            estimatedStorageBytes: isTombstone ? 0 : 100
        )
        return (job, checkpoint, item)
    }

    private func temporaryDatabase(named name: String) -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-vault-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("loki-vault.sqlite3"))
    }

    private func executeSQL(at url: URL, sql: String) throws {
        var connection: OpaquePointer?
        let open = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard open == SQLITE_OK, let connection else { throw sqliteError(connection, code: open) }
        defer { sqlite3_close_v2(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(connection, code: result) }
    }

    private func scalarText(at url: URL, sql: String) throws -> String {
        try scalar(at: url, sql: sql) { statement in
            guard let value = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: value)
        }
    }

    private func scalarInt(at url: URL, sql: String) throws -> Int {
        try scalar(at: url, sql: sql) { Int(sqlite3_column_int64($0, 0)) }
    }

    private func scalar<T>(at url: URL, sql: String, decode: (OpaquePointer) -> T) throws -> T {
        var connection: OpaquePointer?
        let open = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK, let connection else { throw sqliteError(connection, code: open) }
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw sqliteError(connection, code: prepare) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw sqliteError(connection, code: step) }
        return decode(statement)
    }

    private func sqliteError(_ connection: OpaquePointer?, code: Int32) -> NSError {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable"
        return NSError(domain: "VaultDatabaseTests.SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
