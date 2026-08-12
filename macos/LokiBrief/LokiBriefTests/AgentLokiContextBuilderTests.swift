import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class AgentLokiContextBuilderTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testAuthorityLayersAreExplicitAndOrdered() {
        let context = AgentLokiContextBuilder().build(.init(
            systemPolicy: "system",
            toolSchemas: "schemas",
            conversationTail: [],
            userRequest: "request",
            evidenceCandidates: [candidate(id: "one", priority: 1)]
        ))

        XCTAssertEqual(context.layers.map(\.authority), [
            .systemPolicy,
            .toolSchemas,
            .conversationTail,
            .userRequest,
            .boundedEvidence,
        ])
        XCTAssertTrue(context.layers.dropLast().allSatisfy(\.evidenceReferenceIDs.isEmpty))
        XCTAssertEqual(context.layers.last?.evidenceReferenceIDs, ["evidence_one"])
    }

    func testSelectionIsDeterministicAcrossInputOrder() {
        let candidates = [
            candidate(id: "low", priority: 0, timestampOffset: 30),
            candidate(id: "high-old", priority: 10, timestampOffset: 10),
            candidate(id: "high-new", priority: 10, timestampOffset: 20),
        ]
        let builder = AgentLokiContextBuilder(budget: .init(
            maximumConversationTurns: 2,
            maximumConversationCharacters: 1_000,
            maximumEvidenceItems: 2,
            maximumEvidenceCharacters: 10_000,
            maximumTotalCharacters: 20_000,
            maximumEstimatedTokens: 5_000
        ))

        let forward = builder.build(input(candidates))
        let reversed = builder.build(input(candidates.reversed()))

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward.includedEvidenceReferences.map(\.id),
            ["evidence_high-new", "evidence_high-old"]
        )
        XCTAssertEqual(forward.omittedEvidenceCount, 1)
        XCTAssertTrue(forward.wasTruncated)
    }

    func testEvidenceBudgetRetainsAttributionForEveryIncludedExcerpt() throws {
        let builder = AgentLokiContextBuilder(budget: .init(
            maximumConversationTurns: 0,
            maximumConversationCharacters: 0,
            maximumEvidenceItems: 2,
            maximumEvidenceCharacters: 10_000,
            maximumTotalCharacters: 20_000,
            maximumEstimatedTokens: 5_000
        ))
        let context = builder.build(input([
            candidate(id: "first", priority: 3),
            candidate(id: "second", priority: 2),
            candidate(id: "third", priority: 1),
        ]))
        let evidenceLayer = try XCTUnwrap(
            context.layers.first(where: { $0.authority == .boundedEvidence })
        )

        XCTAssertEqual(context.includedEvidenceReferences.count, 2)
        XCTAssertEqual(
            Set(evidenceLayer.evidenceReferenceIDs),
            Set(context.includedEvidenceReferences.map(\.id))
        )
        for reference in context.includedEvidenceReferences {
            XCTAssertTrue(evidenceLayer.content.contains(reference.id))
            XCTAssertTrue(context.citationAllowlist.contains(reference.id))
        }
        XCTAssertFalse(context.citationAllowlist.contains("evidence_third"))
    }

    func testSlackEvidenceDefaultsOffAndIsScopedPerWorkspace() {
        let feed = candidate(id: "feed", sourceKind: .feed, consentScopeID: nil)
        let slackOne = candidate(
            id: "slack-one",
            sourceKind: .slack,
            consentScopeID: "workspace-one"
        )
        let slackTwo = candidate(
            id: "slack-two",
            sourceKind: .slack,
            consentScopeID: "workspace-two"
        )

        let defaultContext = AgentLokiContextBuilder().build(
            input([feed, slackOne, slackTwo])
        )
        XCTAssertEqual(defaultContext.includedEvidenceReferences.map(\.id), ["evidence_feed"])

        let scopedContext = AgentLokiContextBuilder().build(.init(
            systemPolicy: "system",
            toolSchemas: "schemas",
            conversationTail: [],
            userRequest: "request",
            evidenceCandidates: [feed, slackOne, slackTwo],
            consent: .init(
                feedEvidenceEnabled: true,
                slackEnabledWorkspaceScopeIDs: ["workspace-one"]
            )
        ))
        XCTAssertEqual(
            Set(scopedContext.includedEvidenceReferences.map(\.id)),
            ["evidence_feed", "evidence_slack-one"]
        )
        XCTAssertFalse(scopedContext.citationAllowlist.contains("evidence_slack-two"))
    }

    func testConversationUsesOnlyNewestBoundedTailInChronologicalOrder() throws {
        let builder = AgentLokiContextBuilder(budget: .init(
            maximumConversationTurns: 2,
            maximumConversationCharacters: 1_000,
            maximumEvidenceItems: 1,
            maximumEvidenceCharacters: 1_000,
            maximumTotalCharacters: 8_000,
            maximumEstimatedTokens: 2_000
        ))
        let turns = [
            AgentLokiConversationTurn(
                id: "one",
                role: .user,
                text: "oldest",
                createdAt: fixedDate
            ),
            AgentLokiConversationTurn(
                id: "two",
                role: .assistant,
                text: "middle",
                createdAt: fixedDate.addingTimeInterval(1)
            ),
            AgentLokiConversationTurn(
                id: "three",
                role: .user,
                text: "newest",
                createdAt: fixedDate.addingTimeInterval(2)
            ),
        ]
        let context = builder.build(.init(
            systemPolicy: "system",
            toolSchemas: "schemas",
            conversationTail: turns.reversed(),
            userRequest: "request",
            evidenceCandidates: []
        ))
        let layer = try XCTUnwrap(
            context.layers.first(where: { $0.authority == .conversationTail })
        )

        XCTAssertEqual(layer.content, "assistant: middle\nuser: newest")
        XCTAssertEqual(context.includedConversationTurns.map(\.id), ["two", "three"])
        XCTAssertFalse(layer.content.contains("oldest"))
        XCTAssertTrue(context.wasTruncated)
    }

    func testSelectedContextScopesExposeOnlyTheirReadOnlyToolPlane() {
        XCTAssertEqual(
            LokiChatController.allowedToolNames(for: .thisBrief),
            [.getCurrentBrief]
        )
        XCTAssertEqual(
            LokiChatController.allowedToolNames(for: .vault),
            [.searchVaultText, .getVaultItem]
        )
        XCTAssertEqual(
            LokiChatController.allowedToolNames(for: .today),
            [.getCurrentBrief, .getDeliveryStatus, .getUpdateStatus]
        )
        XCTAssertEqual(
            LokiChatController.allowedToolNames(for: .history),
            [.getBriefByID, .searchBriefHistory]
        )
        XCTAssertTrue(
            LokiChatController.allowedToolNames(for: .vault)
                .isDisjoint(with: LokiChatController.allowedToolNames(for: .connectedSources))
        )
        for scope in LokiChatContextScope.deferredCases {
            XCTAssertTrue(LokiChatController.allowedToolNames(for: scope).isEmpty)
        }

        let selectedContext = LokiChatContext(
            scope: .connectedSources,
            targetIdentifier: "source-a"
        )
        XCTAssertTrue(LokiChatController.allowedToolNames(
            for: selectedContext,
            attachedSourceAuthority: nil
        ).isEmpty)
        XCTAssertEqual(
            LokiChatController.allowedToolNames(
                for: selectedContext,
                attachedSourceAuthority: .init(
                    sourceIdentifier: "source-a",
                    accountIdentifier: "account-a",
                    containerIdentifiers: ["container-a"],
                    generationIdentifier: "generation-a",
                    sourceEpoch: 1,
                    sourceDigest: String(repeating: "a", count: 64)
                )
            ),
            [.getSourceHealth, .searchVaultText, .getVaultItem]
        )
    }

    func testClaimBasisAndTrustSurviveContextAssembly() {
        let generated = candidate(
            id: "generated",
            sourceKind: .brief,
            claimBasis: .generated,
            trust: .localGenerated
        )
        let context = AgentLokiContextBuilder().build(input([generated]))

        XCTAssertEqual(context.includedEvidenceReferences.first?.claimBasis, .generated)
        XCTAssertEqual(context.includedEvidenceReferences.first?.trust, .localGenerated)
        XCTAssertTrue(context.layers.last?.content.contains("\"claimBasis\":\"generated\"") == true)
        XCTAssertTrue(context.layers.last?.content.contains("\"trust\":\"local_generated\"") == true)
    }

    func testTotalCharacterAndTokenBudgetsRemainHardCaps() {
        let budget = AgentLokiContextBudget(
            maximumConversationTurns: 8,
            maximumConversationCharacters: 8_000,
            maximumEvidenceItems: 10,
            maximumEvidenceCharacters: 20_000,
            maximumTotalCharacters: 2_000,
            maximumEstimatedTokens: 300
        )
        let longText = String(repeating: "trusted ", count: 2_000)
        let turns = (0 ..< 8).map {
            AgentLokiConversationTurn(
                id: "turn-\($0)",
                role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: longText,
                createdAt: fixedDate.addingTimeInterval(TimeInterval($0))
            )
        }
        let context = AgentLokiContextBuilder(budget: budget).build(.init(
            systemPolicy: longText,
            toolSchemas: longText,
            conversationTail: turns,
            userRequest: longText,
            evidenceCandidates: [
                candidate(id: "large", priority: 10),
            ]
        ))
        let characterCount = context.layers.reduce(0) { $0 + $1.content.count }

        XCTAssertLessThanOrEqual(characterCount, 1_200)
        XCTAssertLessThanOrEqual(context.estimatedTokenCount, budget.maximumEstimatedTokens)
        XCTAssertTrue(context.wasTruncated)
    }

    private func input<S: Sequence>(
        _ candidates: S
    ) -> AgentLokiContextInput where S.Element == AgentLokiContextCandidate {
        .init(
            systemPolicy: "system",
            toolSchemas: "schemas",
            conversationTail: [],
            userRequest: "request",
            evidenceCandidates: Array(candidates)
        )
    }

    private func candidate(
        id: String,
        sourceKind: AgentLokiEvidenceSourceKind = .vault,
        consentScopeID: String? = nil,
        priority: Int = 0,
        timestampOffset: TimeInterval = 0,
        claimBasis: AgentLokiClaimBasis = .observed,
        trust: AgentLokiEvidenceTrust = .authorizedExternalUntrusted
    ) -> AgentLokiContextCandidate {
        let timestamp = fixedDate.addingTimeInterval(timestampOffset)
        let reference = AgentLokiEvidenceReference(
            id: "evidence_\(id)",
            sourceKind: sourceKind,
            accountClassification: sourceKind == .slack ? "slack_workspace" : "authorized_account",
            containerClassification: sourceKind == .slack ? "selected_slack_channel" : "authorized_container",
            sourceItemID: id,
            sourceTimestamp: timestamp,
            retrievedAt: fixedDate,
            localVaultID: "vault:\(id)",
            boundedLabel: "Label \(id)",
            directSourceURL: URL(string: "https://example.test/\(id)"),
            contentOrigin: claimBasis == .generated ? .generated : .source,
            trust: trust,
            claimBasis: claimBasis
        )
        return AgentLokiContextCandidate(
            evidence: .init(reference: reference, text: "Excerpt \(id)"),
            consentScopeID: consentScopeID,
            priority: priority
        )
    }
}
