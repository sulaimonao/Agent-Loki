import CryptoKit
import Foundation

enum ScheduledBriefingRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case refreshingSources = "refreshing_sources"
    case reconcilingVault = "reconciling_vault"
    case assemblingDeterministicBrief = "assembling_deterministic_brief"
    case generatingLocalPresentation = "generating_local_presentation"
    case complete
    case partial
    case cancelled
    case failed
    case interrupted
    case skipped

    var isTerminal: Bool {
        switch self {
        case .complete, .partial, .cancelled, .failed, .interrupted, .skipped: true
        default: false
        }
    }
}

enum ScheduledRunState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case waiting
    case preparing
    case synchronizing
    case assembling
    case generatingLocally = "generating_locally"
    case persisting
    case delivering
    case completed
    case partiallyCompleted = "partially_completed"
    case skipped
    case canceled
    case failed
    case reauthorizationRequired = "reauthorization_required"
    case entitlementRequired = "entitlement_required"

    var isTerminal: Bool {
        switch self {
        case .completed, .partiallyCompleted, .skipped, .canceled, .failed, .reauthorizationRequired, .entitlementRequired: true
        default: false
        }
    }
}

enum ScheduledRunStage: String, Codable, CaseIterable, Sendable {
    case scheduling
    case preparation
    case sourceSynchronization = "source_synchronization"
    case vaultReconciliation = "vault_reconciliation"
    case deterministicAssembly = "deterministic_assembly"
    case localGeneration = "local_generation"
    case persistence
    case delivery
}

enum ScheduledRunResult: String, Codable, CaseIterable, Sendable {
    case completed
    case partiallyCompleted = "partially_completed"
    case skipped
    case canceled
    case failed
    case reauthorizationRequired = "reauthorization_required"
    case entitlementRequired = "entitlement_required"
}

struct ScheduledRunFailure: Codable, Hashable, Sendable {
    let stage: ScheduledRunStage
    let reasonCode: String
    let transient: Bool

    init(stage: ScheduledRunStage, reasonCode: String, transient: Bool = false) {
        self.stage = stage
        self.reasonCode = String(reasonCode.prefix(120))
        self.transient = transient
    }
}

enum ScheduledRunTrigger: String, Codable, CaseIterable, Sendable {
    case scheduled
    case catchUpAfterWake = "catch_up_after_wake"
    case catchUpAfterLaunch = "catch_up_after_launch"
    case manualTest = "manual_test"
    case manualRunNow = "manual_run_now"
    case retry
}

typealias ScheduledBriefingTrigger = ScheduledRunTrigger

extension ScheduledBriefingRunState {
    var scheduledRunState: ScheduledRunState {
        switch self {
        case .queued: .scheduled
        case .refreshingSources, .reconcilingVault: .synchronizing
        case .assemblingDeterministicBrief: .assembling
        case .generatingLocalPresentation: .generatingLocally
        case .complete: .completed
        case .partial: .partiallyCompleted
        case .cancelled: .canceled
        case .failed: .failed
        case .interrupted: .waiting
        case .skipped: .skipped
        }
    }
}

enum ScheduledBriefingSourceKind: String, Codable, CaseIterable, Sendable {
    case feed
    case slackWorkspace = "slack_workspace"
}

enum ScheduledBriefingStageStatus: String, Codable, CaseIterable, Sendable {
    case success
    case degraded
    case failed
    case skipped
    case cancelled

    var contributesFailure: Bool { self == .degraded || self == .failed }
}

enum ScheduledBriefingReason {
    static let queued = "scheduled_briefing_queued"
    static let sourceRefreshStarted = "scheduled_source_refresh_started"
    static let sourceRefreshComplete = "scheduled_source_refresh_complete"
    static let sourceRefreshPartial = "scheduled_source_refresh_partial"
    static let sourceRefreshFailed = "scheduled_source_refresh_failed"
    static let noEnabledSources = "scheduled_no_enabled_sources"
    static let vaultReconciliationStarted = "scheduled_vault_reconciliation_started"
    static let vaultReconciliationSkipped = "scheduled_vault_reconciliation_no_new_evidence"
    static let deterministicAssemblyStarted = "scheduled_deterministic_assembly_started"
    static let deterministicAssemblyComplete = "scheduled_deterministic_assembly_complete"
    static let localPresentationStarted = "scheduled_local_presentation_started"
    static let localPresentationDisabled = "scheduled_local_presentation_disabled"
    static let localPresentationAuthorityRejected = "scheduled_local_presentation_authority_rejected"
    static let runComplete = "scheduled_briefing_complete"
    static let runPartial = "scheduled_briefing_partial"
    static let runCancelled = "scheduled_briefing_cancelled"
    static let runFailed = "scheduled_briefing_failed"
    static let runAlreadyActive = "scheduled_briefing_run_already_active"
    static let lateResultRejected = "scheduled_briefing_late_result_rejected"
    static let persistenceFailed = "scheduled_briefing_persistence_failed"
    static let invalidPlan = "scheduled_briefing_plan_invalid"
}

struct ScheduledBriefingBudget: Codable, Hashable, Sendable {
    static let maximumAllowedFeedSources = 100
    static let maximumAllowedSlackWorkspaces = 20
    static let maximumAllowedFeedConcurrency = 8
    static let maximumAllowedFailureReasons = 64
    static let maximumAllowedDurationSeconds: TimeInterval = 5 * 60
    static let maximumAllowedFeedRequests = 100
    static let maximumAllowedSlackRequests = 400
    static let maximumAllowedNewArchiveItems = 10_000
    static let maximumAllowedStorageGrowthBytes: Int64 = 100 * 1_024 * 1_024
    static let maximumAllowedTransientRetries = 20
    static let maximumAllowedOllamaDurationSeconds: TimeInterval = 120

    let maximumFeedSources: Int
    let maximumSlackWorkspaces: Int
    let maximumFeedConcurrency: Int
    let maximumFailureReasons: Int
    let maximumTotalDurationSeconds: TimeInterval
    let maximumFeedRequests: Int
    let maximumSlackRequests: Int
    let maximumNewArchiveItems: Int
    let maximumStorageGrowthBytes: Int64
    let maximumTransientRetries: Int
    let maximumOllamaDurationSeconds: TimeInterval

    init(
        maximumFeedSources: Int = maximumAllowedFeedSources,
        maximumSlackWorkspaces: Int = maximumAllowedSlackWorkspaces,
        maximumFeedConcurrency: Int = 4,
        maximumFailureReasons: Int = maximumAllowedFailureReasons,
        maximumTotalDurationSeconds: TimeInterval = 5 * 60,
        maximumFeedRequests: Int = maximumAllowedFeedRequests,
        maximumSlackRequests: Int = 200,
        maximumNewArchiveItems: Int = 5_000,
        maximumStorageGrowthBytes: Int64 = 50 * 1_024 * 1_024,
        maximumTransientRetries: Int = 8,
        maximumOllamaDurationSeconds: TimeInterval = 60
    ) {
        self.maximumFeedSources = min(max(maximumFeedSources, 0), Self.maximumAllowedFeedSources)
        self.maximumSlackWorkspaces = min(max(maximumSlackWorkspaces, 0), Self.maximumAllowedSlackWorkspaces)
        self.maximumFeedConcurrency = min(max(maximumFeedConcurrency, 1), Self.maximumAllowedFeedConcurrency)
        self.maximumFailureReasons = min(max(maximumFailureReasons, 1), Self.maximumAllowedFailureReasons)
        self.maximumTotalDurationSeconds = min(max(maximumTotalDurationSeconds, 1), Self.maximumAllowedDurationSeconds)
        self.maximumFeedRequests = min(max(maximumFeedRequests, 0), Self.maximumAllowedFeedRequests)
        self.maximumSlackRequests = min(max(maximumSlackRequests, 0), Self.maximumAllowedSlackRequests)
        self.maximumNewArchiveItems = min(max(maximumNewArchiveItems, 0), Self.maximumAllowedNewArchiveItems)
        self.maximumStorageGrowthBytes = min(max(maximumStorageGrowthBytes, 0), Self.maximumAllowedStorageGrowthBytes)
        self.maximumTransientRetries = min(max(maximumTransientRetries, 0), Self.maximumAllowedTransientRetries)
        self.maximumOllamaDurationSeconds = min(max(maximumOllamaDurationSeconds, 1), Self.maximumAllowedOllamaDurationSeconds)
    }
}

enum ScheduledBriefingBudgetReason {
    static let durationExhausted = "scheduled_briefing_duration_budget_exhausted"
    static let feedRequestsExhausted = "scheduled_feed_request_budget_exhausted"
    static let slackRequestsExhausted = "scheduled_slack_request_budget_exhausted"
    static let transientRetriesExhausted = "scheduled_transient_retry_budget_exhausted"
    static let retryDelayExceedsRemaining = "scheduled_retry_delay_exceeds_remaining_budget"
    static let archiveItemsExhausted = "scheduled_archive_item_budget_exhausted"
    static let archiveStorageExhausted = "scheduled_archive_storage_budget_exhausted"
    static let ollamaDurationExhausted = "scheduled_ollama_duration_budget_exhausted"
}

struct ScheduledBriefingBudgetPermit: Equatable, Sendable {
    let remainingDurationSeconds: TimeInterval
}

enum ScheduledBriefingBudgetClaim: Equatable, Sendable {
    case permitted(ScheduledBriefingBudgetPermit)
    case rejected(reasonCode: String)

    var permit: ScheduledBriefingBudgetPermit? {
        guard case let .permitted(permit) = self else { return nil }
        return permit
    }

    var rejectionReasonCode: String? {
        guard case let .rejected(reasonCode) = self else { return nil }
        return reasonCode
    }
}

struct ScheduledBriefingBudgetUsage: Codable, Hashable, Sendable {
    var feedRequestCount = 0
    var slackRequestCount = 0
    var transientRetryCount = 0
    var archiveItemCount = 0
    var archiveStorageBytes: Int64 = 0
    var ollamaAllowanceMilliseconds = 0
    var ollamaElapsedMilliseconds = 0
    var exhaustionReasonCodes: [String] = []
}

actor ScheduledBriefingBudgetLedger {
    private let budget: ScheduledBriefingBudget
    private let uptime: @Sendable () -> TimeInterval
    private let deadlineUptime: TimeInterval
    private var usageState = ScheduledBriefingBudgetUsage()
    private var exhaustionReasons: Set<String> = []

    init(
        budget: ScheduledBriefingBudget,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.budget = budget
        self.uptime = uptime
        self.deadlineUptime = uptime() + budget.maximumTotalDurationSeconds
    }

    func remainingDurationSeconds() -> TimeInterval {
        max(0, deadlineUptime - uptime())
    }

    func claimFeedRequest() -> ScheduledBriefingBudgetClaim {
        guard let permit = durationPermit() else {
            return reject(ScheduledBriefingBudgetReason.durationExhausted)
        }
        guard usageState.feedRequestCount < budget.maximumFeedRequests else {
            return reject(ScheduledBriefingBudgetReason.feedRequestsExhausted)
        }
        usageState.feedRequestCount += 1
        return .permitted(permit)
    }

    func claimSlackRequest() -> ScheduledBriefingBudgetClaim {
        guard let permit = durationPermit() else {
            return reject(ScheduledBriefingBudgetReason.durationExhausted)
        }
        guard usageState.slackRequestCount < budget.maximumSlackRequests else {
            return reject(ScheduledBriefingBudgetReason.slackRequestsExhausted)
        }
        usageState.slackRequestCount += 1
        return .permitted(permit)
    }

    func claimTransientRetry(delaySeconds: TimeInterval = 0) -> ScheduledBriefingBudgetClaim {
        guard delaySeconds.isFinite, delaySeconds >= 0 else {
            return reject(ScheduledBriefingBudgetReason.retryDelayExceedsRemaining)
        }
        guard let permit = durationPermit() else {
            return reject(ScheduledBriefingBudgetReason.durationExhausted)
        }
        guard usageState.transientRetryCount < budget.maximumTransientRetries else {
            return reject(ScheduledBriefingBudgetReason.transientRetriesExhausted)
        }
        guard delaySeconds < permit.remainingDurationSeconds else {
            return reject(ScheduledBriefingBudgetReason.retryDelayExceedsRemaining)
        }
        usageState.transientRetryCount += 1
        return .permitted(.init(remainingDurationSeconds: permit.remainingDurationSeconds - delaySeconds))
    }

    func reserveArchiveItem(estimatedStorageBytes: Int64) -> ScheduledBriefingBudgetClaim {
        guard let permit = durationPermit() else {
            return reject(ScheduledBriefingBudgetReason.durationExhausted)
        }
        guard estimatedStorageBytes >= 0 else {
            return reject(ScheduledBriefingBudgetReason.archiveStorageExhausted)
        }
        guard usageState.archiveItemCount < budget.maximumNewArchiveItems else {
            return reject(ScheduledBriefingBudgetReason.archiveItemsExhausted)
        }
        guard estimatedStorageBytes <= budget.maximumStorageGrowthBytes - usageState.archiveStorageBytes else {
            return reject(ScheduledBriefingBudgetReason.archiveStorageExhausted)
        }
        usageState.archiveItemCount += 1
        usageState.archiveStorageBytes += estimatedStorageBytes
        return .permitted(permit)
    }

    func ollamaAllowance(userMaximumSeconds: TimeInterval) -> ScheduledBriefingBudgetClaim {
        guard let permit = durationPermit() else {
            return reject(ScheduledBriefingBudgetReason.durationExhausted)
        }
        let allowance = min(userMaximumSeconds, budget.maximumOllamaDurationSeconds, permit.remainingDurationSeconds)
        guard allowance >= 5 else {
            return reject(ScheduledBriefingBudgetReason.ollamaDurationExhausted)
        }
        usageState.ollamaAllowanceMilliseconds = Self.boundedMilliseconds(allowance)
        return .permitted(.init(remainingDurationSeconds: allowance))
    }

    func markDurationExhausted() {
        _ = reject(ScheduledBriefingBudgetReason.durationExhausted)
    }

    func recordOllamaElapsed(seconds: TimeInterval) {
        usageState.ollamaElapsedMilliseconds = Self.boundedMilliseconds(seconds)
    }

    func markOllamaDurationExhausted() {
        _ = reject(ScheduledBriefingBudgetReason.ollamaDurationExhausted)
    }

    func usage() -> ScheduledBriefingBudgetUsage {
        var usage = usageState
        usage.exhaustionReasonCodes = exhaustionReasons.sorted()
        return usage
    }

    private func durationPermit() -> ScheduledBriefingBudgetPermit? {
        let remaining = remainingDurationSeconds()
        return remaining > 0 ? .init(remainingDurationSeconds: remaining) : nil
    }

    @discardableResult
    private func reject(_ reasonCode: String) -> ScheduledBriefingBudgetClaim {
        exhaustionReasons.insert(reasonCode)
        return .rejected(reasonCode: reasonCode)
    }

    private static func boundedMilliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(Int.max, Int((seconds * 1_000).rounded()))
    }
}

enum ScheduledBriefingPlanError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case invalidSlackSelection
    case invalidEntitlementDecision
    case feedSourceBudgetExceeded
    case slackWorkspaceBudgetExceeded
    case feedRequestBudgetExceeded
    case slackRequestBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The scheduled briefing plan contains an invalid identifier."
        case .invalidSlackSelection: "The scheduled briefing plan contains an invalid Slack selection."
        case .invalidEntitlementDecision: "The scheduled briefing plan contains an invalid entitlement decision."
        case .feedSourceBudgetExceeded: "The scheduled briefing plan exceeds its feed-source budget."
        case .slackWorkspaceBudgetExceeded: "The scheduled briefing plan exceeds its Slack-workspace budget."
        case .feedRequestBudgetExceeded: "The scheduled briefing plan exceeds its feed-request budget."
        case .slackRequestBudgetExceeded: "The scheduled briefing plan exceeds its Slack-request budget."
        }
    }
}

struct ScheduledBriefingSlackSelectionSnapshot: Codable, Hashable, Sendable {
    let workspaceID: String
    let channelIDs: [String]
}

struct ScheduledBriefingEntitlementDecision: Codable, Hashable, Sendable {
    let feature: LokiPaidFeature
    let state: VaultEntitlementState
    let acquisitionAllowed: Bool
    let reasonCode: String

    init(_ entitlement: FeatureEntitlement) {
        feature = entitlement.feature
        state = entitlement.state
        acquisitionAllowed = entitlement.acquisitionAllowed
        reasonCode = ScheduledBriefingPrivacy.boundedReasonCode(entitlement.reasonCode)
    }
}

struct ScheduledBriefingPlan: Codable, Hashable, Sendable {
    let id: String
    let occurrenceID: String
    let scheduledFor: Date
    let briefingDay: LocalCalendarDay
    let trigger: ScheduledBriefingTrigger
    let feedSubscriptionIDs: [String]
    let slackWorkspaceIDs: [String]
    let refreshFeedsEnabled: Bool
    let refreshSlackEnabled: Bool
    let slackSelections: [ScheduledBriefingSlackSelectionSnapshot]
    let localPresentationEnabled: Bool
    let localPresentationConsentedWorkspaceIDs: [String]
    let notificationsEnabled: Bool
    let notificationAuthorization: NotificationAuthorizationState
    let notificationPrivacyMode: NotificationPrivacyMode
    let entitlementDecisions: [ScheduledBriefingEntitlementDecision]
    let budget: ScheduledBriefingBudget
    let fingerprint: String

    init(
        id: String,
        occurrenceID: String,
        scheduledFor: Date,
        briefingDay: LocalCalendarDay? = nil,
        trigger: ScheduledBriefingTrigger,
        feedSubscriptionIDs: [String],
        slackWorkspaceIDs: [String],
        refreshFeedsEnabled: Bool,
        refreshSlackEnabled: Bool,
        slackSelections: [ScheduledBriefingSlackSelectionSnapshot],
        localPresentationEnabled: Bool,
        localPresentationConsentedWorkspaceIDs: [String],
        notificationsEnabled: Bool,
        notificationAuthorization: NotificationAuthorizationState,
        notificationPrivacyMode: NotificationPrivacyMode,
        entitlementDecisions: [ScheduledBriefingEntitlementDecision],
        budget: ScheduledBriefingBudget = .init()
    ) throws {
        guard Self.validIdentifier(id), Self.validIdentifier(occurrenceID) else {
            throw ScheduledBriefingPlanError.invalidIdentifier
        }
        let feeds = try Self.normalizedIdentifiers(feedSubscriptionIDs)
        let workspaces = try Self.normalizedIdentifiers(slackWorkspaceIDs)
        let selections = try Self.normalizedSlackSelections(slackSelections, workspaceIDs: Set(workspaces))
        let consentedWorkspaces = try Self.normalizedIdentifiers(localPresentationConsentedWorkspaceIDs)
        guard Set(consentedWorkspaces).isSubset(of: Set(workspaces)) else {
            throw ScheduledBriefingPlanError.invalidSlackSelection
        }
        let decisions = try Self.normalizedEntitlementDecisions(entitlementDecisions)
        guard feeds.count <= budget.maximumFeedSources else {
            throw ScheduledBriefingPlanError.feedSourceBudgetExceeded
        }
        guard workspaces.count <= budget.maximumSlackWorkspaces else {
            throw ScheduledBriefingPlanError.slackWorkspaceBudgetExceeded
        }
        guard feeds.count <= budget.maximumFeedRequests else {
            throw ScheduledBriefingPlanError.feedRequestBudgetExceeded
        }
        guard workspaces.count <= budget.maximumSlackRequests else {
            throw ScheduledBriefingPlanError.slackRequestBudgetExceeded
        }
        let resolvedBriefingDay = briefingDay ?? LocalCalendarDay.resolve(containing: scheduledFor)
        self.id = id
        self.occurrenceID = occurrenceID
        self.scheduledFor = scheduledFor
        self.briefingDay = resolvedBriefingDay
        self.trigger = trigger
        self.feedSubscriptionIDs = feeds
        self.slackWorkspaceIDs = workspaces
        self.refreshFeedsEnabled = refreshFeedsEnabled
        self.refreshSlackEnabled = refreshSlackEnabled
        self.slackSelections = selections
        self.localPresentationEnabled = localPresentationEnabled
        self.localPresentationConsentedWorkspaceIDs = consentedWorkspaces
        self.notificationsEnabled = notificationsEnabled
        self.notificationAuthorization = notificationAuthorization
        self.notificationPrivacyMode = notificationPrivacyMode
        self.entitlementDecisions = decisions
        self.budget = budget
        self.fingerprint = try Self.makeFingerprint(
            occurrenceID: occurrenceID,
            scheduledFor: scheduledFor,
            briefingDay: resolvedBriefingDay,
            trigger: trigger,
            feedSubscriptionIDs: feeds,
            slackWorkspaceIDs: workspaces,
            refreshFeedsEnabled: refreshFeedsEnabled,
            refreshSlackEnabled: refreshSlackEnabled,
            slackSelections: selections,
            localPresentationEnabled: localPresentationEnabled,
            localPresentationConsentedWorkspaceIDs: consentedWorkspaces,
            notificationsEnabled: notificationsEnabled,
            notificationAuthorization: notificationAuthorization,
            notificationPrivacyMode: notificationPrivacyMode,
            entitlementDecisions: decisions,
            budget: budget
        )
    }

    private static func normalizedIdentifiers(_ values: [String]) throws -> [String] {
        guard values.allSatisfy(validIdentifier) else { throw ScheduledBriefingPlanError.invalidIdentifier }
        return Array(Set(values)).sorted()
    }

    private static func normalizedSlackSelections(
        _ values: [ScheduledBriefingSlackSelectionSnapshot],
        workspaceIDs: Set<String>
    ) throws -> [ScheduledBriefingSlackSelectionSnapshot] {
        var channelsByWorkspace: [String: Set<String>] = [:]
        for value in values {
            guard validIdentifier(value.workspaceID), workspaceIDs.contains(value.workspaceID) else {
                throw ScheduledBriefingPlanError.invalidSlackSelection
            }
            let channels = try normalizedIdentifiers(value.channelIDs)
            channelsByWorkspace[value.workspaceID, default: []].formUnion(channels)
        }
        return channelsByWorkspace.keys.sorted().map {
            .init(workspaceID: $0, channelIDs: channelsByWorkspace[$0, default: []].sorted())
        }
    }

    private static func normalizedEntitlementDecisions(
        _ values: [ScheduledBriefingEntitlementDecision]
    ) throws -> [ScheduledBriefingEntitlementDecision] {
        guard Set(values.map(\.feature)).count == values.count,
              values.allSatisfy({ validIdentifier($0.reasonCode) })
        else { throw ScheduledBriefingPlanError.invalidEntitlementDecision }
        return values.sorted { $0.feature.rawValue < $1.feature.rawValue }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = value.lengthOfBytes(using: .utf8)
        return bytes > 0 && bytes <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private struct FingerprintBudget: Encodable {
        let maximumFeedSources: Int
        let maximumSlackWorkspaces: Int
        let maximumFeedConcurrency: Int
        let maximumFailureReasons: Int
        let maximumTotalDurationMilliseconds: Int64
        let maximumFeedRequests: Int
        let maximumSlackRequests: Int
        let maximumNewArchiveItems: Int
        let maximumStorageGrowthBytes: Int64
        let maximumTransientRetries: Int
        let maximumOllamaDurationMilliseconds: Int64
    }

    private struct FingerprintPayload: Encodable {
        let occurrenceID: String
        let scheduledMilliseconds: Int64
        let briefingDay: String
        let trigger: ScheduledBriefingTrigger
        let feedSubscriptionIDs: [String]
        let slackWorkspaceIDs: [String]
        let refreshFeedsEnabled: Bool
        let refreshSlackEnabled: Bool
        let slackSelections: [ScheduledBriefingSlackSelectionSnapshot]
        let localPresentationEnabled: Bool
        let localPresentationConsentedWorkspaceIDs: [String]
        let notificationsEnabled: Bool
        let notificationAuthorization: NotificationAuthorizationState
        let notificationPrivacyMode: NotificationPrivacyMode
        let entitlementDecisions: [ScheduledBriefingEntitlementDecision]
        let budget: FingerprintBudget
    }

    private static func makeFingerprint(
        occurrenceID: String,
        scheduledFor: Date,
        briefingDay: LocalCalendarDay,
        trigger: ScheduledBriefingTrigger,
        feedSubscriptionIDs: [String],
        slackWorkspaceIDs: [String],
        refreshFeedsEnabled: Bool,
        refreshSlackEnabled: Bool,
        slackSelections: [ScheduledBriefingSlackSelectionSnapshot],
        localPresentationEnabled: Bool,
        localPresentationConsentedWorkspaceIDs: [String],
        notificationsEnabled: Bool,
        notificationAuthorization: NotificationAuthorizationState,
        notificationPrivacyMode: NotificationPrivacyMode,
        entitlementDecisions: [ScheduledBriefingEntitlementDecision],
        budget: ScheduledBriefingBudget
    ) throws -> String {
        let payload = FingerprintPayload(
            occurrenceID: occurrenceID,
            scheduledMilliseconds: Int64((scheduledFor.timeIntervalSince1970 * 1_000).rounded()),
            briefingDay: briefingDay.storageValue,
            trigger: trigger,
            feedSubscriptionIDs: feedSubscriptionIDs,
            slackWorkspaceIDs: slackWorkspaceIDs,
            refreshFeedsEnabled: refreshFeedsEnabled,
            refreshSlackEnabled: refreshSlackEnabled,
            slackSelections: slackSelections,
            localPresentationEnabled: localPresentationEnabled,
            localPresentationConsentedWorkspaceIDs: localPresentationConsentedWorkspaceIDs,
            notificationsEnabled: notificationsEnabled,
            notificationAuthorization: notificationAuthorization,
            notificationPrivacyMode: notificationPrivacyMode,
            entitlementDecisions: entitlementDecisions,
            budget: .init(
                maximumFeedSources: budget.maximumFeedSources,
                maximumSlackWorkspaces: budget.maximumSlackWorkspaces,
                maximumFeedConcurrency: budget.maximumFeedConcurrency,
                maximumFailureReasons: budget.maximumFailureReasons,
                maximumTotalDurationMilliseconds: durationMilliseconds(budget.maximumTotalDurationSeconds),
                maximumFeedRequests: budget.maximumFeedRequests,
                maximumSlackRequests: budget.maximumSlackRequests,
                maximumNewArchiveItems: budget.maximumNewArchiveItems,
                maximumStorageGrowthBytes: budget.maximumStorageGrowthBytes,
                maximumTransientRetries: budget.maximumTransientRetries,
                maximumOllamaDurationMilliseconds: durationMilliseconds(budget.maximumOllamaDurationSeconds)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let material = try encoder.encode(payload)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private static func durationMilliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000).rounded())
    }
}

struct ScheduledBriefingSourceOutcome: Codable, Hashable, Sendable {
    let kind: ScheduledBriefingSourceKind
    let sourceID: String
    let status: ScheduledBriefingStageStatus
    let acceptedItemCount: Int
    let reasonCodes: [String]

    init(
        kind: ScheduledBriefingSourceKind,
        sourceID: String,
        status: ScheduledBriefingStageStatus,
        acceptedItemCount: Int = 0,
        reasonCodes: [String] = []
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.status = status
        self.acceptedItemCount = max(0, acceptedItemCount)
        self.reasonCodes = Self.boundedReasonCodes(reasonCodes)
    }

    private static func boundedReasonCodes(_ values: [String]) -> [String] {
        Array(Set(values.map { String($0.prefix(120)) }.filter { !$0.isEmpty })).sorted().prefix(16).map { $0 }
    }
}

struct ScheduledBriefingVaultOutcome: Codable, Hashable, Sendable {
    let status: ScheduledBriefingStageStatus
    let changedItemCount: Int
    let reasonCodes: [String]

    init(status: ScheduledBriefingStageStatus, changedItemCount: Int = 0, reasonCodes: [String] = []) {
        self.status = status
        self.changedItemCount = max(0, changedItemCount)
        self.reasonCodes = Array(Set(reasonCodes.map { String($0.prefix(120)) }.filter { !$0.isEmpty })).sorted().prefix(16).map { $0 }
    }
}

struct ScheduledBriefingDraft: Hashable, Sendable {
    let brief: Brief
    let excludedItemCount: Int
    let failureReasonCodes: [String]
    let localPresentationConsentedWorkspaceIDs: [String]

    init(
        brief: Brief,
        excludedItemCount: Int = 0,
        failureReasonCodes: [String] = [],
        localPresentationConsentedWorkspaceIDs: [String] = []
    ) {
        self.brief = brief
        self.excludedItemCount = max(0, excludedItemCount)
        self.failureReasonCodes = Array(Set(failureReasonCodes.map { String($0.prefix(120)) })).sorted()
        self.localPresentationConsentedWorkspaceIDs = Array(Set(localPresentationConsentedWorkspaceIDs)).sorted()
    }
}

enum ScheduledBriefingPresentationOutcome: Sendable {
    case generated(brief: Brief, provenance: OllamaGenerationProvenance)
    case fallback(reasonCode: String, provenance: OllamaGenerationProvenance?)
    case skipped(reasonCode: String)
}

struct ScheduledBriefingRunResult: Sendable {
    let plan: ScheduledBriefingPlan
    let state: ScheduledBriefingRunState
    let reasonCode: String
    let startedAt: Date
    let completedAt: Date
    let sourceOutcomes: [ScheduledBriefingSourceOutcome]
    let vaultOutcome: ScheduledBriefingVaultOutcome?
    let brief: Brief?
    let generationProvenance: OllamaGenerationProvenance?
    let fallbackReasonCode: String?
    let failureReasonCodes: [String]

    var acceptedItemCount: Int { sourceOutcomes.reduce(0) { $0 + $1.acceptedItemCount } }
}

struct ScheduledBriefingRunSnapshot: Sendable {
    let plan: ScheduledBriefingPlan
    let state: ScheduledBriefingRunState
    let reasonCode: String
    let traceID: String
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let sourceOutcomes: [ScheduledBriefingSourceOutcome]
    let vaultOutcome: ScheduledBriefingVaultOutcome?
    let briefID: String?
    let fallbackReasonCode: String?
    let failureReasonCodes: [String]
}

struct ScheduledBriefingCommit: Sendable {
    let result: ScheduledBriefingRunResult
}

protocol ScheduledBriefingSourceRefreshing: Sendable {
    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome
    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingSourceOutcome
    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome
    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome
    func refreshFeed(identifier: String, plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome
    func refreshSlackWorkspace(identifier: String, plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome
    func cancelAll() async
}

extension ScheduledBriefingSourceRefreshing {
    func refreshFeed(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshFeed(identifier: identifier, trace: trace)
    }

    func refreshSlackWorkspace(identifier: String, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshSlackWorkspace(identifier: identifier, trace: trace)
    }

    func refreshFeed(identifier: String, plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshFeed(identifier: identifier, trace: trace, budget: budget)
    }

    func refreshSlackWorkspace(identifier: String, plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingSourceOutcome {
        await refreshSlackWorkspace(identifier: identifier, trace: trace, budget: budget)
    }
}

protocol ScheduledBriefingVaultReconciling: Sendable {
    func reconcile(plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingVaultOutcome
    func reconcile(plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingVaultOutcome
    func cancel(runID: String) async
}

extension ScheduledBriefingVaultReconciling {
    func reconcile(plan: ScheduledBriefingPlan, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingVaultOutcome {
        await reconcile(plan: plan, trace: trace)
    }
}

@MainActor
protocol ScheduledBriefingAssembling: Sendable {
    func assemble(
        plan: ScheduledBriefingPlan,
        sourceOutcomes: [ScheduledBriefingSourceOutcome],
        vaultOutcome: ScheduledBriefingVaultOutcome?,
        trace: ScheduledBriefingTraceContext
    ) throws -> ScheduledBriefingDraft
}

protocol ScheduledBriefingLocalPresenting: Sendable {
    func present(draft: ScheduledBriefingDraft, trace: ScheduledBriefingTraceContext) async -> ScheduledBriefingPresentationOutcome
    func present(draft: ScheduledBriefingDraft, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingPresentationOutcome
    func cancel() async
}

extension ScheduledBriefingLocalPresenting {
    func present(draft: ScheduledBriefingDraft, trace: ScheduledBriefingTraceContext, budget: ScheduledBriefingBudgetLedger) async -> ScheduledBriefingPresentationOutcome {
        await present(draft: draft, trace: trace)
    }
}

@MainActor
protocol ScheduledBriefingRunPersisting: Sendable {
    func recordTransition(_ snapshot: ScheduledBriefingRunSnapshot) throws
    func commit(_ commit: ScheduledBriefingCommit) throws
}
