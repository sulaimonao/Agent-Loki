import Foundation
import Network
import Security

final class BoundedFeedTransport: FeedTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [UUID: PinnedHTTPExchange] = [:]
    private var preparedRequestIDs: Set<UUID> = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    deinit {
        lock.lock(); let active = Array(exchanges.values); exchanges.removeAll(); preparedRequestIDs.removeAll(); cancelledBeforeRegistration.removeAll(); lock.unlock()
        active.forEach { $0.cancel(.init(.requestCancelled)) }
    }

    func prepare(requestID: UUID) async {
        prepareNow(requestID)
    }

    private func prepareNow(_ requestID: UUID) {
        lock.lock()
        if exchanges[requestID] == nil { preparedRequestIDs.insert(requestID) }
        lock.unlock()
    }

    func releasePreparation(requestID: UUID) async {
        releasePreparationNow(requestID)
    }

    private func releasePreparationNow(_ requestID: UUID) {
        lock.lock()
        preparedRequestIDs.remove(requestID)
        cancelledBeforeRegistration.remove(requestID)
        lock.unlock()
    }

    func data(for request: URLRequest, target: FeedValidatedTarget, requestID: UUID, responseLimit: Int, resourceTimeout: TimeInterval) async throws -> FeedTransportResponse {
        var didRegister = false
        defer {
            if !didRegister { releasePreparationNow(requestID) }
        }
        guard request.url == target.url, target.url.scheme?.lowercased() == "https", request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              FeedURLPolicy.isPublic(target.approvedAddress)
        else { throw FeedFetchFailure(.invalidURL) }
        guard responseLimit > 0, responseLimit <= FeedLimits.maximumResponseBytes else {
            throw FeedFetchFailure(.responseTooLarge)
        }
        guard resourceTimeout > 0, resourceTimeout <= FeedLimits.resourceTimeout else {
            throw FeedFetchFailure(.invalidURL)
        }
        guard !Task.isCancelled else { throw FeedFetchFailure(.requestCancelled) }

        let exchange = try PinnedHTTPExchange(request: request, target: target, responseLimit: responseLimit, resourceTimeout: resourceTimeout)
        let cancelled = register(exchange, for: requestID)
        didRegister = true
        if cancelled { exchange.cancel(.init(.requestCancelled)) }
        defer { unregister(requestID) }
        return try await withTaskCancellationHandler {
            try await exchange.run()
        } onCancel: {
            exchange.cancel(.init(.requestCancelled))
        }
    }

    func cancel(requestID: UUID) async { cancelNow(requestID) }

    private func register(_ exchange: PinnedHTTPExchange, for requestID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        exchanges[requestID] = exchange
        preparedRequestIDs.remove(requestID)
        return cancelledBeforeRegistration.remove(requestID) != nil
    }

    private func unregister(_ requestID: UUID) {
        lock.lock(); defer { lock.unlock() }
        exchanges.removeValue(forKey: requestID)
        preparedRequestIDs.remove(requestID)
        cancelledBeforeRegistration.remove(requestID)
    }

    private func cancelNow(_ requestID: UUID) {
        lock.lock()
        let exchange = exchanges[requestID]
        if exchange == nil, preparedRequestIDs.contains(requestID) { cancelledBeforeRegistration.insert(requestID) }
        lock.unlock()
        exchange?.cancel(.init(.requestCancelled))
    }
}

final class PinnedHTTPExchange: @unchecked Sendable {
    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumFramingOverheadBytes = 256 * 1_024

    private let connection: NWConnection
    private let requestData: Data
    private let responseLimit: Int
    private let responseURL: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.agentloki.LokiBrief.feed.pinned-http")
    private var buffer = Data()
    private var continuation: CheckedContinuation<FeedTransportResponse, Error>?
    private var pendingResult: Result<FeedTransportResponse, Error>?
    private var timer: DispatchSourceTimer?
    private var finished = false

    init(request: URLRequest, target: FeedValidatedTarget, responseLimit: Int, resourceTimeout: TimeInterval) throws {
        guard let originalHost = target.url.host, !originalHost.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(target.url.port ?? 443))
        else { throw FeedFetchFailure(.invalidURL) }

        let endpointHost: NWEndpoint.Host
        switch target.approvedAddress {
        case .ipv4:
            guard let address = IPv4Address(target.approvedAddress.numericHost) else { throw FeedFetchFailure(.nonPublicAddress) }
            endpointHost = .ipv4(address)
        case .ipv6:
            guard let address = IPv6Address(target.approvedAddress.numericHost) else { throw FeedFetchFailure(.nonPublicAddress) }
            endpointHost = .ipv6(address)
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, originalHost)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, min(Int(request.timeoutInterval.rounded(.up)), Int(FeedLimits.resourceTimeout)))
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .responsiveData

        connection = NWConnection(host: endpointHost, port: port, using: parameters)
        requestData = try Self.encode(request: request, target: target)
        self.responseLimit = responseLimit
        responseURL = target.url
        timeout = max(0.001, min(resourceTimeout, FeedLimits.resourceTimeout))
    }

    func run() async throws -> FeedTransportResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finished else {
                    if let result = self.pendingResult { continuation.resume(with: result) }
                    else { continuation.resume(throwing: FeedFetchFailure(.requestCancelled)) }
                    return
                }
                self.continuation = continuation
                self.start()
            }
        }
    }

    func cancel(_ failure: FeedFetchFailure) {
        queue.async { self.finish(.failure(failure)) }
    }

    static func encodedRequestForTesting(_ request: URLRequest, target: FeedValidatedTarget) throws -> Data {
        try encode(request: request, target: target)
    }

    static func decodedResponseForTesting(_ data: Data, url: URL, responseLimit: Int, endOfStream: Bool = true) throws -> FeedTransportResponse? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let target = FeedValidatedTarget(url: url, approvedAddress: .ipv4(93, 184, 216, 34))
        let exchange = try PinnedHTTPExchange(request: request, target: target, responseLimit: responseLimit, resourceTimeout: 1)
        exchange.buffer = data
        return try exchange.decodeIfComplete(endOfStream: endOfStream)
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(FeedFetchFailure(.requestTimedOut))) }
        self.timer = timer
        timer.resume()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendRequest()
            case .failed: self.finish(.failure(FeedFetchFailure(.networkUnavailable)))
            case .cancelled where !self.finished: self.finish(.failure(FeedFetchFailure(.requestCancelled)))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest() {
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(.failure(FeedFetchFailure(.networkUnavailable))) }
            else { self.receiveNext() }
        })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] content, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let content, !content.isEmpty {
                let maximumRawBytes = self.responseLimit + Self.maximumHeaderBytes + Self.maximumFramingOverheadBytes
                guard self.buffer.count <= maximumRawBytes - content.count else {
                    self.finish(.failure(FeedFetchFailure(.responseTooLarge))); return
                }
                self.buffer.append(content)
            }
            do {
                if let response = try self.decodeIfComplete(endOfStream: isComplete) {
                    self.finish(.success(response)); return
                }
            } catch {
                self.finish(.failure(error)); return
            }
            if error != nil { self.finish(.failure(FeedFetchFailure(.networkUnavailable))) }
            else if isComplete { self.finish(.failure(FeedFetchFailure(.networkUnavailable))) }
            else { self.receiveNext() }
        }
    }

    private func finish(_ result: Result<FeedTransportResponse, Error>) {
        guard !finished else { return }
        finished = true
        pendingResult = result
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func encode(request: URLRequest, target: FeedValidatedTarget) throws -> Data {
        guard request.url == target.url, let components = URLComponents(url: target.url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { throw FeedFetchFailure(.invalidURL) }
        var requestTarget = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { requestTarget += "?" + query }
        guard !requestTarget.contains("\r"), !requestTarget.contains("\n") else { throw FeedFetchFailure(.invalidURL) }

        let hostValue: String
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        if let port = components.port, port != 443 { hostValue = "\(bracketedHost):\(port)" }
        else { hostValue = bracketedHost }

        var lines = ["GET \(requestTarget) HTTP/1.1", "Host: \(hostValue)"]
        let forbidden = Set(["authorization", "proxy-authorization", "cookie", "host", "connection", "content-length", "transfer-encoding"])
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let lowered = name.lowercased()
            guard !forbidden.contains(lowered), isValidHeaderName(name), isValidHeaderValue(value) else {
                throw FeedFetchFailure(.invalidURL)
            }
            lines.append("\(name): \(value)")
        }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        guard let encoded = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw FeedFetchFailure(.invalidURL)
        }
        return encoded
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return !value.isEmpty && value.utf8.allSatisfy(allowed.contains)
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        !value.contains("\r") && !value.contains("\n") && value.utf8.allSatisfy { $0 == 0x09 || $0 >= 0x20 }
    }

    private func decodeIfComplete(endOfStream: Bool) throws -> FeedTransportResponse? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: delimiter) else {
            if buffer.count > Self.maximumHeaderBytes { throw FeedFetchFailure(.responseTooLarge) }
            return nil
        }
        guard headerRange.upperBound <= Self.maximumHeaderBytes else { throw FeedFetchFailure(.responseTooLarge) }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw FeedFetchFailure(.networkUnavailable)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw FeedFetchFailure(.networkUnavailable) }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1]), (100...599).contains(statusCode)
        else { throw FeedFetchFailure(.networkUnavailable) }
        if (100..<200).contains(statusCode) {
            guard statusCode != 101 else { throw FeedFetchFailure(.networkUnavailable) }
            buffer.removeSubrange(..<headerRange.upperBound)
            return try decodeIfComplete(endOfStream: endOfStream)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let separator = line.firstIndex(of: ":") else {
                throw FeedFetchFailure(.networkUnavailable)
            }
            let name = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidHeaderName(name), Self.isValidHeaderValue(value) else {
                throw FeedFetchFailure(.networkUnavailable)
            }
            if let existing = headers[name] { headers[name] = existing + "," + value }
            else { headers[name] = value }
        }
        if let contentEncoding = headers["content-encoding"], contentEncoding.lowercased() != "identity" {
            throw FeedFetchFailure(.contentEncodingRejected)
        }

        let body = Data(buffer[headerRange.upperBound...])
        if statusCode == 204 || statusCode == 304 {
            return .init(data: Data(), statusCode: statusCode, url: responseURL, headers: headers)
        }
        if let transferEncoding = headers["transfer-encoding"] {
            guard transferEncoding.lowercased() == "chunked" else { throw FeedFetchFailure(.networkUnavailable) }
            guard let decoded = try Self.decodeChunked(body, limit: responseLimit) else { return nil }
            return .init(data: decoded, statusCode: statusCode, url: responseURL, headers: headers)
        }
        if let lengthText = headers["content-length"] {
            guard !lengthText.contains(","), let length = Int(lengthText), length >= 0 else {
                throw FeedFetchFailure(.networkUnavailable)
            }
            guard length <= responseLimit else { throw FeedFetchFailure(.responseTooLarge) }
            if body.count < length {
                if endOfStream { throw FeedFetchFailure(.networkUnavailable) }
                return nil
            }
            return .init(data: Data(body.prefix(length)), statusCode: statusCode, url: responseURL, headers: headers)
        }
        guard body.count <= responseLimit else { throw FeedFetchFailure(.responseTooLarge) }
        guard endOfStream else { return nil }
        return .init(data: body, statusCode: statusCode, url: responseURL, headers: headers)
    }

    private static func decodeChunked(_ data: Data, limit: Int) throws -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        var decoded = Data()
        var chunkCount = 0
        while true {
            guard let lineEnd = findCRLF(in: bytes, from: index, maximumDistance: 1_024) else { return nil }
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";", maxSplits: 1)[0]
            guard !sizeText.isEmpty, sizeText.utf8.allSatisfy({ $0.isASCIIHexDigit }),
                  let size = Int(sizeText, radix: 16), size >= 0
            else { throw FeedFetchFailure(.networkUnavailable) }
            index = lineEnd + 2
            chunkCount += 1
            guard chunkCount <= 8_192 else { throw FeedFetchFailure(.responseTooLarge) }
            if size == 0 {
                if bytes.count >= index + 2, bytes[index] == 13, bytes[index + 1] == 10 { return decoded }
                guard findDoubleCRLF(in: bytes, from: index, maximumDistance: Self.maximumHeaderBytes) != nil else { return nil }
                return decoded
            }
            guard size <= limit, decoded.count <= limit - size else { throw FeedFetchFailure(.responseTooLarge) }
            guard bytes.count >= index + size + 2 else { return nil }
            decoded.append(contentsOf: bytes[index..<(index + size)])
            index += size
            guard bytes[index] == 13, bytes[index + 1] == 10 else { throw FeedFetchFailure(.networkUnavailable) }
            index += 2
        }
    }

    private static func findCRLF(in bytes: [UInt8], from start: Int, maximumDistance: Int) -> Int? {
        guard start <= bytes.count else { return nil }
        let end = min(bytes.count, start + maximumDistance + 2)
        guard end >= start + 2 else { return nil }
        for index in start..<(end - 1) where bytes[index] == 13 && bytes[index + 1] == 10 { return index }
        return nil
    }

    private static func findDoubleCRLF(in bytes: [UInt8], from start: Int, maximumDistance: Int) -> Int? {
        guard start <= bytes.count else { return nil }
        let end = min(bytes.count, start + maximumDistance + 4)
        guard end >= start + 4 else { return nil }
        for index in start..<(end - 3) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 { return index }
        return nil
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}

actor FeedRetrievalClient: FeedRetrieving {
    typealias EventSink = @Sendable (FeedTraceEvent) -> Void

    private let policy: FeedURLPolicy
    private let transport: any FeedTransporting
    private let parser: FeedParser
    private let normalizer: FeedNormalizer
    private let now: @Sendable () -> Date
    private let eventSink: EventSink?
    private var activeRequestIDs: Set<UUID> = []
    private var activeCancellationSignals: [UUID: FeedCancellationSignal] = [:]

    init(policy: FeedURLPolicy = .init(), transport: any FeedTransporting = BoundedFeedTransport(), parser: FeedParser = .init(), normalizer: FeedNormalizer = .init(), now: @escaping @Sendable () -> Date = { Date() }, eventSink: EventSink? = nil) {
        self.policy = policy
        self.transport = transport
        self.parser = parser
        self.normalizer = normalizer
        self.now = now
        self.eventSink = eventSink
    }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext = .init()) async throws -> FeedFetchResult {
        try await fetch(subscription, trace: trace, progress: { _ in })
    }

    func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext,
        budget: ScheduledBriefingBudgetLedger
    ) async throws -> FeedFetchResult {
        try await fetch(subscription, trace: trace, progress: { _ in }, scheduledBudget: budget)
    }

    func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext,
        progress: @escaping FeedProgressHandler
    ) async throws -> FeedFetchResult {
        try await fetch(subscription, trace: trace, progress: progress, scheduledBudget: nil)
    }

    private func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext,
        progress: @escaping FeedProgressHandler,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> FeedFetchResult {
        let scheduledRemainingDuration = await scheduledBudget?.remainingDurationSeconds()
        if scheduledBudget != nil, scheduledRemainingDuration ?? 0 <= 0 {
            await scheduledBudget?.markDurationExhausted()
            throw FeedFetchFailure(.scheduledDurationBudgetExhausted)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let requestedResourceDuration = max(0.001, min(subscription.policy.resourceTimeout, FeedLimits.resourceTimeout))
        let scheduledDurationIsLimiting = scheduledRemainingDuration.map { $0 <= requestedResourceDuration } ?? false
        let resourceDuration = min(requestedResourceDuration, scheduledRemainingDuration ?? requestedResourceDuration)
        let deadlineUptime = started + max(0.001, resourceDuration)
        let attemptedAt = now()
        let operationID = UUID()
        let cancellationSignal = FeedCancellationSignal()
        activeCancellationSignals[operationID] = cancellationSignal
        defer { activeCancellationSignals.removeValue(forKey: operationID) }
        emit("feed.refresh", trace: trace, status: .started, reason: "feed_refresh_started", metadata: ["subscription_id": subscription.id])
        var requestID: UUID?
        do {
            guard subscription.enabled else { throw FeedFetchFailure(.requestCancelled, message: "The feed is disabled.") }
            await progress(.validating)
            try ensureActive(cancellationSignal)
            let policyTrace = childTrace(of: trace)
            let initialTarget: FeedValidatedTarget
            do {
                initialTarget = try await policy.validate(
                    subscription.canonicalURL,
                    deadlineUptime: deadlineUptime,
                    cancellationSignal: cancellationSignal
                )
            }
            catch {
                let failure = await mapScheduledBudgetFailure(
                    error,
                    budget: scheduledBudget,
                    deadlineUptime: deadlineUptime,
                    scheduledDurationIsLimiting: scheduledDurationIsLimiting
                )
                emit("feed.url_validation", trace: policyTrace, status: failure.code == .requestCancelled ? .skipped : .failed, reason: failure.reasonCode)
                throw failure
            }
            var target = initialTarget
            emit("feed.url_validation", trace: policyTrace, status: .success, reason: "feed_url_policy_accepted")
            var redirectCount = 0
            var conditionalHeaders = true
            while true {
                try Task.checkCancellation()
                await progress(.fetching)
                try ensureActive(cancellationSignal)
                let budgetPermit = try await claimScheduledFeedRequest(scheduledBudget)
                let identifier = UUID()
                await transport.prepare(requestID: identifier)
                let remainingResourceTime: TimeInterval
                do {
                    try ensureActive(cancellationSignal)
                    let operationRemaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
                    remainingResourceTime = min(operationRemaining, budgetPermit?.remainingDurationSeconds ?? operationRemaining)
                    guard remainingResourceTime > 0 else {
                        throw FeedFetchFailure(scheduledBudget == nil ? .requestTimedOut : .scheduledDurationBudgetExhausted)
                    }
                } catch {
                    await transport.releasePreparation(requestID: identifier)
                    throw error
                }
                requestID = identifier; activeRequestIDs.insert(identifier)
                let networkTrace = childTrace(of: trace)
                let requestTimeout = scheduledBudget == nil
                    ? subscription.policy.requestTimeout
                    : min(subscription.policy.requestTimeout, remainingResourceTime)
                var request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
                request.httpMethod = "GET"
                request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/json;q=0.9, application/xml;q=0.8, text/xml;q=0.7", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("LokiBrief/0.2", forHTTPHeaderField: "User-Agent")
                if conditionalHeaders {
                    if let eTag = subscription.eTag, !eTag.isEmpty { request.setValue(String(eTag.prefix(1_024)), forHTTPHeaderField: "If-None-Match") }
                    if let modified = subscription.lastModified, !modified.isEmpty { request.setValue(String(modified.prefix(1_024)), forHTTPHeaderField: "If-Modified-Since") }
                }
                emit("feed.network_request", trace: networkTrace, status: .started, reason: "feed_network_request_started", metadata: ["redirect_count": String(redirectCount), "conditional": String(conditionalHeaders)])
                let response: FeedTransportResponse
                do {
                    response = try await transport.data(
                        for: request,
                        target: target,
                        requestID: identifier,
                        responseLimit: subscription.policy.maximumResponseBytes,
                        resourceTimeout: remainingResourceTime
                    )
                    try ensureActive(cancellationSignal)
                    guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
                        throw FeedFetchFailure(.requestTimedOut)
                    }
                }
                catch {
                    activeRequestIDs.remove(identifier); requestID = nil
                    let failure = await mapScheduledBudgetFailure(
                        error,
                        budget: scheduledBudget,
                        deadlineUptime: deadlineUptime,
                        scheduledDurationIsLimiting: scheduledDurationIsLimiting
                    )
                    emit("feed.network_request", trace: networkTrace, status: failure.code == .requestCancelled ? .skipped : .failed, reason: failure.reasonCode)
                    throw failure
                }
                activeRequestIDs.remove(identifier); requestID = nil
                let isRedirect = (300..<400).contains(response.statusCode) && response.statusCode != 304
                emit("feed.network_request", trace: networkTrace, status: .success, reason: isRedirect ? "feed_redirect_received" : "feed_network_response_received", metadata: ["http_status": String(response.statusCode), "response_bytes": String(response.data.count)])

                if isRedirect {
                    guard redirectCount < subscription.policy.maximumRedirects else { throw FeedFetchFailure(.redirectLimitExceeded) }
                    guard let location = response.headers["location"], let redirected = URL(string: location, relativeTo: target.url)?.absoluteURL else {
                        throw FeedFetchFailure(.redirectTargetRejected)
                    }
                    let previousHost = target.url.host?.lowercased()
                    let redirectTrace = childTrace(of: trace)
                    do {
                        target = try await policy.validate(
                            redirected,
                            deadlineUptime: deadlineUptime,
                            cancellationSignal: cancellationSignal
                        )
                    }
                    catch {
                        let failure = await mapScheduledBudgetFailure(
                            error,
                            budget: scheduledBudget,
                            deadlineUptime: deadlineUptime,
                            scheduledDurationIsLimiting: scheduledDurationIsLimiting
                        )
                        let preservedFailureCodes: Set<FeedFetchFailureCode> = [.dnsResolutionTimedOut, .requestCancelled]
                        let scheduledFailureCodes: Set<FeedFetchFailureCode> = [.scheduledDurationBudgetExhausted]
                        let reportedFailure = preservedFailureCodes.union(scheduledFailureCodes).contains(failure.code) ? failure : FeedFetchFailure(.redirectTargetRejected)
                        emit("feed.redirect_validation", trace: redirectTrace, status: reportedFailure.code == .requestCancelled ? .skipped : .failed, reason: reportedFailure.reasonCode)
                        if preservedFailureCodes.union(scheduledFailureCodes).contains(failure.code) { throw failure }
                        throw FeedFetchFailure(.redirectTargetRejected)
                    }
                    emit("feed.redirect_validation", trace: redirectTrace, status: .success, reason: "feed_redirect_target_accepted", metadata: ["redirect_count": String(redirectCount + 1)])
                    redirectCount += 1
                    conditionalHeaders = previousHost == target.url.host?.lowercased()
                    continue
                }

                let completedAt = now()
                if response.statusCode == 304 {
                    var updated = subscription
                    updated.canonicalURL = target.url
                    updated.lastAttemptedAt = attemptedAt; updated.lastSuccessfulAt = completedAt; updated.lastHTTPStatus = 304
                    updated.eTag = boundedValidator(response.headers["etag"]) ?? subscription.eTag
                    updated.lastModified = boundedValidator(response.headers["last-modified"]) ?? subscription.lastModified
                    updated.state = .connected; updated.failure = nil; updated.updatedAt = completedAt
                    let record = FeedFetchRecord(id: fetchIdentifier(subscriptionID: subscription.id, date: completedAt, status: 304), subscriptionID: subscription.id, traceID: trace.traceID, attemptedAt: attemptedAt, completedAt: completedAt, httpStatus: 304, responseByteCount: response.data.count, parsedEntryCount: 0, finalURL: target.url, eTag: updated.eTag, lastModified: updated.lastModified, wasNotModified: true)
                    await progress(.complete)
                    try ensureActive(cancellationSignal)
                    emit("feed.refresh", trace: trace, status: .success, reason: "feed_not_modified", duration: elapsed(since: started), metadata: ["redirect_count": String(redirectCount)])
                    return .init(subscription: updated, entries: [], record: record, warnings: [])
                }
                if response.statusCode == 401 || response.statusCode == 407 { throw FeedFetchFailure(.authenticationRejected, httpStatus: response.statusCode) }
                guard response.statusCode == 200 else { throw FeedFetchFailure(.unexpectedHTTPStatus, httpStatus: response.statusCode) }
                guard !response.data.isEmpty else { throw FeedFetchFailure(.emptyResponse) }
                await progress(.parsing)
                try ensureActive(cancellationSignal)
                let parseTrace = childTrace(of: trace)
                let parseResult: FeedParseResult
                do { parseResult = try parser.parse(response.data, sourceURL: target.url) }
                catch {
                    emit("feed.parse", trace: parseTrace, status: .failed, reason: map(error).reasonCode)
                    throw error
                }
                emit("feed.parse", trace: parseTrace, status: .success, reason: "feed_parse_succeeded", metadata: ["format": parseResult.format.rawValue, "parsed_entry_count": String(parseResult.entries.count)])
                var resolvedSubscription = subscription
                resolvedSubscription.canonicalURL = target.url
                await progress(.normalizing)
                try ensureActive(cancellationSignal)
                let normalizationTrace = childTrace(of: trace)
                let entries = normalizer.normalize(parseResult, subscription: resolvedSubscription, retrievedAt: completedAt)
                guard !entries.isEmpty else {
                    emit("feed.normalize", trace: normalizationTrace, status: .failed, reason: FeedFetchFailureCode.noEntries.rawValue)
                    throw FeedFetchFailure(.noEntries)
                }
                emit("feed.normalize", trace: normalizationTrace, status: .success, reason: "feed_normalization_succeeded", metadata: ["retained_entry_count": String(entries.count)])
                var updated = resolvedSubscription
                updated.title = subscription.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parseResult.feedTitle : subscription.title
                updated.format = parseResult.format; updated.lastAttemptedAt = attemptedAt; updated.lastSuccessfulAt = completedAt
                updated.lastHTTPStatus = 200; updated.eTag = boundedValidator(response.headers["etag"]); updated.lastModified = boundedValidator(response.headers["last-modified"])
                updated.state = .connected; updated.failure = nil; updated.updatedAt = completedAt
                let record = FeedFetchRecord(id: fetchIdentifier(subscriptionID: subscription.id, date: completedAt, status: 200), subscriptionID: subscription.id, traceID: trace.traceID, attemptedAt: attemptedAt, completedAt: completedAt, httpStatus: 200, responseByteCount: response.data.count, parsedEntryCount: entries.count, finalURL: target.url, eTag: updated.eTag, lastModified: updated.lastModified, wasNotModified: false)
                await progress(.complete)
                try ensureActive(cancellationSignal)
                emit("feed.refresh", trace: trace, status: .success, reason: "feed_refresh_succeeded", duration: elapsed(since: started), metadata: ["entry_count": String(entries.count), "redirect_count": String(redirectCount), "format": parseResult.format.rawValue])
                return .init(subscription: updated, entries: entries, record: record, warnings: parseResult.warnings)
            }
        } catch {
            if let requestID { activeRequestIDs.remove(requestID); await transport.cancel(requestID: requestID) }
            let failure = await mapScheduledBudgetFailure(
                error,
                budget: scheduledBudget,
                deadlineUptime: deadlineUptime,
                scheduledDurationIsLimiting: scheduledDurationIsLimiting
            )
            emit("feed.refresh", trace: trace, status: failure.code == .requestCancelled ? .skipped : .failed, reason: failure.reasonCode, duration: elapsed(since: started))
            throw failure
        }
    }

    func cancelAll() async {
        let cancellationSignals = Array(activeCancellationSignals.values)
        activeCancellationSignals.removeAll()
        cancellationSignals.forEach { $0.cancel() }
        let identifiers = activeRequestIDs
        activeRequestIDs.removeAll()
        for identifier in identifiers { await transport.cancel(requestID: identifier) }
    }

    private func map(_ error: Error) -> FeedFetchFailure {
        if let failure = error as? FeedFetchFailure { return failure }
        if error is CancellationError { return .init(.requestCancelled) }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .init(.requestCancelled)
            case .timedOut: return .init(.requestTimedOut)
            case .userAuthenticationRequired, .userCancelledAuthentication: return .init(.authenticationRejected)
            default: return .init(.networkUnavailable)
            }
        }
        return .init(.networkUnavailable)
    }

    private func claimScheduledFeedRequest(
        _ budget: ScheduledBriefingBudgetLedger?
    ) async throws -> ScheduledBriefingBudgetPermit? {
        guard let budget else { return nil }
        switch await budget.claimFeedRequest() {
        case let .permitted(permit):
            return permit
        case let .rejected(reasonCode):
            if reasonCode == ScheduledBriefingBudgetReason.durationExhausted {
                throw FeedFetchFailure(.scheduledDurationBudgetExhausted)
            }
            throw FeedFetchFailure(.scheduledRequestBudgetExhausted)
        }
    }

    private func mapScheduledBudgetFailure(
        _ error: Error,
        budget: ScheduledBriefingBudgetLedger?,
        deadlineUptime: TimeInterval,
        scheduledDurationIsLimiting: Bool
    ) async -> FeedFetchFailure {
        let failure = map(error)
        guard let budget,
              failure.code == .requestTimedOut || failure.code == .dnsResolutionTimedOut
        else { return failure }
        let budgetExpired = await budget.remainingDurationSeconds() <= 0
        let scheduledDeadlineExpired = scheduledDurationIsLimiting && ProcessInfo.processInfo.systemUptime >= deadlineUptime
        return budgetExpired || scheduledDeadlineExpired ? .init(.scheduledDurationBudgetExhausted) : failure
    }

    private func fetchIdentifier(subscriptionID: String, date: Date, status: Int) -> String {
        "fetch-\(subscriptionID)-\(Int(date.timeIntervalSince1970 * 1_000))-\(status)"
    }

    private func boundedValidator(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(1_024))
    }

    private func ensureActive(_ cancellationSignal: FeedCancellationSignal) throws {
        guard !Task.isCancelled, !cancellationSignal.isCancelled else {
            throw FeedFetchFailure(.requestCancelled)
        }
    }

    private func elapsed(since start: TimeInterval) -> Int {
        max(0, min(Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), 120_000))
    }

    private func emit(_ event: String, trace: FeedTraceContext, status: FeedTraceStatus, reason: String, duration: Int? = nil, metadata: [String: String] = [:]) {
        let safeMetadata = Dictionary(uniqueKeysWithValues: metadata.prefix(12).map { (String($0.key.prefix(64)), String($0.value.prefix(160))) })
        eventSink?(.init(event: String(event.prefix(120)), traceID: String(trace.traceID.prefix(160)), spanID: String(trace.spanID.prefix(160)), parentSpanID: trace.parentSpanID.map { String($0.prefix(160)) }, component: "feed_retrieval", status: status, reasonCode: String(reason.prefix(120)), durationMilliseconds: duration, metadata: safeMetadata))
    }

    private func childTrace(of parent: FeedTraceContext) -> FeedTraceContext {
        .init(traceID: parent.traceID, spanID: UUID().uuidString.lowercased(), parentSpanID: parent.spanID)
    }
}
