import XCTest

/// The launch screen must always tell the person what is going on: a slow
/// store open shows a notice and then continues, and a failed one shows the
/// failure with a retry that works.
final class StartupLoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--startup-ui-test"] + arguments
        app.launch()
        return app
    }

    func testSlowStoreOpenShowsTheNoticeAndThenReachesHome() {
        let app = launch(["--startup-slow"])

        let notice = app.staticTexts["データの読み込みに時間がかかっています"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "The slow-launch notice never appeared")
        // Not `buttons["再試行"]`: the home screen has a retry button of its own
        // (the banner for files a share left unimported), so that label is not
        // proof the launch failure screen is showing.
        XCTAssertFalse(app.staticTexts["保存データを開けませんでした"].exists, "A slow open is not a failure")

        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 20), "The app never advanced past the notice")
        XCTAssertFalse(notice.exists)
    }

    func testFailedStoreOpenShowsTheFailureAndRetryReachesHome() {
        let app = launch(["--startup-fail-once"])

        XCTAssertTrue(app.staticTexts["保存データを開けませんでした"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["保存済みのデータは削除されていません。もう一度お試しください。"].exists,
                      "The person must be told their data is safe")
        let retry = app.buttons["再試行"]
        XCTAssertTrue(retry.exists)

        retry.tap()

        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 20), "Retry did not recover")
        XCTAssertFalse(app.staticTexts["保存データを開けませんでした"].exists, "The failure screen is still showing after the retry")
    }
}
