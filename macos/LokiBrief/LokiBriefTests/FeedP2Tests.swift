import Foundation
import XCTest
@testable import LokiBrief

private struct StubFeedResolver: FeedHostResolving {
    let addresses: [FeedResolvedAddress]
    let failure: FeedFetchFailure?

    init(_ addresses: [FeedResolvedAddress], failure: FeedFetchFailure? = nil) {
        self.addresses = addresses
        self.failure = failure
    }

    func resolve(host: String) async throws -> [FeedResolvedAddress] {
        if let failure { throw failure }
        return addresses
    }
}

private actor SequencedFeedResolver: FeedHostResolving {
    private var responses: [[FeedResolvedAddress]]
    private var hosts: [String] = []

    init(_ responses: [[FeedResolvedAddress]]) { self.responses = responses }

    func resolve(host: String) async throws -> [FeedResolvedAddress] {
        hosts.append(host)
        guard !responses.isEmpty else { throw FeedFetchFailure(.dnsResolutionFailed) }
        return responses.removeFirst()
    }

    func recordedHosts() -> [String] { hosts }
}

private actor ManuallyCompletedFeedResolver: FeedHostResolving {
    private var continuation: CheckedContinuation<[FeedResolvedAddress], Error>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve(host: String) async throws -> [FeedResolvedAddress] {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete(_ addresses: [FeedResolvedAddress]) {
        continuation?.resume(returning: addresses)
        continuation = nil
    }
}

private actor MockFeedTransport: FeedTransporting {
    enum Action: Sendable {
        case response(status: Int, data: Data, headers: [String: String] = [:], finalURL: URL? = nil)
        case failure(FeedFetchFailure)
        case urlError(URLError.Code)
        case waitForCancellation
    }

    struct RecordedRequest: Sendable {
        let url: URL?
        let approvedAddress: FeedResolvedAddress
        let method: String?
        let headers: [String: String]
        let body: Data?
        let timeout: TimeInterval
        let responseLimit: Int
        let resourceTimeout: TimeInterval
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var actions: [Action]
    private var requests: [RecordedRequest] = []
    private var pending: [UUID: CheckedContinuation<FeedTransportResponse, Error>] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var waiters: [Waiter] = []

    init(_ actions: [Action]) { self.actions = actions }

    func data(for request: URLRequest, target: FeedValidatedTarget, requestID: UUID, responseLimit: Int, resourceTimeout: TimeInterval) async throws -> FeedTransportResponse {
        requests.append(.init(
            url: request.url,
            approvedAddress: target.approvedAddress,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeout: request.timeoutInterval,
            responseLimit: responseLimit,
            resourceTimeout: resourceTimeout
        ))
        resumeWaiters()
        guard !actions.isEmpty else { throw FeedFetchFailure(.networkUnavailable) }
        switch actions.removeFirst() {
        case let .response(status, data, headers, finalURL):
            guard data.count <= responseLimit else { throw FeedFetchFailure(.responseTooLarge) }
            return .init(data: data, statusCode: status, url: finalURL ?? target.url, headers: headers)
        case let .failure(failure):
            throw failure
        case let .urlError(code):
            throw URLError(code)
        case .waitForCancellation:
            if cancelledBeforeRegistration.remove(requestID) != nil { throw URLError(.cancelled) }
            return try await withCheckedThrowingContinuation { pending[requestID] = $0 }
        }
    }

    func cancel(requestID: UUID) async {
        if let continuation = pending.removeValue(forKey: requestID) {
            continuation.resume(throwing: URLError(.cancelled))
        } else {
            cancelledBeforeRegistration.insert(requestID)
        }
    }

    func recordedRequests() -> [RecordedRequest] { requests }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append(.init(count: count, continuation: $0)) }
    }

    private func resumeWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if requests.count >= waiter.count { waiter.continuation.resume() }
            else { remaining.append(waiter) }
        }
        waiters = remaining
    }
}

private final class FeedTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FeedTraceEvent] = []

    func record(_ event: FeedTraceEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func snapshot() -> [FeedTraceEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }
}

private final class FeedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [FeedRefreshState] = []

    func record(_ state: FeedRefreshState) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func snapshot() -> [FeedRefreshState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }
}

private final class FeedBudgetUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by duration: TimeInterval) {
        lock.lock(); value += duration; lock.unlock()
    }
}

private actor AddFeedRetriever: FeedRetrieving {
    enum Mode: Sendable { case success, failure(FeedFetchFailure) }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        switch mode {
        case let .failure(failure): throw failure
        case .success:
            let now = Date()
            var connected = subscription
            connected.state = .connected
            connected.format = .rss2
            connected.lastAttemptedAt = now
            connected.lastSuccessfulAt = now
            connected.lastHTTPStatus = 200
            connected.updatedAt = now
            let entry = NormalizedFeedEntry(
                id: "add-flow-entry",
                identity: .init(value: "add-flow-entry", basis: .upstreamIdentifier),
                subscriptionID: connected.id,
                sourceTitle: connected.title,
                title: "Synthetic add-flow evidence",
                summary: "A deterministic fixture used for the Add Feed workflow.",
                canonicalURL: URL(string: "https://example.com/add-flow"),
                author: "Loki Fixture",
                publishedAt: now,
                updatedAt: nil,
                retrievedAt: now,
                originalPosition: 0,
                provenance: .init(subscriptionID: connected.id, feedURL: connected.canonicalURL, format: .rss2, upstreamIdentifier: "add-flow-entry", retrievedAt: now, originalPosition: 0)
            )
            return .init(
                subscription: connected,
                entries: [entry],
                record: .init(id: "fetch-add-flow", subscriptionID: connected.id, traceID: trace.traceID, attemptedAt: now, completedAt: now, httpStatus: 200, responseByteCount: 256, parsedEntryCount: 1, finalURL: connected.canonicalURL, eTag: nil, lastModified: nil, wasNotModified: false),
                warnings: []
            )
        }
    }

    func cancelAll() async { }
}

private actor GatedProgressFeedRetriever: FeedRetrieving {
    private struct StateWaiter {
        let state: FeedRefreshState
        let continuation: CheckedContinuation<Void, Never>
    }

    private var currentState: FeedRefreshState?
    private var stateWaiters: [StateWaiter] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var holdCancellationCleanup = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        try await AddFeedRetriever(.success).fetch(subscription, trace: trace)
    }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext, progress: @escaping FeedProgressHandler) async throws -> FeedFetchResult {
        cancelled = false
        currentState = nil
        for state in [FeedRefreshState.validating, .fetching, .parsing, .normalizing] {
            await progress(state)
            currentState = state
            let ready = stateWaiters.filter { $0.state == state }
            stateWaiters.removeAll { $0.state == state }
            ready.forEach { $0.continuation.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
            guard !cancelled, !Task.isCancelled else { throw FeedFetchFailure(.requestCancelled) }
        }
        await progress(.complete)
        return try await AddFeedRetriever(.success).fetch(subscription, trace: trace)
    }

    func waitUntilReached(_ state: FeedRefreshState) async {
        if currentState == state { return }
        await withCheckedContinuation { stateWaiters.append(.init(state: state, continuation: $0)) }
    }

    func release(_ state: FeedRefreshState) {
        guard currentState == state else { return }
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func setHoldCancellationCleanup(_ hold: Bool) {
        holdCancellationCleanup = hold
    }

    func releaseCancellationCleanup() {
        holdCancellationCleanup = false
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    func cancelAll() async {
        cancelled = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        if holdCancellationCleanup {
            await withCheckedContinuation { cleanupContinuation = $0 }
        }
    }
}

private actor ScheduledGatedFeedRetriever: FeedRetrieving {
    private var capturedSubscription: FeedSubscription?
    private var continuation: CheckedContinuation<FeedFetchResult, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        capturedSubscription = subscription
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete() {
        guard var subscription = capturedSubscription, let continuation else { return }
        let completedAt = Date()
        subscription.state = .connected
        subscription.format = .rss2
        subscription.lastAttemptedAt = completedAt
        subscription.lastSuccessfulAt = completedAt
        subscription.lastHTTPStatus = 200
        subscription.updatedAt = completedAt
        self.continuation = nil
        continuation.resume(returning: .init(
            subscription: subscription,
            entries: [],
            record: .init(
                id: "scheduled-gated-fetch",
                subscriptionID: subscription.id,
                traceID: "scheduled-gated-trace",
                attemptedAt: completedAt,
                completedAt: completedAt,
                httpStatus: 200,
                responseByteCount: 0,
                parsedEntryCount: 0,
                finalURL: subscription.canonicalURL,
                eTag: nil,
                lastModified: nil,
                wasNotModified: true
            ),
            warnings: []
        ))
    }

    func cancelAll() async { }
}

@MainActor
final class FeedP2Tests: XCTestCase, @unchecked Sendable {
    private let sourceURL = URL(string: "https://feeds.example.com/feed.xml")!
    private let fixedDate = Date(timeIntervalSince1970: 1_752_595_200)
    private let publicResolver = StubFeedResolver([.ipv4(93, 184, 216, 34)])

    func testSyntheticFixtureFilesParseRSSAtomAndJSONFeed() throws {
        let parser = FeedParser()
        let rss = try parser.parse(fixture("valid-rss.xml"), sourceURL: sourceURL)
        let atom = try parser.parse(fixture("valid-atom.xml"), sourceURL: sourceURL)
        let json = try parser.parse(fixture("valid-json-feed.json"), sourceURL: sourceURL)

        XCTAssertEqual(rss.format, .rss2)
        XCTAssertEqual(rss.feedTitle, "Loki Synthetic RSS")
        XCTAssertEqual(rss.entries.first?.upstreamIdentifier, "rss-item-1")
        XCTAssertEqual(atom.format, .atom1)
        XCTAssertEqual(atom.entries.first?.author, "Fixture Author")
        XCTAssertEqual(json.format, .jsonFeed11)
        XCTAssertEqual(json.entries.first?.title, "JSON fixture")

        let jsonV1 = Data(String(decoding: fixture("valid-json-feed.json"), as: UTF8.self).replacingOccurrences(of: "version/1.1", with: "version/1").utf8)
        XCTAssertEqual(try parser.parse(jsonV1, sourceURL: sourceURL).format, .jsonFeed11)
    }

    func testMalformedUnsupportedOversizedDepthAndEntryLimitsFailClosed() throws {
        let parser = FeedParser()
        XCTAssertThrowsError(try parser.parse(fixture("malformed.xml"), sourceURL: sourceURL)) { self.assertFailure($0, .malformedXML) }
        XCTAssertThrowsError(try parser.parse(fixture("malformed.json"), sourceURL: sourceURL)) { self.assertFailure($0, .malformedJSON) }
        XCTAssertThrowsError(try parser.parse(Data("<html><body>not a feed</body></html>".utf8), sourceURL: sourceURL)) { self.assertFailure($0, .unsupportedFormat) }
        XCTAssertThrowsError(try parser.parse(Data(repeating: 0x20, count: FeedLimits.maximumParserBytes + 1), sourceURL: sourceURL)) { self.assertFailure($0, .responseTooLarge) }

        let deep = Data((String(repeating: "<x>", count: FeedLimits.maximumXMLDepth + 1) + String(repeating: "</x>", count: FeedLimits.maximumXMLDepth + 1)).utf8)
        XCTAssertThrowsError(try parser.parse(deep, sourceURL: sourceURL)) { self.assertFailure($0, .unsupportedFormat) }

        let items = (0...FeedLimits.maximumParsedEntries).map { ["id": "item-\($0)", "content_text": "fixture"] }
        let object: [String: Any] = ["version": "https://jsonfeed.org/version/1.1", "title": "Limit", "items": items]
        let tooMany = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try parser.parse(tooMany, sourceURL: sourceURL)) { self.assertFailure($0, .parserLimitExceeded) }
    }

    func testXMLExternalEntityAndDTDDeclarationsAreRejected() throws {
        XCTAssertThrowsError(try FeedParser().parse(fixture("external-entity.xml"), sourceURL: sourceURL)) {
            self.assertFailure($0, .externalEntityRejected)
        }
    }

    func testNormalizationHandlesMissingMetadataDatesSanitizationAndCanonicalLink() throws {
        let parsed = FeedParseResult(
            format: .rss2,
            feedTitle: "Fixture",
            entries: [.init(
                title: nil,
                summary: "<p>Useful &amp; bounded</p><script>do-not-run()</script>\u{0007}",
                url: URL(string: "https://EXAMPLE.com:443/story#tracker"),
                author: "  Fixture Author  ",
                publishedAt: nil,
                updatedAt: nil,
                upstreamIdentifier: nil,
                originalPosition: 7
            )],
            warnings: []
        )
        let entry = try XCTUnwrap(FeedNormalizer().normalize(parsed, subscription: subscription(), retrievedAt: fixedDate).first)
        XCTAssertEqual(entry.title, "Useful & bounded")
        XCTAssertEqual(entry.summary, "Useful & bounded")
        XCTAssertEqual(entry.canonicalURL?.absoluteString, "https://example.com/story")
        XCTAssertEqual(entry.author, "Fixture Author")
        XCTAssertNil(entry.publishedAt)
        XCTAssertNil(entry.updatedAt)
        XCTAssertEqual(entry.identity.basis, .canonicalURL)
        XCTAssertFalse(entry.summary.contains("do-not-run"))
        XCTAssertFalse(entry.summary.contains("<"))
        XCTAssertFalse(entry.summary.contains("\u{0007}"))
    }

    func testDateNormalizationAndStableFallbackIdentityIgnoreFeedPosition() throws {
        let rss = Data("""
        <rss version="2.0"><channel><title>Dates</title><item><title>Same item</title><description>Same summary</description><pubDate>Tue, 15 Jul 2025 16:00:00 +0000</pubDate></item></channel></rss>
        """.utf8)
        let parsed = try FeedParser().parse(rss, sourceURL: sourceURL)
        XCTAssertEqual(parsed.entries.first?.publishedAt, Date(timeIntervalSince1970: 1_752_595_200))

        let first = FeedParseResult(format: .rss2, feedTitle: "A", entries: [.init(title: "Same", summary: "Evidence", url: nil, author: nil, publishedAt: nil, updatedAt: nil, upstreamIdentifier: nil, originalPosition: 0)], warnings: [])
        let moved = FeedParseResult(format: .rss2, feedTitle: "A", entries: [.init(title: "Same", summary: "Evidence", url: nil, author: nil, publishedAt: nil, updatedAt: nil, upstreamIdentifier: nil, originalPosition: 99)], warnings: [])
        let normalizer = FeedNormalizer()
        XCTAssertEqual(normalizer.normalize(first, subscription: subscription(), retrievedAt: fixedDate).first?.id, normalizer.normalize(moved, subscription: subscription(), retrievedAt: fixedDate.addingTimeInterval(86_400)).first?.id)
    }

    func testDuplicateIdentifiersAndCanonicalURLsCollapseWithoutCrossSourceMerging() throws {
        let duplicateID = FeedParseResult(format: .jsonFeed11, feedTitle: "Duplicates", entries: [
            .init(title: "First", summary: "A", url: URL(string: "https://example.com/a"), author: nil, publishedAt: fixedDate, updatedAt: nil, upstreamIdentifier: "same-id", originalPosition: 0),
            .init(title: "Second", summary: "B", url: URL(string: "https://example.com/b"), author: nil, publishedAt: fixedDate, updatedAt: nil, upstreamIdentifier: "same-id", originalPosition: 1)
        ], warnings: [])
        XCTAssertEqual(FeedNormalizer().normalize(duplicateID, subscription: subscription(), retrievedAt: fixedDate).count, 1)

        let duplicateURL = FeedParseResult(format: .jsonFeed11, feedTitle: "Duplicates", entries: [
            .init(title: "First", summary: "A", url: URL(string: "https://example.com/shared#one"), author: nil, publishedAt: fixedDate, updatedAt: nil, upstreamIdentifier: "id-a", originalPosition: 0),
            .init(title: "Second", summary: "B", url: URL(string: "https://example.com/shared#two"), author: nil, publishedAt: fixedDate, updatedAt: nil, upstreamIdentifier: "id-b", originalPosition: 1)
        ], warnings: [])
        let sourceA = subscription(id: "source-a")
        let sourceB = subscription(id: "source-b")
        XCTAssertEqual(FeedNormalizer().normalize(duplicateURL, subscription: sourceA, retrievedAt: fixedDate).count, 1)
        XCTAssertNotEqual(
            FeedNormalizer().normalize(duplicateURL, subscription: sourceA, retrievedAt: fixedDate).first?.id,
            FeedNormalizer().normalize(duplicateURL, subscription: sourceB, retrievedAt: fixedDate).first?.id
        )
    }

    func testURLPolicyAllowsOnlyCanonicalPublicHTTPS() async throws {
        let policy = FeedURLPolicy(resolver: publicResolver)
        let accepted = try await policy.validate(URL(string: "https://EXAMPLE.com:443/feed?q=1#fragment")!)
        XCTAssertEqual(accepted.url.absoluteString, "https://example.com/feed?q=1")
        XCTAssertEqual(accepted.approvedAddress, .ipv4(93, 184, 216, 34))

        let forbidden = [
            "http://example.com/feed", "file:///tmp/feed", "data:text/plain,test", "javascript:alert(1)",
            "ftp://example.com/feed", "smb://example.com/feed", "afp://example.com/feed", "ssh://example.com/feed"
        ]
        for value in forbidden {
            do { _ = try await policy.validate(URL(string: value)!); XCTFail("Expected rejection for \(value)") }
            catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .forbiddenScheme) }
        }

        let cancelledSignal = FeedCancellationSignal()
        cancelledSignal.cancel()
        do {
            _ = try await policy.validate(URL(string: "https://8.8.8.8/feed")!, cancellationSignal: cancelledSignal)
            XCTFail("Expected numeric literal policy cancellation")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .requestCancelled)
        }
    }

    func testURLPolicyRejectsCredentialsLocalPrivateMixedDNSAndAmbiguousNumericHosts() async throws {
        let publicPolicy = FeedURLPolicy(resolver: publicResolver)
        let cases: [(String, FeedFetchFailureCode)] = [
            ("https://user:pass@example.com/feed", .credentialsForbidden),
            ("https://localhost/feed", .localHostForbidden),
            ("https://service.internal/feed", .localHostForbidden),
            ("https://127.0.0.1/feed", .nonPublicAddress),
            ("https://10.0.0.1/feed", .nonPublicAddress),
            ("https://169.254.1.1/feed", .nonPublicAddress),
            ("https://[::1]/feed", .nonPublicAddress),
            ("https://2130706433/feed", .numericHostRejected),
            ("https://example.com:11434/feed", .localHostForbidden)
        ]
        for (value, expected) in cases {
            do { _ = try await publicPolicy.validate(URL(string: value)!); XCTFail("Expected \(expected.rawValue)") }
            catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, expected, value) }
        }

        let mixed = FeedURLPolicy(resolver: StubFeedResolver([.ipv4(93, 184, 216, 34), .ipv4(192, 168, 1, 4)]))
        do { _ = try await mixed.validate(URL(string: "https://mixed.example/feed")!); XCTFail("Expected mixed DNS rejection") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .nonPublicAddress) }
    }

    func testURLPolicySelectsOneDeterministicApprovedAddressAndCapsResolutionSet() async throws {
        let policy = FeedURLPolicy(resolver: StubFeedResolver([
            .ipv6([0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
            .ipv4(104, 16, 1, 2),
            .ipv4(93, 184, 216, 34),
            .ipv4(93, 184, 216, 34),
        ]))
        let target = try await policy.validate(sourceURL)
        XCTAssertEqual(target.approvedAddress, .ipv4(93, 184, 216, 34))
        XCTAssertEqual(target.approvedAddress.numericHost, "93.184.216.34")

        let tooMany: [FeedResolvedAddress] = (0...FeedLimits.maximumResolvedAddresses).map { .ipv4(8, 8, UInt8($0), 8) }
        do {
            _ = try await FeedURLPolicy(resolver: StubFeedResolver(tooMany)).validate(sourceURL)
            XCTFail("Expected bounded DNS result rejection")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .dnsAddressLimitExceeded)
        }
    }

    func testAddressPolicyFailClosesCurrentIANASpecialRangesAndAllowsOrdinaryPublicAddresses() {
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv4(192, 0, 0, 9)))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv4(192, 0, 2, 1)))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv4(192, 88, 99, 1)))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv4(192, 168, 1, 1)))
        XCTAssertTrue(FeedURLPolicy.isPublic(.ipv4(192, 1, 1, 1)))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv6([0x20, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv6([0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])))
        XCTAssertFalse(FeedURLPolicy.isPublic(.ipv6([0x3f, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])))
        XCTAssertTrue(FeedURLPolicy.isPublic(.ipv6([0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])))
    }

    func testSameHostRedirectRejectsDNSRebindingBeforeSecondRequest() async throws {
        let resolver = SequencedFeedResolver([
            [.ipv4(93, 184, 216, 34)],
            [.ipv4(127, 0, 0, 1)],
        ])
        let transport = MockFeedTransport([.response(status: 302, data: Data(), headers: ["location": "/rebound.xml"])])
        let client = FeedRetrievalClient(policy: .init(resolver: resolver), transport: transport, now: { self.fixedDate })
        do {
            _ = try await client.fetch(subscription(), trace: .init())
            XCTFail("Expected redirect rebinding rejection")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .redirectTargetRejected)
        }
        let resolvedHosts = await resolver.recordedHosts()
        XCTAssertEqual(resolvedHosts, ["feeds.example.com", "feeds.example.com"])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.approvedAddress, .ipv4(93, 184, 216, 34))
    }

    func testEveryRedirectRequestUsesItsFreshPolicyApprovedAddress() async throws {
        let firstAddress = FeedResolvedAddress.ipv4(93, 184, 216, 34)
        let secondAddress = FeedResolvedAddress.ipv4(104, 16, 1, 2)
        let resolver = SequencedFeedResolver([[firstAddress], [secondAddress]])
        let transport = MockFeedTransport([
            .response(status: 302, data: Data(), headers: ["location": "/canonical.xml"]),
            .response(status: 200, data: fixture("valid-rss.xml")),
        ])
        let client = FeedRetrievalClient(policy: .init(resolver: resolver), transport: transport, now: { self.fixedDate })
        _ = try await client.fetch(subscription(), trace: .init())
        let approvedAddresses = await transport.recordedRequests().map(\.approvedAddress)
        XCTAssertEqual(approvedAddresses, [firstAddress, secondAddress])
    }

    func testPinnedHTTPEncodingKeepsOriginalHostAndBoundedFramingIsDeterministic() throws {
        let target = FeedValidatedTarget(url: sourceURL, approvedAddress: .ipv4(93, 184, 216, 34))
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue("application/rss+xml", forHTTPHeaderField: "Accept")
        let encoded = String(decoding: try PinnedHTTPExchange.encodedRequestForTesting(request, target: target), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("GET /feed.xml HTTP/1.1\r\n"))
        XCTAssertTrue(encoded.contains("\r\nHost: feeds.example.com\r\n"))
        XCTAssertTrue(encoded.contains("\r\nConnection: close\r\n\r\n"))
        XCTAssertFalse(encoded.contains(target.approvedAddress.numericHost))

        let contentLength = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        XCTAssertEqual(try PinnedHTTPExchange.decodedResponseForTesting(contentLength, url: sourceURL, responseLimit: 5)?.data, Data("hello".utf8))

        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try PinnedHTTPExchange.decodedResponseForTesting(chunked, url: sourceURL, responseLimit: 5)?.data, Data("hello".utf8))

        let closeDelimited = Data("HTTP/1.1 200 OK\r\n\r\nhello".utf8)
        XCTAssertNil(try PinnedHTTPExchange.decodedResponseForTesting(closeDelimited, url: sourceURL, responseLimit: 5, endOfStream: false))
        XCTAssertEqual(try PinnedHTTPExchange.decodedResponseForTesting(closeDelimited, url: sourceURL, responseLimit: 5)?.data, Data("hello".utf8))

        let oversized = Data("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello!".utf8)
        XCTAssertThrowsError(try PinnedHTTPExchange.decodedResponseForTesting(oversized, url: sourceURL, responseLimit: 5)) {
            self.assertFailure($0, .responseTooLarge)
        }
        let encodedBody = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello".utf8)
        XCTAssertThrowsError(try PinnedHTTPExchange.decodedResponseForTesting(encodedBody, url: sourceURL, responseLimit: 5)) {
            self.assertFailure($0, .contentEncodingRejected)
        }
    }

    func testRedirectTargetsAreRevalidatedAndRedirectCountIsBounded() async throws {
        let redirectData = Data()
        let privateRedirect = MockFeedTransport([.response(status: 302, data: redirectData, headers: ["location": "https://127.0.0.1/private"])])
        let privateClient = client(transport: privateRedirect)
        do { _ = try await privateClient.fetch(subscription(), trace: .init()); XCTFail("Expected redirect target rejection") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .redirectTargetRejected) }
        let privateRequests = await privateRedirect.recordedRequests()
        XCTAssertEqual(privateRequests.count, 1)

        let redirects = (0...FeedLimits.maximumRedirects).map { index in
            MockFeedTransport.Action.response(status: 302, data: Data(), headers: ["location": "/redirect-\(index)"])
        }
        let limitTransport = MockFeedTransport(redirects)
        let limitClient = client(transport: limitTransport)
        do { _ = try await limitClient.fetch(subscription(), trace: .init()); XCTFail("Expected redirect limit") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .redirectLimitExceeded) }
        let limitRequests = await limitTransport.recordedRequests()
        XCTAssertEqual(limitRequests.count, FeedLimits.maximumRedirects + 1)
    }

    func testScheduledFeedRequestBudgetStopsRedirectBeforeThirdTransportRequest() async throws {
        let transport = MockFeedTransport([
            .response(status: 302, data: Data(), headers: ["location": "/redirect-1"]),
            .response(status: 302, data: Data(), headers: ["location": "/redirect-2"]),
            .response(status: 200, data: fixture("valid-rss.xml"))
        ])
        let budget = ScheduledBriefingBudget(
            maximumTotalDurationSeconds: 30,
            maximumFeedRequests: 2
        )
        let ledger = ScheduledBriefingBudgetLedger(budget: budget)

        do {
            _ = try await client(transport: transport).fetch(subscription(), trace: .init(), budget: ledger)
            XCTFail("Expected the scheduled feed-request budget to stop the redirect chain")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .scheduledRequestBudgetExhausted)
            XCTAssertEqual(failure.reasonCode, ScheduledBriefingBudgetReason.feedRequestsExhausted)
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.compactMap(\.url?.path), ["/feed.xml", "/redirect-1"])
        let usage = await ledger.usage()
        XCTAssertEqual(usage.feedRequestCount, 2)
        XCTAssertEqual(usage.exhaustionReasonCodes, [ScheduledBriefingBudgetReason.feedRequestsExhausted])
    }

    func testScheduledFeedDeadlineClampsTransportResourceTimeout() async throws {
        let transport = MockFeedTransport([
            .response(status: 200, data: fixture("valid-rss.xml"))
        ])
        let budget = ScheduledBriefingBudget(
            maximumTotalDurationSeconds: 1,
            maximumFeedRequests: 1
        )
        let ledger = ScheduledBriefingBudgetLedger(budget: budget)

        _ = try await client(transport: transport).fetch(subscription(), trace: .init(), budget: ledger)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertGreaterThan(request.resourceTimeout, 0)
        XCTAssertLessThanOrEqual(request.resourceTimeout, 1)
        XCTAssertLessThanOrEqual(request.timeout, 1)
    }

    func testScheduledFeedExpiredDurationFailsBeforeTransportWithStableReason() async throws {
        let clock = FeedBudgetUptimeClock(100)
        let transport = MockFeedTransport([
            .response(status: 200, data: fixture("valid-rss.xml"))
        ])
        let budget = ScheduledBriefingBudget(
            maximumTotalDurationSeconds: 1,
            maximumFeedRequests: 1
        )
        let ledger = ScheduledBriefingBudgetLedger(budget: budget, uptime: { clock.now() })
        clock.advance(by: 1)

        do {
            _ = try await client(transport: transport).fetch(subscription(), trace: .init(), budget: ledger)
            XCTFail("Expected the scheduled duration budget to reject the feed request")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .scheduledDurationBudgetExhausted)
            XCTAssertEqual(failure.reasonCode, ScheduledBriefingBudgetReason.durationExhausted)
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        let usage = await ledger.usage()
        XCTAssertEqual(usage.feedRequestCount, 0)
        XCTAssertEqual(usage.exhaustionReasonCodes, [ScheduledBriefingBudgetReason.durationExhausted])
    }

    func testScheduledFeedLateResultCannotReenableRevokedSource() async throws {
        let store = try LocalStore(inMemory: true)
        let original = subscription()
        try store.persistFeedSubscription(original)
        let retriever = ScheduledGatedFeedRetriever()
        let model = try AppModel(store: store, feedClient: retriever)
        let refresher = LiveScheduledSourceRefresher(model: model)
        let plan = try scheduledPlan(feedID: original.id)
        refresher.configure(plan: plan, feedSubscriptions: [original], slackSelectionsByWorkspace: [:])
        let ledger = ScheduledBriefingBudgetLedger(budget: plan.budget)

        let running = Task {
            await refresher.refreshFeed(identifier: original.id, plan: plan, trace: .init(), budget: ledger)
        }
        await retriever.waitUntilStarted()
        model.setFeedEnabled(id: original.id, enabled: false)
        await retriever.complete()
        let outcome = await running.value

        XCTAssertEqual(outcome.status, .skipped)
        XCTAssertEqual(outcome.reasonCodes, ["scheduled_feed_revoked_before_commit"])
        XCTAssertEqual(try store.domainFeedSubscriptions().first?.enabled, false)
    }

    func testScheduledFeedLateResultCannotRecreateRemovedSource() async throws {
        let store = try LocalStore(inMemory: true)
        let original = subscription()
        try store.persistFeedSubscription(original)
        let retriever = ScheduledGatedFeedRetriever()
        let model = try AppModel(store: store, feedClient: retriever)
        let refresher = LiveScheduledSourceRefresher(model: model)
        let plan = try scheduledPlan(feedID: original.id)
        refresher.configure(plan: plan, feedSubscriptions: [original], slackSelectionsByWorkspace: [:])
        let ledger = ScheduledBriefingBudgetLedger(budget: plan.budget)

        let running = Task {
            await refresher.refreshFeed(identifier: original.id, plan: plan, trace: .init(), budget: ledger)
        }
        await retriever.waitUntilStarted()
        model.removeFeed(id: original.id)
        await retriever.complete()
        let outcome = await running.value

        XCTAssertEqual(outcome.status, .skipped)
        XCTAssertEqual(outcome.reasonCodes, ["scheduled_feed_revoked_before_commit"])
        XCTAssertTrue(try store.domainFeedSubscriptions().isEmpty)
        XCTAssertTrue(try store.domainFeedEntries(enabledSubscriptionIDs: [original.id]).isEmpty)
    }

    func testSuccessfulRetrievalUsesGETBoundedHeadersAndCanonicalRedirect() async throws {
        let transport = MockFeedTransport([
            .response(status: 302, data: Data(), headers: ["location": "https://feeds.example.com/canonical.xml"]),
            .response(status: 200, data: fixture("valid-rss.xml"), headers: ["etag": "etag-v2", "last-modified": "Tue, 15 Jul 2025 16:00:00 GMT"])
        ])
        let result = try await client(transport: transport).fetch(subscription(), trace: .init(traceID: "trace", spanID: "root"))
        XCTAssertEqual(result.subscription.canonicalURL.absoluteString, "https://feeds.example.com/canonical.xml")
        XCTAssertEqual(result.subscription.state, .connected)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.record.finalURL, result.subscription.canonicalURL)
        XCTAssertEqual(result.record.responseByteCount, fixture("valid-rss.xml").count)
        XCTAssertEqual(result.subscription.eTag, "etag-v2")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertTrue(requests.allSatisfy {
            $0.body == nil && $0.responseLimit == FeedLimits.maximumResponseBytes &&
            $0.resourceTimeout > 0 && $0.resourceTimeout <= FeedLimits.resourceTimeout
        })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Accept-Encoding"] == "identity" })
        XCTAssertTrue(requests.allSatisfy { request in request.headers.keys.allSatisfy { !["authorization", "proxy-authorization", "cookie"].contains($0.lowercased()) } })
    }

    func testConditionalNotModifiedRefreshPreservesValidatorsAndEntries() async throws {
        var existing = subscription()
        existing.eTag = "etag-v1"
        existing.lastModified = "Mon, 14 Jul 2025 16:00:00 GMT"
        existing.lastSuccessfulAt = fixedDate.addingTimeInterval(-3_600)
        let transport = MockFeedTransport([.response(status: 304, data: Data(), headers: ["etag": "etag-v2"])])
        let result = try await client(transport: transport).fetch(existing, trace: .init())
        XCTAssertTrue(result.record.wasNotModified)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.subscription.eTag, "etag-v2")
        XCTAssertEqual(result.subscription.lastModified, existing.lastModified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.first?.headers["If-None-Match"], "etag-v1")
        XCTAssertEqual(requests.first?.headers["If-Modified-Since"], existing.lastModified)
    }

    func testTimeoutAuthenticationOversizeAndCancellationMapToBoundedFailures() async throws {
        let timeout = client(transport: MockFeedTransport([.urlError(.timedOut)]))
        do { _ = try await timeout.fetch(subscription(), trace: .init()); XCTFail("Expected timeout") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .requestTimedOut) }

        let authentication = client(transport: MockFeedTransport([.response(status: 401, data: Data())]))
        do { _ = try await authentication.fetch(subscription(), trace: .init()); XCTFail("Expected auth rejection") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .authenticationRejected) }

        let oversize = client(transport: MockFeedTransport([.failure(.init(.responseTooLarge))]))
        do { _ = try await oversize.fetch(subscription(), trace: .init()); XCTFail("Expected size rejection") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .responseTooLarge) }

        let cancellationTransport = MockFeedTransport([.waitForCancellation])
        let cancellationClient = client(transport: cancellationTransport)
        let task = Task { try await cancellationClient.fetch(self.subscription(), trace: .init()) }
        await cancellationTransport.waitForRequestCount(1)
        await cancellationClient.cancelAll()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let failure as FeedFetchFailure { XCTAssertEqual(failure.code, .requestCancelled) }
    }

    func testResourceDeadlineCoversDNSAndDiscardsLateResolverCompletion() async throws {
        let resolver = ManuallyCompletedFeedResolver()
        let transport = MockFeedTransport([])
        let recorder = FeedTraceRecorder()
        let client = FeedRetrievalClient(
            policy: .init(resolver: resolver),
            transport: transport,
            now: { self.fixedDate },
            eventSink: { @Sendable event in recorder.record(event) }
        )
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await client.fetch(subscription(resourceTimeout: 0.05), trace: .init(traceID: "dns-timeout", spanID: "root"))
            XCTFail("Expected DNS policy timeout")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .dnsResolutionTimedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        let requestsBeforeLateCompletion = await transport.recordedRequests()
        XCTAssertTrue(requestsBeforeLateCompletion.isEmpty)
        let events = recorder.snapshot()
        XCTAssertTrue(events.contains { $0.event == "feed.url_validation" && $0.status == .failed && $0.reasonCode == FeedFetchFailureCode.dnsResolutionTimedOut.rawValue })
        XCTAssertTrue(events.contains { $0.event == "feed.refresh" && $0.status == .failed && $0.reasonCode == FeedFetchFailureCode.dnsResolutionTimedOut.rawValue })

        await resolver.complete([.ipv4(93, 184, 216, 34)])
        try await Task.sleep(for: .milliseconds(30))
        let requestsAfterLateCompletion = await transport.recordedRequests()
        XCTAssertTrue(requestsAfterLateCompletion.isEmpty, "A resolver result arriving after the deadline must not start network I/O")
    }

    func testCancelAllPromptlyUnblocksPolicyResolverWait() async throws {
        let resolver = ManuallyCompletedFeedResolver()
        let transport = MockFeedTransport([])
        let recorder = FeedTraceRecorder()
        let client = FeedRetrievalClient(
            policy: .init(resolver: resolver),
            transport: transport,
            now: { self.fixedDate },
            eventSink: { @Sendable event in recorder.record(event) }
        )
        let task = Task { try await client.fetch(self.subscription(resourceTimeout: 2), trace: .init(traceID: "dns-cancel", spanID: "root")) }
        await resolver.waitUntilStarted()
        let started = ProcessInfo.processInfo.systemUptime
        await client.cancelAll()
        do {
            _ = try await task.value
            XCTFail("Expected resolver cancellation")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .requestCancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        let events = recorder.snapshot()
        XCTAssertTrue(events.contains { $0.event == "feed.url_validation" && $0.status == .skipped && $0.reasonCode == FeedFetchFailureCode.requestCancelled.rawValue })
        XCTAssertTrue(events.contains { $0.event == "feed.refresh" && $0.status == .skipped && $0.reasonCode == FeedFetchFailureCode.requestCancelled.rawValue })
        await resolver.complete([.ipv4(93, 184, 216, 34)])
    }

    func testCancelAllDuringFetchingProgressCannotStartTransport() async throws {
        let transport = MockFeedTransport([])
        let recorder = FeedTraceRecorder()
        let client = FeedRetrievalClient(
            policy: .init(resolver: publicResolver),
            transport: transport,
            now: { self.fixedDate },
            eventSink: { @Sendable event in recorder.record(event) }
        )
        do {
            _ = try await client.fetch(subscription(), trace: .init(traceID: "progress-cancel", spanID: "root"), progress: { state in
                if state == .fetching { await client.cancelAll() }
            })
            XCTFail("Expected progress-boundary cancellation")
        } catch let failure as FeedFetchFailure {
            XCTAssertEqual(failure.code, .requestCancelled)
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        let events = recorder.snapshot()
        XCTAssertFalse(events.contains { $0.event == "feed.network_request" })
        XCTAssertTrue(events.contains { $0.event == "feed.refresh" && $0.status == .skipped && $0.reasonCode == FeedFetchFailureCode.requestCancelled.rawValue })
    }

    func testRetrievalProgressSequenceIsDeterministic() async throws {
        let progress = FeedProgressRecorder()
        let transport = MockFeedTransport([.response(status: 200, data: fixture("valid-rss.xml"))])
        _ = try await client(transport: transport).fetch(subscription(), trace: .init(), progress: { @Sendable state in
            progress.record(state)
        })
        XCTAssertEqual(progress.snapshot(), [.validating, .fetching, .parsing, .normalizing, .complete])
    }

    func testAppModelExposesAwaitedFeedProgressWithoutLateStateRaces() async throws {
        let retriever = GatedProgressFeedRetriever()
        let model = try AppModel(store: LocalStore(inMemory: true), feedClient: retriever)
        let url = URL(string: "https://feeds.example.com/progress.xml")!
        let subscriptionID = FeedSubscription.stableIdentifier(for: url)
        let addTask = Task {
            await model.addFeed(urlText: url.absoluteString, title: "Progress Feed", saveWhenUnavailable: false)
        }

        for state in [FeedRefreshState.validating, .fetching, .parsing, .normalizing] {
            await retriever.waitUntilReached(state)
            XCTAssertEqual(model.refreshState, state)
            XCTAssertEqual(model.sourceRefreshStates[subscriptionID], state)
            await retriever.release(state)
        }
        let didAddFeed = await addTask.value
        XCTAssertTrue(didAddFeed)
        XCTAssertEqual(model.refreshState, .complete)
        XCTAssertEqual(model.sourceRefreshStates[subscriptionID], .complete)
    }

    func testAppModelCancellationMarksOnlyActiveSourceAndPreservesLastBrief() async throws {
        let retriever = GatedProgressFeedRetriever()
        let model = try AppModel(store: LocalStore(inMemory: true), feedClient: retriever)
        let url = URL(string: "https://feeds.example.com/cancel-progress.xml")!
        let subscriptionID = FeedSubscription.stableIdentifier(for: url)
        let addTask = Task {
            await model.addFeed(urlText: url.absoluteString, title: "Cancelable Feed", saveWhenUnavailable: false)
        }
        for state in [FeedRefreshState.validating, .fetching, .parsing, .normalizing] {
            await retriever.waitUntilReached(state)
            await retriever.release(state)
        }
        let didAddFeed = await addTask.value
        XCTAssertTrue(didAddFeed)

        let inactiveURL = URL(string: "https://feeds.example.com/inactive-progress.xml")!
        let inactiveSubscriptionID = FeedSubscription.stableIdentifier(for: inactiveURL)
        let inactiveAddTask = Task {
            await model.addFeed(urlText: inactiveURL.absoluteString, title: "Inactive Feed", saveWhenUnavailable: false)
        }
        for state in [FeedRefreshState.validating, .fetching, .parsing, .normalizing] {
            await retriever.waitUntilReached(state)
            await retriever.release(state)
        }
        let didAddInactiveFeed = await inactiveAddTask.value
        XCTAssertTrue(didAddInactiveFeed)
        let preservedBrief = model.brief

        model.refreshFeed(id: subscriptionID)
        await retriever.waitUntilReached(.validating)
        await retriever.release(.validating)
        await retriever.waitUntilReached(.fetching)
        XCTAssertEqual(model.sourceRefreshStates[subscriptionID], .fetching)
        await retriever.setHoldCancellationCleanup(true)
        model.cancelRefresh()
        XCTAssertEqual(model.refreshState, .cancelled)
        XCTAssertEqual(model.sourceRefreshStates[subscriptionID], .cancelled)
        XCTAssertEqual(model.sourceRefreshStates[inactiveSubscriptionID], .complete)
        let didStartDuringCleanup = await model.addFeed(
            urlText: "https://feeds.example.com/must-wait-for-cancel.xml",
            title: "Must Wait",
            saveWhenUnavailable: false
        )
        XCTAssertFalse(didStartDuringCleanup)
        await retriever.releaseCancellationCleanup()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.refreshState, .cancelled)
        XCTAssertEqual(model.sourceRefreshStates[subscriptionID], .cancelled)
        XCTAssertEqual(model.sourceRefreshStates[inactiveSubscriptionID], .complete)
        XCTAssertEqual(model.brief, preservedBrief)
    }

    func testStructuredFeedTracesExposeTraversalWithoutPayloadsOrURLs() async throws {
        let marker = "PRIVATE_FEED_PAYLOAD_MARKER_9471"
        let xml = Data("<rss version=\"2.0\"><channel><title>Fixture</title><item><guid>x</guid><title>Title</title><description>\(marker)</description></item></channel></rss>".utf8)
        let recorder = FeedTraceRecorder()
        let transport = MockFeedTransport([.response(status: 200, data: xml)])
        let fixedDate = self.fixedDate
        let tracedClient = FeedRetrievalClient(policy: .init(resolver: publicResolver), transport: transport, now: { fixedDate }, eventSink: { @Sendable event in recorder.record(event) })
        _ = try await tracedClient.fetch(subscription(), trace: .init(traceID: "trace-root", spanID: "span-root"))
        let events = recorder.snapshot()
        XCTAssertTrue(events.contains { $0.event == "feed.url_validation" && $0.status == .success })
        XCTAssertTrue(events.contains { $0.event == "feed.network_request" && $0.status == .started })
        XCTAssertTrue(events.contains { $0.event == "feed.parse" && $0.status == .success })
        XCTAssertTrue(events.contains { $0.event == "feed.normalize" && $0.status == .success })
        XCTAssertTrue(events.contains { $0.event == "feed.refresh" && $0.status == .success })
        XCTAssertTrue(events.allSatisfy { !$0.traceID.isEmpty && !$0.spanID.isEmpty && !$0.reasonCode.isEmpty && $0.component == "feed_retrieval" })
        XCTAssertTrue(events.filter { $0.event != "feed.refresh" }.contains { $0.parentSpanID == "span-root" })
        let encoded = String(data: try JSONEncoder().encode(events), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(marker))
        XCTAssertFalse(encoded.contains(sourceURL.absoluteString))
    }

    func testAddFeedFlowPersistsOnlyValidatedSuccessOrExplicitUnavailableState() async throws {
        let successStore = try LocalStore(inMemory: true)
        let successModel = try AppModel(store: successStore, feedClient: AddFeedRetriever(.success))
        let didAddAvailableFeed = await successModel.addFeed(urlText: "https://feeds.example.com/add.xml#fragment", title: "Added Feed", saveWhenUnavailable: false)
        XCTAssertTrue(didAddAvailableFeed)
        XCTAssertEqual(successModel.subscriptions.count, 1)
        XCTAssertEqual(successModel.subscriptions.first?.state, .connected)
        XCTAssertEqual(successModel.brief.sections.flatMap(\.items).map(\.id), ["add-flow-entry"])

        let unavailableStore = try LocalStore(inMemory: true)
        let unavailableModel = try AppModel(store: unavailableStore, feedClient: AddFeedRetriever(.failure(.init(.networkUnavailable))))
        let didSaveUnavailableFeed = await unavailableModel.addFeed(urlText: "https://feeds.example.com/offline.xml", title: String(repeating: "x", count: FeedLimits.maximumTitleCharacters + 20), saveWhenUnavailable: true)
        XCTAssertTrue(didSaveUnavailableFeed)
        XCTAssertEqual(unavailableModel.subscriptions.first?.state, .savedUnavailable)
        XCTAssertEqual(unavailableModel.subscriptions.first?.failure?.code, .networkUnavailable)
        XCTAssertEqual(unavailableModel.subscriptions.first?.title.count, FeedLimits.maximumTitleCharacters)

        let failuresThatMustNotBeSaved: [FeedFetchFailureCode] = [
            .dnsResolutionFailed,
            .dnsResolutionTimedOut,
            .authenticationRejected,
            .requestCancelled,
            .responseTooLarge,
            .contentEncodingRejected,
            .unsupportedFormat,
            .malformedXML
        ]
        for failureCode in failuresThatMustNotBeSaved {
            let store = try LocalStore(inMemory: true)
            let model = try AppModel(store: store, feedClient: AddFeedRetriever(.failure(.init(failureCode))))
            let didSave = await model.addFeed(
                urlText: "https://feeds.example.com/not-saveable.xml",
                title: String(repeating: "x", count: FeedLimits.maximumTitleCharacters + 20),
                saveWhenUnavailable: true
            )
            XCTAssertFalse(didSave, "Unexpectedly saved failure \(failureCode.rawValue)")
            XCTAssertTrue(model.subscriptions.isEmpty)
        }

        let oversizedURL = "https://feeds.example.com/" + String(repeating: "x", count: FeedLimits.maximumURLCharacters)
        let oversizedURLModel = try AppModel(store: LocalStore(inMemory: true), feedClient: AddFeedRetriever(.success))
        let didSaveOversizedURL = await oversizedURLModel.addFeed(urlText: oversizedURL, title: "Too long", saveWhenUnavailable: true)
        XCTAssertFalse(didSaveOversizedURL)
        XCTAssertTrue(oversizedURLModel.subscriptions.isEmpty)

        let prohibitedStore = try LocalStore(inMemory: true)
        let noNetwork = MockFeedTransport([])
        let prohibitedClient = FeedRetrievalClient(policy: .init(resolver: publicResolver), transport: noNetwork)
        let prohibitedModel = try AppModel(store: prohibitedStore, feedClient: prohibitedClient)
        let didSaveProhibitedFeed = await prohibitedModel.addFeed(urlText: "http://127.0.0.1/private", title: "Forbidden", saveWhenUnavailable: true)
        XCTAssertFalse(didSaveProhibitedFeed)
        XCTAssertTrue(prohibitedModel.subscriptions.isEmpty)
        let prohibitedRequests = await noNetwork.recordedRequests()
        XCTAssertTrue(prohibitedRequests.isEmpty)
    }

    func testCanonicalSubscriptionIdentifierIsStableAcrossEquivalentURLSpellings() {
        let first = URL(string: "https://EXAMPLE.com:443/feed#one")!
        let second = URL(string: "https://example.com/feed#two")!
        XCTAssertEqual(FeedSubscription.stableIdentifier(for: first), FeedSubscription.stableIdentifier(for: second))
        XCTAssertEqual(FeedSubscription.syntacticallyCanonicalURL(first)?.absoluteString, "https://example.com/feed")
    }

    private func client(transport: MockFeedTransport) -> FeedRetrievalClient {
        let now = fixedDate
        return FeedRetrievalClient(policy: .init(resolver: publicResolver), transport: transport, now: { now })
    }

    private func subscription(id: String? = nil, resourceTimeout: TimeInterval = FeedLimits.resourceTimeout) -> FeedSubscription {
        let policy = FeedFetchPolicy(
            requestTimeout: min(FeedLimits.requestTimeout, resourceTimeout),
            resourceTimeout: resourceTimeout,
            maximumRedirects: FeedLimits.maximumRedirects,
            maximumResponseBytes: FeedLimits.maximumResponseBytes,
            maximumRetainedEntries: FeedLimits.maximumRetainedEntriesPerFeed,
            retentionDays: FeedLimits.defaultRetentionDays
        )
        return .init(
            id: id ?? FeedSubscription.stableIdentifier(for: sourceURL),
            title: "Synthetic Feed",
            canonicalURL: sourceURL,
            enabled: true,
            format: .unknown,
            lastAttemptedAt: nil,
            lastSuccessfulAt: nil,
            lastHTTPStatus: nil,
            eTag: nil,
            lastModified: nil,
            state: .savedUnavailable,
            failure: nil,
            policy: policy,
            weight: 1,
            createdAt: fixedDate.addingTimeInterval(-86_400),
            updatedAt: fixedDate.addingTimeInterval(-86_400)
        )
    }

    private func scheduledPlan(feedID: String) throws -> ScheduledBriefingPlan {
        try .init(
            id: "scheduled-feed-revocation-run",
            occurrenceID: "scheduled-feed-revocation-occurrence",
            scheduledFor: fixedDate,
            trigger: .scheduled,
            feedSubscriptionIDs: [feedID],
            slackWorkspaceIDs: [],
            refreshFeedsEnabled: true,
            refreshSlackEnabled: false,
            slackSelections: [],
            localPresentationEnabled: false,
            localPresentationConsentedWorkspaceIDs: [],
            notificationsEnabled: false,
            notificationAuthorization: .notDetermined,
            notificationPrivacyMode: .minimal,
            entitlementDecisions: [],
            budget: .init(maximumFeedSources: 1, maximumFeedRequests: 1)
        )
    }

    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try! Data(contentsOf: url)
    }

    private func assertFailure(_ error: Error, _ expected: FeedFetchFailureCode, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? FeedFetchFailure else { return XCTFail("Expected FeedFetchFailure, got \(error)", file: file, line: line) }
        XCTAssertEqual(failure.code, expected, file: file, line: line)
    }
}
