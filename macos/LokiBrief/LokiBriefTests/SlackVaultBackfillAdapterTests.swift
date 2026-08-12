import XCTest
@testable import LokiBrief

private actor SlackBackfillHistoryTestClient: SlackBackfillHistoryFetching {
    struct Call: Sendable {
        let connectionID: String
        let channelID: String
        let oldest: SlackTimestamp?
        let latest: SlackTimestamp?
        let cursor: String?
        let limit: Int
        let waitForRateLimit: Bool
    }

    enum Step: Sendable {
        case page(SlackHistoryPage, SlackAPICallMetadata)
        case failure(SlackAPIError)
    }

    private var steps: [Step]
    private var calls: [Call] = []
    private var cancellations = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func conversationHistory(
        connection: SlackWorkspaceConnection,
        channelID: String,
        oldest: SlackTimestamp?,
        latest: SlackTimestamp?,
        cursor: String?,
        limit: Int,
        trace: SlackTraceContext,
        waitForRateLimit: Bool
    ) async throws -> SlackAPICallResult<SlackHistoryPage> {
        calls.append(.init(
            connectionID: connection.id,
            channelID: channelID,
            oldest: oldest,
            latest: latest,
            cursor: cursor,
            limit: limit,
            waitForRateLimit: waitForRateLimit
        ))
        guard !steps.isEmpty else { throw SlackAPIError(.invalidSchema) }
        switch steps.removeFirst() {
        case let .page(page, metadata):
            return .init(value: page, metadata: metadata)
        case let .failure(error):
            throw error
        }
    }

    func cancelAll() async {
        cancellations += 1
    }

    func recordedCalls() -> [Call] { calls }
    func cancellationCount() -> Int { cancellations }
}

final class SlackVaultBackfillAdapterTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_785_000_000)

    func testFetchPageUsesRequestedBoundAndPreservesHistoricalCursorAndProvenance() async throws {
        let historyCursor = "history-cursor"
        let upperBound = Self.anchor.addingTimeInterval(120)
        let message = Self.message(
            timestamp: "1785000000.000001",
            text: "Hello <@U-AUTH>",
            replyCount: 4,
            editedAt: "1785000010.000001"
        )
        let client = SlackBackfillHistoryTestClient([
            .page(
                .init(messages: [message], nextCursor: "next-history", hasMore: true),
                Self.metadata(transientRetries: 1)
            ),
        ])
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: [Self.selection()],
            now: { Self.anchor }
        )

        let page = try await adapter.fetchPage(Self.request(
            historyCursor: historyCursor,
            historyUpperBound: upperBound,
            maximumItems: 2
        ))

        XCTAssertEqual(page.nextHistoryCursor, "next-history")
        XCTAssertEqual(page.nextHistoryUpperBound, upperBound)
        XCTAssertFalse(page.isHistoryComplete)
        XCTAssertEqual(page.requestCount, 2)
        XCTAssertEqual(page.retryCount, 1)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.provider, "slack")
        XCTAssertEqual(item.accountID, "workspace-one")
        XCTAssertEqual(item.sourceID, "C-ONE")
        XCTAssertEqual(item.providerItemID, message.timestamp.rawValue)
        XCTAssertTrue(item.directlyMentionsUser)
        XCTAssertTrue(item.isEdited)
        XCTAssertEqual(item.editedAt, message.editedAt?.date)
        XCTAssertEqual(item.replyCount, 4)
        XCTAssertEqual(item.retrievedAt, Self.anchor)
        XCTAssertEqual(item.contentOrigin, .source)

        let recordedCalls = await client.recordedCalls()
        let call = try XCTUnwrap(recordedCalls.first)
        XCTAssertEqual(call.connectionID, "workspace-one")
        XCTAssertEqual(call.channelID, "C-ONE")
        XCTAssertNil(call.oldest)
        let latest = try XCTUnwrap(call.latest)
        XCTAssertEqual(latest.date.timeIntervalSince1970, upperBound.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(call.cursor, historyCursor)
        XCTAssertEqual(call.limit, 2)
        XCTAssertFalse(call.waitForRateLimit)
    }

    func testCursorFallbackUsesOldestMessageWhenSlackHasMoreWithoutCursor() async throws {
        let newer = Self.message(timestamp: "1785000060.000000", text: "newer")
        let older = Self.message(timestamp: "1785000000.000000", text: "older")
        let client = SlackBackfillHistoryTestClient([
            .page(.init(messages: [newer, older], nextCursor: nil, hasMore: true), Self.metadata()),
        ])
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: [Self.selection()],
            now: { Self.anchor }
        )

        let page = try await adapter.fetchPage(Self.request(maximumItems: 2))

        XCTAssertNil(page.nextHistoryCursor)
        XCTAssertEqual(page.nextHistoryUpperBound, older.timestamp.date)
        XCTAssertFalse(page.isHistoryComplete)
        XCTAssertEqual(page.items.map(\.occurredAt), [newer.timestamp.date, older.timestamp.date])
    }

    func testRateLimitIsSurfacedForDurableEngineWaitWithoutSleeping() async throws {
        let client = SlackBackfillHistoryTestClient([
            .failure(.init(.rateLimited, httpStatus: 429, retryAfterSeconds: 30)),
        ])
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: [Self.selection()],
            now: { Self.anchor }
        )

        do {
            _ = try await adapter.fetchPage(Self.request())
            XCTFail("Expected a surfaced rate limit")
        } catch let error as VaultBackfillProviderError {
            guard case let .rateLimited(retryAt) = error else {
                return XCTFail("Unexpected mapped error: \(error)")
            }
            XCTAssertEqual(retryAt, Self.anchor.addingTimeInterval(30))
        }

        let recordedCalls = await client.recordedCalls()
        XCTAssertFalse(try XCTUnwrap(recordedCalls.first).waitForRateLimit)
    }

    func testAuthorizationAndSourceErrorsMapWithoutLeakingSlackDetails() async throws {
        let scenarios: [(SlackAPIError, VaultBackfillProviderError)] = [
            (.init(.tokenRevoked, httpStatus: 401, slackErrorCode: "private-provider-detail"), .reauthorizationRequired),
            (.init(.channelNotFound, httpStatus: 200, slackErrorCode: "private-channel-detail"), .sourceUnavailable),
            (.init(.workspaceUnavailable, httpStatus: 503), .providerUnavailable),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let client = SlackBackfillHistoryTestClient([.failure(scenario.0)])
            let adapter = SlackVaultBackfillAdapter(
                historyClient: client,
                connection: Self.connection(),
                selections: [Self.selection()],
                now: { Self.anchor }
            )
            do {
                _ = try await adapter.fetchPage(Self.request(jobID: "mapping-\(index)"))
                XCTFail("Expected mapped error for scenario \(index)")
            } catch let error as VaultBackfillProviderError {
                XCTAssertEqual(error, scenario.1)
            }
        }
    }

    func testUnselectedDisabledAndDMChannelsNeverReachSlackClient() async throws {
        let client = SlackBackfillHistoryTestClient([])
        let selections = [
            Self.selection(channelID: "C-DISABLED", enabled: false),
            Self.selection(channelID: "D-DIRECT", enabled: true),
        ]
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: selections,
            now: { Self.anchor }
        )

        for channelID in ["C-NOT-SELECTED", "C-DISABLED", "D-DIRECT"] {
            do {
                _ = try await adapter.fetchPage(Self.request(sourceID: channelID))
                XCTFail("Expected source rejection for \(channelID)")
            } catch let error as VaultBackfillProviderError {
                XCTAssertEqual(error, .sourceUnavailable)
            }
        }

        let recordedCalls = await client.recordedCalls()
        XCTAssertTrue(recordedCalls.isEmpty)
    }

    func testMultipleWorkspaceAdaptersRemainAccountBound() async throws {
        let firstClient = SlackBackfillHistoryTestClient([
            .page(.init(messages: [Self.message(timestamp: "1785000000.000001", text: "one")], nextCursor: nil, hasMore: false), Self.metadata()),
        ])
        let secondClient = SlackBackfillHistoryTestClient([
            .page(.init(messages: [Self.message(timestamp: "1785000001.000001", text: "two")], nextCursor: nil, hasMore: false), Self.metadata()),
        ])
        let first = SlackVaultBackfillAdapter(
            historyClient: firstClient,
            connection: Self.connection(id: "workspace-one", teamID: "T-ONE"),
            selections: [Self.selection(workspaceID: "workspace-one")],
            now: { Self.anchor }
        )
        let second = SlackVaultBackfillAdapter(
            historyClient: secondClient,
            connection: Self.connection(id: "workspace-two", teamID: "T-TWO"),
            selections: [Self.selection(workspaceID: "workspace-two")],
            now: { Self.anchor }
        )

        let firstPage = try await first.fetchPage(Self.request(accountID: "workspace-one"))
        let secondPage = try await second.fetchPage(Self.request(jobID: "second", accountID: "workspace-two"))
        XCTAssertEqual(firstPage.items.map(\.accountID), ["workspace-one"])
        XCTAssertEqual(secondPage.items.map(\.accountID), ["workspace-two"])

        do {
            _ = try await first.fetchPage(Self.request(jobID: "cross-account", accountID: "workspace-two"))
            XCTFail("Expected account-bound rejection")
        } catch let error as VaultBackfillProviderError {
            XCTAssertEqual(error, .sourceUnavailable)
        }
    }

    func testEditedMessagesDeduplicateAndDeletionBecomesTombstone() async throws {
        let original = Self.message(timestamp: "1785000000.000001", text: "original")
        let edited = Self.message(
            timestamp: "1785000000.000001",
            text: "edited",
            editedAt: "1785000010.000001"
        )
        let deletion = Self.message(
            timestamp: "1785000020.000001",
            subtype: "message_deleted",
            deletedTimestamp: "1785000005.000001",
            text: ""
        )
        let client = SlackBackfillHistoryTestClient([
            .page(.init(messages: [original, edited, deletion], nextCursor: nil, hasMore: false), Self.metadata()),
        ])
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: [Self.selection()],
            now: { Self.anchor }
        )

        let page = try await adapter.fetchPage(Self.request(maximumItems: 3))

        XCTAssertEqual(page.items.count, 2)
        let available = try XCTUnwrap(page.items.first { !$0.isTombstone })
        XCTAssertEqual(available.body, "edited")
        XCTAssertTrue(available.isEdited)
        let tombstone = try XCTUnwrap(page.items.first { $0.isTombstone })
        XCTAssertEqual(tombstone.providerItemID, "1785000005.000001")
        XCTAssertTrue(tombstone.body.isEmpty)
    }

    func testCancelDelegatesToBoundedHistoryClient() async {
        let client = SlackBackfillHistoryTestClient([])
        let adapter = SlackVaultBackfillAdapter(
            historyClient: client,
            connection: Self.connection(),
            selections: [Self.selection()],
            now: { Self.anchor }
        )

        await adapter.cancel(jobID: "job")

        let cancellationCount = await client.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    private static func connection(
        id: String = "workspace-one",
        teamID: String = "T-ONE"
    ) -> SlackWorkspaceConnection {
        .init(
            id: id,
            teamID: teamID,
            teamName: "Workspace",
            userID: "U-AUTH",
            userDisplayName: "Authorized User",
            state: .connected,
            grantedScopes: [.channelsHistory, .groupsHistory],
            credentialMetadata: nil,
            localModelConsent: false,
            connectedAt: anchor,
            updatedAt: anchor,
            lastFailureReasonCode: nil
        )
    }

    private static func selection(
        workspaceID: String = "workspace-one",
        channelID: String = "C-ONE",
        enabled: Bool = true
    ) -> SlackConversationSelection {
        .init(
            workspaceID: workspaceID,
            channelID: channelID,
            displayName: "selected-channel",
            kind: .publicChannel,
            enabled: enabled,
            weight: 1,
            selectedAt: anchor,
            lastSuccessfulRefreshAt: nil,
            lastFailureReasonCode: nil
        )
    }

    private static func request(
        jobID: String = "job",
        accountID: String = "workspace-one",
        sourceID: String = "C-ONE",
        historyCursor: String? = nil,
        historyUpperBound: Date? = anchor,
        maximumItems: Int = SlackLimits.historyPageSize
    ) -> VaultBackfillFetchRequest {
        .init(
            jobID: jobID,
            provider: "slack",
            accountID: accountID,
            sourceID: sourceID,
            historyCursor: historyCursor,
            historyUpperBound: historyUpperBound,
            maximumItems: maximumItems,
            trace: .init(traceID: "trace", spanID: "span")
        )
    }

    private static func message(
        timestamp: String,
        subtype: String? = nil,
        deletedTimestamp: String? = nil,
        text: String,
        replyCount: Int = 0,
        editedAt: String? = nil
    ) -> SlackHistoryMessage {
        .init(
            type: "message",
            subtype: subtype,
            timestamp: SlackTimestamp(rawValue: timestamp)!,
            deletedTimestamp: deletedTimestamp.flatMap(SlackTimestamp.init(rawValue:)),
            threadTimestamp: nil,
            text: text,
            userID: "U-AUTH",
            botID: nil,
            appID: nil,
            username: nil,
            replyCount: replyCount,
            editedAt: editedAt.flatMap(SlackTimestamp.init(rawValue:))
        )
    }

    private static func metadata(
        transientRetries: Int = 0,
        rateLimitRetries: Int = 0,
        credentialRefreshes: Int = 0
    ) -> SlackAPICallMetadata {
        .init(
            transientRetryCount: transientRetries,
            rateLimitRetryCount: rateLimitRetries,
            credentialRefreshCount: credentialRefreshes,
            rateLimitState: nil
        )
    }
}
