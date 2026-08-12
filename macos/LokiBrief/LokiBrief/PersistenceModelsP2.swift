import Foundation
import SwiftData

@Model final class StoredFeedSubscription {
    @Attribute(.unique) var id: String
    var displayName: String
    var canonicalURL: String
    var enabled: Bool
    var formatRaw: String
    var lastAttemptedAt: Date?
    var lastSuccessfulAt: Date?
    var lastHTTPStatus: Int?
    var eTag: String?
    var lastModified: String?
    var stateRaw: String
    var failureCode: String?
    var failureMessage: String?
    var retentionCount: Int
    var weight: Double
    var createdAt: Date
    var updatedAt: Date

    init(id: String, displayName: String, canonicalURL: String, enabled: Bool = true, formatRaw: String = "unknown", lastAttemptedAt: Date? = nil, lastSuccessfulAt: Date? = nil, lastHTTPStatus: Int? = nil, eTag: String? = nil, lastModified: String? = nil, stateRaw: String = "savedUnavailable", failureCode: String? = nil, failureMessage: String? = nil, retentionCount: Int = 200, weight: Double = 1, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.canonicalURL = canonicalURL
        self.enabled = enabled
        self.formatRaw = formatRaw
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.lastHTTPStatus = lastHTTPStatus
        self.eTag = eTag
        self.lastModified = lastModified
        self.stateRaw = stateRaw
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.retentionCount = retentionCount
        self.weight = weight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StoredFeedFetch {
    @Attribute(.unique) var id: String
    var subscriptionID: String
    var traceID: String
    var attemptedAt: Date
    var completedAt: Date?
    var statusRaw: String
    var httpStatus: Int?
    var responseByteCount: Int
    var parsedEntryCount: Int
    var failureCode: String?
    var failureMessage: String?
    var eTag: String?
    var lastModified: String?

    init(id: String, subscriptionID: String, traceID: String, attemptedAt: Date, completedAt: Date? = nil, statusRaw: String, httpStatus: Int? = nil, responseByteCount: Int = 0, parsedEntryCount: Int = 0, failureCode: String? = nil, failureMessage: String? = nil, eTag: String? = nil, lastModified: String? = nil) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.traceID = traceID
        self.attemptedAt = attemptedAt
        self.completedAt = completedAt
        self.statusRaw = statusRaw
        self.httpStatus = httpStatus
        self.responseByteCount = responseByteCount
        self.parsedEntryCount = parsedEntryCount
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.eTag = eTag
        self.lastModified = lastModified
    }
}

@Model final class StoredNormalizedFeedEntry {
    @Attribute(.unique) var id: String
    var subscriptionID: String
    var title: String
    var summaryText: String
    var canonicalURL: String?
    var author: String?
    var publicationDate: Date?
    var updatedDate: Date?
    var retrievedAt: Date
    var originalPosition: Int
    var formatIdentifier: String?
    var upstreamIdentifier: String?
    var identityBasis: String
    var encodedEntry: Data

    init(id: String, subscriptionID: String, title: String, summaryText: String, canonicalURL: String?, author: String?, publicationDate: Date?, updatedDate: Date?, retrievedAt: Date, originalPosition: Int, formatIdentifier: String?, upstreamIdentifier: String?, identityBasis: String, encodedEntry: Data) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.title = title
        self.summaryText = summaryText
        self.canonicalURL = canonicalURL
        self.author = author
        self.publicationDate = publicationDate
        self.updatedDate = updatedDate
        self.retrievedAt = retrievedAt
        self.originalPosition = originalPosition
        self.formatIdentifier = formatIdentifier
        self.upstreamIdentifier = upstreamIdentifier
        self.identityBasis = identityBasis
        self.encodedEntry = encodedEntry
    }
}

@Model final class StoredBriefAssembly {
    @Attribute(.unique) var id: String
    var generatedAt: Date
    var selectedEntryCount: Int
    var excludedEntryCount: Int
    var enabledSourceCount: Int
    var failureNotes: Data

    init(id: String, generatedAt: Date, selectedEntryCount: Int, excludedEntryCount: Int, enabledSourceCount: Int, failureNotes: Data) {
        self.id = id
        self.generatedAt = generatedAt
        self.selectedEntryCount = selectedEntryCount
        self.excludedEntryCount = excludedEntryCount
        self.enabledSourceCount = enabledSourceCount
        self.failureNotes = failureNotes
    }
}

@Model final class StoredModelProviderSnapshotP2 {
    @Attribute(.unique) var id: String
    var stateRaw: String
    var checkedAt: Date
    var lastSuccessfulCheckAt: Date?
    var serviceVersion: String?
    var failureCode: String?
    var failureMessage: String?

    init(id: String = "ollama", stateRaw: String, checkedAt: Date, lastSuccessfulCheckAt: Date? = nil, serviceVersion: String? = nil, failureCode: String? = nil, failureMessage: String? = nil) {
        self.id = id
        self.stateRaw = stateRaw
        self.checkedAt = checkedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.serviceVersion = serviceVersion
        self.failureCode = failureCode
        self.failureMessage = failureMessage
    }
}

@Model final class StoredLocalModelDescriptor {
    @Attribute(.unique) var id: String
    var displayName: String
    var modifiedAt: Date?
    var sizeBytes: Int64
    var digest: String?
    var details: Data
    var discoveredAt: Date

    init(id: String, displayName: String, modifiedAt: Date?, sizeBytes: Int64, digest: String?, details: Data, discoveredAt: Date) {
        self.id = id
        self.displayName = displayName
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.digest = digest
        self.details = details
        self.discoveredAt = discoveredAt
    }
}

@Model final class StoredModelSelectionRecord {
    @Attribute(.unique) var id: String
    var providerID: String
    var modelID: String?
    var localGenerationEnabled: Bool
    var selectedAt: Date?

    init(id: String = "primary", providerID: String = "ollama", modelID: String? = nil, localGenerationEnabled: Bool = false, selectedAt: Date? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.localGenerationEnabled = localGenerationEnabled
        self.selectedAt = selectedAt
    }
}

@Model final class StoredGenerationProvenanceRecord {
    @Attribute(.unique) var id: String
    var briefID: String
    var providerKind: String
    var modelName: String?
    var endpointClassification: String
    var promptTemplateVersion: String
    var schemaVersion: String
    var generatedAt: Date
    var sourceItemIdentifiers: Data
    var completionStatus: String
    var fallbackStatus: String?
    var durationMilliseconds: Int?
    var promptTokenCount: Int?
    var completionTokenCount: Int?
    var validationResult: String
    var failureCode: String?

    init(id: String, briefID: String, providerKind: String, modelName: String?, endpointClassification: String = "numeric_loopback", promptTemplateVersion: String, schemaVersion: String, generatedAt: Date, sourceItemIdentifiers: Data, completionStatus: String, fallbackStatus: String?, durationMilliseconds: Int?, promptTokenCount: Int?, completionTokenCount: Int?, validationResult: String, failureCode: String?) {
        self.id = id
        self.briefID = briefID
        self.providerKind = providerKind
        self.modelName = modelName
        self.endpointClassification = endpointClassification
        self.promptTemplateVersion = promptTemplateVersion
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceItemIdentifiers = sourceItemIdentifiers
        self.completionStatus = completionStatus
        self.fallbackStatus = fallbackStatus
        self.durationMilliseconds = durationMilliseconds
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.validationResult = validationResult
        self.failureCode = failureCode
    }
}

@Model final class StoredP2Settings {
    @Attribute(.unique) var id: String
    var feedRetentionDays: Int
    var retainedEntriesPerFeed: Int
    var topicPreferences: String
    var generationTimeoutSeconds: Int
    var previewFixturesEnabled: Bool

    init(id: String = "primary", feedRetentionDays: Int = 30, retainedEntriesPerFeed: Int = 200, topicPreferences: String = "", generationTimeoutSeconds: Int = 30, previewFixturesEnabled: Bool = false) {
        self.id = id
        self.feedRetentionDays = feedRetentionDays
        self.retainedEntriesPerFeed = retainedEntriesPerFeed
        self.topicPreferences = topicPreferences
        self.generationTimeoutSeconds = generationTimeoutSeconds
        self.previewFixturesEnabled = previewFixturesEnabled
    }
}

enum LokiBriefSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredSettings.self, StoredBrief.self, StoredReadState.self, StoredStateSnapshot.self]
    }
}

enum LokiBriefSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            StoredSettings.self, StoredBrief.self, StoredReadState.self, StoredStateSnapshot.self,
            StoredFeedSubscription.self, StoredFeedFetch.self, StoredNormalizedFeedEntry.self,
            StoredBriefAssembly.self, StoredModelProviderSnapshotP2.self, StoredLocalModelDescriptor.self,
            StoredModelSelectionRecord.self, StoredGenerationProvenanceRecord.self, StoredP2Settings.self,
        ]
    }
}

enum LokiBriefMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LokiBriefSchemaV1.self, LokiBriefSchemaV2.self, LokiBriefSchemaV3PreEditedAt.self, LokiBriefSchemaV3.self, LokiBriefSchemaV4.self] }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LokiBriefSchemaV1.self, toVersion: LokiBriefSchemaV2.self),
            .lightweight(fromVersion: LokiBriefSchemaV2.self, toVersion: LokiBriefSchemaV3PreEditedAt.self),
            .lightweight(fromVersion: LokiBriefSchemaV3PreEditedAt.self, toVersion: LokiBriefSchemaV3.self),
            .lightweight(fromVersion: LokiBriefSchemaV3.self, toVersion: LokiBriefSchemaV4.self),
        ]
    }
}
