import CryptoKit
import Foundation
import OSLog

enum ScheduledBriefingTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum ScheduledBriefingTraceEventName: String, Codable, CaseIterable, Sendable {
    case applicationShutdown = "application.shutdown"
    case run = "scheduled.run"
    case sourceRefresh = "scheduled.source_refresh"
    case vaultReconciliation = "scheduled.vault_reconcile"
    case deterministicAssembly = "scheduled.brief_assembly"
    case localPresentation = "scheduled.local_generation"
    case cancellation = "scheduled.cancellation"
    case budget = "scheduled.budget"
    case lateResultRejected = "scheduled.late_result_rejected"
    case recovery = "scheduled.run_recovered"
}

enum ScheduledBriefingTraceMetadataKey: String, Codable, CaseIterable, Hashable, Sendable {
    case shutdownResult = "shutdown_result"
    case timeoutMilliseconds = "timeout_ms"
    case runHash = "run_hash"
    case occurrenceHash = "occurrence_hash"
    case sourceHash = "source_hash"
    case sourceKind = "source_kind"
    case trigger
    case stage
    case feedCount = "feed_count"
    case slackWorkspaceCount = "slack_workspace_count"
    case sourceSuccessCount = "source_success_count"
    case sourceFailureCount = "source_failure_count"
    case acceptedItemCount = "accepted_item_count"
    case changedItemCount = "changed_item_count"
    case excludedItemCount = "excluded_item_count"
    case briefHash = "brief_hash"
    case fallbackUsed = "fallback_used"
    case activeRunHash = "active_run_hash"
    case feedRequestCount = "feed_request_count"
    case slackRequestCount = "slack_request_count"
    case transientRetryCount = "transient_retry_count"
    case archiveItemCount = "archive_item_count"
    case archiveStorageBytes = "archive_storage_bytes"
    case ollamaAllowanceMilliseconds = "ollama_allowance_ms"
    case ollamaElapsedMilliseconds = "ollama_elapsed_ms"
    case exhaustionCount = "exhaustion_count"
}

struct ScheduledBriefingTraceMetadata: Codable, Hashable, Sendable {
    private(set) var values: [ScheduledBriefingTraceMetadataKey: String]

    init(_ entries: [(ScheduledBriefingTraceMetadataKey, String)] = []) {
        var bounded: [ScheduledBriefingTraceMetadataKey: String] = [:]
        for (key, value) in entries.prefix(16) {
            bounded[key] = ScheduledBriefingPrivacy.boundedMetadata(value)
        }
        values = bounded
    }

    subscript(_ key: ScheduledBriefingTraceMetadataKey) -> String? { values[key] }
}

struct ScheduledBriefingTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = ScheduledBriefingPrivacy.boundedMetadata(traceID)
        self.spanID = ScheduledBriefingPrivacy.boundedMetadata(spanID)
        self.parentSpanID = parentSpanID.map(ScheduledBriefingPrivacy.boundedMetadata)
    }

    func child() -> ScheduledBriefingTraceContext {
        .init(traceID: traceID, spanID: UUID().uuidString.lowercased(), parentSpanID: spanID)
    }
}

struct ScheduledBriefingTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: ScheduledBriefingTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: ScheduledBriefingTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: ScheduledBriefingTraceMetadata

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

typealias ScheduledBriefingTraceSink = @Sendable (ScheduledBriefingTraceEvent) -> Void

enum ScheduledBriefingProductionTraceLogger {
    private static let logger = Logger(subsystem: "com.agentloki.LokiBrief", category: "scheduled-briefing")

    static func emit(_ event: ScheduledBriefingTraceEvent) {
        guard let line = encodedLine(for: event) else {
            logger.error("{\"event\":\"scheduled.trace_encoding\",\"status\":\"failed\",\"reason_code\":\"scheduled_trace_encoding_failed\"}")
            return
        }
        logger.info("\(line, privacy: .public)")
    }

    static func encodedLine(for event: ScheduledBriefingTraceEvent) -> String? {
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

enum ScheduledBriefingPrivacy {
    static func hashIdentifier(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedMetadata(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !isBidirectionalControl($0.value)
        }
        return String(String.UnicodeScalarView(scalars).prefix(160))
    }

    static func boundedReasonCode(_ value: String) -> String {
        let normalized = boundedMetadata(value)
        return String(normalized.prefix(120))
    }

    private static func isBidirectionalControl(_ value: UInt32) -> Bool {
        (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }
}
