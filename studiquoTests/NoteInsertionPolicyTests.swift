import XCTest
@testable import studiquo

final class NoteInsertionPolicyTests: XCTestCase {
    func testOnlyNotePaneReceivesInsertionEvenWhenOtherPaneWasTouchedLast() {
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .secondary, primaryShowsNote: true, secondaryShowsNote: false),
            .primary
        )
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: false, secondaryShowsNote: true),
            .secondary
        )
    }

    func testLastTouchedNoteWinsWhenBothPanesAreNotes() {
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: true, secondaryShowsNote: true),
            .primary
        )
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .secondary, primaryShowsNote: true, secondaryShowsNote: true),
            .secondary
        )
    }

    func testNoTargetWhenNeitherPaneIsANote() {
        XCTAssertNil(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: false, secondaryShowsNote: false)
        )
        XCTAssertNil(
            NoteInsertionPolicy.targetPane(lastActive: .secondary, primaryShowsNote: false, secondaryShowsNote: false)
        )
    }

    // MARK: - NoteEditorView integration (insertionPage, canInsertIntoNote, noteToolPane)

    private func noteEditorViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/NoteEditorView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sliceFunction(_ signature: String, until nextMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "関数が見つかりません: \(signature)")
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: nextMarker), "終端マーカーが見つかりません: \(nextMarker)")
        return String(rest[..<end.lowerBound])
    }

    func testAllInsertionToolsRouteThroughInsertionPageAndUpdateTargetNotebook() throws {
        let source = try noteEditorViewSource()

        // 1. AI回答のノート挿入
        let aiInsert = try sliceFunction(
            "private func insertAIResponseOnPage(_ text: String)",
            until: "private func attachmentFor",
            in: source
        )
        XCTAssertTrue(
            aiInsert.contains("let page = insertionPage"),
            "AI回答の挿入は insertionPage を対象にする必要があります。"
        )
        XCTAssertFalse(
            aiInsert.contains("currentPrimaryPage"),
            "AI回答の挿入が currentPrimaryPage を参照すると、分割時の対象ペイン制御と食い違います。"
        )

        // 2. テキスト要素の挿入
        let textInsert = try sliceFunction(
            "private func addTextElement()",
            until: "private func addRecognizedTextElement",
            in: source
        )
        XCTAssertTrue(
            textInsert.contains("guard let page = insertionPage else { return }"),
            "テキスト追加は insertionPage を対象にする必要があります。"
        )
        XCTAssertTrue(
            textInsert.contains("page.notebook?.updatedAt = .now"),
            "テキスト追加時は固定の notebook ではなく、挿入先 page.notebook の updatedAt を更新する必要があります。"
        )

        // 3. 写真要素の挿入
        let imageInsert = try sliceFunction(
            "private func addImageElement(from data: Data) async",
            until: "private func applyBackgroundImage",
            in: source
        )
        XCTAssertTrue(
            imageInsert.contains("guard let page = insertionPage else { return }"),
            "写真追加は insertionPage を対象にする必要があります。"
        )
        XCTAssertTrue(
            imageInsert.contains("page.notebook?.updatedAt = .now"),
            "写真追加時は挿入先 page.notebook の updatedAt を更新する必要があります。"
        )
        XCTAssertTrue(
            imageInsert.contains(".studiquoSelectPageElement"),
            "写真追加後は追加した要素を選択状態にする通知を送る必要があります。"
        )

        // 4. 図形・暗記テープの挿入
        let shapeInsert = try sliceFunction(
            "private func addShapeElement(_ kind: PageElementKind)",
            until: "private func addPageLink",
            in: source
        )
        XCTAssertTrue(
            shapeInsert.contains("guard let page = insertionPage else { return }"),
            "図形・暗記テープ追加は insertionPage を対象にする必要があります。"
        )
        XCTAssertTrue(
            shapeInsert.contains("page.notebook?.updatedAt = .now"),
            "図形・暗記テープ追加時は挿入先 page.notebook の updatedAt を更新する必要があります。"
        )

        // 5. ページリンクの挿入
        let linkInsert = try sliceFunction(
            "private func addPageLink(to pageIndex: Int, title: String)",
            until: "private func nextLayerIndex",
            in: source
        )
        XCTAssertTrue(
            linkInsert.contains("guard let page = insertionPage else { return }"),
            "ページリンク追加は insertionPage を対象にする必要があります。"
        )
        XCTAssertTrue(
            linkInsert.contains("page.notebook?.updatedAt = .now"),
            "ページリンク追加時は挿入先 page.notebook の updatedAt を更新する必要があります。"
        )
    }

    func testInsertionToolbarButtonsDependOnCanInsertIntoNote() throws {
        let source = try noteEditorViewSource()
        let toolbarSlice = try sliceFunction(
            "Button { addShapeElement(.studyTape) }",
            until: "private var drawingTool",
            in: source
        )
        XCTAssertTrue(
            toolbarSlice.contains("isActive: pendingShapeKindRaw != \"\" && canInsertIntoNote")
                && toolbarSlice.contains(".disabled(!canInsertIntoNote)"),
            "図形・テキスト・写真のツールバーボタンは canInsertIntoNote に連動して有効/無効を切り替える必要があります。"
        )
    }

    func testPaneShowsNoteExcludesAllNonNoteOverlaysAndModes() throws {
        let source = try noteEditorViewSource()
        let paneShowsNoteBody = try sliceFunction(
            "private func paneShowsNote(_ pane: ActivePane) -> Bool",
            until: "private var insertionPane: ActivePane?",
            in: source
        )
        for condition in [
            "splitMode != .single",
            "let secondaryNotebook",
            "secondaryFlashcardDeck == nil",
            "!secondaryShowsWeb",
            "!secondaryShowsAIChat",
            "photoStudyPane != .secondary",
            "aiSwapPane != .secondary",
            "primaryFlashcardDeck == nil",
            "!primaryShowsWeb",
            "!primaryShowsAIChat",
            "primaryChatTarget == nil",
            "primaryTemporaryChatMaterial == nil",
            "photoStudyPane != .primary",
            "aiSwapPane != .primary",
        ] {
            XCTAssertTrue(
                paneShowsNoteBody.contains(condition),
                "paneShowsNote は非ノート表示条件 (\(condition)) を除外する必要があります。"
            )
        }
    }

    func testNoteToolPaneFallsBackToOtherPaneWhenActivePaneIsNotANote() throws {
        let source = try noteEditorViewSource()
        let noteToolSlice = try sliceFunction(
            "private var noteToolPane: ActivePane?",
            until: "private func trashPendingNotebook()",
            in: source
        )
        XCTAssertTrue(
            noteToolSlice.contains("if paneShowsNote(activePane) { return activePane }")
                && noteToolSlice.contains("return paneShowsNote(otherPane) ? otherPane : nil"),
            "noteToolPane は選択中のペインがノートでない場合、もう一方のノートペインへフォールバックする必要があります。"
        )
        XCTAssertTrue(
            noteToolSlice.contains("noteToolPane == .secondary ? $secondaryPageIndex : $primaryPageIndex")
                && noteToolSlice.contains("let deletedIndex = noteToolPane == .secondary ? secondaryPageIndex : primaryPageIndex"),
            "ページ操作(activePageIndexBinding / deleteCurrentPage)は activePane ではなく noteToolPane を見る必要があります。"
        )
    }

    // MARK: - 分割時のペインタップ選択の統一と排他制御(pendingPaneTarget / pendingAIChatPaneSwap / pendingChatPaneTarget)

    func testPanePickOverlayHandlesAllThreePendingSelectionSourcesAndClearButton() throws {
        let source = try noteEditorViewSource()
        let overlaySlice = try sliceFunction(
            "private func panePickOverlay(for pane: ActivePane) -> some View",
            until: "private enum PaneBodyKind",
            in: source
        )
        XCTAssertTrue(
            overlaySlice.contains("if pendingPaneTarget != nil || pendingAIChatPaneSwap || pendingChatPaneTarget != nil"),
            "panePickOverlay はタブ選択・AIトーク・フレンド/グループチャットの3種類すべてのペイン選択待ちで表示される必要があります。"
        )
        XCTAssertTrue(
            overlaySlice.contains("Button(\"キャンセル\") { clearPendingPaneSelection() }"),
            "キャンセルボタンは clearPendingPaneSelection() で全種類の選択待ちを一括クリアする必要があります。"
        )
        XCTAssertTrue(
            overlaySlice.contains("if let target = pendingPaneTarget")
                && overlaySlice.contains("else if pendingAIChatPaneSwap")
                && overlaySlice.contains("else if let target = pendingChatPaneTarget")
                && overlaySlice.contains("activePane = pane"),
            "ペインタップ時は保留中のターゲット種別に応じて applyPaneTarget / swapInAIChat / openChat を呼び、activePane を更新する必要があります。"
        )
    }

    func testPendingPaneSelectionsAreMutuallyExclusiveAndClearedOnCollapseOrUndo() throws {
        let source = try noteEditorViewSource()

        // 1. フレンド/グループチャット選択時は他の2つをクリアして pendingChatPaneTarget をセット(同一チャット未表示時のみ)
        let openChatSlice = try sliceFunction(
            "private func openChat(_ target: NoteChatTarget)",
            until: "private func openChat(_ target: NoteChatTarget, in pane: ActivePane)",
            in: source
        )
        XCTAssertTrue(
            openChatSlice.contains("primaryChatTarget != target")
                && openChatSlice.contains("secondaryChatTarget != target")
                && openChatSlice.contains("pendingPaneTarget = nil")
                && openChatSlice.contains("pendingAIChatPaneSwap = false")
                && openChatSlice.contains("pendingChatPaneTarget = target"),
            "2分割中に未表示のチャットを開くときは、既存のタブ/AI選択待ちを消して pendingChatPaneTarget に切り替える必要があります。"
        )

        // 2. AIトーク入れ替え時は他の2つをクリアして pendingAIChatPaneSwap をセット
        let swapAISlice = try sliceFunction(
            "private func swapInAIChat()",
            until: "private func swapInAIChat(in pane: ActivePane)",
            in: source
        )
        XCTAssertTrue(
            swapAISlice.contains("pendingPaneTarget = nil")
                && swapAISlice.contains("pendingChatPaneTarget = nil")
                && swapAISlice.contains("pendingAIChatPaneSwap = true"),
            "2分割中にAIトークを選ぶときは、既存のタブ/チャット選択待ちを消して pendingAIChatPaneSwap に切り替える必要があります。"
        )

        // 3. タブ選択時は他の2つをクリアして pendingPaneTarget をセット
        let routeTabSlice = try sliceFunction(
            "private func routeTabSelection(_ target: PaneSwitchTarget)",
            until: "private func showCitedNotebook",
            in: source
        )
        XCTAssertTrue(
            routeTabSlice.contains("pendingAIChatPaneSwap = false")
                && routeTabSlice.contains("pendingChatPaneTarget = nil")
                && routeTabSlice.contains("pendingPaneTarget = target"),
            "2分割中にタブを選ぶときは、既存のAI/チャット選択待ちを消して pendingPaneTarget に切り替える必要があります。"
        )

        // 4. Undo(restorePaneLayout)と1画面戻し(collapseSplit)の両方で clearPendingPaneSelection() が呼ばれること
        let restoreSlice = try sliceFunction(
            "private func restorePaneLayout(_ layout: PaneLayout)",
            until: "private func performPaneTransition",
            in: source
        )
        XCTAssertTrue(
            restoreSlice.contains("clearPendingPaneSelection()"),
            "レイアウトのUndo/Redo時は clearPendingPaneSelection() でペイン選択待ちを消す必要があります。"
        )
        let collapseSlice = try sliceFunction(
            "private func collapseSplit()",
            until: "private var displayedPrimaryNotebook",
            in: source
        )
        XCTAssertTrue(
            collapseSlice.contains("clearPendingPaneSelection()")
                && collapseSlice.contains("pendingPaneTarget = nil")
                && collapseSlice.contains("pendingAIChatPaneSwap = false")
                && collapseSlice.contains("pendingChatPaneTarget = nil"),
            "1画面へ戻すときは clearPendingPaneSelection() で3つの選択待ち状態をすべてクリアする必要があります。"
        )
    }

    func testApplyTemplateUsesCurrentPrimaryPageAndUpdatesActiveNotebook() throws {
        let source = try noteEditorViewSource()
        let templateSlice = try sliceFunction(
            "private func applyTemplate(_ template: PageTemplate)",
            until: "private var drawingHistoryPage",
            in: source
        )
        XCTAssertTrue(
            templateSlice.contains("guard let page = currentPrimaryPage, page.backgroundImageData == nil else { return }")
                && templateSlice.contains("activeNotebook.updatedAt = .now")
                && templateSlice.contains("guard noteToolPane != nil else { return nil }\n        return activePage"),
            "用紙テンプレート変更はAIチャット選択中も noteToolPane 経由で対象ノートページへ適用され、activeNotebook.updatedAt を更新する必要があります。"
        )
    }

    // MARK: - ページサイドバー整理・ページ番号テンキー・資料切替ボタン配置(PR #86, #87)

    func testPageSidebarInlineKeypadAndSeparatedEditMenuOperations() throws {
        let source = try noteEditorViewSource()
        let sidebarSlice = try sliceFunction(
            "private struct PageSidebar: View",
            until: "private var canDeleteBookmarkedPages: Bool",
            in: source
        )

        // 1. ページ番号テンキーがポップオーバーではなくサイドバー一覧内にインライン展開されること
        XCTAssertFalse(
            sidebarSlice.contains(".popover(isPresented: $showsJumpKeypad"),
            "ページ番号テンキーはポップオーバーではなく、ページ一覧内にインライン表示する必要があります。"
        )
        XCTAssertTrue(
            sidebarSlice.contains("if showsJumpKeypad {\n                pageJumpKeypad")
                && sidebarSlice.contains(".accessibilityLabel(\"ページ番号\")"),
            "showsJumpKeypad == true のとき、一覧上部に pageJumpKeypad がインライン表示される必要があります。"
        )

        // 2. jumpToPage の境界チェックと入力リセット・テンキー閉幕
        XCTAssertTrue(
            sidebarSlice.contains("guard let pageNumber = Int(jumpText), notebook.sortedPages.indices.contains(pageNumber - 1) else { return }")
                && sidebarSlice.contains("currentPageIndex = pageNumber - 1")
                && sidebarSlice.contains("jumpText = \"\"")
                && sidebarSlice.contains("showsJumpKeypad = false"),
            "jumpToPage() は有効範囲(1...ページ数)のときのみ currentPageIndex を更新し、jumpText と showsJumpKeypad をリセットする必要があります。"
        )

        // 3. テンキーの各ボタン(1..9, 0, 消去, 移動, 閉じる)
        XCTAssertTrue(
            sidebarSlice.contains("ForEach([\"1\", \"2\", \"3\", \"4\", \"5\", \"6\", \"7\", \"8\", \"9\"]")
                && sidebarSlice.contains("keypadButton(\"消去\", icon: \"delete.left\")")
                && sidebarSlice.contains("guard !jumpText.isEmpty else { return }\n                    jumpText.removeLast()")
                && sidebarSlice.contains("keypadButton(\"0\") { jumpText.append(\"0\") }")
                && sidebarSlice.contains("keypadButton(\"移動\", icon: \"arrow.right\") { jumpToPage() }")
                && sidebarSlice.contains("Button(\"閉じる\") { showsJumpKeypad = false }"),
            "ページ番号テンキーには 0〜9・空文字ガード付きの消去・移動・閉じるボタンが必要です。"
        )

        // 4. 「編集」メニューで「並べ替え」と「複数選択」が分離されていること
        XCTAssertTrue(
            sidebarSlice.contains("Label(isReorderingPages ? \"並べ替えを終了\" : \"並べ替え\", systemImage: \"arrow.up.arrow.down\")")
                && sidebarSlice.contains("pageListEditMode = startsReordering ? .active : .inactive")
                && sidebarSlice.contains("Label(isSelectingPages ? \"複数選択を終了\" : \"複数選択\", systemImage: \"checkmark.circle\")")
                && sidebarSlice.contains("if !isSelectingPages { selectedPageIDs.removeAll() }"),
            "ページ一覧の「編集」メニューでは「並べ替え」(EditMode連動)と「複数選択」(selectedPageIDs管理)が分離されている必要があります。"
        )
    }

    func testPaneReplaceButtonEmbeddingForNotesAndFriendChatAlignment() throws {
        let source = try noteEditorViewSource()
        let replaceSlice = try sliceFunction(
            "private func paneEmbedsReplaceButton(_ pane: ActivePane) -> Bool",
            until: "private func closeFlashcardPane",
            in: source
        )

        // タイトルバーを持つノート(Secondary、分割中、またはPDFノート)はヘッダー内に埋め込み、1画面の通常ノートだけオーバーレイにする
        XCTAssertTrue(
            replaceSlice.contains("case .note:\n            let notebook = pane == .primary ? displayedPrimaryNotebook : secondaryNotebook\n            return pane == .secondary || splitMode != .single || notebook?.containsPDF == true"),
            "タイトルバーを持つノートペインでは資料切替ボタンをヘッダー内に埋め込み、ページ一覧の開閉に追従させる必要があります。"
        )

        // フレンドチャットはペインヘッダーが無いため、オーバーレイ余白が (8, 8) で右端に揃うこと
        XCTAssertTrue(
            replaceSlice.contains("case .friend:")
                && replaceSlice.contains("return (8, 8)"),
            "フレンドチャット(.friend)の資料切替ボタンはヘッダー無しペインに合わせて (8, 8) の余白に整列する必要があります。"
        )
    }
}
