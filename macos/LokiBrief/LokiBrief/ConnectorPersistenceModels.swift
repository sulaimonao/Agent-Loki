import Foundation
import SwiftData

enum ConnectorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case slack
    case discord
    case supportEmail = "support_email"
    case attachedData = "attached_data"

    var displayName: String {
        switch self {
        case .slack: "Slack"
        case .discord: "Discord"
        case .supportEmail: "Support Email"
        case .attachedData: "Attached Data"
        }
    }
}

enum ConnectorConnectionState: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case disconnected
    case connecting
    case connected
    case syncing
    case degraded
    case failed
    case disabled
}

enum ConnectorPrivacyClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case localSelectedSource = "local_selected_source"
    case localImportedMailbox = "local_imported_mailbox"
    case localArchiveOnly = "local_archive_only"
}

struct ConnectorStatusSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: ConnectorKind
    let stableAccountIdentifier: String
    var displayName: String
    var state: ConnectorConnectionState
    var credentialReference: String?
    var selectedSourceIdentifiers: [String]
    var cursorData: Data?
    var lastSuccessfulSync: Date?
    var lastAttemptedSync: Date?
    var importedItemCount: Int
    var skippedItemCount: Int
    var attachmentCount: Int
    var privacyClassification: ConnectorPrivacyClassification
    var lastErrorReasonCode: String?
    var retryAfter: Date?
    var automaticSyncEnabled: Bool
    var localModelConsentEnabled: Bool
    var localDataRemovalPolicy: String
    var latestReceiptIdentifier: String?
    var updatedAt: Date

    init(
        id: String,
        kind: ConnectorKind,
        stableAccountIdentifier: String,
        displayName: String,
        state: ConnectorConnectionState = .disconnected,
        credentialReference: String? = nil,
        selectedSourceIdentifiers: [String] = [],
        cursorData: Data? = nil,
        lastSuccessfulSync: Date? = nil,
        lastAttemptedSync: Date? = nil,
        importedItemCount: Int = 0,
        skippedItemCount: Int = 0,
        attachmentCount: Int = 0,
        privacyClassification: ConnectorPrivacyClassification,
        lastErrorReasonCode: String? = nil,
        retryAfter: Date? = nil,
        automaticSyncEnabled: Bool = false,
        localModelConsentEnabled: Bool = false,
        localDataRemovalPolicy: String = "disconnect_preserves_local_data",
        latestReceiptIdentifier: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.stableAccountIdentifier = stableAccountIdentifier
        self.displayName = displayName
        self.state = state
        self.credentialReference = credentialReference
        self.selectedSourceIdentifiers = Array(Set(selectedSourceIdentifiers)).sorted()
        self.cursorData = cursorData
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastAttemptedSync = lastAttemptedSync
        self.importedItemCount = max(0, importedItemCount)
        self.skippedItemCount = max(0, skippedItemCount)
        self.attachmentCount = max(0, attachmentCount)
        self.privacyClassification = privacyClassification
        self.lastErrorReasonCode = lastErrorReasonCode
        self.retryAfter = retryAfter
        self.automaticSyncEnabled = automaticSyncEnabled
        self.localModelConsentEnabled = localModelConsentEnabled
        self.localDataRemovalPolicy = localDataRemovalPolicy
        self.latestReceiptIdentifier = latestReceiptIdentifier
        self.updatedAt = updatedAt
    }
}

struct ConnectorSyncReceipt: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let connectorStatusIdentifier: String
    let kind: ConnectorKind
    let traceID: String
    let startedAt: Date
    let completedAt: Date
    let status: ConnectorConnectionState
    let reasonCode: String
    let importedItemCount: Int
    let updatedItemCount: Int
    let tombstonedItemCount: Int
    let skippedItemCount: Int
    let attachmentCount: Int
    let pageCount: Int
    let sourceAllowlistHash: String
    let receiptHash: String

    init(
        id: String,
        connectorStatusIdentifier: String,
        kind: ConnectorKind,
        traceID: String,
        startedAt: Date,
        completedAt: Date,
        status: ConnectorConnectionState,
        reasonCode: String,
        importedItemCount: Int,
        updatedItemCount: Int,
        tombstonedItemCount: Int,
        skippedItemCount: Int,
        attachmentCount: Int,
        pageCount: Int,
        sourceAllowlistHash: String,
        receiptHash: String
    ) {
        self.id = id
        self.connectorStatusIdentifier = connectorStatusIdentifier
        self.kind = kind
        self.traceID = traceID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.reasonCode = reasonCode
        self.importedItemCount = max(0, importedItemCount)
        self.updatedItemCount = max(0, updatedItemCount)
        self.tombstonedItemCount = max(0, tombstonedItemCount)
        self.skippedItemCount = max(0, skippedItemCount)
        self.attachmentCount = max(0, attachmentCount)
        self.pageCount = max(0, pageCount)
        self.sourceAllowlistHash = sourceAllowlistHash
        self.receiptHash = receiptHash
    }
}

struct EmailImportAccessSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let mailboxIdentity: String
    let securityScopedBookmark: Data
    let fileIdentityHash: String
    let committedByteOffset: Int64
    let highWatermarkHash: String?
    let updatedAt: Date
}

@Model final class StoredConnectorStatus {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var stableAccountIdentifier: String
    var displayName: String
    var stateRaw: String
    var credentialReference: String?
    var selectedSourceIdentifiersData: Data
    var cursorData: Data?
    var lastSuccessfulSync: Date?
    var lastAttemptedSync: Date?
    var importedItemCount: Int
    var skippedItemCount: Int
    var attachmentCount: Int
    var privacyClassificationRaw: String
    var lastErrorReasonCode: String?
    var retryAfter: Date?
    var automaticSyncEnabled: Bool
    var localModelConsentEnabled: Bool
    var localDataRemovalPolicy: String
    var latestReceiptIdentifier: String?
    var updatedAt: Date
    var schemaVersion: Int

    init(_ value: ConnectorStatusSnapshot) throws {
        id = value.id
        kindRaw = value.kind.rawValue
        stableAccountIdentifier = value.stableAccountIdentifier
        displayName = value.displayName
        stateRaw = value.state.rawValue
        credentialReference = value.credentialReference
        selectedSourceIdentifiersData = try JSONEncoder().encode(value.selectedSourceIdentifiers)
        cursorData = value.cursorData
        lastSuccessfulSync = value.lastSuccessfulSync
        lastAttemptedSync = value.lastAttemptedSync
        importedItemCount = value.importedItemCount
        skippedItemCount = value.skippedItemCount
        attachmentCount = value.attachmentCount
        privacyClassificationRaw = value.privacyClassification.rawValue
        lastErrorReasonCode = value.lastErrorReasonCode
        retryAfter = value.retryAfter
        automaticSyncEnabled = value.automaticSyncEnabled
        localModelConsentEnabled = value.localModelConsentEnabled
        localDataRemovalPolicy = value.localDataRemovalPolicy
        latestReceiptIdentifier = value.latestReceiptIdentifier
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    func update(with value: ConnectorStatusSnapshot) throws {
        kindRaw = value.kind.rawValue
        stableAccountIdentifier = value.stableAccountIdentifier
        displayName = value.displayName
        stateRaw = value.state.rawValue
        credentialReference = value.credentialReference
        selectedSourceIdentifiersData = try JSONEncoder().encode(value.selectedSourceIdentifiers)
        cursorData = value.cursorData
        lastSuccessfulSync = value.lastSuccessfulSync
        lastAttemptedSync = value.lastAttemptedSync
        importedItemCount = value.importedItemCount
        skippedItemCount = value.skippedItemCount
        attachmentCount = value.attachmentCount
        privacyClassificationRaw = value.privacyClassification.rawValue
        lastErrorReasonCode = value.lastErrorReasonCode
        retryAfter = value.retryAfter
        automaticSyncEnabled = value.automaticSyncEnabled
        localModelConsentEnabled = value.localModelConsentEnabled
        localDataRemovalPolicy = value.localDataRemovalPolicy
        latestReceiptIdentifier = value.latestReceiptIdentifier
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    func domain() throws -> ConnectorStatusSnapshot {
        guard let kind = ConnectorKind(rawValue: kindRaw),
              let state = ConnectorConnectionState(rawValue: stateRaw),
              let privacy = ConnectorPrivacyClassification(rawValue: privacyClassificationRaw)
        else { throw CocoaError(.coderInvalidValue) }
        return .init(
            id: id,
            kind: kind,
            stableAccountIdentifier: stableAccountIdentifier,
            displayName: displayName,
            state: state,
            credentialReference: credentialReference,
            selectedSourceIdentifiers: try JSONDecoder().decode(
                [String].self,
                from: selectedSourceIdentifiersData
            ),
            cursorData: cursorData,
            lastSuccessfulSync: lastSuccessfulSync,
            lastAttemptedSync: lastAttemptedSync,
            importedItemCount: importedItemCount,
            skippedItemCount: skippedItemCount,
            attachmentCount: attachmentCount,
            privacyClassification: privacy,
            lastErrorReasonCode: lastErrorReasonCode,
            retryAfter: retryAfter,
            automaticSyncEnabled: automaticSyncEnabled,
            localModelConsentEnabled: localModelConsentEnabled,
            localDataRemovalPolicy: localDataRemovalPolicy,
            latestReceiptIdentifier: latestReceiptIdentifier,
            updatedAt: updatedAt
        )
    }
}

@Model final class StoredConnectorSyncReceipt {
    @Attribute(.unique) var id: String
    var connectorStatusIdentifier: String
    var kindRaw: String
    var encodedReceipt: Data
    var completedAt: Date
    var schemaVersion: Int

    init(_ value: ConnectorSyncReceipt) throws {
        id = value.id
        connectorStatusIdentifier = value.connectorStatusIdentifier
        kindRaw = value.kind.rawValue
        encodedReceipt = try JSONEncoder().encode(value)
        completedAt = value.completedAt
        schemaVersion = 1
    }

    func domain() throws -> ConnectorSyncReceipt {
        try JSONDecoder().decode(ConnectorSyncReceipt.self, from: encodedReceipt)
    }
}

@Model final class StoredEmailImportAccess {
    @Attribute(.unique) var id: String
    var mailboxIdentity: String
    var securityScopedBookmark: Data
    var fileIdentityHash: String
    var committedByteOffset: Int64
    var highWatermarkHash: String?
    var updatedAt: Date
    var schemaVersion: Int

    init(_ value: EmailImportAccessSnapshot) {
        id = value.id
        mailboxIdentity = value.mailboxIdentity
        securityScopedBookmark = value.securityScopedBookmark
        fileIdentityHash = value.fileIdentityHash
        committedByteOffset = max(0, value.committedByteOffset)
        highWatermarkHash = value.highWatermarkHash
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    func update(with value: EmailImportAccessSnapshot) {
        mailboxIdentity = value.mailboxIdentity
        securityScopedBookmark = value.securityScopedBookmark
        fileIdentityHash = value.fileIdentityHash
        committedByteOffset = max(0, value.committedByteOffset)
        highWatermarkHash = value.highWatermarkHash
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    func domain() -> EmailImportAccessSnapshot {
        .init(
            id: id,
            mailboxIdentity: mailboxIdentity,
            securityScopedBookmark: securityScopedBookmark,
            fileIdentityHash: fileIdentityHash,
            committedByteOffset: committedByteOffset,
            highWatermarkHash: highWatermarkHash,
            updatedAt: updatedAt
        )
    }
}

enum LokiBriefSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV9.models + [
            StoredConnectorStatus.self,
            StoredConnectorSyncReceipt.self,
            StoredEmailImportAccess.self,
        ]
    }
}

enum LokiBriefMigrationPlanV10: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LokiBriefMigrationPlanV9.schemas + [LokiBriefSchemaV10.self]
    }

    static var stages: [MigrationStage] {
        LokiBriefMigrationPlanV9.stages + [
            .lightweight(
                fromVersion: LokiBriefSchemaV9.self,
                toVersion: LokiBriefSchemaV10.self
            ),
        ]
    }
}
