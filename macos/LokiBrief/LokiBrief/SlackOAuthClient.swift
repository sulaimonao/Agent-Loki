import Foundation

enum SlackBoundedBodyFailure: Error, Equatable, Sendable {
    case limitExceeded
}

enum SlackBoundedBodyReader {
    static func read<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int,
        expectedContentLength: Int64 = -1
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes > 0,
              expectedContentLength <= Int64(maximumBytes)
        else { throw SlackBoundedBodyFailure.limitExceeded }

        var data = Data()
        if expectedContentLength > 0 {
            data.reserveCapacity(Int(expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw SlackBoundedBodyFailure.limitExceeded
            }
            data.append(byte)
        }
        return data
    }
}

enum SlackBoundedJSONFailure: Error, Equatable, Sendable {
    case invalidStructure
    case maximumDepthExceeded
}

enum SlackBoundedJSONValidator {
    static func validate(_ data: Data, maximumDepth: Int) throws {
        guard maximumDepth > 0 else { throw SlackBoundedJSONFailure.maximumDepthExceeded }

        var closingDelimiters: [UInt8] = []
        closingDelimiters.reserveCapacity(maximumDepth)
        var isInsideString = false
        var isEscaped = false

        for byte in data {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B:
                guard closingDelimiters.count < maximumDepth else {
                    throw SlackBoundedJSONFailure.maximumDepthExceeded
                }
                closingDelimiters.append(0x7D)
            case 0x5B:
                guard closingDelimiters.count < maximumDepth else {
                    throw SlackBoundedJSONFailure.maximumDepthExceeded
                }
                closingDelimiters.append(0x5D)
            case 0x7D, 0x5D:
                guard closingDelimiters.popLast() == byte else {
                    throw SlackBoundedJSONFailure.invalidStructure
                }
            default:
                break
            }
        }

        guard !isInsideString, !isEscaped, closingDelimiters.isEmpty else {
            throw SlackBoundedJSONFailure.invalidStructure
        }
    }
}

enum SlackJSONMediaType {
    static func isJSON(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let mediaType = rawValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }
}

enum SlackOAuthScopePolicy {
    static let requiredUserScopes: Set<String> = [
        "channels:history",
        "channels:read",
        "groups:history",
        "groups:read",
        "users:read"
    ]

    static let forbiddenUserScopes: Set<String> = [
        "im:read",
        "im:history",
        "mpim:read",
        "mpim:history",
        "files:read",
        "search:read",
        "reactions:read",
        "users:read.email",
        "chat:write"
    ]
}

enum SlackOAuthFailureCode: String, Codable, Sendable {
    case invalidClientID = "slack_oauth_client_id_invalid"
    case invalidAuthorizationCode = "slack_oauth_authorization_code_invalid"
    case invalidCodeVerifier = "slack_oauth_code_verifier_invalid"
    case invalidAuthorizationRequest = "slack_oauth_authorization_request_invalid"
    case requestRejected = "slack_oauth_request_rejected"
    case transportFailure = "slack_oauth_transport_failed"
    case timeout = "slack_oauth_transport_timed_out"
    case cancelled = "slack_oauth_request_cancelled"
    case unexpectedHTTPStatus = "slack_oauth_http_status_unexpected"
    case responseTooLarge = "slack_oauth_response_too_large"
    case invalidContentType = "slack_oauth_content_type_invalid"
    case jsonDepthExceeded = "slack_oauth_json_depth_exceeded"
    case malformedResponse = "slack_oauth_response_malformed"
    case slackRejected = "slack_oauth_slack_rejected"
    case missingAccessToken = "slack_oauth_access_token_missing"
    case missingRefreshToken = "slack_oauth_refresh_token_missing"
    case invalidExpiration = "slack_oauth_expiration_invalid"
    case tokenTypeMismatch = "slack_oauth_token_type_mismatch"
    case scopeMismatch = "slack_oauth_scope_mismatch"
    case missingTeamIdentity = "slack_oauth_team_identity_missing"
    case missingUserIdentity = "slack_oauth_user_identity_missing"
    case refreshTokenInvalid = "slack_oauth_refresh_token_invalid"
    case refreshTokenExpired = "slack_oauth_refresh_token_expired"
    case accessTokenRevoked = "slack_oauth_access_token_revoked"
    case workspaceDeactivated = "slack_oauth_workspace_deactivated"
}

struct SlackOAuthFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackOAuthFailureCode
    let httpStatus: Int?

    init(code: SlackOAuthFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }

    var requiresReauthorization: Bool {
        switch code {
        case .refreshTokenInvalid, .refreshTokenExpired, .accessTokenRevoked, .workspaceDeactivated:
            true
        default:
            false
        }
    }

    var errorDescription: String? {
        switch code {
        case .invalidClientID: "The Slack client ID is invalid."
        case .invalidAuthorizationCode: "The Slack authorization code is invalid."
        case .invalidCodeVerifier: "The Slack PKCE verifier is invalid."
        case .invalidAuthorizationRequest: "The Slack authorization request is invalid."
        case .requestRejected: "The Slack token request violated the public-client contract."
        case .transportFailure: "The Slack token endpoint could not be reached."
        case .timeout: "The Slack token request timed out."
        case .cancelled: "The Slack token request was cancelled."
        case .unexpectedHTTPStatus: "The Slack token endpoint returned an unexpected status."
        case .responseTooLarge: "The Slack token response exceeded its size bound."
        case .invalidContentType: "The Slack token response was not JSON."
        case .jsonDepthExceeded: "The Slack token response exceeded its JSON nesting bound."
        case .malformedResponse: "The Slack token response was malformed."
        case .slackRejected: "Slack rejected the token request."
        case .missingAccessToken: "The Slack token response omitted the access token."
        case .missingRefreshToken: "The Slack token response omitted the rotating refresh token."
        case .invalidExpiration: "The Slack token response contained an invalid expiration."
        case .tokenTypeMismatch: "The Slack token response was not a user-token response."
        case .scopeMismatch: "The Slack scope set did not exactly match the required read-only policy."
        case .missingTeamIdentity: "The Slack token response omitted the workspace identity."
        case .missingUserIdentity: "The Slack token response omitted the user identity."
        case .refreshTokenInvalid: "The Slack refresh token is invalid and reauthorization is required."
        case .refreshTokenExpired: "The Slack refresh token expired and reauthorization is required."
        case .accessTokenRevoked: "The Slack credential was revoked and reauthorization is required."
        case .workspaceDeactivated: "The Slack workspace or user is inactive."
        }
    }
}

struct SlackOAuthHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL?
    let contentType: String?
}

protocol SlackOAuthTransporting: Sendable {
    func data(for request: URLRequest) async throws -> SlackOAuthHTTPResponse
}

final class SlackOAuthURLSessionTransport: NSObject, SlackOAuthTransporting, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private static let tokenEndpoint = URL(string: "https://slack.com/api/oauth.v2.access")!
    private static let maximumRequestBytes = 16 * 1_024
    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> SlackOAuthHTTPResponse {
        guard Self.isAllowed(request) else { throw SlackOAuthFailure(code: .requestRejected) }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SlackOAuthFailure(code: .transportFailure)
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        guard httpResponse.statusCode == 200, httpResponse.url == Self.tokenEndpoint else {
            return SlackOAuthHTTPResponse(
                data: Data(),
                statusCode: httpResponse.statusCode,
                url: httpResponse.url,
                contentType: contentType
            )
        }
        guard SlackJSONMediaType.isJSON(contentType) else {
            throw SlackOAuthFailure(code: .invalidContentType)
        }

        let data: Data
        do {
            data = try await SlackBoundedBodyReader.read(
                bytes,
                maximumBytes: SlackOAuthClient.maximumResponseBytes,
                expectedContentLength: httpResponse.expectedContentLength
            )
        } catch let failure as SlackBoundedBodyFailure where failure == .limitExceeded {
            throw SlackOAuthFailure(code: .responseTooLarge)
        }
        return SlackOAuthHTTPResponse(
            data: data,
            statusCode: httpResponse.statusCode,
            url: httpResponse.url,
            contentType: contentType
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func isAllowed(_ request: URLRequest) -> Bool {
        guard request.url == tokenEndpoint,
              request.httpMethod == "POST",
              request.url?.query == nil,
              request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              let body = request.httpBody,
              (1...maximumRequestBytes).contains(body.count),
              let form = String(data: body, encoding: .utf8)
        else { return false }

        let allowedFields = Set(["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "refresh_token"])
        let fields = form.split(separator: "&", omittingEmptySubsequences: false).compactMap { pair -> String? in
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            return String(pair[..<separator]).removingPercentEncoding
        }
        return fields.count == form.split(separator: "&", omittingEmptySubsequences: false).count
            && Set(fields).isSubset(of: allowedFields)
            && !fields.contains("client_secret")
    }
}

struct SlackOAuthClient: Sendable {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    static let authorizationEndpoint = URL(string: "https://slack.com/oauth/v2/authorize")!
    static let tokenEndpoint = URL(string: "https://slack.com/api/oauth.v2.access")!
    static let maximumResponseBytes = 256 * 1_024
    static let maximumJSONDepth = 12
    static let maximumExpirationSeconds = 90 * 24 * 60 * 60
    static let rotatingRefreshLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let clientID: String
    private let requiredScopes: Set<String>
    private let transport: any SlackOAuthTransporting
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?

    init(
        clientID: String,
        requiredScopes: Set<String> = SlackOAuthScopePolicy.requiredUserScopes,
        transport: any SlackOAuthTransporting = SlackOAuthURLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) throws {
        guard Self.isValidClientID(clientID) else {
            throw SlackOAuthFailure(code: .invalidClientID)
        }
        guard requiredScopes == SlackOAuthScopePolicy.requiredUserScopes,
              requiredScopes.allSatisfy(Self.isValidScope),
              requiredScopes.isDisjoint(with: SlackOAuthScopePolicy.forbiddenUserScopes)
        else { throw SlackOAuthFailure(code: .scopeMismatch) }
        self.clientID = clientID
        self.requiredScopes = requiredScopes
        self.transport = transport
        self.now = now
        self.eventSink = eventSink
    }

    func authorizationURL(for material: SlackPKCEMaterial) throws -> URL {
        guard SlackPKCEGenerator.isValidVerifier(material.verifier),
              try SlackPKCEGenerator.s256Challenge(for: material.verifier) == material.challenge,
              (43...512).contains(material.state.utf8.count),
              material.state.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
              })
        else { throw SlackOAuthFailure(code: .invalidAuthorizationRequest) }

        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: SlackOAuthCallbackContract.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "user_scope", value: requiredScopes.sorted().joined(separator: ",")),
            URLQueryItem(name: "code_challenge", value: material.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: material.state)
        ]
        guard let url = components?.url else {
            throw SlackOAuthFailure(code: .invalidAuthorizationRequest)
        }
        return url
    }

    func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        trace: SlackTraceContext = .init()
    ) async throws -> SlackOAuthCredential {
        emit(.codeExchange, trace: trace, status: .started, reason: "slack_code_exchange_started")
        do {
            guard Self.isValidSecretParameter(code, maximumBytes: 4_096) else {
                throw SlackOAuthFailure(code: .invalidAuthorizationCode)
            }
            guard SlackPKCEGenerator.isValidVerifier(verifier) else {
                throw SlackOAuthFailure(code: .invalidCodeVerifier)
            }

            let response = try await performTokenRequest([
                "client_id": clientID,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": SlackOAuthCallbackContract.redirectURI
            ])
            let credential = try decodedCredential(from: response, preserving: nil)
            emit(.codeExchange, trace: trace, status: .success, reason: "slack_code_exchange_succeeded")
            return credential
        } catch let failure as SlackOAuthFailure {
            emit(.codeExchange, trace: trace, status: .failed, reason: failure.reasonCode)
            throw failure
        } catch is CancellationError {
            let failure = SlackOAuthFailure(code: .cancelled)
            emit(.codeExchange, trace: trace, status: .failed, reason: failure.reasonCode)
            throw failure
        } catch {
            let failure = SlackOAuthFailure(code: .transportFailure)
            emit(.codeExchange, trace: trace, status: .failed, reason: failure.reasonCode)
            throw failure
        }
    }

    func refresh(_ credential: SlackOAuthCredential) async throws -> SlackOAuthCredential {
        guard credential.isStructurallyValid() else {
            throw SlackOAuthFailure(code: .malformedResponse)
        }
        guard !credential.isRefreshTokenExpired(at: now()) else {
            throw SlackOAuthFailure(code: .refreshTokenExpired)
        }

        let response = try await performTokenRequest([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken
        ])
        return try decodedCredential(from: response, preserving: credential)
    }

    private func performTokenRequest(_ parameters: [String: String]) async throws -> RawOAuthResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(parameters).utf8)

        let response: SlackOAuthHTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch is CancellationError {
            throw SlackOAuthFailure(code: .cancelled)
        } catch let error as URLError where error.code == .timedOut {
            throw SlackOAuthFailure(code: .timeout)
        } catch let failure as SlackOAuthFailure {
            throw failure
        } catch {
            throw SlackOAuthFailure(code: .transportFailure)
        }

        guard response.url == Self.tokenEndpoint, response.statusCode == 200 else {
            throw SlackOAuthFailure(code: .unexpectedHTTPStatus, httpStatus: response.statusCode)
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw SlackOAuthFailure(code: .responseTooLarge)
        }
        guard SlackJSONMediaType.isJSON(response.contentType) else {
            throw SlackOAuthFailure(code: .invalidContentType)
        }

        do {
            try SlackBoundedJSONValidator.validate(response.data, maximumDepth: Self.maximumJSONDepth)
        } catch SlackBoundedJSONFailure.maximumDepthExceeded {
            throw SlackOAuthFailure(code: .jsonDepthExceeded)
        } catch {
            throw SlackOAuthFailure(code: .malformedResponse)
        }

        let decoded: RawOAuthResponse
        do {
            decoded = try JSONDecoder().decode(RawOAuthResponse.self, from: response.data)
        } catch {
            throw SlackOAuthFailure(code: .malformedResponse)
        }
        guard let ok = decoded.ok else { throw SlackOAuthFailure(code: .malformedResponse) }
        guard ok else { throw Self.rejection(for: decoded.error) }
        return decoded
    }

    private func decodedCredential(
        from response: RawOAuthResponse,
        preserving existing: SlackOAuthCredential?
    ) throws -> SlackOAuthCredential {
        let nestedHasCredential = response.authedUser?.hasCredentialFields == true
        let envelope = nestedHasCredential ? response.authedUser?.credentialEnvelope : response.topLevelCredentialEnvelope

        guard let accessToken = envelope?.accessToken, Self.isValidSecretParameter(accessToken) else {
            throw SlackOAuthFailure(code: .missingAccessToken)
        }
        guard let refreshToken = envelope?.refreshToken, Self.isValidSecretParameter(refreshToken) else {
            throw SlackOAuthFailure(code: .missingRefreshToken)
        }
        guard envelope?.tokenType == "user" else {
            throw SlackOAuthFailure(code: .tokenTypeMismatch)
        }
        guard let expiresIn = envelope?.expiresIn, (1...Self.maximumExpirationSeconds).contains(expiresIn) else {
            throw SlackOAuthFailure(code: .invalidExpiration)
        }
        guard let scopeValue = envelope?.scope else {
            throw SlackOAuthFailure(code: .scopeMismatch)
        }
        guard scopeValue.utf8.count <= 2_048 else {
            throw SlackOAuthFailure(code: .scopeMismatch)
        }
        let scopeValues = scopeValue.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let scopes = Set(scopeValues)
        guard !scopes.contains(""),
              scopeValues.count == requiredScopes.count,
              scopes == requiredScopes,
              scopes.isDisjoint(with: SlackOAuthScopePolicy.forbiddenUserScopes)
        else {
            throw SlackOAuthFailure(code: .scopeMismatch)
        }

        let teamID = existing?.teamID ?? response.team?.id ?? response.teamID
        let userID = existing?.userID ?? response.authedUser?.id ?? response.userID
        guard let teamID, Self.isValidIdentifier(teamID) else {
            throw SlackOAuthFailure(code: .missingTeamIdentity)
        }
        guard let userID, Self.isValidIdentifier(userID) else {
            throw SlackOAuthFailure(code: .missingUserIdentity)
        }

        let issuedAt = now()
        let credential = SlackOAuthCredential(
            teamID: teamID,
            userID: userID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "user",
            issuedAt: issuedAt,
            accessTokenExpiresAt: issuedAt.addingTimeInterval(TimeInterval(expiresIn)),
            refreshTokenExpiresAt: issuedAt.addingTimeInterval(Self.rotatingRefreshLifetime),
            grantedScopes: Array(scopes)
        )
        guard credential.isStructurallyValid() else {
            throw SlackOAuthFailure(code: .malformedResponse)
        }
        return credential
    }

    private static func rejection(for slackError: String?) -> SlackOAuthFailure {
        let code: SlackOAuthFailureCode
        switch slackError {
        case "invalid_refresh_token", "bad_refresh_token":
            code = .refreshTokenInvalid
        case "token_revoked", "invalid_auth":
            code = .accessTokenRevoked
        case "account_inactive", "team_disabled", "org_login_required":
            code = .workspaceDeactivated
        default:
            code = .slackRejected
        }
        return SlackOAuthFailure(code: code)
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { key in
            "\(percentEncoded(key))=\(percentEncoded(parameters[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func isValidClientID(_ value: String) -> Bool {
        guard (1...256).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidScope(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidSecretParameter(_ value: String, maximumBytes: Int = SlackOAuthCredential.maximumTokenBytes) -> Bool {
        guard (1...maximumBytes).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        })
    }

    private func emit(
        _ event: SlackTraceEventName,
        trace: SlackTraceContext,
        status: SlackTraceStatus,
        reason: String
    ) {
        eventSink?(.init(
            ts: now(),
            event: event,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_oauth_client",
            status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: nil,
            metadata: .init()
        ))
    }
}

actor SlackCredentialRefreshCoordinator {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private struct RefreshFlight {
        let generation: UInt64
        let task: Task<SlackOAuthCredential, Error>
    }

    private let oauthClient: SlackOAuthClient
    private let credentialStore: any SlackCredentialStoring
    private let now: @Sendable () -> Date
    private let refreshSkew: TimeInterval
    private let eventSink: TraceSink?
    private var refreshTasks: [String: RefreshFlight] = [:]
    private var refreshGenerations: [String: UInt64] = [:]
    private var invalidatedAccounts: Set<String> = []
    private var allRefreshesSuspended = false

    init(
        oauthClient: SlackOAuthClient,
        credentialStore: any SlackCredentialStoring,
        refreshSkew: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        self.oauthClient = oauthClient
        self.credentialStore = credentialStore
        self.refreshSkew = min(max(refreshSkew, 0), 900)
        self.now = now
        self.eventSink = eventSink
    }

    func credential(
        teamID: String,
        userID: String,
        trace: SlackTraceContext = .init(),
        scheduledBudget: ScheduledBriefingBudgetLedger? = nil
    ) async throws -> SlackOAuthCredential {
        try requireRefreshAllowed(key: "\(teamID):\(userID)", trace: trace)
        let credential = try await credentialStore.read(teamID: teamID, userID: userID)
        try requireRefreshAllowed(key: credential.accountIdentifier, trace: trace)
        guard credential.needsRefresh(at: now(), skew: refreshSkew) else {
            emit(
                trace: trace,
                status: .skipped,
                reason: "slack_credential_refresh_not_required",
                accountIdentifier: credential.accountIdentifier
            )
            return credential
        }
        return try await refresh(credential, trace: trace, scheduledBudget: scheduledBudget)
    }

    func forceRefresh(
        teamID: String,
        userID: String,
        trace: SlackTraceContext = .init(),
        scheduledBudget: ScheduledBriefingBudgetLedger? = nil
    ) async throws -> SlackOAuthCredential {
        try requireRefreshAllowed(key: "\(teamID):\(userID)", trace: trace)
        let credential = try await credentialStore.read(teamID: teamID, userID: userID)
        try requireRefreshAllowed(key: credential.accountIdentifier, trace: trace)
        return try await refresh(credential, trace: trace, scheduledBudget: scheduledBudget)
    }

    func refresh(
        _ credential: SlackOAuthCredential,
        trace: SlackTraceContext = .init(),
        scheduledBudget: ScheduledBriefingBudgetLedger? = nil
    ) async throws -> SlackOAuthCredential {
        try requireRefreshAllowed(key: credential.accountIdentifier, trace: trace)
        guard !credential.isRefreshTokenExpired(at: now()) else {
            emit(
                trace: trace,
                status: .failed,
                reason: SlackOAuthFailureCode.refreshTokenExpired.rawValue,
                accountIdentifier: credential.accountIdentifier
            )
            throw SlackOAuthFailure(code: .refreshTokenExpired)
        }
        let key = credential.accountIdentifier
        if let flight = refreshTasks[key] {
            emit(
                trace: trace,
                status: .skipped,
                reason: "slack_credential_refresh_coalesced",
                accountIdentifier: key
            )
            return try await awaitRefreshFlight(flight, key: key, trace: trace)
        }

        let generation = refreshGenerations[key, default: 0]
        emit(
            trace: trace,
            status: .started,
            reason: "slack_credential_refresh_started",
            accountIdentifier: key
        )
        let task = Task { [oauthClient] in
            if let scheduledBudget {
                switch await scheduledBudget.claimSlackRequest() {
                case .permitted:
                    break
                case let .rejected(reasonCode):
                    throw SlackAPIError.scheduledBudgetFailure(reasonCode: reasonCode)
                }
            }
            try Task.checkCancellation()
            let refreshed = try await oauthClient.refresh(credential)
            try Task.checkCancellation()
            try await self.commitRefresh(refreshed, key: key, generation: generation)
            return refreshed
        }
        let flight = RefreshFlight(generation: generation, task: task)
        refreshTasks[key] = flight
        return try await awaitRefreshFlight(flight, key: key, trace: trace)
    }

    func cancelRefresh(
        teamID: String,
        userID: String,
        trace: SlackTraceContext = .init()
    ) {
        let key = "\(teamID):\(userID)"
        invalidatedAccounts.insert(key)
        refreshGenerations[key, default: 0] &+= 1
        let flight = refreshTasks.removeValue(forKey: key)
        flight?.task.cancel()
        emit(
            trace: trace,
            status: flight == nil ? .skipped : .failed,
            reason: flight == nil
                ? "slack_credential_refresh_cancel_not_required"
                : "slack_credential_refresh_cancelled",
            accountIdentifier: key
        )
    }

    func cancelAllRefreshes(trace: SlackTraceContext = .init()) {
        allRefreshesSuspended = true
        let active = refreshTasks
        for (key, flight) in active {
            refreshGenerations[key, default: 0] &+= 1
            flight.task.cancel()
        }
        refreshTasks.removeAll(keepingCapacity: true)
        emit(
            trace: trace,
            status: active.isEmpty ? .skipped : .failed,
            reason: active.isEmpty
                ? "slack_credential_refresh_cancel_not_required"
                : "slack_credential_refresh_all_cancelled",
            accountIdentifier: nil
        )
    }

    func allowRefresh(
        teamID: String,
        userID: String,
        trace: SlackTraceContext = .init()
    ) {
        let key = "\(teamID):\(userID)"
        allRefreshesSuspended = false
        invalidatedAccounts.remove(key)
        emit(
            trace: trace,
            status: .skipped,
            reason: "slack_credential_refresh_reenabled_after_authorization",
            accountIdentifier: key
        )
    }

    private func commitRefresh(
        _ credential: SlackOAuthCredential,
        key: String,
        generation: UInt64
    ) async throws {
        guard refreshGenerations[key, default: 0] == generation else {
            throw SlackOAuthFailure(code: .cancelled)
        }
        try Task.checkCancellation()
        try await credentialStore.replace(credential)
        guard refreshGenerations[key, default: 0] == generation else {
            throw SlackOAuthFailure(code: .cancelled)
        }
        try Task.checkCancellation()
    }

    private func awaitRefreshFlight(
        _ flight: RefreshFlight,
        key: String,
        trace: SlackTraceContext
    ) async throws -> SlackOAuthCredential {
        do {
            let result = try await flight.task.value
            removeFlightIfCurrent(key: key, generation: flight.generation)
            emit(
                trace: trace,
                status: .success,
                reason: "slack_credential_refresh_succeeded",
                accountIdentifier: key
            )
            return result
        } catch is CancellationError {
            removeFlightIfCurrent(key: key, generation: flight.generation)
            let failure = SlackOAuthFailure(code: .cancelled)
            emit(trace: trace, status: .failed, reason: failure.reasonCode, accountIdentifier: key)
            throw failure
        } catch let failure as SlackOAuthFailure {
            removeFlightIfCurrent(key: key, generation: flight.generation)
            emit(trace: trace, status: .failed, reason: failure.reasonCode, accountIdentifier: key)
            throw failure
        } catch let failure as SlackAPIError {
            removeFlightIfCurrent(key: key, generation: flight.generation)
            emit(trace: trace, status: .failed, reason: failure.reasonCode, accountIdentifier: key)
            throw failure
        } catch {
            removeFlightIfCurrent(key: key, generation: flight.generation)
            emit(
                trace: trace,
                status: .failed,
                reason: "slack_credential_refresh_failed",
                accountIdentifier: key
            )
            throw error
        }
    }

    private func removeFlightIfCurrent(key: String, generation: UInt64) {
        guard refreshTasks[key]?.generation == generation else { return }
        refreshTasks[key] = nil
    }

    private func requireRefreshAllowed(key: String, trace: SlackTraceContext) throws {
        guard !allRefreshesSuspended, !invalidatedAccounts.contains(key) else {
            emit(
                trace: trace,
                status: .failed,
                reason: "slack_credential_refresh_blocked_after_disconnect",
                accountIdentifier: key
            )
            throw SlackOAuthFailure(code: .cancelled)
        }
    }

    private func emit(
        trace: SlackTraceContext,
        status: SlackTraceStatus,
        reason: String,
        accountIdentifier: String?
    ) {
        let metadata = accountIdentifier.map {
            SlackTraceMetadata([(.workspaceHash, SlackPrivacy.hashIdentifier($0))])
        } ?? .init()
        eventSink?(.init(
            ts: now(),
            event: .credentialRefresh,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_credential_refresh_coordinator",
            status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: nil,
            metadata: metadata
        ))
    }
}

struct SlackCredentialAccessTokenProvider: SlackAccessTokenProviding, Sendable {
    private let coordinator: SlackCredentialRefreshCoordinator

    init(coordinator: SlackCredentialRefreshCoordinator) {
        self.coordinator = coordinator
    }

    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext
    ) async throws -> String {
        try await accessToken(
            teamID: teamID,
            userID: userID,
            forceRefresh: forceRefresh,
            trace: trace,
            scheduledBudget: nil
        )
    }

    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> String {
        // Trace identity is accepted to satisfy the API boundary but is intentionally not attached
        // to credential errors or Keychain operations. No token, state, verifier, or code is logged.
        _ = trace
        do {
            let credential: SlackOAuthCredential
            if forceRefresh {
                credential = try await coordinator.forceRefresh(
                    teamID: teamID,
                    userID: userID,
                    trace: trace,
                    scheduledBudget: scheduledBudget
                )
            } else {
                credential = try await coordinator.credential(
                    teamID: teamID,
                    userID: userID,
                    trace: trace,
                    scheduledBudget: scheduledBudget
                )
            }
            guard credential.isStructurallyValid(),
                  !credential.accessToken.unicodeScalars.contains(where: {
                      CharacterSet.whitespacesAndNewlines.contains($0)
                          || CharacterSet.controlCharacters.contains($0)
                  })
            else { throw SlackAPIError(.reauthorizationRequired) }
            return credential.accessToken
        } catch let failure as SlackAPIError {
            throw failure
        } catch let failure as SlackOAuthFailure {
            throw Self.apiFailure(for: failure)
        } catch let failure as SlackCredentialStoreFailure {
            throw Self.apiFailure(for: failure)
        } catch is CancellationError {
            throw SlackAPIError(.cancelled)
        } catch {
            throw SlackAPIError(.reauthorizationRequired)
        }
    }

    private static func apiFailure(for failure: SlackOAuthFailure) -> SlackAPIError {
        switch failure.code {
        case .cancelled:
            .init(.cancelled)
        case .timeout:
            .init(.timedOut)
        case .transportFailure:
            .init(.transportFailure, httpStatus: failure.httpStatus)
        case .unexpectedHTTPStatus:
            .init(.httpFailure, httpStatus: failure.httpStatus)
        case .responseTooLarge:
            .init(.responseTooLarge)
        case .invalidContentType:
            .init(.invalidContentType)
        case .jsonDepthExceeded:
            .init(.jsonLimitExceeded)
        case .scopeMismatch:
            .init(.missingScope)
        case .accessTokenRevoked:
            .init(.tokenRevoked)
        case .refreshTokenExpired:
            .init(.tokenExpired)
        case .workspaceDeactivated:
            .init(.workspaceUnavailable)
        case .refreshTokenInvalid:
            .init(.reauthorizationRequired)
        default:
            .init(.reauthorizationRequired)
        }
    }

    private static func apiFailure(for failure: SlackCredentialStoreFailure) -> SlackAPIError {
        switch failure.code {
        case .unavailable, .interactionNotAllowed, .readFailed:
            .init(.transportFailure)
        case .missingEntitlement, .notFound, .invalidCredential, .payloadDecodingFailed, .payloadTooLarge:
            .init(.reauthorizationRequired)
        default:
            .init(.reauthorizationRequired)
        }
    }
}

private struct RawOAuthResponse: Decodable, Sendable {
    let ok: Bool?
    let error: String?
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let scope: String?
    let team: RawOAuthIdentity?
    let teamID: String?
    let userID: String?
    let authedUser: RawOAuthAuthedUser?

    var topLevelCredentialEnvelope: RawOAuthCredentialEnvelope {
        RawOAuthCredentialEnvelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresIn: expiresIn,
            scope: scope
        )
    }

    enum CodingKeys: String, CodingKey {
        case ok, error, scope, team
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case teamID = "team_id"
        case userID = "user_id"
        case authedUser = "authed_user"
    }
}

private struct RawOAuthIdentity: Decodable, Sendable {
    let id: String?
}

private struct RawOAuthAuthedUser: Decodable, Sendable {
    let id: String?
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let scope: String?

    var hasCredentialFields: Bool {
        accessToken != nil || refreshToken != nil || tokenType != nil || expiresIn != nil || scope != nil
    }

    var credentialEnvelope: RawOAuthCredentialEnvelope {
        RawOAuthCredentialEnvelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresIn: expiresIn,
            scope: scope
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, scope
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

private struct RawOAuthCredentialEnvelope: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let scope: String?
}
