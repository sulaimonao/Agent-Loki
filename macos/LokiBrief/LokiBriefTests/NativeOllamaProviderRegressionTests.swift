import Foundation
import XCTest
@testable import LokiBrief

private final class NativeCancellationProtocolState: @unchecked Sendable {
    private let condition = NSCondition()
    private var startCount = 0
    private var stopCount = 0
    private var releasedStopCount = 0

    func reset() {
        condition.lock()
        startCount = 0
        stopCount = 0
        releasedStopCount = 0
        condition.unlock()
    }

    func recordStart() {
        condition.lock()
        startCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func recordStopAndWaitForRelease() {
        condition.lock()
        stopCount += 1
        let ordinal = stopCount
        condition.broadcast()
        while releasedStopCount < ordinal {
            condition.wait()
        }
        condition.unlock()
    }

    func releaseStop(_ ordinal: Int) {
        condition.lock()
        releasedStopCount = max(releasedStopCount, ordinal)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        releaseStop(.max)
    }

    func counts() -> (starts: Int, stops: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (startCount, stopCount)
    }
}

private final class NativeCancellationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = NativeCancellationProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.recordStart()
    }

    override func stopLoading() {
        // The transport's delegate-completion hook below owns the deterministic
        // drain gate. URLProtocol stopLoading may precede delegate completion.
    }
}

private final class NativeCancellationReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didReturn = false

    func markReturned() {
        lock.withLock { didReturn = true }
    }

    func snapshot() -> Bool {
        lock.withLock { didReturn }
    }
}

private actor ProviderRegressionTransport: OllamaTransporting {
    enum Action: Sendable {
        case response(status: Int, data: Data)
        case failure(OllamaFailure)
        case waitForCancellation
        case waitForCancellationDrain
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var actions: [Action]
    private var requests: [URLRequest] = []
    private var pending: [UUID: CheckedContinuation<OllamaTransportResponse, Error>] = [:]
    private var delayedCancellationRequestIDs: Set<UUID> = []
    private var cancellationDrains: [
        UUID: (
            response: CheckedContinuation<OllamaTransportResponse, Error>,
            drain: CheckedContinuation<Void, Never>
        )
    ] = [:]
    private var cancellationDrainCount = 0
    private var waiters: [Waiter] = []
    private var cancellationDrainWaiters: [Waiter] = []

    init(actions: [Action]) {
        self.actions = actions
    }

    func data(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) async throws -> OllamaTransportResponse {
        requests.append(request)
        resumeSatisfiedWaiters()
        guard !actions.isEmpty else { throw OllamaFailure(.invalidResponse) }

        switch actions.removeFirst() {
        case let .response(status, data):
            return .init(data: data, statusCode: status, finalURL: request.url)
        case let .failure(failure):
            throw failure
        case .waitForCancellation:
            return try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
            }
        case .waitForCancellationDrain:
            return try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
                delayedCancellationRequestIDs.insert(requestID)
            }
        }
    }

    func cancel(requestID: UUID) async {
        guard let response = pending.removeValue(forKey: requestID) else {
            return
        }
        guard delayedCancellationRequestIDs.remove(requestID) != nil else {
            response.resume(throwing: URLError(.cancelled))
            return
        }
        await withCheckedContinuation { continuation in
            cancellationDrains[requestID] = (
                response: response,
                drain: continuation
            )
            cancellationDrainCount += 1
            resumeSatisfiedCancellationDrainWaiters()
        }
    }

    func requestCount() -> Int { requests.count }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append(.init(count: count, continuation: continuation))
        }
    }

    func waitForCancellationDrainCount(_ count: Int) async {
        if cancellationDrainCount >= count { return }
        await withCheckedContinuation { continuation in
            cancellationDrainWaiters.append(.init(
                count: count,
                continuation: continuation
            ))
        }
    }

    func releaseCancellationDrains() {
        let drains = Array(cancellationDrains.values)
        cancellationDrains.removeAll()
        for cancellation in drains {
            cancellation.response.resume(
                throwing: URLError(.cancelled)
            )
            cancellation.drain.resume()
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private func resumeSatisfiedCancellationDrainWaiters() {
        var remaining: [Waiter] = []
        for waiter in cancellationDrainWaiters {
            if cancellationDrainCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationDrainWaiters = remaining
    }
}

private actor ProviderRegressionStartGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdBeforeProviderEntry() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class ProviderRegressionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !dates.isEmpty else { return .distantPast }
        if dates.count == 1 { return dates[0] }
        return dates.removeFirst()
    }
}

final class NativeOllamaProviderRegressionTests: XCTestCase, @unchecked Sendable {
    private static let modelID = "gpt-oss:20b"
    private static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

    func testNativeProviderCorrelatesVersionDiscoveryAndGenerationRequests()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "d", count: 64)
        )
        let transport = ProviderRegressionTransport(
            actions: [
                .response(
                    status: 200,
                    data: try Self.jsonData([
                        "version": "0.30.6",
                    ])
                ),
                .response(
                    status: 200,
                    data: try Self.tagsData()
                ),
                .response(
                    status: 200,
                    data: try Self.generateEnvelope()
                ),
            ]
        )
        let provider = Self.provider(
            transport: transport
        )

        _ = try await provider.checkVersion()
        _ = try await provider.discoverModels()
        _ = try await provider.selectModel(
            id: Self.modelID
        )
        guard case .generated =
            await provider.generate(
                Self.generationInput()
            )
        else {
            XCTFail("Expected generated fixture.")
            return
        }

        let observations = recorder.snapshot()
        XCTAssertEqual(
            observations.map(\.providerKind),
            [.native, .native, .native]
        )
        XCTAssertEqual(
            observations.map(\.operationKind),
            [
                .versionCheck,
                .modelDiscovery,
                .generation,
            ]
        )
        XCTAssertEqual(
            observations.map(\.outcome),
            [.succeeded, .succeeded, .succeeded]
        )
        XCTAssertEqual(
            observations.map(\.sequence),
            [1, 2, 3]
        )
        XCTAssertEqual(
            recorder.stateSnapshot()
                .pendingRequestCount,
            0
        )
        let representation = String(
            decoding: try JSONEncoder().encode(
                observations
            ),
            as: UTF8.self
        )
        XCTAssertFalse(
            representation.contains(
                "A bounded provider regression fixture."
            )
        )
        XCTAssertFalse(
            representation.contains(Self.modelID)
        )
    }

    func testSealedProviderEvidenceRefusesNativeTransportBeforeStart()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        let run = try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "f", count: 64),
            runIdentifier: "sealed_native_transport_refusal"
        )
        _ = try recorder.sealEvidence(for: run)

        let transport = ProviderRegressionTransport(
            actions: [
                .response(
                    status: 200,
                    data: try Self.jsonData([
                        "version": "0.30.6",
                    ])
                ),
            ]
        )
        let provider = Self.provider(transport: transport)
        do {
            _ = try await provider.checkVersion()
            XCTFail("Expected evidence admission refusal")
        } catch {
            // The native provider maps internal failures, but admission must
            // still fail before the transport boundary.
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testProviderEvidenceCapacityRefusesNativeTransportBeforeStart()
        async throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }
        try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "f", count: 64),
            runIdentifier: "capacity_native_transport_refusal"
        )
        try P8FProviderCorrelationCapacityTestFixture.fill(
            recorder
        )

        let transport = ProviderRegressionTransport(
            actions: [
                .response(
                    status: 200,
                    data: try Self.jsonData([
                        "version": "0.30.6",
                    ])
                ),
            ]
        )
        let provider = Self.provider(transport: transport)
        do {
            _ = try await provider.checkVersion()
            XCTFail("Expected evidence capacity refusal")
        } catch let failure as OllamaFailure {
            XCTAssertEqual(failure.code, .invalidResponse)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
    }

    func testRediscoveryRefreshesRetainedSelectionRevisionBeforeGeneration() async throws {
        let transport = ProviderRegressionTransport(actions: [
            .response(status: 200, data: try Self.tagsData(digest: "first")),
            .response(status: 200, data: try Self.tagsData(digest: "refreshed")),
            .response(status: 200, data: try Self.generateEnvelope())
        ])
        let provider = Self.provider(transport: transport)

        let firstCatalog = try await provider.discoverModels()
        _ = try await provider.selectModel(id: Self.modelID)
        let refreshedCatalog = try await provider.discoverModels()
        XCTAssertEqual(refreshedCatalog.revision, firstCatalog.revision + 1)
        XCTAssertEqual(refreshedCatalog.models.first?.digest, "refreshed")

        let outcome = await provider.generate(Self.generationInput())
        guard case let .generated(result) = outcome else {
            XCTFail("A retained selection must remain valid for the refreshed catalog revision.")
            return
        }
        XCTAssertEqual(result.provenance.selectedModelName, Self.modelID)
        let status = await provider.status()
        XCTAssertEqual(status.selectedModelID, Self.modelID)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 3, "The provider must not retry.")
    }

    func testFallbackRetainsAttemptedModelFor404AndCancellationWithoutRetry() async throws {
        let missingTransport = ProviderRegressionTransport(actions: [
            .response(status: 200, data: try Self.tagsData()),
            .response(status: 404, data: Data())
        ])
        let missingProvider = Self.provider(transport: missingTransport)
        _ = try await missingProvider.discoverModels()
        _ = try await missingProvider.selectModel(id: Self.modelID)

        let missingOutcome = await missingProvider.generate(Self.generationInput())
        guard case let .fallback(missingFallback) = missingOutcome else {
            XCTFail("Expected deterministic fallback for a disappeared model.")
            return
        }
        XCTAssertEqual(missingFallback.failure.code, .selectedModelDisappeared)
        XCTAssertEqual(missingFallback.provenance.selectedModelName, Self.modelID)
        let missingRequestCount = await missingTransport.requestCount()
        XCTAssertEqual(missingRequestCount, 2, "The provider must not retry a 404.")

        let cancelTransport = ProviderRegressionTransport(actions: [
            .response(status: 200, data: try Self.tagsData()),
            .waitForCancellation
        ])
        let cancelProvider = Self.provider(transport: cancelTransport)
        _ = try await cancelProvider.discoverModels()
        _ = try await cancelProvider.selectModel(id: Self.modelID)

        let generation = Task { await cancelProvider.generate(Self.generationInput()) }
        await cancelTransport.waitForRequestCount(2)
        await cancelProvider.cancelGeneration()
        let cancelledOutcome = await generation.value
        guard case let .fallback(cancelledFallback) = cancelledOutcome else {
            XCTFail("Expected deterministic fallback for cancellation.")
            return
        }
        XCTAssertEqual(cancelledFallback.failure.code, .requestCancelled)
        XCTAssertEqual(cancelledFallback.provenance.selectedModelName, Self.modelID)
        let cancelRequestCount = await cancelTransport.requestCount()
        XCTAssertEqual(cancelRequestCount, 2, "The provider must not retry cancellation.")
    }

    func testGenerationCancellationWaitsForDrainAndCannotMutateSuccessorState()
        async throws
    {
        let transport = ProviderRegressionTransport(actions: [
            .response(
                status: 200,
                data: try Self.tagsData()
            ),
            .waitForCancellationDrain,
            .response(
                status: 200,
                data: try Self.generateEnvelope()
            ),
        ])
        let provider = Self.provider(transport: transport)
        _ = try await provider.discoverModels()
        _ = try await provider.selectModel(id: Self.modelID)

        let cancelledGeneration = Task {
            await provider.generate(Self.generationInput())
        }
        await transport.waitForRequestCount(2)
        let cancellation = Task {
            await provider.cancelGeneration()
        }
        await transport.waitForCancellationDrainCount(1)

        let drainingStatus = await provider.status()
        XCTAssertEqual(
            drainingStatus.state,
            .generating,
            "Provider state must remain owned by the cancelling epoch until its transport drains."
        )

        await transport.releaseCancellationDrains()
        await cancellation.value
        guard case let .fallback(cancelledFallback) =
            await cancelledGeneration.value
        else {
            XCTFail("Expected the drained generation to report cancellation.")
            return
        }
        XCTAssertEqual(
            cancelledFallback.failure.code,
            .requestCancelled
        )

        guard case .generated =
            await provider.generate(Self.generationInput())
        else {
            XCTFail("Expected successor generation after the completed drain.")
            return
        }
        await Task.yield()
        let successorStatus = await provider.status()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(successorStatus.state, .modelSelected)
        XCTAssertEqual(requestCount, 3)
    }

    func testCancelledTaskBeforeProviderEntryNeverRegistersGenerationRequest() async throws {
        let transport = ProviderRegressionTransport(actions: [
            .response(status: 200, data: try Self.tagsData())
        ])
        let provider = Self.provider(transport: transport)
        _ = try await provider.discoverModels()
        _ = try await provider.selectModel(id: Self.modelID)

        let gate = ProviderRegressionStartGate()
        let generation = Task {
            await gate.holdBeforeProviderEntry()
            return await provider.generate(Self.generationInput())
        }
        await gate.waitUntilEntered()
        generation.cancel()
        await gate.release()

        let outcome = await generation.value
        guard case let .fallback(fallback) = outcome else {
            XCTFail("A task cancelled before provider entry must preserve the deterministic fallback.")
            return
        }
        XCTAssertEqual(fallback.failure.code, .requestCancelled)
        XCTAssertEqual(fallback.provenance.completionStatus, .cancelled)
        XCTAssertEqual(fallback.provenance.validationResult, .cancelled)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1, "Cancellation must prevent the generate request from registering.")
    }

    func testLastSuccessfulCheckAtSurvivesARecordedFailure() async throws {
        let successDate = Date(timeIntervalSince1970: 1_760_000_100)
        let failureDate = Date(timeIntervalSince1970: 1_760_000_200)
        let clock = ProviderRegressionClock([successDate, failureDate])
        let transport = ProviderRegressionTransport(actions: [
            .response(status: 200, data: try Self.jsonData(["version": "0.30.6"])),
            .failure(.init(.serviceUnavailable))
        ])
        let provider = NativeOllamaProvider(
            enabled: true,
            transport: transport,
            now: { clock.next() }
        )

        _ = try await provider.checkVersion()
        var status = await provider.status()
        XCTAssertEqual(status.checkedAt, successDate)
        XCTAssertEqual(status.lastSuccessfulCheckAt, successDate)

        do {
            _ = try await provider.checkVersion()
            XCTFail("Expected the recorded service failure.")
        } catch let failure as OllamaFailure {
            XCTAssertEqual(failure.code, .serviceUnavailable)
        }
        status = await provider.status()
        XCTAssertEqual(status.checkedAt, failureDate)
        XCTAssertEqual(status.lastSuccessfulCheckAt, successDate)
        XCTAssertEqual(status.lastFailureCode, .serviceUnavailable)
    }

    func testDisableDuringHealthAndDiscoveryKeepsActorDisabled() async throws {
        for operation in ["version", "tags"] {
            let transport = ProviderRegressionTransport(actions: [.waitForCancellation])
            let provider = Self.provider(transport: transport)
            let request = Task {
                if operation == "version" {
                    _ = try await provider.checkVersion()
                } else {
                    _ = try await provider.discoverModels()
                }
            }

            await transport.waitForRequestCount(1)
            await provider.setEnabled(false)
            do {
                try await request.value
                XCTFail("Expected disabling to cancel the in-flight \(operation) request.")
            } catch let failure as OllamaFailure {
                XCTAssertEqual(failure.code, .requestCancelled, operation)
            } catch {
                XCTFail("Unexpected \(operation) error: \(error)")
            }

            let status = await provider.status()
            XCTAssertEqual(status.state, .disabled, operation)
            XCTAssertNil(status.checkedAt, operation)
            XCTAssertNil(status.lastFailureCode, operation)
            XCTAssertEqual(status.discoveredModelCount, 0, operation)
            XCTAssertNil(status.selectedModelID, operation)
        }
    }

    func testStatusSnapshotKeepsLegacyInitializerAndDecodeCompatibility() throws {
        let sourceCompatible = OllamaProviderStatusSnapshot(
            state: .connected,
            checkedAt: Self.fixedDate,
            discoveredModelCount: 1,
            selectedModelID: Self.modelID,
            lastFailureCode: nil
        )
        XCTAssertNil(sourceCompatible.lastSuccessfulCheckAt)

        let legacyJSON = Data(
            #"{"state":"connected","checkedAt":null,"discoveredModelCount":1,"selectedModelID":null,"lastFailureCode":null}"#.utf8
        )
        let decoded = try JSONDecoder().decode(OllamaProviderStatusSnapshot.self, from: legacyJSON)
        XCTAssertNil(decoded.lastSuccessfulCheckAt)
        XCTAssertEqual(decoded.discoveredModelCount, 1)
    }

    func testBoundedNativeTransportCancellationWaitsForDelegateDrainAndDoesNotPoisonSuccessor()
        async throws
    {
        let protocolState = NativeCancellationURLProtocol.state
        protocolState.reset()
        defer { protocolState.releaseAll() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeCancellationURLProtocol.self]
        let transport = BoundedOllamaTransport(
            configuration: configuration,
            didCompleteTestHook: { _ in
                protocolState.recordStopAndWaitForRelease()
            }
        )
        let request = Self.request(
            "http://127.0.0.1:11434/api/version"
        )
        let requestID = UUID()

        let firstRequest = Task {
            try? await transport.data(
                for: request,
                requestID: requestID,
                responseLimit: 1_024
            )
        }
        let firstStarted = await Self.waitForProtocolCounts(
            protocolState,
            starts: 1,
            stops: 0
        )
        XCTAssertTrue(firstStarted)

        let firstCancellationReturn = NativeCancellationReturnFlag()
        let firstCancellation = Task {
            await transport.cancel(requestID: requestID)
            firstCancellationReturn.markReturned()
        }
        let firstStopped = await Self.waitForProtocolCounts(
            protocolState,
            starts: 1,
            stops: 1
        )
        XCTAssertTrue(firstStopped)
        XCTAssertFalse(
            firstCancellationReturn.snapshot(),
            "Cancellation must not return before URLSession delegate completion."
        )
        protocolState.releaseStop(1)
        await firstCancellation.value
        _ = await firstRequest.value

        // A late duplicate cancellation after the old delegate completed is inert. It must
        // not leave request-ID state that cancels a subsequently registered operation.
        await transport.cancel(requestID: requestID)
        let successorRequest = Task {
            try? await transport.data(
                for: request,
                requestID: requestID,
                responseLimit: 1_024
            )
        }
        let successorStarted = await Self.waitForProtocolCounts(
            protocolState,
            starts: 2,
            stops: 1
        )
        XCTAssertTrue(successorStarted)
        await Task.yield()
        XCTAssertEqual(protocolState.counts().stops, 1)

        let successorCancellation = Task {
            await transport.cancel(requestID: requestID)
        }
        let successorStopped = await Self.waitForProtocolCounts(
            protocolState,
            starts: 2,
            stops: 2
        )
        XCTAssertTrue(successorStopped)
        protocolState.releaseStop(2)
        await successorCancellation.value
        _ = await successorRequest.value
    }

    func testBoundedTransportRejectsNonExactRequestsBeforeNetwork() async {
        let transport = BoundedOllamaTransport()
        var requests: [(String, URLRequest)] = []

        requests.append(("remote host", Self.request("http://example.com:11434/api/version")))
        requests.append(("custom path", Self.request("http://127.0.0.1:11434/api/show")))
        requests.append(("query", Self.request("http://127.0.0.1:11434/api/version?token=value")))
        requests.append(("credentials", Self.request("http://user:secret@127.0.0.1:11434/api/version")))

        var wrongMethod = Self.request("http://127.0.0.1:11434/api/version")
        wrongMethod.httpMethod = "POST"
        wrongMethod.httpBody = Data("{}".utf8)
        requests.append(("wrong method", wrongMethod))

        var authenticated = Self.request("http://127.0.0.1:11434/api/version")
        authenticated.setValue("Bearer forbidden", forHTTPHeaderField: "Authorization")
        requests.append(("authorization header", authenticated))

        for (label, request) in requests {
            do {
                _ = try await transport.data(
                    for: request,
                    requestID: UUID(),
                    responseLimit: OllamaProviderLimits.maximumResponseBytes
                )
                XCTFail("Expected policy rejection for \(label).")
            } catch let failure as OllamaFailure {
                XCTAssertEqual(failure.code, .invalidEndpoint, label)
            } catch {
                XCTFail("Unexpected error for \(label): \(error)")
            }
        }
    }

    private static func waitForProtocolCounts(
        _ state: NativeCancellationProtocolState,
        starts: Int,
        stops: Int
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let counts = state.counts()
            if counts.starts >= starts, counts.stops >= stops {
                return true
            }
            await Task.yield()
        }
        let counts = state.counts()
        return counts.starts >= starts && counts.stops >= stops
    }

    private static func provider(
        transport: ProviderRegressionTransport
    ) -> NativeOllamaProvider {
        NativeOllamaProvider(
            enabled: true,
            transport: transport,
            now: { fixedDate }
        )
    }

    private static func request(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        return request
    }

    private static func generationInput() -> OllamaGenerationInput {
        .init(
            deterministicBriefID: "provider-regression-brief",
            allowedSectionIDs: ["research"],
            selectedItems: [
                .init(
                    id: "item-research",
                    sectionID: "research",
                    title: "Research update",
                    evidenceText: "A bounded provider regression fixture.",
                    sourceName: "Provider regression fixture",
                    sourceURL: nil,
                    publishedAt: fixedDate
                )
            ]
        )
    }

    private static func tagsData(digest: String = "abc123") throws -> Data {
        try jsonData([
            "models": [[
                "name": modelID,
                "model": modelID,
                "digest": digest,
                "details": ["family": "gemma"]
            ]]
        ])
    }

    private static func generateEnvelope() throws -> Data {
        let output = try jsonData([
            "schema_version": OllamaOutputValidator.schemaVersion,
            "brief_id": "provider-regression-brief",
            "overall_summary": "One attributable update is ready.",
            "section_summaries": [[
                "section_id": "research",
                "summary": "Research evidence is summarized locally."
            ]],
            "item_summaries": []
        ])
        return try jsonData([
            "model": modelID,
            "response": String(data: output, encoding: .utf8)!,
            "done": true
        ])
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
