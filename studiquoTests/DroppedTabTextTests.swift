import XCTest
@testable import studiquo

/// タブをAIチャットの入力欄へドロップしたとき、入力欄が文字として受け取った
/// タブIDを見分けられることの確認(見分けたIDは添付に変換され、入力欄には残らない)。
final class DroppedTabTextTests: XCTestCase {
    func testDetectsTabIDDroppedIntoEmptyDraft() {
        XCTAssertEqual(DroppedTabText.tabID(old: "", new: "notebook:abc123"), "notebook:abc123")
    }

    func testDetectsTabIDInsertedAfterExistingText() {
        XCTAssertEqual(DroppedTabText.tabID(old: "これを要約して", new: "これを要約してdocument:XYZ"), "document:XYZ")
    }

    func testDetectsTabIDInsertedInTheMiddle() {
        XCTAssertEqual(DroppedTabText.tabID(old: "前後", new: "前slide:42後"), "slide:42")
    }

    func testEveryDraggableKindIsRecognised() {
        for kind in ["notebook", "deck", "web", "ai", "friend", "group", "document", "slide"] {
            XCTAssertEqual(DroppedTabText.tabID(old: "", new: "\(kind):id"), "\(kind):id", kind)
        }
    }

    func testOrdinaryTypingAndPastingAreNotTreatedAsTabIDs() {
        XCTAssertNil(DroppedTabText.tabID(old: "", new: "こんにちは"))
        XCTAssertNil(DroppedTabText.tabID(old: "abc", new: "abcd"))
        XCTAssertNil(DroppedTabText.tabID(old: "", new: "https://example.com"))
        XCTAssertNil(DroppedTabText.tabID(old: "", new: "note: メモ"))
    }

    func testDeletingTextIsIgnored() {
        XCTAssertNil(DroppedTabText.tabID(old: "notebook:abc", new: ""))
        XCTAssertNil(DroppedTabText.tabID(old: "notebook:abc", new: "notebook:abc"))
    }
}
