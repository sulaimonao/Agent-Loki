import XCTest
@testable import LokiBrief

private actor SchedulerTestClock: SchedulerClock {
    private var current: Date
    private(set) var sleepCallCount = 0
    private(set) var cancellationCount = 0

    init(now: Date) { current = now }

    func now() async -> Date { current }

    func setNow(_ date: Date) { current = date }

    func sleep(until deadline: Date, tolerance: Duration?) async throws {
        sleepCallCount += 1
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            cancellationCount += 1
            throw error
        }
    }
}

private actor SchedulerTestPersistence: SchedulePersisting {
    var schedule: BriefSchedule
    private(set) var states: [ScheduleSlotKey: ScheduleOccurrenceState] = [:]
    private(set) var interruptionRecoveryCount = 0

    init(schedule: BriefSchedule) { self.schedule = schedule }

    func loadPrimarySchedule() async throws -> BriefSchedule { schedule }
    func save(_ schedule: BriefSchedule, at date: Date) async throws { self.schedule = schedule }
    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState? { states[occurrence.slotKey] }

    func claim(_ occurrence: ScheduleOccurrence, trigger: ScheduleActivationTrigger, at date: Date) async throws -> ScheduleClaimDisposition {
        switch states[occurrence.slotKey] {
        case .succeeded?: return .alreadySucceeded
        case .claimed?, .pending?: return .alreadyClaimed
        case .skipped?, .canceled?: return .terminal
        case .failed?, .interrupted?, nil:
            states[occurrence.slotKey] = .claimed
            return .claimed
        }
    }

    func mark(_ occurrence: ScheduleOccurrence, state: ScheduleOccurrenceState, reasonCode: String, at date: Date) async throws {
        if states[occurrence.slotKey] != .succeeded || state == .succeeded {
            states[occurrence.slotKey] = state
        }
    }

    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int {
        interruptionRecoveryCount += 1
        var changed = 0
        for (key, state) in states where state == .pending || state == .claimed {
            states[key] = .interrupted
            changed += 1
        }
        return changed
    }
}

private actor BlockingScheduleLoadPersistence: SchedulePersisting {
    private let schedule: BriefSchedule
    private var loadContinuation: CheckedContinuation<BriefSchedule, Never>?
    private(set) var claimCount = 0

    init(schedule: BriefSchedule) { self.schedule = schedule }

    func loadPrimarySchedule() async throws -> BriefSchedule {
        await withCheckedContinuation { loadContinuation = $0 }
    }

    func resolveLoad() {
        loadContinuation?.resume(returning: schedule)
        loadContinuation = nil
    }

    func hasSuspendedLoad() -> Bool { loadContinuation != nil }
    func save(_ schedule: BriefSchedule, at date: Date) async throws { }
    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState? { nil }
    func claim(_ occurrence: ScheduleOccurrence, trigger: ScheduleActivationTrigger, at date: Date) async throws -> ScheduleClaimDisposition {
        claimCount += 1
        return .claimed
    }
    func mark(_ occurrence: ScheduleOccurrence, state: ScheduleOccurrenceState, reasonCode: String, at date: Date) async throws { }
    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int { 0 }
}

private actor BlockingScheduleClaimPersistence: SchedulePersisting {
    private let schedule: BriefSchedule
    private var states: [ScheduleSlotKey: ScheduleOccurrenceState] = [:]
    private var firstClaimContinuation: CheckedContinuation<ScheduleClaimDisposition, Never>?
    private var firstClaimOccurrence: ScheduleOccurrence?
    private var claimsInFlight = 0
    private(set) var claimCount = 0
    private(set) var maximumConcurrentClaimCount = 0

    init(schedule: BriefSchedule) { self.schedule = schedule }

    func loadPrimarySchedule() async throws -> BriefSchedule { schedule }
    func save(_ schedule: BriefSchedule, at date: Date) async throws { }
    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState? { states[occurrence.slotKey] }

    func claim(
        _ occurrence: ScheduleOccurrence,
        trigger: ScheduleActivationTrigger,
        at date: Date
    ) async throws -> ScheduleClaimDisposition {
        claimCount += 1
        claimsInFlight += 1
        maximumConcurrentClaimCount = max(maximumConcurrentClaimCount, claimsInFlight)
        if claimCount == 1 {
            firstClaimOccurrence = occurrence
            let disposition = await withCheckedContinuation { firstClaimContinuation = $0 }
            claimsInFlight -= 1
            return disposition
        }
        defer { claimsInFlight -= 1 }
        switch states[occurrence.slotKey] {
        case .succeeded?: return .alreadySucceeded
        case .claimed?, .pending?: return .alreadyClaimed
        case .skipped?, .canceled?: return .terminal
        case .failed?, .interrupted?, nil:
            states[occurrence.slotKey] = .claimed
            return .claimed
        }
    }

    func mark(
        _ occurrence: ScheduleOccurrence,
        state: ScheduleOccurrenceState,
        reasonCode: String,
        at date: Date
    ) async throws {
        if states[occurrence.slotKey] != .succeeded || state == .succeeded {
            states[occurrence.slotKey] = state
        }
    }

    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int { 0 }

    func hasSuspendedClaim() -> Bool { firstClaimContinuation != nil }
    func suspendedOccurrence() -> ScheduleOccurrence? { firstClaimOccurrence }

    func resolveFirstClaim(_ disposition: ScheduleClaimDisposition = .claimed) {
        if disposition == .claimed, let firstClaimOccurrence {
            states[firstClaimOccurrence.slotKey] = .claimed
        }
        firstClaimContinuation?.resume(returning: disposition)
        firstClaimContinuation = nil
    }
}

private actor SchedulerTestFiringDelegate: ScheduleFiringDelegate {
    private(set) var contexts: [ScheduleFiringContext] = []
    private(set) var cancellationReasons: [String] = []
    var outcome: ScheduleFiringOutcome = .succeeded(reasonCode: "fixture_success")
    private let cancellationDisposition: ScheduleFiringCancellationDisposition

    init(cancellationDisposition: ScheduleFiringCancellationDisposition = .accepted) {
        self.cancellationDisposition = cancellationDisposition
    }

    func fire(_ context: ScheduleFiringContext) async -> ScheduleFiringOutcome {
        contexts.append(context)
        return outcome
    }

    func cancelActiveFiring(reasonCode: String) async -> ScheduleFiringCancellationDisposition {
        cancellationReasons.append(reasonCode)
        return cancellationDisposition
    }
}

private actor BlockingSchedulerTestFiringDelegate: ScheduleFiringDelegate {
    private(set) var contexts: [ScheduleFiringContext] = []
    private(set) var cancellationReasons: [String] = []
    private var continuation: CheckedContinuation<ScheduleFiringOutcome, Never>?
    private let cancellationDisposition: ScheduleFiringCancellationDisposition

    init(cancellationDisposition: ScheduleFiringCancellationDisposition = .accepted) {
        self.cancellationDisposition = cancellationDisposition
    }

    func fire(_ context: ScheduleFiringContext) async -> ScheduleFiringOutcome {
        contexts.append(context)
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancelActiveFiring(reasonCode: String) async -> ScheduleFiringCancellationDisposition {
        cancellationReasons.append(reasonCode)
        return cancellationDisposition
    }

    func resolve(_ outcome: ScheduleFiringOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor SchedulerCompletionProbe {
    private(set) var completed = false
    func markCompleted() { completed = true }
}

final class BriefSchedulerLifecycleTests: XCTestCase, @unchecked Sendable {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testStartRecoversInterruptedStateAndArmsOneWaiter() async throws {
        let now = date(2026, 7, 16, 7, 0)
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 8, minute: 0))
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: now)
        let firing = SchedulerTestFiringDelegate()
        let scheduler = makeScheduler(persistence: persistence, clock: clock, firing: firing)

        await scheduler.start()
        try await eventually { await clock.sleepCallCount == 1 }

        let snapshot = await scheduler.snapshot()
        let recoveryCount = await persistence.interruptionRecoveryCount
        XCTAssertEqual(snapshot.state, .waiting)
        XCTAssertEqual(recoveryCount, 1)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testSettingsChangeCancelsOldWaiterAndArmsExactlyOneReplacement() async throws {
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 8, minute: 0))
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate()
        let scheduler = makeScheduler(persistence: persistence, clock: clock, firing: firing)
        await scheduler.start()
        try await eventually { await clock.sleepCallCount == 1 }

        await scheduler.scheduleChanged()
        try await eventually {
            let sleepCalls = await clock.sleepCallCount
            let cancellations = await clock.cancellationCount
            return sleepCalls == 2 && cancellations >= 1
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.state, .waiting)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testSleepCancelsWaitAndWakeRunsOnlyOneCatchUp() async throws {
        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 6, minute: 0),
            catchUpWindow: .init(maximumAge: 6 * 60 * 60)
        )
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 5, 30))
        let firing = SchedulerTestFiringDelegate()
        let scheduler = makeScheduler(persistence: persistence, clock: clock, firing: firing)
        await scheduler.start()
        try await eventually { await clock.sleepCallCount == 1 }

        await scheduler.handle(.willSleep)
        await clock.setNow(date(2026, 7, 16, 7, 10))
        await scheduler.handle(.didWake)
        try await eventually { await firing.contexts.count == 1 }

        let firstTrigger = await firing.contexts.first?.trigger
        XCTAssertEqual(firstTrigger, .catchUpAfterWake)
        await scheduler.handle(.didWake)
        try await Task.sleep(for: .milliseconds(20))
        let contextCount = await firing.contexts.count
        XCTAssertEqual(contextCount, 1)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testLowPowerModeDefersAndRearmsAfterPowerReturns() async throws {
        var schedule = BriefSchedule(enabled: true, localTime: .init(hour: 8, minute: 0))
        schedule.delivery.pauseInLowPowerMode = true
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate()
        let scheduler = makeScheduler(persistence: persistence, clock: clock, firing: firing)
        await scheduler.start()
        try await eventually { await clock.sleepCallCount == 1 }

        await scheduler.handle(.lowPowerModeChanged(isEnabled: true))
        let deferredSnapshot = await scheduler.snapshot()
        XCTAssertEqual(deferredSnapshot.state, .deferredForLowPower)
        await scheduler.handle(.lowPowerModeChanged(isEnabled: false))
        try await eventually { await clock.sleepCallCount == 2 }
        let waitingSnapshot = await scheduler.snapshot()
        XCTAssertEqual(waitingSnapshot.state, .waiting)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testDisabledScheduleDoesNotArmWaiter() async {
        let persistence = SchedulerTestPersistence(schedule: BriefSchedule(enabled: false))
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate()
        let scheduler = makeScheduler(persistence: persistence, clock: clock, firing: firing)

        await scheduler.start()

        let snapshot = await scheduler.snapshot()
        let sleepCalls = await clock.sleepCallCount
        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertEqual(sleepCalls, 0)
    }

    func testInitialLowPowerStatePrecedesLaunch() {
        XCTAssertEqual(
            AppLifecycleEventSource.initialEvents(isLowPowerModeEnabled: true),
            [.lowPowerModeChanged(isEnabled: true), .launched]
        )
    }

    func testSettingsChangeDuringActiveFireStillTerminalizesClaimedOccurrence() async throws {
        let now = date(2026, 7, 16, 7, 0)
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: now)
        let firing = BlockingSchedulerTestFiringDelegate()
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await firing.contexts.count == 1 }
        let firedOccurrence = await firing.contexts.first?.occurrence
        let occurrence = try XCTUnwrap(firedOccurrence)

        await scheduler.scheduleChanged()
        await firing.resolve(.succeeded(reasonCode: "fixture_success"))
        await startTask.value
        try await eventually { await persistence.states[occurrence.slotKey] == .succeeded }

        let snapshot = await scheduler.snapshot()
        let fireCount = await firing.contexts.count
        XCTAssertNil(snapshot.activeOccurrence)
        XCTAssertEqual(fireCount, 1)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testSleepDuringActiveFireKeepsInterruptedTruthAfterLateSuccess() async throws {
        let now = date(2026, 7, 16, 7, 0)
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: now)
        let firing = BlockingSchedulerTestFiringDelegate()
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await firing.contexts.count == 1 }
        let firedOccurrence = await firing.contexts.first?.occurrence
        let occurrence = try XCTUnwrap(firedOccurrence)

        await scheduler.handle(.willSleep)
        await firing.resolve(.succeeded(reasonCode: "late_success"))
        await startTask.value

        let terminalState = await persistence.states[occurrence.slotKey]
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(terminalState, .interrupted)
        XCTAssertNil(snapshot.activeOccurrence)
    }

    func testStopDuringAlreadyTerminalFirePreservesSuccessWithoutRearming() async throws {
        let now = date(2026, 7, 16, 7, 0)
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = SchedulerTestPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: now)
        let firing = BlockingSchedulerTestFiringDelegate(cancellationDisposition: .alreadyTerminal)
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await firing.contexts.count == 1 }
        let firedOccurrence = await firing.contexts.first?.occurrence
        let occurrence = try XCTUnwrap(firedOccurrence)

        await scheduler.stop(reasonCode: "test_stop_after_commit", cancelActive: true)
        await firing.resolve(.succeeded(reasonCode: "fixture_success"))
        await startTask.value

        let terminalState = await persistence.states[occurrence.slotKey]
        let snapshot = await scheduler.snapshot()
        let sleepCount = await clock.sleepCallCount
        XCTAssertEqual(terminalState, .succeeded)
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertNil(snapshot.activeOccurrence)
        XCTAssertNil(snapshot.nextOccurrence)
        XCTAssertEqual(sleepCount, 0)
    }

    func testStopDuringSuspendedReconcileCannotClaimFireOrRearm() async throws {
        let persistence = BlockingScheduleLoadPersistence(
            schedule: BriefSchedule(enabled: true, localTime: .init(hour: 8, minute: 0))
        )
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate()
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await persistence.hasSuspendedLoad() }
        await scheduler.stop(reasonCode: "test_stop_during_load", cancelActive: true)
        await persistence.resolveLoad()
        await startTask.value

        let snapshot = await scheduler.snapshot()
        let claimCount = await persistence.claimCount
        let fireCount = await firing.contexts.count
        let sleepCount = await clock.sleepCallCount
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(fireCount, 0)
        XCTAssertEqual(sleepCount, 0)
    }

    func testSleepDuringSuspendedClaimInterruptsClaimWithoutStartingWork() async throws {
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = BlockingScheduleClaimPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate(cancellationDisposition: .alreadyTerminal)
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await persistence.hasSuspendedClaim() }
        let suspendedOccurrence = await persistence.suspendedOccurrence()
        let occurrence = try XCTUnwrap(suspendedOccurrence)

        await scheduler.handle(.willSleep)
        await persistence.resolveFirstClaim()
        await startTask.value

        let snapshot = await scheduler.snapshot()
        let terminalState = try await persistence.state(for: occurrence)
        let fireCount = await firing.contexts.count
        XCTAssertEqual(snapshot.state, .pausedForSleep)
        XCTAssertNil(snapshot.activeOccurrence)
        XCTAssertNil(snapshot.nextOccurrence)
        XCTAssertEqual(terminalState, .interrupted)
        XCTAssertEqual(fireCount, 0)
    }

    func testClockReconcileDuringSuspendedClaimSerializesClaimOwnership() async throws {
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = BlockingScheduleClaimPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate(cancellationDisposition: .alreadyTerminal)
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await persistence.hasSuspendedClaim() }
        let suspendedOccurrence = await persistence.suspendedOccurrence()
        let firstOccurrence = try XCTUnwrap(suspendedOccurrence)

        await scheduler.handle(.systemClockChanged)
        let deferredClaimCount = await persistence.claimCount
        let deferredMaximumClaims = await persistence.maximumConcurrentClaimCount
        let deferredFireCount = await firing.contexts.count
        XCTAssertEqual(deferredClaimCount, 1)
        XCTAssertEqual(deferredMaximumClaims, 1)
        XCTAssertEqual(deferredFireCount, 0)

        await persistence.resolveFirstClaim()
        await startTask.value
        try await eventually { await firing.contexts.count == 1 }

        let firedContexts = await firing.contexts
        let finalState = try await persistence.state(for: firstOccurrence)
        let finalClaimCount = await persistence.claimCount
        let finalMaximumClaims = await persistence.maximumConcurrentClaimCount
        XCTAssertEqual(finalClaimCount, 2)
        XCTAssertEqual(finalMaximumClaims, 1)
        XCTAssertEqual(Set(firedContexts.map(\.occurrence.slotKey)).count, 1)
        XCTAssertEqual(finalState, .succeeded)
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    func testUpdatePreparationClosesAdmissionAndWaitsForSuspendedScheduledClaimToTerminalize() async throws {
        let schedule = BriefSchedule(enabled: true, localTime: .init(hour: 6, minute: 0))
        let persistence = BlockingScheduleClaimPersistence(schedule: schedule)
        let clock = SchedulerTestClock(now: date(2026, 7, 16, 7, 0))
        let firing = SchedulerTestFiringDelegate(cancellationDisposition: .alreadyTerminal)
        let scheduler = BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )

        let startTask = Task { await scheduler.start() }
        try await eventually { await persistence.hasSuspendedClaim() }
        let pendingOccurrence = await persistence.suspendedOccurrence()
        let suspendedOccurrence = try XCTUnwrap(pendingOccurrence)
        let completion = SchedulerCompletionProbe()
        let prepareTask = Task {
            await scheduler.prepareForUpdateInstallation()
            await completion.markCompleted()
        }

        try await Task.sleep(for: .milliseconds(20))
        let completedWhileClaimSuspended = await completion.completed
        XCTAssertFalse(completedWhileClaimSuspended)

        await persistence.resolveFirstClaim()
        await prepareTask.value
        await startTask.value

        let completedAfterTerminalPersistence = await completion.completed
        let terminalState = try await persistence.state(for: suspendedOccurrence)
        let snapshot = await scheduler.snapshot()
        let fireCount = await firing.contexts.count
        XCTAssertTrue(completedAfterTerminalPersistence)
        XCTAssertEqual(terminalState, .interrupted)
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertNil(snapshot.activeOccurrence)
        XCTAssertNil(snapshot.nextOccurrence)
        XCTAssertEqual(fireCount, 0)

        await scheduler.start()
        let claimCountWhileClosed = await persistence.claimCount
        XCTAssertEqual(claimCountWhileClosed, 1)
        await scheduler.resumeAfterUpdateInstallationAbort()
        await scheduler.stop(reasonCode: "test_complete", cancelActive: true)
    }

    private func makeScheduler(
        persistence: SchedulerTestPersistence,
        clock: SchedulerTestClock,
        firing: SchedulerTestFiringDelegate
    ) -> BriefScheduler {
        BriefScheduler(
            persistence: persistence,
            firingDelegate: firing,
            clock: clock,
            recurrence: .init(systemTimeZone: { self.utc })
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now >= deadline { XCTFail("Timed out waiting for scheduler state"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
