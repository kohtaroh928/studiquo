import XCTest

/// 資料の上のタブが、ノート・暗記帳・文書のどれを開いても同じ高さにあること。
/// 暗記帳だけナビゲーションバーが残り、タブが下に押し下げられていた。
final class TabBarPositionTests: XCTestCase {
    func testTabStripStaysAtTheSameHeightForNoteDeckAndDocument() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--list-mode"]
        app.launch()

        let note = app.descendants(matching: .any)["library-entry-Drag me"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        let addTab = app.buttons["tab-picker-add-tab"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 10))
        let noteTabY = addTab.frame.minY

        func openFromPicker(_ title: String) {
            addTab.tap()
            let item = app.descendants(matching: .any)["split-source-item-\(title)"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), title)
            item.tap()
        }

        openFromPicker("Cards")
        XCTAssertTrue(app.staticTexts["ホームへ戻る"].waitForExistence(timeout: 10))
        XCTAssertEqual(addTab.frame.minY, noteTabY, accuracy: 1, "暗記帳のタブがノートより下にあります。")

        openFromPicker("Document")
        XCTAssertTrue(app.staticTexts["ホームへ戻る"].waitForExistence(timeout: 10))
        XCTAssertEqual(addTab.frame.minY, noteTabY, accuracy: 1, "文書のタブがノートと違う高さです。")
    }
}
