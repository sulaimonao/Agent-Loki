import Foundation

enum LokiChatLimits {
    static let maximumConversationTitleCharacters = 120
    static let maximumMessageCharacters = 128 * 1_024
    static let maximumContextIdentifierCharacters = 512
    static let maximumEvidenceLabelCharacters = 320
    static let maximumStoredEvidenceExcerptCharacters = 500
    static let maximumEvidenceIdentifierCharacters = 512
    static let maximumDirectSourceURLCharacters = 4_096
    static let maximumFailureMessageCharacters = 500
    static let maximumMetadataCharacters = 512
    static let maximumAnswerSegmentsPerMessage = 64
    static let maximumEvidenceReferencesPerMessage = 64
    static let maximumToolReceiptsPerMessage = 32
    static let maximumToolArgumentKeys = 32
    static let maximumConversationPageSize = 100
    static let defaultConversationPageSize = 50
    static let minimumCustomRetentionDays = 1
    static let maximumCustomRetentionDays = 3_650
    static let maximumExportBytes = 2 * 1_024 * 1_024
}

enum LokiMessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case system

    var isUserVisiblePersistedRole: Bool {
        self == .user || self == .assistant
    }
}

enum LokiMessageState: String, Codable, CaseIterable, Sendable {
    case pending
    case waitingForFirstToken = "waiting_for_first_token"
    case streaming
    case toolRequested = "tool_requested"
    case toolExecuting = "tool_executing"
    case completed
    case canceled
    case failed
    case interrupted
    case sourceEvidenceDeleted = "source_evidence_deleted"

    var isTransient: Bool {
        switch self {
        case .pending, .waitingForFirstToken, .streaming, .toolRequested, .toolExecuting:
            true
        case .completed, .canceled, .failed, .interrupted, .sourceEvidenceDeleted:
            false
        }
    }

    var isTerminal: Bool { !isTransient }
}

enum LokiChatContextScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case thisBrief = "this_brief"
    case today
    case vault
    case connectedSources = "connected_sources"
    case history
    case journal
    case goalsAndTasks = "goals_and_tasks"
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisBrief: "This Brief"
        case .today: "Today"
        case .vault: "Vault"
        case .connectedSources: "Connected Sources"
        case .history: "History"
        case .journal: "Journal"
        case .goalsAndTasks: "Goals & Tasks"
        case .web: "Web"
        }
    }

    var isImplementedInP7: Bool {
        switch self {
        case .thisBrief, .today, .vault, .connectedSources, .history: true
        case .journal, .goalsAndTasks, .web: false
        }
    }

    static var implementedCases: [Self] { allCases.filter(\.isImplementedInP7) }
    static var deferredCases: [Self] { allCases.filter { !$0.isImplementedInP7 } }
}

enum LokiChatAnswerClassification: String, Codable, CaseIterable, Sendable {
    case observed
    case inferred
    case generated

    var displayName: String {
        switch self {
        case .observed: "Observed"
        case .inferred: "Inferred"
        case .generated: "Generated"
        }
    }
}

enum LokiEvidenceSourceKind: String, Codable, CaseIterable, Sendable {
    case brief
    case briefHistory = "brief_history"
    case vault
    case feed
    case slack
    case connectedSourceStatus = "connected_source_status"
    case deliveryStatus = "delivery_status"
    case updateStatus = "update_status"
    case localAccountEvidence = "local_account_evidence"
    case webResearch = "web_research"
}

enum LokiEvidenceTrustClassification: String, Codable, CaseIterable, Sendable {
    case localAuthoritative = "local_authoritative"
    case authorizedSource = "authorized_source"
    case untrustedExternalContent = "untrusted_external_content"
    case generatedReference = "generated_reference"
}

enum LokiChatRetentionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case thirtyDays = "thirty_days"
    case ninetyDays = "ninety_days"
    case oneYear = "one_year"
    case unlimited
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .oneYear: "One year"
        case .unlimited: "Unlimited"
        case .custom: "Custom"
        }
    }

    func retentionDays(customDays: Int?) -> Int? {
        switch self {
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        case .unlimited: nil
        case .custom:
            min(
                max(customDays ?? 90, LokiChatLimits.minimumCustomRetentionDays),
                LokiChatLimits.maximumCustomRetentionDays
            )
        }
    }
}

enum LokiConversationFailureCode: String, Codable, CaseIterable, Sendable {
    case historyStorageDisabled = "chat_history_storage_disabled"
    case invalidRequest = "chat_invalid_request"
    case compatibleModelRequired = "chat_compatible_model_required"
    case providerUnavailable = "chat_provider_unavailable"
    case providerTimeout = "chat_provider_timeout"
    case invalidStructuredResponse = "chat_invalid_structured_response"
    case toolRejected = "chat_tool_rejected"
    case toolFailed = "chat_tool_failed"
    case contextUnavailable = "chat_context_unavailable"
    case contextBudgetExceeded = "chat_context_budget_exceeded"
    case sourceEvidenceNotAllowed = "chat_source_evidence_not_allowed"
    case requestCanceled = "chat_request_canceled"
    case generationInterrupted = "chat_generation_interrupted_by_relaunch"
    case sourceEvidenceDeleted = "chat_source_evidence_deleted"
    case persistenceFailed = "chat_persistence_failed"
    case updateInProgress = "chat_update_in_progress"
    case unknown = "chat_unknown_failure"
}

struct LokiConversationFailure: Error, Codable, Hashable, Sendable {
    let code: LokiConversationFailureCode
    let isRecoverable: Bool
    let consumerMessage: String

    init(code: LokiConversationFailureCode, isRecoverable: Bool, consumerMessage: String) {
        self.code = code
        self.isRecoverable = isRecoverable
        self.consumerMessage = String(
            consumerMessage.prefix(LokiChatLimits.maximumFailureMessageCharacters)
        )
    }
}

extension LokiConversationFailure: LocalizedError {
    var errorDescription: String? { consumerMessage }
}

struct LokiChatContext: Codable, Hashable, Sendable {
    let scope: LokiChatContextScope
    let targetIdentifier: String?
    let selectedAt: Date

    init(
        scope: LokiChatContextScope,
        targetIdentifier: String? = nil,
        selectedAt: Date = .now
    ) {
        self.scope = scope
        self.targetIdentifier = targetIdentifier.map {
            String($0.prefix(LokiChatLimits.maximumContextIdentifierCharacters))
        }
        self.selectedAt = selectedAt
    }
}

struct LokiChatContextSelectionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let requestMessageID: String
    let context: LokiChatContext
    let tokenEstimate: Int
    let wasTruncated: Bool

    init(
        id: String,
        conversationID: String,
        requestMessageID: String,
        context: LokiChatContext,
        tokenEstimate: Int,
        wasTruncated: Bool
    ) {
        self.id = String(id.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        self.conversationID = String(
            conversationID.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.requestMessageID = String(
            requestMessageID.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.context = context
        self.tokenEstimate = max(0, tokenEstimate)
        self.wasTruncated = wasTruncated
    }
}

struct LokiChatAnswerSegment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let classification: LokiChatAnswerClassification
    let text: String
    let evidenceReferenceIDs: [String]

    init(
        id: String = UUID().uuidString.lowercased(),
        classification: LokiChatAnswerClassification,
        text: String,
        evidenceReferenceIDs: [String] = []
    ) {
        self.id = id
        self.classification = classification
        self.text = String(text.prefix(LokiChatLimits.maximumMessageCharacters))
        self.evidenceReferenceIDs = evidenceReferenceIDs.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        }
    }
}

struct LokiEvidenceReference: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceKind: LokiEvidenceSourceKind
    let accountClassification: String?
    let accountIdentifier: String?
    let containerClassification: String?
    let containerIdentifier: String?
    let itemIdentifier: String
    let sourceTimestamp: Date?
    let retrievedAt: Date
    let localVaultIdentifier: String?
    let displayLabel: String
    let boundedExcerpt: String?
    let directSourceURL: URL?
    let trustClassification: LokiEvidenceTrustClassification

    init(
        id: String,
        sourceKind: LokiEvidenceSourceKind,
        accountClassification: String? = nil,
        accountIdentifier: String? = nil,
        containerClassification: String? = nil,
        containerIdentifier: String? = nil,
        itemIdentifier: String,
        sourceTimestamp: Date? = nil,
        retrievedAt: Date,
        localVaultIdentifier: String? = nil,
        displayLabel: String,
        boundedExcerpt: String? = nil,
        directSourceURL: URL? = nil,
        trustClassification: LokiEvidenceTrustClassification
    ) {
        self.id = String(id.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        self.sourceKind = sourceKind
        self.accountClassification = accountClassification.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceLabelCharacters))
        }
        self.accountIdentifier = accountIdentifier.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        }
        self.containerClassification = containerClassification.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceLabelCharacters))
        }
        self.containerIdentifier = containerIdentifier.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        }
        self.itemIdentifier = String(
            itemIdentifier.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.sourceTimestamp = sourceTimestamp
        self.retrievedAt = retrievedAt
        self.localVaultIdentifier = localVaultIdentifier.map {
            String($0.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        }
        self.displayLabel = String(
            displayLabel.prefix(LokiChatLimits.maximumEvidenceLabelCharacters)
        )
        self.boundedExcerpt = boundedExcerpt.map {
            String($0.prefix(LokiChatLimits.maximumStoredEvidenceExcerptCharacters))
        }
        self.directSourceURL = Self.safeDirectSourceURL(directSourceURL)
        self.trustClassification = trustClassification
    }

    private static func safeDirectSourceURL(_ url: URL?) -> URL? {
        guard let url,
              url.absoluteString.count <= LokiChatLimits.maximumDirectSourceURLCharacters,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            return nil
        }
        components.fragment = nil
        return components.url
    }
}

struct LokiGenerationProvenance: Codable, Hashable, Sendable {
    let provider: String
    let modelIdentifier: String
    let assessmentVersion: String
    let promptTemplateVersion: String
    let toolSchemaVersion: String
    let startedAt: Date
    let completedAt: Date?
    let durationMilliseconds: Int?
    let promptTokenEstimate: Int?
    let completionTokenCount: Int?
    let evidenceCount: Int
    let status: String
    let reasonCode: String

    init(
        provider: String,
        modelIdentifier: String,
        assessmentVersion: String,
        promptTemplateVersion: String,
        toolSchemaVersion: String,
        startedAt: Date,
        completedAt: Date?,
        durationMilliseconds: Int?,
        promptTokenEstimate: Int?,
        completionTokenCount: Int?,
        evidenceCount: Int,
        status: String,
        reasonCode: String
    ) {
        self.provider = String(provider.prefix(LokiChatLimits.maximumMetadataCharacters))
        self.modelIdentifier = String(
            modelIdentifier.prefix(LokiChatLimits.maximumMetadataCharacters)
        )
        self.assessmentVersion = String(
            assessmentVersion.prefix(LokiChatLimits.maximumMetadataCharacters)
        )
        self.promptTemplateVersion = String(
            promptTemplateVersion.prefix(LokiChatLimits.maximumMetadataCharacters)
        )
        self.toolSchemaVersion = String(
            toolSchemaVersion.prefix(LokiChatLimits.maximumMetadataCharacters)
        )
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.promptTokenEstimate = promptTokenEstimate.map { max(0, $0) }
        self.completionTokenCount = completionTokenCount.map { max(0, $0) }
        self.evidenceCount = max(0, evidenceCount)
        self.status = String(status.prefix(LokiChatLimits.maximumMetadataCharacters))
        self.reasonCode = String(reasonCode.prefix(LokiChatLimits.maximumMetadataCharacters))
    }
}

struct LokiChatToolReceipt: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let requestIdentifier: String
    let toolName: String
    let status: String
    let reasonCode: String
    let requestedAt: Date
    let completedAt: Date?
    let durationMilliseconds: Int?
    let resultCount: Int
    let evidenceReferenceIDs: [String]
    let argumentKeys: [String]

    init(
        id: String,
        requestIdentifier: String,
        toolName: String,
        status: String,
        reasonCode: String,
        requestedAt: Date,
        completedAt: Date?,
        durationMilliseconds: Int?,
        resultCount: Int,
        evidenceReferenceIDs: [String],
        argumentKeys: [String]
    ) {
        self.id = String(id.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        self.requestIdentifier = String(
            requestIdentifier.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.toolName = String(toolName.prefix(LokiChatLimits.maximumMetadataCharacters))
        self.status = String(status.prefix(LokiChatLimits.maximumMetadataCharacters))
        self.reasonCode = String(reasonCode.prefix(LokiChatLimits.maximumMetadataCharacters))
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.resultCount = max(0, resultCount)
        self.evidenceReferenceIDs = Array(
            evidenceReferenceIDs
                .prefix(LokiChatLimits.maximumEvidenceReferencesPerMessage)
                .map {
                    String($0.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
                }
        )
        self.argumentKeys = Array(
            argumentKeys
                .prefix(LokiChatLimits.maximumToolArgumentKeys)
                .map {
                    String($0.prefix(LokiChatLimits.maximumMetadataCharacters))
                }
        )
    }
}

struct LokiMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let sequence: Int
    let role: LokiMessageRole
    var state: LokiMessageState
    var visibleText: String
    var answerSegments: [LokiChatAnswerSegment]
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var failure: LokiConversationFailure?
    let retryOfMessageID: String?
    var isPartial: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        conversationID: String,
        sequence: Int,
        role: LokiMessageRole,
        state: LokiMessageState,
        visibleText: String,
        answerSegments: [LokiChatAnswerSegment] = [],
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        failure: LokiConversationFailure? = nil,
        retryOfMessageID: String? = nil,
        isPartial: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.role = role
        self.state = state
        self.visibleText = String(visibleText.prefix(LokiChatLimits.maximumMessageCharacters))
        self.answerSegments = Array(
            answerSegments.prefix(LokiChatLimits.maximumAnswerSegmentsPerMessage)
        )
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.failure = failure
        self.retryOfMessageID = retryOfMessageID
        self.isPartial = isPartial
    }
}

struct LokiConversation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var context: LokiChatContext
    var messages: [LokiMessage]

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        context: LokiChatContext,
        messages: [LokiMessage] = []
    ) {
        self.id = id
        self.title = String(title.prefix(LokiChatLimits.maximumConversationTitleCharacters))
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.context = context
        self.messages = messages
    }
}

struct LokiConversationSummary: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let messageCount: Int
    let contextScope: LokiChatContextScope
}

struct LokiChatRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let userMessageID: String
    let prompt: String
    let context: LokiChatContext
    let requestedAt: Date

    init(
        id: String,
        conversationID: String,
        userMessageID: String,
        prompt: String,
        context: LokiChatContext,
        requestedAt: Date
    ) {
        self.id = String(id.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        self.conversationID = String(
            conversationID.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.userMessageID = String(
            userMessageID.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters)
        )
        self.prompt = String(prompt.prefix(LokiChatLimits.maximumMessageCharacters))
        self.context = context
        self.requestedAt = requestedAt
    }
}

struct LokiChatResponse: Codable, Hashable, Sendable {
    let message: LokiMessage
    let evidence: [LokiEvidenceReference]
    let toolReceipts: [LokiChatToolReceipt]
    let provenance: LokiGenerationProvenance?

    init(
        message: LokiMessage,
        evidence: [LokiEvidenceReference],
        toolReceipts: [LokiChatToolReceipt],
        provenance: LokiGenerationProvenance?
    ) {
        self.message = message
        self.evidence = Array(
            evidence.prefix(LokiChatLimits.maximumEvidenceReferencesPerMessage)
        )
        self.toolReceipts = Array(
            toolReceipts.prefix(LokiChatLimits.maximumToolReceiptsPerMessage)
        )
        self.provenance = provenance
    }
}

struct LokiChatPrivacySettings: Codable, Hashable, Sendable {
    var storeLocalHistory: Bool
    var retentionPolicy: LokiChatRetentionPolicy
    var customRetentionDays: Int?
    var includeSourceExcerpts: Bool
    var allowFeedEvidence: Bool

    static let defaults = Self(
        storeLocalHistory: true,
        retentionPolicy: .ninetyDays,
        customRetentionDays: nil,
        includeSourceExcerpts: false,
        allowFeedEvidence: true
    )

    var effectiveRetentionDays: Int? {
        retentionPolicy.retentionDays(customDays: customRetentionDays)
    }

    func normalized() -> Self {
        var copy = self
        if retentionPolicy == .custom {
            copy.customRetentionDays = min(
                max(customRetentionDays ?? 90, LokiChatLimits.minimumCustomRetentionDays),
                LokiChatLimits.maximumCustomRetentionDays
            )
        } else {
            copy.customRetentionDays = nil
        }
        return copy
    }
}

struct LokiChatWorkspaceEvidencePolicy: Codable, Hashable, Sendable {
    let workspaceIdentifier: String
    var allowSelectedSlackEvidence: Bool
    var updatedAt: Date

    static func defaultPolicy(workspaceIdentifier: String, at date: Date = .now) -> Self {
        .init(
            workspaceIdentifier: workspaceIdentifier,
            allowSelectedSlackEvidence: false,
            updatedAt: date
        )
    }
}

struct LokiModelAssessmentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let readiness: ModelReadiness
    let assessment: ModelCapabilityAssessment

    init(
        id: String,
        readiness: ModelReadiness,
        assessment: ModelCapabilityAssessment
    ) {
        self.id = String(id.prefix(LokiChatLimits.maximumEvidenceIdentifierCharacters))
        self.readiness = readiness
        self.assessment = assessment
    }

    var provider: String { assessment.provider }
    var providerVersion: String? { assessment.providerVersion }
    var modelIdentifier: String { assessment.modelIdentifier }
    var modelDigest: String? { assessment.modelDigest }
    var assessmentVersion: String { assessment.assessmentVersion }
    var provenCapabilities: [String] {
        assessment.capabilitiesProven.map(\.rawValue).sorted()
    }
    var missingCapabilities: [String] {
        assessment.capabilitiesMissing.map(\.rawValue).sorted()
    }
    var contextWindowClassification: String {
        assessment.contextPolicy.classification.rawValue
    }
    var assessedAt: Date { assessment.assessedAt }
    var durationMilliseconds: Int { assessment.durationMilliseconds }
    var diagnosticReasonCodes: [String] {
        assessment.diagnostics.map(\.reasonCode).sorted()
    }
}
