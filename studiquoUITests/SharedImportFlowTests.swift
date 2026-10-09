import XCTest

/// The whole "files arrive from outside → pick a destination → import" flow,
/// as the student sees it. The inbox is seeded (`--ui-test-seed-shared-inbox`)
/// with one held leftover (`held-leftover.pdf`) and one new share of four files:
/// `lecture-a.pdf` and `lecture-b.pdf` (good), `broken.pdf` (not a real PDF) and
/// `notes.xyz` (a format the library cannot import).
///
/// Each test pins down one of the reported failures:
/// - a leftover from an earlier failure was silently pulled into the next import;
/// - a file that could not be imported was kept forever with no way to see it,
///   retry it or throw it away;
/// - a file that failed made the batch stop, or silently count as imported.
final class SharedImportFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-seed-shared-inbox"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    private func containing(_ text: String) -> NSPredicate { NSPredicate(format: "label CONTAINS %@", text) }

    private var confirm: XCUIElement { app.buttons["share-destination-confirm"] }
    private var resultAlert: XCUIElement { app.alerts["取り込み結果"] }
    /// The held-files banner, found by its retry button: an identifier set on a
    /// SwiftUI container is not reliably exposed as an element of its own.
    private var heldBanner: XCUIElement { app.buttons["shared-import-retry"] }

    private func waitForPicker() {
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the destination picker should open for the new share")
    }

    /// Picks the fixture's "Target" folder and imports there.
    private func importIntoTarget() {
        waitForPicker()
        // By identifier: a plain "Target" search also finds the library's own
        // folder rows behind the sheet, which cannot be tapped.
        let target = app.buttons["share-destination-folder-Target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        confirm.tap()
    }

    private func dismissResultAlert() {
        XCTAssertTrue(resultAlert.waitForExistence(timeout: 30), "the import result should be reported once it ends")
        resultAlert.buttons["OK"].tap()
    }

    // MARK: The new share, and only the new share

    func testTheNewShareIsOfferedOnItsOwnWithoutTheHeldLeftover() {
        waitForPicker()
        XCTAssertTrue(app.staticTexts["4件のファイルを、ここに取り込みます。"].exists,
                      "4 new files — the held leftover must not be counted in")
        XCTAssertFalse(app.staticTexts["5件のファイルを、ここに取り込みます。"].exists)
    }

    func testImportingGoesIntoTheChosenFolderAndLeavesTheLeftoverAlone() {
        importIntoTarget()
        dismissResultAlert()

        XCTAssertTrue(app.staticTexts["lecture-a"].waitForExistence(timeout: 10), "imported into the chosen folder")
        XCTAssertTrue(app.staticTexts["lecture-b"].exists)
        XCTAssertFalse(app.staticTexts["held-leftover"].exists, "the leftover must not be imported with an unrelated share")
        XCTAssertFalse(app.staticTexts["broken"].exists, "a file that is not a PDF must not become an empty notebook")
    }

    // MARK: A failure is reported once, and does not stop the rest

    func testTheResultNamesWhatCouldNotBeImportedAndWhy() {
        importIntoTarget()
        XCTAssertTrue(resultAlert.waitForExistence(timeout: 30))
        XCTAssertTrue(resultAlert.staticTexts.containing(containing("2件を取り込みました")).firstMatch.exists,
                      "both good PDFs imported even though another file in the batch failed")
        XCTAssertTrue(resultAlert.staticTexts.containing(containing("broken.pdf")).firstMatch.exists)
        XCTAssertTrue(resultAlert.staticTexts.containing(containing("notes.xyz")).firstMatch.exists)
        resultAlert.buttons["OK"].tap()
    }

    // MARK: What was not imported stays visible, and can be retried or discarded

    func testWhatCouldNotBeImportedIsKeptAsAHeldBannerWithRetryAndDiscard() {
        importIntoTarget()
        dismissResultAlert()

        XCTAssertTrue(heldBanner.waitForExistence(timeout: 10),
                      "the held leftover and the broken file must stay visible, not vanish or linger invisibly")
        XCTAssertTrue(app.staticTexts.containing(containing("取り込めなかったファイルが2件あります")).firstMatch.exists)
        XCTAssertTrue(app.buttons["shared-import-retry"].exists)
        XCTAssertTrue(app.buttons["shared-import-discard"].exists)
    }

    func testRetryOffersOnlyTheHeldFiles() {
        importIntoTarget()
        dismissResultAlert()
        XCTAssertTrue(heldBanner.waitForExistence(timeout: 10))

        app.buttons["shared-import-retry"].tap()
        waitForPicker()
        XCTAssertTrue(app.staticTexts["2件のファイルを、ここに取り込みます。"].exists,
                      "retry covers exactly the 2 held files")
    }

    func testDiscardingRemovesTheHeldFilesAfterConfirmation() {
        importIntoTarget()
        dismissResultAlert()
        XCTAssertTrue(heldBanner.waitForExistence(timeout: 10))

        app.buttons["shared-import-discard"].tap()
        let confirmDiscard = app.buttons["2件を破棄"]
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5), "discarding must ask first")
        confirmDiscard.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: heldBanner)
        waitForExpectations(timeout: 10)
    }

    func testCancellingKeepsTheFilesAsAHeldBannerInsteadOfLosingThem() {
        waitForPicker()
        app.buttons["キャンセル"].firstMatch.tap()

        XCTAssertTrue(heldBanner.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(containing("取り込めなかったファイルが5件あります")).firstMatch.exists,
                      "all 5 files are kept: 4 just cancelled plus the earlier leftover")
    }
}
