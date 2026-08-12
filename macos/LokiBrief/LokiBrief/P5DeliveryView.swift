import SwiftUI

struct P5DeliveryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: P5DeliveryController

    var body: some View {
        ScrollView {
            Form {
                Section("Schedule") {
                    Toggle("Enable one daily brief schedule", isOn: Binding(
                        get: { controller.schedule.enabled },
                        set: { enabled in controller.updateSchedule { $0.enabled = enabled } }
                    ))
                    DatePicker("Delivery time", selection: deliveryTime, displayedComponents: .hourAndMinute)
                    Toggle("Follow the current system time zone", isOn: Binding(
                        get: { controller.schedule.followsSystemTimeZone },
                        set: { value in controller.updateSchedule { $0.followsSystemTimeZone = value; if !value { $0.persistedTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier } } }
                    ))
                    LabeledContent("Selected days") {
                        HStack(spacing: 5) {
                            ForEach(ScheduleWeekday.allCases, id: \.rawValue) { weekday in
                                Toggle(shortLabel(weekday), isOn: weekdayBinding(weekday)).toggleStyle(.button)
                            }
                        }
                    }
                    Picker("Missed-run policy", selection: Binding(
                        get: { controller.schedule.missedRunPolicy },
                        set: { value in controller.updateSchedule { $0.missedRunPolicy = value } }
                    )) {
                        Text("Skip").tag(MissedRunPolicy.skip)
                        Text("Run when the app returns").tag(MissedRunPolicy.runWhenAppReturns)
                        Text("Run inside the grace window").tag(MissedRunPolicy.runWithinGraceWindow)
                    }
                    Stepper(
                        "Catch-up window: \(Int(controller.schedule.catchUpWindow.maximumAge / 3_600)) hours",
                        value: catchUpHours,
                        in: 1...168
                    )
                    LabeledContent("Scheduler", value: LokiBriefPresentation.label(for: controller.schedulerSnapshot.state.rawValue))
                    LabeledContent("Next scheduled occurrence", value: nextOccurrenceLabel)
                    LabeledContent("Last scheduled occurrence", value: lastOccurrenceLabel)
                    Text("Closing the main window leaves the menu-bar app active. Quitting Loki Brief pauses scheduled delivery until the app is opened again.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Sources") {
                    Toggle("Refresh enabled public feeds", isOn: Binding(
                        get: { controller.schedule.delivery.refreshFeeds },
                        set: { value in controller.updateSchedule { $0.delivery.refreshFeeds = value } }
                    ))
                    Text("\(model.subscriptions.filter(\.enabled).count) enabled feed source(s) participate. Existing HTTPS, SSRF, conditional-request, and cancellation controls remain authoritative.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Refresh connected selected-channel Slack workspaces", isOn: Binding(
                        get: { controller.schedule.delivery.refreshSelectedSlackWorkspaces },
                        set: { value in controller.updateSchedule { $0.delivery.refreshSelectedSlackWorkspaces = value } }
                    ))
                    ForEach(model.slackController.workspaces) { workspace in
                        Toggle(workspace.teamName, isOn: Binding(
                            get: { controller.schedule.selectedAccountIDs.contains(workspace.id) && model.slackController.isWorkspaceEnabled(workspace.id) },
                            set: { selected in
                                controller.updateSchedule { schedule in
                                    if selected { schedule.selectedAccountIDs.insert(workspace.id) }
                                    else { schedule.selectedAccountIDs.remove(workspace.id) }
                                }
                            }
                        ))
                        .disabled(!model.slackController.isWorkspaceEnabled(workspace.id))
                    }
                    Text("\(controller.schedule.selectedAccountIDs.count) connected workspace account(s) selected. Forward cursors only; no scheduled historical backfill, DMs, files, or threads.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Local generation") {
                    LabeledContent("Authoritative selection", value: "Deterministic")
                    Toggle("Allow local Ollama presentation generation during scheduled briefs", isOn: Binding(
                        get: { controller.schedule.delivery.allowScheduledOllama },
                        set: { value in controller.updateSchedule { $0.delivery.allowScheduledOllama = value } }
                    ))
                    Text("Requires the global Ollama preference, an available selected model, and separate per-workspace Slack consent. Implemented local processing is included during Early Access. Failure always preserves deterministic presentation.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Provider", value: LokiBriefPresentation.label(for: model.ollamaStatus.state.rawValue))
                    Text(controller.entitlementMessage).font(.caption).foregroundStyle(.secondary)
                }

                Section("Launch at login") {
                    Toggle("Launch Loki Brief at login", isOn: Binding(
                        get: { controller.launchSnapshot.desiredEnabled },
                        set: controller.setLaunchAtLogin
                    ))
                    LabeledContent("System registration", value: LokiBriefPresentation.label(for: controller.launchSnapshot.state.rawValue))
                    Button("Open Login Items Settings") { controller.openLoginItemsSettings() }
                    Text("Launch Loki Brief at login so scheduled briefs can run while the menu-bar app is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                NotificationDeliverySettingsSection(
                    state: controller.notificationState,
                    setNotificationsEnabled: controller.setNotificationsEnabled,
                    setPrivacyMode: controller.setNotificationPrivacy,
                    sendTestNotification: controller.sendTestNotification,
                    openSystemNotificationSettings: controller.openNotificationSettings
                )

                Section("Run now") {
                    HStack {
                        Button("Generate Brief Now") { controller.generateBriefNow() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isBusy)
                        Button("Cancel Current Run", role: .cancel) {
                            Task { await controller.cancelCurrentRun() }
                        }
                        .disabled(!controller.isBusy)
                    }
                    LabeledContent("Current stage", value: LokiBriefPresentation.label(for: controller.currentRunState.rawValue))
                    Text(LokiBriefPresentation.reason(for: controller.currentRunReasonCode)).font(.caption).foregroundStyle(.secondary)
                }

                Section("Delivery history") {
                    if controller.historyRows.isEmpty {
                        Text("No scheduled, catch-up, test, or manual delivery runs yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.historyRows.prefix(20)) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(row.resultLabel).font(.headline); Spacer(); Text("\(row.briefingDay.formatted(.abbreviated)) · \(row.intendedAt.formatted(date: .omitted, time: .shortened))").font(.caption) }
                                Text("\(row.triggerLabel) · \(row.itemCount) items · \(row.sourceCount) sources · notification \(LokiBriefPresentation.label(for: row.notificationOutcome.rawValue))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let reason = row.boundedReasonCode { Text(LokiBriefPresentation.reason(for: reason)).font(.caption2).foregroundStyle(.secondary) }
                                if let briefID = row.briefID { Button("Open Brief") { model.openHistory(id: briefID) } }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                NotificationPrivacyDisclosureView()
            }
            .formStyle(.grouped)
            .padding(24)
            .disabled(controller.deletionInProgress)
        }
        .navigationTitle("Delivery")
    }

    private var deliveryTime: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents(
                    hour: controller.schedule.localTime.hour,
                    minute: controller.schedule.localTime.minute
                )
                components.calendar = .autoupdatingCurrent
                components.timeZone = .autoupdatingCurrent
                return Calendar.autoupdatingCurrent.date(from: components) ?? .now
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents(
                    in: .autoupdatingCurrent,
                    from: date
                )
                controller.updateSchedule { $0.localTime = .init(hour: components.hour ?? 8, minute: components.minute ?? 0) }
            }
        )
    }

    private var nextOccurrenceLabel: String {
        guard let occurrence = controller.schedulerSnapshot.nextOccurrence else {
            return "None while disabled or paused"
        }
        return "\(occurrence.briefingDay.formatted(.abbreviated)) · \(occurrence.resolvedExecutionDate.formatted(date: .omitted, time: .shortened))"
    }

    private var lastOccurrenceLabel: String {
        guard let row = controller.historyRows.first else { return "None" }
        let instant = row.actualAt ?? row.intendedAt
        return "\(row.briefingDay.formatted(.abbreviated)) · \(instant.formatted(date: .omitted, time: .shortened))"
    }

    private var catchUpHours: Binding<Int> {
        Binding(
            get: { Int(controller.schedule.catchUpWindow.maximumAge / 3_600) },
            set: { hours in controller.updateSchedule { $0.catchUpWindow = .init(maximumAge: TimeInterval(hours * 3_600)) } }
        )
    }

    private func weekdayBinding(_ weekday: ScheduleWeekday) -> Binding<Bool> {
        Binding(
            get: { controller.schedule.recurrence.selectedWeekdays.contains(weekday) },
            set: { enabled in
                controller.updateSchedule { schedule in
                    var days = schedule.recurrence.selectedWeekdays
                    if enabled { days.insert(weekday) } else if days.count > 1 { days.remove(weekday) }
                    schedule.recurrence = .daily(selectedWeekdays: days)
                }
            }
        )
    }

    private func shortLabel(_ weekday: ScheduleWeekday) -> String {
        switch weekday {
        case .sunday: "S"
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        }
    }
}
