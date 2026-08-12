import AppKit
import XCTest
import UserNotifications
@testable import LokiBrief

@MainActor
private final class NotificationRouteRecorder {
    var routes: [NotificationRoute] = []
}

@MainActor
private final class UpdateRouteRecorder {
    var routes: [UpdateRoute] = []
}

private actor ShutdownProbe {
    private(set) var observed = false
    func record() { observed = true }
}

final class NotificationResponseRouterTests: XCTestCase {
    @MainActor
    func testApplicationRemainsRunningAfterLastWindowCloses() {
        let delegate = LokiApplicationDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @MainActor
    func testApplicationShutdownCompletesWithinBound() async {
        let probe = ShutdownProbe()

        let result = await LokiApplicationDelegate.performBoundedShutdown(
            timeout: .milliseconds(100)
        ) {
            await probe.record()
        }

        XCTAssertEqual(result, .completed)
        let handlerRan = await probe.observed
        XCTAssertTrue(handlerRan)
    }

    @MainActor
    func testApplicationShutdownTimesOutAndSignalsCancellation() async {
        let probe = ShutdownProbe()
        let result = await LokiApplicationDelegate.performBoundedShutdown(
            timeout: .milliseconds(20)
        ) {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                await probe.record()
            } catch { }
        }

        XCTAssertEqual(result, .timedOut)
        for _ in 0..<20 {
            if await probe.observed { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let cancellationObserved = await probe.observed
        XCTAssertTrue(cancellationObserved)
    }

    @MainActor
    func testRepeatedQuitKeepsDeferredTerminationInFlight() {
        XCTAssertEqual(
            LokiApplicationDelegate.terminationReply(shutdownHandlerInstalled: true, terminationInProgress: false),
            .terminateLater
        )
        XCTAssertEqual(
            LokiApplicationDelegate.terminationReply(shutdownHandlerInstalled: true, terminationInProgress: true),
            .terminateLater
        )
        XCTAssertEqual(
            LokiApplicationDelegate.terminationReply(shutdownHandlerInstalled: false, terminationInProgress: false),
            .terminateNow
        )
    }

    @MainActor
    func testApplicationShutdownTraceUsesStablePrivacySafeSchema() throws {
        let event = LokiApplicationDelegate.shutdownTraceEvent(
            result: .timedOut,
            durationMilliseconds: 3_001,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            trace: .init(traceID: "trace-safe", spanID: "span-safe", parentSpanID: nil)
        )

        XCTAssertEqual(event.event, .applicationShutdown)
        XCTAssertEqual(event.component, "application_lifecycle")
        XCTAssertEqual(event.status, .degraded)
        XCTAssertEqual(event.reasonCode, "application_shutdown_timed_out")
        XCTAssertEqual(event.durationMilliseconds, 3_001)
        XCTAssertEqual(event.metadata[.shutdownResult], "timed_out")
        XCTAssertEqual(event.metadata[.timeoutMilliseconds], "3000")
        let line = try XCTUnwrap(ScheduledBriefingProductionTraceLogger.encodedLine(for: event))
        XCTAssertTrue(line.contains("\"event\":\"application.shutdown\""))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("token"))
    }

    func testDefaultActionParsesValidatedBriefRoute() {
        let identifier = LokiNotificationContract.stableIdentifier(occurrenceKey: "occurrence")
        let route = NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: identifier,
            userInfo: [
                LokiNotificationContract.UserInfoKey.version: LokiNotificationContract.payloadVersion,
                LokiNotificationContract.UserInfoKey.briefID: "brief-1",
            ]
        )

        XCTAssertEqual(route, .init(notificationIdentifier: identifier, briefID: "brief-1"))
    }

    func testDismissActionDoesNotRoute() {
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "occurrence"),
            userInfo: [
                LokiNotificationContract.UserInfoKey.version: LokiNotificationContract.payloadVersion,
                LokiNotificationContract.UserInfoKey.briefID: "brief-1",
            ]
        ))
    }

    func testWrongCategoryVersionOrIdentifierFailsClosed() {
        let validIdentifier = LokiNotificationContract.stableIdentifier(occurrenceKey: "occurrence")
        let validInfo: [AnyHashable: Any] = [
            LokiNotificationContract.UserInfoKey.version: LokiNotificationContract.payloadVersion,
            LokiNotificationContract.UserInfoKey.briefID: "brief-1",
        ]
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: "OTHER",
            notificationIdentifier: validIdentifier,
            userInfo: validInfo
        ))
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: "untrusted",
            userInfo: validInfo
        ))
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: validIdentifier,
            userInfo: [
                LokiNotificationContract.UserInfoKey.version: "999",
                LokiNotificationContract.UserInfoKey.briefID: "brief-1",
            ]
        ))
    }

    func testMissingOrControlCharacterBriefIdentifierFailsClosed() {
        let identifier = LokiNotificationContract.stableIdentifier(occurrenceKey: "occurrence")
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: identifier,
            userInfo: [LokiNotificationContract.UserInfoKey.version: LokiNotificationContract.payloadVersion]
        ))
        XCTAssertNil(NotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: LokiNotificationContract.categoryIdentifier,
            notificationIdentifier: identifier,
            userInfo: [
                LokiNotificationContract.UserInfoKey.version: LokiNotificationContract.payloadVersion,
                LokiNotificationContract.UserInfoKey.briefID: "brief\nprivate",
            ]
        ))
    }

    func testUpdateNotificationRouteIsExactAndPayloadFree() {
        let route = UpdateNotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: UpdateRoute.availabilityNotificationCategoryIdentifier,
            notificationIdentifier: UpdateRoute.availabilityNotificationIdentifier,
            userInfo: [:]
        )
        XCTAssertEqual(route, UpdateRoute(source: .notification, action: .showAvailability))

        XCTAssertNil(UpdateNotificationRouteParser.parse(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            categoryIdentifier: UpdateRoute.availabilityNotificationCategoryIdentifier,
            notificationIdentifier: UpdateRoute.availabilityNotificationIdentifier,
            userInfo: [:]
        ))
        XCTAssertNil(UpdateNotificationRouteParser.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: UpdateRoute.availabilityNotificationCategoryIdentifier,
            notificationIdentifier: UpdateRoute.availabilityNotificationIdentifier,
            userInfo: ["candidate_version": "private-payload"]
        ))
    }

    @MainActor
    func testUpdateRouteBuffersBeforeConsumerAndDrainsOnce() async {
        let buffer = UpdateRouteBuffer()
        let route = UpdateRoute(source: .notification, action: .showAvailability)
        await buffer.enqueue(route)
        let pendingBeforeConnection = await buffer.pendingRouteForTesting()
        XCTAssertEqual(pendingBeforeConnection, route)

        let recorder = UpdateRouteRecorder()
        await buffer.connect { recorder.routes.append($0) }

        XCTAssertEqual(recorder.routes, [route])
        let pendingAfterConnection = await buffer.pendingRouteForTesting()
        XCTAssertNil(pendingAfterConnection)
    }

    @MainActor
    func testResponseBeforeIntegrationIsBufferedAndDrainedOnce() async {
        let buffer = NotificationRouteBuffer()
        let route = NotificationRoute(
            notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "early"),
            briefID: "brief-early"
        )
        await buffer.enqueue(route)
        await buffer.enqueue(route)
        let pendingBeforeConnection = await buffer.pendingRoutesForTesting()
        XCTAssertEqual(pendingBeforeConnection, [route])

        let recorder = NotificationRouteRecorder()
        await buffer.connect { recorder.routes.append($0) }

        XCTAssertEqual(recorder.routes, [route])
        let pendingAfterConnection = await buffer.pendingRoutesForTesting()
        XCTAssertTrue(pendingAfterConnection.isEmpty)
    }

    @MainActor
    func testConnectedHandlerReceivesNewRoute() async {
        let buffer = NotificationRouteBuffer()
        let recorder = NotificationRouteRecorder()
        await buffer.connect { recorder.routes.append($0) }
        let route = NotificationRoute(
            notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "connected"),
            briefID: "brief-connected"
        )

        await buffer.enqueue(route)

        XCTAssertEqual(recorder.routes, [route])
    }

    func testQueueIsBoundedToMostRecentRoutes() async {
        let buffer = NotificationRouteBuffer()
        for index in 0..<(LokiNotificationContract.maximumQueuedRoutes + 3) {
            await buffer.enqueue(.init(
                notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "occurrence-\(index)"),
                briefID: "brief-\(index)"
            ))
        }

        let routes = await buffer.pendingRoutesForTesting()
        XCTAssertEqual(routes.count, LokiNotificationContract.maximumQueuedRoutes)
        XCTAssertEqual(routes.first?.briefID, "brief-3")
    }

    @MainActor
    func testInvalidationRejectsRouteCapturedBeforeDeleteEvenAfterResume() async {
        let buffer = NotificationRouteBuffer()
        let recorder = NotificationRouteRecorder()
        await buffer.connect { recorder.routes.append($0) }
        let route = NotificationRoute(
            notificationIdentifier: LokiNotificationContract.stableIdentifier(occurrenceKey: "stale"),
            briefID: "brief-stale"
        )
        let staleTicket = buffer.captureTicket()

        await buffer.invalidate()
        await buffer.resume()
        await buffer.enqueue(route, ticket: staleTicket)

        XCTAssertTrue(recorder.routes.isEmpty)
    }
}
