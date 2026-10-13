import XCTest
@testable import studiquo

/// Regression coverage for "フレンドのチャットでバブルを長押しすると、バブルの
/// 大きさと合わない範囲が選択されているように見える": `.frame(maxWidth: 280)` が
/// `.contextMenu` より内側にあると、長押しのプレビューがバブルではなく幅280ptの
/// 透明な枠全体になる。修正は frame を contextMenu の外へ出し、
/// `.contentShape(.contextMenuPreview, ...)` でバブルの角丸に揃えること。
///
/// 長押しのプレビュー形状は実行時に取得できないため、原因となる修飾子の順序を
/// ソースから確認する。
final class ChatBubbleContextMenuShapeTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/ProfileAndFriendsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `startMarker` から次の `endMarker` までの範囲を返す。
    private func slice(_ s: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(s.range(of: startMarker), "\(startMarker) が見つかりません")
        let rest = s[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: endMarker), "\(endMarker) が見つかりません")
        return String(rest[..<end.lowerBound])
    }

    private func assertBubbleIsTight(_ block: String, file: StaticString = #filePath, line: UInt = #line) {
        let shape = block.range(of: ".contentShape(.contextMenuPreview")
        let menu = block.range(of: ".contextMenu")
        let frame = block.range(of: ".frame(maxWidth: 280")
        XCTAssertNotNil(shape, "バブルに .contentShape(.contextMenuPreview, ...) が必要です", file: file, line: line)
        XCTAssertNotNil(menu, file: file, line: line)
        XCTAssertNotNil(frame, file: file, line: line)
        guard let shape, let menu, let frame else { return }
        XCTAssertLessThan(shape.lowerBound, menu.lowerBound,
                          "contentShape は contextMenu より前に置く", file: file, line: line)
        XCTAssertLessThan(menu.lowerBound, frame.lowerBound,
                          ".frame(maxWidth: 280) が .contextMenu より内側にあると、長押しの範囲が幅280ptの枠全体に広がる", file: file, line: line)
    }

    func testOneToOneBubbleKeepsFrameOutsideContextMenu() throws {
        let s = try source()
        let bubble = try slice(s, from: "messageBubble(text: parts.body", to: "if message.isCanceled != true {")
        XCTAssertTrue(bubble.contains(".frame(maxWidth: 280"))
        // バブル本体の定義側に frame が残っていないこと
        let def = try slice(s, from: "private func messageBubble(text:", to: "/// A message that already failed")
        XCTAssertFalse(def.contains(".frame(maxWidth: 280"),
                       "messageBubble 内に frame(maxWidth:) を戻さない")
        XCTAssertTrue(def.contains(".contentShape(.contextMenuPreview"))
        let menu = try XCTUnwrap(bubble.range(of: ".contextMenu"))
        let frame = try XCTUnwrap(bubble.range(of: ".frame(maxWidth: 280"))
        XCTAssertLessThan(menu.lowerBound, frame.lowerBound)
    }

    func testGroupBubbleKeepsFrameOutsideContextMenu() throws {
        let s = try source()
        let block = try slice(s, from: "Text(parts.body)\n                            .textSelection(.enabled)",
                              to: "ForEach(parts.attachments)")
        assertBubbleIsTight(block)
    }
}
