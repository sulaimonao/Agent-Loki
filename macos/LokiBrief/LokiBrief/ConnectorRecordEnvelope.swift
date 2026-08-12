import CryptoKit
import Foundation

enum ConnectorEnvelopeLimits {
    static let schemaVersion = 1
    static let maximumIdentifierBytes = 1_024
    static let maximumRecordTypeBytes = 128
    static let maximumNormalizedTextBytes = 2 * 1_024 * 1_024
    static let maximumAttachments = 32
    static let maximumAttachmentMetadataBytes = 64 * 1_024
    static let maximumCursorBytes = 16 * 1_024
    static let maximumCheckpointBytes = 2_048
}

enum ConnectorEnvelopeFailureCode: String, Error, Codable, Hashable, Sendable {
    case invalidProvider = "connector_envelope_provider_invalid"
    case invalidAccountIdentifier = "connector_envelope_account_identifier_invalid"
    case invalidRecordIdentifier = "connector_envelope_record_identifier_invalid"
    case invalidRecordType = "connector_envelope_record_type_invalid"
    case invalidParentIdentifier = "connector_envelope_parent_identifier_invalid"
    case invalidTimestamp = "connector_envelope_timestamp_invalid"
    case invalidNormalizedText = "connector_envelope_normalized_text_invalid"
    case normalizedTextMismatch = "connector_envelope_text_not_normalized"
    case invalidSourceHash = "connector_envelope_source_hash_invalid"
    case invalidVersionIdentifier = "connector_envelope_version_identifier_invalid"
    case invalidAttachment = "connector_envelope_attachment_invalid"
    case invalidPaginationReceipt = "connector_envelope_pagination_receipt_invalid"
    case paginationScopeMismatch = "connector_envelope_pagination_scope_mismatch"
    case paginationDidNotAdvance = "connector_envelope_pagination_did_not_advance"
    case paginationReceiptMismatch = "connector_envelope_pagination_receipt_mismatch"
    case sensitiveContentCannotBeIndexed = "connector_envelope_sensitive_content_cannot_be_indexed"
    case tombstoneContainsContent = "connector_envelope_tombstone_contains_content"
    case conflictingRecordIdentity = "connector_envelope_record_identity_conflict"
}

extension ConnectorEnvelopeFailureCode: LocalizedError {
    var errorDescription: String? { rawValue }
}

enum ConnectorRecordContentClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case providerRecord = "provider_record"
    case finalUserMessage = "final_user_message"
    case finalAssistantMessage = "final_assistant_message"
    case hiddenReasoning = "hidden_reasoning"
    case credential = "credential"
    case privateSigningMaterial = "private_signing_material"
    case rawDiagnostic = "raw_diagnostic"
    case temporaryArtifact = "temporary_artifact"
    case recoveryArtifact = "recovery_artifact"

    var mayEnterSemanticIndex: Bool {
        switch self {
        case .providerRecord, .finalUserMessage, .finalAssistantMessage:
            true
        case .hiddenReasoning, .credential, .privateSigningMaterial, .rawDiagnostic,
             .temporaryArtifact, .recoveryArtifact:
            false
        }
    }
}

enum ConnectorRecordPolicyClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case localIndexAllowed = "local_index_allowed"
    case archiveOnly = "archive_only"
    case metadataOnly = "metadata_only"
    case excludedSensitive = "excluded_sensitive"

    var mayEnterSemanticIndex: Bool {
        self == .localIndexAllowed
    }
}

enum ConnectorRecordDeletionState: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case tombstone
}

struct ConnectorAttachmentMetadata: Codable, Hashable, Sendable {
    let attachmentIdentifier: String
    let mediaType: String
    let byteCount: Int
    let sourceHash: String
    let widthPixels: Int?
    let heightPixels: Int?

    init(
        attachmentIdentifier: String,
        mediaType: String,
        byteCount: Int,
        sourceHash: String,
        widthPixels: Int? = nil,
        heightPixels: Int? = nil
    ) throws {
        guard ConnectorEnvelopeValidation.validIdentifier(attachmentIdentifier),
              !mediaType.isEmpty,
              mediaType.lengthOfBytes(using: .utf8) <= 255,
              !mediaType.unicodeScalars.contains(where: ConnectorEnvelopeValidation.isUnsafeScalar),
              byteCount >= 0,
              ConnectorEnvelopeValidation.validSHA256(sourceHash),
              widthPixels.map({ $0 > 0 }) ?? true,
              heightPixels.map({ $0 > 0 }) ?? true
        else { throw ConnectorEnvelopeFailureCode.invalidAttachment }
        self.attachmentIdentifier = attachmentIdentifier
        self.mediaType = mediaType.lowercased()
        self.byteCount = byteCount
        self.sourceHash = sourceHash.lowercased()
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    func validateIntegrity() throws {
        guard ConnectorEnvelopeValidation.validIdentifier(attachmentIdentifier),
              !mediaType.isEmpty,
              mediaType == mediaType.lowercased(),
              mediaType.lengthOfBytes(using: .utf8) <= 255,
              !mediaType.unicodeScalars.contains(where: ConnectorEnvelopeValidation.isUnsafeScalar),
              byteCount >= 0,
              ConnectorEnvelopeValidation.validSHA256(sourceHash),
              sourceHash == sourceHash.lowercased(),
              widthPixels.map({ $0 > 0 }) ?? true,
              heightPixels.map({ $0 > 0 }) ?? true
        else { throw ConnectorEnvelopeFailureCode.invalidAttachment }
    }
}

/// A provider cursor is retained only at the connector checkpoint boundary. It
/// is intentionally omitted from semantic-index handoffs and result provenance.
struct ConnectorPaginationReceipt: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let checkpointIdentifier: String
    let streamIdentifier: String
    let pageOrdinal: Int
    let requestCursor: String?
    let nextCursor: String?
    let sourceHighWatermark: String?
    let isComplete: Bool
    let receiptHash: String

    init(
        schemaVersion: Int = ConnectorEnvelopeLimits.schemaVersion,
        checkpointIdentifier: String,
        streamIdentifier: String,
        pageOrdinal: Int,
        requestCursor: String?,
        nextCursor: String?,
        sourceHighWatermark: String?,
        isComplete: Bool
    ) throws {
        guard schemaVersion == ConnectorEnvelopeLimits.schemaVersion,
              ConnectorEnvelopeValidation.validIdentifier(
                checkpointIdentifier,
                maximumBytes: ConnectorEnvelopeLimits.maximumCheckpointBytes
              ),
              ConnectorEnvelopeValidation.validIdentifier(streamIdentifier),
              pageOrdinal >= 0,
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                requestCursor,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                nextCursor,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                sourceHighWatermark,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              (!isComplete || nextCursor == nil),
              !(nextCursor != nil && nextCursor == requestCursor)
        else { throw ConnectorEnvelopeFailureCode.invalidPaginationReceipt }

        self.schemaVersion = schemaVersion
        self.checkpointIdentifier = checkpointIdentifier
        self.streamIdentifier = streamIdentifier
        self.pageOrdinal = pageOrdinal
        self.requestCursor = requestCursor
        self.nextCursor = nextCursor
        self.sourceHighWatermark = sourceHighWatermark
        self.isComplete = isComplete
        receiptHash = ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                String(schemaVersion),
                checkpointIdentifier,
                streamIdentifier,
                String(pageOrdinal),
                requestCursor ?? "",
                nextCursor ?? "",
                sourceHighWatermark ?? "",
                String(isComplete),
            ])
        )
    }

    func validate(after previous: ConnectorPaginationReceipt?) throws {
        try validateIntegrity()

        guard let previous else {
            guard pageOrdinal == 0, requestCursor == nil else {
                throw ConnectorEnvelopeFailureCode.paginationDidNotAdvance
            }
            return
        }
        guard checkpointIdentifier == previous.checkpointIdentifier,
              streamIdentifier == previous.streamIdentifier
        else { throw ConnectorEnvelopeFailureCode.paginationScopeMismatch }
        guard !previous.isComplete,
              pageOrdinal == previous.pageOrdinal + 1,
              requestCursor == previous.nextCursor
        else { throw ConnectorEnvelopeFailureCode.paginationDidNotAdvance }
    }

    func validateIntegrity() throws {
        guard schemaVersion == ConnectorEnvelopeLimits.schemaVersion,
              ConnectorEnvelopeValidation.validIdentifier(
                checkpointIdentifier,
                maximumBytes: ConnectorEnvelopeLimits.maximumCheckpointBytes
              ),
              ConnectorEnvelopeValidation.validIdentifier(streamIdentifier),
              pageOrdinal >= 0,
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                requestCursor,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                nextCursor,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              ConnectorEnvelopeValidation.validOptionalBoundedValue(
                sourceHighWatermark,
                maximumBytes: ConnectorEnvelopeLimits.maximumCursorBytes
              ),
              (!isComplete || nextCursor == nil),
              !(nextCursor != nil && nextCursor == requestCursor),
              receiptHash == receiptHash.lowercased(),
              receiptHash == ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                String(schemaVersion),
                checkpointIdentifier,
                streamIdentifier,
                String(pageOrdinal),
                requestCursor ?? "",
                nextCursor ?? "",
                sourceHighWatermark ?? "",
                String(isComplete),
            ])
        ) else { throw ConnectorEnvelopeFailureCode.paginationReceiptMismatch }
    }
}

struct ConnectorRecordProvenance: Codable, Hashable, Sendable {
    let sourceSystem: String
    let sourceContainerIdentifier: String?
    let sourceURL: URL?
    let retrievedAt: Date
    let policyBasis: String

    init(
        sourceSystem: String,
        sourceContainerIdentifier: String?,
        sourceURL: URL?,
        retrievedAt: Date,
        policyBasis: String
    ) throws {
        guard ConnectorEnvelopeValidation.validIdentifier(sourceSystem),
              ConnectorEnvelopeValidation.validOptionalIdentifier(sourceContainerIdentifier),
              retrievedAt.timeIntervalSinceReferenceDate.isFinite,
              !policyBasis.isEmpty,
              policyBasis.lengthOfBytes(using: .utf8) <= 512,
              !policyBasis.unicodeScalars.contains(where: ConnectorEnvelopeValidation.isUnsafeScalar),
              sourceURL.map({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") }) ?? true,
              sourceURL?.user == nil,
              sourceURL?.password == nil
        else { throw ConnectorEnvelopeFailureCode.invalidRecordIdentifier }
        self.sourceSystem = sourceSystem
        self.sourceContainerIdentifier = sourceContainerIdentifier
        self.sourceURL = sourceURL
        self.retrievedAt = retrievedAt
        self.policyBasis = policyBasis
    }

    func validateIntegrity() throws {
        guard ConnectorEnvelopeValidation.validIdentifier(sourceSystem),
              ConnectorEnvelopeValidation.validOptionalIdentifier(sourceContainerIdentifier),
              retrievedAt.timeIntervalSinceReferenceDate.isFinite,
              !policyBasis.isEmpty,
              policyBasis.lengthOfBytes(using: .utf8) <= 512,
              !policyBasis.unicodeScalars.contains(where: ConnectorEnvelopeValidation.isUnsafeScalar),
              sourceURL.map({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") }) ?? true,
              sourceURL?.user == nil,
              sourceURL?.password == nil
        else { throw ConnectorEnvelopeFailureCode.invalidRecordIdentifier }
    }
}

struct ConnectorRecordIdentity: Codable, Hashable, Sendable {
    let provider: String
    let pseudonymousAccountIdentifier: String
    let remoteRecordIdentifier: String
    let recordType: String

    var deduplicationKey: String {
        ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                provider,
                pseudonymousAccountIdentifier,
                remoteRecordIdentifier,
                recordType,
            ])
        )
    }
}

struct ConnectorRecordEnvelope: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let provider: String
    let pseudonymousAccountIdentifier: String
    let remoteRecordIdentifier: String
    let recordType: String
    let parentOrThreadIdentifier: String?
    let sourceTimestamp: Date
    let ingestionTimestamp: Date
    let normalizedText: String
    let attachments: [ConnectorAttachmentMetadata]
    let deletionState: ConnectorRecordDeletionState
    let editOrVersionIdentifier: String
    let sourceHash: String
    let paginationReceipt: ConnectorPaginationReceipt
    let provenance: ConnectorRecordProvenance
    let policyClassification: ConnectorRecordPolicyClassification
    let contentClassification: ConnectorRecordContentClassification
    let containsSensitiveMaterial: Bool

    init(
        schemaVersion: Int = ConnectorEnvelopeLimits.schemaVersion,
        provider: String,
        pseudonymousAccountIdentifier: String,
        remoteRecordIdentifier: String,
        recordType: String,
        parentOrThreadIdentifier: String? = nil,
        sourceTimestamp: Date,
        ingestionTimestamp: Date,
        normalizedText: String,
        attachments: [ConnectorAttachmentMetadata] = [],
        deletionState: ConnectorRecordDeletionState = .available,
        editOrVersionIdentifier: String,
        sourceHash: String,
        paginationReceipt: ConnectorPaginationReceipt,
        provenance: ConnectorRecordProvenance,
        policyClassification: ConnectorRecordPolicyClassification,
        contentClassification: ConnectorRecordContentClassification = .providerRecord,
        containsSensitiveMaterial: Bool = false
    ) throws {
        let canonicalProvider = ConnectorTextNormalization.identifier(provider)
        let canonicalRecordType = ConnectorTextNormalization.identifier(recordType)
        let canonicalText = ConnectorTextNormalization.text(normalizedText)
        let canonicalAttachments = try attachments.map {
            try ConnectorAttachmentMetadata(
                attachmentIdentifier: $0.attachmentIdentifier,
                mediaType: $0.mediaType,
                byteCount: $0.byteCount,
                sourceHash: $0.sourceHash,
                widthPixels: $0.widthPixels,
                heightPixels: $0.heightPixels
            )
        }
        let attachmentMetadataByteCount =
            (try? JSONEncoder.connectorCanonical.encode(canonicalAttachments).count) ?? Int.max

        guard schemaVersion == ConnectorEnvelopeLimits.schemaVersion,
              ConnectorEnvelopeValidation.validIdentifier(canonicalProvider)
        else { throw ConnectorEnvelopeFailureCode.invalidProvider }
        guard sourceTimestamp.timeIntervalSinceReferenceDate.isFinite,
              ingestionTimestamp.timeIntervalSinceReferenceDate.isFinite
        else { throw ConnectorEnvelopeFailureCode.invalidTimestamp }
        guard ConnectorEnvelopeValidation.validIdentifier(pseudonymousAccountIdentifier) else {
            throw ConnectorEnvelopeFailureCode.invalidAccountIdentifier
        }
        guard ConnectorEnvelopeValidation.validIdentifier(remoteRecordIdentifier) else {
            throw ConnectorEnvelopeFailureCode.invalidRecordIdentifier
        }
        guard ConnectorEnvelopeValidation.validIdentifier(
            canonicalRecordType,
            maximumBytes: ConnectorEnvelopeLimits.maximumRecordTypeBytes
        ) else { throw ConnectorEnvelopeFailureCode.invalidRecordType }
        guard ConnectorEnvelopeValidation.validOptionalIdentifier(parentOrThreadIdentifier) else {
            throw ConnectorEnvelopeFailureCode.invalidParentIdentifier
        }
        guard ConnectorEnvelopeValidation.validIdentifier(editOrVersionIdentifier) else {
            throw ConnectorEnvelopeFailureCode.invalidVersionIdentifier
        }
        guard ConnectorEnvelopeValidation.validSHA256(sourceHash) else {
            throw ConnectorEnvelopeFailureCode.invalidSourceHash
        }
        guard canonicalAttachments.count <= ConnectorEnvelopeLimits.maximumAttachments,
              attachmentMetadataByteCount <= ConnectorEnvelopeLimits.maximumAttachmentMetadataBytes
        else { throw ConnectorEnvelopeFailureCode.invalidAttachment }
        guard canonicalText.lengthOfBytes(using: .utf8) <= ConnectorEnvelopeLimits.maximumNormalizedTextBytes else {
            throw ConnectorEnvelopeFailureCode.invalidNormalizedText
        }
        guard canonicalText == normalizedText else {
            throw ConnectorEnvelopeFailureCode.normalizedTextMismatch
        }
        if deletionState == .tombstone,
           !normalizedText.isEmpty || !attachments.isEmpty {
            throw ConnectorEnvelopeFailureCode.tombstoneContainsContent
        }
        if policyClassification.mayEnterSemanticIndex,
           (!contentClassification.mayEnterSemanticIndex || containsSensitiveMaterial) {
            throw ConnectorEnvelopeFailureCode.sensitiveContentCannotBeIndexed
        }
        try paginationReceipt.validateIntegrity()
        try provenance.validateIntegrity()

        self.schemaVersion = schemaVersion
        self.provider = canonicalProvider
        self.pseudonymousAccountIdentifier = pseudonymousAccountIdentifier
        self.remoteRecordIdentifier = remoteRecordIdentifier
        self.recordType = canonicalRecordType
        self.parentOrThreadIdentifier = parentOrThreadIdentifier
        self.sourceTimestamp = sourceTimestamp
        self.ingestionTimestamp = ingestionTimestamp
        self.normalizedText = normalizedText
        self.attachments = canonicalAttachments.sorted {
            if $0.attachmentIdentifier != $1.attachmentIdentifier {
                return $0.attachmentIdentifier < $1.attachmentIdentifier
            }
            return $0.sourceHash < $1.sourceHash
        }
        self.deletionState = deletionState
        self.editOrVersionIdentifier = editOrVersionIdentifier
        self.sourceHash = sourceHash.lowercased()
        self.paginationReceipt = paginationReceipt
        self.provenance = provenance
        self.policyClassification = policyClassification
        self.contentClassification = contentClassification
        self.containsSensitiveMaterial = containsSensitiveMaterial
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
                provider: values.decode(String.self, forKey: .provider),
                pseudonymousAccountIdentifier: values.decode(
                    String.self,
                    forKey: .pseudonymousAccountIdentifier
                ),
                remoteRecordIdentifier: values.decode(
                    String.self,
                    forKey: .remoteRecordIdentifier
                ),
                recordType: values.decode(String.self, forKey: .recordType),
                parentOrThreadIdentifier: values.decodeIfPresent(
                    String.self,
                    forKey: .parentOrThreadIdentifier
                ),
                sourceTimestamp: values.decode(Date.self, forKey: .sourceTimestamp),
                ingestionTimestamp: values.decode(Date.self, forKey: .ingestionTimestamp),
                normalizedText: values.decode(String.self, forKey: .normalizedText),
                attachments: values.decode(
                    [ConnectorAttachmentMetadata].self,
                    forKey: .attachments
                ),
                deletionState: values.decode(
                    ConnectorRecordDeletionState.self,
                    forKey: .deletionState
                ),
                editOrVersionIdentifier: values.decode(
                    String.self,
                    forKey: .editOrVersionIdentifier
                ),
                sourceHash: values.decode(String.self, forKey: .sourceHash),
                paginationReceipt: values.decode(
                    ConnectorPaginationReceipt.self,
                    forKey: .paginationReceipt
                ),
                provenance: values.decode(
                    ConnectorRecordProvenance.self,
                    forKey: .provenance
                ),
                policyClassification: values.decode(
                    ConnectorRecordPolicyClassification.self,
                    forKey: .policyClassification
                ),
                contentClassification: values.decode(
                    ConnectorRecordContentClassification.self,
                    forKey: .contentClassification
                ),
                containsSensitiveMaterial: values.decode(
                    Bool.self,
                    forKey: .containsSensitiveMaterial
                )
            )
        } catch let decoding as DecodingError {
            throw decoding
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Connector envelope invariant failed: \(error)"
                )
            )
        }
    }

    var identity: ConnectorRecordIdentity {
        .init(
            provider: provider,
            pseudonymousAccountIdentifier: pseudonymousAccountIdentifier,
            remoteRecordIdentifier: remoteRecordIdentifier,
            recordType: recordType
        )
    }

    var deduplicationKey: String { identity.deduplicationKey }

    var mayEnterSemanticIndex: Bool {
        deletionState == .available &&
            policyClassification.mayEnterSemanticIndex &&
            contentClassification.mayEnterSemanticIndex &&
            !containsSensitiveMaterial
    }

    var canonicalEnvelopeHash: String {
        let attachmentMaterial = attachments.map {
            ConnectorEnvelopeDigest.lengthPrefixed([
                $0.attachmentIdentifier,
                $0.mediaType,
                String($0.byteCount),
                $0.sourceHash,
                $0.widthPixels.map(String.init) ?? "",
                $0.heightPixels.map(String.init) ?? "",
            ])
        }.joined()
        return ConnectorEnvelopeDigest.sha256(
            ConnectorEnvelopeDigest.lengthPrefixed([
                String(schemaVersion),
                deduplicationKey,
                parentOrThreadIdentifier ?? "",
                ConnectorEnvelopeDigest.milliseconds(sourceTimestamp),
                normalizedText,
                attachmentMaterial,
                deletionState.rawValue,
                editOrVersionIdentifier,
                sourceHash,
                provenance.sourceSystem,
                provenance.sourceContainerIdentifier ?? "",
                provenance.sourceURL?.absoluteString ?? "",
                policyClassification.rawValue,
                contentClassification.rawValue,
                String(containsSensitiveMaterial),
            ])
        )
    }

    func indexHandoff() -> ConnectorIndexHandoff? {
        guard mayEnterSemanticIndex else { return nil }
        return .init(
            stableSourceIdentifier: deduplicationKey,
            provider: provider,
            pseudonymousAccountIdentifier: pseudonymousAccountIdentifier,
            remoteRecordIdentifier: remoteRecordIdentifier,
            recordType: recordType,
            parentOrThreadIdentifier: parentOrThreadIdentifier,
            sourceTimestamp: sourceTimestamp,
            normalizedText: normalizedText,
            sourceHash: sourceHash,
            sourceURL: provenance.sourceURL,
            provenanceReceiptHash: canonicalEnvelopeHash
        )
    }

}

/// The only connector shape accepted by the semantic layer. Pagination cursors,
/// attachment bytes/metadata, policy text, and sensitive classifications do not
/// cross this boundary.
struct ConnectorIndexHandoff: Codable, Hashable, Sendable {
    let stableSourceIdentifier: String
    let provider: String
    let pseudonymousAccountIdentifier: String
    let remoteRecordIdentifier: String
    let recordType: String
    let parentOrThreadIdentifier: String?
    let sourceTimestamp: Date
    let normalizedText: String
    let sourceHash: String
    let sourceURL: URL?
    let provenanceReceiptHash: String
}

enum ConnectorReconciliationDisposition: String, Codable, Hashable, Sendable {
    case inserted
    case unchanged
    case updated
    case tombstoned
    case staleIgnored = "stale_ignored"
}

struct ConnectorReconciliationResult: Codable, Hashable, Sendable {
    let selectedEnvelope: ConnectorRecordEnvelope
    let disposition: ConnectorReconciliationDisposition
    let discardedEnvelopeHashes: [String]
}

enum ConnectorRecordReconciler {
    static func reconcile(
        existing: ConnectorRecordEnvelope?,
        incoming: [ConnectorRecordEnvelope]
    ) throws -> ConnectorReconciliationResult? {
        guard !incoming.isEmpty else { return nil }
        let identities = Set(incoming.map(\.identity))
        guard identities.count == 1,
              existing.map({ identities.contains($0.identity) }) ?? true
        else { throw ConnectorEnvelopeFailureCode.conflictingRecordIdentity }

        let selectedIncoming = incoming.sorted(by: deterministicNewer).last!
        let selected: ConnectorRecordEnvelope
        let disposition: ConnectorReconciliationDisposition

        if let existing {
            if deterministicNewer(existing, selectedIncoming) {
                selected = selectedIncoming
                if selectedIncoming.canonicalEnvelopeHash == existing.canonicalEnvelopeHash {
                    disposition = .unchanged
                } else if selectedIncoming.deletionState == .tombstone {
                    disposition = .tombstoned
                } else {
                    disposition = .updated
                }
            } else {
                selected = existing
                disposition = selectedIncoming.canonicalEnvelopeHash == existing.canonicalEnvelopeHash
                    ? .unchanged
                    : .staleIgnored
            }
        } else {
            selected = selectedIncoming
            disposition = selectedIncoming.deletionState == .tombstone ? .tombstoned : .inserted
        }

        let discarded = (incoming + (existing.map { [$0] } ?? []))
            .filter { $0.canonicalEnvelopeHash != selected.canonicalEnvelopeHash }
            .map(\.canonicalEnvelopeHash)
            .sorted()
        return .init(
            selectedEnvelope: selected,
            disposition: disposition,
            discardedEnvelopeHashes: Array(Set(discarded)).sorted()
        )
    }

    static func reconcilePage(
        _ envelopes: [ConnectorRecordEnvelope],
        after previousReceipt: ConnectorPaginationReceipt?
    ) throws -> [ConnectorReconciliationResult] {
        guard let receipt = envelopes.first?.paginationReceipt else { return [] }
        try receipt.validate(after: previousReceipt)
        guard envelopes.allSatisfy({ $0.paginationReceipt == receipt }) else {
            throw ConnectorEnvelopeFailureCode.paginationReceiptMismatch
        }
        return try Dictionary(grouping: envelopes, by: \.identity)
            .sorted { $0.key.deduplicationKey < $1.key.deduplicationKey }
            .compactMap { try reconcile(existing: nil, incoming: $0.value) }
    }

    private static func deterministicNewer(
        _ lhs: ConnectorRecordEnvelope,
        _ rhs: ConnectorRecordEnvelope
    ) -> Bool {
        if lhs.sourceTimestamp != rhs.sourceTimestamp {
            return lhs.sourceTimestamp < rhs.sourceTimestamp
        }
        if lhs.deletionState != rhs.deletionState {
            return lhs.deletionState == .available
        }
        if lhs.editOrVersionIdentifier != rhs.editOrVersionIdentifier {
            return lhs.editOrVersionIdentifier < rhs.editOrVersionIdentifier
        }
        if lhs.sourceHash != rhs.sourceHash {
            return lhs.sourceHash < rhs.sourceHash
        }
        if lhs.ingestionTimestamp != rhs.ingestionTimestamp {
            return lhs.ingestionTimestamp < rhs.ingestionTimestamp
        }
        return lhs.canonicalEnvelopeHash < rhs.canonicalEnvelopeHash
    }
}

enum ConnectorTextNormalization {
    static func identifier(_ value: String) -> String {
        text(value).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func text(_ value: String) -> String {
        let canonical = value.precomposedStringWithCanonicalMapping
        let separator = UnicodeScalar(0x20)!
        let safeScalars = canonical.unicodeScalars.map { scalar in
            ConnectorEnvelopeValidation.isUnsafeScalar(scalar)
                ? separator : scalar
        }
        return String(String.UnicodeScalarView(safeScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ConnectorEnvelopeValidation {
    static func validIdentifier(
        _ value: String,
        maximumBytes: Int = ConnectorEnvelopeLimits.maximumIdentifierBytes
    ) -> Bool {
        !value.isEmpty &&
            value.lengthOfBytes(using: .utf8) <= maximumBytes &&
            !value.unicodeScalars.contains(where: isUnsafeScalar)
    }

    static func validOptionalIdentifier(_ value: String?) -> Bool {
        value.map { validIdentifier($0) } ?? true
    }

    static func validOptionalBoundedValue(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return value.lengthOfBytes(using: .utf8) <= maximumBytes &&
            !value.unicodeScalars.contains(where: isUnsafeScalar)
    }

    static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) ||
                (65...70).contains($0.value) ||
                (97...102).contains($0.value)
        }
    }

    static func isUnsafeScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) ||
            CharacterSet.illegalCharacters.contains(scalar) ||
            [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
                .contains(scalar.value)
    }
}

enum ConnectorEnvelopeDigest {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func lengthPrefixed(_ values: [String]) -> String {
        values.map { "\($0.lengthOfBytes(using: .utf8)):\($0)" }.joined(separator: "|")
    }

    static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

private extension JSONEncoder {
    static var connectorCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
