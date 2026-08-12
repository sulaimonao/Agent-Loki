import Foundation

enum ApplicationUpdateReadinessStatus: String, CaseIterable, Sendable {
    case blocked
    case degraded
    case ready
}

enum ApplicationUpdateReadinessReason: String, CaseIterable, Sendable {
    case readinessStarted = "update_readiness_started"
    case participantReady = "update_participant_ready"
    case participantPrepared = "update_participant_prepared"
    case participantRecovered = "update_participant_recovered"
    case participantBlocked = "update_participant_blocked"
    case participantDegraded = "update_participant_degraded"
    case participantRecoveryFailed = "update_participant_recovery_failed"
    case activeWork = "update_install_blocked_active_work"
    case activeFeedWork = "update_install_blocked_feed_work"
    case activeConnectorWork = "update_install_blocked_connector_work"
    case activeSlackWork = "update_install_blocked_slack_work"
    case activeVaultDatabaseWork = "update_install_blocked_vault_database_work"
    case activeLocalGenerationWork = "update_install_blocked_local_generation_work"
    case activeChatGeneration = "update_install_blocked_chat_generation"
    case activeChatToolWork = "update_install_blocked_chat_tool_work"
    case activeChatModelAssessment = "update_install_blocked_chat_model_assessment"
    case activeChatP8Work = "update_install_blocked_chat_p8_work"
    case activeDeliveryRun = "update_install_blocked_delivery_run"
    case deleteAllInProgress = "update_install_blocked_delete_all_in_progress"
    case updateAlreadyInProgress = "update_install_blocked_update_in_progress"
    case invalidParticipantConfiguration = "update_participant_configuration_invalid"
    case preparationFailed = "update_preparation_failed"
    case preparationContractIncomplete = "update_preparation_contract_incomplete"
    case preparationRecovered = "update_preparation_recovered"
    case preparationRecoveryIncomplete = "update_preparation_recovery_incomplete"
    case requestCancelled = "update_preparation_cancelled"
    case updateReady = "update_install_ready"
    case updateLeaseReleased = "update_lease_released"
    case updateLeaseAborted = "update_lease_aborted"
    case updateLeaseNotActive = "update_lease_not_active"
    case deleteAllLeaseAcquired = "delete_all_lease_acquired"
    case deleteAllLeaseReleased = "delete_all_lease_released"
    case deleteAllLeaseAborted = "delete_all_lease_aborted"
    case deleteAllLeaseNotActive = "delete_all_lease_not_active"
    case deleteAllBlockedByUpdate = "delete_all_blocked_update_in_progress"
    case deleteAllAlreadyInProgress = "delete_all_blocked_delete_all_in_progress"
}

enum ApplicationUpdatePreparationContract: String, CaseIterable, Hashable, Sendable {
    case saveState = "save_state"
    case quiesceAndCloseStoresForTermination = "quiesce_and_close_stores_for_termination"
}

struct ApplicationUpdateParticipantAssessment: Equatable, Sendable {
    let status: ApplicationUpdateReadinessStatus
    let reasonCode: ApplicationUpdateReadinessReason

    static let ready = ApplicationUpdateParticipantAssessment(
        status: .ready,
        reasonCode: .participantReady
    )

    static func blocked(
        _ reasonCode: ApplicationUpdateReadinessReason = .participantBlocked
    ) -> ApplicationUpdateParticipantAssessment {
        .init(status: .blocked, reasonCode: reasonCode)
    }

    static func degraded(
        _ reasonCode: ApplicationUpdateReadinessReason = .participantDegraded
    ) -> ApplicationUpdateParticipantAssessment {
        .init(status: .degraded, reasonCode: reasonCode)
    }
}

enum ApplicationUpdateParticipantPreparationState: String, CaseIterable, Sendable {
    case prepared
    case blocked
    case degraded
}

struct ApplicationUpdateParticipantPreparation: Equatable, Sendable {
    let state: ApplicationUpdateParticipantPreparationState
    let fulfilledContracts: Set<ApplicationUpdatePreparationContract>
    let reasonCode: ApplicationUpdateReadinessReason

    static func prepared(
        fulfilling contracts: Set<ApplicationUpdatePreparationContract>
    ) -> ApplicationUpdateParticipantPreparation {
        .init(
            state: .prepared,
            fulfilledContracts: contracts,
            reasonCode: .participantPrepared
        )
    }

    static func blocked(
        _ reasonCode: ApplicationUpdateReadinessReason = .participantBlocked
    ) -> ApplicationUpdateParticipantPreparation {
        .init(state: .blocked, fulfilledContracts: [], reasonCode: reasonCode)
    }

    static func degraded(
        _ reasonCode: ApplicationUpdateReadinessReason = .preparationFailed
    ) -> ApplicationUpdateParticipantPreparation {
        .init(state: .degraded, fulfilledContracts: [], reasonCode: reasonCode)
    }
}

struct ApplicationUpdateParticipantRecovery: Equatable, Sendable {
    let recovered: Bool
    let reasonCode: ApplicationUpdateReadinessReason

    static let recovered = ApplicationUpdateParticipantRecovery(
        recovered: true,
        reasonCode: .participantRecovered
    )

    static let failed = ApplicationUpdateParticipantRecovery(
        recovered: false,
        reasonCode: .participantRecoveryFailed
    )
}

protocol ApplicationUpdateReadinessParticipant: Sendable {
    /// A stable component identifier. It must not contain account, source, or user data.
    var identifier: String { get }
    var preparationOrder: Int { get }
    var requiredPreparationContracts: Set<ApplicationUpdatePreparationContract> { get }

    func assessApplicationUpdateReadiness() async -> ApplicationUpdateParticipantAssessment
    func prepareForApplicationUpdate() async -> ApplicationUpdateParticipantPreparation
    func recoverAfterApplicationUpdateAbort() async -> ApplicationUpdateParticipantRecovery
}

struct ApplicationUpdateBlocker: Equatable, Sendable {
    let participantIdentifier: String?
    let reasonCode: ApplicationUpdateReadinessReason
}

enum ApplicationUpdateReadinessTraceStatus: String, CaseIterable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

struct ApplicationUpdateReadinessEvent: Equatable, Sendable {
    let timestamp: Date
    let event: String
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: ApplicationUpdateReadinessTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int
    let metadata: [String: String]
}

protocol ApplicationUpdateReadinessEventSinking: Sendable {
    func record(_ event: ApplicationUpdateReadinessEvent) async
}

struct NoOpApplicationUpdateReadinessEventSink: ApplicationUpdateReadinessEventSinking {
    func record(_ event: ApplicationUpdateReadinessEvent) async { }
}

struct ApplicationUpdateReadinessReport: Sendable {
    let status: ApplicationUpdateReadinessStatus
    let blockers: [ApplicationUpdateBlocker]
    let reasonCodes: [ApplicationUpdateReadinessReason]
    let preparedParticipantIdentifiers: [String]
    let traceID: String
    let lease: ApplicationUpdateLease?
}

enum ApplicationUpdateLeaseDispositionState: String, CaseIterable, Sendable {
    case released
    case aborted
    case degraded
    case notActive = "not_active"
}

struct ApplicationUpdateLeaseDisposition: Equatable, Sendable {
    let state: ApplicationUpdateLeaseDispositionState
    let reasonCodes: [ApplicationUpdateReadinessReason]
    let preparedParticipantIdentifiers: [String]
}

struct ApplicationUpdateLease: Sendable {
    fileprivate let token: UUID
    fileprivate let coordinator: ApplicationUpdateReadinessCoordinator

    /// Releases a successfully handed-off install. It does not reopen prepared stores.
    func release() async -> ApplicationUpdateLeaseDisposition {
        await coordinator.releaseUpdateLease(token: token)
    }

    /// Aborts before replacement and recovers prepared participants in reverse order.
    func abort() async -> ApplicationUpdateLeaseDisposition {
        await coordinator.abortUpdateLease(token: token)
    }
}

enum ApplicationDeleteAllLeaseAcquisitionStatus: String, CaseIterable, Sendable {
    case acquired
    case blocked
}

struct ApplicationDeleteAllLeaseAcquisition: Sendable {
    let status: ApplicationDeleteAllLeaseAcquisitionStatus
    let reasonCode: ApplicationUpdateReadinessReason
    let lease: ApplicationDeleteAllLease?
}

enum ApplicationDeleteAllLeaseDispositionState: String, CaseIterable, Sendable {
    case released
    case aborted
    case notActive = "not_active"
}

struct ApplicationDeleteAllLeaseDisposition: Equatable, Sendable {
    let state: ApplicationDeleteAllLeaseDispositionState
    let reasonCode: ApplicationUpdateReadinessReason
}

struct ApplicationDeleteAllLease: Sendable {
    fileprivate let token: UUID
    fileprivate let coordinator: ApplicationUpdateReadinessCoordinator

    func release() async -> ApplicationDeleteAllLeaseDisposition {
        await coordinator.releaseDeleteAllLease(token: token, aborted: false)
    }

    func abort() async -> ApplicationDeleteAllLeaseDisposition {
        await coordinator.releaseDeleteAllLease(token: token, aborted: true)
    }
}

enum ApplicationUpdateCoordinatorOperation: String, CaseIterable, Sendable {
    case idle
    case preparingUpdate = "preparing_update"
    case updateReady = "update_ready"
    case recoveringUpdate = "recovering_update"
    case deleteAll = "delete_all"
}

struct ApplicationUpdateCoordinatorSnapshot: Equatable, Sendable {
    let operation: ApplicationUpdateCoordinatorOperation
    let reasonCode: ApplicationUpdateReadinessReason?
}

actor ApplicationUpdateReadinessCoordinator {
    private struct PreparedParticipant: Sendable {
        let participant: any ApplicationUpdateReadinessParticipant
        let identifier: String
    }

    private struct TraceContext: Sendable {
        let traceID: String
        let rootSpanID: String
        let startedAt: Date
    }

    private enum State {
        case idle
        case preparingUpdate(token: UUID, trace: TraceContext)
        case updateReady(token: UUID, trace: TraceContext, participants: [PreparedParticipant])
        case recoveringUpdate(token: UUID, trace: TraceContext, participants: [PreparedParticipant])
        case deleteAll(token: UUID, trace: TraceContext)
    }

    private let participants: [any ApplicationUpdateReadinessParticipant]
    private let eventSink: any ApplicationUpdateReadinessEventSinking
    private var state: State = .idle

    init(
        participants: [any ApplicationUpdateReadinessParticipant],
        eventSink: any ApplicationUpdateReadinessEventSinking = NoOpApplicationUpdateReadinessEventSink()
    ) {
        self.participants = participants.sorted {
            if $0.preparationOrder == $1.preparationOrder {
                return $0.identifier < $1.identifier
            }
            return $0.preparationOrder < $1.preparationOrder
        }
        self.eventSink = eventSink
    }

    func snapshot() -> ApplicationUpdateCoordinatorSnapshot {
        switch state {
        case .idle:
            .init(operation: .idle, reasonCode: nil)
        case .preparingUpdate:
            .init(operation: .preparingUpdate, reasonCode: .updateAlreadyInProgress)
        case .updateReady:
            .init(operation: .updateReady, reasonCode: .updateReady)
        case .recoveringUpdate:
            .init(operation: .recoveringUpdate, reasonCode: .updateLeaseAborted)
        case .deleteAll:
            .init(operation: .deleteAll, reasonCode: .deleteAllInProgress)
        }
    }

    func acquireUpdateLease(
        traceID: String? = nil,
        parentSpanID: String? = nil
    ) async -> ApplicationUpdateReadinessReport {
        let token = UUID()
        let trace = TraceContext(
            traceID: traceID ?? "trace_\(UUID().uuidString.lowercased())",
            rootSpanID: "span_\(UUID().uuidString.lowercased())",
            startedAt: Date()
        )

        switch state {
        case .idle:
            state = .preparingUpdate(token: token, trace: trace)
        case .deleteAll:
            return await blockedReport(reason: .deleteAllInProgress, trace: trace)
        case .preparingUpdate, .updateReady, .recoveringUpdate:
            return await blockedReport(reason: .updateAlreadyInProgress, trace: trace)
        }

        await emit(
            event: "application_update.readiness.started",
            trace: trace,
            spanID: trace.rootSpanID,
            parentSpanID: parentSpanID,
            status: .started,
            reason: .readinessStarted,
            metadata: ["participant_count": String(participants.count)]
        )

        let identifiers = participants.map(\.identifier)
        guard Set(identifiers).count == identifiers.count else {
            state = .idle
            return await degradedReport(
                reason: .invalidParticipantConfiguration,
                blockers: [.init(participantIdentifier: nil, reasonCode: .invalidParticipantConfiguration)],
                trace: trace
            )
        }

        var blockers: [ApplicationUpdateBlocker] = []
        var degraded: [ApplicationUpdateBlocker] = []

        for participant in participants {
            guard !Task.isCancelled else {
                state = .idle
                return await blockedReport(reason: .requestCancelled, trace: trace)
            }
            let assessment = await participant.assessApplicationUpdateReadiness()
            switch assessment.status {
            case .ready:
                continue
            case .blocked:
                blockers.append(.init(
                    participantIdentifier: participant.identifier,
                    reasonCode: assessment.reasonCode
                ))
            case .degraded:
                degraded.append(.init(
                    participantIdentifier: participant.identifier,
                    reasonCode: assessment.reasonCode
                ))
            }
        }

        if !blockers.isEmpty {
            state = .idle
            return await blockedReport(blockers: blockers, trace: trace)
        }
        if !degraded.isEmpty {
            state = .idle
            return await degradedReport(
                reason: degraded[0].reasonCode,
                blockers: degraded,
                trace: trace
            )
        }

        var prepared: [PreparedParticipant] = []
        for participant in participants {
            guard !Task.isCancelled else {
                return await finishFailedPreparation(
                    token: token,
                    trace: trace,
                    initialStatus: .blocked,
                    failure: .init(participantIdentifier: nil, reasonCode: .requestCancelled),
                    prepared: prepared
                )
            }

            let result = await participant.prepareForApplicationUpdate()
            await emit(
                event: "application_update.participant.preparation_completed",
                trace: trace,
                parentSpanID: trace.rootSpanID,
                status: traceStatus(for: result.state),
                reason: result.reasonCode,
                metadata: ["participant": boundedIdentifier(participant.identifier)]
            )

            switch result.state {
            case .blocked:
                return await finishFailedPreparation(
                    token: token,
                    trace: trace,
                    initialStatus: .blocked,
                    failure: .init(
                        participantIdentifier: participant.identifier,
                        reasonCode: result.reasonCode
                    ),
                    prepared: prepared
                )
            case .degraded:
                return await finishFailedPreparation(
                    token: token,
                    trace: trace,
                    initialStatus: .degraded,
                    failure: .init(
                        participantIdentifier: participant.identifier,
                        reasonCode: result.reasonCode
                    ),
                    prepared: prepared
                )
            case .prepared:
                let preparedParticipant = PreparedParticipant(
                    participant: participant,
                    identifier: participant.identifier
                )
                prepared.append(preparedParticipant)
                guard participant.requiredPreparationContracts.isSubset(of: result.fulfilledContracts) else {
                    return await finishFailedPreparation(
                        token: token,
                        trace: trace,
                        initialStatus: .degraded,
                        failure: .init(
                            participantIdentifier: participant.identifier,
                            reasonCode: .preparationContractIncomplete
                        ),
                        prepared: prepared
                    )
                }
            }
        }

        guard isPreparingUpdate(token: token) else {
            return await degradedReport(reason: .preparationFailed, blockers: [], trace: trace)
        }

        state = .updateReady(token: token, trace: trace, participants: prepared)
        await emit(
            event: "application_update.readiness.completed",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: .success,
            reason: .updateReady,
            metadata: ["prepared_count": String(prepared.count)]
        )
        return .init(
            status: .ready,
            blockers: [],
            reasonCodes: [.updateReady],
            preparedParticipantIdentifiers: prepared.map(\.identifier),
            traceID: trace.traceID,
            lease: ApplicationUpdateLease(token: token, coordinator: self)
        )
    }

    func acquireDeleteAllLease() async -> ApplicationDeleteAllLeaseAcquisition {
        let token = UUID()
        let trace = TraceContext(
            traceID: "trace_\(UUID().uuidString.lowercased())",
            rootSpanID: "span_\(UUID().uuidString.lowercased())",
            startedAt: Date()
        )

        switch state {
        case .idle:
            state = .deleteAll(token: token, trace: trace)
            await emit(
                event: "delete_all.lease.acquired",
                trace: trace,
                spanID: trace.rootSpanID,
                parentSpanID: nil,
                status: .success,
                reason: .deleteAllLeaseAcquired
            )
            return .init(
                status: .acquired,
                reasonCode: .deleteAllLeaseAcquired,
                lease: ApplicationDeleteAllLease(token: token, coordinator: self)
            )
        case .deleteAll:
            await emit(
                event: "delete_all.lease.blocked",
                trace: trace,
                spanID: trace.rootSpanID,
                parentSpanID: nil,
                status: .skipped,
                reason: .deleteAllAlreadyInProgress
            )
            return .init(status: .blocked, reasonCode: .deleteAllAlreadyInProgress, lease: nil)
        case .preparingUpdate, .updateReady, .recoveringUpdate:
            await emit(
                event: "delete_all.lease.blocked",
                trace: trace,
                spanID: trace.rootSpanID,
                parentSpanID: nil,
                status: .skipped,
                reason: .deleteAllBlockedByUpdate
            )
            return .init(status: .blocked, reasonCode: .deleteAllBlockedByUpdate, lease: nil)
        }
    }

    fileprivate func releaseUpdateLease(token: UUID) async -> ApplicationUpdateLeaseDisposition {
        guard case let .updateReady(activeToken, trace, prepared) = state, activeToken == token else {
            return .init(state: .notActive, reasonCodes: [.updateLeaseNotActive], preparedParticipantIdentifiers: [])
        }
        state = .idle
        await emit(
            event: "application_update.lease.released",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: .success,
            reason: .updateLeaseReleased,
            metadata: ["prepared_count": String(prepared.count)]
        )
        return .init(
            state: .released,
            reasonCodes: [.updateLeaseReleased],
            preparedParticipantIdentifiers: prepared.map(\.identifier)
        )
    }

    fileprivate func abortUpdateLease(token: UUID) async -> ApplicationUpdateLeaseDisposition {
        guard case let .updateReady(activeToken, trace, prepared) = state, activeToken == token else {
            return .init(state: .notActive, reasonCodes: [.updateLeaseNotActive], preparedParticipantIdentifiers: [])
        }

        state = .recoveringUpdate(token: token, trace: trace, participants: prepared)
        let recoveryFailures = await recover(prepared, trace: trace)
        state = .idle
        let degraded = !recoveryFailures.isEmpty
        let reasonCodes: [ApplicationUpdateReadinessReason] = degraded
            ? [.updateLeaseAborted, .preparationRecoveryIncomplete] + recoveryFailures
            : [.updateLeaseAborted, .preparationRecovered]
        await emit(
            event: "application_update.lease.aborted",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: degraded ? .degraded : .success,
            reason: degraded ? .preparationRecoveryIncomplete : .updateLeaseAborted,
            metadata: ["prepared_count": String(prepared.count)]
        )
        return .init(
            state: degraded ? .degraded : .aborted,
            reasonCodes: unique(reasonCodes),
            preparedParticipantIdentifiers: prepared.map(\.identifier)
        )
    }

    fileprivate func releaseDeleteAllLease(
        token: UUID,
        aborted: Bool
    ) async -> ApplicationDeleteAllLeaseDisposition {
        guard case let .deleteAll(activeToken, trace) = state, activeToken == token else {
            return .init(state: .notActive, reasonCode: .deleteAllLeaseNotActive)
        }
        state = .idle
        let reason: ApplicationUpdateReadinessReason = aborted ? .deleteAllLeaseAborted : .deleteAllLeaseReleased
        await emit(
            event: aborted ? "delete_all.lease.aborted" : "delete_all.lease.released",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: aborted ? .skipped : .success,
            reason: reason
        )
        return .init(state: aborted ? .aborted : .released, reasonCode: reason)
    }

    private func finishFailedPreparation(
        token: UUID,
        trace: TraceContext,
        initialStatus: ApplicationUpdateReadinessStatus,
        failure: ApplicationUpdateBlocker,
        prepared: [PreparedParticipant]
    ) async -> ApplicationUpdateReadinessReport {
        guard isPreparingUpdate(token: token) else {
            return await degradedReport(reason: .preparationFailed, blockers: [failure], trace: trace)
        }
        let recoveryFailures = await recover(prepared, trace: trace)
        state = .idle
        let recovered = recoveryFailures.isEmpty
        let finalStatus: ApplicationUpdateReadinessStatus = recovered ? initialStatus : .degraded
        let recoveryReason: ApplicationUpdateReadinessReason = recovered
            ? .preparationRecovered
            : .preparationRecoveryIncomplete
        let reasons = unique([failure.reasonCode, recoveryReason] + recoveryFailures)
        await emit(
            event: "application_update.readiness.completed",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: finalStatus == .blocked ? .skipped : .degraded,
            reason: recovered ? failure.reasonCode : .preparationRecoveryIncomplete,
            metadata: ["recovered_count": String(prepared.count - recoveryFailures.count)]
        )
        return .init(
            status: finalStatus,
            blockers: [failure],
            reasonCodes: reasons,
            preparedParticipantIdentifiers: [],
            traceID: trace.traceID,
            lease: nil
        )
    }

    private func recover(
        _ prepared: [PreparedParticipant],
        trace: TraceContext
    ) async -> [ApplicationUpdateReadinessReason] {
        var failures: [ApplicationUpdateReadinessReason] = []
        for preparedParticipant in prepared.reversed() {
            let result = await preparedParticipant.participant.recoverAfterApplicationUpdateAbort()
            if !result.recovered {
                failures.append(result.reasonCode)
            }
            await emit(
                event: "application_update.participant.recovered",
                trace: trace,
                parentSpanID: trace.rootSpanID,
                status: result.recovered ? .success : .degraded,
                reason: result.reasonCode,
                metadata: ["participant": boundedIdentifier(preparedParticipant.identifier)]
            )
        }
        return failures
    }

    private func blockedReport(
        reason: ApplicationUpdateReadinessReason,
        trace: TraceContext
    ) async -> ApplicationUpdateReadinessReport {
        await blockedReport(
            blockers: [.init(participantIdentifier: nil, reasonCode: reason)],
            trace: trace
        )
    }

    private func blockedReport(
        blockers: [ApplicationUpdateBlocker],
        trace: TraceContext
    ) async -> ApplicationUpdateReadinessReport {
        let reasons = unique(blockers.map(\.reasonCode))
        await emit(
            event: "application_update.readiness.completed",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: .skipped,
            reason: reasons.first ?? .participantBlocked,
            metadata: ["blocker_count": String(blockers.count)]
        )
        return .init(
            status: .blocked,
            blockers: blockers,
            reasonCodes: reasons,
            preparedParticipantIdentifiers: [],
            traceID: trace.traceID,
            lease: nil
        )
    }

    private func degradedReport(
        reason: ApplicationUpdateReadinessReason,
        blockers: [ApplicationUpdateBlocker],
        trace: TraceContext
    ) async -> ApplicationUpdateReadinessReport {
        await emit(
            event: "application_update.readiness.completed",
            trace: trace,
            parentSpanID: trace.rootSpanID,
            status: .degraded,
            reason: reason,
            metadata: ["blocker_count": String(blockers.count)]
        )
        return .init(
            status: .degraded,
            blockers: blockers,
            reasonCodes: unique([reason] + blockers.map(\.reasonCode)),
            preparedParticipantIdentifiers: [],
            traceID: trace.traceID,
            lease: nil
        )
    }

    private func isPreparingUpdate(token: UUID) -> Bool {
        guard case let .preparingUpdate(activeToken, _) = state else { return false }
        return activeToken == token
    }

    private func traceStatus(
        for state: ApplicationUpdateParticipantPreparationState
    ) -> ApplicationUpdateReadinessTraceStatus {
        switch state {
        case .prepared: .success
        case .blocked: .skipped
        case .degraded: .degraded
        }
    }

    private func unique(
        _ reasons: [ApplicationUpdateReadinessReason]
    ) -> [ApplicationUpdateReadinessReason] {
        var seen: Set<ApplicationUpdateReadinessReason> = []
        return reasons.filter { seen.insert($0).inserted }
    }

    private func boundedIdentifier(_ value: String) -> String {
        String(value.prefix(80))
    }

    private func emit(
        event: String,
        trace: TraceContext,
        spanID: String = "span_\(UUID().uuidString.lowercased())",
        parentSpanID: String?,
        status: ApplicationUpdateReadinessTraceStatus,
        reason: ApplicationUpdateReadinessReason,
        metadata: [String: String] = [:]
    ) async {
        let duration = max(0, Int(Date().timeIntervalSince(trace.startedAt) * 1_000))
        await eventSink.record(.init(
            timestamp: Date(),
            event: event,
            traceID: trace.traceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            component: "application_update_readiness",
            status: status,
            reasonCode: reason.rawValue,
            durationMilliseconds: duration,
            metadata: metadata
        ))
    }
}
