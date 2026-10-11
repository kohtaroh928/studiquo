import XCTest

/// The floating AIトーク panel reopens where it was left: its centre and size
/// are stored as fractions of the editor, so they survive the editor being
/// closed and the app relaunched, and they are clamped back inside whatever
/// window the next launch has.
///
/// `--note-ai-chat-reset-frame` clears the stored frame at launch; relaunches
/// in the same test leave it out so the stored frame is what gets read back.
final class NoteAIChatFloatingFrameTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Helpers

    private func launch(reset: Bool, orientation: UIDeviceOrientation = .portrait) throws {
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test"] + (reset ? ["--note-ai-chat-reset-frame"] : [])
        app.launch()
        XCTAssertTrue(aiButton.waitForExistence(timeout: 30), "AIトークのボタンが表示されません。")
        let wantsLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if (frame.width > frame.height) == wantsLandscape { return }
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw XCTSkip("このシミュレータは向きを変えられません。")
    }

    private var aiButton: XCUIElement { app.buttons["note-ai-toolbar-button"] }
    private var panel: XCUIElement { app.descendants(matching: .any)["note-ai-floating-panel"].firstMatch }

    private func settle() { Thread.sleep(forTimeInterval: 1.5) }

    /// Splits with the Files browser, then opens the floating panel.
    private func openFloating() {
        let menu = app.buttons["画面分割"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let files = app.buttons["ファイルアプリと2分割"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        settle()
        openFloatingFromMenu()
    }

    /// In a split the button swaps the chat into a pane; the floating panel
    /// comes from the long-press menu.
    private func openFloatingFromMenu() {
        aiButton.press(forDuration: 1.2)
        let item = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "臨時画面で開く", "note-ai-floating-to-pane"
        )).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "長押しメニューに「臨時画面で開く」がありません。")
        item.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "臨時画面が開きません。")
        settle()
    }

    private func reopenFloating() {
        // 分割は起動のたびに作り直し。
        openFloating()
    }

    private var windowFrame: CGRect { app.windows.firstMatch.frame }

    /// Drags the panel by its header. The grab point is the "AIトーク" title
    /// at the left of the header, which is part of the drag area.
    private func dragPanel(by delta: CGVector) {
        // The panel's own coordinate space, so a window that does not start at
        // the screen origin cannot shift the grab point off the header.
        let start = panel.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: 22))
        let end = start.withOffset(delta)
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        settle()
    }

    private func resizePanel(by delta: CGVector) {
        let handle = app.descendants(matching: .any)["AIトークの大きさを変更"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "大きさを変えるつまみがありません。")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(delta), withVelocity: .slow, thenHoldForDuration: 0.5)
        settle()
    }

    private func assertSame(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 3, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: Cases

    func testFirstOpenSitsInTheBottomRightCornerInsideTheWindow() throws {
        try launch(reset: true)
        openFloating()
        let frame = panel.frame
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(frame), "初回の位置が画面からはみ出しています: \(frame)")
        XCTAssertGreaterThan(frame.midX, windowFrame.midX, "初回は右寄りに出るはずです。")
        XCTAssertGreaterThan(frame.midY, windowFrame.midY, "初回は下寄りに出るはずです。")
    }

    func testDraggingMovesThePanelAndItReopensThereInTheSameSession() throws {
        try launch(reset: true)
        openFloating()
        let before = panel.frame
        dragPanel(by: CGVector(dx: -200, dy: -250))
        let moved = panel.frame
        XCTAssertLessThan(moved.minX, before.minX - 100, "ドラッグで左へ動きません。(before=\(before), moved=\(moved), window=\(windowFrame))")
        XCTAssertLessThan(moved.minY, before.minY - 100, "ドラッグで上へ動きません。")

        // 閉じて開き直しても、このセッションで置いた位置が優先される。
        app.buttons["xmark.circle.fill"].firstMatch.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "臨時画面が閉じません。")
        settle()
        openFloatingFromMenu()
        assertSame(panel.frame, moved, "開き直すと位置が変わっています。")
    }

    func testPositionSurvivesARelaunch() throws {
        try launch(reset: true)
        openFloating()
        let before = panel.frame
        dragPanel(by: CGVector(dx: -220, dy: -260))
        let saved = panel.frame
        XCTAssertLessThan(saved.minX, before.minX - 100, "ドラッグで動いていないため、復元の確認になりません。")
        app.terminate()

        try launch(reset: false)
        reopenFloating()
        assertSame(panel.frame, saved, "再起動後に前回の位置へ戻っていません。")
    }

    func testResizedSizeSurvivesARelaunch() throws {
        try launch(reset: true)
        openFloating()
        let before = panel.frame
        resizePanel(by: CGVector(dx: -120, dy: -140))
        let resized = panel.frame
        XCTAssertLessThan(resized.width, before.width - 40, "つまみで幅が変わりません。")
        XCTAssertLessThan(resized.height, before.height - 40, "つまみで高さが変わりません。")
        app.terminate()

        try launch(reset: false)
        reopenFloating()
        assertSame(panel.frame, resized, "再起動後に前回の大きさへ戻っていません。")
    }

    func testDraggingFarOutsideStaysInsideTheWindow() throws {
        try launch(reset: true)
        openFloating()
        let start = panel.frame
        dragPanel(by: CGVector(dx: -2000, dy: -2000))
        XCTAssertLessThan(panel.frame.minX, start.minX - 50, "ドラッグで動いていないため、範囲内の確認になりません。")
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(panel.frame), "左上へ大きく動かして画面外に出ました: \(panel.frame)")
        dragPanel(by: CGVector(dx: 2000, dy: 2000))
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(panel.frame), "右下へ大きく動かして画面外に出ました: \(panel.frame)")
    }
}
