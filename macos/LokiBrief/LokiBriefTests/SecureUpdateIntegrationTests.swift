import Foundation
import XCTest
@testable import LokiBrief

private actor P7DeleteBarrierFeedClient: FeedRetrieving {
    func fetch(
        _ subscription: FeedSubscription,
        trace: FeedTraceContext
    ) async throws -> FeedFetchResult {
        throw FeedFetchFailure(.networkUnavailable)
    }

    func cancelAll() async { }
}

private actor UpdateTestCredentialStore: SlackCredentialStoring {
    private var credentials: [String: SlackOAuthCredential] = [:]

    func create(_ credential: SlackOAuthCredential) async throws {
        credentials[credential.accountIdentifier] = credential
    }
    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        guard let credential = credentials["\(teamID):\(userID)"] else {
            throw CancellationError()
        }
        return credential
    }
    func replace(_ credential: SlackOAuthCredential) async throws {
        credentials[credential.accountIdentifier] = credential
    }
    func delete(teamID: String, userID: String) async throws {
        credentials.removeValue(forKey: "\(teamID):\(userID)")
    }
}

private actor P6USuspendedCredentialStore: SlackCredentialStoring {
    private var credential: SlackOAuthCredential?
    private let suspendCreate: Bool
    private let suspendRead: Bool
    private let suspendDelete: Bool
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    init(
        credential: SlackOAuthCredential? = nil,
        suspendCreate: Bool = false,
        suspendRead: Bool = false,
        suspendDelete: Bool = false
    ) {
        self.credential = credential
        self.suspendCreate = suspendCreate
        self.suspendRead = suspendRead
        self.suspendDelete = suspendDelete
    }

    func create(_ credential: SlackOAuthCredential) async throws {
        self.credential = credential
        if suspendCreate {
            await withCheckedContinuation { createContinuation = $0 }
        }
    }

    func read(teamID: String, userID: String) async throws -> SlackOAuthCredential {
        if suspendRead {
            await withCheckedContinuation { readContinuation = $0 }
        }
        guard let credential, credential.teamID == teamID, credential.userID == userID else {
            throw CancellationError()
        }
        return credential
    }

    func replace(_ credential: SlackOAuthCredential) async throws {
        self.credential = credential
    }

    func delete(teamID: String, userID: String) async throws {
        if suspendDelete {
            await withCheckedContinuation { deleteContinuation = $0 }
        }
        credential = nil
    }

    func isCreateSuspended() -> Bool { createContinuation != nil }
    func isReadSuspended() -> Bool { readContinuation != nil }
    func isDeleteSuspended() -> Bool { deleteContinuation != nil }

    func resumeCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }

    func resumeRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func resumeDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}

private struct P6UCredentialAuthorizer: SlackControllerAuthorizing {
    let credential: SlackOAuthCredential

    func authorize(prefersEphemeralSession: Bool) async throws -> SlackOAuthCredential {
        credential
    }

    func cancelActiveAuthorization() async { }
}

private struct P6USlackIdentityValidator: SlackControllerIdentityValidating {
    func validate(
        credential: SlackOAuthCredential,
        provisionalConnection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAuthenticatedIdentity {
        .init(
            teamID: credential.teamID,
            teamName: "P6U synthetic workspace",
            userID: credential.userID,
            userName: "P6U synthetic user",
            workspaceURL: nil
        )
    }
}

private actor P6USuspendedSlackIdentityValidator: SlackControllerIdentityValidating {
    private var continuation: CheckedContinuation<Void, Never>?

    func validate(
        credential: SlackOAuthCredential,
        provisionalConnection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAuthenticatedIdentity {
        await withCheckedContinuation { continuation = $0 }
        return .init(
            teamID: credential.teamID,
            teamName: "P6U synthetic workspace",
            userID: credential.userID,
            userName: "P6U synthetic user",
            workspaceURL: nil
        )
    }

    func isSuspended() -> Bool { continuation != nil }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct P6USuccessfulSlackAPI: SlackControllerAPIServicing {
    let conversations: [SlackConversation]

    func discoverConversations(
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAPICallResult<[SlackConversation]> {
        .init(
            value: conversations,
            metadata: .init(
                transientRetryCount: 0,
                rateLimitRetryCount: 0,
                credentialRefreshCount: 0,
                rateLimitState: nil
            )
        )
    }

    func cancelAll() async { }
}

private actor P6USuspendedSlackCancellationAuthorizer: SlackControllerAuthorizing {
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func authorize(prefersEphemeralSession: Bool) async throws -> SlackOAuthCredential {
        throw CancellationError()
    }

    func cancelActiveAuthorization() async {
        await withCheckedContinuation { cancellationContinuation = $0 }
    }

    func isCancellationSuspended() -> Bool { cancellationContinuation != nil }

    func resumeCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private actor P6UNoOpSlackAPI: SlackControllerAPIServicing {
    func discoverConversations(
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAPICallResult<[SlackConversation]> {
        throw SlackAPIError(.invalidRequest)
    }

    func cancelAll() async { }
}

private actor P6USuspendedPermalinkSync: SlackControllerSyncing {
    private let resolvedEvidence: SlackMessageEvidence
    private var permalinkContinuation: CheckedContinuation<Void, Never>?

    init(resolvedEvidence: SlackMessageEvidence) {
        self.resolvedEvidence = resolvedEvidence
    }

    func syncSelectedChannels(
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        cursors: [SlackSyncCursor],
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?,
        progress: SlackSyncCoordinator.ProgressHandler?
    ) async throws -> SlackSyncOutput {
        throw SlackAPIError(.invalidRequest)
    }

    func resolvePermalink(
        for evidence: SlackMessageEvidence,
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackMessageEvidence {
        await withCheckedContinuation { permalinkContinuation = $0 }
        return resolvedEvidence
    }

    func cancelAll(trace: SlackTraceContext) async { }
    func controllerClearWorkspaceCaches(workspaceID: String) async { }
    func isPermalinkSuspended() -> Bool { permalinkContinuation != nil }

    func resumePermalink() {
        permalinkContinuation?.resume()
        permalinkContinuation = nil
    }
}

private actor P6USuspendedSlackCallback {
    private var continuation: CheckedContinuation<Void, Never>?
    private var invocationCount = 0

    func suspend() async {
        invocationCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func isSuspended() -> Bool { continuation != nil }
    func count() -> Int { invocationCount }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct P6USuccessfulSlackSync: SlackControllerSyncing {
    let output: SlackSyncOutput

    func syncSelectedChannels(
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        cursors: [SlackSyncCursor],
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?,
        progress: SlackSyncCoordinator.ProgressHandler?
    ) async throws -> SlackSyncOutput {
        output
    }

    func resolvePermalink(
        for evidence: SlackMessageEvidence,
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackMessageEvidence {
        throw SlackAPIError(.invalidRequest)
    }

    func cancelAll(trace: SlackTraceContext) async { }
    func controllerClearWorkspaceCaches(workspaceID: String) async { }
}

private struct P6USuccessfulSlackRevoker: SlackTokenRevoking {
    func revoke(accessToken: String) async throws -> SlackRemoteRevocationResult {
        .init(remoteConfirmed: true)
    }
}

private actor P6UVaultDeletionCheckpoint {
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func isSuspended() -> Bool { continuation != nil }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor P6UUpdateAvailabilityNotifier: UpdateAvailabilityNotifying {
    private var postCount = 0

    func postAvailabilityNotificationIfAuthorized() async -> UpdateAvailabilityNotificationResult {
        postCount += 1
        return .posted
    }

    func count() -> Int { postCount }
}

private actor P6USuspendedReadinessParticipant: ApplicationUpdateReadinessParticipant {
    nonisolated let identifier = "p6u_suspended_readiness"
    nonisolated let preparationOrder = 0
    nonisolated let requiredPreparationContracts: Set<ApplicationUpdatePreparationContract> = [
        .saveState,
        .quiesceAndCloseStoresForTermination,
    ]

    private var continuation: CheckedContinuation<Void, Never>?
    private var recoveries = 0

    func assessApplicationUpdateReadiness() async -> ApplicationUpdateParticipantAssessment { .ready }

    func prepareForApplicationUpdate() async -> ApplicationUpdateParticipantPreparation {
        await withCheckedContinuation { continuation = $0 }
        return .prepared(fulfilling: requiredPreparationContracts)
    }

    func recoverAfterApplicationUpdateAbort() async -> ApplicationUpdateParticipantRecovery {
        recoveries += 1
        return .recovered
    }

    func isSuspended() -> Bool { continuation != nil }
    func recoveryCount() -> Int { recoveries }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class P6UInstallHandlerRecorder {
    private(set) var invocationCount = 0
    func invoke() { invocationCount += 1 }
}

final class SecureUpdateIntegrationTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testSignedSmokeUpdateControllerNeverStartsProviderOrReadsStoredChannel()
        throws
    {
        let suiteName =
            "com.agentloki.LokiBriefTests.P8F.InertUpdate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            UpdateChannel.beta.rawValue,
            forKey: "LokiBrief.UpdateChannel"
        )
        var providerStartCount = 0
        let controller = SecureUpdateController(
            model: try AppModel(
                store: LocalStore(inMemory: true)
            ),
            defaults: defaults,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(
                    string:
                        "https://updates.example.test/stable/appcast.xml"
                )!,
            ]),
            availabilityNotifier:
                P8FSignedSmokeInertUpdateAvailabilityNotifier(),
            providerStarter: { _ in
                providerStartCount += 1
            },
            inertForSignedSmoke: true
        )

        XCTAssertEqual(controller.channel, .stable)
        XCTAssertEqual(providerStartCount, 0)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticChecksEnabled)
        XCTAssertEqual(
            controller.statusMessage,
            "Update authority is disabled for the signed smoke runner."
        )

        controller.checkForUpdates()
        controller.setChannel(.beta)
        controller.setAutomaticChecksEnabled(true)
        XCTAssertEqual(controller.channel, .stable)
        XCTAssertEqual(providerStartCount, 0)
        XCTAssertFalse(controller.automaticChecksEnabled)
    }

    @MainActor
    func testControllerDefaultsToStableWithoutFirstLaunchPermissionPrompt() throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try AppModel(store: LocalStore(inMemory: true))

        let stable = SecureUpdateController(model: model, defaults: defaults)
        XCTAssertEqual(stable.channel, .stable)
        XCTAssertEqual(stable.providerAllowedChannels, [])
        XCTAssertFalse(stable.automaticChecksEnabled)
        XCTAssertFalse(stable.requestsFirstLaunchUpdateCheckPermission)

        defaults.set(UpdateChannel.beta.rawValue, forKey: "LokiBrief.UpdateChannel")
        let beta = SecureUpdateController(model: model, defaults: defaults)
        XCTAssertEqual(beta.channel, .beta)
        XCTAssertEqual(beta.providerAllowedChannels, [UpdateChannel.beta.rawValue])
        XCTAssertFalse(beta.requestsFirstLaunchUpdateCheckPermission)
    }

    @MainActor
    func testProviderStartFailureRemainsTruthfulAndDisablesChecks() throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.ProviderStart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try AppModel(store: LocalStore(inMemory: true))
        let controller = SecureUpdateController(
            model: model,
            defaults: defaults,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(string: "https://updates.example.test/stable/appcast.xml")!,
            ]),
            providerStarter: { _ in
                throw NSError(domain: "com.agentloki.tests.provider-start", code: 17)
            }
        )

        XCTAssertFalse(controller.canCheckForUpdates)
        guard case .failed(let failure) = controller.state else {
            return XCTFail("Provider start failure must be published as a typed failure")
        }
        XCTAssertEqual(failure.code, .providerFailure)
        XCTAssertTrue(failure.isRecoverable)
        XCTAssertEqual(controller.statusMessage, failure.consumerMessage)
    }

    @MainActor
    func testAutomaticAvailabilityNotificationUsesPayloadFreeProductionRoute() async throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.Notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifier = P6UUpdateAvailabilityNotifier()
        let controller = SecureUpdateController(
            model: try AppModel(store: LocalStore(inMemory: true)),
            defaults: defaults,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(string: "https://updates.example.test/stable/appcast.xml")!,
            ]),
            availabilityNotifier: notifier,
            providerStarter: { _ in }
        )

        let manualResult = await controller.postAvailabilityNotificationIfNeeded(trigger: .manual)
        XCTAssertEqual(manualResult, .manualCheckSuppressed)
        let manualPostCount = await notifier.count()
        XCTAssertEqual(manualPostCount, 0)
        let automaticResult = await controller.postAvailabilityNotificationIfNeeded(trigger: .automatic)
        XCTAssertEqual(automaticResult, .posted)
        let automaticPostCount = await notifier.count()
        XCTAssertEqual(automaticPostCount, 1)
    }

    @MainActor
    func testAbortDuringSuspendedPreparationRejectsLateInstallHandlerAndRecoversLease() async throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.AbortRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let participant = P6USuspendedReadinessParticipant()
        let coordinator = ApplicationUpdateReadinessCoordinator(participants: [participant])
        let controller = SecureUpdateController(
            model: try AppModel(store: LocalStore(inMemory: true)),
            defaults: defaults,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(string: "https://updates.example.test/stable/appcast.xml")!,
            ]),
            readinessCoordinator: coordinator,
            providerStarter: { _ in }
        )
        let handler = P6UInstallHandlerRecorder()
        controller.beginInstallationPreparation { handler.invoke() }
        for _ in 0..<200 {
            if await participant.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let preparationSuspended = await participant.isSuspended()
        XCTAssertTrue(preparationSuspended)

        controller.beginAbortRecovery(NSError(
            domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
            code: 2_001
        ))
        await participant.resume()
        for _ in 0..<200 {
            if await participant.recoveryCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(handler.invocationCount, 0)
        let recoveryCount = await participant.recoveryCount()
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertNil(defaults.data(forKey: "LokiBrief.PendingUpdateReceipt"))
    }

    @MainActor
    func testAuthorizeLaterCompletionRecoversPreparedStoresAndReportsTypedBlock() async throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.AuthorizeLater.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try AppModel(store: LocalStore(inMemory: true))
        try await waitUntilVaultIsIdle(model.vaultController)
        let controller = SecureUpdateController(
            model: model,
            defaults: defaults,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(string: "https://updates.example.test/stable/appcast.xml")!,
            ]),
            providerStarter: { _ in }
        )
        let handler = P6UInstallHandlerRecorder()
        controller.beginInstallationPreparation { handler.invoke() }
        for _ in 0..<200 {
            if handler.invocationCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(handler.invocationCount, 1)
        let vaultClosed = await model.vaultController.database.isOpen()
        XCTAssertFalse(vaultClosed)

        controller.beginAbortRecovery(NSError(
            domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
            code: 4_008
        ))
        for _ in 0..<200 {
            let vaultIsOpen = await model.vaultController.database.isOpen()
            if vaultIsOpen,
               !model.updateInstallationInProgress,
               case .failed = controller.state {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        let vaultRecovered = await model.vaultController.database.isOpen()
        XCTAssertTrue(vaultRecovered)
        XCTAssertFalse(model.updateInstallationInProgress)
        guard case .failed(let failure) = controller.state else {
            return XCTFail("Authorize Later must finish with a typed recoverable block")
        }
        XCTAssertEqual(failure.code, .installationBlocked)
        XCTAssertTrue(failure.isRecoverable)
    }

    @MainActor
    func testVaultDeletionAndUpdateReadinessAreMutuallyExclusiveInBothOrderings() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-p6u-delete-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let store = try LocalStore(
            inMemory: false,
            url: fixtureDirectory.appendingPathComponent("LokiBrief.store")
        )
        let credentialStore = UpdateTestCredentialStore()
        let slack = SlackAppController(store: store, clientID: nil, credentialStore: credentialStore)
        let checkpoint = P6UVaultDeletionCheckpoint()
        let vault = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: fixtureDirectory.appendingPathComponent("LokiVault.sqlite"),
            deletionCheckpoint: { await checkpoint.suspend() }
        )
        let model = try AppModel(store: store, slackController: slack, vaultController: vault)
        try await waitUntilVaultIsIdle(vault)
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [LokiApplicationUpdateParticipant(model: model)]
        )

        let deletion = Task { await vault.deleteAllVaultData() }
        for _ in 0..<200 {
            if await checkpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let deletionIsSuspended = await checkpoint.isSuspended()
        XCTAssertTrue(deletionIsSuspended)
        let blockedUpdate = await coordinator.acquireUpdateLease()
        XCTAssertEqual(blockedUpdate.status, .blocked)
        XCTAssertEqual(blockedUpdate.reasonCodes, [.deleteAllInProgress])
        XCTAssertNil(blockedUpdate.lease)
        await checkpoint.resume()
        let deletionSucceeded = await deletion.value
        XCTAssertTrue(deletionSucceeded)
    }

    @MainActor
    func testWholeAppDeleteBarrierRejectsNewFeedOllamaAndChatWork() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "loki-p7-delete-admission-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let store = try LocalStore(
            inMemory: false,
            url: fixtureDirectory.appendingPathComponent("LokiBrief.store")
        )
        let existingFeed = FeedSubscription(
            id: "delete-barrier-feed",
            title: "Delete Barrier Feed",
            canonicalURL: URL(string: "https://example.com/existing.xml")!,
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
            createdAt: .now,
            updatedAt: .now
        )
        try store.persistFeedSubscription(existingFeed)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: UpdateTestCredentialStore()
        )
        let checkpoint = P6UVaultDeletionCheckpoint()
        let vault = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: fixtureDirectory.appendingPathComponent("LokiVault.sqlite"),
            deletionCheckpoint: { await checkpoint.suspend() }
        )
        let model = try AppModel(
            store: store,
            feedClient: P7DeleteBarrierFeedClient(),
            slackController: slack,
            vaultController: vault
        )
        try await waitUntilVaultIsIdle(vault)

        let deletion = Task {
            await model.deleteAllDataIncludingSlackCredentials()
        }
        for _ in 0..<200 {
            if await checkpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let deletionSuspended = await checkpoint.isSuspended()
        XCTAssertTrue(deletionSuspended)
        XCTAssertTrue(model.deleteAllInProgress)

        let added = await model.addFeed(
            urlText: "https://example.com/new.xml",
            title: "Must Not Be Added",
            saveWhenUnavailable: true
        )
        XCTAssertFalse(added)
        model.setFeedEnabled(id: existingFeed.id, enabled: false)
        XCTAssertTrue(
            try XCTUnwrap(
                store.domainFeedSubscriptions().first {
                    $0.id == existingFeed.id
                }
            ).enabled
        )
        model.checkOllama()
        XCTAssertNil(model.chatController?.newConversation())
        XCTAssertTrue(
            model.errorMessage?.contains("Delete All Local Data") == true
        )

        await checkpoint.resume()
        await deletion.value
        XCTAssertFalse(model.deleteAllInProgress)
        XCTAssertTrue(try store.domainFeedSubscriptions().isEmpty)
        XCTAssertTrue(try store.lokiConversationPage().isEmpty)
    }

    @MainActor
    func testSuspendedSlackDisconnectBlocksInstallReadinessUntilMutationFinishes() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        let credentialStore = UpdateTestCredentialStore()
        try await credentialStore.create(credential)
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let authorizer = P6USuspendedSlackCancellationAuthorizer()
        let sync = P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence())
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: authorizer,
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: sync,
            tokenRevoker: P6USuccessfulSlackRevoker()
        )
        let model = try AppModel(store: store, slackController: slack)
        try await waitUntilVaultIsIdle(model.vaultController)
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [LokiApplicationUpdateParticipant(model: model)]
        )

        let disconnect = Task {
            await slack.disconnect(workspaceID: credential.accountIdentifier)
        }
        for _ in 0..<200 {
            if await authorizer.isCancellationSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancellationSuspended = await authorizer.isCancellationSuspended()
        XCTAssertTrue(cancellationSuspended)
        XCTAssertTrue(slack.hasUpdateBlockingWork)

        let blocked = await coordinator.acquireUpdateLease()
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.reasonCodes, [.activeSlackWork])
        XCTAssertNil(blocked.lease)

        await authorizer.resumeCancellation()
        let result = await disconnect.value
        XCTAssertFalse(result.localDataDeleted)
        XCTAssertTrue(result.localDataPreserved)
        XCTAssertTrue(result.connectorDisabled)
        XCTAssertTrue(result.credentialDeleted)
        XCTAssertFalse(slack.hasUpdateBlockingWork)

        let ready = await coordinator.acquireUpdateLease()
        XCTAssertEqual(ready.status, .ready)
        let lease = try XCTUnwrap(ready.lease)
        let recovery = await lease.abort()
        XCTAssertEqual(recovery.state, .aborted)
        try await model.vaultController.database.close()
    }

    @MainActor
    func testSuspendedSlackPermalinkResolutionBlocksInstallReadinessUntilPersistenceFinishes() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        let credentialStore = UpdateTestCredentialStore()
        try await credentialStore.create(credential)
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let evidence = makeSlackEvidence()
        try store.persistSlackEvidence(evidence)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.slack.com/archives/C-P6U/p1721577600000001"))
        let sync = P6USuspendedPermalinkSync(
            resolvedEvidence: evidence.replacingPermalink(expectedURL)
        )
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: P6USuspendedSlackCancellationAuthorizer(),
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: sync,
            tokenRevoker: P6USuccessfulSlackRevoker()
        )
        let model = try AppModel(store: store, slackController: slack)
        try await waitUntilVaultIsIdle(model.vaultController)
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [LokiApplicationUpdateParticipant(model: model)]
        )

        let resolution = Task { await slack.resolvePermalink(evidenceID: evidence.id) }
        for _ in 0..<200 {
            if await sync.isPermalinkSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let permalinkSuspended = await sync.isPermalinkSuspended()
        XCTAssertTrue(permalinkSuspended)
        XCTAssertTrue(slack.hasUpdateBlockingWork)

        let blocked = await coordinator.acquireUpdateLease()
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.reasonCodes, [.activeSlackWork])
        XCTAssertNil(blocked.lease)

        await sync.resumePermalink()
        let resolvedURL = await resolution.value
        XCTAssertEqual(resolvedURL, expectedURL)
        XCTAssertEqual(try store.domainSlackEvidence().first?.permalink, expectedURL)
        XCTAssertFalse(slack.hasUpdateBlockingWork)

        let ready = await coordinator.acquireUpdateLease()
        XCTAssertEqual(ready.status, .ready)
        let lease = try XCTUnwrap(ready.lease)
        let recovery = await lease.abort()
        XCTAssertEqual(recovery.state, .aborted)
        try await model.vaultController.database.close()
    }

    @MainActor
    func testCancelledSlackConnectKeepsReadinessBlockedThroughLateCredentialCleanup() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        let credentialStore = P6USuspendedCredentialStore(
            suspendCreate: true,
            suspendDelete: true
        )
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: P6UCredentialAuthorizer(credential: credential),
            identityValidator: P6USlackIdentityValidator(),
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )

        let connection = Task { await slack.connect() }
        for _ in 0..<200 {
            if await credentialStore.isCreateSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let createSuspended = await credentialStore.isCreateSuspended()
        XCTAssertTrue(createSuspended)

        await slack.cancelAuthorization()
        XCTAssertEqual(slack.authorizationOperation, .idle)
        await credentialStore.resumeCreate()
        for _ in 0..<200 {
            if await credentialStore.isDeleteSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let deleteSuspended = await credentialStore.isDeleteSuspended()
        XCTAssertTrue(deleteSuspended)
        XCTAssertEqual(slack.authorizationOperation, .idle)
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        await credentialStore.resumeDelete()
        let connected = await connection.value
        XCTAssertFalse(connected)
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testDisconnectInvalidationClearsStaleAuthorizationMarkerAfterLeasesDrain() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        let credentialStore = UpdateTestCredentialStore()
        try await credentialStore.create(credential)
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let identityValidator = P6USuspendedSlackIdentityValidator()
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: P6UCredentialAuthorizer(credential: credential),
            identityValidator: identityValidator,
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )

        let connection = Task { await slack.connect() }
        for _ in 0..<200 {
            if await identityValidator.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let identitySuspended = await identityValidator.isSuspended()
        XCTAssertTrue(identitySuspended)
        XCTAssertEqual(slack.authorizationOperation, .validatingIdentity)

        let disconnect = await slack.disconnect(
            workspaceID: credential.accountIdentifier,
            revokeRemotely: false
        )
        XCTAssertFalse(disconnect.localDataDeleted)
        XCTAssertTrue(disconnect.localDataPreserved)
        XCTAssertTrue(disconnect.connectorDisabled)
        XCTAssertTrue(disconnect.credentialDeleted)
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        await identityValidator.resume()
        let connected = await connection.value
        XCTAssertFalse(connected)
        XCTAssertEqual(slack.authorizationOperation, .idle)
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testCancelledSlackDiscoveryKeepsReadinessBlockedThroughLateReconciliation() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let credentialStore = P6USuspendedCredentialStore(
            credential: credential,
            suspendRead: true
        )
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: P6UCredentialAuthorizer(credential: credential),
            identityValidator: P6USlackIdentityValidator(),
            apiClient: P6USuccessfulSlackAPI(conversations: [makeSlackConversation()]),
            syncCoordinator: P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )

        let discovery = Task {
            await slack.discoverChannels(workspaceID: credential.accountIdentifier)
        }
        for _ in 0..<200 {
            if await credentialStore.isReadSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let readSuspended = await credentialStore.isReadSuspended()
        XCTAssertTrue(readSuspended)

        await slack.cancelWorkspaceOperation(workspaceID: credential.accountIdentifier)
        XCTAssertEqual(slack.workspaceOperations[credential.accountIdentifier], .idle)
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        await credentialStore.resumeRead()
        let discovered = await discovery.value
        XCTAssertFalse(discovered)
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testSuspendedSlackConsentBlocksUpdateAndDeleteAllBeforePersistence() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: UpdateTestCredentialStore()
        )
        await slack.setLocalModelConsent(workspaceID: credential.accountIdentifier, enabled: true)
        XCTAssertTrue(try XCTUnwrap(store.slackWorkspaceConnection(id: credential.accountIdentifier)).localModelConsent)

        let consentCheckpoint = P6USuspendedSlackCallback()
        slack.onSlackEvidenceDeletionWillBegin = { _, _ in await consentCheckpoint.suspend() }
        let consent = Task {
            await slack.setLocalModelConsent(workspaceID: credential.accountIdentifier, enabled: false)
        }
        for _ in 0..<200 {
            if await consentCheckpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let consentSuspended = await consentCheckpoint.isSuspended()
        XCTAssertTrue(consentSuspended)
        XCTAssertTrue(try XCTUnwrap(store.slackWorkspaceConnection(id: credential.accountIdentifier)).localModelConsent)
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())
        let deleteAllPrepared = await slack.prepareForWholeAppDataDeletion()
        XCTAssertFalse(deleteAllPrepared)
        XCTAssertFalse(slack.wholeAppDeletionInProgress)

        await consentCheckpoint.resume()
        await consent.value
        XCTAssertFalse(try XCTUnwrap(store.slackWorkspaceConnection(id: credential.accountIdentifier)).localModelConsent)
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testSuspendedSlackSyncCallbackBlocksReadinessAfterWorkspaceOperationIsIdle() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        let credentialStore = UpdateTestCredentialStore()
        try await credentialStore.create(credential)
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        try store.persistDiscoveredSlackConversations([makeSlackConversation()], workspaceID: credential.accountIdentifier)
        try store.setSlackConversationSelected(
            id: "\(credential.accountIdentifier):C-P6U",
            selected: true
        )
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: credentialStore,
            authorizer: P6UCredentialAuthorizer(credential: credential),
            identityValidator: P6USlackIdentityValidator(),
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: P6USuccessfulSlackSync(output: makeSuccessfulSlackSyncOutput()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )
        let evidenceCheckpoint = P6USuspendedSlackCallback()
        slack.onBriefingEvidenceChanged = { _ in await evidenceCheckpoint.suspend() }

        let sync = Task {
            await slack.syncSelectedChannels(workspaceID: credential.accountIdentifier)
        }
        for _ in 0..<200 {
            if await evidenceCheckpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let callbackSuspended = await evidenceCheckpoint.isSuspended()
        XCTAssertTrue(callbackSuspended)
        XCTAssertEqual(slack.workspaceOperations[credential.accountIdentifier], .idle)
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        await evidenceCheckpoint.resume()
        let synced = await sync.value
        XCTAssertTrue(synced)
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testSuspendedSlackOuterMutationCallbackBlocksReadinessAfterNestedCancellationIsIdle() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: UpdateTestCredentialStore(),
            authorizer: P6UCredentialAuthorizer(credential: credential),
            identityValidator: P6USlackIdentityValidator(),
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )
        let evidenceCheckpoint = P6USuspendedSlackCallback()
        slack.onBriefingEvidenceChanged = { _ in await evidenceCheckpoint.suspend() }

        let disable = Task {
            await slack.disableWorkspace(workspaceID: credential.accountIdentifier)
        }
        for _ in 0..<200 {
            if await evidenceCheckpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let callbackSuspended = await evidenceCheckpoint.isSuspended()
        XCTAssertTrue(callbackSuspended)
        XCTAssertEqual(slack.workspaceOperations[credential.accountIdentifier], .idle)
        XCTAssertFalse(slack.isWorkspaceEnabled(credential.accountIdentifier))
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        await evidenceCheckpoint.resume()
        await disable.value
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testQueuedSlackEvidenceCallbackClaimsReadinessBlockBeforeTaskStarts() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        try store.persistDiscoveredSlackConversations([makeSlackConversation()], workspaceID: credential.accountIdentifier)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: UpdateTestCredentialStore()
        )
        let evidenceCheckpoint = P6USuspendedSlackCallback()
        slack.onBriefingEvidenceChanged = { _ in await evidenceCheckpoint.suspend() }

        await slack.setChannelSelected(
            workspaceID: credential.accountIdentifier,
            channelID: "C-P6U",
            selected: true
        )
        XCTAssertTrue(slack.hasUpdateBlockingWork)
        XCTAssertFalse(slack.prepareForUpdateInstallation())

        for _ in 0..<200 {
            if await evidenceCheckpoint.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let callbackSuspended = await evidenceCheckpoint.isSuspended()
        XCTAssertTrue(callbackSuspended)
        await evidenceCheckpoint.resume()
        for _ in 0..<200 {
            if !slack.hasUpdateBlockingWork { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(slack.hasUpdateBlockingWork)
        let callbackCount = await evidenceCheckpoint.count()
        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(slack.prepareForUpdateInstallation())
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testActiveUpdateBarrierRejectsSlackCancellationAndReportsBlockedDisconnectTruthfully() async throws {
        let store = try LocalStore(inMemory: true)
        let credential = makeCredential()
        try store.persistSlackWorkspace(makeSlackConnection(credential: credential), enabled: true)
        let slack = SlackAppController(
            store: store,
            clientID: "123.456",
            credentialStore: UpdateTestCredentialStore(),
            authorizer: P6USuspendedSlackCancellationAuthorizer(),
            identityValidator: P6USlackIdentityValidator(),
            apiClient: P6UNoOpSlackAPI(),
            syncCoordinator: P6USuspendedPermalinkSync(resolvedEvidence: makeSlackEvidence()),
            tokenRevoker: P6USuccessfulSlackRevoker()
        )

        XCTAssertTrue(slack.prepareForUpdateInstallation())
        await slack.cancelAuthorization()
        await slack.cancelWorkspaceOperation(workspaceID: credential.accountIdentifier)
        XCTAssertEqual(slack.authorizationOperation, .idle)
        XCTAssertNil(slack.workspaceOperations[credential.accountIdentifier])

        let disconnect = await slack.disconnect(workspaceID: credential.accountIdentifier)
        XCTAssertEqual(disconnect.reasonCode, "slack_update_installation_in_progress")
        XCTAssertFalse(disconnect.localDataDeleted)
        XCTAssertFalse(disconnect.credentialDeleted)
        let deleteAllPrepared = await slack.prepareForWholeAppDataDeletion()
        XCTAssertFalse(deleteAllPrepared)
        XCTAssertTrue(slack.updateInstallationInProgress)
        slack.resumeAfterUpdateInstallationAbort()
    }

    @MainActor
    func testFailedVaultReopenKeepsPersistenceMutationBarrierLatchedUntilRestartRecovery() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-p6u-recovery-latch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let vaultURL = fixtureDirectory.appendingPathComponent("LokiVault.sqlite")
        let backupURL = fixtureDirectory.appendingPathComponent("LokiVault.backup")
        let store = try LocalStore(
            inMemory: false,
            url: fixtureDirectory.appendingPathComponent("LokiBrief.store")
        )
        let slack = SlackAppController(store: store, clientID: nil, credentialStore: UpdateTestCredentialStore())
        let vault = try VaultController(store: store, slackController: slack, databaseURL: vaultURL)
        let model = try AppModel(store: store, slackController: slack, vaultController: vault)
        try await waitUntilVaultIsIdle(vault)
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [LokiApplicationUpdateParticipant(model: model)]
        )

        let report = await coordinator.acquireUpdateLease()
        let lease = try XCTUnwrap(report.lease)
        let openDuringInstall = await vault.database.isOpen()
        XCTAssertFalse(openDuringInstall)
        try FileManager.default.moveItem(at: vaultURL, to: backupURL)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: false)

        let failedRecovery = await lease.abort()
        XCTAssertEqual(failedRecovery.state, .degraded)
        XCTAssertTrue(model.updateInstallationInProgress)
        XCTAssertFalse(model.chatController?.chatPersistenceIsOpen ?? true)
        let originalTopics = model.p2Settings.topicPreferences
        model.setTopicPreferences("must-remain-blocked-after-recovery-failure")
        XCTAssertEqual(model.p2Settings.topicPreferences, originalTopics)

        try FileManager.default.removeItem(at: vaultURL)
        try FileManager.default.moveItem(at: backupURL, to: vaultURL)
        let restartRecovery = await model.recoverAfterApplicationUpdateAbort()
        XCTAssertTrue(restartRecovery.recovered)
        XCTAssertFalse(model.updateInstallationInProgress)
        XCTAssertTrue(model.chatController?.chatPersistenceIsOpen ?? false)
        let openAfterRestartRecovery = await vault.database.isOpen()
        XCTAssertTrue(openAfterRestartRecovery)
        try await vault.database.close()
    }

    @MainActor
    func testLiveP6UDataFixtureSeedOrVerifyAndCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["LOKI_P6U_LIVE_FIXTURE_PHASE"] else {
            throw XCTSkip("P6U live replacement fixture is opt-in.")
        }
        guard phase == "seed" || phase == "verify_cleanup" else {
            return XCTFail("LOKI_P6U_LIVE_FIXTURE_PHASE must be seed or verify_cleanup")
        }
        let namespace = try XCTUnwrap(environment["LOKI_P6U_LIVE_FIXTURE_NAMESPACE"])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard (1...64).contains(namespace.count),
              namespace.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return XCTFail("P6U live fixture namespace is invalid")
        }

        let store = try LocalStore()
        let keychainService = "com.agentloki.LokiBrief.tests.p6u.update.\(namespace)"
        let credentialStore = SecuritySlackCredentialStore(service: keychainService)
        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: credentialStore
        )
        let vault = try VaultController(store: store, slackController: slack)
        defer { Task { try? await vault.database.close() } }

        if phase == "seed" {
            do {
                try? await credentialStore.delete(teamID: liveTeamID(namespace), userID: liveUserID(namespace))
                try seedLiveApplicationData(store: store, namespace: namespace)
                try await seedLiveVault(vault.database, namespace: namespace)
                try await credentialStore.create(liveCredential(namespace: namespace))
                try await assertLiveFixture(
                    store: store,
                    vault: vault,
                    credentialStore: credentialStore,
                    namespace: namespace
                )
            } catch {
                try? await credentialStore.delete(teamID: liveTeamID(namespace), userID: liveUserID(namespace))
                throw error
            }
            try await vault.database.close()
            return
        }

        var verificationError: Error?
        do {
            try await assertLiveFixture(
                store: store,
                vault: vault,
                credentialStore: credentialStore,
                namespace: namespace
            )
        } catch {
            verificationError = error
        }
        do {
            try await credentialStore.delete(teamID: liveTeamID(namespace), userID: liveUserID(namespace))
        } catch {
            if verificationError == nil { verificationError = error }
        }
        try await vault.database.close()
        if let verificationError { throw verificationError }
    }

    @MainActor
    func testPreparedInstallClosesVaultAndAbortPreservesApplicationData() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-p6u-preservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let swiftDataURL = fixtureDirectory.appendingPathComponent("LokiBrief.store")
        let vaultURL = fixtureDirectory.appendingPathComponent("LokiVault.sqlite")
        let credentialStore = UpdateTestCredentialStore()
        let before = try await exercisePreparedInstallAndAbort(
            swiftDataURL: swiftDataURL,
            vaultURL: vaultURL,
            credentialStore: credentialStore
        )

        // Reopen both disk-backed stores after the preparation/abort boundary.
        // This is the deterministic process-relaunch analogue; the realistic
        // Sparkle gate separately proves an actual application relaunch.
        let reopenedStore = try LocalStore(inMemory: false, url: swiftDataURL)
        let reopenedSlack = SlackAppController(
            store: reopenedStore,
            clientID: nil,
            credentialStore: credentialStore
        )
        let reopenedVault = try VaultController(
            store: reopenedStore,
            slackController: reopenedSlack,
            databaseURL: vaultURL
        )
        let afterReopen = try await preservationSnapshot(
            store: reopenedStore,
            vault: reopenedVault,
            credentialStore: credentialStore
        )
        XCTAssertEqual(afterReopen, before)
        try await reopenedVault.database.close()
    }

    @MainActor
    private func exercisePreparedInstallAndAbort(
        swiftDataURL: URL,
        vaultURL: URL,
        credentialStore: UpdateTestCredentialStore
    ) async throws -> PreservationSnapshot {
        let store = try LocalStore(inMemory: false, url: swiftDataURL)
        try seedApplicationData(store: store)
        try await credentialStore.create(makeCredential())

        let slack = SlackAppController(
            store: store,
            clientID: nil,
            credentialStore: credentialStore
        )
        let vault = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: vaultURL
        )
        try await seedVault(vault.database)

        let model = try AppModel(
            store: store,
            slackController: slack,
            vaultController: vault
        )
        try await waitUntilVaultIsIdle(vault)

        let before = try await preservationSnapshot(
            store: store,
            vault: vault,
            credentialStore: credentialStore
        )
        let coordinator = ApplicationUpdateReadinessCoordinator(
            participants: [LokiApplicationUpdateParticipant(model: model)]
        )

        XCTAssertTrue(vault.beginForegroundDatabaseOperation())
        let blockedByActiveDatabase = await coordinator.acquireUpdateLease()
        XCTAssertEqual(blockedByActiveDatabase.status, .blocked)
        XCTAssertEqual(blockedByActiveDatabase.reasonCodes, [.activeVaultDatabaseWork])
        XCTAssertNil(blockedByActiveDatabase.lease)
        vault.endForegroundDatabaseOperation()

        let report = await coordinator.acquireUpdateLease()
        XCTAssertEqual(report.status, .ready, "reason_codes=\(report.reasonCodes.map(\.rawValue))")
        let lease = try XCTUnwrap(
            report.lease,
            "Expected a readiness lease; blockers=\(report.blockers.map(\.reasonCode.rawValue))"
        )
        let databaseOpenDuringInstall = await vault.database.isOpen()
        XCTAssertFalse(databaseOpenDuringInstall)

        let vaultDeletionDuringInstall = await vault.deleteAllVaultData()
        XCTAssertFalse(vaultDeletionDuringInstall)
        XCTAssertNotNil(vault.errorMessage)

        let densityBeforeBlockedMutation = model.density
        let topicBeforeBlockedMutation = model.p2Settings.topicPreferences
        model.updateDensity(densityBeforeBlockedMutation == .compact ? .comfortable : .compact)
        model.setTopicPreferences("must-not-persist-during-update")
        model.setFeedEnabled(id: "update-preservation-feed", enabled: false)
        XCTAssertEqual(model.density, densityBeforeBlockedMutation)
        XCTAssertEqual(model.p2Settings.topicPreferences, topicBeforeBlockedMutation)
        XCTAssertTrue(try XCTUnwrap(store.domainFeedSubscriptions().first).enabled)

        await model.deleteAllDataIncludingSlackCredentials()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try store.history().map(\.id), before.historyIDs)

        let recovery = await lease.abort()
        XCTAssertEqual(recovery.state, .aborted)
        let databaseOpenAfterRecovery = await vault.database.isOpen()
        XCTAssertTrue(databaseOpenAfterRecovery)

        let after = try await preservationSnapshot(
            store: store,
            vault: vault,
            credentialStore: credentialStore
        )
        XCTAssertEqual(after, before)
        await model.shutdownForApplicationTermination()
        try await vault.database.close()
        return before
    }

    private struct PreservationSnapshot: Equatable {
        let feedIDs: [String]
        let historyIDs: [String]
        let schedule: BriefSchedule
        let vaultAccountIDs: [String]
        let vaultContainerIDs: [String]
        let vaultRecordCount: Int
        let deterministicOnly: Bool
        let topicPreferences: String
        let credentialAccountIdentifier: String
    }

    @MainActor
    private func seedApplicationData(store: LocalStore) throws {
        let now = Date(timeIntervalSince1970: 1_721_577_600)
        let feedURL = try XCTUnwrap(URL(string: "https://updates-test.example.test/feed.xml"))
        try store.persistFeedSubscription(FeedSubscription(
            id: "update-preservation-feed",
            title: "Preserved source",
            canonicalURL: feedURL,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: now,
            lastSuccessfulAt: now,
            lastHTTPStatus: 200,
            eTag: nil,
            lastModified: nil,
            state: .connected,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: now,
            updatedAt: now
        ))

        let settings = try store.settings()
        settings.deterministicOnly = false
        let p2Settings = try store.p2Settings()
        p2Settings.topicPreferences = "preserved-topic"
        try store.record(DeterministicBriefingEngine().generatePreview(revision: 17))
        var schedule = try store.primaryBriefSchedule()
        schedule.enabled = true
        schedule.localTime = ScheduleLocalTime(hour: 7, minute: 45)
        schedule.selectedAccountIDs = ["vault-test-account"]
        try store.savePrimaryBriefSchedule(schedule, at: now)
        try store.save()
    }

    private func seedVault(_ database: VaultDatabase) async throws {
        let now = Date(timeIntervalSince1970: 1_721_577_600)
        _ = try await database.upsert(account: VaultAccountInput(
            id: "vault-test-account",
            provider: "feed",
            providerAccountID: "update-preservation-source",
            displayName: "Preserved Vault source",
            createdAt: now,
            updatedAt: now
        ))
        _ = try await database.upsert(container: VaultContainerInput(
            id: "vault-test-container",
            accountID: "vault-test-account",
            providerContainerID: "feed-container",
            kind: "feed",
            displayName: "Preserved items",
            createdAt: now,
            updatedAt: now
        ))
        _ = try await database.upsert(record: VaultRecordInput(
            id: "vault-test-record",
            accountID: "vault-test-account",
            containerID: "vault-test-container",
            providerRecordID: "record-1",
            kind: "feed_item",
            title: "Preserved title",
            body: "Preserved body",
            occurredAt: now,
            capturedAt: now,
            modifiedAt: now
        ))
    }

    @MainActor
    private func waitUntilVaultIsIdle(_ vault: VaultController) async throws {
        // AppModel schedules its initial Vault bootstrap after initialization.
        // Give that task one deterministic opportunity to enter its guarded
        // operation before waiting for the final idle state.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<200 {
            if !vault.hasUpdateBlockingWork { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Vault bootstrap did not become idle")
    }

    @MainActor
    private func preservationSnapshot(
        store: LocalStore,
        vault: VaultController,
        credentialStore: UpdateTestCredentialStore
    ) async throws -> PreservationSnapshot {
        let accounts = try await vault.database.accounts()
        let containers = try await vault.database.containers()
        let storage = try await vault.database.storageSummary()
        let credential = try await credentialStore.read(teamID: "T-P6U", userID: "U-P6U")
        return PreservationSnapshot(
            feedIDs: try store.domainFeedSubscriptions().map(\.id).sorted(),
            historyIDs: try store.history().map(\.id).sorted(),
            schedule: try store.primaryBriefSchedule(),
            vaultAccountIDs: accounts.map(\.id).sorted(),
            vaultContainerIDs: containers.map(\.id).sorted(),
            vaultRecordCount: storage.recordCount,
            deterministicOnly: try store.settings().deterministicOnly,
            topicPreferences: try store.p2Settings().topicPreferences,
            credentialAccountIdentifier: credential.accountIdentifier
        )
    }

    private func makeCredential() -> SlackOAuthCredential {
        let issuedAt = Date(timeIntervalSince1970: 1_721_577_600)
        return SlackOAuthCredential(
            teamID: "T-P6U",
            userID: "U-P6U",
            accessToken: "credential-preservation-access-sentinel",
            refreshToken: "credential-preservation-refresh-sentinel",
            tokenType: "user",
            issuedAt: issuedAt,
            accessTokenExpiresAt: issuedAt.addingTimeInterval(3_600),
            refreshTokenExpiresAt: issuedAt.addingTimeInterval(86_400),
            grantedScopes: ["channels:history"]
        )
    }

    private func makeSlackConnection(credential: SlackOAuthCredential) -> SlackWorkspaceConnection {
        let scopes = Set(credential.grantedScopes.compactMap(SlackGrantedScope.init(rawValue:)))
        return SlackWorkspaceConnection(
            id: credential.accountIdentifier,
            teamID: credential.teamID,
            teamName: "P6U synthetic workspace",
            userID: credential.userID,
            userDisplayName: "P6U synthetic user",
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
            connectedAt: credential.issuedAt,
            updatedAt: credential.issuedAt,
            lastFailureReasonCode: nil
        )
    }

    private func makeSlackEvidence() -> SlackMessageEvidence {
        SlackMessageEvidence(
            id: "p6u-slack-evidence",
            workspaceID: "T-P6U:U-P6U",
            workspaceName: "P6U synthetic workspace",
            channelID: "C-P6U",
            channelName: "p6u-synthetic-channel",
            channelKind: .publicChannel,
            messageTimestamp: SlackTimestamp(rawValue: "1721577600.000001")!,
            excerpt: "Synthetic update-readiness evidence",
            author: .init(id: "U-P6U-AUTHOR", displayName: "Synthetic author", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: false,
            replyCount: 0,
            isEdited: false,
            editedAt: nil,
            permalink: nil,
            retrievedAt: Date(timeIntervalSince1970: 1_721_577_600),
            selectedChannelWeight: 1,
            state: .available
        )
    }

    private func makeSlackConversation() -> SlackConversation {
        SlackConversation(
            id: "C-P6U",
            workspaceID: "T-P6U:U-P6U",
            displayName: "p6u-synthetic-channel",
            kind: .publicChannel,
            isMember: true,
            isArchived: false,
            discoveredAt: Date(timeIntervalSince1970: 1_721_577_600)
        )
    }

    private func makeSuccessfulSlackSyncOutput() -> SlackSyncOutput {
        let anchor = Date(timeIntervalSince1970: 1_721_577_600)
        let cursor = SlackSyncCursor(
            workspaceID: "T-P6U:U-P6U",
            channelID: "C-P6U",
            committedOldest: SlackTimestamp(rawValue: "1721577500.000001"),
            windowLatest: nil,
            nextCursor: nil,
            pendingHighWater: nil,
            updatedAt: anchor
        )
        return SlackSyncOutput(
            run: SlackSyncRun(
                id: "p6u-successful-sync",
                traceID: "p6u-successful-sync-trace",
                workspaceID: "T-P6U:U-P6U",
                startedAt: anchor.addingTimeInterval(-1),
                completedAt: anchor,
                state: .completed,
                selectedChannelCount: 1,
                successfulChannelCount: 1,
                failedChannelCount: 0,
                normalizedMessageCount: 0,
                rateLimitState: nil,
                channelResults: [
                    SlackChannelSyncResult(
                        channelID: "C-P6U",
                        state: .completed,
                        normalizedCount: 0,
                        tombstoneCount: 0,
                        failureReasonCode: nil,
                        cursor: cursor
                    ),
                ]
            ),
            evidenceUpserts: [],
            tombstones: [],
            cursorUpdates: [cursor],
            directives: []
        )
    }

    @MainActor
    private func seedLiveApplicationData(store: LocalStore, namespace: String) throws {
        let anchor = Date(timeIntervalSince1970: 1_721_609_100)
        let feedID = liveFeedID(namespace)
        let feedURL = try XCTUnwrap(URL(string: "https://localhost:9443/fixture/\(namespace)/feed.xml"))
        try store.persistFeedSubscription(FeedSubscription(
            id: feedID,
            title: "P6U disposable source",
            canonicalURL: feedURL,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: anchor,
            lastSuccessfulAt: anchor,
            lastHTTPStatus: 200,
            eTag: nil,
            lastModified: nil,
            state: .connected,
            failure: nil,
            policy: .default,
            weight: 1,
            createdAt: anchor,
            updatedAt: anchor
        ))
        let brief = Brief(
            id: liveBriefID(namespace),
            date: anchor,
            title: "Loki Brief · 2026-07-19",
            summary: "Disposable P6U preservation evidence.",
            status: .ready,
            sections: [],
            generation: BriefGenerationRecord(
                engineID: "p6u-live-fixture",
                generatedAt: anchor,
                status: .ready,
                reasonCode: "p6u_live_fixture_seeded",
                fixtureRevision: 0,
                providerKind: "deterministic"
            ),
            briefingDay: LocalCalendarDay(year: 2026, month: 7, day: 19)
        )
        try store.record(brief)
        let settings = try store.settings()
        settings.deterministicOnly = true
        let p2Settings = try store.p2Settings()
        p2Settings.topicPreferences = "p6u-live-fixture"
        var schedule = try store.primaryBriefSchedule()
        schedule.enabled = true
        schedule.localTime = ScheduleLocalTime(hour: 7, minute: 19)
        schedule.selectedAccountIDs = [liveVaultAccountID(namespace)]
        try store.savePrimaryBriefSchedule(schedule, at: anchor)
        try store.save()
    }

    private func seedLiveVault(_ database: VaultDatabase, namespace: String) async throws {
        let anchor = Date(timeIntervalSince1970: 1_721_609_100)
        _ = try await database.upsert(account: VaultAccountInput(
            id: liveVaultAccountID(namespace),
            provider: "feed",
            providerAccountID: liveFeedID(namespace),
            displayName: "P6U disposable source",
            createdAt: anchor,
            updatedAt: anchor
        ))
        _ = try await database.upsert(container: VaultContainerInput(
            id: liveVaultContainerID(namespace),
            accountID: liveVaultAccountID(namespace),
            providerContainerID: "p6u-container",
            kind: "feed",
            displayName: "P6U disposable items",
            createdAt: anchor,
            updatedAt: anchor
        ))
        _ = try await database.upsert(record: VaultRecordInput(
            id: liveVaultRecordID(namespace),
            accountID: liveVaultAccountID(namespace),
            containerID: liveVaultContainerID(namespace),
            providerRecordID: "p6u-record",
            kind: "feed_item",
            title: "P6U disposable record",
            body: "Synthetic preservation evidence.",
            occurredAt: anchor,
            capturedAt: anchor,
            modifiedAt: anchor
        ))
    }

    @MainActor
    private func assertLiveFixture(
        store: LocalStore,
        vault: VaultController,
        credentialStore: SecuritySlackCredentialStore,
        namespace: String
    ) async throws {
        let subscriptions = try store.domainFeedSubscriptions()
        XCTAssertTrue(subscriptions.contains { $0.id == liveFeedID(namespace) && $0.enabled })
        let storedBrief = try XCTUnwrap(store.history().first { $0.id == liveBriefID(namespace) })
        let decodedBrief = try storedBrief.decodedBrief()
        XCTAssertEqual(decodedBrief.resolvedBriefingDay, LocalCalendarDay(year: 2026, month: 7, day: 19))
        XCTAssertEqual(decodedBrief.resolvedBriefingDay.storageValue, "2026-07-19")
        let schedule = try store.primaryBriefSchedule()
        XCTAssertTrue(schedule.enabled)
        XCTAssertEqual(schedule.localTime, ScheduleLocalTime(hour: 7, minute: 19))
        XCTAssertTrue(schedule.selectedAccountIDs.contains(liveVaultAccountID(namespace)))
        XCTAssertEqual(try store.p2Settings().topicPreferences, "p6u-live-fixture")

        let accounts = try await vault.database.accounts()
        let containers = try await vault.database.containers(accountID: liveVaultAccountID(namespace))
        let record = try await vault.database.record(id: liveVaultRecordID(namespace))
        XCTAssertTrue(accounts.contains { $0.id == liveVaultAccountID(namespace) })
        XCTAssertTrue(containers.contains { $0.id == liveVaultContainerID(namespace) })
        XCTAssertNotNil(record)

        let credential = try await credentialStore.read(
            teamID: liveTeamID(namespace),
            userID: liveUserID(namespace)
        )
        XCTAssertEqual(credential.accountIdentifier, "\(liveTeamID(namespace)):\(liveUserID(namespace))")
        XCTAssertTrue(credential.isStructurallyValid())
        XCTAssertEqual(credential.accessToken.utf8.count, 32)
        XCTAssertEqual(credential.refreshToken.utf8.count, 32)
    }

    private func liveCredential(namespace: String) -> SlackOAuthCredential {
        let anchor = Date(timeIntervalSince1970: 1_721_609_100)
        return SlackOAuthCredential(
            teamID: liveTeamID(namespace),
            userID: liveUserID(namespace),
            accessToken: String(repeating: "a", count: 32),
            refreshToken: String(repeating: "r", count: 32),
            tokenType: "user",
            issuedAt: anchor,
            accessTokenExpiresAt: anchor.addingTimeInterval(3_600),
            refreshTokenExpiresAt: anchor.addingTimeInterval(86_400),
            grantedScopes: ["channels:history"]
        )
    }

    private func liveTeamID(_ namespace: String) -> String { "T-P6U-\(namespace)" }
    private func liveUserID(_ namespace: String) -> String { "U-P6U-\(namespace)" }
    private func liveFeedID(_ namespace: String) -> String { "p6u-feed-\(namespace)" }
    private func liveBriefID(_ namespace: String) -> String { "p6u-brief-\(namespace)" }
    private func liveVaultAccountID(_ namespace: String) -> String { "p6u-vault-account-\(namespace)" }
    private func liveVaultContainerID(_ namespace: String) -> String { "p6u-vault-container-\(namespace)" }
    private func liveVaultRecordID(_ namespace: String) -> String { "p6u-vault-record-\(namespace)" }
}
