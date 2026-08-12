import Combine
import Foundation

enum SlackConnectorAvailability: String, Sendable {
    case configurationRequired
    case disconnected
    case connected
}

enum SlackConnectorOperation: Equatable, Sendable {
    case idle
    case authorizing
    case validatingIdentity
    case discoveringChannels
    case syncingChannels(completed: Int, total: Int)
    case waitingForRateLimit(until: Date)
    case disconnecting
    case cancelling
    case failed(reasonCode: String)
}

private enum SlackRateLimitPersistenceUpdate {
    case preserve
    case set(Date)
    case clear
}

enum SlackChannelFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case selected
    case publicChannels
    case privateChannels
    case member

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .selected: "Selected"
        case .publicChannels: "Public"
        case .privateChannels: "Private"
        case .member: "Member"
        }
    }
}

struct SlackConversationChoice: Identifiable, Hashable, Sendable {
    var id: String { "\(workspaceID):\(channelID)" }
    let workspaceID: String
    let channelID: String
    let displayName: String
    let kind: SlackConversationKind
    let isMember: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let weight: Double
    let lastSuccessfulRefreshAt: Date?
    let lastFailureReasonCode: String?
}

struct SlackWorkspaceStatusDetail: Hashable, Sendable {
    let accessTokenExpiresAt: Date
    let lastSuccessfulRefreshAt: Date?
    let lastFailureReasonCode: String?
    let rateLimitedUntil: Date?

    func tokenFreshness(at date: Date) -> String {
        if accessTokenExpiresAt <= date { return "access token expired; refresh required on next action" }
        return "access token expires \(accessTokenExpiresAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private final class SlackControllerRateLimitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var controller: SlackAppController?

    func bind(_ controller: SlackAppController) {
        lock.lock()
        self.controller = controller
        lock.unlock()
    }

    func receive(workspaceID: String, state: SlackRateLimitState?) {
        lock.lock()
        let controller = controller
        lock.unlock()
        Task { @MainActor in
            controller?.recordRateLimitUpdate(workspaceID: workspaceID, state: state)
        }
    }
}

protocol SlackControllerAuthorizing: Sendable {
    func authorize(prefersEphemeralSession: Bool) async throws -> SlackOAuthCredential
    func cancelActiveAuthorization() async
}

extension SlackAuthorizationService: SlackControllerAuthorizing {}

protocol SlackControllerIdentityValidating: Sendable {
    func validate(
        credential: SlackOAuthCredential,
        provisionalConnection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAuthenticatedIdentity
}

protocol SlackControllerAPIServicing: Sendable {
    func discoverConversations(
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAPICallResult<[SlackConversation]>
    func cancelAll() async
}

extension SlackAPIClient: SlackControllerAPIServicing {}

protocol SlackControllerSyncing: Sendable {
    func syncSelectedChannels(
        connection: SlackWorkspaceConnection,
        selections: [SlackConversationSelection],
        cursors: [SlackSyncCursor],
        trace: SlackTraceContext,
        scheduledBudget: ScheduledBriefingBudgetLedger?,
        progress: SlackSyncCoordinator.ProgressHandler?
    ) async throws -> SlackSyncOutput
    func resolvePermalink(
        for evidence: SlackMessageEvidence,
        connection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackMessageEvidence
    func cancelAll(trace: SlackTraceContext) async
    func controllerClearWorkspaceCaches(workspaceID: String) async
}

extension SlackSyncCoordinator: SlackControllerSyncing {
    func controllerClearWorkspaceCaches(workspaceID: String) async {
        clearWorkspaceCaches(workspaceID: workspaceID)
    }
}

private struct SlackOneShotAccessTokenProvider: SlackAccessTokenProviding {
    let credential: SlackOAuthCredential

    func accessToken(
        teamID: String,
        userID: String,
        forceRefresh: Bool,
        trace: SlackTraceContext
    ) async throws -> String {
        guard !forceRefresh, teamID == credential.teamID, userID == credential.userID else {
            throw SlackAPIError(.reauthorizationRequired)
        }
        return credential.accessToken
    }
}

private struct SlackDirectIdentityValidator: SlackControllerIdentityValidating {
    func validate(
        credential: SlackOAuthCredential,
        provisionalConnection: SlackWorkspaceConnection,
        trace: SlackTraceContext
    ) async throws -> SlackAuthenticatedIdentity {
        let client = SlackAPIClient(tokenProvider: SlackOneShotAccessTokenProvider(credential: credential))
        return try await client.testAuthentication(connection: provisionalConnection, trace: trace).value
    }
}

@MainActor
final class SlackAppController: ObservableObject {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private enum UpdateBlockingMutationKind {
        case cancellableAuthorization
        case persistenceOrCallback
    }

    @Published private(set) var availability: SlackConnectorAvailability
    @Published private(set) var workspaces: [SlackWorkspaceConnection] = []
    @Published private(set) var enabledWorkspaceIDs: Set<String> = []
    @Published private(set) var conversationsByWorkspace: [String: [SlackConversationChoice]] = [:]
    @Published private(set) var workspaceStatusDetails: [String: SlackWorkspaceStatusDetail] = [:]
    @Published private(set) var workspaceOperations: [String: SlackConnectorOperation] = [:]
    @Published private(set) var authorizationOperation: SlackConnectorOperation = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastDisconnectResult: SlackDisconnectResult?
    @Published private(set) var wholeAppDeletionInProgress = false
    @Published private(set) var updateInstallationInProgress = false

    var hasUpdateBlockingWork: Bool {
        wholeAppDeletionInProgress
            || updateInstallationInProgress
            || !activeUpdateBlockingMutationTokens.isEmpty
            || !isTerminal(authorizationOperation)
            || workspaceOperations.values.contains(where: { !isTerminal($0) })
    }

    private var operationBarrierActive: Bool {
        wholeAppDeletionInProgress || updateInstallationInProgress
    }

    let clientIDIsConfigured: Bool
    var onBriefingEvidenceChanged: (@MainActor @Sendable ([String]) async -> Void)?
    var onSlackEvidenceDeletionWillBegin:
        (@MainActor @Sendable (_ workspaceID: String, _ channelID: String?) async -> Void)?
    var onSlackEvidenceDeletionCompleted:
        (@MainActor @Sendable (_ workspaceID: String, _ channelID: String?) async -> Void)?

    private let store: LocalStore
    private let credentialStore: any SlackCredentialStoring
    private let authorizer: (any SlackControllerAuthorizing)?
    private let identityValidator: any SlackControllerIdentityValidating
    private let apiClient: (any SlackControllerAPIServicing)?
    private let backfillHistoryClient: (any SlackBackfillHistoryFetching)?
    private let syncCoordinator: (any SlackControllerSyncing)?
    private let refreshCoordinator: SlackCredentialRefreshCoordinator?
    private let rateLimitRelay: SlackControllerRateLimitRelay?
    private let tokenRevoker: any SlackTokenRevoking
    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?
    private var authorizationEpoch: UInt64 = 0
    private var workspaceEpochs: [String: UInt64] = [:]
    private var preRateLimitOperations: [String: SlackConnectorOperation] = [:]
    private var preRateLimitConnectionStates: [String: SlackConnectionState] = [:]
    private var activeUpdateBlockingMutationTokens: [UUID: UpdateBlockingMutationKind] = [:]

    init(
        store: LocalStore,
        clientID: String? = SlackAppController.configuredClientID(),
        credentialStore injectedCredentialStore: (any SlackCredentialStoring)? = nil,
        authorizer injectedAuthorizer: (any SlackControllerAuthorizing)? = nil,
        identityValidator: any SlackControllerIdentityValidating = SlackDirectIdentityValidator(),
        apiClient injectedAPIClient: (any SlackControllerAPIServicing)? = nil,
        syncCoordinator injectedSyncCoordinator: (any SlackControllerSyncing)? = nil,
        tokenRevoker: any SlackTokenRevoking = SlackRevocationClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: TraceSink? = nil
    ) {
        let credentialStore = injectedCredentialStore ?? SecuritySlackCredentialStore(eventSink: eventSink)
        self.store = store
        self.credentialStore = credentialStore
        self.identityValidator = identityValidator
        self.tokenRevoker = tokenRevoker
        self.now = now
        self.eventSink = eventSink

        let normalizedClientID = Self.normalizedClientID(clientID)
        self.clientIDIsConfigured = normalizedClientID != nil
        self.availability = normalizedClientID == nil ? .configurationRequired : .disconnected

        if let normalizedClientID, let oauthClient = try? SlackOAuthClient(clientID: normalizedClientID, eventSink: eventSink) {
            self.authorizer = injectedAuthorizer ?? SlackAuthorizationService(
                browser: SystemSlackWebAuthenticationSession(),
                oauthClient: oauthClient,
                eventSink: eventSink
            )
            let refreshCoordinator = SlackCredentialRefreshCoordinator(
                oauthClient: oauthClient,
                credentialStore: credentialStore,
                eventSink: eventSink
            )
            let rateLimitRelay = SlackControllerRateLimitRelay()
            self.refreshCoordinator = refreshCoordinator
            self.rateLimitRelay = rateLimitRelay
            let defaultAPIClient = SlackAPIClient(
                tokenProvider: SlackCredentialAccessTokenProvider(coordinator: refreshCoordinator),
                eventSink: eventSink,
                rateLimitSink: { [weak rateLimitRelay] workspaceID, state in
                    rateLimitRelay?.receive(workspaceID: workspaceID, state: state)
                }
            )
            let configuredAPIClient = injectedAPIClient ?? defaultAPIClient
            self.apiClient = configuredAPIClient
            self.backfillHistoryClient = configuredAPIClient as? any SlackBackfillHistoryFetching
            self.syncCoordinator = injectedSyncCoordinator ?? SlackSyncCoordinator(
                client: defaultAPIClient,
                eventSink: eventSink
            )
        } else {
            self.authorizer = nil
            self.apiClient = nil
            self.backfillHistoryClient = nil
            self.syncCoordinator = nil
            self.refreshCoordinator = nil
            self.rateLimitRelay = nil
        }

        rateLimitRelay?.bind(self)
        reloadLocalState(reportFailure: true)
    }

    func prepareForUpdateInstallation() -> Bool {
        guard !wholeAppDeletionInProgress, !updateInstallationInProgress else { return false }
        guard activeUpdateBlockingMutationTokens.isEmpty else { return false }
        guard isTerminal(authorizationOperation), workspaceOperations.values.allSatisfy({ isTerminal($0) }) else {
            return false
        }
        updateInstallationInProgress = true
        do {
            try store.save()
            return true
        } catch {
            updateInstallationInProgress = false
            errorMessage = "Update installation is blocked because Slack control state could not be saved."
            return false
        }
    }

    func resumeAfterUpdateInstallationAbort() {
        updateInstallationInProgress = false
        statusMessage = "Update installation stopped; Slack controls are available again."
    }

    func makeVaultBackfillAdapter(
        workspaceID: String,
        traceSink: SlackVaultBackfillAdapter.TraceSink? = nil
    ) throws -> SlackVaultBackfillAdapter? {
        guard let backfillHistoryClient,
              let connection = workspace(id: workspaceID),
              isWorkspaceEnabled(workspaceID)
        else { return nil }
        let selections = try store.domainSlackSelections(workspaceID: workspaceID).filter(\.enabled)
        guard !selections.isEmpty else { return nil }
        return SlackVaultBackfillAdapter(
            historyClient: backfillHistoryClient,
            connection: connection,
            selections: selections,
            traceSink: traceSink
        )
    }

    func vaultBackfillSources(workspaceID: String) throws -> [VaultBackfillSourceCheckpoint] {
        guard workspace(id: workspaceID) != nil, isWorkspaceEnabled(workspaceID) else { return [] }
        return try store.domainSlackSelections(workspaceID: workspaceID)
            .filter { $0.enabled && ($0.kind == .publicChannel || $0.kind == .privateChannel) && !$0.channelID.hasPrefix("D") }
            .sorted {
                if $0.selectedAt != $1.selectedAt { return $0.selectedAt < $1.selectedAt }
                return $0.channelID < $1.channelID
            }
            .map { selection in
                let forward = try store.domainSlackCursor(
                    workspaceID: workspaceID,
                    conversationID: selection.channelID
                )
                return VaultBackfillSourceCheckpoint(
                    id: "\(workspaceID):\(selection.channelID)",
                    accountID: workspaceID,
                    sourceID: selection.channelID,
                    forwardCursor: forward?.nextCursor,
                    historyCursor: nil,
                    historyUpperBound: forward?.committedOldest?.date,
                    isHistoryComplete: false,
                    failureReasonCode: nil
                )
            }
    }

    nonisolated static func configuredClientID(bundle: Bundle = .main) -> String? {
        normalizedClientID(bundle.object(forInfoDictionaryKey: "LOKI_SLACK_CLIENT_ID") as? String)
    }

    nonisolated static func normalizedClientID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              !trimmed.contains("${"),
              (try? SlackOAuthClient(clientID: trimmed)) != nil
        else { return nil }
        return trimmed
    }

    func choices(
        workspaceID: String,
        search: String = "",
        filter: SlackChannelFilter = .all
    ) -> [SlackConversationChoice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (conversationsByWorkspace[workspaceID] ?? []).filter { choice in
            let matchesQuery = query.isEmpty || choice.displayName.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .selected: matchesFilter = choice.isSelected
            case .publicChannels: matchesFilter = choice.kind == .publicChannel
            case .privateChannels: matchesFilter = choice.kind == .privateChannel
            case .member: matchesFilter = choice.isMember
            }
            return matchesQuery && matchesFilter
        }
    }

    func selectedChannelCount(workspaceID: String) -> Int {
        (conversationsByWorkspace[workspaceID] ?? []).filter(\.isSelected).count
    }

    func isWorkspaceEnabled(_ workspaceID: String) -> Bool {
        enabledWorkspaceIDs.contains(workspaceID)
    }

    @discardableResult
    func connect(
        prefersEphemeralSession: Bool = false,
        expectedWorkspaceID: String? = nil
    ) async -> Bool {
        guard let mutationToken = beginUpdateBlockingMutation(kind: .cancellableAuthorization) else { return false }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard let authorizer else {
            availability = .configurationRequired
            authorizationOperation = .failed(reasonCode: SlackConnectionFailureCode.configurationRequired.rawValue)
            errorMessage = "Slack configuration required"
            return false
        }
        guard authorizationOperation == .idle || isTerminal(authorizationOperation) else { return false }

        authorizationEpoch &+= 1
        let epoch = authorizationEpoch
        let trace = SlackTraceContext()
        authorizationOperation = .authorizing
        errorMessage = nil
        statusMessage = "Waiting for Slack authorization."
        emit(.authorization, trace: trace, status: .started, reason: "slack_authorization_started")

        var credentialStored = false
        var credential: SlackOAuthCredential?
        do {
            let exchanged = try await authorizer.authorize(prefersEphemeralSession: prefersEphemeralSession)
            credential = exchanged
            try requireCurrentAuthorization(epoch)
            authorizationOperation = .validatingIdentity
            statusMessage = "Validating the Slack workspace identity."

            let provisional = provisionalConnection(for: exchanged, at: now())
            let identity = try await identityValidator.validate(
                credential: exchanged,
                provisionalConnection: provisional,
                trace: trace.child()
            )
            try requireCurrentAuthorization(epoch)
            guard identity.teamID == exchanged.teamID, identity.userID == exchanged.userID else {
                throw SlackAPIError(.invalidSchema)
            }
            let connectedWorkspaceID = SlackWorkspaceConnection.stableID(teamID: identity.teamID, userID: identity.userID)
            if let expectedWorkspaceID, connectedWorkspaceID != expectedWorkspaceID {
                throw SlackConnectionFailureCode.identityMismatch
            }

            do {
                try await credentialStore.create(exchanged)
            } catch let failure as SlackCredentialStoreFailure where failure.code == .alreadyExists {
                try await credentialStore.replace(exchanged)
            }
            credentialStored = true
            try requireCurrentAuthorization(epoch)
            await refreshCoordinator?.allowRefresh(
                teamID: exchanged.teamID,
                userID: exchanged.userID,
                trace: trace.child()
            )
            emit(
                .keychainOperation,
                trace: trace.child(),
                status: .success,
                reason: "slack_keychain_credential_saved",
                metadata: workspaceMetadata(exchanged.accountIdentifier)
            )
            try requireCurrentAuthorization(epoch)

            let connectedAt = now()
            let scopes = Set(exchanged.grantedScopes.compactMap(SlackGrantedScope.init(rawValue:)))
            let connection = SlackWorkspaceConnection(
                id: SlackWorkspaceConnection.stableID(teamID: identity.teamID, userID: identity.userID),
                teamID: identity.teamID,
                teamName: identity.teamName,
                userID: identity.userID,
                userDisplayName: identity.userName,
                state: .connected,
                grantedScopes: scopes,
                credentialMetadata: .init(
                    tokenType: exchanged.tokenType,
                    issuedAt: exchanged.issuedAt,
                    accessExpiration: exchanged.accessTokenExpiresAt,
                    grantedScopes: scopes,
                    schemaVersion: exchanged.schemaVersion
                ),
                localModelConsent: false,
                connectedAt: connectedAt,
                updatedAt: connectedAt,
                lastFailureReasonCode: nil
            )
            try store.persistSlackWorkspace(connection, enabled: true)
            reloadLocalState(reportFailure: false)
            authorizationOperation = .idle
            statusMessage = "Slack workspace connected. Choose channels before refreshing."
            emit(
                .authorization,
                trace: trace,
                status: .success,
                reason: "slack_authorization_completed",
                metadata: workspaceMetadata(connection.id)
            )
            return true
        } catch {
            if credentialStored, let credential {
                try? await credentialStore.delete(teamID: credential.teamID, userID: credential.userID)
            }
            guard epoch == authorizationEpoch else { return false }
            let reason = reasonCode(for: error)
            let cancelled = isCancellation(error)
            authorizationOperation = cancelled ? .idle : .failed(reasonCode: reason)
            statusMessage = cancelled ? "Slack authorization cancelled." : nil
            errorMessage = cancelled ? nil : userMessage(for: error)
            emit(
                .authorization,
                trace: trace,
                status: cancelled ? .skipped : .failed,
                reason: reason
            )
            return false
        }
    }

    @discardableResult
    func reauthorize(workspaceID: String) async -> Bool {
        guard workspace(id: workspaceID) != nil else { return false }
        return await connect(expectedWorkspaceID: workspaceID)
    }

    func cancelAuthorization() async {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        authorizationEpoch &+= 1
        authorizationOperation = .cancelling
        await authorizer?.cancelActiveAuthorization()
        authorizationOperation = .idle
        errorMessage = nil
        statusMessage = "Slack authorization cancelled."
        emit(.cancellation, trace: .init(), status: .success, reason: "slack_authorization_cancellation_requested")
    }

    @discardableResult
    func discoverChannels(workspaceID: String) async -> Bool {
        guard let mutationToken = beginUpdateBlockingMutation() else { return false }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard let apiClient, let connection = workspace(id: workspaceID), isWorkspaceEnabled(workspaceID) else {
            setWorkspaceFailure(workspaceID, reason: SlackAPIErrorCode.invalidRequest.rawValue, message: "Enable this Slack workspace before discovering channels.")
            return false
        }
        guard workspaceOperationIsIdle(workspaceID) else { return false }

        let epoch = nextWorkspaceEpoch(workspaceID)
        let trace = SlackTraceContext()
        workspaceOperations[workspaceID] = .discoveringChannels
        errorMessage = nil
        do {
            let result = try await apiClient.discoverConversations(connection: connection, trace: trace)
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            try store.persistDiscoveredSlackConversations(result.value, workspaceID: workspaceID)
            try await reconcileCredentialMetadata(workspaceID: workspaceID)
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            reloadLocalState(reportFailure: false)
            workspaceOperations[workspaceID] = .idle
            statusMessage = result.value.isEmpty
                ? "Slack returned no accessible channels."
                : "Found \(result.value.count) accessible Slack channels."
            return true
        } catch {
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return false }
            try? await reconcileCredentialMetadata(workspaceID: workspaceID)
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return false }
            reloadLocalState(reportFailure: false)
            handleWorkspaceFailure(error, workspaceID: workspaceID)
            return false
        }
    }

    func setChannelSelected(
        workspaceID: String,
        channelID: String,
        selected: Bool
    ) async {
        guard !operationBarrierActive else { return }
        if !selected { invalidateWorkspaceOperationForSelectionChange(workspaceID: workspaceID) }
        if !selected {
            await onSlackEvidenceDeletionWillBegin?(workspaceID, channelID)
        }
        do {
            try store.setSlackConversationSelected(id: "\(workspaceID):\(channelID)", selected: selected)
            reloadLocalState(reportFailure: false)
            statusMessage = selected ? "Slack channel selected." : "Slack channel removed from refresh."
            errorMessage = nil
            notifyBriefingEvidenceChanged()
        } catch {
            errorMessage = userMessage(for: error)
        }
        if !selected {
            await onSlackEvidenceDeletionCompleted?(workspaceID, channelID)
        }
    }

    func setChannelEnabled(
        workspaceID: String,
        channelID: String,
        enabled: Bool
    ) async {
        guard !operationBarrierActive else { return }
        if !enabled { invalidateWorkspaceOperationForSelectionChange(workspaceID: workspaceID) }
        do {
            try store.setSlackConversationEnabled(id: "\(workspaceID):\(channelID)", enabled: enabled)
            reloadLocalState(reportFailure: false)
            statusMessage = enabled
                ? "Slack channel enabled for manual refresh."
                : "Slack channel disabled. Its retained local evidence remains available until deletion."
            errorMessage = nil
            notifyBriefingEvidenceChanged()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func setChannelWeight(workspaceID: String, channelID: String, weight: Double) {
        guard !operationBarrierActive else { return }
        do {
            try store.setSlackConversationWeight(id: "\(workspaceID):\(channelID)", weight: weight)
            reloadLocalState(reportFailure: false)
            errorMessage = nil
            notifyBriefingEvidenceChanged()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func setLocalModelConsent(workspaceID: String, enabled: Bool) async {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        let trace = SlackTraceContext()
        if !enabled {
            await onSlackEvidenceDeletionWillBegin?(workspaceID, nil)
        }
        do {
            try store.setSlackLocalModelConsent(workspaceID: workspaceID, enabled: enabled)
            reloadLocalState(reportFailure: false)
            statusMessage = enabled
                ? "Slack evidence from this workspace may be sent only to the selected local Ollama model."
                : "Slack evidence from this workspace remains excluded from local-model prompts."
            errorMessage = nil
            emit(
                .localModelConsent,
                trace: trace,
                status: .success,
                reason: enabled ? "slack_local_model_consent_enabled" : "slack_local_model_consent_disabled",
                metadata: workspaceMetadata(workspaceID)
            )
            await onBriefingEvidenceChanged?([])
        } catch {
            errorMessage = userMessage(for: error)
            emit(.localModelConsent, trace: trace, status: .failed, reason: reasonCode(for: error), metadata: workspaceMetadata(workspaceID))
        }
        if !enabled {
            await onSlackEvidenceDeletionCompleted?(workspaceID, nil)
        }
    }

    @discardableResult
    func syncSelectedChannels(
        workspaceID: String,
        notifyBriefingEvidenceChanged: Bool = true,
        scheduledBudget: ScheduledBriefingBudgetLedger? = nil,
        scheduledSelections: [SlackConversationSelection]? = nil,
        trace: SlackTraceContext? = nil
    ) async -> Bool {
        guard let mutationToken = beginUpdateBlockingMutation() else { return false }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard let syncCoordinator, let connection = workspace(id: workspaceID), isWorkspaceEnabled(workspaceID) else {
            setWorkspaceFailure(workspaceID, reason: SlackAPIErrorCode.invalidRequest.rawValue, message: "Enable this Slack workspace before refreshing selected channels.")
            return false
        }
        guard workspaceOperationIsIdle(workspaceID) else { return false }

        let epoch = nextWorkspaceEpoch(workspaceID)
        let operationTrace = trace ?? SlackTraceContext()
        do {
            let currentlyEnabled = try store.domainSlackSelections(workspaceID: workspaceID).filter(\.enabled)
            let selections: [SlackConversationSelection]
            if let scheduledSelections {
                let currentlyEnabledIDs = Set(currentlyEnabled.map(\.channelID))
                selections = scheduledSelections.filter { currentlyEnabledIDs.contains($0.channelID) }
            } else {
                selections = currentlyEnabled
            }
            guard !selections.isEmpty else {
                throw SlackAPIError(.invalidRequest)
            }
            let cursors = try selections.compactMap {
                try store.domainSlackCursor(workspaceID: workspaceID, conversationID: $0.channelID)
            }
            workspaceOperations[workspaceID] = .syncingChannels(completed: 0, total: selections.count)
            errorMessage = nil
            let controller = self

            let output = try await syncCoordinator.syncSelectedChannels(
                connection: connection,
                selections: selections,
                cursors: cursors,
                trace: operationTrace,
                scheduledBudget: scheduledBudget,
                progress: { progress in
                    await controller.recordSyncProgress(progress, workspaceID: workspaceID, epoch: epoch)
                }
            )
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            try persist(output: output, workspaceID: workspaceID)
            try await reconcileCredentialMetadata(workspaceID: workspaceID)
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            reloadLocalState(reportFailure: false)
            let scheduledBudgetFailure = output.run.channelResults
                .compactMap(\.failureReasonCode)
                .first(where: { Self.isScheduledBudgetFailureReason($0) })
            if let budgetFailure = scheduledBudgetFailure {
                workspaceOperations[workspaceID] = .failed(reasonCode: budgetFailure)
            } else {
                workspaceOperations[workspaceID] = .idle
            }
            statusMessage = syncMessage(for: output.run)
            if notifyBriefingEvidenceChanged, output.run.state == .completed || output.run.state == .partial {
                await onBriefingEvidenceChanged?(boundedReasonCodes(
                    output.run.channelResults.compactMap(\.failureReasonCode)
                ))
            }
            return scheduledBudgetFailure == nil
                && (output.run.state == .completed || output.run.state == .partial)
        } catch {
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return false }
            try? await reconcileCredentialMetadata(workspaceID: workspaceID)
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return false }
            reloadLocalState(reportFailure: false)
            handleWorkspaceFailure(error, workspaceID: workspaceID)
            return false
        }
    }

    func cancelWorkspaceOperation(workspaceID: String) async {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        _ = nextWorkspaceEpoch(workspaceID)
        workspaceOperations[workspaceID] = .cancelling
        preRateLimitOperations[workspaceID] = nil
        preRateLimitConnectionStates[workspaceID] = nil
        await apiClient?.cancelAll()
        await syncCoordinator?.cancelAll(trace: .init())
        workspaceOperations[workspaceID] = .idle
        errorMessage = nil
        statusMessage = "Slack operation cancelled."
        emit(.cancellation, trace: .init(), status: .success, reason: "slack_workspace_operation_cancellation_requested", metadata: workspaceMetadata(workspaceID))
    }

    func disableWorkspace(workspaceID: String) async {
        guard let mutationToken = beginUpdateBlockingMutation() else { return }
        defer { finishUpdateBlockingMutation(mutationToken) }
        await cancelWorkspaceOperation(workspaceID: workspaceID)
        do {
            try store.setSlackWorkspaceEnabled(id: workspaceID, enabled: false, stateRaw: SlackConnectionState.disconnected.rawValue)
            reloadLocalState(reportFailure: false)
            statusMessage = "Slack workspace disabled. Stored evidence remains local until deletion."
            errorMessage = nil
            await onBriefingEvidenceChanged?([])
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    @discardableResult
    func deleteLocalData(workspaceID: String) async -> Bool {
        guard let mutationToken = beginUpdateBlockingMutation() else { return false }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard workspace(id: workspaceID) != nil else { return false }
        await onSlackEvidenceDeletionWillBegin?(workspaceID, nil)
        await cancelWorkspaceOperation(workspaceID: workspaceID)
        workspaceOperations[workspaceID] = .disconnecting
        do {
            try store.deleteSlackWorkspaceContent(workspaceID: workspaceID)
            await syncCoordinator?.controllerClearWorkspaceCaches(workspaceID: workspaceID)
            reloadLocalState(reportFailure: false)
            workspaceOperations[workspaceID] = .idle
            statusMessage = "Deleted retained Slack evidence, channel selections, cursors, and Slack-derived brief items. The workspace authorization remains connected."
            errorMessage = nil
            await onBriefingEvidenceChanged?([])
            await onSlackEvidenceDeletionCompleted?(workspaceID, nil)
            return true
        } catch {
            workspaceOperations[workspaceID] = .failed(reasonCode: reasonCode(for: error))
            errorMessage = userMessage(for: error)
            await onSlackEvidenceDeletionCompleted?(workspaceID, nil)
            return false
        }
    }

    @discardableResult
    func enableWorkspace(workspaceID: String) async -> Bool {
        guard let mutationToken = beginUpdateBlockingMutation() else { return false }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard let connection = workspace(id: workspaceID), clientIDIsConfigured else { return false }
        let epoch = nextWorkspaceEpoch(workspaceID)
        workspaceOperations[workspaceID] = .validatingIdentity
        do {
            _ = try await credentialStore.read(teamID: connection.teamID, userID: connection.userID)
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            try store.setSlackWorkspaceEnabled(id: workspaceID, enabled: true, stateRaw: SlackConnectionState.connected.rawValue)
            reloadLocalState(reportFailure: false)
            workspaceOperations[workspaceID] = .idle
            statusMessage = "Slack workspace enabled."
            errorMessage = nil
            await onBriefingEvidenceChanged?([])
            return true
        } catch {
            handleWorkspaceFailure(error, workspaceID: workspaceID)
            return false
        }
    }

    @discardableResult
    func disconnect(workspaceID: String, revokeRemotely: Bool = true) async -> SlackDisconnectResult {
        guard let mutationToken = beginUpdateBlockingMutation() else {
            return .init(
                workspaceID: workspaceID,
                localDataDeleted: false,
                localDataPreserved: true,
                connectorDisabled: false,
                credentialDeleted: false,
                remoteRevocationAttempted: false,
                remoteRevocationConfirmed: false,
                reasonCode: operationBarrierReasonCode
            )
        }
        defer { finishUpdateBlockingMutation(mutationToken) }
        let trace = SlackTraceContext()
        emit(.disconnect, trace: trace, status: .started, reason: "slack_disconnect_started", metadata: workspaceMetadata(workspaceID))
        authorizationEpoch &+= 1
        await authorizer?.cancelActiveAuthorization()
        await cancelWorkspaceOperation(workspaceID: workspaceID)
        workspaceOperations[workspaceID] = .disconnecting

        guard let connection = workspace(id: workspaceID) else {
            let result = SlackDisconnectResult(
                workspaceID: workspaceID,
                localDataDeleted: false,
                localDataPreserved: false,
                connectorDisabled: false,
                credentialDeleted: false,
                remoteRevocationAttempted: false,
                remoteRevocationConfirmed: false,
                reasonCode: "slack_disconnect_workspace_not_found"
            )
            lastDisconnectResult = result
            workspaceOperations[workspaceID] = .failed(reasonCode: result.reasonCode)
            return result
        }

        await refreshCoordinator?.cancelRefresh(
            teamID: connection.teamID,
            userID: connection.userID,
            trace: trace.child()
        )
        let credential = try? await credentialStore.read(teamID: connection.teamID, userID: connection.userID)
        let remoteAttempted = revokeRemotely && credential != nil
        let remoteConfirmed: Bool
        if revokeRemotely, let credential {
            remoteConfirmed = (try? await tokenRevoker.revoke(accessToken: credential.accessToken))?.remoteConfirmed == true
        } else {
            remoteConfirmed = false
        }

        let credentialDeleted: Bool
        do {
            try await credentialStore.delete(teamID: connection.teamID, userID: connection.userID)
            credentialDeleted = true
            emit(.keychainOperation, trace: trace.child(), status: .success, reason: "slack_keychain_credential_deleted", metadata: workspaceMetadata(workspaceID))
        } catch let failure as SlackCredentialStoreFailure where failure.code == .notFound {
            credentialDeleted = true
            emit(.keychainOperation, trace: trace.child(), status: .skipped, reason: failure.reasonCode, metadata: workspaceMetadata(workspaceID))
        } catch {
            credentialDeleted = false
            emit(.keychainOperation, trace: trace.child(), status: .failed, reason: reasonCode(for: error), metadata: workspaceMetadata(workspaceID))
        }

        let connectorDisabled: Bool
        if credentialDeleted {
            // Revoking source authorization must drain active local generation
            // and scrub derived chat/index evidence even though the underlying
            // imported Slack archive is deliberately preserved.
            await onSlackEvidenceDeletionWillBegin?(workspaceID, nil)
            do {
                try store.setSlackWorkspaceEnabled(
                    id: workspaceID,
                    enabled: false,
                    stateRaw: SlackConnectionState.disconnected.rawValue
                )
                connectorDisabled = true
            } catch {
                connectorDisabled = false
            }
        } else {
            // Preserve the nonsecret workspace record so a failed Keychain
            // deletion can be retried without losing its archive association.
            connectorDisabled = false
        }
        reloadLocalState(reportFailure: false)
        if credentialDeleted {
            await onSlackEvidenceDeletionCompleted?(workspaceID, nil)
        }
        if connectorDisabled { await onBriefingEvidenceChanged?([]) }

        let reason: String
        if connectorDisabled && credentialDeleted && (!remoteAttempted || remoteConfirmed) {
            reason = "slack_disconnect_completed_local_data_preserved"
        } else if connectorDisabled && credentialDeleted {
            reason = "slack_disconnect_completed_local_data_preserved_remote_revoke_unconfirmed"
        } else {
            reason = "slack_disconnect_credential_or_state_cleanup_incomplete"
        }
        let result = SlackDisconnectResult(
            workspaceID: workspaceID,
            localDataDeleted: false,
            localDataPreserved: true,
            connectorDisabled: connectorDisabled,
            credentialDeleted: credentialDeleted,
            remoteRevocationAttempted: remoteAttempted,
            remoteRevocationConfirmed: remoteConfirmed,
            reasonCode: reason
        )
        lastDisconnectResult = result
        workspaceOperations[workspaceID] = connectorDisabled && credentialDeleted ? .idle : .failed(reasonCode: reason)
        statusMessage = connectorDisabled && credentialDeleted
            ? (remoteAttempted && !remoteConfirmed
                ? "Slack disconnected locally and retained data was preserved; remote revocation could not be confirmed."
                : "Slack disconnected. Its Keychain credential was removed and retained local data was preserved.")
            : nil
        errorMessage = connectorDisabled && credentialDeleted
            ? nil
            : "Slack credential or connection-state cleanup was incomplete. Retry disconnect before reconnecting."
        emit(
            .disconnect,
            trace: trace,
            status: connectorDisabled && credentialDeleted ? (remoteAttempted && !remoteConfirmed ? .degraded : .success) : .failed,
            reason: reason,
            metadata: workspaceMetadata(workspaceID)
        )
        return result
    }

    func resolvePermalink(evidenceID: String) async -> URL? {
        guard let mutationToken = beginUpdateBlockingMutation() else { return nil }
        defer { finishUpdateBlockingMutation(mutationToken) }
        guard let syncCoordinator,
              let evidence = try? store.domainSlackEvidence().first(where: { $0.id == evidenceID }),
              let connection = workspace(id: evidence.workspaceID),
              isWorkspaceEnabled(evidence.workspaceID)
        else { return nil }
        let workspaceID = evidence.workspaceID
        let epoch = workspaceEpochs[workspaceID] ?? 0
        do {
            let resolved = try await syncCoordinator.resolvePermalink(
                for: evidence,
                connection: connection,
                trace: .init()
            )
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            try store.persistSlackEvidence(resolved)
            try await reconcileCredentialMetadata(workspaceID: workspaceID)
            try requireCurrentWorkspace(workspaceID, epoch: epoch)
            reloadLocalState(reportFailure: false)
            return resolved.permalink
        } catch {
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return nil }
            try? await reconcileCredentialMetadata(workspaceID: workspaceID)
            guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return nil }
            reloadLocalState(reportFailure: false)
            handleWorkspaceFailure(error, workspaceID: workspaceID)
            return nil
        }
    }

    @discardableResult
    func prepareForWholeAppDataDeletion() async -> Bool {
        guard !operationBarrierActive else { return false }
        guard activeUpdateBlockingMutationTokens.values.allSatisfy({ $0 == .cancellableAuthorization }) else {
            return false
        }
        wholeAppDeletionInProgress = true
        authorizationEpoch &+= 1
        for workspaceID in workspaces.map(\.id) { _ = nextWorkspaceEpoch(workspaceID) }
        authorizationOperation = .cancelling
        await authorizer?.cancelActiveAuthorization()
        await refreshCoordinator?.cancelAllRefreshes(trace: .init())
        await apiClient?.cancelAll()
        await syncCoordinator?.cancelAll(trace: .init())
        preRateLimitOperations.removeAll()
        preRateLimitConnectionStates.removeAll()

        let capturedWorkspaces = workspaces
        var credentialDeletionFailed = false
        for workspace in capturedWorkspaces {
            do {
                try await credentialStore.delete(teamID: workspace.teamID, userID: workspace.userID)
                emit(
                    .keychainOperation,
                    trace: .init(),
                    status: .success,
                    reason: "slack_keychain_credential_deleted_for_whole_app_reset",
                    metadata: workspaceMetadata(workspace.id)
                )
            } catch let failure as SlackCredentialStoreFailure where failure.code == .notFound {
                emit(
                    .keychainOperation,
                    trace: .init(),
                    status: .skipped,
                    reason: failure.reasonCode,
                    metadata: workspaceMetadata(workspace.id)
                )
            } catch {
                credentialDeletionFailed = true
                emit(
                    .keychainOperation,
                    trace: .init(),
                    status: .failed,
                    reason: reasonCode(for: error),
                    metadata: workspaceMetadata(workspace.id)
                )
            }
            await syncCoordinator?.controllerClearWorkspaceCaches(workspaceID: workspace.id)
        }
        authorizationOperation = .idle
        workspaceOperations = [:]
        preRateLimitOperations.removeAll()
        preRateLimitConnectionStates.removeAll()
        if credentialDeletionFailed {
            errorMessage = "Loki Brief could not delete every Slack credential. Local workspace metadata was preserved so deletion can be retried safely."
            return false
        }
        errorMessage = nil
        return true
    }

    func resumeAfterWholeAppDataDeletionAbort() async {
        guard wholeAppDeletionInProgress else { return }
        for workspace in workspaces {
            await refreshCoordinator?.allowRefresh(
                teamID: workspace.teamID,
                userID: workspace.userID,
                trace: .init()
            )
        }
        authorizationOperation = .idle
        workspaceOperations = [:]
        wholeAppDeletionInProgress = false
    }

    func reloadAfterWholeAppDataDeletion() {
        authorizationEpoch &+= 1
        for workspaceID in workspaces.map(\.id) { _ = nextWorkspaceEpoch(workspaceID) }
        authorizationOperation = .idle
        workspaceOperations = [:]
        lastDisconnectResult = nil
        statusMessage = nil
        errorMessage = nil
        reloadLocalState(reportFailure: true)
        wholeAppDeletionInProgress = false
    }

    func clearMessage() {
        statusMessage = nil
        errorMessage = nil
    }

    private func provisionalConnection(for credential: SlackOAuthCredential, at date: Date) -> SlackWorkspaceConnection {
        let scopes = Set(credential.grantedScopes.compactMap(SlackGrantedScope.init(rawValue:)))
        return SlackWorkspaceConnection(
            id: SlackWorkspaceConnection.stableID(teamID: credential.teamID, userID: credential.userID),
            teamID: credential.teamID,
            teamName: "Slack Workspace",
            userID: credential.userID,
            userDisplayName: "Slack user",
            state: .validating,
            grantedScopes: scopes,
            credentialMetadata: nil,
            localModelConsent: false,
            connectedAt: date,
            updatedAt: date,
            lastFailureReasonCode: nil
        )
    }

    private func reloadLocalState(reportFailure: Bool) {
        do {
            let storedWorkspaces = try store.slackWorkspaceConnections()
            workspaces = try store.domainSlackWorkspaces()
            enabledWorkspaceIDs = Set(storedWorkspaces.filter(\.enabled).map(\.id))
            conversationsByWorkspace = try Dictionary(uniqueKeysWithValues: storedWorkspaces.map { workspace in
                let values = try store.slackConversationSelections(workspaceID: workspace.id).map { stored in
                    SlackConversationChoice(
                        workspaceID: stored.workspaceID,
                        channelID: stored.conversationID,
                        displayName: stored.displayName,
                        kind: SlackConversationKind(rawValue: stored.kindRaw) ?? .publicChannel,
                        isMember: stored.isMember,
                        isSelected: stored.selected,
                        isEnabled: stored.enabled,
                        weight: stored.weight,
                        lastSuccessfulRefreshAt: stored.lastSuccessfulRefresh,
                        lastFailureReasonCode: stored.lastFailureCode
                    )
                }
                return (workspace.id, values)
            })
            workspaceStatusDetails = Dictionary(uniqueKeysWithValues: storedWorkspaces.map { workspace in
                (
                    workspace.id,
                    SlackWorkspaceStatusDetail(
                        accessTokenExpiresAt: workspace.accessExpiresAt,
                        lastSuccessfulRefreshAt: workspace.lastSuccessfulRefresh,
                        lastFailureReasonCode: workspace.lastFailureCode,
                        rateLimitedUntil: workspace.rateLimitedUntil
                    )
                )
            })
            availability = !clientIDIsConfigured
                ? .configurationRequired
                : (enabledWorkspaceIDs.isEmpty ? .disconnected : .connected)
        } catch {
            workspaces = []
            enabledWorkspaceIDs = []
            conversationsByWorkspace = [:]
            workspaceStatusDetails = [:]
            availability = clientIDIsConfigured ? .disconnected : .configurationRequired
            if reportFailure { errorMessage = "Stored Slack metadata could not be loaded." }
        }
    }

    private func persist(output: SlackSyncOutput, workspaceID: String) throws {
        for evidence in output.evidenceUpserts { try store.persistSlackEvidence(evidence) }
        for tombstone in output.tombstones { try store.persistSlackEvidence(tombstone) }
        for cursor in output.cursorUpdates { try store.persistSlackCursor(cursor) }
        for result in output.run.channelResults {
            if result.state == .completed {
                try store.pruneSlackEvidence(
                    workspaceID: workspaceID,
                    conversationID: result.channelID,
                    referenceDate: output.run.completedAt
                )
            }
            try store.recordSlackConversationRefresh(
                id: "\(workspaceID):\(result.channelID)",
                successfulAt: result.state == .completed ? output.run.completedAt : nil,
                failureReasonCode: result.failureReasonCode
            )
        }
        for directive in output.directives {
            switch directive.kind {
            case .disableSelection:
                if let channelID = directive.channelID {
                    try store.setSlackConversationSelected(id: "\(workspaceID):\(channelID)", selected: false)
                    try store.setSlackConversationEnabled(id: "\(workspaceID):\(channelID)", enabled: false)
                }
            case .purgeChannelEvidence:
                if let channelID = directive.channelID {
                    for evidence in try store.slackMessageEvidence(workspaceID: workspaceID) where evidence.conversationID == channelID {
                        try store.tombstoneSlackMessage(
                            id: evidence.id,
                            workspaceID: workspaceID,
                            conversationID: channelID,
                            messageTimestamp: evidence.messageTimestamp,
                            reasonCode: directive.reasonCode,
                            at: now()
                        )
                    }
                }
            case .requireReauthorization:
                try updateWorkspaceState(workspaceID: workspaceID, state: .reauthorizationRequired, failureReasonCode: directive.reasonCode)
            case .markWorkspaceUnavailable:
                try updateWorkspaceState(workspaceID: workspaceID, state: .degraded, failureReasonCode: directive.reasonCode)
            }
        }
        try store.persistSlackSyncRun(output.run)
        let hasTerminalWorkspaceDirective = output.directives.contains {
            $0.kind == .requireReauthorization || $0.kind == .markWorkspaceUnavailable
        }
        if !hasTerminalWorkspaceDirective {
            let state: SlackConnectionState
            let failureReasonCode: String?
            let lastSuccessfulRefresh: Date?
            switch output.run.state {
            case .completed:
                state = .connected
                failureReasonCode = nil
                lastSuccessfulRefresh = output.run.completedAt
            case .partial:
                state = .degraded
                failureReasonCode = "slack_sync_partial"
                lastSuccessfulRefresh = output.run.completedAt
            case .failed:
                state = .degraded
                failureReasonCode = "slack_selected_channel_sync_failed"
                lastSuccessfulRefresh = nil
            case .cancelled:
                state = .connected
                failureReasonCode = nil
                lastSuccessfulRefresh = nil
            case .queued, .running, .waitingForRateLimit:
                throw SlackAPIError(.invalidSchema)
            }
            try updateWorkspaceState(
                workspaceID: workspaceID,
                state: state,
                failureReasonCode: failureReasonCode,
                lastSuccessfulRefresh: lastSuccessfulRefresh,
                rateLimitUpdate: .clear
            )
        }
    }

    private func updateWorkspaceState(
        workspaceID: String,
        state: SlackConnectionState,
        failureReasonCode: String?,
        lastSuccessfulRefresh: Date? = nil,
        rateLimitUpdate: SlackRateLimitPersistenceUpdate = .preserve
    ) throws {
        guard var value = try store.domainSlackWorkspaces().first(where: { $0.id == workspaceID }) else {
            throw SlackPersistenceError.invalidWorkspaceIdentifier
        }
        let prior = try store.slackWorkspaceConnection(id: workspaceID)
        value.state = state
        value.lastFailureReasonCode = failureReasonCode
        value.updatedAt = now()
        let rateLimitedUntil: Date?
        switch rateLimitUpdate {
        case .preserve: rateLimitedUntil = prior?.rateLimitedUntil
        case let .set(value): rateLimitedUntil = value
        case .clear: rateLimitedUntil = nil
        }
        try store.persistSlackWorkspace(
            value,
            enabled: prior?.enabled ?? true,
            lastSuccessfulRefresh: lastSuccessfulRefresh ?? prior?.lastSuccessfulRefresh,
            rateLimitedUntil: rateLimitedUntil
        )
    }

    private func reconcileCredentialMetadata(workspaceID: String) async throws {
        guard var connection = try store.domainSlackWorkspaces().first(where: { $0.id == workspaceID }) else {
            throw SlackPersistenceError.invalidWorkspaceIdentifier
        }
        let credential = try await credentialStore.read(teamID: connection.teamID, userID: connection.userID)
        guard credential.teamID == connection.teamID,
              credential.userID == connection.userID,
              credential.isStructurallyValid()
        else { throw SlackAPIError(.reauthorizationRequired) }
        let scopes = Set(credential.grantedScopes.compactMap(SlackGrantedScope.init(rawValue:)))
        connection.grantedScopes = scopes
        connection.credentialMetadata = .init(
            tokenType: credential.tokenType,
            issuedAt: credential.issuedAt,
            accessExpiration: credential.accessTokenExpiresAt,
            grantedScopes: scopes,
            schemaVersion: credential.schemaVersion
        )
        connection.updatedAt = now()
        let prior = try store.slackWorkspaceConnection(id: workspaceID)
        try store.persistSlackWorkspace(
            connection,
            enabled: prior?.enabled ?? true,
            lastSuccessfulRefresh: prior?.lastSuccessfulRefresh,
            rateLimitedUntil: prior?.rateLimitedUntil
        )
    }

    func recordRateLimitUpdate(workspaceID: String, state: SlackRateLimitState?) {
        guard !operationBarrierActive else { return }
        guard workspace(id: workspaceID) != nil else { return }
        do {
            if let state {
                if preRateLimitOperations[workspaceID] == nil {
                    preRateLimitOperations[workspaceID] = workspaceOperations[workspaceID] ?? .idle
                }
                if preRateLimitConnectionStates[workspaceID] == nil {
                    let current = workspace(id: workspaceID)?.state ?? .connected
                    preRateLimitConnectionStates[workspaceID] = current == .rateLimited ? .connected : current
                }
                workspaceOperations[workspaceID] = .waitingForRateLimit(until: state.retryAt)
                try updateWorkspaceState(
                    workspaceID: workspaceID,
                    state: .rateLimited,
                    failureReasonCode: workspace(id: workspaceID)?.lastFailureReasonCode,
                    rateLimitUpdate: .set(state.retryAt)
                )
                statusMessage = "Slack is rate limited. Waiting until \(state.retryAt.formatted(date: .abbreviated, time: .shortened)) before one replay."
            } else {
                let previousOperation = preRateLimitOperations.removeValue(forKey: workspaceID) ?? .idle
                let previousState = preRateLimitConnectionStates.removeValue(forKey: workspaceID) ?? .connected
                if case .waitingForRateLimit = workspaceOperations[workspaceID] {
                    workspaceOperations[workspaceID] = previousOperation
                }
                let currentState = workspace(id: workspaceID)?.state
                let restoredState: SlackConnectionState = currentState == .reauthorizationRequired ? .reauthorizationRequired : previousState
                try updateWorkspaceState(
                    workspaceID: workspaceID,
                    state: restoredState,
                    failureReasonCode: workspace(id: workspaceID)?.lastFailureReasonCode,
                    rateLimitUpdate: .clear
                )
                statusMessage = "Slack rate-limit wait completed; the explicit operation resumed."
            }
            reloadLocalState(reportFailure: false)
        } catch {
            workspaceOperations[workspaceID] = .failed(reasonCode: reasonCode(for: error))
            errorMessage = userMessage(for: error)
        }
    }

    private func workspace(id: String) -> SlackWorkspaceConnection? {
        workspaces.first(where: { $0.id == id })
    }

    private func recordSyncProgress(_ progress: SlackSyncProgress, workspaceID: String, epoch: UInt64) {
        guard isCurrentWorkspace(workspaceID, epoch: epoch) else { return }
        workspaceOperations[workspaceID] = .syncingChannels(
            completed: min(progress.currentChannelIndex, progress.selectedChannelCount),
            total: progress.selectedChannelCount
        )
    }

    private func nextWorkspaceEpoch(_ workspaceID: String) -> UInt64 {
        let value = (workspaceEpochs[workspaceID] ?? 0) &+ 1
        workspaceEpochs[workspaceID] = value
        return value
    }

    private func isCurrentWorkspace(_ workspaceID: String, epoch: UInt64) -> Bool {
        (workspaceEpochs[workspaceID] ?? 0) == epoch && !Task.isCancelled
    }

    private func invalidateWorkspaceOperationForSelectionChange(workspaceID: String) {
        let epoch = nextWorkspaceEpoch(workspaceID)
        guard !workspaceOperationIsIdle(workspaceID) else { return }
        workspaceOperations[workspaceID] = .cancelling
        preRateLimitOperations[workspaceID] = nil
        preRateLimitConnectionStates[workspaceID] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.apiClient?.cancelAll()
            await self.syncCoordinator?.cancelAll(trace: .init())
            guard self.isCurrentWorkspace(workspaceID, epoch: epoch) else { return }
            if self.workspaceOperations[workspaceID] == .cancelling {
                self.workspaceOperations[workspaceID] = .idle
            }
        }
    }

    private func requireCurrentWorkspace(_ workspaceID: String, epoch: UInt64) throws {
        guard isCurrentWorkspace(workspaceID, epoch: epoch) else { throw SlackAPIError(.cancelled) }
    }

    private func requireCurrentAuthorization(_ epoch: UInt64) throws {
        guard epoch == authorizationEpoch, !Task.isCancelled else {
            throw SlackAuthorizationFailure(code: .attemptCancelled)
        }
    }

    private func workspaceOperationIsIdle(_ workspaceID: String) -> Bool {
        guard let operation = workspaceOperations[workspaceID] else { return true }
        return operation == .idle || isTerminal(operation)
    }

    private func beginUpdateBlockingMutation(
        kind: UpdateBlockingMutationKind = .persistenceOrCallback
    ) -> UUID? {
        guard !operationBarrierActive else { return nil }
        let token = UUID()
        activeUpdateBlockingMutationTokens[token] = kind
        return token
    }

    private func finishUpdateBlockingMutation(_ token: UUID) {
        activeUpdateBlockingMutationTokens.removeValue(forKey: token)
        if activeUpdateBlockingMutationTokens.isEmpty, !isTerminal(authorizationOperation) {
            authorizationOperation = .idle
        }
    }

    private var operationBarrierReasonCode: String {
        updateInstallationInProgress
            ? "slack_update_installation_in_progress"
            : "slack_whole_app_deletion_in_progress"
    }

    private func isTerminal(_ operation: SlackConnectorOperation) -> Bool {
        if case .failed = operation { return true }
        return operation == .idle
    }

    private func handleWorkspaceFailure(_ error: Error, workspaceID: String) {
        let reason = reasonCode(for: error)
        if isCancellation(error) {
            workspaceOperations[workspaceID] = .idle
            statusMessage = "Slack operation cancelled."
            errorMessage = nil
        } else {
            if requiresReauthorization(error) {
                try? updateWorkspaceState(
                    workspaceID: workspaceID,
                    state: .reauthorizationRequired,
                    failureReasonCode: reason,
                    rateLimitUpdate: .clear
                )
                reloadLocalState(reportFailure: false)
            }
            workspaceOperations[workspaceID] = .failed(reasonCode: reason)
            errorMessage = userMessage(for: error)
        }
    }

    private func requiresReauthorization(_ error: Error) -> Bool {
        guard let failure = error as? SlackAPIError else { return false }
        return [.invalidAuth, .tokenExpired, .tokenRevoked, .missingScope, .reauthorizationRequired].contains(failure.code)
    }

    private static func isScheduledBudgetFailureReason(_ reasonCode: String) -> Bool {
        [
            SlackAPIErrorCode.scheduledRequestBudgetExhausted.rawValue,
            SlackAPIErrorCode.scheduledRetryBudgetExhausted.rawValue,
            SlackAPIErrorCode.scheduledDurationBudgetExhausted.rawValue,
            SlackAPIErrorCode.scheduledRetryDelayExceedsRemaining.rawValue,
        ].contains(reasonCode)
    }

    private func setWorkspaceFailure(_ workspaceID: String, reason: String, message: String) {
        workspaceOperations[workspaceID] = .failed(reasonCode: reason)
        errorMessage = message
    }

    private func reasonCode(for error: Error) -> String {
        if let value = error as? SlackAPIError { return value.reasonCode }
        if let value = error as? SlackOAuthFailure { return value.reasonCode }
        if let value = error as? SlackAuthorizationFailure { return value.reasonCode }
        if let value = error as? SlackBrowserSessionFailure { return value.reasonCode }
        if let value = error as? SlackCredentialStoreFailure { return value.reasonCode }
        if let value = error as? SlackConnectionFailureCode { return value.rawValue }
        if let value = error as? SlackPersistenceError {
            switch value {
            case .selectionLimitExceeded: return SlackAPIErrorCode.selectionLimitExceeded.rawValue
            case .invalidWorkspaceIdentifier: return "slack_persistence_workspace_invalid"
            case .invalidConversationIdentifier: return "slack_persistence_conversation_invalid"
            case .invalidWeight: return "slack_persistence_weight_invalid"
            case .invalidPermalink: return "slack_persistence_permalink_invalid"
            }
        }
        if error is CancellationError { return SlackAPIErrorCode.cancelled.rawValue }
        return "slack_operation_failed"
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let value = error as? SlackAPIError { return value.code == .cancelled }
        if let value = error as? SlackOAuthFailure { return value.code == .cancelled }
        if let value = error as? SlackAuthorizationFailure { return value.code == .attemptCancelled }
        if let value = error as? SlackBrowserSessionFailure { return value.code == .cancelled }
        return false
    }

    private func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The Slack operation could not be completed."
    }

    private func syncMessage(for run: SlackSyncRun) -> String {
        switch run.state {
        case .completed:
            "Refreshed \(run.successfulChannelCount) selected Slack channels and retained \(run.normalizedMessageCount) bounded messages."
        case .partial:
            "Slack refresh completed partially: \(run.successfulChannelCount) succeeded and \(run.failedChannelCount) failed."
        case .cancelled:
            "Slack refresh cancelled."
        case .failed:
            "Slack refresh failed before any selected channel completed."
        case .queued, .running, .waitingForRateLimit:
            "Slack refresh is still in progress."
        }
    }

    private func workspaceMetadata(_ workspaceID: String) -> SlackTraceMetadata {
        .init([(.workspaceHash, SlackPrivacy.hashIdentifier(workspaceID))])
    }

    private func notifyBriefingEvidenceChanged(_ reasonCodes: [String] = []) {
        let bounded = boundedReasonCodes(reasonCodes)
        guard onBriefingEvidenceChanged != nil,
              let mutationToken = beginUpdateBlockingMutation()
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishUpdateBlockingMutation(mutationToken) }
            await self.onBriefingEvidenceChanged?(bounded)
        }
    }

    private func boundedReasonCodes(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value -> String? in
            let bounded = String(value.prefix(120))
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
            guard !bounded.isEmpty, bounded.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return bounded
        })).sorted()
    }

    private func emit(
        _ event: SlackTraceEventName,
        trace: SlackTraceContext,
        status: SlackTraceStatus,
        reason: String,
        metadata: SlackTraceMetadata = .init()
    ) {
        eventSink?(.init(
            ts: now(),
            event: event,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "SlackAppController",
            status: status,
            reasonCode: reason,
            durationMilliseconds: nil,
            metadata: metadata
        ))
    }
}
