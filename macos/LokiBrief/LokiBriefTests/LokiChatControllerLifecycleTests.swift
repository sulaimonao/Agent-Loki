import Foundation
import XCTest
@testable import LokiBrief

private final class LokiChatControlledTransport: OllamaChatTransporting, @unchecked Sendable {
    private struct Request {
        let request: URLRequest
        let requestID: UUID
        let continuation: AsyncThrowingStream<OllamaChatTransportEvent, Error>.Continuation
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var cancellationIDs: [UUID] = []
    private var cancellationDrainIsSuspended = false
    private var cancellationDrainWaiters:
        [CheckedContinuation<Void, Never>] = []

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit _: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            requests.append(.init(
                request: request,
                requestID: requestID,
                continuation: continuation
            ))
            lock.unlock()
            continuation.yield(.response(.init(
                statusCode: 200,
                finalURL: request.url,
                expectedContentLength: nil
            )))
        }
    }

    func cancel(requestID: UUID) async {
        let shouldSuspend = lock.withLock {
            cancellationIDs.append(requestID)
            return cancellationDrainIsSuspended
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    guard cancellationDrainIsSuspended else {
                        return true
                    }
                    cancellationDrainWaiters.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        // Deliberately leave the transport continuation open. This models a
        // misbehaving late provider callback so the provider/controller epoch
        // checks, rather than a cooperative fixture, prove stale-result safety.
    }

    func suspendCancellationDrain() {
        lock.withLock {
            cancellationDrainIsSuspended = true
        }
    }

    func releaseCancellationDrain() {
        let waiters = lock.withLock {
            cancellationDrainIsSuspended = false
            let waiters = cancellationDrainWaiters
            cancellationDrainWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func suspendedCancellationCount() -> Int {
        lock.withLock {
            cancellationDrainWaiters.count
        }
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func cancellationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationIDs.count
    }

    func requestBody(requestAt index: Int) -> String? {
        lock.withLock {
            guard requests.indices.contains(index),
                  let body = requests[index].request.httpBody
            else { return nil }
            return String(data: body, encoding: .utf8)
        }
    }

    func emit(_ data: Data, requestAt index: Int) {
        let continuation = continuation(requestAt: index)
        continuation?.yield(.bytes(data))
    }

    func finish(requestAt index: Int) {
        continuation(requestAt: index)?.finish()
    }

    private func continuation(
        requestAt index: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else { return nil }
        return requests[index].continuation
    }
}

private actor LokiChatLifecycleFeedClient: FeedRetrieving {
    func fetch(
        _ subscription: FeedSubscription,
        trace _: FeedTraceContext
    ) async throws -> FeedFetchResult {
        throw FeedFetchFailure(.networkUnavailable)
    }

    func cancelAll() async {}
}

private actor LokiChatLifecycleToolDataSource:
    AgentLokiReadOnlyToolDataSource,
    AgentLokiContextEvidenceProviding
{
    private let suspendCurrentBrief: Bool
    private let snapshotEvidence: [AgentLokiEvidenceExcerpt]
    private let contextEvidence: [AgentLokiEvidenceExcerpt]
    private var currentBriefReadActive = false
    private var currentBriefCancellationCount = 0
    private var currentBriefReadCount = 0

    init(
        suspendCurrentBrief: Bool,
        snapshotEvidence: [AgentLokiEvidenceExcerpt] = [],
        contextEvidence: [AgentLokiEvidenceExcerpt] = []
    ) {
        self.suspendCurrentBrief = suspendCurrentBrief
        self.snapshotEvidence = snapshotEvidence
        self.contextEvidence = contextEvidence
    }

    func contextCandidates(
        for context: LokiChatContext
    ) -> [AgentLokiContextCandidate] {
        guard context.scope == .thisBrief || context.scope == .today else {
            return []
        }
        return contextEvidence.enumerated().map { index, evidence in
            AgentLokiContextCandidate(
                evidence: evidence,
                consentScopeID: evidence.reference.sourceKind == .slack
                    ? evidence.reference.accountIdentifier
                    : nil,
                priority: 100 - index
            )
        }
    }

    func authorizationDecision(
        for _: AgentLokiAuthorizationScope
    ) -> AgentLokiAuthorizationDecision {
        .allow()
    }

    func currentBriefSnapshot() async throws -> AgentLokiToolSnapshot {
        currentBriefReadCount += 1
        guard suspendCurrentBrief else {
            return Self.snapshot(evidence: snapshotEvidence)
        }
        currentBriefReadActive = true
        defer { currentBriefReadActive = false }
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
            currentBriefCancellationCount += 1
            throw CancellationError()
        }
        return Self.snapshot(evidence: snapshotEvidence)
    }

    func briefSnapshot(id _: String) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func searchBriefHistory(
        _: AgentLokiBriefHistoryQuery
    ) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func beginVaultForegroundRead() {}
    func endVaultForegroundRead() {}

    func searchVaultText(
        _: AgentLokiVaultTextQuery
    ) async throws -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func vaultItemSnapshot(id _: String) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func connectedSourcesSnapshot(limit _: Int) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func sourceHealthSnapshot(id _: String) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func slackWorkspacesSnapshot(limit _: Int) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func selectedSlackChannelsSnapshot(
        workspaceID _: String,
        limit _: Int
    ) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func deliveryStatusSnapshot() -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func updateStatusSnapshot() -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func previewBackfill(
        _: AgentLokiBackfillPreviewQuery
    ) -> AgentLokiToolSnapshot {
        Self.snapshot(evidence: snapshotEvidence)
    }

    func state() -> (
        active: Bool,
        cancellations: Int,
        reads: Int
    ) {
        (
            currentBriefReadActive,
            currentBriefCancellationCount,
            currentBriefReadCount
        )
    }

    private static func snapshot(
        evidence: [AgentLokiEvidenceExcerpt]
    ) -> AgentLokiToolSnapshot {
        AgentLokiToolSnapshot(
            records: [
                .init(
                    id: "synthetic-current-brief",
                    fields: [
                        "title": .string("Synthetic current brief"),
                        "item_count": .integer(1),
                    ]
                ),
            ],
            evidence: evidence,
            reasonCode: "chat_tool_synthetic_fixture"
        )
    }
}

private final class LokiChatLifecycleTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OllamaChatTraceEvent] = []

    func record(_ event: OllamaChatTraceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [OllamaChatTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@MainActor
final class LokiChatControllerLifecycleTests: XCTestCase, @unchecked Sendable {
    private static let modelIdentifier = "synthetic-controller-model:latest"
    private static let modelDigest = "sha256:controller-fixture"
    private static let providerVersion = "0.test"
    nonisolated private static let fixedDate = Date(timeIntervalSince1970: 1_785_000_000)

    private struct Fixture {
        let store: LocalStore
        let model: AppModel
        let controller: LokiChatController
        let transport: LokiChatControlledTransport
        let toolExecutor: AgentLokiReadOnlyToolExecutor
        let toolDataSource: LokiChatLifecycleToolDataSource
        let traces: LokiChatLifecycleTraceRecorder
    }

    func testConnectedSourceContextPersistsExactAttachedSourceIdentifier()
        throws
    {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        let context = LokiChatContext(
            scope: .connectedSources,
            targetIdentifier: "attached-source-a",
            selectedAt: Self.fixedDate
        )

        let conversation = try XCTUnwrap(
            fixture.controller.newConversation(context: context)
        )
        XCTAssertEqual(conversation.context, context)
        XCTAssertEqual(
            try fixture.store.lokiConversation(id: conversation.id)?.context,
            context
        )
    }

    func testAgentAttachedJSONCitationUsesExactRecordPointer() throws {
        let provenance = VaultAttachedSourceProvenance(
            sourceIdentifier: "attached-json-a",
            sourceKind: "json",
            sourceEpoch: 8,
            sourceDigest: String(repeating: "a", count: 64),
            selectionIdentifier: "json-selection-a",
            selectionSourceIdentifier: "/projects",
            stableRecordIdentifier: "project-17",
            recordLocator: "/projects/3",
            schemaDigest: String(repeating: "b", count: 64),
            generationIdentifier: "generation:8:fixture",
            generationReceiptHash: String(repeating: "c", count: 64),
            pageReceiptHash: String(repeating: "d", count: 64),
            identityStrategy: "explicit_json_id",
            wasTruncated: true
        )
        let result = VaultSearchResult(
            id: "vault-json-a",
            accountID: "account-json-a",
            containerID: "container-json-a",
            kind: "attached_json_record",
            title: "Project record",
            snippet: "Bounded JSON evidence",
            occurredAt: Self.fixedDate,
            revision: 2,
            contentChecksum: String(repeating: "e", count: 64),
            provider: VaultProviderKind.localImport.rawValue,
            author: nil,
            sourceURL: nil,
            directlyMentionsUser: false,
            isRead: false,
            isDeleted: false,
            contentOrigin: .source,
            attachedSourceProvenance: provenance
        )

        let record = LiveAgentLokiToolDataSource.vaultRecord(result)
        let evidence = LiveAgentLokiToolDataSource.vaultEvidence(result)
        XCTAssertEqual(
            record.fields["attached_selection_source"],
            .string("/projects")
        )
        XCTAssertEqual(
            record.fields["attached_record_locator"],
            .string("/projects/3")
        )
        XCTAssertEqual(
            record.fields["attached_record_stable_id"],
            .string("project-17")
        )
        XCTAssertTrue(
            evidence.text.contains(
                "JSON root /projects, record JSON Pointer /projects/3"
            )
        )
        XCTAssertTrue(evidence.text.contains("truncated true"))
    }

    func testBriefSummaryRemainsIndependentWhileAnyLocalModelCanBeAssignedPrimaryBeforeAssessment() throws {
        let store = try LocalStore(inMemory: true)
        let briefingModel = Self.modelDescriptor()
        let customChatModel = OllamaModelDescriptor(
            id: "my-lab/arbitrary-chat-model:v42",
            name: "My Arbitrary Chat Model",
            modifiedAt: nil,
            sizeBytes: 2,
            digest: "sha256:arbitrary-chat-model",
            format: "gguf",
            family: "custom",
            families: ["custom"],
            parameterSize: "test",
            quantizationLevel: "test"
        )
        let cloudChatModel = OllamaModelDescriptor(
            id: "gpt-oss:120b-cloud",
            name: "Remote Cloud Model",
            modifiedAt: nil,
            sizeBytes: nil,
            digest: "sha256:cloud-model",
            format: "remote",
            family: "gpt-oss",
            families: ["gpt-oss"],
            parameterSize: nil,
            quantizationLevel: nil
        )
        try store.persistModelCatalog(.init(
            revision: 1,
            discoveredAt: Self.fixedDate,
            models: [briefingModel, customChatModel],
            excludedCloudModelCount: 0
        ))
        try store.persistModelSelection(.init(
            model: briefingModel,
            catalogRevision: 1,
            selectedAt: Self.fixedDate
        ), enabled: false)

        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let controller = try XCTUnwrap(model.chatController)
        XCTAssertEqual(model.selectedModelID, briefingModel.id)
        XCTAssertEqual(controller.selectedChatModelID, "gemma4:12b")
        XCTAssertNil(try store.lokiChatModelSelection())
        XCTAssertEqual(
            controller.modelRoleAssignment(for: .primaryAgent).readiness,
            .modelUnavailable
        )

        let traces = LokiChatLifecycleTraceRecorder()
        let explicitController = try LokiChatController(
            model: model,
            store: store,
            traceSink: { event in traces.record(event) }
        )
        explicitController.synchronizeOllamaCatalog(
            models: [briefingModel, customChatModel, cloudChatModel],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 3,
                selectedModelID: briefingModel.id,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )
        XCTAssertEqual(
            explicitController.readinessCards().map(\.id),
            [customChatModel.id, briefingModel.id]
        )
        explicitController.preferModelForChat(id: cloudChatModel.id)
        XCTAssertEqual(
            explicitController.selectedChatModelID,
            "gemma4:12b"
        )

        explicitController.preferModelForChat(id: customChatModel.id)

        XCTAssertEqual(explicitController.selectedChatModelID, customChatModel.id)
        XCTAssertEqual(model.selectedModelID, briefingModel.id)
        XCTAssertEqual(
            try store.lokiChatModelSelection()?.modelIdentifier,
            customChatModel.id
        )
        XCTAssertEqual(
            explicitController.selectedModelReadinessPresentation().readiness,
            .assessmentRequired
        )
        XCTAssertFalse(explicitController.selectedModelReadinessPresentation().canSend)
        XCTAssertTrue(
            explicitController.statusMessage.contains(
                "is preferred for Agent Loki Chat"
            )
        )

        let preferenceEvent = try XCTUnwrap(
            traces.snapshot().last(where: { $0.event == .modelPreferenceChanged })
        )
        XCTAssertEqual(preferenceEvent.status, .degraded)
        XCTAssertEqual(
            preferenceEvent.reasonCode,
            ModelRoleReason.assessmentRequired
        )
        XCTAssertEqual(
            preferenceEvent.metadata["trigger"],
            ModelRole.primaryAgent.rawValue
        )
        XCTAssertEqual(
            preferenceEvent.metadata["state"],
            ModelRoleReadiness.assessmentRequired.rawValue
        )
        XCTAssertEqual(
            preferenceEvent.metadata["model_hash"],
            OllamaChatTracePrivacy.modelIdentifierHash(customChatModel.id)
        )
        XCTAssertFalse(
            preferenceEvent.metadata.values.contains {
                $0.contains(customChatModel.name) || $0.contains(customChatModel.id)
            }
        )

        let reopenedController = try LokiChatController(
            model: model,
            store: store,
            traceSink: { _ in }
        )
        reopenedController.synchronizeOllamaCatalog(
            models: [briefingModel, customChatModel, cloudChatModel],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 3,
                selectedModelID: briefingModel.id,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )
        XCTAssertEqual(reopenedController.selectedChatModelID, customChatModel.id)
        XCTAssertEqual(model.selectedModelID, briefingModel.id)
        XCTAssertEqual(
            reopenedController.selectedModelReadinessPresentation().readiness,
            .assessmentRequired
        )
    }

    func testImageRequestRequiresVisibleVisionRouteConfirmationBeforeTransport() async throws {
        let store = try LocalStore(inMemory: true)
        let primary = Self.modelDescriptor()
        let visionIdentifier = "synthetic-vision-model:latest"
        let visionDigest = "sha256:synthetic-vision-fixture"
        let vision = OllamaModelDescriptor(
            id: visionIdentifier,
            name: "Synthetic Vision Model",
            modifiedAt: nil,
            sizeBytes: 2,
            digest: visionDigest,
            format: "gguf",
            family: "synthetic-vision",
            families: ["synthetic-vision"],
            parameterSize: "test",
            quantizationLevel: "test"
        )
        try store.upsertLokiModelAssessment(.init(
            id: "ollama:\(Self.modelIdentifier):controller-fixture",
            readiness: .ready,
            assessment: Self.readyAssessment()
        ))
        let visionCapabilities: Set<ModelCapability> = [
            .chat,
            .streaming,
            .vision,
            .cancellation,
            .systemInstructions,
            .contextWindow,
        ]
        try store.upsertLokiModelAssessment(.init(
            id: "ollama:\(visionIdentifier):vision-fixture",
            readiness: .ready,
            assessment: .init(
                provider: "ollama",
                providerVersion: Self.providerVersion,
                modelIdentifier: visionIdentifier,
                modelDigest: visionDigest,
                capabilitiesProven: visionCapabilities,
                capabilitiesMissing: Set(ModelCapability.allCases)
                    .subtracting(visionCapabilities),
                contextPolicy: .init(
                    declaredContextTokens: 131_072,
                    empiricallyUsableContextTokens: 65_536
                ),
                assessedAt: Self.fixedDate,
                durationMilliseconds: 10,
                diagnostics: []
            )
        ))
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let transport = LokiChatControlledTransport()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let toolDataSource = LokiChatLifecycleToolDataSource(
            suspendCurrentBrief: false
        )
        let controller = try LokiChatController(
            model: model,
            store: store,
            provider: provider,
            toolExecutor: .init(
                dataSource: toolDataSource,
                traceLogger: .init(sink: { _ in }),
                now: { Self.fixedDate }
            ),
            contextEvidenceProvider: toolDataSource,
            traceSink: { _ in }
        )
        controller.synchronizeOllamaCatalog(
            models: [primary, vision],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 2,
                selectedModelID: nil,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )
        controller.assignModel(id: primary.id, to: .primaryAgent)
        controller.assignModel(id: vision.id, to: .vision)
        XCTAssertEqual(
            controller.modelRoleAssignment(for: .vision).readiness,
            .ready
        )

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(
                "synthetic-p8-red-blue.png.base64",
                isDirectory: false
            )
        let fixtureText = try String(
            contentsOf: fixtureURL,
            encoding: .utf8
        )
        let fixtureData = try XCTUnwrap(
            Data(
                base64Encoded: fixtureText,
                options: [.ignoreUnknownCharacters]
            )
        )
        controller.p8Features.addVisionData(
            fixtureData,
            typeIdentifier: "public.png",
            source: .dragAndDrop
        )
        try await eventually("the synthetic image to finish intake") {
            !controller.p8Features.visionIsProcessing
                && controller.p8Features.hasVisionAttachments
        }

        controller.send(
            "Describe the bounded synthetic image.",
            requireVisibleVisionAcknowledgement: true
        )
        XCTAssertEqual(transport.requestCount(), 0)
        XCTAssertNil(controller.activeConversation)
        let cancelledPending = try XCTUnwrap(
            controller.pendingVisionRoute
        )
        XCTAssertEqual(cancelledPending.requestedRole, .primaryAgent)
        XCTAssertEqual(
            cancelledPending.requestedModelIdentifier,
            Self.modelIdentifier
        )
        XCTAssertEqual(
            cancelledPending.visionModelIdentifier,
            visionIdentifier
        )
        XCTAssertTrue(cancelledPending.notice.contains(visionIdentifier))
        XCTAssertTrue(
            cancelledPending.requiresExplicitVisibilityAcknowledgement
        )
        XCTAssertFalse(
            cancelledPending.visibilityAcknowledgementToken.isEmpty
        )
        XCTAssertEqual(try store.modelRoutingReceipts().count, 1)

        await controller.cancelAndDrainSignedSmokeOperation()
        XCTAssertNil(controller.pendingVisionRoute)
        XCTAssertEqual(transport.requestCount(), 0)
        XCTAssertFalse(controller.p8Features.hasVisionAttachments)
        XCTAssertFalse(
            controller.acknowledgePendingVisionRouteVisibility(
                token:
                    cancelledPending.visibilityAcknowledgementToken
            )
        )
        controller.confirmPendingVisionRoute()
        XCTAssertEqual(transport.requestCount(), 0)

        controller.assessModel(id: visionIdentifier)
        try await eventually(
            "the cancellable Vision reassessment show request"
        ) {
            transport.requestCount() == 1
        }
        transport.emit(
            try JSONSerialization.data(
                withJSONObject: [
                    "capabilities": [
                        "completion",
                        "tools",
                        "vision",
                    ],
                    "model_info": [
                        "general.architecture":
                            "synthetic-vision",
                        "synthetic-vision.context_length":
                            131_072,
                    ],
                ]
            ),
            requestAt: 0
        )
        transport.finish(requestAt: 0)
        try await eventually(
            "the cancellable Vision reassessment probe"
        ) {
            transport.requestCount() == 2
        }
        transport.suspendCancellationDrain()
        defer { transport.releaseCancellationDrain() }
        let retainedCancellationDrain = Task {
            await controller.cancelAndDrainSignedSmokeOperation()
        }
        try await eventually(
            "the signed-smoke cancellation drain to suspend"
        ) {
            transport.suspendedCancellationCount() > 0
        }
        XCTAssertTrue(controller.hasUpdateBlockingWork)

        controller.assessModel(id: primary.id)
        XCTAssertTrue(controller.assessingModelIDs.isEmpty)
        controller.send("Do not admit this successor yet.")
        XCTAssertNil(controller.activeConversation)

        transport.releaseCancellationDrain()
        await retainedCancellationDrain.value
        XCTAssertFalse(controller.hasUpdateBlockingWork)
        let successorRequestIndex = transport.requestCount()

        controller.p8Features.addVisionData(
            fixtureData,
            typeIdentifier: "public.png",
            source: .dragAndDrop
        )
        try await eventually(
            "the replacement synthetic image to finish intake"
        ) {
            !controller.p8Features.visionIsProcessing
                && controller.p8Features.hasVisionAttachments
        }
        controller.send(
            "Describe the bounded synthetic image.",
            requireVisibleVisionAcknowledgement: true
        )
        let pending = try XCTUnwrap(controller.pendingVisionRoute)
        XCTAssertNotEqual(
            pending.visibilityAcknowledgementToken,
            cancelledPending.visibilityAcknowledgementToken
        )
        XCTAssertEqual(
            transport.requestCount(),
            successorRequestIndex
        )
        XCTAssertEqual(try store.modelRoutingReceipts().count, 2)

        controller.confirmPendingVisionRoute()
        XCTAssertEqual(
            transport.requestCount(),
            successorRequestIndex
        )
        XCTAssertEqual(
            controller.pendingVisionRoute,
            pending
        )
        let acknowledgement = Task {
            await controller
                .waitForPendingVisionRouteVisibilityAcknowledgement(
                    token:
                        pending.visibilityAcknowledgementToken
                )
        }
        XCTAssertTrue(
            controller
                .acknowledgePendingVisionRouteVisibility(
                    token:
                        pending.visibilityAcknowledgementToken
                )
        )
        let acknowledged = await acknowledgement.value
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(
            transport.requestCount(),
            successorRequestIndex
        )
        controller.confirmPendingVisionRoute()
        try await eventually("the confirmed Vision request to start") {
            transport.requestCount()
                == successorRequestIndex + 1
        }
        XCTAssertNil(controller.pendingVisionRoute)
        XCTAssertEqual(try store.modelRoutingReceipts().count, 2)
        let requestBody = try XCTUnwrap(
            transport.requestBody(
                requestAt: successorRequestIndex
            )
        )
        XCTAssertTrue(
            requestBody.contains(
                "\"model\":\"\(visionIdentifier)\""
            )
        )
        XCTAssertTrue(requestBody.contains("\"images\":["))

        transport.emit(
            try Self.chatChunk(
                content:
                    "Red is on the left and blue is on the right.",
                done: true,
                modelIdentifier: visionIdentifier
            ),
            requestAt: successorRequestIndex
        )
        transport.finish(requestAt: successorRequestIndex)
        try await eventually("the confirmed Vision response to finish") {
            !controller.isGenerating
        }
        XCTAssertEqual(
            controller.activeConversation?.messages.last?.state,
            .completed
        )
        let answer = try XCTUnwrap(
            controller.activeConversation?.messages.last?.visibleText
        )
        XCTAssertTrue(
            LokiChatController
                .signedSmokeVisionOutputProvesRedLeftBlueRight(
                    answer
                )
        )
        XCTAssertFalse(
            LokiChatController
                .signedSmokeVisionOutputProvesRedLeftBlueRight(
                    "Red and blue are visible on the left and right."
                )
        )
        XCTAssertFalse(
            LokiChatController
                .signedSmokeVisionOutputProvesRedLeftBlueRight(
                    "Red is on the right and blue is on the left."
                )
        )
    }

    func testEmbeddingRuntimeInvalidationAllowlistPersistsAcrossControllerRestart()
        async throws
    {
        let store = try LocalStore(inMemory: true)
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let providerVersion = "0.11.6"
        let assessment = Self.embeddingReadyAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            providerVersion: providerVersion,
            dimension: 3
        )
        let assessmentIdentifier = [
            "ollama",
            modelIdentifier,
            digest,
            ModelCapabilityAssessment.currentAssessmentVersion,
        ].joined(separator: ":")
        try store.upsertLokiModelAssessment(.init(
            id: assessmentIdentifier,
            readiness: .ready,
            assessment: assessment
        ))
        let profile = ModelProfile(
            provider: "ollama",
            providerVersion: providerVersion,
            modelIdentifier: modelIdentifier,
            displayName: "Qwen Embedding",
            modelDigest: digest,
            locallyInstalled: true,
            estimatedCapabilities: [.embedding],
            contextPolicy: .init(declaredContextTokens: nil),
            observedAt: Self.fixedDate
        )
        let assignment = ModelRoleCandidate(
            profile: profile,
            assessmentReceiptIdentifier: assessmentIdentifier,
            assessment: assessment
        ).assignment(
            for: .embedding,
            source: .operatorSelection,
            explicitlyAssigned: true,
            recommended: true,
            selectedAt: Self.fixedDate
        )
        XCTAssertTrue(assignment.isExecutable)
        try store.saveModelRoleAssignments([assignment])

        let descriptor = OllamaModelDescriptor(
            id: modelIdentifier,
            name: "Qwen Embedding",
            modifiedAt: nil,
            sizeBytes: 1,
            digest: digest,
            format: "gguf",
            family: "qwen3",
            families: ["qwen3"],
            parameterSize: "0.6B",
            quantizationLevel: "F16"
        )
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let traces = LokiChatLifecycleTraceRecorder()
        let p8 = try P8FeatureController(
            store: store,
            semanticIndex: try SemanticVaultIndex(inMemory: true)
        )
        let controller = try LokiChatController(
            model: model,
            store: store,
            p8Features: p8,
            traceSink: { event in traces.record(event) }
        )
        let status = OllamaProviderStatusSnapshot(
            state: .connected,
            checkedAt: Self.fixedDate,
            lastSuccessfulCheckAt: Self.fixedDate,
            discoveredModelCount: 1,
            selectedModelID: nil,
            lastFailureCode: nil
        )
        controller.synchronizeOllamaCatalog(
            models: [descriptor],
            status: status,
            providerVersion: providerVersion
        )
        await p8.waitForCurrentWork()
        XCTAssertEqual(
            controller.modelRoleAssignment(for: .embedding).readiness,
            .ready
        )
        XCTAssertTrue(p8.embeddingBindingIsReady)

        let stability = try XCTUnwrap(assessment.embeddingStability)
        controller.handleEmbeddingStabilityInvalidation(.init(
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            ollamaVersion: providerVersion,
            requestProfileVersion: stability.requestProfileVersion,
            requestProfileHash: stability.requestProfileHash,
            dimension: stability.explicitDimensions,
            truncate: stability.truncate,
            normalizationVersion: stability.normalizationVersion,
            assessmentTimestamp: assessment.assessedAt,
            reasonCode: "embedding_assessment_unrecognized_test"
        ))
        await p8.waitForCurrentWork()
        XCTAssertTrue(p8.embeddingBindingIsReady)
        XCTAssertTrue(
            try XCTUnwrap(
                try store.lokiModelAssessments().first
            ).assessment.embeddingStability?.accepted == true
        )
        XCTAssertFalse(traces.snapshot().contains {
            $0.event == .embeddingAssessmentInvalidated
        })

        let acceptedInvalidationReason =
            P8EmbeddingStabilityInvalidation
                .nonFiniteVectorReasonCode
        controller.handleEmbeddingStabilityInvalidation(.init(
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            ollamaVersion: providerVersion,
            requestProfileVersion: stability.requestProfileVersion,
            requestProfileHash: stability.requestProfileHash,
            dimension: stability.explicitDimensions,
            truncate: stability.truncate,
            normalizationVersion: stability.normalizationVersion,
            assessmentTimestamp: assessment.assessedAt,
            reasonCode: acceptedInvalidationReason
        ))
        await p8.waitForCurrentWork()

        let persisted = try XCTUnwrap(
            try store.lokiModelAssessments().first
        )
        XCTAssertNil(persisted.assessment.embeddingStability)
        XCTAssertFalse(
            persisted.assessment.capabilitiesProven.contains(.embedding)
        )
        XCTAssertTrue(
            persisted.assessment.capabilitiesMissing.contains(.embedding)
        )
        XCTAssertTrue(persisted.assessment.diagnostics.contains {
            $0.status == .failed
                && $0.reasonCode == acceptedInvalidationReason
        })
        let invalidatedRole =
            controller.modelRoleAssignment(for: .embedding)
        XCTAssertEqual(invalidatedRole.readiness, .staleAssessment)
        XCTAssertFalse(invalidatedRole.isExecutable)
        XCTAssertFalse(p8.embeddingBindingIsReady)
        let invalidationEvent = try XCTUnwrap(
            traces.snapshot().last {
                $0.event == .embeddingAssessmentInvalidated
            }
        )
        XCTAssertEqual(invalidationEvent.status, .degraded)
        XCTAssertEqual(
            invalidationEvent.reasonCode,
            acceptedInvalidationReason
        )
        XCTAssertEqual(
            invalidationEvent.metadata["model_hash"],
            OllamaChatTracePrivacy.modelIdentifierHash(modelIdentifier)
        )

        let reopenedP8 = try P8FeatureController(
            store: store,
            semanticIndex: try SemanticVaultIndex(inMemory: true)
        )
        let reopened = try LokiChatController(
            model: model,
            store: store,
            p8Features: reopenedP8,
            traceSink: { _ in }
        )
        reopened.synchronizeOllamaCatalog(
            models: [descriptor],
            status: status,
            providerVersion: providerVersion
        )
        await reopenedP8.waitForCurrentWork()
        XCTAssertEqual(
            reopened.modelRoleAssignment(for: .embedding).readiness,
            .staleAssessment
        )
        XCTAssertFalse(
            reopened.modelRoleAssignment(for: .embedding).isExecutable
        )
        XCTAssertFalse(reopenedP8.embeddingBindingIsReady)
    }

    func testStreamingGenerationBlocksUpdateThenCancellationDrainsAndRejectsLateCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "loki-p7-controller-update-\(UUID().uuidString)",
                isDirectory: true
            )
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        var conversationID = ""
        var canceledMessageID = ""
        do {
            let fixture = try makeFixture(
                store: LocalStore(url: storeURL),
                suspendCurrentBrief: false
            )
            fixture.controller.send("Summarize the synthetic current brief.")
            try await eventually("the first native chat request to start") {
                fixture.transport.requestCount() == 1
            }

            XCTAssertTrue(fixture.controller.isGenerating)
            XCTAssertTrue(fixture.controller.hasUpdateBlockingWork)
            XCTAssertEqual(
                fixture.controller.activeConversation?.messages.last?.state,
                .waitingForFirstToken
            )

            fixture.transport.emit(
                try Self.chatChunk(
                    content: "Truthful partial ",
                    thinking: "PRIVATE_EPOCH_CANCEL_THINKING",
                    done: false
                ),
                requestAt: 0
            )
            try await eventually("the visible partial response to stream") {
                fixture.controller.activeConversation?.messages.last?.state == .streaming
            }
            XCTAssertEqual(
                fixture.controller.activeConversation?.messages.last?.visibleText,
                "Truthful partial "
            )

            conversationID = try XCTUnwrap(fixture.controller.activeConversation?.id)
            canceledMessageID = try XCTUnwrap(
                fixture.controller.activeConversation?.messages.last?.id
            )
            let prepared = await fixture.controller.prepareForApplicationUpdate()
            XCTAssertTrue(prepared)
            XCTAssertFalse(fixture.controller.chatPersistenceIsOpen)

            XCTAssertFalse(fixture.controller.isGenerating)
            XCTAssertFalse(fixture.controller.hasUpdateBlockingWork)
            XCTAssertGreaterThanOrEqual(fixture.transport.cancellationCount(), 1)
            let canceled = try XCTUnwrap(
                fixture.controller.activeConversation?.messages.last
            )
            XCTAssertEqual(canceled.state, .canceled)
            XCTAssertEqual(canceled.visibleText, "Truthful partial ")
            XCTAssertTrue(canceled.isPartial)
            let reasoningReceipt = try XCTUnwrap(
                fixture.store.modelReasoningReceipts().first
            )
            XCTAssertEqual(reasoningReceipt.status, .cancelled)
            XCTAssertEqual(
                reasoningReceipt.reasonCode,
                "model_reasoning_cancelled"
            )
            let persistedReasoningText = try XCTUnwrap(
                String(
                    data: JSONEncoder().encode(reasoningReceipt),
                    encoding: .utf8
                )
            )
            XCTAssertFalse(
                persistedReasoningText.contains(
                    "PRIVATE_EPOCH_CANCEL_THINKING"
                )
            )

            fixture.transport.emit(
                try Self.chatChunk(content: "late completion must be ignored", done: true),
                requestAt: 0
            )
            fixture.transport.finish(requestAt: 0)
            for _ in 0..<20 {
                await Task.yield()
            }
            let afterLateCompletion = try XCTUnwrap(
                fixture.controller.activeConversation?.messages.last
            )
            XCTAssertEqual(afterLateCompletion.id, canceledMessageID)
            XCTAssertEqual(afterLateCompletion.state, .canceled)
            XCTAssertEqual(afterLateCompletion.visibleText, "Truthful partial ")

            let messageCountWhileClosed =
                fixture.controller.activeConversation?.messages.count
            fixture.controller.send("This request must be rejected while update admission is closed.")
            XCTAssertEqual(
                fixture.controller.activeConversation?.messages.count,
                messageCountWhileClosed
            )
            XCTAssertEqual(
                fixture.controller.errorMessage,
                "Agent Loki Chat is paused for an application update."
            )

            let recovered = await fixture.controller.recoverAfterApplicationUpdateAbort()
            XCTAssertTrue(recovered)
            XCTAssertTrue(fixture.controller.chatPersistenceIsOpen)
            let cancelledExport = try fixture.controller
                .exportActiveConversation(format: .json)
            XCTAssertFalse(
                String(decoding: cancelledExport.data, as: UTF8.self)
                    .contains("PRIVATE_EPOCH_CANCEL_THINKING")
            )
            fixture.controller.retryResponse(messageID: canceledMessageID)
            try await eventually("a post-abort request to start") {
                fixture.transport.requestCount() == 2
            }
            XCTAssertTrue(fixture.controller.isGenerating)
            let retryUser = try XCTUnwrap(
                fixture.controller.activeConversation?.messages.dropLast().last
            )
            XCTAssertEqual(retryUser.role, .user)
            XCTAssertEqual(retryUser.visibleText, "Summarize the synthetic current brief.")
            XCTAssertEqual(retryUser.retryOfMessageID, canceledMessageID)
            let preparedAgain = await fixture.controller.prepareForApplicationUpdate()
            XCTAssertTrue(preparedAgain)
        }

        let reopenedStore = try LocalStore(url: storeURL)
        let reopened = try XCTUnwrap(
            try reopenedStore.lokiConversation(id: conversationID)
        )
        let preserved = try XCTUnwrap(
            reopened.messages.first(where: { $0.id == canceledMessageID })
        )
        XCTAssertEqual(preserved.state, .canceled)
        XCTAssertEqual(preserved.visibleText, "Truthful partial ")
        XCTAssertTrue(preserved.isPartial)
        XCTAssertFalse(
            String(
                decoding: try JSONEncoder().encode(reopened),
                as: UTF8.self
            ).contains("PRIVATE_EPOCH_CANCEL_THINKING")
        )
        XCTAssertEqual(
            reopened.messages.filter { $0.role == .assistant }.map(\.state),
            [.canceled, .canceled]
        )
    }

    func testActiveToolBlocksUpdateAndPreparationDrainsPendingToolWork() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: true
        )
        fixture.controller.send("Use the synthetic current brief tool.")
        try await eventually("the first native chat request to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(
                toolName: "get_current_brief",
                done: true
            ),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)

        try await eventually("the read-only tool to suspend") {
            let source = await fixture.toolDataSource.state()
            return source.active && fixture.controller.activeToolCount == 1
        }
        XCTAssertTrue(fixture.controller.isGenerating)
        XCTAssertTrue(fixture.controller.hasUpdateBlockingWork)
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .toolExecuting
        )

        let prepared = await fixture.controller.prepareForApplicationUpdate()
        XCTAssertTrue(prepared)

        XCTAssertFalse(fixture.controller.isGenerating)
        XCTAssertEqual(fixture.controller.activeToolCount, 0)
        XCTAssertFalse(fixture.controller.hasUpdateBlockingWork)
        let activeRequestCount = await fixture.toolExecutor.activeRequestCount()
        XCTAssertEqual(activeRequestCount, 0)
        let sourceState = await fixture.toolDataSource.state()
        XCTAssertFalse(sourceState.active)
        XCTAssertEqual(sourceState.cancellations, 1)
        XCTAssertEqual(sourceState.reads, 1)
        XCTAssertEqual(fixture.transport.requestCount(), 1)
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .canceled
        )
    }

    func testActiveGenerationRejectsConversationCreationAndSwitching() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        let firstConversationID = try XCTUnwrap(
            fixture.controller.newConversation()?.id
        )
        let active = try XCTUnwrap(fixture.controller.newConversation())
        fixture.controller.send("Keep this generation attached to its conversation.")
        try await eventually("the guarded request to start") {
            fixture.transport.requestCount() == 1
        }

        XCTAssertNil(fixture.controller.newConversation())
        fixture.controller.openConversation(id: firstConversationID)
        XCTAssertEqual(fixture.controller.activeConversation?.id, active.id)
        XCTAssertEqual(
            fixture.controller.errorMessage,
            "Stop the active Agent Loki response before opening another conversation."
        )

        fixture.controller.stopGeneration()
        try await eventually("the guarded request to stop") {
            !fixture.controller.isGenerating
        }
        XCTAssertEqual(fixture.controller.activeConversation?.id, active.id)
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .canceled
        )
    }

    func testStreamingCompletionAndExplicitRetryPreserveStateAndProvenance() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("Give the synthetic answer.")
        try await eventually("the initial request to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(content: "First ", done: false),
            requestAt: 0
        )
        try await eventually("the initial response to stream") {
            fixture.controller.activeConversation?.messages.last?.state == .streaming
        }
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.visibleText,
            "First "
        )
        fixture.transport.emit(
            try Self.chatChunk(content: "answer", done: true),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)
        try await eventually("the initial response to complete") {
            !fixture.controller.isGenerating
        }

        let initialMessages = try XCTUnwrap(
            fixture.controller.activeConversation?.messages
        )
        XCTAssertEqual(initialMessages.count, 2)
        XCTAssertEqual(initialMessages[1].state, .completed)
        XCTAssertTrue(initialMessages[1].visibleText.hasPrefix("First answer"))
        XCTAssertTrue(
            initialMessages[1].visibleText.contains(
                "No authorized local evidence supported this answer."
            )
        )
        XCTAssertTrue(
            initialMessages[1].answerSegments.first?.text.contains(
                "No authorized local evidence supported this answer."
            ) == true
        )
        let provenance = try XCTUnwrap(
            fixture.controller.generationProvenance(messageID: initialMessages[1].id)
        )
        XCTAssertEqual(provenance.status, "success")
        XCTAssertEqual(provenance.modelIdentifier, Self.modelIdentifier)

        fixture.controller.retryLastResponse()
        try await eventually("the explicit retry request to start") {
            fixture.transport.requestCount() == 2
        }
        let retryMessages = try XCTUnwrap(
            fixture.controller.activeConversation?.messages
        )
        XCTAssertEqual(retryMessages.count, 4)
        XCTAssertEqual(retryMessages[2].role, .user)
        XCTAssertEqual(retryMessages[2].visibleText, initialMessages[0].visibleText)
        XCTAssertEqual(retryMessages[2].retryOfMessageID, initialMessages[0].id)
        XCTAssertEqual(retryMessages[3].state, .waitingForFirstToken)

        fixture.transport.emit(
            try Self.chatChunk(content: "Retry answer", done: true),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the explicit retry to complete") {
            !fixture.controller.isGenerating
        }
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .completed
        )
        XCTAssertTrue(
            fixture.controller.activeConversation?.messages.last?.visibleText
                .hasPrefix("Retry answer") == true
        )
    }

    func testSuccessfulToolRequestResumesGenerationAndPersistsReceipt() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("Use one registered read-only tool.")
        try await eventually("the tool-requesting model turn to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(
                toolName: "get_current_brief",
                done: true
            ),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)

        try await eventually("generation to resume after the tool result") {
            fixture.transport.requestCount() == 2
        }
        XCTAssertEqual(fixture.controller.activeToolCount, 0)
        XCTAssertEqual(fixture.controller.activeToolReceipts.count, 1)
        XCTAssertEqual(
            fixture.controller.activeToolReceipts.first?.toolName,
            "get_current_brief"
        )
        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .waitingForFirstToken
        )
        XCTAssertTrue(fixture.traces.snapshot().contains {
            $0.event == .chatGenerationResumed
        })

        fixture.transport.emit(
            try Self.chatChunk(
                content: "Answer grounded in the synthetic tool result.",
                done: true
            ),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the resumed response to complete") {
            !fixture.controller.isGenerating
        }

        let assistant = try XCTUnwrap(
            fixture.controller.activeConversation?.messages.last
        )
        XCTAssertEqual(assistant.state, .completed)
        let receipts = fixture.controller.toolReceipts(messageID: assistant.id)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.toolName, "get_current_brief")
        XCTAssertEqual(receipts.first?.status, "success")
        XCTAssertEqual(receipts.first?.argumentKeys, [])
        XCTAssertEqual(receipts.first?.requestIdentifier.count, 32)
        XCTAssertNil(UUID(uuidString: receipts.first?.requestIdentifier ?? ""))
        let sourceState = await fixture.toolDataSource.state()
        XCTAssertEqual(sourceState.reads, 1)
    }

    func testToolLoopCarriesPrivateReasoningOnlyIntoContinuationTransport()
        async throws
    {
        let privateReasoning = "PRIVATE_TOOL_LOOP_REASONING_SENTINEL"
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("Use one registered read-only tool.")
        try await eventually("the tool-requesting turn to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(
                thinking: privateReasoning,
                toolName: "get_current_brief",
                done: true
            ),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)

        try await eventually("the private-reasoning continuation to start") {
            fixture.transport.requestCount() == 2
        }
        let continuationBody = try XCTUnwrap(
            fixture.transport.requestBody(requestAt: 1)?.data(using: .utf8)
        )
        let continuationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: continuationBody)
                as? [String: Any]
        )
        let continuationMessages = try XCTUnwrap(
            continuationObject["messages"] as? [[String: Any]]
        )
        let assistantToolTurn = try XCTUnwrap(
            continuationMessages.first {
                $0["role"] as? String == "assistant"
                    && $0["tool_calls"] != nil
            }
        )
        XCTAssertEqual(
            assistantToolTurn["thinking"] as? String,
            privateReasoning
        )

        fixture.transport.emit(
            try Self.chatChunk(
                content: "Synthetic tool continuation completed.",
                done: true
            ),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the private-reasoning tool loop to complete") {
            !fixture.controller.isGenerating
        }

        let conversationID = try XCTUnwrap(
            fixture.controller.activeConversation?.id
        )
        let storedConversation = try XCTUnwrap(
            try fixture.store.lokiConversation(id: conversationID)
        )
        let storedText = String(
            decoding: try JSONEncoder().encode(storedConversation),
            as: UTF8.self
        )
        let exportText = String(
            decoding: try fixture.controller.exportActiveConversation(
                format: .json
            ).data,
            as: UTF8.self
        )
        let receipt = try XCTUnwrap(
            try fixture.store.modelReasoningReceipts().first
        )
        let receiptText = String(
            decoding: try JSONEncoder().encode(receipt),
            as: UTF8.self
        )
        XCTAssertEqual(receipt.toolLoopCount, 1)
        XCTAssertFalse(storedText.contains(privateReasoning))
        XCTAssertFalse(exportText.contains(privateReasoning))
        XCTAssertFalse(receiptText.contains(privateReasoning))
    }

    func testSyntheticGemma4AssessmentPersistsVisionOnlyAfterProbePasses()
        async throws
    {
        let modelIdentifier = "gemma4:12b"
        let modelDigest = "sha256:synthetic-gemma4-vision"
        let primaryIdentifier = "gpt-oss:20b"
        let primaryDigest = "sha256:synthetic-gpt-oss-primary"
        let store = try LocalStore(inMemory: true)
        let primaryCapabilities: Set<ModelCapability> = [
            .chat,
            .streaming,
            .structuredOutput,
            .toolCalling,
            .cancellation,
            .reasoning,
            .systemInstructions,
            .contextWindow,
        ]
        try store.upsertLokiModelAssessment(.init(
            id: "ollama:\(primaryIdentifier):signed-smoke-primary",
            readiness: .ready,
            assessment: .init(
                provider: "ollama",
                providerVersion: Self.providerVersion,
                modelIdentifier: primaryIdentifier,
                modelDigest: primaryDigest,
                capabilitiesProven: primaryCapabilities,
                capabilitiesMissing:
                    Set(ModelCapability.allCases)
                        .subtracting(primaryCapabilities),
                contextPolicy: .init(
                    declaredContextTokens: 131_072,
                    empiricallyUsableContextTokens: 65_536
                ),
                reasoningControl: .ollamaLow,
                reasoningControlsProven: [
                    .ollamaLow,
                    .ollamaMedium,
                    .ollamaHigh,
                ],
                assessedAt: Self.fixedDate,
                durationMilliseconds: 10,
                diagnostics: []
            )
        ))
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let transport = LokiChatControlledTransport()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let toolDataSource = LokiChatLifecycleToolDataSource(
            suspendCurrentBrief: false
        )
        let controller = try LokiChatController(
            model: model,
            store: store,
            provider: provider,
            toolExecutor: AgentLokiReadOnlyToolExecutor(
                dataSource: toolDataSource,
                traceLogger: .init(sink: { _ in }),
                now: { Self.fixedDate }
            ),
            contextEvidenceProvider: toolDataSource,
            traceSink: { _ in }
        )
        controller.synchronizeOllamaCatalog(
            models: [
                .init(
                    id: primaryIdentifier,
                    name: "Synthetic GPT-OSS Primary",
                    modifiedAt: nil,
                    sizeBytes: 1,
                    digest: primaryDigest,
                    format: "gguf",
                    family: "gptoss",
                    families: ["gptoss"],
                    parameterSize: "20B",
                    quantizationLevel: "test"
                ),
                .init(
                    id: modelIdentifier,
                    name: "Synthetic Gemma 4",
                    modifiedAt: nil,
                    sizeBytes: 1,
                    digest: modelDigest,
                    format: "gguf",
                    family: "gemma4",
                    families: ["gemma4"],
                    parameterSize: "12B",
                    quantizationLevel: "test"
                ),
            ],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 2,
                selectedModelID: nil,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )
        controller.assignModel(
            id: primaryIdentifier,
            to: .primaryAgent
        )
        XCTAssertTrue(
            controller.modelRoleAssignment(
                for: .primaryAgent
            ).isExecutable
        )

        controller.assessModel(
            id: modelIdentifier,
            requireVisibleVisionConfirmation: true
        )
        try await eventually("the Gemma 4 show request") {
            transport.requestCount() == 1
        }
        transport.emit(
            try JSONSerialization.data(
                withJSONObject: [
                    "capabilities": ["completion", "tools", "vision"],
                    "model_info": [
                        "general.architecture": "gemma4",
                        "gemma4.context_length": 131_072,
                    ],
                ]
            ),
            requestAt: 0
        )
        transport.finish(requestAt: 0)

        let baseResponses = [
            try Self.chatChunk(
                content: "SYSTEM_OK",
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content: "one two three four five six seven eight",
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content: #"{"probe":"ok"}"#,
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                toolName: "get_synthetic_probe_status",
                arguments: ["probe": "capability"],
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content: "Synthetic result received.",
                done: true,
                modelIdentifier: modelIdentifier
            ),
        ]
        for (offset, response) in baseResponses.enumerated() {
            let requestIndex = offset + 1
            try await eventually("Gemma 4 base assessment request \(requestIndex)") {
                transport.requestCount() == requestIndex + 1
            }
            transport.emit(response, requestAt: requestIndex)
            transport.finish(requestAt: requestIndex)
        }

        try await eventually("the Gemma 4 cancellation probe") {
            transport.requestCount() == 7
        }
        transport.emit(
            try Self.chatChunk(
                content: "one ",
                done: false,
                modelIdentifier: modelIdentifier
            ),
            requestAt: 6
        )
        let routeObserved =
            await controller
                .waitForSignedSmokeVisionAssessmentRoute()
        XCTAssertTrue(routeObserved)
        XCTAssertEqual(transport.requestCount(), 7)
        let pending = try XCTUnwrap(
            controller.pendingVisionRoute
        )
        XCTAssertEqual(pending.requestedRole, .primaryAgent)
        XCTAssertEqual(
            pending.requestedModelIdentifier,
            primaryIdentifier
        )
        XCTAssertEqual(
            pending.visionModelIdentifier,
            modelIdentifier
        )
        XCTAssertTrue(
            pending.requiresExplicitVisibilityAcknowledgement
        )
        controller.confirmPendingVisionRoute()
        XCTAssertEqual(transport.requestCount(), 7)
        XCTAssertEqual(
            controller.pendingVisionRoute,
            pending
        )
        let acknowledgement = Task {
            await controller
                .waitForPendingVisionRouteVisibilityAcknowledgement(
                    token:
                        pending.visibilityAcknowledgementToken
                )
        }
        XCTAssertTrue(
            controller
                .acknowledgePendingVisionRouteVisibility(
                    token:
                        pending.visibilityAcknowledgementToken
                )
        )
        let acknowledged = await acknowledgement.value
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(transport.requestCount(), 7)
        controller.confirmPendingVisionRoute()
        try await eventually(
            "the confirmed Gemma 4 vision probe"
        ) {
            transport.requestCount() == 8
        }
        transport.emit(
            try Self.chatChunk(
                content: "Red is on the left and blue is on the right.",
                done: true,
                modelIdentifier: modelIdentifier
            ),
            requestAt: 7
        )
        transport.finish(requestAt: 7)

        try await eventually("the Gemma 4 assessment receipt to persist") {
            controller.assessingModelIDs.isEmpty
                && (try? store.lokiModelAssessments().count) == 2
        }
        let record = try XCTUnwrap(
            try store.lokiModelAssessments().first {
                $0.assessment.modelIdentifier
                    == modelIdentifier
            }
        )
        XCTAssertTrue(record.assessment.capabilitiesProven.contains(.vision))
        XCTAssertTrue(record.assessment.diagnostics.contains {
            $0.probe == .syntheticVision
                && $0.status == .success
                && $0.reasonCode == "model_synthetic_vision_verified"
        })
        let visionRole = try XCTUnwrap(
            try store.modelRoleAssignment(for: .vision)
        )
        XCTAssertEqual(visionRole.effectiveModelIdentifier, modelIdentifier)
        XCTAssertEqual(
            visionRole.assessmentReceiptIdentifier,
            record.id
        )
        XCTAssertEqual(visionRole.readiness, .ready)
    }

    func testGPTOSSAssessmentClosesToolLoopUnderEveryReasoningProfile()
        async throws
    {
        let modelIdentifier = "gpt-oss:20b"
        let modelDigest = "sha256:synthetic-gpt-oss-reasoning"
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let transport = LokiChatControlledTransport()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let toolDataSource = LokiChatLifecycleToolDataSource(
            suspendCurrentBrief: false
        )
        let controller = try LokiChatController(
            model: model,
            store: store,
            provider: provider,
            toolExecutor: AgentLokiReadOnlyToolExecutor(
                dataSource: toolDataSource,
                traceLogger: .init(sink: { _ in }),
                now: { Self.fixedDate }
            ),
            contextEvidenceProvider: toolDataSource,
            traceSink: { _ in }
        )
        controller.synchronizeOllamaCatalog(
            models: [
                .init(
                    id: modelIdentifier,
                    name: "Synthetic GPT-OSS",
                    modifiedAt: nil,
                    sizeBytes: 1,
                    digest: modelDigest,
                    format: "gguf",
                    family: "gpt-oss",
                    families: ["gpt-oss"],
                    parameterSize: "20B",
                    quantizationLevel: "test"
                ),
            ],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 1,
                selectedModelID: nil,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )

        controller.assessModel(id: modelIdentifier)
        try await eventually("the GPT-OSS show request") {
            transport.requestCount() == 1
        }
        transport.emit(
            try JSONSerialization.data(
                withJSONObject: [
                    "capabilities": [
                        "completion",
                        "tools",
                        "thinking",
                    ],
                    "model_info": [
                        "general.architecture": "gptoss",
                        "gptoss.context_length": 131_072,
                    ],
                ]
            ),
            requestAt: 0
        )
        transport.finish(requestAt: 0)

        let baseResponses = [
            try Self.chatChunk(
                content: "SYSTEM_OK",
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content:
                    "one two three four five six seven eight",
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content: #"{"probe":"ok"}"#,
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                toolName: "get_synthetic_probe_status",
                arguments: ["probe": "capability"],
                done: true,
                modelIdentifier: modelIdentifier
            ),
            try Self.chatChunk(
                content: "Synthetic result received.",
                done: true,
                modelIdentifier: modelIdentifier
            ),
        ]
        for (offset, response) in baseResponses.enumerated() {
            let requestIndex = offset + 1
            try await eventually(
                "GPT-OSS base assessment request \(requestIndex)"
            ) {
                transport.requestCount() == requestIndex + 1
            }
            transport.emit(response, requestAt: requestIndex)
            transport.finish(requestAt: requestIndex)
        }

        try await eventually("the GPT-OSS cancellation probe") {
            transport.requestCount() == 7
        }
        transport.emit(
            try Self.chatChunk(
                content: "one ",
                done: false,
                modelIdentifier: modelIdentifier
            ),
            requestAt: 6
        )

        let profiles: [(String, ModelReasoningControl)] = [
            ("low", .ollamaLow),
            ("medium", .ollamaMedium),
            ("high", .ollamaHigh),
        ]
        let privateThinking = "PRIVATE_PROFILE_REASONING_SENTINEL"
        for (profileOffset, profile) in profiles.enumerated() {
            let toolRequestIndex = 7 + profileOffset * 2
            let continuationRequestIndex = toolRequestIndex + 1
            try await eventually(
                "the \(profile.0) reasoning tool request"
            ) {
                transport.requestCount() == toolRequestIndex + 1
            }
            XCTAssertTrue(
                transport.requestBody(
                    requestAt: toolRequestIndex
                )?.contains(#""think":"\#(profile.0)""#)
                    == true
            )
            transport.emit(
                try Self.chatChunk(
                    thinking: privateThinking,
                    toolName:
                        "get_synthetic_reasoning_status",
                    arguments: ["probe": "reasoning"],
                    done: true,
                    modelIdentifier: modelIdentifier
                ),
                requestAt: toolRequestIndex
            )
            transport.finish(requestAt: toolRequestIndex)

            try await eventually(
                "the \(profile.0) reasoning continuation"
            ) {
                transport.requestCount()
                    == continuationRequestIndex + 1
            }
            let continuationBody = try XCTUnwrap(
                transport.requestBody(
                    requestAt: continuationRequestIndex
                )
            )
            XCTAssertTrue(
                continuationBody.contains(
                    #""think":"\#(profile.0)""#
                )
            )
            XCTAssertTrue(
                continuationBody.contains(
                    "get_synthetic_reasoning_status"
                )
            )
            XCTAssertTrue(
                continuationBody.contains(privateThinking)
            )
            transport.emit(
                try Self.chatChunk(
                    content:
                        "Synthetic reasoning tool continuation completed.",
                    done: true,
                    modelIdentifier: modelIdentifier
                ),
                requestAt: continuationRequestIndex
            )
            transport.finish(
                requestAt: continuationRequestIndex
            )
        }

        try await eventually(
            "the GPT-OSS assessment receipt to persist"
        ) {
            controller.assessingModelIDs.isEmpty
                && (try? store.lokiModelAssessments().count) == 1
        }
        let record = try XCTUnwrap(
            try store.lokiModelAssessments().first
        )
        XCTAssertTrue(
            record.assessment.capabilitiesProven
                .contains(.reasoning)
        )
        XCTAssertEqual(
            record.assessment.verifiedReasoningControls,
            Set(profiles.map { $0.1 })
        )
        for profile in profiles {
            XCTAssertTrue(record.assessment.diagnostics.contains {
                $0.probe == .syntheticToolCall
                    && $0.status == .success
                    && $0.reasonCode
                        == "model_synthetic_tool_call_\(profile.1.rawValue)_succeeded"
            })
            XCTAssertTrue(record.assessment.diagnostics.contains {
                $0.probe == .toolResultContinuation
                    && $0.status == .success
                    && $0.reasonCode
                        == "model_tool_continuation_\(profile.1.rawValue)_succeeded"
            })
        }
        let persistedAssessment = String(
            decoding: try JSONEncoder().encode(record.assessment),
            as: UTF8.self
        )
        XCTAssertFalse(
            persistedAssessment.contains(privateThinking)
        )
        XCTAssertEqual(transport.requestCount(), 13)
    }

    func testDeleteAllResumesReadOnlyToolExecutorForANewConversation() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        _ = fixture.controller.newConversation()
        await fixture.controller.deleteAllConversations()

        XCTAssertNil(fixture.controller.activeConversation)
        XCTAssertFalse(fixture.controller.hasUpdateBlockingWork)

        fixture.controller.send("Use the synthetic current brief tool after deletion.")
        try await eventually("the post-delete tool request to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(toolName: "get_current_brief", done: true),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)
        try await eventually("generation to resume after post-delete tool execution") {
            fixture.transport.requestCount() == 2
        }
        fixture.transport.emit(
            try Self.chatChunk(content: "Post-delete tool answer.", done: true),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the post-delete tool response to complete") {
            !fixture.controller.isGenerating
        }

        XCTAssertEqual(
            fixture.controller.activeConversation?.messages.last?.state,
            .completed
        )
        XCTAssertEqual(fixture.controller.activeToolReceipts.count, 1)
    }

    func testDeleteAllDuringGenerationRejectsLateCallbackAndReopensCleanly() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("This response will be deleted while active.")
        try await eventually("the deletable generation to start") {
            fixture.transport.requestCount() == 1
        }

        let deleted = await fixture.controller.deleteAllConversations()
        XCTAssertTrue(deleted)
        fixture.transport.emit(
            try Self.chatChunk(content: "LATE_CALLBACK_MUST_NOT_RECREATE", done: true),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)
        await Task.yield()

        XCTAssertNil(fixture.controller.activeConversation)
        XCTAssertTrue(try fixture.store.lokiConversationPage().isEmpty)
        XCTAssertNotNil(fixture.controller.newConversation())
        fixture.controller.send("Fresh request after deletion.")
        try await eventually("the fresh request to start") {
            fixture.transport.requestCount() == 2
        }
    }

    func testStopAndSourceRevocationInterleaveEventuallyReopensAdmission() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("Stop while source authorization changes.")
        try await eventually("the interleaved generation to start") {
            fixture.transport.requestCount() == 1
        }

        fixture.controller.stopGeneration()
        await fixture.controller.prepareForExternalEvidenceDeletion()
        await fixture.controller.completeExternalEvidenceDeletion(
            sourceKind: .slack,
            accountIdentifier: "workspace-1"
        )
        try await eventually("all interleaved lifecycle work to drain") {
            !fixture.controller.hasUpdateBlockingWork
        }

        XCTAssertNotNil(fixture.controller.newConversation())
        fixture.controller.send("Admission reopened after both barriers.")
        try await eventually("the post-interleave request to start") {
            fixture.transport.requestCount() == 2
        }
    }

    func testRevocationScrubFailureDeletesDependentChatHistoryBeforeResuming() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false,
            evidenceScrubPreflight: {
                throw NSError(
                    domain: "LokiChatControllerLifecycleTests",
                    code: 77
                )
            }
        )
        let conversation = try XCTUnwrap(fixture.controller.newConversation())
        XCTAssertNotNil(try fixture.store.lokiConversation(id: conversation.id))

        await fixture.controller.prepareForExternalEvidenceDeletion()
        var blockedDraft = fixture.controller.privacySettings
        blockedDraft.includeSourceExcerpts.toggle()
        XCTAssertFalse(fixture.controller.updatePrivacySettings(blockedDraft))
        XCTAssertNotEqual(
            fixture.controller.privacySettings.includeSourceExcerpts,
            blockedDraft.includeSourceExcerpts
        )
        await fixture.controller.completeExternalEvidenceDeletion(
            sourceKind: .slack,
            accountIdentifier: "workspace-1"
        )

        XCTAssertNil(fixture.controller.activeConversation)
        XCTAssertTrue(fixture.controller.conversationSummaries.isEmpty)
        XCTAssertNil(try fixture.store.lokiConversation(id: conversation.id))
        XCTAssertTrue(
            fixture.controller.errorMessage?.contains(
                "removed all local conversations"
            ) == true
        )
        XCTAssertNotNil(fixture.controller.newConversation())
        var settings = fixture.controller.privacySettings
        settings.allowFeedEvidence = false
        fixture.controller.updatePrivacySettings(settings)
        XCTAssertNil(fixture.controller.activeConversation)
        XCTAssertTrue(
            fixture.controller.errorMessage?.contains(
                "revoked feed evidence"
            ) == true
        )

        let workspace = Self.slackWorkspace()
        let workspaceStore = try LocalStore(inMemory: true)
        try workspaceStore.persistSlackWorkspace(workspace)
        try workspaceStore.setSlackLocalModelConsent(
            workspaceID: workspace.id,
            enabled: true
        )
        try workspaceStore.updateLokiChatWorkspaceEvidencePolicy(.init(
            workspaceIdentifier: workspace.id,
            allowSelectedSlackEvidence: true,
            updatedAt: Self.fixedDate
        ))
        let workspaceFixture = try makeFixture(
            store: workspaceStore,
            suspendCurrentBrief: false,
            evidenceScrubPreflight: {
                throw NSError(
                    domain: "LokiChatControllerLifecycleTests",
                    code: 78
                )
            }
        )
        XCTAssertNotNil(workspaceFixture.controller.newConversation())
        workspaceFixture.controller.setWorkspaceSlackEvidence(
            workspace.id,
            allowed: false
        )
        XCTAssertNil(workspaceFixture.controller.activeConversation)
        XCTAssertTrue(
            workspaceFixture.controller.errorMessage?.contains(
                "revoked Slack evidence"
            ) == true
        )
    }

    func testExternalEvidenceDeletionPurgesDerivedSemanticRowsBeforeChatResumes()
        async throws
    {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        let stableIdentifier = "attached-semantic-record"
        let sourceText = "Alpha attached source content."
        let semanticRecord = try SemanticIndexSourceRecord(
            stableSourceIdentifier: stableIdentifier,
            sourceKind: .vaultRecord,
            sourceTimestamp: Self.fixedDate,
            text: sourceText,
            sourceHash: SemanticIndexSourceRecord.deterministicSourceHash(
                stableSourceIdentifier: stableIdentifier,
                sourceKind: .vaultRecord,
                sourceTimestamp: Self.fixedDate,
                text: sourceText
            ),
            provenance: .init(
                provider: VaultProviderKind.localImport.rawValue,
                pseudonymousAccountIdentifier: "attached-account",
                remoteRecordIdentifier: "attached-record",
                provenanceReceiptHash: String(repeating: "a", count: 64)
            )
        )
        let features = fixture.controller.p8Features
        features.configurePermittedVaultSemanticRecordsProvider {
            [semanticRecord]
        }
        await features.waitForCurrentWork()
        features.semanticBuildSourceKinds = [.vaultRecord]
        features.rebuildSemanticIndex()
        await features.waitForCurrentWork()
        XCTAssertNotNil(
            features.semanticHealth?.activeGeneration,
            features.semanticStatus
        )

        features.semanticQuery = "Alpha"
        features.searchSemanticIndex()
        await features.waitForCurrentWork()
        XCTAssertEqual(
            features.semanticResults.count,
            1,
            features.semanticStatus
        )

        await fixture.controller.prepareForExternalEvidenceDeletion()
        XCTAssertTrue(features.semanticResults.isEmpty)
        await fixture.controller.completeExternalEvidenceDeletion(
            sourceKind: .vault,
            accountIdentifier: "attached-account"
        )

        XCTAssertEqual(features.semanticHealth?.state, .empty)
        XCTAssertNil(features.semanticHealth?.activeGeneration)
        XCTAssertTrue(features.semanticResults.isEmpty)
        XCTAssertFalse(features.semanticSourceAuthorityMutationIsHeld)
        XCTAssertNotNil(fixture.controller.newConversation())
    }

    func testHistoryOffSlackRevocationRemovesRelatedStatusAndBackfillAnswer() async throws {
        let statusReference = AgentLokiEvidenceReference(
            id: "source-status-evidence",
            sourceKind: .sourceStatus,
            accountClassification: "slack_workspace",
            accountIdentifier: "workspace-1",
            sourceItemID: "source-status",
            retrievedAt: Self.fixedDate,
            boundedLabel: "Connected source status",
            contentOrigin: .applicationState,
            trust: .localApplicationState,
            claimBasis: .observed
        )
        let backfillReference = AgentLokiEvidenceReference(
            id: "backfill-preview-evidence",
            sourceKind: .backfillPreview,
            accountClassification: "slack_workspace",
            accountIdentifier: "workspace-1",
            sourceItemID: "backfill-preview",
            retrievedAt: Self.fixedDate,
            boundedLabel: "Slack backfill preview",
            contentOrigin: .applicationState,
            trust: .localApplicationState,
            claimBasis: .observed
        )
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false,
            snapshotEvidence: [
                .init(reference: statusReference, text: "Connected."),
                .init(reference: backfillReference, text: "One bounded item."),
            ]
        )
        var settings = fixture.controller.privacySettings
        settings.storeLocalHistory = false
        settings.includeSourceExcerpts = true
        fixture.controller.updatePrivacySettings(settings)
        _ = fixture.controller.newConversation(scope: .connectedSources)

        fixture.controller.send("Inspect connected source state.")
        try await eventually("the connected-source request to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(toolName: "list_connected_sources", done: true),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)
        try await eventually("the connected-source tool result to resume generation") {
            fixture.transport.requestCount() == 2
        }
        fixture.transport.emit(
            try Self.chatChunk(
                content: "The source is available [evidence:\(statusReference.id)].",
                done: true
            ),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the history-off answer to complete") {
            !fixture.controller.isGenerating
        }

        XCTAssertEqual(
            Set(fixture.controller.activeEvidence.map(\.sourceKind)),
            [.connectedSourceStatus]
        )
        let completedMessageID = try XCTUnwrap(
            fixture.controller.activeConversation?.messages.last?.id
        )
        let export = try fixture.controller.exportActiveConversation(format: .json)
        let exportSnapshot = try Self.decodeExport(export.data)
        XCTAssertEqual(
            exportSnapshot.evidenceByMessageID[completedMessageID]?.map(\.id),
            [statusReference.id]
        )
        XCTAssertEqual(
            exportSnapshot.evidenceByMessageID[completedMessageID]?.first?.boundedExcerpt,
            "Connected."
        )
        XCTAssertEqual(
            exportSnapshot.toolReceiptsByMessageID[completedMessageID]?
                .first?.evidenceReferenceIDs,
            [statusReference.id]
        )
        XCTAssertNotNil(exportSnapshot.provenanceByMessageID[completedMessageID])
        settings.includeSourceExcerpts = false
        fixture.controller.updatePrivacySettings(settings)
        let redactedExport = try fixture.controller.exportActiveConversation(format: .json)
        XCTAssertNil(
            try Self.decodeExport(redactedExport.data)
                .evidenceByMessageID[completedMessageID]?.first?.boundedExcerpt
        )
        XCTAssertNil(
            try fixture.store.lokiConversation(
                id: try XCTUnwrap(fixture.controller.activeConversation?.id)
            )
        )

        await fixture.controller.revokeStoredEvidence(
            sourceKind: .slack,
            accountIdentifier: "workspace-1"
        )

        let revoked = try XCTUnwrap(
            fixture.controller.activeConversation?.messages.last
        )
        XCTAssertEqual(revoked.state, .sourceEvidenceDeleted)
        XCTAssertEqual(revoked.failure?.code, .sourceEvidenceDeleted)
        XCTAssertTrue(fixture.controller.activeEvidence.isEmpty)
        XCTAssertTrue(fixture.controller.activeToolReceipts.isEmpty)
    }

    func testChannelScopedRevocationPreservesOtherSelectedChannelAnswers() async throws {
        let workspace = Self.slackWorkspace()
        let evidence = ["channel-1", "channel-2"].map { channelID in
            AgentLokiEvidenceExcerpt(
                reference: .init(
                    id: "evidence-\(channelID)",
                    sourceKind: .slack,
                    accountClassification: "slack_workspace",
                    accountIdentifier: workspace.id,
                    containerClassification: "selected_channel",
                    containerIdentifier: channelID,
                    sourceItemID: "message-\(channelID)",
                    retrievedAt: Self.fixedDate,
                    boundedLabel: channelID,
                    contentOrigin: .source,
                    trust: .authorizedExternalUntrusted,
                    claimBasis: .observed
                ),
                text: "Bounded evidence for \(channelID)."
            )
        }

        for storeLocalHistory in [true, false] {
            let store = try LocalStore(inMemory: true)
            try store.persistSlackWorkspace(workspace)
            try store.setSlackLocalModelConsent(
                workspaceID: workspace.id,
                enabled: true
            )
            try store.persistDiscoveredSlackConversations(
                ["channel-1", "channel-2"].map { channelID in
                    .init(
                        id: channelID,
                        workspaceID: workspace.id,
                        displayName: channelID,
                        kind: .privateChannel,
                        isMember: true,
                        isArchived: false,
                        discoveredAt: Self.fixedDate
                    )
                },
                workspaceID: workspace.id
            )
            for channelID in ["channel-1", "channel-2"] {
                try store.setSlackConversationSelected(
                    id: "\(workspace.id):\(channelID)",
                    selected: true
                )
            }
            try store.updateLokiChatWorkspaceEvidencePolicy(.init(
                workspaceIdentifier: workspace.id,
                allowSelectedSlackEvidence: true,
                updatedAt: Self.fixedDate
            ))
            let fixture = try makeFixture(
                store: store,
                suspendCurrentBrief: false,
                contextEvidence: evidence
            )
            var settings = fixture.controller.privacySettings
            settings.storeLocalHistory = storeLocalHistory
            fixture.controller.updatePrivacySettings(settings)

            for (index, excerpt) in evidence.enumerated() {
                fixture.controller.send("Use \(excerpt.reference.containerIdentifier ?? "").")
                try await eventually("channel response \(index) to start") {
                    fixture.transport.requestCount() == index + 1
                }
                fixture.transport.emit(
                    try Self.chatChunk(
                        content: "Observed [evidence:\(excerpt.reference.id)].",
                        done: true
                    ),
                    requestAt: index
                )
                fixture.transport.finish(requestAt: index)
                try await eventually("channel response \(index) to complete") {
                    !fixture.controller.isGenerating
                }
            }

            await fixture.controller.revokeStoredEvidence(
                sourceKind: .slack,
                accountIdentifier: workspace.id,
                containerIdentifier: "channel-1"
            )

            let assistantMessages = fixture.controller.activeConversation?
                .messages.filter { $0.role == .assistant } ?? []
            XCTAssertEqual(
                assistantMessages.map(\.state),
                [.sourceEvidenceDeleted, .completed]
            )
            XCTAssertEqual(
                fixture.controller.evidenceReferences(
                    messageID: assistantMessages[1].id
                ).map(\.containerIdentifier),
                ["channel-2"]
            )
        }
    }

    func testSelectedContextEvidenceIsBoundedIntoInitialProviderRequestOnly() async throws {
        let selected = Self.evidence(
            id: "selected-context-evidence",
            label: "SELECTED_CONTEXT_SENTINEL"
        )
        let unrelated = Self.evidence(
            id: "unrelated-tool-evidence",
            label: "UNRELATED_SCOPE_SENTINEL"
        )
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false,
            snapshotEvidence: [unrelated],
            contextEvidence: [selected]
        )

        fixture.controller.send("Use only the selected bounded context.")
        try await eventually("the context-bearing request to start") {
            fixture.transport.requestCount() == 1
        }

        let body = try XCTUnwrap(fixture.transport.requestBody(requestAt: 0))
        XCTAssertTrue(body.contains(selected.reference.id))
        XCTAssertTrue(body.contains("SELECTED_CONTEXT_SENTINEL"))
        XCTAssertFalse(body.contains(unrelated.reference.id))
        XCTAssertFalse(body.contains("UNRELATED_SCOPE_SENTINEL"))

        fixture.controller.stopGeneration()
        try await eventually("the context-bearing request to drain") {
            !fixture.controller.isGenerating
        }
    }

    func testHistoryOffVaultEvidenceIsScrubbedByRawProviderRevocation() async throws {
        let rssAccountID = VaultIdentity.accountID(
            provider: "rss",
            providerAccountID: "local-feeds"
        )
        let cases: [(
            reference: AgentLokiEvidenceReference,
            sourceKind: LokiEvidenceSourceKind,
            rawIdentifier: String
        )] = [
            (
                .init(
                    id: "slack-vault-evidence",
                    sourceKind: .vault,
                    accountClassification: "slack",
                    accountIdentifier: VaultIdentity.accountID(
                        provider: "slack",
                        providerAccountID: "workspace-1"
                    ),
                    containerClassification: "channel",
                    containerIdentifier: "slack-container",
                    sourceItemID: "slack-record",
                    retrievedAt: Self.fixedDate,
                    boundedLabel: "Slack Vault item",
                    contentOrigin: .source,
                    trust: .authorizedExternalUntrusted,
                    claimBasis: .observed
                ),
                .slack,
                "workspace-1"
            ),
            (
                .init(
                    id: "rss-vault-evidence",
                    sourceKind: .vault,
                    accountClassification: "rss",
                    accountIdentifier: rssAccountID,
                    containerClassification: "feed",
                    containerIdentifier: VaultIdentity.containerID(
                        provider: "rss",
                        accountID: rssAccountID,
                        providerContainerID: "feed-1"
                    ),
                    sourceItemID: "rss-record",
                    retrievedAt: Self.fixedDate,
                    boundedLabel: "RSS Vault item",
                    contentOrigin: .source,
                    trust: .authorizedExternalUntrusted,
                    claimBasis: .observed
                ),
                .feed,
                "feed-1"
            ),
        ]

        for (index, item) in cases.enumerated() {
            let fixture = try makeFixture(
                store: LocalStore(inMemory: true),
                suspendCurrentBrief: false,
                snapshotEvidence: [
                    .init(reference: item.reference, text: "Bounded Vault content."),
                ]
            )
            var settings = fixture.controller.privacySettings
            settings.storeLocalHistory = false
            fixture.controller.updatePrivacySettings(settings)
            fixture.controller.send("Use the synthetic Vault evidence.")
            try await eventually("the provider Vault tool request \(index)") {
                fixture.transport.requestCount() == 1
            }
            fixture.transport.emit(
                try Self.chatChunk(toolName: "get_current_brief", done: true),
                requestAt: 0
            )
            fixture.transport.finish(requestAt: 0)
            try await eventually("the provider Vault generation \(index)") {
                fixture.transport.requestCount() == 2
            }
            fixture.transport.emit(
                try Self.chatChunk(
                    content: "Observed [evidence:\(item.reference.id)].",
                    done: true
                ),
                requestAt: 1
            )
            fixture.transport.finish(requestAt: 1)
            try await eventually("the provider Vault answer \(index)") {
                !fixture.controller.isGenerating
            }
            XCTAssertEqual(fixture.controller.activeEvidence.map(\.id), [
                item.reference.id,
            ])

            try fixture.controller.scrubEvidenceAfterExternalSourceDeletion(
                sourceKind: item.sourceKind,
                accountIdentifier: item.rawIdentifier
            )

            XCTAssertEqual(
                fixture.controller.activeConversation?.messages.last?.state,
                .sourceEvidenceDeleted
            )
            XCTAssertTrue(fixture.controller.activeEvidence.isEmpty)
            let exported = try fixture.controller.exportActiveConversation(format: .json)
            XCTAssertTrue(try Self.decodeExport(exported.data).evidenceByMessageID.isEmpty)
        }
    }

    func testEvidenceBearingResponsesWithoutAValidCitationAreRejected() async throws {
        for (index, unsupportedAnswer) in [
            "Unsupported factual answer.",
            "Unsupported factual answer [evidence:not-authorized].",
        ].enumerated() {
            let evidence = Self.evidence(
                id: "citation-required-\(index)",
                label: "Authorized synthetic brief"
            )
            let fixture = try makeFixture(
                store: LocalStore(inMemory: true),
                suspendCurrentBrief: false,
                snapshotEvidence: [evidence]
            )
            fixture.controller.send("Read the synthetic current brief.")
            try await eventually("the tool request to start") {
                fixture.transport.requestCount() == 1
            }
            fixture.transport.emit(
                try Self.chatChunk(toolName: "get_current_brief", done: true),
                requestAt: 0
            )
            fixture.transport.finish(requestAt: 0)
            try await eventually("generation to resume after evidence") {
                fixture.transport.requestCount() == 2
            }
            fixture.transport.emit(
                try Self.chatChunk(content: unsupportedAnswer, done: true),
                requestAt: 1
            )
            fixture.transport.finish(requestAt: 1)
            try await eventually("the unsupported answer to fail safely") {
                !fixture.controller.isGenerating
            }

            let assistant = try XCTUnwrap(
                fixture.controller.activeConversation?.messages.last
            )
            XCTAssertEqual(assistant.state, .failed)
            XCTAssertEqual(assistant.failure?.code, .invalidStructuredResponse)
            XCTAssertFalse(assistant.visibleText.contains("Unsupported factual answer"))
            XCTAssertTrue(fixture.controller.activeEvidence.isEmpty)
            XCTAssertTrue(
                try fixture.store.lokiEvidenceReferences(
                    messageID: assistant.id
                ).isEmpty
            )
            XCTAssertTrue(
                try fixture.store.lokiToolReceipts(
                    messageID: assistant.id
                ).isEmpty
            )
            XCTAssertFalse(fixture.traces.snapshot().contains {
                $0.event == .chatCompleted
            })
        }
    }

    func testHistoryOffAfterPersistedConversationExportsDurableAndEphemeralTurns() async throws {
        let fixture = try makeFixture(
            store: LocalStore(inMemory: true),
            suspendCurrentBrief: false
        )
        fixture.controller.send("Persisted turn.")
        try await eventually("the persisted turn request to start") {
            fixture.transport.requestCount() == 1
        }
        fixture.transport.emit(
            try Self.chatChunk(content: "Persisted answer.", done: true),
            requestAt: 0
        )
        fixture.transport.finish(requestAt: 0)
        try await eventually("the persisted turn to complete") {
            !fixture.controller.isGenerating
        }

        var settings = fixture.controller.privacySettings
        settings.storeLocalHistory = false
        fixture.controller.updatePrivacySettings(settings)
        fixture.controller.send("Ephemeral turn.")
        try await eventually("the ephemeral turn request to start") {
            fixture.transport.requestCount() == 2
        }
        fixture.transport.emit(
            try Self.chatChunk(content: "Ephemeral answer.", done: true),
            requestAt: 1
        )
        fixture.transport.finish(requestAt: 1)
        try await eventually("the ephemeral turn to complete") {
            !fixture.controller.isGenerating
        }

        let export = try fixture.controller.exportActiveConversation(format: .json)
        let snapshot = try Self.decodeExport(export.data)
        XCTAssertEqual(
            snapshot.conversation.messages.map(\.visibleText).filter {
                $0 == "Persisted turn."
                    || $0 == "Ephemeral turn."
                    || $0.hasPrefix("Persisted answer.")
                    || $0.hasPrefix("Ephemeral answer.")
            }.count,
            4
        )
        XCTAssertEqual(snapshot.provenanceByMessageID.count, 2)
        XCTAssertEqual(
            try fixture.store.lokiConversation(
                id: snapshot.conversation.id
            )?.messages.count,
            2
        )
    }

    func testLiveDataSourceEnforcesFeedAndVaultProviderConsent() async throws {
        let store = try LocalStore(inMemory: true)
        let feed = Self.feedSubscription()
        try store.persistFeedSubscription(feed)
        try store.record(Self.feedBrief(subscription: feed))
        let workspace = Self.slackWorkspace()
        try store.persistSlackWorkspace(workspace)
        try store.setSlackLocalModelConsent(workspaceID: workspace.id, enabled: true)
        try store.persistDiscoveredSlackConversations([
            .init(
                id: "channel-1",
                workspaceID: workspace.id,
                displayName: "selected-channel",
                kind: .privateChannel,
                isMember: true,
                isArchived: false,
                discoveredAt: Self.fixedDate
            ),
        ], workspaceID: workspace.id)
        try store.setSlackConversationSelected(
            id: "\(workspace.id):channel-1",
            selected: true
        )
        try store.updateLokiChatWorkspaceEvidencePolicy(.init(
            workspaceIdentifier: workspace.id,
            allowSelectedSlackEvidence: true,
            updatedAt: Self.fixedDate
        ))
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient(),
            currentCivilDayProvider: {
                LocalCalendarDay.resolve(containing: Self.fixedDate)
            }
        )
        let source = LiveAgentLokiToolDataSource(model: model)

        var settings = try store.lokiChatPrivacySettings()
        settings.allowFeedEvidence = false
        try store.updateLokiChatPrivacySettings(settings)

        let connected = try await source.connectedSourcesSnapshot(limit: 10)
        XCTAssertFalse(connected.records.contains { $0.id == feed.id })
        do {
            _ = try await source.sourceHealthSnapshot(id: feed.id)
            XCTFail("Feed health must be unavailable when feed evidence is off.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }
        let brief = try await source.currentBriefSnapshot()
        let briefRecord = try XCTUnwrap(brief.records.first)
        XCTAssertNil(briefRecord.fields["summary"])
        XCTAssertNil(briefRecord.fields["item_count"])
        XCTAssertEqual(briefRecord.fields["authorized_evidence_count"], .integer(0))
        XCTAssertEqual(briefRecord.fields["source_content_omitted"], .boolean(true))
        XCTAssertTrue(brief.evidence.isEmpty)

        let rssAccountID = VaultIdentity.accountID(
            provider: "rss",
            providerAccountID: "local-feeds"
        )
        let rssContainerID = VaultIdentity.containerID(
            provider: "rss",
            accountID: rssAccountID,
            providerContainerID: feed.id
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: "rss",
            providerAccountID: "local-feeds",
            accountID: rssAccountID,
            containerID: rssContainerID,
            providerContainerID: feed.id,
            recordID: "rss-record"
        )
        do {
            _ = try await source.vaultItemSnapshot(id: "rss-record")
            XCTFail("RSS Vault content must be unavailable when feed evidence is off.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        settings.allowFeedEvidence = true
        try store.updateLokiChatPrivacySettings(settings)
        model.removeFeed(id: feed.id)
        XCTAssertFalse(model.subscriptions.contains { $0.id == feed.id })
        let staleBrief = try await source.currentBriefSnapshot()
        XCTAssertTrue(staleBrief.evidence.isEmpty)
        XCTAssertNil(staleBrief.records.first?.fields["summary"])
        do {
            _ = try await source.vaultItemSnapshot(id: "rss-record")
            XCTFail("Removed-feed Vault content must remain unavailable.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        let slackAccountID = VaultIdentity.accountID(
            provider: "slack",
            providerAccountID: workspace.id
        )
        let slackContainerID = VaultIdentity.containerID(
            provider: "slack",
            accountID: slackAccountID,
            providerContainerID: "channel-1"
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: "slack",
            providerAccountID: workspace.id,
            accountID: slackAccountID,
            containerID: slackContainerID,
            providerContainerID: "channel-1",
            recordID: "slack-record"
        )
        let authorizedSlack = try await source.vaultItemSnapshot(id: "slack-record")
        XCTAssertEqual(authorizedSlack.records.map(\.id), ["slack-record"])
        await model.slackController.setChannelEnabled(
            workspaceID: workspace.id,
            channelID: "channel-1",
            enabled: false
        )
        let retainedDisabledSlack = try await source.vaultItemSnapshot(id: "slack-record")
        XCTAssertEqual(retainedDisabledSlack.records.map(\.id), ["slack-record"])
        let unselectedContainerID = VaultIdentity.containerID(
            provider: "slack",
            accountID: slackAccountID,
            providerContainerID: "channel-unselected"
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: "slack",
            providerAccountID: workspace.id,
            accountID: slackAccountID,
            containerID: unselectedContainerID,
            providerContainerID: "channel-unselected",
            recordID: "slack-unselected-record"
        )
        do {
            _ = try await source.vaultItemSnapshot(id: "slack-unselected-record")
            XCTFail("Unselected Slack channels must never reach Agent Loki.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        try store.updateLokiChatWorkspaceEvidencePolicy(.init(
            workspaceIdentifier: workspace.id,
            allowSelectedSlackEvidence: false,
            updatedAt: Self.fixedDate.addingTimeInterval(1)
        ))
        do {
            _ = try await source.vaultItemSnapshot(id: "slack-record")
            XCTFail("Slack Vault content must be unavailable after Chat consent is revoked.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

    }

    func testLiveDataSourceRequiresPersistedAttachedSourceConsentRetentionAndContainerSelection()
        async throws
    {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient(),
            currentCivilDayProvider: {
                LocalCalendarDay.resolve(containing: Self.fixedDate)
            }
        )
        let source = LiveAgentLokiToolDataSource(model: model)
        let sourceID = "attached-source-1"
        let selectionID = "attached-selection-1"
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID
        )
        let selectedContainerID = VaultIdentity.containerID(
            provider: VaultProviderKind.localImport.rawValue,
            accountID: accountID,
            providerContainerID: selectionID
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: selectedContainerID,
            providerContainerID: selectionID,
            recordID: "attached-selected-record",
            recordKind: "sqlite_row",
            metadata: [
                "connector_policy": ConnectorRecordPolicyClassification
                    .localIndexAllowed.rawValue,
                "connector_content_classification": ConnectorRecordContentClassification
                    .providerRecord.rawValue,
                "attached_source_id": sourceID,
                "attached_source_kind": "sqlite",
                "attached_source_epoch": "1",
                "attached_source_sha256": String(repeating: "a", count: 64),
                "attached_selection_id": selectionID,
                "attached_selection_source": "private_tasks",
                "attached_schema_sha256": String(repeating: "c", count: 64),
                "attached_record_locator": "private_tasks",
                "attached_identity_strategy": "declared_primary_key",
                "attached_generation_id": "generation-1",
                "attached_generation_receipt_sha256": String(
                    repeating: "d",
                    count: 64
                ),
                "connector_page_receipt_sha256": String(
                    repeating: "e",
                    count: 64
                ),
                "attached_truncated": "false",
            ]
        )

        do {
            _ = try await source.vaultItemSnapshot(id: "attached-selected-record")
            XCTFail("Vault data without a persisted attached source must be denied.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        try store.saveAttachedDataSource(try Self.attachedDataSourceRecord(
            id: sourceID,
            selectionID: selectionID,
            containerID: selectedContainerID,
            retained: false,
            localModelConsentEnabled: true
        ))
        let unretainedDecision = await source.authorizationDecision(
            for: .source(id: sourceID)
        )
        XCTAssertFalse(unretainedDecision.allowed)
        let unretainedSources = try await source.connectedSourcesSnapshot(limit: 10)
        XCTAssertFalse(unretainedSources.records.contains { $0.id == sourceID })

        try store.saveAttachedDataSource(try Self.attachedDataSourceRecord(
            id: sourceID,
            selectionID: selectionID,
            containerID: selectedContainerID,
            retained: true,
            localModelConsentEnabled: false
        ))
        do {
            _ = try await source.vaultItemSnapshot(id: "attached-selected-record")
            XCTFail("Attached data must remain unavailable before explicit consent.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        try store.saveAttachedDataSource(try Self.attachedDataSourceRecord(
            id: sourceID,
            selectionID: selectionID,
            containerID: selectedContainerID,
            retained: true,
            localModelConsentEnabled: true
        ))
        let authorizedDecision = await source.authorizationDecision(
            for: .source(id: sourceID)
        )
        XCTAssertTrue(authorizedDecision.allowed)

        let connected = try await source.connectedSourcesSnapshot(limit: 10)
        let connectedRecord = try XCTUnwrap(
            connected.records.first(where: { $0.id == sourceID })
        )
        XCTAssertEqual(connectedRecord.fields["kind"], .string("attached_data"))
        XCTAssertEqual(connectedRecord.fields["source_kind"], .string("sqlite"))
        XCTAssertEqual(
            connectedRecord.fields["name"],
            .string("SQLite attached source")
        )
        XCTAssertFalse(String(describing: connectedRecord.fields)
            .contains("PRIVATE_FILENAME_MUST_NOT_LEAK"))
        XCTAssertFalse(String(describing: connected.evidence)
            .contains("PRIVATE_FILENAME_MUST_NOT_LEAK"))
        XCTAssertEqual(
            connected.evidence.first(where: {
                $0.reference.accountIdentifier == sourceID
            })?.reference.accountClassification,
            "attached_data_source"
        )
        let health = try await source.sourceHealthSnapshot(id: sourceID)
        XCTAssertEqual(health.records.map(\.id), [sourceID])

        let requestAuthority = AgentLokiAttachedSourceRequestAuthority(
            sourceIdentifier: sourceID,
            accountIdentifier: accountID,
            containerIdentifiers: [selectedContainerID],
            generationIdentifier: "generation-1",
            sourceEpoch: 1,
            sourceDigest: String(repeating: "a", count: 64)
        )
        do {
            _ = try await source.vaultItemSnapshot(
                id: "attached-selected-record"
            )
            XCTFail(
                "Generic Vault item reads must exclude local-import records."
            )
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }
        let selected = try await source.vaultItemSnapshot(
            id: "attached-selected-record",
            attachedSourceAuthority: requestAuthority
        )
        XCTAssertEqual(selected.records.map(\.id), ["attached-selected-record"])
        let selectedEvidence = try XCTUnwrap(selected.evidence.first)
        XCTAssertEqual(
            selectedEvidence.reference.accountClassification,
            VaultProviderKind.localImport.rawValue
        )
        XCTAssertEqual(selectedEvidence.reference.accountIdentifier, accountID)
        XCTAssertEqual(
            selectedEvidence.reference.containerIdentifier,
            selectedContainerID
        )
        XCTAssertNil(selectedEvidence.reference.directSourceURL)

        let search = try await source.searchVaultText(.init(
            text: "Bounded fixture",
            accountID: accountID,
            containerID: selectedContainerID,
            startDate: nil,
            endDate: nil,
            limit: 10,
            attachedSourceAuthority: requestAuthority
        ))
        XCTAssertEqual(search.records.map(\.id), ["attached-selected-record"])
        XCTAssertEqual(
            search.records.first?.fields["source_account_id"],
            .string(accountID)
        )
        XCTAssertEqual(
            search.records.first?.fields["source_container_id"],
            .string(selectedContainerID)
        )
        XCTAssertEqual(
            search.records.first?.fields["attached_selection_source"],
            .string("private_tasks")
        )
        XCTAssertEqual(
            search.records.first?.fields["attached_record_stable_id"],
            .string("attached-selected-record")
        )
        XCTAssertTrue(
            search.evidence.first?.text.contains(
                "table private_tasks, stable row key attached-selected-record"
            ) == true
        )
        let semantic = try await source.permittedVaultSemanticRecords()
        let attachedSemantic = try XCTUnwrap(semantic.first(where: {
            $0.provenance.provider == VaultProviderKind.localImport.rawValue
        }))
        XCTAssertEqual(attachedSemantic.sourceKind, .vaultRecord)
        XCTAssertNil(attachedSemantic.provenance.sourceURL)

        let unselectedContainerID = VaultIdentity.containerID(
            provider: VaultProviderKind.localImport.rawValue,
            accountID: accountID,
            providerContainerID: "attached-selection-unselected"
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: unselectedContainerID,
            providerContainerID: "attached-selection-unselected",
            recordID: "attached-unselected-record",
            recordKind: "sqlite_row",
            metadata: [
                "connector_policy": ConnectorRecordPolicyClassification
                    .localIndexAllowed.rawValue,
                "connector_content_classification": ConnectorRecordContentClassification
                    .providerRecord.rawValue,
            ]
        )
        do {
            _ = try await source.vaultItemSnapshot(
                id: "attached-unselected-record",
                attachedSourceAuthority: requestAuthority
            )
            XCTFail("Unselected attached containers must remain unavailable.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }

        let features = try XCTUnwrap(model.chatController?.p8Features)
        features.semanticBuildSourceKinds = [.vaultRecord]
        features.rebuildSemanticIndex()
        await features.waitForCurrentWork()
        XCTAssertNotNil(features.semanticHealth?.activeGeneration)
        features.semanticQuery = "Bounded fixture"
        features.searchSemanticIndex()
        await features.waitForCurrentWork()
        XCTAssertEqual(features.semanticResults.count, 1)

        let authorityTransaction = try XCTUnwrap(model.chatController)
            .beginAttachedSourceSemanticAuthorityChange(
                reasonCode:
                    "semantic_index_attached_source_consent_revoked"
            )
        let authorityPrepared = await authorityTransaction.prepare()
        XCTAssertTrue(authorityPrepared)
        XCTAssertTrue(try XCTUnwrap(
            store.attachedDataSource(id: sourceID)
        ).localModelConsentEnabled)
        XCTAssertFalse(try XCTUnwrap(model.chatController)
            .attachedSourceRetrievalAuthorityIsOpen)
        XCTAssertNil(model.chatController?.newConversation())
        do {
            _ = try await source.vaultItemSnapshot(
                id: "attached-selected-record",
                attachedSourceAuthority: requestAuthority
            )
            XCTFail(
                "Attached Vault reads must stay closed after semantic purge and before canonical resolution."
            )
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }
        features.rebuildSemanticIndex()
        await features.waitForCurrentWork()
        XCTAssertEqual(features.semanticHealth?.state, .empty)
        XCTAssertNil(features.semanticHealth?.activeGeneration)
        let authorityAborted = await authorityTransaction.abort(
            canonicalStateUnchanged: true
        )
        XCTAssertTrue(authorityAborted)
        XCTAssertTrue(try XCTUnwrap(model.chatController)
            .attachedSourceRetrievalAuthorityIsOpen)
        _ = try await source.vaultItemSnapshot(
            id: "attached-selected-record",
            attachedSourceAuthority: requestAuthority
        )

        let attachedController =
            model.connectorSourcesController.attachedDataSourcesController
        let consentRevoked = await attachedController.setLocalModelConsent(
            sourceIdentifier: sourceID,
            enabled: false
        )
        XCTAssertTrue(consentRevoked)
        XCTAssertTrue(features.semanticResults.isEmpty)
        XCTAssertEqual(features.semanticHealth?.state, .empty)
        XCTAssertNil(features.semanticHealth?.activeGeneration)
        XCTAssertFalse(try XCTUnwrap(
            store.attachedDataSource(id: sourceID)
        ).localModelConsentEnabled)
        do {
            _ = try await source.vaultItemSnapshot(
                id: "attached-selected-record",
                attachedSourceAuthority: requestAuthority
            )
            XCTFail("Revoked attached-source consent must take effect immediately.")
        } catch let error as AgentLokiToolFailure {
            XCTAssertEqual(error.code, .dataUnavailable)
        }
        let revokedSources = try await source.connectedSourcesSnapshot(limit: 10)
        XCTAssertFalse(revokedSources.records.contains { $0.id == sourceID })
    }

    func testLiveDataSourceRejectsQuarantinedAttachedAuthorityWithoutDigests()
        async throws
    {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient(),
            currentCivilDayProvider: {
                LocalCalendarDay.resolve(containing: Self.fixedDate)
            }
        )
        let dataSource = LiveAgentLokiToolDataSource(model: model)
        let sourceID = "attached-quarantined-source"
        let selectionID = "attached-quarantined-selection"
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID
        )
        let containerID = VaultIdentity.containerID(
            provider: VaultProviderKind.localImport.rawValue,
            accountID: accountID,
            providerContainerID: selectionID
        )
        var quarantined = try Self.attachedDataSourceRecord(
            id: sourceID,
            selectionID: selectionID,
            containerID: containerID,
            retained: true,
            localModelConsentEnabled: true
        )
        quarantined.state = .degraded
        quarantined.sourceDigest = nil
        quarantined.shapeDigest = nil
        quarantined.lastErrorReasonCode = AttachedDataSourceFailureCode
            .operationInterruptedByRestart.rawValue
        try quarantined.validate()
        try store.saveAttachedDataSource(quarantined)
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: containerID,
            providerContainerID: selectionID,
            recordID: "attached-quarantined-record",
            recordKind: "sqlite_row",
            metadata: Self.attachedVaultMetadata(
                sourceID: sourceID,
                selectionID: selectionID,
                generationID: "generation-1"
            )
        )

        let decision = await dataSource.authorizationDecision(
            for: .source(id: sourceID)
        )
        XCTAssertFalse(decision.allowed)
        let connected = try await dataSource.connectedSourcesSnapshot(limit: 10)
        XCTAssertFalse(connected.records.contains { $0.id == sourceID })
        let semantic = try await dataSource.permittedVaultSemanticRecords()
        XCTAssertFalse(semantic.contains {
            $0.provenance.provider == VaultProviderKind.localImport.rawValue
                && $0.provenance.pseudonymousAccountIdentifier == sourceID
        })
    }

    func testLiveAttachedSourceSearchAndItemDenyStaleOrMalformedProvenance()
        async throws
    {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient(),
            currentCivilDayProvider: {
                LocalCalendarDay.resolve(containing: Self.fixedDate)
            }
        )
        let dataSource = LiveAgentLokiToolDataSource(model: model)
        let sourceID = "attached-stale-source"
        let selectionID = "attached-stale-selection"
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID
        )
        let containerID = VaultIdentity.containerID(
            provider: VaultProviderKind.localImport.rawValue,
            accountID: accountID,
            providerContainerID: selectionID
        )
        try store.saveAttachedDataSource(try Self.attachedDataSourceRecord(
            id: sourceID,
            selectionID: selectionID,
            containerID: containerID,
            retained: true,
            localModelConsentEnabled: true
        ))
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: containerID,
            providerContainerID: selectionID,
            recordID: "attached-stale-generation-record",
            recordKind: "sqlite_row",
            metadata: Self.attachedVaultMetadata(
                sourceID: sourceID,
                selectionID: selectionID,
                generationID: "generation-2"
            )
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: containerID,
            providerContainerID: selectionID,
            recordID: "attached-missing-generation-record",
            recordKind: "sqlite_row",
            metadata: Self.attachedVaultMetadata(
                sourceID: sourceID,
                selectionID: selectionID,
                generationID: nil
            )
        )
        try await Self.upsertVaultFixture(
            database: model.vaultController.database,
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceID,
            accountID: accountID,
            containerID: containerID,
            providerContainerID: selectionID,
            recordID: "attached-wrong-digest-record",
            recordKind: "sqlite_row",
            metadata: Self.attachedVaultMetadata(
                sourceID: sourceID,
                selectionID: selectionID,
                generationID: "generation-1",
                sourceDigest: String(repeating: "b", count: 64)
            )
        )
        let authority = AgentLokiAttachedSourceRequestAuthority(
            sourceIdentifier: sourceID,
            accountIdentifier: accountID,
            containerIdentifiers: [containerID],
            generationIdentifier: "generation-1",
            sourceEpoch: 1,
            sourceDigest: String(repeating: "a", count: 64)
        )

        for recordID in [
            "attached-stale-generation-record",
            "attached-missing-generation-record",
            "attached-wrong-digest-record",
        ] {
            let decision = await dataSource.authorizationDecision(
                for: .attachedSourceVaultItem(
                    authority: authority,
                    id: recordID
                )
            )
            XCTAssertFalse(decision.allowed)
            do {
                _ = try await dataSource.vaultItemSnapshot(
                    id: recordID,
                    attachedSourceAuthority: authority
                )
                XCTFail("Mismatched or missing attached provenance must fail closed.")
            } catch let error as AgentLokiToolFailure {
                XCTAssertEqual(error.code, .dataUnavailable)
            }
        }

        let search = try await dataSource.searchVaultText(.init(
            text: "Bounded fixture",
            accountID: accountID,
            containerID: containerID,
            startDate: nil,
            endDate: nil,
            limit: 10,
            attachedSourceAuthority: authority
        ))
        XCTAssertTrue(search.records.isEmpty)
        XCTAssertTrue(search.evidence.isEmpty)
        XCTAssertTrue(search.wasTruncated)
    }

    func testPermittedVaultSemanticRecordsFailsClosedWhenLaterAuthorizedContainerExceedsExactCap()
        async throws
    {
        let store = try LocalStore(inMemory: true)
        let firstFeed = Self.feedSubscription(
            id: "a-p8-semantic-feed",
            title: "First P8 Semantic Feed",
            path: "first"
        )
        let secondFeed = Self.feedSubscription(
            id: "b-p8-semantic-feed",
            title: "Second P8 Semantic Feed",
            path: "second"
        )
        try store.persistFeedSubscription(firstFeed)
        try store.persistFeedSubscription(secondFeed)
        var settings = try store.lokiChatPrivacySettings()
        settings.allowFeedEvidence = true
        try store.updateLokiChatPrivacySettings(settings)
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient(),
            currentCivilDayProvider: {
                LocalCalendarDay.resolve(containing: Self.fixedDate)
            }
        )
        let accountID = VaultIdentity.accountID(
            provider: "rss",
            providerAccountID: "local-feeds"
        )
        for (feed, recordID) in [
            (firstFeed, "a-p8-semantic-record"),
            (secondFeed, "b-p8-semantic-record"),
        ] {
            try await Self.upsertVaultFixture(
                database: model.vaultController.database,
                provider: "rss",
                providerAccountID: "local-feeds",
                accountID: accountID,
                containerID: VaultIdentity.containerID(
                    provider: "rss",
                    accountID: accountID,
                    providerContainerID: feed.id
                ),
                providerContainerID: feed.id,
                recordID: recordID
            )
        }
        let source = LiveAgentLokiToolDataSource(
            model: model,
            semanticSourcePreparationBudget: .init(
                maximumRecords: 1,
                maximumTotalTextBytes: 1_024,
                maximumRecordTextBytes: 1_024
            )
        )

        do {
            _ = try await source.permittedVaultSemanticRecords()
            XCTFail(
                "An authorized record beyond an exact container-boundary cap must fail closed."
            )
        } catch let failure as P8SemanticSourcePreparationFailure {
            XCTAssertEqual(failure, .recordLimitExceeded)
        }
    }

    private func makeFixture(
        store: LocalStore,
        suspendCurrentBrief: Bool,
        snapshotEvidence: [AgentLokiEvidenceExcerpt] = [],
        contextEvidence: [AgentLokiEvidenceExcerpt] = [],
        evidenceScrubPreflight: @escaping @MainActor () throws -> Void = {}
    ) throws -> Fixture {
        let model = try AppModel(
            store: store,
            feedClient: LokiChatLifecycleFeedClient()
        )
        let assessment = Self.readyAssessment()
        try store.upsertLokiModelAssessment(.init(
            id: "ollama:synthetic-controller-model:latest:controller-fixture",
            readiness: .ready,
            assessment: assessment
        ))

        let transport = LokiChatControlledTransport()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let toolDataSource = LokiChatLifecycleToolDataSource(
            suspendCurrentBrief: suspendCurrentBrief,
            snapshotEvidence: snapshotEvidence,
            contextEvidence: contextEvidence
        )
        let toolExecutor = AgentLokiReadOnlyToolExecutor(
            dataSource: toolDataSource,
            traceLogger: .init(sink: { _ in }),
            now: { Self.fixedDate }
        )
        let traces = LokiChatLifecycleTraceRecorder()
        let controller = try LokiChatController(
            model: model,
            store: store,
            provider: provider,
            toolExecutor: toolExecutor,
            contextEvidenceProvider: toolDataSource,
            evidenceScrubPreflight: evidenceScrubPreflight,
            traceSink: { event in traces.record(event) }
        )
        controller.synchronizeOllamaCatalog(
            models: [Self.modelDescriptor()],
            status: .init(
                state: .connected,
                checkedAt: Self.fixedDate,
                lastSuccessfulCheckAt: Self.fixedDate,
                discoveredModelCount: 1,
                selectedModelID: nil,
                lastFailureCode: nil
            ),
            providerVersion: Self.providerVersion
        )
        controller.selectModelForChat(id: Self.modelIdentifier)
        XCTAssertEqual(controller.selectedChatModelID, Self.modelIdentifier)
        XCTAssertEqual(controller.selectedModelReadinessPresentation().readiness, .ready)
        return .init(
            store: store,
            model: model,
            controller: controller,
            transport: transport,
            toolExecutor: toolExecutor,
            toolDataSource: toolDataSource,
            traces: traces
        )
    }

    private func eventually(
        _ description: String,
        condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .seconds(2)
        )
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000)
        }
        XCTFail("Timed out waiting for \(description).")
        throw LokiChatLifecycleTestFailure.timedOut(description)
    }

    private static func modelDescriptor() -> OllamaModelDescriptor {
        .init(
            id: modelIdentifier,
            name: "Synthetic Controller Model",
            modifiedAt: nil,
            sizeBytes: 1,
            digest: modelDigest,
            format: "gguf",
            family: "synthetic",
            families: ["synthetic"],
            parameterSize: "test",
            quantizationLevel: "test"
        )
    }

    private static func evidence(
        id: String,
        label: String
    ) -> AgentLokiEvidenceExcerpt {
        .init(
            reference: .init(
                id: id,
                sourceKind: .brief,
                sourceItemID: id,
                retrievedAt: fixedDate,
                boundedLabel: label,
                contentOrigin: .applicationState,
                trust: .localApplicationState,
                claimBasis: .observed
            ),
            text: "\(label) bounded content."
        )
    }

    private static func decodeExport(_ data: Data) throws -> LokiChatExportSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LokiChatExportSnapshot.self, from: data)
    }

    private static func feedSubscription(
        id: String = "p7-live-source-feed",
        title: String = "P7 Live Source Feed",
        path: String = "feed"
    ) -> FeedSubscription {
        FeedSubscription(
            id: id,
            title: title,
            canonicalURL: URL(string: "https://example.com/\(path).xml")!,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: fixedDate,
            lastSuccessfulAt: fixedDate,
            lastHTTPStatus: 200,
            eTag: nil,
            lastModified: nil,
            state: .connected,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
    }

    private static func feedBrief(subscription: FeedSubscription) -> Brief {
        let source = BriefSource(
            id: subscription.id,
            name: subscription.title,
            kind: .newsFeeds,
            state: .connected,
            capabilities: [.feeds],
            detail: "Synthetic P7 feed"
        )
        let item = BriefItem(
            id: "p7-feed-item",
            title: "Authorized feed title",
            summary: "SOURCE_SUMMARY_MUST_NOT_LEAK",
            priority: .normal,
            source: source,
            provenance: .init(
                sourceID: subscription.id,
                publicationDate: fixedDate,
                retrievedAt: fixedDate,
                directURL: URL(string: "https://example.com/item"),
                isSynthetic: true,
                origin: .source,
                format: "rss2",
                upstreamIdentifier: "p7-feed-item"
            ),
            isRead: false
        )
        return Brief(
            id: "p7-feed-brief",
            date: fixedDate,
            title: "P7 Feed Brief",
            summary: "SOURCE_SUMMARY_MUST_NOT_LEAK",
            status: .ready,
            sections: [
                .init(id: "feed", title: "Feed", items: [item]),
            ],
            generation: .init(
                engineID: "p7-test",
                generatedAt: fixedDate,
                status: .ready,
                reasonCode: "p7_test",
                fixtureRevision: 1
            )
        )
    }

    private static func slackWorkspace() -> SlackWorkspaceConnection {
        let identifier = SlackWorkspaceConnection.stableID(
            teamID: "T-P7",
            userID: "U-P7"
        )
        return SlackWorkspaceConnection(
            id: identifier,
            teamID: "T-P7",
            teamName: "P7 Workspace",
            userID: "U-P7",
            userDisplayName: "P7 User",
            state: .connected,
            grantedScopes: Set(SlackGrantedScope.allCases),
            credentialMetadata: nil,
            localModelConsent: true,
            connectedAt: fixedDate,
            updatedAt: fixedDate,
            lastFailureReasonCode: nil
        )
    }

    private static func upsertVaultFixture(
        database: VaultDatabase,
        provider: String,
        providerAccountID: String,
        accountID: String,
        containerID: String,
        providerContainerID: String,
        recordID: String,
        recordKind: String = "message",
        metadata: [String: String] = [:]
    ) async throws {
        _ = try await database.upsert(account: .init(
            id: accountID,
            provider: provider,
            providerAccountID: providerAccountID,
            displayName: "\(provider) fixture",
            createdAt: fixedDate,
            updatedAt: fixedDate
        ))
        _ = try await database.upsert(container: .init(
            id: containerID,
            accountID: accountID,
            providerContainerID: providerContainerID,
            kind: "channel",
            displayName: "Fixture container",
            createdAt: fixedDate,
            updatedAt: fixedDate
        ))
        _ = try await database.upsert(record: .init(
            id: recordID,
            accountID: accountID,
            containerID: containerID,
            providerRecordID: recordID,
            kind: recordKind,
            title: "Fixture record",
            body: "Bounded fixture body",
            occurredAt: fixedDate,
            capturedAt: fixedDate,
            modifiedAt: fixedDate,
            metadata: metadata
        ))
    }

    private static func attachedDataSourceRecord(
        id: String,
        selectionID: String,
        containerID: String,
        retained: Bool,
        localModelConsentEnabled: Bool,
        updatedAt: Date = fixedDate
    ) throws -> AttachedDataSourceRecord {
        let selection = try AttachedDataSourceSelection(
            id: selectionID,
            kind: .sqliteTable,
            sourceIdentifier: "private_tasks",
            displayName: "Private Tasks",
            selectedFields: ["id", "title"],
            searchableFields: ["title"],
            identityFields: ["id"],
            recordIdentityStrategy: .declaredPrimaryKey,
            schemaDigest: String(repeating: "c", count: 64),
            estimatedRecordCount: retained ? 1 : 0,
            estimatedBytes: retained ? 128 : 0
        )
        return try AttachedDataSourceRecord(
            id: id,
            kind: .sqlite,
            mode: .importedSnapshot,
            displayName: "PRIVATE_FILENAME_MUST_NOT_LEAK",
            originalFilename: "private.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            fileIdentity: .init(
                deviceID: 1,
                inode: 2,
                fileType: 0o100000,
                linkCount: 1,
                fileSize: 128,
                modificationNanoseconds: 1_785_000_000_000_000_000
            ),
            sourceDigest: String(repeating: "a", count: 64),
            shapeDigest: String(repeating: "b", count: 64),
            state: .connected,
            selections: [selection],
            currentEpoch: retained ? 1 : 0,
            lastSuccessfulRefreshAt: retained ? fixedDate : nil,
            lastAttemptedRefreshAt: fixedDate,
            itemCount: retained ? 1 : 0,
            importedLocalContainerIdentifiers: retained ? [containerID] : [],
            localDataRetentionState: retained ? .retained : .none,
            currentGenerationIdentifier: retained ? "generation-1" : nil,
            access: .notRetained,
            localModelConsentEnabled: localModelConsentEnabled,
            createdAt: fixedDate,
            updatedAt: updatedAt
        )
    }

    private static func attachedVaultMetadata(
        sourceID: String,
        selectionID: String,
        generationID: String?,
        sourceDigest: String = String(repeating: "a", count: 64)
    ) -> [String: String] {
        var metadata = [
            "connector_policy": ConnectorRecordPolicyClassification
                .localIndexAllowed.rawValue,
            "connector_content_classification":
                ConnectorRecordContentClassification.providerRecord.rawValue,
            "attached_source_id": sourceID,
            "attached_source_kind": "sqlite",
            "attached_source_epoch": "1",
            "attached_source_sha256": sourceDigest,
            "attached_selection_id": selectionID,
            "attached_selection_source": "private_tasks",
            "attached_schema_sha256": String(repeating: "c", count: 64),
            "attached_record_locator": "private_tasks",
            "attached_identity_strategy": "declared_primary_key",
            "attached_generation_receipt_sha256":
                String(repeating: "d", count: 64),
            "connector_page_receipt_sha256":
                String(repeating: "e", count: 64),
            "attached_truncated": "false",
        ]
        metadata["attached_generation_id"] = generationID
        return metadata
    }

    private static func readyAssessment() -> ModelCapabilityAssessment {
        let required: Set<ModelCapability> = [
            .chat,
            .streaming,
            .structuredOutput,
            .toolCalling,
            .cancellation,
            .systemInstructions,
            .contextWindow,
        ]
        return .init(
            provider: "ollama",
            providerVersion: providerVersion,
            modelIdentifier: modelIdentifier,
            modelDigest: modelDigest,
            assessmentVersion: "agent-loki.model-assessment.v2",
            capabilitiesProven: required,
            capabilitiesMissing: Set(ModelCapability.allCases).subtracting(required),
            contextPolicy: .init(
                declaredContextTokens: 131_072,
                empiricallyUsableContextTokens: 65_536
            ),
            assessedAt: fixedDate,
            durationMilliseconds: 10,
            diagnostics: []
        )
    }

    private static func embeddingReadyAssessment(
        modelIdentifier: String,
        digest: String,
        providerVersion: String,
        dimension: Int
    ) -> ModelCapabilityAssessment {
        let profile = OllamaEmbeddingRequestProfile(
            dimensions: dimension
        )
        let stability = EmbeddingStabilityAssessmentSummary(
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            ollamaVersion: providerVersion,
            requestProfileVersion: profile.version,
            requestProfileHash: profile.stableHash,
            observedDimension: dimension,
            explicitDimensions: dimension,
            truncate: profile.truncate,
            normalizationVersion: profile.normalizationVersion,
            repetitionCount: 3,
            requestIdentityVerified: true,
            parserParityVerified: true,
            allValuesFinite: true,
            zeroVectorDetected: false,
            differentInputCollapseDetected: false,
            minimumCosineSimilarity: 1,
            maximumRelativeL2NormDrift: 0,
            minimumL2Norm: 1,
            maximumL2Norm: 1,
            maximumAbsoluteComponentDelta: 0,
            maximumRMSComponentDelta: 0,
            stableTop1: true,
            stableOrderedTop5: true,
            minimumRankingMargin: 0.25,
            rankingHashes: (1...5).map {
                String(repeating: String($0), count: 64)
            },
            reasonCodes: [
                EmbeddingAssessmentReasonCode
                    .requestIdentityVerified.rawValue,
                EmbeddingAssessmentReasonCode
                    .parserParityVerified.rawValue,
                EmbeddingAssessmentReasonCode
                    .boundedNumericalVariance.rawValue,
                EmbeddingAssessmentReasonCode
                    .retrievalStabilityVerified.rawValue,
            ]
        )
        return .init(
            provider: "ollama",
            providerVersion: providerVersion,
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            capabilitiesProven: [.embedding],
            capabilitiesMissing:
                Set(ModelCapability.allCases).subtracting([.embedding]),
            contextPolicy: .init(declaredContextTokens: nil),
            assessedAt: fixedDate,
            durationMilliseconds: 1,
            diagnostics: [],
            embeddingStability: stability
        )
    }

    private static func chatChunk(
        content: String = "",
        thinking: String = "",
        toolName: String? = nil,
        arguments: [String: Any] = [:],
        done: Bool,
        modelIdentifier: String = "synthetic-controller-model:latest"
    ) throws -> Data {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        if !thinking.isEmpty {
            message["thinking"] = thinking
        }
        if let toolName {
            message["tool_calls"] = [[
                "id": "synthetic-tool-call",
                "function": [
                    "name": toolName,
                    "arguments": arguments,
                ],
            ]]
        }
        var object: [String: Any] = [
            "model": modelIdentifier,
            "message": message,
            "done": done,
        ]
        if done {
            object["done_reason"] = "stop"
            object["total_duration"] = 5_000_000
            object["prompt_eval_count"] = 4
            object["eval_count"] = 2
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
    }
}

private enum LokiChatLifecycleTestFailure: Error {
    case timedOut(String)
}
