import CryptoKit
import Foundation
import os

enum OllamaChatTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum OllamaChatTraceEventName: String, Codable, CaseIterable, Sendable {
    case chatStarted = "chat_started"
    case chatContextBuilt = "chat_context_built"
    case chatStreamStarted = "chat_stream_started"
    case chatToolRequested = "chat_tool_requested"
    case chatToolValidated = "chat_tool_validated"
    case chatToolRejected = "chat_tool_rejected"
    case chatToolCompleted = "chat_tool_completed"
    case chatGenerationResumed = "chat_generation_resumed"
    case chatCompleted = "chat_completed"
    case chatCanceled = "chat_canceled"
    case chatFailed = "chat_failed"
    case modelProfileInspected = "model_profile_inspected"
    case modelAssessmentStarted = "model_assessment_started"
    case modelAssessmentCompleted = "model_assessment_completed"
    case modelAssessmentFailed = "model_assessment_failed"
    case embeddingAssessmentInvalidated =
        "embedding_assessment_invalidated"
    case modelPreferenceChanged = "model_preference_changed"
    case conversationDeleted = "conversation_deleted"
}

struct OllamaChatTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = "trace_\(UUID().uuidString.lowercased())",
        spanID: String = "span_\(UUID().uuidString.lowercased())",
        parentSpanID: String? = nil
    ) {
        self.traceID = OllamaChatTracePrivacy.boundedIdentifier(traceID, fallbackPrefix: "trace")
        self.spanID = OllamaChatTracePrivacy.boundedIdentifier(spanID, fallbackPrefix: "span")
        self.parentSpanID = parentSpanID.map {
            OllamaChatTracePrivacy.boundedIdentifier($0, fallbackPrefix: "span")
        }
    }

    func child() -> OllamaChatTraceContext {
        .init(
            traceID: traceID,
            spanID: "span_\(UUID().uuidString.lowercased())",
            parentSpanID: spanID
        )
    }
}

struct OllamaChatTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: OllamaChatTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: OllamaChatTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: [String: String]

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

    init(
        ts: Date = Date(),
        event: OllamaChatTraceEventName,
        context: OllamaChatTraceContext,
        component: String,
        status: OllamaChatTraceStatus,
        reasonCode: String,
        durationMilliseconds: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.ts = ts
        self.event = event
        traceID = context.traceID
        spanID = context.spanID
        parentSpanID = context.parentSpanID
        self.component = OllamaChatTracePrivacy.boundedComponent(component)
        self.status = status
        self.reasonCode = OllamaChatTracePrivacy.boundedReasonCode(reasonCode)
        self.durationMilliseconds = durationMilliseconds.map {
            min(max($0, 0), 600_000)
        }
        self.metadata = OllamaChatTracePrivacy.sanitizedMetadata(metadata)
    }
}

typealias OllamaChatTraceSink = @Sendable (OllamaChatTraceEvent) -> Void

enum OllamaChatTracePrivacy {
    private static let allowedMetadataKeys: Set<String> = [
        "assessment_version",
        "capability_count",
        "chunk_count",
        "context_classification",
        "evidence_count",
        "http_status",
        "missing_count",
        "model_hash",
        "operation",
        "probe",
        "request_bytes",
        "response_bytes",
        "state",
        "token_estimate",
        "tool_name",
        "trigger",
    ]

    static func modelIdentifierHash(_ modelIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(modelIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func boundedIdentifier(_ value: String, fallbackPrefix: String) -> String {
        let scalars = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars)).prefix(160)
        return bounded.isEmpty
            ? "\(fallbackPrefix)_\(UUID().uuidString.lowercased())"
            : String(bounded)
    }

    static func boundedReasonCode(_ value: String) -> String {
        let lowercased = value.lowercased()
        let scalars = lowercased.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars)).prefix(120)
        return bounded.isEmpty ? "ollama_chat_unspecified" : String(bounded)
    }

    static func boundedComponent(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars)).prefix(80)
        return bounded.isEmpty ? "ollama_chat" : String(bounded)
    }

    static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            let normalizedKey = key.lowercased()
            guard allowedMetadataKeys.contains(normalizedKey), result.count < 16 else {
                continue
            }
            let scalars = value.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }
            result[normalizedKey] = String(String.UnicodeScalarView(scalars).prefix(160))
        }
        return result
    }
}

enum OllamaChatProductionTraceLogger {
    private static let logger = Logger(
        subsystem: "com.agentloki.LokiBrief",
        category: "agent-loki-chat"
    )

    static func emit(_ event: OllamaChatTraceEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        logger.info("\(line, privacy: .public)")
    }
}
