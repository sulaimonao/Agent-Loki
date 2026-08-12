import Foundation
import XCTest
#if canImport(LokiBrief)
@testable import LokiBrief
#endif

private struct P8TestTerminalReceiptEnvelope: Codable {
    let schemaVersion: String
    let traceID: String
    let receipt: P8FSignedSmokeTerminalReceipt
    let eventCount: UInt64
    let firstEventSHA256: String
    let finalEventSHA256: String
    let diagnosticManifestSHA256: String
    let committedFinalEvent: P8FSignedSmokeEvent
    let committedDiagnosticManifest:
        P8FSignedSmokeDiagnosticManifestReceipt

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case receipt
        case eventCount = "event_count"
        case firstEventSHA256 = "first_event_sha256"
        case finalEventSHA256 = "final_event_sha256"
        case diagnosticManifestSHA256 =
            "diagnostic_manifest_sha256"
        case committedFinalEvent = "committed_final_event"
        case committedDiagnosticManifest =
            "committed_diagnostic_manifest"
    }
}

@MainActor
final class P8FSignedSmokeReceiptStoreTests: XCTestCase {
    private let fileManager = FileManager.default
    private let fixtureSHA256 = String(repeating: "a", count: 64)
    private let allowlistSHA256 = String(repeating: "b", count: 64)
    private let authorizationSHA256 = String(repeating: "c", count: 64)
    private let generationSHA256 = String(repeating: "d", count: 64)
    private let modelSHA256 = String(repeating: "e", count: 64)
    private let executableSHA256 = String(repeating: "f", count: 64)
    private let cdHash = String(repeating: "1", count: 40)

    func testBuildSelectionReopensAndPreservesAbsentVersusExplicitEmpty()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        var store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        XCTAssertNil(try store.load())

        try store.save([])
        store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        XCTAssertEqual(try store.load(), [])

        let expected: Set<SemanticIndexSourceKind> = [
            .brief,
            .schedule,
        ]
        try store.save(expected)
        store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        XCTAssertEqual(try store.load(), expected)

        try store.clear()
        store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        XCTAssertNil(try store.load())
    }

    func testAuthorityReceiptsReopenAndUseRequiredModes() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let selectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        try selectionStore.save([.brief, .schedule])

        let expected = [
            makeAuthorityEvent(
                name: .scopeAuthorized,
                status: "authorized",
                reasonCode:
                    "semantic_rebuild_source_scope_authorized"
            ),
            makeAuthorityEvent(
                name: .generationBound,
                status: "bound",
                reasonCode:
                    "semantic_generation_source_scope_bound"
            ),
        ]
        var authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try authorityStore.save(expected)
        authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        XCTAssertEqual(try authorityStore.load(), expected)
        let artifact = try XCTUnwrap(
            try authorityStore.loadValidatedArtifact()
        )
        XCTAssertEqual(artifact.receipts, expected)
        XCTAssertEqual(artifact.receiptCount, expected.count)
        XCTAssertEqual(
            artifact.canonicalSHA256,
            P8FSignedSmokeDigest.sha256(
                try Data(
                    contentsOf: receiptsDirectory(in: root)
                        .appendingPathComponent(
                            P8FSignedSmokeReceiptLayout
                                .sourceAuthorityReceiptsFileName
                        )
                )
            )
        )

        let receiptDirectory = receiptsDirectory(in: root)
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(
            try permissions(of: receiptDirectory),
            0o700
        )
        XCTAssertEqual(
            try permissions(
                of: receiptDirectory.appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .buildSourceSelectionFileName
                )
            ),
            0o600
        )
        XCTAssertEqual(
            try permissions(
                of: receiptDirectory.appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .sourceAuthorityReceiptsFileName
                )
            ),
            0o600
        )
    }

    func testMutableStoresRejectSuccessorReplacementBeforeWrite()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let staleSelection =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let staleAuthority =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try staleSelection.save([.brief])
        try staleAuthority.save([
            makeAuthorityEvent(
                name: .scopeAuthorized,
                status: "authorized",
                reasonCode:
                    "semantic_rebuild_source_scope_authorized"
            ),
        ])

        let successorSelection =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let successorAuthority =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try successorSelection.save([.schedule])
        try successorAuthority.save([
            makeAuthorityEvent(
                name: .generationBound,
                status: "bound",
                reasonCode:
                    "semantic_generation_source_scope_bound"
            ),
        ])

        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        let authorityURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .sourceAuthorityReceiptsFileName
            )
        let successorSelectionData = try Data(
            contentsOf: selectionURL
        )
        let successorAuthorityData = try Data(
            contentsOf: authorityURL
        )

        assertThrows(.ioFailure) {
            try staleSelection.save([.brief, .schedule])
        }
        assertThrows(.ioFailure) {
            try staleAuthority.save([
                self.makeAuthorityEvent(
                    name: .scopeAuthorized,
                    status: "authorized",
                    reasonCode:
                        "semantic_rebuild_source_scope_authorized"
                ),
            ])
        }
        XCTAssertEqual(
            try Data(contentsOf: selectionURL),
            successorSelectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: authorityURL),
            successorAuthorityData
        )
    }

    func testMutableStoresRejectSuccessorReplacementBeforeClear()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let staleSelection =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let staleAuthority =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try staleSelection.save([.brief])
        try staleAuthority.save([
            makeAuthorityEvent(
                name: .scopeAuthorized,
                status: "authorized",
                reasonCode:
                    "semantic_rebuild_source_scope_authorized"
            ),
        ])

        let successorSelection =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let successorAuthority =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try successorSelection.save([.schedule])
        try successorAuthority.save([
            makeAuthorityEvent(
                name: .generationBound,
                status: "bound",
                reasonCode:
                    "semantic_generation_source_scope_bound"
            ),
        ])

        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        let authorityURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .sourceAuthorityReceiptsFileName
            )
        let successorSelectionData = try Data(
            contentsOf: selectionURL
        )
        let successorAuthorityData = try Data(
            contentsOf: authorityURL
        )

        assertThrows(.ioFailure) {
            try staleSelection.clear()
        }
        assertThrows(.ioFailure) {
            try staleAuthority.clear()
        }
        XCTAssertEqual(
            try Data(contentsOf: selectionURL),
            successorSelectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: authorityURL),
            successorAuthorityData
        )
    }

    func testHardLinksPresentBeforeMutableStoreConstructionFailClosed()
        throws
    {
        let root = try makeIsolatedRoot()
        let outside = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        _ = try P8FSignedSmokeSemanticBuildSourceSelectionStore(
            isolatedRoot: root
        )
        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        let authorityURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .sourceAuthorityReceiptsFileName
            )
        let outsideSelection = outside.appendingPathComponent(
            "outside-selection.json"
        )
        let outsideAuthority = outside.appendingPathComponent(
            "outside-authority.json"
        )
        let selectionData = Data("outside-selection".utf8)
        let authorityData = Data("outside-authority".utf8)
        try selectionData.write(to: outsideSelection)
        try authorityData.write(to: outsideAuthority)
        try setPermissions(0o600, on: outsideSelection)
        try setPermissions(0o600, on: outsideAuthority)
        try fileManager.linkItem(
            at: outsideSelection,
            to: selectionURL
        )
        try fileManager.linkItem(
            at: outsideAuthority,
            to: authorityURL
        )

        assertThrows(.ioFailure) {
            _ = try
                P8FSignedSmokeSemanticBuildSourceSelectionStore(
                    isolatedRoot: root
                )
        }
        assertThrows(.ioFailure) {
            _ = try
                P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                    isolatedRoot: root
                )
        }
        XCTAssertEqual(
            try Data(contentsOf: outsideSelection),
            selectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideAuthority),
            authorityData
        )
    }

    func testHardLinksInsertedBeforeMutableWritesFailClosed()
        throws
    {
        let root = try makeIsolatedRoot()
        let outside = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let selectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        let authorityURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .sourceAuthorityReceiptsFileName
            )
        let outsideSelection = outside.appendingPathComponent(
            "outside-selection.json"
        )
        let outsideAuthority = outside.appendingPathComponent(
            "outside-authority.json"
        )
        let selectionData = Data("outside-selection".utf8)
        let authorityData = Data("outside-authority".utf8)
        try selectionData.write(to: outsideSelection)
        try authorityData.write(to: outsideAuthority)
        try setPermissions(0o600, on: outsideSelection)
        try setPermissions(0o600, on: outsideAuthority)
        try fileManager.linkItem(
            at: outsideSelection,
            to: selectionURL
        )
        try fileManager.linkItem(
            at: outsideAuthority,
            to: authorityURL
        )

        assertThrows(.ioFailure) {
            try selectionStore.save([.brief])
        }
        assertThrows(.ioFailure) {
            try authorityStore.save([
                self.makeAuthorityEvent(
                    name: .scopeAuthorized,
                    status: "authorized",
                    reasonCode:
                        "semantic_rebuild_source_scope_authorized"
                ),
            ])
        }
        XCTAssertEqual(
            try Data(contentsOf: outsideSelection),
            selectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideAuthority),
            authorityData
        )
    }

    func testHardLinksInsertedBeforeMutableClearsFailClosed()
        throws
    {
        let root = try makeIsolatedRoot()
        let outside = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let selectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try selectionStore.save([.brief])
        try authorityStore.save([
            makeAuthorityEvent(
                name: .scopeAuthorized,
                status: "authorized",
                reasonCode:
                    "semantic_rebuild_source_scope_authorized"
            ),
        ])
        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        let authorityURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .sourceAuthorityReceiptsFileName
            )
        let selectionData = try Data(contentsOf: selectionURL)
        let authorityData = try Data(contentsOf: authorityURL)
        let outsideSelection = outside.appendingPathComponent(
            "outside-selection.json"
        )
        let outsideAuthority = outside.appendingPathComponent(
            "outside-authority.json"
        )
        try fileManager.linkItem(
            at: selectionURL,
            to: outsideSelection
        )
        try fileManager.linkItem(
            at: authorityURL,
            to: outsideAuthority
        )

        assertThrows(.ioFailure) {
            try selectionStore.clear()
        }
        assertThrows(.ioFailure) {
            try authorityStore.clear()
        }
        XCTAssertEqual(
            try Data(contentsOf: outsideSelection),
            selectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideAuthority),
            authorityData
        )
        XCTAssertEqual(
            try Data(contentsOf: selectionURL),
            selectionData
        )
        XCTAssertEqual(
            try Data(contentsOf: authorityURL),
            authorityData
        )
    }

    func testAuthorityStoreRejectsManualOperatorEvidence() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let store =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        let manualEvent = P8SemanticSourceAuthorityEvent(
            occurredAt: fixedDate(0),
            name: .scopeAuthorized,
            sourceAuthorityVersion:
                SemanticIndexBuildScope.currentContractVersion,
            sourceAllowlistHash: allowlistSHA256,
            authorizationReceiptIdentifier:
                "semantic_scope_manual_operator",
            buildInitiation: .manualOperator,
            sourceKinds: [.brief],
            status: "authorized",
            reasonCode:
                "semantic_rebuild_source_scope_authorized"
        )

        assertThrows(.unsafeSourceAuthorityReceipt) {
            try store.save([manualEvent])
        }
        XCTAssertEqual(try store.load(), [])
    }

    func testSymlinkedFixedArtifactAndReceiptDirectoryAreRejected()
        throws
    {
        let root = try makeIsolatedRoot()
        let externalRoot = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: externalRoot)
        }

        let store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        let externalFile = externalRoot.appendingPathComponent(
            "outside.json"
        )
        try Data("{}".utf8).write(to: externalFile)
        try setPermissions(0o600, on: externalFile)
        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        try fileManager.createSymbolicLink(
            at: selectionURL,
            withDestinationURL: externalFile
        )

        assertThrows(.fixedArtifactSymbolicLink) {
            _ = try store.load()
        }
        assertThrows(.fixedArtifactSymbolicLink) {
            try store.save([.brief])
        }

        let secondRoot = try makeIsolatedRoot()
        let outsideDirectory = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: secondRoot)
            try? fileManager.removeItem(at: outsideDirectory)
        }
        try fileManager.createSymbolicLink(
            at: receiptsDirectory(in: secondRoot),
            withDestinationURL: outsideDirectory
        )

        assertThrows(.fixedArtifactSymbolicLink) {
            _ =
                try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                    isolatedRoot: secondRoot
                )
        }
    }

    func testCorruptCanonicalFileFailsClosedAndCannotBeOverwritten()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let store =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        try store.save([.brief])
        let selectionURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .buildSourceSelectionFileName
            )
        try Data("{}".utf8).write(
            to: selectionURL,
            options: []
        )
        try setPermissions(0o600, on: selectionURL)

        assertThrows(.malformedBuildSourceSelection) {
            _ = try store.load()
        }
        assertThrows(.malformedBuildSourceSelection) {
            try store.save([.schedule])
        }
        XCTAssertEqual(
            try Data(contentsOf: selectionURL),
            Data("{}".utf8)
        )
    }

    func testEventChainReopensAndTerminalReceiptBindsTypedSummary()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        var writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let first = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        let second = try writer.append(
            makeEventDraft(
                event: .storageIsolation,
                parentSpanID: first.spanID,
                component: .persistence,
                status: .success,
                reasonCode: .storageSelected,
                scenario: .storageIsolation,
                timestamp: fixedDate(1)
            )
        )
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(first.traceID, second.traceID)

        let firstURL = eventsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout.eventFileName(
                    sequence: 1
                )
            )
        XCTAssertEqual(
            second.previousEventSHA256,
            P8FSignedSmokeDigest.sha256(
                try Data(contentsOf: firstURL)
            )
        )

        let terminalEvents = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: first.spanID,
            startingAt: 2
        )

        let terminal = try makeSuccessfulTerminalReceipt()
        _ = try writer
            .writeCanonicalDiagnosticManifestReceipt()
        let committed = try writer.writeTerminalReceipt(terminal)
        XCTAssertEqual(committed.status, terminal.status)
        XCTAssertNotNil(committed.artifactLedger)
        XCTAssertEqual(
            committed.artifactLedger?
                .sourceAuthorityReceiptCount,
            1
        )
        writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(writer.events.first, first)
        XCTAssertEqual(writer.events.dropFirst().first, second)
        XCTAssertEqual(writer.events.last, terminalEvents.run)
        XCTAssertTrue(writer.events.contains(terminalEvents.cleanup))
        XCTAssertEqual(writer.terminalReceipt, committed)

        assertThrows(.terminalReceiptAlreadyWritten) {
            _ = try writer.append(
                self.makeEventDraft(
                    event: .cleanup,
                    parentSpanID: second.spanID,
                    component: .cleanup,
                    status: .success,
                    reasonCode: .cleanupPassed,
                    scenario: .cleanup,
                    timestamp: self.fixedDate(2)
                )
            )
        }

        XCTAssertEqual(
            try permissions(of: eventsDirectory(in: root)),
            0o700
        )
        XCTAssertEqual(try permissions(of: firstURL), 0o600)
        XCTAssertEqual(
            try permissions(
                of: receiptsDirectory(in: root)
                    .appendingPathComponent(
                        P8FSignedSmokeReceiptLayout
                            .terminalReceiptFileName
                    )
            ),
            0o600
        )
    }

    func testSuccessfulTerminalRejectsClaimsWithoutCommittedEvidence()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .cleanup,
                parentSpanID: started.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup,
                timestamp: fixedDate(1)
            )
        )

        assertThrows(.terminalReceiptInvalid) {
            _ = try writer.commitTerminalReceipt(
                self.makeSuccessfulTerminalReceipt(),
                finalEventDraft: self.makeEventDraft(
                    event: .run,
                    parentSpanID: started.spanID,
                    component: .runner,
                    status: .success,
                    reasonCode: .runCompleted,
                    scenario: .run,
                    timestamp: self.fixedDate(2)
                )
            )
        }
        XCTAssertFalse(fileManager.fileExists(
            atPath: terminalReceiptURL(in: root).path
        ))
    }

    func testFullyRehashedEventAfterTerminalRunIsRejected()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: started.spanID,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                scenario: .run,
                timestamp: fixedDate(1)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .cleanup,
                parentSpanID: started.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup,
                timestamp: fixedDate(2)
            )
        )

        assertThrows(.terminalReceiptInvalid) {
            _ = try writer.writeTerminalReceipt(
                self.makeFailedTerminalReceipt()
            )
        }
    }

    func testReceiptDirectorySamePathReplacementInvalidatesWriter()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let receipts = receiptsDirectory(in: root)
        let displaced = root.appendingPathComponent(
            "displaced-receipts",
            isDirectory: true
        )
        try fileManager.moveItem(at: receipts, to: displaced)
        try fileManager.createDirectory(
            at: receipts,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try setPermissions(0o700, on: receipts)

        assertThrows(.ioFailure) {
            _ = try writer.append(
                self.makeEventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    timestamp: self.fixedDate(0)
                )
            )
        }
    }

    func testEventsDirectorySamePathReplacementInvalidatesWriterAndPreservesSuccessor()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let events = eventsDirectory(in: root)
        let displaced = root.appendingPathComponent(
            "displaced-events",
            isDirectory: true
        )
        try fileManager.moveItem(at: events, to: displaced)
        try fileManager.createDirectory(
            at: events,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try setPermissions(0o700, on: events)
        let marker = events.appendingPathComponent(
            "successor-marker"
        )
        let markerData = Data("successor-owned".utf8)
        try markerData.write(to: marker)

        assertThrows(.ioFailure) {
            _ = try writer.append(
                self.makeEventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    timestamp: self.fixedDate(0)
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: marker), markerData)
        XCTAssertTrue(fileManager.fileExists(atPath: displaced.path))
    }

    func testHardLinkedEventAndImmutableArtifactsFailClosedOnReopen()
        throws
    {
        for artifactName in [
            "event",
            "diagnostic-manifest",
            "terminal-receipt",
        ] {
            let root = try makeIsolatedRoot()
            let outside = try makeIsolatedRoot()
            defer {
                try? fileManager.removeItem(at: root)
                try? fileManager.removeItem(at: outside)
            }
            _ = try writeFailedTerminal(in: root)
            let artifactURL: URL
            switch artifactName {
            case "event":
                artifactURL = eventsDirectory(in: root)
                    .appendingPathComponent(
                        P8FSignedSmokeReceiptLayout.eventFileName(
                            sequence: 1
                        )
                    )
            case "diagnostic-manifest":
                artifactURL = diagnosticManifestURL(in: root)
            default:
                artifactURL = terminalReceiptURL(in: root)
            }
            let artifactData = try Data(contentsOf: artifactURL)
            let outsideAlias = outside.appendingPathComponent(
                "\(artifactName)-outside-alias.json"
            )
            try fileManager.linkItem(
                at: artifactURL,
                to: outsideAlias
            )

            assertThrows(.ioFailure) {
                _ = try P8FSignedSmokeReceiptWriter(
                    isolatedRoot: root
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: outsideAlias),
                artifactData
            )
            XCTAssertEqual(
                try Data(contentsOf: artifactURL),
                artifactData
            )
        }
    }

    func testTamperedEventBreaksHashChainOnReopen() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let first = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .storageIsolation,
                parentSpanID: first.spanID,
                component: .persistence,
                status: .success,
                reasonCode: .storageSelected,
                scenario: .storageIsolation,
                timestamp: fixedDate(1)
            )
        )

        let firstURL = eventsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout.eventFileName(
                    sequence: 1
                )
            )
        let original = try String(
            decoding: Data(contentsOf: firstURL),
            as: UTF8.self
        )
        let tampered = original.replacingOccurrences(
            of: P8FSignedSmokeReasonCode.runStarted.rawValue,
            with: P8FSignedSmokeReasonCode.storageSelected.rawValue
        )
        XCTAssertNotEqual(original, tampered)
        try Data(tampered.utf8).write(
            to: firstURL,
            options: .atomic
        )
        try setPermissions(0o600, on: firstURL)

        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testDecodedInvalidTerminalCountersFailClosed() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let first = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: first.spanID,
            startingAt: 1
        )
        _ = try writer
            .writeCanonicalDiagnosticManifestReceipt()
        _ = try writer.writeTerminalReceipt(
            makeSuccessfulTerminalReceipt()
        )

        let terminalURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .terminalReceiptFileName
            )
        let original = try String(
            decoding: Data(contentsOf: terminalURL),
            as: UTF8.self
        )
        let tampered = original.replacingOccurrences(
            of: #""artifact_count":4"#,
            with: #""artifact_count":-1"#
        )
        XCTAssertNotEqual(original, tampered)
        try Data(tampered.utf8).write(
            to: terminalURL,
            options: .atomic
        )
        try setPermissions(0o600, on: terminalURL)

        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testSuccessfulTerminalRequiresAndBindsDiagnosticManifest()
        throws
    {
        let root = try makeIsolatedRoot()
        let failedRoot = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: failedRoot)
        }

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let first = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: first.spanID,
            startingAt: 1
        )
        _ = try writer.writeTerminalReceipt(
            makeSuccessfulTerminalReceipt()
        )

        let terminalData = try Data(
            contentsOf: receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .terminalReceiptFileName
                )
        )
        XCTAssertTrue(
            String(decoding: terminalData, as: UTF8.self)
                .contains(#""diagnostic_manifest_sha256":"#)
        )
        try fileManager.removeItem(
            at: receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .diagnosticManifestFileName
                )
        )
        let recoveredWriter =
            try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        XCTAssertNotNil(
            recoveredWriter.diagnosticManifestReceipt
        )
        XCTAssertNotNil(
            recoveredWriter.terminalReceipt?.artifactLedger
        )

        var failedWriter = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: failedRoot
        )
        _ = try failedWriter.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        let failedReceipt =
            try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .failed,
                reasonCode: .runFailed,
                startedAt: fixedDate(0),
                completedAt: fixedDate(1),
                applicationIdentity:
                    P8FSignedSmokeReceiptApplicationIdentity(
                        executableSHA256: executableSHA256,
                        cdHash: cdHash
                    ),
                privacySummary:
                    P8FSignedSmokePrivacySummary(
                        artifactCount: 0
                    )
            )
        _ = try failedWriter.writeTerminalReceipt(
            failedReceipt
        )
        failedWriter = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: failedRoot
        )
        XCTAssertEqual(
            failedWriter.terminalReceipt?.status,
            failedReceipt.status
        )
        XCTAssertNotNil(
            failedWriter.terminalReceipt?.artifactLedger
        )
        XCTAssertNotNil(failedWriter.diagnosticManifestReceipt)
    }

    func testCancelledStatusRawEncodingRoundTripsAndUnknownFailsClosed()
        throws
    {
        let encoded = try P8FSignedSmokeJSON.encode(
            P8FSignedSmokeStatus.cancelled
        )
        XCTAssertEqual(encoded, Data(#""cancelled""#.utf8))
        XCTAssertEqual(
            try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeStatus.self,
                from: encoded
            ),
            .cancelled
        )
        assertThrows(.ioFailure) {
            _ = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeStatus.self,
                from: Data(#""canceled""#.utf8)
            )
        }
    }

    func testTerminalCommitRecoversAfterCommitMarkerBeforeReplicas()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let committed = try writeInterruptedFailedTerminal(
            in: root,
            at: .afterCommitMarker
        )
        XCTAssertEqual(
            try eventFileCount(in: root),
            1
        )
        XCTAssertFalse(fileManager.fileExists(
            atPath: diagnosticManifestURL(in: root).path
        ))

        let recovered = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(recovered.events.count, 2)
        XCTAssertEqual(recovered.events.last?.status, .failed)
        XCTAssertEqual(recovered.terminalReceipt, committed)
        XCTAssertNotNil(recovered.diagnosticManifestReceipt)
        XCTAssertEqual(
            recovered.terminalReceipt?.artifactLedger?
                .eventCount,
            2
        )
    }

    func testTerminalCommitRecoversManifestAfterFinalEventReplica()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        _ = try writeInterruptedFailedTerminal(
            in: root,
            at: .afterFinalEventReplica
        )
        XCTAssertEqual(try eventFileCount(in: root), 2)
        XCTAssertFalse(fileManager.fileExists(
            atPath: diagnosticManifestURL(in: root).path
        ))

        let recovered = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(recovered.events.count, 2)
        XCTAssertNotNil(recovered.diagnosticManifestReceipt)
        XCTAssertEqual(
            recovered.terminalReceipt?.artifactLedger?
                .diagnosticManifestCount,
            1
        )
    }

    func testInvalidCommitMarkerDoesNotMaterializeRecoveryReplicas()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        _ = try writeInterruptedFailedTerminal(
            in: root,
            at: .afterCommitMarker
        )
        XCTAssertEqual(try eventFileCount(in: root), 1)
        XCTAssertFalse(fileManager.fileExists(
            atPath: diagnosticManifestURL(in: root).path
        ))

        let terminalURL = terminalReceiptURL(in: root)
        let envelope = try P8FSignedSmokeJSON.decode(
            P8TestTerminalReceiptEnvelope.self,
            from: Data(contentsOf: terminalURL)
        )
        let invalidReceipt = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .failed,
            reasonCode: .cleanupFailed,
            startedAt: envelope.receipt.startedAt,
            completedAt: envelope.receipt.completedAt,
            applicationIdentity:
                envelope.receipt.applicationIdentity,
            admissionAccepted:
                envelope.receipt.admissionAccepted,
            privacySummary: envelope.receipt.privacySummary,
            artifactLedger: envelope.receipt.artifactLedger
        )
        let invalidEnvelope = P8TestTerminalReceiptEnvelope(
            schemaVersion: envelope.schemaVersion,
            traceID: envelope.traceID,
            receipt: invalidReceipt,
            eventCount: envelope.eventCount,
            firstEventSHA256: envelope.firstEventSHA256,
            finalEventSHA256: envelope.finalEventSHA256,
            diagnosticManifestSHA256:
                envelope.diagnosticManifestSHA256,
            committedFinalEvent: envelope.committedFinalEvent,
            committedDiagnosticManifest:
                envelope.committedDiagnosticManifest
        )
        try P8FSignedSmokeJSON.encode(invalidEnvelope).write(
            to: terminalURL,
            options: .atomic
        )
        try setPermissions(0o600, on: terminalURL)

        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
        XCTAssertEqual(try eventFileCount(in: root), 1)
        XCTAssertFalse(fileManager.fileExists(
            atPath: diagnosticManifestURL(in: root).path
        ))
    }

    func testPrecommitFailureLeavesNoTerminalAuthority() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let testHooks = try
            P8FSignedSmokeTerminalCommitXCTestHooks.make {
                boundary in
                if boundary == .beforeCommitMarker {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root,
            testHooks: testHooks
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        let receipt = try makeFailedTerminalReceipt()
        XCTAssertThrowsError(
            try writer.commitTerminalReceipt(
                receipt,
                finalEventDraft: makeEventDraft(
                    event: .run,
                    parentSpanID: started.spanID,
                    component: .runner,
                    status: .failed,
                    reasonCode: .runFailed,
                    scenario: .run,
                    timestamp: fixedDate(1)
                )
            )
        )
        XCTAssertNil(writer.terminalReceipt)
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertFalse(fileManager.fileExists(
            atPath: terminalReceiptURL(in: root).path
        ))
        XCTAssertNoThrow(
            try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        )
    }

    @MainActor
    func testCancellationAtFinalPrecommitBoundaryCannotCommitSuccess()
        async throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let commitTask = Task { @MainActor in
            let testHooks = try
                P8FSignedSmokeTerminalCommitXCTestHooks.make {
                    boundary in
                    guard boundary == .beforeCommitMarker else {
                        return
                    }
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            let writer = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root,
                testHooks: testHooks
            )
            let started = try writer.append(
                makeEventDraft(
                    event: .run,
                    parentSpanID: nil,
                    component: .runner,
                    status: .started,
                    reasonCode: .runStarted,
                    scenario: .run,
                    timestamp: fixedDate(0)
                )
            )
            _ = try appendSuccessfulTerminalEvents(
                to: writer,
                parentSpanID: started.spanID,
                startingAt: 1,
                appendFinalRun: false
            )
            return try writer.commitTerminalReceipt(
                makeSuccessfulTerminalReceipt(),
                finalEventDraft: makeEventDraft(
                    event: .run,
                    parentSpanID: started.spanID,
                    component: .runner,
                    status: .success,
                    reasonCode: .runCompleted,
                    scenario: .run,
                    timestamp: fixedDate(50)
                )
            )
        }

        do {
            _ = try await commitTask.value
            XCTFail("Cancelled precommit unexpectedly committed success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let reopened = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertNil(reopened.terminalReceipt)
        XCTAssertFalse(fileManager.fileExists(
            atPath: terminalReceiptURL(in: root).path
        ))
    }

    func testTerminalEventWithoutCommitMarkerFailsClosed() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: started.spanID,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                scenario: .run,
                timestamp: fixedDate(1)
            )
        )
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testArtifactLedgerTamperFailsCanonicalReconciliation()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        _ = try writeFailedTerminal(in: root)
        let url = terminalReceiptURL(in: root)
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        var receipt = try XCTUnwrap(
            envelope["receipt"] as? [String: Any]
        )
        var ledger = try XCTUnwrap(
            receipt["artifact_ledger"] as? [String: Any]
        )
        ledger["event_count"] = 9_999
        receipt["artifact_ledger"] = ledger
        envelope["receipt"] = receipt
        try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
        try setPermissions(0o600, on: url)

        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testSuccessfulTerminalRequiresDurableSourceAuthorityArtifactBinding()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: started.spanID,
            startingAt: 2,
            bindSourceAuthorityArtifact: false
        )
        _ = try writer.writeCanonicalDiagnosticManifestReceipt()

        assertThrows(.terminalReceiptInvalid) {
            _ = try writer.writeTerminalReceipt(
                self.makeSuccessfulTerminalReceipt()
            )
        }
    }

    func testEventSemanticTupleAndProviderOutcomeContradictionsFail()
        throws
    {
        let ordinary = try P8FSignedSmokeEventMetadata(
            scenario: .storageIsolation
        )
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventDraft(
                event: .storageIsolation,
                component: .persistence,
                status: .failed,
                reasonCode: .storageSelected,
                metadata: ordinary,
                timestamp: self.fixedDate(0)
            )
        }

        let start = fixedDate(0)
        let end = fixedDate(0.001)
        let provider = try P8FSignedSmokeEventMetadata(
            scenario: .qwenEmbedding,
            model: .qwenEmbedding,
            endpointClassification: .ollamaModelIPv4Loopback,
            processIdentifier: 42,
            executableSHA256: executableSHA256,
            providerRequestTraceSHA256:
                String(repeating: "2", count: 64),
            providerRequestIdentifierSHA256:
                String(repeating: "3", count: 64),
            providerKind: .embedding,
            providerOperationKind: .embedding,
            providerOutcome: .failed,
            providerIntervalStartedAt: start,
            providerIntervalEndedAt: end,
            providerIntervalDurationMilliseconds: 1
        )
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventDraft(
                event: .network,
                component: .modelProvider,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 1,
                metadata: provider,
                timestamp: end
            )
        }
    }

    func testCancelledTerminalPersistsHydratesAndUsesVersionedContracts()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let expected = try writeCancelledTerminal(in: root)
        var writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(writer.terminalReceipt, expected)
        XCTAssertEqual(writer.events.count, 4)
        XCTAssertEqual(writer.events.first?.status, .started)
        XCTAssertEqual(
            writer.events.first?.reasonCode,
            .runStarted
        )
        XCTAssertEqual(writer.events.last?.event, .run)
        XCTAssertEqual(writer.events.last?.status, .cancelled)
        XCTAssertEqual(writer.events.last?.reasonCode, .runCancelled)

        let eventData = try Data(
            contentsOf: eventsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .eventFileName(sequence: 4)
                )
        )
        let terminalData = try Data(
            contentsOf: receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .terminalReceiptFileName
                )
        )
        let eventJSON = String(decoding: eventData, as: UTF8.self)
        let terminalJSON = String(
            decoding: terminalData,
            as: UTF8.self
        )
        XCTAssertTrue(
            eventJSON.contains(
                #""schema_version":"agent-loki.p8f.signed-smoke-event.v2""#
            )
        )
        XCTAssertTrue(eventJSON.contains(#""status":"cancelled""#))
        XCTAssertTrue(
            terminalJSON.contains(
                #""schema_version":"agent-loki.p8f.signed-smoke-terminal-receipt.v4""#
            )
        )
        XCTAssertTrue(
            terminalJSON.contains(#""status":"cancelled""#)
        )
        XCTAssertTrue(
            terminalJSON.contains(
                #""reason_code":"p8f_smoke_run_cancelled""#
            )
        )
        XCTAssertTrue(
            terminalJSON.contains("diagnostic_manifest_sha256")
        )
        XCTAssertTrue(terminalJSON.contains("artifact_ledger"))
        XCTAssertTrue(expected.privacySummary.passed)

        XCTAssertEqual(
            P8FSignedSmokeDiagnosticArtifactClassification
                .applicationDiagnostics
                .approvedFieldsSchemaSHA256,
            P8FSignedSmokeDigest.sha256(
                "agent-loki.p8f.diagnostic.application-diagnostics.canonical-event-array.v2"
            )
        )
        XCTAssertEqual(
            P8FSignedSmokeDiagnosticManifestReceipt
                .currentSchemaVersion,
            "agent-loki.p8f.diagnostic-artifact-manifest.v1"
        )
        XCTAssertEqual(
            P8FSignedSmokeReceiptLayout.terminalReceiptFileName,
            "terminal-receipt.v1.json"
        )
        try P8FSignedSmokeReceiptArtifactValidator
            .validateReceiptDirectory(isolatedRoot: root)

        writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(writer.terminalReceipt, expected)

        let finalPrivacy = try P8FSignedSmokePrivacyScanner.scan(
            isolatedRoot: root
        )
        XCTAssertTrue(finalPrivacy.passed)
        XCTAssertEqual(finalPrivacy.artifactCount, 6)
        XCTAssertEqual(finalPrivacy.forbiddenFieldCount, 0)
        XCTAssertEqual(finalPrivacy.forbiddenValueCount, 0)
        XCTAssertEqual(finalPrivacy.privatePathCount, 0)
    }

    func testTerminalRejectsNonterminalStatusesAndMismatchedCancellationReason()
        throws
    {
        let identity =
            try P8FSignedSmokeReceiptApplicationIdentity(
                executableSHA256: executableSHA256,
                cdHash: cdHash
            )
        let privacy =
            try P8FSignedSmokePrivacySummary(artifactCount: 0)

        for status: P8FSignedSmokeStatus in [
            .started,
            .degraded,
            .skipped,
        ] {
            assertThrows(.terminalReceiptInvalid) {
                _ = try P8FSignedSmokeTerminalReceipt(
                    scenario: .run,
                    status: status,
                    reasonCode: .runFailed,
                    startedAt: self.fixedDate(0),
                    completedAt: self.fixedDate(1),
                    applicationIdentity: identity,
                    privacySummary: privacy
                )
            }
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .cancelled,
                reasonCode: .runFailed,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                privacySummary: privacy
            )
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .failed,
                reasonCode: .runCancelled,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                privacySummary: privacy
            )
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .cancelled,
                reasonCode: .runCancelled,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                privacySummary: privacy
            )
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .cancelled,
                reasonCode: .runCancelled,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                cleanupPassed: true,
                privacySummary:
                    try P8FSignedSmokePrivacySummary(
                        artifactCount: 1,
                        forbiddenValueCount: 1
                    )
            )
        }
        XCTAssertNoThrow(
            try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .cancelled,
                reasonCode: .runCancelled,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                cleanupPassed: true,
                privacySummary: privacy
            )
        )
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeTerminalReceipt(
                scenario: .run,
                status: .cancelled,
                reasonCode: .runCancelled,
                startedAt: self.fixedDate(0),
                completedAt: self.fixedDate(1),
                applicationIdentity: identity,
                semanticOutcomeState: .published,
                generationIdentifierSHA256:
                    self.generationSHA256,
                cleanupPassed: true,
                privacySummary: privacy
            )
        }
        XCTAssertNoThrow(
            try P8FSignedSmokeEventDraft(
                event: .generation,
                component: .semanticIndex,
                status: .cancelled,
                reasonCode: .cancelledBeforePublication,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .cancellation
                    ),
                timestamp: fixedDate(1)
            )
        )
    }

    func testCancelledTerminalRejectsRehashedPublishedGenerationEvidence()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .generation,
                parentSpanID: started.spanID,
                component: .semanticIndex,
                status: .success,
                reasonCode: .generationPublished,
                scenario: .successfulPublication,
                timestamp: fixedDate(1)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: started.spanID,
                component: .runner,
                status: .started,
                reasonCode: .runCancellationObserved,
                scenario: .run,
                timestamp: fixedDate(2)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .cleanup,
                parentSpanID: started.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup,
                timestamp: fixedDate(3)
            )
        )
        let cancelled = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .cancelled,
            reasonCode: .runCancelled,
            startedAt: fixedDate(0),
            completedAt: fixedDate(4),
            applicationIdentity:
                try P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                ),
            cleanupPassed: true,
            privacySummary:
                try P8FSignedSmokePrivacySummary(
                    artifactCount: 4
                )
        )

        assertThrows(.terminalReceiptInvalid) {
            _ = try writer.commitTerminalReceipt(
                cancelled,
                finalEventDraft: self.makeEventDraft(
                    event: .run,
                    parentSpanID: started.spanID,
                    component: .runner,
                    status: .cancelled,
                    reasonCode: .runCancelled,
                    scenario: .run,
                    timestamp: self.fixedDate(4)
                )
            )
        }
        XCTAssertNil(writer.terminalReceipt)
        XCTAssertFalse(fileManager.fileExists(
            atPath: terminalReceiptURL(in: root).path
        ))
    }

    func testHydrationRejectsDegradedAndSkippedTerminalStatuses()
        throws
    {
        let statuses: [P8FSignedSmokeStatus] = [
            .degraded,
            .skipped,
        ]
        let roots = try statuses.map { _ in
            try makeIsolatedRoot()
        }
        defer {
            for root in roots {
                try? fileManager.removeItem(at: root)
            }
        }

        for (status, root) in zip(statuses, roots) {
            _ = try writeCancelledTerminal(in: root)
            let terminalURL = receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .terminalReceiptFileName
                )
            let original = try String(
                decoding: Data(contentsOf: terminalURL),
                as: UTF8.self
            )
            let tampered = original.replacingOccurrences(
                of: #""status":"cancelled""#,
                with: #""status":"\#(status.rawValue)""#
            )
            XCTAssertNotEqual(original, tampered)
            try Data(tampered.utf8).write(
                to: terminalURL,
                options: .atomic
            )
            try setPermissions(0o600, on: terminalURL)

            assertThrows(.terminalReceiptInvalid) {
                _ = try P8FSignedSmokeReceiptWriter(
                    isolatedRoot: root
                )
            }
        }

        for field in [
            (#""cleanup_passed":true"#, #""cleanup_passed":false"#),
            (#""forbidden_value_count":0"#, #""forbidden_value_count":1"#),
        ] {
            let root = try makeIsolatedRoot()
            defer { try? fileManager.removeItem(at: root) }
            _ = try writeCancelledTerminal(in: root)
            let terminalURL = receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .terminalReceiptFileName
                )
            let original = try String(
                decoding: Data(contentsOf: terminalURL),
                as: UTF8.self
            )
            let tampered = original.replacingOccurrences(
                of: field.0,
                with: field.1
            )
            XCTAssertNotEqual(original, tampered)
            try Data(tampered.utf8).write(
                to: terminalURL,
                options: .atomic
            )
            try setPermissions(0o600, on: terminalURL)
            assertThrows(.terminalReceiptInvalid) {
                _ = try P8FSignedSmokeReceiptWriter(
                    isolatedRoot: root
                )
            }
        }
    }

    func testCancelledTerminalHashBindingDetectsEventTamper()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        _ = try writeCancelledTerminal(in: root)

        let eventURL = eventsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .eventFileName(sequence: 4)
            )
        let original = try String(
            decoding: Data(contentsOf: eventURL),
            as: UTF8.self
        )
        let tampered = original.replacingOccurrences(
            of: #""status":"cancelled""#,
            with: #""status":"failed""#
        )
        XCTAssertNotEqual(original, tampered)
        try Data(tampered.utf8).write(
            to: eventURL,
            options: .atomic
        )
        try setPermissions(0o600, on: eventURL)

        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testTerminalHydrationRejectsCanonicalStatusMismatchWithCurrentHashes()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let cancelled = try writeCancelledTerminal(in: root)
        let failed = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .failed,
            reasonCode: .runFailed,
            startedAt: cancelled.startedAt,
            completedAt: cancelled.completedAt,
            applicationIdentity: cancelled.applicationIdentity,
            cleanupPassed: true,
            privacySummary: cancelled.privacySummary
        )
        try rewriteTerminalEnvelope(
            in: root,
            receipt: failed
        )

        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testTerminalHydrationRejectsFullyRehashedReasonAndOrderContradictions()
        throws
    {
        let reasonRoot = try makeIsolatedRoot()
        let orderRoot = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: reasonRoot)
            try? fileManager.removeItem(at: orderRoot)
        }

        _ = try writeFailedTerminal(in: reasonRoot)
        try rewriteCanonicalEventChain(in: reasonRoot) { events in
            XCTAssertEqual(events.count, 1)
            return [
                self.copyEvent(
                    events[0],
                    semanticFieldsFrom: events[0],
                    reasonCode: .privacyFailed
                ),
            ]
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: reasonRoot
            )
        }

        _ = try writeCancelledTerminal(in: orderRoot)
        try rewriteCanonicalEventChain(in: orderRoot) { events in
            XCTAssertEqual(events.count, 4)
            return [
                events[0],
                events[1],
                self.copyEvent(
                    events[2],
                    semanticFieldsFrom: events[3]
                ),
                self.copyEvent(
                    events[3],
                    semanticFieldsFrom: events[2]
                ),
            ]
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: orderRoot
            )
        }
    }

    func testSuccessfulTerminalHydrationRejectsFullyRehashedCrossLinkMismatchAndOmission()
        throws
    {
        for mutation in [
            "restart-generation-mismatch",
            "restart-allowlist-omission",
            "probe-fixture-mismatch",
            "legacy-scenario-omission",
            "probe-generation-collapse",
            "hydration-artifact-shape-mismatch",
        ] {
            let root = try makeIsolatedRoot()
            defer { try? fileManager.removeItem(at: root) }
            _ = try writeSuccessfulTerminal(in: root)
            try rewriteCanonicalEventChain(in: root) { events in
                var rewritten = events
                let targetScenario:
                    P8FSignedSmokeScenario = switch mutation {
                    case "restart-generation-mismatch",
                         "restart-allowlist-omission":
                        .restartHydration
                    case "legacy-scenario-omission":
                        .legacyHydration
                    default:
                        .malformedHydration
                    }
                guard let targetIndex = rewritten.firstIndex(where: {
                    $0.metadata.scenario == targetScenario
                }) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let target = rewritten[targetIndex]
                var scenario = target.metadata.scenario
                var reasonCode = target.reasonCode
                var fixtureHash =
                    target.metadata.fixtureManifestSHA256
                var allowlistHash =
                    target.metadata.sourceAllowlistSHA256
                var generationHash =
                    target.metadata.generationIdentifierSHA256
                var artifactHash = target.metadata.artifactSHA256
                var counters = target.metadata.counters
                switch mutation {
                case "restart-generation-mismatch":
                    generationHash = String(
                        repeating: "8",
                        count: 64
                    )
                case "restart-allowlist-omission":
                    allowlistHash = nil
                case "probe-fixture-mismatch":
                    fixtureHash = String(
                        repeating: "9",
                        count: 64
                    )
                case "legacy-scenario-omission":
                    scenario = .staleHydration
                    reasonCode = .staleIdentityRejected
                    counters = nil
                case "probe-generation-collapse":
                    generationHash = rewritten.first(where: {
                        $0.metadata.scenario == .staleHydration
                    })?.metadata.generationIdentifierSHA256
                default:
                    artifactHash = String(
                        repeating: "a",
                        count: 64
                    )
                }
                let metadata = try P8FSignedSmokeEventMetadata(
                    scenario: scenario,
                    fixtureManifestSHA256: fixtureHash,
                    sourceAllowlistSHA256: allowlistHash,
                    generationIdentifierSHA256: generationHash,
                    artifactSHA256: artifactHash,
                    counters: counters
                )
                rewritten[targetIndex] = self.copyEvent(
                    target,
                    semanticFieldsFrom: target,
                    reasonCode: reasonCode,
                    metadata: metadata
                )
                return rewritten
            }

            assertThrows(.terminalReceiptInvalid) {
                _ = try P8FSignedSmokeReceiptWriter(
                    isolatedRoot: root
                )
            }
        }
    }

    func testSuccessfulTerminalSearchRejectsFullyRehashedMatrixContradictions()
        throws
    {
        for mutation in [
            "semantic-scenario-omission",
            "lexical-mode-mismatch",
            "normal-artifact-omission",
            "normal-zero-result",
            "narrowed-generation-mismatch",
            "narrowed-not-narrower",
            "excluded-positive-result",
            "excluded-artifact-injection",
        ] {
            let root = try makeIsolatedRoot()
            defer { try? fileManager.removeItem(at: root) }
            _ = try writeSuccessfulTerminal(in: root)
            try rewriteCanonicalEventChain(in: root) { events in
                var rewritten = events
                let targetScenario:
                    P8FSignedSmokeScenario = switch mutation {
                    case "semantic-scenario-omission":
                        .semanticSearch
                    case "narrowed-generation-mismatch",
                         "narrowed-not-narrower":
                        .searchNarrowing
                    case "excluded-positive-result",
                         "excluded-artifact-injection":
                        .excludedSourceSearch
                    default:
                        .lexicalSearch
                    }
                guard let targetIndex = rewritten.firstIndex(where: {
                    $0.metadata.scenario == targetScenario
                }) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let target = rewritten[targetIndex]
                var scenario = target.metadata.scenario
                var searchMode = target.metadata.searchMode
                var generationHash =
                    target.metadata.generationIdentifierSHA256
                var artifactHash = target.metadata.artifactSHA256
                var counters = target.metadata.counters
                switch mutation {
                case "semantic-scenario-omission":
                    scenario = .lexicalSearch
                    searchMode = .lexical
                case "lexical-mode-mismatch":
                    searchMode = .semantic
                case "normal-artifact-omission":
                    artifactHash = nil
                case "normal-zero-result":
                    counters = try P8FSignedSmokeCounters(
                        resultCount: 0,
                        leakageCanaryHits: 0
                    )
                case "narrowed-generation-mismatch":
                    generationHash = String(
                        repeating: "8",
                        count: 64
                    )
                case "narrowed-not-narrower":
                    let lexicalResultCount = try XCTUnwrap(
                        rewritten.first(where: {
                            $0.metadata.scenario == .lexicalSearch
                        })?.metadata.counters?.resultCount
                    )
                    counters = try P8FSignedSmokeCounters(
                        resultCount: lexicalResultCount,
                        leakageCanaryHits: 0
                    )
                case "excluded-positive-result":
                    counters = try P8FSignedSmokeCounters(
                        resultCount: 1,
                        leakageCanaryHits: 0
                    )
                default:
                    artifactHash = String(
                        repeating: "a",
                        count: 64
                    )
                }
                let metadata = try P8FSignedSmokeEventMetadata(
                    scenario: scenario,
                    searchMode: searchMode,
                    fixtureManifestSHA256:
                        target.metadata.fixtureManifestSHA256,
                    generationIdentifierSHA256: generationHash,
                    artifactSHA256: artifactHash,
                    counters: counters
                )
                rewritten[targetIndex] = self.copyEvent(
                    target,
                    semanticFieldsFrom: target,
                    metadata: metadata
                )
                return rewritten
            }

            assertThrows(.terminalReceiptInvalid) {
                _ = try P8FSignedSmokeReceiptWriter(
                    isolatedRoot: root
                )
            }
        }
    }

    func testCancelledVocabularyRejectsLegacyEventAndTerminalSchemas()
        throws
    {
        let eventRoot = try makeIsolatedRoot()
        let terminalRoot = try makeIsolatedRoot()
        defer {
            try? fileManager.removeItem(at: eventRoot)
            try? fileManager.removeItem(at: terminalRoot)
        }
        _ = try writeCancelledTerminal(in: eventRoot)
        _ = try writeCancelledTerminal(in: terminalRoot)

        let eventURL = eventsDirectory(in: eventRoot)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .eventFileName(sequence: 4)
            )
        let eventJSON = try String(
            decoding: Data(contentsOf: eventURL),
            as: UTF8.self
        )
        let legacyEventJSON = eventJSON.replacingOccurrences(
            of: "agent-loki.p8f.signed-smoke-event.v2",
            with: "agent-loki.p8f.signed-smoke-event.v1"
        )
        XCTAssertNotEqual(eventJSON, legacyEventJSON)
        try Data(legacyEventJSON.utf8).write(
            to: eventURL,
            options: .atomic
        )
        try setPermissions(0o600, on: eventURL)
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: eventRoot
            )
        }

        let terminalURL = receiptsDirectory(in: terminalRoot)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .terminalReceiptFileName
            )
        let terminalJSON = try String(
            decoding: Data(contentsOf: terminalURL),
            as: UTF8.self
        )
        let legacyTerminalJSON =
            terminalJSON.replacingOccurrences(
                of:
                    "agent-loki.p8f.signed-smoke-terminal-receipt.v4",
                with:
                    "agent-loki.p8f.signed-smoke-terminal-receipt.v2"
            )
        XCTAssertNotEqual(terminalJSON, legacyTerminalJSON)
        try Data(legacyTerminalJSON.utf8).write(
            to: terminalURL,
            options: .atomic
        )
        try setPermissions(0o600, on: terminalURL)
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: terminalRoot
            )
        }
    }

    func testHostileCanariesAreRejectedAndNeverPersisted() throws {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let canary = [
            "", "Users", "private", "PRIVATE_CANARY_RAW_PROMPT_RESPONSE",
        ].joined(separator: "/")
        let store =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        let hostile = P8SemanticSourceAuthorityEvent(
            occurredAt: fixedDate(0),
            name: .scopeAuthorized,
            sourceAuthorityVersion:
                SemanticIndexBuildScope.currentContractVersion,
            sourceAllowlistHash: allowlistSHA256,
            authorizationReceiptIdentifier: canary,
            buildInitiation: .signedSmokeRunner,
            sourceKinds: [.brief],
            status: "authorized",
            reasonCode:
                "semantic_rebuild_source_scope_authorized"
        )

        assertThrows(.unsafeSourceAuthorityReceipt) {
            try store.save([hostile])
        }
        assertThrows(.invalidTraceIdentifier) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root,
                traceID: "trace_\(canary)"
            )
        }

        for data in try persistedRegularFileData(in: root) {
            XCTAssertFalse(
                data.range(of: Data(canary.utf8)) != nil,
                "Hostile private-path/raw-content canary persisted"
            )
        }
    }

    func testTerminalReceiptRejectsUnsafeHashAndInconsistentTypedFields()
        throws
    {
        let identity =
            try P8FSignedSmokeReceiptApplicationIdentity(
                executableSHA256: executableSHA256,
                cdHash: cdHash
            )
        let privacy =
            try P8FSignedSmokePrivacySummary(artifactCount: 1)

        assertThrows(.terminalReceiptInvalid) {
            _ = try self.makeTerminalReceipt(
                identity: identity,
                fixtureManifestSHA256:
                    "/private/raw-fixture-path",
                model: .qwenEmbedding,
                modelDigestSHA256: self.modelSHA256,
                modelAssessmentStatus: .success,
                searchMode: .hybrid,
                searchPassed: true,
                privacySummary: privacy
            )
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try self.makeTerminalReceipt(
                identity: identity,
                fixtureManifestSHA256:
                    self.fixtureSHA256,
                model: nil,
                modelDigestSHA256: self.modelSHA256,
                modelAssessmentStatus: .success,
                searchMode: .hybrid,
                searchPassed: true,
                privacySummary: privacy
            )
        }
        assertThrows(.terminalReceiptInvalid) {
            _ = try self.makeTerminalReceipt(
                identity: identity,
                fixtureManifestSHA256:
                    self.fixtureSHA256,
                model: .qwenEmbedding,
                modelDigestSHA256: self.modelSHA256,
                modelAssessmentStatus: .success,
                searchMode: nil,
                searchPassed: true,
                privacySummary: privacy
            )
        }
    }

    func testPositiveSchemasRejectEveryUnknownArtifactAndField()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let selectionStore =
            try P8FSignedSmokeSemanticBuildSourceSelectionStore(
                isolatedRoot: root
            )
        try selectionStore.save([.brief])
        let authorityStore =
            try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
                isolatedRoot: root
            )
        try authorityStore.save([
            makeAuthorityEvent(
                name: .scopeAuthorized,
                status: "authorized",
                reasonCode:
                    "semantic_rebuild_source_scope_authorized"
            ),
        ])

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let first = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: first.spanID,
            startingAt: 1
        )
        _ = try writer
            .writeCanonicalDiagnosticManifestReceipt()
        _ = try writer.writeTerminalReceipt(
            makeSuccessfulTerminalReceipt()
        )

        let receiptDirectory = receiptsDirectory(in: root)
        let artifacts:
            [(P8FSignedSmokeReceiptArtifactKind, URL)] = [
                (
                    .buildSourceSelection,
                    receiptDirectory.appendingPathComponent(
                        P8FSignedSmokeReceiptLayout
                            .buildSourceSelectionFileName
                    )
                ),
                (
                    .sourceAuthorityReceipts,
                    receiptDirectory.appendingPathComponent(
                        P8FSignedSmokeReceiptLayout
                            .sourceAuthorityReceiptsFileName
                    )
                ),
                (
                    .event,
                    eventsDirectory(in: root)
                        .appendingPathComponent(
                            P8FSignedSmokeReceiptLayout
                                .eventFileName(sequence: 1)
                        )
                ),
                (
                    .diagnosticManifest,
                    receiptDirectory.appendingPathComponent(
                        P8FSignedSmokeReceiptLayout
                            .diagnosticManifestFileName
                    )
                ),
                (
                    .terminalReceipt,
                    receiptDirectory.appendingPathComponent(
                        P8FSignedSmokeReceiptLayout
                            .terminalReceiptFileName
                    )
                ),
            ]
        for (kind, url) in artifacts {
            let hostile = try encodedObject(
                byAdding: "raw_query",
                value: "private query payload",
                to: Data(contentsOf: url)
            )
            assertThrows(.artifactSchemaInvalid) {
                try P8FSignedSmokeReceiptArtifactValidator
                    .validateEncodedArtifact(
                        hostile,
                        as: kind
                    )
            }
        }

        let eventURL = artifacts[2].1
        for (key, value) in [
            ("query", "private query" as Any),
            ("excerpt", "private source excerpt" as Any),
            ("embedding", [0.1, 0.2] as Any),
        ] {
            let hostile = try encodedObject(
                byAdding: key,
                value: value,
                inside: "metadata",
                to: Data(contentsOf: eventURL)
            )
            assertThrows(.artifactSchemaInvalid) {
                try P8FSignedSmokeReceiptArtifactValidator
                    .validateEncodedArtifact(
                        hostile,
                        as: .event
                    )
            }
        }

        let unknown = receiptDirectory.appendingPathComponent(
            "raw-diagnostic-log.json"
        )
        try Data(#"{"query":"private"}"#.utf8).write(
            to: unknown
        )
        try setPermissions(0o600, on: unknown)
        assertThrows(.unknownReceiptArtifact) {
            try P8FSignedSmokeReceiptArtifactValidator
                .validateReceiptDirectory(isolatedRoot: root)
        }
        assertThrows(.unknownReceiptArtifact) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
    }

    func testCanonicalDiagnosticManifestReconcilesStoredEvents()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }

        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let rootEvent = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        let providerTraceSHA256 =
            String(repeating: "2", count: 64)
        let providerRequestSHA256 =
            String(repeating: "3", count: 64)
        let providerEvent = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .network,
                parentSpanID: rootEvent.spanID,
                component: .modelProvider,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 2_000,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .qwenEmbedding,
                        model: .qwenEmbedding,
                        endpointClassification:
                            .ollamaModelIPv4Loopback,
                        processIdentifier: 4242,
                        executableSHA256: executableSHA256,
                        providerRequestTraceSHA256:
                            providerTraceSHA256,
                        providerRequestIdentifierSHA256:
                            providerRequestSHA256,
                        providerKind: .embedding,
                        providerOperationKind: .embedding,
                        providerOutcome: .succeeded,
                        providerIntervalStartedAt:
                            fixedDate(1),
                        providerIntervalEndedAt:
                            fixedDate(3),
                        providerIntervalDurationMilliseconds:
                            2_000
                    ),
                timestamp: fixedDate(3)
            )
        )
        _ = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .network,
                parentSpanID: providerEvent.spanID,
                component: .modelProvider,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 4_000,
                metadata:
                    try P8FSignedSmokeEventMetadata(
                        scenario: .qwenEmbedding,
                        model: .qwenEmbedding,
                        endpointClassification:
                            .ollamaModelIPv4Loopback,
                        processIdentifier: 4242,
                        executableSHA256: executableSHA256,
                        providerRequestTraceSHA256:
                            providerTraceSHA256,
                        providerRequestIdentifierSHA256:
                            providerRequestSHA256,
                        providerKind: .embedding,
                        providerOperationKind: .embedding,
                        providerOutcome: .succeeded,
                        providerIntervalStartedAt:
                            fixedDate(1),
                        providerIntervalEndedAt:
                            fixedDate(3),
                        providerIntervalDurationMilliseconds:
                            2_000,
                        externalWatcherIntervalStartedAt:
                            fixedDate(0),
                        externalWatcherIntervalEndedAt:
                            fixedDate(4),
                        externalWatcherIntervalDurationMilliseconds:
                            4_000,
                        transportObservationEvidenceSource:
                            .externalContinuousSocketWatcher,
                        transportObservationClassification:
                            .modelTransport,
                        transportObservationResult:
                            .loopbackOnly,
                        observedEndpointClassification:
                            .ollamaModelIPv4Loopback
                    ),
                timestamp: fixedDate(4)
            )
        )
        let manifest = try writer
            .writeCanonicalDiagnosticManifestReceipt()
        XCTAssertEqual(
            manifest,
            try P8FSignedSmokeDiagnosticManifestReceipt
                .canonical(
                    traceID: writer.traceID,
                    events: writer.events
                )
        )
        XCTAssertEqual(
            manifest.artifacts.map(\.classification),
            P8FSignedSmokeDiagnosticArtifactClassification
                .allCases
        )
        XCTAssertEqual(
            manifest.artifacts.map(
                \.approvedFieldsSchemaSHA256
            ),
            manifest.artifacts.map {
                $0.classification
                    .approvedFieldsSchemaSHA256
            }
        )
        XCTAssertEqual(
            manifest.artifacts.map(\.recordCount),
            [3, 2, 1]
        )
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }

        let data = try Data(
            contentsOf: receiptsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .diagnosticManifestFileName
                )
        )
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("private query"))
        XCTAssertFalse(encoded.contains("raw log"))
        XCTAssertFalse(encoded.contains("raw_query"))
        XCTAssertFalse(encoded.contains("excerpt"))
        XCTAssertFalse(encoded.contains("embedding"))
        XCTAssertTrue(
            encoded.contains(
                #""raw_payload_embedded":false"#
            )
        )

        assertThrows(.diagnosticManifestInvalid) {
            _ = try P8FSignedSmokeDiagnosticArtifactReceipt(
                artifactIdentifierSHA256:
                    String(repeating: "6", count: 64),
                classification: .applicationDiagnostics,
                artifactSHA256:
                    String(repeating: "7", count: 64),
                approvedFieldsSchemaSHA256:
                    String(repeating: "8", count: 64),
                capturedAt: self.fixedDate(1),
                byteCount: 10,
                recordCount: 1,
                rawPayloadEmbedded: true
            )
        }
        assertThrows(.diagnosticManifestInvalid) {
            _ = try P8FSignedSmokeDiagnosticArtifactReceipt(
                artifactIdentifierSHA256:
                    String(repeating: "6", count: 64),
                classification: .applicationDiagnostics,
                artifactSHA256:
                    String(repeating: "7", count: 64),
                approvedFieldsSchemaSHA256:
                    String(repeating: "8", count: 64),
                capturedAt: self.fixedDate(1),
                byteCount: 10,
                recordCount: 1
            )
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        var tamperedArtifacts = try XCTUnwrap(
            object["artifacts"] as? [[String: Any]]
        )
        tamperedArtifacts[1]["artifact_sha256"] =
            String(repeating: "0", count: 64)
        object["artifacts"] = tamperedArtifacts
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let manifestURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .diagnosticManifestFileName
            )
        try tampered.write(to: manifestURL, options: .atomic)
        try setPermissions(0o600, on: manifestURL)
        assertThrows(.terminalReceiptInvalid) {
            _ = try P8FSignedSmokeReceiptWriter(
                isolatedRoot: root
            )
        }
        assertThrows(.diagnosticManifestInvalid) {
            try P8FSignedSmokeReceiptArtifactValidator
                .validateReceiptDirectory(isolatedRoot: root)
        }
    }

    func testTransportCorrelationMetadataRoundTripsAndFailsClosed()
        throws
    {
        let root = try makeIsolatedRoot()
        defer { try? fileManager.removeItem(at: root) }
        let intervalStart = fixedDate(0)
        let intervalEnd = fixedDate(2)
        let providerTraceSHA256 =
            String(repeating: "2", count: 64)
        let providerRequestSHA256 =
            String(repeating: "3", count: 64)

        let providerMetadata =
            try P8FSignedSmokeEventMetadata(
            scenario: .qwenEmbedding,
            model: .qwenEmbedding,
            endpointClassification:
                .ollamaModelIPv4Loopback,
            processIdentifier: 4242,
            executableSHA256: executableSHA256,
            providerRequestTraceSHA256:
                providerTraceSHA256,
            providerRequestIdentifierSHA256:
                providerRequestSHA256,
            providerKind: .embedding,
            providerOperationKind: .embedding,
            providerOutcome: .succeeded,
            providerIntervalStartedAt: intervalStart,
            providerIntervalEndedAt: intervalEnd,
            providerIntervalDurationMilliseconds: 2_000
        )
        let externallyObservedMetadata =
            try P8FSignedSmokeEventMetadata(
            scenario: .qwenEmbedding,
            model: .qwenEmbedding,
            endpointClassification:
                .ollamaModelIPv4Loopback,
            processIdentifier: 4242,
            executableSHA256: executableSHA256,
            providerRequestTraceSHA256:
                providerTraceSHA256,
            providerRequestIdentifierSHA256:
                providerRequestSHA256,
            providerKind: .embedding,
            providerOperationKind: .embedding,
            providerOutcome: .succeeded,
            providerIntervalStartedAt: intervalStart,
            providerIntervalEndedAt: intervalEnd,
            providerIntervalDurationMilliseconds: 2_000,
            externalWatcherIntervalStartedAt: fixedDate(-1),
            externalWatcherIntervalEndedAt: fixedDate(3),
            externalWatcherIntervalDurationMilliseconds:
                4_000,
            transportObservationEvidenceSource:
                .externalContinuousSocketWatcher,
            transportObservationClassification:
                .modelTransport,
            transportObservationResult: .loopbackOnly,
            observedEndpointClassification:
                .ollamaModelIPv4Loopback
        )
        var writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let providerEvent = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .network,
                component: .modelProvider,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 2_000,
                metadata: providerMetadata,
                timestamp: intervalEnd
            )
        )
        _ = try writer.append(
            P8FSignedSmokeEventDraft(
                event: .network,
                parentSpanID: providerEvent.spanID,
                component: .modelProvider,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 4_000,
                metadata: externallyObservedMetadata,
                timestamp: fixedDate(3)
            )
        )
        writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        XCTAssertEqual(
            writer.events.first?.metadata,
            providerMetadata
        )
        XCTAssertNil(
            writer.events.first?
                .metadata.transportObservationResult
        )
        XCTAssertEqual(
            writer.events.last?.metadata,
            externallyObservedMetadata
        )
        let externalEventData = try Data(
            contentsOf: eventsDirectory(in: root)
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .eventFileName(sequence: 2)
                )
        )
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                externalEventData,
                as: .event
            )

        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                processIdentifier: 4242
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                model: .qwenEmbedding,
                endpointClassification:
                    .ollamaModelIPv4Loopback
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                endpointClassification:
                    .ollamaModelIPv4Loopback,
                processIdentifier: 4242,
                executableSHA256: self.executableSHA256,
                providerRequestTraceSHA256:
                    providerTraceSHA256,
                providerRequestIdentifierSHA256:
                    providerRequestSHA256,
                providerIntervalStartedAt: intervalStart,
                providerIntervalEndedAt: intervalStart,
                providerIntervalDurationMilliseconds: 0
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                endpointClassification:
                    .ollamaIPv4Loopback,
                processIdentifier: 4242,
                executableSHA256: self.executableSHA256,
                providerRequestTraceSHA256:
                    providerTraceSHA256,
                providerRequestIdentifierSHA256:
                    providerRequestSHA256,
                providerIntervalStartedAt: intervalStart,
                providerIntervalEndedAt: intervalEnd,
                providerIntervalDurationMilliseconds: 2_000
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                endpointClassification:
                    .ollamaModelIPv4Loopback,
                processIdentifier: 4242,
                executableSHA256: self.executableSHA256,
                providerRequestTraceSHA256:
                    providerTraceSHA256,
                providerRequestIdentifierSHA256:
                    providerRequestSHA256,
                providerIntervalStartedAt: intervalStart,
                providerIntervalEndedAt: intervalEnd,
                providerIntervalDurationMilliseconds: 2_000,
                externalWatcherIntervalStartedAt:
                    self.fixedDate(-1),
                externalWatcherIntervalEndedAt:
                    self.fixedDate(3),
                externalWatcherIntervalDurationMilliseconds:
                    0,
                transportObservationEvidenceSource:
                    .externalContinuousSocketWatcher,
                transportObservationClassification:
                    .modelTransport,
                transportObservationResult: .loopbackOnly,
                observedEndpointClassification:
                    .ollamaModelIPv4Loopback
            )
        }
        let uncorrelatedModelMetadata =
            try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                model: .qwenEmbedding
            )
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventDraft(
                event: .network,
                component: .networkGuard,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                metadata: uncorrelatedModelMetadata,
                timestamp: self.fixedDate(2)
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventDraft(
                event: .modelCapability,
                component: .modelProvider,
                status: .success,
                reasonCode: .modelCapabilityPassed,
                durationMilliseconds: 2_000,
                metadata: providerMetadata,
                timestamp: intervalEnd
            )
        }
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventDraft(
                event: .network,
                component: .networkGuard,
                status: .success,
                reasonCode: .providerTransportSucceeded,
                durationMilliseconds: 2_000,
                metadata: providerMetadata,
                timestamp: self.fixedDate(3)
            )
        }
        XCTAssertNoThrow(
            try P8FSignedSmokeEventDraft(
                event: .modelCapability,
                component: .modelProvider,
                status: .success,
                reasonCode: .visionTransportConfirmed,
                metadata: uncorrelatedModelMetadata,
                timestamp: self.fixedDate(2)
            )
        )
        assertThrows(.eventMetadataInvalid) {
            _ = try P8FSignedSmokeEventMetadata(
                scenario: .qwenEmbedding,
                model: .qwenEmbedding,
                endpointClassification:
                    .ollamaModelIPv4Loopback,
                processIdentifier: 4242,
                executableSHA256: self.executableSHA256,
                providerRequestTraceSHA256:
                    providerTraceSHA256,
                providerRequestIdentifierSHA256:
                    providerRequestSHA256,
                providerIntervalStartedAt:
                    Date(
                        timeIntervalSinceReferenceDate:
                            -Double.greatestFiniteMagnitude
                                / 2
                    ),
                providerIntervalEndedAt:
                    Date(
                        timeIntervalSinceReferenceDate:
                            Double.greatestFiniteMagnitude
                                / 2
                    ),
                providerIntervalDurationMilliseconds: 1
            )
        }
    }

    private func makeSuccessfulTerminalReceipt()
        throws -> P8FSignedSmokeTerminalReceipt
    {
        try makeTerminalReceipt(
            identity:
                P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                ),
            fixtureManifestSHA256: fixtureSHA256,
            model: .qwenEmbedding,
            modelDigestSHA256: modelSHA256,
            modelAssessmentStatus: .success,
            searchMode: .hybrid,
            searchPassed: true,
            privacySummary:
                P8FSignedSmokePrivacySummary(
                    artifactCount: 4
                )
        )
    }

    private func appendSuccessfulTerminalEvents(
        to writer: P8FSignedSmokeReceiptWriter,
        parentSpanID: String,
        startingAt offset: TimeInterval,
        appendFinalRun: Bool = true,
        bindSourceAuthorityArtifact: Bool = true
    ) throws -> (
        cleanup: P8FSignedSmokeEvent,
        run: P8FSignedSmokeEvent?
    ) {
        let sourceCounters = try P8FSignedSmokeCounters(
            adapterInvocations: 3,
            recordsRead: 4,
            recordsAccepted: 4,
            recordsRejected: 0,
            preparedRecords: 4,
            chunks: 4,
            embeddingRequests: 4,
            embeddingsAccepted: 4,
            indexWrites: 4,
            resultCount: 2,
            leakageCanaryHits: 0
        )
        func append(
            event: P8FSignedSmokeEventName,
            component: P8FSignedSmokeComponent,
            status: P8FSignedSmokeStatus,
            reasonCode: P8FSignedSmokeReasonCode,
            metadata: P8FSignedSmokeEventMetadata,
            at eventOffset: TimeInterval,
            durationMilliseconds: Int = 1
        ) throws -> P8FSignedSmokeEvent {
            try writer.append(
                P8FSignedSmokeEventDraft(
                    event: event,
                    parentSpanID: parentSpanID,
                    component: component,
                    status: status,
                    reasonCode: reasonCode,
                    durationMilliseconds: durationMilliseconds,
                    metadata: metadata,
                    timestamp: fixedDate(eventOffset)
                )
            )
        }

        if !writer.events.contains(where: {
            $0.event == .storageIsolation
                && $0.status == .success
                && $0.reasonCode == .storageSelected
        }) {
            _ = try append(
                event: .storageIsolation,
                component: .persistence,
                status: .success,
                reasonCode: .storageSelected,
                metadata: try .init(
                    scenario: .storageIsolation
                ),
                at: offset
            )
        }
        _ = try append(
            event: .admission,
            component: .runner,
            status: .success,
            reasonCode: .admissionAccepted,
            metadata: try .init(scenario: .run),
            at: offset
        )
        _ = try append(
            event: .fixture,
            component: .persistence,
            status: .success,
            reasonCode: .fixtureAccepted,
            metadata: try .init(
                scenario: .sourceAuthority,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 1
        )

        for (scenario, model, digest, runtime, profile) in [
            (
                P8FSignedSmokeScenario.gemma4,
                P8FSignedSmokeApprovedModel.gemma4,
                String(repeating: "1", count: 64),
                nil as String?,
                nil as String?
            ),
            (
                .gptOSS,
                .gptOSS,
                String(repeating: "2", count: 64),
                nil,
                nil
            ),
            (
                .qwenEmbedding,
                .qwenEmbedding,
                modelSHA256,
                String(repeating: "3", count: 64),
                String(repeating: "4", count: 64)
            ),
        ] {
            _ = try append(
                event: .modelCapability,
                component: .modelProvider,
                status: .success,
                reasonCode: .modelCapabilityPassed,
                metadata: try .init(
                    scenario: scenario,
                    model: model,
                    fixtureManifestSHA256: fixtureSHA256,
                    modelDigest: digest,
                    runtimeIdentitySHA256: runtime,
                    requestProfileSHA256: profile,
                    vectorDimension:
                        model == .qwenEmbedding ? 1_024 : nil
                ),
                at: offset + 2
            )
        }
        for reason in [
            P8FSignedSmokeReasonCode.visionRouteDecisionObserved,
            .visionTransportConfirmed,
        ] {
            _ = try append(
                event: .modelCapability,
                component: .modelProvider,
                status: .success,
                reasonCode: reason,
                metadata: try .init(
                    scenario: .visibleVisionRouting,
                    fixtureManifestSHA256: fixtureSHA256
                ),
                at: offset + 3
            )
        }
        _ = try append(
            event: .modelCapability,
            component: .modelProvider,
            status: .success,
            reasonCode: .roleSeparationPassed,
            metadata: try .init(
                scenario: .roleSeparation,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 4
        )
        _ = try append(
            event: .network,
            component: .networkGuard,
            status: .success,
            reasonCode: .webResearchDisabledWithoutKey,
            metadata: try .init(
                scenario: .webResearchDisabled,
                endpointClassification: P8FSignedSmokeEndpointClassification.none,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 5
        )
        for (scenario, reason) in [
            (
                P8FSignedSmokeScenario.cancellation,
                P8FSignedSmokeReasonCode.cancelledBeforePublication
            ),
            (.revocation, .scopeRevokedBeforePublication),
            (.modelProfileDrift, .modelProfileDrift),
        ] {
            _ = try append(
                event: .generation,
                component: .semanticIndex,
                status: .cancelled,
                reasonCode: reason,
                metadata: try .init(
                    scenario: scenario,
                    fixtureManifestSHA256: fixtureSHA256,
                    generationIdentifierSHA256:
                        generationSHA256
                ),
                at: offset + 6
            )
        }
        _ = try append(
            event: .sourceAdapter,
            component: .semanticSourceAuthority,
            status: .success,
            reasonCode: .adapterContractDrift,
            metadata: try .init(
                scenario: .adapterContractDrift,
                sourceKind: .brief,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 7
        )
        _ = try append(
            event: .sourceAuthority,
            component: .semanticSourceAuthority,
            status: .success,
            reasonCode: .unknownSourceKindRejected,
            metadata: try .init(
                scenario: .unknownSourceKind,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 8
        )
        _ = try append(
            event: .generation,
            component: .semanticIndex,
            status: .success,
            reasonCode: .transactionIntegrityFailed,
            metadata: try .init(
                scenario: .transactionIntegrity,
                fixtureManifestSHA256: fixtureSHA256,
                generationIdentifierSHA256:
                    generationSHA256
            ),
            at: offset + 9
        )
        let includedSourceKinds: Set<SemanticIndexSourceKind> = [
            .brief,
            .schedule,
            .chatMessage,
        ]
        for sourceKind in SemanticIndexSourceKind.allCases {
            _ = try append(
                event: .sourceAdapter,
                component: .semanticSourceAuthority,
                status: .success,
                reasonCode: includedSourceKinds.contains(sourceKind)
                    ? .adapterInvoked
                    : .adapterSkipped,
                metadata: try .init(
                    scenario: .sourceAuthority,
                    sourceKind: sourceKind,
                    fixtureManifestSHA256: fixtureSHA256
                ),
                at: offset + 10
            )
        }
        _ = try append(
            event: .sourceAuthority,
            component: .semanticSourceAuthority,
            status: .success,
            reasonCode: .sourceScopeAuthorized,
            metadata: try .init(
                scenario: .sourceAuthority,
                artifactClassification:
                    bindSourceAuthorityArtifact
                    ? .sourceAuthorityReceipt
                    : nil,
                fixtureManifestSHA256: fixtureSHA256,
                sourceAllowlistSHA256: allowlistSHA256,
                authorizationReceiptIdentifierSHA256:
                    authorizationSHA256,
                artifactSHA256:
                    bindSourceAuthorityArtifact
                    ? executableSHA256
                    : nil,
                counters: sourceCounters
            ),
            at: offset + 2
        )
        _ = try append(
            event: .generation,
            component: .semanticIndex,
            status: .success,
            reasonCode: .generationPublished,
            metadata: try .init(
                scenario: .successfulPublication,
                fixtureManifestSHA256: fixtureSHA256,
                sourceAllowlistSHA256: allowlistSHA256,
                generationIdentifierSHA256: generationSHA256,
                authorizationReceiptIdentifierSHA256:
                    authorizationSHA256,
                counters: sourceCounters
            ),
            at: offset + 3
        )
        for (index, provider) in [
            (
                P8FSignedSmokeScenario.gemma4,
                P8FSignedSmokeApprovedModel.gemma4,
                P8FProviderRequestKind.chat,
                P8FProviderRequestOperation.modelInspect,
                "5",
                "7",
                "9"
            ),
            (
                .gptOSS,
                .gptOSS,
                .chat,
                .chatStream,
                "6",
                "8",
                "a"
            ),
            (
                .qwenEmbedding,
                .qwenEmbedding,
                .embedding,
                .embedding,
                "c",
                "d",
                "e"
            ),
        ].enumerated() {
            let providerStart = fixedDate(
                offset + 20 + Double(index * 2)
            )
            let providerEnd = providerStart.addingTimeInterval(1)
            _ = try writer.append(
                P8FSignedSmokeEventDraft(
                    event: .network,
                    parentSpanID: parentSpanID,
                    component: .modelProvider,
                    status: .success,
                    reasonCode: .providerTransportSucceeded,
                    durationMilliseconds: 1_000,
                    metadata: try .init(
                        scenario: provider.0,
                        model: provider.1,
                        endpointClassification:
                            .ollamaModelIPv4Loopback,
                        fixtureManifestSHA256: fixtureSHA256,
                        artifactSHA256:
                            String(
                                repeating: provider.4,
                                count: 64
                            ),
                        processIdentifier:
                            Int(
                                ProcessInfo.processInfo
                                    .processIdentifier
                            ),
                        executableSHA256: executableSHA256,
                        providerRequestTraceSHA256:
                            String(
                                repeating: provider.5,
                                count: 64
                            ),
                        providerRequestIdentifierSHA256:
                            String(
                                repeating: provider.6,
                                count: 64
                            ),
                        providerKind: provider.2,
                        providerOperationKind: provider.3,
                        providerOutcome: .succeeded,
                        providerIntervalStartedAt: providerStart,
                        providerIntervalEndedAt: providerEnd,
                        providerIntervalDurationMilliseconds: 1_000
                    ),
                    timestamp: providerEnd
                )
            )
        }
        for (scenario, mode, artifactCharacter) in [
            (
                P8FSignedSmokeScenario.lexicalSearch,
                SemanticSearchMode.lexical,
                "b"
            ),
            (.semanticSearch, .semantic, "c"),
            (.hybridSearch, .hybrid, "f"),
        ] {
            _ = try append(
                event: .search,
                component: .retrieval,
                status: .success,
                reasonCode: .searchPassed,
                metadata: try .init(
                    scenario: scenario,
                    searchMode: mode,
                    fixtureManifestSHA256: fixtureSHA256,
                    generationIdentifierSHA256:
                        generationSHA256,
                    artifactSHA256:
                        String(
                            repeating: artifactCharacter,
                            count: 64
                        ),
                    counters: try P8FSignedSmokeCounters(
                        resultCount: 2,
                        leakageCanaryHits: 0
                    )
                ),
                at: offset + 30
            )
        }
        _ = try append(
            event: .search,
            component: .retrieval,
            status: .success,
            reasonCode: .searchFilterNarrowed,
            metadata: try .init(
                scenario: .searchNarrowing,
                searchMode: .lexical,
                fixtureManifestSHA256: fixtureSHA256,
                generationIdentifierSHA256: generationSHA256,
                artifactSHA256:
                    String(repeating: "b", count: 64),
                counters: try P8FSignedSmokeCounters(
                    resultCount: 1,
                    leakageCanaryHits: 0
                )
            ),
            at: offset + 31
        )
        _ = try append(
            event: .search,
            component: .retrieval,
            status: .success,
            reasonCode: .excludedSourceFilterEmpty,
            metadata: try .init(
                scenario: .excludedSourceSearch,
                searchMode: .lexical,
                fixtureManifestSHA256: fixtureSHA256,
                generationIdentifierSHA256: generationSHA256,
                counters: try P8FSignedSmokeCounters(
                    resultCount: 0,
                    leakageCanaryHits: 0
                )
            ),
            at: offset + 32
        )
        let hydrationEvidence: [
            (
                P8FSignedSmokeScenario,
                P8FSignedSmokeReasonCode,
                String,
                String?,
                P8FSignedSmokeCounters?
            )
        ] = [
            (
                .restartHydration,
                .generationPublished,
                generationSHA256,
                allowlistSHA256,
                nil
            ),
            (
                .legacyHydration,
                .legacyGenerationPreserved,
                String(repeating: "5", count: 64),
                nil,
                try P8FSignedSmokeCounters(
                    recordsAccepted: 4,
                    chunks: 4,
                    indexWrites: 4
                )
            ),
            (
                .staleHydration,
                .staleIdentityRejected,
                String(repeating: "6", count: 64),
                nil,
                nil
            ),
            (
                .malformedHydration,
                .malformedIdentityRejected,
                String(repeating: "7", count: 64),
                nil,
                nil
            ),
        ]
        for (index, expected) in hydrationEvidence.enumerated() {
            _ = try append(
                event: .generation,
                component: .semanticIndex,
                status: .success,
                reasonCode: expected.1,
                metadata: try .init(
                    scenario: expected.0,
                    fixtureManifestSHA256: fixtureSHA256,
                    sourceAllowlistSHA256: expected.3,
                    generationIdentifierSHA256: expected.2,
                    counters: expected.4
                ),
                at: offset + 8 + Double(index)
            )
        }
        _ = try append(
            event: .privacy,
            component: .privacyGuard,
            status: .success,
            reasonCode: .privacyPassed,
            metadata: try .init(
                scenario: .receiptPrivacy,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 12
        )
        let cleanup = try append(
            event: .cleanup,
            component: .cleanup,
            status: .success,
            reasonCode: .cleanupPassed,
            metadata: try .init(
                scenario: .cleanup,
                fixtureManifestSHA256: fixtureSHA256
            ),
            at: offset + 13
        )
        let run: P8FSignedSmokeEvent? = if appendFinalRun {
            try writer.append(
                makeEventDraft(
                    event: .run,
                    parentSpanID: parentSpanID,
                    component: .runner,
                    status: .success,
                    reasonCode: .runCompleted,
                    scenario: .run,
                    timestamp: fixedDate(offset + 40)
                )
            )
        } else {
            nil
        }
        return (cleanup, run)
    }

    @discardableResult
    private func writeInterruptedFailedTerminal(
        in root: URL,
        at boundary: P8FSignedSmokeTerminalCommitBoundary
    ) throws -> P8FSignedSmokeTerminalReceipt {
        var interruptionObserved = false
        let testHooks = try
            P8FSignedSmokeTerminalCommitXCTestHooks.make {
                observed in
                guard observed == boundary else {
                    return
                }
                interruptionObserved = true
                throw CocoaError(.fileWriteUnknown)
            }
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root,
            testHooks: testHooks
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        let committed = try writer.commitTerminalReceipt(
            makeFailedTerminalReceipt(),
            finalEventDraft: makeEventDraft(
                event: .run,
                parentSpanID: started.spanID,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                scenario: .run,
                timestamp: fixedDate(1)
            )
        )
        XCTAssertTrue(interruptionObserved)
        return committed
    }

    private func makeFailedTerminalReceipt()
        throws -> P8FSignedSmokeTerminalReceipt
    {
        try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .failed,
            reasonCode: .runFailed,
            startedAt: fixedDate(0),
            completedAt: fixedDate(1),
            applicationIdentity:
                P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                ),
            privacySummary:
                P8FSignedSmokePrivacySummary(
                    artifactCount: 4
                )
        )
    }

    private func eventFileCount(in root: URL) throws -> Int {
        try fileManager.contentsOfDirectory(
            at: eventsDirectory(in: root),
            includingPropertiesForKeys: nil
        ).count
    }

    private func terminalReceiptURL(in root: URL) -> URL {
        receiptsDirectory(in: root).appendingPathComponent(
            P8FSignedSmokeReceiptLayout.terminalReceiptFileName
        )
    }

    private func diagnosticManifestURL(in root: URL) -> URL {
        receiptsDirectory(in: root).appendingPathComponent(
            P8FSignedSmokeReceiptLayout
                .diagnosticManifestFileName
        )
    }

    @discardableResult
    private func writeSuccessfulTerminal(
        in root: URL
    ) throws -> P8FSignedSmokeTerminalReceipt {
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let started = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try appendSuccessfulTerminalEvents(
            to: writer,
            parentSpanID: started.spanID,
            startingAt: 2
        )
        _ = try writer.writeCanonicalDiagnosticManifestReceipt()
        return try writer.writeTerminalReceipt(
            makeSuccessfulTerminalReceipt()
        )
    }

    @discardableResult
    private func writeFailedTerminal(
        in root: URL
    ) throws -> P8FSignedSmokeTerminalReceipt {
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        _ = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .failed,
                reasonCode: .runFailed,
                scenario: .run,
                timestamp: fixedDate(1)
            )
        )
        let receipt = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .failed,
            reasonCode: .runFailed,
            startedAt: fixedDate(0),
            completedAt: fixedDate(1),
            applicationIdentity:
                P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                ),
            privacySummary:
                P8FSignedSmokePrivacySummary(
                    artifactCount: 0
                )
        )
        return try writer.writeTerminalReceipt(receipt)
    }

    private func rewriteCanonicalEventChain(
        in root: URL,
        transform:
            ([P8FSignedSmokeEvent]) throws
                -> [P8FSignedSmokeEvent]
    ) throws {
        let eventURLs = try fileManager.contentsOfDirectory(
            at: eventsDirectory(in: root),
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let originalEvents = try eventURLs.map {
            try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeEvent.self,
                from: Data(contentsOf: $0)
            )
        }
        let transformedEvents = try transform(originalEvents)
        guard transformedEvents.count == eventURLs.count,
              !transformedEvents.isEmpty
        else {
            throw CocoaError(.coderInvalidValue)
        }
        var previousSHA256: String?
        for (index, pair) in zip(
            eventURLs,
            transformedEvents
        ).enumerated() {
            let source = pair.1
            let event = P8FSignedSmokeEvent(
                schemaVersion: source.schemaVersion,
                sequence: UInt64(index + 1),
                timestamp: source.timestamp,
                event: source.event,
                traceID: source.traceID,
                spanID: source.spanID,
                parentSpanID: source.parentSpanID,
                component: source.component,
                status: source.status,
                reasonCode: source.reasonCode,
                durationMilliseconds:
                    source.durationMilliseconds,
                metadata: source.metadata,
                previousEventSHA256: previousSHA256
            )
            let data = try P8FSignedSmokeJSON.encode(event)
            try data.write(to: pair.0, options: .atomic)
            try setPermissions(0o600, on: pair.0)
            previousSHA256 = P8FSignedSmokeDigest.sha256(data)
        }
        try rewriteTerminalEnvelope(in: root)
    }

    private func rewriteTerminalEnvelope(
        in root: URL,
        receipt replacementReceipt:
            P8FSignedSmokeTerminalReceipt? = nil
    ) throws {
        let terminalURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .terminalReceiptFileName
            )
        let envelope = try P8FSignedSmokeJSON.decode(
            P8TestTerminalReceiptEnvelope.self,
            from: Data(contentsOf: terminalURL)
        )
        let eventData = try fileManager.contentsOfDirectory(
            at: eventsDirectory(in: root),
            includingPropertiesForKeys: nil
        ).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.map { try Data(contentsOf: $0) }
        guard let first = eventData.first,
              let last = eventData.last
        else {
            throw CocoaError(.coderInvalidValue)
        }
        let events = try eventData.map {
            try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeEvent.self,
                from: $0
            )
        }
        let manifest =
            try P8FSignedSmokeDiagnosticManifestReceipt
                .canonical(
                    traceID: envelope.traceID,
                    events: events
                )
        let manifestData = try P8FSignedSmokeJSON.encode(
            manifest
        )
        let reboundReceipt = try (
            replacementReceipt ?? envelope.receipt
        ).bindingArtifactLedger(
            try .canonical(events: events)
        )
        let rewritten = P8TestTerminalReceiptEnvelope(
            schemaVersion: envelope.schemaVersion,
            traceID: envelope.traceID,
            receipt: reboundReceipt,
            eventCount: UInt64(eventData.count),
            firstEventSHA256:
                P8FSignedSmokeDigest.sha256(first),
            finalEventSHA256:
                P8FSignedSmokeDigest.sha256(last),
            diagnosticManifestSHA256:
                P8FSignedSmokeDigest.sha256(manifestData),
            committedFinalEvent: events.last!,
            committedDiagnosticManifest: manifest
        )
        try P8FSignedSmokeJSON.encode(rewritten).write(
            to: terminalURL,
            options: .atomic
        )
        try setPermissions(0o600, on: terminalURL)
        let manifestURL = receiptsDirectory(in: root)
            .appendingPathComponent(
                P8FSignedSmokeReceiptLayout
                    .diagnosticManifestFileName
            )
        try manifestData.write(to: manifestURL, options: .atomic)
        try setPermissions(0o600, on: manifestURL)
    }

    private func copyEvent(
        _ structuralSource: P8FSignedSmokeEvent,
        semanticFieldsFrom semanticSource:
            P8FSignedSmokeEvent,
        reasonCode: P8FSignedSmokeReasonCode? = nil,
        metadata: P8FSignedSmokeEventMetadata? = nil
    ) -> P8FSignedSmokeEvent {
        P8FSignedSmokeEvent(
            schemaVersion: structuralSource.schemaVersion,
            sequence: structuralSource.sequence,
            timestamp: semanticSource.timestamp,
            event: semanticSource.event,
            traceID: structuralSource.traceID,
            spanID: structuralSource.spanID,
            parentSpanID: structuralSource.parentSpanID,
            component: semanticSource.component,
            status: semanticSource.status,
            reasonCode: reasonCode ?? semanticSource.reasonCode,
            durationMilliseconds:
                semanticSource.durationMilliseconds,
            metadata: metadata ?? semanticSource.metadata,
            previousEventSHA256:
                structuralSource.previousEventSHA256
        )
    }

    @discardableResult
    private func writeCancelledTerminal(
        in root: URL
    ) throws -> P8FSignedSmokeTerminalReceipt {
        let writer = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: root
        )
        let rootEvent = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: nil,
                component: .runner,
                status: .started,
                reasonCode: .runStarted,
                scenario: .run,
                timestamp: fixedDate(0)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .run,
                parentSpanID: rootEvent.spanID,
                component: .runner,
                status: .started,
                reasonCode: .runCancellationObserved,
                scenario: .run,
                timestamp: fixedDate(1)
            )
        )
        _ = try writer.append(
            makeEventDraft(
                event: .cleanup,
                parentSpanID: rootEvent.spanID,
                component: .cleanup,
                status: .success,
                reasonCode: .cleanupPassed,
                scenario: .cleanup,
                timestamp: fixedDate(2)
            )
        )
        let receipt = try P8FSignedSmokeTerminalReceipt(
            scenario: .run,
            status: .cancelled,
            reasonCode: .runCancelled,
            startedAt: fixedDate(0),
            completedAt: fixedDate(3),
            applicationIdentity:
                P8FSignedSmokeReceiptApplicationIdentity(
                    executableSHA256: executableSHA256,
                    cdHash: cdHash
                ),
            cleanupPassed: true,
            privacySummary:
                P8FSignedSmokePrivacySummary(
                    artifactCount: 0
                )
        )
        return try writer.commitTerminalReceipt(
            receipt,
            finalEventDraft: makeEventDraft(
                event: .run,
                parentSpanID: rootEvent.spanID,
                component: .runner,
                status: .cancelled,
                reasonCode: .runCancelled,
                scenario: .run,
                timestamp: fixedDate(3)
            )
        )
    }

    private func makeTerminalReceipt(
        identity: P8FSignedSmokeReceiptApplicationIdentity,
        fixtureManifestSHA256: String,
        model: P8FSignedSmokeApprovedModel?,
        modelDigestSHA256: String?,
        modelAssessmentStatus: P8FSignedSmokeStatus?,
        searchMode: SemanticSearchMode?,
        searchPassed: Bool?,
        privacySummary: P8FSignedSmokePrivacySummary
    ) throws -> P8FSignedSmokeTerminalReceipt {
        try P8FSignedSmokeTerminalReceipt(
            scenario: .cleanup,
            status: .success,
            reasonCode: .runCompleted,
            startedAt: fixedDate(0),
            completedAt: fixedDate(2),
            applicationIdentity: identity,
            admissionAccepted: true,
            fixtureAccepted: true,
            fixtureManifestSHA256:
                fixtureManifestSHA256,
            sourceAllowlistSHA256: allowlistSHA256,
            authorizationReceiptIdentifierSHA256:
                authorizationSHA256,
            semanticOutcomeState: .published,
            generationIdentifierSHA256: generationSHA256,
            sourceCounters: try P8FSignedSmokeCounters(
                adapterInvocations: 3,
                recordsRead: 4,
                recordsAccepted: 4,
                recordsRejected: 0,
                preparedRecords: 4,
                chunks: 4,
                embeddingRequests: 4,
                embeddingsAccepted: 4,
                indexWrites: 4,
                resultCount: 2,
                leakageCanaryHits: 0
            ),
            model: model,
            modelDigestSHA256: modelDigestSHA256,
            modelAssessmentStatus:
                modelAssessmentStatus,
            searchMode: searchMode,
            searchPassed: searchPassed,
            hydrationPassed: true,
            cleanupPassed: true,
            privacySummary: privacySummary
        )
    }

    private func makeEventDraft(
        event: P8FSignedSmokeEventName,
        parentSpanID: String?,
        component: P8FSignedSmokeComponent,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        scenario: P8FSignedSmokeScenario,
        timestamp: Date
    ) throws -> P8FSignedSmokeEventDraft {
        try P8FSignedSmokeEventDraft(
            event: event,
            parentSpanID: parentSpanID,
            component: component,
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: 1,
            metadata:
                try P8FSignedSmokeEventMetadata(
                    scenario: scenario
                ),
            timestamp: timestamp
        )
    }

    private func makeAuthorityEvent(
        name: P8SemanticSourceAuthorityEventName,
        status: String,
        reasonCode: String
    ) -> P8SemanticSourceAuthorityEvent {
        P8SemanticSourceAuthorityEvent(
            occurredAt: fixedDate(0),
            name: name,
            sourceAuthorityVersion:
                SemanticIndexBuildScope.currentContractVersion,
            sourceAllowlistHash: allowlistSHA256,
            authorizationReceiptIdentifier:
                "semantic_scope_\(UUID().uuidString.lowercased())",
            buildInitiation: .signedSmokeRunner,
            sourceKinds: [.brief, .schedule],
            preparedRecordCount: 2,
            chunkCount: 2,
            indexedCount: 2,
            generationIdentifier: generationSHA256,
            status: status,
            reasonCode: reasonCode
        )
    }

    private func makeIsolatedRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-p8f-receipts-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        try setPermissions(0o700, on: root)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func receiptsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
    }

    private func eventsDirectory(in root: URL) -> URL {
        receiptsDirectory(in: root).appendingPathComponent(
            P8FSignedSmokeReceiptLayout.eventsDirectoryName,
            isDirectory: true
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        return (
            (attributes[.posixPermissions] as? NSNumber)?
                .intValue ?? -1
        ) & 0o777
    }

    private func setPermissions(
        _ permissions: Int,
        on url: URL
    ) throws {
        try fileManager.setAttributes(
            [
                .posixPermissions: NSNumber(value: permissions),
            ],
            ofItemAtPath: url.path
        )
    }

    private func encodedObject(
        byAdding key: String,
        value: Any,
        inside nestedKey: String? = nil,
        to data: Data
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .artifactSchemaInvalid
        }
        if let nestedKey {
            guard var nested =
                    object[nestedKey] as? [String: Any]
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .artifactSchemaInvalid
            }
            nested[key] = value
            object[nestedKey] = nested
        } else {
            object[key] = value
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
        )
    }

    private func persistedRegularFileData(
        in root: URL
    ) throws -> [Data] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var result: [Data] = []
        for case let url as URL in enumerator {
            let attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
            guard attributes[.type] as? FileAttributeType
                    == .typeRegular
            else {
                continue
            }
            result.append(try Data(contentsOf: url))
        }
        return result
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func assertThrows(
        _ expected: P8FSignedSmokeReceiptStoreFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(
            try body(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? P8FSignedSmokeReceiptStoreFailure,
                expected,
                file: file,
                line: line
            )
        }
    }
}
