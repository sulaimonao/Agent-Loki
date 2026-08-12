import Foundation

enum ModelRole: String, Codable, CaseIterable, Hashable, Sendable {
    case primaryAgent
    case textFallback
    case vision
    case embedding
    case briefSummary

    var displayName: String {
        switch self {
        case .primaryAgent: "Primary"
        case .textFallback: "Text fallback"
        case .vision: "Vision"
        case .embedding: "Embedding"
        case .briefSummary: "Brief summary"
        }
    }

    var requiredCapabilities: Set<ModelCapability> {
        switch self {
        case .primaryAgent:
            [.chat, .streaming, .structuredOutput, .toolCalling, .cancellation]
        case .textFallback:
            [.chat, .streaming, .cancellation]
        case .vision:
            [.chat, .streaming, .vision, .cancellation]
        case .embedding:
            [.embedding]
        case .briefSummary:
            [.chat, .structuredOutput, .cancellation]
        }
    }

    var capabilityRequirements: [ModelCapabilityRequirement] {
        var requirements = requiredCapabilities
            .sorted { $0.rawValue < $1.rawValue }
            .map {
                ModelCapabilityRequirement(
                    capability: $0,
                    level: .required
                )
            }
        if self != .embedding {
            requirements.append(.init(
                capability: .contextWindow,
                level: .recommended,
                minimumUsableContextTokens:
                    ModelContextPolicy.recommendedMinimumUsableTokens
            ))
        }
        if self == .primaryAgent || self == .textFallback {
            requirements.append(.init(capability: .reasoning, level: .recommended))
        }
        return requirements
    }
}

enum ModelLocalityClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case cloud
    case unknown
}

enum ModelInputModality: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case image
}

enum ModelVerifiedToolSupport: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case readOnly = "read_only"
}

enum ModelRoleReadiness: String, Codable, CaseIterable, Hashable, Sendable {
    case unassigned
    case modelUnavailable = "model_unavailable"
    case assessmentRequired = "assessment_required"
    case staleAssessment = "stale_assessment"
    case staleDigest = "stale_digest"
    case partiallyCompatible = "partially_compatible"
    case degraded
    case ready
    case cloudBlocked = "cloud_blocked"
    case inherited
}

enum ModelRoleAssignmentSource: String, Codable, CaseIterable, Hashable, Sendable {
    case curatedDefault = "curated_default"
    case legacyChatPreference = "legacy_chat_preference"
    case legacyBriefSummaryPreference = "legacy_brief_summary_preference"
    case operatorSelection = "operator_selection"
    case configuredInheritance = "configured_inheritance"
}

enum ModelRoleAssignmentDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case discovered
    case recommended
    case selected
    case assessed
}

enum ModelRoleReason {
    static let ready = "model_role_assessed_ready"
    static let unassigned = "model_role_unassigned"
    static let modelUnavailable = "model_role_model_unavailable"
    static let assessmentRequired = "model_role_assessment_required"
    static let assessmentStale = "model_role_assessment_stale"
    static let digestStale = "model_role_assessment_digest_stale"
    static let partiallyCompatible = "model_role_partially_compatible"
    static let degraded = "model_role_degraded"
    static let cloudBlocked = "model_role_cloud_reference_blocked"
    static let embeddingChatBlocked = "model_role_embedding_model_chat_blocked"
    static let configuredInheritance = "model_role_configured_inheritance"
    static let legacyGemma3AssessmentRequired =
        "model_role_legacy_gemma3_replacement_assessment_required"
    static let legacyGemma3ReplacementUnavailable =
        "model_role_legacy_gemma3_replacement_unavailable"
}

enum ModelRoleDomainError: Error, LocalizedError, Equatable {
    case invalidAssignment
    case unassessedExecution
    case cloudExecutionBlocked
    case roleCapabilityMissing
    case invalidReceipt

    var errorDescription: String? {
        switch self {
        case .invalidAssignment:
            "The model-role assignment did not satisfy the bounded role contract."
        case .unassessedExecution:
            "The selected model has not passed the current assessment for this role."
        case .cloudExecutionBlocked:
            "Cloud-classified model references cannot execute through the local model roles."
        case .roleCapabilityMissing:
            "The selected model did not prove every capability required for this role."
        case .invalidReceipt:
            "The privacy-safe model receipt did not satisfy the bounded receipt contract."
        }
    }
}

struct ModelRoleAssignment: Codable, Hashable, Sendable {
    let role: ModelRole
    let requestedProvider: String?
    let requestedModelIdentifier: String?
    let effectiveProvider: String?
    let effectiveModelIdentifier: String?
    let requestedClassification: ModelLocalityClassification
    let effectiveClassification: ModelLocalityClassification
    let modelDigest: String?
    let assessmentReceiptIdentifier: String?
    let assessmentTimestamp: Date?
    let verifiedInputModalities: Set<ModelInputModality>
    let verifiedThinkingModes: Set<ModelReasoningControl>
    let verifiedToolSupport: ModelVerifiedToolSupport
    let verifiedStructuredOutputSupport: Bool
    let verifiedStreamingSupport: Bool
    let configuredContextTokens: Int?
    let effectiveContextTokens: Int?
    let readiness: ModelRoleReadiness
    let reasonCode: String
    let source: ModelRoleAssignmentSource
    let inheritedFromRole: ModelRole?
    let dispositions: Set<ModelRoleAssignmentDisposition>
    let isExplicitlyAssigned: Bool
    let selectedAt: Date
    let updatedAt: Date

    init(
        role: ModelRole,
        requestedProvider: String?,
        requestedModelIdentifier: String?,
        effectiveProvider: String?,
        effectiveModelIdentifier: String?,
        requestedClassification: ModelLocalityClassification,
        effectiveClassification: ModelLocalityClassification,
        modelDigest: String?,
        assessmentReceiptIdentifier: String?,
        assessmentTimestamp: Date?,
        verifiedInputModalities: Set<ModelInputModality>,
        verifiedThinkingModes: Set<ModelReasoningControl>,
        verifiedToolSupport: ModelVerifiedToolSupport,
        verifiedStructuredOutputSupport: Bool,
        verifiedStreamingSupport: Bool,
        configuredContextTokens: Int?,
        effectiveContextTokens: Int?,
        readiness: ModelRoleReadiness,
        reasonCode: String,
        source: ModelRoleAssignmentSource,
        inheritedFromRole: ModelRole? = nil,
        dispositions: Set<ModelRoleAssignmentDisposition>,
        isExplicitlyAssigned: Bool,
        selectedAt: Date,
        updatedAt: Date
    ) {
        self.role = role
        self.requestedProvider = requestedProvider
        self.requestedModelIdentifier = requestedModelIdentifier
        self.effectiveProvider = effectiveProvider
        self.effectiveModelIdentifier = effectiveModelIdentifier
        self.requestedClassification = requestedClassification
        self.effectiveClassification = effectiveClassification
        self.modelDigest = modelDigest
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier
        self.assessmentTimestamp = assessmentTimestamp
        self.verifiedInputModalities = verifiedInputModalities
        self.verifiedThinkingModes = verifiedThinkingModes
        self.verifiedToolSupport = verifiedToolSupport
        self.verifiedStructuredOutputSupport = verifiedStructuredOutputSupport
        self.verifiedStreamingSupport = verifiedStreamingSupport
        self.configuredContextTokens = Self.boundedContext(configuredContextTokens)
        self.effectiveContextTokens = Self.boundedContext(effectiveContextTokens)
        self.readiness = readiness
        self.reasonCode = Self.boundedReasonCode(reasonCode)
        self.source = source
        self.inheritedFromRole = inheritedFromRole
        self.dispositions = dispositions
        self.isExplicitlyAssigned = isExplicitlyAssigned
        self.selectedAt = selectedAt
        self.updatedAt = updatedAt
    }

    var isExecutable: Bool {
        executionFailure == nil
    }

    var executionFailure: ModelRoleDomainError? {
        guard readiness == .ready,
              effectiveModelIdentifier != nil,
              effectiveProvider != nil
        else { return .unassessedExecution }
        guard effectiveClassification == .local else {
            return .cloudExecutionBlocked
        }
        guard assessmentReceiptIdentifier != nil, assessmentTimestamp != nil else {
            return .unassessedExecution
        }
        guard role.requiredCapabilities.isSubset(of: verifiedCapabilities) else {
            return .roleCapabilityMissing
        }
        return nil
    }

    var verifiedCapabilities: Set<ModelCapability> {
        var capabilities: Set<ModelCapability> = []
        if verifiedInputModalities.contains(.text), role != .embedding {
            capabilities.insert(.chat)
        }
        if verifiedInputModalities.contains(.image) {
            capabilities.insert(.vision)
        }
        if role == .embedding, verifiedInputModalities.contains(.text), readiness == .ready {
            capabilities.insert(.embedding)
        }
        if verifiedStreamingSupport {
            capabilities.insert(.streaming)
        }
        if verifiedStructuredOutputSupport {
            capabilities.insert(.structuredOutput)
        }
        if verifiedToolSupport == .readOnly {
            capabilities.insert(.toolCalling)
        }
        if !verifiedThinkingModes.isEmpty {
            capabilities.insert(.reasoning)
        }
        // Cancellation is an assessed transport property. A ready assignment
        // has already passed its complete role requirement set.
        if readiness == .ready {
            capabilities.insert(.cancellation)
        }
        return capabilities
    }

    func validatedForPersistence() throws -> Self {
        guard inheritedFromRole == nil || (
            role == .briefSummary
                && inheritedFromRole == .primaryAgent
                && readiness == .inherited
                && effectiveModelIdentifier == nil
        ) else {
            throw ModelRoleDomainError.invalidAssignment
        }
        if effectiveModelIdentifier != nil, let failure = executionFailure {
            throw failure
        }
        if requestedClassification == .cloud || effectiveClassification == .cloud {
            guard effectiveModelIdentifier == nil, readiness == .cloudBlocked else {
                throw ModelRoleDomainError.cloudExecutionBlocked
            }
        }
        return self
    }

    static func unassigned(
        role: ModelRole,
        readiness: ModelRoleReadiness = .unassigned,
        reasonCode: String = ModelRoleReason.unassigned,
        source: ModelRoleAssignmentSource,
        selectedAt: Date,
        inheritedFromRole: ModelRole? = nil
    ) -> Self {
        .init(
            role: role,
            requestedProvider: nil,
            requestedModelIdentifier: nil,
            effectiveProvider: nil,
            effectiveModelIdentifier: nil,
            requestedClassification: .unknown,
            effectiveClassification: .unknown,
            modelDigest: nil,
            assessmentReceiptIdentifier: nil,
            assessmentTimestamp: nil,
            verifiedInputModalities: [],
            verifiedThinkingModes: [],
            verifiedToolSupport: .none,
            verifiedStructuredOutputSupport: false,
            verifiedStreamingSupport: false,
            configuredContextTokens: nil,
            effectiveContextTokens: nil,
            readiness: readiness,
            reasonCode: reasonCode,
            source: source,
            inheritedFromRole: inheritedFromRole,
            dispositions: [],
            isExplicitlyAssigned: source != .curatedDefault
                && source != .configuredInheritance,
            selectedAt: selectedAt,
            updatedAt: selectedAt
        )
    }

    static func unavailable(
        role: ModelRole,
        provider: String,
        modelIdentifier: String,
        classification: ModelLocalityClassification,
        readiness: ModelRoleReadiness,
        reasonCode: String,
        source: ModelRoleAssignmentSource,
        recommended: Bool,
        explicitlyAssigned: Bool,
        selectedAt: Date
    ) -> Self {
        var dispositions: Set<ModelRoleAssignmentDisposition> = [.selected]
        if recommended { dispositions.insert(.recommended) }
        return .init(
            role: role,
            requestedProvider: provider,
            requestedModelIdentifier: modelIdentifier,
            effectiveProvider: nil,
            effectiveModelIdentifier: nil,
            requestedClassification: classification,
            effectiveClassification: .unknown,
            modelDigest: nil,
            assessmentReceiptIdentifier: nil,
            assessmentTimestamp: nil,
            verifiedInputModalities: [],
            verifiedThinkingModes: [],
            verifiedToolSupport: .none,
            verifiedStructuredOutputSupport: false,
            verifiedStreamingSupport: false,
            configuredContextTokens: nil,
            effectiveContextTokens: nil,
            readiness: readiness,
            reasonCode: reasonCode,
            source: source,
            dispositions: dispositions,
            isExplicitlyAssigned: explicitlyAssigned,
            selectedAt: selectedAt,
            updatedAt: selectedAt
        )
    }

    private static func boundedContext(_ value: Int?) -> Int? {
        guard let value,
              value > 0,
              value <= ModelContextPolicy.maximumAcceptedDeclarationTokens
        else { return nil }
        return value
    }

    private static func boundedReasonCode(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || "_-.".unicodeScalars.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars)).prefix(120)
        return bounded.isEmpty ? ModelRoleReason.unassigned : String(bounded)
    }
}

struct ModelRoleCandidate: Codable, Hashable, Sendable {
    let profile: ModelProfile
    let assessmentReceiptIdentifier: String?
    let assessment: ModelCapabilityAssessment?

    func assignment(
        for role: ModelRole,
        source: ModelRoleAssignmentSource,
        explicitlyAssigned: Bool,
        recommended: Bool,
        selectedAt: Date
    ) -> ModelRoleAssignment {
        let classification = ModelCuratedRolePolicy.classification(
            modelIdentifier: profile.modelIdentifier
        )
        var dispositions: Set<ModelRoleAssignmentDisposition> = [.selected]
        if profile.locallyInstalled { dispositions.insert(.discovered) }
        if recommended { dispositions.insert(.recommended) }
        if assessment != nil { dispositions.insert(.assessed) }

        func result(
            readiness: ModelRoleReadiness,
            reasonCode: String,
            effective: Bool,
            verifiedAssessment: ModelCapabilityAssessment? = nil
        ) -> ModelRoleAssignment {
            let assessment = verifiedAssessment ?? self.assessment
            var modalities: Set<ModelInputModality> = []
            if assessment?.capabilitiesProven.contains(.chat) == true
                || assessment?.capabilitiesProven.contains(.embedding) == true {
                modalities.insert(.text)
            }
            if assessment?.capabilitiesProven.contains(.vision) == true {
                modalities.insert(.image)
            }
            let thinkingModes: Set<ModelReasoningControl>
            if assessment?.capabilitiesProven.contains(.reasoning) == true,
               let assessment {
                thinkingModes = assessment.verifiedReasoningControls
            } else {
                thinkingModes = []
            }
            return .init(
                role: role,
                requestedProvider: profile.provider,
                requestedModelIdentifier: profile.modelIdentifier,
                effectiveProvider: effective ? profile.provider : nil,
                effectiveModelIdentifier: effective ? profile.modelIdentifier : nil,
                requestedClassification: classification,
                effectiveClassification: effective ? classification : .unknown,
                modelDigest: profile.modelDigest,
                assessmentReceiptIdentifier: assessmentReceiptIdentifier,
                assessmentTimestamp: assessment?.assessedAt,
                verifiedInputModalities: modalities,
                verifiedThinkingModes: thinkingModes,
                verifiedToolSupport: assessment?.capabilitiesProven.contains(.toolCalling) == true
                    ? .readOnly
                    : .none,
                verifiedStructuredOutputSupport:
                    assessment?.capabilitiesProven.contains(.structuredOutput) == true,
                verifiedStreamingSupport:
                    assessment?.capabilitiesProven.contains(.streaming) == true,
                configuredContextTokens: profile.contextPolicy.bestKnownUsableTokens,
                effectiveContextTokens: assessment?.contextPolicy.bestKnownUsableTokens,
                readiness: readiness,
                reasonCode: reasonCode,
                source: source,
                dispositions: dispositions,
                isExplicitlyAssigned: explicitlyAssigned,
                selectedAt: selectedAt,
                updatedAt: selectedAt
            )
        }

        guard classification != .cloud else {
            return result(readiness: .cloudBlocked, reasonCode: ModelRoleReason.cloudBlocked, effective: false)
        }
        guard profile.locallyInstalled else {
            return result(
                readiness: .modelUnavailable,
                reasonCode: ModelRoleReason.modelUnavailable,
                effective: false
            )
        }
        guard !(role != .embedding
            && ModelCuratedRolePolicy.isDedicatedEmbeddingModel(profile.modelIdentifier))
        else {
            return result(
                readiness: .partiallyCompatible,
                reasonCode: ModelRoleReason.embeddingChatBlocked,
                effective: false
            )
        }
        guard let assessment, assessmentReceiptIdentifier != nil else {
            return result(
                readiness: .assessmentRequired,
                reasonCode: ModelRoleReason.assessmentRequired,
                effective: false
            )
        }
        guard assessment.isCurrent(for: profile) else {
            if assessment.modelDigest != profile.modelDigest {
                return result(
                    readiness: .staleDigest,
                    reasonCode: ModelRoleReason.digestStale,
                    effective: false
                )
            }
            return result(
                readiness: .staleAssessment,
                reasonCode: ModelRoleReason.assessmentStale,
                effective: false
            )
        }
        guard role.requiredCapabilities.isSubset(of: assessment.capabilitiesProven) else {
            return result(
                readiness: .partiallyCompatible,
                reasonCode: ModelRoleReason.partiallyCompatible,
                effective: false,
                verifiedAssessment: assessment
            )
        }
        return result(
            readiness: .ready,
            reasonCode: ModelRoleReason.ready,
            effective: true,
            verifiedAssessment: assessment
        )
    }
}

enum ModelCuratedRolePolicy {
    static let recommendedGemma4 = "gemma4:12b"
    static let recommendedGPTOSS = "gpt-oss:20b"
    static let recommendedEmbedding = "qwen3-embedding:0.6b"

    static func recommendedModelIdentifier(for role: ModelRole) -> String? {
        switch role {
        case .primaryAgent, .vision:
            recommendedGemma4
        case .textFallback:
            recommendedGPTOSS
        case .embedding:
            recommendedEmbedding
        case .briefSummary:
            nil
        }
    }

    static func classification(modelIdentifier: String) -> ModelLocalityClassification {
        guard !modelIdentifier.isEmpty else { return .unknown }
        return OllamaModelLocalityPolicy.isCloudReference(modelIdentifier) ? .cloud : .local
    }

    static func isRecommended(_ modelIdentifier: String, for role: ModelRole) -> Bool {
        guard let recommendation = recommendedModelIdentifier(for: role) else {
            return false
        }
        return normalized(modelIdentifier) == normalized(recommendation)
    }

    static func isLegacyGemma3(_ modelIdentifier: String) -> Bool {
        let value = normalized(modelIdentifier)
        return value == "gemma3" || value.hasPrefix("gemma3:")
    }

    static func isGemma4(_ modelIdentifier: String) -> Bool {
        let value = normalized(modelIdentifier)
        return value == "gemma4" || value.hasPrefix("gemma4:")
    }

    static func isGPTOSS(_ modelIdentifier: String) -> Bool {
        let value = normalized(modelIdentifier)
        return value == "gpt-oss" || value.hasPrefix("gpt-oss:")
    }

    static func isDedicatedEmbeddingModel(_ modelIdentifier: String) -> Bool {
        let value = normalized(modelIdentifier)
        return value == "qwen3-embedding" || value.hasPrefix("qwen3-embedding:")
    }

    static var allCuratedModelIdentifiers: Set<String> {
        [recommendedGemma4, recommendedGPTOSS, recommendedEmbedding]
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct LegacyModelPreference: Codable, Hashable, Sendable {
    let provider: String
    let modelIdentifier: String
    let modelDigest: String?
    let assessmentVersion: String?
    let selectedAt: Date
}

struct ModelRoleMigrationInput: Codable, Hashable, Sendable {
    let legacyChatPreference: LegacyModelPreference?
    let legacyBriefSummaryPreference: LegacyModelPreference?
    let candidates: [ModelRoleCandidate]
    let migratedAt: Date
}

struct P8ModelRoleMigrationReport: Codable, Hashable, Sendable {
    let didRun: Bool
    let legacyChatPreferenceMigrated: Bool
    let legacyBriefSummaryPreferenceMigrated: Bool
    let legacyGemma3PreferenceCount: Int
    let roleCount: Int
    let readyRoleCount: Int
    let reasonCode: String

    static let notRequired = P8ModelRoleMigrationReport(
        didRun: false,
        legacyChatPreferenceMigrated: false,
        legacyBriefSummaryPreferenceMigrated: false,
        legacyGemma3PreferenceCount: 0,
        roleCount: 0,
        readyRoleCount: 0,
        reasonCode: "p8_model_role_migration_not_required"
    )

    static let alreadyCompleted = P8ModelRoleMigrationReport(
        didRun: false,
        legacyChatPreferenceMigrated: false,
        legacyBriefSummaryPreferenceMigrated: false,
        legacyGemma3PreferenceCount: 0,
        roleCount: ModelRole.allCases.count,
        readyRoleCount: 0,
        reasonCode: "p8_model_role_migration_already_completed"
    )
}

enum ModelRoleMigrationPolicy {
    static func assignments(for input: ModelRoleMigrationInput) -> [ModelRoleAssignment] {
        let primaryLegacy = input.legacyChatPreference ?? input.legacyBriefSummaryPreference
        let primary = primaryLegacy.map {
            resolveLegacy(
                $0,
                role: .primaryAgent,
                source: input.legacyChatPreference == nil
                    ? .legacyBriefSummaryPreference
                    : .legacyChatPreference,
                candidates: input.candidates,
                migratedAt: input.migratedAt
            )
        } ?? resolveCurated(
            role: .primaryAgent,
            candidates: input.candidates,
            migratedAt: input.migratedAt
        )
        let fallback = resolveCurated(
            role: .textFallback,
            candidates: input.candidates,
            migratedAt: input.migratedAt
        )
        let vision = resolveCurated(
            role: .vision,
            candidates: input.candidates,
            migratedAt: input.migratedAt
        )
        let embedding = resolveCurated(
            role: .embedding,
            candidates: input.candidates,
            migratedAt: input.migratedAt
        )
        let summary = input.legacyBriefSummaryPreference.map {
            resolveLegacy(
                $0,
                role: .briefSummary,
                source: .legacyBriefSummaryPreference,
                candidates: input.candidates,
                migratedAt: input.migratedAt
            )
        } ?? ModelRoleAssignment.unassigned(
            role: .briefSummary,
            readiness: .inherited,
            reasonCode: ModelRoleReason.configuredInheritance,
            source: .configuredInheritance,
            selectedAt: input.migratedAt,
            inheritedFromRole: .primaryAgent
        )
        return [primary, fallback, vision, embedding, summary]
            .sorted { $0.role.rawValue < $1.role.rawValue }
    }

    private static func resolveCurated(
        role: ModelRole,
        candidates: [ModelRoleCandidate],
        migratedAt: Date
    ) -> ModelRoleAssignment {
        guard let identifier = ModelCuratedRolePolicy.recommendedModelIdentifier(for: role) else {
            return .unassigned(
                role: role,
                source: .curatedDefault,
                selectedAt: migratedAt
            )
        }
        if let candidate = exactCandidate(identifier, candidates: candidates) {
            return candidate.assignment(
                for: role,
                source: .curatedDefault,
                explicitlyAssigned: false,
                recommended: true,
                selectedAt: migratedAt
            )
        }
        return .unavailable(
            role: role,
            provider: "ollama",
            modelIdentifier: identifier,
            classification: .local,
            readiness: .modelUnavailable,
            reasonCode: ModelRoleReason.modelUnavailable,
            source: .curatedDefault,
            recommended: true,
            explicitlyAssigned: false,
            selectedAt: migratedAt
        )
    }

    private static func resolveLegacy(
        _ preference: LegacyModelPreference,
        role: ModelRole,
        source: ModelRoleAssignmentSource,
        candidates: [ModelRoleCandidate],
        migratedAt: Date
    ) -> ModelRoleAssignment {
        if ModelCuratedRolePolicy.isLegacyGemma3(preference.modelIdentifier) {
            let replacementFamilies: [(String) -> Bool] = [
                ModelCuratedRolePolicy.isGemma4,
                ModelCuratedRolePolicy.isGPTOSS,
            ]
            for family in replacementFamilies {
                let matches = candidates
                    .filter { family($0.profile.modelIdentifier) }
                    .sorted { $0.profile.modelIdentifier < $1.profile.modelIdentifier }
                for candidate in matches {
                    let assignment = candidate.assignment(
                        for: role,
                        source: source,
                        explicitlyAssigned: true,
                        recommended: ModelCuratedRolePolicy.isRecommended(
                            candidate.profile.modelIdentifier,
                            for: role
                        ),
                        selectedAt: migratedAt
                    )
                    if assignment.readiness == .ready {
                        return assignment
                    }
                }
            }
            let replacementWasDiscovered = candidates.contains {
                ModelCuratedRolePolicy.isGemma4($0.profile.modelIdentifier)
                    || ModelCuratedRolePolicy.isGPTOSS($0.profile.modelIdentifier)
            }
            return .unassigned(
                role: role,
                readiness: replacementWasDiscovered ? .assessmentRequired : .modelUnavailable,
                reasonCode: replacementWasDiscovered
                    ? ModelRoleReason.legacyGemma3AssessmentRequired
                    : ModelRoleReason.legacyGemma3ReplacementUnavailable,
                source: source,
                selectedAt: migratedAt
            )
        }

        if let candidate = exactCandidate(preference.modelIdentifier, candidates: candidates) {
            return candidate.assignment(
                for: role,
                source: source,
                explicitlyAssigned: true,
                recommended: ModelCuratedRolePolicy.isRecommended(
                    preference.modelIdentifier,
                    for: role
                ),
                selectedAt: migratedAt
            )
        }
        let classification = ModelCuratedRolePolicy.classification(
            modelIdentifier: preference.modelIdentifier
        )
        return .unavailable(
            role: role,
            provider: preference.provider,
            modelIdentifier: preference.modelIdentifier,
            classification: classification,
            readiness: classification == .cloud ? .cloudBlocked : .modelUnavailable,
            reasonCode: classification == .cloud
                ? ModelRoleReason.cloudBlocked
                : ModelRoleReason.modelUnavailable,
            source: source,
            recommended: false,
            explicitlyAssigned: true,
            selectedAt: migratedAt
        )
    }

    private static func exactCandidate(
        _ modelIdentifier: String,
        candidates: [ModelRoleCandidate]
    ) -> ModelRoleCandidate? {
        candidates
            .filter {
                $0.profile.modelIdentifier.caseInsensitiveCompare(modelIdentifier) == .orderedSame
            }
            .sorted {
                ($0.assessment?.assessedAt ?? .distantPast)
                    > ($1.assessment?.assessedAt ?? .distantPast)
            }
            .first
    }
}

enum ReasoningMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fast
    case balanced
    case deep

    var displayName: String { rawValue.capitalized }
}

enum ReasoningModeAvailability: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case reduced
    case unavailable
}

struct ReasoningModeResolution: Codable, Hashable, Sendable {
    let requestedMode: ReasoningMode
    let control: ModelReasoningControl?
    let availability: ReasoningModeAvailability
    let reasonCode: String

    static func resolve(
        _ mode: ReasoningMode,
        modelIdentifier: String,
        verifiedControls: Set<ModelReasoningControl>
    ) -> Self {
        let tieredControl: ModelReasoningControl
        switch mode {
        case .fast: tieredControl = .ollamaLow
        case .balanced: tieredControl = .ollamaMedium
        case .deep: tieredControl = .ollamaHigh
        }

        if ModelCuratedRolePolicy.isGPTOSS(modelIdentifier) {
            guard verifiedControls.contains(tieredControl) else {
                return .init(
                    requestedMode: mode,
                    control: nil,
                    availability: .unavailable,
                    reasonCode: "reasoning_gpt_oss_level_not_verified"
                )
            }
            return .init(
                requestedMode: mode,
                control: tieredControl,
                availability: .available,
                reasonCode: "reasoning_gpt_oss_level_verified"
            )
        }

        if verifiedControls.contains(tieredControl) {
            return .init(
                requestedMode: mode,
                control: tieredControl,
                availability: .available,
                reasonCode: "reasoning_model_level_verified"
            )
        }
        switch mode {
        case .fast:
            return .init(
                requestedMode: mode,
                control: .disabled,
                availability: .available,
                reasonCode: "reasoning_fast_without_private_thinking"
            )
        case .balanced where verifiedControls.contains(.ollamaBoolean):
            return .init(
                requestedMode: mode,
                control: .ollamaBoolean,
                availability: .reduced,
                reasonCode: "reasoning_boolean_control_verified"
            )
        case .balanced, .deep:
            return .init(
                requestedMode: mode,
                control: nil,
                availability: .unavailable,
                reasonCode: "reasoning_mode_not_verified"
            )
        }
    }

    static func availableModes(
        modelIdentifier: String,
        verifiedControls: Set<ModelReasoningControl>
    ) -> [ReasoningMode] {
        ReasoningMode.allCases.filter {
            resolve(
                $0,
                modelIdentifier: modelIdentifier,
                verifiedControls: verifiedControls
            ).availability != .unavailable
        }
    }
}

enum ModelReasoningCompletionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case completed
    case cancelled
    case failed
}

struct ModelReasoningUsage: Codable, Hashable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens.map { max(0, $0) }
        self.completionTokens = completionTokens.map { max(0, $0) }
        self.totalTokens = totalTokens.map { max(0, $0) }
    }
}

struct ModelReasoningReceipt: Codable, Hashable, Sendable {
    let id: String
    let traceID: String
    let reasoningMode: ReasoningMode
    let modelIdentifier: String
    let assessmentReceiptIdentifier: String
    let startedAt: Date
    let durationMilliseconds: Int
    let usage: ModelReasoningUsage
    let toolLoopCount: Int
    let status: ModelReasoningCompletionStatus
    let reasonCode: String

    init(
        id: String,
        traceID: String,
        reasoningMode: ReasoningMode,
        modelIdentifier: String,
        assessmentReceiptIdentifier: String,
        startedAt: Date,
        durationMilliseconds: Int,
        usage: ModelReasoningUsage,
        toolLoopCount: Int,
        status: ModelReasoningCompletionStatus,
        reasonCode: String
    ) {
        self.id = String(id.prefix(256))
        self.traceID = String(traceID.prefix(256))
        self.reasoningMode = reasoningMode
        self.modelIdentifier = String(modelIdentifier.prefix(256))
        self.assessmentReceiptIdentifier = String(assessmentReceiptIdentifier.prefix(256))
        self.startedAt = startedAt
        self.durationMilliseconds = min(max(durationMilliseconds, 0), 3_600_000)
        self.usage = usage
        self.toolLoopCount = min(max(toolLoopCount, 0), 32)
        self.status = status
        self.reasonCode = String(reasonCode.prefix(120))
    }
}

/// Raw reasoning exists only in this non-Codable in-memory value. Terminal
/// transitions clear it before returning the persistence-safe receipt.
struct EphemeralModelReasoningState: Sendable {
    static let maximumVisibleCharacters = 64_000

    let receiptIdentifier: String
    let traceID: String
    let reasoningMode: ReasoningMode
    let modelIdentifier: String
    let assessmentReceiptIdentifier: String
    let startedAt: Date
    private(set) var visibleThinking: String = ""
    private(set) var toolLoopCount = 0

    init(
        receiptIdentifier: String,
        traceID: String,
        reasoningMode: ReasoningMode,
        modelIdentifier: String,
        assessmentReceiptIdentifier: String,
        startedAt: Date
    ) {
        self.receiptIdentifier = receiptIdentifier
        self.traceID = traceID
        self.reasoningMode = reasoningMode
        self.modelIdentifier = modelIdentifier
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier
        self.startedAt = startedAt
    }

    mutating func appendThinking(_ chunk: String) {
        guard !chunk.isEmpty, visibleThinking.count < Self.maximumVisibleCharacters else {
            return
        }
        visibleThinking.append(
            contentsOf: chunk.prefix(Self.maximumVisibleCharacters - visibleThinking.count)
        )
    }

    mutating func recordToolLoop() {
        toolLoopCount = min(toolLoopCount + 1, 32)
    }

    mutating func clear() {
        visibleThinking.removeAll(keepingCapacity: false)
    }

    mutating func finish(
        at completedAt: Date,
        status: ModelReasoningCompletionStatus,
        usage: ModelReasoningUsage,
        reasonCode: String
    ) -> ModelReasoningReceipt {
        let receipt = ModelReasoningReceipt(
            id: receiptIdentifier,
            traceID: traceID,
            reasoningMode: reasoningMode,
            modelIdentifier: modelIdentifier,
            assessmentReceiptIdentifier: assessmentReceiptIdentifier,
            startedAt: startedAt,
            durationMilliseconds: Int(
                max(0, completedAt.timeIntervalSince(startedAt) * 1_000)
            ),
            usage: usage,
            toolLoopCount: toolLoopCount,
            status: status,
            reasonCode: reasonCode
        )
        clear()
        return receipt
    }
}

enum ModelRoutingStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case blocked
}

enum ModelRoutingSwitchStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case configuredInheritance = "configured_inheritance"
    case visibleCrossRole = "visible_cross_role"
    case visibleExplicitFallback = "visible_explicit_fallback"
    case blocked
}

struct ModelRoutingReceipt: Codable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let event: String
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: ModelRoutingStatus
    let reasonCode: String
    let durationMilliseconds: Int
    let requestedRole: ModelRole
    let selectedRole: ModelRole?
    let requestedModelIdentifier: String?
    let effectiveModelIdentifier: String?
    let requestedModelClassification: ModelLocalityClassification
    let effectiveModelClassification: ModelLocalityClassification
    let assessmentReceiptIdentifier: String?
    let switchStatus: ModelRoutingSwitchStatus
    let effectiveContextTokens: Int?
    let attachmentsPresent: Bool

    init(
        id: String,
        timestamp: Date,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        status: ModelRoutingStatus,
        reasonCode: String,
        durationMilliseconds: Int = 0,
        requestedRole: ModelRole,
        selectedRole: ModelRole?,
        requestedModelIdentifier: String?,
        effectiveModelIdentifier: String?,
        requestedModelClassification: ModelLocalityClassification,
        effectiveModelClassification: ModelLocalityClassification,
        assessmentReceiptIdentifier: String?,
        switchStatus: ModelRoutingSwitchStatus,
        effectiveContextTokens: Int?,
        attachmentsPresent: Bool
    ) {
        self.id = String(id.prefix(256))
        self.timestamp = timestamp
        self.event = "model.routing.completed"
        self.traceID = String(traceID.prefix(256))
        self.spanID = String(spanID.prefix(256))
        self.parentSpanID = parentSpanID.map { String($0.prefix(256)) }
        self.component = "model_router"
        self.status = status
        self.reasonCode = String(reasonCode.prefix(120))
        self.durationMilliseconds = min(max(durationMilliseconds, 0), 60_000)
        self.requestedRole = requestedRole
        self.selectedRole = selectedRole
        self.requestedModelIdentifier = requestedModelIdentifier.map { String($0.prefix(256)) }
        self.effectiveModelIdentifier = effectiveModelIdentifier.map { String($0.prefix(256)) }
        self.requestedModelClassification = requestedModelClassification
        self.effectiveModelClassification = effectiveModelClassification
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier.map {
            String($0.prefix(256))
        }
        self.switchStatus = switchStatus
        self.effectiveContextTokens = effectiveContextTokens
        self.attachmentsPresent = attachmentsPresent
    }
}

struct ModelRoutingResult: Codable, Hashable, Sendable {
    let receipt: ModelRoutingReceipt
    let userFacingNotice: String?

    var maySubmit: Bool { receipt.status == .ready }
}

enum ModelRoleRouter {
    static func route(
        requestedRole: ModelRole,
        attachmentsPresent: Bool,
        assignments: [ModelRoleAssignment],
        explicitFallbackRole: ModelRole? = nil,
        receiptIdentifier: String,
        traceID: String,
        spanID: String,
        parentSpanID: String? = nil,
        at date: Date
    ) -> ModelRoutingResult {
        let byRole = Dictionary(uniqueKeysWithValues: assignments.map { ($0.role, $0) })
        let requested = byRole[requestedRole]

        if attachmentsPresent,
           [.primaryAgent, .textFallback, .briefSummary].contains(requestedRole) {
            guard let vision = byRole[.vision], vision.isExecutable,
                  let model = vision.effectiveModelIdentifier else {
                return blocked(
                    requestedRole: requestedRole,
                    requested: requested,
                    attachmentsPresent: true,
                    reasonCode: "model_routing_verified_vision_unavailable",
                    receiptIdentifier: receiptIdentifier,
                    traceID: traceID,
                    spanID: spanID,
                    parentSpanID: parentSpanID,
                    at: date
                )
            }
            return ready(
                requestedRole: requestedRole,
                requested: requested,
                selectedRole: .vision,
                selected: vision,
                switchStatus: .visibleCrossRole,
                notice: "This request contains an image.\nUsing the verified vision model: \(model).",
                attachmentsPresent: true,
                reasonCode: "model_routing_image_to_verified_vision",
                receiptIdentifier: receiptIdentifier,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                at: date
            )
        }

        if let requested, requested.readiness == .inherited,
           let inheritedRole = requested.inheritedFromRole,
           let inherited = byRole[inheritedRole],
           inherited.isExecutable {
            return ready(
                requestedRole: requestedRole,
                requested: requested,
                selectedRole: inheritedRole,
                selected: inherited,
                switchStatus: .configuredInheritance,
                notice: nil,
                attachmentsPresent: attachmentsPresent,
                reasonCode: "model_routing_configured_inheritance",
                receiptIdentifier: receiptIdentifier,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                at: date
            )
        }

        if let requested, requested.isExecutable {
            return ready(
                requestedRole: requestedRole,
                requested: requested,
                selectedRole: requestedRole,
                selected: requested,
                switchStatus: .none,
                notice: nil,
                attachmentsPresent: attachmentsPresent,
                reasonCode: "model_routing_requested_role_ready",
                receiptIdentifier: receiptIdentifier,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                at: date
            )
        }

        if let fallbackRole = explicitFallbackRole,
           fallbackRole != requestedRole,
           let fallback = byRole[fallbackRole],
           fallback.isExecutable,
           let model = fallback.effectiveModelIdentifier {
            return ready(
                requestedRole: requestedRole,
                requested: requested,
                selectedRole: fallbackRole,
                selected: fallback,
                switchStatus: .visibleExplicitFallback,
                notice: "Using the explicitly selected fallback model: \(model).",
                attachmentsPresent: attachmentsPresent,
                reasonCode: "model_routing_explicit_fallback",
                receiptIdentifier: receiptIdentifier,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                at: date
            )
        }

        return blocked(
            requestedRole: requestedRole,
            requested: requested,
            attachmentsPresent: attachmentsPresent,
            reasonCode: requested?.reasonCode ?? "model_routing_role_unassigned",
            receiptIdentifier: receiptIdentifier,
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            at: date
        )
    }

    private static func ready(
        requestedRole: ModelRole,
        requested: ModelRoleAssignment?,
        selectedRole: ModelRole,
        selected: ModelRoleAssignment,
        switchStatus: ModelRoutingSwitchStatus,
        notice: String?,
        attachmentsPresent: Bool,
        reasonCode: String,
        receiptIdentifier: String,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        at date: Date
    ) -> ModelRoutingResult {
        .init(
            receipt: .init(
                id: receiptIdentifier,
                timestamp: date,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                status: .ready,
                reasonCode: reasonCode,
                requestedRole: requestedRole,
                selectedRole: selectedRole,
                requestedModelIdentifier: requested?.requestedModelIdentifier,
                effectiveModelIdentifier: selected.effectiveModelIdentifier,
                requestedModelClassification:
                    requested?.requestedClassification ?? .unknown,
                effectiveModelClassification: selected.effectiveClassification,
                assessmentReceiptIdentifier: selected.assessmentReceiptIdentifier,
                switchStatus: switchStatus,
                effectiveContextTokens: selected.effectiveContextTokens,
                attachmentsPresent: attachmentsPresent
            ),
            userFacingNotice: notice
        )
    }

    private static func blocked(
        requestedRole: ModelRole,
        requested: ModelRoleAssignment?,
        attachmentsPresent: Bool,
        reasonCode: String,
        receiptIdentifier: String,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        at date: Date
    ) -> ModelRoutingResult {
        let notice: String? = reasonCode
            == "model_routing_verified_vision_unavailable"
            ? """
              This request contains an image.
              Assign and assess a compatible Vision model before sending.
              """
            : nil
        return .init(
            receipt: .init(
                id: receiptIdentifier,
                timestamp: date,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                status: .blocked,
                reasonCode: reasonCode,
                requestedRole: requestedRole,
                selectedRole: nil,
                requestedModelIdentifier: requested?.requestedModelIdentifier,
                effectiveModelIdentifier: nil,
                requestedModelClassification:
                    requested?.requestedClassification ?? .unknown,
                effectiveModelClassification: .unknown,
                assessmentReceiptIdentifier: nil,
                switchStatus: .blocked,
                effectiveContextTokens: nil,
                attachmentsPresent: attachmentsPresent
            ),
            userFacingNotice: notice
        )
    }
}
