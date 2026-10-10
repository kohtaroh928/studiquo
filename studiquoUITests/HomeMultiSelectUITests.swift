import XCTest

/// Multi-select on the home screen: selecting, "全てを選択"/"選択を解除", moving
/// through the folder-hierarchy picker, deleting with a confirmation, and
/// restoring from the trash. Uses the same seeded library as the drop tests.
final class HomeMultiSelectUITests: XCTestCase {
    private func launch(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test"] + extraArguments
        app.launch()
        return app
    }

    private func selectionAction(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var begin = app.buttons["library-selection-begin"]
        // iPad's native toolbar overflow contains the same selection action
        // when portrait width cannot display every trailing item.
        if !begin.waitForExistence(timeout: 2) || !begin.isHittable {
            let overflow = app.buttons["OverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 10), "ツールバーの追加操作が表示されません", file: file, line: line)
            overflow.tap()
            // UIKit's native menu retains the action label, but not the
            // SwiftUI toolbar item's custom accessibility identifier.
            begin = app.buttons["選択"]
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 15), "「選択」ボタンが表示されません", file: file, line: line)
        return begin
    }

    private func beginSelecting(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        selectionAction(in: app, file: file, line: line).tap()
        XCTAssertTrue(
            selectionCount(app).waitForExistence(timeout: 5),
            "選択モードに入れません", file: file, line: line
        )
    }

    private func select(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.descendants(matching: .any)["library-select-\(title)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(title) を選択できる状態になりません", file: file, line: line)
        target.tap()
    }

    /// The navigation title doubles as the "n件選択中" counter.
    private func selectionCount(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d+件選択中")).firstMatch
    }

    private func countLabel(_ app: XCUIApplication) -> String {
        selectionCount(app).label
    }

    func testSelectAllAndDeselectAll() {
        let app = launch()
        beginSelecting(in: app)
        XCTAssertEqual(countLabel(app), "0件選択中")

        app.buttons["library-selection-select-all"].tap()
        XCTAssertNotEqual(countLabel(app), "0件選択中", "「全てを選択」で何も選ばれません")

        app.buttons["library-selection-deselect-all"].tap()
        XCTAssertEqual(countLabel(app), "0件選択中")

        app.buttons["library-selection-done"].tap()
        XCTAssertTrue(selectionAction(in: app).waitForExistence(timeout: 5))
    }

    func testTappingAnItemTogglesItInsteadOfOpeningIt() {
        let app = launch()
        beginSelecting(in: app)

        select("Drag me", in: app)
        XCTAssertEqual(countLabel(app), "1件選択中")
        select("Drag me", in: app)
        XCTAssertEqual(countLabel(app), "0件選択中")
        XCTAssertFalse(app.buttons["ホームへ戻る"].exists, "選択モード中に資料が開いてしまいました")
    }

    func testSelectionIsKeptWhenOpeningAFolder() {
        let app = launch()
        beginSelecting(in: app)
        select("Drag me", in: app)

        let open = app.buttons["library-open-Parent"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "フォルダを開く「›」ボタンがありません")
        open.tap()

        XCTAssertTrue(selectionCount(app).waitForExistence(timeout: 5))
        XCTAssertEqual(countLabel(app), "1件選択中", "フォルダへ入ると選択が消えました")
    }

    func testSelectedItemsMoveThroughFolderHierarchyPicker() {
        let app = launch()
        beginSelecting(in: app)
        select("Drag me", in: app)
        select("Other one", in: app)
        XCTAssertEqual(countLabel(app), "2件選択中")

        app.buttons["library-selection-move"].tap()
        let parent = app.descendants(matching: .any)["library-move-folder-Parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5), "移動先のフォルダ階層が表示されません")
        parent.tap()
        let destination = app.descendants(matching: .any)["library-move-folder-Parent/Destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "下の階層が表示されません")
        destination.tap()
        let here = app.buttons["library-move-here"]
        XCTAssertTrue(here.waitForExistence(timeout: 5))
        here.tap()

        XCTAssertFalse(
            app.descendants(matching: .any)["library-entry-Drag me"].waitForExistence(timeout: 3),
            "移動した資料がホームに残っています"
        )
        XCTAssertTrue(selectionAction(in: app).waitForExistence(timeout: 5), "移動後に選択モードが終わっていません")

        // Dismiss the native overflow menu exposed by the end-state check.
        if app.buttons["選択"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).tap()
        }
        app.buttons["library-folder-Parent"].tap()
        app.buttons["library-folder-Parent/Destination"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Drag me"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Other one"].exists)
    }

    func testDeleteAsksForConfirmationThenTrashAndRestoreWork() {
        let app = launch()
        beginSelecting(in: app)
        select("Other one", in: app)
        app.buttons["library-selection-delete"].tap()

        // The confirmation names the action; nothing is trashed before it.
        let confirm = app.buttons["ゴミ箱に移動"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "削除の確認が表示されません")
        XCTAssertTrue(app.descendants(matching: .any)["library-select-Other one"].exists, "確認前に削除されています")
        confirm.tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["library-entry-Other one"].waitForExistence(timeout: 3),
            "ゴミ箱へ移した資料が一覧に残っています"
        )

        // In the trash the same selection offers restore instead of move.
        app.buttons["ゴミ箱"].firstMatch.tap()
        beginSelecting(in: app)
        XCTAssertFalse(app.buttons["library-selection-move"].exists, "ゴミ箱に「移動」が出ています")
        select("Other one", in: app)
        app.buttons["library-selection-restore"].tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["library-select-Other one"].waitForExistence(timeout: 3),
            "復元した資料がゴミ箱に残っています"
        )

        app.buttons["すべて"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Other one"].waitForExistence(timeout: 5))
    }

    func testDeletingAFolderMovesItsContentsToTheTrash() {
        let app = launch()
        beginSelecting(in: app)
        select("Parent", in: app)
        app.buttons["library-selection-delete"].tap()

        let confirm = app.buttons["削除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "フォルダ削除の確認が表示されません")
        confirm.tap()

        XCTAssertFalse(
            app.buttons["library-folder-Parent"].waitForExistence(timeout: 3),
            "削除したフォルダが残っています"
        )

        app.buttons["ゴミ箱"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library-entry-Parent note"].waitForExistence(timeout: 5),
            "フォルダ内の資料がゴミ箱に入っていません"
        )
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Source note"].exists)
    }

    // MARK: Swipe to trash on a folder row

    private func folderSurface(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let folder = app.descendants(matching: .any)["library-folder-\(name)"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15), "フォルダ「\(name)」が表示されません")
        return folder
    }

    func testSwipingAFolderRowLeftRevealsTheTrashButtonAndMovesTheWholeRow() {
        let app = launch()
        let folder = folderSurface("Sibling", in: app)
        let restingX = folder.frame.minX
        let trash = app.buttons["library-folder-trash-Sibling"]
        XCTAssertFalse(trash.isHittable, "スワイプ前にゴミ箱ボタンが見えています")

        folder.swipeLeft()

        XCTAssertTrue(trash.waitForExistence(timeout: 3), "左スワイプでゴミ箱ボタンが出ません")
        XCTAssertLessThan(folder.frame.minX, restingX - 40, "行の中身だけでなく、行全体が左へ動く必要があります")
    }

    func testSwipingAFolderRowRightClosesAnOpenRow() {
        let app = launch()
        let folder = folderSurface("Sibling", in: app)
        let restingX = folder.frame.minX
        folder.swipeLeft()
        XCTAssertLessThan(folder.frame.minX, restingX - 40)

        folder.swipeRight()

        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(folder.frame.minX - restingX) < 2 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed, "右スワイプで行が元の位置に戻りません")
    }

    func testTappingTheSwipeTrashButtonMovesTheFolderContentsToTheTrash() {
        let app = launch()
        let folder = folderSurface("Parent", in: app)
        folder.swipeLeft()

        let trash = app.buttons["library-folder-trash-Parent"]
        XCTAssertTrue(trash.waitForExistence(timeout: 3), "左スワイプでゴミ箱ボタンが出ません")
        trash.tap()

        XCTAssertFalse(
            app.descendants(matching: .any)["library-folder-Parent"].waitForExistence(timeout: 3),
            "ゴミ箱へ送ったフォルダが残っています"
        )

        app.buttons["ゴミ箱"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library-entry-Parent note"].waitForExistence(timeout: 5),
            "フォルダ内の資料がゴミ箱に入っていません"
        )
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Source note"].exists)
    }

    func testVerticalScrollingDoesNotOpenAFolderRow() {
        let app = launch()
        let folder = folderSurface("Sibling", in: app)
        let restingX = folder.frame.minX

        let start = folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 4, dy: -80)))

        XCTAssertFalse(app.buttons["library-folder-trash-Sibling"].isHittable, "縦スクロールでゴミ箱ボタンが出ています")
        XCTAssertEqual(folder.frame.minX, restingX, accuracy: 2)
    }

    func testSelectionWorksInIconAndColumnModes() {
        for mode in ["--icon-mode", "--column-mode"] {
            let app = launch([mode])
            beginSelecting(in: app)
            select("Drag me", in: app)
            XCTAssertEqual(countLabel(app), "1件選択中", "\(mode) で選択できません")
            app.terminate()
        }
    }
}
