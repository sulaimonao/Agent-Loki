import Foundation
import XCTest
@testable import LokiBrief

private final class EmbeddingTransportDouble: OllamaChatTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var response: Data
    private var captures: [URLRequest] = []

    init(response: Data) {
        self.response = response
    }

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        lock.withLock { captures.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(
                statusCode: 200,
                finalURL: request.url,
                expectedContentLength: Int64(response.count)
            )))
            continuation.yield(.bytes(response))
            continuation.finish()
        }
    }

    func cancel(requestID: UUID) async {}

    func recordedRequests() -> [URLRequest] {
        lock.withLock { captures }
    }
}

private final class HoldingEmbeddingTransportDouble:
    OllamaChatTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var pending: [
        UUID:
            AsyncThrowingStream<
                OllamaChatTransportEvent,
                Error
            >.Continuation
    ] = [:]
    private var started = false
    private var startedWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<
        OllamaChatTransportEvent,
        Error
    > {
        AsyncThrowingStream { continuation in
            let waiters = lock.withLock {
                pending[requestID] = continuation
                started = true
                let waiters = startedWaiters
                startedWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func cancel(requestID: UUID) async {
        lock.withLock {
            pending.removeValue(forKey: requestID)
        }?.finish(
            throwing: OllamaChatFailure(
                .requestCancelled
            )
        )
    }

    func waitUntilStarted() async {
        if lock.withLock({ started }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if started { return true }
                startedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class AssociatingEmbeddingTransportDouble:
    OllamaChatTransporting,
    @unchecked Sendable
{
    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                let model = try XCTUnwrap(object["model"] as? String)
                let inputs = try XCTUnwrap(object["input"] as? [String])
                let vectors = inputs.map { input -> [Double] in
                    input == "one" ? [1, 0] : [0, 1]
                }
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "model": model,
                        "embeddings": vectors,
                    ],
                    options: [.sortedKeys]
                )
                continuation.yield(.response(.init(
                    statusCode: 200,
                    finalURL: request.url!,
                    expectedContentLength: Int64(response.count)
                )))
                continuation.yield(.bytes(response))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel(requestID: UUID) async {}
}

private final class StabilityEmbeddingTransportDouble:
    OllamaChatTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let epsilonMagnitude: Double
    private let collapseDifferentInputs: Bool
    private let collapseAfterFloatQuantization: Bool
    private var sequence = 0

    init(
        epsilonMagnitude: Double = 0.000_01,
        collapseDifferentInputs: Bool = false,
        collapseAfterFloatQuantization: Bool = false
    ) {
        self.epsilonMagnitude = epsilonMagnitude
        self.collapseDifferentInputs = collapseDifferentInputs
        self.collapseAfterFloatQuantization =
            collapseAfterFloatQuantization
    }

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                let model = try XCTUnwrap(object["model"] as? String)
                let inputs = try XCTUnwrap(object["input"] as? [String])
                let currentSequence = lock.withLock {
                    sequence += 1
                    return sequence
                }
                let epsilon =
                    currentSequence.isMultiple(of: 2)
                        ? epsilonMagnitude
                        : -epsilonMagnitude
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "model": model,
                        "embeddings": inputs.map {
                            Self.vector(
                                for: $0,
                                epsilon: epsilon,
                                collapseDifferentInputs:
                                    collapseDifferentInputs,
                                collapseAfterFloatQuantization:
                                    collapseAfterFloatQuantization
                            )
                        },
                        "prompt_eval_count": inputs.count,
                    ],
                    options: [.sortedKeys]
                )
                continuation.yield(.response(.init(
                    statusCode: 200,
                    finalURL: request.url!,
                    expectedContentLength: Int64(response.count)
                )))
                continuation.yield(.bytes(response))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel(requestID: UUID) async {}

    private static func vector(
        for input: String,
        epsilon: Double,
        collapseDifferentInputs: Bool,
        collapseAfterFloatQuantization: Bool
    ) -> [Double] {
        var vector = Array(repeating: 0.0, count: 8)
        vector[6] = epsilon
        if collapseDifferentInputs {
            vector[7] = 1
            return vector
        }
        if collapseAfterFloatQuantization {
            let checksum = input.utf8.reduce(0) {
                ($0 + Int($1)) % 10
            }
            vector[7] =
                1 + Double(checksum + 1) * 0.000_000_001
            return vector
        }
        if let document =
            OllamaEmbeddingStabilityFixture.p8e.documents.first(
                where: { $0.text == input }
            ) {
            let components = document.identifier.split(
                separator: "-"
            )
            let topic = topicIndex(String(components[0]))
            let rank = Int(components[1]) ?? 5
            vector[topic] = 1
            vector[5] = Double(6 - rank) / 10
        } else if let query =
            OllamaEmbeddingStabilityFixture.p8e.queries.first(
                where: { $0.text == input }
            ) {
            let topic = query.identifier.replacingOccurrences(
                of: "query-",
                with: ""
            )
            vector[topicIndex(topic)] = 1
            vector[5] = 0.55
        } else {
            vector[7] = 1
        }
        return vector
    }

    private static func topicIndex(_ topic: String) -> Int {
        switch topic {
        case "orbital": 0
        case "wind": 1
        case "cello": 2
        case "rye": 3
        case "reef": 4
        default: 0
        }
    }
}

private final class EmbeddingEvidenceRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var requestReceipts:
        [OllamaEmbeddingStabilityRequestReceipt] = []
    private var comparisonReceipts:
        [OllamaEmbeddingStabilityComparisonReceipt] = []
    private var rankingReceipts:
        [OllamaEmbeddingStabilityRankingReceipt] = []

    func recordRequest(
        _ receipt: OllamaEmbeddingStabilityRequestReceipt
    ) {
        lock.withLock {
            requestReceipts.append(receipt)
        }
    }

    func recordComparison(
        _ receipt: OllamaEmbeddingStabilityComparisonReceipt
    ) {
        lock.withLock {
            comparisonReceipts.append(receipt)
        }
    }

    func recordRanking(
        _ receipt: OllamaEmbeddingStabilityRankingReceipt
    ) {
        lock.withLock {
            rankingReceipts.append(receipt)
        }
    }

    func requestSnapshot()
        -> [OllamaEmbeddingStabilityRequestReceipt]
    {
        lock.withLock { requestReceipts }
    }

    func comparisonSnapshot()
        -> [OllamaEmbeddingStabilityComparisonReceipt]
    {
        lock.withLock { comparisonReceipts }
    }

    func rankingSnapshot()
        -> [OllamaEmbeddingStabilityRankingReceipt]
    {
        lock.withLock { rankingReceipts }
    }
}

final class NativeOllamaEmbeddingProviderTests: XCTestCase {
    func testSealedProviderEvidenceRefusesEmbeddingTransportBeforeStart()
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
            runIdentifier: "sealed_embedding_transport_refusal"
        )
        _ = try recorder.sealEvidence(for: run)

        let transport = EmbeddingTransportDouble(
            response: Data()
        )
        let provider = NativeOllamaEmbeddingProvider(
            transport: transport
        )
        do {
            _ = try await provider.embed(.init(
                modelIdentifier: "qwen3-embedding:0.6b",
                inputs: ["Synthetic sealed-evidence input."],
                dimensions: 2
            ))
            XCTFail("Expected evidence admission refusal")
        } catch {
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceRequestAdmissionClosed
            )
        }
        XCTAssertTrue(transport.recordedRequests().isEmpty)
    }

    func testProviderEvidenceCapacityRefusesEmbeddingTransportBeforeStart()
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
            runIdentifier:
                "capacity_embedding_transport_refusal"
        )
        try P8FProviderCorrelationCapacityTestFixture.fill(
            recorder
        )

        let transport = EmbeddingTransportDouble(
            response: Data()
        )
        let provider = NativeOllamaEmbeddingProvider(
            transport: transport
        )
        do {
            _ = try await provider.embed(.init(
                modelIdentifier: "qwen3-embedding:0.6b",
                inputs: ["Synthetic capacity input."],
                dimensions: 2
            ))
            XCTFail("Expected evidence capacity refusal")
        } catch {
            XCTAssertEqual(
                error as? P8FProviderRequestCorrelationFailure,
                .evidenceObservationCapacityExceeded
            )
        }
        XCTAssertTrue(transport.recordedRequests().isEmpty)
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
    }

    func testEmbeddingProviderCorrelatesSuccessAndParseFailureWithoutPayloads()
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
                String(repeating: "c", count: 64)
        )
        let privateInput =
            "PRIVATE_EMBEDDING_INPUT_321"
        let success = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(
                response: try Self.data([
                    "model": "qwen3-embedding:0.6b",
                    "embeddings": [[0.25, -0.25]],
                ])
            )
        )
        _ = try await success.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: [privateInput],
            dimensions: 2
        ))

        let failure = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(
                response: try Self.data([
                    "model": "qwen3-embedding:0.6b",
                    "embeddings": [[0.0, 0.0]],
                ])
            )
        )
        do {
            _ = try await failure.embed(.init(
                modelIdentifier:
                    "qwen3-embedding:0.6b",
                inputs: [privateInput],
                dimensions: 2
            ))
            XCTFail("Expected zero-vector rejection.")
        } catch let error as OllamaEmbeddingFailure {
            XCTAssertEqual(error.code, .zeroVector)
        }

        let observations = recorder.snapshot()
        XCTAssertEqual(
            observations.map(\.providerKind),
            [.embedding, .embedding]
        )
        XCTAssertEqual(
            observations.map(\.operationKind),
            [.embedding, .embedding]
        )
        XCTAssertEqual(
            observations.map(\.outcome),
            [.succeeded, .failed]
        )
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
        let representation = String(
            decoding: try JSONEncoder().encode(
                observations
            ),
            as: UTF8.self
        )
        XCTAssertFalse(
            representation.contains(privateInput)
        )
        XCTAssertFalse(
            representation.contains(
                "qwen3-embedding:0.6b"
            )
        )
    }

    func testEmbeddingProviderCorrelationClosesCancelledRequest()
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
                String(repeating: "e", count: 64)
        )
        let transport =
            HoldingEmbeddingTransportDouble()
        let provider = NativeOllamaEmbeddingProvider(
            transport: transport
        )
        let task = Task {
            try await provider.embed(.init(
                modelIdentifier:
                    "qwen3-embedding:0.6b",
                inputs: [
                    "Synthetic cancellation input.",
                ],
                dimensions: 2
            ))
        }
        await transport.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail(
                "Expected typed embedding cancellation."
            )
        } catch let failure
            as OllamaEmbeddingFailure
        {
            XCTAssertEqual(
                failure.code,
                .requestCancelled
            )
        }

        XCTAssertEqual(
            recorder.snapshot().map(\.outcome),
            [.cancelled]
        )
        XCTAssertEqual(
            recorder.stateSnapshot().pendingRequestCount,
            0
        )
    }

    func testSingleAndBatchEmbeddingParsingUsesObservedDynamicDimension() async throws {
        let response = try Self.data([
            "model": "qwen3-embedding:0.6b",
            "embeddings": [
                [0.1, 0.2, 0.3],
                [0.4, 0.5, 0.6],
            ],
            "total_duration": 123,
            "load_duration": 10,
            "prompt_eval_count": 7,
        ])
        let transport = EmbeddingTransportDouble(response: response)
        let provider = NativeOllamaEmbeddingProvider(transport: transport)
        let receipt = try await provider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["synthetic one", "synthetic two"]
        ))

        XCTAssertEqual(receipt.observedDimension, 3)
        XCTAssertEqual(receipt.vectors.count, 2)
        XCTAssertEqual(receipt.vectors[0], [0.1, 0.2, 0.3])
        XCTAssertEqual(receipt.vectors[1], [0.4, 0.5, 0.6])
        XCTAssertEqual(receipt.promptTokenCount, 7)
        XCTAssertEqual(
            receipt.requestIdentity?.requestProfileHash,
            "10915eb71e1315ed30662e29fe235312c4506d557eb54078cfe268f05b6ec285"
        )
        let request = try XCTUnwrap(transport.recordedRequests().first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/embed")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "qwen3-embedding:0.6b")
        XCTAssertEqual(object["input"] as? [String], ["synthetic one", "synthetic two"])
        XCTAssertEqual(object["truncate"] as? Bool, false)
        XCTAssertNil(object["dimensions"])
    }

    func testNumericZeroAndOneMetadataRemainDistinctFromBooleans()
        async throws
    {
        let numericProvider = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(response: try Self.data([
                "model": "qwen3-embedding:0.6b",
                "embeddings": [[0.25, -0.25]],
                "total_duration": 0,
                "load_duration": 1,
                "prompt_eval_count": 1,
            ]))
        )
        let numeric = try await numericProvider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["synthetic"]
        ))
        XCTAssertEqual(numeric.totalDurationNanoseconds, 0)
        XCTAssertEqual(numeric.loadDurationNanoseconds, 1)
        XCTAssertEqual(numeric.promptTokenCount, 1)

        let booleanProvider = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(response: try Self.data([
                "model": "qwen3-embedding:0.6b",
                "embeddings": [[0.25, -0.25]],
                "total_duration": false,
                "load_duration": true,
                "prompt_eval_count": true,
            ]))
        )
        let boolean = try await booleanProvider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["synthetic"]
        ))
        XCTAssertNil(boolean.totalDurationNanoseconds)
        XCTAssertNil(boolean.loadDurationNanoseconds)
        XCTAssertNil(boolean.promptTokenCount)
    }

    func testCanonicalRequestIdentityPinsNormalizedBytesAndExplicitDimension()
        throws
    {
        let request = OllamaEmbeddingRequest(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["Synthetic P8 embedding receipt."],
            dimensions: 1_024
        )
        let body = try NativeOllamaEmbeddingProvider
            .canonicalRequestData(for: request)
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"dimensions":1024,"input":["Synthetic P8 embedding receipt."],"model":"qwen3-embedding:0.6b","truncate":false}"#
        )
        let identity = try NativeOllamaEmbeddingProvider
            .requestIdentity(for: request)
        XCTAssertEqual(
            identity.normalizedInputHashes,
            [
                "bebfb409c646d6d2cb6c949db6923a05034b0b14d18079d855ff0e72538eaa21",
            ]
        )
        XCTAssertEqual(
            identity.canonicalRequestHash,
            "b2ce4cf5b66c1c1f08b8a2224f382a8cb986b950c1fbcac9ee91e0394baca0c5"
        )
        XCTAssertEqual(
            identity.requestProfileHash,
            "020a0ffa959bac764c72d2c5040b6a09091ce60063ecc4f2c8bf9ad9df9c5bb9"
        )
        XCTAssertEqual(
            request.profile.version,
            OllamaEmbeddingRequestProfile.currentVersion
        )
        XCTAssertEqual(request.profile.dimensions, 1_024)
        XCTAssertFalse(request.profile.truncate)
    }

    func testCanonicalRequestNormalizesNFCAndLineEndingsBeforeHashing()
        throws
    {
        let request = OllamaEmbeddingRequest(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["Cafe\u{301}\r\nsynthetic"]
        )
        let body = try NativeOllamaEmbeddingProvider
            .canonicalRequestData(for: request)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        XCTAssertEqual(object["input"] as? [String], ["Café\nsynthetic"])
        let first = try NativeOllamaEmbeddingProvider
            .requestIdentity(for: request)
        let second = try NativeOllamaEmbeddingProvider.requestIdentity(
            for: .init(
                modelIdentifier: request.modelIdentifier,
                inputs: ["Café\nsynthetic"]
            )
        )
        XCTAssertEqual(first, second)
    }

    func testMixedEmbeddingDimensionsFailClosed() async throws {
        let transport = EmbeddingTransportDouble(response: try Self.data([
            "model": "qwen3-embedding:0.6b",
            "embeddings": [[0.1, 0.2], [0.3]],
        ]))
        let provider = NativeOllamaEmbeddingProvider(transport: transport)
        do {
            _ = try await provider.embed(.init(
                modelIdentifier: "qwen3-embedding:0.6b",
                inputs: ["one", "two"]
            ))
            XCTFail("Expected mixed-dimension rejection.")
        } catch let failure as OllamaEmbeddingFailure {
            XCTAssertEqual(failure.code, .mixedDimensions)
        }
    }

    func testCloudEmbeddingReferenceIsRejectedBeforeTransport() async throws {
        let transport = EmbeddingTransportDouble(response: Data())
        let provider = NativeOllamaEmbeddingProvider(transport: transport)
        do {
            _ = try await provider.embed(.init(
                modelIdentifier: "qwen3-embedding:cloud",
                inputs: ["synthetic"]
            ))
            XCTFail("Expected cloud-model rejection.")
        } catch let failure as OllamaEmbeddingFailure {
            XCTAssertEqual(failure.code, .cloudModelRejected)
        }
        XCTAssertTrue(transport.recordedRequests().isEmpty)
    }

    func testExplicitDimensionMismatchAndZeroVectorFailClosed() async throws {
        let mismatch = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(response: try Self.data([
                "model": "qwen3-embedding:0.6b",
                "embeddings": [[0.1, 0.2]],
            ]))
        )
        do {
            _ = try await mismatch.embed(.init(
                modelIdentifier: "qwen3-embedding:0.6b",
                inputs: ["synthetic"],
                dimensions: 3
            ))
            XCTFail("Expected explicit dimension mismatch rejection.")
        } catch let failure as OllamaEmbeddingFailure {
            XCTAssertEqual(failure.code, .dimensionMismatch)
        }

        let collapsed = NativeOllamaEmbeddingProvider(
            transport: EmbeddingTransportDouble(response: try Self.data([
                "model": "qwen3-embedding:0.6b",
                "embeddings": [[0.0, 0.0]],
            ]))
        )
        do {
            _ = try await collapsed.embed(.init(
                modelIdentifier: "qwen3-embedding:0.6b",
                inputs: ["synthetic"],
                dimensions: 2
            ))
            XCTFail("Expected zero-vector rejection.")
        } catch let failure as OllamaEmbeddingFailure {
            XCTAssertEqual(failure.code, .zeroVector)
        }
    }

    func testDecodedNonFiniteVectorIsRejectedWithExactReason()
        throws
    {
        do {
            _ = try NativeOllamaEmbeddingProvider
                .validatedVectors(
                    [
                        [
                            NSNumber(value: Double.infinity),
                            NSNumber(value: 0.1),
                        ],
                    ],
                    expectedDimension: 2
                )
            XCTFail("Expected decoded non-finite rejection.")
        } catch let failure as OllamaEmbeddingFailure {
            XCTAssertEqual(failure.code, .nonFiniteVector)
        }
    }

    func testConcurrentAndBatchResponsesRemainAssociatedWithInputs()
        async throws
    {
        let provider = NativeOllamaEmbeddingProvider(
            transport: AssociatingEmbeddingTransportDouble()
        )
        async let first = provider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["one"],
            dimensions: 2
        ))
        async let second = provider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["two"],
            dimensions: 2
        ))
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.vectors, [[1, 0]])
        XCTAssertEqual(two.vectors, [[0, 1]])

        let batch = try await provider.embed(.init(
            modelIdentifier: "qwen3-embedding:0.6b",
            inputs: ["two", "one", "two"],
            dimensions: 2
        ))
        XCTAssertEqual(batch.vectors, [[0, 1], [1, 0], [0, 1]])
    }

    func testVectorMetricsAcceptBoundedVarianceAndRejectUnsafeDrift() throws {
        let liveLike = try XCTUnwrap(
            OllamaEmbeddingVectorComparison.compare(
                [0.5, -0.5, 0.25, -0.25],
                [0.500_000_2, -0.499_999_8, 0.250_000_1, -0.249_999_9]
            )
        )
        XCTAssertTrue(OllamaEmbeddingStabilityContract.accepts(liveLike))
        XCTAssertGreaterThan(
            liveLike.maximumAbsoluteComponentDelta,
            1e-8
        )
        XCTAssertGreaterThanOrEqual(
            liveLike.cosineSimilarity,
            OllamaEmbeddingStabilityContract.minimumCosineSimilarity
        )
        XCTAssertLessThanOrEqual(
            liveLike.relativeL2NormDrift,
            OllamaEmbeddingStabilityContract
                .maximumRelativeL2NormDrift
        )
        XCTAssertEqual(liveLike.leftL1Norm, 1.5, accuracy: 1e-15)
        XCTAssertEqual(liveLike.rightL1Norm, 1.5, accuracy: 1e-15)
        XCTAssertEqual(
            liveLike.leftL2Norm,
            0.790_569_415_042_094_9,
            accuracy: 1e-15
        )
        XCTAssertEqual(
            liveLike.rightL2Norm,
            0.790_569_415_042_158,
            accuracy: 1e-15
        )
        XCTAssertEqual(liveLike.minimumValue, -0.5)
        XCTAssertEqual(liveLike.maximumValue, 0.500_000_2)
        XCTAssertEqual(
            liveLike.meanAbsoluteComponentDelta,
            1.500_000_000_043_133_5e-7,
            accuracy: 1e-18
        )
        XCTAssertEqual(
            liveLike.rmsComponentDelta,
            1.581_138_830_129_656_2e-7,
            accuracy: 1e-18
        )
        XCTAssertEqual(
            liveLike.normalizedEuclideanDistance,
            4.000_000_000_114_702_4e-7,
            accuracy: 1e-18
        )

        let cosineFailure = try XCTUnwrap(
            OllamaEmbeddingVectorComparison.compare(
                [1, 0],
                [0.99, 0.1]
            )
        )
        XCTAssertFalse(
            OllamaEmbeddingStabilityContract.accepts(cosineFailure)
        )
        XCTAssertLessThan(
            cosineFailure.cosineSimilarity,
            OllamaEmbeddingStabilityContract.minimumCosineSimilarity
        )

        let normFailure = try XCTUnwrap(
            OllamaEmbeddingVectorComparison.compare(
                [1, 0],
                [1.000_02, 0]
            )
        )
        XCTAssertFalse(
            OllamaEmbeddingStabilityContract.accepts(normFailure)
        )
        XCTAssertGreaterThan(
            normFailure.relativeL2NormDrift,
            OllamaEmbeddingStabilityContract
                .maximumRelativeL2NormDrift
        )

        let nonFinite = try XCTUnwrap(
            OllamaEmbeddingVectorComparison.compare(
                [1, 0],
                [.infinity, 0]
            )
        )
        XCTAssertFalse(nonFinite.allValuesFinite)
        XCTAssertFalse(
            OllamaEmbeddingStabilityContract.accepts(nonFinite)
        )
    }

    func testDeterministicTopFiveRankingUsesSharedCosineAndNoPayloads()
        throws
    {
        let documents = [
            ("doc-1", [1.0, 0.0]),
            ("doc-2", [0.9, 0.1]),
            ("doc-3", [0.8, 0.2]),
            ("doc-4", [0.7, 0.3]),
            ("doc-5", [0.6, 0.4]),
            ("doc-6", [0.0, 1.0]),
        ]
        let ranked = OllamaEmbeddingVectorMath.rank(
            query: [1, 0],
            documents: documents
        )
        XCTAssertEqual(
            ranked.map(\.identifier),
            ["doc-1", "doc-2", "doc-3", "doc-4", "doc-5"]
        )
        XCTAssertEqual(
            OllamaEmbeddingVectorMath.rankingHash(ranked),
            OllamaEmbeddingVectorMath.rankingHash(ranked)
        )
        let encoded = try JSONEncoder().encode(ranked)
        let encodedString = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedString.contains("fixture text sentinel"))
        XCTAssertFalse(encodedString.contains("[1.0,0.0]"))
    }

    func testRepositoryP8EFixtureMatchesProductionAssessmentFixture()
        throws
    {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/p8e-embedding-stability-fixtures.json"
            )
        let fixture = try JSONDecoder().decode(
            OllamaEmbeddingStabilityFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let production =
            OllamaEmbeddingStabilityFixture.p8e
        XCTAssertEqual(fixture.version, production.version)
        XCTAssertEqual(fixture.documents.count, 25)
        XCTAssertEqual(fixture.queries.count, 5)
        for (decoded, expected) in zip(
            fixture.documents,
            production.documents
        ) {
            XCTAssertEqual(
                decoded.identifier,
                expected.identifier
            )
            XCTAssertEqual(
                OllamaEmbeddingPrivacyHash.sha256(decoded.text),
                OllamaEmbeddingPrivacyHash.sha256(expected.text)
            )
        }
        for (decoded, expected) in zip(
            fixture.queries,
            production.queries
        ) {
            XCTAssertEqual(
                decoded.identifier,
                expected.identifier
            )
            XCTAssertEqual(
                decoded.expectedTop1,
                expected.expectedTop1
            )
            XCTAssertEqual(
                decoded.expectedTop5Set,
                expected.expectedTop5Set
            )
            XCTAssertEqual(
                OllamaEmbeddingPrivacyHash.sha256(decoded.text),
                OllamaEmbeddingPrivacyHash.sha256(expected.text)
            )
        }
    }

    func testStabilityAssessorAcceptsScriptedBoundedVarianceAndRankings()
        async throws
    {
        let evidenceRecorder = EmbeddingEvidenceRecorder()
        let summary = try await OllamaEmbeddingStabilityAssessor.assess(
            provider: NativeOllamaEmbeddingProvider(
                transport: StabilityEmbeddingTransportDouble()
            ),
            modelIdentifier: "qwen3-embedding:0.6b",
            modelDigest: String(repeating: "a", count: 64),
            ollamaVersion: "0.30.6",
            repetitions: 3,
            evidenceSink: {
                evidenceRecorder.recordRequest($0)
            },
            comparisonEvidenceSink: {
                evidenceRecorder.recordComparison($0)
            },
            rankingEvidenceSink: {
                evidenceRecorder.recordRanking($0)
            }
        )
        let requestReceipts =
            evidenceRecorder.requestSnapshot()
        let comparisonReceipts =
            evidenceRecorder.comparisonSnapshot()
        let rankingReceipts =
            evidenceRecorder.rankingSnapshot()
        XCTAssertTrue(
            summary.accepted,
            "Unexpected assessment reasons: \(summary.reasonCodes)"
        )
        XCTAssertEqual(summary.observedDimension, 8)
        XCTAssertEqual(summary.explicitDimensions, 8)
        XCTAssertGreaterThan(
            summary.maximumAbsoluteComponentDelta,
            0.000_001,
            "The accepted fixture must prove the old elementwise rule is not the contract."
        )
        XCTAssertGreaterThanOrEqual(
            summary.minimumCosineSimilarity,
            OllamaEmbeddingStabilityContract.minimumCosineSimilarity
        )
        XCTAssertLessThanOrEqual(
            summary.maximumRelativeL2NormDrift,
            OllamaEmbeddingStabilityContract
                .maximumRelativeL2NormDrift
        )
        XCTAssertEqual(summary.rankingHashes.count, 5)
        XCTAssertTrue(summary.stableTop1)
        XCTAssertTrue(summary.stableOrderedTop5)
        XCTAssertEqual(requestReceipts.count, 157)
        XCTAssertEqual(comparisonReceipts.count, 811)
        XCTAssertEqual(rankingReceipts.count, 20)
        XCTAssertTrue(comparisonReceipts.allSatisfy {
            $0.vectorDimension == 8
                && $0.allValuesFinite
                && !$0.zeroVector
                && $0.leftL1Norm.isFinite
                && $0.rightL1Norm.isFinite
                && $0.leftL2Norm > 0
                && $0.rightL2Norm > 0
                && $0.minimumValue.isFinite
                && $0.maximumValue.isFinite
                && $0.maximumAbsoluteComponentDelta.isFinite
                && $0.meanAbsoluteComponentDelta.isFinite
                && $0.rmsComponentDelta.isFinite
                && $0.cosineSimilarity.isFinite
                && $0.normalizedEuclideanDistance.isFinite
        })
        XCTAssertTrue(rankingReceipts.allSatisfy {
            $0.top1Identifier == $0.expectedTop1Identifier
                && $0.orderedTop5Identifiers.count == 5
                && $0.top5Set == $0.expectedTop5Set
                && $0.scoreOrdering.count == 5
                && zip(
                    $0.scoreOrdering,
                    $0.scoreOrdering.dropFirst()
                ).allSatisfy { $0.0 >= $0.1 }
                && $0.minimumAdjacentMargin > 0
                && SemanticIndexValidation.validSHA256(
                    $0.rankingHash
                )
        })
        let evidence = OllamaEmbeddingStabilityLiveEvidence(
            fixtureVersion:
                OllamaEmbeddingStabilityFixture.currentVersion,
            summary: summary,
            requestReceipts: requestReceipts,
            comparisonReceipts: comparisonReceipts,
            rankingReceipts: rankingReceipts
        )
        let encoded = try JSONEncoder().encode(evidence)
        let encodedString = String(decoding: encoded, as: UTF8.self)
        for forbiddenKey in [
            #""vectors""#,
            #""text""#,
            #""documents""#,
            #""queries""#,
        ] {
            XCTAssertFalse(encodedString.contains(forbiddenKey))
        }
        for document in
            OllamaEmbeddingStabilityFixture.p8e.documents {
            XCTAssertFalse(
                encodedString.contains(document.text)
            )
        }
        for query in
            OllamaEmbeddingStabilityFixture.p8e.queries {
            XCTAssertFalse(encodedString.contains(query.text))
        }
    }

    func testStabilityAssessorReportsNumericalVarianceTruthfully()
        async throws
    {
        let summary = try await OllamaEmbeddingStabilityAssessor.assess(
            provider: NativeOllamaEmbeddingProvider(
                transport: StabilityEmbeddingTransportDouble(
                    epsilonMagnitude: 0.01
                )
            ),
            modelIdentifier: "qwen3-embedding:0.6b",
            modelDigest: String(repeating: "a", count: 64),
            ollamaVersion: "0.30.6",
            repetitions: 3
        )
        XCTAssertFalse(summary.accepted)
        XCTAssertTrue(summary.allValuesFinite)
        XCTAssertTrue(summary.reasonCodes.contains(
            EmbeddingAssessmentReasonCode
                .numericalVarianceExceeded.rawValue
        ))
        XCTAssertFalse(summary.reasonCodes.contains(
            EmbeddingAssessmentReasonCode
                .nonFiniteVector.rawValue
        ))
    }

    func testStabilityAssessorReportsDifferentInputCollapse()
        async throws
    {
        let summary = try await OllamaEmbeddingStabilityAssessor.assess(
            provider: NativeOllamaEmbeddingProvider(
                transport: StabilityEmbeddingTransportDouble(
                    collapseDifferentInputs: true
                )
            ),
            modelIdentifier: "qwen3-embedding:0.6b",
            modelDigest: String(repeating: "a", count: 64),
            ollamaVersion: "0.30.6",
            repetitions: 3
        )
        XCTAssertFalse(summary.accepted)
        XCTAssertTrue(summary.differentInputCollapseDetected)
        XCTAssertTrue(summary.reasonCodes.contains(
            EmbeddingAssessmentReasonCode
                .vectorCollapse.rawValue
        ))
    }

    func testStabilityAssessorRejectsDifferentInputsThatCollapseAfterFloatQuantization()
        async throws
    {
        let summary = try await OllamaEmbeddingStabilityAssessor.assess(
            provider: NativeOllamaEmbeddingProvider(
                transport: StabilityEmbeddingTransportDouble(
                    collapseAfterFloatQuantization: true
                )
            ),
            modelIdentifier: "qwen3-embedding:0.6b",
            modelDigest: String(repeating: "a", count: 64),
            ollamaVersion: "0.30.6",
            repetitions: 3
        )
        XCTAssertFalse(summary.accepted)
        XCTAssertTrue(summary.differentInputCollapseDetected)
        XCTAssertTrue(summary.reasonCodes.contains(
            EmbeddingAssessmentReasonCode
                .vectorCollapse.rawValue
        ))
    }

    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
