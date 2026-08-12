import Foundation
import XCTest
@testable import LokiBrief

final class EmailMBoxReaderTests: XCTestCase {
    private let reader = EmailMBoxReader()

    func testSeparatorRecognitionAndMBoxrdUnescapeOnlyInBody() throws {
        let data = Data((entry(
            sender: "agent@example.com",
            messageID: "one@example.com",
            extraHeader: "X-Original: >From header remains\n",
            body: "First line\nFrom not a valid separator\n>From escaped body\n>>From twice escaped body\n"
        ) + entry(
            sender: "agent@example.com",
            messageID: "two@example.com",
            body: "Second body\n"
        )).utf8)
        let page = try reader.readPage(from: data, source: source(), pageSize: 10)

        XCTAssertEqual(page.entries.count, 2)
        let first = try XCTUnwrap(String(data: page.entries[0].data, encoding: .utf8))
        XCTAssertTrue(first.contains("X-Original: >From header remains"))
        XCTAssertTrue(first.contains("\nFrom escaped body\n"))
        XCTAssertTrue(first.contains("\n>From twice escaped body\n"))
        XCTAssertFalse(first.contains("\nFrom twice escaped body\n"))
        XCTAssertTrue(first.contains("\nFrom not a valid separator\n"))
        XCTAssertTrue(page.isComplete)
    }

    func testPaginationCheckpointResumesAtExactSeparator() throws {
        let data = Data((entry(messageID: "one@example.com")
            + entry(messageID: "two@example.com")
            + entry(messageID: "three@example.com")).utf8)
        let source = source()
        let first = try reader.readPage(from: data, source: source, pageSize: 1)
        let checkpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: 1,
            nextByteOffset: first.nextByteOffset,
            committedByteCount: first.committedByteCount,
            committedPrefixSHA256: first.committedPrefixSHA256,
            completed: false
        )
        let second = try reader.readPage(
            from: data,
            source: source,
            checkpoint: checkpoint,
            pageSize: 1
        )

        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.requestByteOffset, first.nextByteOffset)
        let message = try EmailMessageParser().parse(second.entries[0].data)
        XCTAssertEqual(message.headers.messageID, "two@example.com")
    }

    func testTaskOwnedSessionScansAndHashesMailboxOnlyOnceAcrossPages() throws {
        let messageCount = 40
        let data = Data((0..<messageCount).map {
            entry(
                messageID: "bounded-\($0)@example.com",
                body: String(repeating: "x", count: 4_096) + "\n"
            )
        }.joined().utf8)
        let source = source()
        let probe = EmailMBoxWorkProbe()
        let reader = EmailMBoxReader(workObserver: { probe.record($0) })
        let session = try reader.makeSession(for: data, source: source)
        var checkpoint: EmailImportCheckpoint?
        var pageCount = 0

        while true {
            let page = try session.readPage(
                checkpoint: checkpoint,
                pageSize: 1
            )
            XCTAssertEqual(
                page.committedPrefixSHA256,
                EmailDigest.sha256(data.prefix(page.committedByteCount))
            )
            pageCount += 1
            checkpoint = try EmailImportCheckpoint(
                sourceIdentifierHash: source.sourceIdentifierHash,
                format: .mbox,
                nextPageOrdinal: pageCount,
                nextByteOffset: page.nextByteOffset,
                committedByteCount: page.committedByteCount,
                committedPrefixSHA256: page.committedPrefixSHA256,
                completed: page.isComplete
            )
            if page.isComplete { break }
        }

        XCTAssertEqual(pageCount, messageCount)
        XCTAssertEqual(probe.prefixBytesHashed, data.count)
        XCTAssertLessThan(probe.separatorBytesScanned, data.count * 2)
    }

    func testTaskOwnedSessionDoesNotAdvanceUntilOutputCheckpointIsPresented() throws {
        let data = Data((entry(messageID: "one@example.com")
            + entry(messageID: "two@example.com")).utf8)
        let source = source()
        let session = try reader.makeSession(for: data, source: source)

        let prepared = try session.readPage(pageSize: 1)
        let retried = try session.readPage(pageSize: 1)
        XCTAssertEqual(prepared, retried)

        let committed = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: 1,
            nextByteOffset: prepared.nextByteOffset,
            committedByteCount: prepared.committedByteCount,
            committedPrefixSHA256: prepared.committedPrefixSHA256,
            completed: false
        )
        let second = try session.readPage(
            checkpoint: committed,
            pageSize: 1
        )
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(
            try EmailMessageParser().parse(second.entries[0].data)
                .headers.messageID,
            "two@example.com"
        )
    }

    func testSessionCreationCancelsDuringPersistedPrefixValidation() throws {
        let data = Data((entry(
            messageID: "large-one@example.com",
            body: String(repeating: "x", count: 768 * 1_024) + "\n"
        ) + entry(messageID: "two@example.com")).utf8)
        let source = source()
        let first = try reader.readPage(
            from: data,
            source: source,
            pageSize: 1
        )
        let checkpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: 1,
            nextByteOffset: first.nextByteOffset,
            committedByteCount: first.committedByteCount,
            committedPrefixSHA256: first.committedPrefixSHA256,
            completed: false
        )
        let probe = EmailMBoxCancellationProbe(cancelAfterCheck: 5)

        XCTAssertThrowsError(try reader.makeSession(
            for: data,
            source: source,
            checkpoint: checkpoint,
            isCancelled: { probe.isCancelled() }
        )) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 5)
    }

    func testCompletedCheckpointReadsOnlySafeAppend() throws {
        let original = Data(entry(messageID: "one@example.com").utf8)
        let source = source()
        let first = try reader.readPage(from: original, source: source)
        let checkpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: 1,
            committedByteCount: first.committedByteCount,
            committedPrefixSHA256: first.committedPrefixSHA256,
            completed: true
        )
        var appended = original
        appended.append(Data(entry(messageID: "two@example.com").utf8))

        let resumed = try reader.readPage(
            from: appended,
            source: source,
            checkpoint: checkpoint
        )

        XCTAssertEqual(resumed.entries.count, 1)
        XCTAssertEqual(
            try EmailMessageParser().parse(resumed.entries[0].data).headers.messageID,
            "two@example.com"
        )
    }

    func testChangedCommittedPrefixFailsClosed() throws {
        let original = Data((entry(messageID: "one@example.com")
            + entry(messageID: "two@example.com")).utf8)
        let source = source()
        let first = try reader.readPage(from: original, source: source, pageSize: 1)
        let checkpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: 1,
            nextByteOffset: first.nextByteOffset,
            committedByteCount: first.committedByteCount,
            committedPrefixSHA256: first.committedPrefixSHA256,
            completed: false
        )
        var changed = original
        changed[changed.startIndex] = 88

        XCTAssertThrowsError(
            try reader.readPage(from: changed, source: source, checkpoint: checkpoint)
        ) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .mailboxChanged)
        }
    }

    func testCancellationReturnsNoPage() {
        let data = Data(entry(messageID: "one@example.com").utf8)
        XCTAssertThrowsError(
            try reader.readPage(from: data, source: source(), isCancelled: { true })
        ) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
    }

    func testOversizedEntryIsClassifiedAndLaterEntryRemainsReadable() throws {
        let oversized = entry(
            messageID: "oversized@example.com",
            body: String(repeating: "x", count: 512) + "\n"
        )
        let valid = entry(messageID: "valid@example.com")
        let page = try EmailMBoxReader(maximumMessageBytes: 256).readPage(
            from: Data((oversized + valid).utf8),
            source: source(),
            pageSize: 10
        )

        XCTAssertEqual(page.skippedEntries.count, 1)
        XCTAssertEqual(page.skippedEntries[0].reasonCode, .messageTooLarge)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(
            try EmailMessageParser().parse(page.entries[0].data).headers.messageID,
            "valid@example.com"
        )
        XCTAssertTrue(page.isComplete)
    }

    private func source() -> EmailImportSource {
        .init(
            sourceIdentifier: "/synthetic/support.mbox",
            displayName: "Support mailbox.mbox",
            format: .mbox
        )
    }

    private func entry(
        sender: String = "support@example.com",
        messageID: String,
        extraHeader: String = "",
        body: String = "Body\n"
    ) -> String {
        "From \(sender) Tue Aug  8 14:15:16 2023\n"
            + "Message-ID: <\(messageID)>\n"
            + "From: \(sender)\n"
            + "To: customer@example.net\n"
            + "Subject: Ticket\n"
            + extraHeader
            + "\n"
            + body
    }
}

private final class EmailMBoxWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var scanned = 0
    private var hashed = 0

    var separatorBytesScanned: Int {
        lock.withLock { scanned }
    }

    var prefixBytesHashed: Int {
        lock.withLock { hashed }
    }

    func record(_ event: EmailMBoxWorkEvent) {
        lock.withLock {
            switch event {
            case let .separatorBytesScanned(count):
                scanned += count
            case let .prefixBytesHashed(count):
                hashed += count
            }
        }
    }
}

private final class EmailMBoxCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterCheck: Int
    private var checks = 0

    init(cancelAfterCheck: Int) {
        self.cancelAfterCheck = cancelAfterCheck
    }

    var checkCount: Int {
        lock.withLock { checks }
    }

    func isCancelled() -> Bool {
        lock.withLock {
            checks += 1
            return checks >= cancelAfterCheck
        }
    }
}
