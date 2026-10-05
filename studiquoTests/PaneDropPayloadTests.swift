import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import studiquo

/// A pane takes a cut-out page region and a dragged tab through ONE drop destination.
/// These pin down that the single payload type understands both — the AI chat pane
/// regressed when each kind had its own destination — and that the tab kinds every
/// pane recognises come from one list.
final class PaneDropPayloadTests: XCTestCase {
    // MARK: Which strings are tabs

    func testEveryKindOfTabInTheTabBarIsRecognised() {
        // Payload shapes produced by the tab bar's `.draggable(...)`.
        for value in ["notebook:abc", "deck:abc", "document:abc", "slide:abc", "web:Google|https://x", "ai:abc", "friend:abc", "group:abc"] {
            XCTAssertTrue(PaneDropPayload.isTab(value), value)
        }
    }

    func testPlainTextIsNotATab() {
        for value in ["", "hello", "notebook", "notebook-1", "a note: about tabs", "https://example.com"] {
            XCTAssertFalse(PaneDropPayload.isTab(value), value)
        }
    }

    // MARK: Reading what a drag delivers

    private func provider(type: UTType, data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func load(_ provider: NSItemProvider) async throws -> PaneDropPayload {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PaneDropPayload.self) { continuation.resume(with: $0) }
        }
    }

    func testATabDragIsReadAsATab() async throws {
        let drag = provider(type: .utf8PlainText, data: Data("notebook:12345".utf8))
        let payload = try await load(drag)
        guard case .tab(let value) = payload else { return XCTFail("expected a tab, got \(payload)") }
        XCTAssertEqual(value, "notebook:12345")
    }

    func testACutOutPageRegionIsStillReadAsASnippet() async throws {
        let snippet = PageSnippet(pngData: Data([0x89, 0x50, 0x4E, 0x47]), sourceLabel: "ノート 3ページ")
        let drag = provider(type: .studiquoPageSnippet, data: try JSONEncoder().encode(snippet))
        let payload = try await load(drag)
        guard case .snippet(let received) = payload else { return XCTFail("expected a snippet, got \(payload)") }
        XCTAssertEqual(received.sourceLabel, "ノート 3ページ")
        XCTAssertEqual(received.id, snippet.id)
    }
}

/// The layer over a web view must let every real touch through to the page while still
/// answering the drag-and-drop probe — otherwise the page becomes unusable, or a tab
/// dropped on it is lost.
@MainActor
final class TabDropShieldHitTestTests: XCTestCase {
    private final class StubEvent: UIEvent {
        private let stubbedType: UIEvent.EventType
        init(type: UIEvent.EventType) {
            stubbedType = type
            super.init()
        }
        override var type: UIEvent.EventType { stubbedType }
    }

    private func makeShield() -> TabDropShield.ShieldView {
        let shield = TabDropShield.ShieldView()
        shield.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        return shield
    }

    func testTouchesPassThroughToThePage() {
        let shield = makeShield()
        XCTAssertNil(shield.hitTest(CGPoint(x: 100, y: 100), with: StubEvent(type: .touches)))
    }

    func testScrollsHoversAndPressesPassThroughToThePage() {
        let shield = makeShield()
        for type in [UIEvent.EventType.scroll, .hover, .presses, .transform] {
            XCTAssertNil(shield.hitTest(CGPoint(x: 100, y: 100), with: StubEvent(type: type)), "\(type)")
        }
    }

    func testTheDragProbeLandsOnTheShield() {
        let shield = makeShield()
        XCTAssertTrue(shield.hitTest(CGPoint(x: 100, y: 100), with: nil) === shield)
    }

    func testAnEventOfAnUndocumentedTypeIsTreatedAsTheDragProbe() throws {
        // The drag-and-drop probe arrives with an event whose type UIKit does not
        // document (raw value 9 on the iOS this was verified against).
        let undocumented = try XCTUnwrap(UIEvent.EventType(rawValue: 9), "this OS does not even represent raw value 9")
        let shield = makeShield()
        XCTAssertTrue(shield.hitTest(CGPoint(x: 100, y: 100), with: StubEvent(type: undocumented)) === shield)
    }

    func testPointsOutsideTheShieldAreNotClaimed() {
        let shield = makeShield()
        XCTAssertNil(shield.hitTest(CGPoint(x: 500, y: 500), with: nil))
    }
}
