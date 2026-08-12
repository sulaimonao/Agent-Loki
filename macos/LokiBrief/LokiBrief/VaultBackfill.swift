import CryptoKit
import Foundation

// MARK: - Durable contract

enum VaultBackfillJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case running
    case pausing
    case paused
    case resuming
    case waitingForRateLimit = "waiting_for_rate_limit"
    case reauthorizationRequired = "reauthorization_required"
    case providerUnavailable = "provider_unavailable"
    case cancelling
    case cancelled
    case partiallyCompleted = "partially_completed"
    case completed
    case failed

    var isTerminal: Bool {
        switch self {
        case .cancelled, .partiallyCompleted, .completed, .failed: true
        default: false
        }
    }
}

enum VaultBackfillDirection: String, Codable, CaseIterable, Sendable {
    case forward
    case historical
}

enum VaultBackfillStopReason: String, Codable, CaseIterable, Sendable {
    case none
    case pausedByUser = "vault_backfill_paused_by_user"
    case cancelledByUser = "vault_backfill_cancelled_by_user"
    case requestBudgetExhausted = "vault_backfill_request_budget_exhausted"
    case itemBudgetExhausted = "vault_backfill_item_budget_exhausted"
    case durationBudgetExhausted = "vault_backfill_duration_budget_exhausted"
    case storageBudgetExhausted = "vault_backfill_storage_budget_exhausted"
    case retryBudgetExhausted = "vault_backfill_retry_budget_exhausted"
    case rateLimited = "vault_backfill_rate_limited"
    case reauthorizationRequired = "vault_backfill_reauthorization_required"
    case providerUnavailable = "vault_backfill_provider_unavailable"
    case sourcePartiallyFailed = "vault_backfill_source_partially_failed"
    case invalidCheckpoint = "vault_backfill_invalid_checkpoint"
    case persistenceFailed = "vault_backfill_persistence_failed"
    case lateResultRejected = "vault_backfill_late_result_rejected"
    case completed = "vault_backfill_completed"
}

struct VaultBackfillBudget: Codable, Hashable, Sendable {
    let maximumRequests: Int
    let maximumItems: Int
    let maximumDuration: TimeInterval
    let maximumStorageBytes: Int
    let maximumRetries: Int

    init(
        maximumRequests: Int,
        maximumItems: Int,
        maximumDuration: TimeInterval,
        maximumStorageBytes: Int,
        maximumRetries: Int
    ) {
        self.maximumRequests = max(0, maximumRequests)
        self.maximumItems = max(0, maximumItems)
        self.maximumDuration = maximumDuration.isFinite ? max(0, maximumDuration) : 0
        self.maximumStorageBytes = max(0, maximumStorageBytes)
        self.maximumRetries = max(0, maximumRetries)
    }
}

struct VaultBackfillUsage: Codable, Hashable, Sendable {
    var requests = 0
    var items = 0
    var durationMilliseconds = 0
    var storageBytes = 0
    var retries = 0
}

/// One independently pageable provider source, such as a selected Slack channel.
/// `forwardCursor` belongs to live ingestion and is immutable to this engine.
struct VaultBackfillSourceCheckpoint: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let sourceID: String
    let forwardCursor: String?
    var historyCursor: String?
    var historyUpperBound: Date?
    var isHistoryComplete: Bool
    var failureReasonCode: String?
    var newestSynchronizedAt: Date? = nil
    var oldestSynchronizedAt: Date? = nil
    var lastSuccessfulRetrievalAt: Date? = nil
    var lastRateLimitAt: Date? = nil
    var exhaustedAt: Date? = nil
}

struct VaultBackfillCheckpoint: Codable, Hashable, Sendable {
    let schemaVersion: Int
    var sourceIndex: Int
    var sources: [VaultBackfillSourceCheckpoint]
    var usage: VaultBackfillUsage
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        sourceIndex: Int = 0,
        sources: [VaultBackfillSourceCheckpoint],
        usage: VaultBackfillUsage = .init(),
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sourceIndex = sourceIndex
        self.sources = sources
        self.usage = usage
        self.updatedAt = updatedAt
    }
}

struct VaultBackfillJob: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: String
    let createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var state: VaultBackfillJobState
    var stopReason: VaultBackfillStopReason
    var budget: VaultBackfillBudget
    var nextRetryAt: Date?
    var generation: UInt64
    var failedSourceCount: Int
}

/// A bounded, provider-neutral item at the database handoff boundary. The stable
/// key and source metadata are retained; credentials, raw provider payloads,
/// files, and thread bodies are deliberately absent.
struct VaultBackfillArchiveItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: String
    let accountID: String
    let sourceID: String
    let sourceName: String
    let occurredAt: Date
    let title: String
    let body: String
    let authorName: String?
    let providerItemID: String
    let isTombstone: Bool
    let estimatedStorageBytes: Int
    let sourceURL: URL?
    let directlyMentionsUser: Bool
    let isEdited: Bool
    let editedAt: Date?
    let threadRootID: String?
    let replyCount: Int
    let retrievedAt: Date
    let contentOrigin: VaultContentOrigin

    init(
        id: String,
        provider: String,
        accountID: String,
        sourceID: String,
        sourceName: String,
        occurredAt: Date,
        title: String,
        body: String,
        authorName: String?,
        providerItemID: String,
        isTombstone: Bool,
        estimatedStorageBytes: Int,
        sourceURL: URL? = nil,
        directlyMentionsUser: Bool = false,
        isEdited: Bool = false,
        editedAt: Date? = nil,
        threadRootID: String? = nil,
        replyCount: Int = 0,
        retrievedAt: Date? = nil,
        contentOrigin: VaultContentOrigin = .source
    ) {
        self.id = id
        self.provider = provider
        self.accountID = accountID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.occurredAt = occurredAt
        self.title = title
        self.body = body
        self.authorName = authorName
        self.providerItemID = providerItemID
        self.isTombstone = isTombstone
        self.estimatedStorageBytes = max(0, estimatedStorageBytes)
        self.sourceURL = sourceURL
        self.directlyMentionsUser = directlyMentionsUser
        self.isEdited = isEdited
        self.editedAt = editedAt
        self.threadRootID = threadRootID
        self.replyCount = max(0, replyCount)
        self.retrievedAt = retrievedAt ?? occurredAt
        self.contentOrigin = contentOrigin
    }
}

struct VaultBackfillFetchRequest: Codable, Hashable, Sendable {
    let jobID: String
    let provider: String
    let accountID: String
    let sourceID: String
    let historyCursor: String?
    let historyUpperBound: Date?
    let maximumItems: Int
    let trace: VaultBackfillTraceContext
}

struct VaultBackfillPage: Codable, Hashable, Sendable {
    let items: [VaultBackfillArchiveItem]
    let nextHistoryCursor: String?
    let nextHistoryUpperBound: Date?
    let isHistoryComplete: Bool
    let requestCount: Int
    let retryCount: Int
}

enum VaultBackfillProviderError: Error, Codable, Hashable, Sendable {
    case rateLimited(retryAt: Date)
    case reauthorizationRequired
    case providerUnavailable
    case sourceUnavailable
    case invalidResponse
    case cancelled
}

struct VaultBackfillCommitResult: Codable, Hashable, Sendable {
    let insertedItemCount: Int
    let storedBytes: Int
}

protocol VaultBackfillPageFetching: Sendable {
    var providerIdentifier: String { get }
    func fetchPage(_ request: VaultBackfillFetchRequest) async throws -> VaultBackfillPage
    func cancel(jobID: String) async
}

/// Implementations must durably and atomically write job, checkpoint, and items.
/// This is the integration seam for `VaultDatabase`; the engine has no in-memory
/// fallback because a resumable job must never acknowledge an unpersisted cursor.
protocol VaultBackfillPersisting: Sendable {
    func load(jobID: String) async throws -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint)?
    func commit(
        job: VaultBackfillJob,
        checkpoint: VaultBackfillCheckpoint,
        items: [VaultBackfillArchiveItem]
    ) async throws -> VaultBackfillCommitResult
}

// MARK: - Redacted trace contract

struct VaultBackfillTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = Self.bounded(traceID)
        self.spanID = Self.bounded(spanID)
        self.parentSpanID = parentSpanID.map(Self.bounded)
    }

    func child(spanID: String = UUID().uuidString.lowercased()) -> VaultBackfillTraceContext {
        .init(traceID: traceID, spanID: spanID, parentSpanID: self.spanID)
    }

    private static func bounded(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128))
    }
}

enum VaultBackfillTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum VaultBackfillTraceEventName: String, Codable, CaseIterable, Sendable {
    case jobState = "vault.backfill.job_state"
    case pageFetch = "vault.backfill.page_fetch"
    case pageCommit = "vault.backfill.page_commit"
    case checkpoint = "vault.backfill.checkpoint"
    case budget = "vault.backfill.budget"
    case lateResult = "vault.backfill.late_result"
}

struct VaultBackfillTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: VaultBackfillTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: VaultBackfillTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case ts, event, component, status, metadata
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case reasonCode = "reason_code"
        case durationMilliseconds = "duration_ms"
    }
}

enum VaultBackfillPrivacy {
    static func hashIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedText(_ value: String, maximum: Int) -> String {
        let filtered = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(filtered).prefix(maximum))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func boundedMetadata(_ values: [(String, String)]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.prefix(16).map { key, value in
            let safeKey = String(key.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64))
            let safeValue = String(value.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
            }.prefix(160))
            return (safeKey, safeValue)
        })
    }
}

// MARK: - Manual resumable engine

actor VaultBackfillEngine {
    typealias TraceSink = @Sendable (VaultBackfillTraceEvent) -> Void

    private struct ActiveRun {
        var job: VaultBackfillJob
        var checkpoint: VaultBackfillCheckpoint
    }

    private let provider: any VaultBackfillPageFetching
    private let persistence: any VaultBackfillPersisting
    private let now: @Sendable () -> Date
    private let traceSink: TraceSink?
    private var active: [String: ActiveRun] = [:]

    init(
        provider: any VaultBackfillPageFetching,
        persistence: any VaultBackfillPersisting,
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: TraceSink? = nil
    ) {
        self.provider = provider
        self.persistence = persistence
        self.now = now
        self.traceSink = traceSink
    }

    func create(
        jobID: String = UUID().uuidString.lowercased(),
        sources: [VaultBackfillSourceCheckpoint],
        budget: VaultBackfillBudget,
        trace: VaultBackfillTraceContext = .init()
    ) async throws -> VaultBackfillJob {
        let timestamp = now()
        guard !jobID.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.accountID.isEmpty && !$0.sourceID.isEmpty })
        else { throw VaultBackfillProviderError.invalidResponse }

        let job = VaultBackfillJob(
            id: jobID,
            provider: provider.providerIdentifier,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: nil,
            finishedAt: nil,
            state: .queued,
            stopReason: .none,
            budget: budget,
            nextRetryAt: nil,
            generation: 0,
            failedSourceCount: 0
        )
        let checkpoint = VaultBackfillCheckpoint(sources: sources, updatedAt: timestamp)
        _ = try await persistence.commit(job: job, checkpoint: checkpoint, items: [])
        active[jobID] = .init(job: job, checkpoint: checkpoint)
        emit(.jobState, trace: trace, status: .started, reason: "vault_backfill_queued", job: job, checkpoint: checkpoint)
        return job
    }

    /// Runs only when explicitly invoked. There is intentionally no timer,
    /// scheduler, launch hook, or background task in this type.
    func run(jobID: String, trace: VaultBackfillTraceContext = .init()) async throws -> VaultBackfillJob {
        var run = try await loadedRun(jobID: jobID)
        guard [.queued, .paused, .waitingForRateLimit, .reauthorizationRequired, .providerUnavailable, .partiallyCompleted].contains(run.job.state) else {
            return run.job
        }
        if run.job.state == .waitingForRateLimit,
           let retryAt = run.job.nextRetryAt,
           retryAt > now() {
            return run.job
        }

        if run.job.state == .partiallyCompleted {
            // Budgets apply to one explicit foreground run. The durable provider
            // cursor remains cumulative; usage resets so a later manual resume
            // can make bounded progress instead of re-entering an exhausted gate.
            run.checkpoint.usage = .init()
            run.job.finishedAt = nil
        }
        run.job.generation &+= 1
        let generation = run.job.generation
        run.job.state = run.job.startedAt == nil ? .preparing : .resuming
        run.job.stopReason = .none
        run.job.nextRetryAt = nil
        run.job.startedAt = run.job.startedAt ?? now()
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: run.job.state == .preparing ? "vault_backfill_preparing" : "vault_backfill_resuming")

        run.job.state = .running
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: run.job.startedAt == run.job.createdAt ? "vault_backfill_started" : "vault_backfill_resumed")
        while run.checkpoint.sourceIndex < run.checkpoint.sources.count {
            guard isCurrent(jobID: jobID, generation: generation) else { return try await currentJob(jobID: jobID) }
            if let stop = budgetStop(for: run) {
                return try await finishBudgeted(run, reason: stop, trace: trace)
            }

            let index = run.checkpoint.sourceIndex
            if run.checkpoint.sources[index].isHistoryComplete {
                run.checkpoint.sourceIndex += 1
                continue
            }
            let source = run.checkpoint.sources[index]
            let pageTrace = trace.child()
            emit(.pageFetch, trace: pageTrace, status: .started, reason: "vault_backfill_page_fetch_started", job: run.job, checkpoint: run.checkpoint, source: source)
            let request = VaultBackfillFetchRequest(
                jobID: jobID,
                provider: run.job.provider,
                accountID: source.accountID,
                sourceID: source.sourceID,
                historyCursor: source.historyCursor,
                historyUpperBound: source.historyUpperBound,
                maximumItems: min(15, max(0, run.job.budget.maximumItems - run.checkpoint.usage.items)),
                trace: pageTrace
            )

            let page: VaultBackfillPage
            let fetchStartedAt = now()
            do {
                page = try await provider.fetchPage(request)
            } catch {
                guard isCurrent(jobID: jobID, generation: generation) else {
                    emit(.lateResult, trace: pageTrace, status: .skipped, reason: VaultBackfillStopReason.lateResultRejected.rawValue, job: run.job, checkpoint: run.checkpoint, source: source)
                    return try await currentJob(jobID: jobID)
                }
                if case .sourceUnavailable = error as? VaultBackfillProviderError {
                    run.checkpoint.sources[index].failureReasonCode = VaultBackfillStopReason.sourcePartiallyFailed.rawValue
                    run.checkpoint.sources[index].isHistoryComplete = true
                    run.checkpoint.sourceIndex += 1
                    run.checkpoint.updatedAt = now()
                    run.job.failedSourceCount += 1
                    run.job.updatedAt = now()
                    active[jobID] = run
                    try await persistControl(run, trace: pageTrace, reason: VaultBackfillStopReason.sourcePartiallyFailed.rawValue)
                    continue
                }
                return try await handle(error: error, run: run, sourceIndex: index, trace: pageTrace)
            }

            guard isCurrent(jobID: jobID, generation: generation) else {
                emit(.lateResult, trace: pageTrace, status: .skipped, reason: VaultBackfillStopReason.lateResultRejected.rawValue, job: run.job, checkpoint: run.checkpoint, source: source)
                return try await currentJob(jobID: jobID)
            }
            guard page.requestCount > 0, page.retryCount >= 0, page.items.count <= 15,
                  page.items.allSatisfy({ $0.provider == run.job.provider && $0.accountID == source.accountID && $0.sourceID == source.sourceID && $0.estimatedStorageBytes >= 0 }),
                  page.isHistoryComplete || page.nextHistoryCursor != nil || page.nextHistoryUpperBound != nil
            else {
                return try await handle(error: VaultBackfillProviderError.invalidResponse, run: run, sourceIndex: index, trace: pageTrace)
            }

            let elapsed = max(0, Int(now().timeIntervalSince(fetchStartedAt) * 1_000))
            run.checkpoint.usage.requests += page.requestCount
            run.checkpoint.usage.retries += page.retryCount
            run.checkpoint.usage.durationMilliseconds += elapsed

            let accepted = boundedItems(page.items, run: run)
            let storageEstimate = accepted.reduce(0) { $0 + $1.estimatedStorageBytes }
            if accepted.count != page.items.count {
                // Never advance a provider cursor past uncommitted items. A later
                // explicit run refetches this page with a fresh bounded budget;
                // archive IDs make the operation duplicate-safe.
                run.checkpoint.updatedAt = now()
                run.job.updatedAt = now()
                active[jobID] = run
                try await persistControl(run, trace: pageTrace, reason: "vault_backfill_page_not_advanced")
                let itemRoom = max(0, run.job.budget.maximumItems - run.checkpoint.usage.items)
                let reason: VaultBackfillStopReason = itemRoom < page.items.count ? .itemBudgetExhausted : .storageBudgetExhausted
                return try await finishBudgeted(run, reason: reason, trace: pageTrace)
            }
            run.checkpoint.usage.items += accepted.count
            run.checkpoint.usage.storageBytes += storageEstimate
            run.checkpoint.sources[index].historyCursor = page.nextHistoryCursor
            run.checkpoint.sources[index].historyUpperBound = page.nextHistoryUpperBound
            run.checkpoint.sources[index].isHistoryComplete = page.isHistoryComplete
            run.checkpoint.sources[index].failureReasonCode = nil
            run.checkpoint.sources[index].lastSuccessfulRetrievalAt = now()
            if let newest = accepted.map(\.occurredAt).max() {
                run.checkpoint.sources[index].newestSynchronizedAt = max(run.checkpoint.sources[index].newestSynchronizedAt ?? newest, newest)
            }
            if let oldest = accepted.map(\.occurredAt).min() {
                run.checkpoint.sources[index].oldestSynchronizedAt = min(run.checkpoint.sources[index].oldestSynchronizedAt ?? oldest, oldest)
            }
            if page.isHistoryComplete { run.checkpoint.sources[index].exhaustedAt = now() }
            if page.isHistoryComplete { run.checkpoint.sourceIndex += 1 }
            run.checkpoint.updatedAt = now()
            run.job.updatedAt = now()

            let commit = try await persistence.commit(job: run.job, checkpoint: run.checkpoint, items: accepted)
            guard commit.insertedItemCount >= 0,
                  commit.insertedItemCount <= accepted.count,
                  commit.storedBytes >= 0,
                  commit.storedBytes <= storageEstimate
            else { throw VaultBackfillProviderError.invalidResponse }
            // Estimated bytes are persisted atomically with the cursor and items.
            // Over-counting duplicates is conservative and avoids a crash window
            // where a cursor advances before storage usage is durable.
            active[jobID] = run
            emit(.pageCommit, trace: pageTrace, status: accepted.count == page.items.count ? .success : .degraded, reason: accepted.count == page.items.count ? "vault_backfill_page_committed" : "vault_backfill_page_bounded", job: run.job, checkpoint: run.checkpoint, source: source, extra: [
                ("page_items", String(page.items.count)), ("accepted_items", String(accepted.count)),
                ("stored_bytes", String(commit.storedBytes)),
            ])
        }

        run.job.state = run.job.failedSourceCount == 0 ? .completed : .partiallyCompleted
        run.job.stopReason = run.job.failedSourceCount == 0 ? .completed : .sourcePartiallyFailed
        run.job.finishedAt = now()
        run.job.updatedAt = now()
        run.checkpoint.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: run.job.stopReason.rawValue)
        return run.job
    }

    func pause(jobID: String, trace: VaultBackfillTraceContext = .init()) async throws -> VaultBackfillJob {
        var run = try await loadedRun(jobID: jobID)
        guard [.running, .resuming].contains(run.job.state) else { return run.job }
        run.job.state = .pausing
        run.job.generation &+= 1
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: "vault_backfill_pause_requested")
        await provider.cancel(jobID: jobID)
        run.job.state = .paused
        run.job.stopReason = .pausedByUser
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: VaultBackfillStopReason.pausedByUser.rawValue)
        return run.job
    }

    func cancel(jobID: String, trace: VaultBackfillTraceContext = .init()) async throws -> VaultBackfillJob {
        var run = try await loadedRun(jobID: jobID)
        guard !run.job.state.isTerminal else { return run.job }
        run.job.state = .cancelling
        run.job.generation &+= 1
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: "vault_backfill_cancel_requested")
        await provider.cancel(jobID: jobID)
        run.job.state = .cancelled
        run.job.stopReason = .cancelledByUser
        run.job.finishedAt = now()
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: VaultBackfillStopReason.cancelledByUser.rawValue)
        return run.job
    }

    func status(jobID: String) async throws -> (job: VaultBackfillJob, checkpoint: VaultBackfillCheckpoint) {
        let run = try await loadedRun(jobID: jobID)
        return (run.job, run.checkpoint)
    }

    func resume(
        jobID: String,
        budget: VaultBackfillBudget,
        trace: VaultBackfillTraceContext = .init()
    ) async throws -> VaultBackfillJob {
        var run = try await loadedRun(jobID: jobID)
        guard [.paused, .partiallyCompleted, .waitingForRateLimit, .reauthorizationRequired, .providerUnavailable].contains(run.job.state) else {
            return run.job
        }
        run.job.budget = budget
        if run.job.state == .partiallyCompleted { run.checkpoint.usage = .init() }
        run.job.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: "vault_backfill_resume_budget_updated")
        return try await self.run(jobID: jobID, trace: trace.child())
    }

    func skipContainer(jobID: String, trace: VaultBackfillTraceContext = .init()) async throws -> VaultBackfillJob {
        var run = try await loadedRun(jobID: jobID)
        guard run.checkpoint.sourceIndex < run.checkpoint.sources.count else { return run.job }
        let index = run.checkpoint.sourceIndex
        run.job.generation &+= 1
        await provider.cancel(jobID: jobID)
        run.checkpoint.sources[index].failureReasonCode = VaultBackfillStopReason.sourcePartiallyFailed.rawValue
        run.checkpoint.sources[index].isHistoryComplete = true
        run.checkpoint.sources[index].exhaustedAt = now()
        run.checkpoint.sourceIndex += 1
        run.job.failedSourceCount += 1
        run.job.state = .paused
        run.job.stopReason = .sourcePartiallyFailed
        run.job.updatedAt = now()
        run.checkpoint.updatedAt = now()
        active[jobID] = run
        try await persistControl(run, trace: trace, reason: "vault_backfill_container_skipped")
        return run.job
    }

    private func loadedRun(jobID: String) async throws -> ActiveRun {
        if let value = active[jobID] { return value }
        guard let value = try await persistence.load(jobID: jobID) else {
            throw VaultBackfillProviderError.invalidResponse
        }
        guard value.job.provider == provider.providerIdentifier,
              value.checkpoint.schemaVersion == 1,
              value.checkpoint.sourceIndex >= 0,
              value.checkpoint.sourceIndex <= value.checkpoint.sources.count
        else { throw VaultBackfillProviderError.invalidResponse }
        var recoveredJob = value.job
        switch recoveredJob.state {
        case .running, .resuming, .preparing, .pausing:
            recoveredJob.state = .paused
            recoveredJob.stopReason = .persistenceFailed
            recoveredJob.generation &+= 1
            recoveredJob.updatedAt = now()
        case .cancelling:
            recoveredJob.state = .cancelled
            recoveredJob.stopReason = .cancelledByUser
            recoveredJob.finishedAt = now()
            recoveredJob.generation &+= 1
            recoveredJob.updatedAt = now()
        default:
            break
        }
        let run = ActiveRun(job: recoveredJob, checkpoint: value.checkpoint)
        active[jobID] = run
        if recoveredJob != value.job {
            _ = try await persistence.commit(job: recoveredJob, checkpoint: value.checkpoint, items: [])
        }
        return run
    }

    private func currentJob(jobID: String) async throws -> VaultBackfillJob {
        try await loadedRun(jobID: jobID).job
    }

    private func isCurrent(jobID: String, generation: UInt64) -> Bool {
        guard let run = active[jobID] else { return false }
        return run.job.generation == generation && [.running, .resuming].contains(run.job.state)
    }

    private func budgetStop(for run: ActiveRun) -> VaultBackfillStopReason? {
        let usage = run.checkpoint.usage
        let budget = run.job.budget
        if usage.requests >= budget.maximumRequests { return .requestBudgetExhausted }
        if usage.items >= budget.maximumItems { return .itemBudgetExhausted }
        if usage.durationMilliseconds >= Int(budget.maximumDuration * 1_000) { return .durationBudgetExhausted }
        if usage.storageBytes >= budget.maximumStorageBytes { return .storageBudgetExhausted }
        if usage.retries >= budget.maximumRetries && usage.retries > 0 { return .retryBudgetExhausted }
        return nil
    }

    private func boundedItems(_ items: [VaultBackfillArchiveItem], run: ActiveRun) -> [VaultBackfillArchiveItem] {
        let itemRoom = max(0, run.job.budget.maximumItems - run.checkpoint.usage.items)
        var storageRoom = max(0, run.job.budget.maximumStorageBytes - run.checkpoint.usage.storageBytes)
        var accepted: [VaultBackfillArchiveItem] = []
        for item in items.prefix(itemRoom) where item.estimatedStorageBytes <= storageRoom {
            accepted.append(item)
            storageRoom -= item.estimatedStorageBytes
        }
        return accepted
    }

    private func finishBudgeted(
        _ value: ActiveRun,
        reason: VaultBackfillStopReason,
        trace: VaultBackfillTraceContext
    ) async throws -> VaultBackfillJob {
        var run = value
        run.job.state = .partiallyCompleted
        run.job.stopReason = reason
        run.job.finishedAt = now()
        run.job.updatedAt = now()
        run.checkpoint.updatedAt = now()
        active[run.job.id] = run
        try await persistControl(run, trace: trace, reason: reason.rawValue, event: .budget)
        return run.job
    }

    private func handle(
        error: Error,
        run value: ActiveRun,
        sourceIndex: Int,
        trace: VaultBackfillTraceContext
    ) async throws -> VaultBackfillJob {
        var run = value
        switch error as? VaultBackfillProviderError {
        case let .rateLimited(retryAt):
            run.job.state = .waitingForRateLimit
            run.job.stopReason = .rateLimited
            run.job.nextRetryAt = retryAt
        case .reauthorizationRequired:
            run.job.state = .reauthorizationRequired
            run.job.stopReason = .reauthorizationRequired
        case .providerUnavailable:
            run.job.state = .providerUnavailable
            run.job.stopReason = .providerUnavailable
        case .sourceUnavailable:
            run.checkpoint.sources[sourceIndex].failureReasonCode = VaultBackfillStopReason.sourcePartiallyFailed.rawValue
            run.checkpoint.sources[sourceIndex].isHistoryComplete = true
            run.checkpoint.sourceIndex += 1
            run.job.failedSourceCount += 1
            run.job.state = .partiallyCompleted
            run.job.stopReason = .sourcePartiallyFailed
        case .cancelled:
            run.job.state = .cancelled
            run.job.stopReason = .cancelledByUser
            run.job.finishedAt = now()
        case .invalidResponse, .none:
            run.job.state = .failed
            run.job.stopReason = .invalidCheckpoint
            run.job.finishedAt = now()
        }
        run.job.updatedAt = now()
        run.checkpoint.updatedAt = now()
        active[run.job.id] = run
        try await persistControl(run, trace: trace, reason: run.job.stopReason.rawValue)
        return run.job
    }

    private func persistControl(
        _ run: ActiveRun,
        trace: VaultBackfillTraceContext,
        reason: String,
        event: VaultBackfillTraceEventName = .jobState
    ) async throws {
        _ = try await persistence.commit(job: run.job, checkpoint: run.checkpoint, items: [])
        emit(event, trace: trace, status: traceStatus(for: run.job.state), reason: reason, job: run.job, checkpoint: run.checkpoint)
    }

    private func traceStatus(for state: VaultBackfillJobState) -> VaultBackfillTraceStatus {
        switch state {
        case .completed: .success
        case .waitingForRateLimit, .reauthorizationRequired, .providerUnavailable, .partiallyCompleted: .degraded
        case .failed: .failed
        case .cancelled: .skipped
        default: .started
        }
    }

    private func emit(
        _ event: VaultBackfillTraceEventName,
        trace: VaultBackfillTraceContext,
        status: VaultBackfillTraceStatus,
        reason: String,
        job: VaultBackfillJob,
        checkpoint: VaultBackfillCheckpoint,
        source: VaultBackfillSourceCheckpoint? = nil,
        extra: [(String, String)] = []
    ) {
        var metadata: [(String, String)] = [
            ("job_hash", VaultBackfillPrivacy.hashIdentifier(job.id)),
            ("provider", String(job.provider.prefix(40))),
            ("state", job.state.rawValue),
            ("source_index", String(checkpoint.sourceIndex)),
            ("request_count", String(checkpoint.usage.requests)),
            ("item_count", String(checkpoint.usage.items)),
            ("storage_bytes", String(checkpoint.usage.storageBytes)),
            ("retry_count", String(checkpoint.usage.retries)),
        ]
        if let source {
            metadata.append(("account_hash", VaultBackfillPrivacy.hashIdentifier(source.accountID)))
            metadata.append(("source_hash", VaultBackfillPrivacy.hashIdentifier(source.sourceID)))
        }
        metadata.append(contentsOf: extra)
        traceSink?(.init(
            ts: now(),
            event: event,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "vault_backfill_engine",
            status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: nil,
            metadata: VaultBackfillPrivacy.boundedMetadata(metadata)
        ))
    }
}
