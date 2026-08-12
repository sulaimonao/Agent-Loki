import Foundation
import XCTest
@testable import LokiBrief

private struct VaultImportGrantAuthorizer: VaultEntitlementAuthorizing {
    func decision(
        ownerID: String,
        capability: VaultEntitlementCapability,
        at date: Date
    ) async throws -> VaultEntitlementDecision {
        .init(
            ownerID: ownerID,
            capability: capability,
            granted: true,
            reason: .granted,
            evidenceID: "development-grant",
            evaluatedAt: date
        )
    }
}

private actor VaultImportTestSource: VaultImportSourceReading {
    nonisolated let sourceKind: VaultProviderKind
    private static let root = "<root>"
    private let pages: [String: VaultImportPage]
    private var observedCursors: [String?] = []

    init(sourceKind: VaultProviderKind = .rss, pages: [String: VaultImportPage]) {
        self.sourceKind = sourceKind
        self.pages = pages
    }

    func readPage(after cursor: String?, limit: Int) async throws -> VaultImportPage {
        observedCursors.append(cursor)
        return pages[cursor ?? Self.root] ?? .init(items: [], nextCursor: nil, sourceHighWatermark: nil)
    }

    func cursors() -> [String?] { observedCursors }
    func readCount() -> Int { observedCursors.count }

    nonisolated static func pageKey(_ cursor: String? = nil) -> String {
        cursor ?? root
    }
}

private actor VaultImportTestArchive: VaultImportArchiveWriting {
    private var originals: [String: String]

    init(originals: [String: String] = [:]) {
        self.originals = originals
    }

    func insertIfAbsent(_ evidence: VaultImportEvidence) async throws -> VaultArchiveInsertOutcome {
        if let existing = originals[evidence.stableID] {
            return .duplicate(existingOriginalSHA256: existing)
        }
        originals[evidence.stableID] = evidence.original.sha256
        return .inserted(storedOriginalSHA256: evidence.original.sha256)
    }

    func count() -> Int { originals.count }
    func digest(for stableID: String) -> String? { originals[stableID] }
}

private actor VaultImportTestCheckpointStore: VaultImportCheckpointPersisting {
    private var values: [String: VaultImportCheckpoint] = [:]

    func checkpoint(id: String) async throws -> VaultImportCheckpoint? { values[id] }
    func save(_ checkpoint: VaultImportCheckpoint) async throws { values[checkpoint.id] = checkpoint }
    func value(id: String) -> VaultImportCheckpoint? { values[id] }
}

final class VaultImportEntitlementTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_785_000_000)

    func testDevelopmentEntitlementSeparatesAcquisitionFromExistingDataOwnership() async {
        let provider = DeterministicDevelopmentEntitlementProvider(states: [
            .historicalBackfill: .expired,
            .archiveExport: .subscribed,
        ])

        let expired = await provider.entitlement(for: .historicalBackfill)
        XCTAssertEqual(expired.state, .expired)
        XCTAssertFalse(expired.acquisitionAllowed)
        XCTAssertTrue(expired.existingDataReadable)
        XCTAssertTrue(expired.exportAllowed)
        XCTAssertTrue(expired.deletionAllowed)

        let subscribed = await provider.entitlement(for: .archiveExport)
        XCTAssertEqual(subscribed.state, .subscribed)
        XCTAssertTrue(subscribed.acquisitionAllowed)

        let unconfigured = await provider.entitlement(for: .storageAnalytics)
        XCTAssertEqual(unconfigured.state, .providerNotConfigured)
        XCTAssertFalse(unconfigured.acquisitionAllowed)
        XCTAssertTrue(unconfigured.deletionAllowed)
    }

    func testProductionUnconfiguredProviderFailsClosedWithoutLockingOwnedData() async {
        let entitlement = await UnconfiguredFeatureEntitlementProvider().entitlement(for: .historicalBackfill)

        XCTAssertEqual(entitlement.state, .providerNotConfigured)
        XCTAssertEqual(entitlement.reasonCode, "vault_entitlement_provider_not_configured")
        XCTAssertFalse(entitlement.acquisitionAllowed)
        XCTAssertTrue(entitlement.existingDataReadable)
        XCTAssertTrue(entitlement.exportAllowed)
        XCTAssertTrue(entitlement.deletionAllowed)
    }

    func testEntitlementEvaluatorRejectsEvidenceOwnedByAnotherUser() {
        let evidence = VaultEntitlementEvidence(
            id: "evidence-other-owner",
            ownerID: "owner-two",
            productID: "development",
            source: .deterministicDevelopment,
            state: .subscribed,
            capabilities: [.historicalBackfill],
            validFrom: Self.anchor.addingTimeInterval(-60),
            validThrough: nil,
            observedAt: Self.anchor.addingTimeInterval(-30),
            configurationFingerprint: "fixture-fingerprint"
        )

        let decision = VaultEntitlementEvaluator().decision(
            ownerID: "owner-one",
            capability: .historicalBackfill,
            at: Self.anchor,
            evidence: [evidence]
        )

        XCTAssertFalse(decision.granted)
        XCTAssertEqual(decision.reason.rawValue, VaultEntitlementReason.ownerMismatch.rawValue)
        XCTAssertNil(decision.evidenceID)
    }

    func testImportCompletesAndRerunIsIdempotentWithoutRereadingSource() async throws {
        let item = Self.evidence(id: "feed-item-one", payload: "original-one")
        let source = VaultImportTestSource(pages: [
            VaultImportTestSource.pageKey(): .init(items: [item], nextCursor: nil, sourceHighWatermark: "feed-high-watermark"),
        ])
        let archive = VaultImportTestArchive()
        let checkpoints = VaultImportTestCheckpointStore()
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: archive,
            checkpoints: checkpoints,
            entitlements: VaultImportGrantAuthorizer(),
            now: { Self.anchor }
        )

        let request = Self.request(runID: "import-run-one")
        let first = try await coordinator.run(request)
        XCTAssertEqual(first.state, .complete)
        XCTAssertEqual(first.itemsInsertedThisRun, 1)
        XCTAssertEqual(first.duplicateItemsThisRun, 0)

        let second = try await coordinator.run(Self.request(runID: "import-run-two"))
        XCTAssertEqual(second.state, .complete)
        XCTAssertEqual(second.reasonCode, "vault_import_already_complete")
        XCTAssertEqual(second.itemsReadThisRun, 0)
        let sourceReadCount = await source.readCount()
        let archiveCount = await archive.count()
        let archivedDigest = await archive.digest(for: item.stableID)
        XCTAssertEqual(sourceReadCount, 1)
        XCTAssertEqual(archiveCount, 1)
        XCTAssertEqual(archivedDigest, item.original.sha256)
    }

    func testBudgetPauseResumesFromPersistedCursorAndPreservesOriginalDigests() async throws {
        let firstItem = Self.evidence(id: "feed-item-one", payload: "original-one")
        let secondItem = Self.evidence(id: "feed-item-two", payload: "original-two")
        let source = VaultImportTestSource(pages: [
            VaultImportTestSource.pageKey(): .init(items: [firstItem], nextCursor: "page-two", sourceHighWatermark: "watermark"),
            VaultImportTestSource.pageKey("page-two"): .init(items: [secondItem], nextCursor: nil, sourceHighWatermark: "watermark"),
        ])
        let archive = VaultImportTestArchive()
        let checkpoints = VaultImportTestCheckpointStore()
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: archive,
            checkpoints: checkpoints,
            entitlements: VaultImportGrantAuthorizer(),
            now: { Self.anchor }
        )

        let paused = try await coordinator.run(Self.request(runID: "pause-run", maximumPages: 1))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.reasonCode, "vault_import_budget_exhausted")

        let storedCheckpoint = await checkpoints.value(id: paused.checkpointID)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        XCTAssertEqual(checkpoint.sourceCursor, "page-two")
        XCTAssertEqual(checkpoint.itemsInserted, 1)

        let completed = try await coordinator.run(Self.request(runID: "resume-run", maximumPages: 2))
        XCTAssertEqual(completed.state, .complete)
        XCTAssertEqual(completed.itemsInsertedThisRun, 1)
        XCTAssertEqual(completed.cumulativeItemsInserted, 2)
        let observedCursors = await source.cursors()
        let firstDigest = await archive.digest(for: firstItem.stableID)
        let secondDigest = await archive.digest(for: secondItem.stableID)
        XCTAssertEqual(observedCursors, [nil, "page-two"])
        XCTAssertEqual(firstDigest, firstItem.original.sha256)
        XCTAssertEqual(secondDigest, secondItem.original.sha256)
    }

    func testImportRejectsCrossAccountEvidenceBeforeArchiveWrite() async throws {
        let mismatched = Self.evidence(id: "wrong-account", accountID: "account-two", payload: "private-original")
        let source = VaultImportTestSource(pages: [
            VaultImportTestSource.pageKey(): .init(items: [mismatched], nextCursor: nil, sourceHighWatermark: nil),
        ])
        let archive = VaultImportTestArchive()
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: archive,
            checkpoints: VaultImportTestCheckpointStore(),
            entitlements: VaultImportGrantAuthorizer(),
            now: { Self.anchor }
        )

        do {
            _ = try await coordinator.run(Self.request(runID: "cross-account"))
            XCTFail("Cross-account evidence must fail closed")
        } catch {
            XCTAssertEqual(
                (error as? VaultImportFailureCode)?.rawValue,
                VaultImportFailureCode.evidenceOwnershipMismatch.rawValue
            )
        }
        let archiveCount = await archive.count()
        XCTAssertEqual(archiveCount, 0)
    }

    func testUnavailableEntitlementBlocksBeforeSourceRead() async throws {
        let source = VaultImportTestSource(pages: [:])
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: VaultImportTestArchive(),
            checkpoints: VaultImportTestCheckpointStore(),
            entitlements: VaultUnavailableEntitlementAuthorizer(),
            now: { Self.anchor }
        )

        do {
            _ = try await coordinator.run(Self.request(runID: "denied"))
            XCTFail("Unavailable entitlement must block acquisition")
        } catch {
            XCTAssertEqual(
                (error as? VaultImportFailureCode)?.rawValue,
                VaultImportFailureCode.entitlementDenied.rawValue
            )
        }
        let sourceReadCount = await source.readCount()
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testDuplicateWithConflictingOriginalDigestFailsClosed() async throws {
        let item = Self.evidence(id: "conflicting-item", payload: "new-original")
        let source = VaultImportTestSource(pages: [
            VaultImportTestSource.pageKey(): .init(items: [item], nextCursor: nil, sourceHighWatermark: nil),
        ])
        let preservedDigest = String(repeating: "a", count: 64)
        let archive = VaultImportTestArchive(originals: [item.stableID: preservedDigest])
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: archive,
            checkpoints: VaultImportTestCheckpointStore(),
            entitlements: VaultImportGrantAuthorizer(),
            now: { Self.anchor }
        )

        do {
            _ = try await coordinator.run(Self.request(runID: "digest-conflict"))
            XCTFail("Conflicting original representations must not be replaced")
        } catch {
            XCTAssertEqual(
                (error as? VaultImportFailureCode)?.rawValue,
                VaultImportFailureCode.originalConflict.rawValue
            )
        }
        let archivedDigest = await archive.digest(for: item.stableID)
        XCTAssertEqual(archivedDigest, preservedDigest)
    }

    func testImportRejectsEmptyPageThatClaimsAnotherCursor() async throws {
        let source = VaultImportTestSource(pages: [
            VaultImportTestSource.pageKey(): .init(items: [], nextCursor: "impossible-progress", sourceHighWatermark: nil),
        ])
        let coordinator = VaultImportCoordinator(
            source: source,
            archive: VaultImportTestArchive(),
            checkpoints: VaultImportTestCheckpointStore(),
            entitlements: VaultImportGrantAuthorizer(),
            now: { Self.anchor }
        )

        do {
            _ = try await coordinator.run(Self.request(runID: "cursor-stall"))
            XCTFail("An empty nonterminal page must fail rather than loop")
        } catch {
            XCTAssertEqual(
                (error as? VaultImportFailureCode)?.rawValue,
                VaultImportFailureCode.cursorDidNotAdvance.rawValue
            )
        }
    }

    private static func request(runID: String, maximumPages: Int = 10) -> VaultImportRequest {
        .init(
            runID: runID,
            ownerID: "local-user",
            accountID: "account-one",
            containerID: "container-one",
            sourceKind: .rss,
            maximumPages: maximumPages,
            maximumItems: 20,
            pageSize: 10
        )
    }

    private static func evidence(
        id: String,
        accountID: String = "account-one",
        payload: String
    ) -> VaultImportEvidence {
        .init(
            stableID: id,
            ownerID: "local-user",
            accountID: accountID,
            containerID: "container-one",
            sourceKind: .rss,
            sourceItemID: "source-\(id)",
            sourceObservedAt: anchor,
            searchableText: "bounded searchable text",
            original: .init(
                representation: .p2NormalizedFeedEntry,
                payload: Data(payload.utf8)
            )
        )
    }
}
