import XCTest

final class CompactLibraryNavigationTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--compact-library-ui-test", "--list-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["library-location-picker"].waitForExistence(timeout: 20))
        return app
    }

    private func openLibrary(_ app: XCUIApplication) {
        let picker = app.buttons["library-location-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertTrue(app.buttons["library-category-documents"].waitForExistence(timeout: 5))
    }

    func testEachCategoryAndRepeatedSelectionReturnsToTheList() {
        let app = launch()
        for category in ["favorites", "favorites", "pdfs", "studyCards", "textDocuments", "trash", "documents", "documents"] {
            openLibrary(app)
            app.buttons["library-category-\(category)"].tap()
            XCTAssertTrue(app.buttons["library-location-picker"].waitForExistence(timeout: 5), category)
            XCTAssertTrue(app.buttons["library-location-picker"].isHittable, category)
            if category == "favorites" {
                XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 5))
                let emptyState = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "お気に入りはありません")).firstMatch
                XCTAssertTrue(emptyState.waitForExistence(timeout: 5), app.debugDescription)
            }
        }
    }

    func testFolderSelectionShowsContentsAndReturningFromANoteKeepsFolder() {
        let app = launch()
        openLibrary(app)
        app.buttons["library-sidebar-folder-Parent"].tap()
        XCTAssertTrue(app.buttons["library-location-picker"].waitForExistence(timeout: 5))
        let note = app.staticTexts["Parent note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 5))
        app.buttons["ホームへ戻る"].tap()
        XCTAssertTrue(app.buttons["library-location-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Parent"].waitForExistence(timeout: 5))
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        openLibrary(app)
        app.buttons["library-sidebar-folder-Parent"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
    }
}
