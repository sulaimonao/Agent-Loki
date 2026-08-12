import Foundation
import SwiftData

@Model final class StoredNotificationDeliverySettings {
    @Attribute(.unique) var id: String
    var enabledPreference: Bool
    var privacyModeRaw: String
    var lastObservedAuthorizationRaw: String
    var authorizationObservedAt: Date?
    var updatedAt: Date

    init(
        id: String = "primary",
        enabledPreference: Bool = false,
        privacyMode: NotificationPrivacyMode = .minimal,
        lastObservedAuthorization: NotificationAuthorizationState = .notDetermined,
        authorizationObservedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.enabledPreference = enabledPreference
        self.privacyModeRaw = privacyMode.rawValue
        self.lastObservedAuthorizationRaw = lastObservedAuthorization.rawValue
        self.authorizationObservedAt = authorizationObservedAt
        self.updatedAt = updatedAt
    }

    var privacyMode: NotificationPrivacyMode {
        get { NotificationPrivacyMode(rawValue: privacyModeRaw) ?? .minimal }
        set { privacyModeRaw = newValue.rawValue; updatedAt = .now }
    }

    /// Cached UI context only. Callers must query UNUserNotificationCenter before
    /// authorization-sensitive actions.
    var lastObservedAuthorization: NotificationAuthorizationState {
        get { NotificationAuthorizationState(rawValue: lastObservedAuthorizationRaw) ?? .error }
        set {
            lastObservedAuthorizationRaw = newValue.rawValue
            authorizationObservedAt = .now
            updatedAt = .now
        }
    }
}

@Model final class StoredDeliveryRecord {
    @Attribute(.unique) var id: String
    @Attribute(.unique) var notificationIdentifier: String
    var occurrenceIdentifierHash: String
    var briefID: String?
    var outcomeRaw: String
    var authorizationRaw: String
    var privacyModeRaw: String
    var itemCount: Int
    var sourceCount: Int
    var reservedAt: Date
    var submittedAt: Date?
    var responseReceivedAt: Date?
    var removedAt: Date?
    var reasonCode: String?

    init(
        id: String,
        notificationIdentifier: String,
        occurrenceIdentifierHash: String,
        briefID: String?,
        outcome: NotificationDeliveryOutcome = .notRequested,
        authorization: NotificationAuthorizationState,
        privacyMode: NotificationPrivacyMode,
        itemCount: Int,
        sourceCount: Int,
        reservedAt: Date = .now,
        submittedAt: Date? = nil,
        responseReceivedAt: Date? = nil,
        removedAt: Date? = nil,
        reasonCode: String? = nil
    ) {
        self.id = id
        self.notificationIdentifier = notificationIdentifier
        self.occurrenceIdentifierHash = occurrenceIdentifierHash
        self.briefID = briefID
        self.outcomeRaw = outcome.rawValue
        self.authorizationRaw = authorization.rawValue
        self.privacyModeRaw = privacyMode.rawValue
        self.itemCount = max(0, itemCount)
        self.sourceCount = max(0, sourceCount)
        self.reservedAt = reservedAt
        self.submittedAt = submittedAt
        self.responseReceivedAt = responseReceivedAt
        self.removedAt = removedAt
        self.reasonCode = NotificationPrivacySanitizer.reasonCode(reasonCode)
    }

    var outcome: NotificationDeliveryOutcome {
        get { NotificationDeliveryOutcome(rawValue: outcomeRaw) ?? .addFailed }
        set { outcomeRaw = newValue.rawValue }
    }

    var authorization: NotificationAuthorizationState {
        get { NotificationAuthorizationState(rawValue: authorizationRaw) ?? .error }
        set { authorizationRaw = newValue.rawValue }
    }

    var privacyMode: NotificationPrivacyMode {
        get { NotificationPrivacyMode(rawValue: privacyModeRaw) ?? .minimal }
        set { privacyModeRaw = newValue.rawValue }
    }

    func record(
        outcome: NotificationDeliveryOutcome,
        authorization: NotificationAuthorizationState,
        at date: Date = .now,
        reasonCode: String? = nil
    ) {
        self.outcome = outcome
        self.authorization = authorization
        self.reasonCode = NotificationPrivacySanitizer.reasonCode(reasonCode)
        switch outcome {
        case .submitted:
            submittedAt = date
        case .removed:
            removedAt = date
        default:
            break
        }
    }

    func recordResponse(at date: Date = .now) {
        responseReceivedAt = date
    }
}
