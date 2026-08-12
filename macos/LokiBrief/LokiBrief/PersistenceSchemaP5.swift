import Foundation
import SwiftData

enum LokiBriefSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    // A pre-seal P5 build persisted scheduled-run rows before the immutable
    // plan-metadata payload was added while retaining the 5.0.0 version
    // identifier. Keep that exact model shape so those stores are recognized
    // and advanced without reset.
    @Model final class StoredScheduledBriefingRun {
        @Attribute(.unique) var id: String
        var occurrenceHash: String
        var planFingerprint: String
        var scheduledFor: Date
        var triggerRaw: String
        var stateRaw: String
        var coordinatorStateRaw: String
        var reasonCode: String
        var traceID: String
        var startedAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var feedSourceCount: Int
        var slackWorkspaceCount: Int
        var successfulSourceCount: Int
        var failedSourceCount: Int
        var acceptedItemCount: Int
        var vaultStatusRaw: String?
        var vaultChangedItemCount: Int
        var briefID: String?
        var briefIDHash: String?
        var fallbackReasonCode: String?
        var sourceOutcomesData: Data
        var failureReasonCodesData: Data
        var schemaVersion: Int
        var maximumTotalDurationSeconds: Double
        var maximumFeedRequests: Int
        var maximumSlackRequests: Int
        var maximumNewArchiveItems: Int
        var maximumStorageGrowthBytes: Int64
        var maximumTransientRetries: Int
        var maximumOllamaDurationSeconds: Double
        var nextScheduledOccurrence: Date?

        init(id: String, planFingerprint: String, scheduledFor: Date) {
            self.id = id
            occurrenceHash = "legacy-occurrence-hash"
            self.planFingerprint = planFingerprint
            self.scheduledFor = scheduledFor
            triggerRaw = ScheduledRunTrigger.scheduled.rawValue
            stateRaw = ScheduledRunState.completed.rawValue
            coordinatorStateRaw = ScheduledBriefingRunState.complete.rawValue
            reasonCode = ScheduledBriefingReason.runComplete
            traceID = "legacy-trace"
            startedAt = scheduledFor
            updatedAt = scheduledFor
            completedAt = scheduledFor
            feedSourceCount = 1
            slackWorkspaceCount = 1
            successfulSourceCount = 2
            failedSourceCount = 0
            acceptedItemCount = 2
            vaultStatusRaw = ScheduledBriefingStageStatus.success.rawValue
            vaultChangedItemCount = 2
            briefID = "legacy-brief"
            briefIDHash = "legacy-brief-hash"
            fallbackReasonCode = nil
            sourceOutcomesData = Data("[]".utf8)
            failureReasonCodesData = Data("[]".utf8)
            schemaVersion = 1
            maximumTotalDurationSeconds = 300
            maximumFeedRequests = 100
            maximumSlackRequests = 200
            maximumNewArchiveItems = 5_000
            maximumStorageGrowthBytes = 50 * 1_024 * 1_024
            maximumTransientRetries = 8
            maximumOllamaDurationSeconds = 60
            nextScheduledOccurrence = nil
        }
    }

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV4.models + [
            StoredBriefSchedule.self,
            StoredScheduleOccurrence.self,
            StoredScheduledBriefingRun.self,
            StoredScheduledBriefingSourceResult.self,
            StoredNotificationDeliverySettings.self,
            StoredDeliveryRecord.self,
        ]
    }
}

enum LokiBriefSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV4.models + [
            StoredBriefSchedule.self,
            StoredScheduleOccurrence.self,
            StoredScheduledBriefingRun.self,
            StoredScheduledBriefingSourceResult.self,
            StoredNotificationDeliverySettings.self,
            StoredDeliveryRecord.self,
        ]
    }
}

enum LokiBriefSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV6.models + [StoredLocalCalendarDay.self]
    }
}

enum LokiBriefMigrationPlanV7: SchemaMigrationPlan {
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
        ]
    }
}
