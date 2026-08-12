import Foundation
import SQLite3
import XCTest
@testable import LokiBrief

private actor AttachedSemanticPreparationGate {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }
}

private actor AttachedBrowseSearchGate {
    private var request: VaultSearchRequest?
    private var requestWaiters:
        [CheckedContinuation<VaultSearchRequest, Never>] = []
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause(_ request: VaultSearchRequest) async {
        self.request = request
        let pendingRequestWaiters = requestWaiters
        requestWaiters.removeAll()
        pendingRequestWaiters.forEach { $0.resume(returning: request) }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async -> VaultSearchRequest {
        if let request { return request }
        return await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        pendingReleaseWaiters.forEach { $0.resume(returning: ()) }
    }
}

@MainActor
private final class AttachedSemanticAuthorityProbe {
    private let gate = AttachedSemanticPreparationGate()
    private let resolutionSucceeds: Bool
    private(set) var reasonCodes: [String] = []
    private(set) var resolutions: [String] = []

    init(resolutionSucceeds: Bool = true) {
        self.resolutionSucceeds = resolutionSucceeds
    }

    func transaction(
        reasonCode: String
    ) -> AttachedDataSemanticAuthorityTransaction {
        reasonCodes.append(reasonCode)
        let gate = self.gate
        return AttachedDataSemanticAuthorityTransaction(
            preparation: Task { await gate.wait() },
            finisher: { [weak self] resolution in
                switch resolution {
                case .committed:
                    self?.resolutions.append("committed")
                    return self?.resolutionSucceeds == true
                case .unchanged:
                    self?.resolutions.append("unchanged")
                    return self?.resolutionSucceeds == true
                case .unresolved:
                    self?.resolutions.append("unresolved")
                    return false
                }
            }
        )
    }

    func releasePreparation(_ result: Bool) async {
        await gate.release(result)
    }
}

@MainActor
final class AttachedDataSourcesControllerTests: XCTestCase, @unchecked Sendable {
    func testLinkedSQLiteCommitSurvivesRestartAndCarriesProvenanceSearchAndConsent() async throws {
        let directory = try makeDirectory(named: "linked-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        let vaultURL = directory.appendingPathComponent("Vault.sqlite3")
        var sourceIdentifier = ""

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            stack.controller.configureSemanticAuthorityChangeHandler { _ in
                self.allowingSemanticAuthorityTransaction()
            }
            let prepared = await stack.controller.preparePreview(at: sourceURL)
            XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
            let draft = try XCTUnwrap(stack.controller.pendingDraft)
            XCTAssertEqual(draft.observation.kind, .sqlite)
            XCTAssertEqual(draft.mode, .linkedReadOnly)
            XCTAssertFalse(draft.selectedSelections.isEmpty)
            stack.controller.setPendingLocalModelConsent(true)
            let imported = await stack.controller.importPendingPreview()
            XCTAssertTrue(imported)

            let source = try XCTUnwrap(stack.controller.sources.first)
            sourceIdentifier = source.id
            XCTAssertEqual(source.state, .connected)
            XCTAssertEqual(source.mode, .linkedReadOnly)
            XCTAssertTrue(source.access.continuingAccessRetained)
            XCTAssertNotNil(try stack.store.attachedDataSourceBookmark(id: source.id))
            XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
            try await stack.vault.database.close()
        }

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            // AppModel installs semantic authority on every launch. Mirror
            // that lifecycle wiring after reopening the file-backed fixture.
            var semanticAuthorityReasons: [String] = []
            stack.controller.configureSemanticAuthorityChangeHandler {
                reasonCode in
                semanticAuthorityReasons.append(reasonCode)
                return self.allowingSemanticAuthorityTransaction()
            }
            let source = try XCTUnwrap(
                stack.controller.sources.first { $0.id == sourceIdentifier }
            )
            XCTAssertEqual(source.state, .connected)
            XCTAssertTrue(source.access.continuingAccessRetained)
            XCTAssertNotNil(try stack.store.attachedDataSourceBookmark(id: source.id))

            let admitted = try await envelopes(in: stack.vault, source: source)
            XCTAssertEqual(admitted.count, 2)
            XCTAssertTrue(admitted.allSatisfy {
                $0.provider == VaultProviderKind.localImport.rawValue
                    && $0.provenance.sourceSystem == "attached_data"
                    && $0.provenance.sourceURL == nil
                    && $0.provenance.policyBasis
                        == "explicit_user_selected_local_attached_data"
                    && $0.policyClassification == .localIndexAllowed
            })
            let alpha = try XCTUnwrap(admitted.first {
                $0.normalizedText.contains("Alpha")
            })
            let loadedRecord = try await stack.vault.database.record(
                id: "connector:\(alpha.deduplicationKey)"
            )
            let record = try XCTUnwrap(loadedRecord)
            XCTAssertEqual(record.metadata["attached_source_id"], source.id)
            XCTAssertEqual(record.metadata["attached_source_kind"], "sqlite")
            XCTAssertEqual(record.metadata["attached_identity_strategy"],
                           AttachedDataRecordIdentityStrategy.declaredPrimaryKey.rawValue)
            XCTAssertNil(record.sourceURL)
            XCTAssertFalse(record.metadata.values.contains(sourceURL.path))

            let controllerAccountID = VaultIdentity.accountID(
                provider: VaultProviderKind.localImport.rawValue,
                providerAccountID: source.id
            )
            let storedAccounts = try await stack.vault.database.accounts()
            let automaticScoped = try await stack.vault.database.search(.init(
                text: "Alpha",
                accountID: controllerAccountID,
                provider: VaultProviderKind.localImport.rawValue
            ))
            let likeScoped = try await stack.vault.database.search(.init(
                text: "Alpha",
                accountID: controllerAccountID,
                provider: VaultProviderKind.localImport.rawValue,
                preference: .likeOnly
            ))
            XCTAssertEqual(storedAccounts.map(\.id), [controllerAccountID])
            XCTAssertEqual(storedAccounts.map(\.provider), [
                VaultProviderKind.localImport.rawValue,
            ])
            XCTAssertEqual(automaticScoped.mode, .fullText)
            XCTAssertEqual(likeScoped.mode, .likeFallback)
            XCTAssertEqual(automaticScoped.results.map(\.id), [record.id])
            XCTAssertEqual(likeScoped.results.map(\.id), [record.id])

            await stack.controller.browse(
                sourceIdentifier: source.id,
                query: "Alpha"
            )
            let page = try XCTUnwrap(stack.controller.browserPage)
            XCTAssertEqual(page.sourceIdentifier, source.id)
            XCTAssertEqual(page.offset, 0)
            XCTAssertEqual(page.results.count, 1)
            XCTAssertEqual(page.results.first?.id, record.id)

            let consentDisabled = await stack.controller.setLocalModelConsent(
                sourceIdentifier: source.id,
                enabled: false
            )
            XCTAssertTrue(consentDisabled)
            XCTAssertEqual(semanticAuthorityReasons, [
                "semantic_index_attached_source_consent_revoked",
            ])
            XCTAssertFalse(try XCTUnwrap(
                stack.controller.sources.first { $0.id == source.id }
            ).localModelConsentEnabled)
            let refreshedSuccessfully = await stack.controller.refresh(
                sourceIdentifier: source.id
            )
            XCTAssertTrue(refreshedSuccessfully)
            XCTAssertEqual(semanticAuthorityReasons, [
                "semantic_index_attached_source_consent_revoked",
            ])
            let refreshed = try XCTUnwrap(
                stack.controller.sources.first { $0.id == source.id }
            )
            let refreshedEnvelopes = try await envelopes(
                in: stack.vault,
                source: refreshed
            )
            XCTAssertTrue(refreshedEnvelopes.allSatisfy {
                $0.policyClassification == .archiveOnly
            })
            XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
            try await stack.vault.database.close()
        }
    }

    func testAttachedBrowseKeepsExactSourceResponseDuringVaultSearchReentrancy()
        async throws
    {
        let directory = try makeDirectory(named: "browse-reentrancy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.json")
        let secondURL = directory.appendingPathComponent("second.json")
        try Data(
            #"[{"id":"first","body":"Shared first evidence"}]"#.utf8
        ).write(to: firstURL)
        try Data(
            #"[{"id":"second","body":"Shared second evidence"}]"#.utf8
        ).write(to: secondURL)

        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(store: store, clientID: nil)
        let vault = try VaultController(
            store: store,
            slackController: slack,
            inMemory: true
        )
        let gate = AttachedBrowseSearchGate()
        let controller = AttachedDataSourcesController(
            store: store,
            vaultController: vault,
            fileAuthority: AttachedDataFileAuthority(
                securityScope: .unscopedTesting
            ),
            scopedVaultSearch: { request in
                await gate.pause(request)
                return try await vault.boundedSearchResponse(request)
            }
        )

        let firstPrepared = await controller.preparePreview(at: firstURL)
        XCTAssertTrue(firstPrepared, controller.errorMessage ?? "preview failed")
        let firstImported = await controller.importPendingPreview()
        XCTAssertTrue(firstImported, controller.errorMessage ?? "import failed")
        let secondPrepared = await controller.preparePreview(at: secondURL)
        XCTAssertTrue(secondPrepared, controller.errorMessage ?? "preview failed")
        let secondImported = await controller.importPendingPreview()
        XCTAssertTrue(secondImported, controller.errorMessage ?? "import failed")
        let first = try XCTUnwrap(controller.sources.first {
            $0.originalFilename == "first.json"
        })
        let second = try XCTUnwrap(controller.sources.first {
            $0.originalFilename == "second.json"
        })
        let firstAccountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: first.id
        )
        let secondAccountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: second.id
        )

        let browse = Task { @MainActor in
            await controller.browse(
                sourceIdentifier: first.id,
                query: "Shared"
            )
        }
        let request = await gate.waitUntilPaused()
        XCTAssertEqual(request.accountID, firstAccountID)
        XCTAssertEqual(request.provider, VaultProviderKind.localImport.rawValue)
        XCTAssertEqual(request.limit, 50)
        XCTAssertEqual(request.offset, 0)

        await vault.search(
            text: "Shared",
            provider: VaultProviderKind.localImport.rawValue,
            accountID: secondAccountID
        )
        XCTAssertFalse(vault.searchResults.isEmpty)
        XCTAssertTrue(vault.searchResults.allSatisfy {
            $0.accountID == secondAccountID
        })

        await gate.release()
        await browse.value
        let page = try XCTUnwrap(controller.browserPage)
        XCTAssertEqual(page.sourceIdentifier, first.id)
        XCTAssertFalse(page.results.isEmpty)
        XCTAssertTrue(page.results.allSatisfy {
            $0.accountID == firstAccountID
                && Set(first.importedLocalContainerIdentifiers)
                    .contains($0.containerID)
                && $0.attachedSourceProvenance?.sourceIdentifier == first.id
        })
        XCTAssertTrue(vault.searchResults.allSatisfy {
            $0.accountID == secondAccountID
        })
    }

    func testAttachedBrowseRejectsAtomicReplacementBeforeSourceGenerationAdvances()
        async throws
    {
        let directory = try makeDirectory(named: "browse-generation-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(
            #"[{"id":"first","body":"Atomic replacement evidence"}]"#.utf8
        ).write(to: sourceURL)

        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(store: store, clientID: nil)
        let vault = try VaultController(
            store: store,
            slackController: slack,
            inMemory: true
        )
        let controller = AttachedDataSourcesController(
            store: store,
            vaultController: vault,
            fileAuthority: AttachedDataFileAuthority(
                securityScope: .unscopedTesting
            ),
            scopedVaultSearch: { request in
                let response = try await vault.boundedSearchResponse(request)
                let replaced = response.results.map { result in
                    guard let provenance = result.attachedSourceProvenance
                    else { return result }
                    return Self.searchResult(
                        result,
                        replacingAttachedProvenance: .init(
                            sourceIdentifier: provenance.sourceIdentifier,
                            sourceKind: provenance.sourceKind,
                            sourceEpoch: provenance.sourceEpoch + 1,
                            sourceDigest: String(repeating: "f", count: 64),
                            selectionIdentifier:
                                provenance.selectionIdentifier,
                            selectionSourceIdentifier:
                                provenance.selectionSourceIdentifier,
                            stableRecordIdentifier:
                                provenance.stableRecordIdentifier,
                            recordLocator: provenance.recordLocator,
                            schemaDigest: provenance.schemaDigest,
                            generationIdentifier: "generation-successor",
                            generationReceiptHash:
                                String(repeating: "9", count: 64),
                            pageReceiptHash: provenance.pageReceiptHash,
                            identityStrategy: provenance.identityStrategy,
                            wasTruncated: provenance.wasTruncated
                        )
                    )
                }
                return .init(
                    mode: response.mode,
                    results: replaced,
                    queryTokenCount: response.queryTokenCount,
                    wasTruncated: response.wasTruncated
                )
            }
        )

        let prepared = await controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, controller.errorMessage ?? "preview failed")
        let imported = await controller.importPendingPreview()
        XCTAssertTrue(imported, controller.errorMessage ?? "import failed")
        let source = try XCTUnwrap(controller.sources.first)
        let canonicalGeneration = try XCTUnwrap(
            source.currentGenerationIdentifier
        )
        let canonicalEpoch = source.currentEpoch

        await controller.browse(
            sourceIdentifier: source.id,
            query: "Atomic replacement"
        )

        XCTAssertNil(controller.browserPage)
        XCTAssertEqual(
            controller.errorMessage,
            AttachedDataSourceFailureCode.sourceUnavailable.errorDescription
        )
        let unchanged = try XCTUnwrap(store.attachedDataSource(id: source.id))
        XCTAssertEqual(unchanged.currentGenerationIdentifier, canonicalGeneration)
        XCTAssertEqual(unchanged.currentEpoch, canonicalEpoch)
    }

    func testConsentRevocationPersistsOnlyAfterSemanticPurgePreparation()
        async throws
    {
        let directory = try makeDirectory(named: "consent-purge-ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(
            #"{"items":[{"id":"a","body":"Alpha"}]}"#.utf8
        ).write(to: sourceURL)
        let stack = try makeInMemoryStack()
        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(
            prepared,
            stack.controller.errorMessage ?? "preview failed"
        )
        XCTAssertTrue(stack.controller.setJSONRecordRoot("/items"))
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(
            imported,
            stack.controller.errorMessage ?? "import failed"
        )
        let source = try XCTUnwrap(stack.controller.sources.first)
        let consentEnabled = await stack.controller.setLocalModelConsent(
            sourceIdentifier: source.id,
            enabled: true
        )
        XCTAssertTrue(consentEnabled)

        let probe = AttachedSemanticAuthorityProbe()
        stack.controller.configureSemanticAuthorityChangeHandler {
            probe.transaction(reasonCode: $0)
        }
        let revocation = Task { @MainActor in
            await stack.controller.setLocalModelConsent(
                sourceIdentifier: source.id,
                enabled: false
            )
        }
        for _ in 0..<20 {
            if !probe.reasonCodes.isEmpty { break }
            await Task.yield()
        }

        XCTAssertEqual(probe.reasonCodes, [
            "semantic_index_attached_source_consent_revoked",
        ])
        XCTAssertTrue(try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        ).localModelConsentEnabled)
        XCTAssertTrue(probe.resolutions.isEmpty)

        await probe.releasePreparation(true)
        let revoked = await revocation.value
        XCTAssertTrue(revoked)
        XCTAssertFalse(try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        ).localModelConsentEnabled)
        XCTAssertEqual(probe.resolutions, ["committed"])

        let reenabled = await stack.controller.setLocalModelConsent(
            sourceIdentifier: source.id,
            enabled: true
        )
        XCTAssertTrue(reenabled)
        let unresolvedProbe = AttachedSemanticAuthorityProbe(
            resolutionSucceeds: false
        )
        stack.controller.configureSemanticAuthorityChangeHandler {
            unresolvedProbe.transaction(reasonCode: $0)
        }
        let unresolvedRevocation = Task { @MainActor in
            await stack.controller.setLocalModelConsent(
                sourceIdentifier: source.id,
                enabled: false
            )
        }
        await Task.yield()
        await unresolvedProbe.releasePreparation(true)
        let unresolvedResult = await unresolvedRevocation.value
        XCTAssertFalse(unresolvedResult)
        XCTAssertFalse(try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        ).localModelConsentEnabled)
        XCTAssertEqual(unresolvedProbe.resolutions, ["committed"])
        XCTAssertTrue(
            stack.controller.errorMessage?.contains("remains paused") == true
        )
    }

    func testUnavailableSemanticHandlerDoesNotAdvanceConsentGenerationOrRemoval()
        async throws
    {
        let directory = try makeDirectory(named: "semantic-handler-unavailable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(
            #"{"items":[{"id":"a","body":"Alpha"}]}"#.utf8
        ).write(to: sourceURL)
        let stack = try makeInMemoryStack()
        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared)
        XCTAssertTrue(stack.controller.setJSONRecordRoot("/items"))
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let source = try XCTUnwrap(stack.controller.sources.first)
        let consentEnabled = await stack.controller.setLocalModelConsent(
            sourceIdentifier: source.id,
            enabled: true
        )
        XCTAssertTrue(consentEnabled)
        let generation = try XCTUnwrap(
            stack.controller.sources.first?.currentGenerationIdentifier
        )
        let acceptedSourceDigest = try XCTUnwrap(source.sourceDigest)
        let acceptedShapeDigest = try XCTUnwrap(source.shapeDigest)
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: source.id
        )
        let marker = try await stack.vault.database
            .connectorGenerationMarker(accountID: accountID)

        stack.controller.configureSemanticAuthorityChangeHandler { _ in
            AttachedDataSemanticAuthorityTransaction.denied()
        }
        let consentRevoked = await stack.controller.setLocalModelConsent(
            sourceIdentifier: source.id,
            enabled: false
        )
        XCTAssertFalse(consentRevoked)
        XCTAssertTrue(try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        ).localModelConsentEnabled)

        let refreshed = await stack.controller.refresh(
            sourceIdentifier: source.id
        )
        XCTAssertFalse(refreshed)
        let afterRejectedRefresh = try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        )
        XCTAssertEqual(
            afterRejectedRefresh.currentGenerationIdentifier,
            generation
        )
        XCTAssertEqual(afterRejectedRefresh.sourceDigest, acceptedSourceDigest)
        XCTAssertEqual(afterRejectedRefresh.shapeDigest, acceptedShapeDigest)
        XCTAssertNil(afterRejectedRefresh.pendingGenerationIdentifier)
        let markerAfterRefresh = try await stack.vault.database
            .connectorGenerationMarker(accountID: accountID)
        XCTAssertEqual(markerAfterRefresh, marker)

        let removed = await stack.controller.removeLocalData(
            sourceIdentifier: source.id
        )
        XCTAssertFalse(removed)
        let afterRejectedRemoval = try XCTUnwrap(
            stack.store.attachedDataSource(id: source.id)
        )
        XCTAssertEqual(afterRejectedRemoval.localDataRetentionState, .retained)
        XCTAssertEqual(afterRejectedRemoval.currentGenerationIdentifier, generation)
        let markerAfterRemoval = try await stack.vault.database
            .connectorGenerationMarker(accountID: accountID)
        XCTAssertEqual(markerAfterRemoval, marker)
    }

    func testJSONSnapshotPreviewSelectionAndModeCommitWithoutRetainedBookmark() async throws {
        let directory = try makeDirectory(named: "json-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        let sourceData = Data(
            #"{"items":[{"id":"j1","body":"Alpha"},{"id":"j2","body":"Beta"}],"ignored":[1,2]}"#.utf8
        )
        try sourceData.write(to: sourceURL)
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertEqual(stack.controller.pendingDraft?.mode, .linkedReadOnly)
        XCTAssertTrue(stack.controller.setJSONRecordRoot("/items"))
        let selectionID = try XCTUnwrap(
            stack.controller.pendingDraft?.preview.candidateSelections.first?.id
        )
        stack.controller.setPendingSelection(selectionID, included: false)
        XCTAssertTrue(stack.controller.pendingDraft?.selectedSelections.isEmpty == true)
        stack.controller.setPendingSelection(selectionID, included: true)
        stack.controller.setPendingField(
            selectionIdentifier: selectionID,
            field: "/body",
            included: false
        )
        XCTAssertFalse(
            stack.controller.pendingDraft?.selectedSelections.first?
                .selectedFields.contains("/body") ?? true
        )
        stack.controller.setPendingField(
            selectionIdentifier: selectionID,
            field: "/body",
            included: true
        )
        stack.controller.setPendingMode(.importedSnapshot)
        XCTAssertEqual(stack.controller.pendingDraft?.mode, .importedSnapshot)
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)

        let source = try XCTUnwrap(stack.controller.sources.first)
        XCTAssertEqual(source.kind, .json)
        XCTAssertEqual(source.mode, .importedSnapshot)
        XCTAssertEqual(source.state, .connected)
        XCTAssertEqual(source.access.bookmarkState, .notRetained)
        XCTAssertFalse(source.access.continuingAccessRetained)
        XCTAssertFalse(source.refreshEnabled)
        XCTAssertNil(try stack.store.attachedDataSourceBookmark(id: source.id))
        XCTAssertEqual(source.itemCount, 2)
        let admitted = try await envelopes(in: stack.vault, source: source)
        XCTAssertEqual(admitted.count, 2)
        XCTAssertTrue(admitted.contains { $0.normalizedText.contains("Alpha") })
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testTopLevelJSONObjectUsesDollarRootInProjectedProvenance()
        async throws
    {
        try await assertTopLevelJSONProvenance(
            #"{"id":"object-root","body":"Alpha object evidence"}"#,
            expectedRecordLocator: "$",
            fixtureName: "top-level-object"
        )
    }

    func testTopLevelJSONArrayUsesDollarRootInProjectedProvenance()
        async throws
    {
        try await assertTopLevelJSONProvenance(
            #"[{"id":"array-root","body":"Alpha array evidence"}]"#,
            expectedRecordLocator: "/0",
            fixtureName: "top-level-array"
        )
    }

    func testJSONStableIDFieldRequiresUniqueExplicitSelectionAndPersistsStrategy() async throws {
        let directory = try makeDirectory(named: "json-explicit-stable-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(
            #"{"items":[{"external_key":"one","category":"same","body":"Alpha"},{"external_key":"two","category":"same","body":"Beta"}]}"#.utf8
        ).write(to: sourceURL)
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertTrue(stack.controller.setJSONRecordRoot("/items"))
        XCTAssertEqual(
            stack.controller.pendingDraft?.selectedSelections.first?
                .recordIdentityStrategy,
            .jsonPointerAndDigest
        )
        XCTAssertFalse(stack.controller.setPendingJSONIdentityField("/category"))
        XCTAssertTrue(stack.controller.setPendingJSONIdentityField("/external_key"))
        let selected = try XCTUnwrap(
            stack.controller.pendingDraft?.selectedSelections.first
        )
        XCTAssertEqual(selected.recordIdentityStrategy, .explicitJSONID)
        XCTAssertEqual(selected.identityFields, ["/external_key"])
        XCTAssertTrue(selected.selectedFields.contains("/external_key"))

        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let source = try XCTUnwrap(stack.controller.sources.first)
        XCTAssertEqual(source.selections.first?.recordIdentityStrategy, .explicitJSONID)
        XCTAssertEqual(source.selections.first?.identityFields, ["/external_key"])
        let admitted = try await envelopes(in: stack.vault, source: source)
        XCTAssertEqual(admitted.count, 2)
        XCTAssertEqual(Set(admitted.map(\.provenance.sourceSystem)), ["attached_data"])
    }

    func testSQLiteRiskyObjectsAreOffByDefaultAndTruncateOnlyAfterExplicitSelection() async throws {
        let directory = try makeDirectory(named: "sqlite-risk-selection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("risk.sqlite")
        try createSQLite(
            at: sourceURL,
            sql: """
                CREATE TABLE records(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
                INSERT INTO records VALUES (1, 'safe');
                CREATE TABLE schema_migrations(version TEXT PRIMARY KEY);
                INSERT INTO schema_migrations VALUES ('1');
                CREATE TABLE app_private_metadata(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO app_private_metadata VALUES ('owner', 'private');
                CREATE TABLE oversized(id INTEGER PRIMARY KEY, body TEXT NOT NULL);
                WITH RECURSIVE counter(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM counter WHERE value < 10001
                )
                INSERT INTO oversized SELECT value, 'record-' || value FROM counter;
                ANALYZE;
                """
        )
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        let draft = try XCTUnwrap(stack.controller.pendingDraft)
        let candidates = Dictionary(
            uniqueKeysWithValues: draft.preview.candidateSelections.map {
                ($0.sourceIdentifier, $0)
            }
        )
        let selectedNames = Set(draft.selectedSelections.map(\.sourceIdentifier))
        XCTAssertTrue(selectedNames.contains("records"))
        XCTAssertFalse(selectedNames.contains("schema_migrations"))
        XCTAssertFalse(selectedNames.contains("app_private_metadata"))
        XCTAssertFalse(selectedNames.contains("oversized"))
        XCTAssertNotNil(candidates["schema_migrations"])
        XCTAssertNotNil(candidates["app_private_metadata"])
        XCTAssertEqual(candidates["oversized"]?.allowsRecordTruncation, true)
        XCTAssertTrue(draft.preview.warnings.contains(.budgetExceeded))
        XCTAssertTrue(draft.sqlitePreview?.objects.contains {
            $0.kind == .internalTable && !$0.isSelectable
        } == true)

        for identifier in draft.selectedSelectionIdentifiers {
            stack.controller.setPendingSelection(identifier, included: false)
        }
        let oversized = try XCTUnwrap(candidates["oversized"])
        stack.controller.setPendingSelection(oversized.id, included: true)
        XCTAssertEqual(
            stack.controller.pendingDraft?.selectedSelections.first?
                .allowsRecordTruncation,
            true
        )
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let source = try XCTUnwrap(stack.controller.sources.first)
        XCTAssertEqual(
            source.itemCount,
            AttachedDataSourceBudgets.sqliteStandard.maximumRecords
        )
        XCTAssertGreaterThan(source.truncationCount, 0)
        XCTAssertEqual(source.selections.map(\.sourceIdentifier), ["oversized"])
        XCTAssertTrue(source.selections.allSatisfy(\.allowsRecordTruncation))
    }

    func testJSONLinkedReadOnlyRetainsBookmarkAndRefreshesEditedFileWithoutMutation() async throws {
        let directory = try makeDirectory(named: "json-linked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        let initialData = Data(
            #"[{"id":"j1","body":"Alpha linked"}]"#.utf8
        )
        try initialData.write(to: sourceURL)
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertEqual(stack.controller.pendingDraft?.observation.kind, .json)
        XCTAssertEqual(stack.controller.pendingDraft?.mode, .linkedReadOnly)
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let admitted = try XCTUnwrap(stack.controller.sources.first)
        XCTAssertEqual(admitted.mode, .linkedReadOnly)
        XCTAssertTrue(admitted.access.continuingAccessRetained)
        XCTAssertTrue(admitted.refreshEnabled)
        XCTAssertNotNil(try stack.store.attachedDataSourceBookmark(id: admitted.id))
        XCTAssertEqual(try Data(contentsOf: sourceURL), initialData)

        let editedData = Data(
            #"[{"id":"j1","body":"Beta linked edit"}]"#.utf8
        )
        try overwritePreservingResource(at: sourceURL, with: editedData)
        let bytesBeforeRefresh = try Data(contentsOf: sourceURL)
        let refreshedSuccessfully = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertTrue(refreshedSuccessfully)
        let refreshed = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(refreshed.state, .connected)
        XCTAssertEqual(refreshed.currentEpoch, admitted.currentEpoch + 1)
        let current = try await envelopes(in: stack.vault, source: refreshed)
        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(current[0].normalizedText.contains("Beta linked edit"))
        XCTAssertEqual(current[0].provenance.sourceSystem, "attached_data")
        XCTAssertNil(current[0].provenance.sourceURL)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytesBeforeRefresh)
    }

    func testSQLiteSnapshotDropsBookmarkRejectsRefreshAndPreservesVaultProvenance() async throws {
        let directory = try makeDirectory(named: "sqlite-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertEqual(stack.controller.pendingDraft?.observation.kind, .sqlite)
        stack.controller.setPendingMode(.importedSnapshot)
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let admitted = try XCTUnwrap(stack.controller.sources.first)
        let generation = try XCTUnwrap(admitted.currentGenerationIdentifier)
        XCTAssertEqual(admitted.mode, .importedSnapshot)
        XCTAssertEqual(admitted.access.bookmarkState, .notRetained)
        XCTAssertFalse(admitted.access.continuingAccessRetained)
        XCTAssertFalse(admitted.refreshEnabled)
        XCTAssertNil(try stack.store.attachedDataSourceBookmark(id: admitted.id))

        let storedEnvelopes = try await envelopes(in: stack.vault, source: admitted)
        XCTAssertEqual(storedEnvelopes.count, 2)
        XCTAssertTrue(storedEnvelopes.allSatisfy {
            $0.provenance.sourceSystem == "attached_data"
                && $0.provenance.sourceURL == nil
                && $0.policyClassification == .archiveOnly
        })
        let refreshWithoutAuthority = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertFalse(refreshWithoutAuthority)
        let retained = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(retained.currentGenerationIdentifier, generation)
        XCTAssertEqual(retained.localDataRetentionState, .retained)
        let envelopesAfterRejectedRefresh = try await envelopes(
            in: stack.vault,
            source: retained
        )
        XCTAssertEqual(envelopesAfterRejectedRefresh, storedEnvelopes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testDuplicateRefreshIsIdempotentThenEditAndDeleteReconcileRevisionAndTombstone() async throws {
        let directory = try makeDirectory(named: "refresh-reconciliation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let stack = try makeInMemoryStack()
        let admitted = try await admitLinkedSQLite(stack, at: sourceURL)
        let initialEnvelopes = try await envelopes(in: stack.vault, source: admitted)
        let alpha = try XCTUnwrap(initialEnvelopes.first {
            $0.normalizedText.contains("Alpha")
        })
        let beta = try XCTUnwrap(initialEnvelopes.first {
            $0.normalizedText.contains("Beta")
        })
        let alphaRecordID = "connector:\(alpha.deduplicationKey)"
        let betaRecordID = "connector:\(beta.deduplicationKey)"

        let duplicateRefresh = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertTrue(duplicateRefresh)
        let duplicateReceipt = try XCTUnwrap(
            try stack.store.attachedDataSourceReceipts(sourceIdentifier: admitted.id)
                .first
        )
        XCTAssertEqual(duplicateReceipt.operation, .refresh)
        XCTAssertEqual(duplicateReceipt.outcome, .succeeded)
        XCTAssertEqual(duplicateReceipt.importedItemCount, 0)
        XCTAssertEqual(duplicateReceipt.updatedItemCount, 0)
        XCTAssertEqual(duplicateReceipt.tombstonedItemCount, 0)
        let duplicateRevisions = try await stack.vault.database.revisions(
            recordID: alphaRecordID
        )
        XCTAssertEqual(duplicateRevisions, [])
        let duplicateSource = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        let loadedDuplicateRecord = try await stack.vault.database.record(
            id: alphaRecordID
        )
        let duplicateRecord = try XCTUnwrap(loadedDuplicateRecord)
        let duplicateProvenance = try XCTUnwrap(
            VaultAttachedSourceProvenance.project(from: duplicateRecord)
        )
        XCTAssertEqual(
            duplicateProvenance.generationIdentifier,
            duplicateSource.currentGenerationIdentifier
        )
        XCTAssertEqual(
            duplicateProvenance.sourceEpoch,
            Int64(duplicateSource.currentEpoch)
        )

        try executeSQL(at: sourceURL, sql: """
            UPDATE records SET body = 'Alpha edited' WHERE id = 'a';
            DELETE FROM records WHERE id = 'b';
            """)
        let reconciled = await stack.controller.refresh(sourceIdentifier: admitted.id)
        XCTAssertTrue(reconciled)

        let refreshed = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(refreshed.itemCount, 1)
        let current = try await envelopes(in: stack.vault, source: refreshed)
        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(current[0].normalizedText.contains("Alpha edited"))
        XCTAssertEqual(current[0].remoteRecordIdentifier, alpha.remoteRecordIdentifier)
        let revisions = try await stack.vault.database.revisions(
            recordID: alphaRecordID
        )
        XCTAssertEqual(revisions.count, 1)
        XCTAssertTrue(revisions[0].body.contains("Alpha"))
        let deletedRecord = try await stack.vault.database.record(id: betaRecordID)
        XCTAssertNil(deletedRecord)
        let tombstones = try await stack.vault.database.tombstones()
        XCTAssertTrue(tombstones.contains {
            $0.recordID == betaRecordID && $0.reason == .sourceDeleted
        })
        let receipt = try XCTUnwrap(
            try stack.store.attachedDataSourceReceipts(sourceIdentifier: admitted.id)
                .first
        )
        XCTAssertEqual(receipt.updatedItemCount, 1)
        XCTAssertEqual(receipt.tombstonedItemCount, 1)
    }

    func testReplacementFailureRetainsGenerationUntilExplicitReauthorization() async throws {
        let directory = try makeDirectory(named: "replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let stack = try makeInMemoryStack()
        let admitted = try await admitLinkedSQLite(stack, at: sourceURL)
        let priorGeneration = try XCTUnwrap(admitted.currentGenerationIdentifier)
        let priorIdentity = try XCTUnwrap(admitted.fileIdentity)
        let priorEnvelopes = try await envelopes(in: stack.vault, source: admitted)

        let replacement = directory.appendingPathComponent("replacement.sqlite")
        try createSQLite(
            at: replacement,
            sql: """
                CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL);
                INSERT INTO records VALUES ('c', 'Replacement Gamma');
                """
        )
        let displaced = directory.appendingPathComponent("displaced.sqlite")
        try FileManager.default.moveItem(at: sourceURL, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: sourceURL)

        let refreshAfterReplacement = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertFalse(refreshAfterReplacement)
        let degraded = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(degraded.state, .degraded)
        XCTAssertEqual(degraded.currentGenerationIdentifier, priorGeneration)
        XCTAssertEqual(degraded.fileIdentity, priorIdentity)
        XCTAssertEqual(
            degraded.access.bookmarkState,
            .reauthorizationRequired
        )
        XCTAssertTrue(degraded.access.continuingAccessRetained)
        let retainedAfterFailure = try await envelopes(
            in: stack.vault,
            source: degraded
        )
        XCTAssertEqual(retainedAfterFailure, priorEnvelopes)
        let failureReceipt = try XCTUnwrap(
            try stack.store.attachedDataSourceReceipts(sourceIdentifier: admitted.id)
                .first
        )
        XCTAssertEqual(failureReceipt.operation, .refresh)
        XCTAssertEqual(failureReceipt.outcome, .failed)
        XCTAssertTrue(failureReceipt.priorGenerationRetained)
        XCTAssertFalse(failureReceipt.atomicPublicationCommitted)

        let reauthorized = await stack.controller.reauthorize(
            sourceIdentifier: admitted.id,
            with: sourceURL
        )
        XCTAssertTrue(reauthorized)
        let recovered = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(recovered.state, .connected)
        XCTAssertNotEqual(recovered.currentGenerationIdentifier, priorGeneration)
        XCTAssertNotEqual(recovered.fileIdentity?.inode, priorIdentity.inode)
        XCTAssertEqual(recovered.access.bookmarkState, .retained)
        XCTAssertTrue(recovered.access.continuingAccessRetained)
        XCTAssertNotNil(try stack.store.attachedDataSourceBookmark(id: admitted.id))
        let replacementEnvelopes = try await envelopes(
            in: stack.vault,
            source: recovered
        )
        XCTAssertEqual(replacementEnvelopes.count, 1)
        XCTAssertTrue(replacementEnvelopes[0].normalizedText.contains(
            "Replacement Gamma"
        ))
        let receipt = try XCTUnwrap(
            try stack.store.attachedDataSourceReceipts(sourceIdentifier: admitted.id)
                .first
        )
        XCTAssertEqual(receipt.operation, .reauthorize)
        XCTAssertEqual(receipt.outcome, .succeeded)
    }

    func testBookmarkFailureAndStaleResolutionRequireExplicitReauthorization() async throws {
        let directory = try makeDirectory(named: "bookmark-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(
            #"{"items":[{"id":"one","body":"Alpha"}]}"#.utf8
        ).write(to: sourceURL)
        let scope = ControllableSecurityScopeProbe()
        let stack = try makeInMemoryStack(securityScope: scope.access)

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertTrue(stack.controller.setJSONRecordRoot("/items"))
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        let admitted = try XCTUnwrap(stack.controller.sources.first)
        let firstGeneration = try XCTUnwrap(
            admitted.currentGenerationIdentifier
        )
        XCTAssertEqual(admitted.access.bookmarkState, .retained)

        scope.setResolutionFailure(true)
        let refreshWithoutBookmark = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertFalse(refreshWithoutBookmark)
        let unavailable = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(unavailable.state, .degraded)
        XCTAssertEqual(unavailable.currentGenerationIdentifier, firstGeneration)
        XCTAssertEqual(
            unavailable.access.bookmarkState,
            .reauthorizationRequired
        )
        XCTAssertTrue(unavailable.access.continuingAccessRetained)
        XCTAssertNotNil(try stack.store.attachedDataSourceBookmark(id: admitted.id))

        scope.setResolutionFailure(false)
        let restoredAuthority = await stack.controller.reauthorize(
            sourceIdentifier: admitted.id,
            with: sourceURL
        )
        XCTAssertTrue(restoredAuthority)
        let reauthorized = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(reauthorized.state, .connected)
        XCTAssertEqual(reauthorized.access.bookmarkState, .retained)

        scope.setResolvedBookmarksStale(true)
        let refreshFromStaleBookmark = await stack.controller.refresh(
            sourceIdentifier: admitted.id
        )
        XCTAssertTrue(refreshFromStaleBookmark)
        let stale = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(stale.state, .connected)
        XCTAssertEqual(stale.access.bookmarkState, .stale)
        XCTAssertNotNil(stale.currentGenerationIdentifier)

        scope.setResolvedBookmarksStale(false)
        let replacedStaleAuthority = await stack.controller.reauthorize(
            sourceIdentifier: admitted.id,
            with: sourceURL
        )
        XCTAssertTrue(replacedStaleAuthority)
        let current = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(current.state, .connected)
        XCTAssertEqual(current.access.bookmarkState, .retained)
    }

    func testCancellationDuringRefreshRetainsGenerationAndBalancesFileAuthority() async throws {
        let directory = try makeDirectory(named: "cancellation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let scope = BlockingSecurityScopeProbe()
        let stack = try makeInMemoryStack(securityScope: scope.access)
        let admitted = try await admitLinkedSQLite(stack, at: sourceURL)
        let priorGeneration = try XCTUnwrap(admitted.currentGenerationIdentifier)
        let priorSourceDigest = try XCTUnwrap(admitted.sourceDigest)
        let priorShapeDigest = try XCTUnwrap(admitted.shapeDigest)
        let priorEnvelopes = try await envelopes(in: stack.vault, source: admitted)

        try executeSQL(at: sourceURL, sql: """
            ALTER TABLE records ADD COLUMN category TEXT NOT NULL DEFAULT 'general';
            UPDATE records SET body = 'Alpha pending refresh' WHERE id = 'a';
            """)
        let attemptedBytes = try Data(contentsOf: sourceURL)
        XCTAssertNotEqual(attemptedBytes, originalBytes)

        scope.armAfterAllowedStarts(1)
        let refresh = Task {
            await stack.controller.refresh(sourceIdentifier: admitted.id)
        }
        let arrived = await waitForBlockedScope(scope)
        if !arrived {
            scope.release()
            refresh.cancel()
            _ = await refresh.value
            return XCTFail("Refresh did not reach the cancellable publication boundary")
        }
        let attempted = try XCTUnwrap(
            try stack.store.attachedDataSource(id: admitted.id)
        )
        let attemptedPlan = try XCTUnwrap(attempted.frozenImportPlan)
        XCTAssertNotEqual(attemptedPlan.sourceDigest, priorSourceDigest)
        XCTAssertNotEqual(attemptedPlan.shapeDigest, priorShapeDigest)
        stack.controller.cancel(sourceIdentifier: admitted.id)
        scope.release()
        let refreshResult = await refresh.value
        XCTAssertFalse(refreshResult)

        let cancelled = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(cancelled.state, .degraded)
        XCTAssertEqual(cancelled.cancellationState, .completed)
        XCTAssertEqual(cancelled.currentGenerationIdentifier, priorGeneration)
        XCTAssertEqual(cancelled.sourceDigest, priorSourceDigest)
        XCTAssertEqual(cancelled.shapeDigest, priorShapeDigest)
        let retainedAfterCancellation = try await envelopes(
            in: stack.vault,
            source: cancelled
        )
        XCTAssertEqual(retainedAfterCancellation, priorEnvelopes)
        await stack.controller.browse(
            sourceIdentifier: admitted.id,
            query: "Alpha"
        )
        let retainedPage = try XCTUnwrap(stack.controller.browserPage)
        XCTAssertEqual(retainedPage.results.count, 1)
        XCTAssertTrue(retainedPage.results[0].snippet.contains("Alpha"))
        XCTAssertFalse(retainedPage.results[0].snippet.contains("pending"))
        let receipt = try XCTUnwrap(
            try stack.store.attachedDataSourceReceipts(sourceIdentifier: admitted.id)
                .first
        )
        XCTAssertEqual(receipt.operation, .refresh)
        XCTAssertEqual(receipt.outcome, .cancelled)
        XCTAssertTrue(receipt.priorGenerationRetained)
        XCTAssertFalse(receipt.atomicPublicationCommitted)
        XCTAssertEqual(receipt.sourceDigest, attemptedPlan.sourceDigest)
        XCTAssertEqual(receipt.shapeDigest, attemptedPlan.shapeDigest)
        XCTAssertEqual(try Data(contentsOf: sourceURL), attemptedBytes)
        let balance = scope.balance
        XCTAssertGreaterThan(balance.starts, 0)
        XCTAssertEqual(balance.starts, balance.stops)
    }

    func testCancelledFirstImportCanRetryWithoutPriorGenerationAuthority()
        async throws
    {
        let directory = try makeDirectory(named: "cancelled-first-import-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let scope = BlockingSecurityScopeProbe()
        let stack = try makeInMemoryStack(securityScope: scope.access)
        let previewPrepared = await stack.controller.preparePreview(
            at: sourceURL
        )
        XCTAssertTrue(previewPrepared)
        let sourceIdentifier = try XCTUnwrap(stack.controller.pendingDraft?.id)

        scope.armAfterAllowedStarts(0)
        let firstImport = Task {
            await stack.controller.importPendingPreview()
        }
        let arrived = await waitForBlockedScope(scope)
        if !arrived {
            scope.release()
            firstImport.cancel()
            _ = await firstImport.value
            return XCTFail("First import did not reach cancellation boundary")
        }
        stack.controller.cancel(sourceIdentifier: sourceIdentifier)
        scope.release()
        let firstImportResult = await firstImport.value
        XCTAssertFalse(firstImportResult)

        let cancelled = try XCTUnwrap(
            stack.controller.sources.first { $0.id == sourceIdentifier }
        )
        XCTAssertEqual(cancelled.state, .failed)
        XCTAssertNil(cancelled.currentGenerationIdentifier)
        XCTAssertNotNil(cancelled.sourceDigest)
        XCTAssertNotNil(cancelled.shapeDigest)

        let retried = await stack.controller.refresh(
            sourceIdentifier: sourceIdentifier
        )
        XCTAssertTrue(retried, stack.controller.errorMessage ?? "retry failed")
        let admitted = try XCTUnwrap(
            stack.controller.sources.first { $0.id == sourceIdentifier }
        )
        XCTAssertEqual(admitted.state, .connected)
        XCTAssertNotNil(admitted.currentGenerationIdentifier)
        await stack.controller.browse(
            sourceIdentifier: sourceIdentifier,
            query: "Alpha"
        )
        XCTAssertEqual(stack.controller.browserPage?.results.count, 1)
    }

    func testRestartFinalizesMatchingCommittedFrozenPlanWithoutRepublishing() async throws {
        let directory = try makeDirectory(named: "restart-committed-plan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        let vaultURL = directory.appendingPathComponent("Vault.sqlite3")
        var sourceIdentifier = ""
        var generationIdentifier = ""
        var markerBeforeRestart: VaultConnectorGenerationMarker?

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            let startedAt = Date()
            let fixture = try interruptedPublicationFixture(
                sourceIdentifier: "attached:restart-committed",
                startedAt: startedAt
            )
            sourceIdentifier = fixture.source.id
            generationIdentifier = fixture.plan.generationIdentifier
            try stack.store.saveAttachedDataSource(
                fixture.source,
                securityScopedBookmark: Data(
                    "synthetic-recovery-bookmark".utf8
                )
            )
            markerBeforeRestart = try await commitSyntheticGeneration(
                in: stack.vault,
                source: fixture.source,
                receiptHash: fixture.plan.planDigest,
                at: startedAt
            )
            XCTAssertEqual(
                markerBeforeRestart?.generationReceiptHash,
                fixture.plan.planDigest
            )
            XCTAssertTrue(
                try stack.store.attachedDataSourceReceipts(
                    sourceIdentifier: sourceIdentifier
                ).isEmpty
            )
            try await stack.vault.database.close()
        }

        let recoveredStack = try makeFileBackedStack(
            storeURL: storeURL,
            vaultURL: vaultURL
        )
        let semanticProbe = AttachedSemanticAuthorityProbe()
        recoveredStack.controller.configureSemanticAuthorityChangeHandler {
            semanticProbe.transaction(reasonCode: $0)
        }
        XCTAssertEqual(semanticProbe.reasonCodes, [
            "semantic_index_attached_source_restart_reconciliation",
        ])
        await Task.yield()
        let stillInterrupted = try XCTUnwrap(
            recoveredStack.store.attachedDataSource(id: sourceIdentifier)
        )
        XCTAssertEqual(stillInterrupted.state, .importing)
        XCTAssertEqual(
            stillInterrupted.pendingGenerationIdentifier,
            generationIdentifier
        )
        XCTAssertTrue(
            try recoveredStack.store.attachedDataSourceReceipts(
                sourceIdentifier: sourceIdentifier
            ).isEmpty
        )

        await semanticProbe.releasePreparation(true)
        let reconciled = await waitForRestartReconciliation(
            recoveredStack.controller
        )
        XCTAssertTrue(reconciled)
        XCTAssertEqual(semanticProbe.resolutions, ["committed"])
        let recovered = try XCTUnwrap(
            recoveredStack.controller.sources.first { $0.id == sourceIdentifier }
        )
        XCTAssertEqual(recovered.state, .connected)
        XCTAssertEqual(recovered.currentGenerationIdentifier, generationIdentifier)
        XCTAssertNil(recovered.pendingGenerationIdentifier)
        XCTAssertNil(recovered.frozenImportPlan)
        XCTAssertEqual(recovered.itemCount, 1)
        XCTAssertEqual(recovered.localDataRetentionState, .retained)
        let receipts = try recoveredStack.store.attachedDataSourceReceipts(
            sourceIdentifier: sourceIdentifier
        )
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.outcome, .succeeded)
        XCTAssertEqual(receipts.first?.generationIdentifier, generationIdentifier)
        XCTAssertEqual(receipts.first?.atomicPublicationCommitted, true)
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: sourceIdentifier
        )
        let markerAfterRestart = try await recoveredStack.vault.database
            .connectorGenerationMarker(accountID: accountID)
        XCTAssertEqual(markerAfterRestart, markerBeforeRestart)
        try await recoveredStack.vault.database.close()
    }

    func testRestartRestoresRetainedGenerationAuthorityWithoutSuccessReceipt()
        async throws
    {
        let directory = try makeDirectory(named: "restart-retained-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        let vaultURL = directory.appendingPathComponent("Vault.sqlite3")
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        var sourceIdentifier = ""
        var priorGeneration = ""
        var priorSourceDigest = ""
        var priorShapeDigest = ""

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            let admitted = try await admitLinkedSQLite(stack, at: sourceURL)
            sourceIdentifier = admitted.id
            priorGeneration = try XCTUnwrap(
                admitted.currentGenerationIdentifier
            )
            priorSourceDigest = try XCTUnwrap(admitted.sourceDigest)
            priorShapeDigest = try XCTUnwrap(admitted.shapeDigest)
            let attemptedSourceDigest = fixtureDigest("restart-attempted-source")
            let attemptedShapeDigest = fixtureDigest("restart-attempted-shape")
            let pendingGeneration = "generation:2:\(attemptedSourceDigest.prefix(32))"
            let selectionDigest = AttachedDataImportPlan.frozenSelectionDigest(
                for: admitted.selections
            )
            let plan = try AttachedDataImportPlan(
                id: "plan:2:\(selectionDigest.prefix(32))",
                sourceIdentifier: admitted.id,
                sourceKind: admitted.kind,
                mode: admitted.mode,
                fileIdentity: try XCTUnwrap(admitted.fileIdentity),
                sourceDigest: attemptedSourceDigest,
                shapeDigest: attemptedShapeDigest,
                selections: admitted.selections,
                normalizationVersion: admitted.normalizationVersion,
                provenanceVersion: admitted.provenanceVersion,
                generationIdentifier: pendingGeneration,
                priorGenerationIdentifier: priorGeneration,
                priorSourceDigest: priorSourceDigest,
                priorShapeDigest: priorShapeDigest,
                createdAt: Date()
            )
            var interrupted = admitted
            interrupted.sourceDigest = attemptedSourceDigest
            interrupted.shapeDigest = attemptedShapeDigest
            interrupted.state = .refreshing
            interrupted.lastAttemptedRefreshAt = plan.createdAt
            interrupted.pendingGenerationIdentifier = pendingGeneration
            interrupted.frozenImportPlan = plan
            interrupted.cancellationState = .none
            interrupted.lastErrorReasonCode = nil
            interrupted.updatedAt = plan.createdAt
            try interrupted.validate()
            try stack.store.saveAttachedDataSource(interrupted)
            try stack.store.removeAttachedDataSourceReceipts(
                sourceIdentifier: admitted.id
            )
            XCTAssertTrue(
                try stack.store.attachedDataSourceReceipts(
                    sourceIdentifier: admitted.id
                ).isEmpty
            )
            try await stack.vault.database.close()
        }

        let recoveredStack = try makeFileBackedStack(
            storeURL: storeURL,
            vaultURL: vaultURL
        )
        let semanticProbe = AttachedSemanticAuthorityProbe()
        recoveredStack.controller.configureSemanticAuthorityChangeHandler {
            semanticProbe.transaction(reasonCode: $0)
        }
        await semanticProbe.releasePreparation(true)
        let reconciliationCompleted = await waitForRestartReconciliation(
            recoveredStack.controller
        )
        XCTAssertTrue(reconciliationCompleted)
        let recovered = try XCTUnwrap(
            recoveredStack.controller.sources.first {
                $0.id == sourceIdentifier
            }
        )
        XCTAssertEqual(recovered.state, .degraded)
        XCTAssertEqual(recovered.currentGenerationIdentifier, priorGeneration)
        XCTAssertEqual(recovered.sourceDigest, priorSourceDigest)
        XCTAssertEqual(recovered.shapeDigest, priorShapeDigest)
        XCTAssertNil(recovered.pendingGenerationIdentifier)
        XCTAssertNil(recovered.frozenImportPlan)
        await recoveredStack.controller.browse(
            sourceIdentifier: sourceIdentifier,
            query: "Alpha"
        )
        let page = try XCTUnwrap(recoveredStack.controller.browserPage)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertTrue(page.results[0].snippet.contains("Alpha"))
        try await recoveredStack.vault.database.close()
    }

    func testRestartDoesNotAdvanceWithoutAUsableSemanticAuthorityHandler()
        async throws
    {
        let directory = try makeDirectory(named: "restart-handler-unavailable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        let vaultURL = directory.appendingPathComponent("Vault.sqlite3")
        let sourceID = "attached:restart-handler-unavailable"
        let fixture = try interruptedPublicationFixture(
            sourceIdentifier: sourceID,
            startedAt: Date()
        )

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            try stack.store.saveAttachedDataSource(
                fixture.source,
                securityScopedBookmark: Data(
                    "synthetic-recovery-bookmark".utf8
                )
            )
            _ = try await commitSyntheticGeneration(
                in: stack.vault,
                source: fixture.source,
                receiptHash: fixture.plan.planDigest,
                at: fixture.source.updatedAt
            )
            try await stack.vault.database.close()
        }

        let recovered = try makeFileBackedStack(
            storeURL: storeURL,
            vaultURL: vaultURL
        )
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(recovered.controller.hasUpdateBlockingWork)
        var persisted = try XCTUnwrap(
            recovered.store.attachedDataSource(id: sourceID)
        )
        XCTAssertEqual(persisted.state, .importing)
        XCTAssertEqual(
            persisted.pendingGenerationIdentifier,
            fixture.plan.generationIdentifier
        )
        XCTAssertTrue(
            try recovered.store.attachedDataSourceReceipts(
                sourceIdentifier: sourceID
            ).isEmpty
        )

        recovered.controller.configureSemanticAuthorityChangeHandler { _ in
            AttachedDataSemanticAuthorityTransaction.denied()
        }
        for _ in 0..<100 {
            if !recovered.controller.hasUpdateBlockingWork { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(recovered.controller.hasUpdateBlockingWork)
        persisted = try XCTUnwrap(
            recovered.store.attachedDataSource(id: sourceID)
        )
        XCTAssertEqual(persisted.state, .importing)
        XCTAssertEqual(
            persisted.pendingGenerationIdentifier,
            fixture.plan.generationIdentifier
        )
        XCTAssertNil(persisted.currentGenerationIdentifier)
        XCTAssertTrue(
            try recovered.store.attachedDataSourceReceipts(
                sourceIdentifier: sourceID
            ).isEmpty
        )
        try await recovered.vault.database.close()
    }

    func testRestartReconcilesRemovalPendingFromActualVaultAccountPresence() async throws {
        let directory = try makeDirectory(named: "restart-removal-pending")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        let vaultURL = directory.appendingPathComponent("Vault.sqlite3")
        let absentID = "attached:removal-absent"
        let presentID = "attached:removal-present"

        do {
            let stack = try makeFileBackedStack(
                storeURL: storeURL,
                vaultURL: vaultURL
            )
            let absent = try removalPendingSource(id: absentID)
            let present = try removalPendingSource(id: presentID)
            try stack.store.saveAttachedDataSource(absent)
            try stack.store.saveAttachedDataSource(present)
            _ = try await commitSyntheticGeneration(
                in: stack.vault,
                source: present,
                receiptHash: fixtureDigest("removal-present-generation"),
                at: present.updatedAt
            )
            try await stack.vault.database.close()
        }

        let recoveredStack = try makeFileBackedStack(
            storeURL: storeURL,
            vaultURL: vaultURL
        )
        recoveredStack.controller.configureSemanticAuthorityChangeHandler { _ in
            self.allowingSemanticAuthorityTransaction()
        }
        let reconciled = await waitForRestartReconciliation(
            recoveredStack.controller
        )
        XCTAssertTrue(reconciled)
        let absent = try XCTUnwrap(
            recoveredStack.controller.sources.first { $0.id == absentID }
        )
        XCTAssertEqual(absent.localDataRetentionState, .removed)
        XCTAssertEqual(absent.state, .disabled)
        XCTAssertEqual(absent.itemCount, 0)
        XCTAssertNil(absent.currentGenerationIdentifier)
        let absentReceipts = try recoveredStack.store.attachedDataSourceReceipts(
            sourceIdentifier: absentID
        )
        XCTAssertEqual(absentReceipts.count, 1)
        XCTAssertEqual(absentReceipts.first?.operation, .removeLocalData)
        XCTAssertEqual(absentReceipts.first?.outcome, .succeeded)
        XCTAssertEqual(
            absentReceipts.first?.reasonCode,
            "attached_data_local_data_removal_reconciled"
        )

        let present = try XCTUnwrap(
            recoveredStack.controller.sources.first { $0.id == presentID }
        )
        XCTAssertEqual(present.localDataRetentionState, .retained)
        XCTAssertEqual(present.state, .degraded)
        XCTAssertEqual(present.itemCount, 1)
        XCTAssertEqual(present.currentGenerationIdentifier, "generation-current")
        XCTAssertEqual(
            present.lastErrorReasonCode,
            "attached_data_local_data_removal_interrupted"
        )
        XCTAssertTrue(
            try recoveredStack.store.attachedDataSourceReceipts(
                sourceIdentifier: presentID
            ).isEmpty
        )
        let presentAccountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: presentID
        )
        let presentAccountExists = try await recoveredStack.vault.database
            .accountExists(id: presentAccountID)
        XCTAssertTrue(presentAccountExists)
        try await recoveredStack.vault.database.close()
    }

    func testDetachPreservesLocalDataUntilSeparateRemoval() async throws {
        let directory = try makeDirectory(named: "detach-remove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.sqlite")
        try createSQLite(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let stack = try makeInMemoryStack()
        let admitted = try await admitLinkedSQLite(stack, at: sourceURL)
        let generation = try XCTUnwrap(admitted.currentGenerationIdentifier)
        let retainedEnvelopes = try await envelopes(in: stack.vault, source: admitted)

        XCTAssertTrue(stack.controller.detach(sourceIdentifier: admitted.id))
        let detached = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(detached.state, .disconnected)
        XCTAssertEqual(detached.access.bookmarkState, .detached)
        XCTAssertFalse(detached.access.continuingAccessRetained)
        XCTAssertEqual(detached.currentGenerationIdentifier, generation)
        XCTAssertEqual(detached.localDataRetentionState, .retained)
        XCTAssertNil(try stack.store.attachedDataSourceBookmark(id: admitted.id))
        let envelopesAfterDetach = try await envelopes(
            in: stack.vault,
            source: detached
        )
        XCTAssertEqual(envelopesAfterDetach, retainedEnvelopes)

        stack.controller.configureSemanticAuthorityChangeHandler { _ in
            self.allowingSemanticAuthorityTransaction()
        }
        let removedSuccessfully = await stack.controller.removeLocalData(
            sourceIdentifier: admitted.id
        )
        XCTAssertTrue(removedSuccessfully)
        let removed = try XCTUnwrap(
            stack.controller.sources.first { $0.id == admitted.id }
        )
        XCTAssertEqual(removed.state, .disabled)
        XCTAssertEqual(removed.localDataRetentionState, .removed)
        XCTAssertNil(removed.currentGenerationIdentifier)
        XCTAssertEqual(removed.itemCount, 0)
        XCTAssertTrue(removed.importedLocalContainerIdentifiers.isEmpty)
        let remainingAccounts = try await stack.vault.database.accounts()
        let remainingContainers = try await stack.vault.database.containers()
        XCTAssertTrue(remainingAccounts.isEmpty)
        XCTAssertTrue(remainingContainers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        let receipts = try stack.store.attachedDataSourceReceipts(
            sourceIdentifier: admitted.id
        )
        XCTAssertTrue(receipts.contains {
            $0.operation == .detach && $0.outcome == .succeeded
        })
        XCTAssertTrue(receipts.contains {
            $0.operation == .removeLocalData && $0.outcome == .succeeded
        })
    }
}

private extension AttachedDataSourcesControllerTests {
    struct Stack {
        let store: LocalStore
        let vault: VaultController
        let controller: AttachedDataSourcesController
    }

    func allowingSemanticAuthorityTransaction()
        -> AttachedDataSemanticAuthorityTransaction
    {
        AttachedDataSemanticAuthorityTransaction(
            preparation: Task { true },
            finisher: { resolution in
                switch resolution {
                case .committed, .unchanged: true
                case .unresolved: false
                }
            }
        )
    }

    func makeInMemoryStack(
        securityScope: AttachedSecurityScopedResourceAccess = .unscopedTesting
    ) throws -> Stack {
        let store = try LocalStore(inMemory: true)
        let slack = SlackAppController(store: store, clientID: nil)
        let vault = try VaultController(
            store: store,
            slackController: slack,
            inMemory: true
        )
        return Stack(
            store: store,
            vault: vault,
            controller: AttachedDataSourcesController(
                store: store,
                vaultController: vault,
                fileAuthority: AttachedDataFileAuthority(
                    securityScope: securityScope
                )
            )
        )
    }

    func makeFileBackedStack(
        storeURL: URL,
        vaultURL: URL
    ) throws -> Stack {
        let store = try LocalStore(url: storeURL)
        let slack = SlackAppController(store: store, clientID: nil)
        let vault = try VaultController(
            store: store,
            slackController: slack,
            databaseURL: vaultURL
        )
        return Stack(
            store: store,
            vault: vault,
            controller: AttachedDataSourcesController(
                store: store,
                vaultController: vault,
                fileAuthority: AttachedDataFileAuthority(
                    securityScope: .unscopedTesting
                )
            )
        )
    }

    func admitLinkedSQLite(
        _ stack: Stack,
        at sourceURL: URL
    ) async throws -> AttachedDataSourceRecord {
        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(prepared, stack.controller.errorMessage ?? "preview failed")
        XCTAssertEqual(stack.controller.pendingDraft?.mode, .linkedReadOnly)
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(imported)
        return try XCTUnwrap(stack.controller.sources.first)
    }

    func envelopes(
        in vault: VaultController,
        source: AttachedDataSourceRecord
    ) async throws -> [ConnectorRecordEnvelope] {
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: source.id
        )
        return try await vault.database.connectorEnvelopes(
            accountID: accountID,
            containerIDs: Set(source.importedLocalContainerIdentifiers)
        )
    }

    func assertTopLevelJSONProvenance(
        _ json: String,
        expectedRecordLocator: String,
        fixtureName: String
    ) async throws {
        let directory = try makeDirectory(named: fixtureName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("records.json")
        try Data(json.utf8).write(to: sourceURL)
        let stack = try makeInMemoryStack()

        let prepared = await stack.controller.preparePreview(at: sourceURL)
        XCTAssertTrue(
            prepared,
            stack.controller.errorMessage ?? "preview failed"
        )
        XCTAssertEqual(
            stack.controller.pendingDraft?.selectedSelections.first?
                .sourceIdentifier,
            ""
        )
        let imported = await stack.controller.importPendingPreview()
        XCTAssertTrue(
            imported,
            stack.controller.errorMessage ?? "import failed"
        )
        let source = try XCTUnwrap(stack.controller.sources.first)
        XCTAssertEqual(source.selections.first?.sourceIdentifier, "")

        await stack.controller.browse(
            sourceIdentifier: source.id,
            query: "Alpha"
        )
        let page = try XCTUnwrap(stack.controller.browserPage)
        let result = try XCTUnwrap(page.results.first)
        let provenance = try XCTUnwrap(result.attachedSourceProvenance)
        XCTAssertEqual(provenance.sourceIdentifier, source.id)
        XCTAssertEqual(provenance.sourceKind, AttachedDataSourceKind.json.rawValue)
        XCTAssertEqual(provenance.selectionSourceIdentifier, "$")
        XCTAssertEqual(provenance.recordLocator, expectedRecordLocator)

        let loadedRecord = try await stack.vault.database.record(id: result.id)
        let storedRecord = try XCTUnwrap(loadedRecord)
        XCTAssertEqual(
            storedRecord.metadata["attached_selection_source"],
            "$"
        )
        XCTAssertEqual(
            storedRecord.metadata["attached_record_locator"],
            expectedRecordLocator
        )
    }

    static func searchResult(
        _ result: VaultSearchResult,
        replacingAttachedProvenance provenance:
            VaultAttachedSourceProvenance?
    ) -> VaultSearchResult {
        .init(
            id: result.id,
            accountID: result.accountID,
            containerID: result.containerID,
            kind: result.kind,
            title: result.title,
            snippet: result.snippet,
            occurredAt: result.occurredAt,
            revision: result.revision,
            contentChecksum: result.contentChecksum,
            provider: result.provider,
            author: result.author,
            sourceURL: result.sourceURL,
            directlyMentionsUser: result.directlyMentionsUser,
            isRead: result.isRead,
            isDeleted: result.isDeleted,
            contentOrigin: result.contentOrigin,
            attachedSourceProvenance: provenance
        )
    }

    func makeDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-attached-controller-\(name)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    func createSQLite(
        at url: URL,
        sql: String = """
            CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL);
            INSERT INTO records VALUES ('a', 'Alpha'), ('b', 'Beta');
            """
    ) throws {
        try executeSQL(at: url, sql: sql)
    }

    func interruptedPublicationFixture(
        sourceIdentifier: String,
        startedAt: Date
    ) throws -> (source: AttachedDataSourceRecord, plan: AttachedDataImportPlan) {
        let selection = try AttachedDataSourceSelection(
            id: "selection:records",
            kind: .sqliteTable,
            sourceIdentifier: "records",
            displayName: "Records",
            selectedFields: ["id", "body"],
            searchableFields: ["id", "body"],
            identityFields: ["id"],
            recordIdentityStrategy: .declaredPrimaryKey,
            schemaDigest: fixtureDigest("restart-schema"),
            estimatedRecordCount: 1
        )
        let selections = [selection]
        let selectionDigest = AttachedDataImportPlan.frozenSelectionDigest(
            for: selections
        )
        let sourceDigest = fixtureDigest("restart-source")
        let shapeDigest = fixtureDigest("restart-shape")
        let fileIdentity = AttachedDataFileIdentity(
            deviceID: 1,
            inode: 20,
            fileType: 0o100000,
            linkCount: 1,
            fileSize: 1_024,
            modificationNanoseconds: 1_000
        )
        let generationIdentifier = "generation:1:\(sourceDigest.prefix(32))"
        let plan = try AttachedDataImportPlan(
            id: "plan:1:\(selectionDigest.prefix(32))",
            sourceIdentifier: sourceIdentifier,
            sourceKind: .sqlite,
            mode: .importedSnapshot,
            fileIdentity: fileIdentity,
            sourceDigest: sourceDigest,
            shapeDigest: shapeDigest,
            selections: selections,
            selectionDigest: selectionDigest,
            budgets: .sqliteStandard,
            expectedRecordCount: selections.compactMap(\.estimatedRecordCount)
                .reduce(0, +),
            expectedMaterializedBytes: nil,
            normalizationVersion: 1,
            provenanceVersion: 1,
            generationIdentifier: generationIdentifier,
            createdAt: startedAt
        )
        let source = try AttachedDataSourceRecord(
            id: sourceIdentifier,
            kind: .sqlite,
            mode: .importedSnapshot,
            displayName: "Restart recovery",
            originalFilename: "restart.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            fileIdentity: fileIdentity,
            sourceDigest: sourceDigest,
            shapeDigest: shapeDigest,
            state: .importing,
            selections: selections,
            currentEpoch: 0,
            lastAttemptedRefreshAt: startedAt,
            pendingGenerationIdentifier: generationIdentifier,
            frozenImportPlan: plan,
            access: try .init(
                bookmarkState: .retained,
                continuingAccessRetained: true,
                lastAuthorizedAt: startedAt,
                lastResolvedAt: startedAt
            ),
            refreshEnabled: false,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        return (source, plan)
    }

    func removalPendingSource(id: String) throws -> AttachedDataSourceRecord {
        let now = Date()
        let selection = try AttachedDataSourceSelection(
            id: "selection:records",
            kind: .sqliteTable,
            sourceIdentifier: "records",
            displayName: "Records",
            selectedFields: ["id", "body"],
            searchableFields: ["id", "body"],
            identityFields: ["id"],
            recordIdentityStrategy: .declaredPrimaryKey,
            schemaDigest: fixtureDigest("removal-schema"),
            estimatedRecordCount: 1
        )
        let accountID = VaultIdentity.accountID(
            provider: VaultProviderKind.localImport.rawValue,
            providerAccountID: id
        )
        let containerID = VaultIdentity.containerID(
            provider: VaultProviderKind.localImport.rawValue,
            accountID: accountID,
            providerContainerID: selection.id
        )
        return try AttachedDataSourceRecord(
            id: id,
            kind: .sqlite,
            mode: .importedSnapshot,
            displayName: "Removal recovery",
            originalFilename: "removal.sqlite",
            privacySafeLocationDescriptor: "User-selected read-only SQLite file",
            fileIdentity: .init(
                deviceID: 1,
                inode: id == "attached:removal-absent" ? 10 : 11,
                fileType: 0o100000,
                linkCount: 1,
                fileSize: 1_024,
                modificationNanoseconds: 1_000
            ),
            sourceDigest: fixtureDigest("\(id)-source"),
            shapeDigest: fixtureDigest("\(id)-shape"),
            state: .connected,
            selections: [selection],
            currentEpoch: 1,
            lastSuccessfulRefreshAt: now,
            lastAttemptedRefreshAt: now,
            itemCount: 1,
            importedLocalContainerIdentifiers: [containerID],
            localDataRetentionState: .removalPending,
            currentGenerationIdentifier: "generation-current",
            access: .notRetained,
            refreshEnabled: false,
            createdAt: now,
            updatedAt: now
        )
    }

    func commitSyntheticGeneration(
        in vault: VaultController,
        source: AttachedDataSourceRecord,
        receiptHash: String,
        at timestamp: Date
    ) async throws -> VaultConnectorGenerationMarker {
        let selection = try XCTUnwrap(source.selections.first)
        let provider = VaultProviderKind.localImport.rawValue
        let accountID = VaultIdentity.accountID(
            provider: provider,
            providerAccountID: source.id
        )
        let containerID = VaultIdentity.containerID(
            provider: provider,
            accountID: accountID,
            providerContainerID: selection.id
        )
        _ = try await vault.database.replaceConnectorGeneration(.init(
            account: .init(
                id: accountID,
                provider: provider,
                providerAccountID: source.id,
                displayName: source.displayName,
                createdAt: source.createdAt,
                updatedAt: timestamp
            ),
            containers: [.init(
                id: containerID,
                accountID: accountID,
                providerContainerID: selection.id,
                kind: VaultContainerKind.importedCollection.rawValue,
                displayName: selection.displayName,
                createdAt: source.createdAt,
                updatedAt: timestamp
            )],
            records: [.init(
                id: "connector:\(fixtureDigest(source.id).prefix(32))",
                accountID: accountID,
                containerID: containerID,
                providerRecordID: "recovery-record",
                kind: "attached_sqlite_record",
                title: "Recovery record",
                body: "Synthetic recovery record",
                occurredAt: timestamp,
                capturedAt: timestamp,
                modifiedAt: timestamp
            )],
            generationReceiptHash: receiptHash,
            materializedByteCount: 25
        ))
        let marker = try await vault.database.connectorGenerationMarker(
            accountID: accountID
        )
        return try XCTUnwrap(marker)
    }

    func waitForRestartReconciliation(
        _ controller: AttachedDataSourcesController
    ) async -> Bool {
        for _ in 0..<1_000 {
            if !controller.hasUpdateBlockingWork { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !controller.hasUpdateBlockingWork
    }

    func fixtureDigest(_ value: String) -> String {
        ConnectorEnvelopeDigest.sha256(Data(value.utf8))
    }

    func executeSQL(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            throw sqliteError(database, code: opened)
        }
        defer { sqlite3_close_v2(database) }
        let executed = sqlite3_exec(database, sql, nil, nil, nil)
        guard executed == SQLITE_OK else {
            throw sqliteError(database, code: executed)
        }
    }

    func overwritePreservingResource(at url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func sqliteError(_ database: OpaquePointer?, code: Int32) -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite unavailable"
        return NSError(
            domain: "AttachedDataSourcesControllerTests.SQLite",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func waitForBlockedScope(
        _ scope: BlockingSecurityScopeProbe
    ) async -> Bool {
        for _ in 0..<400 {
            if scope.isBlocked { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return scope.isBlocked
    }
}

private final class ControllableSecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var resolutionFails = false
    private var resolvedBookmarksAreStale = false

    var access: AttachedSecurityScopedResourceAccess {
        AttachedSecurityScopedResourceAccess(
            start: { _ in true },
            stop: { _ in },
            makeBookmark: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            resolveBookmark: { [self] data in
                let resolution = lock.withLock {
                    (resolutionFails, resolvedBookmarksAreStale)
                }
                if resolution.0 {
                    throw AttachedDataFileFailureCode.bookmarkUnavailable
                }
                guard let path = String(data: data, encoding: .utf8) else {
                    throw AttachedDataFileFailureCode.bookmarkUnavailable
                }
                return (URL(fileURLWithPath: path), resolution.1)
            }
        )
    }

    func setResolutionFailure(_ enabled: Bool) {
        lock.withLock { resolutionFails = enabled }
    }

    func setResolvedBookmarksStale(_ enabled: Bool) {
        lock.withLock { resolvedBookmarksAreStale = enabled }
    }
}

private final class BlockingSecurityScopeProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var starts = 0
    private var stops = 0
    private var armed = false
    private var allowedStarts = 0
    private var blocked = false
    private var released = false

    var access: AttachedSecurityScopedResourceAccess {
        AttachedSecurityScopedResourceAccess(
            start: { [self] _ in start() },
            stop: { [self] _ in stop() },
            makeBookmark: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            resolveBookmark: { data in
                guard let path = String(data: data, encoding: .utf8) else {
                    throw AttachedDataFileFailureCode.bookmarkUnavailable
                }
                return (URL(fileURLWithPath: path), false)
            }
        )
    }

    var isBlocked: Bool {
        condition.withLock { blocked }
    }

    var balance: (starts: Int, stops: Int) {
        condition.withLock { (starts, stops) }
    }

    func armAfterAllowedStarts(_ count: Int) {
        condition.withLock {
            allowedStarts = count
            blocked = false
            released = false
            armed = true
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private func start() -> Bool {
        condition.lock()
        starts += 1
        if armed, allowedStarts > 0 {
            allowedStarts -= 1
        } else if armed {
            blocked = true
            condition.broadcast()
            while !released {
                condition.wait()
            }
            armed = false
        }
        condition.unlock()
        return true
    }

    private func stop() {
        condition.withLock {
            stops += 1
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
