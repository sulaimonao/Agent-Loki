import CryptoKit
import Foundation

struct AttachedDataSourceDraft: Identifiable, Sendable {
    let id: String
    let observation: AttachedDataFileObservation
    var mode: AttachedDataSourceMode
    var localModelConsentEnabled: Bool
    var selectedSelectionIdentifiers: Set<String>
    var availableFieldsBySelectionIdentifier: [String: [String]]
    var selectionAdmissionNotes: [String: String]
    var preview: AttachedDataSourcePreview
    let sqlitePreview: AttachedSQLitePreview?
    let jsonDocument: AttachedJSONDocument?

    var selectedSelections: [AttachedDataSourceSelection] {
        preview.candidateSelections.filter {
            selectedSelectionIdentifiers.contains($0.id)
        }
    }
}

struct AttachedDataBrowserPage: Sendable {
    let sourceIdentifier: String
    let query: String
    let offset: Int
    let results: [VaultSearchResult]
    let hasNextPage: Bool
}

typealias AttachedDataSourceVaultSearch =
    @MainActor @Sendable (VaultSearchRequest) async throws -> VaultSearchResponse

private struct AttachedDataMaterializedRecord: Sendable {
    let stableIdentifier: String
    let normalizedText: String
    let contentHash: String
    let recordLocator: String
    let identityStrategy: String
    let blobCount: Int
    let wasTruncated: Bool
}

private struct AttachedDataMaterializedContainer: Sendable {
    let selection: AttachedDataSourceSelection
    let records: [AttachedDataMaterializedRecord]
    let truncationCount: Int
}

private struct AttachedDataMaterialization: Sendable {
    let observation: AttachedDataFileObservation
    let containers: [AttachedDataMaterializedContainer]
    let materializedByteCount: Int64

    var recordCount: Int { containers.reduce(0) { $0 + $1.records.count } }
    var blobCount: Int {
        containers.reduce(0) { total, container in
            total + container.records.reduce(0) { $0 + $1.blobCount }
        }
    }
    var truncationCount: Int {
        containers.reduce(0) { $0 + $1.truncationCount }
            + containers.reduce(0) { total, container in
                total + container.records.filter(\.wasTruncated).count
            }
    }
}

private struct AttachedDataSourceInspection: Sendable {
    let observation: AttachedDataFileObservation
    let shapeDigest: String
}

private struct AttachedDataPublicationFinalization: Sendable {
    let source: AttachedDataSourceRecord
    let receipt: AttachedDataSourceReceipt
}

private struct AttachedDataRemovalFinalization: Sendable {
    let source: AttachedDataSourceRecord
    let receipt: AttachedDataSourceReceipt
}

@MainActor
final class AttachedDataSourcesController: ObservableObject {
    @Published private(set) var sources: [AttachedDataSourceRecord] = []
    @Published private(set) var pendingDraft: AttachedDataSourceDraft?
    @Published private(set) var activeSourceIdentifiers: Set<String> = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var browserPage: AttachedDataBrowserPage?

    private let store: LocalStore
    private let vaultController: VaultController
    private let scopedVaultSearch: AttachedDataSourceVaultSearch
    private let fileAuthority: AttachedDataFileAuthority
    private let sqliteSource: AttachedSQLiteSource
    private let jsonParser: AttachedJSONParser
    private var semanticAuthorityChangeHandler:
        (@MainActor @Sendable (String)
            -> AttachedDataSemanticAuthorityTransaction)?
    private var restartSemanticAuthorityTransaction:
        AttachedDataSemanticAuthorityTransaction?
    private var cancellationHandlers: [String: @MainActor () -> Void] = [:]
    private var wholeAppDeletionInProgress = false
    private var restartReconciliationIsPending = false
    private var restartReconciliationTask: Task<Void, Never>?

    var hasUpdateBlockingWork: Bool {
        !activeSourceIdentifiers.isEmpty
            || restartReconciliationIsPending
            || restartReconciliationTask != nil
    }

    init(
        store: LocalStore,
        vaultController: VaultController,
        fileAuthority: AttachedDataFileAuthority = .init(),
        sqliteSource: AttachedSQLiteSource? = nil,
        jsonParser: AttachedJSONParser = .init(),
        scopedVaultSearch: AttachedDataSourceVaultSearch? = nil
    ) {
        self.store = store
        self.vaultController = vaultController
        self.scopedVaultSearch = scopedVaultSearch ?? { request in
            try await vaultController.boundedSearchResponse(request)
        }
        self.fileAuthority = fileAuthority
        self.sqliteSource = sqliteSource
            ?? (try! AttachedSQLiteSource(limits: .init()))
        self.jsonParser = jsonParser
        reload(reportFailure: false)
        restartReconciliationIsPending = sources.contains(where: {
            $0.state == .importing
                || $0.state == .refreshing
                || $0.localDataRetentionState == .removalPending
        })
    }

    func configureSemanticAuthorityChangeHandler(
        _ handler: @escaping @MainActor @Sendable (String)
            -> AttachedDataSemanticAuthorityTransaction
    ) {
        semanticAuthorityChangeHandler = handler
        if restartReconciliationIsPending,
           restartReconciliationTask == nil {
            restartSemanticAuthorityTransaction = handler(
                "semantic_index_attached_source_restart_reconciliation"
            )
            restartReconciliationTask = Task { [weak self] in
                await self?.reconcileAfterRestart()
            }
        }
    }

    func preparePreview(at url: URL) async -> Bool {
        let operationID = "attached-preview"
        guard begin(operationID) else { return false }
        defer { end(operationID) }
        let task = Task { try await buildDraft(at: url) }
        cancellationHandlers[operationID] = { task.cancel() }
        defer { cancellationHandlers[operationID] = nil }
        do {
            pendingDraft = try await task.value
            statusMessage = "Preview ready. Choose the admitted collections, fields, and import mode."
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func discardPreview() {
        pendingDraft = nil
        statusMessage = nil
    }

    func setPendingMode(_ mode: AttachedDataSourceMode) {
        pendingDraft?.mode = mode
    }

    func setPendingLocalModelConsent(_ enabled: Bool) {
        pendingDraft?.localModelConsentEnabled = enabled
    }

    func setPendingSelection(_ identifier: String, included: Bool) {
        guard var draft = pendingDraft,
              let index = draft.preview.candidateSelections.firstIndex(where: {
                  $0.id == identifier
              })
        else { return }
        if included {
            let candidate = draft.preview.candidateSelections[index]
            if draft.observation.kind == .sqlite {
                let projectedRecordCount = draft.selectedSelections
                    .filter { $0.id != identifier }
                    .compactMap(\.estimatedRecordCount)
                    .reduce(candidate.estimatedRecordCount ?? 0, +)
                if projectedRecordCount > draft.preview.appliedBudgets.maximumRecords,
                   !candidate.allowsRecordTruncation,
                   let replacement = try? Self.replacingSelection(
                       candidate,
                       allowsRecordTruncation: true
                   ) {
                    var candidates = draft.preview.candidateSelections
                    candidates[index] = replacement
                    draft.preview = (try? Self.replacingPreview(
                        draft.preview,
                        candidateSelections: candidates
                    )) ?? draft.preview
                    draft.selectionAdmissionNotes[identifier] =
                        "This selection can exceed the source-wide record limit. "
                        + "Selecting it explicitly permits deterministic truncation at that limit."
                }
            }
            draft.selectedSelectionIdentifiers.insert(identifier)
        } else {
            draft.selectedSelectionIdentifiers.remove(identifier)
        }
        pendingDraft = draft
    }

    func setPendingField(
        selectionIdentifier: String,
        field: String,
        included: Bool
    ) {
        guard var draft = pendingDraft,
              let index = draft.preview.candidateSelections.firstIndex(where: {
                  $0.id == selectionIdentifier
              }),
              draft.availableFieldsBySelectionIdentifier[
                selectionIdentifier
              ]?.contains(field) == true
        else { return }
        let existing = draft.preview.candidateSelections[index]
        guard included || !existing.identityFields.contains(field) else {
            return
        }
        var selected = Set(existing.selectedFields)
        if included,
           !selected.contains(field),
           selected.count >= draft.preview.appliedBudgets.maximumFields {
            present(AttachedDataSourceFailureCode.budgetExceeded)
            return
        }
        if included { selected.insert(field) } else { selected.remove(field) }
        guard !selected.isEmpty else { return }
        let searchable = selected.sorted()
        let identity = existing.identityFields.filter(selected.contains)
        do {
            let replacement = try AttachedDataSourceSelection(
                id: existing.id,
                kind: existing.kind,
                sourceIdentifier: existing.sourceIdentifier,
                displayName: existing.displayName,
                selectedFields: selected.sorted(),
                searchableFields: searchable,
                identityFields: identity,
                includedBlobBodyFields:
                    existing.includedBlobBodyFields.filter(selected.contains),
                recordIdentityStrategy: identity.isEmpty
                    && existing.recordIdentityStrategy.requiresIdentityFields
                    ? .canonicalRecordDigest
                    : existing.recordIdentityStrategy,
                schemaDigest: existing.schemaDigest,
                estimatedRecordCount: existing.estimatedRecordCount,
                estimatedBytes: existing.estimatedBytes,
                allowsRecordTruncation: existing.allowsRecordTruncation
            )
            var candidates = draft.preview.candidateSelections
            candidates[index] = replacement
            draft.preview = try AttachedDataSourcePreview(
                id: draft.preview.id,
                sourceIdentifier: draft.preview.sourceIdentifier,
                kind: draft.preview.kind,
                originalFilename: draft.preview.originalFilename,
                privacySafeLocationDescriptor:
                    draft.preview.privacySafeLocationDescriptor,
                fileIdentity: draft.preview.fileIdentity,
                sourceDigest: draft.preview.sourceDigest,
                shapeDigest: draft.preview.shapeDigest,
                candidateSelections: candidates,
                sampleRecords: draft.preview.sampleRecords,
                estimatedRecordCount: draft.preview.estimatedRecordCount,
                estimatedBytes: draft.preview.estimatedBytes,
                warnings: draft.preview.warnings,
                appliedBudgets: draft.preview.appliedBudgets,
                detectedAt: draft.preview.detectedAt
            )
            pendingDraft = draft
        } catch {
            present(error)
        }
    }

    func setJSONRecordRoot(_ pointer: String) -> Bool {
        guard var draft = pendingDraft,
              draft.observation.kind == .json,
              let document = draft.jsonDocument
        else { return false }
        do {
            let root = try document.recordRoot(atJSONPointer: pointer)
            let selection = try Self.jsonSelection(root: root)
            let preview = try Self.domainPreview(
                observation: draft.observation,
                sourceIdentifier: draft.id,
                selections: [selection],
                samples: try Self.jsonSamples(root: root),
                shapeDigest: Self.digest([
                    document.canonicalSHA256,
                    pointer,
                    selection.schemaDigest,
                ]),
                estimatedRecords: root.records.count,
                estimatedBytes: Int64(root.estimatedCanonicalRecordBytes)
            )
            draft.preview = preview
            draft.selectedSelectionIdentifiers = [selection.id]
            draft.availableFieldsBySelectionIdentifier = [
                selection.id: Self.jsonAvailableFields(root),
            ]
            draft.selectionAdmissionNotes = [:]
            pendingDraft = draft
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func setPendingJSONIdentityField(_ pointer: String?) -> Bool {
        guard var draft = pendingDraft,
              draft.observation.kind == .json,
              let document = draft.jsonDocument,
              let existing = draft.preview.candidateSelections.first
        else { return false }
        do {
            let explicitPointer = pointer?.isEmpty == false ? pointer : nil
            let root = try document.recordRoot(
                atJSONPointer: existing.sourceIdentifier,
                explicitIDPointer: explicitPointer
            )
            let replacement = try Self.jsonSelection(
                root: root,
                preservingSelectedFields: existing.selectedFields
            )
            draft.preview = try Self.replacingPreview(
                draft.preview,
                candidateSelections: [replacement]
            )
            draft.selectedSelectionIdentifiers = [replacement.id]
            draft.availableFieldsBySelectionIdentifier = [
                replacement.id: Self.jsonAvailableFields(root),
            ]
            pendingDraft = draft
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func importPendingPreview() async -> Bool {
        guard let draft = pendingDraft,
              !draft.selectedSelections.isEmpty
        else {
            present(AttachedDataSourceFailureCode.invalidSelection)
            return false
        }
        let sourceID = draft.id
        guard begin(sourceID) else { return false }
        defer { end(sourceID) }
        let task = Task {
            try await self.publish(
                sourceIdentifier: sourceID,
                kind: draft.observation.kind,
                mode: draft.mode,
                displayName: draft.observation.displayName,
                originalFilename: draft.observation.originalFilename,
                locationDescriptor: draft.observation.locationDescriptor,
                observation: draft.observation,
                selections: draft.selectedSelections,
                shapeDigest: draft.preview.shapeDigest,
                localModelConsentEnabled: draft.localModelConsentEnabled,
                prior: nil,
                operation: .importSnapshot
            )
        }
        cancellationHandlers[sourceID] = { task.cancel() }
        defer { cancellationHandlers[sourceID] = nil }
        do {
            let authorityResolved = try await task.value
            pendingDraft = nil
            reload()
            guard authorityResolved else {
                statusMessage = nil
                errorMessage =
                    "The attached generation committed, but retrieval remains paused because semantic authority could not be reconciled."
                return false
            }
            statusMessage = draft.mode == .linkedReadOnly
                ? "Linked read-only source admitted. Refresh remains manual."
                : "Snapshot imported into Loki Vault. Continuing file access was not retained."
            errorMessage = nil
            return true
        } catch {
            await recordPublicationFailure(
                error,
                sourceIdentifier: sourceID,
                kind: draft.observation.kind,
                mode: draft.mode,
                operation: .importSnapshot
            )
            return false
        }
    }

    func refresh(sourceIdentifier: String) async -> Bool {
        guard begin(sourceIdentifier) else { return false }
        defer { end(sourceIdentifier) }
        do {
            let source = try requiredSource(sourceIdentifier)
            guard source.mode == .linkedReadOnly,
                  source.access.continuingAccessRetained,
                  let expectedIdentity = source.fileIdentity,
                  let bookmark = try store.attachedDataSourceBookmark(id: source.id)
            else { throw AttachedDataSourceFailureCode.reauthorizationRequired }
            let inspection = try await inspectCurrentSource(
                bookmark: bookmark,
                expectedIdentity: expectedIdentity,
                kind: source.kind,
                selections: source.selections
            )
            let task = Task {
                try await self.publish(
                    sourceIdentifier: source.id,
                    kind: source.kind,
                    mode: source.mode,
                    displayName: source.displayName,
                    originalFilename: source.originalFilename,
                    locationDescriptor: source.privacySafeLocationDescriptor,
                    observation: inspection.observation,
                    selections: source.selections,
                    shapeDigest: inspection.shapeDigest,
                    localModelConsentEnabled: source.localModelConsentEnabled,
                    prior: source,
                    operation: .refresh
                )
            }
            cancellationHandlers[sourceIdentifier] = { task.cancel() }
            defer { cancellationHandlers[sourceIdentifier] = nil }
            let authorityResolved = try await task.value
            reload()
            guard authorityResolved else {
                statusMessage = nil
                errorMessage =
                    "The attached refresh committed, but retrieval remains paused because semantic authority could not be reconciled."
                return false
            }
            statusMessage = "Attached source refresh completed atomically."
            errorMessage = nil
            return true
        } catch {
            let source = try? requiredSource(sourceIdentifier)
            await recordPublicationFailure(
                error,
                sourceIdentifier: sourceIdentifier,
                kind: source?.kind ?? .json,
                mode: source?.mode ?? .linkedReadOnly,
                operation: .refresh
            )
            return false
        }
    }

    func reauthorize(
        sourceIdentifier: String,
        with url: URL
    ) async -> Bool {
        guard begin(sourceIdentifier) else { return false }
        defer { end(sourceIdentifier) }
        do {
            let source = try requiredSource(sourceIdentifier)
            let observation = try await fileAuthority.authorize(url)
            guard observation.kind == source.kind else {
                throw AttachedDataSourceFailureCode.unsupportedSource
            }
            let inspection = try await inspectCurrentSource(
                bookmark: observation.securityScopedBookmark,
                expectedIdentity: observation.identity,
                kind: source.kind,
                selections: source.selections
            )
            let task = Task {
                try await self.publish(
                    sourceIdentifier: source.id,
                    kind: source.kind,
                    mode: source.mode,
                    displayName: source.displayName,
                    originalFilename: observation.originalFilename,
                    locationDescriptor: observation.locationDescriptor,
                    observation: inspection.observation,
                    selections: source.selections,
                    shapeDigest: inspection.shapeDigest,
                    localModelConsentEnabled: source.localModelConsentEnabled,
                    prior: source,
                    operation: .reauthorize
                )
            }
            cancellationHandlers[sourceIdentifier] = { task.cancel() }
            defer { cancellationHandlers[sourceIdentifier] = nil }
            let authorityResolved = try await task.value
            reload()
            guard authorityResolved else {
                statusMessage = nil
                errorMessage =
                    "The attached reauthorization committed, but retrieval remains paused because semantic authority could not be reconciled."
                return false
            }
            statusMessage = "Read-only source authority was replaced explicitly."
            errorMessage = nil
            return true
        } catch {
            let source = try? requiredSource(sourceIdentifier)
            await recordPublicationFailure(
                error,
                sourceIdentifier: sourceIdentifier,
                kind: source?.kind ?? .json,
                mode: source?.mode ?? .linkedReadOnly,
                operation: .reauthorize
            )
            return false
        }
    }

    func detach(sourceIdentifier: String) -> Bool {
        guard begin(sourceIdentifier) else { return false }
        defer { end(sourceIdentifier) }
        do {
            guard let source = try store.detachAttachedDataSource(id: sourceIdentifier)
            else { throw AttachedDataSourceFailureCode.sourceUnavailable }
            let now = Date()
            let receipt = try makeNonPublicationReceipt(
                source: source,
                operation: .detach,
                startedAt: now,
                outcome: .succeeded,
                reasonCode: "attached_data_detached"
            )
            try store.saveAttachedDataSourceReceipt(receipt)
            reload()
            statusMessage = "Continuing file access was removed. Retained local data was preserved."
            errorMessage = nil
            emitTrace(
                event: .attachedDetach,
                status: .success,
                reasonCode: "attached_data_detached",
                source: source
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    func removeLocalData(sourceIdentifier: String) async -> Bool {
        guard begin(sourceIdentifier) else { return false }
        defer { end(sourceIdentifier) }
        var pendingSource: AttachedDataSourceRecord?
        var authorityTransaction:
            AttachedDataSemanticAuthorityTransaction?
        var vaultRemovalCommitted = false
        do {
            var source = try requiredSource(sourceIdentifier)
            guard let semanticAuthorityChangeHandler else {
                statusMessage = nil
                errorMessage =
                    "Local data was not removed because semantic cleanup authority is unavailable."
                return false
            }
            let transaction = semanticAuthorityChangeHandler(
                "semantic_index_attached_source_local_data_removed"
            )
            authorityTransaction = transaction
            guard await transaction.prepare() else {
                _ = await transaction.abort(
                    canonicalStateUnchanged: true
                )
                statusMessage = nil
                errorMessage =
                    "Local data was not removed because derived semantic data could not be deleted safely."
                return false
            }
            let startedAt = Date()
            source.localDataRetentionState = .removalPending
            source.updatedAt = startedAt
            try store.saveAttachedDataSource(source)
            pendingSource = source
            let result = try await vaultController.removeConnectorLocalData(
                provider: .localImport,
                providerAccountIdentifier: source.id
            )
            vaultRemovalCommitted = true
            let finalized = try finalizedRemoval(
                source: source,
                startedAt: startedAt,
                reasonCode: "attached_data_local_data_removed",
                recordsDeleted: result.recordsDeleted
            )
            source = finalized.source
            try store.finalizeAttachedDataSourceRemoval(
                source: finalized.source,
                receipt: finalized.receipt
            )
            let authorityResolved = await transaction.complete()
            if !authorityResolved {
                source.state = .degraded
                source.lastErrorReasonCode =
                    "attached_data_semantic_authority_resolution_failed"
                source.updatedAt = .now
                try? store.saveAttachedDataSource(source)
                reload(reportFailure: false)
                browserPage = nil
                statusMessage = nil
                errorMessage =
                    "Local data was removed, but attached-source retrieval remains paused because semantic authority could not be reconciled."
                return false
            }
            reload()
            browserPage = nil
            statusMessage = "Removed \(result.recordsDeleted) Loki-managed records. File authority was unchanged."
            errorMessage = nil
            emitTrace(
                event: .attachedRemove,
                status: .success,
                reasonCode: "attached_data_local_data_removed",
                source: source,
                recordCount: result.recordsDeleted
            )
            return true
        } catch {
            var canonicalStateUnchanged = pendingSource == nil
            if var source = pendingSource {
                let accountID = Self.accountIdentifier(
                    sourceIdentifier: source.id
                )
                if (try? await vaultController.database.accountExists(
                    id: accountID
                )) == true {
                    canonicalStateUnchanged = !vaultRemovalCommitted
                    source.localDataRetentionState = .retained
                    source.state = .degraded
                    source.lastErrorReasonCode =
                        "attached_data_local_data_removal_failed"
                    source.updatedAt = .now
                    try? store.saveAttachedDataSource(source)
                }
            }
            _ = await authorityTransaction?.abort(
                canonicalStateUnchanged: canonicalStateUnchanged
            )
            reload(reportFailure: false)
            present(error)
            return false
        }
    }

    func setLocalModelConsent(
        sourceIdentifier: String,
        enabled: Bool
    ) async -> Bool {
        var authorityTransaction:
            AttachedDataSemanticAuthorityTransaction?
        var originalConsent: Bool?
        do {
            var source = try requiredSource(sourceIdentifier)
            originalConsent = source.localModelConsentEnabled
            if source.localModelConsentEnabled, !enabled {
                guard let semanticAuthorityChangeHandler else {
                    statusMessage = nil
                    errorMessage =
                        "Local-model consent was not changed because semantic cleanup authority is unavailable."
                    return false
                }
                let transaction = semanticAuthorityChangeHandler(
                    "semantic_index_attached_source_consent_revoked"
                )
                authorityTransaction = transaction
                if !(await transaction.prepare()) {
                    _ = await transaction.abort(
                        canonicalStateUnchanged: true
                    )
                    statusMessage = nil
                    errorMessage =
                        "Local-model consent was not changed because derived semantic data could not be deleted safely."
                    return false
                }
            }
            source.localModelConsentEnabled = enabled
            source.updatedAt = .now
            try source.validate()
            try store.saveAttachedDataSource(source)
            let authorityResolved = await authorityTransaction?.complete()
                ?? true
            reload()
            guard authorityResolved else {
                statusMessage = nil
                errorMessage =
                    "Local-model consent changed, but attached-source retrieval remains paused because semantic authority could not be reconciled."
                return false
            }
            statusMessage = enabled
                ? "This source may enter explicitly rebuilt local-model indexes. Refresh to apply the policy to retained records."
                : "This source is excluded from local-model retrieval. Rebuildable semantic data was deleted; rebuild explicitly to use the remaining sources."
            errorMessage = nil
            return true
        } catch {
            let canonicalStateUnchanged: Bool
            if let originalConsent,
               let persisted = try? requiredSource(sourceIdentifier) {
                canonicalStateUnchanged =
                    persisted.localModelConsentEnabled == originalConsent
            } else {
                canonicalStateUnchanged = false
            }
            _ = await authorityTransaction?.abort(
                canonicalStateUnchanged: canonicalStateUnchanged
            )
            present(error)
            return false
        }
    }

    func browse(
        sourceIdentifier: String,
        query: String,
        offset: Int = 0
    ) async {
        let source = try? requiredSource(sourceIdentifier)
        guard let source, source.hasRetainedLocalData else {
            present(AttachedDataSourceFailureCode.sourceUnavailable)
            return
        }
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: source.id
        )
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedOffset = max(0, offset)
        let allowedContainerIdentifiers = Set(
            source.importedLocalContainerIdentifiers
        )
        let pinnedGenerationIdentifier = source.currentGenerationIdentifier
        let pinnedEpoch = source.currentEpoch
        let pinnedSourceDigest = source.sourceDigest
        guard !allowedContainerIdentifiers.isEmpty else {
            present(AttachedDataSourceFailureCode.sourceUnavailable)
            return
        }
        guard !normalizedQuery.isEmpty else {
            browserPage = .init(
                sourceIdentifier: source.id,
                query: normalizedQuery,
                offset: normalizedOffset,
                results: [],
                hasNextPage: false
            )
            return
        }
        do {
            guard let pinnedGenerationIdentifier,
                  let pinnedSourceDigest,
                  let pinnedGenerationMarker = try await vaultController
                    .boundedConnectorGenerationMarker(accountID: accountID)
            else {
                throw AttachedDataSourceFailureCode.sourceUnavailable
            }
            let pinnedGenerationReceiptHash =
                pinnedGenerationMarker.generationReceiptHash
            let response = try await scopedVaultSearch(.init(
                text: normalizedQuery,
                accountID: accountID,
                provider: VaultProviderKind.localImport.rawValue,
                limit: 50,
                offset: normalizedOffset
            ))
            try Task.checkCancellation()
            let current = try requiredSource(source.id)
            let currentGenerationMarker = try await vaultController
                .boundedConnectorGenerationMarker(accountID: accountID)
            guard current.hasRetainedLocalData,
                  current.currentGenerationIdentifier
                    == pinnedGenerationIdentifier,
                  current.currentEpoch == pinnedEpoch,
                  current.sourceDigest == pinnedSourceDigest,
                  Set(current.importedLocalContainerIdentifiers)
                    == allowedContainerIdentifiers,
                  currentGenerationMarker?.generationReceiptHash
                    == pinnedGenerationReceiptHash,
                  response.results.allSatisfy({ result in
                      result.accountID == accountID
                          && result.provider.lowercased()
                            == VaultProviderKind.localImport.rawValue
                          && allowedContainerIdentifiers
                            .contains(result.containerID)
                          && result.attachedSourceProvenance.map {
                              $0.sourceIdentifier == source.id
                                  && $0.generationIdentifier
                                    == pinnedGenerationIdentifier
                                  && $0.sourceEpoch == pinnedEpoch
                                  && $0.sourceDigest == pinnedSourceDigest
                                  && $0.generationReceiptHash
                                    == pinnedGenerationReceiptHash
                          } == true
                  })
            else {
                throw AttachedDataSourceFailureCode.sourceUnavailable
            }
            browserPage = .init(
                sourceIdentifier: source.id,
                query: normalizedQuery,
                offset: normalizedOffset,
                results: response.results,
                hasNextPage: response.wasTruncated
            )
            errorMessage = nil
        } catch {
            browserPage = nil
            present(error)
        }
    }

    func cancel(sourceIdentifier: String) {
        cancellationHandlers[sourceIdentifier]?()
        if var source = try? requiredSource(sourceIdentifier) {
            source.cancellationState = .requested
            source.updatedAt = .now
            try? store.saveAttachedDataSource(source)
        }
        statusMessage = "Cancellation requested. The last accepted generation remains available."
    }

    func prepareForUpdateInstallation() -> Bool {
        guard !hasUpdateBlockingWork, !wholeAppDeletionInProgress else {
            return false
        }
        return true
    }

    func prepareForWholeAppDataDeletion() -> Bool {
        guard !hasUpdateBlockingWork, !wholeAppDeletionInProgress else {
            present(AttachedDataSourceFailureCode.operationCancelled)
            return false
        }
        wholeAppDeletionInProgress = true
        return true
    }

    func resumeAfterWholeAppDataDeletionAbort() {
        wholeAppDeletionInProgress = false
    }

    func reloadAfterWholeAppDataDeletion() {
        wholeAppDeletionInProgress = false
        pendingDraft = nil
        browserPage = nil
        reload()
    }
}

private extension AttachedDataSourcesController {
    func begin(_ identifier: String) -> Bool {
        guard activeSourceIdentifiers.isEmpty,
              !restartReconciliationIsPending,
              restartReconciliationTask == nil,
              !wholeAppDeletionInProgress
        else {
            present(AttachedDataSourceFailureCode.operationCancelled)
            return false
        }
        activeSourceIdentifiers.insert(identifier)
        return true
    }

    func end(_ identifier: String) {
        activeSourceIdentifiers.remove(identifier)
    }

    func reload(reportFailure: Bool = true) {
        do {
            sources = try store.attachedDataSources()
        } catch {
            if reportFailure { present(error) }
        }
    }

    func reconcileAfterRestart() async {
        let authorityTransaction = restartSemanticAuthorityTransaction
        defer {
            restartSemanticAuthorityTransaction = nil
            restartReconciliationTask = nil
        }
        do {
            guard let authorityTransaction else {
                throw AttachedDataSourceFailureCode.atomicPublicationFailed
            }
            if !(await authorityTransaction.prepare()) {
                _ = await authorityTransaction.abort(
                    canonicalStateUnchanged: false
                )
                throw AttachedDataSourceFailureCode.atomicPublicationFailed
            }
            for source in try store.attachedDataSources() {
                if source.localDataRetentionState == .removalPending {
                    try await reconcileInterruptedRemoval(source)
                    continue
                }
                guard source.state == .importing || source.state == .refreshing,
                      let plan = source.frozenImportPlan,
                      source.pendingGenerationIdentifier
                        == plan.generationIdentifier
                else { continue }
                let accountID = Self.accountIdentifier(
                    sourceIdentifier: source.id
                )
                let marker = try await vaultController.database
                    .connectorGenerationMarker(accountID: accountID)
                if let marker,
                   marker.generationReceiptHash == plan.planDigest {
                    let operation = Self.recoveredOperation(
                        source: source,
                        plan: plan
                    )
                    let finalized = try finalizedPublication(
                        source: source,
                        plan: plan,
                        marker: marker,
                        operation: operation
                    )
                    try store.finalizeAttachedDataSourcePublication(
                        source: finalized.source,
                        receipt: finalized.receipt,
                        removeBookmark: source.mode == .importedSnapshot
                    )
                    emitTrace(
                        event: operation == .refresh
                            ? .attachedRefresh : .attachedImport,
                        status: .success,
                        reasonCode: "attached_data_publication_reconciled",
                        source: finalized.source,
                        recordCount: marker.recordCount
                    )
                } else {
                    let recovered = try source.reconcilingInterruptedOperation()
                    try store.saveAttachedDataSource(recovered)
                }
            }
            guard await authorityTransaction.complete() else {
                throw AttachedDataSourceFailureCode.atomicPublicationFailed
            }
            restartReconciliationIsPending = false
            reload(reportFailure: false)
        } catch {
            _ = await authorityTransaction?.abort(
                canonicalStateUnchanged: false
            )
            present(error)
        }
    }

    func requiredSource(_ identifier: String) throws -> AttachedDataSourceRecord {
        guard let source = try store.attachedDataSource(id: identifier) else {
            throw AttachedDataSourceFailureCode.sourceUnavailable
        }
        return source
    }

    func present(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            errorMessage = AttachedDataSourceFailureCode.operationCancelled
                .localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
        statusMessage = nil
    }

    func buildDraft(at url: URL) async throws -> AttachedDataSourceDraft {
        let observation = try await fileAuthority.authorize(url)
        let sourceIdentifier = "attached:\(UUID().uuidString.lowercased())"
        switch observation.kind {
        case .sqlite:
            let resolved = try await fileAuthority.withResolvedSource(
                bookmark: observation.securityScopedBookmark,
                expectedIdentity: observation.identity
            ) { [sqliteSource] authorizedURL, before, deadline in
                guard before.sourceDigest == observation.sourceDigest else {
                    throw AttachedDataFileFailureCode.identityChanged
                }
                return try await sqliteSource.preview(
                    at: authorizedURL,
                    operationDeadline: deadline
                )
            }
            let sqlitePreview = resolved.0
            let admission = try Self.sqliteDraftAdmission(sqlitePreview)
            let selections = admission.selections
            guard !selections.isEmpty else {
                throw AttachedDataSourceFailureCode.invalidPreview
            }
            let samples = try Self.sqliteSamples(sqlitePreview)
            let preview = try Self.domainPreview(
                observation: resolved.1,
                sourceIdentifier: sourceIdentifier,
                selections: selections,
                samples: samples,
                shapeDigest: sqlitePreview.schemaDigest,
                estimatedRecords: selections.compactMap(\.estimatedRecordCount)
                    .reduce(0, +),
                estimatedBytes: observation.fileSize,
                warnings: admission.hasTruncationRisk ? [.budgetExceeded] : []
            )
            return .init(
                id: sourceIdentifier,
                observation: resolved.1,
                mode: .linkedReadOnly,
                localModelConsentEnabled: false,
                selectedSelectionIdentifiers: admission.defaultSelectionIdentifiers,
                availableFieldsBySelectionIdentifier: Dictionary(
                    uniqueKeysWithValues: selections.map {
                        ($0.id, $0.selectedFields)
                    }
                ),
                selectionAdmissionNotes: admission.notesBySelectionIdentifier,
                preview: preview,
                sqlitePreview: sqlitePreview,
                jsonDocument: nil
            )
        case .json:
            let resolved = try await fileAuthority.withResolvedSource(
                bookmark: observation.securityScopedBookmark,
                expectedIdentity: observation.identity
            ) { [jsonParser] authorizedURL, before, _ in
                guard before.sourceDigest == observation.sourceDigest else {
                    throw AttachedDataFileFailureCode.identityChanged
                }
                let data = try Data(contentsOf: authorizedURL, options: .mappedIfSafe)
                return try jsonParser.parse(data)
            }
            let document = resolved.0
            let root = try document.recordRoot()
            let selection = try Self.jsonSelection(root: root)
            let preview = try Self.domainPreview(
                observation: resolved.1,
                sourceIdentifier: sourceIdentifier,
                selections: [selection],
                samples: try Self.jsonSamples(root: root),
                shapeDigest: Self.digest([
                    document.canonicalSHA256,
                    root.jsonPointer,
                    selection.schemaDigest,
                ]),
                estimatedRecords: root.records.count,
                estimatedBytes: Int64(root.estimatedCanonicalRecordBytes)
            )
            return .init(
                id: sourceIdentifier,
                observation: resolved.1,
                mode: .linkedReadOnly,
                localModelConsentEnabled: false,
                selectedSelectionIdentifiers: [selection.id],
                availableFieldsBySelectionIdentifier: [
                    selection.id: Self.jsonAvailableFields(root),
                ],
                selectionAdmissionNotes: [:],
                preview: preview,
                sqlitePreview: nil,
                jsonDocument: document
            )
        }
    }

    func inspectCurrentSource(
        bookmark: Data,
        expectedIdentity: AttachedDataFileIdentity,
        kind: AttachedDataSourceKind,
        selections: [AttachedDataSourceSelection]
    ) async throws -> AttachedDataSourceInspection {
        let resolved = try await fileAuthority.withResolvedSource(
            bookmark: bookmark,
            expectedIdentity: expectedIdentity
        ) { [sqliteSource, jsonParser] authorizedURL, _, deadline in
            switch kind {
            case .sqlite:
                let preview = try await sqliteSource.preview(
                    at: authorizedURL,
                    operationDeadline: deadline
                )
                for selection in selections {
                    guard let object = preview.objects.first(where: {
                        $0.name == selection.sourceIdentifier && $0.isSelectable
                    }), Set(selection.selectedFields).isSubset(
                        of: Set(object.columns.filter { !$0.isHidden }.map(\.name))
                    ) else {
                        throw AttachedDataSourceFailureCode.invalidSelection
                    }
                }
                return preview.schemaDigest
            case .json:
                let data = try Data(contentsOf: authorizedURL, options: .mappedIfSafe)
                let document = try jsonParser.parse(data)
                var shapeMaterial = [document.canonicalSHA256]
                for selection in selections {
                    let root = try document.recordRoot(
                        atJSONPointer: selection.sourceIdentifier,
                        explicitIDPointer:
                            selection.recordIdentityStrategy == .explicitJSONID
                                ? selection.identityFields.first : nil
                    )
                    let available = Set(root.inferredFields.map(\.jsonPointer))
                    let requested = Set(selection.selectedFields.filter { $0 != "$" })
                    guard requested.isSubset(of: available) else {
                        throw AttachedDataSourceFailureCode.invalidSelection
                    }
                    shapeMaterial.append(selection.sourceIdentifier)
                    shapeMaterial.append(contentsOf: root.inferredFields.flatMap {
                        [$0.jsonPointer] + $0.valueKinds.map(\.rawValue)
                    })
                }
                return Self.digest(shapeMaterial)
            }
        }
        return .init(observation: resolved.1, shapeDigest: resolved.0)
    }

    func publish(
        sourceIdentifier: String,
        kind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        displayName: String,
        originalFilename: String,
        locationDescriptor: String,
        observation: AttachedDataFileObservation,
        selections: [AttachedDataSourceSelection],
        shapeDigest: String,
        localModelConsentEnabled: Bool,
        prior: AttachedDataSourceRecord?,
        operation: AttachedDataSourceReceiptOperation
    ) async throws -> Bool {
        try Task.checkCancellation()
        let startedAt = Date()
        let nextEpoch = (prior?.currentEpoch ?? 0) + 1
        let selectionDigest = AttachedDataImportPlan.frozenSelectionDigest(
            for: selections
        )
        let generationIdentifier = "generation:\(nextEpoch):\(observation.sourceDigest.prefix(32))"
        let planIdentifier = "plan:\(nextEpoch):\(selectionDigest.prefix(32))"
        let budgets = AttachedDataSourceBudgets.standard(for: kind)
        let estimatedRecordCount = selections
            .compactMap(\.estimatedRecordCount).reduce(0, +)
        let estimatedMaterializedBytes: Int64? =
            selections.allSatisfy { $0.estimatedBytes != nil }
                ? selections.compactMap(\.estimatedBytes).reduce(0, +)
                : nil
        let priorGenerationIdentifier = prior?.currentGenerationIdentifier
        let priorSourceDigest: String?
        let priorShapeDigest: String?
        if priorGenerationIdentifier != nil {
            guard let sourceDigest = prior?.sourceDigest,
                  let shapeDigest = prior?.shapeDigest
            else { throw AttachedDataSourceFailureCode.invalidImportPlan }
            priorSourceDigest = sourceDigest
            priorShapeDigest = shapeDigest
        } else {
            priorSourceDigest = nil
            priorShapeDigest = nil
        }
        let plan = try AttachedDataImportPlan(
            id: planIdentifier,
            sourceIdentifier: sourceIdentifier,
            sourceKind: kind,
            mode: mode,
            fileIdentity: observation.identity,
            sourceDigest: observation.sourceDigest,
            shapeDigest: shapeDigest,
            selections: selections,
            selectionDigest: selectionDigest,
            budgets: budgets,
            expectedRecordCount: estimatedRecordCount,
            expectedMaterializedBytes: estimatedMaterializedBytes,
            normalizationVersion: 1,
            provenanceVersion: 1,
            generationIdentifier: generationIdentifier,
            priorGenerationIdentifier: priorGenerationIdentifier,
            priorSourceDigest: priorSourceDigest,
            priorShapeDigest: priorShapeDigest,
            createdAt: startedAt
        )
        let planDigest = plan.planDigest
        let retainedAccess = try AttachedDataSourceAccess(
            bookmarkState: observation.bookmarkWasStale ? .stale : .retained,
            continuingAccessRetained: true,
            lastAuthorizedAt: startedAt,
            lastResolvedAt: startedAt
        )
        var source = try AttachedDataSourceRecord(
            id: sourceIdentifier,
            kind: kind,
            mode: mode,
            displayName: displayName,
            originalFilename: originalFilename,
            privacySafeLocationDescriptor: locationDescriptor,
            fileIdentity: observation.identity,
            sourceDigest: observation.sourceDigest,
            shapeDigest: shapeDigest,
            state: operation == .refresh ? .refreshing : .importing,
            selections: selections,
            currentEpoch: prior?.currentEpoch ?? 0,
            lastSuccessfulRefreshAt: prior?.lastSuccessfulRefreshAt,
            lastAttemptedRefreshAt: startedAt,
            itemCount: prior?.itemCount ?? 0,
            skippedItemCount: prior?.skippedItemCount ?? 0,
            attachmentBlobCount: prior?.attachmentBlobCount ?? 0,
            truncationCount: prior?.truncationCount ?? 0,
            importedLocalContainerIdentifiers:
                prior?.importedLocalContainerIdentifiers ?? [],
            normalizationVersion: 1,
            provenanceVersion: 1,
            cancellationState: .none,
            lastErrorReasonCode: nil,
            localDataRetentionState:
                prior?.localDataRetentionState ?? .none,
            latestReceiptIdentifier: prior?.latestReceiptIdentifier,
            currentGenerationIdentifier: prior?.currentGenerationIdentifier,
            pendingGenerationIdentifier: generationIdentifier,
            frozenImportPlan: plan,
            access: retainedAccess,
            refreshEnabled: mode == .linkedReadOnly,
            automaticRefreshEnabled: false,
            localModelConsentEnabled: localModelConsentEnabled,
            createdAt: prior?.createdAt ?? startedAt,
            updatedAt: startedAt
        )
        let semanticCleanupRequired = source.localModelConsentEnabled
            || prior?.localModelConsentEnabled == true
        let authorityTransaction:
            AttachedDataSemanticAuthorityTransaction?
        if semanticCleanupRequired {
            guard let semanticAuthorityChangeHandler else {
                throw AttachedDataSourceFailureCode.atomicPublicationFailed
            }
            let transaction = semanticAuthorityChangeHandler(
                "semantic_index_attached_source_generation_changed"
            )
            guard await transaction.prepare() else {
                _ = await transaction.abort(
                    canonicalStateUnchanged: true
                )
                throw AttachedDataSourceFailureCode.atomicPublicationFailed
            }
            authorityTransaction = transaction
        } else {
            authorityTransaction = nil
        }
        var vaultPublicationCommitted = false
        do {
            try store.saveAttachedDataSource(
                source,
                securityScopedBookmark: observation.securityScopedBookmark
            )
            emitTrace(
                event: operation == .refresh
                    ? .attachedRefresh : .attachedImport,
                status: .started,
                reasonCode: "attached_data_publication_started",
                source: source
            )

            let materialized = try await materialize(
                observation: observation,
                selections: selections,
                bookmark: observation.securityScopedBookmark
            )
            let mutation = try generationMutation(
                source: source,
                materialization: materialized,
                generationReceiptHash: planDigest
            )
            try Task.checkCancellation()
            let result = try await vaultController.admitConnectorGeneration(
                mutation,
                trace: .init()
            )
            vaultPublicationCommitted = true
            // The atomic Vault commit is the publication boundary. A cancellation
            // arriving after it returns cannot retroactively classify the accepted
            // generation as failed or expose a stale predecessor as current.
            let accountID = Self.accountIdentifier(sourceIdentifier: source.id)
            guard result.generationReceiptHash == planDigest,
                  let marker = try await vaultController.database
                    .connectorGenerationMarker(accountID: accountID),
                  marker.generationReceiptHash == planDigest
            else { throw AttachedDataSourceFailureCode.atomicPublicationFailed }
            let finalized = try finalizedPublication(
                source: source,
                plan: plan,
                marker: marker,
                operation: operation
            )
            source = finalized.source
            try store.finalizeAttachedDataSourcePublication(
                source: finalized.source,
                receipt: finalized.receipt,
                securityScopedBookmark: mode == .linkedReadOnly
                    ? materialized.observation.securityScopedBookmark : nil,
                removeBookmark: mode == .importedSnapshot
            )
            let authorityResolved = await authorityTransaction?.complete()
                ?? true
            if !authorityResolved {
                source.state = .degraded
                source.lastErrorReasonCode =
                    "attached_data_semantic_authority_resolution_failed"
                source.updatedAt = .now
                try store.saveAttachedDataSource(source)
            }
            emitTrace(
                event: operation == .refresh ? .attachedRefresh : .attachedImport,
                status: .success,
                reasonCode: finalized.receipt.reasonCode,
                source: source,
                recordCount: marker.recordCount
            )
            return authorityResolved
        } catch {
            _ = await authorityTransaction?.abort(
                canonicalStateUnchanged: !vaultPublicationCommitted
            )
            throw error
        }
    }

    func materialize(
        observation: AttachedDataFileObservation,
        selections: [AttachedDataSourceSelection],
        bookmark: Data
    ) async throws -> AttachedDataMaterialization {
        let resolved = try await fileAuthority.withResolvedSource(
            bookmark: bookmark,
            expectedIdentity: observation.identity
        ) { [sqliteSource, jsonParser] authorizedURL, before, deadline in
            guard before.sourceDigest == observation.sourceDigest else {
                throw AttachedDataFileFailureCode.identityChanged
            }
            switch observation.kind {
            case .sqlite:
                let selected = selections.map {
                    AttachedSQLiteSelection(
                        objectName: $0.sourceIdentifier,
                        selectedColumns: $0.selectedFields,
                        allowTruncation: $0.allowsRecordTruncation
                    )
                }
                let materialized = try await sqliteSource.materialize(
                    at: authorizedURL,
                    selections: selected,
                    operationDeadline: deadline
                )
                let containers = try materialized.containers.map { container in
                    guard let selection = selections.first(where: {
                        $0.sourceIdentifier == container.objectName
                    }) else { throw AttachedDataSourceFailureCode.invalidSelection }
                    return AttachedDataMaterializedContainer(
                        selection: selection,
                        records: container.records.map {
                            AttachedDataMaterializedRecord(
                                stableIdentifier: $0.stableIdentity,
                                normalizedText: ConnectorTextNormalization.text(
                                    $0.normalizedText
                                ),
                                contentHash: $0.canonicalRecordHash,
                                recordLocator: container.objectName,
                                identityStrategy: $0.identityStrategy.rawValue,
                                blobCount: $0.blobCount,
                                wasTruncated: false
                            )
                        },
                        truncationCount: container.truncatedCount
                    )
                }
                return (containers, Int64(materialized.totalMaterializedBytes))
            case .json:
                let data = try Data(contentsOf: authorizedURL, options: .mappedIfSafe)
                let document = try jsonParser.parse(data)
                var containers: [AttachedDataMaterializedContainer] = []
                var bytes: Int64 = 0
                for selection in selections {
                    let idPointer = selection.recordIdentityStrategy
                        == .explicitJSONID
                        ? selection.identityFields.first : nil
                    let root = try document.recordRoot(
                        atJSONPointer: selection.sourceIdentifier,
                        explicitIDPointer: idPointer
                    )
                    var records: [AttachedDataMaterializedRecord] = []
                    for record in root.records {
                        let pointers = selection.selectedFields.map {
                            $0 == "$" ? "" : $0
                        }
                        let normalized = try record.normalizedSelectedFieldText(
                            selectedFieldPointers: pointers
                        )
                        let text = ConnectorTextNormalization.text(normalized.text)
                        bytes += Int64(text.lengthOfBytes(using: .utf8))
                        guard bytes <= 32 * 1_024 * 1_024 else {
                            throw AttachedJSONFailureCode.maximumAggregateBytesExceeded
                        }
                        records.append(.init(
                            stableIdentifier: record.stableIdentifier,
                            normalizedText: text,
                            contentHash: record.canonicalSHA256,
                            recordLocator: record.jsonPointer.isEmpty
                                ? "$" : record.jsonPointer,
                            identityStrategy: record.identityStrategy.rawValue,
                            blobCount: 0,
                            wasTruncated: normalized.wasTruncated
                        ))
                    }
                    containers.append(.init(
                        selection: selection,
                        records: records,
                        truncationCount: 0
                    ))
                }
                return (containers, bytes)
            }
        }
        return .init(
            observation: resolved.1,
            containers: resolved.0.0,
            materializedByteCount: resolved.0.1
        )
    }

    func generationMutation(
        source: AttachedDataSourceRecord,
        materialization: AttachedDataMaterialization,
        generationReceiptHash: String
    ) throws -> VaultConnectorGenerationMutation {
        let provider = VaultProviderKind.localImport
        guard let generationIdentifier =
                source.pendingGenerationIdentifier
        else { throw AttachedDataSourceFailureCode.invalidImportPlan }
        let publishedEpoch = source.currentEpoch + 1
        let accountID = VaultIdentity.accountID(
            provider: provider.rawValue,
            providerAccountID: source.id
        )
        let timestamp = materialization.observation.modificationDate
        let account = VaultAccountInput(
            id: accountID,
            provider: provider.rawValue,
            providerAccountID: source.id,
            displayName: source.displayName,
            createdAt: source.createdAt,
            updatedAt: timestamp
        )
        var containers: [VaultContainerInput] = []
        var records: [VaultRecordInput] = []
        for container in materialization.containers {
            let selection = container.selection
            let containerID = VaultIdentity.containerID(
                provider: provider.rawValue,
                accountID: accountID,
                providerContainerID: selection.id
            )
            containers.append(.init(
                id: containerID,
                accountID: accountID,
                providerContainerID: selection.id,
                kind: VaultContainerKind.importedCollection.rawValue,
                displayName: selection.displayName,
                createdAt: source.createdAt,
                updatedAt: timestamp
            ))
            guard !container.records.isEmpty else { continue }
            let receipt = try ConnectorPaginationReceipt(
                checkpointIdentifier: "attached:\(source.id):\(selection.id)",
                streamIdentifier: selection.id,
                pageOrdinal: 0,
                requestCursor: nil,
                nextCursor: nil,
                sourceHighWatermark: materialization.observation.sourceDigest,
                isComplete: true
            )
            let descriptors = try container.records.map { record in
                let envelope = try ConnectorRecordEnvelope(
                    provider: provider.rawValue,
                    pseudonymousAccountIdentifier: source.id,
                    remoteRecordIdentifier: record.stableIdentifier,
                    recordType: source.kind == .sqlite
                        ? "attached_sqlite_record" : "attached_json_record",
                    parentOrThreadIdentifier: nil,
                    sourceTimestamp: timestamp,
                    ingestionTimestamp: timestamp,
                    normalizedText: record.normalizedText,
                    editOrVersionIdentifier: record.contentHash,
                    sourceHash: record.contentHash,
                    paginationReceipt: receipt,
                    provenance: try .init(
                        sourceSystem: "attached_data",
                        sourceContainerIdentifier: selection.id,
                        sourceURL: nil,
                        retrievedAt: timestamp,
                        policyBasis: "explicit_user_selected_local_attached_data"
                    ),
                    policyClassification: source.localModelConsentEnabled
                        ? .localIndexAllowed : .archiveOnly,
                    contentClassification: .providerRecord,
                    containsSensitiveMaterial: false
                )
                return try ConnectorVaultRecordDescriptor(
                    envelope: envelope,
                    title: "\(selection.displayName) record",
                    additionalMetadata: [
                        "attached_source_id": source.id,
                        "attached_source_kind": source.kind.rawValue,
                        "attached_source_epoch": String(publishedEpoch),
                        "attached_source_sha256":
                            materialization.observation.sourceDigest,
                        "attached_selection_id": selection.id,
                        "attached_selection_source":
                            selection.kind == .jsonRoot
                                && selection.sourceIdentifier.isEmpty
                                ? "$" : selection.sourceIdentifier,
                        "attached_schema_sha256": selection.schemaDigest,
                        "attached_record_locator": record.recordLocator,
                        "attached_identity_strategy": record.identityStrategy,
                        "attached_generation_id": generationIdentifier,
                        "attached_generation_receipt_sha256":
                            generationReceiptHash,
                        "attached_blob_count": String(record.blobCount),
                        "attached_truncated": String(record.wasTruncated),
                    ]
                )
            }
            let mutation = try ConnectorVaultPage(
                kind: .attachedData,
                provider: provider,
                providerAccountIdentifier: source.id,
                accountDisplayName: source.displayName,
                providerContainerIdentifier: selection.id,
                containerDisplayName: selection.displayName,
                containerKind: .importedCollection,
                paginationReceipt: receipt,
                records: descriptors
            ).mutation(at: source.createdAt)
            records.append(contentsOf: mutation.records)
        }
        return .init(
            account: account,
            containers: containers,
            records: records,
            generationReceiptHash: generationReceiptHash,
            attachmentBlobCount: materialization.blobCount,
            truncationCount: materialization.truncationCount,
            materializedByteCount: materialization.materializedByteCount
        )
    }

    func finalizedPublication(
        source original: AttachedDataSourceRecord,
        plan: AttachedDataImportPlan,
        marker: VaultConnectorGenerationMarker,
        operation: AttachedDataSourceReceiptOperation
    ) throws -> AttachedDataPublicationFinalization {
        guard marker.generationReceiptHash == plan.planDigest,
              plan.sourceIdentifier == original.id,
              original.pendingGenerationIdentifier
                == plan.generationIdentifier,
              original.frozenImportPlan == plan
        else { throw AttachedDataSourceFailureCode.atomicPublicationFailed }

        let completedAt = max(marker.committedAt, plan.createdAt)
        let reasonCode: String
        switch operation {
        case .refresh:
            reasonCode = "attached_data_refresh_succeeded"
        case .reauthorize:
            reasonCode = "attached_data_reauthorization_succeeded"
        default:
            reasonCode = "attached_data_import_succeeded"
        }
        let receiptID = "receipt:\(plan.planDigest.prefix(40))"
        let receiptHash = Self.digest([
            plan.planDigest,
            String(marker.insertedCount),
            String(marker.updatedCount),
            String(marker.tombstonedCount),
            String(marker.recordCount),
            reasonCode,
        ])
        let receipt = try AttachedDataSourceReceipt(
            id: receiptID,
            sourceIdentifier: original.id,
            sourceKind: original.kind,
            mode: original.mode,
            operation: operation,
            outcome: .succeeded,
            reasonCode: reasonCode,
            traceIdentifier: "trace:\(plan.planDigest.prefix(40))",
            importPlanIdentifier: plan.id,
            generationIdentifier: plan.generationIdentifier,
            priorGenerationIdentifier: plan.priorGenerationIdentifier,
            sourceDigest: plan.sourceDigest,
            shapeDigest: plan.shapeDigest,
            selectionDigest: plan.selectionDigest,
            startedAt: plan.createdAt,
            completedAt: completedAt,
            importedItemCount:
                marker.insertedCount + marker.resurrectedCount,
            updatedItemCount: marker.updatedCount,
            tombstonedItemCount: marker.tombstonedCount,
            skippedItemCount: 0,
            attachmentBlobCount: marker.attachmentBlobCount,
            truncationCount: marker.truncationCount,
            materializedByteCount: marker.materializedByteCount,
            pageCount: marker.containerCount,
            bookmarkRetained: original.mode == .linkedReadOnly,
            priorGenerationRetained: false,
            atomicPublicationCommitted: true,
            provenanceVersion: plan.provenanceVersion,
            receiptHash: receiptHash
        )

        var source = original
        source.fileIdentity = plan.fileIdentity
        source.sourceDigest = plan.sourceDigest
        source.shapeDigest = plan.shapeDigest
        source.selections = plan.selections
        source.state = .connected
        source.currentEpoch += 1
        source.lastSuccessfulRefreshAt = completedAt
        source.lastAttemptedRefreshAt = plan.createdAt
        source.itemCount = marker.recordCount
        source.skippedItemCount = 0
        source.attachmentBlobCount = marker.attachmentBlobCount
        source.truncationCount = marker.truncationCount
        let accountID = Self.accountIdentifier(sourceIdentifier: source.id)
        source.importedLocalContainerIdentifiers = plan.selections.map {
            VaultIdentity.containerID(
                provider: VaultProviderKind.localImport.rawValue,
                accountID: accountID,
                providerContainerID: $0.id
            )
        }.sorted()
        source.cancellationState = .completed
        source.lastErrorReasonCode = nil
        source.localDataRetentionState = .retained
        source.latestReceiptIdentifier = receipt.id
        source.currentGenerationIdentifier = plan.generationIdentifier
        source.pendingGenerationIdentifier = nil
        source.frozenImportPlan = nil
        if source.mode == .importedSnapshot {
            source.access = .notRetained
            source.refreshEnabled = false
        }
        source.automaticRefreshEnabled = false
        source.updatedAt = completedAt
        try source.validate()
        return .init(source: source, receipt: receipt)
    }

    func finalizedRemoval(
        source original: AttachedDataSourceRecord,
        startedAt: Date,
        reasonCode: String,
        recordsDeleted: Int
    ) throws -> AttachedDataRemovalFinalization {
        guard recordsDeleted >= 0 else {
            throw AttachedDataSourceFailureCode.invalidCounts
        }
        let completedAt = max(Date(), startedAt)
        let removalDigest = Self.digest([
            original.id,
            String(Int64((startedAt.timeIntervalSince1970 * 1_000).rounded())),
            reasonCode,
        ])
        let receiptID = "receipt:removal:\(removalDigest.prefix(32))"
        let receiptHash = Self.digest([
            removalDigest,
            String(recordsDeleted),
            original.currentGenerationIdentifier ?? "none",
        ])
        var source = original
        source.itemCount = 0
        source.skippedItemCount = 0
        source.attachmentBlobCount = 0
        source.truncationCount = 0
        source.importedLocalContainerIdentifiers = []
        source.currentGenerationIdentifier = nil
        source.pendingGenerationIdentifier = nil
        source.frozenImportPlan = nil
        source.localDataRetentionState = .removed
        source.state = source.access.continuingAccessRetained
            ? .disconnected : .disabled
        source.cancellationState = .none
        source.lastErrorReasonCode = nil
        source.latestReceiptIdentifier = receiptID
        source.updatedAt = completedAt
        try source.validate()
        let receipt = try AttachedDataSourceReceipt(
            id: receiptID,
            sourceIdentifier: source.id,
            sourceKind: source.kind,
            mode: source.mode,
            operation: .removeLocalData,
            outcome: .succeeded,
            reasonCode: reasonCode,
            traceIdentifier: "trace:removal:\(removalDigest.prefix(32))",
            priorGenerationIdentifier: original.currentGenerationIdentifier,
            sourceDigest: original.sourceDigest,
            shapeDigest: original.shapeDigest,
            selectionDigest: Self.selectionDigest(original.selections),
            startedAt: startedAt,
            completedAt: completedAt,
            importedItemCount: 0,
            updatedItemCount: 0,
            tombstonedItemCount: recordsDeleted,
            skippedItemCount: 0,
            attachmentBlobCount: 0,
            truncationCount: 0,
            materializedByteCount: 0,
            pageCount: 0,
            bookmarkRetained: source.access.continuingAccessRetained,
            priorGenerationRetained: false,
            atomicPublicationCommitted: false,
            provenanceVersion: source.provenanceVersion,
            receiptHash: receiptHash
        )
        return .init(source: source, receipt: receipt)
    }

    func reconcileInterruptedRemoval(
        _ source: AttachedDataSourceRecord
    ) async throws {
        let accountID = Self.accountIdentifier(sourceIdentifier: source.id)
        if try await vaultController.database.accountExists(id: accountID) {
            var retained = source
            retained.localDataRetentionState = .retained
            retained.state = .degraded
            retained.lastErrorReasonCode =
                "attached_data_local_data_removal_interrupted"
            retained.updatedAt = .now
            try retained.validate()
            try store.saveAttachedDataSource(retained)
            return
        }
        let finalized = try finalizedRemoval(
            source: source,
            startedAt: source.updatedAt,
            reasonCode: "attached_data_local_data_removal_reconciled",
            recordsDeleted: source.itemCount
        )
        try store.finalizeAttachedDataSourceRemoval(
            source: finalized.source,
            receipt: finalized.receipt
        )
    }

    static func accountIdentifier(sourceIdentifier: String) -> String {
        VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceIdentifier
        )
    }

    static func recoveredOperation(
        source: AttachedDataSourceRecord,
        plan: AttachedDataImportPlan
    ) -> AttachedDataSourceReceiptOperation {
        if source.state == .refreshing { return .refresh }
        return plan.priorGenerationIdentifier == nil
            ? .importSnapshot : .reauthorize
    }

    func recordPublicationFailure(
        _ error: Error,
        sourceIdentifier: String,
        kind: AttachedDataSourceKind,
        mode: AttachedDataSourceMode,
        operation: AttachedDataSourceReceiptOperation
    ) async {
        let cancelled = error is CancellationError || Task.isCancelled
        if var source = try? requiredSource(sourceIdentifier) {
            let frozenImportPlan = source.frozenImportPlan
            let attemptedSourceDigest = frozenImportPlan?.sourceDigest
                ?? source.sourceDigest
            let attemptedShapeDigest = frozenImportPlan?.shapeDigest
                ?? source.shapeDigest
            let retainedSourceDigest = frozenImportPlan?.priorSourceDigest
            let retainedShapeDigest = frozenImportPlan?.priorShapeDigest
            if let plan = frozenImportPlan {
                do {
                    let accountID = Self.accountIdentifier(
                        sourceIdentifier: source.id
                    )
                    if let marker = try await vaultController.database
                        .connectorGenerationMarker(accountID: accountID),
                       marker.generationReceiptHash == plan.planDigest {
                        // The Vault transaction committed. Preserve the frozen
                        // plan so launch reconciliation can finish the private
                        // source record and receipt without republishing.
                        source.lastErrorReasonCode = AttachedDataSourceFailureCode
                            .atomicPublicationFailed.rawValue
                        source.cancellationState = .interrupted
                        source.updatedAt = .now
                        try? store.saveAttachedDataSource(source)
                        reload(reportFailure: false)
                        present(AttachedDataSourceFailureCode.atomicPublicationFailed)
                        return
                    }
                } catch {
                    // Marker readability is the only authority that can prove
                    // the commit did not occur. Fail closed and retain the plan.
                    reload(reportFailure: false)
                    present(AttachedDataSourceFailureCode.atomicPublicationFailed)
                    return
                }
            }
            let priorRetained = source.currentGenerationIdentifier != nil
            source.state = priorRetained ? .degraded : .failed
            source.pendingGenerationIdentifier = nil
            source.frozenImportPlan = nil
            source.cancellationState = cancelled ? .completed : .none
            source.lastErrorReasonCode = reasonCode(error)
            if priorRetained,
               let retainedSourceDigest,
               let retainedShapeDigest {
                source.sourceDigest = retainedSourceDigest
                source.shapeDigest = retainedShapeDigest
            } else if priorRetained, frozenImportPlan != nil {
                // Legacy frozen plans did not persist the accepted authority.
                // Clear the attempted authority rather than pairing it with
                // the retained generation and exposing mismatched provenance.
                source.sourceDigest = nil
                source.shapeDigest = nil
                source.localModelConsentEnabled = false
            }
            if source.mode == .linkedReadOnly,
               source.access.continuingAccessRetained,
               let bookmarkState = authorityFailureBookmarkState(error) {
                source.access = try! AttachedDataSourceAccess(
                    bookmarkState: bookmarkState,
                    continuingAccessRetained: true,
                    lastAuthorizedAt: source.access.lastAuthorizedAt,
                    lastResolvedAt: source.access.lastResolvedAt
                )
            }
            source.updatedAt = .now
            try? store.saveAttachedDataSource(source)
            let startedAt = source.lastAttemptedRefreshAt ?? source.updatedAt
            if let receipt = try? makeNonPublicationReceipt(
                source: source,
                operation: operation,
                startedAt: startedAt,
                outcome: cancelled ? .cancelled : .failed,
                reasonCode: source.lastErrorReasonCode
                    ?? "attached_data_publication_failed",
                priorGenerationRetained: priorRetained,
                sourceDigest: attemptedSourceDigest,
                shapeDigest: attemptedShapeDigest
            ) {
                try? store.saveAttachedDataSourceReceipt(receipt)
            }
            emitTrace(
                event: operation == .refresh ? .attachedRefresh : .attachedImport,
                status: cancelled ? .degraded : .failed,
                reasonCode: source.lastErrorReasonCode
                    ?? "attached_data_publication_failed",
                source: source
            )
        }
        reload(reportFailure: false)
        present(error)
    }

    func makeNonPublicationReceipt(
        source: AttachedDataSourceRecord,
        operation: AttachedDataSourceReceiptOperation,
        startedAt: Date,
        outcome: AttachedDataSourceReceiptOutcome,
        reasonCode: String,
        tombstonedCount: Int = 0,
        priorGenerationRetained: Bool = false,
        sourceDigest: String? = nil,
        shapeDigest: String? = nil
    ) throws -> AttachedDataSourceReceipt {
        let completedAt = Date()
        let receiptHash = Self.digest([
            source.id,
            operation.rawValue,
            outcome.rawValue,
            reasonCode,
            String(tombstonedCount),
            String(completedAt.timeIntervalSince1970),
        ])
        return try .init(
            id: "receipt:\(UUID().uuidString.lowercased())",
            sourceIdentifier: source.id,
            sourceKind: source.kind,
            mode: source.mode,
            operation: operation,
            outcome: outcome,
            reasonCode: reasonCode,
            traceIdentifier: UUID().uuidString.lowercased(),
            generationIdentifier: nil,
            priorGenerationIdentifier: source.currentGenerationIdentifier,
            sourceDigest: sourceDigest ?? source.sourceDigest,
            shapeDigest: shapeDigest ?? source.shapeDigest,
            selectionDigest: source.selections.isEmpty
                ? nil : Self.selectionDigest(source.selections),
            startedAt: startedAt,
            completedAt: completedAt,
            importedItemCount: 0,
            updatedItemCount: 0,
            tombstonedItemCount: tombstonedCount,
            skippedItemCount: 0,
            attachmentBlobCount: 0,
            truncationCount: 0,
            materializedByteCount: 0,
            pageCount: 0,
            bookmarkRetained: source.access.continuingAccessRetained,
            priorGenerationRetained: priorGenerationRetained,
            atomicPublicationCommitted: false,
            provenanceVersion: source.provenanceVersion,
            receiptHash: receiptHash
        )
    }

    func emitTrace(
        event: VaultTraceEventName,
        status: VaultTraceStatus,
        reasonCode: String,
        source: AttachedDataSourceRecord,
        recordCount: Int? = nil
    ) {
        let context = VaultTraceContext()
        var metadata: [(VaultTraceMetadataKey, String)] = [
            (.sourceKind, source.kind.rawValue),
            (.sourceHash, source.sourceDigest.map(VaultPrivacy.checksumPrefix)
                ?? "none"),
            (.skippedCount, String(source.skippedItemCount)),
            (.truncationCount, String(source.truncationCount)),
        ]
        if let recordCount { metadata.append((.recordCount, String(recordCount))) }
        VaultProductionTraceLogger.emit(.init(
            ts: .now,
            event: event,
            traceID: context.traceID,
            spanID: context.spanID,
            parentSpanID: nil,
            component: "attached-data-sources",
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: nil,
            metadata: .init(metadata)
        ))
    }

    func reasonCode(_ error: Error) -> String {
        if error is CancellationError { return "attached_data_operation_cancelled" }
        if let value = error as? AttachedDataSourceFailureCode { return value.rawValue }
        if let value = error as? AttachedDataFileFailureCode { return value.rawValue }
        if let value = error as? AttachedSQLiteFailureCode { return value.rawValue }
        if let value = error as? AttachedJSONFailureCode { return value.rawValue }
        if let value = error as? ConnectorVaultAdmissionFailure { return value.rawValue }
        return "attached_data_operation_failed"
    }

    func authorityFailureBookmarkState(
        _ error: Error
    ) -> AttachedDataBookmarkState? {
        if let failure = error as? AttachedDataFileFailureCode {
            switch failure {
            case .bookmarkStale:
                return .stale
            case .authorizationFailed, .bookmarkUnavailable, .unavailable,
                 .symbolicLinkDenied, .aliasDenied, .nonRegularFileDenied,
                 .identityChanged:
                return .reauthorizationRequired
            case .unsupportedType, .tooLarge, .readFailed,
                 .coherentSnapshotUnavailable, .invalidJSONHeader,
                 .sqliteHeaderMismatch, .cancelled, .timedOut:
                return nil
            }
        }
        if let failure = error as? AttachedDataSourceFailureCode {
            switch failure {
            case .staleBookmark:
                return .stale
            case .bookmarkRequired, .reauthorizationRequired,
                 .sourceIdentityChanged, .sourceUnavailable,
                 .readOnlyAuthorityRequired, .securityScopeFailed:
                return .reauthorizationRequired
            default:
                return nil
            }
        }
        return nil
    }

    static func sqliteDraftAdmission(
        _ preview: AttachedSQLitePreview
    ) throws -> (
        selections: [AttachedDataSourceSelection],
        defaultSelectionIdentifiers: Set<String>,
        notesBySelectionIdentifier: [String: String],
        hasTruncationRisk: Bool
    ) {
        let budgets = AttachedDataSourceBudgets.sqliteStandard
        var remainingRecords = budgets.maximumRecords
        var selections: [AttachedDataSourceSelection] = []
        var defaultIdentifiers = Set<String>()
        var notes: [String: String] = [:]
        var hasTruncationRisk = false
        let objects = preview.objects
            .filter { $0.isSelectable && !$0.defaultSelectedColumns.isEmpty }
            .prefix(VaultLimits.maximumConnectorGenerationContainers)

        for object in objects {
            let lowerName = object.name.lowercased()
            let isMigrationJournal = lowerName.contains("migration")
                || lowerName.contains("schema_history")
                || lowerName.contains("databasechangelog")
                || lowerName == "alembic_version"
            let isPrivateMetadata = lowerName.hasPrefix("__")
                || lowerName.hasSuffix("_private_metadata")
                || lowerName.hasSuffix("_metadata")
                || [
                    "android_metadata", "room_master_table", "sequelize_meta",
                    "typeorm_metadata", "z_metadata", "z_primarykey",
                ].contains(lowerName)
            let exceedsRemaining = object.rowCountExceedsLimit
                || object.boundedRowCount > remainingRecords
            let requiresExplicitSelection = isMigrationJournal
                || isPrivateMetadata || exceedsRemaining
            let selection = try sqliteSelection(
                object,
                allowsRecordTruncation: exceedsRemaining
            )
            selections.append(selection)

            if requiresExplicitSelection {
                if exceedsRemaining {
                    hasTruncationRisk = true
                    notes[selection.id] =
                        "Not selected by default because it can exceed the "
                        + "source-wide \(budgets.maximumRecords)-record limit. "
                        + "Selecting it explicitly permits deterministic truncation at that limit."
                } else if isMigrationJournal {
                    notes[selection.id] =
                        "Not selected by default because its name identifies a migration journal. "
                        + "Select it only if these records are intentionally in scope."
                } else {
                    notes[selection.id] =
                        "Not selected by default because its name identifies application-private metadata. "
                        + "Select it only if these records are intentionally in scope."
                }
            } else {
                defaultIdentifiers.insert(selection.id)
                remainingRecords -= object.boundedRowCount
            }
        }
        return (selections, defaultIdentifiers, notes, hasTruncationRisk)
    }

    static func sqliteSelection(
        _ object: AttachedSQLiteObjectPreview,
        allowsRecordTruncation: Bool = false
    ) throws -> AttachedDataSourceSelection {
        let strategy: AttachedDataRecordIdentityStrategy
        switch object.identityStrategy {
        case .declaredPrimaryKey: strategy = .declaredPrimaryKey
        case .compositePrimaryKey: strategy = .compositePrimaryKey
        case .rowID: strategy = .rowID
        case .selectedRecordDigest: strategy = .canonicalRecordDigest
        }
        let schemaDigest = digest(
            [object.kind.rawValue, object.name] + object.columns.flatMap {
                [$0.name, $0.declaredType, String($0.primaryKeyOrdinal)]
            }
        )
        return try .init(
            id: "selection:\(digest(["sqlite", object.name]).prefix(32))",
            kind: object.kind == .view ? .sqliteView : .sqliteTable,
            sourceIdentifier: object.name,
            displayName: object.name,
            selectedFields: object.defaultSelectedColumns,
            searchableFields: object.defaultSelectedColumns,
            identityFields: strategy.requiresIdentityFields
                ? object.primaryKeyColumns : [],
            recordIdentityStrategy: strategy,
            schemaDigest: schemaDigest,
            estimatedRecordCount: object.boundedRowCount,
            estimatedBytes: nil,
            allowsRecordTruncation: allowsRecordTruncation
        )
    }

    static func jsonSelection(
        root: AttachedJSONRecordRoot,
        preservingSelectedFields requestedFields: [String]? = nil
    ) throws -> AttachedDataSourceSelection {
        let fields = root.inferredFields.map(\.jsonPointer)
        let identityPointer = root.records.compactMap(\.identityFieldPointer).first
        var selectedFields: [String]
        if fields.isEmpty {
            selectedFields = ["$"]
        } else if let requestedFields {
            let available = Set(fields)
            selectedFields = requestedFields.filter(available.contains)
            if selectedFields.isEmpty {
                selectedFields = Array(fields.prefix(128))
            }
        } else {
            selectedFields = Array(fields.prefix(128))
        }
        if let identityPointer, !selectedFields.contains(identityPointer) {
            if selectedFields.count >= 128 { selectedFields.removeLast() }
            selectedFields.append(identityPointer)
        }
        let strategy: AttachedDataRecordIdentityStrategy
        switch root.records.first?.identityStrategy {
        case .explicitIDField: strategy = .explicitJSONID
        case .recognizedIDField: strategy = .recognizedJSONID
        case .pointerAndDigest, .sourceRelativePointerAndDigest, nil:
            strategy = .jsonPointerAndDigest
        }
        let schemaDigest = digest(
            [root.jsonPointer, root.selectedValueKind.rawValue] +
                root.inferredFields.flatMap {
                    [$0.jsonPointer] + $0.valueKinds.map(\.rawValue)
                }
        )
        return try .init(
            id: "selection:\(digest(["json", root.jsonPointer]).prefix(32))",
            kind: .jsonRoot,
            sourceIdentifier: root.jsonPointer,
            displayName: root.jsonPointer.isEmpty
                ? "Top-level JSON records" : "JSON \(root.jsonPointer)",
            selectedFields: selectedFields,
            searchableFields: selectedFields,
            identityFields: identityPointer.map { [$0] } ?? [],
            recordIdentityStrategy: strategy,
            schemaDigest: schemaDigest,
            estimatedRecordCount: root.records.count,
            estimatedBytes: Int64(root.estimatedCanonicalRecordBytes)
        )
    }

    static func jsonAvailableFields(_ root: AttachedJSONRecordRoot) -> [String] {
        let fields = root.inferredFields.map(\.jsonPointer)
        return fields.isEmpty ? ["$"] : fields
    }

    static func replacingSelection(
        _ selection: AttachedDataSourceSelection,
        allowsRecordTruncation: Bool
    ) throws -> AttachedDataSourceSelection {
        try .init(
            id: selection.id,
            kind: selection.kind,
            sourceIdentifier: selection.sourceIdentifier,
            displayName: selection.displayName,
            selectedFields: selection.selectedFields,
            searchableFields: selection.searchableFields,
            identityFields: selection.identityFields,
            includedBlobBodyFields: selection.includedBlobBodyFields,
            recordIdentityStrategy: selection.recordIdentityStrategy,
            schemaDigest: selection.schemaDigest,
            estimatedRecordCount: selection.estimatedRecordCount,
            estimatedBytes: selection.estimatedBytes,
            allowsRecordTruncation: allowsRecordTruncation
        )
    }

    static func replacingPreview(
        _ preview: AttachedDataSourcePreview,
        candidateSelections: [AttachedDataSourceSelection]
    ) throws -> AttachedDataSourcePreview {
        try .init(
            id: preview.id,
            sourceIdentifier: preview.sourceIdentifier,
            kind: preview.kind,
            originalFilename: preview.originalFilename,
            privacySafeLocationDescriptor: preview.privacySafeLocationDescriptor,
            fileIdentity: preview.fileIdentity,
            sourceDigest: preview.sourceDigest,
            shapeDigest: preview.shapeDigest,
            candidateSelections: candidateSelections,
            sampleRecords: preview.sampleRecords,
            estimatedRecordCount: preview.estimatedRecordCount,
            estimatedBytes: preview.estimatedBytes,
            warnings: preview.warnings,
            appliedBudgets: preview.appliedBudgets,
            detectedAt: preview.detectedAt
        )
    }

    static func domainPreview(
        observation: AttachedDataFileObservation,
        sourceIdentifier: String,
        selections: [AttachedDataSourceSelection],
        samples: [AttachedDataPreviewRecord],
        shapeDigest: String,
        estimatedRecords: Int,
        estimatedBytes: Int64,
        warnings: [AttachedDataSourceFailureCode] = []
    ) throws -> AttachedDataSourcePreview {
        let budgets = AttachedDataSourceBudgets.standard(for: observation.kind)
        return try .init(
            id: "preview:\(UUID().uuidString.lowercased())",
            sourceIdentifier: sourceIdentifier,
            kind: observation.kind,
            originalFilename: observation.originalFilename,
            privacySafeLocationDescriptor: observation.locationDescriptor,
            fileIdentity: observation.identity,
            sourceDigest: observation.sourceDigest,
            shapeDigest: shapeDigest,
            candidateSelections: selections,
            sampleRecords: samples,
            estimatedRecordCount: estimatedRecords,
            estimatedBytes: estimatedBytes,
            warnings: warnings,
            appliedBudgets: budgets
        )
    }

    static func sqliteSamples(
        _ preview: AttachedSQLitePreview
    ) throws -> [AttachedDataPreviewRecord] {
        var records: [AttachedDataPreviewRecord] = []
        for object in preview.objects where object.isSelectable {
            guard records.count < 5 else { break }
            let fields = try object.samples.prefix(8).map {
                try AttachedDataPreviewField(
                    name: $0.columnName,
                    kind: .text,
                    displayValue: $0.values.prefix(3).joined(separator: " · ")
                )
            }
            if !fields.isEmpty {
                records.append(try .init(
                    id: "sample:\(digest([object.name]).prefix(32))",
                    fields: fields
                ))
            }
        }
        return records
    }

    static func jsonSamples(
        root: AttachedJSONRecordRoot
    ) throws -> [AttachedDataPreviewRecord] {
        try root.records.prefix(5).enumerated().map { index, record in
            let fields: [AttachedDataPreviewField] = try root.inferredFields
                .prefix(8).compactMap {
                field -> AttachedDataPreviewField? in
                guard let value = try? record.value.value(
                    atJSONPointer: field.jsonPointer
                ) else { return nil }
                return try AttachedDataPreviewField(
                    name: field.jsonPointer.isEmpty ? "$" : field.jsonPointer,
                    kind: previewKind(value.kind),
                    displayValue: String(
                        (try value.canonicalString()).prefix(200)
                    ),
                    isTruncated: (try value.canonicalString()).count > 200
                )
            }
            return try .init(
                id: "sample:\(index):\(record.canonicalSHA256.prefix(24))",
                fields: fields
            )
        }
    }

    static func previewKind(
        _ kind: AttachedJSONValueKind
    ) -> AttachedDataPreviewValueKind {
        switch kind {
        case .null: .null
        case .boolean: .boolean
        case .integer: .integer
        case .floatingPoint: .real
        case .string: .text
        case .object: .object
        case .array: .array
        }
    }

    static func selectionDigest(
        _ selections: [AttachedDataSourceSelection]
    ) -> String {
        AttachedDataImportPlan.frozenSelectionDigest(for: selections)
    }

    nonisolated static func digest(_ fields: [String]) -> String {
        let material = fields.map {
            "\($0.lengthOfBytes(using: .utf8)):\($0)"
        }.joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
