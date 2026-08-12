import CryptoKit
import Foundation
import SQLite3

enum SemanticIndexLimits {
    static let schemaVersion = 3
    static let busyTimeoutMilliseconds: Int32 = 5_000
    static let maximumIdentifierBytes = 1_024
    static let maximumModelIdentifierBytes = 512
    static let maximumVersionBytes = 128
    static let maximumSourceTextBytes = 2 * 1_024 * 1_024
    static let maximumRecordsPerBatch = 200
    static let maximumChunksPerRecord = 2_048
    static let maximumVectorDimension = 32_768
    static let maximumSearchCharacters = 1_024
    static let maximumSearchTokens = 24
    static let maximumSearchResults = 100
    static let maximumCandidateCount = 512
    static let maximumCursorBytes = 16 * 1_024
    static let maximumEmbeddingsPerWorkBatch = 16
}

enum SemanticIndexFailureCode: String, Error, Codable, Hashable, Sendable {
    case invalidDatabaseURL = "semantic_index_database_url_invalid"
    case databaseOpenFailed = "semantic_index_database_open_failed"
    case databaseBusy = "semantic_index_database_busy"
    case databaseClosed = "semantic_index_database_closed"
    case databaseCorrupt = "semantic_index_database_corrupt"
    case unsupportedSchema = "semantic_index_schema_unsupported"
    case sqliteFailure = "semantic_index_sqlite_failure"
    case invalidGeneration = "semantic_index_generation_invalid"
    case noActiveGeneration = "semantic_index_generation_missing"
    case generationStale = "semantic_index_generation_stale_rebuild_required"
    case mixedGeneration = "semantic_index_mixed_generation_rejected"
    case invalidSourceRecord = "semantic_index_source_record_invalid"
    case invalidSourceHash = "semantic_index_source_hash_invalid"
    case invalidBatch = "semantic_index_batch_invalid"
    case checkpointMismatch = "semantic_index_checkpoint_mismatch"
    case batchConflict = "semantic_index_batch_conflict"
    case invalidEmbedding = "semantic_index_embedding_invalid"
    case vectorDimensionMismatch = "semantic_index_vector_dimension_mismatch"
    case embeddingModelRequired = "semantic_index_embedding_model_required_lexical_available"
    case indexingNotPermitted = "semantic_index_automatic_indexing_not_permitted"
    case cancelled = "semantic_index_cancelled"
    case invalidSearch = "semantic_index_search_invalid"
    case queryVectorRequired = "semantic_index_query_vector_required"
    case sensitiveContentExcluded = "semantic_index_sensitive_content_excluded"
    case sourceScopeMissing = "semantic_index_source_scope_missing"
    case sourceScopeViolation = "semantic_index_source_scope_violation"
    case sourceScopeUnknown = "semantic_index_source_scope_unknown"
    case sourceNotIndexed = "semantic_search_filter_source_not_indexed"
    case signedSmokeAuthorityInvalid =
        "semantic_index_signed_smoke_authority_invalid"
}

extension SemanticIndexFailureCode: LocalizedError {
    var errorDescription: String? { rawValue }
}

enum SemanticIndexGenerationState: String, Codable, CaseIterable, Hashable, Sendable {
    case building
    case ready
    case stale
    case paused
    case corrupt
}

enum SemanticIndexStaleReason: String, Codable, CaseIterable, Hashable, Sendable {
    case embeddingRuntimeProfile = "semantic_index_embedding_runtime_profile_stale"
    case canonicalSourcePolicy = "semantic_index_canonical_source_policy_stale"
    case sourceScopeUnknown = "semantic_generation_source_scope_unknown"
    case sourceScopeChanged = "semantic_generation_source_scope_changed"
    case sourcePermissionRevoked =
        "semantic_generation_source_permission_revoked"
    case sourceScopeViolation =
        "semantic_rebuild_source_scope_violation"
    case sourceScopeRebuildRequired =
        "semantic_generation_source_scope_rebuild_required"

    var permitsLexicalFallback: Bool {
        self == .embeddingRuntimeProfile
    }
}

enum SemanticIndexSourceAuthorityState:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case sourceScopeReady = "source_scope_ready"
    case sourceScopeUnknown = "source_scope_unknown"
    case sourceScopeChanged = "source_scope_changed"
    case sourcePermissionRevoked = "source_permission_revoked"
    case sourceScopeViolation = "source_scope_violation"
    case sourceScopeRebuildRequired = "source_scope_rebuild_required"

    var staleReason: SemanticIndexStaleReason? {
        switch self {
        case .sourceScopeReady:
            nil
        case .sourceScopeUnknown:
            .sourceScopeUnknown
        case .sourceScopeChanged:
            .sourceScopeChanged
        case .sourcePermissionRevoked:
            .sourcePermissionRevoked
        case .sourceScopeViolation:
            .sourceScopeViolation
        case .sourceScopeRebuildRequired:
            .sourceScopeRebuildRequired
        }
    }
}

enum SemanticIndexRetrievalCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case lexicalOnly = "lexical_only"
    case hybrid
}

struct SemanticIndexGenerationSpec: Codable, Hashable, Sendable {
    let indexSchemaVersion: Int
    let retrievalCapability: SemanticIndexRetrievalCapability
    let embeddingModelIdentifier: String?
    let embeddingModelDigest: String?
    let vectorDimension: Int?
    let ollamaRuntimeVersion: String?
    let embeddingRequestProfileVersion: String?
    let embeddingRequestProfileHash: String?
    /// The dimensions value sent to the embedding endpoint. `nil` means the
    /// request intentionally uses the model default, not an unknown value.
    let embeddingDimensions: Int?
    let embeddingTruncate: Bool?
    let embeddingNormalizationVersion: String?
    let chunkerVersion: String
    let normalizationVersion: String
    let sourceSchemaVersion: String
    let buildScope: SemanticIndexBuildScope?

    init(
        indexSchemaVersion: Int = SemanticIndexLimits.schemaVersion,
        embeddingModelIdentifier: String,
        embeddingModelDigest: String,
        vectorDimension: Int,
        ollamaRuntimeVersion: String,
        embeddingRequestProfileVersion: String,
        embeddingRequestProfileHash: String,
        embeddingDimensions: Int?,
        embeddingTruncate: Bool,
        embeddingNormalizationVersion: String,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String,
        buildScope: SemanticIndexBuildScope
    ) throws {
        try self.init(
            indexSchemaVersion: indexSchemaVersion,
            retrievalCapability: .hybrid,
            embeddingModelIdentifier: embeddingModelIdentifier,
            embeddingModelDigest: embeddingModelDigest,
            vectorDimension: vectorDimension,
            ollamaRuntimeVersion: ollamaRuntimeVersion,
            embeddingRequestProfileVersion: embeddingRequestProfileVersion,
            embeddingRequestProfileHash: embeddingRequestProfileHash,
            embeddingDimensions: embeddingDimensions,
            embeddingTruncate: embeddingTruncate,
            embeddingNormalizationVersion:
                embeddingNormalizationVersion,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            sourceSchemaVersion: sourceSchemaVersion,
            buildScope: buildScope
        )
    }

    /// Source-compatible fail-closed overload for callers that have not yet
    /// supplied explicit build authority.
    @available(
        *,
        deprecated,
        message: "Supply an explicit non-empty SemanticIndexBuildScope."
    )
    init(
        indexSchemaVersion: Int = SemanticIndexLimits.schemaVersion,
        embeddingModelIdentifier: String,
        embeddingModelDigest: String,
        vectorDimension: Int,
        ollamaRuntimeVersion: String,
        embeddingRequestProfileVersion: String,
        embeddingRequestProfileHash: String,
        embeddingDimensions: Int?,
        embeddingTruncate: Bool,
        embeddingNormalizationVersion: String,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String
    ) throws {
        throw SemanticIndexFailureCode.sourceScopeMissing
    }

    /// Kept source-compatible so an un-updated caller fails closed instead of
    /// creating a generation whose embedding request identity is incomplete.
    @available(*, deprecated, message: "Bind the Ollama runtime and embedding request profile.")
    init(
        indexSchemaVersion: Int = SemanticIndexLimits.schemaVersion,
        embeddingModelIdentifier: String,
        embeddingModelDigest: String,
        vectorDimension: Int,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String
    ) throws {
        throw SemanticIndexFailureCode.invalidGeneration
    }

    static func lexicalOnly(
        indexSchemaVersion: Int = SemanticIndexLimits.schemaVersion,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String,
        buildScope: SemanticIndexBuildScope
    ) throws -> SemanticIndexGenerationSpec {
        try .init(
            indexSchemaVersion: indexSchemaVersion,
            retrievalCapability: .lexicalOnly,
            embeddingModelIdentifier: nil,
            embeddingModelDigest: nil,
            vectorDimension: nil,
            ollamaRuntimeVersion: nil,
            embeddingRequestProfileVersion: nil,
            embeddingRequestProfileHash: nil,
            embeddingDimensions: nil,
            embeddingTruncate: nil,
            embeddingNormalizationVersion: nil,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            sourceSchemaVersion: sourceSchemaVersion,
            buildScope: buildScope
        )
    }

    /// Source-compatible fail-closed overload for callers that have not yet
    /// supplied explicit build authority.
    @available(
        *,
        deprecated,
        message: "Supply an explicit non-empty SemanticIndexBuildScope."
    )
    static func lexicalOnly(
        indexSchemaVersion: Int = SemanticIndexLimits.schemaVersion,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String
    ) throws -> SemanticIndexGenerationSpec {
        throw SemanticIndexFailureCode.sourceScopeMissing
    }

    fileprivate init(
        indexSchemaVersion: Int,
        retrievalCapability: SemanticIndexRetrievalCapability,
        embeddingModelIdentifier: String?,
        embeddingModelDigest: String?,
        vectorDimension: Int?,
        ollamaRuntimeVersion: String?,
        embeddingRequestProfileVersion: String?,
        embeddingRequestProfileHash: String?,
        embeddingDimensions: Int?,
        embeddingTruncate: Bool?,
        embeddingNormalizationVersion: String?,
        chunkerVersion: String,
        normalizationVersion: String,
        sourceSchemaVersion: String,
        buildScope: SemanticIndexBuildScope?
    ) throws {
        if let buildScope {
            try buildScope.validateIntegrity()
        }
        let embeddingContractIsValid: Bool
        switch retrievalCapability {
        case .lexicalOnly:
            embeddingContractIsValid =
                embeddingModelIdentifier == nil &&
                embeddingModelDigest == nil &&
                vectorDimension == nil &&
                ollamaRuntimeVersion == nil &&
                embeddingRequestProfileVersion == nil &&
                embeddingRequestProfileHash == nil &&
                embeddingDimensions == nil &&
                embeddingTruncate == nil &&
                embeddingNormalizationVersion == nil
        case .hybrid:
            embeddingContractIsValid =
                embeddingModelIdentifier.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes: SemanticIndexLimits.maximumModelIdentifierBytes
                    )
                } == true &&
                embeddingModelDigest.map(SemanticIndexValidation.validSHA256) == true &&
                vectorDimension.map {
                    (1...SemanticIndexLimits.maximumVectorDimension).contains($0)
                } == true &&
                ollamaRuntimeVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes: SemanticIndexLimits.maximumVersionBytes
                    )
                } == true &&
                embeddingRequestProfileVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes: SemanticIndexLimits.maximumVersionBytes
                    )
                } == true &&
                embeddingRequestProfileHash.map(SemanticIndexValidation.validSHA256) == true &&
                (embeddingDimensions.map {
                    (1...SemanticIndexLimits.maximumVectorDimension).contains($0) &&
                        $0 == vectorDimension
                } ?? true) &&
                embeddingTruncate != nil &&
                embeddingNormalizationVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumVersionBytes
                    )
                } == true
        }
        guard indexSchemaVersion == SemanticIndexLimits.schemaVersion,
              embeddingContractIsValid,
              SemanticIndexValidation.validIdentifier(
                chunkerVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                normalizationVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                sourceSchemaVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              )
        else { throw SemanticIndexFailureCode.invalidGeneration }

        self.indexSchemaVersion = indexSchemaVersion
        self.retrievalCapability = retrievalCapability
        self.embeddingModelIdentifier = embeddingModelIdentifier
        self.embeddingModelDigest = embeddingModelDigest?.lowercased()
        self.vectorDimension = vectorDimension
        self.ollamaRuntimeVersion = ollamaRuntimeVersion
        self.embeddingRequestProfileVersion = embeddingRequestProfileVersion
        self.embeddingRequestProfileHash = embeddingRequestProfileHash?.lowercased()
        self.embeddingDimensions = embeddingDimensions
        self.embeddingTruncate = embeddingTruncate
        self.embeddingNormalizationVersion =
            embeddingNormalizationVersion
        self.chunkerVersion = chunkerVersion
        self.normalizationVersion = normalizationVersion
        self.sourceSchemaVersion = sourceSchemaVersion
        self.buildScope = buildScope
    }

    var configurationFingerprint: String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                String(indexSchemaVersion),
                retrievalCapability.rawValue,
                embeddingModelIdentifier ?? "",
                embeddingModelDigest ?? "",
                vectorDimension.map(String.init) ?? "",
                ollamaRuntimeVersion ?? "",
                embeddingRequestProfileVersion ?? "",
                embeddingRequestProfileHash ?? "",
                embeddingDimensions.map(String.init) ?? "model_default",
                embeddingTruncate.map { $0 ? "true" : "false" } ?? "",
                embeddingNormalizationVersion ?? "",
                chunkerVersion,
                normalizationVersion,
                sourceSchemaVersion,
                buildScope?.identityFingerprint ?? "source_scope_unknown",
            ])
        )
    }

    fileprivate func staleReason(
        comparedTo expected: SemanticIndexGenerationSpec
    ) -> SemanticIndexStaleReason {
        guard let buildScope, let expectedScope = expected.buildScope else {
            return .sourceScopeUnknown
        }
        guard buildScope.identityFingerprint
                == expectedScope.identityFingerprint
        else {
            return .sourceScopeChanged
        }
        let canonicalSourceIdentityMatches =
            indexSchemaVersion == expected.indexSchemaVersion &&
            chunkerVersion == expected.chunkerVersion &&
            normalizationVersion == expected.normalizationVersion &&
            sourceSchemaVersion == expected.sourceSchemaVersion
        return canonicalSourceIdentityMatches
            ? .embeddingRuntimeProfile
            : .canonicalSourcePolicy
    }
}

enum SemanticIndexSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case brief
    case schedule
    case vaultRecord = "vault_record"
    case chatMessage = "chat_message"
    case slackRecord = "slack_record"
    case connectorRecord = "connector_record"

    var authorityName: String {
        switch self {
        case .brief: "briefs"
        case .schedule: "schedules"
        case .chatMessage: "chatFinalMessages"
        case .vaultRecord: "vaultRecords"
        case .slackRecord: "slackRecords"
        case .connectorRecord: "connectorRecords"
        }
    }

    static var canonicalAuthorityOrder: [Self] {
        allCases.sorted { $0.authorityName < $1.authorityName }
    }
}

enum SemanticIndexBuildInitiation:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case manualOperator = "manual_operator"
    case signedSmokeRunner = "signed_smoke_runner"
}

struct SemanticIndexBuildScope: Codable, Hashable, Sendable {
    static let currentContractVersion =
        "agent-loki.semantic-source-authority.v1"

    let sourceAuthorityContractVersion: String
    let sourceKinds: Set<SemanticIndexSourceKind>
    let allowlistSHA256: String
    let requestTimestamp: Date
    let initiation: SemanticIndexBuildInitiation
    let authorizationReceiptIdentifier: String
    let adapterContractVersions: [SemanticIndexSourceKind: String]

    init(
        sourceKinds: Set<SemanticIndexSourceKind>,
        adapterContractVersions:
            [SemanticIndexSourceKind: String],
        requestTimestamp: Date = Date(),
        initiation: SemanticIndexBuildInitiation = .manualOperator,
        authorizationReceiptIdentifier: String
    ) throws {
        let canonical = sourceKinds.sorted {
            $0.authorityName < $1.authorityName
        }
        guard !canonical.isEmpty,
              Set(adapterContractVersions.keys) == sourceKinds,
              adapterContractVersions.values.allSatisfy({
                  SemanticIndexValidation.validIdentifier(
                      $0,
                      maximumBytes:
                          SemanticIndexLimits.maximumVersionBytes
                  )
              }),
              requestTimestamp.timeIntervalSinceReferenceDate.isFinite,
              SemanticIndexValidation.validIdentifier(
                  authorizationReceiptIdentifier
              )
        else {
            throw SemanticIndexFailureCode.sourceScopeMissing
        }
        sourceAuthorityContractVersion = Self.currentContractVersion
        self.sourceKinds = sourceKinds
        allowlistSHA256 = Self.canonicalAllowlistSHA256(canonical)
        self.requestTimestamp = requestTimestamp
        self.initiation = initiation
        self.authorizationReceiptIdentifier =
            authorizationReceiptIdentifier
        self.adapterContractVersions = adapterContractVersions
    }

    var canonicalSourceKinds: [SemanticIndexSourceKind] {
        sourceKinds.sorted { $0.authorityName < $1.authorityName }
    }

    var identityFingerprint: String {
        let adapterMaterial = canonicalSourceKinds.map { kind in
            SemanticIndexDigest.lengthPrefixed([
                kind.authorityName,
                adapterContractVersions[kind] ?? "",
            ])
        }.joined()
        return SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                sourceAuthorityContractVersion,
                allowlistSHA256,
                SemanticIndexDigest.milliseconds(requestTimestamp),
                initiation.rawValue,
                authorizationReceiptIdentifier,
                adapterMaterial,
            ])
        )
    }

    func permits(_ kind: SemanticIndexSourceKind) -> Bool {
        sourceKinds.contains(kind)
    }

    func adapterContractVersion(
        for kind: SemanticIndexSourceKind
    ) -> String? {
        adapterContractVersions[kind]
    }

    func validateIntegrity() throws {
        guard sourceAuthorityContractVersion
                == Self.currentContractVersion,
              !sourceKinds.isEmpty,
              canonicalSourceKinds.count == sourceKinds.count,
              Set(adapterContractVersions.keys) == sourceKinds,
              adapterContractVersions.values.allSatisfy({
                  SemanticIndexValidation.validIdentifier(
                      $0,
                      maximumBytes:
                          SemanticIndexLimits.maximumVersionBytes
                  )
              }),
              allowlistSHA256 == Self.canonicalAllowlistSHA256(
                  canonicalSourceKinds
              ),
              requestTimestamp.timeIntervalSinceReferenceDate.isFinite,
              SemanticIndexValidation.validIdentifier(
                  authorizationReceiptIdentifier
              )
        else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
    }

    private static func canonicalAllowlistSHA256(
        _ kinds: [SemanticIndexSourceKind]
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed(
                kinds.map(\.authorityName)
            )
        )
    }
}

enum SemanticIndexSourceAuthorityEventName:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case scopeRequested = "semantic_rebuild_source_scope_requested"
    case scopeAuthorized = "semantic_rebuild_source_scope_authorized"
    case emptyScopeRejected = "semantic_rebuild_empty_scope_rejected"
    case adapterInvoked = "semantic_rebuild_source_adapter_invoked"
    case adapterSkipped = "semantic_rebuild_source_adapter_skipped"
    case recordPrepared = "semantic_rebuild_source_record_prepared"
    case scopeViolation = "semantic_rebuild_source_scope_violation"
    case generationBound = "semantic_generation_source_scope_bound"
    case scopeChanged = "semantic_generation_source_scope_changed"
    case permissionRevoked =
        "semantic_generation_source_permission_revoked"
    case scopeUnknown = "semantic_generation_source_scope_unknown"
    case searchFilterNarrowed = "semantic_search_filter_narrowed"
    case searchFilterSourceNotIndexed =
        "semantic_search_filter_source_not_indexed"
}

struct SemanticIndexSourceCountReceipt:
    Codable,
    Hashable,
    Sendable
{
    let sourceKind: SemanticIndexSourceKind
    let preparedRecordCount: Int
    let chunkCount: Int
    let indexedCount: Int
    let skippedCount: Int
    let rejectedCount: Int

    init(
        sourceKind: SemanticIndexSourceKind,
        preparedRecordCount: Int = 0,
        chunkCount: Int = 0,
        indexedCount: Int = 0,
        skippedCount: Int = 0,
        rejectedCount: Int = 0
    ) throws {
        guard preparedRecordCount >= 0,
              chunkCount >= 0,
              indexedCount >= 0,
              skippedCount >= 0,
              rejectedCount >= 0
        else {
            throw SemanticIndexFailureCode.invalidBatch
        }
        self.sourceKind = sourceKind
        self.preparedRecordCount = preparedRecordCount
        self.chunkCount = chunkCount
        self.indexedCount = indexedCount
        self.skippedCount = skippedCount
        self.rejectedCount = rejectedCount
    }
}

struct SemanticIndexSourceAuthorityReceipt:
    Codable,
    Hashable,
    Sendable
{
    let event: SemanticIndexSourceAuthorityEventName
    let sourceAuthorityContractVersion: String
    let sourceAllowlistSHA256: String
    let sourceKinds: [SemanticIndexSourceKind]
    let counts: [SemanticIndexSourceCountReceipt]
    let generationIdentifier: String?
    let status: String
    let reasonCode: String
}

enum SemanticIndexPrivacyClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case indexable
    case keychainValue = "keychain_value"
    case oauthToken = "oauth_token"
    case apiKey = "api_key"
    case privateSigningMaterial = "private_signing_material"
    case hiddenReasoning = "hidden_reasoning"
    case rawDiagnostic = "raw_diagnostic"
    case temporaryArtifact = "temporary_artifact"
    case recoveryManifest = "recovery_manifest"
    case databaseSidecar = "database_sidecar"

    var mayEnterIndex: Bool { self == .indexable }
}

struct SemanticIndexProvenance: Codable, Hashable, Sendable {
    let provider: String
    let pseudonymousAccountIdentifier: String?
    let remoteRecordIdentifier: String?
    let parentOrThreadIdentifier: String?
    let sourceURL: URL?
    let provenanceReceiptHash: String

    init(
        provider: String,
        pseudonymousAccountIdentifier: String? = nil,
        remoteRecordIdentifier: String? = nil,
        parentOrThreadIdentifier: String? = nil,
        sourceURL: URL? = nil,
        provenanceReceiptHash: String
    ) throws {
        guard SemanticIndexValidation.validIdentifier(provider),
              SemanticIndexValidation.validOptionalIdentifier(pseudonymousAccountIdentifier),
              SemanticIndexValidation.validOptionalIdentifier(remoteRecordIdentifier),
              SemanticIndexValidation.validOptionalIdentifier(parentOrThreadIdentifier),
              SemanticIndexValidation.validSHA256(provenanceReceiptHash),
              sourceURL.map({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") }) ?? true,
              sourceURL?.user == nil,
              sourceURL?.password == nil
        else { throw SemanticIndexFailureCode.invalidSourceRecord }
        self.provider = provider
        self.pseudonymousAccountIdentifier = pseudonymousAccountIdentifier
        self.remoteRecordIdentifier = remoteRecordIdentifier
        self.parentOrThreadIdentifier = parentOrThreadIdentifier
        self.sourceURL = sourceURL
        self.provenanceReceiptHash = provenanceReceiptHash.lowercased()
    }

    func validateIntegrity() throws {
        guard SemanticIndexValidation.validIdentifier(provider),
              SemanticIndexValidation.validOptionalIdentifier(pseudonymousAccountIdentifier),
              SemanticIndexValidation.validOptionalIdentifier(remoteRecordIdentifier),
              SemanticIndexValidation.validOptionalIdentifier(parentOrThreadIdentifier),
              SemanticIndexValidation.validSHA256(provenanceReceiptHash),
              provenanceReceiptHash == provenanceReceiptHash.lowercased(),
              sourceURL.map({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") }) ?? true,
              sourceURL?.user == nil,
              sourceURL?.password == nil
        else { throw SemanticIndexFailureCode.invalidSourceRecord }
    }
}

struct SemanticIndexSourceRecord: Codable, Hashable, Sendable {
    let stableSourceIdentifier: String
    let sourceKind: SemanticIndexSourceKind
    let sourceTimestamp: Date
    let text: String
    let sourceHash: String
    let isTombstone: Bool
    let privacyClassification: SemanticIndexPrivacyClassification
    let provenance: SemanticIndexProvenance

    init(
        stableSourceIdentifier: String,
        sourceKind: SemanticIndexSourceKind,
        sourceTimestamp: Date,
        text: String,
        sourceHash: String,
        isTombstone: Bool = false,
        privacyClassification: SemanticIndexPrivacyClassification = .indexable,
        provenance: SemanticIndexProvenance
    ) throws {
        guard SemanticIndexValidation.validIdentifier(stableSourceIdentifier),
              text.lengthOfBytes(using: .utf8) <= SemanticIndexLimits.maximumSourceTextBytes,
              SemanticIndexValidation.validSHA256(sourceHash),
              !(isTombstone && !text.isEmpty)
        else { throw SemanticIndexFailureCode.invalidSourceRecord }
        self.stableSourceIdentifier = stableSourceIdentifier
        self.sourceKind = sourceKind
        self.sourceTimestamp = sourceTimestamp
        self.text = text
        self.sourceHash = sourceHash.lowercased()
        self.isTombstone = isTombstone
        self.privacyClassification = privacyClassification
        self.provenance = provenance
    }

    func validateIntegrity() throws {
        guard SemanticIndexValidation.validIdentifier(stableSourceIdentifier),
              sourceTimestamp.timeIntervalSinceReferenceDate.isFinite,
              text.lengthOfBytes(using: .utf8) <= SemanticIndexLimits.maximumSourceTextBytes,
              SemanticIndexValidation.validSHA256(sourceHash),
              sourceHash == sourceHash.lowercased(),
              !(isTombstone && !text.isEmpty)
        else { throw SemanticIndexFailureCode.invalidSourceRecord }
        try provenance.validateIntegrity()
    }

    init(connectorHandoff: ConnectorIndexHandoff) throws {
        try self.init(
            stableSourceIdentifier: connectorHandoff.stableSourceIdentifier,
            sourceKind: .connectorRecord,
            sourceTimestamp: connectorHandoff.sourceTimestamp,
            text: connectorHandoff.normalizedText,
            sourceHash: connectorHandoff.sourceHash,
            provenance: .init(
                provider: connectorHandoff.provider,
                pseudonymousAccountIdentifier: connectorHandoff.pseudonymousAccountIdentifier,
                remoteRecordIdentifier: connectorHandoff.remoteRecordIdentifier,
                parentOrThreadIdentifier: connectorHandoff.parentOrThreadIdentifier,
                sourceURL: connectorHandoff.sourceURL,
                provenanceReceiptHash: connectorHandoff.provenanceReceiptHash
            )
        )
    }

    static func deterministicSourceHash(
        stableSourceIdentifier: String,
        sourceKind: SemanticIndexSourceKind,
        sourceTimestamp: Date,
        text: String
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                stableSourceIdentifier,
                sourceKind.rawValue,
                SemanticIndexDigest.milliseconds(sourceTimestamp),
                SemanticTextNormalizer.normalize(text),
            ])
        )
    }
}

enum SemanticIndexTrigger: Codable, Hashable, Sendable {
    case manual
    case automatic(isOnBattery: Bool)
}

struct SemanticIndexSchedulingPolicy: Codable, Hashable, Sendable {
    let automaticIndexingEnabled: Bool
    let automaticIndexingOnBatteryEnabled: Bool

    init(
        automaticIndexingEnabled: Bool = false,
        automaticIndexingOnBatteryEnabled: Bool = false
    ) {
        self.automaticIndexingEnabled = automaticIndexingEnabled
        self.automaticIndexingOnBatteryEnabled = automaticIndexingOnBatteryEnabled
    }

    func permits(_ trigger: SemanticIndexTrigger) -> Bool {
        switch trigger {
        case .manual:
            true
        case let .automatic(isOnBattery):
            automaticIndexingEnabled && (!isOnBattery || automaticIndexingOnBatteryEnabled)
        }
    }
}

struct SemanticIndexBatchRequest: Codable, Hashable, Sendable {
    let runIdentifier: String
    let streamIdentifier: String
    let currentCursor: String?
    let nextCursor: String?
    let sourceHighWatermark: String?
    let isFinalBatch: Bool
    let trigger: SemanticIndexTrigger
    let sourceKind: SemanticIndexSourceKind
    let adapterContractVersion: String
    let sourceAllowlistSHA256: String
    let authorizationReceiptIdentifier: String
    let records: [SemanticIndexSourceRecord]

    init(
        runIdentifier: String,
        streamIdentifier: String,
        currentCursor: String?,
        nextCursor: String?,
        sourceHighWatermark: String?,
        isFinalBatch: Bool,
        sourceKind: SemanticIndexSourceKind,
        adapterContractVersion: String,
        sourceAllowlistSHA256: String,
        authorizationReceiptIdentifier: String,
        trigger: SemanticIndexTrigger = .manual,
        records: [SemanticIndexSourceRecord]
    ) throws {
        guard SemanticIndexValidation.validIdentifier(runIdentifier),
              SemanticIndexValidation.validIdentifier(streamIdentifier),
              SemanticIndexValidation.validOptionalBoundedValue(
                currentCursor,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              SemanticIndexValidation.validOptionalBoundedValue(
                nextCursor,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              SemanticIndexValidation.validOptionalBoundedValue(
                sourceHighWatermark,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              records.count <= SemanticIndexLimits.maximumRecordsPerBatch,
              !records.isEmpty || isFinalBatch,
              (!isFinalBatch || nextCursor == nil),
              !(nextCursor != nil && nextCursor == currentCursor),
              SemanticIndexValidation.validIdentifier(
                  adapterContractVersion,
                  maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validSHA256(
                  sourceAllowlistSHA256
              ),
              SemanticIndexValidation.validIdentifier(
                  authorizationReceiptIdentifier
              )
        else { throw SemanticIndexFailureCode.invalidBatch }
        self.runIdentifier = runIdentifier
        self.streamIdentifier = streamIdentifier
        self.currentCursor = currentCursor
        self.nextCursor = nextCursor
        self.sourceHighWatermark = sourceHighWatermark
        self.isFinalBatch = isFinalBatch
        self.trigger = trigger
        self.sourceKind = sourceKind
        self.adapterContractVersion = adapterContractVersion
        self.sourceAllowlistSHA256 = sourceAllowlistSHA256.lowercased()
        self.authorizationReceiptIdentifier =
            authorizationReceiptIdentifier
        self.records = records
    }
}

enum SemanticIndexPreparedActionKind: String, Codable, Hashable, Sendable {
    case replace
    case tombstone
    case unchanged
    case exclude
}

struct SemanticIndexPreparedChunk: Codable, Hashable, Sendable {
    let chunkIdentifier: String
    let chunkIndex: Int
    let chunkHash: String
    let normalizedText: String
}

struct SemanticIndexPreparedSource: Codable, Hashable, Sendable {
    let record: SemanticIndexSourceRecord
    let action: SemanticIndexPreparedActionKind
    let previousSourceState: String?
    let chunks: [SemanticIndexPreparedChunk]
}

struct SemanticIndexEmbeddingWorkItem: Codable, Hashable, Sendable {
    let chunkIdentifier: String
    let normalizedText: String
}

struct SemanticIndexEmbeddingWorkBatch: Codable, Hashable, Sendable {
    let generationIdentifier: String
    let planDigest: String
    let ordinal: Int
    let expectedVectorDimension: Int
    let items: [SemanticIndexEmbeddingWorkItem]

    var inputs: [String] {
        items.map(\.normalizedText)
    }

    func keyedFloatVectors(from orderedVectors: [[Double]]) throws -> [String: [Float]] {
        guard orderedVectors.count == items.count else {
            throw SemanticIndexFailureCode.invalidEmbedding
        }
        var result: [String: [Float]] = [:]
        result.reserveCapacity(items.count)
        for (item, vector) in zip(items, orderedVectors) {
            guard vector.count == expectedVectorDimension else {
                throw SemanticIndexFailureCode.vectorDimensionMismatch
            }
            guard vector.allSatisfy(\.isFinite) else {
                throw SemanticIndexFailureCode.invalidEmbedding
            }
            let converted = vector.map(Float.init)
            guard converted.allSatisfy(\.isFinite),
                  converted.contains(where: { $0 != 0 }),
                  result.updateValue(converted, forKey: item.chunkIdentifier) == nil
            else {
                throw SemanticIndexFailureCode.invalidEmbedding
            }
        }
        return result
    }
}

struct SemanticIndexResourceForecast: Codable, Hashable, Sendable {
    let recordCount: Int
    let chunkCount: Int
    let vectorCount: Int
    let estimatedVectorBytes: Int
    let estimatedTextBytes: Int
    let isAdvisory: Bool
}

struct SemanticIndexPreparedBatch: Codable, Hashable, Sendable {
    let generationIdentifier: String
    let configurationFingerprint: String
    let retrievalCapability: SemanticIndexRetrievalCapability
    let expectedVectorDimension: Int?
    let request: SemanticIndexBatchRequest
    let sources: [SemanticIndexPreparedSource]
    let planDigest: String
    let resourceForecast: SemanticIndexResourceForecast

    var chunksRequiringEmbeddings: [SemanticIndexPreparedChunk] {
        retrievalCapability == .hybrid ? sources.flatMap(\.chunks) : []
    }

    func embeddingWorkBatches(
        maximumBatchSize: Int = SemanticIndexLimits.maximumEmbeddingsPerWorkBatch
    ) throws -> [SemanticIndexEmbeddingWorkBatch] {
        guard (1...SemanticIndexLimits.maximumEmbeddingsPerWorkBatch)
            .contains(maximumBatchSize)
        else {
            throw SemanticIndexFailureCode.invalidBatch
        }
        guard retrievalCapability == .hybrid else {
            guard expectedVectorDimension == nil else {
                throw SemanticIndexFailureCode.mixedGeneration
            }
            return []
        }
        guard let expectedVectorDimension else {
            throw SemanticIndexFailureCode.mixedGeneration
        }

        let chunks = chunksRequiringEmbeddings
        return stride(from: 0, to: chunks.count, by: maximumBatchSize)
            .enumerated()
            .map { ordinal, offset in
                let upperBound = min(offset + maximumBatchSize, chunks.count)
                return SemanticIndexEmbeddingWorkBatch(
                    generationIdentifier: generationIdentifier,
                    planDigest: planDigest,
                    ordinal: ordinal,
                    expectedVectorDimension: expectedVectorDimension,
                    items: chunks[offset..<upperBound].map {
                        SemanticIndexEmbeddingWorkItem(
                            chunkIdentifier: $0.chunkIdentifier,
                            normalizedText: $0.normalizedText
                        )
                    }
                )
            }
    }
}

enum SemanticIndexCheckpointState: String, Codable, CaseIterable, Hashable, Sendable {
    case preparing
    case awaitingEmbeddings = "awaiting_embeddings"
    case running
    case paused
    case cancelled
    case complete
}

struct SemanticIndexProgress: Codable, Hashable, Sendable {
    let runIdentifier: String
    let generationIdentifier: String
    let streamIdentifier: String
    let sourceKind: SemanticIndexSourceKind
    let adapterContractVersion: String
    let sourceAllowlistSHA256: String
    let authorizationReceiptIdentifier: String
    let state: SemanticIndexCheckpointState
    let currentCursor: String?
    let nextCursor: String?
    let sourceHighWatermark: String?
    let batchesCommitted: Int
    let recordsSeen: Int
    let recordsCommitted: Int
    let recordsUnchanged: Int
    let recordsExcluded: Int
    let tombstonesCommitted: Int
    let chunksCommitted: Int
    let pendingChunkCount: Int
    let updatedAt: Date
}

struct SemanticIndexBatchCommitResult: Codable, Hashable, Sendable {
    let progress: SemanticIndexProgress
    let recordsInsertedOrUpdated: Int
    let recordsUnchanged: Int
    let recordsExcluded: Int
    let tombstonesApplied: Int
    let chunksStored: Int
}

struct SemanticIndexGenerationMetadata: Codable, Hashable, Sendable {
    let identifier: String
    let spec: SemanticIndexGenerationSpec
    let createdAt: Date
    let state: SemanticIndexGenerationState
    let staleReason: SemanticIndexStaleReason?
    let sourceAuthorityState: SemanticIndexSourceAuthorityState
    let sourceHighWatermarks: [String: String]
    let sourceRecordHashes: [String: String]
    let sourceManifestDigest: String
    let sourceCount: Int
    let chunkCount: Int
    let tombstoneCount: Int
}

enum SemanticIndexHealthState: String, Codable, CaseIterable, Hashable, Sendable {
    case empty
    case building
    case ready
    case lexicalOnly = "lexical_only"
    case stale
    case paused
    case degraded
    case corrupt
}

struct SemanticIndexHealth: Codable, Hashable, Sendable {
    let state: SemanticIndexHealthState
    let reasonCode: String
    let ftsAvailable: Bool
    let activeGeneration: SemanticIndexGenerationMetadata?
    let progress: [SemanticIndexProgress]
}

enum SemanticSearchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case lexical
    case semantic
    case hybrid
}

struct SemanticSearchFilters: Codable, Hashable, Sendable {
    let sourceKinds: Set<SemanticIndexSourceKind>
    let startDate: Date?
    let endDate: Date?
    let provider: String?

    init(
        sourceKinds: Set<SemanticIndexSourceKind> = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        provider: String? = nil
    ) {
        self.sourceKinds = sourceKinds
        self.startDate = startDate
        self.endDate = endDate
        self.provider = provider
    }
}

enum SemanticSearchSourceFilterState:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case ready
    case sourceNotIndexed = "source_not_indexed"
}

struct SemanticSearchFilterResolution:
    Codable,
    Hashable,
    Sendable
{
    let state: SemanticSearchSourceFilterState
    let requestedSourceKinds: Set<SemanticIndexSourceKind>
    let effectiveSourceKinds: Set<SemanticIndexSourceKind>
    let unindexedSourceKinds: Set<SemanticIndexSourceKind>
}

enum SemanticSearchSimilarityClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case strong
    case moderate
    case weak
    case lexicalOnly = "lexical_only"
}

struct SemanticSearchProvenance: Codable, Hashable, Sendable {
    let stableSourceIdentifier: String
    let sourceKind: SemanticIndexSourceKind
    let sourceTimestamp: Date
    let provider: String
    let pseudonymousAccountIdentifier: String?
    let remoteRecordIdentifier: String?
    let parentOrThreadIdentifier: String?
    let sourceURL: URL?
    let provenanceReceiptHash: String
    let sourceHash: String
}

struct SemanticSearchResult: Codable, Hashable, Sendable {
    let chunkIdentifier: String
    let matchedText: String
    let score: Double
    let lexicalScore: Double?
    let cosineSimilarity: Double?
    let similarityClassification: SemanticSearchSimilarityClassification
    let provenance: SemanticSearchProvenance
}

enum SemanticTextNormalizer {
    static let version = "loki_semantic_normalizer_v1"

    static func normalize(_ value: String) -> String {
        let canonical = value.precomposedStringWithCanonicalMapping
        var output = String.UnicodeScalarView()
        var previousWasWhitespace = true
        for scalar in canonical.unicodeScalars {
            if SemanticIndexValidation.isUnsafeScalar(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                if !previousWasWhitespace {
                    output.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                output.append(scalar)
                previousWasWhitespace = false
            }
        }
        return String(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lexicalTokens(
        _ value: String,
        maximumTokens: Int = SemanticIndexLimits.maximumSearchTokens
    ) -> [String] {
        let lowered = normalize(value)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        var seen = Set<String>()
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(max(1, maximumTokens))
            .map { $0 }
    }
}

enum SemanticTextChunker {
    static let version = "loki_whitespace_chunker_160_24_v1"
    static let maximumTokens = 160
    static let overlapTokens = 24

    struct Chunk: Codable, Hashable, Sendable {
        let index: Int
        let text: String
        let hash: String
    }

    static func chunks(normalizedText: String) -> [Chunk] {
        let tokens = normalizedText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var values: [Chunk] = []
        var start = 0
        while start < tokens.count && values.count < SemanticIndexLimits.maximumChunksPerRecord {
            let end = min(start + maximumTokens, tokens.count)
            let text = tokens[start..<end].joined(separator: " ")
            values.append(.init(
                index: values.count,
                text: text,
                hash: SemanticIndexDigest.sha256(text)
            ))
            guard end < tokens.count else { break }
            start = max(start + 1, end - overlapTokens)
        }
        return values
    }
}

actor SemanticVaultIndex {
    fileprivate enum SQLValue {
        case text(String)
        case integer(Int64)
        case blob(Data)
        case null
    }

    fileprivate struct Bootstrap {
        let connection: OpaquePointer
        let ftsAvailable: Bool
    }

    fileprivate struct LegacyGenerationV1 {
        let identifier: String
        let retrievalCapability: SemanticIndexRetrievalCapability
        let embeddingModelIdentifier: String?
        let embeddingModelDigest: String?
        let vectorDimension: Int?
        let chunkerVersion: String
        let normalizationVersion: String
        let sourceSchemaVersion: String
        let configurationFingerprint: String
        let state: SemanticIndexGenerationState
        let sourceManifestDigest: String
    }

    fileprivate struct LegacyGenerationV2 {
        let identifier: String
        let retrievalCapability: SemanticIndexRetrievalCapability
        let embeddingModelIdentifier: String?
        let embeddingModelDigest: String?
        let vectorDimension: Int?
        let ollamaRuntimeVersion: String?
        let embeddingRequestProfileVersion: String?
        let embeddingRequestProfileHash: String?
        let embeddingDimensions: Int?
        let embeddingTruncate: Bool?
        let embeddingNormalizationVersion: String?
        let chunkerVersion: String
        let normalizationVersion: String
        let sourceSchemaVersion: String
        let configurationFingerprint: String
        let state: SemanticIndexGenerationState
        let staleReason: SemanticIndexStaleReason?
        let sourceManifestDigest: String
    }

    fileprivate struct StoredSourceState {
        let sourceHash: String
        let tombstoned: Bool

        var stableValue: String {
            "\(sourceHash)|\(tombstoned ? "tombstone" : "available")"
        }
    }

    fileprivate struct Candidate {
        let chunkIdentifier: String
        let sourceIdentifier: String
        let normalizedText: String
        let vector: [Float]?
        let sourceKind: SemanticIndexSourceKind
        let sourceTimestamp: Date
        let provider: String
        let pseudonymousAccountIdentifier: String?
        let remoteRecordIdentifier: String?
        let parentOrThreadIdentifier: String?
        let sourceURL: URL?
        let provenanceReceiptHash: String
        let sourceHash: String
    }

    fileprivate struct CandidateFilterClause {
        let sql: String
        let binds: [SQLValue]
    }

    private var connection: OpaquePointer?
    private let databaseURL: URL?
    private let isInMemory: Bool
    private let signedSmokeStorageBoundary:
        P8FSignedSmokeStorageBoundary?
    private let signedSmokeRuntimeAuthority:
        P8FSignedSmokeRuntimeAuthority?
    private let signedSmokeConstructionIssuer:
        P8FSignedSmokeSemanticIndexConstructionIssuer?
    private let signedSmokeConstructionProfile:
        P8FSignedSmokeSemanticIndexConstructionProfile?
    private let signedSmokeStorageIdentity:
        P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot?
    private let schedulingPolicy: SemanticIndexSchedulingPolicy
    private let now: @Sendable () -> Date
    private let publishLifecycleIsValid: @Sendable () -> Bool
    private let finalPublicationValidator:
        @Sendable (
            SemanticIndexGenerationMetadata,
            String?
        ) throws -> Void
    private(set) var ftsAvailable: Bool

    /// Stable file identity used to bind an injected index to an admitted
    /// signed-smoke database path. In-memory indexes intentionally expose nil.
    nonisolated var persistentDatabaseURL: URL? {
        databaseURL
    }

    init(
        url: URL,
        signedSmokeStorageBoundary:
            P8FSignedSmokeStorageBoundary? = nil,
        signedSmokeRuntimeAuthority:
            P8FSignedSmokeRuntimeAuthority? = nil,
        schedulingPolicy: SemanticIndexSchedulingPolicy = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        forceLexicalFallback: Bool = false,
        finalPublicationValidator:
            @escaping @Sendable (
                SemanticIndexGenerationMetadata,
                String?
            ) throws -> Void = { _, _ in },
        publishLifecycleIsValid:
            @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) throws {
        guard signedSmokeStorageBoundary == nil,
              signedSmokeRuntimeAuthority == nil
        else {
            // File-backed signed-smoke indexes are package-issued through the
            // dedicated construction-authority initializer below. Raw callers
            // cannot combine authority with arbitrary lifecycle closures.
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let bootstrap = try Self.bootstrap(
            url: url,
            inMemory: false,
            signedSmokeStorageBoundary:
                signedSmokeStorageBoundary,
            forceLexicalFallback: forceLexicalFallback
        )
        let storageIdentity:
            P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot?
        do {
            storageIdentity = try signedSmokeStorageBoundary?
                .captureSQLiteIdentity(at: url)
        } catch {
            sqlite3_close_v2(bootstrap.connection)
            throw error
        }
        connection = bootstrap.connection
        databaseURL = signedSmokeStorageBoundary == nil
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : LokiCanonicalFileURL.lexical(url)
        isInMemory = false
        self.signedSmokeStorageBoundary =
            signedSmokeStorageBoundary
        self.signedSmokeRuntimeAuthority =
            signedSmokeRuntimeAuthority
        signedSmokeConstructionIssuer = nil
        signedSmokeConstructionProfile = nil
        signedSmokeStorageIdentity = storageIdentity
        self.schedulingPolicy = schedulingPolicy
        self.now = now
        self.publishLifecycleIsValid = publishLifecycleIsValid
        self.finalPublicationValidator = finalPublicationValidator
        ftsAvailable = bootstrap.ftsAvailable
    }

    init(
        inMemory: Bool,
        signedSmokeRuntimeAuthority:
            P8FSignedSmokeRuntimeAuthority? = nil,
        schedulingPolicy: SemanticIndexSchedulingPolicy = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        forceLexicalFallback: Bool = false,
        finalPublicationValidator:
            @escaping @Sendable (
                SemanticIndexGenerationMetadata,
                String?
            ) throws -> Void = { _, _ in },
        publishLifecycleIsValid:
            @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) throws {
        precondition(inMemory, "Use init(url:) for a file-backed semantic index.")
        if let signedSmokeRuntimeAuthority,
           !signedSmokeRuntimeAuthority.permitsInMemoryIndex {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let bootstrap = try Self.bootstrap(
            url: nil,
            inMemory: true,
            signedSmokeStorageBoundary: nil,
            forceLexicalFallback: forceLexicalFallback
        )
        connection = bootstrap.connection
        databaseURL = nil
        isInMemory = true
        signedSmokeStorageBoundary = nil
        self.signedSmokeRuntimeAuthority =
            signedSmokeRuntimeAuthority
        signedSmokeStorageIdentity = nil
        signedSmokeConstructionIssuer = nil
        signedSmokeConstructionProfile = nil
        self.schedulingPolicy = schedulingPolicy
        self.now = now
        self.publishLifecycleIsValid = publishLifecycleIsValid
        self.finalPublicationValidator = finalPublicationValidator
        ftsAvailable = bootstrap.ftsAvailable
    }

    /// Package-only signed-smoke construction route. The authority token has a
    /// file-private initializer and is never exposed by its issuing package.
    /// Every behavior-capable closure is selected from a closed profile here.
    init(
        signedSmokeURL url: URL,
        constructionAuthority:
            P8FSignedSmokeSemanticIndexConstructionAuthority
    ) throws {
        let storageBoundary = constructionAuthority.storageBoundary
        let runtimeAuthority = constructionAuthority.runtimeAuthority
        guard runtimeAuthority.matches(
            storageBoundary: storageBoundary
        ) else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        let bootstrap = try Self.bootstrap(
            url: url,
            inMemory: false,
            signedSmokeStorageBoundary: storageBoundary,
            forceLexicalFallback: false
        )
        let storageIdentity:
            P8FSignedSmokeStorageBoundary.SQLiteIdentitySnapshot
        do {
            storageIdentity = try storageBoundary
                .captureSQLiteIdentity(at: url)
        } catch {
            sqlite3_close_v2(bootstrap.connection)
            throw error
        }
        connection = bootstrap.connection
        databaseURL = LokiCanonicalFileURL.lexical(url)
        isInMemory = false
        signedSmokeStorageBoundary = storageBoundary
        signedSmokeRuntimeAuthority = runtimeAuthority
        signedSmokeStorageIdentity = storageIdentity
        signedSmokeConstructionIssuer = constructionAuthority.issuer
        signedSmokeConstructionProfile =
            constructionAuthority.profile
        schedulingPolicy = SemanticIndexSchedulingPolicy()
        now = { Date() }
        publishLifecycleIsValid = { !Task.isCancelled }
        switch constructionAuthority.profile {
        case .runtime:
            finalPublicationValidator = { _, _ in }
        case .rejectSuccessorPublicationForIntegrityDiagnostic:
            finalPublicationValidator = { _, priorIdentifier in
                if priorIdentifier != nil {
                    throw P8FSignedSmokeSemanticIndexDiagnosticFailure
                        .successorPublicationRejected
                }
            }
#if DEBUG
        case .replaceDirectoryBeforeSuccessorPublicationForIntegrityDiagnostic:
            let directory = LokiCanonicalFileURL.lexical(
                url.deletingLastPathComponent(),
                isDirectory: true
            )
            let backup = directory.deletingLastPathComponent()
                .appendingPathComponent(
                    directory.lastPathComponent
                        + ".publication-original",
                    isDirectory: true
                )
            finalPublicationValidator = { _, priorIdentifier in
                guard priorIdentifier != nil else { return }
                let fileManager = FileManager.default
                try fileManager.moveItem(at: directory, to: backup)
                do {
                    try fileManager.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    try? fileManager.moveItem(at: backup, to: directory)
                    throw error
                }
            }
#endif
        }
        ftsAvailable = bootstrap.ftsAvailable
    }

    /// Requires exact object identity with the authority bound when the index
    /// was created, then revalidates its descriptor-frozen storage identity.
    /// P8FeatureController uses this to reject injected indexes that merely
    /// point at the same pathname.
    nonisolated func validateSignedSmokeRuntimeAuthority(
        _ authority: P8FSignedSmokeRuntimeAuthority
    ) throws {
        guard let bound = signedSmokeRuntimeAuthority,
              bound === authority
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        if isInMemory {
            guard authority.permitsInMemoryIndex else {
                throw SemanticIndexFailureCode
                    .signedSmokeAuthorityInvalid
            }
            return
        }
        guard let boundary = signedSmokeStorageBoundary,
              let identity = signedSmokeStorageIdentity,
              let databaseURL,
              authority.matches(storageBoundary: boundary)
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        do {
            try boundary.validateSQLiteIdentity(
                identity,
                at: databaseURL
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    nonisolated func validateSignedSmokeConstructionAuthority(
        issuer: P8FSignedSmokeSemanticIndexConstructionIssuer,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws {
        guard signedSmokeRuntimeAuthority === runtimeAuthority,
              signedSmokeConstructionIssuer === issuer,
              signedSmokeConstructionProfile != nil
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try validateSignedSmokeRuntimeAuthority(runtimeAuthority)
    }

    nonisolated var signedSmokeIssuedConstructionProfile:
        P8FSignedSmokeSemanticIndexConstructionProfile?
    {
        signedSmokeConstructionProfile
    }

    deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    func close() {
        guard let connection else { return }
        sqlite3_close_v2(connection)
        self.connection = nil
    }

    /// Clears only rebuildable derived state. Canonical SwiftData, Vault, and
    /// connector stores are never opened or mutated by this actor.
    func deleteAllDerivedData() throws {
        let db = try activeConnection()
        try Self.withTransaction(db) {
            if ftsAvailable {
                try Self.execute(db, sql: "DELETE FROM semantic_chunks_fts")
            }
            try Self.execute(db, sql: "DELETE FROM semantic_checkpoints")
            try Self.execute(db, sql: "DELETE FROM semantic_high_watermarks")
            try Self.execute(db, sql: "DELETE FROM semantic_generations")
            try Self.execute(
                db,
                sql: "DELETE FROM semantic_metadata WHERE key = 'active_generation'"
            )
        }
    }

    // MARK: - Generation lifecycle

    @discardableResult
    func beginGeneration(
        spec: SemanticIndexGenerationSpec,
        rebuilding: Bool = false
    ) throws -> SemanticIndexGenerationMetadata {
        guard let buildScope = spec.buildScope else {
            throw SemanticIndexFailureCode.sourceScopeMissing
        }
        try buildScope.validateIntegrity()
        try validateSignedSmokeInitiation(buildScope)
        let canonicalSpec = try SemanticIndexGenerationSpec(
            indexSchemaVersion: spec.indexSchemaVersion,
            retrievalCapability: spec.retrievalCapability,
            embeddingModelIdentifier: spec.embeddingModelIdentifier,
            embeddingModelDigest: spec.embeddingModelDigest,
            vectorDimension: spec.vectorDimension,
            ollamaRuntimeVersion: spec.ollamaRuntimeVersion,
            embeddingRequestProfileVersion: spec.embeddingRequestProfileVersion,
            embeddingRequestProfileHash: spec.embeddingRequestProfileHash,
            embeddingDimensions: spec.embeddingDimensions,
            embeddingTruncate: spec.embeddingTruncate,
            embeddingNormalizationVersion:
                spec.embeddingNormalizationVersion,
            chunkerVersion: spec.chunkerVersion,
            normalizationVersion: spec.normalizationVersion,
            sourceSchemaVersion: spec.sourceSchemaVersion,
            buildScope: buildScope
        )
        guard canonicalSpec == spec else {
            throw SemanticIndexFailureCode.invalidGeneration
        }
        let db = try activeConnection()
        if let active = try activeGenerationIdentifier(db),
           let current = try generationMetadata(identifier: active, db: db) {
            if current.spec.configurationFingerprint == spec.configurationFingerprint,
               !rebuilding {
                guard current.state != .stale else {
                    throw SemanticIndexFailureCode.generationStale
                }
                return current
            }
            if !rebuilding {
                _ = try markGenerationStale(
                    identifier: active,
                    current: current,
                    reason: current.spec.staleReason(comparedTo: spec),
                    db: db
                )
                throw SemanticIndexFailureCode.generationStale
            }
        }

        let createdAt = now()
        let identifier = SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                spec.configurationFingerprint,
                buildScope.identityFingerprint,
                SemanticIndexDigest.milliseconds(createdAt),
            ])
        )
        let emptyManifest = Self.bindingDigest(
            configurationFingerprint: spec.configurationFingerprint,
            sourceBindings: [:],
            highWatermarks: [:]
        )

        try Self.withTransaction(db) {
            if rebuilding {
                try discardNonactiveIncompleteGenerations(db: db)
            }
            try Self.execute(
                db,
                sql: """
                    INSERT INTO semantic_generations(
                        id, index_schema_version, retrieval_capability,
                        embedding_model_identifier, embedding_model_digest,
                        vector_dimension, ollama_runtime_version,
                        embedding_request_profile_version,
                        embedding_request_profile_hash,
                        embedding_dimensions, embedding_truncate,
                        embedding_normalization_version,
                        chunker_version,
                        normalization_version, source_schema_version,
                        configuration_fingerprint, created_at, state,
                        stale_reason, source_manifest_digest,
                        source_authority_contract_version,
                        source_allowlist, source_allowlist_hash,
                        source_request_timestamp, source_build_initiation,
                        source_authorization_receipt_id,
                        source_adapter_contract_versions,
                        source_authority_state
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        stale_reason = excluded.stale_reason
                    """,
                binds: [
                    .text(identifier),
                    .integer(Int64(spec.indexSchemaVersion)),
                    .text(spec.retrievalCapability.rawValue),
                    spec.embeddingModelIdentifier.map(SQLValue.text) ?? .null,
                    spec.embeddingModelDigest.map(SQLValue.text) ?? .null,
                    spec.vectorDimension.map { .integer(Int64($0)) } ?? .null,
                    spec.ollamaRuntimeVersion.map(SQLValue.text) ?? .null,
                    spec.embeddingRequestProfileVersion.map(SQLValue.text) ?? .null,
                    spec.embeddingRequestProfileHash.map(SQLValue.text) ?? .null,
                    spec.embeddingDimensions.map { .integer(Int64($0)) } ?? .null,
                    spec.embeddingTruncate.map { .integer($0 ? 1 : 0) } ?? .null,
                    spec.embeddingNormalizationVersion
                        .map(SQLValue.text) ?? .null,
                    .text(spec.chunkerVersion),
                    .text(spec.normalizationVersion),
                    .text(spec.sourceSchemaVersion),
                    .text(spec.configurationFingerprint),
                    .integer(Self.milliseconds(createdAt)),
                    .text(SemanticIndexGenerationState.building.rawValue),
                    .null,
                    .text(emptyManifest),
                    .text(buildScope.sourceAuthorityContractVersion),
                    .text(Self.encodedSourceAllowlist(buildScope)),
                    .text(buildScope.allowlistSHA256),
                    .integer(
                        Self.milliseconds(buildScope.requestTimestamp)
                    ),
                    .text(buildScope.initiation.rawValue),
                    .text(buildScope.authorizationReceiptIdentifier),
                    .text(
                        Self.encodedAdapterContractVersions(buildScope)
                    ),
                    .text(
                        SemanticIndexSourceAuthorityState
                            .sourceScopeReady.rawValue
                    ),
                ]
            )
        }
        guard let metadata = try generationMetadata(identifier: identifier, db: db) else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        return metadata
    }

    @discardableResult
    func publishGeneration(
        _ generationIdentifier: String
    ) throws -> SemanticIndexGenerationMetadata {
        let db = try activeConnection()
        guard !Task.isCancelled, publishLifecycleIsValid() else {
            throw SemanticIndexFailureCode.cancelled
        }
        let pending = try requireWritableGeneration(
            generationIdentifier,
            db: db
        )
        if let buildScope = pending.spec.buildScope {
            try validateSignedSmokeInitiation(buildScope)
        }
        guard pending.state == .building,
              pending.sourceAuthorityState == .sourceScopeReady,
              pending.spec.buildScope != nil
        else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
        let priorActiveIdentifier =
            try activeGenerationIdentifier(db)
        return try Self.withTransactionResult(db) {
            guard try activeGenerationIdentifier(db)
                    == priorActiveIdentifier,
                  let refreshed = try generationMetadata(
                    identifier: generationIdentifier,
                    db: db
                  ),
                  refreshed.state == .building,
                  refreshed.sourceAuthorityState == .sourceScopeReady,
                  refreshed.spec.configurationFingerprint
                    == pending.spec.configurationFingerprint
            else {
                throw SemanticIndexFailureCode.mixedGeneration
            }
            try validatePublishCandidate(
                refreshed,
                db: db
            )
            try finalPublicationValidator(
                refreshed,
                priorActiveIdentifier
            )
            try validatePersistentStorageIdentity()
            if let buildScope = refreshed.spec.buildScope {
                try validateSignedSmokeInitiation(buildScope)
            }

            // This is intentionally the last fallible lifecycle boundary
            // before the active-pointer swap and old-generation deletion.
            guard !Task.isCancelled,
                  publishLifecycleIsValid(),
                  try activeGenerationIdentifier(db)
                    == priorActiveIdentifier
            else {
                throw SemanticIndexFailureCode.cancelled
            }
            try Self.execute(
                db,
                sql: """
                    UPDATE semantic_generations
                    SET state = ?, stale_reason = NULL,
                        source_authority_state = ?
                    WHERE id = ? AND state = ?
                      AND source_authority_state = ?
                    """,
                binds: [
                    .text(SemanticIndexGenerationState.ready.rawValue),
                    .text(
                        SemanticIndexSourceAuthorityState
                            .sourceScopeReady.rawValue
                    ),
                    .text(generationIdentifier),
                    .text(SemanticIndexGenerationState.building.rawValue),
                    .text(
                        SemanticIndexSourceAuthorityState
                            .sourceScopeReady.rawValue
                    ),
                ]
            )
            guard sqlite3_changes(db) == 1 else {
                throw SemanticIndexFailureCode.mixedGeneration
            }
            // No fallible operation may intervene between this final
            // descriptor/authority check and the active-pointer swap.
            try validatePersistentStorageIdentity()
            if let buildScope = refreshed.spec.buildScope {
                try validateSignedSmokeInitiation(buildScope)
            }
            try Self.execute(
                db,
                sql: """
                    INSERT INTO semantic_metadata(key, value)
                    VALUES('active_generation', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                binds: [.text(generationIdentifier)]
            )
            if ftsAvailable {
                try Self.execute(
                    db,
                    sql: """
                        DELETE FROM semantic_chunks_fts
                        WHERE generation_id <> ?
                        """,
                    binds: [.text(generationIdentifier)]
                )
            }
            try Self.execute(
                db,
                sql: "DELETE FROM semantic_generations WHERE id <> ?",
                binds: [.text(generationIdentifier)]
            )
            return SemanticIndexGenerationMetadata(
                identifier: refreshed.identifier,
                spec: refreshed.spec,
                createdAt: refreshed.createdAt,
                state: .ready,
                staleReason: nil,
                sourceAuthorityState:
                    refreshed.sourceAuthorityState,
                sourceHighWatermarks:
                    refreshed.sourceHighWatermarks,
                sourceRecordHashes:
                    refreshed.sourceRecordHashes,
                sourceManifestDigest:
                    refreshed.sourceManifestDigest,
                sourceCount: refreshed.sourceCount,
                chunkCount: refreshed.chunkCount,
                tombstoneCount: refreshed.tombstoneCount
            )
        }
    }

    /// A non-I/O health projection for the exact metadata returned by the
    /// committed publication transaction. Callers can publish irreversible
    /// evidence without introducing a new fallible database read afterward.
    func committedPublicationHealth(
        for metadata: SemanticIndexGenerationMetadata
    ) -> SemanticIndexHealth {
        let state: SemanticIndexHealthState
        let reasonCode: String
        if metadata.spec.retrievalCapability == .lexicalOnly {
            state = .lexicalOnly
            reasonCode =
                SemanticIndexFailureCode.embeddingModelRequired
                    .rawValue
        } else if ftsAvailable {
            state = .ready
            reasonCode = "semantic_index_ready"
        } else {
            state = .degraded
            reasonCode =
                "semantic_index_lexical_fallback_active"
        }
        return .init(
            state: state,
            reasonCode: reasonCode,
            ftsAvailable: ftsAvailable,
            activeGeneration: metadata,
            progress: []
        )
    }

    @discardableResult
    func completeGeneration(
        _ generationIdentifier: String
    ) throws -> SemanticIndexGenerationMetadata {
        try publishGeneration(generationIdentifier)
    }

    func activeGeneration() throws -> SemanticIndexGenerationMetadata? {
        let db = try activeConnection()
        guard let identifier = try activeGenerationIdentifier(db) else { return nil }
        return try generationMetadata(identifier: identifier, db: db)
    }

    func generation(
        identifier: String
    ) throws -> SemanticIndexGenerationMetadata? {
        guard SemanticIndexValidation.validIdentifier(identifier) else {
            throw SemanticIndexFailureCode.invalidGeneration
        }
        return try generationMetadata(
            identifier: identifier,
            db: activeConnection()
        )
    }

    func discardIncompleteGeneration(
        _ generationIdentifier: String
    ) throws {
        let db = try activeConnection()
        guard SemanticIndexValidation.validIdentifier(
            generationIdentifier
        ) else {
            throw SemanticIndexFailureCode.invalidGeneration
        }
        guard try activeGenerationIdentifier(db)
                != generationIdentifier
        else {
            throw SemanticIndexFailureCode.mixedGeneration
        }
        guard let metadata = try generationMetadata(
            identifier: generationIdentifier,
            db: db
        ) else {
            return
        }
        guard metadata.state != .ready else {
            throw SemanticIndexFailureCode.mixedGeneration
        }
        try Self.withTransaction(db) {
            if ftsAvailable {
                try Self.execute(
                    db,
                    sql: """
                        DELETE FROM semantic_chunks_fts
                        WHERE generation_id = ?
                        """,
                    binds: [.text(generationIdentifier)]
                )
            }
            try Self.execute(
                db,
                sql: "DELETE FROM semantic_generations WHERE id = ?",
                binds: [.text(generationIdentifier)]
            )
        }
    }

    @discardableResult
    func markStaleIfNeeded(for expected: SemanticIndexGenerationSpec) throws -> Bool {
        let db = try activeConnection()
        guard let identifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(identifier: identifier, db: db)
        else { return false }
        guard metadata.spec.configurationFingerprint != expected.configurationFingerprint else {
            return false
        }
        return try markGenerationStale(
            identifier: identifier,
            current: metadata,
            reason: metadata.spec.staleReason(comparedTo: expected),
            db: db
        )
    }

    /// Invalidates the active derived generation after a canonical-source
    /// permission, deletion, or high-watermark change. Canonical records are
    /// not opened or mutated; retrieval stays fail-closed until an explicit
    /// rebuild creates a new generation.
    @discardableResult
    func markActiveGenerationStale(
        reason: SemanticIndexStaleReason = .canonicalSourcePolicy
    ) throws -> Bool {
        let db = try activeConnection()
        guard let identifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(
                  identifier: identifier,
                  db: db
              )
        else { return false }
        return try markGenerationStale(
            identifier: identifier,
            current: metadata,
            reason: reason,
            db: db
        )
    }

    @discardableResult
    func markActiveGenerationSourceAuthority(
        _ state: SemanticIndexSourceAuthorityState
    ) throws -> Bool {
        guard state != .sourceScopeReady else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
        let db = try activeConnection()
        guard let identifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(
                  identifier: identifier,
                  db: db
              )
        else { return false }
        return try markGenerationSourceAuthority(
            identifier: identifier,
            current: metadata,
            state: state,
            db: db
        )
    }

    /// Invalidates only the exact active generation named by the caller.
    /// Signed-smoke containment uses this identity-bound form so a late
    /// failure cannot stale an unrelated successor generation.
    @discardableResult
    func markActiveGenerationSourceAuthority(
        _ state: SemanticIndexSourceAuthorityState,
        matching generationIdentifier: String
    ) throws -> Bool {
        guard state != .sourceScopeReady,
              SemanticIndexValidation.validIdentifier(
                generationIdentifier
              )
        else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
        let db = try activeConnection()
        guard try activeGenerationIdentifier(db)
                == generationIdentifier,
              let metadata = try generationMetadata(
                identifier: generationIdentifier,
                db: db
              )
        else {
            throw SemanticIndexFailureCode.mixedGeneration
        }
        return try markGenerationSourceAuthority(
            identifier: generationIdentifier,
            current: metadata,
            state: state,
            db: db
        )
    }

    // MARK: - Incremental, resumable indexing

    func prepareBatch(
        generationIdentifier: String,
        request: SemanticIndexBatchRequest
    ) throws -> SemanticIndexPreparedBatch {
        try Self.validate(request)
        guard schedulingPolicy.permits(request.trigger) else {
            throw SemanticIndexFailureCode.indexingNotPermitted
        }
        guard !Task.isCancelled else { throw SemanticIndexFailureCode.cancelled }
        let db = try activeConnection()
        let metadata = try requireWritableGeneration(generationIdentifier, db: db)
        try Self.validateSourceAuthority(
            request: request,
            metadata: metadata
        )
        try validateCheckpoint(request: request, generationIdentifier: generationIdentifier, db: db)

        let selected = Self.deduplicated(records: request.records)
        var prepared: [SemanticIndexPreparedSource] = []
        for record in selected {
            let prior = try storedSourceState(
                generationIdentifier: generationIdentifier,
                sourceIdentifier: record.stableSourceIdentifier,
                db: db
            )
            let previousState = prior?.stableValue
            if !record.privacyClassification.mayEnterIndex {
                let redacted = try SemanticIndexSourceRecord(
                    stableSourceIdentifier: record.stableSourceIdentifier,
                    sourceKind: record.sourceKind,
                    sourceTimestamp: record.sourceTimestamp,
                    text: "",
                    sourceHash: SemanticIndexDigest.sha256(
                        SemanticIndexDigest.lengthPrefixed([
                            "excluded",
                            record.stableSourceIdentifier,
                            record.privacyClassification.rawValue,
                        ])
                    ),
                    privacyClassification: record.privacyClassification,
                    provenance: record.provenance
                )
                prepared.append(.init(
                    record: redacted,
                    action: .exclude,
                    previousSourceState: previousState,
                    chunks: []
                ))
                continue
            }
            if record.isTombstone {
                let unchanged = prior?.sourceHash == record.sourceHash && prior?.tombstoned == true
                prepared.append(.init(
                    record: record,
                    action: unchanged ? .unchanged : .tombstone,
                    previousSourceState: previousState,
                    chunks: []
                ))
                continue
            }
            if prior?.sourceHash == record.sourceHash, prior?.tombstoned == false {
                prepared.append(.init(
                    record: record,
                    action: .unchanged,
                    previousSourceState: previousState,
                    chunks: []
                ))
                continue
            }

            let normalized = SemanticTextNormalizer.normalize(record.text)
            guard !normalized.isEmpty else { throw SemanticIndexFailureCode.invalidSourceRecord }
            let chunks = SemanticTextChunker.chunks(normalizedText: normalized).map { chunk in
                SemanticIndexPreparedChunk(
                    chunkIdentifier: SemanticIndexDigest.sha256(
                        SemanticIndexDigest.lengthPrefixed([
                            generationIdentifier,
                            record.stableSourceIdentifier,
                            record.sourceHash,
                            String(chunk.index),
                            chunk.hash,
                        ])
                    ),
                    chunkIndex: chunk.index,
                    chunkHash: chunk.hash,
                    normalizedText: chunk.text
                )
            }
            guard !chunks.isEmpty,
                  chunks.count <= SemanticIndexLimits.maximumChunksPerRecord
            else { throw SemanticIndexFailureCode.invalidSourceRecord }
            prepared.append(.init(
                record: record,
                action: .replace,
                previousSourceState: previousState,
                chunks: chunks
            ))
        }

        let forecast = SemanticIndexResourceForecast(
            recordCount: prepared.count,
            chunkCount: prepared.reduce(0) { $0 + $1.chunks.count },
            vectorCount: metadata.spec.retrievalCapability == .hybrid
                ? prepared.reduce(0) { $0 + $1.chunks.count }
                : 0,
            estimatedVectorBytes: metadata.spec.retrievalCapability == .hybrid
                ? prepared.reduce(0) { $0 + $1.chunks.count }
                    * (metadata.spec.vectorDimension ?? 0) * MemoryLayout<Float>.size
                : 0,
            estimatedTextBytes: prepared
                .flatMap(\.chunks)
                .reduce(0) { $0 + $1.normalizedText.lengthOfBytes(using: .utf8) },
            isAdvisory: true
        )
        let preparedRequest = try SemanticIndexBatchRequest(
            runIdentifier: request.runIdentifier,
            streamIdentifier: request.streamIdentifier,
            currentCursor: request.currentCursor,
            nextCursor: request.nextCursor,
            sourceHighWatermark: request.sourceHighWatermark,
            isFinalBatch: request.isFinalBatch,
            sourceKind: request.sourceKind,
            adapterContractVersion: request.adapterContractVersion,
            sourceAllowlistSHA256:
                request.sourceAllowlistSHA256,
            authorizationReceiptIdentifier:
                request.authorizationReceiptIdentifier,
            trigger: request.trigger,
            records: prepared.map(\.record)
        )
        let planDigest = Self.planDigest(
            generationIdentifier: generationIdentifier,
            configurationFingerprint: metadata.spec.configurationFingerprint,
            request: preparedRequest,
            sources: prepared
        )
        let batch = SemanticIndexPreparedBatch(
            generationIdentifier: generationIdentifier,
            configurationFingerprint: metadata.spec.configurationFingerprint,
            retrievalCapability: metadata.spec.retrievalCapability,
            expectedVectorDimension: metadata.spec.vectorDimension,
            request: preparedRequest,
            sources: prepared,
            planDigest: planDigest,
            resourceForecast: forecast
        )
        try markAwaitingEmbeddings(batch, db: db)
        return batch
    }

    func commit(
        _ batch: SemanticIndexPreparedBatch,
        embeddingsByChunkIdentifier: [String: [Float]]
    ) throws -> SemanticIndexBatchCommitResult {
        guard !Task.isCancelled else {
            try? cancel(runIdentifier: batch.request.runIdentifier)
            throw SemanticIndexFailureCode.cancelled
        }
        let db = try activeConnection()
        let metadata = try requireWritableGeneration(batch.generationIdentifier, db: db)
        try Self.validateSourceAuthority(
            request: batch.request,
            metadata: metadata
        )
        guard metadata.spec.configurationFingerprint == batch.configurationFingerprint,
              metadata.spec.retrievalCapability == batch.retrievalCapability,
              batch.planDigest == Self.planDigest(
                generationIdentifier: batch.generationIdentifier,
                configurationFingerprint: batch.configurationFingerprint,
                request: batch.request,
                sources: batch.sources
              )
        else { throw SemanticIndexFailureCode.mixedGeneration }

        let requiredChunks = batch.chunksRequiringEmbeddings
        let requiredIdentifiers = Set(requiredChunks.map(\.chunkIdentifier))
        guard Set(embeddingsByChunkIdentifier.keys) == requiredIdentifiers else {
            throw SemanticIndexFailureCode.invalidEmbedding
        }
        for chunk in requiredChunks {
            guard let expectedDimension = metadata.spec.vectorDimension else {
                throw SemanticIndexFailureCode.mixedGeneration
            }
            guard let vector = embeddingsByChunkIdentifier[chunk.chunkIdentifier],
                  vector.count == expectedDimension
            else { throw SemanticIndexFailureCode.vectorDimensionMismatch }
            guard vector.allSatisfy(\.isFinite),
                  vector.contains(where: { $0 != 0 })
            else { throw SemanticIndexFailureCode.invalidEmbedding }
        }

        let storedCheckpoint = try checkpoint(
            runIdentifier: batch.request.runIdentifier,
            db: db
        )
        guard let storedCheckpoint,
              storedCheckpoint.generationIdentifier == batch.generationIdentifier,
              storedCheckpoint.streamIdentifier == batch.request.streamIdentifier,
              storedCheckpoint.currentCursor == batch.request.currentCursor,
              storedCheckpoint.state == .awaitingEmbeddings
        else {
            if storedCheckpoint?.state == .cancelled {
                throw SemanticIndexFailureCode.cancelled
            }
            throw SemanticIndexFailureCode.checkpointMismatch
        }

        for source in batch.sources {
            let current = try storedSourceState(
                generationIdentifier: batch.generationIdentifier,
                sourceIdentifier: source.record.stableSourceIdentifier,
                db: db
            )?.stableValue
            guard current == source.previousSourceState else {
                throw SemanticIndexFailureCode.batchConflict
            }
        }

        var replaced = 0
        var unchanged = 0
        var excluded = 0
        var tombstoned = 0
        var chunksStored = 0

        try Self.withTransaction(db) {
            try Self.execute(
                db,
                sql: "UPDATE semantic_checkpoints SET state = ? WHERE run_id = ?",
                binds: [
                    .text(SemanticIndexCheckpointState.running.rawValue),
                    .text(batch.request.runIdentifier),
                ]
            )
            for source in batch.sources {
                let record = source.record
                switch source.action {
                case .unchanged:
                    unchanged += 1
                case .exclude:
                    try deleteSource(
                        generationIdentifier: batch.generationIdentifier,
                        sourceIdentifier: record.stableSourceIdentifier,
                        db: db
                    )
                    excluded += 1
                case .tombstone:
                    try deleteSourceChunks(
                        generationIdentifier: batch.generationIdentifier,
                        sourceIdentifier: record.stableSourceIdentifier,
                        db: db
                    )
                    try upsertSource(
                        record,
                        generationIdentifier: batch.generationIdentifier,
                        tombstoned: true,
                        db: db
                    )
                    tombstoned += 1
                case .replace:
                    try deleteSourceChunks(
                        generationIdentifier: batch.generationIdentifier,
                        sourceIdentifier: record.stableSourceIdentifier,
                        db: db
                    )
                    try upsertSource(
                        record,
                        generationIdentifier: batch.generationIdentifier,
                        tombstoned: false,
                        db: db
                    )
                    for chunk in source.chunks {
                        let vector: [Float]?
                        switch metadata.spec.retrievalCapability {
                        case .lexicalOnly:
                            vector = nil
                        case .hybrid:
                            guard let embedded =
                                embeddingsByChunkIdentifier[chunk.chunkIdentifier]
                            else { throw SemanticIndexFailureCode.invalidEmbedding }
                            vector = embedded
                        }
                        try insertChunk(
                            chunk,
                            vector: vector,
                            record: record,
                            generationIdentifier: batch.generationIdentifier,
                            db: db
                        )
                        chunksStored += 1
                    }
                    replaced += 1
                }
            }

            if let highWatermark = batch.request.sourceHighWatermark {
                try Self.execute(
                    db,
                    sql: """
                        INSERT INTO semantic_high_watermarks(
                            generation_id, stream_id, high_watermark
                        ) VALUES(?, ?, ?)
                        ON CONFLICT(generation_id, stream_id)
                        DO UPDATE SET high_watermark = excluded.high_watermark
                        """,
                    binds: [
                        .text(batch.generationIdentifier),
                        .text(batch.request.streamIdentifier),
                        .text(highWatermark),
                    ]
                )
            }
            let sourceBindings = try sourceBindings(
                generationIdentifier: batch.generationIdentifier,
                db: db
            )
            let highWatermarks = try sourceHighWatermarks(
                generationIdentifier: batch.generationIdentifier,
                db: db
            )
            try Self.execute(
                db,
                sql: "UPDATE semantic_generations SET source_manifest_digest = ? WHERE id = ?",
                binds: [
                    .text(Self.bindingDigest(
                        configurationFingerprint: metadata.spec.configurationFingerprint,
                        sourceBindings: sourceBindings,
                        highWatermarks: highWatermarks
                    )),
                    .text(batch.generationIdentifier),
                ]
            )

            let nextState: SemanticIndexCheckpointState =
                batch.request.isFinalBatch || batch.request.nextCursor == nil ? .complete : .running
            try Self.execute(
                db,
                sql: """
                    UPDATE semantic_checkpoints SET
                        state = ?,
                        current_cursor = ?,
                        next_cursor = ?,
                        source_high_watermark = coalesce(?, source_high_watermark),
                        batches_committed = batches_committed + 1,
                        records_seen = records_seen + ?,
                        records_committed = records_committed + ?,
                        records_unchanged = records_unchanged + ?,
                        records_excluded = records_excluded + ?,
                        tombstones_committed = tombstones_committed + ?,
                        chunks_committed = chunks_committed + ?,
                        pending_chunk_count = 0,
                        updated_at = ?
                    WHERE run_id = ?
                    """,
                binds: [
                    .text(nextState.rawValue),
                    batch.request.nextCursor.map(SQLValue.text) ?? .null,
                    batch.request.nextCursor.map(SQLValue.text) ?? .null,
                    batch.request.sourceHighWatermark.map(SQLValue.text) ?? .null,
                    .integer(Int64(batch.sources.count)),
                    .integer(Int64(replaced + tombstoned)),
                    .integer(Int64(unchanged)),
                    .integer(Int64(excluded)),
                    .integer(Int64(tombstoned)),
                    .integer(Int64(chunksStored)),
                    .integer(Self.milliseconds(now())),
                    .text(batch.request.runIdentifier),
                ]
            )
        }

        guard let progress = try checkpoint(
            runIdentifier: batch.request.runIdentifier,
            db: db
        ) else { throw SemanticIndexFailureCode.databaseCorrupt }
        return .init(
            progress: progress,
            recordsInsertedOrUpdated: replaced,
            recordsUnchanged: unchanged,
            recordsExcluded: excluded,
            tombstonesApplied: tombstoned,
            chunksStored: chunksStored
        )
    }

    func cancel(runIdentifier: String) throws {
        let db = try activeConnection()
        guard SemanticIndexValidation.validIdentifier(runIdentifier) else {
            throw SemanticIndexFailureCode.invalidBatch
        }
        if let existing = try checkpoint(runIdentifier: runIdentifier, db: db) {
            _ = try requireWritableGeneration(
                existing.generationIdentifier,
                db: db
            )
        }
        try Self.execute(
            db,
            sql: """
                UPDATE semantic_checkpoints SET
                    state = ?, pending_chunk_count = 0, updated_at = ?
                WHERE run_id = ? AND state <> 'complete'
                """,
            binds: [
                .text(SemanticIndexCheckpointState.cancelled.rawValue),
                .integer(Self.milliseconds(now())),
                .text(runIdentifier),
            ]
        )
    }

    func progress(runIdentifier: String) throws -> SemanticIndexProgress? {
        try checkpoint(runIdentifier: runIdentifier, db: activeConnection())
    }

    // MARK: - Hybrid retrieval

    func resolveSearchFilters(
        _ filters: SemanticSearchFilters
    ) throws -> SemanticSearchFilterResolution {
        let db = try activeConnection()
        guard let activeIdentifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(
                  identifier: activeIdentifier,
                  db: db
              )
        else {
            return .init(
                state: filters.sourceKinds.isEmpty
                    ? .ready
                    : .sourceNotIndexed,
                requestedSourceKinds: filters.sourceKinds,
                effectiveSourceKinds: [],
                unindexedSourceKinds: filters.sourceKinds
            )
        }
        return try Self.searchFilterResolution(
            filters,
            metadata: metadata
        )
    }

    func search(
        query: String,
        queryVector: [Float]?,
        mode: SemanticSearchMode,
        filters: SemanticSearchFilters = .init(),
        limit: Int = 20,
        candidateLimit: Int = 128
    ) throws -> [SemanticSearchResult] {
        let db = try activeConnection()
        let normalizedQuery = SemanticTextNormalizer.normalize(query)
        let tokens = SemanticTextNormalizer.lexicalTokens(normalizedQuery)
        guard !normalizedQuery.isEmpty,
              normalizedQuery.count <= SemanticIndexLimits.maximumSearchCharacters,
              !tokens.isEmpty,
              (1...SemanticIndexLimits.maximumSearchResults).contains(limit)
        else { throw SemanticIndexFailureCode.invalidSearch }

        guard let activeIdentifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(identifier: activeIdentifier, db: db)
        else { return [] }
        guard metadata.sourceAuthorityState == .sourceScopeReady,
              metadata.spec.buildScope != nil
        else {
            throw SemanticIndexFailureCode.sourceScopeUnknown
        }
        let usesStaleLexicalFallback =
            metadata.state == .stale &&
            metadata.staleReason?.permitsLexicalFallback == true &&
            mode == .lexical
        guard metadata.state == .ready || usesStaleLexicalFallback else {
            if metadata.state == .stale { throw SemanticIndexFailureCode.generationStale }
            throw SemanticIndexFailureCode.noActiveGeneration
        }
        if !usesStaleLexicalFallback {
            guard try vectorsAreValid(
                generationIdentifier: activeIdentifier,
                retrievalCapability: metadata.spec.retrievalCapability,
                expectedDimension: metadata.spec.vectorDimension,
                db: db
            ) else { throw SemanticIndexFailureCode.databaseCorrupt }
        }

        let requiresVector = mode == .semantic || mode == .hybrid
        if requiresVector {
            guard metadata.spec.retrievalCapability == .hybrid,
                  let expectedDimension = metadata.spec.vectorDimension
            else { throw SemanticIndexFailureCode.embeddingModelRequired }
            guard let queryVector else { throw SemanticIndexFailureCode.queryVectorRequired }
            guard queryVector.count == expectedDimension else {
                throw SemanticIndexFailureCode.vectorDimensionMismatch
            }
            guard queryVector.allSatisfy(\.isFinite),
                  queryVector.contains(where: { $0 != 0 })
            else { throw SemanticIndexFailureCode.invalidEmbedding }
        }

        let filterResolution = try Self.searchFilterResolution(
            filters,
            metadata: metadata
        )
        if !filters.sourceKinds.isEmpty,
           filterResolution.effectiveSourceKinds.isEmpty {
            return []
        }
        let effectiveFilters = SemanticSearchFilters(
            sourceKinds: filterResolution.effectiveSourceKinds,
            startDate: filters.startDate,
            endDate: filters.endDate,
            provider: filters.provider
        )

        let boundedCandidateCount = min(
            max(candidateLimit, limit),
            SemanticIndexLimits.maximumCandidateCount
        )
        var candidateByIdentifier: [String: Candidate] = [:]
        var lexicalScoreByIdentifier: [String: Double] = [:]

        if mode == .lexical || mode == .hybrid {
            let lexical = try lexicalCandidates(
                generationIdentifier: activeIdentifier,
                tokens: tokens,
                filters: effectiveFilters,
                limit: boundedCandidateCount,
                db: db
            )
            for (index, candidate) in lexical.enumerated() {
                candidateByIdentifier[candidate.chunkIdentifier] = candidate
                lexicalScoreByIdentifier[candidate.chunkIdentifier] = 1 / Double(index + 1)
            }
        }

        if mode == .semantic ||
            (mode == .hybrid && candidateByIdentifier.count < boundedCandidateCount) {
            let recent = try deterministicCandidates(
                generationIdentifier: activeIdentifier,
                filters: effectiveFilters,
                limit: boundedCandidateCount,
                db: db
            )
            for candidate in recent where candidateByIdentifier.count < boundedCandidateCount {
                candidateByIdentifier[candidate.chunkIdentifier] = candidate
            }
        }

        let scored = candidateByIdentifier.values.map { candidate -> SemanticSearchResult in
            let lexicalScore = lexicalScoreByIdentifier[candidate.chunkIdentifier]
            let cosine = queryVector.flatMap { query in
                candidate.vector.map { Self.cosineSimilarity(query, $0) }
            }
            let score: Double
            switch mode {
            case .lexical:
                score = lexicalScore ?? 0
            case .semantic:
                score = cosine.map(Self.normalizedCosine) ?? 0
            case .hybrid:
                score = 0.35 * (lexicalScore ?? 0) +
                    0.65 * (cosine.map(Self.normalizedCosine) ?? 0)
            }
            let classification: SemanticSearchSimilarityClassification
            if let cosine {
                if cosine >= 0.80 { classification = .strong }
                else if cosine >= 0.55 { classification = .moderate }
                else { classification = .weak }
            } else {
                classification = .lexicalOnly
            }
            return .init(
                chunkIdentifier: candidate.chunkIdentifier,
                matchedText: candidate.normalizedText,
                score: score,
                lexicalScore: lexicalScore,
                cosineSimilarity: cosine,
                similarityClassification: classification,
                provenance: .init(
                    stableSourceIdentifier: candidate.sourceIdentifier,
                    sourceKind: candidate.sourceKind,
                    sourceTimestamp: candidate.sourceTimestamp,
                    provider: candidate.provider,
                    pseudonymousAccountIdentifier: candidate.pseudonymousAccountIdentifier,
                    remoteRecordIdentifier: candidate.remoteRecordIdentifier,
                    parentOrThreadIdentifier: candidate.parentOrThreadIdentifier,
                    sourceURL: candidate.sourceURL,
                    provenanceReceiptHash: candidate.provenanceReceiptHash,
                    sourceHash: candidate.sourceHash
                )
            )
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.provenance.sourceTimestamp != $1.provenance.sourceTimestamp {
                return $0.provenance.sourceTimestamp > $1.provenance.sourceTimestamp
            }
            return $0.chunkIdentifier < $1.chunkIdentifier
        }.prefix(limit).map { $0 }
    }

    // MARK: - Health and corruption classification

    func health(expectedSpec: SemanticIndexGenerationSpec? = nil) throws -> SemanticIndexHealth {
        let db = try activeConnection()
        guard try Self.scalarText(db, sql: "PRAGMA quick_check(1)") == "ok" else {
            return .init(
                state: .corrupt,
                reasonCode: SemanticIndexFailureCode.databaseCorrupt.rawValue,
                ftsAvailable: ftsAvailable,
                activeGeneration: nil,
                progress: []
            )
        }
        guard let identifier = try activeGenerationIdentifier(db),
              let metadata = try generationMetadata(identifier: identifier, db: db)
        else {
            return .init(
                state: .empty,
                reasonCode: "semantic_index_empty",
                ftsAvailable: ftsAvailable,
                activeGeneration: nil,
                progress: []
            )
        }
        if metadata.sourceAuthorityState != .sourceScopeReady {
            return .init(
                state: .stale,
                reasonCode: (
                    metadata.sourceAuthorityState.staleReason
                        ?? .sourceScopeUnknown
                ).rawValue,
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: []
            )
        }

        let checkpoints = try allProgress(generationIdentifier: identifier, db: db)
        let computedManifest = Self.bindingDigest(
            configurationFingerprint: metadata.spec.configurationFingerprint,
            sourceBindings: try sourceBindings(
                generationIdentifier: identifier,
                db: db
            ),
            highWatermarks: metadata.sourceHighWatermarks
        )
        let vectorBytesValid = try vectorsAreValid(
            generationIdentifier: identifier,
            retrievalCapability: metadata.spec.retrievalCapability,
            expectedDimension: metadata.spec.vectorDimension,
            db: db
        )
        guard computedManifest == metadata.sourceManifestDigest, vectorBytesValid else {
            return .init(
                state: .corrupt,
                reasonCode: "semantic_index_generation_binding_corrupt",
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        }

        if let expectedSpec,
           expectedSpec.configurationFingerprint != metadata.spec.configurationFingerprint {
            let reason = metadata.staleReason ??
                metadata.spec.staleReason(comparedTo: expectedSpec)
            return .init(
                state: .stale,
                reasonCode: reason.rawValue,
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        }
        if checkpoints.contains(where: { $0.state == .cancelled || $0.state == .paused }) {
            return .init(
                state: .paused,
                reasonCode: "semantic_index_progress_paused",
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        }

        switch metadata.state {
        case .building:
            return .init(
                state: .building,
                reasonCode: "semantic_index_building",
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        case .stale:
            guard let staleReason = metadata.staleReason else {
                return .init(
                    state: .corrupt,
                    reasonCode: SemanticIndexFailureCode.databaseCorrupt.rawValue,
                    ftsAvailable: ftsAvailable,
                    activeGeneration: metadata,
                    progress: checkpoints
                )
            }
            return .init(
                state: .stale,
                reasonCode: staleReason.rawValue,
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        case .paused:
            return .init(
                state: .paused,
                reasonCode: "semantic_index_paused",
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        case .corrupt:
            return .init(
                state: .corrupt,
                reasonCode: SemanticIndexFailureCode.databaseCorrupt.rawValue,
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        case .ready:
            if metadata.spec.retrievalCapability == .lexicalOnly {
                return .init(
                    state: .lexicalOnly,
                    reasonCode: SemanticIndexFailureCode.embeddingModelRequired.rawValue,
                    ftsAvailable: ftsAvailable,
                    activeGeneration: metadata,
                    progress: checkpoints
                )
            }
            return .init(
                state: ftsAvailable ? .ready : .degraded,
                reasonCode: ftsAvailable
                    ? "semantic_index_ready"
                    : "semantic_index_lexical_fallback_active",
                ftsAvailable: ftsAvailable,
                activeGeneration: metadata,
                progress: checkpoints
            )
        }
    }

    // MARK: - Internal indexing helpers

    private func activeConnection() throws -> OpaquePointer {
        guard let connection else { throw SemanticIndexFailureCode.databaseClosed }
        try validatePersistentStorageIdentity()
        return connection
    }

    private nonisolated func validatePersistentStorageIdentity()
        throws
    {
        guard let boundary = signedSmokeStorageBoundary,
              let identity = signedSmokeStorageIdentity,
              let databaseURL
        else { return }
        do {
            try boundary.validateSQLiteIdentity(
                identity,
                at: databaseURL
            )
        } catch {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
    }

    private nonisolated func validateSignedSmokeInitiation(
        _ buildScope: SemanticIndexBuildScope
    ) throws {
        guard buildScope.initiation == .signedSmokeRunner else {
            return
        }
        guard let signedSmokeRuntimeAuthority else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try validateSignedSmokeRuntimeAuthority(
            signedSmokeRuntimeAuthority
        )
    }

    private func requireActiveGeneration(
        _ generationIdentifier: String,
        db: OpaquePointer
    ) throws {
        guard try activeGenerationIdentifier(db) == generationIdentifier else {
            throw SemanticIndexFailureCode.mixedGeneration
        }
    }

    private func requireWritableGeneration(
        _ generationIdentifier: String,
        db: OpaquePointer
    ) throws -> SemanticIndexGenerationMetadata {
        guard let metadata = try generationMetadata(identifier: generationIdentifier, db: db) else {
            throw SemanticIndexFailureCode.noActiveGeneration
        }
        guard metadata.sourceAuthorityState == .sourceScopeReady,
              metadata.spec.buildScope != nil
        else {
            throw SemanticIndexFailureCode.sourceScopeUnknown
        }
        switch metadata.state {
        case .building, .paused:
            break
        case .ready:
            try requireActiveGeneration(generationIdentifier, db: db)
        case .stale:
            throw SemanticIndexFailureCode.generationStale
        case .corrupt:
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        return metadata
    }

    private func validatePublishCandidate(
        _ metadata: SemanticIndexGenerationMetadata,
        db: OpaquePointer
    ) throws {
        guard metadata.state == .building,
              metadata.sourceAuthorityState == .sourceScopeReady,
              let scope = metadata.spec.buildScope
        else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
        try scope.validateIntegrity()

        let unfinished = try Self.scalarInt(
            db,
            sql: """
                SELECT count(*) FROM semantic_checkpoints
                WHERE generation_id = ? AND state <> 'complete'
                """,
            binds: [.text(metadata.identifier)]
        )
        guard unfinished == 0 else {
            throw SemanticIndexFailureCode.cancelled
        }

        let progress = try allProgress(
            generationIdentifier: metadata.identifier,
            db: db
        )
        guard Set(progress.map(\.sourceKind)) == scope.sourceKinds,
              progress.allSatisfy({
                  $0.state == .complete &&
                      $0.pendingChunkCount == 0 &&
                      $0.batchesCommitted > 0 &&
                      scope.adapterContractVersion(
                          for: $0.sourceKind
                      ) == $0.adapterContractVersion &&
                      $0.sourceAllowlistSHA256
                          == scope.allowlistSHA256 &&
                      $0.authorizationReceiptIdentifier
                          == scope.authorizationReceiptIdentifier
              })
        else {
            throw SemanticIndexFailureCode.checkpointMismatch
        }

        var committedByKind: [SemanticIndexSourceKind: Int] = [:]
        var tombstonesByKind: [SemanticIndexSourceKind: Int] = [:]
        var chunksByKind: [SemanticIndexSourceKind: Int] = [:]
        func accumulate(
            _ value: Int,
            for kind: SemanticIndexSourceKind,
            in totals: inout [SemanticIndexSourceKind: Int]
        ) throws {
            let (next, overflow) = totals[
                kind,
                default: 0
            ].addingReportingOverflow(value)
            guard !overflow, value >= 0 else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            totals[kind] = next
        }
        for checkpoint in progress {
            let (accountedCommitted, committedOverflow) =
                checkpoint.recordsCommitted.addingReportingOverflow(
                    checkpoint.recordsUnchanged
                )
            let (accountedRecords, excludedOverflow) =
                accountedCommitted.addingReportingOverflow(
                    checkpoint.recordsExcluded
                )
            guard !committedOverflow,
                  !excludedOverflow,
                  accountedRecords == checkpoint.recordsSeen,
                  checkpoint.tombstonesCommitted
                    <= checkpoint.recordsCommitted
            else {
                throw SemanticIndexFailureCode.checkpointMismatch
            }
            try accumulate(
                checkpoint.recordsCommitted,
                for: checkpoint.sourceKind,
                in: &committedByKind
            )
            try accumulate(
                checkpoint.tombstonesCommitted,
                for: checkpoint.sourceKind,
                in: &tombstonesByKind
            )
            try accumulate(
                checkpoint.chunksCommitted,
                for: checkpoint.sourceKind,
                in: &chunksByKind
            )
        }

        var storedSourcesByKind:
            [SemanticIndexSourceKind: Int] = [:]
        var storedTombstonesByKind:
            [SemanticIndexSourceKind: Int] = [:]
        try Self.query(
            db,
            sql: """
                SELECT source_kind, count(*), sum(tombstoned)
                FROM semantic_sources
                WHERE generation_id = ?
                GROUP BY source_kind
                ORDER BY source_kind
                """,
            binds: [.text(metadata.identifier)]
        ) { statement in
            guard let kind = SemanticIndexSourceKind(
                    rawValue: Self.text(statement, 0)
                  ),
                  scope.permits(kind)
            else {
                throw SemanticIndexFailureCode.sourceScopeViolation
            }
            storedSourcesByKind[kind] =
                Int(sqlite3_column_int64(statement, 1))
            storedTombstonesByKind[kind] =
                Int(sqlite3_column_int64(statement, 2))
        }

        var storedChunksByKind:
            [SemanticIndexSourceKind: Int] = [:]
        try Self.query(
            db,
            sql: """
                SELECT s.source_kind, count(*)
                FROM semantic_chunks c
                JOIN semantic_sources s
                  ON s.generation_id = c.generation_id
                 AND s.source_id = c.source_id
                WHERE c.generation_id = ?
                GROUP BY s.source_kind
                ORDER BY s.source_kind
                """,
            binds: [.text(metadata.identifier)]
        ) { statement in
            guard let kind = SemanticIndexSourceKind(
                    rawValue: Self.text(statement, 0)
                  ),
                  scope.permits(kind)
            else {
                throw SemanticIndexFailureCode.sourceScopeViolation
            }
            storedChunksByKind[kind] =
                Int(sqlite3_column_int64(statement, 1))
        }

        for kind in scope.canonicalSourceKinds {
            guard committedByKind[kind, default: 0]
                    == storedSourcesByKind[kind, default: 0],
                  tombstonesByKind[kind, default: 0]
                    == storedTombstonesByKind[kind, default: 0],
                  chunksByKind[kind, default: 0]
                    == storedChunksByKind[kind, default: 0]
            else {
                throw SemanticIndexFailureCode.checkpointMismatch
            }
        }
        guard storedSourcesByKind.values.reduce(0, +)
                == metadata.sourceCount,
              storedTombstonesByKind.values.reduce(0, +)
                == metadata.tombstoneCount,
              storedChunksByKind.values.reduce(0, +)
                == metadata.chunkCount
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }

        var chunksAreValid = true
        try Self.query(
            db,
            sql: """
                SELECT c.chunk_id, c.chunk_index, c.chunk_hash,
                       c.normalized_text, s.source_id, s.source_hash
                FROM semantic_chunks c
                JOIN semantic_sources s
                  ON s.generation_id = c.generation_id
                 AND s.source_id = c.source_id
                WHERE c.generation_id = ?
                ORDER BY c.chunk_id
                """,
            binds: [.text(metadata.identifier)]
        ) { statement in
            let chunkIdentifier = Self.text(statement, 0)
            let chunkIndex = Int(
                sqlite3_column_int64(statement, 1)
            )
            let chunkHash = Self.text(statement, 2)
            let normalizedText = Self.text(statement, 3)
            let expectedIdentifier = SemanticIndexDigest.sha256(
                SemanticIndexDigest.lengthPrefixed([
                    metadata.identifier,
                    Self.text(statement, 4),
                    Self.text(statement, 5),
                    String(chunkIndex),
                    chunkHash,
                ])
            )
            if chunkIndex < 0 ||
                !SemanticIndexValidation.validSHA256(chunkHash) ||
                chunkHash != chunkHash.lowercased() ||
                SemanticTextNormalizer.normalize(normalizedText)
                    != normalizedText ||
                SemanticIndexDigest.sha256(normalizedText) != chunkHash ||
                chunkIdentifier != expectedIdentifier {
                chunksAreValid = false
            }
        }

        let computedManifest = Self.bindingDigest(
            configurationFingerprint:
                metadata.spec.configurationFingerprint,
            sourceBindings: try sourceBindings(
                generationIdentifier: metadata.identifier,
                db: db
            ),
            highWatermarks: metadata.sourceHighWatermarks
        )
        guard chunksAreValid,
              computedManifest == metadata.sourceManifestDigest,
              try vectorsAreValid(
                generationIdentifier: metadata.identifier,
                retrievalCapability:
                    metadata.spec.retrievalCapability,
                expectedDimension: metadata.spec.vectorDimension,
                db: db
              )
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        if ftsAvailable {
            let indexedChunkCount = try Self.scalarInt(
                db,
                sql: """
                    SELECT count(*) FROM semantic_chunks_fts
                    WHERE generation_id = ?
                    """,
                binds: [.text(metadata.identifier)]
            )
            guard indexedChunkCount == Int64(metadata.chunkCount) else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
        }
    }

    private func markGenerationStale(
        identifier: String,
        current: SemanticIndexGenerationMetadata,
        reason: SemanticIndexStaleReason,
        db: OpaquePointer
    ) throws -> Bool {
        switch reason {
        case .sourceScopeUnknown:
            return try markGenerationSourceAuthority(
                identifier: identifier,
                current: current,
                state: .sourceScopeUnknown,
                db: db
            )
        case .sourceScopeChanged:
            return try markGenerationSourceAuthority(
                identifier: identifier,
                current: current,
                state: .sourceScopeChanged,
                db: db
            )
        case .sourcePermissionRevoked:
            return try markGenerationSourceAuthority(
                identifier: identifier,
                current: current,
                state: .sourcePermissionRevoked,
                db: db
            )
        case .sourceScopeViolation:
            return try markGenerationSourceAuthority(
                identifier: identifier,
                current: current,
                state: .sourceScopeViolation,
                db: db
            )
        case .sourceScopeRebuildRequired:
            return try markGenerationSourceAuthority(
                identifier: identifier,
                current: current,
                state: .sourceScopeRebuildRequired,
                db: db
            )
        case .embeddingRuntimeProfile, .canonicalSourcePolicy:
            break
        }
        if current.state == .corrupt {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        let effectiveReason: SemanticIndexStaleReason =
            current.state == .building || current.state == .paused
                ? .canonicalSourcePolicy
                : reason
        if current.state == .stale {
            guard let currentReason = current.staleReason else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            if currentReason == effectiveReason ||
                currentReason == .canonicalSourcePolicy {
                return false
            }
        }
        try Self.execute(
            db,
            sql: """
                UPDATE semantic_generations
                SET state = ?, stale_reason = ?
                WHERE id = ?
                """,
            binds: [
                .text(SemanticIndexGenerationState.stale.rawValue),
                .text(effectiveReason.rawValue),
                .text(identifier),
            ]
        )
        return true
    }

    private func markGenerationSourceAuthority(
        identifier: String,
        current: SemanticIndexGenerationMetadata,
        state: SemanticIndexSourceAuthorityState,
        db: OpaquePointer
    ) throws -> Bool {
        guard state != .sourceScopeReady else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
        guard current.state != .corrupt else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        if current.sourceAuthorityState == state,
           current.state == .stale {
            return false
        }
        try Self.execute(
            db,
            sql: """
                UPDATE semantic_generations
                SET state = ?, stale_reason = ?,
                    source_authority_state = ?
                WHERE id = ?
                """,
            binds: [
                .text(SemanticIndexGenerationState.stale.rawValue),
                .text(
                    SemanticIndexStaleReason
                        .canonicalSourcePolicy.rawValue
                ),
                .text(state.rawValue),
                .text(identifier),
            ]
        )
        return true
    }

    private func discardNonactiveIncompleteGenerations(
        db: OpaquePointer
    ) throws {
        let active = try activeGenerationIdentifier(db)
        var binds: [SQLValue] = [
            .text(SemanticIndexGenerationState.building.rawValue),
            .text(SemanticIndexGenerationState.paused.rawValue),
        ]
        let activeClause: String
        if let active {
            activeClause = "AND id <> ?"
            binds.append(.text(active))
        } else {
            activeClause = ""
        }
        if ftsAvailable {
            try Self.execute(
                db,
                sql: """
                    DELETE FROM semantic_chunks_fts
                    WHERE generation_id IN (
                        SELECT id FROM semantic_generations
                        WHERE state IN (?, ?) \(activeClause)
                    )
                    """,
                binds: binds
            )
        }
        try Self.execute(
            db,
            sql: """
                DELETE FROM semantic_generations
                WHERE state IN (?, ?) \(activeClause)
                """,
            binds: binds
        )
    }

    private func validateCheckpoint(
        request: SemanticIndexBatchRequest,
        generationIdentifier: String,
        db: OpaquePointer
    ) throws {
        guard let existing = try checkpoint(runIdentifier: request.runIdentifier, db: db) else {
            guard request.currentCursor == nil else {
                throw SemanticIndexFailureCode.checkpointMismatch
            }
            return
        }
        guard existing.generationIdentifier == generationIdentifier,
              existing.streamIdentifier == request.streamIdentifier,
              existing.sourceKind == request.sourceKind,
              existing.adapterContractVersion
                == request.adapterContractVersion,
              existing.sourceAllowlistSHA256
                == request.sourceAllowlistSHA256,
              existing.authorizationReceiptIdentifier
                == request.authorizationReceiptIdentifier,
              existing.nextCursor == request.currentCursor,
              existing.state != .complete
        else { throw SemanticIndexFailureCode.checkpointMismatch }
    }

    private func markAwaitingEmbeddings(
        _ batch: SemanticIndexPreparedBatch,
        db: OpaquePointer
    ) throws {
        let existing = try checkpoint(
            runIdentifier: batch.request.runIdentifier,
            db: db
        )
        let timestamp = Self.milliseconds(now())
        if let existing {
            try Self.execute(
                db,
                sql: """
                    UPDATE semantic_checkpoints SET
                        state = ?, current_cursor = ?, pending_chunk_count = ?,
                        updated_at = ?
                    WHERE run_id = ?
                    """,
                binds: [
                    .text(SemanticIndexCheckpointState.awaitingEmbeddings.rawValue),
                    batch.request.currentCursor.map(SQLValue.text) ?? .null,
                    .integer(Int64(batch.chunksRequiringEmbeddings.count)),
                    .integer(timestamp),
                    .text(batch.request.runIdentifier),
                ]
            )
            guard existing.nextCursor == batch.request.currentCursor else {
                throw SemanticIndexFailureCode.checkpointMismatch
            }
        } else {
            try Self.execute(
                db,
                sql: """
                    INSERT INTO semantic_checkpoints(
                        run_id, generation_id, stream_id, source_kind,
                        adapter_contract_version, source_allowlist_hash,
                        authorization_receipt_id, state, current_cursor,
                        next_cursor, source_high_watermark, batches_committed,
                        records_seen, records_committed, records_unchanged,
                        records_excluded, tombstones_committed, chunks_committed,
                        pending_chunk_count, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                    """,
                binds: [
                    .text(batch.request.runIdentifier),
                    .text(batch.generationIdentifier),
                    .text(batch.request.streamIdentifier),
                    .text(batch.request.sourceKind.rawValue),
                    .text(batch.request.adapterContractVersion),
                    .text(batch.request.sourceAllowlistSHA256),
                    .text(
                        batch.request.authorizationReceiptIdentifier
                    ),
                    .text(SemanticIndexCheckpointState.awaitingEmbeddings.rawValue),
                    batch.request.currentCursor.map(SQLValue.text) ?? .null,
                    batch.request.currentCursor.map(SQLValue.text) ?? .null,
                    batch.request.sourceHighWatermark.map(SQLValue.text) ?? .null,
                    .integer(Int64(batch.chunksRequiringEmbeddings.count)),
                    .integer(timestamp),
                ]
            )
        }
    }

    private func storedSourceState(
        generationIdentifier: String,
        sourceIdentifier: String,
        db: OpaquePointer
    ) throws -> StoredSourceState? {
        var value: StoredSourceState?
        try Self.query(
            db,
            sql: """
                SELECT source_hash, tombstoned
                FROM semantic_sources
                WHERE generation_id = ? AND source_id = ?
                """,
            binds: [.text(generationIdentifier), .text(sourceIdentifier)]
        ) { statement in
            value = .init(
                sourceHash: Self.text(statement, 0),
                tombstoned: sqlite3_column_int(statement, 1) == 1
            )
        }
        return value
    }

    private func deleteSourceChunks(
        generationIdentifier: String,
        sourceIdentifier: String,
        db: OpaquePointer
    ) throws {
        if ftsAvailable {
            try Self.execute(
                db,
                sql: """
                    DELETE FROM semantic_chunks_fts
                    WHERE generation_id = ? AND chunk_id IN (
                        SELECT chunk_id FROM semantic_chunks
                        WHERE generation_id = ? AND source_id = ?
                    )
                    """,
                binds: [
                    .text(generationIdentifier),
                    .text(generationIdentifier),
                    .text(sourceIdentifier),
                ]
            )
        }
        try Self.execute(
            db,
            sql: "DELETE FROM semantic_chunks WHERE generation_id = ? AND source_id = ?",
            binds: [.text(generationIdentifier), .text(sourceIdentifier)]
        )
    }

    private func deleteSource(
        generationIdentifier: String,
        sourceIdentifier: String,
        db: OpaquePointer
    ) throws {
        try deleteSourceChunks(
            generationIdentifier: generationIdentifier,
            sourceIdentifier: sourceIdentifier,
            db: db
        )
        try Self.execute(
            db,
            sql: "DELETE FROM semantic_sources WHERE generation_id = ? AND source_id = ?",
            binds: [.text(generationIdentifier), .text(sourceIdentifier)]
        )
    }

    private func upsertSource(
        _ record: SemanticIndexSourceRecord,
        generationIdentifier: String,
        tombstoned: Bool,
        db: OpaquePointer
    ) throws {
        try Self.execute(
            db,
            sql: """
                INSERT INTO semantic_sources(
                    generation_id, source_id, source_kind, source_hash,
                    source_timestamp, tombstoned, provider,
                    pseudonymous_account_id, remote_record_id, parent_thread_id,
                    source_url, provenance_receipt_hash
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(generation_id, source_id) DO UPDATE SET
                    source_kind = excluded.source_kind,
                    source_hash = excluded.source_hash,
                    source_timestamp = excluded.source_timestamp,
                    tombstoned = excluded.tombstoned,
                    provider = excluded.provider,
                    pseudonymous_account_id = excluded.pseudonymous_account_id,
                    remote_record_id = excluded.remote_record_id,
                    parent_thread_id = excluded.parent_thread_id,
                    source_url = excluded.source_url,
                    provenance_receipt_hash = excluded.provenance_receipt_hash
                """,
            binds: [
                .text(generationIdentifier),
                .text(record.stableSourceIdentifier),
                .text(record.sourceKind.rawValue),
                .text(record.sourceHash),
                .integer(Self.milliseconds(record.sourceTimestamp)),
                .integer(tombstoned ? 1 : 0),
                .text(record.provenance.provider),
                tombstoned ? .null : record.provenance.pseudonymousAccountIdentifier.map(SQLValue.text) ?? .null,
                tombstoned ? .null : record.provenance.remoteRecordIdentifier.map(SQLValue.text) ?? .null,
                tombstoned ? .null : record.provenance.parentOrThreadIdentifier.map(SQLValue.text) ?? .null,
                tombstoned ? .null : record.provenance.sourceURL.map { .text($0.absoluteString) } ?? .null,
                .text(record.provenance.provenanceReceiptHash),
            ]
        )
    }

    private func insertChunk(
        _ chunk: SemanticIndexPreparedChunk,
        vector: [Float]?,
        record: SemanticIndexSourceRecord,
        generationIdentifier: String,
        db: OpaquePointer
    ) throws {
        try Self.execute(
            db,
            sql: """
                INSERT INTO semantic_chunks(
                    generation_id, chunk_id, source_id, chunk_index, chunk_hash,
                    normalized_text, vector, vector_dimension
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
            binds: [
                .text(generationIdentifier),
                .text(chunk.chunkIdentifier),
                .text(record.stableSourceIdentifier),
                .integer(Int64(chunk.chunkIndex)),
                .text(chunk.chunkHash),
                .text(chunk.normalizedText),
                vector.map { .blob(Self.encodeVector($0)) } ?? .null,
                vector.map { .integer(Int64($0.count)) } ?? .null,
            ]
        )
        if ftsAvailable {
            try Self.execute(
                db,
                sql: """
                    INSERT INTO semantic_chunks_fts(
                        generation_id, chunk_id, normalized_text
                    ) VALUES(?, ?, ?)
                    """,
                binds: [
                    .text(generationIdentifier),
                    .text(chunk.chunkIdentifier),
                    .text(chunk.normalizedText),
                ]
            )
        }
    }

    private func activeGenerationIdentifier(_ db: OpaquePointer) throws -> String? {
        try Self.optionalScalarText(
            db,
            sql: "SELECT value FROM semantic_metadata WHERE key = 'active_generation'"
        )
    }

    private func generationMetadata(
        identifier: String,
        db: OpaquePointer
    ) throws -> SemanticIndexGenerationMetadata? {
        var row: (
            SemanticIndexGenerationSpec,
            Date,
            SemanticIndexGenerationState,
            SemanticIndexStaleReason?,
            SemanticIndexSourceAuthorityState,
            String
        )?
        try Self.query(
            db,
            sql: """
                SELECT index_schema_version, retrieval_capability,
                       embedding_model_identifier, embedding_model_digest,
                       vector_dimension, ollama_runtime_version,
                       embedding_request_profile_version,
                       embedding_request_profile_hash,
                       embedding_dimensions, embedding_truncate,
                       embedding_normalization_version,
                       chunker_version, normalization_version,
                       source_schema_version, configuration_fingerprint,
                       created_at, state, stale_reason,
                       source_manifest_digest,
                       source_authority_contract_version,
                       source_allowlist, source_allowlist_hash,
                       source_request_timestamp, source_build_initiation,
                       source_authorization_receipt_id,
                       source_adapter_contract_versions,
                       source_authority_state
                FROM semantic_generations WHERE id = ?
                """,
            binds: [.text(identifier)]
        ) { statement in
            guard let retrievalCapability = SemanticIndexRetrievalCapability(
                rawValue: Self.text(statement, 1)
            ) else { throw SemanticIndexFailureCode.databaseCorrupt }
            let vectorDimension = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 4))
            let embeddingDimensions = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(statement, 8))
            let embeddingTruncate = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 9) == 1
            let sourceRequestTimestamp =
                sqlite3_column_type(statement, 22) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int64(statement, 22)
            let buildScope = try Self.decodedBuildScope(
                sourceAuthorityContractVersion:
                    Self.optionalText(statement, 19),
                sourceAllowlist: Self.optionalText(statement, 20),
                sourceAllowlistSHA256: Self.optionalText(statement, 21),
                sourceRequestTimestamp: sourceRequestTimestamp,
                sourceBuildInitiation: Self.optionalText(statement, 23),
                sourceAuthorizationReceiptIdentifier:
                    Self.optionalText(statement, 24),
                sourceAdapterContractVersions:
                    Self.optionalText(statement, 25)
            )
            let spec = try SemanticIndexGenerationSpec(
                    indexSchemaVersion: Int(sqlite3_column_int64(statement, 0)),
                    retrievalCapability: retrievalCapability,
                    embeddingModelIdentifier: Self.optionalText(statement, 2),
                    embeddingModelDigest: Self.optionalText(statement, 3),
                    vectorDimension: vectorDimension,
                    ollamaRuntimeVersion: Self.optionalText(statement, 5),
                    embeddingRequestProfileVersion: Self.optionalText(statement, 6),
                    embeddingRequestProfileHash: Self.optionalText(statement, 7),
                    embeddingDimensions: embeddingDimensions,
                    embeddingTruncate: embeddingTruncate,
                    embeddingNormalizationVersion:
                        Self.optionalText(statement, 10),
                    chunkerVersion: Self.text(statement, 11),
                    normalizationVersion: Self.text(statement, 12),
                    sourceSchemaVersion: Self.text(statement, 13),
                    buildScope: buildScope
                )
            guard spec.configurationFingerprint == Self.text(statement, 14),
                  let state = SemanticIndexGenerationState(
                    rawValue: Self.text(statement, 16)
                  ),
                  let sourceAuthorityState =
                    SemanticIndexSourceAuthorityState(
                        rawValue: Self.text(statement, 26)
                  )
            else { throw SemanticIndexFailureCode.databaseCorrupt }
            let storedStaleReason: SemanticIndexStaleReason?
            if let rawStaleReason = Self.optionalText(statement, 17) {
                guard let decoded = SemanticIndexStaleReason(rawValue: rawStaleReason) else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
                storedStaleReason = decoded
            } else {
                storedStaleReason = nil
            }
            guard (state == .stale) == (storedStaleReason != nil),
                  sourceAuthorityState == .sourceScopeReady
                    ? buildScope != nil
                    : state == .stale || state == .corrupt
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            let exposedStaleReason = state == .stale
                ? sourceAuthorityState.staleReason
                    ?? storedStaleReason
                : nil
            row = (
                spec,
                Self.date(statement, 15),
                state,
                exposedStaleReason,
                sourceAuthorityState,
                Self.text(statement, 18)
            )
        }
        guard let row else { return nil }
        let highWatermarks = try sourceHighWatermarks(
            generationIdentifier: identifier,
            db: db
        )
        let hashes = try sourceRecordHashes(
            generationIdentifier: identifier,
            db: db
        )
        let chunkCount = Int(try Self.scalarInt(
            db,
            sql: "SELECT count(*) FROM semantic_chunks WHERE generation_id = ?",
            binds: [.text(identifier)]
        ))
        let tombstoneCount = Int(try Self.scalarInt(
            db,
            sql: """
                SELECT count(*) FROM semantic_sources
                WHERE generation_id = ? AND tombstoned = 1
                """,
            binds: [.text(identifier)]
        ))
        return .init(
            identifier: identifier,
            spec: row.0,
            createdAt: row.1,
            state: row.2,
            staleReason: row.3,
            sourceAuthorityState: row.4,
            sourceHighWatermarks: highWatermarks,
            sourceRecordHashes: hashes,
            sourceManifestDigest: row.5,
            sourceCount: hashes.count,
            chunkCount: chunkCount,
            tombstoneCount: tombstoneCount
        )
    }

    private static func encodedSourceAllowlist(
        _ scope: SemanticIndexBuildScope
    ) -> String {
        scope.canonicalSourceKinds
            .map(\.rawValue)
            .joined(separator: "\n")
    }

    private static func encodedAdapterContractVersions(
        _ scope: SemanticIndexBuildScope
    ) -> String {
        scope.canonicalSourceKinds.map { kind in
            let version = scope.adapterContractVersions[kind] ?? ""
            return "\(kind.rawValue):\(Data(version.utf8).base64EncodedString())"
        }.joined(separator: "\n")
    }

    private static func decodedBuildScope(
        sourceAuthorityContractVersion: String?,
        sourceAllowlist: String?,
        sourceAllowlistSHA256: String?,
        sourceRequestTimestamp: Int64?,
        sourceBuildInitiation: String?,
        sourceAuthorizationReceiptIdentifier: String?,
        sourceAdapterContractVersions: String?
    ) throws -> SemanticIndexBuildScope? {
        let presence = [
            sourceAuthorityContractVersion != nil,
            sourceAllowlist != nil,
            sourceAllowlistSHA256 != nil,
            sourceRequestTimestamp != nil,
            sourceBuildInitiation != nil,
            sourceAuthorizationReceiptIdentifier != nil,
            sourceAdapterContractVersions != nil,
        ]
        if presence.allSatisfy({ !$0 }) {
            return nil
        }
        guard presence.allSatisfy({ $0 }),
              let sourceAuthorityContractVersion,
              let sourceAllowlist,
              let sourceAllowlistSHA256,
              let sourceRequestTimestamp,
              let sourceBuildInitiation,
              let sourceAuthorizationReceiptIdentifier,
              let sourceAdapterContractVersions,
              sourceAuthorityContractVersion
                == SemanticIndexBuildScope.currentContractVersion,
              let initiation = SemanticIndexBuildInitiation(
                rawValue: sourceBuildInitiation
              )
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }

        let rawKinds = sourceAllowlist.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !rawKinds.isEmpty,
              rawKinds.allSatisfy({ !$0.isEmpty })
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        let kinds = try rawKinds.map { raw -> SemanticIndexSourceKind in
            guard let kind = SemanticIndexSourceKind(rawValue: raw) else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            return kind
        }
        guard Set(kinds).count == kinds.count else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }

        var adapterVersions: [SemanticIndexSourceKind: String] = [:]
        for line in sourceAdapterContractVersions.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let components = line.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard components.count == 2,
                  let kind = SemanticIndexSourceKind(
                    rawValue: String(components[0])
                  ),
                  let data = Data(
                    base64Encoded: String(components[1])
                  ),
                  let version = String(data: data, encoding: .utf8),
                  adapterVersions.updateValue(
                    version,
                    forKey: kind
                  ) == nil
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
        }

        let scope = try SemanticIndexBuildScope(
            sourceKinds: Set(kinds),
            adapterContractVersions: adapterVersions,
            requestTimestamp: Date(
                timeIntervalSince1970:
                    Double(sourceRequestTimestamp) / 1_000
            ),
            initiation: initiation,
            authorizationReceiptIdentifier:
                sourceAuthorizationReceiptIdentifier
        )
        guard scope.sourceAuthorityContractVersion
                == sourceAuthorityContractVersion,
              scope.allowlistSHA256 == sourceAllowlistSHA256,
              encodedSourceAllowlist(scope) == sourceAllowlist,
              encodedAdapterContractVersions(scope)
                == sourceAdapterContractVersions
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        return scope
    }

    private func sourceRecordHashes(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        try Self.query(
            db,
            sql: """
                SELECT source_id, source_hash, tombstoned
                FROM semantic_sources
                WHERE generation_id = ?
                ORDER BY source_id
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            let sourceIdentifier = Self.text(statement, 0)
            let sourceHash = Self.text(statement, 1)
            values[sourceIdentifier] = sourceHash
        }
        return values
    }

    private func sourceBindings(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        try Self.query(
            db,
            sql: """
                SELECT source_id, source_hash, tombstoned
                FROM semantic_sources
                WHERE generation_id = ?
                ORDER BY source_id
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            let sourceIdentifier = Self.text(statement, 0)
            let sourceHash = Self.text(statement, 1)
            let tombstone = sqlite3_column_int(statement, 2) == 1
            values[sourceIdentifier] =
                "\(sourceHash)|\(tombstone ? "tombstone" : "available")"
        }
        return values
    }

    private func sourceHighWatermarks(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        try Self.query(
            db,
            sql: """
                SELECT stream_id, high_watermark
                FROM semantic_high_watermarks
                WHERE generation_id = ?
                ORDER BY stream_id
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            values[Self.text(statement, 0)] = Self.text(statement, 1)
        }
        return values
    }

    private func checkpoint(
        runIdentifier: String,
        db: OpaquePointer
    ) throws -> SemanticIndexProgress? {
        var value: SemanticIndexProgress?
        try Self.query(
            db,
            sql: """
                SELECT run_id, generation_id, stream_id, state, current_cursor,
                       next_cursor, source_high_watermark, batches_committed,
                       records_seen, records_committed, records_unchanged,
                       records_excluded, tombstones_committed, chunks_committed,
                       pending_chunk_count, updated_at, source_kind,
                       adapter_contract_version, source_allowlist_hash,
                       authorization_receipt_id
                FROM semantic_checkpoints WHERE run_id = ?
                """,
            binds: [.text(runIdentifier)]
        ) { statement in
            guard let state = SemanticIndexCheckpointState(
                rawValue: Self.text(statement, 3)
            ) else { throw SemanticIndexFailureCode.databaseCorrupt }
            value = .init(
                runIdentifier: Self.text(statement, 0),
                generationIdentifier: Self.text(statement, 1),
                streamIdentifier: Self.text(statement, 2),
                sourceKind: try {
                    guard let kind = SemanticIndexSourceKind(
                        rawValue: Self.text(statement, 16)
                    ) else {
                        throw SemanticIndexFailureCode.databaseCorrupt
                    }
                    return kind
                }(),
                adapterContractVersion: Self.text(statement, 17),
                sourceAllowlistSHA256: Self.text(statement, 18),
                authorizationReceiptIdentifier:
                    Self.text(statement, 19),
                state: state,
                currentCursor: Self.optionalText(statement, 4),
                nextCursor: Self.optionalText(statement, 5),
                sourceHighWatermark: Self.optionalText(statement, 6),
                batchesCommitted: Int(sqlite3_column_int64(statement, 7)),
                recordsSeen: Int(sqlite3_column_int64(statement, 8)),
                recordsCommitted: Int(sqlite3_column_int64(statement, 9)),
                recordsUnchanged: Int(sqlite3_column_int64(statement, 10)),
                recordsExcluded: Int(sqlite3_column_int64(statement, 11)),
                tombstonesCommitted: Int(sqlite3_column_int64(statement, 12)),
                chunksCommitted: Int(sqlite3_column_int64(statement, 13)),
                pendingChunkCount: Int(sqlite3_column_int64(statement, 14)),
                updatedAt: Self.date(statement, 15)
            )
        }
        return value
    }

    private func allProgress(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [SemanticIndexProgress] {
        let identifiers = try Self.stringColumn(
            db,
            sql: """
                SELECT run_id FROM semantic_checkpoints
                WHERE generation_id = ? ORDER BY run_id
                """,
            binds: [.text(generationIdentifier)]
        )
        return try identifiers.compactMap { try checkpoint(runIdentifier: $0, db: db) }
    }

    private func vectorsAreValid(
        generationIdentifier: String,
        retrievalCapability: SemanticIndexRetrievalCapability,
        expectedDimension: Int?,
        db: OpaquePointer
    ) throws -> Bool {
        var valid = true
        try Self.query(
            db,
            sql: """
                SELECT vector, vector_dimension FROM semantic_chunks
                WHERE generation_id = ?
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            if retrievalCapability == .lexicalOnly {
                guard sqlite3_column_type(statement, 0) == SQLITE_NULL,
                      sqlite3_column_type(statement, 1) == SQLITE_NULL
                else {
                    valid = false
                    return
                }
                return
            }
            guard let expectedDimension,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL
            else {
                valid = false
                return
            }
            let dimension = Int(sqlite3_column_int64(statement, 1))
            let data = Self.blob(statement, 0)
            guard dimension == expectedDimension,
                  data.count == dimension * MemoryLayout<UInt32>.size,
                  let vector = Self.decodeVector(data, dimension: dimension),
                  vector.allSatisfy(\.isFinite),
                  vector.contains(where: { $0 != 0 })
            else {
                valid = false
                return
            }
        }
        return valid
    }

    private func lexicalCandidates(
        generationIdentifier: String,
        tokens: [String],
        filters: SemanticSearchFilters,
        limit: Int,
        db: OpaquePointer
    ) throws -> [Candidate] {
        if ftsAvailable {
            let match = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
            let filterClause = Self.candidateFilterClause(filters)
            var candidates: [Candidate] = []
            try Self.query(
                db,
                sql: """
                    SELECT c.chunk_id, c.source_id, c.normalized_text, c.vector,
                           c.vector_dimension, s.source_kind, s.source_timestamp,
                           s.provider, s.pseudonymous_account_id,
                           s.remote_record_id, s.parent_thread_id, s.source_url,
                           s.provenance_receipt_hash, s.source_hash,
                           bm25(semantic_chunks_fts)
                    FROM semantic_chunks_fts
                    JOIN semantic_chunks c
                      ON c.generation_id = semantic_chunks_fts.generation_id
                     AND c.chunk_id = semantic_chunks_fts.chunk_id
                    JOIN semantic_sources s
                      ON s.generation_id = c.generation_id
                     AND s.source_id = c.source_id
                    WHERE semantic_chunks_fts MATCH ?
                      AND semantic_chunks_fts.generation_id = ?
                      AND s.tombstoned = 0
                      \(filterClause.sql)
                    ORDER BY bm25(semantic_chunks_fts), c.chunk_id
                    LIMIT ?
                    """,
                binds: [
                    .text(match),
                    .text(generationIdentifier),
                ] + filterClause.binds + [
                    .integer(Int64(limit)),
                ]
            ) { statement in
                if let candidate = try decodeCandidate(statement) {
                    candidates.append(candidate)
                }
            }
            return Array(candidates.prefix(limit))
        }

        var candidates = try deterministicCandidates(
            generationIdentifier: generationIdentifier,
            filters: filters,
            limit: SemanticIndexLimits.maximumCandidateCount,
            db: db
        )
        candidates = candidates.filter { candidate in
            let candidateTokens = Set(SemanticTextNormalizer.lexicalTokens(
                candidate.normalizedText,
                maximumTokens: SemanticTextChunker.maximumTokens
            ))
            return !candidateTokens.isDisjoint(with: tokens)
        }
        return candidates.sorted {
            let leftTokens = Set(SemanticTextNormalizer.lexicalTokens(
                $0.normalizedText,
                maximumTokens: SemanticTextChunker.maximumTokens
            ))
            let rightTokens = Set(SemanticTextNormalizer.lexicalTokens(
                $1.normalizedText,
                maximumTokens: SemanticTextChunker.maximumTokens
            ))
            let leftMatches = tokens.filter(leftTokens.contains).count
            let rightMatches = tokens.filter(rightTokens.contains).count
            if leftMatches != rightMatches { return leftMatches > rightMatches }
            if $0.sourceTimestamp != $1.sourceTimestamp {
                return $0.sourceTimestamp > $1.sourceTimestamp
            }
            return $0.chunkIdentifier < $1.chunkIdentifier
        }.prefix(limit).map { $0 }
    }

    private func deterministicCandidates(
        generationIdentifier: String,
        filters: SemanticSearchFilters,
        limit: Int,
        db: OpaquePointer
    ) throws -> [Candidate] {
        let filterClause = Self.candidateFilterClause(filters)
        var candidates: [Candidate] = []
        try Self.query(
            db,
            sql: """
                SELECT c.chunk_id, c.source_id, c.normalized_text, c.vector,
                       c.vector_dimension, s.source_kind, s.source_timestamp,
                       s.provider, s.pseudonymous_account_id,
                       s.remote_record_id, s.parent_thread_id, s.source_url,
                       s.provenance_receipt_hash, s.source_hash
                FROM semantic_chunks c
                JOIN semantic_sources s
                  ON s.generation_id = c.generation_id
                 AND s.source_id = c.source_id
                WHERE c.generation_id = ? AND s.tombstoned = 0
                  \(filterClause.sql)
                ORDER BY s.source_timestamp DESC, c.chunk_id
                LIMIT ?
                """,
            binds: [
                .text(generationIdentifier),
            ] + filterClause.binds + [
                .integer(Int64(limit)),
            ]
        ) { statement in
            if let candidate = try decodeCandidate(statement) {
                candidates.append(candidate)
            }
        }
        return Array(candidates.prefix(limit))
    }

    private func decodeCandidate(_ statement: OpaquePointer) throws -> Candidate? {
        guard let sourceKind = SemanticIndexSourceKind(rawValue: Self.text(statement, 5)) else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
        let vector: [Float]?
        if sqlite3_column_type(statement, 3) == SQLITE_NULL,
           sqlite3_column_type(statement, 4) == SQLITE_NULL {
            vector = nil
        } else {
            let dimension = Int(sqlite3_column_int64(statement, 4))
            guard let decoded = Self.decodeVector(
                Self.blob(statement, 3),
                dimension: dimension
            ) else { throw SemanticIndexFailureCode.databaseCorrupt }
            vector = decoded
        }
        return .init(
            chunkIdentifier: Self.text(statement, 0),
            sourceIdentifier: Self.text(statement, 1),
            normalizedText: Self.text(statement, 2),
            vector: vector,
            sourceKind: sourceKind,
            sourceTimestamp: Self.date(statement, 6),
            provider: Self.text(statement, 7),
            pseudonymousAccountIdentifier: Self.optionalText(statement, 8),
            remoteRecordIdentifier: Self.optionalText(statement, 9),
            parentOrThreadIdentifier: Self.optionalText(statement, 10),
            sourceURL: Self.optionalText(statement, 11).flatMap(URL.init(string:)),
            provenanceReceiptHash: Self.text(statement, 12),
            sourceHash: Self.text(statement, 13)
        )
    }

    private static func candidateFilterClause(
        _ filters: SemanticSearchFilters
    ) -> CandidateFilterClause {
        var clauses: [String] = []
        var binds: [SQLValue] = []
        if !filters.sourceKinds.isEmpty {
            let kinds = filters.sourceKinds.map(\.rawValue).sorted()
            clauses.append("s.source_kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))")
            binds.append(contentsOf: kinds.map(SQLValue.text))
        }
        if let startDate = filters.startDate {
            clauses.append("s.source_timestamp >= ?")
            binds.append(.integer(milliseconds(startDate)))
        }
        if let endDate = filters.endDate {
            clauses.append("s.source_timestamp <= ?")
            binds.append(.integer(milliseconds(endDate)))
        }
        if let provider = filters.provider {
            clauses.append("s.provider = ?")
            binds.append(.text(provider))
        }
        return .init(
            sql: clauses.isEmpty ? "" : "AND " + clauses.joined(separator: " AND "),
            binds: binds
        )
    }

    private static func searchFilterResolution(
        _ filters: SemanticSearchFilters,
        metadata: SemanticIndexGenerationMetadata
    ) throws -> SemanticSearchFilterResolution {
        guard metadata.sourceAuthorityState == .sourceScopeReady,
              let buildScope = metadata.spec.buildScope
        else {
            throw SemanticIndexFailureCode.sourceScopeUnknown
        }
        let requested = filters.sourceKinds
        let effective = requested.isEmpty
            ? buildScope.sourceKinds
            : requested.intersection(buildScope.sourceKinds)
        let unindexed = requested.subtracting(buildScope.sourceKinds)
        return .init(
            state: unindexed.isEmpty ? .ready : .sourceNotIndexed,
            requestedSourceKinds: requested,
            effectiveSourceKinds: effective,
            unindexedSourceKinds: unindexed
        )
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        OllamaEmbeddingVectorMath.cosineSimilarity(lhs, rhs)
    }

    private static func normalizedCosine(_ value: Double) -> Double {
        (max(-1, min(1, value)) + 1) / 2
    }

    private static func deduplicated(
        records: [SemanticIndexSourceRecord]
    ) -> [SemanticIndexSourceRecord] {
        var selected: [String: SemanticIndexSourceRecord] = [:]
        for record in records {
            guard let existing = selected[record.stableSourceIdentifier] else {
                selected[record.stableSourceIdentifier] = record
                continue
            }
            let chooseRecord: Bool
            if existing.sourceTimestamp != record.sourceTimestamp {
                chooseRecord = record.sourceTimestamp > existing.sourceTimestamp
            } else if existing.isTombstone != record.isTombstone {
                chooseRecord = record.isTombstone
            } else if existing.sourceHash != record.sourceHash {
                chooseRecord = record.sourceHash > existing.sourceHash
            } else {
                chooseRecord = record.provenance.provenanceReceiptHash >
                    existing.provenance.provenanceReceiptHash
            }
            if chooseRecord { selected[record.stableSourceIdentifier] = record }
        }
        return selected.values.sorted {
            $0.stableSourceIdentifier < $1.stableSourceIdentifier
        }
    }

    private static func validate(_ request: SemanticIndexBatchRequest) throws {
        guard SemanticIndexValidation.validIdentifier(request.runIdentifier),
              SemanticIndexValidation.validIdentifier(request.streamIdentifier),
              SemanticIndexValidation.validOptionalBoundedValue(
                request.currentCursor,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              SemanticIndexValidation.validOptionalBoundedValue(
                request.nextCursor,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              SemanticIndexValidation.validOptionalBoundedValue(
                request.sourceHighWatermark,
                maximumBytes: SemanticIndexLimits.maximumCursorBytes
              ),
              request.records.count <= SemanticIndexLimits.maximumRecordsPerBatch,
              !request.records.isEmpty || request.isFinalBatch,
              (!request.isFinalBatch || request.nextCursor == nil),
              !(request.nextCursor != nil && request.nextCursor == request.currentCursor),
              SemanticIndexValidation.validIdentifier(
                  request.adapterContractVersion,
                  maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validSHA256(
                  request.sourceAllowlistSHA256
              ),
              request.sourceAllowlistSHA256
                == request.sourceAllowlistSHA256.lowercased(),
              SemanticIndexValidation.validIdentifier(
                  request.authorizationReceiptIdentifier
              ),
              request.records.allSatisfy({
                  $0.sourceKind == request.sourceKind
              })
        else { throw SemanticIndexFailureCode.invalidBatch }
        try request.records.forEach { try $0.validateIntegrity() }
    }

    private static func validateSourceAuthority(
        request: SemanticIndexBatchRequest,
        metadata: SemanticIndexGenerationMetadata
    ) throws {
        guard metadata.sourceAuthorityState == .sourceScopeReady,
              let scope = metadata.spec.buildScope
        else {
            throw SemanticIndexFailureCode.sourceScopeUnknown
        }
        try scope.validateIntegrity()
        guard scope.permits(request.sourceKind),
              scope.allowlistSHA256 == request.sourceAllowlistSHA256,
              scope.authorizationReceiptIdentifier
                == request.authorizationReceiptIdentifier,
              scope.adapterContractVersion(for: request.sourceKind)
                == request.adapterContractVersion,
              request.records.allSatisfy({
                  $0.sourceKind == request.sourceKind
              })
        else {
            throw SemanticIndexFailureCode.sourceScopeViolation
        }
    }

    private static func planDigest(
        generationIdentifier: String,
        configurationFingerprint: String,
        request: SemanticIndexBatchRequest,
        sources: [SemanticIndexPreparedSource]
    ) -> String {
        let sourceMaterial = sources.map { source in
            let chunkMaterial = source.chunks.map {
                SemanticIndexDigest.lengthPrefixed([
                    $0.chunkIdentifier,
                    String($0.chunkIndex),
                    $0.chunkHash,
                    $0.normalizedText,
                ])
            }.joined()
            return SemanticIndexDigest.lengthPrefixed([
                source.record.stableSourceIdentifier,
                source.record.sourceKind.rawValue,
                SemanticIndexDigest.milliseconds(source.record.sourceTimestamp),
                source.record.sourceHash,
                String(source.record.isTombstone),
                source.record.privacyClassification.rawValue,
                source.record.provenance.provenanceReceiptHash,
                source.action.rawValue,
                source.previousSourceState ?? "",
                chunkMaterial,
            ])
        }.joined()
        return SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                generationIdentifier,
                configurationFingerprint,
                request.runIdentifier,
                request.streamIdentifier,
                request.currentCursor ?? "",
                request.nextCursor ?? "",
                request.sourceHighWatermark ?? "",
                String(request.isFinalBatch),
                request.sourceKind.authorityName,
                request.adapterContractVersion,
                request.sourceAllowlistSHA256,
                request.authorizationReceiptIdentifier,
                sourceMaterial,
            ])
        )
    }

    private static func manifestDigest(_ sourceHashes: [String: String]) -> String {
        let material = sourceHashes.sorted { $0.key < $1.key }.map {
            SemanticIndexDigest.lengthPrefixed([$0.key, $0.value])
        }.joined()
        return SemanticIndexDigest.sha256(material)
    }

    private static func bindingDigest(
        configurationFingerprint: String,
        sourceBindings: [String: String],
        highWatermarks: [String: String]
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "configuration",
                configurationFingerprint,
                "source_bindings",
                manifestDigest(sourceBindings),
                "source_high_watermarks",
                manifestDigest(highWatermarks),
            ])
        )
    }

    private static func encodeVector(_ vector: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeVector(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0,
              data.count == dimension * MemoryLayout<UInt32>.size
        else { return nil }
        var vector: [Float] = []
        vector.reserveCapacity(dimension)
        for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size) {
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)]
                .enumerated()
                .reduce(UInt32(0)) { partial, element in
                    partial | (UInt32(element.element) << UInt32(element.offset * 8))
                }
            vector.append(Float(bitPattern: bits))
        }
        return vector
    }

    // MARK: - SQLite bootstrap

    private static func bootstrap(
        url: URL?,
        inMemory: Bool,
        signedSmokeStorageBoundary:
            P8FSignedSmokeStorageBoundary?,
        forceLexicalFallback: Bool
    ) throws -> Bootstrap {
        guard inMemory || url?.isFileURL == true else {
            throw SemanticIndexFailureCode.invalidDatabaseURL
        }
        let fileManager = FileManager.default
        if let url {
            do {
                let directory = url.deletingLastPathComponent()
                if let signedSmokeStorageBoundary {
                    try signedSmokeStorageBoundary
                        .ensurePrivateDirectory(
                            at: directory,
                            fileManager: fileManager
                        )
                    try signedSmokeStorageBoundary
                        .validateSQLiteFamily(
                            at: url,
                            requireDatabase: false,
                            fileManager: fileManager
                        )
                } else {
                    try fileManager.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o700],
                        ofItemAtPath: directory.path
                    )
                }
            } catch let boundaryFailure
                as P8FSignedSmokeStorageBoundaryFailure {
                throw boundaryFailure
            } catch {
                throw SemanticIndexFailureCode.databaseOpenFailed
            }
        }

        let existed = url.map { fileManager.fileExists(atPath: $0.path) } ?? false
        var opened: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
        if signedSmokeStorageBoundary != nil {
            flags |= SQLITE_OPEN_NOFOLLOW
        }
        let result = sqlite3_open_v2(
            inMemory ? ":memory:" : url?.path,
            &opened,
            flags,
            nil
        )
        guard result == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close_v2(opened) }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                throw SemanticIndexFailureCode.databaseBusy
            }
            throw SemanticIndexFailureCode.databaseOpenFailed
        }

        do {
            try runToCompletion(
                db,
                sql: "PRAGMA busy_timeout = \(SemanticIndexLimits.busyTimeoutMilliseconds)"
            )
            try runToCompletion(db, sql: "PRAGMA foreign_keys = ON")
            if existed {
                guard try scalarText(db, sql: "PRAGMA quick_check(1)") == "ok" else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
            }
            let previous = Int(try scalarInt(db, sql: "PRAGMA user_version"))
            let hasPreexistingSemanticTables = try scalarInt(
                db,
                sql: """
                    SELECT count(*) FROM sqlite_master
                    WHERE type = 'table' AND name GLOB 'semantic_*'
                    """
            ) > 0
            guard previous == SemanticIndexLimits.schemaVersion ||
                    previous == 2 ||
                    previous == 1 ||
                    (previous == 0 && !hasPreexistingSemanticTables)
            else {
                throw SemanticIndexFailureCode.unsupportedSchema
            }
            let legacyStructureIsValid: Bool
            switch previous {
            case 1:
                legacyStructureIsValid =
                    try isStructurallyValidSchemaV1(db)
            case 2:
                legacyStructureIsValid =
                    try isStructurallyValidSchemaV2(db)
            case 3:
                legacyStructureIsValid =
                    try isStructurallyValidSchemaV3(db)
            case 0:
                legacyStructureIsValid = true
            default:
                legacyStructureIsValid = false
            }
            guard legacyStructureIsValid else {
                throw SemanticIndexFailureCode.unsupportedSchema
            }
            try runToCompletion(db, sql: "PRAGMA secure_delete = ON")
            try runToCompletion(db, sql: "PRAGMA synchronous = FULL")
            let journal = try scalarText(db, sql: "PRAGMA journal_mode = WAL")
            guard journal.lowercased() == (inMemory ? "memory" : "wal") else {
                throw SemanticIndexFailureCode.databaseOpenFailed
            }
            if previous == 1 {
                try migrateSchemaV1ToV3(db)
                guard try scalarText(db, sql: "PRAGMA quick_check(1)") == "ok",
                      try foreignKeysAreValid(db)
                else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
            } else if previous == 2 {
                try migrateSchemaV2ToV3(db)
                guard try scalarText(db, sql: "PRAGMA quick_check(1)") == "ok",
                      try foreignKeysAreValid(db)
                else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
            }
            try withTransaction(db) {
                for statement in schemaStatements {
                    try runToCompletion(db, sql: statement)
                }
                try runToCompletion(
                    db,
                    sql: "PRAGMA user_version = \(SemanticIndexLimits.schemaVersion)"
                )
            }
            try validateStoredSourceAuthorityMetadata(db)

            let fts = forceLexicalFallback ? false : configureFTS(db)
            try execute(
                db,
                sql: """
                    INSERT INTO semantic_features(name, value)
                    VALUES('fts5', ?)
                    ON CONFLICT(name) DO UPDATE SET value = excluded.value
                    """,
                binds: [.text(fts ? "available" : "fallback")]
            )
            if let url {
                if let signedSmokeStorageBoundary {
                    try signedSmokeStorageBoundary.secureSQLiteFamily(
                        at: url,
                        requireDatabase: true,
                        fileManager: fileManager
                    )
                } else {
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                }
            }
            return .init(connection: db, ftsAvailable: fts)
        } catch {
            sqlite3_close_v2(db)
            if let boundaryFailure =
                    error as? P8FSignedSmokeStorageBoundaryFailure {
                throw boundaryFailure
            }
            if let known = error as? SemanticIndexFailureCode { throw known }
            throw SemanticIndexFailureCode.databaseOpenFailed
        }
    }

    private static let requiredSemanticTables: Set<String> = [
        "semantic_metadata",
        "semantic_features",
        "semantic_generations",
        "semantic_sources",
        "semantic_chunks",
        "semantic_high_watermarks",
        "semantic_checkpoints",
    ]

    private static let legacyCheckpointColumns: Set<String> = [
        "run_id",
        "generation_id",
        "stream_id",
        "state",
        "current_cursor",
        "next_cursor",
        "source_high_watermark",
        "batches_committed",
        "records_seen",
        "records_committed",
        "records_unchanged",
        "records_excluded",
        "tombstones_committed",
        "chunks_committed",
        "pending_chunk_count",
        "updated_at",
    ]

    private static func isStructurallyValidSchemaV1(
        _ db: OpaquePointer
    ) throws -> Bool {
        guard try hasRequiredSemanticTables(db) else { return false }
        return try tableColumns(
            "semantic_generations",
            db: db
        ) == [
            "id",
            "index_schema_version",
            "retrieval_capability",
            "embedding_model_identifier",
            "embedding_model_digest",
            "vector_dimension",
            "chunker_version",
            "normalization_version",
            "source_schema_version",
            "configuration_fingerprint",
            "created_at",
            "state",
            "source_manifest_digest",
        ] && tableColumns(
            "semantic_checkpoints",
            db: db
        ) == legacyCheckpointColumns
    }

    private static func isStructurallyValidSchemaV2(
        _ db: OpaquePointer
    ) throws -> Bool {
        guard try hasRequiredSemanticTables(db) else { return false }
        return try tableColumns(
            "semantic_generations",
            db: db
        ) == [
            "id",
            "index_schema_version",
            "retrieval_capability",
            "embedding_model_identifier",
            "embedding_model_digest",
            "vector_dimension",
            "ollama_runtime_version",
            "embedding_request_profile_version",
            "embedding_request_profile_hash",
            "embedding_dimensions",
            "embedding_truncate",
            "embedding_normalization_version",
            "chunker_version",
            "normalization_version",
            "source_schema_version",
            "configuration_fingerprint",
            "created_at",
            "state",
            "stale_reason",
            "source_manifest_digest",
        ] && tableColumns(
            "semantic_checkpoints",
            db: db
        ) == legacyCheckpointColumns
    }

    private static func isStructurallyValidSchemaV3(
        _ db: OpaquePointer
    ) throws -> Bool {
        guard try hasRequiredSemanticTables(db) else { return false }
        return try tableColumns(
            "semantic_generations",
            db: db
        ) == [
            "id",
            "index_schema_version",
            "retrieval_capability",
            "embedding_model_identifier",
            "embedding_model_digest",
            "vector_dimension",
            "ollama_runtime_version",
            "embedding_request_profile_version",
            "embedding_request_profile_hash",
            "embedding_dimensions",
            "embedding_truncate",
            "embedding_normalization_version",
            "chunker_version",
            "normalization_version",
            "source_schema_version",
            "configuration_fingerprint",
            "created_at",
            "state",
            "stale_reason",
            "source_manifest_digest",
            "source_authority_contract_version",
            "source_allowlist",
            "source_allowlist_hash",
            "source_request_timestamp",
            "source_build_initiation",
            "source_authorization_receipt_id",
            "source_adapter_contract_versions",
            "source_authority_state",
        ] && tableColumns(
            "semantic_checkpoints",
            db: db
        ) == legacyCheckpointColumns.union([
            "source_kind",
            "adapter_contract_version",
            "source_allowlist_hash",
            "authorization_receipt_id",
        ])
    }

    private static func hasRequiredSemanticTables(
        _ db: OpaquePointer
    ) throws -> Bool {
        let requiredTables: Set<String> = [
            "semantic_metadata",
            "semantic_features",
            "semantic_generations",
            "semantic_sources",
            "semantic_chunks",
            "semantic_high_watermarks",
            "semantic_checkpoints",
        ]
        let presentTables = Set(try stringColumn(
            db,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name GLOB 'semantic_*'
                """
        ))
        return requiredTables.isSubset(of: presentTables)
    }

    private static func tableColumns(
        _ table: String,
        db: OpaquePointer
    ) throws -> Set<String> {
        guard requiredSemanticTables.contains(table) else {
            throw SemanticIndexFailureCode.unsupportedSchema
        }
        var columns: Set<String> = []
        try query(db, sql: "PRAGMA table_info(\(table))") {
            columns.insert(text($0, 1))
        }
        return columns
    }

    private static func migrateSchemaV1ToV3(_ db: OpaquePointer) throws {
        try withTransaction(db) {
            let legacy = try legacyGenerations(db)
            for generation in legacy {
                try validateLegacyGeneration(generation, db: db)
            }
            try validateActiveGenerationReference(
                Set(legacy.map(\.identifier)),
                db: db
            )

            let v2Additions = [
                "ollama_runtime_version TEXT",
                "embedding_request_profile_version TEXT",
                "embedding_request_profile_hash TEXT",
                "embedding_dimensions INTEGER CHECK(embedding_dimensions IS NULL OR embedding_dimensions > 0)",
                "embedding_truncate INTEGER CHECK(embedding_truncate IS NULL OR embedding_truncate IN (0,1))",
                "embedding_normalization_version TEXT",
                """
                stale_reason TEXT CHECK(
                    stale_reason IS NULL OR stale_reason IN (
                        'semantic_index_embedding_runtime_profile_stale',
                        'semantic_index_canonical_source_policy_stale'
                    )
                )
                """,
            ]
            for addition in v2Additions {
                try runToCompletion(
                    db,
                    sql: "ALTER TABLE semantic_generations ADD COLUMN \(addition)"
                )
            }
            try addSchemaV3AuthorityColumns(db)

            for generation in legacy {
                let migratedSpec = try unknownScopeSpec(
                    from: generation
                )
                let migratedManifest = bindingDigest(
                    configurationFingerprint:
                        migratedSpec.configurationFingerprint,
                    sourceBindings: try legacySourceBindings(
                        generationIdentifier: generation.identifier,
                        db: db
                    ),
                    highWatermarks: try legacyHighWatermarks(
                        generationIdentifier: generation.identifier,
                        db: db
                    )
                )
                try execute(
                    db,
                    sql: """
                        UPDATE semantic_generations SET
                            index_schema_version = ?,
                            ollama_runtime_version = ?,
                            embedding_request_profile_version = ?,
                            embedding_request_profile_hash = ?,
                            embedding_dimensions = ?,
                            embedding_truncate = ?,
                            embedding_normalization_version = ?,
                            configuration_fingerprint = ?,
                            state = ?,
                            stale_reason = ?,
                            source_manifest_digest = ?,
                            source_authority_state = ?
                        WHERE id = ?
                        """,
                    binds: [
                        .integer(Int64(SemanticIndexLimits.schemaVersion)),
                        migratedSpec.ollamaRuntimeVersion.map(SQLValue.text) ?? .null,
                        migratedSpec.embeddingRequestProfileVersion.map(SQLValue.text) ?? .null,
                        migratedSpec.embeddingRequestProfileHash.map(SQLValue.text) ?? .null,
                        migratedSpec.embeddingDimensions.map {
                            .integer(Int64($0))
                        } ?? .null,
                        migratedSpec.embeddingTruncate.map {
                            .integer($0 ? 1 : 0)
                        } ?? .null,
                        migratedSpec.embeddingNormalizationVersion.map(SQLValue.text) ?? .null,
                        .text(migratedSpec.configurationFingerprint),
                        .text(SemanticIndexGenerationState.stale.rawValue),
                        .text(
                            SemanticIndexStaleReason
                                .canonicalSourcePolicy.rawValue
                        ),
                        .text(migratedManifest),
                        .text(
                            SemanticIndexSourceAuthorityState
                                .sourceScopeUnknown.rawValue
                        ),
                        .text(generation.identifier),
                    ]
                )
            }
            guard try scalarText(db, sql: "PRAGMA quick_check(1)") == "ok",
                  try foreignKeysAreValid(db)
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            try runToCompletion(
                db,
                sql: "PRAGMA user_version = \(SemanticIndexLimits.schemaVersion)"
            )
        }
    }

    private static func migrateSchemaV2ToV3(_ db: OpaquePointer) throws {
        try withTransaction(db) {
            let legacy = try legacyGenerationsV2(db)
            for generation in legacy {
                try validateLegacyGenerationV2(generation, db: db)
            }
            try validateActiveGenerationReference(
                Set(legacy.map(\.identifier)),
                db: db
            )
            try addSchemaV3AuthorityColumns(db)

            for generation in legacy {
                let migratedSpec = try unknownScopeSpec(
                    from: generation
                )
                let migratedManifest = bindingDigest(
                    configurationFingerprint:
                        migratedSpec.configurationFingerprint,
                    sourceBindings: try legacySourceBindings(
                        generationIdentifier: generation.identifier,
                        db: db
                    ),
                    highWatermarks: try legacyHighWatermarks(
                        generationIdentifier: generation.identifier,
                        db: db
                    )
                )
                try execute(
                    db,
                    sql: """
                        UPDATE semantic_generations SET
                            index_schema_version = ?,
                            configuration_fingerprint = ?,
                            state = ?,
                            stale_reason = ?,
                            source_manifest_digest = ?,
                            source_authority_state = ?
                        WHERE id = ?
                        """,
                    binds: [
                        .integer(Int64(SemanticIndexLimits.schemaVersion)),
                        .text(migratedSpec.configurationFingerprint),
                        .text(SemanticIndexGenerationState.stale.rawValue),
                        .text(
                            SemanticIndexStaleReason
                                .canonicalSourcePolicy.rawValue
                        ),
                        .text(migratedManifest),
                        .text(
                            SemanticIndexSourceAuthorityState
                                .sourceScopeUnknown.rawValue
                        ),
                        .text(generation.identifier),
                    ]
                )
            }
            guard try scalarText(db, sql: "PRAGMA quick_check(1)") == "ok",
                  try foreignKeysAreValid(db)
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            try runToCompletion(
                db,
                sql: "PRAGMA user_version = \(SemanticIndexLimits.schemaVersion)"
            )
        }
    }

    private static func addSchemaV3AuthorityColumns(
        _ db: OpaquePointer
    ) throws {
        let generationAdditions = [
            "source_authority_contract_version TEXT",
            "source_allowlist TEXT",
            "source_allowlist_hash TEXT",
            "source_request_timestamp INTEGER",
            "source_build_initiation TEXT",
            "source_authorization_receipt_id TEXT",
            "source_adapter_contract_versions TEXT",
            """
            source_authority_state TEXT NOT NULL
                DEFAULT 'source_scope_unknown'
                CHECK(source_authority_state IN (
                    'source_scope_ready',
                    'source_scope_unknown',
                    'source_scope_changed',
                    'source_permission_revoked',
                    'source_scope_violation',
                    'source_scope_rebuild_required'
                ))
            """,
        ]
        for addition in generationAdditions {
            try runToCompletion(
                db,
                sql: """
                    ALTER TABLE semantic_generations
                    ADD COLUMN \(addition)
                    """
            )
        }
        for addition in [
            "source_kind TEXT",
            "adapter_contract_version TEXT",
            "source_allowlist_hash TEXT",
            "authorization_receipt_id TEXT",
        ] {
            try runToCompletion(
                db,
                sql: """
                    ALTER TABLE semantic_checkpoints
                    ADD COLUMN \(addition)
                    """
            )
        }
    }

    private static func validateActiveGenerationReference(
        _ identifiers: Set<String>,
        db: OpaquePointer
    ) throws {
        if let active = try optionalScalarText(
            db,
            sql: """
                SELECT value FROM semantic_metadata
                WHERE key = 'active_generation'
                """
        ), !identifiers.contains(active) {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
    }

    private static func validateStoredSourceAuthorityMetadata(
        _ db: OpaquePointer
    ) throws {
        try query(
            db,
            sql: """
                SELECT source_authority_contract_version,
                       source_allowlist, source_allowlist_hash,
                       source_request_timestamp,
                       source_build_initiation,
                       source_authorization_receipt_id,
                       source_adapter_contract_versions,
                       source_authority_state
                FROM semantic_generations
                ORDER BY id
                """
        ) { statement in
            let requestTimestamp =
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int64(statement, 3)
            let scope = try decodedBuildScope(
                sourceAuthorityContractVersion:
                    optionalText(statement, 0),
                sourceAllowlist: optionalText(statement, 1),
                sourceAllowlistSHA256: optionalText(statement, 2),
                sourceRequestTimestamp: requestTimestamp,
                sourceBuildInitiation: optionalText(statement, 4),
                sourceAuthorizationReceiptIdentifier:
                    optionalText(statement, 5),
                sourceAdapterContractVersions:
                    optionalText(statement, 6)
            )
            guard let state = SemanticIndexSourceAuthorityState(
                    rawValue: text(statement, 7)
                  ),
                  state != .sourceScopeReady || scope != nil
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
        }
    }

    private static func legacyGenerations(
        _ db: OpaquePointer
    ) throws -> [LegacyGenerationV1] {
        var generations: [LegacyGenerationV1] = []
        try query(
            db,
            sql: """
                SELECT id, index_schema_version, retrieval_capability,
                       embedding_model_identifier, embedding_model_digest,
                       vector_dimension, chunker_version, normalization_version,
                       source_schema_version, configuration_fingerprint, state,
                       source_manifest_digest
                FROM semantic_generations
                ORDER BY id
                """
        ) { statement in
            guard sqlite3_column_int64(statement, 1) == 1,
                  let retrievalCapability = SemanticIndexRetrievalCapability(
                    rawValue: text(statement, 2)
                  ),
                  let state = SemanticIndexGenerationState(
                    rawValue: text(statement, 10)
                  )
            else { throw SemanticIndexFailureCode.databaseCorrupt }
            generations.append(.init(
                identifier: text(statement, 0),
                retrievalCapability: retrievalCapability,
                embeddingModelIdentifier: optionalText(statement, 3),
                embeddingModelDigest: optionalText(statement, 4),
                vectorDimension:
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int64(statement, 5)),
                chunkerVersion: text(statement, 6),
                normalizationVersion: text(statement, 7),
                sourceSchemaVersion: text(statement, 8),
                configurationFingerprint: text(statement, 9),
                state: state,
                sourceManifestDigest: text(statement, 11)
            ))
        }
        return generations
    }

    private static func legacyGenerationsV2(
        _ db: OpaquePointer
    ) throws -> [LegacyGenerationV2] {
        var generations: [LegacyGenerationV2] = []
        try query(
            db,
            sql: """
                SELECT id, index_schema_version, retrieval_capability,
                       embedding_model_identifier, embedding_model_digest,
                       vector_dimension, ollama_runtime_version,
                       embedding_request_profile_version,
                       embedding_request_profile_hash,
                       embedding_dimensions, embedding_truncate,
                       embedding_normalization_version,
                       chunker_version, normalization_version,
                       source_schema_version, configuration_fingerprint,
                       state, stale_reason, source_manifest_digest
                FROM semantic_generations
                ORDER BY id
                """
        ) { statement in
            guard sqlite3_column_int64(statement, 1) == 2,
                  let retrievalCapability =
                    SemanticIndexRetrievalCapability(
                        rawValue: text(statement, 2)
                    ),
                  let state = SemanticIndexGenerationState(
                    rawValue: text(statement, 16)
                  )
            else {
                throw SemanticIndexFailureCode.databaseCorrupt
            }
            let staleReason: SemanticIndexStaleReason?
            if let raw = optionalText(statement, 17) {
                guard let decoded = SemanticIndexStaleReason(
                    rawValue: raw
                ), decoded == .embeddingRuntimeProfile ||
                    decoded == .canonicalSourcePolicy
                else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
                staleReason = decoded
            } else {
                staleReason = nil
            }
            let embeddingTruncate: Bool?
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                embeddingTruncate = nil
            } else {
                let raw = sqlite3_column_int64(statement, 10)
                guard raw == 0 || raw == 1 else {
                    throw SemanticIndexFailureCode.databaseCorrupt
                }
                embeddingTruncate = raw == 1
            }
            generations.append(.init(
                identifier: text(statement, 0),
                retrievalCapability: retrievalCapability,
                embeddingModelIdentifier: optionalText(statement, 3),
                embeddingModelDigest: optionalText(statement, 4),
                vectorDimension:
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int64(statement, 5)),
                ollamaRuntimeVersion: optionalText(statement, 6),
                embeddingRequestProfileVersion:
                    optionalText(statement, 7),
                embeddingRequestProfileHash:
                    optionalText(statement, 8),
                embeddingDimensions:
                    sqlite3_column_type(statement, 9) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int64(statement, 9)),
                embeddingTruncate: embeddingTruncate,
                embeddingNormalizationVersion:
                    optionalText(statement, 11),
                chunkerVersion: text(statement, 12),
                normalizationVersion: text(statement, 13),
                sourceSchemaVersion: text(statement, 14),
                configurationFingerprint: text(statement, 15),
                state: state,
                staleReason: staleReason,
                sourceManifestDigest: text(statement, 18)
            ))
        }
        return generations
    }

    private static func validateLegacyGeneration(
        _ generation: LegacyGenerationV1,
        db: OpaquePointer
    ) throws {
        let validEmbeddingContract: Bool
        switch generation.retrievalCapability {
        case .lexicalOnly:
            validEmbeddingContract =
                generation.embeddingModelIdentifier == nil &&
                generation.embeddingModelDigest == nil &&
                generation.vectorDimension == nil
        case .hybrid:
            validEmbeddingContract =
                generation.embeddingModelIdentifier.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumModelIdentifierBytes
                    )
                } == true &&
                generation.embeddingModelDigest.map {
                    SemanticIndexValidation.validSHA256($0) &&
                        $0 == $0.lowercased()
                } == true &&
                generation.vectorDimension.map {
                    (1...SemanticIndexLimits.maximumVectorDimension)
                        .contains($0)
                } == true
        }
        guard SemanticIndexValidation.validIdentifier(generation.identifier),
              validEmbeddingContract,
              SemanticIndexValidation.validIdentifier(
                generation.chunkerVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                generation.normalizationVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                generation.sourceSchemaVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              generation.configurationFingerprint ==
                legacyConfigurationFingerprint(generation),
              SemanticIndexValidation.validSHA256(
                generation.sourceManifestDigest
              ),
              generation.sourceManifestDigest ==
                bindingDigest(
                    configurationFingerprint:
                        generation.configurationFingerprint,
                    sourceBindings: try legacySourceBindings(
                        generationIdentifier: generation.identifier,
                        db: db
                    ),
                    highWatermarks: try legacyHighWatermarks(
                        generationIdentifier: generation.identifier,
                        db: db
                    )
                )
        else { throw SemanticIndexFailureCode.databaseCorrupt }
    }

    private static func legacyConfigurationFingerprint(
        _ generation: LegacyGenerationV1
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "1",
                generation.retrievalCapability.rawValue,
                generation.embeddingModelIdentifier ?? "",
                generation.embeddingModelDigest ?? "",
                generation.vectorDimension.map(String.init) ?? "",
                generation.chunkerVersion,
                generation.normalizationVersion,
                generation.sourceSchemaVersion,
            ])
        )
    }

    private static func validateLegacyGenerationV2(
        _ generation: LegacyGenerationV2,
        db: OpaquePointer
    ) throws {
        let validEmbeddingContract: Bool
        switch generation.retrievalCapability {
        case .lexicalOnly:
            validEmbeddingContract =
                generation.embeddingModelIdentifier == nil &&
                generation.embeddingModelDigest == nil &&
                generation.vectorDimension == nil &&
                generation.ollamaRuntimeVersion == nil &&
                generation.embeddingRequestProfileVersion == nil &&
                generation.embeddingRequestProfileHash == nil &&
                generation.embeddingDimensions == nil &&
                generation.embeddingTruncate == nil &&
                generation.embeddingNormalizationVersion == nil
        case .hybrid:
            validEmbeddingContract =
                generation.embeddingModelIdentifier.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumModelIdentifierBytes
                    )
                } == true &&
                generation.embeddingModelDigest.map {
                    SemanticIndexValidation.validSHA256($0) &&
                        $0 == $0.lowercased()
                } == true &&
                generation.vectorDimension.map {
                    (1...SemanticIndexLimits.maximumVectorDimension)
                        .contains($0)
                } == true &&
                generation.ollamaRuntimeVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumVersionBytes
                    )
                } == true &&
                generation.embeddingRequestProfileVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumVersionBytes
                    )
                } == true &&
                generation.embeddingRequestProfileHash.map {
                    SemanticIndexValidation.validSHA256($0) &&
                        $0 == $0.lowercased()
                } == true &&
                (generation.embeddingDimensions.map {
                    (1...SemanticIndexLimits.maximumVectorDimension)
                        .contains($0) &&
                        $0 == generation.vectorDimension
                } ?? true) &&
                generation.embeddingTruncate != nil &&
                generation.embeddingNormalizationVersion.map {
                    SemanticIndexValidation.validIdentifier(
                        $0,
                        maximumBytes:
                            SemanticIndexLimits.maximumVersionBytes
                    )
                } == true
        }
        guard SemanticIndexValidation.validIdentifier(
                generation.identifier
              ),
              validEmbeddingContract,
              SemanticIndexValidation.validIdentifier(
                generation.chunkerVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                generation.normalizationVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              SemanticIndexValidation.validIdentifier(
                generation.sourceSchemaVersion,
                maximumBytes: SemanticIndexLimits.maximumVersionBytes
              ),
              (generation.state == .stale)
                == (generation.staleReason != nil),
              generation.configurationFingerprint ==
                legacyConfigurationFingerprintV2(generation),
              SemanticIndexValidation.validSHA256(
                generation.sourceManifestDigest
              ),
              generation.sourceManifestDigest ==
                bindingDigest(
                    configurationFingerprint:
                        generation.configurationFingerprint,
                    sourceBindings: try legacySourceBindings(
                        generationIdentifier: generation.identifier,
                        db: db
                    ),
                    highWatermarks: try legacyHighWatermarks(
                        generationIdentifier: generation.identifier,
                        db: db
                    )
                )
        else {
            throw SemanticIndexFailureCode.databaseCorrupt
        }
    }

    private static func legacyConfigurationFingerprintV2(
        _ generation: LegacyGenerationV2
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "2",
                generation.retrievalCapability.rawValue,
                generation.embeddingModelIdentifier ?? "",
                generation.embeddingModelDigest ?? "",
                generation.vectorDimension.map(String.init) ?? "",
                generation.ollamaRuntimeVersion ?? "",
                generation.embeddingRequestProfileVersion ?? "",
                generation.embeddingRequestProfileHash ?? "",
                generation.embeddingDimensions.map(String.init)
                    ?? "model_default",
                generation.embeddingTruncate.map {
                    $0 ? "true" : "false"
                } ?? "",
                generation.embeddingNormalizationVersion ?? "",
                generation.chunkerVersion,
                generation.normalizationVersion,
                generation.sourceSchemaVersion,
            ])
        )
    }

    private static func unknownScopeSpec(
        from generation: LegacyGenerationV1
    ) throws -> SemanticIndexGenerationSpec {
        switch generation.retrievalCapability {
        case .lexicalOnly:
            return try .init(
                indexSchemaVersion: SemanticIndexLimits.schemaVersion,
                retrievalCapability: .lexicalOnly,
                embeddingModelIdentifier: nil,
                embeddingModelDigest: nil,
                vectorDimension: nil,
                ollamaRuntimeVersion: nil,
                embeddingRequestProfileVersion: nil,
                embeddingRequestProfileHash: nil,
                embeddingDimensions: nil,
                embeddingTruncate: nil,
                embeddingNormalizationVersion: nil,
                chunkerVersion: generation.chunkerVersion,
                normalizationVersion: generation.normalizationVersion,
                sourceSchemaVersion: generation.sourceSchemaVersion,
                buildScope: nil
            )
        case .hybrid:
            return try .init(
                indexSchemaVersion: SemanticIndexLimits.schemaVersion,
                retrievalCapability: .hybrid,
                embeddingModelIdentifier:
                    generation.embeddingModelIdentifier,
                embeddingModelDigest: generation.embeddingModelDigest,
                vectorDimension: generation.vectorDimension,
                ollamaRuntimeVersion: "legacy-unbound",
                embeddingRequestProfileVersion:
                    "agent-loki.embedding-request-profile.legacy-unbound",
                embeddingRequestProfileHash: SemanticIndexDigest.sha256(
                    "agent-loki.semantic-index.v1.unbound-request-profile"
                ),
                embeddingDimensions: nil,
                embeddingTruncate: false,
                embeddingNormalizationVersion: "legacy-unbound",
                chunkerVersion: generation.chunkerVersion,
                normalizationVersion: generation.normalizationVersion,
                sourceSchemaVersion: generation.sourceSchemaVersion,
                buildScope: nil
            )
        }
    }

    private static func unknownScopeSpec(
        from generation: LegacyGenerationV2
    ) throws -> SemanticIndexGenerationSpec {
        try .init(
            indexSchemaVersion: SemanticIndexLimits.schemaVersion,
            retrievalCapability: generation.retrievalCapability,
            embeddingModelIdentifier:
                generation.embeddingModelIdentifier,
            embeddingModelDigest: generation.embeddingModelDigest,
            vectorDimension: generation.vectorDimension,
            ollamaRuntimeVersion: generation.ollamaRuntimeVersion,
            embeddingRequestProfileVersion:
                generation.embeddingRequestProfileVersion,
            embeddingRequestProfileHash:
                generation.embeddingRequestProfileHash,
            embeddingDimensions: generation.embeddingDimensions,
            embeddingTruncate: generation.embeddingTruncate,
            embeddingNormalizationVersion:
                generation.embeddingNormalizationVersion,
            chunkerVersion: generation.chunkerVersion,
            normalizationVersion: generation.normalizationVersion,
            sourceSchemaVersion: generation.sourceSchemaVersion,
            buildScope: nil
        )
    }

    private static func legacySourceBindings(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        try query(
            db,
            sql: """
                SELECT source_id, source_hash, tombstoned
                FROM semantic_sources
                WHERE generation_id = ?
                ORDER BY source_id
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            values[text(statement, 0)] =
                "\(text(statement, 1))|\(sqlite3_column_int(statement, 2) == 1 ? "tombstone" : "available")"
        }
        return values
    }

    private static func legacyHighWatermarks(
        generationIdentifier: String,
        db: OpaquePointer
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        try query(
            db,
            sql: """
                SELECT stream_id, high_watermark
                FROM semantic_high_watermarks
                WHERE generation_id = ?
                ORDER BY stream_id
                """,
            binds: [.text(generationIdentifier)]
        ) { statement in
            values[text(statement, 0)] = text(statement, 1)
        }
        return values
    }

    private static func foreignKeysAreValid(_ db: OpaquePointer) throws -> Bool {
        var valid = true
        try query(db, sql: "PRAGMA foreign_key_check") { _ in valid = false }
        return valid
    }

    private static var schemaStatements: [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS semantic_metadata(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_features(
                name TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_generations(
                id TEXT PRIMARY KEY,
                index_schema_version INTEGER NOT NULL,
                retrieval_capability TEXT NOT NULL
                    CHECK(retrieval_capability IN ('lexical_only','hybrid')),
                embedding_model_identifier TEXT,
                embedding_model_digest TEXT,
                vector_dimension INTEGER CHECK(
                    vector_dimension IS NULL OR vector_dimension > 0
                ),
                ollama_runtime_version TEXT,
                embedding_request_profile_version TEXT,
                embedding_request_profile_hash TEXT,
                embedding_dimensions INTEGER CHECK(
                    embedding_dimensions IS NULL OR embedding_dimensions > 0
                ),
                embedding_truncate INTEGER CHECK(
                    embedding_truncate IS NULL OR embedding_truncate IN (0,1)
                ),
                embedding_normalization_version TEXT,
                chunker_version TEXT NOT NULL,
                normalization_version TEXT NOT NULL,
                source_schema_version TEXT NOT NULL,
                configuration_fingerprint TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('building','ready','stale','paused','corrupt')),
                stale_reason TEXT CHECK(
                    stale_reason IS NULL OR stale_reason IN (
                        'semantic_index_embedding_runtime_profile_stale',
                        'semantic_index_canonical_source_policy_stale'
                    )
                ),
                source_manifest_digest TEXT NOT NULL,
                source_authority_contract_version TEXT,
                source_allowlist TEXT,
                source_allowlist_hash TEXT,
                source_request_timestamp INTEGER,
                source_build_initiation TEXT,
                source_authorization_receipt_id TEXT,
                source_adapter_contract_versions TEXT,
                source_authority_state TEXT NOT NULL
                    CHECK(source_authority_state IN (
                        'source_scope_ready',
                        'source_scope_unknown',
                        'source_scope_changed',
                        'source_permission_revoked',
                        'source_scope_violation',
                        'source_scope_rebuild_required'
                    )),
                CHECK(
                    (
                        state = 'stale'
                        AND stale_reason IS NOT NULL
                    )
                    OR
                    (
                        state <> 'stale'
                        AND stale_reason IS NULL
                    )
                ),
                CHECK(
                    (
                        retrieval_capability = 'lexical_only'
                        AND embedding_model_identifier IS NULL
                        AND embedding_model_digest IS NULL
                        AND vector_dimension IS NULL
                        AND ollama_runtime_version IS NULL
                        AND embedding_request_profile_version IS NULL
                        AND embedding_request_profile_hash IS NULL
                        AND embedding_dimensions IS NULL
                        AND embedding_truncate IS NULL
                        AND embedding_normalization_version IS NULL
                    )
                    OR
                    (
                        retrieval_capability = 'hybrid'
                        AND embedding_model_identifier IS NOT NULL
                        AND embedding_model_digest IS NOT NULL
                        AND vector_dimension IS NOT NULL
                        AND ollama_runtime_version IS NOT NULL
                        AND embedding_request_profile_version IS NOT NULL
                        AND embedding_request_profile_hash IS NOT NULL
                        AND embedding_truncate IS NOT NULL
                        AND embedding_normalization_version IS NOT NULL
                    )
                )
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_sources(
                generation_id TEXT NOT NULL
                    REFERENCES semantic_generations(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_hash TEXT NOT NULL,
                source_timestamp INTEGER NOT NULL,
                tombstoned INTEGER NOT NULL CHECK(tombstoned IN (0,1)),
                provider TEXT NOT NULL,
                pseudonymous_account_id TEXT,
                remote_record_id TEXT,
                parent_thread_id TEXT,
                source_url TEXT,
                provenance_receipt_hash TEXT NOT NULL,
                PRIMARY KEY(generation_id, source_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_chunks(
                generation_id TEXT NOT NULL,
                chunk_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL CHECK(chunk_index >= 0),
                chunk_hash TEXT NOT NULL,
                normalized_text TEXT NOT NULL,
                vector BLOB,
                vector_dimension INTEGER CHECK(
                    vector_dimension IS NULL OR vector_dimension > 0
                ),
                CHECK(
                    (vector IS NULL AND vector_dimension IS NULL)
                    OR
                    (vector IS NOT NULL AND vector_dimension IS NOT NULL)
                ),
                PRIMARY KEY(generation_id, chunk_id),
                UNIQUE(generation_id, source_id, chunk_index),
                FOREIGN KEY(generation_id, source_id)
                    REFERENCES semantic_sources(generation_id, source_id)
                    ON DELETE CASCADE
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_high_watermarks(
                generation_id TEXT NOT NULL
                    REFERENCES semantic_generations(id) ON DELETE CASCADE,
                stream_id TEXT NOT NULL,
                high_watermark TEXT NOT NULL,
                PRIMARY KEY(generation_id, stream_id)
            ) STRICT
            """,
            """
            CREATE TABLE IF NOT EXISTS semantic_checkpoints(
                run_id TEXT PRIMARY KEY,
                generation_id TEXT NOT NULL
                    REFERENCES semantic_generations(id) ON DELETE CASCADE,
                stream_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                adapter_contract_version TEXT NOT NULL,
                source_allowlist_hash TEXT NOT NULL,
                authorization_receipt_id TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN (
                    'preparing','awaiting_embeddings','running','paused','cancelled','complete'
                )),
                current_cursor TEXT,
                next_cursor TEXT,
                source_high_watermark TEXT,
                batches_committed INTEGER NOT NULL CHECK(batches_committed >= 0),
                records_seen INTEGER NOT NULL CHECK(records_seen >= 0),
                records_committed INTEGER NOT NULL CHECK(records_committed >= 0),
                records_unchanged INTEGER NOT NULL CHECK(records_unchanged >= 0),
                records_excluded INTEGER NOT NULL CHECK(records_excluded >= 0),
                tombstones_committed INTEGER NOT NULL CHECK(tombstones_committed >= 0),
                chunks_committed INTEGER NOT NULL CHECK(chunks_committed >= 0),
                pending_chunk_count INTEGER NOT NULL CHECK(pending_chunk_count >= 0),
                updated_at INTEGER NOT NULL
            ) STRICT
            """,
            """
            CREATE INDEX IF NOT EXISTS semantic_sources_generation_date_idx
            ON semantic_sources(generation_id, source_timestamp DESC, source_id)
            """,
            """
            CREATE INDEX IF NOT EXISTS semantic_sources_generation_kind_idx
            ON semantic_sources(generation_id, source_kind, source_timestamp DESC)
            """,
            """
            CREATE INDEX IF NOT EXISTS semantic_chunks_source_idx
            ON semantic_chunks(generation_id, source_id, chunk_index)
            """,
        ]
    }

    private static func configureFTS(_ db: OpaquePointer) -> Bool {
        do {
            try runToCompletion(
                db,
                sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS semantic_chunks_fts USING fts5(
                        generation_id UNINDEXED,
                        chunk_id UNINDEXED,
                        normalized_text,
                        tokenize = 'unicode61 remove_diacritics 2'
                    )
                    """
            )
            try execute(
                db,
                sql: """
                    INSERT INTO semantic_chunks_fts(semantic_chunks_fts)
                    VALUES('integrity-check')
                    """
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - SQLite primitives

    private static func withTransaction(
        _ db: OpaquePointer,
        body: () throws -> Void
    ) throws {
        try runToCompletion(db, sql: "BEGIN IMMEDIATE")
        do {
            try body()
            try runToCompletion(db, sql: "COMMIT")
        } catch {
            try? runToCompletion(db, sql: "ROLLBACK")
            throw error
        }
    }

    private static func withTransactionResult<Result>(
        _ db: OpaquePointer,
        body: () throws -> Result
    ) throws -> Result {
        try runToCompletion(db, sql: "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try runToCompletion(db, sql: "COMMIT")
            return result
        } catch {
            try? runToCompletion(db, sql: "ROLLBACK")
            throw error
        }
    }

    private static func execute(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = []
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw sqliteFailure(db) }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteFailure(db)
        }
    }

    private static func query(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw sqliteFailure(db) }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, db: db)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw sqliteFailure(db)
            }
        }
    }

    private static func runToCompletion(
        _ db: OpaquePointer,
        sql: String
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else { throw sqliteFailure(db, code: result) }
    }

    private static func bind(
        _ values: [SQLValue],
        to statement: OpaquePointer,
        db: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .blob(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(value.count),
                        transient
                    )
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteFailure(db, code: result) }
        }
    }

    private static func scalarInt(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = []
    ) throws -> Int64 {
        var value: Int64?
        try query(db, sql: sql, binds: binds) {
            value = sqlite3_column_int64($0, 0)
        }
        guard let value else { throw SemanticIndexFailureCode.databaseCorrupt }
        return value
    }

    private static func scalarText(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = []
    ) throws -> String {
        var value: String?
        try query(db, sql: sql, binds: binds) { value = text($0, 0) }
        guard let value else { throw SemanticIndexFailureCode.databaseCorrupt }
        return value
    }

    private static func optionalScalarText(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = []
    ) throws -> String? {
        var value: String?
        try query(db, sql: sql, binds: binds) { value = text($0, 0) }
        return value
    }

    private static func stringColumn(
        _ db: OpaquePointer,
        sql: String,
        binds: [SQLValue] = []
    ) throws -> [String] {
        var values: [String] = []
        try query(db, sql: sql, binds: binds) { values.append(text($0, 0)) }
        return values
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func optionalText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : text(statement, column)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(
            timeIntervalSince1970:
                Double(sqlite3_column_int64(statement, column)) / 1_000
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func sqliteFailure(
        _ db: OpaquePointer,
        code: Int32? = nil
    ) -> SemanticIndexFailureCode {
        let value = code ?? sqlite3_errcode(db)
        if value == SQLITE_BUSY || value == SQLITE_LOCKED { return .databaseBusy }
        if value == SQLITE_CORRUPT || value == SQLITE_NOTADB { return .databaseCorrupt }
        return .sqliteFailure
    }
}

enum SemanticIndexValidation {
    static func validIdentifier(
        _ value: String,
        maximumBytes: Int = SemanticIndexLimits.maximumIdentifierBytes
    ) -> Bool {
        !value.isEmpty &&
            value.lengthOfBytes(using: .utf8) <= maximumBytes &&
            !value.unicodeScalars.contains(where: isUnsafeScalar)
    }

    static func validOptionalIdentifier(_ value: String?) -> Bool {
        value.map { validIdentifier($0) } ?? true
    }

    static func validOptionalBoundedValue(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
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

enum SemanticIndexDigest {
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func lengthPrefixed(_ values: [String]) -> String {
        values.map { "\($0.lengthOfBytes(using: .utf8)):\($0)" }
            .joined(separator: "|")
    }

    static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}
