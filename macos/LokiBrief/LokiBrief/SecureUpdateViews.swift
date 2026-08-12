import SwiftUI

struct SecureUpdateSettingsSection: View {
    @EnvironmentObject private var updates: SecureUpdateController

    var body: some View {
        Section("Software Updates") {
            LabeledContent("Installed version") {
                Text("\(updates.currentVersion.marketingVersion) (\(updates.currentVersion.buildVersion))")
                    .monospacedDigit()
            }

            Picker(
                "Channel",
                selection: Binding(
                    get: { updates.channel },
                    set: updates.setChannel
                )
            ) {
                ForEach(UpdateChannel.allCases, id: \.self) { channel in
                    Text(channelLabel(channel)).tag(channel)
                }
            }
            Text("Stable is the default. Stable never receives beta or internal items; changing channels is an explicit operator choice.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "Check for updates automatically",
                isOn: Binding(
                    get: { updates.automaticChecksEnabled },
                    set: updates.setAutomaticChecksEnabled
                )
            )
            Text("Automatic checks never enable automatic download or installation. Loki Brief does not ask for install permission on first launch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Check for Updates…") { updates.handle(.check(from: .settings)) }
                    .disabled(!updates.canCheckForUpdates)
                Spacer()
                updateStateLabel
            }

            Text(updates.statusMessage)
                .foregroundStyle(statusColor)

            if let availability = updates.availability {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version \(availability.version.marketingVersion) (\(availability.version.buildVersion))")
                        .font(.headline)
                    Text(availability.releaseNotes.isEmpty ? "No release notes were supplied." : availability.releaseNotes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(20)
                }
                .padding(.vertical, 4)
            }

            if case .downloading(_, let progress) = updates.state {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text("Sparkle’s signed-download window shows live byte progress and the install/relaunch controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .installBlocked = updates.state {
                Button("Retry Installation") { updates.retryBlockedInstallation() }
                Text("Sparkle requires the postponed install continuation to remain live. Finish active work, then retry; quitting Loki Brief abandons the current update cycle safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateStateLabel: some View {
        Text(stateLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var stateLabel: String {
        switch updates.state.kind {
        case .idle: "Idle"
        case .checking: "Checking"
        case .updateAvailable: "Available"
        case .downloading: "Downloading"
        case .readyToInstall: "Ready"
        case .installBlocked: "Blocked safely"
        case .installing: "Installing"
        case .relaunching: "Relaunching"
        case .upToDate: "Up to date"
        case .offline: "Offline"
        case .feedUnavailable: "Feed unavailable"
        case .failed: "Failed safely"
        case .installed: "Installed"
        case .recovered: "Recovered"
        }
    }

    private var statusColor: Color {
        switch updates.state.kind {
        case .failed, .feedUnavailable: .red
        case .offline, .installBlocked, .recovered: .orange
        default: .secondary
        }
    }

    private func channelLabel(_ channel: UpdateChannel) -> String {
        switch channel {
        case .stable: "Stable"
        case .beta: "Beta"
        case .internal: "Internal"
        }
    }
}
