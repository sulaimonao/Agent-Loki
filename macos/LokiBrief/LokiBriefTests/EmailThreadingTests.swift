import XCTest
@testable import LokiBrief

final class EmailThreadingTests: XCTestCase {
    func testReferencesWinAndPreserveRootAndParent() {
        let relation = EmailThreader.relation(for: headers(
            messageID: "new@example.com",
            inReplyTo: "parent@example.com",
            references: ["root@example.com", "parent@example.com"]
        ))

        XCTAssertEqual(relation.basis, .messageReferences)
        XCTAssertEqual(relation.rootMessageID, "root@example.com")
        XCTAssertEqual(relation.parentMessageID, "parent@example.com")
        XCTAssertNotNil(relation.connectorParentIdentifier)
    }

    func testInReplyToUsedWhenReferencesAreAbsent() {
        let relation = EmailThreader.relation(for: headers(
            inReplyTo: "parent@example.com"
        ))

        XCTAssertEqual(relation.basis, .inReplyTo)
        XCTAssertEqual(relation.rootMessageID, "parent@example.com")
    }

    func testRootMessageIDAndReplyReferencesShareOneConnectorThread() {
        let root = EmailThreader.relation(for: headers(
            messageID: "root@example.com",
            from: ["support@example.com"],
            to: ["customer@example.net"],
            subject: "Ticket"
        ))
        let reply = EmailThreader.relation(for: headers(
            messageID: "reply@example.com",
            inReplyTo: "root@example.com",
            references: ["root@example.com"],
            from: ["customer@example.net"],
            to: ["support@example.com"],
            subject: "Re: Ticket"
        ))

        XCTAssertEqual(root.basis, .messageIDRoot)
        XCTAssertEqual(
            root.connectorParentIdentifier,
            reply.connectorParentIdentifier
        )
    }

    func testInReplyToOnlyChainResolvesStableRootWithinImportPage() {
        let values = [
            headers(
                messageID: "deep@example.com",
                inReplyTo: "reply@example.com"
            ),
            headers(messageID: "root@example.com"),
            headers(
                messageID: "reply@example.com",
                inReplyTo: "root@example.com"
            ),
        ]

        let relations = EmailThreader.relations(for: values)

        XCTAssertEqual(relations[0].basis, .inReplyTo)
        XCTAssertEqual(relations[0].parentMessageID, "reply@example.com")
        XCTAssertEqual(relations[0].rootMessageID, "root@example.com")
        XCTAssertEqual(
            relations[0].connectorParentIdentifier,
            relations[1].connectorParentIdentifier
        )
        XCTAssertEqual(
            relations[2].connectorParentIdentifier,
            relations[1].connectorParentIdentifier
        )
    }

    func testHeuristicFallbackIsExplicitAndDeterministic() {
        let first = EmailThreader.relation(for: headers(
            from: ["Agent <support@example.com>"],
            to: ["Customer <customer@example.net>"],
            subject: "Re: Printer offline"
        ))
        let second = EmailThreader.relation(for: headers(
            from: ["Agent <support@example.com>"],
            to: ["Customer <customer@example.net>"],
            subject: "FWD: Printer offline"
        ))

        XCTAssertEqual(first.basis, .heuristicSubjectParticipants)
        XCTAssertEqual(first.heuristicKey, second.heuristicKey)
        XCTAssertNil(first.parentMessageID)
        XCTAssertNil(first.rootMessageID)
    }

    private func headers(
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        from: [String] = [],
        to: [String] = [],
        subject: String = ""
    ) -> EmailHeaderFields {
        .init(
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            from: from,
            to: to,
            cc: [],
            replyTo: [],
            subject: subject,
            sentDate: nil,
            receivedDate: nil
        )
    }
}
