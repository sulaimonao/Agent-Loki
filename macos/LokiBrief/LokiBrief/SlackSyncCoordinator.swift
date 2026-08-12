import Foundation

enum SlackSyncDirectiveKind: String, Codable, CaseIterable, Sendable {
    case disableSelection
    case purgeChannelEvidence
    case requireReauthorization
    case markWorkspaceUnavailable
}

struct SlackSyncDirective: Codable, Hashable, Sendable {
    let kind: SlackSyncDirectiveKind
    let workspaceID: String
    let channelID: String?
    let reasonCode: String
}

struct SlackSyncOutput: Codable, Hashable, Sendable {
    let run: SlackSyncRun
    let evidenceUpserts: [SlackMessageEvidence]
    let tombstones: [SlackMessageEvidence]
    let cursorUpdates: [SlackSyncCursor]
    let directives: [SlackSyncDirective]
}

struct SlackSyncProgress: Sendable {
    let runID: String
    let state: SlackSyncRunState
    let currentChannelIndex: Int
    let selectedChannelCount: Int
    let channelIDHash: String?
    let reasonCode: String
}

actor SlackSyncCoordinator {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void
    typealias ProgressHandler = @Sendable (SlackSyncProgress) async -> Void

    private let client: SlackAPIClient
    private let normalizer: SlackMessageNormalizer
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?
    private var authorCache: [String: [String: SlackMessageAuthor]] = [:]
    private var permalinkCache: [String: URL] = [:]
    private var activeRunID: String?
    private var operationEpoch: UInt64 = 0

    init(
        client: SlackAPIClient,
        normalizer: SlackMessageNormalizer? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        self.client = client
        self.normalizer = normalizer ?? SlackMessageNormalizer(now: now, eventSink: eventSink)
        self.now = now
        self.eventSink = eventSink
    }

    func syncSelectedChannels(
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        cursors: [SlackSyncCursor],
        trace: SlackTraceContext = .init(),
        scheduledBudget: ScheduledBriefingBudgetLedger? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> SlackSyncOutput {
        guard activeRunID == nil else { throw SlackAPIError(.syncAlreadyInProgress) }
        guard [.connected, .degraded, .rateLimited].contains(connection.state) else {
            throw SlackAPIError(.reauthorizationRequired)
        }
        let enabled = selections.filter(\.enabled)
        guard !enabled.isEmpty else { throw SlackAPIError(.invalidRequest) }
        guard enabled.count <= SlackLimits.maximumSelectedChannels else { throw SlackAPIError(.selectionLimitExceeded) }
        guard Set(enabled.map(\.channelID)).count == enabled.count,
              enabled.allSatisfy({ $0.workspaceID == connection.id && $0.validatedWeight != nil })
        else { throw SlackAPIError(.invalidRequest) }

        let cursorByChannel = try validatedCursors(cursors, connectionID: connection.id)
        let orderedSelections = enabled.sorted {
            if $0.workspaceID != $1.workspaceID { return $0.workspaceID < $1.workspaceID }
            return $0.channelID < $1.channelID
        }
        let runID = "slack-sync-\(UUID().uuidString.lowercased())"
        activeRunID = runID
        operationEpoch &+= 1
        let epoch = operationEpoch
        let startedAt = now()
        defer { if activeRunID == runID { activeRunID = nil } }

        await progress?(.init(runID: runID, state: .queued, currentChannelIndex: 0, selectedChannelCount: orderedSelections.count, channelIDHash: nil, reasonCode: "slack_sync_queued"))
        try checkCurrent(runID: runID, epoch: epoch)
        emit(.selectedChannelSync, trace: trace, status: .started, reason: "slack_selected_channel_sync_started", metadata: .init([
            (.selectedChannelCount, String(orderedSelections.count)),
            (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
        ]))

        var channelResults: [SlackChannelSyncResult] = []
        var evidence: [SlackMessageEvidence] = []
        var tombstones: [SlackMessageEvidence] = []
        var cursorUpdates: [SlackSyncCursor] = []
        var directives: [SlackSyncDirective] = []
        var rateLimitState: SlackRateLimitState?
        var lookupBudget = SlackLimits.maximumAuthorLookupsPerSync
        var shouldStopWorkspace = false

        for (index, selection) in orderedSelections.enumerated() {
            try checkCurrent(runID: runID, epoch: epoch)
            let channelTrace = trace.child()
            await progress?(.init(
                runID: runID, state: .running, currentChannelIndex: index + 1,
                selectedChannelCount: orderedSelections.count,
                channelIDHash: SlackPrivacy.hashIdentifier(selection.channelID), reasonCode: "slack_channel_sync_started"
            ))
            try checkCurrent(runID: runID, epoch: epoch)
            let baseCursor = cursorByChannel[selection.channelID] ?? initialCursor(connectionID: connection.id, channelID: selection.channelID, at: startedAt)
            do {
                let latest = baseCursor.windowLatest ?? SlackTimestamp(date: startedAt)
                let history = try await client.conversationHistory(
                    connection: connection,
                    channelID: selection.channelID,
                    oldest: baseCursor.committedOldest,
                    latest: latest,
                    cursor: baseCursor.nextCursor,
                    trace: channelTrace.child(),
                    budget: scheduledBudget
                )
                try checkCurrent(runID: runID, epoch: epoch)
                rateLimitState = history.metadata.rateLimitState ?? rateLimitState
                if let previous = baseCursor.nextCursor, let next = history.value.nextCursor, previous == next {
                    throw SlackAPIError(.invalidSchema)
                }

                let resolution = try await resolveAuthors(
                    in: history.value.messages,
                    connection: connection,
                    remainingBudget: &lookupBudget,
                    rateLimitState: &rateLimitState,
                    trace: channelTrace.child(),
                    runID: runID,
                    epoch: epoch,
                    scheduledBudget: scheduledBudget
                )
                let normalized = try normalizer.normalize(
                    messages: history.value.messages,
                    context: .init(connection: connection, selection: selection, authorsByID: resolution, retrievedAt: now()),
                    trace: channelTrace.child()
                )
                let updatedCursor = try advancedCursor(baseCursor, page: history.value, windowLatest: latest, at: now())
                evidence.append(contentsOf: normalized.evidence)
                tombstones.append(contentsOf: normalized.tombstones)
                cursorUpdates.append(updatedCursor)
                channelResults.append(.init(
                    channelID: selection.channelID,
                    state: .completed,
                    normalizedCount: normalized.evidence.count,
                    tombstoneCount: normalized.tombstones.count,
                    failureReasonCode: nil,
                    cursor: updatedCursor
                ))
            } catch {
                let failure = mapFailure(error)
                let cancelled = failure.code == .cancelled
                channelResults.append(.init(
                    channelID: selection.channelID,
                    state: cancelled ? .cancelled : .failed,
                    normalizedCount: 0,
                    tombstoneCount: 0,
                    failureReasonCode: failure.reasonCode,
                    cursor: baseCursor
                ))
                if [.channelAccessLost, .channelNotFound].contains(failure.code) {
                    directives.append(.init(kind: .disableSelection, workspaceID: connection.id, channelID: selection.channelID, reasonCode: failure.reasonCode))
                    directives.append(.init(kind: .purgeChannelEvidence, workspaceID: connection.id, channelID: selection.channelID, reasonCode: failure.reasonCode))
                }
                if [.invalidAuth, .tokenExpired, .tokenRevoked, .missingScope, .reauthorizationRequired].contains(failure.code) {
                    directives.append(.init(kind: .requireReauthorization, workspaceID: connection.id, channelID: nil, reasonCode: failure.reasonCode))
                    shouldStopWorkspace = true
                } else if failure.code == .workspaceUnavailable {
                    directives.append(.init(kind: .markWorkspaceUnavailable, workspaceID: connection.id, channelID: nil, reasonCode: failure.reasonCode))
                    shouldStopWorkspace = true
                } else if Self.isScheduledBudgetFailure(failure.code) {
                    shouldStopWorkspace = true
                }
                if cancelled { shouldStopWorkspace = true }
            }
            if shouldStopWorkspace { break }
        }

        let completedAt = now()
        let successCount = channelResults.filter { $0.state == .completed }.count
        let failureCount = channelResults.count - successCount
        let finalState: SlackSyncRunState
        if channelResults.contains(where: { $0.state == .cancelled }) { finalState = .cancelled }
        else if successCount == orderedSelections.count { finalState = .completed }
        else if successCount > 0 { finalState = .partial }
        else { finalState = .failed }
        let run = SlackSyncRun(
            id: runID,
            traceID: trace.traceID,
            workspaceID: connection.id,
            startedAt: startedAt,
            completedAt: completedAt,
            state: finalState,
            selectedChannelCount: orderedSelections.count,
            successfulChannelCount: successCount,
            failedChannelCount: failureCount,
            normalizedMessageCount: evidence.count,
            rateLimitState: rateLimitState,
            channelResults: channelResults
        )
        await progress?(.init(
            runID: runID, state: finalState, currentChannelIndex: channelResults.count,
            selectedChannelCount: orderedSelections.count, channelIDHash: nil,
            reasonCode: reasonCode(for: finalState)
        ))
        try checkCurrent(runID: runID, epoch: epoch)
        emit(
            .selectedChannelSync,
            trace: trace,
            status: traceStatus(for: finalState),
            reason: reasonCode(for: finalState),
            metadata: .init([
                (.selectedChannelCount, String(orderedSelections.count)),
                (.successCount, String(successCount)),
                (.failureCount, String(failureCount)),
                (.normalizedCount, String(evidence.count)),
                (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
            ])
        )
        return .init(
            run: run,
            evidenceUpserts: deterministicEvidenceOrder(evidence),
            tombstones: deterministicEvidenceOrder(tombstones),
            cursorUpdates: cursorUpdates.sorted { $0.channelID < $1.channelID },
            directives: directives
        )
    }

    func resolvePermalink(
        for evidence: SlackMessageEvidence,
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext = .init()
    ) async throws -> SlackMessageEvidence {
        guard evidence.workspaceID == connection.id,
              evidence.state == .available
        else { throw SlackAPIError(.invalidRequest) }
        if let cached = evidence.permalink ?? permalinkCache[evidence.id] {
            return evidence.replacingPermalink(cached)
        }
        let epoch = operationEpoch
        let result = try await client.permalink(
            connection: connection,
            channelID: evidence.channelID,
            messageTimestamp: evidence.messageTimestamp,
            trace: trace
        )
        guard epoch == operationEpoch, !Task.isCancelled else { throw SlackAPIError(.cancelled) }
        if permalinkCache.count >= 1_000, let first = permalinkCache.keys.sorted().first {
            permalinkCache.removeValue(forKey: first)
        }
        permalinkCache[evidence.id] = result.value
        return evidence.replacingPermalink(result.value)
    }

    func cancelAll(trace: SlackTraceContext = .init()) async {
        operationEpoch &+= 1
        activeRunID = nil
        await client.cancelAll()
        emit(.cancellation, trace: trace, status: .success, reason: "slack_sync_cancellation_requested")
    }

    func clearWorkspaceCaches(workspaceID: String) {
        authorCache.removeValue(forKey: workspaceID)
        permalinkCache.removeAll()
    }

    private func resolveAuthors(
        in messages: [SlackHistoryMessage],
        connection: SlackWorkspaceConnection,
        remainingBudget: inout Int,
        rateLimitState: inout SlackRateLimitState?,
        trace: SlackTraceContext,
        runID: String,
        epoch: UInt64,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> [String: SlackMessageAuthor] {
        var workspaceCache = authorCache[connection.id] ?? [:]
        let requestedIDs = Set(messages.compactMap { message in
            message.botID == nil && message.appID == nil ? message.userID : nil
        }).sorted()
        let unresolved = requestedIDs.filter { workspaceCache[$0] == nil }
        var resolvedCount = 0
        for userID in unresolved where remainingBudget > 0 {
            try checkCurrent(runID: runID, epoch: epoch)
            do {
                let result = try await client.userInfo(
                    connection: connection,
                    userID: userID,
                    trace: trace.child(),
                    budget: scheduledBudget
                )
                try checkCurrent(runID: runID, epoch: epoch)
                workspaceCache[userID] = result.value
                rateLimitState = result.metadata.rateLimitState ?? rateLimitState
                remainingBudget -= 1
                resolvedCount += 1
            } catch {
                let failure = mapFailure(error)
                if [.invalidAuth, .tokenExpired, .tokenRevoked, .missingScope, .reauthorizationRequired, .workspaceUnavailable, .cancelled].contains(failure.code)
                    || Self.isScheduledBudgetFailure(failure.code)
                {
                    throw failure
                }
                remainingBudget -= 1
            }
        }
        if workspaceCache.count > SlackLimits.maximumCachedAuthorsPerWorkspace {
            let retainedIDs = workspaceCache.keys.sorted().suffix(SlackLimits.maximumCachedAuthorsPerWorkspace)
            workspaceCache = Dictionary(uniqueKeysWithValues: retainedIDs.compactMap { id in workspaceCache[id].map { (id, $0) } })
        }
        authorCache[connection.id] = workspaceCache
        emit(.authorResolution, trace: trace, status: unresolved.count > resolvedCount ? .degraded : .success, reason: unresolved.count > resolvedCount ? "slack_author_resolution_bounded" : "slack_author_resolution_succeeded", metadata: .init([
            (.successCount, String(resolvedCount)),
            (.skippedCount, String(max(0, unresolved.count - resolvedCount))),
            (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
        ]))
        return workspaceCache
    }

    private func initialCursor(connectionID: String, channelID: String, at date: Date) -> SlackSyncCursor {
        .init(
            workspaceID: connectionID,
            channelID: channelID,
            committedOldest: SlackTimestamp(date: date.addingTimeInterval(-SlackLimits.initialLookbackSeconds)),
            windowLatest: nil,
            nextCursor: nil,
            pendingHighWater: nil,
            updatedAt: date
        )
    }

    private func advancedCursor(_ cursor: SlackSyncCursor, page: SlackHistoryPage, windowLatest: SlackTimestamp, at date: Date) throws -> SlackSyncCursor {
        let observed = page.messages.map { $0.deletedTimestamp ?? $0.timestamp }
        let pageHigh = observed.max()
        let pendingHigh = [cursor.pendingHighWater, pageHigh].compactMap { $0 }.max()
        let hasBacklog = page.nextCursor != nil || page.hasMore
        if hasBacklog {
            guard !page.messages.isEmpty else { throw SlackAPIError(.invalidSchema) }
            let nextWindowLatest: SlackTimestamp
            if page.nextCursor != nil { nextWindowLatest = cursor.windowLatest ?? windowLatest }
            else { nextWindowLatest = try page.messages.map(\.timestamp).min().unwrap(or: SlackAPIError(.invalidSchema)) }
            return .init(
                workspaceID: cursor.workspaceID,
                channelID: cursor.channelID,
                committedOldest: cursor.committedOldest,
                windowLatest: nextWindowLatest,
                nextCursor: page.nextCursor,
                pendingHighWater: pendingHigh,
                updatedAt: date
            )
        }
        return .init(
            workspaceID: cursor.workspaceID,
            channelID: cursor.channelID,
            committedOldest: maxTimestamp(cursor.committedOldest, windowLatest),
            windowLatest: nil,
            nextCursor: nil,
            pendingHighWater: nil,
            updatedAt: date
        )
    }

    private func validatedCursors(_ cursors: [SlackSyncCursor], connectionID: String) throws -> [String: SlackSyncCursor] {
        guard Set(cursors.map(\.channelID)).count == cursors.count,
              cursors.allSatisfy({ $0.workspaceID == connectionID && ($0.nextCursor?.count ?? 0) <= SlackLimits.maximumCursorCharacters })
        else { throw SlackAPIError(.invalidRequest) }
        return Dictionary(uniqueKeysWithValues: cursors.map { ($0.channelID, $0) })
    }

    private func deterministicEvidenceOrder(_ values: [SlackMessageEvidence]) -> [SlackMessageEvidence] {
        values.sorted {
            if $0.workspaceID != $1.workspaceID { return $0.workspaceID < $1.workspaceID }
            if $0.channelID != $1.channelID { return $0.channelID < $1.channelID }
            if $0.messageTimestamp != $1.messageTimestamp { return $0.messageTimestamp > $1.messageTimestamp }
            return $0.id < $1.id
        }
    }

    private func checkCurrent(runID: String, epoch: UInt64) throws {
        guard activeRunID == runID, operationEpoch == epoch, !Task.isCancelled else { throw SlackAPIError(.cancelled) }
    }

    private func maxTimestamp(_ lhs: SlackTimestamp?, _ rhs: SlackTimestamp?) -> SlackTimestamp? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private func mapFailure(_ error: Error) -> SlackAPIError {
        if let failure = error as? SlackAPIError { return failure }
        if error is CancellationError { return .init(.cancelled) }
        return .init(.transportFailure)
    }

    private static func isScheduledBudgetFailure(_ code: SlackAPIErrorCode) -> Bool {
        [
            .scheduledRequestBudgetExhausted,
            .scheduledRetryBudgetExhausted,
            .scheduledDurationBudgetExhausted,
            .scheduledRetryDelayExceedsRemaining,
        ].contains(code)
    }

    private func reasonCode(for state: SlackSyncRunState) -> String {
        switch state {
        case .completed: "slack_selected_channel_sync_completed"
        case .partial: "slack_selected_channel_sync_partial"
        case .cancelled: "slack_selected_channel_sync_cancelled"
        case .failed: "slack_selected_channel_sync_failed"
        case .queued: "slack_selected_channel_sync_queued"
        case .running: "slack_selected_channel_sync_running"
        case .waitingForRateLimit: "slack_selected_channel_sync_rate_limited"
        }
    }

    private func traceStatus(for state: SlackSyncRunState) -> SlackTraceStatus {
        switch state {
        case .completed: .success
        case .partial, .waitingForRateLimit: .degraded
        case .cancelled: .skipped
        case .failed: .failed
        case .queued, .running: .started
        }
    }

    private func emit(_ event: SlackTraceEventName, trace: SlackTraceContext, status: SlackTraceStatus, reason: String, metadata: SlackTraceMetadata = .init()) {
        eventSink?(.init(
            ts: now(), event: event, traceID: trace.traceID, spanID: trace.spanID,
            parentSpanID: trace.parentSpanID, component: "slack_sync_coordinator",
            status: status, reasonCode: String(reason.prefix(120)), durationMilliseconds: nil, metadata: metadata
        ))
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
