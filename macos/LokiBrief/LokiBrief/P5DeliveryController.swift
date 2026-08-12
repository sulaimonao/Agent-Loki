import AppKit
import Combine
import Foundation
import OSLog

private enum P5ProductionTraceLogger {
    private static let logger = Logger(subsystem: "com.agentloki.LokiBrief", category: "scheduled-delivery")

    static func emit(_ event: ScheduleTraceEvent) {
        logger.info("event=\(event.event.rawValue, privacy: .public) trace_id=\(event.traceID, privacy: .public) span_id=\(event.spanID, privacy: .public) parent_span_id=\(event.parentSpanID ?? "none", privacy: .public) component=\(event.component, privacy: .public) status=\(event.status.rawValue, privacy: .public) reason_code=\(event.reasonCode, privacy: .public) occurrence_hash=\(event.occurrenceHash ?? "none", privacy: .public) count=\(event.boundedCount ?? 0, privacy: .public)")
    }

    static func emit(_ event: NotificationTraceEvent) {
        let identifierHash = event.notificationIdentifier.map(ScheduledBriefingPrivacy.hashIdentifier) ?? "none"
        logger.info("event=\(event.event, privacy: .public) trace_id=\(event.traceID, privacy: .public) span_id=\(event.spanID, privacy: .public) parent_span_id=\(event.parentSpanID ?? "none", privacy: .public) component=\(event.component, privacy: .public) status=\(event.status.rawValue, privacy: .public) reason_code=\(event.reasonCode, privacy: .public) notification_hash=\(identifierHash, privacy: .public) duration_ms=\(event.durationMilliseconds ?? 0, privacy: .public) item_count=\(event.itemCount ?? 0, privacy: .public) source_count=\(event.sourceCount ?? 0, privacy: .public)")
    }
}

private enum P5DeliveryExecutionPhase {
    case idle
    case preparing
    case coordinating
    case postCommitDelivery
}

private actor P5ScheduleFiringBridge: ScheduleFiringDelegate {
    typealias FireHandler = @MainActor @Sendable (ScheduleFiringContext) async -> ScheduleFiringOutcome
    typealias CancelHandler = @MainActor @Sendable (String) async -> ScheduleFiringCancellationDisposition

    private var fireHandler: FireHandler?
    private var cancelHandler: CancelHandler?

    func connect(fire: @escaping FireHandler, cancel: @escaping CancelHandler) {
        fireHandler = fire
        cancelHandler = cancel
    }

    func fire(_ context: ScheduleFiringContext) async -> ScheduleFiringOutcome {
        guard let fireHandler else { return .failed(reasonCode: "schedule_firing_bridge_unavailable") }
        return await fireHandler(context)
    }

    func cancelActiveFiring(reasonCode: String) async -> ScheduleFiringCancellationDisposition {
        await cancelHandler?(reasonCode) ?? .alreadyTerminal
    }
}

@MainActor
final class P5DeliveryController: ObservableObject {
    @Published private(set) var schedule: BriefSchedule
    @Published private(set) var schedulerSnapshot = BriefSchedulerSnapshot(state: .stopped, epoch: 0, nextOccurrence: nil, activeOccurrence: nil, reasonCode: "scheduler_not_started")
    @Published private(set) var currentRunState: ScheduledRunState = .waiting
    @Published private(set) var currentRunReasonCode = "no_active_delivery_run"
    @Published private(set) var launchSnapshot: LaunchAtLoginSnapshot
    @Published private(set) var notificationState: NotificationDeliverySettingsViewState
    @Published private(set) var historyRows: [DeliveryHistoryRow] = []
    @Published private(set) var entitlementMessage = "Implemented local delivery features are included with Loki Brief 1.0 Early Access."
    @Published private(set) var isBusy = false
    @Published private(set) var deletionInProgress = false
    @Published private(set) var updateInstallationInProgress = false

    var hasUpdateBlockingWork: Bool {
        isBusy
            || deletionInProgress
            || updateInstallationInProgress
            || !activeUpdateBlockingMutationTokens.isEmpty
    }

    private var deliveryOperationBarrierActive: Bool {
        deletionInProgress || updateInstallationInProgress
    }

    private unowned let model: AppModel
    private let store: LocalStore
    private let schedulePersistence: any SchedulePersisting
    private let sourceRefresher: LiveScheduledSourceRefresher
    private let coordinator: ScheduledBriefingCoordinator
    private let scheduler: BriefScheduler
    private let firingBridge: P5ScheduleFiringBridge
    private let launchService: LaunchAtLoginService
    private let notificationService: NotificationDeliveryService
    private let entitlementProvider: any FeatureEntitlementProvider
    private var lifecycleTask: Task<Void, Never>?
    private var notificationBuffer: NotificationRouteBuffer?
    private var activationComplete = false
    private var currentRunID: String?
    private var deliveryEpoch: UInt64 = 0
    private var runCancellationEpoch: UInt64 = 0
    private var runCancellationReasonCode = "delivery_run_cancelled"
    private var launchActionEpoch: UInt64 = 0
    private var notificationActionEpoch: UInt64 = 0
    private var notificationsRevoked: Bool
    private var runUIOwnershipEpoch: UInt64 = 0
    private var executionPhase: P5DeliveryExecutionPhase = .idle
    private var executionPhaseOwner: UInt64?
    private var activeUpdateBlockingMutationTokens: Set<UUID> = []

    init(
        model: AppModel,
        store: LocalStore,
        entitlementProvider: (any FeatureEntitlementProvider)? = nil,
        notificationClient: (any UserNotificationCenterClient)? = nil,
        launchClient: (any LaunchAtLoginSystemClient)? = nil,
        schedulePersistence injectedSchedulePersistence: (any SchedulePersisting)? = nil,
        isTesting: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) throws {
        self.model = model
        self.store = store
        self.schedule = try store.primaryBriefSchedule()
        let notificationSettings = try store.notificationDeliverySettings()
        self.notificationState = .init(
            notificationsEnabledPreference: notificationSettings.enabledPreference,
            authorization: notificationSettings.lastObservedAuthorization,
            privacyMode: notificationSettings.privacyMode
        )
        self.notificationsRevoked = !notificationSettings.enabledPreference
        self.launchSnapshot = .init(
            state: .notRegistered,
            desiredEnabled: model.settings.launchAtLoginPreference,
            reasonCode: "launch_status_not_checked",
            checkedAt: .now
        )
        self.entitlementProvider = entitlementProvider ?? Self.defaultEntitlementProvider(isTesting: isTesting)
        let schedulePersistence = injectedSchedulePersistence ?? SchedulePersistenceAdapter(store: store)
        self.schedulePersistence = schedulePersistence
        let persistence = ScheduledBriefingPersistenceAdapter(store: store)
        let sourceRefresher = LiveScheduledSourceRefresher(model: model)
        self.sourceRefresher = sourceRefresher
        self.coordinator = ScheduledBriefingCoordinator(
            sourceRefresher: sourceRefresher,
            vaultReconciler: LiveScheduledVaultReconciler(model: model),
            assembler: LiveScheduledBriefingAssembler(model: model),
            localPresenter: LiveScheduledLocalPresenter(model: model),
            persistence: persistence,
            eventSink: { event in ScheduledBriefingProductionTraceLogger.emit(event) }
        )
        self.firingBridge = P5ScheduleFiringBridge()
        self.scheduler = BriefScheduler(
            persistence: schedulePersistence,
            firingDelegate: firingBridge,
            clock: LiveSchedulerClock(),
            traceSink: { event in P5ProductionTraceLogger.emit(event) }
        )
        self.launchService = LaunchAtLoginService(
            client: launchClient ?? SMAppServiceLaunchAtLoginClient(),
            desiredEnabled: model.settings.launchAtLoginPreference,
            registrationAllowed: !isTesting,
            traceSink: { event in P5ProductionTraceLogger.emit(event) }
        )
        self.notificationService = NotificationDeliveryService(
            center: notificationClient ?? SystemUserNotificationCenterClient(),
            traceSink: { event in P5ProductionTraceLogger.emit(event) }
        )
        try reloadHistory()

        Task { [weak self, firingBridge] in
            await firingBridge.connect(
                fire: { [weak self] context in
                    guard let self else { return .failed(reasonCode: "delivery_controller_released") }
                    return await self.execute(context)
                },
                cancel: { [weak self] reasonCode in
                    guard let self else { return .alreadyTerminal }
                    return await self.cancelCurrentRun(reasonCode: reasonCode)
                }
            )
        }
    }

    func activate(
        lifecycle: AppLifecycleEventSource?,
        notificationBuffer: NotificationRouteBuffer,
        openMainWindow: @escaping @MainActor @Sendable () -> Void
    ) async {
        guard !activationComplete else { return }
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        activationComplete = true
        self.notificationBuffer = notificationBuffer
        _ = try? store.markScheduledBriefingRunsInterrupted()
        await notificationBuffer.connect { [weak self] route in
            guard let self else { return }
            guard !self.deliveryOperationBarrierActive else {
                P5ProductionTraceLogger.emit(.init(
                    event: "notification_response",
                    traceID: UUID().uuidString.lowercased(),
                    status: .skipped,
                    reasonCode: "notification_route_blocked_application_operation"
                ))
                return
            }
            guard (try? self.store.recordValidatedNotificationResponse(
                identifier: route.notificationIdentifier,
                briefID: route.briefID
            )) == true else {
                P5ProductionTraceLogger.emit(.init(
                    event: "notification_response",
                    traceID: UUID().uuidString.lowercased(),
                    status: .skipped,
                    reasonCode: "notification_route_persistence_mismatch",
                    notificationIdentifier: route.notificationIdentifier
                ))
                return
            }
            self.model.openHistory(id: route.briefID)
            openMainWindow()
            NSApp.activate()
            try? self.reloadHistory()
        }
        launchSnapshot = await launchService.refresh()
        let authorization = await notificationService.refreshAuthorization()
        updateAuthorization(authorization)
        if let lifecycle {
            lifecycleTask = Task { [weak self] in
                for await event in lifecycle.events {
                    guard let self else { return }
                    await self.handleLifecycleEvent(event)
                }
            }
        } else {
            await scheduler.start()
        }
        await refreshSchedulerSnapshot()
        try? reloadHistory()
    }

    func shutdown() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        guard !updateInstallationInProgress else { return }
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        await scheduler.stop(reasonCode: "application_will_terminate", cancelActive: true)
        guard !Task.isCancelled else { return }
        await cancelCurrentRun(reasonCode: "application_will_terminate")
        guard !Task.isCancelled else { return }
        try? store.save()
        guard !Task.isCancelled else { return }
        await refreshSchedulerSnapshot()
    }

    @discardableResult
    func prepareForUpdateInstallation() async -> Bool {
        guard !deliveryOperationBarrierActive,
              !isBusy,
              activeUpdateBlockingMutationTokens.isEmpty
        else { return false }
        updateInstallationInProgress = true
        await scheduler.prepareForUpdateInstallation()
        guard !isBusy, activeUpdateBlockingMutationTokens.isEmpty else {
            updateInstallationInProgress = false
            await scheduler.resumeAfterUpdateInstallationAbort()
            return false
        }
        do {
            try store.save()
            await refreshSchedulerSnapshot()
            return true
        } catch {
            updateInstallationInProgress = false
            await scheduler.resumeAfterUpdateInstallationAbort()
            return false
        }
    }

    func resumeAfterUpdateInstallationAbort() async {
        guard updateInstallationInProgress else { return }
        currentRunReasonCode = "update_installation_aborted"
        await scheduler.resumeAfterUpdateInstallationAbort()
        await refreshSchedulerSnapshot()
        updateInstallationInProgress = false
    }

    @discardableResult
    func prepareForDeleteAll() async -> Bool {
        guard !deliveryOperationBarrierActive else { return false }
        deletionInProgress = true
        deliveryEpoch &+= 1
        launchActionEpoch &+= 1
        notificationActionEpoch &+= 1
        notificationsRevoked = true
        notificationState.isPerformingAction = false
        runUIOwnershipEpoch &+= 1
        await notificationBuffer?.invalidate()
        await scheduler.stop(reasonCode: "delete_all_local_data", cancelActive: true)
        await coordinator.cancelForDataDeletion()
        await notificationService.removeAll()
        currentRunID = nil
        currentRunState = .waiting
        currentRunReasonCode = "local_data_deleted"
        isBusy = false
        executionPhase = .idle
        executionPhaseOwner = nil
        return true
    }

    func resumeAfterDeleteAllAbort() async {
        await notificationBuffer?.resume()
        notificationsRevoked = !notificationState.notificationsEnabledPreference
        deletionInProgress = false
        currentRunReasonCode = "local_data_deletion_aborted"
        await scheduler.scheduleChanged()
        await refreshSchedulerSnapshot()
    }

    func completeDeleteAll() {
        deletionInProgress = false
    }

    func reloadAfterDeleteAll() throws {
        schedule = try store.primaryBriefSchedule()
        let settings = try store.notificationDeliverySettings()
        notificationState = .init(
            notificationsEnabledPreference: settings.enabledPreference,
            authorization: settings.lastObservedAuthorization,
            privacyMode: settings.privacyMode
        )
        notificationsRevoked = true
        historyRows = []
        schedulerSnapshot = .init(state: .disabled, epoch: schedulerSnapshot.epoch, nextOccurrence: nil, activeOccurrence: nil, reasonCode: "schedule_disabled_after_delete_all")
    }

    func updateSchedule(_ transform: (inout BriefSchedule) -> Void) {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        let operationEpoch = deliveryEpoch
        var changed = schedule
        transform(&changed)
        do {
            try store.savePrimaryBriefSchedule(changed)
            schedule = changed
            Task { [weak self] in
                guard let self else { return }
                defer { finishUpdateBlockingMutation(mutationToken) }
                guard isDeliveryOperationCurrent(operationEpoch) else { return }
                await scheduler.scheduleChanged()
                guard isDeliveryOperationCurrent(operationEpoch) else { return }
                await refreshSchedulerSnapshot()
            }
        } catch {
            finishUpdateBlockingMutation(mutationToken)
            model.errorMessage = error.localizedDescription
        }
    }

    func generateBriefNow() {
        guard !isBusy, !deliveryOperationBarrierActive else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await runManualNow()
        }
    }

    @discardableResult
    func runManualNow() async -> ScheduleFiringOutcome {
        guard let mutationToken = beginUpdateBlockingMutation() else {
            return .canceled(reasonCode: "application_operation_barrier_active")
        }
        defer { finishUpdateBlockingMutation(mutationToken) }
        let operationEpoch = deliveryEpoch
        let cancellationEpoch = runCancellationEpoch
        let occurrence = manualOccurrence(at: .now)
        do {
            guard try await schedulePersistence.claim(occurrence, trigger: .manualRunNow, at: .now) == .claimed else {
                return .failed(reasonCode: "manual_occurrence_not_claimed")
            }
            return await executeManualOccurrence(
                occurrence,
                operationEpoch: operationEpoch,
                cancellationEpoch: cancellationEpoch
            )
        } catch {
            model.errorMessage = "Manual delivery could not persist its occurrence ledger: \(error.localizedDescription)"
            return .failed(reasonCode: "manual_occurrence_persistence_failed")
        }
    }

    private func executeManualOccurrence(
        _ occurrence: ScheduleOccurrence,
        operationEpoch: UInt64,
        cancellationEpoch: UInt64
    ) async -> ScheduleFiringOutcome {
        do {
            let outcome = await execute(
                .init(occurrence: occurrence, trigger: .manualRunNow, schedulerEpoch: schedulerSnapshot.epoch),
                cancellationEpoch: cancellationEpoch
            )
            guard operationEpoch == deliveryEpoch else {
                return .canceled(reasonCode: "local_data_deleted")
            }
            let terminal: (ScheduleOccurrenceState, String)
            switch outcome {
            case let .succeeded(reason), let .partiallySucceeded(reason): terminal = (.succeeded, reason)
            case let .canceled(reason): terminal = (.canceled, reason)
            case let .failed(reason), let .reauthorizationRequired(reason), let .entitlementRequired(reason): terminal = (.failed, reason)
            }
            try await schedulePersistence.mark(occurrence, state: terminal.0, reasonCode: terminal.1, at: .now)
            return outcome
        } catch {
            model.errorMessage = "Manual delivery could not persist its occurrence ledger: \(error.localizedDescription)"
            return .failed(reasonCode: "manual_occurrence_persistence_failed")
        }
    }

    @discardableResult
    func cancelCurrentRun(
        reasonCode: String = "explicit_user_cancellation"
    ) async -> ScheduleFiringCancellationDisposition {
        let mutationToken: UUID?
        if deletionInProgress {
            mutationToken = nil
        } else {
            guard let admittedToken = beginUpdateBlockingMutation() else { return .alreadyTerminal }
            mutationToken = admittedToken
        }
        defer {
            if let mutationToken { finishUpdateBlockingMutation(mutationToken) }
        }
        let boundedReason = SchedulePrivacy.boundedIdentifier(reasonCode, fallback: "delivery_run_cancelled")
        switch executionPhase {
        case .idle:
            return .alreadyTerminal
        case .postCommitDelivery:
            await notificationService.cancelActiveSubmissions(reasonCode: "active_notification_submission_cancelled")
            currentRunReasonCode = "brief_committed_notification_cancelled"
            return .alreadyTerminal
        case .coordinating:
            if let currentRunID, await coordinator.cancel(runID: currentRunID) == false {
                await notificationService.cancelActiveSubmissions(reasonCode: "active_notification_submission_cancelled")
                return .alreadyTerminal
            }
        case .preparing:
            break
        }

        runCancellationEpoch &+= 1
        runCancellationReasonCode = boundedReason
        await notificationService.cancelActiveSubmissions(reasonCode: "active_notification_submission_cancelled")
        currentRunState = .canceled
        currentRunReasonCode = boundedReason
        try? reloadHistory()
        return .accepted
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        launchActionEpoch &+= 1
        let actionEpoch = launchActionEpoch
        Task { [weak self] in
            guard let self else { return }
            defer { finishUpdateBlockingMutation(mutationToken) }
            guard !deliveryOperationBarrierActive, actionEpoch == launchActionEpoch else { return }
            let operationEpoch = deliveryEpoch
            launchSnapshot = enabled ? await launchService.registerExplicitly() : await launchService.unregisterExplicitly()
            guard isDeliveryOperationCurrent(operationEpoch), actionEpoch == launchActionEpoch else { return }
            model.settings.launchAtLoginPreference = launchSnapshot.desiredEnabled
            model.saveSettings()
        }
    }

    func openLoginItemsSettings() {
        Task { await launchService.openLoginItemsSettingsExplicitly() }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        notificationActionEpoch &+= 1
        let actionEpoch = notificationActionEpoch
        notificationsRevoked = true
        notificationState.isPerformingAction = true

        if !enabled {
            notificationState.notificationsEnabledPreference = false
            var revokedSchedule = schedule
            revokedSchedule.delivery.notificationsEnabled = false
            schedule = revokedSchedule
            do {
                let settings = try store.notificationDeliverySettings()
                settings.enabledPreference = false
                settings.updatedAt = .now
                try store.savePrimaryBriefSchedule(revokedSchedule)
            } catch {
                model.errorMessage = "Notifications remain off for this launch, but the preference could not be saved: \(error.localizedDescription)"
            }
        }

        Task { [weak self] in
            guard let self else { return }
            defer { finishUpdateBlockingMutation(mutationToken) }
            guard
                  !deliveryOperationBarrierActive,
                  actionEpoch == notificationActionEpoch
            else { return }
            let operationEpoch = deliveryEpoch
            defer {
                if actionEpoch == notificationActionEpoch {
                    notificationState.isPerformingAction = false
                }
            }
            if !enabled {
                await notificationBuffer?.invalidate()
                await notificationService.removeAll()
            }
            guard isDeliveryOperationCurrent(operationEpoch),
                  actionEpoch == notificationActionEpoch
            else { return }
            var authorization = await notificationService.refreshAuthorization()
            guard isDeliveryOperationCurrent(operationEpoch),
                  actionEpoch == notificationActionEpoch
            else { return }
            if enabled, authorization == .notDetermined {
                authorization = await notificationService.requestAuthorization(reason: .explicitUserEnable)
                guard isDeliveryOperationCurrent(operationEpoch),
                      actionEpoch == notificationActionEpoch
                else { return }
            }
            do {
                let settings = try store.notificationDeliverySettings()
                settings.enabledPreference = enabled
                settings.lastObservedAuthorization = authorization
                settings.updatedAt = .now
                var changedSchedule = schedule
                changedSchedule.delivery.notificationsEnabled = enabled
                try store.savePrimaryBriefSchedule(changedSchedule)
                guard isDeliveryOperationCurrent(operationEpoch),
                      actionEpoch == notificationActionEpoch
                else { return }
                schedule = changedSchedule
                notificationState.notificationsEnabledPreference = enabled
                notificationState.authorization = authorization
                notificationsRevoked = !enabled
                if enabled {
                    await notificationBuffer?.resume()
                }
            } catch {
                model.errorMessage = "The notification preference could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func setNotificationPrivacy(_ mode: NotificationPrivacyMode) {
        guard !deliveryOperationBarrierActive else { return }
        do {
            let settings = try store.notificationDeliverySettings()
            settings.privacyMode = mode
            try store.save()
            notificationState.privacyMode = mode
            updateSchedule { $0.delivery.notificationPrivacy = mode == .summary ? .summary : .minimal }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    func sendTestNotification() {
        guard !notificationsRevoked,
              let mutationToken = beginUpdateBlockingMutation()
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { finishUpdateBlockingMutation(mutationToken) }
            guard !deliveryOperationBarrierActive, !notificationsRevoked else { return }
            let operationEpoch = deliveryEpoch
            let key = "manual-test-\(UUID().uuidString.lowercased())"
            let input = NotificationDeliveryInput(
                occurrenceKey: key,
                briefID: model.brief.id,
                runResult: .completed,
                hasUsableBrief: true,
                itemCount: model.brief.itemCount,
                sourceCount: Set(model.brief.sections.flatMap(\.items).map(\.source.id)).count,
                privacyMode: notificationState.privacyMode,
                briefingDay: model.brief.resolvedBriefingDay
            )
            await deliverNotification(input, operationEpoch: operationEpoch)
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func removeNotificationArtifacts() async {
        await notificationService.removeAll()
    }

    private func execute(
        _ context: ScheduleFiringContext,
        cancellationEpoch expectedCancellationEpoch: UInt64? = nil
    ) async -> ScheduleFiringOutcome {
        guard !deliveryOperationBarrierActive else { return .canceled(reasonCode: "application_operation_barrier_active") }
        guard !isBusy else { return .failed(reasonCode: "delivery_run_already_active") }
        let operationEpoch = deliveryEpoch
        let cancellationEpoch = expectedCancellationEpoch ?? runCancellationEpoch
        if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
            return cancellation
        }
        runUIOwnershipEpoch &+= 1
        let uiOwnershipEpoch = runUIOwnershipEpoch
        executionPhase = .preparing
        executionPhaseOwner = uiOwnershipEpoch
        isBusy = true
        currentRunState = .preparing
        currentRunReasonCode = "delivery_plan_preparing"
        defer {
            if uiOwnershipEpoch == runUIOwnershipEpoch {
                currentRunID = nil
                isBusy = false
                executionPhase = .idle
                executionPhaseOwner = nil
            }
        }

        let planningSchedule = schedule
        let planningNotificationState = notificationState
        let feedSubscriptions = model.subscriptions.filter(\.enabled)
        let feedIDs = feedSubscriptions.map(\.id)
        let slackIDs = model.slackController.workspaces.filter {
            planningSchedule.selectedAccountIDs.contains($0.id) && model.slackController.isWorkspaceEnabled($0.id)
        }.map(\.id)
        let slackSelectionsByWorkspace: [String: [SlackConversationSelection]]
        let localConsentWorkspaceIDs: [String]
        do {
            slackSelectionsByWorkspace = try Dictionary(uniqueKeysWithValues: slackIDs.map { workspaceID in
                (
                    workspaceID,
                    try store.domainSlackSelections(workspaceID: workspaceID).filter(\.enabled)
                )
            })
            let selectedWorkspaceIDs = Set(slackIDs)
            localConsentWorkspaceIDs = try store.domainSlackWorkspaces()
                .filter { selectedWorkspaceIDs.contains($0.id) && $0.localModelConsent }
                .map(\.id)
        } catch {
            currentRunState = .failed
            currentRunReasonCode = "delivery_plan_snapshot_failed"
            return .failed(reasonCode: "delivery_plan_snapshot_failed")
        }
        let localEnabled = planningSchedule.delivery.allowScheduledOllama && model.localGenerationEnabled
        let requiredFeatures: [LokiPaidFeature] = [.dailyBriefScheduling]
            + (((planningSchedule.delivery.refreshFeeds && !feedIDs.isEmpty) || (planningSchedule.delivery.refreshSelectedSlackWorkspaces && !slackIDs.isEmpty)) ? [.backgroundForwardSync] : [])
            + (slackIDs.count > 1 ? [.multipleAccountScheduledSync] : [])
            + (localEnabled ? [.scheduledLocalModelProcessing] : [])
        var entitlementDecisions: [ScheduledBriefingEntitlementDecision] = []
        for feature in requiredFeatures {
            let entitlement = await entitlementProvider.entitlement(for: feature)
            entitlementDecisions.append(.init(entitlement))
            if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
                return cancellation
            }
            guard entitlement.acquisitionAllowed else {
                entitlementMessage = "\(LokiBriefPresentation.label(for: feature.rawValue)): \(LokiBriefPresentation.reason(for: entitlement.reasonCode))"
                currentRunState = .entitlementRequired
                currentRunReasonCode = entitlement.reasonCode
                return .entitlementRequired(reasonCode: entitlement.reasonCode)
            }
        }
        entitlementMessage = "Implemented local delivery features are included with Loki Brief 1.0 Early Access."

        do {
            if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
                return cancellation
            }
            let trigger = scheduledTrigger(context.trigger)
            let runID = "run-\(context.occurrence.key.rawValue)-\(trigger.rawValue)"
            let plan = try ScheduledBriefingPlan(
                id: runID,
                occurrenceID: context.occurrence.key.rawValue,
                scheduledFor: context.occurrence.resolvedExecutionDate,
                briefingDay: context.occurrence.briefingDay,
                trigger: trigger,
                feedSubscriptionIDs: feedIDs,
                slackWorkspaceIDs: slackIDs,
                refreshFeedsEnabled: planningSchedule.delivery.refreshFeeds,
                refreshSlackEnabled: planningSchedule.delivery.refreshSelectedSlackWorkspaces,
                slackSelections: slackIDs.map { workspaceID in
                    .init(
                        workspaceID: workspaceID,
                        channelIDs: slackSelectionsByWorkspace[workspaceID, default: []].map(\.channelID)
                    )
                },
                localPresentationEnabled: localEnabled,
                localPresentationConsentedWorkspaceIDs: localConsentWorkspaceIDs,
                notificationsEnabled: planningSchedule.delivery.notificationsEnabled
                    && planningNotificationState.notificationsEnabledPreference,
                notificationAuthorization: planningNotificationState.authorization,
                notificationPrivacyMode: Self.restrictivePrivacyMode(
                    planningNotificationState.privacyMode,
                    planningSchedule.delivery.notificationPrivacy == .summary ? .summary : .minimal
                ),
                entitlementDecisions: entitlementDecisions
            )
            sourceRefresher.configure(
                plan: plan,
                feedSubscriptions: feedSubscriptions,
                slackSelectionsByWorkspace: slackSelectionsByWorkspace
            )
            currentRunID = runID
            executionPhase = .coordinating
            currentRunState = .synchronizing
            currentRunReasonCode = "scheduled_delivery_started"
            let result = await coordinator.run(plan)
            if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
                return cancellation
            }
            executionPhase = .postCommitDelivery
            currentRunID = nil
            currentRunState = result.state.scheduledRunState
            currentRunReasonCode = result.reasonCode
            model.applyScheduledBriefingResult(result)

            if let brief = result.brief,
               plan.notificationsEnabled,
               plan.notificationAuthorization.permitsDelivery,
               !notificationsRevoked,
               schedule.delivery.notificationsEnabled,
               notificationState.notificationsEnabledPreference {
                let notifyResult: NotificationEligibleRunResult = result.state == .complete ? .completed : .partiallyCompleted
                let input = NotificationDeliveryInput(
                    occurrenceKey: context.occurrence.key.rawValue,
                    briefID: brief.id,
                    runResult: notifyResult,
                    hasUsableBrief: true,
                    itemCount: brief.itemCount,
                    sourceCount: result.sourceOutcomes.count,
                    privacyMode: Self.restrictivePrivacyMode(
                        plan.notificationPrivacyMode,
                        notificationState.privacyMode
                    ),
                    briefingDay: plan.briefingDay
                )
                currentRunState = .delivering
                await deliverNotification(
                    input,
                    operationEpoch: operationEpoch,
                    cancellationEpoch: cancellationEpoch
                )
                if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
                    return cancellation
                }
                currentRunState = result.state.scheduledRunState
            }
            try? reloadHistory()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self,
                      uiOwnershipEpoch == runUIOwnershipEpoch,
                      cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) == nil
                else { return }
                await refreshSchedulerSnapshot()
                guard uiOwnershipEpoch == runUIOwnershipEpoch,
                      cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) == nil
                else { return }
                try? store.recordNextScheduledOccurrence(runID: runID, next: schedulerSnapshot.nextOccurrence?.resolvedExecutionDate)
            }
            switch result.state {
            case .complete: return .succeeded(reasonCode: result.reasonCode)
            case .partial: return .partiallySucceeded(reasonCode: result.reasonCode)
            case .cancelled: return .canceled(reasonCode: result.reasonCode)
            default: return .failed(reasonCode: result.reasonCode)
            }
        } catch {
            if let cancellation = cancellationOutcome(operationEpoch: operationEpoch, cancellationEpoch: cancellationEpoch) {
                return cancellation
            }
            currentRunID = nil
            currentRunState = .failed
            currentRunReasonCode = "delivery_plan_failed"
            return .failed(reasonCode: "delivery_plan_failed")
        }
    }

    private func deliverNotification(
        _ input: NotificationDeliveryInput,
        operationEpoch: UInt64,
        cancellationEpoch: UInt64? = nil
    ) async {
        guard !notificationsRevoked,
              isDeliveryOperationCurrent(operationEpoch, cancellationEpoch: cancellationEpoch)
        else { return }
        let authorization = await notificationService.refreshAuthorization()
        guard !notificationsRevoked,
              isDeliveryOperationCurrent(operationEpoch, cancellationEpoch: cancellationEpoch)
        else { return }
        updateAuthorization(authorization)
        do {
            let (reservation, _) = try store.reserveNotificationDelivery(input: input, authorization: authorization)
            let outcome = await notificationService.deliver(input, reservation: reservation)
            let identifier = LokiNotificationContract.stableIdentifier(occurrenceKey: input.occurrenceKey)
            guard !notificationsRevoked,
                  isDeliveryOperationCurrent(operationEpoch, cancellationEpoch: cancellationEpoch)
            else {
                await notificationService.remove(identifier: identifier)
                try? store.recordNotificationDelivery(
                    identifier: identifier,
                    outcome: .removed,
                    authorization: authorization,
                    reasonCode: "notification_revoked_before_completion"
                )
                return
            }
            try store.recordNotificationDelivery(
                identifier: identifier,
                outcome: outcome,
                authorization: authorization,
                reasonCode: "notification_\(outcome.rawValue)"
            )
            try reloadHistory()
        } catch {
            model.errorMessage = "Notification delivery was not claimed: \(error.localizedDescription)"
        }
    }

    private func isDeliveryOperationCurrent(
        _ operationEpoch: UInt64,
        cancellationEpoch: UInt64? = nil
    ) -> Bool {
        guard !deliveryOperationBarrierActive, operationEpoch == deliveryEpoch else { return false }
        return cancellationEpoch.map { $0 == runCancellationEpoch } ?? true
    }

    private func cancellationOutcome(
        operationEpoch: UInt64,
        cancellationEpoch: UInt64
    ) -> ScheduleFiringOutcome? {
        if deliveryOperationBarrierActive || operationEpoch != deliveryEpoch {
            return .canceled(reasonCode: "application_operation_barrier_active")
        }
        if cancellationEpoch != runCancellationEpoch {
            return .canceled(reasonCode: runCancellationReasonCode)
        }
        return nil
    }

    private func updateAuthorization(_ authorization: NotificationAuthorizationState) {
        notificationState.authorization = authorization
        if let settings = try? store.notificationDeliverySettings() {
            settings.lastObservedAuthorization = authorization
            try? store.save()
        }
    }

    private func handleLifecycleEvent(_ event: AppLifecycleEvent) async {
        guard let mutationToken = beginUpdateBlockingMutation() else {
            P5ProductionTraceLogger.emit(.init(
                event: "scheduler_lifecycle_event",
                traceID: UUID().uuidString.lowercased(),
                status: .skipped,
                reasonCode: "lifecycle_event_blocked_update_installation"
            ))
            return
        }
        defer { finishUpdateBlockingMutation(mutationToken) }
        await scheduler.handle(event)
        await refreshSchedulerSnapshot()
    }

    private func beginUpdateBlockingMutation() -> UUID? {
        guard !deliveryOperationBarrierActive else { return nil }
        let token = UUID()
        activeUpdateBlockingMutationTokens.insert(token)
        return token
    }

    private func finishUpdateBlockingMutation(_ token: UUID) {
        activeUpdateBlockingMutationTokens.remove(token)
    }

    private func refreshSchedulerSnapshot() async {
        schedulerSnapshot = await scheduler.snapshot()
    }

    private func reloadHistory() throws {
        let deliveries = try store.deliveryRecords()
        historyRows = try store.scheduledBriefingRuns().map { run in
            let delivery = deliveries.first(where: { $0.occurrenceIdentifierHash == run.occurrenceHash })
            return DeliveryHistoryRow(
                id: run.id,
                briefingDay: store.localCalendarDay(ownerType: .run, ownerIdentifier: run.id)
                    ?? (try? run.planMetadata().briefingDay)
                    ?? LocalCalendarDay.resolve(containing: run.scheduledFor),
                intendedAt: run.scheduledFor,
                actualAt: run.completedAt,
                triggerLabel: LokiBriefPresentation.label(for: run.triggerRaw),
                resultLabel: LokiBriefPresentation.label(for: run.stateRaw),
                itemCount: run.acceptedItemCount,
                sourceCount: run.successfulSourceCount + run.failedSourceCount,
                briefID: delivery?.briefID ?? run.briefID,
                notificationOutcome: delivery?.outcome ?? .notRequested,
                boundedReasonCode: run.reasonCode
            )
        }
    }

    private func scheduledTrigger(_ trigger: ScheduleActivationTrigger) -> ScheduledRunTrigger {
        switch trigger {
        case .scheduled: .scheduled
        case .catchUpAfterWake: .catchUpAfterWake
        case .catchUpAfterLaunch, .settingsChanged, .systemClockChanged, .systemTimeZoneChanged, .lowPowerEnded, .userSessionReturned: .catchUpAfterLaunch
        case .manualTest: .manualTest
        case .manualRunNow: .manualRunNow
        case .retry: .retry
        }
    }

    private func manualOccurrence(at date: Date) -> ScheduleOccurrence {
        let timeZone = TimeZone.autoupdatingCurrent
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents(in: timeZone, from: date)
        let localDate = LocalCalendarDay(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        ).storageValue
        let localTime = ScheduleLocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        let nonce = UUID().uuidString.lowercased()
        return .init(
            key: SchedulePrivacy.occurrenceKey(canonicalValue: "manual|\(date.timeIntervalSince1970)|\(nonce)"),
            slotKey: SchedulePrivacy.slotKey(canonicalValue: "manual|\(nonce)"),
            scheduleID: schedule.id,
            intendedLocalDate: localDate,
            intendedLocalTime: localTime,
            resolvedTimeZoneIdentifier: timeZone.identifier,
            recurrenceVersion: schedule.recurrenceVersion,
            resolvedExecutionDate: date,
            resolvedAfterDSTGap: false,
            repeatedLocalTime: false
        )
    }

    private static func restrictivePrivacyMode(
        _ first: NotificationPrivacyMode,
        _ second: NotificationPrivacyMode
    ) -> NotificationPrivacyMode {
        first == .minimal || second == .minimal ? .minimal : .summary
    }

    private static func defaultEntitlementProvider(isTesting: Bool) -> any FeatureEntitlementProvider {
        LokiBriefEarlyAccessEntitlementProvider()
    }
}
