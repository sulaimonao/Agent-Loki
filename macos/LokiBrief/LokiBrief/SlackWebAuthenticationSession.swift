import AppKit
import AuthenticationServices
import Foundation

enum SlackBrowserSessionFailureCode: String, Codable, Sendable {
    case sessionAlreadyActive = "slack_browser_session_already_active"
    case invalidAuthorizationURL = "slack_browser_authorization_url_invalid"
    case invalidCallbackScheme = "slack_browser_callback_scheme_invalid"
    case presentationUnavailable = "slack_browser_presentation_unavailable"
    case failedToStart = "slack_browser_session_failed_to_start"
    case cancelled = "slack_browser_session_cancelled"
    case failed = "slack_browser_session_failed"
}

struct SlackBrowserSessionFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackBrowserSessionFailureCode

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .sessionAlreadyActive:
            "A browser authorization session is already active."
        case .invalidAuthorizationURL:
            "The browser authorization URL is invalid."
        case .invalidCallbackScheme:
            "The browser callback scheme is invalid."
        case .presentationUnavailable:
            "A presentation window is unavailable."
        case .failedToStart:
            "The browser authorization session could not start."
        case .cancelled:
            "The browser authorization session was cancelled."
        case .failed:
            "The browser authorization session failed."
        }
    }
}

protocol SlackWebAuthenticationSessioning: AnyObject, Sendable {
    @MainActor
    func authenticate(
        authorizationURL: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL

    @MainActor
    func cancel()
}

@MainActor
final class SystemSlackWebAuthenticationSession: NSObject, SlackWebAuthenticationSessioning,
    ASWebAuthenticationPresentationContextProviding
{
    typealias PresentationAnchorProvider = @MainActor @Sendable () -> ASPresentationAnchor?

    private let presentationAnchorProvider: PresentationAnchorProvider
    private var activeSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    init(presentationAnchorProvider: @escaping PresentationAnchorProvider = {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible })
    }) {
        self.presentationAnchorProvider = presentationAnchorProvider
        super.init()
    }

    func authenticate(
        authorizationURL: URL,
        callbackScheme: String = SlackOAuthCallbackContract.scheme,
        prefersEphemeralSession: Bool = false
    ) async throws -> URL {
        guard activeSession == nil, continuation == nil else {
            throw SlackBrowserSessionFailure(code: .sessionAlreadyActive)
        }
        guard Self.isAllowedAuthorizationURL(authorizationURL) else {
            throw SlackBrowserSessionFailure(code: .invalidAuthorizationURL)
        }
        guard callbackScheme == SlackOAuthCallbackContract.scheme else {
            throw SlackBrowserSessionFailure(code: .invalidCallbackScheme)
        }
        guard presentationAnchorProvider() != nil else {
            throw SlackBrowserSessionFailure(code: .presentationUnavailable)
        }
        guard !Task.isCancelled else {
            throw SlackBrowserSessionFailure(code: .cancelled)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                    Task { @MainActor [weak self] in
                        self?.finish(callbackURL: callbackURL, error: error)
                    }
                }

                let session: ASWebAuthenticationSession
                if #available(macOS 14.4, *) {
                    session = ASWebAuthenticationSession(
                        url: authorizationURL,
                        callback: .customScheme(callbackScheme),
                        completionHandler: completion
                    )
                } else {
                    session = ASWebAuthenticationSession(
                        url: authorizationURL,
                        callbackURLScheme: callbackScheme,
                        completionHandler: completion
                    )
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
                self.continuation = continuation
                activeSession = session

                guard session.start() else {
                    activeSession = nil
                    self.continuation = nil
                    continuation.resume(throwing: SlackBrowserSessionFailure(code: .failedToStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        let session = activeSession
        activeSession = nil
        let continuation = continuation
        self.continuation = nil
        session?.cancel()
        continuation?.resume(throwing: SlackBrowserSessionFailure(code: .cancelled))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `authenticate` verifies the provider before starting. If the window closes in the
        // narrow interval before this callback, use the app's current key window if available.
        presentationAnchorProvider() ?? NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }

    private func finish(callbackURL: URL?, error: Error?) {
        guard let continuation else { return }
        activeSession = nil
        self.continuation = nil

        if let callbackURL {
            continuation.resume(returning: callbackURL)
            return
        }
        if let error, Self.isCancellation(error) {
            continuation.resume(throwing: SlackBrowserSessionFailure(code: .cancelled))
            return
        }
        continuation.resume(throwing: SlackBrowserSessionFailure(code: .failed))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionErrorDomain
            && nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }

    private static func isAllowedAuthorizationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.host == "slack.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.percentEncodedPath == "/oauth/v2/authorize"
            && components.fragment == nil
    }
}
