import XCTest
import WebKit
@testable import studiquo

/// Regression coverage for a real gap: the in-app research browser
/// (`WebBrowserModel`, `NoteEditorView.swift`) had no navigation
/// restriction at all — any page's own link or script could send it to
/// `file://`, `tel:`/`sms:`/`mailto:`, or an arbitrary custom scheme,
/// with nothing in the app deciding whether that should be allowed.
final class WebBrowserNavigationPolicyTests: XCTestCase {
    func testHTTPIsAllowed() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "http://example.com")), .allow)
    }

    func testHTTPSIsAllowed() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "https://www.google.com/search?q=test")), .allow)
    }

    func testSchemeMatchingIsCaseInsensitive() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "HTTPS://example.com")), .allow)
    }

    func testFileURLIsBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "file:///etc/passwd")), .cancel)
    }

    func testTelSchemeIsBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "tel:+81312345678")), .cancel)
    }

    func testMailtoSchemeIsBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "mailto:someone@example.com")), .cancel)
    }

    func testAnArbitraryCustomAppSchemeIsBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "someotherapp://open?id=1")), .cancel)
    }

    /// The app's own scheme is not special-cased here either — the research
    /// browser has no legitimate reason to navigate back into studiquo
    /// itself, and blocking it closes off a page using its own URL scheme
    /// to trigger an in-app deep link (e.g. the friend-add flow) without
    /// the student choosing to do that.
    func testTheAppsOwnCustomSchemeIsAlsoBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: URL(string: "studiquo://friend/add?code=ABCDEFG")), .cancel)
    }

    func testANilURLIsBlocked() {
        XCTAssertEqual(webBrowserNavigationPolicy(for: nil), .cancel)
    }
}
