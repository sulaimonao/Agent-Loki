import Foundation
import XCTest
@testable import LokiBrief

private final class OAuthTraceRecorder: @unchecked Sendable {
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

private final class AsyncByteReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct CountingAsyncBytes: AsyncSequence, Sendable {
    typealias Element = UInt8

    struct AsyncIterator: AsyncIteratorProtocol {
        let total: Int
        let counter: AsyncByteReadCounter
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < total else { return nil }
            index += 1
            counter.increment()
            return 0x41
        }
    }

    let total: Int
    let counter: AsyncByteReadCounter

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(total: total, counter: counter)
    }
}

private actor SlackOAuthTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RecordingSlackOAuthTransport: SlackOAuthTransporting {
    private var responses: [SlackOAuthHTTPResponse]
    private let gate: SlackOAuthTestGate?
    private var requests: [URLRequest] = []

    init(responses: [SlackOAuthHTTPResponse], gate: SlackOAuthTestGate? = nil) {
        self.responses = responses
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> SlackOAuthHTTPResponse {
        requests.append(request)
        if let gate { await gate.wait() }
        guard !responses.isEmpty else { throw SlackOAuthFailure(code: .transportFailure) }
        return responses.removeFirst()
    }

    func requestCount() -> Int { requests.count }
    func request(at index: Int) -> URLRequest { requests[index] }
}

private actor OAuthTestCredentialStore: SlackCredentialStoring {
    private var credentials: [String: SlackOAuthCredential] = [:]
    private(set) var createCount = 0
    private(set) var replaceCount = 0
    private(set) var deleteCount = 0

    init(_ credential: SlackOAuthCredential? = nil) {
        if let credential { credentials[credential.accountIdentifier] = credential }
    }

    func create(_ credential: SlackOAuthCredential) async throws {
        guard credentials[credential.accountIdentifier] == nil else {
            throw SlackCredentialStoreFailure(code: .alreadyExists)
        }
        credentials[credential.accountIdentifier] = credential
        createCount += 1
    }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        guard let credential = credentials["\(teamID):\(userID)"] else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        guard credentials[credential.accountIdentifier] != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        credentials[credential.accountIdentifier] = credential
        replaceCount += 1
    }

    func delete(teamID: String, userID: String) async throws {
        guard credentials.removeValue(forKey: "\(teamID):\(userID)") != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        deleteCount += 1
    }
}

final class SlackOAuthClientTests: XCTestCase, @unchecked Sendable {
    func testProductionTraceEncodingIsStructuredBoundedAndSecretFree() throws {
        let privateWorkspace = "workspace-private-sentinel"
        let event = SlackTraceEvent(
            ts: Date(timeIntervalSince1970: 1_784_000_000),
            event: .credentialRefresh,
            traceID: "trace-safe",
            spanID: "span-safe",
            parentSpanID: "parent-safe",
            component: "slack_oauth",
            status: .success,
            reasonCode: "slack_refresh_succeeded",
            durationMilliseconds: 7,
            metadata: .init([(.workspaceHash, SlackPrivacy.hashIdentifier(privateWorkspace))])
        )

        let line = try XCTUnwrap(SlackProductionTraceLogger.encodedLine(for: event))
        XCTAssertLessThanOrEqual(line.utf8.count, 8_192)
        XCTAssertFalse(line.contains(privateWorkspace))
        XCTAssertFalse(line.contains("access-private-sentinel"))
        XCTAssertFalse(line.contains("refresh-private-sentinel"))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "slack.credential_refresh")
        XCTAssertEqual(object["trace_id"] as? String, "trace-safe")
        XCTAssertEqual(object["span_id"] as? String, "span-safe")
        XCTAssertEqual(object["parent_span_id"] as? String, "parent-safe")
        XCTAssertEqual(object["component"] as? String, "slack_oauth")
        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["reason_code"] as? String, "slack_refresh_succeeded")
        XCTAssertEqual(object["duration_ms"] as? Int, 7)
    }

    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)
    private static let scopes = SlackOAuthScopePolicy.requiredUserScopes.sorted().joined(separator: ",")

    func testAuthorizationURLUsesOnlyUserScopesS256AndExactCallback() throws {
        let material = try SlackPKCEGenerator(
            random: DeterministicOAuthRandom([
                Data(repeating: 0x31, count: 32),
                Data(repeating: 0x72, count: 32)
            ])
        ).generate()
        let client = try SlackOAuthClient(
            clientID: "123456.789012",
            transport: RecordingSlackOAuthTransport(responses: [])
        )
        let url = try client.authorizationURL(for: material)
        let query = Self.query(url)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "slack.com")
        XCTAssertEqual(url.path, "/oauth/v2/authorize")
        XCTAssertEqual(query["client_id"], "123456.789012")
        XCTAssertEqual(query["redirect_uri"], SlackOAuthCallbackContract.redirectURI)
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["user_scope"], Self.scopes)
        XCTAssertEqual(query["code_challenge"], material.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], material.state)
        XCTAssertNil(query["scope"])
        XCTAssertNil(query["client_secret"])
    }

    func testOAuthClientRejectsNonCanonicalRequestedScopePolicy() throws {
        let transport = RecordingSlackOAuthTransport(responses: [])
        for scopes in [
            Set(["channels:read"]),
            SlackOAuthScopePolicy.requiredUserScopes.union(["chat:write"]),
            SlackOAuthScopePolicy.requiredUserScopes.union(["emoji:read"])
        ] {
            XCTAssertThrowsError(
                try SlackOAuthClient(
                    clientID: "123456.789012",
                    requiredScopes: scopes,
                    transport: transport
                )
            ) { error in
                XCTAssertEqual((error as? SlackOAuthFailure)?.code, .scopeMismatch)
            }
        }
    }

    func testCodeExchangeOmitsClientSecretAndParsesNestedUserEnvelope() async throws {
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.nestedSuccess())])
        let client = try Self.client(transport)
        let verifier = try Self.verifier()

        let credential = try await client.exchangeAuthorizationCode(code: "one-time-code", verifier: verifier)
        XCTAssertEqual(credential.teamID, "T123")
        XCTAssertEqual(credential.userID, "U123")
        XCTAssertEqual(credential.accessToken, "access-one")
        XCTAssertEqual(credential.refreshToken, "refresh-one")
        XCTAssertEqual(Set(credential.grantedScopes), SlackOAuthScopePolicy.requiredUserScopes)
        XCTAssertEqual(credential.issuedAt, Self.anchor)
        XCTAssertEqual(credential.accessTokenExpiresAt, Self.anchor.addingTimeInterval(3_600))
        XCTAssertEqual(credential.refreshTokenExpiresAt, Self.anchor.addingTimeInterval(30 * 24 * 60 * 60))

        let request = await transport.request(at: 0)
        let form = Self.form(request)
        XCTAssertEqual(request.url, SlackOAuthClient.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["client_id"], "123456.789012")
        XCTAssertEqual(form["redirect_uri"], SlackOAuthCallbackContract.redirectURI)
        XCTAssertEqual(form["code"], "one-time-code")
        XCTAssertEqual(form["code_verifier"], verifier)
        XCTAssertNil(form["client_secret"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCodeExchangeAlsoParsesTopLevelUserTokenEnvelope() async throws {
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.topLevelSuccess())])
        let credential = try await Self.client(transport).exchangeAuthorizationCode(
            code: "one-time-code",
            verifier: try Self.verifier()
        )
        XCTAssertEqual(credential.teamID, "T123")
        XCTAssertEqual(credential.userID, "U123")
        XCTAssertEqual(credential.accessToken, "access-top")
        XCTAssertEqual(credential.refreshToken, "refresh-top")
    }

    func testCodeExchangeEmitsSecretFreeLinkedTraceEvents() async throws {
        let recorder = OAuthTraceRecorder()
        let trace = SlackTraceContext(
            traceID: "trace-oauth-exchange",
            spanID: "span-oauth-exchange",
            parentSpanID: "span-authorization"
        )
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.nestedSuccess())])
        let client = try SlackOAuthClient(
            clientID: "123456.789012",
            transport: transport,
            now: { Self.anchor },
            eventSink: { event in recorder.append(event) }
        )
        let verifier = try Self.verifier()

        _ = try await client.exchangeAuthorizationCode(
            code: "one-time-code-private",
            verifier: verifier,
            trace: trace
        )

        let events = recorder.events()
        XCTAssertEqual(events.map(\.event), [.codeExchange, .codeExchange])
        XCTAssertEqual(events.map(\.status), [.started, .success])
        XCTAssertEqual(events.map(\.reasonCode), [
            "slack_code_exchange_started",
            "slack_code_exchange_succeeded"
        ])
        XCTAssertTrue(events.allSatisfy { event in
            event.traceID == trace.traceID
                && event.spanID == trace.spanID
                && event.parentSpanID == trace.parentSpanID
                && event.component == "slack_oauth_client"
                && event.ts == Self.anchor
        })

        let encoded = try JSONEncoder().encode(events)
        let rendered = String(decoding: encoded, as: UTF8.self)
        for secret in ["one-time-code-private", verifier, "access-one", "refresh-one"] {
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testOAuthResponseRequiresJSONContentTypeAndBoundedDepth() async throws {
        let wrongContentType = SlackOAuthHTTPResponse(
            data: Self.nestedSuccess(),
            statusCode: 200,
            url: SlackOAuthClient.tokenEndpoint,
            contentType: "text/html"
        )
        await Self.assertOAuthFailure(.invalidContentType) {
            try await Self.client(
                RecordingSlackOAuthTransport(responses: [wrongContentType])
            ).exchangeAuthorizationCode(code: "one-time-code", verifier: try Self.verifier())
        }

        let tooDeep = Self.response(Self.deeplyNestedSuccess(depth: SlackOAuthClient.maximumJSONDepth + 2))
        await Self.assertOAuthFailure(.jsonDepthExceeded) {
            try await Self.client(
                RecordingSlackOAuthTransport(responses: [tooDeep])
            ).exchangeAuthorizationCode(code: "one-time-code", verifier: try Self.verifier())
        }
    }

    func testBoundedBodyReaderStopsBeforeConsumingOversizeStream() async throws {
        let counter = AsyncByteReadCounter()
        do {
            _ = try await SlackBoundedBodyReader.read(
                CountingAsyncBytes(total: 100, counter: counter),
                maximumBytes: 4
            )
            XCTFail("Expected the stream bound to reject the fifth byte.")
        } catch let failure as SlackBoundedBodyFailure {
            XCTAssertEqual(failure, .limitExceeded)
        }
        XCTAssertEqual(counter.value, 5)

        let lengthCounter = AsyncByteReadCounter()
        do {
            _ = try await SlackBoundedBodyReader.read(
                CountingAsyncBytes(total: 100, counter: lengthCounter),
                maximumBytes: 4,
                expectedContentLength: 5
            )
            XCTFail("Expected the declared response length to fail before streaming.")
        } catch let failure as SlackBoundedBodyFailure {
            XCTAssertEqual(failure, .limitExceeded)
        }
        XCTAssertEqual(lengthCounter.value, 0)
    }

    func testMalformedAndIncompleteOAuthResponsesFailClosed() async throws {
        let fixtures: [(Data, SlackOAuthFailureCode)] = [
            (Data("not-json".utf8), .malformedResponse),
            (Self.json(["ok": true]), .missingAccessToken),
            (Self.json([
                "ok": true,
                "team": ["id": "T123"],
                "authed_user": [
                    "id": "U123", "access_token": "access", "token_type": "user",
                    "expires_in": 3_600, "scope": Self.scopes
                ]
            ]), .missingRefreshToken),
            (Self.nestedSuccess(tokenType: "bot"), .tokenTypeMismatch),
            (Self.nestedSuccess(scope: "channels:read"), .scopeMismatch),
            (Self.nestedSuccess(scope: "\(Self.scopes),channels:read"), .scopeMismatch),
            (Self.nestedSuccess(scope: "\(Self.scopes),chat:write"), .scopeMismatch),
            (Self.nestedSuccess(scope: "\(Self.scopes),emoji:read"), .scopeMismatch)
        ]

        for (data, expected) in fixtures {
            let transport = RecordingSlackOAuthTransport(responses: [Self.response(data)])
            await Self.assertOAuthFailure(expected) {
                try await Self.client(transport).exchangeAuthorizationCode(
                    code: "one-time-code",
                    verifier: try Self.verifier()
                )
            }
        }
    }

    func testRefreshUsesTopLevelEnvelopePreservesIdentityAndAtomicallyReplacesStore() async throws {
        let original = Self.credential(access: "access-old", refresh: "refresh-old", accessLifetime: 1)
        let store = OAuthTestCredentialStore(original)
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.refreshSuccess())])
        let oauth = try Self.client(transport)
        let recorder = OAuthTraceRecorder()
        let trace = SlackTraceContext(
            traceID: "trace-refresh-success",
            spanID: "span-refresh-success",
            parentSpanID: "span-api"
        )
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: oauth,
            credentialStore: store,
            now: { Self.anchor },
            eventSink: { event in recorder.append(event) }
        )

        let refreshed = try await coordinator.forceRefresh(
            teamID: "T123",
            userID: "U123",
            trace: trace
        )
        XCTAssertEqual(refreshed.teamID, original.teamID)
        XCTAssertEqual(refreshed.userID, original.userID)
        XCTAssertEqual(refreshed.accessToken, "access-two")
        XCTAssertEqual(refreshed.refreshToken, "refresh-two")
        let replacementCount = await store.replaceCount
        let storedCredential = try await store.read(teamID: "T123", userID: "U123")
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(storedCredential, refreshed)

        let form = Self.form(await transport.request(at: 0))
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "refresh-old")
        XCTAssertNil(form["client_secret"])
        XCTAssertNil(form["code"])
        XCTAssertNil(form["redirect_uri"])

        let traceEvents = recorder.events()
        XCTAssertEqual(traceEvents.map(\.event), [.credentialRefresh, .credentialRefresh])
        XCTAssertEqual(traceEvents.map(\.status), [.started, .success])
        XCTAssertEqual(traceEvents.map(\.reasonCode), [
            "slack_credential_refresh_started",
            "slack_credential_refresh_succeeded"
        ])
        XCTAssertTrue(traceEvents.allSatisfy { event in
            event.traceID == trace.traceID
                && event.spanID == trace.spanID
                && event.parentSpanID == trace.parentSpanID
        })
    }

    func testConcurrentRefreshesShareOneExchangeAndOneAtomicReplacement() async throws {
        let original = Self.credential(access: "access-old", refresh: "refresh-old", accessLifetime: 1)
        let store = OAuthTestCredentialStore(original)
        let gate = SlackOAuthTestGate()
        let transport = RecordingSlackOAuthTransport(
            responses: [Self.response(Self.refreshSuccess())],
            gate: gate
        )
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor }
        )

        let first = Task { try await coordinator.forceRefresh(teamID: "T123", userID: "U123") }
        let second = Task { try await coordinator.forceRefresh(teamID: "T123", userID: "U123") }
        for _ in 0..<1_000 {
            if await transport.requestCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let blockedRequestCount = await transport.requestCount()
        XCTAssertEqual(blockedRequestCount, 1)
        await gate.open()

        let results = try await [first.value, second.value]
        let finalRequestCount = await transport.requestCount()
        let replacementCount = await store.replaceCount
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(replacementCount, 1)
    }

    func testScheduledRefreshBudgetRejectsBeforeOAuthTransportAndEmitsStableReason() async throws {
        let original = Self.credential(
            access: "access-budget-rejected",
            refresh: "refresh-budget-rejected",
            accessLifetime: 1
        )
        let store = OAuthTestCredentialStore(original)
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.refreshSuccess())])
        let recorder = OAuthTraceRecorder()
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor },
            eventSink: { event in recorder.append(event) }
        )
        let trace = SlackTraceContext(
            traceID: "trace-scheduled-budget-rejected",
            spanID: "span-scheduled-budget-rejected",
            parentSpanID: "span-scheduled-run"
        )
        let budget = ScheduledBriefingBudgetLedger(
            budget: .init(maximumSlackRequests: 0)
        )

        do {
            _ = try await coordinator.forceRefresh(
                teamID: "T123",
                userID: "U123",
                trace: trace,
                scheduledBudget: budget
            )
            XCTFail("Expected the scheduled Slack request budget to reject credential refresh.")
        } catch let failure as SlackAPIError {
            XCTAssertEqual(failure.code, .scheduledRequestBudgetExhausted)
            XCTAssertEqual(failure.reasonCode, ScheduledBriefingBudgetReason.slackRequestsExhausted)
        }

        let requestCount = await transport.requestCount()
        let replacementCount = await store.replaceCount
        let usage = await budget.usage()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(replacementCount, 0)
        XCTAssertEqual(usage.slackRequestCount, 0)
        XCTAssertEqual(usage.exhaustionReasonCodes, [ScheduledBriefingBudgetReason.slackRequestsExhausted])

        let events = recorder.events().filter { $0.event == .credentialRefresh }
        XCTAssertTrue(events.contains { event in
            event.status == .failed
                && event.reasonCode == ScheduledBriefingBudgetReason.slackRequestsExhausted
                && event.traceID == trace.traceID
                && event.spanID == trace.spanID
                && event.parentSpanID == trace.parentSpanID
        })
        let rendered = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(rendered.contains(original.accessToken))
        XCTAssertFalse(rendered.contains(original.refreshToken))
    }

    func testConcurrentScheduledRefreshesShareOneBudgetClaimAndExchange() async throws {
        let original = Self.credential(access: "access-old", refresh: "refresh-old", accessLifetime: 1)
        let store = OAuthTestCredentialStore(original)
        let gate = SlackOAuthTestGate()
        let transport = RecordingSlackOAuthTransport(
            responses: [Self.response(Self.refreshSuccess())],
            gate: gate
        )
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor }
        )
        let budget = ScheduledBriefingBudgetLedger(
            budget: .init(maximumSlackRequests: 1)
        )

        let first = Task {
            try await coordinator.forceRefresh(
                teamID: "T123",
                userID: "U123",
                scheduledBudget: budget
            )
        }
        let second = Task {
            try await coordinator.forceRefresh(
                teamID: "T123",
                userID: "U123",
                scheduledBudget: budget
            )
        }
        for _ in 0..<1_000 {
            if await transport.requestCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        let blockedRequestCount = await transport.requestCount()
        let blockedUsage = await budget.usage()
        XCTAssertEqual(blockedRequestCount, 1)
        XCTAssertEqual(blockedUsage.slackRequestCount, 1)
        await gate.open()

        let results = try await [first.value, second.value]
        let finalRequestCount = await transport.requestCount()
        let replacementCount = await store.replaceCount
        let finalUsage = await budget.usage()
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(finalUsage.slackRequestCount, 1)
        XCTAssertTrue(finalUsage.exhaustionReasonCodes.isEmpty)
    }

    func testRefreshEmitsTraceAndCancellationBlocksLateCredentialReplacement() async throws {
        let original = Self.credential(access: "access-old", refresh: "refresh-old", accessLifetime: 1)
        let store = OAuthTestCredentialStore(original)
        let gate = SlackOAuthTestGate()
        let transport = RecordingSlackOAuthTransport(
            responses: [Self.response(Self.refreshSuccess())],
            gate: gate
        )
        let recorder = OAuthTraceRecorder()
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor },
            eventSink: { event in recorder.append(event) }
        )
        let trace = SlackTraceContext(
            traceID: "trace-refresh",
            spanID: "span-refresh",
            parentSpanID: "span-api"
        )

        let refresh = Task {
            try await coordinator.forceRefresh(
                teamID: "T123",
                userID: "U123",
                trace: trace
            )
        }
        for _ in 0..<1_000 {
            if await transport.requestCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let requestCountBeforeCancellation = await transport.requestCount()
        XCTAssertEqual(requestCountBeforeCancellation, 1)

        await coordinator.cancelRefresh(teamID: "T123", userID: "U123", trace: trace)
        await gate.open()

        await Self.assertOAuthFailure(.cancelled) {
            try await refresh.value
        }
        let replacementCount = await store.replaceCount
        let storedCredential = try await store.read(teamID: "T123", userID: "U123")
        XCTAssertEqual(replacementCount, 0)
        XCTAssertEqual(storedCredential, original)
        await Self.assertOAuthFailure(.cancelled) {
            try await coordinator.forceRefresh(
                teamID: "T123",
                userID: "U123",
                trace: trace
            )
        }
        let requestCountAfterInvalidation = await transport.requestCount()
        XCTAssertEqual(requestCountAfterInvalidation, 1)

        let events = recorder.events().filter { $0.event == .credentialRefresh }
        XCTAssertTrue(events.contains { event in
            event.status == .started
                && event.reasonCode == "slack_credential_refresh_started"
        })
        XCTAssertTrue(events.contains { event in
            event.status == .failed
                && event.reasonCode == "slack_credential_refresh_cancelled"
        })
        XCTAssertTrue(events.contains { event in
            event.status == .failed
                && event.reasonCode == SlackOAuthFailureCode.cancelled.rawValue
        })
        XCTAssertTrue(events.allSatisfy { event in
            event.traceID == trace.traceID
                && event.spanID == trace.spanID
                && event.parentSpanID == trace.parentSpanID
                && event.metadata[.workspaceHash] != "T123:U123"
        })
        let rendered = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in ["access-old", "refresh-old", "access-two", "refresh-two"] {
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testRefreshFailureKeepsOldCredentialAndRequiresExplicitReauthorization() async throws {
        let original = Self.credential(access: "access-old", refresh: "refresh-old", accessLifetime: 1)
        let store = OAuthTestCredentialStore(original)
        let rejected = Self.json(["ok": false, "error": "invalid_refresh_token"])
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(rejected)])
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor }
        )

        do {
            _ = try await coordinator.forceRefresh(teamID: "T123", userID: "U123")
            XCTFail("Expected refresh rejection.")
        } catch let failure as SlackOAuthFailure {
            XCTAssertEqual(failure.code, .refreshTokenInvalid)
            XCTAssertTrue(failure.requiresReauthorization)
        }
        let replacementCount = await store.replaceCount
        let storedCredential = try await store.read(teamID: "T123", userID: "U123")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(replacementCount, 0)
        XCTAssertEqual(storedCredential, original)
        XCTAssertEqual(requestCount, 1, "Refresh failure must not start a browser or retry.")
    }

    func testExpiredRefreshTokenFailsBeforeTransportOrStoreReplacement() async throws {
        let expired = SlackOAuthCredential(
            teamID: "T123",
            userID: "U123",
            accessToken: "access-old",
            refreshToken: "refresh-old",
            tokenType: "user",
            issuedAt: Self.anchor.addingTimeInterval(-60 * 24 * 60 * 60),
            accessTokenExpiresAt: Self.anchor.addingTimeInterval(-1),
            refreshTokenExpiresAt: Self.anchor.addingTimeInterval(-1),
            grantedScopes: Array(SlackOAuthScopePolicy.requiredUserScopes)
        )
        let store = OAuthTestCredentialStore(expired)
        let transport = RecordingSlackOAuthTransport(responses: [Self.response(Self.refreshSuccess())])
        let coordinator = SlackCredentialRefreshCoordinator(
            oauthClient: try Self.client(transport),
            credentialStore: store,
            now: { Self.anchor }
        )

        await Self.assertOAuthFailure(.refreshTokenExpired) {
            try await coordinator.forceRefresh(teamID: "T123", userID: "U123")
        }
        let requestCount = await transport.requestCount()
        let replacementCount = await store.replaceCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(replacementCount, 0)
    }

    private static func client(_ transport: any SlackOAuthTransporting) throws -> SlackOAuthClient {
        try SlackOAuthClient(clientID: "123456.789012", transport: transport, now: { anchor })
    }

    private static func verifier() throws -> String {
        let value = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        _ = try SlackPKCEGenerator.s256Challenge(for: value)
        return value
    }

    private static func credential(access: String, refresh: String, accessLifetime: TimeInterval) -> SlackOAuthCredential {
        SlackOAuthCredential(
            teamID: "T123",
            userID: "U123",
            accessToken: access,
            refreshToken: refresh,
            tokenType: "user",
            issuedAt: anchor.addingTimeInterval(-10),
            accessTokenExpiresAt: anchor.addingTimeInterval(accessLifetime),
            refreshTokenExpiresAt: anchor.addingTimeInterval(20 * 24 * 60 * 60),
            grantedScopes: Array(SlackOAuthScopePolicy.requiredUserScopes)
        )
    }

    private static func nestedSuccess(tokenType: String = "user", scope: String = scopes) -> Data {
        json([
            "ok": true,
            "team": ["id": "T123"],
            "authed_user": [
                "id": "U123",
                "access_token": "access-one",
                "refresh_token": "refresh-one",
                "token_type": tokenType,
                "expires_in": 3_600,
                "scope": scope
            ]
        ])
    }

    private static func topLevelSuccess() -> Data {
        json([
            "ok": true,
            "team": ["id": "T123"],
            "authed_user": ["id": "U123"],
            "access_token": "access-top",
            "refresh_token": "refresh-top",
            "token_type": "user",
            "expires_in": 3_600,
            "scope": scopes
        ])
    }

    private static func refreshSuccess() -> Data {
        json([
            "ok": true,
            "access_token": "access-two",
            "refresh_token": "refresh-two",
            "token_type": "user",
            "expires_in": 3_600,
            "scope": scopes
        ])
    }

    private static func deeplyNestedSuccess(depth: Int) -> Data {
        var nested: Any = "leaf"
        for _ in 0..<depth {
            nested = ["next": nested]
        }
        return json([
            "ok": true,
            "team": ["id": "T123"],
            "authed_user": [
                "id": "U123",
                "access_token": "access-one",
                "refresh_token": "refresh-one",
                "token_type": "user",
                "expires_in": 3_600,
                "scope": scopes
            ],
            "unknown_nested_value": nested
        ])
    }

    private static func response(_ data: Data, status: Int = 200, url: URL? = SlackOAuthClient.tokenEndpoint) -> SlackOAuthHTTPResponse {
        SlackOAuthHTTPResponse(
            data: data,
            statusCode: status,
            url: url,
            contentType: "application/json; charset=utf-8"
        )
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody,
              let string = String(data: body, encoding: .utf8),
              let items = URLComponents(string: "?\(string)")?.queryItems
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private static func assertOAuthFailure<T>(
        _ expected: SlackOAuthFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected OAuth failure \(expected.rawValue).")
        } catch let failure as SlackOAuthFailure {
            XCTAssertEqual(failure.code, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

private final class DeterministicOAuthRandom: SlackSecureRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) { self.values = values }

    func bytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { throw SlackPKCEFailure(code: .randomGenerationFailed) }
        return values.removeFirst()
    }
}
