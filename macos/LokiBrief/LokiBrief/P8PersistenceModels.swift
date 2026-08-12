import Foundation
import SwiftData

struct OllamaWebResearchGlobalSettings: Codable, Hashable, Sendable {
    var providerEnabled: Bool
    var externalNetworkDisclosureAccepted: Bool
    var updatedAt: Date

    static func defaults(at date: Date = .now) -> Self {
        .init(
            providerEnabled: false,
            externalNetworkDisclosureAccepted: false,
            updatedAt: date
        )
    }
}

struct OllamaWebResearchConversationPolicy: Codable, Hashable, Sendable {
    let conversationIdentifier: String
    var webResearchEnabled: Bool
    var updatedAt: Date

    static func defaults(
        conversationIdentifier: String,
        at date: Date = .now
    ) -> Self {
        .init(
            conversationIdentifier: conversationIdentifier,
            webResearchEnabled: false,
            updatedAt: date
        )
    }
}

@Model final class StoredModelRoleAssignment {
    @Attribute(.unique) var id: String
    var roleRaw: String
    var requestedProvider: String?
    var requestedModelIdentifier: String?
    var effectiveProvider: String?
    var effectiveModelIdentifier: String?
    var requestedClassificationRaw: String
    var effectiveClassificationRaw: String
    var modelDigest: String?
    var assessmentReceiptIdentifier: String?
    var assessmentTimestamp: Date?
    var verifiedInputModalitiesData: Data
    var verifiedThinkingModesData: Data
    var verifiedToolSupportRaw: String
    var verifiedStructuredOutputSupport: Bool
    var verifiedStreamingSupport: Bool
    var configuredContextTokens: Int?
    var effectiveContextTokens: Int?
    var readinessRaw: String
    var reasonCode: String
    var sourceRaw: String
    var inheritedFromRoleRaw: String?
    var dispositionsData: Data
    var isExplicitlyAssigned: Bool
    var selectedAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: String,
        roleRaw: String,
        requestedProvider: String?,
        requestedModelIdentifier: String?,
        effectiveProvider: String?,
        effectiveModelIdentifier: String?,
        requestedClassificationRaw: String,
        effectiveClassificationRaw: String,
        modelDigest: String?,
        assessmentReceiptIdentifier: String?,
        assessmentTimestamp: Date?,
        verifiedInputModalitiesData: Data,
        verifiedThinkingModesData: Data,
        verifiedToolSupportRaw: String,
        verifiedStructuredOutputSupport: Bool,
        verifiedStreamingSupport: Bool,
        configuredContextTokens: Int?,
        effectiveContextTokens: Int?,
        readinessRaw: String,
        reasonCode: String,
        sourceRaw: String,
        inheritedFromRoleRaw: String?,
        dispositionsData: Data,
        isExplicitlyAssigned: Bool,
        selectedAt: Date,
        updatedAt: Date,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.requestedProvider = requestedProvider
        self.requestedModelIdentifier = requestedModelIdentifier
        self.effectiveProvider = effectiveProvider
        self.effectiveModelIdentifier = effectiveModelIdentifier
        self.requestedClassificationRaw = requestedClassificationRaw
        self.effectiveClassificationRaw = effectiveClassificationRaw
        self.modelDigest = modelDigest
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier
        self.assessmentTimestamp = assessmentTimestamp
        self.verifiedInputModalitiesData = verifiedInputModalitiesData
        self.verifiedThinkingModesData = verifiedThinkingModesData
        self.verifiedToolSupportRaw = verifiedToolSupportRaw
        self.verifiedStructuredOutputSupport = verifiedStructuredOutputSupport
        self.verifiedStreamingSupport = verifiedStreamingSupport
        self.configuredContextTokens = configuredContextTokens
        self.effectiveContextTokens = effectiveContextTokens
        self.readinessRaw = readinessRaw
        self.reasonCode = reasonCode
        self.sourceRaw = sourceRaw
        self.inheritedFromRoleRaw = inheritedFromRoleRaw
        self.dispositionsData = dispositionsData
        self.isExplicitlyAssigned = isExplicitlyAssigned
        self.selectedAt = selectedAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredModelRoutingReceipt {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var event: String
    var traceID: String
    var spanID: String
    var parentSpanID: String?
    var component: String
    var statusRaw: String
    var reasonCode: String
    var durationMilliseconds: Int
    var requestedRoleRaw: String
    var selectedRoleRaw: String?
    var requestedModelIdentifier: String?
    var effectiveModelIdentifier: String?
    var requestedModelClassificationRaw: String
    var effectiveModelClassificationRaw: String
    var assessmentReceiptIdentifier: String?
    var switchStatusRaw: String
    var effectiveContextTokens: Int?
    var attachmentsPresent: Bool
    var schemaVersion: Int

    init(
        id: String,
        timestamp: Date,
        event: String,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        component: String,
        statusRaw: String,
        reasonCode: String,
        durationMilliseconds: Int,
        requestedRoleRaw: String,
        selectedRoleRaw: String?,
        requestedModelIdentifier: String?,
        effectiveModelIdentifier: String?,
        requestedModelClassificationRaw: String,
        effectiveModelClassificationRaw: String,
        assessmentReceiptIdentifier: String?,
        switchStatusRaw: String,
        effectiveContextTokens: Int?,
        attachmentsPresent: Bool,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.component = component
        self.statusRaw = statusRaw
        self.reasonCode = reasonCode
        self.durationMilliseconds = durationMilliseconds
        self.requestedRoleRaw = requestedRoleRaw
        self.selectedRoleRaw = selectedRoleRaw
        self.requestedModelIdentifier = requestedModelIdentifier
        self.effectiveModelIdentifier = effectiveModelIdentifier
        self.requestedModelClassificationRaw = requestedModelClassificationRaw
        self.effectiveModelClassificationRaw = effectiveModelClassificationRaw
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier
        self.switchStatusRaw = switchStatusRaw
        self.effectiveContextTokens = effectiveContextTokens
        self.attachmentsPresent = attachmentsPresent
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredModelReasoningReceipt {
    @Attribute(.unique) var id: String
    var traceID: String
    var reasoningModeRaw: String
    var modelIdentifier: String
    var assessmentReceiptIdentifier: String
    var startedAt: Date
    var durationMilliseconds: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var toolLoopCount: Int
    var statusRaw: String
    var reasonCode: String
    var schemaVersion: Int

    init(
        id: String,
        traceID: String,
        reasoningModeRaw: String,
        modelIdentifier: String,
        assessmentReceiptIdentifier: String,
        startedAt: Date,
        durationMilliseconds: Int,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        toolLoopCount: Int,
        statusRaw: String,
        reasonCode: String,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.traceID = traceID
        self.reasoningModeRaw = reasoningModeRaw
        self.modelIdentifier = modelIdentifier
        self.assessmentReceiptIdentifier = assessmentReceiptIdentifier
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.toolLoopCount = toolLoopCount
        self.statusRaw = statusRaw
        self.reasonCode = reasonCode
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredP8ModelRoleMigrationState {
    @Attribute(.unique) var id: String
    var completedAt: Date
    var sourceSchemaVersion: Int
    var reasonCode: String
    var reportData: Data
    var schemaVersion: Int

    init(
        id: String = "v8-to-v9-model-roles",
        completedAt: Date,
        sourceSchemaVersion: Int = 8,
        reasonCode: String,
        reportData: Data,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.completedAt = completedAt
        self.sourceSchemaVersion = sourceSchemaVersion
        self.reasonCode = reasonCode
        self.reportData = reportData
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredOllamaWebResearchSettings {
    @Attribute(.unique) var id: String
    var providerEnabled: Bool
    var externalNetworkDisclosureAccepted: Bool
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: String = "primary",
        providerEnabled: Bool = false,
        externalNetworkDisclosureAccepted: Bool = false,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.providerEnabled = providerEnabled
        self.externalNetworkDisclosureAccepted = externalNetworkDisclosureAccepted
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

@Model final class StoredOllamaWebResearchConversationPolicy {
    @Attribute(.unique) var id: String
    var conversationIdentifier: String
    var webResearchEnabled: Bool
    var updatedAt: Date
    var schemaVersion: Int

    init(
        conversationIdentifier: String,
        webResearchEnabled: Bool = false,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = conversationIdentifier
        self.conversationIdentifier = conversationIdentifier
        self.webResearchEnabled = webResearchEnabled
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

enum LokiBriefSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV8.models + [
            StoredModelRoleAssignment.self,
            StoredModelRoutingReceipt.self,
            StoredModelReasoningReceipt.self,
            StoredP8ModelRoleMigrationState.self,
            StoredOllamaWebResearchSettings.self,
            StoredOllamaWebResearchConversationPolicy.self,
        ]
    }
}

enum LokiBriefMigrationPlanV9: SchemaMigrationPlan {
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
            LokiBriefSchemaV9.self,
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
            .lightweight(fromVersion: LokiBriefSchemaV8.self, toVersion: LokiBriefSchemaV9.self),
        ]
    }
}
