import Foundation

enum SlackRevocationFailureCode: String, Codable, Sendable {
    case invalidAccessToken = "slack_revoke_access_token_invalid"
    case requestRejected = "slack_revoke_request_rejected"
    case cancelled = "slack_revoke_cancelled"
    case timedOut = "slack_revoke_timed_out"
    case transportFailure = "slack_revoke_transport_failed"
    case redirectRejected = "slack_revoke_redirect_rejected"
    case unexpectedHTTPStatus = "slack_revoke_http_status_unexpected"
    case responseTooLarge = "slack_revoke_response_too_large"
    case invalidContentType = "slack_revoke_content_type_invalid"
    case jsonDepthExceeded = "slack_revoke_json_depth_exceeded"
    case malformedResponse = "slack_revoke_response_malformed"
    case slackRejected = "slack_revoke_slack_rejected"
    case revocationNotConfirmed = "slack_revoke_not_confirmed"
}

struct SlackRevocationFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackRevocationFailureCode
    let httpStatus: Int?

    init(code: SlackRevocationFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .invalidAccessToken: "The Slack credential could not be revoked."
        case .requestRejected: "The Slack revocation request violated its local security contract."
        case .cancelled: "The Slack revocation request was cancelled."
        case .timedOut: "The Slack revocation request timed out."
        case .transportFailure: "Slack could not be reached for revocation."
        case .redirectRejected: "Slack revocation refused a redirect."
        case .unexpectedHTTPStatus: "Slack revocation returned an unexpected HTTP status."
        case .responseTooLarge: "The Slack revocation response exceeded its size bound."
        case .invalidContentType: "The Slack revocation response was not JSON."
        case .jsonDepthExceeded: "The Slack revocation response exceeded its JSON nesting bound."
        case .malformedResponse: "The Slack revocation response was malformed."
        case .slackRejected: "Slack rejected the revocation request."
        case .revocationNotConfirmed: "Slack did not confirm remote revocation."
        }
    }
}

struct SlackRemoteRevocationResult: Codable, Equatable, Sendable {
    let remoteConfirmed: Bool
}

protocol SlackTokenRevoking: Sendable {
    func revoke(accessToken: String) async throws -> SlackRemoteRevocationResult
}

struct SlackRevocationHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
    let contentType: String?
}

protocol SlackRevocationTransporting: Sendable {
    func data(for request: URLRequest) async throws -> SlackRevocationHTTPResponse
}

final class SlackRevocationURLSessionTransport: NSObject, SlackRevocationTransporting,
    URLSessionTaskDelegate, @unchecked Sendable
{
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
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> SlackRevocationHTTPResponse {
        guard SlackRevocationClient.isAllowed(request) else {
            throw SlackRevocationFailure(code: .requestRejected)
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let response = response as? HTTPURLResponse else {
            throw SlackRevocationFailure(code: .transportFailure)
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard response.statusCode == 200, response.url == SlackRevocationClient.endpoint else {
            return SlackRevocationHTTPResponse(
                data: Data(),
                statusCode: response.statusCode,
                finalURL: response.url,
                contentType: contentType
            )
        }
        guard SlackJSONMediaType.isJSON(contentType) else {
            throw SlackRevocationFailure(code: .invalidContentType)
        }

        let data: Data
        do {
            data = try await SlackBoundedBodyReader.read(
                bytes,
                maximumBytes: SlackRevocationClient.maximumResponseBytes,
                expectedContentLength: response.expectedContentLength
            )
        } catch let failure as SlackBoundedBodyFailure where failure == .limitExceeded {
            throw SlackRevocationFailure(code: .responseTooLarge)
        }
        return SlackRevocationHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            finalURL: response.url,
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
}

struct SlackRevocationClient: SlackTokenRevoking, Sendable {
    static let endpoint = URL(string: "https://slack.com/api/auth.revoke")!
    static let maximumResponseBytes = 32 * 1_024
    static let maximumJSONDepth = 8

    private let transport: any SlackRevocationTransporting

    init(transport: any SlackRevocationTransporting = SlackRevocationURLSessionTransport()) {
        self.transport = transport
    }

    func revoke(accessToken: String) async throws -> SlackRemoteRevocationResult {
        guard Self.isValidToken(accessToken) else {
            throw SlackRevocationFailure(code: .invalidAccessToken)
        }
        guard !Task.isCancelled else { throw SlackRevocationFailure(code: .cancelled) }

        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        guard Self.isAllowed(request) else { throw SlackRevocationFailure(code: .requestRejected) }

        let response: SlackRevocationHTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch is CancellationError {
            throw SlackRevocationFailure(code: .cancelled)
        } catch let error as URLError where error.code == .cancelled {
            throw SlackRevocationFailure(code: .cancelled)
        } catch let error as URLError where error.code == .timedOut {
            throw SlackRevocationFailure(code: .timedOut)
        } catch let failure as SlackRevocationFailure {
            throw failure
        } catch {
            throw SlackRevocationFailure(code: .transportFailure)
        }

        guard response.finalURL == Self.endpoint else {
            throw SlackRevocationFailure(code: .redirectRejected, httpStatus: response.statusCode)
        }
        if (300...399).contains(response.statusCode) {
            throw SlackRevocationFailure(code: .redirectRejected, httpStatus: response.statusCode)
        }
        guard response.statusCode == 200 else {
            throw SlackRevocationFailure(code: .unexpectedHTTPStatus, httpStatus: response.statusCode)
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw SlackRevocationFailure(code: .responseTooLarge)
        }
        guard SlackJSONMediaType.isJSON(response.contentType) else {
            throw SlackRevocationFailure(code: .invalidContentType)
        }

        do {
            try SlackBoundedJSONValidator.validate(response.data, maximumDepth: Self.maximumJSONDepth)
        } catch SlackBoundedJSONFailure.maximumDepthExceeded {
            throw SlackRevocationFailure(code: .jsonDepthExceeded)
        } catch {
            throw SlackRevocationFailure(code: .malformedResponse)
        }

        let envelope: RevocationEnvelope
        do {
            envelope = try JSONDecoder().decode(RevocationEnvelope.self, from: response.data)
        } catch {
            throw SlackRevocationFailure(code: .malformedResponse)
        }
        guard envelope.ok else {
            guard let error = envelope.error, !error.isEmpty, error.utf8.count <= 120 else {
                throw SlackRevocationFailure(code: .malformedResponse)
            }
            throw SlackRevocationFailure(code: .slackRejected)
        }
        guard envelope.revoked == true else {
            throw SlackRevocationFailure(code: .revocationNotConfirmed)
        }
        return SlackRemoteRevocationResult(remoteConfirmed: true)
    }

    static func isAllowed(_ request: URLRequest) -> Bool {
        guard request.url == endpoint,
              request.httpMethod == "POST",
              request.httpBody == nil,
              request.httpBodyStream == nil,
              request.url?.query == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.value(forHTTPHeaderField: "Content-Type") == nil,
              request.value(forHTTPHeaderField: "client_secret") == nil,
              let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "),
              isValidToken(String(authorization.dropFirst("Bearer ".count)))
        else { return false }
        return true
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard (1...SlackOAuthCredential.maximumTokenBytes).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        })
    }
}

private struct RevocationEnvelope: Decodable, Sendable {
    let ok: Bool
    let revoked: Bool?
    let error: String?
}
