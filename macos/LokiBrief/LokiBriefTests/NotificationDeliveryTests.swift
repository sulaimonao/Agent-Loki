import XCTest
import UserNotifications
@testable import LokiBrief

private enum NotificationTestError: Error { case rejected }

private actor FakeUserNotificationCenter: UserNotificationCenterClient {
    var state: NotificationAuthorizationState
    var requestedState: NotificationAuthorizationState
    var requestError: Error?
    var submitError: Error?
    var shouldBlockSubmit = false
    private var submitContinuation: CheckedContinuation<Void, Never>?
    private(set) var authorizationRequests = 0
    private(set) var submissions: [NotificationSubmission] = []
    private(set) var removedPending: [[String]] = []
    private(set) var removedDelivered: [[String]] = []
    private(set) var removeAllPendingCount = 0
    private(set) var removeAllDeliveredCount = 0
    private(set) var submitStarted = false

    init(
        state: NotificationAuthorizationState,
        requestedState: NotificationAuthorizationState = .authorized
    ) {
        self.state = state
        self.requestedState = requestedState
    }

    func authorizationState() async -> NotificationAuthorizationState { state }

    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState {
        authorizationRequests += 1
        if let requestError { throw requestError }
        state = requestedState
        return requestedState
    }

    func submit(_ submission: NotificationSubmission) async throws {
        submitStarted = true
        if shouldBlockSubmit {
            await withCheckedContinuation { submitContinuation = $0 }
        }
        if let submitError { throw submitError }
        submissions.append(submission)
    }

    func removePending(identifiers: [String]) async { removedPending.append(identifiers) }
    func removeDelivered(identifiers: [String]) async { removedDelivered.append(identifiers) }
    func removeAllPending() async { removeAllPendingCount += 1 }
    func removeAllDelivered() async { removeAllDeliveredCount += 1 }

    func configureRequestError() { requestError = NotificationTestError.rejected }
    func configureSubmitError() { submitError = NotificationTestError.rejected }
    func blockSubmission() { shouldBlockSubmit = true }
    func resumeSubmission() { submitContinuation?.resume(); submitContinuation = nil }
}

final class NotificationDeliveryTests: XCTestCase {
    func testRefreshReadsAuthorizationWithoutRequestingIt() async {
        let center = FakeUserNotificationCenter(state: .notDetermined)
        let service = NotificationDeliveryService(center: center)

        let state = await service.refreshAuthorization()
        let requests = await center.authorizationRequests
        XCTAssertEqual(state, .notDetermined)
        XCTAssertEqual(requests, 0)
    }

    func testExplicitAuthorizationIsTheOnlyRequestingEntryPoint() async {
        let center = FakeUserNotificationCenter(state: .notDetermined, requestedState: .authorized)
        let service = NotificationDeliveryService(center: center)

        let state = await service.requestAuthorization(reason: .explicitUserEnable)
        let requests = await center.authorizationRequests
        XCTAssertEqual(state, .authorized)
        XCTAssertEqual(requests, 1)
    }

    func testAuthorizationFailureReturnsErrorWithoutRetry() async {
        let center = FakeUserNotificationCenter(state: .notDetermined)
        await center.configureRequestError()
        let service = NotificationDeliveryService(center: center)

        let state = await service.requestAuthorization(reason: .explicitUserEnable)
        let requests = await center.authorizationRequests
        XCTAssertEqual(state, .error)
        XCTAssertEqual(requests, 1)
    }

    func testSystemAuthorizationStatusMappingCoversPublishedCases() {
        XCTAssertEqual(SystemUserNotificationCenterClient.map(.notDetermined), .notDetermined)
        XCTAssertEqual(SystemUserNotificationCenterClient.map(.denied), .denied)
        XCTAssertEqual(SystemUserNotificationCenterClient.map(.authorized), .authorized)
        XCTAssertEqual(SystemUserNotificationCenterClient.map(.provisional), .provisional)
        XCTAssertTrue(NotificationAuthorizationState.allCases.contains(.ephemeral))
    }

    func testAuthorizedEligibleRunIsTruthfullySubmitted() async {
        let center = FakeUserNotificationCenter(state: .authorized)
        let service = NotificationDeliveryService(center: center)
        let input = fixture()

        let outcome = await service.deliver(input, reservation: .reserved)
        XCTAssertEqual(outcome, .submitted)
        let submissions = await center.submissions
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions[0], LokiNotificationContract.content(for: input))
    }

    func testDeniedAuthorizationDoesNotSubmitOrRequest() async {
        let center = FakeUserNotificationCenter(state: .denied)
        let service = NotificationDeliveryService(center: center)

        let outcome = await service.deliver(fixture(), reservation: .reserved)
        let submissions = await center.submissions
        let requests = await center.authorizationRequests
        XCTAssertEqual(outcome, .authorizationDenied)
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func testNotDeterminedAuthorizationDoesNotPromptFromDelivery() async {
        let center = FakeUserNotificationCenter(state: .notDetermined)
        let service = NotificationDeliveryService(center: center)

        let outcome = await service.deliver(fixture(), reservation: .reserved)
        let requests = await center.authorizationRequests
        XCTAssertEqual(outcome, .authorizationNotDetermined)
        XCTAssertEqual(requests, 0)
    }

    func testFailedCanceledSkippedAndConfigurationRunsDoNotNotify() async {
        for result in [
            NotificationEligibleRunResult.failed,
            .canceled,
            .skipped,
            .configurationRequired,
        ] {
            let center = FakeUserNotificationCenter(state: .authorized)
            let service = NotificationDeliveryService(center: center)
            let input = fixture(runResult: result, hasUsableBrief: false)
            let outcome = await service.deliver(input, reservation: .reserved)
            let submissions = await center.submissions
            XCTAssertEqual(outcome, .ineligibleRun)
            XCTAssertTrue(submissions.isEmpty)
        }
    }

    func testUsablePartialRunMayNotify() async {
        let center = FakeUserNotificationCenter(state: .provisional)
        let service = NotificationDeliveryService(center: center)

        let outcome = await service.deliver(fixture(runResult: .partiallyCompleted), reservation: .reserved)
        XCTAssertEqual(outcome, .submitted)
    }

    func testPersistedDuplicateAndSuppressedDecisionDoNotSubmit() async {
        let center = FakeUserNotificationCenter(state: .authorized)
        let service = NotificationDeliveryService(center: center)

        let duplicate = await service.deliver(fixture(), reservation: .alreadySubmitted)
        let suppressed = await service.deliver(fixture(), reservation: .suppressed)
        let submissions = await center.submissions
        XCTAssertEqual(duplicate, .duplicateSuppressed)
        XCTAssertEqual(suppressed, .notRequested)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testSubmissionErrorIsNotReportedAsDelivered() async {
        let center = FakeUserNotificationCenter(state: .authorized)
        await center.configureSubmitError()
        let service = NotificationDeliveryService(center: center)

        let outcome = await service.deliver(fixture(), reservation: .reserved)
        XCTAssertEqual(outcome, .addFailed)
    }

    func testRemoveAllRemovesPendingAndDeliveredArtifacts() async {
        let center = FakeUserNotificationCenter(state: .authorized)
        let service = NotificationDeliveryService(center: center)

        await service.removeAll()

        let pendingCount = await center.removeAllPendingCount
        let deliveredCount = await center.removeAllDeliveredCount
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(deliveredCount, 1)
    }

    func testEpochRejectsAndRemovesLateSubmission() async {
        let center = FakeUserNotificationCenter(state: .authorized)
        await center.blockSubmission()
        let service = NotificationDeliveryService(center: center)
        let input = fixture()
        let identifier = LokiNotificationContract.stableIdentifier(occurrenceKey: input.occurrenceKey)

        let delivery = Task { await service.deliver(input, reservation: .reserved) }
        while !(await center.submitStarted) { await Task.yield() }
        await service.removeAll()
        await center.resumeSubmission()

        let outcome = await delivery.value
        let removedPending = await center.removedPending
        let removedDelivered = await center.removedDelivered
        XCTAssertEqual(outcome, .removed)
        XCTAssertTrue(removedPending.contains([identifier]))
        XCTAssertTrue(removedDelivered.contains([identifier]))
    }

    private func fixture(
        runResult: NotificationEligibleRunResult = .completed,
        hasUsableBrief: Bool = true
    ) -> NotificationDeliveryInput {
        .init(
            occurrenceKey: "schedule-1|2026-07-16|06:00|America/Los_Angeles|v1",
            briefID: "brief-2026-07-16",
            runResult: runResult,
            hasUsableBrief: hasUsableBrief,
            itemCount: 8,
            sourceCount: 3,
            privacyMode: .summary
        )
    }
}
