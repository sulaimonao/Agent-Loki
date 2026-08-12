import Foundation
import XCTest
@testable import LokiBrief

private final class AuthorizationTraceRecorder: @unchecked Sendable {
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

private final class DeterministicSlackRandom: SlackSecureRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func bytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { throw SlackPKCEFailure(code: .randomGenerationFailed) }
        return values.removeFirst()
    }
}

private actor RejectingSlackOAuthTransport: SlackOAuthTransporting {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> SlackOAuthHTTPResponse {
        requestCount += 1
        throw SlackOAuthFailure(code: .transportFailure)
    }
}

@MainActor
private final class ControlledSlackBrowserSession: SlackWebAuthenticationSessioning {
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func authenticate(
        authorizationURL: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        startCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: SlackBrowserSessionFailure(code: .cancelled))
    }
}

final class SlackPKCEAuthorizationTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    func testSystemPKCEUsesThirtyTwoIndependentBytesAndURLSafeShape() throws {
        let first = try SlackPKCEGenerator().generate()
        let second = try SlackPKCEGenerator().generate()

        for material in [first, second] {
            XCTAssertEqual(material.verifier.count, 43)
            XCTAssertEqual(material.challenge.count, 43)
            XCTAssertEqual(material.state.count, 43)
            XCTAssertTrue(material.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
            XCTAssertTrue(material.challenge.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) })
            XCTAssertTrue(material.state.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) })
            XCTAssertFalse(material.verifier.contains("="))
            XCTAssertFalse(material.state.contains("="))
        }
        XCTAssertNotEqual(first.verifier, first.state)
        XCTAssertNotEqual(first.state, second.state)
    }

    func testS256MatchesRFC7636Vector() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            try SlackPKCEGenerator.s256Challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testDeterministicGeneratorUsesSeparateVerifierAndStateDraws() throws {
        let verifierBytes = Data((0..<32).map(UInt8.init))
        let stateBytes = Data((32..<64).map(UInt8.init))
        let material = try SlackPKCEGenerator(
            random: DeterministicSlackRandom([verifierBytes, stateBytes])
        ).generate()

        XCTAssertEqual(material.verifier, SlackPKCEGenerator.base64URLEncoded(verifierBytes))
        XCTAssertEqual(material.state, SlackPKCEGenerator.base64URLEncoded(stateBytes))
        XCTAssertNotEqual(material.verifier, material.state)
    }

    func testExactCallbackIsAcceptedOnlyAfterStateMatches() async throws {
        let coordinator = Self.coordinator()
        let attempt = try await coordinator.begin(at: Self.anchor)
        let result = try await coordinator.accept(
            Self.callback(code: "sensitive-code", state: attempt.material.state),
            at: Self.anchor.addingTimeInterval(1)
        )
        XCTAssertEqual(result, .authorized(code: "sensitive-code"))
    }

    func testCallbackValidationEmitsLinkedSecretFreeSuccessAndFailureTraces() async throws {
        let recorder = AuthorizationTraceRecorder()
        let trace = SlackTraceContext(
            traceID: "trace-callback",
            spanID: "span-callback",
            parentSpanID: "span-authorization"
        )

        var coordinator = Self.coordinator(eventSink: { event in recorder.append(event) })
        var attempt = try await coordinator.begin(at: Self.anchor)
        _ = try await coordinator.accept(
            Self.callback(code: "authorization-code-private", state: attempt.material.state),
            at: Self.anchor,
            trace: trace
        )

        coordinator = Self.coordinator(eventSink: { event in recorder.append(event) })
        attempt = try await coordinator.begin(at: Self.anchor)
        await Self.assertAuthorizationFailure(.stateMismatch) {
            try await coordinator.accept(
                Self.callback(code: "other-code-private", state: "wrong-state-private"),
                at: Self.anchor,
                trace: trace
            )
        }

        let events = recorder.events()
        XCTAssertEqual(events.map(\.event), Array(repeating: .callbackValidation, count: 4))
        XCTAssertEqual(events.map(\.status), [.started, .success, .started, .failed])
        XCTAssertEqual(events.last?.reasonCode, SlackAuthorizationFailureCode.stateMismatch.rawValue)
        XCTAssertTrue(events.allSatisfy { event in
            event.traceID == trace.traceID
                && event.spanID == trace.spanID
                && event.parentSpanID == trace.parentSpanID
                && event.component == "slack_authorization_attempt_coordinator"
                && event.ts == Self.anchor
        })

        let rendered = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [
            "authorization-code-private",
            "other-code-private",
            "wrong-state-private",
            attempt.material.state,
            attempt.material.verifier
        ] {
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testCallbackRejectsLegacySchemeHostAndPathVariants() async throws {
        let variants = [
            "com.agentloki.lokibrief:/oauth/slack?code=x&state=state",
            "loki-brief://oauth/slack?code=x&state=state",
            "com.agentloki.lokibrief://other/slack?code=x&state=state",
            "com.agentloki.lokibrief://oauth/other?code=x&state=state"
        ]
        for value in variants {
            let coordinator = Self.coordinator()
            _ = try await coordinator.begin(at: Self.anchor)
            await Self.assertAuthorizationFailure(.callbackMismatch) {
                try await coordinator.accept(try XCTUnwrap(URL(string: value)), at: Self.anchor)
            }
        }
    }

    func testMissingAndWrongStateTerminateAttemptWithoutInspectingCode() async throws {
        var coordinator = Self.coordinator()
        _ = try await coordinator.begin(at: Self.anchor)
        await Self.assertAuthorizationFailure(.missingState) {
            try await coordinator.accept(try XCTUnwrap(URL(string: "\(SlackOAuthCallbackContract.redirectURI)?code=secret")), at: Self.anchor)
        }

        coordinator = Self.coordinator()
        _ = try await coordinator.begin(at: Self.anchor)
        await Self.assertAuthorizationFailure(.stateMismatch) {
            try await coordinator.accept(Self.callback(code: "secret", state: "wrong-state"), at: Self.anchor)
        }
    }

    func testDuplicateCallbackIsRejectedAfterOneConsumption() async throws {
        let coordinator = Self.coordinator()
        let attempt = try await coordinator.begin(at: Self.anchor)
        let callback = Self.callback(code: "secret", state: attempt.material.state)
        _ = try await coordinator.accept(callback, at: Self.anchor)

        await Self.assertAuthorizationFailure(.duplicateCallback) {
            try await coordinator.accept(callback, at: Self.anchor)
        }
    }

    func testCallbackAfterCancellationAndExpiryIsLate() async throws {
        var coordinator = Self.coordinator()
        var attempt = try await coordinator.begin(at: Self.anchor)
        _ = try await coordinator.cancel(attempt.id)
        await Self.assertAuthorizationFailure(.lateCallback) {
            try await coordinator.accept(Self.callback(code: "secret", state: attempt.material.state), at: Self.anchor)
        }

        coordinator = Self.coordinator(lifetime: 5)
        attempt = try await coordinator.begin(at: Self.anchor)
        let callback = Self.callback(code: "secret", state: attempt.material.state)
        await Self.assertAuthorizationFailure(.attemptExpired) {
            try await coordinator.accept(callback, at: Self.anchor.addingTimeInterval(6))
        }
        await Self.assertAuthorizationFailure(.lateCallback) {
            try await coordinator.accept(callback, at: Self.anchor.addingTimeInterval(7))
        }
    }

    func testOverlappingAuthorizationAttemptIsRejected() async throws {
        let coordinator = Self.coordinator()
        _ = try await coordinator.begin(at: Self.anchor)
        await Self.assertAuthorizationFailure(.attemptAlreadyActive) {
            try await coordinator.begin(at: Self.anchor)
        }
    }

    func testAuthorizationDenialConsumesAttemptWithoutRetainingState() async throws {
        let coordinator = Self.coordinator()
        let attempt = try await coordinator.begin(at: Self.anchor)
        var components = URLComponents(string: SlackOAuthCallbackContract.redirectURI)!
        components.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "state", value: attempt.material.state)
        ]
        await Self.assertAuthorizationFailure(.authorizationDenied) {
            try await coordinator.accept(try XCTUnwrap(components.url), at: Self.anchor)
        }
        let activeAttemptID = await coordinator.activeAttemptID()
        XCTAssertNil(activeAttemptID)
    }

    func testExplicitAuthorizationCancellationCancelsBrowserAndSkipsExchange() async throws {
        let browser = await MainActor.run { ControlledSlackBrowserSession() }
        let transport = RejectingSlackOAuthTransport()
        let oauthClient = try SlackOAuthClient(clientID: "123456.789012", transport: transport)
        let service = SlackAuthorizationService(browser: browser, oauthClient: oauthClient, now: { Self.anchor })

        let authorization = Task { try await service.authorize() }
        for _ in 0..<100 {
            if await MainActor.run(body: { browser.startCount > 0 }) { break }
            await Task.yield()
        }
        await service.cancelActiveAuthorization()

        do {
            _ = try await authorization.value
            XCTFail("Expected browser-session cancellation.")
        } catch let failure as SlackBrowserSessionFailure {
            XCTAssertEqual(failure.code, .cancelled)
        }
        let cancelCount = await MainActor.run { browser.cancelCount }
        let requestCount = await transport.requestCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testSystemBrowserRejectsNonSlackURLAndWrongSchemeBeforePresentation() async throws {
        let browser = SystemSlackWebAuthenticationSession(presentationAnchorProvider: { nil })
        do {
            _ = try await browser.authenticate(
                authorizationURL: try XCTUnwrap(URL(string: "https://example.com/oauth/v2/authorize")),
                callbackScheme: SlackOAuthCallbackContract.scheme,
                prefersEphemeralSession: false
            )
            XCTFail("Expected the non-Slack URL to be rejected.")
        } catch let failure as SlackBrowserSessionFailure {
            XCTAssertEqual(failure.code, .invalidAuthorizationURL)
        }

        do {
            _ = try await browser.authenticate(
                authorizationURL: SlackOAuthClient.authorizationEndpoint,
                callbackScheme: "loki-brief",
                prefersEphemeralSession: false
            )
            XCTFail("Expected the callback scheme to be rejected.")
        } catch let failure as SlackBrowserSessionFailure {
            XCTAssertEqual(failure.code, .invalidCallbackScheme)
        }
    }

    private static func coordinator(
        lifetime: TimeInterval = 600,
        eventSink: SlackAuthorizationAttemptCoordinator.TraceSink? = nil
    ) -> SlackAuthorizationAttemptCoordinator {
        let bytes = [Data(repeating: 0x11, count: 32), Data(repeating: 0x22, count: 32)]
        return SlackAuthorizationAttemptCoordinator(
            generator: SlackPKCEGenerator(random: DeterministicSlackRandom(bytes)),
            lifetime: lifetime,
            eventSink: eventSink
        )
    }

    private static func callback(code: String, state: String) -> URL {
        var components = URLComponents(string: SlackOAuthCallbackContract.redirectURI)!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    private static func assertAuthorizationFailure<T>(
        _ expected: SlackAuthorizationFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected authorization failure \(expected.rawValue).")
        } catch let failure as SlackAuthorizationFailure {
            XCTAssertEqual(failure.code, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}
