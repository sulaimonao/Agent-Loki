import SwiftUI
import UniformTypeIdentifiers

private enum AttachedDataFilePickerPurpose: Equatable {
    case add
    case reauthorize(String)
}

struct AttachedDataSourcesSection: View {
    @ObservedObject var controller: AttachedDataSourcesController
    @State private var pickerPurpose: AttachedDataFilePickerPurpose?
    @State private var isPickerPresented = false
    @State private var pendingDetach: AttachedDataSourceRecord?
    @State private var pendingRemoval: AttachedDataSourceRecord?
    @State private var browserSource: AttachedDataSourceRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Attached Data Sources")
                        .font(.title2.weight(.semibold))
                    Text("Link a SQLite or JSON file read-only, or import a one-time normalized snapshot into Loki Vault. Loki never writes to the source and never executes model-authored SQL.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Data Source…", systemImage: "externaldrive.badge.plus") {
                    pickerPurpose = .add
                    isPickerPresented = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens a read-only file picker for SQLite or JSON")
            }

            Text("Manual refresh is the RC3 default. SQLite is admitted by file header, not extension. JSON Lines, encrypted databases, remote databases, raw SQL, and source writes are not supported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.sources.isEmpty {
                ContentUnavailableView(
                    "No attached data sources",
                    systemImage: "externaldrive",
                    description: Text("Choose a bounded SQLite .db/.sqlite/.sqlite3 file or an RFC 8259 .json file.")
                )
            } else {
                ForEach(controller.sources) { source in
                    sourceCard(source)
                }
            }

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
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            let purpose = pickerPurpose
            pickerPurpose = nil
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    switch purpose {
                    case .add:
                        _ = await controller.preparePreview(at: url)
                    case let .reauthorize(identifier):
                        _ = await controller.reauthorize(
                            sourceIdentifier: identifier,
                            with: url
                        )
                    case nil:
                        break
                    }
                }
            case let .failure(error):
                let value = error as NSError
                guard value.domain != NSCocoaErrorDomain
                        || value.code != NSUserCancelledError
                else { return }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { controller.pendingDraft != nil },
                set: { if !$0 { controller.discardPreview() } }
            )
        ) {
            AttachedDataSourcePreviewSheet(controller: controller)
        }
        .sheet(
            isPresented: Binding(
                get: { browserSource != nil },
                set: { if !$0 { browserSource = nil } }
            )
        ) {
            if let browserSource {
                AttachedDataBrowserSheet(
                    controller: controller,
                    source: browserSource
                )
            }
        }
        .confirmationDialog(
            "Detach read-only file access?",
            isPresented: Binding(
                get: { pendingDetach != nil },
                set: { if !$0 { pendingDetach = nil } }
            )
        ) {
            Button("Detach", role: .destructive) {
                guard let source = pendingDetach else { return }
                pendingDetach = nil
                _ = controller.detach(sourceIdentifier: source.id)
            }
            Button("Cancel", role: .cancel) { pendingDetach = nil }
        } message: {
            Text("Continuing access to the original file will be revoked. Loki-managed records remain until Remove Local Data is chosen separately.")
        }
        .confirmationDialog(
            "Remove Loki-managed local data?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove Local Data", role: .destructive) {
                guard let source = pendingRemoval else { return }
                pendingRemoval = nil
                Task {
                    _ = await controller.removeLocalData(
                        sourceIdentifier: source.id
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This removes this source's Vault records, revisions, tombstones, and semantic evidence. Read-only file authority is unchanged.")
        }
    }

    private func sourceCard(_ source: AttachedDataSourceRecord) -> some View {
        let busy = controller.activeSourceIdentifiers.contains(source.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: source.kind == .sqlite
                      ? "cylinder.split.1x2" : "curlybraces.square")
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName).font(.headline)
                    Text("\(source.kind.displayName) · \(modeLabel(source.mode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(stateLabel(source.state), systemImage: stateSymbol(source.state))
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("Status: \(stateLabel(source.state))")
            }

            Text(source.privacySafeLocationDescriptor)
                .foregroundStyle(.secondary)
            Text("\(source.itemCount) records · \(source.skippedItemCount) skipped · \(source.truncationCount) truncated · \(source.attachmentBlobCount) BLOB values as metadata")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let digest = source.sourceDigest {
                Text("Source digest: \(digest.prefix(12))… · epoch \(source.currentEpoch)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let last = source.lastSuccessfulRefreshAt {
                Text("Last accepted import or refresh: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = source.lastErrorReasonCode {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Selected collections and fields") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(source.selections) { selection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.displayName).font(.subheadline.weight(.medium))
                            Text(selection.selectedFields.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 5)
            }

            Toggle(
                "Allow this source in explicitly rebuilt local-model indexes",
                isOn: Binding(
                    get: { source.localModelConsentEnabled },
                    set: { enabled in
                        Task {
                            _ = await controller.setLocalModelConsent(
                                sourceIdentifier: source.id,
                                enabled: enabled
                            )
                        }
                    }
                )
            )
            .accessibilityHint("Off by default. This never authorizes a remote model provider.")

            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        controller.cancel(sourceIdentifier: source.id)
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    if source.mode == .linkedReadOnly,
                       source.access.continuingAccessRetained {
                        Button("Refresh Now", systemImage: "arrow.clockwise") {
                            Task {
                                _ = await controller.refresh(
                                    sourceIdentifier: source.id
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Reads the authorized file again and atomically replaces the accepted generation")
                    }
                    Button("Reimport or Replace…", systemImage: "arrow.triangle.2.circlepath") {
                        pickerPurpose = .reauthorize(source.id)
                        isPickerPresented = true
                    }
                    Button("Browse", systemImage: "list.bullet.rectangle") {
                        browserSource = source
                    }
                    .disabled(!source.hasRetainedLocalData)
                }
                Spacer()
                if source.access.continuingAccessRetained {
                    Button("Detach…", role: .destructive) {
                        pendingDetach = source
                    }
                    .disabled(busy)
                }
                Button("Remove Local Data…", role: .destructive) {
                    pendingRemoval = source
                }
                .disabled(busy || !source.hasRetainedLocalData)
            }
        }
        .padding(17)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func modeLabel(_ mode: AttachedDataSourceMode) -> String {
        mode == .linkedReadOnly ? "Link Read-Only" : "Imported Snapshot"
    }

    private func stateLabel(_ state: AttachedDataSourceState) -> String {
        state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func stateSymbol(_ state: AttachedDataSourceState) -> String {
        switch state {
        case .connected, .ready: "checkmark.circle"
        case .selecting, .previewing, .importing, .refreshing: "hourglass"
        case .degraded, .stale: "exclamationmark.triangle"
        case .failed, .unavailable: "xmark.octagon"
        case .disconnected, .disabled: "minus.circle"
        }
    }

    private static let allowedTypes: [UTType] = {
        ["db", "sqlite", "sqlite3", "json"].compactMap {
            UTType(filenameExtension: $0)
        }
    }()
}

private struct AttachedDataSourcePreviewSheet: View {
    @ObservedObject var controller: AttachedDataSourcesController
    @Environment(\.dismiss) private var dismiss
    @State private var jsonRoot = ""

    var body: some View {
        NavigationStack {
            Group {
                if let draft = controller.pendingDraft {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            privacyNotice(draft)
                            modePicker(draft)
                            if draft.observation.kind == .json {
                                jsonRootPicker
                            }
                            previewWarnings(draft)
                            selectionList(draft)
                            scopeSummary(draft)
                            Toggle(
                                "Allow selected text in explicitly rebuilt local-model indexes",
                                isOn: Binding(
                                    get: { draft.localModelConsentEnabled },
                                    set: controller.setPendingLocalModelConsent
                                )
                            )
                            .accessibilityHint("Off by default and limited to local providers under the existing consent boundary")
                            if !draft.preview.sampleRecords.isEmpty {
                                samples(draft.preview.sampleRecords)
                            }
                        }
                        .padding(24)
                    }
                } else {
                    ProgressView("Preparing bounded preview…")
                }
            }
            .navigationTitle("Attach Data Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.discardPreview()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm and Import") {
                        Task {
                            if await controller.importPendingPreview() {
                                dismiss()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        controller.pendingDraft?.selectedSelections.isEmpty
                            ?? true
                    )
                }
            }
        }
        .frame(minWidth: 720, minHeight: 650)
        .interactiveDismissDisabled(
            !controller.activeSourceIdentifiers.isEmpty
        )
    }

    private func privacyNotice(_ draft: AttachedDataSourceDraft) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Local, bounded, read-only admission", systemImage: "lock.shield")
                .font(.headline)
            Text("The original \(draft.observation.kind.displayName) file remains unchanged. Loki reads only the explicitly selected collections and fields. File paths and bookmark bytes are never written to logs or receipts.")
                .foregroundStyle(.secondary)
            if draft.observation.kind == .sqlite {
                Text("SQLite preview and ingestion use a separate read-only connection and a coherent task-owned backup snapshot. External databases are never attached to Loki's production database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func modePicker(_ draft: AttachedDataSourceDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode").font(.headline)
            Picker(
                "Attached data mode",
                selection: Binding(
                    get: { draft.mode },
                    set: controller.setPendingMode
                )
            ) {
                Text("Link Read-Only").tag(AttachedDataSourceMode.linkedReadOnly)
                Text("Import into Vault").tag(AttachedDataSourceMode.importedSnapshot)
            }
            .pickerStyle(.segmented)
            Text(draft.mode == .linkedReadOnly
                 ? "Loki retains minimum read-only file authority. Refresh is explicit and manual. Detach and Remove Local Data remain separate."
                 : "Importing creates a local Loki-managed copy of the selected data. Later changes to the original file are not reflected unless you reimport. Continuing file access is removed after success.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var jsonRootPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JSON record root").font(.headline)
            HStack {
                TextField("RFC 6901 pointer; leave empty for top level", text: $jsonRoot)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("JSON record root pointer")
                Button("Apply") {
                    _ = controller.setJSONRecordRoot(jsonRoot)
                }
            }
            Text("Examples: /items or /projects/0/tasks. Remote references and JSON Schema references are never resolved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectionList(_ draft: AttachedDataSourceDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Collections and searchable fields").font(.headline)
            ForEach(draft.preview.candidateSelections) { selection in
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(
                        isOn: Binding(
                            get: {
                                draft.selectedSelectionIdentifiers.contains(
                                    selection.id
                                )
                            },
                            set: {
                                controller.setPendingSelection(
                                    selection.id,
                                    included: $0
                                )
                            }
                        )
                    ) {
                        Text(selection.displayName).font(.subheadline.weight(.semibold))
                    }
                    if selection.kind == .jsonRoot {
                        jsonIdentityPicker(draft, selection: selection)
                    }
                    if let note = draft.selectionAdmissionNotes[selection.id] {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Selection warning: \(note)")
                    }
                    if draft.selectedSelectionIdentifiers.contains(selection.id) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 180))],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(
                                draft.availableFieldsBySelectionIdentifier[
                                    selection.id
                                ] ?? selection.selectedFields,
                                id: \.self
                            ) { field in
                                Toggle(
                                    field,
                                    isOn: Binding(
                                        get: { selection.selectedFields.contains(field) },
                                        set: {
                                            controller.setPendingField(
                                                selectionIdentifier: selection.id,
                                                field: field,
                                                included: $0
                                            )
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .font(.caption.monospaced())
                                .disabled(selection.identityFields.contains(field))
                                .accessibilityHint(
                                    selection.identityFields.contains(field)
                                        ? "Required for stable record identity"
                                        : "Includes or excludes this field"
                                )
                            }
                        }
                    }
                    Text("Identity: \(selection.recordIdentityStrategy.rawValue) · estimated \(selection.estimatedRecordCount.map(String.init) ?? "unknown") records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selection.allowsRecordTruncation,
                       draft.selectedSelectionIdentifiers.contains(selection.id) {
                        Label(
                            "Explicit bounded truncation is enabled for this source selection.",
                            systemImage: "scissors"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            }
            if let sqlitePreview = draft.sqlitePreview {
                let unavailable = sqlitePreview.objects.filter { !$0.isSelectable }
                if !unavailable.isEmpty {
                    DisclosureGroup("Unavailable internal, shadow, or virtual objects") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(unavailable) { object in
                                Text("\(object.name) · \(object.exclusionReasonCode ?? "unsupported")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 5)
                    }
                    .accessibilityHint("These objects cannot be admitted by the read-only SQLite engine")
                }
            }
        }
    }

    private func jsonIdentityPicker(
        _ draft: AttachedDataSourceDraft,
        selection: AttachedDataSourceSelection
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(
                "Stable record ID field",
                selection: Binding(
                    get: {
                        selection.recordIdentityStrategy == .explicitJSONID
                            ? selection.identityFields.first ?? "" : ""
                    },
                    set: {
                        _ = controller.setPendingJSONIdentityField(
                            $0.isEmpty ? nil : $0
                        )
                    }
                )
            ) {
                Text("Automatic safe identity").tag("")
                ForEach(
                    draft.availableFieldsBySelectionIdentifier[selection.id] ?? [],
                    id: \.self
                ) { field in
                    Text(field).tag(field)
                }
            }
            .accessibilityHint("The chosen field must exist in every record and contain unique scalar values")
            Text("Automatic uses one unambiguous id-like field when safe; otherwise it uses a JSON pointer plus canonical record digest. An invalid or duplicate field is rejected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewWarnings(_ draft: AttachedDataSourceDraft) -> some View {
        if draft.preview.warnings.contains(.budgetExceeded) {
            Label(
                "Some SQLite objects exceed the source-wide record budget and are off by default. Selecting one explicitly permits deterministic bounded truncation; otherwise admission fails rather than truncating silently.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func scopeSummary(_ draft: AttachedDataSourceDraft) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Bounded scope").font(.headline)
            Text(scopeSummaryText(draft.preview.appliedBudgets))
                .foregroundStyle(.secondary)
            Text("BLOB bodies are excluded; only BLOB size metadata is admitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scopeSummaryText(_ budgets: AttachedDataSourceBudgets) -> String {
        var limits = [
            "up to \(budgets.maximumRecords) records",
            "up to \(budgets.maximumFields) selected fields",
            "\(binaryByteText(budgets.maximumInputBytes)) input limit",
            "\(binaryByteText(budgets.maximumMaterializedBytes)) materialized",
        ]
        if let pageSize = budgets.pageSize {
            limits.append("\(pageSize) records per read page")
        }
        if let seconds = budgets.executionTimeSeconds {
            limits.append("\(Int(seconds)) seconds per operation")
        } else {
            limits.append("cancellation checks during parsing")
        }
        return limits.joined(separator: ", ") + "."
    }

    private func binaryByteText(_ bytes: Int64) -> String {
        let gibibyte: Int64 = 1_024 * 1_024 * 1_024
        let mebibyte: Int64 = 1_024 * 1_024
        if bytes.isMultiple(of: gibibyte) {
            return "\(bytes / gibibyte) GiB"
        }
        if bytes.isMultiple(of: mebibyte) {
            return "\(bytes / mebibyte) MiB"
        }
        return "\(bytes) bytes"
    }

    private func samples(_ records: [AttachedDataPreviewRecord]) -> some View {
        DisclosureGroup("Bounded preview samples") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.fields, id: \.name) { field in
                            Text("\(field.name): \(field.displayValue)")
                                .font(.caption.monospaced())
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct AttachedDataBrowserSheet: View {
    @ObservedObject var controller: AttachedDataSourcesController
    let source: AttachedDataSourceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search stays within the exact selected collections for \(source.displayName). Results preserve table or JSON-pointer provenance.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Bounded local search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { search(offset: 0) }
                    Button("Search") { search(offset: 0) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                List(controller.browserPage?.results ?? []) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.title).font(.headline)
                        Text(result.snippet).lineLimit(4)
                        if let provenance = result.attachedSourceProvenance {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    provenance.sourceKind == "sqlite"
                                        ? "Table: \(provenance.selectionSourceIdentifier) · row key: \(provenance.stableRecordIdentifier)"
                                        : "JSON root: \(provenance.selectionSourceIdentifier) · JSON Pointer: \(provenance.recordLocator)"
                                )
                                Text(
                                    "Epoch \(provenance.sourceEpoch) · generation \(provenance.generationIdentifier) · revision \(result.revision)"
                                )
                                Text(
                                    "Source \(provenance.sourceDigest.prefix(16))… · schema \(provenance.schemaDigest.prefix(16))… · receipt \(provenance.generationReceiptHash.prefix(16))…"
                                )
                                Text(
                                    "Identity: \(provenance.identityStrategy) · truncated: \(provenance.wasTruncated ? "yes" : "no")"
                                )
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                provenance.sourceKind == "sqlite"
                                    ? "SQLite citation. Table \(provenance.selectionSourceIdentifier), row key \(provenance.stableRecordIdentifier), epoch \(provenance.sourceEpoch)."
                                    : "JSON citation. Root \(provenance.selectionSourceIdentifier), record pointer \(provenance.recordLocator), epoch \(provenance.sourceEpoch)."
                            )
                        } else {
                            Text("Attached provenance unavailable · revision \(result.revision)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Previous") {
                        search(offset: max(0, (controller.browserPage?.offset ?? 0) - 50))
                    }
                    .disabled((controller.browserPage?.offset ?? 0) == 0)
                    Button("Next") {
                        search(offset: (controller.browserPage?.offset ?? 0) + 50)
                    }
                    .disabled(controller.browserPage?.hasNextPage != true)
                    Spacer()
                    Text("Maximum 50 records per page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .navigationTitle("Attached Data Browser")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func search(offset: Int) {
        Task {
            await controller.browse(
                sourceIdentifier: source.id,
                query: query,
                offset: offset
            )
        }
    }
}
