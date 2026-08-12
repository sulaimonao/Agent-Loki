import Accessibility
import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LokiChatModelReadinessPresentation: Equatable, Sendable {
    var readiness: ModelReadiness
    var providerName: String?
    var modelName: String?
    var requiredCapabilitiesMissing: [String]
    var recommendedCapabilitiesMissing: [String]
    var contextWindowSummary: String?
    var failureMessage: String?

    static let unavailable = Self(
        readiness: .assessmentRequired,
        providerName: nil,
        modelName: nil,
        requiredCapabilitiesMissing: [],
        recommendedCapabilitiesMissing: [],
        contextWindowSummary: nil,
        failureMessage: "Prefer any installed local model, then assess it before using Agent Loki Chat."
    )

    var canSend: Bool { readiness == .ready }

    var statusTitle: String {
        switch readiness {
        case .notInstalled: "Ollama not installed"
        case .providerNotRunning: "Ollama not running"
        case .modelUnavailable: "Model unavailable"
        case .assessmentRequired: "Assessment required"
        case .assessing: "Assessing model"
        case .ready: "Ready for Agent Loki"
        case .partiallyCompatible: "Missing required capabilities"
        case .incompatible: "Model incompatible"
        case .degraded: "Local model degraded"
        case .error: "Model assessment failed"
        }
    }

    var modelDisclosure: String {
        switch (providerName, modelName) {
        case let (.some(provider), .some(model)):
            "\(provider) · \(model)"
        case let (.some(provider), nil):
            provider
        case let (nil, .some(model)):
            model
        case (nil, nil):
            "No preferred chat model"
        }
    }
}

struct P8SemanticSourceAuthorityPresentation: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let sourceKind: SemanticIndexSourceKind
        let label: String
        let selectedForNextRebuild: Bool
        let presentInActiveGeneration: Bool
        let enabledAsSearchFilter: Bool
        let availableForRebuild: Bool
        let rebuildRequired: Bool

        var id: SemanticIndexSourceKind { sourceKind }
        var searchFilterIsNotIndexed: Bool {
            enabledAsSearchFilter && !presentInActiveGeneration
        }
    }

    let rows: [Row]
    let selectedBuildSourceSummary: String
    let canRebuildSelectedSources: Bool

    init(
        buildSourceKinds: Set<SemanticIndexSourceKind>,
        searchFilterSourceKinds: Set<SemanticIndexSourceKind>,
        indexedSourceKinds: Set<SemanticIndexSourceKind>,
        availableBuildSourceKinds: Set<SemanticIndexSourceKind>,
        rebuildRequired: Bool,
        isWorking: Bool
    ) {
        rows = SemanticIndexSourceKind.allCases.map { sourceKind in
            .init(
                sourceKind: sourceKind,
                label: P8FeatureController.semanticSourceLabel(
                    sourceKind
                ),
                selectedForNextRebuild:
                    buildSourceKinds.contains(sourceKind),
                presentInActiveGeneration:
                    indexedSourceKinds.contains(sourceKind),
                enabledAsSearchFilter:
                    searchFilterSourceKinds.contains(sourceKind),
                availableForRebuild:
                    availableBuildSourceKinds.contains(sourceKind),
                rebuildRequired:
                    rebuildRequired
                        && indexedSourceKinds.contains(sourceKind)
            )
        }
        selectedBuildSourceSummary = buildSourceKinds.isEmpty
            ? "No Index Sources selected."
            : "Selected for next rebuild: \(P8FeatureController.semanticSourceList(buildSourceKinds))."
        canRebuildSelectedSources =
            !buildSourceKinds.isEmpty
            && buildSourceKinds.isSubset(
                of: availableBuildSourceKinds
            )
            && !isWorking
    }
}

struct LokiChatViewCallbacks {
    var send: (_ prompt: String, _ context: LokiChatContext) -> Void
    var stop: () -> Void
    var retry: (_ messageID: String) -> Void
    var copyResponse: (_ text: String) -> Void
    var newConversation: (_ context: LokiChatContext) -> Void
    var selectConversation: (_ conversationID: String) -> Void
    var deleteConversation: (_ conversationID: String) async -> Bool
    var deleteAllConversations: () async -> Bool
    var loadMoreConversations: () -> Void
    var exportConversation: (_ conversationID: String, _ format: LokiChatExportFormat) -> Void
    var openEvidence: (_ reference: LokiEvidenceReference) -> Void
    var showModelReadiness: () -> Void
    var assessSelectedModel: () -> Void
    var selectModelForChat: () -> Void
    var updatePrivacySettings: (_ settings: LokiChatPrivacySettings) -> Void
    var updateWorkspacePolicy: (_ policy: LokiChatWorkspaceEvidencePolicy) -> Void

    init(
        send: @escaping (_ prompt: String, _ context: LokiChatContext) -> Void = { _, _ in },
        stop: @escaping () -> Void = {},
        retry: @escaping (_ messageID: String) -> Void = { _ in },
        copyResponse: @escaping (_ text: String) -> Void = { _ in },
        newConversation: @escaping (_ context: LokiChatContext) -> Void = { _ in },
        selectConversation: @escaping (_ conversationID: String) -> Void = { _ in },
        deleteConversation: @escaping (_ conversationID: String) async -> Bool = { _ in true },
        deleteAllConversations: @escaping () async -> Bool = { true },
        loadMoreConversations: @escaping () -> Void = {},
        exportConversation: @escaping (
            _ conversationID: String,
            _ format: LokiChatExportFormat
        ) -> Void = { _, _ in },
        openEvidence: @escaping (_ reference: LokiEvidenceReference) -> Void = { _ in },
        showModelReadiness: @escaping () -> Void = {},
        assessSelectedModel: @escaping () -> Void = {},
        selectModelForChat: @escaping () -> Void = {},
        updatePrivacySettings: @escaping (_ settings: LokiChatPrivacySettings) -> Void = { _ in },
        updateWorkspacePolicy: @escaping (
            _ policy: LokiChatWorkspaceEvidencePolicy
        ) -> Void = { _ in }
    ) {
        self.send = send
        self.stop = stop
        self.retry = retry
        self.copyResponse = copyResponse
        self.newConversation = newConversation
        self.selectConversation = selectConversation
        self.deleteConversation = deleteConversation
        self.deleteAllConversations = deleteAllConversations
        self.loadMoreConversations = loadMoreConversations
        self.exportConversation = exportConversation
        self.openEvidence = openEvidence
        self.showModelReadiness = showModelReadiness
        self.assessSelectedModel = assessSelectedModel
        self.selectModelForChat = selectModelForChat
        self.updatePrivacySettings = updatePrivacySettings
        self.updateWorkspacePolicy = updateWorkspacePolicy
    }
}

@MainActor
final class LokiChatViewState: ObservableObject {
    struct AttachedSourceOption: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let kind: AttachedDataSourceKind
    }

    @Published var conversations: [LokiConversationSummary]
    @Published var selectedConversationID: String?
    @Published var messages: [LokiMessage]
    @Published var evidenceByMessageID: [String: [LokiEvidenceReference]]
    @Published var toolReceiptsByMessageID: [String: [LokiChatToolReceipt]]
    @Published var provenanceByMessageID: [String: LokiGenerationProvenance]
    @Published var selectedScope: LokiChatContextScope
    @Published var selectedContextIdentifier: String?
    @Published var attachedSourceOptions: [AttachedSourceOption]
    @Published var composerText: String
    @Published var modelReadiness: LokiChatModelReadinessPresentation
    @Published var activeAssistantMessageID: String?
    @Published var toolActivityMessage: String?
    @Published var isLoadingHistory: Bool
    @Published var canLoadMoreConversations: Bool
    @Published var privacySettings: LokiChatPrivacySettings
    @Published var workspaceEvidencePolicy: LokiChatWorkspaceEvidencePolicy?
    @Published private(set) var announcementText: String?
    @Published private(set) var announcementRevision: Int

    init(
        conversations: [LokiConversationSummary] = [],
        selectedConversationID: String? = nil,
        messages: [LokiMessage] = [],
        evidenceByMessageID: [String: [LokiEvidenceReference]] = [:],
        toolReceiptsByMessageID: [String: [LokiChatToolReceipt]] = [:],
        provenanceByMessageID: [String: LokiGenerationProvenance] = [:],
        selectedScope: LokiChatContextScope = .thisBrief,
        selectedContextIdentifier: String? = nil,
        attachedSourceOptions: [AttachedSourceOption] = [],
        composerText: String = "",
        modelReadiness: LokiChatModelReadinessPresentation = .unavailable,
        activeAssistantMessageID: String? = nil,
        toolActivityMessage: String? = nil,
        isLoadingHistory: Bool = false,
        canLoadMoreConversations: Bool = false,
        privacySettings: LokiChatPrivacySettings = .defaults,
        workspaceEvidencePolicy: LokiChatWorkspaceEvidencePolicy? = nil
    ) {
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.messages = messages
        self.evidenceByMessageID = evidenceByMessageID
        self.toolReceiptsByMessageID = toolReceiptsByMessageID
        self.provenanceByMessageID = provenanceByMessageID
        self.selectedScope = selectedScope.isImplementedInP7 ? selectedScope : .thisBrief
        self.selectedContextIdentifier = selectedContextIdentifier
        self.attachedSourceOptions = attachedSourceOptions
        self.composerText = composerText
        self.modelReadiness = modelReadiness
        self.activeAssistantMessageID = activeAssistantMessageID
        self.toolActivityMessage = toolActivityMessage
        self.isLoadingHistory = isLoadingHistory
        self.canLoadMoreConversations = canLoadMoreConversations
        self.privacySettings = privacySettings.normalized()
        self.workspaceEvidencePolicy = workspaceEvidencePolicy
        self.announcementText = nil
        self.announcementRevision = 0
    }

    var isGenerating: Bool { activeAssistantMessageID != nil }
    var hasConversationToDelete: Bool {
        selectedConversationID != nil || !messages.isEmpty || !conversations.isEmpty
    }

    var selectedConversationSummary: LokiConversationSummary? {
        guard let selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == selectedConversationID })
    }

    var selectedContext: LokiChatContext {
        LokiChatContext(
            scope: selectedScope,
            targetIdentifier: selectedContextIdentifier
        )
    }

    var canSubmit: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && modelReadiness.canSend
            && selectedScope.isImplementedInP7
            && (selectedScope != .connectedSources
                || selectedContextIdentifier == nil
                || attachedSourceOptions.contains(where: {
                    $0.id == selectedContextIdentifier
                }))
    }

    func updateStreamingText(messageID: String, text: String, at date: Date = .now) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].visibleText = String(text.prefix(LokiChatLimits.maximumMessageCharacters))
        messages[index].updatedAt = date
        messages[index].state = .streaming
        messages[index].isPartial = true
        // Deliberately no VoiceOver announcement for individual token updates.
    }

    func generationStarted(messageID: String) {
        activeAssistantMessageID = messageID
        announce("Agent Loki is responding.")
    }

    func generationCompleted(messageID: String) {
        guard activeAssistantMessageID == messageID else { return }
        activeAssistantMessageID = nil
        announce("Agent Loki response complete.")
    }

    func generationCanceled(messageID: String) {
        guard activeAssistantMessageID == messageID else { return }
        activeAssistantMessageID = nil
        announce("Agent Loki response stopped.")
    }

    func generationFailed(messageID: String) {
        if activeAssistantMessageID == messageID {
            activeAssistantMessageID = nil
        }
        announce("Agent Loki could not complete the response.")
    }

    func synchronizeGeneration(
        activeMessageID: String?,
        terminalStateByMessageID: [String: LokiMessageState]
    ) {
        let previousMessageID = activeAssistantMessageID
        guard previousMessageID != activeMessageID else { return }

        if let previousMessageID {
            switch terminalStateByMessageID[previousMessageID] {
            case .completed:
                generationCompleted(messageID: previousMessageID)
            case .canceled, .interrupted:
                generationCanceled(messageID: previousMessageID)
            case .failed, .sourceEvidenceDeleted, .none:
                generationFailed(messageID: previousMessageID)
            case .pending, .waitingForFirstToken, .streaming, .toolRequested, .toolExecuting:
                generationFailed(messageID: previousMessageID)
            }
        }
        if let activeMessageID {
            generationStarted(messageID: activeMessageID)
        }
    }

    func announce(_ text: String) {
        announcementText = String(text.prefix(240))
        announcementRevision &+= 1
    }
}

enum LokiChatPresentation {
    static let composerPlaceholder = "Ask about this brief, your Vault, or connected sources…"
    static let localHistoryDisclosure = "Chat history is stored locally."
    static func localHistoryDisclosure(storeLocalHistory: Bool) -> String {
        storeLocalHistory
            ? localHistoryDisclosure
            : "Chat history storage is off; new turns are retained only for this app session. Previously stored history remains local until you delete it."
    }
    static func deletionAnnouncement(all: Bool, succeeded: Bool) -> String {
        switch (all, succeeded) {
        case (true, true):
            "All local Agent Loki conversations deleted."
        case (true, false):
            "Agent Loki could not delete all local conversations."
        case (false, true):
            "Local conversation deleted."
        case (false, false):
            "Agent Loki could not delete that local conversation."
        }
    }

    static func reconciledPrivacyDraft(
        _ draft: LokiChatPrivacySettings,
        previousCommitted: LokiChatPrivacySettings,
        newCommitted: LokiChatPrivacySettings
    ) -> LokiChatPrivacySettings {
        if draft == previousCommitted || newCommitted == .defaults {
            return newCommitted
        }
        return draft
    }

    static let noDurableMemoryDisclosure =
        "Agent Loki does not create durable personal memories in this version."

    static func deferredScopeLabel(_ scope: LokiChatContextScope) -> String {
        "\(scope.displayName) — planned"
    }
}

struct AskAgentLokiPanel: View {
    @ObservedObject var state: LokiChatViewState
    let callbacks: LokiChatViewCallbacks
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Ask Agent Loki", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)
                Spacer()
                Button(state.modelReadiness.statusTitle, action: callbacks.showModelReadiness)
                    .buttonStyle(.link)
                    .accessibilityLabel(
                        "Agent Loki model status: \(state.modelReadiness.statusTitle)"
                    )
            }

            LokiChatScopeSelector(selectedScope: $state.selectedScope)

            if state.selectedScope == .connectedSources {
                LokiChatAttachedSourcePicker(
                    selection: $state.selectedContextIdentifier,
                    options: state.attachedSourceOptions
                )
            }

            if let toolActivity = state.toolActivityMessage {
                Label(toolActivity, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Read-only tool activity: \(toolActivity)")
            }

            TextField(
                LokiChatPresentation.composerPlaceholder,
                text: $state.composerText,
                axis: .vertical
            )
            .lineLimit(2...5)
            .focused($composerFocused)
            .accessibilityLabel("Ask Agent Loki")
            .onSubmit(submit)

            HStack {
                Text(verbatim: state.modelReadiness.modelDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.isGenerating {
                    Button("Stop", role: .cancel) {
                        state.announce("Stopping Agent Loki response.")
                        callbacks.stop()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Stop Agent Loki response")
                } else {
                    Button("Ask", action: submit)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!state.canSubmit)
                        .accessibilityHint("Sends the question using the selected context.")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LokiChatPresentation.localHistoryDisclosure(
                    storeLocalHistory: state.privacySettings.storeLocalHistory
                ))
                Text(verbatim: LokiChatPresentation.noDurableMemoryDisclosure)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        }
        .padding()
        .onChange(of: state.selectedScope) { _, scope in
            if scope != .connectedSources {
                state.selectedContextIdentifier = nil
            }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: state.announcementRevision) { _, _ in postAnnouncement() }
    }

    private func submit() {
        let prompt = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, state.canSubmit else { return }
        state.composerText = ""
        state.announce("Question sent to Agent Loki.")
        callbacks.send(prompt, state.selectedContext)
    }

    private func postAnnouncement() {
        guard let text = state.announcementText else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

struct LokiChatWorkspaceView: View {
    @ObservedObject var state: LokiChatViewState
    let callbacks: LokiChatViewCallbacks
    let composerAccessory: AnyView?
    @State private var confirmDeleteAll = false
    @State private var conversationPendingDeletionID: String?

    init(
        state: LokiChatViewState,
        callbacks: LokiChatViewCallbacks,
        composerAccessory: AnyView? = nil
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.callbacks = callbacks
        self.composerAccessory = composerAccessory
    }

    var body: some View {
        NavigationSplitView {
            conversationSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                transcript
                Divider()
                composer
            }
        }
        .confirmationDialog(
            "Delete all local conversations?",
            isPresented: $confirmDeleteAll
        ) {
            Button("Delete All Conversations", role: .destructive) {
                Task {
                    let deleted = await callbacks.deleteAllConversations()
                    state.announce(LokiChatPresentation.deletionAnnouncement(
                        all: true,
                        succeeded: deleted
                    ))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes local chat history. It does not delete external source data or installed Ollama models.")
        }
        .confirmationDialog(
            "Delete this local conversation?",
            isPresented: Binding(
                get: { conversationPendingDeletionID != nil },
                set: { if !$0 { conversationPendingDeletionID = nil } }
            )
        ) {
            Button("Delete Conversation", role: .destructive) {
                guard let identifier = conversationPendingDeletionID else { return }
                conversationPendingDeletionID = nil
                Task {
                    let deleted = await callbacks.deleteConversation(identifier)
                    state.announce(LokiChatPresentation.deletionAnnouncement(
                        all: false,
                        succeeded: deleted
                    ))
                }
            }
            Button("Cancel", role: .cancel) { conversationPendingDeletionID = nil }
        }
    }

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.headline)
                Spacer()
                Button {
                    callbacks.newConversation(state.selectedContext)
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .help("New Conversation")
                .accessibilityLabel("New Agent Loki conversation")
                .disabled(state.isGenerating)
            }
            .padding()

            List(selection: $state.selectedConversationID) {
                ForEach(state.conversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: conversation.title)
                            .lineLimit(2)
                        Text(conversation.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(conversation.id))
                    .contextMenu {
                        Button("Delete Conversation", role: .destructive) {
                            conversationPendingDeletionID = conversation.id
                        }
                    }
                    .accessibilityLabel(
                        "\(conversation.title), \(conversation.messageCount) messages"
                    )
                }

                if state.canLoadMoreConversations {
                    Button(state.isLoadingHistory ? "Loading…" : "Load More") {
                        callbacks.loadMoreConversations()
                    }
                    .disabled(state.isLoadingHistory)
                    .accessibilityLabel("Load more local conversations")
                }
            }
            .disabled(state.isGenerating)
            .onChange(of: state.selectedConversationID) { _, identifier in
                guard let identifier else { return }
                callbacks.selectConversation(identifier)
            }

            Divider()
            Button("Delete All Conversations", role: .destructive) {
                confirmDeleteAll = true
            }
            .padding()
            .disabled(!state.hasConversationToDelete)
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: state.selectedConversationSummary?.title ?? "Agent Loki")
                    .font(.title2.bold())
                Text(verbatim: state.modelReadiness.modelDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LokiChatScopeSelector(selectedScope: $state.selectedScope)
                .frame(maxWidth: 540)
            if let conversationID = state.selectedConversationID {
                Menu {
                    ForEach(LokiChatExportFormat.allCases) { format in
                        Button("Export \(format.rawValue.uppercased())") {
                            callbacks.exportConversation(conversationID, format)
                        }
                    }
                    Divider()
                    Button("Delete Conversation", role: .destructive) {
                        conversationPendingDeletionID = conversationID
                    }
                } label: {
                    Label("Conversation Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Conversation actions")
            }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if state.messages.isEmpty {
                    ContentUnavailableView(
                        "Start a Conversation",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(
                            "Ask about the selected local brief, Vault records, or connected-source status."
                        )
                    )
                    .padding(.top, 48)
                } else {
                    ForEach(state.messages) { message in
                        LokiChatMessageView(
                            message: message,
                            evidence: state.evidenceByMessageID[message.id] ?? [],
                            toolReceipts: state.toolReceiptsByMessageID[message.id] ?? [],
                            provenance: state.provenanceByMessageID[message.id],
                            callbacks: callbacks
                        )
                        .id(message.id)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Agent Loki conversation transcript")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let composerAccessory {
                composerAccessory
            }
            AskAgentLokiPanel(state: state, callbacks: callbacks)
        }
        .padding()
    }
}

struct LokiChatScopeSelector: View {
    @Binding var selectedScope: LokiChatContextScope

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LokiChatContextScope.allCases) { scope in
                Button {
                    guard scope.isImplementedInP7 else { return }
                    selectedScope = scope
                } label: {
                    Text(
                        scope.isImplementedInP7
                            ? scope.displayName
                            : LokiChatPresentation.deferredScopeLabel(scope)
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(selectedScope == scope ? .accentColor : nil)
                .disabled(!scope.isImplementedInP7)
                .accessibilityLabel(
                    scope.isImplementedInP7
                        ? "\(scope.displayName) context"
                        : "\(scope.displayName), planned and unavailable"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Loki context")
    }
}

private struct LokiChatAttachedSourcePicker: View {
    @Binding var selection: String?
    let options: [LokiChatViewState.AttachedSourceOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Attached source", selection: $selection) {
                Text("Connected-source status only").tag(String?.none)
                if let selection,
                   !options.contains(where: { $0.id == selection }) {
                    Text("Selected source is no longer available")
                        .tag(String?.some(selection))
                }
                ForEach(options) { option in
                    Text("\(option.displayName) (\(option.kind.displayName))")
                        .tag(String?.some(option.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Attached data source for this conversation")
            .accessibilityHint(
                "Choose one consented attached source. Vault reads are limited to that exact source."
            )

            if options.isEmpty {
                Text("No retained attached source currently allows local-model use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "No consented attached data source is available"
                    )
            }
        }
    }
}

private struct LokiChatMessageView: View {
    let message: LokiMessage
    let evidence: [LokiEvidenceReference]
    let toolReceipts: [LokiChatToolReceipt]
    let provenance: LokiGenerationProvenance?
    let callbacks: LokiChatViewCallbacks

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    message.role == .user ? "You" : "Agent Loki",
                    systemImage: message.role == .user ? "person.crop.circle" : "sparkles"
                )
                .font(.headline)
                Spacer()
                Text(message.updatedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if message.answerSegments.isEmpty {
                Text(verbatim: message.visibleText)
                    .textSelection(.enabled)
            } else {
                ForEach(message.answerSegments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: segment.classification.displayName)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(verbatim: segment.text)
                            .textSelection(.enabled)
                    }
                }
            }

            if let lifecycleLabel = lifecycleLabel {
                Label(lifecycleLabel, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if message.isPartial {
                Label("Truthful partial response", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failure = message.failure {
                Label(failure.consumerMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !evidence.isEmpty {
                DisclosureGroup("Evidence (\(evidence.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(evidence) { reference in
                            Button {
                                callbacks.openEvidence(reference)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: reference.displayLabel)
                                    Text(verbatim: reference.sourceKind.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Evidence: \(reference.displayLabel), \(reference.sourceKind.rawValue)"
                            )
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if !toolReceipts.isEmpty {
                DisclosureGroup("Read-only tool activity (\(toolReceipts.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(toolReceipts) { receipt in
                            Text(
                                verbatim: "\(receipt.toolName): \(receipt.status) · \(receipt.reasonCode)"
                            )
                            .font(.caption)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if let provenance {
                DisclosureGroup("Model and generation") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Provider: \(provenance.provider)")
                        Text(verbatim: "Model: \(provenance.modelIdentifier)")
                        Text(verbatim: "Assessment: \(provenance.assessmentVersion)")
                        Text(verbatim: "Status: \(provenance.status) · \(provenance.reasonCode)")
                    }
                    .font(.caption)
                    .padding(.top, 6)
                }
            }

            if message.role == .assistant {
                HStack {
                    Button("Copy") { callbacks.copyResponse(message.visibleText) }
                        .accessibilityLabel("Copy Agent Loki response")
                    if message.state == .failed
                        || message.state == .canceled
                        || message.state == .interrupted {
                        Button("Retry") { callbacks.retry(message.id) }
                            .accessibilityLabel("Retry this Agent Loki response")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "Your message" : "Agent Loki response")
    }

    private var lifecycleLabel: String? {
        switch message.state {
        case .pending: "Pending"
        case .waitingForFirstToken: "Waiting for first token"
        case .streaming: "Streaming local response"
        case .toolRequested: "Read-only tool requested"
        case .toolExecuting: "Reading authorized local data"
        case .completed, .canceled, .failed, .interrupted, .sourceEvidenceDeleted:
            nil
        }
    }
}

struct AgentLokiModelReadinessSection: View {
    let presentation: LokiChatModelReadinessPresentation
    let callbacks: LokiChatViewCallbacks

    var body: some View {
        GroupBox("Model Readiness") {
            VStack(alignment: .leading, spacing: 12) {
                readinessRow(
                    title: "Agent Loki Chat",
                    detail: presentation.statusTitle,
                    systemImage: presentation.canSend ? "checkmark.circle.fill" : "circle.dashed"
                )
                Text(verbatim: presentation.modelDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !presentation.requiredCapabilitiesMissing.isEmpty {
                    Text(
                        verbatim: "Missing requirements: \(presentation.requiredCapabilitiesMissing.joined(separator: ", "))"
                    )
                    .font(.caption)
                }
                if let context = presentation.contextWindowSummary {
                    Text(verbatim: "Context window: \(context)")
                        .font(.caption)
                }
                if let failure = presentation.failureMessage {
                    Text(verbatim: failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Assess Model", action: callbacks.assessSelectedModel)
                        .disabled(presentation.readiness == .assessing)
                    Button("Prefer for Agent Loki", action: callbacks.selectModelForChat)
                        .disabled(presentation.modelName == nil)
                }

                Divider()
                readinessRow(
                    title: "Semantic Vault Search",
                    detail: "Configure an Embedding role and manage the explicit derived index in Local Models.",
                    systemImage: "text.magnifyingglass"
                )
                readinessRow(
                    title: "Images and screenshots",
                    detail: "Temporary, metadata-stripped attachments are available from the live composer.",
                    systemImage: "photo"
                )
                readinessRow(
                    title: "Web Research",
                    detail: "External research is separately credentialed and disabled by default in Local Models.",
                    systemImage: "network"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func readinessRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LokiChatPrivacyControls: View {
    @Binding var settings: LokiChatPrivacySettings
    @Binding var workspacePolicy: LokiChatWorkspaceEvidencePolicy?
    let callbacks: LokiChatViewCallbacks

    var body: some View {
        Form {
            Section("Agent Loki Chat") {
                Toggle("Store local chat history", isOn: $settings.storeLocalHistory)

                Picker("Conversation retention", selection: $settings.retentionPolicy) {
                    ForEach(LokiChatRetentionPolicy.allCases) { policy in
                        Text(verbatim: policy.displayName).tag(policy)
                    }
                }

                if settings.retentionPolicy == .custom {
                    Stepper(
                        "Retain for \(settings.customRetentionDays ?? 90) days",
                        value: Binding(
                            get: { settings.customRetentionDays ?? 90 },
                            set: { settings.customRetentionDays = $0 }
                        ),
                        in: LokiChatLimits.minimumCustomRetentionDays...LokiChatLimits.maximumCustomRetentionDays
                    )
                }

                Toggle(
                    "Include source excerpts in stored conversations",
                    isOn: $settings.includeSourceExcerpts
                )
                Toggle(
                    "Allow feed evidence in Agent Loki Chat",
                    isOn: $settings.allowFeedEvidence
                )

                if workspacePolicy != nil {
                    Toggle(
                        "Allow selected Slack evidence in Agent Loki Chat",
                        isOn: Binding(
                            get: { workspacePolicy?.allowSelectedSlackEvidence ?? false },
                            set: { workspacePolicy?.allowSelectedSlackEvidence = $0 }
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: LokiChatPresentation.localHistoryDisclosure(
                        storeLocalHistory: settings.storeLocalHistory
                    ))
                    Text(verbatim: LokiChatPresentation.noDurableMemoryDisclosure)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("Save Chat Privacy Settings") {
                settings = settings.normalized()
                callbacks.updatePrivacySettings(settings)
                if let workspacePolicy {
                    callbacks.updateWorkspacePolicy(workspacePolicy)
                }
            }
        }
    }
}

@MainActor
private final class LiveLokiChatViewBridge: ObservableObject {
    let state: LokiChatViewState
    private weak var model: AppModel?
    private weak var controller: LokiChatController?
    private var cancellable: AnyCancellable?

    init(model: AppModel, controller: LokiChatController) {
        self.model = model
        self.controller = controller
        self.state = LokiChatViewState()
        synchronize()
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.synchronize()
            }
        }
    }

    var callbacks: LokiChatViewCallbacks {
        LokiChatViewCallbacks(
            send: { [weak controller] prompt, context in
                controller?.setContext(context)
                controller?.send(prompt)
            },
            stop: { [weak controller] in controller?.stopGeneration() },
            retry: { [weak controller] messageID in
                controller?.retryResponse(messageID: messageID)
            },
            copyResponse: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            newConversation: { [weak controller] context in
                _ = controller?.newConversation(context: context)
            },
            selectConversation: { [weak controller] identifier in
                controller?.openConversation(id: identifier)
            },
            deleteConversation: { [weak controller] identifier in
                controller?.deleteConversation(id: identifier) ?? false
            },
            deleteAllConversations: { [weak controller] in
                await controller?.deleteAllConversations() ?? false
            },
            loadMoreConversations: { [weak controller] in
                controller?.loadMoreConversations()
            },
            exportConversation: { [weak controller] identifier, format in
                controller?.openConversation(id: identifier)
                controller?.revealExportSavePanel(format: format)
            },
            openEvidence: { [weak model] reference in
                if let url = reference.directSourceURL, url.scheme?.lowercased() == "https" {
                    NSWorkspace.shared.open(url)
                } else if reference.sourceKind == .vault {
                    model?.selection = .vault
                } else {
                    model?.selection = .sources
                }
            },
            showModelReadiness: { [weak model] in model?.selection = .models },
            assessSelectedModel: { [weak controller] in
                guard let identifier = controller?.selectedChatModelID else { return }
                controller?.assessModel(id: identifier)
            },
            selectModelForChat: {},
            updatePrivacySettings: { [weak controller] settings in
                controller?.updatePrivacySettings(settings)
            },
            updateWorkspacePolicy: { [weak controller] policy in
                controller?.setWorkspaceSlackEvidence(
                    policy.workspaceIdentifier,
                    allowed: policy.allowSelectedSlackEvidence
                )
            }
        )
    }

    func synchronize() {
        guard let controller else { return }
        let messages = controller.activeConversation?.messages ?? []
        state.conversations = controller.conversationSummaries
        state.canLoadMoreConversations = controller.canLoadMoreConversations
        state.selectedConversationID = controller.activeConversation?.id
        state.messages = messages
        state.selectedScope = controller.activeConversation?.context.scope ?? state.selectedScope
        state.selectedContextIdentifier = controller.activeConversation?.context.targetIdentifier
        state.attachedSourceOptions = controller
            .attachedSourceRetrievalAuthorityIsOpen
            ? ((try? model?.store.attachedDataSources()) ?? [])
                .filter {
                    $0.localModelConsentEnabled
                        && $0.hasRetainedLocalData
                        && $0.currentGenerationIdentifier != nil
                        && !$0.importedLocalContainerIdentifiers.isEmpty
                        && !$0.selections.isEmpty
                }
                .sorted {
                    if $0.displayName != $1.displayName {
                        return $0.displayName.localizedStandardCompare(
                            $1.displayName
                        ) == .orderedAscending
                    }
                    return $0.id < $1.id
                }
                .map {
                    .init(
                        id: $0.id,
                        displayName: $0.displayName,
                        kind: $0.kind
                    )
                }
            : []
        state.modelReadiness = controller.selectedModelReadinessPresentation()
        let activeAssistantMessageID = controller.isGenerating
            ? messages.last(where: { $0.role == .assistant && $0.state.isTransient })?.id
            : nil
        state.synchronizeGeneration(
            activeMessageID: activeAssistantMessageID,
            terminalStateByMessageID: Dictionary(
                uniqueKeysWithValues: messages.map { ($0.id, $0.state) }
            )
        )
        state.toolActivityMessage = controller.toolActivityMessage
        state.privacySettings = controller.privacySettings
        state.evidenceByMessageID = Dictionary(uniqueKeysWithValues: messages
            .filter { $0.role == .assistant }
            .map { message in
                let stored = controller.evidenceReferences(messageID: message.id)
                let evidence = stored.isEmpty && message.id == messages.last?.id
                    ? controller.activeEvidence
                    : stored
                return (message.id, evidence)
            })
        state.toolReceiptsByMessageID = Dictionary(uniqueKeysWithValues: messages
            .filter { $0.role == .assistant }
            .map { message in
                let stored = controller.toolReceipts(messageID: message.id)
                let receipts = stored.isEmpty && message.id == messages.last?.id
                    ? controller.activeToolReceipts
                    : stored
                return (message.id, receipts)
            })
        state.provenanceByMessageID = Dictionary(uniqueKeysWithValues: messages.compactMap {
            guard let provenance = controller.generationProvenance(messageID: $0.id) else {
                return nil
            }
            return ($0.id, provenance)
        })
    }
}

struct LiveAskAgentLokiPanel: View {
    @StateObject private var bridge: LiveLokiChatViewBridge
    @ObservedObject private var controller: LokiChatController

    init(model: AppModel, controller: LokiChatController) {
        _bridge = StateObject(wrappedValue: LiveLokiChatViewBridge(
            model: model,
            controller: controller
        ))
        _controller = ObservedObject(wrappedValue: controller)
    }

    var body: some View {
        VStack(spacing: 8) {
            P8VisionRouteConfirmationBanner(controller: controller)
            P8VisionAttachmentControls(
                features: controller.p8Features,
                compact: true
            )
            AskAgentLokiPanel(state: bridge.state, callbacks: bridge.callbacks)
        }
    }
}

struct LiveLokiChatWorkspaceView: View {
    @StateObject private var bridge: LiveLokiChatViewBridge
    @ObservedObject private var controller: LokiChatController

    init(model: AppModel, controller: LokiChatController) {
        _bridge = StateObject(wrappedValue: LiveLokiChatViewBridge(
            model: model,
            controller: controller
        ))
        _controller = ObservedObject(wrappedValue: controller)
    }

    var body: some View {
        LokiChatWorkspaceView(
            state: bridge.state,
            callbacks: bridge.callbacks,
            composerAccessory: AnyView(
                VStack(spacing: 8) {
                    P8VisionRouteConfirmationBanner(
                        controller: controller
                    )
                    P8VisionAttachmentControls(
                        features: controller.p8Features,
                        compact: true
                    )
                }
            )
        )
            .navigationTitle("Agent Loki")
    }
}

struct LiveAgentLokiModelReadinessSection: View {
    @ObservedObject var controller: LokiChatController

    var body: some View {
        GroupBox("Agent Loki Model Readiness") {
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.statusMessage)
                    .foregroundStyle(.secondary)
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if controller.installedModels.isEmpty {
                    ContentUnavailableView(
                        "No Installed Models Discovered",
                        systemImage: "cpu",
                        description: Text("Check Ollama. Loki Brief remains fully usable without Agent Loki Chat.")
                    )
                }

                Text("Model Roles")
                    .font(.title3.bold())
                Text("Each role is explicit. Only current, assessed local assignments can execute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ModelRole.allCases, id: \.self) { role in
                    P8ModelRoleCard(controller: controller, role: role)
                }

                Divider()

                P8ReasoningModePicker(controller: controller)

                DisclosureGroup("Installed Model Assessments") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.readinessCards()) { card in
                            P8InstalledModelAssessmentCard(
                                controller: controller,
                                card: card
                            )
                        }
                    }
                    .padding(.top, 8)
                }

                Divider()
                P8SemanticSearchControls(features: controller.p8Features)

                Divider()
                P8VisionAttachmentControls(
                    features: controller.p8Features,
                    compact: false
                )

                Divider()
                P8WebResearchControls(
                    controller: controller,
                    features: controller.p8Features
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct P8ModelRoleCard: View {
    @ObservedObject var controller: LokiChatController
    let role: ModelRole

    private var assignment: ModelRoleAssignment {
        controller.modelRoleAssignment(for: role)
    }

    private var requestedModelIdentifier: String? {
        assignment.requestedModelIdentifier
    }

    private var requestedModelIsInstalled: Bool {
        guard let requestedModelIdentifier else { return false }
        return controller.installedModels.contains { $0.id == requestedModelIdentifier }
    }

    private var recommendedModelIdentifier: String? {
        ModelCuratedRolePolicy.recommendedModelIdentifier(for: role)
    }

    private var requestedModelIsRecommended: Bool {
        guard let requestedModelIdentifier else { return false }
        return ModelCuratedRolePolicy.isRecommended(requestedModelIdentifier, for: role)
    }

    private var requestedModelIsAssessing: Bool {
        guard let requestedModelIdentifier else { return false }
        return controller.assessingModelIDs.contains(requestedModelIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(role.displayName, systemImage: roleSystemImage)
                    .font(.headline)
                Spacer()
                P8StatusBadge(
                    text: readinessLabel,
                    color: readinessColor
                )
            }

            Text(verbatim: assignedModelDisclosure)
                .font(.subheadline.weight(.medium))

            HStack(spacing: 6) {
                P8StatusBadge(
                    text: requestedModelIsInstalled ? "Installed" : "Unavailable",
                    color: requestedModelIsInstalled ? .blue : .orange
                )
                if requestedModelIsRecommended {
                    P8StatusBadge(text: "Recommended", color: .purple)
                } else if requestedModelIdentifier != nil {
                    P8StatusBadge(text: "Custom", color: .secondary)
                }
                if assignment.dispositions.contains(.selected) {
                    P8StatusBadge(text: "Selected", color: .accentColor)
                }
                if assignment.assessmentTimestamp != nil {
                    P8StatusBadge(
                        text: assessmentIsStale ? "Assessed · stale" : "Assessed",
                        color: assessmentIsStale ? .orange : .green
                    )
                } else {
                    P8StatusBadge(text: "Not assessed", color: .secondary)
                }
                if assignment.requestedClassification == .cloud {
                    P8StatusBadge(text: "Cloud blocked", color: .red)
                }
            }

            Text("Required: \(capabilityList(Array(role.requiredCapabilities)))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let inheritedFromRole = assignment.inheritedFromRole {
                Text("Configured to inherit from \(inheritedFromRole.displayName). Routing resolves the current assessed Primary assignment at send time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let recommendedModelIdentifier,
                      !requestedModelIsRecommended {
                Text("Recommended: \(recommendedModelIdentifier)\(controller.installedModels.contains { $0.id == recommendedModelIdentifier } ? " · installed" : " · unavailable")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Reason: \(assignment.reasonCode)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Menu {
                    Button("Unassigned") {
                        controller.clearModelRole(role)
                    }
                    if role == .briefSummary {
                        Button("Inherit Primary") {
                            controller.inheritPrimaryForBriefSummary()
                        }
                        Divider()
                    }
                    ForEach(controller.installedModels) { model in
                        Button {
                            controller.assignModel(id: model.id, to: role)
                        } label: {
                            if ModelCuratedRolePolicy.isRecommended(model.id, for: role) {
                                Label(model.name, systemImage: "star.fill")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    Label("Assign Model", systemImage: "slider.horizontal.3")
                }
                .disabled(controller.isGenerating)

                if let requestedModelIdentifier, requestedModelIsInstalled {
                    Button(requestedModelIsAssessing ? "Assessing…" : "Assess") {
                        controller.assessModel(id: requestedModelIdentifier)
                    }
                    .disabled(requestedModelIsAssessing || controller.isGenerating)
                }

                if requestedModelIdentifier != nil || assignment.inheritedFromRole != nil {
                    Button("Clear", role: .destructive) {
                        controller.clearModelRole(role)
                    }
                    .disabled(controller.isGenerating)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var assessmentIsStale: Bool {
        assignment.readiness == .staleAssessment
            || assignment.readiness == .staleDigest
    }

    private var assignedModelDisclosure: String {
        if let inheritedFromRole = assignment.inheritedFromRole {
            return "Inherits \(inheritedFromRole.displayName)"
        }
        if let requestedProvider = assignment.requestedProvider,
           let requestedModelIdentifier {
            return "\(requestedProvider.capitalized) · \(requestedModelIdentifier)"
        }
        return "No model assigned"
    }

    private var readinessLabel: String {
        switch assignment.readiness {
        case .unassigned: "Unassigned"
        case .modelUnavailable: "Unavailable"
        case .assessmentRequired: "Assessment required"
        case .staleAssessment: "Assessment stale"
        case .staleDigest: "Digest stale"
        case .partiallyCompatible: "Partially compatible"
        case .degraded: "Degraded"
        case .ready: "Ready"
        case .cloudBlocked: "Cloud blocked"
        case .inherited: "Inherited"
        }
    }

    private var readinessColor: Color {
        switch assignment.readiness {
        case .ready: .green
        case .inherited: .blue
        case .assessmentRequired, .staleAssessment, .staleDigest,
             .partiallyCompatible, .degraded, .modelUnavailable: .orange
        case .cloudBlocked: .red
        case .unassigned: .secondary
        }
    }

    private var roleSystemImage: String {
        switch role {
        case .primaryAgent: "brain.head.profile"
        case .textFallback: "text.bubble"
        case .vision: "eye"
        case .embedding: "point.3.connected.trianglepath.dotted"
        case .briefSummary: "doc.text.magnifyingglass"
        }
    }

    private func capabilityList(_ values: [ModelCapability]) -> String {
        values
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: ", ")
    }
}

private struct P8ReasoningModePicker: View {
    @ObservedObject var controller: LokiChatController

    private var primary: ModelRoleAssignment {
        controller.modelRoleAssignment(for: .primaryAgent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reasoning Mode", systemImage: "brain")
                .font(.title3.bold())

            Picker("Reasoning mode", selection: $controller.reasoningMode) {
                ForEach(ReasoningMode.allCases, id: \.self) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isGenerating)

            HStack(spacing: 8) {
                ForEach(ReasoningMode.allCases, id: \.self) { mode in
                    let resolution = resolution(for: mode)
                    P8StatusBadge(
                        text: "\(mode.displayName): \(availabilityLabel(resolution.availability))",
                        color: availabilityColor(resolution.availability)
                    )
                }
            }

            Text(reasoningDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resolution(for mode: ReasoningMode) -> ReasoningModeResolution {
        ReasoningModeResolution.resolve(
            mode,
            modelIdentifier: primary.effectiveModelIdentifier
                ?? primary.requestedModelIdentifier
                ?? "",
            verifiedControls: primary.verifiedThinkingModes
        )
    }

    private var reasoningDisclosure: String {
        let resolution = resolution(for: controller.reasoningMode)
        switch resolution.availability {
        case .available:
            return "The selected mode is backed by a verified local control. Private reasoning is never persisted or displayed."
        case .reduced:
            return "The selected model exposes only a reduced verified reasoning control. Private reasoning is never persisted or displayed."
        case .unavailable:
            return "The selected mode is unavailable for the current Primary role; sending will remain fail-closed."
        }
    }

    private func availabilityLabel(
        _ availability: ReasoningModeAvailability
    ) -> String {
        switch availability {
        case .available: "available"
        case .reduced: "reduced"
        case .unavailable: "unavailable"
        }
    }

    private func availabilityColor(
        _ availability: ReasoningModeAvailability
    ) -> Color {
        switch availability {
        case .available: .green
        case .reduced: .orange
        case .unavailable: .secondary
        }
    }
}

private struct P8InstalledModelAssessmentCard: View {
    @ObservedObject var controller: LokiChatController
    let card: AgentLokiModelReadinessCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(card.displayName)
                    .font(.headline)
                Spacer()
                P8StatusBadge(
                    text: card.readiness.rawValue.replacingOccurrences(
                        of: "_",
                        with: " "
                    ).capitalized,
                    color: card.isReady ? .green : .secondary
                )
            }
            Text("Installed locally · context \(card.contextClassification.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Estimated: \(capabilityList(card.estimatedCapabilities))")
                .font(.caption)
            Text("Verified: \(capabilityList(card.verifiedCapabilities))")
                .font(.caption)
            if !card.missingRequiredCapabilities.isEmpty {
                Text("Missing: \(capabilityList(card.missingRequiredCapabilities))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(card.isAssessing ? "Assessing…" : "Assess Model") {
                controller.assessModel(id: card.id)
            }
            .disabled(card.isAssessing || controller.isGenerating)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func capabilityList(_ values: [ModelCapability]) -> String {
        values.isEmpty ? "not verified" : values.map(\.rawValue).joined(separator: ", ")
    }
}

private struct P8SemanticSearchControls: View {
    @ObservedObject var features: P8FeatureController
    @State private var includeStartDate = false
    @State private var includeEndDate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Semantic Vault Search", systemImage: "text.magnifyingglass")
                    .font(.title3.bold())
                Spacer()
                if let health = features.semanticHealth {
                    if health.state == .ready
                        && !features.embeddingBindingIsReady {
                        P8StatusBadge(
                            text: embeddingReassessmentIsRequired
                                ? "Reassessment required"
                                : "Embedding unavailable",
                            color: .orange
                        )
                    } else {
                        P8StatusBadge(
                            text: health.state.rawValue.replacingOccurrences(
                                of: "_",
                                with: " "
                            ).capitalized,
                            color: healthColor(health.state)
                        )
                    }
                } else {
                    P8StatusBadge(text: "Health unknown", color: .secondary)
                }
            }

            Picker("Search mode", selection: $features.semanticMode) {
                ForEach(SemanticSearchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if !features.embeddingBindingIsReady {
                Label(
                    embeddingReassessmentIsRequired
                        ? "Embedding reassessment required. Semantic and Hybrid fail closed; Lexical is available only when current index health permits it."
                        : "No ready Embedding role is bound. Semantic and Hybrid fail closed; Lexical is available only when current index health permits it.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let model = features.embeddingRoleAssignment?
                .effectiveModelIdentifier {
                Label("Embedding: \(model) · assessed and ready", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                TextField("Search the derived local index", text: $features.semanticQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(features.searchSemanticIndex)
                Button("Search", action: features.searchSemanticIndex)
                    .disabled(
                        features.semanticQuery.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || features.semanticIsWorking
                    )
                    .keyboardShortcut(.return, modifiers: [.command])
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Index Sources")
                    .font(.headline)
                Text(
                    "Explicitly authorizes which local source adapters may be read during the next manual rebuild. This selection does not change Search Filters."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(sourcePresentation.rows) { row in
                    HStack(spacing: 8) {
                        Toggle(
                            row.label,
                            isOn: buildSourceKindBinding(
                                row.sourceKind
                            )
                        )
                        .toggleStyle(.checkbox)
                        .disabled(
                            !row.availableForRebuild
                                || features.semanticIsWorking
                        )
                        Spacer()
                        if row.selectedForNextRebuild {
                            P8StatusBadge(
                                text: "Next rebuild",
                                color: .blue
                            )
                        }
                        if row.presentInActiveGeneration {
                            P8StatusBadge(
                                text: "Indexed",
                                color: row.rebuildRequired
                                    ? .orange
                                    : .green
                            )
                        }
                        if row.rebuildRequired {
                            P8StatusBadge(
                                text: "Rebuild required",
                                color: .orange
                            )
                        }
                        if !row.availableForRebuild {
                            P8StatusBadge(
                                text: "Unavailable",
                                color: .secondary
                            )
                        }
                    }
                }

                Text(sourcePresentation.selectedBuildSourceSummary)
                    .font(.caption.weight(.semibold))
            }
            .padding(10)
            .background(
                .quaternary.opacity(0.2),
                in: RoundedRectangle(cornerRadius: 8)
            )

            DisclosureGroup("Search Filters") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Narrows results only within sources already present in the active generation. It never authorizes indexing."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(sourcePresentation.rows) { row in
                        HStack(spacing: 8) {
                            Toggle(
                                row.label,
                                isOn: searchSourceKindBinding(
                                    row.sourceKind
                                )
                            )
                            .toggleStyle(.checkbox)
                            Spacer()
                            if row.enabledAsSearchFilter {
                                P8StatusBadge(
                                    text: "Filtered",
                                    color: .blue
                                )
                            }
                            if row.searchFilterIsNotIndexed {
                                P8StatusBadge(
                                    text: "Not indexed",
                                    color: .orange
                                )
                            }
                        }
                    }

                    Toggle("From date", isOn: Binding(
                        get: { includeStartDate },
                        set: { enabled in
                            includeStartDate = enabled
                            features.semanticStartDate = enabled ? .now : nil
                        }
                    ))
                    .toggleStyle(.checkbox)
                    if includeStartDate {
                        DatePicker(
                            "From",
                            selection: Binding(
                                get: { features.semanticStartDate ?? .now },
                                set: { features.semanticStartDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                    }

                    Toggle("Through date", isOn: Binding(
                        get: { includeEndDate },
                        set: { enabled in
                            includeEndDate = enabled
                            features.semanticEndDate = enabled ? .now : nil
                        }
                    ))
                    .toggleStyle(.checkbox)
                    if includeEndDate {
                        DatePicker(
                            "Through",
                            selection: Binding(
                                get: { features.semanticEndDate ?? .now },
                                set: { features.semanticEndDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                    }
                }
                .padding(.top, 6)
            }

            Text(features.semanticStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let health = features.semanticHealth {
                semanticFreshness(health)
            }

            HStack {
                Button("Refresh Health", action: features.refreshSemanticHealth)
                    .disabled(features.semanticIsWorking)
                Button("Rebuild Selected Sources") {
                    features.rebuildSemanticIndex()
                }
                .disabled(
                    !sourcePresentation.canRebuildSelectedSources
                )
                if features.semanticIsWorking {
                    Button("Cancel", role: .cancel, action: features.cancelSemanticWork)
                }
            }
            .buttonStyle(.bordered)

            if features.semanticResults.isEmpty,
               features.semanticHealth?.state == .empty
                    || features.semanticHealth?.state == .stale {
                ContentUnavailableView(
                    features.semanticHealth?.state == .stale
                        ? "Derived Index Is Stale"
                        : "No Derived Index",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Canonical local records are unchanged. Run an explicit rebuild to create a disposable search index.")
                )
            } else {
                ForEach(features.semanticResults, id: \.chunkIdentifier) { result in
                    semanticResult(result)
                }
            }
        }
        .onAppear {
            includeStartDate = features.semanticStartDate != nil
            includeEndDate = features.semanticEndDate != nil
            if features.semanticHealth == nil {
                features.refreshSemanticHealth()
            }
        }
    }

    @ViewBuilder
    private func semanticFreshness(_ health: SemanticIndexHealth) -> some View {
        if let generation = health.activeGeneration {
            Text("Generation: \(generation.spec.retrievalCapability.rawValue.replacingOccurrences(of: "_", with: " ")) · \(generation.sourceCount) sources · \(generation.chunkCount) chunks · created \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let latest = health.progress.map(\.updatedAt).max() {
            Text("Latest index activity: \(latest.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func semanticResult(_ result: SemanticSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.matchedText)
                .lineLimit(5)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                P8StatusBadge(
                    text: result.similarityClassification.rawValue
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized,
                    color: similarityColor(result.similarityClassification)
                )
                if let similarity = result.cosineSimilarity {
                    Text("Similarity \(similarity.formatted(.number.precision(.fractionLength(3))))")
                        .font(.caption)
                }
                if let lexicalScore = result.lexicalScore {
                    Text("Lexical \(lexicalScore.formatted(.number.precision(.fractionLength(3))))")
                        .font(.caption)
                }
            }
            Text("\(sourceKindLabel(result.provenance.sourceKind)) · \(result.provenance.provider) · \(result.provenance.sourceTimestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Provenance \(result.provenance.provenanceReceiptHash.prefix(16))…")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let sourceURL = result.provenance.sourceURL,
               sourceURL.scheme?.lowercased() == "https" {
                Link("Open Source", destination: sourceURL)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var embeddingReassessmentIsRequired: Bool {
        guard let readiness =
            features.embeddingRoleAssignment?.readiness
        else {
            return false
        }
        return readiness == .staleAssessment
            || readiness == .staleDigest
    }

    private var sourcePresentation:
        P8SemanticSourceAuthorityPresentation
    {
        .init(
            buildSourceKinds: features.semanticBuildSourceKinds,
            searchFilterSourceKinds: features.semanticSourceKinds,
            indexedSourceKinds: features.semanticIndexedSourceKinds,
            availableBuildSourceKinds:
                features.semanticAvailableBuildSourceKinds,
            rebuildRequired:
                features.semanticSourceScopeRequiresRebuild,
            isWorking: features.semanticIsWorking
        )
    }

    private func buildSourceKindBinding(
        _ kind: SemanticIndexSourceKind
    ) -> Binding<Bool> {
        Binding(
            get: {
                features.semanticBuildSourceKinds.contains(kind)
            },
            set: { enabled in
                features.setSemanticBuildSourceKind(
                    kind,
                    enabled: enabled
                )
            }
        )
    }

    private func searchSourceKindBinding(
        _ kind: SemanticIndexSourceKind
    ) -> Binding<Bool> {
        Binding(
            get: { features.semanticSourceKinds.contains(kind) },
            set: { enabled in
                if enabled {
                    features.semanticSourceKinds.insert(kind)
                } else {
                    features.semanticSourceKinds.remove(kind)
                }
            }
        )
    }

    private func sourceKindLabel(_ kind: SemanticIndexSourceKind) -> String {
        kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func healthColor(_ state: SemanticIndexHealthState) -> Color {
        switch state {
        case .ready, .lexicalOnly: .green
        case .building, .paused: .blue
        case .stale, .degraded: .orange
        case .corrupt: .red
        case .empty: .secondary
        }
    }

    private func similarityColor(
        _ classification: SemanticSearchSimilarityClassification
    ) -> Color {
        switch classification {
        case .strong: .green
        case .moderate: .blue
        case .weak: .orange
        case .lexicalOnly: .secondary
        }
    }
}

private struct P8VisionRouteConfirmationBanner: View {
    @ObservedObject var controller: LokiChatController

    var body: some View {
        if let route = controller.pendingVisionRoute {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Confirm Vision Model Route",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.headline)
                Text(route.notice)
                    .font(.subheadline)
                Text(
                    "Requested \(route.requestedRole.displayName): "
                        + "\(route.requestedModelIdentifier ?? "unassigned") "
                        + "→ Vision: \(route.visionModelIdentifier)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Confirm and Send") {
                        controller.confirmPendingVisionRoute()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel Route", role: .cancel) {
                        controller.cancelPendingVisionRoute()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                Color.accentColor.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Confirm image request routing to \(route.visionModelIdentifier)"
            )
            .id(route.visibilityAcknowledgementToken)
            .onAppear {
                _ = controller
                    .acknowledgePendingVisionRouteVisibility(
                        token:
                            route
                                .visibilityAcknowledgementToken
                    )
            }
        }
    }
}

private struct P8VisionAttachmentControls: View {
    @ObservedObject var features: P8FeatureController
    let compact: Bool
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    compact ? "Image Attachments" : "Images and Screenshots",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(compact ? .headline : .title3.bold())
                Spacer()
                P8StatusBadge(
                    text: "\(features.visionAttachments.count)/\(VisionAttachmentLimits.maximumAttachmentCount)",
                    color: features.visionAttachments.isEmpty ? .secondary : .blue
                )
            }

            if !features.visionAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(features.visionAttachments) { attachment in
                            visionThumbnail(attachment)
                        }
                    }
                }
            }

            HStack {
                Button {
                    chooseImages()
                } label: {
                    Label("Choose Images", systemImage: "plus")
                }
                .disabled(
                    features.visionIsProcessing
                        || features.visionAttachments.count
                            >= VisionAttachmentLimits.maximumAttachmentCount
                )
                Button {
                    features.pasteVisionAttachment()
                } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .disabled(features.visionIsProcessing)
                if !features.visionAttachments.isEmpty {
                    Button("Remove All", role: .destructive) {
                        Task { await features.cancelAndClearVisionAttachments() }
                    }
                }
                if features.visionIsProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .buttonStyle(.bordered)

            Text(features.visionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !compact {
                Text("Files are bounded, decoded locally, stripped of metadata, and kept only in protected temporary storage until send or removal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 0)
        .background(
            compact
                ? (isDropTarget
                    ? Color.accentColor.opacity(0.14)
                    : Color(nsColor: .quaternaryLabelColor).opacity(0.28))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [6])
                    )
            }
        }
        .onDrop(
            of: supportedDropTypeIdentifiers,
            isTargeted: $isDropTarget,
            perform: acceptDroppedImages
        )
        .accessibilityHint("Drop PNG, JPEG, HEIC, or HEIF still images here.")
    }

    private func visionThumbnail(
        _ attachment: VisionAttachmentDescriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = NSImage(data: attachment.thumbnailData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: compact ? 72 : 96,
                        height: compact ? 54 : 72
                    )
                    .clipped()
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(attachment.accessibilityLabel)
            }
            Text("\(attachment.pixelSize.width)×\(attachment.pixelSize.height)")
                .font(.caption2)
            Text(ByteCountFormatter.string(
                fromByteCount: Int64(attachment.modelByteCount),
                countStyle: .file
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button("Remove", role: .destructive) {
                features.removeVisionAttachment(attachment.id)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var supportedDropTypeIdentifiers: [String] {
        P8FeatureController.supportedVisionDropTypeIdentifiers
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Choose Images for Agent Loki"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .png,
            .jpeg,
            .heic,
            UTType("public.heif") ?? .image,
        ]
        guard panel.runModal() == .OK else { return }
        features.addVisionFiles(panel.urls, source: .filePicker)
    }

    private func acceptDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        features.acceptDroppedVisionItems(providers)
    }
}

private struct P8WebResearchControls: View {
    @ObservedObject var controller: LokiChatController
    @ObservedObject var features: P8FeatureController
    @State private var inputClassification:
        OllamaWebResearchInputClassification = .operatorAuthored
    @State private var privateRecordUseApproved = false
    @State private var evidenceFollowUpApproved = false

    private var conversationIdentifier: String? {
        controller.activeConversation?.id
    }

    private var conversationPolicyEnabled: Bool {
        guard let conversationIdentifier else { return false }
        return features.webConversationPolicy(
            conversationIdentifier: conversationIdentifier
        )?.webResearchEnabled == true
    }

    private var effectiveWebResearchEnabled: Bool {
        features.webGlobalSettings.providerEnabled
            && features.webGlobalSettings.externalNetworkDisclosureAccepted
            && features.webCredentialConfigured == true
            && conversationPolicyEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Web Research", systemImage: "network")
                    .font(.title3.bold())
                Spacer()
                P8StatusBadge(
                    text:
                        features
                            .signedSmokeWebCredentialSealIsActive
                        ? "Signed-smoke sealed"
                        : (
                            effectiveWebResearchEnabled
                                ? "Enabled for this chat"
                                : "Off"
                        ),
                    color: effectiveWebResearchEnabled ? .green : .secondary
                )
            }

            Text("Web Research contacts disclosed external Ollama endpoints. It never runs implicitly from private Vault content, and it remains separate from local read-only tools.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                P8StatusBadge(
                    text: researchCapacity.label,
                    color: researchCapacity.color
                )
                Text(researchCapacity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                SecureField(
                    "Dedicated Ollama Web Research API key",
                    text: $features.webAPIKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                Button("Store in Keychain", action: features.storeWebAPIKey)
                    .disabled(features.webAPIKeyDraft.isEmpty)
                Button("Refresh Status", action: features.refreshWebCredentialStatus)
            }

            HStack {
                Label(
                    credentialStatus,
                    systemImage: features.webCredentialConfigured == true
                        ? "key.fill"
                        : "key"
                )
                .font(.caption)
                .foregroundStyle(
                    features.webCredentialConfigured == true
                        ? .green
                        : .secondary
                )
                if features.webCredentialConfigured == true {
                    Button("Remove Key", role: .destructive) {
                        features.removeWebAPIKey()
                    }
                    .font(.caption)
                }
            }

            Toggle(
                "I understand that Web Research sends approved queries to external Ollama services.",
                isOn: Binding(
                    get: {
                        features.webGlobalSettings
                            .externalNetworkDisclosureAccepted
                    },
                    set: { accepted in
                        features.updateWebGlobalSettings(
                            providerEnabled: accepted
                                ? features.webGlobalSettings.providerEnabled
                                : false,
                            disclosureAccepted: accepted
                        )
                    }
                )
            )

            Toggle(
                "Enable Ollama Web Research globally",
                isOn: Binding(
                    get: { features.webGlobalSettings.providerEnabled },
                    set: { enabled in
                        features.updateWebGlobalSettings(
                            providerEnabled: enabled,
                            disclosureAccepted: features.webGlobalSettings
                                .externalNetworkDisclosureAccepted
                        )
                    }
                )
            )
            .disabled(
                features.webCredentialConfigured != true
                    || !features.webGlobalSettings
                        .externalNetworkDisclosureAccepted
            )

            Toggle(
                "Enable Web Research for this conversation",
                isOn: Binding(
                    get: { conversationPolicyEnabled },
                    set: { enabled in
                        guard let conversationIdentifier else { return }
                        features.updateWebConversationPolicy(
                            conversationIdentifier: conversationIdentifier,
                            enabled: enabled
                        )
                    }
                )
            )
            .disabled(
                conversationIdentifier == nil
                    || !features.webGlobalSettings.providerEnabled
                    || !features.webGlobalSettings
                        .externalNetworkDisclosureAccepted
                    || features.webCredentialConfigured != true
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Outbound query preview")
                    .font(.caption.weight(.semibold))
                Picker("Operation", selection: $features.webPreviewOperation) {
                    Text("Search").tag(P8WebResearchToolName.search)
                    Text("Fetch URL").tag(P8WebResearchToolName.fetch)
                }
                .pickerStyle(.segmented)
                Picker("Input classification", selection: $inputClassification) {
                    ForEach(
                        OllamaWebResearchInputClassification.allCases,
                        id: \.self
                    ) { classification in
                        Text(
                            classification.rawValue
                                .replacingOccurrences(of: "_", with: " ")
                                .capitalized
                        )
                        .tag(classification)
                    }
                }
                if inputClassification == .privateRecord {
                    Toggle(
                        "I explicitly approve using this private record in the outbound request.",
                        isOn: $privateRecordUseApproved
                    )
                }
                if inputClassification == .untrustedWebEvidence {
                    Toggle(
                        "I explicitly approve this follow-up based on untrusted web evidence.",
                        isOn: $evidenceFollowUpApproved
                    )
                }
                TextField(
                    features.webPreviewOperation == .search
                        ? "Enter the exact search query"
                        : "Enter the exact HTTPS URL",
                    text: $features.webQueryPreview,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Approve Exact Preview") {
                        features.approveWebQueryPreview(
                            inputClassification: inputClassification,
                            privateRecordUseApproved:
                                privateRecordUseApproved,
                            evidenceFollowUpApproved:
                                evidenceFollowUpApproved
                        )
                    }
                    .disabled(
                        !effectiveWebResearchEnabled
                            || features.webQueryPreview.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                    if features.webQueryPreviewApproved {
                        Button("Revoke Approval", role: .destructive) {
                            features.clearWebQueryPreviewApproval()
                        }
                    }
                }
                .buttonStyle(.bordered)

                if features.webQueryPreviewApproved {
                    Label(
                        "Approved exact preview: \(features.webQueryPreview)",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                } else {
                    Text("No outbound query is approved. Changing the draft revokes the prior preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(features.webStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if features
                .shouldRefreshWebCredentialStatusOnAppear {
                features.refreshWebCredentialStatus()
            }
        }
        .disabled(features.signedSmokeWebCredentialSealIsActive)
    }

    private var credentialStatus: String {
        if let reason =
                features
                    .signedSmokeWebResearchDisabledReasonCode {
            return reason.displayText
        }
        if features.webCredentialConfigured == true {
            return "Dedicated Keychain credential configured"
        }
        if features.webCredentialConfigured == false {
            return "No dedicated credential configured"
        }
        return "Credential status not yet checked"
    }

    private var researchCapacity:
        (label: String, detail: String, color: Color)
    {
        let eligible = controller.modelRoleAssignments.first {
            $0.role == .primaryAgent
                && $0.isExecutable
                && $0.verifiedToolSupport == .readOnly
        } ?? controller.modelRoleAssignments.first {
            $0.role == .textFallback
                && $0.isExecutable
                && $0.verifiedToolSupport == .readOnly
        }
        guard let eligible,
              let model = eligible.effectiveModelIdentifier,
              let tokens = eligible.effectiveContextTokens
        else {
            return (
                "Unavailable",
                "Assign and assess a local Primary or Text fallback with verified read-only tool support.",
                .secondary
            )
        }
        let mode = OllamaWebResearchContextMode(
            effectiveContextTokens: tokens
        )
        let role = eligible.role == .primaryAgent
            ? "Primary"
            : "Text fallback"
        switch mode {
        case .full:
            return (
                "Full context",
                "\(role) · \(model) · \(tokens.formatted()) effective tokens. Bounds: \(mode.userVisibleBoundsDescription).",
                .green
            )
        case .limited:
            return (
                "Limited context",
                "\(role) · \(model) · \(tokens.formatted()) effective tokens. Below 65,536; bounds shrink to \(mode.userVisibleBoundsDescription).",
                .orange
            )
        }
    }
}

private struct P8StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct LiveLokiChatPrivacySection: View {
    @ObservedObject var controller: LokiChatController
    @ObservedObject var slackController: SlackAppController
    @State private var draft: LokiChatPrivacySettings

    init(controller: LokiChatController, slackController: SlackAppController) {
        self.controller = controller
        self.slackController = slackController
        _draft = State(initialValue: controller.privacySettings)
    }

    var body: some View {
        Section("Agent Loki Chat") {
            Toggle("Store local chat history", isOn: $draft.storeLocalHistory)
            Picker("Conversation retention", selection: $draft.retentionPolicy) {
                ForEach(LokiChatRetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            if draft.retentionPolicy == .custom {
                Stepper(
                    "Retain for \(draft.customRetentionDays ?? 90) days",
                    value: Binding(
                        get: { draft.customRetentionDays ?? 90 },
                        set: { draft.customRetentionDays = $0 }
                    ),
                    in: LokiChatLimits.minimumCustomRetentionDays...LokiChatLimits.maximumCustomRetentionDays
                )
            }
            Toggle(
                "Include source excerpts in stored conversations",
                isOn: $draft.includeSourceExcerpts
            )
            Toggle("Allow feed evidence in Agent Loki Chat", isOn: $draft.allowFeedEvidence)
            if !slackController.workspaces.isEmpty {
                ForEach(slackController.workspaces) { workspace in
                    Toggle(
                        "Allow selected Slack evidence · \(workspace.teamName)",
                        isOn: Binding(
                            get: { controller.workspaceAllowsSlackEvidence(workspace.id) },
                            set: { controller.setWorkspaceSlackEvidence(workspace.id, allowed: $0) }
                        )
                    )
                    .disabled(!workspace.localModelConsent)
                }
                Text("Slack evidence requires both the existing workspace local-model consent and this separate Agent Loki Chat permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Save Chat Privacy Settings") {
                draft = draft.normalized()
                _ = controller.updatePrivacySettings(draft)
                draft = controller.privacySettings
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(LokiChatPresentation.localHistoryDisclosure(
                storeLocalHistory: draft.storeLocalHistory
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LokiChatPresentation.noDurableMemoryDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(controller.isGenerating)
        .onChange(of: controller.privacySettings) { previous, current in
            draft = LokiChatPresentation.reconciledPrivacyDraft(
                draft,
                previousCommitted: previous,
                newCommitted: current
            )
        }
    }
}
