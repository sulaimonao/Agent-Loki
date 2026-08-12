import Foundation
import XCTest
@testable import LokiBrief

final class EmailMessageParserTests: XCTestCase {
    func testFoldedAndEncodedHeadersUnicodeAndQuotedPrintableBody() throws {
        let message = """
        Message-ID: <Ticket-42@Example.COM>
        Date: Tue, 8 Aug 2023 14:15:16 +0000
        From: =?UTF-8?Q?Jos=C3=A9_Support?= <support@example.com>
        To: Customer <customer@example.net>
        Subject: =?UTF-8?Q?Printer_=E2=9C=93?=
         follow-up
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hello=2C Jos=C3=A9.=0ASecond line.
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))

        XCTAssertEqual(parsed.headers.messageID, "ticket-42@example.com")
        XCTAssertEqual(parsed.headers.subject, "Printer ✓ follow-up")
        XCTAssertEqual(parsed.headers.from, ["José Support <support@example.com>"])
        XCTAssertEqual(parsed.normalizedBody, "Hello, José.\nSecond line.")
        XCTAssertNotNil(parsed.headers.sentDate)
    }

    func testMultipartAlternativePrefersPlainTextAndSanitizesHTML() throws {
        let message = """
        From: support@example.com
        To: customer@example.net
        Subject: Alternative
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain; charset=utf-8

        Plain answer
        --alt
        Content-Type: text/html; charset=utf-8

        <p>HTML answer</p><script>steal()</script><img src="https://tracker.invalid/p.gif">
        --alt--
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))

        XCTAssertEqual(parsed.normalizedBody, "Plain answer")
        XCTAssertEqual(parsed.suppressedActiveHTMLCount, 1)
        XCTAssertEqual(parsed.suppressedRemoteResourceCount, 1)
        XCTAssertTrue(parsed.warnings.contains(.activeHTMLSuppressed))
        XCTAssertTrue(parsed.warnings.contains(.remoteHTMLResourceSuppressed))
    }

    func testHTMLFallbackRemovesActiveContentAndRemoteResources() throws {
        let message = """
        From: support@example.com
        Subject: HTML only
        Content-Type: text/html; charset=utf-8

        <div>Hello &amp; welcome</div><iframe src="https://evil.invalid">hidden</iframe>
        <a href="javascript:alert(1)" onclick="x()">Open ticket</a>
        <img width="1" height="1" src="https://tracker.invalid/pixel">
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))

        XCTAssertEqual(parsed.normalizedBody, "Hello & welcome Open ticket")
        XCTAssertFalse(parsed.normalizedBody.contains("hidden"))
        XCTAssertFalse(parsed.normalizedBody.contains("javascript"))
        XCTAssertEqual(parsed.suppressedActiveHTMLCount, 1)
        XCTAssertEqual(parsed.suppressedRemoteResourceCount, 1)
    }

    func testAttachmentStoresSafeMetadataAndDigestWithoutPayload() throws {
        let attachment = Data("secret attachment bytes".utf8)
        let encoded = attachment.base64EncodedString()
        let message = """
        Message-ID: <attachment@example.com>
        From: support@example.com
        Subject: Attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain; charset=utf-8

        See attached.
        --mixed
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="../../private/answer.bin"
        Content-Transfer-Encoding: base64

        \(encoded)
        --mixed--
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))
        let metadata = try XCTUnwrap(parsed.attachments.first)

        XCTAssertEqual(metadata.filename, "answer.bin")
        XCTAssertEqual(metadata.byteCount, attachment.count)
        XCTAssertEqual(metadata.sha256, EmailDigest.sha256(attachment))
        XCTAssertEqual(metadata.digestBasis, .decodedContent)
        XCTAssertEqual(parsed.normalizedBody, "See attached.")
    }

    func testMissingMessageIDFallsBackToDeterministicRawDigestIdentity() throws {
        let data = Data("From: support@example.com\nSubject: No ID\n\nBody".utf8)
        let first = try EmailMessageParser().parse(data)
        let second = try EmailMessageParser().parse(data)

        XCTAssertEqual(first.stableRemoteIdentifier, second.stableRemoteIdentifier)
        XCTAssertEqual(first.editOrVersionIdentifier, EmailDigest.sha256(data))
        XCTAssertTrue(first.stableRemoteIdentifier.hasSuffix(first.rawMessageSHA256))
    }

    func testMalformedHeaderIsSkippedWithoutHidingTheWarning() throws {
        let data = Data("From: support@example.com\nmalformed header line\nSubject: Ticket\n\nBody".utf8)
        let parsed = try EmailMessageParser().parse(data)

        XCTAssertEqual(parsed.normalizedBody, "Body")
        XCTAssertTrue(parsed.warnings.contains(.malformedHeaderSkipped))
    }

    func testOversizedAttachmentRemainsMetadataOnlyAndIsClassified() throws {
        let attachment = Data(
            repeating: 0x61,
            count: EmailImportLimits.maximumAttachmentBytes + 1
        )
        let message = """
        Message-ID: <oversized@example.com>
        From: support@example.com
        Subject: Oversized attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="oversized"

        --oversized
        Content-Type: text/plain; charset=utf-8

        Metadata only.
        --oversized
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="large.bin"
        Content-Transfer-Encoding: base64

        \(attachment.base64EncodedString())
        --oversized--
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))
        let metadata = try XCTUnwrap(parsed.attachments.first)
        XCTAssertEqual(metadata.byteCount, attachment.count)
        XCTAssertTrue(metadata.wasOversized)
        XCTAssertTrue(
            parsed.warnings.contains(.attachmentOversizedMetadataOnly)
        )
        XCTAssertEqual(parsed.normalizedBody, "Metadata only.")
    }

    func testUnsafeBidiScalarsAreRemovedFromVisibleHeaderAndFilename() throws {
        let message = """
        Message-ID: <bidi@example.com>
        From: Support\u{202E} <support@example.com>
        Subject: Invoice\u{202E}fdp.exe
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="bidi"

        --bidi
        Content-Type: text/plain; charset=utf-8

        Safe body.
        --bidi
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="report\u{202E}gnp.exe"
        Content-Transfer-Encoding: base64

        eA==
        --bidi--
        """

        let parsed = try EmailMessageParser().parse(Data(message.utf8))

        XCTAssertFalse(parsed.headers.subject.contains("\u{202E}"))
        XCTAssertFalse(parsed.headers.from.joined().contains("\u{202E}"))
        XCTAssertFalse(try XCTUnwrap(parsed.attachments.first).filename.contains("\u{202E}"))
    }

    func testCancellationIsObservedDuringQuotedPrintableDecode() {
        let probe = CancellationProbe(cancelAfterCheck: 12)
        let message = """
        From: support@example.com
        Subject: Cancellable
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        \(String(repeating: "a", count: 220_000))
        """

        XCTAssertThrowsError(try EmailMessageParser().parse(
            Data(message.utf8),
            isCancelled: { probe.isCancelled() }
        )) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 12)
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterCheck: Int
    private var checks = 0

    init(cancelAfterCheck: Int) {
        self.cancelAfterCheck = cancelAfterCheck
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfterCheck
    }
}
