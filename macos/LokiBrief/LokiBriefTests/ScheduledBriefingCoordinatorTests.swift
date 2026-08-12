import Foundation
import XCTest
@testable import LokiBrief

private actor ScheduledBriefingTestSources: ScheduledBriefingSourceRefreshing {
    private let feedOutcomes: [String: ScheduledBriefingSourceOutcome]
    private let slackOutcomes: [String: ScheduledBriefingSourceOutcome]
    private let suspendedFeedID: String?
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var activeFeedCount = 0
    private var maximumActiveFeedCount = 0
    private var feedCalls: [String] = []
    private var slackCalls: [String] = []
    private var cancellationCount = 0

    init(
        feedOutcomes: [String: ScheduledBriefingSourceOutcome] = [:],
        slackOutcomes: [String: ScheduledBriefingSourceOutcome] = [:],
        suspendedFeedID: String? = nil
    ) {
        self.feedOutcomes = feedOutcomes
        self.slackOutcomes = slackOutcomes
        self.suspendedFeedID = suspendedFeedID
    }

    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome {
        feedCalls.append(identifier)
        activeFeedCount += 1
        maximumActiveFeedCount = max(maximumActiveFeedCount, activeFeedCount)
        if identifier == suspendedFeedID {
            await withCheckedContinuation { continuation in
                suspendedContinuation = continuation
            }
        } else {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        activeFeedCount -= 1
        return feedOutcomes[identifier] ?? .init(kind: .feed, sourceID: identifier, status: .success, acceptedItemCount: 1)
    }

    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome {
        slackCalls.append(identifier)
        return slackOutcomes[identifier] ?? .init(kind: .slackWorkspace, sourceID: identifier, status: .success, acceptedItemCount: 1)
    }

    func cancelAll() async { cancellationCount += 1 }

    func resolveSuspendedFeed() {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume()
    }

    func hasSuspendedFeed() -> Bool { suspendedContinuation != nil }
    func observations() -> (feeds: [String], slack: [String], maximumFeeds: Int, cancellations: Int) {
        (feedCalls, slackCalls, maximumActiveFeedCount, cancellationCount)
    }
}

private actor ScheduledBriefingTestVault: ScheduledBriefingVaultReconciling {
    private let outcome: ScheduledBriefingVaultOutcome
    private var reconciliations = 0
    private var cancellations = 0

    init(_ outcome: ScheduledBriefingVaultOutcome = .init(status: .success, changedItemCount: 2)) {
        self.outcome = outcome
    }

    func reconcile(plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingVaultOutcome {
        reconciliations += 1
        return outcome
    }

    func cancel(runID: String) async { cancellations += 1 }
    func counts() -> (reconciliations: Int, cancellations: Int) { (reconciliations, cancellations) }
}

@MainActor
private final class ScheduledBriefingTestAssembler: ScheduledBriefingAssembling, @unchecked Sendable {
    let draft: ScheduledBriefingDraft
    private(set) var plans: [ScheduledBriefingPlan] = []
    private(set) var receivedOutcomes: [[ScheduledBriefingSourceOutcome]] = []

    init(draft: ScheduledBriefingDraft) { self.draft = draft }

    func assemble(
        plan: ScheduledBriefingPlan,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        trace: ScheduledBriefingTraceContext
    ) throws -> ScheduledBriefingDraft {
        plans.append(plan)
        receivedOutcomes.append(sourceOutcomes)
        return draft
    }
}

private actor ScheduledBriefingTestPresenter: ScheduledBriefingLocalPresenting {
    private let outcome: ScheduledBriefingPresentationOutcome
    private var presentations = 0
    private var cancellations = 0

    init(_ outcome: ScheduledBriefingPresentationOutcome) { self.outcome = outcome }

    func present(draft: ScheduledBriefingDraft, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingPresentationOutcome {
        presentations += 1
        return outcome
    }

    func cancel() async { cancellations += 1 }
    func counts() -> (presentations: Int, cancellations: Int) { (presentations, cancellations) }
}

private actor ScheduledBriefingSuspendedPresenter: ScheduledBriefingLocalPresenting {
    private var continuation: CheckedContinuation<ScheduledBriefingPresentationOutcome, Never>?
    private var cancellations = 0

    func present(
        draft: ScheduledBriefingDraft,
        trace: ScheduledBriefingTraceContext
    ) async -> ScheduledBriefingPresentationOutcome {
        await withCheckedContinuation { continuation = $0 }
    }

    func cancel() async { cancellations += 1 }

    func resolveLate() {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: .skipped(reasonCode: "late_presenter_result"))
    }

    func hasSuspended() -> Bool { continuation != nil }
    func cancellationCount() -> Int { cancellations }
}

private final class ScheduledBriefingAdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var uptimeValue: TimeInterval
    private var dateValue: Date

    init(uptime: TimeInterval, date: Date) {
        uptimeValue = uptime
        dateValue = date
    }

    func uptime() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return uptimeValue
    }

    func date() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dateValue
    }

    func advance(by duration: TimeInterval) {
        lock.lock()
        uptimeValue += duration
        dateValue = dateValue.addingTimeInterval(duration)
        lock.unlock()
    }
}

private actor ScheduledBriefingAdvancingPresenter: ScheduledBriefingLocalPresenting {
    private let clock: ScheduledBriefingAdvancingClock
    private let advanceBy: TimeInterval
    private let outcome: ScheduledBriefingPresentationOutcome

    init(
        clock: ScheduledBriefingAdvancingClock,
        advanceBy: TimeInterval,
        outcome: ScheduledBriefingPresentationOutcome
    ) {
        self.clock = clock
        self.advanceBy = advanceBy
        self.outcome = outcome
    }

    func present(
        draft: ScheduledBriefingDraft,
        trace: ScheduledBriefingTraceContext
    ) async -> ScheduledBriefingPresentationOutcome {
        clock.advance(by: advanceBy)
        return outcome
    }

    func cancel() async { }
}

@MainActor
private final class ScheduledBriefingTestPersistence: ScheduledBriefingRunPersisting, @unchecked Sendable {
    private(set) var snapshots: [ScheduledBriefingRunSnapshot] = []
    private(set) var commits: [ScheduledBriefingCommit] = []

    func recordTransition(_ snapshot: ScheduledBriefingRunSnapshot) throws { snapshots.append(snapshot) }
    func commit(_ commit: ScheduledBriefingCommit) throws { commits.append(commit) }
}

private final class ScheduledBriefingTestTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScheduledBriefingTraceEvent] = []

    func append(_ event: ScheduledBriefingTraceEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [ScheduledBriefingTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class ScheduledBriefingCoordinatorTests: XCTestCase, @unchecked Sendable {
    nonisolated private static let anchor = Date(timeIntervalSince1970: 1_785_100_000)

    func testCanonicalStatesTriggersAndBoundedPlanAreStable() throws {
        XCTAssertEqual(Set(ScheduledRunState.allCases), Set([
            .scheduled, .waiting, .preparing, .synchronizing, .assembling, .generatingLocally,
            .persisting, .delivering, .completed, .partiallyCompleted, .skipped, .canceled,
            .failed, .reauthorizationRequired, .entitlementRequired,
        ]))
        XCTAssertEqual(Set(ScheduledRunTrigger.allCases), Set([
            .scheduled, .catchUpAfterWake, .catchUpAfterLaunch, .manualTest, .manualRunNow, .retry,
        ]))

        let budget = ScheduledBriefingBudget(
            maximumFeedSources: 1_000,
            maximumSlackWorkspaces: 1_000,
            maximumFeedConcurrency: 1_000,
            maximumFailureReasons: 1_000,
            maximumTotalDurationSeconds: 99_999,
            maximumFeedRequests: 1_000,
            maximumSlackRequests: 1_000,
            maximumNewArchiveItems: 1_000_000,
            maximumStorageGrowthBytes: .max,
            maximumTransientRetries: 1_000,
            maximumOllamaDurationSeconds: 9_999
        )
        XCTAssertEqual(budget.maximumFeedSources, ScheduledBriefingBudget.maximumAllowedFeedSources)
        XCTAssertEqual(budget.maximumSlackWorkspaces, ScheduledBriefingBudget.maximumAllowedSlackWorkspaces)
        XCTAssertEqual(budget.maximumFeedConcurrency, ScheduledBriefingBudget.maximumAllowedFeedConcurrency)
        XCTAssertEqual(budget.maximumFeedRequests, ScheduledBriefingBudget.maximumAllowedFeedRequests)
        XCTAssertEqual(budget.maximumSlackRequests, ScheduledBriefingBudget.maximumAllowedSlackRequests)
        XCTAssertEqual(budget.maximumNewArchiveItems, ScheduledBriefingBudget.maximumAllowedNewArchiveItems)
        XCTAssertEqual(budget.maximumStorageGrowthBytes, ScheduledBriefingBudget.maximumAllowedStorageGrowthBytes)
        XCTAssertEqual(budget.maximumTransientRetries, ScheduledBriefingBudget.maximumAllowedTransientRetries)
        XCTAssertEqual(budget.maximumOllamaDurationSeconds, ScheduledBriefingBudget.maximumAllowedOllamaDurationSeconds)

        let first = try Self.plan(feeds: ["feed-b", "feed-a", "feed-a"], slack: ["workspace-b", "workspace-a"])
        let second = try Self.plan(feeds: ["feed-a", "feed-b"], slack: ["workspace-a", "workspace-b"])
        XCTAssertEqual(first.feedSubscriptionIDs, ["feed-a", "feed-b"])
        XCTAssertEqual(first.slackWorkspaceIDs, ["workspace-a", "workspace-b"])
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testPlanFingerprintBindsEveryImmutableDecisionWithoutDelimiterCollisions() throws {
        let allowed = ScheduledBriefingEntitlementDecision(.init(
            feature: .dailyBriefScheduling,
            state: .available,
            acquisitionAllowed: true,
            reasonCode: "vault_entitlement_available"
        ))
        let baseline = try Self.plan(
            feeds: ["feed|a"],
            slack: ["workspace:a"],
            slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel,one"])],
            entitlementDecisions: [allowed]
        )
        let equivalent = try Self.plan(
            feeds: ["feed|a"],
            slack: ["workspace:a"],
            slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel,one", "channel,one"])],
            entitlementDecisions: [allowed]
        )
        XCTAssertEqual(baseline.fingerprint, equivalent.fingerprint)

        XCTAssertNotEqual(
            baseline.fingerprint,
            try Self.plan(
                feeds: ["feed", "a"],
                slack: ["workspace:a"],
                slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel,one"])],
                entitlementDecisions: [allowed]
            ).fingerprint
        )
        XCTAssertNotEqual(
            baseline.fingerprint,
            try Self.plan(
                feeds: ["feed|a"],
                slack: ["workspace:a"],
                slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel", "one"])],
                entitlementDecisions: [allowed]
            ).fingerprint
        )
        XCTAssertNotEqual(
            baseline.fingerprint,
            try Self.plan(
                feeds: ["feed|a"],
                slack: ["workspace:a"],
                slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel,one"])],
                notificationPrivacyMode: .summary,
                entitlementDecisions: [allowed]
            ).fingerprint
        )
        XCTAssertNotEqual(
            baseline.fingerprint,
            try Self.plan(
                feeds: ["feed|a"],
                slack: ["workspace:a"],
                slackSelections: [.init(workspaceID: "workspace:a", channelIDs: ["channel,one"])],
                entitlementDecisions: [.init(.init(
                    feature: .dailyBriefScheduling,
                    state: .expired,
                    acquisitionAllowed: false,
                    reasonCode: "vault_entitlement_expired"
                ))]
            ).fingerprint
        )
    }

    func testPersistedPlanMetadataUsesHashesAndBoundedDecisionsOnly() throws {
        let plan = try Self.plan(
            id: "private-run-id",
            feeds: ["private-feed-id"],
            slack: ["private-workspace-id"],
            slackSelections: [.init(workspaceID: "private-workspace-id", channelIDs: ["private-channel-id"])],
            entitlementDecisions: [.init(.init(
                feature: .dailyBriefScheduling,
                state: .available,
                acquisitionAllowed: true,
                reasonCode: "vault_entitlement_available"
            ))]
        )
        let snapshot = ScheduledBriefingRunSnapshot(
            plan: plan,
            state: .queued,
            reasonCode: ScheduledBriefingReason.queued,
            traceID: "trace-id",
            startedAt: Self.anchor,
            updatedAt: Self.anchor,
            completedAt: nil,
            sourceOutcomes: [],
            vaultOutcome: nil,
            briefID: nil,
            fallbackReasonCode: nil,
            failureReasonCodes: []
        )
        let stored = StoredScheduledBriefingRun(snapshot: snapshot)
        let encoded = try XCTUnwrap(String(data: stored.planMetadataData, encoding: .utf8))
        XCTAssertFalse(encoded.contains("private-feed-id"))
        XCTAssertFalse(encoded.contains("private-workspace-id"))
        XCTAssertFalse(encoded.contains("private-channel-id"))
        let metadata = try stored.planMetadata()
        XCTAssertEqual(metadata.schemaVersion, 2)
        XCTAssertEqual(metadata.briefingDay, plan.briefingDay)
        XCTAssertEqual(metadata.feedSourceHashes.count, 1)
        XCTAssertEqual(metadata.slackSelections.first?.channelHashes.count, 1)
        XCTAssertEqual(metadata.entitlementDecisions.first?.featureRaw, LokiPaidFeature.dailyBriefScheduling.rawValue)
        XCTAssertEqual(metadata.notificationPrivacyRaw, NotificationPrivacyMode.minimal.rawValue)
    }

    func testOllamaAllowanceUsesThePlanCapAndRejectsAnUnusableWindow() async {
        let planCappedLedger = ScheduledBriefingBudgetLedger(
            budget: .init(
                maximumTotalDurationSeconds: 300,
                maximumOllamaDurationSeconds: 17
            )
        )
        let planCappedClaim = await planCappedLedger.ollamaAllowance(userMaximumSeconds: 45)
        XCTAssertEqual(planCappedClaim.permit?.remainingDurationSeconds ?? 0, 17, accuracy: 0.001)
        XCTAssertNil(planCappedClaim.rejectionReasonCode)

        let userCappedLedger = ScheduledBriefingBudgetLedger(
            budget: .init(
                maximumTotalDurationSeconds: 300,
                maximumOllamaDurationSeconds: 60
            )
        )
        let userCappedClaim = await userCappedLedger.ollamaAllowance(userMaximumSeconds: 11)
        XCTAssertEqual(userCappedClaim.permit?.remainingDurationSeconds ?? 0, 11, accuracy: 0.001)

        let unusableLedger = ScheduledBriefingBudgetLedger(
            budget: .init(
                maximumTotalDurationSeconds: 300,
                maximumOllamaDurationSeconds: 4
            )
        )
        let unusableClaim = await unusableLedger.ollamaAllowance(userMaximumSeconds: 45)
        XCTAssertNil(unusableClaim.permit)
        XCTAssertEqual(unusableClaim.rejectionReasonCode, ScheduledBriefingBudgetReason.ollamaDurationExhausted)
    }

    func testOrderedRunUsesBoundedFeedConcurrencySequentialSlackAndDeterministicFallback() async throws {
        let plan = try Self.plan(feeds: ["feed-c", "feed-a", "feed-b"], slack: ["workspace-b", "workspace-a"])
        let sources = ScheduledBriefingTestSources()
        let vault = ScheduledBriefingTestVault()
        let draft = ScheduledBriefingDraft(brief: Self.brief())
        let assembler = ScheduledBriefingTestAssembler(draft: draft)
        let presenter = ScheduledBriefingTestPresenter(.skipped(reasonCode: "ollama_not_running"))
        let persistence = ScheduledBriefingTestPersistence()
        let traces = ScheduledBriefingTestTraceRecorder()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: vault,
            assembler: assembler,
            localPresenter: presenter,
            persistence: persistence,
            now: { Self.anchor },
            eventSink: { traces.append($0) }
        )

        let result = await coordinator.run(plan)
        let observations = await sources.observations()
        let vaultCounts = await vault.counts()

        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.brief?.id, "scheduled-brief")
        XCTAssertEqual(result.fallbackReasonCode, "ollama_not_running")
        XCTAssertEqual(result.sourceOutcomes.map(\.sourceID), ["feed-a", "feed-b", "feed-c", "workspace-a", "workspace-b"])
        XCTAssertLessThanOrEqual(observations.maximumFeeds, plan.budget.maximumFeedConcurrency)
        XCTAssertEqual(observations.slack, ["workspace-a", "workspace-b"])
        XCTAssertEqual(vaultCounts.reconciliations, 1)
        XCTAssertEqual(persistence.commits.count, 1)
        XCTAssertEqual(persistence.commits.first?.result.brief?.id, "scheduled-brief")
        XCTAssertEqual(assembler.receivedOutcomes.first?.map(\.sourceID), result.sourceOutcomes.map(\.sourceID))

        let events = traces.events()
        XCTAssertEqual(Set(events.map(\.traceID)).count, 1)
        XCTAssertTrue(events.contains { $0.event == .sourceRefresh && $0.status == .success })
        XCTAssertTrue(events.contains { $0.event == .vaultReconciliation && $0.status == .success })
        XCTAssertTrue(events.contains { $0.event == .localPresentation && $0.status == .skipped })
        let encoded = events.compactMap(ScheduledBriefingProductionTraceLogger.encodedLine).joined(separator: "\n")
        XCTAssertFalse(encoded.contains("feed-a"))
        XCTAssertFalse(encoded.contains("workspace-a"))
        XCTAssertFalse(encoded.contains("scheduled-run-private"))
    }

    func testDisabledSourcePoliciesDoNotExpandFromCapturedIdentifiers() async throws {
        let sources = ScheduledBriefingTestSources()
        let persistence = ScheduledBriefingTestPersistence()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: ScheduledBriefingTestVault(),
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: ScheduledBriefingTestPresenter(.skipped(reasonCode: "unused")),
            persistence: persistence,
            now: { Self.anchor }
        )
        let result = await coordinator.run(try Self.plan(
            feeds: ["feed-captured"],
            slack: ["workspace-captured"],
            refreshFeedsEnabled: false,
            refreshSlackEnabled: false,
            localPresentationEnabled: false
        ))

        let observations = await sources.observations()
        XCTAssertEqual(observations.feeds, [])
        XCTAssertEqual(observations.slack, [])
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(persistence.commits.count, 1)
    }

    func testPresentationDeadlineCommitsDeterministicFallbackAndRejectsLateResult() async throws {
        let presenter = ScheduledBriefingSuspendedPresenter()
        let persistence = ScheduledBriefingTestPersistence()
        let traces = ScheduledBriefingTestTraceRecorder()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: ScheduledBriefingTestSources(),
            vaultReconciler: ScheduledBriefingTestVault(),
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: presenter,
            persistence: persistence,
            eventSink: { traces.append($0) }
        )
        let plan = try Self.plan(
            feeds: [],
            slack: [],
            budget: .init(maximumTotalDurationSeconds: 1, maximumOllamaDurationSeconds: 60)
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = await coordinator.run(plan)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        for _ in 0..<50 {
            if await presenter.cancellationCount() > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let cancellationCount = await presenter.cancellationCount()

        XCTAssertLessThan(elapsed, 2.5)
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.brief?.id, Self.brief().id)
        XCTAssertEqual(result.fallbackReasonCode, ScheduledBriefingBudgetReason.ollamaDurationExhausted)
        XCTAssertEqual(persistence.commits.count, 1)
        XCTAssertEqual(cancellationCount, 1)
        let budgetEvent = try XCTUnwrap(traces.events().first(where: { $0.event == .budget }))
        XCTAssertEqual(budgetEvent.status, .degraded)
        XCTAssertEqual(budgetEvent.reasonCode, ScheduledBriefingBudgetReason.durationExhausted)
        XCTAssertEqual(budgetEvent.metadata[.exhaustionCount], "2")
        XCTAssertGreaterThanOrEqual(Int(budgetEvent.metadata[.ollamaElapsedMilliseconds] ?? "0") ?? 0, 900)

        await presenter.resolveLate()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(persistence.commits.count, 1)
    }

    func testPresentationValueCompletingAfterLogicalDeadlineIsDiscardedForDeterministicFallback() async throws {
        let clock = ScheduledBriefingAdvancingClock(uptime: 100, date: Self.anchor)
        let presenter = ScheduledBriefingAdvancingPresenter(
            clock: clock,
            advanceBy: 2,
            outcome: .generated(
                brief: Self.brief(),
                provenance: Self.provenance(briefID: Self.brief().id)
            )
        )
        let persistence = ScheduledBriefingTestPersistence()
        let traces = ScheduledBriefingTestTraceRecorder()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: ScheduledBriefingTestSources(),
            vaultReconciler: ScheduledBriefingTestVault(),
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: presenter,
            persistence: persistence,
            now: { clock.date() },
            uptime: { clock.uptime() },
            eventSink: { traces.append($0) }
        )
        let plan = try Self.plan(
            feeds: [],
            slack: [],
            budget: .init(maximumTotalDurationSeconds: 1, maximumOllamaDurationSeconds: 60)
        )

        let result = await coordinator.run(plan)

        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.brief, Self.brief())
        XCTAssertNil(result.generationProvenance)
        XCTAssertEqual(result.fallbackReasonCode, ScheduledBriefingBudgetReason.ollamaDurationExhausted)
        XCTAssertEqual(persistence.commits.count, 1)
        let budgetEvent = try XCTUnwrap(traces.events().first(where: { $0.event == .budget }))
        XCTAssertEqual(budgetEvent.reasonCode, ScheduledBriefingBudgetReason.durationExhausted)
        XCTAssertEqual(budgetEvent.metadata[.exhaustionCount], "2")
        XCTAssertEqual(budgetEvent.metadata[.ollamaElapsedMilliseconds], "2000")
    }

    func testSourceAndVaultFailuresCommitOneTruthfulPartialBrief() async throws {
        let failedFeed = ScheduledBriefingSourceOutcome(
            kind: .feed,
            sourceID: "feed-failed",
            status: .failed,
            reasonCodes: ["feed_request_timed_out"]
        )
        let sources = ScheduledBriefingTestSources(feedOutcomes: ["feed-failed": failedFeed])
        let vault = ScheduledBriefingTestVault(.init(status: .degraded, reasonCodes: ["vault_import_paused"]))
        let persistence = ScheduledBriefingTestPersistence()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: vault,
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: ScheduledBriefingTestPresenter(.skipped(reasonCode: "ollama_disabled")),
            persistence: persistence,
            now: { Self.anchor }
        )

        let result = await coordinator.run(try Self.plan(feeds: ["feed-failed", "feed-ok"], slack: []))

        XCTAssertEqual(result.state, .partial)
        XCTAssertEqual(result.failureReasonCodes, ["feed_request_timed_out", "vault_import_paused"])
        XCTAssertEqual(result.brief?.id, "scheduled-brief")
        XCTAssertEqual(persistence.commits.count, 1)
        XCTAssertEqual(persistence.commits.first?.result.state, .partial)
    }

    func testCancellationRejectsLateFeedAndNeverCommitsBrief() async throws {
        let sources = ScheduledBriefingTestSources(suspendedFeedID: "feed-late")
        let vault = ScheduledBriefingTestVault()
        let persistence = ScheduledBriefingTestPersistence()
        let traces = ScheduledBriefingTestTraceRecorder()
        let plan = try Self.plan(feeds: ["feed-late"], slack: [])
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: vault,
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: ScheduledBriefingTestPresenter(.skipped(reasonCode: "unused")),
            persistence: persistence,
            now: { Self.anchor },
            eventSink: { traces.append($0) }
        )

        let running = Task { await coordinator.run(plan) }
        while !(await sources.hasSuspendedFeed()) { await Task.yield() }
        let cancellationAccepted = await coordinator.cancel(runID: plan.id)
        XCTAssertTrue(cancellationAccepted)
        await sources.resolveSuspendedFeed()
        let result = await running.value
        let observations = await sources.observations()
        let vaultCounts = await vault.counts()

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertNil(result.brief)
        XCTAssertTrue(persistence.commits.isEmpty)
        XCTAssertGreaterThanOrEqual(observations.cancellations, 1)
        XCTAssertGreaterThanOrEqual(vaultCounts.cancellations, 1)
        XCTAssertTrue(traces.events().contains {
            $0.event == .lateResultRejected && $0.reasonCode == ScheduledBriefingReason.lateResultRejected
        })
    }

    func testTotalDurationBudgetCancelsSuspendedSourceAndRejectsLateCommit() async throws {
        let sources = ScheduledBriefingTestSources(suspendedFeedID: "feed-deadline")
        let vault = ScheduledBriefingTestVault()
        let persistence = ScheduledBriefingTestPersistence()
        let traces = ScheduledBriefingTestTraceRecorder()
        let plan = try Self.plan(
            feeds: ["feed-deadline"],
            slack: [],
            budget: .init(maximumTotalDurationSeconds: 1)
        )
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: vault,
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: ScheduledBriefingTestPresenter(.skipped(reasonCode: "unused")),
            persistence: persistence,
            eventSink: { traces.append($0) }
        )

        let running = Task { await coordinator.run(plan) }
        while !(await sources.hasSuspendedFeed()) { await Task.yield() }
        let result = await running.value
        let observationsAtTimeout = await sources.observations()

        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.reasonCode, ScheduledBriefingBudgetReason.durationExhausted)
        XCTAssertTrue(persistence.commits.isEmpty)
        XCTAssertGreaterThanOrEqual(observationsAtTimeout.cancellations, 1)
        XCTAssertTrue(traces.events().contains {
            $0.event == .budget
                && $0.status == .degraded
                && $0.reasonCode == ScheduledBriefingBudgetReason.durationExhausted
        })

        let snapshotCountAtTimeout = persistence.snapshots.count
        await sources.resolveSuspendedFeed()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(persistence.snapshots.count, snapshotCountAtTimeout)
        XCTAssertTrue(persistence.commits.isEmpty)
    }

    func testSecondRunIsSkippedWhileSingleOwnerIsActive() async throws {
        let sources = ScheduledBriefingTestSources(suspendedFeedID: "feed-hold")
        let persistence = ScheduledBriefingTestPersistence()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sources,
            vaultReconciler: ScheduledBriefingTestVault(),
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: Self.brief())),
            localPresenter: ScheduledBriefingTestPresenter(.skipped(reasonCode: "unused")),
            persistence: persistence,
            now: { Self.anchor }
        )
        let firstPlan = try Self.plan(id: "first-run", feeds: ["feed-hold"], slack: [])
        let secondPlan = try Self.plan(id: "second-run", feeds: [], slack: [])

        let first = Task { await coordinator.run(firstPlan) }
        while !(await sources.hasSuspendedFeed()) { await Task.yield() }
        let second = await coordinator.run(secondPlan)
        XCTAssertEqual(second.state, .skipped)
        XCTAssertEqual(second.reasonCode, ScheduledBriefingReason.runAlreadyActive)
        let cancellationAccepted = await coordinator.cancel(runID: firstPlan.id)
        XCTAssertTrue(cancellationAccepted)
        await sources.resolveSuspendedFeed()
        let firstResult = await first.value
        XCTAssertEqual(firstResult.state, .cancelled)
        XCTAssertTrue(persistence.commits.isEmpty)
    }

    func testLocalPresentationCannotChangeDeterministicAuthority() async throws {
        let deterministic = Self.brief()
        let changed = Brief(
            id: deterministic.id,
            date: deterministic.date,
            title: deterministic.title,
            summary: "model summary",
            status: deterministic.status,
            sections: [],
            generation: deterministic.generation
        )
        let presenter = ScheduledBriefingTestPresenter(.generated(brief: changed, provenance: Self.provenance(briefID: deterministic.id)))
        let persistence = ScheduledBriefingTestPersistence()
        let coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: ScheduledBriefingTestSources(),
            vaultReconciler: ScheduledBriefingTestVault(),
            assembler: ScheduledBriefingTestAssembler(draft: .init(brief: deterministic)),
            localPresenter: presenter,
            persistence: persistence,
            now: { Self.anchor }
        )

        let result = await coordinator.run(try Self.plan(feeds: [], slack: []))

        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.brief, deterministic)
        XCTAssertEqual(result.fallbackReasonCode, ScheduledBriefingReason.localPresentationAuthorityRejected)
        XCTAssertNil(result.generationProvenance)
    }

    func testStoredSourceResultHashesIdentifierAndBoundsReason() throws {
        let rawSourceID = "private-workspace-identifier"
        let outcome = ScheduledBriefingSourceOutcome(
            kind: .slackWorkspace,
            sourceID: rawSourceID,
            status: .failed,
            reasonCodes: [String(repeating: "x", count: 300)]
        )
        let stored = StoredScheduledBriefingSourceResult(
            runID: "run-id",
            outcome: outcome,
            startedAt: Self.anchor,
            completedAt: Self.anchor.addingTimeInterval(2)
        )

        XCTAssertEqual(stored.runID, "run-id")
        XCTAssertNotEqual(stored.sourceIDHash, rawSourceID)
        XCTAssertEqual(stored.sourceIDHash.count, 16)
        XCTAssertEqual(stored.reasonCode?.count, 120)
        XCTAssertEqual(stored.durationMilliseconds, 2_000)
    }

    private static func plan(
        id: String = "scheduled-run-private",
        feeds: [String],
        slack: [String],
        refreshFeedsEnabled: Bool = true,
        refreshSlackEnabled: Bool = true,
        slackSelections: [ScheduledBriefingSlackSelectionSnapshot]? = nil,
        localPresentationEnabled: Bool = true,
        localPresentationConsentedWorkspaceIDs: [String]? = nil,
        notificationsEnabled: Bool = true,
        notificationAuthorization: NotificationAuthorizationState = .authorized,
        notificationPrivacyMode: NotificationPrivacyMode = .minimal,
        entitlementDecisions: [ScheduledBriefingEntitlementDecision] = [],
        budget: ScheduledBriefingBudget = .init(maximumFeedConcurrency: 2)
    ) throws -> ScheduledBriefingPlan {
        try .init(
            id: id,
            occurrenceID: "occurrence-private",
            scheduledFor: anchor,
            trigger: .scheduled,
            feedSubscriptionIDs: feeds,
            slackWorkspaceIDs: slack,
            refreshFeedsEnabled: refreshFeedsEnabled,
            refreshSlackEnabled: refreshSlackEnabled,
            slackSelections: slackSelections ?? slack.map { .init(workspaceID: $0, channelIDs: ["channel-\($0)"]) },
            localPresentationEnabled: localPresentationEnabled,
            localPresentationConsentedWorkspaceIDs: localPresentationConsentedWorkspaceIDs ?? slack,
            notificationsEnabled: notificationsEnabled,
            notificationAuthorization: notificationAuthorization,
            notificationPrivacyMode: notificationPrivacyMode,
            entitlementDecisions: entitlementDecisions,
            budget: budget
        )
    }

    private static func brief() -> Brief {
        let item = BriefItem(
            id: "evidence-1",
            title: "Attributable update",
            summary: "Deterministic evidence summary.",
            priority: .normal,
            source: .init(id: "source", name: "Source", kind: .newsFeeds, state: .connected, capabilities: [.feeds], detail: "Selected source"),
            provenance: .init(sourceID: "source", publicationDate: anchor, retrievedAt: anchor, directURL: nil, isSynthetic: false, origin: .source),
            isRead: false
        )
        return .init(
            id: "scheduled-brief",
            date: anchor,
            title: "Scheduled Brief",
            summary: "One deterministic item.",
            status: .ready,
            sections: [.init(id: "news", title: "News and Research", items: [item])],
            generation: .init(
                engineID: "loki.deterministic.mixed.v1",
                generatedAt: anchor,
                status: .ready,
                reasonCode: "deterministic_mixed_brief_assembled",
                fixtureRevision: 0,
                providerKind: "deterministic",
                sourceItemIDs: ["evidence-1"],
                validationResult: "not_applicable"
            )
        )
    }

    private static func provenance(briefID: String) -> OllamaGenerationProvenance {
        .init(
            providerKind: "ollama",
            selectedModelName: "local-model",
            endpointClassification: .numericIPv4Loopback,
            promptTemplateVersion: "test",
            schemaVersion: OllamaOutputValidator.schemaVersion,
            generatedAt: anchor,
            sourceItemIdentifiers: ["evidence-1"],
            deterministicBriefIdentifier: briefID,
            completionStatus: .success,
            fallbackStatus: .notUsed,
            durationMilliseconds: 10,
            promptTokenCount: nil,
            outputTokenCount: nil,
            validationResult: .valid,
            failureReasonCode: nil
        )
    }
}
