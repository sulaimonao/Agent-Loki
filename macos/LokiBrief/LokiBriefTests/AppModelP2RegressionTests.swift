import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

private enum AppModelP2Fixture {
    static let anchor = Date(timeIntervalSince1970: 1_760_000_000)
    static let modelID = "gpt-oss:20b"

    static func modelDescriptor() -> OllamaModelDescriptor {
        .init(
            id: modelID,
            name: modelID,
            modifiedAt: "2026-07-15T10:00:00Z",
            sizeBytes: 3_338_801_804,
            digest: "fixture-digest",
            format: "gguf",
            family: "gemma",
            families: ["gemma"],
            parameterSize: "4.3B",
            quantizationLevel: "Q4_K_M"
        )
    }

    static func versionData() throws -> Data {
        try jsonData(["version": "0.30.6"])
    }

    static func tagsData(models: [OllamaModelDescriptor] = [modelDescriptor()]) throws -> Data {
        let values: [[String: Any]] = models.map { model in
            [
                "name": model.name,
                "model": model.id,
                "modified_at": model.modifiedAt as Any,
                "size": model.sizeBytes as Any,
                "digest": model.digest as Any,
                "details": [
                    "format": model.format as Any,
                    "family": model.family as Any,
                    "families": model.families,
                    "parameter_size": model.parameterSize as Any,
                    "quantization_level": model.quantizationLevel as Any,
                ],
            ]
        }
        return try jsonData(["models": values])
    }

    static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func subscription() -> FeedSubscription {
        .init(
            id: "app-model-p2-source",
            title: "AppModel P2 Fixture",
            canonicalURL: URL(string: "https://feeds.example.com/app-model-p2.xml")!,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: nil,
            lastSuccessfulAt: nil,
            lastHTTPStatus: nil,
            eTag: nil,
            lastModified: nil,
            state: .savedUnavailable,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: anchor.addingTimeInterval(-86_400),
            updatedAt: anchor.addingTimeInterval(-86_400)
        )
    }

    static func connected(_ source: FeedSubscription) -> FeedSubscription {
        var result = source
        result.lastAttemptedAt = anchor
        result.lastSuccessfulAt = anchor
        result.lastHTTPStatus = 200
        result.state = .connected
        result.updatedAt = anchor
        return result
    }

    static func entry(
        id: String,
        source: FeedSubscription,
        title: String,
        summary: String,
        position: Int
    ) -> NormalizedFeedEntry {
        let itemURL = URL(string: "https://example.com/app-model-p2/\(id)")!
        return .init(
            id: id,
            identity: .init(value: id, basis: .upstreamIdentifier),
            subscriptionID: source.id,
            sourceTitle: source.title,
            title: title,
            summary: summary,
            canonicalURL: itemURL,
            author: "Loki Test Fixture",
            publishedAt: anchor.addingTimeInterval(-Double(position + 1) * 60),
            updatedAt: nil,
            retrievedAt: anchor,
            originalPosition: position,
            provenance: .init(
                subscriptionID: source.id,
                feedURL: source.canonicalURL,
                format: .rss2,
                upstreamIdentifier: id,
                retrievedAt: anchor,
                originalPosition: position
            )
        )
    }

    static func fetchResult(
        source: FeedSubscription,
        entries: [NormalizedFeedEntry]
    ) -> FeedFetchResult {
        let connectedSource = connected(source)
        return .init(
            subscription: connectedSource,
            entries: entries,
            record: .init(
                id: "fetch-app-model-p2-\(entries.count)",
                subscriptionID: source.id,
                traceID: "trace-app-model-p2",
                attemptedAt: anchor,
                completedAt: anchor,
                httpStatus: 200,
                responseByteCount: 2_048,
                parsedEntryCount: entries.count,
                finalURL: source.canonicalURL,
                eTag: "fixture-etag",
                lastModified: nil,
                wasNotModified: false
            ),
            warnings: []
        )
    }
}

private actor AppModelP2FeedRetriever: FeedRetrieving {
    private let result: FeedFetchResult?

    init(result: FeedFetchResult? = nil) {
        self.result = result
    }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        guard let result, result.subscription.id == subscription.id else {
            throw FeedFetchFailure(.networkUnavailable, message: "No scripted AppModel P2 feed response.")
        }
        return result
    }

    func cancelAll() async { }
}

private actor AppModelP2OllamaTransport: OllamaTransporting {
    enum Action: Sendable {
        case response(status: Int, data: Data)
        case structuredGenerationSuccess
        case waitForCancellation
    }

    struct EvidenceCapture: Sendable, Equatable {
        let deterministicBriefID: String
        let allowedSectionIDs: [String]
        let selectedItemIDs: [String]
        let selectedSectionIDs: [String]
    }

    private var actions: [Action]
    private var requestURLs: [String] = []
    private var evidenceCaptures: [EvidenceCapture] = []
    private var pending: [UUID: CheckedContinuation<OllamaTransportResponse, Error>] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var cancellationCount = 0

    init(actions: [Action]) {
        self.actions = actions
    }

    func data(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) async throws -> OllamaTransportResponse {
        requestURLs.append(request.url?.absoluteString ?? "")
        guard !actions.isEmpty else { throw OllamaFailure(.invalidResponse) }

        switch actions.removeFirst() {
        case let .response(status, data):
            guard data.count <= responseLimit else { throw OllamaFailure(.responseTooLarge) }
            return .init(data: data, statusCode: status, finalURL: request.url)
        case .structuredGenerationSuccess:
            let result = try structuredGenerationResponse(for: request)
            guard result.count <= responseLimit else { throw OllamaFailure(.responseTooLarge) }
            return .init(data: result, statusCode: 200, finalURL: request.url)
        case .waitForCancellation:
            if cancelledBeforeRegistration.remove(requestID) != nil {
                throw URLError(.cancelled)
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
            }
        }
    }

    func cancel(requestID: UUID) async {
        cancellationCount += 1
        if let continuation = pending.removeValue(forKey: requestID) {
            continuation.resume(throwing: URLError(.cancelled))
        } else {
            cancelledBeforeRegistration.insert(requestID)
        }
    }

    func requestCount() -> Int { requestURLs.count }
    func recordedURLs() -> [String] { requestURLs }
    func recordedEvidence() -> [EvidenceCapture] { evidenceCaptures }
    func recordedCancellationCount() -> Int { cancellationCount }

    private func structuredGenerationResponse(for request: URLRequest) throws -> Data {
        guard let body = request.httpBody,
              let bodyObject = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = bodyObject["model"] as? String,
              let prompt = bodyObject["prompt"] as? String,
              let marker = prompt.range(of: "UNTRUSTED_EVIDENCE_JSON:", options: .backwards)
        else {
            throw OllamaFailure(.invalidResponse)
        }

        let evidenceText = prompt[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let evidenceData = evidenceText.data(using: .utf8),
              let evidence = try JSONSerialization.jsonObject(with: evidenceData) as? [String: Any],
              let briefID = evidence["deterministic_brief_id"] as? String,
              let allowedSectionIDs = evidence["allowed_section_ids"] as? [String],
              let items = evidence["items"] as? [[String: Any]]
        else {
            throw OllamaFailure(.invalidResponse)
        }

        let itemIDs = try items.map { item -> String in
            guard let value = item["id"] as? String else { throw OllamaFailure(.invalidResponse) }
            return value
        }
        let sectionIDs = try items.map { item -> String in
            guard let value = item["section_id"] as? String else { throw OllamaFailure(.invalidResponse) }
            return value
        }
        evidenceCaptures.append(.init(
            deterministicBriefID: briefID,
            allowedSectionIDs: allowedSectionIDs,
            selectedItemIDs: itemIDs,
            selectedSectionIDs: sectionIDs
        ))

        let output = try AppModelP2Fixture.jsonData([
            "schema_version": OllamaOutputValidator.schemaVersion,
            "brief_id": briefID,
            "overall_summary": "A bounded local summary was generated from selected evidence.",
            "section_summaries": allowedSectionIDs.map {
                ["section_id": $0, "summary": "Selected evidence for \($0) was summarized locally."]
            },
            "item_summaries": [],
        ])
        return try AppModelP2Fixture.jsonData([
            "model": model,
            "response": String(decoding: output, as: UTF8.self),
            "done": true,
            "total_duration": 12_000_000,
            "prompt_eval_count": 40,
            "eval_count": 20,
        ])
    }
}

private final class AppModelOllamaSynchronizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OllamaRuntimeSynchronizationEvent] = []

    func record(_ event: OllamaRuntimeSynchronizationEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [OllamaRuntimeSynchronizationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@MainActor
final class AppModelP2RegressionTests: XCTestCase, @unchecked Sendable {
    func testP8OnlyWorkBlocksApplicationUpdateReadinessAndLifecyclePauseDrains()
        async throws
    {
        let model = try AppModel(
            store: LocalStore(inMemory: true),
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: NativeOllamaProvider()
        )
        let chat = try XCTUnwrap(model.chatController)
        await chat.p8Features.waitForCurrentWork()
        let baselineReady = await eventually {
            model.assessApplicationUpdateReadiness().status == .ready
        }
        XCTAssertTrue(baselineReady)

        chat.p8Features
            .configurePermittedVaultSemanticRecordsProvider {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        await chat.p8Features.waitForCurrentWork()
        chat.p8Features.semanticBuildSourceKinds = [.vaultRecord]
        chat.p8Features.rebuildSemanticIndex()
        let becameActive = await eventually {
            chat.p8Features.hasActiveWork
        }
        XCTAssertTrue(becameActive)

        let blocked = model.assessApplicationUpdateReadiness()
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.reasonCode, .activeChatP8Work)

        await chat.p8Features.prepareForLifecyclePause()
        XCTAssertFalse(chat.p8Features.hasActiveWork)
        chat.p8Features.resumeAfterLifecyclePause()
    }

    func testLocalSummaryTestIsBlockedWhileToggleIsOffWithoutProviderRequest() async throws {
        let transport = AppModelP2OllamaTransport(actions: [])
        let provider = NativeOllamaProvider(
            enabled: true,
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider
        )

        XCTAssertFalse(model.localGenerationEnabled)
        model.testLocalSummary()

        XCTAssertEqual(
            model.errorMessage,
            "Enable Ollama brief summaries before running the local summary test."
        )
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(try store.latestGenerationProvenance())
    }

    func testPreviouslyEnabledProviderSynchronizesVersionCatalogSelectionAndChatOnRelaunch() async throws {
        let store = try LocalStore(inMemory: true)
        let successfulCheck = AppModelP2Fixture.anchor.addingTimeInterval(-60)
        let failedCheck = AppModelP2Fixture.anchor
        let descriptor = AppModelP2Fixture.modelDescriptor()
        let selection = OllamaModelSelection(
            model: descriptor,
            catalogRevision: 7,
            selectedAt: successfulCheck
        )
        try store.persistModelCatalog(.init(
            revision: 7,
            discoveredAt: successfulCheck,
            models: [descriptor],
            excludedCloudModelCount: 0
        ))
        try store.persistModelSelection(selection, enabled: true)
        try store.upsertProviderSnapshot(.init(
            stateRaw: OllamaRuntimeState.degraded.rawValue,
            checkedAt: failedCheck,
            lastSuccessfulCheckAt: successfulCheck,
            serviceVersion: "0.30.6",
            failureCode: OllamaFailureCode.serviceUnavailable.rawValue,
            failureMessage: "The local Ollama service was unavailable during the previous check."
        ))

        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
        ])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let recorder = AppModelOllamaSynchronizationRecorder()
        let relaunched = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider,
            ollamaSynchronizationEventSink: { recorder.record($0) }
        )

        let synchronized = await eventually {
            relaunched.ollamaStatus.state == .modelSelected
                && relaunched.chatController?
                    .selectedModelReadinessPresentation().readiness
                    != .providerNotRunning
        }
        XCTAssertTrue(synchronized)
        guard synchronized else { return }

        XCTAssertEqual(relaunched.localModels.map(\.id), [AppModelP2Fixture.modelID])
        XCTAssertEqual(relaunched.selectedModelID, AppModelP2Fixture.modelID)
        XCTAssertFalse(relaunched.localGenerationEnabled)
        XCTAssertEqual(relaunched.ollamaStatus.checkedAt, AppModelP2Fixture.anchor)
        XCTAssertEqual(relaunched.ollamaStatus.lastSuccessfulCheckAt, AppModelP2Fixture.anchor)
        XCTAssertNil(relaunched.ollamaStatus.lastFailureCode)
        XCTAssertEqual(
            relaunched.localGenerationMessage,
            "Ollama 0.30.6 · 1 installed model."
        )
        XCTAssertEqual(
            relaunched.chatController?.selectedModelReadinessPresentation().providerName,
            "Ollama"
        )
        let runtimeStatus = await provider.status()
        XCTAssertEqual(runtimeStatus.state, .modelSelected)
        let recordedURLs = await transport.recordedURLs()
        XCTAssertEqual(
            recordedURLs,
            [
                "http://127.0.0.1:11434/api/version",
                "http://127.0.0.1:11434/api/tags",
            ]
        )
        let persisted = try XCTUnwrap(store.providerSnapshot())
        XCTAssertEqual(persisted.stateRaw, OllamaRuntimeState.modelSelected.rawValue)
        XCTAssertEqual(persisted.serviceVersion, "0.30.6")
        XCTAssertNil(persisted.failureCode)

        let events = recorder.snapshot()
        XCTAssertEqual(events.first?.trigger, .startup)
        XCTAssertEqual(events.first?.status, .started)
        XCTAssertEqual(events.last?.trigger, .startup)
        XCTAssertEqual(events.last?.status, .success)
        XCTAssertEqual(
            events.last?.reasonCode,
            "ollama_runtime_synchronization_succeeded"
        )
        XCTAssertEqual(events.first?.traceID, events.last?.traceID)
        let encodedEvents = try JSONEncoder().encode(events)
        let eventText = try XCTUnwrap(String(data: encodedEvents, encoding: .utf8))
        XCTAssertFalse(eventText.contains(AppModelP2Fixture.modelID))
        XCTAssertFalse(eventText.lowercased().contains("previous check"))
    }

    func testMissingInvalidAndExplicitlyDisabledSnapshotsRemainNetworkSilent() async throws {
        for stateRaw: String? in [
            nil,
            "future_unknown_state",
            OllamaRuntimeState.disabled.rawValue,
        ] {
            let store = try LocalStore(inMemory: true)
            if let stateRaw {
                try store.upsertProviderSnapshot(.init(
                    stateRaw: stateRaw,
                    checkedAt: AppModelP2Fixture.anchor
                ))
            }
            let transport = AppModelP2OllamaTransport(actions: [])
            let provider = NativeOllamaProvider(
                transport: transport,
                now: { AppModelP2Fixture.anchor }
            )
            let model = try AppModel(
                store: store,
                feedClient: AppModelP2FeedRetriever(),
                ollamaProvider: provider
            )

            for _ in 0..<20 { await Task.yield() }

            let requestCount = await transport.requestCount()
            let runtimeStatus = await provider.status()
            XCTAssertEqual(requestCount, 0, stateRaw ?? "missing")
            XCTAssertEqual(model.ollamaStatus.state, .disabled, stateRaw ?? "missing")
            XCTAssertEqual(runtimeStatus.state, .disabled, stateRaw ?? "missing")
        }
    }

    func testManualCheckCoalescesWithStartupAndExplicitDisableCancelsAndDrains() async throws {
        let store = try LocalStore(inMemory: true)
        try store.upsertProviderSnapshot(.init(
            stateRaw: OllamaRuntimeState.connected.rawValue,
            checkedAt: AppModelP2Fixture.anchor
        ))
        let transport = AppModelP2OllamaTransport(actions: [.waitForCancellation])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let recorder = AppModelOllamaSynchronizationRecorder()
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider,
            ollamaSynchronizationEventSink: { recorder.record($0) }
        )
        let startupRequestStarted = await eventually {
            await transport.requestCount() == 1
        }
        XCTAssertTrue(startupRequestStarted)
        guard startupRequestStarted else { return }

        model.checkOllama()
        for _ in 0..<20 { await Task.yield() }
        let coalescedRequestCount = await transport.requestCount()
        XCTAssertEqual(coalescedRequestCount, 1)
        XCTAssertTrue(recorder.snapshot().contains {
            $0.trigger == .manual
                && $0.status == .skipped
                && $0.reasonCode == "ollama_runtime_synchronization_coalesced"
        })

        model.disableOllama()
        let drained = await eventually {
            let status = await provider.status()
            let cancellationCount = await transport.recordedCancellationCount()
            return status.state == .disabled
                && cancellationCount > 0
                && !model.hasUpdateBlockingRuntimeWork
        }
        XCTAssertTrue(drained)
        XCTAssertEqual(model.ollamaStatus.state, .disabled)
        let finalRequestCount = await transport.requestCount()
        let persistedState = try store.providerSnapshot()?.stateRaw
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(persistedState, OllamaRuntimeState.disabled.rawValue)
    }

    func testTerminationCancelsAndDrainsStartupWithoutPersistingAnOptOut() async throws {
        let store = try LocalStore(inMemory: true)
        try store.upsertProviderSnapshot(.init(
            stateRaw: OllamaRuntimeState.connected.rawValue,
            checkedAt: AppModelP2Fixture.anchor
        ))
        let transport = AppModelP2OllamaTransport(actions: [.waitForCancellation])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider
        )
        let startupRequestStarted = await eventually {
            await transport.requestCount() == 1
        }
        XCTAssertTrue(startupRequestStarted)
        guard startupRequestStarted else { return }

        await model.shutdownForApplicationTermination()

        let runtimeStatus = await provider.status()
        let cancellationCount = await transport.recordedCancellationCount()
        let requestCount = await transport.requestCount()
        let persistedState = try store.providerSnapshot()?.stateRaw
        XCTAssertEqual(runtimeStatus.state, .disabled)
        XCTAssertGreaterThan(cancellationCount, 0)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(persistedState, OllamaRuntimeState.connected.rawValue)
    }

    func testDeleteAllCancelsAndDrainsStartupBeforeRemovingProviderState() async throws {
        let store = try LocalStore(inMemory: true)
        try store.upsertProviderSnapshot(.init(
            stateRaw: OllamaRuntimeState.connected.rawValue,
            checkedAt: AppModelP2Fixture.anchor
        ))
        let transport = AppModelP2OllamaTransport(actions: [.waitForCancellation])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider
        )
        let startupRequestStarted = await eventually {
            await transport.requestCount() == 1
        }
        XCTAssertTrue(startupRequestStarted)
        guard startupRequestStarted else { return }

        await model.deleteAllData()

        let runtimeStatus = await provider.status()
        let cancellationCount = await transport.recordedCancellationCount()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(runtimeStatus.state, .disabled)
        XCTAssertGreaterThan(cancellationCount, 0)
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(try store.providerSnapshot())
        XCTAssertTrue(model.localModels.isEmpty)
        XCTAssertEqual(model.ollamaStatus.state, .disabled)
    }

    func testNewerFallbackProvenanceDoesNotHideOlderSuccessfulOllamaTimestampOnRelaunch() throws {
        let store = try LocalStore(inMemory: true)
        let successfulGenerationAt = AppModelP2Fixture.anchor.addingTimeInterval(-60)
        let fallbackGenerationAt = AppModelP2Fixture.anchor
        try store.persistGenerationProvenance(.init(
            providerKind: "ollama",
            selectedModelName: AppModelP2Fixture.modelID,
            endpointClassification: .numericIPv4Loopback,
            promptTemplateVersion: "loki.brief.p2.v1",
            schemaVersion: OllamaOutputValidator.schemaVersion,
            generatedAt: successfulGenerationAt,
            sourceItemIdentifiers: ["successful-item"],
            deterministicBriefIdentifier: "successful-brief",
            completionStatus: .success,
            fallbackStatus: .notUsed,
            durationMilliseconds: 125,
            promptTokenCount: 24,
            outputTokenCount: 16,
            validationResult: .valid,
            failureReasonCode: nil
        ))
        try store.persistGenerationProvenance(.init(
            providerKind: "ollama",
            selectedModelName: AppModelP2Fixture.modelID,
            endpointClassification: .numericIPv4Loopback,
            promptTemplateVersion: "loki.brief.p2.v1",
            schemaVersion: OllamaOutputValidator.schemaVersion,
            generatedAt: fallbackGenerationAt,
            sourceItemIdentifiers: ["fallback-item"],
            deterministicBriefIdentifier: "fallback-brief",
            completionStatus: .fallback,
            fallbackStatus: .deterministicBriefPreserved,
            durationMilliseconds: 80,
            promptTokenCount: nil,
            outputTokenCount: nil,
            validationResult: .providerUnavailable,
            failureReasonCode: OllamaFailureCode.serviceUnavailable.rawValue
        ))

        let relaunched = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: NativeOllamaProvider()
        )

        XCTAssertEqual(try store.latestGenerationProvenance()?.generatedAt, fallbackGenerationAt)
        XCTAssertEqual(relaunched.lastLocalGenerationAt, successfulGenerationAt)
    }

    func testToggleOffAndOnBeforeOllamaCheckPreservesRelaunchedModelSelection() throws {
        let store = try LocalStore(inMemory: true)
        let descriptor = AppModelP2Fixture.modelDescriptor()
        let selection = OllamaModelSelection(
            model: descriptor,
            catalogRevision: 3,
            selectedAt: AppModelP2Fixture.anchor
        )
        try store.persistModelCatalog(.init(
            revision: 3,
            discoveredAt: AppModelP2Fixture.anchor,
            models: [descriptor],
            excludedCloudModelCount: 0
        ))
        try store.persistModelSelection(selection, enabled: true)
        let settings = try store.settings()
        settings.deterministicOnly = false
        try store.save()

        let relaunched = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: NativeOllamaProvider()
        )
        XCTAssertEqual(relaunched.selectedModelID, AppModelP2Fixture.modelID)
        XCTAssertTrue(relaunched.localGenerationEnabled)

        relaunched.setLocalGenerationEnabled(false)
        XCTAssertEqual(relaunched.selectedModelID, AppModelP2Fixture.modelID)
        XCTAssertEqual(try store.modelSelection().modelID, AppModelP2Fixture.modelID)
        XCTAssertFalse(try store.modelSelection().localGenerationEnabled)

        relaunched.setLocalGenerationEnabled(true)
        XCTAssertEqual(relaunched.selectedModelID, AppModelP2Fixture.modelID)
        XCTAssertEqual(try store.modelSelection().modelID, AppModelP2Fixture.modelID)
        XCTAssertTrue(try store.modelSelection().localGenerationEnabled)
    }

    func testDeleteAllDataDuringInFlightLocalGenerationCannotRepopulateP2State() async throws {
        let store = try LocalStore(inMemory: true)
        let source = AppModelP2Fixture.subscription()
        let entry = AppModelP2Fixture.entry(
            id: "delete-race-entry",
            source: source,
            title: "Delete race fixture",
            summary: "A retained entry exists before the destructive local reset.",
            position: 0
        )
        try store.persistFeedFetchResult(
            AppModelP2Fixture.fetchResult(source: source, entries: [entry]),
            settings: try store.p2Settings()
        )
        try store.record(DeterministicBriefingEngine().generatePreview(revision: 9))

        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
            .waitForCancellation,
        ])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider
        )
        XCTAssertEqual(model.historyCount, 1)
        XCTAssertEqual(model.subscriptions.count, 1)

        model.checkOllama()
        let discovered = await eventually {
            model.localModels.map(\.id) == [AppModelP2Fixture.modelID]
        }
        XCTAssertTrue(discovered)
        guard discovered else { return }

        model.selectOllamaModel(AppModelP2Fixture.modelID)
        let selected = await eventually {
            model.selectedModelID == AppModelP2Fixture.modelID &&
                model.ollamaStatus.state == .modelSelected
        }
        XCTAssertTrue(selected)
        guard selected else { return }

        model.setLocalGenerationEnabled(true)
        model.testLocalSummary()
        let generationStarted = await eventually {
            await transport.requestCount() == 3
        }
        XCTAssertTrue(generationStarted)
        guard generationStarted else { return }

        await model.deleteAllData()
        let cancelled = await eventually {
            let cancellationCount = await transport.recordedCancellationCount()
            return cancellationCount > 0
        }
        XCTAssertTrue(cancelled)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertTrue(model.localModels.isEmpty)
        XCTAssertNil(model.selectedModelID)
        XCTAssertFalse(model.localGenerationEnabled)
        XCTAssertNil(model.lastLocalGenerationAt)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.historyCount, 0)
        XCTAssertEqual(model.ollamaStatus.state, .disabled)
        let providerStatusAfterDelete = await provider.status()
        XCTAssertEqual(providerStatusAfterDelete.state, .disabled)

        let context = store.container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredFeedSubscription>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredBrief>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredLocalModelDescriptor>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredModelProviderSnapshotP2>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredModelSelectionRecord>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()).count, 0)
        XCTAssertNil(try store.latestGenerationProvenance())
    }

    func testOllamaEvidenceBoundUsesOnlySectionsPresentInFirstSixteenSelectedItems() async throws {
        let store = try LocalStore(inMemory: true)
        let source = AppModelP2Fixture.subscription()
        try store.persistFeedSubscription(source)
        let attentionEntries = (0..<17).map { index in
            AppModelP2Fixture.entry(
                id: String(format: "attention-%02d", index),
                source: source,
                title: "Urgent fixture \(index)",
                summary: "Immediate action evidence \(index).",
                position: index
            )
        }
        let systemEntry = AppModelP2Fixture.entry(
            id: "system-after-attention",
            source: source,
            title: "Product release update",
            summary: "A system release is available.",
            position: 17
        )
        let result = AppModelP2Fixture.fetchResult(
            source: source,
            entries: attentionEntries + [systemEntry]
        )
        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
            .structuredGenerationSuccess,
        ])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(result: result),
            feedEngine: .init(now: { AppModelP2Fixture.anchor }),
            ollamaProvider: provider
        )

        model.checkOllama()
        let discovered = await eventually {
            model.localModels.map(\.id) == [AppModelP2Fixture.modelID]
        }
        XCTAssertTrue(discovered)
        guard discovered else { return }
        model.selectOllamaModel(AppModelP2Fixture.modelID)
        let selected = await eventually {
            model.selectedModelID == AppModelP2Fixture.modelID &&
                model.ollamaStatus.state == .modelSelected
        }
        XCTAssertTrue(selected)
        guard selected else { return }

        model.setLocalGenerationEnabled(true)
        model.refreshAllFeeds()
        let completed = await eventually(iterations: 500) {
            let requestCount = await transport.requestCount()
            return model.refreshState == .complete && requestCount == 3
        }
        XCTAssertTrue(completed)
        guard completed else { return }

        let recordedEvidence = await transport.recordedEvidence()
        let capture = try XCTUnwrap(recordedEvidence.last)
        XCTAssertEqual(capture.allowedSectionIDs, ["attention"])
        XCTAssertEqual(capture.selectedItemIDs.count, OllamaProviderLimits.maximumSelectedItems)
        XCTAssertEqual(Set(capture.selectedSectionIDs), ["attention"])
        XCTAssertEqual(Set(capture.selectedItemIDs), Set(attentionEntries.prefix(16).map(\.id)))
        XCTAssertTrue(model.brief.sections.contains { $0.id == "system" })
        XCTAssertEqual(model.brief.generation.providerKind, "ollama")
    }

    func testSlackEvidenceNeverEntersOllamaUntilItsWorkspaceConsentIsExplicitlyEnabled() async throws {
        let store = try LocalStore(inMemory: true)
        let workspace = try persistSlackFixture(in: store, consent: false)
        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
            .structuredGenerationSuccess,
        ])
        let provider = NativeOllamaProvider(transport: transport, now: { AppModelP2Fixture.anchor })
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            feedEngine: .init(now: { AppModelP2Fixture.anchor }),
            mixedEngine: .init(slackEngine: .init(now: { AppModelP2Fixture.anchor })),
            ollamaProvider: provider
        )

        model.checkOllama()
        let discovered = await eventually { model.localModels.map(\.id) == [AppModelP2Fixture.modelID] }
        XCTAssertTrue(discovered)
        model.selectOllamaModel(AppModelP2Fixture.modelID)
        let selected = await eventually { model.ollamaStatus.state == .modelSelected }
        XCTAssertTrue(selected)
        model.setLocalGenerationEnabled(true)

        await model.rebuildBriefAfterSlackChange()
        let requestCountBeforeConsent = await transport.requestCount()
        XCTAssertEqual(requestCountBeforeConsent, 2)
        XCTAssertEqual(model.brief.sections.flatMap(\.items).first?.source.kind, .slack)
        XCTAssertEqual(model.brief.sections.flatMap(\.items).first?.slackAttribution?.locallyGenerated, false)

        try store.setSlackLocalModelConsent(workspaceID: workspace.id, enabled: true)
        await model.rebuildBriefAfterSlackChange()

        let requestCountAfterConsent = await transport.requestCount()
        XCTAssertEqual(requestCountAfterConsent, 3)
        let recordedEvidence = await transport.recordedEvidence()
        let capture = try XCTUnwrap(recordedEvidence.last)
        XCTAssertEqual(capture.selectedItemIDs, ["slack-private-evidence"])
        XCTAssertEqual(model.brief.sections.flatMap(\.items).first?.slackAttribution?.locallyGenerated, true)
    }

    func testDisablingSlackConsentCancelsInFlightGenerationAndRejectsLatePresentationText() async throws {
        let store = try LocalStore(inMemory: true)
        let workspace = try persistSlackFixture(in: store, consent: true)
        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
            .waitForCancellation,
        ])
        let provider = NativeOllamaProvider(transport: transport, now: { AppModelP2Fixture.anchor })
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            feedEngine: .init(now: { AppModelP2Fixture.anchor }),
            mixedEngine: .init(slackEngine: .init(now: { AppModelP2Fixture.anchor })),
            ollamaProvider: provider
        )

        model.checkOllama()
        let discovered = await eventually { model.localModels.map(\.id) == [AppModelP2Fixture.modelID] }
        XCTAssertTrue(discovered)
        model.selectOllamaModel(AppModelP2Fixture.modelID)
        let selected = await eventually { model.ollamaStatus.state == .modelSelected }
        XCTAssertTrue(selected)
        model.setLocalGenerationEnabled(true)

        let rebuild = Task { await model.rebuildBriefAfterSlackChange() }
        let requestStarted = await eventually { await transport.requestCount() == 3 }
        XCTAssertTrue(requestStarted)
        try store.setSlackLocalModelConsent(workspaceID: workspace.id, enabled: false)
        model.cancelSlackLocalGeneration()
        let cancelled = await eventually { await transport.recordedCancellationCount() > 0 }
        XCTAssertTrue(cancelled)
        await rebuild.value

        XCTAssertNotEqual(model.brief.generation.providerKind, "ollama")
        XCTAssertEqual(model.brief.sections.flatMap(\.items).first?.slackAttribution?.locallyGenerated, false)
        XCTAssertFalse(try XCTUnwrap(store.slackWorkspaceConnection(id: workspace.id)).localModelConsent)
    }

    func testDisappearedSelectedModelClearsPublishedAndPersistedSelectionWithDegradedTruth() async throws {
        let store = try LocalStore(inMemory: true)
        let transport = AppModelP2OllamaTransport(actions: [
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData()),
            .response(status: 200, data: try AppModelP2Fixture.versionData()),
            .response(status: 200, data: try AppModelP2Fixture.tagsData(models: [])),
        ])
        let provider = NativeOllamaProvider(
            transport: transport,
            now: { AppModelP2Fixture.anchor }
        )
        let model = try AppModel(
            store: store,
            feedClient: AppModelP2FeedRetriever(),
            ollamaProvider: provider
        )

        model.checkOllama()
        let discovered = await eventually {
            model.localModels.map(\.id) == [AppModelP2Fixture.modelID]
        }
        XCTAssertTrue(discovered)
        guard discovered else { return }
        model.selectOllamaModel(AppModelP2Fixture.modelID)
        let selected = await eventually {
            model.selectedModelID == AppModelP2Fixture.modelID &&
                model.ollamaStatus.state == .modelSelected
        }
        XCTAssertTrue(selected)
        guard selected else { return }
        model.setLocalGenerationEnabled(true)

        model.checkOllama()
        let disappeared = await eventually {
            model.selectedModelID == nil &&
                model.localModels.isEmpty &&
                model.ollamaStatus.state == .degraded &&
                model.ollamaStatus.lastFailureCode == .selectedModelDisappeared
        }
        XCTAssertTrue(disappeared)
        guard disappeared else { return }

        XCTAssertTrue(model.localGenerationEnabled)
        XCTAssertTrue(model.localGenerationMessage.contains("no longer installed"))
        let selection = try store.modelSelection()
        XCTAssertNil(selection.modelID)
        XCTAssertTrue(selection.localGenerationEnabled)
        let snapshot = try XCTUnwrap(store.providerSnapshot())
        XCTAssertEqual(snapshot.stateRaw, OllamaRuntimeState.degraded.rawValue)
        XCTAssertEqual(snapshot.failureCode, OllamaFailureCode.selectedModelDisappeared.rawValue)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 4)
    }

    private func eventually(
        iterations: Int = 300,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func persistSlackFixture(in store: LocalStore, consent: Bool) throws -> SlackWorkspaceConnection {
        let workspaceID = SlackWorkspaceConnection.stableID(teamID: "T-PRIVATE", userID: "U-PRIVATE")
        let workspace = SlackWorkspaceConnection(
            id: workspaceID,
            teamID: "T-PRIVATE",
            teamName: "Private Workspace",
            userID: "U-PRIVATE",
            userDisplayName: "Private Member",
            state: .connected,
            grantedScopes: Set(SlackGrantedScope.allCases),
            credentialMetadata: .init(
                tokenType: "user",
                issuedAt: AppModelP2Fixture.anchor,
                accessExpiration: AppModelP2Fixture.anchor.addingTimeInterval(3_600),
                grantedScopes: Set(SlackGrantedScope.allCases),
                schemaVersion: 1
            ),
            localModelConsent: false,
            connectedAt: AppModelP2Fixture.anchor,
            updatedAt: AppModelP2Fixture.anchor,
            lastFailureReasonCode: nil
        )
        try store.persistSlackWorkspace(workspace)
        if consent { try store.setSlackLocalModelConsent(workspaceID: workspaceID, enabled: true) }
        try store.persistDiscoveredSlackConversations([.init(
            id: "C-PRIVATE",
            workspaceID: workspaceID,
            displayName: "private-channel",
            kind: .privateChannel,
            isMember: true,
            isArchived: false,
            discoveredAt: AppModelP2Fixture.anchor
        )], workspaceID: workspaceID)
        try store.setSlackConversationSelected(id: "\(workspaceID):C-PRIVATE", selected: true)
        let timestamp = try XCTUnwrap(SlackTimestamp(rawValue: "1760000000.000001"))
        try store.persistSlackEvidence(.init(
            id: "slack-private-evidence",
            workspaceID: workspaceID,
            workspaceName: "Private Workspace",
            channelID: "C-PRIVATE",
            channelName: "private-channel",
            channelKind: .privateChannel,
            messageTimestamp: timestamp,
            excerpt: "PRIVATE_SLACK_PROMPT_BOUNDARY_MARKER",
            author: .init(id: "U-AUTHOR", displayName: "Private Author", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: true,
            replyCount: 0,
            isEdited: false,
            editedAt: nil,
            permalink: nil,
            retrievedAt: AppModelP2Fixture.anchor,
            selectedChannelWeight: 1,
            state: .available
        ))
        return workspace
    }
}
