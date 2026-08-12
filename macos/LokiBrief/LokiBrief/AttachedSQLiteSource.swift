import CryptoKit
import Darwin
import Foundation
import SQLite3

struct AttachedSQLiteLimits: Hashable, Sendable {
    var maximumRecords = 10_000
    var maximumColumns = 128
    var maximumTextBytes = 16 * 1_024
    var maximumRecordBytes = 128 * 1_024
    var maximumMaterializedBytes = 32 * 1_024 * 1_024
    var pageSize = 250
    var executionTimeSeconds: TimeInterval = 15

    func validate() throws {
        guard (1 ... VaultLimits.maximumConnectorGenerationRecords)
                .contains(maximumRecords),
              (1 ... 256).contains(maximumColumns),
              (1 ... 256 * 1_024).contains(maximumTextBytes),
              (1 ... 2 * 1_024 * 1_024).contains(maximumRecordBytes),
              (1 ... 128 * 1_024 * 1_024).contains(maximumMaterializedBytes),
              (1 ... VaultLimits.maximumBatchSize).contains(pageSize),
              executionTimeSeconds.isFinite,
              (0.1 ... 60).contains(executionTimeSeconds)
        else { throw AttachedSQLiteFailureCode.invalidBudget }
    }
}

enum AttachedSQLiteFailureCode: String, Error, Codable, Hashable, Sendable,
    LocalizedError
{
    case invalidBudget = "attached_sqlite_budget_invalid"
    case invalidHeader = "attached_sqlite_header_invalid"
    case encryptedOrUnknown = "attached_sqlite_encrypted_or_unknown"
    case openFailed = "attached_sqlite_open_failed"
    case snapshotFailed = "attached_sqlite_snapshot_failed"
    case sourceIdentityChanged = "attached_sqlite_source_identity_changed"
    case sourceTooLarge = "attached_sqlite_source_too_large"
    case busy = "attached_sqlite_busy"
    case corrupt = "attached_sqlite_corrupt"
    case unsafeSchema = "attached_sqlite_schema_unsafe"
    case unsupportedObject = "attached_sqlite_object_unsupported"
    case invalidSelection = "attached_sqlite_selection_invalid"
    case queryDenied = "attached_sqlite_query_denied"
    case queryFailed = "attached_sqlite_query_failed"
    case resultLimitExceeded = "attached_sqlite_record_limit_exceeded"
    case recordBytesExceeded = "attached_sqlite_record_bytes_exceeded"
    case materializedBytesExceeded = "attached_sqlite_materialized_bytes_exceeded"
    case invalidText = "attached_sqlite_text_invalid"
    case cancelled = "attached_sqlite_cancelled"
    case timedOut = "attached_sqlite_timed_out"

    var errorDescription: String? { rawValue }
}

enum AttachedSQLiteObjectKind: String, Codable, Hashable, Sendable {
    case table
    case view
    case virtualTable = "virtual_table"
    case internalTable = "internal_table"
    case shadowTable = "shadow_table"
}

enum AttachedSQLiteIdentityStrategy: String, Codable, Hashable, Sendable {
    case declaredPrimaryKey = "declared_primary_key"
    case compositePrimaryKey = "composite_primary_key"
    case rowID = "rowid"
    case selectedRecordDigest = "selected_record_digest"
}

struct AttachedSQLiteColumn: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let declaredType: String
    let isNullable: Bool
    let primaryKeyOrdinal: Int
    let isHidden: Bool
    let isBlobDeclared: Bool
}

struct AttachedSQLiteSample: Codable, Hashable, Sendable, Identifiable {
    var id: String { columnName }
    let columnName: String
    let values: [String]
}

struct AttachedSQLiteObjectPreview: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let kind: AttachedSQLiteObjectKind
    let columns: [AttachedSQLiteColumn]
    let primaryKeyColumns: [String]
    let identityStrategy: AttachedSQLiteIdentityStrategy
    let rowIDAlias: String?
    let boundedRowCount: Int
    let rowCountExceedsLimit: Bool
    let samples: [AttachedSQLiteSample]
    let isSelectable: Bool
    let exclusionReasonCode: String?

    var defaultSelectedColumns: [String] {
        columns.filter { !$0.isHidden && !$0.isBlobDeclared }.map(\.name)
    }
}

struct AttachedSQLitePreview: Codable, Hashable, Sendable {
    let objects: [AttachedSQLiteObjectPreview]
    let schemaDigest: String
    let sqliteVersion: String
}

struct AttachedSQLiteSelection: Codable, Hashable, Sendable {
    let objectName: String
    let selectedColumns: [String]
    let allowTruncation: Bool

    init(
        objectName: String,
        selectedColumns: [String],
        allowTruncation: Bool = false
    ) {
        self.objectName = objectName
        self.selectedColumns = Array(Set(selectedColumns)).sorted()
        self.allowTruncation = allowTruncation
    }
}

enum AttachedSQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(String)
    case text(String)
    case blobMetadata(byteCount: Int)

    var normalizedText: String {
        switch self {
        case .null: "null"
        case let .integer(value): String(value)
        case let .real(value): value
        case let .text(value): value
        case let .blobMetadata(byteCount): "<BLOB \(byteCount) bytes; content not indexed>"
        }
    }
}

struct AttachedSQLiteField: Hashable, Sendable {
    let name: String
    let value: AttachedSQLiteValue
}

struct AttachedSQLiteRecord: Hashable, Sendable {
    let objectName: String
    let stableIdentity: String
    let identityStrategy: AttachedSQLiteIdentityStrategy
    let fields: [AttachedSQLiteField]
    let normalizedText: String
    let canonicalRecordHash: String
    let blobCount: Int
}

struct AttachedSQLiteContainerMaterialization: Hashable, Sendable {
    let objectName: String
    let records: [AttachedSQLiteRecord]
    let truncatedCount: Int
}

struct AttachedSQLiteMaterialization: Hashable, Sendable {
    let containers: [AttachedSQLiteContainerMaterialization]
    let totalRecordCount: Int
    let totalMaterializedBytes: Int
    let truncationCount: Int
}

enum AttachedSQLiteDeniedOperationProbe: String, CaseIterable, Sendable {
    case insert
    case update
    case delete
    case create
    case drop
    case alter
    case attach
    case detach
    case vacuum
    case unsafePragma
    case loadExtension
    case doubleQuotedDMLLiteral
    case doubleQuotedDDLCheck
    case defensiveWritableSchema
}

typealias AttachedSQLiteQueryProgressTestHook = @Sendable (
    _ sql: String,
    _ invocation: Int
) -> Void

private final class AttachedSQLiteProgressContext: @unchecked Sendable {
    var deadline = AttachedDataOperationDeadline.distantFuture
    var interruption: AttachedSQLiteFailureCode?
    var statementSQL = ""
    var invocation = 0
    let testHook: AttachedSQLiteQueryProgressTestHook?

    init(testHook: AttachedSQLiteQueryProgressTestHook?) {
        self.testHook = testHook
    }

    func setDeadline(_ deadline: AttachedDataOperationDeadline) {
        self.deadline = deadline
        interruption = nil
        statementSQL = ""
        invocation = 0
    }

    func checkBudget() -> AttachedSQLiteFailureCode? {
        if Task.isCancelled {
            interruption = .cancelled
            return interruption
        }
        if deadline.hasExpired {
            interruption = .timedOut
            return interruption
        }
        return nil
    }

    func beginStatement(_ sql: String) {
        statementSQL = sql
        invocation = 0
    }

    func endStatement() {
        statementSQL = ""
        invocation = 0
    }

    func shouldInterrupt() -> Bool {
        invocation += 1
        testHook?(statementSQL, invocation)
        return checkBudget() != nil
    }
}

private final class AttachedSQLiteConnection {
    let database: OpaquePointer
    let progress: AttachedSQLiteProgressContext

    init(
        url: URL,
        readOnly: Bool,
        configureReadBoundary: Bool,
        progressTestHook: AttachedSQLiteQueryProgressTestHook? = nil
    ) throws {
        progress = AttachedSQLiteProgressContext(testHook: progressTestHook)
        let pathDescriptor = Darwin.open(
            url.path,
            (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW
        )
        guard pathDescriptor >= 0 else {
            throw AttachedSQLiteFailureCode.openFailed
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathResult = pathBuffer.withUnsafeMutableBufferPointer { storage in
            loki_attached_descriptor_path(
                pathDescriptor,
                storage.baseAddress,
                storage.count
            )
        }
        Darwin.close(pathDescriptor)
        guard pathResult == 0 else {
            throw AttachedSQLiteFailureCode.openFailed
        }
        let nofollowPath = String(cString: pathBuffer)
        var opened: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(nofollowPath, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw AttachedSQLiteFailureCode.openFailed
        }
        database = opened
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 250)
        if configureReadBoundary {
            try configureReadOnlyBoundary()
        }
    }

    deinit {
        sqlite3_progress_handler(database, 0, nil, nil)
        sqlite3_set_authorizer(database, nil, nil)
        sqlite3_close_v2(database)
    }

    func setDeadline(_ deadline: AttachedDataOperationDeadline) {
        progress.setDeadline(deadline)
    }

    func interruptionFailure() -> AttachedSQLiteFailureCode? {
        progress.interruption
    }

    func requireBudget() throws {
        if let failure = progress.checkBudget() { throw failure }
    }

    func beginStatement(_ sql: String) {
        progress.beginStatement(sql)
    }

    func endStatement() {
        progress.endStatement()
    }

    private func configureReadOnlyBoundary() throws {
        try requireConfiguration(
            operation: Int32(SQLITE_DBCONFIG_DEFENSIVE),
            value: 1
        )
        try requireConfiguration(
            operation: Int32(SQLITE_DBCONFIG_DQS_DML),
            value: 0
        )
        try requireConfiguration(
            operation: Int32(SQLITE_DBCONFIG_DQS_DDL),
            value: 0
        )
        try requireRejectedPrepare(
            "SELECT \"__loki_dqs_dml_literal_must_be_denied__\""
        )
        try requireDQS_DDLRejection()
        try requireDefensiveWritableSchemaDenial()

        // Apple's system SQLite omits the load-extension entry point, so
        // extension loading cannot be enabled through this process. The
        // authorizer below independently denies `load_extension` as a function.
        _ = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 2 * 1_024 * 1_024)
        _ = sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 64 * 1_024)
        _ = sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 256)
        _ = sqlite3_limit(database, SQLITE_LIMIT_EXPR_DEPTH, 64)
        _ = sqlite3_limit(database, SQLITE_LIMIT_COMPOUND_SELECT, 4)
        _ = sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, 16)
        _ = sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
        _ = sqlite3_limit(database, SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 256)
        _ = sqlite3_limit(database, SQLITE_LIMIT_TRIGGER_DEPTH, 0)
        _ = sqlite3_limit(database, SQLITE_LIMIT_WORKER_THREADS, 0)

        guard sqlite3_exec(
            database,
            "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw AttachedSQLiteFailureCode.openFailed }

        let progressPointer = Unmanaged.passUnretained(progress).toOpaque()
        sqlite3_progress_handler(database, 1_000, { raw in
            guard let raw else { return 1 }
            let value = Unmanaged<AttachedSQLiteProgressContext>
                .fromOpaque(raw).takeUnretainedValue()
            return value.shouldInterrupt() ? 1 : 0
        }, progressPointer)

        let result = sqlite3_set_authorizer(database, {
            _, action, first, second, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE:
                return SQLITE_OK
            case SQLITE_FUNCTION:
                let functionName = second.map { String(cString: $0).lowercased() }
                    ?? first.map { String(cString: $0).lowercased() }
                    ?? ""
                return ["coalesce", "count"].contains(functionName)
                    ? SQLITE_OK : SQLITE_DENY
            case SQLITE_PRAGMA:
                let pragmaName = first.map { String(cString: $0).lowercased() }
                    ?? ""
                return ["table_list", "table_xinfo"].contains(pragmaName)
                    ? SQLITE_OK : SQLITE_DENY
            default:
                return SQLITE_DENY
            }
        }, nil)
        guard result == SQLITE_OK else {
            throw AttachedSQLiteFailureCode.openFailed
        }
    }

    private func requireConfiguration(operation: Int32, value: Int32) throws {
        var effectiveValue: Int32 = -1
        let result = loki_attached_sqlite_db_config(
            database,
            operation,
            value,
            &effectiveValue
        )
        guard result == SQLITE_OK, effectiveValue == value else {
            throw AttachedSQLiteFailureCode.openFailed
        }
    }

    private func requireRejectedPrepare(_ sql: String) throws {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        if let statement { sqlite3_finalize(statement) }
        guard result == SQLITE_ERROR else {
            throw AttachedSQLiteFailureCode.openFailed
        }
    }

    private func requireDefensiveWritableSchemaDenial() throws {
        guard sqlite3_exec(
            database,
            "PRAGMA writable_schema=ON",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw AttachedSQLiteFailureCode.openFailed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            database,
            "PRAGMA writable_schema",
            -1,
            &statement,
            nil
        )
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw AttachedSQLiteFailureCode.openFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int(statement, 0) == 0
        else { throw AttachedSQLiteFailureCode.openFailed }
    }

    private func requireDQS_DDLRejection() throws {
        var probeDatabase: OpaquePointer?
        let opened = sqlite3_open_v2(
            ":memory:",
            &probeDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let probeDatabase else {
            if let probeDatabase { sqlite3_close_v2(probeDatabase) }
            throw AttachedSQLiteFailureCode.openFailed
        }
        defer { sqlite3_close_v2(probeDatabase) }
        var effectiveValue: Int32 = -1
        guard loki_attached_sqlite_db_config(
            probeDatabase,
            Int32(SQLITE_DBCONFIG_DQS_DDL),
            0,
            &effectiveValue
        ) == SQLITE_OK,
            effectiveValue == 0
        else { throw AttachedSQLiteFailureCode.openFailed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            probeDatabase,
            "CREATE TABLE __loki_dqs_ddl_probe__(value TEXT CHECK(value <> \"__loki_dqs_ddl_literal_must_be_denied__\"))",
            -1,
            &statement,
            nil
        )
        if let statement { sqlite3_finalize(statement) }
        guard result == SQLITE_ERROR else {
            throw AttachedSQLiteFailureCode.openFailed
        }
    }

}

actor AttachedSQLiteSource {
    enum SnapshotBindingPhase: Sendable {
        case descriptorOpened
        case readTransactionPinned
        case snapshotCaptured
        case retrying
    }

    typealias SnapshotBindingTestHook = @Sendable (
        SnapshotBindingPhase,
        URL
    ) throws -> Void

    private static let maximumSourceBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let limits: AttachedSQLiteLimits
    private let snapshotBindingTestHook: SnapshotBindingTestHook?
    private let queryProgressTestHook: AttachedSQLiteQueryProgressTestHook?

    init(
        limits: AttachedSQLiteLimits = .init(),
        snapshotBindingTestHook: SnapshotBindingTestHook? = nil,
        queryProgressTestHook: AttachedSQLiteQueryProgressTestHook? = nil
    ) throws {
        try limits.validate()
        self.limits = limits
        self.snapshotBindingTestHook = snapshotBindingTestHook
        self.queryProgressTestHook = queryProgressTestHook
    }

    static func hasSQLiteHeader(_ data: Data) -> Bool {
        data.count >= 16 && data.prefix(16) == Data("SQLite format 3\0".utf8)
    }

    func preview(
        at authorizedURL: URL,
        operationDeadline: AttachedDataOperationDeadline? = nil
    ) async throws -> AttachedSQLitePreview {
        try Task.checkCancellation()
        return try await withStableSnapshot(
            of: authorizedURL,
            operationDeadline: operationDeadline
        ) { connection in
            try Self.preview(connection: connection, limits: limits)
        }
    }

    func materialize(
        at authorizedURL: URL,
        selections: [AttachedSQLiteSelection],
        operationDeadline: AttachedDataOperationDeadline? = nil
    ) async throws -> AttachedSQLiteMaterialization {
        try Task.checkCancellation()
        guard !selections.isEmpty,
              Set(selections.map(\.objectName)).count == selections.count
        else { throw AttachedSQLiteFailureCode.invalidSelection }
        return try await withStableSnapshot(
            of: authorizedURL,
            operationDeadline: operationDeadline
        ) { connection in
            let preview = try Self.preview(connection: connection, limits: limits)
            return try Self.materialize(
                connection: connection,
                preview: preview,
                selections: selections,
                limits: limits
            )
        }
    }

    func probeDeniedOperation(
        at authorizedURL: URL,
        _ probe: AttachedSQLiteDeniedOperationProbe
    ) async throws -> Bool {
        try await withStableSnapshot(of: authorizedURL) { connection in
            let statementText: String
            switch probe {
            case .insert: statementText = "INSERT INTO __loki_probe__ VALUES (1)"
            case .update: statementText = "UPDATE __loki_probe__ SET value = 1"
            case .delete: statementText = "DELETE FROM __loki_probe__"
            case .create: statementText = "CREATE TABLE __loki_probe__(value)"
            case .drop: statementText = "DROP TABLE __loki_probe__"
            case .alter: statementText = "ALTER TABLE __loki_probe__ ADD COLUMN value"
            case .attach: statementText = "ATTACH DATABASE ':memory:' AS denied"
            case .detach: statementText = "DETACH DATABASE denied"
            case .vacuum: statementText = "VACUUM"
            case .unsafePragma: statementText = "PRAGMA writable_schema=ON"
            case .loadExtension: statementText = "SELECT load_extension('denied')"
            case .doubleQuotedDMLLiteral:
                statementText = "SELECT \"__loki_dqs_dml_literal_must_be_denied__\""
            case .doubleQuotedDDLCheck:
                statementText = "CREATE TABLE __loki_dqs_ddl_probe__(value TEXT CHECK(value <> \"__loki_dqs_ddl_literal_must_be_denied__\"))"
            case .defensiveWritableSchema:
                statementText = "PRAGMA writable_schema=ON"
            }
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(
                connection.database,
                statementText,
                -1,
                &statement,
                nil
            )
            let executionResult: Int32
            if result == SQLITE_OK, let statement {
                executionResult = sqlite3_step(statement)
            } else {
                executionResult = result
            }
            if let statement { sqlite3_finalize(statement) }
            return [SQLITE_AUTH, SQLITE_READONLY, SQLITE_ERROR]
                .contains(executionResult)
        }
    }

    private func withStableSnapshot<T>(
        of sourceURL: URL,
        operationDeadline: AttachedDataOperationDeadline? = nil,
        operation: (AttachedSQLiteConnection) throws -> T
    ) async throws -> T {
        let deadline = operationDeadline?.limited(
            to: limits.executionTimeSeconds
        ) ?? AttachedDataOperationDeadline(
            secondsFromNow: limits.executionTimeSeconds
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-attached-sqlite-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let temporaryDescriptor = Darwin.open(
            temporaryRoot.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard temporaryDescriptor >= 0 else {
            throw AttachedSQLiteFailureCode.snapshotFailed
        }
        let canonicalTemporaryRoot: URL
        do {
            canonicalTemporaryRoot = URL(
                fileURLWithPath: try Self.descriptorPath(temporaryDescriptor),
                isDirectory: true
            )
        } catch {
            Darwin.close(temporaryDescriptor)
            throw error
        }
        Darwin.close(temporaryDescriptor)
        let snapshotURL = canonicalTemporaryRoot.appendingPathComponent(
            "snapshot.sqlite"
        )
        try await Self.createStableSnapshot(
            from: sourceURL,
            expectedIdentity: nil,
            to: snapshotURL,
            maximumSourceBytes: Self.maximumSourceBytes,
            operationDeadline: deadline,
            bindingTestHook: snapshotBindingTestHook
        )
        let connection = try AttachedSQLiteConnection(
            url: snapshotURL,
            readOnly: true,
            configureReadBoundary: true,
            progressTestHook: queryProgressTestHook
        )
        connection.setDeadline(deadline)
        try connection.requireBudget()
        do {
            return try operation(connection)
        } catch let error as AttachedSQLiteFailureCode {
            throw error
        } catch {
            if let interruption = connection.interruptionFailure() {
                throw interruption
            }
            let code = sqlite3_extended_errcode(connection.database)
            if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
                throw AttachedSQLiteFailureCode.corrupt
            }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                throw AttachedSQLiteFailureCode.busy
            }
            throw AttachedSQLiteFailureCode.queryFailed
        }
    }

    static func createStableSnapshot(
        from sourceURL: URL,
        expectedIdentity: AttachedDataFileIdentity?,
        to snapshotURL: URL,
        maximumSourceBytes: Int64,
        executionTimeSeconds: TimeInterval = 15,
        bindingTestHook: SnapshotBindingTestHook? = nil
    ) async throws {
        guard maximumSourceBytes > 0 else {
            throw AttachedSQLiteFailureCode.sourceTooLarge
        }
        guard executionTimeSeconds.isFinite,
              (0.1 ... 300).contains(executionTimeSeconds)
        else { throw AttachedSQLiteFailureCode.invalidBudget }
        try await createStableSnapshot(
            from: sourceURL,
            expectedIdentity: expectedIdentity,
            to: snapshotURL,
            maximumSourceBytes: maximumSourceBytes,
            operationDeadline: .init(secondsFromNow: executionTimeSeconds),
            bindingTestHook: bindingTestHook
        )
    }

    static func createStableSnapshot(
        from sourceURL: URL,
        expectedIdentity: AttachedDataFileIdentity?,
        to snapshotURL: URL,
        maximumSourceBytes: Int64,
        operationDeadline: AttachedDataOperationDeadline,
        bindingTestHook: SnapshotBindingTestHook? = nil
    ) async throws {
        var lastRetryFailure: AttachedSQLiteSnapshotCaptureFailure?
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard !operationDeadline.hasExpired else {
                throw AttachedSQLiteFailureCode.timedOut
            }
            do {
                try captureStableSnapshot(
                    from: sourceURL,
                    expectedIdentity: expectedIdentity,
                    to: snapshotURL,
                    maximumSourceBytes: maximumSourceBytes,
                    deadline: operationDeadline,
                    bindingTestHook: bindingTestHook
                )
                return
            } catch let failure as AttachedSQLiteSnapshotCaptureFailure {
                lastRetryFailure = failure
                guard failure == .sourceChanged else { throw failure.publicFailure }
                try bindingTestHook?(.retrying, sourceURL.standardizedFileURL)
                await Task.yield()
            }
        }
        throw lastRetryFailure?.publicFailure ?? AttachedSQLiteFailureCode.snapshotFailed
    }

    private static func captureStableSnapshot(
        from sourceURL: URL,
        expectedIdentity: AttachedDataFileIdentity?,
        to snapshotURL: URL,
        maximumSourceBytes: Int64,
        deadline: AttachedDataOperationDeadline,
        bindingTestHook: SnapshotBindingTestHook?
    ) throws {
        guard !deadline.hasExpired else {
            throw AttachedSQLiteSnapshotCaptureFailure.timedOut
        }
        let canonical = sourceURL.standardizedFileURL
        let parentURL = canonical.deletingLastPathComponent().resolvingSymlinksInPath()
        let leafName = canonical.lastPathComponent
        guard !leafName.isEmpty, !leafName.contains("/") else {
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }

        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }
        defer { Darwin.close(parentDescriptor) }
        let descriptorParentPath = try descriptorPath(parentDescriptor)

        let sourceDescriptor = leafName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard sourceDescriptor >= 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }
        defer { Darwin.close(sourceDescriptor) }

        let sourceBefore = try descriptorIdentity(sourceDescriptor)
        if let expectedIdentity,
           !sourceBefore.matchesResource(expectedIdentity)
        {
            throw AttachedSQLiteSnapshotCaptureFailure.identityChanged
        }
        guard sourceBefore.fileSize <= maximumSourceBytes else {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceTooLarge
        }
        let header = try preadData(
            descriptor: sourceDescriptor,
            offset: 0,
            count: min(100, Int(sourceBefore.fileSize))
        )
        guard hasSQLiteHeader(header) else {
            throw ["db", "sqlite", "sqlite3"].contains(
                canonical.pathExtension.lowercased()
            )
                ? AttachedSQLiteSnapshotCaptureFailure.encryptedOrUnknown
                : AttachedSQLiteSnapshotCaptureFailure.invalidHeader
        }

        let walBinding = try openSidecar(
            parentDescriptor: parentDescriptor,
            leafName: leafName + "-wal"
        )
        defer { walBinding.close() }
        let walByteCount = walBinding.identity?.fileSize ?? 0
        guard walByteCount >= 0,
              walByteCount <= maximumSourceBytes - sourceBefore.fileSize
        else {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceTooLarge
        }

        let shmBinding = try openSidecar(
            parentDescriptor: parentDescriptor,
            leafName: leafName + "-shm"
        )
        defer { shmBinding.close() }
        let shmByteCount = shmBinding.identity?.fileSize ?? 0
        guard shmByteCount >= 0,
              shmByteCount <= maximumSourceBytes
                - sourceBefore.fileSize - walByteCount
        else {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceTooLarge
        }

        let journalBinding = try openSidecar(
            parentDescriptor: parentDescriptor,
            leafName: leafName + "-journal"
        )
        defer { journalBinding.close() }
        guard journalBinding.identity?.fileSize ?? 0 == 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceChanged
        }

        try requireCurrentPath(
            parentDescriptor: parentDescriptor,
            leafName: leafName,
            expected: sourceBefore,
            identityFailure: true
        )
        try validateSidecar(walBinding, parentDescriptor: parentDescriptor)
        try validateSidecar(
            shmBinding,
            parentDescriptor: parentDescriptor,
            requireStableMetadata: false
        )
        try validateSidecar(journalBinding, parentDescriptor: parentDescriptor)
        try bindingTestHook?(.descriptorOpened, canonical)

        let resolvedSourcePath = descriptorParentPath + "/" + leafName
        var sourceDatabase: OpaquePointer?
        let sourceOpenResult = sqlite3_open_v2(
            resolvedSourcePath,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard sourceOpenResult == SQLITE_OK, let sourceDatabase else {
            if let sourceDatabase { sqlite3_close_v2(sourceDatabase) }
            throw snapshotFailure(forSQLiteResult: sourceOpenResult, opening: true)
        }
        defer {
            _ = sqlite3_exec(sourceDatabase, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(sourceDatabase)
        }
        sqlite3_extended_result_codes(sourceDatabase, 1)
        sqlite3_busy_timeout(sourceDatabase, 250)
        guard sqlite3_db_readonly(sourceDatabase, "main") == 1,
              let openedFilename = sqlite3_db_filename(sourceDatabase, "main"),
              String(cString: openedFilename) == resolvedSourcePath
        else { throw AttachedSQLiteSnapshotCaptureFailure.identityChanged }

        try executeSnapshotSQL(
            sourceDatabase,
            sql: "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN"
        )
        try forceReadTransaction(on: sourceDatabase)
        try bindingTestHook?(.readTransactionPinned, canonical)
        guard !deadline.hasExpired else {
            throw AttachedSQLiteSnapshotCaptureFailure.timedOut
        }
        try validateSourceBinding(
            database: sourceDatabase,
            sourceDescriptor: sourceDescriptor,
            sourceBefore: sourceBefore,
            parentDescriptor: parentDescriptor,
            parentPath: descriptorParentPath,
            leafName: leafName,
            walBinding: walBinding,
            shmBinding: shmBinding,
            journalBinding: journalBinding,
            maximumSourceBytes: maximumSourceBytes
        )

        let destinationDescriptor = Darwin.open(
            snapshotURL.path,
            O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed
        }
        defer { Darwin.close(destinationDescriptor) }
        guard Darwin.fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed
        }
        let destinationBefore = try descriptorIdentity(destinationDescriptor)
        let destinationPath = try descriptorPath(destinationDescriptor)
        guard try pathIdentity(at: snapshotURL)?
            .matchesResource(destinationBefore) == true
        else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }

        var destinationDatabase: OpaquePointer?
        let destinationOpenResult = sqlite3_open_v2(
            destinationPath,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard destinationOpenResult == SQLITE_OK, let destinationDatabase else {
            if let destinationDatabase { sqlite3_close_v2(destinationDatabase) }
            throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed
        }
        sqlite3_extended_result_codes(destinationDatabase, 1)
        sqlite3_busy_timeout(destinationDatabase, 250)
        do {
            try backup(
                from: sourceDatabase,
                to: destinationDatabase,
                deadline: deadline
            )
            guard !deadline.hasExpired else {
                throw AttachedSQLiteSnapshotCaptureFailure.timedOut
            }
            try requireDeleteJournalMode(on: destinationDatabase)
        } catch {
            sqlite3_close_v2(destinationDatabase)
            throw error
        }
        guard sqlite3_close_v2(destinationDatabase) == SQLITE_OK,
              Darwin.fsync(destinationDescriptor) == 0
        else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }
        try removeTaskOwnedSnapshotSidecars(at: snapshotURL)

        try bindingTestHook?(.snapshotCaptured, canonical)
        try validateSourceBinding(
            database: sourceDatabase,
            sourceDescriptor: sourceDescriptor,
            sourceBefore: sourceBefore,
            parentDescriptor: parentDescriptor,
            parentPath: descriptorParentPath,
            leafName: leafName,
            walBinding: walBinding,
            shmBinding: shmBinding,
            journalBinding: journalBinding,
            maximumSourceBytes: maximumSourceBytes
        )

        let destinationAfter = try descriptorIdentity(destinationDescriptor)
        let destinationHeader = try preadData(
            descriptor: destinationDescriptor,
            offset: 0,
            count: min(100, Int(destinationAfter.fileSize))
        )
        var destinationInformation = stat()
        guard Darwin.fstat(destinationDescriptor, &destinationInformation) == 0,
              destinationAfter.matchesResource(destinationBefore),
              destinationAfter.linkCount == 1,
              UInt32(destinationInformation.st_mode & 0o777) == 0o600,
              destinationAfter.fileSize <= maximumSourceBytes,
              try pathIdentity(at: snapshotURL)?
                .matchesResource(destinationAfter) == true,
              !FileManager.default.fileExists(
                atPath: snapshotURL.path + "-wal"
              ),
              !FileManager.default.fileExists(
                atPath: snapshotURL.path + "-shm"
              ),
              !FileManager.default.fileExists(
                atPath: snapshotURL.path + "-journal"
              ),
              destinationHeader.count > 19,
              hasSQLiteHeader(destinationHeader),
              destinationHeader[18] == 1,
              destinationHeader[19] == 1
        else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }
    }

    private static func openSidecar(
        parentDescriptor: Int32,
        leafName: String
    ) throws -> AttachedSQLiteSidecarBinding {
        let descriptor = leafName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let failure = errno
            if failure == ENOENT {
                return .init(leafName: leafName, descriptor: nil, identity: nil)
            }
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }
        do {
            return .init(
                leafName: leafName,
                descriptor: descriptor,
                identity: try descriptorIdentity(descriptor)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateSourceBinding(
        database: OpaquePointer,
        sourceDescriptor: Int32,
        sourceBefore: AttachedDataFileIdentity,
        parentDescriptor: Int32,
        parentPath: String,
        leafName: String,
        walBinding: AttachedSQLiteSidecarBinding,
        shmBinding: AttachedSQLiteSidecarBinding,
        journalBinding: AttachedSQLiteSidecarBinding,
        maximumSourceBytes: Int64
    ) throws {
        var hasMoved: Int32 = 1
        guard sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_HAS_MOVED,
            &hasMoved
        ) == SQLITE_OK else {
            throw AttachedSQLiteSnapshotCaptureFailure.identityChanged
        }
        guard hasMoved == 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.identityChanged
        }
        guard try descriptorPath(parentDescriptor) == parentPath else {
            throw AttachedSQLiteSnapshotCaptureFailure.identityChanged
        }

        let sourceAfter = try descriptorIdentity(sourceDescriptor)
        guard sourceAfter.matchesSnapshot(sourceBefore) else {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceChanged
        }
        try requireCurrentPath(
            parentDescriptor: parentDescriptor,
            leafName: leafName,
            expected: sourceBefore,
            identityFailure: true
        )
        try validateSidecar(walBinding, parentDescriptor: parentDescriptor)
        try validateSidecar(
            shmBinding,
            parentDescriptor: parentDescriptor,
            requireStableMetadata: false
        )
        try validateSidecar(journalBinding, parentDescriptor: parentDescriptor)
        let walByteCount = try walBinding.descriptor.map {
            try descriptorIdentity($0).fileSize
        } ?? 0
        let shmByteCount = try shmBinding.descriptor.map {
            try descriptorIdentity($0).fileSize
        } ?? 0
        guard sourceAfter.fileSize >= 0,
              sourceAfter.fileSize <= maximumSourceBytes,
              walByteCount >= 0,
              walByteCount <= maximumSourceBytes - sourceAfter.fileSize,
              shmByteCount >= 0,
              shmByteCount <= maximumSourceBytes
                - sourceAfter.fileSize - walByteCount
        else { throw AttachedSQLiteSnapshotCaptureFailure.sourceTooLarge }
    }

    private static func requireCurrentPath(
        parentDescriptor: Int32,
        leafName: String,
        expected: AttachedDataFileIdentity,
        identityFailure: Bool
    ) throws {
        guard try pathIdentity(
            parentDescriptor: parentDescriptor,
            leafName: leafName
        )?.matchesResource(expected) == true else {
            throw identityFailure
                ? AttachedSQLiteSnapshotCaptureFailure.identityChanged
                : AttachedSQLiteSnapshotCaptureFailure.sourceChanged
        }
    }

    private static func validateSidecar(
        _ binding: AttachedSQLiteSidecarBinding,
        parentDescriptor: Int32,
        requireStableMetadata: Bool = true
    ) throws {
        if let descriptor = binding.descriptor,
           let expected = binding.identity
        {
            let current = try descriptorIdentity(descriptor)
            guard current.matchesResource(expected),
                  !requireStableMetadata || current.matchesSnapshot(expected),
                  try pathIdentity(
                    parentDescriptor: parentDescriptor,
                    leafName: binding.leafName
                  )?.matchesResource(expected) == true
            else { throw AttachedSQLiteSnapshotCaptureFailure.sourceChanged }
        } else if try pathIdentity(
            parentDescriptor: parentDescriptor,
            leafName: binding.leafName
        ) != nil {
            throw AttachedSQLiteSnapshotCaptureFailure.sourceChanged
        }
    }

    private static func removeTaskOwnedSnapshotSidecars(at snapshotURL: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let path = snapshotURL.path + suffix
            var information = stat()
            guard Darwin.lstat(path, &information) == 0 else {
                if errno == ENOENT { continue }
                throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed
            }
            guard UInt32(information.st_mode & S_IFMT) == UInt32(S_IFREG),
                  information.st_nlink == 1,
                  Darwin.unlink(path) == 0
            else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }
        }
    }

    private static func forceReadTransaction(on database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            database,
            "PRAGMA schema_version",
            -1,
            &statement,
            nil
        )
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw snapshotFailure(forSQLiteResult: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            throw snapshotFailure(forSQLiteResult: stepped)
        }
    }

    private static func executeSnapshotSQL(
        _ database: OpaquePointer,
        sql: String
    ) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw snapshotFailure(forSQLiteResult: result)
        }
    }

    private static func backup(
        from source: OpaquePointer,
        to destination: OpaquePointer,
        deadline: AttachedDataOperationDeadline
    ) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw snapshotFailure(
                forSQLiteResult: sqlite3_extended_errcode(destination)
            )
        }
        var result: Int32 = SQLITE_OK
        while result == SQLITE_OK {
            if Task.isCancelled {
                _ = sqlite3_backup_finish(backup)
                throw AttachedSQLiteSnapshotCaptureFailure.cancelled
            }
            if deadline.hasExpired {
                _ = sqlite3_backup_finish(backup)
                throw AttachedSQLiteSnapshotCaptureFailure.timedOut
            }
            result = sqlite3_backup_step(backup, 256)
        }
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw snapshotFailure(
                forSQLiteResult: result == SQLITE_DONE ? finished : result
            )
        }
    }

    private static func requireDeleteJournalMode(
        on database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            database,
            "PRAGMA journal_mode=DELETE",
            -1,
            &statement,
            nil
        )
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw snapshotFailure(forSQLiteResult: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let rowResult = sqlite3_step(statement)
        guard rowResult == SQLITE_ROW else {
            throw snapshotFailure(forSQLiteResult: rowResult)
        }
        guard let mode = sqlite3_column_text(statement, 0),
              String(cString: mode).lowercased() == "delete"
        else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }
        let doneResult = sqlite3_step(statement)
        guard doneResult == SQLITE_DONE else {
            throw snapshotFailure(forSQLiteResult: doneResult)
        }
    }

    private static func snapshotFailure(
        forSQLiteResult result: Int32,
        opening: Bool = false
    ) -> AttachedSQLiteSnapshotCaptureFailure {
        let primary = result & 0xFF
        switch primary {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .sourceChanged
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupt
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY:
            return opening ? .openFailed : .snapshotFailed
        case SQLITE_INTERRUPT:
            return Task.isCancelled ? .cancelled : .snapshotFailed
        default:
            return opening ? .openFailed : .snapshotFailed
        }
    }

    private static func pathIdentity(at url: URL) throws
        -> AttachedDataFileIdentity?
    {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed
        }
        defer { Darwin.close(descriptor) }
        return try descriptorIdentity(descriptor)
    }

    private static func preadData(
        descriptor: Int32,
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw AttachedSQLiteSnapshotCaptureFailure.snapshotFailed }
        var bytes = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let result = bytes.withUnsafeMutableBytes { storage in
                Darwin.pread(
                    descriptor,
                    storage.baseAddress?.advanced(by: total),
                    count - total,
                    off_t(offset + Int64(total))
                )
            }
            guard result > 0 else {
                throw AttachedSQLiteSnapshotCaptureFailure.sourceChanged
            }
            total += result
        }
        return Data(bytes)
    }

    private static func descriptorIdentity(_ descriptor: Int32) throws
        -> AttachedDataFileIdentity
    {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              UInt32(information.st_mode & S_IFMT) == UInt32(S_IFREG),
              information.st_nlink > 0
        else { throw AttachedSQLiteSnapshotCaptureFailure.openFailed }
        let identity = AttachedDataFileIdentity(
            deviceID: Int64(information.st_dev),
            inode: UInt64(information.st_ino),
            fileType: UInt32(information.st_mode & S_IFMT),
            linkCount: UInt64(information.st_nlink),
            fileSize: Int64(information.st_size),
            modificationNanoseconds:
                Int64(information.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(information.st_mtimespec.tv_nsec)
        )
        try identity.validate()
        return identity
    }

    private static func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { storage in
            loki_attached_descriptor_path(
                descriptor,
                storage.baseAddress,
                storage.count
            )
        }
        guard result == 0 else {
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }
        let path = String(cString: buffer)
        guard path.hasPrefix("/"),
              path.lengthOfBytes(using: .utf8) < Int(MAXPATHLEN)
        else { throw AttachedSQLiteSnapshotCaptureFailure.openFailed }
        return path
    }

    private static func pathIdentity(
        parentDescriptor: Int32,
        leafName: String
    ) throws -> AttachedDataFileIdentity? {
        let descriptor = leafName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AttachedSQLiteSnapshotCaptureFailure.openFailed
        }
        defer { Darwin.close(descriptor) }
        return try descriptorIdentity(descriptor)
    }

    private struct RawObject {
        let name: String
        let type: String
        let sql: String
    }

    private static func preview(
        connection: AttachedSQLiteConnection,
        limits: AttachedSQLiteLimits
    ) throws -> AttachedSQLitePreview {
        try connection.requireBudget()
        var catalog: [(name: String, type: String)] = []
        try query(
            connection,
            sql: "PRAGMA table_list",
            binds: []
        ) { statement in
            guard sqlite3_column_count(statement) >= 3 else {
                throw AttachedSQLiteFailureCode.unsafeSchema
            }
            let schema = try text(statement, column: 0, maximumBytes: 16)
            guard schema == "main" else { return }
            let type = try text(statement, column: 2, maximumBytes: 16)
            guard ["table", "view", "virtual", "shadow"].contains(type)
            else { return }
            guard catalog.count < VaultLimits.maximumConnectorGenerationContainers
            else { throw AttachedSQLiteFailureCode.unsafeSchema }
            catalog.append((
                name: try text(statement, column: 1, maximumBytes: 512),
                type: type
            ))
        }

        var rawObjects: [RawObject] = []
        rawObjects.reserveCapacity(catalog.count)
        for object in catalog {
            var definition = ""
            try query(
                connection,
                sql: "SELECT coalesce(sql, '') FROM sqlite_schema WHERE name = ? AND type IN ('table','view') LIMIT 1",
                binds: [.text(object.name)]
            ) { statement in
                definition = try text(
                    statement,
                    column: 0,
                    maximumBytes: 64 * 1_024
                )
            }
            rawObjects.append(.init(
                name: object.name,
                type: object.type,
                sql: definition
            ))
        }
        rawObjects.sort { $0.name < $1.name }

        let virtualNames = Set(rawObjects.filter {
            $0.type == "virtual"
                || $0.sql.uppercased().contains("CREATE VIRTUAL TABLE")
        }.map { $0.name.lowercased() })
        let shadowSuffixes = [
            "_data", "_idx", "_content", "_docsize", "_config",
            "_segments", "_segdir", "_stat",
            "_node", "_rowid", "_parent",
        ]
        var previews: [AttachedSQLiteObjectPreview] = []
        for raw in rawObjects {
            try Task.checkCancellation()
            let lowerName = raw.name.lowercased()
            let isInternal = lowerName.hasPrefix("sqlite_")
            let isVirtual = raw.type == "virtual"
                || virtualNames.contains(lowerName)
            let isShadow = raw.type == "shadow" || shadowSuffixes.contains { suffix in
                guard lowerName.hasSuffix(suffix) else { return false }
                return virtualNames.contains(String(lowerName.dropLast(suffix.count)))
            }
            let kind: AttachedSQLiteObjectKind
            if isInternal { kind = .internalTable }
            else if isShadow { kind = .shadowTable }
            else if isVirtual { kind = .virtualTable }
            else if raw.type == "view" { kind = .view }
            else { kind = .table }

            let columns = isInternal || isShadow || isVirtual
                ? []
                : try columns(
                    connection: connection,
                    objectName: raw.name,
                    limit: limits.maximumColumns
                )
            let primaryKeys = columns.filter { $0.primaryKeyOrdinal > 0 }
                .sorted { $0.primaryKeyOrdinal < $1.primaryKeyOrdinal }
                .map(\.name)
            let primaryKeyContainsBlob = columns.contains {
                $0.primaryKeyOrdinal > 0 && $0.isBlobDeclared
            }
            let withoutRowID = raw.sql.uppercased().contains("WITHOUT ROWID")
            let primaryKeyIsNonNull = !primaryKeys.isEmpty
                && (withoutRowID || columns
                    .filter { $0.primaryKeyOrdinal > 0 }
                    .allSatisfy { !$0.isNullable })
            let declaredNames = Set(columns.map { $0.name.lowercased() })
            let availableRowIDAlias = kind == .table && !withoutRowID
                ? ["rowid", "_rowid_", "oid"].first {
                    !declaredNames.contains($0)
                }
                : nil
            let identity: AttachedSQLiteIdentityStrategy
            if !primaryKeyContainsBlob, primaryKeyIsNonNull,
               primaryKeys.count == 1
            {
                identity = .declaredPrimaryKey
            } else if !primaryKeyContainsBlob, primaryKeyIsNonNull,
                      primaryKeys.count > 1
            {
                identity = .compositePrimaryKey
            } else if availableRowIDAlias != nil {
                identity = .rowID
            }
            else { identity = .selectedRecordDigest }
            let selectable = !isInternal && !isShadow && !isVirtual
                && !columns.isEmpty
            let count = selectable
                ? try boundedCount(
                    connection: connection,
                    objectName: raw.name,
                    maximum: limits.maximumRecords
                ) : (0, false)
            let defaultColumns = columns.filter {
                !$0.isHidden && !$0.isBlobDeclared
            }.map(\.name)
            let samples = selectable
                ? try sampleValues(
                    connection: connection,
                    objectName: raw.name,
                    columns: Array(defaultColumns.prefix(12)),
                    maximumTextBytes: min(limits.maximumTextBytes, 256)
                ) : []
            previews.append(.init(
                name: raw.name,
                kind: kind,
                columns: columns,
                primaryKeyColumns: primaryKeys,
                identityStrategy: identity,
                rowIDAlias: identity == .rowID ? availableRowIDAlias : nil,
                boundedRowCount: count.0,
                rowCountExceedsLimit: count.1,
                samples: samples,
                isSelectable: selectable,
                exclusionReasonCode: selectable ? nil
                    : "attached_sqlite_\(kind.rawValue)_excluded"
            ))
        }
        let schemaMaterial = previews.map { preview in
            ([preview.kind.rawValue, preview.name,
              preview.identityStrategy.rawValue, preview.rowIDAlias ?? "none"]
            + preview.columns.flatMap {
                [$0.name, $0.declaredType, String($0.primaryKeyOrdinal),
                 String($0.isNullable), String($0.isHidden)]
            }).joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return .init(
            objects: previews,
            schemaDigest: digest(schemaMaterial),
            sqliteVersion: String(cString: sqlite3_libversion())
        )
    }

    private static func columns(
        connection: AttachedSQLiteConnection,
        objectName: String,
        limit: Int
    ) throws -> [AttachedSQLiteColumn] {
        var values: [AttachedSQLiteColumn] = []
        try query(
            connection,
            sql: "PRAGMA table_xinfo(\(try quoteIdentifier(objectName)))",
            binds: []
        ) { statement in
            guard values.count < limit else {
                throw AttachedSQLiteFailureCode.unsafeSchema
            }
            let declared = try text(statement, column: 2, maximumBytes: 512)
            values.append(.init(
                name: try text(statement, column: 1, maximumBytes: 512),
                declaredType: declared,
                isNullable: sqlite3_column_int(statement, 3) == 0,
                primaryKeyOrdinal: Int(sqlite3_column_int(statement, 5)),
                isHidden: sqlite3_column_count(statement) > 6
                    && sqlite3_column_int(statement, 6) != 0,
                isBlobDeclared: declared.uppercased().contains("BLOB")
            ))
        }
        return values
    }

    private static func boundedCount(
        connection: AttachedSQLiteConnection,
        objectName: String,
        maximum: Int
    ) throws -> (Int, Bool) {
        var count = 0
        let sql = "SELECT count(*) FROM (SELECT 1 FROM \(try quoteIdentifier(objectName)) LIMIT ?)"
        try query(connection, sql: sql, binds: [.integer(Int64(maximum + 1))]) {
            statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return (min(count, maximum), count > maximum)
    }

    private static func sampleValues(
        connection: AttachedSQLiteConnection,
        objectName: String,
        columns: [String],
        maximumTextBytes: Int
    ) throws -> [AttachedSQLiteSample] {
        guard !columns.isEmpty else { return [] }
        let projection = try columns.map(quoteIdentifier).joined(separator: ",")
        var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, [String]()) })
        try query(
            connection,
            sql: "SELECT \(projection) FROM \(try quoteIdentifier(objectName)) LIMIT 3",
            binds: []
        ) { statement in
            for (index, column) in columns.enumerated() {
                let normalized = try value(
                    statement,
                    column: Int32(index),
                    maximumTextBytes: maximumTextBytes
                ).normalizedText
                values[column, default: []].append(String(normalized.prefix(80)))
            }
        }
        return columns.map { .init(columnName: $0, values: values[$0] ?? []) }
    }

    private static func materialize(
        connection: AttachedSQLiteConnection,
        preview: AttachedSQLitePreview,
        selections: [AttachedSQLiteSelection],
        limits: AttachedSQLiteLimits
    ) throws -> AttachedSQLiteMaterialization {
        try connection.requireBudget()
        var containers: [AttachedSQLiteContainerMaterialization] = []
        var totalRecords = 0
        var totalBytes = 0
        var totalTruncation = 0
        let orderedSelections = selections.sorted { first, second in
            if first.allowTruncation != second.allowTruncation {
                return !first.allowTruncation
            }
            return first.objectName < second.objectName
        }
        for selection in orderedSelections {
            try Task.checkCancellation()
            guard let object = preview.objects.first(where: {
                $0.name == selection.objectName
            }), object.isSelectable,
            !selection.selectedColumns.isEmpty,
            selection.selectedColumns.count <= limits.maximumColumns,
            Set(selection.selectedColumns).isSubset(
                of: Set(object.columns.filter { !$0.isHidden }.map(\.name))
            ) else { throw AttachedSQLiteFailureCode.invalidSelection }

            var records: [AttachedSQLiteRecord] = []
            var offset = 0
            var truncated = 0
            if totalRecords >= limits.maximumRecords {
                guard selection.allowTruncation else {
                    throw AttachedSQLiteFailureCode.resultLimitExceeded
                }
                containers.append(.init(
                    objectName: object.name,
                    records: [],
                    truncatedCount: 1
                ))
                totalTruncation += 1
                continue
            }
            while totalRecords < limits.maximumRecords {
                try Task.checkCancellation()
                let remaining = limits.maximumRecords - totalRecords
                let pageLimit = min(limits.pageSize, remaining)
                let page = try readPage(
                    connection: connection,
                    object: object,
                    selectedColumns: selection.selectedColumns,
                    limit: pageLimit,
                    offset: offset,
                    maximumTextBytes: limits.maximumTextBytes,
                    maximumRecordBytes: limits.maximumRecordBytes
                )
                for record in page {
                    let bytes = record.normalizedText.lengthOfBytes(using: .utf8)
                    guard bytes <= limits.maximumMaterializedBytes - totalBytes else {
                        throw AttachedSQLiteFailureCode.materializedBytesExceeded
                    }
                    records.append(record)
                    totalBytes += bytes
                    totalRecords += 1
                }
                offset += page.count
                if page.count < pageLimit { break }
            }
            if totalRecords == limits.maximumRecords {
                let hasMore = try !readPage(
                    connection: connection,
                    object: object,
                    selectedColumns: selection.selectedColumns,
                    limit: 1,
                    offset: offset,
                    maximumTextBytes: limits.maximumTextBytes,
                    maximumRecordBytes: limits.maximumRecordBytes
                ).isEmpty
                if hasMore {
                    guard selection.allowTruncation else {
                        throw AttachedSQLiteFailureCode.resultLimitExceeded
                    }
                    truncated = 1
                    totalTruncation += 1
                }
            }
            containers.append(.init(
                objectName: object.name,
                records: records,
                truncatedCount: truncated
            ))
        }
        return .init(
            containers: containers,
            totalRecordCount: totalRecords,
            totalMaterializedBytes: totalBytes,
            truncationCount: totalTruncation
        )
    }

    private static func readPage(
        connection: AttachedSQLiteConnection,
        object: AttachedSQLiteObjectPreview,
        selectedColumns: [String],
        limit: Int,
        offset: Int,
        maximumTextBytes: Int,
        maximumRecordBytes: Int
    ) throws -> [AttachedSQLiteRecord] {
        let identityColumns: [String]
        switch object.identityStrategy {
        case .declaredPrimaryKey, .compositePrimaryKey:
            identityColumns = object.primaryKeyColumns
        case .rowID, .selectedRecordDigest:
            identityColumns = []
        }
        let requestedColumns = Array(Set(selectedColumns + identityColumns)).sorted()
        var projection = try requestedColumns.map(quoteIdentifier)
        if object.identityStrategy == .rowID {
            guard let rowIDAlias = object.rowIDAlias else {
                throw AttachedSQLiteFailureCode.unsafeSchema
            }
            projection.append(
                "\(try quoteIdentifier(rowIDAlias)) AS \"__loki_rowid__\""
            )
        }
        let ordering: String
        if !identityColumns.isEmpty {
            ordering = try identityColumns.map(quoteIdentifier).joined(separator: ",")
        } else if object.identityStrategy == .rowID,
                  let rowIDAlias = object.rowIDAlias
        {
            ordering = try quoteIdentifier(rowIDAlias)
        } else {
            ordering = try selectedColumns.map(quoteIdentifier).joined(separator: ",")
        }
        let sql = "SELECT \(projection.joined(separator: ",")) FROM \(try quoteIdentifier(object.name))\(ordering.isEmpty ? "" : " ORDER BY \(ordering)") LIMIT ? OFFSET ?"
        var records: [AttachedSQLiteRecord] = []
        try query(
            connection,
            sql: sql,
            binds: [.integer(Int64(limit)), .integer(Int64(offset))]
        ) { statement in
            var allValues: [String: AttachedSQLiteValue] = [:]
            for (index, name) in requestedColumns.enumerated() {
                allValues[name] = try value(
                    statement,
                    column: Int32(index),
                    maximumTextBytes: maximumTextBytes
                )
            }
            let rowIDIndex = requestedColumns.count
            let identityMaterial: String
            switch object.identityStrategy {
            case .declaredPrimaryKey, .compositePrimaryKey:
                identityMaterial = object.primaryKeyColumns.map {
                    "\($0)=\(allValues[$0]?.normalizedText ?? "null")"
                }.joined(separator: "\u{1f}")
            case .rowID:
                identityMaterial = String(sqlite3_column_int64(
                    statement,
                    Int32(rowIDIndex)
                ))
            case .selectedRecordDigest:
                identityMaterial = selectedColumns.sorted().map {
                    "\($0)=\(allValues[$0]?.normalizedText ?? "null")"
                }.joined(separator: "\u{1f}")
            }
            let fields = selectedColumns.sorted().map {
                AttachedSQLiteField(
                    name: $0,
                    value: allValues[$0] ?? .null
                )
            }
            let text = fields.map { "\($0.name): \($0.value.normalizedText)" }
                .joined(separator: "\n")
            guard text.lengthOfBytes(using: .utf8) <= maximumRecordBytes else {
                throw AttachedSQLiteFailureCode.recordBytesExceeded
            }
            let canonical = ([object.name, identityMaterial] + fields.flatMap {
                [$0.name, $0.value.normalizedText]
            }).joined(separator: "\u{1e}")
            records.append(.init(
                objectName: object.name,
                stableIdentity: digest(
                    "\(object.name)\u{1f}\(object.identityStrategy.rawValue)\u{1f}\(identityMaterial)"
                ),
                identityStrategy: object.identityStrategy,
                fields: fields,
                normalizedText: text,
                canonicalRecordHash: digest(canonical),
                blobCount: fields.reduce(0) {
                    if case .blobMetadata = $1.value { return $0 + 1 }
                    return $0
                }
            ))
        }
        return records
    }

    private enum BindValue {
        case integer(Int64)
        case text(String)
    }

    private static func query(
        _ connection: AttachedSQLiteConnection,
        sql: String,
        binds: [BindValue],
        row: (OpaquePointer) throws -> Void
    ) throws {
        try connection.requireBudget()
        guard sql.lengthOfBytes(using: .utf8) <= 64 * 1_024 else {
            throw AttachedSQLiteFailureCode.queryDenied
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            connection.database,
            sql,
            -1,
            &statement,
            nil
        )
        guard prepared == SQLITE_OK, let statement else {
            switch prepared & 0xFF {
            case SQLITE_AUTH, SQLITE_READONLY:
                throw AttachedSQLiteFailureCode.queryDenied
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw AttachedSQLiteFailureCode.busy
            case SQLITE_CORRUPT, SQLITE_NOTADB:
                throw AttachedSQLiteFailureCode.corrupt
            default:
                break
            }
            if let failure = connection.interruptionFailure() { throw failure }
            throw AttachedSQLiteFailureCode.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        connection.beginStatement(sql)
        defer { connection.endStatement() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch bind {
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            }
            guard result == SQLITE_OK else {
                throw AttachedSQLiteFailureCode.queryFailed
            }
        }
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                try row(statement)
                try connection.requireBudget()
            case SQLITE_DONE:
                try connection.requireBudget()
                return
            case SQLITE_INTERRUPT:
                throw connection.interruptionFailure() ?? .cancelled
            case SQLITE_AUTH, SQLITE_READONLY:
                throw AttachedSQLiteFailureCode.queryDenied
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw AttachedSQLiteFailureCode.busy
            case SQLITE_CORRUPT, SQLITE_NOTADB:
                throw AttachedSQLiteFailureCode.corrupt
            default:
                throw AttachedSQLiteFailureCode.queryFailed
            }
        }
    }

    private static func value(
        _ statement: OpaquePointer,
        column: Int32,
        maximumTextBytes: Int
    ) throws -> AttachedSQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            let number = sqlite3_column_double(statement, column)
            return .real(number.isFinite ? String(number) : "non_finite")
        case SQLITE_TEXT:
            let byteCount = Int(sqlite3_column_bytes(statement, column))
            guard byteCount <= maximumTextBytes,
                  let pointer = sqlite3_column_text(statement, column)
            else { throw AttachedSQLiteFailureCode.recordBytesExceeded }
            let data = Data(bytes: pointer, count: byteCount)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AttachedSQLiteFailureCode.invalidText
            }
            return .text(text)
        case SQLITE_BLOB:
            return .blobMetadata(
                byteCount: Int(sqlite3_column_bytes(statement, column))
            )
        default:
            throw AttachedSQLiteFailureCode.queryFailed
        }
    }

    private static func text(
        _ statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int
    ) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBytes,
              let pointer = sqlite3_column_text(statement, column)
        else { throw AttachedSQLiteFailureCode.unsafeSchema }
        let data = Data(bytes: pointer, count: count)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AttachedSQLiteFailureCode.invalidText
        }
        return value
    }

    private static func quoteIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.lengthOfBytes(using: .utf8) <= 512,
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else { throw AttachedSQLiteFailureCode.unsafeSchema }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private enum AttachedSQLiteSnapshotCaptureFailure: Error, Equatable {
    case invalidHeader
    case encryptedOrUnknown
    case openFailed
    case snapshotFailed
    case sourceChanged
    case identityChanged
    case sourceTooLarge
    case corrupt
    case cancelled
    case timedOut

    var publicFailure: AttachedSQLiteFailureCode {
        switch self {
        case .invalidHeader: .invalidHeader
        case .encryptedOrUnknown: .encryptedOrUnknown
        case .openFailed: .openFailed
        case .snapshotFailed: .snapshotFailed
        case .sourceChanged: .busy
        case .identityChanged: .sourceIdentityChanged
        case .sourceTooLarge: .sourceTooLarge
        case .corrupt: .corrupt
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        }
    }
}

private struct AttachedSQLiteSidecarBinding {
    let leafName: String
    let descriptor: Int32?
    let identity: AttachedDataFileIdentity?

    func close() {
        if let descriptor { Darwin.close(descriptor) }
    }
}
