import Foundation
import XCTest
@testable import LokiBrief

private actor MockSlackRevocationTransport: SlackRevocationTransporting {
    enum Action: Sendable {
        case response(SlackRevocationHTTPResponse)
        case cancellation
        case timeout
    }

    private let action: Action
    private var requests: [URLRequest] = []

    init(_ action: Action) { self.action = action }

    func data(for request: URLRequest) async throws -> SlackRevocationHTTPResponse {
        requests.append(request)
        switch action {
        case let .response(response): return response
        case .cancellation: throw CancellationError()
        case .timeout: throw URLError(.timedOut)
        }
    }

    func request(at index: Int) -> URLRequest { requests[index] }
    func requestCount() -> Int { requests.count }
}

private actor AdapterCredentialStore: SlackCredentialStoring {
    private var credential: SlackOAuthCredential?

    init(_ credential: SlackOAuthCredential?) { self.credential = credential }

    func create(_ credential: SlackOAuthCredential) async throws { self.credential = credential }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        guard let credential, credential.teamID == teamID, credential.userID == userID else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        guard self.credential != nil else { throw SlackCredentialStoreFailure(code: .notFound) }
        self.credential = credential
    }

    func delete(teamID: String, userID: String) async throws { credential = nil }
}

private actor AdapterOAuthTransport: SlackOAuthTransporting {
    private let response: SlackOAuthHTTPResponse
    private(set) var count = 0

    init(_ response: SlackOAuthHTTPResponse) { self.response = response }

    func data(for request: URLRequest) async throws -> SlackOAuthHTTPResponse {
        count += 1
        return response
    }
}

final class SlackRevocationClientTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    func testRevocationUsesFixedPostEndpointAndBearerOnly() async throws {
        let transport = MockSlackRevocationTransport(.response(Self.response(["ok": true, "revoked": true])))
        let result = try await SlackRevocationClient(transport: transport).revoke(accessToken: "access-sentinel")
        XCTAssertTrue(result.remoteConfirmed)

        let request = await transport.request(at: 0)
        XCTAssertEqual(request.url, SlackRevocationClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-sentinel")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(request.value(forHTTPHeaderField: "client_secret"))
        XCTAssertTrue(SlackRevocationClient.isAllowed(request))
    }

    func testRevocationPolicyRejectsQueryBodyWrongHostAndSecretHeader() throws {
        var query = URLRequest(url: try XCTUnwrap(URL(string: "https://slack.com/api/auth.revoke?token=value")))
        query.httpMethod = "POST"
        query.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(SlackRevocationClient.isAllowed(query))

        var body = URLRequest(url: SlackRevocationClient.endpoint)
        body.httpMethod = "POST"
        body.httpBody = Data("client_secret=forbidden".utf8)
        body.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(SlackRevocationClient.isAllowed(body))

        var wrongHost = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/auth.revoke")))
        wrongHost.httpMethod = "POST"
        wrongHost.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(SlackRevocationClient.isAllowed(wrongHost))

        var secretHeader = URLRequest(url: SlackRevocationClient.endpoint)
        secretHeader.httpMethod = "POST"
        secretHeader.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        secretHeader.setValue("forbidden", forHTTPHeaderField: "client_secret")
        XCTAssertFalse(SlackRevocationClient.isAllowed(secretHeader))
    }

    func testRevocationRejectsRedirectOversizeContentTypeAndMalformedSchema() async {
        let fixtures: [(SlackRevocationHTTPResponse, SlackRevocationFailureCode)] = [
            (Self.response(["ok": true, "revoked": true], status: 302), .redirectRejected),
            (Self.response(["ok": true, "revoked": true], url: URL(string: "https://example.com/redirect")!), .redirectRejected),
            (.init(data: Data(repeating: 0x41, count: SlackRevocationClient.maximumResponseBytes + 1), statusCode: 200, finalURL: SlackRevocationClient.endpoint, contentType: "application/json"), .responseTooLarge),
            (.init(data: Data("{}".utf8), statusCode: 200, finalURL: SlackRevocationClient.endpoint, contentType: "text/html"), .invalidContentType),
            (.init(data: Data("not-json".utf8), statusCode: 200, finalURL: SlackRevocationClient.endpoint, contentType: "application/json"), .malformedResponse),
            (Self.deeplyNestedResponse(depth: SlackRevocationClient.maximumJSONDepth + 2), .jsonDepthExceeded),
            (Self.response(["ok": true, "revoked": false]), .revocationNotConfirmed),
            (Self.response(["ok": false, "error": "invalid_auth"]), .slackRejected)
        ]

        for (response, expected) in fixtures {
            await Self.assertFailure(expected) {
                try await SlackRevocationClient(
                    transport: MockSlackRevocationTransport(.response(response))
                ).revoke(accessToken: "access-sentinel")
            }
        }
    }

    func testRevocationMapsCancellationAndTimeoutWithoutLeakingToken() async {
        await Self.assertFailure(.cancelled) {
            try await SlackRevocationClient(
                transport: MockSlackRevocationTransport(.cancellation)
            ).revoke(accessToken: "access-sentinel-private")
        }
        await Self.assertFailure(.timedOut) {
            try await SlackRevocationClient(
                transport: MockSlackRevocationTransport(.timeout)
            ).revoke(accessToken: "access-sentinel-private")
        }
        for code in SlackRevocationFailureCode.allTestCases {
            let rendered = SlackRevocationFailure(code: code).errorDescription ?? ""
            XCTAssertFalse(rendered.contains("access-sentinel-private"))
        }
    }

    func testCredentialAccessTokenAdapterLoadsCurrentTokenWithoutRefresh() async throws {
        let credential = Self.credential(accessExpiresAt: Self.anchor.addingTimeInterval(3_600))
        let store = AdapterCredentialStore(credential)
        let transport = AdapterOAuthTransport(
            .init(
                data: Data(),
                statusCode: 500,
                url: SlackOAuthClient.tokenEndpoint,
                contentType: "application/json"
            )
        )
        let oauth = try SlackOAuthClient(clientID: "123456.789012", transport: transport, now: { Self.anchor })
        let provider = SlackCredentialAccessTokenProvider(
            coordinator: SlackCredentialRefreshCoordinator(
                oauthClient: oauth,
                credentialStore: store,
                now: { Self.anchor }
            )
        )

        let token = try await provider.accessToken(
            teamID: "T123",
            userID: "U123",
            forceRefresh: false,
            trace: .init(traceID: "trace", spanID: "span")
        )
        let requestCount = await transport.count
        XCTAssertEqual(token, "access-current")
        XCTAssertEqual(requestCount, 0)
    }

    func testCredentialAccessTokenAdapterSanitizesRefreshAndMissingStoreFailures() async throws {
        let rejectedData = try JSONSerialization.data(
            withJSONObject: ["ok": false, "error": "invalid_refresh_token"],
            options: [.sortedKeys]
        )
        let transport = AdapterOAuthTransport(
            .init(
                data: rejectedData,
                statusCode: 200,
                url: SlackOAuthClient.tokenEndpoint,
                contentType: "application/json"
            )
        )
        let oauth = try SlackOAuthClient(clientID: "123456.789012", transport: transport, now: { Self.anchor })
        var provider = SlackCredentialAccessTokenProvider(
            coordinator: SlackCredentialRefreshCoordinator(
                oauthClient: oauth,
                credentialStore: AdapterCredentialStore(Self.credential(accessExpiresAt: Self.anchor)),
                now: { Self.anchor }
            )
        )
        await Self.assertAPIFailure(.reauthorizationRequired) {
            try await provider.accessToken(
                teamID: "T123", userID: "U123", forceRefresh: true,
                trace: .init(traceID: "trace", spanID: "span")
            )
        }

        provider = SlackCredentialAccessTokenProvider(
            coordinator: SlackCredentialRefreshCoordinator(
                oauthClient: oauth,
                credentialStore: AdapterCredentialStore(nil),
                now: { Self.anchor }
            )
        )
        await Self.assertAPIFailure(.reauthorizationRequired) {
            try await provider.accessToken(
                teamID: "T123", userID: "U123", forceRefresh: false,
                trace: .init(traceID: "trace", spanID: "span")
            )
        }
    }

    private static func credential(accessExpiresAt: Date) -> SlackOAuthCredential {
        SlackOAuthCredential(
            teamID: "T123",
            userID: "U123",
            accessToken: "access-current",
            refreshToken: "refresh-current",
            tokenType: "user",
            issuedAt: anchor.addingTimeInterval(-60),
            accessTokenExpiresAt: accessExpiresAt,
            refreshTokenExpiresAt: anchor.addingTimeInterval(20 * 24 * 60 * 60),
            grantedScopes: Array(SlackOAuthScopePolicy.requiredUserScopes)
        )
    }

    private static func response(
        _ object: Any,
        status: Int = 200,
        url: URL = SlackRevocationClient.endpoint
    ) -> SlackRevocationHTTPResponse {
        .init(
            data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            statusCode: status,
            finalURL: url,
            contentType: "application/json; charset=utf-8"
        )
    }

    private static func deeplyNestedResponse(depth: Int) -> SlackRevocationHTTPResponse {
        var nested: Any = "leaf"
        for _ in 0..<depth {
            nested = ["next": nested]
        }
        return response(["ok": true, "revoked": true, "unknown_nested_value": nested])
    }

    private static func assertFailure<T>(
        _ expected: SlackRevocationFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected revocation failure \(expected.rawValue).")
        } catch let failure as SlackRevocationFailure {
            XCTAssertEqual(failure.code, expected)
            XCTAssertFalse((failure.errorDescription ?? "").contains("access-sentinel"))
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }

    private static func assertAPIFailure<T>(
        _ expected: SlackAPIErrorCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected Slack API failure \(expected.rawValue).")
        } catch let failure as SlackAPIError {
            XCTAssertEqual(failure.code, expected)
            XCTAssertNil(failure.slackErrorCode)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

private extension SlackRevocationFailureCode {
    static let allTestCases: [SlackRevocationFailureCode] = [
        .invalidAccessToken, .requestRejected, .cancelled, .timedOut, .transportFailure,
        .redirectRejected, .unexpectedHTTPStatus, .responseTooLarge, .invalidContentType,
        .jsonDepthExceeded, .malformedResponse, .slackRejected, .revocationNotConfirmed
    ]
}
