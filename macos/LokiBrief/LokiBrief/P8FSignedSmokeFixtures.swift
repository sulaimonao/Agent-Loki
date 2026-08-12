import Foundation
import SQLite3
import SwiftData

enum P8FSignedSmokeFixtureFailure: String, Error, Codable, Sendable {
    case fixtureDirectoryInvalid = "p8f_smoke_fixture_directory_invalid"
    case fixtureDirectoryPermissionsInvalid =
        "p8f_smoke_fixture_directory_permissions_invalid"
    case fixtureStoreUnexpectedState =
        "p8f_smoke_fixture_store_unexpected_state"
    case fixtureManifestMismatch = "p8f_smoke_fixture_manifest_mismatch"
    case fixtureWriteFailed = "p8f_smoke_fixture_write_failed"
}

enum P8FSignedSmokeFixtureClass:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case brief
    case schedule
    case finalChatUser = "final_chat_user"
    case finalChatAssistant = "final_chat_assistant"
    case draftChat = "draft_chat"
    case streamingChat = "streaming_chat"
    case cancelledChat = "cancelled_chat"
    case failedChat = "failed_chat"
    case toolTrace = "tool_trace"
    case hiddenReasoningLike = "hidden_reasoning_like"
    case vault
    case slack
    case connector
    case unknownSourceKind = "unknown_source_kind"
    case malformedSourceKind = "malformed_source_kind"
}

struct P8FSignedSmokeFixtureCount:
    Codable,
    Equatable,
    Sendable
{
    let fixtureClass: P8FSignedSmokeFixtureClass
    let count: Int
}

struct P8FSignedSmokeSourceHash:
    Codable,
    Equatable,
    Sendable
{
    let sourceKind: SemanticIndexSourceKind
    let stableIdentifierSHA256: String
    let sourceSHA256: String
}

struct P8FSignedSmokeFixtureManifest:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f-signed-smoke-fixture.v1"
    static let fixtureIdentifier =
        "agent-loki-p8f-source-authority-synthetic-v1"
    static let expectedCanonicalSHA256 =
        "7dae981f72568ddf25709735436ac4defa512ec4ec90e41a1752828c16473c5a"
    static let expectedSourceAllowlistSHA256 =
        "616d0c91529087a1b4fbb12e066a010bef35113a6b34eb9a6cd11fd98bcb0e1c"

    let schemaVersion: String
    let fixtureIdentifier: String
    let anchorTimestamp: Date
    let inventory: [P8FSignedSmokeFixtureCount]
    let canonicalSourceKinds: [SemanticIndexSourceKind]
    let expectedSourceAllowlistSHA256: String
    let expectedPreparedRecordCount: Int
    let expectedChunkCount: Int
    let expectedSourceEmbeddingCount: Int
    let expectedIndexWriteCount: Int
    let expectedExcludedAdapterInvocationCount: Int
    let expectedUnknownAcceptedCount: Int
    let expectedMalformedAcceptedCount: Int
    let expectedLeakageCanaryHitCount: Int
    let sourceHashes: [P8FSignedSmokeSourceHash]
    let leakageCanarySHA256: String
    let hiddenReasoningCanarySHA256: String

    var canonicalSHA256: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return String(repeating: "0", count: 64)
        }
        return SemanticIndexDigest.sha256(
            String(decoding: data, as: UTF8.self)
        )
    }
}

struct P8FSignedSmokeSeededFixture {
    let store: LocalStore
    let manifest: P8FSignedSmokeFixtureManifest
    let fixtureDirectory: URL
}

struct P8FSignedSmokeClosedDomainAudit:
    Codable,
    Equatable,
    Sendable
{
    let envelopeCount: Int
    let excludedKnownKindCount: Int
    let unknownRejectedCount: Int
    let malformedRejectedCount: Int
    let acceptedUnexpectedKindCount: Int
}

private struct P8FSignedSmokeRawEnvelope: Codable {
    let fixtureClass: P8FSignedSmokeFixtureClass
    let sourceKind: String
    let stableIdentifier: String
    let text: String
}

@MainActor
enum P8FSignedSmokeFixtureSeeder {
    static let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    static let controlDirectoryName = "P8FControl"
    static let fixtureDirectoryName = "Fixture"
    static let manifestFilename = "fixture-manifest.json"
    static let adversarialFilename = "adversarial-source-envelopes.json"
    static let fixtureStoreFilename = "LokiBrief-v1.store"

    static let leakageCanary =
        "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY_7ED9DCD9"
    static let hiddenReasoningCanary =
        "P8F_SYNTHETIC_HIDDEN_REASONING_CANARY_DBB8F63A"

    static func seed(
        isolatedRoot: URL,
        storageBoundary:
            P8FSignedSmokeStorageBoundary? = nil,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeSeededFixture {
        let storageBoundary = try resolvedStorageBoundary(
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        let fixtureDirectory = fixtureDirectory(
            under: isolatedRoot
        )
        guard !fileManager.fileExists(
            atPath: fixtureDirectory.path
        ) else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        try ensurePrivateDirectory(
            fixtureDirectory,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )

        let storeURL = storeURL(in: fixtureDirectory)
        do {
            try storageBoundary.validateSQLiteFamily(
                at: storeURL,
                requireDatabase: false,
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        let store = try LocalStore(url: storeURL)
        try seedCanonicalStore(store)
        try secureStoreFamily(
            at: storeURL,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        try writeAdversarialEnvelopes(
            to: fixtureDirectory.appendingPathComponent(
                adversarialFilename,
                isDirectory: false
            ),
            fileManager: fileManager
        )

        let manifest = try makeManifest(store: store)
        let manifestURL = fixtureDirectory.appendingPathComponent(
            manifestFilename,
            isDirectory: false
        )
        try writeManifest(
            manifest,
            to: manifestURL,
            fileManager: fileManager
        )
        try validateManifest(
            manifest,
            at: manifestURL,
            fileManager: fileManager
        )
        return .init(
            store: store,
            manifest: manifest,
            fixtureDirectory: fixtureDirectory
        )
    }

    static func reopen(
        isolatedRoot: URL,
        storageBoundary:
            P8FSignedSmokeStorageBoundary? = nil,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeSeededFixture {
        let storageBoundary = try resolvedStorageBoundary(
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        let fixtureDirectory = fixtureDirectory(
            under: isolatedRoot
        )
        guard ordinaryPrivateDirectory(
            fixtureDirectory,
            fileManager: fileManager
        ) else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureDirectoryInvalid
        }
        let manifestURL = fixtureDirectory.appendingPathComponent(
            manifestFilename,
            isDirectory: false
        )
        let adversarialURL = fixtureDirectory.appendingPathComponent(
            adversarialFilename,
            isDirectory: false
        )
        let storeURL = storeURL(in: fixtureDirectory)
        guard ordinaryPrivateFile(
            manifestURL,
            fileManager: fileManager
        ),
        ordinaryPrivateFile(
            adversarialURL,
            fileManager: fileManager
        ),
        ordinaryPrivateFile(
            storeURL,
            fileManager: fileManager
        ),
        let manifestData = try? Data(contentsOf: manifestURL)
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let frozenManifest = try? decoder.decode(
            P8FSignedSmokeFixtureManifest.self,
            from: manifestData
        ),
        frozenManifest.canonicalSHA256
            == P8FSignedSmokeFixtureManifest
                .expectedCanonicalSHA256
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
        do {
            try storageBoundary.validateSQLiteFamily(
                at: storeURL,
                requireDatabase: true,
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        let store = try LocalStore(url: storeURL)
        try secureStoreFamily(
            at: storeURL,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        let observedManifest = try makeManifest(store: store)
        guard observedManifest == frozenManifest,
              observedManifest.canonicalSHA256
                == frozenManifest.canonicalSHA256
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
        _ = try auditClosedSourceDomain(
            fixtureDirectory: fixtureDirectory,
            fileManager: fileManager
        )
        return .init(
            store: store,
            manifest: frozenManifest,
            fixtureDirectory: fixtureDirectory
        )
    }

    static func auditClosedSourceDomain(
        fixtureDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeClosedDomainAudit {
        let url = fixtureDirectory.appendingPathComponent(
            adversarialFilename,
            isDirectory: false
        )
        guard ordinaryPrivateFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              let envelopes = try? JSONDecoder().decode(
                [P8FSignedSmokeRawEnvelope].self,
                from: data
              ),
              envelopes.count == 5
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
        var knownExcluded = 0
        var unknownRejected = 0
        var malformedRejected = 0
        var unexpectedAccepted = 0
        for envelope in envelopes {
            let decoded = SemanticIndexSourceKind(
                rawValue: envelope.sourceKind
            )
            switch envelope.fixtureClass {
            case .vault, .slack, .connector:
                if let decoded,
                   [
                       SemanticIndexSourceKind.vaultRecord,
                       .slackRecord,
                       .connectorRecord,
                   ].contains(decoded) {
                    knownExcluded += 1
                } else {
                    unexpectedAccepted += 1
                }
            case .unknownSourceKind:
                if decoded == nil {
                    unknownRejected += 1
                } else {
                    unexpectedAccepted += 1
                }
            case .malformedSourceKind:
                if decoded == nil {
                    malformedRejected += 1
                } else {
                    unexpectedAccepted += 1
                }
            default:
                unexpectedAccepted += 1
            }
        }
        return .init(
            envelopeCount: envelopes.count,
            excludedKnownKindCount: knownExcluded,
            unknownRejectedCount: unknownRejected,
            malformedRejectedCount: malformedRejected,
            acceptedUnexpectedKindCount: unexpectedAccepted
        )
    }

    private static func seedCanonicalStore(
        _ store: LocalStore
    ) throws {
        try store.record(syntheticBrief())
        try store.savePrimaryBriefSchedule(
            syntheticSchedule(),
            at: anchor.addingTimeInterval(10)
        )

        var conversation = LokiConversation(
            id: "p8f-synthetic-conversation",
            title: "P8F synthetic source authority",
            createdAt: anchor.addingTimeInterval(20),
            updatedAt: anchor.addingTimeInterval(27),
            context: .init(
                scope: .today,
                selectedAt: anchor.addingTimeInterval(20)
            )
        )
        conversation.messages = [
            message(
                id: "p8f-final-user",
                conversationID: conversation.id,
                sequence: 0,
                role: .user,
                state: .completed,
                text: "Synthetic final user record for source authority.",
                offset: 21
            ),
            message(
                id: "p8f-final-assistant",
                conversationID: conversation.id,
                sequence: 1,
                role: .assistant,
                state: .completed,
                text:
                    "Synthetic final assistant record for source authority.",
                offset: 22
            ),
            message(
                id: "p8f-draft-user",
                conversationID: conversation.id,
                sequence: 2,
                role: .user,
                state: .pending,
                text: "Synthetic draft record must not be indexed.",
                offset: 23
            ),
            message(
                id: "p8f-streaming-assistant",
                conversationID: conversation.id,
                sequence: 3,
                role: .assistant,
                state: .streaming,
                text: "Synthetic streaming record must not be indexed.",
                offset: 24,
                isPartial: true
            ),
            message(
                id: "p8f-cancelled-assistant",
                conversationID: conversation.id,
                sequence: 4,
                role: .assistant,
                state: .canceled,
                text: "Synthetic cancelled record must not be indexed.",
                offset: 25,
                isPartial: true
            ),
            message(
                id: "p8f-failed-assistant",
                conversationID: conversation.id,
                sequence: 5,
                role: .assistant,
                state: .failed,
                text: "Synthetic failed record must not be indexed.",
                offset: 26
            ),
        ]
        _ = try store.persistLokiConversation(conversation)

        let context = store.container.mainContext
        let existing = try context.fetch(
            FetchDescriptor<StoredLokiMessage>()
        )
        try insertHiddenMessageIfMissing(
            id: "p8f-tool-trace",
            conversationID: conversation.id,
            sequence: 6,
            role: .tool,
            text: "Synthetic tool trace must not be indexed.",
            into: context,
            existing: existing
        )
        try insertHiddenMessageIfMissing(
            id: "p8f-hidden-reasoning",
            conversationID: conversation.id,
            sequence: 7,
            role: .system,
            text: hiddenReasoningCanary,
            into: context,
            existing: existing
        )
        try context.save()
    }

    private static func insertHiddenMessageIfMissing(
        id: String,
        conversationID: String,
        sequence: Int,
        role: LokiMessageRole,
        text: String,
        into context: ModelContext,
        existing: [StoredLokiMessage]
    ) throws {
        guard !existing.contains(where: { $0.id == id }) else {
            guard existing.contains(where: {
                $0.id == id
                    && $0.conversationID == conversationID
                    && $0.sequence == sequence
                    && $0.roleRaw == role.rawValue
                    && $0.stateRaw == LokiMessageState.completed.rawValue
                    && $0.visibleText == text
            }) else {
                throw P8FSignedSmokeFixtureFailure
                    .fixtureStoreUnexpectedState
            }
            return
        }
        let timestamp = anchor.addingTimeInterval(
            TimeInterval(20 + sequence)
        )
        context.insert(StoredLokiMessage(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            roleRaw: role.rawValue,
            stateRaw: LokiMessageState.completed.rawValue,
            visibleText: text,
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: timestamp
        ))
    }

    private static func syntheticBrief() -> Brief {
        let source = BriefSource(
            id: "p8f-synthetic-source",
            name: "P8F Synthetic Source",
            kind: .previewFixtures,
            state: .available,
            capabilities: [.preview],
            detail: "Bounded nonprivate synthetic fixture."
        )
        let item = BriefItem(
            id: "p8f-synthetic-brief-item",
            title: "Synthetic launch readiness",
            summary:
                "A deterministic nonprivate brief record for source authority.",
            priority: .normal,
            source: source,
            provenance: .init(
                sourceID: source.id,
                publicationDate: anchor,
                retrievedAt: anchor,
                directURL: nil,
                isSynthetic: true,
                origin: .source
            ),
            isRead: false
        )
        return Brief(
            id: "p8f-synthetic-brief",
            date: anchor,
            title: "P8F Synthetic Brief",
            summary:
                "Deterministic nonprivate source-authority fixture.",
            status: .ready,
            sections: [
                .init(
                    id: "p8f-synthetic-section",
                    title: "Synthetic",
                    items: [item],
                    summary: "Synthetic source authority section."
                ),
            ],
            generation: .init(
                engineID: "p8f-signed-smoke-fixture",
                generatedAt: anchor,
                status: .ready,
                reasonCode: "p8f_synthetic_fixture_seeded",
                fixtureRevision: 1,
                providerKind: "deterministic"
            )
        )
    }

    private static func syntheticSchedule() -> BriefSchedule {
        BriefSchedule(
            enabled: true,
            localTime: .init(hour: 9, minute: 17),
            recurrence: .daily(
                selectedWeekdays: [.monday, .wednesday, .friday]
            ),
            followsSystemTimeZone: true,
            missedRunPolicy: .skip,
            selectedAccountIDs: [],
            delivery: .init(
                refreshFeeds: false,
                refreshSelectedSlackWorkspaces: false,
                allowScheduledOllama: false,
                notificationsEnabled: false,
                notificationPrivacy: .minimal,
                pauseInLowPowerMode: true
            ),
            recurrenceVersion: 1
        )
    }

    private static func message(
        id: String,
        conversationID: String,
        sequence: Int,
        role: LokiMessageRole,
        state: LokiMessageState,
        text: String,
        offset: TimeInterval,
        isPartial: Bool = false
    ) -> LokiMessage {
        let timestamp = anchor.addingTimeInterval(offset)
        return LokiMessage(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            role: role,
            state: state,
            visibleText: text,
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: state.isTerminal ? timestamp : nil,
            failure: state == .failed
                ? .init(
                    code: .unknown,
                    isRecoverable: false,
                    consumerMessage:
                        "Synthetic fixture failure; not production content."
                )
                : nil,
            isPartial: isPartial
        )
    }

    private static func writeAdversarialEnvelopes(
        to url: URL,
        fileManager: FileManager
    ) throws {
        let envelopes = [
            P8FSignedSmokeRawEnvelope(
                fixtureClass: .vault,
                sourceKind:
                    SemanticIndexSourceKind.vaultRecord.rawValue,
                stableIdentifier: "p8f-excluded-vault",
                text: leakageCanary
            ),
            .init(
                fixtureClass: .slack,
                sourceKind:
                    SemanticIndexSourceKind.slackRecord.rawValue,
                stableIdentifier: "p8f-excluded-slack",
                text: leakageCanary
            ),
            .init(
                fixtureClass: .connector,
                sourceKind:
                    SemanticIndexSourceKind.connectorRecord.rawValue,
                stableIdentifier: "p8f-excluded-connector",
                text: leakageCanary
            ),
            .init(
                fixtureClass: .unknownSourceKind,
                sourceKind: "future_private_source",
                stableIdentifier: "p8f-unknown-source-kind",
                text: leakageCanary
            ),
            .init(
                fixtureClass: .malformedSourceKind,
                sourceKind: " ../malformed ",
                stableIdentifier: "p8f-malformed-source-kind",
                text: leakageCanary
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try privateAtomicWrite(
                try encoder.encode(envelopes),
                to: url,
                fileManager: fileManager
            )
        } catch let failure as P8FSignedSmokeFixtureFailure {
            throw failure
        } catch {
            throw P8FSignedSmokeFixtureFailure.fixtureWriteFailed
        }
    }

    private static func makeManifest(
        store: LocalStore
    ) throws -> P8FSignedSmokeFixtureManifest {
        let briefRecords = try P8SemanticSourceAdapter.briefRecords(
            from: store
        )
        let scheduleRecords =
            try P8SemanticSourceAdapter.scheduleRecords(from: store)
        let chatRecords =
            try P8SemanticSourceAdapter.chatFinalMessageRecords(
                from: store
            )
        guard briefRecords.count == 1,
              scheduleRecords.count == 1,
              chatRecords.count == 2
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        let sourceHashes = (
            briefRecords + scheduleRecords + chatRecords
        )
        .sorted {
            if $0.sourceKind != $1.sourceKind {
                return $0.sourceKind.rawValue
                    < $1.sourceKind.rawValue
            }
            return $0.stableSourceIdentifier
                < $1.stableSourceIdentifier
        }
        .map {
            P8FSignedSmokeSourceHash(
                sourceKind: $0.sourceKind,
                stableIdentifierSHA256:
                    SemanticIndexDigest.sha256(
                        $0.stableSourceIdentifier
                    ),
                sourceSHA256: $0.sourceHash
            )
        }
        let counts: [P8FSignedSmokeFixtureClass: Int] = [
            .brief: 1,
            .schedule: 1,
            .finalChatUser: 1,
            .finalChatAssistant: 1,
            .draftChat: 1,
            .streamingChat: 1,
            .cancelledChat: 1,
            .failedChat: 1,
            .toolTrace: 1,
            .hiddenReasoningLike: 1,
            .vault: 1,
            .slack: 1,
            .connector: 1,
            .unknownSourceKind: 1,
            .malformedSourceKind: 1,
        ]
        return .init(
            schemaVersion:
                P8FSignedSmokeFixtureManifest.currentSchemaVersion,
            fixtureIdentifier:
                P8FSignedSmokeFixtureManifest.fixtureIdentifier,
            anchorTimestamp: anchor,
            inventory:
                P8FSignedSmokeFixtureClass.allCases.map {
                    .init(
                        fixtureClass: $0,
                        count: counts[$0] ?? 0
                    )
                },
            canonicalSourceKinds: [
                .brief,
                .chatMessage,
                .schedule,
            ].sorted { $0.authorityName < $1.authorityName },
            expectedSourceAllowlistSHA256:
                P8FSignedSmokeFixtureManifest
                    .expectedSourceAllowlistSHA256,
            expectedPreparedRecordCount: 4,
            expectedChunkCount: 4,
            expectedSourceEmbeddingCount: 4,
            expectedIndexWriteCount: 4,
            expectedExcludedAdapterInvocationCount: 0,
            expectedUnknownAcceptedCount: 0,
            expectedMalformedAcceptedCount: 0,
            expectedLeakageCanaryHitCount: 0,
            sourceHashes: sourceHashes,
            leakageCanarySHA256:
                SemanticIndexDigest.sha256(leakageCanary),
            hiddenReasoningCanarySHA256:
                SemanticIndexDigest.sha256(
                    hiddenReasoningCanary
                )
        )
    }

    private static func writeManifest(
        _ manifest: P8FSignedSmokeFixtureManifest,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        do {
            try privateAtomicWrite(
                try encoder.encode(manifest),
                to: url,
                fileManager: fileManager
            )
        } catch let failure as P8FSignedSmokeFixtureFailure {
            throw failure
        } catch {
            throw P8FSignedSmokeFixtureFailure.fixtureWriteFailed
        }
    }

    private static func validateManifest(
        _ expected: P8FSignedSmokeFixtureManifest,
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard ordinaryPrivateFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let reopened = try? decoder.decode(
            P8FSignedSmokeFixtureManifest.self,
            from: data
        ),
        reopened == expected,
        reopened.canonicalSHA256 == expected.canonicalSHA256
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureManifestMismatch
        }
    }

    private static func ensurePrivateDirectory(
        _ url: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager
    ) throws {
        do {
            try storageBoundary.ensurePrivateDirectory(
                at: url,
                fileManager: fileManager
            )
        } catch let failure as P8FSignedSmokeFixtureFailure {
            throw failure
        } catch {
            throw P8FSignedSmokeFixtureFailure
                .fixtureDirectoryInvalid
        }
    }

    private static func fixtureDirectory(
        under isolatedRoot: URL
    ) -> URL {
        isolatedRoot
            .appendingPathComponent(
                controlDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                fixtureDirectoryName,
                isDirectory: true
            )
    }

    private static func storeURL(
        in fixtureDirectory: URL
    ) -> URL {
        fixtureDirectory.appendingPathComponent(
            fixtureStoreFilename,
            isDirectory: false
        )
    }

    private static func secureStoreFamily(
        at storeURL: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager
    ) throws {
        do {
            try storageBoundary.secureSQLiteFamily(
                at: storeURL,
                requireDatabase: true,
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
    }

    private static func resolvedStorageBoundary(
        isolatedRoot: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary?,
        fileManager: FileManager
    ) throws -> P8FSignedSmokeStorageBoundary {
        do {
            let boundary = try storageBoundary
                ?? P8FSignedSmokeStorageBoundary(
                    admitting: isolatedRoot,
                    fileManager: fileManager
                )
            try boundary.validatePrivateDirectory(
                at: isolatedRoot,
                fileManager: fileManager
            )
            try boundary.validatePrivateTree(
                at: isolatedRoot,
                fileManager: fileManager
            )
            return boundary
        } catch {
            throw P8FSignedSmokeFixtureFailure.fixtureDirectoryInvalid
        }
    }

    private static func privateAtomicWrite(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
            guard attributes[.type] as? FileAttributeType
                    == .typeRegular
            else {
                throw P8FSignedSmokeFixtureFailure
                    .fixtureWriteFailed
            }
        }
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        guard ordinaryPrivateFile(url, fileManager: fileManager)
        else {
            throw P8FSignedSmokeFixtureFailure.fixtureWriteFailed
        }
    }

    private static func ordinaryPrivateFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        permissionBits(attributes) == 0o600
        else { return false }
        return true
    }

    private static func ordinaryPrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeDirectory,
        permissionBits(attributes) == 0o700
        else { return false }
        return true
    }

    private static func permissionBits(
        _ attributes: [FileAttributeKey: Any]
    ) -> Int? {
        (attributes[.posixPermissions] as? NSNumber)?.intValue
            ?? attributes[.posixPermissions] as? Int
    }
}

struct P8FSignedSmokeSourceCounter:
    Codable,
    Equatable,
    Sendable
{
    let sourceKind: SemanticIndexSourceKind
    let adapterInvocations: Int
    let recordsRead: Int
}

enum P8FSignedSmokeSourceRegistryMode:
    Equatable,
    Sendable
{
    case normal
    case blockBeforeRead(SemanticIndexSourceKind)
    case adapterKindDrift(
        expected: SemanticIndexSourceKind,
        actual: SemanticIndexSourceKind
    )
}

enum P8FSignedSmokeEmbeddingCapability {
    case native
    case counting(P8FSignedSmokeCountingEmbeddingProvider)
}

struct P8FSignedSmokeVolatileCredentialCounters:
    Equatable,
    Sendable
{
    let storeCount: Int
    let readCount: Int
    let deleteCount: Int
}

private actor P8FSignedSmokeVolatileCredentialCapability:
    OllamaWebResearchCredentialStoring
{
    private let backing = VolatileOllamaWebResearchCredentialStore()
    private var storeCount = 0
    private var readCount = 0
    private var deleteCount = 0

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        storeCount += 1
        try await backing.storeAPIKey(
            apiKey,
            service: service,
            account: account
        )
    }

    func readAPIKey(
        service: String,
        account: String
    ) async throws -> String? {
        readCount += 1
        return try await backing.readAPIKey(
            service: service,
            account: account
        )
    }

    func deleteAPIKey(
        service: String,
        account: String
    ) async throws {
        deleteCount += 1
        try await backing.deleteAPIKey(
            service: service,
            account: account
        )
    }

    func snapshot() -> P8FSignedSmokeVolatileCredentialCounters {
        .init(
            storeCount: storeCount,
            readCount: readCount,
            deleteCount: deleteCount
        )
    }
}

private struct P8FSignedSmokeDisabledWebResearchProvider:
    P8OllamaWebResearchProviding
{
    func search(
        _ request: OllamaWebSearchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebSearchResponse {
        throw P8SignedSmokeWebResearchFailure()
    }

    func fetch(
        _ request: OllamaWebFetchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebFetchResponse {
        throw P8SignedSmokeWebResearchFailure()
    }

    func cancel(requestID: UUID) async {}
}

private struct P8FSignedSmokeUnavailableEntitlementProvider:
    FeatureEntitlementProvider
{
    func entitlement(
        for feature: LokiPaidFeature
    ) async -> FeatureEntitlement {
        .init(
            feature: feature,
            state: .unavailable,
            acquisitionAllowed: false,
            reasonCode: "p8f_signed_smoke_acquisition_disabled"
        )
    }
}

actor P8FSignedSmokeInertToolDataSource:
    AgentLokiReadOnlyToolDataSource
{
    private func unavailable() -> AgentLokiToolFailure {
        AgentLokiToolFailure(
            .authorizationDenied,
            message:
                "Read-only tools are disabled in signed-smoke isolation."
        )
    }

    func authorizationDecision(
        for scope: AgentLokiAuthorizationScope
    ) async -> AgentLokiAuthorizationDecision {
        .deny(
            .authorizationDenied,
            reasonCode: "p8f_signed_smoke_tool_disabled"
        )
    }

    func currentBriefSnapshot() async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func briefSnapshot(id: String) async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func searchBriefHistory(
        _ query: AgentLokiBriefHistoryQuery
    ) async throws -> AgentLokiToolSnapshot
    { throw unavailable() }

    func beginVaultForegroundRead() async {}
    func endVaultForegroundRead() async {}

    func searchVaultText(
        _ query: AgentLokiVaultTextQuery
    ) async throws -> AgentLokiToolSnapshot
    { throw unavailable() }

    func vaultItemSnapshot(id: String) async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func connectedSourcesSnapshot(limit: Int) async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func sourceHealthSnapshot(id: String) async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func slackWorkspacesSnapshot(limit: Int) async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func selectedSlackChannelsSnapshot(
        workspaceID: String,
        limit: Int
    ) async throws -> AgentLokiToolSnapshot
    { throw unavailable() }

    func deliveryStatusSnapshot() async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func updateStatusSnapshot() async throws
        -> AgentLokiToolSnapshot
    { throw unavailable() }

    func previewBackfill(
        _ query: AgentLokiBackfillPreviewQuery
    ) async throws -> AgentLokiToolSnapshot
    { throw unavailable() }
}

enum P8FSignedSmokeSemanticIndexConstructionProfile:
    String,
    Equatable,
    Sendable
{
    /// Normal signed-smoke storage, scheduling, lifecycle, and publication
    /// behavior. No caller-supplied closure participates in construction.
    case runtime

    /// The one bounded diagnostic profile: allow the first publication and
    /// reject a successor immediately before its publication transaction.
    case rejectSuccessorPublicationForIntegrityDiagnostic

#if DEBUG
    /// XCTest-only deterministic substitution immediately before successor
    /// publication. The package factory additionally verifies the actual test
    /// host before issuing this profile.
    case replaceDirectoryBeforeSuccessorPublicationForIntegrityDiagnostic
#endif
}

enum P8FSignedSmokeSemanticIndexDiagnosticFailure:
    String,
    Error,
    Equatable,
    Sendable
{
    case successorPublicationRejected =
        "p8f_semantic_successor_publication_diagnostic_rejected"
}

final class P8FSignedSmokeSemanticIndexConstructionIssuer:
    @unchecked Sendable
{
    fileprivate init() {}
}

final class P8FSignedSmokeSemanticIndexConstructionAuthority:
    @unchecked Sendable
{
    let storageBoundary: P8FSignedSmokeStorageBoundary
    let runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    let issuer: P8FSignedSmokeSemanticIndexConstructionIssuer
    let profile: P8FSignedSmokeSemanticIndexConstructionProfile

    fileprivate init(
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority,
        issuer: P8FSignedSmokeSemanticIndexConstructionIssuer,
        profile: P8FSignedSmokeSemanticIndexConstructionProfile
    ) {
        self.storageBoundary = storageBoundary
        self.runtimeAuthority = runtimeAuthority
        self.issuer = issuer
        self.profile = profile
    }
}

private actor P8FSignedSmokeDisabledFeedClient: FeedRetrieving {
    func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext
    ) async throws -> FeedFetchResult {
        throw FeedFetchFailure(
            .networkUnavailable,
            message:
                "Feed transport is disabled in signed-smoke isolation."
        )
    }

    func cancelAll() async {}
}

@MainActor
private final class P8FSignedSmokeDependencyBoundaryGuard {
    private let store: LocalStore
    private let storeStorageURL: URL
    private let storageURL: URL
    private let storageBoundary: P8FSignedSmokeStorageBoundary
    private let runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    private let sqliteIdentity:
        P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot
    private var applicationSlackControllerIdentity:
        ObjectIdentifier?
    private var applicationVaultControllerIdentity:
        ObjectIdentifier?
    private var vaultControllerDatabaseURL: URL?
    private var vaultDatabaseURL: URL?
    private var vaultSQLiteIdentity:
        P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot?
    private var vaultFamilyExpectedAbsent = false

    fileprivate var boundStore: LocalStore { store }
    fileprivate var boundStorageBoundary:
        P8FSignedSmokeStorageBoundary
    { storageBoundary }
    fileprivate var boundRuntimeAuthority:
        P8FSignedSmokeRuntimeAuthority
    { runtimeAuthority }

    init(
        store: LocalStore,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority,
        requiredBoundaryStorageURL: URL? = nil
    ) throws {
        guard runtimeAuthority.matches(
                storageBoundary: storageBoundary
              ),
              !store.isInMemory,
              store.usesExplicitStorageURL,
              store.validatesExplicitStorageIdentity(),
              let storageURL = store.storageURL
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let primaryStoreURL = storageBoundary.rootURL
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureStoreFilename,
                isDirectory: false
            )
        let fixtureStoreURL = storageBoundary.rootURL
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.controlDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureStoreFilename,
                isDirectory: false
            )
        guard let resolvedStoragePath = LokiCanonicalFileURL.existing(
                storageURL,
                isDirectory: false
              )?.path
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let resolvedPrimaryPath = LokiCanonicalFileURL.existing(
            primaryStoreURL,
            isDirectory: false
        )?.path
        let resolvedFixturePath = LokiCanonicalFileURL.existing(
            fixtureStoreURL,
            isDirectory: false
        )?.path
        let boundaryStorageURL: URL
        if let requiredBoundaryStorageURL {
            let required = LokiCanonicalFileURL.lexical(
                requiredBoundaryStorageURL
            )
            guard let resolvedRequiredPath =
                    LokiCanonicalFileURL.existing(
                        required,
                        isDirectory: false
                    )?.path,
                  resolvedStoragePath == resolvedRequiredPath
            else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            boundaryStorageURL = required
        } else if resolvedStoragePath == resolvedPrimaryPath {
            boundaryStorageURL = primaryStoreURL
        } else if resolvedStoragePath == resolvedFixturePath {
            boundaryStorageURL = fixtureStoreURL
        } else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try storageBoundary.validateCurrentRoot()
            sqliteIdentity = try storageBoundary
                .captureSQLiteIdentity(
                    at: boundaryStorageURL,
                    freezeSidecars: false
                )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        self.store = store
        storeStorageURL = storageURL
        self.storageURL = boundaryStorageURL
        self.storageBoundary = storageBoundary
        self.runtimeAuthority = runtimeAuthority
    }

    func bindApplicationDependencies(
        slackController: SlackAppController,
        vaultController: VaultController
    ) throws {
        guard applicationSlackControllerIdentity == nil,
              applicationVaultControllerIdentity == nil,
              vaultControllerDatabaseURL == nil,
              vaultDatabaseURL == nil,
              vaultSQLiteIdentity == nil,
              !vaultFamilyExpectedAbsent,
              !vaultController.databaseIsInMemory
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let candidateVaultURL = LokiCanonicalFileURL.lexical(
            vaultController.databaseURL
        )
        let expectedVaultURL = storageBoundary.rootURL
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(
                "loki-vault.sqlite3",
                isDirectory: false
            )
        guard candidateVaultURL.resolvingSymlinksInPath()
                .standardizedFileURL.path
                == expectedVaultURL.resolvingSymlinksInPath()
                    .standardizedFileURL.path
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try validate()
            try storageBoundary.validateSQLiteFamily(
                at: expectedVaultURL,
                requireDatabase: true
            )
            vaultSQLiteIdentity = try storageBoundary
                .captureSQLiteIdentity(
                    at: expectedVaultURL,
                    freezeSidecars: false
                )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        applicationSlackControllerIdentity =
            ObjectIdentifier(slackController)
        applicationVaultControllerIdentity =
            ObjectIdentifier(vaultController)
        vaultControllerDatabaseURL = candidateVaultURL
        vaultDatabaseURL = expectedVaultURL
    }

    func validate(
        store candidateStore: LocalStore,
        storageBoundary candidateBoundary:
            P8FSignedSmokeStorageBoundary,
        runtimeAuthority candidateAuthority:
            P8FSignedSmokeRuntimeAuthority
    ) throws {
        guard store === candidateStore,
              runtimeAuthority === candidateAuthority,
              storageBoundary.sharesAdmissionIdentity(
                with: candidateBoundary
              ),
              candidateAuthority.matches(
                storageBoundary: candidateBoundary
              ),
              candidateStore.storageURL == storeStorageURL,
              candidateStore.validatesExplicitStorageIdentity()
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try validate()
    }

    func validate() throws {
        do {
            guard store.validatesExplicitStorageIdentity()
            else {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .invalidFile
            }
            try storageBoundary.validateCurrentRoot()
            try storageBoundary.validateSQLiteFamily(
                at: storageURL,
                requireDatabase: true
            )
            try storageBoundary.validateSQLiteIdentity(
                sqliteIdentity,
                at: storageURL
            )
            if let vaultDatabaseURL {
                if vaultFamilyExpectedAbsent {
                    guard vaultSQLiteIdentity == nil else {
                        throw P8FSignedSmokeStorageBoundaryFailure
                            .invalidFile
                    }
                    try storageBoundary.validateSQLiteFamilyAbsent(
                        at: vaultDatabaseURL
                    )
                } else if let vaultSQLiteIdentity {
                    try storageBoundary.validateSQLiteFamily(
                        at: vaultDatabaseURL,
                        requireDatabase: true
                    )
                    try storageBoundary.validateSQLiteIdentity(
                        vaultSQLiteIdentity,
                        at: vaultDatabaseURL
                    )
                } else {
                    throw P8FSignedSmokeStorageBoundaryFailure
                        .invalidFile
                }
            } else if applicationSlackControllerIdentity != nil
                        || applicationVaultControllerIdentity != nil {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .invalidFile
            }
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    func validateApplicationDependencies(
        slackController: SlackAppController,
        vaultController: VaultController
    ) throws {
        guard applicationSlackControllerIdentity
                == ObjectIdentifier(slackController),
              applicationVaultControllerIdentity
                == ObjectIdentifier(vaultController),
              vaultControllerDatabaseURL
                == LokiCanonicalFileURL.lexical(
                    vaultController.databaseURL
                )
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try validate()
    }

    func vaultRemovalIdentity(
        slackController: SlackAppController,
        vaultController: VaultController
    ) throws -> (
        URL,
        P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot
    ) {
        try validateApplicationDependencies(
            slackController: slackController,
            vaultController: vaultController
        )
        guard let vaultDatabaseURL,
              let vaultSQLiteIdentity,
              !vaultFamilyExpectedAbsent
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        return (vaultDatabaseURL, vaultSQLiteIdentity)
    }

    func recordVaultFamilyRemoved(
        at databaseURL: URL,
        matching _:
            P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot
    ) throws {
        guard self.vaultDatabaseURL
                == LokiCanonicalFileURL.lexical(databaseURL),
              vaultSQLiteIdentity != nil,
              !vaultFamilyExpectedAbsent
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try storageBoundary.validateSQLiteFamilyAbsent(
                at: databaseURL
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        vaultSQLiteIdentity = nil
        vaultFamilyExpectedAbsent = true
    }
}

/// The only dependency route accepted by a file-backed signed-smoke feature
/// controller. Construction freezes the exact admitted LocalStore object and
/// SQLite-family identity; every package-backed source read revalidates them.
@MainActor
final class P8FSignedSmokeDependencyPackage {
    private let boundaryGuard:
        P8FSignedSmokeDependencyBoundaryGuard
    let sourceRegistry: P8FSignedSmokeSourceRegistry
    let embeddingProvider: any P8EmbeddingProviding
    let nativeEmbeddingProvider: NativeOllamaEmbeddingProvider?
    let semanticSourcePreparationBudget:
        P8SemanticSourcePreparationBudget
    let semanticBuildSourceSelectionStore:
        P8FSignedSmokeSemanticBuildSourceSelectionStore
    let semanticSourceAuthorityReceiptStore:
        P8FSignedSmokeSemanticSourceAuthorityReceiptStore
    let semanticSourceAuthorityEventSink:
        P8SemanticSourceAuthorityEventSink
    private let credentialCapability:
        P8FSignedSmokeVolatileCredentialCapability
    var webCredentialStore: any OllamaWebResearchCredentialStoring {
        credentialCapability
    }
    let webResearchProvider: any P8OllamaWebResearchProviding
    let inertToolDataSource: P8FSignedSmokeInertToolDataSource
    let chatProvider: NativeOllamaChatProvider
    let chatContextBuilder: AgentLokiContextBuilder
    let chatTraceSink: OllamaChatTraceSink
    let chatEvidenceScrubPreflight:
        @MainActor () throws -> Void
    let applicationSlackController: SlackAppController?
    let applicationVaultController: VaultController?
    let applicationBriefingEngine: any BriefingEngine
    let applicationFeedClient: any FeedRetrieving
    let applicationFeedEngine: DeterministicFeedBriefingEngine
    let applicationMixedEngine: DeterministicMixedBriefingEngine
    let applicationOllamaProvider: NativeOllamaProvider
    let applicationOllamaSynchronizationEventSink:
        OllamaRuntimeSynchronizationSink
    let applicationCurrentCivilDayProvider: () -> LocalCalendarDay
    private let semanticIndexConstructionIssuer:
        P8FSignedSmokeSemanticIndexConstructionIssuer
    private let controlTreeURL: URL
    private var controlTreeIdentity:
        P8FSignedSmokeStorageBoundary.DirectoryIdentitySnapshot?
    private var controlTreeExpectedAbsent = false
    private let vaultExportStagingURL: URL?
    private var vaultExportStagingIdentity:
        P8FSignedSmokeStorageBoundary.DirectoryIdentitySnapshot?
    private var vaultExportStagingExpectedAbsent: Bool
    private var semanticIndexIdentity: ObjectIdentifier?
    private var semanticDatabaseURL: URL?
    private var semanticSQLiteIdentity:
        P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot?
    private var semanticFamilyExpectedAbsent = false

    private init(
        store: LocalStore,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority,
        sourceRegistryMode: P8FSignedSmokeSourceRegistryMode,
        contractVersionOverrides:
            [SemanticIndexSourceKind: String],
        embeddingCapability: P8FSignedSmokeEmbeddingCapability,
        applicationVaultDatabaseURL: URL?
    ) throws {
        let requiredBoundaryStorageURL =
            applicationVaultDatabaseURL == nil
            ? nil
            : storageBoundary.rootURL.appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureStoreFilename,
                isDirectory: false
            )
        let boundaryGuard = try P8FSignedSmokeDependencyBoundaryGuard(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority,
            requiredBoundaryStorageURL: requiredBoundaryStorageURL
        )
        self.boundaryGuard = boundaryGuard
        semanticIndexConstructionIssuer =
            P8FSignedSmokeSemanticIndexConstructionIssuer()
        let resolvedControlTreeURL = storageBoundary.rootURL
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.controlDirectoryName,
                isDirectory: true
            )
        controlTreeURL = resolvedControlTreeURL
        do {
            if let identity = try storageBoundary
                .captureDirectoryIdentityIfPresent(
                    at: resolvedControlTreeURL
                )
            {
                try storageBoundary.validatePrivateTree(
                    at: resolvedControlTreeURL
                )
                try storageBoundary.validateDirectoryIdentity(
                    identity,
                    at: resolvedControlTreeURL
                )
                controlTreeIdentity = identity
                controlTreeExpectedAbsent = false
            } else {
                controlTreeIdentity = nil
                controlTreeExpectedAbsent = true
            }
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        if let applicationVaultDatabaseURL {
            let slackController = SlackAppController(
                store: store,
                clientID: nil,
                credentialStore: VolatileSlackCredentialStore(),
                eventSink: { _ in }
            )
            let vaultController = try VaultController(
                store: store,
                slackController: slackController,
                databaseURL: applicationVaultDatabaseURL,
                entitlementProvider:
                    P8FSignedSmokeUnavailableEntitlementProvider()
            )
            try storageBoundary.secureSQLiteFamily(
                at: applicationVaultDatabaseURL,
                requireDatabase: true
            )
            try boundaryGuard.bindApplicationDependencies(
                slackController: slackController,
                vaultController: vaultController
            )
            let stagingURL = LokiCanonicalFileURL.lexical(
                VaultPaths.exportStagingDirectory(
                    for: applicationVaultDatabaseURL
                ),
                isDirectory: true
            )
            vaultExportStagingURL = stagingURL
            do {
                if let identity = try storageBoundary
                    .captureDirectoryIdentityIfPresent(at: stagingURL)
                {
                    try storageBoundary.validatePrivateTree(at: stagingURL)
                    try storageBoundary.validateDirectoryIdentity(
                        identity,
                        at: stagingURL
                    )
                    vaultExportStagingIdentity = identity
                    vaultExportStagingExpectedAbsent = false
                } else {
                    vaultExportStagingIdentity = nil
                    vaultExportStagingExpectedAbsent = true
                }
            } catch {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            applicationSlackController = slackController
            applicationVaultController = vaultController
        } else {
            vaultExportStagingURL = nil
            vaultExportStagingIdentity = nil
            vaultExportStagingExpectedAbsent = false
            applicationSlackController = nil
            applicationVaultController = nil
        }
        sourceRegistry = P8FSignedSmokeSourceRegistry(
            store: store,
            mode: sourceRegistryMode,
            contractVersionOverrides: contractVersionOverrides,
            boundaryRevalidator: {
                try boundaryGuard.validate()
            }
        )
        switch embeddingCapability {
        case .native:
            let native = NativeOllamaEmbeddingProvider()
            embeddingProvider = native
            nativeEmbeddingProvider = native
        case let .counting(counting):
            embeddingProvider = counting
            nativeEmbeddingProvider = nil
        }
        semanticSourcePreparationBudget = .production
        semanticBuildSourceSelectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: storageBoundary.rootURL
            )
        semanticSourceAuthorityReceiptStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: storageBoundary.rootURL
            )
        semanticSourceAuthorityEventSink = { _ in }
        credentialCapability =
            P8FSignedSmokeVolatileCredentialCapability()
        webResearchProvider =
            P8FSignedSmokeDisabledWebResearchProvider()
        inertToolDataSource = P8FSignedSmokeInertToolDataSource()
        chatProvider = NativeOllamaChatProvider()
        chatContextBuilder = AgentLokiContextBuilder()
        chatTraceSink = { _ in }
        chatEvidenceScrubPreflight = {}
        applicationBriefingEngine = DeterministicBriefingEngine()
        applicationFeedClient = P8FSignedSmokeDisabledFeedClient()
        applicationFeedEngine = DeterministicFeedBriefingEngine()
        applicationMixedEngine = DeterministicMixedBriefingEngine()
        applicationOllamaProvider = NativeOllamaProvider()
        applicationOllamaSynchronizationEventSink = { _ in }
        applicationCurrentCivilDayProvider = {
            LocalCalendarDay.resolve(
                containing: P8FSignedSmokeFixtureSeeder.anchor
            )
        }
        try boundaryGuard.validate(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority
        )
    }

    static func makeAppOwned(
        store: LocalStore,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority,
        sourceRegistryMode:
            P8FSignedSmokeSourceRegistryMode = .normal,
        contractVersionOverrides:
            [SemanticIndexSourceKind: String] = [:],
        embeddingCapability:
            P8FSignedSmokeEmbeddingCapability = .native
    ) throws -> P8FSignedSmokeDependencyPackage {
        try .init(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority,
            sourceRegistryMode: sourceRegistryMode,
            contractVersionOverrides: contractVersionOverrides,
            embeddingCapability: embeddingCapability,
            applicationVaultDatabaseURL: nil
        )
    }

    static func makeApplicationOwned(
        store: LocalStore,
        vaultDatabaseURL: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws -> P8FSignedSmokeDependencyPackage {
        let package = try P8FSignedSmokeDependencyPackage(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority,
            sourceRegistryMode: .normal,
            contractVersionOverrides: [:],
            embeddingCapability: .native,
            applicationVaultDatabaseURL: vaultDatabaseURL
        )
        guard let vaultController = package.applicationVaultController
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try vaultController.installSignedSmokeDependencyPackage(
            package,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority
        )
        return package
    }

#if DEBUG
    /// Explicit XCTest-only access for fixture adapter unit tests. The raw
    /// registry initializer remains file-private and ordinary app or
    /// signed-smoke runtime construction cannot mint this authority.
    static func makeXCTestSourceRegistry(
        store: LocalStore,
        mode: P8FSignedSmokeSourceRegistryMode = .normal,
        contractVersionOverrides:
            [SemanticIndexSourceKind: String] = [:]
    ) throws -> P8FSignedSmokeSourceRegistry {
        _ = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        return P8FSignedSmokeSourceRegistry(
            store: store,
            mode: mode,
            contractVersionOverrides: contractVersionOverrides,
            boundaryRevalidator: nil
        )
    }
#endif

    func validate(
        store: LocalStore,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws {
        try boundaryGuard.validate(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority
        )
    }

    func revalidateBoundary() throws {
        try boundaryGuard.validate()
    }

    var admittedApplicationStore: LocalStore {
        boundaryGuardStore
    }

    var admittedStorageBoundary: P8FSignedSmokeStorageBoundary {
        boundaryGuardStorageBoundary
    }

    var admittedRuntimeAuthority: P8FSignedSmokeRuntimeAuthority {
        boundaryGuardRuntimeAuthority
    }

    /// Atomically issues and binds the only file-backed semantic index accepted
    /// by this package. No authority-bearing index is returned during an
    /// unbound issuance window.
    func makeAndBindSemanticIndex(
        at databaseURL: URL,
        profile:
            P8FSignedSmokeSemanticIndexConstructionProfile = .runtime
    ) throws -> SemanticVaultIndex {
        try boundaryGuard.validate()
#if DEBUG
        if profile
            == .replaceDirectoryBeforeSuccessorPublicationForIntegrityDiagnostic
        {
            do {
                _ = try P8FSignedSmokeRuntimeAuthority
                    .makeXCTestInMemory()
            } catch {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
        }
#endif
        let canonical = LokiCanonicalFileURL.lexical(databaseURL)
        let isInitialBinding = semanticIndexIdentity == nil
            && semanticDatabaseURL == nil
            && semanticSQLiteIdentity == nil
            && !semanticFamilyExpectedAbsent
        let isAuthorizedReplacement = semanticIndexIdentity == nil
            && semanticDatabaseURL == canonical
            && semanticSQLiteIdentity == nil
            && semanticFamilyExpectedAbsent
        guard isInitialBinding || isAuthorizedReplacement else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        if isAuthorizedReplacement {
            try requireSemanticFamilyExpectedAbsent(at: canonical)
        }
        do {
            try boundaryGuardStorageBoundary.validateSQLiteFamily(
                at: canonical,
                requireDatabase: false
            )
            let constructionAuthority =
                P8FSignedSmokeSemanticIndexConstructionAuthority(
                    storageBoundary: boundaryGuardStorageBoundary,
                    runtimeAuthority: boundaryGuardRuntimeAuthority,
                    issuer: semanticIndexConstructionIssuer,
                    profile: profile
                )
            let index = try SemanticVaultIndex(
                signedSmokeURL: canonical,
                constructionAuthority: constructionAuthority
            )
            try boundaryGuardStorageBoundary.secureSQLiteFamily(
                at: canonical,
                requireDatabase: true
            )
            try index.validateSignedSmokeConstructionAuthority(
                issuer: semanticIndexConstructionIssuer,
                runtimeAuthority: boundaryGuardRuntimeAuthority
            )
            try bindSemanticIndex(index, databaseURL: canonical)
            return index
        } catch let failure as SemanticIndexFailureCode {
            throw failure
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    /// Deletes only the exact control-tree directory captured when this
    /// package was constructed. A same-path successor is preserved and makes
    /// the old cleanup authority fail closed.
    func removeBoundControlTree(
        fileManager: FileManager = .default
    ) throws {
        try boundaryGuard.validate()
        if controlTreeExpectedAbsent {
            do {
                guard try boundaryGuardStorageBoundary
                    .captureDirectoryIdentityIfPresent(
                        at: controlTreeURL
                    ) == nil
                else {
                    throw SemanticIndexFailureCode
                        .signedSmokeAuthorityInvalid
                }
            } catch {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            return
        }
        guard let controlTreeIdentity else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try boundaryGuardStorageBoundary.removePrivateTree(
                at: controlTreeURL,
                matching: controlTreeIdentity,
                fileManager: fileManager
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        guard !fileManager.fileExists(atPath: controlTreeURL.path)
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        self.controlTreeIdentity = nil
        controlTreeExpectedAbsent = true
    }

    func validateApplicationDependencies(
        store: LocalStore,
        slackController: SlackAppController,
        vaultController: VaultController,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws {
        try validate(
            store: store,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority
        )
        guard applicationSlackController === slackController,
              applicationVaultController === vaultController
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try boundaryGuard.validateApplicationDependencies(
            slackController: slackController,
            vaultController: vaultController
        )
    }

    func clearBoundSemanticAuthorityStores() throws {
        try boundaryGuard.validate()
        try semanticBuildSourceSelectionStore.clear()
        try semanticSourceAuthorityReceiptStore.clear()
        try validateBoundSemanticAuthorityStoresAreEmpty()
    }

    func validateBoundSemanticAuthorityStoresAreEmpty() throws {
        try boundaryGuard.validate()
        guard try semanticBuildSourceSelectionStore.load() == nil,
              try semanticSourceAuthorityReceiptStore.load().isEmpty
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    private func bindSemanticIndex(
        _ index: SemanticVaultIndex,
        databaseURL: URL
    ) throws {
        try boundaryGuard.validate()
        try index.validateSignedSmokeConstructionAuthority(
            issuer: semanticIndexConstructionIssuer,
            runtimeAuthority: boundaryGuardRuntimeAuthority
        )
        let canonical = LokiCanonicalFileURL.lexical(databaseURL)
        let isInitialBinding = semanticIndexIdentity == nil
            && semanticDatabaseURL == nil
            && semanticSQLiteIdentity == nil
            && !semanticFamilyExpectedAbsent
        let isAuthorizedReplacement = semanticIndexIdentity == nil
            && semanticDatabaseURL == canonical
            && semanticSQLiteIdentity == nil
            && semanticFamilyExpectedAbsent
        guard index.persistentDatabaseURL == canonical,
              isInitialBinding || isAuthorizedReplacement
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try boundaryGuardStorageBoundary.validateSQLiteFamily(
                at: canonical,
                requireDatabase: true
            )
            semanticSQLiteIdentity = try boundaryGuardStorageBoundary
                .captureSQLiteIdentity(at: canonical)
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        semanticIndexIdentity = ObjectIdentifier(index)
        semanticDatabaseURL = canonical
        semanticFamilyExpectedAbsent = false
    }

    func validateSemanticIndex(
        _ index: SemanticVaultIndex
    ) throws {
        guard semanticIndexIdentity == ObjectIdentifier(index),
              let semanticDatabaseURL,
              let semanticSQLiteIdentity,
              index.persistentDatabaseURL == semanticDatabaseURL,
              !semanticFamilyExpectedAbsent
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try boundaryGuard.validate()
        try index.validateSignedSmokeRuntimeAuthority(
            boundaryGuardRuntimeAuthority
        )
        try index.validateSignedSmokeConstructionAuthority(
            issuer: semanticIndexConstructionIssuer,
            runtimeAuthority: boundaryGuardRuntimeAuthority
        )
        do {
            try boundaryGuardStorageBoundary.validateSQLiteIdentity(
                semanticSQLiteIdentity,
                at: semanticDatabaseURL
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    func removeSemanticIndexFamily(
        _ index: SemanticVaultIndex,
        at databaseURL: URL
    ) async throws {
        try validateSemanticIndex(index)
        guard let expectedURL = semanticDatabaseURL,
              let identity = semanticSQLiteIdentity,
              expectedURL == LokiCanonicalFileURL.lexical(databaseURL)
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        await index.close()
        do {
            try boundaryGuardStorageBoundary.removeSQLiteFamily(
                at: expectedURL,
                matching: identity
            )
            try boundaryGuardStorageBoundary
                .validateSQLiteFamilyAbsent(at: expectedURL)
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        semanticIndexIdentity = nil
        semanticSQLiteIdentity = nil
        semanticFamilyExpectedAbsent = true
    }

    func requireSemanticFamilyExpectedAbsent(
        at databaseURL: URL
    ) throws {
        let canonical = LokiCanonicalFileURL.lexical(databaseURL)
        guard semanticFamilyExpectedAbsent,
              semanticDatabaseURL == canonical,
              semanticIndexIdentity == nil,
              semanticSQLiteIdentity == nil
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try boundaryGuardStorageBoundary
                .validateSQLiteFamilyAbsent(at: canonical)
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    func removeVaultFamily(
        for vaultController: VaultController
    ) async throws {
        guard let slackController = applicationSlackController,
              applicationVaultController === vaultController
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let (databaseURL, primaryIdentity) = try boundaryGuard
            .vaultRemovalIdentity(
                slackController: slackController,
                vaultController: vaultController
            )
        try await vaultController.signedSmokeCloseDatabaseForCleanup()
        do {
            let closedIdentity = try boundaryGuardStorageBoundary
                .captureClosedSQLiteIdentity(
                    at: databaseURL,
                    matchingPrimary: primaryIdentity
                )
            try boundaryGuardStorageBoundary.removeSQLiteFamily(
                at: databaseURL,
                matching: closedIdentity
            )
            try boundaryGuardStorageBoundary
                .validateSQLiteFamilyAbsent(at: databaseURL)
            try boundaryGuard.recordVaultFamilyRemoved(
                at: databaseURL,
                matching: closedIdentity
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    func removeVaultExportStagingIfPresent(
        for vaultController: VaultController
    ) throws {
        guard let slackController = applicationSlackController,
              applicationVaultController === vaultController
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try boundaryGuard.validateApplicationDependencies(
            slackController: slackController,
            vaultController: vaultController
        )
        guard let vaultExportStagingURL,
              vaultExportStagingURL == LokiCanonicalFileURL.lexical(
                VaultPaths.exportStagingDirectory(
                    for: vaultController.databaseURL
                ),
                isDirectory: true
              )
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        if vaultExportStagingExpectedAbsent {
            do {
                guard try boundaryGuardStorageBoundary
                    .captureDirectoryIdentityIfPresent(
                        at: vaultExportStagingURL
                    ) == nil
                else {
                    throw SemanticIndexFailureCode
                        .signedSmokeAuthorityInvalid
                }
            } catch {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            return
        }
        guard let vaultExportStagingIdentity else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try boundaryGuardStorageBoundary.removePrivateTree(
                at: vaultExportStagingURL,
                matching: vaultExportStagingIdentity
            )
            guard try boundaryGuardStorageBoundary
                .captureDirectoryIdentityIfPresent(
                    at: vaultExportStagingURL
                ) == nil
            else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        self.vaultExportStagingIdentity = nil
        vaultExportStagingExpectedAbsent = true
    }

    private var boundaryGuardStore: LocalStore {
        boundaryGuard.boundStore
    }

    private var boundaryGuardRuntimeAuthority:
        P8FSignedSmokeRuntimeAuthority
    {
        boundaryGuard.boundRuntimeAuthority
    }

    private var boundaryGuardStorageBoundary:
        P8FSignedSmokeStorageBoundary
    {
        boundaryGuard.boundStorageBoundary
    }

    func credentialCounters()
        async -> P8FSignedSmokeVolatileCredentialCounters
    {
        await credentialCapability.snapshot()
    }
}

@MainActor
final class P8FSignedSmokeSourceRegistry {
    private let store: LocalStore
    private let mode: P8FSignedSmokeSourceRegistryMode
    private let contractVersionOverrides:
        [SemanticIndexSourceKind: String]
    private let boundaryRevalidator:
        (@MainActor () throws -> Void)?
    private var invocations:
        [SemanticIndexSourceKind: Int] = [:]
    private var recordsRead:
        [SemanticIndexSourceKind: Int] = [:]
    private var blockedSourceKind: SemanticIndexSourceKind?
    private var blockedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation:
        CheckedContinuation<Void, Never>?

    fileprivate init(
        store: LocalStore,
        mode: P8FSignedSmokeSourceRegistryMode = .normal,
        contractVersionOverrides:
            [SemanticIndexSourceKind: String] = [:],
        boundaryRevalidator:
            (@MainActor () throws -> Void)? = nil
    ) {
        self.store = store
        self.mode = mode
        self.contractVersionOverrides =
            contractVersionOverrides
        self.boundaryRevalidator = boundaryRevalidator
    }

    func providers() -> [P8SemanticSourceProvider] {
        SemanticIndexSourceKind.allCases.map { kind in
            .init(
                sourceKind: kind,
                contractVersion: contractVersion(for: kind)
            ) {
                try await self.records(for: kind)
            }
        }
    }

    func counters() -> [P8FSignedSmokeSourceCounter] {
        SemanticIndexSourceKind.allCases.map {
            .init(
                sourceKind: $0,
                adapterInvocations: invocations[$0] ?? 0,
                recordsRead: recordsRead[$0] ?? 0
            )
        }
    }

    func waitUntilBlocked(
        sourceKind: SemanticIndexSourceKind
    ) async throws {
        if blockedSourceKind == sourceKind {
            try Task.checkCancellation()
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                blockedWaiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelBlockedWaitAndReleaseProvider()
            }
        }
        try Task.checkCancellation()
    }

    func releaseBlockedProvider() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func cancelBlockedWaitAndReleaseProvider() {
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        releaseBlockedProvider()
    }

    private func records(
        for kind: SemanticIndexSourceKind
    ) async throws -> [SemanticIndexSourceRecord] {
        try boundaryRevalidator?()
        invocations[kind, default: 0] += 1
        if mode == .blockBeforeRead(kind) {
            blockedSourceKind = kind
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.releaseBlockedProvider()
                }
            }
            try Task.checkCancellation()
        }
        try boundaryRevalidator?()
        let records: [SemanticIndexSourceRecord]
        switch kind {
        case .brief:
            records = try P8SemanticSourceAdapter.briefRecords(
                from: store
            )
        case .schedule:
            records = try P8SemanticSourceAdapter.scheduleRecords(
                from: store
            )
        case .chatMessage:
            records =
                try P8SemanticSourceAdapter.chatFinalMessageRecords(
                    from: store
                )
        case .vaultRecord, .slackRecord, .connectorRecord:
            records = [try excludedCanaryRecord(kind: kind)]
        }
        let effectiveRecords: [SemanticIndexSourceRecord]
        if case let .adapterKindDrift(expected, actual) = mode,
           expected == kind,
           let first = records.first {
            effectiveRecords = [
                try .init(
                    stableSourceIdentifier:
                        first.stableSourceIdentifier,
                    sourceKind: actual,
                    sourceTimestamp: first.sourceTimestamp,
                    text: first.text,
                    sourceHash:
                        SemanticIndexSourceRecord
                            .deterministicSourceHash(
                                stableSourceIdentifier:
                                    first.stableSourceIdentifier,
                                sourceKind: actual,
                                sourceTimestamp:
                                    first.sourceTimestamp,
                                text: first.text
                            ),
                    isTombstone: first.isTombstone,
                    privacyClassification:
                        first.privacyClassification,
                    provenance: first.provenance
                ),
            ] + Array(records.dropFirst())
        } else {
            effectiveRecords = records
        }
        recordsRead[kind, default: 0] +=
            effectiveRecords.count
        return effectiveRecords
    }

    private func contractVersion(
        for kind: SemanticIndexSourceKind
    ) -> String {
        if let override = contractVersionOverrides[kind] {
            return override
        }
        switch kind {
        case .brief:
            return P8SemanticSourceAdapter.briefContractVersion
        case .schedule:
            return P8SemanticSourceAdapter.scheduleContractVersion
        case .chatMessage:
            return P8SemanticSourceAdapter
                .chatFinalMessageContractVersion
        case .slackRecord:
            return P8SemanticSourceAdapter.slackContractVersion
        case .vaultRecord:
            return "p8f.smoke.excluded-vault.v1"
        case .connectorRecord:
            return "p8f.smoke.excluded-connector.v1"
        }
    }

    private func excludedCanaryRecord(
        kind: SemanticIndexSourceKind
    ) throws -> SemanticIndexSourceRecord {
        let identifier = "p8f-excluded-\(kind.rawValue)"
        let text =
            "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY_7ED9DCD9"
        return try .init(
            stableSourceIdentifier: identifier,
            sourceKind: kind,
            sourceTimestamp:
                P8FSignedSmokeFixtureSeeder.anchor,
            text: text,
            sourceHash:
                SemanticIndexSourceRecord.deterministicSourceHash(
                    stableSourceIdentifier: identifier,
                    sourceKind: kind,
                    sourceTimestamp:
                        P8FSignedSmokeFixtureSeeder.anchor,
                    text: text
                ),
            provenance: .init(
                provider: "p8f_signed_smoke",
                provenanceReceiptHash:
                    SemanticIndexDigest.sha256(
                        "p8f-excluded-\(kind.rawValue)-provenance"
                    )
            )
        )
    }
}

struct P8FSignedSmokeHydrationSnapshot:
    Equatable,
    Sendable
{
    let userVersion: Int
    let generationIdentifier: String
    let sourceCount: Int
    let chunkCount: Int
    let tombstoneCount: Int
    let vectorBlobSHA256: String
    let sourceBindingSHA256: String
    let highWatermarkSHA256: String
}

enum P8FSignedSmokeHydrationFixtureFactory {
    static func downgradeToLegacyV2(
        databaseURL: URL,
        isolatedRoot: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        active: SemanticIndexGenerationMetadata,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeHydrationSnapshot {
        try validateDatabaseURL(
            databaseURL,
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        guard active.state == .ready,
              active.sourceAuthorityState
                == .sourceScopeReady,
              active.spec.buildScope != nil,
              active.tombstoneCount == 0
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        let legacyFingerprint =
            legacySchemaV2Fingerprint(active.spec)
        let sourceBindings =
            active.sourceRecordHashes.mapValues {
                "\($0)|available"
            }
        let legacyManifest = legacyBindingDigest(
            configurationFingerprint:
                legacyFingerprint,
            sourceBindings: sourceBindings,
            highWatermarks:
                active.sourceHighWatermarks
        )

        try withDatabase(
            at: databaseURL,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        ) { database in
            try execute(
                database,
                sql: "PRAGMA foreign_keys = OFF"
            )
            try execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try execute(
                    database,
                    sql: """
                        CREATE TABLE semantic_generations_v2(
                            id TEXT PRIMARY KEY,
                            index_schema_version INTEGER NOT NULL,
                            retrieval_capability TEXT NOT NULL
                                CHECK(retrieval_capability IN (
                                    'lexical_only','hybrid'
                                )),
                            embedding_model_identifier TEXT,
                            embedding_model_digest TEXT,
                            vector_dimension INTEGER,
                            ollama_runtime_version TEXT,
                            embedding_request_profile_version TEXT,
                            embedding_request_profile_hash TEXT,
                            embedding_dimensions INTEGER,
                            embedding_truncate INTEGER,
                            embedding_normalization_version TEXT,
                            chunker_version TEXT NOT NULL,
                            normalization_version TEXT NOT NULL,
                            source_schema_version TEXT NOT NULL,
                            configuration_fingerprint TEXT NOT NULL,
                            created_at INTEGER NOT NULL,
                            state TEXT NOT NULL,
                            stale_reason TEXT,
                            source_manifest_digest TEXT NOT NULL
                        ) STRICT
                        """
                )
                try execute(
                    database,
                    sql: """
                        INSERT INTO semantic_generations_v2(
                            id, index_schema_version,
                            retrieval_capability,
                            embedding_model_identifier,
                            embedding_model_digest,
                            vector_dimension,
                            ollama_runtime_version,
                            embedding_request_profile_version,
                            embedding_request_profile_hash,
                            embedding_dimensions,
                            embedding_truncate,
                            embedding_normalization_version,
                            chunker_version,
                            normalization_version,
                            source_schema_version,
                            configuration_fingerprint,
                            created_at, state, stale_reason,
                            source_manifest_digest
                        )
                        SELECT id, 2, retrieval_capability,
                               embedding_model_identifier,
                               embedding_model_digest,
                               vector_dimension,
                               ollama_runtime_version,
                               embedding_request_profile_version,
                               embedding_request_profile_hash,
                               embedding_dimensions,
                               embedding_truncate,
                               embedding_normalization_version,
                               chunker_version,
                               normalization_version,
                               source_schema_version,
                               ?, created_at, state,
                               CASE
                                   WHEN stale_reason IN (
                                       'semantic_index_embedding_runtime_profile_stale',
                                       'semantic_index_canonical_source_policy_stale'
                                   )
                                   THEN stale_reason
                                   ELSE NULL
                               END,
                               ?
                        FROM semantic_generations
                        """,
                    textBinds: [
                        legacyFingerprint,
                        legacyManifest,
                    ]
                )
                try createLegacyCheckpointTable(database)
                try execute(
                    database,
                    sql: """
                        INSERT INTO semantic_checkpoints_v2(
                            run_id, generation_id, stream_id,
                            state, current_cursor, next_cursor,
                            source_high_watermark,
                            batches_committed, records_seen,
                            records_committed,
                            records_unchanged,
                            records_excluded,
                            tombstones_committed,
                            chunks_committed,
                            pending_chunk_count, updated_at
                        )
                        SELECT run_id, generation_id, stream_id,
                               state, current_cursor, next_cursor,
                               source_high_watermark,
                               batches_committed, records_seen,
                               records_committed,
                               records_unchanged,
                               records_excluded,
                               tombstones_committed,
                               chunks_committed,
                               pending_chunk_count, updated_at
                        FROM semantic_checkpoints
                        """
                )
                try execute(
                    database,
                    sql: "DROP TABLE semantic_checkpoints"
                )
                try execute(
                    database,
                    sql: "DROP TABLE semantic_generations"
                )
                try execute(
                    database,
                    sql: """
                        ALTER TABLE semantic_generations_v2
                        RENAME TO semantic_generations
                        """
                )
                try execute(
                    database,
                    sql: """
                        ALTER TABLE semantic_checkpoints_v2
                        RENAME TO semantic_checkpoints
                        """
                )
                try execute(
                    database,
                    sql: "PRAGMA user_version = 2"
                )
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
            try execute(
                database,
                sql: "PRAGMA foreign_keys = ON"
            )
            guard try scalarText(
                database,
                sql: "PRAGMA quick_check(1)"
            ) == "ok",
            try foreignKeysAreValid(database)
            else {
                throw SemanticIndexFailureCode
                    .databaseCorrupt
            }
        }
        let observed = try snapshot(
            databaseURL: databaseURL,
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        guard observed.userVersion == 2,
              observed.generationIdentifier
                == active.identifier,
              observed.sourceCount == active.sourceCount,
              observed.chunkCount == active.chunkCount,
              observed.tombstoneCount
                == active.tombstoneCount
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        return observed
    }

    static func corruptLegacyConfigurationFingerprint(
        databaseURL: URL,
        isolatedRoot: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        generationIdentifier: String,
        fileManager: FileManager = .default
    ) throws {
        try validateDatabaseURL(
            databaseURL,
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        try withDatabase(
            at: databaseURL,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        ) { database in
            try execute(
                database,
                sql: """
                    UPDATE semantic_generations
                    SET configuration_fingerprint = ?
                    WHERE id = ?
                    """,
                textBinds: [
                    String(repeating: "0", count: 64),
                    generationIdentifier,
                ]
            )
            guard sqlite3_changes(database) == 1 else {
                throw SemanticIndexFailureCode
                    .databaseCorrupt
            }
        }
    }

    static func snapshot(
        databaseURL: URL,
        isolatedRoot: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeHydrationSnapshot {
        try validateDatabaseURL(
            databaseURL,
            isolatedRoot: isolatedRoot,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        )
        return try withDatabase(
            at: databaseURL,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        ) {
            database in
            guard let generationIdentifier =
                    try scalarText(
                        database,
                        sql: """
                            SELECT value
                            FROM semantic_metadata
                            WHERE key = 'active_generation'
                            """
                    ),
                  let userVersion =
                    try scalarInteger(
                        database,
                        sql: "PRAGMA user_version"
                    ),
                  let sourceCount =
                    try scalarInteger(
                        database,
                        sql: """
                            SELECT count(*)
                            FROM semantic_sources
                            WHERE generation_id = ?
                            """,
                        textBinds: [
                            generationIdentifier,
                        ]
                    ),
                  let chunkCount =
                    try scalarInteger(
                        database,
                        sql: """
                            SELECT count(*)
                            FROM semantic_chunks
                            WHERE generation_id = ?
                            """,
                        textBinds: [
                            generationIdentifier,
                        ]
                    ),
                  let tombstoneCount =
                    try scalarInteger(
                        database,
                        sql: """
                            SELECT count(*)
                            FROM semantic_sources
                            WHERE generation_id = ?
                              AND tombstoned = 1
                            """,
                        textBinds: [
                            generationIdentifier,
                        ]
                    )
            else {
                throw SemanticIndexFailureCode
                    .databaseCorrupt
            }
            var vectorBytes = Data()
            try query(
                database,
                sql: """
                    SELECT vector
                    FROM semantic_chunks
                    WHERE generation_id = ?
                    ORDER BY chunk_id
                    """,
                textBinds: [generationIdentifier]
            ) { statement in
                let byteCount = Int(
                    sqlite3_column_bytes(statement, 0)
                )
                var length = UInt64(byteCount).bigEndian
                withUnsafeBytes(of: &length) {
                    vectorBytes.append(
                        contentsOf: $0
                    )
                }
                if byteCount > 0,
                   let pointer = sqlite3_column_blob(
                       statement,
                       0
                   ) {
                    vectorBytes.append(
                        Data(
                            bytes: pointer,
                            count: byteCount
                        )
                    )
                }
            }
            let sourceBindings =
                try keyValueDigest(
                    database,
                    sql: """
                        SELECT source_id,
                               source_hash || '|' ||
                               CASE
                                   WHEN tombstoned = 1
                                   THEN 'tombstone'
                                   ELSE 'available'
                               END
                        FROM semantic_sources
                        WHERE generation_id = ?
                        ORDER BY source_id
                        """,
                    generationIdentifier:
                        generationIdentifier
                )
            let highWatermarks =
                try keyValueDigest(
                    database,
                    sql: """
                        SELECT stream_id, high_watermark
                        FROM semantic_high_watermarks
                        WHERE generation_id = ?
                        ORDER BY stream_id
                        """,
                    generationIdentifier:
                        generationIdentifier
                )
            return .init(
                userVersion: Int(userVersion),
                generationIdentifier:
                    generationIdentifier,
                sourceCount: Int(sourceCount),
                chunkCount: Int(chunkCount),
                tombstoneCount:
                    Int(tombstoneCount),
                vectorBlobSHA256:
                    P8FSignedSmokeDigest.sha256(
                        vectorBytes
                    ),
                sourceBindingSHA256:
                    sourceBindings,
                highWatermarkSHA256:
                    highWatermarks
            )
        }
    }

    private static func validateDatabaseURL(
        _ databaseURL: URL,
        isolatedRoot: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager
    ) throws {
        guard LokiCanonicalFileURL.lexical(
                isolatedRoot,
                isDirectory: true
              )
                == storageBoundary.rootURL
        else {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
        do {
            try storageBoundary.validateSQLiteFamily(
                at: databaseURL,
                requireDatabase: true,
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeFixtureFailure
                .fixtureStoreUnexpectedState
        }
    }

    private static func legacySchemaV2Fingerprint(
        _ spec: SemanticIndexGenerationSpec
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "2",
                spec.retrievalCapability.rawValue,
                spec.embeddingModelIdentifier ?? "",
                spec.embeddingModelDigest ?? "",
                spec.vectorDimension.map(String.init)
                    ?? "",
                spec.ollamaRuntimeVersion ?? "",
                spec.embeddingRequestProfileVersion
                    ?? "",
                spec.embeddingRequestProfileHash ?? "",
                spec.embeddingDimensions.map(String.init)
                    ?? "model_default",
                spec.embeddingTruncate.map {
                    $0 ? "true" : "false"
                } ?? "",
                spec.embeddingNormalizationVersion
                    ?? "",
                spec.chunkerVersion,
                spec.normalizationVersion,
                spec.sourceSchemaVersion,
            ])
        )
    }

    private static func legacyBindingDigest(
        configurationFingerprint: String,
        sourceBindings: [String: String],
        highWatermarks: [String: String]
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "configuration",
                configurationFingerprint,
                "source_bindings",
                manifestDigest(sourceBindings),
                "source_high_watermarks",
                manifestDigest(highWatermarks),
            ])
        )
    }

    private static func manifestDigest(
        _ values: [String: String]
    ) -> String {
        SemanticIndexDigest.sha256(
            values.sorted { $0.key < $1.key }
                .map {
                    SemanticIndexDigest
                        .lengthPrefixed([
                            $0.key,
                            $0.value,
                        ])
                }.joined()
        )
    }

    private static func createLegacyCheckpointTable(
        _ database: OpaquePointer
    ) throws {
        try execute(
            database,
            sql: """
                CREATE TABLE semantic_checkpoints_v2(
                    run_id TEXT PRIMARY KEY,
                    generation_id TEXT NOT NULL
                        REFERENCES semantic_generations(id)
                        ON DELETE CASCADE,
                    stream_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'preparing','awaiting_embeddings',
                        'running','paused','cancelled',
                        'complete'
                    )),
                    current_cursor TEXT,
                    next_cursor TEXT,
                    source_high_watermark TEXT,
                    batches_committed INTEGER NOT NULL
                        CHECK(batches_committed >= 0),
                    records_seen INTEGER NOT NULL
                        CHECK(records_seen >= 0),
                    records_committed INTEGER NOT NULL
                        CHECK(records_committed >= 0),
                    records_unchanged INTEGER NOT NULL
                        CHECK(records_unchanged >= 0),
                    records_excluded INTEGER NOT NULL
                        CHECK(records_excluded >= 0),
                    tombstones_committed INTEGER NOT NULL
                        CHECK(tombstones_committed >= 0),
                    chunks_committed INTEGER NOT NULL
                        CHECK(chunks_committed >= 0),
                    pending_chunk_count INTEGER NOT NULL
                        CHECK(pending_chunk_count >= 0),
                    updated_at INTEGER NOT NULL
                ) STRICT
                """
        )
    }

    private static func keyValueDigest(
        _ database: OpaquePointer,
        sql: String,
        generationIdentifier: String
    ) throws -> String {
        var values: [String: String] = [:]
        try query(
            database,
            sql: sql,
            textBinds: [generationIdentifier]
        ) { statement in
            values[text(statement, 0)] =
                text(statement, 1)
        }
        return manifestDigest(values)
    }

    private static func foreignKeysAreValid(
        _ database: OpaquePointer
    ) throws -> Bool {
        var valid = true
        try query(
            database,
            sql: "PRAGMA foreign_key_check"
        ) { _ in
            valid = false
        }
        return valid
    }

    private static func withDatabase<T>(
        at url: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW,
            nil
        ) == SQLITE_OK,
        let database
        else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw SemanticIndexFailureCode
                .databaseOpenFailed
        }
        var databaseIsOpen = true
        defer {
            if databaseIsOpen {
                sqlite3_close_v2(database)
            }
        }
        guard sqlite3_busy_timeout(
            database,
            SemanticIndexLimits
                .busyTimeoutMilliseconds
        ) == SQLITE_OK
        else {
            throw SemanticIndexFailureCode
                .databaseBusy
        }
        let value: T
        do {
            value = try body(database)
        } catch {
            sqlite3_close_v2(database)
            databaseIsOpen = false
            try? storageBoundary.secureSQLiteFamily(
                at: url,
                requireDatabase: true,
                fileManager: fileManager
            )
            throw error
        }
        let closeResult = sqlite3_close_v2(database)
        guard closeResult == SQLITE_OK else {
            throw SemanticIndexFailureCode.databaseOpenFailed
        }
        databaseIsOpen = false
        try storageBoundary.secureSQLiteFamily(
            at: url,
            requireDatabase: true,
            fileManager: fileManager
        )
        return value
    }

    private static func execute(
        _ database: OpaquePointer,
        sql: String,
        textBinds: [String] = []
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else {
            throw SemanticIndexFailureCode.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        for (offset, value) in textBinds.enumerated() {
            guard sqlite3_bind_text(
                statement,
                Int32(offset + 1),
                value,
                -1,
                transient
            ) == SQLITE_OK else {
                throw SemanticIndexFailureCode
                    .sqliteFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE
        else {
            throw SemanticIndexFailureCode
                .sqliteFailure
        }
    }

    private static func query(
        _ database: OpaquePointer,
        sql: String,
        textBinds: [String] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
        else {
            throw SemanticIndexFailureCode.sqliteFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        for (offset, value) in textBinds.enumerated() {
            guard sqlite3_bind_text(
                statement,
                Int32(offset + 1),
                value,
                -1,
                transient
            ) == SQLITE_OK else {
                throw SemanticIndexFailureCode
                    .sqliteFailure
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw SemanticIndexFailureCode
                    .sqliteFailure
            }
        }
    }

    private static func scalarInteger(
        _ database: OpaquePointer,
        sql: String,
        textBinds: [String] = []
    ) throws -> Int64? {
        var value: Int64?
        try query(
            database,
            sql: sql,
            textBinds: textBinds
        ) {
            value = sqlite3_column_int64($0, 0)
        }
        return value
    }

    private static func scalarText(
        _ database: OpaquePointer,
        sql: String
    ) throws -> String? {
        var value: String?
        try query(database, sql: sql) {
            value = text($0, 0)
        }
        return value
    }

    private static func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String {
        guard let pointer =
                sqlite3_column_text(statement, column)
        else { return "" }
        return String(cString: pointer)
    }
}
