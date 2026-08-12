import CryptoKit
import Foundation

enum EmailImportLimits {
    static let maximumSourceBytes = 256 * 1_024 * 1_024
    static let maximumMessageBytes = 32 * 1_024 * 1_024
    static let maximumHeaderBytes = 256 * 1_024
    static let maximumHeaderCount = 512
    static let maximumHeaderLineBytes = 16 * 1_024
    static let maximumMIMEDepth = 16
    static let maximumMIMEParts = 256
    static let maximumDecodedPartBytes = 32 * 1_024 * 1_024
    static let maximumTextBytes = 1_500_000
    static let maximumAttachmentBytes = 16 * 1_024 * 1_024
    static let maximumAttachments = ConnectorEnvelopeLimits.maximumAttachments
    static let maximumFilenameCharacters = 255
    static let maximumHeaderValueCharacters = 8_192
    static let maximumAddressValues = 100
    static let maximumReferences = 100
    static let maximumMessagesPerPage = 100
    static let maximumReconciliationEntries = 100_000
    static let maximumTraceMetadataEntries = 16
    static let fileReadChunkBytes = 64 * 1_024
    /// Leaves room in Vault's 64 KiB metadata row for the connector sidecar,
    /// integrity hashes, and provider-independent fields.
    static let maximumPreservedMetadataBytes = 32 * 1_024
}

enum EmailImportFailureCode: String, Error, Codable, Hashable, Sendable {
    case sourceTooLarge = "email_source_too_large"
    case messageTooLarge = "email_message_too_large"
    case headerSectionMissing = "email_header_section_missing"
    case headerSectionTooLarge = "email_header_section_too_large"
    case headerCountExceeded = "email_header_count_exceeded"
    case headerLineTooLarge = "email_header_line_too_large"
    case malformedHeader = "email_header_malformed"
    case mimeDepthExceeded = "email_mime_depth_exceeded"
    case mimePartCountExceeded = "email_mime_part_count_exceeded"
    case multipartBoundaryMissing = "email_multipart_boundary_missing"
    case multipartMalformed = "email_multipart_malformed"
    case transferEncodingInvalid = "email_transfer_encoding_invalid"
    case decodedPartTooLarge = "email_decoded_part_too_large"
    case textBodyTooLarge = "email_text_body_too_large"
    case unsupportedCharacterSet = "email_charset_unsupported"
    case mailboxMalformed = "email_mbox_malformed"
    case mailboxChanged = "email_mbox_changed_since_checkpoint"
    case checkpointInvalid = "email_checkpoint_invalid"
    case cancelled = "email_import_cancelled"
    case envelopeRejected = "email_connector_envelope_rejected"
    case preservedMetadataTooLarge = "email_preserved_metadata_too_large"
    case reconciliationStateTooLarge = "email_reconciliation_state_too_large"
}

extension EmailImportFailureCode: LocalizedError {
    var errorDescription: String? { rawValue }
}

enum EmailParseWarningCode: String, Codable, CaseIterable, Hashable, Sendable {
    case malformedHeaderSkipped = "email_header_malformed_skipped"
    case dateUnparseable = "email_date_unparseable"
    case receivedDateUnparseable = "email_received_date_unparseable"
    case unsupportedCharacterSetReplaced = "email_charset_replaced"
    case invalidEncodedWordPreserved = "email_encoded_word_invalid_preserved"
    case attachmentOversizedMetadataOnly = "email_attachment_oversized_metadata_only"
    case attachmentLimitReached = "email_attachment_limit_reached"
    case activeHTMLSuppressed = "email_html_active_content_suppressed"
    case remoteHTMLResourceSuppressed = "email_html_remote_resource_suppressed"
    case bodyUnavailable = "email_body_unavailable"
}

enum EmailImportReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case duplicateMessageSkipped = "email_duplicate_message_skipped"
    case duplicateMessageSuperseded = "email_duplicate_message_superseded"
}

enum EmailImportSourceFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case eml
    case mbox
    case maildir
}

enum EmailImportIndexingPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case archiveOnly = "archive_only"
    case localSemanticIndex = "local_semantic_index"

    var connectorPolicy: ConnectorRecordPolicyClassification {
        switch self {
        case .archiveOnly: .archiveOnly
        case .localSemanticIndex: .localIndexAllowed
        }
    }

    var policyBasis: String {
        switch self {
        case .archiveOnly: "explicit_local_email_import_archive_only_v1"
        case .localSemanticIndex: "explicit_local_email_import_local_index_v1"
        }
    }
}

struct EmailImportSource: Codable, Hashable, Sendable {
    let sourceIdentifierHash: String
    let mailboxIdentifierHash: String
    let displayName: String
    let format: EmailImportSourceFormat
    let observedModificationDate: Date?
    let indexingPolicy: EmailImportIndexingPolicy

    init(
        sourceIdentifier: String,
        mailboxIdentifier: String? = nil,
        displayName: String,
        format: EmailImportSourceFormat,
        observedModificationDate: Date? = nil,
        indexingPolicy: EmailImportIndexingPolicy = .archiveOnly
    ) {
        sourceIdentifierHash = EmailDigest.sha256("source\u{1f}\(sourceIdentifier)")
        mailboxIdentifierHash = EmailDigest.sha256(
            "mailbox\u{1f}\(mailboxIdentifier ?? sourceIdentifier)"
        )
        self.displayName = EmailFilenameSanitizer.basename(
            displayName,
            fallback: format == .eml ? "Imported message.eml" : "Support mailbox"
        )
        self.format = format
        self.observedModificationDate = observedModificationDate
        self.indexingPolicy = indexingPolicy
    }
}

struct EmailHeaderFields: Codable, Hashable, Sendable {
    let messageID: String?
    let inReplyTo: String?
    let references: [String]
    let from: [String]
    let to: [String]
    let cc: [String]
    let replyTo: [String]
    let subject: String
    let sentDate: Date?
    let receivedDate: Date?
}

enum EmailAttachmentDigestBasis: String, Codable, CaseIterable, Hashable, Sendable {
    case decodedContent = "decoded_content"
}

struct EmailAttachmentMetadata: Codable, Hashable, Sendable {
    let identifier: String
    let filename: String
    let mediaType: String
    let byteCount: Int
    let sha256: String
    let digestBasis: EmailAttachmentDigestBasis
    let disposition: String?
    let contentID: String?
    let wasOversized: Bool
}

enum EmailThreadBasis: String, Codable, CaseIterable, Hashable, Sendable {
    case messageIDRoot = "message_id_root"
    case messageReferences = "message_references"
    case inReplyTo = "in_reply_to"
    case heuristicSubjectParticipants = "heuristic_subject_participants"
    case none
}

struct EmailThreadRelation: Codable, Hashable, Sendable {
    let basis: EmailThreadBasis
    let parentMessageID: String?
    let rootMessageID: String?
    let heuristicKey: String?

    var connectorParentIdentifier: String? {
        if let rootMessageID {
            return "email-thread:\(EmailDigest.sha256(rootMessageID))"
        }
        if let parentMessageID {
            return "email-thread:\(EmailDigest.sha256(parentMessageID))"
        }
        if let heuristicKey {
            return "email-thread:\(heuristicKey)"
        }
        return nil
    }
}

struct EmailParsedMessage: Codable, Hashable, Sendable {
    let headers: EmailHeaderFields
    let normalizedBody: String
    let attachments: [EmailAttachmentMetadata]
    let rawMessageSHA256: String
    let warnings: [EmailParseWarningCode]
    let suppressedActiveHTMLCount: Int
    let suppressedRemoteResourceCount: Int

    var stableRemoteIdentifier: String {
        if let messageID = headers.messageID {
            return "email-message:\(EmailDigest.sha256("message-id\u{1f}\(messageID)"))"
        }
        return "email-message:\(rawMessageSHA256)"
    }

    var editOrVersionIdentifier: String { rawMessageSHA256 }
}

/// Compact coordinates for reconstructing one already admitted mbox message
/// from the authenticated source prefix. The reconciliation state retains only
/// these offsets and parsed identity/thread fields, never a message body.
struct EmailMBoxEntryLocator: Hashable, Sendable {
    let separatorByteOffset: Int
    let messageEndByteOffset: Int

    init(separatorByteOffset: Int, messageEndByteOffset: Int) throws {
        guard separatorByteOffset >= 0,
              messageEndByteOffset > separatorByteOffset
        else { throw EmailImportFailureCode.checkpointInvalid }
        self.separatorByteOffset = separatorByteOffset
        self.messageEndByteOffset = messageEndByteOffset
    }

    init(_ entry: EmailMBoxEntry) throws {
        try self.init(
            separatorByteOffset: entry.separatorByteOffset,
            messageEndByteOffset: entry.messageEndByteOffset
        )
    }
}

/// Compact, task-owned state used to reconcile identities across committed
/// mbox pages. It intentionally retains no body or attachment metadata.
struct EmailMBoxReconciliationMessageState: Hashable, Sendable {
    let stableRemoteIdentifier: String
    let rawMessageSHA256: String
    let sourceTimestamp: Date
    let ancestry: EmailThreadAncestry?
    let sourceLocator: EmailMBoxEntryLocator
}

struct EmailMBoxReconciliationState: Hashable, Sendable {
    var selectedByRemoteIdentifier:
        [String: EmailMBoxReconciliationMessageState] = [:]

    var ancestryByMessageID: [String: EmailThreadAncestry] {
        var result: [String: EmailThreadAncestry] = [:]
        result.reserveCapacity(selectedByRemoteIdentifier.count)
        for state in selectedByRemoteIdentifier.values {
            guard let ancestry = state.ancestry else { continue }
            result[ancestry.messageID] = ancestry
        }
        return result
    }
}

struct EmailPreservedMetadata: Codable, Hashable, Sendable {
    let headers: EmailHeaderFields
    let attachments: [EmailAttachmentMetadata]
    let thread: EmailThreadRelation
    let rawMessageSHA256: String
    let warnings: [EmailParseWarningCode]
    let mailboxIdentifierHash: String
    let importSourceIdentifierHash: String

    init(
        headers: EmailHeaderFields,
        attachments: [EmailAttachmentMetadata],
        thread: EmailThreadRelation,
        rawMessageSHA256: String,
        warnings: [EmailParseWarningCode],
        mailboxIdentifierHash: String,
        importSourceIdentifierHash: String
    ) throws {
        self.headers = headers
        self.attachments = attachments
        self.thread = thread
        self.rawMessageSHA256 = rawMessageSHA256
        self.warnings = warnings
        self.mailboxIdentifierHash = mailboxIdentifierHash
        self.importSourceIdentifierHash = importSourceIdentifierHash
        _ = try canonicalJSONData()
    }

    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= EmailImportLimits.maximumPreservedMetadataBytes else {
            throw EmailImportFailureCode.preservedMetadataTooLarge
        }
        return data
    }
}

struct EmailAdmissionRecord: Codable, Hashable, Sendable {
    let envelope: ConnectorRecordEnvelope
    let metadata: EmailPreservedMetadata
}

struct EmailImportCheckpoint: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sourceIdentifierHash: String
    let format: EmailImportSourceFormat
    let nextPageOrdinal: Int
    let paginationStreamIdentifier: String?
    let nextByteOffset: Int?
    let committedByteCount: Int?
    let committedPrefixSHA256: String?
    let nextMaildirRelativePath: String?
    /// Identifies the selected ancestry/version graph whose bounded thread
    /// repair pass is in progress. Optional fields keep schema-v1 checkpoints
    /// written before thread convergence source-compatible.
    let threadRepairGeneration: String?
    let threadRepairAfterRemoteIdentifier: String?
    let completed: Bool

    init(
        schemaVersion: Int = 1,
        sourceIdentifierHash: String,
        format: EmailImportSourceFormat,
        nextPageOrdinal: Int,
        paginationStreamIdentifier: String? = nil,
        nextByteOffset: Int? = nil,
        committedByteCount: Int? = nil,
        committedPrefixSHA256: String? = nil,
        nextMaildirRelativePath: String? = nil,
        threadRepairGeneration: String? = nil,
        threadRepairAfterRemoteIdentifier: String? = nil,
        completed: Bool
    ) throws {
        guard schemaVersion == 1,
              sourceIdentifierHash.count == 64,
              sourceIdentifierHash.allSatisfy(\.isHexDigit),
              nextPageOrdinal >= 0,
              paginationStreamIdentifier.map({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit)
              }) ?? true,
              nextByteOffset.map({ $0 >= 0 }) ?? true,
              committedByteCount.map({ $0 >= 0 }) ?? true,
              (committedByteCount == nil) == (committedPrefixSHA256 == nil),
              committedPrefixSHA256.map({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit)
              }) ?? true,
              threadRepairGeneration.map({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit)
              }) ?? true,
              threadRepairAfterRemoteIdentifier.map({
                  ConnectorEnvelopeValidation.validIdentifier($0)
              }) ?? true,
              threadRepairAfterRemoteIdentifier == nil
                || threadRepairGeneration != nil,
              !completed || (nextByteOffset == nil && nextMaildirRelativePath == nil)
        else { throw EmailImportFailureCode.checkpointInvalid }
        self.schemaVersion = schemaVersion
        self.sourceIdentifierHash = sourceIdentifierHash.lowercased()
        self.format = format
        self.nextPageOrdinal = nextPageOrdinal
        self.paginationStreamIdentifier = paginationStreamIdentifier?.lowercased()
        self.nextByteOffset = nextByteOffset
        self.committedByteCount = committedByteCount
        self.committedPrefixSHA256 = committedPrefixSHA256?.lowercased()
        self.nextMaildirRelativePath = nextMaildirRelativePath
        self.threadRepairGeneration = threadRepairGeneration?.lowercased()
        self.threadRepairAfterRemoteIdentifier =
            threadRepairAfterRemoteIdentifier
        self.completed = completed
    }
}

struct EmailImportReceipt: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sourceFormat: EmailImportSourceFormat
    let pageOrdinal: Int
    let importedItemCount: Int
    let skippedItemCount: Int
    let attachmentCount: Int
    let warningCounts: [String: Int]
    let paginationReceiptHash: String
    let completed: Bool
}

struct EmailAdmissionPage: Codable, Hashable, Sendable {
    let records: [EmailAdmissionRecord]
    let paginationReceipt: ConnectorPaginationReceipt
    let checkpointAfterCommit: EmailImportCheckpoint
    let receipt: EmailImportReceipt
}

enum EmailImportedDataRetentionPolicy: String, Codable, Hashable, Sendable {
    /// A security-scoped bookmark or other read authorization controls future
    /// source reads only. Removing it must not delete already admitted records.
    case preserveOnAuthorizationRemoval = "disconnect_preserves_local_data"
}

/// ConnectorVaultPage-ready grouping without importing or owning Vault state.
/// Every record in a group shares one source/account/pagination boundary.
struct EmailVaultPageGroup: Codable, Hashable, Sendable {
    let provider: String
    let providerAccountIdentifier: String
    let accountDisplayName: String
    let providerContainerIdentifier: String
    let containerDisplayName: String
    let containerKind: String
    let paginationReceipt: ConnectorPaginationReceipt
    let records: [EmailAdmissionRecord]
}

/// The complete, non-persistent output of one local import page. Authorization
/// state is intentionally absent and has a separate lifecycle from this data.
struct EmailImportResult: Codable, Hashable, Sendable {
    let sourceFormat: EmailImportSourceFormat
    let sourceDisplayName: String
    let mailboxDisplayIdentity: String
    let admissionPage: EmailAdmissionPage
    let vaultPageGroups: [EmailVaultPageGroup]
    let importedDataRetentionPolicy: EmailImportedDataRetentionPolicy

    var envelopes: [ConnectorRecordEnvelope] {
        admissionPage.records.map(\.envelope)
    }

    var attachmentMetadata: [EmailAttachmentMetadata] {
        admissionPage.records.flatMap { $0.metadata.attachments }
    }

    var attachmentCount: Int { attachmentMetadata.count }
    var paginationReceipt: ConnectorPaginationReceipt { admissionPage.paginationReceipt }
    var checkpointAfterCommit: EmailImportCheckpoint {
        admissionPage.checkpointAfterCommit
    }
}

enum EmailTraceEventName: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceRead = "email.source_read"
    case messageParse = "email.message_parse"
    case htmlSanitize = "email.html_sanitize"
    case pagePrepared = "email.page_prepared"
    case cancellation = "email.cancellation"
}

enum EmailTraceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

struct EmailTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = EmailTracePrivacy.boundedIdentifier(traceID)
        self.spanID = EmailTracePrivacy.boundedIdentifier(spanID)
        self.parentSpanID = parentSpanID.map(EmailTracePrivacy.boundedIdentifier)
    }

    func child() -> Self {
        .init(traceID: traceID, parentSpanID: spanID)
    }
}

struct EmailTraceEvent: Codable, Hashable, Sendable {
    let timestamp: Date
    let event: EmailTraceEventName
    let status: EmailTraceStatus
    let reasonCode: String
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let metadata: [String: String]
}

typealias EmailTraceSink = @Sendable (EmailTraceEvent) -> Void

enum EmailTracePrivacy {
    static func boundedIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(128))
    }

    static func metadata(_ values: [(String, String)]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values
            .filter { allowedMetadataKeys.contains($0.0) }
            .prefix(EmailImportLimits.maximumTraceMetadataEntries)
            .map { key, value in
                (
                    key,
                    String(value.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0)
                    }.prefix(160))
                )
            })
    }

    private static let allowedMetadataKeys: Set<String> = [
        "source_hash", "format", "page_ordinal", "message_count",
        "imported_count", "skipped_count", "attachment_count",
        "warning_count", "part_count", "active_suppressed_count",
        "remote_suppressed_count", "byte_count",
    ]
}

enum EmailDigest {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct EmailAuthorizedFileSnapshot: Hashable, Sendable {
    let data: Data
    let observedModificationDate: Date?
}

/// Performs the bounded, credential-free file read used by local Email import.
/// Security-scope acquisition remains a caller concern so tests can exercise the
/// byte and cancellation boundary without requiring a sandbox extension.
enum EmailBoundedFileReader {
    static func readAuthorizedFile(
        at url: URL,
        maximumBytes: Int = EmailImportLimits.maximumSourceBytes,
        chunkByteCount: Int = EmailImportLimits.fileReadChunkBytes,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailAuthorizedFileSnapshot {
        guard maximumBytes > 0,
              maximumBytes <= EmailImportLimits.maximumSourceBytes,
              chunkByteCount > 0,
              chunkByteCount <= maximumBytes
        else { throw EmailImportFailureCode.checkpointInvalid }
        try checkCancellation(isCancelled)

        let initialValues = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard initialValues.isRegularFile == true else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        if let announcedSize = initialValues.fileSize,
           announcedSize > maximumBytes {
            throw EmailImportFailureCode.sourceTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        if let announcedSize = initialValues.fileSize {
            result.reserveCapacity(min(announcedSize, maximumBytes))
        }
        while true {
            try checkCancellation(isCancelled)
            guard let chunk = try handle.read(upToCount: chunkByteCount),
                  !chunk.isEmpty
            else { break }
            guard chunk.count <= maximumBytes - result.count else {
                throw EmailImportFailureCode.sourceTooLarge
            }
            result.append(chunk)
        }
        try checkCancellation(isCancelled)
        return .init(
            data: result,
            observedModificationDate: initialValues.contentModificationDate
        )
    }

    /// Owns the detached worker and forwards cancellation to it. Callers must
    /// already hold any security-scoped authorization for the URL while this
    /// operation is running.
    static func readAuthorizedFileDetached(
        at url: URL,
        maximumBytes: Int = EmailImportLimits.maximumSourceBytes,
        chunkByteCount: Int = EmailImportLimits.fileReadChunkBytes
    ) async throws -> EmailAuthorizedFileSnapshot {
        let worker = Task.detached(priority: .userInitiated) {
            try readAuthorizedFile(
                at: url,
                maximumBytes: maximumBytes,
                chunkByteCount: chunkByteCount,
                isCancelled: { Task.isCancelled }
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func checkCancellation(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw EmailImportFailureCode.cancelled }
    }
}

enum EmailFilenameSanitizer {
    static func basename(_ value: String, fallback: String = "attachment") -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
        let candidate = normalized.split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
        let filtered = String(candidate.unicodeScalars.filter {
            !ConnectorEnvelopeValidation.isUnsafeScalar($0)
                && $0.value != 0
        })
        let collapsed = filtered
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = collapsed.isEmpty || collapsed == "." ? fallback : collapsed
        return String(safe.prefix(EmailImportLimits.maximumFilenameCharacters))
    }
}
