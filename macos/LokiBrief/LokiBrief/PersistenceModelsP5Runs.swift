import Foundation
import SwiftData

struct StoredScheduledBriefingSourceOutcomePayload: Codable, Hashable, Sendable {
    let sourceHash: String
    let sourceKindRaw: String
    let statusRaw: String
    let acceptedItemCount: Int
    let reasonCodes: [String]

    init(_ outcome: ScheduledBriefingSourceOutcome) {
        sourceHash = ScheduledBriefingPrivacy.hashIdentifier(outcome.sourceID)
        sourceKindRaw = outcome.kind.rawValue
        statusRaw = outcome.status.rawValue
        acceptedItemCount = outcome.acceptedItemCount
        reasonCodes = outcome.reasonCodes
    }
}

struct StoredScheduledBriefingPlanMetadataPayload: Codable, Hashable, Sendable {
    struct SlackSelection: Codable, Hashable, Sendable {
        let workspaceHash: String
        let channelHashes: [String]
    }

    struct EntitlementDecision: Codable, Hashable, Sendable {
        let featureRaw: String
        let stateRaw: String
        let acquisitionAllowed: Bool
        let reasonCode: String
    }

    let schemaVersion: Int
    let briefingDay: LocalCalendarDay?
    let feedSourceHashes: [String]
    let slackWorkspaceHashes: [String]
    let slackSelections: [SlackSelection]
    let refreshFeedsEnabled: Bool
    let refreshSlackEnabled: Bool
    let localPresentationEnabled: Bool
    let localPresentationConsentWorkspaceHashes: [String]
    let notificationsEnabled: Bool
    let notificationAuthorizationRaw: String
    let notificationPrivacyRaw: String
    let entitlementDecisions: [EntitlementDecision]

    static let legacyUnavailable = Self(
        schemaVersion: 0,
        briefingDay: nil,
        feedSourceHashes: [],
        slackWorkspaceHashes: [],
        slackSelections: [],
        refreshFeedsEnabled: false,
        refreshSlackEnabled: false,
        localPresentationEnabled: false,
        localPresentationConsentWorkspaceHashes: [],
        notificationsEnabled: false,
        notificationAuthorizationRaw: NotificationAuthorizationState.notDetermined.rawValue,
        notificationPrivacyRaw: NotificationPrivacyMode.minimal.rawValue,
        entitlementDecisions: []
    )

    init(_ plan: ScheduledBriefingPlan) {
        schemaVersion = 2
        briefingDay = plan.briefingDay
        feedSourceHashes = plan.feedSubscriptionIDs.map(ScheduledBriefingPrivacy.hashIdentifier).sorted()
        slackWorkspaceHashes = plan.slackWorkspaceIDs.map(ScheduledBriefingPrivacy.hashIdentifier).sorted()
        slackSelections = plan.slackSelections.map { selection in
            .init(
                workspaceHash: ScheduledBriefingPrivacy.hashIdentifier(selection.workspaceID),
                channelHashes: selection.channelIDs.map {
                    ScheduledBriefingPrivacy.hashIdentifier("\(selection.workspaceID):\($0)")
                }.sorted()
            )
        }.sorted { $0.workspaceHash < $1.workspaceHash }
        refreshFeedsEnabled = plan.refreshFeedsEnabled
        refreshSlackEnabled = plan.refreshSlackEnabled
        localPresentationEnabled = plan.localPresentationEnabled
        localPresentationConsentWorkspaceHashes = plan.localPresentationConsentedWorkspaceIDs
            .map(ScheduledBriefingPrivacy.hashIdentifier)
            .sorted()
        notificationsEnabled = plan.notificationsEnabled
        notificationAuthorizationRaw = plan.notificationAuthorization.rawValue
        notificationPrivacyRaw = plan.notificationPrivacyMode.rawValue
        entitlementDecisions = plan.entitlementDecisions.map {
            .init(
                featureRaw: $0.feature.rawValue,
                stateRaw: $0.state.rawValue,
                acquisitionAllowed: $0.acquisitionAllowed,
                reasonCode: ScheduledBriefingPrivacy.boundedReasonCode($0.reasonCode)
            )
        }
    }

    private init(
        schemaVersion: Int,
        briefingDay: LocalCalendarDay?,
        feedSourceHashes: [String],
        slackWorkspaceHashes: [String],
        slackSelections: [SlackSelection],
        refreshFeedsEnabled: Bool,
        refreshSlackEnabled: Bool,
        localPresentationEnabled: Bool,
        localPresentationConsentWorkspaceHashes: [String],
        notificationsEnabled: Bool,
        notificationAuthorizationRaw: String,
        notificationPrivacyRaw: String,
        entitlementDecisions: [EntitlementDecision]
    ) {
        self.schemaVersion = schemaVersion
        self.briefingDay = briefingDay
        self.feedSourceHashes = feedSourceHashes
        self.slackWorkspaceHashes = slackWorkspaceHashes
        self.slackSelections = slackSelections
        self.refreshFeedsEnabled = refreshFeedsEnabled
        self.refreshSlackEnabled = refreshSlackEnabled
        self.localPresentationEnabled = localPresentationEnabled
        self.localPresentationConsentWorkspaceHashes = localPresentationConsentWorkspaceHashes
        self.notificationsEnabled = notificationsEnabled
        self.notificationAuthorizationRaw = notificationAuthorizationRaw
        self.notificationPrivacyRaw = notificationPrivacyRaw
        self.entitlementDecisions = entitlementDecisions
    }

    func replacingBriefingDay(_ day: LocalCalendarDay) -> Self {
        Self(
            schemaVersion: max(schemaVersion, 2),
            briefingDay: day,
            feedSourceHashes: feedSourceHashes,
            slackWorkspaceHashes: slackWorkspaceHashes,
            slackSelections: slackSelections,
            refreshFeedsEnabled: refreshFeedsEnabled,
            refreshSlackEnabled: refreshSlackEnabled,
            localPresentationEnabled: localPresentationEnabled,
            localPresentationConsentWorkspaceHashes: localPresentationConsentWorkspaceHashes,
            notificationsEnabled: notificationsEnabled,
            notificationAuthorizationRaw: notificationAuthorizationRaw,
            notificationPrivacyRaw: notificationPrivacyRaw,
            entitlementDecisions: entitlementDecisions
        )
    }
}

@Model final class StoredScheduledBriefingRun {
    @Attribute(.unique) var id: String
    var occurrenceHash: String
    var planFingerprint: String
    var planMetadataData: Data = Data()
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

    init(snapshot: ScheduledBriefingRunSnapshot) {
        id = snapshot.plan.id
        occurrenceHash = ScheduledBriefingPrivacy.hashIdentifier(snapshot.plan.occurrenceID)
        planFingerprint = snapshot.plan.fingerprint
        planMetadataData = Self.encode(StoredScheduledBriefingPlanMetadataPayload(snapshot.plan))
        scheduledFor = snapshot.plan.scheduledFor
        triggerRaw = snapshot.plan.trigger.rawValue
        stateRaw = snapshot.state.scheduledRunState.rawValue
        coordinatorStateRaw = snapshot.state.rawValue
        reasonCode = ScheduledBriefingPrivacy.boundedReasonCode(snapshot.reasonCode)
        traceID = ScheduledBriefingPrivacy.boundedMetadata(snapshot.traceID)
        startedAt = snapshot.startedAt
        updatedAt = snapshot.updatedAt
        completedAt = snapshot.completedAt
        feedSourceCount = snapshot.plan.feedSubscriptionIDs.count
        slackWorkspaceCount = snapshot.plan.slackWorkspaceIDs.count
        successfulSourceCount = snapshot.sourceOutcomes.filter { $0.status == .success }.count
        failedSourceCount = snapshot.sourceOutcomes.filter { $0.status.contributesFailure }.count
        acceptedItemCount = snapshot.sourceOutcomes.reduce(0) { $0 + $1.acceptedItemCount }
        vaultStatusRaw = snapshot.vaultOutcome?.status.rawValue
        vaultChangedItemCount = snapshot.vaultOutcome?.changedItemCount ?? 0
        briefID = snapshot.briefID.map { String($0.prefix(512)) }
        briefIDHash = snapshot.briefID.map(ScheduledBriefingPrivacy.hashIdentifier)
        fallbackReasonCode = snapshot.fallbackReasonCode.map(ScheduledBriefingPrivacy.boundedReasonCode)
        sourceOutcomesData = Self.encodeSourceOutcomes(snapshot.sourceOutcomes)
        failureReasonCodesData = Self.encodeReasonCodes(snapshot.failureReasonCodes)
        schemaVersion = 2
        maximumTotalDurationSeconds = snapshot.plan.budget.maximumTotalDurationSeconds
        maximumFeedRequests = snapshot.plan.budget.maximumFeedRequests
        maximumSlackRequests = snapshot.plan.budget.maximumSlackRequests
        maximumNewArchiveItems = snapshot.plan.budget.maximumNewArchiveItems
        maximumStorageGrowthBytes = snapshot.plan.budget.maximumStorageGrowthBytes
        maximumTransientRetries = snapshot.plan.budget.maximumTransientRetries
        maximumOllamaDurationSeconds = snapshot.plan.budget.maximumOllamaDurationSeconds
        nextScheduledOccurrence = nil
    }

    func update(with snapshot: ScheduledBriefingRunSnapshot) {
        precondition(id == snapshot.plan.id)
        occurrenceHash = ScheduledBriefingPrivacy.hashIdentifier(snapshot.plan.occurrenceID)
        planFingerprint = snapshot.plan.fingerprint
        planMetadataData = Self.encode(StoredScheduledBriefingPlanMetadataPayload(snapshot.plan))
        scheduledFor = snapshot.plan.scheduledFor
        triggerRaw = snapshot.plan.trigger.rawValue
        stateRaw = snapshot.state.scheduledRunState.rawValue
        coordinatorStateRaw = snapshot.state.rawValue
        reasonCode = ScheduledBriefingPrivacy.boundedReasonCode(snapshot.reasonCode)
        traceID = ScheduledBriefingPrivacy.boundedMetadata(snapshot.traceID)
        startedAt = snapshot.startedAt
        updatedAt = snapshot.updatedAt
        completedAt = snapshot.completedAt
        feedSourceCount = snapshot.plan.feedSubscriptionIDs.count
        slackWorkspaceCount = snapshot.plan.slackWorkspaceIDs.count
        successfulSourceCount = snapshot.sourceOutcomes.filter { $0.status == .success }.count
        failedSourceCount = snapshot.sourceOutcomes.filter { $0.status.contributesFailure }.count
        acceptedItemCount = snapshot.sourceOutcomes.reduce(0) { $0 + $1.acceptedItemCount }
        vaultStatusRaw = snapshot.vaultOutcome?.status.rawValue
        vaultChangedItemCount = snapshot.vaultOutcome?.changedItemCount ?? 0
        briefID = snapshot.briefID.map { String($0.prefix(512)) }
        briefIDHash = snapshot.briefID.map(ScheduledBriefingPrivacy.hashIdentifier)
        fallbackReasonCode = snapshot.fallbackReasonCode.map(ScheduledBriefingPrivacy.boundedReasonCode)
        sourceOutcomesData = Self.encodeSourceOutcomes(snapshot.sourceOutcomes)
        failureReasonCodesData = Self.encodeReasonCodes(snapshot.failureReasonCodes)
        maximumTotalDurationSeconds = snapshot.plan.budget.maximumTotalDurationSeconds
        maximumFeedRequests = snapshot.plan.budget.maximumFeedRequests
        maximumSlackRequests = snapshot.plan.budget.maximumSlackRequests
        maximumNewArchiveItems = snapshot.plan.budget.maximumNewArchiveItems
        maximumStorageGrowthBytes = snapshot.plan.budget.maximumStorageGrowthBytes
        maximumTransientRetries = snapshot.plan.budget.maximumTransientRetries
        maximumOllamaDurationSeconds = snapshot.plan.budget.maximumOllamaDurationSeconds
        schemaVersion = 2
    }

    func update(with result: ScheduledBriefingRunResult) {
        precondition(id == result.plan.id)
        planFingerprint = result.plan.fingerprint
        planMetadataData = Self.encode(StoredScheduledBriefingPlanMetadataPayload(result.plan))
        schemaVersion = 2
        stateRaw = result.state.scheduledRunState.rawValue
        coordinatorStateRaw = result.state.rawValue
        reasonCode = ScheduledBriefingPrivacy.boundedReasonCode(result.reasonCode)
        updatedAt = result.completedAt
        completedAt = result.completedAt
        successfulSourceCount = result.sourceOutcomes.filter { $0.status == .success }.count
        failedSourceCount = result.sourceOutcomes.filter { $0.status.contributesFailure }.count
        acceptedItemCount = result.acceptedItemCount
        vaultStatusRaw = result.vaultOutcome?.status.rawValue
        vaultChangedItemCount = result.vaultOutcome?.changedItemCount ?? 0
        briefID = result.brief.map { String($0.id.prefix(512)) }
        briefIDHash = result.brief.map { ScheduledBriefingPrivacy.hashIdentifier($0.id) }
        fallbackReasonCode = result.fallbackReasonCode.map(ScheduledBriefingPrivacy.boundedReasonCode)
        sourceOutcomesData = Self.encodeSourceOutcomes(result.sourceOutcomes)
        failureReasonCodesData = Self.encodeReasonCodes(result.failureReasonCodes)
    }

    func sourceOutcomes() throws -> [StoredScheduledBriefingSourceOutcomePayload] {
        try JSONDecoder().decode([StoredScheduledBriefingSourceOutcomePayload].self, from: sourceOutcomesData)
    }

    func planMetadata() throws -> StoredScheduledBriefingPlanMetadataPayload {
        guard !planMetadataData.isEmpty else { return .legacyUnavailable }
        return try JSONDecoder().decode(StoredScheduledBriefingPlanMetadataPayload.self, from: planMetadataData)
    }

    @discardableResult
    func backfillBriefingDayMetadata(_ day: LocalCalendarDay) -> Bool {
        guard let payload = try? planMetadata(), payload.briefingDay == nil else { return false }
        planMetadataData = Self.encode(payload.replacingBriefingDay(day))
        schemaVersion = max(schemaVersion, 2)
        return true
    }

    func failureReasonCodes() throws -> [String] {
        try JSONDecoder().decode([String].self, from: failureReasonCodesData)
    }

    private static func encodeSourceOutcomes(_ outcomes: [ScheduledBriefingSourceOutcome]) -> Data {
        encode(outcomes.map(StoredScheduledBriefingSourceOutcomePayload.init))
    }

    private static func encodeReasonCodes(_ reasonCodes: [String]) -> Data {
        encode(Array(Set(reasonCodes.map(ScheduledBriefingPrivacy.boundedReasonCode))).sorted())
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("[]".utf8)
    }
}

@Model final class StoredScheduledBriefingSourceResult {
    @Attribute(.unique) var id: String
    var runID: String
    var sourceIDHash: String
    var sourceKindRaw: String
    var statusRaw: String
    var acceptedItemCount: Int
    var reasonCode: String?
    var startedAt: Date
    var completedAt: Date
    var durationMilliseconds: Int
    var schemaVersion: Int

    init(
        runID: String,
        outcome: ScheduledBriefingSourceOutcome,
        startedAt: Date,
        completedAt: Date
    ) {
        let sourceHash = ScheduledBriefingPrivacy.hashIdentifier(outcome.sourceID)
        id = "\(runID):\(outcome.kind.rawValue):\(sourceHash)"
        self.runID = String(runID.prefix(512))
        sourceIDHash = sourceHash
        sourceKindRaw = outcome.kind.rawValue
        statusRaw = outcome.status.rawValue
        acceptedItemCount = max(0, outcome.acceptedItemCount)
        reasonCode = outcome.reasonCodes.first.map(ScheduledBriefingPrivacy.boundedReasonCode)
        let boundedCompletedAt = max(completedAt, startedAt)
        self.startedAt = startedAt
        self.completedAt = boundedCompletedAt
        durationMilliseconds = max(0, Int((boundedCompletedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
        schemaVersion = 1
    }
}
