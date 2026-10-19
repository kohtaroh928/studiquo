import XCTest
@testable import studiquo

/// Regression coverage for "暗記帳の画面だけタブが下にずれる": the flashcard
/// deck view left the system navigation bar visible, so its content sat lower
/// than in every other document view. Each full-screen document view draws its
/// own "ホームへ戻る" header and must hide the navigation bar.
///
/// A presented view hierarchy can't be inspected at runtime, so this checks
/// the source directly (same approach as `NoteEditorPhotosPickerStyleTests`).
final class DocumentViewNavigationBarTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFullScreenDocumentViewsHideNavigationBar() throws {
        for file in ["FlashcardDeckView.swift", "SlideDeckView.swift", "TextDocumentView.swift", "NoteEditorView.swift"] {
            let text = try source(file)
            XCTAssertTrue(
                text.contains(".toolbar(.hidden, for: .navigationBar)")
                    || text.contains(".navigationBarHidden(true)"),
                "\(file) must hide the navigation bar so its content aligns with other documents"
            )
        }
    }

    func testFlashcardDeckViewHidesNavigationBarOnItsRootBody() throws {
        let text = try source("FlashcardDeckView.swift")
        let start = try XCTUnwrap(text.range(of: "struct FlashcardDeckView"))
        let end = try XCTUnwrap(text.range(of: "struct FlashcardStudyContent", range: start.upperBound..<text.endIndex))
        XCTAssertTrue(
            text[start.upperBound..<end.lowerBound].contains(".toolbar(.hidden, for: .navigationBar)"),
            "FlashcardDeckView's body must hide the navigation bar"
        )
    }
}
