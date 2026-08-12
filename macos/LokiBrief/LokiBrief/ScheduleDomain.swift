import CryptoKit
import Foundation

enum ScheduleWeekday: Int, Codable, CaseIterable, Hashable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
}

struct ScheduleLocalTime: Codable, Equatable, Hashable, Sendable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    static let eightAM = ScheduleLocalTime(hour: 8, minute: 0)
}

enum ScheduleRecurrence: Codable, Equatable, Hashable, Sendable {
    case daily(selectedWeekdays: Set<ScheduleWeekday>)

    var selectedWeekdays: Set<ScheduleWeekday> {
        switch self {
        case let .daily(selectedWeekdays): selectedWeekdays
        }
    }

    static let everyDay = ScheduleRecurrence.daily(selectedWeekdays: Set(ScheduleWeekday.allCases))
}

enum MissedRunPolicy: String, Codable, CaseIterable, Sendable {
    case skip
    case runWhenAppReturns
    case runWithinGraceWindow
}

struct CatchUpWindow: Codable, Equatable, Hashable, Sendable {
    static let defaultMaximumAge: TimeInterval = 6 * 60 * 60
    static let absoluteMaximumAge: TimeInterval = 7 * 24 * 60 * 60

    let maximumAge: TimeInterval

    init(maximumAge: TimeInterval = CatchUpWindow.defaultMaximumAge) {
        self.maximumAge = min(max(maximumAge, 60), CatchUpWindow.absoluteMaximumAge)
    }
}

enum ScheduleNotificationPrivacy: String, Codable, CaseIterable, Sendable {
    case minimal
    case summary
}

struct ScheduledDeliverySettings: Codable, Equatable, Sendable {
    var refreshFeeds: Bool
    var refreshSelectedSlackWorkspaces: Bool
    var allowScheduledOllama: Bool
    var notificationsEnabled: Bool
    var notificationPrivacy: ScheduleNotificationPrivacy
    var pauseInLowPowerMode: Bool

    static let `default` = ScheduledDeliverySettings(
        refreshFeeds: true,
        refreshSelectedSlackWorkspaces: true,
        allowScheduledOllama: false,
        notificationsEnabled: false,
        notificationPrivacy: .minimal,
        pauseInLowPowerMode: true
    )
}

struct BriefSchedule: Codable, Equatable, Identifiable, Sendable {
    static let primaryID = "primary-daily-brief"

    let id: String
    var enabled: Bool
    var localTime: ScheduleLocalTime
    var recurrence: ScheduleRecurrence
    var followsSystemTimeZone: Bool
    var persistedTimeZoneIdentifier: String?
    var missedRunPolicy: MissedRunPolicy
    var catchUpWindow: CatchUpWindow
    var selectedAccountIDs: Set<String>
    var delivery: ScheduledDeliverySettings
    var recurrenceVersion: Int

    init(
        id: String = BriefSchedule.primaryID,
        enabled: Bool = false,
        localTime: ScheduleLocalTime = .eightAM,
        recurrence: ScheduleRecurrence = .everyDay,
        followsSystemTimeZone: Bool = true,
        persistedTimeZoneIdentifier: String? = nil,
        missedRunPolicy: MissedRunPolicy = .runWithinGraceWindow,
        catchUpWindow: CatchUpWindow = .init(),
        selectedAccountIDs: Set<String> = [],
        delivery: ScheduledDeliverySettings = .default,
        recurrenceVersion: Int = 1
    ) {
        self.id = SchedulePrivacy.boundedIdentifier(id, fallback: BriefSchedule.primaryID)
        self.enabled = enabled
        self.localTime = localTime
        self.recurrence = recurrence
        self.followsSystemTimeZone = followsSystemTimeZone
        self.persistedTimeZoneIdentifier = persistedTimeZoneIdentifier.map {
            SchedulePrivacy.boundedIdentifier($0, fallback: "UTC")
        }
        self.missedRunPolicy = missedRunPolicy
        self.catchUpWindow = catchUpWindow
        self.selectedAccountIDs = Set(selectedAccountIDs.sorted().prefix(256).map {
            SchedulePrivacy.boundedIdentifier($0, fallback: "invalid-account")
        })
        self.delivery = delivery
        self.recurrenceVersion = max(recurrenceVersion, 1)
    }
}

struct ScheduleOccurrenceKey: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = SchedulePrivacy.boundedIdentifier(rawValue, fallback: "invalid-occurrence")
    }
}

struct ScheduleSlotKey: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = SchedulePrivacy.boundedIdentifier(rawValue, fallback: "invalid-slot")
    }
}

struct ScheduleOccurrence: Codable, Equatable, Identifiable, Sendable {
    var id: String { key.rawValue }

    let key: ScheduleOccurrenceKey
    let slotKey: ScheduleSlotKey
    let scheduleID: String
    let intendedLocalDate: String
    let intendedLocalTime: ScheduleLocalTime
    let resolvedTimeZoneIdentifier: String
    let recurrenceVersion: Int
    let resolvedExecutionDate: Date
    let resolvedAfterDSTGap: Bool
    let repeatedLocalTime: Bool

    var briefingDay: LocalCalendarDay {
        if let persisted = LocalCalendarDay(storageValue: intendedLocalDate) { return persisted }
        let timeZone = TimeZone(identifier: resolvedTimeZoneIdentifier) ?? .autoupdatingCurrent
        return LocalCalendarDay.resolve(
            containing: resolvedExecutionDate,
            calendar: .autoupdatingCurrent,
            timeZone: timeZone
        )
    }
}

enum ScheduleOccurrenceState: String, Codable, CaseIterable, Sendable {
    case pending
    case claimed
    case succeeded
    case skipped
    case canceled
    case failed
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .skipped, .canceled, .failed: true
        case .pending, .claimed, .interrupted: false
        }
    }
}

enum BriefScheduleState: String, Codable, Equatable, Sendable {
    case stopped
    case disabled
    case waiting
    case firing
    case pausedForSleep = "paused_for_sleep"
    case pausedForInactiveSession = "paused_for_inactive_session"
    case deferredForLowPower = "deferred_for_low_power"
    case failed
}

enum ScheduleActivationTrigger: String, Codable, CaseIterable, Sendable {
    case scheduled
    case catchUpAfterWake
    case catchUpAfterLaunch
    case settingsChanged
    case systemClockChanged
    case systemTimeZoneChanged
    case lowPowerEnded
    case userSessionReturned
    case manualTest
    case manualRunNow
    case retry
}

struct ScheduleFiringContext: Codable, Equatable, Sendable {
    let occurrence: ScheduleOccurrence
    let trigger: ScheduleActivationTrigger
    let schedulerEpoch: UInt64
}

enum ScheduleCatchUpAction: String, Codable, Sendable {
    case run
    case skip
    case none
}

struct ScheduleCatchUpDecision: Codable, Equatable, Sendable {
    let action: ScheduleCatchUpAction
    let reasonCode: String
}

enum ScheduleClaimDisposition: String, Codable, Sendable {
    case claimed
    case alreadyClaimed
    case alreadySucceeded
    case terminal
}

enum ScheduleTraceStatus: String, Codable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum ScheduleTraceEventName: String, Codable, Sendable {
    case schedulerStart = "schedule.scheduler_start"
    case schedulerStop = "schedule.scheduler_stop"
    case nextOccurrence = "schedule.next_occurrence"
    case catchUpDecision = "schedule.catch_up_decision"
    case occurrenceClaim = "schedule.occurrence_claim"
    case occurrenceFire = "schedule.occurrence_fire"
    case lifecycleReconcile = "schedule.lifecycle_reconcile"
    case lowPowerDeferral = "schedule.low_power_deferral"
    case launchAtLogin = "schedule.launch_at_login"
}

struct ScheduleTraceEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: ScheduleTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: ScheduleTraceStatus
    let reasonCode: String
    let occurrenceHash: String?
    let boundedCount: Int?
}

typealias ScheduleTraceSink = @Sendable (ScheduleTraceEvent) -> Void

enum SchedulePrivacy {
    static func hashIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedIdentifier(_ value: String, fallback: String) -> String {
        let sanitized = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let bounded = String(String.UnicodeScalarView(sanitized).prefix(256))
        return bounded.isEmpty ? fallback : bounded
    }

    static func occurrenceKey(canonicalValue: String) -> ScheduleOccurrenceKey {
        ScheduleOccurrenceKey(rawValue: "occurrence-\(hashIdentifier(canonicalValue))")
    }

    static func slotKey(canonicalValue: String) -> ScheduleSlotKey {
        ScheduleSlotKey(rawValue: "slot-\(hashIdentifier(canonicalValue))")
    }
}
