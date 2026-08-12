import Foundation

enum AgentLokiReadOnlyToolName: String, Codable, CaseIterable, Hashable, Sendable {
    case getCurrentBrief = "get_current_brief"
    case getBriefByID = "get_brief_by_id"
    case searchBriefHistory = "search_brief_history"
    case searchVaultText = "search_vault_text"
    case getVaultItem = "get_vault_item"
    case listConnectedSources = "list_connected_sources"
    case getSourceHealth = "get_source_health"
    case listSlackWorkspaces = "list_slack_workspaces"
    case listSelectedSlackChannels = "list_selected_slack_channels"
    case getDeliveryStatus = "get_delivery_status"
    case getUpdateStatus = "get_update_status"
    case previewBackfillRequest = "preview_backfill_request"
}

enum AgentLokiToolArgumentValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case stringList([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode([String].self) {
            self = .stringList(value)
        } else {
            throw DecodingError.typeMismatch(
                AgentLokiToolArgumentValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Tool arguments support only strings, integers, booleans, and string arrays."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .stringList(value): try container.encode(value)
        }
    }
}

struct AgentLokiToolRequest: Codable, Hashable, Sendable {
    let name: String
    let arguments: [String: AgentLokiToolArgumentValue]

    init(name: String, arguments: [String: AgentLokiToolArgumentValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentLokiAnyCodingKey.self)
        let allowedKeys = Set(["name", "arguments"])
        let unknownKeys = Set(container.allKeys.map(\.stringValue)).subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown tool request fields: \(unknownKeys.sorted().joined(separator: ","))"
                )
            )
        }
        let nameKey = AgentLokiAnyCodingKey("name")
        let argumentsKey = AgentLokiAnyCodingKey("arguments")
        self.name = try container.decode(String.self, forKey: nameKey)
        self.arguments = try container.decodeIfPresent(
            [String: AgentLokiToolArgumentValue].self,
            forKey: argumentsKey
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AgentLokiAnyCodingKey.self)
        try container.encode(name, forKey: AgentLokiAnyCodingKey("name"))
        try container.encode(arguments, forKey: AgentLokiAnyCodingKey("arguments"))
    }
}

private struct AgentLokiAnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum AgentLokiToolArgumentKind: String, Codable, Hashable, Sendable {
    case string
    case integer
    case boolean
    case stringList = "string_list"
    case dateTime = "date_time"
}

struct AgentLokiToolArgumentRule: Codable, Hashable, Sendable {
    let kind: AgentLokiToolArgumentKind
    let required: Bool
    let maximumCharacters: Int?
    let maximumListCount: Int?
    let minimumInteger: Int?
    let maximumInteger: Int?

    init(
        kind: AgentLokiToolArgumentKind,
        required: Bool = false,
        maximumCharacters: Int? = nil,
        maximumListCount: Int? = nil,
        minimumInteger: Int? = nil,
        maximumInteger: Int? = nil
    ) {
        self.kind = kind
        self.required = required
        self.maximumCharacters = maximumCharacters
        self.maximumListCount = maximumListCount
        self.minimumInteger = minimumInteger
        self.maximumInteger = maximumInteger
    }
}

struct AgentLokiToolDescriptor: Codable, Hashable, Sendable {
    let name: AgentLokiReadOnlyToolName
    let arguments: [String: AgentLokiToolArgumentRule]
    let maximumResultCount: Int
    let readOnly: Bool
}

enum AgentLokiToolFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case unknownTool = "chat_tool_unknown"
    case unknownArgument = "chat_tool_unknown_argument"
    case missingArgument = "chat_tool_missing_argument"
    case invalidArgumentType = "chat_tool_invalid_argument_type"
    case invalidArgumentValue = "chat_tool_invalid_argument_value"
    case resultLimitExceeded = "chat_tool_result_limit_exceeded"
    case timeRangeInvalid = "chat_tool_time_range_invalid"
    case timeRangeExceeded = "chat_tool_time_range_exceeded"
    case authorizationDenied = "chat_tool_authorization_denied"
    case accountScopeDenied = "chat_tool_account_scope_denied"
    case containerScopeDenied = "chat_tool_container_scope_denied"
    case requestAdmissionClosed = "chat_tool_request_admission_closed"
    case cancelled = "chat_tool_cancelled"
    case dataUnavailable = "chat_tool_data_unavailable"
    case readFailed = "chat_tool_read_failed"
}

struct AgentLokiToolFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: AgentLokiToolFailureCode
    let argumentName: String?
    let message: String

    init(
        _ code: AgentLokiToolFailureCode,
        argumentName: String? = nil,
        message: String? = nil
    ) {
        self.code = code
        self.argumentName = argumentName.map(AgentLokiEvidenceSanitizer.classification)
        self.message = AgentLokiEvidenceSanitizer.text(
            message ?? code.defaultMessage,
            maximumCharacters: 240
        )
    }

    var errorDescription: String? { message }
    var reasonCode: String { code.rawValue }
}

private extension AgentLokiToolFailureCode {
    var defaultMessage: String {
        switch self {
        case .unknownTool: "That tool is not registered."
        case .unknownArgument: "The request contains an unsupported argument."
        case .missingArgument: "The request is missing a required argument."
        case .invalidArgumentType: "An argument has the wrong type."
        case .invalidArgumentValue: "An argument is outside the allowed bounds."
        case .resultLimitExceeded: "The requested result count is outside the allowed bounds."
        case .timeRangeInvalid: "The requested time range is invalid."
        case .timeRangeExceeded: "The requested time range is too large."
        case .authorizationDenied: "The read request is not authorized."
        case .accountScopeDenied: "The account scope is not authorized."
        case .containerScopeDenied: "The container scope is not authorized."
        case .requestAdmissionClosed: "Read-only tool requests are temporarily unavailable."
        case .cancelled: "The read request was cancelled."
        case .dataUnavailable: "No authorized local data is available."
        case .readFailed: "The authorized local read could not be completed."
        }
    }
}

struct AgentLokiValidatedToolRequest: Hashable, Sendable {
    let name: AgentLokiReadOnlyToolName
    let arguments: [String: AgentLokiToolArgumentValue]
    let startDate: Date?
    let endDate: Date?
    let resultLimit: Int
    let canonicalRequest: String

    func string(_ key: String) -> String? {
        guard case let .string(value) = arguments[key] else { return nil }
        return value
    }

    func integer(_ key: String) -> Int? {
        guard case let .integer(value) = arguments[key] else { return nil }
        return value
    }

    func boolean(_ key: String) -> Bool? {
        guard case let .boolean(value) = arguments[key] else { return nil }
        return value
    }

    func stringList(_ key: String) -> [String]? {
        guard case let .stringList(value) = arguments[key] else { return nil }
        return value
    }
}

enum AgentLokiReadOnlyToolRegistry {
    static let schemaVersion = "agent-loki-read-only-tools-v1"
    static let maximumTimeRange: TimeInterval = 366 * 24 * 60 * 60

    static let descriptors: [AgentLokiReadOnlyToolName: AgentLokiToolDescriptor] = {
        let identifier = AgentLokiToolArgumentRule(
            kind: .string,
            required: true,
            maximumCharacters: 512
        )
        let optionalDate = AgentLokiToolArgumentRule(
            kind: .dateTime,
            maximumCharacters: 40
        )
        let boundedLimit = AgentLokiToolArgumentRule(
            kind: .integer,
            minimumInteger: 1,
            maximumInteger: 50
        )
        return [
            .getCurrentBrief: .init(
                name: .getCurrentBrief,
                arguments: [:],
                maximumResultCount: 1,
                readOnly: true
            ),
            .getBriefByID: .init(
                name: .getBriefByID,
                arguments: ["brief_id": identifier],
                maximumResultCount: 1,
                readOnly: true
            ),
            .searchBriefHistory: .init(
                name: .searchBriefHistory,
                arguments: [
                    "query": .init(kind: .string, maximumCharacters: 256),
                    "start_at": optionalDate,
                    "end_at": optionalDate,
                    "limit": boundedLimit,
                ],
                maximumResultCount: 50,
                readOnly: true
            ),
            .searchVaultText: .init(
                name: .searchVaultText,
                arguments: [
                    "query": .init(kind: .string, required: true, maximumCharacters: 512),
                    "account_id": .init(kind: .string, maximumCharacters: 512),
                    "container_id": .init(kind: .string, maximumCharacters: 512),
                    "start_at": optionalDate,
                    "end_at": optionalDate,
                    "limit": .init(
                        kind: .integer,
                        minimumInteger: 1,
                        maximumInteger: 20
                    ),
                ],
                maximumResultCount: 20,
                readOnly: true
            ),
            .getVaultItem: .init(
                name: .getVaultItem,
                arguments: ["item_id": identifier],
                maximumResultCount: 1,
                readOnly: true
            ),
            .listConnectedSources: .init(
                name: .listConnectedSources,
                arguments: ["limit": boundedLimit],
                maximumResultCount: 50,
                readOnly: true
            ),
            .getSourceHealth: .init(
                name: .getSourceHealth,
                arguments: ["source_id": identifier],
                maximumResultCount: 1,
                readOnly: true
            ),
            .listSlackWorkspaces: .init(
                name: .listSlackWorkspaces,
                arguments: ["limit": boundedLimit],
                maximumResultCount: 50,
                readOnly: true
            ),
            .listSelectedSlackChannels: .init(
                name: .listSelectedSlackChannels,
                arguments: [
                    "workspace_id": identifier,
                    "limit": boundedLimit,
                ],
                maximumResultCount: 50,
                readOnly: true
            ),
            .getDeliveryStatus: .init(
                name: .getDeliveryStatus,
                arguments: [:],
                maximumResultCount: 1,
                readOnly: true
            ),
            .getUpdateStatus: .init(
                name: .getUpdateStatus,
                arguments: [:],
                maximumResultCount: 1,
                readOnly: true
            ),
            .previewBackfillRequest: .init(
                name: .previewBackfillRequest,
                arguments: [
                    "workspace_id": identifier,
                    "channel_ids": .init(
                        kind: .stringList,
                        maximumCharacters: 512,
                        maximumListCount: 50
                    ),
                    "item_limit": .init(
                        kind: .integer,
                        minimumInteger: 1,
                        maximumInteger: 1_000
                    ),
                ],
                maximumResultCount: 1,
                readOnly: true
            ),
        ]
    }()

    static var registeredNames: Set<String> {
        Set(descriptors.keys.map(\.rawValue))
    }

    static func validate(_ request: AgentLokiToolRequest) throws -> AgentLokiValidatedToolRequest {
        guard let name = AgentLokiReadOnlyToolName(rawValue: request.name),
              let descriptor = descriptors[name]
        else {
            throw AgentLokiToolFailure(.unknownTool)
        }
        guard descriptor.readOnly else {
            throw AgentLokiToolFailure(.unknownTool)
        }

        let unknownArguments = Set(request.arguments.keys).subtracting(descriptor.arguments.keys)
        guard let firstUnknown = unknownArguments.sorted().first else {
            return try semanticallyValidate(
                name: name,
                descriptor: descriptor,
                arguments: request.arguments
            )
        }
        throw AgentLokiToolFailure(.unknownArgument, argumentName: firstUnknown)
    }

    private static func semanticallyValidate(
        name: AgentLokiReadOnlyToolName,
        descriptor: AgentLokiToolDescriptor,
        arguments: [String: AgentLokiToolArgumentValue]
    ) throws -> AgentLokiValidatedToolRequest {
        for (argumentName, rule) in descriptor.arguments {
            guard let value = arguments[argumentName] else {
                if rule.required {
                    throw AgentLokiToolFailure(.missingArgument, argumentName: argumentName)
                }
                continue
            }
            try validate(value, name: argumentName, rule: rule)
        }

        if name == .searchVaultText {
            let query = try requiredString("query", arguments: arguments)
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: "query")
            }
        }
        if name == .searchBriefHistory,
           case let .string(query)? = arguments["query"],
           query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: "query")
        }

        let startDate = try date("start_at", arguments: arguments)
        let endDate = try date("end_at", arguments: arguments)
        if let startDate, let endDate {
            guard startDate <= endDate else {
                throw AgentLokiToolFailure(.timeRangeInvalid)
            }
            guard endDate.timeIntervalSince(startDate) <= maximumTimeRange else {
                throw AgentLokiToolFailure(.timeRangeExceeded)
            }
        }

        let requestedLimit: Int
        if let limit = integer("limit", arguments: arguments) {
            requestedLimit = limit
        } else {
            requestedLimit = descriptor.maximumResultCount
        }
        guard (1 ... descriptor.maximumResultCount).contains(requestedLimit) else {
            throw AgentLokiToolFailure(.resultLimitExceeded, argumentName: "limit")
        }

        let normalizedArguments = arguments.mapValues(Self.normalized)
        return AgentLokiValidatedToolRequest(
            name: name,
            arguments: normalizedArguments,
            startDate: startDate,
            endDate: endDate,
            resultLimit: requestedLimit,
            canonicalRequest: canonicalRequest(name: name, arguments: normalizedArguments)
        )
    }

    private static func validate(
        _ value: AgentLokiToolArgumentValue,
        name: String,
        rule: AgentLokiToolArgumentRule
    ) throws {
        switch (rule.kind, value) {
        case let (.string, .string(string)), let (.dateTime, .string(string)):
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  string.count <= (rule.maximumCharacters ?? 512)
            else {
                throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: name)
            }
            if rule.kind == .dateTime, parseDate(string) == nil {
                throw AgentLokiToolFailure(.timeRangeInvalid, argumentName: name)
            }
        case let (.integer, .integer(integer)):
            if let minimum = rule.minimumInteger, integer < minimum {
                throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: name)
            }
            if let maximum = rule.maximumInteger, integer > maximum {
                if name == "limit" {
                    throw AgentLokiToolFailure(.resultLimitExceeded, argumentName: name)
                }
                throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: name)
            }
        case (.boolean, .boolean):
            break
        case let (.stringList, .stringList(strings)):
            guard strings.count <= (rule.maximumListCount ?? 50),
                  Set(strings).count == strings.count,
                  strings.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          $0.count <= (rule.maximumCharacters ?? 512)
                  })
            else {
                throw AgentLokiToolFailure(.invalidArgumentValue, argumentName: name)
            }
        default:
            throw AgentLokiToolFailure(.invalidArgumentType, argumentName: name)
        }
    }

    private static func requiredString(
        _ key: String,
        arguments: [String: AgentLokiToolArgumentValue]
    ) throws -> String {
        guard case let .string(value)? = arguments[key] else {
            throw AgentLokiToolFailure(.missingArgument, argumentName: key)
        }
        return value
    }

    private static func integer(
        _ key: String,
        arguments: [String: AgentLokiToolArgumentValue]
    ) -> Int? {
        guard case let .integer(value)? = arguments[key] else { return nil }
        return value
    }

    private static func date(
        _ key: String,
        arguments: [String: AgentLokiToolArgumentValue]
    ) throws -> Date? {
        guard case let .string(value)? = arguments[key] else { return nil }
        guard let date = parseDate(value) else {
            throw AgentLokiToolFailure(.timeRangeInvalid, argumentName: key)
        }
        return date
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func normalized(
        _ value: AgentLokiToolArgumentValue
    ) -> AgentLokiToolArgumentValue {
        switch value {
        case let .string(string):
            return .string(AgentLokiEvidenceSanitizer.text(string, maximumCharacters: 512))
        case let .integer(integer):
            return .integer(integer)
        case let .boolean(boolean):
            return .boolean(boolean)
        case let .stringList(strings):
            return .stringList(strings.map {
                AgentLokiEvidenceSanitizer.text($0, maximumCharacters: 512)
            })
        }
    }

    private static func canonicalRequest(
        name: AgentLokiReadOnlyToolName,
        arguments: [String: AgentLokiToolArgumentValue]
    ) -> String {
        let entries = arguments.keys.sorted().map { key -> String in
            let value: String
            switch arguments[key] {
            case let .string(string): value = "s:\(string)"
            case let .integer(integer): value = "i:\(integer)"
            case let .boolean(boolean): value = "b:\(boolean)"
            case let .stringList(strings): value = "a:\(strings.joined(separator: "\u{1e}"))"
            case nil: value = ""
            }
            return "\(key)=\(value)"
        }
        return ([schemaVersion, name.rawValue] + entries).joined(separator: "\u{1f}")
    }
}

enum AgentLokiToolFieldValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case date(Date)
    case stringList([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Date.self) {
            self = .date(value)
        } else if let value = try? container.decode([String].self) {
            self = .stringList(value)
        } else {
            throw DecodingError.typeMismatch(
                AgentLokiToolFieldValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported safe field value.")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .date(value): try container.encode(value)
        case let .stringList(value): try container.encode(value)
        }
    }
}

struct AgentLokiToolRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fields: [String: AgentLokiToolFieldValue]
    let evidenceReferenceIDs: [String]

    init(
        id: String,
        fields: [String: AgentLokiToolFieldValue],
        evidenceReferenceIDs: [String] = []
    ) {
        self.id = AgentLokiEvidenceSanitizer.identifier(id)
        var safeFields: [String: AgentLokiToolFieldValue] = [:]
        for key in fields.keys.sorted().prefix(64) {
            let safeKey = AgentLokiEvidenceSanitizer.classification(key)
            guard let value = fields[key] else { continue }
            safeFields[safeKey] = Self.bounded(value)
        }
        self.fields = safeFields
        self.evidenceReferenceIDs = Array(evidenceReferenceIDs.prefix(50))
            .map(AgentLokiEvidenceSanitizer.identifier)
    }

    private static func bounded(_ value: AgentLokiToolFieldValue) -> AgentLokiToolFieldValue {
        switch value {
        case let .string(string):
            return .string(AgentLokiEvidenceSanitizer.text(string, maximumCharacters: 1_200))
        case let .stringList(strings):
            return .stringList(Array(strings.prefix(50)).map {
                AgentLokiEvidenceSanitizer.text($0, maximumCharacters: 240)
            })
        case .integer, .boolean, .date:
            return value
        }
    }
}

struct AgentLokiToolSnapshot: Codable, Hashable, Sendable {
    let records: [AgentLokiToolRecord]
    let evidence: [AgentLokiEvidenceExcerpt]
    let reasonCode: String
    let wasTruncated: Bool

    init(
        records: [AgentLokiToolRecord],
        evidence: [AgentLokiEvidenceExcerpt] = [],
        reasonCode: String = "chat_tool_read_complete",
        wasTruncated: Bool = false
    ) {
        self.records = Array(records.prefix(200))
        self.evidence = Array(evidence.prefix(
            AgentLokiEvidenceLimits.maximumEvidenceItemsPerResult
        ))
        self.reasonCode = AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        self.wasTruncated = wasTruncated ||
            records.count > self.records.count ||
            evidence.count > self.evidence.count
    }
}

struct AgentLokiBriefHistoryQuery: Hashable, Sendable {
    let text: String?
    let startDate: Date?
    let endDate: Date?
    let limit: Int
}

struct AgentLokiVaultTextQuery: Hashable, Sendable {
    let text: String
    let accountID: String?
    let containerID: String?
    let startDate: Date?
    let endDate: Date?
    let limit: Int
    let attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?

    init(
        text: String,
        accountID: String?,
        containerID: String?,
        startDate: Date?,
        endDate: Date?,
        limit: Int,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority? = nil
    ) {
        self.text = text
        self.accountID = accountID
        self.containerID = containerID
        self.startDate = startDate
        self.endDate = endDate
        self.limit = limit
        self.attachedSourceAuthority = attachedSourceAuthority
    }
}

/// Immutable authority captured with one Chat request. The executor pins Vault
/// reads to this account/container generation and asks the live data source to
/// revalidate it both before and after every read.
struct AgentLokiAttachedSourceRequestAuthority: Hashable, Sendable {
    let sourceIdentifier: String
    let accountIdentifier: String
    let containerIdentifiers: Set<String>
    let generationIdentifier: String
    let sourceEpoch: Int64
    let sourceDigest: String
    let generationReceiptHash: String?

    init(
        sourceIdentifier: String,
        accountIdentifier: String,
        containerIdentifiers: Set<String>,
        generationIdentifier: String,
        sourceEpoch: Int64,
        sourceDigest: String,
        generationReceiptHash: String? = nil
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.accountIdentifier = accountIdentifier
        self.containerIdentifiers = containerIdentifiers
        self.generationIdentifier = generationIdentifier
        self.sourceEpoch = sourceEpoch
        self.sourceDigest = sourceDigest
        self.generationReceiptHash = generationReceiptHash
    }
}

struct AgentLokiBackfillPreviewQuery: Hashable, Sendable {
    let workspaceID: String
    let channelIDs: [String]
    let itemLimit: Int
}

enum AgentLokiAuthorizationScope: Hashable, Sendable {
    case general(AgentLokiReadOnlyToolName)
    case brief(id: String)
    case vaultSearch(accountID: String?, containerID: String?)
    case vaultItem(id: String)
    case source(id: String)
    case slackWorkspace(id: String)
    case backfillPreview(workspaceID: String)
    case attachedSourceVaultSearch(
        authority: AgentLokiAttachedSourceRequestAuthority,
        requestedAccountID: String?,
        requestedContainerID: String?
    )
    case attachedSourceVaultItem(
        authority: AgentLokiAttachedSourceRequestAuthority,
        id: String
    )
    case attachedSourceHealth(
        authority: AgentLokiAttachedSourceRequestAuthority,
        requestedSourceID: String
    )
    case attachedSourceTool(
        authority: AgentLokiAttachedSourceRequestAuthority,
        name: AgentLokiReadOnlyToolName
    )
}

struct AgentLokiAuthorizationDecision: Hashable, Sendable {
    let allowed: Bool
    let failureCode: AgentLokiToolFailureCode
    let reasonCode: String

    static func allow(reasonCode: String = "chat_tool_scope_authorized") -> Self {
        .init(
            allowed: true,
            failureCode: .authorizationDenied,
            reasonCode: AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        )
    }

    static func deny(
        _ failureCode: AgentLokiToolFailureCode = .authorizationDenied,
        reasonCode: String = "chat_tool_scope_denied"
    ) -> Self {
        .init(
            allowed: false,
            failureCode: failureCode,
            reasonCode: AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        )
    }
}

/// Integration adapters must satisfy these methods from already-local state.
/// No method authorizes provider refreshes, network requests, writes, or update
/// actions. The Vault barrier methods are mandatory so P6U can observe active
/// foreground database work.
protocol AgentLokiReadOnlyToolDataSource: Sendable {
    func authorizationDecision(
        for scope: AgentLokiAuthorizationScope
    ) async -> AgentLokiAuthorizationDecision

    func currentBriefSnapshot() async throws -> AgentLokiToolSnapshot
    func briefSnapshot(id: String) async throws -> AgentLokiToolSnapshot
    func searchBriefHistory(
        _ query: AgentLokiBriefHistoryQuery
    ) async throws -> AgentLokiToolSnapshot

    func beginVaultForegroundRead() async
    func endVaultForegroundRead() async
    func searchVaultText(
        _ query: AgentLokiVaultTextQuery
    ) async throws -> AgentLokiToolSnapshot
    func vaultItemSnapshot(id: String) async throws -> AgentLokiToolSnapshot
    func vaultItemSnapshot(
        id: String,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?
    ) async throws -> AgentLokiToolSnapshot

    func connectedSourcesSnapshot(limit: Int) async throws -> AgentLokiToolSnapshot
    func sourceHealthSnapshot(id: String) async throws -> AgentLokiToolSnapshot
    func slackWorkspacesSnapshot(limit: Int) async throws -> AgentLokiToolSnapshot
    func selectedSlackChannelsSnapshot(
        workspaceID: String,
        limit: Int
    ) async throws -> AgentLokiToolSnapshot
    func deliveryStatusSnapshot() async throws -> AgentLokiToolSnapshot
    func updateStatusSnapshot() async throws -> AgentLokiToolSnapshot
    func previewBackfill(
        _ query: AgentLokiBackfillPreviewQuery
    ) async throws -> AgentLokiToolSnapshot
}

extension AgentLokiReadOnlyToolDataSource {
    func vaultItemSnapshot(
        id: String,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?
    ) async throws -> AgentLokiToolSnapshot {
        guard attachedSourceAuthority == nil else {
            throw AgentLokiToolFailure(.authorizationDenied)
        }
        return try await vaultItemSnapshot(id: id)
    }
}

enum AgentLokiToolResultStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case empty
    case rejected
    case cancelled
    case failed
}

struct AgentLokiToolResult: Codable, Hashable, Sendable {
    let requestID: String
    let toolName: AgentLokiReadOnlyToolName?
    let status: AgentLokiToolResultStatus
    let reasonCode: String
    let records: [AgentLokiToolRecord]
    let evidence: [AgentLokiEvidenceExcerpt]
    let receipt: AgentLokiToolReceipt
    let failure: AgentLokiToolFailure?
    let wasTruncated: Bool
}

actor AgentLokiReadOnlyToolExecutor {
    private let dataSource: any AgentLokiReadOnlyToolDataSource
    private let traceLogger: AgentLokiToolTraceLogger
    private let now: @Sendable () -> Date
    private var acceptsRequests = true
    private var epoch: UInt64 = 0
    private var pending: [UUID: Task<AgentLokiToolSnapshot, Error>] = [:]
    private var lifecycleCancellationReasonCode = "chat_tool_cancelled_for_lifecycle_transition"

    init(
        dataSource: any AgentLokiReadOnlyToolDataSource,
        traceLogger: AgentLokiToolTraceLogger = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataSource = dataSource
        self.traceLogger = traceLogger
        self.now = now
    }

    func execute(
        _ proposed: AgentLokiToolRequest,
        modelIdentifier: String? = nil,
        context: AgentLokiToolTraceContext = .init(),
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority? = nil
    ) async -> AgentLokiToolResult {
        let requestUUID = UUID()
        let requestID = requestUUID.uuidString.lowercased()
        let startedAt = now()
        let toolName = AgentLokiReadOnlyToolName(rawValue: proposed.name)
        let safeToolName = toolName?.rawValue ?? "unregistered"
        emit(
            event: .requested,
            context: context,
            status: .started,
            reasonCode: "chat_tool_request_received",
            toolName: safeToolName,
            modelIdentifier: modelIdentifier,
            startedAt: startedAt
        )

        guard acceptsRequests else {
            return rejectedResult(
                requestID: requestID,
                toolName: toolName,
                canonicalRequest: safeToolName,
                failure: .init(.requestAdmissionClosed),
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
        }

        let validated: AgentLokiValidatedToolRequest
        do {
            validated = try AgentLokiReadOnlyToolRegistry.validate(proposed)
        } catch let failure as AgentLokiToolFailure {
            return rejectedResult(
                requestID: requestID,
                toolName: toolName,
                canonicalRequest: safeToolName,
                failure: failure,
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
        } catch {
            return rejectedResult(
                requestID: requestID,
                toolName: toolName,
                canonicalRequest: safeToolName,
                failure: .init(.invalidArgumentValue),
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
        }

        let requestEpoch = epoch
        let authorizationScope = Self.authorizationScope(
            for: validated,
            attachedSourceAuthority: attachedSourceAuthority
        )
        let authorization = await dataSource.authorizationDecision(
            for: authorizationScope
        )
        guard acceptsRequests, requestEpoch == epoch, !Task.isCancelled else {
            return cancelledResult(
                requestID: requestID,
                validated: validated,
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
        }
        guard authorization.allowed else {
            return rejectedResult(
                requestID: requestID,
                toolName: validated.name,
                canonicalRequest: validated.canonicalRequest,
                failure: .init(
                    authorization.failureCode,
                    message: AgentLokiToolFailureCode.authorizationDenied.defaultMessage
                ),
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt,
                reasonCode: authorization.reasonCode
            )
        }

        emit(
            event: .validated,
            context: context.child(),
            status: .success,
            reasonCode: authorization.reasonCode,
            toolName: validated.name.rawValue,
            modelIdentifier: modelIdentifier,
            startedAt: startedAt
        )

        let task = Task {
            try Task.checkCancellation()
            return try await Self.readSnapshot(
                dataSource: dataSource,
                request: validated,
                attachedSourceAuthority: attachedSourceAuthority
            )
        }
        pending[requestUUID] = task
        defer { pending.removeValue(forKey: requestUUID) }

        do {
            let unboundedSnapshot = try await task.value
            guard acceptsRequests, requestEpoch == epoch, !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    validated: validated,
                    context: context,
                    modelIdentifier: modelIdentifier,
                    startedAt: startedAt
                )
            }
            let postReadAuthorization = await dataSource.authorizationDecision(
                for: authorizationScope
            )
            guard acceptsRequests, requestEpoch == epoch, !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    validated: validated,
                    context: context,
                    modelIdentifier: modelIdentifier,
                    startedAt: startedAt
                )
            }
            guard postReadAuthorization.allowed else {
                return rejectedResult(
                    requestID: requestID,
                    toolName: validated.name,
                    canonicalRequest: validated.canonicalRequest,
                    failure: .init(
                        postReadAuthorization.failureCode,
                        message: AgentLokiToolFailureCode.authorizationDenied
                            .defaultMessage
                    ),
                    context: context,
                    modelIdentifier: modelIdentifier,
                    startedAt: startedAt,
                    reasonCode: postReadAuthorization.reasonCode
                )
            }
            let snapshot = Self.bounded(
                unboundedSnapshot,
                resultLimit: validated.resultLimit
            )
            let completedAt = now()
            let status: AgentLokiToolResultStatus = snapshot.records.isEmpty && snapshot.evidence.isEmpty
                ? .empty
                : .success
            let receiptStatus: AgentLokiToolReceiptStatus = status == .empty ? .empty : .success
            let receipt = AgentLokiToolReceipt(
                toolName: validated.name.rawValue,
                canonicalRequest: validated.canonicalRequest,
                status: receiptStatus,
                reasonCode: snapshot.reasonCode,
                startedAt: startedAt,
                completedAt: completedAt,
                evidenceReferenceIDs: snapshot.evidence.map(\.reference.id),
                wasTruncated: snapshot.wasTruncated
            )
            emit(
                event: .completed,
                context: context.child(),
                status: status == .empty ? .degraded : .success,
                reasonCode: snapshot.reasonCode,
                toolName: validated.name.rawValue,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt,
                evidenceCount: snapshot.evidence.count,
                resultCount: snapshot.records.count,
                wasTruncated: snapshot.wasTruncated
            )
            return AgentLokiToolResult(
                requestID: requestID,
                toolName: validated.name,
                status: status,
                reasonCode: snapshot.reasonCode,
                records: snapshot.records,
                evidence: snapshot.evidence,
                receipt: receipt,
                failure: nil,
                wasTruncated: snapshot.wasTruncated
            )
        } catch is CancellationError {
            return cancelledResult(
                requestID: requestID,
                validated: validated,
                context: context,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
        } catch {
            let completedAt = now()
            let failure = AgentLokiToolFailure(.readFailed)
            let receipt = AgentLokiToolReceipt(
                toolName: validated.name.rawValue,
                canonicalRequest: validated.canonicalRequest,
                status: .failed,
                reasonCode: failure.reasonCode,
                startedAt: startedAt,
                completedAt: completedAt,
                evidenceReferenceIDs: [],
                wasTruncated: false
            )
            emit(
                event: .completed,
                context: context.child(),
                status: .failed,
                reasonCode: failure.reasonCode,
                toolName: validated.name.rawValue,
                modelIdentifier: modelIdentifier,
                startedAt: startedAt
            )
            return AgentLokiToolResult(
                requestID: requestID,
                toolName: validated.name,
                status: .failed,
                reasonCode: failure.reasonCode,
                records: [],
                evidence: [],
                receipt: receipt,
                failure: failure,
                wasTruncated: false
            )
        }
    }

    @discardableResult
    func cancelAll(
        reasonCode: String = "chat_tool_cancelled_for_lifecycle_transition"
    ) -> Int {
        acceptsRequests = false
        lifecycleCancellationReasonCode = AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        epoch &+= 1
        let tasks = Array(pending.values)
        tasks.forEach { $0.cancel() }
        return tasks.count
    }

    func resume() {
        epoch &+= 1
        lifecycleCancellationReasonCode = "chat_tool_cancelled_for_lifecycle_transition"
        acceptsRequests = true
    }

    func activeRequestCount() -> Int {
        pending.count
    }

    private func rejectedResult(
        requestID: String,
        toolName: AgentLokiReadOnlyToolName?,
        canonicalRequest: String,
        failure: AgentLokiToolFailure,
        context: AgentLokiToolTraceContext,
        modelIdentifier: String?,
        startedAt: Date,
        reasonCode: String? = nil
    ) -> AgentLokiToolResult {
        let completedAt = now()
        let finalReasonCode = reasonCode ?? failure.reasonCode
        let receipt = AgentLokiToolReceipt(
            toolName: toolName?.rawValue ?? "unregistered",
            canonicalRequest: canonicalRequest,
            status: .rejected,
            reasonCode: finalReasonCode,
            startedAt: startedAt,
            completedAt: completedAt,
            evidenceReferenceIDs: [],
            wasTruncated: false
        )
        emit(
            event: .rejected,
            context: context.child(),
            status: .skipped,
            reasonCode: finalReasonCode,
            toolName: toolName?.rawValue ?? "unregistered",
            modelIdentifier: modelIdentifier,
            startedAt: startedAt
        )
        return AgentLokiToolResult(
            requestID: requestID,
            toolName: toolName,
            status: .rejected,
            reasonCode: finalReasonCode,
            records: [],
            evidence: [],
            receipt: receipt,
            failure: failure,
            wasTruncated: false
        )
    }

    private func cancelledResult(
        requestID: String,
        validated: AgentLokiValidatedToolRequest,
        context: AgentLokiToolTraceContext,
        modelIdentifier: String?,
        startedAt: Date
    ) -> AgentLokiToolResult {
        let completedAt = now()
        let failure = AgentLokiToolFailure(.cancelled)
        let finalReasonCode = acceptsRequests
            ? failure.reasonCode
            : lifecycleCancellationReasonCode
        let receipt = AgentLokiToolReceipt(
            toolName: validated.name.rawValue,
            canonicalRequest: validated.canonicalRequest,
            status: .cancelled,
            reasonCode: finalReasonCode,
            startedAt: startedAt,
            completedAt: completedAt,
            evidenceReferenceIDs: [],
            wasTruncated: false
        )
        emit(
            event: .completed,
            context: context.child(),
            status: .skipped,
            reasonCode: finalReasonCode,
            toolName: validated.name.rawValue,
            modelIdentifier: modelIdentifier,
            startedAt: startedAt
        )
        return AgentLokiToolResult(
            requestID: requestID,
            toolName: validated.name,
            status: .cancelled,
            reasonCode: finalReasonCode,
            records: [],
            evidence: [],
            receipt: receipt,
            failure: failure,
            wasTruncated: false
        )
    }

    private func emit(
        event: AgentLokiToolTraceEventName,
        context: AgentLokiToolTraceContext,
        status: AgentLokiToolTraceStatus,
        reasonCode: String,
        toolName: String,
        modelIdentifier: String?,
        startedAt: Date,
        evidenceCount: Int = 0,
        resultCount: Int = 0,
        wasTruncated: Bool = false
    ) {
        let duration = max(0, Int(now().timeIntervalSince(startedAt) * 1_000))
        traceLogger.emit(AgentLokiToolTraceEvent(
            ts: now(),
            event: event,
            context: context,
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: event == .requested ? nil : duration,
            metadata: .init([
                (.tool, toolName),
                (.modelIdentifierHash, AgentLokiToolTracePrivacy.modelIdentifierHash(modelIdentifier)),
                (.evidenceCount, String(evidenceCount)),
                (.resultCount, String(resultCount)),
                (.wasTruncated, String(wasTruncated)),
                (.activeRequestCount, String(pending.count)),
                (.schemaVersion, AgentLokiReadOnlyToolRegistry.schemaVersion),
            ])
        ))
    }

    private nonisolated static func authorizationScope(
        for request: AgentLokiValidatedToolRequest,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?
    ) -> AgentLokiAuthorizationScope {
        if let authority = attachedSourceAuthority {
            switch request.name {
            case .searchVaultText:
                return .attachedSourceVaultSearch(
                    authority: authority,
                    requestedAccountID: request.string("account_id"),
                    requestedContainerID: request.string("container_id")
                )
            case .getVaultItem:
                return .attachedSourceVaultItem(
                    authority: authority,
                    id: request.string("item_id") ?? ""
                )
            case .getSourceHealth:
                return .attachedSourceHealth(
                    authority: authority,
                    requestedSourceID: request.string("source_id") ?? ""
                )
            default:
                return .attachedSourceTool(
                    authority: authority,
                    name: request.name
                )
            }
        }
        switch request.name {
        case .getBriefByID:
            return .brief(id: request.string("brief_id") ?? "")
        case .searchVaultText:
            return .vaultSearch(
                accountID: request.string("account_id"),
                containerID: request.string("container_id")
            )
        case .getVaultItem:
            return .vaultItem(id: request.string("item_id") ?? "")
        case .getSourceHealth:
            return .source(id: request.string("source_id") ?? "")
        case .listSelectedSlackChannels:
            return .slackWorkspace(id: request.string("workspace_id") ?? "")
        case .previewBackfillRequest:
            return .backfillPreview(workspaceID: request.string("workspace_id") ?? "")
        default:
            return .general(request.name)
        }
    }

    private nonisolated static func readSnapshot(
        dataSource: any AgentLokiReadOnlyToolDataSource,
        request: AgentLokiValidatedToolRequest,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?
    ) async throws -> AgentLokiToolSnapshot {
        try Task.checkCancellation()
        switch request.name {
        case .getCurrentBrief:
            return try await dataSource.currentBriefSnapshot()
        case .getBriefByID:
            return try await dataSource.briefSnapshot(id: request.string("brief_id") ?? "")
        case .searchBriefHistory:
            return try await dataSource.searchBriefHistory(.init(
                text: request.string("query"),
                startDate: request.startDate,
                endDate: request.endDate,
                limit: request.resultLimit
            ))
        case .searchVaultText:
            return try await withVaultBarrier(dataSource: dataSource) {
                try await dataSource.searchVaultText(.init(
                    text: request.string("query") ?? "",
                    accountID: attachedSourceAuthority?.accountIdentifier
                        ?? request.string("account_id"),
                    containerID: request.string("container_id"),
                    startDate: request.startDate,
                    endDate: request.endDate,
                    limit: request.resultLimit,
                    attachedSourceAuthority: attachedSourceAuthority
                ))
            }
        case .getVaultItem:
            return try await withVaultBarrier(dataSource: dataSource) {
                try await dataSource.vaultItemSnapshot(
                    id: request.string("item_id") ?? "",
                    attachedSourceAuthority: attachedSourceAuthority
                )
            }
        case .listConnectedSources:
            return try await dataSource.connectedSourcesSnapshot(limit: request.resultLimit)
        case .getSourceHealth:
            return try await dataSource.sourceHealthSnapshot(id: request.string("source_id") ?? "")
        case .listSlackWorkspaces:
            return try await dataSource.slackWorkspacesSnapshot(limit: request.resultLimit)
        case .listSelectedSlackChannels:
            return try await dataSource.selectedSlackChannelsSnapshot(
                workspaceID: request.string("workspace_id") ?? "",
                limit: request.resultLimit
            )
        case .getDeliveryStatus:
            return try await dataSource.deliveryStatusSnapshot()
        case .getUpdateStatus:
            return try await dataSource.updateStatusSnapshot()
        case .previewBackfillRequest:
            return try await dataSource.previewBackfill(.init(
                workspaceID: request.string("workspace_id") ?? "",
                channelIDs: request.stringList("channel_ids") ?? [],
                itemLimit: request.integer("item_limit") ?? 100
            ))
        }
    }

    private nonisolated static func withVaultBarrier(
        dataSource: any AgentLokiReadOnlyToolDataSource,
        operation: @escaping @Sendable () async throws -> AgentLokiToolSnapshot
    ) async throws -> AgentLokiToolSnapshot {
        await dataSource.beginVaultForegroundRead()
        do {
            let result = try await operation()
            await dataSource.endVaultForegroundRead()
            return result
        } catch {
            await dataSource.endVaultForegroundRead()
            throw error
        }
    }

    private nonisolated static func bounded(
        _ snapshot: AgentLokiToolSnapshot,
        resultLimit: Int
    ) -> AgentLokiToolSnapshot {
        let records = Array(snapshot.records.prefix(resultLimit))
        let permittedEvidenceIDs = Set(records.flatMap(\.evidenceReferenceIDs))
        let matchedEvidence = snapshot.evidence.filter {
            permittedEvidenceIDs.isEmpty || permittedEvidenceIDs.contains($0.reference.id)
        }
        let evidence = Array(matchedEvidence.prefix(
            AgentLokiEvidenceLimits.maximumEvidenceItemsPerResult
        ))
        return AgentLokiToolSnapshot(
            records: records,
            evidence: evidence,
            reasonCode: snapshot.reasonCode,
            wasTruncated: snapshot.wasTruncated ||
                records.count < snapshot.records.count ||
                evidence.count < matchedEvidence.count
        )
    }
}
