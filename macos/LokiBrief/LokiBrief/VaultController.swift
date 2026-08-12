import AppKit
import CryptoKit
import Foundation

enum VaultPaths {
    static func databaseURL(isolated: Bool) throws -> URL {
        if isolated {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-loki-vault-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
        }
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("LokiBrief", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("loki-vault.sqlite3")
    }

    static func exportDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
    }

    static func exportStagingDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("ExportStaging", isDirectory: true)
    }
}

struct VaultBackfillRunSnapshot: Identifiable, Hashable, Sendable {
    let job: VaultBackfillJob
    let checkpoint: VaultBackfillCheckpoint

    var id: String { job.id }
    var archivedItemCount: Int { checkpoint.usage.items }
    var requestCount: Int { checkpoint.usage.requests }
    var currentSource: VaultBackfillSourceCheckpoint? {
        guard checkpoint.sourceIndex < checkpoint.sources.count else { return checkpoint.sources.last }
        return checkpoint.sources[checkpoint.sourceIndex]
    }
}

enum VaultControllerFailure: Error, LocalizedError {
    case archiveUnavailable
    case slackBackfillUnavailable
    case noSelectedSlackChannels
    case entitlementUnavailable(String)
    case jobUnavailable

    var errorDescription: String? {
        switch self {
        case .archiveUnavailable: "Loki Vault is unavailable for this launch. Existing archive files were preserved."
        case .slackBackfillUnavailable: "Slack historical backfill is unavailable until a configured, connected workspace is enabled."
        case .noSelectedSlackChannels: "Select at least one authorized Slack channel before starting backfill."
        case let .entitlementUnavailable(reason): "Historical acquisition is paused. \(LokiBriefPresentation.reason(for: reason)) Existing archive access, export, and deletion remain available."
        case .jobUnavailable: "That backfill job is no longer available."
        }
    }
}

@MainActor
final class VaultController: ObservableObject {
    static let localOwnerID = "local-macos-user"

    @Published private(set) var archiveAvailable = true
    @Published private(set) var storage: VaultStorageSummary?
    @Published private(set) var integrity: VaultIntegrityReport?
    @Published private(set) var accounts: [VaultAccount] = []
    @Published private(set) var containers: [VaultContainer] = []
    @Published private(set) var backfillRuns: [VaultBackfillRunSnapshot] = []
    @Published private(set) var searchResults: [VaultSearchResult] = []
    @Published private(set) var searchMode: VaultSearchMode?
    @Published private(set) var searchOffset = 0
    @Published private(set) var searchHasNext = false
    @Published private(set) var historicalBackfillEntitlement = FeatureEntitlement(
        feature: .historicalBackfill,
        state: .available,
        acquisitionAllowed: true,
        reasonCode: "loki_brief_early_access_included"
    )
    @Published private(set) var isReconciling = false
    @Published private(set) var statusMessage = "Loki Vault is local and ready for inspection."
    @Published private(set) var lastExportURL: URL?
    @Published var errorMessage: String?

    let databaseURL: URL
    let databaseIsInMemory: Bool
    let database: VaultDatabase

    private let store: LocalStore
    private let slackController: SlackAppController
    private let entitlementProvider: any FeatureEntitlementProvider
    private let scheduledRecordCommitBoundary: (@MainActor @Sendable () async -> Void)?
    private var engines: [String: VaultBackfillEngine] = [:]
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var lifecycleGeneration: UInt64 = 0
    private var foregroundDatabaseOperationCount = 0
    private var updatePreparationInProgress = false
    private var closedForUpdate = false
    private(set) var deletionInProgress = false
    private let deletionCheckpoint: (@MainActor @Sendable () async -> Void)?
    private let updatePreparationCheckpoint: (@MainActor @Sendable () async -> Void)?
    private weak var signedSmokeDependencyPackage:
        P8FSignedSmokeDependencyPackage?
    var onEvidenceDeletionWillBegin: (@MainActor @Sendable () async -> Void)?
    var onEvidenceDeletionCompleted: (@MainActor @Sendable (String?) async -> Void)?

    var hasUpdateBlockingWork: Bool {
        deletionInProgress
            || updatePreparationInProgress
            || closedForUpdate
            || isReconciling
            || !runTasks.isEmpty
            || foregroundDatabaseOperationCount > 0
    }

    func beginForegroundDatabaseOperation() -> Bool {
        guard archiveAvailable,
              !deletionInProgress,
              !updatePreparationInProgress,
              !closedForUpdate
        else { return false }
        foregroundDatabaseOperationCount += 1
        return true
    }

    func endForegroundDatabaseOperation() {
        foregroundDatabaseOperationCount = max(0, foregroundDatabaseOperationCount - 1)
    }

    init(
        store: LocalStore,
        slackController: SlackAppController,
        databaseURL: URL? = nil,
        inMemory: Bool = false,
        entitlementProvider: any FeatureEntitlementProvider = LokiBriefEarlyAccessEntitlementProvider(),
        scheduledRecordCommitBoundary: (@MainActor @Sendable () async -> Void)? = nil,
        deletionCheckpoint: (@MainActor @Sendable () async -> Void)? = nil,
        updatePreparationCheckpoint: (@MainActor @Sendable () async -> Void)? = nil
    ) throws {
        self.store = store
        self.slackController = slackController
        self.entitlementProvider = entitlementProvider
        self.scheduledRecordCommitBoundary = scheduledRecordCommitBoundary
        self.deletionCheckpoint = deletionCheckpoint
        self.updatePreparationCheckpoint = updatePreparationCheckpoint
        precondition(
            !inMemory || databaseURL == nil,
            "An in-memory Loki Vault cannot also use a file URL."
        )
        // An explicitly located SwiftData store is a test/recovery fixture, not
        // the production application store. Keep its implicit Vault companion
        // isolated so file-backed tests can never inspect or delete user data.
        let resolvedURL = try databaseURL?.resolvingSymlinksInPath().standardizedFileURL
            ?? VaultPaths.databaseURL(
                isolated: store.isInMemory || store.usesExplicitStorageURL
            ).resolvingSymlinksInPath().standardizedFileURL
        self.databaseURL = inMemory
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-loki-vault-memory", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
            : resolvedURL
        self.databaseIsInMemory = inMemory
        self.database = try inMemory
            ? VaultDatabase(inMemory: true)
            : VaultDatabase(url: resolvedURL)
    }

    func installSignedSmokeDependencyPackage(
        _ dependencyPackage: P8FSignedSmokeDependencyPackage,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) throws {
        guard signedSmokeDependencyPackage == nil else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try dependencyPackage.validateApplicationDependencies(
            store: store,
            slackController: slackController,
            vaultController: self,
            storageBoundary: storageBoundary,
            runtimeAuthority: runtimeAuthority
        )
        signedSmokeDependencyPackage = dependencyPackage
    }

    private func revalidateSignedSmokeDependencyAuthority() throws {
        guard let signedSmokeDependencyPackage else { return }
        guard let applicationSlackController =
                signedSmokeDependencyPackage.applicationSlackController,
              let applicationVaultController =
                signedSmokeDependencyPackage.applicationVaultController,
              applicationSlackController === slackController,
              applicationVaultController === self
        else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try signedSmokeDependencyPackage.revalidateBoundary()
    }

    func signedSmokeCloseDatabaseForCleanup() async throws {
        guard signedSmokeDependencyPackage != nil else {
            throw SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid
        }
        try revalidateSignedSmokeDependencyAuthority()
        try await database.close()
    }

    func bootstrap() async {
        guard (try? revalidateSignedSmokeDependencyAuthority()) != nil
        else {
            archiveAvailable = false
            errorMessage =
                "Signed-smoke Vault authority changed; bootstrap was rejected."
            return
        }
        await reconcileExistingEvidence()
        await refresh()
    }

    func prepareForUpdateInstall() async -> String? {
        guard !closedForUpdate else { return nil }
        guard !updatePreparationInProgress else { return "vault_work_active" }
        guard !hasUpdateBlockingWork else { return "vault_work_active" }
        updatePreparationInProgress = true
        lifecycleGeneration &+= 1
        await updatePreparationCheckpoint?()
        do {
            try await database.close(trace: .init())
            closedForUpdate = true
            updatePreparationInProgress = false
            archiveAvailable = false
            statusMessage = "Loki Vault is closed safely for update installation."
            errorMessage = nil
            return nil
        } catch {
            updatePreparationInProgress = false
            errorMessage = "Update installation is blocked because Loki Vault could not close safely."
            return "vault_database_close_failed"
        }
    }

    func resumeAfterUpdateInstallAbort() async -> Bool {
        guard closedForUpdate else { return true }
        do {
            try await database.reopen(trace: .init())
            closedForUpdate = false
            archiveAvailable = true
            await refresh()
            statusMessage = "Update installation stopped; Loki Vault reopened safely."
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Update installation stopped, but Loki Vault could not reopen. Restart Loki Brief before using the archive."
            return false
        }
    }

    func refresh() async {
        guard (try? revalidateSignedSmokeDependencyAuthority()) != nil
        else {
            archiveAvailable = false
            errorMessage =
                "Signed-smoke Vault authority changed; refresh was rejected."
            return
        }
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        historicalBackfillEntitlement = await entitlementProvider.entitlement(for: .historicalBackfill)
        do {
            let summary = try await database.storageSummary()
            let report = try await database.integrityCheck()
            let archiveAccounts = try await database.accounts()
            let archiveContainers = try await database.containers()
            let runs = try await database.backfillRuns()
            storage = summary
            integrity = report
            accounts = archiveAccounts
            containers = archiveContainers
            backfillRuns = runs.map { .init(job: $0.job, checkpoint: $0.checkpoint) }
            errorMessage = nil
            statusMessage = report.recoveryClassification == .healthy
                ? "Archive integrity is healthy."
                : "Archive inspection requires attention: \(report.recoveryClassification.rawValue)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reconcileExistingEvidence() async {
        guard (try? revalidateSignedSmokeDependencyAuthority()) != nil
        else {
            archiveAvailable = false
            errorMessage =
                "Signed-smoke Vault authority changed; reconciliation was rejected."
            return
        }
        guard archiveAvailable, !updatePreparationInProgress, !closedForUpdate, !isReconciling else { return }
        isReconciling = true
        let generation = lifecycleGeneration
        defer { isReconciling = false }
        do {
            let readStates = try store.readStates()
            let subscriptions = try store.domainFeedSubscriptions()
            let subscriptionIDs = Set(subscriptions.map(\.id))
            let feedEntries = try store.domainFeedEntries(enabledSubscriptionIDs: subscriptionIDs)
            let slackEvidence = try store.domainSlackEvidence()
            let batches = try reconciliationBatches(
                subscriptions: subscriptions,
                feedEntries: feedEntries,
                slackEvidence: slackEvidence,
                readStates: readStates
            )
            var inserted = 0
            for batch in batches {
                guard generation == lifecycleGeneration, !Task.isCancelled else { return }
                inserted += try await reconcile(batch, generation: generation)
            }
            statusMessage = inserted == 0
                ? "Existing feed and Slack evidence is reconciled with Loki Vault."
                : "Reconciled \(inserted) new or changed evidence item\(inserted == 1 ? "" : "s") into Loki Vault."
            errorMessage = nil
        } catch {
            errorMessage = "Vault reconciliation paused safely: \(error.localizedDescription)"
        }
    }

    func reconcileScheduledEvidence(
        plan: ScheduledBriefingPlan,
        budget: ScheduledBriefingBudgetLedger
    ) async -> ScheduledBriefingVaultOutcome {
        guard archiveAvailable, !updatePreparationInProgress, !closedForUpdate else {
            return .init(status: .failed, reasonCodes: ["scheduled_vault_unavailable"])
        }
        guard !isReconciling else {
            return .init(status: .degraded, reasonCodes: ["scheduled_vault_reconciliation_busy"])
        }

        isReconciling = true
        let generation = lifecycleGeneration
        defer { isReconciling = false }

        do {
            let feedSubscriptionIDs = Set(plan.feedSubscriptionIDs)
            let slackWorkspaceIDs = Set(plan.slackWorkspaceIDs)
            let readStates = try store.readStates()
            let subscriptions = try store.domainFeedSubscriptions().filter { feedSubscriptionIDs.contains($0.id) }
            let feedEntries = try store.domainFeedEntries(enabledSubscriptionIDs: feedSubscriptionIDs)
            let slackEvidence = try store.domainSlackEvidence().filter { slackWorkspaceIDs.contains($0.workspaceID) }
            let batches = try reconciliationBatches(
                subscriptions: subscriptions,
                feedEntries: feedEntries,
                slackEvidence: slackEvidence,
                readStates: readStates
            )

            var changedItemCount = 0
            for batch in batches {
                guard generation == lifecycleGeneration, !Task.isCancelled else {
                    return .init(
                        status: .cancelled,
                        changedItemCount: changedItemCount,
                        reasonCodes: ["scheduled_vault_reconciliation_cancelled"]
                    )
                }
                let result = try await reconcileScheduled(batch, generation: generation, budget: budget)
                changedItemCount += result.changedItemCount
                if result.wasCancelled {
                    return .init(
                        status: .cancelled,
                        changedItemCount: changedItemCount,
                        reasonCodes: ["scheduled_vault_reconciliation_cancelled"]
                    )
                }
                if let reasonCode = result.budgetReasonCode {
                    statusMessage = "Scheduled Vault reconciliation reached its bounded run budget; committed evidence remains preserved."
                    errorMessage = nil
                    return .init(
                        status: .degraded,
                        changedItemCount: changedItemCount,
                        reasonCodes: [reasonCode]
                    )
                }
            }

            statusMessage = changedItemCount == 0
                ? "Scheduled evidence is already reconciled with Loki Vault."
                : "Scheduled reconciliation committed \(changedItemCount) new or changed evidence item\(changedItemCount == 1 ? "" : "s") to Loki Vault."
            errorMessage = nil
            return .init(
                status: .success,
                changedItemCount: changedItemCount,
                reasonCodes: [changedItemCount == 0
                    ? "scheduled_vault_reconciliation_no_new_evidence"
                    : "scheduled_vault_reconciliation_complete"]
            )
        } catch is CancellationError {
            return .init(status: .cancelled, reasonCodes: ["scheduled_vault_reconciliation_cancelled"])
        } catch {
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                return .init(status: .cancelled, reasonCodes: ["scheduled_vault_reconciliation_cancelled"])
            }
            errorMessage = "Scheduled Vault reconciliation paused safely: \(error.localizedDescription)"
            return .init(status: .degraded, reasonCodes: ["scheduled_vault_reconciliation_failed"])
        }
    }

    func cancelScheduledReconciliation() {
        lifecycleGeneration &+= 1
        statusMessage = "Scheduled Vault reconciliation cancellation requested; committed evidence remains preserved."
    }

    func search(
        text: String,
        provider: String? = nil,
        accountID: String? = nil,
        containerID: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        directMentionsOnly: Bool = false,
        offset: Int = 0
    ) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchMode = nil
            searchOffset = 0
            searchHasNext = false
            return
        }
        do {
            try Task.checkCancellation()
            let response = try await database.search(.init(
                text: query,
                accountID: accountID,
                containerID: containerID,
                provider: provider,
                startDate: startDate,
                endDate: endDate,
                directlyMentionsUser: directMentionsOnly ? true : nil,
                limit: 50,
                offset: max(0, offset)
            ))
            try Task.checkCancellation()
            searchResults = response.results
            searchMode = response.mode
            searchOffset = max(0, offset)
            searchHasNext = response.wasTruncated
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns one bounded search response without publishing it through the
    /// shared Vault browser state. Callers with a stricter authority scope can
    /// validate this response against the exact account and containers they
    /// pinned before the actor hop.
    func boundedSearchResponse(
        _ request: VaultSearchRequest
    ) async throws -> VaultSearchResponse {
        guard beginForegroundDatabaseOperation()
        else { throw VaultControllerFailure.archiveUnavailable }
        defer { endForegroundDatabaseOperation() }
        try Task.checkCancellation()
        let response = try await database.search(request)
        try Task.checkCancellation()
        return response
    }

    /// Reads the generation marker under the same foreground database barrier
    /// used by bounded attached-source searches.
    func boundedConnectorGenerationMarker(
        accountID: String
    ) async throws -> VaultConnectorGenerationMarker? {
        guard beginForegroundDatabaseOperation()
        else { throw VaultControllerFailure.archiveUnavailable }
        defer { endForegroundDatabaseOperation() }
        try Task.checkCancellation()
        let marker = try await database.connectorGenerationMarker(
            accountID: accountID
        )
        try Task.checkCancellation()
        return marker
    }

    func startSlackBackfill(workspaceID: String) async {
        guard beginForegroundDatabaseOperation() else { errorMessage = VaultControllerFailure.archiveUnavailable.localizedDescription; return }
        defer { endForegroundDatabaseOperation() }
        let entitlement = await entitlementProvider.entitlement(for: .historicalBackfill)
        historicalBackfillEntitlement = entitlement
        guard entitlement.acquisitionAllowed else {
            errorMessage = VaultControllerFailure.entitlementUnavailable(entitlement.reasonCode).localizedDescription
            return
        }
        do {
            guard let adapter = try slackController.makeVaultBackfillAdapter(
                workspaceID: workspaceID,
                traceSink: { event in VaultBackfillProductionTraceLogger.emit(event) }
            ) else { throw VaultControllerFailure.slackBackfillUnavailable }
            let sources = try slackController.vaultBackfillSources(workspaceID: workspaceID)
            guard !sources.isEmpty else { throw VaultControllerFailure.noSelectedSlackChannels }
            let engine = VaultBackfillEngine(
                provider: adapter,
                persistence: database,
                traceSink: { event in VaultBackfillProductionTraceLogger.emit(event) }
            )
            let job = try await engine.create(
                sources: sources,
                budget: .init(
                    maximumRequests: 20,
                    maximumItems: 300,
                    maximumDuration: 300,
                    maximumStorageBytes: 50 * 1_024 * 1_024,
                    maximumRetries: 2
                )
            )
            engines[job.id] = engine
            launch(jobID: job.id, engine: engine, resumeBudget: nil)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pauseBackfill(jobID: String) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        do {
            guard let engine = try await engine(for: jobID) else { throw VaultControllerFailure.jobUnavailable }
            _ = try await engine.pause(jobID: jobID)
            runTasks[jobID]?.cancel()
            runTasks[jobID] = nil
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func resumeBackfill(jobID: String) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        let entitlement = await entitlementProvider.entitlement(for: .historicalBackfill)
        historicalBackfillEntitlement = entitlement
        guard entitlement.acquisitionAllowed else {
            errorMessage = VaultControllerFailure.entitlementUnavailable(entitlement.reasonCode).localizedDescription
            return
        }
        do {
            guard let engine = try await engine(for: jobID) else { throw VaultControllerFailure.jobUnavailable }
            launch(
                jobID: jobID,
                engine: engine,
                resumeBudget: .init(
                    maximumRequests: 20,
                    maximumItems: 300,
                    maximumDuration: 300,
                    maximumStorageBytes: 50 * 1_024 * 1_024,
                    maximumRetries: 2
                )
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelBackfill(jobID: String) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        do {
            guard let engine = try await engine(for: jobID) else { throw VaultControllerFailure.jobUnavailable }
            _ = try await engine.cancel(jobID: jobID)
            runTasks[jobID]?.cancel()
            runTasks[jobID] = nil
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func skipBackfillContainer(jobID: String) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        do {
            guard let engine = try await engine(for: jobID) else { throw VaultControllerFailure.jobUnavailable }
            _ = try await engine.skipContainer(jobID: jobID)
            runTasks[jobID]?.cancel()
            runTasks[jobID] = nil
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func enforceRetention(accountID: String, preset: VaultRetentionPreset) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        guard preset != .unlimited else {
            statusMessage = "Unlimited retention selected; no records were deleted. Local capacity and archive safety limits still apply."
            return
        }
        let days: Int
        switch preset {
        case .recentOnly: days = 7
        case .thirtyDays: days = 30
        case .ninetyDays: days = 90
        case .oneYear: days = 365
        case .custom: days = 30
        case .unlimited: return
        }
        await onEvidenceDeletionWillBegin?()
        do {
            let result = try await database.applyRetention(.init(
                accountID: accountID,
                recordAgeDays: days,
                maximumRecordsPerContainer: VaultLimits.maximumRecordsPerContainer,
                tombstoneAgeDays: max(days, 30)
            ), now: Date())
            _ = try store.scrubLokiChatEvidence(
                sourceKind: .vault,
                accountIdentifier: accountID
            )
            statusMessage = "Retention removed \(result.recordsRemovedByAge + result.recordsRemovedByLimit) archived item(s)."
            await refresh()
        } catch { errorMessage = error.localizedDescription }
        await onEvidenceDeletionCompleted?(accountID)
    }

    func compact() async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        do {
            try await database.compact()
            statusMessage = "Vault checkpoint and compaction completed."
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func export(accountID: String? = nil, startDate: Date? = nil, endDate: Date? = nil) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        do {
            let exportedAt = Date()
            let calendar = Calendar.autoupdatingCurrent
            let timeZone = TimeZone.autoupdatingCurrent
            let localTimestamp = LocalCalendarTimestamp.resolve(
                exportedAt,
                calendar: calendar,
                timeZone: timeZone
            )
            let directory = VaultPaths.exportDirectory(for: databaseURL)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent(
                LocalCalendarExportFilename.make(timestamp: localTimestamp)
            )
            let result = try await database.export(
                to: url,
                scope: .init(accountID: accountID, startDate: startDate, endDate: endDate),
                exportedAt: exportedAt,
                localCalendar: calendar,
                localTimeZone: timeZone
            )
            let verification = try VaultDatabase.verifyExport(at: result.url)
            guard verification.isValid else { throw VaultControllerFailure.archiveUnavailable }
            lastExportURL = result.url
            statusMessage = "Exported \(result.recordCount) item(s) to a local, unencrypted .lokivault file."
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    func deleteAccountArchive(accountID: String) async {
        guard beginForegroundDatabaseOperation() else { return }
        defer { endForegroundDatabaseOperation() }
        lifecycleGeneration &+= 1
        await onEvidenceDeletionWillBegin?()
        for snapshot in backfillRuns where snapshot.checkpoint.sources.contains(where: {
            VaultIdentity.accountID(provider: snapshot.job.provider, providerAccountID: $0.accountID) == accountID
        }) {
            runTasks[snapshot.id]?.cancel()
            if let engine = try? await engine(for: snapshot.id) { _ = try? await engine.cancel(jobID: snapshot.id) }
            runTasks[snapshot.id] = nil
        }
        do {
            let summary = try await database.deleteAccount(id: accountID)
            _ = try store.scrubLokiChatEvidence(
                sourceKind: .vault,
                accountIdentifier: accountID
            )
            statusMessage = "Deleted \(summary.recordsDeleted) local archive item(s). Provider credentials and connection state were preserved."
            await refresh()
        } catch { errorMessage = error.localizedDescription }
        await onEvidenceDeletionCompleted?(accountID)
    }

    func connectionSummary(for account: VaultAccount) -> String {
        guard account.provider == VaultProviderKind.slack.rawValue else {
            return "Local source archive"
        }
        guard slackController.workspaces.contains(where: { $0.id == account.providerAccountID }) else {
            return "Disconnected; archived data remains local"
        }
        return slackController.isWorkspaceEnabled(account.providerAccountID)
            ? "Connected and enabled"
            : "Connected but disabled"
    }

    func permissionSummary(for account: VaultAccount) -> String {
        guard account.provider == VaultProviderKind.slack.rawValue,
              let workspace = slackController.workspaces.first(where: { $0.id == account.providerAccountID })
        else { return "No provider permission metadata" }
        return "\(workspace.grantedScopes.count) granted scopes · \(slackController.selectedChannelCount(workspaceID: account.providerAccountID)) selected containers"
    }

    func backfillSummary(for account: VaultAccount) -> String {
        let matches = backfillRuns.filter { run in
            run.checkpoint.sources.contains {
                VaultIdentity.accountID(provider: run.job.provider, providerAccountID: $0.accountID) == account.id
            }
        }
        guard let latest = matches.max(by: { $0.job.updatedAt < $1.job.updatedAt }) else {
            return "No historical backfill job"
        }
        return "\(latest.job.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) · \(latest.archivedItemCount) archived"
    }

    func disconnectAccount(accountID: String, deleteArchive: Bool) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        if deleteArchive { await deleteAccountArchive(accountID: accountID) }
        guard account.provider == VaultProviderKind.slack.rawValue else {
            statusMessage = "The local archive action completed. This source does not provide an account-disconnect action."
            return
        }
        let result = await slackController.disconnect(workspaceID: account.providerAccountID)
        if result.connectorDisabled && result.credentialDeleted {
            statusMessage = deleteArchive
                ? "Slack was disconnected and its local archive was deleted."
                : "Slack was disconnected. Existing local data remains readable and separately deletable."
        } else {
            errorMessage = "Slack disconnect cleanup was incomplete. Retry from Sources; retained local data was preserved."
        }
    }

    func deleteAllVaultData() async -> Bool {
        guard !updatePreparationInProgress, !closedForUpdate else {
            errorMessage = "Vault deletion is unavailable while update installation is prepared. Cancel or finish the update first."
            return false
        }
        guard !deletionInProgress else {
            errorMessage = "Vault deletion is already in progress."
            return false
        }
        guard foregroundDatabaseOperationCount == 0 else {
            errorMessage = "Finish the active Vault operation before deleting all Vault data."
            return false
        }
        do {
            try revalidateSignedSmokeDependencyAuthority()
        } catch {
            errorMessage =
                "Vault deletion was rejected because signed-smoke dependency authority changed."
            return false
        }
        deletionInProgress = true
        defer { deletionInProgress = false }
        await onEvidenceDeletionWillBegin?()
        if let deletionCheckpoint { await deletionCheckpoint() }
        lifecycleGeneration &+= 1
        for task in runTasks.values { task.cancel() }
        for (jobID, engine) in engines { _ = try? await engine.cancel(jobID: jobID) }
        runTasks.removeAll()
        engines.removeAll()

        var failures: [String] = []
        if let signedSmokeDependencyPackage {
            do {
                try signedSmokeDependencyPackage
                    .removeVaultExportStagingIfPresent(for: self)
                try await signedSmokeDependencyPackage
                    .removeVaultFamily(for: self)
            } catch {
                failures.append("signed_smoke_vault_authority")
            }
        } else {
            do { try await database.close() }
            catch { failures.append("database_close") }

            let fileManager = FileManager.default
            let targets = [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
                URL(fileURLWithPath: databaseURL.path + "-shm"),
                VaultPaths.exportStagingDirectory(for: databaseURL),
            ]
            for target in targets where fileManager.fileExists(atPath: target.path) {
                do { try fileManager.removeItem(at: target) }
                catch { failures.append(target.lastPathComponent) }
            }
        }
        archiveAvailable = false
        storage = nil
        integrity = nil
        accounts = []
        containers = []
        backfillRuns = []
        searchResults = []
        searchHasNext = false
        _ = try? store.scrubLokiChatEvidence(
            sourceKind: .vault,
            accountIdentifier: nil
        )
        await onEvidenceDeletionCompleted?(nil)
        if failures.isEmpty {
            statusMessage = "All Loki Vault data and export staging files were deleted. The archive will be recreated only on a future app launch."
            errorMessage = nil
            return true
        }
        errorMessage = "Vault cleanup was partial. Preserved paths requiring retry: \(failures.joined(separator: ", "))."
        return false
    }

    private func launch(jobID: String, engine: VaultBackfillEngine, resumeBudget: VaultBackfillBudget?) {
        runTasks[jobID]?.cancel()
        let generation = lifecycleGeneration
        runTasks[jobID] = Task { [weak self] in
            guard let self else { return }
            do {
                if let resumeBudget {
                    _ = try await engine.resume(jobID: jobID, budget: resumeBudget)
                } else {
                    _ = try await engine.run(jobID: jobID)
                }
                guard generation == self.lifecycleGeneration else { return }
                await self.refresh()
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.lifecycleGeneration else { return }
                self.errorMessage = error.localizedDescription
                await self.refresh()
            }
            self.runTasks[jobID] = nil
        }
    }

    private func engine(for jobID: String) async throws -> VaultBackfillEngine? {
        if let existing = engines[jobID] { return existing }
        guard let saved = try await database.load(jobID: jobID),
              saved.job.provider == VaultProviderKind.slack.rawValue,
              let workspaceID = saved.checkpoint.sources.first?.accountID,
              let adapter = try slackController.makeVaultBackfillAdapter(
                workspaceID: workspaceID,
                traceSink: { event in VaultBackfillProductionTraceLogger.emit(event) }
              )
        else { return nil }
        let created = VaultBackfillEngine(
            provider: adapter,
            persistence: database,
            traceSink: { event in VaultBackfillProductionTraceLogger.emit(event) }
        )
        engines[jobID] = created
        return created
    }
}

private extension VaultController {
    struct ReconciliationBatch {
        let provider: VaultProviderKind
        let providerAccountID: String
        let accountID: String
        let accountName: String
        let providerContainerID: String
        let containerID: String
        let containerName: String
        let containerKind: VaultContainerKind
        let records: [VaultRecordInput]
        let fingerprint: String
    }

    struct ScheduledReconciliationBatchResult {
        let changedItemCount: Int
        let budgetReasonCode: String?
        let wasCancelled: Bool
    }

    func reconciliationBatches(
        subscriptions: [FeedSubscription],
        feedEntries: [NormalizedFeedEntry],
        slackEvidence: [SlackMessageEvidence],
        readStates: [String: Bool]
    ) throws -> [ReconciliationBatch] {
        var batches: [ReconciliationBatch] = []
        let subscriptionsByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        let rssAccountID = VaultIdentity.accountID(provider: VaultProviderKind.rss.rawValue, providerAccountID: "local-feeds")
        for (subscriptionID, entries) in Dictionary(grouping: feedEntries, by: \.subscriptionID).sorted(by: { $0.key < $1.key }) {
            let subscription = subscriptionsByID[subscriptionID]
            let containerID = VaultIdentity.containerID(
                provider: VaultProviderKind.rss.rawValue,
                accountID: rssAccountID,
                providerContainerID: subscriptionID
            )
            let records = try entries.sorted {
                if $0.retrievedAt != $1.retrievedAt { return $0.retrievedAt < $1.retrievedAt }
                return $0.id < $1.id
            }.map { entry in
                let originalChecksum = try Self.digest(entry)
                return VaultRecordInput(
                    id: "rss:\(entry.id)",
                    accountID: rssAccountID,
                    containerID: containerID,
                    providerRecordID: entry.identity.value,
                    kind: "feed_item",
                    title: entry.title,
                    body: entry.summary,
                    author: entry.author,
                    sourceURL: entry.canonicalURL,
                    occurredAt: entry.publishedAt ?? entry.updatedAt ?? entry.retrievedAt,
                    capturedAt: entry.retrievedAt,
                    modifiedAt: entry.updatedAt ?? entry.publishedAt ?? entry.retrievedAt,
                    metadata: [
                        "import_source": "p2_normalized_feed_entry",
                        "original_sha256": originalChecksum,
                        "identity_basis": entry.identity.basis.rawValue,
                    ],
                    isRead: readStates[entry.id] ?? false
                )
            }
            batches.append(.init(
                provider: .rss,
                providerAccountID: "local-feeds",
                accountID: rssAccountID,
                accountName: "Saved Feeds",
                providerContainerID: subscriptionID,
                containerID: containerID,
                containerName: subscription?.title ?? entries.first?.sourceTitle ?? "Feed",
                containerKind: .feed,
                records: records,
                fingerprint: Self.fingerprint(records)
            ))
        }

        let workspaces = try store.domainSlackWorkspaces()
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for key in Dictionary(grouping: slackEvidence, by: { "\($0.workspaceID)\u{1f}\($0.channelID)" }).keys.sorted() {
            guard let entries = Dictionary(grouping: slackEvidence, by: { "\($0.workspaceID)\u{1f}\($0.channelID)" })[key],
                  let first = entries.first else { continue }
            let accountID = VaultIdentity.accountID(provider: VaultProviderKind.slack.rawValue, providerAccountID: first.workspaceID)
            let containerID = VaultIdentity.containerID(
                provider: VaultProviderKind.slack.rawValue,
                accountID: accountID,
                providerContainerID: first.channelID
            )
            let records = try entries.sorted {
                if $0.messageTimestamp.date != $1.messageTimestamp.date { return $0.messageTimestamp.date < $1.messageTimestamp.date }
                return $0.id < $1.id
            }.map { evidence in
                let originalChecksum = try Self.digest(evidence)
                return VaultRecordInput(
                    id: "slack:\(evidence.id)",
                    accountID: accountID,
                    containerID: containerID,
                    providerRecordID: evidence.messageTimestamp.rawValue,
                    kind: "message",
                    title: evidence.channelName.isEmpty ? "Slack channel" : "#\(evidence.channelName)",
                    body: evidence.excerpt,
                    author: evidence.author.displayName == "Unknown Slack author" ? nil : evidence.author.displayName,
                    sourceURL: evidence.permalink,
                    occurredAt: evidence.messageTimestamp.date,
                    capturedAt: evidence.retrievedAt,
                    modifiedAt: evidence.editedAt?.date ?? evidence.messageTimestamp.date,
                    metadata: [
                        "import_source": "p3_normalized_slack_evidence",
                        "original_sha256": originalChecksum,
                        "author_kind": evidence.author.kind.rawValue,
                        "edited": String(evidence.isEdited),
                    ],
                    directlyMentionsUser: evidence.directlyMentionsAuthenticatedUser,
                    isRead: readStates[evidence.id] ?? false,
                    replyCount: evidence.replyCount
                )
            }
            batches.append(.init(
                provider: .slack,
                providerAccountID: first.workspaceID,
                accountID: accountID,
                accountName: workspacesByID[first.workspaceID]?.teamName ?? first.workspaceName,
                providerContainerID: first.channelID,
                containerID: containerID,
                containerName: first.channelName,
                containerKind: .slackChannel,
                records: records,
                fingerprint: Self.fingerprint(records)
            ))
        }
        return batches.sorted {
            if $0.provider.rawValue != $1.provider.rawValue { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
            return $0.containerID < $1.containerID
        }
    }

    func reconcile(_ batch: ReconciliationBatch, generation: UInt64) async throws -> Int {
        let now = Date()
        _ = try await database.upsert(account: .init(
            id: batch.accountID,
            provider: batch.provider.rawValue,
            providerAccountID: batch.providerAccountID,
            displayName: batch.accountName,
            createdAt: now,
            updatedAt: now
        ))
        _ = try await database.upsert(container: .init(
            id: batch.containerID,
            accountID: batch.accountID,
            providerContainerID: batch.providerContainerID,
            kind: batch.containerKind.rawValue,
            displayName: batch.containerName,
            createdAt: now,
            updatedAt: now
        ))
        try store.upsertVaultAccount(.init(
            id: batch.accountID,
            ownerID: Self.localOwnerID,
            providerRaw: batch.provider.rawValue,
            providerAccountID: batch.providerAccountID,
            displayName: batch.accountName,
            availabilityRaw: VaultControlAvailability.available.rawValue,
            updatedAt: now
        ))
        try store.upsertVaultContainer(.init(
            id: batch.containerID,
            ownerID: Self.localOwnerID,
            accountID: batch.accountID,
            providerContainerID: batch.providerContainerID,
            displayName: batch.containerName,
            kindRaw: batch.containerKind.rawValue,
            availabilityRaw: VaultControlAvailability.available.rawValue,
            lastImportedAt: now,
            updatedAt: now
        ))

        let checkpointID = Self.checkpointID(provider: batch.provider, accountID: batch.accountID, containerID: batch.containerID)
        let existing = try store.vaultImportCheckpointDomain(id: checkpointID)
        if existing?.state == .complete, existing?.sourceHighWatermark == batch.fingerprint { return 0 }
        let canResume = existing?.sourceHighWatermark == batch.fingerprint
        var cursor = canResume ? Int(existing?.sourceCursor ?? "0") ?? 0 : 0
        var checkpoint = VaultImportCheckpoint(
            id: checkpointID,
            ownerID: Self.localOwnerID,
            accountID: batch.accountID,
            containerID: batch.containerID,
            sourceKind: batch.provider,
            runID: UUID().uuidString.lowercased(),
            state: .running,
            sourceCursor: String(cursor),
            sourceHighWatermark: batch.fingerprint,
            pagesCommitted: canResume ? existing?.pagesCommitted ?? 0 : 0,
            itemsRead: canResume ? existing?.itemsRead ?? 0 : 0,
            itemsInserted: canResume ? existing?.itemsInserted ?? 0 : 0,
            duplicateItems: canResume ? existing?.duplicateItems ?? 0 : 0,
            lastReasonCode: "vault_import_started",
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try store.saveVaultImportCheckpoint(checkpoint)
        var changed = 0
        while cursor < batch.records.count {
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                checkpoint.state = .paused
                checkpoint.lastReasonCode = "vault_import_cancelled_at_page_boundary"
                checkpoint.updatedAt = Date()
                try store.saveVaultImportCheckpoint(checkpoint)
                return changed
            }
            let end = min(cursor + 100, batch.records.count)
            let results = try await database.upsert(records: Array(batch.records[cursor..<end]))
            let inserted = results.filter { $0.disposition != .unchanged }.count
            changed += inserted
            checkpoint.pagesCommitted += 1
            checkpoint.itemsRead += end - cursor
            checkpoint.itemsInserted += inserted
            checkpoint.duplicateItems += (end - cursor) - inserted
            cursor = end
            checkpoint.sourceCursor = cursor < batch.records.count ? String(cursor) : nil
            checkpoint.state = cursor < batch.records.count ? .running : .complete
            checkpoint.lastReasonCode = cursor < batch.records.count ? "vault_import_page_committed" : "vault_import_complete"
            checkpoint.updatedAt = Date()
            try store.saveVaultImportCheckpoint(checkpoint)
        }
        if batch.records.isEmpty {
            checkpoint.state = .complete
            checkpoint.sourceCursor = nil
            checkpoint.lastReasonCode = "vault_import_complete_empty"
            checkpoint.updatedAt = Date()
            try store.saveVaultImportCheckpoint(checkpoint)
        }
        return changed
    }

    func reconcileScheduled(
        _ batch: ReconciliationBatch,
        generation: UInt64,
        budget: ScheduledBriefingBudgetLedger
    ) async throws -> ScheduledReconciliationBatchResult {
        let checkpointID = Self.checkpointID(
            provider: batch.provider,
            accountID: batch.accountID,
            containerID: batch.containerID
        )
        let existing = try store.vaultImportCheckpointDomain(id: checkpointID)
        if existing?.state == .complete, existing?.sourceHighWatermark == batch.fingerprint {
            return .init(changedItemCount: 0, budgetReasonCode: nil, wasCancelled: false)
        }

        let canResume = existing?.sourceHighWatermark == batch.fingerprint
        var cursor = canResume ? Int(existing?.sourceCursor ?? "0") ?? 0 : 0
        cursor = min(max(cursor, 0), batch.records.count)
        let startedAt = Date()
        var checkpoint = VaultImportCheckpoint(
            id: checkpointID,
            ownerID: Self.localOwnerID,
            accountID: batch.accountID,
            containerID: batch.containerID,
            sourceKind: batch.provider,
            runID: UUID().uuidString.lowercased(),
            state: .running,
            sourceCursor: String(cursor),
            sourceHighWatermark: batch.fingerprint,
            pagesCommitted: canResume ? existing?.pagesCommitted ?? 0 : 0,
            itemsRead: canResume ? existing?.itemsRead ?? 0 : 0,
            itemsInserted: canResume ? existing?.itemsInserted ?? 0 : 0,
            duplicateItems: canResume ? existing?.duplicateItems ?? 0 : 0,
            lastReasonCode: "scheduled_vault_import_started",
            createdAt: existing?.createdAt ?? startedAt,
            updatedAt: startedAt
        )
        var changedItemCount = 0
        var preparedScope = false

        while cursor < batch.records.count {
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
            }

            let pageEnd = min(cursor + 100, batch.records.count)
            var committableRecords: [VaultRecordInput] = []
            var budgetReasonCode: String?
            for record in batch.records[cursor..<pageEnd] {
                let disposition = try await database.preflightUpsertDisposition(for: record)
                guard generation == lifecycleGeneration, !Task.isCancelled else {
                    return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
                }
                if disposition != .unchanged {
                    let estimate = try Self.scheduledStorageEstimate(for: record)
                    let claim = await budget.reserveArchiveItem(estimatedStorageBytes: estimate)
                    guard generation == lifecycleGeneration, !Task.isCancelled else {
                        return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
                    }
                    guard claim.permit != nil else {
                        budgetReasonCode = claim.rejectionReasonCode ?? ScheduledBriefingBudgetReason.archiveItemsExhausted
                        break
                    }
                }
                committableRecords.append(record)
            }

            guard !committableRecords.isEmpty else {
                if canResume, cursor > 0, let budgetReasonCode {
                    checkpoint.state = .paused
                    checkpoint.sourceCursor = String(cursor)
                    checkpoint.lastReasonCode = budgetReasonCode
                    checkpoint.updatedAt = Date()
                    try store.saveVaultImportCheckpoint(checkpoint)
                }
                return .init(
                    changedItemCount: changedItemCount,
                    budgetReasonCode: budgetReasonCode,
                    wasCancelled: false
                )
            }

            guard generation == lifecycleGeneration, !Task.isCancelled else {
                return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
            }
            if !preparedScope {
                try await prepareScheduledReconciliationScope(batch, at: startedAt, generation: generation)
                guard generation == lifecycleGeneration, !Task.isCancelled else {
                    return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
                }
                preparedScope = true
            }
            let results = try await database.upsert(records: committableRecords)
            await scheduledRecordCommitBoundary?()
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: true)
            }
            let changed = results.filter { $0.disposition != .unchanged }.count
            changedItemCount += changed

            // The cursor advances only after the archive transaction commits. If a
            // checkpoint save is interrupted, replay is safe and idempotent.
            cursor += committableRecords.count
            checkpoint.pagesCommitted += 1
            checkpoint.itemsRead += committableRecords.count
            checkpoint.itemsInserted += changed
            checkpoint.duplicateItems += committableRecords.count - changed
            checkpoint.sourceCursor = cursor < batch.records.count ? String(cursor) : nil
            if let budgetReasonCode {
                checkpoint.state = .paused
                checkpoint.lastReasonCode = budgetReasonCode
            } else if cursor < batch.records.count {
                checkpoint.state = .running
                checkpoint.lastReasonCode = "scheduled_vault_import_page_committed"
            } else {
                checkpoint.state = .complete
                checkpoint.lastReasonCode = "scheduled_vault_import_complete"
            }
            checkpoint.updatedAt = Date()
            try store.saveVaultImportCheckpoint(checkpoint)

            if let budgetReasonCode {
                return .init(
                    changedItemCount: changedItemCount,
                    budgetReasonCode: budgetReasonCode,
                    wasCancelled: false
                )
            }
        }

        return .init(changedItemCount: changedItemCount, budgetReasonCode: nil, wasCancelled: false)
    }

    func prepareScheduledReconciliationScope(
        _ batch: ReconciliationBatch,
        at date: Date,
        generation: UInt64
    ) async throws {
        _ = try await database.upsert(account: .init(
            id: batch.accountID,
            provider: batch.provider.rawValue,
            providerAccountID: batch.providerAccountID,
            displayName: batch.accountName,
            createdAt: date,
            updatedAt: date
        ))
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        _ = try await database.upsert(container: .init(
            id: batch.containerID,
            accountID: batch.accountID,
            providerContainerID: batch.providerContainerID,
            kind: batch.containerKind.rawValue,
            displayName: batch.containerName,
            createdAt: date,
            updatedAt: date
        ))
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        try store.upsertVaultAccount(.init(
            id: batch.accountID,
            ownerID: Self.localOwnerID,
            providerRaw: batch.provider.rawValue,
            providerAccountID: batch.providerAccountID,
            displayName: batch.accountName,
            availabilityRaw: VaultControlAvailability.available.rawValue,
            updatedAt: date
        ))
        try store.upsertVaultContainer(.init(
            id: batch.containerID,
            ownerID: Self.localOwnerID,
            accountID: batch.accountID,
            providerContainerID: batch.providerContainerID,
            displayName: batch.containerName,
            kindRaw: batch.containerKind.rawValue,
            availabilityRaw: VaultControlAvailability.available.rawValue,
            lastImportedAt: date,
            updatedAt: date
        ))
    }

    static func scheduledStorageEstimate(for record: VaultRecordInput) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return Int64(try encoder.encode(record).count)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ records: [VaultRecordInput]) -> String {
        let source = records.map { "\($0.id)\u{1f}\(Int($0.modifiedAt.timeIntervalSince1970 * 1_000))\u{1f}\($0.metadata["original_sha256"] ?? "")" }
            .joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func checkpointID(provider: VaultProviderKind, accountID: String, containerID: String) -> String {
        let digest = SHA256.hash(data: Data("\(provider.rawValue)\u{1f}\(accountID)\u{1f}\(containerID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "vault-import-\(provider.rawValue)-\(digest)"
    }
}
