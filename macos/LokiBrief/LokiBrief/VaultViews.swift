import SwiftUI

private enum VaultSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case accounts = "Accounts"
    case backfill = "Backfill"
    case search = "Search"
    case storage = "Storage"

    var id: String { rawValue }
}

struct VaultView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = VaultSection.overview

    private var controller: VaultController { model.vaultController }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vault section", selection: $section) {
                ForEach(VaultSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            .padding(.top, 22)

            Group {
                switch section {
                case .overview: VaultOverviewView(controller: controller)
                case .accounts: VaultAccountsView(controller: controller)
                case .backfill: VaultBackfillView(controller: controller)
                case .search: VaultSearchView(controller: controller)
                case .storage: VaultStorageView(controller: controller)
                }
            }
        }
        .navigationTitle("Vault")
        .task { await controller.bootstrap() }
        .alert(
            "Loki Vault",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(LokiBriefPresentation.message(for: controller.errorMessage ?? ""))
        }
    }
}

private struct VaultOverviewView: View {
    @ObservedObject var controller: VaultController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Loki Vault",
                    subtitle: "A provider-neutral archive stored locally on this Mac. Implemented archive, search, export, and deletion features are included during Early Access."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    VaultMetricCard(title: "Archive", value: controller.archiveAvailable ? "Available" : "Closed", icon: "externaldrive")
                    VaultMetricCard(title: "Items", value: "\(controller.storage?.recordCount ?? 0)", icon: "doc.text.magnifyingglass")
                    VaultMetricCard(title: "Local storage", value: byteString(controller.storage?.totalArchiveBytes ?? 0), icon: "internaldrive")
                    VaultMetricCard(title: "Accounts", value: "\(controller.storage?.accountCount ?? 0)", icon: "person.2")
                    VaultMetricCard(title: "Backfill jobs", value: "\(controller.backfillRuns.count)", icon: "clock.arrow.circlepath")
                    VaultMetricCard(title: "Integrity", value: integrityLabel, icon: integrityIcon)
                }
                GroupBox("Current state") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.statusMessage)
                        if controller.isReconciling {
                            Label("Reconciling existing source evidence at durable page boundaries…", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                        }
                        if let oldest = controller.storage?.oldestItemAt {
                            Label("Oldest archived item: \(oldest.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar.badge.clock")
                        }
                        if let newest = controller.storage?.newestItemAt {
                            Label("Newest archived item: \(newest.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                let failures = controller.backfillRuns.filter {
                    [.failed, .providerUnavailable, .reauthorizationRequired].contains($0.job.state)
                }
                if !failures.isEmpty {
                    GroupBox("Recent attention") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(failures.prefix(5)) { run in
                                Label("\(run.job.provider.capitalized): \(LokiBriefPresentation.reason(for: run.job.stopReason.rawValue))", systemImage: "exclamationmark.triangle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
                HStack {
                    Button("Refresh Status", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                    Button("Reconcile Existing Evidence", systemImage: "arrow.triangle.2.circlepath") { Task { await controller.reconcileExistingEvidence(); await controller.refresh() } }
                        .disabled(controller.isReconciling || !controller.archiveAvailable)
                }
            }
            .padding(32)
        }
    }

    private var integrityLabel: String {
        guard let integrity = controller.integrity else { return "Not checked" }
        return integrity.recoveryClassification == .healthy ? "Healthy" : "Attention"
    }

    private var integrityIcon: String {
        controller.integrity?.recoveryClassification == .healthy ? "checkmark.shield" : "exclamationmark.shield"
    }
}

private struct VaultMetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VaultAccountsView: View {
    @ObservedObject var controller: VaultController
    @State private var pendingAction: PendingAccountAction?

    private struct PendingAccountAction: Identifiable {
        enum Kind { case deleteArchive, disconnect, disconnectAndDelete }
        let id = UUID()
        let account: VaultAccount
        let kind: Kind
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Vault Accounts", subtitle: "Multiple provider-owned account identities remain isolated. Slack and saved RSS evidence are the currently supported archive sources.")
                if controller.accounts.isEmpty {
                    ContentUnavailableView("No Archived Accounts", systemImage: "archivebox", description: Text("Connect Slack or add a feed, then perform an explicit refresh or reconciliation."))
                }
                ForEach(controller.accounts) { account in
                    accountCard(account)
                }
            }
            .padding(32)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(confirmationButton(action.kind), role: .destructive) {
                    pendingAction = nil
                    Task {
                        switch action.kind {
                        case .deleteArchive: await controller.deleteAccountArchive(accountID: action.account.id)
                        case .disconnect: await controller.disconnectAccount(accountID: action.account.id, deleteArchive: false)
                        case .disconnectAndDelete: await controller.disconnectAccount(accountID: action.account.id, deleteArchive: true)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private func accountCard(_ account: VaultAccount) -> some View {
        let contribution = controller.storage?.accountContributions.first(where: { $0.accountID == account.id })
        let accountContainers = controller.containers.filter { $0.accountID == account.id }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName).font(.title3.weight(.semibold))
                        Text("\(account.provider.uppercased()) · local account archive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(contribution?.itemCount ?? 0) items · \(byteString(contribution?.estimatedBytes ?? 0))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(controller.connectionSummary(for: account))
                    .font(.callout)
                Text(controller.permissionSummary(for: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.backfillSummary(for: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let contribution {
                    Text("Archived range: \(contribution.oldestItemAt?.formatted(date: .abbreviated, time: .omitted) ?? "unknown") to \(contribution.newestItemAt?.formatted(date: .abbreviated, time: .omitted) ?? "unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(controller.historicalBackfillEntitlement.acquisitionAllowed ? "Historical backfill: Included with Early Access" : "Historical backfill: Not offered in this release")
                    .font(.caption)
                    .foregroundStyle(controller.historicalBackfillEntitlement.acquisitionAllowed ? .green : .orange)
                if accountContainers.isEmpty {
                    Text("No archived containers.").foregroundStyle(.secondary)
                } else {
                    ForEach(accountContainers) { container in
                        HStack {
                            Label(container.displayName, systemImage: container.kind == VaultContainerKind.feed.rawValue ? "dot.radiowaves.left.and.right" : "number")
                            Spacer()
                            Text(container.kind.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                HStack {
                    if account.provider == VaultProviderKind.slack.rawValue {
                        Button("Start Bounded Backfill", systemImage: "clock.arrow.circlepath") {
                            Task { await controller.startSlackBackfill(workspaceID: account.providerAccountID) }
                        }
                        .disabled(!controller.historicalBackfillEntitlement.acquisitionAllowed)
                        .help(controller.historicalBackfillEntitlement.acquisitionAllowed
                              ? "Start a foreground, bounded historical backfill."
                              : "Historical acquisition is not offered in this release. Existing data remains readable, exportable, and deletable.")
                    }
                    Menu("Retention") {
                        Button("Recent Only (7 days)") { Task { await controller.enforceRetention(accountID: account.id, preset: .recentOnly) } }
                        Button("30 Days") { Task { await controller.enforceRetention(accountID: account.id, preset: .thirtyDays) } }
                        Button("90 Days") { Task { await controller.enforceRetention(accountID: account.id, preset: .ninetyDays) } }
                        Button("One Year") { Task { await controller.enforceRetention(accountID: account.id, preset: .oneYear) } }
                        Button("Unlimited") { Task { await controller.enforceRetention(accountID: account.id, preset: .unlimited) } }
                    }
                    Spacer()
                    Button("Delete Local Archive", role: .destructive) { pendingAction = .init(account: account, kind: .deleteArchive) }
                    if account.provider == VaultProviderKind.slack.rawValue {
                        Button("Disconnect Account") { pendingAction = .init(account: account, kind: .disconnect) }
                        Button("Disconnect and Delete Everything", role: .destructive) { pendingAction = .init(account: account, kind: .disconnectAndDelete) }
                    }
                }
            }
            .padding(8)
        }
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "Confirm account action" }
        return switch action.kind {
        case .deleteArchive: "Delete this account’s local archive?"
        case .disconnect: "Disconnect this account?"
        case .disconnectAndDelete: "Disconnect and delete everything for this account?"
        }
    }

    private var confirmationMessage: String {
        guard let action = pendingAction else { return "" }
        return switch action.kind {
        case .deleteArchive: "This pauses matching backfill work and deletes only this account’s Vault items, revisions, search entries, cursors, jobs, and tombstones. Provider credentials remain connected."
        case .disconnect: "This revokes or removes provider credentials and local connection data. Existing Vault archive data remains locally readable, exportable, and deletable."
        case .disconnectAndDelete: "This combines provider disconnect with account-scoped Vault deletion. Other accounts, providers, and app settings are preserved."
        }
    }

    private func confirmationButton(_ kind: PendingAccountAction.Kind) -> String {
        switch kind {
        case .deleteArchive: "Delete Local Archive"
        case .disconnect: "Disconnect Account"
        case .disconnectAndDelete: "Disconnect and Delete Everything"
        }
    }
}

private struct VaultBackfillView: View {
    @ObservedObject var controller: VaultController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Manual Backfill", subtitle: "Backfill runs only while Loki Brief is open and only after an explicit start or resume. Budgets apply to every foreground run.")
                Label(
                    controller.historicalBackfillEntitlement.acquisitionAllowed
                        ? "Historical acquisition is available."
                        : "Historical acquisition is not offered in this release. Existing archive access, export, and deletion remain available.",
                    systemImage: controller.historicalBackfillEntitlement.acquisitionAllowed ? "checkmark.shield" : "lock.trianglebadge.exclamationmark"
                )
                .foregroundStyle(controller.historicalBackfillEntitlement.acquisitionAllowed ? .green : .orange)
                if controller.backfillRuns.isEmpty {
                    ContentUnavailableView("No Backfill Jobs", systemImage: "clock.arrow.circlepath", description: Text("Start a bounded job from a connected Slack account. No background helper or schedule is installed."))
                }
                ForEach(controller.backfillRuns) { run in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(run.job.provider.capitalized, systemImage: "archivebox")
                                Text(LokiBriefPresentation.label(for: run.job.state.rawValue))
                                    .foregroundStyle(stateColor(run.job.state))
                                Spacer()
                                Text("Updated \(run.job.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Archived \(run.archivedItemCount) items · \(run.requestCount) requests · \(run.checkpoint.usage.retries) retries")
                            if let source = run.currentSource {
                                Text("Container \(run.checkpoint.sourceIndex + 1) of \(run.checkpoint.sources.count) · oldest reached \(source.oldestSynchronizedAt?.formatted(date: .abbreviated, time: .omitted) ?? "not yet known")")
                                    .foregroundStyle(.secondary)
                            }
                            if let retry = run.job.nextRetryAt {
                                Label("Waiting until \(retry.formatted(date: .abbreviated, time: .standard)) for the provider rate limit", systemImage: "hourglass")
                                    .foregroundStyle(.orange)
                            }
                            if run.job.stopReason != .none {
                                Text(LokiBriefPresentation.reason(for: run.job.stopReason.rawValue)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if [.running, .resuming, .preparing].contains(run.job.state) {
                                    Button("Pause") { Task { await controller.pauseBackfill(jobID: run.id) } }
                                }
                                if [.paused, .partiallyCompleted, .waitingForRateLimit, .reauthorizationRequired, .providerUnavailable].contains(run.job.state) {
                                    Button("Resume") { Task { await controller.resumeBackfill(jobID: run.id) } }
                                        .disabled(!controller.historicalBackfillEntitlement.acquisitionAllowed)
                                }
                                if ![.cancelled, .completed, .failed].contains(run.job.state) {
                                    Button("Cancel", role: .destructive) { Task { await controller.cancelBackfill(jobID: run.id) } }
                                    Button("Skip Container") { Task { await controller.skipBackfillContainer(jobID: run.id) } }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                Text("A total-history percentage is intentionally not shown because provider-side history size is usually unknowable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }

    private func stateColor(_ state: VaultBackfillJobState) -> Color {
        switch state {
        case .completed: .green
        case .failed, .reauthorizationRequired: .red
        case .waitingForRateLimit, .providerUnavailable, .partiallyCompleted: .orange
        default: .secondary
        }
    }
}

private struct VaultSearchView: View {
    @ObservedObject var controller: VaultController
    @State private var query = ""
    @State private var provider: String?
    @State private var accountID: String?
    @State private var containerID: String?
    @State private var useStartDate = false
    @State private var startDate = Calendar.autoupdatingCurrent.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var useEndDate = false
    @State private var endDate = Date()
    @State private var directMentionsOnly = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Local Search", subtitle: "Prepared local SQLite search only. Search terms are never logged or sent to Slack, Ollama, or a Loki server.")
            HStack {
                TextField("Search archived text", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch(offset: 0) }
                Button("Search", systemImage: "magnifyingglass") { runSearch(offset: 0) }
                    .keyboardShortcut(.return, modifiers: [])
            }
            HStack {
                Picker("Provider", selection: $provider) {
                    Text("All Providers").tag(String?.none)
                    ForEach(Array(Set(controller.accounts.map(\.provider))).sorted(), id: \.self) { Text($0.uppercased()).tag(String?.some($0)) }
                }
                Picker("Account", selection: $accountID) {
                    Text("All Accounts").tag(String?.none)
                    ForEach(controller.accounts) { Text($0.displayName).tag(String?.some($0.id)) }
                }
                Picker("Container", selection: $containerID) {
                    Text("All Containers").tag(String?.none)
                    ForEach(filteredContainers) { Text($0.displayName).tag(String?.some($0.id)) }
                }
                Toggle("Direct mentions", isOn: $directMentionsOnly)
            }
            .labelsHidden()
            HStack {
                Toggle("From", isOn: $useStartDate)
                if useStartDate {
                    DatePicker("From date", selection: $startDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
                Toggle("Through", isOn: $useEndDate)
                if useEndDate {
                    DatePicker("Through date", selection: $endDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
                Spacer()
            }
            Divider()
            if controller.searchResults.isEmpty {
                ContentUnavailableView("No Search Results", systemImage: "doc.text.magnifyingglass", description: Text(query.isEmpty ? "Enter bounded text to search the local archive." : "No archived item matched the current filters."))
            } else {
                List(controller.searchResults) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(result.title).font(.headline)
                            Spacer()
                            Text(result.provider.uppercased()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(result.snippet).lineLimit(3)
                        HStack {
                            Text(result.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            if let author = result.author { Text(author) }
                            if result.directlyMentionsUser { Label("Direct mention", systemImage: "at") }
                            if let url = result.sourceURL { Link("Open Source", destination: url) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
                HStack {
                    Button("Previous") { runSearch(offset: max(0, controller.searchOffset - 50)) }
                        .disabled(controller.searchOffset == 0)
                    Text("Results \(controller.searchOffset + 1)–\(controller.searchOffset + controller.searchResults.count)")
                        .foregroundStyle(.secondary)
                    Button("Next") { runSearch(offset: controller.searchOffset + 50) }
                        .disabled(!controller.searchHasNext)
                    Spacer()
                    if let mode = controller.searchMode {
                        Text(mode == .fullText ? "Full-text index" : "Bounded fallback").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(32)
        .onDisappear { searchTask?.cancel() }
    }

    private var filteredContainers: [VaultContainer] {
        controller.containers.filter { accountID == nil || $0.accountID == accountID }
    }

    private func runSearch(offset: Int) {
        searchTask?.cancel()
        searchTask = Task {
            await controller.search(
                text: query,
                provider: provider,
                accountID: accountID,
                containerID: containerID,
                startDate: useStartDate ? localDayInterval(containing: startDate)?.start : nil,
                endDate: useEndDate ? localDayInterval(containing: endDate)?.end : nil,
                directMentionsOnly: directMentionsOnly,
                offset: offset
            )
        }
    }

    private func localDayInterval(containing date: Date) -> DateInterval? {
        let calendar = Calendar.autoupdatingCurrent
        let timeZone = TimeZone.autoupdatingCurrent
        let day = LocalCalendarDay.resolve(containing: date, calendar: calendar, timeZone: timeZone)
        guard let reference = day.referenceDate(calendar: calendar, timeZone: timeZone) else { return nil }
        return calendar.dateInterval(of: .day, for: reference)
    }
}

private struct VaultStorageView: View {
    @ObservedObject var controller: VaultController
    @State private var confirmDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Vault Storage", subtitle: "Archive content is local and is not application-level encrypted. Credentials remain separately isolated in the Data Protection Keychain.")
                GroupBox("Files") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        metricRow("SQLite database", controller.storage?.databaseBytes ?? 0)
                        metricRow("Write-ahead log", controller.storage?.walBytes ?? 0)
                        metricRow("Shared memory", controller.storage?.sharedMemoryBytes ?? 0)
                        metricRow("Total archive", controller.storage?.totalArchiveBytes ?? 0)
                        metricRow("Reusable pages", controller.storage?.freeBytes ?? 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                GroupBox("Account contribution estimate") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.storage?.accountContributions ?? [], id: \.accountID) { contribution in
                            HStack {
                                Text(controller.accounts.first(where: { $0.id == contribution.accountID })?.displayName ?? contribution.provider.capitalized)
                                Spacer()
                                Text("\(contribution.itemCount) items · \(byteString(contribution.estimatedBytes))")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                HStack {
                    Button("Compact Archive", systemImage: "arrow.down.right.and.arrow.up.left") { Task { await controller.compact() } }
                    Button("Export Full Archive", systemImage: "square.and.arrow.up") { Task { await controller.export() } }
                    Button("Reveal Last Export", systemImage: "folder") { controller.revealLastExport() }
                        .disabled(controller.lastExportURL == nil)
                    Spacer()
                    Button("Delete All Vault Data", role: .destructive) { confirmDeleteAll = true }
                }
                Text(".lokivault exports are deterministic local JSONL with checksums. Exports are unencrypted; keep them only in a location you trust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .confirmationDialog("Delete all Loki Vault data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Vault Data", role: .destructive) { Task { _ = await controller.deleteAllVaultData() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This closes the archive, rejects late work, and removes the database, WAL, SHM, and export staging files. It does not recreate the archive during this operation. Use Settings → Delete All Local Data to also remove credentials and the existing SwiftData store.")
        }
    }

    @ViewBuilder
    private func metricRow(_ label: String, _ bytes: Int64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(byteString(bytes)).textSelection(.enabled)
        }
    }
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
