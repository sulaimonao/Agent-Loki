import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

// Discord Connector V1 deliberately uses REST polling rather than Gateway state.
// Every remote operation is a bounded GET against the fixed Discord API v10
// authority. The bot token exists only in Keychain and at the transport boundary.

enum DiscordLimits {
    static let apiScheme = "https"
    static let apiHost = "discord.com"
    static let apiVersionPath = "/api/v10"
    static let maximumIdentifierBytes = 128
    static let maximumTokenBytes = 8_192
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumJSONDepth = 64
    static let maximumJSONContainers = 25_000
    static let maximumGuildPages = 100
    static let maximumThreadPages = 100
    static let maximumHistoryPages = 500
    static let guildPageSize = 200
    static let threadPageSize = 100
    static let historyPageSize = 100
    static let maximumSelections = 100
    static let incrementalPollsBeforeFullReconciliation = 10
    static let maximumSyncOutputMessages = 5_000
    static let maximumSyncOutputBytes = 32 * 1_024 * 1_024
    static let maximumExistingEnvelopes = 100_000
    static let maximumExistingEnvelopeBytes = 128 * 1_024 * 1_024
    static let maximumObservationFilterBytes = 128 * 1_024
    static let maximumAttachmentsPerMessage = 32
    static let maximumAttachmentFilenameCharacters = 512
    static let maximumRetryAfterSeconds: TimeInterval = 3_600
    static let requestTimeout: TimeInterval = 20
    static let resourceTimeout: TimeInterval = 60
}

enum DiscordInstallationPolicy {
    static let oauth2Scopes: Set<String> = ["bot"]
    static let viewChannelPermission: UInt64 = 1 << 10
    static let readMessageHistoryPermission: UInt64 = 1 << 16
    static let minimumChannelPermissions =
        viewChannelPermission | readMessageHistoryPermission
    static let messageContentIntentName = "MESSAGE_CONTENT"
}

enum DiscordFailureCode: String, Error, Codable, CaseIterable, Hashable, Sendable {
    case invalidAuthority = "discord_authority_invalid"
    case invalidCredential = "discord_credential_invalid"
    case credentialNotFound = "discord_credential_not_found"
    case credentialStoreUnavailable = "discord_credential_store_unavailable"
    case credentialDeleteFailed = "discord_credential_delete_failed"
    case invalidEndpoint = "discord_endpoint_invalid"
    case writeEndpointRejected = "discord_write_endpoint_rejected"
    case authorizationBoundaryViolation = "discord_authorization_boundary_violation"
    case directMessageRejected = "discord_direct_message_rejected"
    case containerOnlyChannelRejected = "discord_container_only_channel_rejected"
    case invalidRequest = "discord_request_invalid"
    case invalidToken = "discord_token_invalid"
    case missingGuildPermission = "discord_guild_permission_missing"
    case missingChannelPermission = "discord_channel_permission_missing"
    case messageContentIntentMissing = "discord_message_content_intent_missing"
    case limitedMessageContent = "discord_message_content_limited"
    case resourceUnavailable = "discord_resource_unavailable"
    case responseTooLarge = "discord_response_too_large"
    case invalidContentType = "discord_content_type_invalid"
    case invalidJSON = "discord_json_invalid"
    case invalidSchema = "discord_schema_invalid"
    case paginationDidNotAdvance = "discord_pagination_did_not_advance"
    case paginationOutOfOrder = "discord_pagination_out_of_order"
    case duplicatePageReplay = "discord_duplicate_page_replay"
    case rateLimited = "discord_rate_limited"
    case invalidRetryAfter = "discord_retry_after_invalid"
    case transportFailure = "discord_transport_failure"
    case transientFailureExhausted = "discord_transient_failure_exhausted"
    case cancelled = "discord_operation_cancelled"
    case syncIncomplete = "discord_sync_incomplete"
    case syncOutputLimitReached = "discord_sync_output_limit_reached"
    case reconciliationUnconfirmed = "discord_tombstone_unconfirmed"
}

struct DiscordFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: DiscordFailureCode
    let httpStatus: Int?
    let retryAfterSeconds: TimeInterval?
    let providerCode: Int?

    init(
        _ code: DiscordFailureCode,
        httpStatus: Int? = nil,
        retryAfterSeconds: TimeInterval? = nil,
        providerCode: Int? = nil
    ) {
        self.code = code
        self.httpStatus = httpStatus
        self.retryAfterSeconds = retryAfterSeconds
        self.providerCode = providerCode
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .invalidAuthority, .invalidRequest:
            "The Discord connector configuration is invalid."
        case .invalidCredential, .invalidToken:
            "The Discord bot credential is invalid or no longer authorized."
        case .credentialNotFound:
            "No Discord bot credential is stored for this connection."
        case .credentialStoreUnavailable:
            "The Data Protection Keychain is unavailable."
        case .credentialDeleteFailed:
            "The Discord bot credential could not be removed from Keychain."
        case .invalidEndpoint, .writeEndpointRejected, .authorizationBoundaryViolation,
             .directMessageRejected:
            "A Discord request was rejected by the local read-only policy."
        case .containerOnlyChannelRejected:
            "Discord forum and media channels are thread containers, not message-history sources."
        case .missingGuildPermission:
            "The bot cannot read the selected Discord server."
        case .missingChannelPermission:
            "The bot needs View Channel and Read Message History in the selected channel."
        case .messageContentIntentMissing, .limitedMessageContent:
            "Discord Message Content access is unavailable; only limited metadata can be imported."
        case .resourceUnavailable:
            "The selected Discord resource is unavailable."
        case .responseTooLarge, .invalidContentType, .invalidJSON, .invalidSchema:
            "Discord returned an unsupported response."
        case .paginationDidNotAdvance, .paginationOutOfOrder, .duplicatePageReplay:
            "Discord history pagination could not be reconciled safely."
        case .rateLimited, .invalidRetryAfter:
            "Discord temporarily rate limited the connector."
        case .transportFailure, .transientFailureExhausted:
            "Discord could not be reached."
        case .cancelled:
            "The Discord operation was cancelled."
        case .syncIncomplete:
            "Discord history was only partially synchronized."
        case .syncOutputLimitReached:
            "Discord sync reached its bounded output limit; continuation was preserved."
        case .reconciliationUnconfirmed:
            "A possible Discord deletion requires another complete reconciliation."
        }
    }
}

enum DiscordConnectionState: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case disconnected
    case connecting
    case connected
    case syncing
    case degraded
    case failed
    case disabled
}

enum DiscordMessageContentAccess: String, Codable, CaseIterable, Hashable, Sendable {
    case enabled
    case limitedByPrivilegedIntent = "limited_by_privileged_intent"

    var permitsContentIndexing: Bool { self == .enabled }
}

enum DiscordMessageBodyState: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case empty
    case limitedByMessageContentIntent = "limited_by_message_content_intent"
}

enum DiscordChannelType: Int, Codable, CaseIterable, Hashable, Sendable {
    case guildText = 0
    case directMessage = 1
    case guildVoice = 2
    case groupDirectMessage = 3
    case guildCategory = 4
    case guildAnnouncement = 5
    case announcementThread = 10
    case publicThread = 11
    case privateThread = 12
    case guildStageVoice = 13
    case guildDirectory = 14
    case guildForum = 15
    case guildMedia = 16

    var isDirectMessage: Bool {
        self == .directMessage || self == .groupDirectMessage
    }

    var isThread: Bool {
        self == .announcementThread || self == .publicThread || self == .privateThread
    }

    var isReadableTextSource: Bool {
        switch self {
        case .guildText, .guildAnnouncement, .guildForum, .guildMedia,
             .announcementThread, .publicThread, .privateThread:
            true
        case .directMessage, .groupDirectMessage, .guildVoice, .guildCategory,
             .guildStageVoice, .guildDirectory:
            false
        }
    }

    var supportsPublicArchivedThreads: Bool {
        switch self {
        case .guildText, .guildAnnouncement, .guildForum, .guildMedia:
            true
        default:
            false
        }
    }

    var supportsPrivateThreads: Bool { self == .guildText }

    var supportsDirectHistory: Bool {
        self == .guildText || self == .guildAnnouncement || isThread
    }

    var isThreadContainerOnly: Bool {
        self == .guildForum || self == .guildMedia
    }
}

struct DiscordConnectorAuthority: Codable, Hashable, Sendable {
    let applicationID: String
    let botUserID: String
    let guildAllowlist: Set<String>
    let channelAllowlist: Set<String>
    let threadAllowlist: Set<String>
    let messageContentAccess: DiscordMessageContentAccess
    let ingestDirectMessages: Bool
    let downloadAttachmentBodies: Bool

    init(
        applicationID: String,
        botUserID: String,
        guildAllowlist: Set<String>,
        channelAllowlist: Set<String>,
        threadAllowlist: Set<String> = [],
        messageContentAccess: DiscordMessageContentAccess,
        ingestDirectMessages: Bool = false,
        downloadAttachmentBodies: Bool = false
    ) throws {
        guard DiscordValidation.isSnowflake(applicationID),
              DiscordValidation.isSnowflake(botUserID),
              !guildAllowlist.isEmpty,
              guildAllowlist.allSatisfy(DiscordValidation.isSnowflake),
              channelAllowlist.allSatisfy(DiscordValidation.isSnowflake),
              threadAllowlist.allSatisfy(DiscordValidation.isSnowflake),
              !ingestDirectMessages,
              !downloadAttachmentBodies
        else { throw DiscordFailure(.invalidAuthority) }

        self.applicationID = applicationID
        self.botUserID = botUserID
        self.guildAllowlist = guildAllowlist
        self.channelAllowlist = channelAllowlist
        self.threadAllowlist = threadAllowlist
        self.messageContentAccess = messageContentAccess
        self.ingestDirectMessages = false
        self.downloadAttachmentBodies = false
    }

    var accountIdentifier: String {
        DiscordPrivacy.digest("\(applicationID):\(botUserID)")
    }

    func admits(_ selection: DiscordSourceSelection) -> Bool {
        guard guildAllowlist.contains(selection.guildID),
              channelAllowlist.contains(selection.channelID)
        else { return false }
        guard let threadID = selection.threadID else { return true }
        return threadAllowlist.contains(threadID)
    }
}

struct DiscordSourceSelection: Codable, Hashable, Sendable, Identifiable {
    let guildID: String
    let channelID: String
    let threadID: String?
    let parentChannelType: DiscordChannelType?

    private enum CodingKeys: String, CodingKey {
        case guildID
        case channelID
        case threadID
        case parentChannelType
    }

    init(
        guildID: String,
        channelID: String,
        threadID: String? = nil,
        parentChannelType: DiscordChannelType? = nil
    ) throws {
        guard DiscordValidation.isSnowflake(guildID),
              DiscordValidation.isSnowflake(channelID),
              threadID.map(DiscordValidation.isSnowflake) ?? true
        else { throw DiscordFailure(.invalidAuthority) }
        if threadID == nil, parentChannelType?.isThreadContainerOnly == true {
            throw DiscordFailure(.containerOnlyChannelRejected)
        }
        guard parentChannelType.map({
            threadID == nil
                ? $0.supportsDirectHistory && !$0.isThread
                : $0.supportsPublicArchivedThreads || $0.supportsPrivateThreads
        }) ?? true else { throw DiscordFailure(.invalidAuthority) }
        self.guildID = guildID
        self.channelID = channelID
        self.threadID = threadID
        self.parentChannelType = parentChannelType
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            guildID: values.decode(String.self, forKey: .guildID),
            channelID: values.decode(String.self, forKey: .channelID),
            threadID: values.decodeIfPresent(String.self, forKey: .threadID),
            parentChannelType: values.decodeIfPresent(
                DiscordChannelType.self,
                forKey: .parentChannelType
            )
        )
    }

    var id: String { "\(guildID):\(channelID):\(threadID ?? "channel")" }
    var historyChannelID: String { threadID ?? channelID }
    var sourceContainerIdentifier: String {
        "discord:guild:\(guildID):channel:\(channelID):thread:\(threadID ?? "none")"
    }
}

struct DiscordBotCredential: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let applicationID: String
    let botUserID: String
    let token: String

    init(applicationID: String, botUserID: String, token: String) throws {
        guard DiscordValidation.isSnowflake(applicationID),
              DiscordValidation.isSnowflake(botUserID),
              DiscordValidation.isValidToken(token)
        else { throw DiscordFailure(.invalidCredential) }
        self.applicationID = applicationID
        self.botUserID = botUserID
        self.token = token
    }

    var accountIdentifier: String {
        DiscordPrivacy.digest("\(applicationID):\(botUserID)")
    }

    var description: String {
        "DiscordBotCredential(applicationID: \(applicationID), botUserID: \(botUserID), token: <redacted>)"
    }

    var debugDescription: String { description }
}

enum DiscordTraceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum DiscordTraceEventName: String, Codable, CaseIterable, Hashable, Sendable {
    case credential = "discord.credential"
    case connection = "discord.connection"
    case networkRequest = "discord.network_request"
    case guildDiscovery = "discord.guild_discovery"
    case channelDiscovery = "discord.channel_discovery"
    case threadDiscovery = "discord.thread_discovery"
    case historyPage = "discord.history_page"
    case normalization = "discord.normalization"
    case reconciliation = "discord.reconciliation"
    case rateLimit = "discord.rate_limit"
    case cancellation = "discord.cancellation"
    case disconnect = "discord.disconnect"
}

enum DiscordTraceMetadataKey: String, Codable, CaseIterable, Hashable, Sendable {
    case operation
    case endpoint
    case httpStatus = "http_status"
    case responseBytes = "response_bytes"
    case pageOrdinal = "page_ordinal"
    case pageCount = "page_count"
    case importedCount = "imported_count"
    case skippedCount = "skipped_count"
    case tombstoneCount = "tombstone_count"
    case attachmentCount = "attachment_count"
    case retryCount = "retry_count"
    case retryAfterMilliseconds = "retry_after_ms"
    case accountHash = "account_hash"
    case guildHash = "guild_hash"
    case channelHash = "channel_hash"
    case threadHash = "thread_hash"
    case contentMode = "content_mode"
    case syncMode = "sync_mode"
    case outputBytes = "output_bytes"
    case outputMessageLimit = "output_message_limit"
    case outputByteLimit = "output_byte_limit"
}

struct DiscordTraceMetadata: Codable, Hashable, Sendable {
    private(set) var values: [String: String]

    init(_ entries: [(DiscordTraceMetadataKey, String)] = []) {
        var result: [String: String] = [:]
        for (key, value) in entries.prefix(20) {
            result[key.rawValue] = DiscordPrivacy.boundedMetadata(value)
        }
        values = result
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        var result: [String: String] = [:]
        for key in DiscordTraceMetadataKey.allCases {
            if let value = raw[key.rawValue], result.count < 20 {
                result[key.rawValue] = DiscordPrivacy.boundedMetadata(value)
            }
        }
        values = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    subscript(_ key: DiscordTraceMetadataKey) -> String? { values[key.rawValue] }
}

struct DiscordTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = DiscordPrivacy.boundedMetadata(traceID)
        self.spanID = DiscordPrivacy.boundedMetadata(spanID)
        self.parentSpanID = parentSpanID.map(DiscordPrivacy.boundedMetadata)
    }

    func child() -> DiscordTraceContext {
        .init(
            traceID: traceID,
            spanID: UUID().uuidString.lowercased(),
            parentSpanID: spanID
        )
    }
}

struct DiscordTraceEvent: Codable, Hashable, Sendable {
    let timestamp: Date
    let event: DiscordTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: DiscordTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int
    let metadata: DiscordTraceMetadata

    init(
        timestamp: Date,
        event: DiscordTraceEventName,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        component: String,
        status: DiscordTraceStatus,
        reasonCode: String,
        durationMilliseconds: Int = 0,
        metadata: DiscordTraceMetadata
    ) {
        self.timestamp = timestamp
        self.event = event
        self.traceID = DiscordPrivacy.boundedMetadata(traceID)
        self.spanID = DiscordPrivacy.boundedMetadata(spanID)
        self.parentSpanID = parentSpanID.map(DiscordPrivacy.boundedMetadata)
        self.component = DiscordPrivacy.boundedMetadata(component)
        self.status = status
        self.reasonCode = DiscordPrivacy.boundedMetadata(reasonCode)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
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

enum DiscordProductionTraceLogger {
    private static let logger = Logger(
        subsystem: "com.agentloki.LokiBrief",
        category: "discord"
    )

    static func emit(_ event: DiscordTraceEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              data.count <= 8_192,
              let line = String(data: data, encoding: .utf8)
        else {
            logger.error("{\"event\":\"discord.trace_encoding\",\"status\":\"failed\",\"reason_code\":\"discord_trace_encoding_failed\"}")
            return
        }
        logger.info("\(line, privacy: .public)")
    }
}

enum DiscordValidation {
    static func isSnowflake(_ value: String) -> Bool {
        guard (1...20).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              UInt64(value) != nil
        else { return false }
        return true
    }

    static func isValidToken(_ value: String) -> Bool {
        guard (1...DiscordLimits.maximumTokenBytes).contains(value.utf8.count),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.lowercased().hasPrefix("bearer "),
              !value.lowercased().hasPrefix("bot ")
        else { return false }
        return !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) ||
                CharacterSet.controlCharacters.contains($0)
        }
    }

    static func isBoundedCursor(_ value: String) -> Bool {
        guard (1...ConnectorEnvelopeLimits.maximumCursorBytes).contains(value.utf8.count)
        else { return false }
        return !value.unicodeScalars.contains(where: ConnectorEnvelopeValidation.isUnsafeScalar)
    }
}

enum DiscordPrivacy {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func shortHash(_ value: String) -> String {
        String(digest(value).prefix(16))
    }

    static func boundedMetadata(_ value: String) -> String {
        let safe = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
                !ConnectorEnvelopeValidation.isUnsafeScalar($0)
        }
        return String(String.UnicodeScalarView(safe).prefix(160))
    }

    static func boundedName(_ value: String, fallback: String) -> String {
        let normalized = ConnectorTextNormalization.text(value)
        return normalized.isEmpty ? fallback : String(normalized.prefix(256))
    }
}

enum DiscordCredentialStoreFailureCode: String, Error, Codable, Hashable, Sendable {
    case invalidService = "discord_keychain_service_invalid"
    case invalidCredential = "discord_keychain_credential_invalid"
    case payloadEncodingFailed = "discord_keychain_payload_encoding_failed"
    case payloadDecodingFailed = "discord_keychain_payload_decoding_failed"
    case payloadTooLarge = "discord_keychain_payload_too_large"
    case notFound = "discord_keychain_item_not_found"
    case missingEntitlement = "discord_keychain_missing_entitlement"
    case unavailable = "discord_keychain_unavailable"
    case interactionNotAllowed = "discord_keychain_interaction_not_allowed"
    case saveFailed = "discord_keychain_save_failed"
    case readFailed = "discord_keychain_read_failed"
    case deleteFailed = "discord_keychain_delete_failed"
}

struct DiscordCredentialStoreFailure: Error, Equatable, Sendable, LocalizedError {
    let code: DiscordCredentialStoreFailureCode
    let status: OSStatus?

    init(code: DiscordCredentialStoreFailureCode, status: OSStatus? = nil) {
        self.code = code
        self.status = status
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .invalidService:
            "The Discord Keychain service identifier is invalid."
        case .invalidCredential:
            "The Discord bot credential is invalid."
        case .payloadEncodingFailed, .payloadDecodingFailed, .payloadTooLarge:
            "The Discord credential payload could not be stored safely."
        case .notFound:
            "No Discord bot credential exists for this connection."
        case .missingEntitlement:
            "The application is not entitled to use the Data Protection Keychain."
        case .unavailable:
            "The Data Protection Keychain is unavailable."
        case .interactionNotAllowed:
            "Keychain access is not currently permitted."
        case .saveFailed:
            "The Discord bot credential could not be saved to Keychain."
        case .readFailed:
            "The Discord bot credential could not be read from Keychain."
        case .deleteFailed:
            "The Discord bot credential could not be deleted from Keychain."
        }
    }
}

protocol DiscordCredentialStoring: Sendable {
    func save(_ credential: DiscordBotCredential, trace: DiscordTraceContext) async throws
    func read(accountIdentifier: String, trace: DiscordTraceContext) async throws -> DiscordBotCredential
    func delete(accountIdentifier: String, trace: DiscordTraceContext) async throws
}

actor SecurityDiscordCredentialStore: DiscordCredentialStoring {
    typealias TraceSink = @Sendable (DiscordTraceEvent) -> Void

    static let productionService = "com.agentloki.LokiBrief.discord.bot-token.v1"
    static let maximumPayloadBytes = 16 * 1_024

    private struct StoredCredential: Codable {
        let schemaVersion: Int
        let applicationID: String
        let botUserID: String
        let token: String
    }

    private let service: String
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?

    init(
        service: String = productionService,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        self.service = service
        self.now = now
        self.eventSink = eventSink
    }

    func save(_ credential: DiscordBotCredential, trace: DiscordTraceContext) async throws {
        emit(
            operation: "save",
            status: .started,
            reasonCode: "discord_keychain_save_started",
            accountIdentifier: credential.accountIdentifier,
            trace: trace
        )
        do {
            let payload = StoredCredential(
                schemaVersion: 1,
                applicationID: credential.applicationID,
                botUserID: credential.botUserID,
                token: credential.token
            )
            let data: Data
            do {
                data = try JSONEncoder().encode(payload)
            } catch {
                throw DiscordCredentialStoreFailure(code: .payloadEncodingFailed)
            }
            guard data.count <= Self.maximumPayloadBytes else {
                throw DiscordCredentialStoreFailure(code: .payloadTooLarge)
            }

            var query = try exactQuery(accountIdentifier: credential.accountIdentifier)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let updateQuery = try exactQuery(accountIdentifier: credential.accountIdentifier)
                let updateStatus = SecItemUpdate(
                    updateQuery as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard updateStatus == errSecSuccess else {
                    throw failure(for: updateStatus, fallback: .saveFailed)
                }
            } else if addStatus != errSecSuccess {
                throw failure(for: addStatus, fallback: .saveFailed)
            }
            emit(
                operation: "save",
                status: .success,
                reasonCode: "discord_keychain_save_succeeded",
                accountIdentifier: credential.accountIdentifier,
                trace: trace
            )
        } catch {
            emit(
                operation: "save",
                status: .failed,
                reasonCode: reasonCode(for: error),
                accountIdentifier: credential.accountIdentifier,
                trace: trace
            )
            throw error
        }
    }

    func read(
        accountIdentifier: String,
        trace: DiscordTraceContext
    ) async throws -> DiscordBotCredential {
        emit(
            operation: "read",
            status: .started,
            reasonCode: "discord_keychain_read_started",
            accountIdentifier: accountIdentifier,
            trace: trace
        )
        do {
            var query = try exactQuery(accountIdentifier: accountIdentifier)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                throw failure(for: status, fallback: .readFailed)
            }
            guard let data = result as? Data,
                  data.count <= Self.maximumPayloadBytes
            else { throw DiscordCredentialStoreFailure(code: .payloadTooLarge) }

            let payload: StoredCredential
            do {
                payload = try JSONDecoder().decode(StoredCredential.self, from: data)
            } catch {
                throw DiscordCredentialStoreFailure(code: .payloadDecodingFailed)
            }
            guard payload.schemaVersion == 1 else {
                throw DiscordCredentialStoreFailure(code: .invalidCredential)
            }
            let credential: DiscordBotCredential
            do {
                credential = try .init(
                    applicationID: payload.applicationID,
                    botUserID: payload.botUserID,
                    token: payload.token
                )
            } catch {
                throw DiscordCredentialStoreFailure(code: .invalidCredential)
            }
            guard credential.accountIdentifier == accountIdentifier else {
                throw DiscordCredentialStoreFailure(code: .invalidCredential)
            }
            emit(
                operation: "read",
                status: .success,
                reasonCode: "discord_keychain_read_succeeded",
                accountIdentifier: accountIdentifier,
                trace: trace
            )
            return credential
        } catch {
            emit(
                operation: "read",
                status: .failed,
                reasonCode: reasonCode(for: error),
                accountIdentifier: accountIdentifier,
                trace: trace
            )
            throw error
        }
    }

    func delete(accountIdentifier: String, trace: DiscordTraceContext) async throws {
        emit(
            operation: "delete",
            status: .started,
            reasonCode: "discord_keychain_delete_started",
            accountIdentifier: accountIdentifier,
            trace: trace
        )
        do {
            let status = SecItemDelete(
                try exactQuery(accountIdentifier: accountIdentifier) as CFDictionary
            )
            guard status == errSecSuccess else {
                throw failure(for: status, fallback: .deleteFailed)
            }
            emit(
                operation: "delete",
                status: .success,
                reasonCode: "discord_keychain_delete_succeeded",
                accountIdentifier: accountIdentifier,
                trace: trace
            )
        } catch {
            emit(
                operation: "delete",
                status: .failed,
                reasonCode: reasonCode(for: error),
                accountIdentifier: accountIdentifier,
                trace: trace
            )
            throw error
        }
    }

    private func exactQuery(accountIdentifier: String) throws -> [String: Any] {
        guard Self.validService(service),
              accountIdentifier.count == 64,
              ConnectorEnvelopeValidation.validSHA256(accountIdentifier)
        else { throw DiscordCredentialStoreFailure(code: .invalidService) }
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountIdentifier,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
    }

    private static func validService(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func failure(
        for status: OSStatus,
        fallback: DiscordCredentialStoreFailureCode
    ) -> DiscordCredentialStoreFailure {
        let code: DiscordCredentialStoreFailureCode
        switch status {
        case errSecItemNotFound:
            code = .notFound
        case errSecMissingEntitlement:
            code = .missingEntitlement
        case errSecNotAvailable:
            code = .unavailable
        case errSecInteractionNotAllowed:
            code = .interactionNotAllowed
        default:
            code = fallback
        }
        return .init(code: code, status: status)
    }

    private func reasonCode(for error: Error) -> String {
        if let failure = error as? DiscordCredentialStoreFailure {
            return failure.reasonCode
        }
        return DiscordCredentialStoreFailureCode.unavailable.rawValue
    }

    private func emit(
        operation: String,
        status: DiscordTraceStatus,
        reasonCode: String,
        accountIdentifier: String,
        trace: DiscordTraceContext
    ) {
        let event = DiscordTraceEvent(
            timestamp: now(),
            event: .credential,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "discord_keychain",
            status: status,
            reasonCode: reasonCode,
            metadata: .init([
                (.operation, operation),
                (.accountHash, DiscordPrivacy.shortHash(accountIdentifier)),
            ])
        )
        eventSink?(event)
        if eventSink == nil { DiscordProductionTraceLogger.emit(event) }
    }
}

enum DiscordRESTEndpoint: Hashable, Sendable {
    case currentBot
    case currentGuilds(after: String?)
    case guildChannels(guildID: String)
    case activeGuildThreads(guildID: String)
    case publicArchivedThreads(channelID: String, before: String?)
    case joinedPrivateArchivedThreads(channelID: String, before: String?)
    case channelMessages(channelID: String, before: String?, after: String?, limit: Int)
    case channelMessage(channelID: String, messageID: String)

    var traceName: String {
        switch self {
        case .currentBot: "current_bot"
        case .currentGuilds: "current_guilds"
        case .guildChannels: "guild_channels"
        case .activeGuildThreads: "active_guild_threads"
        case .publicArchivedThreads: "public_archived_threads"
        case .joinedPrivateArchivedThreads: "joined_private_archived_threads"
        case .channelMessages: "channel_messages"
        case .channelMessage: "channel_message"
        }
    }

    var permissionSurface: DiscordPermissionSurface {
        switch self {
        case .currentBot:
            .authentication
        case .currentGuilds, .guildChannels, .activeGuildThreads:
            .guild
        case .publicArchivedThreads, .joinedPrivateArchivedThreads,
             .channelMessages, .channelMessage:
            .channel
        }
    }

    func request() throws -> URLRequest {
        var components = URLComponents()
        components.scheme = DiscordLimits.apiScheme
        components.host = DiscordLimits.apiHost
        var queryItems: [URLQueryItem] = []

        switch self {
        case .currentBot:
            components.path = "\(DiscordLimits.apiVersionPath)/users/@me"
        case let .currentGuilds(after):
            components.path = "\(DiscordLimits.apiVersionPath)/users/@me/guilds"
            queryItems.append(.init(name: "limit", value: String(DiscordLimits.guildPageSize)))
            if let after { queryItems.append(.init(name: "after", value: after)) }
        case let .guildChannels(guildID):
            components.path = "\(DiscordLimits.apiVersionPath)/guilds/\(guildID)/channels"
        case let .activeGuildThreads(guildID):
            components.path = "\(DiscordLimits.apiVersionPath)/guilds/\(guildID)/threads"
        case let .publicArchivedThreads(channelID, before):
            components.path = "\(DiscordLimits.apiVersionPath)/channels/\(channelID)/threads/archived/public"
            queryItems.append(.init(name: "limit", value: String(DiscordLimits.threadPageSize)))
            if let before { queryItems.append(.init(name: "before", value: before)) }
        case let .joinedPrivateArchivedThreads(channelID, before):
            components.path = "\(DiscordLimits.apiVersionPath)/channels/\(channelID)/users/@me/threads/archived/private"
            queryItems.append(.init(name: "limit", value: String(DiscordLimits.threadPageSize)))
            if let before { queryItems.append(.init(name: "before", value: before)) }
        case let .channelMessages(channelID, before, after, limit):
            components.path = "\(DiscordLimits.apiVersionPath)/channels/\(channelID)/messages"
            queryItems.append(.init(name: "limit", value: String(limit)))
            if let before { queryItems.append(.init(name: "before", value: before)) }
            if let after { queryItems.append(.init(name: "after", value: after)) }
        case let .channelMessage(channelID, messageID):
            components.path = "\(DiscordLimits.apiVersionPath)/channels/\(channelID)/messages/\(messageID)"
        }
        components.queryItems = queryItems.isEmpty
            ? nil
            : queryItems.sorted { $0.name < $1.name }
        guard let url = components.url else { throw DiscordFailure(.invalidEndpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = DiscordLimits.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try DiscordEndpointPolicy.validateUnauthenticated(request)
        return request
    }
}

enum DiscordPermissionSurface: Equatable, Sendable {
    case authentication
    case guild
    case channel
}

enum DiscordEndpointPolicy {
    static func validateUnauthenticated(_ request: URLRequest) throws {
        guard request.httpMethod == "GET" else {
            throw DiscordFailure(.writeEndpointRejected)
        }
        guard request.httpBody == nil,
              request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DiscordLimits.apiScheme,
              components.host?.lowercased() == DiscordLimits.apiHost,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { throw DiscordFailure(.authorizationBoundaryViolation) }

        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 4,
              segments[0] == "api",
              segments[1] == "v10"
        else { throw DiscordFailure(.invalidEndpoint) }

        let resourceSegments = Array(segments.dropFirst(2))
        let allowedQueryKeys: Set<String>
        if resourceSegments == ["users", "@me"] {
            allowedQueryKeys = []
        } else if resourceSegments == ["users", "@me", "guilds"] {
            allowedQueryKeys = ["after", "limit"]
        } else if resourceSegments.count == 3,
                  resourceSegments[0] == "guilds",
                  resourceSegments[2] == "channels" || resourceSegments[2] == "threads" {
            let guildID = resourceSegments[1]
            guard DiscordValidation.isSnowflake(guildID) else {
                throw DiscordFailure(.invalidEndpoint)
            }
            allowedQueryKeys = []
        } else if resourceSegments.count == 5,
                  resourceSegments[0] == "channels",
                  Array(resourceSegments.dropFirst(2)) == ["threads", "archived", "public"] {
            let channelID = resourceSegments[1]
            guard DiscordValidation.isSnowflake(channelID) else {
                throw DiscordFailure(.invalidEndpoint)
            }
            allowedQueryKeys = ["before", "limit"]
        } else if resourceSegments.count == 7,
                  resourceSegments[0] == "channels",
                  Array(resourceSegments.dropFirst(2)) == ["users", "@me", "threads", "archived", "private"] {
            let channelID = resourceSegments[1]
            guard DiscordValidation.isSnowflake(channelID) else {
                throw DiscordFailure(.invalidEndpoint)
            }
            allowedQueryKeys = ["before", "limit"]
        } else if resourceSegments.count == 3,
                  resourceSegments[0] == "channels",
                  resourceSegments[2] == "messages" {
            let channelID = resourceSegments[1]
            guard DiscordValidation.isSnowflake(channelID) else {
                throw DiscordFailure(.invalidEndpoint)
            }
            allowedQueryKeys = ["after", "before", "limit"]
        } else if resourceSegments.count == 4,
                  resourceSegments[0] == "channels",
                  resourceSegments[2] == "messages" {
            let channelID = resourceSegments[1]
            let messageID = resourceSegments[3]
            guard DiscordValidation.isSnowflake(channelID),
                  DiscordValidation.isSnowflake(messageID)
            else { throw DiscordFailure(.invalidEndpoint) }
            allowedQueryKeys = []
        } else {
            throw DiscordFailure(.invalidEndpoint)
        }

        let queryItems = components.queryItems ?? []
        let keys = queryItems.map { $0.name.lowercased() }
        guard Set(keys).count == keys.count,
              Set(keys).isSubset(of: allowedQueryKeys),
              !keys.contains(where: {
                  ["token", "access_token", "authorization", "client_secret"].contains($0)
              }),
              !(keys.contains("before") && keys.contains("after"))
        else { throw DiscordFailure(.invalidRequest) }

        for item in queryItems {
            switch item.name.lowercased() {
            case "before", "after":
                guard let value = item.value,
                      DiscordValidation.isBoundedCursor(value)
                else {
                    throw DiscordFailure(.invalidRequest)
                }
            case "limit":
                guard let value = item.value,
                      let limit = Int(value),
                      (1...DiscordLimits.guildPageSize).contains(limit)
                else { throw DiscordFailure(.invalidRequest) }
            default:
                break
            }
        }
    }
}

struct DiscordHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
    let headers: [String: String]
}

enum DiscordTransportDisposition: Equatable, Sendable {
    case productionURLSession
    case testFixture
}

protocol DiscordRESTTransporting: Sendable {
    var disposition: DiscordTransportDisposition { get }
    func data(
        for unauthenticatedRequest: URLRequest,
        botToken: String,
        requestID: UUID,
        responseLimit: Int
    ) async throws -> DiscordHTTPResponse
    func cancel(requestID: UUID) async
}

/// Marker required by the explicit test factory. Production initialization never
/// accepts an injected transport.
protocol DiscordTestingTransporting: DiscordRESTTransporting { }

final class DiscordURLSessionTransport: NSObject, DiscordRESTTransporting, @unchecked Sendable {
    let disposition = DiscordTransportDisposition.productionURLSession

    private final class TaskState {
        let requestID: UUID
        let responseLimit: Int
        var data = Data()
        var response: HTTPURLResponse?
        var terminalFailure: Error?
        var continuation: CheckedContinuation<DiscordHTTPResponse, Error>?

        init(
            requestID: UUID,
            responseLimit: Int,
            continuation: CheckedContinuation<DiscordHTTPResponse, Error>
        ) {
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
        configuration.timeoutIntervalForRequest = DiscordLimits.requestTimeout
        configuration.timeoutIntervalForResource = DiscordLimits.resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.name = "com.agentloki.LokiBrief.discord.transport"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func data(
        for unauthenticatedRequest: URLRequest,
        botToken: String,
        requestID: UUID,
        responseLimit: Int
    ) async throws -> DiscordHTTPResponse {
        try DiscordEndpointPolicy.validateUnauthenticated(unauthenticatedRequest)
        guard DiscordValidation.isValidToken(botToken) else {
            throw DiscordFailure(.invalidCredential)
        }
        guard responseLimit > 0,
              responseLimit <= DiscordLimits.maximumResponseBytes
        else { throw DiscordFailure(.responseTooLarge) }
        guard !Task.isCancelled else { throw DiscordFailure(.cancelled) }

        var request = unauthenticatedRequest
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "AgentLoki-LokiBrief/1.0 (Discord read-only connector)",
            forHTTPHeaderField: "User-Agent"
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = TaskState(
                    requestID: requestID,
                    responseLimit: responseLimit,
                    continuation: continuation
                )
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

    private func setFailure(_ error: Error, task: URLSessionTask) {
        lock.lock()
        statesByTaskID[task.taskIdentifier]?.terminalFailure = error
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
            continuation.resume(throwing: DiscordFailure(.cancelled))
        } else if let networkError {
            continuation.resume(throwing: networkError)
        } else if let response = state.response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key] = String(describing: value)
            }
            continuation.resume(returning: .init(
                data: state.data,
                statusCode: response.statusCode,
                finalURL: response.url,
                headers: headers
            ))
        } else {
            continuation.resume(throwing: DiscordFailure(.invalidSchema))
        }
    }
}

extension DiscordURLSessionTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            setFailure(DiscordFailure(.invalidSchema), task: dataTask)
            completionHandler(.cancel)
            return
        }
        var shouldCancel = false
        lock.lock()
        if let state = statesByTaskID[dataTask.taskIdentifier] {
            state.response = response
            if response.expectedContentLength > Int64(state.responseLimit) {
                state.terminalFailure = DiscordFailure(.responseTooLarge)
                shouldCancel = true
            }
        }
        lock.unlock()
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        lock.lock()
        if let state = statesByTaskID[dataTask.taskIdentifier] {
            if data.count > state.responseLimit - state.data.count {
                state.terminalFailure = DiscordFailure(.responseTooLarge)
                shouldCancel = true
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        setFailure(DiscordFailure(.invalidEndpoint, httpStatus: response.statusCode), task: task)
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        complete(task, networkError: error)
    }
}

struct DiscordGuild: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let displayName: String
}

struct DiscordChannel: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let guildID: String
    let parentChannelID: String?
    let displayName: String
    let type: DiscordChannelType
    let isArchived: Bool

    var isThreadContainerOnly: Bool {
        !type.isThread && type.isThreadContainerOnly
    }

    var permitsDirectHistorySelection: Bool {
        type.isThread || (type.supportsDirectHistory && !type.isThreadContainerOnly)
    }
}

struct DiscordBotIdentity: Codable, Hashable, Sendable {
    let botUserID: String
    let displayName: String
}

struct DiscordMessageAuthor: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let isBot: Bool
}

struct DiscordAttachmentDescriptor: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let filename: String
    let mediaType: String
    let byteCount: Int
    let widthPixels: Int?
    let heightPixels: Int?
    let metadataHash: String
    let bodyDownloaded: Bool
}

struct DiscordImportedMessage: Codable, Hashable, Sendable, Identifiable {
    var id: String { envelope.deduplicationKey }
    let guildID: String
    let channelID: String
    let threadID: String?
    let messageID: String
    let replyToMessageID: String?
    let author: DiscordMessageAuthor
    let bodyState: DiscordMessageBodyState
    let attachments: [DiscordAttachmentDescriptor]
    let envelope: ConnectorRecordEnvelope
}

enum DiscordDiscoveryLimitationScope: String, Codable, CaseIterable, Hashable, Sendable {
    case guild
    case channel
}

struct DiscordDiscoveryLimitation: Codable, Hashable, Sendable {
    let scope: DiscordDiscoveryLimitationScope
    let sourceIdentifierHash: String
    let reasonCode: DiscordFailureCode

    init(
        scope: DiscordDiscoveryLimitationScope,
        sourceIdentifier: String,
        reasonCode: DiscordFailureCode
    ) {
        self.scope = scope
        self.sourceIdentifierHash = DiscordPrivacy.digest(sourceIdentifier)
        self.reasonCode = reasonCode
    }
}

struct DiscordDiscoveryResult: Codable, Hashable, Sendable {
    let guilds: [DiscordGuild]
    let channels: [DiscordChannel]
    let threads: [DiscordChannel]
    let skippedGuildCount: Int
    let skippedChannelCount: Int
    let skippedDirectMessageCount: Int
    let messageContentAccess: DiscordMessageContentAccess
    let limitations: [DiscordDiscoveryLimitation]

    var isComplete: Bool { limitations.isEmpty }

    var reasonCode: String {
        if limitations.contains(where: { $0.reasonCode == .missingGuildPermission }) {
            return DiscordFailureCode.missingGuildPermission.rawValue
        }
        if limitations.contains(where: { $0.reasonCode == .missingChannelPermission }) {
            return DiscordFailureCode.missingChannelPermission.rawValue
        }
        if limitations.contains(where: { $0.reasonCode == .resourceUnavailable }) {
            return DiscordFailureCode.resourceUnavailable.rawValue
        }
        if messageContentAccess == .limitedByPrivilegedIntent {
            return DiscordFailureCode.messageContentIntentMissing.rawValue
        }
        return "discord_source_discovery_succeeded"
    }
}

struct DiscordRateLimitState: Codable, Hashable, Sendable {
    let retryAfterSeconds: TimeInterval
    let retryAt: Date
    let isGlobal: Bool
    let observedAt: Date
}

struct DiscordConnectionSnapshot: Codable, Hashable, Sendable {
    let accountIdentifier: String
    let credentialReference: String?
    let state: DiscordConnectionState
    let messageContentAccess: DiscordMessageContentAccess
    let lastAttemptedAt: Date?
    let lastSuccessfulSyncAt: Date?
    let importedItemCount: Int
    let skippedItemCount: Int
    let attachmentCount: Int
    let latestReasonCode: String?
    let rateLimitState: DiscordRateLimitState?
}

enum DiscordSyncMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Uses a complete first backfill, incremental polling thereafter, and a
    /// bounded periodic full reconciliation for edits and deletions.
    case automatic
    /// Polls from the persisted high-watermark when one exists. The first run
    /// still performs a complete historical backfill so no interval is skipped.
    case incremental
    /// Reads the complete retained history and is the only mode allowed to
    /// advance absence observations or emit conservative tombstones.
    case fullReconciliation = "full_reconciliation"
}

struct DiscordSyncOutputLimit: Codable, Hashable, Sendable {
    static let production = DiscordSyncOutputLimit(
        uncheckedMaximumMessages: DiscordLimits.maximumSyncOutputMessages,
        uncheckedMaximumEstimatedBytes: DiscordLimits.maximumSyncOutputBytes
    )

    let maximumMessages: Int
    let maximumEstimatedBytes: Int

    init(
        maximumMessages: Int,
        maximumEstimatedBytes: Int = DiscordLimits.maximumSyncOutputBytes
    ) throws {
        guard (1...DiscordLimits.maximumSyncOutputMessages).contains(maximumMessages),
              (DiscordLimits.maximumResponseBytes...DiscordLimits.maximumSyncOutputBytes)
                .contains(maximumEstimatedBytes)
        else { throw DiscordFailure(.invalidAuthority) }
        self.maximumMessages = maximumMessages
        self.maximumEstimatedBytes = maximumEstimatedBytes
    }

    private init(
        uncheckedMaximumMessages: Int,
        uncheckedMaximumEstimatedBytes: Int
    ) {
        maximumMessages = uncheckedMaximumMessages
        maximumEstimatedBytes = uncheckedMaximumEstimatedBytes
    }
}

enum DiscordSelectionHistoryCoverage: String, Codable, CaseIterable, Hashable, Sendable {
    case historicalBackfill = "historical_backfill"
    case incremental
    case fullReconciliation = "full_reconciliation"

    var permitsAbsenceReconciliation: Bool {
        self == .historicalBackfill || self == .fullReconciliation
    }
}

/// Fixed-size membership evidence for pre-existing records observed during a
/// history traversal that spans multiple sync calls. Bloom false positives can
/// suppress a tombstone, but can never create one, which keeps deletion
/// reconciliation conservative without persisting raw Discord identifiers.
struct DiscordObservedExistingFilter: Codable, Hashable, Sendable {
    private static let hashCount = 7

    private(set) var bits: Data

    private enum CodingKeys: String, CodingKey {
        case bits
        case integrityHash
    }

    init(expectedItemCount: Int) throws {
        guard expectedItemCount > 0 else { throw DiscordFailure(.invalidSchema) }
        let desiredBytes = max(128, (expectedItemCount * 12 + 7) / 8)
        bits = Data(
            repeating: 0,
            count: min(DiscordLimits.maximumObservationFilterBytes, desiredBytes)
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try values.decode(Data.self, forKey: .bits)
        let integrityHash = try values.decode(String.self, forKey: .integrityHash)
        guard (128...DiscordLimits.maximumObservationFilterBytes).contains(decoded.count),
              ConnectorEnvelopeValidation.validSHA256(integrityHash),
              integrityHash == ConnectorEnvelopeDigest.sha256(decoded)
        else { throw DiscordFailure(.invalidSchema) }
        bits = decoded
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bits, forKey: .bits)
        try values.encode(
            ConnectorEnvelopeDigest.sha256(bits),
            forKey: .integrityHash
        )
    }

    mutating func insert(_ value: String) {
        for bit in bitOffsets(value) {
            bits[bit / 8] |= UInt8(1 << UInt8(bit % 8))
        }
    }

    func mightContain(_ value: String) -> Bool {
        bitOffsets(value).allSatisfy {
            bits[$0 / 8] & UInt8(1 << UInt8($0 % 8)) != 0
        }
    }

    private func bitOffsets(_ value: String) -> [Int] {
        let digest = Array(SHA256.hash(data: Data(value.utf8)))
        let bitCount = bits.count * 8
        return (0..<Self.hashCount).map { index in
            let offset = index * 4
            let word = digest[offset..<offset + 4].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            return Int(word) % bitCount
        }
    }
}

struct DiscordPendingHistoryContinuation: Codable, Hashable, Sendable {
    let coverage: DiscordSelectionHistoryCoverage
    let targetHighWatermarkMessageID: String
    let lastPaginationReceipt: ConnectorPaginationReceipt
    let observedExistingFilter: DiscordObservedExistingFilter?

    private enum CodingKeys: String, CodingKey {
        case coverage
        case targetHighWatermarkMessageID
        case lastPaginationReceipt
        case observedExistingFilter
    }

    init(
        coverage: DiscordSelectionHistoryCoverage,
        targetHighWatermarkMessageID: String,
        lastPaginationReceipt: ConnectorPaginationReceipt,
        observedExistingFilter: DiscordObservedExistingFilter?
    ) throws {
        try lastPaginationReceipt.validateIntegrity()
        guard coverage.permitsAbsenceReconciliation,
              DiscordValidation.isSnowflake(targetHighWatermarkMessageID),
              !lastPaginationReceipt.isComplete,
              lastPaginationReceipt.sourceHighWatermark == targetHighWatermarkMessageID,
              lastPaginationReceipt.nextCursor.map(DiscordValidation.isSnowflake) == true
        else { throw DiscordFailure(.invalidSchema) }
        self.coverage = coverage
        self.targetHighWatermarkMessageID = targetHighWatermarkMessageID
        self.lastPaginationReceipt = lastPaginationReceipt
        self.observedExistingFilter = observedExistingFilter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            coverage: values.decode(
                DiscordSelectionHistoryCoverage.self,
                forKey: .coverage
            ),
            targetHighWatermarkMessageID: values.decode(
                String.self,
                forKey: .targetHighWatermarkMessageID
            ),
            lastPaginationReceipt: values.decode(
                ConnectorPaginationReceipt.self,
                forKey: .lastPaginationReceipt
            ),
            observedExistingFilter: values.decodeIfPresent(
                DiscordObservedExistingFilter.self,
                forKey: .observedExistingFilter
            )
        )
    }
}

struct DiscordPendingIncrementalCursor: Codable, Hashable, Sendable {
    let targetHighWatermarkMessageID: String
    let lastPaginationReceipt: ConnectorPaginationReceipt

    private enum CodingKeys: String, CodingKey {
        case targetHighWatermarkMessageID
        case lastPaginationReceipt
    }

    init(
        targetHighWatermarkMessageID: String,
        lastPaginationReceipt: ConnectorPaginationReceipt
    ) throws {
        try lastPaginationReceipt.validateIntegrity()
        guard DiscordValidation.isSnowflake(targetHighWatermarkMessageID),
              !lastPaginationReceipt.isComplete,
              lastPaginationReceipt.sourceHighWatermark == targetHighWatermarkMessageID,
              lastPaginationReceipt.nextCursor.map(DiscordValidation.isSnowflake) == true
        else { throw DiscordFailure(.invalidSchema) }
        self.targetHighWatermarkMessageID = targetHighWatermarkMessageID
        self.lastPaginationReceipt = lastPaginationReceipt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            targetHighWatermarkMessageID: values.decode(
                String.self,
                forKey: .targetHighWatermarkMessageID
            ),
            lastPaginationReceipt: values.decode(
                ConnectorPaginationReceipt.self,
                forKey: .lastPaginationReceipt
            )
        )
    }
}

struct DiscordSelectionSyncCursor: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let highWatermarkMessageID: String?
    let incrementalPollsSinceFullReconciliation: Int
    let lastCompletedCoverage: DiscordSelectionHistoryCoverage?
    let pendingIncremental: DiscordPendingIncrementalCursor?
    let pendingHistoryContinuation: DiscordPendingHistoryContinuation?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case highWatermarkMessageID
        case incrementalPollsSinceFullReconciliation
        case lastCompletedCoverage
        case pendingIncremental
        case pendingHistoryContinuation
    }

    init(
        schemaVersion: Int = 1,
        highWatermarkMessageID: String?,
        incrementalPollsSinceFullReconciliation: Int,
        lastCompletedCoverage: DiscordSelectionHistoryCoverage?,
        pendingIncremental: DiscordPendingIncrementalCursor? = nil,
        pendingHistoryContinuation: DiscordPendingHistoryContinuation? = nil
    ) throws {
        let pendingOrderIsValid: Bool
        if let pendingIncremental,
           let highWatermarkMessageID,
           let prior = UInt64(highWatermarkMessageID),
           let target = UInt64(pendingIncremental.targetHighWatermarkMessageID),
           let nextCursor = pendingIncremental.lastPaginationReceipt.nextCursor,
           let next = UInt64(nextCursor)
        {
            let requestOrderIsValid: Bool
            if let requestCursor = pendingIncremental.lastPaginationReceipt.requestCursor,
               let request = UInt64(requestCursor) {
                requestOrderIsValid = request > next
            } else {
                requestOrderIsValid =
                    pendingIncremental.lastPaginationReceipt.requestCursor == nil
            }
            pendingOrderIsValid = target > prior && target >= next && next > prior &&
                requestOrderIsValid
        } else {
            pendingOrderIsValid = pendingIncremental == nil
        }
        guard schemaVersion == 1,
              highWatermarkMessageID.map(DiscordValidation.isSnowflake) ?? true,
              (0...DiscordLimits.incrementalPollsBeforeFullReconciliation)
                .contains(incrementalPollsSinceFullReconciliation),
              pendingOrderIsValid,
              pendingIncremental == nil || pendingHistoryContinuation == nil,
              lastCompletedCoverage != .incremental || highWatermarkMessageID != nil
        else { throw DiscordFailure(.invalidSchema) }
        self.schemaVersion = schemaVersion
        self.highWatermarkMessageID = highWatermarkMessageID
        self.incrementalPollsSinceFullReconciliation =
            incrementalPollsSinceFullReconciliation
        self.lastCompletedCoverage = lastCompletedCoverage
        self.pendingIncremental = pendingIncremental
        self.pendingHistoryContinuation = pendingHistoryContinuation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            highWatermarkMessageID: values.decodeIfPresent(
                String.self,
                forKey: .highWatermarkMessageID
            ),
            incrementalPollsSinceFullReconciliation: values.decode(
                Int.self,
                forKey: .incrementalPollsSinceFullReconciliation
            ),
            lastCompletedCoverage: values.decodeIfPresent(
                DiscordSelectionHistoryCoverage.self,
                forKey: .lastCompletedCoverage
            ),
            pendingIncremental: values.decodeIfPresent(
                DiscordPendingIncrementalCursor.self,
                forKey: .pendingIncremental
            ),
            pendingHistoryContinuation: values.decodeIfPresent(
                DiscordPendingHistoryContinuation.self,
                forKey: .pendingHistoryContinuation
            )
        )
    }
}

struct DiscordReconciliationState: Codable, Hashable, Sendable {
    var missingCompleteObservations: [String: Int]
    var selectionCursors: [String: DiscordSelectionSyncCursor]
    var nextSelectionIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case missingCompleteObservations
        case selectionCursors
        case nextSelectionIdentifier
    }

    init(
        missingCompleteObservations: [String: Int] = [:],
        selectionCursors: [String: DiscordSelectionSyncCursor] = [:],
        nextSelectionIdentifier: String? = nil
    ) {
        self.missingCompleteObservations = missingCompleteObservations.filter {
            !$0.key.isEmpty && $0.value > 0
        }
        self.selectionCursors = selectionCursors.filter { !$0.key.isEmpty }
        self.nextSelectionIdentifier = nextSelectionIdentifier.flatMap {
            ConnectorEnvelopeValidation.validIdentifier($0) ? $0 : nil
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            missingCompleteObservations: try values.decodeIfPresent(
                [String: Int].self,
                forKey: .missingCompleteObservations
            ) ?? [:],
            selectionCursors: try values.decodeIfPresent(
                [String: DiscordSelectionSyncCursor].self,
                forKey: .selectionCursors
            ) ?? [:],
            nextSelectionIdentifier: try values.decodeIfPresent(
                String.self,
                forKey: .nextSelectionIdentifier
            )
        )
    }
}

struct DiscordSyncReceipt: Codable, Hashable, Sendable {
    let traceID: String
    let checkpointIdentifier: String
    let startedAt: Date
    let completedAt: Date
    let selectionCount: Int
    let completeSelectionCount: Int
    let importedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
    let tombstoneCount: Int
    let skippedCount: Int
    let attachmentCount: Int
    let estimatedOutputBytes: Int
    let outputLimitReached: Bool
    let isComplete: Bool
    let reasonCode: String
}

struct DiscordSyncResult: Codable, Hashable, Sendable {
    let messages: [DiscordImportedMessage]
    let reconciliations: [ConnectorReconciliationResult]
    let reconciliationState: DiscordReconciliationState
    let receipt: DiscordSyncReceipt
}

struct DiscordVaultAdmissionDescriptor: Codable, Hashable, Sendable, Identifiable {
    var id: String { envelope.deduplicationKey }
    let envelope: ConnectorRecordEnvelope
    let privacyBoundedTitle: String
    let pseudonymousAuthorIdentifier: String?
    let authorDisplayName: String?
    let authorIsBot: Bool?
    let guildIdentifierHash: String?
    let channelIdentifierHash: String?
    let threadIdentifierHash: String?
    let messageIdentifierHash: String
    let replyToMessageIdentifierHash: String?
    let bodyState: DiscordMessageBodyState?
    let attachments: [DiscordAttachmentDescriptor]
}

struct DiscordVaultAdmissionGroup: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let pseudonymousAccountIdentifier: String
    let sourceContainerIdentifierHash: String
    let streamIdentifierHash: String
    let checkpointIdentifierHash: String
    let pageOrdinal: Int
    let paginationReceiptHash: String
    let isComplete: Bool
    let descriptors: [DiscordVaultAdmissionDescriptor]

    var envelopes: [ConnectorRecordEnvelope] { descriptors.map(\.envelope) }
}

enum DiscordVaultAdmissionAdapter {
    private struct GroupKey: Hashable {
        let pseudonymousAccountIdentifier: String
        let sourceContainerIdentifierHash: String
        let streamIdentifierHash: String
        let checkpointIdentifierHash: String
        let pageOrdinal: Int
        let paginationReceiptHash: String
        let isComplete: Bool
    }

    /// Produces deterministic page-scoped batches without exposing raw guild,
    /// channel, thread, cursor, or checkpoint identifiers in the grouping key.
    /// Envelope payloads remain unchanged for the existing Vault admission gate.
    static func groups(from result: DiscordSyncResult) throws -> [DiscordVaultAdmissionGroup] {
        var byCanonicalHash: [String: DiscordVaultAdmissionDescriptor] = [:]
        for message in result.messages {
            let envelope = message.envelope
            byCanonicalHash[envelope.canonicalEnvelopeHash] = .init(
                envelope: envelope,
                privacyBoundedTitle: message.threadID == nil
                    ? "Discord channel message"
                    : "Discord thread message",
                pseudonymousAuthorIdentifier: DiscordPrivacy.digest(
                    "\(envelope.pseudonymousAccountIdentifier):author:\(message.author.id)"
                ),
                authorDisplayName: DiscordPrivacy.boundedName(
                    message.author.displayName,
                    fallback: "Discord member"
                ),
                authorIsBot: message.author.isBot,
                guildIdentifierHash: DiscordPrivacy.digest(message.guildID),
                channelIdentifierHash: DiscordPrivacy.digest(message.channelID),
                threadIdentifierHash: message.threadID.map(DiscordPrivacy.digest),
                messageIdentifierHash: DiscordPrivacy.digest(message.messageID),
                replyToMessageIdentifierHash:
                    message.replyToMessageID.map(DiscordPrivacy.digest),
                bodyState: message.bodyState,
                attachments: message.attachments
            )
        }
        for reconciliation in result.reconciliations
            where reconciliation.disposition == .tombstoned
        {
            let envelope = reconciliation.selectedEnvelope
            byCanonicalHash[envelope.canonicalEnvelopeHash] = .init(
                envelope: envelope,
                privacyBoundedTitle: "Deleted Discord message",
                pseudonymousAuthorIdentifier: nil,
                authorDisplayName: nil,
                authorIsBot: nil,
                guildIdentifierHash: nil,
                channelIdentifierHash: nil,
                threadIdentifierHash: nil,
                messageIdentifierHash: DiscordPrivacy.digest(
                    envelope.remoteRecordIdentifier
                ),
                replyToMessageIdentifierHash: nil,
                bodyState: nil,
                attachments: []
            )
        }

        var grouped: [GroupKey: [DiscordVaultAdmissionDescriptor]] = [:]
        for descriptor in byCanonicalHash.values {
            let envelope = descriptor.envelope
            guard envelope.provider == "discord",
                  let sourceContainer = envelope.provenance.sourceContainerIdentifier,
                  ConnectorEnvelopeValidation.validIdentifier(sourceContainer),
                  ConnectorEnvelopeValidation.validSHA256(
                      envelope.paginationReceipt.receiptHash
                  )
            else { throw DiscordFailure(.invalidSchema) }
            let receipt = envelope.paginationReceipt
            let key = GroupKey(
                pseudonymousAccountIdentifier: envelope.pseudonymousAccountIdentifier,
                sourceContainerIdentifierHash: DiscordPrivacy.digest(sourceContainer),
                streamIdentifierHash: DiscordPrivacy.digest(receipt.streamIdentifier),
                checkpointIdentifierHash: DiscordPrivacy.digest(receipt.checkpointIdentifier),
                pageOrdinal: receipt.pageOrdinal,
                paginationReceiptHash: receipt.receiptHash,
                isComplete: receipt.isComplete
            )
            grouped[key, default: []].append(descriptor)
        }

        return grouped.map { key, descriptors in
            let id = DiscordPrivacy.digest(
                ConnectorEnvelopeDigest.lengthPrefixed([
                    key.pseudonymousAccountIdentifier,
                    key.sourceContainerIdentifierHash,
                    key.streamIdentifierHash,
                    key.checkpointIdentifierHash,
                    String(key.pageOrdinal),
                    key.paginationReceiptHash,
                    String(key.isComplete),
                ])
            )
            return DiscordVaultAdmissionGroup(
                id: id,
                pseudonymousAccountIdentifier: key.pseudonymousAccountIdentifier,
                sourceContainerIdentifierHash: key.sourceContainerIdentifierHash,
                streamIdentifierHash: key.streamIdentifierHash,
                checkpointIdentifierHash: key.checkpointIdentifierHash,
                pageOrdinal: key.pageOrdinal,
                paginationReceiptHash: key.paginationReceiptHash,
                isComplete: key.isComplete,
                descriptors: descriptors.sorted {
                    $0.envelope.deduplicationKey < $1.envelope.deduplicationKey
                }
            )
        }.sorted {
            if $0.sourceContainerIdentifierHash != $1.sourceContainerIdentifierHash {
                return $0.sourceContainerIdentifierHash < $1.sourceContainerIdentifierHash
            }
            if $0.pageOrdinal != $1.pageOrdinal { return $0.pageOrdinal < $1.pageOrdinal }
            return $0.id < $1.id
        }
    }
}

enum DiscordLocalDataDisposition: String, Codable, Hashable, Sendable {
    case preserved
}

struct DiscordDisconnectResult: Codable, Hashable, Sendable {
    let accountIdentifier: String
    let credentialDeleted: Bool
    let localDataDeleted: Bool
    let localDataDisposition: DiscordLocalDataDisposition
    let remoteMutationAttempted: Bool
    let reasonCode: String
}

protocol DiscordSleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct SystemDiscordSleeper: DiscordSleeping {
    func sleep(seconds: TimeInterval) async throws {
        guard seconds >= 0,
              seconds.isFinite,
              seconds <= DiscordLimits.maximumRetryAfterSeconds
        else { throw DiscordFailure(.invalidRetryAfter) }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

private struct DiscordUserDTO: Decodable {
    let id: String
    let username: String
    let globalName: String?
    let bot: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case bot
    }
}

private struct DiscordGuildDTO: Decodable {
    let id: String
    let name: String
}

private struct DiscordThreadMetadataDTO: Decodable {
    let archived: Bool
    let archiveTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case archived
        case archiveTimestamp = "archive_timestamp"
    }
}

private struct DiscordChannelDTO: Decodable {
    let id: String
    let type: Int
    let guildID: String?
    let name: String?
    let parentID: String?
    let threadMetadata: DiscordThreadMetadataDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case guildID = "guild_id"
        case name
        case parentID = "parent_id"
        case threadMetadata = "thread_metadata"
    }
}

private struct DiscordThreadsPageDTO: Decodable {
    let threads: [DiscordChannelDTO]
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case threads
        case hasMore = "has_more"
    }
}

private struct DiscordMessageAuthorDTO: Decodable {
    let id: String
    let username: String
    let globalName: String?
    let bot: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case bot
    }
}

private struct DiscordAttachmentDTO: Decodable {
    let id: String
    let filename: String
    let contentType: String?
    let size: Int
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case contentType = "content_type"
        case size
        case width
        case height
    }
}

private struct DiscordEmbedFieldDTO: Decodable {
    let name: String?
    let value: String?
}

private struct DiscordEmbedFooterDTO: Decodable {
    let text: String?
}

private struct DiscordEmbedAuthorDTO: Decodable {
    let name: String?
}

private struct DiscordEmbedDTO: Decodable {
    let title: String?
    let description: String?
    let fields: [DiscordEmbedFieldDTO]?
    let footer: DiscordEmbedFooterDTO?
    let author: DiscordEmbedAuthorDTO?
}

private struct DiscordMessageReferenceDTO: Decodable {
    let messageID: String?
    let channelID: String?
    let guildID: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case channelID = "channel_id"
        case guildID = "guild_id"
    }
}

private struct DiscordMessageDTO: Decodable {
    let id: String
    let channelID: String
    let guildID: String?
    let author: DiscordMessageAuthorDTO
    let content: String?
    let timestamp: String
    let editedTimestamp: String?
    let attachments: [DiscordAttachmentDTO]?
    let embeds: [DiscordEmbedDTO]?
    let messageReference: DiscordMessageReferenceDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case guildID = "guild_id"
        case author
        case content
        case timestamp
        case editedTimestamp = "edited_timestamp"
        case attachments
        case embeds
        case messageReference = "message_reference"
    }
}

private struct DiscordErrorDTO: Decodable {
    let code: Int?
    let retryAfter: TimeInterval?
    let global: Bool?

    enum CodingKeys: String, CodingKey {
        case code
        case retryAfter = "retry_after"
        case global
    }
}

private enum DiscordDateParser {
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private enum DiscordJSONGuard {
    static func validate(_ data: Data) throws {
        guard data.count <= DiscordLimits.maximumResponseBytes else {
            throw DiscordFailure(.responseTooLarge)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DiscordFailure(.invalidJSON)
        }
        var containers = 0
        try inspect(object, depth: 0, containers: &containers)
    }

    private static func inspect(_ value: Any, depth: Int, containers: inout Int) throws {
        guard depth <= DiscordLimits.maximumJSONDepth else {
            throw DiscordFailure(.invalidJSON)
        }
        if let array = value as? [Any] {
            containers += 1
            guard containers <= DiscordLimits.maximumJSONContainers else {
                throw DiscordFailure(.invalidJSON)
            }
            for item in array { try inspect(item, depth: depth + 1, containers: &containers) }
        } else if let dictionary = value as? [String: Any] {
            containers += 1
            guard containers <= DiscordLimits.maximumJSONContainers else {
                throw DiscordFailure(.invalidJSON)
            }
            for item in dictionary.values {
                try inspect(item, depth: depth + 1, containers: &containers)
            }
        }
    }
}

private actor DiscordRESTClient {
    typealias TraceSink = @Sendable (DiscordTraceEvent) -> Void
    typealias RateLimitSink = @Sendable (String, DiscordRateLimitState?) -> Void

    private let credentialStore: any DiscordCredentialStoring
    private let transport: any DiscordRESTTransporting
    private let sleeper: any DiscordSleeping
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?
    private let rateLimitSink: RateLimitSink?
    private var activeRequestIDs: Set<UUID> = []
    private var waitTasks: [UUID: Task<Void, Error>] = [:]
    private var cancellationEpoch: UInt64 = 0

    init(
        credentialStore: any DiscordCredentialStoring,
        transport: any DiscordRESTTransporting,
        sleeper: any DiscordSleeping,
        now: @escaping @Sendable () -> Date,
        eventSink: TraceSink?,
        rateLimitSink: RateLimitSink?
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.sleeper = sleeper
        self.now = now
        self.eventSink = eventSink
        self.rateLimitSink = rateLimitSink
    }

    func currentBot(
        accountIdentifier: String,
        trace: DiscordTraceContext
    ) async throws -> DiscordUserDTO {
        try decode(
            DiscordUserDTO.self,
            from: await perform(
                endpoint: .currentBot,
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func guilds(
        accountIdentifier: String,
        after: String?,
        trace: DiscordTraceContext
    ) async throws -> [DiscordGuildDTO] {
        try decode(
            [DiscordGuildDTO].self,
            from: await perform(
                endpoint: .currentGuilds(after: after),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func channels(
        accountIdentifier: String,
        guildID: String,
        trace: DiscordTraceContext
    ) async throws -> [DiscordChannelDTO] {
        try decode(
            [DiscordChannelDTO].self,
            from: await perform(
                endpoint: .guildChannels(guildID: guildID),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func activeThreads(
        accountIdentifier: String,
        guildID: String,
        trace: DiscordTraceContext
    ) async throws -> DiscordThreadsPageDTO {
        try decode(
            DiscordThreadsPageDTO.self,
            from: await perform(
                endpoint: .activeGuildThreads(guildID: guildID),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func publicArchivedThreads(
        accountIdentifier: String,
        channelID: String,
        before: String?,
        trace: DiscordTraceContext
    ) async throws -> DiscordThreadsPageDTO {
        try decode(
            DiscordThreadsPageDTO.self,
            from: await perform(
                endpoint: .publicArchivedThreads(channelID: channelID, before: before),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func joinedPrivateArchivedThreads(
        accountIdentifier: String,
        channelID: String,
        before: String?,
        trace: DiscordTraceContext
    ) async throws -> DiscordThreadsPageDTO {
        try decode(
            DiscordThreadsPageDTO.self,
            from: await perform(
                endpoint: .joinedPrivateArchivedThreads(channelID: channelID, before: before),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func messages(
        accountIdentifier: String,
        channelID: String,
        before: String?,
        after: String? = nil,
        limit: Int = DiscordLimits.historyPageSize,
        trace: DiscordTraceContext
    ) async throws -> [DiscordMessageDTO] {
        try decode(
            [DiscordMessageDTO].self,
            from: await perform(
                endpoint: .channelMessages(
                    channelID: channelID,
                    before: before,
                    after: after,
                    limit: limit
                ),
                accountIdentifier: accountIdentifier,
                trace: trace
            ).data
        )
    }

    func cancelAll(trace: DiscordTraceContext) async {
        cancellationEpoch &+= 1
        let requests = activeRequestIDs
        let waits = waitTasks.values
        activeRequestIDs.removeAll()
        waitTasks.removeAll()
        for wait in waits { wait.cancel() }
        for requestID in requests { await transport.cancel(requestID: requestID) }
        emit(
            .cancellation,
            trace: trace,
            status: .success,
            reasonCode: DiscordFailureCode.cancelled.rawValue,
            metadata: .init([(.operation, "cancel_all")])
        )
    }

    private func perform(
        endpoint: DiscordRESTEndpoint,
        accountIdentifier: String,
        trace: DiscordTraceContext
    ) async throws -> DiscordHTTPResponse {
        let epoch = cancellationEpoch
        var transientRetries = 0
        var rateLimitRetries = 0

        while true {
            try checkCancellation(epoch: epoch)
            let credential: DiscordBotCredential
            do {
                credential = try await credentialStore.read(
                    accountIdentifier: accountIdentifier,
                    trace: trace.child()
                )
            } catch let failure as DiscordCredentialStoreFailure {
                if failure.code == .notFound {
                    throw DiscordFailure(.credentialNotFound)
                }
                throw DiscordFailure(.credentialStoreUnavailable)
            }
            let request = try endpoint.request()
            let requestID = UUID()
            activeRequestIDs.insert(requestID)
            emit(
                .networkRequest,
                trace: trace,
                status: .started,
                reasonCode: "discord_request_started",
                metadata: .init([
                    (.endpoint, endpoint.traceName),
                    (.accountHash, DiscordPrivacy.shortHash(accountIdentifier)),
                    (.retryCount, String(transientRetries + rateLimitRetries)),
                ])
            )

            do {
                let response = try await transport.data(
                    for: request,
                    botToken: credential.token,
                    requestID: requestID,
                    responseLimit: DiscordLimits.maximumResponseBytes
                )
                activeRequestIDs.remove(requestID)
                try validateFinalURL(response.finalURL)

                if response.statusCode == 429 {
                    let parsed = try retryAfter(response)
                    let state = DiscordRateLimitState(
                        retryAfterSeconds: parsed.seconds,
                        retryAt: now().addingTimeInterval(parsed.seconds),
                        isGlobal: parsed.global,
                        observedAt: now()
                    )
                    rateLimitSink?(accountIdentifier, state)
                    emit(
                        .rateLimit,
                        trace: trace,
                        status: .degraded,
                        reasonCode: DiscordFailureCode.rateLimited.rawValue,
                        metadata: .init([
                            (.endpoint, endpoint.traceName),
                            (.retryAfterMilliseconds, String(Int(parsed.seconds * 1_000))),
                            (.retryCount, String(rateLimitRetries + 1)),
                        ])
                    )
                    guard rateLimitRetries < 2 else {
                        throw DiscordFailure(
                            .rateLimited,
                            httpStatus: 429,
                            retryAfterSeconds: parsed.seconds
                        )
                    }
                    rateLimitRetries += 1
                    try await wait(seconds: parsed.seconds)
                    continue
                }

                if response.statusCode == 401 {
                    throw DiscordFailure(.invalidToken, httpStatus: 401)
                }
                if response.statusCode == 403 {
                    let code: DiscordFailureCode = endpoint.permissionSurface == .channel
                        ? .missingChannelPermission
                        : .missingGuildPermission
                    throw DiscordFailure(code, httpStatus: 403)
                }
                if response.statusCode == 404 {
                    let providerCode = (try? JSONDecoder().decode(
                        DiscordErrorDTO.self,
                        from: response.data
                    ))?.code
                    throw DiscordFailure(
                        .resourceUnavailable,
                        httpStatus: 404,
                        providerCode: providerCode
                    )
                }
                if (500...599).contains(response.statusCode) {
                    guard transientRetries < 1 else {
                        throw DiscordFailure(
                            .transientFailureExhausted,
                            httpStatus: response.statusCode
                        )
                    }
                    transientRetries += 1
                    try await wait(seconds: 0.25)
                    continue
                }
                guard (200...299).contains(response.statusCode) else {
                    throw DiscordFailure(.transportFailure, httpStatus: response.statusCode)
                }
                try validateContentType(response.headers)
                try DiscordJSONGuard.validate(response.data)
                rateLimitSink?(accountIdentifier, nil)
                emit(
                    .networkRequest,
                    trace: trace,
                    status: .success,
                    reasonCode: "discord_request_succeeded",
                    metadata: .init([
                        (.endpoint, endpoint.traceName),
                        (.httpStatus, String(response.statusCode)),
                        (.responseBytes, String(response.data.count)),
                        (.retryCount, String(transientRetries + rateLimitRetries)),
                    ])
                )
                return response
            } catch {
                activeRequestIDs.remove(requestID)
                if Task.isCancelled || error is CancellationError ||
                    (error as? DiscordFailure)?.code == .cancelled
                {
                    throw DiscordFailure(.cancelled)
                }
                if error is URLError {
                    guard transientRetries < 1 else {
                        throw DiscordFailure(.transientFailureExhausted)
                    }
                    transientRetries += 1
                    try await wait(seconds: 0.25)
                    continue
                }
                let failure = (error as? DiscordFailure) ?? DiscordFailure(.transportFailure)
                emit(
                    .networkRequest,
                    trace: trace,
                    status: .failed,
                    reasonCode: failure.reasonCode,
                    metadata: .init([
                        (.endpoint, endpoint.traceName),
                        (.httpStatus, failure.httpStatus.map(String.init) ?? "none"),
                    ])
                )
                throw failure
            }
        }
    }

    private func wait(seconds: TimeInterval) async throws {
        guard seconds >= 0,
              seconds.isFinite,
              seconds <= DiscordLimits.maximumRetryAfterSeconds
        else { throw DiscordFailure(.invalidRetryAfter) }
        let waitID = UUID()
        let task = Task { try await sleeper.sleep(seconds: seconds) }
        waitTasks[waitID] = task
        defer { waitTasks.removeValue(forKey: waitID) }
        do {
            try await task.value
        } catch {
            throw DiscordFailure(.cancelled)
        }
    }

    private func checkCancellation(epoch: UInt64) throws {
        guard !Task.isCancelled, epoch == cancellationEpoch else {
            throw DiscordFailure(.cancelled)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DiscordFailure(.invalidSchema)
        }
    }

    private func validateFinalURL(_ url: URL?) throws {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DiscordLimits.apiScheme,
              components.host?.lowercased() == DiscordLimits.apiHost,
              components.path.hasPrefix("\(DiscordLimits.apiVersionPath)/")
        else { throw DiscordFailure(.invalidEndpoint) }
    }

    private func validateContentType(_ headers: [String: String]) throws {
        guard let value = header("Content-Type", headers: headers),
              value.lowercased().split(separator: ";", maxSplits: 1).first == "application/json"
        else {
            throw DiscordFailure(.invalidContentType)
        }
    }

    private func retryAfter(
        _ response: DiscordHTTPResponse
    ) throws -> (seconds: TimeInterval, global: Bool) {
        let body = try? JSONDecoder().decode(DiscordErrorDTO.self, from: response.data)
        let headerValue = header("Retry-After", headers: response.headers)
            .flatMap(TimeInterval.init)
        guard let seconds = headerValue ?? body?.retryAfter,
              seconds >= 0,
              seconds.isFinite,
              seconds <= DiscordLimits.maximumRetryAfterSeconds
        else { throw DiscordFailure(.invalidRetryAfter, httpStatus: 429) }
        return (seconds, body?.global == true ||
            header("X-RateLimit-Global", headers: response.headers)?.lowercased() == "true")
    }

    private func header(_ name: String, headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func emit(
        _ name: DiscordTraceEventName,
        trace: DiscordTraceContext,
        status: DiscordTraceStatus,
        reasonCode: String,
        metadata: DiscordTraceMetadata
    ) {
        let event = DiscordTraceEvent(
            timestamp: now(),
            event: name,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "discord_rest_client",
            status: status,
            reasonCode: reasonCode,
            metadata: metadata
        )
        eventSink?(event)
        if eventSink == nil { DiscordProductionTraceLogger.emit(event) }
    }
}

actor DiscordConnectorController {
    typealias TraceSink = @Sendable (DiscordTraceEvent) -> Void

    private enum HistoryPlan {
        case historicalBackfill(DiscordPendingHistoryContinuation?)
        case incremental(DiscordSelectionSyncCursor)
        case fullReconciliation(DiscordPendingHistoryContinuation?)

        var coverage: DiscordSelectionHistoryCoverage {
            switch self {
            case .historicalBackfill: .historicalBackfill
            case .incremental: .incremental
            case .fullReconciliation: .fullReconciliation
            }
        }
    }

    private struct HistoryResult {
        let messages: [DiscordImportedMessage]
        let reconciliations: [ConnectorReconciliationResult]
        let finalReceipt: ConnectorPaginationReceipt
        let isComplete: Bool
        let skippedCount: Int
        let coverage: DiscordSelectionHistoryCoverage
        let sourceHighWatermark: String?
        let pendingIncremental: DiscordPendingIncrementalCursor?
        let pendingHistoryContinuation: DiscordPendingHistoryContinuation?
        let observedExistingFilter: DiscordObservedExistingFilter?
        let outputLimitReached: Bool
    }

    private struct OutputLimitBeforeProgress: Error {}

    private struct SyncOutputBudget {
        let limit: DiscordSyncOutputLimit
        private(set) var messageCount = 0
        private(set) var reconciliationCount = 0
        private(set) var estimatedBytes = 0

        var remainingMessages: Int {
            max(0, limit.maximumMessages - messageCount)
        }

        var isEmpty: Bool {
            messageCount == 0 && reconciliationCount == 0 && estimatedBytes == 0
        }

        mutating func reserve(
            messages: [DiscordImportedMessage],
            reconciliations: [ConnectorReconciliationResult]
        ) throws -> Bool {
            let encoder = JSONEncoder()
            let messageBytes = try encoder.encode(messages).count
            let reconciliationBytes = try encoder.encode(reconciliations).count
            let estimate = messageBytes + reconciliationBytes +
                messages.count * 1_024
            guard messages.count <= limit.maximumMessages - messageCount,
                  reconciliations.count <=
                    limit.maximumMessages - reconciliationCount,
                  estimate <= limit.maximumEstimatedBytes - estimatedBytes
            else { return false }
            messageCount += messages.count
            reconciliationCount += reconciliations.count
            estimatedBytes += estimate
            return true
        }
    }

    private let credentialStore: any DiscordCredentialStoring
    private let client: DiscordRESTClient
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?
    private let historyPageSize: Int
    private var snapshots: [String: DiscordConnectionSnapshot] = [:]
    private var discoveredParentTypes: [String: [String: DiscordChannelType]] = [:]

    /// Production construction has no transport parameter. It always creates the
    /// fixed URLSession transport and the dedicated Data Protection Keychain store.
    init(
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        let store = SecurityDiscordCredentialStore(now: now, eventSink: eventSink)
        let transport = DiscordURLSessionTransport()
        self.credentialStore = store
        self.now = now
        self.eventSink = eventSink
        self.historyPageSize = DiscordLimits.historyPageSize
        self.client = DiscordRESTClient(
            credentialStore: store,
            transport: transport,
            sleeper: SystemDiscordSleeper(),
            now: now,
            eventSink: eventSink,
            rateLimitSink: nil
        )
    }

    /// Explicit fixture-only construction. The marker protocol and disposition
    /// check prevent a production URLSession transport from being mistaken for a
    /// deterministic test transport, while the production initializer above
    /// cannot accept an injected transport at all.
    static func makeForTesting(
        credentialStore: any DiscordCredentialStoring,
        transport: any DiscordTestingTransporting,
        sleeper: any DiscordSleeping,
        historyPageSize: Int = DiscordLimits.historyPageSize,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) throws -> DiscordConnectorController {
        guard transport.disposition == .testFixture,
              (1...DiscordLimits.historyPageSize).contains(historyPageSize)
        else { throw DiscordFailure(.invalidAuthority) }
        return DiscordConnectorController(
            credentialStore: credentialStore,
            transport: transport,
            sleeper: sleeper,
            historyPageSize: historyPageSize,
            now: now,
            eventSink: eventSink
        )
    }

    private init(
        credentialStore: any DiscordCredentialStoring,
        transport: any DiscordRESTTransporting,
        sleeper: any DiscordSleeping,
        historyPageSize: Int,
        now: @escaping @Sendable () -> Date,
        eventSink: TraceSink?
    ) {
        self.credentialStore = credentialStore
        self.now = now
        self.eventSink = eventSink
        self.historyPageSize = historyPageSize
        self.client = DiscordRESTClient(
            credentialStore: credentialStore,
            transport: transport,
            sleeper: sleeper,
            now: now,
            eventSink: eventSink,
            rateLimitSink: nil
        )
    }

    func connect(
        credential: DiscordBotCredential,
        authority: DiscordConnectorAuthority,
        trace: DiscordTraceContext = .init()
    ) async throws -> DiscordConnectionSnapshot {
        guard credential.applicationID == authority.applicationID,
              credential.botUserID == authority.botUserID,
              credential.accountIdentifier == authority.accountIdentifier
        else { throw DiscordFailure(.invalidAuthority) }

        let accountIdentifier = authority.accountIdentifier
        snapshots[accountIdentifier] = snapshot(
            authority: authority,
            state: .connecting,
            attemptedAt: now(),
            reasonCode: "discord_connection_validation_started"
        )
        emit(
            .connection,
            trace: trace,
            status: .started,
            reasonCode: "discord_connection_validation_started",
            metadata: authorityMetadata(authority)
        )

        do {
            try await credentialStore.save(credential, trace: trace.child())
            let identity = try await client.currentBot(
                accountIdentifier: accountIdentifier,
                trace: trace.child()
            )
            guard identity.id == authority.botUserID, identity.bot == true else {
                throw DiscordFailure(.invalidToken)
            }
            let limited = authority.messageContentAccess == .limitedByPrivilegedIntent
            let state: DiscordConnectionState = limited ? .degraded : .connected
            let reason = limited
                ? DiscordFailureCode.messageContentIntentMissing.rawValue
                : "discord_connection_validated"
            let value = snapshot(
                authority: authority,
                state: state,
                attemptedAt: now(),
                reasonCode: reason
            )
            snapshots[accountIdentifier] = value
            emit(
                .connection,
                trace: trace,
                status: limited ? .degraded : .success,
                reasonCode: reason,
                metadata: authorityMetadata(authority)
            )
            return value
        } catch {
            try? await credentialStore.delete(
                accountIdentifier: accountIdentifier,
                trace: trace.child()
            )
            let failure = mapFailure(error)
            snapshots[accountIdentifier] = snapshot(
                authority: authority,
                state: .failed,
                attemptedAt: now(),
                reasonCode: failure.reasonCode
            )
            emit(
                .connection,
                trace: trace,
                status: failure.code == .cancelled ? .skipped : .failed,
                reasonCode: failure.reasonCode,
                metadata: authorityMetadata(authority)
            )
            throw failure
        }
    }

    func connectionSnapshot(accountIdentifier: String) -> DiscordConnectionSnapshot? {
        snapshots[accountIdentifier]
    }

    /// Restores a connection after process launch by reading only the exact
    /// pseudonymous Keychain account and revalidating the stored bot token.
    /// No token is accepted from UI state or persisted outside Keychain.
    func resume(
        authority: DiscordConnectorAuthority,
        trace: DiscordTraceContext = .init()
    ) async throws -> DiscordConnectionSnapshot {
        let accountIdentifier = authority.accountIdentifier
        snapshots[accountIdentifier] = snapshot(
            authority: authority,
            state: .connecting,
            attemptedAt: now(),
            reasonCode: "discord_connection_resume_started"
        )
        emit(
            .connection,
            trace: trace,
            status: .started,
            reasonCode: "discord_connection_resume_started",
            metadata: authorityMetadata(authority)
        )

        do {
            let identity = try await client.currentBot(
                accountIdentifier: accountIdentifier,
                trace: trace.child()
            )
            guard identity.id == authority.botUserID, identity.bot == true else {
                throw DiscordFailure(.invalidToken)
            }
            let limited = authority.messageContentAccess == .limitedByPrivilegedIntent
            let reason = limited
                ? DiscordFailureCode.messageContentIntentMissing.rawValue
                : "discord_connection_resumed"
            let value = snapshot(
                authority: authority,
                state: limited ? .degraded : .connected,
                attemptedAt: now(),
                reasonCode: reason
            )
            snapshots[accountIdentifier] = value
            emit(
                .connection,
                trace: trace,
                status: limited ? .degraded : .success,
                reasonCode: reason,
                metadata: authorityMetadata(authority)
            )
            return value
        } catch {
            let failure = mapFailure(error)
            snapshots[accountIdentifier] = snapshot(
                authority: authority,
                state: failure.code == .credentialNotFound ? .disconnected : .failed,
                attemptedAt: now(),
                reasonCode: failure.reasonCode
            )
            emit(
                .connection,
                trace: trace,
                status: failure.code == .credentialNotFound ? .skipped : .failed,
                reasonCode: failure.reasonCode,
                metadata: authorityMetadata(authority)
            )
            throw failure
        }
    }

    func discoverSources(
        authority: DiscordConnectorAuthority,
        includeArchivedThreads: Bool = true,
        trace: DiscordTraceContext = .init()
    ) async throws -> DiscordDiscoveryResult {
        try requireConnected(authority)
        let accountIdentifier = authority.accountIdentifier
        var guildsByID: [String: DiscordGuild] = [:]
        var guildAfter: String?
        var guildPages = 0
        var skippedGuilds = 0

        emit(
            .guildDiscovery,
            trace: trace,
            status: .started,
            reasonCode: "discord_guild_discovery_started",
            metadata: authorityMetadata(authority)
        )
        repeat {
            guard guildPages < DiscordLimits.maximumGuildPages else {
                throw DiscordFailure(.syncIncomplete)
            }
            let raw = try await client.guilds(
                accountIdentifier: accountIdentifier,
                after: guildAfter,
                trace: trace.child()
            )
            guard raw.count <= DiscordLimits.guildPageSize else {
                throw DiscordFailure(.invalidSchema)
            }
            for guild in raw {
                guard DiscordValidation.isSnowflake(guild.id) else {
                    throw DiscordFailure(.invalidSchema)
                }
                if authority.guildAllowlist.contains(guild.id) {
                    guildsByID[guild.id] = .init(
                        id: guild.id,
                        displayName: DiscordPrivacy.boundedName(
                            guild.name,
                            fallback: "Discord server"
                        )
                    )
                } else {
                    skippedGuilds += 1
                }
            }
            guildPages += 1
            let next = raw.count == DiscordLimits.guildPageSize ? raw.last?.id : nil
            if let next, next == guildAfter {
                throw DiscordFailure(.paginationDidNotAdvance)
            }
            guildAfter = next
        } while guildAfter != nil

        let absentGuildIDs = authority.guildAllowlist.subtracting(guildsByID.keys)
        var limitations = absentGuildIDs.sorted().map {
            DiscordDiscoveryLimitation(
                scope: .guild,
                sourceIdentifier: $0,
                reasonCode: .missingGuildPermission
            )
        }
        var channelsByID: [String: DiscordChannel] = [:]
        var threadsByID: [String: DiscordChannel] = [:]
        var skippedChannels = 0
        var skippedDMs = 0

        for guild in guildsByID.values.sorted(by: { $0.id < $1.id }) {
            let rawChannels = try await client.channels(
                accountIdentifier: accountIdentifier,
                guildID: guild.id,
                trace: trace.child()
            )
            for raw in rawChannels {
                guard let type = DiscordChannelType(rawValue: raw.type),
                      DiscordValidation.isSnowflake(raw.id),
                      raw.guildID == nil || raw.guildID == guild.id
                else { throw DiscordFailure(.invalidSchema) }
                if type.isDirectMessage {
                    skippedDMs += 1
                    continue
                }
                guard type.isReadableTextSource,
                      !type.isThread
                else {
                    skippedChannels += 1
                    continue
                }
                channelsByID[raw.id] = try channel(from: raw, guildID: guild.id)
            }

            let active = try await client.activeThreads(
                accountIdentifier: accountIdentifier,
                guildID: guild.id,
                trace: trace.child()
            )
            for raw in active.threads {
                if let thread = try admittedThread(
                    raw,
                    guildID: guild.id
                ) {
                    threadsByID[thread.id] = thread
                } else {
                    skippedChannels += 1
                }
            }

            if includeArchivedThreads {
                for parent in channelsByID.values
                    .filter({ $0.guildID == guild.id })
                    .sorted(by: { $0.id < $1.id })
                {
                    do {
                        if parent.type.supportsPublicArchivedThreads {
                            let archived = try await archivedThreads(
                                accountIdentifier: accountIdentifier,
                                parent: parent,
                                privateJoinedOnly: false,
                                trace: trace.child()
                            )
                            for thread in archived { threadsByID[thread.id] = thread }
                        }
                        if parent.type.supportsPrivateThreads {
                            let archived = try await archivedThreads(
                                accountIdentifier: accountIdentifier,
                                parent: parent,
                                privateJoinedOnly: true,
                                trace: trace.child()
                            )
                            for thread in archived { threadsByID[thread.id] = thread }
                        }
                    } catch let failure as DiscordFailure where
                        failure.code == .missingChannelPermission ||
                        failure.code == .resourceUnavailable
                    {
                        channelsByID.removeValue(forKey: parent.id)
                        threadsByID = threadsByID.filter {
                            $0.value.parentChannelID != parent.id
                        }
                        skippedChannels += 1
                        limitations.append(.init(
                            scope: .channel,
                            sourceIdentifier: parent.id,
                            reasonCode: failure.code
                        ))
                        emit(
                            .threadDiscovery,
                            trace: trace,
                            status: .degraded,
                            reasonCode: failure.reasonCode,
                            metadata: .init([
                                (.guildHash, DiscordPrivacy.shortHash(parent.guildID)),
                                (.channelHash, DiscordPrivacy.shortHash(parent.id)),
                            ])
                        )
                    }
                }
            }
        }

        let result = DiscordDiscoveryResult(
            guilds: guildsByID.values.sorted(by: { $0.id < $1.id }),
            channels: channelsByID.values.sorted(by: { $0.id < $1.id }),
            threads: threadsByID.values.sorted(by: { $0.id < $1.id }),
            skippedGuildCount: skippedGuilds + absentGuildIDs.count,
            skippedChannelCount: skippedChannels,
            skippedDirectMessageCount: skippedDMs,
            messageContentAccess: authority.messageContentAccess,
            limitations: limitations.sorted {
                if $0.scope.rawValue != $1.scope.rawValue {
                    return $0.scope.rawValue < $1.scope.rawValue
                }
                if $0.sourceIdentifierHash != $1.sourceIdentifierHash {
                    return $0.sourceIdentifierHash < $1.sourceIdentifierHash
                }
                return $0.reasonCode.rawValue < $1.reasonCode.rawValue
            }
        )
        discoveredParentTypes[accountIdentifier] = Dictionary(
            uniqueKeysWithValues: result.channels.map { ($0.id, $0.type) }
        )
        emit(
            .channelDiscovery,
            trace: trace,
            status: result.isComplete && authority.messageContentAccess == .enabled
                ? .success : .degraded,
            reasonCode: result.reasonCode,
            metadata: .init([
                (.pageCount, String(guildPages)),
                (.importedCount, String(result.channels.count + result.threads.count)),
                (.skippedCount, String(
                    result.skippedGuildCount + skippedChannels + skippedDMs
                )),
                (.contentMode, authority.messageContentAccess.rawValue),
                (.accountHash, DiscordPrivacy.shortHash(accountIdentifier)),
            ])
        )
        return result
    }

    func sync(
        authority: DiscordConnectorAuthority,
        selections: [DiscordSourceSelection],
        existingEnvelopes: [ConnectorRecordEnvelope] = [],
        reconciliationState: DiscordReconciliationState = .init(),
        checkpointIdentifier: String,
        maximumPagesPerSelection: Int = DiscordLimits.maximumHistoryPages,
        mode: DiscordSyncMode = .automatic,
        outputLimit: DiscordSyncOutputLimit = .production,
        trace: DiscordTraceContext = .init()
    ) async throws -> DiscordSyncResult {
        try requireConnected(authority)
        guard !selections.isEmpty,
              selections.count <= DiscordLimits.maximumSelections,
              Set(selections).count == selections.count,
              selections.allSatisfy(authority.admits),
              ConnectorEnvelopeValidation.validIdentifier(
                  checkpointIdentifier,
                  maximumBytes: ConnectorEnvelopeLimits.maximumCheckpointBytes
              ),
              existingEnvelopes.allSatisfy({
                  $0.provider == "discord" &&
                      $0.pseudonymousAccountIdentifier == authority.accountIdentifier &&
                      $0.provenance.sourceSystem == "discord-api-v10"
              }),
              existingEnvelopes.count <= DiscordLimits.maximumExistingEnvelopes,
              ConnectorEnvelopeMaterializationBudget.admits(
                  existingEnvelopes,
                  maximumBytes: DiscordLimits.maximumExistingEnvelopeBytes
              ),
              maximumPagesPerSelection > 0,
              maximumPagesPerSelection <= DiscordLimits.maximumHistoryPages,
              outputLimit.maximumMessages >= historyPageSize
        else { throw DiscordFailure(.invalidAuthority) }
        try await validateSelectionParentTypes(
            authority: authority,
            selections: selections,
            trace: trace.child()
        )

        let startedAt = now()
        let accountIdentifier = authority.accountIdentifier
        snapshots[accountIdentifier] = snapshot(
            authority: authority,
            state: .syncing,
            attemptedAt: startedAt,
            reasonCode: "discord_sync_started"
        )
        emit(
            .historyPage,
            trace: trace,
            status: .started,
            reasonCode: "discord_sync_started",
            metadata: .init([
                (.accountHash, DiscordPrivacy.shortHash(accountIdentifier)),
                (.pageCount, "0"),
                (.syncMode, mode.rawValue),
                (.outputMessageLimit, String(outputLimit.maximumMessages)),
                (.outputByteLimit, String(outputLimit.maximumEstimatedBytes)),
            ])
        )

        var existingByKey: [String: ConnectorRecordEnvelope] = [:]
        for envelope in existingEnvelopes {
            if let current = existingByKey[envelope.deduplicationKey] {
                existingByKey[envelope.deduplicationKey] = try ConnectorRecordReconciler
                    .reconcile(existing: current, incoming: [envelope])?
                    .selectedEnvelope ?? current
            } else {
                existingByKey[envelope.deduplicationKey] = envelope
            }
        }
        var allMessages: [DiscordImportedMessage] = []
        var allReconciliations: [ConnectorReconciliationResult] = []
        var state = reconciliationState
        let selectedIDs = Set(selections.map(\.id))
        state.selectionCursors = state.selectionCursors.filter {
            selectedIDs.contains($0.key)
        }
        let retainedKeys = Set(existingEnvelopes.map(\.deduplicationKey))
        state.missingCompleteObservations = state.missingCompleteObservations.filter {
            retainedKeys.contains($0.key)
        }
        if !selectedIDs.contains(state.nextSelectionIdentifier ?? "") {
            state.nextSelectionIdentifier = nil
        }
        var completeSelections = 0
        var skippedCount = 0
        var outputBudget = SyncOutputBudget(limit: outputLimit)
        var outputLimitReached = false

        do {
            let orderedSelections = rotatedSelections(
                selections.sorted(by: { $0.id < $1.id }),
                startingAt: state.nextSelectionIdentifier
            )
            state.nextSelectionIdentifier = nil
            for (selectionIndex, selection) in orderedSelections.enumerated() {
                guard outputBudget.remainingMessages >= historyPageSize else {
                    outputLimitReached = true
                    state.nextSelectionIdentifier = selection.id
                    break
                }
                let existingForSelection = existingEnvelopes.filter {
                    $0.deletionState == .available &&
                        $0.provenance.sourceContainerIdentifier ==
                            selection.sourceContainerIdentifier
                }
                let previousCursor = state.selectionCursors[selection.id]
                let plan = historyPlan(
                    requestedMode: mode,
                    previousCursor: previousCursor,
                    hasRetainedRecords: !existingForSelection.isEmpty
                )
                let history: HistoryResult
                do {
                    history = try await self.history(
                        authority: authority,
                        selection: selection,
                        existingByKey: existingByKey,
                        existingSelectionKeys: Set(
                            existingForSelection.map(\.deduplicationKey)
                        ),
                        checkpointIdentifier: checkpointIdentifier,
                        maximumPages: maximumPagesPerSelection,
                        plan: plan,
                        outputBudget: &outputBudget,
                        trace: trace.child()
                    )
                } catch is OutputLimitBeforeProgress {
                    outputLimitReached = true
                    state.nextSelectionIdentifier = selection.id
                    break
                }
                allMessages.append(contentsOf: history.messages)
                allReconciliations.append(contentsOf: history.reconciliations)
                skippedCount += history.skippedCount
                state.selectionCursors[selection.id] = try updatedCursor(
                    previous: previousCursor,
                    history: history
                )
                if history.outputLimitReached {
                    outputLimitReached = true
                    state.nextSelectionIdentifier = orderedSelections[
                        (selectionIndex + 1) % orderedSelections.count
                    ].id
                    break
                }
                guard history.isComplete else { continue }
                completeSelections += 1
                guard history.coverage.permitsAbsenceReconciliation else {
                    continue
                }
                let currentKeys = Set(history.messages.map(\.envelope.deduplicationKey))
                let observed: (String) -> Bool = { key in
                    currentKeys.contains(key) ||
                        history.observedExistingFilter?.mightContain(key) == true
                }
                for existing in existingForSelection where observed(existing.deduplicationKey) {
                    state.missingCompleteObservations.removeValue(
                        forKey: existing.deduplicationKey
                    )
                }

                let missing = existingForSelection.filter {
                    !observed($0.deduplicationKey)
                }
                var reconciliationOutputExhausted = false
                for existing in missing {
                    let count = min(
                        2,
                        (state.missingCompleteObservations[existing.deduplicationKey] ?? 0) + 1
                    )
                    state.missingCompleteObservations[existing.deduplicationKey] = count
                    guard count >= 2 else {
                        emit(
                            .reconciliation,
                            trace: trace,
                            status: .degraded,
                            reasonCode: DiscordFailureCode.reconciliationUnconfirmed.rawValue,
                            metadata: selectionMetadata(selection)
                        )
                        continue
                    }
                    let tombstone = try makeTombstone(
                        existing: existing,
                        receipt: history.finalReceipt,
                        checkpointIdentifier: checkpointIdentifier
                    )
                    if let reconciled = try ConnectorRecordReconciler.reconcile(
                        existing: existing,
                        incoming: [tombstone]
                    ) {
                        guard try outputBudget.reserve(
                            messages: [],
                            reconciliations: [reconciled]
                        ) else {
                            outputLimitReached = true
                            reconciliationOutputExhausted = true
                            state.nextSelectionIdentifier = orderedSelections[
                                (selectionIndex + 1) % orderedSelections.count
                            ].id
                            state.selectionCursors[selection.id] = try .init(
                                highWatermarkMessageID: maximumSnowflake(
                                    previousCursor?.highWatermarkMessageID,
                                    history.sourceHighWatermark
                                ),
                                incrementalPollsSinceFullReconciliation:
                                    DiscordLimits.incrementalPollsBeforeFullReconciliation,
                                lastCompletedCoverage: history.coverage
                            )
                            break
                        }
                        allReconciliations.append(reconciled)
                        state.missingCompleteObservations.removeValue(
                            forKey: existing.deduplicationKey
                        )
                    }
                }
                if reconciliationOutputExhausted { break }
            }

            let complete = completeSelections == selections.count && !outputLimitReached
            let tombstones = allReconciliations.filter { $0.disposition == .tombstoned }.count
            let updated = allReconciliations.filter { $0.disposition == .updated }.count
            let unchanged = allReconciliations.filter { $0.disposition == .unchanged }.count
            let attachments = allMessages.reduce(0) { $0 + $1.attachments.count }
            let limited = authority.messageContentAccess == .limitedByPrivilegedIntent
            let reason: String
            if outputLimitReached {
                reason = DiscordFailureCode.syncOutputLimitReached.rawValue
            } else if !complete {
                reason = DiscordFailureCode.syncIncomplete.rawValue
            } else if limited {
                reason = DiscordFailureCode.limitedMessageContent.rawValue
            } else {
                reason = "discord_sync_succeeded"
            }
            let receipt = DiscordSyncReceipt(
                traceID: trace.traceID,
                checkpointIdentifier: checkpointIdentifier,
                startedAt: startedAt,
                completedAt: now(),
                selectionCount: selections.count,
                completeSelectionCount: completeSelections,
                importedCount: allMessages.count,
                updatedCount: updated,
                unchangedCount: unchanged,
                tombstoneCount: tombstones,
                skippedCount: skippedCount,
                attachmentCount: attachments,
                estimatedOutputBytes: outputBudget.estimatedBytes,
                outputLimitReached: outputLimitReached,
                isComplete: complete,
                reasonCode: reason
            )
            let previousSnapshot = snapshots[accountIdentifier]
            snapshots[accountIdentifier] = DiscordConnectionSnapshot(
                accountIdentifier: accountIdentifier,
                credentialReference: credentialReference(accountIdentifier),
                state: complete && !limited ? .connected : .degraded,
                messageContentAccess: authority.messageContentAccess,
                lastAttemptedAt: startedAt,
                lastSuccessfulSyncAt: complete
                    ? receipt.completedAt
                    : previousSnapshot?.lastSuccessfulSyncAt,
                importedItemCount: allMessages.count,
                skippedItemCount: skippedCount,
                attachmentCount: attachments,
                latestReasonCode: reason,
                rateLimitState: nil
            )
            emit(
                .reconciliation,
                trace: trace,
                status: complete && !limited ? .success : .degraded,
                reasonCode: reason,
                metadata: .init([
                    (.importedCount, String(allMessages.count)),
                    (.skippedCount, String(skippedCount)),
                    (.tombstoneCount, String(tombstones)),
                    (.attachmentCount, String(attachments)),
                    (.contentMode, authority.messageContentAccess.rawValue),
                    (.accountHash, DiscordPrivacy.shortHash(accountIdentifier)),
                    (.syncMode, mode.rawValue),
                    (.outputBytes, String(outputBudget.estimatedBytes)),
                    (.outputMessageLimit, String(outputLimit.maximumMessages)),
                    (.outputByteLimit, String(outputLimit.maximumEstimatedBytes)),
                ])
            )
            return DiscordSyncResult(
                messages: allMessages.sorted { $0.messageID < $1.messageID },
                reconciliations: allReconciliations.sorted {
                    $0.selectedEnvelope.deduplicationKey < $1.selectedEnvelope.deduplicationKey
                },
                reconciliationState: state,
                receipt: receipt
            )
        } catch {
            let failure = mapFailure(error)
            let previous = snapshots[accountIdentifier]
            snapshots[accountIdentifier] = DiscordConnectionSnapshot(
                accountIdentifier: accountIdentifier,
                credentialReference: credentialReference(accountIdentifier),
                state: failure.code == .cancelled ? .degraded : .failed,
                messageContentAccess: authority.messageContentAccess,
                lastAttemptedAt: startedAt,
                lastSuccessfulSyncAt: previous?.lastSuccessfulSyncAt,
                importedItemCount: previous?.importedItemCount ?? 0,
                skippedItemCount: previous?.skippedItemCount ?? 0,
                attachmentCount: previous?.attachmentCount ?? 0,
                latestReasonCode: failure.reasonCode,
                rateLimitState: failure.retryAfterSeconds.map {
                    DiscordRateLimitState(
                        retryAfterSeconds: $0,
                        retryAt: now().addingTimeInterval($0),
                        isGlobal: false,
                        observedAt: now()
                    )
                }
            )
            emit(
                failure.code == .cancelled ? .cancellation : .reconciliation,
                trace: trace,
                status: failure.code == .cancelled ? .skipped : .failed,
                reasonCode: failure.reasonCode,
                metadata: authorityMetadata(authority)
            )
            throw failure
        }
    }

    func cancel(trace: DiscordTraceContext = .init()) async {
        await client.cancelAll(trace: trace)
    }

    func disconnect(
        authority: DiscordConnectorAuthority,
        trace: DiscordTraceContext = .init()
    ) async -> DiscordDisconnectResult {
        let accountIdentifier = authority.accountIdentifier
        await client.cancelAll(trace: trace.child())
        var deleted = false
        var reason = "discord_disconnect_succeeded"
        do {
            try await credentialStore.delete(
                accountIdentifier: accountIdentifier,
                trace: trace.child()
            )
            deleted = true
        } catch let failure as DiscordCredentialStoreFailure where failure.code == .notFound {
            deleted = true
            reason = "discord_disconnect_credential_already_absent"
        } catch let failure as DiscordCredentialStoreFailure {
            reason = failure.reasonCode
        } catch {
            reason = DiscordFailureCode.credentialDeleteFailed.rawValue
        }

        snapshots[accountIdentifier] = snapshot(
            authority: authority,
            state: deleted ? .disconnected : .failed,
            attemptedAt: now(),
            reasonCode: reason
        )
        discoveredParentTypes.removeValue(forKey: accountIdentifier)
        emit(
            .disconnect,
            trace: trace,
            status: deleted ? .success : .failed,
            reasonCode: reason,
            metadata: authorityMetadata(authority)
        )
        return .init(
            accountIdentifier: accountIdentifier,
            credentialDeleted: deleted,
            localDataDeleted: false,
            localDataDisposition: .preserved,
            remoteMutationAttempted: false,
            reasonCode: reason
        )
    }

    private func rotatedSelections(
        _ selections: [DiscordSourceSelection],
        startingAt identifier: String?
    ) -> [DiscordSourceSelection] {
        guard let identifier,
              let index = selections.firstIndex(where: { $0.id == identifier }),
              index > 0
        else { return selections }
        return Array(selections[index...]) + Array(selections[..<index])
    }

    private func validateSelectionParentTypes(
        authority: DiscordConnectorAuthority,
        selections: [DiscordSourceSelection],
        trace: DiscordTraceContext
    ) async throws {
        let accountIdentifier = authority.accountIdentifier
        var known = discoveredParentTypes[accountIdentifier] ?? [:]
        let unresolvedGuilds = Set(selections.compactMap { selection -> String? in
            guard known[selection.channelID] == nil,
                  selection.parentChannelType == nil
            else { return nil }
            return selection.guildID
        })
        for guildID in unresolvedGuilds.sorted() {
            let rawChannels = try await client.channels(
                accountIdentifier: accountIdentifier,
                guildID: guildID,
                trace: trace.child()
            )
            for raw in rawChannels {
                guard DiscordValidation.isSnowflake(raw.id),
                      raw.guildID == nil || raw.guildID == guildID,
                      let type = DiscordChannelType(rawValue: raw.type),
                      !type.isDirectMessage
                else { throw DiscordFailure(.invalidSchema) }
                known[raw.id] = type
            }
        }
        for selection in selections {
            let discovered = known[selection.channelID]
            if let declared = selection.parentChannelType,
               let discovered,
               declared != discovered {
                throw DiscordFailure(.invalidSchema)
            }
            guard let type = discovered ?? selection.parentChannelType else {
                throw DiscordFailure(.missingChannelPermission)
            }
            if selection.threadID == nil, type.isThreadContainerOnly {
                throw DiscordFailure(.containerOnlyChannelRejected)
            }
            let permitted = selection.threadID == nil
                ? type.supportsDirectHistory && !type.isThread
                : type.supportsPublicArchivedThreads || type.supportsPrivateThreads
            guard permitted else { throw DiscordFailure(.invalidAuthority) }
        }
        discoveredParentTypes[accountIdentifier] = known
    }

    private func historyPlan(
        requestedMode: DiscordSyncMode,
        previousCursor: DiscordSelectionSyncCursor?,
        hasRetainedRecords: Bool
    ) -> HistoryPlan {
        if let pending = previousCursor?.pendingHistoryContinuation {
            return pending.coverage == .historicalBackfill
                ? .historicalBackfill(pending)
                : .fullReconciliation(pending)
        }
        if requestedMode == .fullReconciliation {
            return .fullReconciliation(nil)
        }
        guard let previousCursor,
              previousCursor.highWatermarkMessageID != nil,
              hasRetainedRecords
        else { return .historicalBackfill(nil) }
        if previousCursor.pendingIncremental != nil {
            return .incremental(previousCursor)
        }
        if requestedMode == .incremental {
            return .incremental(previousCursor)
        }
        if previousCursor.incrementalPollsSinceFullReconciliation >=
            DiscordLimits.incrementalPollsBeforeFullReconciliation {
            return .fullReconciliation(nil)
        }
        return .incremental(previousCursor)
    }

    private func updatedCursor(
        previous: DiscordSelectionSyncCursor?,
        history: HistoryResult
    ) throws -> DiscordSelectionSyncCursor? {
        guard history.isComplete else {
            if history.coverage == .incremental,
               let previous,
               let pending = history.pendingIncremental {
                return try .init(
                    highWatermarkMessageID: previous.highWatermarkMessageID,
                    incrementalPollsSinceFullReconciliation:
                        previous.incrementalPollsSinceFullReconciliation,
                    lastCompletedCoverage: previous.lastCompletedCoverage,
                    pendingIncremental: pending
                )
            }
            if let pending = history.pendingHistoryContinuation {
                return try .init(
                    highWatermarkMessageID: previous?.highWatermarkMessageID,
                    incrementalPollsSinceFullReconciliation:
                        previous?.incrementalPollsSinceFullReconciliation ?? 0,
                    lastCompletedCoverage: previous?.lastCompletedCoverage,
                    pendingHistoryContinuation: pending
                )
            }
            return previous
        }

        let highWatermark = maximumSnowflake(
            previous?.highWatermarkMessageID,
            history.sourceHighWatermark
        )
        switch history.coverage {
        case .historicalBackfill, .fullReconciliation:
            return try .init(
                highWatermarkMessageID: highWatermark,
                incrementalPollsSinceFullReconciliation: 0,
                lastCompletedCoverage: history.coverage
            )
        case .incremental:
            guard let previous else { throw DiscordFailure(.invalidSchema) }
            return try .init(
                highWatermarkMessageID: highWatermark,
                incrementalPollsSinceFullReconciliation: min(
                    DiscordLimits.incrementalPollsBeforeFullReconciliation,
                    previous.incrementalPollsSinceFullReconciliation + 1
                ),
                lastCompletedCoverage: .incremental
            )
        }
    }

    private func maximumSnowflake(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs.flatMap(UInt64.init), rhs.flatMap(UInt64.init)) {
        case let (left?, right?): left >= right ? lhs : rhs
        case (_?, nil): lhs
        case (nil, _?): rhs
        case (nil, nil): nil
        }
    }

    private func history(
        authority: DiscordConnectorAuthority,
        selection: DiscordSourceSelection,
        existingByKey: [String: ConnectorRecordEnvelope],
        existingSelectionKeys: Set<String>,
        checkpointIdentifier: String,
        maximumPages: Int,
        plan: HistoryPlan,
        outputBudget: inout SyncOutputBudget,
        trace: DiscordTraceContext
    ) async throws -> HistoryResult {
        let streamIdentifier = "discord-history-\(selection.id)"
        let coverage = plan.coverage
        let priorHighWatermark: String?
        var before: String?
        var pageOrdinal: Int
        var previousReceipt: ConnectorPaginationReceipt?
        var finalReceipt: ConnectorPaginationReceipt?
        var highWatermark: String?
        var observedExistingFilter: DiscordObservedExistingFilter?
        switch plan {
        case let .historicalBackfill(continuation),
             let .fullReconciliation(continuation):
            priorHighWatermark = nil
            if let continuation {
                let receipt = continuation.lastPaginationReceipt
                guard continuation.coverage == coverage,
                      receipt.checkpointIdentifier == checkpointIdentifier,
                      receipt.streamIdentifier == streamIdentifier,
                      let next = receipt.nextCursor
                else { throw DiscordFailure(.invalidSchema) }
                before = next
                pageOrdinal = receipt.pageOrdinal + 1
                previousReceipt = receipt
                finalReceipt = receipt
                highWatermark = continuation.targetHighWatermarkMessageID
                observedExistingFilter = continuation.observedExistingFilter
            } else {
                before = nil
                pageOrdinal = 0
                previousReceipt = nil
                finalReceipt = nil
                highWatermark = nil
                observedExistingFilter = try DiscordObservedExistingFilter(
                    expectedItemCount: existingSelectionKeys.count +
                        DiscordLimits.maximumSyncOutputMessages
                )
            }
        case let .incremental(cursor):
            guard let persistedHighWatermark = cursor.highWatermarkMessageID else {
                throw DiscordFailure(.invalidSchema)
            }
            priorHighWatermark = persistedHighWatermark
            if let pending = cursor.pendingIncremental {
                let receipt = pending.lastPaginationReceipt
                guard receipt.checkpointIdentifier == checkpointIdentifier,
                      receipt.streamIdentifier == streamIdentifier,
                      receipt.sourceHighWatermark ==
                        pending.targetHighWatermarkMessageID,
                      let next = receipt.nextCursor
                else { throw DiscordFailure(.invalidSchema) }
                before = next
                pageOrdinal = receipt.pageOrdinal + 1
                previousReceipt = receipt
                finalReceipt = receipt
                highWatermark = pending.targetHighWatermarkMessageID
            } else {
                before = nil
                pageOrdinal = 0
                previousReceipt = nil
                finalReceipt = nil
                highWatermark = nil
            }
            observedExistingFilter = nil
        }
        var seenPageSignatures: Set<String> = []
        var seenMessageHashes: [String: String] = [:]
        var messages: [DiscordImportedMessage] = []
        var reconciliations: [ConnectorReconciliationResult] = []
        var skipped = 0
        var complete = false
        var outputLimitReached = false
        var pagesFetched = 0

        while pagesFetched < maximumPages {
            guard outputBudget.remainingMessages >= historyPageSize else {
                guard finalReceipt != nil else { throw OutputLimitBeforeProgress() }
                outputLimitReached = true
                break
            }
            let raw = try await client.messages(
                accountIdentifier: authority.accountIdentifier,
                channelID: selection.historyChannelID,
                before: before,
                limit: historyPageSize,
                trace: trace.child()
            )
            guard raw.count <= historyPageSize else { throw DiscordFailure(.invalidSchema) }
            let ids = raw.map(\.id)
            let signature = DiscordPrivacy.digest(ids.joined(separator: ":"))
            guard seenPageSignatures.insert(signature).inserted else {
                throw DiscordFailure(.duplicatePageReplay)
            }
            try validateMessageOrder(raw, before: before)
            if highWatermark == nil {
                highWatermark = maximumSnowflake(priorHighWatermark, ids.first)
            }

            let eligibleRaw: [DiscordMessageDTO]
            let reachedIncrementalBoundary: Bool
            if let priorHighWatermark,
               let priorValue = UInt64(priorHighWatermark) {
                eligibleRaw = try raw.filter {
                    guard let value = UInt64($0.id) else {
                        throw DiscordFailure(.invalidSchema)
                    }
                    return value > priorValue
                }
                reachedIncrementalBoundary = eligibleRaw.count != raw.count
            } else {
                eligibleRaw = raw
                reachedIncrementalBoundary = false
            }
            let nextCursor = !reachedIncrementalBoundary && raw.count == historyPageSize
                ? raw.last?.id : nil
            if let nextCursor, nextCursor == before {
                throw DiscordFailure(.paginationDidNotAdvance)
            }
            let receipt = try ConnectorPaginationReceipt(
                checkpointIdentifier: checkpointIdentifier,
                streamIdentifier: streamIdentifier,
                pageOrdinal: pageOrdinal,
                requestCursor: before,
                nextCursor: nextCursor,
                sourceHighWatermark: highWatermark,
                isComplete: nextCursor == nil
            )
            try receipt.validate(after: previousReceipt)

            var normalizedPage: [DiscordImportedMessage] = []
            for rawMessage in eligibleRaw {
                let normalized = try normalize(
                    rawMessage,
                    authority: authority,
                    selection: selection,
                    receipt: receipt,
                    trace: trace.child()
                )
                if let priorHash = seenMessageHashes[normalized.messageID] {
                    guard priorHash == normalized.envelope.sourceHash else {
                        throw DiscordFailure(.invalidSchema)
                    }
                    skipped += 1
                    continue
                }
                seenMessageHashes[normalized.messageID] = normalized.envelope.sourceHash
                normalizedPage.append(normalized)
            }

            if !normalizedPage.isEmpty {
                _ = try ConnectorRecordReconciler.reconcilePage(
                    normalizedPage.map(\.envelope),
                    after: previousReceipt
                )
            }
            var pageMessages: [DiscordImportedMessage] = []
            var pageReconciliations: [ConnectorReconciliationResult] = []
            for message in normalizedPage {
                let existing = existingByKey[message.envelope.deduplicationKey]
                guard let reconciled = try ConnectorRecordReconciler.reconcile(
                    existing: existing,
                    incoming: [message.envelope]
                ) else { continue }
                pageMessages.append(message.replacingEnvelope(reconciled.selectedEnvelope))
                pageReconciliations.append(reconciled)
            }
            guard try outputBudget.reserve(
                messages: pageMessages,
                reconciliations: pageReconciliations
            ) else {
                if outputBudget.isEmpty {
                    throw DiscordFailure(.syncOutputLimitReached)
                }
                guard finalReceipt != nil else { throw OutputLimitBeforeProgress() }
                outputLimitReached = true
                break
            }
            messages.append(contentsOf: pageMessages)
            reconciliations.append(contentsOf: pageReconciliations)
            if observedExistingFilter != nil {
                for message in pageMessages {
                    observedExistingFilter?.insert(message.envelope.deduplicationKey)
                }
            }
            emit(
                .historyPage,
                trace: trace,
                status: .success,
                reasonCode: "discord_history_page_succeeded",
                metadata: .init([
                    (.pageOrdinal, String(pageOrdinal)),
                    (.importedCount, String(pageMessages.count)),
                    (.skippedCount, String(skipped)),
                    (.channelHash, DiscordPrivacy.shortHash(selection.historyChannelID)),
                    (.threadHash, selection.threadID.map(DiscordPrivacy.shortHash) ?? "none"),
                    (.syncMode, coverage.rawValue),
                ])
            )
            pageOrdinal += 1
            pagesFetched += 1
            previousReceipt = receipt
            finalReceipt = receipt
            before = nextCursor
            if nextCursor == nil {
                complete = true
                break
            }
        }

        guard let finalReceipt else {
            throw DiscordFailure(.invalidSchema)
        }
        let pendingIncremental: DiscordPendingIncrementalCursor?
        if !complete,
           coverage == .incremental,
           let highWatermark {
            pendingIncremental = try .init(
                targetHighWatermarkMessageID: highWatermark,
                lastPaginationReceipt: finalReceipt
            )
        } else {
            pendingIncremental = nil
        }
        let pendingHistoryContinuation: DiscordPendingHistoryContinuation?
        if !complete,
           coverage.permitsAbsenceReconciliation,
           let highWatermark {
            pendingHistoryContinuation = try .init(
                coverage: coverage,
                targetHighWatermarkMessageID: highWatermark,
                lastPaginationReceipt: finalReceipt,
                observedExistingFilter: observedExistingFilter
            )
        } else {
            pendingHistoryContinuation = nil
        }
        return .init(
            messages: messages,
            reconciliations: reconciliations,
            finalReceipt: finalReceipt,
            isComplete: complete,
            skippedCount: skipped,
            coverage: coverage,
            sourceHighWatermark: highWatermark,
            pendingIncremental: pendingIncremental,
            pendingHistoryContinuation: pendingHistoryContinuation,
            observedExistingFilter: observedExistingFilter,
            outputLimitReached: outputLimitReached
        )
    }

    private func normalize(
        _ raw: DiscordMessageDTO,
        authority: DiscordConnectorAuthority,
        selection: DiscordSourceSelection,
        receipt: ConnectorPaginationReceipt,
        trace: DiscordTraceContext
    ) throws -> DiscordImportedMessage {
        guard raw.guildID != nil else {
            throw DiscordFailure(.directMessageRejected)
        }
        guard DiscordValidation.isSnowflake(raw.id),
              raw.channelID == selection.historyChannelID,
              raw.guildID == selection.guildID,
              DiscordValidation.isSnowflake(raw.author.id),
              let sourceTimestamp = DiscordDateParser.date(raw.timestamp),
              raw.editedTimestamp.flatMap(DiscordDateParser.date) != nil ||
                raw.editedTimestamp == nil
        else { throw DiscordFailure(.invalidSchema) }

        let editedAt = raw.editedTimestamp.flatMap(DiscordDateParser.date)
        let replyID = raw.messageReference?.messageID
        guard replyID.map(DiscordValidation.isSnowflake) ?? true,
              raw.messageReference?.channelID == nil ||
                raw.messageReference?.channelID == selection.historyChannelID,
              raw.messageReference?.guildID == nil ||
                raw.messageReference?.guildID == selection.guildID
        else {
            throw DiscordFailure(.invalidSchema)
        }

        let limited = authority.messageContentAccess == .limitedByPrivilegedIntent
        let normalizedText = limited ? "" : normalizeText(raw)
        let bodyState: DiscordMessageBodyState
        if limited {
            bodyState = .limitedByMessageContentIntent
        } else if normalizedText.isEmpty {
            bodyState = .empty
        } else {
            bodyState = .available
        }

        let descriptors = try (raw.attachments ?? []).map(attachment)
        guard descriptors.count <= DiscordLimits.maximumAttachmentsPerMessage else {
            throw DiscordFailure(.invalidSchema)
        }
        let connectorAttachments = try descriptors.map {
            try ConnectorAttachmentMetadata(
                attachmentIdentifier: $0.id,
                mediaType: $0.mediaType,
                byteCount: $0.byteCount,
                sourceHash: $0.metadataHash,
                widthPixels: $0.widthPixels,
                heightPixels: $0.heightPixels
            )
        }
        let author = DiscordMessageAuthor(
            id: raw.author.id,
            displayName: DiscordPrivacy.boundedName(
                raw.author.globalName ?? raw.author.username,
                fallback: "Discord member"
            ),
            isBot: raw.author.bot == true
        )
        let editIdentifier = editedAt.map {
            "edited:\(ConnectorEnvelopeDigest.milliseconds($0))"
        } ?? "created:\(raw.id)"
        let attachmentMaterial = descriptors.map {
            ConnectorEnvelopeDigest.lengthPrefixed([
                $0.id,
                $0.filename,
                $0.mediaType,
                String($0.byteCount),
                $0.metadataHash,
            ])
        }.joined()
        let sourceHash = ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                raw.id,
                selection.guildID,
                selection.channelID,
                selection.threadID ?? "",
                replyID ?? "",
                raw.author.id,
                normalizedText,
                editIdentifier,
                attachmentMaterial,
                bodyState.rawValue,
            ])
        )
        let sourceURL = URL(
            string: "https://discord.com/channels/\(selection.guildID)/\(selection.historyChannelID)/\(raw.id)"
        )
        let policy: ConnectorRecordPolicyClassification =
            bodyState == .available && !normalizedText.isEmpty
                ? .localIndexAllowed
                : .metadataOnly
        let envelope = try ConnectorRecordEnvelope(
            provider: "discord",
            pseudonymousAccountIdentifier: authority.accountIdentifier,
            remoteRecordIdentifier: "\(selection.id):\(raw.id)",
            recordType: "discord_message",
            parentOrThreadIdentifier: selection.threadID ?? replyID,
            sourceTimestamp: sourceTimestamp,
            ingestionTimestamp: now(),
            normalizedText: normalizedText,
            attachments: connectorAttachments,
            editOrVersionIdentifier: editIdentifier,
            sourceHash: sourceHash,
            paginationReceipt: receipt,
            provenance: try .init(
                sourceSystem: "discord-api-v10",
                sourceContainerIdentifier: selection.sourceContainerIdentifier,
                sourceURL: sourceURL,
                retrievedAt: now(),
                policyBasis: limited
                    ? "explicit Discord allowlist; Message Content unavailable; metadata only"
                    : "explicit Discord guild/channel/thread allowlist; attachment metadata only"
            ),
            policyClassification: policy,
            contentClassification: .providerRecord,
            containsSensitiveMaterial: false
        )
        emit(
            .normalization,
            trace: trace,
            status: limited ? .degraded : .success,
            reasonCode: limited
                ? DiscordFailureCode.limitedMessageContent.rawValue
                : "discord_message_normalized",
            metadata: .init([
                (.channelHash, DiscordPrivacy.shortHash(selection.historyChannelID)),
                (.attachmentCount, String(descriptors.count)),
                (.contentMode, bodyState.rawValue),
            ])
        )
        return .init(
            guildID: selection.guildID,
            channelID: selection.channelID,
            threadID: selection.threadID,
            messageID: raw.id,
            replyToMessageID: replyID,
            author: author,
            bodyState: bodyState,
            attachments: descriptors,
            envelope: envelope
        )
    }

    private func normalizeText(_ raw: DiscordMessageDTO) -> String {
        var parts: [String] = []
        if let content = raw.content { parts.append(content) }
        for embed in raw.embeds ?? [] {
            if let title = embed.title { parts.append(title) }
            if let description = embed.description { parts.append(description) }
            if let author = embed.author?.name { parts.append(author) }
            for field in embed.fields ?? [] {
                if let name = field.name { parts.append(name) }
                if let value = field.value { parts.append(value) }
            }
            if let footer = embed.footer?.text { parts.append(footer) }
        }
        return ConnectorTextNormalization.text(parts.joined(separator: "\n"))
    }

    private func attachment(_ raw: DiscordAttachmentDTO) throws -> DiscordAttachmentDescriptor {
        guard DiscordValidation.isSnowflake(raw.id),
              raw.size >= 0,
              raw.width.map({ $0 > 0 }) ?? true,
              raw.height.map({ $0 > 0 }) ?? true
        else { throw DiscordFailure(.invalidSchema) }
        let filename = safeFilename(raw.filename)
        let mediaType = safeMediaType(raw.contentType)
        let hash = ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                raw.id,
                filename,
                mediaType,
                String(raw.size),
                raw.width.map(String.init) ?? "",
                raw.height.map(String.init) ?? "",
            ])
        )
        return .init(
            id: raw.id,
            filename: filename,
            mediaType: mediaType,
            byteCount: raw.size,
            widthPixels: raw.width,
            heightPixels: raw.height,
            metadataHash: hash,
            bodyDownloaded: false
        )
    }

    private func safeFilename(_ value: String) -> String {
        let withoutSeparators = value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let normalized = ConnectorTextNormalization.text(withoutSeparators)
        let bounded = String(normalized.prefix(DiscordLimits.maximumAttachmentFilenameCharacters))
        return bounded.isEmpty ? "discord-attachment" : bounded
    }

    private func safeMediaType(_ value: String?) -> String {
        guard let value else { return "application/octet-stream" }
        let lower = value.lowercased()
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-/"
        )
        guard !lower.isEmpty,
              lower.utf8.count <= 255,
              lower.unicodeScalars.allSatisfy(allowed.contains)
        else { return "application/octet-stream" }
        return lower
    }

    private func validateMessageOrder(
        _ messages: [DiscordMessageDTO],
        before: String?
    ) throws {
        let values = try messages.map { message -> UInt64 in
            guard DiscordValidation.isSnowflake(message.id),
                  let value = UInt64(message.id)
            else { throw DiscordFailure(.invalidSchema) }
            return value
        }
        for pair in zip(values, values.dropFirst()) {
            guard pair.0 > pair.1 else { throw DiscordFailure(.paginationOutOfOrder) }
        }
        if let before, let cursor = UInt64(before) {
            guard values.allSatisfy({ $0 < cursor }) else {
                throw DiscordFailure(.paginationOutOfOrder)
            }
        }
    }

    private func makeTombstone(
        existing: ConnectorRecordEnvelope,
        receipt: ConnectorPaginationReceipt,
        checkpointIdentifier: String
    ) throws -> ConnectorRecordEnvelope {
        let timestamp = max(
            now().timeIntervalSince1970,
            existing.sourceTimestamp.timeIntervalSince1970 + 0.001
        )
        let sourceHash = ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                "discord-tombstone",
                existing.remoteRecordIdentifier,
                existing.sourceHash,
            ])
        )
        return try ConnectorRecordEnvelope(
            provider: existing.provider,
            pseudonymousAccountIdentifier: existing.pseudonymousAccountIdentifier,
            remoteRecordIdentifier: existing.remoteRecordIdentifier,
            recordType: existing.recordType,
            parentOrThreadIdentifier: existing.parentOrThreadIdentifier,
            sourceTimestamp: Date(timeIntervalSince1970: timestamp),
            ingestionTimestamp: now(),
            normalizedText: "",
            attachments: [],
            deletionState: .tombstone,
            editOrVersionIdentifier: "deleted:\(checkpointIdentifier)",
            sourceHash: sourceHash,
            paginationReceipt: receipt,
            provenance: try .init(
                sourceSystem: existing.provenance.sourceSystem,
                sourceContainerIdentifier: existing.provenance.sourceContainerIdentifier,
                sourceURL: existing.provenance.sourceURL,
                retrievedAt: now(),
                policyBasis: "two complete Discord REST reconciliations confirmed absence"
            ),
            policyClassification: .metadataOnly,
            contentClassification: .providerRecord,
            containsSensitiveMaterial: false
        )
    }

    private func archivedThreads(
        accountIdentifier: String,
        parent: DiscordChannel,
        privateJoinedOnly: Bool,
        trace: DiscordTraceContext
    ) async throws -> [DiscordChannel] {
        var before: String?
        var pages = 0
        var byID: [String: DiscordChannel] = [:]
        repeat {
            guard pages < DiscordLimits.maximumThreadPages else {
                throw DiscordFailure(.syncIncomplete)
            }
            let page: DiscordThreadsPageDTO
            if privateJoinedOnly {
                page = try await client.joinedPrivateArchivedThreads(
                    accountIdentifier: accountIdentifier,
                    channelID: parent.id,
                    before: before,
                    trace: trace.child()
                )
            } else {
                page = try await client.publicArchivedThreads(
                    accountIdentifier: accountIdentifier,
                    channelID: parent.id,
                    before: before,
                    trace: trace.child()
                )
            }
            for raw in page.threads {
                if let thread = try admittedThread(
                    raw,
                    guildID: parent.guildID
                ) {
                    byID[thread.id] = thread
                }
            }
            pages += 1
            guard page.hasMore == true else { before = nil; break }
            let next: String?
            if privateJoinedOnly {
                next = page.threads.last?.id
            } else {
                next = page.threads.last?.threadMetadata?.archiveTimestamp
            }
            guard let next, !next.isEmpty, next != before else {
                throw DiscordFailure(.paginationDidNotAdvance)
            }
            guard DiscordValidation.isBoundedCursor(next),
                  privateJoinedOnly
                    ? DiscordValidation.isSnowflake(next)
                    : DiscordDateParser.date(next) != nil
            else { throw DiscordFailure(.invalidSchema) }
            before = next
        } while before != nil
        return byID.values.sorted(by: { $0.id < $1.id })
    }

    private func admittedThread(
        _ raw: DiscordChannelDTO,
        guildID: String
    ) throws -> DiscordChannel? {
        guard let type = DiscordChannelType(rawValue: raw.type),
              DiscordValidation.isSnowflake(raw.id),
              raw.guildID == nil || raw.guildID == guildID,
              type.isThread,
              !type.isDirectMessage
        else { throw DiscordFailure(.invalidSchema) }
        guard let parentID = raw.parentID,
              DiscordValidation.isSnowflake(parentID)
        else { return nil }
        return try channel(from: raw, guildID: guildID)
    }

    private func channel(
        from raw: DiscordChannelDTO,
        guildID: String
    ) throws -> DiscordChannel {
        guard let type = DiscordChannelType(rawValue: raw.type),
              type.isReadableTextSource,
              !type.isDirectMessage,
              DiscordValidation.isSnowflake(raw.id),
              raw.parentID.map(DiscordValidation.isSnowflake) ?? true
        else { throw DiscordFailure(.directMessageRejected) }
        return .init(
            id: raw.id,
            guildID: guildID,
            parentChannelID: raw.parentID,
            displayName: DiscordPrivacy.boundedName(
                raw.name ?? (type.isThread ? "Discord thread" : "Discord channel"),
                fallback: type.isThread ? "Discord thread" : "Discord channel"
            ),
            type: type,
            isArchived: raw.threadMetadata?.archived == true
        )
    }

    private func requireConnected(_ authority: DiscordConnectorAuthority) throws {
        guard let value = snapshots[authority.accountIdentifier],
              [.connected, .degraded].contains(value.state)
        else { throw DiscordFailure(.credentialNotFound) }
    }

    private func snapshot(
        authority: DiscordConnectorAuthority,
        state: DiscordConnectionState,
        attemptedAt: Date?,
        reasonCode: String?
    ) -> DiscordConnectionSnapshot {
        .init(
            accountIdentifier: authority.accountIdentifier,
            credentialReference: state == .disconnected
                ? nil
                : credentialReference(authority.accountIdentifier),
            state: state,
            messageContentAccess: authority.messageContentAccess,
            lastAttemptedAt: attemptedAt,
            lastSuccessfulSyncAt: snapshots[authority.accountIdentifier]?.lastSuccessfulSyncAt,
            importedItemCount: snapshots[authority.accountIdentifier]?.importedItemCount ?? 0,
            skippedItemCount: snapshots[authority.accountIdentifier]?.skippedItemCount ?? 0,
            attachmentCount: snapshots[authority.accountIdentifier]?.attachmentCount ?? 0,
            latestReasonCode: reasonCode,
            rateLimitState: snapshots[authority.accountIdentifier]?.rateLimitState
        )
    }

    private func credentialReference(_ accountIdentifier: String) -> String {
        "keychain:discord:\(DiscordPrivacy.shortHash(accountIdentifier))"
    }

    private func mapFailure(_ error: Error) -> DiscordFailure {
        if let failure = error as? DiscordFailure { return failure }
        if let failure = error as? DiscordCredentialStoreFailure {
            switch failure.code {
            case .notFound:
                return .init(.credentialNotFound)
            case .deleteFailed:
                return .init(.credentialDeleteFailed)
            default:
                return .init(.credentialStoreUnavailable)
            }
        }
        if error is ConnectorEnvelopeFailureCode {
            return .init(.invalidSchema)
        }
        if error is CancellationError { return .init(.cancelled) }
        return .init(.transportFailure)
    }

    private func authorityMetadata(_ authority: DiscordConnectorAuthority) -> DiscordTraceMetadata {
        .init([
            (.accountHash, DiscordPrivacy.shortHash(authority.accountIdentifier)),
            (.importedCount, String(authority.channelAllowlist.count + authority.threadAllowlist.count)),
            (.contentMode, authority.messageContentAccess.rawValue),
        ])
    }

    private func selectionMetadata(_ selection: DiscordSourceSelection) -> DiscordTraceMetadata {
        .init([
            (.guildHash, DiscordPrivacy.shortHash(selection.guildID)),
            (.channelHash, DiscordPrivacy.shortHash(selection.channelID)),
            (.threadHash, selection.threadID.map(DiscordPrivacy.shortHash) ?? "none"),
        ])
    }

    private func emit(
        _ name: DiscordTraceEventName,
        trace: DiscordTraceContext,
        status: DiscordTraceStatus,
        reasonCode: String,
        metadata: DiscordTraceMetadata
    ) {
        let event = DiscordTraceEvent(
            timestamp: now(),
            event: name,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "discord_connector",
            status: status,
            reasonCode: reasonCode,
            metadata: metadata
        )
        eventSink?(event)
        if eventSink == nil { DiscordProductionTraceLogger.emit(event) }
    }
}

private extension DiscordImportedMessage {
    func replacingEnvelope(_ envelope: ConnectorRecordEnvelope) -> DiscordImportedMessage {
        .init(
            guildID: guildID,
            channelID: channelID,
            threadID: threadID,
            messageID: messageID,
            replyToMessageID: replyToMessageID,
            author: author,
            bodyState: bodyState,
            attachments: attachments,
            envelope: envelope
        )
    }
}
