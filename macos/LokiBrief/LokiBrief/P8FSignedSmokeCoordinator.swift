import AppKit
import Foundation
import Security

enum P8FSignedSmokeCoordinatorFailure:
    String,
    Error,
    Equatable,
    Sendable
{
    case applicationIdentityUnavailable =
        "p8f_smoke_application_identity_unavailable"
    case executableIdentityUnavailable =
        "p8f_smoke_executable_identity_unavailable"
    case executableIdentityMismatch =
        "p8f_smoke_executable_identity_mismatch"
    case codeIdentityUnavailable =
        "p8f_smoke_code_identity_unavailable"
    case priorTerminalReceipt =
        "p8f_smoke_prior_terminal_receipt"
    case runIdentityMismatch =
        "p8f_smoke_run_identity_mismatch"
    case fixtureMismatch =
        "p8f_smoke_fixture_mismatch"
    case prerequisiteMissing =
        "p8f_smoke_prerequisite_missing"
    case modelUnavailable =
        "p8f_smoke_model_unavailable"
    case modelDigestMismatch =
        "p8f_smoke_model_digest_mismatch"
    case modelAssessmentFailed =
        "p8f_smoke_model_assessment_failed"
    case modelRoleFailed =
        "p8f_smoke_model_role_failed"
    case semanticBuildFailed =
        "p8f_smoke_semantic_build_failed"
    case semanticCountMismatch =
        "p8f_smoke_semantic_count_mismatch"
    case atomicPublicationFailed =
        "p8f_smoke_atomic_publication_failed"
    case searchFailed =
        "p8f_smoke_search_failed"
    case hydrationFailed =
        "p8f_smoke_hydration_failed"
    case privacyFailed =
        "p8f_smoke_privacy_failed"
    case cleanupFailed =
        "p8f_smoke_cleanup_failed"
    case receiptFailed =
        "p8f_smoke_receipt_failed"
}

struct P8FSignedSmokeBootstrap: Sendable {
    let admission: P8FSignedSmokeAdmission
    let applicationIdentity:
        P8FSignedSmokeReceiptApplicationIdentity

    var isolatedRoot: URL {
        admission.storagePlan.rootURL!
    }

    /// The sole production bootstrap route. All authority-bearing inputs are
    /// derived by the admission resolver from the current process.
    static func resolveIfRequested(
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeBootstrap? {
        guard P8FSignedSmokeAdmissionResolver.hasControlIntent(
            arguments: CommandLine.arguments
        ) else {
            return nil
        }
        let admission =
            try P8FSignedSmokeAdmissionResolver
                .resolveProcessAdmission(
                    fileManager: fileManager
                )
        let receiptIdentity =
            try P8FSignedSmokeRuntimeIdentity.resolve(
                bundle: .main
            )
        try validateExpectedExecutableIdentity(
            admission: admission,
            receiptIdentity: receiptIdentity
        )
        return .init(
            admission: admission,
            applicationIdentity: receiptIdentity
        )
    }

#if DEBUG
    /// Injected bootstrap inputs exist only for XCTest. The admission resolver
    /// independently proves that the current host is an actual XCTest process
    /// before minting runtime authority.
    static func resolveForXCTest(
        arguments: [String],
        environment: [String: String],
        simulateXCTestRejection: Bool = false,
        applicationIdentity: P8FSignedSmokeApplicationIdentity,
        capabilities: Set<P8FSignedSmokeAdmissionCapability>,
        pathPolicy: LokiLaunchStoragePathPolicy,
        receiptIdentity:
            P8FSignedSmokeReceiptApplicationIdentity,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeBootstrap? {
        guard P8FSignedSmokeAdmissionResolver.hasControlIntent(
            arguments: arguments
        ) else {
            return nil
        }
        let admission =
            try P8FSignedSmokeAdmissionResolver.resolveForXCTest(
                arguments: arguments,
                environment: environment,
                simulateXCTestRejection: simulateXCTestRejection,
                applicationIdentity: applicationIdentity,
                capabilities: capabilities,
                pathPolicy: pathPolicy,
                fileManager: fileManager
            )
        try validateExpectedExecutableIdentity(
            admission: admission,
            receiptIdentity: receiptIdentity
        )
        return .init(
            admission: admission,
            applicationIdentity: receiptIdentity
        )
    }
#endif

    private static func validateExpectedExecutableIdentity(
        admission: P8FSignedSmokeAdmission,
        receiptIdentity: P8FSignedSmokeReceiptApplicationIdentity
    ) throws {
        if let expected =
                admission.controlPlan.expectedExecutableSHA256,
           expected != receiptIdentity.executableSHA256 {
            throw P8FSignedSmokeCoordinatorFailure
                .executableIdentityMismatch
        }
    }
}

enum P8FSignedSmokeRuntimeIdentity {
    static func resolve(
        bundle: Bundle
    ) throws -> P8FSignedSmokeReceiptApplicationIdentity {
        guard bundle.bundleIdentifier
                == P8FSignedSmokeApplicationIdentity
                    .required.bundleIdentifier,
              bundle.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
              ) as? String
                == P8FSignedSmokeApplicationIdentity
                    .required.marketingVersion,
              bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String
                == P8FSignedSmokeApplicationIdentity
                    .required.buildVersion
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .applicationIdentityUnavailable
        }
        guard let executableURL = bundle.executableURL,
              let executableData = try? Data(
                contentsOf: executableURL,
                options: [.mappedIfSafe]
              )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .executableIdentityUnavailable
        }
        return try .init(
            executableSHA256:
                P8FSignedSmokeDigest.sha256(executableData),
            cdHash: try currentCDHash()
        )
    }

    private static func currentCDHash() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .codeIdentityUnavailable
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            code,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .codeIdentityUnavailable
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any],
        let unique = dictionary[kSecCodeInfoUnique] as? Data,
        unique.count == 20
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .codeIdentityUnavailable
        }
        return unique.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum P8FSignedSmokeExecutionResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(P8FSignedSmokeCoordinatorFailure)
}

struct P8FSignedSmokeProviderReceiptClassification:
    Equatable,
    Sendable
{
    let status: P8FSignedSmokeStatus
    let reasonCode: P8FSignedSmokeReasonCode
}

struct P8FSignedSmokeEmbeddingCounters:
    Equatable,
    Sendable
{
    let requestCount: Int
    let inputCount: Int
    let acceptedVectorCount: Int
}

actor P8FSignedSmokeCountingEmbeddingProvider:
    P8EmbeddingProviding
{
    private let underlying = NativeOllamaEmbeddingProvider()
    private var requestCount = 0
    private var inputCount = 0
    private var acceptedVectorCount = 0

    func embed(
        _ request: OllamaEmbeddingRequest
    ) async throws -> OllamaEmbeddingReceipt {
        requestCount += 1
        inputCount += request.inputs.count
        let receipt = try await underlying.embed(request)
        acceptedVectorCount += receipt.vectors.count
        return receipt
    }

    func snapshot() -> P8FSignedSmokeEmbeddingCounters {
        .init(
            requestCount: requestCount,
            inputCount: inputCount,
            acceptedVectorCount: acceptedVectorCount
        )
    }
}

private struct P8FSignedSmokeCredentialCounters: Equatable, Sendable {
    let storeCount: Int
    let readCount: Int
    let deleteCount: Int
}

private actor P8FSignedSmokeVolatileCredentialProbe:
    OllamaWebResearchCredentialStoring
{
    private var storeCount = 0
    private var readCount = 0
    private var deleteCount = 0

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        try validateNamespace(
            service: service,
            account: account
        )
        storeCount += 1
    }

    func readAPIKey(
        service: String,
        account: String
    ) async throws -> String? {
        try validateNamespace(
            service: service,
            account: account
        )
        readCount += 1
        return nil
    }

    func deleteAPIKey(
        service: String,
        account: String
    ) async throws {
        try validateNamespace(
            service: service,
            account: account
        )
        deleteCount += 1
    }

    func snapshot() -> P8FSignedSmokeCredentialCounters {
        .init(
            storeCount: storeCount,
            readCount: readCount,
            deleteCount: deleteCount
        )
    }

    private func validateNamespace(
        service: String,
        account: String
    ) throws {
        guard service
                == OllamaWebResearchCredentialNamespace.service,
              account
                == OllamaWebResearchCredentialNamespace.account
        else {
            throw OllamaWebResearchFailure(
                .credentialNamespaceRejected
            )
        }
    }

}

struct P8FSignedSmokePrivacyScanner {
    private static let forbiddenKeys: Set<String> = [
        "text",
        "content",
        "visible_text",
        "source_text",
        "chat_content",
        "brief_content",
        "schedule_content",
        "vault_content",
        "slack_content",
        "connector_payload",
        "prompt",
        "raw_prompt",
        "response",
        "raw_response",
        "thinking",
        "hidden_reasoning",
        "vector",
        "vectors",
        "embedding_vector",
        "image_bytes",
        "authorization",
        "cookie",
        "credential",
        "token",
        "access_token",
        "refresh_token",
        "api_key",
        "password",
        "secret",
        "private_key",
    ]

    static func scan(
        isolatedRoot: URL,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokePrivacySummary {
        let directory = isolatedRoot.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        var artifactCount = 0
        var forbiddenFieldCount = 0
        var forbiddenValueCount = 0
        var rawVectorCount = 0
        var rawContentCount = 0
        var rawPromptCount = 0
        var rawResponseCount = 0
        var hiddenReasoningCount = 0
        var privatePathCount = 0
        var credentialCount = 0

        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw P8FSignedSmokeCoordinatorFailure
                    .privacyFailed
            }
            guard values.isRegularFile == true else { continue }
            artifactCount += 1
            let data = try Data(contentsOf: url)
            guard data.count <= 512 * 1_024,
                  let object = try? JSONSerialization.jsonObject(
                    with: data
                  )
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .privacyFailed
            }
            walk(
                object,
                forbiddenFieldCount: &forbiddenFieldCount,
                forbiddenValueCount: &forbiddenValueCount,
                rawVectorCount: &rawVectorCount,
                rawContentCount: &rawContentCount,
                rawPromptCount: &rawPromptCount,
                rawResponseCount: &rawResponseCount,
                hiddenReasoningCount: &hiddenReasoningCount,
                privatePathCount: &privatePathCount,
                credentialCount: &credentialCount
            )
        }
        return try .init(
            artifactCount: artifactCount,
            forbiddenFieldCount: forbiddenFieldCount,
            forbiddenValueCount: forbiddenValueCount,
            rawVectorCount: rawVectorCount,
            rawContentCount: rawContentCount,
            rawPromptCount: rawPromptCount,
            rawResponseCount: rawResponseCount,
            hiddenReasoningCount: hiddenReasoningCount,
            privatePathCount: privatePathCount,
            credentialCount: credentialCount
        )
    }

    static func scanEncodedArtifact(
        _ data: Data
    ) throws -> P8FSignedSmokePrivacySummary {
        guard data.count <= 512 * 1_024,
              let object = try? JSONSerialization.jsonObject(
                with: data
              )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .privacyFailed
        }
        var forbiddenFieldCount = 0
        var forbiddenValueCount = 0
        var rawVectorCount = 0
        var rawContentCount = 0
        var rawPromptCount = 0
        var rawResponseCount = 0
        var hiddenReasoningCount = 0
        var privatePathCount = 0
        var credentialCount = 0
        walk(
            object,
            forbiddenFieldCount: &forbiddenFieldCount,
            forbiddenValueCount: &forbiddenValueCount,
            rawVectorCount: &rawVectorCount,
            rawContentCount: &rawContentCount,
            rawPromptCount: &rawPromptCount,
            rawResponseCount: &rawResponseCount,
            hiddenReasoningCount: &hiddenReasoningCount,
            privatePathCount: &privatePathCount,
            credentialCount: &credentialCount
        )
        return try .init(
            artifactCount: 1,
            forbiddenFieldCount: forbiddenFieldCount,
            forbiddenValueCount: forbiddenValueCount,
            rawVectorCount: rawVectorCount,
            rawContentCount: rawContentCount,
            rawPromptCount: rawPromptCount,
            rawResponseCount: rawResponseCount,
            hiddenReasoningCount: hiddenReasoningCount,
            privatePathCount: privatePathCount,
            credentialCount: credentialCount
        )
    }

    private static func walk(
        _ object: Any,
        forbiddenFieldCount: inout Int,
        forbiddenValueCount: inout Int,
        rawVectorCount: inout Int,
        rawContentCount: inout Int,
        rawPromptCount: inout Int,
        rawResponseCount: inout Int,
        hiddenReasoningCount: inout Int,
        privatePathCount: inout Int,
        credentialCount: inout Int
    ) {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalized = key.lowercased()
                if forbiddenKeys.contains(normalized) {
                    forbiddenFieldCount += 1
                }
                if [
                    "vector",
                    "vectors",
                    "embedding_vector",
                ].contains(normalized) {
                    rawVectorCount += 1
                }
                if [
                    "text",
                    "content",
                    "visible_text",
                    "source_text",
                    "chat_content",
                    "brief_content",
                    "schedule_content",
                    "vault_content",
                    "slack_content",
                ].contains(normalized) {
                    rawContentCount += 1
                }
                if [
                    "prompt",
                    "raw_prompt",
                ].contains(normalized) {
                    rawPromptCount += 1
                }
                if [
                    "response",
                    "raw_response",
                ].contains(normalized) {
                    rawResponseCount += 1
                }
                if [
                    "reasoning",
                    "hidden_reasoning",
                    "thinking",
                ].contains(normalized) {
                    hiddenReasoningCount += 1
                }
                if [
                    "authorization",
                    "cookie",
                    "credential",
                    "token",
                    "access_token",
                    "refresh_token",
                    "api_key",
                    "password",
                    "secret",
                    "private_key",
                ].contains(normalized) {
                    credentialCount += 1
                }
                walk(
                    value,
                    forbiddenFieldCount: &forbiddenFieldCount,
                    forbiddenValueCount: &forbiddenValueCount,
                    rawVectorCount: &rawVectorCount,
                    rawContentCount: &rawContentCount,
                    rawPromptCount: &rawPromptCount,
                    rawResponseCount: &rawResponseCount,
                    hiddenReasoningCount:
                        &hiddenReasoningCount,
                    privatePathCount: &privatePathCount,
                    credentialCount: &credentialCount
                )
            }
        } else if let array = object as? [Any] {
            for value in array {
                walk(
                    value,
                    forbiddenFieldCount: &forbiddenFieldCount,
                    forbiddenValueCount: &forbiddenValueCount,
                    rawVectorCount: &rawVectorCount,
                    rawContentCount: &rawContentCount,
                    rawPromptCount: &rawPromptCount,
                    rawResponseCount: &rawResponseCount,
                    hiddenReasoningCount:
                        &hiddenReasoningCount,
                    privatePathCount: &privatePathCount,
                    credentialCount: &credentialCount
                )
            }
        } else if let value = object as? String {
            let lowercased = value.lowercased()
            if value.contains(
                "P8F_SYNTHETIC_EXCLUDED_LEAKAGE_CANARY"
            ) || value.contains(
                "P8F_SYNTHETIC_HIDDEN_REASONING_CANARY"
            ) {
                forbiddenValueCount += 1
            }
            if value.hasPrefix("/Users/")
                || value.hasPrefix("/Volumes/")
                || value.contains("/Library/Containers/") {
                privatePathCount += 1
            }
            if lowercased.contains("bearer ")
                || lowercased.contains("authorization:")
                || lowercased.contains("cookie:")
                || lowercased.contains("private key")
                || lowercased.contains("xoxb-")
                || lowercased.contains("xoxp-")
                || lowercased.contains("xoxe-") {
                credentialCount += 1
            }
        }
    }
}

enum P8FSignedSmokePrerequisiteValidator {
    static func validate(
        _ scenario: P8FSignedSmokeControlScenario,
        events: [P8FSignedSmokeEvent]
    ) throws {
        let successes = events.filter { $0.status == .success }
        func contains(
            _ expected: P8FSignedSmokeScenario,
            reason: P8FSignedSmokeReasonCode
        ) -> Bool {
            successes.contains {
                $0.metadata.scenario == expected
                    && $0.reasonCode == reason
            }
        }
        switch scenario {
        case .modelAssessment:
            break
        case .semanticSourceProof:
            guard contains(
                .qwenEmbedding,
                reason: .modelCapabilityPassed
            ) else {
                throw P8FSignedSmokeCoordinatorFailure
                    .prerequisiteMissing
            }
        case .search:
            guard contains(
                .successfulPublication,
                reason: .generationPublished
            ) else {
                throw P8FSignedSmokeCoordinatorFailure
                    .prerequisiteMissing
            }
        case .hydration:
            guard contains(
                .successfulPublication,
                reason: .generationPublished
            ) else {
                throw P8FSignedSmokeCoordinatorFailure
                    .prerequisiteMissing
            }
        case .cleanup:
            let required: [
                (
                    P8FSignedSmokeScenario,
                    P8FSignedSmokeReasonCode,
                    P8FSignedSmokeStatus
                )
            ] = [
                (.run, .admissionAccepted, .success),
                (.storageIsolation, .storageSelected, .success),
                (.sourceAuthority, .fixtureAccepted, .success),
                (.gemma4, .modelCapabilityPassed, .success),
                (.gptOSS, .modelCapabilityPassed, .success),
                (.qwenEmbedding, .modelCapabilityPassed, .success),
                (
                    .visibleVisionRouting,
                    .visionRouteDecisionObserved,
                    .success
                ),
                (
                    .visibleVisionRouting,
                    .visionTransportConfirmed,
                    .success
                ),
                (
                    .roleSeparation,
                    .roleSeparationPassed,
                    .success
                ),
                (
                    .webResearchDisabled,
                    .webResearchDisabledWithoutKey,
                    .success
                ),
                (
                    .cancellation,
                    .cancelledBeforePublication,
                    .cancelled
                ),
                (
                    .revocation,
                    .scopeRevokedBeforePublication,
                    .cancelled
                ),
                (
                    .modelProfileDrift,
                    .modelProfileDrift,
                    .cancelled
                ),
                (
                    .adapterContractDrift,
                    .adapterContractDrift,
                    .success
                ),
                (
                    .unknownSourceKind,
                    .unknownSourceKindRejected,
                    .success
                ),
                (
                    .transactionIntegrity,
                    .transactionIntegrityFailed,
                    .success
                ),
                (
                    .sourceAuthority,
                    .sourceScopeAuthorized,
                    .success
                ),
                (
                    .successfulPublication,
                    .generationPublished,
                    .success
                ),
                (.lexicalSearch, .searchPassed, .success),
                (.semanticSearch, .searchPassed, .success),
                (.hybridSearch, .searchPassed, .success),
                (
                    .searchNarrowing,
                    .searchFilterNarrowed,
                    .success
                ),
                (
                    .excludedSourceSearch,
                    .excludedSourceFilterEmpty,
                    .success
                ),
                (
                    .restartHydration,
                    .generationPublished,
                    .success
                ),
                (
                    .legacyHydration,
                    .legacyGenerationPreserved,
                    .success
                ),
                (
                    .staleHydration,
                    .staleIdentityRejected,
                    .success
                ),
                (
                    .malformedHydration,
                    .malformedIdentityRejected,
                    .success
                ),
            ]
            let includedKinds: Set<SemanticIndexSourceKind> = [
                .brief,
                .schedule,
                .chatMessage,
            ]
            let sourceEvents = successes.filter {
                $0.event == .sourceAdapter
                    && $0.metadata.scenario
                        == .sourceAuthority
            }
            let exactSourceMatrix =
                SemanticIndexSourceKind.allCases.allSatisfy {
                    sourceKind in
                    let matching = sourceEvents.filter {
                        $0.metadata.sourceKind == sourceKind
                    }
                    return matching.count == 1
                        && matching[0].reasonCode
                            == (
                                includedKinds.contains(sourceKind)
                                ? .adapterInvoked
                                : .adapterSkipped
                            )
                }
            let providerEvents = events.filter {
                $0.event == .network
                    && $0.metadata.model != nil
            }
            var exactProviderEvidence = true
            for model in P8FSignedSmokeApprovedModel.allCases {
                let hasExactEvidence = providerEvents.contains(where: { event in
                    guard event.metadata.model == model,
                          event.metadata.hasCompleteProviderCorrelation,
                          event.metadata.artifactSHA256 != nil,
                          event.status == .success,
                          event.reasonCode == .providerTransportSucceeded,
                          event.metadata.providerOutcome == .succeeded
                    else {
                        return false
                    }
                    return Self.providerOperationMatches(
                        model: model,
                        providerKind: event.metadata.providerKind,
                        operationKind:
                            event.metadata.providerOperationKind
                    )
                })
                guard hasExactEvidence else {
                    exactProviderEvidence = false
                    break
                }
            }
            let allModeledNetworkEventsAreCorrelated =
                providerEvents.allSatisfy {
                    $0.metadata.hasCompleteProviderCorrelation
                        && $0.metadata.artifactSHA256 != nil
                        && (
                            (
                                $0.status == .success
                                    && $0.reasonCode
                                        == .providerTransportSucceeded
                                    && $0.metadata.providerOutcome
                                        == .succeeded
                            )
                            || (
                                $0.status == .failed
                                    && $0.reasonCode
                                        == .providerTransportFailed
                                    && $0.metadata.providerOutcome
                                        == .failed
                            )
                            || (
                                $0.status == .cancelled
                                    && $0.reasonCode
                                        == .providerTransportCancelled
                                    && $0.metadata.providerOutcome
                                        == .cancelled
                            )
                        )
                }
            guard required.allSatisfy({ expected in
                events.contains {
                    $0.metadata.scenario == expected.0
                        && $0.reasonCode == expected.1
                        && $0.status == expected.2
                }
            }),
            exactSourceMatrix,
            exactProviderEvidence,
            allModeledNetworkEventsAreCorrelated
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .prerequisiteMissing
            }
        }
    }

    private static func providerOperationMatches(
        model: P8FSignedSmokeApprovedModel,
        providerKind: P8FProviderRequestKind?,
        operationKind: P8FProviderRequestOperation?
    ) -> Bool {
        switch model {
        case .qwenEmbedding:
            return providerKind == .embedding
                && operationKind == .embedding
        case .gemma4, .gptOSS:
            return providerKind == .chat
                && (
                    operationKind == .modelInspect
                        || operationKind == .chatStream
                )
        }
    }
}

#if DEBUG
@MainActor
final class P8FSignedSmokeCoordinatorXCTestHooks {
    fileprivate let postFixtureCleanupPackageInstallation:
        (() throws -> Void)?
    fileprivate let postCancellationContainment:
        (() throws -> Data)?
    fileprivate let providerCorrelationEvidenceAppend:
        (() throws -> Void)?
    fileprivate let postDiagnosticManifestCommit:
        (() -> Void)?

    private init(
        postFixtureCleanupPackageInstallation:
            (() throws -> Void)?,
        postCancellationContainment:
            (() throws -> Data)?,
        providerCorrelationEvidenceAppend:
            (() throws -> Void)?,
        postDiagnosticManifestCommit:
            (() -> Void)?
    ) {
        self.postFixtureCleanupPackageInstallation =
            postFixtureCleanupPackageInstallation
        self.postCancellationContainment =
            postCancellationContainment
        self.providerCorrelationEvidenceAppend =
            providerCorrelationEvidenceAppend
        self.postDiagnosticManifestCommit =
            postDiagnosticManifestCommit
    }

    /// Opaque hook authority is minted only inside an actual XCTest host. A
    /// Debug app process cannot construct this capability.
    static func make(
        postFixtureCleanupPackageInstallation:
            (() throws -> Void)? = nil,
        postCancellationContainment:
            (() throws -> Data)? = nil,
        providerCorrelationEvidenceAppend:
            (() throws -> Void)? = nil,
        postDiagnosticManifestCommit:
            (() -> Void)? = nil
    ) throws -> P8FSignedSmokeCoordinatorXCTestHooks {
        _ = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        return .init(
            postFixtureCleanupPackageInstallation:
                postFixtureCleanupPackageInstallation,
            postCancellationContainment:
                postCancellationContainment,
            providerCorrelationEvidenceAppend:
                providerCorrelationEvidenceAppend,
            postDiagnosticManifestCommit:
                postDiagnosticManifestCommit
        )
    }
}
#endif

@MainActor
final class P8FSignedSmokeCoordinator {
    private struct InjectedCancellationPrivacyFailure: Error {
        let summary: P8FSignedSmokePrivacySummary
    }

    private struct CommittedPublicationEvidence {
        let fixtureManifestSHA256: String
        let sourceAllowlistSHA256: String
        let generationIdentifierSHA256: String?
        let authorizationReceiptIdentifierSHA256: String
        var counters: P8FSignedSmokeCounters?
    }

    private let bootstrap: P8FSignedSmokeBootstrap
    private let fileManager = FileManager.default
#if DEBUG
    private let xctestHooks:
        P8FSignedSmokeCoordinatorXCTestHooks?
#endif
    private let providerEvidenceRun:
        P8FProviderRequestEvidenceRun?
    private var providerEvidenceSeal:
        P8FProviderRequestEvidenceSeal?
    private var committedPublicationEvidence:
        CommittedPublicationEvidence?
    private var controlTreeCleanupPackage:
        P8FSignedSmokeDependencyPackage?
    private var irreversiblePublicationCommitted = false
    private var hasExecuted = false

    private var storageBoundary: P8FSignedSmokeStorageBoundary {
        bootstrap.admission.storageBoundary
    }

    init(
        bootstrap: P8FSignedSmokeBootstrap,
        providerEvidenceRun:
            P8FProviderRequestEvidenceRun? = nil
    ) {
        self.bootstrap = bootstrap
        self.providerEvidenceRun = providerEvidenceRun
#if DEBUG
        xctestHooks = nil
#endif
    }

#if DEBUG
    static func makeForXCTest(
        bootstrap: P8FSignedSmokeBootstrap,
        hooks: P8FSignedSmokeCoordinatorXCTestHooks,
        providerEvidenceRun:
            P8FProviderRequestEvidenceRun? = nil
    ) throws -> P8FSignedSmokeCoordinator {
        _ = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        return .init(
            bootstrap: bootstrap,
            xctestHooks: hooks,
            providerEvidenceRun: providerEvidenceRun
        )
    }

    private init(
        bootstrap: P8FSignedSmokeBootstrap,
        xctestHooks: P8FSignedSmokeCoordinatorXCTestHooks,
        providerEvidenceRun:
            P8FProviderRequestEvidenceRun?
    ) {
        self.bootstrap = bootstrap
        self.xctestHooks = xctestHooks
        self.providerEvidenceRun = providerEvidenceRun
    }
#endif

    private func invokePostCancellationContainmentXCTestHook()
        throws -> Data?
    {
#if DEBUG
        return try xctestHooks?.postCancellationContainment?()
#else
        return nil
#endif
    }

    private func invokePostFixtureCleanupPackageInstallationXCTestHook()
        throws
    {
#if DEBUG
        try xctestHooks?
            .postFixtureCleanupPackageInstallation?()
#endif
    }

    private func invokeProviderCorrelationEvidenceAppendXCTestHook()
        throws
    {
#if DEBUG
        try xctestHooks?.providerCorrelationEvidenceAppend?()
#endif
    }

    private func invokePostDiagnosticManifestCommitXCTestHook() {
#if DEBUG
        xctestHooks?.postDiagnosticManifestCommit?()
#endif
    }

    func execute(
        model: AppModel
    ) async -> P8FSignedSmokeExecutionResult {
        guard !hasExecuted else {
            return .failed(.priorTerminalReceipt)
        }
        hasExecuted = true
        var activeWriter: P8FSignedSmokeReceiptWriter?
        do {
            let writer = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: bootstrap.isolatedRoot
            )
            activeWriter = writer
            guard writer.terminalReceipt == nil else {
                throw P8FSignedSmokeCoordinatorFailure
                    .priorTerminalReceipt
            }
            controlTreeCleanupPackage = try model
                .retainedSignedSmokeDependencyPackage(
                    storageBoundary: storageBoundary,
                    runtimeAuthority:
                        bootstrap.admission.runtimeAuthority
                )
            try prepareRun(writer)
            if !irreversiblePublicationCommitted {
                try Task.checkCancellation()
            }
            try P8FSignedSmokePrerequisiteValidator.validate(
                bootstrap.admission.controlPlan.scenario,
                events: writer.events
            )
            switch bootstrap.admission.controlPlan.scenario {
            case .modelAssessment:
                try await runModelAssessment(
                    model: model,
                    writer: writer
                )
            case .semanticSourceProof:
                try await runSemanticSourceProof(
                    model: model,
                    writer: writer
                )
            case .search:
                try await runSearch(
                    model: model,
                    writer: writer
                )
            case .hydration:
                try await runHydration(
                    model: model,
                    writer: writer
                )
            case .cleanup:
                try await runCleanup(
                    model: model,
                    writer: writer
                )
            }
            if writer.terminalReceipt != nil {
                return .succeeded
            }
            if !irreversiblePublicationCommitted {
                try Task.checkCancellation()
            }
            if bootstrap.admission.controlPlan.scenario
                != .cleanup {
                try appendProviderCorrelationEvidence(
                    writer: writer
                )
            }
            if !irreversiblePublicationCommitted {
                try Task.checkCancellation()
            }
            return .succeeded
        } catch {
            let primaryResult = Self.classify(error)
            let writer = activeWriter ?? (try?
                P8FSignedSmokeReceiptWriter(
                    isolatedRoot: bootstrap.isolatedRoot
                ))
            guard let writer else {
                return .failed(.receiptFailed)
            }
            guard writer.terminalReceipt == nil else {
                return primaryResult
            }
            var reconciledResult = primaryResult
            if case .cancelled = reconciledResult {
                // Cancellation reconciliation is strict below.
            } else {
                do {
                    try appendProviderCorrelationEvidence(
                        writer: writer
                    )
                } catch {
                    reconciledResult = .failed(.receiptFailed)
                }
            }
            switch reconciledResult {
            case .succeeded:
                return .failed(.receiptFailed)
            case .failed(let failure):
                do {
                    try persistFailure(
                        failure,
                        writer: writer
                    )
                    return .failed(failure)
                } catch {
                    return .failed(.receiptFailed)
                }
            case .cancelled:
                do {
                    try appendCancellationCausalEvent(
                        writer: writer
                    )
                    do {
                        try reconcileProviderCorrelationForCancellation(
                            writer: writer
                        )
                    } catch {
                        let terminalFailure:
                            P8FSignedSmokeCoordinatorFailure =
                                (error as?
                                    P8FSignedSmokeCoordinatorFailure)
                                    == .receiptFailed
                                ? .receiptFailed
                                : .cleanupFailed
                        try persistFailure(
                            terminalFailure,
                            writer: writer
                        )
                        return Self.resolveTerminalResult(
                            primary: .cancelled,
                            containmentFailure: terminalFailure
                        )
                    }
                    do {
                        try containCancelledRun(writer: writer)
                    } catch {
                        let terminalFailure =
                            P8FSignedSmokeCoordinatorFailure.cleanupFailed
                        try persistFailure(
                            terminalFailure,
                            writer: writer
                        )
                        return Self.resolveTerminalResult(
                            primary: .cancelled,
                            containmentFailure: terminalFailure
                        )
                    }
                    let injectedPrivacyArtifact =
                        try invokePostCancellationContainmentXCTestHook()
                    try persistCancellation(
                        writer: writer,
                        injectedPrivacyArtifact:
                            injectedPrivacyArtifact
                    )
                    return Self.resolveTerminalResult(
                        primary: .cancelled,
                        containmentFailure: nil
                    )
                } catch let injected
                    as InjectedCancellationPrivacyFailure
                {
                    do {
                        try persistFailure(
                            .privacyFailed,
                            writer: writer,
                            additionalPrivacySummary:
                                injected.summary
                        )
                        return .failed(.privacyFailed)
                    } catch {
                        return .failed(.receiptFailed)
                    }
                } catch let failure
                    as P8FSignedSmokeCoordinatorFailure
                    where failure == .privacyFailed
                {
                    do {
                        try persistFailure(
                            failure,
                            writer: writer
                        )
                        return .failed(failure)
                    } catch {
                        return .failed(.receiptFailed)
                    }
                } catch {
                    if writer.terminalReceipt == nil {
                        try? persistFailure(
                            .receiptFailed,
                            writer: writer
                        )
                    }
                    return .failed(.receiptFailed)
                }
            }
        }
    }

    private func prepareRun(
        _ writer: P8FSignedSmokeReceiptWriter
    ) throws {
        let runIdentitySHA256 = P8FSignedSmokeDigest.sha256(
            bootstrap.admission.controlPlan.runIdentifier
        )
        let rootEvent: P8FSignedSmokeEvent
        if let first = writer.events.first {
            guard first.event == .run,
                  first.reasonCode == .runStarted,
                  first.metadata.runtimeIdentitySHA256
                    == runIdentitySHA256
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .runIdentityMismatch
            }
            rootEvent = first
        } else {
            rootEvent = try writer.append(
                try eventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    runtimeIdentitySHA256: runIdentitySHA256,
                    artifactSHA256:
                        bootstrap.applicationIdentity
                            .executableSHA256
                )
            )
        }
        _ = try writer.append(
            try eventDraft(
                event: .admission,
                parentSpanID: rootEvent.spanID,
                component: .runner,
                status: .success,
                reasonCode: .admissionAccepted,
                scenario: .run,
                runtimeIdentitySHA256: runIdentitySHA256,
                artifactSHA256:
                    bootstrap.applicationIdentity
                        .executableSHA256
            )
        )
        _ = try writer.append(
            try eventDraft(
                event: .storageIsolation,
                parentSpanID: rootEvent.spanID,
                component: .persistence,
                status: .success,
                reasonCode: .storageSelected,
                scenario: .storageIsolation,
                runtimeIdentitySHA256: runIdentitySHA256
            )
        )
    }

    private func runModelAssessment(
        model: AppModel,
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try validatedFixture(writer: writer)
        try appendFixtureAccepted(
            seeded,
            writer: writer
        )
        guard let rawModel =
                bootstrap.admission.controlPlan.modelIdentifier,
              let approvedModel =
                P8FSignedSmokeApprovedModel(rawValue: rawModel),
              let expectedDigest =
                bootstrap.admission.controlPlan.modelDigest
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelUnavailable
        }
        let completedModelAssessments:
            Set<P8FSignedSmokeApprovedModel> = Set(
            writer.events.compactMap {
                event -> P8FSignedSmokeApprovedModel? in
                guard event.status == .success,
                      event.reasonCode
                        == .modelCapabilityPassed
                else {
                    return nil
                }
                switch event.metadata.scenario {
                case .gptOSS:
                    return P8FSignedSmokeApprovedModel.gptOSS
                case .gemma4:
                    return P8FSignedSmokeApprovedModel.gemma4
                case .qwenEmbedding:
                    return P8FSignedSmokeApprovedModel
                        .qwenEmbedding
                default:
                    return nil
                }
            }
        )
        let requiredPriorAssessments:
            Set<P8FSignedSmokeApprovedModel>
        switch approvedModel {
        case .gptOSS:
            requiredPriorAssessments = []
        case .gemma4:
            requiredPriorAssessments = [.gptOSS]
        case .qwenEmbedding:
            requiredPriorAssessments = [
                .gptOSS,
                .gemma4,
            ]
        }
        guard completedModelAssessments
                == requiredPriorAssessments
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        let assessmentStartedAt = Date()
        model.checkOllama()
        try await model
            .waitForCurrentOllamaSynchronizationPropagatingCancellation()
        guard let chat = model.chatController,
              let descriptor = chat.installedModels.first(
                where: { $0.id == approvedModel.rawValue }
              )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelUnavailable
        }
        guard descriptor.digest?.lowercased()
                == expectedDigest.lowercased()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelDigestMismatch
        }
        if approvedModel == .gemma4 {
            let primary = chat.modelRoleAssignment(
                for: .primaryAgent
            )
            guard primary.isExecutable,
                  primary.effectiveModelIdentifier
                    == P8FSignedSmokeApprovedModel
                        .gptOSS.rawValue
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelRoleFailed
            }
        }
        chat.assessModel(
            id: descriptor.id,
            requireVisibleVisionConfirmation:
                approvedModel == .gemma4
        )
        if approvedModel == .gemma4 {
            guard try await chat
                    .waitForSignedSmokeVisionAssessmentRoutePropagatingCancellation(),
                  let pending = chat.pendingVisionRoute,
                  pending.requestedRole == .primaryAgent,
                  pending.requestedModelIdentifier
                    == P8FSignedSmokeApprovedModel
                        .gptOSS.rawValue,
                  pending.visionModelIdentifier
                    == P8FSignedSmokeApprovedModel
                        .gemma4.rawValue,
                  chat.isGenerating == false
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelRoleFailed
            }
            _ = try writer.append(
                try eventDraft(
                    event: .modelCapability,
                    parentSpanID: rootSpanID(writer),
                    component: .modelProvider,
                    status: .success,
                    reasonCode:
                        .visionRouteDecisionObserved,
                    scenario: .visibleVisionRouting,
                    model: .gemma4,
                    fixtureManifestSHA256:
                        seeded.manifest.canonicalSHA256,
                    artifactSHA256:
                        P8FSignedSmokeDigest.sha256(
                            [
                                pending.requestedRole
                                    .rawValue,
                                pending
                                    .requestedModelIdentifier,
                                pending
                                    .visionModelIdentifier,
                            ]
                            .compactMap { $0 }
                            .joined(separator: "|")
                    )
                )
            )
            guard try await waitForVisibleVisionRoute(
                    chat: chat,
                    token:
                        pending.visibilityAcknowledgementToken
                  ),
                  chat.pendingVisionRoute?
                    .visibilityAcknowledgementToken
                    == pending.visibilityAcknowledgementToken,
                  chat.isGenerating == false
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelRoleFailed
            }
            chat.confirmPendingVisionRoute()
        }
        try await chat
            .waitForCurrentAssessmentPropagatingCancellation()
        guard let assessment = chat.modelAssessment(
            for: descriptor.id
        ),
        assessment.modelIdentifier == descriptor.id,
        assessment.modelDigest?.lowercased()
            == expectedDigest.lowercased(),
        assessment.assessmentVersion
            == ModelCapabilityAssessment
                .currentAssessmentVersion,
        assessment.providerVersion != nil,
        assessment.assessedAt >= assessmentStartedAt
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelAssessmentFailed
        }
        let role: ModelRole
        var runtimeIdentitySHA256: String?
        var requestProfileSHA256: String?
        switch approvedModel {
        case .gemma4:
            let requiredCapabilities: Set<ModelCapability> = [
                .chat,
                .streaming,
                .toolCalling,
                .cancellation,
                .vision,
                .reasoning,
            ]
            guard requiredCapabilities.isSubset(
                of: assessment.capabilitiesProven
            ),
            assessment.verifiedReasoningControls.contains(
                .ollamaBoolean
            ),
            [
                ModelCapabilityProbe.syntheticToolCall,
                .toolResultContinuation,
                .reasoningControl,
                .syntheticVision,
            ].allSatisfy({
                diagnosticSucceeded(
                    $0,
                    in: assessment
                )
            })
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelAssessmentFailed
            }
            _ = try writer.append(
                try eventDraft(
                    event: .modelCapability,
                    parentSpanID: rootSpanID(writer),
                    component: .modelProvider,
                    status: .success,
                    reasonCode:
                        .visionTransportConfirmed,
                    scenario: .visibleVisionRouting,
                    model: .gemma4,
                    fixtureManifestSHA256:
                        seeded.manifest.canonicalSHA256,
                    modelDigest:
                        expectedDigest.lowercased()
                )
            )
            role = .vision
        case .gptOSS:
            let requiredCapabilities: Set<ModelCapability> = [
                .chat,
                .streaming,
                .structuredOutput,
                .toolCalling,
                .cancellation,
                .reasoning,
            ]
            guard requiredCapabilities.isSubset(
                of: assessment.capabilitiesProven
            ),
            [
                ModelReasoningControl.ollamaLow,
                .ollamaMedium,
                .ollamaHigh,
            ].allSatisfy(
                assessment.verifiedReasoningControls.contains
            ),
            [
                ModelCapabilityProbe.syntheticToolCall,
                .toolResultContinuation,
                .cancellation,
                .reasoningControl,
            ].allSatisfy({
                diagnosticSucceeded(
                    $0,
                    in: assessment
                )
            }) else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelAssessmentFailed
            }
            role = .primaryAgent
        case .qwenEmbedding:
            guard assessment.capabilitiesProven
                    .contains(.embedding),
                  let stability = assessment.embeddingStability,
                  stability.accepted,
                  stability.modelIdentifier == descriptor.id,
                  stability.modelDigest.lowercased()
                    == expectedDigest.lowercased(),
                  stability.ollamaVersion
                    == assessment.providerVersion,
                  stability.observedDimension == 1_024,
                  stability.explicitDimensions == 1_024,
                  diagnosticSucceeded(
                    .embeddingSingle,
                    in: assessment
                  ),
                  diagnosticSucceeded(
                    .embeddingBatch,
                    in: assessment
                  )
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelAssessmentFailed
            }
            runtimeIdentitySHA256 =
                P8FSignedSmokeDigest.sha256(
                    stability.ollamaVersion
                )
            requestProfileSHA256 =
                stability.requestProfileHash
            role = .embedding
        }
        let priorOtherAssignments = Dictionary(
            uniqueKeysWithValues:
                chat.modelRoleAssignments
                    .filter { $0.role != role }
                    .map { ($0.role, $0) }
        )
        chat.assignModel(id: descriptor.id, to: role)
        let assignment = chat.modelRoleAssignment(for: role)
        guard assignment.effectiveModelIdentifier
                == descriptor.id,
              assignment.modelDigest?.lowercased()
                == expectedDigest.lowercased(),
              assignment.readiness == .ready,
              assignment.executionFailure == nil,
              priorOtherAssignments.allSatisfy({
                  chat.modelRoleAssignment(for: $0.key)
                    == $0.value
              }),
              !chat.modelRoleAssignments.contains(where: {
                  $0.effectiveModelIdentifier?
                    .lowercased().contains("gemma3") == true
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        guard chat.p8Features
                .declareSignedSmokeWebCredentialAbsentWithoutRead(),
              chat.p8Features.webCredentialConfigured == false,
              !chat.p8Features.webGlobalSettings.providerEnabled,
              !chat.p8Features.webGlobalSettings
                .externalNetworkDisclosureAccepted,
              chat.p8Features.webResearchToolDefinitions(
                conversationIdentifier:
                    "p8f-synthetic-web-disabled",
                effectiveContextTokens: 65_536
              ).isEmpty
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        let webCredentialSealBeforeDispatch =
            chat.p8Features
                .signedSmokeWebCredentialSealSnapshot
        guard webCredentialSealProvesNoAccess(
            webCredentialSealBeforeDispatch
        ) else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        var webDispatchRejectedBeforeTransport = false
        do {
            _ = try await chat.p8Features
                .executeWebResearchToolCall(
                    .init(
                        id: "p8f-synthetic-web-call",
                        name:
                            P8WebResearchToolName.search.rawValue,
                        argumentsJSON: Data(
                            """
                            {"query":"synthetic disabled proof","maximumResults":1}
                            """.utf8
                        )
                    ),
                    conversationIdentifier:
                        "p8f-synthetic-web-disabled",
                    session: .init(
                        effectiveContextTokens: 65_536
                    )
                )
        } catch let failure
            as P8SignedSmokeWebResearchFailure
        {
            webDispatchRejectedBeforeTransport =
                failure.code == .disabledWithoutKey
        }
        guard webDispatchRejectedBeforeTransport,
              chat.p8Features
                .signedSmokeWebCredentialSealSnapshot
                == webCredentialSealBeforeDispatch,
              webCredentialSealProvesNoAccess(
                chat.p8Features
                    .signedSmokeWebCredentialSealSnapshot
              )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        let scenario = scenario(for: approvedModel)
        _ = try writer.append(
            try eventDraft(
                event: .modelCapability,
                parentSpanID: rootSpanID(writer),
                component: .modelProvider,
                status: .success,
                reasonCode: .modelCapabilityPassed,
                scenario: scenario,
                model: approvedModel,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                modelDigest: expectedDigest.lowercased(),
                runtimeIdentitySHA256:
                    runtimeIdentitySHA256,
                requestProfileSHA256:
                    requestProfileSHA256,
                vectorDimension:
                    approvedModel == .qwenEmbedding
                    ? 1_024
                    : nil
            )
        )
        _ = try writer.append(
            try eventDraft(
                event: .network,
                parentSpanID: rootSpanID(writer),
                component: .networkGuard,
                status: .success,
                reasonCode:
                    .webResearchDisabledWithoutKey,
                scenario: .webResearchDisabled,
                endpointClassification:
                    P8FSignedSmokeEndpointClassification.none,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256
            )
        )
        try await proveRoleSeparationIfReady(
            chat: chat,
            writer: writer,
            fixtureManifestSHA256:
                seeded.manifest.canonicalSHA256
        )
    }

    private func runSemanticSourceProof(
        model: AppModel,
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try validatedFixture(writer: writer)
        try appendFixtureAccepted(
            seeded,
            writer: writer
        )
        let audit =
            try P8FSignedSmokeFixtureSeeder
                .auditClosedSourceDomain(
                    fixtureDirectory: seeded.fixtureDirectory
                )
        guard audit.excludedKnownKindCount == 3,
              audit.unknownRejectedCount == 1,
              audit.malformedRejectedCount == 1,
              audit.acceptedUnexpectedKindCount == 0
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .fixtureMismatch
        }
        let modelContext = try qwenContext(model: model)
        try await runAtomicAdversarialMatrix(
            modelContext: modelContext,
            writer: writer
        )

        let sourceKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        let priorDependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let priorIndex = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: priorDependencyPackage
        )
        let priorController = try semanticController(
            seeded: seeded,
            dependencyPackage: priorDependencyPackage,
            index: priorIndex,
            modelContext: modelContext
        )
        let priorReceiptIdentifier =
            authorizationReceiptIdentifier(
                suffix: "successful_publication_prior"
            )
        let priorOutcome = try await awaitSignedSmokeRebuild(
            controller: priorController,
            request: .init(
                sourceKinds: sourceKinds,
                requestTimestamp:
                    P8FSignedSmokeFixtureSeeder.anchor,
                authorizationReceiptIdentifier:
                    priorReceiptIdentifier
            )
        )
        guard priorOutcome.state == .published,
              let prior = try await priorIndex.activeGeneration(),
              prior.identifier
                == priorOutcome.generationIdentifier
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        await priorController.closeForApplicationTermination()
        let embeddingProvider =
            P8FSignedSmokeCountingEmbeddingProvider()
        let dependencyPackage = try dependencyPackage(
            seeded: seeded,
            sourceRegistryMode: .blockBeforeRead(.brief),
            embeddingCapability: .counting(embeddingProvider)
        )
        let registry = dependencyPackage.sourceRegistry
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: dependencyPackage
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: dependencyPackage,
            index: index,
            modelContext: modelContext
        )
        let receiptIdentifier =
            authorizationReceiptIdentifier(
                suffix: "successful_publication"
            )
        let task = Task {
            await controller.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: sourceKinds,
                    requestTimestamp:
                        P8FSignedSmokeFixtureSeeder.anchor,
                    authorizationReceiptIdentifier:
                        receiptIdentifier
                )
            )
        }
        let outcome: P8SignedSmokeSemanticRebuildOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await registry.waitUntilBlocked(
                    sourceKind: .brief
                )
                try Task.checkCancellation()
                let duringBuild = try await index.activeGeneration()
                guard duringBuild?.identifier == prior.identifier else {
                    registry.releaseBlockedProvider()
                    _ = await task.value
                    throw P8FSignedSmokeCoordinatorFailure
                        .atomicPublicationFailed
                }
                registry.releaseBlockedProvider()
                let completed = await task.value
                if completed.state == .cancelled {
                    throw CancellationError()
                }
                return completed
            } onCancel: {
                task.cancel()
                Task { @MainActor in
                    registry
                        .cancelBlockedWaitAndReleaseProvider()
                }
            }
        } catch {
            task.cancel()
            registry.cancelBlockedWaitAndReleaseProvider()
            let completed = await task.value
            await controller.waitForCurrentWork()
            await controller.closeForApplicationTermination()
            if Self.isCancellation(error),
               completed.state == .failed
                || completed.state == .rejected {
                throw P8FSignedSmokeCoordinatorFailure
                    .semanticBuildFailed
            }
            throw error
        }
        if let publishedGenerationIdentifier =
                outcome.generationIdentifier
        {
            irreversiblePublicationCommitted = true
            committedPublicationEvidence = .init(
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                sourceAllowlistSHA256:
                    seeded.manifest
                        .expectedSourceAllowlistSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        publishedGenerationIdentifier
                    ),
                authorizationReceiptIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        receiptIdentifier
                    ),
                counters: nil
            )
        }
        if outcome.state != .published,
           outcome.reasonCode
            == "semantic_source_authority_receipt_persistence_failed"
        {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        guard outcome.state == .published,
              outcome.initiation == .signedSmokeRunner,
              outcome.sourceAllowlistSHA256
                == seeded.manifest
                    .expectedSourceAllowlistSHA256,
              let generationIdentifier =
                outcome.generationIdentifier,
              let active = try await index.activeGeneration(),
              active.identifier == generationIdentifier,
              active.identifier != prior.identifier,
              active.sourceCount
                == seeded.manifest
                    .expectedPreparedRecordCount,
              active.chunkCount
                == seeded.manifest.expectedChunkCount,
              active.spec.buildScope?.sourceKinds
                == sourceKinds,
              active.spec.buildScope?.initiation
                == .signedSmokeRunner,
              active.spec.buildScope?.allowlistSHA256
                == seeded.manifest
                    .expectedSourceAllowlistSHA256,
              Dictionary(
                uniqueKeysWithValues:
                    active.sourceRecordHashes.map {
                        (
                            P8FSignedSmokeDigest.sha256(
                                $0.key
                            ),
                            $0.value
                        )
                    }
              )
                == Dictionary(
                    uniqueKeysWithValues:
                        seeded.manifest.sourceHashes.map {
                            (
                                $0.stableIdentifierSHA256,
                                $0.sourceSHA256
                            )
                        }
                )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .semanticBuildFailed
        }
        let authorityArtifact:
            P8FSignedSmokeSourceAuthorityReceiptArtifact
        do {
            guard controller
                    .semanticSourceAuthorityReceiptPersistenceIsAvailable,
                  let durableArtifact = try dependencyPackage
                    .semanticSourceAuthorityReceiptStore
                    .loadValidatedArtifact(),
                  !durableArtifact.receipts.isEmpty,
                  durableArtifact.receipts
                    == controller.semanticSourceAuthorityEvents
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .receiptFailed
            }
            authorityArtifact = durableArtifact
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        let authorityEvents = authorityArtifact.receipts
        let counters = registry.counters()
        let embeddingCounters =
            await embeddingProvider.snapshot()
        let terminalAuthority =
            authorityEvents.last {
                $0.name == .generationBound
                    && $0.authorizationReceiptIdentifier
                        == receiptIdentifier
            }
        let publicationEvents =
            authorityEvents.filter {
                $0.name == .generationBound
                    && $0.authorizationReceiptIdentifier
                        == receiptIdentifier
            }
        let included = counters.filter {
            sourceKinds.contains($0.sourceKind)
        }
        let excluded = counters.filter {
            !sourceKinds.contains($0.sourceKind)
        }
        let expectedRecordCounts = Dictionary(
            grouping: seeded.manifest.sourceHashes,
            by: \.sourceKind
        ).mapValues(\.count)
        let indexedEvents =
            authorityEvents.filter {
                $0.name == .recordPrepared
                    && $0.status == "indexed"
                    && $0.authorizationReceiptIdentifier
                        == receiptIdentifier
            }
        let indexedEventByKind =
            Dictionary(
                uniqueKeysWithValues:
                    indexedEvents.compactMap {
                        event
                        -> (
                            SemanticIndexSourceKind,
                            P8SemanticSourceAuthorityEvent
                        )? in
                        guard let raw = event.sourceKind,
                              let kind =
                                SemanticIndexSourceKind(
                                    rawValue: raw
                                )
                        else { return nil }
                        return (kind, event)
                    }
            )
        let skippedKinds =
            Set(
                authorityEvents
                    .filter {
                        $0.name == .adapterSkipped
                            && $0.authorizationReceiptIdentifier
                                == receiptIdentifier
                    }
                    .compactMap {
                        $0.sourceKind.flatMap(
                            SemanticIndexSourceKind.init(
                                rawValue:
                            )
                        )
                    }
            )
        let excludedKinds =
            Set(SemanticIndexSourceKind.allCases)
                .subtracting(sourceKinds)
        let sourceEmbeddingInputCount =
            embeddingCounters.inputCount - 2
        let sourceAcceptedVectorCount =
            embeddingCounters.acceptedVectorCount - 2
        guard included.allSatisfy({
            let expected =
                expectedRecordCounts[$0.sourceKind] ?? 0
            let event = indexedEventByKind[$0.sourceKind]
            return $0.adapterInvocations == 1
                && $0.recordsRead == expected
                && event?.preparedRecordCount == expected
                && event?.chunkCount == expected
                && event?.indexedCount == expected
                && event?.excludedCount == 0
                && event?.tombstoneCount == 0
                && event?.skippedCount == 0
                && event?.rejectedCount == 0
        }),
        included.reduce(0, { $0 + $1.recordsRead })
            == seeded.manifest.expectedPreparedRecordCount,
        excluded.allSatisfy({
            $0.adapterInvocations == 0 && $0.recordsRead == 0
        }),
        skippedKinds == excludedKinds,
        publicationEvents.count == 1,
        publicationEvents.first?.generationIdentifier
            == generationIdentifier,
        indexedEventByKind.count == sourceKinds.count,
        embeddingCounters.requestCount
            == sourceKinds.count + 1,
        embeddingCounters.inputCount
            == seeded.manifest
                .expectedSourceEmbeddingCount + 2,
        embeddingCounters.acceptedVectorCount
            == seeded.manifest
                .expectedSourceEmbeddingCount + 2,
        sourceEmbeddingInputCount
            == seeded.manifest
                .expectedSourceEmbeddingCount,
        sourceAcceptedVectorCount
            == seeded.manifest
                .expectedSourceEmbeddingCount,
        terminalAuthority?.preparedRecordCount
            == seeded.manifest.expectedPreparedRecordCount,
        terminalAuthority?.chunkCount
            == seeded.manifest.expectedChunkCount,
        terminalAuthority?.indexedCount
            == seeded.manifest.expectedIndexWriteCount,
        terminalAuthority?.excludedCount == 0,
        terminalAuthority?.rejectedCount == 0
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .semanticCountMismatch
        }
        var perSourceCounters:
            [SemanticIndexSourceKind: P8FSignedSmokeCounters] = [:]
        for counter in counters {
            let sourceKind = counter.sourceKind
            let isIncluded = sourceKinds.contains(sourceKind)
            let indexed = indexedEventByKind[sourceKind]
            let sourceCounters =
                try P8FSignedSmokeCounters(
                    adapterInvocations:
                        counter.adapterInvocations,
                    recordsRead: counter.recordsRead,
                    recordsAccepted:
                        indexed?.indexedCount ?? 0,
                    recordsRejected:
                        (indexed?.excludedCount ?? 0)
                        + (indexed?.tombstoneCount ?? 0)
                        + (indexed?.skippedCount ?? 0)
                        + (indexed?.rejectedCount ?? 0),
                    preparedRecords:
                        indexed?.preparedRecordCount ?? 0,
                    chunks: indexed?.chunkCount ?? 0,
                    embeddingRequests:
                        indexed?.chunkCount ?? 0,
                    embeddingsAccepted:
                        indexed?.chunkCount ?? 0,
                    indexWrites:
                        indexed?.indexedCount ?? 0,
                    leakageCanaryHits: 0
                )
            let emptyCounters = try P8FSignedSmokeCounters()
            guard isIncluded
                    || sourceCounters == emptyCounters
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .semanticCountMismatch
            }
            perSourceCounters[sourceKind] =
                sourceCounters
            _ = try writer.append(
                try eventDraft(
                    event: .sourceAdapter,
                    parentSpanID: rootSpanID(writer),
                    component: .semanticSourceAuthority,
                    status: .success,
                    reasonCode:
                        isIncluded
                        ? .adapterInvoked
                        : .adapterSkipped,
                    scenario: .sourceAuthority,
                    sourceKind: sourceKind,
                    fixtureManifestSHA256:
                        seeded.manifest.canonicalSHA256,
                    sourceAllowlistSHA256:
                        seeded.manifest
                            .expectedSourceAllowlistSHA256,
                    authorizationReceiptIdentifierSHA256:
                        P8FSignedSmokeDigest.sha256(
                            receiptIdentifier
                        ),
                    counters: sourceCounters
                )
            )
        }
        let aggregate = try aggregateCounters(
            Array(perSourceCounters.values)
        )
        guard aggregate.preparedRecords
                == seeded.manifest
                    .expectedPreparedRecordCount,
              aggregate.chunks
                == seeded.manifest.expectedChunkCount,
              aggregate.embeddingRequests
                == seeded.manifest
                    .expectedSourceEmbeddingCount,
              aggregate.embeddingsAccepted
                == seeded.manifest
                    .expectedSourceEmbeddingCount,
              aggregate.indexWrites
                == seeded.manifest.expectedIndexWriteCount,
              aggregate.leakageCanaryHits
                == seeded.manifest
                    .expectedLeakageCanaryHitCount
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .semanticCountMismatch
        }
        committedPublicationEvidence?.counters = aggregate
        _ = try writer.append(
            try eventDraft(
                event: .sourceAuthority,
                parentSpanID: rootSpanID(writer),
                component: .semanticSourceAuthority,
                status: .success,
                reasonCode: .sourceScopeAuthorized,
                scenario: .sourceAuthority,
                artifactClassification:
                    .sourceAuthorityReceipt,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                sourceAllowlistSHA256:
                    seeded.manifest
                        .expectedSourceAllowlistSHA256,
                authorizationReceiptIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        receiptIdentifier
                    ),
                artifactSHA256:
                    authorityArtifact.canonicalSHA256,
                counters: aggregate
            )
        )
        try appendCommittedPublicationEvidenceIfNeeded(
            writer: writer
        )
        await controller.closeForApplicationTermination()
    }

    private func proveRoleSeparationIfReady(
        chat: LokiChatController,
        writer: P8FSignedSmokeReceiptWriter,
        fixtureManifestSHA256: String
    ) async throws {
        guard !writer.events.contains(where: {
            $0.status == .success
                && $0.metadata.scenario == .roleSeparation
                && $0.reasonCode == .roleSeparationPassed
        }) else {
            return
        }
        let initialAssignments = Dictionary(
            uniqueKeysWithValues:
                chat.modelRoleAssignments.map {
                    ($0.role, $0)
                }
        )
        guard Set(initialAssignments.keys)
                == Set(ModelRole.allCases),
              initialAssignments[.primaryAgent]?
                .effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel.gptOSS.rawValue,
              initialAssignments[.primaryAgent]?.readiness
                == .ready,
              initialAssignments[.vision]?
                .effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel.gemma4.rawValue,
              initialAssignments[.vision]?.readiness == .ready,
              initialAssignments[.embedding]?
                .effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue,
              initialAssignments[.embedding]?.readiness
                == .ready,
              !initialAssignments.values.contains(where: {
                  $0.effectiveModelIdentifier?
                    .lowercased().contains("gemma3") == true
              })
        else {
            // Role separation is emitted only after every required assessment
            // has completed. Earlier per-model launches remain successful and
            // the cleanup prerequisite still fails closed until this event
            // exists.
            return
        }
        chat.assignModel(
            id: P8FSignedSmokeApprovedModel.gemma4.rawValue,
            to: .briefSummary
        )
        let afterSummaryAssignment = Dictionary(
            uniqueKeysWithValues:
                chat.modelRoleAssignments.map {
                    ($0.role, $0)
                }
        )
        let otherRolesUnchangedAfterSummary =
            ModelRole.allCases
                .filter { $0 != .briefSummary }
                .allSatisfy {
                    afterSummaryAssignment[$0]
                        == initialAssignments[$0]
                }
        guard afterSummaryAssignment[.briefSummary]?
                .effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel.gemma4.rawValue,
              afterSummaryAssignment[.briefSummary]?.readiness
                == .ready,
              afterSummaryAssignment[.briefSummary]?
                .isExplicitlyAssigned == true,
              otherRolesUnchangedAfterSummary
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        chat.assignModel(
            id: P8FSignedSmokeApprovedModel.gptOSS.rawValue,
            to: .textFallback
        )
        let afterFallbackAssignment = Dictionary(
            uniqueKeysWithValues:
                chat.modelRoleAssignments.map {
                    ($0.role, $0)
                }
        )
        let otherRolesUnchangedAfterFallback =
            ModelRole.allCases
                .filter { $0 != .textFallback }
                .allSatisfy {
                    afterFallbackAssignment[$0]
                        == afterSummaryAssignment[$0]
                }
        guard afterFallbackAssignment[.textFallback]?
                .effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel.gptOSS.rawValue,
              afterFallbackAssignment[.textFallback]?.readiness
                == .ready,
              afterFallbackAssignment[.textFallback]?
                .isExplicitlyAssigned == true,
              otherRolesUnchangedAfterFallback
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        let embeddingRoute = ModelRoleRouter.route(
            requestedRole: .embedding,
            attachmentsPresent: false,
            assignments: chat.modelRoleAssignments,
            receiptIdentifier:
                "p8f_signed_smoke_embedding_route",
            traceID:
                "trace_p8f_signed_smoke_role_separation",
            spanID:
                "span_p8f_signed_smoke_embedding_route",
            at: P8FSignedSmokeFixtureSeeder.anchor
        )
        guard embeddingRoute.maySubmit,
              embeddingRoute.receipt.selectedRole == .embedding,
              embeddingRoute.receipt.effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue,
              let imageData =
                LokiChatController
                    .signedSmokeSyntheticVisionFixtureData()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }

        chat.p8Features.addVisionData(
            imageData,
            typeIdentifier: "public.png",
            source: .filePicker
        )
        await chat.p8Features.waitForCurrentWork()
        guard chat.p8Features.visionAttachments.count == 1,
              chat.p8Features.hasVisionAttachments
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        chat.send(
            "Synthetic routing proof. State which color is on the left and which is on the right.",
            requireVisibleVisionAcknowledgement: true
        )
        guard let pending = chat.pendingVisionRoute,
              pending.requestedRole == .primaryAgent,
              pending.requestedModelIdentifier
                == P8FSignedSmokeApprovedModel.gptOSS.rawValue,
              pending.visionModelIdentifier
                == P8FSignedSmokeApprovedModel.gemma4.rawValue,
              chat.isGenerating == false,
              chat.p8Features.hasVisionAttachments
        else {
            await chat.p8Features.cancelAndClearVisionAttachments()
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        guard let routingReceipt =
                chat.signedSmokeLatestModelRoutingReceipt(),
              routingReceipt.status == .ready,
              routingReceipt.requestedRole
                == .primaryAgent,
              routingReceipt.selectedRole == .vision,
              routingReceipt.requestedModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .gptOSS.rawValue,
              routingReceipt.effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .gemma4.rawValue,
              routingReceipt.switchStatus
                == .visibleCrossRole,
              routingReceipt.reasonCode
                == "model_routing_image_to_verified_vision",
              routingReceipt.attachmentsPresent
        else {
            await chat.p8Features
                .cancelAndClearVisionAttachments()
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        guard try await waitForVisibleVisionRoute(
                chat: chat,
                token:
                    pending.visibilityAcknowledgementToken
              )
        else {
            await chat.p8Features
                .cancelAndClearVisionAttachments()
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        chat.confirmPendingVisionRoute()
        try await chat
            .waitForCurrentGenerationPropagatingCancellation()
        guard let assistant =
                chat.activeConversation?.messages.last(
                    where: { $0.role == .assistant }
                ),
              chat.pendingVisionRoute == nil,
              chat.isGenerating == false,
              chat.p8Features.hasVisionAttachments == false,
              chat.errorMessage == nil,
              assistant.state == .completed,
              LokiChatController
                .signedSmokeVisionOutputProvesRedLeftBlueRight(
                    assistant.visibleText
                )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .modelRoleFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .modelCapability,
                parentSpanID: rootSpanID(writer),
                component: .modelProvider,
                status: .success,
                reasonCode: .roleSeparationPassed,
                scenario: .roleSeparation,
                fixtureManifestSHA256:
                    fixtureManifestSHA256,
                artifactSHA256:
                    P8FSignedSmokeDigest.sha256(
                        routingReceipt.id
                    )
            )
        )
    }

    private func diagnosticSucceeded(
        _ probe: ModelCapabilityProbe,
        in assessment: ModelCapabilityAssessment
    ) -> Bool {
        assessment.diagnostics.contains {
            $0.probe == probe && $0.status == .success
        }
    }

    private func waitForVisibleVisionRoute(
        chat: LokiChatController,
        token: String
    ) async throws -> Bool {
        do {
            for _ in 0..<200 {
                try Task.checkCancellation()
                guard chat.pendingVisionRoute?
                        .visibilityAcknowledgementToken == token
                else {
                    await chat.cancelAndDrainSignedSmokeOperation(
                        expectedVisionRouteToken: token
                    )
                    return false
                }
                if chat
                    .pendingVisionRouteVisibilityWasAcknowledged(
                        token: token
                    ) {
                    return true
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            await chat.cancelAndDrainSignedSmokeOperation(
                expectedVisionRouteToken: token
            )
            throw error
        }
        await chat.cancelAndDrainSignedSmokeOperation(
            expectedVisionRouteToken: token
        )
        return false
    }

    private func webCredentialSealProvesNoAccess(
        _ snapshot:
            P8SignedSmokeWebCredentialSealSnapshot
    ) -> Bool {
        snapshot.isSealed
            && snapshot.storeAttemptCount == 0
            && snapshot.readAttemptCount == 0
            && snapshot.deleteAttemptCount == 0
            && snapshot.rejectedStoreAttemptCount == 0
            && snapshot.rejectedReadAttemptCount == 0
            && snapshot.rejectedDeleteAttemptCount == 0
            && snapshot.activeStoreCount == 0
            && snapshot.activeReadCount == 0
            && snapshot.activeDeleteCount == 0
    }

    private func resultsMatchFixtureManifest(
        _ results: [SemanticSearchResult],
        manifest: P8FSignedSmokeFixtureManifest
    ) -> Bool {
        let expected = Dictionary(
            uniqueKeysWithValues:
                manifest.sourceHashes.map {
                    (
                        "\($0.sourceKind.rawValue)|"
                            + $0.stableIdentifierSHA256,
                        $0.sourceSHA256
                    )
                }
        )
        return !results.isEmpty
            && results.allSatisfy { result in
                let provenance = result.provenance
                let key =
                    "\(provenance.sourceKind.rawValue)|"
                    + P8FSignedSmokeDigest.sha256(
                        provenance.stableSourceIdentifier
                    )
                return expected[key]
                        == provenance.sourceHash
                    && P8FSignedSmokeDigest.isSHA256(
                        provenance.provenanceReceiptHash
                    )
            }
    }

    private func provenanceIdentifierSHA256s(
        for results: [SemanticSearchResult]
    ) -> [String] {
        Set(
            results.map {
                P8FSignedSmokeDigest.sha256(
                    SemanticIndexDigest.lengthPrefixed([
                        $0.provenance
                            .stableSourceIdentifier,
                        $0.provenance
                            .provenanceReceiptHash,
                        $0.provenance.sourceHash,
                    ])
                )
            }
        ).sorted()
    }

    private func aggregateCounters(
        _ counters: [P8FSignedSmokeCounters]
    ) throws -> P8FSignedSmokeCounters {
        try P8FSignedSmokeCounters(
            adapterInvocations:
                counters.reduce(0) {
                    $0 + $1.adapterInvocations
                },
            recordsRead:
                counters.reduce(0) {
                    $0 + $1.recordsRead
                },
            recordsAccepted:
                counters.reduce(0) {
                    $0 + $1.recordsAccepted
                },
            recordsRejected:
                counters.reduce(0) {
                    $0 + $1.recordsRejected
                },
            preparedRecords:
                counters.reduce(0) {
                    $0 + $1.preparedRecords
                },
            chunks:
                counters.reduce(0) { $0 + $1.chunks },
            embeddingRequests:
                counters.reduce(0) {
                    $0 + $1.embeddingRequests
                },
            embeddingsAccepted:
                counters.reduce(0) {
                    $0 + $1.embeddingsAccepted
                },
            indexWrites:
                counters.reduce(0) {
                    $0 + $1.indexWrites
                },
            resultCount:
                counters.reduce(0) {
                    $0 + $1.resultCount
                },
            leakageCanaryHits:
                counters.reduce(0) {
                    $0 + $1.leakageCanaryHits
                }
        )
    }

    private func runSearch(
        model: AppModel,
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try validatedFixture(writer: writer)
        try appendFixtureAccepted(
            seeded,
            writer: writer
        )
        let modelContext = try qwenContext(model: model)
        let dependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let registry = dependencyPackage.sourceRegistry
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: dependencyPackage
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: dependencyPackage,
            index: index,
            modelContext: modelContext
        )
        guard try await index.activeGeneration() != nil else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        let registryCountersBeforeSearch =
            registry.counters()
        guard registryCountersBeforeSearch.allSatisfy({
            $0.adapterInvocations == 0
                && $0.recordsRead == 0
        }) else {
            throw P8FSignedSmokeCoordinatorFailure
                .searchFailed
        }
        let allowedKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        guard let expectedGenerationSHA256 =
                writer.events.last(where: {
                    $0.metadata.scenario
                        == .successfulPublication
                        && $0.reasonCode
                            == .generationPublished
                })?.metadata.generationIdentifierSHA256
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        let searchQuery = "synthetic source authority"
        var unfilteredResultCounts:
            [SemanticSearchMode: Int] = [:]
        for mode in SemanticSearchMode.allCases {
            let outcome = try await awaitSignedSmokeSearch(
                controller: controller,
                request: .init(
                    query: searchQuery,
                    mode: mode
                )
            )
            let results = controller.semanticResults
            let leakageCanaryHits = results.filter {
                $0.matchedText.contains(
                    P8FSignedSmokeFixtureSeeder
                        .leakageCanary
                )
                    || $0.matchedText.contains(
                        P8FSignedSmokeFixtureSeeder
                            .hiddenReasoningCanary
                    )
            }.count
            guard outcome.state == .completed,
                  outcome.resultCount > 0,
                  outcome.resultCount == results.count,
                  outcome.generationIdentifier.map(
                      P8FSignedSmokeDigest.sha256
                  ) == expectedGenerationSHA256,
                  Set(outcome.sourceKinds)
                    .isSubset(of: allowedKinds),
                  Set(results.map(\.provenance.sourceKind))
                    == Set(outcome.sourceKinds),
                  resultsMatchFixtureManifest(
                    results,
                    manifest: seeded.manifest
                  ),
                  outcome.provenanceIdentifierSHA256s
                    == provenanceIdentifierSHA256s(
                        for: results
                    ),
                  leakageCanaryHits == 0
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .searchFailed
            }
            unfilteredResultCounts[mode] =
                outcome.resultCount
            _ = try writer.append(
                try eventDraft(
                    event: .search,
                    parentSpanID: rootSpanID(writer),
                    component: .retrieval,
                    status: .success,
                    reasonCode: .searchPassed,
                    scenario: searchScenario(for: mode),
                    searchMode: mode,
                    fixtureManifestSHA256:
                        seeded.manifest.canonicalSHA256,
                    generationIdentifierSHA256:
                        expectedGenerationSHA256,
                    artifactSHA256:
                        P8FSignedSmokeDigest.sha256(
                            outcome
                                .provenanceIdentifierSHA256s
                                .joined(separator: "\n")
                        ),
                    counters:
                        try P8FSignedSmokeCounters(
                            resultCount: outcome.resultCount,
                            leakageCanaryHits:
                                leakageCanaryHits
                        )
                )
            )
        }
        let narrowed = try await awaitSignedSmokeSearch(
            controller: controller,
            request: .init(
                query: searchQuery,
                mode: .lexical,
                filters: .init(sourceKinds: [.brief])
            )
        )
        let narrowedResults = controller.semanticResults
        let narrowedCanaryHits =
            narrowedResults.filter {
                $0.matchedText.contains(
                    P8FSignedSmokeFixtureSeeder
                        .leakageCanary
                )
                    || $0.matchedText.contains(
                        P8FSignedSmokeFixtureSeeder
                            .hiddenReasoningCanary
                    )
            }.count
        guard narrowed.state == .completed,
              narrowed.resultCount > 0,
              narrowed.resultCount
                < (unfilteredResultCounts[.lexical] ?? 0),
              narrowed.resultCount == narrowedResults.count,
              Set(narrowed.sourceKinds) == [.brief],
              resultsMatchFixtureManifest(
                narrowedResults,
                manifest: seeded.manifest
              ),
              narrowed.provenanceIdentifierSHA256s
                == provenanceIdentifierSHA256s(
                    for: narrowedResults
                ),
              narrowedCanaryHits == 0,
              narrowed.generationIdentifier.map(
                  P8FSignedSmokeDigest.sha256
              ) == expectedGenerationSHA256,
              controller.semanticSourceAuthorityEvents.contains(where: {
                  $0.name == .searchFilterNarrowed
                      && $0.sourceKinds
                        == [SemanticIndexSourceKind.brief.rawValue]
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure.searchFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .search,
                parentSpanID: rootSpanID(writer),
                component: .retrieval,
                status: .success,
                reasonCode: .searchFilterNarrowed,
                scenario: .searchNarrowing,
                searchMode: .lexical,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    expectedGenerationSHA256,
                artifactSHA256:
                    P8FSignedSmokeDigest.sha256(
                        narrowed
                            .provenanceIdentifierSHA256s
                            .joined(separator: "\n")
                    ),
                counters:
                    try P8FSignedSmokeCounters(
                        resultCount: narrowed.resultCount,
                        leakageCanaryHits:
                            narrowedCanaryHits
                    )
            )
        )
        let excluded = try await awaitSignedSmokeSearch(
            controller: controller,
            request: .init(
                query: searchQuery,
                mode: .lexical,
                filters:
                    .init(sourceKinds: [.vaultRecord])
            )
        )
        guard excluded.state == .completed,
              excluded.resultCount == 0,
              excluded.sourceKinds.isEmpty,
              excluded.provenanceIdentifierSHA256s.isEmpty,
              controller.semanticResults.isEmpty,
              excluded.generationIdentifier.map(
                  P8FSignedSmokeDigest.sha256
              ) == expectedGenerationSHA256,
              controller.semanticSourceAuthorityEvents.contains(where: {
                  $0.name
                      == .searchFilterSourceNotIndexed
                      && $0.sourceKinds
                        == [
                            SemanticIndexSourceKind
                                .vaultRecord.rawValue,
                        ]
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure.searchFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .search,
                parentSpanID: rootSpanID(writer),
                component: .retrieval,
                status: .success,
                reasonCode:
                    .excludedSourceFilterEmpty,
                scenario: .excludedSourceSearch,
                searchMode: .lexical,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    expectedGenerationSHA256,
                counters:
                    try P8FSignedSmokeCounters(
                        resultCount: 0,
                        leakageCanaryHits: 0
                )
            )
        )
        guard registry.counters()
                == registryCountersBeforeSearch
        else {
            throw P8FSignedSmokeCoordinatorFailure.searchFailed
        }
        await controller.closeForApplicationTermination()
    }

    private func runHydration(
        model: AppModel,
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try validatedFixture(writer: writer)
        try appendFixtureAccepted(
            seeded,
            writer: writer
        )
        let modelContext = try qwenContext(model: model)
        let dependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let registry = dependencyPackage.sourceRegistry
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: dependencyPackage
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: dependencyPackage,
            index: index,
            modelContext: modelContext
        )
        controller.refreshSemanticHealth()
        await controller.waitForCurrentWork()
        let qwenAssessment =
            modelContext.assessments[
                P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue
            ]
        let stability =
            qwenAssessment?.embeddingStability
        let expectedAdapterContracts = Dictionary(
            uniqueKeysWithValues:
                registry.providers()
                    .filter {
                        seeded.manifest
                            .canonicalSourceKinds
                            .contains($0.sourceKind)
                    }
                    .map {
                        (
                            $0.sourceKind,
                            $0.contractVersion
                        )
                    }
        )
        guard let active = try await index.activeGeneration(),
              active.state == .ready,
              active.staleReason == nil,
              active.sourceAuthorityState
                == .sourceScopeReady,
              controller.semanticHealth?.state == .ready,
              controller.semanticHealth?
                .activeGeneration?.identifier
                == active.identifier,
              active.spec.buildScope?.initiation
                == .signedSmokeRunner,
              active.spec.buildScope?.allowlistSHA256
                == seeded.manifest
                    .expectedSourceAllowlistSHA256,
              active.spec.buildScope?.sourceKinds
                == Set(
                    seeded.manifest
                        .canonicalSourceKinds
                ),
              active.spec.buildScope?
                .adapterContractVersions
                == expectedAdapterContracts,
              active.spec.embeddingModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue,
              active.spec.embeddingModelDigest
                == qwenAssessment?.modelDigest,
              active.spec.vectorDimension == 1_024,
              active.spec.ollamaRuntimeVersion
                == stability?.ollamaVersion,
              active.spec
                .embeddingRequestProfileVersion
                == stability?.requestProfileVersion,
              active.spec.embeddingRequestProfileHash
                == stability?.requestProfileHash,
              active.spec.embeddingDimensions
                == stability?.explicitDimensions,
              active.spec.embeddingTruncate
                == stability?.truncate,
              active.spec
                .embeddingNormalizationVersion
                == stability?.normalizationVersion,
              active.spec.chunkerVersion
                == SemanticTextChunker.version,
              active.spec.normalizationVersion
                == SemanticTextNormalizer.version,
              active.spec.sourceSchemaVersion
                == "loki_brief_v9"
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        let search = try await awaitSignedSmokeSearch(
            controller: controller,
            request: .init(query: "synthetic", mode: .lexical)
        )
        guard search.state == .completed,
              search.resultCount > 0,
              search.generationIdentifier
                == active.identifier,
              Set(search.sourceKinds).isSubset(
                  of: Set(
                      seeded.manifest
                        .canonicalSourceKinds
                  )
              )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode: .generationPublished,
                scenario: .restartHydration,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                sourceAllowlistSHA256:
                    seeded.manifest
                        .expectedSourceAllowlistSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        active.identifier
                    )
            )
        )
        await controller.closeForApplicationTermination()
        try await runHydrationProbeMatrix(
            modelContext: modelContext,
            writer: writer
        )
    }

    private func runHydrationProbeMatrix(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        try await runLegacyHydrationCase(
            modelContext: modelContext,
            writer: writer
        )
        try await runStaleHydrationCase(
            modelContext: modelContext,
            writer: writer
        )
        try await runMalformedHydrationCase(
            modelContext: modelContext,
            writer: writer
        )
    }

    private func runLegacyHydrationCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let probe = try await buildHydrationProbe(
            name: "legacy-hydration",
            modelContext: modelContext
        )
        let before =
            try P8FSignedSmokeHydrationFixtureFactory
                .downgradeToLegacyV2(
                    databaseURL: probe.databaseURL,
                    isolatedRoot:
                        bootstrap.isolatedRoot,
                    storageBoundary: storageBoundary,
                    active: probe.active
                )
        let dependencyPackage = try dependencyPackage(
            seeded: probe.seeded
        )
        let reopened = try openSemanticIndex(
            at: probe.databaseURL,
            dependencyPackage: dependencyPackage
        )
        guard let active =
                try await reopened.activeGeneration(),
              active.identifier
                == before.generationIdentifier,
              active.state == .stale,
              active.staleReason == .sourceScopeUnknown,
              active.sourceAuthorityState
                == .sourceScopeUnknown,
              active.spec.buildScope == nil,
              await allSearchModesFailClosed(
                  in: reopened,
                  active: active,
                  expected: .sourceScopeUnknown
              )
        else {
            await reopened.close()
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        await reopened.close()
        let after =
            try P8FSignedSmokeHydrationFixtureFactory
                .snapshot(
                    databaseURL: probe.databaseURL,
                    isolatedRoot:
                        bootstrap.isolatedRoot,
                    storageBoundary: storageBoundary
                )
        guard after.userVersion
                == SemanticIndexLimits.schemaVersion,
              after.generationIdentifier
                == before.generationIdentifier,
              after.sourceCount == before.sourceCount,
              after.chunkCount == before.chunkCount,
              after.tombstoneCount
                == before.tombstoneCount,
              after.vectorBlobSHA256
                == before.vectorBlobSHA256,
              after.sourceBindingSHA256
                == before.sourceBindingSHA256,
              after.highWatermarkSHA256
                == before.highWatermarkSHA256
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode:
                    .legacyGenerationPreserved,
                scenario: .legacyHydration,
                fixtureManifestSHA256:
                    probe.seeded.manifest
                        .canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        before.generationIdentifier
                    ),
                counters:
                    try P8FSignedSmokeCounters(
                        recordsAccepted:
                            before.sourceCount,
                        chunks: before.chunkCount,
                        indexWrites: before.chunkCount
                    )
            )
        )
    }

    private func runStaleHydrationCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let probe = try await buildHydrationProbe(
            name: "stale-hydration",
            modelContext: modelContext
        )
        let spec = probe.active.spec
        guard let scope = spec.buildScope,
              let modelIdentifier =
                spec.embeddingModelIdentifier,
              let modelDigest =
                spec.embeddingModelDigest,
              let vectorDimension =
                spec.vectorDimension,
              let ollamaRuntimeVersion =
                spec.ollamaRuntimeVersion,
              let requestProfileVersion =
                spec.embeddingRequestProfileVersion,
              let requestProfileHash =
                spec.embeddingRequestProfileHash,
              let embeddingTruncate =
                spec.embeddingTruncate,
              let normalizationVersion =
                spec.embeddingNormalizationVersion
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        let staleExpectedSpec =
            try SemanticIndexGenerationSpec(
                embeddingModelIdentifier:
                    modelIdentifier,
                embeddingModelDigest: modelDigest,
                vectorDimension: vectorDimension,
                ollamaRuntimeVersion:
                    ollamaRuntimeVersion,
                embeddingRequestProfileVersion:
                    requestProfileVersion,
                embeddingRequestProfileHash:
                    requestProfileHash,
                embeddingDimensions:
                    spec.embeddingDimensions,
                embeddingTruncate:
                    embeddingTruncate,
                embeddingNormalizationVersion:
                    normalizationVersion,
                chunkerVersion:
                    spec.chunkerVersion,
                normalizationVersion:
                    spec.normalizationVersion,
                sourceSchemaVersion:
                    "loki_brief_v9_stale_probe",
                buildScope: scope
            )
        let dependencyPackage = try dependencyPackage(
            seeded: probe.seeded
        )
        let reopened = try openSemanticIndex(
            at: probe.databaseURL,
            dependencyPackage: dependencyPackage
        )
        let health = try await reopened.health(
            expectedSpec: staleExpectedSpec
        )
        guard let active =
                try await reopened.activeGeneration(),
              active.identifier
                == probe.active.identifier,
              health.state == .stale,
              health.reasonCode
                == SemanticIndexStaleReason
                    .canonicalSourcePolicy.rawValue,
              active.state == .stale,
              active.staleReason
                == .canonicalSourcePolicy,
              await allSearchModesFailClosed(
                  in: reopened,
                  active: active,
                  expected: .generationStale
              )
        else {
            await reopened.close()
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        await reopened.close()
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode: .staleIdentityRejected,
                scenario: .staleHydration,
                fixtureManifestSHA256:
                    probe.seeded.manifest
                        .canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        active.identifier
                    )
            )
        )
    }

    private func runMalformedHydrationCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let probe = try await buildHydrationProbe(
            name: "malformed-hydration",
            modelContext: modelContext
        )
        _ =
            try P8FSignedSmokeHydrationFixtureFactory
                .downgradeToLegacyV2(
                    databaseURL: probe.databaseURL,
                    isolatedRoot:
                        bootstrap.isolatedRoot,
                    storageBoundary: storageBoundary,
                    active: probe.active
                )
        try P8FSignedSmokeHydrationFixtureFactory
            .corruptLegacyConfigurationFingerprint(
                databaseURL: probe.databaseURL,
                isolatedRoot: bootstrap.isolatedRoot,
                storageBoundary: storageBoundary,
                generationIdentifier:
                    probe.active.identifier
            )
        let before =
            try P8FSignedSmokeHydrationFixtureFactory
                .snapshot(
                    databaseURL: probe.databaseURL,
                    isolatedRoot:
                        bootstrap.isolatedRoot,
                    storageBoundary: storageBoundary
                )
        let rejected: Bool
        do {
            let dependencyPackage = try dependencyPackage(
                seeded: probe.seeded
            )
            let unexpectedlyOpened = try openSemanticIndex(
                at: probe.databaseURL,
                dependencyPackage: dependencyPackage
            )
            await unexpectedlyOpened.close()
            rejected = false
        } catch {
            rejected =
                error as? SemanticIndexFailureCode
                    == .databaseCorrupt
        }
        let after =
            try P8FSignedSmokeHydrationFixtureFactory
                .snapshot(
                    databaseURL: probe.databaseURL,
                    isolatedRoot:
                        bootstrap.isolatedRoot,
                    storageBoundary: storageBoundary
                )
        guard rejected,
              before == after,
              after.userVersion == 2
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode:
                    .malformedIdentityRejected,
                scenario: .malformedHydration,
                fixtureManifestSHA256:
                    probe.seeded.manifest
                        .canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        before.generationIdentifier
                    )
            )
        )
    }

    private func buildHydrationProbe(
        name: String,
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        )
    ) async throws -> (
        seeded: P8FSignedSmokeSeededFixture,
        databaseURL: URL,
        active: SemanticIndexGenerationMetadata
    ) {
        let seeded = try matrixFixture(name: name)
        let databaseURL = try semanticDatabaseURL(
            for: seeded.fixtureDirectory
        )
        let dependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let index = try openSemanticIndex(
            at: databaseURL,
            dependencyPackage: dependencyPackage
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: dependencyPackage,
            index: index,
            modelContext: modelContext
        )
        let outcome = try await awaitSignedSmokeRebuild(
            controller: controller,
            request: .init(
                sourceKinds:
                    Set(
                        seeded.manifest
                            .canonicalSourceKinds
                    ),
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: name
                    )
            )
        )
        guard outcome.state == .published,
              let active =
                try await index.activeGeneration(),
              active.identifier
                == outcome.generationIdentifier,
              active.state == .ready,
              active.sourceAuthorityState
                == .sourceScopeReady
        else {
            await controller
                .closeForApplicationTermination()
            throw P8FSignedSmokeCoordinatorFailure
                .hydrationFailed
        }
        await controller.closeForApplicationTermination()
        return (
            seeded: seeded,
            databaseURL: databaseURL,
            active: active
        )
    }

    private func allSearchModesFailClosed(
        in index: SemanticVaultIndex,
        active: SemanticIndexGenerationMetadata,
        expected: SemanticIndexFailureCode
    ) async -> Bool {
        var queryVector: [Float]?
        if let dimension = active.spec.vectorDimension {
            var vector = Array(
                repeating: Float(0),
                count: dimension
            )
            if !vector.isEmpty {
                vector[0] = 1
            }
            queryVector = vector
        }
        for mode in SemanticSearchMode.allCases {
            do {
                _ = try await index.search(
                    query: "synthetic source authority",
                    queryVector:
                        mode == .lexical
                        ? nil
                        : queryVector,
                    mode: mode
                )
                return false
            } catch {
                guard error as? SemanticIndexFailureCode
                        == expected
                else {
                    return false
                }
            }
        }
        return true
    }

    private func runCleanup(
        model: AppModel,
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try validatedFixture(writer: writer)
        try appendFixtureAccepted(
            seeded,
            writer: writer
        )
        let dependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: dependencyPackage
        )
        let semanticDatabaseURL = try semanticDatabaseURL(
            for: seeded.fixtureDirectory
        )
        let controller = try P8FeatureController(
            store: seeded.store,
            semanticIndex: index,
            semanticDatabaseURLOverride:
                semanticDatabaseURL,
            signedSmokeStorageBoundary:
                storageBoundary,
            signedSmokeRuntimeAuthority:
                bootstrap.admission.runtimeAuthority,
            signedSmokeDependencyPackage:
                dependencyPackage
        )
        let derivedDataDeleted = await controller
            .deleteAllP8DerivedAndCredentialData()
        let credentialSnapshot = await dependencyPackage
            .credentialCounters()
        guard derivedDataDeleted,
              credentialSnapshot == .init(
                    storeCount: 0,
                    readCount: 0,
                    deleteCount: 1
                ),
              [
                  semanticDatabaseURL.path,
                  semanticDatabaseURL.path + "-wal",
                  semanticDatabaseURL.path + "-shm",
              ].allSatisfy({
                  !fileManager.fileExists(atPath: $0)
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        try Task.checkCancellation()
        let selectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: bootstrap.isolatedRoot
            )
        let authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: bootstrap.isolatedRoot
            )
        guard try selectionStore.load() == nil,
              try authorityStore.load().isEmpty
        else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        let controlDirectory = bootstrap.isolatedRoot
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder
                    .controlDirectoryName,
                isDirectory: true
            )
        do {
            try dependencyPackage.removeBoundControlTree(
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        guard !fileManager.fileExists(
            atPath: controlDirectory.path
        ) else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        // Even the cleanup launch seals its empty provider generation before
        // terminalization, so no late request can race the final receipt.
        try appendProviderCorrelationEvidence(writer: writer)
        try Task.checkCancellation()
        _ = try writer.append(
            try eventDraft(
                event: .cleanup,
                parentSpanID: rootSpanID(writer),
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256
            )
        )
        var privacy = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: bootstrap.isolatedRoot
        )
        guard privacy.passed else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        try Task.checkCancellation()
        _ = try writer.append(
            try eventDraft(
                event: .privacy,
                parentSpanID: rootSpanID(writer),
                component: .privacyGuard,
                status: .success,
                reasonCode: .privacyPassed,
                scenario: .receiptPrivacy,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256
            )
        )
        try Task.checkCancellation()
        privacy = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: bootstrap.isolatedRoot
        )
        guard privacy.passed else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        let terminalPrivacy =
            try P8FSignedSmokePrivacySummary(
                artifactCount: privacy.artifactCount + 3
            )
        let terminal = try successfulTerminalReceipt(
            writer: writer,
            privacy: terminalPrivacy,
            fixtureManifestSHA256:
                seeded.manifest.canonicalSHA256
        )
        _ = model
        try publishSuccessfulTerminal(
            terminal,
            writer: writer
        )
    }

    /// All fallible audit and cancellation checks happen before the terminal
    /// envelope commit point. The envelope binds the final event, manifest,
    /// and artifact ledger; replicas are deterministically recoverable.
    func publishSuccessfulTerminal(
        _ terminal: P8FSignedSmokeTerminalReceipt,
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        let terminalArtifactPrivacy =
            try P8FSignedSmokePrivacyScanner
                .scanEncodedArtifact(
                    try P8FSignedSmokeJSON.encode(terminal)
                )
        guard terminalArtifactPrivacy.passed,
              terminalArtifactPrivacy.artifactCount == 1
        else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        let diagnosticManifest =
            try P8FSignedSmokeDiagnosticManifestReceipt
                .canonical(
                    traceID: writer.traceID,
                    events: writer.events
                )
        try P8FSignedSmokeDiagnosticManifestReceipt.validate(
            diagnosticManifest,
            against: writer.events
        )
        let diagnosticManifestData =
            try P8FSignedSmokeJSON.encode(diagnosticManifest)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                diagnosticManifestData,
                as: .diagnosticManifest
            )
        let diagnosticManifestPrivacy =
            try P8FSignedSmokePrivacyScanner
                .scanEncodedArtifact(
                    diagnosticManifestData
                )
        guard diagnosticManifestPrivacy.passed,
              diagnosticManifestPrivacy.artifactCount == 1
        else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        try P8FSignedSmokeReceiptArtifactValidator
            .validateReceiptDirectory(
                isolatedRoot: bootstrap.isolatedRoot,
                fileManager: fileManager
            )
        let precommitPrivacy =
            try P8FSignedSmokePrivacyScanner.scan(
                isolatedRoot: bootstrap.isolatedRoot
            )
        guard precommitPrivacy.passed,
              terminal.privacySummary.passed,
              precommitPrivacy.artifactCount + 3
                == terminal.privacySummary.artifactCount
        else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        try Task.checkCancellation()
        _ = try writer.commitTerminalReceipt(
            terminal,
            finalEventDraft: try eventDraft(
                event: .run,
                parentSpanID: rootSpanID(writer),
                component: .runner,
                status: .success,
                reasonCode: .runCompleted,
                scenario: .run
            )
        )
        invokePostDiagnosticManifestCommitXCTestHook()
    }

    private func runAtomicAdversarialMatrix(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        try await runBlockedMatrixCase(
            name: "cancellation",
            reasonCode: .cancelledBeforePublication,
            scenario: .cancellation,
            expectedState: .cancelled,
            modelContext: modelContext,
            writer: writer
        ) { controller in
            controller.cancelSemanticWork()
        }
        try await runBlockedMatrixCase(
            name: "revocation",
            reasonCode: .scopeRevokedBeforePublication,
            scenario: .revocation,
            expectedState: .cancelled,
            modelContext: modelContext,
            writer: writer
        ) { controller in
            controller.semanticBuildSourceKinds = []
        }
        try await runBlockedMatrixCase(
            name: "model-profile-drift",
            reasonCode: .modelProfileDrift,
            scenario: .modelProfileDrift,
            expectedState: .cancelled,
            modelContext: modelContext,
            writer: writer
        ) { controller in
            controller.synchronizeModelRoles([])
        }
        try await runAdapterDriftCase(
            modelContext: modelContext,
            writer: writer
        )
        try await runUnknownSourceKindCase(
            modelContext: modelContext,
            writer: writer
        )
        try await runFinalIntegrityCase(
            modelContext: modelContext,
            writer: writer
        )
    }

    private func runBlockedMatrixCase(
        name: String,
        reasonCode: P8FSignedSmokeReasonCode,
        scenario: P8FSignedSmokeScenario,
        expectedState:
            P8SignedSmokeSemanticRebuildTerminalState? = nil,
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter,
        mutate: (P8FeatureController) -> Void
    ) async throws {
        let seeded = try matrixFixture(name: name)
        let sourceKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        let priorDependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let priorIndex = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: priorDependencyPackage
        )
        let priorController = try semanticController(
            seeded: seeded,
            dependencyPackage: priorDependencyPackage,
            index: priorIndex,
            modelContext: modelContext
        )
        let priorOutcome = try await awaitSignedSmokeRebuild(
            controller: priorController,
            request: .init(
                sourceKinds: sourceKinds,
                requestTimestamp:
                    P8FSignedSmokeFixtureSeeder.anchor,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "\(name)_prior"
                    )
            )
        )
        guard priorOutcome.state == .published,
              let prior = try await priorIndex.activeGeneration()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        await priorController.closeForApplicationTermination()
        let blockedDependencyPackage = try dependencyPackage(
            seeded: seeded,
            sourceRegistryMode: .blockBeforeRead(.brief)
        )
        let blockedRegistry =
            blockedDependencyPackage.sourceRegistry
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: blockedDependencyPackage
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: blockedDependencyPackage,
            index: index,
            modelContext: modelContext
        )
        if scenario == .revocation {
            controller.refreshSemanticHealth()
            await controller.waitForCurrentWork()
            let baseline = try await awaitSignedSmokeSearch(
                controller: controller,
                request: .init(
                    query: "synthetic source authority",
                    mode: .lexical
                )
            )
            guard baseline.state == .completed,
                  baseline.resultCount > 0,
                  controller.semanticResults.count
                    == baseline.resultCount
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .atomicPublicationFailed
            }
        }
        let candidateReceiptIdentifier =
            authorizationReceiptIdentifier(
                suffix: "\(name)_candidate"
            )
        let task = Task {
            await controller.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: sourceKinds,
                    requestTimestamp:
                        P8FSignedSmokeFixtureSeeder.anchor,
                    authorizationReceiptIdentifier:
                        candidateReceiptIdentifier
                )
            )
        }
        let outcome: P8SignedSmokeSemanticRebuildOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await blockedRegistry.waitUntilBlocked(
                    sourceKind: .brief
                )
                try Task.checkCancellation()
                mutate(controller)
                try Task.checkCancellation()
                if scenario == .revocation {
                    guard controller.semanticResults.isEmpty,
                          controller.semanticBuildSourceKinds
                            .isEmpty,
                          controller.semanticHealth?.state
                            == .stale,
                          controller.semanticHealth?.reasonCode
                            == SemanticIndexStaleReason
                                .sourcePermissionRevoked.rawValue
                    else {
                        throw P8FSignedSmokeCoordinatorFailure
                            .atomicPublicationFailed
                    }
                }
                if scenario == .modelProfileDrift {
                    guard controller.semanticResults.isEmpty,
                          controller.semanticHealth?.state
                            == .stale,
                          controller.semanticHealth?.reasonCode
                            == SemanticIndexStaleReason
                                .embeddingRuntimeProfile.rawValue
                    else {
                        throw P8FSignedSmokeCoordinatorFailure
                            .atomicPublicationFailed
                    }
                }
                blockedRegistry.releaseBlockedProvider()
                let completed = await task.value
                await controller.waitForCurrentWork()
                if Task.isCancelled {
                    if completed.state == .failed
                        || completed.state == .rejected {
                        throw P8FSignedSmokeCoordinatorFailure
                            .atomicPublicationFailed
                    }
                    throw CancellationError()
                }
                return completed
            } onCancel: {
                task.cancel()
                Task { @MainActor in
                    blockedRegistry
                        .cancelBlockedWaitAndReleaseProvider()
                }
            }
        } catch {
            task.cancel()
            blockedRegistry.cancelBlockedWaitAndReleaseProvider()
            let completed = await task.value
            await controller.waitForCurrentWork()
            await controller.closeForApplicationTermination()
            if Self.isCancellation(error),
               completed.state == .failed
                || completed.state == .rejected {
                throw P8FSignedSmokeCoordinatorFailure
                    .atomicPublicationFailed
            }
            throw error
        }
        let active = try await index.activeGeneration()
        guard outcome.state != .published,
              expectedState.map({ outcome.state == $0 })
                ?? true,
              expectedState == nil
                || outcome.reasonCode
                    == "semantic_rebuild_cancelled",
              active?.identifier == prior.identifier,
              scenario != .modelProfileDrift
                || (
                    active?.state == .stale
                        && active?.staleReason
                            == .embeddingRuntimeProfile
                )
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        if expectedState == .cancelled {
            let cancellationEvents =
                controller.semanticSourceAuthorityEvents.filter {
                    $0.name == .rebuildCancelled
                        && $0.authorizationReceiptIdentifier
                            == candidateReceiptIdentifier
                        && $0.status == "cancelled"
                }
            guard cancellationEvents.count == 1 else {
                throw P8FSignedSmokeCoordinatorFailure
                    .atomicPublicationFailed
            }
        }
        if scenario == .revocation {
            let rejectedSearch = try await awaitSignedSmokeSearch(
                controller: controller,
                request: .init(
                    query: "synthetic source authority",
                    mode: .lexical
                )
            )
            guard rejectedSearch.state != .completed,
                  rejectedSearch.resultCount == 0,
                  controller.semanticResults.isEmpty,
                  controller
                    .semanticSourceAuthorityEvents
                    .contains(where: {
                        $0.name
                            == .generationPermissionRevoked
                            && $0.generationIdentifier
                                == prior.identifier
                            && $0.status == "blocked"
                    })
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .atomicPublicationFailed
            }
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: Self.receiptStatus(
                    forAtomicState: outcome.state
                ),
                reasonCode: reasonCode,
                scenario: scenario,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        prior.identifier
                    )
            )
        )
    }

    private func runUnknownSourceKindCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try matrixFixture(
            name: "unknown-source-kind"
        )
        let sourceKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        let priorDependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let priorIndex = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: priorDependencyPackage
        )
        let priorController = try semanticController(
            seeded: seeded,
            dependencyPackage: priorDependencyPackage,
            index: priorIndex,
            modelContext: modelContext
        )
        let priorOutcome = try await awaitSignedSmokeRebuild(
            controller: priorController,
            request: .init(
                sourceKinds: sourceKinds,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "unknown_prior"
                    )
            )
        )
        guard priorOutcome.state == .published,
              let prior = try await priorIndex.activeGeneration()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        await priorController.closeForApplicationTermination()
        let candidateRegistry = try dependencyPackage(
            seeded: seeded
        ).sourceRegistry
        let rawKinds =
            seeded.manifest.canonicalSourceKinds
                .map(\.rawValue)
                + ["future_private_source"]
        let candidate =
            P8SignedSmokeSemanticRebuildRequest(
                rawSourceKinds: rawKinds,
                requestTimestamp:
                    P8FSignedSmokeFixtureSeeder.anchor,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "unknown_candidate"
                    )
            )
        guard candidate == nil,
              candidateRegistry.counters().allSatisfy({
                  $0.adapterInvocations == 0
                      && $0.recordsRead == 0
              }),
              try await priorIndex.activeGeneration()?.identifier
                == prior.identifier
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .sourceAuthority,
                parentSpanID: rootSpanID(writer),
                component: .semanticSourceAuthority,
                status: .success,
                reasonCode: .unknownSourceKindRejected,
                scenario: .unknownSourceKind,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        prior.identifier
                    )
            )
        )
    }

    private func runAdapterDriftCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try matrixFixture(name: "adapter-drift")
        let sourceKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        let goodDependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let goodIndex = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: goodDependencyPackage
        )
        let good = try semanticController(
            seeded: seeded,
            dependencyPackage: goodDependencyPackage,
            index: goodIndex,
            modelContext: modelContext
        )
        let priorOutcome = try await awaitSignedSmokeRebuild(
            controller: good,
            request: .init(
                sourceKinds: sourceKinds,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "adapter_prior"
                    )
            )
        )
        guard priorOutcome.state == .published,
              let prior = try await goodIndex.activeGeneration()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        await good.closeForApplicationTermination()
        let driftDependencyPackage = try dependencyPackage(
            seeded: seeded,
            sourceRegistryMode: .adapterKindDrift(
                expected: .brief,
                actual: .slackRecord
            )
        )
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: driftDependencyPackage
        )
        let drift = try semanticController(
            seeded: seeded,
            dependencyPackage: driftDependencyPackage,
            index: index,
            modelContext: modelContext
        )
        let outcome = try await awaitSignedSmokeRebuild(
            controller: drift,
            request: .init(
                sourceKinds: sourceKinds,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "adapter_candidate"
                    )
            )
        )
        guard outcome.state == .failed,
              try await index.activeGeneration()?.identifier
                == prior.identifier
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .sourceAdapter,
                parentSpanID: rootSpanID(writer),
                component: .semanticSourceAuthority,
                status: .success,
                reasonCode: .adapterContractDrift,
                scenario: .adapterContractDrift,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        prior.identifier
                    )
            )
        )
    }

    private func runFinalIntegrityCase(
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        ),
        writer: P8FSignedSmokeReceiptWriter
    ) async throws {
        let seeded = try matrixFixture(name: "final-integrity")
        let sourceKinds = Set(
            seeded.manifest.canonicalSourceKinds
        )
        let dependencyPackage = try dependencyPackage(
            seeded: seeded
        )
        let index = try semanticIndex(
            for: seeded.fixtureDirectory,
            dependencyPackage: dependencyPackage,
            profile:
                .rejectSuccessorPublicationForIntegrityDiagnostic
        )
        let controller = try semanticController(
            seeded: seeded,
            dependencyPackage: dependencyPackage,
            index: index,
            modelContext: modelContext
        )
        let priorOutcome = try await awaitSignedSmokeRebuild(
            controller: controller,
            request: .init(
                sourceKinds: sourceKinds,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "integrity_prior"
                    )
            )
        )
        guard priorOutcome.state == .published,
              let prior = try await index.activeGeneration()
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        let outcome = try await awaitSignedSmokeRebuild(
            controller: controller,
            request: .init(
                sourceKinds: sourceKinds,
                authorizationReceiptIdentifier:
                    authorizationReceiptIdentifier(
                        suffix: "integrity_candidate"
                    )
            )
        )
        guard outcome.state == .failed,
              try await index.activeGeneration()?.identifier
                == prior.identifier
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .atomicPublicationFailed
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode: .transactionIntegrityFailed,
                scenario: .transactionIntegrity,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                generationIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        prior.identifier
                    )
            )
        )
    }

    private func qwenContext(
        model: AppModel
    ) throws -> (
        assignments: [ModelRoleAssignment],
        assessments: [String: ModelCapabilityAssessment]
    ) {
        guard let chat = model.chatController,
              let assignment =
                chat.modelRoleAssignments.first(
                    where: { $0.role == .embedding }
                ),
              assignment.effectiveModelIdentifier
                == P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue,
              assignment.readiness == .ready,
              assignment.executionFailure == nil,
              let assessment = chat.modelAssessment(
                for: P8FSignedSmokeApprovedModel
                    .qwenEmbedding.rawValue
              ),
              let stability = assessment.embeddingStability,
              stability.accepted,
              stability.observedDimension == 1_024
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        return (
            assignments: chat.modelRoleAssignments,
            assessments: [
                assessment.modelIdentifier: assessment,
            ]
        )
    }

    private func semanticController(
        seeded: P8FSignedSmokeSeededFixture,
        dependencyPackage:
            P8FSignedSmokeDependencyPackage,
        index: SemanticVaultIndex,
        modelContext: (
            assignments: [ModelRoleAssignment],
            assessments: [String: ModelCapabilityAssessment]
        )
    ) throws -> P8FeatureController {
        let controller = try P8FeatureController(
            store: seeded.store,
            semanticIndex: index,
            semanticDatabaseURLOverride:
                try semanticDatabaseURL(
                    for: seeded.fixtureDirectory
                ),
            signedSmokeStorageBoundary:
                storageBoundary,
            signedSmokeRuntimeAuthority:
                bootstrap.admission.runtimeAuthority,
            signedSmokeDependencyPackage:
                dependencyPackage
        )
        controller.synchronizeModelRoles(
            modelContext.assignments,
            assessmentsByModelID:
                modelContext.assessments
        )
        return controller
    }

    private func dependencyPackage(
        seeded: P8FSignedSmokeSeededFixture,
        sourceRegistryMode:
            P8FSignedSmokeSourceRegistryMode = .normal,
        contractVersionOverrides:
            [SemanticIndexSourceKind: String] = [:],
        embeddingCapability:
            P8FSignedSmokeEmbeddingCapability = .native
    ) throws -> P8FSignedSmokeDependencyPackage {
        let package = try P8FSignedSmokeDependencyPackage.makeAppOwned(
            store: seeded.store,
            storageBoundary: storageBoundary,
            runtimeAuthority:
                bootstrap.admission.runtimeAuthority,
            sourceRegistryMode: sourceRegistryMode,
            contractVersionOverrides:
                contractVersionOverrides,
            embeddingCapability: embeddingCapability
        )
        controlTreeCleanupPackage = package
        return package
    }

    private func awaitSignedSmokeRebuild(
        controller: P8FeatureController,
        request: P8SignedSmokeSemanticRebuildRequest
    ) async throws -> P8SignedSmokeSemanticRebuildOutcome {
        let outcome = await controller
            .rebuildSemanticIndexForSignedSmoke(request)
        if outcome.state == .cancelled {
            await controller.waitForCurrentWork()
            await controller.closeForApplicationTermination()
            throw CancellationError()
        }
        return outcome
    }

    private func awaitSignedSmokeSearch(
        controller: P8FeatureController,
        request: P8SignedSmokeSemanticSearchRequest
    ) async throws -> P8SignedSmokeSemanticSearchOutcome {
        let outcome = await controller
            .searchSemanticIndexForSignedSmoke(request)
        if outcome.state == .cancelled {
            await controller.waitForCurrentWork()
            await controller.closeForApplicationTermination()
            throw CancellationError()
        }
        if outcome.state == .completed,
           Task.isCancelled {
            await controller.waitForCurrentWork()
            await controller.closeForApplicationTermination()
            throw CancellationError()
        }
        return outcome
    }

    private func semanticIndex(
        for fixtureDirectory: URL,
        dependencyPackage: P8FSignedSmokeDependencyPackage,
        profile:
            P8FSignedSmokeSemanticIndexConstructionProfile = .runtime
    ) throws -> SemanticVaultIndex {
        let databaseURL = try semanticDatabaseURL(
            for: fixtureDirectory
        )
        return try openSemanticIndex(
            at: databaseURL,
            dependencyPackage: dependencyPackage,
            profile: profile
        )
    }

    private func openSemanticIndex(
        at databaseURL: URL,
        dependencyPackage: P8FSignedSmokeDependencyPackage,
        profile:
            P8FSignedSmokeSemanticIndexConstructionProfile = .runtime
    ) throws -> SemanticVaultIndex {
        try storageBoundary.validateSQLiteFamily(
            at: databaseURL,
            requireDatabase: false,
            fileManager: fileManager
        )
        let index = try dependencyPackage.makeAndBindSemanticIndex(
            at: databaseURL,
            profile: profile
        )
        try storageBoundary.secureSQLiteFamily(
            at: databaseURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        return index
    }

    private func semanticDatabaseURL(
        for fixtureDirectory: URL
    ) throws -> URL {
        let directory = fixtureDirectory
            .appendingPathComponent(
                "Semantic",
                isDirectory: true
            )
            .appendingPathComponent(
                "v1",
                isDirectory: true
            )
        try storageBoundary.ensurePrivateDirectory(
            at: directory,
            fileManager: fileManager
        )
        let databaseURL = directory.appendingPathComponent(
            "loki-semantic.sqlite3",
            isDirectory: false
        )
        try storageBoundary.validateSQLiteFamily(
            at: databaseURL,
            requireDatabase: false,
            fileManager: fileManager
        )
        return databaseURL
    }

    private func validatedFixture(
        writer: P8FSignedSmokeReceiptWriter
    )
        throws -> P8FSignedSmokeSeededFixture
    {
        let fixtureDirectory = bootstrap.isolatedRoot
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder
                    .controlDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder
                    .fixtureDirectoryName,
                isDirectory: true
            )
        let retainedFixtureExpected =
            writer.events.contains {
                $0.status == .success
                    && $0.event == .fixture
                    && $0.reasonCode == .fixtureAccepted
                    && $0.metadata.fixtureManifestSHA256
                        == P8FSignedSmokeFixtureManifest
                            .expectedCanonicalSHA256
            }
        let fixtureExists = fileManager.fileExists(
            atPath: fixtureDirectory.path
        )
        let seeded: P8FSignedSmokeSeededFixture
        switch (retainedFixtureExpected, fixtureExists) {
        case (false, false):
            seeded = try P8FSignedSmokeFixtureSeeder.seed(
                isolatedRoot: bootstrap.isolatedRoot,
                storageBoundary: storageBoundary
            )
        case (true, true):
            seeded = try P8FSignedSmokeFixtureSeeder.reopen(
                isolatedRoot: bootstrap.isolatedRoot,
                storageBoundary: storageBoundary
            )
        case (false, true), (true, false):
            throw P8FSignedSmokeCoordinatorFailure
                .fixtureMismatch
        }
        guard bootstrap.admission.controlPlan
                .expectedFixtureManifestSHA256
                == P8FSignedSmokeFixtureManifest
                    .expectedCanonicalSHA256,
              seeded.manifest.canonicalSHA256
                == P8FSignedSmokeFixtureManifest
                    .expectedCanonicalSHA256,
              seeded.manifest.expectedSourceAllowlistSHA256
                == P8FSignedSmokeFixtureManifest
                    .expectedSourceAllowlistSHA256
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .fixtureMismatch
        }
        _ = try dependencyPackage(seeded: seeded)
        try invokePostFixtureCleanupPackageInstallationXCTestHook()
        try Task.checkCancellation()
        return seeded
    }

    private func appendFixtureAccepted(
        _ seeded: P8FSignedSmokeSeededFixture,
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        _ = try writer.append(
            try eventDraft(
                event: .fixture,
                parentSpanID: rootSpanID(writer),
                component: .persistence,
                status: .success,
                reasonCode: .fixtureAccepted,
                scenario: .sourceAuthority,
                artifactClassification: .fixtureManifest,
                fixtureManifestSHA256:
                    seeded.manifest.canonicalSHA256,
                artifactSHA256:
                    seeded.manifest.canonicalSHA256
            )
        )
    }

    private func matrixFixture(
        name: String
    ) throws -> P8FSignedSmokeSeededFixture {
        let root = bootstrap.isolatedRoot
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder
                    .controlDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                "Adverse",
                isDirectory: true
            )
            .appendingPathComponent(
                name,
                isDirectory: true
            )
        try storageBoundary.ensurePrivateDirectory(
            at: root,
            fileManager: fileManager
        )
        let seeded = try P8FSignedSmokeFixtureSeeder.seed(
            isolatedRoot: root,
            storageBoundary: storageBoundary
        )
        guard seeded.manifest.canonicalSHA256
                == P8FSignedSmokeFixtureManifest
                    .expectedCanonicalSHA256
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .fixtureMismatch
        }
        return seeded
    }

    private func persistFailure(
        _ failure: P8FSignedSmokeCoordinatorFailure,
        writer: P8FSignedSmokeReceiptWriter,
        additionalPrivacySummary:
            P8FSignedSmokePrivacySummary? = nil
    ) throws {
        try appendCommittedPublicationEvidenceIfNeeded(
            writer: writer
        )
        if writer.events.isEmpty {
            _ = try writer.append(
                try eventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    runtimeIdentitySHA256:
                        P8FSignedSmokeDigest.sha256(
                            bootstrap.admission.controlPlan
                                .runIdentifier
                        )
                )
            )
        }
        if failure == .cleanupFailed,
           !writer.events.contains(where: {
               $0.event == .cleanup
                   && $0.status == .failed
                   && $0.reasonCode == .cleanupFailed
           }) {
            _ = try writer.append(
                try eventDraft(
                    event: .cleanup,
                    parentSpanID: rootSpanID(writer),
                    component: .cleanup,
                    status: .failed,
                    reasonCode: .cleanupFailed,
                    scenario: .cleanup
                )
            )
        }
        let terminalReasonCode: P8FSignedSmokeReasonCode =
            switch failure {
            case .cleanupFailed:
                .cleanupFailed
            case .privacyFailed:
                .privacyFailed
            case .receiptFailed:
                .receiptPersistenceFailed
            default:
                .runFailed
            }
        let finalEventDraft = try eventDraft(
            event: .run,
            parentSpanID: rootSpanID(writer),
            component: .runner,
            status: .failed,
            reasonCode: terminalReasonCode,
            scenario: .run,
            artifactSHA256:
                P8FSignedSmokeDigest.sha256(
                    failure.rawValue
                )
        )
        var privacy: P8FSignedSmokePrivacySummary
        if let scanned = try? P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: bootstrap.isolatedRoot
        ) {
            privacy = scanned
        } else {
            privacy = try P8FSignedSmokePrivacySummary(
                artifactCount: 0,
                forbiddenFieldCount: 1
            )
        }
        if let additionalPrivacySummary {
            privacy = try mergedPrivacySummary(
                privacy,
                additionalPrivacySummary
            )
        }
        privacy = try P8FSignedSmokePrivacySummary(
            artifactCount: privacy.artifactCount + 3,
            forbiddenFieldCount:
                privacy.forbiddenFieldCount,
            forbiddenValueCount:
                privacy.forbiddenValueCount,
            rawVectorCount: privacy.rawVectorCount,
            rawContentCount: privacy.rawContentCount,
            rawPromptCount: privacy.rawPromptCount,
            rawResponseCount: privacy.rawResponseCount,
            hiddenReasoningCount:
                privacy.hiddenReasoningCount,
            privatePathCount: privacy.privatePathCount,
            credentialCount: privacy.credentialCount
        )
        let startedAt =
            writer.events.first?.timestamp ?? Date()
        let terminal = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .failed,
            reasonCode: terminalReasonCode,
            startedAt: startedAt,
            completedAt: max(Date(), startedAt),
            applicationIdentity:
                bootstrap.applicationIdentity,
            admissionAccepted: terminalAdmissionState(
                events: writer.events
            ),
            privacySummary: privacy
        )
        _ = try writer.commitTerminalReceipt(
            terminal,
            finalEventDraft: finalEventDraft
        )
    }

    private func appendCommittedPublicationEvidenceIfNeeded(
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        guard let evidence = committedPublicationEvidence else {
            return
        }
        guard let generationIdentifierSHA256 =
                evidence.generationIdentifierSHA256
        else {
            // A published outcome without an identifier cannot support a
            // truthful terminal receipt. Refuse terminalization instead of
            // emitting a sparse failed receipt that hides publication.
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        if writer.events.contains(where: {
            $0.event == .generation
                && $0.status == .success
                && $0.reasonCode == .generationPublished
                && $0.metadata.scenario == .successfulPublication
                && $0.metadata.generationIdentifierSHA256
                    == generationIdentifierSHA256
        }) {
            return
        }
        _ = try writer.append(
            try eventDraft(
                event: .generation,
                parentSpanID: rootSpanID(writer),
                component: .semanticIndex,
                status: .success,
                reasonCode: .generationPublished,
                scenario: .successfulPublication,
                fixtureManifestSHA256:
                    evidence.fixtureManifestSHA256,
                sourceAllowlistSHA256:
                    evidence.sourceAllowlistSHA256,
                generationIdentifierSHA256:
                    generationIdentifierSHA256,
                authorizationReceiptIdentifierSHA256:
                    evidence.authorizationReceiptIdentifierSHA256,
                counters: evidence.counters
            )
        )
    }

    private func appendCancellationCausalEvent(
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        if writer.events.isEmpty {
            _ = try writer.append(
                try eventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    runtimeIdentitySHA256:
                        P8FSignedSmokeDigest.sha256(
                            bootstrap.admission.controlPlan
                                .runIdentifier
                        )
                )
            )
        }
        guard !writer.events.contains(where: {
            $0.event == .run
                && $0.status == .started
                && $0.reasonCode
                    == .runCancellationObserved
        }) else {
            return
        }
        _ = try writer.append(
            try eventDraft(
                event: .run,
                parentSpanID: rootSpanID(writer),
                component: .runner,
                status: .started,
                reasonCode: .runCancellationObserved,
                scenario: .run
            )
        )
    }

    private func reconcileProviderCorrelationForCancellation(
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        let sealedEvidence: P8FProviderRequestEvidenceSeal
        do {
            sealedEvidence = try sealProviderEvidence()
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        let observations = sealedEvidence.observations
        guard observations.enumerated().allSatisfy({
                  $0.element.sequence == UInt64($0.offset + 1)
              }),
              observations.last?.sequence
                ?? 0 == sealedEvidence.latestSequence,
              Set(
                  observations.map(\.requestIdentifierSHA256)
              ).count == observations.count,
              observations.allSatisfy({ observation in
                  observation.processIdentifier > 0
                      && observation.executableSHA256
                        == bootstrap.applicationIdentity
                            .executableSHA256
                      && observation.endpointPolicyClassification
                        == .ollamaModelIPv4Loopback
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }

        if !observations.isEmpty {
            try appendProviderCorrelationEvidence(
                writer: writer
            )
        }

        let resealed: P8FProviderRequestEvidenceSeal
        do {
            resealed = try P8FProviderRequestCorrelationRecorder
                .shared
                .sealEvidence(for: sealedEvidence.run)
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        guard resealed == sealedEvidence,
              observations.allSatisfy({ observation in
                  writer.events.filter { event in
                      event.event == .network
                          && event.metadata
                            .providerRequestIdentifierSHA256
                            == observation
                                .requestIdentifierSHA256
                          && event.metadata
                            .providerRequestTraceSHA256
                            == observation.requestTraceSHA256
                          && event.metadata.processIdentifier
                            == Int(observation.processIdentifier)
                          && event.metadata.executableSHA256
                            == observation.executableSHA256
                          && event.metadata.providerKind
                            == observation.providerKind
                          && event.metadata
                            .providerOperationKind
                            == observation.operationKind
                          && event.metadata.providerOutcome
                            == observation.outcome
                          && event.metadata.endpointClassification
                            == .ollamaModelIPv4Loopback
                  }.count == 1
              })
        else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
    }

    private func containCancelledRun(
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        if writer.events.contains(where: {
            $0.event == .cleanup
                && $0.status == .success
                && $0.reasonCode == .cleanupPassed
        }) {
            try requireContainedProviderCorrelationForCancellation()
            return
        }
        guard let controlTreeCleanupPackage else {
            throw P8FSignedSmokeCoordinatorFailure
                .cleanupFailed
        }
        do {
            try controlTreeCleanupPackage
                .clearBoundSemanticAuthorityStores()
            try controlTreeCleanupPackage.removeBoundControlTree(
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeCoordinatorFailure
                .cleanupFailed
        }
        try requireContainedProviderCorrelationForCancellation()
        _ = try writer.append(
            try eventDraft(
                event: .cleanup,
                parentSpanID: rootSpanID(writer),
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup
            )
        )
    }

    private func requireContainedProviderCorrelationForCancellation()
        throws
    {
        guard let providerEvidenceSeal else {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
        do {
            guard try P8FProviderRequestCorrelationRecorder
                .shared
                .sealEvidence(for: providerEvidenceSeal.run)
                    == providerEvidenceSeal
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .cleanupFailed
            }
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.cleanupFailed
        }
    }

    private func persistCancellation(
        writer: P8FSignedSmokeReceiptWriter,
        injectedPrivacyArtifact: Data?
    ) throws {
        if let injectedPrivacyArtifact {
            let injectedSummary =
                try P8FSignedSmokePrivacyScanner
                    .scanEncodedArtifact(
                        injectedPrivacyArtifact
                    )
            guard injectedSummary.passed else {
                throw InjectedCancellationPrivacyFailure(
                    summary: injectedSummary
                )
            }
        }
        let scannedPrivacy = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: bootstrap.isolatedRoot
        )
        guard scannedPrivacy.passed else {
            throw P8FSignedSmokeCoordinatorFailure.privacyFailed
        }
        let privacy = try P8FSignedSmokePrivacySummary(
            artifactCount: scannedPrivacy.artifactCount + 3
        )
        let startedAt = writer.events.first?.timestamp ?? Date()
        let terminal = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .cancelled,
            reasonCode: .runCancelled,
            startedAt: startedAt,
            completedAt: max(Date(), startedAt),
            applicationIdentity:
                bootstrap.applicationIdentity,
            admissionAccepted: terminalAdmissionState(
                events: writer.events
            ),
            cleanupPassed:
                writer.events.contains {
                    $0.event == .cleanup
                        && $0.status == .success
                        && $0.reasonCode == .cleanupPassed
                },
            privacySummary: privacy
        )
        _ = try writer.commitTerminalReceipt(
            terminal,
            finalEventDraft: try eventDraft(
                event: .run,
                parentSpanID: rootSpanID(writer),
                component: .runner,
                status: .cancelled,
                reasonCode: .runCancelled,
                scenario: .run
            )
        )
    }

    private func mergedPrivacySummary(
        _ first: P8FSignedSmokePrivacySummary,
        _ second: P8FSignedSmokePrivacySummary
    ) throws -> P8FSignedSmokePrivacySummary {
        try .init(
            artifactCount:
                first.artifactCount + second.artifactCount,
            forbiddenFieldCount:
                first.forbiddenFieldCount
                    + second.forbiddenFieldCount,
            forbiddenValueCount:
                first.forbiddenValueCount
                    + second.forbiddenValueCount,
            rawVectorCount:
                first.rawVectorCount + second.rawVectorCount,
            rawContentCount:
                first.rawContentCount + second.rawContentCount,
            rawPromptCount:
                first.rawPromptCount + second.rawPromptCount,
            rawResponseCount:
                first.rawResponseCount + second.rawResponseCount,
            hiddenReasoningCount:
                first.hiddenReasoningCount
                    + second.hiddenReasoningCount,
            privatePathCount:
                first.privatePathCount + second.privatePathCount,
            credentialCount:
                first.credentialCount + second.credentialCount
        )
    }

    private func terminalAdmissionState(
        events: [P8FSignedSmokeEvent]
    ) -> Bool? {
        if events.contains(where: {
            $0.event == .admission
                && $0.status == .success
                && $0.reasonCode == .admissionAccepted
        }) {
            return true
        }
        if events.contains(where: {
            $0.event == .admission
                && $0.status == .failed
                && $0.reasonCode == .admissionRejected
        }) {
            return false
        }
        return nil
    }

    private func successfulTerminalReceipt(
        writer: P8FSignedSmokeReceiptWriter,
        privacy: P8FSignedSmokePrivacySummary,
        fixtureManifestSHA256: String
    ) throws -> P8FSignedSmokeTerminalReceipt {
        let events = writer.events
        try P8FSignedSmokePrerequisiteValidator.validate(
            .cleanup,
            events: events
        )
        let successes = events.filter {
            $0.status == .success
        }
        let publication = successes.last {
            $0.metadata.scenario == .successfulPublication
                && $0.reasonCode == .generationPublished
        }
        let source = successes.last {
            $0.metadata.scenario == .sourceAuthority
                && $0.reasonCode == .sourceScopeAuthorized
        }
        let fixture = successes.last {
            $0.event == .fixture
                && $0.reasonCode == .fixtureAccepted
                && $0.metadata.fixtureManifestSHA256
                    == fixtureManifestSHA256
        }
        let gemma = successes.last {
            $0.metadata.scenario == .gemma4
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.model == .gemma4
        }
        let gpt = successes.last {
            $0.metadata.scenario == .gptOSS
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.model == .gptOSS
        }
        let qwen = successes.last {
            $0.metadata.scenario == .qwenEmbedding
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.model == .qwenEmbedding
                && $0.metadata.vectorDimension == 1_024
        }
        let admissionAccepted = successes.contains {
            $0.event == .admission
                && $0.reasonCode == .admissionAccepted
        }
        let storageAccepted = successes.contains {
            $0.event == .storageIsolation
                && $0.reasonCode == .storageSelected
        }
        let searchEvents = successes.filter {
            $0.event == .search
                && $0.reasonCode == .searchPassed
                && $0.metadata
                    .generationIdentifierSHA256
                    == publication?.metadata
                        .generationIdentifierSHA256
        }
        let searchPassed =
            SemanticSearchMode.allCases.allSatisfy {
                mode in
                searchEvents.contains {
                    $0.metadata.searchMode == mode
                        && $0.metadata.counters?
                            .resultCount ?? 0 > 0
                        && $0.metadata.counters?
                            .leakageCanaryHits == 0
                        && $0.metadata.artifactSHA256 != nil
                }
            }
        let hydrationPassed = [
            (
                P8FSignedSmokeScenario.restartHydration,
                P8FSignedSmokeReasonCode.generationPublished
            ),
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
        ].allSatisfy { expected in
            successes.contains {
                $0.metadata.scenario == expected.0
                    && $0.reasonCode == expected.1
            }
        }
        let cleanupPassed = successes.contains {
            $0.event == .cleanup
                && $0.metadata.scenario == .cleanup
                && $0.reasonCode == .cleanupPassed
        }
        let privacyPassed = successes.contains {
            $0.event == .privacy
                && $0.metadata.scenario
                    == .receiptPrivacy
                && $0.reasonCode == .privacyPassed
        }
        let providerEvents = events.filter {
            $0.event == .network
                && $0.metadata.model != nil
        }
        let providerIdentifiers = providerEvents.compactMap {
            $0.metadata.providerRequestIdentifierSHA256
        }
        let providerEvidenceBoundToAdmittedExecutable =
            !providerEvents.isEmpty
                && providerEvents.allSatisfy {
                    $0.metadata.hasCompleteProviderCorrelation
                        && $0.metadata.executableSHA256
                            == bootstrap.applicationIdentity
                                .executableSHA256
                        && $0.metadata.endpointClassification
                            == .ollamaModelIPv4Loopback
                        && $0.metadata.artifactSHA256 != nil
                        && !$0.metadata
                            .hasCompleteExternalObservation
                }
                && providerIdentifiers.count
                    == providerEvents.count
                && Set(providerIdentifiers).count
                    == providerIdentifiers.count
        guard let publication,
              let source,
              let fixture,
              let gemma,
              let gpt,
              let qwen,
              let sourceAllowlistSHA256 =
                source.metadata.sourceAllowlistSHA256,
              let authorizationSHA256 =
                source.metadata
                    .authorizationReceiptIdentifierSHA256,
              let generationSHA256 =
                publication.metadata
                    .generationIdentifierSHA256,
              let model = qwen.metadata.model,
              let modelDigest = qwen.metadata.modelDigest,
              let sourceCounters =
                source.metadata.counters,
              admissionAccepted,
              storageAccepted,
              searchPassed,
              hydrationPassed,
              cleanupPassed,
              privacyPassed,
              providerEvidenceBoundToAdmittedExecutable,
              privacy.passed,
              fixture.metadata.fixtureManifestSHA256
                == fixtureManifestSHA256,
              fixtureManifestSHA256
                == P8FSignedSmokeFixtureManifest
                    .expectedCanonicalSHA256,
              publication.metadata.fixtureManifestSHA256
                == fixtureManifestSHA256,
              publication.metadata.sourceAllowlistSHA256
                == sourceAllowlistSHA256,
              sourceCounters.adapterInvocations == 3,
              sourceCounters.recordsRead == 4,
              sourceCounters.recordsAccepted == 4,
              sourceCounters.recordsRejected == 0,
              sourceCounters.preparedRecords == 4,
              sourceCounters.chunks == 4,
              sourceCounters.embeddingRequests == 4,
              sourceCounters.embeddingsAccepted == 4,
              sourceCounters.indexWrites == 4,
              sourceCounters.leakageCanaryHits == 0,
              gemma.metadata.modelDigest != nil,
              gpt.metadata.modelDigest != nil,
              P8FSignedSmokeDigest.isSHA256(modelDigest)
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .receiptFailed
        }
        let startedAt = events.first?.timestamp ?? Date()
        return try P8FSignedSmokeTerminalReceipt(
            scenario: .cleanup,
            status: .success,
            reasonCode: .runCompleted,
            startedAt: startedAt,
            completedAt: max(Date(), startedAt),
            applicationIdentity:
                bootstrap.applicationIdentity,
            admissionAccepted: admissionAccepted,
            fixtureAccepted:
                fixture.metadata.fixtureManifestSHA256
                    == fixtureManifestSHA256,
            fixtureManifestSHA256:
                fixtureManifestSHA256,
            sourceAllowlistSHA256:
                sourceAllowlistSHA256,
            authorizationReceiptIdentifierSHA256:
                authorizationSHA256,
            semanticOutcomeState: .published,
            generationIdentifierSHA256:
                generationSHA256,
            sourceCounters: sourceCounters,
            model: model,
            modelDigestSHA256: modelDigest,
            modelAssessmentStatus: qwen.status,
            searchMode: .hybrid,
            searchPassed: searchPassed,
            hydrationPassed: hydrationPassed,
            cleanupPassed: cleanupPassed,
            privacySummary: privacy
        )
    }

    private func eventDraft(
        event: P8FSignedSmokeEventName,
        parentSpanID: String?,
        component: P8FSignedSmokeComponent,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        scenario: P8FSignedSmokeScenario,
        sourceKind: SemanticIndexSourceKind? = nil,
        model: P8FSignedSmokeApprovedModel? = nil,
        searchMode: SemanticSearchMode? = nil,
        artifactClassification:
            P8FSignedSmokeArtifactClassification? = nil,
        endpointClassification:
            P8FSignedSmokeEndpointClassification? = nil,
        fixtureManifestSHA256: String? = nil,
        sourceAllowlistSHA256: String? = nil,
        generationIdentifierSHA256: String? = nil,
        authorizationReceiptIdentifierSHA256:
            String? = nil,
        modelDigest: String? = nil,
        runtimeIdentitySHA256: String? = nil,
        requestProfileSHA256: String? = nil,
        artifactSHA256: String? = nil,
        vectorDimension: Int? = nil,
        counters: P8FSignedSmokeCounters? = nil,
        processIdentifier: Int? = nil,
        executableSHA256: String? = nil,
        providerRequestTraceSHA256: String? = nil,
        providerRequestIdentifierSHA256: String? = nil,
        providerKind: P8FProviderRequestKind? = nil,
        providerOperationKind:
            P8FProviderRequestOperation? = nil,
        providerOutcome: P8FProviderRequestOutcome? = nil,
        providerIntervalStartedAt: Date? = nil,
        providerIntervalEndedAt: Date? = nil,
        providerIntervalDurationMilliseconds: Int? = nil,
        durationMilliseconds: Int = 0,
        timestamp: Date = Date()
    ) throws -> P8FSignedSmokeEventDraft {
        try .init(
            event: event,
            parentSpanID: parentSpanID,
            component: component,
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: durationMilliseconds,
            metadata:
                try P8FSignedSmokeEventMetadata(
                    scenario: scenario,
                    sourceKind: sourceKind,
                    model: model,
                    searchMode: searchMode,
                    artifactClassification:
                        artifactClassification,
                    endpointClassification:
                        endpointClassification,
                    fixtureManifestSHA256:
                        fixtureManifestSHA256,
                    sourceAllowlistSHA256:
                        sourceAllowlistSHA256,
                    generationIdentifierSHA256:
                        generationIdentifierSHA256,
                    authorizationReceiptIdentifierSHA256:
                        authorizationReceiptIdentifierSHA256,
                    modelDigest: modelDigest,
                    runtimeIdentitySHA256:
                        runtimeIdentitySHA256,
                    requestProfileSHA256:
                        requestProfileSHA256,
                    artifactSHA256: artifactSHA256,
                    vectorDimension: vectorDimension,
                    counters: counters,
                    processIdentifier: processIdentifier,
                    executableSHA256: executableSHA256,
                    providerRequestTraceSHA256:
                        providerRequestTraceSHA256,
                    providerRequestIdentifierSHA256:
                        providerRequestIdentifierSHA256,
                    providerKind: providerKind,
                    providerOperationKind:
                        providerOperationKind,
                    providerOutcome: providerOutcome,
                    providerIntervalStartedAt:
                        providerIntervalStartedAt,
                    providerIntervalEndedAt:
                        providerIntervalEndedAt,
                    providerIntervalDurationMilliseconds:
                        providerIntervalDurationMilliseconds
                ),
            timestamp: timestamp
        )
    }

    private func appendProviderCorrelationEvidence(
        writer: P8FSignedSmokeReceiptWriter
    ) throws {
        let sealedEvidence = try sealProviderEvidence()
        let observations = sealedEvidence.observations
        guard observations.enumerated().allSatisfy({
                  $0.element.sequence
                    == UInt64($0.offset + 1)
              }),
              observations.last?.sequence
                ?? 0 == sealedEvidence.latestSequence,
              Set(
                observations.map(\.requestIdentifierSHA256)
              ).count == observations.count
        else {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }

        let expectedModel:
            P8FSignedSmokeApprovedModel?
        switch bootstrap.admission.controlPlan.scenario {
        case .modelAssessment:
            guard let rawModel =
                    bootstrap.admission.controlPlan
                        .modelIdentifier,
                  let approvedModel =
                    P8FSignedSmokeApprovedModel(
                        rawValue: rawModel
                    )
            else {
                throw P8FSignedSmokeCoordinatorFailure
                    .modelUnavailable
            }
            expectedModel = approvedModel
        case .semanticSourceProof, .search:
            expectedModel = .qwenEmbedding
        case .hydration, .cleanup:
            expectedModel = nil
        }
        guard expectedModel != nil
                || observations.isEmpty
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }

        let existingIdentifiers = Set(
            writer.events.compactMap {
                $0.metadata
                    .providerRequestIdentifierSHA256
            }
        )
        if let expectedModel {
            for observation in observations
            where !existingIdentifiers.contains(
                observation.requestIdentifierSHA256
            ) {
                guard observation.processIdentifier > 0,
                      observation.executableSHA256
                        == bootstrap.applicationIdentity
                            .executableSHA256,
                      observation.endpointPolicyClassification
                        == .ollamaModelIPv4Loopback
                else {
                    throw P8FSignedSmokeCoordinatorFailure
                        .receiptFailed
                }
                let classification =
                    Self.providerReceiptClassification(
                        for: observation.outcome
                    )
                let artifactSHA256 =
                    P8FSignedSmokeDigest.sha256(
                        try P8FSignedSmokeJSON.encode(
                            observation
                        )
                    )
                try invokeProviderCorrelationEvidenceAppendXCTestHook()
                _ = try writer.append(
                    try eventDraft(
                        event: .network,
                        parentSpanID:
                            rootSpanID(writer),
                        component: .modelProvider,
                        status: classification.status,
                        reasonCode: classification.reasonCode,
                        scenario:
                            scenario(for: expectedModel),
                        model: expectedModel,
                        endpointClassification:
                            .ollamaModelIPv4Loopback,
                        fixtureManifestSHA256:
                            P8FSignedSmokeFixtureManifest
                                .expectedCanonicalSHA256,
                        artifactSHA256: artifactSHA256,
                        processIdentifier:
                            Int(
                                observation
                                    .processIdentifier
                            ),
                        executableSHA256:
                            observation.executableSHA256,
                        providerRequestTraceSHA256:
                            observation
                                .requestTraceSHA256,
                        providerRequestIdentifierSHA256:
                            observation
                                .requestIdentifierSHA256,
                        providerKind:
                            observation.providerKind,
                        providerOperationKind:
                            observation.operationKind,
                        providerOutcome:
                            observation.outcome,
                        providerIntervalStartedAt:
                            observation
                                .providerRequestStartedAt,
                        providerIntervalEndedAt:
                            observation
                                .providerRequestEndedAt,
                        providerIntervalDurationMilliseconds:
                            observation
                                .providerRequestDurationMilliseconds,
                        durationMilliseconds:
                            observation
                                .providerRequestDurationMilliseconds,
                        timestamp:
                            observation
                                .providerRequestEndedAt
                    )
                )
            }
        }

        guard expectedModel == nil
                || !observations.isEmpty
        else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
    }

    private func sealProviderEvidence()
        throws -> P8FProviderRequestEvidenceSeal
    {
        if let providerEvidenceSeal {
            return providerEvidenceSeal
        }
        guard let providerEvidenceRun else {
            throw P8FSignedSmokeCoordinatorFailure
                .prerequisiteMissing
        }
        let sealed: P8FProviderRequestEvidenceSeal
        do {
            sealed = try P8FProviderRequestCorrelationRecorder
                .shared
                .sealEvidence(for: providerEvidenceRun)
        } catch {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        guard sealed.run == providerEvidenceRun else {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        providerEvidenceSeal = sealed
        return sealed
    }

    private func rootSpanID(
        _ writer: P8FSignedSmokeReceiptWriter
    ) throws -> String {
        guard let spanID = writer.events.first?.spanID else {
            throw P8FSignedSmokeCoordinatorFailure.receiptFailed
        }
        return spanID
    }

    private func authorizationReceiptIdentifier(
        suffix: String
    ) -> String {
        let digest = P8FSignedSmokeDigest.sha256(
            bootstrap.admission.controlPlan.runIdentifier
                + "\u{1f}"
                + suffix
        )
        return "semantic_scope_\(digest)"
    }

    private func scenario(
        for model: P8FSignedSmokeApprovedModel
    ) -> P8FSignedSmokeScenario {
        switch model {
        case .gemma4: .gemma4
        case .gptOSS: .gptOSS
        case .qwenEmbedding: .qwenEmbedding
        }
    }

    private func searchScenario(
        for mode: SemanticSearchMode
    ) -> P8FSignedSmokeScenario {
        switch mode {
        case .lexical: .lexicalSearch
        case .semantic: .semanticSearch
        case .hybrid: .hybridSearch
        }
    }

    static func receiptStatus(
        forAtomicState state:
            P8SignedSmokeSemanticRebuildTerminalState
    ) -> P8FSignedSmokeStatus {
        switch state {
        case .published:
            .success
        case .rejected, .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    static func providerReceiptClassification(
        for outcome: P8FProviderRequestOutcome
    ) -> P8FSignedSmokeProviderReceiptClassification {
        switch outcome {
        case .succeeded:
            .init(
                status: .success,
                reasonCode: .providerTransportSucceeded
            )
        case .failed:
            .init(
                status: .failed,
                reasonCode: .providerTransportFailed
            )
        case .cancelled:
            .init(
                status: .cancelled,
                reasonCode: .providerTransportCancelled
            )
        }
    }

    static func resolveTerminalResult(
        primary: P8FSignedSmokeExecutionResult,
        containmentFailure:
            P8FSignedSmokeCoordinatorFailure?
    ) -> P8FSignedSmokeExecutionResult {
        if let containmentFailure {
            return .failed(containmentFailure)
        }
        return primary
    }

    static func classify(
        _ error: Error
    ) -> P8FSignedSmokeExecutionResult {
        if let failure =
                error as? P8FSignedSmokeCoordinatorFailure {
            return .failed(failure)
        }
        if isCancellation(error) {
            return .cancelled
        }
        if error is P8FSignedSmokeAdmissionFailure {
            return .failed(.prerequisiteMissing)
        }
        if error is P8FSignedSmokeReceiptStoreFailure {
            return .failed(.receiptFailed)
        }
        if error is P8FSignedSmokeFixtureFailure {
            return .failed(.fixtureMismatch)
        }
        return .failed(.semanticBuildFailed)
    }

    private static func isCancellation(
        _ error: Error
    ) -> Bool {
        if error is CancellationError {
            return true
        }
        if let failure = error as? URLError,
           failure.code == .cancelled {
            return true
        }
        if let failure = error as? OllamaFailure,
           failure.code == .requestCancelled {
            return true
        }
        if let failure = error as? OllamaChatFailure,
           failure.code == .requestCancelled {
            return true
        }
        if let failure = error as? OllamaEmbeddingFailure,
           failure.code == .requestCancelled {
            return true
        }
        if let failure = error as? OllamaWebResearchFailure,
           failure.code == .requestCancelled {
            return true
        }
        if let failure = error as? VisionAttachmentFailure,
           failure.code == .cancelled {
            return true
        }
        if let failure = error as? SemanticIndexFailureCode,
           failure == .cancelled {
            return true
        }
        return false
    }
}
