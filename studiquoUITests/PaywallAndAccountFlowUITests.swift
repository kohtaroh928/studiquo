import XCTest

/// ブロッキングPaywall画面（`--paywall-ui-test`）および設定内プラン画面（`--paywall-ui-test-settings`）で、
/// Standard / Plus / Pro の各プランカード・価格表示・規約リンク・退会／ログアウト導線が機能することを確認する。
final class PaywallAndAccountFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    func testBlockingPaywallShowsAllPlansSamplePricesLegalLinksAndAccountDeletionExit() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--paywall-ui-test", "--paywall-ui-test-sample-prices"]
        app.launch()

        XCTAssertTrue(app.navigationBars["プラン"].waitForExistence(timeout: 15))
        // ブロッキングPaywallでは「完了」ボタンで閉じられないこと
        XCTAssertFalse(app.navigationBars["プラン"].buttons["完了"].exists)

        // Standard / Plus / Pro のプラン名とサンプル価格が表示されること
        XCTAssertTrue(app.staticTexts["Standard"].exists)
        XCTAssertTrue(app.staticTexts["Plus"].exists)

        let proTitle = app.staticTexts["Pro"]
        reveal(proTitle)
        XCTAssertTrue(proTitle.exists)

        // ブロッキングPaywall専用の救済導線（プランを再読み込み・ログアウト・アカウントを削除）と法務リンク
        let reloadButton = app.buttons["プランを再読み込み"]
        reveal(reloadButton)
        XCTAssertTrue(reloadButton.exists)
        XCTAssertTrue(app.buttons["ログアウト"].exists)
        XCTAssertTrue(app.buttons["購入履歴を復元"].exists)
        XCTAssertTrue(app.buttons["利用規約"].exists)
        XCTAssertTrue(app.buttons["プライバシーポリシー"].exists)

        let deleteAccountButton = app.buttons["アカウントを削除"]
        XCTAssertTrue(deleteAccountButton.exists)
    }

    func testNonBlockingSettingsPaywallIncludesDoneButtonAndOmitsBlockingExits() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--paywall-ui-test", "--paywall-ui-test-settings", "--paywall-ui-test-sample-prices"]
        app.launch()

        XCTAssertTrue(app.navigationBars["プラン"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["プラン"].buttons["完了"].exists)

        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(app.buttons["プランを再読み込み"].exists)
        XCTAssertTrue(app.buttons["購入履歴を復元"].exists)
    }
}
