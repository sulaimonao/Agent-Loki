import CryptoKit
import CoreFoundation
import Foundation

enum OllamaEmbeddingLimits {
    static let maximumBatchCount = 16
    static let maximumInputBytes = 64 * 1_024
    static let maximumCombinedInputBytes = 512 * 1_024
    static let maximumVectorDimension = 8_192
    static let maximumResponseBytes = 2 * 1_024 * 1_024
}

enum OllamaEmbeddingFailureCode: String, Codable, CaseIterable, Sendable {
    case invalidRequest = "ollama_embedding_invalid_request"
    case cloudModelRejected = "ollama_embedding_cloud_model_rejected"
    case redirectRejected = "ollama_embedding_redirect_rejected"
    case authenticationRejected = "ollama_embedding_authentication_rejected"
    case serviceUnavailable = "ollama_embedding_service_unavailable"
    case requestTimedOut = "ollama_embedding_request_timed_out"
    case requestCancelled = "ollama_embedding_request_cancelled"
    case httpFailure = "ollama_embedding_http_failure"
    case invalidResponse = "ollama_embedding_invalid_response"
    case responseModelMismatch = "ollama_embedding_response_model_mismatch"
    case mixedDimensions = "ollama_embedding_mixed_dimensions"
    case dimensionMismatch = "ollama_embedding_dimension_mismatch"
    case nonFiniteVector = "ollama_embedding_non_finite_vector"
    case zeroVector = "ollama_embedding_zero_vector"
}

struct OllamaEmbeddingFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: OllamaEmbeddingFailureCode
    let httpStatus: Int?

    init(_ code: OllamaEmbeddingFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var errorDescription: String? {
        switch code {
        case .invalidRequest:
            "The bounded embedding request was invalid."
        case .cloudModelRejected:
            "Cloud model references are not permitted for local embeddings."
        case .redirectRejected:
            "The local embedding endpoint attempted a redirect."
        case .authenticationRejected:
            "The local embedding endpoint requested credentials."
        case .serviceUnavailable:
            "The local Ollama embedding service is unavailable."
        case .requestTimedOut:
            "The local embedding request timed out."
        case .requestCancelled:
            "The local embedding request was cancelled."
        case .httpFailure:
            "The local embedding endpoint returned an unsuccessful response."
        case .invalidResponse:
            "The local embedding endpoint returned an invalid response."
        case .responseModelMismatch:
            "The embedding response did not match the explicitly selected model."
        case .mixedDimensions:
            "The embedding response contained mixed vector dimensions."
        case .dimensionMismatch:
            "The embedding response dimension did not match the explicit request profile."
        case .nonFiniteVector:
            "The embedding response contained a non-finite vector component."
        case .zeroVector:
            "The embedding response contained a collapsed zero vector."
        }
    }
}

struct OllamaEmbeddingRequest: Hashable, Sendable {
    let modelIdentifier: String
    let inputs: [String]
    let dimensions: Int?
    let timeoutSeconds: TimeInterval

    init(
        modelIdentifier: String,
        inputs: [String],
        dimensions: Int? = nil,
        timeoutSeconds: TimeInterval = OllamaChatProviderLimits.defaultTimeoutSeconds
    ) {
        self.modelIdentifier = modelIdentifier
        self.inputs = inputs
        self.dimensions = dimensions
        self.timeoutSeconds = timeoutSeconds
    }

    var profile: OllamaEmbeddingRequestProfile {
        .init(dimensions: dimensions)
    }
}

struct OllamaEmbeddingRequestProfile: Codable, Hashable, Sendable {
    static let currentVersion =
        "agent-loki.embedding-request-profile.v1"
    static let currentNormalizationVersion =
        "agent-loki.embedding-input.nfc-lf.v1"

    let version: String
    let dimensions: Int?
    let truncate: Bool
    let normalizationVersion: String

    init(
        version: String = Self.currentVersion,
        dimensions: Int?,
        truncate: Bool = false,
        normalizationVersion: String =
            Self.currentNormalizationVersion
    ) {
        self.version = version
        self.dimensions = dimensions
        self.truncate = truncate
        self.normalizationVersion = normalizationVersion
    }

    var stableHash: String {
        OllamaEmbeddingPrivacyHash.sha256(
            OllamaEmbeddingPrivacyHash.lengthPrefixed([
                version,
                dimensions.map(String.init) ?? "model_default",
                truncate ? "true" : "false",
                normalizationVersion,
            ])
        )
    }
}

struct OllamaEmbeddingRequestIdentity: Codable, Hashable, Sendable {
    let normalizedInputHashes: [String]
    let normalizedInputsHash: String
    let canonicalRequestHash: String
    let requestProfileHash: String
}

struct OllamaEmbeddingReceipt: Codable, Hashable, Sendable {
    let modelIdentifier: String
    let vectors: [[Double]]
    let observedDimension: Int
    let totalDurationNanoseconds: Int64?
    let loadDurationNanoseconds: Int64?
    let promptTokenCount: Int?
    let requestIdentity: OllamaEmbeddingRequestIdentity?

    init(
        modelIdentifier: String,
        vectors: [[Double]],
        observedDimension: Int,
        totalDurationNanoseconds: Int64?,
        loadDurationNanoseconds: Int64?,
        promptTokenCount: Int?,
        requestIdentity: OllamaEmbeddingRequestIdentity? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.vectors = vectors
        self.observedDimension = observedDimension
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.loadDurationNanoseconds = loadDurationNanoseconds
        self.promptTokenCount = promptTokenCount
        self.requestIdentity = requestIdentity
    }
}

enum EmbeddingAssessmentReasonCode: String, Codable, CaseIterable, Sendable {
    case requestIdentityVerified =
        "embedding_assessment_request_identity_verified"
    case parserParityVerified =
        "embedding_assessment_parser_parity_verified"
    case boundedNumericalVariance =
        "embedding_assessment_bounded_numerical_variance"
    case retrievalStabilityVerified =
        "embedding_assessment_retrieval_stability_verified"
    case numericalVarianceExceeded =
        "embedding_assessment_numerical_variance_exceeded"
    case responseParsingDefect =
        "embedding_assessment_response_parsing_defect"
    case dimensionDrift =
        "embedding_assessment_dimension_drift"
    case nonFiniteVector =
        "embedding_assessment_non_finite_vector"
    case vectorCollapse =
        "embedding_assessment_vector_collapse"
    case rankingInstability =
        "embedding_assessment_ranking_instability"
    case runtimeProfileStale =
        "embedding_assessment_runtime_profile_stale"
}

struct OllamaEmbeddingVectorComparison:
    Codable,
    Hashable,
    Sendable
{
    let dimension: Int
    let allValuesFinite: Bool
    let zeroVector: Bool
    let leftL1Norm: Double
    let rightL1Norm: Double
    let leftL2Norm: Double
    let rightL2Norm: Double
    let minimumValue: Double
    let maximumValue: Double
    let maximumAbsoluteComponentDelta: Double
    let meanAbsoluteComponentDelta: Double
    let rmsComponentDelta: Double
    let cosineSimilarity: Double
    let normalizedEuclideanDistance: Double
    let relativeL2NormDrift: Double

    static func compare(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Self? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        let finite = lhs.allSatisfy(\.isFinite)
            && rhs.allSatisfy(\.isFinite)
        let zero = !lhs.contains(where: { $0 != 0 })
            || !rhs.contains(where: { $0 != 0 })
        var leftL1 = 0.0
        var rightL1 = 0.0
        var leftSquared = 0.0
        var rightSquared = 0.0
        var deltaSquared = 0.0
        var deltaTotal = 0.0
        var maximumDelta = 0.0
        var minimumValue = Double.infinity
        var maximumValue = -Double.infinity
        for index in lhs.indices {
            let left = lhs[index]
            let right = rhs[index]
            leftL1 += abs(left)
            rightL1 += abs(right)
            leftSquared += left * left
            rightSquared += right * right
            let delta = abs(left - right)
            deltaTotal += delta
            deltaSquared += delta * delta
            maximumDelta = max(maximumDelta, delta)
            minimumValue = min(min(minimumValue, left), right)
            maximumValue = max(max(maximumValue, left), right)
        }
        let leftL2 = sqrt(leftSquared)
        let rightL2 = sqrt(rightSquared)
        let denominator = max(leftL2, rightL2)
        let cosine =
            OllamaEmbeddingVectorMath.cosineSimilarity(lhs, rhs)
        return .init(
            dimension: lhs.count,
            allValuesFinite: finite,
            zeroVector: zero,
            leftL1Norm: leftL1,
            rightL1Norm: rightL1,
            leftL2Norm: leftL2,
            rightL2Norm: rightL2,
            minimumValue: minimumValue,
            maximumValue: maximumValue,
            maximumAbsoluteComponentDelta: maximumDelta,
            meanAbsoluteComponentDelta:
                deltaTotal / Double(lhs.count),
            rmsComponentDelta:
                sqrt(deltaSquared / Double(lhs.count)),
            cosineSimilarity: cosine,
            normalizedEuclideanDistance:
                denominator > 0
                    ? sqrt(deltaSquared) / denominator
                    : .infinity,
            relativeL2NormDrift:
                denominator > 0
                    ? abs(leftL2 - rightL2) / denominator
                    : .infinity
        )
    }
}

enum OllamaEmbeddingStabilityContract {
    static let minimumCosineSimilarity = 0.99999
    static let maximumRelativeL2NormDrift = 0.00001

    static func accepts(
        _ comparison: OllamaEmbeddingVectorComparison
    ) -> Bool {
        comparison.dimension > 0
            && comparison.allValuesFinite
            && !comparison.zeroVector
            && comparison.cosineSimilarity.isFinite
            && comparison.cosineSimilarity
                >= minimumCosineSimilarity
            && comparison.relativeL2NormDrift.isFinite
            && comparison.relativeL2NormDrift
                <= maximumRelativeL2NormDrift
    }
}

struct OllamaEmbeddingRankedResult:
    Codable,
    Hashable,
    Sendable
{
    let identifier: String
    let cosineSimilarity: Double
}

enum OllamaEmbeddingVectorMath {
    static func cosineSimilarity(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in lhs.indices {
            let left = lhs[index]
            let right = rhs[index]
            dot += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return -1 }
        return max(
            -1,
            min(
                1,
                dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
            )
        )
    }

    static func cosineSimilarity(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Double {
        cosineSimilarity(lhs.map(Double.init), rhs.map(Double.init))
    }

    static func rank(
        query: [Double],
        documents: [(identifier: String, vector: [Double])],
        limit: Int = 5
    ) -> [OllamaEmbeddingRankedResult] {
        guard limit > 0 else { return [] }
        return documents.map {
            OllamaEmbeddingRankedResult(
                identifier: $0.identifier,
                cosineSimilarity: cosineSimilarity(
                    query,
                    $0.vector
                )
            )
        }
        .sorted {
            if $0.cosineSimilarity != $1.cosineSimilarity {
                return $0.cosineSimilarity > $1.cosineSimilarity
            }
            return $0.identifier < $1.identifier
        }
        .prefix(limit)
        .map { $0 }
    }

    static func rank(
        query: [Float],
        documents: [(identifier: String, vector: [Float])],
        limit: Int = 5
    ) -> [OllamaEmbeddingRankedResult] {
        guard limit > 0 else { return [] }
        return documents.map {
            OllamaEmbeddingRankedResult(
                identifier: $0.identifier,
                cosineSimilarity: cosineSimilarity(
                    query,
                    $0.vector
                )
            )
        }
        .sorted {
            if $0.cosineSimilarity != $1.cosineSimilarity {
                return $0.cosineSimilarity > $1.cosineSimilarity
            }
            return $0.identifier < $1.identifier
        }
        .prefix(limit)
        .map { $0 }
    }

    static func rankingHash(
        _ results: [OllamaEmbeddingRankedResult]
    ) -> String {
        OllamaEmbeddingPrivacyHash.sha256(
            OllamaEmbeddingPrivacyHash.lengthPrefixed(
                results.map(\.identifier)
            )
        )
    }
}

enum OllamaEmbeddingPrivacyHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func lengthPrefixed(_ values: [String]) -> String {
        values.map {
            "\(Data($0.utf8).count):\($0)"
        }
        .joined(separator: "|")
    }
}

struct OllamaEmbeddingStabilityDocument:
    Codable,
    Hashable,
    Sendable
{
    let identifier: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case text
    }
}

struct OllamaEmbeddingStabilityQuery:
    Codable,
    Hashable,
    Sendable
{
    let identifier: String
    let text: String
    let expectedTop1: String
    let expectedTop5Set: Set<String>

    private enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case text
        case expectedTop1 = "expected_top1"
        case expectedTop5Set = "expected_top5_set"
    }
}

struct OllamaEmbeddingStabilityFixture:
    Codable,
    Hashable,
    Sendable
{
    static let currentVersion =
        "agent-loki.p8e.synthetic-retrieval.v1"

    let version: String
    let documents: [OllamaEmbeddingStabilityDocument]
    let queries: [OllamaEmbeddingStabilityQuery]

    static let p8e = OllamaEmbeddingStabilityFixture(
        version: currentVersion,
        documents: [
            .init(
                identifier: "orbital-01",
                text: "Orbital greenhouse tomato seedlings use red and blue LED cycles with closed-loop humidity control."
            ),
            .init(
                identifier: "orbital-02",
                text: "A spacecraft greenhouse grows tomatoes in microgravity with hydroponic nutrient delivery."
            ),
            .init(
                identifier: "orbital-03",
                text: "Crewed orbital agriculture monitors tomato roots, leaf moisture, and carbon dioxide."
            ),
            .init(
                identifier: "orbital-04",
                text: "Microgravity crop research evaluates fruiting plants inside a sealed space habitat."
            ),
            .init(
                identifier: "orbital-05",
                text: "Space station botany experiments track edible plant growth under artificial light."
            ),
            .init(
                identifier: "wind-01",
                text: "Offshore wind turbine blades are inspected by autonomous drones after saltwater storms."
            ),
            .init(
                identifier: "wind-02",
                text: "Drone cameras detect cracks and erosion on coastal wind turbine rotor blades."
            ),
            .init(
                identifier: "wind-03",
                text: "Marine wind farm maintenance uses aerial imaging to schedule blade repairs."
            ),
            .init(
                identifier: "wind-04",
                text: "Technicians review turbine nacelle and rotor imagery captured above the ocean."
            ),
            .init(
                identifier: "wind-05",
                text: "Renewable energy operators inspect tall coastal equipment for storm damage."
            ),
            .init(
                identifier: "cello-01",
                text: "A luthier adjusts a cello bridge and soundpost to restore warm acoustic resonance."
            ),
            .init(
                identifier: "cello-02",
                text: "Cello repair requires careful bridge fitting, string-height measurement, and soundpost placement."
            ),
            .init(
                identifier: "cello-03",
                text: "An orchestral instrument workshop corrects buzzing and uneven tone on a wooden cello."
            ),
            .init(
                identifier: "cello-04",
                text: "String instrument maintenance balances neck relief, bridge curvature, and resonant response."
            ),
            .init(
                identifier: "cello-05",
                text: "A craftsperson services a bowed wooden instrument before a concert."
            ),
            .init(
                identifier: "rye-01",
                text: "Rye sourdough fermentation is stabilized by feeding a mature starter at a consistent warm temperature."
            ),
            .init(
                identifier: "rye-02",
                text: "A baker controls rye starter acidity through scheduled flour and water feedings."
            ),
            .init(
                identifier: "rye-03",
                text: "Whole-grain sourdough dough develops flavor during a measured overnight fermentation."
            ),
            .init(
                identifier: "rye-04",
                text: "Bread fermentation timing depends on starter strength, hydration, and room temperature."
            ),
            .init(
                identifier: "rye-05",
                text: "Artisan bread making uses a living culture instead of packaged yeast."
            ),
            .init(
                identifier: "reef-01",
                text: "Coral reef health is monitored with underwater hydrophones that record fish and invertebrate sounds."
            ),
            .init(
                identifier: "reef-02",
                text: "Marine biologists analyze reef soundscapes from submerged acoustic sensors."
            ),
            .init(
                identifier: "reef-03",
                text: "Passive underwater audio reveals changes in coral habitat biodiversity."
            ),
            .init(
                identifier: "reef-04",
                text: "Ocean researchers compare nightly biological sound activity across reef restoration sites."
            ),
            .init(
                identifier: "reef-05",
                text: "Long-term marine habitat surveys combine acoustic observations with ecological sampling."
            ),
        ],
        queries: [
            .init(
                identifier: "query-orbital",
                text: "How are tomato seedlings managed in an orbital greenhouse?",
                expectedTop1: "orbital-01",
                expectedTop5Set: [
                    "orbital-01",
                    "orbital-02",
                    "orbital-03",
                    "orbital-04",
                    "orbital-05",
                ]
            ),
            .init(
                identifier: "query-wind",
                text: "How can drones inspect offshore wind turbine blades after coastal storms?",
                expectedTop1: "wind-01",
                expectedTop5Set: [
                    "wind-01",
                    "wind-02",
                    "wind-03",
                    "wind-04",
                    "wind-05",
                ]
            ),
            .init(
                identifier: "query-cello",
                text: "How does a luthier adjust a cello bridge and soundpost for better resonance?",
                expectedTop1: "cello-01",
                expectedTop5Set: [
                    "cello-01",
                    "cello-02",
                    "cello-03",
                    "cello-04",
                    "cello-05",
                ]
            ),
            .init(
                identifier: "query-rye",
                text: "How should a rye sourdough starter be fed to keep fermentation stable?",
                expectedTop1: "rye-01",
                expectedTop5Set: [
                    "rye-01",
                    "rye-02",
                    "rye-03",
                    "rye-04",
                    "rye-05",
                ]
            ),
            .init(
                identifier: "query-reef",
                text: "How do hydrophones and underwater soundscapes measure coral reef health?",
                expectedTop1: "reef-01",
                expectedTop5Set: [
                    "reef-01",
                    "reef-02",
                    "reef-03",
                    "reef-04",
                    "reef-05",
                ]
            ),
        ]
    )
}

struct OllamaEmbeddingStabilityRequestReceipt:
    Codable,
    Hashable,
    Sendable
{
    let fixtureIdentifier: String
    let normalizedInputSHA256: String
    let normalizedInputsSHA256: String
    let canonicalRequestSHA256: String
    let requestProfileSHA256: String
    let modelIdentifier: String
    let modelDigest: String
    let ollamaVersion: String
    let dimensionsParameter: Int?
    let truncate: Bool
    let runtimeOptions: [String]
    let inputForm: String
    let sequenceNumber: Int
    let modelOrderScenario: String
    let responseDimension: Int
    let promptTokenCount: Int?
    let totalDurationNanoseconds: Int64?
    let loadDurationNanoseconds: Int64?
    let wallDurationMilliseconds: Int
    let allValuesFinite: Bool
    let zeroVector: Bool
    let l1Norm: Double
    let l2Norm: Double
    let minimumValue: Double
    let maximumValue: Double
}

struct OllamaEmbeddingStabilityComparisonReceipt:
    Codable,
    Hashable,
    Sendable
{
    let fixtureIdentifier: String
    let comparisonScenario: String
    let leftSampleIdentifier: String
    let rightSampleIdentifier: String
    let vectorDimension: Int
    let allValuesFinite: Bool
    let zeroVector: Bool
    let leftL1Norm: Double
    let rightL1Norm: Double
    let leftL2Norm: Double
    let rightL2Norm: Double
    let minimumValue: Double
    let maximumValue: Double
    let maximumAbsoluteComponentDelta: Double
    let meanAbsoluteComponentDelta: Double
    let rmsComponentDelta: Double
    let cosineSimilarity: Double
    let normalizedEuclideanDistance: Double
    let relativeL2NormDrift: Double

    init(
        fixtureIdentifier: String,
        comparisonScenario: String,
        leftSampleIdentifier: String,
        rightSampleIdentifier: String,
        comparison: OllamaEmbeddingVectorComparison
    ) {
        self.fixtureIdentifier = fixtureIdentifier
        self.comparisonScenario = comparisonScenario
        self.leftSampleIdentifier = leftSampleIdentifier
        self.rightSampleIdentifier = rightSampleIdentifier
        vectorDimension = comparison.dimension
        allValuesFinite = comparison.allValuesFinite
        zeroVector = comparison.zeroVector
        leftL1Norm = comparison.leftL1Norm
        rightL1Norm = comparison.rightL1Norm
        leftL2Norm = comparison.leftL2Norm
        rightL2Norm = comparison.rightL2Norm
        minimumValue = comparison.minimumValue
        maximumValue = comparison.maximumValue
        maximumAbsoluteComponentDelta =
            comparison.maximumAbsoluteComponentDelta
        meanAbsoluteComponentDelta =
            comparison.meanAbsoluteComponentDelta
        rmsComponentDelta = comparison.rmsComponentDelta
        cosineSimilarity = comparison.cosineSimilarity
        normalizedEuclideanDistance =
            comparison.normalizedEuclideanDistance
        relativeL2NormDrift = comparison.relativeL2NormDrift
    }
}

struct OllamaEmbeddingStabilityRankingReceipt:
    Codable,
    Hashable,
    Sendable
{
    let queryIdentifier: String
    let generationForm: String
    let modelOrderScenario: String
    let repetitionNumber: Int
    let expectedTop1Identifier: String
    let expectedTop5Set: [String]
    let top1Identifier: String
    let orderedTop5Identifiers: [String]
    let top5Set: [String]
    let scoreOrdering: [Double]
    let minimumAdjacentMargin: Double
    let rankingHash: String
}

struct OllamaEmbeddingStabilityLiveEvidence:
    Codable,
    Hashable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.embedding-stability-live-evidence.v2"

    let schemaVersion: String
    let fixtureVersion: String
    let summary: EmbeddingStabilityAssessmentSummary
    let requestReceipts:
        [OllamaEmbeddingStabilityRequestReceipt]
    let comparisonReceipts:
        [OllamaEmbeddingStabilityComparisonReceipt]
    let rankingReceipts:
        [OllamaEmbeddingStabilityRankingReceipt]

    init(
        fixtureVersion: String,
        summary: EmbeddingStabilityAssessmentSummary,
        requestReceipts:
            [OllamaEmbeddingStabilityRequestReceipt],
        comparisonReceipts:
            [OllamaEmbeddingStabilityComparisonReceipt],
        rankingReceipts:
            [OllamaEmbeddingStabilityRankingReceipt]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.fixtureVersion = fixtureVersion
        self.summary = summary
        self.requestReceipts = requestReceipts
        self.comparisonReceipts = comparisonReceipts
        self.rankingReceipts = rankingReceipts
    }
}

actor NativeOllamaEmbeddingProvider {
    private let transport: any OllamaChatTransporting

    init(transport: any OllamaChatTransporting = BoundedOllamaChatTransport()) {
        self.transport = transport
    }

    func embed(_ request: OllamaEmbeddingRequest) async throws -> OllamaEmbeddingReceipt {
        try validate(request)
        let url = try OllamaLoopbackEndpointPolicy.url(path: "embed")
        let body = try Self.canonicalRequestData(for: request)
        let requestIdentity = try Self.requestIdentity(
            for: request,
            canonicalRequestData: body
        )
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try OllamaLoopbackEndpointPolicy.validate(urlRequest)

        let requestID = UUID()
        let correlationToken =
            try P8FProviderRequestCorrelationRecorder.shared.begin(
                providerKind: .embedding,
                operationKind: .embedding,
                requestIdentifier: requestID,
                requestTraceMaterial:
                    requestIdentity.requestProfileHash
            )
        let events = transport.stream(
            for: urlRequest,
            requestID: requestID,
            responseLimit: OllamaEmbeddingLimits.maximumResponseBytes
        )
        let data: Data
        do {
            data = try await withTaskCancellationHandler {
                var responseStarted = false
                var collected = Data()
                for try await event in events {
                    switch event {
                    case let .response(head):
                        guard !responseStarted, head.finalURL == url else {
                            throw OllamaEmbeddingFailure(.redirectRejected, httpStatus: head.statusCode)
                        }
                        responseStarted = true
                        switch head.statusCode {
                        case 200..<300:
                            break
                        case 401, 403:
                            throw OllamaEmbeddingFailure(.authenticationRejected, httpStatus: head.statusCode)
                        default:
                            throw OllamaEmbeddingFailure(.httpFailure, httpStatus: head.statusCode)
                        }
                    case let .bytes(chunk):
                        guard responseStarted,
                              collected.count + chunk.count <= OllamaEmbeddingLimits.maximumResponseBytes
                        else {
                            throw OllamaEmbeddingFailure(.invalidResponse)
                        }
                        collected.append(chunk)
                    }
                }
                try Task.checkCancellation()
                guard responseStarted, !collected.isEmpty else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                return collected
            } onCancel: {
                Task { await self.transport.cancel(requestID: requestID) }
            }
            let receipt = try parse(
                data,
                request: request,
                requestIdentity: requestIdentity
            )
            P8FProviderRequestCorrelationRecorder.shared
                .complete(
                    correlationToken,
                    outcome: .succeeded
                )
            return receipt
        } catch {
            let failure = map(error)
            P8FProviderRequestCorrelationRecorder.shared
                .complete(
                    correlationToken,
                    outcome: failure.code
                        == .requestCancelled
                        ? .cancelled
                        : .failed
                )
            throw failure
        }
    }

    static func canonicalRequestData(
        for request: OllamaEmbeddingRequest
    ) throws -> Data {
        var object: [String: Any] = [
            "model": request.modelIdentifier,
            "input": request.inputs.map(Self.normalize),
            // Index generations must never silently mix truncated inputs.
            "truncate": false,
        ]
        if let dimensions = request.dimensions {
            object["dimensions"] = dimensions
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func requestIdentity(
        for request: OllamaEmbeddingRequest
    ) throws -> OllamaEmbeddingRequestIdentity {
        try requestIdentity(
            for: request,
            canonicalRequestData: canonicalRequestData(for: request)
        )
    }

    private func validate(_ request: OllamaEmbeddingRequest) throws {
        let identifier = request.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let dimensionsAreValid = request.dimensions.map {
            (1...OllamaEmbeddingLimits.maximumVectorDimension)
                .contains($0)
        } ?? true
        guard !identifier.isEmpty,
              identifier.count <= OllamaChatProviderLimits.maximumIdentifierCharacters,
              !OllamaModelLocalityPolicy.isCloudReference(identifier),
              OllamaChatProviderLimits.contains(timeout: request.timeoutSeconds),
              !request.inputs.isEmpty,
              request.inputs.count <= OllamaEmbeddingLimits.maximumBatchCount,
              dimensionsAreValid
        else {
            if OllamaModelLocalityPolicy.isCloudReference(identifier) {
                throw OllamaEmbeddingFailure(.cloudModelRejected)
            }
            throw OllamaEmbeddingFailure(.invalidRequest)
        }
        var combined = 0
        for input in request.inputs {
            let bytes = input.lengthOfBytes(using: .utf8)
            combined += bytes
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bytes <= OllamaEmbeddingLimits.maximumInputBytes,
                  combined <= OllamaEmbeddingLimits.maximumCombinedInputBytes
            else {
                throw OllamaEmbeddingFailure(.invalidRequest)
            }
        }
    }

    private func parse(
        _ data: Data,
        request: OllamaEmbeddingRequest,
        requestIdentity: OllamaEmbeddingRequestIdentity
    ) throws -> OllamaEmbeddingReceipt {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let model = object["model"] as? String,
              model == request.modelIdentifier,
              let rawVectors = object["embeddings"] as? [[Any]],
              rawVectors.count == request.inputs.count
        else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = object["model"] as? String,
               model != request.modelIdentifier {
                throw OllamaEmbeddingFailure(.responseModelMismatch)
            }
            throw OllamaEmbeddingFailure(.invalidResponse)
        }
        let validated = try Self.validatedVectors(
            rawVectors,
            expectedDimension: request.dimensions
        )
        return .init(
            modelIdentifier: model,
            vectors: validated.vectors,
            observedDimension: validated.dimension,
            totalDurationNanoseconds: Self.int64(object["total_duration"]),
            loadDurationNanoseconds: Self.int64(object["load_duration"]),
            promptTokenCount: Self.int(object["prompt_eval_count"]),
            requestIdentity: requestIdentity
        )
    }

    static func validatedVectors(
        _ rawVectors: [[Any]],
        expectedDimension: Int?
    ) throws -> (vectors: [[Double]], dimension: Int) {
        guard let first = rawVectors.first,
              !first.isEmpty,
              first.count
                <= OllamaEmbeddingLimits.maximumVectorDimension
        else {
            throw OllamaEmbeddingFailure(.invalidResponse)
        }
        let dimension = first.count
        if let expectedDimension,
           dimension != expectedDimension {
            throw OllamaEmbeddingFailure(.dimensionMismatch)
        }
        var vectors: [[Double]] = []
        vectors.reserveCapacity(rawVectors.count)
        for rawVector in rawVectors {
            guard rawVector.count == dimension else {
                throw OllamaEmbeddingFailure(.mixedDimensions)
            }
            let vector: [Double] = try rawVector.map { value in
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID()
                else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                let double = number.doubleValue
                guard double.isFinite else {
                    throw OllamaEmbeddingFailure(.nonFiniteVector)
                }
                return double
            }
            guard vector.contains(where: { $0 != 0 }) else {
                throw OllamaEmbeddingFailure(.zeroVector)
            }
            vectors.append(vector)
        }
        return (vectors, dimension)
    }

    private static func requestIdentity(
        for request: OllamaEmbeddingRequest,
        canonicalRequestData: Data
    ) throws -> OllamaEmbeddingRequestIdentity {
        let normalizedInputs = request.inputs.map(normalize)
        let normalizedInputHashes = normalizedInputs.map {
            OllamaEmbeddingPrivacyHash.sha256(Data($0.utf8))
        }
        let normalizedInputsData = try JSONSerialization.data(
            withJSONObject: normalizedInputs,
            options: [.withoutEscapingSlashes]
        )
        return .init(
            normalizedInputHashes: normalizedInputHashes,
            normalizedInputsHash:
                OllamaEmbeddingPrivacyHash.sha256(
                    normalizedInputsData
                ),
            canonicalRequestHash:
                OllamaEmbeddingPrivacyHash.sha256(
                    canonicalRequestData
                ),
            requestProfileHash: request.profile.stableHash
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private func map(_ error: Error) -> OllamaEmbeddingFailure {
        if let failure = error as? OllamaEmbeddingFailure { return failure }
        if let failure = error as? OllamaChatFailure {
            return switch failure.code {
            case .requestCancelled: .init(.requestCancelled)
            case .requestTimedOut: .init(.requestTimedOut)
            case .serviceUnavailable: .init(.serviceUnavailable)
            case .authenticationRejected: .init(.authenticationRejected, httpStatus: failure.httpStatus)
            case .redirectRejected: .init(.redirectRejected, httpStatus: failure.httpStatus)
            default: .init(.httpFailure, httpStatus: failure.httpStatus)
            }
        }
        if error is CancellationError { return .init(.requestCancelled) }
        if let urlError = error as? URLError {
            return switch urlError.code {
            case .cancelled: .init(.requestCancelled)
            case .timedOut: .init(.requestTimedOut)
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                .init(.serviceUnavailable)
            default:
                .init(.httpFailure)
            }
        }
        return .init(.invalidResponse)
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let candidate = number.int64Value
        guard candidate >= 0, candidate <= Int64(Int.max) else { return nil }
        return Int(candidate)
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let candidate = number.int64Value
        return candidate >= 0 ? candidate : nil
    }
}

enum OllamaEmbeddingStabilityAssessor {
    static func assess(
        provider: NativeOllamaEmbeddingProvider,
        modelIdentifier: String,
        modelDigest: String,
        ollamaVersion: String,
        modelOrderScenario: String = "native_qwen_only",
        repetitions: Int = 3,
        timeoutSeconds: TimeInterval =
            OllamaChatProviderLimits.defaultTimeoutSeconds,
        evidenceSink: (@Sendable (
            OllamaEmbeddingStabilityRequestReceipt
        ) -> Void)? = nil,
        comparisonEvidenceSink: (@Sendable (
            OllamaEmbeddingStabilityComparisonReceipt
        ) -> Void)? = nil,
        rankingEvidenceSink: (@Sendable (
            OllamaEmbeddingStabilityRankingReceipt
        ) -> Void)? = nil
    ) async throws -> EmbeddingStabilityAssessmentSummary {
        guard !modelIdentifier.isEmpty,
              SemanticIndexValidation.validSHA256(
                modelDigest.lowercased()
              ),
              !ollamaVersion.isEmpty,
              !modelOrderScenario.isEmpty,
              modelOrderScenario.count <= 128,
              modelOrderScenario.allSatisfy({
                  $0.isLowercase || $0.isNumber || $0 == "_"
              }),
              (3...8).contains(repetitions),
              OllamaChatProviderLimits.contains(
                timeout: timeoutSeconds
              )
        else {
            throw OllamaEmbeddingFailure(.invalidRequest)
        }

        func scopedScenario(_ phase: String) -> String {
            guard modelOrderScenario != "native_qwen_only"
            else { return phase }
            return "\(modelOrderScenario)__\(phase)"
        }

        let fixture = OllamaEmbeddingStabilityFixture.p8e
        let probeInput = "Synthetic P8 embedding receipt."
        let discoveryRequest = OllamaEmbeddingRequest(
            modelIdentifier: modelIdentifier,
            inputs: [probeInput],
            timeoutSeconds: timeoutSeconds
        )
        let discoveryExpectedIdentity =
            try NativeOllamaEmbeddingProvider.requestIdentity(
                for: discoveryRequest
            )
        let discoveryStarted =
            ProcessInfo.processInfo.systemUptime
        let discovery = try await provider.embed(discoveryRequest)
        let discoveryWallMilliseconds = Int(
            (
                ProcessInfo.processInfo.systemUptime
                    - discoveryStarted
            ) * 1_000
        )
        guard discovery.observedDimension > 0,
              discovery.vectors.count == 1,
              discovery.requestIdentity
                == discoveryExpectedIdentity
        else {
            throw OllamaEmbeddingFailure(.invalidResponse)
        }
        emitEvidence(
            sink: evidenceSink,
            request: discoveryRequest,
            receipt: discovery,
            identity: discoveryExpectedIdentity,
            fixtureIdentifiers: ["probe-dimension-discovery"],
            modelDigest: modelDigest,
            ollamaVersion: ollamaVersion,
            scenario: scopedScenario(
                "native_dimension_discovery_default"
            ),
            sequence: 1,
            wallDurationMilliseconds:
                discoveryWallMilliseconds
        )

        let dimension = discovery.observedDimension
        let profile = OllamaEmbeddingRequestProfile(
            dimensions: dimension
        )
        var requestIdentityVerified = true
        var allValuesFinite = true
        var zeroVectorDetected = false

        func explicitReceipt(
            inputs: [String],
            fixtureIdentifiers: [String],
            scenario: String,
            sequence: Int
        ) async throws -> OllamaEmbeddingReceipt {
            guard fixtureIdentifiers.count == inputs.count else {
                throw OllamaEmbeddingFailure(.invalidRequest)
            }
            let request = OllamaEmbeddingRequest(
                modelIdentifier: modelIdentifier,
                inputs: inputs,
                dimensions: dimension,
                timeoutSeconds: timeoutSeconds
            )
            let expectedIdentity =
                try NativeOllamaEmbeddingProvider.requestIdentity(
                    for: request
                )
            let started = ProcessInfo.processInfo.systemUptime
            let receipt = try await provider.embed(request)
            let wallDurationMilliseconds = Int(
                (
                    ProcessInfo.processInfo.systemUptime
                        - started
                ) * 1_000
            )
            requestIdentityVerified =
                requestIdentityVerified
                && receipt.modelIdentifier == modelIdentifier
                && receipt.observedDimension == dimension
                && receipt.vectors.count == inputs.count
                && receipt.requestIdentity == expectedIdentity
                && receipt.requestIdentity?.requestProfileHash
                    == profile.stableHash
            for vector in receipt.vectors {
                allValuesFinite =
                    allValuesFinite
                    && vector.count == dimension
                    && vector.allSatisfy(\.isFinite)
                zeroVectorDetected =
                    zeroVectorDetected
                    || !vector.contains(where: { $0 != 0 })
            }
            emitEvidence(
                sink: evidenceSink,
                request: request,
                receipt: receipt,
                identity: expectedIdentity,
                fixtureIdentifiers: fixtureIdentifiers,
                modelDigest: modelDigest,
                ollamaVersion: ollamaVersion,
                scenario: scenario,
                sequence: sequence,
                wallDurationMilliseconds:
                    wallDurationMilliseconds
            )
            return receipt
        }

        let sequentialProbeCount = 20
        var repeatedSingles: [[Double]] = []
        repeatedSingles.reserveCapacity(sequentialProbeCount)
        for sequence in 0..<sequentialProbeCount {
            try Task.checkCancellation()
            repeatedSingles.append(
                try await explicitReceipt(
                    inputs: [probeInput],
                    fixtureIdentifiers: ["probe-repeated"],
                    scenario: scopedScenario(
                        "native_sequential_explicit"
                    ),
                    sequence: sequence + 1
                )
                    .vectors[0]
            )
        }
        let repeatedBatch = try await explicitReceipt(
            inputs: Array(
                repeating: probeInput,
                count: OllamaEmbeddingLimits.maximumBatchCount
            ),
            fixtureIdentifiers: Array(
                repeating: "probe-repeated",
                count: OllamaEmbeddingLimits.maximumBatchCount
            ),
            scenario: scopedScenario("native_batch_repeated"),
            sequence: 1
        )

        var baselineDocuments: [String: [Double]] = [:]
        for (index, document) in fixture.documents.enumerated() {
            try Task.checkCancellation()
            baselineDocuments[document.identifier] =
                try await explicitReceipt(
                    inputs: [document.text],
                    fixtureIdentifiers: [document.identifier],
                    scenario: scopedScenario(
                        "native_retrieval_single"
                    ),
                    sequence: index + 1
                )
                    .vectors[0]
        }
        var baselineQueries: [String: [Double]] = [:]
        for (index, query) in fixture.queries.enumerated() {
            try Task.checkCancellation()
            baselineQueries[query.identifier] =
                try await explicitReceipt(
                    inputs: [query.text],
                    fixtureIdentifiers: [query.identifier],
                    scenario: scopedScenario(
                        "native_retrieval_single"
                    ),
                    sequence:
                        fixture.documents.count + index + 1
                )
                    .vectors[0]
        }

        var batchDocumentRuns: [[String: [Double]]] = []
        var batchQueryRuns: [[String: [Double]]] = []
        batchDocumentRuns.reserveCapacity(repetitions)
        batchQueryRuns.reserveCapacity(repetitions)
        for repetition in 0..<repetitions {
            try Task.checkCancellation()
            var documents: [String: [Double]] = [:]
            for offset in stride(
                from: 0,
                to: fixture.documents.count,
                by: OllamaEmbeddingLimits.maximumBatchCount
            ) {
                let end = min(
                    fixture.documents.count,
                    offset
                        + OllamaEmbeddingLimits.maximumBatchCount
                )
                let batch = Array(fixture.documents[offset..<end])
                let receipt = try await explicitReceipt(
                    inputs: batch.map(\.text),
                    fixtureIdentifiers:
                        batch.map(\.identifier),
                    scenario: scopedScenario(
                        "native_retrieval_batch_repetition_\(repetition + 1)"
                    ),
                    sequence:
                        offset
                            / OllamaEmbeddingLimits
                                .maximumBatchCount + 1
                )
                for (document, vector) in zip(
                    batch,
                    receipt.vectors
                ) {
                    documents[document.identifier] = vector
                }
            }
            let queryReceipt = try await explicitReceipt(
                inputs: fixture.queries.map(\.text),
                fixtureIdentifiers:
                    fixture.queries.map(\.identifier),
                scenario: scopedScenario(
                    "native_retrieval_batch_repetition_\(repetition + 1)"
                ),
                sequence: 3
            )
            batchDocumentRuns.append(documents)
            batchQueryRuns.append(
                Dictionary(
                    uniqueKeysWithValues: zip(
                        fixture.queries.map(\.identifier),
                        queryReceipt.vectors
                    )
                )
            )
        }

        var comparisons: [OllamaEmbeddingVectorComparison] = []
        var parserComparisons: [OllamaEmbeddingVectorComparison] = []
        func recordComparison(
            fixtureIdentifier: String,
            scenario: String,
            leftSampleIdentifier: String,
            left: [Double],
            rightSampleIdentifier: String,
            right: [Double],
            verifiesParserParity: Bool = false
        ) throws {
            guard let comparison =
                    OllamaEmbeddingVectorComparison.compare(
                        left,
                        right
                    )
            else {
                throw OllamaEmbeddingFailure(.mixedDimensions)
            }
            comparisons.append(comparison)
            if verifiesParserParity {
                parserComparisons.append(comparison)
            }
            comparisonEvidenceSink?(.init(
                fixtureIdentifier: fixtureIdentifier,
                comparisonScenario: scenario,
                leftSampleIdentifier: leftSampleIdentifier,
                rightSampleIdentifier: rightSampleIdentifier,
                comparison: comparison
            ))
        }
        if let discoveryVector = discovery.vectors.first,
           let firstExplicit = repeatedSingles.first {
            try recordComparison(
                fixtureIdentifier: "probe-repeated",
                scenario: scopedScenario(
                    "native_default_vs_explicit"
                ),
                leftSampleIdentifier: "default-dimension-discovery-1",
                left: discoveryVector,
                rightSampleIdentifier: "explicit-sequential-1",
                right: firstExplicit
            )
        }
        let repeatedSamples: [
            (identifier: String, vector: [Double])
        ] = repeatedSingles.enumerated().map {
            (
                identifier: "explicit-sequential-\($0.offset + 1)",
                vector: $0.element
            )
        } + repeatedBatch.vectors.enumerated().map {
            (
                identifier: "explicit-batch-\($0.offset + 1)",
                vector: $0.element
            )
        }
        for leftIndex in repeatedSamples.indices {
            for rightIndex in repeatedSamples.indices
                where rightIndex > leftIndex {
                try recordComparison(
                    fixtureIdentifier: "probe-repeated",
                    scenario: scopedScenario(
                        "native_repeated_same_input"
                    ),
                    leftSampleIdentifier:
                        repeatedSamples[leftIndex].identifier,
                    left: repeatedSamples[leftIndex].vector,
                    rightSampleIdentifier:
                        repeatedSamples[rightIndex].identifier,
                    right: repeatedSamples[rightIndex].vector
                )
            }
        }
        for document in fixture.documents {
            guard let baseline =
                    baselineDocuments[document.identifier]
            else {
                throw OllamaEmbeddingFailure(.invalidResponse)
            }
            var sameInputSamples: [
                (identifier: String, vector: [Double])
            ] = [("single-generation", baseline)]
            for (index, run) in batchDocumentRuns.enumerated() {
                guard let vector = run[document.identifier] else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                sameInputSamples.append((
                    "batch-generation-\(index + 1)",
                    vector
                ))
            }
            for leftIndex in sameInputSamples.indices {
                for rightIndex in sameInputSamples.indices
                    where rightIndex > leftIndex {
                    try recordComparison(
                        fixtureIdentifier: document.identifier,
                        scenario: scopedScenario(
                            "native_retrieval_same_input"
                        ),
                        leftSampleIdentifier:
                            sameInputSamples[leftIndex].identifier,
                        left: sameInputSamples[leftIndex].vector,
                        rightSampleIdentifier:
                            sameInputSamples[rightIndex].identifier,
                        right: sameInputSamples[rightIndex].vector,
                        verifiesParserParity: leftIndex == 0
                    )
                }
            }
        }
        for query in fixture.queries {
            guard let baseline =
                    baselineQueries[query.identifier]
            else {
                throw OllamaEmbeddingFailure(.invalidResponse)
            }
            var sameInputSamples: [
                (identifier: String, vector: [Double])
            ] = [("single-generation", baseline)]
            for (index, run) in batchQueryRuns.enumerated() {
                guard let vector = run[query.identifier] else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                sameInputSamples.append((
                    "batch-generation-\(index + 1)",
                    vector
                ))
            }
            for leftIndex in sameInputSamples.indices {
                for rightIndex in sameInputSamples.indices
                    where rightIndex > leftIndex {
                    try recordComparison(
                        fixtureIdentifier: query.identifier,
                        scenario: scopedScenario(
                            "native_retrieval_same_input"
                        ),
                        leftSampleIdentifier:
                            sameInputSamples[leftIndex].identifier,
                        left: sameInputSamples[leftIndex].vector,
                        rightSampleIdentifier:
                            sameInputSamples[rightIndex].identifier,
                        right: sameInputSamples[rightIndex].vector,
                        verifiesParserParity: leftIndex == 0
                    )
                }
            }
        }
        var differentInputCollapseDetected = false
        let distinctVectorRuns = [
            (
                documents: baselineDocuments,
                queries: baselineQueries
            ),
        ] + zip(batchDocumentRuns, batchQueryRuns).map {
            (documents: $0.0, queries: $0.1)
        }
        for run in distinctVectorRuns {
            let vectors =
                fixture.documents.compactMap {
                    run.documents[$0.identifier]
                }
                + fixture.queries.compactMap {
                    run.queries[$0.identifier]
                }
            guard vectors.count
                    == fixture.documents.count
                        + fixture.queries.count
            else {
                throw OllamaEmbeddingFailure(.invalidResponse)
            }
            let productVectors = vectors.map {
                $0.map(Float.init)
            }
            guard productVectors.allSatisfy({
                $0.allSatisfy(\.isFinite)
            }) else {
                throw OllamaEmbeddingFailure(.nonFiniteVector)
            }
            guard productVectors.allSatisfy({
                $0.contains(where: { $0 != 0 })
            }) else {
                throw OllamaEmbeddingFailure(.zeroVector)
            }
            for leftIndex in productVectors.indices {
                for rightIndex in productVectors.indices
                    where rightIndex > leftIndex {
                    if productVectors[leftIndex]
                        == productVectors[rightIndex] {
                        differentInputCollapseDetected = true
                    }
                }
            }
        }

        let parserParityVerified =
            parserComparisons.count
                == repetitions
                    * (
                        fixture.documents.count
                            + fixture.queries.count
                    )
            && parserComparisons.allSatisfy {
                $0.dimension == dimension
                    && $0.allValuesFinite
                    && !$0.zeroVector
            }
        let numericalVarianceBounded =
            !comparisons.isEmpty
            && comparisons.allSatisfy(
                OllamaEmbeddingStabilityContract.accepts
            )

        let baselineRankings = try rankings(
            fixture: fixture,
            documentVectors: baselineDocuments,
            queryVectors: baselineQueries
        )
        var allRankings = [baselineRankings]
        for index in batchDocumentRuns.indices {
            allRankings.append(try rankings(
                fixture: fixture,
                documentVectors: batchDocumentRuns[index],
                queryVectors: batchQueryRuns[index]
            ))
        }

        var stableTop1 = true
        var stableOrderedTop5 = true
        var minimumRankingMargin = Double.infinity
        var rankingHashes: [String] = []
        for query in fixture.queries {
            guard let baseline = baselineRankings[query.identifier],
                  baseline.count == 5
            else {
                throw OllamaEmbeddingFailure(.invalidResponse)
            }
            let baselineIdentifiers =
                baseline.map(\.identifier)
            stableTop1 =
                stableTop1
                && baselineIdentifiers.first == query.expectedTop1
            stableOrderedTop5 =
                stableOrderedTop5
                && Set(baselineIdentifiers)
                    == query.expectedTop5Set
            rankingHashes.append(
                OllamaEmbeddingVectorMath.rankingHash(baseline)
            )
            for (runIndex, run) in allRankings.enumerated() {
                guard let ranking = run[query.identifier] else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                let identifiers = ranking.map(\.identifier)
                let scores = ranking.map(\.cosineSimilarity)
                stableTop1 =
                    stableTop1
                    && identifiers.first == query.expectedTop1
                stableOrderedTop5 =
                    stableOrderedTop5
                    && identifiers == baselineIdentifiers
                    && Set(identifiers) == query.expectedTop5Set
                var runMinimumMargin = Double.infinity
                for index in 0..<(ranking.count - 1) {
                    let margin =
                        ranking[index].cosineSimilarity
                            - ranking[index + 1]
                                .cosineSimilarity
                    runMinimumMargin = min(
                        runMinimumMargin,
                        margin
                    )
                }
                minimumRankingMargin = min(
                    minimumRankingMargin,
                    runMinimumMargin
                )
                rankingEvidenceSink?(.init(
                    queryIdentifier: query.identifier,
                    generationForm:
                        runIndex == 0 ? "single" : "batch",
                    modelOrderScenario: modelOrderScenario,
                    repetitionNumber:
                        runIndex == 0 ? 1 : runIndex,
                    expectedTop1Identifier: query.expectedTop1,
                    expectedTop5Set:
                        query.expectedTop5Set.sorted(),
                    top1Identifier: identifiers[0],
                    orderedTop5Identifiers: identifiers,
                    top5Set: Set(identifiers).sorted(),
                    scoreOrdering: scores,
                    minimumAdjacentMargin: runMinimumMargin,
                    rankingHash:
                        OllamaEmbeddingVectorMath
                            .rankingHash(ranking)
                ))
            }
        }

        var reasonCodes: [String] = []
        reasonCodes.append(
            requestIdentityVerified
                ? EmbeddingAssessmentReasonCode
                    .requestIdentityVerified.rawValue
                : EmbeddingAssessmentReasonCode
                    .runtimeProfileStale.rawValue
        )
        reasonCodes.append(
            parserParityVerified
                ? EmbeddingAssessmentReasonCode
                    .parserParityVerified.rawValue
                : EmbeddingAssessmentReasonCode
                    .dimensionDrift.rawValue
        )
        if !allValuesFinite {
            reasonCodes.append(
                EmbeddingAssessmentReasonCode
                    .nonFiniteVector.rawValue
            )
        }
        if zeroVectorDetected
            || differentInputCollapseDetected {
            reasonCodes.append(
                EmbeddingAssessmentReasonCode
                    .vectorCollapse.rawValue
            )
        }
        reasonCodes.append(
            numericalVarianceBounded
                ? EmbeddingAssessmentReasonCode
                    .boundedNumericalVariance.rawValue
                : EmbeddingAssessmentReasonCode
                    .numericalVarianceExceeded.rawValue
        )
        reasonCodes.append(
            stableTop1
                    && stableOrderedTop5
                    && minimumRankingMargin > 0
                ? EmbeddingAssessmentReasonCode
                    .retrievalStabilityVerified.rawValue
                : EmbeddingAssessmentReasonCode
                    .rankingInstability.rawValue
        )

        return .init(
            modelIdentifier: modelIdentifier,
            modelDigest: modelDigest,
            ollamaVersion: ollamaVersion,
            requestProfileVersion: profile.version,
            requestProfileHash: profile.stableHash,
            observedDimension: dimension,
            explicitDimensions: dimension,
            truncate: profile.truncate,
            normalizationVersion: profile.normalizationVersion,
            repetitionCount: repetitions,
            requestIdentityVerified:
                requestIdentityVerified
                && discovery.requestIdentity
                    == discoveryExpectedIdentity,
            parserParityVerified: parserParityVerified,
            allValuesFinite: allValuesFinite,
            zeroVectorDetected: zeroVectorDetected,
            differentInputCollapseDetected:
                differentInputCollapseDetected,
            minimumCosineSimilarity:
                comparisons.map(\.cosineSimilarity).min()
                    ?? -.infinity,
            maximumRelativeL2NormDrift:
                comparisons.map(\.relativeL2NormDrift).max()
                    ?? .infinity,
            minimumL2Norm:
                comparisons.flatMap {
                    [$0.leftL2Norm, $0.rightL2Norm]
                }.min() ?? -.infinity,
            maximumL2Norm:
                comparisons.flatMap {
                    [$0.leftL2Norm, $0.rightL2Norm]
                }.max() ?? .infinity,
            maximumAbsoluteComponentDelta:
                comparisons.map(\.maximumAbsoluteComponentDelta)
                    .max() ?? .infinity,
            maximumRMSComponentDelta:
                comparisons.map(\.rmsComponentDelta).max()
                    ?? .infinity,
            stableTop1: stableTop1,
            stableOrderedTop5: stableOrderedTop5,
            minimumRankingMargin: minimumRankingMargin,
            rankingHashes: rankingHashes,
            reasonCodes: reasonCodes
        )
    }

    private static func rankings(
        fixture: OllamaEmbeddingStabilityFixture,
        documentVectors: [String: [Double]],
        queryVectors: [String: [Double]]
    ) throws -> [String: [OllamaEmbeddingRankedResult]] {
        let documents: [
            (identifier: String, vector: [Float])
        ] = try fixture.documents.map { document in
            guard let vector =
                    documentVectors[document.identifier]
            else {
                throw OllamaEmbeddingFailure(.invalidResponse)
            }
            return (
                identifier: document.identifier,
                vector: vector.map(Float.init)
            )
        }
        return try Dictionary(
            uniqueKeysWithValues: fixture.queries.map { query in
                guard let vector = queryVectors[query.identifier]
                else {
                    throw OllamaEmbeddingFailure(.invalidResponse)
                }
                return (
                    query.identifier,
                    OllamaEmbeddingVectorMath.rank(
                        query: vector.map(Float.init),
                        documents: documents,
                        limit: 5
                    )
                )
            }
        )
    }

    private static func emitEvidence(
        sink: (@Sendable (
            OllamaEmbeddingStabilityRequestReceipt
        ) -> Void)?,
        request: OllamaEmbeddingRequest,
        receipt: OllamaEmbeddingReceipt,
        identity: OllamaEmbeddingRequestIdentity,
        fixtureIdentifiers: [String],
        modelDigest: String,
        ollamaVersion: String,
        scenario: String,
        sequence: Int,
        wallDurationMilliseconds: Int
    ) {
        guard let sink,
              receipt.vectors.count == fixtureIdentifiers.count,
              identity.normalizedInputHashes.count
                == fixtureIdentifiers.count
        else { return }
        for index in receipt.vectors.indices {
            let vector = receipt.vectors[index]
            let absoluteValues = vector.map(abs)
            let l2Norm = sqrt(
                vector.reduce(0) { $0 + $1 * $1 }
            )
            sink(.init(
                fixtureIdentifier: fixtureIdentifiers[index],
                normalizedInputSHA256:
                    identity.normalizedInputHashes[index],
                normalizedInputsSHA256:
                    identity.normalizedInputsHash,
                canonicalRequestSHA256:
                    identity.canonicalRequestHash,
                requestProfileSHA256:
                    identity.requestProfileHash,
                modelIdentifier: receipt.modelIdentifier,
                modelDigest: modelDigest.lowercased(),
                ollamaVersion: ollamaVersion,
                dimensionsParameter: request.dimensions,
                truncate: request.profile.truncate,
                runtimeOptions: [],
                inputForm:
                    request.inputs.count == 1
                        ? "single"
                        : "batch",
                sequenceNumber: sequence,
                modelOrderScenario: scenario,
                responseDimension: receipt.observedDimension,
                promptTokenCount: receipt.promptTokenCount,
                totalDurationNanoseconds:
                    receipt.totalDurationNanoseconds,
                loadDurationNanoseconds:
                    receipt.loadDurationNanoseconds,
                wallDurationMilliseconds:
                    max(0, wallDurationMilliseconds),
                allValuesFinite:
                    vector.allSatisfy(\.isFinite),
                zeroVector:
                    !vector.contains(where: { $0 != 0 }),
                l1Norm: absoluteValues.reduce(0, +),
                l2Norm: l2Norm,
                minimumValue: vector.min() ?? .nan,
                maximumValue: vector.max() ?? .nan
            ))
        }
    }
}
