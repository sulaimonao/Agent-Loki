import Darwin
import Foundation

struct SystemFeedHostResolver: FeedHostResolving {
    func resolve(host: String) async throws -> [FeedResolvedAddress] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            guard status == 0, let first = result else {
                throw FeedFetchFailure(.dnsResolutionFailed)
            }
            defer { freeaddrinfo(first) }

            var addresses: Set<FeedResolvedAddress> = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor?.pointee {
                if info.ai_family == AF_INET, let raw = info.ai_addr {
                    let value = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
                    }
                    addresses.insert(.ipv4(
                        UInt8((value >> 24) & 0xff),
                        UInt8((value >> 16) & 0xff),
                        UInt8((value >> 8) & 0xff),
                        UInt8(value & 0xff)
                    ))
                } else if info.ai_family == AF_INET6, let raw = info.ai_addr {
                    var address = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: &address) { Array($0) }
                    addresses.insert(.ipv6(bytes))
                }
                cursor = info.ai_next
            }
            guard !addresses.isEmpty else { throw FeedFetchFailure(.dnsResolutionFailed) }
            return addresses.sorted { String(describing: $0) < String(describing: $1) }
        }.value
    }
}

struct FeedURLPolicy: Sendable {
    let resolver: any FeedHostResolving

    init(resolver: any FeedHostResolving = SystemFeedHostResolver()) {
        self.resolver = resolver
    }

    func validate(
        _ input: URL,
        deadlineUptime: TimeInterval? = nil,
        cancellationSignal: FeedCancellationSignal? = nil
    ) async throws -> FeedValidatedTarget {
        guard !Task.isCancelled, cancellationSignal?.isCancelled != true else {
            throw FeedFetchFailure(.requestCancelled)
        }
        guard input.absoluteString.count <= FeedLimits.maximumURLCharacters else {
            throw FeedFetchFailure(.invalidURL)
        }
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false) else {
            throw FeedFetchFailure(.invalidURL)
        }
        guard components.scheme?.lowercased() == "https" else {
            throw FeedFetchFailure(.forbiddenScheme)
        }
        guard components.user == nil, components.password == nil else {
            throw FeedFetchFailure(.credentialsForbidden)
        }
        guard let componentHost = components.host?.lowercased(), !componentHost.isEmpty else {
            throw FeedFetchFailure(.missingHost)
        }
        let rawHost: String
        if componentHost.hasPrefix("["), componentHost.hasSuffix("]") {
            rawHost = String(componentHost.dropFirst().dropLast())
        } else {
            rawHost = componentHost
        }
        guard !rawHost.contains("%") else { throw FeedFetchFailure(.nonPublicAddress) }
        guard components.port != 11_434 else {
            throw FeedFetchFailure(.localHostForbidden)
        }
        try rejectLocalHostname(rawHost)

        let approvedAddresses: [FeedResolvedAddress]
        if let literal = Self.parseLiteral(rawHost) {
            guard Self.isPublic(literal) else { throw FeedFetchFailure(.nonPublicAddress) }
            approvedAddresses = [literal]
        } else {
            if Self.looksNumeric(rawHost) { throw FeedFetchFailure(.numericHostRejected) }
            let addresses: [FeedResolvedAddress]
            let effectiveDeadline = deadlineUptime ?? ProcessInfo.processInfo.systemUptime + FeedLimits.resourceTimeout
            guard effectiveDeadline > ProcessInfo.processInfo.systemUptime else {
                throw FeedFetchFailure(.dnsResolutionTimedOut)
            }
            let signal = cancellationSignal ?? FeedCancellationSignal()
            guard !Task.isCancelled, !signal.isCancelled else {
                throw FeedFetchFailure(.requestCancelled)
            }
            do {
                addresses = try await FeedResolutionAttempt(
                    resolver: resolver,
                    host: rawHost,
                    deadlineUptime: effectiveDeadline,
                    cancellationSignal: signal
                ).run()
            }
            catch let failure as FeedFetchFailure { throw failure }
            catch is CancellationError { throw FeedFetchFailure(.requestCancelled) }
            catch { throw FeedFetchFailure(.dnsResolutionFailed) }
            guard !Task.isCancelled, !signal.isCancelled else {
                throw FeedFetchFailure(.requestCancelled)
            }
            guard ProcessInfo.processInfo.systemUptime < effectiveDeadline else {
                throw FeedFetchFailure(.dnsResolutionTimedOut)
            }
            guard addresses.count <= FeedLimits.maximumResolvedAddresses else {
                throw FeedFetchFailure(.dnsAddressLimitExceeded)
            }
            guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublic) else {
                throw FeedFetchFailure(.nonPublicAddress)
            }
            approvedAddresses = Array(Set(addresses)).sorted { $0.sortKey < $1.sortKey }
        }

        components.scheme = "https"
        components.host = rawHost
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        guard let canonical = components.url, canonical.scheme == "https",
              canonical.absoluteString.count <= FeedLimits.maximumURLCharacters else {
            throw FeedFetchFailure(.invalidURL)
        }
        guard let approvedAddress = approvedAddresses.first else {
            throw FeedFetchFailure(.dnsResolutionFailed)
        }
        return FeedValidatedTarget(url: canonical, approvedAddress: approvedAddress)
    }

    private func rejectLocalHostname(_ host: String) throws {
        let exact = ["localhost", "localhost.localdomain", "ip6-localhost", "broadcasthost"]
        let suffixes = [".localhost", ".local", ".localdomain", ".internal", ".lan", ".home"]
        guard !exact.contains(host), !suffixes.contains(where: host.hasSuffix) else {
            throw FeedFetchFailure(.localHostForbidden)
        }
    }

    static func parseLiteral(_ host: String) -> FeedResolvedAddress? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            return .ipv4(
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            )
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return .ipv6(bytes)
        }
        return nil
    }

    static func looksNumeric(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasPrefix("0x") { return true }
        return !lowered.isEmpty && lowered.allSatisfy { $0.isNumber || $0 == "." || $0 == "x" }
    }

    static func isPublic(_ address: FeedResolvedAddress) -> Bool {
        switch address {
        case let .ipv4(a, b, c, _):
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && ((b == 0 && c == 0) || b == 168) { return false }
            if a == 192 && b == 0 && c == 2 { return false }
            if a == 192 && b == 88 && c == 99 { return false }
            if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            return true
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
            if bytes[0] & 0xfe == 0xfc { return false }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return false }
            if bytes[0] == 0xff { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] & 0xfe == 0 { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isPublic(.ipv4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return bytes[0] & 0xe0 == 0x20
        }
    }
}

private final class FeedResolutionAttempt: @unchecked Sendable {
    private typealias ResolutionResult = Result<[FeedResolvedAddress], Error>

    private let resolver: any FeedHostResolving
    private let host: String
    private let deadlineUptime: TimeInterval
    private let cancellationSignal: FeedCancellationSignal
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[FeedResolvedAddress], Error>?
    private var completedResult: ResolutionResult?
    private var started = false
    private var resolutionTask: Task<Void, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var cancellationRegistration: UUID?

    init(
        resolver: any FeedHostResolving,
        host: String,
        deadlineUptime: TimeInterval,
        cancellationSignal: FeedCancellationSignal
    ) {
        self.resolver = resolver
        self.host = host
        self.deadlineUptime = deadlineUptime
        self.cancellationSignal = cancellationSignal
    }

    func run() async throws -> [FeedResolvedAddress] {
        try await withTaskCancellationHandler {
            start()
            return try await withCheckedThrowingContinuation { install($0) }
        } onCancel: {
            finish(.failure(FeedFetchFailure(.requestCancelled)))
        }
    }

    private func install(_ newContinuation: CheckedContinuation<[FeedResolvedAddress], Error>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            newContinuation.resume(with: completedResult)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    private func start() {
        lock.lock()
        guard !started, completedResult == nil else { lock.unlock(); return }
        started = true
        lock.unlock()

        let registration = cancellationSignal.register { [weak self] in
            self?.finish(.failure(FeedFetchFailure(.requestCancelled)))
        }
        lock.lock()
        let shouldRetainRegistration = completedResult == nil
        if shouldRetainRegistration { cancellationRegistration = registration }
        lock.unlock()
        if !shouldRetainRegistration { cancellationSignal.unregister(registration) }

        let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            finish(.failure(FeedFetchFailure(.dnsResolutionTimedOut)))
            return
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(FeedFetchFailure(.dnsResolutionTimedOut)))
        }
        lock.lock()
        let shouldScheduleTimeout = completedResult == nil
        if shouldScheduleTimeout { self.timeoutWorkItem = timeoutWorkItem }
        lock.unlock()
        if shouldScheduleTimeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: timeoutWorkItem)
        }

        lock.lock()
        let shouldStartResolution = completedResult == nil
        lock.unlock()
        guard shouldStartResolution else { return }

        let resolver = resolver
        let host = host
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let addresses = try await resolver.resolve(host: host)
                self?.finishResolution(.success(addresses))
            } catch {
                self?.finishResolution(.failure(error))
            }
        }
        lock.lock()
        let shouldRetainTask = completedResult == nil
        if shouldRetainTask { resolutionTask = task }
        lock.unlock()
        if !shouldRetainTask { task.cancel() }
    }

    private func finishResolution(_ result: ResolutionResult) {
        finish(result, enforcingResolutionBoundary: true)
    }

    private func finish(_ proposedResult: ResolutionResult, enforcingResolutionBoundary: Bool = false) {
        lock.lock()
        guard completedResult == nil else { lock.unlock(); return }
        let result: ResolutionResult
        if enforcingResolutionBoundary, cancellationSignal.isCancelled || Task.isCancelled {
            result = .failure(FeedFetchFailure(.requestCancelled))
        } else if enforcingResolutionBoundary, ProcessInfo.processInfo.systemUptime >= deadlineUptime {
            result = .failure(FeedFetchFailure(.dnsResolutionTimedOut))
        } else {
            result = proposedResult
        }
        completedResult = result
        let pendingContinuation = continuation
        continuation = nil
        let pendingTask = resolutionTask
        resolutionTask = nil
        let pendingTimeout = timeoutWorkItem
        timeoutWorkItem = nil
        let registration = cancellationRegistration
        cancellationRegistration = nil
        lock.unlock()

        pendingTimeout?.cancel()
        pendingTask?.cancel()
        cancellationSignal.unregister(registration)
        pendingContinuation?.resume(with: result)
    }
}

extension FeedResolvedAddress {
    var sortKey: String {
        switch self {
        case let .ipv4(a, b, c, d):
            return String(format: "4-%03d-%03d-%03d-%03d", a, b, c, d)
        case let .ipv6(bytes):
            return "6-" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    var numericHost: String {
        switch self {
        case let .ipv4(a, b, c, d):
            return "\(a).\(b).\(c).\(d)"
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return "::" }
            let words = stride(from: 0, to: 16, by: 2).map {
                UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
            var bestStart: Int?
            var bestLength = 0
            var index = 0
            while index < words.count {
                guard words[index] == 0 else { index += 1; continue }
                let start = index
                while index < words.count, words[index] == 0 { index += 1 }
                let length = index - start
                if length >= 2, length > bestLength {
                    bestStart = start
                    bestLength = length
                }
            }
            guard let bestStart else {
                return words.map { String($0, radix: 16) }.joined(separator: ":")
            }
            let left = words[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
            let right = words[(bestStart + bestLength)...].map { String($0, radix: 16) }.joined(separator: ":")
            if left.isEmpty, right.isEmpty { return "::" }
            if left.isEmpty { return "::" + right }
            if right.isEmpty { return left + "::" }
            return left + "::" + right
        }
    }
}
