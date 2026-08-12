import Foundation

struct OllamaProviderLimits: Hashable, Sendable {
    static let minimumTimeoutSeconds: TimeInterval = 5
    static let maximumTimeoutSeconds: TimeInterval = 120
    static let defaultTimeoutSeconds: TimeInterval = 30
    static let maximumResponseBytes = 512 * 1_024
    static let maximumPromptBytes = 16 * 1_024
    static let maximumRequestBytes = 64 * 1_024
    static let maximumSelectedItems = 16
    static let maximumDiscoveredModels = 256
    static let maximumSummaryCharacters = 600
    static let maximumIdentifierCharacters = 256
    static let maximumTitleCharacters = 400
    static let maximumSourceNameCharacters = 240
    static let maximumEvidenceCharacters = 1_500
    static let maximumGeneratedItemSummaries = 16
    static let maximumPredictedTokens = 1_024

    static func contains(timeout: TimeInterval) -> Bool {
        timeout.isFinite && timeout >= minimumTimeoutSeconds && timeout <= maximumTimeoutSeconds
    }
}

enum OllamaModelLocalityPolicy {
    static func isCloudReference(_ value: String) -> Bool {
        value.lowercased().contains("cloud")
    }
}

enum OllamaRuntimeState: String, Codable, CaseIterable, Sendable {
    case disabled
    case notInstalled
    case notRunning
    case available
    case connected
    case noModels
    case modelSelected
    case generating
    case degraded
    case error
}

enum OllamaFailureCode: String, Codable, CaseIterable, Sendable {
    case providerDisabled = "ollama_provider_disabled"
    case invalidEndpoint = "ollama_invalid_endpoint"
    case redirectRejected = "ollama_redirect_rejected"
    case authenticationRejected = "ollama_authentication_rejected"
    case timeoutOutOfRange = "ollama_timeout_out_of_range"
    case requestTooLarge = "ollama_request_too_large"
    case responseTooLarge = "ollama_response_too_large"
    case serviceUnavailable = "ollama_service_unavailable"
    case requestTimedOut = "ollama_request_timed_out"
    case requestCancelled = "ollama_request_cancelled"
    case httpFailure = "ollama_http_failure"
    case invalidResponse = "ollama_invalid_response"
    case modelListTooLarge = "ollama_model_list_too_large"
    case noModels = "ollama_no_models"
    case modelNotDiscovered = "ollama_model_not_discovered"
    case selectedModelDisappeared = "ollama_selected_model_disappeared"
    case cloudModelRejected = "ollama_cloud_model_rejected"
    case generationAlreadyInProgress = "ollama_generation_already_in_progress"
    case evidenceInvalid = "ollama_evidence_invalid"
    case evidenceTooLarge = "ollama_evidence_too_large"
    case outputSchemaInvalid = "ollama_output_schema_invalid"
    case outputBriefMismatch = "ollama_output_brief_mismatch"
    case outputUnknownSection = "ollama_output_unknown_section"
    case outputUnknownItem = "ollama_output_unknown_item"
    case outputDuplicateIdentifier = "ollama_output_duplicate_identifier"
    case outputTooLong = "ollama_output_too_long"
    case outputInventedURL = "ollama_output_invented_url"
    case responseModelMismatch = "ollama_response_model_mismatch"
}

struct OllamaFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: OllamaFailureCode
    let httpStatus: Int?

    init(_ code: OllamaFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .providerDisabled: "Local Ollama summaries are disabled. The deterministic brief remains available."
        case .invalidEndpoint: "The request did not match the fixed numeric loopback Ollama endpoint."
        case .redirectRejected: "Ollama attempted a redirect. Redirects are not permitted."
        case .authenticationRejected: "Ollama requested credentials. Credentialed requests are not permitted."
        case .timeoutOutOfRange: "The Ollama timeout must be between 5 and 120 seconds."
        case .requestTooLarge: "The bounded Ollama request was too large."
        case .responseTooLarge: "The Ollama response exceeded the 512 KiB limit."
        case .serviceUnavailable: "The local Ollama service is unavailable or not running."
        case .requestTimedOut: "The local Ollama request timed out."
        case .requestCancelled: "The local Ollama request was cancelled."
        case .httpFailure: "The local Ollama service returned an unsuccessful response."
        case .invalidResponse: "The local Ollama service returned an invalid response."
        case .modelListTooLarge: "The installed-model response exceeded the bounded model count."
        case .noModels: "No eligible local Ollama models were discovered."
        case .modelNotDiscovered: "Select a model from the most recently discovered local models."
        case .selectedModelDisappeared: "The selected local Ollama model is no longer installed."
        case .cloudModelRejected: "Cloud model references are not permitted. Select an installed local model."
        case .generationAlreadyInProgress: "A local summary generation is already in progress."
        case .evidenceInvalid: "The selected briefing evidence is invalid or incomplete."
        case .evidenceTooLarge: "The selected briefing evidence exceeded the bounded prompt limits."
        case .outputSchemaInvalid: "The local model output did not match the required summary schema."
        case .outputBriefMismatch: "The local model output referred to a different deterministic brief."
        case .outputUnknownSection: "The local model output referred to an unknown brief section."
        case .outputUnknownItem: "The local model output referred to an unknown evidence item."
        case .outputDuplicateIdentifier: "The local model output repeated a section or item identifier."
        case .outputTooLong: "The local model output exceeded a summary length limit."
        case .outputInventedURL: "The local model output included a URL, which generated summaries may not supply."
        case .responseModelMismatch: "The local Ollama response did not match the explicitly selected model."
        }
    }
}

struct OllamaVersionInfo: Codable, Hashable, Sendable {
    let version: String
    let checkedAt: Date
}

struct OllamaModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let modifiedAt: String?
    let sizeBytes: Int64?
    let digest: String?
    let format: String?
    let family: String?
    let families: [String]
    let parameterSize: String?
    let quantizationLevel: String?
}

struct OllamaModelCatalog: Codable, Hashable, Sendable {
    let revision: Int
    let discoveredAt: Date
    let models: [OllamaModelDescriptor]
    let excludedCloudModelCount: Int
}

struct OllamaModelSelection: Codable, Hashable, Sendable {
    let model: OllamaModelDescriptor
    let catalogRevision: Int
    let selectedAt: Date
}

struct OllamaProviderStatusSnapshot: Codable, Hashable, Sendable {
    let state: OllamaRuntimeState
    let checkedAt: Date?
    let lastSuccessfulCheckAt: Date?
    let discoveredModelCount: Int
    let selectedModelID: String?
    let lastFailureCode: OllamaFailureCode?

    init(
        state: OllamaRuntimeState,
        checkedAt: Date?,
        lastSuccessfulCheckAt: Date? = nil,
        discoveredModelCount: Int,
        selectedModelID: String?,
        lastFailureCode: OllamaFailureCode?
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.discoveredModelCount = discoveredModelCount
        self.selectedModelID = selectedModelID
        self.lastFailureCode = lastFailureCode
    }
}

struct OllamaEvidenceItem: Codable, Hashable, Sendable {
    let id: String
    let sectionID: String
    let title: String
    let evidenceText: String
    let sourceName: String
    let sourceURL: URL?
    let publishedAt: Date?
}

struct OllamaGenerationInput: Codable, Hashable, Sendable {
    let deterministicBriefID: String
    let allowedSectionIDs: [String]
    let selectedItems: [OllamaEvidenceItem]
    let includeItemSummaries: Bool
    let timeoutSeconds: TimeInterval

    init(
        deterministicBriefID: String,
        allowedSectionIDs: [String],
        selectedItems: [OllamaEvidenceItem],
        includeItemSummaries: Bool = false,
        timeoutSeconds: TimeInterval = OllamaProviderLimits.defaultTimeoutSeconds
    ) {
        self.deterministicBriefID = deterministicBriefID
        self.allowedSectionIDs = allowedSectionIDs
        self.selectedItems = selectedItems
        self.includeItemSummaries = includeItemSummaries
        self.timeoutSeconds = timeoutSeconds
    }
}

struct OllamaSectionSummary: Codable, Hashable, Sendable {
    let sectionID: String
    let summary: String
}

struct OllamaItemSummary: Codable, Hashable, Sendable {
    let itemID: String
    let sectionID: String
    let summary: String
}

struct OllamaValidatedSummary: Codable, Hashable, Sendable {
    let schemaVersion: String
    let deterministicBriefID: String
    let overallSummary: String
    let sectionSummaries: [OllamaSectionSummary]
    let itemSummaries: [OllamaItemSummary]
}

enum OllamaEndpointClassification: String, Codable, Sendable {
    case numericIPv4Loopback = "numeric_ipv4_loopback"
}

enum OllamaGenerationCompletionStatus: String, Codable, Sendable {
    case success
    case fallback
    case cancelled
}

enum OllamaGenerationFallbackStatus: String, Codable, Sendable {
    case notUsed = "not_used"
    case deterministicBriefPreserved = "deterministic_brief_preserved"
}

enum OllamaGenerationValidationResult: String, Codable, Sendable {
    case valid
    case providerUnavailable = "provider_unavailable"
    case rejected
    case cancelled
}

struct OllamaGenerationProvenance: Codable, Hashable, Sendable {
    let providerKind: String
    let selectedModelName: String?
    let endpointClassification: OllamaEndpointClassification
    let promptTemplateVersion: String
    let schemaVersion: String
    let generatedAt: Date
    let sourceItemIdentifiers: [String]
    let deterministicBriefIdentifier: String
    let completionStatus: OllamaGenerationCompletionStatus
    let fallbackStatus: OllamaGenerationFallbackStatus
    let durationMilliseconds: Int?
    let promptTokenCount: Int?
    let outputTokenCount: Int?
    let validationResult: OllamaGenerationValidationResult
    let failureReasonCode: String?
}

struct OllamaGenerationResult: Codable, Hashable, Sendable {
    let summary: OllamaValidatedSummary
    let provenance: OllamaGenerationProvenance
}

struct OllamaGenerationFallback: Codable, Hashable, Sendable {
    let failure: OllamaFailure
    let provenance: OllamaGenerationProvenance
}

enum OllamaGenerationOutcome: Codable, Hashable, Sendable {
    case generated(OllamaGenerationResult)
    case fallback(OllamaGenerationFallback)
}

struct OllamaTraceContext: Codable, Hashable, Sendable {
    let traceID: String
    let spanID: String
    let parentSpanID: String?

    init(
        traceID: String = UUID().uuidString.lowercased(),
        spanID: String = UUID().uuidString.lowercased(),
        parentSpanID: String? = nil
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}

enum OllamaTraceStatus: String, Codable, Sendable {
    case started
    case success
    case degraded
    case failed
    case skipped
}

enum OllamaTraceEventName: String, Codable, Sendable {
    case networkRequest = "ollama.network_request"
    case healthCheck = "ollama.health_check"
    case modelDiscovery = "ollama.model_discovery"
    case modelSelection = "ollama.model_selection"
    case generation = "ollama.generation"
    case outputValidation = "ollama.output_validation"
    case cancellation = "ollama.cancellation"
}

struct OllamaTraceEvent: Codable, Sendable {
    let event: OllamaTraceEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: String
    let status: OllamaTraceStatus
    let reasonCode: String
    let durationMilliseconds: Int?
    let metadata: [String: String]
}

struct OllamaTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
}

protocol OllamaTransporting: Sendable {
    func data(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) async throws -> OllamaTransportResponse

    func cancel(requestID: UUID) async
}
