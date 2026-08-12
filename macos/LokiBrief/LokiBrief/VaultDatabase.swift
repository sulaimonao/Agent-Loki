import CryptoKit
import Foundation
import SQLite3

actor VaultDatabase {
    fileprivate enum SQLValue {
        case text(String)
        case integer(Int64)
        case blob(Data)
        case null
    }

    fileprivate struct Bootstrap {
        let connection: OpaquePointer
        let disposition: VaultOpenDisposition
        let ftsAvailable: Bool
    }

    private static let requiredBaseTables: Set<String> = [
        "vault_schema_migrations",
        "vault_features",
        "vault_accounts",
        "vault_connector_generations",
        "vault_containers",
        "vault_records",
        "vault_revisions",
        "vault_tombstones",
        "vault_participants",
        "vault_item_participants",
        "vault_provenance",
        "vault_sync_cursors",
        "vault_sync_runs",
        "vault_backfill_jobs",
        "vault_storage_statistics",
    ]

    private var connection: OpaquePointer?
    private(set) var openDisposition: VaultOpenDisposition
    private var ftsAvailable: Bool
    private let databaseURL: URL?
    private let isInMemory: Bool
    private let traceSink: VaultTraceSink

    init(
        url: URL,
        trace: VaultTraceContext = .init(),
        traceSink: @escaping VaultTraceSink = { event in VaultProductionTraceLogger.emit(event) }
    ) throws {
        let bootstrap = try Self.bootstrap(
            url: url,
            inMemory: false,
            trace: trace,
            traceSink: traceSink
        )
        databaseURL = url.resolvingSymlinksInPath().standardizedFileURL
        isInMemory = false
        connection = bootstrap.connection
        openDisposition = bootstrap.disposition
        ftsAvailable = bootstrap.ftsAvailable
        self.traceSink = traceSink
    }

    init(
        inMemory: Bool,
        trace: VaultTraceContext = .init(),
        traceSink: @escaping VaultTraceSink = { event in VaultProductionTraceLogger.emit(event) }
    ) throws {
        precondition(inMemory, "Use init(url:) for a file-backed Loki Vault.")
        let bootstrap = try Self.bootstrap(
            url: nil,
            inMemory: true,
            trace: trace,
            traceSink: traceSink
        )
        databaseURL = nil
        isInMemory = true
        connection = bootstrap.connection
        openDisposition = bootstrap.disposition
        ftsAvailable = bootstrap.ftsAvailable
        self.traceSink = traceSink
    }

    deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    // MARK: - Accounts and containers

    func accounts() throws -> [VaultAccount] {
        let db = try activeConnection(operation: "account_list")
        var values: [VaultAccount] = []
        try Self.query(
            db,
            sql: "SELECT id, provider, provider_account_id, display_name, created_at, updated_at FROM vault_accounts ORDER BY provider, display_name COLLATE NOCASE, id",
            operation: "account_list"
        ) { statement in
            values.append(.init(
                id: Self.text(statement, 0), provider: Self.text(statement, 1),
                providerAccountID: Self.text(statement, 2), displayName: Self.text(statement, 3),
                createdAt: Self.date(statement, 4), updatedAt: Self.date(statement, 5)
            ))
        }
        return values
    }

    func containers(accountID: String? = nil) throws -> [VaultContainer] {
        if let accountID { try Self.validateIdentifier(accountID, field: "account_id") }
        let db = try activeConnection(operation: "container_list")
        var values: [VaultContainer] = []
        let filter = accountID == nil ? "" : " WHERE account_id = ?"
        try Self.query(
            db,
            sql: "SELECT id, account_id, provider_container_id, kind, display_name, created_at, updated_at FROM vault_containers\(filter) ORDER BY account_id, display_name COLLATE NOCASE, id",
            binds: accountID.map { [.text($0)] } ?? [],
            operation: "container_list"
        ) { statement in
            values.append(.init(
                id: Self.text(statement, 0), accountID: Self.text(statement, 1),
                providerContainerID: Self.text(statement, 2), kind: Self.text(statement, 3),
                displayName: Self.text(statement, 4), createdAt: Self.date(statement, 5),
                updatedAt: Self.date(statement, 6)
            ))
        }
        return values
    }

    @discardableResult
    func upsert(account: VaultAccountInput, trace: VaultTraceContext = .init()) throws -> VaultAccount {
        try Self.validateAccount(account)
        let db = try activeConnection(operation: "account_upsert")
        let started = Date()
        do {
            try Self.withTransaction(db, operation: "account_upsert") {
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_accounts(id, provider, provider_account_id, display_name, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        provider = excluded.provider,
                        provider_account_id = excluded.provider_account_id,
                        display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """,
                    binds: [
                        .text(account.id), .text(account.provider), .text(account.providerAccountID),
                        .text(account.displayName), .integer(Self.milliseconds(account.createdAt)),
                        .integer(Self.milliseconds(account.updatedAt)),
                    ],
                    operation: "account_upsert"
                )
            }
            emit(.accountUpsert, trace: trace, status: .success, reason: "vault_account_upserted", started: started,
                 metadata: [(.accountHash, VaultPrivacy.hashIdentifier(account.id))])
            return VaultAccount(
                id: account.id, provider: account.provider, providerAccountID: account.providerAccountID,
                displayName: account.displayName, createdAt: account.createdAt, updatedAt: account.updatedAt
            )
        } catch {
            emitFailure(.accountUpsert, trace: trace, error: error, started: started,
                        metadata: [(.accountHash, VaultPrivacy.hashIdentifier(account.id))])
            throw error
        }
    }

    @discardableResult
    func upsert(container: VaultContainerInput, trace: VaultTraceContext = .init()) throws -> VaultContainer {
        try Self.validateContainer(container)
        let db = try activeConnection(operation: "container_upsert")
        let started = Date()
        do {
            guard try Self.scalarInt(db, sql: "SELECT count(*) FROM vault_accounts WHERE id = ?", binds: [.text(container.accountID)], operation: "container_account_check") == 1 else {
                throw Self.failure("vault_account_not_found", operation: "container_upsert", recovery: .healthy)
            }
            try Self.withTransaction(db, operation: "container_upsert") {
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_containers(id, account_id, provider_container_id, kind, display_name, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        provider_container_id = excluded.provider_container_id,
                        kind = excluded.kind,
                        display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """,
                    binds: [
                        .text(container.id), .text(container.accountID), .text(container.providerContainerID),
                        .text(container.kind), .text(container.displayName),
                        .integer(Self.milliseconds(container.createdAt)), .integer(Self.milliseconds(container.updatedAt)),
                    ],
                    operation: "container_upsert"
                )
            }
            emit(.containerUpsert, trace: trace, status: .success, reason: "vault_container_upserted", started: started,
                 metadata: [
                    (.accountHash, VaultPrivacy.hashIdentifier(container.accountID)),
                    (.containerHash, VaultPrivacy.hashIdentifier(container.id)),
                 ])
            return VaultContainer(
                id: container.id, accountID: container.accountID, providerContainerID: container.providerContainerID,
                kind: container.kind, displayName: container.displayName,
                createdAt: container.createdAt, updatedAt: container.updatedAt
            )
        } catch {
            emitFailure(.containerUpsert, trace: trace, error: error, started: started,
                        metadata: [(.containerHash, VaultPrivacy.hashIdentifier(container.id))])
            throw error
        }
    }

    /// Commits one already-normalized connector page as a single Vault
    /// transaction. Connector cursors and receipts are advanced by the caller
    /// only after this method returns, so cancellation or a write failure can
    /// safely replay the exact page through stable record identifiers.
    func commit(
        connectorPage page: VaultConnectorPageMutation,
        trace: VaultTraceContext = .init()
    ) throws -> VaultConnectorCommitResult {
        try Self.validateAccount(page.account)
        try Self.validateContainer(page.container)
        guard page.container.accountID == page.account.id,
              ConnectorEnvelopeValidation.validSHA256(
                page.paginationReceiptHash
              ),
              page.records.count + page.tombstones.count > 0,
              page.records.count + page.tombstones.count
                <= VaultLimits.maximumBatchSize,
              Set(page.records.map(\.id)).count == page.records.count,
              Set(page.tombstones.map(\.recordID)).count
                == page.tombstones.count,
              Set(page.records.map(\.id)).isDisjoint(
                with: Set(page.tombstones.map(\.recordID))
              )
        else {
            throw Self.failure(
                "vault_connector_page_invalid",
                operation: "connector_page_commit",
                recovery: .healthy
            )
        }
        try page.records.forEach(Self.validateRecord)
        guard page.records.allSatisfy({
            $0.accountID == page.account.id
                && $0.containerID == page.container.id
        }) else {
            throw Self.failure(
                "vault_connector_scope_mismatch",
                operation: "connector_page_commit",
                recovery: .healthy
            )
        }
        let db = try activeConnection(operation: "connector_page_commit")
        let started = Date()
        do {
            var results: [VaultUpsertResult] = []
            var tombstonedCount = 0
            var tombstoneNotFoundCount = 0
            try Self.withTransaction(db, operation: "connector_page_commit") {
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_accounts(id, provider, provider_account_id, display_name, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        provider = excluded.provider,
                        provider_account_id = excluded.provider_account_id,
                        display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """,
                    binds: [
                        .text(page.account.id),
                        .text(page.account.provider),
                        .text(page.account.providerAccountID),
                        .text(page.account.displayName),
                        .integer(Self.milliseconds(page.account.createdAt)),
                        .integer(Self.milliseconds(page.account.updatedAt)),
                    ],
                    operation: "connector_account_upsert"
                )
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_containers(id, account_id, provider_container_id, kind, display_name, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        provider_container_id = excluded.provider_container_id,
                        kind = excluded.kind,
                        display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """,
                    binds: [
                        .text(page.container.id),
                        .text(page.container.accountID),
                        .text(page.container.providerContainerID),
                        .text(page.container.kind),
                        .text(page.container.displayName),
                        .integer(Self.milliseconds(page.container.createdAt)),
                        .integer(Self.milliseconds(page.container.updatedAt)),
                    ],
                    operation: "connector_container_upsert"
                )
                for record in page.records {
                    results.append(try Self.upsertRecord(record, db: db))
                }
                for tombstone in page.tombstones {
                    if let existing = try Self.existingRecord(
                        id: tombstone.recordID,
                        db: db
                    ) {
                        guard existing.accountID == page.account.id,
                              existing.containerID == page.container.id,
                              existing.providerRecordID
                                == tombstone.providerRecordID
                        else {
                            throw Self.failure(
                                "vault_connector_tombstone_scope_mismatch",
                                operation: "connector_page_commit",
                                recovery: .healthy
                            )
                        }
                    }
                    let result = try Self.tombstoneRecord(
                        recordID: tombstone.recordID,
                        reason: .sourceDeleted,
                        deletedAt: tombstone.deletedAt,
                        db: db
                    )
                    if result == nil {
                        tombstoneNotFoundCount += 1
                    } else {
                        tombstonedCount += 1
                    }
                }
            }
            let dispositions = Dictionary(
                grouping: results,
                by: \.disposition
            ).mapValues(\.count)
            let result = VaultConnectorCommitResult(
                insertedCount: dispositions[.inserted, default: 0],
                updatedCount: dispositions[.updated, default: 0],
                unchangedCount: dispositions[.unchanged, default: 0],
                resurrectedCount: dispositions[.resurrected, default: 0],
                tombstonedCount: tombstonedCount,
                tombstoneNotFoundCount: tombstoneNotFoundCount,
                paginationReceiptHash: page.paginationReceiptHash
            )
            emit(
                .recordUpsert,
                trace: trace,
                status: .success,
                reason: "vault_connector_page_committed",
                started: started,
                metadata: [
                    (.accountHash, VaultPrivacy.hashIdentifier(page.account.id)),
                    (.containerHash, VaultPrivacy.hashIdentifier(page.container.id)),
                    (.recordCount, String(page.records.count)),
                    (.tombstoneCount, String(page.tombstones.count)),
                ]
            )
            return result
        } catch {
            emitFailure(
                .recordUpsert,
                trace: trace,
                error: error,
                started: started,
                metadata: [
                    (.accountHash, VaultPrivacy.hashIdentifier(page.account.id)),
                    (.containerHash, VaultPrivacy.hashIdentifier(page.container.id)),
                    (.recordCount, String(page.records.count)),
                ]
            )
            throw error
        }
    }

    /// Atomically replaces one connector account's complete admitted
    /// generation. The caller performs all external-file reads and
    /// normalization before entering this transaction. Existing records stay
    /// readable until commit succeeds; omitted records become source-deletion
    /// tombstones in the same commit.
    func replaceConnectorGeneration(
        _ generation: VaultConnectorGenerationMutation,
        trace: VaultTraceContext = .init()
    ) throws -> VaultConnectorGenerationCommitResult {
        try Self.validateAccount(generation.account)
        guard !generation.containers.isEmpty,
              generation.containers.count
                <= VaultLimits.maximumConnectorGenerationContainers,
              generation.records.count
                <= VaultLimits.maximumConnectorGenerationRecords,
              ConnectorEnvelopeValidation.validSHA256(
                generation.generationReceiptHash
              ),
              generation.attachmentBlobCount >= 0,
              generation.truncationCount >= 0,
              generation.materializedByteCount >= 0,
              Set(generation.containers.map(\.id)).count
                == generation.containers.count,
              Set(generation.records.map(\.id)).count
                == generation.records.count
        else {
            throw Self.failure(
                "vault_connector_generation_invalid",
                operation: "connector_generation_replace",
                recovery: .healthy
            )
        }

        let containerIDs = Set(generation.containers.map(\.id))
        for container in generation.containers {
            try Self.validateContainer(container)
            guard container.accountID == generation.account.id else {
                throw Self.failure(
                    "vault_connector_generation_scope_mismatch",
                    operation: "connector_generation_replace",
                    recovery: .healthy
                )
            }
        }
        for record in generation.records {
            try Self.validateRecord(record)
            guard record.accountID == generation.account.id,
                  containerIDs.contains(record.containerID)
            else {
                throw Self.failure(
                    "vault_connector_generation_scope_mismatch",
                    operation: "connector_generation_replace",
                    recovery: .healthy
                )
            }
        }

        let db = try activeConnection(operation: "connector_generation_replace")
        let started = Date()
        let desiredRecordIDs = Set(generation.records.map(\.id))
        let existingRecordIDs = try Self.stringColumn(
            db,
            sql: "SELECT id FROM vault_records WHERE account_id = ? ORDER BY id",
            binds: [.text(generation.account.id)],
            operation: "connector_generation_existing_records"
        )

        do {
            var upserts: [VaultUpsertResult] = []
            var tombstonedCount = 0
            var committedResult: VaultConnectorGenerationCommitResult?
            try Self.withTransaction(
                db,
                operation: "connector_generation_replace"
            ) {
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_accounts(id, provider, provider_account_id, display_name, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        provider = excluded.provider,
                        provider_account_id = excluded.provider_account_id,
                        display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """,
                    binds: [
                        .text(generation.account.id),
                        .text(generation.account.provider),
                        .text(generation.account.providerAccountID),
                        .text(generation.account.displayName),
                        .integer(Self.milliseconds(generation.account.createdAt)),
                        .integer(Self.milliseconds(generation.account.updatedAt)),
                    ],
                    operation: "connector_generation_account_upsert"
                )
                for container in generation.containers.sorted(by: {
                    $0.id < $1.id
                }) {
                    try Self.execute(
                        db,
                        sql: """
                        INSERT INTO vault_containers(id, account_id, provider_container_id, kind, display_name, created_at, updated_at)
                        VALUES(?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            account_id = excluded.account_id,
                            provider_container_id = excluded.provider_container_id,
                            kind = excluded.kind,
                            display_name = excluded.display_name,
                            updated_at = excluded.updated_at
                        """,
                        binds: [
                            .text(container.id),
                            .text(container.accountID),
                            .text(container.providerContainerID),
                            .text(container.kind),
                            .text(container.displayName),
                            .integer(Self.milliseconds(container.createdAt)),
                            .integer(Self.milliseconds(container.updatedAt)),
                        ],
                        operation: "connector_generation_container_upsert"
                    )
                }
                for record in generation.records.sorted(by: { $0.id < $1.id }) {
                    upserts.append(try Self.upsertRecord(record, db: db))
                }
                for recordID in existingRecordIDs
                where !desiredRecordIDs.contains(recordID) {
                    if try Self.tombstoneRecord(
                        recordID: recordID,
                        reason: .sourceDeleted,
                        deletedAt: generation.account.updatedAt,
                        db: db
                    ) != nil {
                        tombstonedCount += 1
                    }
                }
                let dispositions = Dictionary(grouping: upserts, by: \.disposition)
                    .mapValues(\.count)
                let result = VaultConnectorGenerationCommitResult(
                    insertedCount: dispositions[.inserted, default: 0],
                    updatedCount: dispositions[.updated, default: 0],
                    unchangedCount: dispositions[.unchanged, default: 0],
                    resurrectedCount: dispositions[.resurrected, default: 0],
                    tombstonedCount: tombstonedCount,
                    generationReceiptHash: generation.generationReceiptHash
                )
                try Self.execute(
                    db,
                    sql: """
                    INSERT INTO vault_connector_generations(
                        account_id, generation_receipt_hash, container_count,
                        record_count, inserted_count, updated_count,
                        unchanged_count, resurrected_count, tombstoned_count,
                        attachment_blob_count, truncation_count,
                        materialized_byte_count, committed_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        generation_receipt_hash = excluded.generation_receipt_hash,
                        container_count = excluded.container_count,
                        record_count = excluded.record_count,
                        inserted_count = excluded.inserted_count,
                        updated_count = excluded.updated_count,
                        unchanged_count = excluded.unchanged_count,
                        resurrected_count = excluded.resurrected_count,
                        tombstoned_count = excluded.tombstoned_count,
                        attachment_blob_count = excluded.attachment_blob_count,
                        truncation_count = excluded.truncation_count,
                        materialized_byte_count = excluded.materialized_byte_count,
                        committed_at = excluded.committed_at
                    """,
                    binds: [
                        .text(generation.account.id),
                        .text(generation.generationReceiptHash),
                        .integer(Int64(generation.containers.count)),
                        .integer(Int64(generation.records.count)),
                        .integer(Int64(result.insertedCount)),
                        .integer(Int64(result.updatedCount)),
                        .integer(Int64(result.unchangedCount)),
                        .integer(Int64(result.resurrectedCount)),
                        .integer(Int64(result.tombstonedCount)),
                        .integer(Int64(generation.attachmentBlobCount)),
                        .integer(Int64(generation.truncationCount)),
                        .integer(generation.materializedByteCount),
                        .integer(Self.milliseconds(started)),
                    ],
                    operation: "connector_generation_marker_upsert"
                )
                committedResult = result
            }
            guard let result = committedResult else {
                throw Self.failure(
                    "vault_connector_generation_marker_missing",
                    operation: "connector_generation_replace",
                    recovery: .healthy
                )
            }
            emit(
                .recordUpsert,
                trace: trace,
                status: .success,
                reason: "vault_connector_generation_committed",
                started: started,
                metadata: [
                    (.accountHash, VaultPrivacy.hashIdentifier(generation.account.id)),
                    (.containerCount, String(generation.containers.count)),
                    (.recordCount, String(generation.records.count)),
                    (.tombstoneCount, String(tombstonedCount)),
                    (.checksumPrefix, VaultPrivacy.checksumPrefix(
                        generation.generationReceiptHash
                    )),
                ]
            )
            return result
        } catch {
            emitFailure(
                .recordUpsert,
                trace: trace,
                error: error,
                started: started,
                metadata: [
                    (.accountHash, VaultPrivacy.hashIdentifier(generation.account.id)),
                    (.recordCount, String(generation.records.count)),
                ]
            )
            throw error
        }
    }

    func connectorGenerationMarker(
        accountID: String
    ) throws -> VaultConnectorGenerationMarker? {
        try Self.validateIdentifier(accountID, field: "account_id")
        let db = try activeConnection(operation: "connector_generation_marker_read")
        var marker: VaultConnectorGenerationMarker?
        try Self.query(
            db,
            sql: """
            SELECT generation_receipt_hash, container_count, record_count,
                   inserted_count, updated_count, unchanged_count,
                   resurrected_count, tombstoned_count,
                   attachment_blob_count, truncation_count,
                   materialized_byte_count, committed_at
            FROM vault_connector_generations
            WHERE account_id = ?
            """,
            binds: [.text(accountID)],
            operation: "connector_generation_marker_read"
        ) { statement in
            marker = VaultConnectorGenerationMarker(
                accountID: accountID,
                generationReceiptHash: Self.text(statement, 0),
                containerCount: Int(sqlite3_column_int64(statement, 1)),
                recordCount: Int(sqlite3_column_int64(statement, 2)),
                insertedCount: Int(sqlite3_column_int64(statement, 3)),
                updatedCount: Int(sqlite3_column_int64(statement, 4)),
                unchangedCount: Int(sqlite3_column_int64(statement, 5)),
                resurrectedCount: Int(sqlite3_column_int64(statement, 6)),
                tombstonedCount: Int(sqlite3_column_int64(statement, 7)),
                attachmentBlobCount: Int(sqlite3_column_int64(statement, 8)),
                truncationCount: Int(sqlite3_column_int64(statement, 9)),
                materializedByteCount: sqlite3_column_int64(statement, 10),
                committedAt: Date(
                    timeIntervalSince1970:
                        Double(sqlite3_column_int64(statement, 11)) / 1_000
                )
            )
        }
        return marker
    }

    func accountExists(id: String) throws -> Bool {
        try Self.validateIdentifier(id, field: "account_id")
        let db = try activeConnection(operation: "account_exists")
        return try Self.scalarInt(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM vault_accounts WHERE id = ?)",
            binds: [.text(id)],
            operation: "account_exists"
        ) == 1
    }

    // MARK: - Records, revisions, and tombstones

    @discardableResult
    func upsert(record: VaultRecordInput, trace: VaultTraceContext = .init()) throws -> VaultUpsertResult {
        try upsert(records: [record], trace: trace)[0]
    }

    func preflightUpsertDisposition(for record: VaultRecordInput) throws -> VaultUpsertDisposition {
        try Self.validateRecord(record)
        let db = try activeConnection(operation: "record_upsert_preflight")
        let metadataJSON = try Self.canonicalMetadata(record.metadata)
        let checksum = Self.contentChecksum(record, metadataJSON: metadataJSON)
        if let existing = try Self.existingRecord(id: record.id, db: db) {
            return existing.checksum == checksum ? .unchanged : .updated
        }
        let wasTombstoned = try Self.scalarInt(
            db,
            sql: "SELECT count(*) FROM vault_tombstones WHERE record_id = ?",
            binds: [.text(record.id)],
            operation: "record_upsert_preflight_tombstone_check"
        ) > 0
        return wasTombstoned ? .resurrected : .inserted
    }

    @discardableResult
    func upsert(records: [VaultRecordInput], trace: VaultTraceContext = .init()) throws -> [VaultUpsertResult] {
        guard !records.isEmpty, records.count <= VaultLimits.maximumBatchSize else {
            throw Self.failure("vault_batch_size_invalid", operation: "record_upsert", recovery: .healthy)
        }
        try records.forEach(Self.validateRecord)
        guard Set(records.map(\.id)).count == records.count else {
            throw Self.failure("vault_batch_duplicate_record_id", operation: "record_upsert", recovery: .healthy)
        }
        let db = try activeConnection(operation: "record_upsert")
        let started = Date()
        do {
            var results: [VaultUpsertResult] = []
            try Self.withTransaction(db, operation: "record_upsert") {
                for record in records {
                    results.append(try Self.upsertRecord(record, db: db))
                }
            }
            let dispositions = Dictionary(grouping: results, by: \.disposition).mapValues(\.count)
            let reason = dispositions.keys.count == 1
                ? "vault_record_\(results[0].disposition.rawValue)"
                : "vault_record_batch_upserted"
            emit(.recordUpsert, trace: trace, status: .success, reason: reason, started: started,
                 metadata: [(.recordCount, String(results.count))])
            return results
        } catch {
            emitFailure(.recordUpsert, trace: trace, error: error, started: started,
                        metadata: [(.recordCount, String(records.count))])
            throw error
        }
    }

    func record(id: String) throws -> VaultRecord? {
        try Self.validateIdentifier(id, field: "record_id")
        let db = try activeConnection(operation: "record_read")
        var value: VaultRecord?
        try Self.query(db, sql: Self.recordSelect + " WHERE r.id = ?", binds: [.text(id)], operation: "record_read") {
            value = try Self.decodeRecord($0)
        }
        return value
    }

    func revisions(recordID: String) throws -> [VaultRecordRevision] {
        try Self.validateIdentifier(recordID, field: "record_id")
        let db = try activeConnection(operation: "revision_read")
        var values: [VaultRecordRevision] = []
        try Self.query(
            db,
            sql: """
            SELECT record_id, revision, title, body, author, source_url, occurred_at, captured_at,
                   modified_at, metadata_json, content_checksum, stored_at
            FROM vault_revisions WHERE record_id = ? ORDER BY revision ASC
            """,
            binds: [.text(recordID)],
            operation: "revision_read"
        ) { statement in
            values.append(try Self.decodeRevision(statement))
        }
        return values
    }

    @discardableResult
    func tombstone(
        recordID: String,
        reason: VaultTombstoneReason,
        deletedAt: Date,
        trace: VaultTraceContext = .init()
    ) throws -> VaultTombstone? {
        try Self.validateIdentifier(recordID, field: "record_id")
        let db = try activeConnection(operation: "record_tombstone")
        let started = Date()
        do {
            var result: VaultTombstone?
            try Self.withTransaction(db, operation: "record_tombstone") {
                result = try Self.tombstoneRecord(recordID: recordID, reason: reason, deletedAt: deletedAt, db: db)
            }
            emit(.tombstone, trace: trace, status: result == nil ? .skipped : .success,
                 reason: result == nil ? "vault_record_not_found" : "vault_record_tombstoned", started: started,
                 metadata: [(.recordHash, VaultPrivacy.hashIdentifier(recordID))])
            return result
        } catch {
            emitFailure(.tombstone, trace: trace, error: error, started: started,
                        metadata: [(.recordHash, VaultPrivacy.hashIdentifier(recordID))])
            throw error
        }
    }

    func tombstones(accountID: String? = nil) throws -> [VaultTombstone] {
        let db = try activeConnection(operation: "tombstone_read")
        if let accountID { try Self.validateIdentifier(accountID, field: "account_id") }
        var values: [VaultTombstone] = []
        let sql = """
            SELECT record_id, account_id, container_id, provider_record_id, reason, deleted_at, prior_content_purged
            FROM vault_tombstones
            \(accountID == nil ? "" : "WHERE account_id = ?")
            ORDER BY deleted_at ASC, record_id ASC
            """
        try Self.query(db, sql: sql, binds: accountID.map { [.text($0)] } ?? [], operation: "tombstone_read") { statement in
            guard let reason = VaultTombstoneReason(rawValue: Self.text(statement, 4)) else {
                throw Self.failure("vault_tombstone_reason_invalid", operation: "tombstone_read", recovery: .corruptionPreserveOriginal)
            }
            values.append(.init(
                recordID: Self.text(statement, 0), accountID: Self.text(statement, 1),
                containerID: Self.text(statement, 2), providerRecordID: Self.text(statement, 3),
                reason: reason, deletedAt: Self.date(statement, 5),
                priorContentPurged: sqlite3_column_int(statement, 6) == 1
            ))
        }
        return values
    }

    // MARK: - Search

    func search(_ request: VaultSearchRequest, trace: VaultTraceContext = .init()) throws -> VaultSearchResponse {
        let db = try activeConnection(operation: "search")
        let tokens = try Self.searchTokens(request.text)
        let limit = min(max(request.limit, 1), VaultLimits.maximumSearchResults)
        if let accountID = request.accountID { try Self.validateIdentifier(accountID, field: "account_id") }
        if let containerID = request.containerID { try Self.validateIdentifier(containerID, field: "container_id") }
        let started = Date()

        if request.preference == .automatic, ftsAvailable {
            do {
                let response = try Self.ftsSearch(db, tokens: tokens, request: request, limit: limit)
                emit(.search, trace: trace, status: .success, reason: "vault_search_fts_succeeded", started: started,
                     metadata: [
                        (.queryTokenCount, String(tokens.count)), (.resultCount, String(response.results.count)),
                        (.searchMode, response.mode.rawValue),
                     ])
                return response
            } catch {
                emit(.search, trace: trace, status: .degraded, reason: "vault_search_fts_fallback", started: started,
                     metadata: [(.queryTokenCount, String(tokens.count)), (.searchMode, VaultSearchMode.likeFallback.rawValue)])
            }
        }

        do {
            let response = try Self.likeSearch(db, tokens: tokens, request: request, limit: limit)
            emit(.search, trace: trace, status: request.preference == .automatic ? .degraded : .success,
                 reason: request.preference == .automatic ? "vault_search_like_fallback_succeeded" : "vault_search_like_selected",
                 started: started,
                 metadata: [
                    (.queryTokenCount, String(tokens.count)), (.resultCount, String(response.results.count)),
                    (.searchMode, response.mode.rawValue),
                 ])
            return response
        } catch {
            emitFailure(.search, trace: trace, error: error, started: started,
                        metadata: [(.queryTokenCount, String(tokens.count))])
            throw error
        }
    }

    // MARK: - Deletion and retention

    func deleteAccount(id: String, trace: VaultTraceContext = .init()) throws -> VaultDeletionSummary {
        try deleteScope(accountID: id, containerID: nil, trace: trace)
    }

    func deleteContainer(id: String, trace: VaultTraceContext = .init()) throws -> VaultDeletionSummary {
        try deleteScope(accountID: nil, containerID: id, trace: trace)
    }

    func applyRetention(
        _ policy: VaultRetentionPolicy,
        now: Date,
        trace: VaultTraceContext = .init()
    ) throws -> VaultRetentionResult {
        guard (1...VaultLimits.maximumRetentionDays).contains(policy.recordAgeDays),
              (1...VaultLimits.maximumRecordsPerContainer).contains(policy.maximumRecordsPerContainer),
              (1...VaultLimits.maximumRetentionDays).contains(policy.tombstoneAgeDays)
        else { throw Self.failure("vault_retention_policy_invalid", operation: "retention", recovery: .healthy) }
        if let accountID = policy.accountID { try Self.validateIdentifier(accountID, field: "account_id") }
        if let containerID = policy.containerID { try Self.validateIdentifier(containerID, field: "container_id") }

        let db = try activeConnection(operation: "retention")
        let started = Date()
        do {
            let ageCutoff = Self.milliseconds(now.addingTimeInterval(-Double(policy.recordAgeDays) * 86_400))
            let scope = Self.scopeClause(accountID: policy.accountID, containerID: policy.containerID, prefix: "")
            var ageIDs = try Self.stringColumn(
                db,
                sql: "SELECT id FROM vault_records WHERE occurred_at < ?\(scope.sql) ORDER BY occurred_at ASC, id ASC LIMIT ?",
                binds: [.integer(ageCutoff)] + scope.binds + [.integer(Int64(VaultLimits.maximumRetentionDeletesPerRun + 1))],
                operation: "retention_age_candidates"
            )
            let ageWasBounded = ageIDs.count > VaultLimits.maximumRetentionDeletesPerRun
            ageIDs = Array(ageIDs.prefix(VaultLimits.maximumRetentionDeletesPerRun))

            var limitIDs: [String] = []
            if !ageWasBounded {
                var containerClauses: [String] = []
                var containerBinds: [SQLValue] = []
                if let accountID = policy.accountID {
                    containerClauses.append("account_id = ?")
                    containerBinds.append(.text(accountID))
                }
                if let containerID = policy.containerID {
                    containerClauses.append("id = ?")
                    containerBinds.append(.text(containerID))
                }
                let containerWhere = containerClauses.isEmpty
                    ? ""
                    : " WHERE " + containerClauses.joined(separator: " AND ")
                let containers = try Self.stringColumn(
                    db,
                    sql: "SELECT id FROM vault_containers\(containerWhere) ORDER BY id",
                    binds: containerBinds,
                    operation: "retention_containers"
                )
                for container in containers where ageIDs.count + limitIDs.count < VaultLimits.maximumRetentionDeletesPerRun {
                    let remaining = VaultLimits.maximumRetentionDeletesPerRun - ageIDs.count - limitIDs.count
                    let candidates = try Self.stringColumn(
                        db,
                        sql: """
                        SELECT id FROM vault_records
                        WHERE container_id = ? AND occurred_at >= ?
                        ORDER BY occurred_at DESC, id ASC LIMIT ? OFFSET ?
                        """,
                        binds: [
                            .text(container), .integer(ageCutoff), .integer(Int64(remaining + 1)),
                            .integer(Int64(policy.maximumRecordsPerContainer)),
                        ],
                        operation: "retention_limit_candidates"
                    )
                    limitIDs.append(contentsOf: candidates.prefix(remaining))
                    if candidates.count > remaining { break }
                }
            }

            var ageRemoved = 0
            var limitRemoved = 0
            var tombstonesRemoved = 0
            let tombstoneCutoff = Self.milliseconds(now.addingTimeInterval(-Double(policy.tombstoneAgeDays) * 86_400))
            try Self.withTransaction(db, operation: "retention") {
                for id in ageIDs {
                    if try Self.tombstoneRecord(recordID: id, reason: .retentionExpired, deletedAt: now, db: db) != nil { ageRemoved += 1 }
                }
                for id in limitIDs where !ageIDs.contains(id) {
                    if try Self.tombstoneRecord(recordID: id, reason: .retentionExpired, deletedAt: now, db: db) != nil { limitRemoved += 1 }
                }
                let tombstoneScope = Self.scopeClause(accountID: policy.accountID, containerID: policy.containerID, prefix: "")
                try Self.execute(
                    db,
                    sql: "DELETE FROM vault_tombstones WHERE deleted_at < ?\(tombstoneScope.sql)",
                    binds: [.integer(tombstoneCutoff)] + tombstoneScope.binds,
                    operation: "retention_tombstones"
                )
                tombstonesRemoved = Int(sqlite3_changes(db))
            }
            let bounded = ageWasBounded || ageRemoved + limitRemoved >= VaultLimits.maximumRetentionDeletesPerRun
            let result = VaultRetentionResult(
                recordsRemovedByAge: ageRemoved, recordsRemovedByLimit: limitRemoved,
                tombstonesRemoved: tombstonesRemoved, wasBounded: bounded
            )
            emit(.retention, trace: trace, status: bounded ? .degraded : .success,
                 reason: bounded ? "vault_retention_batch_limit_reached" : "vault_retention_applied", started: started,
                 metadata: [
                    (.deletedCount, String(ageRemoved + limitRemoved)),
                    (.tombstoneCount, String(tombstonesRemoved)),
                 ])
            return result
        } catch {
            emitFailure(.retention, trace: trace, error: error, started: started)
            throw error
        }
    }

    // MARK: - Diagnostics and lifecycle

    func storageSummary(trace: VaultTraceContext = .init()) throws -> VaultStorageSummary {
        let db = try activeConnection(operation: "storage_summary")
        let started = Date()
        let pageSize = try Self.scalarInt(db, sql: "PRAGMA page_size", operation: "storage_page_size")
        let freePages = try Self.scalarInt(db, sql: "PRAGMA freelist_count", operation: "storage_free_pages")
        let databaseBytes = databaseURL.map(Self.fileSize) ?? 0
        let walBytes = databaseURL.map {
            Self.fileSize(URL(fileURLWithPath: $0.path + "-wal"))
        } ?? 0
        let sharedMemoryBytes = databaseURL.map {
            Self.fileSize(URL(fileURLWithPath: $0.path + "-shm"))
        } ?? 0
        let result = VaultStorageSummary(
            accountCount: try Self.count(db, table: "vault_accounts"),
            containerCount: try Self.count(db, table: "vault_containers"),
            recordCount: try Self.count(db, table: "vault_records"),
            revisionCount: try Self.count(db, table: "vault_revisions"),
            tombstoneCount: try Self.count(db, table: "vault_tombstones"),
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            sharedMemoryBytes: sharedMemoryBytes,
            totalArchiveBytes: databaseBytes + walBytes + sharedMemoryBytes,
            freeBytes: freePages * pageSize,
            oldestItemAt: try Self.optionalDate(db, sql: "SELECT MIN(occurred_at) FROM vault_records", operation: "storage_oldest"),
            newestItemAt: try Self.optionalDate(db, sql: "SELECT MAX(occurred_at) FROM vault_records", operation: "storage_newest"),
            accountContributions: try Self.storageContributions(db)
        )
        emit(.storageSummary, trace: trace, status: .success, reason: "vault_storage_summary_ready", started: started,
             metadata: [(.recordCount, String(result.recordCount)), (.byteCount, String(result.databaseBytes))])
        return result
    }

    func backfillRuns() throws -> [(job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint)] {
        let db = try activeConnection(operation: "backfill_job_list")
        var values: [(VaultBackfillJob, VaultBackfillCheckpoint)] = []
        try Self.query(
            db,
            sql: "SELECT job_json, checkpoint_json FROM vault_backfill_jobs ORDER BY updated_at DESC, job_id",
            operation: "backfill_job_list"
        ) { statement in
            values.append((
                try Self.makeBackfillDecoder().decode(VaultBackfillJob.self, from: Self.blob(statement, 0)),
                try Self.makeBackfillDecoder().decode(VaultBackfillCheckpoint.self, from: Self.blob(statement, 1))
            ))
        }
        return values
    }

    func diagnostics() throws -> VaultDatabaseDiagnostics {
        let db = try activeConnection(operation: "diagnostics")
        let tables = Set(try Self.stringColumn(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name",
            operation: "diagnostic_tables"
        ))
        return .init(
            schemaVersion: Int(try Self.scalarInt(db, sql: "PRAGMA user_version", operation: "diagnostic_schema")),
            journalMode: try Self.scalarText(db, sql: "PRAGMA journal_mode", operation: "diagnostic_journal"),
            foreignKeysEnabled: try Self.scalarInt(db, sql: "PRAGMA foreign_keys", operation: "diagnostic_foreign_keys") == 1,
            synchronousLevel: Int(try Self.scalarInt(db, sql: "PRAGMA synchronous", operation: "diagnostic_synchronous")),
            secureDeleteEnabled: try Self.scalarInt(db, sql: "PRAGMA secure_delete", operation: "diagnostic_secure_delete") == 1,
            busyTimeoutMilliseconds: Int(try Self.scalarInt(db, sql: "PRAGMA busy_timeout", operation: "diagnostic_busy_timeout")),
            ftsAvailable: ftsAvailable,
            requiredTables: tables.intersection(Self.requiredBaseTables.union(["vault_records_fts"]))
        )
    }

    func integrityCheck(trace: VaultTraceContext = .init()) throws -> VaultIntegrityReport {
        let db = try activeConnection(operation: "integrity_check")
        let started = Date()
        let sqliteOK = try Self.scalarText(db, sql: "PRAGMA integrity_check(1)", operation: "integrity_check") == "ok"
        let foreignKeyRows = try Self.rowCount(db, sql: "PRAGMA foreign_key_check", operation: "foreign_key_check")
        var ftsOK = !ftsAvailable
        if ftsAvailable {
            do {
                try Self.execute(db, sql: "INSERT INTO vault_records_fts(vault_records_fts) VALUES('integrity-check')", operation: "fts_integrity_check")
                ftsOK = true
            } catch {
                ftsOK = false
            }
        }
        let classification: VaultRecoveryClassification
        if !sqliteOK { classification = .corruptionPreserveOriginal }
        else if foreignKeyRows != 0 { classification = .foreignKeyRepairRequired }
        else if !ftsOK { classification = .ftsRebuildRequired }
        else { classification = .healthy }
        let report = VaultIntegrityReport(
            sqliteIntegrityOK: sqliteOK, foreignKeysOK: foreignKeyRows == 0,
            ftsAvailable: ftsAvailable, ftsIntegrityOK: ftsOK,
            recoveryClassification: classification
        )
        emit(.integrityCheck, trace: trace, status: classification == .healthy ? .success : .failed,
             reason: classification.rawValue, started: started,
             metadata: [(.ftsAvailable, String(ftsAvailable))])
        return report
    }

    func close(trace: VaultTraceContext = .init()) throws {
        guard let db = connection else {
            emit(.databaseClose, trace: trace, status: .skipped, reason: "vault_already_closed", started: Date())
            return
        }
        let started = Date()
        do {
            try Self.runToCompletion(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)", operation: "close_checkpoint")
            let result = sqlite3_close_v2(db)
            guard result == SQLITE_OK else {
                throw Self.sqliteFailure(db, code: result, operation: "database_close")
            }
            connection = nil
            emit(.databaseClose, trace: trace, status: .success, reason: "vault_database_closed", started: started)
        } catch {
            emitFailure(.databaseClose, trace: trace, error: error, started: started)
            throw error
        }
    }

    func reopen(trace: VaultTraceContext = .init()) throws {
        guard connection == nil else {
            emit(.databaseOpen, trace: trace, status: .skipped, reason: "vault_already_open", started: Date())
            return
        }
        let bootstrap = try Self.bootstrap(
            url: databaseURL,
            inMemory: isInMemory,
            trace: trace,
            traceSink: traceSink
        )
        connection = bootstrap.connection
        openDisposition = bootstrap.disposition
        ftsAvailable = bootstrap.ftsAvailable
    }

    func isOpen() -> Bool {
        connection != nil
    }

    func checkpoint(trace: VaultTraceContext = .init()) throws {
        let db = try activeConnection(operation: "checkpoint")
        try Self.runToCompletion(db, sql: "PRAGMA wal_checkpoint(PASSIVE)", operation: "checkpoint")
    }

    func compact(trace: VaultTraceContext = .init()) throws {
        let db = try activeConnection(operation: "compact")
        let started = Date()
        try Self.runToCompletion(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)", operation: "compact_checkpoint")
        try Self.runToCompletion(db, sql: "VACUUM", operation: "compact_vacuum")
        emit(.storageSummary, trace: trace, status: .success, reason: "vault_compaction_completed", started: started)
    }

    // MARK: - Export

    func export(
        to url: URL,
        scope: VaultExportScope = .all,
        exportedAt: Date = Date(),
        localCalendar: Calendar = .autoupdatingCurrent,
        localTimeZone: TimeZone = .autoupdatingCurrent,
        trace: VaultTraceContext = .init()
    ) throws -> VaultExportResult {
        let db = try activeConnection(operation: "export")
        guard url.isFileURL, url.pathExtension.lowercased() == "lokivault" else {
            throw Self.failure("vault_export_url_invalid", operation: "export", recovery: .healthy)
        }
        let started = Date()
        do {
            let rows = try Self.exportRows(db, scope: scope)
            var contentLines: [String] = []
            for (index, row) in rows.enumerated() {
                contentLines.append(try Self.exportEnvelope(sequence: index + 1, type: row.type, payload: row.payload))
            }
            let payloadData = Data((contentLines.joined(separator: "\n") + (contentLines.isEmpty ? "" : "\n")).utf8)
            let payloadChecksum = Self.sha256(payloadData)
            let counts = Dictionary(grouping: rows, by: \.type).mapValues(\.count)
            let localTimestamp = LocalCalendarTimestamp.resolve(
                exportedAt,
                calendar: localCalendar,
                timeZone: localTimeZone
            )
            let manifest: [String: Any] = [
                "format": "com.agentloki.lokivault.jsonl.v1",
                "schema_version": VaultLimits.schemaVersion,
                "exported_at": Self.iso8601(exportedAt),
                "exported_local_day": localTimestamp.day.storageValue,
                "export_calendar_identifier": String(describing: localCalendar.identifier),
                "export_time_zone_identifier": localTimestamp.timeZoneIdentifier,
                "account_scope": scope.accountID.map { $0 as Any } ?? NSNull(),
                "start_date": scope.startDate.map { Self.iso8601($0) as Any } ?? NSNull(),
                "end_date": scope.endDate.map { Self.iso8601($0) as Any } ?? NSNull(),
                "line_count": contentLines.count + 1,
                "account_count": counts["account", default: 0],
                "container_count": counts["container", default: 0],
                "record_count": counts["record", default: 0],
                "revision_count": counts["revision", default: 0],
                "tombstone_count": counts["tombstone", default: 0],
                "payload_checksum": payloadChecksum,
            ]
            let manifestLine = try Self.exportEnvelope(sequence: 0, type: "manifest", payload: manifest)
            let fileData = Data(([manifestLine] + contentLines).joined(separator: "\n").appending("\n").utf8)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let result = VaultExportResult(
                url: url, lineCount: contentLines.count + 1,
                accountCount: counts["account", default: 0], containerCount: counts["container", default: 0],
                recordCount: counts["record", default: 0], revisionCount: counts["revision", default: 0],
                tombstoneCount: counts["tombstone", default: 0], payloadChecksum: payloadChecksum,
                fileChecksum: Self.sha256(fileData), byteCount: fileData.count
            )
            emit(.export, trace: trace, status: .success, reason: "vault_export_completed", started: started,
                 metadata: [
                    (.recordCount, String(result.recordCount)), (.byteCount, String(result.byteCount)),
                    (.checksumPrefix, VaultPrivacy.checksumPrefix(result.fileChecksum)),
                 ])
            return result
        } catch {
            emitFailure(.export, trace: trace, error: error, started: started)
            throw error
        }
    }

    nonisolated static func verifyExport(at url: URL) throws -> VaultExportVerification {
        guard url.isFileURL, url.pathExtension.lowercased() == "lokivault" else {
            return .init(isValid: false, lineCount: 0, payloadChecksum: nil, fileChecksum: "", reasonCode: "vault_export_url_invalid")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fileChecksum = sha256(data)
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
            return .init(isValid: false, lineCount: 0, payloadChecksum: nil, fileChecksum: fileChecksum, reasonCode: "vault_export_not_jsonl")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else {
            return .init(isValid: false, lineCount: 0, payloadChecksum: nil, fileChecksum: fileChecksum, reasonCode: "vault_export_empty")
        }
        var envelopes: [[String: Any]] = []
        for (expectedSequence, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (envelope["sequence"] as? NSNumber)?.intValue == expectedSequence,
                  let payload = envelope["payload"] as? [String: Any],
                  let checksum = envelope["checksum"] as? String,
                  checksum == sha256(try canonicalJSON(payload))
            else {
                return .init(isValid: false, lineCount: lines.count, payloadChecksum: nil, fileChecksum: fileChecksum, reasonCode: "vault_export_line_checksum_invalid")
            }
            envelopes.append(envelope)
        }
        guard envelopes[0]["type"] as? String == "manifest",
              let manifest = envelopes[0]["payload"] as? [String: Any],
              (manifest["line_count"] as? NSNumber)?.intValue == lines.count,
              let expectedPayloadChecksum = manifest["payload_checksum"] as? String
        else {
            return .init(isValid: false, lineCount: lines.count, payloadChecksum: nil, fileChecksum: fileChecksum, reasonCode: "vault_export_manifest_invalid")
        }
        let payloadText = lines.dropFirst().joined(separator: "\n") + (lines.count > 1 ? "\n" : "")
        let actualPayloadChecksum = sha256(Data(payloadText.utf8))
        guard actualPayloadChecksum == expectedPayloadChecksum else {
            return .init(isValid: false, lineCount: lines.count, payloadChecksum: actualPayloadChecksum, fileChecksum: fileChecksum, reasonCode: "vault_export_payload_checksum_invalid")
        }
        return .init(isValid: true, lineCount: lines.count, payloadChecksum: actualPayloadChecksum, fileChecksum: fileChecksum, reasonCode: "vault_export_verified")
    }
}

private extension VaultDatabase {
    struct ExistingRecord {
        let id: String
        let accountID: String
        let containerID: String
        let providerRecordID: String
        let kind: String
        let title: String
        let body: String
        let author: String?
        let sourceURL: String?
        let occurredAt: Int64
        let capturedAt: Int64
        let modifiedAt: Int64
        let metadataJSON: String
        let revision: Int
        let checksum: String
        let insertedAt: Int64
        let directlyMentionsUser: Bool
        let isRead: Bool
        let contentOrigin: String
        let providerMetadataVersion: Int
        let threadRootID: String?
        let replyCount: Int
    }

    struct ExportRow {
        let type: String
        let payload: [String: Any]
    }

    struct ScopeClause {
        let sql: String
        let binds: [SQLValue]
    }

    static let recordSelect = """
        SELECT r.id, r.account_id, r.container_id, r.provider_record_id, r.kind,
               r.title, r.body, r.author, r.source_url, r.occurred_at, r.captured_at,
               r.modified_at, r.metadata_json, r.revision, r.content_checksum,
               a.provider, r.inserted_at, r.direct_mention, r.is_read, r.content_origin,
               r.provider_metadata_version, r.thread_root_id, r.reply_count
        FROM vault_records r JOIN vault_accounts a ON a.id = r.account_id
        """

    static func bootstrap(
        url: URL?,
        inMemory: Bool,
        trace: VaultTraceContext,
        traceSink: VaultTraceSink
    ) throws -> Bootstrap {
        guard inMemory || url?.isFileURL == true else {
            throw failure("vault_database_url_invalid", operation: "database_open", recovery: .inaccessiblePreserveOriginal)
        }
        let fileManager = FileManager.default
        if let url {
            let directory = url.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                throw failure("vault_directory_unavailable", operation: "database_open", recovery: .inaccessiblePreserveOriginal)
            }
        }

        let existed = url.map { fileManager.fileExists(atPath: $0.path) } ?? false
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(inMemory ? ":memory:" : url?.path, &opened, flags, nil)
        guard result == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw failure(
                result == SQLITE_BUSY || result == SQLITE_LOCKED ? "vault_database_busy" : "vault_database_open_failed",
                operation: "database_open",
                code: result,
                recovery: result == SQLITE_BUSY || result == SQLITE_LOCKED ? .lockedRetryable : .inaccessiblePreserveOriginal
            )
        }

        do {
            try runToCompletion(db, sql: "PRAGMA busy_timeout = \(VaultLimits.busyTimeoutMilliseconds)", operation: "configure_busy_timeout")
            try runToCompletion(db, sql: "PRAGMA foreign_keys = ON", operation: "configure_foreign_keys")
            try runToCompletion(db, sql: "PRAGMA secure_delete = ON", operation: "configure_secure_delete")
            try runToCompletion(db, sql: "PRAGMA synchronous = FULL", operation: "configure_synchronous")
            let journal = try scalarText(db, sql: "PRAGMA journal_mode = WAL", operation: "configure_journal")
            guard journal.lowercased() == (inMemory ? "memory" : "wal") else {
                throw failure("vault_wal_unavailable", operation: "database_open", recovery: .inaccessiblePreserveOriginal)
            }

            if existed {
                let quickCheck = try scalarText(db, sql: "PRAGMA quick_check(1)", operation: "database_quick_check")
                guard quickCheck == "ok" else {
                    throw failure("vault_database_corrupt", operation: "database_open", recovery: .corruptionPreserveOriginal)
                }
            }

            let previous = Int(try scalarInt(db, sql: "PRAGMA user_version", operation: "schema_version_read"))
            guard previous <= VaultLimits.schemaVersion else {
                throw failure(
                    "vault_schema_newer_than_application",
                    operation: "schema_migration",
                    recovery: .unsupportedNewerSchemaPreserveOriginal
                )
            }
            try migrate(db, from: previous)
            let fts = try configureFTS(db)
            try execute(
                db,
                sql: "INSERT INTO vault_features(name, value) VALUES('fts5', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                binds: [.text(fts ? "available" : "fallback")],
                operation: "feature_record"
            )
            if let url {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }

            let disposition: VaultOpenDisposition
            if !existed { disposition = .created(schemaVersion: VaultLimits.schemaVersion) }
            else if previous < VaultLimits.schemaVersion { disposition = .migrated(from: previous, to: VaultLimits.schemaVersion) }
            else { disposition = .opened(schemaVersion: VaultLimits.schemaVersion) }
            traceSink(traceEvent(
                name: .databaseOpen,
                trace: trace,
                status: .success,
                reason: !existed ? "vault_database_created" : (previous < VaultLimits.schemaVersion ? "vault_database_migrated" : "vault_database_opened"),
                metadata: .init([(.schemaVersion, String(VaultLimits.schemaVersion)), (.ftsAvailable, String(fts))])
            ))
            return .init(connection: db, disposition: disposition, ftsAvailable: fts)
        } catch {
            let sqliteCode = sqlite3_errcode(db)
            sqlite3_close_v2(db)
            if let failure = error as? VaultDatabaseFailure { throw failure }
            throw failure(
                sqliteCode == SQLITE_BUSY || sqliteCode == SQLITE_LOCKED ? "vault_database_busy" : "vault_database_open_failed",
                operation: "database_open",
                code: sqliteCode,
                recovery: sqliteCode == SQLITE_BUSY || sqliteCode == SQLITE_LOCKED ? .lockedRetryable : .inaccessiblePreserveOriginal
            )
        }
    }

    static func migrate(_ db: OpaquePointer, from previous: Int) throws {
        try withTransaction(db, operation: "schema_migration") {
            for sql in schemaStatements {
                try runToCompletion(db, sql: sql, operation: "schema_migration")
            }
            let appliedAt = milliseconds(Date())
            if previous < VaultLimits.schemaVersion {
                for version in max(previous + 1, 1)...VaultLimits.schemaVersion {
                    try execute(
                        db,
                        sql: "INSERT OR IGNORE INTO vault_schema_migrations(version, applied_at) VALUES(?, ?)",
                        binds: [.integer(Int64(version)), .integer(appliedAt)],
                        operation: "schema_migration_record"
                    )
                }
            }
            try runToCompletion(db, sql: "PRAGMA user_version = \(VaultLimits.schemaVersion)", operation: "schema_version_write")
        }
    }

    static var schemaStatements: [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS vault_schema_migrations(
                version INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_features(
                name TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_accounts(
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                provider_account_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(provider, provider_account_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_connector_generations(
                account_id TEXT PRIMARY KEY REFERENCES vault_accounts(id) ON DELETE CASCADE,
                generation_receipt_hash TEXT NOT NULL,
                container_count INTEGER NOT NULL CHECK(container_count >= 0),
                record_count INTEGER NOT NULL CHECK(record_count >= 0),
                inserted_count INTEGER NOT NULL CHECK(inserted_count >= 0),
                updated_count INTEGER NOT NULL CHECK(updated_count >= 0),
                unchanged_count INTEGER NOT NULL CHECK(unchanged_count >= 0),
                resurrected_count INTEGER NOT NULL CHECK(resurrected_count >= 0),
                tombstoned_count INTEGER NOT NULL CHECK(tombstoned_count >= 0),
                attachment_blob_count INTEGER NOT NULL CHECK(attachment_blob_count >= 0),
                truncation_count INTEGER NOT NULL CHECK(truncation_count >= 0),
                materialized_byte_count INTEGER NOT NULL CHECK(materialized_byte_count >= 0),
                committed_at INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_containers(
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                provider_container_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(account_id, provider_container_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_records(
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                container_id TEXT NOT NULL REFERENCES vault_containers(id) ON DELETE CASCADE,
                provider_record_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                author TEXT,
                source_url TEXT,
                occurred_at INTEGER NOT NULL,
                captured_at INTEGER NOT NULL,
                modified_at INTEGER NOT NULL,
                inserted_at INTEGER NOT NULL,
                metadata_json TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK(revision > 0),
                content_checksum TEXT NOT NULL,
                direct_mention INTEGER NOT NULL CHECK(direct_mention IN (0,1)),
                is_read INTEGER NOT NULL CHECK(is_read IN (0,1)),
                content_origin TEXT NOT NULL CHECK(content_origin IN ('source','generated')),
                provider_metadata_version INTEGER NOT NULL CHECK(provider_metadata_version > 0),
                thread_root_id TEXT,
                reply_count INTEGER NOT NULL CHECK(reply_count >= 0),
                UNIQUE(account_id, container_id, provider_record_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_revisions(
                record_id TEXT NOT NULL REFERENCES vault_records(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                author TEXT,
                source_url TEXT,
                occurred_at INTEGER NOT NULL,
                captured_at INTEGER NOT NULL,
                modified_at INTEGER NOT NULL,
                metadata_json TEXT NOT NULL,
                content_checksum TEXT NOT NULL,
                stored_at INTEGER NOT NULL,
                PRIMARY KEY(record_id, revision)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_tombstones(
                record_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                container_id TEXT NOT NULL REFERENCES vault_containers(id) ON DELETE CASCADE,
                provider_record_id TEXT NOT NULL,
                reason TEXT NOT NULL,
                deleted_at INTEGER NOT NULL,
                prior_content_purged INTEGER NOT NULL CHECK(prior_content_purged IN (0,1))
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_participants(
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                provider_participant_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                kind TEXT NOT NULL,
                UNIQUE(account_id, provider_participant_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_item_participants(
                record_id TEXT NOT NULL REFERENCES vault_records(id) ON DELETE CASCADE,
                participant_id TEXT NOT NULL REFERENCES vault_participants(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                PRIMARY KEY(record_id, participant_id, role)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_provenance(
                record_id TEXT PRIMARY KEY REFERENCES vault_records(id) ON DELETE CASCADE,
                provider TEXT NOT NULL,
                provider_account_id TEXT NOT NULL,
                provider_container_id TEXT NOT NULL,
                provider_item_id TEXT NOT NULL,
                retrieved_at INTEGER NOT NULL,
                source_url TEXT,
                content_origin TEXT NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_sync_cursors(
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                container_id TEXT NOT NULL REFERENCES vault_containers(id) ON DELETE CASCADE,
                direction TEXT NOT NULL CHECK(direction IN ('forward','historical')),
                provider_cursor TEXT,
                boundary_at INTEGER,
                last_success_at INTEGER,
                last_rate_limit_at INTEGER,
                last_failure_code TEXT,
                exhausted INTEGER NOT NULL DEFAULT 0 CHECK(exhausted IN (0,1)),
                PRIMARY KEY(account_id, container_id, direction)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_sync_runs(
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES vault_accounts(id) ON DELETE CASCADE,
                container_id TEXT REFERENCES vault_containers(id) ON DELETE CASCADE,
                direction TEXT NOT NULL,
                state TEXT NOT NULL,
                reason_code TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                completed_at INTEGER,
                request_count INTEGER NOT NULL,
                item_count INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_backfill_jobs(
                job_id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                state TEXT NOT NULL,
                job_json BLOB NOT NULL,
                checkpoint_json BLOB NOT NULL,
                updated_at INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS vault_storage_statistics(
                id TEXT PRIMARY KEY,
                account_id TEXT REFERENCES vault_accounts(id) ON DELETE CASCADE,
                measured_at INTEGER NOT NULL,
                item_count INTEGER NOT NULL,
                revision_count INTEGER NOT NULL,
                estimated_bytes INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_containers_account_immutable
            BEFORE UPDATE OF account_id ON vault_containers
            FOR EACH ROW WHEN NEW.account_id <> OLD.account_id
            BEGIN
                SELECT RAISE(ABORT, 'vault_container_account_immutable');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_records_scope_insert
            BEFORE INSERT ON vault_records
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_records_scope_update
            BEFORE UPDATE OF account_id, container_id ON vault_records
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_tombstones_scope_insert
            BEFORE INSERT ON vault_tombstones
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_tombstones_scope_update
            BEFORE UPDATE OF account_id, container_id ON vault_tombstones
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_sync_cursors_scope_insert
            BEFORE INSERT ON vault_sync_cursors
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_sync_cursors_scope_update
            BEFORE UPDATE OF account_id, container_id ON vault_sync_cursors
            FOR EACH ROW WHEN NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_sync_runs_scope_insert
            BEFORE INSERT ON vault_sync_runs
            FOR EACH ROW WHEN NEW.container_id IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS vault_sync_runs_scope_update
            BEFORE UPDATE OF account_id, container_id ON vault_sync_runs
            FOR EACH ROW WHEN NEW.container_id IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM vault_containers
                WHERE id = NEW.container_id AND account_id = NEW.account_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'vault_scope_mismatch');
            END
            """,
            "CREATE INDEX IF NOT EXISTS vault_records_account_date_idx ON vault_records(account_id, occurred_at DESC, id)",
            "CREATE INDEX IF NOT EXISTS vault_records_container_date_idx ON vault_records(container_id, occurred_at DESC, id)",
            "CREATE INDEX IF NOT EXISTS vault_records_author_idx ON vault_records(author)",
            "CREATE INDEX IF NOT EXISTS vault_tombstones_scope_idx ON vault_tombstones(account_id, container_id, deleted_at)",
        ]
    }

    static func configureFTS(_ db: OpaquePointer) throws -> Bool {
        do {
            try runToCompletion(
                db,
                sql: "CREATE VIRTUAL TABLE IF NOT EXISTS vault_records_fts USING fts5(title, body, author, content='vault_records', content_rowid='rowid')",
                operation: "fts_create"
            )
            try runToCompletion(db, sql: """
                CREATE TRIGGER IF NOT EXISTS vault_records_fts_ai AFTER INSERT ON vault_records BEGIN
                    INSERT INTO vault_records_fts(rowid, title, body, author) VALUES(new.rowid, new.title, new.body, coalesce(new.author, ''));
                END
                """, operation: "fts_insert_trigger")
            try runToCompletion(db, sql: """
                CREATE TRIGGER IF NOT EXISTS vault_records_fts_ad BEFORE DELETE ON vault_records BEGIN
                    INSERT INTO vault_records_fts(vault_records_fts, rowid, title, body, author)
                    VALUES('delete', old.rowid, old.title, old.body, coalesce(old.author, ''));
                END
                """, operation: "fts_delete_trigger")
            try runToCompletion(db, sql: """
                CREATE TRIGGER IF NOT EXISTS vault_records_fts_au BEFORE UPDATE ON vault_records BEGIN
                    INSERT INTO vault_records_fts(vault_records_fts, rowid, title, body, author)
                    VALUES('delete', old.rowid, old.title, old.body, coalesce(old.author, ''));
                    INSERT INTO vault_records_fts(rowid, title, body, author)
                    VALUES(new.rowid, new.title, new.body, coalesce(new.author, ''));
                END
                """, operation: "fts_update_trigger")
            let recordCount = try scalarInt(db, sql: "SELECT count(*) FROM vault_records", operation: "fts_record_count")
            let ftsCount = try scalarInt(db, sql: "SELECT count(*) FROM vault_records_fts", operation: "fts_index_count")
            if recordCount != ftsCount {
                try runToCompletion(db, sql: "INSERT INTO vault_records_fts(vault_records_fts) VALUES('rebuild')", operation: "fts_rebuild")
            }
            return true
        } catch let error as VaultDatabaseFailure where error.sqliteCode == SQLITE_ERROR {
            return false
        }
    }

    func activeConnection(operation: String) throws -> OpaquePointer {
        guard let connection else {
            throw Self.failure("vault_database_closed", operation: operation, recovery: .closed)
        }
        return connection
    }

    static func withTransaction(_ db: OpaquePointer, operation: String, body: () throws -> Void) throws {
        try runToCompletion(db, sql: "BEGIN IMMEDIATE", operation: operation)
        do {
            try body()
            try runToCompletion(db, sql: "COMMIT", operation: operation)
        } catch {
            try? runToCompletion(db, sql: "ROLLBACK", operation: operation)
            throw error
        }
    }

    static func execute(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = [],
        operation: String
    ) throws {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw sqliteFailure(db, code: prepare, operation: operation) }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, db: db, operation: operation)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw sqliteFailure(db, code: step, operation: operation) }
    }

    static func query(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = [],
        operation: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw sqliteFailure(db, code: prepare, operation: operation) }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, db: db, operation: operation)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { try row(statement) }
            else if step == SQLITE_DONE { return }
            else { throw sqliteFailure(db, code: step, operation: operation) }
        }
    }

    static func bind(_ values: [SQLValue], to statement: OpaquePointer, db: OpaquePointer, operation: String) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
            case let .blob(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteFailure(db, code: result, operation: operation) }
        }
    }

    static func runToCompletion(_ db: OpaquePointer, sql: String, operation: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteFailure(db, code: result, operation: operation) }
    }

    static func scalarInt(_ db: OpaquePointer, sql: String, binds: [SQLValue] = [], operation: String) throws -> Int64 {
        var value: Int64?
        try query(db, sql: sql, binds: binds, operation: operation) { value = sqlite3_column_int64($0, 0) }
        guard let value else { throw failure("vault_scalar_missing", operation: operation, recovery: .corruptionPreserveOriginal) }
        return value
    }

    static func scalarText(_ db: OpaquePointer, sql: String, binds: [SQLValue] = [], operation: String) throws -> String {
        var value: String?
        try query(db, sql: sql, binds: binds, operation: operation) { value = text($0, 0) }
        guard let value else { throw failure("vault_scalar_missing", operation: operation, recovery: .corruptionPreserveOriginal) }
        return value
    }

    static func optionalDate(_ db: OpaquePointer, sql: String, binds: [SQLValue] = [], operation: String) throws -> Date? {
        var value: Date?
        try query(db, sql: sql, binds: binds, operation: operation) { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL { value = date(statement, 0) }
        }
        return value
    }

    static func stringColumn(_ db: OpaquePointer, sql: String, binds: [SQLValue] = [], operation: String) throws -> [String] {
        var values: [String] = []
        try query(db, sql: sql, binds: binds, operation: operation) { values.append(text($0, 0)) }
        return values
    }

    static func rowCount(_ db: OpaquePointer, sql: String, binds: [SQLValue] = [], operation: String) throws -> Int {
        var count = 0
        try query(db, sql: sql, binds: binds, operation: operation) { _ in count += 1 }
        return count
    }

    static func count(_ db: OpaquePointer, table: String) throws -> Int {
        guard requiredBaseTables.contains(table) else {
            throw failure("vault_table_not_allowlisted", operation: "count", recovery: .healthy)
        }
        return Int(try scalarInt(db, sql: "SELECT count(*) FROM \(table)", operation: "count_\(table)"))
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    static func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, column)) / 1_000)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.count <= VaultLimits.maximumIdentifierCharacters,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw failure("vault_\(field)_invalid", operation: "validation", recovery: .healthy) }
    }

    static func validateAccount(_ account: VaultAccountInput) throws {
        try validateIdentifier(account.id, field: "account_id")
        try validateIdentifier(account.providerAccountID, field: "provider_account_id")
        guard !account.provider.isEmpty,
              account.provider.count <= VaultLimits.maximumProviderCharacters,
              !account.displayName.isEmpty,
              account.displayName.count <= VaultLimits.maximumDisplayNameCharacters
        else { throw failure("vault_account_invalid", operation: "account_validation", recovery: .healthy) }
    }

    static func validateContainer(_ container: VaultContainerInput) throws {
        try validateIdentifier(container.id, field: "container_id")
        try validateIdentifier(container.accountID, field: "account_id")
        try validateIdentifier(container.providerContainerID, field: "provider_container_id")
        guard !container.kind.isEmpty,
              container.kind.count <= VaultLimits.maximumKindCharacters,
              !container.displayName.isEmpty,
              container.displayName.count <= VaultLimits.maximumDisplayNameCharacters
        else { throw failure("vault_container_invalid", operation: "container_validation", recovery: .healthy) }
    }

    static func validateRecord(_ record: VaultRecordInput) throws {
        try validateIdentifier(record.id, field: "record_id")
        try validateIdentifier(record.accountID, field: "account_id")
        try validateIdentifier(record.containerID, field: "container_id")
        try validateIdentifier(record.providerRecordID, field: "provider_record_id")
        if let threadRootID = record.threadRootID { try validateIdentifier(threadRootID, field: "thread_root_id") }
        let metadata = try canonicalMetadata(record.metadata)
        guard !record.kind.isEmpty,
              record.kind.count <= VaultLimits.maximumKindCharacters,
              record.title.count <= VaultLimits.maximumTitleCharacters,
              record.body.lengthOfBytes(using: .utf8) <= VaultLimits.maximumBodyBytes,
              (record.author?.count ?? 0) <= VaultLimits.maximumAuthorCharacters,
              (record.sourceURL?.absoluteString.count ?? 0) <= VaultLimits.maximumURLCharacters,
              record.metadata.count <= VaultLimits.maximumMetadataEntries,
              metadata.utf8.count <= VaultLimits.maximumMetadataBytes,
              record.providerMetadataVersion > 0,
              record.replyCount >= 0
        else { throw failure("vault_record_invalid", operation: "record_validation", recovery: .healthy) }
    }

    static func canonicalMetadata(_ metadata: [String: String]) throws -> String {
        guard JSONSerialization.isValidJSONObject(metadata) else {
            throw failure("vault_metadata_invalid", operation: "metadata_encode", recovery: .healthy)
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw failure("vault_metadata_invalid", operation: "metadata_encode", recovery: .healthy)
        }
        return text
    }

    static func contentChecksum(_ record: VaultRecordInput, metadataJSON: String) -> String {
        let checksumMetadataJSON: String
        let isAttachedConnectorRecord =
            record.metadata["connector_schema_version"] != nil
                && record.metadata["attached_source_id"] != nil
        if record.metadata["connector_schema_version"] != nil {
            var stableConnectorMetadata = record.metadata
            // Retrieval time and page receipts belong to sync audit state, not
            // provider-content identity. Excluding the reconstructable sidecar
            // and its volatile hashes prevents an unchanged replay from
            // manufacturing a Vault revision while the first admitted
            // provenance remains available locally.
            stableConnectorMetadata.removeValue(
                forKey: ConnectorVaultStoredEnvelope.metadataKey
            )
            stableConnectorMetadata.removeValue(
                forKey: "connector_envelope_sha256"
            )
            stableConnectorMetadata.removeValue(
                forKey: "connector_page_receipt_sha256"
            )
            if isAttachedConnectorRecord {
                // These fields identify the atomic attached-data generation,
                // not the selected record's content. Refreshing an unchanged
                // row must advance its provenance without manufacturing a
                // content revision.
                stableConnectorMetadata.removeValue(
                    forKey: "attached_source_epoch"
                )
                stableConnectorMetadata.removeValue(
                    forKey: "attached_source_sha256"
                )
                stableConnectorMetadata.removeValue(
                    forKey: "attached_generation_id"
                )
                stableConnectorMetadata.removeValue(
                    forKey: "attached_generation_receipt_sha256"
                )
                stableConnectorMetadata.removeValue(
                    forKey: "connector_policy"
                )
            }
            checksumMetadataJSON = (try? canonicalMetadata(
                stableConnectorMetadata
            )) ?? metadataJSON
        } else {
            checksumMetadataJSON = metadataJSON
        }
        let values = [
            record.kind, record.title, record.body, record.author ?? "", record.sourceURL?.absoluteString ?? "",
            isAttachedConnectorRecord
                ? "" : String(milliseconds(record.occurredAt)),
            checksumMetadataJSON, String(record.directlyMentionsUser),
            String(record.isRead), record.contentOrigin.rawValue, String(record.providerMetadataVersion),
            record.threadRootID ?? "", String(record.replyCount),
        ]
        return sha256(Data(values.joined(separator: "\u{0}").utf8))
    }

    static func upsertRecord(_ record: VaultRecordInput, db: OpaquePointer) throws -> VaultUpsertResult {
        guard try scalarInt(db, sql: "SELECT count(*) FROM vault_accounts WHERE id = ?", binds: [.text(record.accountID)], operation: "record_account_check") == 1,
              try scalarInt(db, sql: "SELECT count(*) FROM vault_containers WHERE id = ? AND account_id = ?", binds: [.text(record.containerID), .text(record.accountID)], operation: "record_container_check") == 1
        else { throw failure("vault_record_scope_not_found", operation: "record_upsert", recovery: .healthy) }

        let metadataJSON = try canonicalMetadata(record.metadata)
        let checksum = contentChecksum(record, metadataJSON: metadataJSON)
        let existing = try existingRecord(id: record.id, db: db)
        let wasTombstoned = try scalarInt(db, sql: "SELECT count(*) FROM vault_tombstones WHERE record_id = ?", binds: [.text(record.id)], operation: "record_tombstone_check") > 0
        if let existing, existing.checksum == checksum {
            if record.metadata["connector_schema_version"] != nil,
               record.metadata["attached_source_id"] != nil {
                // Attached-data provenance is generation-scoped. Replace the
                // current sidecar and allowlisted metadata in place so reads
                // cannot observe a prior generation, while retaining the
                // record revision because its selected content is unchanged.
                try execute(
                    db,
                    sql: """
                    UPDATE vault_records
                    SET occurred_at = ?, captured_at = ?, modified_at = ?,
                        metadata_json = ?
                    WHERE id = ?
                    """,
                    binds: [
                        .integer(milliseconds(record.occurredAt)),
                        .integer(milliseconds(record.capturedAt)),
                        .integer(milliseconds(record.modifiedAt)),
                        .text(metadataJSON),
                        .text(record.id),
                    ],
                    operation: "attached_record_unchanged_provenance_refresh"
                )
                try execute(
                    db,
                    sql: "UPDATE vault_provenance SET retrieved_at = ? WHERE record_id = ?",
                    binds: [
                        .integer(milliseconds(record.capturedAt)),
                        .text(record.id),
                    ],
                    operation: "attached_record_unchanged_provenance_touch"
                )
            } else if record.metadata["connector_schema_version"] == nil {
                try execute(
                    db,
                    sql: "UPDATE vault_records SET captured_at = ?, modified_at = ? WHERE id = ?",
                    binds: [.integer(milliseconds(record.capturedAt)), .integer(milliseconds(record.modifiedAt)), .text(record.id)],
                    operation: "record_unchanged_touch"
                )
            }
            return .init(recordID: record.id, disposition: .unchanged, revision: existing.revision, contentChecksum: checksum)
        }

        let revision: Int
        let disposition: VaultUpsertDisposition
        if let existing {
            try execute(
                db,
                sql: """
                    INSERT OR IGNORE INTO vault_revisions(
                        record_id, revision, title, body, author, source_url, occurred_at,
                        captured_at, modified_at, metadata_json, content_checksum, stored_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                binds: [
                    .text(existing.id), .integer(Int64(existing.revision)), .text(existing.title), .text(existing.body),
                    existing.author.map(SQLValue.text) ?? .null, existing.sourceURL.map(SQLValue.text) ?? .null,
                    .integer(existing.occurredAt), .integer(existing.capturedAt), .integer(existing.modifiedAt),
                    .text(existing.metadataJSON), .text(existing.checksum), .integer(milliseconds(Date())),
                ],
                operation: "revision_insert"
            )
            revision = existing.revision + 1
            disposition = .updated
        } else {
            revision = 1
            disposition = wasTombstoned ? .resurrected : .inserted
        }

        let insertedAt = existing?.insertedAt ?? milliseconds(record.capturedAt)
        try execute(
            db,
            sql: """
                INSERT INTO vault_records(
                    id, account_id, container_id, provider_record_id, kind, title, body, author,
                    source_url, occurred_at, captured_at, modified_at, inserted_at, metadata_json,
                    revision, content_checksum, direct_mention, is_read, content_origin,
                    provider_metadata_version, thread_root_id, reply_count
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    account_id = excluded.account_id,
                    container_id = excluded.container_id,
                    provider_record_id = excluded.provider_record_id,
                    kind = excluded.kind,
                    title = excluded.title,
                    body = excluded.body,
                    author = excluded.author,
                    source_url = excluded.source_url,
                    occurred_at = excluded.occurred_at,
                    captured_at = excluded.captured_at,
                    modified_at = excluded.modified_at,
                    metadata_json = excluded.metadata_json,
                    revision = excluded.revision,
                    content_checksum = excluded.content_checksum,
                    direct_mention = excluded.direct_mention,
                    is_read = excluded.is_read,
                    content_origin = excluded.content_origin,
                    provider_metadata_version = excluded.provider_metadata_version,
                    thread_root_id = excluded.thread_root_id,
                    reply_count = excluded.reply_count
                """,
            binds: [
                .text(record.id), .text(record.accountID), .text(record.containerID), .text(record.providerRecordID),
                .text(record.kind), .text(record.title), .text(record.body), record.author.map(SQLValue.text) ?? .null,
                record.sourceURL.map { .text($0.absoluteString) } ?? .null, .integer(milliseconds(record.occurredAt)),
                .integer(milliseconds(record.capturedAt)), .integer(milliseconds(record.modifiedAt)), .integer(insertedAt),
                .text(metadataJSON), .integer(Int64(revision)), .text(checksum), .integer(record.directlyMentionsUser ? 1 : 0),
                .integer(record.isRead ? 1 : 0), .text(record.contentOrigin.rawValue),
                .integer(Int64(record.providerMetadataVersion)), record.threadRootID.map(SQLValue.text) ?? .null,
                .integer(Int64(record.replyCount)),
            ],
            operation: "record_upsert"
        )
        try execute(db, sql: "DELETE FROM vault_tombstones WHERE record_id = ?", binds: [.text(record.id)], operation: "record_tombstone_clear")
        try execute(
            db,
            sql: """
                INSERT INTO vault_provenance(
                    record_id, provider, provider_account_id, provider_container_id,
                    provider_item_id, retrieved_at, source_url, content_origin
                )
                SELECT ?, a.provider, a.provider_account_id, c.provider_container_id, ?, ?, ?, ?
                FROM vault_accounts a JOIN vault_containers c ON c.account_id = a.id
                WHERE a.id = ? AND c.id = ?
                ON CONFLICT(record_id) DO UPDATE SET
                    provider = excluded.provider,
                    provider_account_id = excluded.provider_account_id,
                    provider_container_id = excluded.provider_container_id,
                    provider_item_id = excluded.provider_item_id,
                    retrieved_at = excluded.retrieved_at,
                    source_url = excluded.source_url,
                    content_origin = excluded.content_origin
                """,
            binds: [
                .text(record.id), .text(record.providerRecordID), .integer(milliseconds(record.capturedAt)),
                record.sourceURL.map { .text($0.absoluteString) } ?? .null, .text(record.contentOrigin.rawValue),
                .text(record.accountID), .text(record.containerID),
            ],
            operation: "provenance_upsert"
        )
        try execute(
            db,
            sql: """
                DELETE FROM vault_revisions
                WHERE record_id = ? AND revision NOT IN (
                    SELECT revision FROM vault_revisions WHERE record_id = ?
                    ORDER BY revision DESC LIMIT ?
                )
                """,
            binds: [.text(record.id), .text(record.id), .integer(Int64(VaultLimits.maximumRevisionsPerItem))],
            operation: "revision_bound"
        )
        return .init(recordID: record.id, disposition: disposition, revision: revision, contentChecksum: checksum)
    }

    static func existingRecord(id: String, db: OpaquePointer) throws -> ExistingRecord? {
        var value: ExistingRecord?
        try query(
            db,
            sql: """
                SELECT id, account_id, container_id, provider_record_id, kind, title, body, author,
                       source_url, occurred_at, captured_at, modified_at, metadata_json, revision,
                       content_checksum, inserted_at, direct_mention, is_read, content_origin,
                       provider_metadata_version, thread_root_id, reply_count
                FROM vault_records WHERE id = ?
                """,
            binds: [.text(id)],
            operation: "record_existing"
        ) { statement in
            value = .init(
                id: text(statement, 0), accountID: text(statement, 1), containerID: text(statement, 2),
                providerRecordID: text(statement, 3), kind: text(statement, 4), title: text(statement, 5),
                body: text(statement, 6), author: optionalText(statement, 7), sourceURL: optionalText(statement, 8),
                occurredAt: sqlite3_column_int64(statement, 9), capturedAt: sqlite3_column_int64(statement, 10),
                modifiedAt: sqlite3_column_int64(statement, 11), metadataJSON: text(statement, 12),
                revision: Int(sqlite3_column_int64(statement, 13)), checksum: text(statement, 14),
                insertedAt: sqlite3_column_int64(statement, 15), directlyMentionsUser: sqlite3_column_int(statement, 16) == 1,
                isRead: sqlite3_column_int(statement, 17) == 1, contentOrigin: text(statement, 18),
                providerMetadataVersion: Int(sqlite3_column_int64(statement, 19)), threadRootID: optionalText(statement, 20),
                replyCount: Int(sqlite3_column_int64(statement, 21))
            )
        }
        return value
    }

    static func decodeRecord(_ statement: OpaquePointer) throws -> VaultRecord {
        let metadataText = text(statement, 12)
        guard let metadataData = metadataText.data(using: .utf8),
              let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: String],
              let origin = VaultContentOrigin(rawValue: text(statement, 19))
        else { throw failure("vault_record_decode_failed", operation: "record_decode", recovery: .corruptionPreserveOriginal) }
        return .init(
            id: text(statement, 0), accountID: text(statement, 1), containerID: text(statement, 2),
            providerRecordID: text(statement, 3), kind: text(statement, 4), title: text(statement, 5),
            body: text(statement, 6), author: optionalText(statement, 7),
            sourceURL: optionalText(statement, 8).flatMap(URL.init(string:)), occurredAt: date(statement, 9),
            capturedAt: date(statement, 10), modifiedAt: date(statement, 11), metadata: metadata,
            revision: Int(sqlite3_column_int64(statement, 13)), contentChecksum: text(statement, 14),
            provider: text(statement, 15), insertedAt: date(statement, 16),
            directlyMentionsUser: sqlite3_column_int(statement, 17) == 1,
            isRead: sqlite3_column_int(statement, 18) == 1, contentOrigin: origin,
            providerMetadataVersion: Int(sqlite3_column_int64(statement, 20)),
            threadRootID: optionalText(statement, 21), replyCount: Int(sqlite3_column_int64(statement, 22))
        )
    }

    static func decodeRevision(_ statement: OpaquePointer) throws -> VaultRecordRevision {
        let metadataText = text(statement, 9)
        guard let data = metadataText.data(using: .utf8),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw failure("vault_revision_decode_failed", operation: "revision_decode", recovery: .corruptionPreserveOriginal) }
        return .init(
            recordID: text(statement, 0), revision: Int(sqlite3_column_int64(statement, 1)),
            title: text(statement, 2), body: text(statement, 3), author: optionalText(statement, 4),
            sourceURL: optionalText(statement, 5).flatMap(URL.init(string:)), occurredAt: date(statement, 6),
            capturedAt: date(statement, 7), modifiedAt: date(statement, 8), metadata: metadata,
            contentChecksum: text(statement, 10), storedAt: date(statement, 11)
        )
    }

    static func tombstoneRecord(
        recordID: String,
        reason: VaultTombstoneReason,
        deletedAt: Date,
        db: OpaquePointer
    ) throws -> VaultTombstone? {
        guard let existing = try existingRecord(id: recordID, db: db) else { return nil }
        try execute(
            db,
            sql: """
                INSERT INTO vault_tombstones(
                    record_id, account_id, container_id, provider_record_id, reason, deleted_at, prior_content_purged
                ) VALUES(?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(record_id) DO UPDATE SET
                    reason = excluded.reason, deleted_at = excluded.deleted_at, prior_content_purged = 1
                """,
            binds: [
                .text(existing.id), .text(existing.accountID), .text(existing.containerID),
                .text(existing.providerRecordID), .text(reason.rawValue), .integer(milliseconds(deletedAt)),
            ],
            operation: "record_tombstone_insert"
        )
        try execute(db, sql: "DELETE FROM vault_records WHERE id = ?", binds: [.text(recordID)], operation: "record_tombstone_purge")
        return .init(
            recordID: existing.id, accountID: existing.accountID, containerID: existing.containerID,
            providerRecordID: existing.providerRecordID, reason: reason, deletedAt: deletedAt,
            priorContentPurged: true
        )
    }

    func deleteScope(accountID: String?, containerID: String?, trace: VaultTraceContext) throws -> VaultDeletionSummary {
        if let accountID { try Self.validateIdentifier(accountID, field: "account_id") }
        if let containerID { try Self.validateIdentifier(containerID, field: "container_id") }
        guard (accountID == nil) != (containerID == nil) else {
            throw Self.failure("vault_delete_scope_invalid", operation: "deletion", recovery: .healthy)
        }
        let db = try activeConnection(operation: "deletion")
        let started = Date()
        let scope = Self.scopeClause(accountID: accountID, containerID: containerID, prefix: "")
        let records = Int(try Self.scalarInt(db, sql: "SELECT count(*) FROM vault_records WHERE 1 = 1\(scope.sql)", binds: scope.binds, operation: "deletion_record_count"))
        let revisions = Int(try Self.scalarInt(
            db,
            sql: "SELECT count(*) FROM vault_revisions WHERE record_id IN (SELECT id FROM vault_records WHERE 1 = 1\(scope.sql))",
            binds: scope.binds,
            operation: "deletion_revision_count"
        ))
        let tombstones = Int(try Self.scalarInt(db, sql: "SELECT count(*) FROM vault_tombstones WHERE 1 = 1\(scope.sql)", binds: scope.binds, operation: "deletion_tombstone_count"))
        var backfillJobIDs: [String] = []
        if let accountID {
            backfillJobIDs = try Self.backfillJobIDs(accountID: accountID, db: db)
        }
        let containers = accountID.map { _ in
            Int((try? Self.scalarInt(db, sql: "SELECT count(*) FROM vault_containers WHERE account_id = ?", binds: [.text(accountID!)], operation: "deletion_container_count")) ?? 0)
        } ?? 1
        let accounts = accountID == nil ? 0 : 1
        try Self.withTransaction(db, operation: "deletion") {
            if let accountID {
                for jobID in backfillJobIDs {
                    try Self.execute(
                        db,
                        sql: "DELETE FROM vault_backfill_jobs WHERE job_id = ?",
                        binds: [.text(jobID)],
                        operation: "account_backfill_job_delete"
                    )
                }
                try Self.execute(db, sql: "DELETE FROM vault_accounts WHERE id = ?", binds: [.text(accountID)], operation: "account_delete")
            } else if let containerID {
                try Self.execute(db, sql: "DELETE FROM vault_containers WHERE id = ?", binds: [.text(containerID)], operation: "container_delete")
            }
        }
        let result = VaultDeletionSummary(
            accountsDeleted: accounts, containersDeleted: containers, recordsDeleted: records,
            revisionsDeleted: revisions, tombstonesDeleted: tombstones
        )
        emit(.deletion, trace: trace, status: .success, reason: accountID == nil ? "vault_container_deleted" : "vault_account_deleted", started: started,
             metadata: [
                (.recordCount, String(records)), (.revisionCount, String(revisions)),
                (.tombstoneCount, String(tombstones)), (.jobCount, String(backfillJobIDs.count)),
             ])
        return result
    }

    static func backfillJobIDs(accountID: String, db: OpaquePointer) throws -> [String] {
        var jobIDs: [String] = []
        try query(
            db,
            sql: "SELECT job_id, provider, checkpoint_json FROM vault_backfill_jobs ORDER BY job_id",
            operation: "account_backfill_job_scope_read"
        ) { statement in
            let jobID = text(statement, 0)
            let provider = text(statement, 1)
            let checkpoint = try makeBackfillDecoder().decode(
                VaultBackfillCheckpoint.self,
                from: blob(statement, 2)
            )
            if checkpoint.sources.contains(where: {
                VaultIdentity.accountID(provider: provider, providerAccountID: $0.accountID) == accountID
            }) {
                jobIDs.append(jobID)
            }
        }
        return jobIDs
    }

    static func scopeClause(accountID: String?, containerID: String?, prefix: String) -> ScopeClause {
        let qualified = prefix.isEmpty ? "" : "\(prefix)."
        var sql = ""
        var binds: [SQLValue] = []
        if let accountID { sql += " AND \(qualified)account_id = ?"; binds.append(.text(accountID)) }
        if let containerID { sql += " AND \(qualified)container_id = ?"; binds.append(.text(containerID)) }
        return .init(sql: sql, binds: binds)
    }

    static func searchTokens(_ input: String) throws -> [String] {
        guard input.count <= VaultLimits.maximumSearchCharacters else {
            throw failure("vault_search_query_too_long", operation: "search", recovery: .healthy)
        }
        let values = input.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard values.count <= VaultLimits.maximumSearchTokens else {
            throw failure("vault_search_too_many_tokens", operation: "search", recovery: .healthy)
        }
        return values
    }

    static func searchFilters(_ request: VaultSearchRequest) throws -> ScopeClause {
        var clauses: [String] = []
        var binds: [SQLValue] = []
        if let accountID = request.accountID { clauses.append("r.account_id = ?"); binds.append(.text(accountID)) }
        if let containerID = request.containerID { clauses.append("r.container_id = ?"); binds.append(.text(containerID)) }
        if let provider = request.provider { clauses.append("a.provider = ?"); binds.append(.text(provider)) }
        if let author = request.author { clauses.append("r.author = ?"); binds.append(.text(author)) }
        if let start = request.startDate { clauses.append("r.occurred_at >= ?"); binds.append(.integer(milliseconds(start))) }
        if let end = request.endDate { clauses.append("r.occurred_at <= ?"); binds.append(.integer(milliseconds(end))) }
        if let kind = request.itemKind { clauses.append("r.kind = ?"); binds.append(.text(kind)) }
        if let mention = request.directlyMentionsUser { clauses.append("r.direct_mention = ?"); binds.append(.integer(mention ? 1 : 0)) }
        if let read = request.readFilter { clauses.append("r.is_read = ?"); binds.append(.integer(read == .read ? 1 : 0)) }
        if let origin = request.contentOrigin { clauses.append("r.content_origin = ?"); binds.append(.text(origin.rawValue)) }
        return .init(sql: clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND "), binds: binds)
    }

    static func ftsSearch(
        _ db: OpaquePointer,
        tokens: [String],
        request: VaultSearchRequest,
        limit: Int
    ) throws -> VaultSearchResponse {
        guard !tokens.isEmpty, request.deleted != true else {
            return try likeSearch(db, tokens: tokens, request: request, limit: limit)
        }
        let filters = try searchFilters(request)
        let expression = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
        var records: [VaultRecord] = []
        try query(
            db,
            sql: recordSelect + " JOIN vault_records_fts ON vault_records_fts.rowid = r.rowid WHERE vault_records_fts MATCH ?\(filters.sql) ORDER BY r.occurred_at DESC, r.id ASC LIMIT ? OFFSET ?",
            binds: [.text(expression)] + filters.binds + [.integer(Int64(limit + 1)), .integer(Int64(max(0, request.offset)))],
            operation: "fts_search"
        ) { records.append(try decodeRecord($0)) }
        return searchResponse(records: records, tokens: tokens, mode: .fullText, limit: limit)
    }

    static func likeSearch(
        _ db: OpaquePointer,
        tokens: [String],
        request: VaultSearchRequest,
        limit: Int
    ) throws -> VaultSearchResponse {
        if request.deleted == true {
            return try deletedSearch(db, tokens: tokens, request: request, limit: limit)
        }
        let filters = try searchFilters(request)
        let tokenClauses = tokens.map { _ in "lower(r.title || ' ' || r.body || ' ' || coalesce(r.author, '')) LIKE ? ESCAPE '\\'" }
        let tokenSQL = tokenClauses.isEmpty ? "" : " AND " + tokenClauses.joined(separator: " AND ")
        let tokenBinds = tokens.map { SQLValue.text("%\(escapeLike($0))%") }
        var records: [VaultRecord] = []
        try query(
            db,
            sql: recordSelect + " WHERE 1 = 1\(tokenSQL)\(filters.sql) ORDER BY r.occurred_at DESC, r.id ASC LIMIT ? OFFSET ?",
            binds: tokenBinds + filters.binds + [.integer(Int64(limit + 1)), .integer(Int64(max(0, request.offset)))],
            operation: "like_search"
        ) { records.append(try decodeRecord($0)) }
        return searchResponse(records: records, tokens: tokens, mode: .likeFallback, limit: limit)
    }

    static func deletedSearch(
        _ db: OpaquePointer,
        tokens: [String],
        request: VaultSearchRequest,
        limit: Int
    ) throws -> VaultSearchResponse {
        guard tokens.isEmpty else {
            return .init(mode: .likeFallback, results: [], queryTokenCount: tokens.count, wasTruncated: false)
        }
        var clauses: [String] = []
        var binds: [SQLValue] = []
        if let account = request.accountID { clauses.append("t.account_id = ?"); binds.append(.text(account)) }
        if let container = request.containerID { clauses.append("t.container_id = ?"); binds.append(.text(container)) }
        if let provider = request.provider { clauses.append("a.provider = ?"); binds.append(.text(provider)) }
        if let start = request.startDate { clauses.append("t.deleted_at >= ?"); binds.append(.integer(milliseconds(start))) }
        if let end = request.endDate { clauses.append("t.deleted_at <= ?"); binds.append(.integer(milliseconds(end))) }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var results: [VaultSearchResult] = []
        try query(
            db,
            sql: """
                SELECT t.record_id, t.account_id, t.container_id, t.provider_record_id,
                       t.deleted_at, a.provider, t.prior_content_purged
                FROM vault_tombstones t JOIN vault_accounts a ON a.id = t.account_id
                \(whereSQL) ORDER BY t.deleted_at DESC, t.record_id ASC LIMIT ? OFFSET ?
                """,
            binds: binds + [.integer(Int64(limit + 1)), .integer(Int64(max(0, request.offset)))],
            operation: "deleted_search"
        ) { statement in
            results.append(.init(
                id: text(statement, 0), accountID: text(statement, 1), containerID: text(statement, 2),
                kind: "tombstone", title: "Deleted source item",
                snippet: sqlite3_column_int(statement, 6) == 1
                    ? "Prior content purged locally."
                    : "No prior content was archived.",
                occurredAt: date(statement, 4), revision: 0, contentChecksum: "",
                provider: text(statement, 5), author: nil, sourceURL: nil, directlyMentionsUser: false,
                isRead: false, isDeleted: true, contentOrigin: .source
            ))
        }
        let truncated = results.count > limit
        return .init(mode: .likeFallback, results: Array(results.prefix(limit)), queryTokenCount: 0, wasTruncated: truncated)
    }

    static func searchResponse(records: [VaultRecord], tokens: [String], mode: VaultSearchMode, limit: Int) -> VaultSearchResponse {
        let truncated = records.count > limit
        let results = records.prefix(limit).map { record in
            VaultSearchResult(
                id: record.id, accountID: record.accountID, containerID: record.containerID,
                kind: record.kind, title: record.title,
                snippet: snippet(for: record, tokens: tokens), occurredAt: record.occurredAt,
                revision: record.revision, contentChecksum: record.contentChecksum,
                provider: record.provider, author: record.author, sourceURL: record.sourceURL,
                directlyMentionsUser: record.directlyMentionsUser, isRead: record.isRead,
                isDeleted: false, contentOrigin: record.contentOrigin,
                attachedSourceProvenance:
                    VaultAttachedSourceProvenance.project(from: record)
            )
        }
        return .init(mode: mode, results: Array(results), queryTokenCount: tokens.count, wasTruncated: truncated)
    }

    static func snippet(for record: VaultRecord, tokens: [String]) -> String {
        let source = record.body.isEmpty ? record.title : record.body
        guard source.count > VaultLimits.maximumSearchSnippetCharacters else { return source }
        let lower = source.lowercased()
        let index = tokens.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? source.startIndex
        let offset = max(0, lower.distance(from: lower.startIndex, to: index) - 80)
        let start = source.index(source.startIndex, offsetBy: min(offset, source.count))
        return String(source[start...].prefix(VaultLimits.maximumSearchSnippetCharacters))
    }

    static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func storageContributions(_ db: OpaquePointer) throws -> [VaultStorageContribution] {
        var values: [VaultStorageContribution] = []
        try query(
            db,
            sql: """
                SELECT a.provider, a.id, count(r.id),
                       coalesce((SELECT count(*) FROM vault_revisions v JOIN vault_records rr ON rr.id = v.record_id WHERE rr.account_id = a.id), 0),
                       coalesce(sum(length(r.title) + length(r.body) + length(coalesce(r.author, '')) + length(r.metadata_json)), 0),
                       min(r.occurred_at), max(r.occurred_at)
                FROM vault_accounts a LEFT JOIN vault_records r ON r.account_id = a.id
                GROUP BY a.provider, a.id ORDER BY a.provider, a.id
                """,
            operation: "storage_contributions"
        ) { statement in
            values.append(.init(
                provider: text(statement, 0), accountID: text(statement, 1),
                itemCount: Int(sqlite3_column_int64(statement, 2)), revisionCount: Int(sqlite3_column_int64(statement, 3)),
                estimatedBytes: sqlite3_column_int64(statement, 4),
                oldestItemAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : date(statement, 5),
                newestItemAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : date(statement, 6)
            ))
        }
        return values
    }

    static func exportRows(_ db: OpaquePointer, scope: VaultExportScope) throws -> [ExportRow] {
        if let accountID = scope.accountID { try validateIdentifier(accountID, field: "account_id") }
        if let start = scope.startDate, let end = scope.endDate, start > end {
            throw failure("vault_export_date_range_invalid", operation: "export", recovery: .healthy)
        }
        var rows: [ExportRow] = []
        let accountWhere = scope.accountID == nil ? "" : " WHERE id = ?"
        let accountBinds = scope.accountID.map { [SQLValue.text($0)] } ?? []
        try query(
            db,
            sql: "SELECT id, provider, provider_account_id, display_name, created_at, updated_at FROM vault_accounts\(accountWhere) ORDER BY provider, id",
            binds: accountBinds,
            operation: "export_accounts"
        ) { statement in
            rows.append(.init(type: "account", payload: [
                "id": text(statement, 0), "provider": text(statement, 1),
                "provider_account_id": text(statement, 2), "display_name": text(statement, 3),
                "created_at": iso8601(date(statement, 4)), "updated_at": iso8601(date(statement, 5)),
            ]))
        }
        let containerWhere = scope.accountID == nil ? "" : " WHERE account_id = ?"
        try query(
            db,
            sql: "SELECT id, account_id, provider_container_id, kind, display_name, created_at, updated_at FROM vault_containers\(containerWhere) ORDER BY account_id, id",
            binds: accountBinds,
            operation: "export_containers"
        ) { statement in
            rows.append(.init(type: "container", payload: [
                "id": text(statement, 0), "account_id": text(statement, 1),
                "provider_container_id": text(statement, 2), "kind": text(statement, 3),
                "display_name": text(statement, 4), "created_at": iso8601(date(statement, 5)),
                "updated_at": iso8601(date(statement, 6)),
            ]))
        }

        let filter = exportRecordFilter(scope: scope, alias: "r")
        try query(
            db,
            sql: recordSelect + " WHERE 1 = 1\(filter.sql) ORDER BY r.account_id, r.container_id, r.occurred_at, r.id",
            binds: filter.binds,
            operation: "export_records"
        ) { statement in
            let record = try decodeRecord(statement)
            rows.append(.init(type: "record", payload: recordPayload(record)))
        }
        try query(
            db,
            sql: """
                SELECT v.record_id, v.revision, v.title, v.body, v.author, v.source_url,
                       v.occurred_at, v.captured_at, v.modified_at, v.metadata_json,
                       v.content_checksum, v.stored_at
                FROM vault_revisions v JOIN vault_records r ON r.id = v.record_id
                WHERE 1 = 1\(filter.sql)
                ORDER BY r.account_id, v.record_id, v.revision
                """,
            binds: filter.binds,
            operation: "export_revisions"
        ) { statement in
            let revision = try decodeRevision(statement)
            rows.append(.init(type: "revision", payload: revisionPayload(revision)))
        }
        let tombstone = exportTombstoneFilter(scope: scope)
        try query(
            db,
            sql: """
                SELECT record_id, account_id, container_id, provider_record_id, reason, deleted_at, prior_content_purged
                FROM vault_tombstones WHERE 1 = 1\(tombstone.sql)
                ORDER BY account_id, container_id, deleted_at, record_id
                """,
            binds: tombstone.binds,
            operation: "export_tombstones"
        ) { statement in
            rows.append(.init(type: "tombstone", payload: [
                "record_id": text(statement, 0), "account_id": text(statement, 1),
                "container_id": text(statement, 2), "provider_record_id": text(statement, 3),
                "reason": text(statement, 4), "deleted_at": iso8601(date(statement, 5)),
                "prior_content_purged": sqlite3_column_int(statement, 6) == 1,
            ]))
        }
        try query(
            db,
            sql: """
                SELECT p.record_id, p.provider, p.provider_account_id, p.provider_container_id,
                       p.provider_item_id, p.retrieved_at, p.source_url, p.content_origin
                FROM vault_provenance p JOIN vault_records r ON r.id = p.record_id
                WHERE 1 = 1\(filter.sql)
                ORDER BY r.account_id, r.container_id, r.occurred_at, p.record_id
                """,
            binds: filter.binds,
            operation: "export_provenance"
        ) { statement in
            rows.append(.init(type: "provenance", payload: [
                "record_id": text(statement, 0), "provider": text(statement, 1),
                "provider_account_id": text(statement, 2), "provider_container_id": text(statement, 3),
                "provider_item_id": text(statement, 4), "retrieved_at": iso8601(date(statement, 5)),
                "source_url": optionalText(statement, 6).map { $0 as Any } ?? NSNull(), "content_origin": text(statement, 7),
            ]))
        }
        return rows
    }

    static func exportRecordFilter(scope: VaultExportScope, alias: String) -> ScopeClause {
        var sql = ""
        var binds: [SQLValue] = []
        if let account = scope.accountID { sql += " AND \(alias).account_id = ?"; binds.append(.text(account)) }
        if let start = scope.startDate { sql += " AND \(alias).occurred_at >= ?"; binds.append(.integer(milliseconds(start))) }
        if let end = scope.endDate { sql += " AND \(alias).occurred_at <= ?"; binds.append(.integer(milliseconds(end))) }
        return .init(sql: sql, binds: binds)
    }

    static func exportTombstoneFilter(scope: VaultExportScope) -> ScopeClause {
        var sql = ""
        var binds: [SQLValue] = []
        if let account = scope.accountID { sql += " AND account_id = ?"; binds.append(.text(account)) }
        if let start = scope.startDate { sql += " AND deleted_at >= ?"; binds.append(.integer(milliseconds(start))) }
        if let end = scope.endDate { sql += " AND deleted_at <= ?"; binds.append(.integer(milliseconds(end))) }
        return .init(sql: sql, binds: binds)
    }

    static func recordPayload(_ record: VaultRecord) -> [String: Any] {
        [
            "id": record.id, "account_id": record.accountID, "container_id": record.containerID,
            "provider": record.provider, "provider_record_id": record.providerRecordID, "kind": record.kind,
            "title": record.title, "body": record.body,
            "author": record.author.map { $0 as Any } ?? NSNull(),
            "source_url": record.sourceURL.map { $0.absoluteString as Any } ?? NSNull(),
            "occurred_at": iso8601(record.occurredAt),
            "captured_at": iso8601(record.capturedAt), "modified_at": iso8601(record.modifiedAt),
            "inserted_at": iso8601(record.insertedAt), "metadata": record.metadata,
            "revision": record.revision, "content_checksum": record.contentChecksum,
            "direct_mention": record.directlyMentionsUser, "is_read": record.isRead,
            "content_origin": record.contentOrigin.rawValue,
            "provider_metadata_version": record.providerMetadataVersion,
            "thread_root_id": record.threadRootID.map { $0 as Any } ?? NSNull(), "reply_count": record.replyCount,
        ]
    }

    static func revisionPayload(_ revision: VaultRecordRevision) -> [String: Any] {
        [
            "record_id": revision.recordID, "revision": revision.revision,
            "title": revision.title, "body": revision.body,
            "author": revision.author.map { $0 as Any } ?? NSNull(),
            "source_url": revision.sourceURL.map { $0.absoluteString as Any } ?? NSNull(),
            "occurred_at": iso8601(revision.occurredAt),
            "captured_at": iso8601(revision.capturedAt), "modified_at": iso8601(revision.modifiedAt),
            "metadata": revision.metadata, "content_checksum": revision.contentChecksum,
            "stored_at": iso8601(revision.storedAt),
        ]
    }

    static func exportEnvelope(sequence: Int, type: String, payload: [String: Any]) throws -> String {
        let checksum = sha256(try canonicalJSON(payload))
        let envelope: [String: Any] = [
            "sequence": sequence,
            "type": type,
            "payload": payload,
            "checksum": checksum,
        ]
        guard let text = String(data: try canonicalJSON(envelope), encoding: .utf8) else {
            throw failure("vault_export_encoding_failed", operation: "export", recovery: .healthy)
        }
        return text
    }

    static func canonicalJSON(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw failure("vault_json_invalid", operation: "json_encode", recovery: .healthy)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func failure(
        _ reason: String,
        operation: String,
        code: Int32? = nil,
        recovery: VaultRecoveryClassification
    ) -> VaultDatabaseFailure {
        .init(reasonCode: reason, operation: operation, sqliteCode: code, recoveryClassification: recovery)
    }

    static func sqliteFailure(_ db: OpaquePointer, code: Int32, operation: String) -> VaultDatabaseFailure {
        let recovery: VaultRecoveryClassification
        let reason: String
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED:
            recovery = .lockedRetryable
            reason = "vault_sqlite_busy"
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            recovery = .corruptionPreserveOriginal
            reason = "vault_sqlite_corrupt"
        case SQLITE_READONLY, SQLITE_CANTOPEN, SQLITE_PERM:
            recovery = .inaccessiblePreserveOriginal
            reason = "vault_sqlite_inaccessible"
        default:
            recovery = .unknownPreserveOriginal
            reason = "vault_sqlite_operation_failed"
        }
        return failure(reason, operation: operation, code: code, recovery: recovery)
    }

    static func traceEvent(
        name: VaultTraceEventName,
        trace: VaultTraceContext,
        status: VaultTraceStatus,
        reason: String,
        metadata: VaultTraceMetadata = .init()
    ) -> VaultTraceEvent {
        .init(
            ts: Date(), event: name, traceID: trace.traceID, spanID: trace.spanID,
            parentSpanID: trace.parentSpanID, component: "vault_database", status: status,
            reasonCode: String(reason.prefix(120)), durationMilliseconds: nil, metadata: metadata
        )
    }

    func emit(
        _ event: VaultTraceEventName,
        trace: VaultTraceContext,
        status: VaultTraceStatus,
        reason: String,
        started: Date,
        metadata: [(VaultTraceMetadataKey, String)] = []
    ) {
        traceSink(.init(
            ts: Date(), event: event, traceID: trace.traceID, spanID: trace.spanID,
            parentSpanID: trace.parentSpanID, component: "vault_database", status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000)),
            metadata: .init(metadata)
        ))
    }

    func emitFailure(
        _ event: VaultTraceEventName,
        trace: VaultTraceContext,
        error: Error,
        started: Date,
        metadata: [(VaultTraceMetadataKey, String)] = []
    ) {
        let failure = error as? VaultDatabaseFailure
        var values = metadata
        if let code = failure?.sqliteCode { values.append((.sqliteCode, String(code))) }
        emit(
            event, trace: trace, status: .failed,
            reason: failure?.reasonCode ?? "vault_operation_failed", started: started, metadata: values
        )
    }
}

extension VaultDatabase: VaultBackfillPersisting {
    func load(jobID: String) async throws -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint)? {
        try Self.validateIdentifier(jobID, field: "job_id")
        let db = try activeConnection(operation: "backfill_job_load")
        var value: (VaultBackfillJob, VaultBackfillCheckpoint)?
        try Self.query(
            db,
            sql: "SELECT job_json, checkpoint_json FROM vault_backfill_jobs WHERE job_id = ?",
            binds: [.text(jobID)],
            operation: "backfill_job_load"
        ) { statement in
            let jobData = Self.blob(statement, 0)
            let checkpointData = Self.blob(statement, 1)
            value = (
                try Self.makeBackfillDecoder().decode(VaultBackfillJob.self, from: jobData),
                try Self.makeBackfillDecoder().decode(VaultBackfillCheckpoint.self, from: checkpointData)
            )
        }
        return value
    }

    func commit(
        job: VaultBackfillJob,
        checkpoint: VaultBackfillCheckpoint,
        items: [VaultBackfillArchiveItem]
    ) async throws -> VaultBackfillCommitResult {
        try Self.validateIdentifier(job.id, field: "job_id")
        guard checkpoint.schemaVersion == 1,
              items.count <= VaultLimits.maximumBatchSize,
              checkpoint.sources.allSatisfy({ !$0.accountID.isEmpty && !$0.sourceID.isEmpty }),
              Set(checkpoint.sources.map(\.accountID)).count == 1
        else { throw Self.failure("vault_backfill_checkpoint_invalid", operation: "backfill_commit", recovery: .healthy) }

        let allowedScopes = Set(checkpoint.sources.map { "\($0.accountID)\u{1f}\($0.sourceID)" })

        let jobData = try Self.makeBackfillEncoder().encode(job)
        let checkpointData = try Self.makeBackfillEncoder().encode(checkpoint)
        let db = try activeConnection(operation: "backfill_commit")
        var inserted = 0
        var storedBytes = 0
        try Self.withTransaction(db, operation: "backfill_commit") {
            for item in items {
                guard item.provider == job.provider,
                      allowedScopes.contains("\(item.accountID)\u{1f}\(item.sourceID)"),
                      item.estimatedStorageBytes >= 0,
                      item.body.lengthOfBytes(using: .utf8) <= VaultLimits.maximumBodyBytes
                else { throw Self.failure("vault_backfill_item_invalid", operation: "backfill_commit", recovery: .healthy) }
                let archiveAccountID = VaultIdentity.accountID(provider: item.provider, providerAccountID: item.accountID)
                let archiveContainerID = VaultIdentity.containerID(
                    provider: item.provider,
                    accountID: archiveAccountID,
                    providerContainerID: item.sourceID
                )
                let timestamp = Self.milliseconds(item.retrievedAt)
                try Self.execute(
                    db,
                    sql: """
                        INSERT INTO vault_accounts(id, provider, provider_account_id, display_name, created_at, updated_at)
                        VALUES(?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at
                        """,
                    binds: [
                        .text(archiveAccountID), .text(item.provider), .text(item.accountID),
                        .text(item.provider == "slack" ? "Slack workspace" : "Provider account"),
                        .integer(timestamp), .integer(timestamp),
                    ],
                    operation: "backfill_account_upsert"
                )
                try Self.execute(
                    db,
                    sql: """
                        INSERT INTO vault_containers(id, account_id, provider_container_id, kind, display_name, created_at, updated_at)
                        VALUES(?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name, updated_at = excluded.updated_at
                        """,
                    binds: [
                        .text(archiveContainerID), .text(archiveAccountID), .text(item.sourceID),
                        .text(item.provider == "slack" ? "slack_channel" : "feed"),
                        .text(item.sourceName), .integer(timestamp), .integer(timestamp),
                    ],
                    operation: "backfill_container_upsert"
                )

                if item.isTombstone {
                    if try Self.tombstoneRecord(recordID: item.id, reason: .sourceDeleted, deletedAt: item.retrievedAt, db: db) == nil {
                        try Self.execute(
                            db,
                            sql: """
                                INSERT INTO vault_tombstones(
                                    record_id, account_id, container_id, provider_record_id, reason, deleted_at, prior_content_purged
                                ) VALUES(?, ?, ?, ?, ?, ?, 0)
                                ON CONFLICT(record_id) DO UPDATE SET reason = excluded.reason, deleted_at = excluded.deleted_at
                                """,
                            binds: [
                                .text(item.id), .text(archiveAccountID), .text(archiveContainerID),
                                .text(item.providerItemID), .text(VaultTombstoneReason.sourceDeleted.rawValue),
                                .integer(timestamp),
                            ],
                            operation: "backfill_tombstone_upsert"
                        )
                    }
                    continue
                }

                let input = VaultRecordInput(
                    id: item.id,
                    accountID: archiveAccountID,
                    containerID: archiveContainerID,
                    providerRecordID: item.providerItemID,
                    kind: item.provider == "slack" ? "message" : "feed_item",
                    title: item.title,
                    body: item.body,
                    author: item.authorName,
                    sourceURL: item.sourceURL,
                    occurredAt: item.occurredAt,
                    capturedAt: item.retrievedAt,
                    modifiedAt: item.editedAt ?? item.occurredAt,
                    metadata: [
                        "backfill": "true",
                        "edited": String(item.isEdited),
                    ],
                    directlyMentionsUser: item.directlyMentionsUser,
                    isRead: false,
                    contentOrigin: item.contentOrigin,
                    providerMetadataVersion: 1,
                    threadRootID: item.threadRootID,
                    replyCount: item.replyCount
                )
                try Self.validateRecord(input)
                let result = try Self.upsertRecord(input, db: db)
                if result.disposition != .unchanged {
                    inserted += 1
                    storedBytes += item.estimatedStorageBytes
                }
            }
            try Self.execute(
                db,
                sql: """
                    INSERT INTO vault_backfill_jobs(job_id, provider, state, job_json, checkpoint_json, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(job_id) DO UPDATE SET
                        provider = excluded.provider,
                        state = excluded.state,
                        job_json = excluded.job_json,
                        checkpoint_json = excluded.checkpoint_json,
                        updated_at = excluded.updated_at
                    """,
                binds: [
                    .text(job.id), .text(job.provider), .text(job.state.rawValue),
                    .blob(jobData), .blob(checkpointData), .integer(Self.milliseconds(job.updatedAt)),
                ],
                operation: "backfill_job_persist"
            )
        }
        return .init(insertedItemCount: inserted, storedBytes: storedBytes)
    }
}

private extension VaultDatabase {
    static func makeBackfillEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeBackfillDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
