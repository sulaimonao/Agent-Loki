import Foundation
import XCTest
@testable import LokiBrief

private final class KeychainTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SlackTraceEvent] = []

    func record(_ event: SlackTraceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [SlackTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor InMemorySlackCredentialStore: SlackCredentialStoring {
    private var records: [String: SlackOAuthCredential] = [:]

    func create(_ credential: SlackOAuthCredential) async throws {
        guard credential.isStructurallyValid() else {
            throw SlackCredentialStoreFailure(code: .invalidCredential)
        }
        guard records[credential.accountIdentifier] == nil else {
            throw SlackCredentialStoreFailure(code: .alreadyExists)
        }
        records[credential.accountIdentifier] = credential
    }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        guard let credential = records["\(teamID):\(userID)"] else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        guard records[credential.accountIdentifier] != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        records[credential.accountIdentifier] = credential
    }

    func delete(teamID: String, userID: String) async throws {
        guard records.removeValue(forKey: "\(teamID):\(userID)") != nil else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
    }
}

private enum KeychainSmokeTestSentinel: Error, Equatable {
    case expectedFailureDidNotOccur(
        SlackCredentialStoreFailureCode
    )
}

final class SlackCredentialStoreTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    func testCredentialStoreContractCreateReadAtomicReplaceDeleteAndNotFound() async throws {
        let store: any SlackCredentialStoring = InMemorySlackCredentialStore()
        let original = Self.credential(access: "access-original", refresh: "refresh-original")
        let replacement = Self.credential(access: "access-replacement", refresh: "refresh-replacement")

        try await store.create(original)
        let created = try await store.read(teamID: "T123", userID: "U123")
        XCTAssertEqual(created, original)
        await Self.assertStoreFailure(.alreadyExists) { try await store.create(original) }

        try await store.replace(replacement)
        let replaced = try await store.read(teamID: "T123", userID: "U123")
        XCTAssertEqual(replaced, replacement)
        XCTAssertNotEqual(replaced, original)

        try await store.delete(teamID: "T123", userID: "U123")
        await Self.assertStoreFailure(.notFound) {
            try await store.read(teamID: "T123", userID: "U123")
        }
        await Self.assertStoreFailure(.notFound) { try await store.replace(replacement) }
        await Self.assertStoreFailure(.notFound) {
            try await store.delete(teamID: "T123", userID: "U123")
        }
    }

    func testCredentialValidationRejectsNonUserAndControlBearingSecrets() {
        let bot = SlackOAuthCredential(
            teamID: "T123",
            userID: "U123",
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "bot",
            issuedAt: Self.anchor,
            accessTokenExpiresAt: Self.anchor.addingTimeInterval(60),
            refreshTokenExpiresAt: Self.anchor.addingTimeInterval(120),
            grantedScopes: ["channels:read"]
        )
        let controlBearing = SlackOAuthCredential(
            teamID: "T123",
            userID: "U123",
            accessToken: "access\nleak",
            refreshToken: "refresh",
            tokenType: "user",
            issuedAt: Self.anchor,
            accessTokenExpiresAt: Self.anchor.addingTimeInterval(60),
            refreshTokenExpiresAt: Self.anchor.addingTimeInterval(120),
            grantedScopes: ["channels:read"]
        )
        XCTAssertFalse(bot.isStructurallyValid())
        XCTAssertFalse(controlBearing.isStructurallyValid())
    }

    func testReasonCodedErrorsAndDescriptionsNeverContainCredentialValues() {
        let sensitiveValues = ["access-sentinel-private", "refresh-sentinel-private"]
        for code in [
            SlackCredentialStoreFailureCode.invalidCredential,
            .payloadEncodingFailed,
            .payloadDecodingFailed,
            .alreadyExists,
            .notFound,
            .createFailed,
            .readFailed,
            .replaceFailed,
            .deleteFailed
        ] {
            let failure = SlackCredentialStoreFailure(code: code, status: errSecParam)
            let rendered = "\(failure.reasonCode) \(failure.errorDescription ?? "") \(failure.status ?? 0)"
            XCTAssertTrue(sensitiveValues.allSatisfy { !rendered.contains($0) })
        }
    }

    func testIsolatedDataProtectionKeychainCreateReadReplaceDeleteSmoke() async throws {
        let namespace = UUID().uuidString.lowercased()
        let service = "com.agentloki.LokiBrief.tests.slack.oauth.\(namespace)"
        let teamID = "T-\(namespace)"
        let userID = "U-\(namespace)"
        let traceRecorder = KeychainTraceRecorder()
        let store = SecuritySlackCredentialStore(service: service, eventSink: { @Sendable event in
            traceRecorder.record(event)
        })
        let original = Self.credential(
            teamID: teamID,
            userID: userID,
            access: "native-access-one",
            refresh: "native-refresh-one"
        )
        let replacement = Self.credential(
            teamID: teamID,
            userID: userID,
            access: "native-access-two",
            refresh: "native-refresh-two"
        )

        var primaryError: Error?
        var creationSucceeded = false
        var cleanupRequired = false
        var cleanupDeleteSucceeded = false

        do {
            try await store.create(original)
            creationSucceeded = true
            cleanupRequired = true
            let created = try await store.read(teamID: teamID, userID: userID)
            XCTAssertEqual(created, original)
            try await store.replace(replacement)
            let replaced = try await store.read(teamID: teamID, userID: userID)
            XCTAssertEqual(replaced, replacement)
        } catch {
            primaryError = error
        }

        // Every successful creation converges through this one bounded cleanup path. The
        // ownership flag is cleared only after an exact post-delete not-found read proves
        // absence; an unexpected successful read remains a typed failure and cannot skip.
        var cleanupError: Error?
        if cleanupRequired {
            do {
                cleanupDeleteSucceeded =
                    try await Self.deleteAndVerifyOwnedItemAbsent(
                        store,
                        teamID: teamID,
                        userID: userID
                    )
                cleanupRequired = false
            } catch {
                cleanupError = error
                // A cleanup anomaly is itself a gate failure, but it cannot be
                // allowed to strand the exact synthetic item. Make one final
                // bounded attempt against the same UUID-owned identity. Keep
                // the first error when recovery proves absence; a recovery
                // failure outranks it because residual state is then unknown.
                do {
                    cleanupDeleteSucceeded =
                        try await Self.deleteAndVerifyOwnedItemAbsent(
                            store,
                            teamID: teamID,
                            userID: userID
                        ) || cleanupDeleteSucceeded
                    cleanupRequired = false
                } catch {
                    cleanupError = error
                }
            }
        }

        if let cleanupError { throw cleanupError }
        if let failure = primaryError as? SlackCredentialStoreFailure,
           !creationSucceeded,
           failure.code == .missingEntitlement
        {
            throw XCTSkip("Data Protection Keychain unavailable: \(failure.reasonCode).")
        }
        if let primaryError { throw primaryError }
        XCTAssertFalse(cleanupRequired)
        Self.assertSafeKeychainTrace(
            traceRecorder.snapshot(),
            successfulOperations: Set([
                "create",
                "read",
                "replace",
            ] + (cleanupDeleteSucceeded ? ["delete"] : [])),
            attemptedOperations: [
                "create",
                "read",
                "replace",
                "delete",
            ],
            taskOwnedValues: [namespace, service, teamID, userID]
        )
    }

    private static func assertSafeKeychainTrace(
        _ events: [SlackTraceEvent],
        successfulOperations: Set<String>,
        attemptedOperations: Set<String> = [],
        taskOwnedValues: [String] = []
    ) {
        let successful = events.filter { $0.status == .success }
        XCTAssertTrue(successfulOperations.isSubset(of: Set(successful.compactMap { $0.metadata[.operation] })))
        let attempted = Set(events.compactMap {
            $0.metadata[.operation]
        })
        XCTAssertTrue(attemptedOperations.isSubset(of: attempted))
        XCTAssertTrue(events.allSatisfy { $0.event == .keychainOperation })
        XCTAssertTrue(events.allSatisfy { $0.component == "slack_keychain" })
        XCTAssertTrue(events.allSatisfy { $0.metadata[.workspaceHash]?.count == 16 })
        let serialized = events.map(String.init(describing:)).joined(separator: " ")
        for privateValue in [
            "native-access-one",
            "native-refresh-one",
            "native-access-two",
            "native-refresh-two",
            "T123",
            "U123",
        ] + taskOwnedValues {
            XCTAssertFalse(serialized.contains(privateValue))
        }
    }

    private static func credential(
        teamID: String = "T123",
        userID: String = "U123",
        access: String,
        refresh: String
    ) -> SlackOAuthCredential {
        SlackOAuthCredential(
            teamID: teamID,
            userID: userID,
            accessToken: access,
            refreshToken: refresh,
            tokenType: "user",
            issuedAt: anchor,
            accessTokenExpiresAt: anchor.addingTimeInterval(3_600),
            refreshTokenExpiresAt: anchor.addingTimeInterval(30 * 24 * 60 * 60),
            grantedScopes: Array(SlackOAuthScopePolicy.requiredUserScopes)
        )
    }

    private static func assertStoreFailure<T>(
        _ expected: SlackCredentialStoreFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected credential-store failure \(expected.rawValue).")
        } catch let failure as SlackCredentialStoreFailure {
            XCTAssertEqual(failure.code, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }

    private static func requireStoreFailure<T>(
        _ expected: SlackCredentialStoreFailureCode,
        operation: () async throws -> T
    ) async throws {
        do {
            _ = try await operation()
            throw KeychainSmokeTestSentinel
                .expectedFailureDidNotOccur(expected)
        } catch let sentinel as KeychainSmokeTestSentinel {
            throw sentinel
        } catch let failure as SlackCredentialStoreFailure {
            guard failure.code == expected else { throw failure }
        }
    }

    private static func deleteOwnedItemIfPresent(
        _ store: SecuritySlackCredentialStore,
        teamID: String,
        userID: String
    ) async throws -> Bool {
        do {
            try await store.delete(
                teamID: teamID,
                userID: userID
            )
            return true
        } catch let failure as SlackCredentialStoreFailure {
            guard failure.code == .notFound else {
                throw failure
            }
            // Exact task-owned absence already satisfies the delete half of cleanup.
            return false
        }
    }

    private static func deleteAndVerifyOwnedItemAbsent(
        _ store: SecuritySlackCredentialStore,
        teamID: String,
        userID: String
    ) async throws -> Bool {
        let deleted = try await deleteOwnedItemIfPresent(
            store,
            teamID: teamID,
            userID: userID
        )
        try await requireStoreFailure(.notFound) {
            try await store.read(teamID: teamID, userID: userID)
        }
        return deleted
    }
}
