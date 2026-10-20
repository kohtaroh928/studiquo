import XCTest

/// ホーム画面のアイコン表示・カラム表示で、PDFのアイコンが1ページ目になること。
final class LibraryPDFCoverTests: XCTestCase {
    private func launch(mode: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--home-pdf-cover", "--\(mode)-mode"]
        app.launch()
        return app
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func assertCoversAreShown(_ app: XCUIApplication, in mode: String) {
        XCTAssertTrue(
            element(app, "notebook-cover-image-表紙つきPDF").waitForExistence(timeout: 20),
            "\(mode): PDFのアイコンが1ページ目になっていません。"
        )
        XCTAssertTrue(
            element(app, "notebook-cover-placeholder-保護されたPDF").waitForExistence(timeout: 5),
            "\(mode): 保護されたPDFは記号のままであるべきです。"
        )
        XCTAssertFalse(element(app, "notebook-cover-image-保護されたPDF").exists, "\(mode): 保護されたPDFの1ページ目が見えています。")
        XCTAssertFalse(element(app, "notebook-cover-image-Drag me").exists, "\(mode): 普通のノートに表紙は付きません。")
        XCTAssertFalse(element(app, "notebook-cover-placeholder-Drag me").exists, "\(mode): 普通のノートは自身の記号のままです。")
    }

    func testIconModeShowsThePDFsFirstPage() {
        assertCoversAreShown(launch(mode: "icon"), in: "アイコン")
    }

    func testColumnModeShowsThePDFsFirstPage() {
        assertCoversAreShown(launch(mode: "column"), in: "カラム")
    }

    /// サイドバーで「PDF」に絞ると、リスト表示でもPDFのアイコンが1ページ目になる。
    func testPDFFilterListShowsTheFirstPageAndAllFilesListKeepsTheSymbol() {
        let app = launch(mode: "list")
        let sidebarPDF = app.buttons["PDF"].firstMatch
        XCTAssertTrue(sidebarPDF.waitForExistence(timeout: 20), "サイドバーに「PDF」がありません。")
        XCTAssertTrue(element(app, "library-entry-表紙つきPDF").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "notebook-cover-image-表紙つきPDF").exists, "「すべて」のリストは記号のままです。")

        sidebarPDF.tap()
        assertCoversAreShown(app, in: "PDFに絞ったリスト")
    }
}
