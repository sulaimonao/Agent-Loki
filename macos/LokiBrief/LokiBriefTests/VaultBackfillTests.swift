import XCTest
@testable import LokiBrief

private actor VaultBackfillTestStore: VaultBackfillPersisting {
    private var value: (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint)?
    private var archived: [VaultBackfillArchiveItem] = []

    func load(jobID: String) async throws -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint)? {
        guard value?.job.id == jobID else { return nil }
        return value
    }

    func commit(
        job: VaultBackfillJob,
        checkpoint: VaultBackfillCheckpoint,
        items: [VaultBackfillArchiveItem]
    ) async throws -> VaultBackfillCommitResult {
        value = (job, checkpoint)
        archived.append(contentsOf: items)
        return .init(
            insertedItemCount: items.count,
            storedBytes: items.reduce(0) { $0 + $1.estimatedStorageBytes }
        )
    }

    func snapshot() -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint, items: [VaultBackfillArchiveItem])? {
        guard let value else { return nil }
        return (value.job, value.checkpoint, archived)
    }

    func forceInFlightState(_ state: VaultBackfillJobState, startedAt: Date) {
        guard var current = value else { return }
        current.job.state = state
        current.job.startedAt = startedAt
        value = current
    }
}

private actor VaultBackfillTestProvider: VaultBackfillPageFetching {
    enum Step: Sendable {
        case page(VaultBackfillPage)
        case failure(VaultBackfillProviderError)
        case suspended
    }

    nonisolated let providerIdentifier = "test"
    private var steps: [Step]
    private var suspendedContinuation: CheckedContinuation<VaultBackfillPage, Error>?
    private var fetches = 0
    private var cancellations = 0
    private var requests: [VaultBackfillFetchRequest] = []
    private let onFetch: (@Sendable () -> Void)?

    init(_ steps: [Step], onFetch: (@Sendable () -> Void)? = nil) {
        self.steps = steps
        self.onFetch = onFetch
    }

    func fetchPage(_ request: VaultBackfillFetchRequest) async throws -> VaultBackfillPage {
        fetches += 1
        requests.append(request)
        onFetch?()
        guard !steps.isEmpty else { throw VaultBackfillProviderError.invalidResponse }
        switch steps.removeFirst() {
        case let .page(page): return page
        case let .failure(error): throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                suspendedContinuation = continuation
            }
        }
    }

    func cancel(jobID: String) async { cancellations += 1 }

    func resolveSuspended(with page: VaultBackfillPage) {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(returning: page)
    }

    func fetchCount() -> Int { fetches }
    func cancellationCount() -> Int { cancellations }
    func requestedPages() -> [VaultBackfillFetchRequest] { requests }
}

private final class VaultBackfillTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class VaultBackfillTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VaultBackfillTraceEvent] = []

    func append(_ event: VaultBackfillTraceEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    func events() -> [VaultBackfillTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class VaultBackfillTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_785_000_000)

    func testCompletesAndNeverMutatesForwardCursor() async throws {
        let item = Self.item(id: "item-1", storage: 128)
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [item],
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let traces = VaultBackfillTraceRecorder()
        let engine = VaultBackfillEngine(
            provider: provider,
            persistence: store,
            now: { Self.anchor },
            traceSink: { event in traces.append(event) }
        )
        _ = try await engine.create(
            jobID: "job-private-sentinel",
            sources: [Self.source(forwardCursor: "forward-live-cursor")],
            budget: Self.budget()
        )

        let result = try await engine.run(
            jobID: "job-private-sentinel",
            trace: .init(traceID: "trace-fixed", spanID: "span-fixed")
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.stopReason, .completed)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertEqual(snapshot.checkpoint.sources[0].forwardCursor, "forward-live-cursor")
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)
        XCTAssertTrue(snapshot.checkpoint.sources[0].isHistoryComplete)
        XCTAssertEqual(snapshot.checkpoint.usage, .init(requests: 1, items: 1, durationMilliseconds: 0, storageBytes: 128, retries: 0))
        XCTAssertEqual(snapshot.items, [item])

        let encoded = String(decoding: try JSONEncoder().encode(traces.events()), as: UTF8.self)
        XCTAssertTrue(encoded.contains("vault.backfill.page_commit"))
        XCTAssertTrue(encoded.contains("trace-fixed"))
        XCTAssertFalse(encoded.contains("account-private"))
        XCTAssertFalse(encoded.contains("job-private-sentinel"))
    }

    func testRequestAndRetryBudgetsPersistHistoryCheckpointForManualResume() async throws {
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [Self.item(id: "first", storage: 10)],
                nextHistoryCursor: "history-page-2",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 2,
                retryCount: 1
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "budgeted",
            sources: [Self.source(forwardCursor: "forward-stays")],
            budget: .init(maximumRequests: 2, maximumItems: 10, maximumDuration: 30, maximumStorageBytes: 1_000, maximumRetries: 1)
        )

        let result = try await engine.run(jobID: "budgeted")

        XCTAssertEqual(result.state, .partiallyCompleted)
        XCTAssertEqual(result.stopReason, .requestBudgetExhausted)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertEqual(snapshot.checkpoint.sources[0].forwardCursor, "forward-stays")
        XCTAssertEqual(snapshot.checkpoint.sources[0].historyCursor, "history-page-2")
        XCTAssertEqual(snapshot.checkpoint.usage.requests, 2)
        XCTAssertEqual(snapshot.checkpoint.usage.retries, 1)
        let fetchCount = await provider.fetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testItemBudgetDoesNotAdvancePastUncommittedPage() async throws {
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [
                    Self.item(id: "one", storage: 60),
                    Self.item(id: "two", storage: 60),
                    Self.item(id: "three", storage: 10),
                ],
                nextHistoryCursor: "next",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "storage-budgeted",
            sources: [Self.source()],
            budget: .init(maximumRequests: 5, maximumItems: 2, maximumDuration: 30, maximumStorageBytes: 100, maximumRetries: 1)
        )

        let result = try await engine.run(jobID: "storage-budgeted")

        XCTAssertEqual(result.state, .partiallyCompleted)
        XCTAssertEqual(result.stopReason, .itemBudgetExhausted)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.checkpoint.usage.items, 0)
        XCTAssertEqual(snapshot.checkpoint.usage.storageBytes, 0)
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)
    }

    func testStorageBudgetDoesNotAdvancePastUncommittedPage() async throws {
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [
                    Self.item(id: "one", storage: 60),
                    Self.item(id: "two", storage: 60),
                ],
                nextHistoryCursor: "next",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "storage-only-budgeted",
            sources: [Self.source()],
            budget: .init(maximumRequests: 5, maximumItems: 3, maximumDuration: 30, maximumStorageBytes: 100, maximumRetries: 1)
        )

        let result = try await engine.run(jobID: "storage-only-budgeted")

        XCTAssertEqual(result.state, .partiallyCompleted)
        XCTAssertEqual(result.stopReason, .storageBudgetExhausted)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.checkpoint.usage.items, 0)
        XCTAssertEqual(snapshot.checkpoint.usage.storageBytes, 0)
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)
    }

    func testDurationBudgetUsesMeasuredFetchTime() async throws {
        let clock = VaultBackfillTestClock(Self.anchor)
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [],
                nextHistoryCursor: "next",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 1,
                retryCount: 0
            )),
        ], onFetch: { clock.advance(2) })
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { clock.now() })
        _ = try await engine.create(
            jobID: "duration-budgeted",
            sources: [Self.source()],
            budget: .init(maximumRequests: 5, maximumItems: 5, maximumDuration: 1, maximumStorageBytes: 1_000, maximumRetries: 1)
        )

        let result = try await engine.run(jobID: "duration-budgeted")

        XCTAssertEqual(result.stopReason, .durationBudgetExhausted)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertEqual(snapshot.checkpoint.usage.durationMilliseconds, 2_000)
    }

    func testPauseRejectsLateProviderResultWithoutArchiveOrCursorAdvance() async throws {
        let provider = VaultBackfillTestProvider([.suspended])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(jobID: "pause", sources: [Self.source(forwardCursor: "forward")], budget: Self.budget())

        let running = Task { try await engine.run(jobID: "pause") }
        while await provider.fetchCount() == 0 { await Task.yield() }
        let paused = try await engine.pause(jobID: "pause")
        XCTAssertEqual(paused.state, .paused)
        await provider.resolveSuspended(with: .init(
            items: [Self.item(id: "late", storage: 20)],
            nextHistoryCursor: "must-not-stick",
            nextHistoryUpperBound: Self.anchor,
            isHistoryComplete: false,
            requestCount: 1,
            retryCount: 0
        ))

        let returned = try await running.value
        XCTAssertEqual(returned.state, .paused)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)
        XCTAssertEqual(snapshot.checkpoint.sources[0].forwardCursor, "forward")
        let cancellationCount = await provider.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testSourceFailureAllowsOtherAccountsToCompletePartially() async throws {
        let second = Self.item(id: "second-account", accountID: "account-two", sourceID: "source-two", storage: 20)
        let provider = VaultBackfillTestProvider([
            .failure(.sourceUnavailable),
            .page(.init(items: [second], nextHistoryCursor: nil, nextHistoryUpperBound: nil, isHistoryComplete: true, requestCount: 1, retryCount: 0)),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "multi-account",
            sources: [Self.source(), Self.source(id: "two", accountID: "account-two", sourceID: "source-two")],
            budget: Self.budget()
        )

        let result = try await engine.run(jobID: "multi-account")

        XCTAssertEqual(result.state, .partiallyCompleted)
        XCTAssertEqual(result.failedSourceCount, 1)
        let stored = await store.snapshot()
        XCTAssertEqual((try XCTUnwrap(stored)).items.map(\.id), ["second-account"])
    }

    func testManualResumeUsesPersistedCursorAndFreshBudget() async throws {
        let first = Self.item(id: "first", storage: 10)
        let second = Self.item(id: "second", storage: 10)
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [first],
                nextHistoryCursor: "page-two",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 1,
                retryCount: 0
            )),
            .page(.init(
                items: [second],
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "resume",
            sources: [Self.source(forwardCursor: "forward-stable")],
            budget: .init(maximumRequests: 1, maximumItems: 10, maximumDuration: 30, maximumStorageBytes: 1_000, maximumRetries: 2)
        )

        let firstRun = try await engine.run(jobID: "resume")
        XCTAssertEqual(firstRun.state, .partiallyCompleted)
        XCTAssertEqual(firstRun.stopReason, .requestBudgetExhausted)

        let resumed = try await engine.resume(jobID: "resume", budget: Self.budget())

        XCTAssertEqual(resumed.state, .completed)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertEqual(snapshot.items.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.checkpoint.sources[0].forwardCursor, "forward-stable")
        XCTAssertTrue(snapshot.checkpoint.sources[0].isHistoryComplete)
        let requests = await provider.requestedPages()
        XCTAssertEqual(requests.map(\.historyCursor), [nil, "page-two"])
    }

    func testCrashStyleReopenRecoversRunningJobAndResumesFromDurableCheckpoint() async throws {
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [Self.item(id: "after-reopen", storage: 20)],
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let original = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await original.create(jobID: "crash-reopen", sources: [Self.source()], budget: Self.budget())
        await store.forceInFlightState(.running, startedAt: Self.anchor.addingTimeInterval(-10))

        let relaunched = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        let recovered = try await relaunched.status(jobID: "crash-reopen")
        XCTAssertEqual(recovered.job.state, .paused)
        XCTAssertEqual(recovered.job.stopReason, .persistenceFailed)

        let completed = try await relaunched.run(jobID: "crash-reopen")
        XCTAssertEqual(completed.state, .completed)
        let stored = await store.snapshot()
        XCTAssertEqual((try XCTUnwrap(stored)).items.map(\.id), ["after-reopen"])
    }

    func testCancelRejectsLateProviderCompletion() async throws {
        let provider = VaultBackfillTestProvider([.suspended])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(jobID: "cancel", sources: [Self.source()], budget: Self.budget())

        let running = Task { try await engine.run(jobID: "cancel") }
        while await provider.fetchCount() == 0 { await Task.yield() }
        let cancelled = try await engine.cancel(jobID: "cancel")
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.stopReason, .cancelledByUser)
        await provider.resolveSuspended(with: .init(
            items: [Self.item(id: "late-cancel", storage: 10)],
            nextHistoryCursor: "must-not-advance",
            nextHistoryUpperBound: Self.anchor,
            isHistoryComplete: false,
            requestCount: 1,
            retryCount: 0
        ))

        let returned = try await running.value
        XCTAssertEqual(returned.state, .cancelled)
        let stored = await store.snapshot()
        let snapshot = try XCTUnwrap(stored)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)
        let cancellationCount = await provider.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testRateLimitPersistsWaitAndDoesNotRefetchBeforeRetryAt() async throws {
        let clock = VaultBackfillTestClock(Self.anchor)
        let retryAt = Self.anchor.addingTimeInterval(60)
        let provider = VaultBackfillTestProvider([
            .failure(.rateLimited(retryAt: retryAt)),
            .page(.init(
                items: [Self.item(id: "after-rate-limit", storage: 10)],
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { clock.now() })
        _ = try await engine.create(jobID: "rate-limit", sources: [Self.source()], budget: Self.budget())

        let waiting = try await engine.run(jobID: "rate-limit")
        XCTAssertEqual(waiting.state, .waitingForRateLimit)
        XCTAssertEqual(waiting.nextRetryAt, retryAt)
        let storedWaiting = await store.snapshot()
        XCTAssertEqual((try XCTUnwrap(storedWaiting)).job.state, .waitingForRateLimit)

        let earlyRun = try await engine.run(jobID: "rate-limit")
        XCTAssertEqual(earlyRun.state, .waitingForRateLimit)
        let earlyFetchCount = await provider.fetchCount()
        XCTAssertEqual(earlyFetchCount, 1)
        clock.advance(61)
        let completed = try await engine.run(jobID: "rate-limit")
        XCTAssertEqual(completed.state, .completed)
        let finalFetchCount = await provider.fetchCount()
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testReauthorizationAndProviderUnavailableCanResumeWithoutCursorLoss() async throws {
        let scenarios: [(String, VaultBackfillProviderError, VaultBackfillJobState, VaultBackfillStopReason)] = [
            ("reauthorization", .reauthorizationRequired, .reauthorizationRequired, .reauthorizationRequired),
            ("provider-unavailable", .providerUnavailable, .providerUnavailable, .providerUnavailable),
        ]

        for (jobID, failure, expectedState, expectedReason) in scenarios {
            let provider = VaultBackfillTestProvider([
                .failure(failure),
                .page(.init(
                    items: [Self.item(id: "\(jobID)-item", storage: 10)],
                    nextHistoryCursor: nil,
                    nextHistoryUpperBound: nil,
                    isHistoryComplete: true,
                    requestCount: 1,
                    retryCount: 0
                )),
            ])
            let store = VaultBackfillTestStore()
            let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
            _ = try await engine.create(jobID: jobID, sources: [Self.source(forwardCursor: "forward")], budget: Self.budget())

            let degraded = try await engine.run(jobID: jobID)
            XCTAssertEqual(degraded.state, expectedState, jobID)
            XCTAssertEqual(degraded.stopReason, expectedReason, jobID)
            let degradedStored = await store.snapshot()
            XCTAssertNil((try XCTUnwrap(degradedStored)).checkpoint.sources[0].historyCursor)

            let completed = try await engine.resume(jobID: jobID, budget: Self.budget())
            XCTAssertEqual(completed.state, .completed, jobID)
            let completedStored = await store.snapshot()
            let checkpoint = try XCTUnwrap(completedStored).checkpoint.sources[0]
            XCTAssertEqual(checkpoint.forwardCursor, "forward", jobID)
            XCTAssertTrue(checkpoint.isHistoryComplete, jobID)
        }
    }

    func testCursorGapPreventionRefetchesWholePageAfterLargerResumeBudget() async throws {
        let pageItems = [
            Self.item(id: "one", storage: 10),
            Self.item(id: "two", storage: 10),
            Self.item(id: "three", storage: 10),
        ]
        let partialPage = VaultBackfillPage(
            items: pageItems,
            nextHistoryCursor: "after-page",
            nextHistoryUpperBound: Self.anchor,
            isHistoryComplete: false,
            requestCount: 1,
            retryCount: 0
        )
        let provider = VaultBackfillTestProvider([
            .page(partialPage),
            .page(.init(
                items: pageItems,
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "cursor-gap",
            sources: [Self.source()],
            budget: .init(maximumRequests: 10, maximumItems: 2, maximumDuration: 30, maximumStorageBytes: 1_000, maximumRetries: 2)
        )

        let bounded = try await engine.run(jobID: "cursor-gap")
        XCTAssertEqual(bounded.stopReason, .itemBudgetExhausted)
        let boundedStored = await store.snapshot()
        var snapshot = try XCTUnwrap(boundedStored)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNil(snapshot.checkpoint.sources[0].historyCursor)

        let completed = try await engine.resume(
            jobID: "cursor-gap",
            budget: .init(maximumRequests: 10, maximumItems: 3, maximumDuration: 30, maximumStorageBytes: 1_000, maximumRetries: 2)
        )
        XCTAssertEqual(completed.state, .completed)
        let completedStored = await store.snapshot()
        snapshot = try XCTUnwrap(completedStored)
        XCTAssertEqual(snapshot.items.map(\.id), ["one", "two", "three"])
        XCTAssertTrue(snapshot.checkpoint.sources[0].isHistoryComplete)
        let requestedPages = await provider.requestedPages()
        XCTAssertEqual(requestedPages.map(\.historyCursor), [nil, nil])
    }

    func testRetryBudgetResetsForExplicitResume() async throws {
        let provider = VaultBackfillTestProvider([
            .page(.init(
                items: [Self.item(id: "retry-first", storage: 10)],
                nextHistoryCursor: "retry-next",
                nextHistoryUpperBound: Self.anchor,
                isHistoryComplete: false,
                requestCount: 2,
                retryCount: 1
            )),
            .page(.init(
                items: [Self.item(id: "retry-second", storage: 10)],
                nextHistoryCursor: nil,
                nextHistoryUpperBound: nil,
                isHistoryComplete: true,
                requestCount: 1,
                retryCount: 0
            )),
        ])
        let store = VaultBackfillTestStore()
        let engine = VaultBackfillEngine(provider: provider, persistence: store, now: { Self.anchor })
        _ = try await engine.create(
            jobID: "retry-budget",
            sources: [Self.source()],
            budget: .init(maximumRequests: 10, maximumItems: 10, maximumDuration: 30, maximumStorageBytes: 1_000, maximumRetries: 1)
        )

        let firstRun = try await engine.run(jobID: "retry-budget")
        XCTAssertEqual(firstRun.stopReason, .retryBudgetExhausted)
        let resumed = try await engine.resume(jobID: "retry-budget", budget: Self.budget())
        XCTAssertEqual(resumed.state, .completed)
        let stored = await store.snapshot()
        XCTAssertEqual((try XCTUnwrap(stored)).items.map(\.id), ["retry-first", "retry-second"])
    }

    private static func budget() -> VaultBackfillBudget {
        .init(maximumRequests: 10, maximumItems: 100, maximumDuration: 60, maximumStorageBytes: 100_000, maximumRetries: 3)
    }

    private static func source(
        id: String = "one",
        accountID: String = "account-private",
        sourceID: String = "source-private",
        forwardCursor: String? = nil
    ) -> VaultBackfillSourceCheckpoint {
        .init(
            id: id,
            accountID: accountID,
            sourceID: sourceID,
            forwardCursor: forwardCursor,
            historyCursor: nil,
            historyUpperBound: anchor,
            isHistoryComplete: false,
            failureReasonCode: nil
        )
    }

    private static func item(
        id: String,
        accountID: String = "account-private",
        sourceID: String = "source-private",
        storage: Int
    ) -> VaultBackfillArchiveItem {
        .init(
            id: id,
            provider: "test",
            accountID: accountID,
            sourceID: sourceID,
            sourceName: "Source",
            occurredAt: anchor,
            title: "Title",
            body: "Body",
            authorName: "Author",
            providerItemID: id,
            isTombstone: false,
            estimatedStorageBytes: storage
        )
    }
}

private extension VaultBackfillUsage {
    init(requests: Int, items: Int, durationMilliseconds: Int, storageBytes: Int, retries: Int) {
        self.init()
        self.requests = requests
        self.items = items
        self.durationMilliseconds = durationMilliseconds
        self.storageBytes = storageBytes
        self.retries = retries
    }
}
