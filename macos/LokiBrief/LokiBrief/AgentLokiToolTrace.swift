import Foundation
import OSLog

enum AgentLokiToolTraceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum AgentLokiToolTraceEventName: String, Codable, CaseIterable, Hashable, Sendable {
    case requested = "chat_tool_requested"
    case validated = "chat_tool_validated"
    case rejected = "chat_tool_rejected"
    case completed = "chat_tool_completed"
}

enum AgentLokiToolTraceMetadataKey: String, Codable, CaseIterable, Hashable, Sendable {
    case tool
    case modelIdentifierHash = "model_identifier_hash"
    case evidenceCount = "evidence_count"
    case resultCount = "result_count"
    case tokenEstimate = "token_estimate"
    case wasTruncated = "was_truncated"
    case activeRequestCount = "active_request_count"
    case schemaVersion = "schema_version"
}

struct AgentLokiToolTraceMetadata: Codable, Hashable, Sendable {
    static let maximumEntries = 12
    static let maximumValueCharacters = 80

    private(set) var values: [AgentLokiToolTraceMetadataKey: String]

    init(_ entries: [(AgentLokiToolTraceMetadataKey, String)] = []) {
        var bounded: [AgentLokiToolTraceMetadataKey: String] = [:]
        for (key, rawValue) in entries.prefix(Self.maximumEntries) {
            bounded[key] = Self.normalizedValue(rawValue, for: key)
        }
        values = bounded
    }

    subscript(_ key: AgentLokiToolTraceMetadataKey) -> String? {
        values[key]
    }

    private static func normalizedValue(
        _ value: String,
        for key: AgentLokiToolTraceMetadataKey
    ) -> String {
        switch key {
        case .tool:
            return AgentLokiReadOnlyToolName(rawValue: value)?.rawValue ?? "unregistered"
        case .modelIdentifierHash:
            let candidate = AgentLokiEvidenceSanitizer.classification(value)
            let scalars = candidate.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
            let result = String(String.UnicodeScalarView(scalars))
            return String((result.isEmpty ? "unavailable" : result).prefix(64))
        case .evidenceCount, .resultCount, .tokenEstimate, .activeRequestCount:
            guard let count = Int(value), count >= 0 else { return "0" }
            return String(min(count, 1_000_000))
        case .wasTruncated:
            return value == "true" ? "true" : "false"
        case .schemaVersion:
            let candidate = AgentLokiEvidenceSanitizer.classification(value)
            return String(candidate.prefix(Self.maximumValueCharacters))
        }
    }
}

struct AgentLokiToolTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = Self.boundedLink(traceID)
        self.spanID = Self.boundedLink(spanID)
        self.parentSpanID = parentSpanID.map(Self.boundedLink)
    }

    func child(spanID: String = UUID().uuidString.lowercased()) -> AgentLokiToolTraceContext {
        AgentLokiToolTraceContext(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: self.spanID
        )
    }

    private static func boundedLink(_ value: String) -> String {
        let classified = AgentLokiEvidenceSanitizer.classification(value)
        return String(classified.prefix(80))
    }
}

struct AgentLokiToolTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: AgentLokiToolTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: AgentLokiToolTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: AgentLokiToolTraceMetadata

    init(
        ts: Date = Date(),
        event: AgentLokiToolTraceEventName,
        context: AgentLokiToolTraceContext,
        status: AgentLokiToolTraceStatus,
        reasonCode: String,
        durationMilliseconds: Int? = nil,
        metadata: AgentLokiToolTraceMetadata = .init()
    ) {
        self.ts = ts
        self.event = event
        self.traceID = context.traceID
        self.spanID = context.spanID
        self.parentSpanID = context.parentSpanID
        self.component = "agent_loki_read_only_tools"
        self.status = status
        self.reasonCode = AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.metadata = metadata
    }

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

typealias AgentLokiToolTraceSink = @Sendable (AgentLokiToolTraceEvent) -> Void

struct AgentLokiToolTraceLogger: Sendable {
    private let subsystem: String
    private let sink: AgentLokiToolTraceSink?

    init(
        subsystem: String = "com.agentloki.LokiBrief",
        sink: AgentLokiToolTraceSink? = nil
    ) {
        self.subsystem = subsystem
        self.sink = sink
    }

    func emit(_ event: AgentLokiToolTraceEvent) {
        sink?(event)
        guard sink == nil else { return }
        let logger = Logger(subsystem: subsystem, category: "agent-loki-tools")
        guard let line = encodedLine(for: event) else {
            logger.error(
                "{\"event\":\"chat_tool_trace_encoding\",\"status\":\"failed\",\"reason_code\":\"chat_tool_trace_encoding_failed\"}"
            )
            return
        }
        logger.info("\(line, privacy: .public)")
    }

    func encodedLine(for event: AgentLokiToolTraceEvent) -> String? {
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

enum AgentLokiToolTracePrivacy {
    static func modelIdentifierHash(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "unavailable" }
        return AgentLokiEvidenceHasher.sha256Prefix(identifier, bytes: 16)
    }
}
