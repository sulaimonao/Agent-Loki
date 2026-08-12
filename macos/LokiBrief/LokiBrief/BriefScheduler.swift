import Foundation

enum ScheduleFiringOutcome: Equatable, Sendable {
    case succeeded(reasonCode: String)
    case partiallySucceeded(reasonCode: String)
    case canceled(reasonCode: String)
    case failed(reasonCode: String)
    case reauthorizationRequired(reasonCode: String)
    case entitlementRequired(reasonCode: String)
}

enum ScheduleFiringCancellationDisposition: Equatable, Sendable {
    case accepted
    case alreadyTerminal
}

protocol ScheduleFiringDelegate: Sendable {
    func fire(_ context: ScheduleFiringContext) async -> ScheduleFiringOutcome
    func cancelActiveFiring(reasonCode: String) async -> ScheduleFiringCancellationDisposition
}

struct BriefSchedulerSnapshot: Equatable, Sendable {
    let state: BriefScheduleState
    let epoch: UInt64
    let nextOccurrence: ScheduleOccurrence?
    let activeOccurrence: ScheduleOccurrence?
    let reasonCode: String
}

actor BriefScheduler {
    private struct DeferredReconciliation {
        let trigger: ScheduleActivationTrigger
        let evaluateCatchUp: Bool
        let reasonCode: String
    }

    private let persistence: any SchedulePersisting
    private let firingDelegate: any ScheduleFiringDelegate
    private let clock: any SchedulerClock
    private let recurrence: ScheduleRecurrenceCalculator
    private let traceSink: ScheduleTraceSink

    private var waitTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var firingCancellationEpoch: UInt64 = 0
    private var firingOwnershipSequence: UInt64 = 0
    private var firingOwner: UInt64?
    private var deferredReconciliation: DeferredReconciliation?
    private var state: BriefScheduleState = .stopped
    private var nextOccurrence: ScheduleOccurrence?
    private var activeOccurrence: ScheduleOccurrence?
    private var reasonCode = "scheduler_not_started"
    private var isSleeping = false
    private var isUserSessionActive = true
    private var isLowPowerModeEnabled = false
    private var hasRecoveredLaunchState = false
    private var updateInstallationPrepared = false
    private var activeUpdateBlockingOperationTokens: Set<UUID> = []
    private var updateDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistence: any SchedulePersisting,
        firingDelegate: any ScheduleFiringDelegate,
        clock: any SchedulerClock,
        recurrence: ScheduleRecurrenceCalculator = .init(),
        traceSink: @escaping ScheduleTraceSink = { _ in }
    ) {
        self.persistence = persistence
        self.firingDelegate = firingDelegate
        self.clock = clock
        self.recurrence = recurrence
        self.traceSink = traceSink
    }

    func snapshot() -> BriefSchedulerSnapshot {
        .init(
            state: state,
            epoch: epoch,
            nextOccurrence: nextOccurrence,
            activeOccurrence: activeOccurrence,
            reasonCode: reasonCode
        )
    }

    func start() async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        let startEpoch = epoch
        let now = await clock.now()
        if !hasRecoveredLaunchState {
            do {
                let count = try await persistence.markNonterminalOccurrencesInterrupted(at: now)
                guard startEpoch == epoch else { return }
                hasRecoveredLaunchState = true
                emit(
                    .lifecycleReconcile,
                    status: .success,
                    reasonCode: count > 0 ? "interrupted_occurrences_recovered" : "no_interrupted_occurrences",
                    occurrence: nil,
                    count: count,
                    at: now
                )
            } catch {
                state = .failed
                reasonCode = "interruption_recovery_failed"
                emit(.lifecycleReconcile, status: .failed, reasonCode: reasonCode, at: now)
                return
            }
        }
        emit(.schedulerStart, status: .started, reasonCode: "scheduler_start_requested", at: now)
        await reconcile(trigger: .catchUpAfterLaunch, evaluateCatchUp: true, reasonCode: "scheduler_started")
    }

    func scheduleChanged() async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        await reconcile(trigger: .settingsChanged, evaluateCatchUp: false, reasonCode: "schedule_settings_changed")
    }

    func retryMostRecentEligibleOccurrence() async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        await reconcile(trigger: .retry, evaluateCatchUp: true, reasonCode: "schedule_retry_requested")
    }

    func fireManually(trigger: ScheduleActivationTrigger) async {
        guard trigger == .manualRunNow || trigger == .manualTest else { return }
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        let manualEpoch = epoch
        let now = await clock.now()
        do {
            let schedule = try await persistence.loadPrimarySchedule()
            guard manualEpoch == epoch else { return }
            guard let occurrence = try recurrence.mostRecentOccurrence(onOrBefore: now, schedule: schedule)
                ?? recurrence.nextOccurrence(after: now.addingTimeInterval(-1), schedule: schedule)
            else {
                state = .failed
                reasonCode = "manual_occurrence_unavailable"
                return
            }
            await fire(occurrence, trigger: trigger, schedule: schedule)
        } catch {
            state = .failed
            reasonCode = "manual_schedule_calculation_failed"
            emit(.occurrenceFire, status: .failed, reasonCode: reasonCode, at: now)
        }
    }

    func handle(_ event: AppLifecycleEvent) async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        switch event {
        case .launched:
            await start()
        case .willSleep:
            isSleeping = true
            await pauseAndCancelActive(state: .pausedForSleep, reasonCode: "system_will_sleep")
        case .didWake:
            isSleeping = false
            await reconcile(trigger: .catchUpAfterWake, evaluateCatchUp: true, reasonCode: "wake_reconciliation")
        case .systemClockChanged:
            await reconcile(trigger: .systemClockChanged, evaluateCatchUp: true, reasonCode: "system_clock_changed")
        case .systemTimeZoneChanged:
            await reconcile(trigger: .systemTimeZoneChanged, evaluateCatchUp: true, reasonCode: "system_time_zone_changed")
        case let .lowPowerModeChanged(isEnabled):
            isLowPowerModeEnabled = isEnabled
            if isEnabled {
                let schedule = try? await persistence.loadPrimarySchedule()
                if schedule?.delivery.pauseInLowPowerMode == true {
                    await pauseAndCancelActive(state: .deferredForLowPower, reasonCode: "low_power_mode_enabled")
                }
            } else {
                await reconcile(trigger: .lowPowerEnded, evaluateCatchUp: true, reasonCode: "low_power_mode_ended")
            }
        case .userSessionBecameInactive:
            isUserSessionActive = false
            await pauseAndCancelActive(state: .pausedForInactiveSession, reasonCode: "user_session_inactive")
        case .userSessionBecameActive:
            isUserSessionActive = true
            await reconcile(trigger: .userSessionReturned, evaluateCatchUp: true, reasonCode: "user_session_returned")
        case .willTerminate:
            await stop(reasonCode: "application_will_terminate", cancelActive: true)
        }
    }

    func stop(reasonCode: String, cancelActive: Bool) async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        await stopWithoutAdmissionCheck(reasonCode: reasonCode, cancelActive: cancelActive)
    }

    /// Closes scheduler admission, invalidates pending work, and does not return
    /// until every scheduler operation admitted before the close has unwound.
    /// The controller keeps its own update barrier raised while awaiting this
    /// handshake, so no new lifecycle or settings action can cross the boundary.
    func prepareForUpdateInstallation() async {
        guard !updateInstallationPrepared else {
            await waitForUpdateBlockingOperationsToDrain()
            return
        }
        updateInstallationPrepared = true
        await stopWithoutAdmissionCheck(
            reasonCode: "update_installation_preparing",
            cancelActive: false
        )
        await waitForUpdateBlockingOperationsToDrain()
        waitTask?.cancel()
        waitTask = nil
        nextOccurrence = nil
        activeOccurrence = nil
        firingOwner = nil
        deferredReconciliation = nil
        reasonCode = "update_installation_preparing"
        state = .stopped
    }

    func resumeAfterUpdateInstallationAbort() async {
        guard updateInstallationPrepared else { return }
        updateInstallationPrepared = false
        await scheduleChanged()
    }

    private func stopWithoutAdmissionCheck(reasonCode: String, cancelActive: Bool) async {
        epoch &+= 1
        waitTask?.cancel()
        waitTask = nil
        nextOccurrence = nil
        deferredReconciliation = nil
        self.reasonCode = SchedulePrivacy.boundedIdentifier(reasonCode, fallback: "scheduler_stopped")
        state = .stopped
        if cancelActive {
            let disposition = await firingDelegate.cancelActiveFiring(reasonCode: self.reasonCode)
            if disposition == .accepted {
                firingCancellationEpoch &+= 1
                let hadActiveOccurrence = activeOccurrence != nil
                if let activeOccurrence {
                    let now = await clock.now()
                    try? await persistence.mark(
                        activeOccurrence,
                        state: .interrupted,
                        reasonCode: self.reasonCode,
                        at: now
                    )
                }
                activeOccurrence = nil
                if hadActiveOccurrence {
                    firingOwner = nil
                }
            }
        }
        emit(.schedulerStop, status: .success, reasonCode: self.reasonCode, at: await clock.now())
    }

    private func reconcile(
        trigger: ScheduleActivationTrigger,
        evaluateCatchUp: Bool,
        reasonCode: String
    ) async {
        epoch &+= 1
        let currentEpoch = epoch
        waitTask?.cancel()
        waitTask = nil
        nextOccurrence = nil
        let now = await clock.now()
        guard firingOwner == nil, activeOccurrence == nil else {
            if firingOwner != nil {
                deferredReconciliation = .init(
                    trigger: trigger,
                    evaluateCatchUp: evaluateCatchUp,
                    reasonCode: reasonCode
                )
            }
            emit(
                .lifecycleReconcile,
                status: .skipped,
                reasonCode: activeOccurrence == nil
                    ? "occurrence_claim_reconciliation_deferred"
                    : "active_occurrence_reconciliation_deferred",
                occurrence: activeOccurrence,
                at: now
            )
            return
        }

        do {
            let schedule = try await persistence.loadPrimarySchedule()
            guard currentEpoch == epoch else { return }
            guard schedule.enabled else {
                state = .disabled
                self.reasonCode = "schedule_disabled"
                return
            }
            guard !isSleeping else {
                state = .pausedForSleep
                self.reasonCode = "system_sleeping"
                return
            }
            guard isUserSessionActive else {
                state = .pausedForInactiveSession
                self.reasonCode = "user_session_inactive"
                return
            }
            if isLowPowerModeEnabled, schedule.delivery.pauseInLowPowerMode {
                state = .deferredForLowPower
                self.reasonCode = "low_power_mode_deferral"
                emit(.lowPowerDeferral, status: .skipped, reasonCode: self.reasonCode, at: now)
                return
            }

            if evaluateCatchUp,
               let missed = try recurrence.mostRecentOccurrence(onOrBefore: now, schedule: schedule) {
                let isEligible = try await isEligibleForReconciliation(missed)
                guard currentEpoch == epoch else { return }
                if isEligible {
                let decision = recurrence.catchUpDecision(for: missed, schedule: schedule, now: now)
                emit(
                    .catchUpDecision,
                    status: decision.action == .run ? .success : .skipped,
                    reasonCode: decision.reasonCode,
                    occurrence: missed,
                    at: now
                )
                switch decision.action {
                case .run:
                    await fire(missed, trigger: trigger, schedule: schedule)
                    return
                case .skip:
                    try await persistence.mark(
                        missed,
                        state: .skipped,
                        reasonCode: decision.reasonCode,
                        at: now
                    )
                case .none:
                    break
                }
                }
            }

            guard currentEpoch == epoch else { return }
            guard let next = try recurrence.nextOccurrence(after: now, schedule: schedule) else {
                state = .failed
                self.reasonCode = "next_occurrence_unavailable"
                emit(.nextOccurrence, status: .failed, reasonCode: self.reasonCode, at: now)
                return
            }
            nextOccurrence = next
            state = .waiting
            self.reasonCode = reasonCode
            emit(.nextOccurrence, status: .success, reasonCode: "next_occurrence_calculated", occurrence: next, at: now)
            armWait(for: next, schedule: schedule, epoch: currentEpoch)
        } catch ScheduleCalculationFailure.disabled {
            state = .disabled
            self.reasonCode = "schedule_disabled"
        } catch {
            state = .failed
            self.reasonCode = "schedule_reconciliation_failed"
            emit(.lifecycleReconcile, status: .failed, reasonCode: self.reasonCode, at: now)
        }
    }

    private func armWait(for occurrence: ScheduleOccurrence, schedule: BriefSchedule, epoch: UInt64) {
        let clock = self.clock
        waitTask = Task { [weak self] in
            do {
                try await clock.sleep(until: occurrence.resolvedExecutionDate, tolerance: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.timerFired(occurrence, schedule: schedule, epoch: epoch)
            } catch is CancellationError {
                return
            } catch {
                await self?.timerFailed(epoch: epoch)
            }
        }
    }

    private func timerFired(_ occurrence: ScheduleOccurrence, schedule: BriefSchedule, epoch: UInt64) async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        guard epoch == self.epoch,
              nextOccurrence?.key == occurrence.key,
              !isSleeping,
              isUserSessionActive,
              !(isLowPowerModeEnabled && schedule.delivery.pauseInLowPowerMode)
        else { return }
        waitTask = nil
        nextOccurrence = nil
        await fire(occurrence, trigger: .scheduled, schedule: schedule)
    }

    private func timerFailed(epoch: UInt64) async {
        guard let operationToken = beginUpdateBlockingOperation() else { return }
        defer { finishUpdateBlockingOperation(operationToken) }
        guard epoch == self.epoch else { return }
        waitTask = nil
        state = .failed
        reasonCode = "scheduler_clock_sleep_failed"
        emit(.schedulerStop, status: .failed, reasonCode: reasonCode, at: await clock.now())
    }

    private func fire(
        _ occurrence: ScheduleOccurrence,
        trigger: ScheduleActivationTrigger,
        schedule: BriefSchedule
    ) async {
        guard firingOwner == nil, activeOccurrence == nil else {
            emit(
                .occurrenceFire,
                status: .skipped,
                reasonCode: "occurrence_firing_already_owned",
                occurrence: occurrence,
                at: await clock.now()
            )
            return
        }
        firingOwnershipSequence &+= 1
        let owner = firingOwnershipSequence
        firingOwner = owner
        let firingEpoch = epoch
        let cancellationEpoch = firingCancellationEpoch
        let now = await clock.now()
        guard firingOwner == owner,
              firingEpoch == epoch,
              cancellationEpoch == firingCancellationEpoch
        else {
            _ = await releaseFiringOwner(owner)
            return
        }
        do {
            let disposition = try await persistence.claim(occurrence, trigger: trigger, at: now)
            emit(
                .occurrenceClaim,
                status: disposition == .claimed ? .success : .skipped,
                reasonCode: "occurrence_claim_\(disposition.rawValue)",
                occurrence: occurrence,
                at: now
            )
            guard disposition == .claimed else {
                let resumedDeferredReconciliation = await releaseFiringOwner(owner)
                if !resumedDeferredReconciliation, firingEpoch == epoch {
                    await reconcile(trigger: .scheduled, evaluateCatchUp: false, reasonCode: "occurrence_already_handled")
                }
                return
            }
            guard firingOwner == owner,
                  firingEpoch == epoch,
                  cancellationEpoch == firingCancellationEpoch
            else {
                try? await persistence.mark(
                    occurrence,
                    state: .interrupted,
                    reasonCode: "occurrence_claim_invalidated_before_fire",
                    at: await clock.now()
                )
                _ = await releaseFiringOwner(owner)
                return
            }
            state = .firing
            reasonCode = "occurrence_firing"
            activeOccurrence = occurrence
            emit(.occurrenceFire, status: .started, reasonCode: reasonCode, occurrence: occurrence, at: now)

            let outcome = await firingDelegate.fire(.init(
                occurrence: occurrence,
                trigger: trigger,
                schedulerEpoch: firingEpoch
            ))
            guard firingOwner == owner,
                  cancellationEpoch == firingCancellationEpoch,
                  activeOccurrence?.slotKey == occurrence.slotKey
            else { return }
            activeOccurrence = nil
            let completionDate = await clock.now()
            let persistenceResult: (ScheduleOccurrenceState, String, ScheduleTraceStatus)
            switch outcome {
            case let .succeeded(code):
                persistenceResult = (.succeeded, code, .success)
            case let .partiallySucceeded(code):
                persistenceResult = (.succeeded, code, .degraded)
            case let .canceled(code):
                persistenceResult = (.canceled, code, .skipped)
            case let .failed(code), let .reauthorizationRequired(code), let .entitlementRequired(code):
                persistenceResult = (.failed, code, .failed)
            }
            try await persistence.mark(
                occurrence,
                state: persistenceResult.0,
                reasonCode: persistenceResult.1,
                at: completionDate
            )
            emit(
                .occurrenceFire,
                status: persistenceResult.2,
                reasonCode: persistenceResult.1,
                occurrence: occurrence,
                at: completionDate
            )
            guard firingOwner == owner,
                  cancellationEpoch == firingCancellationEpoch
            else { return }
            let resumedDeferredReconciliation = await releaseFiringOwner(owner)
            if !resumedDeferredReconciliation, firingEpoch == epoch {
                await reconcile(trigger: .scheduled, evaluateCatchUp: false, reasonCode: "occurrence_finished")
            }
        } catch {
            guard firingOwner == owner else { return }
            if activeOccurrence?.slotKey == occurrence.slotKey {
                activeOccurrence = nil
            }
            if firingEpoch == epoch, cancellationEpoch == firingCancellationEpoch {
                state = .failed
                reasonCode = "occurrence_persistence_failed"
                emit(.occurrenceFire, status: .failed, reasonCode: reasonCode, occurrence: occurrence, at: await clock.now())
            }
            _ = await releaseFiringOwner(owner)
        }
    }

    private func pauseAndCancelActive(state: BriefScheduleState, reasonCode: String) async {
        epoch &+= 1
        waitTask?.cancel()
        waitTask = nil
        nextOccurrence = nil
        deferredReconciliation = nil
        self.state = state
        self.reasonCode = reasonCode
        let disposition = await firingDelegate.cancelActiveFiring(reasonCode: reasonCode)
        if disposition == .accepted {
            firingCancellationEpoch &+= 1
            let hadActiveOccurrence = activeOccurrence != nil
            if let activeOccurrence {
                try? await persistence.mark(
                    activeOccurrence,
                    state: .interrupted,
                    reasonCode: reasonCode,
                    at: await clock.now()
                )
            }
            activeOccurrence = nil
            if hadActiveOccurrence {
                firingOwner = nil
            }
        }
        emit(.lifecycleReconcile, status: .degraded, reasonCode: reasonCode, at: await clock.now())
    }

    /// Releases the single claim/fire owner and replays the newest reconciliation
    /// request that arrived while a persistence claim was suspended.
    @discardableResult
    private func releaseFiringOwner(_ owner: UInt64) async -> Bool {
        guard firingOwner == owner else { return false }
        firingOwner = nil
        guard activeOccurrence == nil, let deferredReconciliation else { return false }
        self.deferredReconciliation = nil
        await reconcile(
            trigger: deferredReconciliation.trigger,
            evaluateCatchUp: deferredReconciliation.evaluateCatchUp,
            reasonCode: deferredReconciliation.reasonCode
        )
        return true
    }

    private func isEligibleForReconciliation(_ occurrence: ScheduleOccurrence) async throws -> Bool {
        guard let existing = try await persistence.state(for: occurrence) else { return true }
        switch existing {
        case .failed, .interrupted: return true
        case .pending, .claimed, .succeeded, .skipped, .canceled: return false
        }
    }

    private func beginUpdateBlockingOperation() -> UUID? {
        guard !updateInstallationPrepared else { return nil }
        let token = UUID()
        activeUpdateBlockingOperationTokens.insert(token)
        return token
    }

    private func finishUpdateBlockingOperation(_ token: UUID) {
        activeUpdateBlockingOperationTokens.remove(token)
        guard activeUpdateBlockingOperationTokens.isEmpty else { return }
        let waiters = updateDrainWaiters
        updateDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForUpdateBlockingOperationsToDrain() async {
        guard !activeUpdateBlockingOperationTokens.isEmpty else { return }
        await withCheckedContinuation { continuation in
            updateDrainWaiters.append(continuation)
        }
    }

    private func emit(
        _ event: ScheduleTraceEventName,
        status: ScheduleTraceStatus,
        reasonCode: String,
        occurrence: ScheduleOccurrence? = nil,
        count: Int? = nil,
        at date: Date
    ) {
        traceSink(.init(
            timestamp: date,
            event: event,
            traceID: UUID().uuidString.lowercased(),
            spanID: UUID().uuidString.lowercased(),
            parentSpanID: nil,
            component: "brief-scheduler",
            status: status,
            reasonCode: String(reasonCode.prefix(120)),
            occurrenceHash: occurrence.map { SchedulePrivacy.hashIdentifier($0.key.rawValue) },
            boundedCount: count.map { min(max($0, 0), 10_000) }
        ))
    }
}
