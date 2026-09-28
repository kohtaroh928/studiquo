import XCTest
@testable import studiquo

/// Regression coverage for "ノートの写真ボタンをタップすると、写真ライブラリの
/// 案内文がツールバーからはみ出して隣のボタンと重なる": the fix landed as
/// `FullScreenPhotoPicker` (a `PHPickerViewController` wrapped directly and
/// shown via `.fullScreenCover` — see its own doc comment in
/// NoteEditorView.swift) instead of SwiftUI's `PhotosPicker`. The three
/// trigger points (the toolbar's "写真" icon, the "写真を背景に設定" menu
/// row, and the "表示モード" menu's own "写真" row) must stay plain buttons
/// that just flip a `Bool` to present that full-screen cover — reintroducing
/// an inline `PhotosPicker` (especially with `.photosPickerStyle(.compact)`,
/// the original mistake) would bring the overflow bug straight back, since
/// that style embeds a live, unconstrained photo-browsing strip — and, under
/// Limited Photos Access, an unbounded-width access-management banner —
/// directly inline instead of behind a self-contained full-screen cover.
///
/// There's no supported way to inspect a presented `View` hierarchy or a
/// `photosPickerStyle` modifier at runtime (layout only shows up once the
/// system's own picker/permission UI is on screen), so this checks the
/// structural facts that actually determine the bug, straight from source.
final class NoteEditorPhotosPickerStyleTests: XCTestCase {
    private func noteEditorViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/NoteEditorView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The core regression test: SwiftUI's `PhotosPicker` must never be
    /// embedded inline in the toolbar or a menu row again.
    func testNoteEditorViewNeverEmbedsAnInlinePhotosPicker() throws {
        let source = try noteEditorViewSource()
        XCTAssertFalse(
            source.contains("PhotosPicker("),
            "NoteEditorView.swift はもう SwiftUI の PhotosPicker を直接埋め込んで"
                + "はいけません。写真選択は FullScreenPhotoPicker を .fullScreenCover"
                + "で表示する形に置き換えられています — PhotosPicker を（特に"
                + ".photosPickerStyle(.compact) 付きで）ツールバーやメニュー内に"
                + "戻すと、案内文がはみ出して隣接する要素と重なる不具合が再発します。"
        )
        XCTAssertFalse(
            source.contains(".photosPickerStyle(.compact)"),
            "念のための二重チェック: .photosPickerStyle(.compact) はこのファイルの"
                + "どこにも現れてはいけません。"
        )
    }

    /// The three original trigger points must still be plain buttons that
    /// only flip presentation state — not, e.g., an inline picker that
    /// happens to also toggle the flag.
    func testAllThreePhotoTriggersArePlainButtonsThatOnlyPresentTheFullScreenCover() throws {
        let source = try noteEditorViewSource()

        XCTAssertTrue(
            source.contains("showsImagePicker = true"),
            "ツールバーの「写真」ボタンと「表示モード」内の「写真」行は、" +
                "showsImagePicker を true にするだけの単純なボタンである必要があります。"
        )
        XCTAssertTrue(
            source.contains("showsBackgroundImagePicker = true"),
            "「写真を背景に設定」の行は、showsBackgroundImagePicker を true に" +
                "するだけの単純なボタンである必要があります。"
        )
    }

    /// `FullScreenPhotoPicker` must only ever be shown as a genuine
    /// full-screen cover — the whole point of the fix is that a picker (and
    /// whatever access-management banner it may show) has the entire screen
    /// to render in, so it structurally cannot overflow into neighboring
    /// toolbar or menu content the way an inline picker did.
    func testFullScreenPhotoPickerIsOnlyEverPresentedAsAFullScreenCover() throws {
        let source = try noteEditorViewSource()

        /// Whether `.fullScreenCover(isPresented: $<bindingName>)` is
        /// immediately followed (within a short window — just past any
        /// reasonable amount of whitespace/braces) by `FullScreenPhotoPicker`.
        func isPresentedAsFullScreenCover(bindingName: String) -> Bool {
            guard let bindingRange = source.range(of: ".fullScreenCover(isPresented: $\(bindingName))") else {
                return false
            }
            let after = source[bindingRange.upperBound...].prefix(200)
            return after.contains("FullScreenPhotoPicker")
        }

        XCTAssertTrue(
            isPresentedAsFullScreenCover(bindingName: "showsImagePicker"),
            "showsImagePicker は .fullScreenCover(isPresented:) の中で" +
                " FullScreenPhotoPicker を表示する必要があります。シートや" +
                "ポップオーバー、インライン表示に変更すると、画面の端で" +
                "案内文がはみ出す不具合が再発する可能性があります。"
        )
        XCTAssertTrue(
            isPresentedAsFullScreenCover(bindingName: "showsBackgroundImagePicker"),
            "showsBackgroundImagePicker は .fullScreenCover(isPresented:) の中で" +
                " FullScreenPhotoPicker を表示する必要があります。シートや" +
                "ポップオーバー、インライン表示に変更すると、画面の端で" +
                "案内文がはみ出す不具合が再発する可能性があります。"
        )
    }
}
