import XCTest
@testable import LokiBrief

private actor ApplicationUpdateReadinessCallLog {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    func snapshot() -> [String] {
        entries
    }
}

private actor ApplicationUpdateReadinessEventRecorder: ApplicationUpdateReadinessEventSinking {
    private var events: [ApplicationUpdateReadinessEvent] = []

    func record(_ event: ApplicationUpdateReadinessEvent) {
        events.append(event)
    }

    func snapshot() -> [ApplicationUpdateReadinessEvent] {
        events
    }
}

private actor ApplicationUpdateReadinessFixtureParticipant: ApplicationUpdateReadinessParticipant {
    nonisolated let identifier: String
    nonisolated let preparationOrder: Int
    nonisolated let requiredPreparationContracts: Set<ApplicationUpdatePreparationContract>

    private let assessment: ApplicationUpdateParticipantAssessment
    private let preparation: ApplicationUpdateParticipantPreparation
    private let recovery: ApplicationUpdateParticipantRecovery
    private let callLog: ApplicationUpdateReadinessCallLog

    init(
        identifier: String,
        preparationOrder: Int,
        requiredPreparationContracts: Set<ApplicationUpdatePreparationContract> = [],
        assessment: ApplicationUpdateParticipantAssessment = .ready,
        preparation: ApplicationUpdateParticipantPreparation = .prepared(fulfilling: []),
        recovery: ApplicationUpdateParticipantRecovery = .recovered,
        callLog: ApplicationUpdateReadinessCallLog
    ) {
        self.identifier = identifier
        self.preparationOrder = preparationOrder
        self.requiredPreparationContracts = requiredPreparationContracts
        self.assessment = assessment
        self.preparation = preparation
        self.recovery = recovery
        self.callLog = callLog
    }

    func assessApplicationUpdateReadiness() async -> ApplicationUpdateParticipantAssessment {
        await callLog.append("assess:\(identifier)")
        return assessment
    }

    func prepareForApplicationUpdate() async -> ApplicationUpdateParticipantPreparation {
        await callLog.append("prepare:\(identifier)")
        return preparation
    }

    func recoverAfterApplicationUpdateAbort() async -> ApplicationUpdateParticipantRecovery {
        await callLog.append("recover:\(identifier)")
        return recovery
    }
}

final class ApplicationUpdateReadinessTests: XCTestCase, @unchecked Sendable {
    func testActiveRunBlocksInstallBeforePreparation() async {
        let calls = ApplicationUpdateReadinessCallLog()
        let activeRun = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "scheduled_briefing",
            preparationOrder: 10,
            assessment: .blocked(.activeWork),
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [activeRun])

        let report = await coordinator.acquireUpdateLease()
        let recordedCalls = await calls.snapshot()
        let operation = await coordinator.snapshot().operation

        XCTAssertEqual(report.status, .blocked)
        XCTAssertNil(report.lease)
        XCTAssertEqual(report.reasonCodes, [.activeWork])
        XCTAssertEqual(report.blockers, [
            .init(participantIdentifier: "scheduled_briefing", reasonCode: .activeWork)
        ])
        XCTAssertEqual(recordedCalls, ["assess:scheduled_briefing"])
        XCTAssertEqual(operation, .idle)
    }

    func testDatabaseCloseAndSaveContractsAreBothRequired() async {
        let calls = ApplicationUpdateReadinessCallLog()
        let database = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "application_databases",
            preparationOrder: 20,
            requiredPreparationContracts: [.saveState, .quiesceAndCloseStoresForTermination],
            preparation: .prepared(fulfilling: [.saveState]),
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [database])

        let report = await coordinator.acquireUpdateLease()
        let recordedCalls = await calls.snapshot()
        let operation = await coordinator.snapshot().operation

        XCTAssertEqual(report.status, .degraded)
        XCTAssertNil(report.lease)
        XCTAssertEqual(report.reasonCodes, [
            .preparationContractIncomplete,
            .preparationRecovered
        ])
        XCTAssertEqual(recordedCalls, [
            "assess:application_databases",
            "prepare:application_databases",
            "recover:application_databases"
        ])
        XCTAssertEqual(operation, .idle)
    }

    func testFailedPrepareRecoversAlreadyPreparedParticipantsInReverseOrder() async {
        let calls = ApplicationUpdateReadinessCallLog()
        let second = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "sqlite_vault",
            preparationOrder: 20,
            preparation: .prepared(fulfilling: [.quiesceAndCloseStoresForTermination]),
            callLog: calls
        )
        let first = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "swiftdata",
            preparationOrder: 10,
            preparation: .prepared(fulfilling: [.saveState, .quiesceAndCloseStoresForTermination]),
            callLog: calls
        )
        let failure = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "scheduler",
            preparationOrder: 30,
            preparation: .degraded(.preparationFailed),
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [second, failure, first]
        )

        let report = await coordinator.acquireUpdateLease()
        let preparationAndRecovery = await calls.snapshot().filter {
            $0.hasPrefix("prepare:") || $0.hasPrefix("recover:")
        }
        let operation = await coordinator.snapshot().operation

        XCTAssertEqual(report.status, .degraded)
        XCTAssertEqual(report.reasonCodes, [.preparationFailed, .preparationRecovered])
        XCTAssertEqual(preparationAndRecovery, [
            "prepare:swiftdata",
            "prepare:sqlite_vault",
            "prepare:scheduler",
            "recover:sqlite_vault",
            "recover:swiftdata"
        ])
        XCTAssertEqual(operation, .idle)
    }

    func testSuccessfulReadinessReturnsLeaseAndReleaseTruth() async throws {
        let calls = ApplicationUpdateReadinessCallLog()
        let database = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "application_databases",
            preparationOrder: 20,
            requiredPreparationContracts: [.saveState, .quiesceAndCloseStoresForTermination],
            preparation: .prepared(fulfilling: [.saveState, .quiesceAndCloseStoresForTermination]),
            callLog: calls
        )
        let scheduler = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "scheduler",
            preparationOrder: 10,
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [database, scheduler]
        )

        let report = await coordinator.acquireUpdateLease()
        let lease = try XCTUnwrap(report.lease)
        let readyOperation = await coordinator.snapshot().operation

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.reasonCodes, [.updateReady])
        XCTAssertEqual(report.preparedParticipantIdentifiers, ["scheduler", "application_databases"])
        XCTAssertEqual(readyOperation, .updateReady)

        let released = await lease.release()
        let releasedOperation = await coordinator.snapshot().operation
        XCTAssertEqual(released.state, .released)
        XCTAssertEqual(released.reasonCodes, [.updateLeaseReleased])
        XCTAssertEqual(releasedOperation, .idle)

        let repeated = await lease.release()
        XCTAssertEqual(repeated.state, .notActive)
        XCTAssertEqual(repeated.reasonCodes, [.updateLeaseNotActive])
    }

    func testDeleteAllIsBlockedWhileUpdateLeaseIsActive() async throws {
        let calls = ApplicationUpdateReadinessCallLog()
        let participant = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "databases",
            preparationOrder: 10,
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [participant])
        let update = await coordinator.acquireUpdateLease()
        let updateLease = try XCTUnwrap(update.lease)

        let deleteAll = await coordinator.acquireDeleteAllLease()

        XCTAssertEqual(deleteAll.status, .blocked)
        XCTAssertEqual(deleteAll.reasonCode, .deleteAllBlockedByUpdate)
        XCTAssertNil(deleteAll.lease)
        _ = await updateLease.abort()
    }

    func testUpdateIsBlockedWhileDeleteAllLeaseIsActive() async throws {
        let calls = ApplicationUpdateReadinessCallLog()
        let participant = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "databases",
            preparationOrder: 10,
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [participant])
        let deleteAll = await coordinator.acquireDeleteAllLease()
        let deleteAllLease = try XCTUnwrap(deleteAll.lease)

        let update = await coordinator.acquireUpdateLease()

        XCTAssertEqual(update.status, .blocked)
        XCTAssertEqual(update.reasonCodes, [.deleteAllInProgress])
        XCTAssertNil(update.lease)

        let release = await deleteAllLease.release()
        let operation = await coordinator.snapshot().operation
        XCTAssertEqual(release, .init(state: .released, reasonCode: .deleteAllLeaseReleased))
        XCTAssertEqual(operation, .idle)
    }

    func testAbortRecoversReadyParticipantsAndReportsRepeatedAbortTruthfully() async throws {
        let calls = ApplicationUpdateReadinessCallLog()
        let first = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "first",
            preparationOrder: 10,
            callLog: calls
        )
        let second = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "second",
            preparationOrder: 20,
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [first, second])
        let report = await coordinator.acquireUpdateLease()
        let lease = try XCTUnwrap(report.lease)

        let aborted = await lease.abort()
        let recoveries = await calls.snapshot().filter { $0.hasPrefix("recover:") }
        let operation = await coordinator.snapshot().operation

        XCTAssertEqual(aborted.state, .aborted)
        XCTAssertEqual(aborted.reasonCodes, [.updateLeaseAborted, .preparationRecovered])
        XCTAssertEqual(recoveries, ["recover:second", "recover:first"])
        XCTAssertEqual(operation, .idle)

        let repeated = await lease.abort()
        XCTAssertEqual(repeated.state, .notActive)
        XCTAssertEqual(repeated.reasonCodes, [.updateLeaseNotActive])
    }

    func testReasonCodesAndTraceLinksAreStableAndPrivacySafe() async throws {
        XCTAssertEqual(
            ApplicationUpdateReadinessReason.activeWork.rawValue,
            "update_install_blocked_active_work"
        )
        XCTAssertEqual(
            ApplicationUpdateReadinessReason.preparationContractIncomplete.rawValue,
            "update_preparation_contract_incomplete"
        )
        XCTAssertEqual(
            ApplicationUpdateReadinessReason.deleteAllBlockedByUpdate.rawValue,
            "delete_all_blocked_update_in_progress"
        )

        let calls = ApplicationUpdateReadinessCallLog()
        let events = ApplicationUpdateReadinessEventRecorder()
        let participant = ApplicationUpdateReadinessFixtureParticipant(
            identifier: "database",
            preparationOrder: 10,
            callLog: calls
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [participant],
            eventSink: events
        )

        let report = await coordinator.acquireUpdateLease()
        let lease = try XCTUnwrap(report.lease)
        _ = await lease.abort()
        let recorded = await events.snapshot()

        XCTAssertFalse(recorded.isEmpty)
        XCTAssertTrue(recorded.allSatisfy { $0.traceID == report.traceID })
        XCTAssertTrue(recorded.allSatisfy { !$0.spanID.isEmpty })
        XCTAssertTrue(recorded.dropFirst().allSatisfy { $0.parentSpanID != nil })
        XCTAssertTrue(recorded.allSatisfy {
            !$0.metadata.keys.contains("credential")
                && !$0.metadata.keys.contains("source_data")
                && !$0.metadata.keys.contains("vault_content")
        })
        XCTAssertEqual(recorded.first?.reasonCode, "update_readiness_started")
        XCTAssertTrue(recorded.contains { $0.reasonCode == "update_install_ready" })
        XCTAssertTrue(recorded.contains { $0.reasonCode == "update_lease_aborted" })
    }
}
