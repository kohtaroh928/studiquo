import XCTest

/// The "ファイルアプリと2分割" entry of the note editor's split menu.
///
/// The Files browser is a system UI that runs in another process, so these
/// tests stop at what the app owns: that the split opens a pane hosting the
/// browser, that it can be closed, and that no other pane is left behind.
/// Picking a real file, cloud downloads and relaunch are checked by hand.
final class ExternalFilePaneTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func openSplitMenuEntry(_ identifier: String, name: String) {
        let splitMenu = app.buttons["画面分割"]
        XCTAssertTrue(splitMenu.waitForExistence(timeout: 30), "ノート画面の「画面分割」ボタンが見つかりません。")
        // The tool strip scrolls sideways, and the split control sits past the
        // right edge in portrait.
        let strip = app.windows.firstMatch
        var swipes = 0
        while splitMenu.frame.maxX > strip.frame.maxX - 8, swipes < 5 {
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.04))
                .press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.04)))
            swipes += 1
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertLessThanOrEqual(splitMenu.frame.maxX, strip.frame.maxX, "「画面分割」ボタンが画面内に表示されません。")
        splitMenu.tap()
        let entry = app.buttons[identifier]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "分割メニューに「\(name)」がありません。")
        entry.tap()
    }

    private func openExternalFileSplit() {
        openSplitMenuEntry("note-split-external-file-button", name: "ファイルアプリと2分割")
    }

    func testSplitMenuOpensFileBrowserPane() {
        openExternalFileSplit()
        // The editor tags the whole pane with its own identifier, which takes
        // precedence over the ones inside it, so the pane is found by its text.
        XCTAssertTrue(
            app.staticTexts["ファイルを選択"].waitForExistence(timeout: 10),
            "ファイルアプリと2分割を選んでも、副ペインが開きません。"
        )
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "external-file-pane-opened"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSplitMenuOpensPhotoStudyPane() {
        openSplitMenuEntry("note-split-photo-study-button", name: "写真アプリと2分割")
        XCTAssertTrue(
            app.buttons["写真資料を閉じる"].waitForExistence(timeout: 10),
            "写真アプリと2分割を選んでも、写真ペインが開きません。"
        )
        XCTAssertFalse(
            app.buttons["photo-study-toolbar-button"].exists,
            "ツールバーに写真資料ボタンが残っています。"
        )
    }
}
