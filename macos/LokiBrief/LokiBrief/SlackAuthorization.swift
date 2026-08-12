import Foundation

enum SlackOAuthCallbackContract {
    static let scheme = "com.agentloki.lokibrief"
    static let host = "oauth"
    static let path = "/slack"
    static let redirectURI = "com.agentloki.lokibrief://oauth/slack"
    static let maximumCallbackCharacters = 8_192

    static func state(from callbackURL: URL) throws -> String {
        let values = try queryValues(from: callbackURL)
        guard let state = values["state"], !state.isEmpty else {
            throw SlackAuthorizationFailure(code: .missingState)
        }
        guard state.utf8.count <= 512 else {
            throw SlackAuthorizationFailure(code: .malformedCallback)
        }
        return state
    }

    static func result(from callbackURL: URL) throws -> SlackAuthorizationCallback {
        let values = try queryValues(from: callbackURL)
        let code = values["code"]
        let denial = values["error"]

        guard (code == nil) != (denial == nil) else {
            throw SlackAuthorizationFailure(code: .malformedCallback)
        }
        if denial != nil {
            throw SlackAuthorizationFailure(code: .authorizationDenied)
        }
        guard let code, !code.isEmpty, code.utf8.count <= 4_096,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SlackAuthorizationFailure(code: .missingAuthorizationCode)
        }
        return .authorized(code: code)
    }

    private static func queryValues(from callbackURL: URL) throws -> [String: String] {
        guard callbackURL.absoluteString.utf8.count <= maximumCallbackCharacters,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath == path,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count <= 8
        else {
            throw SlackAuthorizationFailure(code: .callbackMismatch)
        }

        let allowedNames = Set(["code", "state", "error", "error_description"])
        var values: [String: String] = [:]
        for item in queryItems {
            guard allowedNames.contains(item.name), values[item.name] == nil, let value = item.value else {
                throw SlackAuthorizationFailure(code: .malformedCallback)
            }
            values[item.name] = value
        }
        return values
    }
}

enum SlackAuthorizationFailureCode: String, Codable, Sendable {
    case attemptAlreadyActive = "slack_authorization_attempt_already_active"
    case attemptNotActive = "slack_authorization_attempt_not_active"
    case attemptExpired = "slack_authorization_attempt_expired"
    case attemptCancelled = "slack_authorization_attempt_cancelled"
    case callbackMismatch = "slack_authorization_callback_mismatch"
    case malformedCallback = "slack_authorization_callback_malformed"
    case missingState = "slack_authorization_state_missing"
    case stateMismatch = "slack_authorization_state_mismatch"
    case missingAuthorizationCode = "slack_authorization_code_missing"
    case authorizationDenied = "slack_authorization_denied"
    case duplicateCallback = "slack_authorization_callback_duplicate"
    case lateCallback = "slack_authorization_callback_late"
}

struct SlackAuthorizationFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackAuthorizationFailureCode

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .attemptAlreadyActive:
            "A Slack authorization attempt is already active."
        case .attemptNotActive:
            "No matching Slack authorization attempt is active."
        case .attemptExpired:
            "The Slack authorization attempt expired."
        case .attemptCancelled:
            "The Slack authorization attempt was cancelled."
        case .callbackMismatch:
            "The Slack authorization callback did not match the registered contract."
        case .malformedCallback:
            "The Slack authorization callback was malformed."
        case .missingState:
            "The Slack authorization callback did not include state."
        case .stateMismatch:
            "The Slack authorization callback state did not match."
        case .missingAuthorizationCode:
            "The Slack authorization callback did not include a valid code."
        case .authorizationDenied:
            "Slack authorization was denied."
        case .duplicateCallback:
            "The Slack authorization callback was already consumed."
        case .lateCallback:
            "The Slack authorization callback arrived after the attempt ended."
        }
    }
}

struct SlackAuthorizationAttempt: Equatable, Sendable {
    let id: UUID
    let material: SlackPKCEMaterial
    let startedAt: Date
    let expiresAt: Date
}

enum SlackAuthorizationCallback: Equatable, Sendable {
    case authorized(code: String)
}

actor SlackAuthorizationAttemptCoordinator {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private enum TerminalOutcome: Sendable {
        case consumed
        case cancelled
        case expired
        case rejected
    }

    private struct TerminalAttempt: Sendable {
        let id: UUID
        let outcome: TerminalOutcome
    }

    private let generator: SlackPKCEGenerator
    private let lifetime: TimeInterval
    private let eventSink: TraceSink?
    private var activeAttempt: SlackAuthorizationAttempt?
    private var terminalAttempt: TerminalAttempt?

    init(
        generator: SlackPKCEGenerator = .init(),
        lifetime: TimeInterval = 600,
        eventSink: TraceSink? = nil
    ) {
        self.generator = generator
        self.lifetime = min(max(lifetime, 1), 900)
        self.eventSink = eventSink
    }

    func begin(at now: Date = Date()) throws -> SlackAuthorizationAttempt {
        guard activeAttempt == nil else {
            throw SlackAuthorizationFailure(code: .attemptAlreadyActive)
        }
        terminalAttempt = nil
        let attempt = SlackAuthorizationAttempt(
            id: UUID(),
            material: try generator.generate(),
            startedAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        activeAttempt = attempt
        return attempt
    }

    func activeAttemptID() -> UUID? {
        activeAttempt?.id
    }

    @discardableResult
    func cancel(_ attemptID: UUID) throws -> Bool {
        guard let activeAttempt else {
            if terminalAttempt?.id == attemptID {
                throw SlackAuthorizationFailure(code: .attemptCancelled)
            }
            throw SlackAuthorizationFailure(code: .attemptNotActive)
        }
        guard activeAttempt.id == attemptID else {
            throw SlackAuthorizationFailure(code: .attemptNotActive)
        }
        self.activeAttempt = nil
        terminalAttempt = TerminalAttempt(id: attemptID, outcome: .cancelled)
        return true
    }

    func accept(
        _ callbackURL: URL,
        at now: Date = Date(),
        trace: SlackTraceContext = .init()
    ) throws -> SlackAuthorizationCallback {
        emit(
            at: now,
            trace: trace,
            status: .started,
            reason: "slack_callback_validation_started"
        )
        do {
            let result = try validatedCallback(callbackURL, at: now)
            emit(
                at: now,
                trace: trace,
                status: .success,
                reason: "slack_callback_validation_succeeded"
            )
            return result
        } catch let failure as SlackAuthorizationFailure {
            emit(at: now, trace: trace, status: .failed, reason: failure.reasonCode)
            throw failure
        } catch {
            let failure = SlackAuthorizationFailure(code: .malformedCallback)
            emit(at: now, trace: trace, status: .failed, reason: failure.reasonCode)
            throw failure
        }
    }

    private func validatedCallback(
        _ callbackURL: URL,
        at now: Date
    ) throws -> SlackAuthorizationCallback {
        let receivedState: String
        do {
            receivedState = try SlackOAuthCallbackContract.state(from: callbackURL)
        } catch {
            rejectActiveAttempt()
            throw error
        }

        guard let activeAttempt else {
            if terminalAttempt?.outcome == .consumed {
                throw SlackAuthorizationFailure(code: .duplicateCallback)
            }
            throw SlackAuthorizationFailure(code: .lateCallback)
        }

        guard Self.constantTimeEqual(receivedState, activeAttempt.material.state) else {
            self.activeAttempt = nil
            terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .rejected)
            throw SlackAuthorizationFailure(code: .stateMismatch)
        }
        guard now <= activeAttempt.expiresAt else {
            self.activeAttempt = nil
            terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .expired)
            throw SlackAuthorizationFailure(code: .attemptExpired)
        }

        do {
            let result = try SlackOAuthCallbackContract.result(from: callbackURL)
            self.activeAttempt = nil
            terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .consumed)
            return result
        } catch let failure as SlackAuthorizationFailure where failure.code == .authorizationDenied {
            self.activeAttempt = nil
            terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .consumed)
            throw failure
        } catch {
            self.activeAttempt = nil
            terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .rejected)
            throw error
        }
    }

    private func rejectActiveAttempt() {
        guard let activeAttempt else { return }
        self.activeAttempt = nil
        terminalAttempt = TerminalAttempt(id: activeAttempt.id, outcome: .rejected)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    private func emit(
        at date: Date,
        trace: SlackTraceContext,
        status: SlackTraceStatus,
        reason: String
    ) {
        eventSink?(.init(
            ts: date,
            event: .callbackValidation,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_authorization_attempt_coordinator",
            status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: nil,
            metadata: .init()
        ))
    }
}

/// Runs one public-client browser/code-exchange attempt. The returned credential is intentionally
/// not persisted here: the integration layer must first validate it with Slack `auth.test`, then
/// create the Keychain record only after the returned team/user identity is confirmed.
actor SlackAuthorizationService {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private let attempts: SlackAuthorizationAttemptCoordinator
    private let browser: any SlackWebAuthenticationSessioning
    private let oauthClient: SlackOAuthClient
    private let now: @Sendable () -> Date

    init(
        attempts: SlackAuthorizationAttemptCoordinator? = nil,
        browser: any SlackWebAuthenticationSessioning,
        oauthClient: SlackOAuthClient,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        self.attempts = attempts ?? SlackAuthorizationAttemptCoordinator(eventSink: eventSink)
        self.browser = browser
        self.oauthClient = oauthClient
        self.now = now
    }

    func authorize(prefersEphemeralSession: Bool = false) async throws -> SlackOAuthCredential {
        let trace = SlackTraceContext()
        let attempt = try await attempts.begin(at: now())
        let authorizationURL: URL
        do {
            authorizationURL = try oauthClient.authorizationURL(for: attempt.material)
        } catch {
            _ = try? await attempts.cancel(attempt.id)
            throw error
        }

        do {
            let callbackURL = try await browser.authenticate(
                authorizationURL: authorizationURL,
                callbackScheme: SlackOAuthCallbackContract.scheme,
                prefersEphemeralSession: prefersEphemeralSession
            )
            let callback = try await attempts.accept(callbackURL, at: now(), trace: trace)
            switch callback {
            case let .authorized(code):
                return try await oauthClient.exchangeAuthorizationCode(
                    code: code,
                    verifier: attempt.material.verifier,
                    trace: trace.child()
                )
            }
        } catch {
            _ = try? await attempts.cancel(attempt.id)
            throw error
        }
    }

    func cancelActiveAuthorization() async {
        if let attemptID = await attempts.activeAttemptID() {
            _ = try? await attempts.cancel(attemptID)
        }
        await browser.cancel()
    }
}
