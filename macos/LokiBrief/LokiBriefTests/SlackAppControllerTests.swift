import Foundation
import XCTest
@testable import LokiBrief

private actor SlackControllerTestLog {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor SlackControllerFakeCredentialStore: SlackCredentialStoring {
    private var credential: SlackOAuthCredential?
    private let log: SlackControllerTestLog?
    private let deleteFailure: SlackCredentialStoreFailure?
    private(set) var createCount = 0
    private(set) var readCount = 0
    private(set) var replaceCount = 0
    private(set) var deleteCount = 0

    init(
        credential: SlackOAuthCredential? = nil,
        log: SlackControllerTestLog? = nil,
        deleteFailure: SlackCredentialStoreFailure? = nil
    ) {
        self.credential = credential
        self.log = log
        self.deleteFailure = deleteFailure
    }

    func create(_ credential: SlackOAuthCredential) async throws {
        createCount += 1
        await log?.append("keychain.create")
        guard self.credential == nil else {
            throw SlackCredentialStoreFailure(code: .alreadyExists)
        }
        self.credential = credential
    }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        readCount += 1
        await log?.append("keychain.read")
        guard let credential, credential.teamID == teamID, credential.userID == userID else {
            throw SlackCredentialStoreFailure(code: .notFound)
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        replaceCount += 1
        await log?.append("keychain.replace")
        self.credential = credential
    }

    func delete(teamID: String, userID: String) async throws {
        deleteCount += 1
        await log?.append("keychain.delete")
        if let deleteFailure { throw deleteFailure }
        guard credential != nil else { throw SlackCredentialStoreFailure(code: .notFound) }
        credential = nil
    }

    func counts() -> (create: Int, read: Int, replace: Int, delete: Int) {
        (createCount, readCount, replaceCount, deleteCount)
    }
}

private actor SlackControllerFakeAuthorizer: SlackControllerAuthorizing {
    private let credential: SlackOAuthCredential
    private let delayNanoseconds: UInt64
    private let log: SlackControllerTestLog?
    private(set) var authorizeCount = 0
    private(set) var cancelCount = 0

    init(
        credential: SlackOAuthCredential,
        delayNanoseconds: UInt64 = 0,
        log: SlackControllerTestLog? = nil
    ) {
        self.credential = credential
        self.delayNanoseconds = delayNanoseconds
        self.log = log
    }

    func authorize(prefersEphemeralSession: Bool) async throws -> SlackOAuthCredential {
        authorizeCount += 1
        await log?.append("authorize")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return credential
    }

    func cancelActiveAuthorization() async {
        cancelCount += 1
        await log?.append("authorize.cancel")
    }

    func counts() -> (authorize: Int, cancel: Int) { (authorizeCount, cancelCount) }
}

private actor SlackControllerSuspendedAuthorizer: SlackControllerAuthorizing {
    private let credential: SlackOAuthCredential
    private var continuation: CheckedContinuation<SlackOAuthCredential, Never>?
    private var authorizeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var authorizeCount = 0
    private(set) var cancelCount = 0

    init(credential: SlackOAuthCredential) {
        self.credential = credential
    }

    func authorize(prefersEphemeralSession: Bool) async throws -> SlackOAuthCredential {
        authorizeCount += 1
        let waiters = authorizeWaiters
        authorizeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancelActiveAuthorization() async {
        // Deliberately leave the authorization suspended to simulate a browser
        // callback that ignores cancellation and arrives after Delete All.
        cancelCount += 1
    }

    func waitUntilAuthorizationStarts() async {
        guard authorizeCount == 0 else { return }
        await withCheckedContinuation { authorizeWaiters.append($0) }
    }

    func resolveAuthorization() {
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func counts() -> (authorize: Int, cancel: Int) { (authorizeCount, cancelCount) }
}

private actor SlackControllerFakeIdentityValidator: SlackControllerIdentityValidating {
    private let identity: SlackAuthenticatedIdentity
    private let log: SlackControllerTestLog?
    private(set) var validationCount = 0

    init(identity: SlackAuthenticatedIdentity, log: SlackControllerTestLog? = nil) {
        self.identity = identity
        self.log = log
    }

    func validate(
        credential: SlackOAuthCredential,
        provisionalConnection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAuthenticatedIdentity {
        validationCount += 1
        await log?.append("auth.test")
        return identity
    }
}

private actor SlackControllerFakeAPI: SlackControllerAPIServicing {
    let conversations: [SlackConversation]
    let failure: SlackAPIError?
    private(set) var discoverCount = 0
    private(set) var cancelCount = 0

    init(conversations: [SlackConversation] = [], failure: SlackAPIError? = nil) {
        self.conversations = conversations
        self.failure = failure
    }

    func discoverConversations(
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAPICallResult<[SlackConversation]> {
        discoverCount += 1
        if let failure { throw failure }
        return .init(
            value: conversations,
            metadata: .init(
                transientRetryCount: 0,
                rateLimitRetryCount: 0,
                credentialRefreshCount: 0,
                rateLimitState: nil
            )
        )
    }

    func cancelAll() async { cancelCount += 1 }
    func counts() -> (discover: Int, cancel: Int) { (discoverCount, cancelCount) }
}

private actor SlackControllerFakeSync: SlackControllerSyncing {
    private let output: SlackSyncOutput?
    private let syncFailure: SlackAPIError
    private let permalinkResult: SlackMessageEvidence?
    private let permalinkFailure: SlackAPIError
    private let delayNanoseconds: UInt64
    private(set) var syncCount = 0
    private(set) var cancelCount = 0
    private(set) var clearCount = 0
    private(set) var receivedChannelIDs: [String] = []
    private(set) var receivedTrace: SlackTraceContext?
    private(set) var receivedScheduledBudget = false
    private var syncWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        output: SlackSyncOutput? = nil,
        syncFailure: SlackAPIError = .init(.invalidRequest),
        permalinkResult: SlackMessageEvidence? = nil,
        permalinkFailure: SlackAPIError = .init(.invalidRequest),
        delayNanoseconds: UInt64 = 0
    ) {
        self.output = output
        self.syncFailure = syncFailure
        self.permalinkResult = permalinkResult
        self.permalinkFailure = permalinkFailure
        self.delayNanoseconds = delayNanoseconds
    }

    func syncSelectedChannels(
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        cursors: [SlackSyncCursor],
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?,
        progress: SlackSyncCoordinator.ProgressHandler?
    ) async throws -> SlackSyncOutput {
        syncCount += 1
        receivedChannelIDs = selections.map(\.channelID)
        receivedTrace = trace
        receivedScheduledBudget = scheduledBudget != nil
        let ready = syncWaiters.filter { syncCount >= $0.count }
        syncWaiters.removeAll { syncCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        if let output { return output }
        throw syncFailure
    }

    func resolvePermalink(
        for evidence: SlackMessageEvidence,
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackMessageEvidence {
        if let permalinkResult { return permalinkResult }
        throw permalinkFailure
    }

    func cancelAll(trace: SlackTraceContext) async {
        cancelCount += 1
        let ready = cancelWaiters.filter { cancelCount >= $0.count }
        cancelWaiters.removeAll { cancelCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
    func controllerClearWorkspaceCaches(workspaceID: String) async { clearCount += 1 }
    func counts() -> (sync: Int, cancel: Int, clear: Int, channelIDs: [String]) {
        (syncCount, cancelCount, clearCount, receivedChannelIDs)
    }
    func scheduledContext() -> (trace: SlackTraceContext?, receivedBudget: Bool) {
        (receivedTrace, receivedScheduledBudget)
    }
    func waitForSyncCount(_ count: Int) async {
        guard syncCount < count else { return }
        await withCheckedContinuation { syncWaiters.append((count, $0)) }
    }
    func waitForCancelCount(_ count: Int) async {
        guard cancelCount < count else { return }
        await withCheckedContinuation { cancelWaiters.append((count, $0)) }
    }
}

private actor SlackControllerFakeRevoker: SlackTokenRevoking {
    private(set) var revokeCount = 0
    func revoke(accessToken: String) async throws -> SlackRemoteRevocationResult {
        revokeCount += 1
        return .init(remoteConfirmed: true)
    }
}

@MainActor
final class SlackAppControllerTests: XCTestCase {
    private nonisolated static let anchor = Date(timeIntervalSince1970: 1_784_000_000)

    func testMissingClientIDIsTruthfulAndStartsNoExternalOperation() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = Self.credential()
        let credentialStore = SlackControllerFakeCredentialStore()
        let authorizer = SlackControllerFakeAuthorizer(credential: credential)
        let api = SlackControllerFakeAPI()

        let controller = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: credentialStore,
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: api,
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        XCTAssertEqual(controller.availability, .configurationRequired)
        XCTAssertFalse(controller.clientIDIsConfigured)
        var authorizerCounts = await authorizer.counts()
        let apiCounts = await api.counts()
        let credentialCounts = await credentialStore.counts()
        XCTAssertEqual(authorizerCounts.authorize, 0)
        XCTAssertEqual(apiCounts.discover, 0)
        XCTAssertEqual(credentialCounts.read, 0)
        let connected = await controller.connect()
        XCTAssertFalse(connected)
        XCTAssertEqual(controller.errorMessage, "Slack configuration required")
        authorizerCounts = await authorizer.counts()
        XCTAssertEqual(authorizerCounts.authorize, 0)
    }

    func testLaunchLoadsOnlyNonsecretMetadataWithoutKeychainBrowserOrNetwork() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        let credentialStore = SlackControllerFakeCredentialStore(credential: Self.credential())
        let authorizer = SlackControllerFakeAuthorizer(credential: Self.credential())
        let api = SlackControllerFakeAPI()

        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: api,
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        XCTAssertEqual(controller.availability, .connected)
        XCTAssertEqual(controller.workspaces.map(\.id), [Self.workspaceID])
        XCTAssertEqual(controller.conversationsByWorkspace[Self.workspaceID]?.count, 1)
        let credentialCounts = await credentialStore.counts()
        let authorizerCounts = await authorizer.counts()
        let apiCounts = await api.counts()
        XCTAssertEqual(credentialCounts.read, 0)
        XCTAssertEqual(authorizerCounts.authorize, 0)
        XCTAssertEqual(apiCounts.discover, 0)
    }

    func testConnectValidatesIdentityBeforeKeychainAndDefaultsConsentOff() async throws {
        let log = SlackControllerTestLog()
        let credentialStore = SlackControllerFakeCredentialStore(log: log)
        let controller = SlackAppController(
            store: try LocalStore(inMemory: true),
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential(), log: log),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity(), log: log),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker(),
            now: { Self.anchor }
        )

        let connected = await controller.connect()
        let logValues = await log.snapshot()
        XCTAssertTrue(connected)
        XCTAssertEqual(logValues, ["authorize", "auth.test", "keychain.create"])
        XCTAssertEqual(controller.workspaces.count, 1)
        XCTAssertEqual(controller.workspaces.first?.state, .connected)
        XCTAssertEqual(controller.workspaces.first?.localModelConsent, false)
        XCTAssertEqual(controller.selectedChannelCount(workspaceID: Self.workspaceID), 0)
    }

    func testChannelDiscoveryRunsOnlyAfterExplicitRequest() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let api = SlackControllerFakeAPI(conversations: [Self.conversation()])
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: api,
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        var apiCounts = await api.counts()
        XCTAssertEqual(apiCounts.discover, 0)
        let discovered = await controller.discoverChannels(workspaceID: Self.workspaceID)
        XCTAssertTrue(discovered)
        apiCounts = await api.counts()
        XCTAssertEqual(apiCounts.discover, 1)
        XCTAssertEqual(controller.conversationsByWorkspace[Self.workspaceID]?.map(\.channelID), ["C123"])
    }

    func testSelectedChannelEnablementPersistsSeparatelyAndDisabledChannelIsNotSynced() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        let sync = SlackControllerFakeSync()
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: sync,
            tokenRevoker: SlackControllerFakeRevoker()
        )

        await controller.setChannelSelected(workspaceID: Self.workspaceID, channelID: "C123", selected: true)
        await controller.setChannelEnabled(workspaceID: Self.workspaceID, channelID: "C123", enabled: false)

        var stored = try XCTUnwrap(store.slackConversationSelections(workspaceID: Self.workspaceID).first)
        XCTAssertTrue(stored.selected)
        XCTAssertFalse(stored.enabled)
        XCTAssertEqual(controller.conversationsByWorkspace[Self.workspaceID]?.first?.isEnabled, false)
        let syncResult = await controller.syncSelectedChannels(workspaceID: Self.workspaceID)
        let syncCounts = await sync.counts()
        XCTAssertFalse(syncResult)
        XCTAssertEqual(syncCounts.sync, 0)

        await controller.setChannelEnabled(workspaceID: Self.workspaceID, channelID: "C123", enabled: true)
        stored = try XCTUnwrap(store.slackConversationSelections(workspaceID: Self.workspaceID).first)
        XCTAssertTrue(stored.selected)
        XCTAssertTrue(stored.enabled)
    }

    func testChannelDeselectionCarriesContainerScopeAcrossDeletionCallbacks() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations(
            [Self.conversation()],
            workspaceID: Self.workspaceID
        )
        try store.setSlackConversationSelected(
            id: "\(Self.workspaceID):C123",
            selected: true
        )
        let controller = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: SlackControllerFakeCredentialStore(
                credential: Self.credential()
            )
        )
        let log = SlackControllerTestLog()
        controller.onSlackEvidenceDeletionWillBegin = {
            workspaceID, channelID in
            await log.append("begin:\(workspaceID):\(channelID ?? "all")")
        }
        controller.onSlackEvidenceDeletionCompleted = {
            workspaceID, channelID in
            await log.append("complete:\(workspaceID):\(channelID ?? "all")")
        }

        await controller.setChannelSelected(
            workspaceID: Self.workspaceID,
            channelID: "C123",
            selected: false
        )

        let callbackEvents = await log.snapshot()
        XCTAssertEqual(
            callbackEvents,
            [
                "begin:\(Self.workspaceID):C123",
                "complete:\(Self.workspaceID):C123",
            ]
        )
        XCTAssertFalse(
            try XCTUnwrap(
                store.slackConversationSelections(
                    workspaceID: Self.workspaceID
                ).first
            ).selected
        )
    }

    func testScheduledSyncForwardsBudgetAndCallerTraceAndPreservesExhaustionReason() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)
        let sync = SlackControllerFakeSync(syncFailure: .init(.scheduledRequestBudgetExhausted))
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: sync,
            tokenRevoker: SlackControllerFakeRevoker()
        )
        let trace = SlackTraceContext(
            traceID: "scheduled-trace",
            spanID: "scheduled-span",
            parentSpanID: "scheduled-parent"
        )
        let budget = ScheduledBriefingBudgetLedger(budget: .init(maximumSlackRequests: 0))

        let result = await controller.syncSelectedChannels(
            workspaceID: Self.workspaceID,
            notifyBriefingEvidenceChanged: false,
            scheduledBudget: budget,
            trace: trace
        )

        XCTAssertFalse(result)
        XCTAssertEqual(
            controller.workspaceOperations[Self.workspaceID],
            .failed(reasonCode: ScheduledBriefingBudgetReason.slackRequestsExhausted)
        )
        let context = await sync.scheduledContext()
        XCTAssertEqual(context.trace, trace)
        XCTAssertTrue(context.receivedBudget)
    }

    func testScheduledPartialSyncWithBudgetFailureReturnsDegradedFailureReason() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let conversations = [
            Self.conversation(id: "C123", name: "product"),
            Self.conversation(id: "C456", name: "private-team"),
        ]
        try store.persistDiscoveredSlackConversations(conversations, workspaceID: Self.workspaceID)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C456", selected: true)
        let successCursor = Self.cursor(channelID: "C123", updatedAt: Self.anchor)
        let failedCursor = Self.cursor(channelID: "C456", updatedAt: Self.anchor)
        let output = SlackSyncOutput(
            run: .init(
                id: "sync-scheduled-budget-partial",
                traceID: "trace-scheduled-budget-partial",
                workspaceID: Self.workspaceID,
                startedAt: Self.anchor.addingTimeInterval(-1),
                completedAt: Self.anchor,
                state: .partial,
                selectedChannelCount: 2,
                successfulChannelCount: 1,
                failedChannelCount: 1,
                normalizedMessageCount: 0,
                rateLimitState: nil,
                channelResults: [
                    .init(
                        channelID: "C123",
                        state: .completed,
                        normalizedCount: 0,
                        tombstoneCount: 0,
                        failureReasonCode: nil,
                        cursor: successCursor
                    ),
                    .init(
                        channelID: "C456",
                        state: .failed,
                        normalizedCount: 0,
                        tombstoneCount: 0,
                        failureReasonCode: ScheduledBriefingBudgetReason.slackRequestsExhausted,
                        cursor: failedCursor
                    ),
                ]
            ),
            evidenceUpserts: [],
            tombstones: [],
            cursorUpdates: [successCursor],
            directives: []
        )
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(output: output),
            tokenRevoker: SlackControllerFakeRevoker()
        )
        let budget = ScheduledBriefingBudgetLedger(budget: .init(maximumSlackRequests: 1))

        let result = await controller.syncSelectedChannels(
            workspaceID: Self.workspaceID,
            notifyBriefingEvidenceChanged: false,
            scheduledBudget: budget,
            trace: .init(traceID: "scheduled-trace", spanID: "scheduled-span")
        )

        XCTAssertFalse(result)
        XCTAssertEqual(
            controller.workspaceOperations[Self.workspaceID],
            .failed(reasonCode: ScheduledBriefingBudgetReason.slackRequestsExhausted)
        )
        let outcome = LiveScheduledSourceRefresher.slackWorkspaceOutcome(
            identifier: Self.workspaceID,
            syncSucceeded: result,
            operation: controller.workspaceOperations[Self.workspaceID]
        )
        XCTAssertEqual(outcome.status, .degraded)
        XCTAssertEqual(outcome.reasonCodes, [ScheduledBriefingBudgetReason.slackRequestsExhausted])
    }

    func testRateLimitWaitingStatePersistsThenClearsWhenWaitCompletes() throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker(),
            now: { Self.anchor }
        )
        let retryAt = Self.anchor.addingTimeInterval(7)

        controller.recordRateLimitUpdate(
            workspaceID: Self.workspaceID,
            state: .init(method: .conversationsHistory, retryAfterSeconds: 7, retryAt: retryAt, observedAt: Self.anchor)
        )
        XCTAssertEqual(controller.workspaceOperations[Self.workspaceID], .waitingForRateLimit(until: retryAt))
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.connectionStateRaw, SlackConnectionState.rateLimited.rawValue)
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.rateLimitedUntil, retryAt)

        controller.recordRateLimitUpdate(workspaceID: Self.workspaceID, state: nil)
        XCTAssertEqual(controller.workspaceOperations[Self.workspaceID], .idle)
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.connectionStateRaw, SlackConnectionState.connected.rawValue)
        XCTAssertNil(try store.slackWorkspaceConnection(id: Self.workspaceID)?.rateLimitedUntil)
    }

    func testDiscoveryAndSyncAuthorizationFailuresPersistReauthorizationWithoutOpeningBrowser() async throws {
        let discoveryStore = try LocalStore(inMemory: true)
        try discoveryStore.persistSlackWorkspace(Self.connection(), enabled: true)
        let discoveryAuthorizer = SlackControllerFakeAuthorizer(credential: Self.credential())
        let discoveryController = SlackAppController(
            store: discoveryStore,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: discoveryAuthorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(failure: .init(.missingScope)),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let discoveryResult = await discoveryController.discoverChannels(workspaceID: Self.workspaceID)
        let discoveryAuthorizerCounts = await discoveryAuthorizer.counts()
        XCTAssertFalse(discoveryResult)
        XCTAssertEqual(try discoveryStore.domainSlackWorkspaces().first?.state, .reauthorizationRequired)
        XCTAssertEqual(try discoveryStore.domainSlackWorkspaces().first?.lastFailureReasonCode, SlackAPIErrorCode.missingScope.rawValue)
        XCTAssertEqual(discoveryAuthorizerCounts.authorize, 0)

        let syncStore = try LocalStore(inMemory: true)
        try syncStore.persistSlackWorkspace(Self.connection(), enabled: true)
        try syncStore.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        try syncStore.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)
        let syncAuthorizer = SlackControllerFakeAuthorizer(credential: Self.credential())
        let syncController = SlackAppController(
            store: syncStore,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: syncAuthorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(syncFailure: .init(.tokenRevoked)),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let syncResult = await syncController.syncSelectedChannels(workspaceID: Self.workspaceID)
        let syncAuthorizerCounts = await syncAuthorizer.counts()
        XCTAssertFalse(syncResult)
        XCTAssertEqual(try syncStore.domainSlackWorkspaces().first?.state, .reauthorizationRequired)
        XCTAssertEqual(try syncStore.domainSlackWorkspaces().first?.lastFailureReasonCode, SlackAPIErrorCode.tokenRevoked.rawValue)
        XCTAssertEqual(syncAuthorizerCounts.authorize, 0)
    }

    func testSuccessfulExplicitOperationReconcilesRotatedCredentialMetadata() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let rotatedIssuedAt = Self.anchor.addingTimeInterval(600)
        let rotatedExpiration = Self.anchor.addingTimeInterval(7_200)
        let rotated = Self.credential(issuedAt: rotatedIssuedAt, accessTokenExpiresAt: rotatedExpiration)
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: rotated),
            authorizer: SlackControllerFakeAuthorizer(credential: rotated),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(conversations: [Self.conversation()]),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker(),
            now: { rotatedIssuedAt }
        )

        let discovered = await controller.discoverChannels(workspaceID: Self.workspaceID)
        XCTAssertTrue(discovered)
        XCTAssertEqual(controller.workspaces.first?.credentialMetadata?.issuedAt, rotatedIssuedAt)
        XCTAssertEqual(controller.workspaceStatusDetails[Self.workspaceID]?.accessTokenExpiresAt, rotatedExpiration)
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.credentialIssuedAt, rotatedIssuedAt)
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.accessExpiresAt, rotatedExpiration)
    }

    func testPostRotationAPIFailureStillReconcilesNonsecretCredentialMetadata() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let rotatedIssuedAt = Self.anchor.addingTimeInterval(900)
        let rotatedExpiration = Self.anchor.addingTimeInterval(8_100)
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(
                credential: Self.credential(issuedAt: rotatedIssuedAt, accessTokenExpiresAt: rotatedExpiration)
            ),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(failure: .init(.transportFailure)),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker(),
            now: { rotatedIssuedAt }
        )

        let discovered = await controller.discoverChannels(workspaceID: Self.workspaceID)
        XCTAssertFalse(discovered)
        XCTAssertEqual(controller.workspaces.first?.credentialMetadata?.issuedAt, rotatedIssuedAt)
        XCTAssertEqual(controller.workspaceStatusDetails[Self.workspaceID]?.accessTokenExpiresAt, rotatedExpiration)
        XCTAssertEqual(try store.slackWorkspaceConnection(id: Self.workspaceID)?.credentialIssuedAt, rotatedIssuedAt)
    }

    func testSyncPersistsPerChannelSuccessFailureAndDisablesLostChannel() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let conversations = [
            Self.conversation(id: "C123", name: "product"),
            Self.conversation(id: "C456", name: "private-team"),
        ]
        try store.persistDiscoveredSlackConversations(conversations, workspaceID: Self.workspaceID)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C456", selected: true)
        let completedAt = Self.anchor.addingTimeInterval(60)
        let successCursor = Self.cursor(channelID: "C123", updatedAt: completedAt)
        let failedCursor = Self.cursor(channelID: "C456", updatedAt: completedAt)
        let output = SlackSyncOutput(
            run: .init(
                id: "sync-channel-state",
                traceID: "trace-channel-state",
                workspaceID: Self.workspaceID,
                startedAt: Self.anchor,
                completedAt: completedAt,
                state: .partial,
                selectedChannelCount: 2,
                successfulChannelCount: 1,
                failedChannelCount: 1,
                normalizedMessageCount: 0,
                rateLimitState: nil,
                channelResults: [
                    .init(channelID: "C123", state: .completed, normalizedCount: 0, tombstoneCount: 0, failureReasonCode: nil, cursor: successCursor),
                    .init(channelID: "C456", state: .failed, normalizedCount: 0, tombstoneCount: 0, failureReasonCode: SlackAPIErrorCode.channelNotFound.rawValue, cursor: failedCursor),
                ]
            ),
            evidenceUpserts: [],
            tombstones: [],
            cursorUpdates: [successCursor],
            directives: [
                .init(kind: .disableSelection, workspaceID: Self.workspaceID, channelID: "C456", reasonCode: SlackAPIErrorCode.channelNotFound.rawValue),
                .init(kind: .purgeChannelEvidence, workspaceID: Self.workspaceID, channelID: "C456", reasonCode: SlackAPIErrorCode.channelNotFound.rawValue),
            ]
        )
        let sync = SlackControllerFakeSync(output: output)
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: sync,
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let synced = await controller.syncSelectedChannels(workspaceID: Self.workspaceID)
        XCTAssertTrue(synced)
        let stored = Dictionary(uniqueKeysWithValues: try store.slackConversationSelections(workspaceID: Self.workspaceID).map { ($0.conversationID, $0) })
        XCTAssertEqual(stored["C123"]?.lastSuccessfulRefresh, completedAt)
        XCTAssertNil(stored["C123"]?.lastFailureCode)
        XCTAssertNil(stored["C456"]?.lastSuccessfulRefresh)
        XCTAssertEqual(stored["C456"]?.lastFailureCode, SlackAPIErrorCode.channelNotFound.rawValue)
        XCTAssertEqual(stored["C456"]?.selected, false)
        XCTAssertEqual(stored["C456"]?.enabled, false)
        XCTAssertEqual(try store.domainSlackWorkspaces().first?.state, .degraded)
        XCTAssertNil(try store.slackWorkspaceConnection(id: Self.workspaceID)?.rateLimitedUntil)
    }

    func testSuccessfulEmptyChannelSyncPrunesExpiredChannelEvidenceAndPreservesUnrelatedEvidence() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)

        let expiredTimestamp = SlackTimestamp(
            date: Self.anchor.addingTimeInterval(-Double(SlackPersistenceLimits.evidenceRetentionDays + 1) * 86_400)
        )
        func expiredEvidence(id: String, channelID: String) -> SlackMessageEvidence {
            SlackMessageEvidence(
                id: id,
                workspaceID: Self.workspaceID,
                workspaceName: "Loki Test Workspace",
                channelID: channelID,
                channelName: channelID,
                channelKind: .publicChannel,
                messageTimestamp: expiredTimestamp,
                excerpt: "old synthetic evidence",
                author: .init(id: "U200", displayName: "Tester", kind: .user, isDeleted: false),
                directlyMentionsAuthenticatedUser: false,
                replyCount: 0,
                isEdited: false,
                editedAt: nil,
                permalink: nil,
                retrievedAt: expiredTimestamp.date,
                selectedChannelWeight: 1,
                state: .available
            )
        }
        try store.persistSlackEvidence(expiredEvidence(id: "expired-quiet-channel", channelID: "C123"))
        try store.persistSlackEvidence(expiredEvidence(id: "expired-unrelated-channel", channelID: "C999"))

        let completedAt = Self.anchor
        let cursor = Self.cursor(channelID: "C123", updatedAt: completedAt)
        let output = SlackSyncOutput(
            run: .init(
                id: "sync-empty-quiet-channel",
                traceID: "trace-empty-quiet-channel",
                workspaceID: Self.workspaceID,
                startedAt: completedAt.addingTimeInterval(-1),
                completedAt: completedAt,
                state: .completed,
                selectedChannelCount: 1,
                successfulChannelCount: 1,
                failedChannelCount: 0,
                normalizedMessageCount: 0,
                rateLimitState: nil,
                channelResults: [
                    .init(channelID: "C123", state: .completed, normalizedCount: 0, tombstoneCount: 0, failureReasonCode: nil, cursor: cursor),
                ]
            ),
            evidenceUpserts: [],
            tombstones: [],
            cursorUpdates: [cursor],
            directives: []
        )
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(output: output),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let didSync = await controller.syncSelectedChannels(workspaceID: Self.workspaceID)
        XCTAssertTrue(didSync)
        XCTAssertEqual(try store.domainSlackEvidence().map(\.id), ["expired-unrelated-channel"])
    }

    func testPermalinkMissingScopePersistsReauthorizationWithoutBrowserRestart() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let evidence = Self.evidence(channelID: "C123")
        try store.persistSlackEvidence(evidence)
        let authorizer = SlackControllerFakeAuthorizer(credential: Self.credential())
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(permalinkFailure: .init(.missingScope)),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let permalink = await controller.resolvePermalink(evidenceID: evidence.id)
        let authorizerCounts = await authorizer.counts()
        XCTAssertNil(permalink)
        XCTAssertEqual(try store.domainSlackWorkspaces().first?.state, .reauthorizationRequired)
        XCTAssertEqual(try store.domainSlackWorkspaces().first?.lastFailureReasonCode, SlackAPIErrorCode.missingScope.rawValue)
        XCTAssertEqual(authorizerCounts.authorize, 0)
    }

    func testDeselectInvalidatesAndCancelsLateSyncBeforeEvidenceCanLand() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        try store.setSlackConversationSelected(id: "\(Self.workspaceID):C123", selected: true)
        let completedAt = Self.anchor.addingTimeInterval(30)
        let cursor = Self.cursor(channelID: "C123", updatedAt: completedAt)
        let output = SlackSyncOutput(
            run: .init(
                id: "late-sync",
                traceID: "trace-late-sync",
                workspaceID: Self.workspaceID,
                startedAt: Self.anchor,
                completedAt: completedAt,
                state: .completed,
                selectedChannelCount: 1,
                successfulChannelCount: 1,
                failedChannelCount: 0,
                normalizedMessageCount: 1,
                rateLimitState: nil,
                channelResults: [
                    .init(channelID: "C123", state: .completed, normalizedCount: 1, tombstoneCount: 0, failureReasonCode: nil, cursor: cursor),
                ]
            ),
            evidenceUpserts: [Self.evidence(channelID: "C123")],
            tombstones: [],
            cursorUpdates: [cursor],
            directives: []
        )
        let sync = SlackControllerFakeSync(output: output, delayNanoseconds: 80_000_000)
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: SlackControllerFakeCredentialStore(credential: Self.credential()),
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: sync,
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let task = Task { await controller.syncSelectedChannels(workspaceID: Self.workspaceID) }
        await sync.waitForSyncCount(1)
        await controller.setChannelSelected(workspaceID: Self.workspaceID, channelID: "C123", selected: false)
        await sync.waitForCancelCount(1)
        let result = await task.value
        let syncCounts = await sync.counts()

        XCTAssertFalse(result)
        XCTAssertTrue(try store.domainSlackEvidence().isEmpty)
        XCTAssertEqual(try store.slackConversationSelections(workspaceID: Self.workspaceID).first?.selected, false)
        XCTAssertGreaterThanOrEqual(syncCounts.cancel, 1)
    }

    func testCancelledAuthorizationRejectsLateCredentialAndDoesNotPersistIt() async throws {
        let credentialStore = SlackControllerFakeCredentialStore()
        let authorizer = SlackControllerFakeAuthorizer(
            credential: Self.credential(),
            delayNanoseconds: 80_000_000
        )
        let controller = SlackAppController(
            store: try LocalStore(inMemory: true),
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let task = Task { await controller.connect() }
        try await Task.sleep(nanoseconds: 10_000_000)
        await controller.cancelAuthorization()
        let connected = await task.value
        let credentialCounts = await credentialStore.counts()
        let authorizerCounts = await authorizer.counts()
        XCTAssertFalse(connected)
        XCTAssertTrue(controller.workspaces.isEmpty)
        XCTAssertEqual(credentialCounts.create, 0)
        XCTAssertEqual(authorizerCounts.cancel, 1)
    }

    func testDeleteAllWithNoWorkspaceStillRejectsSuspendedAuthorizationCallback() async throws {
        let store = try LocalStore(inMemory: true)
        let credentialStore = SlackControllerFakeCredentialStore()
        let authorizer = SlackControllerSuspendedAuthorizer(credential: Self.credential())
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )
        let model = try AppModel(store: store, slackController: controller)

        let connectTask = Task { await controller.connect() }
        await authorizer.waitUntilAuthorizationStarts()
        XCTAssertTrue(controller.workspaces.isEmpty)

        await model.deleteAllData()
        await authorizer.resolveAuthorization()
        let connected = await connectTask.value

        let credentialCounts = await credentialStore.counts()
        let authorizerCounts = await authorizer.counts()
        XCTAssertFalse(connected)
        XCTAssertTrue(controller.workspaces.isEmpty)
        XCTAssertTrue(try store.domainSlackWorkspaces().isEmpty)
        XCTAssertEqual(credentialCounts.create, 0)
        XCTAssertEqual(credentialCounts.replace, 0)
        XCTAssertEqual(authorizerCounts.authorize, 1)
        XCTAssertGreaterThanOrEqual(authorizerCounts.cancel, 1)
        XCTAssertFalse(controller.wholeAppDeletionInProgress)
    }

    func testContentDeletionPreservesWorkspaceAuthorizationAndCredential() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        let credentialStore = SlackControllerFakeCredentialStore(credential: Self.credential())
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let deleted = await controller.deleteLocalData(workspaceID: Self.workspaceID)
        let credentialCounts = await credentialStore.counts()
        XCTAssertTrue(deleted)
        XCTAssertEqual(controller.workspaces.map(\.id), [Self.workspaceID])
        XCTAssertEqual(controller.conversationsByWorkspace[Self.workspaceID], [])
        XCTAssertEqual(credentialCounts.delete, 0)
    }

    func testDisconnectRevokesAndDeletesCredentialWhilePreservingWorkspaceData() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let credentialStore = SlackControllerFakeCredentialStore(credential: Self.credential())
        let revoker = SlackControllerFakeRevoker()
        let authorizer = SlackControllerFakeAuthorizer(credential: Self.credential())
        let generationLog = SlackControllerTestLog()
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: authorizer,
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: revoker
        )
        controller.onSlackEvidenceDeletionWillBegin = { _, _ in
            await generationLog.append("slack-generation.cancel")
        }

        let result = await controller.disconnect(workspaceID: Self.workspaceID)
        XCTAssertTrue(result.remoteRevocationAttempted)
        XCTAssertTrue(result.remoteRevocationConfirmed)
        XCTAssertTrue(result.credentialDeleted)
        XCTAssertFalse(result.localDataDeleted)
        XCTAssertTrue(result.localDataPreserved)
        XCTAssertTrue(result.connectorDisabled)
        XCTAssertEqual(controller.workspaces.map(\.id), [Self.workspaceID])
        XCTAssertFalse(controller.isWorkspaceEnabled(Self.workspaceID))
        let revokeCount = await revoker.revokeCount
        let credentialCounts = await credentialStore.counts()
        let authorizerCounts = await authorizer.counts()
        let generationEvents = await generationLog.snapshot()
        XCTAssertEqual(revokeCount, 1)
        XCTAssertEqual(credentialCounts.delete, 1)
        XCTAssertEqual(authorizerCounts.cancel, 1)
        XCTAssertEqual(generationEvents, ["slack-generation.cancel"])
    }

    func testDisconnectPreservesWorkspaceMetadataWhenKeychainDeletionFails() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        try store.persistDiscoveredSlackConversations([Self.conversation()], workspaceID: Self.workspaceID)
        let credentialStore = SlackControllerFakeCredentialStore(
            credential: Self.credential(),
            deleteFailure: SlackCredentialStoreFailure(code: .interactionNotAllowed)
        )
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let result = await controller.disconnect(workspaceID: Self.workspaceID, revokeRemotely: false)
        XCTAssertFalse(result.credentialDeleted)
        XCTAssertFalse(result.localDataDeleted)
        XCTAssertTrue(result.localDataPreserved)
        XCTAssertFalse(result.connectorDisabled)
        XCTAssertEqual(controller.workspaces.map(\.id), [Self.workspaceID])
        XCTAssertEqual(try store.domainSlackWorkspaces().map(\.id), [Self.workspaceID])
        XCTAssertEqual(try store.slackConversationSelections(workspaceID: Self.workspaceID).map(\.conversationID), ["C123"])
        XCTAssertNotNil(controller.errorMessage)
    }

    func testWholeAppDeletionRemovesCredentialBeforeWorkspaceMetadataAndReloadsEmptyState() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let credentialStore = SlackControllerFakeCredentialStore(credential: Self.credential())
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let prepared = await controller.prepareForWholeAppDataDeletion()
        XCTAssertTrue(prepared)
        XCTAssertEqual(controller.workspaces.map(\.id), [Self.workspaceID])
        let credentialCounts = await credentialStore.counts()
        XCTAssertEqual(credentialCounts.delete, 1)

        try store.deleteAllLocalData()
        controller.reloadAfterWholeAppDataDeletion()
        XCTAssertTrue(controller.workspaces.isEmpty)
    }

    func testWholeAppDeletionPreservesWorkspaceMetadataWhenCredentialDeletionFails() async throws {
        let store = try LocalStore(inMemory: true)
        try store.persistSlackWorkspace(Self.connection(), enabled: true)
        let credentialStore = SlackControllerFakeCredentialStore(
            credential: Self.credential(),
            deleteFailure: SlackCredentialStoreFailure(code: .interactionNotAllowed)
        )
        let controller = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: SlackControllerFakeAuthorizer(credential: Self.credential()),
            identityValidator: SlackControllerFakeIdentityValidator(identity: Self.identity()),
            apiClient: SlackControllerFakeAPI(),
            syncCoordinator: SlackControllerFakeSync(),
            tokenRevoker: SlackControllerFakeRevoker()
        )

        let prepared = await controller.prepareForWholeAppDataDeletion()
        XCTAssertFalse(prepared)
        XCTAssertEqual(try store.domainSlackWorkspaces().map(\.id), [Self.workspaceID])
        XCTAssertNotNil(controller.errorMessage)
    }

    private static var workspaceID: String { SlackWorkspaceConnection.stableID(teamID: "T123", userID: "U123") }

    private static func credential(
        issuedAt: Date = anchor,
        accessTokenExpiresAt: Date? = nil
    ) -> SlackOAuthCredential {
        .init(
            teamID: "T123",
            userID: "U123",
            accessToken: "TEST_ACCESS_SENTINEL",
            refreshToken: "TEST_REFRESH_SENTINEL",
            tokenType: "user",
            issuedAt: issuedAt,
            accessTokenExpiresAt: accessTokenExpiresAt ?? issuedAt.addingTimeInterval(3_600),
            refreshTokenExpiresAt: issuedAt.addingTimeInterval(30 * 86_400),
            grantedScopes: SlackOAuthScopePolicy.requiredUserScopes.sorted()
        )
    }

    private static func identity() -> SlackAuthenticatedIdentity {
        .init(
            teamID: "T123",
            teamName: "Loki Test Workspace",
            userID: "U123",
            userName: "Loki Tester",
            workspaceURL: URL(string: "https://loki-test.slack.com")
        )
    }

    private static func connection() -> SlackWorkspaceConnection {
        let credential = credential()
        let scopes = Set(credential.grantedScopes.compactMap(SlackGrantedScope.init(rawValue:)))
        return .init(
            id: workspaceID,
            teamID: credential.teamID,
            teamName: "Loki Test Workspace",
            userID: credential.userID,
            userDisplayName: "Loki Tester",
            state: .connected,
            grantedScopes: scopes,
            credentialMetadata: .init(
                tokenType: credential.tokenType,
                issuedAt: credential.issuedAt,
                accessExpiration: credential.accessTokenExpiresAt,
                grantedScopes: scopes,
                schemaVersion: credential.schemaVersion
            ),
            localModelConsent: false,
            connectedAt: anchor,
            updatedAt: anchor,
            lastFailureReasonCode: nil
        )
    }

    private static func conversation(id: String = "C123", name: String = "product") -> SlackConversation {
        .init(
            id: id,
            workspaceID: workspaceID,
            displayName: name,
            kind: .publicChannel,
            isMember: true,
            isArchived: false,
            discoveredAt: anchor
        )
    }

    private static func cursor(channelID: String, updatedAt: Date) -> SlackSyncCursor {
        .init(
            workspaceID: workspaceID,
            channelID: channelID,
            committedOldest: SlackTimestamp(rawValue: "1783990000.000001"),
            windowLatest: nil,
            nextCursor: nil,
            pendingHighWater: nil,
            updatedAt: updatedAt
        )
    }

    private static func evidence(channelID: String) -> SlackMessageEvidence {
        .init(
            id: "evidence-\(channelID)",
            workspaceID: workspaceID,
            workspaceName: "Loki Test Workspace",
            channelID: channelID,
            channelName: channelID == "C123" ? "product" : "private-team",
            channelKind: .publicChannel,
            messageTimestamp: SlackTimestamp(rawValue: "1784000000.000001")!,
            excerpt: "bounded synthetic evidence",
            author: .init(id: "U200", displayName: "Tester", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: false,
            replyCount: 0,
            isEdited: false,
            editedAt: nil,
            permalink: nil,
            retrievedAt: anchor,
            selectedChannelWeight: 1,
            state: .available
        )
    }
}
