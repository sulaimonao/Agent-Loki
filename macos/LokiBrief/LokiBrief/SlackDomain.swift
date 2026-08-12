import CryptoKit
import Foundation
import OSLog

enum SlackLimits {
    static let maximumSelectedChannels = 20
    static let historyPageSize = 15
    static let channelDiscoveryPageSize = 200
    static let maximumChannelDiscoveryPages = 20
    static let maximumDiscoveredChannels = channelDiscoveryPageSize * maximumChannelDiscoveryPages
    static let maximumAuthorLookupsPerSync = 64
    static let maximumCachedAuthorsPerWorkspace = 1_000
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumJSONDepth = 64
    static let maximumJSONContainers = 20_000
    static let maximumRawMessageCharacters = 100_000
    static let maximumExcerptCharacters = 1_500
    static let maximumWorkspaceNameCharacters = 200
    static let maximumChannelNameCharacters = 200
    static let maximumAuthorNameCharacters = 200
    static let maximumIdentifierCharacters = 256
    static let maximumCursorCharacters = 2_048
    static let maximumPermalinkCharacters = 4_096
    static let maximumRetryAfterSeconds: TimeInterval = 3_600
    static let initialLookbackSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let requestTimeout: TimeInterval = 20
    static let resourceTimeout: TimeInterval = 60
}

enum SlackGrantedScope: String, Codable, CaseIterable, Hashable, Sendable {
    case channelsRead = "channels:read"
    case channelsHistory = "channels:history"
    case groupsRead = "groups:read"
    case groupsHistory = "groups:history"
    case usersRead = "users:read"
}

enum SlackConnectionState: String, Codable, CaseIterable, Sendable {
    case configurationRequired
    case disconnected
    case authorizing
    case exchangingCode
    case validating
    case connected
    case refreshingCredentials
    case rateLimited
    case degraded
    case reauthorizationRequired
    case disconnecting
    case error
}

struct SlackWorkspaceConnection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let teamID: String
    var teamName: String
    let userID: String
    var userDisplayName: String
    var state: SlackConnectionState
    var grantedScopes: Set<SlackGrantedScope>
    var credentialMetadata: SlackCredentialMetadata?
    var localModelConsent: Bool
    let connectedAt: Date
    var updatedAt: Date
    var lastFailureReasonCode: String?
}

struct SlackCredentialMetadata: Codable, Hashable, Sendable {
    let tokenType: String
    let issuedAt: Date
    let accessExpiration: Date
    let grantedScopes: Set<SlackGrantedScope>
    let schemaVersion: Int
}

enum SlackConversationKind: String, Codable, CaseIterable, Sendable {
    case publicChannel
    case privateChannel
}

struct SlackConversation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    let displayName: String
    let kind: SlackConversationKind
    let isMember: Bool
    let isArchived: Bool
    let discoveredAt: Date
}

struct SlackConversationSelection: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(workspaceID):\(channelID)" }
    let workspaceID: String
    let channelID: String
    var displayName: String
    let kind: SlackConversationKind
    var enabled: Bool
    var weight: Double
    let selectedAt: Date
    var lastSuccessfulRefreshAt: Date?
    var lastFailureReasonCode: String?

    var validatedWeight: Double? {
        guard weight.isFinite else { return nil }
        return min(max(weight, 0.5), 2)
    }
}

enum SlackMessageAuthorKind: String, Codable, CaseIterable, Sendable {
    case user
    case bot
    case app
    case unknown
}

struct SlackMessageAuthor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let kind: SlackMessageAuthorKind
    let isDeleted: Bool
}

struct SlackTimestamp: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String
    private let seconds: UInt64
    private let fractionalNanoseconds: UInt32

    init?(rawValue: String) {
        let pieces = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              !pieces[1].isEmpty,
              pieces[0].count <= 20,
              pieces[1].count <= 9,
              pieces[0].allSatisfy(\.isNumber),
              pieces[1].allSatisfy(\.isNumber),
              let seconds = UInt64(pieces[0])
        else { return nil }
        let paddedFraction = String(pieces[1]) + String(repeating: "0", count: 9 - pieces[1].count)
        guard let fraction = UInt32(paddedFraction) else { return nil }
        self.rawValue = rawValue
        self.seconds = seconds
        self.fractionalNanoseconds = fraction
    }

    init(date: Date) {
        let interval = max(0, date.timeIntervalSince1970)
        let whole = UInt64(interval.rounded(.down))
        let fraction = UInt32(min(999_999_999, max(0, Int((interval - Double(whole)) * 1_000_000_000))))
        self.rawValue = String(format: "%llu.%09u", whole, fraction)
        self.seconds = whole
        self.fractionalNanoseconds = fraction
    }

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(fractionalNanoseconds) / 1_000_000_000)
    }

    static func < (lhs: SlackTimestamp, rhs: SlackTimestamp) -> Bool {
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        return lhs.fractionalNanoseconds < rhs.fractionalNanoseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Slack timestamp.")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SlackMessageEvidenceState: String, Codable, CaseIterable, Sendable {
    case available
    case deleted
    case inaccessible
}

struct SlackMessageEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    let workspaceName: String
    let channelID: String
    let channelName: String
    let channelKind: SlackConversationKind
    let messageTimestamp: SlackTimestamp
    let excerpt: String
    let author: SlackMessageAuthor
    let directlyMentionsAuthenticatedUser: Bool
    let replyCount: Int
    let isEdited: Bool
    let editedAt: SlackTimestamp?
    let permalink: URL?
    let retrievedAt: Date
    let selectedChannelWeight: Double
    let state: SlackMessageEvidenceState

    var deduplicationKey: String { "\(workspaceID):\(channelID):\(messageTimestamp.rawValue)" }

    func replacingPermalink(_ value: URL) -> SlackMessageEvidence {
        .init(
            id: id,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            channelID: channelID,
            channelName: channelName,
            channelKind: channelKind,
            messageTimestamp: messageTimestamp,
            excerpt: excerpt,
            author: author,
            directlyMentionsAuthenticatedUser: directlyMentionsAuthenticatedUser,
            replyCount: replyCount,
            isEdited: isEdited,
            editedAt: editedAt,
            permalink: value,
            retrievedAt: retrievedAt,
            selectedChannelWeight: selectedChannelWeight,
            state: state
        )
    }
}

struct SlackSyncCursor: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(workspaceID):\(channelID)" }
    let workspaceID: String
    let channelID: String
    var committedOldest: SlackTimestamp?
    var windowLatest: SlackTimestamp?
    var nextCursor: String?
    var pendingHighWater: SlackTimestamp?
    var updatedAt: Date
}

enum SlackSyncRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForRateLimit
    case partial
    case completed
    case cancelled
    case failed
}

struct SlackChannelSyncResult: Codable, Hashable, Sendable {
    let channelID: String
    let state: SlackSyncRunState
    let normalizedCount: Int
    let tombstoneCount: Int
    let failureReasonCode: String?
    let cursor: SlackSyncCursor
}

struct SlackSyncRun: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let traceID: String
    let workspaceID: String
    let startedAt: Date
    let completedAt: Date
    let state: SlackSyncRunState
    let selectedChannelCount: Int
    let successfulChannelCount: Int
    let failedChannelCount: Int
    let normalizedMessageCount: Int
    let rateLimitState: SlackRateLimitState?
    let channelResults: [SlackChannelSyncResult]
}

struct SlackRateLimitState: Codable, Hashable, Sendable {
    let method: SlackAPIMethod
    let retryAfterSeconds: TimeInterval
    let retryAt: Date
    let observedAt: Date
}

enum SlackConnectionFailureCode: String, Error, Codable, CaseIterable, Sendable {
    case configurationRequired = "slack_configuration_required"
    case cancelled = "slack_authorization_cancelled"
    case denied = "slack_authorization_denied"
    case malformedResponse = "slack_authorization_malformed_response"
    case missingScope = "slack_authorization_missing_scope"
    case identityMismatch = "slack_authorization_identity_mismatch"
    case credentialUnavailable = "slack_credential_unavailable"
}

enum SlackAPIErrorCode: String, Codable, CaseIterable, Sendable {
    case cancelled = "slack_api_cancelled"
    case invalidEndpoint = "slack_api_invalid_endpoint"
    case redirectRejected = "slack_api_redirect_rejected"
    case invalidRequest = "slack_api_invalid_request"
    case transportFailure = "slack_api_transport_failure"
    case timedOut = "slack_api_timed_out"
    case responseTooLarge = "slack_api_response_too_large"
    case invalidContentType = "slack_api_invalid_content_type"
    case invalidJSON = "slack_api_invalid_json"
    case jsonLimitExceeded = "slack_api_json_limit_exceeded"
    case invalidSchema = "slack_api_invalid_schema"
    case httpFailure = "slack_api_http_failure"
    case slackFailure = "slack_api_reported_failure"
    case invalidAuth = "slack_api_invalid_auth"
    case tokenExpired = "slack_api_token_expired"
    case tokenRevoked = "slack_api_token_revoked"
    case missingScope = "slack_api_missing_scope"
    case channelNotFound = "slack_api_channel_not_found"
    case channelAccessLost = "slack_api_channel_access_lost"
    case workspaceUnavailable = "slack_api_workspace_unavailable"
    case rateLimited = "slack_api_rate_limited"
    case invalidRetryAfter = "slack_api_invalid_retry_after"
    case reauthorizationRequired = "slack_api_reauthorization_required"
    case selectionLimitExceeded = "slack_selection_limit_exceeded"
    case authorLookupLimitReached = "slack_author_lookup_limit_reached"
    case syncAlreadyInProgress = "slack_sync_already_in_progress"
    case scheduledRequestBudgetExhausted = "scheduled_slack_request_budget_exhausted"
    case scheduledRetryBudgetExhausted = "scheduled_transient_retry_budget_exhausted"
    case scheduledDurationBudgetExhausted = "scheduled_briefing_duration_budget_exhausted"
    case scheduledRetryDelayExceedsRemaining = "scheduled_retry_delay_exceeds_remaining_budget"
}

struct SlackAPIError: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: SlackAPIErrorCode
    let httpStatus: Int?
    let retryAfterSeconds: TimeInterval?
    let slackErrorCode: String?

    init(_ code: SlackAPIErrorCode, httpStatus: Int? = nil, retryAfterSeconds: TimeInterval? = nil, slackErrorCode: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus
        self.retryAfterSeconds = retryAfterSeconds
        self.slackErrorCode = slackErrorCode.map { String($0.prefix(120)) }
    }

    var reasonCode: String { code.rawValue }

    static func scheduledBudgetFailure(reasonCode: String) -> SlackAPIError {
        switch reasonCode {
        case ScheduledBriefingBudgetReason.slackRequestsExhausted:
            return .init(.scheduledRequestBudgetExhausted)
        case ScheduledBriefingBudgetReason.transientRetriesExhausted:
            return .init(.scheduledRetryBudgetExhausted)
        case ScheduledBriefingBudgetReason.retryDelayExceedsRemaining:
            return .init(.scheduledRetryDelayExceedsRemaining)
        default:
            return .init(.scheduledDurationBudgetExhausted)
        }
    }

    var errorDescription: String? {
        switch code {
        case .cancelled: "The Slack operation was cancelled."
        case .invalidEndpoint, .redirectRejected, .invalidRequest: "The Slack request failed a local security check."
        case .transportFailure, .timedOut: "Slack could not be reached."
        case .responseTooLarge, .invalidContentType, .invalidJSON, .jsonLimitExceeded, .invalidSchema: "Slack returned an unsupported response."
        case .httpFailure, .slackFailure: "Slack could not complete the request."
        case .invalidAuth, .tokenExpired, .tokenRevoked, .reauthorizationRequired: "Slack authorization must be renewed."
        case .missingScope: "The Slack connection does not have a required read scope."
        case .channelNotFound, .channelAccessLost: "The selected Slack channel is no longer accessible."
        case .workspaceUnavailable: "The Slack workspace is unavailable."
        case .rateLimited: "Slack temporarily rate limited the request."
        case .invalidRetryAfter: "Slack returned an invalid rate-limit wait."
        case .selectionLimitExceeded: "Select no more than 20 Slack channels."
        case .authorLookupLimitReached: "Some Slack author names could not be resolved within this refresh."
        case .syncAlreadyInProgress: "A Slack refresh is already in progress."
        case .scheduledRequestBudgetExhausted: "The scheduled Slack request budget is exhausted."
        case .scheduledRetryBudgetExhausted: "The scheduled Slack retry budget is exhausted."
        case .scheduledDurationBudgetExhausted: "The scheduled briefing duration budget is exhausted."
        case .scheduledRetryDelayExceedsRemaining: "The Slack rate-limit wait exceeds the scheduled briefing time remaining."
        }
    }
}

struct SlackDisconnectResult: Codable, Hashable, Sendable {
    let workspaceID: String
    let localDataDeleted: Bool
    let localDataPreserved: Bool
    let connectorDisabled: Bool
    let credentialDeleted: Bool
    let remoteRevocationAttempted: Bool
    let remoteRevocationConfirmed: Bool
    let reasonCode: String
}

enum SlackAPIMethod: String, Codable, CaseIterable, Sendable {
    case authTest = "auth.test"
    case conversationsList = "conversations.list"
    case conversationsHistory = "conversations.history"
    case usersInfo = "users.info"
    case chatGetPermalink = "chat.getPermalink"

    var path: String { "/api/\(rawValue)" }
}

struct SlackAuthenticatedIdentity: Codable, Hashable, Sendable {
    let teamID: String
    let teamName: String
    let userID: String
    let userName: String
    let workspaceURL: URL?
}

struct SlackHistoryMessage: Codable, Hashable, Sendable {
    let type: String
    let subtype: String?
    let timestamp: SlackTimestamp
    let deletedTimestamp: SlackTimestamp?
    let threadTimestamp: SlackTimestamp?
    let text: String
    let userID: String?
    let botID: String?
    let appID: String?
    let username: String?
    let replyCount: Int
    let editedAt: SlackTimestamp?
}

struct SlackConversationPage: Codable, Hashable, Sendable {
    let conversations: [SlackConversation]
    let nextCursor: String?
}

struct SlackHistoryPage: Codable, Hashable, Sendable {
    let messages: [SlackHistoryMessage]
    let nextCursor: String?
    let hasMore: Bool
}

struct SlackAPICallMetadata: Codable, Hashable, Sendable {
    let transientRetryCount: Int
    let rateLimitRetryCount: Int
    let credentialRefreshCount: Int
    let rateLimitState: SlackRateLimitState?
}

struct SlackAPICallResult<Value: Sendable>: Sendable {
    let value: Value
    let metadata: SlackAPICallMetadata
}

struct SlackTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
    let headers: [String: String]
}

protocol SlackAPITransporting: Sendable {
    func data(for request: URLRequest, requestID: UUID, responseLimit: Int) async throws -> SlackTransportResponse
    func cancel(requestID: UUID) async
}

protocol SlackAccessTokenProviding: Sendable {
    func accessToken(teamID: String, userID: String, forceRefresh: Bool, trace: SlackTraceContext) async throws -> String
    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> String
}

extension SlackAccessTokenProviding {
    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?
    ) async throws -> String {
        try await accessToken(teamID: teamID, userID: userID, forceRefresh: forceRefresh, trace: trace)
    }
}

protocol SlackSleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct SystemSlackSleeper: SlackSleeping {
    func sleep(seconds: TimeInterval) async throws {
        guard seconds >= 0, seconds.isFinite else { throw SlackAPIError(.invalidRetryAfter) }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

enum SlackTraceStatus: String, Codable, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum SlackTraceEventName: String, Codable, CaseIterable, Sendable {
    case authorization = "slack.authorization"
    case callbackValidation = "slack.callback_validation"
    case codeExchange = "slack.code_exchange"
    case keychainOperation = "slack.keychain_operation"
    case credentialRefresh = "slack.credential_refresh"
    case networkRequest = "slack.network_request"
    case identityValidation = "slack.identity_validation"
    case channelDiscovery = "slack.channel_discovery"
    case selectedChannelSync = "slack.selected_channel_sync"
    case rateLimit = "slack.rate_limit"
    case authorResolution = "slack.author_resolution"
    case messageNormalization = "slack.message_normalization"
    case permalinkResolution = "slack.permalink_resolution"
    case deterministicAssembly = "slack.deterministic_assembly"
    case localModelConsent = "slack.local_model_consent"
    case cancellation = "slack.cancellation"
    case fallback = "slack.fallback"
    case disconnect = "slack.disconnect"
}

enum SlackTraceMetadataKey: String, Codable, CaseIterable, Hashable, Sendable {
    case operation
    case httpStatus = "http_status"
    case responseBytes = "response_bytes"
    case pageSize = "page_size"
    case pageCount = "page_count"
    case selectedChannelCount = "selected_channel_count"
    case normalizedCount = "normalized_count"
    case skippedCount = "skipped_count"
    case successCount = "success_count"
    case failureCount = "failure_count"
    case retryAfterSeconds = "retry_after_seconds"
    case retryCount = "retry_count"
    case workspaceHash = "workspace_hash"
    case channelHash = "channel_hash"
    case authorHash = "author_hash"
    case directMentionCount = "direct_mention_count"
    case consentedWorkspaceCount = "consented_workspace_count"
}

struct SlackTraceMetadata: Codable, Hashable, Sendable {
    private(set) var values: [SlackTraceMetadataKey: String]

    init(_ entries: [(SlackTraceMetadataKey, String)] = []) {
        var bounded: [SlackTraceMetadataKey: String] = [:]
        for (key, value) in entries.prefix(16) {
            bounded[key] = SlackPrivacy.boundedMetadata(value)
        }
        self.values = bounded
    }

    subscript(_ key: SlackTraceMetadataKey) -> String? { values[key] }
}

struct SlackTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(traceID: String = UUID().uuidString.lowercased(), spanID: String = UUID().uuidString.lowercased(), parentSpanID: String? = nil) {
        self.traceID = SlackPrivacy.boundedMetadata(traceID)
        self.spanID = SlackPrivacy.boundedMetadata(spanID)
        self.parentSpanID = parentSpanID.map(SlackPrivacy.boundedMetadata)
    }

    func child() -> SlackTraceContext {
        .init(traceID: traceID, spanID: UUID().uuidString.lowercased(), parentSpanID: spanID)
    }
}

struct SlackTraceEvent: Codable, Hashable, Sendable {
    let ts: Date
    let event: SlackTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: SlackTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: SlackTraceMetadata

    enum CodingKeys: String, CodingKey {
        case ts
        case event
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case component
        case status
        case reasonCode = "reason_code"
        case durationMilliseconds = "duration_ms"
        case metadata
    }
}

enum SlackProductionTraceLogger {
    private static let logger = Logger(subsystem: "com.agentloki.LokiBrief", category: "slack")

    static func emit(_ event: SlackTraceEvent) {
        guard let line = encodedLine(for: event) else {
            logger.error("{\"event\":\"slack.trace_encoding\",\"status\":\"failed\",\"reason_code\":\"slack_trace_encoding_failed\"}")
            return
        }
        logger.info("\(line, privacy: .public)")
    }

    static func encodedLine(for event: SlackTraceEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              data.count <= 8_192,
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }
}

enum SlackPrivacy {
    static func hashIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedMetadata(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(160))
    }

    static func boundedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= SlackLimits.maximumIdentifierCharacters,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    static func boundedDisplayName(_ value: String, maximum: Int, fallback: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !isBidirectionalControl(scalar.value)
        }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(maximum))
    }

    static func isBidirectionalControl(_ value: UInt32) -> Bool {
        (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }
}
