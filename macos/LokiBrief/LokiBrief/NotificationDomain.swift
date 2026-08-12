import CryptoKit
import Foundation

enum NotificationAuthorizationState: String, Codable, CaseIterable, Hashable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case authorized
    case provisional
    case ephemeral
    case unsupported
    case error

    var permitsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied, .unsupported, .error: false
        }
    }
}

enum NotificationPrivacyMode: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case minimal
    case summary

    var id: String { rawValue }
}

enum NotificationAuthorizationRequestReason: String, Sendable {
    case explicitUserEnable = "explicit_user_enable"
}

enum NotificationEligibleRunResult: String, Codable, Sendable {
    case completed
    case partiallyCompleted = "partially_completed"
    case canceled
    case skipped
    case failed
    case configurationRequired = "configuration_required"

    var canNotify: Bool {
        self == .completed || self == .partiallyCompleted
    }
}

enum NotificationDeliveryReservation: String, Sendable {
    /// The persistence layer atomically reserved this occurrence before delivery began.
    case reserved
    case alreadySubmitted = "already_submitted"
    case suppressed
}

enum NotificationDeliveryOutcome: String, Codable, Sendable {
    case notRequested = "not_requested"
    case authorizationDenied = "authorization_denied"
    case authorizationNotDetermined = "authorization_not_determined"
    case unsupported
    case ineligibleRun = "ineligible_run"
    case duplicateSuppressed = "duplicate_suppressed"
    case submitted
    case addFailed = "add_failed"
    case removed
}

struct NotificationDeliveryInput: Equatable, Sendable {
    let occurrenceKey: String
    let briefID: String
    let runResult: NotificationEligibleRunResult
    let hasUsableBrief: Bool
    let itemCount: Int
    let sourceCount: Int
    let privacyMode: NotificationPrivacyMode
    let briefingDay: LocalCalendarDay

    init(
        occurrenceKey: String,
        briefID: String,
        runResult: NotificationEligibleRunResult,
        hasUsableBrief: Bool,
        itemCount: Int,
        sourceCount: Int,
        privacyMode: NotificationPrivacyMode,
        briefingDay: LocalCalendarDay = LocalCalendarDay.resolve(containing: .now)
    ) {
        self.occurrenceKey = occurrenceKey
        self.briefID = briefID
        self.runResult = runResult
        self.hasUsableBrief = hasUsableBrief
        self.itemCount = max(0, itemCount)
        self.sourceCount = max(0, sourceCount)
        self.privacyMode = privacyMode
        self.briefingDay = briefingDay
    }

    var isEligible: Bool { runResult.canNotify && hasUsableBrief }
}

struct NotificationSubmission: Equatable, Sendable {
    let identifier: String
    let categoryIdentifier: String
    let title: String
    let body: String
    let userInfo: [String: String]
}

struct NotificationRoute: Equatable, Sendable {
    let notificationIdentifier: String
    let briefID: String
}

enum LokiNotificationContract {
    static let categoryIdentifier = "LOKI_BRIEF_READY"
    static let identifierPrefix = "lokibrief.daily."
    static let payloadVersion = "2"
    static let supportedPayloadVersions: Set<String> = ["1", payloadVersion]
    static let maximumIdentifierLength = 512
    static let maximumBriefIdentifierLength = 512
    static let maximumQueuedRoutes = 16

    enum UserInfoKey {
        static let briefID = "brief_id"
        static let briefingDay = "briefing_day"
        static let version = "notification_version"
    }

    static func stableIdentifier(occurrenceKey: String) -> String {
        identifierPrefix + SHA256.hash(data: Data(occurrenceKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func content(for input: NotificationDeliveryInput) -> NotificationSubmission {
        let title = "Loki Brief · \(input.briefingDay.storageValue)"
        let dayLabel = input.briefingDay.formatted(.abbreviated)
        let body: String
        switch input.privacyMode {
        case .minimal:
            body = "Your \(dayLabel) brief is ready."
        case .summary:
            body = "\(dayLabel): \(input.itemCount) \(input.itemCount == 1 ? "item" : "items") from \(input.sourceCount) \(input.sourceCount == 1 ? "source" : "sources")"
        }
        return NotificationSubmission(
            identifier: stableIdentifier(occurrenceKey: input.occurrenceKey),
            categoryIdentifier: categoryIdentifier,
            title: title,
            body: body,
            userInfo: [
                UserInfoKey.briefID: input.briefID,
                UserInfoKey.briefingDay: input.briefingDay.storageValue,
                UserInfoKey.version: payloadVersion,
            ]
        )
    }

    static func validBriefIdentifier(_ value: String) -> Bool {
        let length = value.lengthOfBytes(using: .utf8)
        return length > 0
            && length <= maximumBriefIdentifierLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func validNotificationIdentifier(_ value: String) -> Bool {
        value.hasPrefix(identifierPrefix)
            && value.lengthOfBytes(using: .utf8) <= maximumIdentifierLength
            && value.dropFirst(identifierPrefix.count).count == 64
            && value.dropFirst(identifierPrefix.count).allSatisfy { $0.isHexDigit }
    }
}

enum NotificationPrivacySanitizer {
    static func reasonCode(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let bounded = String(value.prefix(120))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard bounded.unicodeScalars.allSatisfy(allowed.contains) else { return "invalid_reason_code" }
        return bounded
    }
}

struct NotificationTraceEvent: Equatable, Sendable {
    enum Status: String, Sendable {
        case started
        case success
        case degraded
        case failed
        case skipped
    }

    let event: String
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: Status
    let reasonCode: String
    let durationMilliseconds: Int?
    let notificationIdentifier: String?
    let itemCount: Int?
    let sourceCount: Int?

    init(
        event: String,
        traceID: String,
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil,
        status: Status,
        reasonCode: String,
        durationMilliseconds: Int? = nil,
        notificationIdentifier: String? = nil,
        itemCount: Int? = nil,
        sourceCount: Int? = nil
    ) {
        self.event = event
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.component = "notification_delivery"
        self.status = status
        self.reasonCode = NotificationPrivacySanitizer.reasonCode(reasonCode) ?? "missing_reason_code"
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.notificationIdentifier = notificationIdentifier
        self.itemCount = itemCount.map { max(0, $0) }
        self.sourceCount = sourceCount.map { max(0, $0) }
    }
}

typealias NotificationTraceSink = @Sendable (NotificationTraceEvent) -> Void
