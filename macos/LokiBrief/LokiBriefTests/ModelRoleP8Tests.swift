import Foundation
import XCTest
@testable import LokiBrief

final class ModelRoleP8Tests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_743_000_000)

    func testCuratedPolicyContainsAllRolesWithoutGemma3() {
        XCTAssertEqual(Set(ModelRole.allCases), [
            .primaryAgent,
            .textFallback,
            .vision,
            .embedding,
            .briefSummary,
        ])
        XCTAssertEqual(
            ModelCuratedRolePolicy.recommendedModelIdentifier(for: .primaryAgent),
            "gemma4:12b"
        )
        XCTAssertEqual(
            ModelCuratedRolePolicy.recommendedModelIdentifier(for: .vision),
            "gemma4:12b"
        )
        XCTAssertEqual(
            ModelCuratedRolePolicy.recommendedModelIdentifier(for: .textFallback),
            "gpt-oss:20b"
        )
        XCTAssertEqual(
            ModelCuratedRolePolicy.recommendedModelIdentifier(for: .embedding),
            "qwen3-embedding:0.6b"
        )
        XCTAssertNil(
            ModelCuratedRolePolicy.recommendedModelIdentifier(for: .briefSummary)
        )
        XCTAssertFalse(
            ModelCuratedRolePolicy.allCuratedModelIdentifiers.contains {
                ModelCuratedRolePolicy.isLegacyGemma3($0)
            }
        )
    }

    func testAssessedGPTOSSCanBePrimaryAndRemainsTextOnly() throws {
        let candidate = candidate(
            modelIdentifier: "gpt-oss:20b",
            capabilities: ModelRole.primaryAgent.requiredCapabilities.union([.reasoning]),
            controls: [.ollamaLow, .ollamaMedium, .ollamaHigh]
        )
        let assignment = candidate.assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )

        XCTAssertEqual(assignment.readiness, .ready)
        XCTAssertEqual(assignment.effectiveModelIdentifier, "gpt-oss:20b")
        XCTAssertEqual(assignment.verifiedInputModalities, [.text])
        XCTAssertFalse(assignment.verifiedInputModalities.contains(.image))
        XCTAssertEqual(
            assignment.verifiedThinkingModes,
            [.ollamaLow, .ollamaMedium, .ollamaHigh]
        )
        XCTAssertTrue(try assignment.validatedForPersistence().isExecutable)
    }

    func testAssessedGemma4CanIndependentlyFillPrimaryAndVision() {
        let capabilities = ModelRole.primaryAgent.requiredCapabilities
            .union(ModelRole.vision.requiredCapabilities)
            .union([.reasoning])
        let candidate = candidate(
            modelIdentifier: "gemma4:12b",
            capabilities: capabilities,
            controls: [.ollamaBoolean]
        )

        let primary = candidate.assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )
        let vision = candidate.assignment(
            for: .vision,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )

        XCTAssertEqual(primary.readiness, .ready)
        XCTAssertEqual(vision.readiness, .ready)
        XCTAssertEqual(primary.effectiveModelIdentifier, "gemma4:12b")
        XCTAssertEqual(vision.effectiveModelIdentifier, "gemma4:12b")
        XCTAssertTrue(vision.verifiedInputModalities.contains(.image))
    }

    func testUnassessedAndStaleModelsNeverBecomeEffective() {
        let profile = profile(modelIdentifier: "gemma4:12b", digest: "sha256:new")
        let unassessed = ModelRoleCandidate(
            profile: profile,
            assessmentReceiptIdentifier: nil,
            assessment: nil
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )
        let staleAssessment = assessment(
            modelIdentifier: "gemma4:12b",
            digest: "sha256:old",
            capabilities: ModelRole.primaryAgent.requiredCapabilities
        )
        let stale = ModelRoleCandidate(
            profile: profile,
            assessmentReceiptIdentifier: "assessment-stale",
            assessment: staleAssessment
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )

        XCTAssertEqual(unassessed.readiness, .assessmentRequired)
        XCTAssertNil(unassessed.effectiveModelIdentifier)
        XCTAssertFalse(unassessed.isExecutable)
        XCTAssertEqual(stale.readiness, .staleDigest)
        XCTAssertNil(stale.effectiveModelIdentifier)
        XCTAssertFalse(stale.isExecutable)
    }

    func testCloudReferenceIsBlockedBeforeExecution() {
        let cloud = candidate(
            modelIdentifier: "gpt-oss:120b-cloud",
            capabilities: ModelRole.primaryAgent.requiredCapabilities
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )

        XCTAssertEqual(cloud.requestedClassification, .cloud)
        XCTAssertEqual(cloud.readiness, .cloudBlocked)
        XCTAssertNil(cloud.effectiveModelIdentifier)
        XCTAssertFalse(cloud.isExecutable)
    }

    func testDedicatedEmbeddingRecommendationCanNeverExecuteAsChat() {
        let qwen = candidate(
            modelIdentifier: "qwen3-embedding:0.6b",
            digest: String(repeating: "a", count: 64),
            capabilities: ModelRole.primaryAgent.requiredCapabilities.union([.embedding])
        )
        let chat = qwen.assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )
        let embedding = qwen.assignment(
            for: .embedding,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )

        XCTAssertEqual(chat.readiness, .partiallyCompatible)
        XCTAssertNil(chat.effectiveModelIdentifier)
        XCTAssertEqual(embedding.readiness, .ready)
        XCTAssertEqual(embedding.effectiveModelIdentifier, "qwen3-embedding:0.6b")
    }

    func testLegacyGemma3UsesAssessedGemma4BeforeAssessedGPTOSS() {
        let input = ModelRoleMigrationInput(
            legacyChatPreference: legacy("gemma3:latest"),
            legacyBriefSummaryPreference: legacy("gemma3:latest"),
            candidates: [
                candidate(
                    modelIdentifier: "gpt-oss:20b",
                    capabilities: ModelRole.primaryAgent.requiredCapabilities
                        .union(ModelRole.briefSummary.requiredCapabilities)
                ),
                candidate(
                    modelIdentifier: "gemma4:12b",
                    capabilities: ModelRole.primaryAgent.requiredCapabilities
                        .union(ModelRole.briefSummary.requiredCapabilities)
                        .union(ModelRole.vision.requiredCapabilities)
                ),
            ],
            migratedAt: anchor
        )

        let assignments = ModelRoleMigrationPolicy.assignments(for: input)
        XCTAssertEqual(
            assignments.first { $0.role == .primaryAgent }?.effectiveModelIdentifier,
            "gemma4:12b"
        )
        XCTAssertEqual(
            assignments.first { $0.role == .briefSummary }?.effectiveModelIdentifier,
            "gemma4:12b"
        )
        XCTAssertFalse(assignments.contains {
            $0.requestedModelIdentifier.map(ModelCuratedRolePolicy.isLegacyGemma3) == true
                || $0.effectiveModelIdentifier.map(ModelCuratedRolePolicy.isLegacyGemma3) == true
        })
    }

    func testLegacyGemma3UsesAssessedGPTOSSWhenGemma4IsUnassessed() {
        let unassessedGemma = ModelRoleCandidate(
            profile: profile(modelIdentifier: "gemma4:12b"),
            assessmentReceiptIdentifier: nil,
            assessment: nil
        )
        let assignments = ModelRoleMigrationPolicy.assignments(for: .init(
            legacyChatPreference: legacy("gemma3:latest"),
            legacyBriefSummaryPreference: nil,
            candidates: [
                unassessedGemma,
                candidate(
                    modelIdentifier: "gpt-oss:20b",
                    capabilities: ModelRole.primaryAgent.requiredCapabilities
                ),
            ],
            migratedAt: anchor
        ))

        XCTAssertEqual(
            assignments.first { $0.role == .primaryAgent }?.effectiveModelIdentifier,
            "gpt-oss:20b"
        )
    }

    func testIndependentBriefSummaryPreferenceDoesNotFollowPrimaryOverride() {
        let assignments = ModelRoleMigrationPolicy.assignments(for: .init(
            legacyChatPreference: legacy("gpt-oss:20b"),
            legacyBriefSummaryPreference: legacy("gemma4:12b"),
            candidates: [
                candidate(
                    modelIdentifier: "gpt-oss:20b",
                    capabilities: ModelRole.primaryAgent.requiredCapabilities
                ),
                candidate(
                    modelIdentifier: "gemma4:12b",
                    capabilities: ModelRole.briefSummary.requiredCapabilities
                        .union(ModelRole.vision.requiredCapabilities)
                ),
            ],
            migratedAt: anchor
        ))

        let primary = assignments.first { $0.role == .primaryAgent }
        let summary = assignments.first { $0.role == .briefSummary }
        XCTAssertEqual(primary?.effectiveModelIdentifier, "gpt-oss:20b")
        XCTAssertEqual(summary?.effectiveModelIdentifier, "gemma4:12b")
        XCTAssertTrue(summary?.isExplicitlyAssigned == true)
        XCTAssertNil(summary?.inheritedFromRole)
    }

    func testUnsetBriefSummaryUsesConfiguredPrimaryInheritance() {
        let assignments = ModelRoleMigrationPolicy.assignments(for: .init(
            legacyChatPreference: legacy("gpt-oss:20b"),
            legacyBriefSummaryPreference: nil,
            candidates: [
                candidate(
                    modelIdentifier: "gpt-oss:20b",
                    capabilities: ModelRole.primaryAgent.requiredCapabilities
                ),
            ],
            migratedAt: anchor
        ))
        let summary = assignments.first { $0.role == .briefSummary }

        XCTAssertEqual(summary?.readiness, .inherited)
        XCTAssertEqual(summary?.inheritedFromRole, .primaryAgent)
        XCTAssertFalse(summary?.isExplicitlyAssigned == true)
    }

    func testGPTOSSFastBalancedDeepMapOnlyToVerifiedLevels() {
        let controls: Set<ModelReasoningControl> = [
            .ollamaLow,
            .ollamaMedium,
            .ollamaHigh,
        ]
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .fast,
                modelIdentifier: "gpt-oss:20b",
                verifiedControls: controls
            ).control,
            .ollamaLow
        )
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .balanced,
                modelIdentifier: "gpt-oss:20b",
                verifiedControls: controls
            ).control,
            .ollamaMedium
        )
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .deep,
                modelIdentifier: "gpt-oss:20b",
                verifiedControls: controls
            ).control,
            .ollamaHigh
        )
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .deep,
                modelIdentifier: "gpt-oss:20b",
                verifiedControls: [.ollamaLow, .ollamaMedium]
            ).availability,
            .unavailable
        )
    }

    func testBooleanReasoningExposesReducedSetWithoutPretendingDeepSupport() {
        let modes = ReasoningModeResolution.availableModes(
            modelIdentifier: "gemma4:12b",
            verifiedControls: [.ollamaBoolean]
        )

        XCTAssertEqual(modes, [.fast, .balanced])
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .balanced,
                modelIdentifier: "gemma4:12b",
                verifiedControls: [.ollamaBoolean]
            ).availability,
            .reduced
        )
        XCTAssertEqual(
            ReasoningModeResolution.resolve(
                .deep,
                modelIdentifier: "gemma4:12b",
                verifiedControls: [.ollamaBoolean]
            ).availability,
            .unavailable
        )
    }

    func testImageRoutingIsVisibleAndUsesOnlyAssessedVisionRole() {
        let primary = candidate(
            modelIdentifier: "gpt-oss:20b",
            capabilities: ModelRole.primaryAgent.requiredCapabilities
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )
        let vision = candidate(
            modelIdentifier: "gemma4:12b",
            capabilities: ModelRole.vision.requiredCapabilities
        ).assignment(
            for: .vision,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )

        let result = ModelRoleRouter.route(
            requestedRole: .primaryAgent,
            attachmentsPresent: true,
            assignments: [primary, vision],
            receiptIdentifier: "route-image",
            traceID: "trace-image",
            spanID: "span-image",
            at: anchor
        )

        XCTAssertTrue(result.maySubmit)
        XCTAssertEqual(result.receipt.selectedRole, .vision)
        XCTAssertEqual(result.receipt.switchStatus, .visibleCrossRole)
        XCTAssertEqual(result.receipt.effectiveModelIdentifier, "gemma4:12b")
        XCTAssertEqual(
            result.userFacingNotice,
            "This request contains an image.\nUsing the verified vision model: gemma4:12b."
        )
    }

    func testNoReadyVisionDisablesImageSubmission() {
        let primary = candidate(
            modelIdentifier: "gpt-oss:20b",
            capabilities: ModelRole.primaryAgent.requiredCapabilities
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )

        let result = ModelRoleRouter.route(
            requestedRole: .primaryAgent,
            attachmentsPresent: true,
            assignments: [primary],
            receiptIdentifier: "route-no-vision",
            traceID: "trace-no-vision",
            spanID: "span-no-vision",
            at: anchor
        )

        XCTAssertFalse(result.maySubmit)
        XCTAssertNil(result.receipt.selectedRole)
        XCTAssertEqual(result.receipt.switchStatus, .blocked)
        XCTAssertEqual(
            result.userFacingNotice,
            """
            This request contains an image.
            Assign and assess a compatible Vision model before sending.
            """
        )
    }

    func testTextRoutingNeverSilentlyUsesFallback() {
        let unavailablePrimary = ModelRoleAssignment.unassigned(
            role: .primaryAgent,
            readiness: .assessmentRequired,
            reasonCode: ModelRoleReason.assessmentRequired,
            source: .operatorSelection,
            selectedAt: anchor
        )
        let fallback = candidate(
            modelIdentifier: "gpt-oss:20b",
            capabilities: ModelRole.textFallback.requiredCapabilities
        ).assignment(
            for: .textFallback,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: anchor
        )

        let blocked = ModelRoleRouter.route(
            requestedRole: .primaryAgent,
            attachmentsPresent: false,
            assignments: [unavailablePrimary, fallback],
            receiptIdentifier: "route-blocked",
            traceID: "trace-blocked",
            spanID: "span-blocked",
            at: anchor
        )
        let explicit = ModelRoleRouter.route(
            requestedRole: .primaryAgent,
            attachmentsPresent: false,
            assignments: [unavailablePrimary, fallback],
            explicitFallbackRole: .textFallback,
            receiptIdentifier: "route-explicit",
            traceID: "trace-explicit",
            spanID: "span-explicit",
            at: anchor
        )

        XCTAssertFalse(blocked.maySubmit)
        XCTAssertNil(blocked.receipt.selectedRole)
        XCTAssertTrue(explicit.maySubmit)
        XCTAssertEqual(explicit.receipt.selectedRole, .textFallback)
        XCTAssertEqual(explicit.receipt.switchStatus, .visibleExplicitFallback)
        XCTAssertNotNil(explicit.userFacingNotice)
    }

    func testRoutingReceiptContainsTraceGraphFieldsWithoutPrivatePayloadFields() throws {
        let assignment = candidate(
            modelIdentifier: "gpt-oss:20b",
            capabilities: ModelRole.primaryAgent.requiredCapabilities
        ).assignment(
            for: .primaryAgent,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: false,
            selectedAt: anchor
        )
        let receipt = ModelRoleRouter.route(
            requestedRole: .primaryAgent,
            attachmentsPresent: false,
            assignments: [assignment],
            receiptIdentifier: "route-safe",
            traceID: "trace-safe",
            spanID: "span-safe",
            parentSpanID: "span-parent",
            at: anchor
        ).receipt
        let encoded = try JSONEncoder().encode(receipt)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertEqual(receipt.event, "model.routing.completed")
        XCTAssertEqual(receipt.component, "model_router")
        XCTAssertEqual(receipt.traceID, "trace-safe")
        XCTAssertEqual(receipt.parentSpanID, "span-parent")
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertFalse(text.contains("rawReasoning"))
        XCTAssertFalse(text.contains("filePath"))
        XCTAssertFalse(text.contains("imageBytes"))
        XCTAssertFalse(text.contains("credential"))
    }

    func testEphemeralThinkingIsClearedAndNeverAppearsInReceipt() throws {
        var state = EphemeralModelReasoningState(
            receiptIdentifier: "reasoning-receipt",
            traceID: "trace-reasoning",
            reasoningMode: .deep,
            modelIdentifier: "gpt-oss:20b",
            assessmentReceiptIdentifier: "assessment-gpt",
            startedAt: anchor
        )
        state.appendThinking("PRIVATE_CHAIN_SENTINEL")
        state.recordToolLoop()
        let receipt = state.finish(
            at: anchor.addingTimeInterval(1.25),
            status: .completed,
            usage: .init(promptTokens: 10, completionTokens: 20, totalTokens: 30),
            reasonCode: "reasoning_completed"
        )
        let encoded = try JSONEncoder().encode(receipt)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(state.visibleThinking.isEmpty)
        XCTAssertEqual(receipt.durationMilliseconds, 1_250)
        XCTAssertEqual(receipt.toolLoopCount, 1)
        XCTAssertFalse(text.contains("PRIVATE_CHAIN_SENTINEL"))
        XCTAssertFalse(text.contains("thinking"))
    }

    func testCancellationClearsEphemeralThinkingAndPersistsOnlyCancelledState() throws {
        var state = EphemeralModelReasoningState(
            receiptIdentifier: "reasoning-cancelled",
            traceID: "trace-cancelled",
            reasoningMode: .balanced,
            modelIdentifier: "gemma4:12b",
            assessmentReceiptIdentifier: "assessment-gemma4",
            startedAt: anchor
        )
        state.appendThinking("PRIVATE_CANCELLED_CHAIN")
        let receipt = state.finish(
            at: anchor.addingTimeInterval(0.5),
            status: .cancelled,
            usage: .init(promptTokens: nil, completionTokens: nil, totalTokens: nil),
            reasonCode: "reasoning_cancelled"
        )
        let encoded = try JSONEncoder().encode(receipt)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(state.visibleThinking.isEmpty)
        XCTAssertEqual(receipt.status, .cancelled)
        XCTAssertFalse(text.contains("PRIVATE_CANCELLED_CHAIN"))
    }

    func testLegacyAssessmentWithoutReasoningControlSetDecodesWithSingularFallback() throws {
        let legacy = assessment(
            modelIdentifier: "gpt-oss:20b",
            digest: "sha256:legacy-assessment",
            capabilities: ModelRole.primaryAgent.requiredCapabilities.union([.reasoning]),
            controls: [.ollamaLow]
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "reasoningControlsProven")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            ModelCapabilityAssessment.self,
            from: legacyData
        )

        XCTAssertEqual(decoded.reasoningControl, .ollamaLow)
        XCTAssertEqual(decoded.verifiedReasoningControls, [.ollamaLow])
    }

    private func legacy(_ modelIdentifier: String) -> LegacyModelPreference {
        .init(
            provider: "ollama",
            modelIdentifier: modelIdentifier,
            modelDigest: "sha256:\(modelIdentifier)",
            assessmentVersion: ModelCapabilityAssessment.currentAssessmentVersion,
            selectedAt: anchor
        )
    }

    private func candidate(
        modelIdentifier: String,
        digest: String? = nil,
        capabilities: Set<ModelCapability>,
        controls: Set<ModelReasoningControl> = []
    ) -> ModelRoleCandidate {
        let digest = digest ?? "sha256:\(modelIdentifier)"
        return .init(
            profile: profile(modelIdentifier: modelIdentifier, digest: digest),
            assessmentReceiptIdentifier: "assessment-\(modelIdentifier)",
            assessment: assessment(
                modelIdentifier: modelIdentifier,
                digest: digest,
                capabilities: capabilities,
                controls: controls
            )
        )
    }

    private func profile(
        modelIdentifier: String,
        digest: String? = nil
    ) -> ModelProfile {
        .init(
            provider: "ollama",
            providerVersion: "0.12.3",
            modelIdentifier: modelIdentifier,
            displayName: modelIdentifier,
            modelDigest: digest ?? "sha256:\(modelIdentifier)",
            locallyInstalled: true,
            estimatedCapabilities: [],
            contextPolicy: .init(declaredContextTokens: 131_072),
            observedAt: anchor
        )
    }

    private func assessment(
        modelIdentifier: String,
        digest: String,
        capabilities: Set<ModelCapability>,
        controls: Set<ModelReasoningControl> = []
    ) -> ModelCapabilityAssessment {
        let stability: EmbeddingStabilityAssessmentSummary?
        if capabilities.contains(.embedding) {
            let profile = OllamaEmbeddingRequestProfile(
                dimensions: 1_024
            )
            stability = .init(
                modelIdentifier: modelIdentifier,
                modelDigest: digest,
                ollamaVersion: "0.12.3",
                requestProfileVersion: profile.version,
                requestProfileHash: profile.stableHash,
                observedDimension: 1_024,
                explicitDimensions: 1_024,
                truncate: profile.truncate,
                normalizationVersion: profile.normalizationVersion,
                repetitionCount: 3,
                requestIdentityVerified: true,
                parserParityVerified: true,
                allValuesFinite: true,
                zeroVectorDetected: false,
                differentInputCollapseDetected: false,
                minimumCosineSimilarity: 1,
                maximumRelativeL2NormDrift: 0,
                minimumL2Norm: 1,
                maximumL2Norm: 1,
                maximumAbsoluteComponentDelta: 0,
                maximumRMSComponentDelta: 0,
                stableTop1: true,
                stableOrderedTop5: true,
                minimumRankingMargin: 0.1,
                rankingHashes: (1...5).map {
                    String(repeating: String($0), count: 64)
                },
                reasonCodes: [
                    EmbeddingAssessmentReasonCode
                        .requestIdentityVerified.rawValue,
                    EmbeddingAssessmentReasonCode
                        .parserParityVerified.rawValue,
                    EmbeddingAssessmentReasonCode
                        .boundedNumericalVariance.rawValue,
                    EmbeddingAssessmentReasonCode
                        .retrievalStabilityVerified.rawValue,
                ]
            )
        } else {
            stability = nil
        }
        return .init(
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
            diagnostics: [],
            embeddingStability: stability
        )
    }
}
