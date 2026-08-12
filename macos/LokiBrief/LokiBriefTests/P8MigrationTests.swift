import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class P8MigrationTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_743_100_000)

    func testDisposableV8StoreMigratesToV9ReopensIdempotentlyAndPreservesGemma3Receipts() throws {
        let fixture = try makeFixtureDirectory(named: "p8-v8-to-v9-ready")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeV8Fixture(
            at: fixture.storeURL,
            includeReadyGemma4: true,
            includeReadyGPTOSS: true
        )

        var firstAssignments: [ModelRoleAssignment] = []
        do {
            let migrated = try LocalStore(url: fixture.storeURL)
            XCTAssertTrue(migrated.modelRoleMigrationReport.didRun)
            XCTAssertEqual(migrated.modelRoleMigrationReport.legacyGemma3PreferenceCount, 2)
            XCTAssertEqual(migrated.modelRoleMigrationReport.roleCount, 5)
            firstAssignments = try migrated.modelRoleAssignments()
            XCTAssertEqual(firstAssignments.count, ModelRole.allCases.count)
            XCTAssertEqual(
                try migrated.modelRoleAssignment(for: .primaryAgent)?
                    .effectiveModelIdentifier,
                "gemma4:12b"
            )
            XCTAssertEqual(
                try migrated.modelRoleAssignment(for: .vision)?
                    .effectiveModelIdentifier,
                "gemma4:12b"
            )
            XCTAssertEqual(
                try migrated.modelRoleAssignment(for: .textFallback)?
                    .effectiveModelIdentifier,
                "gpt-oss:20b"
            )
            XCTAssertEqual(
                try migrated.modelRoleAssignment(for: .briefSummary)?
                    .effectiveModelIdentifier,
                "gemma4:12b"
            )
            XCTAssertEqual(
                try migrated.modelRoleAssignment(for: .embedding)?.readiness,
                .modelUnavailable
            )
            let webDefaults = try migrated.ollamaWebResearchGlobalSettings()
            XCTAssertFalse(webDefaults.providerEnabled)
            XCTAssertFalse(webDefaults.externalNetworkDisclosureAccepted)

            XCTAssertEqual(
                try migrated.lokiChatModelSelection()?.modelIdentifier,
                "gemma4:12b"
            )
            XCTAssertEqual(try migrated.modelSelection().modelID, "gemma4:12b")
            XCTAssertEqual(
                try migrated.generationProvenance(briefID: "legacy-brief")?.modelName,
                "gemma3:latest",
                "Historical brief provenance must retain the model that actually produced it."
            )
            XCTAssertEqual(
                try migrated.lokiGenerationProvenance(messageID: "legacy-message")?
                    .modelIdentifier,
                "gemma3:latest",
                "Historical Chat provenance must never be rewritten as an active preference."
            )
        }

        do {
            let reopened = try LocalStore(url: fixture.storeURL)
            XCTAssertFalse(reopened.modelRoleMigrationReport.didRun)
            XCTAssertEqual(
                reopened.modelRoleMigrationReport.reasonCode,
                "p8_model_role_migration_already_completed"
            )
            XCTAssertEqual(try reopened.modelRoleAssignments(), firstAssignments)
            XCTAssertEqual(
                try reopened.generationProvenance(briefID: "legacy-brief")?.modelName,
                "gemma3:latest"
            )
            XCTAssertEqual(
                try reopened.lokiGenerationProvenance(messageID: "legacy-message")?
                    .modelIdentifier,
                "gemma3:latest"
            )
            XCTAssertFalse(
                try reopened.ollamaWebResearchGlobalSettings().providerEnabled
            )
        }
    }

    func testLegacyGemma3BecomesTruthfullyUnassignedWhenNoReplacementIsAssessed() throws {
        let fixture = try makeFixtureDirectory(named: "p8-v8-to-v9-unassessed")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeV8Fixture(
            at: fixture.storeURL,
            includeReadyGemma4: false,
            includeReadyGPTOSS: false
        )

        let migrated = try LocalStore(url: fixture.storeURL)
        let primary = try XCTUnwrap(
            try migrated.modelRoleAssignment(for: .primaryAgent)
        )
        let summary = try XCTUnwrap(
            try migrated.modelRoleAssignment(for: .briefSummary)
        )

        XCTAssertEqual(primary.readiness, .assessmentRequired)
        XCTAssertNil(primary.requestedModelIdentifier)
        XCTAssertNil(primary.effectiveModelIdentifier)
        XCTAssertFalse(primary.isExecutable)
        XCTAssertEqual(summary.readiness, .assessmentRequired)
        XCTAssertNil(summary.requestedModelIdentifier)
        XCTAssertNil(summary.effectiveModelIdentifier)
        XCTAssertNil(try migrated.lokiChatModelSelection())
        XCTAssertNil(try migrated.modelSelection().modelID)
        XCTAssertFalse(try migrated.modelSelection().localGenerationEnabled)
        XCTAssertEqual(
            try migrated.generationProvenance(briefID: "legacy-brief")?.modelName,
            "gemma3:latest"
        )
        XCTAssertEqual(
            try migrated.lokiGenerationProvenance(messageID: "legacy-message")?
                .modelIdentifier,
            "gemma3:latest"
        )
    }

    func testExplicitBriefSummaryAssignmentAndPrivacySafeReceiptsRoundTripAcrossReopen() throws {
        let fixture = try makeFixtureDirectory(named: "p8-v9-round-trip")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let summaryAssignment = readyCandidate(
            modelIdentifier: "gemma4:12b",
            capabilities: ModelRole.briefSummary.requiredCapabilities
        ).assignment(
            for: .briefSummary,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )
        let routingReceipt = ModelRoutingReceipt(
            id: "route-round-trip",
            timestamp: anchor,
            traceID: "trace-round-trip",
            spanID: "span-round-trip",
            parentSpanID: nil,
            status: .ready,
            reasonCode: "model_routing_requested_role_ready",
            requestedRole: .briefSummary,
            selectedRole: .briefSummary,
            requestedModelIdentifier: "gemma4:12b",
            effectiveModelIdentifier: "gemma4:12b",
            requestedModelClassification: .local,
            effectiveModelClassification: .local,
            assessmentReceiptIdentifier: "assessment-gemma4:12b",
            switchStatus: .none,
            effectiveContextTokens: 98_304,
            attachmentsPresent: false
        )
        let reasoningReceipt = ModelReasoningReceipt(
            id: "reasoning-round-trip",
            traceID: "trace-round-trip",
            reasoningMode: .balanced,
            modelIdentifier: "gemma4:12b",
            assessmentReceiptIdentifier: "assessment-gemma4:12b",
            startedAt: anchor,
            durationMilliseconds: 750,
            usage: .init(promptTokens: 12, completionTokens: 24, totalTokens: 36),
            toolLoopCount: 1,
            status: .completed,
            reasonCode: "reasoning_completed"
        )

        do {
            let store = try LocalStore(url: fixture.storeURL)
            try store.saveModelRoleAssignment(summaryAssignment)
            try store.persistModelRoutingReceipt(routingReceipt)
            try store.persistModelReasoningReceipt(reasoningReceipt)
        }

        let reopened = try LocalStore(url: fixture.storeURL)
        XCTAssertEqual(
            try reopened.modelRoleAssignment(for: .briefSummary),
            summaryAssignment
        )
        XCTAssertEqual(try reopened.modelRoutingReceipts(), [routingReceipt])
        XCTAssertEqual(try reopened.modelReasoningReceipts(), [reasoningReceipt])
    }

    func testV9MigrationPlanHasOneOrderedV8ToV9LightweightStage() {
        XCTAssertEqual(LokiBriefSchemaV9.versionIdentifier, Schema.Version(9, 0, 0))
        XCTAssertEqual(LokiBriefMigrationPlanV9.schemas.count, 10)
        XCTAssertEqual(LokiBriefMigrationPlanV9.stages.count, 9)
    }

    func testWebResearchSettingsDefaultDisabledPersistIndependentlyAndClear() throws {
        let fixture = try makeFixtureDirectory(named: "p8-web-policy-round-trip")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let enabledAt = anchor.addingTimeInterval(60)

        do {
            let store = try LocalStore(url: fixture.storeURL)
            let globalDefaults = try store.ollamaWebResearchGlobalSettings()
            let chatDefaults = try store.ollamaWebResearchConversationPolicy(
                conversationIdentifier: "conversation-a"
            )
            XCTAssertFalse(globalDefaults.providerEnabled)
            XCTAssertFalse(globalDefaults.externalNetworkDisclosureAccepted)
            XCTAssertFalse(chatDefaults.webResearchEnabled)

            try store.updateOllamaWebResearchGlobalSettings(.init(
                providerEnabled: true,
                externalNetworkDisclosureAccepted: true,
                updatedAt: enabledAt
            ))
            try store.updateOllamaWebResearchConversationPolicy(.init(
                conversationIdentifier: "conversation-a",
                webResearchEnabled: true,
                updatedAt: enabledAt
            ))
            XCTAssertFalse(
                try store.ollamaWebResearchConversationPolicy(
                    conversationIdentifier: "conversation-b"
                ).webResearchEnabled,
                "Per-chat enablement must never spread to another conversation."
            )
        }

        do {
            let reopened = try LocalStore(url: fixture.storeURL)
            XCTAssertEqual(
                try reopened.ollamaWebResearchGlobalSettings(),
                .init(
                    providerEnabled: true,
                    externalNetworkDisclosureAccepted: true,
                    updatedAt: enabledAt
                )
            )
            XCTAssertTrue(
                try reopened.ollamaWebResearchConversationPolicy(
                    conversationIdentifier: "conversation-a"
                ).webResearchEnabled
            )
            XCTAssertFalse(
                try reopened.ollamaWebResearchConversationPolicy(
                    conversationIdentifier: "conversation-b"
                ).webResearchEnabled
            )

            try reopened.clearOllamaWebResearchConversationPolicy(
                conversationIdentifier: "conversation-a"
            )
            XCTAssertFalse(
                try reopened.ollamaWebResearchConversationPolicy(
                    conversationIdentifier: "conversation-a"
                ).webResearchEnabled
            )
            let reset = try reopened.clearOllamaWebResearchGlobalSettings(at: anchor)
            XCTAssertFalse(reset.providerEnabled)
            XCTAssertFalse(reset.externalNetworkDisclosureAccepted)
        }
    }

    func testDeleteAllClearsWebResearchPolicyAndNoCredentialMaterialIsPersistable() throws {
        let store = try LocalStore(inMemory: true)
        try store.updateOllamaWebResearchGlobalSettings(.init(
            providerEnabled: true,
            externalNetworkDisclosureAccepted: true,
            updatedAt: anchor
        ))
        try store.updateOllamaWebResearchConversationPolicy(.init(
            conversationIdentifier: "conversation-delete",
            webResearchEnabled: true,
            updatedAt: anchor
        ))

        try store.deleteAllLocalData()

        let global = try store.ollamaWebResearchGlobalSettings()
        let conversation = try store.ollamaWebResearchConversationPolicy(
            conversationIdentifier: "conversation-delete"
        )
        let encoded = try JSONEncoder().encode(global)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(global.providerEnabled)
        XCTAssertFalse(global.externalNetworkDisclosureAccepted)
        XCTAssertFalse(conversation.webResearchEnabled)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("key"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("credential"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    }

    private func makeFixtureDirectory(
        named name: String
    ) throws -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (directory, directory.appendingPathComponent("LokiBrief.store"))
    }

    private func writeV8Fixture(
        at storeURL: URL,
        includeReadyGemma4: Bool,
        includeReadyGPTOSS: Bool
    ) throws {
        let schema = Schema(versionedSchema: LokiBriefSchemaV8.self)
        let configuration = ModelConfiguration(
            "LokiBrief-v1",
            schema: schema,
            url: storeURL
        )
        let legacy = try ModelContainer(
            for: schema,
            migrationPlan: LokiBriefMigrationPlanV8.self,
            configurations: [configuration]
        )
        let context = legacy.mainContext

        context.insert(StoredLocalModelDescriptor(
            id: "gemma4:12b",
            displayName: "gemma4:12b",
            modifiedAt: anchor,
            sizeBytes: 12_000,
            digest: "sha256:gemma4",
            details: Data("{}".utf8),
            discoveredAt: anchor
        ))
        context.insert(StoredLocalModelDescriptor(
            id: "gpt-oss:20b",
            displayName: "gpt-oss:20b",
            modifiedAt: anchor,
            sizeBytes: 20_000,
            digest: "sha256:gpt-oss",
            details: Data("{}".utf8),
            discoveredAt: anchor
        ))
        if includeReadyGemma4 {
            let capabilities = ModelRole.primaryAgent.requiredCapabilities
                .union(ModelRole.vision.requiredCapabilities)
                .union(ModelRole.briefSummary.requiredCapabilities)
                .union([.reasoning])
            context.insert(try storedAssessment(
                id: "assessment-gemma4",
                modelIdentifier: "gemma4:12b",
                digest: "sha256:gemma4",
                capabilities: capabilities,
                controls: [.ollamaBoolean]
            ))
        }
        if includeReadyGPTOSS {
            let capabilities = ModelRole.primaryAgent.requiredCapabilities
                .union(ModelRole.textFallback.requiredCapabilities)
                .union(ModelRole.briefSummary.requiredCapabilities)
                .union([.reasoning])
            context.insert(try storedAssessment(
                id: "assessment-gpt-oss",
                modelIdentifier: "gpt-oss:20b",
                digest: "sha256:gpt-oss",
                capabilities: capabilities,
                controls: [.ollamaLow, .ollamaMedium, .ollamaHigh]
            ))
        }

        context.insert(StoredLokiChatModelSelection(
            provider: "ollama",
            modelIdentifier: "gemma3:latest",
            modelDigest: "sha256:legacy-gemma3",
            assessmentVersion: "agent-loki.model-assessment.v1",
            selectedAt: anchor
        ))
        context.insert(StoredModelSelectionRecord(
            modelID: "gemma3:latest",
            localGenerationEnabled: true,
            selectedAt: anchor
        ))
        context.insert(StoredGenerationProvenanceRecord(
            id: "legacy-brief-generation",
            briefID: "legacy-brief",
            providerKind: "ollama",
            modelName: "gemma3:latest",
            promptTemplateVersion: "loki.brief.p2.v1",
            schemaVersion: "loki.brief.output.v1",
            generatedAt: anchor,
            sourceItemIdentifiers: Data("[]".utf8),
            completionStatus: "success",
            fallbackStatus: nil,
            durationMilliseconds: 100,
            promptTokenCount: 10,
            completionTokenCount: 20,
            validationResult: "valid",
            failureCode: nil
        ))
        context.insert(StoredLokiGenerationProvenance(
            messageID: "legacy-message",
            conversationID: "legacy-conversation",
            provider: "ollama",
            modelIdentifier: "gemma3:latest",
            assessmentVersion: "agent-loki.model-assessment.v1",
            promptTemplateVersion: "agent-loki.chat.v1",
            toolSchemaVersion: "agent-loki.tools.v1",
            startedAt: anchor,
            completedAt: anchor.addingTimeInterval(1),
            durationMilliseconds: 1_000,
            promptTokenEstimate: 10,
            completionTokenCount: 20,
            evidenceCount: 0,
            status: "completed",
            reasonCode: "legacy_completed"
        ))
        try context.save()
    }

    private func storedAssessment(
        id: String,
        modelIdentifier: String,
        digest: String,
        capabilities: Set<ModelCapability>,
        controls: Set<ModelReasoningControl>
    ) throws -> StoredLokiModelAssessment {
        let assessment = ModelCapabilityAssessment(
            provider: "ollama",
            providerVersion: "0.12.3",
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            capabilitiesProven: capabilities,
            capabilitiesMissing: Set(ModelCapability.allCases).subtracting(capabilities),
            contextPolicy: .init(
                declaredContextTokens: 131_072,
                empiricallyUsableContextTokens: 98_304
            ),
            reasoningControl: controls.sorted { $0.rawValue < $1.rawValue }.first,
            reasoningControlsProven: controls,
            assessedAt: anchor,
            durationMilliseconds: 100,
            diagnostics: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return StoredLokiModelAssessment(
            id: id,
            provider: assessment.provider,
            providerVersion: assessment.providerVersion,
            modelIdentifier: assessment.modelIdentifier,
            modelDigest: assessment.modelDigest,
            assessmentVersion: assessment.assessmentVersion,
            readinessRaw: ModelReadiness.ready.rawValue,
            provenCapabilitiesData: try encoder.encode(
                assessment.capabilitiesProven.map(\.rawValue).sorted()
            ),
            missingCapabilitiesData: try encoder.encode(
                assessment.capabilitiesMissing.map(\.rawValue).sorted()
            ),
            contextWindowClassificationRaw:
                assessment.contextPolicy.classification.rawValue,
            assessedAt: assessment.assessedAt,
            durationMilliseconds: assessment.durationMilliseconds,
            diagnosticReasonCodesData: try encoder.encode([String]()),
            capabilityAssessmentData: try encoder.encode(assessment)
        )
    }

    private func readyCandidate(
        modelIdentifier: String,
        capabilities: Set<ModelCapability>
    ) -> ModelRoleCandidate {
        let profile = ModelProfile(
            provider: "ollama",
            providerVersion: "0.12.3",
            modelIdentifier: modelIdentifier,
            displayName: modelIdentifier,
            modelDigest: "sha256:\(modelIdentifier)",
            locallyInstalled: true,
            estimatedCapabilities: [],
            contextPolicy: .init(declaredContextTokens: 131_072),
            observedAt: anchor
        )
        let assessment = ModelCapabilityAssessment(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            capabilitiesProven: capabilities,
            capabilitiesMissing: Set(ModelCapability.allCases).subtracting(capabilities),
            contextPolicy: .init(
                declaredContextTokens: 131_072,
                empiricallyUsableContextTokens: 98_304
            ),
            assessedAt: anchor,
            durationMilliseconds: 100,
            diagnostics: []
        )
        return .init(
            profile: profile,
            assessmentReceiptIdentifier: "assessment-\(modelIdentifier)",
            assessment: assessment
        )
    }
}
