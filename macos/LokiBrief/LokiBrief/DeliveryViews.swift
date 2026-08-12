import SwiftUI

struct NotificationDeliverySettingsViewState: Equatable, Sendable {
    var notificationsEnabledPreference: Bool
    var authorization: NotificationAuthorizationState
    var privacyMode: NotificationPrivacyMode
    var isPerformingAction: Bool

    init(
        notificationsEnabledPreference: Bool,
        authorization: NotificationAuthorizationState,
        privacyMode: NotificationPrivacyMode,
        isPerformingAction: Bool = false
    ) {
        self.notificationsEnabledPreference = notificationsEnabledPreference
        self.authorization = authorization
        self.privacyMode = privacyMode
        self.isPerformingAction = isPerformingAction
    }
}

struct NotificationDeliverySettingsSection: View {
    let state: NotificationDeliverySettingsViewState
    let setNotificationsEnabled: (Bool) -> Void
    let setPrivacyMode: (NotificationPrivacyMode) -> Void
    let sendTestNotification: () -> Void
    let openSystemNotificationSettings: () -> Void

    var body: some View {
        Section("Notifications") {
            Toggle(
                "Notify me when a usable daily brief is ready",
                isOn: Binding(
                    get: { state.notificationsEnabledPreference },
                    set: setNotificationsEnabled
                )
            )
            .disabled(state.isPerformingAction)

            LabeledContent("System authorization", value: authorizationLabel)
            Text(authorizationDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(
                "Notification privacy",
                selection: Binding(get: { state.privacyMode }, set: setPrivacyMode)
            ) {
                Text("Minimal").tag(NotificationPrivacyMode.minimal)
                Text("Summary counts").tag(NotificationPrivacyMode.summary)
            }

            Text(privacyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Send Test Notification", action: sendTestNotification)
                    .disabled(!state.authorization.permitsDelivery || state.isPerformingAction)
                if state.authorization == .denied || state.authorization == .notDetermined {
                    Button("Open Notification Settings", action: openSystemNotificationSettings)
                }
            }
        }
    }

    private var authorizationLabel: String {
        switch state.authorization {
        case .notDetermined: "Not requested"
        case .denied: "Denied in System Settings"
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .ephemeral: "Temporarily authorized"
        case .unsupported: "Unavailable"
        case .error: "Unable to read"
        }
    }

    private var authorizationDetail: String {
        switch state.authorization {
        case .notDetermined:
            "Loki Brief asks only when you explicitly enable notifications. Scheduled brief generation works without notification access."
        case .denied:
            "Scheduled briefs still run, but macOS will not present Loki Brief notifications. This setting is not requested repeatedly."
        case .authorized:
            "macOS permits Loki Brief to submit local notifications. Focus and system presentation settings still control what appears."
        case .provisional:
            "macOS permits quiet local notifications. Delivery presentation remains controlled by System Settings."
        case .ephemeral:
            "Notification access is temporary. Loki Brief rechecks system truth before delivery."
        case .unsupported:
            "Native notification delivery is unavailable. Brief generation and history remain available."
        case .error:
            "Loki Brief could not read notification authorization. No delivery is claimed."
        }
    }

    private var privacyDetail: String {
        switch state.privacyMode {
        case .minimal:
            "Shows only that the brief is ready."
        case .summary:
            "Shows bounded item and source counts only. Message text, channel names, account names, authors, and URLs never appear."
        }
    }
}

struct DeliveryHistoryRow: Identifiable, Equatable, Sendable {
    let id: String
    let briefingDay: LocalCalendarDay
    let intendedAt: Date
    let actualAt: Date?
    let triggerLabel: String
    let resultLabel: String
    let itemCount: Int
    let sourceCount: Int
    let briefID: String?
    let notificationOutcome: NotificationDeliveryOutcome
    let boundedReasonCode: String?

    init(
        id: String,
        briefingDay: LocalCalendarDay? = nil,
        intendedAt: Date,
        actualAt: Date?,
        triggerLabel: String,
        resultLabel: String,
        itemCount: Int,
        sourceCount: Int,
        briefID: String?,
        notificationOutcome: NotificationDeliveryOutcome,
        boundedReasonCode: String?
    ) {
        self.id = id
        self.briefingDay = briefingDay ?? LocalCalendarDay.resolve(containing: intendedAt)
        self.intendedAt = intendedAt
        self.actualAt = actualAt
        self.triggerLabel = String(triggerLabel.prefix(80))
        self.resultLabel = String(resultLabel.prefix(80))
        self.itemCount = max(0, itemCount)
        self.sourceCount = max(0, sourceCount)
        self.briefID = briefID
        self.notificationOutcome = notificationOutcome
        self.boundedReasonCode = NotificationPrivacySanitizer.reasonCode(boundedReasonCode)
    }
}

struct DeliveryHistoryView: View {
    let rows: [DeliveryHistoryRow]
    let openBrief: (String) -> Void

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Delivery Runs",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Scheduled, catch-up, and manual delivery runs will appear here without private source text.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in historyCard(row) }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Delivery History")
    }

    private func historyCard(_ row: DeliveryHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.resultLabel).font(.headline)
                Spacer()
                Text("\(row.briefingDay.formatted(.abbreviated)) · \(row.intendedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(row.triggerLabel)
                Text("•")
                Text("\(row.itemCount) items")
                Text("•")
                Text("\(row.sourceCount) sources")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Notification", value: notificationLabel(row.notificationOutcome))
                .font(.caption)
            if let actualAt = row.actualAt {
                LabeledContent("Actual", value: actualAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
            if let reason = row.boundedReasonCode {
                Text(LokiBriefPresentation.reason(for: reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let briefID = row.briefID {
                Button("Open Brief") { openBrief(briefID) }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func notificationLabel(_ outcome: NotificationDeliveryOutcome) -> String {
        switch outcome {
        case .submitted: "Submitted to macOS"
        case .authorizationDenied: "Blocked by System Settings"
        case .authorizationNotDetermined: "Permission not requested"
        case .unsupported: "Unavailable"
        case .addFailed: "Submission failed"
        case .removed: "Removed"
        case .duplicateSuppressed: "Duplicate suppressed"
        case .ineligibleRun, .notRequested: "Not requested"
        }
    }
}

struct NotificationPrivacyDisclosureView: View {
    var body: some View {
        GroupBox("Scheduled notification privacy") {
            Text("Notifications are local and privacy-preserving by default. Minimal mode shows only that a brief is ready; summary mode adds bounded item and source counts. Slack excerpts, channel and workspace names, account names, authors, email addresses, URLs, search terms, prompts, and model output are never placed in notification content or notification traces.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
