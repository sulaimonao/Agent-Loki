import Darwin
import Foundation
import SQLite3
import XCTest
@testable import LokiBrief

final class AttachedSQLiteSourceTests: XCTestCase, @unchecked Sendable {
    func testPreviewClassifiesPrimaryKeyCompositeRowIDAndDigestIdentity() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = try await AttachedSQLiteSource().preview(at: fixture.database)
        let objects = Dictionary(uniqueKeysWithValues: preview.objects.map { ($0.name, $0) })

        XCTAssertEqual(objects["single_pk"]?.identityStrategy, .declaredPrimaryKey)
        XCTAssertEqual(objects["single_pk"]?.primaryKeyColumns, ["id"])
        XCTAssertEqual(objects["composite_pk"]?.identityStrategy, .compositePrimaryKey)
        XCTAssertEqual(objects["composite_pk"]?.primaryKeyColumns, ["tenant", "item"])
        XCTAssertEqual(objects["rowid_records"]?.identityStrategy, .rowID)
        XCTAssertEqual(objects["rowid_records"]?.rowIDAlias, "rowid")
        XCTAssertEqual(objects["digest_view"]?.identityStrategy, .selectedRecordDigest)
        XCTAssertEqual(objects["digest_view"]?.kind, .view)
        XCTAssertEqual(objects["sqlite_sequence"]?.kind, .internalTable)
        XCTAssertFalse(objects["sqlite_sequence"]?.isSelectable ?? true)
        XCTAssertEqual(preview.schemaDigest.utf8.count, 64)
    }

    func testNullablePrimaryKeyAndShadowedRowIDAliasesChooseSafeIdentity() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        let preview = try await source.preview(at: fixture.database)
        let objects = Dictionary(uniqueKeysWithValues: preview.objects.map { ($0.name, $0) })

        XCTAssertEqual(objects["nullable_pk"]?.primaryKeyColumns, ["code"])
        XCTAssertEqual(objects["nullable_pk"]?.identityStrategy, .rowID)
        XCTAssertEqual(objects["nullable_pk"]?.rowIDAlias, "rowid")
        XCTAssertEqual(objects["rowid_shadow"]?.identityStrategy, .rowID)
        XCTAssertEqual(objects["rowid_shadow"]?.rowIDAlias, "_rowid_")
        XCTAssertEqual(
            objects["all_rowid_aliases_shadowed"]?.identityStrategy,
            .selectedRecordDigest
        )
        XCTAssertNil(objects["all_rowid_aliases_shadowed"]?.rowIDAlias)

        let materialized = try await source.materialize(
            at: fixture.database,
            selections: [
                .init(objectName: "nullable_pk", selectedColumns: ["body"]),
                .init(objectName: "rowid_shadow", selectedColumns: ["body", "rowid"]),
                .init(
                    objectName: "all_rowid_aliases_shadowed",
                    selectedColumns: ["body", "oid", "rowid", "_rowid_"]
                ),
            ]
        )
        let byName = Dictionary(
            uniqueKeysWithValues: materialized.containers.map { ($0.objectName, $0) }
        )
        XCTAssertEqual(byName["nullable_pk"]?.records.count, 2)
        XCTAssertEqual(
            Set(byName["nullable_pk"]?.records.map(\.stableIdentity) ?? []).count,
            2
        )
        XCTAssertEqual(byName["rowid_shadow"]?.records.count, 2)
        XCTAssertEqual(
            Set(byName["rowid_shadow"]?.records.map(\.stableIdentity) ?? []).count,
            2
        )
        XCTAssertEqual(
            byName["all_rowid_aliases_shadowed"]?.records.first?.identityStrategy,
            .selectedRecordDigest
        )
    }

    func testStableIdentitiesAreDeterministicForEverySupportedStrategy() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        let selections = [
            AttachedSQLiteSelection(objectName: "single_pk", selectedColumns: ["name"]),
            AttachedSQLiteSelection(objectName: "composite_pk", selectedColumns: ["body"]),
            AttachedSQLiteSelection(objectName: "rowid_records", selectedColumns: ["name", "value"]),
            AttachedSQLiteSelection(objectName: "digest_view", selectedColumns: ["name", "value"]),
        ]

        let first = try await source.materialize(at: fixture.database, selections: selections)
        let second = try await source.materialize(
            at: fixture.database,
            selections: Array(selections.reversed())
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.totalRecordCount, 8)
        for container in first.containers {
            XCTAssertFalse(container.records.isEmpty, container.objectName)
            XCTAssertEqual(
                Set(container.records.map(\.stableIdentity)).count,
                container.records.count,
                container.objectName
            )
            XCTAssertTrue(container.records.allSatisfy {
                $0.stableIdentity.utf8.count == 64
                    && $0.canonicalRecordHash.utf8.count == 64
            })
        }
    }

    func testValuesNormalizeNullIntegerRealTextAndBlobAsMetadataOnly() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        let preview = try await source.preview(at: fixture.database)
        let table = try XCTUnwrap(preview.objects.first { $0.name == "typed_values" })
        XCTAssertFalse(table.defaultSelectedColumns.contains("payload"))

        let materialized = try await source.materialize(
            at: fixture.database,
            selections: [.init(
                objectName: "typed_values",
                selectedColumns: ["missing", "count", "ratio", "label", "payload"]
            )]
        )
        let record = try XCTUnwrap(materialized.containers.first?.records.first)
        let fields = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.name, $0.value) })

        XCTAssertEqual(fields["missing"], .null)
        XCTAssertEqual(fields["count"], .integer(42))
        XCTAssertEqual(fields["ratio"], .real("3.5"))
        XCTAssertEqual(fields["label"], .text("café"))
        XCTAssertEqual(fields["payload"], .blobMetadata(byteCount: 4))
        XCTAssertEqual(record.blobCount, 1)
        XCTAssertTrue(record.normalizedText.contains("payload: <BLOB 4 bytes; content not indexed>"))
        XCTAssertFalse(record.normalizedText.contains("000102ff"))
    }

    func testQuotedUnicodeIdentifiersAndVirtualShadowObjectsAreHandledSafely() async throws {
        let directory = try makeDirectory(named: "quoted-virtual")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("quoted.sqlite")
        try executeSQL(at: databaseURL, sql: """
            CREATE TABLE "odd "" table"(
                "primary key" TEXT PRIMARY KEY NOT NULL,
                "from" TEXT NOT NULL,
                "quo""te" TEXT NOT NULL,
                "日本語" INTEGER NOT NULL
            );
            INSERT INTO "odd "" table" VALUES ('id-1', 'alpha', 'quoted', 7);
            CREATE VIRTUAL TABLE "search notes" USING fts5("body text");
            INSERT INTO "search notes"("body text") VALUES ('searchable');
            CREATE VIRTUAL TABLE legacy_search USING fts4(body);
            INSERT INTO legacy_search(body) VALUES ('legacy searchable');
            CREATE VIRTUAL TABLE spatial_index
                USING rtree(id, minX, maxX, minY, maxY);
            INSERT INTO spatial_index VALUES (1, 0, 1, 0, 1);
            """)

        let source = try AttachedSQLiteSource()
        let preview = try await source.preview(at: databaseURL)
        let objects = Dictionary(
            uniqueKeysWithValues: preview.objects.map { ($0.name, $0) }
        )
        XCTAssertEqual(objects["odd \" table"]?.identityStrategy, .declaredPrimaryKey)
        XCTAssertEqual(objects["odd \" table"]?.primaryKeyColumns, ["primary key"])
        XCTAssertEqual(objects["search notes"]?.kind, .virtualTable)
        XCTAssertFalse(objects["search notes"]?.isSelectable ?? true)
        for suffix in ["_data", "_idx", "_content", "_docsize", "_config"] {
            let shadow = try XCTUnwrap(objects["search notes" + suffix])
            XCTAssertEqual(shadow.kind, .shadowTable, suffix)
            XCTAssertFalse(shadow.isSelectable, suffix)
        }
        XCTAssertEqual(objects["legacy_search"]?.kind, .virtualTable)
        XCTAssertEqual(objects["spatial_index"]?.kind, .virtualTable)
        for name in [
            "legacy_search_content", "legacy_search_segments",
            "legacy_search_segdir", "legacy_search_docsize",
            "legacy_search_stat", "spatial_index_node",
            "spatial_index_rowid", "spatial_index_parent",
        ] {
            let shadow = try XCTUnwrap(objects[name])
            XCTAssertEqual(shadow.kind, .shadowTable, name)
            XCTAssertFalse(shadow.isSelectable, name)
        }

        let materialized = try await source.materialize(
            at: databaseURL,
            selections: [.init(
                objectName: "odd \" table",
                selectedColumns: ["from", "quo\"te", "日本語"]
            )]
        )
        let record = try XCTUnwrap(materialized.containers.first?.records.first)
        XCTAssertEqual(record.identityStrategy, .declaredPrimaryKey)
        XCTAssertTrue(record.normalizedText.contains("from: alpha"))
        XCTAssertTrue(record.normalizedText.contains("quo\"te: quoted"))
        XCTAssertTrue(record.normalizedText.contains("日本語: 7"))
    }

    func testAllMutationAndBoundaryEscapeProbesAreDeniedWithoutChangingSource() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        let before = try Data(contentsOf: fixture.database)

        for probe in AttachedSQLiteDeniedOperationProbe.allCases {
            let denied = try await source.probeDeniedOperation(
                at: fixture.database,
                probe
            )
            XCTAssertTrue(
                denied,
                "Expected \(probe.rawValue) to be denied"
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
        XCTAssertEqual(try scalarInt(at: fixture.database, sql: "SELECT count(*) FROM __loki_probe__"), 1)
    }

    func testSQLiteHeaderPolicyDistinguishesExtensionMismatchFromUnknownDatabase() async throws {
        let directory = try makeDirectory(named: "headers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("payload.json")
        let sqliteURL = directory.appendingPathComponent("payload.sqlite")
        try Data("{}".utf8).write(to: jsonURL)
        try Data("not a database".utf8).write(to: sqliteURL)
        let source = try AttachedSQLiteSource()

        do {
            _ = try await source.preview(at: jsonURL)
            XCTFail("Expected non-SQLite content to fail")
        } catch let failure as AttachedSQLiteFailureCode {
            XCTAssertEqual(failure, .invalidHeader)
        }
        do {
            _ = try await source.preview(at: sqliteURL)
            XCTFail("Expected SQLite-looking extension with unknown content to fail")
        } catch let failure as AttachedSQLiteFailureCode {
            XCTAssertEqual(failure, .encryptedOrUnknown)
        }
    }

    func testSQLiteHeaderWithCorruptSchemaPageFailsAsCorrupt() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var bytes = try Data(contentsOf: fixture.database)
        XCTAssertGreaterThan(bytes.count, 100)
        bytes[100] = 0
        try bytes.write(to: fixture.database, options: [])

        await assertFailure(.corrupt) {
            try await AttachedSQLiteSource().preview(at: fixture.database)
        }
    }

    func testRecordLimitRequiresExplicitTruncationConsent() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limits = AttachedSQLiteLimits(
            maximumRecords: 2,
            maximumColumns: 8,
            maximumTextBytes: 64,
            maximumRecordBytes: 1_024,
            maximumMaterializedBytes: 16 * 1_024,
            pageSize: 1,
            executionTimeSeconds: 2
        )
        let source = try AttachedSQLiteSource(limits: limits)

        do {
            _ = try await source.materialize(
                at: fixture.database,
                selections: [.init(objectName: "budget_records", selectedColumns: ["value"])]
            )
            XCTFail("Expected the record cap to fail closed")
        } catch let failure as AttachedSQLiteFailureCode {
            XCTAssertEqual(failure, .resultLimitExceeded)
        }

        let truncated = try await source.materialize(
            at: fixture.database,
            selections: [.init(
                objectName: "budget_records",
                selectedColumns: ["value"],
                allowTruncation: true
            )]
        )
        XCTAssertEqual(truncated.totalRecordCount, 2)
        XCTAssertEqual(truncated.truncationCount, 1)
        XCTAssertEqual(truncated.containers.first?.truncatedCount, 1)
    }

    func testNonTruncatingSelectionsMaterializeBeforeTruncationAuthorizedSelections() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource(limits: .init(
            maximumRecords: 3,
            maximumColumns: 8,
            maximumTextBytes: 64,
            maximumRecordBytes: 1_024,
            maximumMaterializedBytes: 16 * 1_024,
            pageSize: 2,
            executionTimeSeconds: 2
        ))

        let materialized = try await source.materialize(
            at: fixture.database,
            selections: [
                .init(
                    objectName: "a_risky_records",
                    selectedColumns: ["value"],
                    allowTruncation: true
                ),
                .init(
                    objectName: "z_safe_record",
                    selectedColumns: ["value"]
                ),
            ]
        )

        XCTAssertEqual(
            materialized.containers.map(\.objectName),
            ["z_safe_record", "a_risky_records"]
        )
        XCTAssertEqual(materialized.containers[0].records.count, 1)
        XCTAssertEqual(materialized.containers[0].truncatedCount, 0)
        XCTAssertEqual(materialized.containers[1].records.count, 2)
        XCTAssertEqual(materialized.containers[1].truncatedCount, 1)
        XCTAssertEqual(materialized.totalRecordCount, 3)
        XCTAssertEqual(materialized.truncationCount, 1)
    }

    func testTextRecordAndAggregateByteBudgetsFailClosed() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let textLimited = try AttachedSQLiteSource(limits: .init(
            maximumRecords: 10,
            maximumColumns: 8,
            maximumTextBytes: 3,
            maximumRecordBytes: 1_024,
            maximumMaterializedBytes: 16 * 1_024,
            pageSize: 2,
            executionTimeSeconds: 2
        ))
        await assertFailure(.recordBytesExceeded) {
            try await textLimited.materialize(
                at: fixture.database,
                selections: [.init(objectName: "budget_records", selectedColumns: ["value"])]
            )
        }

        let recordLimited = try AttachedSQLiteSource(limits: .init(
            maximumRecords: 10,
            maximumColumns: 8,
            maximumTextBytes: 64,
            maximumRecordBytes: 5,
            maximumMaterializedBytes: 16 * 1_024,
            pageSize: 2,
            executionTimeSeconds: 2
        ))
        await assertFailure(.recordBytesExceeded) {
            try await recordLimited.materialize(
                at: fixture.database,
                selections: [.init(objectName: "budget_records", selectedColumns: ["value"])]
            )
        }

        let aggregateLimited = try AttachedSQLiteSource(limits: .init(
            maximumRecords: 10,
            maximumColumns: 8,
            maximumTextBytes: 64,
            maximumRecordBytes: 1_024,
            maximumMaterializedBytes: 5,
            pageSize: 2,
            executionTimeSeconds: 2
        ))
        await assertFailure(.materializedBytesExceeded) {
            try await aggregateLimited.materialize(
                at: fixture.database,
                selections: [.init(objectName: "budget_records", selectedColumns: ["value"])]
            )
        }
    }

    func testInvalidBudgetsAndSelectionsAreRejectedBeforeQuerying() async throws {
        XCTAssertThrowsError(try AttachedSQLiteSource(limits: .init(maximumRecords: 0))) {
            XCTAssertEqual($0 as? AttachedSQLiteFailureCode, .invalidBudget)
        }

        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        await assertFailure(.invalidSelection) {
            try await source.materialize(at: fixture.database, selections: [])
        }
        await assertFailure(.invalidSelection) {
            try await source.materialize(
                at: fixture.database,
                selections: [
                    .init(objectName: "budget_records", selectedColumns: ["value"]),
                    .init(objectName: "budget_records", selectedColumns: ["value"]),
                ]
            )
        }
        await assertFailure(.invalidSelection) {
            try await source.materialize(
                at: fixture.database,
                selections: [.init(objectName: "budget_records", selectedColumns: ["missing"])]
            )
        }
    }

    func testCancellationIsObservedBeforeSnapshotOrQueryWork() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await source.preview(at: fixture.database)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Task.checkCancellation is the expected pre-work boundary.
        } catch let failure as AttachedSQLiteFailureCode {
            XCTAssertEqual(failure, .cancelled)
        }
    }

    func testActualTimeBudgetAndMidQueryCancellationInterruptGeneratedMultiPageLoad() async throws {
        let fixture = try makeHeavyQueryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let timedSource = try AttachedSQLiteSource(limits: .init(
            maximumRecords: 1_000,
            maximumColumns: 8,
            maximumTextBytes: 64,
            maximumRecordBytes: 1_024,
            maximumMaterializedBytes: 1 * 1_024 * 1_024,
            pageSize: 10,
            executionTimeSeconds: 0.1
        ))
        await assertFailure(.timedOut) {
            try await timedSource.materialize(
                at: fixture.database,
                selections: [.init(
                    objectName: "heavy_view",
                    selectedColumns: ["value"],
                    allowTruncation: true
                )]
            )
        }

        let progressGate = QueryProgressGate()
        let cancellableSource = try AttachedSQLiteSource(
            limits: .init(
                maximumRecords: 1_000,
                maximumColumns: 8,
                maximumTextBytes: 64,
                maximumRecordBytes: 1_024,
                maximumMaterializedBytes: 1 * 1_024 * 1_024,
                pageSize: 10,
                executionTimeSeconds: 10
            ),
            queryProgressTestHook: { sql, invocation in
                guard invocation == 1,
                      sql.contains("FROM \"heavy_view\""),
                      sql.contains(" ORDER BY ")
                else { return }
                progressGate.blockOnce()
            }
        )
        let task = Task {
            try await cancellableSource.materialize(
                at: fixture.database,
                selections: [.init(
                    objectName: "heavy_view",
                    selectedColumns: ["value"],
                    allowTruncation: true
                )]
            )
        }
        let waitDeadline = Date().addingTimeInterval(5)
        while !progressGate.hasEntered, Date() < waitDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        progressGate.unblock()
        XCTAssertTrue(progressGate.hasEntered)
        await assertFailure(.cancelled) {
            try await task.value
        }
        XCTAssertEqual(progressGate.blockCount, 1)
    }

    func testSnapshotBackupAndQueriesShareOneOperationDeadline() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try AttachedSQLiteSource(
            limits: .init(executionTimeSeconds: 0.1),
            snapshotBindingTestHook: { phase, _ in
                if case .readTransactionPinned = phase {
                    usleep(150_000)
                }
            }
        )

        await assertFailure(.timedOut) {
            try await source.preview(at: fixture.database)
        }
    }

    func testSchemaEnumerationFailsClosedAtBoundedObjectLimit() async throws {
        let directory = try makeDirectory(named: "schema-object-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("many.sqlite")
        let schema = (0..<130).map {
            "CREATE TABLE object_\($0)(id INTEGER PRIMARY KEY);"
        }.joined(separator: "\n")
        try executeSQL(at: databaseURL, sql: schema)

        let source = try AttachedSQLiteSource()
        await assertFailure(.unsafeSchema) {
            try await source.preview(at: databaseURL)
        }
    }

    func testSQLiteOpenedFileMovementFailsClosedOnPathSwapAndRestore() async throws {
        let fixture = try makeIdentityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replacement = fixture.directory.appendingPathComponent("replacement.sqlite")
        let held = fixture.directory.appendingPathComponent("held.sqlite")
        try executeSQL(at: replacement, sql: "CREATE TABLE attacker_only(id INTEGER PRIMARY KEY);")
        let sourceURL = fixture.database
        let source = try AttachedSQLiteSource(
            snapshotBindingTestHook: { phase, _ in
                switch phase {
                case .descriptorOpened:
                    try renamePOSIX(sourceURL, held)
                    try renamePOSIX(replacement, sourceURL)
                case .readTransactionPinned:
                    try renamePOSIX(sourceURL, replacement)
                    try renamePOSIX(held, sourceURL)
                case .snapshotCaptured, .retrying:
                    break
                }
            }
        )

        await assertFailure(.sourceIdentityChanged) {
            try await source.preview(at: sourceURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertEqual(
            try scalarInt(
                at: sourceURL,
                sql: "SELECT count(*) FROM sqlite_schema WHERE name = 'single_pk'"
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                at: replacement,
                sql: "SELECT count(*) FROM sqlite_schema WHERE name = 'attacker_only'"
            ),
            1
        )
    }

    func testBusyWriterRetriesCoherentlyAndPersistentLockFailsClosed() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var writer: OpaquePointer?
        let opened = sqlite3_open_v2(
            try canonicalPOSIXPath(fixture.database),
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard opened == SQLITE_OK, let writer else {
            throw sqliteError(writer, code: opened)
        }
        defer {
            _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(writer)
        }
        let writerBox = SQLiteHandleBox(writer)

        try executeSQL(on: writer, sql: "BEGIN EXCLUSIVE")
        let retryGate = OneShotGate()
        let retryingSource = try AttachedSQLiteSource(
            snapshotBindingTestHook: { phase, _ in
                guard case .retrying = phase, retryGate.claim() else { return }
                let result = sqlite3_exec(writerBox.database, "ROLLBACK", nil, nil, nil)
                guard result == SQLITE_OK else {
                    throw NSError(
                        domain: "AttachedSQLiteSourceTests.SQLite",
                        code: Int(result)
                    )
                }
            }
        )
        let preview = try await retryingSource.preview(at: fixture.database)
        XCTAssertTrue(preview.objects.contains { $0.name == "budget_records" })
        XCTAssertEqual(retryGate.claimCount, 1)

        try executeSQL(on: writer, sql: "BEGIN EXCLUSIVE")
        let persistentlyLockedSource = try AttachedSQLiteSource()
        await assertFailure(.busy) {
            try await persistentlyLockedSource.preview(at: fixture.database)
        }
    }

    func testMissingRollbackSidecarsWorkButUnavailableWALStateFailsCoherentAuthority() async throws {
        let rollbackFixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: rollbackFixture.directory) }
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: rollbackFixture.database.path + suffix
                )
            )
        }
        _ = try await AttachedSQLiteSource().preview(at: rollbackFixture.database)

        let directory = try makeDirectory(named: "sidecar-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sidecars.sqlite")
        var writer: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let writer else {
            throw sqliteError(writer, code: opened)
        }
        defer { sqlite3_close_v2(writer) }
        try executeSQL(on: writer, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE records(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
            INSERT INTO records VALUES (1, 'committed-in-wal');
            """)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        )
        let authority = AttachedDataFileAuthority(securityScope: .unscopedTesting)

        guard Darwin.chmod(walURL.path, 0o000) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        await assertFileFailure(.coherentSnapshotUnavailable) {
            try await authority.authorize(databaseURL)
        }
        guard Darwin.chmod(walURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func testOversizedSHMSidecarCountsAgainstTotalSourceBudget() async throws {
        let fixture = try makeBudgetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.database.path
        )
        let mainByteCount = try XCTUnwrap(
            (attributes[.size] as? NSNumber)?.int64Value
        )
        let sidecarAllowance: Int64 = 1_024
        let shmURL = URL(fileURLWithPath: fixture.database.path + "-shm")
        let descriptor = Darwin.open(
            shmURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, sidecarAllowance + 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let authority = AttachedDataFileAuthority(
            securityScope: .unscopedTesting,
            maximumSQLiteBytes: mainByteCount + sidecarAllowance
        )

        await assertFileFailure(.tooLarge) {
            try await authority.authorize(fixture.database)
        }
    }

    func testWALOnlyCommitChangesLogicalDigestSchemaAndMaterialization() async throws {
        let directory = try makeDirectory(named: "wal-logical-identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("wal.sqlite")
        var writer: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let writer else {
            throw sqliteError(writer, code: opened)
        }
        defer { sqlite3_close_v2(writer) }
        try executeSQL(
            on: writer,
            sql: """
                PRAGMA journal_mode=WAL;
                PRAGMA wal_autocheckpoint=0;
                CREATE TABLE base_records(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
                INSERT INTO base_records VALUES (1, 'Alpha');
                PRAGMA wal_checkpoint(TRUNCATE);
                """
        )

        let authority = AttachedDataFileAuthority(securityScope: .unscopedTesting)
        let firstObservation = try await authority.authorize(databaseURL)
        let source = try AttachedSQLiteSource()
        let (firstPreview, _) = try await authority.withResolvedSource(
            bookmark: firstObservation.securityScopedBookmark,
            expectedIdentity: firstObservation.identity
        ) { snapshotURL, _ in
            try await source.preview(at: snapshotURL)
        }
        let mainBytesBeforeWALCommit = try Data(contentsOf: databaseURL)

        try executeSQL(
            on: writer,
            sql: """
                CREATE TABLE wal_only(id TEXT PRIMARY KEY, body TEXT NOT NULL);
                INSERT INTO wal_only VALUES ('w1', 'Beta from WAL');
                """
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), mainBytesBeforeWALCommit)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        XCTAssertGreaterThan(
            try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )
        let walBytesBeforeRead = try Data(contentsOf: walURL)

        let standaloneSnapshot = directory.appendingPathComponent("standalone.sqlite")
        try await AttachedSQLiteSource.createStableSnapshot(
            from: databaseURL,
            expectedIdentity: nil,
            to: standaloneSnapshot,
            maximumSourceBytes: 16 * 1_024 * 1_024
        )
        let standaloneHeader = try Data(contentsOf: standaloneSnapshot)
        XCTAssertEqual(Array(standaloneHeader[18...19]), [1, 1])
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: standaloneSnapshot.path + suffix
                ),
                suffix
            )
        }
        XCTAssertEqual(
            try scalarInt(
                at: standaloneSnapshot,
                sql: "SELECT count(*) FROM wal_only"
            ),
            1
        )

        let secondObservation = try await authority.authorize(databaseURL)
        XCTAssertTrue(secondObservation.identity.matchesSnapshot(firstObservation.identity))
        XCTAssertNotEqual(secondObservation.sourceDigest, firstObservation.sourceDigest)
        let (result, _) = try await authority.withResolvedSource(
            bookmark: secondObservation.securityScopedBookmark,
            expectedIdentity: secondObservation.identity
        ) { snapshotURL, _ in
            let preview: AttachedSQLitePreview
            do {
                preview = try await source.preview(at: snapshotURL)
            } catch {
                XCTFail("WAL snapshot preview failed: \(error)")
                throw error
            }
            let materialized: AttachedSQLiteMaterialization
            do {
                materialized = try await source.materialize(
                    at: snapshotURL,
                    selections: [.init(
                        objectName: "wal_only",
                        selectedColumns: ["body"]
                    )]
                )
            } catch {
                XCTFail("WAL snapshot materialization failed: \(error)")
                throw error
            }
            return WALSnapshotResult(preview: preview, materialized: materialized)
        }

        XCTAssertNotEqual(result.preview.schemaDigest, firstPreview.schemaDigest)
        XCTAssertTrue(result.preview.objects.contains { $0.name == "wal_only" })
        XCTAssertEqual(result.materialized.totalRecordCount, 1)
        XCTAssertTrue(
            result.materialized.containers.first?.records.first?
                .normalizedText.contains("Beta from WAL") == true
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), mainBytesBeforeWALCommit)
        XCTAssertEqual(try Data(contentsOf: walURL), walBytesBeforeRead)

        try executeSQL(on: writer, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        let checkpointedObservation = try await authority.authorize(databaseURL)
        XCTAssertEqual(
            checkpointedObservation.sourceDigest,
            secondObservation.sourceDigest
        )
        let (checkpointedPreview, _) = try await authority.withResolvedSource(
            bookmark: checkpointedObservation.securityScopedBookmark,
            expectedIdentity: checkpointedObservation.identity
        ) { snapshotURL, _ in
            try await source.preview(at: snapshotURL)
        }
        XCTAssertEqual(checkpointedPreview.schemaDigest, result.preview.schemaDigest)
    }

    func testSQLiteBackupMatchesPinnedReaderAndIgnoresUncommittedWALFrames() async throws {
        let directory = try makeDirectory(named: "wal-uncommitted")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("uncommitted.sqlite")
        var writer: OpaquePointer?
        let writerResult = sqlite3_open_v2(
            databaseURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard writerResult == SQLITE_OK, let writer else {
            throw sqliteError(writer, code: writerResult)
        }
        defer {
            _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(writer)
        }
        try executeSQL(on: writer, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            PRAGMA synchronous=FULL;
            PRAGMA cache_size=1;
            PRAGMA cache_spill=ON;
            CREATE TABLE records(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
            INSERT INTO records VALUES (1, 'committed-alpha');
            PRAGMA wal_checkpoint(TRUNCATE);
            """)

        var pinnedReader: OpaquePointer?
        let readerResult = sqlite3_open_v2(
            try canonicalPOSIXPath(databaseURL),
            &pinnedReader,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard readerResult == SQLITE_OK, let pinnedReader else {
            throw sqliteError(pinnedReader, code: readerResult)
        }
        defer {
            _ = sqlite3_exec(pinnedReader, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(pinnedReader)
        }
        try executeSQL(on: pinnedReader, sql: "BEGIN")
        let pinnedCount = try scalarInt(
            on: pinnedReader,
            sql: "SELECT count(*) FROM records"
        )
        XCTAssertEqual(pinnedCount, 1)

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walBytesBefore = try Data(contentsOf: walURL).count
        try executeSQL(on: writer, sql: """
            BEGIN IMMEDIATE;
            WITH RECURSIVE sequence(value) AS (
                SELECT 2 UNION ALL SELECT value + 1 FROM sequence WHERE value < 96
            )
            INSERT INTO records(id, body)
                SELECT value,
                       'uncommitted-wal-sentinel-' || value || '-' || hex(zeroblob(8192))
                FROM sequence;
            """)
        let flushed = sqlite3_db_cacheflush(writer)
        guard flushed == SQLITE_OK else {
            throw sqliteError(writer, code: flushed)
        }
        let walBytesAfter = try Data(contentsOf: walURL).count
        XCTAssertGreaterThan(walBytesAfter, walBytesBefore)
        XCTAssertEqual(
            try scalarInt(at: databaseURL, sql: "SELECT count(*) FROM records"),
            pinnedCount
        )

        let source = try AttachedSQLiteSource()
        let materialized = try await source.materialize(
            at: databaseURL,
            selections: [.init(
                objectName: "records",
                selectedColumns: ["body"]
            )]
        )
        XCTAssertEqual(materialized.totalRecordCount, pinnedCount)
        XCTAssertEqual(
            materialized.containers.first?.records.first?.normalizedText,
            "body: committed-alpha"
        )
        XCTAssertFalse(
            materialized.containers.first?.records.contains {
                $0.normalizedText.contains("uncommitted-wal-sentinel")
            } ?? true
        )
        XCTAssertEqual(
            try scalarInt(on: pinnedReader, sql: "SELECT count(*) FROM records"),
            pinnedCount
        )
    }

    func testConcurrentWALSchemaCommitRetriesToOneCoherentGeneration() async throws {
        let directory = try makeDirectory(named: "concurrent-schema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("schema.sqlite")
        var writer: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let writer else {
            throw sqliteError(writer, code: opened)
        }
        defer { sqlite3_close_v2(writer) }
        try executeSQL(on: writer, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE initial_records(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
            INSERT INTO initial_records VALUES (1, 'initial');
            PRAGMA wal_checkpoint(TRUNCATE);
            """)

        let writerBox = SQLiteHandleBox(writer)
        let schemaChange = OneShotGate()
        let source = try AttachedSQLiteSource(
            snapshotBindingTestHook: { phase, _ in
                guard case .readTransactionPinned = phase,
                      schemaChange.claim()
                else { return }
                let result = sqlite3_exec(
                    writerBox.database,
                    "CREATE TABLE concurrent_records(id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO concurrent_records VALUES (1, 'committed');",
                    nil,
                    nil,
                    nil
                )
                guard result == SQLITE_OK else {
                    throw NSError(
                        domain: "AttachedSQLiteSourceTests.SQLite",
                        code: Int(result)
                    )
                }
            }
        )
        let preview = try await source.preview(at: databaseURL)
        XCTAssertEqual(schemaChange.claimCount, 1)
        XCTAssertTrue(preview.objects.contains { $0.name == "initial_records" })
        XCTAssertTrue(preview.objects.contains { $0.name == "concurrent_records" })
        let materialized = try await source.materialize(
            at: databaseURL,
            selections: [.init(
                objectName: "concurrent_records",
                selectedColumns: ["body"]
            )]
        )
        XCTAssertEqual(materialized.totalRecordCount, 1)
        XCTAssertEqual(
            materialized.containers.first?.records.first?.normalizedText,
            "body: committed"
        )
    }

    private func assertFailure<T>(
        _ expected: AttachedSQLiteFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let failure as AttachedSQLiteFailureCode {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertFileFailure<T>(
        _ expected: AttachedDataFileFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let failure as AttachedDataFileFailureCode {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeIdentityFixture() throws -> (directory: URL, database: URL) {
        let directory = try makeDirectory(named: "identity")
        let database = directory.appendingPathComponent("identity.sqlite")
        do {
            try executeSQL(at: database, sql: """
                CREATE TABLE single_pk(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
                INSERT INTO single_pk VALUES ('a', 'alpha'), ('b', 'beta');
                CREATE TABLE composite_pk(
                    tenant TEXT NOT NULL,
                    item INTEGER NOT NULL,
                    body TEXT,
                    PRIMARY KEY(tenant, item)
                ) WITHOUT ROWID;
                INSERT INTO composite_pk VALUES ('one', 1, 'first'), ('one', 2, 'second');
                CREATE TABLE rowid_records(name TEXT NOT NULL, value INTEGER NOT NULL);
                INSERT INTO rowid_records VALUES ('gamma', 3), ('delta', 4);
                CREATE VIEW digest_view AS SELECT name, value FROM rowid_records;
                CREATE TABLE nullable_pk(code TEXT PRIMARY KEY, body TEXT NOT NULL);
                INSERT INTO nullable_pk VALUES (NULL, 'nullable-one'), (NULL, 'nullable-two');
                CREATE TABLE rowid_shadow(rowid TEXT, body TEXT NOT NULL);
                INSERT INTO rowid_shadow VALUES ('same', 'shadow-one'), ('same', 'shadow-two');
                CREATE TABLE all_rowid_aliases_shadowed(
                    rowid TEXT,
                    _rowid_ TEXT,
                    oid TEXT,
                    body TEXT NOT NULL
                );
                INSERT INTO all_rowid_aliases_shadowed
                    VALUES ('r', 'u', 'o', 'digest-only');
                CREATE TABLE autoincrement_probe(id INTEGER PRIMARY KEY AUTOINCREMENT);
                INSERT INTO autoincrement_probe DEFAULT VALUES;
                CREATE TABLE typed_values(
                    id INTEGER PRIMARY KEY,
                    missing TEXT,
                    count INTEGER,
                    ratio REAL,
                    label TEXT,
                    payload BLOB
                );
                INSERT INTO typed_values VALUES (1, NULL, 42, 3.5, 'café', x'000102ff');
                CREATE TABLE __loki_probe__(value INTEGER);
                INSERT INTO __loki_probe__ VALUES (7);
                """)
            return (directory, database)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeBudgetFixture() throws -> (directory: URL, database: URL) {
        let directory = try makeDirectory(named: "budgets")
        let database = directory.appendingPathComponent("budgets.sqlite3")
        do {
            try executeSQL(at: database, sql: """
                CREATE TABLE budget_records(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO budget_records VALUES (1, 'alpha'), (2, 'bravo'), (3, 'charlie');
                CREATE TABLE a_risky_records(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO a_risky_records VALUES
                    (1, 'risky-one'), (2, 'risky-two'), (3, 'risky-three');
                CREATE TABLE z_safe_record(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO z_safe_record VALUES (1, 'safe');
                """)
            return (directory, database)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeHeavyQueryFixture() throws -> (directory: URL, database: URL) {
        let directory = try makeDirectory(named: "heavy-query")
        let database = directory.appendingPathComponent("heavy.sqlite")
        do {
            try executeSQL(at: database, sql: """
                CREATE TABLE numbers(value INTEGER PRIMARY KEY);
                WITH RECURSIVE sequence(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM sequence WHERE value < 2500
                )
                INSERT INTO numbers SELECT value FROM sequence;
                CREATE VIEW heavy_view AS
                    SELECT left_number.value * 100000 + right_number.value AS value
                    FROM numbers AS left_number
                    CROSS JOIN numbers AS right_number;
                """)
            return (directory, database)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-loki-attached-sqlite-tests-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func executeSQL(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            throw sqliteError(database, code: result)
        }
        defer { sqlite3_close_v2(database) }
        let executed = sqlite3_exec(database, sql, nil, nil, nil)
        guard executed == SQLITE_OK else {
            throw sqliteError(database, code: executed)
        }
    }

    private func executeSQL(on database: OpaquePointer, sql: String) throws {
        let executed = sqlite3_exec(database, sql, nil, nil, nil)
        guard executed == SQLITE_OK else {
            throw sqliteError(database, code: executed)
        }
    }

    private func scalarInt(at url: URL, sql: String) throws -> Int {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let database else {
            throw sqliteError(database, code: opened)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw sqliteError(database, code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            throw sqliteError(database, code: stepped)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarInt(on database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw sqliteError(database, code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            throw sqliteError(database, code: stepped)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sqliteError(_ database: OpaquePointer?, code: Int32) -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite unavailable"
        return NSError(
            domain: "AttachedSQLiteSourceTests.SQLite",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct WALSnapshotResult: Sendable {
    let preview: AttachedSQLitePreview
    let materialized: AttachedSQLiteMaterialization
}

private final class SQLiteHandleBox: @unchecked Sendable {
    let database: OpaquePointer

    init(_ database: OpaquePointer) {
        self.database = database
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var count = 0

    var claimCount: Int {
        lock.withLock { count }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            count += 1
            return true
        }
    }
}

private final class QueryProgressGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var entered = false
    private var released = false
    private var count = 0

    var blockCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func blockOnce() {
        condition.lock()
        guard !blocked else {
            condition.unlock()
            return
        }
        blocked = true
        entered = true
        count += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(5)
        while !released, condition.wait(until: deadline) {}
        condition.unlock()
    }

    func unblock() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private func renamePOSIX(_ source: URL, _ destination: URL) throws {
    let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
            Darwin.rename(sourcePath, destinationPath)
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func canonicalPOSIXPath(_ url: URL) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let resolved = url.path.withCString { path in
        buffer.withUnsafeMutableBufferPointer { storage in
            Darwin.realpath(path, storage.baseAddress)
        }
    }
    guard resolved != nil else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return String(cString: buffer)
}
