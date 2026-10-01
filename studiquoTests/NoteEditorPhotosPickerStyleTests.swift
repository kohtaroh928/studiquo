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

    private func photoStudyLibraryViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/PhotoStudyLibraryView.swift")
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

    func testPhotoStudyReplacesThePaneOppositeTheLastEditedNote() {
        XCTAssertEqual(
            PhotoStudyPlacementPolicy.photoPane(
                lastActive: .primary,
                primaryCanEdit: true,
                secondaryCanEdit: true
            ),
            .secondary
        )
        XCTAssertEqual(
            PhotoStudyPlacementPolicy.photoPane(
                lastActive: .secondary,
                primaryCanEdit: true,
                secondaryCanEdit: true
            ),
            .primary
        )
    }

    func testPhotoStudyKeepsTheOnlyEditableNoteVisible() {
        XCTAssertEqual(
            PhotoStudyPlacementPolicy.photoPane(
                lastActive: .primary,
                primaryCanEdit: false,
                secondaryCanEdit: true
            ),
            .primary
        )
        XCTAssertEqual(
            PhotoStudyPlacementPolicy.photoPane(
                lastActive: .secondary,
                primaryCanEdit: true,
                secondaryCanEdit: false
            ),
            .secondary
        )
    }

    /// Regression coverage for a selected reference photo covering both
    /// halves of the editor. The viewer used to be attached to the root of
    /// `NoteEditorView` as an overlay, so its black background hid the note.
    /// It must stay inside `photoStudyLibraryPane`, which is already bounded
    /// by the split layout.
    func testSelectedPhotoViewerIsHostedOnlyInsidePhotoStudyPane() throws {
        let source = try noteEditorViewSource()
        let paneStart = try XCTUnwrap(source.range(of: "private var photoStudyLibraryPane"))
        let followingSource = source[paneStart.lowerBound...]
        let paneEnd = try XCTUnwrap(followingSource.range(of: "private func temporaryChatMaterialView"))
        let paneImplementation = followingSource[..<paneEnd.lowerBound]

        XCTAssertTrue(
            paneImplementation.contains("PhotoStudyPaneViewer("),
            "選択した写真は、分割された写真資料ペインの中で表示する必要があります。"
        )
        XCTAssertEqual(
            source.components(separatedBy: "PhotoStudyPaneViewer(").count - 1,
            1,
            "PhotoStudyPaneViewer をNoteEditorView全体のoverlayなどにも追加すると、" +
                "ノート側まで覆う不具合が再発します。表示場所は写真資料ペイン内の1か所だけにしてください。"
        )
    }

    /// Even when hosted by the correct pane, ignoring safe areas lets the
    /// viewer paint outside its proposed split bounds. Clipping at the pane
    /// viewer is the second guard that keeps the image on one half only.
    func testSelectedPhotoViewerCannotEscapeItsSplitPaneBounds() throws {
        let source = try photoStudyLibraryViewSource()
        let viewerStart = try XCTUnwrap(source.range(of: "struct PhotoStudyPaneViewer"))
        let viewerSource = source[viewerStart.lowerBound...]

        XCTAssertTrue(
            viewerSource.contains(".clipped()"),
            "写真ビューは分割ペインの境界でクリップし、ノート側へ描画がはみ出さないようにしてください。"
        )
        XCTAssertFalse(
            viewerSource.contains(".ignoresSafeArea()"),
            "写真ビュー内で ignoresSafeArea を使うと、半画面の境界を越えて全画面を覆う可能性があります。"
        )
    }

    func testPhotoStudySplitSurvivesRotationAndOnlyChangesItsAxis() throws {
        let source = try noteEditorViewSource()
        let orientationStart = try XCTUnwrap(source.range(of: "private func updateOrientation"))
        let following = source[orientationStart.lowerBound...]
        let orientationEnd = try XCTUnwrap(following.range(of: "private func collapseSplit"))
        let implementation = following[..<orientationEnd.lowerBound]

        XCTAssertTrue(implementation.contains("photoStudyPane != nil"))
        XCTAssertTrue(implementation.contains("splitMode = portrait ? .vertical : .horizontal"))
        XCTAssertFalse(
            implementation.contains("photoStudyPane = nil"),
            "端末回転で写真資料を閉じたり、選択写真を全画面側へ逃がしてはいけません。"
        )
    }

    func testPhotoStudyDisablesPaneSwapThatWouldMoveToolsOntoThePhotoPane() throws {
        let source = try noteEditorViewSource()
        let swapStart = try XCTUnwrap(source.range(of: "private func swapSplitPanes"))
        let following = source[swapStart.lowerBound...]
        let swapEnd = try XCTUnwrap(following.range(of: "private var drawingTool"))
        let implementation = following[..<swapEnd.lowerBound]

        XCTAssertTrue(
            implementation.contains("guard splitMode != .single, photoStudyPane == nil else { return }"),
            "写真表示中の左右入れ替えで、ノート用ツールが写真ペインを操作する状態を作ってはいけません。"
        )
    }

    func testAIAndFriendChatSnippetRoutesRemainIndependent() throws {
        let source = try noteEditorViewSource()

        let friendStart = try XCTUnwrap(source.range(of: "private func addSnippetToChat"))
        let friendFollowing = source[friendStart.lowerBound...]
        let friendEnd = try XCTUnwrap(friendFollowing.range(of: "private func openChat(_ target: NoteChatTarget, attaching snippet: PageSnippet)"))
        let friendRoute = friendFollowing[..<friendEnd.lowerBound]
        XCTAssertTrue(friendRoute.contains("pendingChatSnippet"))
        XCTAssertFalse(friendRoute.contains("askAIAboutSnippet"), "フレンド送信用の切り抜きをAI質問へ誤配送してはいけません。")

        let aiStart = try XCTUnwrap(source.range(of: "private func askAIAboutSnippet"))
        let aiFollowing = source[aiStart.lowerBound...]
        let aiEnd = try XCTUnwrap(aiFollowing.range(of: "private func attachmentForDroppedTab"))
        let aiRoute = aiFollowing[..<aiEnd.lowerBound]
        XCTAssertTrue(aiRoute.contains("AIChatAttachment"))
        XCTAssertTrue(aiRoute.contains("sendAIChatMessage"))
        XCTAssertFalse(aiRoute.contains("pendingChatSnippet"), "AI質問用の切り抜きが個人・グループチャットの入力欄へ介入してはいけません。")
    }

    func testTransientSnippetSelectionAndPickerStateIsNeverPersistedAcrossRelaunch() throws {
        let source = try noteEditorViewSource()
        for declaration in [
            "@State private var snippetAwaitingChatPicker",
            "@State private var pendingChatSnippet",
            "@State private var pendingProofQuestionSnippet",
            "@State private var pendingProofAnswerSnippet",
            "@State private var showsChatPicker",
        ] {
            XCTAssertTrue(source.contains(declaration), "一時UI状態はNoteEditorViewの起動中だけ保持する必要があります: \(declaration)")
        }
        for persistedName in [
            "@AppStorage(\"snippetAwaitingChatPicker\")",
            "@AppStorage(\"pendingChatSnippet\")",
            "@AppStorage(\"pendingProofQuestionSnippet\")",
            "@AppStorage(\"pendingProofAnswerSnippet\")",
            "@AppStorage(\"showsChatPicker\")",
        ] {
            XCTAssertFalse(source.contains(persistedName), "再起動後に点線枠や送信先選択画面を復元してはいけません。")
        }
    }
}
