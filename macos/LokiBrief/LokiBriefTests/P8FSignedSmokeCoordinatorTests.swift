import Foundation
import XCTest
@testable import LokiBrief

private actor P8FCoordinatorDisabledFeedClient: FeedRetrieving {
    func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext
    ) async throws -> FeedFetchResult {
        throw FeedFetchFailure(.networkUnavailable)
    }

    func cancelAll() async { }
}

@MainActor
final class P8FSignedSmokeCoordinatorTests: XCTestCase {
    private let fileManager = FileManager.default
    private let executableSHA256 = String(repeating: "a", count: 64)
    private let cdHash = String(repeating: "b", count: 40)
    private let fixtureSHA256 = String(repeating: "c", count: 64)
    private let allowlistSHA256 = String(repeating: "d", count: 64)
    private let authorizationSHA256 = String(repeating: "e", count: 64)
    private let generationSHA256 = String(repeating: "f", count: 64)
    private let modelSHA256 = String(repeating: "1", count: 64)

    func testPrivacyScannerAcceptsTypedEventAndTerminalReceipt()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root,
            traceID:
                "trace_00000000-0000-0000-0000-000000000001"
        )
        let rootEvent = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .run,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                durationMilliseconds: 1,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .run,
                        artifactClassification: .eventChain
                    ),
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .cleanup,
                parentSpanID: rootEvent.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                durationMilliseconds: 1,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .cleanup
                    ),
                timestamp: fixedDate(1)
            )
        )
        let terminalReceipt =
            try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .failed,
                reasonCode: .runFailed,
                startedAt: fixedDate(0),
                completedAt: fixedDate(3),
                applicationIdentity:
                    try P8FSignedSmokeReceiptApplicationIdentity(
                        executableSHA256: executableSHA256,
                        cdHash: cdHash
                    ),
                privacySummary:
                    try P8FSignedSmokePrivacySummary(
                        artifactCount: 5
                    )
            )
        _ = try writer.commitTerminalReceipt(
            terminalReceipt,
            finalEventDraft: P8FSignedSmokeEventDraft(
                event: .run,
                parentSpanID: rootEvent.spanID,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                durationMilliseconds: 1,
                metadata: try P8FSignedSmokeEventMetadata(
                    scenario: .run
                ),
                timestamp: fixedDate(2)
            )
        )

        let summary = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: root
        )

        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.artifactCount, 5)
        XCTAssertEqual(summary.forbiddenFieldCount, 0)
        XCTAssertEqual(summary.forbiddenValueCount, 0)
        XCTAssertEqual(summary.privatePathCount, 0)
    }

    func testPrivacyScannerRejectsCanaryPrivatePathAndForbiddenKey()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        try setPermissions(0o700, on: directory)
        try writeJSONObject(
            [
                "marker":
                    "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY",
            ],
            named: "canary.json",
            in: directory
        )
        try writeJSONObject(
            [
                "artifact_location":
                    ["", "Users", "synthetic", "private-receipt.json"]
                    .joined(separator: "/"),
            ],
            named: "private-path.json",
            in: directory
        )
        try writeJSONObject(
            ["content": "synthetic-redacted"],
            named: "forbidden-key.json",
            in: directory
        )
        try writeJSONObject(
            ["access_token": "synthetic-redacted"],
            named: ".hidden-token.json",
            in: directory
        )

        let summary = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: root
        )

        XCTAssertFalse(summary.passed)
        XCTAssertEqual(summary.artifactCount, 4)
        XCTAssertEqual(summary.forbiddenValueCount, 1)
        XCTAssertEqual(summary.privatePathCount, 1)
        XCTAssertEqual(summary.forbiddenFieldCount, 2)
        XCTAssertEqual(summary.rawContentCount, 1)
        XCTAssertEqual(summary.credentialCount, 1)
    }

    func testPrerequisitesRequireSuccessfulExactPriorEvidence()
        throws
    {
        XCTAssertNoThrow(
            try P8FSignedSmokePrerequisiteValidator.validate(
                .modelAssessment,
                events: []
            )
        )
        assertPrerequisiteMissing(.semanticSourceProof, events: [])

        let degradedQwen = try makeEvent(
            scenario: .qwenEmbedding,
            reasonCode: .modelCapabilityPassed,
            status: .degraded,
            sequence: 1
        )
        assertPrerequisiteMissing(
            .semanticSourceProof,
            events: [degradedQwen]
        )

        let successfulQwen = try makeEvent(
            scenario: .qwenEmbedding,
            reasonCode: .modelCapabilityPassed,
            status: .success,
            sequence: 1
        )
        XCTAssertNoThrow(
            try P8FSignedSmokePrerequisiteValidator.validate(
                .semanticSourceProof,
                events: [successfulQwen]
            )
        )

        let failedPublication = try makeEvent(
            scenario: .successfulPublication,
            reasonCode: .generationPublished,
            status: .failed,
            sequence: 2
        )
        assertPrerequisiteMissing(
            .search,
            events: [failedPublication]
        )
        assertPrerequisiteMissing(
            .hydration,
            events: [failedPublication]
        )

        let successfulPublication = try makeEvent(
            scenario: .successfulPublication,
            reasonCode: .generationPublished,
            status: .success,
            sequence: 2
        )
        XCTAssertNoThrow(
            try P8FSignedSmokePrerequisiteValidator.validate(
                .search,
                events: [successfulPublication]
            )
        )
        XCTAssertNoThrow(
            try P8FSignedSmokePrerequisiteValidator.validate(
                .hydration,
                events: [successfulPublication]
            )
        )
    }

    func testCleanupRequiresEveryExactSuccessfulPrerequisite()
        throws
    {
        let requirements: [
            (
                P8FSignedSmokeScenario,
                P8FSignedSmokeReasonCode
            )
        ] = [
            (.run, .admissionAccepted),
            (.storageIsolation, .storageSelected),
            (.sourceAuthority, .fixtureAccepted),
            (.gemma4, .modelCapabilityPassed),
            (.gptOSS, .modelCapabilityPassed),
            (.qwenEmbedding, .modelCapabilityPassed),
            (
                .visibleVisionRouting,
                .visionRouteDecisionObserved
            ),
            (
                .visibleVisionRouting,
                .visionTransportConfirmed
            ),
            (.roleSeparation, .roleSeparationPassed),
            (
                .webResearchDisabled,
                .webResearchDisabledWithoutKey
            ),
            (
                .cancellation,
                .cancelledBeforePublication
            ),
            (
                .revocation,
                .scopeRevokedBeforePublication
            ),
            (
                .modelProfileDrift,
                .modelProfileDrift
            ),
            (
                .adapterContractDrift,
                .adapterContractDrift
            ),
            (
                .unknownSourceKind,
                .unknownSourceKindRejected
            ),
            (
                .transactionIntegrity,
                .transactionIntegrityFailed
            ),
            (
                .sourceAuthority,
                .sourceScopeAuthorized
            ),
            (.successfulPublication, .generationPublished),
            (.lexicalSearch, .searchPassed),
            (.semanticSearch, .searchPassed),
            (.hybridSearch, .searchPassed),
            (
                .searchNarrowing,
                .searchFilterNarrowed
            ),
            (
                .excludedSourceSearch,
                .excludedSourceFilterEmpty
            ),
            (.restartHydration, .generationPublished),
            (
                .legacyHydration,
                .legacyGenerationPreserved
            ),
            (
                .staleHydration,
                .staleIdentityRejected
            ),
            (
                .malformedHydration,
                .malformedIdentityRejected
            ),
        ]
        let cancelledScenarios: Set<P8FSignedSmokeScenario> = [
            .cancellation,
            .revocation,
            .modelProfileDrift,
        ]
        let requirementEvents = try requirements.enumerated().map {
            try makeEvent(
                scenario: $0.element.0,
                reasonCode: $0.element.1,
                status:
                    cancelledScenarios.contains($0.element.0)
                    ? .cancelled
                    : .success,
                sequence: UInt64($0.offset + 1)
            )
        }
        let includedKinds: Set<SemanticIndexSourceKind> = [
            .brief,
            .schedule,
            .chatMessage,
        ]
        let sourceEvents =
            try SemanticIndexSourceKind.allCases
                .enumerated()
                .map { offset, sourceKind in
                    try makeEvent(
                        scenario: .sourceAuthority,
                        reasonCode:
                            includedKinds.contains(sourceKind)
                            ? .adapterInvoked
                            : .adapterSkipped,
                        status: .success,
                        sequence:
                            UInt64(
                                requirementEvents.count
                                    + offset + 1
                            ),
                        sourceKind: sourceKind
                    )
                }
        XCTAssertEqual(sourceEvents.count, 6)
        XCTAssertEqual(
            Set(sourceEvents.compactMap {
                $0.metadata.sourceKind
            }),
            Set(SemanticIndexSourceKind.allCases)
        )
        let providerEvents =
            try P8FSignedSmokeApprovedModel.allCases
                .enumerated()
                .map { offset, model in
                    try makeProviderCorrelationEvent(
                        model: model,
                        sequence:
                            UInt64(
                                requirementEvents.count
                                    + sourceEvents.count
                                    + offset + 1
                            )
                    )
                }
        let events =
            requirementEvents + sourceEvents + providerEvents

        XCTAssertNoThrow(
            try P8FSignedSmokePrerequisiteValidator.validate(
                .cleanup,
                events: events
            )
        )
        assertPrerequisiteMissing(
            .cleanup,
            events:
                Array(requirementEvents.dropLast())
                + sourceEvents + providerEvents
        )
        assertPrerequisiteMissing(
            .cleanup,
            events:
                requirementEvents
                + Array(sourceEvents.dropLast())
                + providerEvents
        )
        assertPrerequisiteMissing(
            .cleanup,
            events:
                requirementEvents + sourceEvents
                + Array(providerEvents.dropLast())
        )

        var wrongReasonEvents = events
        let gemmaIndex = try XCTUnwrap(
            wrongReasonEvents.firstIndex {
                $0.metadata.scenario == .gemma4
            }
        )
        let gemmaSequence =
            wrongReasonEvents[gemmaIndex].sequence
        wrongReasonEvents[gemmaIndex] = try makeEvent(
            scenario: .gemma4,
            reasonCode: .modelCapabilityFailed,
            status: .success,
            sequence: gemmaSequence
        )
        assertPrerequisiteMissing(
            .cleanup,
            events: wrongReasonEvents
        )

        for scenario in cancelledScenarios {
            let index = try XCTUnwrap(
                requirementEvents.firstIndex {
                    $0.metadata.scenario == scenario
                }
            )
            for wrongStatus in [
                P8FSignedSmokeStatus.success,
                .skipped,
            ] {
                var wrongStatusEvents = events
                wrongStatusEvents[index] = try makeEvent(
                    scenario: scenario,
                    reasonCode:
                        requirementEvents[index].reasonCode,
                    status: wrongStatus,
                    sequence:
                        requirementEvents[index].sequence
                )
                assertPrerequisiteMissing(
                    .cleanup,
                    events: wrongStatusEvents
                )
            }
        }

        let providerStartIndex =
            requirementEvents.count + sourceEvents.count
        let cancelledModel = try XCTUnwrap(
            providerEvents.first?.metadata.model
        )
        var cancelledProviderEvents = events
        cancelledProviderEvents[providerStartIndex] =
            try makeProviderCorrelationEvent(
                model: cancelledModel,
                sequence:
                    providerEvents[0].sequence,
                outcome: .cancelled
            )
        assertPrerequisiteMissing(
            .cleanup,
            events: cancelledProviderEvents
        )

        var skippedProviderEvents = events
        skippedProviderEvents[providerStartIndex] =
            try makeProviderCorrelationEvent(
                model: cancelledModel,
                sequence:
                    providerEvents[0].sequence,
                outcome: .cancelled,
                statusOverride: .skipped
            )
        assertPrerequisiteMissing(
            .cleanup,
            events: skippedProviderEvents
        )
    }

    func testOrdinaryArgumentsDoNotEnterSignedSmokeBootstrap()
        throws
    {
        XCTAssertFalse(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: [
                    "/Applications/LokiBrief.app/Contents/MacOS/LokiBrief",
                    "--ordinary-startup",
                ]
            )
        )
    }

    func testAtomicTerminalStatesMapToDistinctReceiptStatuses() {
        XCTAssertEqual(
            P8FSignedSmokeCoordinator.receiptStatus(
                forAtomicState: .published
            ),
            .success
        )
        XCTAssertEqual(
            P8FSignedSmokeCoordinator.receiptStatus(
                forAtomicState: .rejected
            ),
            .failed
        )
        XCTAssertEqual(
            P8FSignedSmokeCoordinator.receiptStatus(
                forAtomicState: .failed
            ),
            .failed
        )
        XCTAssertEqual(
            P8FSignedSmokeCoordinator.receiptStatus(
                forAtomicState: .cancelled
            ),
            .cancelled
        )
    }

    func testProviderOutcomesMapToExactReceiptStatusAndReason() {
        XCTAssertEqual(
            P8FSignedSmokeCoordinator
                .providerReceiptClassification(for: .succeeded),
            .init(
                status: .success,
                reasonCode: .providerTransportSucceeded
            )
        )
        XCTAssertEqual(
            P8FSignedSmokeCoordinator
                .providerReceiptClassification(for: .failed),
            .init(
                status: .failed,
                reasonCode: .providerTransportFailed
            )
        )
        XCTAssertEqual(
            P8FSignedSmokeCoordinator
                .providerReceiptClassification(for: .cancelled),
            .init(
                status: .cancelled,
                reasonCode: .providerTransportCancelled
            )
        )
    }

    func testKnownCancellationErrorsClassifyAsCancelled() {
        let cancellationErrors: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            OllamaFailure(.requestCancelled),
            OllamaChatFailure(.requestCancelled),
            OllamaEmbeddingFailure(.requestCancelled),
            OllamaWebResearchFailure(.requestCancelled),
            VisionAttachmentFailure(.cancelled),
            SemanticIndexFailureCode.cancelled,
        ]
        for error in cancellationErrors {
            XCTAssertEqual(
                P8FSignedSmokeCoordinator.classify(error),
                .cancelled
            )
        }
        XCTAssertEqual(
            P8FSignedSmokeCoordinator.classify(
                URLError(.timedOut)
            ),
            .failed(.semanticBuildFailed)
        )
    }

    func testTaskCancellationDoesNotMaskTypedFailureClassification()
        async
    {
        for failure: P8FSignedSmokeCoordinatorFailure in [
            .cleanupFailed,
            .privacyFailed,
            .modelRoleFailed,
        ] {
            let (stream, continuation) =
                AsyncStream<Void>.makeStream()
            let task = Task {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                return P8FSignedSmokeCoordinator.classify(failure)
            }
            task.cancel()
            continuation.yield(())
            continuation.finish()

            let result = await task.value
            XCTAssertEqual(result, .failed(failure))
        }

        let cancellation = Task {
            do {
                try Task.checkCancellation()
                return P8FSignedSmokeExecutionResult.succeeded
            } catch {
                return P8FSignedSmokeCoordinator.classify(error)
            }
        }
        cancellation.cancel()
        let cancellationResult = await cancellation.value
        XCTAssertEqual(cancellationResult, .cancelled)
    }

    func testContainmentSuccessDoesNotOverwritePrimaryCancellation()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try activateProviderCorrelationRecorder(
            for: fixture
        )

        let controlPlanData = try Data(
            contentsOf: fixture.controlPlanURL
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                P8FSignedSmokeControlPlan.self,
                from: controlPlanData
            ).modelIdentifier,
            fixture.hostileCanary
        )

        let coordinator = P8FSignedSmokeCoordinator(
            bootstrap: fixture.bootstrap,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()
        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .cancelled)
        var writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(writer.events.count, 6)
        XCTAssertEqual(
            writer.events.map(\.event),
            [
                .run,
                .admission,
                .storageIsolation,
                .run,
                .cleanup,
                .run,
            ]
        )
        XCTAssertEqual(
            writer.events.map(\.status),
            [
                .started,
                .success,
                .success,
                .started,
                .success,
                .cancelled,
            ]
        )
        XCTAssertEqual(
            writer.events.map(\.reasonCode),
            [
                .runStarted,
                .admissionAccepted,
                .storageSelected,
                .runCancellationObserved,
                .cleanupPassed,
                .runCancelled,
            ]
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .success
                    && $0.reasonCode == .cleanupPassed
            }.count,
            1
        )
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .cancelled)
        XCTAssertEqual(terminal.reasonCode, .runCancelled)
        XCTAssertEqual(terminal.cleanupPassed, true)
        XCTAssertNotNil(writer.diagnosticManifestReceipt)
        XCTAssertNotNil(terminal.artifactLedger)
        XCTAssertEqual(try terminalReceiptFileCount(in: fixture.root), 1)

        let finalPrivacy = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: fixture.root
        )
        XCTAssertTrue(finalPrivacy.passed)
        XCTAssertEqual(
            finalPrivacy.artifactCount,
            writer.events.count + 2
        )
        XCTAssertEqual(finalPrivacy.forbiddenFieldCount, 0)
        XCTAssertEqual(finalPrivacy.forbiddenValueCount, 0)
        XCTAssertEqual(finalPrivacy.rawVectorCount, 0)
        XCTAssertEqual(finalPrivacy.rawContentCount, 0)
        XCTAssertEqual(finalPrivacy.rawPromptCount, 0)
        XCTAssertEqual(finalPrivacy.rawResponseCount, 0)
        XCTAssertEqual(finalPrivacy.hiddenReasoningCount, 0)
        XCTAssertEqual(finalPrivacy.privatePathCount, 0)
        XCTAssertEqual(finalPrivacy.credentialCount, 0)

        writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(writer.terminalReceipt?.status, terminal.status)
        XCTAssertNotNil(writer.terminalReceipt?.artifactLedger)
        XCTAssertThrowsError(
            try writer.writeTerminalReceipt(terminal)
        ) { error in
            XCTAssertEqual(
                error as? P8FSignedSmokeReceiptStoreFailure,
                .terminalReceiptAlreadyWritten
            )
        }
    }

    func testCancellationAfterFixtureCreationUsesExactFixtureCleanupPackage()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try activateProviderCorrelationRecorder(
            for: fixture
        )
        let controlDirectory = fixture.root.appendingPathComponent(
            P8FSignedSmokeFixtureSeeder.controlDirectoryName,
            isDirectory: true
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: controlDirectory.path)
        )

        var checkpointObserved = false
        var controlTreeExistedAtCheckpoint = false
        let hooks = try P8FSignedSmokeCoordinatorXCTestHooks.make(
            postFixtureCleanupPackageInstallation: {
                checkpointObserved = true
                controlTreeExistedAtCheckpoint =
                    self.fileManager.fileExists(
                        atPath: controlDirectory.path
                    )
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        let coordinator = try P8FSignedSmokeCoordinator.makeForXCTest(
            bootstrap: fixture.bootstrap,
            hooks: hooks,
            providerEvidenceRun: providerEvidenceRun
        )
        let execution = Task {
            await coordinator.execute(model: fixture.model)
        }

        let result = await execution.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertTrue(checkpointObserved)
        XCTAssertTrue(controlTreeExistedAtCheckpoint)
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(
            fileManager.fileExists(atPath: controlDirectory.path)
        )
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.map(\.event),
            [
                .run,
                .admission,
                .storageIsolation,
                .run,
                .cleanup,
                .run,
            ]
        )
        XCTAssertEqual(
            writer.events.map(\.reasonCode),
            [
                .runStarted,
                .admissionAccepted,
                .storageSelected,
                .runCancellationObserved,
                .cleanupPassed,
                .runCancelled,
            ]
        )
        XCTAssertFalse(writer.events.contains {
            $0.event == .fixture || $0.event == .network
        })
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .cancelled)
        XCTAssertEqual(terminal.reasonCode, .runCancelled)
        XCTAssertEqual(terminal.cleanupPassed, true)
        let providerState = recorder.stateSnapshot()
        XCTAssertEqual(providerState.pendingRequestCount, 0)
        XCTAssertEqual(providerState.observationCount, 0)
    }

    func testContainmentFailureOverridesPrimaryCancellationWithExactFailure()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try activateProviderCorrelationRecorder(
            for: fixture
        )

        let hostileControlDirectory = fixture.root
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.controlDirectoryName,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: hostileControlDirectory,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        try setPermissions(0o755, on: hostileControlDirectory)

        let coordinator = P8FSignedSmokeCoordinator(
            bootstrap: fixture.bootstrap,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()
        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .failed(.cleanupFailed))
        var writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(writer.events.count, 6)
        XCTAssertEqual(
            writer.events.map(\.event),
            [
                .run,
                .admission,
                .storageIsolation,
                .run,
                .cleanup,
                .run,
            ]
        )
        XCTAssertEqual(
            writer.events.map(\.status),
            [
                .started,
                .success,
                .success,
                .started,
                .failed,
                .failed,
            ]
        )
        XCTAssertEqual(
            writer.events.map(\.reasonCode),
            [
                .runStarted,
                .admissionAccepted,
                .storageSelected,
                .runCancellationObserved,
                .cleanupFailed,
                .cleanupFailed,
            ]
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .failed
                    && $0.reasonCode == .cleanupFailed
            }.count,
            1
        )
        XCTAssertFalse(
            writer.events.contains {
                $0.event == .cleanup && $0.status == .success
            }
        )
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reasonCode, .cleanupFailed)
        XCTAssertEqual(writer.finalEventSHA256?.count, 64)
        XCTAssertEqual(try terminalReceiptFileCount(in: fixture.root), 1)

        writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(writer.terminalReceipt, terminal)
        XCTAssertEqual(writer.events.last?.event, .run)
        XCTAssertEqual(writer.events.last?.status, .failed)
        XCTAssertEqual(
            writer.events.last?.reasonCode,
            .cleanupFailed
        )
    }

    func testPendingProviderCorrelationPreventsCleanCancellationTerminal()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                fixture.bootstrap.applicationIdentity
                    .executableSHA256
        )
        XCTAssertNotNil(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: UUID(),
            requestTraceMaterial:
                "synthetic-pending-correlation"
        ))
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            1
        )

        let coordinator = P8FSignedSmokeCoordinator(
            bootstrap: fixture.bootstrap,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()

        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .failed(.cleanupFailed))
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .failed
                    && $0.reasonCode == .cleanupFailed
            }.count,
            1
        )
        XCTAssertFalse(writer.events.contains {
            $0.event == .cleanup && $0.status == .success
        })
        XCTAssertFalse(writer.events.contains {
            $0.event == .network
        })
        XCTAssertTrue(writer.events.allSatisfy {
            $0.metadata.providerRequestIdentifierSHA256 == nil
                && $0.metadata.providerRequestTraceSHA256 == nil
        })
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reasonCode, .cleanupFailed)
        XCTAssertNil(terminal.cleanupPassed)
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            1
        )
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            1
        )
    }

    func testInactiveProviderCorrelationPreventsCleanCancellationTerminal()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let initialState = recorder.stateSnapshot()
        XCTAssertFalse(initialState.isActive)
        XCTAssertEqual(initialState.pendingRequestCount, 0)

        let coordinator = P8FSignedSmokeCoordinator(
            bootstrap: fixture.bootstrap
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()

        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .failed(.cleanupFailed))
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .failed
                    && $0.reasonCode == .cleanupFailed
            }.count,
            1
        )
        XCTAssertFalse(writer.events.contains {
            $0.event == .cleanup && $0.status == .success
        })
        XCTAssertFalse(writer.events.contains {
            $0.event == .network
        })
        XCTAssertTrue(writer.events.allSatisfy {
            $0.metadata.providerRequestIdentifierSHA256 == nil
                && $0.metadata.providerRequestTraceSHA256 == nil
        })
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reasonCode, .cleanupFailed)
        XCTAssertNil(terminal.cleanupPassed)
        let finalState = recorder.stateSnapshot()
        XCTAssertFalse(finalState.isActive)
        XCTAssertEqual(finalState.pendingRequestCount, 0)
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            1
        )
    }

    func testMismatchedCompletedProviderObservationPreventsCleanCancellation()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let fixture = try makeCancellationExecutionFixture(
            modelIdentifier:
                P8FSignedSmokeApprovedModel.gptOSS.rawValue
        )
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "9", count: 64)
        )
        let token = try XCTUnwrap(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: UUID(),
            requestTraceMaterial:
                "synthetic-mismatched-completed-observation"
        ))
        XCTAssertTrue(recorder.complete(
            token,
            outcome: .cancelled
        ))
        let observationState = recorder.stateSnapshot()
        XCTAssertEqual(observationState.pendingRequestCount, 0)
        XCTAssertEqual(observationState.observationCount, 1)

        let coordinator = P8FSignedSmokeCoordinator(
            bootstrap: fixture.bootstrap,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()

        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .failed(.cleanupFailed))
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .failed
                    && $0.reasonCode == .cleanupFailed
            }.count,
            1
        )
        XCTAssertFalse(writer.events.contains {
            $0.event == .network
        })
        XCTAssertTrue(writer.events.allSatisfy {
            $0.metadata.providerRequestIdentifierSHA256 == nil
                && $0.metadata.providerRequestTraceSHA256 == nil
        })
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reasonCode, .cleanupFailed)
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            1
        )
    }

    func testProviderEvidenceAppendFailurePreventsCleanCancellation()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let fixture = try makeCancellationExecutionFixture(
            modelIdentifier:
                P8FSignedSmokeApprovedModel.gptOSS.rawValue
        )
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try activateProviderCorrelationRecorder(
            for: fixture
        )
        let token = try XCTUnwrap(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: UUID(),
            requestTraceMaterial:
                "synthetic-evidence-append-failure"
        ))
        XCTAssertTrue(recorder.complete(
            token,
            outcome: .cancelled
        ))
        var appendAttempted = false
        let hooks = try P8FSignedSmokeCoordinatorXCTestHooks.make(
            providerCorrelationEvidenceAppend: {
                appendAttempted = true
                throw P8FSignedSmokeCoordinatorFailure.receiptFailed
            }
        )
        let coordinator = try P8FSignedSmokeCoordinator.makeForXCTest(
            bootstrap: fixture.bootstrap,
            hooks: hooks,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()

        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertTrue(appendAttempted)
        XCTAssertEqual(result, .failed(.receiptFailed))
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertFalse(writer.events.contains {
            $0.event == .cleanup
        })
        XCTAssertFalse(writer.events.contains {
            $0.event == .network
        })
        XCTAssertTrue(writer.events.allSatisfy {
            $0.metadata.providerRequestIdentifierSHA256 == nil
                && $0.metadata.providerRequestTraceSHA256 == nil
        })
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(
            terminal.reasonCode,
            .receiptPersistenceFailed
        )
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            1
        )
    }

    func testPrivacyFailureAfterCancellationPreservesCausalEventAndExactFailure()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let providerEvidenceRun = try activateProviderCorrelationRecorder(
            for: fixture
        )
        let canaryData = try JSONSerialization.data(
            withJSONObject: [
                "content":
                    "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY",
            ],
            options: [.sortedKeys]
        )
        XCTAssertFalse(
            try P8FSignedSmokePrivacyScanner
                .scanEncodedArtifact(canaryData)
                .passed
        )
        var injected = false
        let hooks = try P8FSignedSmokeCoordinatorXCTestHooks.make(
            postCancellationContainment: {
                injected = true
                return canaryData
            }
        )
        let coordinator = try P8FSignedSmokeCoordinator.makeForXCTest(
            bootstrap: fixture.bootstrap,
            hooks: hooks,
            providerEvidenceRun: providerEvidenceRun
        )
        let task = Task {
            await coordinator.execute(model: fixture.model)
        }
        task.cancel()

        let result = await task.value
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertEqual(result, .failed(.privacyFailed))
        XCTAssertTrue(injected)
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            1
        )
        let terminalURL = fixture.root
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout.directoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .terminalReceiptFileName,
                isDirectory: false
            )
        let terminalJSON = try String(
            decoding: Data(contentsOf: terminalURL),
            as: UTF8.self
        )
        XCTAssertTrue(terminalJSON.contains(#""status":"failed""#))
        XCTAssertTrue(
            terminalJSON.contains(
                #""reason_code":"p8f_smoke_privacy_failed""#
            )
        )
        XCTAssertFalse(
            terminalJSON.contains(#""status":"cancelled""#)
        )

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .run
                    && $0.status == .started
                    && $0.reasonCode
                        == .runCancellationObserved
            }.count,
            1
        )
        XCTAssertEqual(
            writer.events.filter {
                $0.event == .cleanup
                    && $0.status == .success
                    && $0.reasonCode == .cleanupPassed
            }.count,
            1
        )
        XCTAssertEqual(writer.events.last?.event, .run)
        XCTAssertEqual(writer.events.last?.status, .failed)
        XCTAssertEqual(
            writer.events.last?.reasonCode,
            .privacyFailed
        )
        let terminal = try XCTUnwrap(writer.terminalReceipt)
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reasonCode, .privacyFailed)
        XCTAssertFalse(terminal.privacySummary.passed)
    }

    func testFabricatedSuccessClaimsNeverReachTerminalCommitHook()
        async throws
    {
        let fixture = try makeCancellationExecutionFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: fixture.root
        )
        let rootEvent = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .run,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                durationMilliseconds: 1,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .run,
                        artifactClassification: .eventChain
                    ),
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .cleanup,
                parentSpanID: rootEvent.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                durationMilliseconds: 1,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .cleanup
                    ),
                timestamp: fixedDate(1)
            )
        )
        let terminal =
            try P8FSignedSmokeTerminalReceipt(
                scenario: .cleanup,
                status: .success,
                reasonCode: .runCompleted,
                startedAt: fixedDate(0),
                completedAt: fixedDate(3),
                applicationIdentity:
                    fixture.bootstrap.applicationIdentity,
                admissionAccepted: true,
                fixtureAccepted: true,
                fixtureManifestSHA256: fixtureSHA256,
                sourceAllowlistSHA256: allowlistSHA256,
                authorizationReceiptIdentifierSHA256:
                    authorizationSHA256,
                semanticOutcomeState: .published,
                generationIdentifierSHA256:
                    generationSHA256,
                sourceCounters:
                    try P8FSignedSmokeCounters(
                        adapterInvocations: 3,
                        recordsRead: 4,
                        recordsAccepted: 4,
                        recordsRejected: 0,
                        preparedRecords: 4,
                        chunks: 4,
                        embeddingRequests: 4,
                        embeddingsAccepted: 4,
                        indexWrites: 4,
                        resultCount: 2,
                        leakageCanaryHits: 0
                    ),
                model: .qwenEmbedding,
                modelDigestSHA256: modelSHA256,
                modelAssessmentStatus: .success,
                searchMode: .hybrid,
                searchPassed: true,
                hydrationPassed: true,
                cleanupPassed: true,
                privacySummary:
                    try P8FSignedSmokePrivacySummary(
                        artifactCount: 5
                    )
            )
        var hookInvoked = false
        let hooks = try P8FSignedSmokeCoordinatorXCTestHooks.make(
            postDiagnosticManifestCommit: {
                hookInvoked = true
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        let coordinator = try P8FSignedSmokeCoordinator.makeForXCTest(
            bootstrap: fixture.bootstrap,
            hooks: hooks
        )
        let publicationTask = Task { @MainActor in
            try coordinator.publishSuccessfulTerminal(
                terminal,
                writer: writer
            )
            return Task.isCancelled
        }

        do {
            _ = try await publicationTask.value
            XCTFail("fabricated terminal claims unexpectedly committed")
        } catch {
            XCTAssertEqual(
                error as? P8FSignedSmokeReceiptStoreFailure,
                .terminalReceiptInvalid
            )
        }
        await fixture.model.shutdownForApplicationTermination()

        XCTAssertFalse(hookInvoked)
        XCTAssertNil(writer.diagnosticManifestReceipt)
        XCTAssertNil(writer.terminalReceipt)
        XCTAssertEqual(
            try terminalReceiptFileCount(in: fixture.root),
            0
        )
        let receiptDirectory = fixture.root.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
        XCTAssertFalse(fileManager.fileExists(
            atPath: receiptDirectory.appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .diagnosticManifestFileName
            ).path
        ))
    }

    private func makeEvent(
        scenario: P8FSignedSmokeScenario,
        reasonCode: P8FSignedSmokeReasonCode,
        status: P8FSignedSmokeStatus,
        sequence: UInt64,
        sourceKind: SemanticIndexSourceKind? = nil
    ) throws -> P8FSignedSmokeEvent {
        P8FSignedSmokeEvent(
            schemaVersion:
                P8FSignedSmokeEvent.currentSchemaVersion,
            sequence: sequence,
            timestamp: fixedDate(TimeInterval(sequence)),
            event: eventName(
                for: scenario,
                reasonCode: reasonCode,
                sourceKind: sourceKind
            ),
            traceID:
                "trace_00000000-0000-0000-0000-000000000001",
            spanID:
                "span_00000000-0000-0000-0000-\(String(format: "%012llu", sequence))",
            parentSpanID: nil,
            component: component(
                for: scenario,
                sourceKind: sourceKind
            ),
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: 1,
            metadata:
                try P8FSignedSmokeEventMetadata(
                    scenario: scenario,
                    sourceKind: sourceKind
                ),
            previousEventSHA256: nil
        )
    }

    private func makeProviderCorrelationEvent(
        model: P8FSignedSmokeApprovedModel,
        sequence: UInt64,
        outcome: P8FProviderRequestOutcome = .succeeded,
        statusOverride: P8FSignedSmokeStatus? = nil
    ) throws -> P8FSignedSmokeEvent {
        let startedAt =
            fixedDate(TimeInterval(sequence))
        let endedAt =
            startedAt.addingTimeInterval(0.001)
        let classification =
            P8FSignedSmokeCoordinator
                .providerReceiptClassification(for: outcome)
        return P8FSignedSmokeEvent(
            schemaVersion:
                P8FSignedSmokeEvent.currentSchemaVersion,
            sequence: sequence,
            timestamp: endedAt,
            event: .network,
            traceID:
                "trace_00000000-0000-0000-0000-000000000001",
            spanID:
                "span_00000000-0000-0000-0000-\(String(format: "%012llu", sequence))",
            parentSpanID: nil,
            component: .modelProvider,
            status: statusOverride ?? classification.status,
            reasonCode: classification.reasonCode,
            durationMilliseconds: 1,
            metadata:
                try P8FSignedSmokeEventMetadata(
                    scenario: scenario(for: model),
                    model: model,
                    endpointClassification:
                        .ollamaModelIPv4Loopback,
                    artifactSHA256:
                        String(repeating: "2", count: 64),
                    processIdentifier: 42,
                    executableSHA256: executableSHA256,
                    providerRequestTraceSHA256:
                        String(
                            repeating: "3",
                            count: 64
                        ),
                    providerRequestIdentifierSHA256:
                        P8FSignedSmokeDigest.sha256(
                            "request-\(sequence)"
                        ),
                    providerKind:
                        model == .qwenEmbedding
                        ? .embedding
                        : .chat,
                    providerOperationKind:
                        model == .qwenEmbedding
                        ? .embedding
                        : .chatStream,
                    providerOutcome: outcome,
                    providerIntervalStartedAt:
                        startedAt,
                    providerIntervalEndedAt: endedAt,
                    providerIntervalDurationMilliseconds: 1
                ),
            previousEventSHA256: nil
        )
    }

    private func scenario(
        for model: P8FSignedSmokeApprovedModel
    ) -> P8FSignedSmokeScenario {
        switch model {
        case .gemma4:
            return .gemma4
        case .gptOSS:
            return .gptOSS
        case .qwenEmbedding:
            return .qwenEmbedding
        }
    }

    private func eventName(
        for scenario: P8FSignedSmokeScenario,
        reasonCode: P8FSignedSmokeReasonCode,
        sourceKind: SemanticIndexSourceKind?
    ) -> P8FSignedSmokeEventName {
        if sourceKind != nil {
            return .sourceAdapter
        }
        switch scenario {
        case .run where reasonCode == .admissionAccepted:
            return .admission
        case .storageIsolation:
            return .storageIsolation
        case .sourceAuthority
            where reasonCode == .fixtureAccepted:
            return .fixture
        case .sourceAuthority:
            return .sourceAuthority
        case .gemma4, .gptOSS, .qwenEmbedding,
             .roleSeparation, .visibleVisionRouting:
            return .modelCapability
        case .webResearchDisabled:
            return .network
        case .lexicalSearch, .semanticSearch,
             .hybridSearch, .searchNarrowing,
             .excludedSourceSearch:
            return .search
        case .successfulPublication, .restartHydration,
             .legacyHydration, .staleHydration,
             .malformedHydration, .cancellation,
             .revocation, .modelProfileDrift,
             .adapterContractDrift, .unknownSourceKind,
             .transactionIntegrity:
            return .generation
        default:
            return .run
        }
    }

    private func component(
        for scenario: P8FSignedSmokeScenario,
        sourceKind: SemanticIndexSourceKind?
    ) -> P8FSignedSmokeComponent {
        if sourceKind != nil {
            return .semanticSourceAuthority
        }
        switch scenario {
        case .storageIsolation:
            return .persistence
        case .sourceAuthority:
            return .semanticSourceAuthority
        case .gemma4, .gptOSS, .qwenEmbedding,
             .roleSeparation, .visibleVisionRouting:
            return .modelProvider
        case .webResearchDisabled:
            return .networkGuard
        case .lexicalSearch, .semanticSearch,
             .hybridSearch, .searchNarrowing,
             .excludedSourceSearch:
            return .retrieval
        case .successfulPublication, .restartHydration,
             .legacyHydration, .staleHydration,
             .malformedHydration, .cancellation,
             .revocation, .modelProfileDrift,
             .adapterContractDrift, .unknownSourceKind,
             .transactionIntegrity:
            return .semanticIndex
        default:
            return .runner
        }
    }

    private func assertPrerequisiteMissing(
        _ scenario: P8FSignedSmokeControlScenario,
        events: [P8FSignedSmokeEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try P8FSignedSmokePrerequisiteValidator.validate(
                scenario,
                events: events
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? P8FSignedSmokeCoordinatorFailure,
                .prerequisiteMissing,
                file: file,
                line: line
            )
        }
    }

    private func makeIsolatedRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-p8f-coordinator-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        try setPermissions(0o700, on: root)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private struct CancellationExecutionFixture {
        let root: URL
        let controlPlanURL: URL
        let hostileCanary: String
        let bootstrap: P8FSignedSmokeBootstrap
        let model: AppModel
    }

    private func makeCancellationExecutionFixture(
        modelIdentifier: String? = nil
    )
        throws -> CancellationExecutionFixture
    {
        let root = try makeIsolatedRoot()
        do {
            let vaultDirectory = root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
            try fileManager.createDirectory(
                at: vaultDirectory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: NSNumber(value: 0o700),
                ]
            )
            try setPermissions(
                0o700,
                on: root.appendingPathComponent(
                    "Vault",
                    isDirectory: true
                )
            )
            try setPermissions(0o700, on: vaultDirectory)
            let requiredFiles = [
                root.appendingPathComponent("LokiBrief-v1.store"),
                vaultDirectory.appendingPathComponent(
                    "loki-vault.sqlite3"
                ),
            ]
            for URL in requiredFiles {
                guard fileManager.createFile(
                    atPath: URL.path,
                    contents: Data()
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try setPermissions(0o600, on: URL)
            }

            let hostileCanary = [
                "", "Users", "private",
                "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY_token_prompt_response_vector_fixture_image_bytes_hidden_reasoning",
            ].joined(separator: "/")
            let plan = P8FSignedSmokeControlPlan(
                runIdentifier:
                    "p8f-cancellation-\(UUID().uuidString.lowercased())",
                scenario: .modelAssessment,
                expectedFixtureManifestSHA256:
                    P8FSignedSmokeFixtureManifest
                        .expectedCanonicalSHA256,
                modelIdentifier:
                    modelIdentifier ?? hostileCanary,
                modelDigest: modelSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let controlPlanURL = root.appendingPathComponent(
                P8FSignedSmokeAdmissionResolver.controlPlanFileName
            )
            try encoder.encode(plan).write(
                to: controlPlanURL,
                options: .atomic
            )
            try setPermissions(0o600, on: controlPlanURL)

            let approvedRoot = root.deletingLastPathComponent()
            let pathPolicy = LokiLaunchStoragePathPolicy(
                approvedTemporaryRoots: [approvedRoot],
                productionApplicationSupportRoot:
                    approvedRoot.appendingPathComponent(
                        "production-application-support",
                        isDirectory: true
                    ),
                recoveryRoots: [
                    approvedRoot.appendingPathComponent(
                        "production-recovery",
                        isDirectory: true
                    ),
                ]
            )
            let receiptIdentity =
                try P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                )
            let bootstrap = try XCTUnwrap(
                P8FSignedSmokeBootstrap.resolveForXCTest(
                arguments: [
                    "LokiBrief",
                    P8FSignedSmokeAdmissionResolver.controlSentinel,
                    LokiLaunchStorageResolver.signedSmokeSentinel,
                    LokiLaunchStorageResolver.isolatedRootArgument,
                    root.path,
                ],
                environment: [:],
                simulateXCTestRejection: false,
                applicationIdentity: .required,
                capabilities: [.p8fControlV1],
                pathPolicy: pathPolicy,
                receiptIdentity: receiptIdentity,
                fileManager: fileManager
                )
            )

            let model = try AppModel.makeAdmittedSignedSmoke(
                bootstrap.admission,
                fileManager: fileManager
            )
            return .init(
                root: root,
                controlPlanURL: controlPlanURL,
                hostileCanary: hostileCanary,
                bootstrap: bootstrap,
                model: model
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func terminalReceiptFileCount(in root: URL) throws -> Int {
        let directory = root.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter {
                $0 == P8FSignedSmokeReceiptLayout
                    .terminalReceiptFileName
            }
            .count
    }

    private func activateProviderCorrelationRecorder(
        for fixture: CancellationExecutionFixture
    ) throws -> P8FProviderRequestEvidenceRun {
        try P8FProviderRequestCorrelationRecorder.shared.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                fixture.bootstrap.applicationIdentity
                    .executableSHA256,
            runIdentifier:
                fixture.bootstrap.admission.controlPlan.runIdentifier
        )
    }

    private func writeJSONObject(
        _ object: [String: Any],
        named name: String,
        in directory: URL
    ) throws {
        let url = directory.appendingPathComponent(name)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(to: url)
        try setPermissions(0o600, on: url)
    }

    private func setPermissions(
        _ permissions: Int,
        on url: URL
    ) throws {
        try fileManager.setAttributes(
            [
                .posixPermissions: NSNumber(value: permissions),
            ],
            ofItemAtPath: url.path
        )
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }
}
