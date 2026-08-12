import XCTest
@testable import LokiBrief

final class EmailHTMLSanitizerTests: XCTestCase {
    func testVisibleTextOnlyAndTrackingPixelSuppression() {
        let html = """
        <html><head><style>.x { display:none }</style></head><body>
        <h1>Case &amp; status</h1>
        <script>send(document.cookie)</script>
        <p onclick="run()">Resolved &#x2713;</p>
        <img width="1" height="1" src="https://tracker.invalid/open.gif">
        <object data="https://evil.invalid">not visible</object>
        </body></html>
        """

        let result = EmailHTMLSanitizer().sanitize(html)

        XCTAssertEqual(result.text, "Case & status Resolved ✓")
        XCTAssertFalse(result.text.contains("cookie"))
        XCTAssertFalse(result.text.contains("tracker"))
        XCTAssertFalse(result.text.contains("not visible"))
        XCTAssertEqual(result.suppressedRemoteResourceCount, 1)
        XCTAssertGreaterThanOrEqual(result.suppressedActiveContentCount, 4)
    }

    func testDangerousLinksRetainOnlyVisibleLabel() {
        let result = EmailHTMLSanitizer().sanitize(
            #"<a href="javascript:alert(1)" style="background:url(https://x)">safe label</a>"#
        )

        XCTAssertEqual(result.text, "safe label")
        XCTAssertFalse(result.text.contains("javascript"))
        XCTAssertFalse(result.text.contains("https"))
    }
}
