import Foundation
import XCTest
@testable import LokiBrief

private actor P3TokenProvider: SlackAccessTokenProviding {
    private let initialToken: String
    private let refreshedToken: String
    private var refreshFlags: [Bool] = []
    private var scheduledBudgetCallCount = 0

    init(initialToken: String = "TEST_ACCESS_INITIAL_SENTINEL", refreshedToken: String = "TEST_ACCESS_REFRESHED_SENTINEL") {
        self.initialToken = initialToken
        self.refreshedToken = refreshedToken
    }

    func accessToken(teamID: String, userID: String, forceRefresh: Bool, trace: SlackTraceContext) async throws -> String {
        refreshFlags.append(forceRefresh)
        return forceRefresh ? refreshedToken : initialToken
    }

    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> String {
        if scheduledBudget != nil { scheduledBudgetCallCount += 1 }
        return try await accessToken(teamID: teamID, userID: userID, forceRefresh: forceRefresh, trace: trace)
    }

    func calls() -> [Bool] { refreshFlags }
    func scheduledBudgetCalls() -> Int { scheduledBudgetCallCount }
}

private actor P3SlackTransport: SlackAPITransporting {
    enum Action: Sendable {
        case response(status: Int, data: Data, headers: [String: String])
        case failure(SlackAPIError)
        case waitForCancellation
    }

    private var actions: [Action]
    private var requests: [URLRequest] = []
    private var cancelled: [UUID] = []
    private var pending: [UUID: CheckedContinuation<SlackTransportResponse, Error>] = [:]
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ actions: [Action]) { self.actions = actions }

    func data(for request: URLRequest, requestID: UUID, responseLimit: Int) async throws -> SlackTransportResponse {
        requests.append(request)
        let ready = requestWaiters.filter { requests.count >= $0.count }
        requestWaiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        guard !actions.isEmpty else { throw SlackAPIError(.transportFailure) }
        switch actions.removeFirst() {
        case let .response(status, data, headers):
            return .init(data: data, statusCode: status, finalURL: request.url, headers: headers)
        case let .failure(error):
            throw error
        case .waitForCancellation:
            return try await withCheckedThrowingContinuation { pending[requestID] = $0 }
        }
    }

    func cancel(requestID: UUID) async {
        cancelled.append(requestID)
        pending.removeValue(forKey: requestID)?.resume(throwing: SlackAPIError(.cancelled))
    }
    func capturedRequests() -> [URLRequest] { requests }
    func cancellationCount() -> Int { cancelled.count }
    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
}

private actor P3SlackSleeper: SlackSleeping {
    private var waits: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws { waits.append(seconds) }
    func recordedWaits() -> [TimeInterval] { waits }
}

private actor P3SlackCoordinatorReference {
    private var coordinator: SlackSyncCoordinator?

    func set(_ coordinator: SlackSyncCoordinator) {
        self.coordinator = coordinator
    }

    func cancelAll() async {
        await coordinator?.cancelAll()
    }
}

private final class P3TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SlackTraceEvent] = []

    func append(_ event: SlackTraceEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    func events() -> [SlackTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class P3RateLimitRecorder: @unchecked Sendable {
    struct Observation: Sendable {
        let workspaceID: String
        let state: SlackRateLimitState?
    }

    private let lock = NSLock()
    private var stored: [Observation] = []

    func append(workspaceID: String, state: SlackRateLimitState?) {
        lock.lock()
        stored.append(.init(workspaceID: workspaceID, state: state))
        lock.unlock()
    }

    func observations() -> [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class SlackAPIClientP3Tests: XCTestCase, @unchecked Sendable {
    fileprivate static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    func testEndpointPolicyIsFixedHostBearerOnlyAndRejectsCredentialQuery() throws {
        var valid = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        valid.httpMethod = "GET"
        valid.setValue("Bearer TEST_ACCESS_SENTINEL", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(try SlackEndpointPolicy.validate(valid), .authTest)

        var wrongHost = valid
        wrongHost.url = URL(string: "https://slack.com.attacker.example/api/auth.test")!
        XCTAssertThrowsError(try SlackEndpointPolicy.validate(wrongHost)) { error in
            XCTAssertEqual((error as? SlackAPIError)?.code, .invalidEndpoint)
        }

        var queryCredential = valid
        queryCredential.url = URL(string: "https://slack.com/api/auth.test?token=TEST_QUERY_CREDENTIAL_SENTINEL")!
        XCTAssertThrowsError(try SlackEndpointPolicy.validate(queryCredential)) { error in
            XCTAssertEqual((error as? SlackAPIError)?.code, .invalidRequest)
        }

        var cookieCredential = valid
        cookieCredential.setValue("token=TEST_COOKIE_CREDENTIAL_SENTINEL", forHTTPHeaderField: "Cookie")
        XCTAssertThrowsError(try SlackEndpointPolicy.validate(cookieCredential)) { error in
            XCTAssertEqual((error as? SlackAPIError)?.code, .invalidRequest)
        }
    }

    func testSingleServerRetryKeepsTokenOutOfURLAndTrace() async throws {
        let token = "TEST_SECRET_MUST_NOT_APPEAR"
        let provider = P3TokenProvider(initialToken: token)
        let transport = P3SlackTransport([
            .response(status: 503, data: Data(), headers: [:]),
            .response(status: 200, data: Self.authSuccess(), headers: Self.jsonHeaders),
        ])
        let traces = P3TraceRecorder()
        let client = SlackAPIClient(
            tokenProvider: provider,
            transport: transport,
            sleeper: P3SlackSleeper(),
            now: { Self.anchor },
            eventSink: { event in traces.append(event) }
        )

        let result = try await client.testAuthentication(connection: Self.connection())
        XCTAssertEqual(result.value.teamID, "T123")
        XCTAssertEqual(result.metadata.transientRetryCount, 1)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString.contains(token) == false })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" })
        let encodedTraces = try JSONEncoder().encode(traces.events())
        XCTAssertFalse(String(decoding: encodedTraces, as: UTF8.self).contains(token))
    }

    func testRateLimitWaitIsExactAndOnlyReplayedOnce() async throws {
        let sleeper = P3SlackSleeper()
        let rateLimits = P3RateLimitRecorder()
        let transport = P3SlackTransport([
            .response(status: 429, data: Self.json(["ok": false, "error": "ratelimited"]), headers: ["Retry-After": "7"]),
            .response(status: 200, data: Self.authSuccess(), headers: Self.jsonHeaders),
        ])
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: sleeper,
            now: { Self.anchor },
            rateLimitSink: { workspaceID, state in
                rateLimits.append(workspaceID: workspaceID, state: state)
            }
        )

        let result = try await client.testAuthentication(connection: Self.connection())
        let waits = await sleeper.recordedWaits()
        XCTAssertEqual(waits, [7])
        XCTAssertEqual(result.metadata.rateLimitRetryCount, 1)
        XCTAssertEqual(result.metadata.rateLimitState?.retryAt, Self.anchor.addingTimeInterval(7))
        let observations = rateLimits.observations()
        XCTAssertEqual(observations.map(\.workspaceID), ["T123:U123", "T123:U123"])
        XCTAssertEqual(observations.first?.state?.retryAt, Self.anchor.addingTimeInterval(7))
        XCTAssertNil(observations.last?.state)
    }

    func testScheduledRequestBudgetExhaustionStartsNoTransport() async throws {
        let tokenProvider = P3TokenProvider()
        let transport = P3SlackTransport([
            .response(
                status: 200,
                data: Self.json(["ok": true, "messages": [], "has_more": false]),
                headers: Self.jsonHeaders
            ),
        ])
        let client = SlackAPIClient(
            tokenProvider: tokenProvider,
            transport: transport,
            sleeper: P3SlackSleeper()
        )
        let budget = ScheduledBriefingBudgetLedger(
            budget: .init(maximumSlackRequests: 0)
        )

        do {
            _ = try await client.conversationHistory(
                connection: Self.connection(),
                channelID: "C1",
                oldest: nil,
                latest: nil,
                cursor: nil,
                budget: budget
            )
            XCTFail("Expected the scheduled request budget to reject before transport.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .scheduledRequestBudgetExhausted)
            XCTAssertEqual(error.reasonCode, ScheduledBriefingBudgetReason.slackRequestsExhausted)
        }

        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        let scheduledBudgetCalls = await tokenProvider.scheduledBudgetCalls()
        XCTAssertEqual(scheduledBudgetCalls, 1)
    }

    func testScheduledRetryBudgetExhaustionPreventsTransportReplay() async throws {
        let transport = P3SlackTransport([
            .failure(.init(.transportFailure)),
            .response(
                status: 200,
                data: Self.json(["ok": true, "messages": [], "has_more": false]),
                headers: Self.jsonHeaders
            ),
        ])
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: P3SlackSleeper()
        )
        let budget = ScheduledBriefingBudgetLedger(
            budget: .init(maximumSlackRequests: 2, maximumTransientRetries: 0)
        )

        do {
            _ = try await client.conversationHistory(
                connection: Self.connection(),
                channelID: "C1",
                oldest: nil,
                latest: nil,
                cursor: nil,
                budget: budget
            )
            XCTFail("Expected the scheduled retry budget to prevent replay.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .scheduledRetryBudgetExhausted)
            XCTAssertEqual(error.reasonCode, ScheduledBriefingBudgetReason.transientRetriesExhausted)
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testScheduledRetryAfterBeyondRemainingDurationStartsNoSleeper() async throws {
        let sleeper = P3SlackSleeper()
        let transport = P3SlackTransport([
            .response(
                status: 429,
                data: Self.json(["ok": false, "error": "ratelimited"]),
                headers: ["Retry-After": "7"]
            ),
        ])
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: sleeper
        )
        let budget = ScheduledBriefingBudgetLedger(
            budget: .init(maximumTotalDurationSeconds: 1, maximumSlackRequests: 2, maximumTransientRetries: 1),
            uptime: { 100 }
        )

        do {
            _ = try await client.conversationHistory(
                connection: Self.connection(),
                channelID: "C1",
                oldest: nil,
                latest: nil,
                cursor: nil,
                budget: budget
            )
            XCTFail("Expected Retry-After to be rejected when it exceeds the scheduled duration remaining.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .scheduledRetryDelayExceedsRemaining)
            XCTAssertEqual(error.reasonCode, ScheduledBriefingBudgetReason.retryDelayExceedsRemaining)
        }

        let waits = await sleeper.recordedWaits()
        let requests = await transport.capturedRequests()
        XCTAssertTrue(waits.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testSecondRateLimitAndOverDeepJSONFailClosed() async throws {
        let repeatedLimit = P3SlackTransport([
            .response(status: 429, data: Data(), headers: ["Retry-After": "1"]),
            .response(status: 429, data: Data(), headers: ["Retry-After": "1"]),
        ])
        let limitedClient = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: repeatedLimit,
            sleeper: P3SlackSleeper(),
            now: { Self.anchor }
        )
        do {
            _ = try await limitedClient.testAuthentication(connection: Self.connection())
            XCTFail("Expected the second 429 to stop.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }

        var nested: Any = "leaf"
        for _ in 0...SlackLimits.maximumJSONDepth { nested = ["next": nested] }
        let deep = P3SlackTransport([
            .response(status: 200, data: try JSONSerialization.data(withJSONObject: nested), headers: Self.jsonHeaders),
        ])
        let deepClient = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: deep, sleeper: P3SlackSleeper())
        do {
            _ = try await deepClient.testAuthentication(connection: Self.connection())
            XCTFail("Expected bounded JSON rejection.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .jsonLimitExceeded)
        }
    }

    func testMalformedOverDeepJSONIsRejectedBeforeObjectParsing() async throws {
        let preparseProbe = Data(String(repeating: "[", count: SlackLimits.maximumJSONDepth + 1).utf8)
        let transport = P3SlackTransport([
            .response(status: 200, data: preparseProbe, headers: Self.jsonHeaders),
        ])
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: P3SlackSleeper()
        )

        do {
            _ = try await client.testAuthentication(connection: Self.connection())
            XCTFail("Expected byte-level JSON depth rejection.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .jsonLimitExceeded)
        }
    }

    func testTokenExpiredRefreshesCredentialOnce() async throws {
        let provider = P3TokenProvider()
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.json(["ok": false, "error": "token_expired"]), headers: Self.jsonHeaders),
            .response(status: 200, data: Self.authSuccess(), headers: Self.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: provider, transport: transport, sleeper: P3SlackSleeper())
        let result = try await client.testAuthentication(connection: Self.connection())
        XCTAssertEqual(result.metadata.credentialRefreshCount, 1)
        let providerCalls = await provider.calls()
        XCTAssertEqual(providerCalls, [false, true])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer TEST_ACCESS_INITIAL_SENTINEL", "Bearer TEST_ACCESS_REFRESHED_SENTINEL"])
    }

    func testHTTP401And403RefreshExactlyOnceThenFailTruthfully() async throws {
        for status in [401, 403] {
            let provider = P3TokenProvider()
            let transport = P3SlackTransport([
                .response(status: status, data: Data(), headers: [:]),
                .response(status: status, data: Data(), headers: [:]),
            ])
            let client = SlackAPIClient(
                tokenProvider: provider,
                transport: transport,
                sleeper: P3SlackSleeper()
            )

            do {
                _ = try await client.testAuthentication(connection: Self.connection())
                XCTFail("Expected HTTP \(status) to fail after one credential refresh.")
            } catch let error as SlackAPIError {
                XCTAssertEqual(error.code, .httpFailure)
                XCTAssertEqual(error.httpStatus, status)
            }

            let providerCalls = await provider.calls()
            XCTAssertEqual(providerCalls, [false, true])
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testCancellationStopsActiveTransportAndNoWriteMethodExists() async throws {
        let transport = P3SlackTransport([.waitForCancellation])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper())
        let task = Task { try await client.testAuthentication(connection: Self.connection()) }
        await transport.waitForRequestCount(1)
        await client.cancelAll()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let cancellationCount = await transport.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(Set(SlackAPIMethod.allCases.map(\.rawValue)), [
            "auth.test", "conversations.list", "conversations.history", "users.info", "chat.getPermalink",
        ])
    }

    func testChannelDiscoveryPaginatesClassifiesAndExcludesArchived() async throws {
        let first = Self.json([
            "ok": true,
            "channels": [
                ["id": "C2", "name": "private-team", "is_private": true, "is_member": true, "is_archived": false],
                ["id": "C9", "name": "old", "is_private": false, "is_member": true, "is_archived": true],
            ],
            "response_metadata": ["next_cursor": "next-page"],
        ])
        let second = Self.json([
            "ok": true,
            "channels": [
                ["id": "C1", "name": "announcements", "is_private": false, "is_member": false, "is_archived": false],
            ],
            "response_metadata": ["next_cursor": ""],
        ])
        let transport = P3SlackTransport([
            .response(status: 200, data: first, headers: Self.jsonHeaders),
            .response(status: 200, data: second, headers: Self.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper(), now: { Self.anchor })
        let result = try await client.discoverConversations(connection: Self.connection())
        XCTAssertEqual(result.value.map(\.id), ["C1", "C2"])
        XCTAssertEqual(result.value.map(\.kind), [.publicChannel, .privateChannel])
        XCTAssertEqual(result.value.map(\.isMember), [false, true])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    fileprivate static var jsonHeaders: [String: String] { ["Content-Type": "application/json; charset=utf-8"] }

    fileprivate static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    fileprivate static func authSuccess() -> Data {
        json([
            "ok": true,
            "team_id": "T123",
            "team": "Acme",
            "user_id": "U123",
            "user": "Taylor",
            "url": "https://acme.slack.com/",
        ])
    }

    fileprivate static func connection(state: SlackConnectionState = .connected) -> SlackWorkspaceConnection {
        .init(
            id: "T123:U123",
            teamID: "T123",
            teamName: "Acme",
            userID: "U123",
            userDisplayName: "Taylor",
            state: state,
            grantedScopes: Set(SlackGrantedScope.allCases),
            credentialMetadata: nil,
            localModelConsent: false,
            connectedAt: anchor,
            updatedAt: anchor,
            lastFailureReasonCode: nil
        )
    }
}

final class SlackNormalizationP3Tests: XCTestCase, @unchecked Sendable {
    private static let anchor = SlackAPIClientP3Tests.anchor

    func testExactMentionAndMrkdwnSanitizationAreDeterministic() throws {
        let normalizer = SlackMessageNormalizer(now: { Self.anchor })
        let result = try normalizer.normalize(
            messages: [Self.message(
                ts: "1780000000.000001",
                text: "*Hi* <@U123> <https://private.example/path> <https://example.com|roadmap>\u{202e}",
                user: "U200"
            )],
            context: Self.context()
        )
        XCTAssertEqual(result.evidence.count, 1)
        XCTAssertTrue(result.evidence[0].directlyMentionsAuthenticatedUser)
        XCTAssertEqual(result.evidence[0].excerpt, "Hi @Taylor [link] roadmap")
        XCTAssertFalse(normalizer.containsExactUserMention("<@U1234>", userID: "U123"))
        XCTAssertTrue(normalizer.containsExactUserMention("<@U123|taylor>", userID: "U123"))
    }

    func testThreadFileAndSystemMessagesAreSkippedAndDeletionWinsDedupe() throws {
        let original = Self.message(ts: "1780000000.000010", text: "original", user: "U200")
        let edited = Self.message(ts: "1780000000.000010", text: "edited", user: "U200", editedAt: "1780000001.000000")
        let deleted = Self.message(
            ts: "1780000002.000000",
            subtype: "message_deleted",
            text: "",
            deletedTs: "1780000000.000010"
        )
        let thread = Self.message(ts: "1780000003.000000", text: "thread", user: "U200", threadTs: "1780000000.000010")
        let file = Self.message(ts: "1780000004.000000", subtype: "file_share", text: "file", user: "U200")
        let join = Self.message(ts: "1780000005.000000", subtype: "channel_join", text: "joined", user: "U200")

        let result = try SlackMessageNormalizer().normalize(
            messages: [file, original, join, edited, thread, deleted],
            context: Self.context()
        )
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertEqual(result.tombstones.count, 1)
        XCTAssertEqual(result.tombstones[0].messageTimestamp.rawValue, "1780000000.000010")
        XCTAssertEqual(Set(result.skipped.map(\.reason)), [.unsupportedSubtype, .threadReply])
    }

    func testNonfiniteSelectionWeightFailsClosed() throws {
        var context = Self.context()
        context = .init(
            connection: context.connection,
            selection: .init(
                workspaceID: context.selection.workspaceID,
                channelID: context.selection.channelID,
                displayName: context.selection.displayName,
                kind: context.selection.kind,
                enabled: true,
                weight: .nan,
                selectedAt: Self.anchor,
                lastSuccessfulRefreshAt: nil,
                lastFailureReasonCode: nil
            ),
            authorsByID: context.authorsByID,
            retrievedAt: context.retrievedAt
        )
        XCTAssertThrowsError(try SlackMessageNormalizer().normalize(messages: [Self.message(ts: "1780000000.1", text: "hello")], context: context)) { error in
            XCTAssertEqual((error as? SlackAPIError)?.code, .invalidRequest)
        }
    }

    fileprivate static func context(channelID: String = "C100", weight: Double = 1) -> SlackNormalizationContext {
        .init(
            connection: SlackAPIClientP3Tests.connection(),
            selection: .init(
                workspaceID: "T123:U123",
                channelID: channelID,
                displayName: "engineering",
                kind: .privateChannel,
                enabled: true,
                weight: weight,
                selectedAt: anchor,
                lastSuccessfulRefreshAt: nil,
                lastFailureReasonCode: nil
            ),
            authorsByID: ["U123": .init(id: "U123", displayName: "Taylor", kind: .user, isDeleted: false),
                          "U200": .init(id: "U200", displayName: "Mina", kind: .user, isDeleted: false)],
            retrievedAt: anchor
        )
    }

    fileprivate static func message(
        ts: String,
        subtype: String? = nil,
        text: String,
        user: String? = nil,
        deletedTs: String? = nil,
        threadTs: String? = nil,
        botID: String? = nil,
        editedAt: String? = nil
    ) -> SlackHistoryMessage {
        .init(
            type: "message",
            subtype: subtype,
            timestamp: SlackTimestamp(rawValue: ts)!,
            deletedTimestamp: deletedTs.flatMap(SlackTimestamp.init(rawValue:)),
            threadTimestamp: threadTs.flatMap(SlackTimestamp.init(rawValue:)),
            text: text,
            userID: user,
            botID: botID,
            appID: nil,
            username: botID == nil ? nil : "bot",
            replyCount: 0,
            editedAt: editedAt.flatMap(SlackTimestamp.init(rawValue:))
        )
    }
}

final class SlackSyncCoordinatorP3Tests: XCTestCase, @unchecked Sendable {
    private static let anchor = SlackAPIClientP3Tests.anchor

    func testSelectedChannelsRunSequentiallyOnePageEachAndPreservePartialSuccess() async throws {
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.history(channel: "C1", text: "one"), headers: SlackAPIClientP3Tests.jsonHeaders),
            .response(status: 200, data: SlackAPIClientP3Tests.json(["ok": false, "error": "channel_not_found"]), headers: SlackAPIClientP3Tests.jsonHeaders),
            .response(status: 200, data: Self.history(channel: "C3", text: "three"), headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper(), now: { Self.anchor })
        let coordinator = SlackSyncCoordinator(client: client, now: { Self.anchor })
        let selections = ["C3", "C1", "C2"].map(Self.selection)

        let output = try await coordinator.syncSelectedChannels(
            connection: SlackAPIClientP3Tests.connection(),
            selections: selections,
            cursors: []
        )
        XCTAssertEqual(output.run.state, .partial)
        XCTAssertEqual(output.run.successfulChannelCount, 2)
        XCTAssertEqual(output.run.failedChannelCount, 1)
        XCTAssertEqual(output.evidenceUpserts.map(\.channelID), ["C1", "C3"])
        XCTAssertEqual(output.directives.map(\.kind.rawValue).sorted(), [SlackSyncDirectiveKind.disableSelection.rawValue, SlackSyncDirectiveKind.purgeChannelEvidence.rawValue].sorted())
        let captured = await transport.capturedRequests()
        let historyRequests = captured.filter { $0.url?.path == SlackAPIMethod.conversationsHistory.path }
        XCTAssertEqual(historyRequests.count, 3)
        XCTAssertEqual(historyRequests.compactMap(Self.queryChannel), ["C1", "C2", "C3"])
        XCTAssertTrue(historyRequests.allSatisfy { Self.queryValue("limit", in: $0) == "15" })
    }

    func testCoordinatorForwardsTraceSinkIntoDefaultNormalizer() async throws {
        let transport = P3SlackTransport([
            .response(
                status: 200,
                data: Self.history(channel: "C1", text: "trace me"),
                headers: SlackAPIClientP3Tests.jsonHeaders
            ),
        ])
        let recorder = P3TraceRecorder()
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: P3SlackSleeper(),
            now: { Self.anchor },
            eventSink: { recorder.append($0) }
        )
        let coordinator = SlackSyncCoordinator(
            client: client,
            now: { Self.anchor },
            eventSink: { recorder.append($0) }
        )
        let trace = SlackTraceContext()

        _ = try await coordinator.syncSelectedChannels(
            connection: SlackAPIClientP3Tests.connection(),
            selections: [Self.selection("C1")],
            cursors: [],
            trace: trace
        )

        let normalizationEvents = recorder.events().filter { $0.event == .messageNormalization }
        XCTAssertEqual(normalizationEvents.map(\.status), [.started, .success])
        XCTAssertTrue(normalizationEvents.allSatisfy { $0.component == "slack_message_normalizer" })
        XCTAssertTrue(normalizationEvents.allSatisfy { $0.traceID == trace.traceID && $0.parentSpanID != nil })
    }

    func testUsersInfoResolvesAndClassifiesAppAuthor() async throws {
        let history = Self.history(
            messages: [[
                "type": "message",
                "ts": "1779999999.000001",
                "text": "App-authored update",
                "user": "UAPP",
            ]],
            nextCursor: nil,
            hasMore: false
        )
        let appUser = SlackAPIClientP3Tests.json([
            "ok": true,
            "user": [
                "id": "UAPP",
                "deleted": false,
                "is_bot": false,
                "is_app_user": true,
                "profile": [
                    "display_name": "Release Assistant",
                    "real_name": "Release Assistant",
                ],
            ],
        ])
        let transport = P3SlackTransport([
            .response(status: 200, data: history, headers: SlackAPIClientP3Tests.jsonHeaders),
            .response(status: 200, data: appUser, headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(
            tokenProvider: P3TokenProvider(),
            transport: transport,
            sleeper: P3SlackSleeper(),
            now: { Self.anchor }
        )
        let coordinator = SlackSyncCoordinator(client: client, now: { Self.anchor })

        let output = try await coordinator.syncSelectedChannels(
            connection: SlackAPIClientP3Tests.connection(),
            selections: [Self.selection("C1")],
            cursors: []
        )

        let evidence = try XCTUnwrap(output.evidenceUpserts.first)
        XCTAssertEqual(evidence.author.id, "UAPP")
        XCTAssertEqual(evidence.author.displayName, "Release Assistant")
        XCTAssertEqual(evidence.author.kind, .app)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            SlackAPIMethod.conversationsHistory.path,
            SlackAPIMethod.usersInfo.path,
        ])
        XCTAssertEqual(Self.queryValue("user", in: requests[1]), "UAPP")
        XCTAssertEqual(Self.queryValue("include_locale", in: requests[1]), "false")
    }

    func testCursorWindowDrainsAcrossThreeBoundedInvocationsWithoutGap() async throws {
        let page1 = (0..<15).map { Self.rawMessage(ts: "17799999\(85 - $0).000001", text: "p1-\($0)") }
        let page2 = (0..<15).map { Self.rawMessage(ts: "17799999\(70 - $0).000001", text: "p2-\($0)") }
        let page3 = [Self.rawMessage(ts: "1779999955.000001", text: "p3")]
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.history(messages: page1, nextCursor: "page-2", hasMore: true), headers: SlackAPIClientP3Tests.jsonHeaders),
            .response(status: 200, data: Self.history(messages: page2, nextCursor: "page-3", hasMore: true), headers: SlackAPIClientP3Tests.jsonHeaders),
            .response(status: 200, data: Self.history(messages: page3, nextCursor: nil, hasMore: false), headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper(), now: { Self.anchor })
        let coordinator = SlackSyncCoordinator(client: client, now: { Self.anchor })
        let connection = SlackAPIClientP3Tests.connection()
        let selection = Self.selection("C1")

        let first = try await coordinator.syncSelectedChannels(connection: connection, selections: [selection], cursors: [])
        XCTAssertEqual(first.evidenceUpserts.count, 15)
        XCTAssertEqual(first.cursorUpdates[0].nextCursor, "page-2")
        XCTAssertNotNil(first.cursorUpdates[0].windowLatest)
        let initialCommitted = first.cursorUpdates[0].committedOldest

        let second = try await coordinator.syncSelectedChannels(connection: connection, selections: [selection], cursors: first.cursorUpdates)
        XCTAssertEqual(second.evidenceUpserts.count, 15)
        XCTAssertEqual(second.cursorUpdates[0].nextCursor, "page-3")
        XCTAssertEqual(second.cursorUpdates[0].committedOldest, initialCommitted)

        let third = try await coordinator.syncSelectedChannels(connection: connection, selections: [selection], cursors: second.cursorUpdates)
        XCTAssertEqual(third.evidenceUpserts.count, 1)
        XCTAssertNil(third.cursorUpdates[0].nextCursor)
        XCTAssertNil(third.cursorUpdates[0].windowLatest)
        XCTAssertGreaterThan(third.cursorUpdates[0].committedOldest!, initialCommitted!)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.compactMap { Self.queryValue("cursor", in: $0) }, ["page-2", "page-3"])
    }

    func testPermalinkIsResolvedLazilyAndCached() async throws {
        let transport = P3SlackTransport([
            .response(
                status: 200,
                data: SlackAPIClientP3Tests.json([
                    "ok": true,
                    "permalink": "https://acme.slack.com/archives/C1/p1779999999000001",
                ]),
                headers: SlackAPIClientP3Tests.jsonHeaders
            ),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper())
        let coordinator = SlackSyncCoordinator(client: client)
        let context = SlackNormalizationP3Tests.context(channelID: "C1")
        let evidence = try SlackMessageNormalizer().normalize(
            messages: [SlackNormalizationP3Tests.message(ts: "1779999999.000001", text: "open me", botID: "B1")],
            context: context
        ).evidence[0]
        let requestsBeforeResolution = await transport.capturedRequests()
        XCTAssertTrue(requestsBeforeResolution.isEmpty)

        let first = try await coordinator.resolvePermalink(for: evidence, connection: context.connection)
        let second = try await coordinator.resolvePermalink(for: evidence, connection: context.connection)
        XCTAssertEqual(first.permalink, second.permalink)
        XCTAssertEqual(first.permalink?.host, "acme.slack.com")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, SlackAPIMethod.chatGetPermalink.path)
    }

    func testCancellationDuringQueuedProgressPreventsFirstRequest() async throws {
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.history(channel: "C1", text: "must not load"), headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper())
        let recorder = P3TraceRecorder()
        let coordinator = SlackSyncCoordinator(client: client, eventSink: { recorder.append($0) })
        let reference = P3SlackCoordinatorReference()
        await reference.set(coordinator)

        do {
            _ = try await coordinator.syncSelectedChannels(
                connection: SlackAPIClientP3Tests.connection(),
                selections: [Self.selection("C1")],
                cursors: [],
                progress: { update in
                    if update.state == .queued {
                        await reference.cancelAll()
                    }
                }
            )
            XCTFail("Expected cancellation after queued progress.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            recorder.events().filter { $0.event == .cancellation }.map(\.reasonCode),
            ["slack_sync_cancellation_requested"]
        )
    }

    func testCancellationDuringRunningProgressPreventsChannelRequest() async throws {
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.history(channel: "C1", text: "must not load"), headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper())
        let coordinator = SlackSyncCoordinator(client: client)
        let reference = P3SlackCoordinatorReference()
        await reference.set(coordinator)

        do {
            _ = try await coordinator.syncSelectedChannels(
                connection: SlackAPIClientP3Tests.connection(),
                selections: [Self.selection("C1")],
                cursors: [],
                progress: { update in
                    if update.state == .running {
                        await reference.cancelAll()
                    }
                }
            )
            XCTFail("Expected cancellation after running progress.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationDuringFinalProgressPreventsStaleOutputReturn() async throws {
        let transport = P3SlackTransport([
            .response(status: 200, data: Self.history(channel: "C1", text: "loaded once"), headers: SlackAPIClientP3Tests.jsonHeaders),
        ])
        let client = SlackAPIClient(tokenProvider: P3TokenProvider(), transport: transport, sleeper: P3SlackSleeper())
        let coordinator = SlackSyncCoordinator(client: client)
        let reference = P3SlackCoordinatorReference()
        await reference.set(coordinator)

        do {
            _ = try await coordinator.syncSelectedChannels(
                connection: SlackAPIClientP3Tests.connection(),
                selections: [Self.selection("C1")],
                cursors: [],
                progress: { update in
                    if update.state == .completed {
                        await reference.cancelAll()
                    }
                }
            )
            XCTFail("Expected cancellation instead of stale completed output.")
        } catch let error as SlackAPIError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    private static func selection(_ channelID: String) -> SlackConversationSelection {
        .init(
            workspaceID: "T123:U123",
            channelID: channelID,
            displayName: "channel-\(channelID.lowercased())",
            kind: .privateChannel,
            enabled: true,
            weight: 1,
            selectedAt: anchor,
            lastSuccessfulRefreshAt: nil,
            lastFailureReasonCode: nil
        )
    }

    private static func history(channel: String, text: String) -> Data {
        history(messages: [rawMessage(ts: "1779999999.000001", text: text)], nextCursor: nil, hasMore: false)
    }

    private static func history(messages: [[String: Any]], nextCursor: String?, hasMore: Bool) -> Data {
        SlackAPIClientP3Tests.json([
            "ok": true,
            "messages": messages,
            "has_more": hasMore,
            "response_metadata": ["next_cursor": nextCursor ?? ""],
        ])
    }

    private static func rawMessage(ts: String, text: String) -> [String: Any] {
        ["type": "message", "subtype": "bot_message", "ts": ts, "text": text, "bot_id": "B1", "username": "Build Bot"]
    }

    private static func queryChannel(_ request: URLRequest) -> String? { queryValue("channel", in: request) }

    private static func queryValue(_ key: String, in request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
}
