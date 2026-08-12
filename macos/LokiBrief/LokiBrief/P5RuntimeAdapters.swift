import Foundation

@MainActor
final class LiveScheduledSourceRefresher: ScheduledBriefingSourceRefreshing {
    private struct RuntimeSnapshot {
        let planFingerprint: String
        let feedSubscriptions: [String: FeedSubscription]
        let slackSelectionsByWorkspace: [String: [SlackConversationSelection]]
    }

    private unowned let model: AppModel
    private var operationGeneration: UInt64 = 0
    private var runtimeSnapshot: RuntimeSnapshot?

    init(model: AppModel) { self.model = model }

    nonisolated static func slackWorkspaceOutcome(
        identifier: String,
        syncSucceeded: Bool,
        operation: SlackConnectorOperation?
    ) -> ScheduledBriefingSourceOutcome {
        let failureReason: String?
        if case let .failed(reasonCode)? = operation {
            failureReason = reasonCode
        } else {
            failureReason = nil
        }
        let sourceSucceeded = syncSucceeded && failureReason == nil
        return .init(
            kind: .slackWorkspace,
            sourceID: identifier,
            status: sourceSucceeded ? .success : .degraded,
            reasonCodes: sourceSucceeded ? [] : [failureReason ?? "scheduled_slack_refresh_partial"]
        )
    }

    func configure(
        plan: ScheduledBriefingPlan,
        feedSubscriptions: [FeedSubscription],
        slackSelectionsByWorkspace: [String: [SlackConversationSelection]]
    ) {
        operationGeneration &+= 1
        runtimeSnapshot = .init(
            planFingerprint: plan.fingerprint,
            feedSubscriptions: Dictionary(uniqueKeysWithValues: feedSubscriptions.map { ($0.id, $0) }),
            slackSelectionsByWorkspace: slackSelectionsByWorkspace
        )
    }

    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome {
        await refreshFeed(identifier: identifier, trace: trace, budget: nil)
    }

    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshFeed(identifier: identifier, plan: nil, trace: trace, budget: Optional(budget))
    }

    func refreshFeed(
        identifier: String,
        plan: ScheduledBriefingPlan,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async -> ScheduledBriefingSourceOutcome {
        await refreshFeed(identifier: identifier, plan: plan, trace: trace, budget: Optional(budget))
    }

    private func refreshFeed(
        identifier: String,
        plan: ScheduledBriefingPlan? = nil,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger?
    ) async -> ScheduledBriefingSourceOutcome {
        let generation = operationGeneration
        guard !Task.isCancelled else {
            return .init(kind: .feed, sourceID: identifier, status: .skipped, reasonCodes: [ScheduledBriefingReason.lateResultRejected])
        }
        guard plan?.refreshFeedsEnabled != false else {
            return .init(kind: .feed, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_feed_refresh_disabled"])
        }
        let subscription: FeedSubscription?
        if let plan {
            guard let runtimeSnapshot, runtimeSnapshot.planFingerprint == plan.fingerprint else {
                return .init(kind: .feed, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_plan_runtime_snapshot_mismatch"])
            }
            subscription = runtimeSnapshot.feedSubscriptions[identifier]
        } else {
            subscription = model.subscriptions.first(where: { $0.id == identifier && $0.enabled })
        }
        guard let subscription else {
            return .init(kind: .feed, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_feed_not_enabled"])
        }
        do {
            let feedTrace = FeedTraceContext(traceID: trace.traceID, spanID: trace.spanID, parentSpanID: trace.parentSpanID)
            let result: FeedFetchResult
            if let budget {
                result = try await model.feedClient.fetch(subscription, trace: feedTrace, budget: budget)
            } else {
                result = try await model.feedClient.fetch(subscription, trace: feedTrace)
            }
            guard generation == operationGeneration, !Task.isCancelled else {
                return .init(kind: .feed, sourceID: identifier, status: .skipped, reasonCodes: [ScheduledBriefingReason.lateResultRejected])
            }
            // The captured subscription makes the network operation immutable,
            // but a user can still revoke that source while the request is in
            // flight. Never let the captured `enabled = true` value recreate a
            // removed subscription or re-enable a disabled one at commit time.
            guard let current = try model.store.domainFeedSubscriptions().first(where: { $0.id == identifier }),
                  current.enabled,
                  current.createdAt == subscription.createdAt
            else {
                return .init(
                    kind: .feed,
                    sourceID: identifier,
                    status: .skipped,
                    reasonCodes: ["scheduled_feed_revoked_before_commit"]
                )
            }
            var acceptedSubscription = result.subscription
            acceptedSubscription.title = current.title
            acceptedSubscription.enabled = true
            acceptedSubscription.policy = current.policy
            acceptedSubscription.weight = current.weight
            let acceptedResult = FeedFetchResult(
                subscription: acceptedSubscription,
                entries: result.entries,
                record: result.record,
                warnings: result.warnings
            )
            try model.store.persistFeedFetchResult(acceptedResult, settings: model.p2Settings)
            return .init(kind: .feed, sourceID: identifier, status: .success, acceptedItemCount: result.entries.count, reasonCodes: result.warnings)
        } catch {
            let reason = (error as? FeedFetchFailure)?.reasonCode ?? "scheduled_feed_refresh_failed"
            return .init(kind: .feed, sourceID: identifier, status: .failed, reasonCodes: [reason])
        }
    }

    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome {
        await refreshSlackWorkspace(identifier: identifier, trace: trace, budget: nil)
    }

    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshSlackWorkspace(identifier: identifier, plan: nil, trace: trace, budget: Optional(budget))
    }

    func refreshSlackWorkspace(
        identifier: String,
        plan: ScheduledBriefingPlan,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async -> ScheduledBriefingSourceOutcome {
        await refreshSlackWorkspace(identifier: identifier, plan: plan, trace: trace, budget: Optional(budget))
    }

    private func refreshSlackWorkspace(
        identifier: String,
        plan: ScheduledBriefingPlan? = nil,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger?
    ) async -> ScheduledBriefingSourceOutcome {
        let generation = operationGeneration
        guard !Task.isCancelled else {
            return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: [ScheduledBriefingReason.lateResultRejected])
        }
        guard plan?.refreshSlackEnabled != false else {
            return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_slack_refresh_disabled"])
        }
        guard model.slackController.availability == .connected,
              model.slackController.workspaces.contains(where: { $0.id == identifier }),
              model.slackController.isWorkspaceEnabled(identifier)
        else {
            return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_slack_unavailable"])
        }
        let scheduledSelections: [SlackConversationSelection]?
        if let plan {
            guard let runtimeSnapshot, runtimeSnapshot.planFingerprint == plan.fingerprint else {
                return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_plan_runtime_snapshot_mismatch"])
            }
            let selections = runtimeSnapshot.slackSelectionsByWorkspace[identifier] ?? []
            let plannedChannelIDs = Set(plan.slackSelections.first(where: { $0.workspaceID == identifier })?.channelIDs ?? [])
            guard Set(selections.map(\.channelID)) == plannedChannelIDs else {
                return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: ["scheduled_plan_runtime_snapshot_mismatch"])
            }
            scheduledSelections = selections
        } else {
            scheduledSelections = nil
        }
        let success = await model.slackController.syncSelectedChannels(
            workspaceID: identifier,
            notifyBriefingEvidenceChanged: false,
            scheduledBudget: budget,
            scheduledSelections: scheduledSelections,
            trace: .init(traceID: trace.traceID, spanID: trace.spanID, parentSpanID: trace.parentSpanID)
        )
        guard generation == operationGeneration, !Task.isCancelled else {
            return .init(kind: .slackWorkspace, sourceID: identifier, status: .skipped, reasonCodes: [ScheduledBriefingReason.lateResultRejected])
        }
        return Self.slackWorkspaceOutcome(
            identifier: identifier,
            syncSucceeded: success,
            operation: model.slackController.workspaceOperations[identifier]
        )
    }

    func cancelAll() async {
        operationGeneration &+= 1
        runtimeSnapshot = nil
        await model.feedClient.cancelAll()
        for workspace in model.slackController.workspaces {
            await model.slackController.cancelWorkspaceOperation(workspaceID: workspace.id)
        }
    }
}

@MainActor
final class LiveScheduledVaultReconciler: ScheduledBriefingVaultReconciling {
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func reconcile(plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingVaultOutcome {
        let priorError = model.vaultController.errorMessage
        await model.vaultController.reconcileExistingEvidence()
        if let error = model.vaultController.errorMessage, error != priorError {
            return .init(status: .degraded, reasonCodes: ["scheduled_vault_reconciliation_failed"])
        }
        return .init(status: .success, reasonCodes: ["scheduled_vault_reconciliation_complete"])
    }

    func reconcile(
        plan: ScheduledBriefingPlan,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async -> ScheduledBriefingVaultOutcome {
        await model.vaultController.reconcileScheduledEvidence(plan: plan, budget: budget)
    }

    func cancel(runID: String) async {
        model.vaultController.cancelScheduledReconciliation()
    }
}

@MainActor
final class LiveScheduledBriefingAssembler: ScheduledBriefingAssembling {
    private unowned let model: AppModel
    init(model: AppModel) { self.model = model }

    func assemble(
        plan: ScheduledBriefingPlan,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        trace: ScheduledBriefingTraceContext
    ) throws -> ScheduledBriefingDraft {
        try model.scheduledDeterministicDraft(plan: plan, sourceOutcomes: sourceOutcomes, vaultOutcome: vaultOutcome)
    }
}

@MainActor
final class LiveScheduledLocalPresenter: ScheduledBriefingLocalPresenting {
    private unowned let model: AppModel
    private var operationGeneration: UInt64 = 0
    private var activePresentationTask: Task<ScheduledBriefingPresentationOutcome, Never>?

    init(model: AppModel) { self.model = model }

    func present(draft: ScheduledBriefingDraft, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingPresentationOutcome {
        let generation = operationGeneration
        let task = Task { @MainActor [model] in
            guard !Task.isCancelled else { return Self.cancelledOutcome }
            return await model.scheduledLocalPresentation(draft: draft)
        }
        activePresentationTask = task
        let outcome = await task.value
        guard generation == operationGeneration, !Task.isCancelled else {
            return Self.cancelledOutcome
        }
        activePresentationTask = nil
        return outcome
    }

    func present(
        draft: ScheduledBriefingDraft,
        trace: ScheduledBriefingTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async -> ScheduledBriefingPresentationOutcome {
        let generation = operationGeneration
        let claim = await budget.ollamaAllowance(
            userMaximumSeconds: TimeInterval(model.p2Settings.generationTimeoutSeconds)
        )
        guard generation == operationGeneration, !Task.isCancelled else {
            return Self.cancelledOutcome
        }
        guard let allowance = claim.permit?.remainingDurationSeconds else {
            return .skipped(
                reasonCode: claim.rejectionReasonCode ?? ScheduledBriefingBudgetReason.ollamaDurationExhausted
            )
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadlineUptime = startedAt + allowance
        let task = Task { @MainActor [model] in
            guard !Task.isCancelled else { return Self.cancelledOutcome }
            return await model.scheduledLocalPresentation(draft: draft, timeoutSeconds: allowance)
        }
        activePresentationTask = task
        let result = await ScheduledBriefingDeadlineRace.run(maximumDurationSeconds: allowance) {
            await task.value
        }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        await budget.recordOllamaElapsed(seconds: max(0, finishedAt - startedAt))
        guard generation == operationGeneration, !Task.isCancelled else {
            task.cancel()
            return Self.cancelledOutcome
        }
        activePresentationTask = nil
        if finishedAt >= deadlineUptime {
            await budget.markOllamaDurationExhausted()
            task.cancel()
            await model.ollamaProvider.cancelGeneration()
            return .fallback(reasonCode: ScheduledBriefingBudgetReason.ollamaDurationExhausted, provenance: nil)
        }
        switch result {
        case let .value(outcome):
            return outcome
        case .timedOut:
            await budget.markOllamaDurationExhausted()
            task.cancel()
            await model.ollamaProvider.cancelGeneration()
            return .fallback(reasonCode: ScheduledBriefingBudgetReason.ollamaDurationExhausted, provenance: nil)
        }
    }

    func cancel() async {
        operationGeneration &+= 1
        activePresentationTask?.cancel()
        activePresentationTask = nil
        await model.ollamaProvider.cancelGeneration()
    }

    private static var cancelledOutcome: ScheduledBriefingPresentationOutcome {
        .skipped(reasonCode: OllamaFailureCode.requestCancelled.rawValue)
    }
}
