import Foundation
import XCTest
@testable import LokiBrief

final class DeterministicSlackBriefingP3Tests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_780_000_000)

    func testDirectMentionWeightedUrgencyAndDefaultCollaborationAreExplicitlyAttributed() throws {
        let engine = DeterministicSlackBriefingEngine(now: { Self.anchor })
        let direct = Self.evidence(id: "direct", secondsAgo: 60, excerpt: "Can you review this?", direct: true, weight: 1)
        let urgent = Self.evidence(id: "urgent", secondsAgo: 120, excerpt: "Critical launch issue", direct: false, weight: 1.5)
        let nearMatch = Self.evidence(id: "near", secondsAgo: 180, excerpt: "This is noncritical collaboration", direct: false, weight: 2)

        let result = engine.assemble(evidence: [nearMatch, urgent, direct], preferences: .default)
        XCTAssertEqual(result.brief.sections.map(\.id), ["attention", "collaboration"])
        XCTAssertEqual(result.brief.sections.last?.title, "Messages and Collaboration")
        let byID = Dictionary(uniqueKeysWithValues: result.brief.sections.flatMap(\.items).map { ($0.id, $0) })
        XCTAssertEqual(byID["direct"]?.slackAttribution?.priorityReasonCode, "slack_direct_mention")
        XCTAssertEqual(byID["urgent"]?.slackAttribution?.priorityReasonCode, "slack_weighted_urgency")
        XCTAssertEqual(byID["near"]?.slackAttribution?.priorityReasonCode, "slack_collaboration_default")
        XCTAssertEqual(byID["direct"]?.slackAttribution?.workspaceName, "Acme")
        XCTAssertEqual(byID["direct"]?.slackAttribution?.channelName, "engineering")
        XCTAssertEqual(byID["direct"]?.slackAttribution?.authorName, "Mina")
        XCTAssertEqual(byID["direct"]?.slackAttribution?.locallyGenerated, false)
        XCTAssertEqual(byID["direct"]?.provenance.origin, .source)
        XCTAssertEqual(byID["direct"]?.source.kind, .slack)
    }

    func testPermutationIsStableAndEditChangesBriefIdentityWithoutChangingMessageIdentity() throws {
        let engine = DeterministicSlackBriefingEngine(now: { Self.anchor })
        let one = Self.evidence(id: "one", secondsAgo: 20, excerpt: "first", direct: false, weight: 1)
        let two = Self.evidence(id: "two", secondsAgo: 10, excerpt: "second", direct: true, weight: 1)
        let forward = engine.assemble(evidence: [one, two], preferences: .default)
        let reverse = engine.assemble(evidence: [two, one], preferences: .default)
        XCTAssertEqual(forward.brief, reverse.brief)
        XCTAssertEqual(forward.ranking, reverse.ranking)

        let edited = Self.evidence(
            id: "one",
            secondsAgo: 20,
            excerpt: "first, revised",
            direct: false,
            weight: 1,
            editedAt: SlackTimestamp(date: Self.anchor.addingTimeInterval(-5))
        )
        let revised = engine.assemble(evidence: [edited, two], preferences: .default)
        XCTAssertNotEqual(revised.brief.id, forward.brief.id)
        XCTAssertTrue(revised.brief.sections.flatMap(\.items).contains { $0.id == "one" })
    }

    func testDeletedDuplicateAndNonfiniteWeightNeverEnterBrief() throws {
        let engine = DeterministicSlackBriefingEngine(now: { Self.anchor })
        let available = Self.evidence(id: "stable", secondsAgo: 10, excerpt: "keep?", direct: true, weight: 1)
        let deleted = Self.evidence(id: "stable", secondsAgo: 10, excerpt: "", direct: false, weight: 1, state: .deleted)
        let nonfinite = Self.evidence(id: "nan", secondsAgo: 20, excerpt: "bad weight", direct: true, weight: .nan)

        let result = engine.assemble(evidence: [available, nonfinite, deleted], preferences: .default)
        XCTAssertTrue(result.brief.sections.isEmpty)
        XCTAssertEqual(Set(result.excludedEvidenceIDs), ["nan", "stable"])
    }

    func testMixedEngineReturnsExactFeedBriefWhenSlackHasNoUsableEvidenceOrFailure() throws {
        let feed = Self.feedResult()
        let engine = DeterministicMixedBriefingEngine(
            slackEngine: .init(now: { Self.anchor })
        )
        let deleted = Self.evidence(id: "deleted", secondsAgo: 30, excerpt: "", direct: false, weight: 1, state: .deleted)
        let result = engine.assemble(
            feedResult: feed,
            slackEvidence: [deleted],
            slackPreferences: .default
        )
        XCTAssertEqual(result.brief, feed.brief)
        XCTAssertNil(result.slackAssembly)
        XCTAssertTrue(result.slackRanking.isEmpty)
    }

    func testMixedEngineUsesStableGlobalOrderAndPreservesSlackAttribution() throws {
        let feed = Self.feedResult()
        let engine = DeterministicMixedBriefingEngine(slackEngine: .init(now: { Self.anchor }))
        let slack = Self.evidence(id: "slack", secondsAgo: 10, excerpt: "Please review", direct: true, weight: 1)
        let first = engine.assemble(feedResult: feed, slackEvidence: [slack], slackPreferences: .default)
        let second = engine.assemble(feedResult: feed, slackEvidence: [slack], slackPreferences: .default)
        XCTAssertEqual(first.brief, second.brief)
        XCTAssertEqual(first.brief.sections.map(\.id), ["attention", "news"])
        XCTAssertEqual(first.brief.sections.first?.items.first?.id, "slack")
        XCTAssertEqual(first.brief.sections.first?.items.first?.slackAttribution?.priorityReasonCode, "slack_direct_mention")
        XCTAssertEqual(first.brief.generation.engineID, DeterministicMixedBriefingEngine.identifier)
    }

    private static func evidence(
        id: String,
        secondsAgo: TimeInterval,
        excerpt: String,
        direct: Bool,
        weight: Double,
        editedAt: SlackTimestamp? = nil,
        state: SlackMessageEvidenceState = .available
    ) -> SlackMessageEvidence {
        let timestamp = SlackTimestamp(date: anchor.addingTimeInterval(-secondsAgo))
        return .init(
            id: id,
            workspaceID: "T123:U123",
            workspaceName: "Acme",
            channelID: "C100",
            channelName: "engineering",
            channelKind: .privateChannel,
            messageTimestamp: timestamp,
            excerpt: excerpt,
            author: .init(id: "U200", displayName: "Mina", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: direct,
            replyCount: 0,
            isEdited: editedAt != nil,
            editedAt: editedAt,
            permalink: URL(string: "https://acme.slack.com/archives/C100/p1780000000000000"),
            retrievedAt: anchor,
            selectedChannelWeight: weight,
            state: state
        )
    }

    private static func feedResult() -> BriefAssemblyResult {
        let source = BriefSource(
            id: "feed-one",
            name: "Example Feed",
            kind: .newsFeeds,
            state: .connected,
            capabilities: [.feeds],
            detail: "Public HTTPS feed."
        )
        let item = BriefItem(
            id: "feed-item",
            title: "Feed item",
            summary: "A retained feed summary.",
            priority: .normal,
            source: source,
            provenance: .init(
                sourceID: source.id,
                publicationDate: anchor.addingTimeInterval(-60),
                retrievedAt: anchor,
                directURL: URL(string: "https://example.com/item"),
                isSynthetic: false,
                origin: .source,
                format: "rss2",
                upstreamIdentifier: "feed-upstream"
            ),
            isRead: false,
            rankingExplanation: "Score 50: fixture."
        )
        let brief = Brief(
            id: "feed-brief-fixed",
            date: Calendar(identifier: .gregorian).startOfDay(for: anchor),
            title: "Loki Brief · 2026-05-28",
            summary: "One feed item.",
            status: .ready,
            sections: [.init(id: "news", title: "News and Research", items: [item])],
            generation: .init(
                engineID: DeterministicFeedBriefingEngine.identifier,
                generatedAt: anchor,
                status: .ready,
                reasonCode: "deterministic_feed_brief_assembled",
                fixtureRevision: 0,
                providerKind: "deterministic",
                sourceItemIDs: [item.id],
                validationResult: "not_applicable"
            )
        )
        return .init(
            brief: brief,
            ranking: [.init(itemID: item.id, score: 50, reasons: ["fixture"], sectionID: "news")],
            excludedEntryIDs: [],
            failureNotes: []
        )
    }
}
