import CryptoKit
import Foundation

enum VaultEntitlementCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case localArchive = "local_archive"
    case multiAccount = "multi_account"
    case historicalBackfill = "historical_backfill"
    case extendedRetention = "extended_retention"
    case fullTextSearch = "full_text_search"
    case crossAccountSearch = "cross_account_search"
    case archiveExport = "archive_export"
    case storageAnalytics = "storage_analytics"
    case scheduledSync = "scheduled_sync"
    case dailyBriefScheduling = "daily_brief_scheduling"
    case backgroundForwardSync = "background_forward_sync"
    case multipleAccountScheduledSync = "multiple_account_scheduled_sync"
    case scheduledLocalModelProcessing = "scheduled_local_model_processing"
    case advancedLocalModelProcessing = "advanced_local_model_processing"
}

enum LokiPaidFeature: String, Codable, CaseIterable, Hashable, Sendable {
    case multipleAccounts = "multiple_accounts"
    case historicalBackfill = "historical_backfill"
    case extendedRetention = "extended_retention"
    case fullTextSearch = "full_text_search"
    case crossAccountSearch = "cross_account_search"
    case archiveExport = "archive_export"
    case storageAnalytics = "storage_analytics"
    case scheduledSync = "scheduled_sync"
    case dailyBriefScheduling = "daily_brief_scheduling"
    case backgroundForwardSync = "background_forward_sync"
    case multipleAccountScheduledSync = "multiple_account_scheduled_sync"
    case scheduledLocalModelProcessing = "scheduled_local_model_processing"
    case advancedLocalModelProcessing = "advanced_local_model_processing"
}

struct FeatureEntitlement: Codable, Hashable, Sendable {
    let feature: LokiPaidFeature
    let state: VaultEntitlementState
    let acquisitionAllowed: Bool
    let reasonCode: String

    /// Existing data ownership actions are intentionally independent of
    /// acquisition state and remain available even after expiry.
    var existingDataReadable: Bool { true }
    var exportAllowed: Bool { true }
    var deletionAllowed: Bool { true }
}

protocol FeatureEntitlementProvider: Sendable {
    func entitlement(for feature: LokiPaidFeature) async -> FeatureEntitlement
}

/// Loki Brief 1.0 is a free early-access release. The provider-neutral
/// entitlement boundary remains in place for a future paid release, while
/// every local feature implemented in RC1 is available without an account,
/// payment, receipt, license key, or cloud entitlement service.
struct LokiBriefEarlyAccessEntitlementProvider: FeatureEntitlementProvider {
    static let policyName = "Loki Brief 1.0 Early Access"
    static let includedFeatures: Set<LokiPaidFeature> = [
        .multipleAccounts,
        .historicalBackfill,
        .extendedRetention,
        .fullTextSearch,
        .crossAccountSearch,
        .archiveExport,
        .storageAnalytics,
        .scheduledSync,
        .dailyBriefScheduling,
        .backgroundForwardSync,
        .multipleAccountScheduledSync,
        .scheduledLocalModelProcessing,
    ]
    static let futureFeaturesNotOffered: Set<LokiPaidFeature> = [
        .advancedLocalModelProcessing,
    ]

    func entitlement(for feature: LokiPaidFeature) async -> FeatureEntitlement {
        guard Self.includedFeatures.contains(feature) else {
            return .init(
                feature: feature,
                state: .unavailable,
                acquisitionAllowed: false,
                reasonCode: "loki_brief_early_access_feature_not_offered"
            )
        }
        return .init(
            feature: feature,
            state: .available,
            acquisitionAllowed: true,
            reasonCode: "loki_brief_early_access_included"
        )
    }
}

enum LokiBriefPresentation {
    static func feedFormat(for rawValue: String) -> String {
        switch rawValue {
        case "rss2": "RSS 2.0"
        case "atom1": "Atom 1.0"
        case "jsonFeed11": "JSON Feed 1.1"
        default: "Unknown feed format"
        }
    }

    static func slackScope(for rawValue: String) -> String {
        switch rawValue {
        case "channels:read": "Public channels"
        case "channels:history": "Public channel history"
        case "groups:read": "Private channels"
        case "groups:history": "Private channel history"
        case "users:read": "Workspace member profiles"
        default: "Read-only workspace access"
        }
    }

    static func label(for rawValue: String) -> String {
        let separatedCamelCase = rawValue.reduce(into: "") { result, character in
            if character.isUppercase, let previous = result.last, previous.isLowercase || previous.isNumber {
                result.append("_")
            }
            result.append(character)
        }
        let words = separatedCamelCase
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
            .map { $0.lowercased() }
        guard !words.isEmpty else { return "Unknown" }
        return words.joined(separator: " ").capitalized
    }

    /// Convert bounded internal reason codes into stable consumer copy. Raw
    /// codes remain available in structured local logs and are never rendered.
    static func reason(for reasonCode: String) -> String {
        let code = reasonCode.lowercased()
        if code == "no_active_delivery_run" { return "No delivery run is active." }
        if code == "none" { return "No stop condition was recorded." }
        if code == "loki_brief_early_access_included" || code == "vault_entitlement_available" { return "Included with Loki Brief 1.0 Early Access." }
        if code == "scheduled_vault_reconciliation_no_new_evidence" { return "No new evidence required Vault reconciliation." }
        if code == "scheduled_local_presentation_disabled" { return "Local model presentation was not requested; deterministic output was preserved." }
        if code.hasSuffix("_partially_completed") || code.hasSuffix("_partial") { return "The operation completed with some source issues." }
        if code.hasSuffix("_complete") || code.hasSuffix("_completed") || code.hasSuffix("_success") || code.hasSuffix("_succeeded") { return "The operation completed." }
        if code.hasSuffix("_started") || code.hasSuffix("_preparing") || code.hasSuffix("_queued") || code.hasSuffix("_running") { return "The operation is in progress." }
        if code.contains("not_started") || code.contains("disabled_after_delete") { return "The operation is currently off." }
        if code.contains("rate_limit") { return "The provider is temporarily rate-limited. Loki Brief will wait before retrying." }
        if code.contains("reauthor") || code.contains("token_expired") || code.contains("invalid_auth") { return "Reconnect the source to continue." }
        if code.contains("configuration_required") { return "This source is not configured in the current build." }
        if code.contains("entitlement") { return "This feature is not included in the current release." }
        if code.contains("cancel") { return "The operation was cancelled." }
        if code.contains("timeout") || code.contains("timed_out") { return "The operation timed out without changing existing data." }
        if code.contains("budget") || code.contains("limit") { return "The operation reached a safety limit and stopped without discarding existing data." }
        if code.contains("authorization") || code.contains("permission") { return "Authorization is required before this operation can continue." }
        if code.contains("network") || code.contains("unavailable") { return "The requested service is currently unavailable." }
        if code.contains("not_found") { return "The requested item is no longer available." }
        if code.contains("failed") || code.contains("error") { return "The operation could not be completed. Retry or review the related settings." }
        return "The operation needs attention. Retry or review the related settings."
    }

    /// Preserve bounded, consumer-written messages while preventing local
    /// filesystem locations and identifier-shaped diagnostics from reaching
    /// alerts or status surfaces. Full diagnostics remain in local logs.
    static func message(for rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "The operation needs attention. Retry or review the related settings." }
        let lowercased = value.lowercased()
        let privateLocationMarkers = ["/users/", "/private/", "/tmp/", "/var/folders/", "file://"]
        if privateLocationMarkers.contains(where: lowercased.contains) {
            return "The operation could not be completed. Existing data was preserved; retry or review the related settings."
        }
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let identifierTokens = value.components(separatedBy: identifierCharacters.inverted)
        if let identifier = identifierTokens.first(where: {
            $0.contains("_") && $0.unicodeScalars.allSatisfy(identifierCharacters.contains)
        }) {
            return reason(for: identifier)
        }
        return String(value.prefix(500))
    }
}

/// Preserved for compatibility tests and future fail-closed compositions.
/// Loki Brief 1.0 Release uses `LokiBriefEarlyAccessEntitlementProvider`.
struct UnconfiguredFeatureEntitlementProvider: FeatureEntitlementProvider {
    func entitlement(for feature: LokiPaidFeature) async -> FeatureEntitlement {
        .init(
            feature: feature,
            state: .providerNotConfigured,
            acquisitionAllowed: false,
            reasonCode: "vault_entitlement_provider_not_configured"
        )
    }
}

struct DeterministicDevelopmentEntitlementProvider: FeatureEntitlementProvider {
    let states: [LokiPaidFeature: VaultEntitlementState]

    init(states: [LokiPaidFeature: VaultEntitlementState] = [:]) {
        self.states = states
    }

    func entitlement(for feature: LokiPaidFeature) async -> FeatureEntitlement {
        let state = states[feature] ?? .providerNotConfigured
        let acquisitionAllowed = [.available, .trial, .subscribed, .gracePeriod].contains(state)
        return .init(
            feature: feature,
            state: state,
            acquisitionAllowed: acquisitionAllowed,
            reasonCode: acquisitionAllowed ? "vault_entitlement_available" : "vault_entitlement_\(state.rawValue)"
        )
    }
}

struct VaultEntitlementEvidence: Codable, Hashable, Sendable {
    let id: String
    let ownerID: String
    let productID: String
    let source: VaultEntitlementSource
    let state: VaultEntitlementState
    let capabilities: Set<VaultEntitlementCapability>
    let validFrom: Date
    let validThrough: Date?
    let observedAt: Date
    let configurationFingerprint: String
}

enum VaultEntitlementReason: String, Codable, Sendable {
    case granted = "entitlement_granted"
    case invalidOwner = "entitlement_owner_invalid"
    case ownerMismatch = "entitlement_owner_mismatch"
    case unavailable = "entitlement_unavailable"
    case invalidEvidence = "entitlement_evidence_invalid"
    case notYetValid = "entitlement_not_yet_valid"
    case expired = "entitlement_expired"
    case revoked = "entitlement_revoked"
    case inactive = "entitlement_inactive"
}

struct VaultEntitlementDecision: Codable, Hashable, Sendable {
    let ownerID: String
    let capability: VaultEntitlementCapability
    let granted: Bool
    let reason: VaultEntitlementReason
    let evidenceID: String?
    let evaluatedAt: Date
}

struct VaultEntitlementEvaluator: Sendable {
    func decision(
        ownerID: String,
        capability: VaultEntitlementCapability,
        at evaluatedAt: Date,
        evidence: [VaultEntitlementEvidence]
    ) -> VaultEntitlementDecision {
        guard VaultControlValidation.validIdentifier(ownerID) else {
            return denied(ownerID, capability, .invalidOwner, nil, evaluatedAt)
        }

        let visibleEvidence = evidence.filter { $0.observedAt <= evaluatedAt && $0.capabilities.contains(capability) }
        let ownedEvidence = visibleEvidence.filter { $0.ownerID == ownerID }
        guard !ownedEvidence.isEmpty else {
            let reason: VaultEntitlementReason = visibleEvidence.isEmpty ? .unavailable : .ownerMismatch
            return denied(ownerID, capability, reason, nil, evaluatedAt)
        }

        let selected = ownedEvidence.sorted(by: entitlementPrecedes).first!
        guard validEvidenceShape(selected) else {
            return denied(ownerID, capability, .invalidEvidence, selected.id, evaluatedAt)
        }
        guard selected.validFrom <= evaluatedAt else {
            return denied(ownerID, capability, .notYetValid, selected.id, evaluatedAt)
        }
        if let validThrough = selected.validThrough, validThrough < evaluatedAt {
            return denied(ownerID, capability, .expired, selected.id, evaluatedAt)
        }

        switch selected.state {
        case .available, .trial, .subscribed, .gracePeriod:
            return .init(
                ownerID: ownerID,
                capability: capability,
                granted: true,
                reason: .granted,
                evidenceID: selected.id,
                evaluatedAt: evaluatedAt
            )
        case .expired:
            return denied(ownerID, capability, .expired, selected.id, evaluatedAt)
        case .unavailable, .providerNotConfigured:
            return denied(ownerID, capability, .inactive, selected.id, evaluatedAt)
        }
    }

    private func entitlementPrecedes(_ lhs: VaultEntitlementEvidence, _ rhs: VaultEntitlementEvidence) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        let lhsRank = sourceRank(lhs.source)
        let rhsRank = sourceRank(rhs.source)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.id < rhs.id
    }

    private func sourceRank(_ source: VaultEntitlementSource) -> Int {
        switch source {
        case .deterministicDevelopment: 0
        case .providerNotConfigured: 1
        }
    }

    private func validEvidenceShape(_ evidence: VaultEntitlementEvidence) -> Bool {
        VaultControlValidation.validIdentifier(evidence.id)
            && VaultControlValidation.validIdentifier(evidence.ownerID)
            && VaultControlValidation.validIdentifier(evidence.productID)
            && !evidence.configurationFingerprint.isEmpty
            && evidence.validThrough.map { $0 >= evidence.validFrom } != false
    }

    private func denied(
        _ ownerID: String,
        _ capability: VaultEntitlementCapability,
        _ reason: VaultEntitlementReason,
        _ evidenceID: String?,
        _ evaluatedAt: Date
    ) -> VaultEntitlementDecision {
        .init(
            ownerID: ownerID,
            capability: capability,
            granted: false,
            reason: reason,
            evidenceID: evidenceID,
            evaluatedAt: evaluatedAt
        )
    }
}

protocol VaultEntitlementEvidenceReading: Sendable {
    func entitlementEvidence(ownerID: String) async throws -> [VaultEntitlementEvidence]
}

protocol VaultEntitlementAuthorizing: Sendable {
    func decision(
        ownerID: String,
        capability: VaultEntitlementCapability,
        at date: Date
    ) async throws -> VaultEntitlementDecision
}

actor VaultDeterministicEntitlementService: VaultEntitlementAuthorizing {
    private let reader: any VaultEntitlementEvidenceReading
    private let evaluator: VaultEntitlementEvaluator

    init(
        reader: any VaultEntitlementEvidenceReading,
        evaluator: VaultEntitlementEvaluator = .init()
    ) {
        self.reader = reader
        self.evaluator = evaluator
    }

    func decision(
        ownerID: String,
        capability: VaultEntitlementCapability,
        at date: Date
    ) async throws -> VaultEntitlementDecision {
        let evidence = try await reader.entitlementEvidence(ownerID: ownerID)
        return evaluator.decision(ownerID: ownerID, capability: capability, at: date, evidence: evidence)
    }
}

struct VaultUnavailableEntitlementAuthorizer: VaultEntitlementAuthorizing {
    func decision(
        ownerID: String,
        capability: VaultEntitlementCapability,
        at date: Date
    ) async throws -> VaultEntitlementDecision {
        .init(
            ownerID: ownerID,
            capability: capability,
            granted: false,
            reason: .unavailable,
            evidenceID: nil,
            evaluatedAt: date
        )
    }
}

enum VaultImportOriginalRepresentation: String, Codable, Sendable {
    case p2NormalizedFeedEntry = "p2_normalized_feed_entry"
    case p3NormalizedSlackEvidence = "p3_normalized_slack_evidence"
}

struct VaultImportOriginal: Codable, Hashable, Sendable {
    let representation: VaultImportOriginalRepresentation
    let mediaType: String
    let sha256: String

    init(
        representation: VaultImportOriginalRepresentation,
        mediaType: String = "application/json",
        payload: Data
    ) {
        self.representation = representation
        self.mediaType = mediaType
        self.sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

struct VaultImportEvidence: Codable, Hashable, Sendable {
    let stableID: String
    let ownerID: String
    let accountID: String
    let containerID: String
    let sourceKind: VaultProviderKind
    let sourceItemID: String
    let sourceObservedAt: Date
    let searchableText: String
    let original: VaultImportOriginal
}

struct VaultImportPage: Codable, Hashable, Sendable {
    let items: [VaultImportEvidence]
    let nextCursor: String?
    let sourceHighWatermark: String?
}

protocol VaultImportSourceReading: Sendable {
    var sourceKind: VaultProviderKind { get }
    func readPage(after cursor: String?, limit: Int) async throws -> VaultImportPage
}

protocol VaultFeedEvidenceReading: Sendable {
    func readFeedEvidencePage(after cursor: String?, limit: Int) async throws -> VaultImportPage
}

protocol VaultSlackEvidenceReading: Sendable {
    func readSlackEvidencePage(after cursor: String?, limit: Int) async throws -> VaultImportPage
}

struct VaultFeedImportSourceAdapter<Reader: VaultFeedEvidenceReading>: VaultImportSourceReading {
    let reader: Reader
    let sourceKind = VaultProviderKind.rss

    func readPage(after cursor: String?, limit: Int) async throws -> VaultImportPage {
        try await reader.readFeedEvidencePage(after: cursor, limit: limit)
    }
}

struct VaultSlackImportSourceAdapter<Reader: VaultSlackEvidenceReading>: VaultImportSourceReading {
    let reader: Reader
    let sourceKind = VaultProviderKind.slack

    func readPage(after cursor: String?, limit: Int) async throws -> VaultImportPage {
        try await reader.readSlackEvidencePage(after: cursor, limit: limit)
    }
}

enum VaultArchiveInsertOutcome: Hashable, Sendable {
    case inserted(storedOriginalSHA256: String)
    case duplicate(existingOriginalSHA256: String)
}

protocol VaultImportArchiveWriting: Sendable {
    func insertIfAbsent(_ evidence: VaultImportEvidence) async throws -> VaultArchiveInsertOutcome
}

struct VaultImportCheckpoint: Codable, Hashable, Sendable {
    let id: String
    let ownerID: String
    let accountID: String
    let containerID: String
    let sourceKind: VaultProviderKind
    var runID: String
    var state: VaultImportCheckpointState
    var sourceCursor: String?
    var sourceHighWatermark: String?
    var pagesCommitted: Int
    var itemsRead: Int
    var itemsInserted: Int
    var duplicateItems: Int
    var lastReasonCode: String?
    let createdAt: Date
    var updatedAt: Date
}

protocol VaultImportCheckpointPersisting: Sendable {
    func checkpoint(id: String) async throws -> VaultImportCheckpoint?
    func save(_ checkpoint: VaultImportCheckpoint) async throws
}

struct VaultImportRequest: Codable, Hashable, Sendable {
    let runID: String
    let ownerID: String
    let accountID: String
    let containerID: String
    let sourceKind: VaultProviderKind
    let maximumPages: Int
    let maximumItems: Int
    let pageSize: Int

    init(
        runID: String,
        ownerID: String,
        accountID: String,
        containerID: String,
        sourceKind: VaultProviderKind,
        maximumPages: Int = 100,
        maximumItems: Int = 10_000,
        pageSize: Int = 100
    ) {
        self.runID = runID
        self.ownerID = ownerID
        self.accountID = accountID
        self.containerID = containerID
        self.sourceKind = sourceKind
        self.maximumPages = min(max(maximumPages, 1), VaultControlValidation.maximumBackfillPages)
        self.maximumItems = min(max(maximumItems, 1), VaultControlValidation.maximumBackfillItems)
        self.pageSize = min(max(pageSize, 1), 200)
    }

    var checkpointID: String {
        [ownerID, sourceKind.rawValue, accountID, containerID]
            .map { "\($0.lengthOfBytes(using: .utf8)):\($0)" }
            .joined(separator: "|")
    }
}

struct VaultImportSummary: Codable, Hashable, Sendable {
    let runID: String
    let checkpointID: String
    let state: VaultBackfillState
    let pagesReadThisRun: Int
    let itemsReadThisRun: Int
    let itemsInsertedThisRun: Int
    let duplicateItemsThisRun: Int
    let cumulativePagesCommitted: Int
    let cumulativeItemsInserted: Int
    let reasonCode: String
    let completedAt: Date
}

enum VaultImportFailureCode: String, Error, Codable, Sendable {
    case invalidRequest = "vault_import_request_invalid"
    case sourceMismatch = "vault_import_source_mismatch"
    case checkpointOwnershipMismatch = "vault_checkpoint_ownership_mismatch"
    case entitlementDenied = "vault_backfill_entitlement_denied"
    case pageLimitExceeded = "vault_import_page_limit_exceeded"
    case evidenceOwnershipMismatch = "vault_import_evidence_ownership_mismatch"
    case evidenceInvalid = "vault_import_evidence_invalid"
    case originalConflict = "vault_import_original_conflict"
    case cursorDidNotAdvance = "vault_import_cursor_did_not_advance"
}

extension VaultImportFailureCode: LocalizedError {
    var errorDescription: String? { rawValue }
}

protocol VaultImportRunning: Sendable {
    func run(_ request: VaultImportRequest) async throws -> VaultImportSummary
}

actor VaultImportCoordinator: VaultImportRunning {
    private let source: any VaultImportSourceReading
    private let archive: any VaultImportArchiveWriting
    private let checkpoints: any VaultImportCheckpointPersisting
    private let entitlements: any VaultEntitlementAuthorizing
    private let now: @Sendable () -> Date

    init(
        source: any VaultImportSourceReading,
        archive: any VaultImportArchiveWriting,
        checkpoints: any VaultImportCheckpointPersisting,
        entitlements: any VaultEntitlementAuthorizing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.archive = archive
        self.checkpoints = checkpoints
        self.entitlements = entitlements
        self.now = now
    }

    func run(_ request: VaultImportRequest) async throws -> VaultImportSummary {
        try validate(request)
        guard source.sourceKind == request.sourceKind else { throw VaultImportFailureCode.sourceMismatch }

        let startedAt = now()
        let entitlement = try await entitlements.decision(
            ownerID: request.ownerID,
            capability: .historicalBackfill,
            at: startedAt
        )
        guard entitlement.granted, entitlement.ownerID == request.ownerID else {
            throw VaultImportFailureCode.entitlementDenied
        }

        var checkpoint = try await checkpoints.checkpoint(id: request.checkpointID)
            ?? initialCheckpoint(for: request, at: startedAt)
        try validate(checkpoint, belongsTo: request)

        if checkpoint.state == .complete {
            return summary(
                request: request,
                checkpoint: checkpoint,
                state: .complete,
                pages: 0,
                items: 0,
                inserted: 0,
                duplicates: 0,
                reason: "vault_import_already_complete",
                at: startedAt
            )
        }

        checkpoint.runID = request.runID
        checkpoint.state = .running
        checkpoint.lastReasonCode = "vault_import_started"
        checkpoint.updatedAt = startedAt
        try await checkpoints.save(checkpoint)

        var pagesThisRun = 0
        var itemsThisRun = 0
        var insertedThisRun = 0
        var duplicatesThisRun = 0

        while pagesThisRun < request.maximumPages && itemsThisRun < request.maximumItems {
            if Task.isCancelled {
                checkpoint.state = .paused
                checkpoint.lastReasonCode = "vault_import_cancelled_at_page_boundary"
                checkpoint.updatedAt = now()
                try await checkpoints.save(checkpoint)
                return summary(
                    request: request,
                    checkpoint: checkpoint,
                    state: .cancelled,
                    pages: pagesThisRun,
                    items: itemsThisRun,
                    inserted: insertedThisRun,
                    duplicates: duplicatesThisRun,
                    reason: "vault_import_cancelled_at_page_boundary",
                    at: checkpoint.updatedAt
                )
            }

            let remainingItems = request.maximumItems - itemsThisRun
            let requestedPageSize = min(request.pageSize, remainingItems)
            let priorCursor = checkpoint.sourceCursor
            let page = try await source.readPage(after: priorCursor, limit: requestedPageSize)
            guard page.items.count <= requestedPageSize else { throw VaultImportFailureCode.pageLimitExceeded }
            try validate(page, for: request)

            var pageInserted = 0
            var pageDuplicates = 0
            for evidence in page.items {
                let outcome = try await archive.insertIfAbsent(evidence)
                switch outcome {
                case let .inserted(storedDigest):
                    guard storedDigest == evidence.original.sha256 else {
                        throw VaultImportFailureCode.originalConflict
                    }
                    pageInserted += 1
                case let .duplicate(existingDigest):
                    guard existingDigest == evidence.original.sha256 else {
                        throw VaultImportFailureCode.originalConflict
                    }
                    pageDuplicates += 1
                }
            }

            if page.nextCursor != nil, page.nextCursor == priorCursor {
                throw VaultImportFailureCode.cursorDidNotAdvance
            }
            if page.items.isEmpty, page.nextCursor != nil {
                throw VaultImportFailureCode.cursorDidNotAdvance
            }

            pagesThisRun += 1
            itemsThisRun += page.items.count
            insertedThisRun += pageInserted
            duplicatesThisRun += pageDuplicates
            checkpoint.pagesCommitted += 1
            checkpoint.itemsRead += page.items.count
            checkpoint.itemsInserted += pageInserted
            checkpoint.duplicateItems += pageDuplicates
            checkpoint.sourceCursor = page.nextCursor
            checkpoint.sourceHighWatermark = page.sourceHighWatermark ?? checkpoint.sourceHighWatermark
            checkpoint.updatedAt = now()

            if page.nextCursor == nil {
                checkpoint.state = .complete
                checkpoint.lastReasonCode = "vault_import_complete"
                try await checkpoints.save(checkpoint)
                return summary(
                    request: request,
                    checkpoint: checkpoint,
                    state: .complete,
                    pages: pagesThisRun,
                    items: itemsThisRun,
                    inserted: insertedThisRun,
                    duplicates: duplicatesThisRun,
                    reason: "vault_import_complete",
                    at: checkpoint.updatedAt
                )
            }

            checkpoint.state = .running
            checkpoint.lastReasonCode = "vault_import_page_committed"
            try await checkpoints.save(checkpoint)
        }

        checkpoint.state = .paused
        checkpoint.lastReasonCode = "vault_import_budget_exhausted"
        checkpoint.updatedAt = now()
        try await checkpoints.save(checkpoint)
        return summary(
            request: request,
            checkpoint: checkpoint,
            state: .paused,
            pages: pagesThisRun,
            items: itemsThisRun,
            inserted: insertedThisRun,
            duplicates: duplicatesThisRun,
            reason: "vault_import_budget_exhausted",
            at: checkpoint.updatedAt
        )
    }

    private func validate(_ request: VaultImportRequest) throws {
        let identifiers = [request.runID, request.ownerID, request.accountID, request.containerID]
        guard identifiers.allSatisfy(VaultControlValidation.validIdentifier) else {
            throw VaultImportFailureCode.invalidRequest
        }
    }

    private func validate(_ checkpoint: VaultImportCheckpoint, belongsTo request: VaultImportRequest) throws {
        guard checkpoint.id == request.checkpointID,
              checkpoint.ownerID == request.ownerID,
              checkpoint.accountID == request.accountID,
              checkpoint.containerID == request.containerID,
              checkpoint.sourceKind == request.sourceKind
        else { throw VaultImportFailureCode.checkpointOwnershipMismatch }
    }

    private func validate(_ page: VaultImportPage, for request: VaultImportRequest) throws {
        if let cursor = page.nextCursor,
           cursor.lengthOfBytes(using: .utf8) > VaultControlValidation.maximumCursorBytes {
            throw VaultImportFailureCode.evidenceInvalid
        }
        for evidence in page.items {
            guard evidence.ownerID == request.ownerID,
                  evidence.accountID == request.accountID,
                  evidence.containerID == request.containerID,
                  evidence.sourceKind == request.sourceKind
            else { throw VaultImportFailureCode.evidenceOwnershipMismatch }
            guard VaultControlValidation.validIdentifier(evidence.stableID),
                  VaultControlValidation.validIdentifier(evidence.sourceItemID),
                  !evidence.original.mediaType.isEmpty,
                  evidence.original.sha256.count == 64
            else { throw VaultImportFailureCode.evidenceInvalid }
        }
    }

    private func initialCheckpoint(for request: VaultImportRequest, at date: Date) -> VaultImportCheckpoint {
        .init(
            id: request.checkpointID,
            ownerID: request.ownerID,
            accountID: request.accountID,
            containerID: request.containerID,
            sourceKind: request.sourceKind,
            runID: request.runID,
            state: .ready,
            sourceCursor: nil,
            sourceHighWatermark: nil,
            pagesCommitted: 0,
            itemsRead: 0,
            itemsInserted: 0,
            duplicateItems: 0,
            lastReasonCode: nil,
            createdAt: date,
            updatedAt: date
        )
    }

    private func summary(
        request: VaultImportRequest,
        checkpoint: VaultImportCheckpoint,
        state: VaultBackfillState,
        pages: Int,
        items: Int,
        inserted: Int,
        duplicates: Int,
        reason: String,
        at date: Date
    ) -> VaultImportSummary {
        .init(
            runID: request.runID,
            checkpointID: checkpoint.id,
            state: state,
            pagesReadThisRun: pages,
            itemsReadThisRun: items,
            itemsInsertedThisRun: inserted,
            duplicateItemsThisRun: duplicates,
            cumulativePagesCommitted: checkpoint.pagesCommitted,
            cumulativeItemsInserted: checkpoint.itemsInserted,
            reasonCode: reason,
            completedAt: date
        )
    }
}
