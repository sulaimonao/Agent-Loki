import CryptoKit
import Foundation
import OSLog

enum VaultTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum VaultTraceEventName: String, Codable, CaseIterable, Sendable {
    case databaseOpen = "vault.database_open"
    case migration = "vault.migration"
    case integrityCheck = "vault.integrity_check"
    case accountUpsert = "vault.account_upsert"
    case containerUpsert = "vault.container_upsert"
    case recordUpsert = "vault.record_upsert"
    case tombstone = "vault.tombstone"
    case search = "vault.search"
    case retention = "vault.retention"
    case deletion = "vault.deletion"
    case storageSummary = "vault.storage_summary"
    case export = "vault.export"
    case databaseClose = "vault.database_close"
    case recovery = "vault.recovery"
    case attachedPreview = "attached_data.preview"
    case attachedImport = "attached_data.import"
    case attachedRefresh = "attached_data.refresh"
    case attachedDetach = "attached_data.detach"
    case attachedRemove = "attached_data.remove_local_data"
}

enum VaultTraceMetadataKey: String, Codable, CaseIterable, Hashable, Sendable {
    case operation
    case schemaVersion = "schema_version"
    case previousSchemaVersion = "previous_schema_version"
    case accountHash = "account_hash"
    case containerHash = "container_hash"
    case containerCount = "container_count"
    case recordHash = "record_hash"
    case recordCount = "record_count"
    case revisionCount = "revision_count"
    case tombstoneCount = "tombstone_count"
    case jobCount = "job_count"
    case deletedCount = "deleted_count"
    case resultCount = "result_count"
    case queryTokenCount = "query_token_count"
    case searchMode = "search_mode"
    case disposition
    case sqliteCode = "sqlite_code"
    case ftsAvailable = "fts_available"
    case byteCount = "byte_count"
    case checksumPrefix = "checksum_prefix"
    case sourceKind = "source_kind"
    case sourceHash = "source_hash"
    case pageCount = "page_count"
    case skippedCount = "skipped_count"
    case truncationCount = "truncation_count"
}

struct VaultTraceMetadata: Codable, Hashable, Sendable {
    private(set) var values: [VaultTraceMetadataKey: String]

    init(_ entries: [(VaultTraceMetadataKey, String)] = []) {
        var bounded: [VaultTraceMetadataKey: String] = [:]
        for (key, value) in entries.prefix(16) {
            bounded[key] = VaultPrivacy.boundedMetadata(value)
        }
        values = bounded
    }

    subscript(_ key: VaultTraceMetadataKey) -> String? { values[key] }
}

struct VaultTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = VaultPrivacy.boundedMetadata(traceID)
        self.spanID = VaultPrivacy.boundedMetadata(spanID)
        self.parentSpanID = parentSpanID.map(VaultPrivacy.boundedMetadata)
    }

    func child() -> VaultTraceContext {
        .init(traceID: traceID, spanID: UUID().uuidString.lowercased(), parentSpanID: spanID)
    }
}

struct VaultTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: VaultTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: VaultTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: VaultTraceMetadata

    enum CodingKeys: String, CodingKey {
        case ts
        case event
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case component
        case status
        case reasonCode = "reason_code"
        case durationMilliseconds = "duration_ms"
        case metadata
    }
}

typealias VaultTraceSink = @Sendable (VaultTraceEvent) -> Void

enum VaultProductionTraceLogger {
    private static let logger = Logger(subsystem: "com.agentloki.LokiBrief", category: "vault")

    static func emit(_ event: VaultTraceEvent) {
        guard let line = encodedLine(for: event) else {
            logger.error("{\"event\":\"vault.trace_encoding\",\"status\":\"failed\",\"reason_code\":\"vault_trace_encoding_failed\"}")
            return
        }
        logger.info("\(line, privacy: .public)")
    }

    static func encodedLine(for event: VaultTraceEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              data.count <= 8_192,
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }
}

enum VaultBackfillProductionTraceLogger {
    private static let logger = Logger(subsystem: "com.agentloki.LokiBrief", category: "vault-backfill")

    static func emit(_ event: VaultBackfillTraceEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              data.count <= 8_192,
              let line = String(data: data, encoding: .utf8)
        else {
            logger.error("{\"event\":\"vault.backfill.trace_encoding\",\"status\":\"failed\",\"reason_code\":\"vault_backfill_trace_encoding_failed\"}")
            return
        }
        logger.info("\(line, privacy: .public)")
    }
}

enum VaultPrivacy {
    static func hashIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedMetadata(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(160))
    }

    static func checksumPrefix(_ value: String) -> String {
        String(value.prefix(12))
    }
}
