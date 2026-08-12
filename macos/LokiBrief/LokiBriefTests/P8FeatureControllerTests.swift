import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokiBrief

private enum P8ControllerEmbeddingBehavior: Sendable {
    case stable
    case strongStable
    case failure(OllamaEmbeddingFailureCode)
    case malformedDimension(Int)
    case responseModelIdentifier(String)
    case mismatchedRequestProfileHash(String)
    case missingRequestIdentity
    case fixedVector([Double])
    case failAfterSuccessfulRequests(
        Int,
        OllamaEmbeddingFailureCode
    )
    case collapseAcrossRequestBoundaryAfterSuccessfulRequests(Int)
}

private final class P8MalformedEmbeddingTransport:
    OllamaChatTransporting,
    @unchecked Sendable
{
    func stream(
        for request: URLRequest,
        requestID: UUID,
        responseLimit: Int
    ) -> AsyncThrowingStream<OllamaChatTransportEvent, Error> {
        let response = Data(
            #"{"embeddings":[],"model":"qwen3-embedding:0.6b"}"#.utf8
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(
                statusCode: 200,
                finalURL: request.url!,
                expectedContentLength: Int64(response.count)
            )))
            continuation.yield(.bytes(response))
            continuation.finish()
        }
    }

    func cancel(requestID: UUID) async {}
}

private actor P8ControllerFakeEmbeddingProvider: P8EmbeddingProviding {
    let dimension: Int
    let requestProfileHashOverride: String?
    private(set) var requests: [OllamaEmbeddingRequest] = []
    private var behavior: P8ControllerEmbeddingBehavior = .stable
    private var behaviorRequestCount = 0

    init(
        dimension: Int = 3,
        requestProfileHashOverride: String? = nil
    ) {
        self.dimension = dimension
        self.requestProfileHashOverride = requestProfileHashOverride
    }

    func setBehavior(_ behavior: P8ControllerEmbeddingBehavior) {
        self.behavior = behavior
        behaviorRequestCount = 0
    }

    func embed(
        _ request: OllamaEmbeddingRequest
    ) async throws -> OllamaEmbeddingReceipt {
        requests.append(request)
        behaviorRequestCount += 1
        let observedDimension: Int
        let responseModelIdentifier: String
        let responseProfileHash: String?
        let includesRequestIdentity: Bool
        let fixedVector: [Double]?
        switch behavior {
        case .stable, .strongStable:
            observedDimension = dimension
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = nil
        case let .failure(code):
            throw OllamaEmbeddingFailure(code)
        case let .malformedDimension(value):
            observedDimension = value
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = nil
        case let .responseModelIdentifier(identifier):
            observedDimension = dimension
            responseModelIdentifier = identifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = nil
        case let .mismatchedRequestProfileHash(hash):
            observedDimension = dimension
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = hash
            includesRequestIdentity = true
            fixedVector = nil
        case .missingRequestIdentity:
            observedDimension = dimension
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = nil
            includesRequestIdentity = false
            fixedVector = nil
        case let .fixedVector(vector):
            observedDimension = vector.count
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = vector
        case let .failAfterSuccessfulRequests(count, code):
            guard behaviorRequestCount <= count else {
                throw OllamaEmbeddingFailure(code)
            }
            observedDimension = dimension
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = nil
        case .collapseAcrossRequestBoundaryAfterSuccessfulRequests:
            observedDimension = dimension
            responseModelIdentifier = request.modelIdentifier
            responseProfileHash = requestProfileHashOverride
                ?? request.profile.stableHash
            includesRequestIdentity = true
            fixedVector = nil
        }
        let vectors: [[Double]]
        if case .strongStable = behavior {
            vectors = request.inputs.map {
                Self.strongStableVector(
                    for: $0,
                    dimension: observedDimension
                )
            }
        } else if case let
            .collapseAcrossRequestBoundaryAfterSuccessfulRequests(
                count
            ) = behavior
        {
            vectors = request.inputs.enumerated().map { index, input in
                if behaviorRequestCount == count && index == 0
                    || behaviorRequestCount > count {
                    return Self.collapsedVector(
                        dimension: observedDimension
                    )
                }
                return Self.strongStableVector(
                    for: input,
                    dimension: observedDimension
                )
            }
        } else {
            vectors = request.inputs.map {
                fixedVector
                    ?? Self.stableVector(
                        for: $0,
                        dimension: observedDimension
                    )
            }
        }
        let identityHash = String(repeating: "1", count: 64)
        return .init(
            modelIdentifier: responseModelIdentifier,
            vectors: vectors,
            observedDimension: observedDimension,
            totalDurationNanoseconds: 1,
            loadDurationNanoseconds: 1,
            promptTokenCount: request.inputs.count,
            requestIdentity: includesRequestIdentity
                ? .init(
                    normalizedInputHashes: request.inputs.map { _ in
                        identityHash
                    },
                    normalizedInputsHash: identityHash,
                    canonicalRequestHash: identityHash,
                    requestProfileHash: responseProfileHash
                        ?? request.profile.stableHash
                )
                : nil
        )
    }

    private static func stableVector(
        for input: String,
        dimension: Int
    ) -> [Double] {
        guard dimension > 0 else { return [] }
        var vector = Array(repeating: 0.0, count: dimension)
        vector[0] = 1
        if dimension > 1 {
            let checksum = input.utf8.enumerated().reduce(0) {
                ($0 + (($1.offset + 1) * Int($1.element))) % 65_521
            }
            vector[1] = Double(checksum + 1) / 65_522
        }
        return vector
    }

    private static func collapsedVector(
        dimension: Int
    ) -> [Double] {
        guard dimension > 0 else { return [] }
        var vector = Array(repeating: 0.0, count: dimension)
        vector[0] = 1
        return vector
    }

    private static func strongStableVector(
        for input: String,
        dimension: Int
    ) -> [Double] {
        guard dimension > 0 else { return [] }
        var vector = Array(repeating: 0.0, count: dimension)
        vector[0] = 1
        let digest = SemanticIndexDigest.sha256(input)
        if dimension > 1,
           let value = UInt32(digest.prefix(8), radix: 16) {
            vector[1] = (Double(value) + 1) / 4_294_967_296
        }
        if dimension > 2,
           let value = UInt32(digest.dropFirst(8).prefix(8), radix: 16) {
            vector[2] = (Double(value) + 1) / 4_294_967_296
        }
        return vector
    }
}

private actor P8NoncooperativeSearchEmbeddingProvider:
    P8EmbeddingProviding
{
    private let base = P8ControllerFakeEmbeddingProvider(dimension: 3)
    private var shouldBlockNextRequest = false
    private var blockedRequestStarted = false
    private var startedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation:
        CheckedContinuation<Void, Never>?

    func armNextRequest() {
        shouldBlockNextRequest = true
        blockedRequestStarted = false
    }

    func waitUntilRequestIsBlocked() async {
        if blockedRequestStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseBlockedRequest() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func embed(
        _ request: OllamaEmbeddingRequest
    ) async throws -> OllamaEmbeddingReceipt {
        if shouldBlockNextRequest {
            shouldBlockNextRequest = false
            blockedRequestStarted = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return try await base.embed(request)
    }
}

@MainActor
private final class P8MalformedSemanticBuildSourceSelectionStore:
    P8SemanticBuildSourceSelectionStoring
{
    func load() throws -> Set<SemanticIndexSourceKind>? {
        throw P8SemanticBuildSourceSelectionFailure
            .malformedPersistedSelection
    }

    func save(_ sourceKinds: Set<SemanticIndexSourceKind>) throws {}

    func clear() throws {}
}

@MainActor
private final class P8EffectfulSemanticBuildSourceSelectionStore:
    P8SemanticBuildSourceSelectionStoring
{
    let sentinelURL: URL
    private(set) var methodCallCount = 0

    init(sentinelURL: URL) {
        self.sentinelURL = sentinelURL
    }

    func load() throws -> Set<SemanticIndexSourceKind>? {
        try recordUnexpectedCall()
        return nil
    }

    func save(
        _ sourceKinds: Set<SemanticIndexSourceKind>
    ) throws {
        try recordUnexpectedCall()
    }

    func clear() throws {
        try recordUnexpectedCall()
    }

    private func recordUnexpectedCall() throws {
        methodCallCount += 1
        try Data("selection-store-called".utf8).write(
            to: sentinelURL,
            options: .atomic
        )
    }
}

@MainActor
private final class P8EffectfulSemanticSourceAuthorityReceiptStore:
    P8SemanticSourceAuthorityReceiptStoring
{
    let sentinelURL: URL
    private(set) var methodCallCount = 0

    init(sentinelURL: URL) {
        self.sentinelURL = sentinelURL
    }

    func load() throws -> [P8SemanticSourceAuthorityEvent] {
        try recordUnexpectedCall()
        return []
    }

    func save(
        _ receipts: [P8SemanticSourceAuthorityEvent]
    ) throws {
        try recordUnexpectedCall()
    }

    func clear() throws {
        try recordUnexpectedCall()
    }

    private func recordUnexpectedCall() throws {
        methodCallCount += 1
        try Data("authority-store-called".utf8).write(
            to: sentinelURL,
            options: .atomic
        )
    }
}

@MainActor
private final class P8FailOnceSemanticSourceAuthorityReceiptStore:
    P8SemanticSourceAuthorityReceiptStoring
{
    private let failingEventName:
        P8SemanticSourceAuthorityEventName
    private var receipts: [P8SemanticSourceAuthorityEvent] = []
    private(set) var didFail = false

    init(
        failingOn failingEventName:
            P8SemanticSourceAuthorityEventName
    ) {
        self.failingEventName = failingEventName
    }

    func load() throws -> [P8SemanticSourceAuthorityEvent] {
        receipts
    }

    func save(
        _ receipts: [P8SemanticSourceAuthorityEvent]
    ) throws {
        if !didFail,
           receipts.last?.name == failingEventName
        {
            didFail = true
            throw P8SemanticSourceAuthorityReceiptStoreFailure
                .malformedPersistedReceipts
        }
        self.receipts = Array(receipts.suffix(128))
    }

    func clear() throws {
        receipts = []
    }
}

private actor P8ControllerFakeCredentialStore:
    OllamaWebResearchCredentialStoring
{
    private var key: String?

    init(key: String? = "p8-controller-fake-key-123") {
        self.key = key
    }

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        key = apiKey
    }

    func readAPIKey(
        service: String,
        account: String
    ) async throws -> String? {
        key
    }

    func deleteAPIKey(
        service: String,
        account: String
    ) async throws {
        key = nil
    }

    func storedKey() -> String? { key }
}

private actor P8ControllerBlockingWebProvider:
    P8OllamaWebResearchProviding
{
    private(set) var cancelledRequestIdentifiers: [UUID] = []
    private(set) var searchInvocationCount = 0
    private(set) var fetchInvocationCount = 0

    func search(
        _ request: OllamaWebSearchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebSearchResponse {
        searchInvocationCount += 1
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }

    func fetch(
        _ request: OllamaWebFetchRequest,
        authorization: OllamaWebResearchAuthorization,
        session: OllamaWebResearchToolSession
    ) async throws -> OllamaWebFetchResponse {
        fetchInvocationCount += 1
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }

    func cancel(requestID: UUID) async {
        cancelledRequestIdentifiers.append(requestID)
    }
}

private actor P8ControllerBlockingCredentialStore:
    OllamaWebResearchCredentialStoring
{
    enum BlockedOperation: Equatable {
        case read
        case store
    }

    let blockedOperation: BlockedOperation
    private(set) var readStarted = false
    private(set) var storeStarted = false
    private var key: String?
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        blockedOperation: BlockedOperation,
        key: String? = nil
    ) {
        self.blockedOperation = blockedOperation
        self.key = key
    }

    func storeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) async throws {
        storeStarted = true
        if blockedOperation == .store {
            await waitForRelease()
        }
        key = apiKey
    }

    func readAPIKey(
        service: String,
        account: String
    ) async throws -> String? {
        readStarted = true
        if blockedOperation == .read {
            await waitForRelease()
        }
        return key
    }

    func deleteAPIKey(
        service: String,
        account: String
    ) async throws {
        key = nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class P8SemanticSourceAdapterProbe {
    private(set) var invocationCounts:
        [SemanticIndexSourceKind: Int] = [:]
    private var recordsBySourceKind:
        [SemanticIndexSourceKind: [SemanticIndexSourceRecord]] = [:]
    private var failuresBySourceKind:
        [SemanticIndexSourceKind: Error] = [:]

    func setRecords(
        _ records: [SemanticIndexSourceRecord],
        for sourceKind: SemanticIndexSourceKind
    ) {
        recordsBySourceKind[sourceKind] = records
    }

    func setFailure(
        _ failure: Error?,
        for sourceKind: SemanticIndexSourceKind
    ) {
        failuresBySourceKind[sourceKind] = failure
    }

    func provider(
        for sourceKind: SemanticIndexSourceKind,
        records: [SemanticIndexSourceRecord] = []
    ) -> P8SemanticSourceProvider {
        recordsBySourceKind[sourceKind] = records
        return .init(
            sourceKind: sourceKind,
            contractVersion:
                "p8.test.\(sourceKind.rawValue).v1"
        ) {
            self.invocationCounts[sourceKind, default: 0] += 1
            if let failure =
                    self.failuresBySourceKind[sourceKind] {
                throw failure
            }
            return self.recordsBySourceKind[sourceKind] ?? []
        }
    }
}

@MainActor
private final class P8BlockingSemanticSourceAdapterProbe {
    private(set) var started = false

    func provider() -> P8SemanticSourceProvider {
        .init(
            sourceKind: .brief,
            contractVersion: "p8.test.blocking-brief.v1"
        ) {
            self.started = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
    }
}

private actor P8BlockingCancellationEmbeddingProvider:
    P8EmbeddingProviding
{
    private let base = P8ControllerFakeEmbeddingProvider(dimension: 3)
    private var shouldBlockNextRequest = false
    private var blockedRequestStarted = false
    private var startedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private(set) var typedCancellationCount = 0

    func armNextRequest() {
        shouldBlockNextRequest = true
        blockedRequestStarted = false
    }

    func waitUntilRequestIsBlocked() async {
        if blockedRequestStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func embed(
        _ request: OllamaEmbeddingRequest
    ) async throws -> OllamaEmbeddingReceipt {
        if shouldBlockNextRequest {
            shouldBlockNextRequest = false
            blockedRequestStarted = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                typedCancellationCount += 1
                throw OllamaEmbeddingFailure(.requestCancelled)
            }
        }
        return try await base.embed(request)
    }
}

@MainActor
final class P8FeatureControllerTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testExplicitBuildSourcesAreIndependentAndExcludedAdaptersReceiveZeroCalls()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let providers = SemanticIndexSourceKind.allCases.map {
            probe.provider(for: $0)
        }
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: providers,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertTrue(feature.semanticBuildSourceKinds.isEmpty)
        feature.semanticSourceKinds = [.slackRecord]
        XCTAssertTrue(feature.semanticBuildSourceKinds.isEmpty)

        feature.rebuildSemanticIndex(buildSourceKinds: nil)
        feature.rebuildSemanticIndex()
        XCTAssertTrue(probe.invocationCounts.isEmpty)
        XCTAssertEqual(
            feature.semanticSourceAuthorityEvents.filter {
                $0.name == .emptyScopeRejected
            }.count,
            2
        )
        let emptyScopeGeneration = try await index.activeGeneration()
        XCTAssertNil(emptyScopeGeneration)
        let privateSentinel =
            "private semantic source content must never enter a receipt"
        let privateIdentifier = "private-brief-identifier"
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: privateIdentifier,
                    sourceKind: .brief,
                    text: privateSentinel
                ),
            ],
            for: .brief
        )

        feature.semanticBuildSourceKinds = [
            .brief,
            .schedule,
            .chatMessage,
        ]
        XCTAssertEqual(feature.semanticSourceKinds, [.slackRecord])
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        XCTAssertEqual(probe.invocationCounts[.brief], 1)
        XCTAssertEqual(probe.invocationCounts[.schedule], 1)
        XCTAssertEqual(probe.invocationCounts[.chatMessage], 1)
        XCTAssertNil(probe.invocationCounts[.slackRecord])
        XCTAssertNil(probe.invocationCounts[.vaultRecord])
        XCTAssertNil(probe.invocationCounts[.connectorRecord])
        let activeGeneration = try await index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        XCTAssertEqual(active.sourceCount, 1)
        XCTAssertEqual(
            active.spec.buildScope?.sourceKinds,
            [.brief, .schedule, .chatMessage]
        )

        let scopedEvents =
            feature.semanticSourceAuthorityEvents.filter {
                $0.authorizationReceiptIdentifier != nil
            }
        XCTAssertEqual(
            Set(
                scopedEvents.compactMap(
                    \.authorizationReceiptIdentifier
                )
            ).count,
            1
        )
        XCTAssertEqual(
            Set(
                scopedEvents.filter {
                    $0.name == .adapterInvoked
                        && $0.status == "started"
                }.compactMap(\.sourceKind)
            ),
            Set([
                SemanticIndexSourceKind.brief.rawValue,
                SemanticIndexSourceKind.schedule.rawValue,
                SemanticIndexSourceKind.chatMessage.rawValue,
            ])
        )
        XCTAssertEqual(
            Set(
                scopedEvents.filter {
                    $0.name == .adapterSkipped
                }.compactMap(\.sourceKind)
            ),
            Set([
                SemanticIndexSourceKind.slackRecord.rawValue,
                SemanticIndexSourceKind.vaultRecord.rawValue,
                SemanticIndexSourceKind.connectorRecord.rawValue,
            ])
        )
        let briefIndexed = try XCTUnwrap(
            scopedEvents.first {
                $0.name == .recordPrepared
                    && $0.sourceKind
                        == SemanticIndexSourceKind.brief.rawValue
                    && $0.status == "indexed"
            }
        )
        XCTAssertEqual(briefIndexed.preparedRecordCount, 1)
        XCTAssertEqual(briefIndexed.indexedCount, 1)
        XCTAssertGreaterThan(briefIndexed.chunkCount, 0)
        let reflectedReceipts = String(reflecting: scopedEvents)
        XCTAssertFalse(reflectedReceipts.contains(privateSentinel))
        XCTAssertFalse(reflectedReceipts.contains(privateIdentifier))
    }

    func testSignedSmokeRebuildReturnsPublishedBoundOutcome()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority
        )
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            signedSmokeRuntimeAuthority: authority,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                P8VolatileSemanticSourceAuthorityReceiptStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "signed-smoke-brief",
                    sourceKind: .brief,
                    text: "Signed smoke semantic source"
                ),
            ],
            for: .brief
        )
        let receiptIdentifier =
            "p8-signed-smoke-rebuild-receipt"

        let outcome =
            await feature.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: [.brief],
                    requestTimestamp: anchor,
                    authorizationReceiptIdentifier:
                        receiptIdentifier
                )
            )
        await feature.waitForCurrentWork()

        XCTAssertEqual(outcome.state, .published)
        XCTAssertEqual(outcome.initiation, .signedSmokeRunner)
        XCTAssertEqual(outcome.sourceKinds, [.brief])
        XCTAssertEqual(
            outcome.sourceAuthorityContractVersion,
            SemanticIndexBuildScope.currentContractVersion
        )
        XCTAssertEqual(
            outcome.authorizationReceiptIdentifier,
            receiptIdentifier
        )
        XCTAssertEqual(
            outcome.reasonCode,
            "semantic_generation_source_scope_bound"
        )
        let activeGeneration = try await index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        XCTAssertEqual(active.sourceCount, 1)
        XCTAssertEqual(probe.invocationCounts[.brief], 1)
        let buildScope = try XCTUnwrap(active.spec.buildScope)
        XCTAssertEqual(buildScope.initiation, .signedSmokeRunner)
        XCTAssertEqual(buildScope.requestTimestamp, anchor)
        XCTAssertEqual(
            buildScope.authorizationReceiptIdentifier,
            receiptIdentifier
        )
        XCTAssertEqual(
            outcome.sourceAllowlistSHA256,
            buildScope.allowlistSHA256
        )
        XCTAssertEqual(
            outcome.generationIdentifier,
            active.identifier
        )

        let scopedEvents =
            feature.semanticSourceAuthorityEvents.filter {
                $0.authorizationReceiptIdentifier
                    == receiptIdentifier
            }
        XCTAssertFalse(scopedEvents.isEmpty)
        XCTAssertTrue(
            scopedEvents.allSatisfy {
                $0.buildInitiation == .signedSmokeRunner
            }
        )
        let terminalEvents = scopedEvents.filter {
            switch $0.name {
            case .generationBound,
                 .rebuildFailed,
                 .rebuildCancelled,
                 .emptyScopeRejected:
                true
            default:
                false
            }
        }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertEqual(terminalEvents.first?.name, .generationBound)
        XCTAssertEqual(
            terminalEvents.first?.generationIdentifier,
            active.identifier
        )
    }

    func testSignedSmokeReceiptFailureBeforePublicationBlocksGeneration()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority
        )
        let probe = P8SemanticSourceAdapterProbe()
        let receiptStore =
            P8FailOnceSemanticSourceAuthorityReceiptStore(
                failingOn: .scopeAuthorized
            )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            signedSmokeRuntimeAuthority: authority,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                receiptStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        let outcome = await feature
            .rebuildSemanticIndexForSignedSmoke(.init(
                sourceKinds: [.brief],
                requestTimestamp: anchor,
                authorizationReceiptIdentifier:
                    "signed-smoke-prepublication-receipt-failure"
            ))

        XCTAssertTrue(receiptStore.didFail)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(
            outcome.reasonCode,
            "semantic_source_authority_receipt_persistence_failed"
        )
        XCTAssertNil(outcome.generationIdentifier)
        let activeGeneration = try await index.activeGeneration()
        XCTAssertNil(activeGeneration)
        XCTAssertEqual(probe.invocationCounts[.brief], nil)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .rebuildFailed
                    && $0.reasonCode
                        == "semantic_source_authority_receipt_persistence_failed"
            }
        )
    }

    func testSignedSmokeFinalReceiptFailureStalesPublishedGeneration()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority
        )
        let probe = P8SemanticSourceAdapterProbe()
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier:
                        "signed-smoke-final-receipt-failure",
                    sourceKind: .brief,
                    text: "Synthetic source-authority receipt failure"
                ),
            ],
            for: .brief
        )
        let receiptStore =
            P8FailOnceSemanticSourceAuthorityReceiptStore(
                failingOn: .generationBound
            )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            signedSmokeRuntimeAuthority: authority,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                receiptStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        let outcome = await feature
            .rebuildSemanticIndexForSignedSmoke(.init(
                sourceKinds: [.brief],
                requestTimestamp: anchor,
                authorizationReceiptIdentifier:
                    "signed-smoke-final-receipt-failure"
            ))

        XCTAssertTrue(receiptStore.didFail)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertEqual(
            outcome.reasonCode,
            "semantic_source_authority_receipt_persistence_failed"
        )
        XCTAssertNotNil(outcome.generationIdentifier)
        let activeGeneration = try await index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        XCTAssertEqual(active.identifier, outcome.generationIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(
            active.staleReason,
            .sourceScopeViolation
        )
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeViolation
        )
        let search = await feature
            .searchSemanticIndexForSignedSmoke(.init(
                query: "synthetic receipt failure",
                mode: .semantic
            ))
        XCTAssertNotEqual(search.state, .completed)
        XCTAssertEqual(search.resultCount, 0)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .rebuildFailed
                    && $0.reasonCode
                        == "semantic_source_authority_receipt_persistence_failed"
            }
        )
    }

    func testRawInMemoryIndexAndFakeProvidersCannotAcquireSignedSmokeAuthority()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                P8VolatileSemanticSourceAuthorityReceiptStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        let outcome = await feature
            .rebuildSemanticIndexForSignedSmoke(.init(
                sourceKinds: [.brief],
                authorizationReceiptIdentifier:
                    "raw-mock-must-not-acquire-runtime-authority"
            ))

        XCTAssertEqual(outcome.state, .rejected)
        XCTAssertEqual(
            outcome.reasonCode,
            SemanticIndexFailureCode
                .signedSmokeAuthorityInvalid.rawValue
        )
        XCTAssertEqual(probe.invocationCounts[.brief], nil)
        XCTAssertFalse(
            feature.semanticSourceAuthorityEvents.contains {
                $0.buildInitiation == .signedSmokeRunner
            }
        )
        let activeGeneration = try await index.activeGeneration()
        XCTAssertNil(activeGeneration)
    }

    func testCancellingSignedSmokeCallerCancelsAndDrainsRebuildWithoutPublication()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority
        )
        let probe = P8BlockingSemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            signedSmokeRuntimeAuthority: authority,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [probe.provider()],
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                P8VolatileSemanticSourceAuthorityReceiptStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        let operation = Task {
            await feature.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: [.brief],
                    authorizationReceiptIdentifier:
                        "cancelled-caller-receipt"
                )
            )
        }
        let adapterStarted = await waitUntil { probe.started }
        XCTAssertTrue(adapterStarted)

        operation.cancel()
        let outcome = await operation.value

        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertFalse(feature.hasActiveWork)
        XCTAssertFalse(feature.semanticIsWorking)
        XCTAssertEqual(
            outcome.reasonCode,
            "semantic_rebuild_cancelled"
        )
        let activeGeneration = try await index.activeGeneration()
        XCTAssertNil(activeGeneration)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .rebuildCancelled
                    && $0.status == "cancelled"
            }
        )
    }

    func testSignedSmokeRebuildMapsTypedEmbeddingCancellationToCancelledAndPreservesPriorGeneration()
        async throws
    {
        let context = try await makeSignedSmokeEmbeddingFeature(
            identifier: "typed-rebuild-cancellation"
        )
        let prior = try await requireActiveGeneration(
            in: context.index
        )
        context.probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "typed-rebuild-cancellation-replacement",
                    sourceKind: .brief,
                    text: "Replacement semantic source"
                ),
            ],
            for: .brief
        )
        await context.embedding.armNextRequest()
        let receiptIdentifier =
            "typed-embedding-rebuild-cancellation"
        let operation = Task {
            await context.feature.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: [.brief],
                    authorizationReceiptIdentifier:
                        receiptIdentifier
                )
            )
        }
        await context.embedding.waitUntilRequestIsBlocked()

        operation.cancel()
        let outcome = await operation.value
        let typedCancellationCount =
            await context.embedding.typedCancellationCount

        XCTAssertEqual(
            typedCancellationCount,
            1
        )
        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertEqual(
            outcome.reasonCode,
            "semantic_rebuild_cancelled"
        )
        XCTAssertNil(outcome.generationIdentifier)
        XCTAssertFalse(context.feature.hasActiveWork)
        XCTAssertFalse(context.feature.semanticIsWorking)
        let active = try await requireActiveGeneration(
            in: context.index
        )
        XCTAssertEqual(active.identifier, prior.identifier)
        let terminalEvents = context.feature
            .semanticSourceAuthorityEvents.filter {
                $0.authorizationReceiptIdentifier
                    == receiptIdentifier
                    && [
                        .generationBound,
                        .rebuildFailed,
                        .rebuildCancelled,
                        .emptyScopeRejected,
                    ].contains($0.name)
            }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertEqual(terminalEvents.first?.name, .rebuildCancelled)
        XCTAssertEqual(terminalEvents.first?.status, "cancelled")
        XCTAssertEqual(
            terminalEvents.first?.reasonCode,
            "semantic_rebuild_cancelled"
        )
    }

    func testCancelledSemanticRebuildDrainsBeforeSuccessfulSuccessorRebuildAndSearch()
        async throws
    {
        let context = try await makeSignedSmokeEmbeddingFeature(
            identifier: "cancelled-semantic-predecessor"
        )
        let prior = try await requireActiveGeneration(
            in: context.index
        )
        context.probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "cancelled-semantic-successor",
                    sourceKind: .brief,
                    text: "Successful successor semantic source"
                ),
            ],
            for: .brief
        )
        await context.embedding.armNextRequest()
        let cancelledOperation = Task {
            await context.feature.rebuildSemanticIndexForSignedSmoke(
                .init(
                    sourceKinds: [.brief],
                    authorizationReceiptIdentifier:
                        "cancelled-semantic-operation"
                )
            )
        }
        await context.embedding.waitUntilRequestIsBlocked()
        cancelledOperation.cancel()
        let cancelled = await cancelledOperation.value

        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(context.feature.hasActiveWork)
        let stillActive = try await requireActiveGeneration(
            in: context.index
        )
        XCTAssertEqual(stillActive.identifier, prior.identifier)

        let successor = await context.feature
            .rebuildSemanticIndexForSignedSmoke(.init(
                sourceKinds: [.brief],
                authorizationReceiptIdentifier:
                    "successful-semantic-successor"
            ))
        XCTAssertEqual(successor.state, .published)
        XCTAssertNotEqual(
            successor.generationIdentifier,
            prior.identifier
        )
        let search = await context.feature
            .searchSemanticIndexForSignedSmoke(.init(
                query: "successful successor semantic source",
                mode: .semantic
            ))
        XCTAssertEqual(search.state, .completed)
        XCTAssertGreaterThan(search.resultCount, 0)
        let activeSuccessor = try await requireActiveGeneration(
            in: context.index
        )
        XCTAssertEqual(
            activeSuccessor.identifier,
            successor.generationIdentifier
        )
    }

    func testSignedSmokeSearchMapsTypedEmbeddingCancellationToCancelledAndPublishesNoResults()
        async throws
    {
        let context = try await makeSignedSmokeEmbeddingFeature(
            identifier: "typed-search-cancellation"
        )
        let prior = try await requireActiveGeneration(
            in: context.index
        )
        let successful = await context.feature
            .searchSemanticIndexForSignedSmoke(.init(
                query: "semantic source",
                mode: .semantic
            ))
        XCTAssertEqual(successful.state, .completed)
        XCTAssertGreaterThan(successful.resultCount, 0)

        await context.embedding.armNextRequest()
        let operation = Task {
            await context.feature
                .searchSemanticIndexForSignedSmoke(.init(
                    query: "semantic source",
                    mode: .semantic
                ))
        }
        await context.embedding.waitUntilRequestIsBlocked()

        operation.cancel()
        let outcome = await operation.value
        let typedCancellationCount =
            await context.embedding.typedCancellationCount

        XCTAssertEqual(
            typedCancellationCount,
            1
        )
        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertEqual(outcome.reasonCode, "semantic_search_cancelled")
        XCTAssertEqual(outcome.resultCount, 0)
        XCTAssertTrue(outcome.provenanceIdentifierSHA256s.isEmpty)
        XCTAssertTrue(context.feature.semanticResults.isEmpty)
        XCTAssertFalse(context.feature.hasActiveWork)
        XCTAssertFalse(context.feature.semanticIsWorking)
        let active = try await requireActiveGeneration(
            in: context.index
        )
        XCTAssertEqual(active.identifier, prior.identifier)
    }

    func testManualRebuildWrapperKeepsManualOperatorInitiation()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                P8VolatileSemanticSourceAuthorityReceiptStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        let activeGeneration = try await index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        let buildScope = try XCTUnwrap(active.spec.buildScope)
        XCTAssertEqual(buildScope.initiation, .manualOperator)
        let scopedEvents =
            feature.semanticSourceAuthorityEvents.filter {
                $0.authorizationReceiptIdentifier
                    == buildScope.authorizationReceiptIdentifier
            }
        XCTAssertFalse(scopedEvents.isEmpty)
        XCTAssertTrue(
            scopedEvents.allSatisfy {
                $0.buildInitiation == .manualOperator
            }
        )
        XCTAssertEqual(
            scopedEvents.filter {
                $0.name == .generationBound
            }.count,
            1
        )
    }

    func testExplicitSlackAndVaultScopesInvokeOnlyTheirSelectedAdapters()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        feature.semanticBuildSourceKinds = [.slackRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(probe.invocationCounts, [.slackRecord: 1])
        var active = try await index.activeGeneration()
        XCTAssertEqual(
            active?.spec.buildScope?.sourceKinds,
            [.slackRecord]
        )

        feature.semanticBuildSourceKinds = [.vaultRecord]
        await feature.waitForCurrentWork()
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(probe.invocationCounts[.slackRecord], 1)
        XCTAssertEqual(probe.invocationCounts[.vaultRecord], 1)
        XCTAssertEqual(probe.invocationCounts.count, 2)
        active = try await index.activeGeneration()
        XCTAssertEqual(
            active?.spec.buildScope?.sourceKinds,
            [.vaultRecord]
        )
    }

    func testIndexSourceChangesFailCloseAgainstActiveScopeUntilExplicitRebuild()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders:
                SemanticIndexSourceKind.allCases.map {
                    probe.provider(for: $0)
                },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "scope-brief",
                    sourceKind: .brief,
                    text: "alpha brief"
                ),
            ],
            for: .brief
        )
        feature.semanticBuildSourceKinds = [.brief, .schedule]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let initialGeneration =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(initialGeneration.sourceCount, 1)

        feature.semanticBuildSourceKinds.insert(.chatMessage)
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertEqual(
            feature.semanticHealth?.reasonCode,
            SemanticIndexStaleReason.sourceScopeChanged.rawValue
        )
        await feature.waitForCurrentWork()
        var invalidated =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(
            invalidated.identifier,
            initialGeneration.identifier
        )
        XCTAssertEqual(invalidated.state, .stale)
        XCTAssertEqual(
            invalidated.sourceAuthorityState,
            .sourceScopeChanged
        )
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .generationScopeChanged
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourceScopeChanged.rawValue
            }
        )

        for mode in SemanticSearchMode.allCases {
            feature.semanticMode = mode
            feature.semanticQuery = "alpha"
            feature.searchSemanticIndex()
            await feature.waitForCurrentWork()
            XCTAssertTrue(
                feature.semanticResults.isEmpty,
                "\(mode.rawValue) retrieval must remain fail-closed"
            )
        }

        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let rebuilt =
            try await requireActiveGeneration(in: index)
        XCTAssertNotEqual(
            rebuilt.identifier,
            initialGeneration.identifier
        )
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(
            rebuilt.sourceAuthorityState,
            .sourceScopeReady
        )

        feature.semanticBuildSourceKinds.remove(.schedule)
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertEqual(
            feature.semanticHealth?.reasonCode,
            SemanticIndexStaleReason.sourcePermissionRevoked.rawValue
        )
        await feature.waitForCurrentWork()
        invalidated =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(invalidated.identifier, rebuilt.identifier)
        XCTAssertEqual(
            invalidated.sourceAuthorityState,
            .sourcePermissionRevoked
        )
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .generationPermissionRevoked
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourcePermissionRevoked.rawValue
            }
        )
    }

    func testPostDedupAndCommitReceiptsReconcileEveryRecordOutcome()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let duplicate = try Self.semanticRecord(
            identifier: "receipt-duplicate",
            sourceKind: .brief,
            text: "alpha indexed receipt record"
        )
        let privateSentinel = "receipt-private-value-never-log"
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                duplicate,
                duplicate,
                try Self.semanticRecord(
                    identifier: "receipt-excluded",
                    sourceKind: .brief,
                    text: privateSentinel,
                    privacyClassification: .apiKey
                ),
                try Self.semanticRecord(
                    identifier: "receipt-tombstone",
                    sourceKind: .brief,
                    text: "",
                    isTombstone: true
                ),
            ],
            for: .brief
        )
        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        let indexedReceipt = try XCTUnwrap(
            feature.semanticSourceAuthorityEvents.last {
                $0.name == .recordPrepared
                    && $0.status == "indexed"
                    && $0.sourceKind
                        == SemanticIndexSourceKind.brief.rawValue
            }
        )
        XCTAssertEqual(indexedReceipt.preparedRecordCount, 3)
        XCTAssertEqual(indexedReceipt.indexedCount, 1)
        XCTAssertEqual(indexedReceipt.excludedCount, 1)
        XCTAssertEqual(indexedReceipt.tombstoneCount, 1)
        XCTAssertEqual(indexedReceipt.skippedCount, 1)
        XCTAssertEqual(indexedReceipt.rejectedCount, 0)
        XCTAssertGreaterThan(indexedReceipt.chunkCount, 0)
        let boundReceipt = try XCTUnwrap(
            feature.semanticSourceAuthorityEvents.last {
                $0.name == .generationBound
            }
        )
        XCTAssertEqual(boundReceipt.preparedRecordCount, 3)
        XCTAssertEqual(boundReceipt.indexedCount, 1)
        XCTAssertEqual(boundReceipt.excludedCount, 1)
        XCTAssertEqual(boundReceipt.tombstoneCount, 1)
        XCTAssertEqual(boundReceipt.skippedCount, 1)
        XCTAssertFalse(
            String(reflecting:
                feature.semanticSourceAuthorityEvents)
                .contains(privateSentinel)
        )
    }

    func testCrossKindStableIdentifierCollisionRejectsBuildAndPreservesActiveGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
                probe.provider(for: .schedule),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "initial-brief",
                    sourceKind: .brief,
                    text: "initial brief"
                ),
            ],
            for: .brief
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "initial-schedule",
                    sourceKind: .schedule,
                    text: "initial schedule"
                ),
            ],
            for: .schedule
        )
        feature.semanticBuildSourceKinds = [.brief, .schedule]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let prior =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(prior.sourceCount, 2)
        let privateCollisionIdentifier =
            "private-cross-kind-collision"
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: privateCollisionIdentifier,
                    sourceKind: .brief,
                    text: "replacement brief"
                ),
            ],
            for: .brief
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: privateCollisionIdentifier,
                    sourceKind: .schedule,
                    text: "replacement schedule"
                ),
            ],
            for: .schedule
        )

        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let after =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(after.identifier, prior.identifier)
        XCTAssertEqual(after.state, .ready)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .scopeViolation
                    && $0.reasonCode
                        == "semantic_rebuild_cross_kind_stable_identifier_collision"
                    && $0.rejectedCount == 1
            }
        )
        XCTAssertFalse(
            String(reflecting:
                feature.semanticSourceAuthorityEvents)
                .contains(privateCollisionIdentifier)
        )
    }

    func testAdapterFailureReceiptIsPrivateAndPreservesPriorReadyGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "adapter-failure-prior",
                    sourceKind: .brief,
                    text: "prior ready record"
                ),
            ],
            for: .brief
        )
        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let prior =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(prior.sourceCount, 1)
        let privateFailureSentinel =
            "private-adapter-failure-payload"
        probe.setFailure(
            NSError(
                domain: privateFailureSentinel,
                code: 1
            ),
            for: .brief
        )

        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let after =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(after.identifier, prior.identifier)
        XCTAssertEqual(after.state, .ready)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .adapterInvoked
                    && $0.status == "failed"
                    && $0.reasonCode
                        == "semantic_rebuild_source_adapter_failed"
            }
        )
        let terminalReceipt = try XCTUnwrap(
            feature.semanticSourceAuthorityEvents.last {
                $0.name == .rebuildFailed
                    && $0.status == "failed"
            }
        )
        XCTAssertEqual(
            terminalReceipt.reasonCode,
            "semantic_rebuild_failed"
        )
        XCTAssertNotNil(
            terminalReceipt.authorizationReceiptIdentifier
        )
        XCTAssertFalse(
            String(reflecting:
                feature.semanticSourceAuthorityEvents)
                .contains(privateFailureSentinel)
        )
    }

    func testCancelledRebuildEmitsAndRetainsTerminalAuthorityReceipt()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8BlockingSemanticSourceAdapterProbe()
        let receiptStore =
            P8VolatileSemanticSourceAuthorityReceiptStore()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [probe.provider()],
            semanticSourceAuthorityReceiptStore: receiptStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        let adapterStarted = await waitUntil { probe.started }
        XCTAssertTrue(adapterStarted)

        feature.cancelSemanticWork()
        await feature.waitForCurrentWork()

        let terminalReceipt = try XCTUnwrap(
            feature.semanticSourceAuthorityEvents.last {
                $0.name == .rebuildCancelled
            }
        )
        XCTAssertEqual(terminalReceipt.status, "cancelled")
        XCTAssertEqual(
            terminalReceipt.reasonCode,
            "semantic_rebuild_cancelled"
        )
        XCTAssertEqual(
            terminalReceipt.sourceKinds,
            [SemanticIndexSourceKind.brief.rawValue]
        )
        XCTAssertNotNil(
            terminalReceipt.authorizationReceiptIdentifier
        )
        XCTAssertTrue(
            feature
                .semanticSourceAuthorityReceiptPersistenceIsAvailable
        )
        XCTAssertTrue(
            try receiptStore.load().contains {
                $0.eventIdentifier
                    == terminalReceipt.eventIdentifier
            }
        )
        let activeGeneration = try await index.activeGeneration()
        XCTAssertNil(activeGeneration)
    }

    func testUserDefaultsAuthorityReceiptsRehydrateWithoutPrivatePayload()
        async throws
    {
        let suiteName =
            "P8FeatureControllerTests.authority-receipts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let privateFailureSentinel =
            "private-durable-adapter-failure-payload"
        let probe = P8SemanticSourceAdapterProbe()
        probe.setFailure(
            NSError(
                domain: privateFailureSentinel,
                code: 1
            ),
            for: .brief
        )
        let first = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex:
                try SemanticVaultIndex(inMemory: true),
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            semanticSourceAuthorityReceiptStore:
                P8UserDefaultsSemanticSourceAuthorityReceiptStore(
                    defaults: defaults
                ),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        first.semanticBuildSourceKinds = [.brief]
        first.rebuildSemanticIndex()
        await first.waitForCurrentWork()
        let terminalReceipt = try XCTUnwrap(
            first.semanticSourceAuthorityEvents.last {
                $0.name == .rebuildFailed
            }
        )
        XCTAssertTrue(
            first.semanticSourceAuthorityReceiptPersistenceIsAvailable
        )

        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex:
                try SemanticVaultIndex(inMemory: true),
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            semanticSourceAuthorityReceiptStore:
                P8UserDefaultsSemanticSourceAuthorityReceiptStore(
                    defaults: defaults
                ),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertTrue(
            reopened.semanticSourceAuthorityEvents.contains {
                $0.eventIdentifier
                    == terminalReceipt.eventIdentifier
                    && $0.name == .rebuildFailed
                    && $0.reasonCode
                        == "semantic_rebuild_failed"
            }
        )
        XCTAssertTrue(
            reopened
                .semanticSourceAuthorityReceiptPersistenceIsAvailable
        )
        XCTAssertFalse(
            String(
                reflecting:
                    reopened.semanticSourceAuthorityEvents
            ).contains(privateFailureSentinel)
        )
    }

    func testExplicitRecreateRejectsHealthyGenerationBeforeAdapterInvocation()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "healthy-recreate-guard",
                    sourceKind: .brief,
                    text: "healthy generation"
                ),
            ],
            for: .brief
        )
        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let prior =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(prior.sourceCount, 1)
        probe.setFailure(
            NSError(domain: "must-not-run", code: 1),
            for: .brief
        )

        feature.recreateSemanticIndexAndRebuild()
        await feature.waitForCurrentWork()
        let after =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(after.identifier, prior.identifier)
        XCTAssertEqual(after.state, .ready)
        XCTAssertEqual(probe.invocationCounts[.brief], 1)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .scopeViolation
                    && $0.reasonCode
                        == "semantic_recreate_requires_corrupt_or_missing_active_generation"
            }
        )
    }

    func testMisclassifiedAdapterRecordRejectsWholeBuildAndPreservesPriorGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        feature.semanticBuildSourceKinds = [.brief]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let priorGeneration = try await index.activeGeneration()
        let prior = try XCTUnwrap(priorGeneration)

        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "authorized-brief-before-violation",
                    sourceKind: .brief,
                    text: "synthetic authorized record"
                ),
                try Self.semanticRecord(
                    identifier: "misclassified-slack-record",
                    sourceKind: .slackRecord,
                    text: "synthetic unauthorized record"
                ),
            ],
            for: .brief
        )
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        let afterGeneration = try await index.activeGeneration()
        let after = try XCTUnwrap(afterGeneration)
        XCTAssertEqual(after.identifier, prior.identifier)
        XCTAssertEqual(after.state, .ready)
        XCTAssertEqual(after.sourceCount, prior.sourceCount)
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .scopeViolation
                    && $0.status == "rejected"
                    && $0.reasonCode
                        == "semantic_rebuild_adapter_kind_mismatch"
                    && $0.rejectedCount == 1
            }
        )
    }

    func testUnindexedSearchFilterReturnsBeforeEmbeddingAndCannotChangeBuildAuthority()
        async throws
    {
        let context = try await makeReadyEmbeddingFeature(
            identifier: "indexed-vault-record"
        )
        let buildSourceKinds =
            context.feature.semanticBuildSourceKinds
        let requestsBeforeSearch =
            await context.embedding.requests.count
        let activeBefore =
            try await requireActiveGeneration(in: context.index)

        context.feature.semanticSourceKinds = [.slackRecord]
        context.feature.semanticMode = .semantic
        context.feature.semanticQuery = "alpha"
        context.feature.searchSemanticIndex()
        await context.feature.waitForCurrentWork()

        XCTAssertEqual(
            context.feature.semanticBuildSourceKinds,
            buildSourceKinds
        )
        XCTAssertTrue(context.feature.semanticResults.isEmpty)
        XCTAssertTrue(
            context.feature.semanticStatus.contains("Not indexed")
        )
        let requestsAfterSearch =
            await context.embedding.requests.count
        XCTAssertEqual(requestsAfterSearch, requestsBeforeSearch)
        let activeAfter =
            try await requireActiveGeneration(in: context.index)
        XCTAssertEqual(activeAfter.identifier, activeBefore.identifier)
        XCTAssertEqual(activeAfter.state, activeBefore.state)
        XCTAssertEqual(
            activeAfter.sourceAuthorityState,
            activeBefore.sourceAuthorityState
        )
        XCTAssertEqual(
            activeAfter.staleReason,
            activeBefore.staleReason
        )
        XCTAssertTrue(
            context.feature.semanticSourceAuthorityEvents.contains {
                $0.name == .searchFilterSourceNotIndexed
                    && $0.sourceKinds
                        == [
                            SemanticIndexSourceKind.slackRecord
                                .rawValue,
                        ]
            }
        )
    }

    func testMixedIndexedAndUnindexedSearchFiltersIntersectWithoutStalingGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                probe.provider(for: .brief),
                probe.provider(for: .schedule),
                probe.provider(for: .slackRecord),
            ],
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "mixed-filter-brief",
                    sourceKind: .brief,
                    text: "alpha brief result"
                ),
            ],
            for: .brief
        )
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: "mixed-filter-schedule",
                    sourceKind: .schedule,
                    text: "alpha schedule result"
                ),
            ],
            for: .schedule
        )
        feature.semanticBuildSourceKinds = [.brief, .schedule]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let activeBefore =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(activeBefore.sourceCount, 2)

        feature.semanticSourceKinds = [.brief, .slackRecord]
        feature.semanticMode = .lexical
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()

        XCTAssertEqual(feature.semanticResults.count, 1)
        XCTAssertEqual(
            feature.semanticResults.first?.provenance.sourceKind,
            .brief
        )
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .searchFilterNarrowed
                    && $0.sourceKinds
                        == [SemanticIndexSourceKind.brief.rawValue]
            }
        )
        XCTAssertTrue(
            feature.semanticSourceAuthorityEvents.contains {
                $0.name == .searchFilterSourceNotIndexed
                    && $0.sourceKinds
                        == [
                            SemanticIndexSourceKind.slackRecord
                                .rawValue,
                        ]
            }
        )
        let activeAfter =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(activeAfter.identifier, activeBefore.identifier)
        XCTAssertEqual(activeAfter.state, activeBefore.state)
        XCTAssertEqual(
            activeAfter.sourceAuthorityState,
            activeBefore.sourceAuthorityState
        )
        XCTAssertEqual(
            activeAfter.staleReason,
            activeBefore.staleReason
        )
    }

    func testCorruptFileBackedIndexFailsSoftThenExplicitRecreateAndDeleteRemovesFamily()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(
            url: root.appendingPathComponent("primary.sqlite3")
        )
        let semanticURL = try XCTUnwrap(
            P8SemanticPaths.databaseURL(for: store)
        )
        try Data("not-a-sqlite-database".utf8).write(
            to: semanticURL,
            options: .atomic
        )
        let credentialStore = P8ControllerFakeCredentialStore()
        let webProvider = P8ControllerBlockingWebProvider()

        let feature = try P8FeatureController(
            store: store,
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            webCredentialStore: credentialStore,
            webResearchProvider: webProvider
        )

        XCTAssertEqual(feature.semanticStorageState, .corrupt)
        XCTAssertEqual(feature.semanticHealth?.state, .corrupt)
        XCTAssertTrue(feature.semanticStatus.contains("recreate"))

        feature.semanticBuildSourceKinds = [.brief]
        feature.recreateSemanticIndexAndRebuild()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticStorageState, .available)
        XCTAssertEqual(feature.semanticHealth?.state, .lexicalOnly)

        let deleteSucceeded =
            await feature.deleteAllP8DerivedAndCredentialData()
        XCTAssertTrue(deleteSucceeded)
        XCTAssertEqual(feature.semanticStorageState, .deleted)
        XCTAssertTrue(feature.semanticBuildSourceKinds.isEmpty)
        for URL in P8SemanticPaths.databaseFamilyURLs(for: semanticURL) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: URL.path)
            )
        }
        let credentialAfterDelete = await credentialStore.storedKey()
        XCTAssertNil(credentialAfterDelete)
        XCTAssertFalse(feature.hasActiveWork)

        let resetSucceeded = await feature.resetAfterDeleteAll()
        XCTAssertTrue(resetSucceeded)
        XCTAssertEqual(feature.semanticStorageState, .available)
        XCTAssertEqual(feature.semanticHealth?.state, .empty)
        XCTAssertEqual(feature.webCredentialConfigured, false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: semanticURL.path)
        )
        XCTAssertFalse(feature.lifecycleIsPaused)
    }

    func testSignedSmokeControllerRejectsRawReceiptStoresBeforeAnyProtocolMethodCall()
        throws
    {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let selectionSentinel = outsideRoot.appendingPathComponent(
            "selection-sentinel"
        )
        let authoritySentinel = outsideRoot.appendingPathComponent(
            "authority-sentinel"
        )
        let selectionMarker = Data("selection-intact".utf8)
        let authorityMarker = Data("authority-intact".utf8)
        try selectionMarker.write(to: selectionSentinel)
        try authorityMarker.write(to: authoritySentinel)
        let selectionStore =
            P8EffectfulSemanticBuildSourceSelectionStore(
                sentinelURL: selectionSentinel
            )
        let authorityStore =
            P8EffectfulSemanticSourceAuthorityReceiptStore(
                sentinelURL: authoritySentinel
            )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                semanticBuildSourceSelectionStore:
                    selectionStore,
                semanticSourceAuthorityReceiptStore:
                    P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                        isolatedRoot: root
                    ),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertEqual(selectionStore.methodCallCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: selectionSentinel),
            selectionMarker
        )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                semanticBuildSourceSelectionStore:
                    P8FSignedSmokeSemanticBuildSourceSelectionStore(
                        isolatedRoot: root
                    ),
                semanticSourceAuthorityReceiptStore:
                    authorityStore,
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertEqual(authorityStore.methodCallCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: authoritySentinel),
            authorityMarker
        )
    }

    func testSignedSmokeControllerRejectsWrongRootConcreteReceiptStoresAndAcceptsSameRootStores()
        throws
    {
        let root = try temporaryDirectory()
        let wrongRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: wrongRoot)
        }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                semanticBuildSourceSelectionStore:
                    P8FSignedSmokeSemanticBuildSourceSelectionStore(
                        isolatedRoot: wrongRoot
                    ),
                semanticSourceAuthorityReceiptStore:
                    P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                        isolatedRoot: root
                    ),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                semanticBuildSourceSelectionStore:
                    P8FSignedSmokeSemanticBuildSourceSelectionStore(
                        isolatedRoot: root
                    ),
                semanticSourceAuthorityReceiptStore:
                    P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                        isolatedRoot: wrongRoot
                    ),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }

        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let accepted = try P8FeatureController(
            store: store,
            signedSmokeStorageBoundary:
                admission.storageBoundary,
            signedSmokeRuntimeAuthority:
                admission.runtimeAuthority,
            signedSmokeDependencyPackage: dependencyPackage
        )
        XCTAssertEqual(accepted.semanticStorageState, .available)
    }

    func testSignedSmokePackageRejectsRawSourcePreparationBudgetOverride()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage: dependencyPackage,
                semanticSourcePreparationBudget: .init(
                    maximumRecords: 1,
                    maximumTotalTextBytes: 1,
                    maximumRecordTextBytes: 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
    }

    func testSignedSmokeControllerRejectsOutsideLocalStoreBeforeSourceRead()
        throws
    {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let admission = try signedSmokeAdmission(for: root)
        let outsideStore = try LocalStore(
            url: outsideRoot.appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureStoreFilename
            )
        )
        let sourceSentinel = outsideRoot.appendingPathComponent(
            "source-provider-sentinel"
        )
        let marker = Data("source-provider-intact".utf8)
        try marker.write(to: sourceSentinel)
        var sourceReadCount = 0
        let sourceProvider = P8SemanticSourceProvider(
            sourceKind: .brief,
            contractVersion: "outside-store-adversary.v1"
        ) {
            sourceReadCount += 1
            try Data("source-provider-called".utf8).write(
                to: sourceSentinel,
                options: .atomic
            )
            return []
        }

        XCTAssertThrowsError(
            try P8FeatureController(
                store: outsideStore,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                semanticSourceProviders: [sourceProvider],
                semanticBuildSourceSelectionStore:
                    P8FSignedSmokeSemanticBuildSourceSelectionStore(
                        isolatedRoot: root
                    ),
                semanticSourceAuthorityReceiptStore:
                    P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                        isolatedRoot: root
                    ),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertEqual(sourceReadCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: sourceSentinel),
            marker
        )
    }

    func testSignedSmokePackageRejectsLocalStoreReplacementBeforeConstruction()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let storeURL = try XCTUnwrap(store.storageURL)
        let retained = storeURL.deletingLastPathComponent()
            .appendingPathComponent("retained-original.store")
        try FileManager.default.moveItem(
            at: storeURL,
            to: retained
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: storeURL.path,
                contents: Data("substituted-store".utf8)
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )

        XCTAssertThrowsError(
            try P8FSignedSmokeDependencyPackage.makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: retained.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: storeURL),
            Data("substituted-store".utf8)
        )
    }

    func testSignedSmokePackageRejectsWrongAuthorityRootAndStoreReuse()
        throws
    {
        let rootA = try temporaryDirectory()
        let rootB = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let admissionA = try signedSmokeAdmission(for: rootA)
        let admissionB = try signedSmokeAdmission(for: rootB)
        let storeA = try signedSmokeFixtureStore(
            under: rootA,
            storageBoundary: admissionA.storageBoundary
        )
        let storeB = try signedSmokeFixtureStore(
            under: rootB,
            storageBoundary: admissionB.storageBoundary
        )
        let package = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: storeA,
                storageBoundary: admissionA.storageBoundary,
                runtimeAuthority: admissionA.runtimeAuthority
            )

        XCTAssertThrowsError(
            try package.validate(
                store: storeA,
                storageBoundary: admissionA.storageBoundary,
                runtimeAuthority: admissionB.runtimeAuthority
            )
        )
        XCTAssertThrowsError(
            try package.validate(
                store: storeA,
                storageBoundary: admissionB.storageBoundary,
                runtimeAuthority: admissionB.runtimeAuthority
            )
        )
        XCTAssertThrowsError(
            try package.validate(
                store: storeB,
                storageBoundary: admissionB.storageBoundary,
                runtimeAuthority: admissionB.runtimeAuthority
            )
        )
        XCTAssertNoThrow(
            try package.validate(
                store: storeA,
                storageBoundary: admissionA.storageBoundary,
                runtimeAuthority: admissionA.runtimeAuthority
            )
        )
    }

    func testSignedSmokePackageDetectsLocalStoreReplacementAfterConstruction()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let package = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let storeURL = try XCTUnwrap(store.storageURL)
        let retained = storeURL.deletingLastPathComponent()
            .appendingPathComponent("retained-after-package.store")
        try FileManager.default.moveItem(
            at: storeURL,
            to: retained
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: storeURL.path,
                contents: Data("post-package-substitution".utf8)
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )

        XCTAssertThrowsError(try package.revalidateBoundary()) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: storeURL),
            Data("post-package-substitution".utf8)
        )
    }

    func testSignedSmokeSemanticBoundaryRejectsSymlinkAndCleanupPreservesOutsideFamily()
        async throws
    {
        let root = try temporaryDirectory()
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-p8-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let admission = try signedSmokeAdmission(for: root)
        let boundary = admission.storageBoundary
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: boundary
        )

        let outsideSemantic = outsideRoot
            .appendingPathComponent("Semantic", isDirectory: true)
        let outsideVersion = outsideSemantic
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideVersion,
            withIntermediateDirectories: true
        )
        for directory in [outsideRoot, outsideSemantic, outsideVersion] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        let outsideDatabase = outsideVersion
            .appendingPathComponent("loki-semantic.sqlite3")
        let outsideFamily = [
            outsideDatabase,
            URL(fileURLWithPath: outsideDatabase.path + "-wal"),
            URL(fileURLWithPath: outsideDatabase.path + "-shm"),
        ]
        let markerData = outsideFamily.enumerated().map {
            Data("outside-semantic-\($0.offset)".utf8)
        }
        for (URL, data) in zip(outsideFamily, markerData) {
            try data.write(to: URL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: URL.path
            )
        }

        let semanticLink = root.appendingPathComponent(
            "Semantic",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: semanticLink,
            withDestinationURL: outsideSemantic
        )
        XCTAssertThrowsError(
            try P8SemanticPaths.databaseURL(
                for: store,
                signedSmokeStorageBoundary: boundary
            )
        )
        for (URL, data) in zip(outsideFamily, markerData) {
            XCTAssertEqual(try Data(contentsOf: URL), data)
        }

        try FileManager.default.removeItem(at: semanticLink)
        let semanticDatabase = try XCTUnwrap(
            P8SemanticPaths.databaseURL(
                for: store,
                signedSmokeStorageBoundary: boundary
            )
        )
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: boundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let semanticIndex = try dependencyPackage
            .makeAndBindSemanticIndex(at: semanticDatabase)
        let feature = try P8FeatureController(
            store: store,
            semanticIndex: semanticIndex,
            semanticDatabaseURLOverride: semanticDatabase,
            signedSmokeStorageBoundary: boundary,
            signedSmokeRuntimeAuthority:
                admission.runtimeAuthority,
            signedSmokeDependencyPackage: dependencyPackage
        )
        let retainedSemantic = root.appendingPathComponent(
            "retained-semantic",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: semanticLink,
            to: retainedSemantic
        )
        try FileManager.default.createSymbolicLink(
            at: semanticLink,
            withDestinationURL: outsideSemantic
        )

        let deletionSucceeded =
            await feature.deleteAllP8DerivedAndCredentialData()
        XCTAssertFalse(deletionSucceeded)
        for (URL, data) in zip(outsideFamily, markerData) {
            XCTAssertEqual(try Data(contentsOf: URL), data)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retainedSemantic.path
            )
        )
    }

    func testSignedSmokeInjectedSemanticIndexMustMatchAdmittedDatabase()
        async throws
    {
        let root = try temporaryDirectory()
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-p8-index-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let admission = try signedSmokeAdmission(for: root)
        let boundary = admission.storageBoundary
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: boundary
        )

        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outsideDatabase = outsideRoot
            .appendingPathComponent("outside-semantic.sqlite3")
        let outsideIndex = try SemanticVaultIndex(url: outsideDatabase)
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: boundary,
                runtimeAuthority: admission.runtimeAuthority
            )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                semanticIndex: outsideIndex,
                signedSmokeStorageBoundary: boundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage: dependencyPackage
            )
        )

        let admittedDatabase = root
            .appendingPathComponent("Semantic", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("loki-semantic.sqlite3")
        try boundary.ensurePrivateDirectory(
            at: admittedDatabase.deletingLastPathComponent()
        )
        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                semanticIndex: outsideIndex,
                semanticDatabaseURLOverride: admittedDatabase,
                signedSmokeStorageBoundary: boundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage: dependencyPackage
            )
        )
        await outsideIndex.close()
    }

    func testSignedSmokeControllerRejectsIndependentlyReadmittedBoundary()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let semanticDatabase = try XCTUnwrap(
            P8SemanticPaths.databaseURL(
                for: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary
            )
        )
        let readmission = try signedSmokeAdmission(for: root)
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let index = try dependencyPackage.makeAndBindSemanticIndex(
            at: semanticDatabase
        )
        XCTAssertFalse(
            admission.storageBoundary.sharesAdmissionIdentity(
                with: readmission.storageBoundary
            )
        )

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                semanticIndex: index,
                semanticDatabaseURLOverride: semanticDatabase,
                signedSmokeStorageBoundary:
                    readmission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        await index.close()
    }

    func testFileAuthorityRequiresBoundaryAndOverrideMustMatchIndex()
        async throws
    {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let admission = try signedSmokeAdmission(for: root)
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: admission.storageBoundary
        )
        let semanticDatabase = try XCTUnwrap(
            P8SemanticPaths.databaseURL(
                for: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary
            )
        )
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let index = try dependencyPackage.makeAndBindSemanticIndex(
            at: semanticDatabase
        )

        let outsideVersion = outsideRoot
            .appendingPathComponent("Semantic", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideVersion,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [
            outsideRoot,
            outsideRoot.appendingPathComponent(
                "Semantic",
                isDirectory: true
            ),
            outsideVersion,
        ] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        let outsideDatabase = outsideVersion
            .appendingPathComponent("loki-semantic.sqlite3")
        let outsideFamily = P8SemanticPaths.databaseFamilyURLs(
            for: outsideDatabase
        )
        let markerData = outsideFamily.enumerated().map {
            Data("outside-override-\($0.offset)".utf8)
        }
        for (URL, data) in zip(outsideFamily, markerData) {
            try data.write(to: URL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: URL.path
            )
        }

        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                semanticIndex: index,
                semanticDatabaseURLOverride: outsideDatabase,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertThrowsError(
            try P8FeatureController(
                store: store,
                semanticIndex: index,
                semanticDatabaseURLOverride: outsideDatabase,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .databaseOpenFailed
            )
        }
        for (URL, data) in zip(outsideFamily, markerData) {
            XCTAssertEqual(try Data(contentsOf: URL), data)
        }
        await index.close()
    }

    func testFailedSignedSmokeDeleteCannotAuthorizeResetAfterReplacement()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try signedSmokeAdmission(for: root)
        let boundary = admission.storageBoundary
        let store = try signedSmokeFixtureStore(
            under: root,
            storageBoundary: boundary
        )
        let semanticDatabase = try XCTUnwrap(
            P8SemanticPaths.databaseURL(
                for: store,
                signedSmokeStorageBoundary: boundary
            )
        )
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: store,
                storageBoundary: boundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let index = try dependencyPackage.makeAndBindSemanticIndex(
            at: semanticDatabase
        )
        let feature = try P8FeatureController(
            store: store,
            semanticIndex: index,
            semanticDatabaseURLOverride: semanticDatabase,
            signedSmokeStorageBoundary: boundary,
            signedSmokeRuntimeAuthority:
                admission.runtimeAuthority,
            signedSmokeDependencyPackage: dependencyPackage
        )
        await feature.waitForCurrentWork()
        await index.close()

        let retainedDatabase = semanticDatabase
            .deletingLastPathComponent()
            .appendingPathComponent("retained-semantic.sqlite3")
        try FileManager.default.moveItem(
            at: semanticDatabase,
            to: retainedDatabase
        )
        let replacementMarker = Data(
            "replacement-must-survive-failed-delete".utf8
        )
        try replacementMarker.write(to: semanticDatabase)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: semanticDatabase.path
        )

        let deletionSucceeded =
            await feature.deleteAllP8DerivedAndCredentialData()
        XCTAssertFalse(deletionSucceeded)
        XCTAssertEqual(feature.semanticStorageState, .degraded)
        XCTAssertTrue(feature.semanticStatus.contains("incomplete"))
        XCTAssertFalse(
            feature.semanticStatus.contains("were deleted")
        )

        let resetSucceeded = await feature.resetAfterDeleteAll()
        XCTAssertFalse(resetSucceeded)
        XCTAssertEqual(
            try Data(contentsOf: semanticDatabase),
            replacementMarker
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retainedDatabase.path
            )
        )
    }

    func testHybridGenerationBindsAcceptedRuntimeProfileAndStaleProfileAllowsOnlyLexicalFallback()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding = P8ControllerFakeEmbeddingProvider(dimension: 3)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "vault-alpha")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let first = embeddingAssignment(
            modelIdentifier: "qwen3-embedding:0.6b",
            digest: String(repeating: "a", count: 64)
        )
        let accepted = embeddingAssessment(
            modelIdentifier: "qwen3-embedding:0.6b",
            digest: String(repeating: "a", count: 64),
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        feature.synchronizeModelRoles(
            [first],
            assessmentsByModelID: [
                "qwen3-embedding:0.6b": accepted
            ]
        )
        await feature.waitForCurrentWork()

        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let activeGeneration = try await index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        XCTAssertEqual(
            active.spec.embeddingModelIdentifier,
            "qwen3-embedding:0.6b"
        )
        XCTAssertEqual(
            active.spec.embeddingModelDigest,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(active.spec.vectorDimension, 3)
        XCTAssertEqual(active.spec.ollamaRuntimeVersion, "0.11.6")
        XCTAssertEqual(
            active.spec.embeddingRequestProfileVersion,
            OllamaEmbeddingRequestProfile.currentVersion
        )
        XCTAssertEqual(
            active.spec.embeddingRequestProfileHash,
            OllamaEmbeddingRequestProfile(dimensions: 3).stableHash
        )
        XCTAssertEqual(active.spec.embeddingDimensions, 3)
        XCTAssertEqual(active.spec.embeddingTruncate, false)
        XCTAssertEqual(
            active.spec.embeddingNormalizationVersion,
            OllamaEmbeddingRequestProfile.currentNormalizationVersion
        )
        XCTAssertNil(active.staleReason)

        let rebuildRequests = await embedding.requests
        XCTAssertFalse(rebuildRequests.isEmpty)
        XCTAssertTrue(
            rebuildRequests.allSatisfy { $0.dimensions == 3 }
        )

        feature.semanticMode = .semantic
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticResults.count, 1)

        let replacementAssessment = embeddingAssessment(
            modelIdentifier: "qwen3-embedding:0.6b",
            digest: String(repeating: "a", count: 64),
            dimension: 3,
            ollamaVersion: "0.11.7"
        )
        feature.synchronizeModelRoles(
            [first],
            assessmentsByModelID: [
                "qwen3-embedding:0.6b": replacementAssessment
            ]
        )
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertTrue(feature.semanticResults.isEmpty)
        await feature.waitForCurrentWork()
        let changedRoleHealth = try await index.health()
        XCTAssertEqual(changedRoleHealth.state, .stale)
        XCTAssertEqual(
            changedRoleHealth.activeGeneration?.staleReason,
            .embeddingRuntimeProfile
        )

        feature.semanticMode = .lexical
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticResults.count, 1)

        for mode in [SemanticSearchMode.semantic, .hybrid] {
            feature.semanticMode = mode
            feature.searchSemanticIndex()
            await feature.waitForCurrentWork()
            XCTAssertTrue(feature.semanticResults.isEmpty)
            XCTAssertEqual(
                feature.semanticHealth?.activeGeneration?.staleReason,
                .embeddingRuntimeProfile
            )
            XCTAssertTrue(
                feature.semanticStatus.contains(
                    "Lexical fallback remains available"
                )
            )
        }
        XCTAssertFalse(feature.hasActiveWork)
    }

    func testRuntimeDimensionDriftRevokesBindingAndPreservesLexicalFallback()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding = P8ControllerFakeEmbeddingProvider(dimension: 3)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "dimension-drift")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let assessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        var invalidations: [P8EmbeddingStabilityInvalidation] = []
        feature.configureEmbeddingStabilityInvalidationHandler {
            invalidations.append($0)
        }
        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [modelIdentifier: assessment]
        )
        await feature.waitForCurrentWork()
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticHealth?.state, .ready)
        XCTAssertTrue(feature.embeddingBindingIsReady)

        await embedding.setBehavior(.failure(.dimensionMismatch))
        let requestsBeforeDrift = await embedding.requests.count
        feature.semanticMode = .semantic
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()

        XCTAssertEqual(invalidations.count, 1)
        XCTAssertEqual(
            invalidations.first?.reasonCode,
            P8EmbeddingStabilityInvalidation.reasonCode
        )
        XCTAssertNil(feature.embeddingStabilityAssessment)
        XCTAssertFalse(feature.embeddingBindingIsReady)
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertEqual(
            feature.semanticHealth?.activeGeneration?.staleReason,
            .embeddingRuntimeProfile
        )
        XCTAssertTrue(feature.semanticStatus.contains("Reassess"))
        let requestsAfterDrift = await embedding.requests.count
        XCTAssertEqual(requestsAfterDrift, requestsBeforeDrift + 1)

        feature.semanticMode = .lexical
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(
            feature.semanticResults.first?.provenance
                .stableSourceIdentifier,
            "dimension-drift"
        )
        let requestsAfterLexical = await embedding.requests.count
        for mode in [SemanticSearchMode.semantic, .hybrid] {
            feature.semanticMode = mode
            feature.searchSemanticIndex()
            await feature.waitForCurrentWork()
            XCTAssertTrue(feature.semanticResults.isEmpty)
            let currentRequestCount = await embedding.requests.count
            XCTAssertEqual(currentRequestCount, requestsAfterLexical)
        }
    }

    func testMixedDimensionRebuildFailsBeforeReplacingReadyGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding = P8ControllerFakeEmbeddingProvider(dimension: 3)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "mixed-dimension")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "b", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let assessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [modelIdentifier: assessment]
        )
        await feature.waitForCurrentWork()
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let readyGeneration = try await index.activeGeneration()
        let readyIdentifier = try XCTUnwrap(readyGeneration).identifier

        await embedding.setBehavior(.failure(.mixedDimensions))
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        let activeAfter = try await index.activeGeneration()
        let after = try XCTUnwrap(activeAfter)
        XCTAssertEqual(after.identifier, readyIdentifier)
        XCTAssertEqual(after.state, .stale)
        XCTAssertEqual(after.staleReason, .embeddingRuntimeProfile)
        XCTAssertFalse(feature.embeddingBindingIsReady)
        feature.semanticMode = .lexical
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(
            feature.semanticResults.first?.provenance
                .stableSourceIdentifier,
            "mixed-dimension"
        )
    }

    func testFatalEmbeddingRuntimeFailuresInvalidateAcceptedStability()
        async throws
    {
        let cases: [
            (
                code: OllamaEmbeddingFailureCode,
                reasonCode: String
            )
        ] = [
            (
                .dimensionMismatch,
                P8EmbeddingStabilityInvalidation
                    .dimensionDriftReasonCode
            ),
            (
                .mixedDimensions,
                P8EmbeddingStabilityInvalidation
                    .dimensionDriftReasonCode
            ),
            (
                .nonFiniteVector,
                P8EmbeddingStabilityInvalidation
                    .nonFiniteVectorReasonCode
            ),
            (
                .zeroVector,
                P8EmbeddingStabilityInvalidation
                    .vectorCollapseReasonCode
            ),
            (
                .responseModelMismatch,
                P8EmbeddingStabilityInvalidation
                    .runtimeProfileStaleReasonCode
            ),
        ]

        for (offset, testCase) in cases.enumerated() {
            let context = try await makeReadyEmbeddingFeature(
                identifier: "fatal-\(offset)"
            )
            var invalidations: [P8EmbeddingStabilityInvalidation] = []
            context.feature
                .configureEmbeddingStabilityInvalidationHandler {
                    invalidations.append($0)
                }
            await context.embedding.setBehavior(
                .failure(testCase.code)
            )
            context.feature.semanticMode = .semantic
            context.feature.semanticQuery = "alpha"
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()

            XCTAssertEqual(
                invalidations.map(\.reasonCode),
                [testCase.reasonCode]
            )
            XCTAssertFalse(context.feature.embeddingBindingIsReady)
            XCTAssertNil(
                context.feature.embeddingStabilityAssessment
            )
            XCTAssertEqual(context.feature.semanticHealth?.state, .stale)
            XCTAssertEqual(
                context.feature.semanticHealth?.activeGeneration?
                    .staleReason,
                .embeddingRuntimeProfile
            )
            let requestsAfterFailure =
                await context.embedding.requests.count

            context.feature.semanticMode = .lexical
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()
            XCTAssertEqual(
                context.feature.semanticResults.first?.provenance
                    .stableSourceIdentifier,
                "fatal-\(offset)"
            )
            for mode in [
                SemanticSearchMode.semantic,
                .hybrid,
            ] {
                context.feature.semanticMode = mode
                context.feature.searchSemanticIndex()
                await context.feature.waitForCurrentWork()
                XCTAssertTrue(
                    context.feature.semanticResults.isEmpty
                )
            }
            let finalRequestCount =
                await context.embedding.requests.count
            XCTAssertEqual(finalRequestCount, requestsAfterFailure)
        }
    }

    func testNativeMalformedResponseInvalidatesAcceptedStability()
        async throws
    {
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: semanticGenerationSpec(
                modelIdentifier: modelIdentifier,
                digest: digest
            )
        )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: NativeOllamaEmbeddingProvider(
                transport: P8MalformedEmbeddingTransport()
            ),
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        feature.synchronizeModelRoles(
            [
                embeddingAssignment(
                    modelIdentifier: modelIdentifier,
                    digest: digest
                ),
            ],
            assessmentsByModelID: [
                modelIdentifier: embeddingAssessment(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 3,
                    ollamaVersion: "0.11.6"
                ),
            ]
        )
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.embeddingBindingIsReady)

        var invalidations: [P8EmbeddingStabilityInvalidation] = []
        feature.configureEmbeddingStabilityInvalidationHandler {
            invalidations.append($0)
        }
        feature.semanticMode = .semantic
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()

        XCTAssertEqual(
            invalidations.map(\.reasonCode),
            [
                P8EmbeddingStabilityInvalidation
                    .responseParsingDefectReasonCode,
            ]
        )
        XCTAssertFalse(feature.embeddingBindingIsReady)
        XCTAssertNil(feature.embeddingStabilityAssessment)
        XCTAssertEqual(
            feature.semanticHealth?.activeGeneration?.staleReason,
            .embeddingRuntimeProfile
        )
    }

    func testReceiptIdentityMismatchInvalidatesAcceptedStability()
        async throws
    {
        let behaviors: [P8ControllerEmbeddingBehavior] = [
            .responseModelIdentifier("unexpected:latest"),
            .mismatchedRequestProfileHash(
                String(repeating: "9", count: 64)
            ),
            .missingRequestIdentity,
        ]
        for (offset, behavior) in behaviors.enumerated() {
            let context = try await makeReadyEmbeddingFeature(
                identifier: "identity-\(offset)"
            )
            var invalidations: [P8EmbeddingStabilityInvalidation] = []
            context.feature
                .configureEmbeddingStabilityInvalidationHandler {
                    invalidations.append($0)
                }
            await context.embedding.setBehavior(behavior)
            context.feature.semanticMode = .semantic
            context.feature.semanticQuery = "alpha"
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()

            XCTAssertEqual(
                invalidations.map(\.reasonCode),
                [
                    P8EmbeddingStabilityInvalidation
                        .runtimeProfileStaleReasonCode,
                ]
            )
            XCTAssertFalse(context.feature.embeddingBindingIsReady)
            XCTAssertEqual(
                context.feature.semanticHealth?.activeGeneration?
                    .staleReason,
                .embeddingRuntimeProfile
            )
        }
    }

    func testTransientEmbeddingFailuresPreserveAcceptedStability()
        async throws
    {
        let codes: [OllamaEmbeddingFailureCode] = [
            .serviceUnavailable,
            .requestTimedOut,
            .requestCancelled,
            .httpFailure,
        ]
        for (offset, code) in codes.enumerated() {
            let context = try await makeReadyEmbeddingFeature(
                identifier: "transient-\(offset)"
            )
            let readyGeneration =
                try await context.index.activeGeneration()
            let readyIdentifier =
                try XCTUnwrap(readyGeneration).identifier
            var invalidations: [P8EmbeddingStabilityInvalidation] = []
            context.feature
                .configureEmbeddingStabilityInvalidationHandler {
                    invalidations.append($0)
                }
            await context.embedding.setBehavior(.failure(code))
            context.feature.semanticMode = .semantic
            context.feature.semanticQuery = "alpha"
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()

            XCTAssertTrue(invalidations.isEmpty)
            XCTAssertTrue(context.feature.embeddingBindingIsReady)
            let generationAfterFailure =
                try await context.index.activeGeneration()
            let afterFailure = try XCTUnwrap(
                generationAfterFailure
            )
            XCTAssertEqual(afterFailure.identifier, readyIdentifier)
            XCTAssertEqual(afterFailure.state, .ready)

            await context.embedding.setBehavior(.stable)
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()
            XCTAssertFalse(context.feature.semanticResults.isEmpty)
            XCTAssertTrue(context.feature.embeddingBindingIsReady)
        }
    }

    func testMidBuildFatalFailurePreservesPriorGenerationForLexicalFallback()
        async throws
    {
        let context = try await makeReadyEmbeddingFeature(
            identifier: "mid-build-fatal"
        )
        var invalidations: [P8EmbeddingStabilityInvalidation] = []
        context.feature
            .configureEmbeddingStabilityInvalidationHandler {
                invalidations.append($0)
            }
        let priorGeneration =
            try await context.index.activeGeneration()
        let priorIdentifier =
            try XCTUnwrap(priorGeneration).identifier
        await context.embedding.setBehavior(
            .failAfterSuccessfulRequests(1, .nonFiniteVector)
        )
        context.feature.rebuildSemanticIndex()
        await context.feature.waitForCurrentWork()

        let activeGeneration =
            try await context.index.activeGeneration()
        let active = try XCTUnwrap(activeGeneration)
        XCTAssertEqual(active.identifier, priorIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(active.staleReason, .embeddingRuntimeProfile)
        XCTAssertEqual(
            invalidations.map(\.reasonCode),
            [
                P8EmbeddingStabilityInvalidation
                    .nonFiniteVectorReasonCode,
            ]
        )
        context.feature.semanticMode = .lexical
        context.feature.semanticQuery = "alpha"
        context.feature.searchSemanticIndex()
        await context.feature.waitForCurrentWork()
        XCTAssertEqual(
            context.feature.semanticResults.first?.provenance
                .stableSourceIdentifier,
            "mid-build-fatal"
        )
    }

    func testCrossBatchFloatCollapseAfterPartialCommitFailsClosed()
        async throws
    {
        let committedRecordCount =
            SemanticIndexLimits.maximumRecordsPerBatch
        let identifiers = (0...committedRecordCount).map {
            String(format: "batch-collapse-%03d", $0)
        }
        let context = try await makeReadyEmbeddingFeature(
            identifiers: identifiers,
            initialBehavior: .strongStable
        )
        let priorGeneration =
            try await context.index.activeGeneration()
        let priorIdentifier =
            try XCTUnwrap(priorGeneration).identifier
        var invalidations: [P8EmbeddingStabilityInvalidation] = []
        context.feature
            .configureEmbeddingStabilityInvalidationHandler {
                invalidations.append($0)
            }
        let workRequestsInCommittedBatch =
            (
                committedRecordCount
                    + OllamaEmbeddingLimits.maximumBatchCount
                    - 1
            ) / OllamaEmbeddingLimits.maximumBatchCount
        let dimensionProbeRequestCount = 1
        let successfulRequestsBeforeCollision =
            dimensionProbeRequestCount + workRequestsInCommittedBatch
        let requestCountBeforeFailure =
            await context.embedding.requests.count
        await context.embedding.setBehavior(
            .collapseAcrossRequestBoundaryAfterSuccessfulRequests(
                successfulRequestsBeforeCollision
            )
        )
        context.feature.rebuildSemanticIndex()
        await context.feature.waitForCurrentWork()

        let generation =
            try await context.index.activeGeneration()
        let active = try XCTUnwrap(generation)
        XCTAssertEqual(active.identifier, priorIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(active.staleReason, .embeddingRuntimeProfile)
        XCTAssertEqual(active.sourceCount, identifiers.count)
        XCTAssertEqual(active.chunkCount, identifiers.count)
        let requestCountAfterFailure =
            await context.embedding.requests.count
        XCTAssertEqual(
            requestCountAfterFailure - requestCountBeforeFailure,
            successfulRequestsBeforeCollision + 1
        )
        XCTAssertEqual(
            invalidations.map(\.reasonCode),
            [
                P8EmbeddingStabilityInvalidation
                    .vectorCollapseReasonCode,
            ]
        )
        XCTAssertFalse(context.feature.embeddingBindingIsReady)
        context.feature.semanticMode = .lexical
        context.feature.semanticQuery = "alpha"
        context.feature.searchSemanticIndex()
        await context.feature.waitForCurrentWork()
        XCTAssertFalse(context.feature.semanticResults.isEmpty)
    }

    func testFloatConversionOverflowAndUnderflowInvalidateStability()
        async throws
    {
        let cases: [
            (
                vector: [Double],
                reasonCode: String
            )
        ] = [
            (
                [Double.greatestFiniteMagnitude, 0, 0],
                P8EmbeddingStabilityInvalidation
                    .nonFiniteVectorReasonCode
            ),
            (
                [Double.leastNonzeroMagnitude, 0, 0],
                P8EmbeddingStabilityInvalidation
                    .vectorCollapseReasonCode
            ),
        ]
        for (offset, testCase) in cases.enumerated() {
            let context = try await makeReadyEmbeddingFeature(
                identifier: "float-\(offset)"
            )
            var invalidations: [P8EmbeddingStabilityInvalidation] = []
            context.feature
                .configureEmbeddingStabilityInvalidationHandler {
                    invalidations.append($0)
                }
            await context.embedding.setBehavior(
                .fixedVector(testCase.vector)
            )
            context.feature.semanticMode = .semantic
            context.feature.semanticQuery = "alpha"
            context.feature.searchSemanticIndex()
            await context.feature.waitForCurrentWork()
            XCTAssertEqual(
                invalidations.map(\.reasonCode),
                [testCase.reasonCode]
            )
            XCTAssertFalse(context.feature.embeddingBindingIsReady)
        }
    }

    func testPausedEmbeddingBindingChangeReconcilesOnResume()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let initialAssessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(dimension: 3),
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "pause-reconcile")]
            },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [
                modelIdentifier: initialAssessment
            ]
        )
        await feature.waitForCurrentWork()
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let readyGeneration = try await index.activeGeneration()
        XCTAssertEqual(
            readyGeneration?.state,
            .ready
        )

        await feature.prepareForLifecyclePause()
        XCTAssertTrue(feature.lifecycleIsPaused)
        let changedAssessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.7"
        )
        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [
                modelIdentifier: changedAssessment
            ]
        )
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertFalse(feature.hasActiveWork)

        feature.resumeAfterLifecyclePause()
        await feature.waitForCurrentWork()
        let reconciled = try await index.activeGeneration()
        XCTAssertEqual(reconciled?.state, .stale)
        XCTAssertEqual(
            reconciled?.staleReason,
            .embeddingRuntimeProfile
        )
        XCTAssertEqual(
            feature.semanticHealth?.activeGeneration?.staleReason,
            .embeddingRuntimeProfile
        )
        XCTAssertTrue(
            feature.semanticStatus.contains(
                "Lexical fallback remains available"
            )
        )
        XCTAssertFalse(feature.hasActiveWork)
    }

    func testInitialRoleHydrationPreservesMatchingReadyGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let assessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        let first = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(dimension: 3),
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "hydration-ready")]
            },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        first.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [modelIdentifier: assessment]
        )
        await first.waitForCurrentWork()
        first.semanticBuildSourceKinds = [.vaultRecord]
        first.rebuildSemanticIndex()
        await first.waitForCurrentWork()
        let initialGeneration = try await index.activeGeneration()
        XCTAssertEqual(initialGeneration?.state, .ready)

        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(dimension: 3),
            permittedVaultSemanticRecordsProvider: { [] },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        reopened.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [modelIdentifier: assessment]
        )
        await reopened.waitForCurrentWork()

        let hydratedGeneration =
            try await index.activeGeneration()
        XCTAssertEqual(hydratedGeneration?.state, .ready)
        XCTAssertNil(hydratedGeneration?.staleReason)
        XCTAssertEqual(reopened.semanticHealth?.state, .ready)
    }

    func testReopenPersistedSourceAdditionMarksActiveScopeChanged()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.brief]
                )
            )
        )
        let selectionStore =
            P8VolatileSemanticBuildSourceSelectionStore()
        try selectionStore.save([.brief, .schedule])
        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticBuildSourceSelectionStore: selectionStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertEqual(reopened.semanticHealth?.state, .stale)
        await reopened.waitForCurrentWork()
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeChanged
        )
        XCTAssertEqual(
            active.staleReason,
            .sourceScopeChanged
        )
        XCTAssertTrue(
            reopened.semanticSourceAuthorityEvents.contains {
                $0.name == .generationScopeChanged
                    && $0.status == "blocked"
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourceScopeChanged.rawValue
                    && $0.authorizationReceiptIdentifier
                        == "p8_controller_test_scope"
            }
        )
        await assertAllSemanticSearchModesBlocked(reopened)
    }

    func testReopenExplicitEmptySelectionRevokesActiveSourcePermission()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.brief]
                )
            )
        )
        let selectionStore =
            P8VolatileSemanticBuildSourceSelectionStore()
        try selectionStore.save([])
        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticBuildSourceSelectionStore: selectionStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertTrue(reopened.semanticBuildSourceKinds.isEmpty)
        await reopened.waitForCurrentWork()
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourcePermissionRevoked
        )
        XCTAssertEqual(
            active.staleReason,
            .sourcePermissionRevoked
        )
        XCTAssertTrue(
            reopened.semanticSourceAuthorityEvents.contains {
                $0.name == .generationPermissionRevoked
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourcePermissionRevoked.rawValue
            }
        )
        await assertAllSemanticSearchModesBlocked(reopened)
    }

    func testReopenMalformedSelectionMarksActiveScopeUnknown()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.brief]
                )
            )
        )
        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticBuildSourceSelectionStore:
                P8MalformedSemanticBuildSourceSelectionStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertTrue(reopened.semanticBuildSourceKinds.isEmpty)
        await reopened.waitForCurrentWork()
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeUnknown
        )
        XCTAssertEqual(active.staleReason, .sourceScopeUnknown)
        XCTAssertTrue(
            reopened.semanticSourceAuthorityEvents.contains {
                $0.name == .generationScopeUnknown
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourceScopeUnknown.rawValue
            }
        )
        await assertAllSemanticSearchModesBlocked(reopened)
    }

    func testReopenAbsentSelectionPreservesMatchingActiveGeneration()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let initial = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.brief]
                )
            )
        )
        let selectionStore =
            P8VolatileSemanticBuildSourceSelectionStore()
        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticBuildSourceSelectionStore: selectionStore,
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        XCTAssertTrue(reopened.semanticBuildSourceKinds.isEmpty)
        reopened.refreshSemanticHealth()
        await reopened.waitForCurrentWork()
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(active.identifier, initial.identifier)
        XCTAssertEqual(active.state, .ready)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeReady
        )
        XCTAssertNil(active.staleReason)
        XCTAssertEqual(reopened.semanticHealth?.state, .lexicalOnly)
    }

    func testReopenAdapterContractDriftRequiresExplicitRebuild()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.brief]
                )
            )
        )
        let reopened = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(),
            semanticSourceProviders: [
                .init(
                    sourceKind: .brief,
                    contractVersion:
                        "p8.semantic-source.brief.v2"
                ) { [] },
            ],
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        reopened.refreshSemanticHealth()
        await reopened.waitForCurrentWork()
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeRebuildRequired
        )
        XCTAssertEqual(
            active.staleReason,
            .sourceScopeRebuildRequired
        )
        XCTAssertTrue(
            reopened.semanticSourceAuthorityEvents.contains {
                $0.name == .generationScopeRebuildRequired
                    && $0.reasonCode
                        == SemanticIndexStaleReason
                        .sourceScopeRebuildRequired.rawValue
            }
        )
        await assertAllSemanticSearchModesBlocked(reopened)
    }

    func testInitialRoleHydrationClassifiesCompleteGenerationIdentity()
        async throws
    {
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let assessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )
        let mismatches: [
            (
                label: String,
                specification: SemanticIndexGenerationSpec,
                reason: SemanticIndexStaleReason
            )
        ] = [
            (
                "chunker",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    chunkerVersion: "semantic-chunker-old"
                ),
                .canonicalSourcePolicy
            ),
            (
                "semantic-normalizer",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    normalizationVersion: "semantic-normalizer-old"
                ),
                .canonicalSourcePolicy
            ),
            (
                "source-schema",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    sourceSchemaVersion: "loki_brief_v8"
                ),
                .canonicalSourcePolicy
            ),
            (
                "ollama-runtime",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    ollamaVersion: "0.11.5"
                ),
                .embeddingRuntimeProfile
            ),
            (
                "request-profile",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    requestProfileVersion: "loki-embedding-request-old",
                    requestProfileHash: String(repeating: "b", count: 64)
                ),
                .embeddingRuntimeProfile
            ),
            (
                "vector-dimension",
                try semanticGenerationSpec(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 4
                ),
                .embeddingRuntimeProfile
            ),
        ]

        for mismatch in mismatches {
            let index = try SemanticVaultIndex(inMemory: true)
            _ = try await publishEmptyGeneration(
                index: index,
                specification: mismatch.specification
            )
            let feature = try P8FeatureController(
                store: LocalStore(inMemory: true),
                semanticIndex: index,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(dimension: 3),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )

            feature.synchronizeModelRoles(
                [assignment],
                assessmentsByModelID: [modelIdentifier: assessment]
            )
            await feature.waitForCurrentWork()

            let active = try await index.activeGeneration()
            XCTAssertEqual(active?.state, .stale, mismatch.label)
            XCTAssertEqual(
                active?.staleReason,
                mismatch.reason,
                mismatch.label
            )
            XCTAssertEqual(
                feature.semanticHealth?.reasonCode,
                mismatch.reason.rawValue,
                mismatch.label
            )
        }
    }

    func testBindingChangeDuringStagedBuildDoesNotPublishPartialGeneration()
        async throws
    {
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let index = try SemanticVaultIndex(inMemory: true)
        let generation = try await index.beginGeneration(
            spec: semanticGenerationSpec(
                modelIdentifier: modelIdentifier,
                digest: digest,
                ollamaVersion: "0.11.5"
            )
        )
        XCTAssertEqual(generation.state, .building)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(dimension: 3),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        let assessment = embeddingAssessment(
            modelIdentifier: modelIdentifier,
            digest: digest,
            dimension: 3,
            ollamaVersion: "0.11.6"
        )

        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [modelIdentifier: assessment]
        )
        await feature.waitForCurrentWork()

        let active = try await index.activeGeneration()
        XCTAssertNil(active)
        let staged = try await index.generation(
            identifier: generation.identifier
        )
        XCTAssertEqual(staged?.state, .building)
        XCTAssertEqual(feature.semanticHealth?.state, .empty)
        XCTAssertTrue(feature.embeddingBindingIsReady)

        feature.semanticMode = .lexical
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertTrue(
            feature.semanticStatus.contains("No active")
                || feature.semanticStatus.contains("No index")
        )
    }

    func testInitialNoRoleHydrationReconcilesLexicalGenerationIdentity()
        async throws
    {
        let cases: [
            (
                label: String,
                specification: SemanticIndexGenerationSpec,
                expectedState: SemanticIndexGenerationState,
                expectedReason: SemanticIndexStaleReason?
            )
        ] = [
            (
                "current",
                try .lexicalOnly(
                    sourceSchemaVersion: "loki_brief_v9",
                    buildScope: syntheticBuildScope()
                ),
                .ready,
                nil
            ),
            (
                "old-source-schema",
                try .lexicalOnly(
                    sourceSchemaVersion: "loki_brief_v8",
                    buildScope: syntheticBuildScope()
                ),
                .stale,
                .canonicalSourcePolicy
            ),
        ]

        for fixture in cases {
            let index = try SemanticVaultIndex(inMemory: true)
            _ = try await publishEmptyGeneration(
                index: index,
                specification: fixture.specification
            )
            let feature = try P8FeatureController(
                store: LocalStore(inMemory: true),
                semanticIndex: index,
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(dimension: 3),
                webCredentialStore:
                    P8ControllerFakeCredentialStore(),
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )

            feature.synchronizeModelRoles([])
            await feature.waitForCurrentWork()

            let active = try await index.activeGeneration()
            XCTAssertEqual(
                active?.state,
                fixture.expectedState,
                fixture.label
            )
            XCTAssertEqual(
                active?.staleReason,
                fixture.expectedReason,
                fixture.label
            )
            XCTAssertEqual(
                feature.semanticHealth?.state,
                fixture.expectedState == .ready
                    ? .lexicalOnly
                    : .stale,
                fixture.label
            )
            if fixture.expectedReason == .canonicalSourcePolicy {
                feature.semanticMode = .lexical
                feature.semanticQuery = "canonical freshness"
                feature.searchSemanticIndex()
                await feature.waitForCurrentWork()
                XCTAssertTrue(
                    feature.semanticStatus.contains("stale"),
                    fixture.label
                )
            }
        }
    }

    func testInitialVaultProviderWiringPreservesReadyGenerationButReplacementInvalidates()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        _ = try await publishEmptyGeneration(
            index: index,
            specification: .lexicalOnly(
                sourceSchemaVersion: "loki_brief_v9",
                buildScope: syntheticBuildScope(
                    sourceKinds: [.vaultRecord]
                )
            )
        )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider:
                P8ControllerFakeEmbeddingProvider(dimension: 3),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )

        feature.configurePermittedVaultSemanticRecordsProvider { [] }
        feature.synchronizeModelRoles([])
        await feature.waitForCurrentWork()
        let initiallyWired = try await index.activeGeneration()
        XCTAssertEqual(initiallyWired?.state, .ready)
        XCTAssertNil(initiallyWired?.staleReason)

        feature.configurePermittedVaultSemanticRecordsProvider { [] }
        await feature.waitForCurrentWork()
        let replaced = try await index.activeGeneration()
        XCTAssertEqual(replaced?.state, .stale)
        XCTAssertEqual(
            replaced?.staleReason,
            .canonicalSourcePolicy
        )
    }

    func testHybridRebuildRejectsMismatchedRequestProfileIdentity()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding = P8ControllerFakeEmbeddingProvider(
            dimension: 3,
            requestProfileHashOverride:
                String(repeating: "0", count: 64)
        )
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "vault-profile-mismatch")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        let assignment = embeddingAssignment(
            modelIdentifier: modelIdentifier,
            digest: digest
        )
        feature.synchronizeModelRoles(
            [assignment],
            assessmentsByModelID: [
                modelIdentifier: embeddingAssessment(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 3,
                    ollamaVersion: "0.11.6"
                )
            ]
        )
        await feature.waitForCurrentWork()

        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        let activeGeneration = try await index.activeGeneration()
        XCTAssertNil(activeGeneration)
        XCTAssertFalse(feature.embeddingBindingIsReady)
        XCTAssertNil(feature.embeddingStabilityAssessment)
        XCTAssertTrue(
            feature.semanticStatus.contains(
                P8EmbeddingStabilityInvalidation
                    .runtimeProfileStaleReasonCode
            )
        )
        let requests = await embedding.requests
        XCTAssertEqual(requests.map(\.dimensions), [3])
    }

    func testPermittedVaultMergeInvalidationAndPreparationLimitAreFailClosed()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "permitted-vault")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let mergedGeneration = try await index.activeGeneration()
        XCTAssertEqual(mergedGeneration?.sourceCount, 1)
        XCTAssertEqual(
            mergedGeneration?.spec.retrievalCapability,
            .lexicalOnly
        )
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticResults.count, 1)

        let invalidation = feature.beginSemanticSourceInvalidation(
            reasonCode: "test_vault_record_deleted"
        )
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        await invalidation?.value
        let invalidatedHealth = try await index.health()
        XCTAssertEqual(invalidatedHealth.state, .stale)
        XCTAssertEqual(
            invalidatedHealth.activeGeneration?.staleReason,
            .canonicalSourcePolicy
        )

        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertTrue(feature.semanticStatus.contains("stale"))

        let limited = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: try SemanticVaultIndex(inMemory: true),
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            semanticSourcePreparationBudget: .init(
                maximumRecords: 1,
                maximumTotalTextBytes: 1_024,
                maximumRecordTextBytes: 1_024
            ),
            permittedVaultSemanticRecordsProvider: {
                [
                    try Self.vaultRecord(identifier: "one"),
                    try Self.vaultRecord(identifier: "two"),
                ]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        limited.semanticBuildSourceKinds = [.vaultRecord]
        limited.rebuildSemanticIndex()
        await limited.waitForCurrentWork()
        XCTAssertTrue(limited.semanticStatus.contains("record limit"))
        XCTAssertNil(limited.semanticHealth?.activeGeneration)
    }

    func testNoncooperativeLateSearchCannotPublishAfterSourceDeletionInvalidation()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding =
            P8NoncooperativeSearchEmbeddingProvider()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "late-search-vault")]
            },
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        feature.synchronizeModelRoles(
            [
                embeddingAssignment(
                    modelIdentifier: modelIdentifier,
                    digest: digest
                ),
            ],
            assessmentsByModelID: [
                modelIdentifier: embeddingAssessment(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 3,
                    ollamaVersion: "0.11.6"
                ),
            ]
        )
        await feature.waitForCurrentWork()
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()

        feature.semanticMode = .semantic
        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticResults.count, 1)

        await embedding.armNextRequest()
        feature.searchSemanticIndex()
        await embedding.waitUntilRequestIsBlocked()
        let invalidation = feature.beginSemanticSourceInvalidation(
            reasonCode: "semantic_index_source_deleted"
        )
        XCTAssertTrue(feature.semanticResults.isEmpty)

        await embedding.releaseBlockedRequest()
        await invalidation?.value
        await feature.waitForCurrentWork()

        XCTAssertTrue(feature.semanticResults.isEmpty)
        let active =
            try await requireActiveGeneration(in: index)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(
            active.staleReason,
            .canonicalSourcePolicy
        )
    }

    func testSemanticSourcePurgeFailsClosedImmediatelyAndDeletesDerivedRows()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            permittedVaultSemanticRecordsProvider: {
                [try Self.vaultRecord(identifier: "purged-vault-record")]
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let published = try await requireActiveGeneration(in: index)

        feature.semanticQuery = "alpha"
        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.semanticResults.count, 1)

        let purge = feature.beginSemanticSourceAuthorityMutationPurge(
            reasonCode: "semantic_index_attached_source_consent_revoked"
        )
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertEqual(feature.semanticHealth?.state, .stale)
        XCTAssertTrue(feature.semanticSourceAuthorityMutationIsHeld)

        await purge?.value
        let health = try await index.health()
        XCTAssertEqual(health.state, .empty)
        XCTAssertNil(health.activeGeneration)
        let deletedGeneration = try await index.generation(
            identifier: published.identifier
        )
        XCTAssertNil(deletedGeneration)
        XCTAssertTrue(feature.semanticResults.isEmpty)
        XCTAssertTrue(feature.semanticStatus.contains("were deleted"))

        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        let generationWhileAuthorityHeld = try await index.activeGeneration()
        XCTAssertNil(generationWhileAuthorityHeld)
        XCTAssertTrue(feature.semanticSourceAuthorityMutationIsHeld)

        feature.searchSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.semanticResults.isEmpty)
        let activeAfterRejectedSearch = try await index.activeGeneration()
        XCTAssertNil(activeAfterRejectedSearch)
        XCTAssertTrue(feature.completeSemanticSourceAuthorityMutation())
        XCTAssertFalse(feature.semanticSourceAuthorityMutationIsHeld)
    }

    func testBatchVisionDataPreservesDropOrderAndPauseDrainsWork()
        async throws
    {
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: try SemanticVaultIndex(inMemory: true),
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let image = try syntheticPNG(width: 5, height: 4)
        let first = UUID(
            uuidString: "81000000-0000-0000-0000-000000000001"
        )!
        let second = UUID(
            uuidString: "81000000-0000-0000-0000-000000000002"
        )!
        feature.addVisionDataBatch([
            .init(
                id: first,
                source: .dragAndDrop,
                data: image,
                declaredTypeIdentifier: UTType.png.identifier
            ),
            .init(
                id: second,
                source: .dragAndDrop,
                data: image,
                declaredTypeIdentifier: UTType.png.identifier
            ),
        ])
        await feature.waitForCurrentWork()
        XCTAssertEqual(
            feature.visionAttachments.map(\.id),
            [first, second]
        )

        await feature.prepareForLifecyclePause()
        XCTAssertTrue(feature.lifecycleIsPaused)
        XCTAssertFalse(feature.hasActiveWork)
        XCTAssertTrue(feature.visionAttachments.isEmpty)
        feature.resumeAfterLifecyclePause()
        XCTAssertFalse(feature.lifecycleIsPaused)
    }

    func testFilePickerURLFlowImportsSyntheticImageThroughController()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(
            "synthetic-file-picker.png",
            isDirectory: false
        )
        let image = try syntheticPNG(width: 7, height: 5)
        try image.write(to: fileURL, options: .atomic)
        let feature = try makeVisionFeature()

        feature.addVisionFiles([fileURL], source: .filePicker)
        await feature.waitForCurrentWork()

        let attachment = try XCTUnwrap(feature.visionAttachments.first)
        XCTAssertEqual(feature.visionAttachments.count, 1)
        XCTAssertEqual(attachment.source, .filePicker)
        XCTAssertEqual(attachment.originalFormat, .png)
        XCTAssertEqual(
            attachment.pixelSize,
            .init(width: 7, height: 5)
        )
        XCTAssertEqual(
            feature.visionStatus,
            "1 bounded local image attachment ready."
        )

        let modelData = try await feature.consumeVisionModelData()
        XCTAssertEqual(modelData.count, 1)
        XCTAssertNotNil(
            CGImageSourceCreateWithData(modelData[0] as CFData, nil)
        )
        XCTAssertTrue(feature.visionAttachments.isEmpty)
    }

    func testNSItemProviderDropCallbackLoadsOrderedBatchThroughController()
        async throws
    {
        let feature = try makeVisionFeature()
        let first = try syntheticPNG(width: 3, height: 2)
        let second = try syntheticPNG(width: 6, height: 4)
        let unsupported = NSItemProvider(
            item: Data("synthetic text".utf8) as NSData,
            typeIdentifier: UTType.plainText.identifier
        )

        let accepted = feature.acceptDroppedVisionItems([
            unsupported,
            itemProvider(data: first, typeIdentifier: UTType.png.identifier),
            itemProvider(data: second, typeIdentifier: UTType.png.identifier),
        ])
        XCTAssertTrue(accepted)
        await feature.waitForCurrentWork()

        XCTAssertEqual(
            feature.visionAttachments.map(\.source),
            [.dragAndDrop, .dragAndDrop]
        )
        XCTAssertEqual(
            feature.visionAttachments.map(\.pixelSize),
            [
                .init(width: 3, height: 2),
                .init(width: 6, height: 4),
            ]
        )
        XCTAssertEqual(
            feature.visionStatus,
            "2 bounded local image attachments ready."
        )

        await feature.cancelAndClearVisionAttachments()
        XCTAssertTrue(feature.visionAttachments.isEmpty)
    }

    func testPasteVisionAttachmentUsesNamedSyntheticClipboard()
        async throws
    {
        let feature = try makeVisionFeature()
        let pasteboard = NSPasteboard(
            name: .init(
                "agent-loki-p8-tests-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let image = try syntheticPNG(width: 8, height: 3)
        XCTAssertTrue(pasteboard.setData(image, forType: .png))

        feature.pasteVisionAttachment(from: pasteboard)
        await feature.waitForCurrentWork()

        let attachment = try XCTUnwrap(feature.visionAttachments.first)
        XCTAssertEqual(feature.visionAttachments.count, 1)
        XCTAssertEqual(attachment.source, .clipboardPaste)
        XCTAssertEqual(attachment.originalFormat, .png)
        XCTAssertEqual(
            attachment.pixelSize,
            .init(width: 8, height: 3)
        )
        XCTAssertEqual(
            feature.visionStatus,
            "1 bounded local image attachment ready."
        )

        await feature.cancelAndClearVisionAttachments()
        XCTAssertTrue(feature.visionAttachments.isEmpty)
    }

    func testLifecyclePauseCancelsAndDrainsTrackedWebDispatch() async throws {
        let credentialStore = P8ControllerFakeCredentialStore()
        let webProvider = P8ControllerBlockingWebProvider()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: try SemanticVaultIndex(inMemory: true),
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            webCredentialStore: credentialStore,
            webResearchProvider: webProvider
        )
        await feature.refreshWebCredentialStatusNow()
        feature.updateWebGlobalSettings(
            providerEnabled: true,
            disclosureAccepted: true
        )
        feature.updateWebConversationPolicy(
            conversationIdentifier: "conversation-pause",
            enabled: true
        )
        feature.webQueryPreview = "bounded synthetic query"
        feature.approveWebQueryPreview()
        let call = OllamaChatToolCall(
            id: "web-pause-call",
            name: "web_search",
            argumentsJSON: try JSONSerialization.data(
                withJSONObject: [
                    "query": "bounded synthetic query",
                    "max_results": 1,
                ]
            )
        )
        let execution = Task {
            try await feature.executeWebResearchToolCall(
                call,
                conversationIdentifier: "conversation-pause",
                session: .init(effectiveContextTokens: 8_192)
            )
        }
        let becameActive = await waitUntil {
            feature.hasActiveWork
        }
        XCTAssertTrue(becameActive)

        await feature.prepareForLifecyclePause()
        XCTAssertFalse(feature.hasActiveWork)
        XCTAssertTrue(feature.lifecycleIsPaused)
        _ = await execution.result
        let cancelledRequestCount =
            await webProvider.cancelledRequestIdentifiers.count
        XCTAssertEqual(cancelledRequestCount, 1)
    }

    func testSignedSmokeWebCredentialSealProvesAbsenceWithoutReadAndRejectsEveryAccess()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(
            url: root.appendingPathComponent(
                "signed-smoke-web.sqlite3"
            )
        )
        let provider = P8ControllerBlockingWebProvider()
        let feature = try P8FeatureController(
            store: store,
            semanticIndex: try SemanticVaultIndex(inMemory: true),
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            webCredentialStore:
                VolatileOllamaWebResearchCredentialStore(),
            webResearchProvider: provider
        )

        XCTAssertTrue(
            feature
                .declareSignedSmokeWebCredentialAbsentWithoutRead()
        )
        XCTAssertTrue(
            feature.signedSmokeWebCredentialSealIsActive
        )
        XCTAssertFalse(
            feature.shouldRefreshWebCredentialStatusOnAppear
        )
        XCTAssertEqual(feature.webCredentialConfigured, false)
        XCTAssertEqual(
            feature.signedSmokeWebResearchDisabledReasonCode,
            .disabledWithoutKey
        )
        XCTAssertEqual(
            feature.webStatus,
            P8SignedSmokeWebResearchReasonCode
                .disabledWithoutKey
                .displayText
        )
        feature.updateWebGlobalSettings(
            providerEnabled: true,
            disclosureAccepted: true
        )
        XCTAssertFalse(feature.webGlobalSettings.providerEnabled)
        XCTAssertFalse(
            feature.webGlobalSettings
                .externalNetworkDisclosureAccepted
        )
        XCTAssertEqual(
            feature.webStatus,
            P8SignedSmokeWebResearchReasonCode
                .disabledWithoutKey
                .displayText
        )
        XCTAssertEqual(
            feature.signedSmokeWebCredentialSealSnapshot,
            .init(
                isSealed: true,
                storeAttemptCount: 0,
                readAttemptCount: 0,
                deleteAttemptCount: 0,
                rejectedStoreAttemptCount: 0,
                rejectedReadAttemptCount: 0,
                rejectedDeleteAttemptCount: 0,
                activeStoreCount: 0,
                activeReadCount: 0,
                activeDeleteCount: 0
            )
        )

        await feature.refreshWebCredentialStatusNow()
        XCTAssertEqual(feature.webCredentialConfigured, false)
        XCTAssertEqual(
            feature.webStatus,
            P8SignedSmokeWebResearchReasonCode
                .disabledWithoutKey
                .displayText
        )

        feature.webAPIKeyDraft =
            "signed-smoke-key-must-not-store"
        feature.storeWebAPIKey()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.webCredentialConfigured, false)
        XCTAssertEqual(
            feature.webStatus,
            P8SignedSmokeWebResearchReasonCode
                .disabledWithoutKey
                .displayText
        )

        feature.removeWebAPIKey()
        await feature.waitForCurrentWork()
        XCTAssertEqual(feature.webCredentialConfigured, false)
        XCTAssertEqual(
            feature.webStatus,
            P8SignedSmokeWebResearchReasonCode
                .disabledWithoutKey
                .displayText
        )

        XCTAssertEqual(
            feature.signedSmokeWebCredentialSealSnapshot,
            .init(
                isSealed: true,
                storeAttemptCount: 1,
                readAttemptCount: 1,
                deleteAttemptCount: 1,
                rejectedStoreAttemptCount: 1,
                rejectedReadAttemptCount: 1,
                rejectedDeleteAttemptCount: 1,
                activeStoreCount: 0,
                activeReadCount: 0,
                activeDeleteCount: 0
            )
        )
        XCTAssertTrue(
            feature.webResearchToolDefinitions(
                conversationIdentifier:
                    "signed-smoke-web-disabled",
                effectiveContextTokens: 8_192
            ).isEmpty
        )

        let call = OllamaChatToolCall(
            id: "signed-smoke-disabled-call",
            name: P8WebResearchToolName.search.rawValue,
            argumentsJSON: try JSONSerialization.data(
                withJSONObject: [
                    "query": "synthetic disabled proof",
                    "max_results": 1,
                ]
            )
        )
        do {
            _ = try await feature.executeWebResearchToolCall(
                call,
                conversationIdentifier:
                    "signed-smoke-web-disabled",
                session: .init(effectiveContextTokens: 8_192)
            )
            XCTFail("The sealed Web dispatch must fail closed.")
        } catch let failure as P8SignedSmokeWebResearchFailure {
            XCTAssertEqual(failure.code, .disabledWithoutKey)
            XCTAssertEqual(
                failure.reasonCode,
                P8SignedSmokeWebResearchReasonCode
                    .disabledWithoutKey
                    .rawValue
            )
            XCTAssertEqual(
                failure.localizedDescription,
                P8SignedSmokeWebResearchReasonCode
                    .disabledWithoutKey
                    .displayText
            )
        }
        let providerSearchInvocationCount =
            await provider.searchInvocationCount
        let providerFetchInvocationCount =
            await provider.fetchInvocationCount
        XCTAssertEqual(providerSearchInvocationCount, 0)
        XCTAssertEqual(providerFetchInvocationCount, 0)
    }

    func testSignedSmokeWebCredentialSealRejectsAdmissionWhileReadOrStoreIsActive()
        async throws
    {
        for operation in [
            P8ControllerBlockingCredentialStore
                .BlockedOperation.read,
            .store,
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let credentialStore =
                P8ControllerBlockingCredentialStore(
                    blockedOperation: operation
                )
            let feature = try P8FeatureController(
                store: try LocalStore(
                    url: root.appendingPathComponent(
                        "active-\(String(describing: operation)).sqlite3"
                    )
                ),
                semanticIndex:
                    try SemanticVaultIndex(inMemory: true),
                embeddingProvider:
                    P8ControllerFakeEmbeddingProvider(),
                webCredentialStore: credentialStore,
                webResearchProvider:
                    P8ControllerBlockingWebProvider()
            )

            switch operation {
            case .read:
                feature.refreshWebCredentialStatus()
            case .store:
                feature.webAPIKeyDraft =
                    "active-store-key-must-not-seal"
                feature.storeWebAPIKey()
            }

            var operationStarted = false
            for _ in 0..<200 {
                operationStarted =
                    operation == .read
                    ? await credentialStore.readStarted
                    : await credentialStore.storeStarted
                if operationStarted { break }
                await Task.yield()
            }
            XCTAssertTrue(operationStarted)
            XCTAssertTrue(feature.hasActiveWork)
            let activeSnapshot =
                feature.signedSmokeWebCredentialSealSnapshot
            XCTAssertFalse(activeSnapshot.isSealed)
            switch operation {
            case .read:
                XCTAssertEqual(activeSnapshot.readAttemptCount, 1)
                XCTAssertEqual(activeSnapshot.activeReadCount, 1)
                XCTAssertEqual(activeSnapshot.storeAttemptCount, 0)
            case .store:
                XCTAssertEqual(activeSnapshot.storeAttemptCount, 1)
                XCTAssertEqual(activeSnapshot.activeStoreCount, 1)
                XCTAssertEqual(activeSnapshot.readAttemptCount, 0)
            }
            XCTAssertFalse(
                feature
                    .declareSignedSmokeWebCredentialAbsentWithoutRead()
            )
            XCTAssertFalse(
                feature.signedSmokeWebCredentialSealIsActive
            )

            await credentialStore.release()
            await feature.waitForCurrentWork()
            XCTAssertFalse(feature.hasActiveWork)
            XCTAssertFalse(
                feature
                    .declareSignedSmokeWebCredentialAbsentWithoutRead()
            )
        }
    }

    private func makeReadyEmbeddingFeature(
        identifier: String
    ) async throws -> (
        feature: P8FeatureController,
        index: SemanticVaultIndex,
        embedding: P8ControllerFakeEmbeddingProvider
    ) {
        try await makeReadyEmbeddingFeature(
            identifiers: [identifier]
        )
    }

    private func makeSignedSmokeEmbeddingFeature(
        identifier: String
    ) async throws -> (
        feature: P8FeatureController,
        index: SemanticVaultIndex,
        embedding: P8BlockingCancellationEmbeddingProvider,
        probe: P8SemanticSourceAdapterProbe
    ) {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority
        )
        let embedding = P8BlockingCancellationEmbeddingProvider()
        let probe = P8SemanticSourceAdapterProbe()
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            signedSmokeRuntimeAuthority: authority,
            embeddingProvider: embedding,
            semanticSourceProviders: [
                probe.provider(for: .brief),
            ],
            semanticBuildSourceSelectionStore:
                P8VolatileSemanticBuildSourceSelectionStore(),
            semanticSourceAuthorityReceiptStore:
                P8VolatileSemanticSourceAuthorityReceiptStore(),
            webCredentialStore:
                P8ControllerFakeCredentialStore(),
            webResearchProvider:
                P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        feature.synchronizeModelRoles(
            [
                embeddingAssignment(
                    modelIdentifier: modelIdentifier,
                    digest: digest
                ),
            ],
            assessmentsByModelID: [
                modelIdentifier: embeddingAssessment(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 3,
                    ollamaVersion: "0.11.6"
                ),
            ]
        )
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.embeddingBindingIsReady)
        probe.setRecords(
            [
                try Self.semanticRecord(
                    identifier: identifier,
                    sourceKind: .brief,
                    text: "Stable semantic source"
                ),
            ],
            for: .brief
        )
        let initial = await feature
            .rebuildSemanticIndexForSignedSmoke(.init(
                sourceKinds: [.brief],
                requestTimestamp: anchor,
                authorizationReceiptIdentifier:
                    "\(identifier)-initial"
            ))
        XCTAssertEqual(initial.state, .published)
        XCTAssertNotNil(initial.generationIdentifier)
        return (feature, index, embedding, probe)
    }

    private func requireActiveGeneration(
        in index: SemanticVaultIndex
    ) async throws -> SemanticIndexGenerationMetadata {
        let activeGeneration = try await index.activeGeneration()
        return try XCTUnwrap(activeGeneration)
    }

    private func assertAllSemanticSearchModesBlocked(
        _ feature: P8FeatureController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for mode in SemanticSearchMode.allCases {
            feature.semanticMode = mode
            feature.semanticQuery = "authority hydration probe"
            feature.searchSemanticIndex()
            await feature.waitForCurrentWork()
            XCTAssertTrue(
                feature.semanticResults.isEmpty,
                "\(mode.rawValue) retrieval was not fail-closed",
                file: file,
                line: line
            )
            XCTAssertTrue(
                feature.semanticStatus.contains("stale"),
                "\(mode.rawValue) did not report stale authority",
                file: file,
                line: line
            )
        }
    }

    private func makeReadyEmbeddingFeature(
        identifiers: [String],
        initialBehavior: P8ControllerEmbeddingBehavior = .stable
    ) async throws -> (
        feature: P8FeatureController,
        index: SemanticVaultIndex,
        embedding: P8ControllerFakeEmbeddingProvider
    ) {
        let index = try SemanticVaultIndex(inMemory: true)
        let embedding = P8ControllerFakeEmbeddingProvider(dimension: 3)
        await embedding.setBehavior(initialBehavior)
        let feature = try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: index,
            embeddingProvider: embedding,
            permittedVaultSemanticRecordsProvider: {
                try identifiers.map {
                    try Self.vaultRecord(identifier: $0)
                }
            },
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
        let modelIdentifier = "qwen3-embedding:0.6b"
        let digest = String(repeating: "a", count: 64)
        feature.synchronizeModelRoles(
            [
                embeddingAssignment(
                    modelIdentifier: modelIdentifier,
                    digest: digest
                ),
            ],
            assessmentsByModelID: [
                modelIdentifier: embeddingAssessment(
                    modelIdentifier: modelIdentifier,
                    digest: digest,
                    dimension: 3,
                    ollamaVersion: "0.11.6"
                ),
            ]
        )
        await feature.waitForCurrentWork()
        feature.semanticBuildSourceKinds = [.vaultRecord]
        feature.rebuildSemanticIndex()
        await feature.waitForCurrentWork()
        XCTAssertTrue(feature.embeddingBindingIsReady)
        XCTAssertEqual(feature.semanticHealth?.state, .ready)
        return (feature, index, embedding)
    }

    private func embeddingAssignment(
        modelIdentifier: String,
        digest: String
    ) -> ModelRoleAssignment {
        .init(
            role: .embedding,
            requestedProvider: "ollama",
            requestedModelIdentifier: modelIdentifier,
            effectiveProvider: "ollama",
            effectiveModelIdentifier: modelIdentifier,
            requestedClassification: .local,
            effectiveClassification: .local,
            modelDigest: digest,
            assessmentReceiptIdentifier: "assessment-\(modelIdentifier)",
            assessmentTimestamp: anchor,
            verifiedInputModalities: [.text],
            verifiedThinkingModes: [],
            verifiedToolSupport: .none,
            verifiedStructuredOutputSupport: false,
            verifiedStreamingSupport: false,
            configuredContextTokens: nil,
            effectiveContextTokens: nil,
            readiness: .ready,
            reasonCode: ModelRoleReason.ready,
            source: .operatorSelection,
            dispositions: [.discovered, .selected, .assessed],
            isExplicitlyAssigned: true,
            selectedAt: anchor,
            updatedAt: anchor
        )
    }

    private func embeddingAssessment(
        modelIdentifier: String,
        digest: String,
        dimension: Int,
        ollamaVersion: String
    ) -> ModelCapabilityAssessment {
        let requestProfile = OllamaEmbeddingRequestProfile(
            dimensions: dimension
        )
        let stability = EmbeddingStabilityAssessmentSummary(
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            ollamaVersion: ollamaVersion,
            requestProfileVersion: requestProfile.version,
            requestProfileHash: requestProfile.stableHash,
            observedDimension: dimension,
            explicitDimensions: dimension,
            truncate: requestProfile.truncate,
            normalizationVersion: requestProfile.normalizationVersion,
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
            rankingHashes: (2...6).map {
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
            providerVersion: ollamaVersion,
            modelIdentifier: modelIdentifier,
            modelDigest: digest,
            capabilitiesProven: [.embedding],
            capabilitiesMissing: [],
            contextPolicy: .init(declaredContextTokens: nil),
            assessedAt: anchor,
            durationMilliseconds: 1,
            diagnostics: [],
            embeddingStability: stability
        )
    }

    private func semanticGenerationSpec(
        modelIdentifier: String,
        digest: String,
        dimension: Int = 3,
        ollamaVersion: String = "0.11.6",
        requestProfileVersion: String? = nil,
        requestProfileHash: String? = nil,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String = "loki_brief_v9"
    ) throws -> SemanticIndexGenerationSpec {
        let profile = OllamaEmbeddingRequestProfile(
            dimensions: dimension
        )
        return try .init(
            embeddingModelIdentifier: modelIdentifier,
            embeddingModelDigest: digest,
            vectorDimension: dimension,
            ollamaRuntimeVersion: ollamaVersion,
            embeddingRequestProfileVersion:
                requestProfileVersion ?? profile.version,
            embeddingRequestProfileHash:
                requestProfileHash ?? profile.stableHash,
            embeddingDimensions: dimension,
            embeddingTruncate: profile.truncate,
            embeddingNormalizationVersion:
                profile.normalizationVersion,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            sourceSchemaVersion: sourceSchemaVersion,
            buildScope: syntheticBuildScope()
        )
    }

    private func syntheticBuildScope(
        sourceKinds: Set<SemanticIndexSourceKind> = [.brief],
        authorizationReceiptIdentifier: String =
            "p8_controller_test_scope"
    ) throws -> SemanticIndexBuildScope {
        try .init(
            sourceKinds: sourceKinds,
            adapterContractVersions: Dictionary(
                uniqueKeysWithValues: sourceKinds.map {
                    (
                        $0,
                        Self.syntheticAdapterContractVersion(
                            for: $0
                        )
                    )
                }
            ),
            requestTimestamp: anchor,
            initiation: .manualOperator,
            authorizationReceiptIdentifier:
                authorizationReceiptIdentifier
        )
    }

    private static func syntheticAdapterContractVersion(
        for sourceKind: SemanticIndexSourceKind
    ) -> String {
        switch sourceKind {
        case .brief:
            P8SemanticSourceAdapter.briefContractVersion
        case .schedule:
            P8SemanticSourceAdapter.scheduleContractVersion
        case .chatMessage:
            P8SemanticSourceAdapter
                .chatFinalMessageContractVersion
        case .slackRecord:
            P8SemanticSourceAdapter.slackContractVersion
        case .vaultRecord:
            "p8.semantic-source.permitted-vault.v1"
        case .connectorRecord:
            "p8.test.connectorRecord.v1"
        }
    }

    @discardableResult
    private func publishEmptyGeneration(
        index: SemanticVaultIndex,
        specification: SemanticIndexGenerationSpec
    ) async throws -> SemanticIndexGenerationMetadata {
        let generation = try await index.beginGeneration(
            spec: specification
        )
        let buildScope = try XCTUnwrap(
            specification.buildScope
        )
        for sourceKind in buildScope.canonicalSourceKinds {
            let request = try SemanticIndexBatchRequest(
                runIdentifier:
                    "p8_test_run_\(sourceKind.rawValue)",
                streamIdentifier:
                    "p8_test_stream_\(sourceKind.rawValue)",
                currentCursor: nil,
                nextCursor: nil,
                sourceHighWatermark: nil,
                isFinalBatch: true,
                sourceKind: sourceKind,
                adapterContractVersion: try XCTUnwrap(
                    buildScope.adapterContractVersion(
                        for: sourceKind
                    )
                ),
                sourceAllowlistSHA256:
                    buildScope.allowlistSHA256,
                authorizationReceiptIdentifier:
                    buildScope.authorizationReceiptIdentifier,
                records: []
            )
            let prepared = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: request
            )
            _ = try await index.commit(
                prepared,
                embeddingsByChunkIdentifier: [:]
            )
        }
        return try await index.publishGeneration(
            generation.identifier
        )
    }

    private static func semanticRecord(
        identifier: String,
        sourceKind: SemanticIndexSourceKind,
        text: String,
        sourceTimestamp: Date = Date(
            timeIntervalSince1970: 1_800_000_000
        ),
        isTombstone: Bool = false,
        privacyClassification:
            SemanticIndexPrivacyClassification = .indexable
    ) throws -> SemanticIndexSourceRecord {
        let sourceHash =
            SemanticIndexSourceRecord.deterministicSourceHash(
                stableSourceIdentifier: identifier,
                sourceKind: sourceKind,
                sourceTimestamp: sourceTimestamp,
                text: text
            )
        return try .init(
            stableSourceIdentifier: identifier,
            sourceKind: sourceKind,
            sourceTimestamp: sourceTimestamp,
            text: text,
            sourceHash: sourceHash,
            isTombstone: isTombstone,
            privacyClassification: privacyClassification,
            provenance: .init(
                provider: "synthetic_source_authority_test",
                provenanceReceiptHash:
                    SemanticIndexDigest.sha256(
                        "synthetic-source-authority|\(identifier)"
                    )
            )
        )
    }

    private static func vaultRecord(
        identifier: String
    ) throws -> SemanticIndexSourceRecord {
        try semanticRecord(
            identifier: identifier,
            sourceKind: .vaultRecord,
            text: "alpha permitted Vault record \(identifier)"
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func makeVisionFeature() throws -> P8FeatureController {
        try P8FeatureController(
            store: LocalStore(inMemory: true),
            semanticIndex: try SemanticVaultIndex(inMemory: true),
            embeddingProvider: P8ControllerFakeEmbeddingProvider(),
            webCredentialStore: P8ControllerFakeCredentialStore(),
            webResearchProvider: P8ControllerBlockingWebProvider()
        )
    }

    private func itemProvider(
        data: Data,
        typeIdentifier: String
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func temporaryDirectory() throws -> URL {
        let canonicalTemporaryDirectory = try XCTUnwrap(
            LokiCanonicalFileURL.existing(
                FileManager.default.temporaryDirectory,
                isDirectory: true
            )
        )
        let URL = canonicalTemporaryDirectory
            .appendingPathComponent(
                "agent-loki-p8-controller-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: URL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return URL
    }

    private func signedSmokeFixtureStore(
        under root: URL,
        storageBoundary: P8FSignedSmokeStorageBoundary
    ) throws -> LocalStore {
        let controlDirectory = root.appendingPathComponent(
            P8FSignedSmokeFixtureSeeder.controlDirectoryName,
            isDirectory: true
        )
        let fixtureDirectory = controlDirectory
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureDirectoryName,
                isDirectory: true
            )
        try storageBoundary.ensurePrivateDirectory(
            at: controlDirectory
        )
        try storageBoundary.ensurePrivateDirectory(
            at: fixtureDirectory
        )
        let storeURL = fixtureDirectory.appendingPathComponent(
            P8FSignedSmokeFixtureSeeder.fixtureStoreFilename,
            isDirectory: false
        )
        try storageBoundary.validateSQLiteFamily(
            at: storeURL,
            requireDatabase: false
        )
        let store = try LocalStore(url: storeURL)
        try storageBoundary.secureSQLiteFamily(
            at: storeURL,
            requireDatabase: true
        )
        return store
    }

    private func signedSmokeAdmission(
        for root: URL
    ) throws -> P8FSignedSmokeAdmission {
        let fileManager = FileManager.default
        let vaultDirectory = root
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try fileManager.createDirectory(
            at: vaultDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [
            root,
            root.appendingPathComponent("Vault", isDirectory: true),
            vaultDirectory,
        ] {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        let requiredFiles = [
            root.appendingPathComponent("LokiBrief-v1.store"),
            vaultDirectory.appendingPathComponent(
                "loki-vault.sqlite3"
            ),
        ]
        for fileURL in requiredFiles {
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: Data()
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        let plan = P8FSignedSmokeControlPlan(
            runIdentifier:
                "p8-feature-authority-\(UUID().uuidString.lowercased())",
            scenario: .search,
            expectedFixtureManifestSHA256:
                P8FSignedSmokeFixtureManifest
                    .expectedCanonicalSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let planURL = root.appendingPathComponent(
            P8FSignedSmokeAdmissionResolver.controlPlanFileName
        )
        try encoder.encode(plan).write(
            to: planURL,
            options: .atomic
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: planURL.path
        )
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
        return try P8FSignedSmokeAdmissionResolver.resolveForXCTest(
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
            fileManager: fileManager
        )
    }

    private func syntheticPNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo:
                CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisionAttachmentFailure(.decodeFailed)
        }
        context.setFillColor(
            red: 0.2,
            green: 0.6,
            blue: 0.9,
            alpha: 1
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let image = context.makeImage() else {
            throw VisionAttachmentFailure(.decodeFailed)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw VisionAttachmentFailure(.metadataStrippingFailed)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            nil
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VisionAttachmentFailure(.metadataStrippingFailed)
        }
        return output as Data
    }
}
