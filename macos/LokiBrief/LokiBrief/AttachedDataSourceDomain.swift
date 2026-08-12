import CryptoKit
import Foundation

enum AttachedDataSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sqlite
    case json

    var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        case .json: "JSON"
        }
    }
}

enum AttachedDataSourceMode: String, Codable, CaseIterable, Hashable, Sendable {
    case linkedReadOnly = "linked_read_only"
    case importedSnapshot = "imported_snapshot"
}

enum AttachedDataSourceState: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case disconnected
    case selecting
    case previewing
    case ready
    case importing
    case refreshing
    case connected
    case degraded
    case stale
    case failed
    case disabled

    var isOperationInProgress: Bool {
        switch self {
        case .selecting, .previewing, .importing, .refreshing:
            true
        default:
            false
        }
    }
}

enum AttachedDataSourceFailureCode: String, Codable, CaseIterable, Error, Hashable, Sendable {
    case invalidIdentifier = "attached_data_invalid_identifier"
    case invalidDisplayName = "attached_data_invalid_display_name"
    case invalidOriginalFilename = "attached_data_invalid_original_filename"
    case invalidLocationDescriptor = "attached_data_invalid_location_descriptor"
    case invalidFileIdentity = "attached_data_invalid_file_identity"
    case invalidDigest = "attached_data_invalid_digest"
    case invalidSelection = "attached_data_invalid_selection"
    case duplicateSelection = "attached_data_duplicate_selection"
    case invalidPreview = "attached_data_invalid_preview"
    case invalidBudgets = "attached_data_invalid_budgets"
    case invalidImportPlan = "attached_data_invalid_import_plan"
    case invalidReceipt = "attached_data_invalid_receipt"
    case receiptConflict = "attached_data_receipt_conflict"
    case invalidCounts = "attached_data_invalid_counts"
    case invalidEpoch = "attached_data_invalid_epoch"
    case invalidDateRange = "attached_data_invalid_date_range"
    case invalidAccessState = "attached_data_invalid_access_state"
    case bookmarkRequired = "attached_data_bookmark_required"
    case bookmarkTooLarge = "attached_data_bookmark_too_large"
    case staleBookmark = "attached_data_stale_bookmark"
    case reauthorizationRequired = "attached_data_reauthorization_required"
    case sourceIdentityChanged = "attached_data_source_identity_changed"
    case sourceUnavailable = "attached_data_source_unavailable"
    case sourceBusy = "attached_data_source_busy"
    case unsupportedSource = "attached_data_source_unsupported"
    case encryptedSourceUnsupported = "attached_data_encrypted_source_unsupported"
    case malformedSource = "attached_data_source_malformed"
    case readOnlyAuthorityRequired = "attached_data_read_only_authority_required"
    case securityScopeFailed = "attached_data_security_scope_failed"
    case coherentSnapshotUnavailable = "attached_data_coherent_snapshot_unavailable"
    case budgetExceeded = "attached_data_budget_exceeded"
    case operationCancelled = "attached_data_operation_cancelled"
    case operationInterruptedByRestart = "attached_data_operation_interrupted_by_restart"
    case atomicPublicationFailed = "attached_data_atomic_publication_failed"
    case persistenceCorrupt = "attached_data_persistence_corrupt"
}

extension AttachedDataSourceFailureCode: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The attached source identifier is invalid."
        case .invalidDisplayName: "The attached source display name is invalid."
        case .invalidOriginalFilename: "The attached source filename is invalid."
        case .invalidLocationDescriptor: "The attached source location descriptor is not privacy-safe."
        case .invalidFileIdentity: "The attached source file identity is invalid."
        case .invalidDigest: "The attached source digest is invalid."
        case .invalidSelection, .duplicateSelection: "The attached source selection is invalid."
        case .invalidPreview: "The attached source preview is invalid."
        case .invalidBudgets: "The attached source limits are invalid."
        case .invalidImportPlan: "The attached source import plan is invalid."
        case .invalidReceipt, .receiptConflict: "The attached source receipt is invalid."
        case .invalidCounts: "The attached source counts are invalid."
        case .invalidEpoch: "The attached source epoch is invalid."
        case .invalidDateRange: "The attached source timestamps are invalid."
        case .invalidAccessState: "The attached source access state is inconsistent."
        case .bookmarkRequired: "Read-only access to the attached source must be authorized."
        case .bookmarkTooLarge: "The attached source authorization record exceeds its limit."
        case .staleBookmark: "Access to the attached source is stale."
        case .reauthorizationRequired: "The attached source must be selected again."
        case .sourceIdentityChanged: "The selected file no longer matches the admitted source."
        case .sourceUnavailable: "The attached source is unavailable."
        case .sourceBusy: "The attached source is busy."
        case .unsupportedSource: "The selected file is not a supported attached source."
        case .encryptedSourceUnsupported: "Encrypted attached databases are not supported."
        case .malformedSource: "The attached source is malformed or corrupt."
        case .readOnlyAuthorityRequired: "The attached source cannot be opened with read-only authority."
        case .securityScopeFailed: "Read-only access to the attached source could not be established."
        case .coherentSnapshotUnavailable: "A coherent read-only snapshot could not be created."
        case .budgetExceeded: "The attached source exceeded an approved limit."
        case .operationCancelled: "The attached source operation was cancelled."
        case .operationInterruptedByRestart: "The attached source operation was interrupted and must be resumed explicitly."
        case .atomicPublicationFailed: "The attached source generation was not published."
        case .persistenceCorrupt: "The attached source record could not be read safely."
        }
    }
}

enum AttachedDataSourceSelectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sqliteTable = "sqlite_table"
    case sqliteView = "sqlite_view"
    case jsonRoot = "json_root"
}

enum AttachedDataRecordIdentityStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case declaredPrimaryKey = "declared_primary_key"
    case compositePrimaryKey = "composite_primary_key"
    case rowID = "rowid"
    case withoutRowIDPrimaryKey = "without_rowid_primary_key"
    case canonicalRecordDigest = "canonical_record_digest"
    case explicitJSONID = "explicit_json_id"
    case recognizedJSONID = "recognized_json_id"
    case jsonPointerAndDigest = "json_pointer_and_digest"

    var requiresIdentityFields: Bool {
        switch self {
        case .declaredPrimaryKey, .compositePrimaryKey,
             .withoutRowIDPrimaryKey, .explicitJSONID, .recognizedJSONID:
            true
        case .rowID, .canonicalRecordDigest, .jsonPointerAndDigest:
            false
        }
    }
}

enum AttachedDataBookmarkState: String, Codable, CaseIterable, Hashable, Sendable {
    case notRetained = "not_retained"
    case retained
    case stale
    case reauthorizationRequired = "reauthorization_required"
    case detached
}

enum AttachedDataCancellationState: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case requested
    case completed
    case interrupted
}

enum AttachedDataLocalDataRetentionState: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case retained
    case removalPending = "removal_pending"
    case removed
}

enum AttachedDataSourceReceiptOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case preview
    case importSnapshot = "import_snapshot"
    case refresh
    case reauthorize
    case detach
    case removeLocalData = "remove_local_data"
}

enum AttachedDataSourceReceiptOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case succeeded
    case degraded
    case failed
    case cancelled
}

enum AttachedDataPreviewValueKind: String, CaseIterable, Hashable, Sendable {
    case null
    case boolean
    case integer
    case real
    case text
    case blobMetadata = "blob_metadata"
    case object
    case array
}

enum AttachedDataSourceLimits {
    static let maximumIdentifierBytes = 256
    static let maximumDisplayNameBytes = 200
    static let maximumFilenameBytes = 255
    static let maximumLocationDescriptorBytes = 256
    static let maximumSourceLabelBytes = 2_048
    static let maximumFieldNameBytes = 512
    static let maximumSelections = 256
    static let maximumFieldsPerSelection = 512
    static let maximumPreviewRecords = 25
    static let maximumPreviewValueBytes = 4_096
    static let maximumWarnings = 32
    static let maximumImportedContainerIdentifiers = 256
    static let maximumReasonCodeBytes = 160
    static let maximumBookmarkBytes = 1_048_576
    static let maximumReceiptsPerSource = 100
}

enum AttachedDataSourceValidation {
    static func identifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.lengthOfBytes(using: .utf8) <= AttachedDataSourceLimits.maximumIdentifierBytes
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    static func boundedText(_ value: String, maximumBytes: Int, allowEmpty: Bool = false) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !trimmed.isEmpty),
              value.lengthOfBytes(using: .utf8) <= maximumBytes
        else { return false }
        return !value.unicodeScalars.contains { scalar in
            scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    static func filename(_ value: String) -> Bool {
        boundedText(value, maximumBytes: AttachedDataSourceLimits.maximumFilenameBytes)
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    static func privacySafeLocationDescriptor(_ value: String) -> Bool {
        guard boundedText(
            value,
            maximumBytes: AttachedDataSourceLimits.maximumLocationDescriptorBytes
        ) else { return false }
        let lowered = value.lowercased()
        return !value.hasPrefix("/")
            && !value.hasPrefix("~")
            && !value.contains("/")
            && !value.contains("\\")
            && !lowered.hasPrefix("file:")
    }

    static func sourceLabel(_ value: String, allowEmpty: Bool = false) -> Bool {
        boundedText(
            value,
            maximumBytes: AttachedDataSourceLimits.maximumSourceLabelBytes,
            allowEmpty: allowEmpty
        )
    }

    static func fieldName(_ value: String) -> Bool {
        boundedText(value, maximumBytes: AttachedDataSourceLimits.maximumFieldNameBytes)
    }

    static func reasonCode(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.lengthOfBytes(using: .utf8) <= AttachedDataSourceLimits.maximumReasonCodeBytes
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    static func finite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    static func unique<T: Hashable>(_ values: [T]) -> Bool {
        Set(values).count == values.count
    }
}

struct AttachedDataFileIdentity: Codable, Hashable, Sendable {
    let deviceID: Int64
    let inode: UInt64
    let fileType: UInt32
    let linkCount: UInt64
    let fileSize: Int64
    let modificationNanoseconds: Int64

    init(
        deviceID: Int64,
        inode: UInt64,
        fileType: UInt32,
        linkCount: UInt64,
        fileSize: Int64,
        modificationNanoseconds: Int64
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.fileType = fileType
        self.linkCount = linkCount
        self.fileSize = fileSize
        self.modificationNanoseconds = modificationNanoseconds
    }

    func matchesResource(_ other: Self) -> Bool {
        deviceID == other.deviceID
            && inode == other.inode
            && fileType == other.fileType
            && linkCount > 0
            && other.linkCount > 0
    }

    func matchesSnapshot(_ other: Self) -> Bool {
        matchesResource(other)
            && linkCount == other.linkCount
            && fileSize == other.fileSize
            && modificationNanoseconds == other.modificationNanoseconds
    }

    func validate() throws {
        let regularFileType: UInt32 = 0o100000
        let fileTypeMask: UInt32 = 0o170000
        guard inode > 0,
              (fileType & fileTypeMask) == regularFileType,
              linkCount > 0,
              fileSize >= 0,
              modificationNanoseconds >= 0
        else { throw AttachedDataSourceFailureCode.invalidFileIdentity }
    }
}

struct AttachedDataSourceBudgets: Codable, Hashable, Sendable {
    let maximumInputBytes: Int64
    let maximumRecords: Int
    let maximumKeysPerObject: Int?
    let maximumNestingDepth: Int?
    let maximumNodes: Int?
    let maximumStringBytes: Int?
    let maximumNumberBytes: Int?
    let maximumRecordBytes: Int?
    let maximumMaterializedBytes: Int64
    let maximumNormalizedTextBytes: Int?
    let maximumFields: Int
    let pageSize: Int?
    let executionTimeSeconds: TimeInterval?
    let cancellationCheckIntervalBytes: Int?

    static let jsonStandard = try! AttachedDataSourceBudgets(
        maximumInputBytes: 32 * 1_024 * 1_024,
        maximumRecords: 100_000,
        maximumKeysPerObject: 10_000,
        maximumNestingDepth: 64,
        maximumNodes: 1_000_000,
        maximumStringBytes: 1 * 1_024 * 1_024,
        maximumNumberBytes: 64 * 1_024,
        maximumRecordBytes: nil,
        maximumMaterializedBytes: 32 * 1_024 * 1_024,
        maximumNormalizedTextBytes: 1_500_000,
        maximumFields: 128,
        pageSize: nil,
        executionTimeSeconds: nil,
        cancellationCheckIntervalBytes: 4_096
    )

    static let sqliteStandard = try! AttachedDataSourceBudgets(
        maximumInputBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumRecords: 10_000,
        maximumKeysPerObject: nil,
        maximumNestingDepth: nil,
        maximumNodes: nil,
        maximumStringBytes: 16 * 1_024,
        maximumNumberBytes: nil,
        maximumRecordBytes: 128 * 1_024,
        maximumMaterializedBytes: 32 * 1_024 * 1_024,
        maximumNormalizedTextBytes: nil,
        maximumFields: 128,
        pageSize: 250,
        executionTimeSeconds: 15,
        cancellationCheckIntervalBytes: nil
    )

    // Kept only for source compatibility with pre-RC2 fixtures. Persisted
    // previews and plans validate against the exact source-kind standard.
    static let `default` = sqliteStandard

    static func standard(for kind: AttachedDataSourceKind) -> Self {
        switch kind {
        case .sqlite: sqliteStandard
        case .json: jsonStandard
        }
    }

    init(
        maximumInputBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumRecords: Int = 10_000,
        maximumKeysPerObject: Int? = nil,
        maximumNestingDepth: Int? = nil,
        maximumNodes: Int? = nil,
        maximumStringBytes: Int? = 16 * 1_024,
        maximumNumberBytes: Int? = nil,
        maximumRecordBytes: Int? = 128 * 1_024,
        maximumMaterializedBytes: Int64 = 32 * 1_024 * 1_024,
        maximumNormalizedTextBytes: Int? = nil,
        maximumFields: Int = 128,
        pageSize: Int? = 250,
        executionTimeSeconds: TimeInterval? = 15,
        cancellationCheckIntervalBytes: Int? = nil
    ) throws {
        self.maximumInputBytes = maximumInputBytes
        self.maximumRecords = maximumRecords
        self.maximumKeysPerObject = maximumKeysPerObject
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumNodes = maximumNodes
        self.maximumStringBytes = maximumStringBytes
        self.maximumNumberBytes = maximumNumberBytes
        self.maximumRecordBytes = maximumRecordBytes
        self.maximumMaterializedBytes = maximumMaterializedBytes
        self.maximumNormalizedTextBytes = maximumNormalizedTextBytes
        self.maximumFields = maximumFields
        self.pageSize = pageSize
        self.executionTimeSeconds = executionTimeSeconds
        self.cancellationCheckIntervalBytes = cancellationCheckIntervalBytes
        try validate()
    }

    func validate() throws {
        guard (1...4_294_967_296).contains(maximumInputBytes),
              (1...1_000_000).contains(maximumRecords),
              maximumKeysPerObject.map({ (1...10_000).contains($0) }) ?? true,
              maximumNestingDepth.map({ (1...128).contains($0) }) ?? true,
              maximumNodes.map({ (1...10_000_000).contains($0) }) ?? true,
              maximumStringBytes.map({ (1...2_097_152).contains($0) }) ?? true,
              maximumNumberBytes.map({ (1...2_097_152).contains($0) }) ?? true,
              maximumRecordBytes.map({ (1...4_194_304).contains($0) }) ?? true,
              maximumRecordBytes.map({ recordBytes in
                  maximumStringBytes.map { recordBytes >= $0 } ?? true
              }) ?? true,
              (1...1_073_741_824).contains(maximumMaterializedBytes),
              maximumMaterializedBytes <= maximumInputBytes,
              maximumNormalizedTextBytes.map({ (1...4_194_304).contains($0) }) ?? true,
              (1...512).contains(maximumFields),
              pageSize.map({ (1...1_000).contains($0) }) ?? true,
              executionTimeSeconds.map({
                  $0.isFinite && (0.1...300).contains($0)
              }) ?? true,
              cancellationCheckIntervalBytes.map({
                  (1...1_048_576).contains($0)
              }) ?? true
        else { throw AttachedDataSourceFailureCode.invalidBudgets }
    }
}

struct AttachedDataSourceSelection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: AttachedDataSourceSelectionKind
    let sourceIdentifier: String
    let displayName: String
    let selectedFields: [String]
    let searchableFields: [String]
    let identityFields: [String]
    let includedBlobBodyFields: [String]
    let recordIdentityStrategy: AttachedDataRecordIdentityStrategy
    let schemaDigest: String
    let estimatedRecordCount: Int?
    let estimatedBytes: Int64?
    let allowsRecordTruncation: Bool

    init(
        id: String,
        kind: AttachedDataSourceSelectionKind,
        sourceIdentifier: String,
        displayName: String,
        selectedFields: [String],
        searchableFields: [String],
        identityFields: [String] = [],
        includedBlobBodyFields: [String] = [],
        recordIdentityStrategy: AttachedDataRecordIdentityStrategy,
        schemaDigest: String,
        estimatedRecordCount: Int? = nil,
        estimatedBytes: Int64? = nil,
        allowsRecordTruncation: Bool = false
    ) throws {
        self.id = id
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.displayName = displayName
        self.selectedFields = selectedFields
        self.searchableFields = searchableFields
        self.identityFields = identityFields
        self.includedBlobBodyFields = includedBlobBodyFields
        self.recordIdentityStrategy = recordIdentityStrategy
        self.schemaDigest = schemaDigest
        self.estimatedRecordCount = estimatedRecordCount
        self.estimatedBytes = estimatedBytes
        self.allowsRecordTruncation = allowsRecordTruncation
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sourceIdentifier
        case displayName
        case selectedFields
        case searchableFields
        case identityFields
        case includedBlobBodyFields
        case recordIdentityStrategy
        case schemaDigest
        case estimatedRecordCount
        case estimatedBytes
        case allowsRecordTruncation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(AttachedDataSourceSelectionKind.self, forKey: .kind),
            sourceIdentifier: values.decode(String.self, forKey: .sourceIdentifier),
            displayName: values.decode(String.self, forKey: .displayName),
            selectedFields: values.decode([String].self, forKey: .selectedFields),
            searchableFields: values.decode([String].self, forKey: .searchableFields),
            identityFields: values.decode([String].self, forKey: .identityFields),
            includedBlobBodyFields: values.decode(
                [String].self,
                forKey: .includedBlobBodyFields
            ),
            recordIdentityStrategy: values.decode(
                AttachedDataRecordIdentityStrategy.self,
                forKey: .recordIdentityStrategy
            ),
            schemaDigest: values.decode(String.self, forKey: .schemaDigest),
            estimatedRecordCount: values.decodeIfPresent(
                Int.self,
                forKey: .estimatedRecordCount
            ),
            estimatedBytes: values.decodeIfPresent(Int64.self, forKey: .estimatedBytes),
            allowsRecordTruncation: try values.decodeIfPresent(
                Bool.self,
                forKey: .allowsRecordTruncation
            ) ?? false
        )
    }

    func validate() throws {
        let sourceAllowsEmpty = kind == .jsonRoot
        let fieldsMayBeEmpty = kind == .jsonRoot && estimatedRecordCount == 0
        guard AttachedDataSourceValidation.identifier(id),
              AttachedDataSourceValidation.sourceLabel(
                sourceIdentifier,
                allowEmpty: sourceAllowsEmpty
              ),
              AttachedDataSourceValidation.boundedText(
                displayName,
                maximumBytes: AttachedDataSourceLimits.maximumDisplayNameBytes
              ),
              !selectedFields.isEmpty || fieldsMayBeEmpty,
              selectedFields.count <= AttachedDataSourceLimits.maximumFieldsPerSelection,
              selectedFields.allSatisfy(AttachedDataSourceValidation.fieldName),
              searchableFields.allSatisfy(AttachedDataSourceValidation.fieldName),
              identityFields.allSatisfy(AttachedDataSourceValidation.fieldName),
              includedBlobBodyFields.allSatisfy(AttachedDataSourceValidation.fieldName),
              AttachedDataSourceValidation.unique(selectedFields),
              AttachedDataSourceValidation.unique(searchableFields),
              AttachedDataSourceValidation.unique(identityFields),
              AttachedDataSourceValidation.unique(includedBlobBodyFields),
              Set(searchableFields).isSubset(of: Set(selectedFields)),
              Set(identityFields).isSubset(of: Set(selectedFields)),
              Set(includedBlobBodyFields).isSubset(of: Set(selectedFields)),
              !recordIdentityStrategy.requiresIdentityFields || !identityFields.isEmpty,
              AttachedDataSourceValidation.digest(schemaDigest),
              estimatedRecordCount.map({ $0 >= 0 }) ?? true,
              estimatedBytes.map({ $0 >= 0 }) ?? true
        else { throw AttachedDataSourceFailureCode.invalidSelection }
    }
}

struct AttachedDataPreviewField: Hashable, Sendable {
    let name: String
    let kind: AttachedDataPreviewValueKind
    let displayValue: String
    let isTruncated: Bool

    init(
        name: String,
        kind: AttachedDataPreviewValueKind,
        displayValue: String,
        isTruncated: Bool = false
    ) throws {
        guard AttachedDataSourceValidation.fieldName(name),
              AttachedDataSourceValidation.boundedText(
                displayValue,
                maximumBytes: AttachedDataSourceLimits.maximumPreviewValueBytes,
                allowEmpty: true
              )
        else { throw AttachedDataSourceFailureCode.invalidPreview }
        self.name = name
        self.kind = kind
        self.displayValue = displayValue
        self.isTruncated = isTruncated
    }
}

struct AttachedDataPreviewRecord: Hashable, Identifiable, Sendable {
    let id: String
    let fields: [AttachedDataPreviewField]

    init(id: String, fields: [AttachedDataPreviewField]) throws {
        guard AttachedDataSourceValidation.identifier(id),
              fields.count <= AttachedDataSourceLimits.maximumFieldsPerSelection,
              AttachedDataSourceValidation.unique(fields.map(\.name))
        else { throw AttachedDataSourceFailureCode.invalidPreview }
        self.id = id
        self.fields = fields
    }
}

struct AttachedDataSourcePreview: Hashable, Identifiable, Sendable {
    let id: String
    let sourceIdentifier: String
    let kind: AttachedDataSourceKind
    let originalFilename: String
    let privacySafeLocationDescriptor: String
    let fileIdentity: AttachedDataFileIdentity
    let sourceDigest: String
    let shapeDigest: String
    let candidateSelections: [AttachedDataSourceSelection]
    let sampleRecords: [AttachedDataPreviewRecord]
    let estimatedRecordCount: Int?
    let estimatedBytes: Int64?
    let warnings: [AttachedDataSourceFailureCode]
    let appliedBudgets: AttachedDataSourceBudgets
    let detectedAt: Date

    init(
        id: String,
        sourceIdentifier: String,
        kind: AttachedDataSourceKind,
        originalFilename: String,
        privacySafeLocationDescriptor: String,
        fileIdentity: AttachedDataFileIdentity,
        sourceDigest: String,
        shapeDigest: String,
        candidateSelections: [AttachedDataSourceSelection],
        sampleRecords: [AttachedDataPreviewRecord] = [],
        estimatedRecordCount: Int? = nil,
        estimatedBytes: Int64? = nil,
        warnings: [AttachedDataSourceFailureCode] = [],
        appliedBudgets: AttachedDataSourceBudgets? = nil,
        detectedAt: Date = .now
    ) throws {
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.kind = kind
        self.originalFilename = originalFilename
        self.privacySafeLocationDescriptor = privacySafeLocationDescriptor
        self.fileIdentity = fileIdentity
        self.sourceDigest = sourceDigest
        self.shapeDigest = shapeDigest
        self.candidateSelections = candidateSelections
        self.sampleRecords = sampleRecords
        self.estimatedRecordCount = estimatedRecordCount
        self.estimatedBytes = estimatedBytes
        self.warnings = Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }
        self.appliedBudgets = appliedBudgets ?? .standard(for: kind)
        self.detectedAt = detectedAt
        try validate()
    }

    func validate() throws {
        try fileIdentity.validate()
        try appliedBudgets.validate()
        try candidateSelections.forEach { try $0.validate() }
        guard AttachedDataSourceValidation.identifier(id),
              AttachedDataSourceValidation.identifier(sourceIdentifier),
              AttachedDataSourceValidation.filename(originalFilename),
              AttachedDataSourceValidation.privacySafeLocationDescriptor(
                privacySafeLocationDescriptor
              ),
              AttachedDataSourceValidation.digest(sourceDigest),
              AttachedDataSourceValidation.digest(shapeDigest),
              !candidateSelections.isEmpty,
              candidateSelections.count <= AttachedDataSourceLimits.maximumSelections,
              AttachedDataSourceValidation.unique(candidateSelections.map(\.id)),
              sampleRecords.count <= AttachedDataSourceLimits.maximumPreviewRecords,
              estimatedRecordCount.map({ $0 >= 0 }) ?? true,
              estimatedBytes.map({ $0 >= 0 }) ?? true,
              warnings.count <= AttachedDataSourceLimits.maximumWarnings,
              appliedBudgets == .standard(for: kind),
              AttachedDataSourceValidation.finite(detectedAt)
        else { throw AttachedDataSourceFailureCode.invalidPreview }
    }
}

struct AttachedDataSourceAccess: Codable, Hashable, Sendable {
    let bookmarkState: AttachedDataBookmarkState
    let continuingAccessRetained: Bool
    let lastAuthorizedAt: Date?
    let lastResolvedAt: Date?

    init(
        bookmarkState: AttachedDataBookmarkState,
        continuingAccessRetained: Bool,
        lastAuthorizedAt: Date? = nil,
        lastResolvedAt: Date? = nil
    ) throws {
        self.bookmarkState = bookmarkState
        self.continuingAccessRetained = continuingAccessRetained
        self.lastAuthorizedAt = lastAuthorizedAt
        self.lastResolvedAt = lastResolvedAt
        try validate()
    }

    static let notRetained = try! AttachedDataSourceAccess(
        bookmarkState: .notRetained,
        continuingAccessRetained: false
    )

    func validate() throws {
        let retainedState = bookmarkState == .retained
            || bookmarkState == .stale
            || bookmarkState == .reauthorizationRequired
        guard retainedState == continuingAccessRetained,
              lastAuthorizedAt.map(AttachedDataSourceValidation.finite) ?? true,
              lastResolvedAt.map(AttachedDataSourceValidation.finite) ?? true
        else { throw AttachedDataSourceFailureCode.invalidAccessState }
    }

    func detached(at date: Date = .now) throws -> Self {
        try .init(
            bookmarkState: .detached,
            continuingAccessRetained: false,
            lastAuthorizedAt: lastAuthorizedAt,
            lastResolvedAt: date
        )
    }
}

private struct AttachedDataDigestMaterial {
    private var bytes = Data()

    init(domain: String) {
        append("domain", domain)
    }

    mutating func append(_ label: String, _ value: String) {
        appendFrame(label)
        appendFrame(value)
    }

    mutating func append(_ label: String, _ value: Bool) {
        append(label, value ? "true" : "false")
    }

    mutating func append<T: BinaryInteger>(_ label: String, _ value: T) {
        append(label, String(value))
    }

    mutating func append(_ label: String, values: [String]) {
        append("\(label).count", values.count)
        for (index, value) in values.enumerated() {
            append("\(label).\(index)", value)
        }
    }

    mutating func appendOptional(_ label: String, _ value: String?) {
        append("\(label).present", value != nil)
        if let value { append("\(label).value", value) }
    }

    func sha256() -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendFrame(_ value: String) {
        let encoded = Data(value.utf8)
        bytes.append(contentsOf: String(encoded.count).utf8)
        bytes.append(58)
        bytes.append(encoded)
    }
}

struct AttachedDataImportPlan: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sourceIdentifier: String
    let sourceKind: AttachedDataSourceKind
    let mode: AttachedDataSourceMode
    let fileIdentity: AttachedDataFileIdentity
    let sourceDigest: String
    let shapeDigest: String
    let selections: [AttachedDataSourceSelection]
    let selectionDigest: String
    let budgets: AttachedDataSourceBudgets
    let expectedRecordCount: Int?
    let expectedMaterializedBytes: Int64?
    let normalizationVersion: Int
    let provenanceVersion: Int
    let generationIdentifier: String
    let priorGenerationIdentifier: String?
    let priorSourceDigest: String?
    let priorShapeDigest: String?
    let createdAt: Date
    let planDigest: String

    init(
        id: String,
        sourceIdentifier: String,
        sourceKind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        fileIdentity: AttachedDataFileIdentity,
        sourceDigest: String,
        shapeDigest: String,
        selections: [AttachedDataSourceSelection],
        selectionDigest: String? = nil,
        budgets: AttachedDataSourceBudgets? = nil,
        expectedRecordCount: Int? = nil,
        expectedMaterializedBytes: Int64? = nil,
        normalizationVersion: Int,
        provenanceVersion: Int,
        generationIdentifier: String,
        priorGenerationIdentifier: String? = nil,
        priorSourceDigest: String? = nil,
        priorShapeDigest: String? = nil,
        createdAt: Date = .now,
        planDigest: String? = nil
    ) throws {
        let frozenSelectionDigest = Self.frozenSelectionDigest(for: selections)
        let resolvedSelectionDigest = selectionDigest ?? frozenSelectionDigest
        let resolvedBudgets = budgets ?? .standard(for: sourceKind)
        let frozenPlanDigest = Self.frozenPlanDigest(
            id: id,
            sourceIdentifier: sourceIdentifier,
            sourceKind: sourceKind,
            mode: mode,
            fileIdentity: fileIdentity,
            sourceDigest: sourceDigest,
            shapeDigest: shapeDigest,
            selectionDigest: resolvedSelectionDigest,
            budgets: resolvedBudgets,
            expectedRecordCount: expectedRecordCount,
            expectedMaterializedBytes: expectedMaterializedBytes,
            normalizationVersion: normalizationVersion,
            provenanceVersion: provenanceVersion,
            generationIdentifier: generationIdentifier,
            priorGenerationIdentifier: priorGenerationIdentifier,
            priorSourceDigest: priorSourceDigest,
            priorShapeDigest: priorShapeDigest,
            createdAt: createdAt
        )
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.sourceKind = sourceKind
        self.mode = mode
        self.fileIdentity = fileIdentity
        self.sourceDigest = sourceDigest
        self.shapeDigest = shapeDigest
        self.selections = selections
        self.selectionDigest = resolvedSelectionDigest
        self.budgets = resolvedBudgets
        self.expectedRecordCount = expectedRecordCount
        self.expectedMaterializedBytes = expectedMaterializedBytes
        self.normalizationVersion = normalizationVersion
        self.provenanceVersion = provenanceVersion
        self.generationIdentifier = generationIdentifier
        self.priorGenerationIdentifier = priorGenerationIdentifier
        self.priorSourceDigest = priorSourceDigest
        self.priorShapeDigest = priorShapeDigest
        self.createdAt = createdAt
        self.planDigest = planDigest ?? frozenPlanDigest
        try validate()
    }

    static func frozenSelectionDigest(
        for selections: [AttachedDataSourceSelection]
    ) -> String {
        var material = AttachedDataDigestMaterial(
            domain: "agent-loki.attached-data.selection.v2"
        )
        material.append("selections.count", selections.count)
        for (index, selection) in selections.enumerated() {
            let prefix = "selections.\(index)"
            material.append("\(prefix).id", selection.id)
            material.append("\(prefix).kind", selection.kind.rawValue)
            material.append(
                "\(prefix).sourceIdentifier",
                selection.sourceIdentifier
            )
            material.append("\(prefix).displayName", selection.displayName)
            material.append(
                "\(prefix).selectedFields",
                values: selection.selectedFields
            )
            material.append(
                "\(prefix).searchableFields",
                values: selection.searchableFields
            )
            material.append(
                "\(prefix).identityFields",
                values: selection.identityFields
            )
            material.append(
                "\(prefix).includedBlobBodyFields",
                values: selection.includedBlobBodyFields
            )
            material.append(
                "\(prefix).recordIdentityStrategy",
                selection.recordIdentityStrategy.rawValue
            )
            material.append("\(prefix).schemaDigest", selection.schemaDigest)
            material.appendOptional(
                "\(prefix).estimatedRecordCount",
                selection.estimatedRecordCount.map(String.init)
            )
            material.appendOptional(
                "\(prefix).estimatedBytes",
                selection.estimatedBytes.map(String.init)
            )
            material.append(
                "\(prefix).allowsRecordTruncation",
                selection.allowsRecordTruncation
            )
        }
        return material.sha256()
    }

    static func frozenPlanDigest(
        id: String,
        sourceIdentifier: String,
        sourceKind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        fileIdentity: AttachedDataFileIdentity,
        sourceDigest: String,
        shapeDigest: String,
        selectionDigest: String,
        budgets: AttachedDataSourceBudgets,
        expectedRecordCount: Int?,
        expectedMaterializedBytes: Int64?,
        normalizationVersion: Int,
        provenanceVersion: Int,
        generationIdentifier: String,
        priorGenerationIdentifier: String?,
        priorSourceDigest: String?,
        priorShapeDigest: String?,
        createdAt: Date
    ) -> String {
        var material = AttachedDataDigestMaterial(
            domain: "agent-loki.attached-data.import-plan.v2"
        )
        material.append("id", id)
        material.append("sourceIdentifier", sourceIdentifier)
        material.append("sourceKind", sourceKind.rawValue)
        material.append("mode", mode.rawValue)
        material.append("fileIdentity.deviceID", fileIdentity.deviceID)
        material.append("fileIdentity.inode", fileIdentity.inode)
        material.append("fileIdentity.fileType", fileIdentity.fileType)
        material.append("fileIdentity.linkCount", fileIdentity.linkCount)
        material.append("fileIdentity.fileSize", fileIdentity.fileSize)
        material.append(
            "fileIdentity.modificationNanoseconds",
            fileIdentity.modificationNanoseconds
        )
        material.append("sourceDigest", sourceDigest)
        material.append("shapeDigest", shapeDigest)
        material.append("selectionDigest", selectionDigest)
        material.append("budgets.maximumInputBytes", budgets.maximumInputBytes)
        material.append("budgets.maximumRecords", budgets.maximumRecords)
        material.appendOptional(
            "budgets.maximumKeysPerObject",
            budgets.maximumKeysPerObject.map(String.init)
        )
        material.appendOptional(
            "budgets.maximumNestingDepth",
            budgets.maximumNestingDepth.map(String.init)
        )
        material.appendOptional(
            "budgets.maximumNodes",
            budgets.maximumNodes.map(String.init)
        )
        material.appendOptional(
            "budgets.maximumStringBytes",
            budgets.maximumStringBytes.map(String.init)
        )
        material.appendOptional(
            "budgets.maximumNumberBytes",
            budgets.maximumNumberBytes.map(String.init)
        )
        material.appendOptional(
            "budgets.maximumRecordBytes",
            budgets.maximumRecordBytes.map(String.init)
        )
        material.append(
            "budgets.maximumMaterializedBytes",
            budgets.maximumMaterializedBytes
        )
        material.appendOptional(
            "budgets.maximumNormalizedTextBytes",
            budgets.maximumNormalizedTextBytes.map(String.init)
        )
        material.append("budgets.maximumFields", budgets.maximumFields)
        material.appendOptional(
            "budgets.pageSize",
            budgets.pageSize.map(String.init)
        )
        material.appendOptional(
            "budgets.executionTimeSeconds",
            budgets.executionTimeSeconds.map {
                String($0.bitPattern, radix: 16)
            }
        )
        material.appendOptional(
            "budgets.cancellationCheckIntervalBytes",
            budgets.cancellationCheckIntervalBytes.map(String.init)
        )
        material.appendOptional(
            "expectedRecordCount",
            expectedRecordCount.map(String.init)
        )
        material.appendOptional(
            "expectedMaterializedBytes",
            expectedMaterializedBytes.map(String.init)
        )
        material.append("normalizationVersion", normalizationVersion)
        material.append("provenanceVersion", provenanceVersion)
        material.append("generationIdentifier", generationIdentifier)
        material.appendOptional(
            "priorGenerationIdentifier",
            priorGenerationIdentifier
        )
        // Preserve validation of legacy frozen plans whose digest predates
        // durable retained-generation authority fields.
        if priorSourceDigest != nil || priorShapeDigest != nil {
            material.appendOptional("priorSourceDigest", priorSourceDigest)
            material.appendOptional("priorShapeDigest", priorShapeDigest)
        }
        material.append(
            "createdAt",
            String(createdAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        )
        return material.sha256()
    }

    func validate() throws {
        try fileIdentity.validate()
        try budgets.validate()
        try selections.forEach { try $0.validate() }
        guard AttachedDataSourceValidation.identifier(id),
              AttachedDataSourceValidation.identifier(sourceIdentifier),
              AttachedDataSourceValidation.digest(sourceDigest),
              AttachedDataSourceValidation.digest(shapeDigest),
              !selections.isEmpty,
              selections.count <= AttachedDataSourceLimits.maximumSelections,
              AttachedDataSourceValidation.unique(selections.map(\.id)),
              AttachedDataSourceValidation.digest(selectionDigest),
              selectionDigest == Self.frozenSelectionDigest(for: selections),
              budgets == .standard(for: sourceKind),
              expectedRecordCount.map({ $0 >= 0 }) ?? true,
              expectedMaterializedBytes.map({ $0 >= 0 }) ?? true,
              normalizationVersion > 0,
              provenanceVersion > 0,
              AttachedDataSourceValidation.identifier(generationIdentifier),
              priorGenerationIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              priorGenerationIdentifier != generationIdentifier,
              priorSourceDigest.map(AttachedDataSourceValidation.digest) ?? true,
              priorShapeDigest.map(AttachedDataSourceValidation.digest) ?? true,
              (priorSourceDigest == nil) == (priorShapeDigest == nil),
              priorGenerationIdentifier != nil
                || (priorSourceDigest == nil && priorShapeDigest == nil),
              AttachedDataSourceValidation.finite(createdAt),
              AttachedDataSourceValidation.digest(planDigest),
              planDigest == Self.frozenPlanDigest(
                  id: id,
                  sourceIdentifier: sourceIdentifier,
                  sourceKind: sourceKind,
                  mode: mode,
                  fileIdentity: fileIdentity,
                  sourceDigest: sourceDigest,
                  shapeDigest: shapeDigest,
                  selectionDigest: selectionDigest,
                  budgets: budgets,
                  expectedRecordCount: expectedRecordCount,
                  expectedMaterializedBytes: expectedMaterializedBytes,
                  normalizationVersion: normalizationVersion,
                  provenanceVersion: provenanceVersion,
                  generationIdentifier: generationIdentifier,
                  priorGenerationIdentifier: priorGenerationIdentifier,
                  priorSourceDigest: priorSourceDigest,
                  priorShapeDigest: priorShapeDigest,
                  createdAt: createdAt
              )
        else { throw AttachedDataSourceFailureCode.invalidImportPlan }
    }
}

struct AttachedDataSourceReceipt: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sourceIdentifier: String
    let sourceKind: AttachedDataSourceKind
    let mode: AttachedDataSourceMode
    let operation: AttachedDataSourceReceiptOperation
    let outcome: AttachedDataSourceReceiptOutcome
    let reasonCode: String
    let traceIdentifier: String
    let importPlanIdentifier: String?
    let generationIdentifier: String?
    let priorGenerationIdentifier: String?
    let sourceDigest: String?
    let shapeDigest: String?
    let selectionDigest: String?
    let startedAt: Date
    let completedAt: Date
    let importedItemCount: Int
    let updatedItemCount: Int
    let tombstonedItemCount: Int
    let skippedItemCount: Int
    let attachmentBlobCount: Int
    let truncationCount: Int
    let materializedByteCount: Int64
    let pageCount: Int
    let bookmarkRetained: Bool
    let priorGenerationRetained: Bool
    let atomicPublicationCommitted: Bool
    let provenanceVersion: Int
    let receiptHash: String

    init(
        id: String,
        sourceIdentifier: String,
        sourceKind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        operation: AttachedDataSourceReceiptOperation,
        outcome: AttachedDataSourceReceiptOutcome,
        reasonCode: String,
        traceIdentifier: String,
        importPlanIdentifier: String? = nil,
        generationIdentifier: String? = nil,
        priorGenerationIdentifier: String? = nil,
        sourceDigest: String? = nil,
        shapeDigest: String? = nil,
        selectionDigest: String? = nil,
        startedAt: Date,
        completedAt: Date,
        importedItemCount: Int,
        updatedItemCount: Int,
        tombstonedItemCount: Int,
        skippedItemCount: Int,
        attachmentBlobCount: Int,
        truncationCount: Int,
        materializedByteCount: Int64,
        pageCount: Int,
        bookmarkRetained: Bool,
        priorGenerationRetained: Bool,
        atomicPublicationCommitted: Bool,
        provenanceVersion: Int,
        receiptHash: String
    ) throws {
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.sourceKind = sourceKind
        self.mode = mode
        self.operation = operation
        self.outcome = outcome
        self.reasonCode = reasonCode
        self.traceIdentifier = traceIdentifier
        self.importPlanIdentifier = importPlanIdentifier
        self.generationIdentifier = generationIdentifier
        self.priorGenerationIdentifier = priorGenerationIdentifier
        self.sourceDigest = sourceDigest
        self.shapeDigest = shapeDigest
        self.selectionDigest = selectionDigest
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.importedItemCount = importedItemCount
        self.updatedItemCount = updatedItemCount
        self.tombstonedItemCount = tombstonedItemCount
        self.skippedItemCount = skippedItemCount
        self.attachmentBlobCount = attachmentBlobCount
        self.truncationCount = truncationCount
        self.materializedByteCount = materializedByteCount
        self.pageCount = pageCount
        self.bookmarkRetained = bookmarkRetained
        self.priorGenerationRetained = priorGenerationRetained
        self.atomicPublicationCommitted = atomicPublicationCommitted
        self.provenanceVersion = provenanceVersion
        self.receiptHash = receiptHash
        try validate()
    }

    func validate() throws {
        let counts = [
            importedItemCount,
            updatedItemCount,
            tombstonedItemCount,
            skippedItemCount,
            attachmentBlobCount,
            truncationCount,
            pageCount,
        ]
        guard AttachedDataSourceValidation.identifier(id),
              AttachedDataSourceValidation.identifier(sourceIdentifier),
              AttachedDataSourceValidation.reasonCode(reasonCode),
              AttachedDataSourceValidation.identifier(traceIdentifier),
              importPlanIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              generationIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              priorGenerationIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              generationIdentifier == nil || generationIdentifier != priorGenerationIdentifier,
              sourceDigest.map(AttachedDataSourceValidation.digest) ?? true,
              shapeDigest.map(AttachedDataSourceValidation.digest) ?? true,
              selectionDigest.map(AttachedDataSourceValidation.digest) ?? true,
              AttachedDataSourceValidation.finite(startedAt),
              AttachedDataSourceValidation.finite(completedAt),
              completedAt >= startedAt,
              counts.allSatisfy({ $0 >= 0 }),
              materializedByteCount >= 0,
              provenanceVersion > 0,
              AttachedDataSourceValidation.digest(receiptHash)
        else { throw AttachedDataSourceFailureCode.invalidReceipt }
        if atomicPublicationCommitted {
            guard outcome == .succeeded,
                  generationIdentifier != nil,
                  sourceDigest != nil,
                  selectionDigest != nil
            else { throw AttachedDataSourceFailureCode.invalidReceipt }
        }
    }

    var privacySafeDiagnosticFields: [String: String] {
        [
            "source_id": sourceIdentifier,
            "source_kind": sourceKind.rawValue,
            "mode": mode.rawValue,
            "operation": operation.rawValue,
            "outcome": outcome.rawValue,
            "reason_code": reasonCode,
            "imported_count": String(importedItemCount),
            "updated_count": String(updatedItemCount),
            "tombstoned_count": String(tombstonedItemCount),
            "skipped_count": String(skippedItemCount),
            "truncation_count": String(truncationCount),
            "materialized_bytes": String(materializedByteCount),
            "source_digest": sourceDigest ?? "none",
            "receipt_hash": receiptHash,
        ]
    }
}

struct AttachedDataSourceRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: AttachedDataSourceKind
    let mode: AttachedDataSourceMode
    var displayName: String
    let originalFilename: String
    let privacySafeLocationDescriptor: String
    var fileIdentity: AttachedDataFileIdentity?
    var sourceDigest: String?
    var shapeDigest: String?
    var state: AttachedDataSourceState
    var selections: [AttachedDataSourceSelection]
    var currentEpoch: Int64
    var lastSuccessfulRefreshAt: Date?
    var lastAttemptedRefreshAt: Date?
    var itemCount: Int
    var skippedItemCount: Int
    var attachmentBlobCount: Int
    var truncationCount: Int
    var importedLocalContainerIdentifiers: [String]
    let normalizationVersion: Int
    let provenanceVersion: Int
    var cancellationState: AttachedDataCancellationState
    var lastErrorReasonCode: String?
    var localDataRetentionState: AttachedDataLocalDataRetentionState
    var latestReceiptIdentifier: String?
    var currentGenerationIdentifier: String?
    var pendingGenerationIdentifier: String?
    var frozenImportPlan: AttachedDataImportPlan?
    var access: AttachedDataSourceAccess
    var refreshEnabled: Bool
    var automaticRefreshEnabled: Bool
    var localModelConsentEnabled: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        kind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        displayName: String,
        originalFilename: String,
        privacySafeLocationDescriptor: String,
        fileIdentity: AttachedDataFileIdentity? = nil,
        sourceDigest: String? = nil,
        shapeDigest: String? = nil,
        state: AttachedDataSourceState = .selecting,
        selections: [AttachedDataSourceSelection] = [],
        currentEpoch: Int64 = 0,
        lastSuccessfulRefreshAt: Date? = nil,
        lastAttemptedRefreshAt: Date? = nil,
        itemCount: Int = 0,
        skippedItemCount: Int = 0,
        attachmentBlobCount: Int = 0,
        truncationCount: Int = 0,
        importedLocalContainerIdentifiers: [String] = [],
        normalizationVersion: Int = 1,
        provenanceVersion: Int = 1,
        cancellationState: AttachedDataCancellationState = .none,
        lastErrorReasonCode: String? = nil,
        localDataRetentionState: AttachedDataLocalDataRetentionState = .none,
        latestReceiptIdentifier: String? = nil,
        currentGenerationIdentifier: String? = nil,
        pendingGenerationIdentifier: String? = nil,
        frozenImportPlan: AttachedDataImportPlan? = nil,
        access: AttachedDataSourceAccess = .notRetained,
        refreshEnabled: Bool = false,
        automaticRefreshEnabled: Bool = false,
        localModelConsentEnabled: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.privacySafeLocationDescriptor = privacySafeLocationDescriptor
        self.fileIdentity = fileIdentity
        self.sourceDigest = sourceDigest
        self.shapeDigest = shapeDigest
        self.state = state
        self.selections = selections
        self.currentEpoch = currentEpoch
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastAttemptedRefreshAt = lastAttemptedRefreshAt
        self.itemCount = itemCount
        self.skippedItemCount = skippedItemCount
        self.attachmentBlobCount = attachmentBlobCount
        self.truncationCount = truncationCount
        self.importedLocalContainerIdentifiers = importedLocalContainerIdentifiers
        self.normalizationVersion = normalizationVersion
        self.provenanceVersion = provenanceVersion
        self.cancellationState = cancellationState
        self.lastErrorReasonCode = lastErrorReasonCode
        self.localDataRetentionState = localDataRetentionState
        self.latestReceiptIdentifier = latestReceiptIdentifier
        self.currentGenerationIdentifier = currentGenerationIdentifier
        self.pendingGenerationIdentifier = pendingGenerationIdentifier
        self.frozenImportPlan = frozenImportPlan
        self.access = access
        self.refreshEnabled = refreshEnabled
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.localModelConsentEnabled = localModelConsentEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    var isBookmarkStale: Bool {
        access.bookmarkState == .stale
            || access.bookmarkState == .reauthorizationRequired
    }

    var hasRetainedLocalData: Bool {
        localDataRetentionState == .retained
    }

    func validate() throws {
        try fileIdentity?.validate()
        try selections.forEach { try $0.validate() }
        try frozenImportPlan?.validate()
        try access.validate()
        let counts = [itemCount, skippedItemCount, attachmentBlobCount, truncationCount]
        guard AttachedDataSourceValidation.identifier(id),
              AttachedDataSourceValidation.boundedText(
                displayName,
                maximumBytes: AttachedDataSourceLimits.maximumDisplayNameBytes
              ),
              AttachedDataSourceValidation.filename(originalFilename),
              AttachedDataSourceValidation.privacySafeLocationDescriptor(
                privacySafeLocationDescriptor
              ),
              sourceDigest.map(AttachedDataSourceValidation.digest) ?? true,
              shapeDigest.map(AttachedDataSourceValidation.digest) ?? true,
              shapeDigest == nil || sourceDigest != nil,
              selections.count <= AttachedDataSourceLimits.maximumSelections,
              AttachedDataSourceValidation.unique(selections.map(\.id)),
              currentEpoch >= 0,
              lastSuccessfulRefreshAt.map(AttachedDataSourceValidation.finite) ?? true,
              lastAttemptedRefreshAt.map(AttachedDataSourceValidation.finite) ?? true,
              counts.allSatisfy({ $0 >= 0 }),
              importedLocalContainerIdentifiers.count
                <= AttachedDataSourceLimits.maximumImportedContainerIdentifiers,
              importedLocalContainerIdentifiers.allSatisfy(
                AttachedDataSourceValidation.identifier
              ),
              AttachedDataSourceValidation.unique(importedLocalContainerIdentifiers),
              normalizationVersion > 0,
              provenanceVersion > 0,
              lastErrorReasonCode.map(AttachedDataSourceValidation.reasonCode) ?? true,
              latestReceiptIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              currentGenerationIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              pendingGenerationIdentifier.map(AttachedDataSourceValidation.identifier) ?? true,
              pendingGenerationIdentifier == nil
                || pendingGenerationIdentifier != currentGenerationIdentifier,
              AttachedDataSourceValidation.finite(createdAt),
              AttachedDataSourceValidation.finite(updatedAt),
              updatedAt >= createdAt,
              !automaticRefreshEnabled || refreshEnabled,
              currentGenerationIdentifier == nil
                || localDataRetentionState == .retained
                || localDataRetentionState == .removalPending
        else { throw AttachedDataSourceFailureCode.persistenceCorrupt }

        if state == .ready || state == .importing || state == .refreshing
            || state == .connected {
            guard fileIdentity != nil,
                  sourceDigest != nil,
                  shapeDigest != nil,
                  !selections.isEmpty
            else { throw AttachedDataSourceFailureCode.persistenceCorrupt }
        }
        if state == .importing || state == .refreshing {
            guard let frozenImportPlan,
                  pendingGenerationIdentifier == frozenImportPlan.generationIdentifier,
                  frozenImportPlan.sourceIdentifier == id,
                  frozenImportPlan.sourceKind == kind,
                  frozenImportPlan.mode == mode,
                  frozenImportPlan.fileIdentity == fileIdentity,
                  frozenImportPlan.sourceDigest == sourceDigest,
                  frozenImportPlan.shapeDigest == shapeDigest,
                  frozenImportPlan.selections == selections,
                  frozenImportPlan.priorGenerationIdentifier == currentGenerationIdentifier
            else { throw AttachedDataSourceFailureCode.invalidImportPlan }
        }
    }

    func detached(at date: Date = .now) throws -> Self {
        var value = self
        value.access = try access.detached(at: date)
        value.refreshEnabled = false
        value.automaticRefreshEnabled = false
        value.state = .disconnected
        value.pendingGenerationIdentifier = nil
        value.cancellationState = .none
        value.lastErrorReasonCode = nil
        value.updatedAt = date
        try value.validate()
        return value
    }

    func reconcilingInterruptedOperation(at date: Date = .now) throws -> Self {
        guard state.isOperationInProgress else { return self }
        var value = self
        let hadPublishedGeneration = currentGenerationIdentifier != nil
        switch state {
        case .importing, .refreshing:
            if hadPublishedGeneration {
                guard let frozenImportPlan,
                      frozenImportPlan.priorGenerationIdentifier
                        == currentGenerationIdentifier
                else { throw AttachedDataSourceFailureCode.invalidImportPlan }
                if let priorSourceDigest = frozenImportPlan.priorSourceDigest,
                   let priorShapeDigest = frozenImportPlan.priorShapeDigest {
                    value.sourceDigest = priorSourceDigest
                    value.shapeDigest = priorShapeDigest
                } else {
                    // Legacy plans lack enough durable information to restore
                    // the accepted authority. Quarantine retrieval safely while
                    // preserving the generation for explicit local-data removal.
                    value.sourceDigest = nil
                    value.shapeDigest = nil
                    value.localModelConsentEnabled = false
                }
            }
            value.state = hadPublishedGeneration ? .degraded : .disconnected
            value.frozenImportPlan = nil
        case .selecting, .previewing:
            value.state = .disconnected
            value.frozenImportPlan = nil
        default:
            return self
        }
        value.pendingGenerationIdentifier = nil
        value.cancellationState = .interrupted
        value.lastErrorReasonCode = AttachedDataSourceFailureCode
            .operationInterruptedByRestart.rawValue
        value.updatedAt = date
        try value.validate()
        return value
    }

    var privacySafeDiagnosticFields: [String: String] {
        [
            "source_id": id,
            "source_kind": kind.rawValue,
            "mode": mode.rawValue,
            "state": state.rawValue,
            "epoch": String(currentEpoch),
            "item_count": String(itemCount),
            "skipped_count": String(skippedItemCount),
            "attachment_count": String(attachmentBlobCount),
            "truncation_count": String(truncationCount),
            "source_digest": sourceDigest ?? "none",
            "shape_digest": shapeDigest ?? "none",
            "reason_code": lastErrorReasonCode ?? "none",
            "bookmark_state": access.bookmarkState.rawValue,
        ]
    }
}
