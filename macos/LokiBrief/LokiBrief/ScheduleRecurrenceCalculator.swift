import Foundation

enum ScheduleCalculationFailure: Error, Equatable, Sendable {
    case disabled
    case noSelectedWeekdays
    case invalidTimeZone(String)
    case unableToResolveDate
}

struct ScheduleRecurrenceCalculator: Sendable {
    private let systemCalendar: @Sendable () -> Calendar
    private let systemTimeZone: @Sendable () -> TimeZone

    init(
        systemCalendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        systemTimeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.systemCalendar = systemCalendar
        self.systemTimeZone = systemTimeZone
    }

    func resolvedTimeZone(for schedule: BriefSchedule) throws -> TimeZone {
        if schedule.followsSystemTimeZone { return systemTimeZone() }
        guard let identifier = schedule.persistedTimeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier)
        else {
            throw ScheduleCalculationFailure.invalidTimeZone(schedule.persistedTimeZoneIdentifier ?? "missing")
        }
        return timeZone
    }

    func nextOccurrence(after date: Date, schedule: BriefSchedule) throws -> ScheduleOccurrence? {
        guard schedule.enabled else { throw ScheduleCalculationFailure.disabled }
        guard !schedule.recurrence.selectedWeekdays.isEmpty else {
            throw ScheduleCalculationFailure.noSelectedWeekdays
        }
        let timeZone = try resolvedTimeZone(for: schedule)
        var calendar = systemCalendar()
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)

        for dayOffset in 0..<15 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: start) else { continue }
            guard isSelected(candidateDay, schedule: schedule, calendar: calendar) else { continue }
            let occurrence = try occurrence(onLocalDayContaining: candidateDay, schedule: schedule, calendar: calendar)
            if occurrence.resolvedExecutionDate > date { return occurrence }
        }
        return nil
    }

    func mostRecentOccurrence(onOrBefore date: Date, schedule: BriefSchedule) throws -> ScheduleOccurrence? {
        guard schedule.enabled else { throw ScheduleCalculationFailure.disabled }
        guard !schedule.recurrence.selectedWeekdays.isEmpty else {
            throw ScheduleCalculationFailure.noSelectedWeekdays
        }
        let timeZone = try resolvedTimeZone(for: schedule)
        var calendar = systemCalendar()
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)

        for dayOffset in 0..<15 {
            guard let candidateDay = calendar.date(byAdding: .day, value: -dayOffset, to: start) else { continue }
            guard isSelected(candidateDay, schedule: schedule, calendar: calendar) else { continue }
            let occurrence = try occurrence(onLocalDayContaining: candidateDay, schedule: schedule, calendar: calendar)
            if occurrence.resolvedExecutionDate <= date { return occurrence }
        }
        return nil
    }

    func catchUpDecision(
        for occurrence: ScheduleOccurrence,
        schedule: BriefSchedule,
        now: Date
    ) -> ScheduleCatchUpDecision {
        guard schedule.enabled else {
            return .init(action: .skip, reasonCode: "schedule_disabled")
        }
        guard occurrence.resolvedExecutionDate <= now else {
            return .init(action: .none, reasonCode: "occurrence_not_due")
        }
        let age = now.timeIntervalSince(occurrence.resolvedExecutionDate)
        switch schedule.missedRunPolicy {
        case .skip:
            return .init(action: .skip, reasonCode: "missed_policy_skip")
        case .runWithinGraceWindow:
            return age <= schedule.catchUpWindow.maximumAge
                ? .init(action: .run, reasonCode: "catch_up_within_grace_window")
                : .init(action: .skip, reasonCode: "catch_up_grace_window_expired")
        case .runWhenAppReturns:
            return .init(action: .run, reasonCode: "catch_up_app_returned")
        }
    }

    private func isSelected(_ date: Date, schedule: BriefSchedule, calendar: Calendar) -> Bool {
        guard let weekday = ScheduleWeekday(rawValue: calendar.component(.weekday, from: date)) else { return false }
        return schedule.recurrence.selectedWeekdays.contains(weekday)
    }

    private func occurrence(
        onLocalDayContaining day: Date,
        schedule: BriefSchedule,
        calendar: Calendar
    ) throws -> ScheduleOccurrence {
        guard let firstResolution = calendar.date(
            bySettingHour: schedule.localTime.hour,
            minute: schedule.localTime.minute,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else { throw ScheduleCalculationFailure.unableToResolveDate }

        let intendedComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let resolvedComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: firstResolution)
        guard resolvedComponents.year == intendedComponents.year,
              resolvedComponents.month == intendedComponents.month,
              resolvedComponents.day == intendedComponents.day
        else { throw ScheduleCalculationFailure.unableToResolveDate }

        let lastResolution = calendar.date(
            bySettingHour: schedule.localTime.hour,
            minute: schedule.localTime.minute,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .last,
            direction: .forward
        )
        let repeated = lastResolution.map { $0 != firstResolution } ?? false
        let adjusted = resolvedComponents.hour != schedule.localTime.hour
            || resolvedComponents.minute != schedule.localTime.minute
        let localDate = LocalCalendarDay(
            year: intendedComponents.year ?? 1970,
            month: intendedComponents.month ?? 1,
            day: intendedComponents.day ?? 1
        ).storageValue
        let canonicalSlot = [
            schedule.id,
            localDate,
            String(format: "%02d:%02d", schedule.localTime.hour, schedule.localTime.minute),
            "v\(schedule.recurrenceVersion)",
        ].joined(separator: "|")
        let canonicalOccurrence = canonicalSlot + "|" + calendar.timeZone.identifier

        return ScheduleOccurrence(
            key: SchedulePrivacy.occurrenceKey(canonicalValue: canonicalOccurrence),
            slotKey: SchedulePrivacy.slotKey(canonicalValue: canonicalSlot),
            scheduleID: schedule.id,
            intendedLocalDate: localDate,
            intendedLocalTime: schedule.localTime,
            resolvedTimeZoneIdentifier: calendar.timeZone.identifier,
            recurrenceVersion: schedule.recurrenceVersion,
            resolvedExecutionDate: firstResolution,
            resolvedAfterDSTGap: adjusted,
            repeatedLocalTime: repeated
        )
    }
}
