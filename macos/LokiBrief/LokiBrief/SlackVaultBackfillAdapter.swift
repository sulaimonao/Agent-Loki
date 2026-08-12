import Foundation

protocol SlackBackfillHistoryFetching: Sendable {
    func conversationHistory(
        connection: SlackWorkspaceConnection,
        channelID: String,
        oldest: SlackTimestamp?,
        latest: SlackTimestamp?,
        cursor: String?,
        limit: Int,
        trace: SlackTraceContext,
        waitForRateLimit: Bool
    ) async throws -> SlackAPICallResult<SlackHistoryPage>

    func cancelAll() async
}

extension SlackAPIClient: SlackBackfillHistoryFetching {}

actor SlackVaultBackfillAdapter: VaultBackfillPageFetching {
    typealias TraceSink = @Sendable (VaultBackfillTraceEvent) -> Void

    nonisolated let providerIdentifier = "slack"

    private let historyClient: any SlackBackfillHistoryFetching
    private let connection: SlackWorkspaceConnection
    private let selectionsByID: [String: SlackConversationSelection]
    private let normalizer: SlackMessageNormalizer
    private let now: @Sendable () -> Date
    private let traceSink: TraceSink?

    init(
        client: SlackAPIClient,
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: TraceSink? = nil
    ) {
        self.init(
            historyClient: client,
            connection: connection,
            selections: selections,
            now: now,
            traceSink: traceSink
        )
    }

    init(
        historyClient: any SlackBackfillHistoryFetching,
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: TraceSink? = nil
    ) {
        self.historyClient = historyClient
        self.connection = connection
        self.selectionsByID = Dictionary(
            selections
                .filter { $0.enabled && $0.workspaceID == connection.id }
                .map { ($0.channelID, $0) },
            uniquingKeysWith: { first, second in
                if first.selectedAt != second.selectedAt { return first.selectedAt < second.selectedAt ? first : second }
                return first.displayName <= second.displayName ? first : second
            }
        )
        self.normalizer = SlackMessageNormalizer(now: now)
        self.now = now
        self.traceSink = traceSink
    }

    func fetchPage(_ request: VaultBackfillFetchRequest) async throws -> VaultBackfillPage {
        guard request.provider == providerIdentifier,
              request.accountID == connection.id,
              request.maximumItems > 0,
              request.maximumItems <= SlackLimits.historyPageSize,
              let selection = selectionsByID[request.sourceID],
              selection.enabled,
              selection.workspaceID == connection.id,
              selection.kind == .publicChannel || selection.kind == .privateChannel,
              !selection.channelID.hasPrefix("D")
        else { throw VaultBackfillProviderError.sourceUnavailable }

        let slackTrace = SlackTraceContext(
            traceID: request.trace.traceID,
            spanID: request.trace.spanID,
            parentSpanID: request.trace.parentSpanID
        )
        do {
            // This is the adapter's sole provider call. It never invokes replies,
            // files, DMs, author lookup, or permalink APIs.
            let response = try await historyClient.conversationHistory(
                connection: connection,
                channelID: selection.channelID,
                oldest: nil,
                latest: request.historyUpperBound.map(SlackTimestamp.init(date:)),
                cursor: request.historyCursor,
                limit: min(request.maximumItems, SlackLimits.historyPageSize),
                trace: slackTrace,
                waitForRateLimit: false
            )
            let normalized = try normalizer.normalize(
                messages: response.value.messages,
                context: .init(
                    connection: connection,
                    selection: selection,
                    authorsByID: [:],
                    retrievedAt: now()
                ),
                trace: slackTrace.child()
            )

            var items = normalized.evidence.map { archiveItem(from: $0, selection: selection) }
            items.append(contentsOf: normalized.tombstones.map { archiveItem(from: $0, selection: selection) })
            items.sort {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id < $1.id
            }
            guard items.count <= SlackLimits.historyPageSize else {
                throw VaultBackfillProviderError.invalidResponse
            }

            let cursor = try nextCursor(
                page: response.value,
                previousUpperBound: request.historyUpperBound
            )
            let metadata = response.metadata
            let retries = metadata.transientRetryCount + metadata.rateLimitRetryCount + metadata.credentialRefreshCount
            let requests = 1 + retries
            emit(
                trace: request.trace,
                status: normalized.skipped.isEmpty ? .success : .degraded,
                reason: normalized.skipped.isEmpty ? "slack_vault_backfill_page_normalized" : "slack_vault_backfill_page_partially_normalized",
                sourceID: selection.channelID,
                extra: [
                    ("page_size", String(response.value.messages.count)),
                    ("archive_item_count", String(items.count)),
                    ("skipped_count", String(normalized.skipped.count)),
                    ("request_count", String(requests)),
                    ("retry_count", String(retries)),
                ]
            )
            return .init(
                items: items,
                nextHistoryCursor: cursor.providerCursor,
                nextHistoryUpperBound: cursor.upperBound,
                isHistoryComplete: cursor.isComplete,
                requestCount: requests,
                retryCount: retries
            )
        } catch let error as VaultBackfillProviderError {
            emit(trace: request.trace, status: .failed, reason: reasonCode(for: error), sourceID: selection.channelID)
            throw error
        } catch let error as SlackAPIError {
            let mapped = map(error)
            emit(trace: request.trace, status: traceStatus(for: mapped), reason: reasonCode(for: mapped), sourceID: selection.channelID)
            throw mapped
        } catch is CancellationError {
            emit(trace: request.trace, status: .skipped, reason: "slack_vault_backfill_cancelled", sourceID: selection.channelID)
            throw VaultBackfillProviderError.cancelled
        } catch {
            emit(trace: request.trace, status: .failed, reason: "slack_vault_backfill_invalid_response", sourceID: selection.channelID)
            throw VaultBackfillProviderError.invalidResponse
        }
    }

    func cancel(jobID: String) async {
        await historyClient.cancelAll()
    }

    private func archiveItem(
        from evidence: SlackMessageEvidence,
        selection: SlackConversationSelection
    ) -> VaultBackfillArchiveItem {
        let body = VaultBackfillPrivacy.boundedText(evidence.excerpt, maximum: SlackLimits.maximumExcerptCharacters)
        let sourceName = VaultBackfillPrivacy.boundedText(selection.displayName, maximum: SlackLimits.maximumChannelNameCharacters)
        let author = evidence.author.displayName == "Unknown Slack author"
            ? nil
            : VaultBackfillPrivacy.boundedText(evidence.author.displayName, maximum: SlackLimits.maximumAuthorNameCharacters)
        let estimated = min(
            64 * 1_024,
            256 + evidence.id.utf8.count + sourceName.utf8.count + body.utf8.count + (author?.utf8.count ?? 0)
        )
        return .init(
            id: evidence.id,
            provider: providerIdentifier,
            accountID: evidence.workspaceID,
            sourceID: evidence.channelID,
            sourceName: sourceName,
            occurredAt: evidence.messageTimestamp.date,
            title: sourceName.isEmpty ? "Slack channel" : "#\(sourceName)",
            body: body,
            authorName: author,
            providerItemID: evidence.messageTimestamp.rawValue,
            isTombstone: evidence.state != .available,
            estimatedStorageBytes: estimated,
            sourceURL: evidence.permalink,
            directlyMentionsUser: evidence.directlyMentionsAuthenticatedUser,
            isEdited: evidence.isEdited,
            editedAt: evidence.editedAt?.date,
            threadRootID: nil,
            replyCount: evidence.replyCount,
            retrievedAt: evidence.retrievedAt,
            contentOrigin: .source
        )
    }

    private func nextCursor(
        page: SlackHistoryPage,
        previousUpperBound: Date?
    ) throws -> (providerCursor: String?, upperBound: Date?, isComplete: Bool) {
        if let next = page.nextCursor, !next.isEmpty {
            return (next, previousUpperBound, false)
        }
        if page.hasMore {
            guard let oldest = page.messages.map({ $0.deletedTimestamp ?? $0.timestamp }).min() else {
                throw VaultBackfillProviderError.invalidResponse
            }
            return (nil, oldest.date, false)
        }
        return (nil, nil, true)
    }

    private func map(_ error: SlackAPIError) -> VaultBackfillProviderError {
        switch error.code {
        case .rateLimited:
            guard let seconds = error.retryAfterSeconds,
                  seconds > 0,
                  seconds <= SlackLimits.maximumRetryAfterSeconds
            else { return .providerUnavailable }
            return .rateLimited(retryAt: now().addingTimeInterval(seconds))
        case .invalidAuth, .tokenExpired, .tokenRevoked, .missingScope, .reauthorizationRequired:
            return .reauthorizationRequired
        case .transportFailure, .timedOut, .httpFailure, .workspaceUnavailable:
            return .providerUnavailable
        case .channelNotFound, .channelAccessLost:
            return .sourceUnavailable
        case .cancelled:
            return .cancelled
        default:
            return .invalidResponse
        }
    }

    private func reasonCode(for error: VaultBackfillProviderError) -> String {
        switch error {
        case .rateLimited: "slack_vault_backfill_rate_limited"
        case .reauthorizationRequired: "slack_vault_backfill_reauthorization_required"
        case .providerUnavailable: "slack_vault_backfill_provider_unavailable"
        case .sourceUnavailable: "slack_vault_backfill_source_unavailable"
        case .invalidResponse: "slack_vault_backfill_invalid_response"
        case .cancelled: "slack_vault_backfill_cancelled"
        }
    }

    private func traceStatus(for error: VaultBackfillProviderError) -> VaultBackfillTraceStatus {
        switch error {
        case .rateLimited, .reauthorizationRequired, .providerUnavailable, .sourceUnavailable: .degraded
        case .cancelled: .skipped
        case .invalidResponse: .failed
        }
    }

    private func emit(
        trace: VaultBackfillTraceContext,
        status: VaultBackfillTraceStatus,
        reason: String,
        sourceID: String,
        extra: [(String, String)] = []
    ) {
        var metadata: [(String, String)] = [
            ("account_hash", VaultBackfillPrivacy.hashIdentifier(connection.id)),
            ("source_hash", VaultBackfillPrivacy.hashIdentifier(sourceID)),
        ]
        metadata.append(contentsOf: extra)
        traceSink?(.init(
            ts: now(),
            event: .pageFetch,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_vault_backfill_adapter",
            status: status,
            reasonCode: reason,
            durationMilliseconds: nil,
            metadata: VaultBackfillPrivacy.boundedMetadata(metadata)
        ))
    }
}
