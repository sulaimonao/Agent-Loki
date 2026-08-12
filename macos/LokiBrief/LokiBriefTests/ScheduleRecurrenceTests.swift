import XCTest
@testable import LokiBrief

final class ScheduleRecurrenceTests: XCTestCase, @unchecked Sendable {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    func testNextDailyOccurrenceUsesLocalCalendarTime() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 8, minute: 15),
            followsSystemTimeZone: true
        )
        let occurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 7, 16, 7, 0, timeZone: losAngeles),
            schedule: schedule
        ))

        XCTAssertEqual(occurrence.intendedLocalDate, "2026-07-16")
        XCTAssertEqual(occurrence.intendedLocalTime, .init(hour: 8, minute: 15))
        XCTAssertEqual(occurrence.resolvedExecutionDate, date(2026, 7, 16, 8, 15, timeZone: losAngeles))
    }

    func testSelectedWeekdaysSkipUnselectedDays() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 8, minute: 0),
            recurrence: .daily(selectedWeekdays: [.monday]),
            followsSystemTimeZone: true
        )
        let occurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 7, 16, 9, 0, timeZone: losAngeles),
            schedule: schedule
        ))
        XCTAssertEqual(occurrence.intendedLocalDate, "2026-07-20")
    }

    func testDisabledScheduleDoesNotCalculate() {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        XCTAssertThrowsError(try calculator.nextOccurrence(after: .now, schedule: BriefSchedule())) { error in
            XCTAssertEqual(error as? ScheduleCalculationFailure, .disabled)
        }
    }

    func testSpringForwardNonexistentTimeUsesNextValidTimeOnIntendedDay() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 2, minute: 30),
            followsSystemTimeZone: true
        )
        let occurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 3, 8, 0, 0, timeZone: losAngeles),
            schedule: schedule
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence.resolvedExecutionDate)

        XCTAssertEqual(occurrence.intendedLocalDate, "2026-03-08")
        XCTAssertEqual(resolved.year, 2026)
        XCTAssertEqual(resolved.month, 3)
        XCTAssertEqual(resolved.day, 8)
        XCTAssertEqual(resolved.hour, 3)
        XCTAssertEqual(resolved.minute, 0)
        XCTAssertTrue(occurrence.resolvedAfterDSTGap)
    }

    func testFallBackRepeatedTimeUsesFirstInstantAndStableSlot() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 1, minute: 30),
            followsSystemTimeZone: true
        )
        let occurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 11, 1, 0, 0, timeZone: losAngeles),
            schedule: schedule
        ))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        let first = calendar.date(
            bySettingHour: 1,
            minute: 30,
            second: 0,
            of: date(2026, 11, 1, 12, 0, timeZone: losAngeles),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        XCTAssertEqual(occurrence.resolvedExecutionDate, first)
        XCTAssertTrue(occurrence.repeatedLocalTime)
    }

    func testTimeZoneChangeChangesOccurrenceKeyButNotSemanticSlotKey() throws {
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 8, minute: 0))
        let now = Date(timeIntervalSince1970: 1_768_406_400)
        let pacific = try XCTUnwrap(ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles }).nextOccurrence(after: now, schedule: schedule))
        let easternZone = TimeZone(identifier: "America/New_York")!
        let eastern = try XCTUnwrap(ScheduleRecurrenceCalculator(systemTimeZone: { easternZone }).nextOccurrence(after: now, schedule: schedule))

        XCTAssertNotEqual(pacific.key, eastern.key)
        XCTAssertEqual(pacific.slotKey, eastern.slotKey)
    }

    func testOccurrenceKeysAreDeterministic() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let schedule = BriefSchedule(enabled: true)
        let now = date(2026, 7, 16, 7, 0, timeZone: losAngeles)
        XCTAssertEqual(
            try calculator.nextOccurrence(after: now, schedule: schedule),
            try calculator.nextOccurrence(after: now, schedule: schedule)
        )
    }

    func testCatchUpPolicyHonorsGraceWindowAndSkip() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        let base = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 6, minute: 0),
            catchUpWindow: .init(maximumAge: 6 * 60 * 60)
        )
        let scheduled = date(2026, 7, 16, 6, 0, timeZone: losAngeles)
        let occurrence = try XCTUnwrap(calculator.mostRecentOccurrence(onOrBefore: scheduled, schedule: base))
        XCTAssertEqual(
            calculator.catchUpDecision(for: occurrence, schedule: base, now: scheduled.addingTimeInterval(70 * 60)).action,
            .run
        )
        XCTAssertEqual(
            calculator.catchUpDecision(for: occurrence, schedule: base, now: scheduled.addingTimeInterval(14 * 60 * 60)).reasonCode,
            "catch_up_grace_window_expired"
        )

        var skip = base
        skip.missedRunPolicy = .skip
        XCTAssertEqual(calculator.catchUpDecision(for: occurrence, schedule: skip, now: scheduled).action, .skip)
    }

    func testRunWhenAppReturnsRunsNewestOccurrenceOutsideGraceWindow() throws {
        let calculator = ScheduleRecurrenceCalculator(systemTimeZone: { self.losAngeles })
        var schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 6, minute: 0),
            catchUpWindow: .init(maximumAge: 60 * 60)
        )
        schedule.missedRunPolicy = .runWhenAppReturns
        let scheduled = date(2026, 7, 16, 6, 0, timeZone: losAngeles)
        let occurrence = try XCTUnwrap(calculator.mostRecentOccurrence(onOrBefore: scheduled, schedule: schedule))

        let decision = calculator.catchUpDecision(
            for: occurrence,
            schedule: schedule,
            now: scheduled.addingTimeInterval(14 * 60 * 60)
        )

        XCTAssertEqual(decision.action, .run)
        XCTAssertEqual(decision.reasonCode, "catch_up_app_returned")
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
