import Foundation
import XCTest
@testable import LokiBrief

final class LocalCalendarDayTests: XCTestCase, @unchecked Sendable {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testScreenshotScenarioLosAngelesJuly19At1745RendersJuly19TitleIdentityAndPresentation() {
        let instant = date(2026, 7, 19, 17, 45, timeZone: losAngeles)
        XCTAssertEqual(instant, date(2026, 7, 20, 0, 45, timeZone: utc))

        let calendar = gregorian(timeZone: losAngeles)
        let engine = DeterministicFeedBriefingEngine(
            now: { instant },
            calendar: { calendar },
            timeZone: { self.losAngeles }
        )
        let automatic = engine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default
        ).brief
        let july19 = LocalCalendarDay(year: 2026, month: 7, day: 19)
        let explicitJuly19 = engine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default,
            briefingDay: july19
        ).brief
        let wrongUTCTruncatedDay = engine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default,
            briefingDay: .init(year: 2026, month: 7, day: 20)
        ).brief

        XCTAssertEqual(automatic.resolvedBriefingDay, july19)
        XCTAssertEqual(automatic.title, "Loki Brief · 2026-07-19")
        XCTAssertEqual(automatic.id, explicitJuly19.id)
        XCTAssertNotEqual(automatic.id, wrongUTCTruncatedDay.id)
        XCTAssertEqual(
            automatic.resolvedBriefingDay.formatted(
                .complete,
                locale: Locale(identifier: "en_US_POSIX"),
                calendar: calendar,
                timeZone: losAngeles
            ),
            "Sunday, July 19, 2026"
        )
        let localTimestamp = LocalCalendarTimestamp.resolve(
            instant,
            calendar: calendar,
            timeZone: losAngeles
        )
        XCTAssertEqual(localTimestamp.filenameValue, "20260719-174500000")

        let firstExportName = LocalCalendarExportFilename.make(
            timestamp: localTimestamp,
            uniqueIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000019")!
        )
        let secondExportName = LocalCalendarExportFilename.make(
            timestamp: localTimestamp,
            uniqueIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        )
        XCTAssertEqual(
            firstExportName,
            "loki-vault-20260719-174500000-00000000-0000-0000-0000-000000000019.lokivault"
        )
        XCTAssertNotEqual(firstExportName, secondExportName)
    }

    func testBriefIdentityIsStableAcrossUTCMidnightAndChangesAtLocalMidnight() {
        let beforeUTCMidnight = date(2026, 7, 19, 16, 45, timeZone: losAngeles)
        let afterUTCMidnight = date(2026, 7, 19, 17, 45, timeZone: losAngeles)
        let beforeLocalMidnight = date(2026, 7, 19, 23, 59, timeZone: losAngeles)
        let afterLocalMidnight = date(2026, 7, 20, 0, 1, timeZone: losAngeles)

        XCTAssertEqual(beforeUTCMidnight, date(2026, 7, 19, 23, 45, timeZone: utc))
        XCTAssertEqual(afterUTCMidnight, date(2026, 7, 20, 0, 45, timeZone: utc))

        let first = brief(at: beforeUTCMidnight, timeZone: losAngeles)
        let second = brief(at: afterUTCMidnight, timeZone: losAngeles)
        let finalJuly19 = brief(at: beforeLocalMidnight, timeZone: losAngeles)
        let firstJuly20 = brief(at: afterLocalMidnight, timeZone: losAngeles)

        XCTAssertEqual(first.resolvedBriefingDay, .init(year: 2026, month: 7, day: 19))
        XCTAssertEqual(second.resolvedBriefingDay, first.resolvedBriefingDay)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(finalJuly19.resolvedBriefingDay, first.resolvedBriefingDay)
        XCTAssertNotEqual(finalJuly19.id, firstJuly20.id)
        XCTAssertEqual(firstJuly20.resolvedBriefingDay, .init(year: 2026, month: 7, day: 20))
    }

    func testExtremeOffsetsResolveDifferentCivilDaysFromSameInstant() {
        let instant = date(2026, 7, 20, 11, 30, timeZone: utc)
        let utcMinus12 = TimeZone(secondsFromGMT: -12 * 60 * 60)!
        let utcPlus14 = TimeZone(secondsFromGMT: 14 * 60 * 60)!

        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: instant,
                calendar: gregorian(timeZone: utcMinus12),
                timeZone: utcMinus12
            ),
            .init(year: 2026, month: 7, day: 19)
        )
        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: instant,
                calendar: gregorian(timeZone: utcPlus14),
                timeZone: utcPlus14
            ),
            .init(year: 2026, month: 7, day: 21)
        )
    }

    func testDSTGapAndRepeatResolveToIntendedLocalCalendarDays() throws {
        let calendar = gregorian(timeZone: losAngeles)
        let calculator = ScheduleRecurrenceCalculator(
            systemCalendar: { calendar },
            systemTimeZone: { self.losAngeles }
        )
        let springSchedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 2, minute: 30),
            followsSystemTimeZone: true
        )
        let springOccurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 3, 8, 0, 0, timeZone: losAngeles),
            schedule: springSchedule
        ))
        let springDay = LocalCalendarDay(year: 2026, month: 3, day: 8)

        XCTAssertTrue(springOccurrence.resolvedAfterDSTGap)
        XCTAssertEqual(springOccurrence.briefingDay, springDay)
        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: springOccurrence.resolvedExecutionDate,
                calendar: calendar,
                timeZone: losAngeles
            ),
            springDay
        )

        let fallSchedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 1, minute: 30),
            followsSystemTimeZone: true
        )
        let fallOccurrence = try XCTUnwrap(calculator.nextOccurrence(
            after: date(2026, 11, 1, 0, 0, timeZone: losAngeles),
            schedule: fallSchedule
        ))
        let fallDay = LocalCalendarDay(year: 2026, month: 11, day: 1)

        XCTAssertTrue(fallOccurrence.repeatedLocalTime)
        XCTAssertEqual(fallOccurrence.briefingDay, fallDay)
        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: fallOccurrence.resolvedExecutionDate,
                calendar: calendar,
                timeZone: losAngeles
            ),
            fallDay
        )
        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: fallOccurrence.resolvedExecutionDate.addingTimeInterval(60 * 60),
                calendar: calendar,
                timeZone: losAngeles
            ),
            fallDay
        )
    }

    func testCatchUpPassesOccurrenceDayToEngineInsteadOfCurrentWallClockDay() throws {
        let calendar = gregorian(timeZone: losAngeles)
        let calculator = ScheduleRecurrenceCalculator(
            systemCalendar: { calendar },
            systemTimeZone: { self.losAngeles }
        )
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 23, minute: 45),
            followsSystemTimeZone: true,
            missedRunPolicy: .runWithinGraceWindow,
            catchUpWindow: .init(maximumAge: 6 * 60 * 60)
        )
        let catchUpTime = date(2026, 7, 20, 0, 15, timeZone: losAngeles)
        let occurrence = try XCTUnwrap(calculator.mostRecentOccurrence(
            onOrBefore: catchUpTime,
            schedule: schedule
        ))

        XCTAssertEqual(
            calculator.catchUpDecision(for: occurrence, schedule: schedule, now: catchUpTime).action,
            .run
        )
        XCTAssertEqual(occurrence.briefingDay, .init(year: 2026, month: 7, day: 19))

        let engine = DeterministicFeedBriefingEngine(
            now: { catchUpTime },
            calendar: { calendar },
            timeZone: { self.losAngeles }
        )
        let scheduledBrief = engine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default,
            briefingDay: occurrence.briefingDay
        ).brief
        let wallClockBrief = engine.assemble(
            entries: [],
            subscriptions: [],
            preferences: .default
        ).brief

        XCTAssertEqual(scheduledBrief.resolvedBriefingDay, occurrence.briefingDay)
        XCTAssertEqual(scheduledBrief.title, "Loki Brief · 2026-07-19")
        XCTAssertEqual(wallClockBrief.resolvedBriefingDay, .init(year: 2026, month: 7, day: 20))
        XCTAssertNotEqual(scheduledBrief.id, wallClockBrief.id)
        XCTAssertEqual(scheduledBrief.generation.generatedAt, catchUpTime)
    }

    func testHistoryGroupingUsesExplicitBriefingDayNotAbsoluteTimestamp() {
        let july19 = LocalCalendarDay(year: 2026, month: 7, day: 19)
        let july18 = LocalCalendarDay(year: 2026, month: 7, day: 18)
        let utcJuly20Instant = date(2026, 7, 20, 0, 45, timeZone: utc)
        let entries = [
            historyEntry(id: "july-19-a", generatedAt: utcJuly20Instant, briefingDay: july19),
            historyEntry(id: "july-19-b", generatedAt: utcJuly20Instant.addingTimeInterval(60), briefingDay: july19),
            historyEntry(id: "july-18", generatedAt: utcJuly20Instant.addingTimeInterval(120), briefingDay: july18),
        ]

        XCTAssertEqual(
            LocalCalendarDay.resolve(
                containing: utcJuly20Instant,
                calendar: gregorian(timeZone: utc),
                timeZone: utc
            ),
            .init(year: 2026, month: 7, day: 20)
        )

        let groups = BriefHistoryGrouping.group(entries)
        XCTAssertEqual(groups.map(\.day), [july19, july18])
        XCTAssertEqual(groups[0].entries.map(\.id), ["july-19-a", "july-19-b"])
        XCTAssertEqual(groups[1].entries.map(\.id), ["july-18"])
    }

    func testNotificationContentAndPayloadUseExplicitBriefingDay() {
        let day = LocalCalendarDay(year: 2026, month: 7, day: 19)
        let input = NotificationDeliveryInput(
            occurrenceKey: "local-day-notification-fixture",
            briefID: "local-day-brief",
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: 4,
            sourceCount: 2,
            privacyMode: .summary,
            briefingDay: day
        )
        let submission = LokiNotificationContract.content(for: input)
        let expectedDayLabel = day.formatted(.abbreviated)

        XCTAssertEqual(submission.title, "Loki Brief · 2026-07-19")
        XCTAssertTrue(submission.body.contains(expectedDayLabel))
        XCTAssertEqual(
            submission.userInfo[LokiNotificationContract.UserInfoKey.briefingDay],
            "2026-07-19"
        )
        XCTAssertEqual(
            submission.userInfo[LokiNotificationContract.UserInfoKey.version],
            LokiNotificationContract.payloadVersion
        )
        XCTAssertFalse(submission.title.contains("2026-07-20"))
    }

    private func brief(at instant: Date, timeZone: TimeZone) -> Brief {
        let calendar = gregorian(timeZone: timeZone)
        return DeterministicFeedBriefingEngine(
            now: { instant },
            calendar: { calendar },
            timeZone: { timeZone }
        ).assemble(
            entries: [],
            subscriptions: [],
            preferences: .default
        ).brief
    }

    private func historyEntry(
        id: String,
        generatedAt: Date,
        briefingDay: LocalCalendarDay
    ) -> BriefHistoryEntry {
        BriefHistoryEntry(
            id: id,
            title: "Loki Brief · \(briefingDay.storageValue)",
            date: generatedAt,
            generatedAt: generatedAt,
            status: .ready,
            itemCount: 0,
            fixtureRevision: 0,
            briefingDay: briefingDay
        )
    }

    private func gregorian(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        let calendar = gregorian(timeZone: timeZone)
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        ))!
    }
}
