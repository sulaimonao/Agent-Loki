import Foundation

private enum ScheduledBriefingCoordinatorError: Error {
    case cancelled
    case durationBudgetExceeded
    case deterministicAssemblyFailed
    case persistenceFailed
}

enum ScheduledBriefingDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private actor ScheduledBriefingDeadlineLatch<Value: Sendable> {
    private var result: ScheduledBriefingDeadlineResult<Value>?
    private var waiters: [CheckedContinuation<ScheduledBriefingDeadlineResult<Value>, Never>] = []

    func resolve(_ result: ScheduledBriefingDeadlineResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    func wait() async -> ScheduledBriefingDeadlineResult<Value> {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

enum ScheduledBriefingDeadlineRace {
    static func run<Value: Sendable>(
        maximumDurationSeconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> ScheduledBriefingDeadlineResult<Value> {
        guard maximumDurationSeconds > 0 else { return .timedOut }
        let latch = ScheduledBriefingDeadlineLatch<Value>()
        let operationTask = Task { @MainActor in
            let value = await operation()
            await latch.resolve(.value(value))
        }
        let timeoutTask = Task.detached {
            let nanoseconds = UInt64(min(max(maximumDurationSeconds, 0.001), 300) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                await latch.resolve(.timedOut)
            } catch { }
        }
        let result = await latch.wait()
        operationTask.cancel()
        timeoutTask.cancel()
        return result
    }
}

private enum ScheduledBriefingSourceStageResult: Sendable {
    case outcomes([ScheduledBriefingSourceOutcome])
    case cancelled
}

@MainActor
final class ScheduledBriefingCoordinator {
    private struct ActiveRun {
        let plan: ScheduledBriefingPlan
        let generation: UInt64
        let trace: ScheduledBriefingTraceContext
        let startedAt: Date
        var state: ScheduledBriefingRunState
        var cancelRequested: Bool
        var cancellationCleanup: Task<Void, Never>?
    }

    private let sourceRefresher: any ScheduledBriefingSourceRefreshing
    private let vaultReconciler: any ScheduledBriefingVaultReconciling
    private let assembler: any ScheduledBriefingAssembling
    private let localPresenter: any ScheduledBriefingLocalPresenting
    private let persistence: any ScheduledBriefingRunPersisting
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let eventSink: ScheduledBriefingTraceSink?

    private var generation: UInt64 = 0
    private var active: ActiveRun?

    init(
        sourceRefresher: any ScheduledBriefingSourceRefreshing,
        vaultReconciler: any ScheduledBriefingVaultReconciling,
        assembler: any ScheduledBriefingAssembling,
        localPresenter: any ScheduledBriefingLocalPresenting,
        persistence: any ScheduledBriefingRunPersisting,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        eventSink: ScheduledBriefingTraceSink? = nil
    ) {
        self.sourceRefresher = sourceRefresher
        self.vaultReconciler = vaultReconciler
        self.assembler = assembler
        self.localPresenter = localPresenter
        self.persistence = persistence
        self.now = now
        self.uptime = uptime
        self.eventSink = eventSink
    }

    var activeRunID: String? { active?.plan.id }

    func run(_ plan: ScheduledBriefingPlan) async -> ScheduledBriefingRunResult {
        let requestedAt = now()
        guard active == nil else {
            let trace = ScheduledBriefingTraceContext()
            emit(
                .run,
                trace: trace,
                status: .skipped,
                reason: ScheduledBriefingReason.runAlreadyActive,
                metadata: runMetadata(plan) + [
                    (.activeRunHash, active.map { ScheduledBriefingPrivacy.hashIdentifier($0.plan.id) } ?? "unknown"),
                ]
            )
            return .init(
                plan: plan,
                state: .skipped,
                reasonCode: ScheduledBriefingReason.runAlreadyActive,
                startedAt: requestedAt,
                completedAt: requestedAt,
                sourceOutcomes: [],
                vaultOutcome: nil,
                brief: nil,
                generationProvenance: nil,
                fallbackReasonCode: nil,
                failureReasonCodes: [ScheduledBriefingReason.runAlreadyActive]
            )
        }

        generation &+= 1
        let runGeneration = generation
        let trace = ScheduledBriefingTraceContext()
        let budgetLedger = ScheduledBriefingBudgetLedger(budget: plan.budget, uptime: uptime)
        active = .init(
            plan: plan,
            generation: runGeneration,
            trace: trace,
            startedAt: requestedAt,
            state: .queued,
            cancelRequested: false,
            cancellationCleanup: nil
        )

        var sourceOutcomes: [ScheduledBriefingSourceOutcome] = []
        var vaultOutcome: ScheduledBriefingVaultOutcome?
        var fallbackReasonCode: String?
        var generationProvenance: OllamaGenerationProvenance?
        var failureReasonCodes: [String] = []

        emit(.run, trace: trace, status: .started, reason: ScheduledBriefingReason.queued, metadata: runMetadata(plan))

        do {
            try recordTransition(
                plan: plan,
                generation: runGeneration,
                state: .queued,
                reason: ScheduledBriefingReason.queued,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                briefID: nil,
                fallbackReasonCode: nil,
                failures: failureReasonCodes
            )

            try recordTransition(
                plan: plan,
                generation: runGeneration,
                state: .refreshingSources,
                reason: ScheduledBriefingReason.sourceRefreshStarted,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                briefID: nil,
                fallbackReasonCode: nil,
                failures: failureReasonCodes
            )
            emit(
                .sourceRefresh,
                trace: trace.child(),
                status: .started,
                reason: ScheduledBriefingReason.sourceRefreshStarted,
                metadata: runMetadata(plan)
            )

            let sourceStage = await ScheduledBriefingDeadlineRace.run(
                maximumDurationSeconds: await budgetLedger.remainingDurationSeconds()
            ) { [weak self] in
                guard let self else { return ScheduledBriefingSourceStageResult.cancelled }
                do {
                    return ScheduledBriefingSourceStageResult.outcomes(try await self.refreshSources(
                        plan: plan,
                        generation: runGeneration,
                        trace: trace,
                        budget: budgetLedger
                    ))
                } catch {
                    return ScheduledBriefingSourceStageResult.cancelled
                }
            }
            switch sourceStage {
            case let .value(.outcomes(outcomes)):
                sourceOutcomes = outcomes
            case .value(.cancelled):
                throw ScheduledBriefingCoordinatorError.cancelled
            case .timedOut:
                await budgetLedger.markDurationExhausted()
                throw ScheduledBriefingCoordinatorError.durationBudgetExceeded
            }
            try requireCurrent(plan: plan, generation: runGeneration, trace: trace)
            failureReasonCodes = boundedFailures(from: sourceOutcomes, limit: plan.budget.maximumFailureReasons)
            let sourceStatus: ScheduledBriefingTraceStatus = failureReasonCodes.isEmpty ? .success : .degraded
            let sourceReason = sourceOutcomes.isEmpty
                ? ScheduledBriefingReason.noEnabledSources
                : (failureReasonCodes.isEmpty ? ScheduledBriefingReason.sourceRefreshComplete : ScheduledBriefingReason.sourceRefreshPartial)
            emit(
                .sourceRefresh,
                trace: trace.child(),
                status: sourceOutcomes.isEmpty ? .skipped : sourceStatus,
                reason: sourceReason,
                metadata: sourceSummaryMetadata(sourceOutcomes)
            )

            try recordTransition(
                plan: plan,
                generation: runGeneration,
                state: .reconcilingVault,
                reason: ScheduledBriefingReason.vaultReconciliationStarted,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: nil,
                briefID: nil,
                fallbackReasonCode: nil,
                failures: failureReasonCodes
            )

            if sourceOutcomes.contains(where: { $0.status == .success || $0.status == .degraded }) {
                let vaultTrace = trace.child()
                emit(.vaultReconciliation, trace: vaultTrace, status: .started, reason: ScheduledBriefingReason.vaultReconciliationStarted)
                let vaultStage = await ScheduledBriefingDeadlineRace.run(
                    maximumDurationSeconds: await budgetLedger.remainingDurationSeconds()
                ) { [vaultReconciler = self.vaultReconciler] in
                    await vaultReconciler.reconcile(plan: plan, trace: vaultTrace, budget: budgetLedger)
                }
                guard case let .value(returned) = vaultStage else {
                    await budgetLedger.markDurationExhausted()
                    throw ScheduledBriefingCoordinatorError.durationBudgetExceeded
                }
                try requireCurrent(plan: plan, generation: runGeneration, trace: trace)
                vaultOutcome = returned
                if returned.status.contributesFailure {
                    failureReasonCodes.append(contentsOf: returned.reasonCodes.isEmpty ? ["scheduled_vault_reconciliation_failed"] : returned.reasonCodes)
                    failureReasonCodes = boundedReasonCodes(failureReasonCodes, limit: plan.budget.maximumFailureReasons)
                }
                emit(
                    .vaultReconciliation,
                    trace: vaultTrace,
                    status: traceStatus(returned.status),
                    reason: returned.reasonCodes.first ?? (returned.status == .success ? "scheduled_vault_reconciliation_complete" : "scheduled_vault_reconciliation_degraded"),
                    metadata: [(.changedItemCount, String(returned.changedItemCount))]
                )
            } else {
                vaultOutcome = .init(status: .skipped, reasonCodes: [ScheduledBriefingReason.vaultReconciliationSkipped])
                emit(
                    .vaultReconciliation,
                    trace: trace.child(),
                    status: .skipped,
                    reason: ScheduledBriefingReason.vaultReconciliationSkipped
                )
            }

            try recordTransition(
                plan: plan,
                generation: runGeneration,
                state: .assemblingDeterministicBrief,
                reason: ScheduledBriefingReason.deterministicAssemblyStarted,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                briefID: nil,
                fallbackReasonCode: nil,
                failures: failureReasonCodes
            )
            let assemblyTrace = trace.child()
            emit(.deterministicAssembly, trace: assemblyTrace, status: .started, reason: ScheduledBriefingReason.deterministicAssemblyStarted)
            let draft = try assembler.assemble(
                plan: plan,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                trace: assemblyTrace
            )
            try requireCurrent(plan: plan, generation: runGeneration, trace: trace)
            guard ![BriefStatus.cancelled, .failed, .unavailable].contains(draft.brief.status) else {
                throw ScheduledBriefingCoordinatorError.deterministicAssemblyFailed
            }
            failureReasonCodes.append(contentsOf: draft.failureReasonCodes)
            failureReasonCodes = boundedReasonCodes(failureReasonCodes, limit: plan.budget.maximumFailureReasons)
            emit(
                .deterministicAssembly,
                trace: assemblyTrace,
                status: draft.brief.status == .partial ? .degraded : .success,
                reason: ScheduledBriefingReason.deterministicAssemblyComplete,
                metadata: [
                    (.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)),
                    (.acceptedItemCount, String(draft.brief.itemCount)),
                    (.excludedItemCount, String(draft.excludedItemCount)),
                ]
            )

            var finalBrief = draft.brief
            var presentationStageEnforcedRemainingBudget = false
            if plan.localPresentationEnabled {
                try recordTransition(
                    plan: plan,
                    generation: runGeneration,
                    state: .generatingLocalPresentation,
                    reason: ScheduledBriefingReason.localPresentationStarted,
                    sourceOutcomes: sourceOutcomes,
                    vaultOutcome: vaultOutcome,
                    briefID: draft.brief.id,
                    fallbackReasonCode: nil,
                    failures: failureReasonCodes
                )
                let presentationTrace = trace.child()
                emit(.localPresentation, trace: presentationTrace, status: .started, reason: ScheduledBriefingReason.localPresentationStarted)
                let presentationStartedUptime = uptime()
                let presentationMaximumDuration = await budgetLedger.remainingDurationSeconds()
                let presentationDeadlineUptime = presentationStartedUptime + presentationMaximumDuration
                let presentationStage = await ScheduledBriefingDeadlineRace.run(
                    maximumDurationSeconds: presentationMaximumDuration
                ) { [localPresenter = self.localPresenter] in
                    await localPresenter.present(draft: draft, trace: presentationTrace, budget: budgetLedger)
                }
                let presentationFinishedUptime = uptime()
                let presentationDeadlineExpired = presentationFinishedUptime >= presentationDeadlineUptime
                presentationStageEnforcedRemainingBudget = true
                // The deadline race already bounded this optional stage by the
                // whole-run remainder. Recheck ownership/cancellation here, but
                // do not discard the authoritative deterministic draft merely
                // because that bounded fallback reached the terminal deadline.
                try requireCurrent(
                    plan: plan,
                    generation: runGeneration,
                    trace: trace,
                    enforceDurationBudget: false
                )
                switch (presentationStage, presentationDeadlineExpired) {
                case (.timedOut, _), (_, true):
                    await budgetLedger.recordOllamaElapsed(seconds: max(0, presentationFinishedUptime - presentationStartedUptime))
                    await budgetLedger.markOllamaDurationExhausted()
                    await budgetLedger.markDurationExhausted()
                    let localPresenter = self.localPresenter
                    Task { await localPresenter.cancel() }
                    fallbackReasonCode = ScheduledBriefingBudgetReason.ollamaDurationExhausted
                    emit(
                        .localPresentation,
                        trace: presentationTrace,
                        status: .degraded,
                        reason: ScheduledBriefingBudgetReason.ollamaDurationExhausted,
                        metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)), (.fallbackUsed, "true")]
                    )
                case let (.value(presentation), false):
                    switch presentation {
                case let .generated(candidate, provenance):
                    if presentationPreservesAuthority(candidate: candidate, deterministic: draft.brief, provenance: provenance) {
                        finalBrief = candidate
                        generationProvenance = provenance
                        emit(
                            .localPresentation,
                            trace: presentationTrace,
                            status: .success,
                            reason: "scheduled_local_presentation_complete",
                            metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(candidate.id)), (.fallbackUsed, "false")]
                        )
                    } else {
                        fallbackReasonCode = ScheduledBriefingReason.localPresentationAuthorityRejected
                        emit(
                            .localPresentation,
                            trace: presentationTrace,
                            status: .degraded,
                            reason: ScheduledBriefingReason.localPresentationAuthorityRejected,
                            metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)), (.fallbackUsed, "true")]
                        )
                    }
                case let .fallback(reasonCode, provenance):
                    fallbackReasonCode = ScheduledBriefingPrivacy.boundedReasonCode(reasonCode)
                    generationProvenance = provenance
                    emit(
                        .localPresentation,
                        trace: presentationTrace,
                        status: .degraded,
                        reason: fallbackReasonCode ?? "scheduled_local_presentation_fallback",
                        metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)), (.fallbackUsed, "true")]
                    )
                case let .skipped(reasonCode):
                    fallbackReasonCode = ScheduledBriefingPrivacy.boundedReasonCode(reasonCode)
                    emit(
                        .localPresentation,
                        trace: presentationTrace,
                        status: .skipped,
                        reason: fallbackReasonCode ?? ScheduledBriefingReason.localPresentationDisabled,
                        metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)), (.fallbackUsed, "true")]
                    )
                    }
                }
                if await budgetLedger.remainingDurationSeconds() <= 0 {
                    await budgetLedger.markDurationExhausted()
                }
            } else {
                fallbackReasonCode = ScheduledBriefingReason.localPresentationDisabled
                emit(
                    .localPresentation,
                    trace: trace.child(),
                    status: .skipped,
                    reason: ScheduledBriefingReason.localPresentationDisabled,
                    metadata: [(.briefHash, ScheduledBriefingPrivacy.hashIdentifier(draft.brief.id)), (.fallbackUsed, "false")]
                )
            }

            let terminalBudgetUsage = await budgetLedger.usage()
            try requireCurrent(
                plan: plan,
                generation: runGeneration,
                trace: trace,
                enforceDurationBudget: !presentationStageEnforcedRemainingBudget
            )
            let isPartial = !failureReasonCodes.isEmpty || draft.brief.status == .partial
            let terminalState: ScheduledBriefingRunState = isPartial ? .partial : .complete
            let terminalReason = isPartial ? ScheduledBriefingReason.runPartial : ScheduledBriefingReason.runComplete
            let completedAt = now()
            let result = ScheduledBriefingRunResult(
                plan: plan,
                state: terminalState,
                reasonCode: terminalReason,
                startedAt: requestedAt,
                completedAt: completedAt,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                brief: finalBrief,
                generationProvenance: generationProvenance,
                fallbackReasonCode: fallbackReasonCode,
                failureReasonCodes: failureReasonCodes
            )

            // This synchronous main-actor boundary is the final acceptance gate.
            // Cancellation cannot interleave between the current check and commit.
            do { try persistence.commit(.init(result: result)) }
            catch { throw ScheduledBriefingCoordinatorError.persistenceFailed }
            active = nil
            emit(
                .run,
                trace: trace,
                status: terminalState == .complete ? .success : .degraded,
                reason: terminalReason,
                duration: durationMilliseconds(since: requestedAt),
                metadata: sourceSummaryMetadata(sourceOutcomes) + [
                    (.briefHash, ScheduledBriefingPrivacy.hashIdentifier(finalBrief.id)),
                    (.fallbackUsed, fallbackReasonCode == nil ? "false" : "true"),
                ]
            )
            emitBudgetUsage(terminalBudgetUsage, trace: trace, plan: plan)
            return result
        } catch ScheduledBriefingCoordinatorError.cancelled {
            let terminalBudgetUsage = await budgetLedger.usage()
            let result = await finishCancelled(
                plan: plan,
                generation: runGeneration,
                trace: trace,
                startedAt: requestedAt,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                fallbackReasonCode: fallbackReasonCode,
                failureReasonCodes: failureReasonCodes
            )
            emitBudgetUsage(terminalBudgetUsage, trace: trace, plan: plan)
            return result
        } catch {
            let reason = failureReasonCode(for: error)
            let terminalBudgetUsage = await budgetLedger.usage()
            let result = await finishFailed(
                plan: plan,
                generation: runGeneration,
                trace: trace,
                startedAt: requestedAt,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                fallbackReasonCode: fallbackReasonCode,
                failureReasonCodes: boundedReasonCodes(failureReasonCodes + [reason], limit: plan.budget.maximumFailureReasons),
                reason: reason
            )
            emitBudgetUsage(terminalBudgetUsage, trace: trace, plan: plan)
            return result
        }
    }

    @discardableResult
    func cancel(runID: String) async -> Bool {
        guard var current = active, current.plan.id == runID else { return false }
        if current.cancelRequested {
            if let cleanup = current.cancellationCleanup { await cleanup.value }
            return true
        }
        generation &+= 1
        current.cancelRequested = true
        let cleanup = makeCancellationCleanup(plan: current.plan)
        current.cancellationCleanup = cleanup
        active = current
        emit(
            .cancellation,
            trace: current.trace.child(),
            status: .started,
            reason: "scheduled_cancellation_requested",
            metadata: runMetadata(current.plan)
        )
        await cleanup.value
        emit(
            .cancellation,
            trace: current.trace.child(),
            status: .success,
            reason: "scheduled_cancellation_propagated",
            metadata: runMetadata(current.plan)
        )
        return true
    }

    /// Cancels and detaches the active run before whole-app persistence is
    /// deleted. A late non-cooperative provider may still return, but it can no
    /// longer append a terminal transition to a freshly cleared store.
    func cancelForDataDeletion() async {
        guard var current = active else { return }
        generation &+= 1
        current.cancelRequested = true
        let cleanup = current.cancellationCleanup ?? makeCancellationCleanup(plan: current.plan)
        current.cancellationCleanup = cleanup
        active = current
        await cleanup.value
        if active?.plan.id == current.plan.id {
            active = nil
        }
    }

    private func refreshSources(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async throws -> [ScheduledBriefingSourceOutcome] {
        var outcomes = try await refreshFeeds(plan: plan, generation: generation, trace: trace, budget: budget)
        guard plan.refreshSlackEnabled else { return deterministicSourceOrder(outcomes) }
        for workspaceID in plan.slackWorkspaceIDs {
            try requireCurrent(plan: plan, generation: generation, trace: trace)
            let sourceTrace = trace.child()
            let returned = await sourceRefresher.refreshSlackWorkspace(
                identifier: workspaceID,
                plan: plan,
                trace: sourceTrace,
                budget: budget
            )
            try requireCurrent(plan: plan, generation: generation, trace: trace)
            let accepted = validatedSourceOutcome(returned, expectedKind: .slackWorkspace, expectedID: workspaceID)
            outcomes.append(accepted)
            emitSourceOutcome(accepted, trace: sourceTrace)
        }
        return deterministicSourceOrder(outcomes)
    }

    private func refreshFeeds(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async throws -> [ScheduledBriefingSourceOutcome] {
        guard plan.refreshFeedsEnabled, !plan.feedSubscriptionIDs.isEmpty else { return [] }
        let refresher = sourceRefresher
        let identifiers = plan.feedSubscriptionIDs
        let concurrency = min(plan.budget.maximumFeedConcurrency, identifiers.count)
        return try await withThrowingTaskGroup(of: (String, ScheduledBriefingSourceOutcome, ScheduledBriefingTraceContext).self) { group in
            var iterator = identifiers.makeIterator()
            for _ in 0..<concurrency {
                if let identifier = iterator.next() {
                    let child = trace.child()
                    group.addTask {
                        (
                            identifier,
                            await refresher.refreshFeed(identifier: identifier, plan: plan, trace: child, budget: budget),
                            child
                        )
                    }
                }
            }
            var outcomes: [ScheduledBriefingSourceOutcome] = []
            while let (requestedID, returned, child) = try await group.next() {
                try requireCurrent(plan: plan, generation: generation, trace: trace)
                let accepted = validatedSourceOutcome(returned, expectedKind: .feed, expectedID: requestedID)
                outcomes.append(accepted)
                emitSourceOutcome(accepted, trace: child)
                if let identifier = iterator.next() {
                    let nextTrace = trace.child()
                    group.addTask {
                        (
                            identifier,
                            await refresher.refreshFeed(identifier: identifier, plan: plan, trace: nextTrace, budget: budget),
                            nextTrace
                        )
                    }
                }
            }
            return deterministicSourceOrder(outcomes)
        }
    }

    private func validatedSourceOutcome(
        _ outcome: ScheduledBriefingSourceOutcome,
        expectedKind: ScheduledBriefingSourceKind,
        expectedID: String
    ) -> ScheduledBriefingSourceOutcome {
        guard outcome.kind == expectedKind, outcome.sourceID == expectedID else {
            return .init(
                kind: expectedKind,
                sourceID: expectedID,
                status: .failed,
                reasonCodes: ["scheduled_source_result_identity_mismatch"]
            )
        }
        return outcome
    }

    private func presentationPreservesAuthority(
        candidate: Brief,
        deterministic: Brief,
        provenance: OllamaGenerationProvenance
    ) -> Bool {
        candidate.id == deterministic.id
            && candidate.date == deterministic.date
            && candidate.sections.map(\.id) == deterministic.sections.map(\.id)
            && candidate.sections.flatMap(\.items).map(\.id) == deterministic.sections.flatMap(\.items).map(\.id)
            && candidate.generation.sourceItemIDs == deterministic.generation.sourceItemIDs
            && provenance.deterministicBriefIdentifier == deterministic.id
    }

    private func recordTransition(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        state: ScheduledBriefingRunState,
        reason: String,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        briefID: String?,
        fallbackReasonCode: String?,
        failures: [String]
    ) throws {
        try requireCurrent(plan: plan, generation: generation, trace: active?.trace ?? .init())
        guard var current = active else { throw ScheduledBriefingCoordinatorError.cancelled }
        current.state = state
        active = current
        do {
            try persistence.recordTransition(.init(
                plan: plan,
                state: state,
                reasonCode: reason,
                traceID: current.trace.traceID,
                startedAt: current.startedAt,
                updatedAt: now(),
                completedAt: state.isTerminal ? now() : nil,
                sourceOutcomes: sourceOutcomes,
                vaultOutcome: vaultOutcome,
                briefID: briefID,
                fallbackReasonCode: fallbackReasonCode,
                failureReasonCodes: failures
            ))
        } catch {
            throw ScheduledBriefingCoordinatorError.persistenceFailed
        }
    }

    private func requireCurrent(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        trace: ScheduledBriefingTraceContext,
        enforceDurationBudget: Bool = true
    ) throws {
        guard let current = active,
              current.plan.id == plan.id,
              current.generation == generation,
              self.generation == generation,
              !current.cancelRequested,
              !Task.isCancelled
        else {
            emit(
                .lateResultRejected,
                trace: trace.child(),
                status: .skipped,
                reason: ScheduledBriefingReason.lateResultRejected,
                metadata: runMetadata(plan)
            )
            throw ScheduledBriefingCoordinatorError.cancelled
        }
        if enforceDurationBudget,
           now().timeIntervalSince(current.startedAt) > plan.budget.maximumTotalDurationSeconds {
            throw ScheduledBriefingCoordinatorError.durationBudgetExceeded
        }
    }

    private func finishCancelled(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        trace: ScheduledBriefingTraceContext,
        startedAt: Date,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        fallbackReasonCode: String?,
        failureReasonCodes: [String]
    ) async -> ScheduledBriefingRunResult {
        let cleanup: Task<Void, Never>
        if let current = active, current.plan.id == plan.id, let existing = current.cancellationCleanup {
            cleanup = existing
        } else {
            cleanup = makeCancellationCleanup(plan: plan)
            if var current = active, current.plan.id == plan.id {
                current.cancelRequested = true
                current.cancellationCleanup = cleanup
                active = current
            }
        }
        await cleanup.value
        let completedAt = now()
        let result = ScheduledBriefingRunResult(
            plan: plan,
            state: .cancelled,
            reasonCode: ScheduledBriefingReason.runCancelled,
            startedAt: startedAt,
            completedAt: completedAt,
            sourceOutcomes: deterministicSourceOrder(sourceOutcomes),
            vaultOutcome: vaultOutcome,
            brief: nil,
            generationProvenance: nil,
            fallbackReasonCode: fallbackReasonCode,
            failureReasonCodes: boundedReasonCodes(failureReasonCodes + [ScheduledBriefingReason.runCancelled], limit: plan.budget.maximumFailureReasons)
        )
        if active?.plan.id == plan.id {
            try? persistence.recordTransition(snapshot(for: result, traceID: trace.traceID))
            active = nil
        }
        emit(
            .run,
            trace: trace,
            status: .skipped,
            reason: ScheduledBriefingReason.runCancelled,
            duration: durationMilliseconds(since: startedAt),
            metadata: sourceSummaryMetadata(sourceOutcomes)
        )
        return result
    }

    private func finishFailed(
        plan: ScheduledBriefingPlan,
        generation: UInt64,
        trace: ScheduledBriefingTraceContext,
        startedAt: Date,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        fallbackReasonCode: String?,
        failureReasonCodes: [String],
        reason: String
    ) async -> ScheduledBriefingRunResult {
        if var current = active, current.plan.id == plan.id {
            self.generation &+= 1
            current.cancelRequested = true
            active = current
        }
        let cleanup = makeCancellationCleanup(plan: plan)
        await cleanup.value
        let completedAt = now()
        let result = ScheduledBriefingRunResult(
            plan: plan,
            state: .failed,
            reasonCode: reason,
            startedAt: startedAt,
            completedAt: completedAt,
            sourceOutcomes: deterministicSourceOrder(sourceOutcomes),
            vaultOutcome: vaultOutcome,
            brief: nil,
            generationProvenance: nil,
            fallbackReasonCode: fallbackReasonCode,
            failureReasonCodes: failureReasonCodes
        )
        if active?.plan.id == plan.id {
            try? persistence.recordTransition(snapshot(for: result, traceID: trace.traceID))
            active = nil
        }
        emit(
            .run,
            trace: trace,
            status: .failed,
            reason: reason,
            duration: durationMilliseconds(since: startedAt),
            metadata: sourceSummaryMetadata(sourceOutcomes)
        )
        return result
    }

    private func makeCancellationCleanup(plan: ScheduledBriefingPlan) -> Task<Void, Never> {
        let sourceRefresher = sourceRefresher
        let vaultReconciler = vaultReconciler
        let localPresenter = localPresenter
        return Task {
            async let source: Void = sourceRefresher.cancelAll()
            async let vault: Void = vaultReconciler.cancel(runID: plan.id)
            async let presentation: Void = localPresenter.cancel()
            _ = await (source, vault, presentation)
        }
    }

    private func snapshot(for result: ScheduledBriefingRunResult, traceID: String) -> ScheduledBriefingRunSnapshot {
        .init(
            plan: result.plan,
            state: result.state,
            reasonCode: result.reasonCode,
            traceID: traceID,
            startedAt: result.startedAt,
            updatedAt: result.completedAt,
            completedAt: result.completedAt,
            sourceOutcomes: result.sourceOutcomes,
            vaultOutcome: result.vaultOutcome,
            briefID: result.brief?.id,
            fallbackReasonCode: result.fallbackReasonCode,
            failureReasonCodes: result.failureReasonCodes
        )
    }

    private func deterministicSourceOrder(_ outcomes: [ScheduledBriefingSourceOutcome]) -> [ScheduledBriefingSourceOutcome] {
        outcomes.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.sourceID < $1.sourceID
        }
    }

    private func boundedFailures(from outcomes: [ScheduledBriefingSourceOutcome], limit: Int) -> [String] {
        let values = outcomes.flatMap { outcome -> [String] in
            guard outcome.status.contributesFailure else { return [] }
            return outcome.reasonCodes.isEmpty ? ["scheduled_\(outcome.kind.rawValue)_refresh_failed"] : outcome.reasonCodes
        }
        return boundedReasonCodes(values, limit: limit)
    }

    private func boundedReasonCodes(_ values: [String], limit: Int) -> [String] {
        Array(Set(values.map(ScheduledBriefingPrivacy.boundedReasonCode).filter { !$0.isEmpty })).sorted().prefix(limit).map { $0 }
    }

    private func failureReasonCode(for error: Error) -> String {
        switch error {
        case ScheduledBriefingCoordinatorError.durationBudgetExceeded: ScheduledBriefingBudgetReason.durationExhausted
        case ScheduledBriefingCoordinatorError.deterministicAssemblyFailed: "scheduled_deterministic_assembly_failed"
        case ScheduledBriefingCoordinatorError.persistenceFailed: ScheduledBriefingReason.persistenceFailed
        default: ScheduledBriefingReason.runFailed
        }
    }

    private func durationMilliseconds(since start: Date) -> Int {
        max(0, Int((now().timeIntervalSince(start) * 1_000).rounded()))
    }

    private func runMetadata(_ plan: ScheduledBriefingPlan) -> [(ScheduledBriefingTraceMetadataKey, String)] {
        [
            (.runHash, ScheduledBriefingPrivacy.hashIdentifier(plan.id)),
            (.occurrenceHash, ScheduledBriefingPrivacy.hashIdentifier(plan.occurrenceID)),
            (.trigger, plan.trigger.rawValue),
            (.feedCount, String(plan.feedSubscriptionIDs.count)),
            (.slackWorkspaceCount, String(plan.slackWorkspaceIDs.count)),
        ]
    }

    private func sourceSummaryMetadata(_ outcomes: [ScheduledBriefingSourceOutcome]) -> [(ScheduledBriefingTraceMetadataKey, String)] {
        [
            (.sourceSuccessCount, String(outcomes.filter { $0.status == .success }.count)),
            (.sourceFailureCount, String(outcomes.filter { $0.status.contributesFailure }.count)),
            (.acceptedItemCount, String(outcomes.reduce(0) { $0 + $1.acceptedItemCount })),
        ]
    }

    private func emitBudgetUsage(
        _ usage: ScheduledBriefingBudgetUsage,
        trace: ScheduledBriefingTraceContext,
        plan: ScheduledBriefingPlan
    ) {
        let exhausted = !usage.exhaustionReasonCodes.isEmpty
        emit(
            .budget,
            trace: trace.child(),
            status: exhausted ? .degraded : .success,
            reason: usage.exhaustionReasonCodes.first ?? "scheduled_budget_within_limits",
            metadata: runMetadata(plan) + [
                (.feedRequestCount, String(usage.feedRequestCount)),
                (.slackRequestCount, String(usage.slackRequestCount)),
                (.transientRetryCount, String(usage.transientRetryCount)),
                (.archiveItemCount, String(usage.archiveItemCount)),
                (.archiveStorageBytes, String(usage.archiveStorageBytes)),
                (.ollamaAllowanceMilliseconds, String(usage.ollamaAllowanceMilliseconds)),
                (.ollamaElapsedMilliseconds, String(usage.ollamaElapsedMilliseconds)),
                (.exhaustionCount, String(usage.exhaustionReasonCodes.count)),
            ]
        )
    }

    private func emitSourceOutcome(_ outcome: ScheduledBriefingSourceOutcome, trace: ScheduledBriefingTraceContext) {
        let reason = outcome.reasonCodes.first ?? "scheduled_\(outcome.kind.rawValue)_refresh_\(outcome.status.rawValue)"
        emit(
            .sourceRefresh,
            trace: trace,
            status: traceStatus(outcome.status),
            reason: reason,
            metadata: [
                (.sourceHash, ScheduledBriefingPrivacy.hashIdentifier(outcome.sourceID)),
                (.sourceKind, outcome.kind.rawValue),
                (.acceptedItemCount, String(outcome.acceptedItemCount)),
            ]
        )
    }

    private func traceStatus(_ status: ScheduledBriefingStageStatus) -> ScheduledBriefingTraceStatus {
        switch status {
        case .success: .success
        case .degraded: .degraded
        case .failed: .failed
        case .skipped, .cancelled: .skipped
        }
    }

    private func emit(
        _ event: ScheduledBriefingTraceEventName,
        trace: ScheduledBriefingTraceContext,
        status: ScheduledBriefingTraceStatus,
        reason: String,
        duration: Int? = nil,
        metadata: [(ScheduledBriefingTraceMetadataKey, String)] = []
    ) {
        eventSink?(.init(
            ts: now(),
            event: event,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "scheduled_briefing_coordinator",
            status: status,
            reasonCode: ScheduledBriefingPrivacy.boundedReasonCode(reason),
            durationMilliseconds: duration,
            metadata: .init(metadata)
        ))
    }
}
