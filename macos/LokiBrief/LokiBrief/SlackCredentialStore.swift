import Foundation
import Security

struct SlackOAuthCredential: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumTokenBytes = 8_192

    let schemaVersion: Int
    let teamID: String
    let userID: String
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let issuedAt: Date
    let accessTokenExpiresAt: Date
    let refreshTokenExpiresAt: Date
    let grantedScopes: [String]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        teamID: String,
        userID: String,
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        issuedAt: Date,
        accessTokenExpiresAt: Date,
        refreshTokenExpiresAt: Date,
        grantedScopes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.teamID = teamID
        self.userID = userID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.issuedAt = issuedAt
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.grantedScopes = Array(Set(grantedScopes)).sorted()
    }

    var accountIdentifier: String { "\(teamID):\(userID)" }

    func needsRefresh(at now: Date, skew: TimeInterval = 300) -> Bool {
        let boundedSkew = min(max(skew, 0), 900)
        return accessTokenExpiresAt <= now.addingTimeInterval(boundedSkew)
    }

    func isRefreshTokenExpired(at now: Date) -> Bool {
        refreshTokenExpiresAt <= now
    }

    func isStructurallyValid() -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && Self.isValidIdentifier(teamID)
            && Self.isValidIdentifier(userID)
            && Self.isValidSecret(accessToken)
            && Self.isValidSecret(refreshToken)
            && tokenType == "user"
            && issuedAt < accessTokenExpiresAt
            && issuedAt < refreshTokenExpiresAt
            && !grantedScopes.isEmpty
            && grantedScopes.allSatisfy(Self.isValidScope)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidSecret(_ value: String) -> Bool {
        guard (1...maximumTokenBytes).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func isValidScope(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

enum SlackCredentialStoreFailureCode: String, Codable, Sendable {
    case invalidService = "slack_keychain_service_invalid"
    case invalidCredential = "slack_keychain_credential_invalid"
    case payloadEncodingFailed = "slack_keychain_payload_encoding_failed"
    case payloadDecodingFailed = "slack_keychain_payload_decoding_failed"
    case payloadTooLarge = "slack_keychain_payload_too_large"
    case alreadyExists = "slack_keychain_item_already_exists"
    case notFound = "slack_keychain_item_not_found"
    case missingEntitlement = "slack_keychain_missing_entitlement"
    case unavailable = "slack_keychain_unavailable"
    case interactionNotAllowed = "slack_keychain_interaction_not_allowed"
    case createFailed = "slack_keychain_create_failed"
    case readFailed = "slack_keychain_read_failed"
    case replaceFailed = "slack_keychain_replace_failed"
    case deleteFailed = "slack_keychain_delete_failed"
}

struct SlackCredentialStoreFailure: Error, Equatable, Sendable, LocalizedError {
    let code: SlackCredentialStoreFailureCode
    let status: OSStatus?

    init(code: SlackCredentialStoreFailureCode, status: OSStatus? = nil) {
        self.code = code
        self.status = status
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .invalidService:
            "The Keychain service identifier is invalid."
        case .invalidCredential:
            "The Slack credential envelope is invalid."
        case .payloadEncodingFailed:
            "The Slack credential envelope could not be encoded."
        case .payloadDecodingFailed:
            "The Slack credential envelope could not be decoded."
        case .payloadTooLarge:
            "The Slack credential envelope exceeded its storage bound."
        case .alreadyExists:
            "A Slack credential already exists for this workspace and user."
        case .notFound:
            "No Slack credential exists for this workspace and user."
        case .missingEntitlement:
            "The application is not entitled to access the Data Protection Keychain."
        case .unavailable:
            "The Data Protection Keychain is unavailable."
        case .interactionNotAllowed:
            "Keychain access is not currently permitted."
        case .createFailed:
            "The Slack credential could not be created in Keychain."
        case .readFailed:
            "The Slack credential could not be read from Keychain."
        case .replaceFailed:
            "The Slack credential could not be atomically replaced in Keychain."
        case .deleteFailed:
            "The Slack credential could not be deleted from Keychain."
        }
    }
}

protocol SlackCredentialStoring: Sendable {
    func create(_ credential: SlackOAuthCredential) async throws
    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential
    func replace(_ credential: SlackOAuthCredential) async throws
    func delete(teamID: String, userID: String) async throws
}

/// Process-local credential plane for in-memory and explicit-root launches.
/// It cannot read or mutate the production Keychain namespace.
actor VolatileSlackCredentialStore: SlackCredentialStoring {
    private var credentials: [String: SlackOAuthCredential] = [:]

    func create(_ credential: SlackOAuthCredential) async throws {
        guard credential.isStructurallyValid() else {
            throw SlackCredentialStoreFailure(code: .invalidCredential)
        }
        let key = credential.accountIdentifier
        guard credentials[key] == nil else {
            throw SlackCredentialStoreFailure(code: .alreadyExists)
        }
        credentials[key] = credential
    }

    func read(
        teamID: String,
        userID: String
    ) async throws -> SlackOAuthCredential {
        let key = "\(teamID):\(userID)"
        guard let credential = credentials[key] else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        guard credential.isStructurallyValid() else {
            throw SlackCredentialStoreFailure(code: .invalidCredential)
        }
        let key = credential.accountIdentifier
        guard credentials[key] != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        credentials[key] = credential
    }

    func delete(teamID: String, userID: String) async throws {
        let key = "\(teamID):\(userID)"
        guard credentials.removeValue(forKey: key) != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
    }
}

actor SecuritySlackCredentialStore: SlackCredentialStoring {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    static let productionService = "com.agentloki.LokiBrief.slack.oauth.v1"
    static let maximumPayloadBytes = 64 * 1_024

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

    func create(_ credential: SlackOAuthCredential) async throws {
        let trace = SlackTraceContext()
        emit(operation: "create", status: .started, reason: "slack_keychain_create_started", accountIdentifier: credential.accountIdentifier, trace: trace)
        do {
            let data = try encodedCredential(credential)
            var query = try baseQuery(teamID: credential.teamID, userID: credential.userID)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecValueData as String] = data

            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw failure(for: status, operation: .createFailed)
            }
            emit(operation: "create", status: .success, reason: "slack_keychain_create_succeeded", accountIdentifier: credential.accountIdentifier, trace: trace)
        } catch {
            emit(operation: "create", status: .failed, reason: reasonCode(for: error), accountIdentifier: credential.accountIdentifier, trace: trace)
            throw error
        }
    }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        let accountIdentifier = "\(teamID):\(userID)"
        let trace = SlackTraceContext()
        emit(operation: "read", status: .started, reason: "slack_keychain_read_started", accountIdentifier: accountIdentifier, trace: trace)
        do {
            var query = try baseQuery(teamID: teamID, userID: userID)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                throw failure(for: status, operation: .readFailed)
            }
            guard let data = result as? Data, data.count <= Self.maximumPayloadBytes else {
                throw SlackCredentialStoreFailure(code: .payloadTooLarge)
            }

            let credential: SlackOAuthCredential
            do {
                credential = try Self.decoder.decode(SlackOAuthCredential.self, from: data)
            } catch {
                throw SlackCredentialStoreFailure(code: .payloadDecodingFailed)
            }
            guard credential.teamID == teamID, credential.userID == userID, credential.isStructurallyValid() else {
                throw SlackCredentialStoreFailure(code: .invalidCredential)
            }
            emit(operation: "read", status: .success, reason: "slack_keychain_read_succeeded", accountIdentifier: accountIdentifier, trace: trace)
            return credential
        } catch {
            emit(operation: "read", status: .failed, reason: reasonCode(for: error), accountIdentifier: accountIdentifier, trace: trace)
            throw error
        }
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        let trace = SlackTraceContext()
        emit(operation: "replace", status: .started, reason: "slack_keychain_replace_started", accountIdentifier: credential.accountIdentifier, trace: trace)
        do {
            let data = try encodedCredential(credential)
            let query = try baseQuery(teamID: credential.teamID, userID: credential.userID)
            let attributes: [String: Any] = [kSecValueData as String: data]

            // SecItemUpdate replaces the one exact Generic Password payload atomically. A missing
            // item remains a failure; refresh must never silently recreate a credential record.
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw failure(for: status, operation: .replaceFailed)
            }
            emit(operation: "replace", status: .success, reason: "slack_keychain_replace_succeeded", accountIdentifier: credential.accountIdentifier, trace: trace)
        } catch {
            emit(operation: "replace", status: .failed, reason: reasonCode(for: error), accountIdentifier: credential.accountIdentifier, trace: trace)
            throw error
        }
    }

    func delete(teamID: String, userID: String) async throws {
        let accountIdentifier = "\(teamID):\(userID)"
        let trace = SlackTraceContext()
        emit(operation: "delete", status: .started, reason: "slack_keychain_delete_started", accountIdentifier: accountIdentifier, trace: trace)
        do {
            let query = try baseQuery(teamID: teamID, userID: userID)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess else {
                throw failure(for: status, operation: .deleteFailed)
            }
            emit(operation: "delete", status: .success, reason: "slack_keychain_delete_succeeded", accountIdentifier: accountIdentifier, trace: trace)
        } catch {
            emit(operation: "delete", status: .failed, reason: reasonCode(for: error), accountIdentifier: accountIdentifier, trace: trace)
            throw error
        }
    }

    private func baseQuery(teamID: String, userID: String) throws -> [String: Any] {
        guard Self.isValidService(service) else {
            throw SlackCredentialStoreFailure(code: .invalidService)
        }
        let probe = SlackOAuthCredential(
            teamID: teamID,
            userID: userID,
            accessToken: "probe",
            refreshToken: "probe",
            tokenType: "user",
            issuedAt: Date(timeIntervalSince1970: 0),
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1),
            grantedScopes: ["probe"]
        )
        guard probe.isStructurallyValid() else {
            throw SlackCredentialStoreFailure(code: .invalidCredential)
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probe.accountIdentifier,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    private func encodedCredential(_ credential: SlackOAuthCredential) throws -> Data {
        guard credential.isStructurallyValid() else {
            throw SlackCredentialStoreFailure(code: .invalidCredential)
        }
        let data: Data
        do {
            data = try Self.encoder.encode(credential)
        } catch {
            throw SlackCredentialStoreFailure(code: .payloadEncodingFailed)
        }
        guard data.count <= Self.maximumPayloadBytes else {
            throw SlackCredentialStoreFailure(code: .payloadTooLarge)
        }
        return data
    }

    private func failure(for status: OSStatus, operation: SlackCredentialStoreFailureCode) -> SlackCredentialStoreFailure {
        let code: SlackCredentialStoreFailureCode
        switch status {
        case errSecDuplicateItem:
            code = .alreadyExists
        case errSecItemNotFound:
            code = .notFound
        case errSecMissingEntitlement:
            code = .missingEntitlement
        case errSecNotAvailable:
            code = .unavailable
        case errSecInteractionNotAllowed:
            code = .interactionNotAllowed
        default:
            code = operation
        }
        return SlackCredentialStoreFailure(code: code, status: status)
    }

    private func reasonCode(for error: Error) -> String {
        (error as? SlackCredentialStoreFailure)?.reasonCode ?? "slack_keychain_operation_failed"
    }

    private func emit(
        operation: String,
        status: SlackTraceStatus,
        reason: String,
        accountIdentifier: String,
        trace: SlackTraceContext
    ) {
        eventSink?(.init(
            ts: now(),
            event: .keychainOperation,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_keychain",
            status: status,
            reasonCode: String(reason.prefix(120)),
            durationMilliseconds: nil,
            metadata: .init([
                (.operation, operation),
                (.workspaceHash, SlackPrivacy.hashIdentifier(accountIdentifier)),
            ])
        ))
    }

    private static func isValidService(_ value: String) -> Bool {
        guard (1...256).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
