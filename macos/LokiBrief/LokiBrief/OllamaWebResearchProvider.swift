import CFNetwork
import CryptoKit
import Darwin
import Foundation
import Security

enum OllamaWebResearchLimits {
    static let maximumQueryCharacters = 512
    static let maximumURLCharacters = 4_096
    static let maximumSearchResults = 10
    static let maximumResolvedAddresses = 32
    static let minimumRequestTimeout: TimeInterval = 5
    static let maximumRequestTimeout: TimeInterval = 45
    static let defaultRequestTimeout: TimeInterval = 20
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumRedirects = 3
    static let minimumFullResearchContextTokens = 65_536
    static let maximumTitleCharacters = 500
    static let maximumSearchExcerptCharacters = 4_000
    static let maximumFetchExcerptCharacters = 12_000
}

enum OllamaWebResearchFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case providerDisabled = "ollama_web_provider_disabled"
    case chatDisabled = "ollama_web_chat_disabled"
    case disclosureRequired = "ollama_web_first_use_disclosure_required"
    case previewRequired = "ollama_web_query_preview_required"
    case previewMismatch = "ollama_web_query_preview_mismatch"
    case privateInputApprovalRequired = "ollama_web_private_input_approval_required"
    case evidenceFollowUpApprovalRequired = "ollama_web_evidence_follow_up_approval_required"
    case credentialMissing = "ollama_web_credential_missing"
    case credentialInvalid = "ollama_web_credential_invalid"
    case credentialUnavailable = "ollama_web_credential_unavailable"
    case credentialNamespaceRejected = "ollama_web_credential_namespace_rejected"
    case credentialStorageFailed = "ollama_web_credential_storage_failed"
    case credentialReadFailed = "ollama_web_credential_read_failed"
    case credentialDeleteFailed = "ollama_web_credential_delete_failed"
    case credentialEntitlementMissing = "ollama_web_credential_entitlement_missing"
    case credentialInteractionNotAllowed = "ollama_web_credential_interaction_not_allowed"
    case invalidRequest = "ollama_web_invalid_request"
    case invalidURL = "ollama_web_invalid_url"
    case forbiddenScheme = "ollama_web_forbidden_scheme"
    case credentialsInURLRejected = "ollama_web_url_credentials_rejected"
    case localHostRejected = "ollama_web_local_host_rejected"
    case ipLiteralRejected = "ollama_web_ip_literal_rejected"
    case nonPublicAddress = "ollama_web_non_public_address"
    case dnsResolutionFailed = "ollama_web_dns_resolution_failed"
    case dnsAddressLimitExceeded = "ollama_web_dns_address_limit_exceeded"
    case contextModeLimitExceeded = "ollama_web_context_mode_limit_exceeded"
    case toolLoopLimitExceeded = "ollama_web_tool_loop_limit_exceeded"
    case fetchLimitExceeded = "ollama_web_fetch_limit_exceeded"
    case redirectRejected = "ollama_web_redirect_rejected"
    case redirectLimitExceeded = "ollama_web_redirect_limit_exceeded"
    case authenticationChallengeRejected = "ollama_web_authentication_challenge_rejected"
    case responseTooLarge = "ollama_web_response_too_large"
    case requestTimedOut = "ollama_web_request_timed_out"
    case requestCancelled = "ollama_web_request_cancelled"
    case transportUnavailable = "ollama_web_transport_unavailable"
    case httpFailure = "ollama_web_http_failure"
    case invalidResponse = "ollama_web_invalid_response"
    case citationEvidenceMissing = "ollama_web_citation_evidence_missing"
}

struct OllamaWebResearchFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: OllamaWebResearchFailureCode
    let httpStatus: Int?

    init(_ code: OllamaWebResearchFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .providerDisabled:
            "Web Research is disabled globally."
        case .chatDisabled:
            "Web Research is disabled for this chat."
        case .disclosureRequired:
            "Accept the external-network disclosure before using Web Research."
        case .previewRequired:
            "Review and approve the visible web request preview."
        case .previewMismatch:
            "The approved web request preview does not match the normalized request."
        case .privateInputApprovalRequired:
            "Explicit operator approval is required before private data enters a web query."
        case .evidenceFollowUpApprovalRequired:
            "Untrusted web evidence cannot authorize another network call."
        case .credentialMissing:
            "An Agent Loki Web Research API key is required."
        case .credentialInvalid:
            "The Agent Loki Web Research API key is invalid."
        case .credentialUnavailable:
            "The Agent Loki Web Research credential store is unavailable."
        case .credentialNamespaceRejected:
            "The Web Research credential namespace is invalid."
        case .credentialStorageFailed:
            "The Web Research API key could not be stored."
        case .credentialReadFailed:
            "The Web Research API key could not be read."
        case .credentialDeleteFailed:
            "The Web Research API key could not be deleted."
        case .credentialEntitlementMissing:
            "The app is not entitled to the Data Protection Keychain."
        case .credentialInteractionNotAllowed:
            "Data Protection Keychain access is not currently permitted."
        case .invalidRequest:
            "The bounded Web Research request is invalid."
        case .invalidURL:
            "Enter a valid public HTTPS URL."
        case .forbiddenScheme:
            "Only public HTTPS URLs are permitted."
        case .credentialsInURLRejected:
            "Credential-bearing URLs are not permitted."
        case .localHostRejected:
            "Local and private hostnames are not permitted."
        case .ipLiteralRejected:
            "IP-literal web targets are not permitted."
        case .nonPublicAddress:
            "The web target resolved to a non-public address."
        case .dnsResolutionFailed:
            "The web target could not be resolved safely."
        case .dnsAddressLimitExceeded:
            "The web target returned too many addresses to validate safely."
        case .contextModeLimitExceeded:
            "The request exceeds the active research context mode."
        case .toolLoopLimitExceeded:
            "The bounded Web Research tool-loop limit was reached."
        case .fetchLimitExceeded:
            "The bounded Web Research fetch limit was reached."
        case .redirectRejected:
            "The Web Research provider attempted an unsafe redirect."
        case .redirectLimitExceeded:
            "The Web Research provider exceeded its redirect limit."
        case .authenticationChallengeRejected:
            "The Web Research request encountered an unexpected credential challenge."
        case .responseTooLarge:
            "The Web Research response exceeded its byte limit."
        case .requestTimedOut:
            "The Web Research request timed out."
        case .requestCancelled:
            "The Web Research request was cancelled."
        case .transportUnavailable:
            "The Web Research provider is unavailable."
        case .httpFailure:
            "The Web Research provider returned an unsuccessful response."
        case .invalidResponse:
            "The Web Research provider returned an invalid response."
        case .citationEvidenceMissing:
            "A claim citation referenced unavailable web evidence."
        }
    }
}

enum OllamaWebResearchOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case search = "web_search"
    case fetch = "web_fetch"
}

enum OllamaWebResearchInputClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case operatorAuthored = "operator_authored"
    case publicContext = "public_context"
    case privateRecord = "private_record"
    case untrustedWebEvidence = "untrusted_web_evidence"
}

struct OllamaWebResearchAuthorization: Hashable, Sendable {
    let globalProviderEnabled: Bool
    let chatWebResearchEnabled: Bool
    let externalNetworkDisclosureAccepted: Bool
    let queryPreviewApproved: Bool
    let previewedInput: String?
    let privateRecordUseApproved: Bool
    let evidenceFollowUpApproved: Bool

    init(
        globalProviderEnabled: Bool = false,
        chatWebResearchEnabled: Bool = false,
        externalNetworkDisclosureAccepted: Bool = false,
        queryPreviewApproved: Bool = false,
        previewedInput: String? = nil,
        privateRecordUseApproved: Bool = false,
        evidenceFollowUpApproved: Bool = false
    ) {
        self.globalProviderEnabled = globalProviderEnabled
        self.chatWebResearchEnabled = chatWebResearchEnabled
        self.externalNetworkDisclosureAccepted = externalNetworkDisclosureAccepted
        self.queryPreviewApproved = queryPreviewApproved
        self.previewedInput = previewedInput
        self.privateRecordUseApproved = privateRecordUseApproved
        self.evidenceFollowUpApproved = evidenceFollowUpApproved
    }
}

enum OllamaWebResearchContextMode: String, Codable, CaseIterable, Hashable, Sendable {
    case full
    case limited

    init(effectiveContextTokens: Int) {
        self = effectiveContextTokens >= OllamaWebResearchLimits.minimumFullResearchContextTokens
            ? .full
            : .limited
    }

    var maximumSearchResults: Int {
        switch self {
        case .full: OllamaWebResearchLimits.maximumSearchResults
        case .limited: 3
        }
    }

    var maximumToolLoops: Int {
        switch self {
        case .full: 6
        case .limited: 3
        }
    }

    var maximumFetchCount: Int {
        switch self {
        case .full: 4
        case .limited: 2
        }
    }

    var userVisibleBoundsDescription: String {
        "\(maximumSearchResults) search results, \(maximumFetchCount) fetches, \(maximumToolLoops) tool loops"
    }

    var maximumResponseBytes: Int {
        switch self {
        case .full: OllamaWebResearchLimits.maximumResponseBytes
        case .limited: 512 * 1_024
        }
    }

    var maximumSearchExcerptCharacters: Int {
        switch self {
        case .full: OllamaWebResearchLimits.maximumSearchExcerptCharacters
        case .limited: 1_500
        }
    }

    var maximumFetchExcerptCharacters: Int {
        switch self {
        case .full: OllamaWebResearchLimits.maximumFetchExcerptCharacters
        case .limited: 4_000
        }
    }
}

actor OllamaWebResearchToolSession {
    nonisolated let id: UUID
    nonisolated let contextMode: OllamaWebResearchContextMode

    private var toolLoopCount = 0
    private var fetchCount = 0

    init(
        id: UUID = UUID(),
        effectiveContextTokens: Int
    ) {
        self.id = id
        contextMode = .init(effectiveContextTokens: effectiveContextTokens)
    }

    func admit(
        _ operation: OllamaWebResearchOperation,
        requestedSearchResults: Int? = nil
    ) throws -> Int {
        guard toolLoopCount < contextMode.maximumToolLoops else {
            throw OllamaWebResearchFailure(.toolLoopLimitExceeded)
        }
        if operation == .search,
           let requestedSearchResults,
           requestedSearchResults > contextMode.maximumSearchResults
        {
            throw OllamaWebResearchFailure(.contextModeLimitExceeded)
        }
        if operation == .fetch {
            guard fetchCount < contextMode.maximumFetchCount else {
                throw OllamaWebResearchFailure(.fetchLimitExceeded)
            }
            fetchCount += 1
        }
        toolLoopCount += 1
        return toolLoopCount
    }

    func snapshot() -> (toolLoopCount: Int, fetchCount: Int) {
        (toolLoopCount, fetchCount)
    }
}

enum OllamaWebResearchCredentialNamespace {
    static let service = "com.agentloki.LokiBrief.ollama.web-research.v1"
    static let account = "agent-loki-web-research-api-key"
}

protocol OllamaWebResearchCredentialStoring: Sendable {
    func storeAPIKey(_ apiKey: String, service: String, account: String) async throws
    func readAPIKey(service: String, account: String) async throws -> String?
    func deleteAPIKey(service: String, account: String) async throws
}

extension OllamaWebResearchCredentialStoring {
    func storeAgentLokiAPIKey(_ apiKey: String) async throws {
        try await storeAPIKey(
            apiKey,
            service: OllamaWebResearchCredentialNamespace.service,
            account: OllamaWebResearchCredentialNamespace.account
        )
    }

    func readAgentLokiAPIKey() async throws -> String? {
        try await readAPIKey(
            service: OllamaWebResearchCredentialNamespace.service,
            account: OllamaWebResearchCredentialNamespace.account
        )
    }

    func deleteAgentLokiAPIKey() async throws {
        try await deleteAPIKey(
            service: OllamaWebResearchCredentialNamespace.service,
            account: OllamaWebResearchCredentialNamespace.account
        )
    }
}

private struct OllamaWebResearchAPIKey: Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard (16...4_096).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw OllamaWebResearchFailure(.credentialInvalid)
        }
        self.rawValue = rawValue
    }
}

actor VolatileOllamaWebResearchCredentialStore:
    OllamaWebResearchCredentialStoring
{
    private var apiKey: String?

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        try validateNamespace(service: service, account: account)
        self.apiKey = try OllamaWebResearchAPIKey(apiKey).rawValue
    }

    func readAPIKey(service: String, account: String) async throws -> String? {
        try validateNamespace(service: service, account: account)
        return apiKey
    }

    func deleteAPIKey(service: String, account: String) async throws {
        try validateNamespace(service: service, account: account)
        apiKey = nil
    }

    private func validateNamespace(
        service: String,
        account: String
    ) throws {
        guard service == OllamaWebResearchCredentialNamespace.service,
              account == OllamaWebResearchCredentialNamespace.account
        else {
            throw OllamaWebResearchFailure(.credentialNamespaceRejected)
        }
    }
}

actor SecurityOllamaWebResearchCredentialStore: OllamaWebResearchCredentialStoring {
    static let maximumAPIKeyBytes = 4_096

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        try validateNamespace(service: service, account: account)
        let key = try OllamaWebResearchAPIKey(apiKey)
        let data = Data(key.rawValue.utf8)
        guard data.count <= Self.maximumAPIKeyBytes else {
            throw OllamaWebResearchFailure(.credentialInvalid)
        }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainFailure(
                status: updateStatus,
                operation: .credentialStorageFailed
            )
        }

        var createQuery = query
        createQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        createQuery[kSecValueData as String] = data
        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        if createStatus == errSecSuccess {
            return
        }
        if createStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw keychainFailure(
                    status: retryStatus,
                    operation: .credentialStorageFailed
                )
            }
            return
        }
        throw keychainFailure(
            status: createStatus,
            operation: .credentialStorageFailed
        )
    }

    func readAPIKey(service: String, account: String) async throws -> String? {
        try validateNamespace(service: service, account: account)
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainFailure(
                status: status,
                operation: .credentialReadFailed
            )
        }
        guard let data = result as? Data,
              data.count <= Self.maximumAPIKeyBytes,
              let rawValue = String(data: data, encoding: .utf8),
              Data(rawValue.utf8) == data
        else {
            throw OllamaWebResearchFailure(.credentialInvalid)
        }
        return try OllamaWebResearchAPIKey(rawValue).rawValue
    }

    func deleteAPIKey(service: String, account: String) async throws {
        try validateNamespace(service: service, account: account)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainFailure(
                status: status,
                operation: .credentialDeleteFailed
            )
        }
    }

    private func validateNamespace(service: String, account: String) throws {
        guard service == OllamaWebResearchCredentialNamespace.service,
              account == OllamaWebResearchCredentialNamespace.account
        else {
            throw OllamaWebResearchFailure(.credentialNamespaceRejected)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OllamaWebResearchCredentialNamespace.service,
            kSecAttrAccount as String: OllamaWebResearchCredentialNamespace.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    private func keychainFailure(
        status: OSStatus,
        operation: OllamaWebResearchFailureCode
    ) -> OllamaWebResearchFailure {
        switch status {
        case errSecMissingEntitlement:
            return .init(.credentialEntitlementMissing)
        case errSecInteractionNotAllowed:
            return .init(.credentialInteractionNotAllowed)
        case errSecNotAvailable:
            return .init(.credentialUnavailable)
        default:
            return .init(operation)
        }
    }
}

enum OllamaWebResearchResolvedAddress: Hashable, Sendable {
    case ipv4(UInt8, UInt8, UInt8, UInt8)
    case ipv6([UInt8])
}

protocol OllamaWebResearchHostResolving: Sendable {
    func resolve(host: String) async throws -> [OllamaWebResearchResolvedAddress]
}

struct SystemOllamaWebResearchHostResolver: OllamaWebResearchHostResolving {
    func resolve(host: String) async throws -> [OllamaWebResearchResolvedAddress] {
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
                throw OllamaWebResearchFailure(.dnsResolutionFailed)
            }
            defer { freeaddrinfo(first) }

            var addresses: Set<OllamaWebResearchResolvedAddress> = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor?.pointee {
                if info.ai_family == AF_INET, let raw = info.ai_addr {
                    let value = raw.withMemoryRebound(
                        to: sockaddr_in.self,
                        capacity: 1
                    ) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                    }
                    addresses.insert(.ipv4(
                        UInt8((value >> 24) & 0xff),
                        UInt8((value >> 16) & 0xff),
                        UInt8((value >> 8) & 0xff),
                        UInt8(value & 0xff)
                    ))
                } else if info.ai_family == AF_INET6, let raw = info.ai_addr {
                    var address = raw.withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) {
                        $0.pointee.sin6_addr
                    }
                    addresses.insert(.ipv6(withUnsafeBytes(of: &address) { Array($0) }))
                }
                guard addresses.count <= OllamaWebResearchLimits.maximumResolvedAddresses else {
                    throw OllamaWebResearchFailure(.dnsAddressLimitExceeded)
                }
                cursor = info.ai_next
            }
            guard !addresses.isEmpty else {
                throw OllamaWebResearchFailure(.dnsResolutionFailed)
            }
            return addresses.sorted { $0.sortKey < $1.sortKey }
        }.value
    }
}

struct OllamaWebResearchValidatedURL: Hashable, Sendable {
    let url: URL
    let resolvedAddresses: [OllamaWebResearchResolvedAddress]
}

struct OllamaWebResearchURLPolicy: Sendable {
    let resolver: any OllamaWebResearchHostResolving
    let resolutionTimeout: TimeInterval

    init(
        resolver: any OllamaWebResearchHostResolving = SystemOllamaWebResearchHostResolver(),
        resolutionTimeout: TimeInterval = OllamaWebResearchLimits.minimumRequestTimeout
    ) {
        self.resolver = resolver
        self.resolutionTimeout = max(
            1,
            min(resolutionTimeout, OllamaWebResearchLimits.maximumRequestTimeout)
        )
    }

    func normalize(_ input: URL) throws -> URL {
        guard input.absoluteString.count <= OllamaWebResearchLimits.maximumURLCharacters,
              var components = URLComponents(url: input, resolvingAgainstBaseURL: false)
        else {
            throw OllamaWebResearchFailure(.invalidURL)
        }
        guard components.scheme?.lowercased() == "https" else {
            throw OllamaWebResearchFailure(.forbiddenScheme)
        }
        guard components.user == nil, components.password == nil else {
            throw OllamaWebResearchFailure(.credentialsInURLRejected)
        }
        guard var host = components.host?.lowercased(), !host.isEmpty else {
            throw OllamaWebResearchFailure(.invalidURL)
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard Self.parseLiteral(host) == nil, !Self.looksNumeric(host) else {
            throw OllamaWebResearchFailure(.ipLiteralRejected)
        }
        guard !host.isEmpty,
              !host.contains("%"),
              host.utf8.allSatisfy({
                  $0.isASCIIAlphaNumeric || $0 == 0x2D || $0 == 0x2E
              }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: {
                  $0.isEmpty || $0.count > 63 || $0.first == "-" || $0.last == "-"
              })
        else {
            throw OllamaWebResearchFailure(.invalidURL)
        }
        let exactLocalNames = Set([
            "localhost",
            "localhost.localdomain",
            "ip6-localhost",
            "broadcasthost",
        ])
        let localSuffixes = [
            ".localhost",
            ".local",
            ".localdomain",
            ".internal",
            ".lan",
            ".home",
        ]
        guard !exactLocalNames.contains(host),
              !localSuffixes.contains(where: host.hasSuffix)
        else {
            throw OllamaWebResearchFailure(.localHostRejected)
        }
        guard components.port == nil || components.port == 443 else {
            throw OllamaWebResearchFailure(.invalidURL)
        }

        components.scheme = "https"
        components.host = host
        components.port = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let normalized = components.url,
              normalized.absoluteString.count <= OllamaWebResearchLimits.maximumURLCharacters
        else {
            throw OllamaWebResearchFailure(.invalidURL)
        }
        return normalized
    }

    func validate(_ input: URL) async throws -> OllamaWebResearchValidatedURL {
        guard !Task.isCancelled else {
            throw OllamaWebResearchFailure(.requestCancelled)
        }
        let normalized = try normalize(input)
        guard let host = normalized.host else {
            throw OllamaWebResearchFailure(.invalidURL)
        }
        let addresses: [OllamaWebResearchResolvedAddress]
        do {
            addresses = try await OllamaWebResearchResolutionAttempt(
                resolver: resolver,
                host: host,
                timeout: resolutionTimeout
            ).run()
        } catch is CancellationError {
            throw OllamaWebResearchFailure(.requestCancelled)
        } catch let failure as OllamaWebResearchFailure {
            throw failure
        } catch {
            throw OllamaWebResearchFailure(.dnsResolutionFailed)
        }
        guard !Task.isCancelled else {
            throw OllamaWebResearchFailure(.requestCancelled)
        }
        guard addresses.count <= OllamaWebResearchLimits.maximumResolvedAddresses else {
            throw OllamaWebResearchFailure(.dnsAddressLimitExceeded)
        }
        guard !addresses.isEmpty, addresses.allSatisfy(Self.isPublic) else {
            throw OllamaWebResearchFailure(.nonPublicAddress)
        }
        return .init(
            url: normalized,
            resolvedAddresses: Array(Set(addresses)).sorted { $0.sortKey < $1.sortKey }
        )
    }

    static func isPublic(_ address: OllamaWebResearchResolvedAddress) -> Bool {
        switch address {
        case let .ipv4(a, b, c, _):
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && ((b == 0 && c == 0) || b == 168) { return false }
            if a == 192 && b == 0 && c == 2 { return false }
            if a == 192 && b == 88 && c == 99 { return false }
            if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) {
                return false
            }
            if a == 203 && b == 0 && c == 113 { return false }
            return true
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
                return false
            }
            if bytes[0] & 0xfe == 0xfc { return false }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return false }
            if bytes[0] == 0xff { return false }
            if bytes[0] == 0x00 && bytes[1] == 0x64
                && bytes[2] == 0xff && bytes[3] == 0x9b
            {
                return false
            }
            if bytes[0] == 0x01 && bytes[1..<8].allSatisfy({ $0 == 0 }) {
                return false
            }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] & 0xfe == 0 {
                return false
            }
            if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x01
                && bytes[2] == 0x0d && bytes[3] == 0xb8
            {
                return false
            }
            if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 {
                return false
            }
            if bytes[0..<10].allSatisfy({ $0 == 0 }),
               bytes[10] == 0xff,
               bytes[11] == 0xff
            {
                return isPublic(.ipv4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return bytes[0] & 0xe0 == 0x20
        }
    }

    private static func parseLiteral(_ host: String) -> OllamaWebResearchResolvedAddress? {
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
            return .ipv6(withUnsafeBytes(of: &ipv6) { Array($0) })
        }
        return nil
    }

    private static func looksNumeric(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasPrefix("0x") { return true }
        return !lowered.isEmpty
            && lowered.allSatisfy { $0.isNumber || $0 == "." || $0 == "x" }
    }
}

private final class OllamaWebResearchResolutionAttempt: @unchecked Sendable {
    private typealias ResolutionResult = Result<
        [OllamaWebResearchResolvedAddress],
        Error
    >

    private let resolver: any OllamaWebResearchHostResolving
    private let host: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        [OllamaWebResearchResolvedAddress],
        Error
    >?
    private var completedResult: ResolutionResult?
    private var resolutionTask: Task<Void, Never>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        resolver: any OllamaWebResearchHostResolving,
        host: String,
        timeout: TimeInterval
    ) {
        self.resolver = resolver
        self.host = host
        self.timeout = timeout
    }

    func run() async throws -> [OllamaWebResearchResolvedAddress] {
        try await withTaskCancellationHandler {
            start()
            return try await withCheckedThrowingContinuation { install($0) }
        } onCancel: {
            finish(.failure(OllamaWebResearchFailure(.requestCancelled)))
        }
    }

    private func start() {
        lock.lock()
        guard resolutionTask == nil, completedResult == nil else {
            lock.unlock()
            return
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(OllamaWebResearchFailure(.requestTimedOut)))
        }
        self.timeoutWorkItem = timeoutWorkItem
        let task = Task { [resolver, host] in
            do {
                let addresses = try await resolver.resolve(host: host)
                self.finish(.success(addresses))
            } catch is CancellationError {
                self.finish(.failure(OllamaWebResearchFailure(.requestCancelled)))
            } catch {
                self.finish(.failure(error))
            }
        }
        resolutionTask = task
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
    }

    private func install(
        _ newContinuation: CheckedContinuation<
            [OllamaWebResearchResolvedAddress],
            Error
        >
    ) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            newContinuation.resume(with: completedResult)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    private func finish(_ result: ResolutionResult) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        let task = resolutionTask
        resolutionTask = nil
        let timeoutWorkItem = timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        task?.cancel()
        continuation?.resume(with: result)
    }
}

private extension OllamaWebResearchResolvedAddress {
    var sortKey: String {
        switch self {
        case let .ipv4(a, b, c, d):
            return String(format: "4-%03d-%03d-%03d-%03d", a, b, c, d)
        case let .ipv6(bytes):
            return "6-" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}

struct OllamaWebResearchTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL
    let redirectCount: Int
}

protocol OllamaWebResearchTransporting: Sendable {
    func data(
        for request: URLRequest,
        operation: OllamaWebResearchOperation,
        requestID: UUID,
        responseByteLimit: Int,
        timeout: TimeInterval,
        redirectLimit: Int
    ) async throws -> OllamaWebResearchTransportResponse

    func cancel(requestID: UUID) async
}

enum OllamaWebResearchEndpointPolicy {
    static let searchURL = URL(string: "https://ollama.com/api/web_search")!
    static let fetchURL = URL(string: "https://ollama.com/api/web_fetch")!

    static func url(for operation: OllamaWebResearchOperation) -> URL {
        switch operation {
        case .search: searchURL
        case .fetch: fetchURL
        }
    }

    static func validate(
        _ request: URLRequest,
        operation: OllamaWebResearchOperation
    ) throws {
        guard request.url == url(for: operation),
              request.httpMethod == "POST",
              request.httpBody != nil,
              request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Content-Type") == "application/json",
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "),
              authorization.count > "Bearer ".count,
              !authorization.contains("\r"),
              !authorization.contains("\n")
        else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
    }

    static func validateResponseURL(
        _ url: URL,
        operation: OllamaWebResearchOperation
    ) throws {
        guard url == self.url(for: operation) else {
            throw OllamaWebResearchFailure(.redirectRejected)
        }
    }
}

final class BoundedOllamaWebResearchTransport:
    NSObject,
    OllamaWebResearchTransporting,
    @unchecked Sendable
{
    private final class TaskState {
        let requestID: UUID
        let operation: OllamaWebResearchOperation
        let responseByteLimit: Int
        let redirectLimit: Int
        let continuation: CheckedContinuation<OllamaWebResearchTransportResponse, Error>
        var data = Data()
        var statusCode: Int?
        var finalURL: URL?
        var redirectCount = 0
        var terminalFailure: OllamaWebResearchFailure?

        init(
            requestID: UUID,
            operation: OllamaWebResearchOperation,
            responseByteLimit: Int,
            redirectLimit: Int,
            continuation: CheckedContinuation<OllamaWebResearchTransportResponse, Error>
        ) {
            self.requestID = requestID
            self.operation = operation
            self.responseByteLimit = responseByteLimit
            self.redirectLimit = redirectLimit
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var session: URLSession!
    private var statesByTaskID: [Int: TaskState] = [:]
    private var tasksByRequestID: [UUID: URLSessionTask] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = OllamaWebResearchLimits.maximumRequestTimeout
        configuration.timeoutIntervalForResource = OllamaWebResearchLimits.maximumRequestTimeout
        configuration.httpMaximumConnectionsPerHost = 2

        let queue = OperationQueue()
        queue.name = "com.agentloki.LokiBrief.ollama-web-research.transport"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(
        for request: URLRequest,
        operation: OllamaWebResearchOperation,
        requestID: UUID,
        responseByteLimit: Int,
        timeout: TimeInterval,
        redirectLimit: Int
    ) async throws -> OllamaWebResearchTransportResponse {
        try OllamaWebResearchEndpointPolicy.validate(request, operation: operation)
        guard responseByteLimit > 0,
              responseByteLimit <= OllamaWebResearchLimits.maximumResponseBytes
        else {
            throw OllamaWebResearchFailure(.responseTooLarge)
        }
        guard timeout.isFinite,
              timeout >= OllamaWebResearchLimits.minimumRequestTimeout,
              timeout <= OllamaWebResearchLimits.maximumRequestTimeout
        else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
        guard (0...OllamaWebResearchLimits.maximumRedirects).contains(redirectLimit) else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
        guard !Task.isCancelled else {
            throw OllamaWebResearchFailure(.requestCancelled)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var timedRequest = request
                timedRequest.timeoutInterval = timeout
                let task = session.dataTask(with: timedRequest)
                let state = TaskState(
                    requestID: requestID,
                    operation: operation,
                    responseByteLimit: responseByteLimit,
                    redirectLimit: redirectLimit,
                    continuation: continuation
                )
                lock.lock()
                let duplicate = tasksByRequestID[requestID] != nil
                let preCancelled = cancelledBeforeRegistration.remove(requestID) != nil
                if !duplicate {
                    statesByTaskID[task.taskIdentifier] = state
                    tasksByRequestID[requestID] = task
                }
                lock.unlock()
                if duplicate {
                    continuation.resume(throwing: OllamaWebResearchFailure(.invalidRequest))
                } else if preCancelled || Task.isCancelled {
                    lock.lock()
                    statesByTaskID.removeValue(forKey: task.taskIdentifier)
                    tasksByRequestID.removeValue(forKey: requestID)
                    cancelledBeforeRegistration.remove(requestID)
                    lock.unlock()
                    task.cancel()
                    continuation.resume(
                        throwing: OllamaWebResearchFailure(.requestCancelled)
                    )
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            cancelNow(requestID: requestID)
        }
    }

    func cancel(requestID: UUID) async {
        cancelNow(requestID: requestID)
    }

    private func cancelNow(requestID: UUID) {
        lock.lock()
        let task = tasksByRequestID[requestID]
        if let task {
            statesByTaskID[task.taskIdentifier]?.terminalFailure = .init(.requestCancelled)
        } else {
            cancelledBeforeRegistration.insert(requestID)
        }
        lock.unlock()
        task?.cancel()
    }

    private func setTerminalFailure(
        _ failure: OllamaWebResearchFailure,
        for task: URLSessionTask
    ) {
        lock.lock()
        statesByTaskID[task.taskIdentifier]?.terminalFailure = failure
        lock.unlock()
    }

    private func complete(_ task: URLSessionTask, networkError: Error?) {
        lock.lock()
        guard let state = statesByTaskID.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        tasksByRequestID.removeValue(forKey: state.requestID)
        cancelledBeforeRegistration.remove(state.requestID)
        let failure = state.terminalFailure
        let data = state.data
        let statusCode = state.statusCode
        let finalURL = state.finalURL
        let redirectCount = state.redirectCount
        lock.unlock()

        if let failure {
            state.continuation.resume(throwing: failure)
        } else if let networkError {
            state.continuation.resume(throwing: Self.map(networkError))
        } else if let statusCode, let finalURL {
            state.continuation.resume(returning: .init(
                data: data,
                statusCode: statusCode,
                finalURL: finalURL,
                redirectCount: redirectCount
            ))
        } else {
            state.continuation.resume(throwing: OllamaWebResearchFailure(.invalidResponse))
        }
    }

    private static func map(_ error: Error) -> OllamaWebResearchFailure {
        if let failure = error as? OllamaWebResearchFailure {
            return failure
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .init(.requestCancelled)
            case .timedOut:
                return .init(.requestTimedOut)
            default:
                return .init(.transportUnavailable)
            }
        }
        if error is CancellationError {
            return .init(.requestCancelled)
        }
        return .init(.transportUnavailable)
    }
}

extension BoundedOllamaWebResearchTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let finalURL = response.url,
              http.value(forHTTPHeaderField: "Content-Type")?
                  .lowercased()
                  .hasPrefix("application/json") == true
        else {
            setTerminalFailure(.init(.invalidResponse), for: dataTask)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let state = statesByTaskID[dataTask.taskIdentifier]
        let declaredLength = response.expectedContentLength
        let tooLarge = declaredLength >= 0
            && declaredLength > Int64(state?.responseByteLimit ?? 0)
        if tooLarge {
            state?.terminalFailure = .init(.responseTooLarge)
        } else {
            state?.statusCode = http.statusCode
            state?.finalURL = finalURL
        }
        lock.unlock()
        completionHandler(state != nil && !tooLarge ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard let state = statesByTaskID[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        guard data.count <= state.responseByteLimit,
              state.data.count <= state.responseByteLimit - data.count
        else {
            state.terminalFailure = .init(.responseTooLarge)
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        guard let state = statesByTaskID[task.taskIdentifier] else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        state.redirectCount += 1
        let overLimit = state.redirectCount > state.redirectLimit
        let operation = state.operation
        lock.unlock()

        do {
            guard !overLimit, response.statusCode == 307 || response.statusCode == 308 else {
                throw OllamaWebResearchFailure(
                    overLimit ? .redirectLimitExceeded : .redirectRejected
                )
            }
            try OllamaWebResearchEndpointPolicy.validate(request, operation: operation)
            completionHandler(request)
        } catch let failure as OllamaWebResearchFailure {
            setTerminalFailure(failure, for: task)
            completionHandler(nil)
        } catch {
            setTerminalFailure(.init(.redirectRejected), for: task)
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            setTerminalFailure(.init(.authenticationChallengeRejected), for: task)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        complete(task, networkError: error)
    }
}

struct OllamaWebSearchRequest: Hashable, Sendable {
    let id: UUID
    let query: String
    let maximumResults: Int
    let inputClassification: OllamaWebResearchInputClassification
    let timeout: TimeInterval

    init(
        id: UUID = UUID(),
        query: String,
        maximumResults: Int = 5,
        inputClassification: OllamaWebResearchInputClassification = .operatorAuthored,
        timeout: TimeInterval = OllamaWebResearchLimits.defaultRequestTimeout
    ) {
        self.id = id
        self.query = query
        self.maximumResults = maximumResults
        self.inputClassification = inputClassification
        self.timeout = timeout
    }
}

struct OllamaWebFetchRequest: Hashable, Sendable {
    let id: UUID
    let url: URL
    let inputClassification: OllamaWebResearchInputClassification
    let timeout: TimeInterval

    init(
        id: UUID = UUID(),
        url: URL,
        inputClassification: OllamaWebResearchInputClassification = .operatorAuthored,
        timeout: TimeInterval = OllamaWebResearchLimits.defaultRequestTimeout
    ) {
        self.id = id
        self.url = url
        self.inputClassification = inputClassification
        self.timeout = timeout
    }
}

enum OllamaWebResearchPreviewNormalizer {
    static func query(_ query: String) throws -> String {
        let normalized = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.count <= OllamaWebResearchLimits.maximumQueryCharacters,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
        return normalized
    }

    static func fetchURL(_ url: URL) throws -> URL {
        try OllamaWebResearchURLPolicy().normalize(url)
    }
}

enum OllamaWebEvidenceAuthority: String, Codable, Hashable, Sendable {
    case untrustedExternalEvidence = "untrusted_external_evidence"
}

struct OllamaWebEvidencePermissions: Codable, Hashable, Sendable {
    let canModifySystemPolicy: Bool
    let canModifyToolPermissions: Bool
    let canAuthorizeNetworkRequests: Bool
    let canRequestCredentials: Bool
    let canTriggerFileOrShellOperations: Bool

    static let none = OllamaWebEvidencePermissions(
        canModifySystemPolicy: false,
        canModifyToolPermissions: false,
        canAuthorizeNetworkRequests: false,
        canRequestCredentials: false,
        canTriggerFileOrShellOperations: false
    )
}

struct OllamaWebResearchProvenance: Codable, Hashable, Sendable {
    let title: String
    let sourceURL: URL
    let retrievedAt: Date
    let toolReceiptID: String
    let evidenceID: String
}

struct OllamaWebResearchEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let excerpt: String
    let wasExcerptTruncated: Bool
    let authority: OllamaWebEvidenceAuthority
    let permissions: OllamaWebEvidencePermissions
    let provenance: OllamaWebResearchProvenance
}

struct OllamaWebResearchToolReceipt: Codable, Hashable, Sendable {
    let id: String
    let requestID: UUID
    let sessionID: UUID
    let operation: OllamaWebResearchOperation
    let inputDigest: String
    let startedAt: Date
    let completedAt: Date
    let contextMode: OllamaWebResearchContextMode
    let toolLoopIndex: Int
    let responseByteCount: Int
    let redirectCount: Int
    let evidenceIDs: [String]
    let omittedEvidenceCount: Int
}

struct OllamaWebSearchResponse: Codable, Hashable, Sendable {
    let evidence: [OllamaWebResearchEvidence]
    let receipt: OllamaWebResearchToolReceipt
    let wasLimited: Bool
}

struct OllamaWebFetchResponse: Codable, Hashable, Sendable {
    let evidence: OllamaWebResearchEvidence
    let receipt: OllamaWebResearchToolReceipt
    let wasLimited: Bool
}

struct OllamaWebResearchClaimCitation: Codable, Hashable, Sendable {
    let claimID: String
    let evidenceIDs: [String]

    static func validated(
        claimID: String,
        evidenceIDs: [String],
        availableEvidence: [OllamaWebResearchEvidence]
    ) throws -> OllamaWebResearchClaimCitation {
        let normalizedClaimID = OllamaWebResearchTextPolicy.classification(
            claimID,
            maximumCharacters: 256
        )
        guard !normalizedClaimID.isEmpty, !evidenceIDs.isEmpty else {
            throw OllamaWebResearchFailure(.citationEvidenceMissing)
        }
        let available = Set(availableEvidence.map(\.id))
        let normalizedEvidenceIDs = Array(Set(evidenceIDs)).sorted()
        guard normalizedEvidenceIDs.allSatisfy(available.contains) else {
            throw OllamaWebResearchFailure(.citationEvidenceMissing)
        }
        return .init(claimID: normalizedClaimID, evidenceIDs: normalizedEvidenceIDs)
    }
}

actor OllamaWebResearchProvider {
    private struct SearchBody: Encodable {
        let query: String
        let maximumResults: Int

        enum CodingKeys: String, CodingKey {
            case query
            case maximumResults = "max_results"
        }
    }

    private struct FetchBody: Encodable {
        let url: String
    }

    private let credentialStore: any OllamaWebResearchCredentialStoring
    private let urlPolicy: OllamaWebResearchURLPolicy
    private let transport: any OllamaWebResearchTransporting
    private let now: @Sendable () -> Date
    private let receiptID: @Sendable () -> UUID

    init(
        credentialStore: any OllamaWebResearchCredentialStoring,
        resolver: any OllamaWebResearchHostResolving = SystemOllamaWebResearchHostResolver(),
        transport: any OllamaWebResearchTransporting = BoundedOllamaWebResearchTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        receiptID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.credentialStore = credentialStore
        urlPolicy = .init(resolver: resolver)
        self.transport = transport
        self.now = now
        self.receiptID = receiptID
    }

    func search(
        _ request: OllamaWebSearchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebSearchResponse {
        let normalizedQuery = try OllamaWebResearchPreviewNormalizer.query(request.query)
        try Self.validateTimeout(request.timeout)
        guard (1...OllamaWebResearchLimits.maximumSearchResults).contains(
            request.maximumResults
        ) else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
        try Self.authorize(
            normalizedInput: normalizedQuery,
            classification: request.inputClassification,
            authorization: authorization
        )
        let loopIndex = try await session.admit(
            .search,
            requestedSearchResults: request.maximumResults
        )
        let key = try await apiKey()
        _ = try await urlPolicy.validate(OllamaWebResearchEndpointPolicy.searchURL)
        let startedAt = now()
        let body = try Self.encoded(SearchBody(
            query: normalizedQuery,
            maximumResults: request.maximumResults
        ))
        let providerRequest = try Self.providerRequest(
            operation: .search,
            body: body,
            key: key
        )
        let response = try await execute(
            providerRequest,
            operation: .search,
            requestID: request.id,
            timeout: request.timeout,
            contextMode: session.contextMode
        )
        let decoded = try Self.searchPayload(response.data)
        let identifier = receiptID().uuidString.lowercased()
        var evidence: [OllamaWebResearchEvidence] = []
        var omittedCount = max(0, decoded.count - request.maximumResults)
        var anyExcerptTruncated = false

        for item in decoded.prefix(request.maximumResults) {
            guard !Task.isCancelled else {
                throw OllamaWebResearchFailure(.requestCancelled)
            }
            do {
                // A returned search URL is untrusted evidence. Normalize it locally,
                // but do not let it trigger DNS or another network boundary. An
                // explicitly approved fetch performs resolution immediately before
                // dispatch.
                let sourceURL = try urlPolicy.normalize(item.url)
                let boundedTitle = OllamaWebResearchTextPolicy.text(
                    item.title,
                    maximumCharacters: OllamaWebResearchLimits.maximumTitleCharacters
                )
                let boundedExcerpt = OllamaWebResearchTextPolicy.bounded(
                    item.content,
                    maximumCharacters: session.contextMode.maximumSearchExcerptCharacters
                )
                anyExcerptTruncated = anyExcerptTruncated || boundedExcerpt.wasTruncated
                let evidenceID = "\(identifier):\(evidence.count + 1)"
                let provenance = OllamaWebResearchProvenance(
                    title: boundedTitle.isEmpty ? sourceURL.host ?? "Web result" : boundedTitle,
                    sourceURL: sourceURL,
                    retrievedAt: now(),
                    toolReceiptID: identifier,
                    evidenceID: evidenceID
                )
                evidence.append(.init(
                    id: evidenceID,
                    excerpt: boundedExcerpt.text,
                    wasExcerptTruncated: boundedExcerpt.wasTruncated,
                    authority: .untrustedExternalEvidence,
                    permissions: .none,
                    provenance: provenance
                ))
            } catch let failure as OllamaWebResearchFailure
                where failure.code == .requestCancelled
            {
                throw failure
            } catch {
                omittedCount += 1
            }
        }
        let receipt = OllamaWebResearchToolReceipt(
            id: identifier,
            requestID: request.id,
            sessionID: session.id,
            operation: .search,
            inputDigest: OllamaWebResearchPrivacy.digest(normalizedQuery),
            startedAt: startedAt,
            completedAt: now(),
            contextMode: session.contextMode,
            toolLoopIndex: loopIndex,
            responseByteCount: response.data.count,
            redirectCount: response.redirectCount,
            evidenceIDs: evidence.map(\.id),
            omittedEvidenceCount: omittedCount
        )
        return .init(
            evidence: evidence,
            receipt: receipt,
            wasLimited: omittedCount > 0 || anyExcerptTruncated
        )
    }

    func fetch(
        _ request: OllamaWebFetchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebFetchResponse {
        try Self.validateTimeout(request.timeout)
        let normalizedTarget = try urlPolicy.normalize(request.url)
        try Self.authorize(
            normalizedInput: normalizedTarget.absoluteString,
            classification: request.inputClassification,
            authorization: authorization
        )
        let loopIndex = try await session.admit(.fetch)
        let key = try await apiKey()
        let validatedTarget = try await urlPolicy.validate(normalizedTarget)
        _ = try await urlPolicy.validate(OllamaWebResearchEndpointPolicy.fetchURL)
        let startedAt = now()
        let body = try Self.encoded(FetchBody(
            url: validatedTarget.url.absoluteString
        ))
        let providerRequest = try Self.providerRequest(
            operation: .fetch,
            body: body,
            key: key
        )
        let response = try await execute(
            providerRequest,
            operation: .fetch,
            requestID: request.id,
            timeout: request.timeout,
            contextMode: session.contextMode
        )
        let decoded = try Self.fetchPayload(response.data)
        let identifier = receiptID().uuidString.lowercased()
        let title = OllamaWebResearchTextPolicy.text(
            decoded.title ?? validatedTarget.url.host ?? "Fetched page",
            maximumCharacters: OllamaWebResearchLimits.maximumTitleCharacters
        )
        let boundedExcerpt = OllamaWebResearchTextPolicy.bounded(
            decoded.content,
            maximumCharacters: session.contextMode.maximumFetchExcerptCharacters
        )
        let evidenceID = "\(identifier):1"
        let evidence = OllamaWebResearchEvidence(
            id: evidenceID,
            excerpt: boundedExcerpt.text,
            wasExcerptTruncated: boundedExcerpt.wasTruncated,
            authority: .untrustedExternalEvidence,
            permissions: .none,
            provenance: .init(
                title: title,
                sourceURL: validatedTarget.url,
                retrievedAt: now(),
                toolReceiptID: identifier,
                evidenceID: evidenceID
            )
        )
        let receipt = OllamaWebResearchToolReceipt(
            id: identifier,
            requestID: request.id,
            sessionID: session.id,
            operation: .fetch,
            inputDigest: OllamaWebResearchPrivacy.digest(validatedTarget.url.absoluteString),
            startedAt: startedAt,
            completedAt: now(),
            contextMode: session.contextMode,
            toolLoopIndex: loopIndex,
            responseByteCount: response.data.count,
            redirectCount: response.redirectCount,
            evidenceIDs: [evidenceID],
            omittedEvidenceCount: 0
        )
        return .init(
            evidence: evidence,
            receipt: receipt,
            wasLimited: boundedExcerpt.wasTruncated
        )
    }

    func cancel(requestID: UUID) async {
        await transport.cancel(requestID: requestID)
    }

    private func execute(
        _ request: URLRequest,
        operation: OllamaWebResearchOperation,
        requestID: UUID,
        timeout: TimeInterval,
        contextMode: OllamaWebResearchContextMode
    ) async throws -> OllamaWebResearchTransportResponse {
        let response: OllamaWebResearchTransportResponse
        let requestTransport = transport
        do {
            response = try await withTaskCancellationHandler {
                try await requestTransport.data(
                    for: request,
                    operation: operation,
                    requestID: requestID,
                    responseByteLimit: contextMode.maximumResponseBytes,
                    timeout: timeout,
                    redirectLimit: OllamaWebResearchLimits.maximumRedirects
                )
            } onCancel: {
                Task { await requestTransport.cancel(requestID: requestID) }
            }
        } catch let failure as OllamaWebResearchFailure {
            throw failure
        } catch is CancellationError {
            throw OllamaWebResearchFailure(.requestCancelled)
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaWebResearchFailure(.requestTimedOut)
        } catch {
            throw OllamaWebResearchFailure(.transportUnavailable)
        }
        guard response.redirectCount <= OllamaWebResearchLimits.maximumRedirects else {
            throw OllamaWebResearchFailure(.redirectLimitExceeded)
        }
        guard response.data.count <= contextMode.maximumResponseBytes else {
            throw OllamaWebResearchFailure(.responseTooLarge)
        }
        try OllamaWebResearchEndpointPolicy.validateResponseURL(
            response.finalURL,
            operation: operation
        )
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaWebResearchFailure(
                .httpFailure,
                httpStatus: response.statusCode
            )
        }
        return response
    }

    private func apiKey() async throws -> OllamaWebResearchAPIKey {
        do {
            guard let raw = try await credentialStore.readAgentLokiAPIKey() else {
                throw OllamaWebResearchFailure(.credentialMissing)
            }
            return try OllamaWebResearchAPIKey(raw)
        } catch let failure as OllamaWebResearchFailure {
            throw failure
        } catch {
            throw OllamaWebResearchFailure(.credentialUnavailable)
        }
    }

    private static func authorize(
        normalizedInput: String,
        classification: OllamaWebResearchInputClassification,
        authorization: OllamaWebResearchAuthorization
    ) throws {
        guard authorization.globalProviderEnabled else {
            throw OllamaWebResearchFailure(.providerDisabled)
        }
        guard authorization.chatWebResearchEnabled else {
            throw OllamaWebResearchFailure(.chatDisabled)
        }
        guard authorization.externalNetworkDisclosureAccepted else {
            throw OllamaWebResearchFailure(.disclosureRequired)
        }
        guard authorization.queryPreviewApproved,
              let preview = authorization.previewedInput
        else {
            throw OllamaWebResearchFailure(.previewRequired)
        }
        guard preview == normalizedInput else {
            throw OllamaWebResearchFailure(.previewMismatch)
        }
        if classification == .privateRecord,
           !authorization.privateRecordUseApproved
        {
            throw OllamaWebResearchFailure(.privateInputApprovalRequired)
        }
        if classification == .untrustedWebEvidence,
           !authorization.evidenceFollowUpApproved
        {
            throw OllamaWebResearchFailure(.evidenceFollowUpApprovalRequired)
        }
    }

    private static func validateTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite,
              timeout >= OllamaWebResearchLimits.minimumRequestTimeout,
              timeout <= OllamaWebResearchLimits.maximumRequestTimeout
        else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
    }

    private static func providerRequest(
        operation: OllamaWebResearchOperation,
        body: Data,
        key: OllamaWebResearchAPIKey
    ) throws -> URLRequest {
        guard body.count <= 64 * 1_024 else {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
        var request = URLRequest(url: OllamaWebResearchEndpointPolicy.url(for: operation))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(key.rawValue)", forHTTPHeaderField: "Authorization")
        try OllamaWebResearchEndpointPolicy.validate(request, operation: operation)
        return request
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch {
            throw OllamaWebResearchFailure(.invalidRequest)
        }
    }

    private struct DecodedSearchItem {
        let title: String
        let url: URL
        let content: String
    }

    private static func searchPayload(_ data: Data) throws -> [DecodedSearchItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = root["results"] as? [[String: Any]]
        else {
            throw OllamaWebResearchFailure(.invalidResponse)
        }
        return try rawResults.map { item in
            guard let title = item["title"] as? String,
                  let urlText = item["url"] as? String,
                  let url = URL(string: urlText),
                  let content = (item["content"] as? String) ?? (item["snippet"] as? String)
            else {
                throw OllamaWebResearchFailure(.invalidResponse)
            }
            return .init(title: title, url: url, content: content)
        }
    }

    private static func fetchPayload(_ data: Data) throws -> (title: String?, content: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (root["content"] as? String) ?? (root["text"] as? String),
              !content.isEmpty
        else {
            throw OllamaWebResearchFailure(.invalidResponse)
        }
        return (root["title"] as? String, content)
    }
}

private enum OllamaWebResearchTextPolicy {
    static func text(_ input: String, maximumCharacters: Int) -> String {
        bounded(input, maximumCharacters: maximumCharacters).text
    }

    static func classification(_ input: String, maximumCharacters: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._:-")
        )
        return input.unicodeScalars
            .filter(allowed.contains)
            .prefix(maximumCharacters)
            .map { String($0) }
            .joined()
    }

    static func bounded(
        _ input: String,
        maximumCharacters: Int
    ) -> (text: String, wasTruncated: Bool) {
        var sanitized = ""
        sanitized.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                sanitized.append(" ")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        let collapsed = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumCharacters else {
            return (collapsed, false)
        }
        return (String(collapsed.prefix(maximumCharacters)), true)
    }
}

private enum OllamaWebResearchPrivacy {
    static func digest(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
