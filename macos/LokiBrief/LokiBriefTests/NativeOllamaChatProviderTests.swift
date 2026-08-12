import Foundation
import XCTest
@testable import LokiBrief

enum P8FProviderCorrelationCapacityTestFixture {
    static let maximumObservationCount = 4_096

    private struct FixtureFailure: Error {}

    static func fill(
        _ recorder: P8FProviderRequestCorrelationRecorder,
        observationCount: Int = maximumObservationCount
    ) throws {
        guard (0...maximumObservationCount).contains(
            observationCount
        ) else {
            throw FixtureFailure()
        }
        let startedAt = Date(
            timeIntervalSinceReferenceDate: 1_000
        )
        for ordinal in 0..<observationCount {
            let suffix = String(
                format: "%012llx",
                UInt64(ordinal + 1)
            )
            guard let requestIdentifier = UUID(
                uuidString:
                    "10000000-0000-4000-8000-\(suffix)"
            ),
            let token = try recorder.begin(
                providerKind: .chat,
                operationKind: .modelInspect,
                requestIdentifier: requestIdentifier,
                requestTraceMaterial:
                    "provider-capacity-fixture-\(ordinal)",
                startedAt: startedAt
            ),
            recorder.complete(
                token,
                outcome: .succeeded,
                endedAt: startedAt.addingTimeInterval(0.001)
            ) else {
                throw FixtureFailure()
            }
        }
    }
}

private final class ChatCancellationProtocolState: @unchecked Sendable {
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

private final class ChatCancellationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ChatCancellationProtocolState()

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

private final class ChatCancellationReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didReturn = false

    func markReturned() {
        lock.withLock { didReturn = true }
    }

    func snapshot() -> Bool {
        lock.withLock { didReturn }
    }
}

private final class ScriptedOllamaChatTransport: OllamaChatTransporting, @unchecked Sendable {
    struct Script {
        let statusCode: Int
        let finalURL: URL?
        let chunks: [Data]
        let holdsOpen: Bool
        let failure: Error?

        init(
            statusCode: Int = 200,
            finalURL: URL? = nil,
            chunks: [Data],
            holdsOpen: Bool = false,
            failure: Error? = nil
        ) {
            self.statusCode = statusCode
            self.finalURL = finalURL
            self.chunks = chunks
            self.holdsOpen = holdsOpen
            self.failure = failure
        }
    }

    struct Capture {
        let request: URLRequest
        let requestID: UUID
        let responseLimit: Int
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var captures: [Capture] = []
    private var pending: [
        UUID: AsyncThrowingStream<OllamaChatTransportEvent, Error>.Continuation
    ] = [:]
    private var cancellations = 0

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        lock.lock()
        captures.append(.init(
            request: request,
            requestID: requestID,
            responseLimit: responseLimit
        ))
        let script = scripts.isEmpty ? nil : scripts.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: OllamaChatFailure(.invalidResponse))
                return
            }
            let expectedLength = script.chunks.reduce(0) { $0 + $1.count }
            continuation.yield(.response(.init(
                statusCode: script.statusCode,
                finalURL: script.finalURL ?? request.url,
                expectedContentLength: Int64(expectedLength)
            )))
            for chunk in script.chunks {
                continuation.yield(.bytes(chunk))
            }
            if let failure = script.failure {
                continuation.finish(throwing: failure)
            } else if script.holdsOpen {
                lock.lock()
                pending[requestID] = continuation
                lock.unlock()
            } else {
                continuation.finish()
            }
        }
    }

    func cancel(requestID: UUID) async {
        let continuation = lock.withLock {
            cancellations += 1
            return pending.removeValue(forKey: requestID)
        }
        continuation?.finish(throwing: OllamaChatFailure(.requestCancelled))
    }

    func recordedRequests() -> [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }

    func cancellationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func pendingRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

private final class OllamaChatTraceRecorder: @unchecked Sendable {
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

final class NativeOllamaChatProviderTests: XCTestCase {
    private static let model = "synthetic-chat-model:latest"
    private static let fixedDate = Date(timeIntervalSince1970: 1_785_000_000)

    func testBoundedChatTransportCancellationWaitsForDelegateDrainAndDoesNotPoisonSuccessor()
        async throws
    {
        let protocolState = ChatCancellationURLProtocol.state
        protocolState.reset()
        defer { protocolState.releaseAll() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatCancellationURLProtocol.self]
        let transport = BoundedOllamaChatTransport(
            configuration: configuration,
            didCompleteTestHook: { _ in
                protocolState.recordStopAndWaitForRelease()
            }
        )
        var request = URLRequest(
            url: try OllamaLoopbackEndpointPolicy.url(path: "chat")
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let requestID = UUID()

        let firstEvents = transport.stream(
            for: request,
            requestID: requestID,
            responseLimit: 1_024
        )
        let firstConsumer = Task {
            do {
                for try await _ in firstEvents {}
            } catch {}
        }
        let firstStarted = await Self.waitForProtocolCounts(
            protocolState,
            starts: 1,
            stops: 0
        )
        XCTAssertTrue(firstStarted)

        let firstCancellationReturn = ChatCancellationReturnFlag()
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
        await firstConsumer.value

        // Reusing the identifier is intentionally adversarial: termination from the old
        // stream is bound to its URLSession task identifier and cannot cancel this successor.
        let successorEvents = transport.stream(
            for: request,
            requestID: requestID,
            responseLimit: 1_024
        )
        let successorConsumer = Task {
            do {
                for try await _ in successorEvents {}
            } catch {}
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
        await successorConsumer.value
    }

    func testProviderRequestCorrelationRecorderIsInertBoundedOrderedAndPrivacySafe()
        throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let firstRequestID = UUID(
            uuidString:
                "11111111-2222-3333-4444-555555555555"
        )!
        let secondRequestID = UUID(
            uuidString:
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!
        let privateTrace =
            "trace_PRIVATE_PROMPT_/private/secret"
        XCTAssertNil(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: firstRequestID,
            requestTraceMaterial: privateTrace
        ))
        XCTAssertEqual(
            recorder.stateSnapshot(),
            .init(
                isActive: false,
                pendingRequestCount: 0,
                observationCount: 0,
                latestSequence: 0
            )
        )

        try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: firstRequestID,
            requestTraceMaterial: privateTrace,
            startedAt: Date(
                timeIntervalSinceReferenceDate:
                    .infinity
            )
        )) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestInvalid
            )
        }
        let first = try XCTUnwrap(try recorder.begin(
            providerKind: .chat,
            operationKind: .modelInspect,
            requestIdentifier: firstRequestID,
            requestTraceMaterial: privateTrace,
            startedAt: .distantPast
        ))
        let second = try XCTUnwrap(try recorder.begin(
            providerKind: .embedding,
            operationKind: .embedding,
            requestIdentifier: secondRequestID,
            requestTraceMaterial: privateTrace,
            startedAt: Self.fixedDate
        ))
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            2
        )

        XCTAssertTrue(recorder.complete(
            second,
            outcome: .failed,
            endedAt: Self.fixedDate
                .addingTimeInterval(-10)
        ))
        XCTAssertTrue(recorder.complete(
            first,
            outcome: .cancelled,
            endedAt: .distantFuture
        ))
        XCTAssertFalse(recorder.complete(
            first,
            outcome: .succeeded
        ))

        let observations = recorder.snapshot()
        XCTAssertEqual(
            observations.map(\.sequence),
            [1, 2]
        )
        XCTAssertEqual(
            observations.map(\.outcome),
            [.failed, .cancelled]
        )
        XCTAssertEqual(
            observations.map(\.providerRequestDurationMilliseconds),
            [1, 600_000]
        )
        XCTAssertTrue(observations.allSatisfy {
            $0.endpointPolicyClassification
                == .ollamaModelIPv4Loopback
                && $0.processIdentifier
                    == Int32(
                        ProcessInfo.processInfo
                            .processIdentifier
                    )
                && $0.requestIdentifierSHA256.count
                    == 64
                && $0.requestTraceSHA256.count == 64
        })
        XCTAssertEqual(
            observations[0].requestTraceSHA256,
            observations[1].requestTraceSHA256
        )
        XCTAssertNotEqual(
            observations[0].requestIdentifierSHA256,
            observations[1].requestIdentifierSHA256
        )
        XCTAssertEqual(
            recorder.stateSnapshot(),
            .init(
                isActive: true,
                pendingRequestCount: 0,
                observationCount: 2,
                latestSequence: 2
            )
        )

        let encoded = try JSONEncoder().encode(
            observations
        )
        let representation =
            String(decoding: encoded, as: UTF8.self)
            + observations
                .map(\.debugDescription)
                .joined()
            + String(
                reflecting: recorder.stateSnapshot()
            )
        for forbidden in [
            firstRequestID.uuidString,
            firstRequestID.uuidString.lowercased(),
            secondRequestID.uuidString,
            secondRequestID.uuidString.lowercased(),
            privateTrace,
            "PRIVATE_PROMPT",
            "/private/secret",
        ] {
            XCTAssertFalse(
                representation.contains(forbidden)
            )
        }
    }

    func testProviderRequestCorrelationRecorderReservesCapacityAtBeginAndSealsFailClosed()
        throws
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
                String(repeating: "c", count: 64),
            runIdentifier: "provider_capacity_boundary"
        )
        try P8FProviderCorrelationCapacityTestFixture.fill(
            recorder,
            observationCount:
                P8FProviderCorrelationCapacityTestFixture
                    .maximumObservationCount - 2
        )

        let penultimate = try XCTUnwrap(try recorder.begin(
            providerKind: .embedding,
            operationKind: .embedding,
            requestIdentifier: UUID(
                uuidString:
                    "20000000-0000-4000-8000-000000000001"
            )!,
            requestTraceMaterial: "penultimate-capacity-slot",
            startedAt: Self.fixedDate
        ))
        let final = try XCTUnwrap(try recorder.begin(
            providerKind: .native,
            operationKind: .versionCheck,
            requestIdentifier: UUID(
                uuidString:
                    "20000000-0000-4000-8000-000000000002"
            )!,
            requestTraceMaterial: "final-capacity-slot",
            startedAt: Self.fixedDate
        ))
        XCTAssertEqual(
            recorder.stateSnapshot(),
            .init(
                isActive: true,
                pendingRequestCount: 2,
                observationCount: 4_094,
                latestSequence: 4_094
            )
        )

        XCTAssertThrowsError(try recorder.begin(
            providerKind: .chat,
            operationKind: .chatStream,
            requestIdentifier: UUID(
                uuidString:
                    "20000000-0000-4000-8000-000000000003"
            )!,
            requestTraceMaterial: "over-capacity-request",
            startedAt: Self.fixedDate
        )) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceObservationCapacityExceeded
            )
        }
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            2
        )

        XCTAssertTrue(recorder.complete(
            penultimate,
            outcome: .succeeded,
            endedAt: Self.fixedDate.addingTimeInterval(0.001)
        ))
        XCTAssertFalse(recorder.complete(
            final,
            outcome: .failed,
            endedAt: Date(
                timeIntervalSinceReferenceDate: .infinity
            )
        ))
        XCTAssertEqual(
            recorder.stateSnapshot(),
            .init(
                isActive: true,
                pendingRequestCount: 1,
                observationCount: 4_095,
                latestSequence: 4_095
            )
        )
        XCTAssertThrowsError(
            try recorder.sealEvidence(for: run)
        ) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestsPending
            )
        }

        XCTAssertTrue(recorder.complete(
            final,
            outcome: .failed,
            endedAt: Self.fixedDate.addingTimeInterval(0.001)
        ))
        XCTAssertThrowsError(try recorder.begin(
            providerKind: .chat,
            operationKind: .modelInspect,
            requestIdentifier: UUID(),
            requestTraceMaterial: "full-capacity-request",
            startedAt: Self.fixedDate
        )) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceObservationCapacityExceeded
            )
        }

        let seal = try recorder.sealEvidence(for: run)
        XCTAssertEqual(
            recorder.stateSnapshot(),
            .init(
                isActive: true,
                pendingRequestCount: 0,
                observationCount: 4_096,
                latestSequence: 4_096
            )
        )
        XCTAssertEqual(seal.latestSequence, 4_096)
        XCTAssertEqual(seal.observations.count, 4_096)
        XCTAssertEqual(
            seal.observations.suffix(2).map(\.outcome),
            [.succeeded, .failed]
        )
    }

    func testProviderEvidenceSealIsGenerationBoundIdempotentAndImmutable()
        throws
    {
        let recorder =
            P8FProviderRequestCorrelationRecorder.shared
        recorder.resetForTesting()
        defer { recorder.resetForTesting() }

        let privateRunIdentifier =
            "PRIVATE_PROVIDER_EVIDENCE_RUN_IDENTIFIER"
        let run = try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "e", count: 64),
            runIdentifier: privateRunIdentifier
        )
        let token = try XCTUnwrap(try recorder.begin(
            providerKind: .chat,
            operationKind: .modelInspect,
            requestIdentifier: UUID(
                uuidString:
                    "12345678-1234-1234-1234-123456789abc"
            )!,
            requestTraceMaterial:
                "PRIVATE_PROVIDER_EVIDENCE_TRACE",
            startedAt: Self.fixedDate
        ))

        XCTAssertThrowsError(
            try recorder.sealEvidence(for: run)
        ) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestsPending
            )
        }
        XCTAssertTrue(recorder.complete(
            token,
            outcome: .succeeded,
            endedAt: Self.fixedDate.addingTimeInterval(1)
        ))

        let sealed = try recorder.sealEvidence(for: run)
        XCTAssertEqual(sealed.run, run)
        XCTAssertEqual(sealed.latestSequence, 1)
        XCTAssertEqual(sealed.observations.count, 1)
        XCTAssertEqual(
            sealed.observations.first?.outcome,
            .succeeded
        )

        XCTAssertThrowsError(try recorder.begin(
            providerKind: .embedding,
            operationKind: .embedding,
            requestIdentifier: UUID(),
            requestTraceMaterial: "late_begin_must_fail"
        )) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestAdmissionClosed
            )
        }
        XCTAssertFalse(recorder.complete(
            token,
            outcome: .failed
        ))
        XCTAssertEqual(
            try recorder.sealEvidence(for: run),
            sealed,
            "Repeated sealing must return the one cached exact snapshot."
        )
        XCTAssertEqual(recorder.snapshot(), sealed.observations)
        XCTAssertEqual(
            recorder.stateSnapshot().observationCount,
            sealed.observations.count
        )

        let nextRun = try recorder.activate(
            processIdentifier: Int32(
                ProcessInfo.processInfo.processIdentifier
            ),
            admittedExecutableSHA256:
                String(repeating: "e", count: 64),
            runIdentifier: privateRunIdentifier
        )
        XCTAssertNotEqual(nextRun, run)
        XCTAssertEqual(
            nextRun.runIdentifierSHA256,
            run.runIdentifierSHA256
        )
        XCTAssertThrowsError(
            try recorder.sealEvidence(for: run)
        ) { error in
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRunMismatch
            )
        }
        XCTAssertEqual(sealed.observations.count, 1)

        let representation = String(
            decoding: try JSONEncoder().encode(sealed),
            as: UTF8.self
        ) + run.debugDescription
        XCTAssertFalse(
            representation.contains(privateRunIdentifier)
        )
        XCTAssertFalse(
            representation.contains(
                "PRIVATE_PROVIDER_EVIDENCE_TRACE"
            )
        )
    }

    func testSealedProviderEvidenceRefusesChatTransportBeforeStart()
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
            runIdentifier: "sealed_chat_transport_refusal"
        )
        _ = try recorder.sealEvidence(for: run)

        let transport = ScriptedOllamaChatTransport(scripts: [])
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        do {
            _ = try await provider.streamChat(.init(
                modelIdentifier: Self.model,
                messages: [
                    .init(
                        role: .user,
                        content: "Synthetic sealed-evidence request."
                    ),
                ]
            ))
            XCTFail("Expected evidence admission refusal")
        } catch {
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestAdmissionClosed
            )
        }
        XCTAssertTrue(transport.recordedRequests().isEmpty)
        XCTAssertEqual(transport.cancellationCount(), 0)
    }

    func testProviderEvidenceCapacityRefusesChatTransportBeforeStart()
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
            runIdentifier: "capacity_chat_transport_refusal"
        )
        try P8FProviderCorrelationCapacityTestFixture.fill(
            recorder
        )

        let transport = ScriptedOllamaChatTransport(scripts: [])
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        do {
            _ = try await provider.streamChat(.init(
                modelIdentifier: Self.model,
                messages: [
                    .init(
                        role: .user,
                        content: "Synthetic capacity request."
                    ),
                ]
            ))
            XCTFail("Expected evidence capacity refusal")
        } catch {
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceObservationCapacityExceeded
            )
        }
        XCTAssertTrue(transport.recordedRequests().isEmpty)
        XCTAssertEqual(transport.cancellationCount(), 0)
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
    }

    func testChatProviderCorrelatesSuccessfulInspectAndCancelledStream()
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
                String(repeating: "b", count: 64)
        )

        let show = try Self.jsonData([
            "capabilities": ["completion"],
            "model_info": [
                "synthetic.context_length": 8_192,
            ],
        ])
        let transport = ScriptedOllamaChatTransport(
            scripts: [
                .init(chunks: [show]),
                .init(chunks: [], holdsOpen: true),
            ]
        )
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )

        _ = try await provider.inspectModel(
            modelIdentifier: Self.model,
            modelDigest: nil,
            providerVersion: "0.30.6"
        )
        let handle = try await provider.streamChat(
            .init(
                modelIdentifier: Self.model,
                messages: [
                    .init(
                        role: .user,
                        content:
                            "Synthetic cancellation fixture."
                    ),
                ]
            )
        )
        await provider.cancel(requestID: handle.requestID)

        let observations = recorder.snapshot()
        XCTAssertEqual(
            observations.map(\.providerKind),
            [.chat, .chat]
        )
        XCTAssertEqual(
            observations.map(\.operationKind),
            [.modelInspect, .chatStream]
        )
        XCTAssertEqual(
            observations.map(\.outcome),
            [.succeeded, .cancelled]
        )
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
    }

    func testCloudModelIdentifiersAreRejectedBeforeShowOrChatTransport() async throws {
        let transport = ScriptedOllamaChatTransport(scripts: [])
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let cloudModel = "gpt-oss:120b-CLOUD"

        do {
            _ = try await provider.inspectModel(
                modelIdentifier: cloudModel,
                modelDigest: nil,
                providerVersion: "0.30.6"
            )
            XCTFail("Expected cloud model rejection before /api/show transport")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .cloudModelRejected)
        }

        do {
            _ = try await provider.streamChat(.init(
                modelIdentifier: cloudModel,
                messages: [.init(role: .user, content: "Synthetic request.")]
            ))
            XCTFail("Expected cloud model rejection before /api/chat transport")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .cloudModelRejected)
        }

        XCTAssertTrue(
            transport.recordedRequests().isEmpty,
            "Cloud identifiers must not cross either Ollama transport boundary"
        )
        XCTAssertEqual(
            transport.cancellationCount(),
            0,
            "Cloud rejection must occur before a transport request exists to cancel"
        )
    }

    func testInspectModelUsesFixedShowEndpointAndExtractsDeclaredCapabilitiesAndContext() async throws {
        let show = try Self.jsonData([
            "capabilities": ["completion", "tools", "thinking"],
            "model_info": [
                "general.architecture": "synthetic",
                "synthetic.context_length": 131_072,
                "synthetic.embedding_length": 4_096,
                "synthetic.vision.context_length": 8_192,
            ],
            "template": "must-not-be-persisted",
            "license": "must-not-be-persisted",
        ])
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: Self.fragment(show, sizes: [1, 2, 5, 13, 21])),
        ])
        let traces = OllamaChatTraceRecorder()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { event in traces.record(event) }
        )

        let profile = try await provider.inspectModel(
            modelIdentifier: Self.model,
            displayName: "Synthetic Chat",
            modelDigest: "digest-1",
            providerVersion: "0.30.6"
        )

        XCTAssertEqual(profile.provider, "ollama")
        XCTAssertEqual(profile.modelIdentifier, Self.model)
        XCTAssertEqual(profile.modelDigest, "digest-1")
        XCTAssertEqual(profile.estimatedCapabilities, [.chat, .toolCalling, .reasoning, .contextWindow])
        XCTAssertEqual(profile.contextPolicy.declaredContextTokens, 131_072)
        XCTAssertEqual(profile.contextPolicy.classification, .extended)
        XCTAssertEqual(profile.reasoningControl, .ollamaBoolean)

        let capture = try XCTUnwrap(transport.recordedRequests().first)
        XCTAssertEqual(capture.request.url?.absoluteString, "http://127.0.0.1:11434/api/show")
        XCTAssertEqual(capture.request.httpMethod, "POST")
        XCTAssertNil(capture.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(capture.request.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertNil(capture.request.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(capture.request.httpBody)
        let bodyObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(bodyObject["model"] as? String, Self.model)
        XCTAssertEqual(bodyObject["verbose"] as? Bool, false)

        let encodedTraces = try JSONEncoder().encode(traces.snapshot())
        let traceText = String(decoding: encodedTraces, as: UTF8.self)
        XCTAssertFalse(traceText.contains(Self.model))
        XCTAssertFalse(traceText.contains("must-not-be-persisted"))
        XCTAssertTrue(traceText.contains(OllamaChatTracePrivacy.modelIdentifierHash(Self.model)))
    }

    func testFragmentedNDJSONSeparatesEphemeralThinkingVisibleTextAndAllowlistedTool() async throws {
        let secretThinking = "PRIVATE_MODEL_THINKING_MUST_NOT_ESCAPE"
        let first = try Self.chatChunk(
            content: "",
            thinking: secretThinking,
            done: false
        )
        let second = try Self.chatChunk(
            content: "Visible ",
            done: false
        )
        let third = try Self.chatChunk(
            content: "answer",
            toolCalls: [[
                "function": [
                    "name": "get_synthetic_status",
                    "arguments": ["probe": "ok"],
                ],
            ]],
            done: true
        )
        let combined = first + second + third
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: Self.fragment(combined, sizes: [1, 3, 2, 11, 5, 17])),
        ])
        let traces = OllamaChatTraceRecorder()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { event in traces.record(event) }
        )
        let tool = try Self.toolDefinition(name: "get_synthetic_status")
        let handle = try await provider.streamChat(.init(
            modelIdentifier: Self.model,
            messages: [.init(role: .user, content: "Synthetic request.")],
            tools: [tool]
        ))

        var visible = ""
        var ephemeralThinking = ""
        var toolCalls: [OllamaChatToolCall] = []
        var completion: OllamaChatCompletion?
        for try await event in handle.events {
            switch event {
            case let .thinkingDelta(delta):
                ephemeralThinking += delta
            case let .contentDelta(delta):
                visible += delta
            case let .toolCall(call):
                toolCalls.append(call)
            case let .completed(value):
                completion = value
            case .responseStarted:
                break
            }
        }

        XCTAssertEqual(visible, "Visible answer")
        XCTAssertEqual(completion?.content, "Visible answer")
        XCTAssertEqual(ephemeralThinking, secretThinking)
        XCTAssertEqual(completion?.ephemeralThinking, secretThinking)
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.name, "get_synthetic_status")
        let arguments = try XCTUnwrap(toolCalls.first?.argumentsJSON)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: arguments) as? [String: Any])?["probe"] as? String,
            "ok"
        )
        XCTAssertFalse(visible.contains(secretThinking))

        let traceData = try JSONEncoder().encode(traces.snapshot())
        let traceText = String(decoding: traceData, as: UTF8.self)
        XCTAssertFalse(traceText.contains(secretThinking))
        XCTAssertFalse(traceText.contains("Synthetic request"))
        XCTAssertFalse(traceText.contains("Visible answer"))
        XCTAssertFalse(traceText.contains(Self.model))

        let requestBody = try XCTUnwrap(transport.recordedRequests().first?.request.httpBody)
        let requestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestObject["think"] as? Bool, false)
    }

    func testGPTOSSArchitectureUsesBoundedLowReasoningWithoutRetainingThinking() async throws {
        let show = try Self.jsonData([
            "capabilities": ["completion", "tools", "thinking"],
            "model_info": [
                "general.architecture": "gptoss",
                "gptoss.context_length": 131_072,
            ],
        ])
        let response = try Self.chatChunk(
            content: "SYSTEM_OK",
            thinking: "PRIVATE_SYNTHETIC_REASONING",
            done: true
        )
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [show]),
            .init(chunks: [response]),
        ])
        let provider = NativeOllamaChatProvider(transport: transport, traceSink: { _ in })
        let profile = try await provider.inspectModel(
            modelIdentifier: Self.model,
            modelDigest: "digest-gptoss",
            providerVersion: "0.30.6"
        )
        XCTAssertEqual(profile.reasoningControl, .ollamaLow)

        let handle = try await provider.streamChat(.init(
            modelIdentifier: profile.modelIdentifier,
            messages: [.init(role: .user, content: "Synthetic request.")],
            stream: false,
            reasoningControl: profile.reasoningControl
        ))
        var completion: OllamaChatCompletion?
        for try await event in handle.events {
            if case let .completed(value) = event {
                completion = value
            }
        }
        XCTAssertEqual(completion?.content, "SYSTEM_OK")
        XCTAssertEqual(completion?.ephemeralThinking, "PRIVATE_SYNTHETIC_REASONING")
        XCTAssertFalse(completion?.content.contains("PRIVATE_SYNTHETIC_REASONING") == true)

        let requestBody = try XCTUnwrap(transport.recordedRequests().last?.request.httpBody)
        let requestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestObject["think"] as? String, "low")
    }

    func testVerifiedReasoningControlsMapToExactOllamaTransportValues() async throws {
        let response = try Self.chatChunk(content: "OK", done: true)
        let transport = ScriptedOllamaChatTransport(scripts: Array(
            repeating: .init(chunks: [response]),
            count: 5
        ))
        let provider = NativeOllamaChatProvider(transport: transport, traceSink: { _ in })
        let controls: [(ModelReasoningControl, AnyHashable)] = [
            (.disabled, false),
            (.ollamaBoolean, true),
            (.ollamaLow, "low"),
            (.ollamaMedium, "medium"),
            (.ollamaHigh, "high"),
        ]

        for (control, _) in controls {
            let handle = try await provider.streamChat(.init(
                modelIdentifier: Self.model,
                messages: [.init(role: .user, content: "Synthetic request.")],
                stream: false,
                reasoningControl: control
            ))
            for try await _ in handle.events {}
        }

        let bodies = try transport.recordedRequests().map { capture -> [String: Any] in
            let data = try XCTUnwrap(capture.request.httpBody)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
        }
        XCTAssertEqual(bodies.count, controls.count)
        XCTAssertEqual(bodies[0]["think"] as? Bool, false)
        XCTAssertEqual(bodies[1]["think"] as? Bool, true)
        XCTAssertEqual(bodies[2]["think"] as? String, "low")
        XCTAssertEqual(bodies[3]["think"] as? String, "medium")
        XCTAssertEqual(bodies[4]["think"] as? String, "high")
    }

    func testImageMessageUsesBoundedBase64ContractWithoutChangingVisibleContent() async throws {
        let response = try Self.chatChunk(content: "Image acknowledged.", done: true)
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [response]),
        ])
        let provider = NativeOllamaChatProvider(transport: transport, traceSink: { _ in })
        let modelBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let handle = try await provider.streamChat(.init(
            modelIdentifier: Self.model,
            messages: [
                .init(
                    role: .user,
                    content: "Describe the repository-owned synthetic image.",
                    images: [modelBytes]
                ),
            ],
            stream: false
        ))

        var completion: OllamaChatCompletion?
        for try await event in handle.events {
            if case let .completed(value) = event {
                completion = value
            }
        }
        XCTAssertEqual(completion?.content, "Image acknowledged.")

        let requestBody = try XCTUnwrap(transport.recordedRequests().first?.request.httpBody)
        let requestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let messages = try XCTUnwrap(requestObject["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Describe the repository-owned synthetic image.")
        XCTAssertEqual(
            messages.first?["images"] as? [String],
            [modelBytes.base64EncodedString()]
        )
    }

    func testUnregisteredModelToolRequestIsRejectedBeforeItCanReachApplicationCode() async throws {
        let response = try Self.chatChunk(
            toolCalls: [[
                "function": [
                    "name": "unregistered_write_tool",
                    "arguments": [:],
                ],
            ]],
            done: true
        )
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [response]),
        ])
        let provider = NativeOllamaChatProvider(transport: transport, traceSink: { _ in })
        let allowed = try Self.toolDefinition(name: "get_synthetic_status")
        let handle = try await provider.streamChat(.init(
            modelIdentifier: Self.model,
            messages: [.init(role: .user, content: "Synthetic request.")],
            tools: [allowed],
            stream: false
        ))

        do {
            for try await _ in handle.events { }
            XCTFail("Expected the unregistered model tool request to fail closed.")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .invalidToolCall)
        }
    }

    func testCancellationTerminatesStreamAndRejectsLateCompletion() async throws {
        let first = try Self.chatChunk(content: "one ", done: false)
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [first], holdsOpen: true),
        ])
        let traces = OllamaChatTraceRecorder()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            traceSink: { event in traces.record(event) }
        )
        let handle = try await provider.streamChat(.init(
            modelIdentifier: Self.model,
            messages: [.init(role: .user, content: "Synthetic long response.")],
            stream: true
        ))

        var sawContent = false
        var sawCompletion = false
        do {
            for try await event in handle.events {
                switch event {
                case .contentDelta:
                    sawContent = true
                    await provider.cancel(requestID: handle.requestID)
                case .completed:
                    sawCompletion = true
                case .responseStarted, .thinkingDelta, .toolCall:
                    break
                }
            }
            XCTFail("Expected cancellation to terminate the stream with a typed failure.")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .requestCancelled)
        }

        XCTAssertTrue(sawContent)
        XCTAssertFalse(sawCompletion)
        XCTAssertEqual(transport.cancellationCount(), 1)
        XCTAssertTrue(traces.snapshot().contains {
            $0.event == .chatCanceled
                && $0.reasonCode == OllamaChatFailureCode.requestCancelled.rawValue
        })
    }

    func testCancellationDuringThinkingOnlyClearsTransportWithoutVisibleOrLoggedReasoning()
        async throws
    {
        let privateReasoning = "PRIVATE_THINKING_ONLY_CANCEL_SENTINEL"
        let thinking = try Self.chatChunk(
            content: "",
            thinking: privateReasoning,
            done: false
        )
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [thinking], holdsOpen: true),
        ])
        let traces = OllamaChatTraceRecorder()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            traceSink: { event in traces.record(event) }
        )
        let handle = try await provider.streamChat(.init(
            modelIdentifier: Self.model,
            messages: [.init(role: .user, content: "Synthetic cancellation.")],
            stream: true,
            reasoningControl: .ollamaLow
        ))

        var visibleContent = ""
        var sawCompletion = false
        do {
            for try await event in handle.events {
                switch event {
                case .thinkingDelta:
                    await provider.cancel(requestID: handle.requestID)
                case let .contentDelta(delta):
                    visibleContent += delta
                case .completed:
                    sawCompletion = true
                case .responseStarted, .toolCall:
                    break
                }
            }
            XCTFail("Expected thinking-only cancellation to terminate the stream.")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .requestCancelled)
        }

        XCTAssertTrue(visibleContent.isEmpty)
        XCTAssertFalse(sawCompletion)
        XCTAssertEqual(transport.cancellationCount(), 1)
        let traceText = String(
            decoding: try JSONEncoder().encode(traces.snapshot()),
            as: UTF8.self
        )
        XCTAssertFalse(traceText.contains(privateReasoning))
    }

    func testCompleteSyntheticAssessmentProvesRequirementsWithoutNameHeuristics() async throws {
        let ordinary = try Self.chatChunk(content: "SYSTEM_OK", done: true)
        let streamOne = try Self.chatChunk(content: "one ", done: false)
        let streamTwo = try Self.chatChunk(content: "two", done: true)
        let structured = try Self.chatChunk(content: #"{"probe":"ok"}"#, done: true)
        let tool = try Self.chatChunk(
            toolCalls: [[
                "function": [
                    "name": "get_synthetic_probe_status",
                    "arguments": ["probe": "capability"],
                ],
            ]],
            done: true
        )
        let continuation = try Self.chatChunk(content: "Synthetic result received.", done: true)
        let cancellation = try Self.chatChunk(content: "one ", done: false)
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [ordinary]),
            .init(chunks: Self.fragment(streamOne + streamTwo, sizes: [2, 7, 3, 19])),
            .init(chunks: [structured]),
            .init(chunks: [tool]),
            .init(chunks: [continuation]),
            .init(chunks: [cancellation], holdsOpen: true),
        ])
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { _ in }
        )
        let profile = ModelProfile(
            provider: "ollama",
            providerVersion: "0.30.6",
            modelIdentifier: Self.model,
            displayName: "Arbitrary",
            modelDigest: "digest-v1",
            locallyInstalled: true,
            estimatedCapabilities: [],
            contextPolicy: .init(declaredContextTokens: 131_072),
            observedAt: Self.fixedDate
        )

        let assessment = await provider.assessModel(profile)
        let required = Set(ModelCapabilityRequirement.agentLokiChat
            .filter { $0.level == .required }
            .map(\.capability))
        XCTAssertTrue(required.isSubset(of: assessment.capabilitiesProven))
        XCTAssertTrue(assessment.capabilitiesProven.contains(.systemInstructions))
        XCTAssertTrue(assessment.capabilitiesProven.contains(.contextWindow))
        XCTAssertFalse(assessment.capabilitiesProven.contains(.reasoning))
        XCTAssertEqual(assessment.assessmentVersion, ModelCapabilityAssessment.currentAssessmentVersion)
        XCTAssertEqual(transport.recordedRequests().count, 6)

        let readiness = ModelReadinessEvaluation.evaluate(
            profile: profile,
            assessment: assessment,
            providerInstalled: true,
            providerRunning: true,
            modelAvailable: true
        )
        XCTAssertEqual(readiness.readiness, .ready)
        XCTAssertEqual(transport.cancellationCount(), 1)

        // Block the first probe, then reproduce the signed-smoke abort order:
        // cancel the assessment task before draining provider transports. The
        // cancelled assessment must not admit its successor streaming probe.
        let cancelledTraces = OllamaChatTraceRecorder()
        let cancelledTransport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [], holdsOpen: true),
            .init(chunks: []),
            .init(chunks: []),
            .init(chunks: []),
            .init(chunks: []),
            .init(chunks: []),
        ])
        let cancelledProvider = NativeOllamaChatProvider(
            transport: cancelledTransport,
            now: { Self.fixedDate },
            traceSink: { event in
                cancelledTraces.record(event)
            }
        )
        let cancelledTask = Task {
            await cancelledProvider.assessModel(profile)
        }
        let clock = ContinuousClock()
        let admissionDeadline = clock.now.advanced(
            by: .seconds(2)
        )
        while cancelledTransport.recordedRequests().count < 1,
              clock.now < admissionDeadline
        {
            await Task.yield()
        }
        XCTAssertEqual(
            cancelledTransport.recordedRequests().count,
            1,
            "The cancellation fixture must block inside probe one."
        )

        cancelledTask.cancel()
        await cancelledProvider.cancelAll()
        let cancelledAssessment = await cancelledTask.value

        XCTAssertEqual(cancelledTransport.recordedRequests().count, 1)
        XCTAssertEqual(cancelledTransport.cancellationCount(), 1)
        XCTAssertEqual(cancelledTransport.pendingRequestCount(), 0)
        XCTAssertTrue(cancelledAssessment.capabilitiesProven.isEmpty)
        XCTAssertTrue(cancelledAssessment.diagnostics.contains {
            $0.status == .cancelled
                && $0.reasonCode
                    == OllamaChatFailureCode.requestCancelled.rawValue
        })
        XCTAssertEqual(
            cancelledTraces.snapshot().last(where: {
                $0.event == .modelAssessmentCompleted
            })?.status,
            .skipped
        )
        XCTAssertEqual(
            cancelledTraces.snapshot().last(where: {
                $0.event == .modelAssessmentCompleted
            })?.reasonCode,
            OllamaChatFailureCode.requestCancelled.rawValue
        )
        XCTAssertEqual(
            cancelledTraces.snapshot().last(where: {
                $0.event == .modelAssessmentCompleted
            })?.metadata["state"],
            "cancelled"
        )

        // A second drain is inert only when the provider actor retained no
        // active assessment stream after the cancelled task returned.
        await cancelledProvider.cancelAll()
        XCTAssertEqual(cancelledTransport.cancellationCount(), 1)
    }

    func testCancelledAssessmentDrainsBeforeIndependentSuccessorAssessment()
        async throws
    {
        let ordinary = try Self.chatChunk(
            content: "SYSTEM_OK",
            done: true
        )
        let streamOne = try Self.chatChunk(
            content: "one ",
            done: false
        )
        let streamTwo = try Self.chatChunk(
            content: "two",
            done: true
        )
        let structured = try Self.chatChunk(
            content: #"{"probe":"ok"}"#,
            done: true
        )
        let tool = try Self.chatChunk(
            toolCalls: [[
                "function": [
                    "name": "get_synthetic_probe_status",
                    "arguments": ["probe": "capability"],
                ],
            ]],
            done: true
        )
        let continuation = try Self.chatChunk(
            content: "Synthetic result received.",
            done: true
        )
        let cancellation = try Self.chatChunk(
            content: "one ",
            done: false
        )
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(chunks: [], holdsOpen: true),
            .init(chunks: [ordinary]),
            .init(chunks: Self.fragment(
                streamOne + streamTwo,
                sizes: [2, 7, 3, 19]
            )),
            .init(chunks: [structured]),
            .init(chunks: [tool]),
            .init(chunks: [continuation]),
            .init(chunks: [cancellation], holdsOpen: true),
        ])
        let traces = OllamaChatTraceRecorder()
        let provider = NativeOllamaChatProvider(
            transport: transport,
            now: { Self.fixedDate },
            traceSink: { event in traces.record(event) }
        )
        let profile = ModelProfile(
            provider: "ollama",
            providerVersion: "0.30.6",
            modelIdentifier: Self.model,
            displayName: "Independent successor fixture",
            modelDigest: "digest-successor",
            locallyInstalled: true,
            estimatedCapabilities: [],
            contextPolicy: .init(
                declaredContextTokens: 131_072
            ),
            observedAt: Self.fixedDate
        )

        let cancelledTask = Task {
            await provider.assessModel(profile)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while transport.recordedRequests().count < 1,
              clock.now < deadline
        {
            await Task.yield()
        }
        XCTAssertEqual(transport.recordedRequests().count, 1)

        cancelledTask.cancel()
        await provider.cancelAll()
        let cancelledAssessment = await cancelledTask.value
        XCTAssertTrue(cancelledAssessment.capabilitiesProven.isEmpty)
        XCTAssertTrue(cancelledAssessment.diagnostics.contains {
            $0.status == .cancelled
        })
        XCTAssertEqual(transport.pendingRequestCount(), 0)

        let successorAssessment = await provider.assessModel(
            profile
        )
        let required = Set(
            ModelCapabilityRequirement.agentLokiChat
                .filter { $0.level == .required }
                .map(\.capability)
        )
        XCTAssertTrue(required.isSubset(
            of: successorAssessment.capabilitiesProven
        ))
        XCTAssertFalse(successorAssessment.diagnostics.contains {
            $0.status == .cancelled
        })
        XCTAssertEqual(transport.recordedRequests().count, 7)
        XCTAssertEqual(transport.cancellationCount(), 2)
        XCTAssertEqual(transport.pendingRequestCount(), 0)

        let successorCompletion = traces.snapshot().last(where: {
            $0.event == .modelAssessmentCompleted
        })
        XCTAssertEqual(successorCompletion?.status, .success)
        XCTAssertEqual(
            successorCompletion?.metadata["state"],
            ModelReadiness.ready.rawValue
        )
    }

    func testRedirectedShowResponseFailsClosed() async throws {
        let body = try Self.jsonData([
            "capabilities": ["completion"],
            "model_info": [:],
        ])
        let transport = ScriptedOllamaChatTransport(scripts: [
            .init(
                finalURL: URL(string: "http://127.0.0.1:11434/api/other"),
                chunks: [body]
            ),
        ])
        let provider = NativeOllamaChatProvider(transport: transport, traceSink: { _ in })

        do {
            _ = try await provider.inspectModel(
                modelIdentifier: Self.model,
                modelDigest: "digest",
                providerVersion: "0.30.6"
            )
            XCTFail("Expected the redirected response to fail closed.")
        } catch let failure as OllamaChatFailure {
            XCTAssertEqual(failure.code, .redirectRejected)
        }
    }

    func testNDJSONDecoderHandlesArbitraryFragmentationAndRejectsOversizedLine() throws {
        let first = Data(#"{"a":1}"#.utf8)
        let second = Data(#"{"b":2}"#.utf8)
        let combined = first + Data([0x0A]) + second
        var decoder = OllamaNDJSONLineDecoder()
        var lines: [Data] = []
        for byte in combined {
            lines.append(contentsOf: try decoder.append(Data([byte])))
        }
        lines.append(contentsOf: try decoder.finish())
        XCTAssertEqual(lines, [first, second])

        var oversized = OllamaNDJSONLineDecoder()
        XCTAssertThrowsError(try oversized.append(Data(
            repeating: 0x61,
            count: OllamaChatProviderLimits.maximumNDJSONLineBytes + 1
        ))) { error in
            XCTAssertEqual((error as? OllamaChatFailure)?.code, .ndjsonLineTooLarge)
        }
    }

    func testBoundedTransportRejectsRemoteOrCredentialedRequestsBeforeNetwork() async {
        let transport = BoundedOllamaChatTransport()
        let targets = [
            "http://example.com:11434/api/chat",
            "http://user:secret@127.0.0.1:11434/api/chat",
            "http://127.0.0.1:11434/api/chat?token=forbidden",
        ]
        for target in targets {
            var request = URLRequest(url: URL(string: target)!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            let events = transport.stream(
                for: request,
                requestID: UUID(),
                responseLimit: 1_024
            )
            do {
                for try await _ in events { }
                XCTFail("Expected endpoint policy rejection for \(target).")
            } catch let failure as OllamaChatFailure {
                XCTAssertEqual(failure.code, .invalidEndpoint)
            } catch {
                XCTFail("Unexpected endpoint error: \(error)")
            }
        }
    }

    private static func waitForProtocolCounts(
        _ state: ChatCancellationProtocolState,
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

    private static func toolDefinition(name: String) throws -> OllamaChatToolDefinition {
        .init(
            name: name,
            description: "One synthetic read-only tool.",
            parametersJSONSchema: try jsonData([
                "type": "object",
                "properties": [
                    "probe": ["type": "string"],
                ],
                "additionalProperties": false,
            ])
        )
    }

    private static func chatChunk(
        content: String = "",
        thinking: String? = nil,
        toolCalls: [[String: Any]] = [],
        done: Bool
    ) throws -> Data {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        if let thinking {
            message["thinking"] = thinking
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        var object: [String: Any] = [
            "model": model,
            "message": message,
            "done": done,
        ]
        if done {
            object["done_reason"] = "stop"
            object["total_duration"] = 15_000_000
            object["prompt_eval_count"] = 12
            object["eval_count"] = 8
        }
        return try jsonData(object) + Data([0x0A])
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func fragment(_ data: Data, sizes: [Int]) -> [Data] {
        guard !data.isEmpty else { return [] }
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let requested = sizes[index % sizes.count]
            let end = min(data.count, offset + max(1, requested))
            chunks.append(Data(data[offset..<end]))
            offset = end
            index += 1
        }
        return chunks
    }
}
