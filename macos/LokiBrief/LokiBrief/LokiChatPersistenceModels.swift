import Foundation
import SwiftData

@Model final class StoredLokiChatSettings {
    @Attribute(.unique) var id: String
    var storeLocalHistory: Bool
    var retentionPolicyRaw: String
    var customRetentionDays: Int?
    var includeSourceExcerpts: Bool
    var allowFeedEvidence: Bool
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: String = "primary",
        storeLocalHistory: Bool = true,
        retentionPolicyRaw: String = LokiChatRetentionPolicy.ninetyDays.rawValue,
        customRetentionDays: Int? = nil,
        includeSourceExcerpts: Bool = false,
        allowFeedEvidence: Bool = true,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.storeLocalHistory = storeLocalHistory
        self.retentionPolicyRaw = retentionPolicyRaw
        self.customRetentionDays = customRetentionDays
        self.includeSourceExcerpts = includeSourceExcerpts
        self.allowFeedEvidence = allowFeedEvidence
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiChatWorkspacePolicy {
    @Attribute(.unique) var id: String
    var workspaceIdentifier: String
    var allowSelectedSlackEvidence: Bool
    var updatedAt: Date
    var schemaVersion: Int

    init(
        workspaceIdentifier: String,
        allowSelectedSlackEvidence: Bool = false,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = workspaceIdentifier
        self.workspaceIdentifier = workspaceIdentifier
        self.allowSelectedSlackEvidence = allowSelectedSlackEvidence
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiConversation {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var contextScopeRaw: String
    var contextTargetIdentifier: String?
    var contextSelectedAt: Date
    var messageCount: Int
    var schemaVersion: Int

    init(
        id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        contextScopeRaw: String,
        contextTargetIdentifier: String?,
        contextSelectedAt: Date,
        messageCount: Int = 0,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contextScopeRaw = contextScopeRaw
        self.contextTargetIdentifier = contextTargetIdentifier
        self.contextSelectedAt = contextSelectedAt
        self.messageCount = messageCount
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiMessage {
    @Attribute(.unique) var id: String
    var conversationID: String
    var sequence: Int
    var roleRaw: String
    var stateRaw: String
    var visibleText: String
    var answerSegmentsData: Data
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var failureCodeRaw: String?
    var failureRecoverable: Bool
    var failureMessage: String?
    var retryOfMessageID: String?
    var isPartial: Bool
    var schemaVersion: Int

    init(
        id: String,
        conversationID: String,
        sequence: Int,
        roleRaw: String,
        stateRaw: String,
        visibleText: String,
        answerSegmentsData: Data = Data("[]".utf8),
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        failureCodeRaw: String? = nil,
        failureRecoverable: Bool = false,
        failureMessage: String? = nil,
        retryOfMessageID: String? = nil,
        isPartial: Bool = false,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.roleRaw = roleRaw
        self.stateRaw = stateRaw
        self.visibleText = visibleText
        self.answerSegmentsData = answerSegmentsData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.failureCodeRaw = failureCodeRaw
        self.failureRecoverable = failureRecoverable
        self.failureMessage = failureMessage
        self.retryOfMessageID = retryOfMessageID
        self.isPartial = isPartial
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiChatContextSelection {
    @Attribute(.unique) var id: String
    var conversationID: String
    var requestMessageID: String
    var scopeRaw: String
    var targetIdentifier: String?
    var selectedAt: Date
    var tokenEstimate: Int
    var wasTruncated: Bool
    var schemaVersion: Int

    init(
        id: String,
        conversationID: String,
        requestMessageID: String,
        scopeRaw: String,
        targetIdentifier: String?,
        selectedAt: Date,
        tokenEstimate: Int,
        wasTruncated: Bool,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.conversationID = conversationID
        self.requestMessageID = requestMessageID
        self.scopeRaw = scopeRaw
        self.targetIdentifier = targetIdentifier
        self.selectedAt = selectedAt
        self.tokenEstimate = tokenEstimate
        self.wasTruncated = wasTruncated
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiEvidenceReference {
    @Attribute(.unique) var id: String
    var referenceIdentifier: String
    var conversationID: String
    var messageID: String
    var sourceKindRaw: String
    var accountClassification: String?
    var accountIdentifier: String?
    var containerClassification: String?
    var containerIdentifier: String?
    var itemIdentifier: String
    var sourceTimestamp: Date?
    var retrievedAt: Date
    var localVaultIdentifier: String?
    var displayLabel: String
    var boundedExcerpt: String?
    var directSourceURLString: String?
    var trustClassificationRaw: String
    var schemaVersion: Int

    init(
        id: String,
        referenceIdentifier: String,
        conversationID: String,
        messageID: String,
        sourceKindRaw: String,
        accountClassification: String?,
        accountIdentifier: String?,
        containerClassification: String?,
        containerIdentifier: String?,
        itemIdentifier: String,
        sourceTimestamp: Date?,
        retrievedAt: Date,
        localVaultIdentifier: String?,
        displayLabel: String,
        boundedExcerpt: String?,
        directSourceURLString: String?,
        trustClassificationRaw: String,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.referenceIdentifier = referenceIdentifier
        self.conversationID = conversationID
        self.messageID = messageID
        self.sourceKindRaw = sourceKindRaw
        self.accountClassification = accountClassification
        self.accountIdentifier = accountIdentifier
        self.containerClassification = containerClassification
        self.containerIdentifier = containerIdentifier
        self.itemIdentifier = itemIdentifier
        self.sourceTimestamp = sourceTimestamp
        self.retrievedAt = retrievedAt
        self.localVaultIdentifier = localVaultIdentifier
        self.displayLabel = displayLabel
        self.boundedExcerpt = boundedExcerpt
        self.directSourceURLString = directSourceURLString
        self.trustClassificationRaw = trustClassificationRaw
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiToolReceipt {
    @Attribute(.unique) var id: String
    var conversationID: String
    var messageID: String
    var requestIdentifier: String
    var toolName: String
    var status: String
    var reasonCode: String
    var requestedAt: Date
    var completedAt: Date?
    var durationMilliseconds: Int?
    var resultCount: Int
    var evidenceReferenceIDsData: Data
    var argumentKeysData: Data
    var schemaVersion: Int

    init(
        id: String,
        conversationID: String,
        messageID: String,
        requestIdentifier: String,
        toolName: String,
        status: String,
        reasonCode: String,
        requestedAt: Date,
        completedAt: Date?,
        durationMilliseconds: Int?,
        resultCount: Int,
        evidenceReferenceIDsData: Data,
        argumentKeysData: Data,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.requestIdentifier = requestIdentifier
        self.toolName = toolName
        self.status = status
        self.reasonCode = reasonCode
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.resultCount = resultCount
        self.evidenceReferenceIDsData = evidenceReferenceIDsData
        self.argumentKeysData = argumentKeysData
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiGenerationProvenance {
    @Attribute(.unique) var messageID: String
    var conversationID: String
    var provider: String
    var modelIdentifier: String
    var assessmentVersion: String
    var promptTemplateVersion: String
    var toolSchemaVersion: String
    var startedAt: Date
    var completedAt: Date?
    var durationMilliseconds: Int?
    var promptTokenEstimate: Int?
    var completionTokenCount: Int?
    var evidenceCount: Int
    var status: String
    var reasonCode: String
    var schemaVersion: Int

    init(
        messageID: String,
        conversationID: String,
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
        reasonCode: String,
        schemaVersion: Int = 1
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.assessmentVersion = assessmentVersion
        self.promptTemplateVersion = promptTemplateVersion
        self.toolSchemaVersion = toolSchemaVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.promptTokenEstimate = promptTokenEstimate
        self.completionTokenCount = completionTokenCount
        self.evidenceCount = evidenceCount
        self.status = status
        self.reasonCode = reasonCode
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiModelAssessment {
    @Attribute(.unique) var id: String
    var provider: String
    var providerVersion: String?
    var modelIdentifier: String
    var modelDigest: String?
    var assessmentVersion: String
    var readinessRaw: String
    var provenCapabilitiesData: Data
    var missingCapabilitiesData: Data
    var contextWindowClassificationRaw: String
    var assessedAt: Date
    var durationMilliseconds: Int
    var diagnosticReasonCodesData: Data
    var capabilityAssessmentData: Data
    var schemaVersion: Int

    init(
        id: String,
        provider: String,
        providerVersion: String?,
        modelIdentifier: String,
        modelDigest: String?,
        assessmentVersion: String,
        readinessRaw: String,
        provenCapabilitiesData: Data,
        missingCapabilitiesData: Data,
        contextWindowClassificationRaw: String,
        assessedAt: Date,
        durationMilliseconds: Int,
        diagnosticReasonCodesData: Data,
        capabilityAssessmentData: Data,
        schemaVersion: Int = 2
    ) {
        self.id = id
        self.provider = provider
        self.providerVersion = providerVersion
        self.modelIdentifier = modelIdentifier
        self.modelDigest = modelDigest
        self.assessmentVersion = assessmentVersion
        self.readinessRaw = readinessRaw
        self.provenCapabilitiesData = provenCapabilitiesData
        self.missingCapabilitiesData = missingCapabilitiesData
        self.contextWindowClassificationRaw = contextWindowClassificationRaw
        self.assessedAt = assessedAt
        self.durationMilliseconds = durationMilliseconds
        self.diagnosticReasonCodesData = diagnosticReasonCodesData
        self.capabilityAssessmentData = capabilityAssessmentData
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredLokiChatModelSelection {
    @Attribute(.unique) var id: String
    var provider: String
    var modelIdentifier: String
    var modelDigest: String?
    var assessmentVersion: String
    var selectedAt: Date
    var schemaVersion: Int

    init(
        id: String = "primary",
        provider: String,
        modelIdentifier: String,
        modelDigest: String?,
        assessmentVersion: String,
        selectedAt: Date,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.modelDigest = modelDigest
        self.assessmentVersion = assessmentVersion
        self.selectedAt = selectedAt
        self.schemaVersion = schemaVersion
    }
}

enum LokiBriefSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV7.models + [
            StoredLokiChatSettings.self,
            StoredLokiChatWorkspacePolicy.self,
            StoredLokiConversation.self,
            StoredLokiMessage.self,
            StoredLokiChatContextSelection.self,
            StoredLokiEvidenceReference.self,
            StoredLokiToolReceipt.self,
            StoredLokiGenerationProvenance.self,
            StoredLokiModelAssessment.self,
            StoredLokiChatModelSelection.self,
        ]
    }
}

enum LokiBriefMigrationPlanV8: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            LokiBriefSchemaV1.self,
            LokiBriefSchemaV2.self,
            LokiBriefSchemaV3PreEditedAt.self,
            LokiBriefSchemaV3.self,
            LokiBriefSchemaV4.self,
            LokiBriefSchemaV5.self,
            LokiBriefSchemaV6.self,
            LokiBriefSchemaV7.self,
            LokiBriefSchemaV8.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LokiBriefSchemaV1.self, toVersion: LokiBriefSchemaV2.self),
            .lightweight(fromVersion: LokiBriefSchemaV2.self, toVersion: LokiBriefSchemaV3PreEditedAt.self),
            .lightweight(fromVersion: LokiBriefSchemaV3PreEditedAt.self, toVersion: LokiBriefSchemaV3.self),
            .lightweight(fromVersion: LokiBriefSchemaV3.self, toVersion: LokiBriefSchemaV4.self),
            .lightweight(fromVersion: LokiBriefSchemaV4.self, toVersion: LokiBriefSchemaV5.self),
            .lightweight(fromVersion: LokiBriefSchemaV5.self, toVersion: LokiBriefSchemaV6.self),
            .lightweight(fromVersion: LokiBriefSchemaV6.self, toVersion: LokiBriefSchemaV7.self),
            .lightweight(fromVersion: LokiBriefSchemaV7.self, toVersion: LokiBriefSchemaV8.self),
        ]
    }
}
