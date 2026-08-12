import Foundation
import OSLog

public enum UpdateTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

public enum UpdateTraceEventName: String, Codable, CaseIterable, Sendable {
    case check = "update_check"
    case feedResolution = "update_feed_resolution"
    case feedValidation = "update_feed_validation"
    case availability = "update_availability"
    case download = "update_download"
    case signatureValidation = "update_signature_validation"
    case installReadiness = "update_install_readiness"
    case storeClose = "update_store_close"
    case install = "update_install"
    case relaunch = "update_relaunch"
    case recovery = "update_recovery"
    case stateTransition = "update_state_transition"
    case policy = "update_policy"
}

public enum UpdateTraceMetadataKey: String, Codable, CaseIterable, Sendable {
    case channel
    case checkTrigger = "check_trigger"
    case currentVersion = "current_version"
    case currentBuild = "current_build"
    case candidateVersion = "candidate_version"
    case candidateBuild = "candidate_build"
    case progressBasisPoints = "progress_basis_points"
    case byteCount = "byte_count"
    case blockerCount = "blocker_count"
    case retryable
    case automatic
    case signatureAlgorithm = "signature_algorithm"
    case receiptStatus = "receipt_status"
    case transitionFrom = "transition_from"
    case transitionTo = "transition_to"
    case route
}

public struct UpdateTraceMetadata: Codable, Equatable, Sendable {
    public static let maximumEntries = 16
    public static let maximumValueCharacters = 160

    public private(set) var values: [String: String]

    public init(_ entries: [UpdateTraceMetadataKey: String] = [:]) {
        var normalized: [String: String] = [:]
        for key in entries.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(Self.maximumEntries) {
            guard let value = entries[key] else { continue }
            normalized[key.rawValue] = UpdateTraceText.metadataValue(value, for: key)
        }
        self.values = normalized
    }

    public subscript(_ key: UpdateTraceMetadataKey) -> String? {
        values[key.rawValue]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UpdateTraceCodingKey.self)
        var decodedEntries: [UpdateTraceMetadataKey: String] = [:]
        for codingKey in container.allKeys.prefix(Self.maximumEntries) {
            guard let key = UpdateTraceMetadataKey(rawValue: codingKey.stringValue) else { continue }
            decodedEntries[key] = try container.decode(String.self, forKey: codingKey)
        }
        self.init(decodedEntries)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: UpdateTraceCodingKey.self)
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: UpdateTraceCodingKey(key))
        }
    }
}

public struct UpdateTraceContext: Codable, Equatable, Sendable {
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?

    public init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = UpdateTraceText.identifier(traceID) ?? UUID().uuidString.lowercased()
        self.spanID = UpdateTraceText.identifier(spanID) ?? UUID().uuidString.lowercased()
        self.parentSpanID = parentSpanID.flatMap(UpdateTraceText.identifier)
    }

    public func child(spanID: String = UUID().uuidString.lowercased()) -> UpdateTraceContext {
        UpdateTraceContext(traceID: traceID, spanID: spanID, parentSpanID: self.spanID)
    }
}

public struct UpdateTraceEvent: Codable, Equatable, Sendable {
    public let ts: Date
    public let event: UpdateTraceEventName
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let component: String
    public let status: UpdateTraceStatus
    public let reasonCode: String
    public let durationMS: Int?
    public let metadata: UpdateTraceMetadata

    public init(
        ts: Date = Date(),
        event: UpdateTraceEventName,
        context: UpdateTraceContext,
        status: UpdateTraceStatus,
        reasonCode: String,
        durationMS: Int? = nil,
        metadata: UpdateTraceMetadata = UpdateTraceMetadata()
    ) {
        self.ts = ts
        self.event = event
        self.traceID = context.traceID
        self.spanID = context.spanID
        self.parentSpanID = context.parentSpanID
        self.component = "secure_update"
        self.status = status
        self.reasonCode = UpdateDomainText.reasonCode(reasonCode)
        self.durationMS = durationMS.map { max(0, $0) }
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case ts
        case event
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case component
        case status
        case reasonCode = "reason_code"
        case durationMS = "duration_ms"
        case metadata
    }
}

public enum UpdateTraceEncodingError: Error, Equatable, Sendable {
    case eventTooLarge
}

public struct UpdateProductionTraceLogger: Sendable {
    public static let maximumEncodedBytes = 8_192

    private let logger: Logger
    private let eventSink: @Sendable (UpdateTraceEvent) -> Void

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.agentloki.LokiBrief",
        category: String = "secure_update",
        eventSink: @escaping @Sendable (UpdateTraceEvent) -> Void = { _ in }
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.eventSink = eventSink
    }

    public func encodedLine(for event: UpdateTraceEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard data.count <= Self.maximumEncodedBytes else {
            throw UpdateTraceEncodingError.eventTooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func emit(_ event: UpdateTraceEvent) {
        eventSink(event)
        do {
            let line = try encodedLine(for: event)
            logger.log(level: logLevel(for: event.status), "\(line, privacy: .public)")
        } catch {
            logger.error("secure update trace encoding failed reason_code=update_trace_encoding_failed")
        }
    }

    private func logLevel(for status: UpdateTraceStatus) -> OSLogType {
        switch status {
        case .started, .success, .skipped:
            return .info
        case .degraded:
            return .default
        case .failed:
            return .error
        }
    }
}

private struct UpdateTraceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private enum UpdateTraceText {
    private static let sensitiveMarkers = [
        "http://", "https://", "file://", "%3a%2f%2f", "authorization", "bearer ",
        "access_token", "auth_token", "private_token", "token", "password", "secret",
        "private key", "private_key", "github_pat_", "ghp_", "xoxb-", "xoxe-"
    ]

    static func identifier(_ value: String) -> String? {
        let bounded = UpdateDomainText.bounded(value, limit: 96, fallback: "")
        guard !bounded.isEmpty, !containsSensitiveMaterial(bounded) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard bounded.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return bounded
    }

    static func metadataValue(_ value: String, for key: UpdateTraceMetadataKey) -> String {
        let bounded = UpdateDomainText.bounded(
            value,
            limit: UpdateTraceMetadata.maximumValueCharacters,
            fallback: "unknown"
        )
        guard !containsSensitiveMaterial(bounded) else {
            return "[redacted]"
        }

        switch key {
        case .channel:
            return UpdateChannel(rawValue: bounded) == nil ? "unknown" : bounded
        case .checkTrigger:
            return UpdateCheckTrigger(rawValue: bounded) == nil ? "unknown" : bounded
        case .currentVersion, .currentBuild, .candidateVersion, .candidateBuild:
            return bounded
        case .progressBasisPoints:
            guard let number = Int(bounded), (0...10_000).contains(number) else { return "unknown" }
            return String(number)
        case .byteCount, .blockerCount:
            guard bounded.count <= 20, bounded.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return "unknown"
            }
            return String(bounded.drop(while: { $0 == "0" })).isEmpty ? "0" : String(bounded.drop(while: { $0 == "0" }))
        case .retryable, .automatic:
            return (bounded == "true" || bounded == "false") ? bounded : "unknown"
        case .signatureAlgorithm:
            return UpdateSignatureAlgorithm(rawValue: bounded) == nil ? "unknown" : bounded
        case .receiptStatus:
            return UpdateReceiptStatus(rawValue: bounded) == nil ? "unknown" : bounded
        case .transitionFrom, .transitionTo:
            return UpdateStateKind(rawValue: bounded) == nil ? "unknown" : bounded
        case .route:
            return stableAtom(bounded) ?? "unknown"
        }
    }

    private static func stableAtom(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard value == value.lowercased(), value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }

    private static func containsSensitiveMaterial(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return sensitiveMarkers.contains(where: lowercased.contains)
    }
}
