import XCTest

/// Verifies that split-pane tools use the same direct pane-tap selection as
/// tabs, rather than silently choosing a side for the student.
final class PaneTapSelectionTests: XCTestCase {
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
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testAIChatOpensInThePrimaryPaneTheStudentTaps() {
        let split = app.buttons["画面分割"]
        XCTAssertTrue(split.waitForExistence(timeout: 20))
        split.tap()

        let files = app.buttons["ファイルアプリと2分割"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()

        let ai = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(ai.waitForExistence(timeout: 10))
        ai.tap()

        let primaryPicker = app.descendants(matching: .any)["pane-pick-primary"].firstMatch
        XCTAssertTrue(primaryPicker.waitForExistence(timeout: 5), "AIトーク後にペイン選択を求めませんでした。")
        primaryPicker.tap()

        let chat = app.descendants(matching: .any)["note-ai-swapped-pane"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "選択したペインにAIトークが開きませんでした。")
        XCTAssertLessThan(chat.frame.midY, app.windows.firstMatch.frame.midY, "上のペインをタップしたのにAIトークが下に開いています。")
    }
}
