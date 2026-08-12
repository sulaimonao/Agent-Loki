import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(
                NavigationDestination.allCases,
                selection: Binding(
                    get: { model.selection },
                    set: { model.navigate(to: $0) }
                )
            ) { destination in Label(destination.rawValue, systemImage: icon(destination)).tag(destination) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            Group {
                switch model.selection {
                case .today: TodayView()
                case .chat:
                    if let controller = model.chatController {
                        LiveLokiChatWorkspaceView(model: model, controller: controller)
                    } else {
                        ContentUnavailableView(
                            "Agent Loki Chat Unavailable",
                            systemImage: "bubble.left.and.exclamationmark.bubble.right",
                            description: Text("Loki Brief remains usable without chat. Reopen the app after resolving the local persistence error.")
                        )
                    }
                case .sources: SourcesView()
                case .vault: VaultView()
                case .models: ModelsView()
                case .history: HistoryView()
                case .delivery:
                    if let controller = model.p5Controller { P5DeliveryView(controller: controller) }
                    else { ContentUnavailableView("Delivery Unavailable", systemImage: "calendar.badge.exclamationmark", description: Text("The existing local store was preserved. Reopen Loki Brief after resolving the persistence error.")) }
                case .settings: SettingsView()
                case .privacy: PrivacyView()
                }
            }.environmentObject(model)
        }
        .alert("Loki Brief", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(LokiBriefPresentation.message(for: model.errorMessage ?? "")) }
    }
    private func icon(_ d: NavigationDestination) -> String { switch d { case .today: "sun.horizon"; case .chat: "bubble.left.and.text.bubble.right"; case .sources: "dot.radiowaves.left.and.right"; case .vault: "archivebox"; case .models: "cpu"; case .history: "clock.arrow.circlepath"; case .delivery: "calendar.badge.clock"; case .settings: "gearshape"; case .privacy: "hand.raised" } }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: model.density == .compact ? 16 : 26) {
                if model.isPresentingHistoricalBrief {
                    HStack {
                        Label(
                            "Viewing historical brief · \(model.brief.resolvedBriefingDay.formatted(.complete))",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.callout.weight(.semibold))
                        Spacer()
                        Button("Return to Today") { model.openToday() }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(modeLabel, systemImage: model.brief.generation.providerKind == "ollama" ? "cpu" : "checkmark.seal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(model.brief.title).font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text(model.brief.summary).font(.title3).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading)
                    }
                    Spacer()
                    if isRefreshing { Button("Cancel", role: .cancel) { model.cancelRefresh() } }
                    Button("Refresh All", systemImage: "arrow.clockwise") { model.refreshAllFeeds() }.buttonStyle(.borderedProminent).disabled(isRefreshing || !model.subscriptions.contains(where: \.enabled))
                }
                HStack(spacing: 18) {
                    Label(LokiBriefPresentation.label(for: model.refreshState.rawValue), systemImage: "network")
                    Label(model.brief.resolvedBriefingDay.formatted(.complete), systemImage: "calendar")
                    Label("\(model.brief.itemCount) items", systemImage: "list.bullet")
                    if let modelName = model.brief.generation.modelName, model.brief.generation.providerKind == "ollama" { Label(modelName, systemImage: "cpu") }
                }.font(.subheadline).foregroundStyle(.secondary)
                Text(model.refreshMessage).font(.callout).foregroundStyle(.secondary)
                if let failure = model.brief.partialFailureMessage { Label(LokiBriefPresentation.message(for: failure), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) }
                if let controller = model.chatController {
                    LiveAskAgentLokiPanel(model: model, controller: controller)
                }
                if model.brief.sections.isEmpty {
                    ContentUnavailableView("No Briefing Evidence", systemImage: "newspaper", description: Text("Add a public HTTPS feed in Sources and refresh it manually or through an enabled Delivery schedule while Loki Brief is running. The last valid brief is preserved when refresh fails."))
                }
                ForEach(model.brief.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.title2.weight(.semibold))
                        if let summary = section.summary { Text(summary).foregroundStyle(.secondary) }
                        ForEach(section.items) { item in
                            BriefItemRow(
                                item: item,
                                density: model.density,
                                toggle: { model.toggleRead(item) },
                                openSlack: { model.openSlackEvidence(item.id) }
                            )
                        }
                    }
                }
            }.padding(32)
        }.navigationTitle(model.isPresentingHistoricalBrief ? "History" : "Today")
    }
    private var isRefreshing: Bool { ![.idle, .complete, .partial, .cancelled, .failed].contains(model.refreshState) }
    private var modeLabel: String {
        if model.isPresentingHistoricalBrief { return "Historical brief · preserved local history" }
        if let modelName = model.brief.generation.modelName, model.brief.generation.providerKind == "ollama" { return "Generated locally with Ollama · \(modelName)" }
        if model.brief.status == .preview { return "Preview data · synthetic fixture" }
        return "Deterministic briefing · source-authoritative"
    }
}

struct BriefItemRow: View {
    let item: BriefItem
    let density: BriefingDensity
    let toggle: () -> Void
    let openSlack: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityLabel(item.priority.rawValue)
                Text(item.title).font(.headline).foregroundStyle(item.isRead ? .secondary : .primary)
                Spacer()
                Button(item.isRead ? "Mark Unread" : "Mark Read", action: toggle).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(item.summary).foregroundStyle(.secondary)
            if let explanation = item.rankingExplanation { Label(explanation, systemImage: "line.3.horizontal.decrease.circle").font(.caption).foregroundStyle(.secondary) }
            if let corroboratingSources = item.corroboratingSourceIDs, corroboratingSources.count > 1 { Label("Corroborated by \(corroboratingSources.count) subscribed sources", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary) }
            if let unavailable = item.availabilityMessage { Label(unavailable, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) }
            if let slack = item.slackAttribution {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Label("Slack", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                        Text(slack.workspaceName)
                        Text("•")
                        Text("#\(slack.channelName)")
                        Text("•")
                        Text(slack.authorName)
                        Text("•")
                        Text(slack.messageTimestamp.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Label(priorityReason(slack.priorityReasonCode), systemImage: "arrow.up.arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if slack.locallyGenerated {
                        Label("Presentation summary generated locally with the selected Ollama model", systemImage: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text(item.source.name); Text("•")
                Text(item.provenance.origin == .generated ? "Generated presentation text" : "Source evidence"); Text("•")
                Text("Published \(item.provenance.publicationDate.formatted(date: .abbreviated, time: .shortened))"); Text("•")
                Text("Retrieved \(item.provenance.retrievedAt.formatted(date: .omitted, time: .shortened))")
                Spacer()
                if item.provenance.isSynthetic { Text("Synthetic fixture") }
            }.font(.caption).foregroundStyle(.tertiary)
            if item.slackAttribution != nil {
                Button("Open in Slack", systemImage: "arrow.up.forward.app", action: openSlack)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.link)
            } else if let directURL = item.provenance.directURL, directURL.scheme == "https" {
                Link("Open Source", destination: directURL).font(.caption.weight(.semibold))
            }
        }.padding(density == .compact ? 10 : 16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .contain)
    }
    private var color: Color { switch item.priority { case .urgent: .red; case .high: .orange; case .normal: .blue; case .low: .gray } }
    private func priorityReason(_ reasonCode: String) -> String {
        switch reasonCode {
        case "slack_direct_mention": "Needs attention because this message directly mentions the authorized Slack user."
        case "slack_weighted_urgency": "Needs attention because a highly weighted selected channel contains a bounded urgency phrase."
        default: "Included in Messages and Collaboration by deterministic recency and selected-channel weighting."
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var addFeed = false
    @State private var pendingRemoval: FeedSubscription?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { PageHeader(title: "Sources", subtitle: "Connect only the sources you choose. Slack and Discord use explicit read authority; Support Email imports selected local files; public feeds remain unauthenticated. Automatic connector sync is off by default."); Spacer(); Button("Refresh All Enabled Feeds") { model.refreshAllFeeds() }.disabled(!model.subscriptions.contains(where: \.enabled)); Button("Add Feed", systemImage: "plus") { addFeed = true }.buttonStyle(.borderedProminent) }
                SlackSourcesSection(controller: model.slackController)
                ConnectorSourcesSection(controller: model.connectorSourcesController)
                if model.subscriptions.isEmpty { ContentUnavailableView("No Feed Subscriptions", systemImage: "dot.radiowaves.left.and.right", description: Text("Add an unauthenticated public HTTPS RSS, Atom, or JSON Feed.")) }
                ForEach(model.subscriptions) { subscription in
                    FeedSubscriptionCard(subscription: subscription, refreshState: model.sourceRefreshStates[subscription.id] ?? .idle, toggle: { model.setFeedEnabled(id: subscription.id, enabled: $0) }, saveTitle: { model.updateFeedTitle(id: subscription.id, title: $0) }, setWeight: { model.updateFeedWeight(id: subscription.id, weight: $0) }, refresh: { model.refreshFeed(id: subscription.id) }, remove: { pendingRemoval = subscription })
                }
                Divider()
                ForEach(model.sources.filter { ![SourceKind.previewFixtures, .newsFeeds, .slack, .discord, .supportEmail].contains($0.kind) }) { source in StatusRow(name: source.name, detail: source.detail, state: source.state.rawValue, active: false) }
            }.padding(32)
        }.navigationTitle("Sources")
            .sheet(isPresented: $addFeed) { AddFeedSheet().environmentObject(model) }
            .confirmationDialog("Remove \(pendingRemoval?.title ?? "this feed")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) { Button("Remove Feed", role: .destructive) { if let id = pendingRemoval?.id { model.removeFeed(id: id) }; pendingRemoval = nil }; Button("Cancel", role: .cancel) { pendingRemoval = nil } } message: { Text("Stored entries for this subscription will also be removed. Existing brief-history snapshots remain attributable and unchanged.") }
    }
}

private struct AddFeedSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var saveUnavailable = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Add Feed", subtitle: "Loki Brief validates the URL, retrieves one bounded feed response, parses it, and persists only after a supported format is confirmed.")
            TextField("https://example.com/feed.xml", text: $url).textFieldStyle(.roundedBorder)
            TextField("Display name (optional)", text: $title).textFieldStyle(.roundedBorder)
            Toggle("If retrieval fails, save explicitly as currently unavailable", isOn: $saveUnavailable)
            Text("HTTPS only. Local, private-network, authenticated, and Ollama targets are rejected.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.disabled(saving); Button(saving ? "Validating…" : "Save") { saving = true; Task { let saved = await model.addFeed(urlText: url, title: title, saveWhenUnavailable: saveUnavailable); saving = false; if saved { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 560)
    }
}

private struct FeedSubscriptionCard: View {
    let subscription: FeedSubscription
    let refreshState: FeedRefreshState
    let toggle: (Bool) -> Void
    let saveTitle: (String) -> Void
    let setWeight: (Double) -> Void
    let refresh: () -> Void
    let remove: () -> Void
    @State private var title: String
    init(subscription: FeedSubscription, refreshState: FeedRefreshState, toggle: @escaping (Bool) -> Void, saveTitle: @escaping (String) -> Void, setWeight: @escaping (Double) -> Void, refresh: @escaping () -> Void, remove: @escaping () -> Void) {
        self.subscription = subscription; self.refreshState = refreshState; self.toggle = toggle; self.saveTitle = saveTitle; self.setWeight = setWeight; self.refresh = refresh; self.remove = remove; _title = State(initialValue: subscription.title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Toggle("", isOn: Binding(get: { subscription.enabled }, set: toggle)).labelsHidden(); TextField("Feed name", text: $title, onCommit: { saveTitle(title) }).font(.headline); Spacer(); Text(LokiBriefPresentation.label(for: refreshState == .idle ? subscription.state.rawValue : refreshState.rawValue)).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
            Text(subscription.canonicalURL.absoluteString).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            HStack { Text("Format: \(LokiBriefPresentation.feedFormat(for: subscription.format.rawValue))"); Text("•"); Text(subscription.lastAttemptedAt.map { "Last attempt \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Never attempted"); Text("•"); Text(subscription.lastSuccessfulAt.map { "Last success \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No successful refresh"); if let status = subscription.lastHTTPStatus { Text("• HTTP \(status)") } }.font(.caption).foregroundStyle(.secondary)
            if let failure = subscription.failure { Label(failure.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack { Text("Source weight").font(.caption); Slider(value: Binding(get: { subscription.weight }, set: setWeight), in: 0.5...2, step: 0.1).frame(width: 180); Text(subscription.weight.formatted(.number.precision(.fractionLength(1)))).font(.caption.monospacedDigit()); Spacer(); Button("Refresh Feed", action: refresh).disabled(!subscription.enabled); Button("Remove", role: .destructive, action: remove) }
        }.padding(17).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ModelsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Local Models", subtitle: "Ollama is an optional, fixed-loopback presentation-text provider. Install and manage models in the Ollama application.")
                StatusRow(name: "Deterministic briefing engine", detail: "Always available. It remains authoritative for evidence, rank, order, sections, links, and fallback.", state: "available", active: true)
                StatusRow(name: "Ollama", detail: LokiBriefPresentation.message(for: model.localGenerationMessage), state: model.ollamaStatus.state.rawValue, active: [.connected, .modelSelected].contains(model.ollamaStatus.state))
                if let checkedAt = model.ollamaStatus.checkedAt { Text("Last check attempt \(checkedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if let successfulAt = model.ollamaStatus.lastSuccessfulCheckAt { Text("Last successful check \(successfulAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if let generatedAt = model.lastLocalGenerationAt { Text("Last successful local generation \(generatedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if let controller = model.chatController {
                    LiveAgentLokiModelReadinessSection(controller: controller)
                }
                HStack { Button("Check Ollama") { model.checkOllama() }.buttonStyle(.borderedProminent); Button("Refresh Installed Models") { model.checkOllama() }; Spacer(); Button("Disable Ollama", role: .destructive) { model.disableOllama() } }
                Toggle("Use Ollama for Brief Summaries", isOn: Binding(get: { model.localGenerationEnabled }, set: model.setLocalGenerationEnabled))
                Picker("Brief-summary model", selection: Binding(get: { model.selectedModelID }, set: model.selectOllamaModel)) {
                    Text("No model selected").tag(String?.none)
                    ForEach(model.localModels) { localModel in Text(localModel.name).tag(Optional(localModel.id)) }
                }.disabled(model.localModels.isEmpty)
                Button("Test Local Summary") { model.testLocalSummary() }.disabled(!model.localGenerationEnabled || model.ollamaStatus.state != .modelSelected)
                ForEach(model.localModels) { localModel in
                    VStack(alignment: .leading, spacing: 5) { Text(localModel.name).font(.headline); HStack { if let parameterSize = localModel.parameterSize { Text(parameterSize) }; if let quantization = localModel.quantizationLevel { Text("• \(quantization)") }; if let size = localModel.sizeBytes { Text("• \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") } }.font(.caption).foregroundStyle(.secondary) }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Not available: model pull, push, create, copy, delete, embeddings, web research, write tools, arbitrary network access, cloud endpoints, or Ollama application lifecycle control. Agent Loki uses only its closed read-only local tool registry.").font(.callout).foregroundStyle(.secondary)
            }.padding(32)
        }.navigationTitle("Local Models")
    }
}

struct StatusRow: View {
    let name: String; let detail: String; let state: String; let active: Bool
    var body: some View { HStack(alignment: .top, spacing: 16) { Image(systemName: active ? "checkmark.circle.fill" : "circle.dashed").font(.title2).foregroundStyle(active ? .green : .secondary); VStack(alignment: .leading, spacing: 5) { HStack { Text(name).font(.headline); Text(LokiBriefPresentation.label(for: state)).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) }; Text(detail).foregroundStyle(.secondary) }; Spacer() }.padding(17).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)) }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if model.history.isEmpty { ContentUnavailableView("No Stored Briefs", systemImage: "clock.arrow.circlepath", description: Text("Refresh an enabled source or generate a brief to create local history.")) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        PageHeader(
                            title: "History",
                            subtitle: "Persisted evidence order and generation attribution. Historical briefs are grouped by their recorded local briefing day and are never silently regenerated."
                        )
                        ForEach(BriefHistoryGrouping.group(model.history)) { group in
                            Text(group.day.formatted(.complete))
                                .font(.title3.weight(.semibold))
                                .padding(.top, 8)
                            ForEach(group.entries) { entry in historyRow(entry) }
                        }
                    }
                    .padding(32)
                }
            }
        }.navigationTitle("History")
    }

    private func historyRow(_ entry: BriefHistoryEntry) -> some View {
        Button { model.openHistory(id: entry.id) } label: {
            HStack(spacing: 16) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.headline)
                    Text(entry.briefingDay.formatted(.complete)).foregroundStyle(.secondary)
                    if let partial = entry.partialFailureMessage {
                        Text(LokiBriefPresentation.message(for: partial)).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(entry.itemCount) items")
                    Text(generationLabel(entry)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func generationLabel(_ entry: BriefHistoryEntry) -> String {
        if entry.providerKind == "ollama" { return entry.modelName.map { "Ollama · \($0)" } ?? "Ollama" }
        if entry.providerKind == "deterministic" {
            return entry.modelName.map { "Deterministic fallback · attempted \($0)" } ?? "Deterministic"
        }
        return "Preview r\(entry.fixtureRevision)"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section("Briefing") {
                Picker("Density", selection: Binding(get: { model.density }, set: model.updateDensity)) { ForEach(BriefingDensity.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Deterministic-only briefing mode", isOn: Binding(get: { model.settings.deterministicOnly }, set: model.setDeterministicOnly))
                TextField("Topic preferences, comma separated", text: Binding(get: { model.p2Settings.topicPreferences }, set: model.setTopicPreferences))
                Stepper("Feed retention: \(model.p2Settings.feedRetentionDays) days", value: Binding(get: { model.p2Settings.feedRetentionDays }, set: model.setFeedRetentionDays), in: 1...365)
                Stepper("Entries per feed: \(model.p2Settings.retainedEntriesPerFeed)", value: Binding(get: { model.p2Settings.retainedEntriesPerFeed }, set: model.setRetainedEntriesPerFeed), in: 1...FeedLimits.maximumRetainedEntriesPerFeed)
                Stepper("Local generation timeout: \(model.p2Settings.generationTimeoutSeconds)s", value: Binding(get: { model.p2Settings.generationTimeoutSeconds }, set: model.setGenerationTimeoutSeconds), in: 5...120)
            }
            if let controller = model.chatController {
                LiveLokiChatPrivacySection(
                    controller: controller,
                    slackController: model.slackController
                )
            }
            Section("Local data") { Button("Delete All Local Data", role: .destructive) { confirmDelete = true } }
            SecureUpdateSettingsSection()
            SlackSettingsFormSection(controller: model.slackController)
            Section("V1 boundaries") { Text("Slack DMs, posting, and attachment bodies; Discord DMs, writes, moderation, and attachment bodies; IMAP, provider OAuth, SMTP, and Maildir; cloud scheduling; and cloud archive storage are not offered. Billing is not configured, and every implemented local feature is available without payment or a Loki account.").foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("Settings").confirmationDialog("Delete all Loki Brief local data?", isPresented: $confirmDelete) { Button("Delete All Local Data", role: .destructive) { Task { await model.deleteAllDataIncludingSlackCredentials() } }; Button("Cancel", role: .cancel) {} } message: { Text("This cancels active work and removes conversations, chat messages, tool receipts, model assessments, the Vault database/WAL/SHM/export staging, account controls, backfill state, settings, feeds, brief history, local-model metadata, Slack evidence, and Slack credentials. Installed Ollama models and external provider data remain untouched. A partial cleanup is reported truthfully.") }
    }
}

struct PrivacyView: View {
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "About Agent Loki", subtitle: "Agent Loki V1.0.0 Release Candidate 3 · native, local-first macOS knowledge and assistant application.")
        GroupBox("Release and license") { Text("Source release: v1.0.0-rc.3. Native bundle: 1.0.0 (3). Licensed under Apache License 2.0. Binary distribution readiness is recorded separately in the RC3 verification packet.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Identity") { Text("The application identity is the current macOS user. Slack and Discord authorization connect external read-only sources; neither creates a Loki cloud account. Email import uses only files you select.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Privacy") { Text("Loki Brief stores bounded control data in local SwiftData and admitted source evidence with provenance in the local Loki Vault SQLite archive. Slack and Discord credentials remain only in isolated Data Protection Keychain namespaces. Email file bookmarks are read-only. Attachment bodies, raw API responses, hidden reasoning, and telemetry are not retained by these connectors.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Local at-rest protection") { Text("Vault content is not application-level encrypted. Protection relies on the App Sandbox, current-user file permissions, restrictive Vault file permissions, macOS disk protection such as FileVault when enabled, and separate Keychain isolation for credentials. Local .lokivault exports are unencrypted.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        SlackPrivacyDisclosure()
        GroupBox("Discord setup help") { Text("Use an official bot with Server Install, the bot scope, View Channel, and Read Message History (permission integer 66560). Do not grant Send Messages, Manage Messages, moderation, or Administrator. Enable the privileged Message Content intent only when Discord permits it; otherwise Loki Brief reports degraded metadata-only access. DMs are disabled.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Email import help") { Text("Choose .eml or .mbox files in Sources. HTML is converted to inert text without fetching remote resources. IMAP, Gmail or Microsoft OAuth, Maildir, SMTP, and outbound mail are not included in V1. Removing file access preserves imported data; Remove Local Data is a separate confirmed action.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Troubleshooting and deletion") { Text("Connector cards show the latest reason code, counts, and last successful sync. Revalidate credentials or reselect an email file when authorization is unavailable. Disconnect removes credentials or file access without deleting retained records. Use Remove Local Data separately, or Delete All Local Data in Settings for a full local reset.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Network boundary") { Text("Feed networking begins only at saved public HTTPS URLs. Slack uses its fixed OAuth/Web API surface. Discord Connector V1 uses fixed GET-only API v10 REST endpoints and rejects redirects and writes. Email parsing performs no network access. Ollama is fixed to numeric loopback. There is no incoming server, Loki cloud archive, telemetry, automatic connector polling, daemon, helper, or remote delivery service.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        GroupBox("Authority") { Text("The deterministic engine controls evidence inclusion, rank, order, sections, links, read state, and fallback. Connector records enter Vault through an atomic provenance gate. Local-model indexing remains an explicit opt-in and cannot grant connector write or publication authority.").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
    }.padding(32) }.navigationTitle("About & Privacy") }
}

struct PageHeader: View { let title: String; let subtitle: String; var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 32, weight: .semibold, design: .rounded)); Text(subtitle).font(.title3).foregroundStyle(.secondary).frame(maxWidth: 760, alignment: .leading) }.padding(.bottom, 8) } }
