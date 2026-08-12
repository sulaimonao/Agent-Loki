import Foundation

enum SlackEndpointPolicy {
    private static let allowedQueryKeys: [SlackAPIMethod: Set<String>] = [
        .authTest: [],
        .conversationsList: ["cursor", "exclude_archived", "limit", "team_id", "types"],
        .conversationsHistory: ["channel", "cursor", "inclusive", "latest", "limit", "oldest"],
        .usersInfo: ["include_locale", "user"],
        .chatGetPermalink: ["channel", "message_ts"],
    ]

    static func validate(_ request: URLRequest, expectedMethod: SlackAPIMethod? = nil) throws -> SlackAPIMethod {
        guard request.httpMethod == "GET",
              request.httpBody == nil,
              let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "slack.com",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let method = SlackAPIMethod.allCases.first(where: { $0.path == components.path }),
              expectedMethod == nil || expectedMethod == method
        else { throw SlackAPIError(.invalidEndpoint) }

        let queryItems = components.queryItems ?? []
        let keys = queryItems.map { $0.name.lowercased() }
        guard Set(keys).count == keys.count,
              !keys.contains(where: { ["token", "access_token", "authorization", "client_secret"].contains($0) }),
              Set(keys).isSubset(of: allowedQueryKeys[method] ?? [])
        else { throw SlackAPIError(.invalidRequest) }

        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "),
              authorization.count > "Bearer ".count,
              !authorization.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw SlackAPIError(.invalidRequest) }
        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil
        else { throw SlackAPIError(.invalidRequest) }
        return method
    }
}

final class BoundedSlackTransport: NSObject, SlackAPITransporting, @unchecked Sendable {
    private final class TaskState {
        let requestID: UUID
        let responseLimit: Int
        var data = Data()
        var response: HTTPURLResponse?
        var terminalFailure: SlackAPIError?
        var continuation: CheckedContinuation<SlackTransportResponse, Error>?

        init(requestID: UUID, responseLimit: Int, continuation: CheckedContinuation<SlackTransportResponse, Error>) {
            self.requestID = requestID
            self.responseLimit = responseLimit
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var statesByTaskID: [Int: TaskState] = [:]
    private var tasksByRequestID: [UUID: URLSessionDataTask] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SlackLimits.requestTimeout
        configuration.timeoutIntervalForResource = SlackLimits.resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.name = "com.agentloki.LokiBrief.slack.transport"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest, requestID: UUID, responseLimit: Int) async throws -> SlackTransportResponse {
        _ = try SlackEndpointPolicy.validate(request)
        guard responseLimit > 0, responseLimit <= SlackLimits.maximumResponseBytes else {
            throw SlackAPIError(.responseTooLarge)
        }
        guard !Task.isCancelled else { throw SlackAPIError(.cancelled) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = TaskState(requestID: requestID, responseLimit: responseLimit, continuation: continuation)
                lock.lock()
                statesByTaskID[task.taskIdentifier] = state
                tasksByRequestID[requestID] = task
                let wasCancelled = cancelledBeforeRegistration.remove(requestID) != nil
                lock.unlock()
                task.resume()
                if wasCancelled { task.cancel() }
            }
        } onCancel: {
            self.cancelNow(requestID: requestID)
        }
    }

    func cancel(requestID: UUID) async { cancelNow(requestID: requestID) }

    private func cancelNow(requestID: UUID) {
        lock.lock()
        let task = tasksByRequestID[requestID]
        if task == nil { cancelledBeforeRegistration.insert(requestID) }
        lock.unlock()
        task?.cancel()
    }

    private func setTerminalFailure(_ failure: SlackAPIError, for task: URLSessionTask) {
        lock.lock()
        statesByTaskID[task.taskIdentifier]?.terminalFailure = failure
        lock.unlock()
    }

    private func complete(_ task: URLSessionTask, networkError: Error?) {
        lock.lock()
        let state = statesByTaskID.removeValue(forKey: task.taskIdentifier)
        if let requestID = state?.requestID {
            tasksByRequestID.removeValue(forKey: requestID)
            cancelledBeforeRegistration.remove(requestID)
        }
        lock.unlock()

        guard let state, let continuation = state.continuation else { return }
        state.continuation = nil
        if let terminalFailure = state.terminalFailure {
            continuation.resume(throwing: terminalFailure)
        } else if let urlError = networkError as? URLError, urlError.code == .cancelled {
            continuation.resume(throwing: SlackAPIError(.cancelled))
        } else if let networkError {
            continuation.resume(throwing: networkError)
        } else if let response = state.response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key] = String(describing: value)
            }
            continuation.resume(returning: .init(data: state.data, statusCode: response.statusCode, finalURL: response.url, headers: headers))
        } else {
            continuation.resume(throwing: SlackAPIError(.invalidSchema))
        }
    }
}

extension BoundedSlackTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            setTerminalFailure(.init(.invalidSchema), for: dataTask)
            completionHandler(.cancel)
            return
        }
        var shouldCancel = false
        lock.lock()
        if let state = statesByTaskID[dataTask.taskIdentifier] {
            state.response = response
            if response.expectedContentLength > Int64(state.responseLimit) {
                state.terminalFailure = .init(.responseTooLarge)
                shouldCancel = true
            }
        }
        lock.unlock()
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        lock.lock()
        if let state = statesByTaskID[dataTask.taskIdentifier] {
            if data.count > state.responseLimit - state.data.count {
                state.terminalFailure = .init(.responseTooLarge)
                shouldCancel = true
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        setTerminalFailure(.init(.redirectRejected, httpStatus: response.statusCode), for: task)
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(task, networkError: error)
    }
}

actor SlackAPIClient {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void
    typealias RateLimitSink = @Sendable (_ workspaceID: String, _ state: SlackRateLimitState?) -> Void

    private struct AttemptLedger {
        var transientRetryCount = 0
        var rateLimitRetryCount = 0
        var credentialRefreshCount = 0
        var lastRateLimitState: SlackRateLimitState?
    }

    private struct SlackEnvelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private let tokenProvider: any SlackAccessTokenProviding
    private let transport: any SlackAPITransporting
    private let sleeper: any SlackSleeping
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?
    private let rateLimitSink: RateLimitSink?
    private var activeRequestIDs: Set<UUID> = []
    private var activeWaitTasks: [UUID: Task<Void, Error>] = [:]
    private var cancellationEpoch: UInt64 = 0

    init(
        tokenProvider: any SlackAccessTokenProviding,
        transport: any SlackAPITransporting = BoundedSlackTransport(),
        sleeper: any SlackSleeping = SystemSlackSleeper(),
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil,
        rateLimitSink: RateLimitSink? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.sleeper = sleeper
        self.now = now
        self.eventSink = eventSink
        self.rateLimitSink = rateLimitSink
    }

    func testAuthentication(connection: SlackWorkspaceConnection, trace: SlackTraceContext = .init()) async throws -> SlackAPICallResult<SlackAuthenticatedIdentity> {
        emit(.identityValidation, trace: trace, status: .started, reason: "slack_identity_validation_started", metadata: identityMetadata(connection))
        do {
            let response = try await perform(method: .authTest, connection: connection, query: [], trace: trace.child())
            let decoded = try decode(SlackAuthTestResponse.self, from: response.data)
            guard let teamID = SlackPrivacy.boundedIdentifier(decoded.teamID),
                  let userID = SlackPrivacy.boundedIdentifier(decoded.userID),
                  teamID == connection.teamID,
                  userID == connection.userID
            else { throw SlackAPIError(.invalidSchema) }
            let identity = SlackAuthenticatedIdentity(
                teamID: teamID,
                teamName: SlackPrivacy.boundedDisplayName(decoded.team ?? connection.teamName, maximum: SlackLimits.maximumWorkspaceNameCharacters, fallback: "Slack Workspace"),
                userID: userID,
                userName: SlackPrivacy.boundedDisplayName(decoded.user ?? connection.userDisplayName, maximum: SlackLimits.maximumAuthorNameCharacters, fallback: "Slack user"),
                workspaceURL: validatedWorkspaceURL(decoded.url)
            )
            emit(.identityValidation, trace: trace, status: .success, reason: "slack_identity_validated", metadata: identityMetadata(connection))
            return .init(value: identity, metadata: response.metadata)
        } catch {
            let failure = mapFailure(error)
            emit(.identityValidation, trace: trace, status: failure.code == .cancelled ? .skipped : .failed, reason: failure.reasonCode, metadata: identityMetadata(connection))
            throw failure
        }
    }

    func listConversations(
        connection: SlackWorkspaceConnection,
        cursor: String? = nil,
        limit: Int = SlackLimits.channelDiscoveryPageSize,
        trace: SlackTraceContext = .init()
    ) async throws -> SlackAPICallResult<SlackConversationPage> {
        guard (1...SlackLimits.channelDiscoveryPageSize).contains(limit), isBoundedCursor(cursor) else { throw SlackAPIError(.invalidRequest) }
        var query = [
            URLQueryItem(name: "exclude_archived", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "types", value: "public_channel,private_channel"),
        ]
        if let cursor, !cursor.isEmpty { query.append(.init(name: "cursor", value: cursor)) }
        let response = try await perform(method: .conversationsList, connection: connection, query: query, trace: trace)
        let decoded = try decode(SlackConversationsResponse.self, from: response.data)
        guard decoded.channels.count <= limit else { throw SlackAPIError(.invalidSchema) }
        let conversations = try decoded.channels.map { raw -> SlackConversation in
            guard raw.isIM != true, raw.isMPIM != true,
                  let id = SlackPrivacy.boundedIdentifier(raw.id),
                  let name = raw.name
            else { throw SlackAPIError(.invalidSchema) }
            return .init(
                id: id,
                workspaceID: connection.id,
                displayName: SlackPrivacy.boundedDisplayName(name, maximum: SlackLimits.maximumChannelNameCharacters, fallback: "Slack channel"),
                kind: raw.isPrivate == true ? .privateChannel : .publicChannel,
                isMember: raw.isMember == true,
                isArchived: raw.isArchived == true,
                discoveredAt: now()
            )
        }.filter { !$0.isArchived }
        let nextCursor = try boundedCursor(decoded.responseMetadata?.nextCursor)
        return .init(value: .init(conversations: conversations, nextCursor: nextCursor), metadata: response.metadata)
    }

    func discoverConversations(connection: SlackWorkspaceConnection, trace: SlackTraceContext = .init()) async throws -> SlackAPICallResult<[SlackConversation]> {
        emit(.channelDiscovery, trace: trace, status: .started, reason: "slack_channel_discovery_started", metadata: identityMetadata(connection))
        var cursor: String?
        var pages = 0
        var byID: [String: SlackConversation] = [:]
        var combined = AttemptLedger()
        do {
            repeat {
                try checkCancellation(epoch: cancellationEpoch)
                let page = try await listConversations(connection: connection, cursor: cursor, trace: trace.child())
                pages += 1
                merge(page.metadata, into: &combined)
                for conversation in page.value.conversations { byID[conversation.id] = conversation }
                cursor = page.value.nextCursor
                guard byID.count <= SlackLimits.maximumDiscoveredChannels else { throw SlackAPIError(.invalidSchema) }
            } while cursor != nil && pages < SlackLimits.maximumChannelDiscoveryPages
            guard cursor == nil else { throw SlackAPIError(.invalidSchema) }
            let values = byID.values.sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            emit(.channelDiscovery, trace: trace, status: .success, reason: "slack_channel_discovery_succeeded", metadata: .init([
                (.pageCount, String(pages)), (.successCount, String(values.count)), (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
            ]))
            return .init(value: values, metadata: metadata(from: combined))
        } catch {
            let failure = mapFailure(error)
            emit(.channelDiscovery, trace: trace, status: failure.code == .cancelled ? .skipped : .failed, reason: failure.reasonCode, metadata: identityMetadata(connection))
            throw failure
        }
    }

    func conversationHistory(
        connection: SlackWorkspaceConnection,
        channelID: String,
        oldest: SlackTimestamp?,
        latest: SlackTimestamp?,
        cursor: String?,
        limit: Int = SlackLimits.historyPageSize,
        trace: SlackTraceContext = .init(),
        waitForRateLimit: Bool = true
    ) async throws -> SlackAPICallResult<SlackHistoryPage> {
        try await conversationHistory(
            connection: connection,
            channelID: channelID,
            oldest: oldest,
            latest: latest,
            cursor: cursor,
            limit: limit,
            trace: trace,
            waitForRateLimit: waitForRateLimit,
            budget: nil
        )
    }

    func conversationHistory(
        connection: SlackWorkspaceConnection,
        channelID: String,
        oldest: SlackTimestamp?,
        latest: SlackTimestamp?,
        cursor: String?,
        limit: Int = SlackLimits.historyPageSize,
        trace: SlackTraceContext = .init(),
        waitForRateLimit: Bool = true,
        budget: ScheduledBriefingBudgetLedger?
    ) async throws -> SlackAPICallResult<SlackHistoryPage> {
        guard (1...SlackLimits.historyPageSize).contains(limit),
              let channelID = SlackPrivacy.boundedIdentifier(channelID),
              isBoundedCursor(cursor)
        else { throw SlackAPIError(.invalidRequest) }
        var query = [URLQueryItem(name: "channel", value: channelID), .init(name: "limit", value: String(limit))]
        if let oldest { query.append(.init(name: "oldest", value: oldest.rawValue)) }
        if let latest { query.append(.init(name: "latest", value: latest.rawValue)) }
        if oldest != nil || latest != nil { query.append(.init(name: "inclusive", value: "false")) }
        if let cursor, !cursor.isEmpty { query.append(.init(name: "cursor", value: cursor)) }
        let response = try await perform(
            method: .conversationsHistory,
            connection: connection,
            query: query,
            trace: trace,
            waitForRateLimit: waitForRateLimit,
            budget: budget
        )
        let decoded = try decode(SlackHistoryResponse.self, from: response.data)
        guard decoded.messages.count <= limit else { throw SlackAPIError(.invalidSchema) }
        let messages = try decoded.messages.map(decodeHistoryMessage)
        return .init(
            value: .init(messages: messages, nextCursor: try boundedCursor(decoded.responseMetadata?.nextCursor), hasMore: decoded.hasMore == true),
            metadata: response.metadata
        )
    }

    func userInfo(
        connection: SlackWorkspaceConnection,
        userID: String,
        trace: SlackTraceContext = .init(),
        budget: ScheduledBriefingBudgetLedger? = nil
    ) async throws -> SlackAPICallResult<SlackMessageAuthor> {
        guard let userID = SlackPrivacy.boundedIdentifier(userID) else { throw SlackAPIError(.invalidRequest) }
        let response = try await perform(
            method: .usersInfo,
            connection: connection,
            query: [.init(name: "user", value: userID), .init(name: "include_locale", value: "false")],
            trace: trace,
            budget: budget
        )
        let decoded = try decode(SlackUserInfoResponse.self, from: response.data)
        guard let id = SlackPrivacy.boundedIdentifier(decoded.user.id), id == userID else { throw SlackAPIError(.invalidSchema) }
        let preferred = decoded.user.profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (preferred?.isEmpty == false ? preferred : decoded.user.profile?.realName) ?? decoded.user.realName ?? "Slack member"
        let author = SlackMessageAuthor(
            id: id,
            displayName: SlackPrivacy.boundedDisplayName(name, maximum: SlackLimits.maximumAuthorNameCharacters, fallback: "Slack member"),
            kind: decoded.user.isAppUser == true ? .app : (decoded.user.isBot == true ? .bot : .user),
            isDeleted: decoded.user.deleted == true
        )
        return .init(value: author, metadata: response.metadata)
    }

    func permalink(connection: SlackWorkspaceConnection, channelID: String, messageTimestamp: SlackTimestamp, trace: SlackTraceContext = .init()) async throws -> SlackAPICallResult<URL> {
        guard let channelID = SlackPrivacy.boundedIdentifier(channelID) else { throw SlackAPIError(.invalidRequest) }
        emit(.permalinkResolution, trace: trace, status: .started, reason: "slack_permalink_resolution_started", metadata: .init([
            (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)), (.channelHash, SlackPrivacy.hashIdentifier(channelID)),
        ]))
        do {
            let response = try await perform(method: .chatGetPermalink, connection: connection, query: [.init(name: "channel", value: channelID), .init(name: "message_ts", value: messageTimestamp.rawValue)], trace: trace.child())
            let decoded = try decode(SlackPermalinkResponse.self, from: response.data)
            guard let url = URL(string: decoded.permalink),
                  decoded.permalink.count <= SlackLimits.maximumPermalinkCharacters,
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host == "slack.com" || host.hasSuffix(".slack.com"),
                  url.user == nil, url.password == nil
            else { throw SlackAPIError(.invalidSchema) }
            emit(.permalinkResolution, trace: trace, status: .success, reason: "slack_permalink_resolved", metadata: .init([
                (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)), (.channelHash, SlackPrivacy.hashIdentifier(channelID)),
            ]))
            return .init(value: url, metadata: response.metadata)
        } catch {
            let failure = mapFailure(error)
            emit(.permalinkResolution, trace: trace, status: failure.code == .cancelled ? .skipped : .failed, reason: failure.reasonCode, metadata: .init([
                (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)), (.channelHash, SlackPrivacy.hashIdentifier(channelID)),
            ]))
            throw failure
        }
    }

    func cancelAll() async {
        cancellationEpoch &+= 1
        let requestIDs = activeRequestIDs
        let waits = activeWaitTasks.values
        activeRequestIDs.removeAll()
        activeWaitTasks.removeAll()
        waits.forEach { $0.cancel() }
        for requestID in requestIDs { await transport.cancel(requestID: requestID) }
    }

    private func perform(
        method: SlackAPIMethod,
        connection: SlackWorkspaceConnection,
        query: [URLQueryItem],
        trace: SlackTraceContext,
        waitForRateLimit: Bool = true,
        budget: ScheduledBriefingBudgetLedger? = nil
    ) async throws -> (data: Data, metadata: SlackAPICallMetadata) {
        let operationEpoch = cancellationEpoch
        var ledger = AttemptLedger()
        var token = try await loadToken(
            connection: connection,
            forceRefresh: false,
            trace: trace.child(),
            scheduledBudget: budget
        )

        while true {
            try checkCancellation(epoch: operationEpoch)
            let request = try makeRequest(method: method, query: query, token: token)
            try await requireScheduledSlackRequestPermit(budget)
            try checkCancellation(epoch: operationEpoch)
            let requestID = UUID()
            activeRequestIDs.insert(requestID)
            emit(.networkRequest, trace: trace, status: .started, reason: "slack_api_request_started", metadata: .init([
                (.operation, method.rawValue), (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
            ]))
            let response: SlackTransportResponse
            do {
                response = try await transport.data(for: request, requestID: requestID, responseLimit: SlackLimits.maximumResponseBytes)
                activeRequestIDs.remove(requestID)
            } catch {
                activeRequestIDs.remove(requestID)
                let failure = mapFailure(error)
                if isTransient(failure), ledger.transientRetryCount == 0 {
                    try await requireScheduledTransientRetryPermit(budget, delaySeconds: 0)
                    ledger.transientRetryCount = 1
                    emit(.networkRequest, trace: trace, status: .degraded, reason: "slack_api_transient_retry", metadata: .init([
                        (.operation, method.rawValue), (.retryCount, "1"), (.workspaceHash, SlackPrivacy.hashIdentifier(connection.id)),
                    ]))
                    continue
                }
                emit(.networkRequest, trace: trace, status: failure.code == .cancelled ? .skipped : .failed, reason: failure.reasonCode, metadata: .init([(.operation, method.rawValue)]))
                throw failure
            }

            try checkCancellation(epoch: operationEpoch)
            guard response.finalURL == request.url else { throw SlackAPIError(.redirectRejected, httpStatus: response.statusCode) }

            if response.statusCode == 429 {
                if !waitForRateLimit {
                    throw SlackAPIError(.rateLimited, httpStatus: response.statusCode, retryAfterSeconds: retryAfter(from: response.headers))
                }
                try await applyRateLimit(
                    response: response,
                    method: method,
                    workspaceID: connection.id,
                    trace: trace,
                    operationEpoch: operationEpoch,
                    ledger: &ledger,
                    budget: budget
                )
                continue
            }
            if (500...599).contains(response.statusCode), ledger.transientRetryCount == 0 {
                try await requireScheduledTransientRetryPermit(budget, delaySeconds: 0)
                ledger.transientRetryCount = 1
                emit(.networkRequest, trace: trace, status: .degraded, reason: "slack_api_server_retry", metadata: .init([
                    (.operation, method.rawValue), (.httpStatus, String(response.statusCode)), (.retryCount, "1"),
                ]))
                continue
            }
            guard (200...299).contains(response.statusCode) else {
                if [401, 403].contains(response.statusCode), ledger.credentialRefreshCount == 0 {
                    ledger.credentialRefreshCount = 1
                    token = try await loadToken(
                        connection: connection,
                        forceRefresh: true,
                        trace: trace.child(),
                        scheduledBudget: budget
                    )
                    continue
                }
                throw SlackAPIError(.httpFailure, httpStatus: response.statusCode)
            }

            try validateContentType(response.headers)
            try validateJSONBounds(response.data)
            let envelope = try decode(SlackEnvelope.self, from: response.data)
            if !envelope.ok {
                let failure = mapSlackError(envelope.error, httpStatus: response.statusCode, headers: response.headers)
                if failure.code == .tokenExpired, ledger.credentialRefreshCount == 0 {
                    ledger.credentialRefreshCount = 1
                    token = try await loadToken(
                        connection: connection,
                        forceRefresh: true,
                        trace: trace.child(),
                        scheduledBudget: budget
                    )
                    continue
                }
                if failure.code == .rateLimited {
                    if !waitForRateLimit { throw failure }
                    try await applyRateLimit(
                        response: response,
                        method: method,
                        workspaceID: connection.id,
                        trace: trace,
                        operationEpoch: operationEpoch,
                        ledger: &ledger,
                        budget: budget
                    )
                    continue
                }
                throw failure
            }
            emit(.networkRequest, trace: trace, status: .success, reason: "slack_api_request_succeeded", metadata: .init([
                (.operation, method.rawValue), (.httpStatus, String(response.statusCode)), (.responseBytes, String(response.data.count)),
            ]))
            return (response.data, metadata(from: ledger))
        }
    }

    private func applyRateLimit(
        response: SlackTransportResponse,
        method: SlackAPIMethod,
        workspaceID: String,
        trace: SlackTraceContext,
        operationEpoch: UInt64,
        ledger: inout AttemptLedger,
        budget: ScheduledBriefingBudgetLedger?
    ) async throws {
        guard ledger.rateLimitRetryCount == 0 else {
            throw SlackAPIError(.rateLimited, httpStatus: response.statusCode, retryAfterSeconds: retryAfter(from: response.headers))
        }
        guard let seconds = retryAfter(from: response.headers),
              seconds > 0,
              seconds <= SlackLimits.maximumRetryAfterSeconds,
              seconds.rounded(.down) == seconds
        else { throw SlackAPIError(.invalidRetryAfter, httpStatus: response.statusCode) }
        try await requireScheduledTransientRetryPermit(budget, delaySeconds: seconds)
        try checkCancellation(epoch: operationEpoch)
        ledger.rateLimitRetryCount = 1
        let observedAt = now()
        let rateLimitState = SlackRateLimitState(method: method, retryAfterSeconds: seconds, retryAt: observedAt.addingTimeInterval(seconds), observedAt: observedAt)
        ledger.lastRateLimitState = rateLimitState
        rateLimitSink?(workspaceID, rateLimitState)
        emit(.rateLimit, trace: trace, status: .degraded, reason: "slack_rate_limit_wait_started", metadata: .init([
            (.operation, method.rawValue), (.retryAfterSeconds, String(Int(seconds))),
        ]))
        let waitID = UUID()
        let wait = Task { try await sleeper.sleep(seconds: seconds) }
        activeWaitTasks[waitID] = wait
        do {
            try await withTaskCancellationHandler { try await wait.value } onCancel: { wait.cancel() }
            activeWaitTasks.removeValue(forKey: waitID)
            try checkCancellation(epoch: operationEpoch)
            rateLimitSink?(workspaceID, nil)
            emit(.rateLimit, trace: trace, status: .success, reason: "slack_rate_limit_wait_completed", metadata: .init([
                (.operation, method.rawValue), (.retryAfterSeconds, String(Int(seconds))),
            ]))
        } catch {
            activeWaitTasks.removeValue(forKey: waitID)
            rateLimitSink?(workspaceID, nil)
            throw SlackAPIError(.cancelled, httpStatus: response.statusCode, retryAfterSeconds: seconds)
        }
    }

    private func requireScheduledSlackRequestPermit(_ budget: ScheduledBriefingBudgetLedger?) async throws {
        guard let budget else { return }
        switch await budget.claimSlackRequest() {
        case .permitted:
            return
        case let .rejected(reasonCode):
            throw SlackAPIError.scheduledBudgetFailure(reasonCode: reasonCode)
        }
    }

    private func requireScheduledTransientRetryPermit(
        _ budget: ScheduledBriefingBudgetLedger?,
        delaySeconds: TimeInterval
    ) async throws {
        guard let budget else { return }
        switch await budget.claimTransientRetry(delaySeconds: delaySeconds) {
        case .permitted:
            return
        case let .rejected(reasonCode):
            throw SlackAPIError.scheduledBudgetFailure(reasonCode: reasonCode)
        }
    }

    private func loadToken(
        connection: SlackWorkspaceConnection,
        forceRefresh: Bool,
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> String {
        guard SlackPrivacy.boundedIdentifier(connection.teamID) != nil,
              SlackPrivacy.boundedIdentifier(connection.userID) != nil
        else { throw SlackAPIError(.invalidRequest) }
        do {
            let token = try await tokenProvider.accessToken(
                teamID: connection.teamID,
                userID: connection.userID,
                forceRefresh: forceRefresh,
                trace: trace,
                scheduledBudget: scheduledBudget
            )
            guard !token.isEmpty,
                  token.count <= 8_192,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
            else { throw SlackAPIError(.reauthorizationRequired) }
            return token
        } catch let failure as SlackAPIError {
            throw failure
        } catch {
            throw SlackAPIError(.reauthorizationRequired)
        }
    }

    private func makeRequest(method: SlackAPIMethod, query: [URLQueryItem], token: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "slack.com"
        components.path = method.path
        components.queryItems = query.isEmpty ? nil : query.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return ($0.value ?? "") < ($1.value ?? "")
        }
        guard let url = components.url else { throw SlackAPIError(.invalidRequest) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: SlackLimits.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LokiBrief/0.1", forHTTPHeaderField: "User-Agent")
        _ = try SlackEndpointPolicy.validate(request, expectedMethod: method)
        return request
    }

    private func decodeHistoryMessage(_ raw: SlackRawHistoryMessage) throws -> SlackHistoryMessage {
        guard raw.type == "message",
              let timestamp = SlackTimestamp(rawValue: raw.ts),
              raw.text.count <= SlackLimits.maximumRawMessageCharacters,
              raw.replyCount ?? 0 >= 0
        else { throw SlackAPIError(.invalidSchema) }
        return .init(
            type: raw.type,
            subtype: raw.subtype.flatMap { SlackPrivacy.boundedIdentifier($0) },
            timestamp: timestamp,
            deletedTimestamp: raw.deletedTs.flatMap(SlackTimestamp.init(rawValue:)),
            threadTimestamp: raw.threadTs.flatMap(SlackTimestamp.init(rawValue:)),
            text: raw.text,
            userID: raw.user.flatMap(SlackPrivacy.boundedIdentifier),
            botID: raw.botID.flatMap(SlackPrivacy.boundedIdentifier),
            appID: raw.appID.flatMap(SlackPrivacy.boundedIdentifier),
            username: raw.username.map { SlackPrivacy.boundedDisplayName($0, maximum: SlackLimits.maximumAuthorNameCharacters, fallback: "Slack app") },
            replyCount: min(raw.replyCount ?? 0, 1_000_000),
            editedAt: raw.edited?.ts.flatMap(SlackTimestamp.init(rawValue:))
        )
    }

    private func validateContentType(_ headers: [String: String]) throws {
        guard let value = header("Content-Type", in: headers)?.lowercased(),
              value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "application/json"
        else { throw SlackAPIError(.invalidContentType) }
    }

    private func validateJSONBounds(_ data: Data) throws {
        guard !data.isEmpty else { throw SlackAPIError(.invalidJSON) }
        guard data.count <= SlackLimits.maximumResponseBytes else { throw SlackAPIError(.responseTooLarge) }
        do {
            try SlackBoundedJSONValidator.validate(data, maximumDepth: SlackLimits.maximumJSONDepth)
        } catch SlackBoundedJSONFailure.maximumDepthExceeded {
            throw SlackAPIError(.jsonLimitExceeded)
        } catch {
            throw SlackAPIError(.invalidJSON)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw SlackAPIError(.invalidJSON)
        }
        var containers = 0
        try inspectJSON(object, depth: 1, containers: &containers)
    }

    private func inspectJSON(_ value: Any, depth: Int, containers: inout Int) throws {
        guard depth <= SlackLimits.maximumJSONDepth else { throw SlackAPIError(.jsonLimitExceeded) }
        if let dictionary = value as? [String: Any] {
            containers += 1
            guard containers <= SlackLimits.maximumJSONContainers else { throw SlackAPIError(.jsonLimitExceeded) }
            for (key, child) in dictionary {
                guard key.count <= SlackLimits.maximumIdentifierCharacters else { throw SlackAPIError(.jsonLimitExceeded) }
                try inspectJSON(child, depth: depth + 1, containers: &containers)
            }
        } else if let array = value as? [Any] {
            containers += 1
            guard containers <= SlackLimits.maximumJSONContainers else { throw SlackAPIError(.jsonLimitExceeded) }
            for child in array { try inspectJSON(child, depth: depth + 1, containers: &containers) }
        } else if let string = value as? String, string.count > SlackLimits.maximumRawMessageCharacters {
            throw SlackAPIError(.jsonLimitExceeded)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SlackAPIError(.invalidSchema) }
    }

    private func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let value = header("Retry-After", in: headers)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(value)
        else { return nil }
        return seconds
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func mapSlackError(_ value: String?, httpStatus: Int?, headers: [String: String]) -> SlackAPIError {
        let raw = value.map { String($0.prefix(120)) }
        switch raw {
        case "invalid_auth", "not_authed": return .init(.invalidAuth, httpStatus: httpStatus, slackErrorCode: raw)
        case "token_expired": return .init(.tokenExpired, httpStatus: httpStatus, slackErrorCode: raw)
        case "token_revoked", "account_inactive": return .init(.tokenRevoked, httpStatus: httpStatus, slackErrorCode: raw)
        case "missing_scope": return .init(.missingScope, httpStatus: httpStatus, slackErrorCode: raw)
        case "channel_not_found": return .init(.channelNotFound, httpStatus: httpStatus, slackErrorCode: raw)
        case "not_in_channel", "no_permission", "channel_is_limited_access": return .init(.channelAccessLost, httpStatus: httpStatus, slackErrorCode: raw)
        case "team_access_not_granted", "team_added_to_org", "org_login_required": return .init(.workspaceUnavailable, httpStatus: httpStatus, slackErrorCode: raw)
        case "ratelimited": return .init(.rateLimited, httpStatus: httpStatus, retryAfterSeconds: retryAfter(from: headers), slackErrorCode: raw)
        default: return .init(.slackFailure, httpStatus: httpStatus, slackErrorCode: raw)
        }
    }

    private func mapFailure(_ error: Error) -> SlackAPIError {
        if let failure = error as? SlackAPIError { return failure }
        if error is CancellationError { return .init(.cancelled) }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .init(.cancelled)
            case .timedOut: return .init(.timedOut)
            default: return .init(.transportFailure)
            }
        }
        return .init(.transportFailure)
    }

    private func isTransient(_ failure: SlackAPIError) -> Bool {
        [.transportFailure, .timedOut].contains(failure.code)
    }

    private func isBoundedCursor(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.count <= SlackLimits.maximumCursorCharacters && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func boundedCursor(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBoundedCursor(trimmed) else { throw SlackAPIError(.invalidSchema) }
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validatedWorkspaceURL(_ value: String?) -> URL? {
        guard let value, value.count <= SlackLimits.maximumPermalinkCharacters,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com"),
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private func checkCancellation(epoch: UInt64) throws {
        guard epoch == cancellationEpoch, !Task.isCancelled else { throw SlackAPIError(.cancelled) }
    }

    private func merge(_ metadata: SlackAPICallMetadata, into ledger: inout AttemptLedger) {
        ledger.transientRetryCount += metadata.transientRetryCount
        ledger.rateLimitRetryCount += metadata.rateLimitRetryCount
        ledger.credentialRefreshCount += metadata.credentialRefreshCount
        ledger.lastRateLimitState = metadata.rateLimitState ?? ledger.lastRateLimitState
    }

    private func metadata(from ledger: AttemptLedger) -> SlackAPICallMetadata {
        .init(
            transientRetryCount: ledger.transientRetryCount,
            rateLimitRetryCount: ledger.rateLimitRetryCount,
            credentialRefreshCount: ledger.credentialRefreshCount,
            rateLimitState: ledger.lastRateLimitState
        )
    }

    private func identityMetadata(_ connection: SlackWorkspaceConnection) -> SlackTraceMetadata {
        .init([(.workspaceHash, SlackPrivacy.hashIdentifier(connection.id))])
    }

    private func emit(_ event: SlackTraceEventName, trace: SlackTraceContext, status: SlackTraceStatus, reason: String, duration: Int? = nil, metadata: SlackTraceMetadata = .init()) {
        eventSink?(.init(
            ts: now(), event: event, traceID: trace.traceID, spanID: trace.spanID,
            parentSpanID: trace.parentSpanID, component: "slack_api_client", status: status,
            reasonCode: String(reason.prefix(120)), durationMilliseconds: duration, metadata: metadata
        ))
    }
}

private struct SlackAuthTestResponse: Decodable {
    let ok: Bool
    let url: String?
    let team: String?
    let user: String?
    let teamID: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case ok, url, team, user
        case teamID = "team_id"
        case userID = "user_id"
    }
}

private struct SlackResponseMetadata: Decodable {
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case nextCursor = "next_cursor" }
}

private struct SlackConversationsResponse: Decodable {
    let ok: Bool
    let channels: [SlackRawConversation]
    let responseMetadata: SlackResponseMetadata?
    enum CodingKeys: String, CodingKey { case ok, channels; case responseMetadata = "response_metadata" }
}

private struct SlackRawConversation: Decodable {
    let id: String
    let name: String?
    let isPrivate: Bool?
    let isMember: Bool?
    let isArchived: Bool?
    let isIM: Bool?
    let isMPIM: Bool?
    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrivate = "is_private"
        case isMember = "is_member"
        case isArchived = "is_archived"
        case isIM = "is_im"
        case isMPIM = "is_mpim"
    }
}

private struct SlackHistoryResponse: Decodable {
    let ok: Bool
    let messages: [SlackRawHistoryMessage]
    let hasMore: Bool?
    let responseMetadata: SlackResponseMetadata?
    enum CodingKeys: String, CodingKey {
        case ok, messages
        case hasMore = "has_more"
        case responseMetadata = "response_metadata"
    }
}

private struct SlackRawHistoryMessage: Decodable {
    struct Edited: Decodable { let ts: String? }
    let type: String
    let subtype: String?
    let ts: String
    let deletedTs: String?
    let threadTs: String?
    let text: String
    let user: String?
    let botID: String?
    let appID: String?
    let username: String?
    let replyCount: Int?
    let edited: Edited?
    enum CodingKeys: String, CodingKey {
        case type, subtype, ts, text, user, username, edited
        case deletedTs = "deleted_ts"
        case threadTs = "thread_ts"
        case botID = "bot_id"
        case appID = "app_id"
        case replyCount = "reply_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        ts = try container.decode(String.self, forKey: .ts)
        deletedTs = try container.decodeIfPresent(String.self, forKey: .deletedTs)
        threadTs = try container.decodeIfPresent(String.self, forKey: .threadTs)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user)
        botID = try container.decodeIfPresent(String.self, forKey: .botID)
        appID = try container.decodeIfPresent(String.self, forKey: .appID)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        replyCount = try container.decodeIfPresent(Int.self, forKey: .replyCount)
        edited = try container.decodeIfPresent(Edited.self, forKey: .edited)
    }
}

private struct SlackUserInfoResponse: Decodable {
    struct User: Decodable {
        struct Profile: Decodable {
            let displayName: String?
            let realName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name"; case realName = "real_name" }
        }
        let id: String
        let deleted: Bool?
        let isBot: Bool?
        let isAppUser: Bool?
        let realName: String?
        let profile: Profile?
        enum CodingKeys: String, CodingKey {
            case id, deleted, profile
            case isBot = "is_bot"
            case isAppUser = "is_app_user"
            case realName = "real_name"
        }
    }
    let ok: Bool
    let user: User
}

private struct SlackPermalinkResponse: Decodable {
    let ok: Bool
    let permalink: String
}
