import XCTest
@testable import LokiBrief

final class DeliveryPrivacyTests: XCTestCase {
    func testStableIdentifierHashesOccurrenceKeyWithSHA256() {
        XCTAssertEqual(
            LokiNotificationContract.stableIdentifier(occurrenceKey: "abc"),
            "lokibrief.daily.ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testMinimalNotificationContainsNoCountsOrInputIdentifiers() {
        let input = privateFixture(privacyMode: .minimal)
        let submission = LokiNotificationContract.content(for: input)

        XCTAssertEqual(submission.title, "Loki Brief · 2026-07-19")
        XCTAssertEqual(submission.body, "Your \(input.briefingDay.formatted(.abbreviated)) brief is ready.")
        XCTAssertFalse(submission.identifier.contains(input.occurrenceKey))
        XCTAssertFalse(submission.body.contains(input.briefID))
        XCTAssertEqual(Set(submission.userInfo.keys), [
            LokiNotificationContract.UserInfoKey.briefID,
            LokiNotificationContract.UserInfoKey.briefingDay,
            LokiNotificationContract.UserInfoKey.version,
        ])
        XCTAssertEqual(submission.userInfo[LokiNotificationContract.UserInfoKey.briefingDay], "2026-07-19")
        XCTAssertEqual(submission.userInfo[LokiNotificationContract.UserInfoKey.version], "2")
    }

    func testSummaryNotificationContainsCountsButNoPrivateSourceMetadata() {
        let input = privateFixture(privacyMode: .summary)
        let submission = LokiNotificationContract.content(for: input)

        XCTAssertEqual(
            submission.body,
            "\(input.briefingDay.formatted(.abbreviated)): 8 items from 3 sources"
        )
        for forbidden in [
            "private-channel",
            "workspace-name",
            "author@example.com",
            "https://private.example/path",
            "secret search",
            input.occurrenceKey,
            input.briefID,
        ] {
            XCTAssertFalse(submission.title.contains(forbidden))
            XCTAssertFalse(submission.body.contains(forbidden))
        }
    }

    func testReasonCodeSanitizerRejectsPayloadLikeTextAndURLs() {
        XCTAssertEqual(NotificationPrivacySanitizer.reasonCode("notification_add_failed"), "notification_add_failed")
        XCTAssertEqual(NotificationPrivacySanitizer.reasonCode("token abc@example.com"), "invalid_reason_code")
        XCTAssertEqual(NotificationPrivacySanitizer.reasonCode("https://private.example"), "invalid_reason_code")
        XCTAssertNil(NotificationPrivacySanitizer.reasonCode(nil))
    }

    func testTraceCarriesDeepLoggingLinksWithoutNotificationContent() {
        let event = NotificationTraceEvent(
            event: "notification_delivery",
            traceID: "trace-1",
            spanID: "span-1",
            parentSpanID: "parent-1",
            status: .success,
            reasonCode: "submitted_to_system",
            durationMilliseconds: 12,
            notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "private-occurrence"),
            itemCount: 8,
            sourceCount: 3
        )

        XCTAssertEqual(event.traceID, "trace-1")
        XCTAssertEqual(event.spanID, "span-1")
        XCTAssertEqual(event.parentSpanID, "parent-1")
        XCTAssertEqual(event.durationMilliseconds, 12)
        XCTAssertEqual(event.component, "notification_delivery")
        XCTAssertFalse(event.notificationIdentifier?.contains("private-occurrence") ?? true)
        let labels = Set(Mirror(reflecting: event).children.compactMap(\.label))
        XCTAssertFalse(labels.contains("body"))
        XCTAssertFalse(labels.contains("title"))
        XCTAssertFalse(labels.contains("briefID"))
        XCTAssertFalse(labels.contains("sourceName"))
    }

    func testDeliveryHistoryRowHasNoPrivateSourceTextSurface() {
        let row = DeliveryHistoryRow(
            id: "run-1",
            intendedAt: Date(timeIntervalSince1970: 1),
            actualAt: Date(timeIntervalSince1970: 2),
            triggerLabel: "Scheduled",
            resultLabel: "Completed",
            itemCount: 8,
            sourceCount: 3,
            briefID: "brief-1",
            notificationOutcome: .submitted,
            boundedReasonCode: "completed"
        )
        let labels = Set(Mirror(reflecting: row).children.compactMap(\.label))

        XCTAssertFalse(labels.contains("sourceName"))
        XCTAssertFalse(labels.contains("channelName"))
        XCTAssertFalse(labels.contains("messageExcerpt"))
        XCTAssertFalse(labels.contains("notificationBody"))
        XCTAssertEqual(row.boundedReasonCode, "completed")
    }

    private func privateFixture(privacyMode: NotificationPrivacyMode) -> NotificationDeliveryInput {
        .init(
            occurrenceKey: "schedule-private|2026-07-16|private-channel|workspace-name|author@example.com|https://private.example/path|secret search",
            briefID: "brief-private",
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: 8,
            sourceCount: 3,
            privacyMode: privacyMode,
            briefingDay: .init(year: 2026, month: 7, day: 19)
        )
    }
}
