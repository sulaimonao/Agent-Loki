import SwiftUI
import UniformTypeIdentifiers

struct ConnectorSourcesSection: View {
    @ObservedObject var controller: ConnectorSourcesController
    @State private var showDiscordSetup = false
    @State private var discordSelectionStatusID: String?
    @State private var pendingDisconnect: ConnectorStatusSnapshot?
    @State private var pendingDataRemoval: ConnectorStatusSnapshot?
    @State private var showEmailImporter = false
    @State private var allowEmailLocalModel = false
    @State private var emailOperationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            discordSection
            Divider()
            emailSection
            Divider()
            AttachedDataSourcesSection(
                controller: controller.attachedDataSourcesController
            )
            if let message = controller.statusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showDiscordSetup) {
            DiscordSetupSheet(controller: controller)
        }
        .sheet(
            isPresented: Binding(
                get: { discordSelectionStatusID != nil },
                set: { if !$0 { discordSelectionStatusID = nil } }
            )
        ) {
            if let statusID = discordSelectionStatusID {
                DiscordSourceSelectionSheet(
                    controller: controller,
                    statusID: statusID
                )
            }
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.kind.displayName ?? "connector")?",
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            )
        ) {
            Button("Disconnect", role: .destructive) {
                guard let status = pendingDisconnect else { return }
                pendingDisconnect = nil
                if status.kind == .discord {
                    Task { _ = await controller.disconnectDiscord(statusID: status.id) }
                } else {
                    _ = controller.disconnectEmail(statusID: status.id)
                }
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: {
            Text("The credential or read-only file authorization will be removed. Imported local data is preserved until you separately choose Remove Local Data.")
        }
        .confirmationDialog(
            "Remove retained local data?",
            isPresented: Binding(
                get: { pendingDataRemoval != nil },
                set: { if !$0 { pendingDataRemoval = nil } }
            )
        ) {
            Button("Remove Local Data", role: .destructive) {
                guard let statusID = pendingDataRemoval?.id else { return }
                pendingDataRemoval = nil
                Task { _ = await controller.removeLocalData(statusID: statusID) }
            }
            Button("Cancel", role: .cancel) { pendingDataRemoval = nil }
        } message: {
            Text("This permanently removes this source's admitted Vault records, revisions, and tombstones. Its credential or file authorization is unchanged.")
        }
    }

    private var discordStatuses: [ConnectorStatusSnapshot] {
        controller.statuses.filter { $0.kind == .discord }
    }

    private var emailStatuses: [ConnectorStatusSnapshot] {
        controller.statuses.filter { $0.kind == .supportEmail }
    }

    private var discordSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Discord").font(.title2.weight(.semibold))
                    Text("Read-only REST history from explicitly selected servers, channels, and threads. Direct messages, writes, moderation, reactions, and attachment-body downloads are disabled.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect Discord", systemImage: "link.badge.plus") {
                    showDiscordSetup = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the read-only Discord bot setup form")
            }

            if discordStatuses.isEmpty {
                ContentUnavailableView(
                    "No Discord source connected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a Discord bot with server installation, the bot scope, View Channel, and Read Message History. Message Content access may require Discord approval.")
                )
            } else {
                ForEach(discordStatuses) { status in discordCard(status) }
            }
        }
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Support Email").font(.title2.weight(.semibold))
                    Text("Import local RFC 5322 .eml or .mbox files. Parsing is local; HTML is converted to inert text, and remote images, scripts, tracking pixels, and attachment bodies are never fetched.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Email File…", systemImage: "tray.and.arrow.down") {
                    showEmailImporter = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens a read-only file picker for EML or MBOX")
                .fileImporter(
                    isPresented: $showEmailImporter,
                    allowedContentTypes: Self.emailTypes,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case let .success(urls):
                        guard let url = urls.first else { return }
                        emailOperationTask = Task { @MainActor in
                            _ = await controller.importEmail(
                                from: url,
                                allowLocalModel: allowEmailLocalModel
                            )
                            emailOperationTask = nil
                        }
                    case let .failure(error):
                        let value = error as NSError
                        guard value.domain != NSCocoaErrorDomain
                                || value.code != NSUserCancelledError
                        else { return }
                        controller.reportEmailFilePickerFailure()
                    }
                }
            }
            Toggle(
                "Allow newly imported email text in explicitly rebuilt local-model indexes",
                isOn: $allowEmailLocalModel
            )
            .accessibilityHint("Off by default. This does not enable cloud transmission or attachment-body indexing.")
            Text("Archive-only is the default. IMAP, Gmail or Microsoft OAuth, SMTP, Maildir, outbound mail, and remote attachment fetching are not included in V1.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if emailStatuses.isEmpty {
                ContentUnavailableView(
                    "No email files imported",
                    systemImage: "envelope.open",
                    description: Text("Choose a synthetic or user-authorized .eml or .mbox file. Loki Brief stores a read-only security-scoped bookmark for explicit future imports.")
                )
            } else {
                ForEach(emailStatuses) { status in emailCard(status) }
            }
        }
    }

    private func discordCard(_ status: ConnectorStatusSnapshot) -> some View {
        let busy = controller.activeStatusIdentifiers.contains(status.id)
        let discovery = controller.discordDiscoveryByStatusID[status.id]
        let selections = controller.discordSelections(statusID: status.id)
        return VStack(alignment: .leading, spacing: 12) {
            connectorHeader(status, systemImage: "bubble.left.and.text.bubble.right")
            Text("\(status.selectedSourceIdentifiers.count) selected channels or threads · manual sync only")
                .foregroundStyle(.secondary)
            if !selections.isEmpty {
                DisclosureGroup("Selected Discord sources") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(selections) { selection in
                            Text(discordSelectionLabel(selection))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    discordSelectionAccessibilityLabel(selection)
                                )
                        }
                    }
                    .padding(.top, 5)
                }
            }
            connectorMetrics(status)
            if let discovery {
                Text("Discovered \(discovery.channels.count) readable channels and \(discovery.threads.count) threads. DMs skipped: \(discovery.skippedDirectMessageCount).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(
                "Allow selected Discord excerpts in explicitly rebuilt local-model indexes",
                isOn: Binding(
                    get: { status.localModelConsentEnabled },
                    set: {
                        _ = controller.setDiscordLocalModelConsent(
                            statusID: status.id,
                            enabled: $0
                        )
                    }
                )
            )
            .accessibilityHint("Off by default and limited to local models")
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        Task { await controller.cancel(statusID: status.id) }
                    }
                } else {
                    if status.state == .disconnected || status.state == .failed {
                        Button("Revalidate", systemImage: "key") {
                            Task { _ = await controller.resumeDiscord(statusID: status.id) }
                        }
                    }
                    Button("Discover", systemImage: "arrow.clockwise") {
                        Task { _ = await controller.discoverDiscord(statusID: status.id) }
                    }
                    Button("Choose Channels", systemImage: "checklist") {
                        discordSelectionStatusID = status.id
                    }
                    .disabled(discovery == nil)
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { _ = await controller.syncDiscord(statusID: status.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(status.selectedSourceIdentifiers.isEmpty)
                }
                Spacer()
                Button("Disconnect…", role: .destructive) {
                    pendingDisconnect = status
                }
                .disabled(busy || status.credentialReference == nil)
                Button("Remove Local Data…", role: .destructive) {
                    pendingDataRemoval = status
                }
                .disabled(busy || status.importedItemCount == 0)
            }
        }
        .padding(17)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func emailCard(_ status: ConnectorStatusSnapshot) -> some View {
        let busy = controller.activeStatusIdentifiers.contains(status.id)
        let accessState = controller.emailAccessState(statusID: status.id)
        let accessAvailable = accessState == .available
        return VStack(alignment: .leading, spacing: 12) {
            connectorHeader(status, systemImage: "envelope")
            Text(emailAccessDescription(accessState))
                .foregroundStyle(.secondary)
            Text(status.localModelConsentEnabled
                 ? "Import policy: local semantic index allowed"
                 : "Import policy: archive only")
                .font(.caption)
                .foregroundStyle(.secondary)
            connectorMetrics(status)
            if status.privacyClassification == .localImportedMailbox {
                Toggle(
                    "Allow imported email text in explicitly rebuilt local-model indexes",
                    isOn: Binding(
                        get: { status.localModelConsentEnabled },
                        set: {
                            _ = controller.setEmailLocalModelConsent(
                                statusID: status.id,
                                enabled: $0
                            )
                        }
                    )
                )
                .accessibilityHint("Revocable local-model consent; no cloud transmission or attachment-body indexing")
            } else {
                Text("Local-model indexing remains unavailable for this archive-only import. Re-import the selected file with the explicit opt-in to change its policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        emailOperationTask?.cancel()
                    }
                    .disabled(emailOperationTask == nil)
                } else {
                    Button("Import New Content", systemImage: "arrow.triangle.2.circlepath") {
                        emailOperationTask = Task { @MainActor in
                            _ = await controller.syncEmail(statusID: status.id)
                            emailOperationTask = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!accessAvailable)
                }
                Spacer()
                Button("Remove File Access…", role: .destructive) {
                    pendingDisconnect = status
                }
                .disabled(busy || !accessAvailable)
                Button("Remove Local Data…", role: .destructive) {
                    pendingDataRemoval = status
                }
                .disabled(busy || status.importedItemCount == 0)
            }
        }
        .padding(17)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func connectorHeader(
        _ status: ConnectorStatusSnapshot,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.displayName).font(.headline)
                Text("State: \(status.state.rawValue.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption.weight(.semibold))
            }
            Spacer()
            Text(status.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }

    private func connectorMetrics(_ status: ConnectorStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.lastSuccessfulSync.map {
                "Last successful sync \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "No successful sync yet")
            Text("Imported \(status.importedItemCount) · skipped \(status.skippedItemCount) · attachments \(status.attachmentCount)")
            if let retry = status.retryAfter, retry > .now {
                Text("Retry after \(retry.formatted(date: .abbreviated, time: .shortened))")
            }
            if let reason = status.lastErrorReasonCode {
                Text("Latest status: \(reason.replacingOccurrences(of: "_", with: " "))")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func discordSelectionLabel(
        _ selection: DiscordSourceSelection
    ) -> String {
        if let threadID = selection.threadID {
            return "Guild \(selection.guildID) · Channel \(selection.channelID) · Thread \(threadID)"
        }
        return "Guild \(selection.guildID) · Channel \(selection.channelID)"
    }

    private func emailAccessDescription(
        _ state: EmailFileAccessState
    ) -> String {
        switch state {
        case .available:
            "Read-only file authorization retained for explicit re-import."
        case .removed:
            "File authorization removed; admitted local data is preserved."
        case .unavailable:
            "File authorization state could not be read. Reopen Loki Brief or reselect the source before importing."
        }
    }

    private func discordSelectionAccessibilityLabel(
        _ selection: DiscordSourceSelection
    ) -> String {
        if let threadID = selection.threadID {
            return "Selected Discord guild \(selection.guildID), channel \(selection.channelID), thread \(threadID)"
        }
        return "Selected Discord guild \(selection.guildID), channel \(selection.channelID)"
    }

    private static let emailTypes: [UTType] = [
        UTType(filenameExtension: "eml") ?? .data,
        UTType(filenameExtension: "mbox") ?? .data,
    ]
}

private struct DiscordSetupSheet: View {
    @ObservedObject var controller: ConnectorSourcesController
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = "Discord"
    @State private var applicationID = ""
    @State private var botUserID = ""
    @State private var token = ""
    @State private var guildIDs = ""
    @State private var messageContentEnabled = false
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "Connect Discord Read-Only",
                subtitle: "The bot token is written only to the Data Protection Keychain. Nonsecret allowlists and sync receipts stay in local app storage; imported records stay in Loki Vault."
            )
            GroupBox("Minimum Discord setup") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Installation context: Server Install only")
                    Text("Scope: bot")
                    Text("Permissions: View Channel + Read Message History (66560)")
                    Text("No Send Messages, Manage Messages, moderation, or Administrator permission")
                    Text("Message Content is a privileged intent. Without it, Loki Brief reports a degraded metadata-only state rather than claiming full content access.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
            }
            TextField("Connection name", text: $displayName)
            TextField("Discord application ID", text: $applicationID)
                .accessibilityLabel("Discord application ID")
            TextField("Discord bot user ID", text: $botUserID)
                .accessibilityLabel("Discord bot user ID")
            SecureField("Discord bot token", text: $token)
                .accessibilityHint("Stored only in the local Data Protection Keychain")
            TextField("Allowed server IDs, comma separated", text: $guildIDs)
                .accessibilityHint("At least one explicit server ID is required. Direct messages are always excluded.")
            Toggle("Message Content intent is enabled for this bot", isOn: $messageContentEnabled)
            HStack {
                Spacer()
                Button("Cancel") { token = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(connecting)
                Button(connecting ? "Connecting…" : "Connect") {
                    connecting = true
                    let tokenValue = token
                    token = ""
                    Task {
                        let connected = await controller.connectDiscord(
                            displayName: displayName,
                            applicationID: applicationID,
                            botUserID: botUserID,
                            token: tokenValue,
                            guildIDs: parsedGuildIDs,
                            messageContentEnabled: messageContentEnabled
                        )
                        connecting = false
                        if connected { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(connecting || applicationID.isEmpty || botUserID.isEmpty || token.isEmpty || parsedGuildIDs.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(26)
        .frame(width: 680)
    }

    private var parsedGuildIDs: Set<String> {
        Set(guildIDs.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }
}

private struct DiscordSourceSelectionSheet: View {
    @ObservedObject var controller: ConnectorSourcesController
    let statusID: String
    @Environment(\.dismiss) private var dismiss
    @State private var channelIDs: Set<String>
    @State private var threadIDs: Set<String>

    init(controller: ConnectorSourcesController, statusID: String) {
        self.controller = controller
        self.statusID = statusID
        let existing = controller.discordSelections(statusID: statusID)
        _channelIDs = State(initialValue: Set(
            existing.filter { $0.threadID == nil }.map(\.channelID)
        ))
        _threadIDs = State(initialValue: Set(existing.compactMap(\.threadID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Discord Sources").font(.title2.weight(.semibold))
                    Text("Only checked channels and threads can be synchronized. Discovery reads source metadata, not message history.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Selection") {
                    if controller.saveDiscordSelection(
                        statusID: statusID,
                        selectedChannelIDs: channelIDs,
                        selectedThreadIDs: threadIDs
                    ) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Divider()
            if let discovery = controller.discordDiscoveryByStatusID[statusID] {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(discovery.channels) { channel in
                            if channel.isThreadContainerOnly {
                                sourceInformation(
                                    name: channel.displayName,
                                    detail: "Thread container · server \(shortHash(channel.guildID)) · select a child thread"
                                )
                            } else {
                                sourceToggle(
                                    name: channel.displayName,
                                    detail: "Channel · server \(shortHash(channel.guildID))",
                                    selected: Binding(
                                        get: { channelIDs.contains(channel.id) },
                                        set: { selected in
                                            if selected { channelIDs.insert(channel.id) }
                                            else { channelIDs.remove(channel.id) }
                                        }
                                    )
                                )
                            }
                        }
                        ForEach(discovery.threads) { thread in
                            sourceToggle(
                                name: thread.displayName,
                                detail: "Thread · server \(shortHash(thread.guildID))\(thread.isArchived ? " · archived" : "")",
                                selected: Binding(
                                    get: { threadIDs.contains(thread.id) },
                                    set: { selected in
                                        if selected { threadIDs.insert(thread.id) }
                                        else { threadIDs.remove(thread.id) }
                                    }
                                )
                            )
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Discover Discord sources first",
                    systemImage: "arrow.clockwise",
                    description: Text("Close this sheet and choose Discover. No message history is requested during discovery.")
                )
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 580)
    }

    private func sourceToggle(
        name: String,
        detail: String,
        selected: Binding<Bool>
    ) -> some View {
        Toggle(isOn: selected) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceInformation(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortHash(_ value: String) -> String {
        String(DiscordPrivacy.shortHash(value).prefix(12))
    }
}
