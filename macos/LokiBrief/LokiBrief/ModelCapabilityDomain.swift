import Foundation

enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case chat
    case streaming
    case structuredOutput
    case toolCalling
    case systemInstructions
    case contextWindow
    case cancellation
    case vision
    case embedding
    case reasoning
    case webResearch
}

/// Bounded provider control for models that expose a separate reasoning
/// channel. The reasoning payload is never retained by Agent Loki.
enum ModelReasoningControl: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case ollamaBoolean = "ollama_boolean"
    case ollamaLow = "ollama_low"
    case ollamaMedium = "ollama_medium"
    case ollamaHigh = "ollama_high"
}

enum ModelCapabilityRequirementLevel: String, Codable, CaseIterable, Sendable {
    case required
    case recommended
    case deferred
}

struct ModelCapabilityRequirement: Codable, Hashable, Sendable {
    let capability: ModelCapability
    let level: ModelCapabilityRequirementLevel
    let minimumUsableContextTokens: Int?

    init(
        capability: ModelCapability,
        level: ModelCapabilityRequirementLevel,
        minimumUsableContextTokens: Int? = nil
    ) {
        self.capability = capability
        self.level = level
        self.minimumUsableContextTokens = minimumUsableContextTokens
    }

    static let agentLokiChat: [ModelCapabilityRequirement] = [
        .init(capability: .chat, level: .required),
        .init(capability: .streaming, level: .required),
        .init(capability: .structuredOutput, level: .required),
        .init(capability: .toolCalling, level: .required),
        .init(capability: .cancellation, level: .required),
        .init(capability: .systemInstructions, level: .recommended),
        .init(
            capability: .contextWindow,
            level: .recommended,
            minimumUsableContextTokens: ModelContextPolicy.recommendedMinimumUsableTokens
        ),
        .init(capability: .reasoning, level: .recommended),
        .init(capability: .embedding, level: .deferred),
        .init(capability: .vision, level: .deferred),
        .init(capability: .webResearch, level: .deferred),
    ]
}

enum ModelContextWindowClassification: String, Codable, CaseIterable, Sendable {
    case undeclared
    case belowRecommended = "below_recommended"
    case recommended
    case extended
}

struct ModelContextPolicy: Codable, Hashable, Sendable {
    static let recommendedMinimumUsableTokens = 64_000
    static let defaultReservedOutputTokens = 4_096
    static let maximumAcceptedDeclarationTokens = 1_048_576

    let declaredContextTokens: Int?
    let empiricallyUsableContextTokens: Int?
    let reservedOutputTokens: Int
    let classification: ModelContextWindowClassification

    init(
        declaredContextTokens: Int?,
        empiricallyUsableContextTokens: Int? = nil,
        reservedOutputTokens: Int = ModelContextPolicy.defaultReservedOutputTokens
    ) {
        self.declaredContextTokens = Self.boundedTokenCount(declaredContextTokens)
        self.empiricallyUsableContextTokens = Self.boundedTokenCount(empiricallyUsableContextTokens)
        self.reservedOutputTokens = min(
            max(reservedOutputTokens, 1),
            Self.maximumAcceptedDeclarationTokens
        )

        guard let usable = self.empiricallyUsableContextTokens ?? self.declaredContextTokens else {
            classification = .undeclared
            return
        }
        if usable < Self.recommendedMinimumUsableTokens {
            classification = .belowRecommended
        } else if usable < 2 * Self.recommendedMinimumUsableTokens {
            classification = .recommended
        } else {
            classification = .extended
        }
    }

    var bestKnownUsableTokens: Int? {
        empiricallyUsableContextTokens ?? declaredContextTokens
    }

    var maximumInputTokens: Int? {
        bestKnownUsableTokens.map { max(0, $0 - reservedOutputTokens) }
    }

    var meetsRecommendedMinimum: Bool {
        guard let usable = bestKnownUsableTokens else { return false }
        return usable >= Self.recommendedMinimumUsableTokens
    }

    private static func boundedTokenCount(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= maximumAcceptedDeclarationTokens else {
            return nil
        }
        return value
    }
}

struct ModelProfile: Codable, Hashable, Sendable {
    let provider: String
    let providerVersion: String?
    let modelIdentifier: String
    let displayName: String
    let modelDigest: String?
    let locallyInstalled: Bool
    let estimatedCapabilities: Set<ModelCapability>
    let contextPolicy: ModelContextPolicy
    let reasoningControl: ModelReasoningControl
    let observedAt: Date

    init(
        provider: String,
        providerVersion: String?,
        modelIdentifier: String,
        displayName: String,
        modelDigest: String?,
        locallyInstalled: Bool,
        estimatedCapabilities: Set<ModelCapability>,
        contextPolicy: ModelContextPolicy,
        reasoningControl: ModelReasoningControl = .disabled,
        observedAt: Date
    ) {
        self.provider = provider
        self.providerVersion = providerVersion
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName
        self.modelDigest = modelDigest
        self.locallyInstalled = locallyInstalled
        self.estimatedCapabilities = estimatedCapabilities
        self.contextPolicy = contextPolicy
        self.reasoningControl = reasoningControl
        self.observedAt = observedAt
    }
}

enum ModelCapabilityProbe: String, Codable, CaseIterable, Sendable {
    case ordinaryChat = "ordinary_chat"
    case streaming
    case structuredJSON = "structured_json"
    case syntheticToolCall = "synthetic_tool_call"
    case toolResultContinuation = "tool_result_continuation"
    case cancellation
    case contextDeclaration = "context_declaration"
    case reasoningControl = "reasoning_control"
    case syntheticVision = "synthetic_vision"
    case embeddingSingle = "embedding_single"
    case embeddingBatch = "embedding_batch"
}

enum ModelCapabilityProbeStatus: String, Codable, CaseIterable, Sendable {
    case success
    case failed
    case cancelled
    case skipped
}

struct ModelCapabilityDiagnostic: Codable, Hashable, Sendable {
    let probe: ModelCapabilityProbe
    let status: ModelCapabilityProbeStatus
    let reasonCode: String
    let durationMilliseconds: Int

    init(
        probe: ModelCapabilityProbe,
        status: ModelCapabilityProbeStatus,
        reasonCode: String,
        durationMilliseconds: Int
    ) {
        self.probe = probe
        self.status = status
        self.reasonCode = Self.boundedReasonCode(reasonCode)
        self.durationMilliseconds = min(max(durationMilliseconds, 0), 240_000)
    }

    private static func boundedReasonCode(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars)).prefix(120)
        return bounded.isEmpty ? "model_assessment_unspecified" : String(bounded)
    }
}

struct ModelCapabilityAssessment: Codable, Hashable, Sendable {
    // P8E extends the v2 payload with an optional embedding-only proof. Keeping
    // the outer version stable preserves current non-embedding assessments;
    // embedding profiles additionally require a current accepted proof below.
    static let currentAssessmentVersion = "agent-loki.model-assessment.v2"
    static let maximumDiagnostics = 16

    let provider: String
    let providerVersion: String?
    let modelIdentifier: String
    let modelDigest: String?
    let assessmentVersion: String
    let capabilitiesProven: Set<ModelCapability>
    let capabilitiesMissing: Set<ModelCapability>
    let contextPolicy: ModelContextPolicy
    let reasoningControl: ModelReasoningControl?
    let reasoningControlsProven: Set<ModelReasoningControl>?
    let assessedAt: Date
    let durationMilliseconds: Int
    let diagnostics: [ModelCapabilityDiagnostic]
    let embeddingStability: EmbeddingStabilityAssessmentSummary?

    init(
        provider: String,
        providerVersion: String?,
        modelIdentifier: String,
        modelDigest: String?,
        assessmentVersion: String = ModelCapabilityAssessment.currentAssessmentVersion,
        capabilitiesProven: Set<ModelCapability>,
        capabilitiesMissing: Set<ModelCapability>,
        contextPolicy: ModelContextPolicy,
        reasoningControl: ModelReasoningControl? = nil,
        reasoningControlsProven: Set<ModelReasoningControl>? = nil,
        assessedAt: Date,
        durationMilliseconds: Int,
        diagnostics: [ModelCapabilityDiagnostic],
        embeddingStability: EmbeddingStabilityAssessmentSummary? = nil
    ) {
        self.provider = provider
        self.providerVersion = providerVersion
        self.modelIdentifier = modelIdentifier
        self.modelDigest = modelDigest
        self.assessmentVersion = assessmentVersion
        self.capabilitiesProven = capabilitiesProven
        self.capabilitiesMissing = capabilitiesMissing.subtracting(capabilitiesProven)
        self.contextPolicy = contextPolicy
        self.reasoningControl = reasoningControl
        self.reasoningControlsProven = reasoningControlsProven
            ?? reasoningControl.map { Set([$0]) }
        self.assessedAt = assessedAt
        self.durationMilliseconds = min(max(durationMilliseconds, 0), 600_000)
        self.diagnostics = Array(diagnostics.prefix(Self.maximumDiagnostics))
        self.embeddingStability = embeddingStability
    }

    var verifiedReasoningControls: Set<ModelReasoningControl> {
        reasoningControlsProven ?? reasoningControl.map { Set([$0]) } ?? []
    }

    func isCurrent(
        for profile: ModelProfile,
        requiredAssessmentVersion: String = ModelCapabilityAssessment.currentAssessmentVersion
    ) -> Bool {
        let identityIsCurrent =
            assessmentVersion == requiredAssessmentVersion
            && provider == profile.provider
            && providerVersion == profile.providerVersion
            && modelIdentifier == profile.modelIdentifier
            && modelDigest == profile.modelDigest
        guard identityIsCurrent else { return false }
        if profile.estimatedCapabilities.contains(.embedding)
            || ModelCuratedRolePolicy.isDedicatedEmbeddingModel(
                profile.modelIdentifier
            ) {
            return embeddingStability?.isCurrent(for: profile) == true
        }
        return true
    }
}

struct EmbeddingStabilityAssessmentSummary:
    Codable,
    Hashable,
    Sendable
{
    static let currentContractVersion =
        "agent-loki.embedding-stability-assessment.v1"

    let contractVersion: String
    let modelIdentifier: String
    let modelDigest: String
    let ollamaVersion: String
    let requestProfileVersion: String
    let requestProfileHash: String
    let observedDimension: Int
    let explicitDimensions: Int
    let truncate: Bool
    let normalizationVersion: String
    let repetitionCount: Int
    let requestIdentityVerified: Bool
    let parserParityVerified: Bool
    let allValuesFinite: Bool
    let zeroVectorDetected: Bool
    let differentInputCollapseDetected: Bool
    let minimumCosineSimilarity: Double
    let maximumRelativeL2NormDrift: Double
    let minimumL2Norm: Double
    let maximumL2Norm: Double
    let maximumAbsoluteComponentDelta: Double
    let maximumRMSComponentDelta: Double
    let stableTop1: Bool
    let stableOrderedTop5: Bool
    let minimumRankingMargin: Double
    let rankingHashes: [String]
    let reasonCodes: [String]

    init(
        contractVersion: String = Self.currentContractVersion,
        modelIdentifier: String,
        modelDigest: String,
        ollamaVersion: String,
        requestProfileVersion: String,
        requestProfileHash: String,
        observedDimension: Int,
        explicitDimensions: Int,
        truncate: Bool,
        normalizationVersion: String,
        repetitionCount: Int,
        requestIdentityVerified: Bool,
        parserParityVerified: Bool,
        allValuesFinite: Bool,
        zeroVectorDetected: Bool,
        differentInputCollapseDetected: Bool,
        minimumCosineSimilarity: Double,
        maximumRelativeL2NormDrift: Double,
        minimumL2Norm: Double,
        maximumL2Norm: Double,
        maximumAbsoluteComponentDelta: Double,
        maximumRMSComponentDelta: Double,
        stableTop1: Bool,
        stableOrderedTop5: Bool,
        minimumRankingMargin: Double,
        rankingHashes: [String],
        reasonCodes: [String]
    ) {
        self.contractVersion = contractVersion
        self.modelIdentifier = modelIdentifier
        self.modelDigest = modelDigest.lowercased()
        self.ollamaVersion = ollamaVersion
        self.requestProfileVersion = requestProfileVersion
        self.requestProfileHash = requestProfileHash.lowercased()
        self.observedDimension = observedDimension
        self.explicitDimensions = explicitDimensions
        self.truncate = truncate
        self.normalizationVersion = normalizationVersion
        self.repetitionCount = repetitionCount
        self.requestIdentityVerified = requestIdentityVerified
        self.parserParityVerified = parserParityVerified
        self.allValuesFinite = allValuesFinite
        self.zeroVectorDetected = zeroVectorDetected
        self.differentInputCollapseDetected =
            differentInputCollapseDetected
        self.minimumCosineSimilarity = minimumCosineSimilarity
        self.maximumRelativeL2NormDrift =
            maximumRelativeL2NormDrift
        self.minimumL2Norm = minimumL2Norm
        self.maximumL2Norm = maximumL2Norm
        self.maximumAbsoluteComponentDelta =
            maximumAbsoluteComponentDelta
        self.maximumRMSComponentDelta = maximumRMSComponentDelta
        self.stableTop1 = stableTop1
        self.stableOrderedTop5 = stableOrderedTop5
        self.minimumRankingMargin = minimumRankingMargin
        self.rankingHashes = rankingHashes
        self.reasonCodes = reasonCodes
    }

    var accepted: Bool {
        contractVersion == Self.currentContractVersion
            && !modelIdentifier.isEmpty
            && SemanticIndexValidation.validSHA256(modelDigest)
            && !ollamaVersion.isEmpty
            && requestProfileVersion
                == OllamaEmbeddingRequestProfile.currentVersion
            && SemanticIndexValidation.validSHA256(requestProfileHash)
            && (1...OllamaEmbeddingLimits.maximumVectorDimension)
                .contains(observedDimension)
            && explicitDimensions == observedDimension
            && !truncate
            && normalizationVersion
                == OllamaEmbeddingRequestProfile
                    .currentNormalizationVersion
            && repetitionCount >= 3
            && requestIdentityVerified
            && parserParityVerified
            && allValuesFinite
            && !zeroVectorDetected
            && !differentInputCollapseDetected
            && minimumCosineSimilarity.isFinite
            && minimumCosineSimilarity >= 0.99999
            && minimumCosineSimilarity <= 1
            && maximumRelativeL2NormDrift.isFinite
            && maximumRelativeL2NormDrift >= 0
            && maximumRelativeL2NormDrift <= 0.00001
            && minimumL2Norm.isFinite
            && minimumL2Norm > 0
            && maximumL2Norm.isFinite
            && maximumL2Norm >= minimumL2Norm
            && maximumAbsoluteComponentDelta.isFinite
            && maximumAbsoluteComponentDelta >= 0
            && maximumRMSComponentDelta.isFinite
            && maximumRMSComponentDelta >= 0
            && maximumRMSComponentDelta
                <= maximumAbsoluteComponentDelta
            && stableTop1
            && stableOrderedTop5
            && minimumRankingMargin.isFinite
            && minimumRankingMargin > 0
            && rankingHashes.count == 5
            && rankingHashes.allSatisfy(
                SemanticIndexValidation.validSHA256
            )
            && reasonCodes.count == 4
            && Set(reasonCodes) == Set([
                EmbeddingAssessmentReasonCode
                    .requestIdentityVerified.rawValue,
                EmbeddingAssessmentReasonCode
                    .parserParityVerified.rawValue,
                EmbeddingAssessmentReasonCode
                    .boundedNumericalVariance.rawValue,
                EmbeddingAssessmentReasonCode
                    .retrievalStabilityVerified.rawValue,
            ])
    }

    func isCurrent(for profile: ModelProfile) -> Bool {
        let expectedProfile = OllamaEmbeddingRequestProfile(
            dimensions: explicitDimensions
        )
        return accepted
            && modelIdentifier == profile.modelIdentifier
            && modelDigest == profile.modelDigest?.lowercased()
            && ollamaVersion == profile.providerVersion
            && requestProfileHash == expectedProfile.stableHash
    }
}

enum ModelReadiness: String, Codable, CaseIterable, Sendable {
    case notInstalled
    case providerNotRunning
    case modelUnavailable
    case assessmentRequired
    case assessing
    case ready
    case partiallyCompatible
    case incompatible
    case degraded
    case error
}

enum ModelReadinessFailureCode: String, Codable, CaseIterable, Sendable {
    case providerNotInstalled = "model_provider_not_installed"
    case providerNotRunning = "model_provider_not_running"
    case modelUnavailable = "model_unavailable"
    case assessmentMissing = "model_assessment_missing"
    case assessmentStale = "model_assessment_stale"
    case requiredCapabilityMissing = "model_required_capability_missing"
    case incompatible = "model_incompatible"
    case providerDegraded = "model_provider_degraded"
    case assessmentFailed = "model_assessment_failed"
}

struct ModelReadinessFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: ModelReadinessFailureCode
    let missingCapabilities: Set<ModelCapability>

    init(
        _ code: ModelReadinessFailureCode,
        missingCapabilities: Set<ModelCapability> = []
    ) {
        self.code = code
        self.missingCapabilities = missingCapabilities
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .providerNotInstalled:
            "Ollama is not installed. Loki Brief remains available without Agent Loki Chat."
        case .providerNotRunning:
            "Ollama is not running. Loki Brief remains available without Agent Loki Chat."
        case .modelUnavailable:
            "The selected local model is unavailable."
        case .assessmentMissing:
            "Assess the preferred installed model before using it for Agent Loki Chat."
        case .assessmentStale:
            "The installed model or assessment contract changed. Assess the model again."
        case .requiredCapabilityMissing:
            "The model did not prove every capability required by Agent Loki Chat."
        case .incompatible:
            "The model is not compatible with Agent Loki Chat."
        case .providerDegraded:
            "The local model provider is temporarily degraded."
        case .assessmentFailed:
            "The bounded model capability assessment failed."
        }
    }
}

struct ModelReadinessEvaluation: Codable, Hashable, Sendable {
    let readiness: ModelReadiness
    let requiredCapabilitiesMissing: Set<ModelCapability>
    let recommendedCapabilitiesMissing: Set<ModelCapability>
    let deferredCapabilities: Set<ModelCapability>
    let failure: ModelReadinessFailure?

    static func evaluate(
        profile: ModelProfile?,
        assessment: ModelCapabilityAssessment?,
        providerInstalled: Bool,
        providerRunning: Bool,
        modelAvailable: Bool,
        assessing: Bool = false,
        providerDegraded: Bool = false,
        requirements: [ModelCapabilityRequirement] = ModelCapabilityRequirement.agentLokiChat
    ) -> ModelReadinessEvaluation {
        let required = Set(requirements.filter { $0.level == .required }.map(\.capability))
        let recommended = Set(requirements.filter { $0.level == .recommended }.map(\.capability))
        let deferred = Set(requirements.filter { $0.level == .deferred }.map(\.capability))

        func result(
            _ readiness: ModelReadiness,
            requiredMissing: Set<ModelCapability> = required,
            recommendedMissing: Set<ModelCapability> = recommended,
            failure: ModelReadinessFailure?
        ) -> ModelReadinessEvaluation {
            .init(
                readiness: readiness,
                requiredCapabilitiesMissing: requiredMissing,
                recommendedCapabilitiesMissing: recommendedMissing,
                deferredCapabilities: deferred,
                failure: failure
            )
        }

        guard providerInstalled else {
            return result(.notInstalled, failure: .init(.providerNotInstalled))
        }
        guard providerRunning else {
            return result(.providerNotRunning, failure: .init(.providerNotRunning))
        }
        guard let profile, profile.locallyInstalled, modelAvailable else {
            return result(.modelUnavailable, failure: .init(.modelUnavailable))
        }
        if assessing {
            return result(.assessing, failure: nil)
        }
        if providerDegraded {
            return result(.degraded, failure: .init(.providerDegraded))
        }
        guard let assessment else {
            return result(.assessmentRequired, failure: .init(.assessmentMissing))
        }
        guard assessment.isCurrent(for: profile) else {
            return result(.assessmentRequired, failure: .init(.assessmentStale))
        }

        // Estimated capabilities and model names are intentionally absent from
        // this decision. Only the versioned runtime assessment can establish
        // readiness.
        let requiredMissing = required.subtracting(assessment.capabilitiesProven)
        var recommendedMissing = recommended.subtracting(assessment.capabilitiesProven)
        if let contextRequirement = requirements.first(where: {
            $0.capability == .contextWindow && $0.level == .recommended
        }),
           let minimum = contextRequirement.minimumUsableContextTokens,
           (assessment.contextPolicy.bestKnownUsableTokens ?? 0) < minimum {
            recommendedMissing.insert(.contextWindow)
        }
        if requiredMissing.isEmpty {
            return result(
                .ready,
                requiredMissing: [],
                recommendedMissing: recommendedMissing,
                failure: nil
            )
        }
        if !assessment.capabilitiesProven.contains(.chat) {
            return result(
                .incompatible,
                requiredMissing: requiredMissing,
                recommendedMissing: recommendedMissing,
                failure: .init(.incompatible, missingCapabilities: requiredMissing)
            )
        }
        return result(
            .partiallyCompatible,
            requiredMissing: requiredMissing,
            recommendedMissing: recommendedMissing,
            failure: .init(.requiredCapabilityMissing, missingCapabilities: requiredMissing)
        )
    }
}

struct ChatModelSelection: Codable, Hashable, Sendable {
    let provider: String
    let modelIdentifier: String
    let modelDigest: String?
    let assessmentVersion: String
    let selectedAt: Date
}

struct EmbeddingModelSelection: Codable, Hashable, Sendable {
    let provider: String
    let modelIdentifier: String
    let modelDigest: String?
    let selectedAt: Date
}

struct VisionModelSelection: Codable, Hashable, Sendable {
    let provider: String
    let modelIdentifier: String
    let modelDigest: String?
    let selectedAt: Date
}
