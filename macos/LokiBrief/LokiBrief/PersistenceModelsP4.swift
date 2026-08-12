import Foundation
import SwiftData

enum VaultProviderKind: String, Codable, CaseIterable, Sendable {
    case slack
    case rss
    case discord
    case supportEmail = "support_email"
    case google
    case github
    case microsoft
    case facebook
    case instagram
    case linkedin
    case x
    case localImport = "local_import"

    var isOperationalInP4: Bool { self == .slack || self == .rss }
}

enum VaultAccountState: String, Codable, CaseIterable, Sendable {
    case connected
    case disabled
    case reauthorizationRequired = "reauthorization_required"
    case unavailable
    case notImplemented = "not_implemented"
}

enum VaultCapability: String, Codable, CaseIterable, Sendable {
    case currentSync = "current_sync"
    case historicalBackfill = "historical_backfill"
    case localSearch = "local_search"
    case export
}

enum VaultContainerKind: String, Codable, CaseIterable, Sendable {
    case slackChannel = "slack_channel"
    case discordChannel = "discord_channel"
    case feed
    case repository
    case mailbox
    case calendar
    case socialStream = "social_stream"
    case importedCollection = "imported_collection"
}

enum VaultControlAvailability: String, Codable, Sendable {
    case available
    case configurationRequired = "configuration_required"
    case disconnected
    case unavailable
}

enum VaultSyncPolicyMode: String, Codable, Hashable, Sendable {
    case manual
}

enum VaultBackfillState: String, Codable, Sendable {
    case queued
    case running
    case paused
    case complete
    case degraded
    case failed
    case cancelled
}

enum VaultImportCheckpointState: String, Codable, Sendable {
    case ready
    case running
    case paused
    case complete
    case failed
}

enum VaultDeletionState: String, Codable, Sendable {
    case requested
    case running
    case complete
    case failed
}

enum VaultEntitlementState: String, Codable, Hashable, Sendable {
    case available
    case trial
    case subscribed
    case gracePeriod = "grace_period"
    case expired
    case unavailable
    case providerNotConfigured = "provider_not_configured"
}

enum VaultEntitlementSource: String, Codable, Sendable {
    case deterministicDevelopment = "deterministic_development"
    case providerNotConfigured = "provider_not_configured"
}

enum VaultControlValidation {
    static let maximumIdentifierBytes = 512
    static let maximumDisplayNameCharacters = 160
    static let maximumCursorBytes = 4_096
    static let maximumReasonCodeCharacters = 120
    static let maximumBackfillPages = 10_000
    static let maximumBackfillItems = 1_000_000
    static let maximumRetentionDays = 3_650

    static func validIdentifier(_ value: String) -> Bool {
        let byteCount = value.lengthOfBytes(using: .utf8)
        return byteCount > 0
            && byteCount <= maximumIdentifierBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func boundedDisplayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(maximumDisplayNameCharacters))
    }

    static func boundedReasonCode(_ value: String?) -> String? {
        value.map { String($0.prefix(maximumReasonCodeCharacters)) }
    }
}

@Model final class StoredVaultAccount {
    @Attribute(.unique) var id: String
    var ownerID: String
    var providerRaw: String
    var providerAccountID: String
    var displayName: String
    var availabilityRaw: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        providerRaw: String,
        providerAccountID: String,
        displayName: String,
        availabilityRaw: String,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.providerRaw = providerRaw
        self.providerAccountID = providerAccountID
        self.displayName = VaultControlValidation.boundedDisplayName(displayName, fallback: "Account")
        self.availabilityRaw = availabilityRaw
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StoredVaultContainer {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String
    var providerContainerID: String
    var displayName: String
    var kindRaw: String
    var availabilityRaw: String
    var archivalEnabled: Bool
    var lastImportedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        accountID: String,
        providerContainerID: String,
        displayName: String,
        kindRaw: String,
        availabilityRaw: String,
        archivalEnabled: Bool = true,
        lastImportedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.providerContainerID = providerContainerID
        self.displayName = VaultControlValidation.boundedDisplayName(displayName, fallback: "Container")
        self.kindRaw = kindRaw
        self.availabilityRaw = availabilityRaw
        self.archivalEnabled = archivalEnabled
        self.lastImportedAt = lastImportedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StoredVaultSyncPolicy {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String
    var containerID: String
    var modeRaw: String
    var historicalStartAt: Date?
    var maximumPagesPerRun: Int
    var maximumItemsPerRun: Int
    var enabled: Bool
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        accountID: String,
        containerID: String,
        modeRaw: String = VaultSyncPolicyMode.manual.rawValue,
        historicalStartAt: Date? = nil,
        maximumPagesPerRun: Int = 100,
        maximumItemsPerRun: Int = 10_000,
        enabled: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.modeRaw = modeRaw
        self.historicalStartAt = historicalStartAt
        self.maximumPagesPerRun = min(max(maximumPagesPerRun, 1), VaultControlValidation.maximumBackfillPages)
        self.maximumItemsPerRun = min(max(maximumItemsPerRun, 1), VaultControlValidation.maximumBackfillItems)
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

@Model final class StoredVaultBackfillSummary {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String
    var containerID: String
    var sourceKindRaw: String
    var startedAt: Date
    var completedAt: Date?
    var stateRaw: String
    var pagesRead: Int
    var itemsRead: Int
    var itemsInserted: Int
    var duplicateItems: Int
    var reasonCode: String?

    init(
        id: String,
        ownerID: String,
        accountID: String,
        containerID: String,
        sourceKindRaw: String,
        startedAt: Date,
        completedAt: Date? = nil,
        stateRaw: String,
        pagesRead: Int = 0,
        itemsRead: Int = 0,
        itemsInserted: Int = 0,
        duplicateItems: Int = 0,
        reasonCode: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.sourceKindRaw = sourceKindRaw
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stateRaw = stateRaw
        self.pagesRead = max(0, pagesRead)
        self.itemsRead = max(0, itemsRead)
        self.itemsInserted = max(0, itemsInserted)
        self.duplicateItems = max(0, duplicateItems)
        self.reasonCode = VaultControlValidation.boundedReasonCode(reasonCode)
    }
}

@Model final class StoredVaultBackfillCursor {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String
    var containerID: String
    var sourceKindRaw: String
    var sourceCursor: String?
    var sourceHighWatermark: String?
    var lastStableItemID: String?
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        accountID: String,
        containerID: String,
        sourceKindRaw: String,
        sourceCursor: String? = nil,
        sourceHighWatermark: String? = nil,
        lastStableItemID: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.sourceKindRaw = sourceKindRaw
        self.sourceCursor = sourceCursor.map { String($0.prefix(VaultControlValidation.maximumCursorBytes)) }
        self.sourceHighWatermark = sourceHighWatermark.map { String($0.prefix(VaultControlValidation.maximumCursorBytes)) }
        self.lastStableItemID = lastStableItemID
        self.updatedAt = updatedAt
    }
}

@Model final class StoredVaultStorageSnapshot {
    @Attribute(.unique) var id: String
    var ownerID: String
    var measuredAt: Date
    var archiveBytes: Int64
    var searchIndexBytes: Int64
    var controlStoreBytes: Int64
    var archivedItemCount: Int
    var applicationEncryptedAtRest: Bool

    init(
        id: String,
        ownerID: String,
        measuredAt: Date,
        archiveBytes: Int64,
        searchIndexBytes: Int64,
        controlStoreBytes: Int64,
        archivedItemCount: Int,
        applicationEncryptedAtRest: Bool = false
    ) {
        self.id = id
        self.ownerID = ownerID
        self.measuredAt = measuredAt
        self.archiveBytes = max(0, archiveBytes)
        self.searchIndexBytes = max(0, searchIndexBytes)
        self.controlStoreBytes = max(0, controlStoreBytes)
        self.archivedItemCount = max(0, archivedItemCount)
        self.applicationEncryptedAtRest = applicationEncryptedAtRest
    }
}

@Model final class StoredVaultRetentionPolicy {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String?
    var containerID: String?
    var retentionDays: Int
    var preserveSourceRepresentation: Bool
    var automaticDeletionEnabled: Bool
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        accountID: String? = nil,
        containerID: String? = nil,
        retentionDays: Int = 30,
        preserveSourceRepresentation: Bool = true,
        automaticDeletionEnabled: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.retentionDays = min(max(retentionDays, 1), VaultControlValidation.maximumRetentionDays)
        self.preserveSourceRepresentation = preserveSourceRepresentation
        self.automaticDeletionEnabled = automaticDeletionEnabled
        self.updatedAt = updatedAt
    }
}

@Model final class StoredVaultEntitlement {
    @Attribute(.unique) var id: String
    var ownerID: String
    var productID: String
    var sourceRaw: String
    var stateRaw: String
    var capabilitiesRaw: String
    var validFrom: Date
    var validThrough: Date?
    var observedAt: Date
    var configurationFingerprint: String

    init(
        id: String,
        ownerID: String,
        productID: String,
        sourceRaw: String,
        stateRaw: String,
        capabilitiesRaw: String,
        validFrom: Date,
        validThrough: Date? = nil,
        observedAt: Date,
        configurationFingerprint: String
    ) {
        self.id = id
        self.ownerID = ownerID
        self.productID = productID
        self.sourceRaw = sourceRaw
        self.stateRaw = stateRaw
        self.capabilitiesRaw = capabilitiesRaw
        self.validFrom = validFrom
        self.validThrough = validThrough
        self.observedAt = observedAt
        self.configurationFingerprint = configurationFingerprint
    }
}

@Model final class StoredVaultDeletionRecord {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String?
    var containerID: String?
    var requestedAt: Date
    var completedAt: Date?
    var stateRaw: String
    var deletedArchiveItemCount: Int
    var deletedOriginalByteCount: Int64
    var reasonCode: String

    init(
        id: String,
        ownerID: String,
        accountID: String? = nil,
        containerID: String? = nil,
        requestedAt: Date,
        completedAt: Date? = nil,
        stateRaw: String,
        deletedArchiveItemCount: Int = 0,
        deletedOriginalByteCount: Int64 = 0,
        reasonCode: String
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.stateRaw = stateRaw
        self.deletedArchiveItemCount = max(0, deletedArchiveItemCount)
        self.deletedOriginalByteCount = max(0, deletedOriginalByteCount)
        self.reasonCode = String(reasonCode.prefix(VaultControlValidation.maximumReasonCodeCharacters))
    }
}

@Model final class StoredVaultImportCheckpoint {
    @Attribute(.unique) var id: String
    var ownerID: String
    var accountID: String
    var containerID: String
    var sourceKindRaw: String
    var runID: String
    var stateRaw: String
    var sourceCursor: String?
    var sourceHighWatermark: String?
    var pagesCommitted: Int
    var itemsRead: Int
    var itemsInserted: Int
    var duplicateItems: Int
    var lastReasonCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        ownerID: String,
        accountID: String,
        containerID: String,
        sourceKindRaw: String,
        runID: String,
        stateRaw: String,
        sourceCursor: String? = nil,
        sourceHighWatermark: String? = nil,
        pagesCommitted: Int = 0,
        itemsRead: Int = 0,
        itemsInserted: Int = 0,
        duplicateItems: Int = 0,
        lastReasonCode: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.sourceKindRaw = sourceKindRaw
        self.runID = runID
        self.stateRaw = stateRaw
        self.sourceCursor = sourceCursor.map { String($0.prefix(VaultControlValidation.maximumCursorBytes)) }
        self.sourceHighWatermark = sourceHighWatermark.map { String($0.prefix(VaultControlValidation.maximumCursorBytes)) }
        self.pagesCommitted = max(0, pagesCommitted)
        self.itemsRead = max(0, itemsRead)
        self.itemsInserted = max(0, itemsInserted)
        self.duplicateItems = max(0, duplicateItems)
        self.lastReasonCode = VaultControlValidation.boundedReasonCode(lastReasonCode)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum LokiBriefSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV3.models + [
            StoredVaultAccount.self,
            StoredVaultContainer.self,
            StoredVaultSyncPolicy.self,
            StoredVaultBackfillSummary.self,
            StoredVaultBackfillCursor.self,
            StoredVaultStorageSnapshot.self,
            StoredVaultRetentionPolicy.self,
            StoredVaultEntitlement.self,
            StoredVaultDeletionRecord.self,
            StoredVaultImportCheckpoint.self,
        ]
    }
}

enum LokiBriefMigrationPlanV4: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LokiBriefSchemaV1.self, LokiBriefSchemaV2.self, LokiBriefSchemaV3PreEditedAt.self, LokiBriefSchemaV3.self, LokiBriefSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LokiBriefSchemaV1.self, toVersion: LokiBriefSchemaV2.self),
            .lightweight(fromVersion: LokiBriefSchemaV2.self, toVersion: LokiBriefSchemaV3PreEditedAt.self),
            .lightweight(fromVersion: LokiBriefSchemaV3PreEditedAt.self, toVersion: LokiBriefSchemaV3.self),
            .lightweight(fromVersion: LokiBriefSchemaV3.self, toVersion: LokiBriefSchemaV4.self),
        ]
    }
}

@MainActor
extension LocalStore {
    private var p4Context: ModelContext { container.mainContext }

    func vaultAccounts() throws -> [StoredVaultAccount] {
        try p4Context.fetch(FetchDescriptor<StoredVaultAccount>()).sorted {
            if $0.providerRaw != $1.providerRaw { return $0.providerRaw < $1.providerRaw }
            if $0.displayName != $1.displayName { return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    func vaultContainers(accountID: String? = nil) throws -> [StoredVaultContainer] {
        try p4Context.fetch(FetchDescriptor<StoredVaultContainer>())
            .filter { accountID == nil || $0.accountID == accountID }
            .sorted {
                if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
                if $0.displayName != $1.displayName { return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                return $0.id < $1.id
            }
    }

    func upsertVaultAccount(_ incoming: StoredVaultAccount) throws {
        if let existing = try p4Context.fetch(FetchDescriptor<StoredVaultAccount>()).first(where: { $0.id == incoming.id }) {
            existing.ownerID = incoming.ownerID
            existing.providerRaw = incoming.providerRaw
            existing.providerAccountID = incoming.providerAccountID
            existing.displayName = incoming.displayName
            existing.availabilityRaw = incoming.availabilityRaw
            existing.enabled = incoming.enabled
            existing.updatedAt = incoming.updatedAt
        } else {
            p4Context.insert(incoming)
        }
        try p4Context.save()
    }

    func upsertVaultContainer(_ incoming: StoredVaultContainer) throws {
        if let existing = try p4Context.fetch(FetchDescriptor<StoredVaultContainer>()).first(where: { $0.id == incoming.id }) {
            existing.accountID = incoming.accountID
            existing.providerContainerID = incoming.providerContainerID
            existing.displayName = incoming.displayName
            existing.kindRaw = incoming.kindRaw
            existing.availabilityRaw = incoming.availabilityRaw
            existing.archivalEnabled = incoming.archivalEnabled
            existing.lastImportedAt = incoming.lastImportedAt
            existing.updatedAt = incoming.updatedAt
        } else {
            p4Context.insert(incoming)
        }
        try p4Context.save()
    }

    func vaultImportCheckpoint(id: String) throws -> StoredVaultImportCheckpoint? {
        try p4Context.fetch(FetchDescriptor<StoredVaultImportCheckpoint>()).first(where: { $0.id == id })
    }

    func saveVaultImportCheckpoint(_ value: VaultImportCheckpoint) throws {
        let existing = try vaultImportCheckpoint(id: value.id)
        let target = existing ?? StoredVaultImportCheckpoint(
            id: value.id,
            ownerID: value.ownerID,
            accountID: value.accountID,
            containerID: value.containerID,
            sourceKindRaw: value.sourceKind.rawValue,
            runID: value.runID,
            stateRaw: value.state.rawValue,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt
        )
        target.runID = value.runID
        target.stateRaw = value.state.rawValue
        target.sourceCursor = value.sourceCursor
        target.sourceHighWatermark = value.sourceHighWatermark
        target.pagesCommitted = value.pagesCommitted
        target.itemsRead = value.itemsRead
        target.itemsInserted = value.itemsInserted
        target.duplicateItems = value.duplicateItems
        target.lastReasonCode = value.lastReasonCode
        target.updatedAt = value.updatedAt
        if existing == nil { p4Context.insert(target) }
        try p4Context.save()
    }

    func vaultImportCheckpointDomain(id: String) throws -> VaultImportCheckpoint? {
        guard let value = try vaultImportCheckpoint(id: id),
              let kind = VaultProviderKind(rawValue: value.sourceKindRaw),
              let state = VaultImportCheckpointState(rawValue: value.stateRaw)
        else { return nil }
        return .init(
            id: value.id,
            ownerID: value.ownerID,
            accountID: value.accountID,
            containerID: value.containerID,
            sourceKind: kind,
            runID: value.runID,
            state: state,
            sourceCursor: value.sourceCursor,
            sourceHighWatermark: value.sourceHighWatermark,
            pagesCommitted: value.pagesCommitted,
            itemsRead: value.itemsRead,
            itemsInserted: value.itemsInserted,
            duplicateItems: value.duplicateItems,
            lastReasonCode: value.lastReasonCode,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt
        )
    }
}
