import Foundation

enum FeedLimits {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30
    static let maximumRedirects = 5
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumParserBytes = maximumResponseBytes
    static let maximumParsedEntries = 500
    static let maximumRetainedEntriesPerFeed = 200
    static let defaultRetentionDays = 30
    static let maximumFetchRecordsPerFeed = 100
    static let maximumBriefHistoryRecords = 365
    static let briefHistoryRetentionDays = 365
    static let maximumGenerationProvenanceRecords = 365
    static let maximumConcurrentRefreshes = 4
    static let maximumResolvedAddresses = 32
    static let maximumURLCharacters = 4_096
    static let maximumXMLDepth = 64
    static let maximumTextCharacters = 32_000
    static let maximumTitleCharacters = 500
    static let maximumAuthorCharacters = 300
}

enum FeedFormat: String, Codable, CaseIterable, Sendable {
    case rss2
    case atom1
    case jsonFeed11
    case unknown
}

enum FeedSubscriptionState: String, Codable, CaseIterable, Sendable {
    case savedUnavailable
    case connected
    case disabled
    case validating
    case refreshing
    case degraded
    case error
}

enum FeedRefreshState: String, Codable, CaseIterable, Sendable {
    case idle
    case validating
    case fetching
    case parsing
    case normalizing
    case assembling
    case generatingLocally
    case complete
    case partial
    case cancelled
    case failed
}

enum FeedFetchFailureCode: String, Codable, CaseIterable, Sendable {
    case invalidURL = "feed_invalid_url"
    case forbiddenScheme = "feed_forbidden_scheme"
    case missingHost = "feed_missing_host"
    case credentialsForbidden = "feed_credentials_forbidden"
    case localHostForbidden = "feed_local_host_forbidden"
    case nonPublicAddress = "feed_non_public_address"
    case numericHostRejected = "feed_ambiguous_numeric_host"
    case dnsResolutionFailed = "feed_dns_resolution_failed"
    case dnsResolutionTimedOut = "feed_dns_resolution_timed_out"
    case dnsAddressLimitExceeded = "feed_dns_address_limit_exceeded"
    case redirectLimitExceeded = "feed_redirect_limit_exceeded"
    case redirectTargetRejected = "feed_redirect_target_rejected"
    case scheduledRequestBudgetExhausted = "scheduled_feed_request_budget_exhausted"
    case scheduledDurationBudgetExhausted = "scheduled_briefing_duration_budget_exhausted"
    case authenticationRejected = "feed_authentication_rejected"
    case requestTimedOut = "feed_request_timed_out"
    case requestCancelled = "feed_request_cancelled"
    case networkUnavailable = "feed_network_unavailable"
    case responseTooLarge = "feed_response_too_large"
    case contentEncodingRejected = "feed_content_encoding_rejected"
    case unexpectedHTTPStatus = "feed_unexpected_http_status"
    case emptyResponse = "feed_empty_response"
    case unsupportedFormat = "feed_unsupported_format"
    case malformedXML = "feed_malformed_xml"
    case malformedJSON = "feed_malformed_json"
    case externalEntityRejected = "feed_external_entity_rejected"
    case parserLimitExceeded = "feed_parser_limit_exceeded"
    case noEntries = "feed_no_entries"
    case invalidEntry = "feed_invalid_entry"
}

struct FeedFetchFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: FeedFetchFailureCode
    let message: String
    let httpStatus: Int?

    init(_ code: FeedFetchFailureCode, message: String? = nil, httpStatus: Int? = nil) {
        self.code = code
        self.message = message ?? code.defaultMessage
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }
    var errorDescription: String? { message }
}

private extension FeedFetchFailureCode {
    var defaultMessage: String {
        switch self {
        case .invalidURL: "Enter a valid public HTTPS feed URL."
        case .forbiddenScheme: "Only HTTPS feed URLs are supported."
        case .missingHost: "The feed URL must include a public host."
        case .credentialsForbidden: "Credential-bearing feed URLs are not supported."
        case .localHostForbidden: "Local and loopback feed targets are not permitted."
        case .nonPublicAddress: "The feed host resolved to a non-public address."
        case .numericHostRejected: "Ambiguous numeric host spellings are not permitted."
        case .dnsResolutionFailed: "The feed host could not be resolved."
        case .dnsResolutionTimedOut: "Feed host validation timed out before DNS policy checks completed."
        case .dnsAddressLimitExceeded: "The feed host returned too many addresses to validate safely."
        case .redirectLimitExceeded: "The feed exceeded the five-redirect limit."
        case .redirectTargetRejected: "A feed redirect targeted a prohibited URL."
        case .scheduledRequestBudgetExhausted: "The scheduled briefing exhausted its feed-request budget."
        case .scheduledDurationBudgetExhausted: "The scheduled briefing exhausted its total-duration budget."
        case .authenticationRejected: "Authenticated feeds are not supported."
        case .requestTimedOut: "The feed request timed out."
        case .requestCancelled: "The feed request was cancelled."
        case .networkUnavailable: "The feed could not be reached."
        case .responseTooLarge: "The feed exceeded the 2 MiB response limit."
        case .contentEncodingRejected: "The feed used an unrequested content encoding."
        case .unexpectedHTTPStatus: "The feed returned an unsuccessful HTTP response."
        case .emptyResponse: "The feed returned an empty response."
        case .unsupportedFormat: "The response is not supported RSS, Atom, or JSON Feed."
        case .malformedXML: "The XML feed is malformed."
        case .malformedJSON: "The JSON Feed is malformed."
        case .externalEntityRejected: "The XML feed declared a prohibited DTD or entity."
        case .parserLimitExceeded: "The feed exceeded a parser safety limit."
        case .noEntries: "The feed contained no usable entries."
        case .invalidEntry: "The feed contained an invalid entry."
        }
    }
}

struct FeedFetchPolicy: Codable, Hashable, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let maximumRedirects: Int
    let maximumResponseBytes: Int
    let maximumRetainedEntries: Int
    let retentionDays: Int

    static let `default` = FeedFetchPolicy(
        requestTimeout: FeedLimits.requestTimeout,
        resourceTimeout: FeedLimits.resourceTimeout,
        maximumRedirects: FeedLimits.maximumRedirects,
        maximumResponseBytes: FeedLimits.maximumResponseBytes,
        maximumRetainedEntries: FeedLimits.maximumRetainedEntriesPerFeed,
        retentionDays: FeedLimits.defaultRetentionDays
    )
}

struct FeedSubscription: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var canonicalURL: URL
    var enabled: Bool
    var format: FeedFormat
    var lastAttemptedAt: Date?
    var lastSuccessfulAt: Date?
    var lastHTTPStatus: Int?
    var eTag: String?
    var lastModified: String?
    var state: FeedSubscriptionState
    var failure: FeedFetchFailure?
    var policy: FeedFetchPolicy
    var weight: Double
    let createdAt: Date
    var updatedAt: Date
}

struct FeedEntryIdentity: Codable, Hashable, Sendable {
    enum Basis: String, Codable, Sendable { case upstreamIdentifier, canonicalURL, titleAndDate, boundedFallback }
    let value: String
    let basis: Basis
}

struct FeedEntryProvenance: Codable, Hashable, Sendable {
    let subscriptionID: String
    let feedURL: URL
    let format: FeedFormat
    let upstreamIdentifier: String?
    let retrievedAt: Date
    let originalPosition: Int
}

struct ParsedFeedEntry: Codable, Hashable, Sendable {
    let title: String?
    let summary: String?
    let url: URL?
    let author: String?
    let publishedAt: Date?
    let updatedAt: Date?
    let upstreamIdentifier: String?
    let originalPosition: Int
}

struct NormalizedFeedEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let identity: FeedEntryIdentity
    let subscriptionID: String
    let sourceTitle: String
    let title: String
    let summary: String
    let canonicalURL: URL?
    let author: String?
    let publishedAt: Date?
    let updatedAt: Date?
    let retrievedAt: Date
    let originalPosition: Int
    let provenance: FeedEntryProvenance
}

struct FeedParseResult: Codable, Hashable, Sendable {
    let format: FeedFormat
    let feedTitle: String
    let entries: [ParsedFeedEntry]
    let warnings: [String]
}

struct FeedFetchRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let subscriptionID: String
    let traceID: String
    let attemptedAt: Date
    let completedAt: Date
    let httpStatus: Int
    let responseByteCount: Int
    let parsedEntryCount: Int
    let finalURL: URL
    let eTag: String?
    let lastModified: String?
    let wasNotModified: Bool
}

struct FeedFetchResult: Codable, Hashable, Sendable {
    let subscription: FeedSubscription
    let entries: [NormalizedFeedEntry]
    let record: FeedFetchRecord
    let warnings: [String]
}

enum FeedTraceStatus: String, Codable, Sendable { case started, success, degraded, failed, skipped }

struct FeedTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(traceID: String = UUID().uuidString.lowercased(), spanID: String = UUID().uuidString.lowercased(), parentSpanID: String? = nil) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}

struct FeedTraceEvent: Codable, Hashable, Sendable {
    let event: String
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: FeedTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: [String: String]
}

enum FeedResolvedAddress: Hashable, Sendable {
    case ipv4(UInt8, UInt8, UInt8, UInt8)
    case ipv6([UInt8])
}

struct FeedValidatedTarget: Hashable, Sendable {
    let url: URL
    let approvedAddress: FeedResolvedAddress
}

final class FeedCancellationSignal: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func register(_ handler: @escaping Handler) -> UUID? {
        let identifier = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return nil
        }
        handlers[identifier] = handler
        lock.unlock()
        return identifier
    }

    func unregister(_ identifier: UUID?) {
        guard let identifier else { return }
        lock.lock(); handlers.removeValue(forKey: identifier); lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}

protocol FeedHostResolving: Sendable {
    func resolve(host: String) async throws -> [FeedResolvedAddress]
}

struct FeedTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL
    let headers: [String: String]
}

protocol FeedTransporting: Sendable {
    func prepare(requestID: UUID) async
    func releasePreparation(requestID: UUID) async
    func data(for request: URLRequest, target: FeedValidatedTarget, requestID: UUID, responseLimit: Int, resourceTimeout: TimeInterval) async throws -> FeedTransportResponse
    func cancel(requestID: UUID) async
}

extension FeedTransporting {
    func prepare(requestID: UUID) async { }
    func releasePreparation(requestID: UUID) async { }
}

typealias FeedProgressHandler = @Sendable (FeedRefreshState) async -> Void

protocol FeedRetrieving: Sendable {
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext, progress: @escaping FeedProgressHandler) async throws -> FeedFetchResult
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext, budget: ScheduledBriefingBudgetLedger) async throws -> FeedFetchResult
    func cancelAll() async
}

extension FeedRetrieving {
    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext, progress: @escaping FeedProgressHandler) async throws -> FeedFetchResult {
        await progress(.validating)
        return try await fetch(subscription, trace: trace)
    }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext, budget: ScheduledBriefingBudgetLedger) async throws -> FeedFetchResult {
        try await fetch(subscription, trace: trace)
    }
}
