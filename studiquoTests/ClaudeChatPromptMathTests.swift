import XCTest
@testable import studiquo

/// The direct-Claude route must ask for math the same way the server prompts
/// do, so replies from either path are typeset.
final class ClaudeChatPromptMathTests: XCTestCase {
    func testThePromptAsksForDelimitedLaTeX() {
        let prompt = ClaudeChatService.systemPrompt(noteContext: "")
        XCTAssertTrue(prompt.contains("$...$"))
        XCTAssertTrue(prompt.contains("$$...$$"))
        XCTAssertTrue(prompt.contains(#"\text{距離}"#), "日本語を式に入れる書き方")
        XCTAssertTrue(prompt.contains("「100円」"), "通貨の$を避ける指示")
        XCTAssertFalse(prompt.contains(#"\\"#), "バックスラッシュが二重になっていません")
    }

    func testTheNoteContextIsStillAppended() {
        let prompt = ClaudeChatService.systemPrompt(noteContext: "加法定理のメモ")
        XCTAssertTrue(prompt.contains("加法定理のメモ"))
        XCTAssertTrue(prompt.contains("$$...$$"))
    }
}
