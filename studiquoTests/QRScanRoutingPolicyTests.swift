import XCTest
@testable import studiquo

final class QRScanRoutingPolicyTests: XCTestCase {
    func testAcceptsTheCurrentHTTPSUniversalLinkFormat() {
        XCTAssertTrue(QRScanRoutingPolicy.isInviteLink("https://studiquo-mcp.studiquo-mcp-server.workers.dev/invite?token=LINKTOKEN1"))
    }

    func testAcceptsTheOlderCustomSchemeFormat() {
        XCTAssertTrue(QRScanRoutingPolicy.isInviteLink("studiquo://friend/add?token=LINKTOKEN1"))
    }

    func testRejectsAPlainManuallyTypedStyleCode() {
        XCTAssertFalse(QRScanRoutingPolicy.isInviteLink("ABCD1234"))
    }

    func testRejectsSomethingThatIsNotEvenAURL() {
        XCTAssertFalse(QRScanRoutingPolicy.isInviteLink("not a url at all"))
    }

    /// This policy only decides *where to route* a scan (to `add(url:)` vs.
    /// the manual-code path) — it isn't the final word on whether the link
    /// is actually one of studiquo's own. An unrelated https:// link still
    /// routes to `add(url:)`, which safely no-ops on it once it checks the
    /// exact host/path itself; this matches the scheme-only check the
    /// inline code did before being pulled out into this policy.
    func testAnUnrelatedHTTPSLinkStillRoutesToAddURLRatherThanTheManualCodePath() {
        XCTAssertTrue(QRScanRoutingPolicy.isInviteLink("https://example.com/some/other/page"))
    }
}
