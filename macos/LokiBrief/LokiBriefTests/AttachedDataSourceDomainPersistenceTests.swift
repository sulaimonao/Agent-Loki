import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class AttachedDataSourceDomainPersistenceTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testValidationRejectsUnsafeLocationInvalidAccessAndDuplicateSelectionFields() throws {
        XCTAssertFalse(AttachedDataSourceValidation.privacySafeLocationDescriptor("/private/example/private.db"))
        XCTAssertFalse(AttachedDataSourceValidation.privacySafeLocationDescriptor("file:///private/data.json"))
        XCTAssertTrue(AttachedDataSourceValidation.privacySafeLocationDescriptor(
            "User-selected read-only SQLite file"
        ))

        XCTAssertThrowsError(try AttachedDataSourceAccess(
            bookmarkState: .retained,
            continuingAccessRetained: false
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidAccessState)
        }
        XCTAssertThrowsError(try AttachedDataSourceSelection(
            id: "selection-duplicate",
            kind: .sqliteTable,
            sourceIdentifier: "records",
            displayName: "Records",
            selectedFields: ["id", "id"],
            searchableFields: ["id"],
            identityFields: ["id"],
            recordIdentityStrategy: .declaredPrimaryKey,
            schemaDigest: digest("a")
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidSelection)
        }
        XCTAssertThrowsError(try AttachedDataSourceBudgets(maximumRecords: 0)) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidBudgets)
        }
    }

    func testFileIdentitySeparatesSameResourceEditsFromReplacement() throws {
        let original = identity(size: 100, modificationNanoseconds: 10)
        let edited = identity(size: 120, modificationNanoseconds: 20)
        let replacement = AttachedDataFileIdentity(
            deviceID: original.deviceID,
            inode: original.inode + 1,
            fileType: original.fileType,
            linkCount: 1,
            fileSize: original.fileSize,
            modificationNanoseconds: original.modificationNanoseconds
        )

        XCTAssertTrue(original.matchesResource(edited))
        XCTAssertFalse(original.matchesSnapshot(edited))
        XCTAssertFalse(original.matchesResource(replacement))
        XCTAssertTrue(original.matchesSnapshot(original))
        XCTAssertNoThrow(try original.validate())
    }

    func testPublishedBudgetsExactlyMirrorJSONAndSQLiteEngineLimits() throws {
        let jsonEngine = AttachedJSONLimits.standard
        let json = AttachedDataSourceBudgets.jsonStandard
        XCTAssertEqual(json.maximumInputBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(json.maximumInputBytes, Int64(jsonEngine.maximumInputBytes))
        XCTAssertEqual(json.maximumRecords, jsonEngine.maximumRecords)
        XCTAssertEqual(json.maximumKeysPerObject, jsonEngine.maximumKeysPerObject)
        XCTAssertEqual(json.maximumNestingDepth, jsonEngine.maximumNestingDepth)
        XCTAssertEqual(json.maximumNodes, jsonEngine.maximumNodes)
        XCTAssertEqual(json.maximumStringBytes, jsonEngine.maximumStringBytes)
        XCTAssertEqual(json.maximumNumberBytes, jsonEngine.maximumNumberBytes)
        XCTAssertEqual(
            json.maximumMaterializedBytes,
            Int64(jsonEngine.maximumAggregateMaterializationBytes)
        )
        XCTAssertEqual(
            json.maximumNormalizedTextBytes,
            jsonEngine.maximumNormalizedTextBytes
        )
        XCTAssertEqual(json.maximumFields, jsonEngine.maximumSelectedFields)
        XCTAssertEqual(
            json.cancellationCheckIntervalBytes,
            jsonEngine.cancellationCheckIntervalBytes
        )
        XCTAssertNil(json.maximumRecordBytes)
        XCTAssertNil(json.pageSize)
        XCTAssertNil(json.executionTimeSeconds)

        let sqliteEngine = AttachedSQLiteLimits()
        let sqlite = AttachedDataSourceBudgets.sqliteStandard
        XCTAssertEqual(sqlite.maximumInputBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(sqlite.maximumRecords, sqliteEngine.maximumRecords)
        XCTAssertEqual(sqlite.maximumStringBytes, sqliteEngine.maximumTextBytes)
        XCTAssertEqual(sqlite.maximumRecordBytes, sqliteEngine.maximumRecordBytes)
        XCTAssertEqual(
            sqlite.maximumMaterializedBytes,
            Int64(sqliteEngine.maximumMaterializedBytes)
        )
        XCTAssertEqual(sqlite.maximumFields, sqliteEngine.maximumColumns)
        XCTAssertEqual(sqlite.pageSize, sqliteEngine.pageSize)
        XCTAssertEqual(
            sqlite.executionTimeSeconds,
            sqliteEngine.executionTimeSeconds
        )
        XCTAssertNil(sqlite.maximumKeysPerObject)
        XCTAssertNil(sqlite.maximumNestingDepth)
        XCTAssertNil(sqlite.maximumNodes)
        XCTAssertNil(sqlite.maximumNumberBytes)
        XCTAssertNil(sqlite.maximumNormalizedTextBytes)
        XCTAssertNil(sqlite.cancellationCheckIntervalBytes)
    }

    func testFrozenPlanDigestRejectsMaterialMutationAndSelectionDigestForgery() throws {
        let originalSelection = try selection()
        let original = try importPlan(selection: originalSelection)
        XCTAssertEqual(
            original.selectionDigest,
            AttachedDataImportPlan.frozenSelectionDigest(for: [originalSelection])
        )
        XCTAssertNoThrow(try original.validate())

        let changedSelection = try AttachedDataSourceSelection(
            id: originalSelection.id,
            kind: originalSelection.kind,
            sourceIdentifier: originalSelection.sourceIdentifier,
            displayName: "Records changed",
            selectedFields: originalSelection.selectedFields,
            searchableFields: originalSelection.searchableFields,
            identityFields: originalSelection.identityFields,
            includedBlobBodyFields: originalSelection.includedBlobBodyFields,
            recordIdentityStrategy: originalSelection.recordIdentityStrategy,
            schemaDigest: originalSelection.schemaDigest,
            estimatedRecordCount: originalSelection.estimatedRecordCount,
            estimatedBytes: 256,
            allowsRecordTruncation: true
        )
        XCTAssertNotEqual(
            original.selectionDigest,
            AttachedDataImportPlan.frozenSelectionDigest(for: [changedSelection])
        )
        XCTAssertThrowsError(try importPlan(
            selection: changedSelection,
            selectionDigest: original.selectionDigest
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidImportPlan)
        }
        XCTAssertThrowsError(try importPlan(
            selection: originalSelection,
            expectedRecordCount: 3,
            planDigest: original.planDigest
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidImportPlan)
        }
        XCTAssertThrowsError(try importPlan(
            selection: originalSelection,
            fileIdentity: identity(modificationNanoseconds: 2_000),
            planDigest: original.planDigest
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidImportPlan)
        }
        XCTAssertThrowsError(try importPlan(
            selection: originalSelection,
            createdAt: anchor.addingTimeInterval(1),
            planDigest: original.planDigest
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidImportPlan)
        }
        XCTAssertThrowsError(try importPlan(
            selection: originalSelection,
            priorSourceDigest: digest("c"),
            planDigest: original.planDigest
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .invalidImportPlan)
        }
    }

    func testConnectedStateRequiresAdmittedIdentityDigestsAndSelection() throws {
        XCTAssertThrowsError(try AttachedDataSourceRecord(
            id: "source-invalid-connected",
            kind: .sqlite,
            mode: .linkedReadOnly,
            displayName: "Missing admission",
            originalFilename: "records.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            state: .connected
        )) {
            XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .persistenceCorrupt)
        }

        let connected = try connectedRecord()
        XCTAssertEqual(connected.state, .connected)
        XCTAssertTrue(connected.hasRetainedLocalData)
        XCTAssertFalse(connected.isBookmarkStale)
        XCTAssertEqual(connected.privacySafeDiagnosticFields["source_id"], connected.id)
        XCTAssertNil(connected.privacySafeDiagnosticFields["filename"])
        XCTAssertNil(connected.privacySafeDiagnosticFields["path"])
    }

    func testRestartReconcilesPreviewAndSelectionWithoutPublishingState() throws {
        for state in [AttachedDataSourceState.selecting, .previewing] {
            let record = try AttachedDataSourceRecord(
                id: "source-\(state.rawValue)",
                kind: .json,
                mode: .importedSnapshot,
                displayName: "Pending source",
                originalFilename: "pending.json",
                privacySafeLocationDescriptor: "User-selected read-only JSON file",
                state: state,
                createdAt: anchor,
                updatedAt: anchor
            )

            let recovered = try record.reconcilingInterruptedOperation(
                at: anchor.addingTimeInterval(10)
            )
            XCTAssertEqual(recovered.state, .disconnected)
            XCTAssertEqual(recovered.cancellationState, .interrupted)
            XCTAssertEqual(
                recovered.lastErrorReasonCode,
                AttachedDataSourceFailureCode.operationInterruptedByRestart.rawValue
            )
            XCTAssertNil(recovered.pendingGenerationIdentifier)
            XCTAssertNil(recovered.currentGenerationIdentifier)
        }
    }

    func testRestartPreservesPublishedGenerationButNeverPromotesPendingGeneration() throws {
        let withPublished = try importingRecord(priorGeneration: "generation-old")
        let recoveredPublished = try withPublished.reconcilingInterruptedOperation(
            at: anchor.addingTimeInterval(30)
        )
        XCTAssertEqual(recoveredPublished.state, .degraded)
        XCTAssertEqual(recoveredPublished.currentGenerationIdentifier, "generation-old")
        XCTAssertEqual(recoveredPublished.sourceDigest, digest("a"))
        XCTAssertEqual(recoveredPublished.shapeDigest, digest("b"))
        XCTAssertNil(recoveredPublished.pendingGenerationIdentifier)
        XCTAssertNil(recoveredPublished.frozenImportPlan)
        XCTAssertTrue(recoveredPublished.hasRetainedLocalData)
        XCTAssertEqual(recoveredPublished.cancellationState, .interrupted)

        var legacyWithPublished = try importingRecord(
            priorGeneration: "generation-old",
            includesRetainedGenerationAuthority: false
        )
        let originalLegacyPlan = try XCTUnwrap(
            legacyWithPublished.frozenImportPlan
        )
        var legacyPlanPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(originalLegacyPlan)
            ) as? [String: Any]
        )
        legacyPlanPayload.removeValue(forKey: "priorSourceDigest")
        legacyPlanPayload.removeValue(forKey: "priorShapeDigest")
        XCTAssertNil(legacyPlanPayload["priorSourceDigest"])
        XCTAssertNil(legacyPlanPayload["priorShapeDigest"])
        let decodedLegacyPlan = try JSONDecoder().decode(
            AttachedDataImportPlan.self,
            from: JSONSerialization.data(withJSONObject: legacyPlanPayload)
        )
        XCTAssertEqual(decodedLegacyPlan.planDigest, originalLegacyPlan.planDigest)
        XCTAssertNil(decodedLegacyPlan.priorSourceDigest)
        XCTAssertNil(decodedLegacyPlan.priorShapeDigest)
        XCTAssertNoThrow(try decodedLegacyPlan.validate())
        legacyWithPublished.frozenImportPlan = decodedLegacyPlan
        try legacyWithPublished.validate()
        let recoveredLegacy = try legacyWithPublished
            .reconcilingInterruptedOperation(
                at: anchor.addingTimeInterval(30)
            )
        XCTAssertEqual(recoveredLegacy.state, .degraded)
        XCTAssertEqual(
            recoveredLegacy.currentGenerationIdentifier,
            "generation-old"
        )
        XCTAssertNil(recoveredLegacy.sourceDigest)
        XCTAssertNil(recoveredLegacy.shapeDigest)
        XCTAssertFalse(recoveredLegacy.localModelConsentEnabled)
        XCTAssertNil(recoveredLegacy.pendingGenerationIdentifier)
        XCTAssertNil(recoveredLegacy.frozenImportPlan)

        let withoutPublished = try importingRecord(priorGeneration: nil)
        let recoveredUnpublished = try withoutPublished.reconcilingInterruptedOperation(
            at: anchor.addingTimeInterval(30)
        )
        XCTAssertEqual(recoveredUnpublished.state, .disconnected)
        XCTAssertNil(recoveredUnpublished.currentGenerationIdentifier)
        XCTAssertNil(recoveredUnpublished.pendingGenerationIdentifier)
        XCTAssertNil(recoveredUnpublished.frozenImportPlan)
        XCTAssertFalse(recoveredUnpublished.hasRetainedLocalData)
    }

    func testDetachRevokesBookmarkAuthorityWhilePreservingLocalGeneration() throws {
        let record = try connectedRecord()
        let detached = try record.detached(at: anchor.addingTimeInterval(60))

        XCTAssertEqual(detached.state, .disconnected)
        XCTAssertEqual(detached.access.bookmarkState, .detached)
        XCTAssertFalse(detached.access.continuingAccessRetained)
        XCTAssertFalse(detached.refreshEnabled)
        XCTAssertFalse(detached.automaticRefreshEnabled)
        XCTAssertEqual(detached.currentGenerationIdentifier, record.currentGenerationIdentifier)
        XCTAssertEqual(detached.localDataRetentionState, .retained)
        XCTAssertEqual(detached.importedLocalContainerIdentifiers, ["container-records"])
        XCTAssertTrue(detached.localModelConsentEnabled)
    }

    func testPersistenceReplacesSourceAtomicallyPreservesBookmarkThenDetachesAcrossReopen() throws {
        let fixture = try makeStoreFixture(named: "source-replacement")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bookmark = Data("private-security-scoped-bookmark-marker".utf8)
        var updated = try connectedRecord()

        do {
            let store = try LocalStore(url: fixture.database)
            try store.saveAttachedDataSource(updated, securityScopedBookmark: bookmark)
            XCTAssertEqual(try store.attachedDataSources(), [updated])
            XCTAssertEqual(try store.attachedDataSourceBookmark(id: updated.id), bookmark)

            updated.displayName = "Renamed Records"
            updated.updatedAt = anchor.addingTimeInterval(30)
            try updated.validate()
            try store.saveAttachedDataSource(updated)
            XCTAssertEqual(try store.attachedDataSources(), [updated])
            XCTAssertEqual(
                try store.attachedDataSourceBookmark(id: updated.id),
                bookmark,
                "A status update must not silently discard continuing authority"
            )
        }

        do {
            let reopened = try LocalStore(url: fixture.database)
            XCTAssertEqual(try reopened.attachedDataSources(), [updated])
            XCTAssertEqual(try reopened.attachedDataSourceBookmark(id: updated.id), bookmark)
            let encodedDomain = try JSONEncoder().encode(try XCTUnwrap(
                reopened.attachedDataSource(id: updated.id)
            ))
            XCTAssertFalse(String(decoding: encodedDomain, as: UTF8.self).contains(
                "private-security-scoped-bookmark-marker"
            ))

            let detached = try XCTUnwrap(try reopened.detachAttachedDataSource(
                id: updated.id,
                at: anchor.addingTimeInterval(60)
            ))
            XCTAssertEqual(detached.currentGenerationIdentifier, "generation-current")
            XCTAssertEqual(detached.localDataRetentionState, .retained)
            XCTAssertNil(try reopened.attachedDataSourceBookmark(id: updated.id))
        }

        do {
            let reopened = try LocalStore(url: fixture.database)
            let detached = try XCTUnwrap(reopened.attachedDataSource(id: updated.id))
            XCTAssertEqual(detached.state, .disconnected)
            XCTAssertEqual(detached.access.bookmarkState, .detached)
            XCTAssertNil(try reopened.attachedDataSourceBookmark(id: updated.id))
            XCTAssertEqual(try reopened.attachedDataSources().count, 1)
        }
    }

    func testPersistenceReconcilesInterruptedImportAcrossRestart() throws {
        let fixture = try makeStoreFixture(named: "restart-reconcile")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let importing = try importingRecord(priorGeneration: "generation-old")
        let bookmark = Data("restart-bookmark".utf8)

        do {
            let store = try LocalStore(url: fixture.database)
            try store.saveAttachedDataSource(importing, securityScopedBookmark: bookmark)
        }
        do {
            let reopened = try LocalStore(url: fixture.database)
            let reconciled = try reopened.reconcileInterruptedAttachedDataSourceOperations(
                at: anchor.addingTimeInterval(120)
            )
            let recovered = try XCTUnwrap(reconciled.first)
            XCTAssertEqual(recovered.state, .degraded)
            XCTAssertEqual(recovered.currentGenerationIdentifier, "generation-old")
            XCTAssertNil(recovered.pendingGenerationIdentifier)
            XCTAssertEqual(recovered.cancellationState, .interrupted)
            XCTAssertEqual(try reopened.attachedDataSourceBookmark(id: importing.id), bookmark)
        }
        do {
            let reopened = try LocalStore(url: fixture.database)
            XCTAssertEqual(try reopened.attachedDataSource(id: importing.id)?.state, .degraded)
            XCTAssertNil(try reopened.attachedDataSource(id: importing.id)?
                .pendingGenerationIdentifier)
        }
    }

    func testReceiptsAreImmutableIdempotentAndDurable() throws {
        let fixture = try makeStoreFixture(named: "receipts")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receipt = try makeReceipt(reasonCode: "attached_data_import_succeeded", hash: digest("e"))
        let conflict = try makeReceipt(reasonCode: "attached_data_import_changed", hash: digest("f"))

        do {
            let store = try LocalStore(url: fixture.database)
            try store.saveAttachedDataSourceReceipt(receipt)
            try store.saveAttachedDataSourceReceipt(receipt)
            XCTAssertEqual(try store.attachedDataSourceReceipts(), [receipt])
            XCTAssertThrowsError(try store.saveAttachedDataSourceReceipt(conflict)) {
                XCTAssertEqual($0 as? AttachedDataSourceFailureCode, .receiptConflict)
            }
        }
        do {
            let reopened = try LocalStore(url: fixture.database)
            XCTAssertEqual(try reopened.attachedDataSourceReceipts(), [receipt])
            XCTAssertEqual(
                try reopened.attachedDataSourceReceipt(id: receipt.id),
                receipt
            )
        }
    }

    func testV11SchemaAddsOnlyAttachedSourceModelsAndOneMigrationStage() {
        XCTAssertEqual(LokiBriefSchemaV11.versionIdentifier, Schema.Version(11, 0, 0))
        XCTAssertEqual(LokiBriefSchemaV11.models.count, LokiBriefSchemaV10.models.count + 2)
        XCTAssertEqual(LokiBriefMigrationPlanV11.schemas.count, LokiBriefMigrationPlanV10.schemas.count + 1)
        XCTAssertEqual(LokiBriefMigrationPlanV11.stages.count, LokiBriefMigrationPlanV10.stages.count + 1)
    }

    private func connectedRecord() throws -> AttachedDataSourceRecord {
        try AttachedDataSourceRecord(
            id: "source-records",
            kind: .sqlite,
            mode: .linkedReadOnly,
            displayName: "Records",
            originalFilename: "records.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            fileIdentity: identity(),
            sourceDigest: digest("a"),
            shapeDigest: digest("b"),
            state: .connected,
            selections: [try selection()],
            currentEpoch: 3,
            lastSuccessfulRefreshAt: anchor,
            lastAttemptedRefreshAt: anchor,
            itemCount: 2,
            importedLocalContainerIdentifiers: ["container-records"],
            localDataRetentionState: .retained,
            latestReceiptIdentifier: "receipt-current",
            currentGenerationIdentifier: "generation-current",
            access: try .init(
                bookmarkState: .retained,
                continuingAccessRetained: true,
                lastAuthorizedAt: anchor,
                lastResolvedAt: anchor
            ),
            refreshEnabled: true,
            localModelConsentEnabled: true,
            createdAt: anchor,
            updatedAt: anchor
        )
    }

    private func importingRecord(
        priorGeneration: String?,
        includesRetainedGenerationAuthority: Bool = true
    ) throws -> AttachedDataSourceRecord {
        let selection = try selection()
        let generation = "generation-pending"
        let attemptedSourceDigest = digest("c")
        let attemptedShapeDigest = digest("d")
        let plan = try AttachedDataImportPlan(
            id: "plan-pending",
            sourceIdentifier: "source-importing",
            sourceKind: .sqlite,
            mode: .linkedReadOnly,
            fileIdentity: identity(),
            sourceDigest: attemptedSourceDigest,
            shapeDigest: attemptedShapeDigest,
            selections: [selection],
            normalizationVersion: 1,
            provenanceVersion: 1,
            generationIdentifier: generation,
            priorGenerationIdentifier: priorGeneration,
            priorSourceDigest: priorGeneration == nil
                || !includesRetainedGenerationAuthority ? nil : digest("a"),
            priorShapeDigest: priorGeneration == nil
                || !includesRetainedGenerationAuthority ? nil : digest("b"),
            createdAt: anchor
        )
        return try AttachedDataSourceRecord(
            id: "source-importing",
            kind: .sqlite,
            mode: .linkedReadOnly,
            displayName: "Importing",
            originalFilename: "importing.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            fileIdentity: identity(),
            sourceDigest: attemptedSourceDigest,
            shapeDigest: attemptedShapeDigest,
            state: .importing,
            selections: [selection],
            currentEpoch: priorGeneration == nil ? 0 : 1,
            localDataRetentionState: priorGeneration == nil ? .none : .retained,
            currentGenerationIdentifier: priorGeneration,
            pendingGenerationIdentifier: generation,
            frozenImportPlan: plan,
            access: try .init(
                bookmarkState: .retained,
                continuingAccessRetained: true,
                lastAuthorizedAt: anchor,
                lastResolvedAt: anchor
            ),
            refreshEnabled: true,
            createdAt: anchor,
            updatedAt: anchor
        )
    }

    private func selection() throws -> AttachedDataSourceSelection {
        try AttachedDataSourceSelection(
            id: "selection-records",
            kind: .sqliteTable,
            sourceIdentifier: "records",
            displayName: "Records",
            selectedFields: ["id", "body"],
            searchableFields: ["body"],
            identityFields: ["id"],
            recordIdentityStrategy: .declaredPrimaryKey,
            schemaDigest: digest("b"),
            estimatedRecordCount: 2,
            estimatedBytes: 128
        )
    }

    private func importPlan(
        selection: AttachedDataSourceSelection,
        fileIdentity: AttachedDataFileIdentity? = nil,
        expectedRecordCount: Int = 2,
        createdAt: Date? = nil,
        selectionDigest: String? = nil,
        priorSourceDigest: String? = nil,
        planDigest: String? = nil
    ) throws -> AttachedDataImportPlan {
        try AttachedDataImportPlan(
            id: "plan-pending",
            sourceIdentifier: "source-importing",
            sourceKind: .sqlite,
            mode: .linkedReadOnly,
            fileIdentity: fileIdentity ?? identity(),
            sourceDigest: digest("a"),
            shapeDigest: digest("b"),
            selections: [selection],
            selectionDigest: selectionDigest,
            budgets: .sqliteStandard,
            expectedRecordCount: expectedRecordCount,
            expectedMaterializedBytes: 128,
            normalizationVersion: 1,
            provenanceVersion: 1,
            generationIdentifier: "generation-pending",
            priorGenerationIdentifier: "generation-current",
            priorSourceDigest: priorSourceDigest ?? digest("a"),
            priorShapeDigest: digest("b"),
            createdAt: createdAt ?? anchor,
            planDigest: planDigest
        )
    }

    private func identity(
        size: Int64 = 1_024,
        modificationNanoseconds: Int64 = 1_000
    ) -> AttachedDataFileIdentity {
        AttachedDataFileIdentity(
            deviceID: 42,
            inode: 84,
            fileType: 0o100000,
            linkCount: 1,
            fileSize: size,
            modificationNanoseconds: modificationNanoseconds
        )
    }

    private func makeReceipt(
        reasonCode: String,
        hash: String
    ) throws -> AttachedDataSourceReceipt {
        try AttachedDataSourceReceipt(
            id: "receipt-fixed",
            sourceIdentifier: "source-records",
            sourceKind: .sqlite,
            mode: .linkedReadOnly,
            operation: .refresh,
            outcome: .succeeded,
            reasonCode: reasonCode,
            traceIdentifier: "trace-receipt",
            importPlanIdentifier: "plan-receipt",
            generationIdentifier: "generation-receipt",
            priorGenerationIdentifier: "generation-current",
            sourceDigest: digest("a"),
            shapeDigest: digest("b"),
            selectionDigest: digest("c"),
            startedAt: anchor,
            completedAt: anchor.addingTimeInterval(1),
            importedItemCount: 1,
            updatedItemCount: 1,
            tombstonedItemCount: 0,
            skippedItemCount: 0,
            attachmentBlobCount: 0,
            truncationCount: 0,
            materializedByteCount: 128,
            pageCount: 1,
            bookmarkRetained: true,
            priorGenerationRetained: false,
            atomicPublicationCommitted: true,
            provenanceVersion: 1,
            receiptHash: hash
        )
    }

    private func makeStoreFixture(named name: String) throws
        -> (directory: URL, database: URL)
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-loki-attached-domain-tests-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (directory, directory.appendingPathComponent("LokiBrief.store"))
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
