import SwiftData
import XCTest
@testable import LokiBrief

private actor P5DisabledFeedClient: FeedRetrieving {
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        throw FeedFetchFailure(.networkUnavailable)
    }
    func cancelAll() async { }
}

private actor P5SuspendedFeedClient: FeedRetrieving {
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancellationCount = 0

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        await withCheckedContinuation { continuation = $0 }
        let now = Date()
        let articleURL = URL(string: "https://example.com/late-scheduled-result")!
        let entry = NormalizedFeedEntry(
            id: "late-p5-entry",
            identity: .init(value: articleURL.absoluteString, basis: .canonicalURL),
            subscriptionID: subscription.id,
            sourceTitle: subscription.title,
            title: "Late scheduled result",
            summary: "This result must not recreate local data after deletion.",
            canonicalURL: articleURL,
            author: nil,
            publishedAt: now,
            updatedAt: nil,
            retrievedAt: now,
            originalPosition: 0,
            provenance: .init(
                subscriptionID: subscription.id,
                feedURL: subscription.canonicalURL,
                format: subscription.format,
                upstreamIdentifier: "late-p5-entry",
                retrievedAt: now,
                originalPosition: 0
            )
        )
        return .init(
            subscription: subscription,
            entries: [entry],
            record: .init(
                id: "late-p5-fetch",
                subscriptionID: subscription.id,
                traceID: trace.traceID,
                attemptedAt: now,
                completedAt: now,
                httpStatus: 200,
                responseByteCount: 128,
                parsedEntryCount: 1,
                finalURL: subscription.canonicalURL,
                eTag: nil,
                lastModified: nil,
                wasNotModified: false
            ),
            warnings: []
        )
    }

    func cancelAll() async { cancellationCount += 1 }
    func isSuspended() -> Bool { continuation != nil }
    func cancellations() -> Int { cancellationCount }
    func resolve() {
        continuation?.resume()
        continuation = nil
    }
}

private struct P5AuthorizedNotificationClient: UserNotificationCenterClient {
    func authorizationState() async -> NotificationAuthorizationState { .authorized }
    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState { .authorized }
    func submit(_ submission: NotificationSubmission) async throws { }
    func removePending(identifiers: [String]) async { }
    func removeDelivered(identifiers: [String]) async { }
    func removeAllPending() async { }
    func removeAllDelivered() async { }
}

private actor P5SuspendedNotificationDisableClient: UserNotificationCenterClient {
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var suspendNextAuthorizationRead = false
    private var submissionCount = 0
    private var removeAllCount = 0

    func authorizationState() async -> NotificationAuthorizationState {
        if suspendNextAuthorizationRead {
            suspendNextAuthorizationRead = false
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        return .authorized
    }

    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState { .authorized }
    func submit(_ submission: NotificationSubmission) async throws { submissionCount += 1 }
    func removePending(identifiers: [String]) async { }
    func removeDelivered(identifiers: [String]) async { }
    func removeAllPending() async { removeAllCount += 1 }
    func removeAllDelivered() async { suspendNextAuthorizationRead = true }

    func isAuthorizationSuspended() -> Bool { authorizationContinuation != nil }
    func submissions() -> Int { submissionCount }
    func removals() -> Int { removeAllCount }
    func resumeAuthorization() {
        let pending = authorizationContinuation
        authorizationContinuation = nil
        pending?.resume()
    }
}

private actor P5SuspendedNotificationClient: UserNotificationCenterClient {
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var suspendNextAuthorizationRead: Bool
    private(set) var submissionCount = 0

    init(suspendNextAuthorizationRead: Bool = true) {
        self.suspendNextAuthorizationRead = suspendNextAuthorizationRead
    }

    func authorizationState() async -> NotificationAuthorizationState {
        if suspendNextAuthorizationRead {
            suspendNextAuthorizationRead = false
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        return .authorized
    }

    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState { .authorized }
    func submit(_ submission: NotificationSubmission) async throws { submissionCount += 1 }
    func removePending(identifiers: [String]) async { }
    func removeDelivered(identifiers: [String]) async { }
    func removeAllPending() async { }
    func removeAllDelivered() async { }

    func hasSuspendedAuthorizationRead() -> Bool { authorizationContinuation != nil }

    func resumeAuthorizationRead() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

private actor P5SuspendedLaunchClient: LaunchAtLoginSystemClient {
    private var registerContinuation: CheckedContinuation<Void, Never>?
    private var registered = false

    func currentState() async -> LaunchAtLoginSystemState {
        registered ? .enabled : .notRegistered
    }

    func register() async throws {
        await withCheckedContinuation { registerContinuation = $0 }
        registered = true
    }

    func unregister() async throws { registered = false }
    func openLoginItemsSettings() async { }

    func hasSuspendedRegistration() -> Bool { registerContinuation != nil }

    func resumeRegistration() {
        registerContinuation?.resume()
        registerContinuation = nil
    }
}

private actor P5BlockingSchedulePersistence: SchedulePersisting {
    private let persistedSchedule: BriefSchedule
    private var suspendNextLoad: Bool
    private var suspendNextClaim: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var claimContinuation: CheckedContinuation<ScheduleClaimDisposition, Never>?
    private var states: [ScheduleSlotKey: ScheduleOccurrenceState] = [:]
    private(set) var loadCount = 0
    private(set) var claimCount = 0
    private(set) var markCount = 0
    private(set) var recoveryCount = 0

    init(
        schedule: BriefSchedule = BriefSchedule(enabled: false),
        suspendNextLoad: Bool = false,
        suspendNextClaim: Bool = false
    ) {
        self.persistedSchedule = schedule
        self.suspendNextLoad = suspendNextLoad
        self.suspendNextClaim = suspendNextClaim
    }

    func loadPrimarySchedule() async throws -> BriefSchedule {
        loadCount += 1
        if suspendNextLoad {
            suspendNextLoad = false
            await withCheckedContinuation { loadContinuation = $0 }
        }
        return persistedSchedule
    }

    func save(_ schedule: BriefSchedule, at date: Date) async throws { }

    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState? {
        states[occurrence.slotKey]
    }

    func claim(
        _ occurrence: ScheduleOccurrence,
        trigger: ScheduleActivationTrigger,
        at date: Date
    ) async throws -> ScheduleClaimDisposition {
        claimCount += 1
        if suspendNextClaim {
            suspendNextClaim = false
            let disposition = await withCheckedContinuation { claimContinuation = $0 }
            if disposition == .claimed { states[occurrence.slotKey] = .claimed }
            return disposition
        }
        states[occurrence.slotKey] = .claimed
        return .claimed
    }

    func mark(
        _ occurrence: ScheduleOccurrence,
        state: ScheduleOccurrenceState,
        reasonCode: String,
        at date: Date
    ) async throws {
        markCount += 1
        states[occurrence.slotKey] = state
    }

    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int {
        recoveryCount += 1
        return 0
    }

    func hasSuspendedLoad() -> Bool { loadContinuation != nil }
    func hasSuspendedClaim() -> Bool { claimContinuation != nil }

    func resumeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func resumeClaim(_ disposition: ScheduleClaimDisposition) {
        claimContinuation?.resume(returning: disposition)
        claimContinuation = nil
    }

    func operationCounts() -> [Int] {
        [loadCount, claimCount, markCount, recoveryCount]
    }
}

private struct P5NotRegisteredLaunchClient: LaunchAtLoginSystemClient {
    func currentState() async -> LaunchAtLoginSystemState { .notRegistered }
    func register() async throws { }
    func unregister() async throws { }
    func openLoginItemsSettings() async { }
}

@MainActor
private final class P5MainWindowOpenRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
final class P5DeliveryControllerTests: XCTestCase, @unchecked Sendable {
    func testManualRunUsesProductionCoordinatorAndPersistsBriefRunAndOccurrence() async throws {
        let store = try LocalStore(inMemory: true)
        try seedExistingFeedEvidence(store)
        let p2 = try store.p2Settings()
        p2.previewFixturesEnabled = false
        try store.save()
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let controller = try XCTUnwrap(model.p5Controller)
        controller.updateSchedule {
            $0.delivery.refreshFeeds = false
            $0.delivery.refreshSelectedSlackWorkspaces = false
            $0.delivery.notificationsEnabled = false
        }

        let outcome = await controller.runManualNow()

        guard case .succeeded = outcome else { return XCTFail("Expected a complete deterministic manual run, got \(outcome)") }
        let runs = try store.scheduledBriefingRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].triggerRaw, ScheduledRunTrigger.manualRunNow.rawValue)
        XCTAssertEqual(runs[0].stateRaw, ScheduledRunState.completed.rawValue)
        XCTAssertNotNil(runs[0].briefID)
        XCTAssertEqual(try store.history().count, 1)
        let occurrences = try store.container.mainContext.fetch(FetchDescriptor<StoredScheduleOccurrence>())
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences[0].state, .succeeded)
        XCTAssertEqual(controller.historyRows.count, 1)
    }

    func testUnconfiguredProductionEntitlementFailsClosedWithoutCreatingRun() async throws {
        let store = try LocalStore(inMemory: true)
        try seedExistingFeedEvidence(store)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            entitlementProvider: UnconfiguredFeatureEntitlementProvider(),
            isTesting: true
        )
        controller.updateSchedule { $0.delivery.refreshFeeds = false }

        let outcome = await controller.runManualNow()

        guard case .entitlementRequired(let reasonCode) = outcome else { return XCTFail("Expected entitlementRequired, got \(outcome)") }
        XCTAssertEqual(reasonCode, "vault_entitlement_provider_not_configured")
        XCTAssertTrue(try store.scheduledBriefingRuns().isEmpty)
        let occurrences = try store.container.mainContext.fetch(FetchDescriptor<StoredScheduleOccurrence>())
        XCTAssertEqual(occurrences.first?.state, .failed)
    }

    func testDeleteAllRejectsLateFeedCompletionWithoutRecreatingP5Data() async throws {
        let store = try LocalStore(inMemory: true)
        try seedExistingFeedEvidence(store)
        let feedClient = P5SuspendedFeedClient()
        let model = try AppModel(store: store, feedClient: feedClient)
        let controller = try XCTUnwrap(model.p5Controller)
        controller.updateSchedule {
            $0.delivery.refreshFeeds = true
            $0.delivery.refreshSelectedSlackWorkspaces = false
            $0.delivery.notificationsEnabled = false
            $0.delivery.allowScheduledOllama = false
        }

        let running = Task { await controller.runManualNow() }
        try await eventually { await feedClient.isSuspended() }

        await model.deleteAllData()
        await feedClient.resolve()
        let result = await running.value
        try await Task.sleep(for: .milliseconds(30))

        guard case .canceled(let reasonCode) = result else {
            return XCTFail("Expected the deleted run to be canceled, got \(result)")
        }
        let cancellationCount = await feedClient.cancellations()
        XCTAssertEqual(reasonCode, "local_data_deleted")
        XCTAssertGreaterThanOrEqual(cancellationCount, 1)
        XCTAssertTrue(try store.history().isEmpty)
        XCTAssertTrue(try store.feedSubscriptions().isEmpty)
        XCTAssertTrue(try store.deliveryRecords().isEmpty)
        XCTAssertTrue(try store.scheduledBriefingRuns().isEmpty)
        let context = store.container.mainContext
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredScheduleOccurrence>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredScheduledBriefingSourceResult>()).isEmpty)
    }

    func testDisableNotificationsLatchesBeforeCleanupAwaitAndBlocksPlannedRunSubmission() async throws {
        let store = try LocalStore(inMemory: true)
        try seedExistingFeedEvidence(store)
        var schedule = try store.primaryBriefSchedule()
        schedule.delivery.refreshFeeds = true
        schedule.delivery.refreshSelectedSlackWorkspaces = false
        schedule.delivery.allowScheduledOllama = false
        schedule.delivery.notificationsEnabled = true
        try store.savePrimaryBriefSchedule(schedule)
        let notificationSettings = try store.notificationDeliverySettings()
        notificationSettings.enabledPreference = true
        notificationSettings.lastObservedAuthorization = .authorized
        try store.save()

        let feedClient = P5SuspendedFeedClient()
        let notificationClient = P5SuspendedNotificationDisableClient()
        let model = try AppModel(store: store, feedClient: feedClient)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: notificationClient,
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )

        let running = Task { await controller.runManualNow() }
        try await eventually { await feedClient.isSuspended() }
        controller.setNotificationsEnabled(false)
        try await eventually { await notificationClient.isAuthorizationSuspended() }
        await feedClient.resolve()
        let outcome = await running.value

        guard case .succeeded = outcome else {
            await notificationClient.resumeAuthorization()
            return XCTFail("Expected the deterministic run to complete, got \(outcome)")
        }
        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let notificationUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(notificationUpdatePrepared)
        let removalCount = await notificationClient.removals()
        let submissionCount = await notificationClient.submissions()
        XCTAssertGreaterThanOrEqual(removalCount, 1)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(try store.deliveryRecords().contains(where: { $0.outcome == .submitted }))

        await notificationClient.resumeAuthorization()
        for _ in 0..<200 {
            if !controller.notificationState.isPerformingAction { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.notificationState.isPerformingAction)
        XCTAssertFalse(controller.notificationState.notificationsEnabledPreference)
        XCTAssertFalse(controller.schedule.delivery.notificationsEnabled)
    }

    func testNotificationRouteSelectsPersistedBriefOnTodayAndRequestsMainWindowOnce() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let brief = DeterministicBriefingEngine().generatePreview(revision: 41)
        try store.record(brief)
        let input = NotificationDeliveryInput(
            occurrenceKey: "notification-route-fixture",
            briefID: brief.id,
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: brief.itemCount,
            sourceCount: brief.sections.count,
            privacyMode: .minimal
        )
        let (_, record) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: P5AuthorizedNotificationClient(),
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )
        let buffer = NotificationRouteBuffer()
        let windowRecorder = P5MainWindowOpenRecorder()
        await controller.activate(
            lifecycle: nil,
            notificationBuffer: buffer,
            openMainWindow: { windowRecorder.record() }
        )

        await buffer.enqueue(.init(notificationIdentifier: record.notificationIdentifier, briefID: brief.id))

        XCTAssertEqual(model.brief.id, brief.id)
        XCTAssertEqual(model.selection, .today)
        XCTAssertEqual(windowRecorder.count, 1)
        XCTAssertNotNil(try store.deliveryRecords().first?.responseReceivedAt)
        await controller.shutdown()
    }

    func testUpdatePreparationBlocksLifecycleAndNotificationWritesUntilAbortRecovery() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let brief = DeterministicBriefingEngine().generatePreview(revision: 61)
        try store.record(brief)
        let input = NotificationDeliveryInput(
            occurrenceKey: "notification-update-barrier-fixture",
            briefID: brief.id,
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: brief.itemCount,
            sourceCount: brief.sections.count,
            privacyMode: .minimal
        )
        let (_, record) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: P5AuthorizedNotificationClient(),
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )
        let center = NotificationCenter()
        let lifecycle = AppLifecycleEventSource(defaultCenter: center)
        let buffer = NotificationRouteBuffer()
        let windowRecorder = P5MainWindowOpenRecorder()
        await controller.activate(
            lifecycle: lifecycle,
            notificationBuffer: buffer,
            openMainWindow: { windowRecorder.record() }
        )
        try await Task.sleep(for: .milliseconds(30))

        let updatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertTrue(updatePrepared)
        let preparedSnapshot = controller.schedulerSnapshot
        center.post(name: .NSSystemClockDidChange, object: nil)
        await buffer.enqueue(.init(
            notificationIdentifier: record.notificationIdentifier,
            briefID: brief.id
        ))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(controller.schedulerSnapshot, preparedSnapshot)
        XCTAssertNil(try store.deliveryRecords().first?.responseReceivedAt)
        XCTAssertEqual(windowRecorder.count, 0)

        await controller.resumeAfterUpdateInstallationAbort()
        let recoveredEpoch = controller.schedulerSnapshot.epoch
        center.post(name: .NSSystemClockDidChange, object: nil)
        try await eventually {
            await MainActor.run { controller.schedulerSnapshot.epoch != recoveredEpoch }
        }
        await buffer.enqueue(.init(
            notificationIdentifier: record.notificationIdentifier,
            briefID: brief.id
        ))

        XCTAssertNotNil(try store.deliveryRecords().first?.responseReceivedAt)
        XCTAssertEqual(windowRecorder.count, 1)
        lifecycle.close(defaultCenter: center)
        await controller.shutdown()
    }

    func testNotificationRouteRejectsMismatchedPersistedBriefWithoutRecordingOrOpening() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let persistedBrief = DeterministicBriefingEngine().generatePreview(revision: 51)
        let routedBrief = DeterministicBriefingEngine().generatePreview(revision: 52)
        try store.record(persistedBrief)
        try store.record(routedBrief)
        let input = NotificationDeliveryInput(
            occurrenceKey: "notification-mismatch-fixture",
            briefID: persistedBrief.id,
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: persistedBrief.itemCount,
            sourceCount: persistedBrief.sections.count,
            privacyMode: .minimal
        )
        let (_, record) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: P5AuthorizedNotificationClient(),
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )
        let buffer = NotificationRouteBuffer()
        let windowRecorder = P5MainWindowOpenRecorder()
        let originalSelection = model.selection
        let originalBriefID = model.brief.id
        await controller.activate(
            lifecycle: nil,
            notificationBuffer: buffer,
            openMainWindow: { windowRecorder.record() }
        )

        await buffer.enqueue(.init(
            notificationIdentifier: record.notificationIdentifier,
            briefID: routedBrief.id
        ))

        XCTAssertEqual(model.selection, originalSelection)
        XCTAssertEqual(model.brief.id, originalBriefID)
        XCTAssertEqual(windowRecorder.count, 0)
        XCTAssertNil(try store.deliveryRecords().first?.responseReceivedAt)
        await controller.shutdown()
    }

    func testNotificationRouteRejectsMissingPersistedBriefWithoutRecordingOrOpening() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let missingBriefID = "brief-missing"
        let input = NotificationDeliveryInput(
            occurrenceKey: "notification-missing-brief-fixture",
            briefID: missingBriefID,
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: 1,
            sourceCount: 1,
            privacyMode: .minimal
        )
        let (_, record) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: P5AuthorizedNotificationClient(),
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )
        let buffer = NotificationRouteBuffer()
        let windowRecorder = P5MainWindowOpenRecorder()
        let originalSelection = model.selection
        let originalBriefID = model.brief.id
        await controller.activate(
            lifecycle: nil,
            notificationBuffer: buffer,
            openMainWindow: { windowRecorder.record() }
        )

        await buffer.enqueue(.init(
            notificationIdentifier: record.notificationIdentifier,
            briefID: missingBriefID
        ))

        XCTAssertEqual(model.selection, originalSelection)
        XCTAssertEqual(model.brief.id, originalBriefID)
        XCTAssertEqual(windowRecorder.count, 0)
        XCTAssertNil(try store.deliveryRecords().first?.responseReceivedAt)
        await controller.shutdown()
    }

    func testManualClaimBlocksUpdateBeforeDeliveryBecomesBusy() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let persistence = P5BlockingSchedulePersistence(suspendNextClaim: true)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            schedulePersistence: persistence,
            isTesting: true
        )

        let runTask = Task { await controller.runManualNow() }
        try await eventually { await persistence.hasSuspendedClaim() }

        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let manualUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(manualUpdatePrepared)

        await persistence.resumeClaim(.terminal)
        guard case .failed(reasonCode: "manual_occurrence_not_claimed") = await runTask.value else {
            return XCTFail("Expected the suspended claim to finish as not claimed")
        }
        XCTAssertFalse(controller.hasUpdateBlockingWork)
        await controller.shutdown()
    }

    func testActivationBlocksUpdateAcrossSuspendedAuthorizationRefresh() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let notificationClient = P5SuspendedNotificationClient()
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: notificationClient,
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )
        let buffer = NotificationRouteBuffer()
        let activationTask = Task {
            await controller.activate(lifecycle: nil, notificationBuffer: buffer, openMainWindow: { })
        }
        try await eventually { await notificationClient.hasSuspendedAuthorizationRead() }

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let activationUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(activationUpdatePrepared)

        await notificationClient.resumeAuthorizationRead()
        await activationTask.value
        XCTAssertFalse(controller.hasUpdateBlockingWork)
        await controller.shutdown()
    }

    func testLifecycleEventBodyBlocksUpdateAcrossSuspendedReconcile() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let persistence = P5BlockingSchedulePersistence(suspendNextLoad: true)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: P5AuthorizedNotificationClient(),
            launchClient: P5NotRegisteredLaunchClient(),
            schedulePersistence: persistence,
            isTesting: true
        )
        let center = NotificationCenter()
        let lifecycle = AppLifecycleEventSource(defaultCenter: center)
        await controller.activate(
            lifecycle: lifecycle,
            notificationBuffer: NotificationRouteBuffer(),
            openMainWindow: { }
        )
        try await eventually { await persistence.hasSuspendedLoad() }

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let lifecycleUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(lifecycleUpdatePrepared)

        await persistence.resumeLoad()
        try await eventually {
            let counts = await persistence.operationCounts()
            let hasBlockingWork = await MainActor.run { controller.hasUpdateBlockingWork }
            return counts[3] == 1 && !hasBlockingWork
        }
        lifecycle.close(defaultCenter: center)
        await controller.shutdown()
    }

    func testQueuedScheduleUpdateBlocksInstallUntilSchedulerReconcileReturns() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let persistence = P5BlockingSchedulePersistence(suspendNextLoad: true)
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            schedulePersistence: persistence,
            isTesting: true
        )

        controller.updateSchedule { $0.enabled.toggle() }
        try await eventually { await persistence.hasSuspendedLoad() }

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let scheduleUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(scheduleUpdatePrepared)

        await persistence.resumeLoad()
        try await eventually { await MainActor.run { !controller.hasUpdateBlockingWork } }
        await controller.shutdown()
    }

    func testLaunchAtLoginActionBlocksInstallUntilSystemMutationReturns() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let launchClient = P5SuspendedLaunchClient()
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            launchClient: launchClient,
            isTesting: false
        )

        controller.setLaunchAtLogin(true)
        try await eventually { await launchClient.hasSuspendedRegistration() }

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let launchUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(launchUpdatePrepared)

        await launchClient.resumeRegistration()
        try await eventually { await MainActor.run { !controller.hasUpdateBlockingWork } }
        XCTAssertEqual(controller.launchSnapshot.state, .enabled)
        await controller.shutdown()
    }

    func testTestNotificationActionBlocksInstallUntilSubmissionReturns() async throws {
        let store = try LocalStore(inMemory: true)
        let settings = try store.notificationDeliverySettings()
        settings.enabledPreference = true
        settings.lastObservedAuthorization = .authorized
        var schedule = try store.primaryBriefSchedule()
        schedule.delivery.notificationsEnabled = true
        try store.savePrimaryBriefSchedule(schedule)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let notificationClient = P5SuspendedNotificationClient()
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            notificationClient: notificationClient,
            launchClient: P5NotRegisteredLaunchClient(),
            isTesting: true
        )

        controller.sendTestNotification()
        try await eventually { await notificationClient.hasSuspendedAuthorizationRead() }

        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let testNotificationUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(testNotificationUpdatePrepared)

        await notificationClient.resumeAuthorizationRead()
        try await eventually { await MainActor.run { !controller.hasUpdateBlockingWork } }
        let submissionCount = await notificationClient.submissionCount
        XCTAssertEqual(submissionCount, 1)
        await controller.shutdown()
    }

    func testCanceledRunRemainsUpdateBlockingUntilCoordinatorAndOccurrenceTerminalize() async throws {
        let store = try LocalStore(inMemory: true)
        try seedExistingFeedEvidence(store)
        let feedClient = P5SuspendedFeedClient()
        let model = try AppModel(store: store, feedClient: feedClient)
        let controller = try XCTUnwrap(model.p5Controller)
        controller.updateSchedule {
            $0.delivery.refreshFeeds = true
            $0.delivery.refreshSelectedSlackWorkspaces = false
            $0.delivery.notificationsEnabled = false
            $0.delivery.allowScheduledOllama = false
        }
        try await eventually { await MainActor.run { !controller.hasUpdateBlockingWork } }

        let runTask = Task { await controller.runManualNow() }
        try await eventually { await feedClient.isSuspended() }
        let cancellationDisposition = await controller.cancelCurrentRun(reasonCode: "test_cancel_for_update")
        XCTAssertEqual(cancellationDisposition, .accepted)

        XCTAssertTrue(controller.isBusy)
        XCTAssertTrue(controller.hasUpdateBlockingWork)
        let cancellationUpdatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertFalse(cancellationUpdatePrepared)

        await feedClient.resolve()
        guard case .canceled(reasonCode: "test_cancel_for_update") = await runTask.value else {
            return XCTFail("Expected the original run task to unwind with the explicit cancellation")
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.hasUpdateBlockingWork)
        XCTAssertEqual(try store.scheduledBriefingRuns().first?.stateRaw, ScheduledRunState.canceled.rawValue)
        let occurrences = try store.container.mainContext.fetch(FetchDescriptor<StoredScheduleOccurrence>())
        XCTAssertEqual(occurrences.first?.state, .canceled)

        let updatePreparedAfterCancellation = await controller.prepareForUpdateInstallation()
        XCTAssertTrue(updatePreparedAfterCancellation)
        await controller.resumeAfterUpdateInstallationAbort()
        await controller.shutdown()
    }

    func testShutdownDuringPreparedUpdateDoesNotReenterSchedulerPersistence() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store, feedClient: P5DisabledFeedClient())
        let persistence = P5BlockingSchedulePersistence()
        let controller = try P5DeliveryController(
            model: model,
            store: store,
            schedulePersistence: persistence,
            isTesting: true
        )

        let updatePrepared = await controller.prepareForUpdateInstallation()
        XCTAssertTrue(updatePrepared)
        let countsBeforeShutdown = await persistence.operationCounts()
        let snapshotBeforeShutdown = controller.schedulerSnapshot

        await controller.shutdown()

        XCTAssertTrue(controller.updateInstallationInProgress)
        XCTAssertEqual(controller.schedulerSnapshot, snapshotBeforeShutdown)
        let countsAfterShutdown = await persistence.operationCounts()
        XCTAssertEqual(countsAfterShutdown, countsBeforeShutdown)

        await controller.resumeAfterUpdateInstallationAbort()
        XCTAssertFalse(controller.updateInstallationInProgress)
        await controller.shutdown()
    }

    private func seedExistingFeedEvidence(_ store: LocalStore) throws {
        let now = Date()
        let url = try XCTUnwrap(URL(string: "https://example.com/loki-feed.xml"))
        let articleURL = try XCTUnwrap(URL(string: "https://example.com/research"))
        let subscription = FeedSubscription(
            id: "p5-fixture-feed",
            title: "P5 Fixture Feed",
            canonicalURL: url,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: now,
            lastSuccessfulAt: now,
            lastHTTPStatus: 200,
            eTag: nil,
            lastModified: nil,
            state: .connected,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: now,
            updatedAt: now
        )
        let entry = NormalizedFeedEntry(
            id: "p5-fixture-entry",
            identity: .init(value: articleURL.absoluteString, basis: .canonicalURL),
            subscriptionID: subscription.id,
            sourceTitle: subscription.title,
            title: "Deterministic scheduled delivery fixture",
            summary: "A bounded non-private fixture proves the production coordinator path.",
            canonicalURL: articleURL,
            author: nil,
            publishedAt: now.addingTimeInterval(-60),
            updatedAt: nil,
            retrievedAt: now,
            originalPosition: 0,
            provenance: .init(subscriptionID: subscription.id, feedURL: url, format: .rss2, upstreamIdentifier: "p5-fixture", retrievedAt: now, originalPosition: 0)
        )
        try store.persistFeedFetchResult(.init(
            subscription: subscription,
            entries: [entry],
            record: .init(id: "p5-fixture-fetch", subscriptionID: subscription.id, traceID: "p5-fixture-trace", attemptedAt: now, completedAt: now, httpStatus: 200, responseByteCount: 128, parsedEntryCount: 1, finalURL: url, eTag: nil, lastModified: nil, wasNotModified: false),
            warnings: []
        ), settings: try store.p2Settings())
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for P5 operation state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
