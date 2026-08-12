import Foundation

enum VaultLimits {
    static let schemaVersion = 3
    static let busyTimeoutMilliseconds: Int32 = 5_000
    static let maximumProviderCharacters = 80
    static let maximumIdentifierCharacters = 512
    static let maximumDisplayNameCharacters = 300
    static let maximumKindCharacters = 80
    static let maximumTitleCharacters = 2_000
    static let maximumBodyBytes = 2 * 1_024 * 1_024
    static let maximumAuthorCharacters = 500
    static let maximumURLCharacters = 4_096
    static let maximumMetadataEntries = 64
    static let maximumMetadataBytes = 64 * 1_024
    static let maximumSearchCharacters = 512
    static let maximumSearchTokens = 16
    static let maximumSearchResults = 200
    static let maximumSearchSnippetCharacters = 500
    static let maximumBatchSize = 1_000
    static let maximumConnectorGenerationRecords = 10_000
    static let maximumConnectorGenerationContainers = 128
    static let maximumRetentionDays = 3_650
    static let maximumRecordsPerContainer = 100_000
    static let maximumRetentionDeletesPerRun = 5_000
    static let maximumRevisionsPerItem = 10
}

enum VaultIdentity {
    static func accountID(provider: String, providerAccountID: String) -> String {
        "\(provider):\(providerAccountID)"
    }

    static func containerID(provider: String, accountID: String, providerContainerID: String) -> String {
        "\(provider):\(accountID):\(providerContainerID)"
    }
}

enum VaultContentOrigin: String, Codable, CaseIterable, Sendable {
    case source
    case generated
}

enum VaultReadFilter: String, Codable, CaseIterable, Sendable {
    case read
    case unread
}

enum VaultRetentionPreset: String, Codable, CaseIterable, Sendable {
    case recentOnly = "recent_only"
    case thirtyDays = "thirty_days"
    case ninetyDays = "ninety_days"
    case oneYear = "one_year"
    case unlimited
    case custom
}

enum VaultAccountDeletionState: String, Codable, CaseIterable, Sendable {
    case idle
    case pausingJobs = "pausing_jobs"
    case deletingArchive = "deleting_archive"
    case disconnecting
    case complete
    case failed
}

struct VaultSyncPolicy: Codable, Hashable, Sendable {
    let mode: VaultSyncPolicyMode
    let archivalEnabled: Bool
    let historicalStartAt: Date?
    let maximumRequestsPerRun: Int
    let maximumItemsPerRun: Int
}

struct VaultAccountEntitlement: Codable, Hashable, Sendable {
    let accountID: String
    let state: VaultEntitlementState
    let capabilities: Set<VaultEntitlementCapability>
    let acquisitionAllowed: Bool
}

enum VaultSearchPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case likeOnly = "like_only"
}

enum VaultSearchMode: String, Codable, CaseIterable, Sendable {
    case fullText = "fts5"
    case likeFallback = "like_fallback"
}

enum VaultUpsertDisposition: String, Codable, CaseIterable, Sendable {
    case inserted
    case updated
    case unchanged
    case resurrected
}

enum VaultTombstoneReason: String, Codable, CaseIterable, Sendable {
    case sourceDeleted = "source_deleted"
    case sourceInaccessible = "source_inaccessible"
    case accountDeleted = "account_deleted"
    case containerDeleted = "container_deleted"
    case retentionExpired = "retention_expired"
    case replaced = "replaced"
    case userDeleted = "user_deleted"
}

enum VaultOpenDisposition: Codable, Hashable, Sendable {
    case created(schemaVersion: Int)
    case opened(schemaVersion: Int)
    case migrated(from: Int, to: Int)
}

enum VaultRecoveryClassification: String, Codable, CaseIterable, Sendable {
    case healthy = "vault_healthy"
    case migrationRequired = "vault_migration_required"
    case lockedRetryable = "vault_locked_retryable"
    case unsupportedNewerSchemaPreserveOriginal = "vault_unsupported_newer_schema_preserve_original"
    case corruptionPreserveOriginal = "vault_corruption_preserve_original"
    case foreignKeyRepairRequired = "vault_foreign_key_repair_required"
    case ftsRebuildRequired = "vault_fts_rebuild_required"
    case inaccessiblePreserveOriginal = "vault_inaccessible_preserve_original"
    case closed = "vault_closed"
    case unknownPreserveOriginal = "vault_unknown_preserve_original"
}

struct VaultDatabaseFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let reasonCode: String
    let operation: String
    let sqliteCode: Int32?
    let recoveryClassification: VaultRecoveryClassification

    var errorDescription: String? {
        "Loki Vault could not complete \(operation) (\(reasonCode))."
    }
}

struct VaultAccountInput: Codable, Hashable, Sendable {
    let id: String
    let provider: String
    let providerAccountID: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
}

struct VaultAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: String
    let providerAccountID: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
}

struct VaultContainerInput: Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let providerContainerID: String
    let kind: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
}

struct VaultContainer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let providerContainerID: String
    let kind: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
}

struct VaultRecordInput: Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let containerID: String
    let providerRecordID: String
    let kind: String
    let title: String
    let body: String
    let author: String?
    let sourceURL: URL?
    let occurredAt: Date
    let capturedAt: Date
    let modifiedAt: Date
    let metadata: [String: String]
    let directlyMentionsUser: Bool
    let isRead: Bool
    let contentOrigin: VaultContentOrigin
    let providerMetadataVersion: Int
    let threadRootID: String?
    let replyCount: Int

    init(
        id: String,
        accountID: String,
        containerID: String,
        providerRecordID: String,
        kind: String,
        title: String,
        body: String,
        author: String? = nil,
        sourceURL: URL? = nil,
        occurredAt: Date,
        capturedAt: Date,
        modifiedAt: Date,
        metadata: [String: String] = [:],
        directlyMentionsUser: Bool = false,
        isRead: Bool = false,
        contentOrigin: VaultContentOrigin = .source,
        providerMetadataVersion: Int = 1,
        threadRootID: String? = nil,
        replyCount: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.containerID = containerID
        self.providerRecordID = providerRecordID
        self.kind = kind
        self.title = title
        self.body = body
        self.author = author
        self.sourceURL = sourceURL
        self.occurredAt = occurredAt
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.metadata = metadata
        self.directlyMentionsUser = directlyMentionsUser
        self.isRead = isRead
        self.contentOrigin = contentOrigin
        self.providerMetadataVersion = max(1, providerMetadataVersion)
        self.threadRootID = threadRootID
        self.replyCount = max(0, replyCount)
    }
}

struct VaultRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let containerID: String
    let providerRecordID: String
    let kind: String
    let title: String
    let body: String
    let author: String?
    let sourceURL: URL?
    let occurredAt: Date
    let capturedAt: Date
    let modifiedAt: Date
    let metadata: [String: String]
    let revision: Int
    let contentChecksum: String
    let provider: String
    let insertedAt: Date
    let directlyMentionsUser: Bool
    let isRead: Bool
    let contentOrigin: VaultContentOrigin
    let providerMetadataVersion: Int
    let threadRootID: String?
    let replyCount: Int
}

struct VaultRecordRevision: Codable, Hashable, Sendable {
    let recordID: String
    let revision: Int
    let title: String
    let body: String
    let author: String?
    let sourceURL: URL?
    let occurredAt: Date
    let capturedAt: Date
    let modifiedAt: Date
    let metadata: [String: String]
    let contentChecksum: String
    let storedAt: Date
}

struct VaultTombstone: Identifiable, Codable, Hashable, Sendable {
    var id: String { recordID }
    let recordID: String
    let accountID: String
    let containerID: String
    let providerRecordID: String
    let reason: VaultTombstoneReason
    let deletedAt: Date
    let priorContentPurged: Bool
}

struct VaultUpsertResult: Codable, Hashable, Sendable {
    let recordID: String
    let disposition: VaultUpsertDisposition
    let revision: Int
    let contentChecksum: String
}

struct VaultSearchRequest: Codable, Hashable, Sendable {
    let text: String
    let accountID: String?
    let containerID: String?
    let provider: String?
    let author: String?
    let startDate: Date?
    let endDate: Date?
    let itemKind: String?
    let directlyMentionsUser: Bool?
    let readFilter: VaultReadFilter?
    let deleted: Bool?
    let contentOrigin: VaultContentOrigin?
    let limit: Int
    let offset: Int
    let preference: VaultSearchPreference

    init(
        text: String,
        accountID: String? = nil,
        containerID: String? = nil,
        provider: String? = nil,
        author: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        itemKind: String? = nil,
        directlyMentionsUser: Bool? = nil,
        readFilter: VaultReadFilter? = nil,
        deleted: Bool? = false,
        contentOrigin: VaultContentOrigin? = nil,
        limit: Int = 50,
        offset: Int = 0,
        preference: VaultSearchPreference = .automatic
    ) {
        self.text = text
        self.accountID = accountID
        self.containerID = containerID
        self.provider = provider
        self.author = author
        self.startDate = startDate
        self.endDate = endDate
        self.itemKind = itemKind
        self.directlyMentionsUser = directlyMentionsUser
        self.readFilter = readFilter
        self.deleted = deleted
        self.contentOrigin = contentOrigin
        self.limit = limit
        self.offset = offset
        self.preference = preference
    }
}

struct VaultSearchResult: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let accountID: String
    let containerID: String
    let kind: String
    let title: String
    let snippet: String
    let occurredAt: Date
    let revision: Int
    let contentChecksum: String
    let provider: String
    let author: String?
    let sourceURL: URL?
    let directlyMentionsUser: Bool
    let isRead: Bool
    let isDeleted: Bool
    let contentOrigin: VaultContentOrigin
    let attachedSourceProvenance: VaultAttachedSourceProvenance?

    init(
        id: String,
        accountID: String,
        containerID: String,
        kind: String,
        title: String,
        snippet: String,
        occurredAt: Date,
        revision: Int,
        contentChecksum: String,
        provider: String,
        author: String?,
        sourceURL: URL?,
        directlyMentionsUser: Bool,
        isRead: Bool,
        isDeleted: Bool,
        contentOrigin: VaultContentOrigin,
        attachedSourceProvenance: VaultAttachedSourceProvenance? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.containerID = containerID
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.occurredAt = occurredAt
        self.revision = revision
        self.contentChecksum = contentChecksum
        self.provider = provider
        self.author = author
        self.sourceURL = sourceURL
        self.directlyMentionsUser = directlyMentionsUser
        self.isRead = isRead
        self.isDeleted = isDeleted
        self.contentOrigin = contentOrigin
        self.attachedSourceProvenance = attachedSourceProvenance
    }
}

/// Privacy-safe, allowlisted projection of attached-record provenance. Raw
/// Vault metadata and source file locations never cross this DTO boundary.
struct VaultAttachedSourceProvenance: Codable, Hashable, Sendable {
    let sourceIdentifier: String
    let sourceKind: String
    let sourceEpoch: Int64
    let sourceDigest: String
    let selectionIdentifier: String
    let selectionSourceIdentifier: String
    let stableRecordIdentifier: String
    let recordLocator: String
    let schemaDigest: String
    let generationIdentifier: String
    let generationReceiptHash: String
    let pageReceiptHash: String
    let identityStrategy: String
    let wasTruncated: Bool

    static func project(from record: VaultRecord) -> Self? {
        let metadata = record.metadata
        guard record.provider.lowercased()
                == VaultProviderKind.localImport.rawValue,
              let sourceIdentifier = metadata["attached_source_id"],
              let sourceKind = metadata["attached_source_kind"],
              let epochText = metadata["attached_source_epoch"],
              let sourceEpoch = Int64(epochText), sourceEpoch > 0,
              let sourceDigest = metadata["attached_source_sha256"],
              let selectionIdentifier = metadata["attached_selection_id"],
              let storedSelectionSourceIdentifier =
                metadata["attached_selection_source"],
              let recordLocator = metadata["attached_record_locator"],
              let schemaDigest = metadata["attached_schema_sha256"],
              let generationIdentifier = metadata["attached_generation_id"],
              let generationReceiptHash =
                metadata["attached_generation_receipt_sha256"],
              let pageReceiptHash =
                metadata["connector_page_receipt_sha256"],
              let identityStrategy = metadata["attached_identity_strategy"],
              let truncatedText = metadata["attached_truncated"],
              let wasTruncated = Bool(truncatedText),
              validIdentifier(sourceIdentifier),
              validIdentifier(sourceKind),
              validDigest(sourceDigest),
              validIdentifier(selectionIdentifier),
              validIdentifier(record.providerRecordID),
              validLocator(recordLocator),
              validDigest(schemaDigest),
              validIdentifier(generationIdentifier),
              validDigest(generationReceiptHash),
              validDigest(pageReceiptHash),
              validIdentifier(identityStrategy)
        else { return nil }
        let selectionSourceIdentifier =
            sourceKind == AttachedDataSourceKind.json.rawValue
                && storedSelectionSourceIdentifier.isEmpty
                ? "$" : storedSelectionSourceIdentifier
        guard validLocator(selectionSourceIdentifier) else { return nil }
        return .init(
            sourceIdentifier: sourceIdentifier,
            sourceKind: sourceKind,
            sourceEpoch: sourceEpoch,
            sourceDigest: sourceDigest,
            selectionIdentifier: selectionIdentifier,
            selectionSourceIdentifier: selectionSourceIdentifier,
            stableRecordIdentifier: record.providerRecordID,
            recordLocator: recordLocator,
            schemaDigest: schemaDigest,
            generationIdentifier: generationIdentifier,
            generationReceiptHash: generationReceiptHash,
            pageReceiptHash: pageReceiptHash,
            identityStrategy: identityStrategy,
            wasTruncated: wasTruncated
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.lengthOfBytes(using: .utf8) <= 512
            && !value.unicodeScalars.contains(where: unsafeScalar)
    }

    private static func validLocator(_ value: String) -> Bool {
        !value.isEmpty
            && value.lengthOfBytes(using: .utf8) <= 2_048
            && !value.unicodeScalars.contains(where: unsafeScalar)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value)
                || (65 ... 70).contains($0.value)
                || (97 ... 102).contains($0.value)
        }
    }

    private static func unsafeScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.illegalCharacters.contains(scalar)
            || [
                0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                0x2066, 0x2067, 0x2068, 0x2069,
            ].contains(scalar.value)
    }
}

struct VaultSearchResponse: Codable, Hashable, Sendable {
    let mode: VaultSearchMode
    let results: [VaultSearchResult]
    let queryTokenCount: Int
    let wasTruncated: Bool
}

struct VaultRetentionPolicy: Codable, Hashable, Sendable {
    let accountID: String?
    let containerID: String?
    let recordAgeDays: Int
    let maximumRecordsPerContainer: Int
    let tombstoneAgeDays: Int

    init(
        accountID: String? = nil,
        containerID: String? = nil,
        recordAgeDays: Int,
        maximumRecordsPerContainer: Int,
        tombstoneAgeDays: Int
    ) {
        self.accountID = accountID
        self.containerID = containerID
        self.recordAgeDays = recordAgeDays
        self.maximumRecordsPerContainer = maximumRecordsPerContainer
        self.tombstoneAgeDays = tombstoneAgeDays
    }
}

struct VaultRetentionResult: Codable, Hashable, Sendable {
    let recordsRemovedByAge: Int
    let recordsRemovedByLimit: Int
    let tombstonesRemoved: Int
    let wasBounded: Bool
}

struct VaultDeletionSummary: Codable, Hashable, Sendable {
    let accountsDeleted: Int
    let containersDeleted: Int
    let recordsDeleted: Int
    let revisionsDeleted: Int
    let tombstonesDeleted: Int
}

struct VaultStorageSummary: Codable, Hashable, Sendable {
    let accountCount: Int
    let containerCount: Int
    let recordCount: Int
    let revisionCount: Int
    let tombstoneCount: Int
    let databaseBytes: Int64
    let walBytes: Int64
    let sharedMemoryBytes: Int64
    let totalArchiveBytes: Int64
    let freeBytes: Int64
    let oldestItemAt: Date?
    let newestItemAt: Date?
    let accountContributions: [VaultStorageContribution]
}

struct VaultStorageContribution: Codable, Hashable, Sendable {
    let provider: String
    let accountID: String
    let itemCount: Int
    let revisionCount: Int
    let estimatedBytes: Int64
    let oldestItemAt: Date?
    let newestItemAt: Date?
}

struct VaultIntegrityReport: Codable, Hashable, Sendable {
    let sqliteIntegrityOK: Bool
    let foreignKeysOK: Bool
    let ftsAvailable: Bool
    let ftsIntegrityOK: Bool
    let recoveryClassification: VaultRecoveryClassification
}

struct VaultDatabaseDiagnostics: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let journalMode: String
    let foreignKeysEnabled: Bool
    let synchronousLevel: Int
    let secureDeleteEnabled: Bool
    let busyTimeoutMilliseconds: Int
    let ftsAvailable: Bool
    let requiredTables: Set<String>
}

struct VaultExportResult: Codable, Hashable, Sendable {
    let url: URL
    let lineCount: Int
    let accountCount: Int
    let containerCount: Int
    let recordCount: Int
    let revisionCount: Int
    let tombstoneCount: Int
    let payloadChecksum: String
    let fileChecksum: String
    let byteCount: Int
}

struct VaultExportVerification: Codable, Hashable, Sendable {
    let isValid: Bool
    let lineCount: Int
    let payloadChecksum: String?
    let fileChecksum: String
    let reasonCode: String
}

struct VaultExportScope: Codable, Hashable, Sendable {
    let accountID: String?
    let startDate: Date?
    let endDate: Date?

    static let all = VaultExportScope(accountID: nil, startDate: nil, endDate: nil)

    init(accountID: String? = nil, startDate: Date? = nil, endDate: Date? = nil) {
        self.accountID = accountID
        self.startDate = startDate
        self.endDate = endDate
    }
}
