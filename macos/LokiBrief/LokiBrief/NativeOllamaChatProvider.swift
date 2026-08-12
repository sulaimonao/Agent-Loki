import CFNetwork
import CryptoKit
import Foundation

enum P8FProviderRequestKind: String, Codable, CaseIterable, Sendable {
    case native = "ollama_native"
    case chat = "ollama_chat"
    case embedding = "ollama_embedding"
}

enum P8FProviderRequestOperation: String, Codable, CaseIterable, Sendable {
    case versionCheck = "ollama_version_check"
    case modelDiscovery = "ollama_model_discovery"
    case generation = "ollama_generation"
    case modelInspect = "ollama_model_inspect"
    case chatStream = "ollama_chat_stream"
    case embedding = "ollama_embedding"
}

enum P8FProviderRequestOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
}

enum P8FProviderEndpointPolicyClassification:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    /// This is an application endpoint-policy declaration. It is not evidence
    /// of observed sockets or a substitute for an operator-owned watcher.
    case ollamaModelIPv4Loopback =
        "ollama_model_http_ipv4_loopback_127_0_0_1_11434"
}

struct P8FProviderRequestCorrelationToken:
    Hashable,
    Sendable,
    CustomDebugStringConvertible
{
    fileprivate let activationGeneration: UInt64
    fileprivate let requestIdentifierSHA256: String

    var debugDescription: String {
        "P8FProviderRequestCorrelationToken(request_identifier_sha256: \(requestIdentifierSHA256))"
    }
}

/// Opaque authority for exactly one activated provider-evidence generation.
/// The raw run identifier is never retained; only its domain-separated hash is exposed.
struct P8FProviderRequestEvidenceRun:
    Codable,
    Hashable,
    Sendable,
    CustomDebugStringConvertible
{
    fileprivate let activationGeneration: UInt64
    let runIdentifierSHA256: String

    enum CodingKeys: String, CodingKey {
        case activationGeneration = "activation_generation"
        case runIdentifierSHA256 = "run_identifier_sha256"
    }

    var debugDescription: String {
        "P8FProviderRequestEvidenceRun(activation_generation: \(activationGeneration), run_identifier_sha256: \(runIdentifierSHA256))"
    }
}

struct P8FProviderRequestObservation:
    Codable,
    Hashable,
    Sendable,
    CustomDebugStringConvertible
{
    let sequence: UInt64
    let providerKind: P8FProviderRequestKind
    let operationKind: P8FProviderRequestOperation
    let outcome: P8FProviderRequestOutcome
    let processIdentifier: Int32
    let executableSHA256: String
    let requestIdentifierSHA256: String
    let requestTraceSHA256: String
    let providerRequestStartedAt: Date
    let providerRequestEndedAt: Date
    let providerRequestDurationMilliseconds: Int
    let endpointPolicyClassification:
        P8FProviderEndpointPolicyClassification

    enum CodingKeys: String, CodingKey {
        case sequence
        case providerKind = "provider_kind"
        case operationKind = "operation_kind"
        case outcome
        case processIdentifier = "process_identifier"
        case executableSHA256 = "executable_sha256"
        case requestIdentifierSHA256 =
            "request_identifier_sha256"
        case requestTraceSHA256 = "request_trace_sha256"
        case providerRequestStartedAt =
            "provider_request_started_at"
        case providerRequestEndedAt =
            "provider_request_ended_at"
        case providerRequestDurationMilliseconds =
            "provider_request_duration_ms"
        case endpointPolicyClassification =
            "endpoint_policy_classification"
    }

    var debugDescription: String {
        [
            "P8FProviderRequestObservation(",
            "sequence: \(sequence)",
            "provider: \(providerKind.rawValue)",
            "operation: \(operationKind.rawValue)",
            "outcome: \(outcome.rawValue)",
            "pid: \(processIdentifier)",
            "executable_sha256: \(executableSHA256)",
            "request_identifier_sha256: \(requestIdentifierSHA256)",
            "request_trace_sha256: \(requestTraceSHA256)",
            "duration_ms: \(providerRequestDurationMilliseconds)",
            "endpoint_policy: \(endpointPolicyClassification.rawValue)",
            ")",
        ].joined(separator: ", ")
    }
}

/// Immutable observation snapshot produced once for one evidence generation.
struct P8FProviderRequestEvidenceSeal:
    Codable,
    Hashable,
    Sendable
{
    let run: P8FProviderRequestEvidenceRun
    let latestSequence: UInt64
    let observations: [P8FProviderRequestObservation]

    enum CodingKeys: String, CodingKey {
        case run
        case latestSequence = "latest_sequence"
        case observations
    }
}

struct P8FProviderRequestCorrelationState:
    Codable,
    Equatable,
    Sendable
{
    let isActive: Bool
    let pendingRequestCount: Int
    let observationCount: Int
    let latestSequence: UInt64

    enum CodingKeys: String, CodingKey {
        case isActive = "is_active"
        case pendingRequestCount = "pending_request_count"
        case observationCount = "observation_count"
        case latestSequence = "latest_sequence"
    }
}

enum P8FProviderRequestCorrelationFailure:
    Error,
    Equatable,
    Sendable
{
    case invalidProcessIdentifier
    case invalidExecutableSHA256
    case invalidRunIdentifier
    case evidenceRecorderInactive
    case evidenceRunMismatch
    case evidenceRequestsPending
    case evidenceRequestInvalid
    case evidenceRequestAdmissionClosed
    case evidenceObservationCapacityExceeded
}

/// Process-local, app-side request correlation for the signed-smoke lane.
///
/// The recorder is inert until signed-smoke admission explicitly activates it.
/// It stores hashes and typed policy declarations only. It never stores raw
/// request identifiers, trace identifiers, prompts, responses, vectors, image
/// bytes, model content, credentials, file paths, or hidden reasoning.
final class P8FProviderRequestCorrelationRecorder:
    @unchecked Sendable
{
    static let shared = P8FProviderRequestCorrelationRecorder()

    private struct Activation {
        let run: P8FProviderRequestEvidenceRun
        let processIdentifier: Int32
        let executableSHA256: String
        var sealedEvidence: P8FProviderRequestEvidenceSeal?
    }

    private struct PendingRequest {
        let providerKind: P8FProviderRequestKind
        let operationKind: P8FProviderRequestOperation
        let processIdentifier: Int32
        let executableSHA256: String
        let requestIdentifierSHA256: String
        let requestTraceSHA256: String
        let startedAt: Date
    }

    private static let maximumObservationCount = 4_096
    private static let maximumDurationMilliseconds = 600_000

    private let lock = NSLock()
    private var activationGeneration: UInt64 = 0
    private var activation: Activation?
    private var pending: [
        P8FProviderRequestCorrelationToken: PendingRequest
    ] = [:]
    private var observations: [P8FProviderRequestObservation] = []
    private var nextSequence: UInt64 = 0

    private init() {}

    @discardableResult
    func activate(
        processIdentifier: Int32,
        admittedExecutableSHA256: String,
        runIdentifier: String = UUID().uuidString.lowercased()
    ) throws -> P8FProviderRequestEvidenceRun {
        guard processIdentifier > 0,
              processIdentifier
                == Int32(ProcessInfo.processInfo.processIdentifier)
        else {
            throw P8FProviderRequestCorrelationFailure
                .invalidProcessIdentifier
        }
        let normalizedSHA = admittedExecutableSHA256.lowercased()
        guard Self.isSHA256(normalizedSHA) else {
            throw P8FProviderRequestCorrelationFailure
                .invalidExecutableSHA256
        }
        guard Self.isValidRunIdentifier(runIdentifier) else {
            throw P8FProviderRequestCorrelationFailure
                .invalidRunIdentifier
        }
        let runIdentifierSHA256 = Self.sha256(
            domain: "agent-loki.p8f.provider-evidence-run.v1",
            value: runIdentifier
        )

        return try lock.withLock {
            guard pending.isEmpty else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRequestsPending
            }
            activationGeneration &+= 1
            let run = P8FProviderRequestEvidenceRun(
                activationGeneration: activationGeneration,
                runIdentifierSHA256: runIdentifierSHA256
            )
            activation = .init(
                run: run,
                processIdentifier: processIdentifier,
                executableSHA256: normalizedSHA,
                sealedEvidence: nil
            )
            pending.removeAll(keepingCapacity: false)
            observations.removeAll(keepingCapacity: false)
            nextSequence = 0
            return run
        }
    }

    func deactivate() {
        lock.withLock {
            activation = nil
            pending.removeAll(keepingCapacity: false)
        }
    }

    var isActive: Bool {
        lock.withLock { activation != nil }
    }

    func begin(
        providerKind: P8FProviderRequestKind,
        operationKind: P8FProviderRequestOperation,
        requestIdentifier: UUID,
        requestTraceMaterial: String,
        startedAt: Date = Date()
    ) throws -> P8FProviderRequestCorrelationToken? {
        guard startedAt.timeIntervalSinceReferenceDate
            .isFinite
        else {
            throw P8FProviderRequestCorrelationFailure
                .evidenceRequestInvalid
        }
        let identifierHash = Self.sha256(
            domain: "agent-loki.p8f.provider-request-id.v1",
            value: requestIdentifier.uuidString.lowercased()
        )
        let traceHash = Self.sha256(
            domain: "agent-loki.p8f.provider-request-trace.v1",
            value: requestTraceMaterial
        )

        return try lock.withLock {
            guard let activation else {
                return nil
            }
            guard activation.sealedEvidence == nil else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRequestAdmissionClosed
            }
            // Every admitted request owns one future observation slot.
            guard observations.count + pending.count
                    < Self.maximumObservationCount
            else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceObservationCapacityExceeded
            }
            let token = P8FProviderRequestCorrelationToken(
                activationGeneration:
                    activation.run.activationGeneration,
                requestIdentifierSHA256: identifierHash
            )
            guard pending[token] == nil else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRequestInvalid
            }
            pending[token] = .init(
                providerKind: providerKind,
                operationKind: operationKind,
                processIdentifier:
                    activation.processIdentifier,
                executableSHA256:
                    activation.executableSHA256,
                requestIdentifierSHA256: identifierHash,
                requestTraceSHA256: traceHash,
                startedAt: startedAt
            )
            return token
        }
    }

    @discardableResult
    func complete(
        _ token: P8FProviderRequestCorrelationToken?,
        outcome: P8FProviderRequestOutcome,
        endedAt: Date = Date()
    ) -> Bool {
        guard let token,
              endedAt.timeIntervalSinceReferenceDate
                .isFinite
        else {
            return false
        }
        return lock.withLock {
            guard let activation,
                  activation.sealedEvidence == nil,
                  activation.run.activationGeneration
                    == token.activationGeneration,
                  let pendingRequest = pending[token],
                  observations.count
                    < Self.maximumObservationCount
            else {
                return false
            }
            let rawSeconds = endedAt.timeIntervalSince(
                pendingRequest.startedAt
            )
            let boundedSeconds: Double
            if rawSeconds.isFinite, rawSeconds > 0 {
                boundedSeconds = min(
                    rawSeconds,
                    Double(
                        Self.maximumDurationMilliseconds
                    ) / 1_000
                )
            } else {
                boundedSeconds = 0.001
            }
            let durationMilliseconds = max(
                1,
                min(
                    Self.maximumDurationMilliseconds,
                    Int(ceil(boundedSeconds * 1_000))
                )
            )
            let boundedEndedAt = pendingRequest.startedAt
                .addingTimeInterval(
                    TimeInterval(durationMilliseconds) / 1_000
                )
            nextSequence &+= 1
            observations.append(.init(
                sequence: nextSequence,
                providerKind: pendingRequest.providerKind,
                operationKind: pendingRequest.operationKind,
                outcome: outcome,
                processIdentifier:
                    pendingRequest.processIdentifier,
                executableSHA256:
                    pendingRequest.executableSHA256,
                requestIdentifierSHA256:
                    pendingRequest.requestIdentifierSHA256,
                requestTraceSHA256:
                    pendingRequest.requestTraceSHA256,
                providerRequestStartedAt:
                    pendingRequest.startedAt,
                providerRequestEndedAt: boundedEndedAt,
                providerRequestDurationMilliseconds:
                    durationMilliseconds,
                endpointPolicyClassification:
                    .ollamaModelIPv4Loopback
            ))
            // Keep the token pending until its evidence append commits so a
            // failed completion cannot make sealing overlook the request.
            _ = pending.removeValue(forKey: token)
            return true
        }
    }

    /// Atomically closes request admission and snapshots the exact drained observation set.
    /// A caller must first drain every token begun in this generation. Repeated calls with
    /// the same run return the cached value; an old generation cannot seal a replacement.
    func sealEvidence(
        for run: P8FProviderRequestEvidenceRun
    ) throws -> P8FProviderRequestEvidenceSeal {
        try lock.withLock {
            guard var activation else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRecorderInactive
            }
            guard activation.run == run else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRunMismatch
            }
            if let sealedEvidence = activation.sealedEvidence {
                return sealedEvidence
            }
            guard pending.isEmpty else {
                throw P8FProviderRequestCorrelationFailure
                    .evidenceRequestsPending
            }

            let sealedEvidence = P8FProviderRequestEvidenceSeal(
                run: run,
                latestSequence: nextSequence,
                observations: observations
            )
            activation.sealedEvidence = sealedEvidence
            self.activation = activation
            return sealedEvidence
        }
    }

    func snapshot(
        afterSequence: UInt64 = 0
    ) -> [P8FProviderRequestObservation] {
        lock.withLock {
            observations.filter {
                $0.sequence > afterSequence
            }
        }
    }

    func stateSnapshot()
        -> P8FProviderRequestCorrelationState
    {
        lock.withLock {
            .init(
                isActive: activation != nil,
                pendingRequestCount: pending.count,
                observationCount: observations.count,
                latestSequence: nextSequence
            )
        }
    }

    func resetForTesting() {
        lock.withLock {
            activationGeneration &+= 1
            activation = nil
            pending.removeAll(keepingCapacity: false)
            observations.removeAll(keepingCapacity: false)
            nextSequence = 0
        }
    }

    private static func sha256(
        domain: String,
        value: String
    ) -> String {
        var data = Data(domain.utf8)
        data.append(0)
        data.append(contentsOf: value.utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (97...102).contains($0.value)
            }
    }

    private static func isValidRunIdentifier(
        _ value: String
    ) -> Bool {
        (1...512).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

enum OllamaChatProviderLimits {
    static let minimumTimeoutSeconds: TimeInterval = 5
    static let maximumTimeoutSeconds: TimeInterval = 120
    static let defaultTimeoutSeconds: TimeInterval = 60
    static let maximumRequestBytes = 48 * 1_024 * 1_024
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumShowResponseBytes = 1 * 1_024 * 1_024
    static let maximumNDJSONLineBytes = 512 * 1_024
    static let maximumMessageCount = 64
    static let maximumMessageContentBytes = 128 * 1_024
    static let maximumCombinedMessageBytes = 384 * 1_024
    static let maximumOutputBytes = 256 * 1_024
    static let maximumThinkingBytes = 256 * 1_024
    static let maximumImageCount = VisionAttachmentLimits.maximumAttachmentCount
    static let maximumImageBytes = VisionAttachmentLimits.maximumPerImageBytes
    static let maximumCombinedImageBytes = VisionAttachmentLimits.maximumTotalBytes
    static let maximumToolCount = 16
    static let maximumToolCallsPerResponse = 8
    static let maximumToolArgumentsBytes = 16 * 1_024
    static let maximumIdentifierCharacters = 256
    static let maximumToolDescriptionCharacters = 1_000
    static let maximumOutputTokens = 8_192

    static func contains(timeout: TimeInterval) -> Bool {
        timeout.isFinite
            && timeout >= minimumTimeoutSeconds
            && timeout <= maximumTimeoutSeconds
    }
}

enum OllamaChatFailureCode: String, Codable, CaseIterable, Sendable {
    case invalidEndpoint = "ollama_chat_invalid_endpoint"
    case redirectRejected = "ollama_chat_redirect_rejected"
    case authenticationRejected = "ollama_chat_authentication_rejected"
    case invalidRequest = "ollama_chat_invalid_request"
    case cloudModelRejected = "ollama_chat_cloud_model_rejected"
    case requestTooLarge = "ollama_chat_request_too_large"
    case responseTooLarge = "ollama_chat_response_too_large"
    case ndjsonLineTooLarge = "ollama_chat_ndjson_line_too_large"
    case serviceUnavailable = "ollama_chat_service_unavailable"
    case requestTimedOut = "ollama_chat_request_timed_out"
    case requestCancelled = "ollama_chat_request_cancelled"
    case httpFailure = "ollama_chat_http_failure"
    case invalidResponse = "ollama_chat_invalid_response"
    case responseModelMismatch = "ollama_chat_response_model_mismatch"
    case invalidToolCall = "ollama_chat_invalid_tool_call"
    case structuredOutputInvalid = "ollama_chat_structured_output_invalid"
    case outputTruncated = "ollama_chat_output_truncated"
    case assessmentFailed = "ollama_chat_assessment_failed"
}

struct OllamaChatFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: OllamaChatFailureCode
    let httpStatus: Int?

    init(_ code: OllamaChatFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .invalidEndpoint:
            "The request did not match the fixed numeric-loopback Ollama Chat endpoint."
        case .redirectRejected:
            "Ollama Chat attempted a redirect. Redirects are not permitted."
        case .authenticationRejected:
            "Ollama Chat requested credentials. Credentialed requests are not permitted."
        case .invalidRequest:
            "The bounded Ollama Chat request was invalid."
        case .cloudModelRejected:
            "Cloud model references are not permitted for local Ollama Chat."
        case .requestTooLarge:
            "The bounded Ollama Chat request exceeded its size limit."
        case .responseTooLarge:
            "The Ollama Chat response exceeded its size limit."
        case .ndjsonLineTooLarge:
            "One Ollama Chat streaming record exceeded its size limit."
        case .serviceUnavailable:
            "The local Ollama service is unavailable."
        case .requestTimedOut:
            "The local Ollama request timed out."
        case .requestCancelled:
            "The local Ollama request was cancelled."
        case .httpFailure:
            "The local Ollama service returned an unsuccessful response."
        case .invalidResponse:
            "The local Ollama service returned an invalid response."
        case .responseModelMismatch:
            "The Ollama response did not match the explicitly selected model."
        case .invalidToolCall:
            "The model returned an invalid or unregistered tool request."
        case .structuredOutputInvalid:
            "The model did not satisfy the required structured-output probe."
        case .outputTruncated:
            "The bounded Ollama Chat response ended at its output-token limit."
        case .assessmentFailed:
            "The bounded model capability assessment failed."
        }
    }
}

enum OllamaChatRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct OllamaChatToolCall: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: Data

    init(id: String, name: String, argumentsJSON: Data) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

struct OllamaChatMessage: Hashable, Sendable {
    let role: OllamaChatRole
    let content: String
    let toolCalls: [OllamaChatToolCall]
    let toolName: String?
    /// Metadata-stripped image bytes for the fixed-loopback Ollama image
    /// message contract. These bytes are never persisted by chat storage.
    let images: [Data]
    /// Protocol-required reasoning state may be carried only inside the active
    /// in-memory tool loop. It is intentionally absent from persistence,
    /// exports, trace metadata, and semantic-index inputs.
    let ephemeralThinking: String?

    init(
        role: OllamaChatRole,
        content: String,
        toolCalls: [OllamaChatToolCall] = [],
        toolName: String? = nil,
        images: [Data] = [],
        ephemeralThinking: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.images = images
        self.ephemeralThinking = ephemeralThinking
    }
}

struct OllamaChatToolDefinition: Codable, Hashable, Sendable {
    let name: String
    let description: String
    let parametersJSONSchema: Data

    init(name: String, description: String, parametersJSONSchema: Data) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

struct OllamaChatRequest: Hashable, Sendable {
    let modelIdentifier: String
    let messages: [OllamaChatMessage]
    let tools: [OllamaChatToolDefinition]
    let outputJSONSchema: Data?
    let stream: Bool
    let timeoutSeconds: TimeInterval
    let configuredContextTokens: Int?
    let maximumOutputTokens: Int
    let reasoningControl: ModelReasoningControl

    init(
        modelIdentifier: String,
        messages: [OllamaChatMessage],
        tools: [OllamaChatToolDefinition] = [],
        outputJSONSchema: Data? = nil,
        stream: Bool = true,
        timeoutSeconds: TimeInterval = OllamaChatProviderLimits.defaultTimeoutSeconds,
        configuredContextTokens: Int? = nil,
        maximumOutputTokens: Int = 2_048,
        reasoningControl: ModelReasoningControl = .disabled
    ) {
        self.modelIdentifier = modelIdentifier
        self.messages = messages
        self.tools = tools
        self.outputJSONSchema = outputJSONSchema
        self.stream = stream
        self.timeoutSeconds = timeoutSeconds
        self.configuredContextTokens = configuredContextTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.reasoningControl = reasoningControl
    }
}

struct OllamaChatCompletion: Hashable, Sendable {
    let modelIdentifier: String
    let content: String
    let toolCalls: [OllamaChatToolCall]
    let doneReason: String?
    let durationMilliseconds: Int?
    let promptTokenCount: Int?
    let outputTokenCount: Int?
    let chunkCount: Int
    /// Ephemeral transport state for an immediately continuing tool loop.
    /// Callers must discard this value when the active turn ends or cancels.
    let ephemeralThinking: String
}

enum OllamaChatStreamEvent: Sendable {
    case responseStarted
    case thinkingDelta(String)
    case contentDelta(String)
    case toolCall(OllamaChatToolCall)
    case completed(OllamaChatCompletion)
}

struct OllamaChatStreamHandle {
    let requestID: UUID
    let events: AsyncThrowingStream<OllamaChatStreamEvent, Error>
}

struct OllamaChatTransportResponseHead: Sendable {
    let statusCode: Int
    let finalURL: URL?
    let expectedContentLength: Int64?
}

enum OllamaChatTransportEvent: Sendable {
    case response(OllamaChatTransportResponseHead)
    case bytes(Data)
}

protocol OllamaChatTransporting: Sendable {
    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error>

    func cancel(requestID: UUID) async
}

enum OllamaLoopbackEndpointPolicy {
    static let baseURL = URL(string: "http://127.0.0.1:11434/api")!

    private static let operations: [String: String] = [
        "/api/show": "POST",
        "/api/chat": "POST",
        "/api/embed": "POST",
    ]

    static func url(path: String) throws -> URL {
        guard ["show", "chat", "embed"].contains(path) else {
            throw OllamaChatFailure(.invalidEndpoint)
        }
        return baseURL.appendingPathComponent(path, isDirectory: false)
    }

    static func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              components.host == "127.0.0.1",
              components.port == 11_434,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let expectedMethod = operations[components.percentEncodedPath],
              request.httpMethod == expectedMethod,
              request.httpBody != nil,
              request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil
        else {
            throw OllamaChatFailure(.invalidEndpoint)
        }
    }
}

final class BoundedOllamaChatTransport: NSObject, OllamaChatTransporting, @unchecked Sendable {
    private final class TaskState {
        let requestID: UUID
        let responseLimit: Int
        let continuation: AsyncThrowingStream<OllamaChatTransportEvent, Error>.Continuation
        var responseBytes = 0
        var terminalFailure: OllamaChatFailure?
        var cancellationDrainWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            requestID: UUID,
            responseLimit: Int,
            continuation: AsyncThrowingStream<OllamaChatTransportEvent, Error>.Continuation
        ) {
            self.requestID = requestID
            self.responseLimit = responseLimit
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let didCompleteTestHook: (@Sendable (Int) -> Void)?
    private var session: URLSession!
    private var statesByTaskID: [Int: TaskState] = [:]
    private var tasksByRequestID: [UUID: URLSessionTask] = [:]

    override convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(
        configuration: URLSessionConfiguration,
        didCompleteTestHook: (@Sendable (Int) -> Void)? = nil
    ) {
        self.didCompleteTestHook = didCompleteTestHook
        super.init()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = OllamaChatProviderLimits.maximumTimeoutSeconds
        configuration.timeoutIntervalForResource = OllamaChatProviderLimits.maximumTimeoutSeconds
        configuration.httpMaximumConnectionsPerHost = 2

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.agentloki.LokiBrief.ollama-chat.transport"
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                try OllamaLoopbackEndpointPolicy.validate(request)
                guard responseLimit > 0,
                      responseLimit <= OllamaChatProviderLimits.maximumResponseBytes
                else {
                    throw OllamaChatFailure(.responseTooLarge)
                }
                guard !Task.isCancelled else {
                    throw OllamaChatFailure(.requestCancelled)
                }

                let task = session.dataTask(with: request)
                let state = TaskState(
                    requestID: requestID,
                    responseLimit: responseLimit,
                    continuation: continuation
                )
                let taskIdentifier = task.taskIdentifier
                lock.lock()
                statesByTaskID[task.taskIdentifier] = state
                tasksByRequestID[requestID] = task
                lock.unlock()

                continuation.onTermination = { [weak self] _ in
                    self?.cancelNow(
                        requestID: requestID,
                        taskIdentifier: taskIdentifier
                    )
                }
                task.resume()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel(requestID: UUID) async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            let task: URLSessionTask?
            lock.lock()
            if let candidate = tasksByRequestID[requestID],
               let state = statesByTaskID[candidate.taskIdentifier]
            {
                state.terminalFailure = .init(.requestCancelled)
                state.cancellationDrainWaiters.append(continuation)
                task = candidate
            } else {
                task = nil
            }
            lock.unlock()

            guard let task else {
                continuation.resume()
                return
            }
            task.cancel()
        }
    }

    private func cancelNow(
        requestID: UUID,
        taskIdentifier: Int
    ) {
        lock.lock()
        let task = tasksByRequestID[requestID]
        if let task,
           task.taskIdentifier == taskIdentifier,
           let state = statesByTaskID[taskIdentifier]
        {
            state.terminalFailure = .init(.requestCancelled)
        }
        lock.unlock()
        if task?.taskIdentifier == taskIdentifier {
            task?.cancel()
        }
    }

    private func setTerminalFailure(_ failure: OllamaChatFailure, for task: URLSessionTask) {
        lock.lock()
        statesByTaskID[task.taskIdentifier]?.terminalFailure = failure
        lock.unlock()
    }

    private func complete(_ task: URLSessionTask, networkError: Error?) {
        lock.lock()
        guard let state = statesByTaskID.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        if tasksByRequestID[state.requestID]?.taskIdentifier
            == task.taskIdentifier
        {
            tasksByRequestID.removeValue(forKey: state.requestID)
        }
        let terminalFailure = state.terminalFailure
        let cancellationDrainWaiters = state.cancellationDrainWaiters
        lock.unlock()

        if let terminalFailure {
            state.continuation.finish(throwing: terminalFailure)
        } else if let networkError {
            state.continuation.finish(throwing: Self.map(networkError))
        } else {
            state.continuation.finish()
        }
        cancellationDrainWaiters.forEach { $0.resume() }
    }

    private static func map(_ error: Error) -> OllamaChatFailure {
        if let failure = error as? OllamaChatFailure {
            return failure
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .init(.requestCancelled)
            case .timedOut:
                return .init(.requestTimedOut)
            default:
                return .init(.serviceUnavailable)
            }
        }
        if error is CancellationError {
            return .init(.requestCancelled)
        }
        return .init(.serviceUnavailable)
    }
}

extension BoundedOllamaChatTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            setTerminalFailure(.init(.invalidResponse), for: dataTask)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let state = statesByTaskID[dataTask.taskIdentifier]
        let declaredLength = response.expectedContentLength >= 0
            ? response.expectedContentLength
            : nil
        let tooLarge = declaredLength.map { $0 > Int64(state?.responseLimit ?? 0) } ?? false
        if tooLarge {
            state?.terminalFailure = .init(.responseTooLarge)
        }
        lock.unlock()

        guard let state, !tooLarge else {
            completionHandler(.cancel)
            return
        }
        state.continuation.yield(.response(.init(
            statusCode: http.statusCode,
            finalURL: response.url,
            expectedContentLength: declaredLength
        )))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = statesByTaskID[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let nextCount = state.responseBytes + data.count
        guard nextCount <= state.responseLimit else {
            state.terminalFailure = .init(.responseTooLarge)
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.responseBytes = nextCount
        lock.unlock()
        state.continuation.yield(.bytes(data))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        setTerminalFailure(
            .init(.redirectRejected, httpStatus: response.statusCode),
            for: task
        )
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        setTerminalFailure(.init(.authenticationRejected), for: task)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        didCompleteTestHook?(task.taskIdentifier)
        complete(task, networkError: error)
    }
}

struct OllamaNDJSONLineDecoder {
    private(set) var totalBytes = 0
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        totalBytes += data.count
        guard totalBytes <= OllamaChatProviderLimits.maximumResponseBytes else {
            throw OllamaChatFailure(.responseTooLarge)
        }
        buffer.append(data)

        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard line.count <= OllamaChatProviderLimits.maximumNDJSONLineBytes else {
                throw OllamaChatFailure(.ndjsonLineTooLarge)
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        guard buffer.count <= OllamaChatProviderLimits.maximumNDJSONLineBytes else {
            throw OllamaChatFailure(.ndjsonLineTooLarge)
        }
        return lines
    }

    mutating func finish() throws -> [Data] {
        guard buffer.count <= OllamaChatProviderLimits.maximumNDJSONLineBytes else {
            throw OllamaChatFailure(.ndjsonLineTooLarge)
        }
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [buffer]
    }
}

actor NativeOllamaChatProvider {
    private struct ActiveStream {
        let continuation: AsyncThrowingStream<OllamaChatStreamEvent, Error>.Continuation
        let trace: OllamaChatTraceContext
        let modelHash: String
        let startedAt: TimeInterval
        let correlationToken:
            P8FProviderRequestCorrelationToken?
    }

    private struct ParsedChunk {
        let model: String
        let thinking: String
        let content: String
        let toolCalls: [OllamaChatToolCall]
        let done: Bool
        let doneReason: String?
        let durationMilliseconds: Int?
        let promptTokenCount: Int?
        let outputTokenCount: Int?
    }

    private struct ProbeCollection {
        let completion: OllamaChatCompletion
        let responseStarted: Bool
        let contentDeltaCount: Int
    }

    private struct ProbeOutcome {
        let capabilities: Set<ModelCapability>
        let diagnostics: [ModelCapabilityDiagnostic]

        var wasCancelled: Bool {
            diagnostics.contains { $0.status == .cancelled }
        }
    }

    private let transport: any OllamaChatTransporting
    private let now: @Sendable () -> Date
    private let traceSink: OllamaChatTraceSink
    private var activeStreams: [UUID: ActiveStream] = [:]

    init(
        transport: any OllamaChatTransporting = BoundedOllamaChatTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: @escaping OllamaChatTraceSink = {
            OllamaChatProductionTraceLogger.emit($0)
        }
    ) {
        self.transport = transport
        self.now = now
        self.traceSink = traceSink
    }

    func inspectModel(
        modelIdentifier: String,
        displayName: String? = nil,
        modelDigest: String?,
        providerVersion: String?,
        trace: OllamaChatTraceContext = .init()
    ) async throws -> ModelProfile {
        let started = ProcessInfo.processInfo.systemUptime
        let requestID = UUID()
        let modelHash = OllamaChatTracePrivacy.modelIdentifierHash(modelIdentifier)
        var didStartTransport = false
        var correlationToken:
            P8FProviderRequestCorrelationToken?
        do {
            try validateIdentifier(modelIdentifier)
            let body = try jsonData([
                "model": modelIdentifier,
                "verbose": false,
            ])
            let request = try makeRequest(
                path: "show",
                body: body,
                timeout: OllamaChatProviderLimits.defaultTimeoutSeconds
            )
            correlationToken =
                try P8FProviderRequestCorrelationRecorder.shared.begin(
                    providerKind: .chat,
                    operationKind: .modelInspect,
                    requestIdentifier: requestID,
                    requestTraceMaterial: trace.traceID
                )
            didStartTransport = true
            let response = try await collectResponse(
                request: request,
                requestID: requestID,
                limit: OllamaChatProviderLimits.maximumShowResponseBytes
            )
            let profile = try decodeProfile(
                response,
                modelIdentifier: modelIdentifier,
                displayName: displayName,
                modelDigest: modelDigest,
                providerVersion: providerVersion
            )
            emit(
                .modelProfileInspected,
                trace: trace,
                status: .success,
                reason: "model_profile_inspected",
                started: started,
                metadata: [
                    "model_hash": modelHash,
                    "capability_count": String(profile.estimatedCapabilities.count),
                    "context_classification": profile.contextPolicy.classification.rawValue,
                ]
            )
            P8FProviderRequestCorrelationRecorder.shared
                .complete(
                    correlationToken,
                    outcome: .succeeded
                )
            return profile
        } catch {
            if didStartTransport {
                await transport.cancel(requestID: requestID)
            }
            let failure = mapFailure(error)
            P8FProviderRequestCorrelationRecorder.shared
                .complete(
                    correlationToken,
                    outcome: failure.code
                        == .requestCancelled
                        ? .cancelled
                        : .failed
                )
            emit(
                .modelProfileInspected,
                trace: trace,
                status: failure.code == .requestCancelled ? .skipped : .failed,
                reason: failure.reasonCode,
                started: started,
                metadata: ["model_hash": modelHash]
            )
            throw failure
        }
    }

    func streamChat(
        _ request: OllamaChatRequest,
        trace: OllamaChatTraceContext = .init()
    ) throws -> OllamaChatStreamHandle {
        try validate(request)
        let body = try makeChatBody(request)
        guard body.count <= OllamaChatProviderLimits.maximumRequestBytes else {
            throw OllamaChatFailure(.requestTooLarge)
        }
        let urlRequest = try makeRequest(
            path: "chat",
            body: body,
            timeout: request.timeoutSeconds
        )
        let requestID = UUID()
        let correlationToken =
            try P8FProviderRequestCorrelationRecorder.shared.begin(
                providerKind: .chat,
                operationKind: .chatStream,
                requestIdentifier: requestID,
                requestTraceMaterial: trace.traceID
            )
        let transportEvents = transport.stream(
            for: urlRequest,
            requestID: requestID,
            responseLimit: OllamaChatProviderLimits.maximumResponseBytes
        )
        let pair = AsyncThrowingStream<OllamaChatStreamEvent, Error>.makeStream()
        let modelHash = OllamaChatTracePrivacy.modelIdentifierHash(request.modelIdentifier)
        activeStreams[requestID] = .init(
            continuation: pair.continuation,
            trace: trace,
            modelHash: modelHash,
            startedAt: ProcessInfo.processInfo.systemUptime,
            correlationToken: correlationToken
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(requestID: requestID) }
        }
        emit(
            .chatStreamStarted,
            trace: trace,
            status: .started,
            reason: "ollama_chat_stream_started",
            metadata: [
                "model_hash": modelHash,
                "request_bytes": String(body.count),
            ]
        )
        Task { [weak self] in
            await self?.consume(
                transportEvents,
                request: request,
                requestID: requestID,
                expectedURL: urlRequest.url
            )
        }
        return .init(requestID: requestID, events: pair.stream)
    }

    func cancel(requestID: UUID) async {
        guard let active = activeStreams.removeValue(forKey: requestID) else {
            return
        }
        P8FProviderRequestCorrelationRecorder.shared
            .complete(
                active.correlationToken,
                outcome: .cancelled
            )
        active.continuation.finish(
            throwing: OllamaChatFailure(.requestCancelled)
        )
        await transport.cancel(requestID: requestID)
        emit(
            .chatCanceled,
            trace: active.trace,
            status: .skipped,
            reason: OllamaChatFailureCode.requestCancelled.rawValue,
            started: active.startedAt,
            metadata: ["model_hash": active.modelHash]
        )
    }

    func cancelAll() async {
        let requestIDs = Array(activeStreams.keys)
        for requestID in requestIDs {
            await cancel(requestID: requestID)
        }
    }

    func assessModel(
        _ profile: ModelProfile,
        timeoutSeconds: TimeInterval = OllamaChatProviderLimits.defaultTimeoutSeconds,
        trace: OllamaChatTraceContext = .init()
    ) async -> ModelCapabilityAssessment {
        let started = ProcessInfo.processInfo.systemUptime
        let modelHash = OllamaChatTracePrivacy.modelIdentifierHash(profile.modelIdentifier)
        emit(
            .modelAssessmentStarted,
            trace: trace,
            status: .started,
            reason: "model_assessment_started",
            metadata: [
                "assessment_version": ModelCapabilityAssessment.currentAssessmentVersion,
                "model_hash": modelHash,
            ]
        )

        var proven: Set<ModelCapability> = []
        var diagnostics: [ModelCapabilityDiagnostic] = []
        var assessmentWasCancelled = false
        let childTraces = (0..<5).map { _ in trace.child() }

        let ordinary = await ordinaryChatProbe(
            profile: profile,
            timeoutSeconds: timeoutSeconds,
            trace: childTraces[0]
        )
        proven.formUnion(ordinary.capabilities)
        diagnostics.append(contentsOf: ordinary.diagnostics)
        assessmentWasCancelled = ordinary.wasCancelled

        if !assessmentWasCancelled {
            let streaming = await streamingProbe(
                profile: profile,
                timeoutSeconds: timeoutSeconds,
                trace: childTraces[1]
            )
            proven.formUnion(streaming.capabilities)
            diagnostics.append(contentsOf: streaming.diagnostics)
            assessmentWasCancelled = streaming.wasCancelled
        }

        if !assessmentWasCancelled {
            let structured = await structuredOutputProbe(
                profile: profile,
                timeoutSeconds: timeoutSeconds,
                trace: childTraces[2]
            )
            proven.formUnion(structured.capabilities)
            diagnostics.append(contentsOf: structured.diagnostics)
            assessmentWasCancelled = structured.wasCancelled
        }

        if !assessmentWasCancelled {
            let tools = await toolContinuationProbe(
                profile: profile,
                timeoutSeconds: timeoutSeconds,
                trace: childTraces[3]
            )
            proven.formUnion(tools.capabilities)
            diagnostics.append(contentsOf: tools.diagnostics)
            assessmentWasCancelled = tools.wasCancelled
        }

        if !assessmentWasCancelled {
            let cancellation = await cancellationProbe(
                profile: profile,
                timeoutSeconds: timeoutSeconds,
                trace: childTraces[4]
            )
            proven.formUnion(cancellation.capabilities)
            diagnostics.append(contentsOf: cancellation.diagnostics)
            assessmentWasCancelled = cancellation.wasCancelled
        }

        assessmentWasCancelled = assessmentWasCancelled
            || Task.isCancelled

        // A cancelled assessment must not manufacture a context success after
        // its transport sequence has been drained.
        if !assessmentWasCancelled {
            if profile.contextPolicy.bestKnownUsableTokens != nil {
                proven.insert(.contextWindow)
                diagnostics.append(.init(
                    probe: .contextDeclaration,
                    status: .success,
                    reasonCode: "model_context_declared",
                    durationMilliseconds: 0
                ))
            } else {
                diagnostics.append(.init(
                    probe: .contextDeclaration,
                    status: .failed,
                    reasonCode: "model_context_undeclared",
                    durationMilliseconds: 0
                ))
            }
        }

        let missing = Set(ModelCapability.allCases).subtracting(proven)
        let assessment = ModelCapabilityAssessment(
            provider: profile.provider,
            providerVersion: profile.providerVersion,
            modelIdentifier: profile.modelIdentifier,
            modelDigest: profile.modelDigest,
            capabilitiesProven: proven,
            capabilitiesMissing: missing,
            contextPolicy: profile.contextPolicy,
            reasoningControl: profile.reasoningControl,
            assessedAt: now(),
            durationMilliseconds: elapsedMilliseconds(since: started),
            diagnostics: diagnostics
        )
        let required = Set(
            ModelCapabilityRequirement.agentLokiChat
                .filter { $0.level == .required }
                .map(\.capability)
        )
        let requiredMissing = required.subtracting(proven)
        emit(
            .modelAssessmentCompleted,
            trace: trace,
            status: assessmentWasCancelled
                ? .skipped
                : requiredMissing.isEmpty ? .success : .degraded,
            reason: assessmentWasCancelled
                ? OllamaChatFailureCode.requestCancelled.rawValue
                : requiredMissing.isEmpty
                    ? "model_assessment_ready"
                    : "model_assessment_requirements_missing",
            started: started,
            metadata: [
                "assessment_version": assessment.assessmentVersion,
                "capability_count": String(proven.count),
                "missing_count": String(requiredMissing.count),
                "model_hash": modelHash,
                "state": assessmentWasCancelled
                    ? "cancelled"
                    : requiredMissing.isEmpty
                        ? ModelReadiness.ready.rawValue
                        : ModelReadiness.partiallyCompatible.rawValue,
            ]
        )
        return assessment
    }

    private func consume(
        _ transportEvents: AsyncThrowingStream<OllamaChatTransportEvent, Error>,
        request: OllamaChatRequest,
        requestID: UUID,
        expectedURL: URL?
    ) async {
        var decoder = OllamaNDJSONLineDecoder()
        var responseStarted = false
        var done = false
        var ephemeralThinking = ""
        var thinkingBytes = 0
        var content = ""
        var outputBytes = 0
        var toolCalls: [OllamaChatToolCall] = []
        var seenToolCalls: Set<String> = []
        var doneReason: String?
        var durationMilliseconds: Int?
        var promptTokenCount: Int?
        var outputTokenCount: Int?
        var chunkCount = 0
        let allowedTools = Set(request.tools.map(\.name))

        do {
            for try await event in transportEvents {
                guard activeStreams[requestID] != nil else { return }
                switch event {
                case let .response(head):
                    try validateResponseHead(head, expectedURL: expectedURL)
                    guard !responseStarted else {
                        throw OllamaChatFailure(.invalidResponse)
                    }
                    responseStarted = true
                    activeStreams[requestID]?.continuation.yield(.responseStarted)
                case let .bytes(data):
                    guard responseStarted else {
                        throw OllamaChatFailure(.invalidResponse)
                    }
                    for line in try decoder.append(data) {
                        let parsed = try parseChunk(
                            line,
                            request: request,
                            allowedTools: allowedTools
                        )
                        try apply(
                            parsed,
                            request: request,
                            requestID: requestID,
                            ephemeralThinking: &ephemeralThinking,
                            thinkingBytes: &thinkingBytes,
                            content: &content,
                            outputBytes: &outputBytes,
                            toolCalls: &toolCalls,
                            seenToolCalls: &seenToolCalls,
                            done: &done,
                            doneReason: &doneReason,
                            durationMilliseconds: &durationMilliseconds,
                            promptTokenCount: &promptTokenCount,
                            outputTokenCount: &outputTokenCount,
                            chunkCount: &chunkCount
                        )
                        await Task.yield()
                        guard activeStreams[requestID] != nil else { return }
                    }
                }
            }

            for line in try decoder.finish() {
                let parsed = try parseChunk(
                    line,
                    request: request,
                    allowedTools: allowedTools
                )
                try apply(
                    parsed,
                    request: request,
                    requestID: requestID,
                    ephemeralThinking: &ephemeralThinking,
                    thinkingBytes: &thinkingBytes,
                    content: &content,
                    outputBytes: &outputBytes,
                    toolCalls: &toolCalls,
                    seenToolCalls: &seenToolCalls,
                    done: &done,
                    doneReason: &doneReason,
                    durationMilliseconds: &durationMilliseconds,
                    promptTokenCount: &promptTokenCount,
                    outputTokenCount: &outputTokenCount,
                    chunkCount: &chunkCount
                )
            }

            guard responseStarted,
                  done,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCalls.isEmpty
            else {
                throw OllamaChatFailure(.invalidResponse)
            }
            finishSuccess(
                requestID: requestID,
                completion: .init(
                    modelIdentifier: request.modelIdentifier,
                    content: content,
                    toolCalls: toolCalls,
                    doneReason: doneReason,
                    durationMilliseconds: durationMilliseconds,
                    promptTokenCount: promptTokenCount,
                    outputTokenCount: outputTokenCount,
                    chunkCount: chunkCount,
                    ephemeralThinking: ephemeralThinking
                )
            )
        } catch {
            finishFailure(requestID: requestID, error: error)
        }
    }

    private func apply(
        _ parsed: ParsedChunk,
        request: OllamaChatRequest,
        requestID: UUID,
        ephemeralThinking: inout String,
        thinkingBytes: inout Int,
        content: inout String,
        outputBytes: inout Int,
        toolCalls: inout [OllamaChatToolCall],
        seenToolCalls: inout Set<String>,
        done: inout Bool,
        doneReason: inout String?,
        durationMilliseconds: inout Int?,
        promptTokenCount: inout Int?,
        outputTokenCount: inout Int?,
        chunkCount: inout Int
    ) throws {
        guard !done else {
            throw OllamaChatFailure(.invalidResponse)
        }
        guard parsed.model == request.modelIdentifier else {
            throw OllamaChatFailure(.responseModelMismatch)
        }
        chunkCount += 1

        if !parsed.thinking.isEmpty {
            let bytes = parsed.thinking.lengthOfBytes(using: .utf8)
            guard thinkingBytes + bytes <= OllamaChatProviderLimits.maximumThinkingBytes else {
                throw OllamaChatFailure(.responseTooLarge)
            }
            thinkingBytes += bytes
            ephemeralThinking.append(parsed.thinking)
            activeStreams[requestID]?.continuation.yield(.thinkingDelta(parsed.thinking))
        }
        if !parsed.content.isEmpty {
            let bytes = parsed.content.lengthOfBytes(using: .utf8)
            guard outputBytes + bytes <= OllamaChatProviderLimits.maximumOutputBytes else {
                throw OllamaChatFailure(.responseTooLarge)
            }
            outputBytes += bytes
            content.append(parsed.content)
            activeStreams[requestID]?.continuation.yield(.contentDelta(parsed.content))
        }
        for toolCall in parsed.toolCalls {
            let key = "\(toolCall.name):\(OllamaChatTracePrivacy.modelIdentifierHash(String(decoding: toolCall.argumentsJSON, as: UTF8.self)))"
            guard seenToolCalls.insert(key).inserted else { continue }
            guard toolCalls.count < OllamaChatProviderLimits.maximumToolCallsPerResponse else {
                throw OllamaChatFailure(.invalidToolCall)
            }
            toolCalls.append(toolCall)
            activeStreams[requestID]?.continuation.yield(.toolCall(toolCall))
            if let active = activeStreams[requestID] {
                emit(
                    .chatToolRequested,
                    trace: active.trace.child(),
                    status: .success,
                    reason: "ollama_chat_tool_requested",
                    metadata: [
                        "model_hash": active.modelHash,
                        "tool_name": toolCall.name,
                    ]
                )
            }
        }
        if parsed.done {
            done = true
            doneReason = parsed.doneReason
            durationMilliseconds = parsed.durationMilliseconds
            promptTokenCount = parsed.promptTokenCount
            outputTokenCount = parsed.outputTokenCount
        }
    }

    private func finishSuccess(requestID: UUID, completion: OllamaChatCompletion) {
        guard let active = activeStreams.removeValue(forKey: requestID) else { return }
        P8FProviderRequestCorrelationRecorder.shared
            .complete(
                active.correlationToken,
                outcome: .succeeded
            )
        active.continuation.yield(.completed(completion))
        active.continuation.finish()
        emit(
            .chatCompleted,
            trace: active.trace,
            status: .success,
            reason: "ollama_chat_completed",
            started: active.startedAt,
            metadata: [
                "chunk_count": String(completion.chunkCount),
                "model_hash": active.modelHash,
            ]
        )
    }

    private func finishFailure(requestID: UUID, error: Error) {
        guard let active = activeStreams.removeValue(forKey: requestID) else { return }
        let failure = mapFailure(error)
        P8FProviderRequestCorrelationRecorder.shared
            .complete(
                active.correlationToken,
                outcome: failure.code
                    == .requestCancelled
                    ? .cancelled
                    : .failed
            )
        active.continuation.finish(throwing: failure)
        emit(
            failure.code == .requestCancelled ? .chatCanceled : .chatFailed,
            trace: active.trace,
            status: failure.code == .requestCancelled ? .skipped : .failed,
            reason: failure.reasonCode,
            started: active.startedAt,
            metadata: ["model_hash": active.modelHash]
        )
    }

    private func ordinaryChatProbe(
        profile: ModelProfile,
        timeoutSeconds: TimeInterval,
        trace: OllamaChatTraceContext
    ) async -> ProbeOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let request = OllamaChatRequest(
                modelIdentifier: profile.modelIdentifier,
                messages: [
                    .init(role: .system, content: "This is a synthetic capability probe. Reply exactly SYSTEM_OK."),
                    .init(role: .user, content: "Return the requested synthetic marker."),
                ],
                stream: false,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 32,
                reasoningControl: profile.reasoningControl
            )
            let result = try await collectAssessmentStream(
                request,
                trace: trace
            )
            try requireProbeNotTruncated(result.completion)
            let text = result.completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw OllamaChatFailure(.invalidResponse)
            }
            var capabilities: Set<ModelCapability> = [.chat]
            if text.uppercased().contains("SYSTEM_OK") {
                capabilities.insert(.systemInstructions)
            }
            return .init(
                capabilities: capabilities,
                diagnostics: [.init(
                    probe: .ordinaryChat,
                    status: .success,
                    reasonCode: capabilities.contains(.systemInstructions)
                        ? "model_ordinary_chat_and_system_succeeded"
                        : "model_ordinary_chat_succeeded",
                    durationMilliseconds: elapsedMilliseconds(since: started)
                )]
            )
        } catch {
            return failedProbe(.ordinaryChat, error: error, started: started)
        }
    }

    private func streamingProbe(
        profile: ModelProfile,
        timeoutSeconds: TimeInterval,
        trace: OllamaChatTraceContext
    ) async -> ProbeOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let request = OllamaChatRequest(
                modelIdentifier: profile.modelIdentifier,
                messages: [
                    .init(role: .user, content: "Synthetic probe: reply with the numbers one through eight, separated by spaces."),
                ],
                stream: true,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 64,
                reasoningControl: profile.reasoningControl
            )
            let result = try await collectAssessmentStream(
                request,
                trace: trace
            )
            try requireProbeNotTruncated(result.completion)
            guard result.responseStarted,
                  result.contentDeltaCount > 0,
                  !result.completion.content.isEmpty
            else {
                throw OllamaChatFailure(.invalidResponse)
            }
            return .init(
                capabilities: [.streaming],
                diagnostics: [.init(
                    probe: .streaming,
                    status: .success,
                    reasonCode: "model_streaming_succeeded",
                    durationMilliseconds: elapsedMilliseconds(since: started)
                )]
            )
        } catch {
            return failedProbe(.streaming, error: error, started: started)
        }
    }

    private func structuredOutputProbe(
        profile: ModelProfile,
        timeoutSeconds: TimeInterval,
        trace: OllamaChatTraceContext
    ) async -> ProbeOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let schema = try jsonData([
                "type": "object",
                "properties": [
                    "probe": [
                        "type": "string",
                        "const": "ok",
                    ],
                ],
                "required": ["probe"],
                "additionalProperties": false,
            ])
            let request = OllamaChatRequest(
                modelIdentifier: profile.modelIdentifier,
                messages: [
                    .init(role: .system, content: "Return only the requested synthetic JSON object."),
                    .init(role: .user, content: "Return a synthetic successful probe result."),
                ],
                outputJSONSchema: schema,
                stream: false,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 64,
                reasoningControl: profile.reasoningControl
            )
            let result = try await collectAssessmentStream(
                request,
                trace: trace
            )
            try requireProbeNotTruncated(result.completion)
            guard let data = result.completion.content.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.count == 1,
                  object["probe"] as? String == "ok"
            else {
                throw OllamaChatFailure(.structuredOutputInvalid)
            }
            return .init(
                capabilities: [.structuredOutput],
                diagnostics: [.init(
                    probe: .structuredJSON,
                    status: .success,
                    reasonCode: "model_structured_output_succeeded",
                    durationMilliseconds: elapsedMilliseconds(since: started)
                )]
            )
        } catch {
            return failedProbe(.structuredJSON, error: error, started: started)
        }
    }

    private func toolContinuationProbe(
        profile: ModelProfile,
        timeoutSeconds: TimeInterval,
        trace: OllamaChatTraceContext
    ) async -> ProbeOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        let toolName = "get_synthetic_probe_status"
        var toolCallWasProven = false
        var toolCallDuration = 0
        do {
            let parameters = try jsonData([
                "type": "object",
                "properties": [
                    "probe": [
                        "type": "string",
                        "enum": ["capability"],
                    ],
                ],
                "required": ["probe"],
                "additionalProperties": false,
            ])
            let tool = OllamaChatToolDefinition(
                name: toolName,
                description: "Returns one synthetic read-only capability-probe status.",
                parametersJSONSchema: parameters
            )
            let initialMessages: [OllamaChatMessage] = [
                .init(
                    role: .system,
                    content: "This is a synthetic assessment. Use only the supplied read-only tool."
                ),
                .init(
                    role: .user,
                    content: "Use the synthetic status tool with probe set to capability."
                ),
            ]
            let first = try await collectAssessmentStream(.init(
                modelIdentifier: profile.modelIdentifier,
                messages: initialMessages,
                tools: [tool],
                stream: false,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 128,
                reasoningControl: profile.reasoningControl
            ), trace: trace)
            try requireProbeNotTruncated(first.completion)
            guard first.completion.toolCalls.count == 1,
                  let call = first.completion.toolCalls.first,
                  call.name == toolName,
                  let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
                  arguments.count == 1,
                  arguments["probe"] as? String == "capability"
            else {
                throw OllamaChatFailure(.invalidToolCall)
            }
            toolCallWasProven = true
            toolCallDuration = elapsedMilliseconds(since: started)

            let syntheticResult = #"{"status":"ok","synthetic":true}"#
            let continuationMessages = initialMessages + [
                .init(role: .assistant, content: "", toolCalls: [call]),
                .init(role: .tool, content: syntheticResult, toolName: toolName),
            ]
            let continued = try await collectAssessmentStream(.init(
                modelIdentifier: profile.modelIdentifier,
                messages: continuationMessages,
                tools: [tool],
                stream: false,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 128,
                reasoningControl: profile.reasoningControl
            ), trace: trace.child())
            try requireProbeNotTruncated(continued.completion)
            guard continued.completion.toolCalls.isEmpty,
                  !continued.completion.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw OllamaChatFailure(.invalidResponse)
            }
            return .init(
                capabilities: [.toolCalling],
                diagnostics: [
                    .init(
                        probe: .syntheticToolCall,
                        status: .success,
                        reasonCode: "model_synthetic_tool_call_succeeded",
                        durationMilliseconds: toolCallDuration
                    ),
                    .init(
                        probe: .toolResultContinuation,
                        status: .success,
                        reasonCode: "model_tool_continuation_succeeded",
                        durationMilliseconds: elapsedMilliseconds(since: started)
                    ),
                ]
            )
        } catch {
            let failure = mapFailure(error)
            if failure.code == .requestCancelled {
                return .init(
                    capabilities: [],
                    diagnostics: [
                        .init(
                            probe: .syntheticToolCall,
                            status: toolCallWasProven
                                ? .success
                                : .cancelled,
                            reasonCode: toolCallWasProven
                                ? "model_synthetic_tool_call_succeeded"
                                : failure.reasonCode,
                            durationMilliseconds: toolCallWasProven
                                ? toolCallDuration
                                : elapsedMilliseconds(since: started)
                        ),
                        .init(
                            probe: .toolResultContinuation,
                            status: toolCallWasProven
                                ? .cancelled
                                : .skipped,
                            reasonCode: toolCallWasProven
                                ? failure.reasonCode
                                : "model_tool_continuation_not_reached",
                            durationMilliseconds: elapsedMilliseconds(since: started)
                        ),
                    ]
                )
            }
            return .init(
                capabilities: [],
                diagnostics: [
                    .init(
                        probe: .syntheticToolCall,
                        status: .failed,
                        reasonCode: failure.reasonCode,
                        durationMilliseconds: elapsedMilliseconds(since: started)
                    ),
                    .init(
                        probe: .toolResultContinuation,
                        status: .skipped,
                        reasonCode: "model_tool_continuation_not_reached",
                        durationMilliseconds: elapsedMilliseconds(since: started)
                    ),
                ]
            )
        }
    }

    private func cancellationProbe(
        profile: ModelProfile,
        timeoutSeconds: TimeInterval,
        trace: OllamaChatTraceContext
    ) async -> ProbeOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try requireAssessmentTransportAdmission()
            let handle = try streamChat(.init(
                modelIdentifier: profile.modelIdentifier,
                messages: [
                    .init(
                        role: .user,
                        content: "Synthetic cancellation probe: count upward slowly from one and do not stop before two hundred."
                    ),
                ],
                stream: true,
                timeoutSeconds: timeoutSeconds,
                maximumOutputTokens: 512,
                reasoningControl: profile.reasoningControl
            ), trace: trace)
            var receivedContent = false
            var receivedCompletion = false
            do {
                for try await event in handle.events {
                    switch event {
                    case .contentDelta:
                        if !receivedContent {
                            receivedContent = true
                            await cancel(requestID: handle.requestID)
                        }
                    case .completed:
                        receivedCompletion = true
                    case .responseStarted, .thinkingDelta, .toolCall:
                        break
                    }
                }
            } catch let failure as OllamaChatFailure where failure.code == .requestCancelled {
                // Expected client-side terminal state.
            }
            guard receivedContent, !receivedCompletion else {
                throw OllamaChatFailure(.requestCancelled)
            }
            return .init(
                capabilities: [.cancellation],
                diagnostics: [.init(
                    probe: .cancellation,
                    status: .success,
                    reasonCode: "model_cancellation_succeeded",
                    durationMilliseconds: elapsedMilliseconds(since: started)
                )]
            )
        } catch {
            return failedProbe(.cancellation, error: error, started: started)
        }
    }

    private func collect(_ handle: OllamaChatStreamHandle) async throws -> ProbeCollection {
        var responseStarted = false
        var contentDeltaCount = 0
        var completion: OllamaChatCompletion?
        for try await event in handle.events {
            switch event {
            case .responseStarted:
                responseStarted = true
            case .thinkingDelta:
                break
            case .contentDelta:
                contentDeltaCount += 1
            case .toolCall:
                break
            case let .completed(value):
                completion = value
            }
        }
        guard let completion else {
            throw OllamaChatFailure(.invalidResponse)
        }
        return .init(
            completion: completion,
            responseStarted: responseStarted,
            contentDeltaCount: contentDeltaCount
        )
    }

    private func collectAssessmentStream(
        _ request: OllamaChatRequest,
        trace: OllamaChatTraceContext
    ) async throws -> ProbeCollection {
        try requireAssessmentTransportAdmission()
        return try await collect(streamChat(request, trace: trace))
    }

    private func requireAssessmentTransportAdmission() throws {
        guard !Task.isCancelled else {
            throw OllamaChatFailure(.requestCancelled)
        }
    }

    private func failedProbe(
        _ probe: ModelCapabilityProbe,
        error: Error,
        started: TimeInterval
    ) -> ProbeOutcome {
        let failure = mapFailure(error)
        return .init(
            capabilities: [],
            diagnostics: [.init(
                probe: probe,
                status: failure.code == .requestCancelled ? .cancelled : .failed,
                reasonCode: failure.reasonCode,
                durationMilliseconds: elapsedMilliseconds(since: started)
            )]
        )
    }

    private func requireProbeNotTruncated(_ completion: OllamaChatCompletion) throws {
        guard completion.doneReason?.lowercased() != "length" else {
            throw OllamaChatFailure(.outputTruncated)
        }
    }

    private func collectResponse(
        request: URLRequest,
        requestID: UUID,
        limit: Int
    ) async throws -> Data {
        let events = transport.stream(for: request, requestID: requestID, responseLimit: limit)
        let transport = self.transport
        return try await withTaskCancellationHandler {
            var responseStarted = false
            var data = Data()
            for try await event in events {
                switch event {
                case let .response(head):
                    try validateResponseHead(head, expectedURL: request.url)
                    guard !responseStarted else {
                        throw OllamaChatFailure(.invalidResponse)
                    }
                    responseStarted = true
                case let .bytes(chunk):
                    guard responseStarted, data.count + chunk.count <= limit else {
                        throw OllamaChatFailure(.responseTooLarge)
                    }
                    data.append(chunk)
                }
            }
            guard responseStarted, !data.isEmpty else {
                throw OllamaChatFailure(.invalidResponse)
            }
            return data
        } onCancel: {
            Task { await transport.cancel(requestID: requestID) }
        }
    }

    private func decodeProfile(
        _ data: Data,
        modelIdentifier: String,
        displayName: String?,
        modelDigest: String?,
        providerVersion: String?
    ) throws -> ModelProfile {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaChatFailure(.invalidResponse)
        }
        let declared = Set((object["capabilities"] as? [String] ?? []).map { $0.lowercased() })
        var estimated: Set<ModelCapability> = []
        if declared.contains("completion") { estimated.insert(.chat) }
        if declared.contains("tools") { estimated.insert(.toolCalling) }
        if declared.contains("thinking") { estimated.insert(.reasoning) }
        if declared.contains("vision") { estimated.insert(.vision) }
        if declared.contains("embedding") { estimated.insert(.embedding) }

        let modelInfo = object["model_info"] as? [String: Any] ?? [:]
        let architecture = modelInfo["general.architecture"] as? String
        let declaredContext = declaredContextTokens(
            modelInfo: modelInfo,
            architecture: architecture
        )
        if declaredContext != nil {
            estimated.insert(.contextWindow)
        }
        return .init(
            provider: "ollama",
            providerVersion: boundedOptional(providerVersion),
            modelIdentifier: modelIdentifier,
            displayName: boundedOptional(displayName) ?? modelIdentifier,
            modelDigest: boundedOptional(modelDigest),
            locallyInstalled: true,
            estimatedCapabilities: estimated,
            contextPolicy: .init(declaredContextTokens: declaredContext),
            reasoningControl: {
                guard declared.contains("thinking") else { return .disabled }
                return architecture?.lowercased() == "gptoss"
                    ? .ollamaLow
                    : .ollamaBoolean
            }(),
            observedAt: now()
        )
    }

    private func declaredContextTokens(
        modelInfo: [String: Any],
        architecture: String?
    ) -> Int? {
        if let architecture,
           let exact = integer(modelInfo["\(architecture).context_length"]),
           exact > 0,
           exact <= ModelContextPolicy.maximumAcceptedDeclarationTokens {
            return exact
        }
        let candidates = modelInfo.compactMap { key, value -> Int? in
            let lowercased = key.lowercased()
            guard lowercased.hasSuffix(".context_length"),
                  !lowercased.contains("vision"),
                  !lowercased.contains("original_context_length"),
                  let value = integer(value),
                  value > 0,
                  value <= ModelContextPolicy.maximumAcceptedDeclarationTokens
            else {
                return nil
            }
            return value
        }
        return candidates.max()
    }

    private func parseChunk(
        _ data: Data,
        request: OllamaChatRequest,
        allowedTools: Set<String>
    ) throws -> ParsedChunk {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaChatFailure(.invalidResponse)
        }
        if object["error"] as? String != nil {
            throw OllamaChatFailure(.httpFailure)
        }
        guard let model = object["model"] as? String,
              let done = object["done"] as? Bool
        else {
            throw OllamaChatFailure(.invalidResponse)
        }
        let message = object["message"] as? [String: Any] ?? [:]
        let thinking = message["thinking"] as? String ?? ""
        let content = message["content"] as? String ?? ""
        let rawToolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        guard rawToolCalls.count <= OllamaChatProviderLimits.maximumToolCallsPerResponse else {
            throw OllamaChatFailure(.invalidToolCall)
        }
        let toolCalls = try rawToolCalls.enumerated().map { offset, raw -> OllamaChatToolCall in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  allowedTools.contains(name),
                  isValidToolName(name),
                  let arguments = function["arguments"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(arguments)
            else {
                throw OllamaChatFailure(.invalidToolCall)
            }
            let argumentData = try JSONSerialization.data(
                withJSONObject: arguments,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard argumentData.count <= OllamaChatProviderLimits.maximumToolArgumentsBytes else {
                throw OllamaChatFailure(.invalidToolCall)
            }
            let rawID = raw["id"] as? String
            let id = boundedOptional(rawID)
                ?? "tool-\(offset)-\(UUID().uuidString.lowercased())"
            return .init(id: id, name: name, argumentsJSON: argumentData)
        }
        return .init(
            model: model,
            thinking: thinking,
            content: content,
            toolCalls: toolCalls,
            done: done,
            doneReason: boundedOptional(object["done_reason"] as? String),
            durationMilliseconds: boundedDuration(object["total_duration"]),
            promptTokenCount: boundedCount(object["prompt_eval_count"]),
            outputTokenCount: boundedCount(object["eval_count"])
        )
    }

    private func validate(_ request: OllamaChatRequest) throws {
        try validateIdentifier(request.modelIdentifier)
        guard OllamaChatProviderLimits.contains(timeout: request.timeoutSeconds),
              !request.messages.isEmpty,
              request.messages.count <= OllamaChatProviderLimits.maximumMessageCount,
              request.tools.count <= OllamaChatProviderLimits.maximumToolCount,
              request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= OllamaChatProviderLimits.maximumOutputTokens
        else {
            throw OllamaChatFailure(.invalidRequest)
        }
        if let context = request.configuredContextTokens {
            guard context > 0,
                  context <= ModelContextPolicy.maximumAcceptedDeclarationTokens
            else {
                throw OllamaChatFailure(.invalidRequest)
            }
        }

        var combinedBytes = 0
        var combinedImageBytes = 0
        for message in request.messages {
            let bytes = message.content.lengthOfBytes(using: .utf8)
            combinedBytes += bytes
            let thinkingBytes = message.ephemeralThinking?.lengthOfBytes(using: .utf8) ?? 0
            guard message.images.count <= OllamaChatProviderLimits.maximumImageCount,
                  thinkingBytes <= OllamaChatProviderLimits.maximumThinkingBytes
            else {
                throw OllamaChatFailure(.requestTooLarge)
            }
            for image in message.images {
                guard !image.isEmpty,
                      image.count <= OllamaChatProviderLimits.maximumImageBytes
                else {
                    throw OllamaChatFailure(.requestTooLarge)
                }
                combinedImageBytes += image.count
            }
            guard bytes <= OllamaChatProviderLimits.maximumMessageContentBytes,
                  combinedBytes <= OllamaChatProviderLimits.maximumCombinedMessageBytes,
                  combinedImageBytes <= OllamaChatProviderLimits.maximumCombinedImageBytes,
                  message.toolCalls.count <= OllamaChatProviderLimits.maximumToolCallsPerResponse
            else {
                throw OllamaChatFailure(.requestTooLarge)
            }
            switch message.role {
            case .system:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      message.toolCalls.isEmpty,
                      message.toolName == nil,
                      message.images.isEmpty,
                      message.ephemeralThinking == nil
                else {
                    throw OllamaChatFailure(.invalidRequest)
                }
            case .user:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      message.toolCalls.isEmpty,
                      message.toolName == nil,
                      message.ephemeralThinking == nil
                else {
                    throw OllamaChatFailure(.invalidRequest)
                }
            case .assistant:
                guard !message.content.isEmpty || !message.toolCalls.isEmpty,
                      message.toolName == nil,
                      message.images.isEmpty
                else {
                    throw OllamaChatFailure(.invalidRequest)
                }
            case .tool:
                guard !message.content.isEmpty,
                      message.toolCalls.isEmpty,
                      let toolName = message.toolName,
                      isValidToolName(toolName),
                      message.images.isEmpty,
                      message.ephemeralThinking == nil
                else {
                    throw OllamaChatFailure(.invalidRequest)
                }
            }
        }

        let toolNames = request.tools.map(\.name)
        guard Set(toolNames).count == toolNames.count else {
            throw OllamaChatFailure(.invalidRequest)
        }
        for tool in request.tools {
            guard isValidToolName(tool.name),
                  !tool.description.isEmpty,
                  tool.description.count <= OllamaChatProviderLimits.maximumToolDescriptionCharacters
            else {
                throw OllamaChatFailure(.invalidRequest)
            }
            _ = try jsonObject(from: tool.parametersJSONSchema)
        }
        let allowedTools = Set(toolNames)
        for message in request.messages {
            for call in message.toolCalls {
                guard allowedTools.contains(call.name),
                      isValidToolName(call.name),
                      call.argumentsJSON.count <= OllamaChatProviderLimits.maximumToolArgumentsBytes
                else {
                    throw OllamaChatFailure(.invalidRequest)
                }
                _ = try jsonObject(from: call.argumentsJSON)
            }
            if message.role == .tool {
                guard let toolName = message.toolName, allowedTools.contains(toolName) else {
                    throw OllamaChatFailure(.invalidRequest)
                }
            }
        }
        if let schema = request.outputJSONSchema {
            _ = try jsonObject(from: schema)
        }
    }

    private func makeChatBody(_ request: OllamaChatRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.modelIdentifier,
            "messages": try request.messages.map(messageObject),
            "stream": request.stream,
        ]
        switch request.reasoningControl {
        case .disabled:
            body["think"] = false
        case .ollamaBoolean:
            body["think"] = true
        case .ollamaLow:
            body["think"] = "low"
        case .ollamaMedium:
            body["think"] = "medium"
        case .ollamaHigh:
            body["think"] = "high"
        }
        var options: [String: Any] = [
            "temperature": 0,
            "num_predict": request.maximumOutputTokens,
        ]
        if let configuredContextTokens = request.configuredContextTokens {
            options["num_ctx"] = configuredContextTokens
        }
        body["options"] = options
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": try jsonObject(from: tool.parametersJSONSchema),
                    ],
                ] as [String: Any]
            }
        }
        if let schema = request.outputJSONSchema {
            body["format"] = try jsonObject(from: schema)
        }
        return try jsonData(body)
    }

    private func messageObject(_ message: OllamaChatMessage) throws -> [String: Any] {
        var object: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content,
        ]
        if !message.images.isEmpty {
            object["images"] = message.images.map { $0.base64EncodedString() }
        }
        if let thinking = message.ephemeralThinking, !thinking.isEmpty {
            object["thinking"] = thinking
        }
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = try message.toolCalls.map { call in
                [
                    "id": call.id,
                    "function": [
                        "name": call.name,
                        "arguments": try jsonObject(from: call.argumentsJSON),
                    ],
                ] as [String: Any]
            }
        }
        if let toolName = message.toolName {
            object["tool_name"] = toolName
        }
        return object
    }

    private func makeRequest(
        path: String,
        body: Data,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard OllamaChatProviderLimits.contains(timeout: timeout),
              !body.isEmpty,
              body.count <= OllamaChatProviderLimits.maximumRequestBytes
        else {
            throw OllamaChatFailure(.requestTooLarge)
        }
        var request = URLRequest(
            url: try OllamaLoopbackEndpointPolicy.url(path: path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try OllamaLoopbackEndpointPolicy.validate(request)
        return request
    }

    private func validateResponseHead(
        _ head: OllamaChatTransportResponseHead,
        expectedURL: URL?
    ) throws {
        guard let expectedURL, head.finalURL == expectedURL else {
            throw OllamaChatFailure(.redirectRejected, httpStatus: head.statusCode)
        }
        switch head.statusCode {
        case 200:
            return
        case 300..<400:
            throw OllamaChatFailure(.redirectRejected, httpStatus: head.statusCode)
        case 401, 407:
            throw OllamaChatFailure(.authenticationRejected, httpStatus: head.statusCode)
        default:
            throw OllamaChatFailure(.httpFailure, httpStatus: head.statusCode)
        }
    }

    private func validateIdentifier(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.count <= OllamaChatProviderLimits.maximumIdentifierCharacters,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw OllamaChatFailure(.invalidRequest)
        }
        guard !OllamaModelLocalityPolicy.isCloudReference(value) else {
            throw OllamaChatFailure(.cloudModelRejected)
        }
    }

    private func isValidToolName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
    }

    private func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OllamaChatFailure(.invalidRequest)
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard data.count <= OllamaChatProviderLimits.maximumToolArgumentsBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object)
        else {
            throw OllamaChatFailure(.invalidRequest)
        }
        return object
    }

    private func boundedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(scalars))
            .prefix(OllamaChatProviderLimits.maximumIdentifierCharacters)
        return bounded.isEmpty ? nil : String(bounded)
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func boundedCount(_ value: Any?) -> Int? {
        guard let count = integer(value), count >= 0 else { return nil }
        return min(count, 1_000_000)
    }

    private func boundedDuration(_ value: Any?) -> Int? {
        guard let nanoseconds = value as? NSNumber, nanoseconds.int64Value >= 0 else {
            return nil
        }
        return Int(min(nanoseconds.int64Value / 1_000_000, 600_000))
    }

    private func mapFailure(_ error: Error) -> OllamaChatFailure {
        if let failure = error as? OllamaChatFailure { return failure }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .init(.requestCancelled)
            case .timedOut:
                return .init(.requestTimedOut)
            default:
                return .init(.serviceUnavailable)
            }
        }
        if error is CancellationError {
            return .init(.requestCancelled)
        }
        return .init(.invalidResponse)
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Int {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
        return min(Int(elapsed * 1_000), 600_000)
    }

    private func emit(
        _ event: OllamaChatTraceEventName,
        trace: OllamaChatTraceContext,
        status: OllamaChatTraceStatus,
        reason: String,
        started: TimeInterval? = nil,
        metadata: [String: String] = [:]
    ) {
        traceSink(.init(
            ts: now(),
            event: event,
            context: trace,
            component: "native_ollama_chat_provider",
            status: status,
            reasonCode: reason,
            durationMilliseconds: started.map(elapsedMilliseconds),
            metadata: metadata
        ))
    }
}
