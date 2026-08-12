import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class LokiChatMigrationTests: XCTestCase, @unchecked Sendable {
    func testV7StoreMigratesAdditivelyToV8WithoutResettingExistingSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-v7-to-v8-chat-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV7.self)
            let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: storeURL)
            let legacy = try ModelContainer(
                for: schema,
                migrationPlan: LokiBriefMigrationPlanV7.self,
                configurations: [configuration]
            )
            legacy.mainContext.insert(
                StoredSettings(
                    preferredBriefingTime: Date(timeIntervalSince1970: 25_200),
                    launchAtLoginPreference: true,
                    notificationPreference: false,
                    density: .compact,
                    deterministicOnly: true
                )
            )
            try legacy.mainContext.save()
        }

        let migrated = try LocalStore(url: storeURL)
        XCTAssertEqual(try migrated.settings().density, .compact)
        XCTAssertTrue(try migrated.settings().launchAtLoginPreference)
        XCTAssertEqual(try migrated.lokiChatPrivacySettings(), .defaults)
        XCTAssertTrue(try migrated.lokiConversationPage().isEmpty)
        XCTAssertNil(try migrated.lokiChatModelSelection())
    }

    func testV8ReopenIsIdempotentAndPreservesFullAssessmentCurrentnessInputs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-v8-chat-idempotent-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assessedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let assessment = ModelCapabilityAssessment(
            provider: "ollama",
            providerVersion: "0.12.3",
            modelIdentifier: "bounded-synthetic",
            modelDigest: "sha256:abc123",
            capabilitiesProven: [
                .chat,
                .streaming,
                .structuredOutput,
                .toolCalling,
                .systemInstructions,
                .contextWindow,
                .cancellation,
            ],
            capabilitiesMissing: [.vision, .embedding, .webResearch],
            contextPolicy: ModelContextPolicy(
                declaredContextTokens: 131_072,
                empiricallyUsableContextTokens: 98_304,
                reservedOutputTokens: 4_096
            ),
            assessedAt: assessedAt,
            durationMilliseconds: 456,
            diagnostics: [
                .init(
                    probe: .ordinaryChat,
                    status: .success,
                    reasonCode: "ordinary_chat_passed",
                    durationMilliseconds: 40
                ),
                .init(
                    probe: .syntheticToolCall,
                    status: .success,
                    reasonCode: "synthetic_tool_call_passed",
                    durationMilliseconds: 81
                ),
            ]
        )
        let record = LokiModelAssessmentRecord(
            id: "ollama:bounded-synthetic",
            readiness: .ready,
            assessment: assessment
        )
        let selection = ChatModelSelection(
            provider: assessment.provider,
            modelIdentifier: assessment.modelIdentifier,
            modelDigest: assessment.modelDigest,
            assessmentVersion: assessment.assessmentVersion,
            selectedAt: assessedAt
        )

        do {
            let store = try LocalStore(url: storeURL)
            try store.upsertLokiModelAssessment(record)
            try store.saveLokiChatModelSelection(selection)
        }

        do {
            let reopened = try LocalStore(url: storeURL)
            let persisted = try XCTUnwrap(try reopened.lokiModelAssessments().first)
            XCTAssertEqual(persisted.readiness, .ready)
            XCTAssertEqual(persisted.assessment, assessment)
            XCTAssertEqual(persisted.providerVersion, "0.12.3")
            XCTAssertEqual(persisted.modelDigest, "sha256:abc123")
            XCTAssertEqual(
                persisted.assessment.contextPolicy.empiricallyUsableContextTokens,
                98_304
            )
            XCTAssertEqual(
                persisted.assessment.diagnostics.map(\.reasonCode),
                ["ordinary_chat_passed", "synthetic_tool_call_passed"]
            )
            let currentProfile = ModelProfile(
                provider: "ollama",
                providerVersion: "0.12.3",
                modelIdentifier: "bounded-synthetic",
                displayName: "Bounded synthetic",
                modelDigest: "sha256:abc123",
                locallyInstalled: true,
                estimatedCapabilities: [],
                contextPolicy: ModelContextPolicy(declaredContextTokens: 131_072),
                observedAt: assessedAt
            )
            XCTAssertTrue(persisted.assessment.isCurrent(for: currentProfile))
            XCTAssertFalse(persisted.assessment.isCurrent(for: ModelProfile(
                provider: currentProfile.provider,
                providerVersion: "0.12.4",
                modelIdentifier: currentProfile.modelIdentifier,
                displayName: currentProfile.displayName,
                modelDigest: currentProfile.modelDigest,
                locallyInstalled: true,
                estimatedCapabilities: [],
                contextPolicy: currentProfile.contextPolicy,
                observedAt: assessedAt
            )))
            XCTAssertFalse(persisted.assessment.isCurrent(for: ModelProfile(
                provider: currentProfile.provider,
                providerVersion: currentProfile.providerVersion,
                modelIdentifier: currentProfile.modelIdentifier,
                displayName: currentProfile.displayName,
                modelDigest: "sha256:changed",
                locallyInstalled: true,
                estimatedCapabilities: [],
                contextPolicy: currentProfile.contextPolicy,
                observedAt: assessedAt
            )))
            XCTAssertEqual(try reopened.lokiChatModelSelection(), selection)
        }

        let secondReopen = try LocalStore(url: storeURL)
        XCTAssertEqual(try secondReopen.lokiModelAssessments().count, 1)
        XCTAssertEqual(try secondReopen.lokiChatModelSelection(), selection)
    }
}
