import SwiftUI

struct SlackSourcesSection: View {
    @ObservedObject var controller: SlackAppController
    @State private var channelWorkspace: SlackWorkspaceConnection?
    @State private var deleteDataWorkspace: SlackWorkspaceConnection?
    @State private var disconnectWorkspace: SlackWorkspaceConnection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Slack").font(.title2.weight(.semibold))
                    Text("Connect a user-authorized workspace, choose up to 20 channels, then refresh only when you request it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                availabilityBadge
            }

            switch controller.availability {
            case .configurationRequired:
                configurationRequiredCard
            case .disconnected where controller.workspaces.isEmpty:
                disconnectedCard
            case .disconnected, .connected:
                if controller.workspaces.isEmpty {
                    disconnectedCard
                } else {
                    ForEach(controller.workspaces) { workspace in
                        workspaceCard(workspace)
                    }
                    Button("Connect Another Slack Workspace", systemImage: "plus") {
                        Task { await controller.connect() }
                    }
                    .disabled(isAuthorizing)
                }
            }

            if let message = controller.statusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Label(LokiBriefPresentation.message(for: error), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(item: $channelWorkspace) { workspace in
            SlackChannelSelectionSheet(controller: controller, workspace: workspace)
        }
        .confirmationDialog(
            "Delete retained Slack data for \(deleteDataWorkspace?.teamName ?? "this workspace")?",
            isPresented: Binding(
                get: { deleteDataWorkspace != nil },
                set: { if !$0 { deleteDataWorkspace = nil } }
            )
        ) {
            Button("Delete Slack Data", role: .destructive) {
                guard let workspaceID = deleteDataWorkspace?.id else { return }
                deleteDataWorkspace = nil
                Task { await controller.deleteLocalData(workspaceID: workspaceID) }
            }
            Button("Cancel", role: .cancel) { deleteDataWorkspace = nil }
        } message: {
            Text("This removes retained Slack excerpts, channel selections, cursors, sync records, and Slack-derived brief items. The workspace authorization and Keychain credential remain. Feed data is preserved.")
        }
        .confirmationDialog(
            "Disconnect \(disconnectWorkspace?.teamName ?? "this Slack workspace")?",
            isPresented: Binding(
                get: { disconnectWorkspace != nil },
                set: { if !$0 { disconnectWorkspace = nil } }
            )
        ) {
            Button("Disconnect Slack", role: .destructive) {
                guard let workspaceID = disconnectWorkspace?.id else { return }
                disconnectWorkspace = nil
                Task { await controller.disconnect(workspaceID: workspaceID) }
            }
            Button("Cancel", role: .cancel) { disconnectWorkspace = nil }
        } message: {
            Text("Loki Brief will attempt remote token revocation, delete the Keychain credential, and disable future Slack access. Retained channels, evidence, cursors, and brief history stay local until you separately choose Delete Slack Data.")
        }
        .disabled(controller.wholeAppDeletionInProgress)
    }

    private var availabilityBadge: some View {
        Text(availabilityLabel)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var availabilityLabel: String {
        switch controller.availability {
        case .configurationRequired: "configuration required"
        case .disconnected: "disconnected"
        case .connected: "connected"
        }
    }

    private var isAuthorizing: Bool {
        switch controller.authorizationOperation {
        case .authorizing, .validatingIdentity, .cancelling: true
        case .idle, .discoveringChannels, .syncingChannels, .waitingForRateLimit, .disconnecting, .failed: false
        }
    }

    private var configurationRequiredCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                Label("Slack configuration required", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Text("Slack is not configured in this private release candidate. The release operator must provide the approved Slack application configuration before connection is available.")
                Text("No browser session or Slack request starts while configuration is missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var disconnectedCard: some View {
        GroupBox {
            HStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("No Slack workspace connected").font(.headline)
                    Text("Authorization uses a public-client PKCE flow. Loki Brief requests only the configured read-only user scopes and stores rotating tokens in the local Data Protection Keychain.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAuthorizing {
                    Button("Cancel") { Task { await controller.cancelAuthorization() } }
                } else {
                    Button("Connect Slack", systemImage: "link") {
                        Task { await controller.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func workspaceCard(_ workspace: SlackWorkspaceConnection) -> some View {
        let enabled = controller.isWorkspaceEnabled(workspace.id)
        let selectedCount = controller.selectedChannelCount(workspaceID: workspace.id)
        let operation = controller.workspaceOperations[workspace.id] ?? .idle
        let detail = controller.workspaceStatusDetails[workspace.id]

        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "pause.circle")
                    .font(.title2)
                    .foregroundStyle(enabled ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(workspace.teamName).font(.headline)
                        Text(enabled ? LokiBriefPresentation.label(for: workspace.state.rawValue) : "Disabled")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("Authorized as \(workspace.userDisplayName) · \(selectedCount)/\(SlackLimits.maximumSelectedChannels) channels selected")
                        .foregroundStyle(.secondary)
                    Text("Access: \(workspace.grantedScopes.map { LokiBriefPresentation.slackScope(for: $0.rawValue) }.sorted().joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isBusy(operation) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        Task { await controller.cancelWorkspaceOperation(workspaceID: workspace.id) }
                    }
                }
            }

            if case let .syncingChannels(completed, total) = operation {
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                    Text("Refreshing selected channels \(completed)/\(total)")
                }
            } else if case let .waitingForRateLimit(until) = operation {
                Label(
                    "Waiting for Slack rate limit until \(until.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if case let .failed(reasonCode) = operation {
                Label(LokiBriefPresentation.reason(for: reasonCode), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let detail {
                    Text(detail.tokenFreshness(at: .now))
                    Text(detail.lastSuccessfulRefreshAt.map {
                        "Last successful refresh \($0.formatted(date: .abbreviated, time: .shortened))"
                    } ?? "No successful selected-channel refresh yet")
                    if let rateLimitedUntil = detail.rateLimitedUntil, rateLimitedUntil > .now {
                        Text("Rate limited until \(rateLimitedUntil.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.orange)
                    }
                    if let failure = detail.lastFailureReasonCode {
                        Text("Last issue: \(LokiBriefPresentation.reason(for: failure))").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(
                isOn: Binding(
                    get: { workspace.localModelConsent },
                    set: { enabled in
                        Task { await controller.setLocalModelConsent(workspaceID: workspace.id, enabled: enabled) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow this workspace's bounded Slack excerpts in local Ollama prompts")
                    Text("Off by default. This never authorizes cloud-model transmission; deterministic ranking remains authoritative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)

            HStack {
                Button("Choose Channels", systemImage: "checklist") { channelWorkspace = workspace }
                Button("Discover Channels", systemImage: "arrow.clockwise") {
                    Task { await controller.discoverChannels(workspaceID: workspace.id) }
                }
                .disabled(!enabled || isBusy(operation))
                Button("Refresh Selected", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await controller.syncSelectedChannels(workspaceID: workspace.id) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled || selectedCount == 0 || isBusy(operation))
                Spacer()
                if enabled {
                    Button("Disable") { Task { await controller.disableWorkspace(workspaceID: workspace.id) } }
                        .disabled(isBusy(operation))
                } else {
                    Button("Enable") { Task { await controller.enableWorkspace(workspaceID: workspace.id) } }
                        .disabled(isBusy(operation) || !controller.clientIDIsConfigured)
                }
                Button("Reauthorize") { Task { await controller.reauthorize(workspaceID: workspace.id) } }
                    .disabled(isBusy(operation) || isAuthorizing || !controller.clientIDIsConfigured)
                Button("Delete Slack Data…", role: .destructive) { deleteDataWorkspace = workspace }
                    .disabled(isBusy(operation))
                Button("Disconnect Slack…", role: .destructive) { disconnectWorkspace = workspace }
                    .disabled(isBusy(operation))
            }
        }
        .padding(17)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func isBusy(_ operation: SlackConnectorOperation) -> Bool {
        switch operation {
        case .discoveringChannels, .syncingChannels, .waitingForRateLimit, .disconnecting, .cancelling, .validatingIdentity, .authorizing:
            true
        case .idle, .failed:
            false
        }
    }
}

private struct SlackChannelSelectionSheet: View {
    @ObservedObject var controller: SlackAppController
    let workspace: SlackWorkspaceConnection
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filter: SlackChannelFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Slack Channels").font(.title2.weight(.semibold))
                    Text("\(workspace.teamName) · \(controller.selectedChannelCount(workspaceID: workspace.id))/\(SlackLimits.maximumSelectedChannels) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Discover Channels") {
                    Task { await controller.discoverChannels(workspaceID: workspace.id) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            HStack {
                TextField("Search channels", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $filter) {
                    ForEach(SlackChannelFilter.allCases) { value in Text(value.label).tag(value) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
            }

            Divider()

            if displayedChoices.isEmpty {
                ContentUnavailableView(
                    controller.conversationsByWorkspace[workspace.id, default: []].isEmpty
                        ? "No Discovered Channels"
                        : "No Matching Channels",
                    systemImage: "number",
                    description: Text("Channel discovery runs only when you press Discover Channels. Public and private channels are limited to those available to the authorized Slack user.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(displayedChoices) { choice in
                            channelRow(choice)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 580)
    }

    private var displayedChoices: [SlackConversationChoice] {
        controller.choices(workspaceID: workspace.id, search: search, filter: filter)
    }

    @ViewBuilder
    private func channelRow(_ choice: SlackConversationChoice) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { choice.isSelected },
                        set: { selected in
                            Task {
                                await controller.setChannelSelected(
                                    workspaceID: workspace.id,
                                    channelID: choice.channelID,
                                    selected: selected
                                )
                            }
                        }
                    )
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: choice.kind == .privateChannel ? "lock.fill" : "number")
                            .foregroundStyle(.secondary)
                        Text(choice.displayName).font(.headline)
                        if choice.isMember {
                            Text("member")
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .toggleStyle(.switch)
                Spacer()
                if let refreshedAt = choice.lastSuccessfulRefreshAt {
                    Text("Refreshed \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if choice.isSelected {
                Toggle(
                    "Enabled for manual refresh",
                    isOn: Binding(
                        get: { choice.isEnabled },
                        set: { enabled in
                            Task {
                                await controller.setChannelEnabled(
                                    workspaceID: workspace.id,
                                    channelID: choice.channelID,
                                    enabled: enabled
                                )
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .font(.caption)
                .padding(.leading, 38)

                HStack {
                    Text("Briefing weight").font(.caption)
                    Slider(
                        value: Binding(
                            get: { choice.weight },
                            set: { controller.setChannelWeight(workspaceID: workspace.id, channelID: choice.channelID, weight: $0) }
                        ),
                        in: 0.5...2,
                        step: 0.1
                    )
                    .frame(width: 190)
                    Text(choice.weight.formatted(.number.precision(.fractionLength(1))))
                        .font(.caption.monospacedDigit())
                }
                .padding(.leading, 38)
            }

            if let reason = choice.lastFailureReasonCode {
                Label(LokiBriefPresentation.reason(for: reason), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 38)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct SlackSettingsFormSection: View {
    @ObservedObject var controller: SlackAppController

    var body: some View {
        Section("Slack") {
            Text("Slack refresh is manual and selected-channel only. Token rotation occurs only when an explicit Slack operation needs a current credential.")
                .foregroundStyle(.secondary)
            ForEach(controller.workspaces) { workspace in
                Toggle(
                    "Allow local Ollama for \(workspace.teamName)",
                    isOn: Binding(
                        get: { workspace.localModelConsent },
                        set: { enabled in
                            Task { await controller.setLocalModelConsent(workspaceID: workspace.id, enabled: enabled) }
                        }
                    )
                )
            }
        }
        .disabled(controller.wholeAppDeletionInProgress)
    }
}

struct SlackPrivacyDisclosure: View {
    var body: some View {
        GroupBox("Slack privacy boundary") {
            Text("Slack access uses PKCE with rotating user tokens stored in the local Data Protection Keychain. Loki Brief retains bounded normalized excerpts, author/workspace/channel attribution, retrieval timestamps, selection weights, cursors, and failure reason codes. It does not persist raw Slack payloads, full message history, browser cookies, authorization codes, access tokens, refresh tokens, request bodies, or hidden reasoning. No background Slack polling is performed.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
