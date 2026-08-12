import Foundation
import XCTest
@testable import LokiBrief

private actor AgentLokiToolFakeDataSource: AgentLokiReadOnlyToolDataSource {
    private(set) var calls: [String] = []
    private(set) var vaultBeginCount = 0
    private(set) var vaultEndCount = 0
    private let delayVaultReads: Bool
    private let recordCount: Int
    private let invalidateAttachedAuthorityDuringRead: Bool
    private var attachedAuthorityIsValid = true

    init(
        delayVaultReads: Bool = false,
        recordCount: Int = 1,
        invalidateAttachedAuthorityDuringRead: Bool = false
    ) {
        self.delayVaultReads = delayVaultReads
        self.recordCount = recordCount
        self.invalidateAttachedAuthorityDuringRead =
            invalidateAttachedAuthorityDuringRead
    }

    func authorizationDecision(
        for scope: AgentLokiAuthorizationScope
    ) -> AgentLokiAuthorizationDecision {
        switch scope {
        case let .vaultSearch(accountID, containerID):
            guard accountID == nil || accountID == "account-allowed" else {
                return .deny(.accountScopeDenied, reasonCode: "chat_tool_account_scope_denied")
            }
            guard containerID == nil || containerID == "container-allowed" else {
                return .deny(.containerScopeDenied, reasonCode: "chat_tool_container_scope_denied")
            }
            return .allow()
        case let .slackWorkspace(id), let .backfillPreview(id):
            return id == "workspace-allowed"
                ? .allow()
                : .deny(.accountScopeDenied, reasonCode: "chat_tool_workspace_scope_denied")
        case let .brief(id):
            return id == "brief-allowed" ? .allow() : .deny()
        case let .vaultItem(id):
            return id == "vault-allowed" ? .allow() : .deny()
        case let .source(id):
            return id == "source-allowed" ? .allow() : .deny()
        case let .attachedSourceVaultSearch(
            authority,
            requestedAccountID,
            requestedContainerID
        ):
            return attachedAuthorityIsValid
                && authority.sourceIdentifier == "source-a"
                && authority.accountIdentifier == "account-a"
                && authority.containerIdentifiers == ["container-a"]
                && (requestedAccountID == nil
                    || requestedAccountID == authority.accountIdentifier)
                && (requestedContainerID == nil
                    || authority.containerIdentifiers.contains(
                        requestedContainerID!
                    ))
                ? .allow(reasonCode: "chat_attached_source_scope_authorized")
                : .deny(
                    .containerScopeDenied,
                    reasonCode: "chat_attached_source_exact_scope_denied"
                )
        case let .attachedSourceVaultItem(authority, id):
            return attachedAuthorityIsValid
                && authority.sourceIdentifier == "source-a"
                && id == "vault-a"
                ? .allow(reasonCode: "chat_attached_source_item_authorized")
                : .deny(reasonCode: "chat_attached_source_item_denied")
        case let .attachedSourceHealth(authority, requestedSourceID):
            return attachedAuthorityIsValid
                && requestedSourceID == authority.sourceIdentifier
                ? .allow()
                : .deny()
        case .attachedSourceTool:
            return .deny()
        case .general:
            return .allow()
        }
    }

    func currentBriefSnapshot() -> AgentLokiToolSnapshot {
        calls.append("current_brief")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func briefSnapshot(id _: String) -> AgentLokiToolSnapshot {
        calls.append("brief_by_id")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func searchBriefHistory(
        _ query: AgentLokiBriefHistoryQuery
    ) -> AgentLokiToolSnapshot {
        calls.append("brief_history:\(query.limit)")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func beginVaultForegroundRead() {
        vaultBeginCount += 1
        calls.append("vault_begin")
    }

    func endVaultForegroundRead() {
        vaultEndCount += 1
        calls.append("vault_end")
    }

    func searchVaultText(
        _ query: AgentLokiVaultTextQuery
    ) async throws -> AgentLokiToolSnapshot {
        calls.append(
            "vault_search:\(query.limit):\(query.accountID ?? "none")"
        )
        if invalidateAttachedAuthorityDuringRead,
           query.attachedSourceAuthority != nil {
            attachedAuthorityIsValid = false
        }
        if delayVaultReads {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return fixtureSnapshot(recordCount: recordCount)
    }

    func vaultItemSnapshot(id _: String) -> AgentLokiToolSnapshot {
        calls.append("vault_item")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func vaultItemSnapshot(
        id _: String,
        attachedSourceAuthority: AgentLokiAttachedSourceRequestAuthority?
    ) -> AgentLokiToolSnapshot {
        calls.append("vault_item_scoped")
        if invalidateAttachedAuthorityDuringRead,
           attachedSourceAuthority != nil {
            attachedAuthorityIsValid = false
        }
        return fixtureSnapshot(recordCount: recordCount)
    }

    func connectedSourcesSnapshot(limit: Int) -> AgentLokiToolSnapshot {
        calls.append("sources:\(limit)")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func sourceHealthSnapshot(id _: String) -> AgentLokiToolSnapshot {
        calls.append("source_health")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func slackWorkspacesSnapshot(limit: Int) -> AgentLokiToolSnapshot {
        calls.append("slack_workspaces:\(limit)")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func selectedSlackChannelsSnapshot(
        workspaceID _: String,
        limit: Int
    ) -> AgentLokiToolSnapshot {
        calls.append("slack_channels:\(limit)")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func deliveryStatusSnapshot() -> AgentLokiToolSnapshot {
        calls.append("delivery_status")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func updateStatusSnapshot() -> AgentLokiToolSnapshot {
        calls.append("update_status")
        return fixtureSnapshot(recordCount: recordCount)
    }

    func previewBackfill(
        _ query: AgentLokiBackfillPreviewQuery
    ) -> AgentLokiToolSnapshot {
        calls.append("backfill_preview:\(query.itemLimit)")
        return AgentLokiToolSnapshot(
            records: [
                .init(
                    id: "backfill-preview",
                    fields: [
                        "would_start": .boolean(false),
                        "item_limit": .integer(query.itemLimit),
                    ]
                ),
            ],
            reasonCode: "chat_tool_backfill_preview_only"
        )
    }

    func state() -> (calls: [String], begin: Int, end: Int) {
        (calls, vaultBeginCount, vaultEndCount)
    }
}

private final class AgentLokiToolTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentLokiToolTraceEvent] = []

    func record(_ event: AgentLokiToolTraceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [AgentLokiToolTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class AgentLokiReadOnlyToolTests: XCTestCase, @unchecked Sendable {
    func testRegistryIsExactAndReadOnly() {
        XCTAssertEqual(AgentLokiReadOnlyToolRegistry.registeredNames, Set([
            "get_current_brief",
            "get_brief_by_id",
            "search_brief_history",
            "search_vault_text",
            "get_vault_item",
            "list_connected_sources",
            "get_source_health",
            "list_slack_workspaces",
            "list_selected_slack_channels",
            "get_delivery_status",
            "get_update_status",
            "preview_backfill_request",
        ]))
        XCTAssertTrue(AgentLokiReadOnlyToolRegistry.descriptors.values.allSatisfy(\.readOnly))
    }

    func testStrictJSONAndRegistryRejectUnknownSurface() throws {
        let unknownTopLevel = Data(
            #"{"name":"get_current_brief","arguments":{},"shell":"rm -rf"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            AgentLokiToolRequest.self,
            from: unknownTopLevel
        ))

        XCTAssertThrowsError(try AgentLokiReadOnlyToolRegistry.validate(.init(
            name: "run_shell",
            arguments: [:]
        ))) { error in
            XCTAssertEqual((error as? AgentLokiToolFailure)?.code, .unknownTool)
        }
        XCTAssertThrowsError(try AgentLokiReadOnlyToolRegistry.validate(.init(
            name: "get_current_brief",
            arguments: ["path": .string("/private/data")]
        ))) { error in
            XCTAssertEqual((error as? AgentLokiToolFailure)?.code, .unknownArgument)
        }
    }

    func testSchemaRejectsWrongTypesLimitsAndTimeRanges() {
        XCTAssertThrowsError(try AgentLokiReadOnlyToolRegistry.validate(.init(
            name: "search_vault_text",
            arguments: ["query": .integer(1)]
        ))) { error in
            XCTAssertEqual((error as? AgentLokiToolFailure)?.code, .invalidArgumentType)
        }
        XCTAssertThrowsError(try AgentLokiReadOnlyToolRegistry.validate(.init(
            name: "search_vault_text",
            arguments: ["query": .string("release"), "limit": .integer(21)]
        ))) { error in
            XCTAssertEqual((error as? AgentLokiToolFailure)?.code, .resultLimitExceeded)
        }
        XCTAssertThrowsError(try AgentLokiReadOnlyToolRegistry.validate(.init(
            name: "search_brief_history",
            arguments: [
                "start_at": .string("2024-01-01T00:00:00Z"),
                "end_at": .string("2026-01-02T00:00:00Z"),
            ]
        ))) { error in
            XCTAssertEqual((error as? AgentLokiToolFailure)?.code, .timeRangeExceeded)
        }
    }

    func testUnauthorizedAccountScopeStopsBeforeRead() async {
        let dataSource = AgentLokiToolFakeDataSource()
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let result = await executor.execute(.init(
            name: "search_vault_text",
            arguments: [
                "query": .string("roadmap"),
                "account_id": .string("account-denied"),
            ]
        ))

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.failure?.code, .accountScopeDenied)
        let state = await dataSource.state()
        XCTAssertTrue(state.calls.isEmpty)
        XCTAssertEqual(state.begin, 0)
        XCTAssertEqual(state.end, 0)
    }

    func testVaultReadIsBoundedAndAlwaysUsesForegroundBarrier() async {
        let dataSource = AgentLokiToolFakeDataSource(recordCount: 5)
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let result = await executor.execute(.init(
            name: "search_vault_text",
            arguments: [
                "query": .string("roadmap"),
                "account_id": .string("account-allowed"),
                "container_id": .string("container-allowed"),
                "limit": .integer(2),
            ]
        ))

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(
            Set(result.receipt.evidenceReferenceIDs),
            Set(result.evidence.map(\.reference.id))
        )
        XCTAssertTrue(result.evidence.allSatisfy {
            $0.reference.accountIdentifier == "account-allowed"
                && $0.reference.containerIdentifier == "container-allowed"
        })
        let state = await dataSource.state()
        XCTAssertEqual(state.begin, 1)
        XCTAssertEqual(state.end, 1)
        XCTAssertEqual(state.calls.first, "vault_begin")
        XCTAssertEqual(state.calls.last, "vault_end")
    }

    func testCancellationClosesAdmissionAndPreventsLateResult() async {
        let dataSource = AgentLokiToolFakeDataSource(delayVaultReads: true)
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let execution = Task {
            await executor.execute(.init(
                name: "search_vault_text",
                arguments: ["query": .string("roadmap")]
            ))
        }
        while await executor.activeRequestCount() == 0 {
            await Task.yield()
        }

        let cancelledCount = await executor.cancelAll()
        XCTAssertEqual(cancelledCount, 1)
        let cancelled = await execution.value
        XCTAssertEqual(cancelled.status, .cancelled)
        let closed = await executor.execute(.init(name: "get_current_brief"))
        XCTAssertEqual(closed.failure?.code, .requestAdmissionClosed)
        let state = await dataSource.state()
        XCTAssertEqual(state.begin, 1)
        XCTAssertEqual(state.end, 1)
    }

    func testAttachedSourceAuthorityPinsAAndDeniesB() async {
        let dataSource = AgentLokiToolFakeDataSource()
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let authority = AgentLokiAttachedSourceRequestAuthority(
            sourceIdentifier: "source-a",
            accountIdentifier: "account-a",
            containerIdentifiers: ["container-a"],
            generationIdentifier: "generation-a",
            sourceEpoch: 4,
            sourceDigest: String(repeating: "a", count: 64)
        )

        let selected = await executor.execute(
            .init(
                name: "search_vault_text",
                arguments: ["query": .string("selected")]
            ),
            attachedSourceAuthority: authority
        )
        XCTAssertEqual(selected.status, .success)
        let selectedState = await dataSource.state()
        XCTAssertTrue(
            selectedState.calls.contains("vault_search:20:account-a")
        )

        let denied = await executor.execute(
            .init(
                name: "search_vault_text",
                arguments: [
                    "query": .string("other"),
                    "account_id": .string("account-b"),
                ]
            ),
            attachedSourceAuthority: authority
        )
        XCTAssertEqual(denied.status, .rejected)
        XCTAssertEqual(denied.failure?.code, .containerScopeDenied)
        XCTAssertTrue(denied.records.isEmpty)
    }

    func testAttachedSourceAuthorityRevalidatesAfterRead() async {
        let dataSource = AgentLokiToolFakeDataSource(
            invalidateAttachedAuthorityDuringRead: true
        )
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let result = await executor.execute(
            .init(
                name: "search_vault_text",
                arguments: ["query": .string("stale")]
            ),
            attachedSourceAuthority: .init(
                sourceIdentifier: "source-a",
                accountIdentifier: "account-a",
                containerIdentifiers: ["container-a"],
                generationIdentifier: "generation-a",
                sourceEpoch: 4,
                sourceDigest: String(repeating: "a", count: 64)
            )
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(
            result.reasonCode,
            "chat_attached_source_exact_scope_denied"
        )
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.evidence.isEmpty)
    }

    func testPreviewBackfillIsExplicitlyNonStarting() async throws {
        let dataSource = AgentLokiToolFakeDataSource()
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: .init(sink: { _ in })
        )
        let result = await executor.execute(.init(
            name: "preview_backfill_request",
            arguments: [
                "workspace_id": .string("workspace-allowed"),
                "channel_ids": .stringList(["channel-1"]),
                "item_limit": .integer(25),
            ]
        ))

        XCTAssertEqual(result.status, .success)
        guard case let .boolean(wouldStart)? = result.records.first?.fields["would_start"] else {
            XCTFail("The preview must expose an explicit non-starting disposition.")
            return
        }
        XCTAssertFalse(wouldStart)
        let state = await dataSource.state()
        XCTAssertEqual(state.calls, ["backfill_preview:25"])
    }

    func testToolTraceCarriesLinksAndNeverCarriesPrivateInputs() async throws {
        let recorder = AgentLokiToolTraceRecorder()
        let dataSource = AgentLokiToolFakeDataSource()
        let logger = AgentLokiToolTraceLogger(sink: { recorder.record($0) })
        let executor = AgentLokiReadOnlyToolExecutor(
            dataSource: dataSource,
            traceLogger: logger
        )
        let privateQuery = "private-channel password=hunter2 https://private.example/path"
        _ = await executor.execute(
            .init(
                name: "search_vault_text",
                arguments: ["query": .string(privateQuery)]
            ),
            modelIdentifier: "private-model-name"
        )

        let events = recorder.snapshot()
        XCTAssertEqual(events.first?.event, .requested)
        XCTAssertEqual(events.last?.event, .completed)
        XCTAssertTrue(events.allSatisfy { !$0.traceID.isEmpty && !$0.spanID.isEmpty })
        for event in events {
            let line = try XCTUnwrap(logger.encodedLine(for: event))
            XCTAssertFalse(line.contains(privateQuery))
            XCTAssertFalse(line.contains("private-channel"))
            XCTAssertFalse(line.contains("hunter2"))
            XCTAssertFalse(line.contains("private-model-name"))
            XCTAssertFalse(line.contains("https://"))
        }
    }

}

private func fixtureSnapshot(recordCount: Int) -> AgentLokiToolSnapshot {
    let retrievedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let evidence = (0 ..< recordCount).map { index -> AgentLokiEvidenceExcerpt in
        let reference = AgentLokiEvidenceReference(
            sourceKind: .vault,
            accountClassification: "authorized_account",
            accountIdentifier: "account-allowed",
            containerClassification: "authorized_container",
            containerIdentifier: "container-allowed",
            sourceItemID: "source-\(index)",
            sourceTimestamp: retrievedAt,
            retrievedAt: retrievedAt,
            localVaultID: "vault-\(index)",
            boundedLabel: "Evidence \(index)",
            directSourceURL: URL(string: "https://example.test/items/\(index)"),
            contentOrigin: .source,
            trust: .authorizedExternalUntrusted,
            claimBasis: .observed
        )
        return AgentLokiEvidenceExcerpt(reference: reference, text: "Bounded evidence \(index)")
    }
    let records = evidence.enumerated().map { index, excerpt in
        AgentLokiToolRecord(
            id: "record-\(index)",
            fields: ["title": .string("Result \(index)")],
            evidenceReferenceIDs: [excerpt.reference.id]
        )
    }
    return AgentLokiToolSnapshot(records: records, evidence: evidence)
}
