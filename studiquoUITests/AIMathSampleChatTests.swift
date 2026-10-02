import XCTest

/// Plumbing for the AI-math rendering work: the fake AI can be asked for any
/// sample in the shared corpus (`AIMathSamples`) by typing `sample:<id>`, and
/// answers it a few characters at a time like a streamed reply. The rendering
/// tests in later steps are built on this.
final class AIMathSampleChatTests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testTheFakeAIRepliesWithTheRequestedSample() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
        app.buttons["home-tab-ai"].tap()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !(app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists) {
            Thread.sleep(forTimeInterval: 0.3)
        }
        let draft = app.textViews["ai-chat-draft"].exists ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
        draft.tap()
        draft.typeText("sample:quadratic-formula")
        app.buttons["ai-chat-send"].tap()

        // The sample's own words, whatever the screen does with its LaTeX.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "解の公式")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "サンプルの返答が表示されません。")
    }
}
