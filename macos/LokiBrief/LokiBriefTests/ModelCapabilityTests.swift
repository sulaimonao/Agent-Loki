import Foundation
import XCTest
@testable import LokiBrief

final class ModelCapabilityTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_785_000_000)

    func testAgentLokiRequirementsKeepRequiredRecommendedAndDeferredCapabilitiesSeparate() {
        let requirements = ModelCapabilityRequirement.agentLokiChat
        let required = Set(requirements.filter { $0.level == .required }.map(\.capability))
        let recommended = Set(requirements.filter { $0.level == .recommended }.map(\.capability))
        let deferred = Set(requirements.filter { $0.level == .deferred }.map(\.capability))

        XCTAssertEqual(required, [.chat, .streaming, .structuredOutput, .toolCalling, .cancellation])
        XCTAssertEqual(recommended, [.systemInstructions, .contextWindow, .reasoning])
        XCTAssertEqual(deferred, [.embedding, .vision, .webResearch])
        XCTAssertEqual(
            requirements.first(where: { $0.capability == .contextWindow })?.minimumUsableContextTokens,
            64_000
        )
    }

    func testEstimatedCapabilitiesAndModelNameNeverProduceReadinessWithoutAssessment() {
        let profile = makeProfile(
            estimated: [.chat, .streaming, .structuredOutput, .toolCalling, .cancellation],
            modelIdentifier: "name-that-claims-everything:latest"
        )

        let result = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: nil,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )

        XCTAssertEqual(result.readiness, .assessmentRequired)
        XCTAssertEqual(result.failure?.code, .assessmentMissing)
        XCTAssertFalse(result.requiredCapabilitiesMissing.isEmpty)
    }

    func testCurrentRuntimeAssessmentProducesReadyAndKeepsRecommendedGapsVisible() {
        let profile = makeProfile(estimated: [])
        let proven: Set<ModelCapability> = [
            .chat, .streaming, .structuredOutput, .toolCalling, .cancellation,
        ]
        let assessment = makeAssessment(profile: profile, proven: proven)

        let result = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: assessment,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertTrue(result.requiredCapabilitiesMissing.isEmpty)
        XCTAssertEqual(
            result.recommendedCapabilitiesMissing,
            [.systemInstructions, .contextWindow, .reasoning]
        )
        XCTAssertNil(result.failure)
    }

    func testChangedDigestProviderVersionOrAssessmentVersionRequiresReassessment() {
        let profile = makeProfile(estimated: [])
        let proven = Set(ModelCapabilityRequirement.agentLokiChat
            .filter { $0.level == .required }
            .map(\.capability))
        let current = makeAssessment(profile: profile, proven: proven)
        XCTAssertTrue(current.isCurrent(for: profile))

        let changedDigest = makeProfile(estimated: [], digest: "changed-digest")
        XCTAssertFalse(current.isCurrent(for: changedDigest))

        let changedProvider = makeProfile(estimated: [], providerVersion: "0.30.7")
        XCTAssertFalse(current.isCurrent(for: changedProvider))

        let oldVersion = ModelCapabilityAssessment(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            assessmentVersion: "agent-loki.model-assessment.v0",
            capabilitiesProven: proven,
            capabilitiesMissing: [],
            contextPolicy: profile.contextPolicy,
            assessedAt: fixedDate,
            durationMilliseconds: 20,
            diagnostics: []
        )
        XCTAssertFalse(oldVersion.isCurrent(for: profile))

        let evaluation = ModelReadinessEvaluation.evaluate(
            profile: changedDigest,
            assessment: current,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )
        XCTAssertEqual(evaluation.readiness, .assessmentRequired)
        XCTAssertEqual(evaluation.failure?.code, .assessmentStale)
    }

    func testEmbeddingAssessmentCurrentContractRequiresExactRuntimeModelAndDigestIdentity() {
        let profile = makeEmbeddingProfile()
        let stability = makeEmbeddingStability()
        let assessment = makeEmbeddingAssessment(
            profile: profile,
            stability: stability
        )

        XCTAssertEqual(
            ModelCapabilityAssessment.currentAssessmentVersion,
            "agent-loki.model-assessment.v2"
        )
        XCTAssertTrue(stability.accepted)
        XCTAssertTrue(stability.isCurrent(for: profile))
        XCTAssertTrue(assessment.isCurrent(for: profile))

        let changedRuntime = makeEmbeddingProfile(providerVersion: "0.30.7")
        XCTAssertFalse(stability.isCurrent(for: changedRuntime))
        XCTAssertFalse(assessment.isCurrent(for: changedRuntime))
        assertStale(assessment, for: changedRuntime)

        let changedDigest = makeEmbeddingProfile(
            digest: String(repeating: "c", count: 64)
        )
        XCTAssertFalse(stability.isCurrent(for: changedDigest))
        XCTAssertFalse(assessment.isCurrent(for: changedDigest))
        assertStale(assessment, for: changedDigest)

        let changedModel = makeEmbeddingProfile(
            modelIdentifier: "qwen3-embedding:4b"
        )
        XCTAssertFalse(stability.isCurrent(for: changedModel))
        XCTAssertFalse(assessment.isCurrent(for: changedModel))

        let missingStability = makeAssessment(
            profile: profile,
            proven: [.embedding]
        )
        XCTAssertFalse(missingStability.isCurrent(for: profile))
    }

    func testPersistedV2NonEmbeddingAssessmentRemainsCurrentWithoutEmbeddingProof() {
        let profile = makeProfile(estimated: [.chat])
        let assessment = ModelCapabilityAssessment(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            assessmentVersion: "agent-loki.model-assessment.v2",
            capabilitiesProven: [.chat],
            capabilitiesMissing: [],
            contextPolicy: profile.contextPolicy,
            assessedAt: fixedDate,
            durationMilliseconds: 20,
            diagnostics: [],
            embeddingStability: nil
        )

        XCTAssertTrue(assessment.isCurrent(for: profile))
    }

    func testEmbeddingAssessmentRejectsStaleRequestProfileAndDimensionIdentity() {
        let profile = makeEmbeddingProfile()
        let staleVersion = makeEmbeddingStability(
            requestProfileVersion:
                "agent-loki.embedding-request-profile.v0"
        )
        XCTAssertFalse(staleVersion.accepted)
        XCTAssertFalse(
            makeEmbeddingAssessment(
                profile: profile,
                stability: staleVersion
            ).isCurrent(for: profile)
        )

        let structurallyValidButStale = [
            (
                "request profile hash",
                makeEmbeddingStability(
                    requestProfileHash: String(repeating: "d", count: 64)
                )
            ),
            (
                "explicit dimension",
                makeEmbeddingStability(
                    observedDimension: 768,
                    explicitDimensions: 768
                )
            ),
        ]

        for (identity, stability) in structurallyValidButStale {
            XCTAssertTrue(
                stability.accepted,
                "\(identity) mutation should remain structurally valid"
            )
            XCTAssertFalse(
                makeEmbeddingAssessment(
                    profile: profile,
                    stability: stability
                ).isCurrent(for: profile),
                "\(identity) mutation must make the assessment stale"
            )
        }
    }

    func testEmbeddingStabilityRejectsUnsafeRequestAndRepetitionContracts() {
        let rejected: [(String, EmbeddingStabilityAssessmentSummary)] = [
            (
                "request profile version",
                makeEmbeddingStability(requestProfileVersion: "")
            ),
            (
                "request profile hash",
                makeEmbeddingStability(requestProfileHash: "not-a-sha256")
            ),
            (
                "explicit dimension",
                makeEmbeddingStability(explicitDimensions: 768)
            ),
            (
                "truncate",
                makeEmbeddingStability(truncate: true)
            ),
            (
                "repetition count",
                makeEmbeddingStability(repetitionCount: 2)
            ),
            (
                "request identity",
                makeEmbeddingStability(requestIdentityVerified: false)
            ),
            (
                "parser parity",
                makeEmbeddingStability(parserParityVerified: false)
            ),
            (
                "finite values",
                makeEmbeddingStability(allValuesFinite: false)
            ),
        ]

        for (contract, stability) in rejected {
            XCTAssertFalse(
                stability.accepted,
                "\(contract) failure must reject embedding stability"
            )
        }
    }

    func testEmbeddingStabilityRejectsNumericalCollapseAndRankingFailures() {
        let acceptedAtBoundary = makeEmbeddingStability(
            minimumCosineSimilarity: 0.99999,
            maximumRelativeL2NormDrift: 0.00001
        )
        XCTAssertTrue(acceptedAtBoundary.accepted)

        let rejected: [(String, EmbeddingStabilityAssessmentSummary)] = [
            (
                "cosine floor",
                makeEmbeddingStability(minimumCosineSimilarity: 0.99998)
            ),
            (
                "relative norm drift",
                makeEmbeddingStability(
                    maximumRelativeL2NormDrift: 0.00002
                )
            ),
            (
                "negative relative norm drift",
                makeEmbeddingStability(
                    maximumRelativeL2NormDrift: -0.00001
                )
            ),
            (
                "cosine domain",
                makeEmbeddingStability(
                    minimumCosineSimilarity: 1.00001
                )
            ),
            (
                "zero vector",
                makeEmbeddingStability(zeroVectorDetected: true)
            ),
            (
                "different-input collapse",
                makeEmbeddingStability(
                    differentInputCollapseDetected: true
                )
            ),
            (
                "top-1 ranking",
                makeEmbeddingStability(stableTop1: false)
            ),
            (
                "ordered top-5 ranking",
                makeEmbeddingStability(stableOrderedTop5: false)
            ),
            (
                "ranking hashes",
                makeEmbeddingStability(rankingHashes: [])
            ),
            (
                "success reason codes",
                makeEmbeddingStability(reasonCodes: [])
            ),
            (
                "ranking margin",
                makeEmbeddingStability(minimumRankingMargin: 0)
            ),
            (
                "finite ranking margin",
                makeEmbeddingStability(minimumRankingMargin: .nan)
            ),
            (
                "absolute delta",
                makeEmbeddingStability(
                    maximumAbsoluteComponentDelta: .infinity
                )
            ),
            (
                "negative absolute delta",
                makeEmbeddingStability(
                    maximumAbsoluteComponentDelta: -0.0001
                )
            ),
            (
                "RMS delta",
                makeEmbeddingStability(
                    maximumRMSComponentDelta: .nan
                )
            ),
            (
                "negative RMS delta",
                makeEmbeddingStability(
                    maximumRMSComponentDelta: -0.00001
                )
            ),
            (
                "RMS above maximum delta",
                makeEmbeddingStability(
                    maximumAbsoluteComponentDelta: 0.00001,
                    maximumRMSComponentDelta: 0.00002
                )
            ),
            (
                "minimum L2 norm",
                makeEmbeddingStability(minimumL2Norm: 0)
            ),
            (
                "maximum L2 norm",
                makeEmbeddingStability(
                    minimumL2Norm: 1.1,
                    maximumL2Norm: 1.0
                )
            ),
        ]

        for (contract, stability) in rejected {
            XCTAssertFalse(
                stability.accepted,
                "\(contract) failure must reject embedding stability"
            )
        }
    }

    func testMissingChatIsIncompatibleWhileOtherMissingRequirementsArePartial() {
        let profile = makeProfile(estimated: [])
        let withoutChat = makeAssessment(
            profile: profile,
            proven: [.streaming, .structuredOutput, .toolCalling, .cancellation]
        )
        let incompatible = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: withoutChat,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )
        XCTAssertEqual(incompatible.readiness, .incompatible)
        XCTAssertEqual(incompatible.failure?.code, .incompatible)

        let withoutTools = makeAssessment(
            profile: profile,
            proven: [.chat, .streaming, .structuredOutput, .cancellation]
        )
        let partial = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: withoutTools,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )
        XCTAssertEqual(partial.readiness, .partiallyCompatible)
        XCTAssertEqual(partial.requiredCapabilitiesMissing, [.toolCalling])
        XCTAssertEqual(partial.failure?.code, .requiredCapabilityMissing)
    }

    func testContextPolicyClassifiesDeclarationWithoutPretendingItWasEmpiricallyProven() {
        let unknown = ModelContextPolicy(declaredContextTokens: nil)
        XCTAssertEqual(unknown.classification, .undeclared)
        XCTAssertNil(unknown.maximumInputTokens)

        let small = ModelContextPolicy(declaredContextTokens: 32_768)
        XCTAssertEqual(small.classification, .belowRecommended)
        XCTAssertFalse(small.meetsRecommendedMinimum)

        let recommended = ModelContextPolicy(declaredContextTokens: 65_536)
        XCTAssertEqual(recommended.classification, .recommended)
        XCTAssertEqual(recommended.maximumInputTokens, 61_440)
        XCTAssertTrue(recommended.meetsRecommendedMinimum)

        let empirical = ModelContextPolicy(
            declaredContextTokens: 131_072,
            empiricallyUsableContextTokens: 16_384
        )
        XCTAssertEqual(empirical.classification, .belowRecommended)
        XCTAssertEqual(empirical.bestKnownUsableTokens, 16_384)
    }

    func testReadinessKeepsBelowMinimumContextVisibleAsARecommendedGap() {
        let profile = ModelProfile(
            provider: "ollama",
            providerVersion: "0.30.6",
            modelIdentifier: "synthetic-model:latest",
            displayName: "Synthetic",
            modelDigest: "digest-v1",
            locallyInstalled: true,
            estimatedCapabilities: [],
            contextPolicy: .init(declaredContextTokens: 32_768),
            observedAt: fixedDate
        )
        let proven: Set<ModelCapability> = [
            .chat,
            .streaming,
            .structuredOutput,
            .toolCalling,
            .cancellation,
            .contextWindow,
        ]
        let assessment = makeAssessment(profile: profile, proven: proven)

        let result = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: assessment,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertTrue(result.recommendedCapabilitiesMissing.contains(.contextWindow))
    }

    func testDiagnosticsAreBoundedAndNeverOverrideProvenCapabilities() {
        let profile = makeProfile(estimated: [])
        let diagnostics = (0..<30).map {
            ModelCapabilityDiagnostic(
                probe: .ordinaryChat,
                status: .failed,
                reasonCode: "reason with unsafe spaces \($0)",
                durationMilliseconds: 999_999
            )
        }
        let assessment = ModelCapabilityAssessment(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            capabilitiesProven: [.chat],
            capabilitiesMissing: [.chat, .streaming],
            contextPolicy: profile.contextPolicy,
            assessedAt: fixedDate,
            durationMilliseconds: 999_999,
            diagnostics: diagnostics
        )

        XCTAssertEqual(assessment.diagnostics.count, ModelCapabilityAssessment.maximumDiagnostics)
        XCTAssertFalse(assessment.capabilitiesMissing.contains(.chat))
        XCTAssertTrue(assessment.capabilitiesMissing.contains(.streaming))
        XCTAssertLessThanOrEqual(assessment.durationMilliseconds, 600_000)
        XCTAssertTrue(assessment.diagnostics.allSatisfy { !$0.reasonCode.contains(" ") })
    }

    private func makeProfile(
        estimated: Set<ModelCapability>,
        modelIdentifier: String = "synthetic-model:latest",
        digest: String? = "digest-v1",
        providerVersion: String? = "0.30.6"
    ) -> ModelProfile {
        .init(
            provider: "ollama",
            providerVersion: providerVersion,
            modelIdentifier: modelIdentifier,
            displayName: modelIdentifier,
            modelDigest: digest,
            locallyInstalled: true,
            estimatedCapabilities: estimated,
            contextPolicy: .init(declaredContextTokens: nil),
            observedAt: fixedDate
        )
    }

    private func makeAssessment(
        profile: ModelProfile,
        proven: Set<ModelCapability>
    ) -> ModelCapabilityAssessment {
        .init(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            capabilitiesProven: proven,
            capabilitiesMissing: Set(ModelCapability.allCases).subtracting(proven),
            contextPolicy: profile.contextPolicy,
            assessedAt: fixedDate,
            durationMilliseconds: 20,
            diagnostics: []
        )
    }

    private func makeEmbeddingProfile(
        modelIdentifier: String = "qwen3-embedding:0.6b",
        digest: String = String(repeating: "a", count: 64),
        providerVersion: String = "0.30.6"
    ) -> ModelProfile {
        makeProfile(
            estimated: [.embedding],
            modelIdentifier: modelIdentifier,
            digest: digest,
            providerVersion: providerVersion
        )
    }

    private func assertStale(
        _ assessment: ModelCapabilityAssessment,
        for profile: ModelProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let evaluation = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: assessment,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )
        XCTAssertEqual(
            evaluation.readiness,
            .assessmentRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(
            evaluation.failure?.code,
            .assessmentStale,
            file: file,
            line: line
        )
    }

    private func makeEmbeddingAssessment(
        profile: ModelProfile,
        stability: EmbeddingStabilityAssessmentSummary
    ) -> ModelCapabilityAssessment {
        .init(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            capabilitiesProven: [.embedding],
            capabilitiesMissing: Set(ModelCapability.allCases)
                .subtracting([.embedding]),
            contextPolicy: profile.contextPolicy,
            assessedAt: fixedDate,
            durationMilliseconds: 20,
            diagnostics: [],
            embeddingStability: stability
        )
    }

    private func makeEmbeddingStability(
        modelIdentifier: String = "qwen3-embedding:0.6b",
        modelDigest: String = String(repeating: "a", count: 64),
        ollamaVersion: String = "0.30.6",
        requestProfileVersion: String =
            OllamaEmbeddingRequestProfile.currentVersion,
        requestProfileHash: String =
            OllamaEmbeddingRequestProfile(dimensions: 1_024)
                .stableHash,
        observedDimension: Int = 1_024,
        explicitDimensions: Int = 1_024,
        truncate: Bool = false,
        normalizationVersion: String =
            OllamaEmbeddingRequestProfile.currentNormalizationVersion,
        repetitionCount: Int = 3,
        requestIdentityVerified: Bool = true,
        parserParityVerified: Bool = true,
        allValuesFinite: Bool = true,
        zeroVectorDetected: Bool = false,
        differentInputCollapseDetected: Bool = false,
        minimumCosineSimilarity: Double = 0.99999,
        maximumRelativeL2NormDrift: Double = 0.00001,
        minimumL2Norm: Double = 0.999_999,
        maximumL2Norm: Double = 1.000_001,
        maximumAbsoluteComponentDelta: Double = 0.0001,
        maximumRMSComponentDelta: Double = 0.00001,
        stableTop1: Bool = true,
        stableOrderedTop5: Bool = true,
        rankingHashes: [String] = [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            String(repeating: "c", count: 64),
            String(repeating: "d", count: 64),
            String(repeating: "e", count: 64),
        ],
        minimumRankingMargin: Double = 0.01,
        reasonCodes: [String] = [
            EmbeddingAssessmentReasonCode
                .requestIdentityVerified.rawValue,
            EmbeddingAssessmentReasonCode
                .parserParityVerified.rawValue,
            EmbeddingAssessmentReasonCode
                .boundedNumericalVariance.rawValue,
            EmbeddingAssessmentReasonCode
                .retrievalStabilityVerified.rawValue,
        ]
    ) -> EmbeddingStabilityAssessmentSummary {
        .init(
            modelIdentifier: modelIdentifier,
            modelDigest: modelDigest,
            ollamaVersion: ollamaVersion,
            requestProfileVersion: requestProfileVersion,
            requestProfileHash: requestProfileHash,
            observedDimension: observedDimension,
            explicitDimensions: explicitDimensions,
            truncate: truncate,
            normalizationVersion: normalizationVersion,
            repetitionCount: repetitionCount,
            requestIdentityVerified: requestIdentityVerified,
            parserParityVerified: parserParityVerified,
            allValuesFinite: allValuesFinite,
            zeroVectorDetected: zeroVectorDetected,
            differentInputCollapseDetected: differentInputCollapseDetected,
            minimumCosineSimilarity: minimumCosineSimilarity,
            maximumRelativeL2NormDrift: maximumRelativeL2NormDrift,
            minimumL2Norm: minimumL2Norm,
            maximumL2Norm: maximumL2Norm,
            maximumAbsoluteComponentDelta: maximumAbsoluteComponentDelta,
            maximumRMSComponentDelta: maximumRMSComponentDelta,
            stableTop1: stableTop1,
            stableOrderedTop5: stableOrderedTop5,
            minimumRankingMargin: minimumRankingMargin,
            rankingHashes: rankingHashes,
            reasonCodes: reasonCodes
        )
    }
}
