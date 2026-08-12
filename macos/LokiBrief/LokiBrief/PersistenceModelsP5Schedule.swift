import Foundation
import SwiftData

@Model final class StoredBriefSchedule {
    @Attribute(.unique) var id: String
    var enabled: Bool
    var localHour: Int
    var localMinute: Int
    var selectedWeekdaysData: Data
    var followsSystemTimeZone: Bool
    var persistedTimeZoneIdentifier: String?
    var missedRunPolicyRaw: String
    var maximumCatchUpAgeSeconds: Double
    var selectedAccountIDsData: Data
    var refreshFeeds: Bool
    var refreshSelectedSlackWorkspaces: Bool
    var allowScheduledOllama: Bool
    var notificationsEnabled: Bool
    var notificationPrivacyRaw: String
    var pauseInLowPowerMode: Bool
    var recurrenceVersion: Int
    var updatedAt: Date

    init(schedule: BriefSchedule, updatedAt: Date = .now) throws {
        self.id = schedule.id
        self.enabled = schedule.enabled
        self.localHour = schedule.localTime.hour
        self.localMinute = schedule.localTime.minute
        self.selectedWeekdaysData = try Self.encode(schedule.recurrence.selectedWeekdays.map(\.rawValue).sorted())
        self.followsSystemTimeZone = schedule.followsSystemTimeZone
        self.persistedTimeZoneIdentifier = schedule.persistedTimeZoneIdentifier
        self.missedRunPolicyRaw = schedule.missedRunPolicy.rawValue
        self.maximumCatchUpAgeSeconds = schedule.catchUpWindow.maximumAge
        self.selectedAccountIDsData = try Self.encode(schedule.selectedAccountIDs.sorted())
        self.refreshFeeds = schedule.delivery.refreshFeeds
        self.refreshSelectedSlackWorkspaces = schedule.delivery.refreshSelectedSlackWorkspaces
        self.allowScheduledOllama = schedule.delivery.allowScheduledOllama
        self.notificationsEnabled = schedule.delivery.notificationsEnabled
        self.notificationPrivacyRaw = schedule.delivery.notificationPrivacy.rawValue
        self.pauseInLowPowerMode = schedule.delivery.pauseInLowPowerMode
        self.recurrenceVersion = schedule.recurrenceVersion
        self.updatedAt = updatedAt
    }

    func update(from schedule: BriefSchedule, updatedAt: Date) throws {
        enabled = schedule.enabled
        localHour = schedule.localTime.hour
        localMinute = schedule.localTime.minute
        selectedWeekdaysData = try Self.encode(schedule.recurrence.selectedWeekdays.map(\.rawValue).sorted())
        followsSystemTimeZone = schedule.followsSystemTimeZone
        persistedTimeZoneIdentifier = schedule.persistedTimeZoneIdentifier
        missedRunPolicyRaw = schedule.missedRunPolicy.rawValue
        maximumCatchUpAgeSeconds = schedule.catchUpWindow.maximumAge
        selectedAccountIDsData = try Self.encode(schedule.selectedAccountIDs.sorted())
        refreshFeeds = schedule.delivery.refreshFeeds
        refreshSelectedSlackWorkspaces = schedule.delivery.refreshSelectedSlackWorkspaces
        allowScheduledOllama = schedule.delivery.allowScheduledOllama
        notificationsEnabled = schedule.delivery.notificationsEnabled
        notificationPrivacyRaw = schedule.delivery.notificationPrivacy.rawValue
        pauseInLowPowerMode = schedule.delivery.pauseInLowPowerMode
        recurrenceVersion = schedule.recurrenceVersion
        self.updatedAt = updatedAt
    }

    func domainSchedule() throws -> BriefSchedule {
        let weekdayValues = try Self.decode([Int].self, from: selectedWeekdaysData)
        let weekdays = Set(weekdayValues.compactMap(ScheduleWeekday.init(rawValue:)))
        let accounts = Set(try Self.decode([String].self, from: selectedAccountIDsData))
        return BriefSchedule(
            id: id,
            enabled: enabled,
            localTime: .init(hour: localHour, minute: localMinute),
            recurrence: .daily(selectedWeekdays: weekdays),
            followsSystemTimeZone: followsSystemTimeZone,
            persistedTimeZoneIdentifier: persistedTimeZoneIdentifier,
            missedRunPolicy: MissedRunPolicy(rawValue: missedRunPolicyRaw) ?? .runWithinGraceWindow,
            catchUpWindow: .init(maximumAge: maximumCatchUpAgeSeconds),
            selectedAccountIDs: accounts,
            delivery: .init(
                refreshFeeds: refreshFeeds,
                refreshSelectedSlackWorkspaces: refreshSelectedSlackWorkspaces,
                allowScheduledOllama: allowScheduledOllama,
                notificationsEnabled: notificationsEnabled,
                notificationPrivacy: ScheduleNotificationPrivacy(rawValue: notificationPrivacyRaw) ?? .minimal,
                pauseInLowPowerMode: pauseInLowPowerMode
            ),
            recurrenceVersion: recurrenceVersion
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

@Model final class StoredScheduleOccurrence {
    @Attribute(.unique) var id: String
    @Attribute(.unique) var slotKey: String
    var scheduleID: String
    var intendedLocalDate: String
    var intendedHour: Int
    var intendedMinute: Int
    var resolvedTimeZoneIdentifier: String
    var recurrenceVersion: Int
    var resolvedExecutionDate: Date
    var resolvedAfterDSTGap: Bool
    var repeatedLocalTime: Bool
    var stateRaw: String
    var activationTriggerRaw: String
    var claimedAt: Date?
    var completedAt: Date?
    var reasonCode: String?
    var updatedAt: Date

    init(
        occurrence: ScheduleOccurrence,
        state: ScheduleOccurrenceState,
        trigger: ScheduleActivationTrigger,
        claimedAt: Date? = nil,
        completedAt: Date? = nil,
        reasonCode: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = occurrence.key.rawValue
        self.slotKey = occurrence.slotKey.rawValue
        self.scheduleID = occurrence.scheduleID
        self.intendedLocalDate = occurrence.intendedLocalDate
        self.intendedHour = occurrence.intendedLocalTime.hour
        self.intendedMinute = occurrence.intendedLocalTime.minute
        self.resolvedTimeZoneIdentifier = occurrence.resolvedTimeZoneIdentifier
        self.recurrenceVersion = occurrence.recurrenceVersion
        self.resolvedExecutionDate = occurrence.resolvedExecutionDate
        self.resolvedAfterDSTGap = occurrence.resolvedAfterDSTGap
        self.repeatedLocalTime = occurrence.repeatedLocalTime
        self.stateRaw = state.rawValue
        self.activationTriggerRaw = trigger.rawValue
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.reasonCode = reasonCode.map { String($0.prefix(120)) }
        self.updatedAt = updatedAt
    }

    var state: ScheduleOccurrenceState {
        ScheduleOccurrenceState(rawValue: stateRaw) ?? .interrupted
    }
}
