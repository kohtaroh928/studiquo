import XCTest
@testable import studiquo

/// Regression coverage for "写真・テキストボックスの青い枠の中をドラッグしても
/// 動かない": the selection frame's move gesture was attached with
/// `.contentShape(Rectangle().stroke(lineWidth: 20))`, so only a thin band
/// along the border was draggable and a drag started inside the frame hit
/// nothing. The gesture must cover the whole interior of the frame.
///
/// A rendered hit-test region can't be inspected from a unit test, so this
/// checks the structural fact from source, like the other editor tests.
final class ElementMoveHitAreaTests: XCTestCase {
    private func selectionChromeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/NoteEditorView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var selectionChrome: some View"))
        let end = try XCTUnwrap(source.range(of: "private func resizeHandleGesture", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func testMoveGestureHitAreaCoversWholeFrameInterior() throws {
        let chrome = try selectionChromeSource()
        let gestureRange = try XCTUnwrap(chrome.range(of: ".gesture(moveGesture)"))
        // The modifiers attached to the outline right before the gesture.
        let outlineStart = try XCTUnwrap(chrome.range(of: "Rectangle()\n"))
        let outline = String(chrome[outlineStart.lowerBound..<gestureRange.lowerBound])
        XCTAssertTrue(
            outline.contains(".contentShape(Rectangle())"),
            "移動ジェスチャーの判定は青い枠の内側全体(Rectangle())である必要があります。"
        )
        XCTAssertFalse(
            outline.contains(".stroke(") && outline.contains("contentShape(Rectangle().stroke"),
            "判定を枠線の帯(Rectangle().stroke)だけにすると、枠の中をドラッグしても動かない不具合が再発します。"
        )
    }
}
