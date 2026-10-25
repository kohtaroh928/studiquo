import XCTest

final class RAGCitationNavigationTests: XCTestCase {
    func testPrivacySettingsAlwaysAllowManagingStoredRAGData() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-more"].waitForExistence(timeout: 30))
        app.buttons["home-tab-more"].tap()
        let manage = app.buttons["settings-rag-data"]
        for _ in 0..<12 {
            if manage.exists && manage.isHittable { break }
            let list = app.collectionViews.firstMatch
            if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(manage.exists && manage.isHittable)
        manage.tap()
        XCTAssertTrue(app.navigationBars["資料検索"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["rag-auto-grant"].exists)
        let future = app.switches["rag-auto-future"]
        XCTAssertTrue(future.exists)
        XCTAssertEqual(future.value as? String, "0")
        let deletion = app.buttons["保存済みの検索データを削除"]
        for _ in 0..<8 {
            if deletion.exists && deletion.isHittable { break }
            let visibleLists = app.collectionViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 200 }
            if let list = visibleLists.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                list.swipeUp(velocity: .slow)
            } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(deletion.exists)
        // Form virtualizes offscreen rows. Find the registration section again
        // after scrolling to the deletion action; disclosure length can change.
        let registration = app.descendants(matching: .any)["rag-registration-unknown"]
        for _ in 0..<8 {
            if registration.exists && app.buttons["登録状況を再確認"].exists { break }
            let visibleLists = app.collectionViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 200 }
            if let list = visibleLists.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                list.swipeDown(velocity: .slow)
            } else { app.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(registration.exists)
        XCTAssertTrue(app.buttons["登録状況を再確認"].exists)
    }

    func testTappingStructuredCitationOpensItsNotebookPage() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test", "--note-ai-chat-auto-open", "--rag-citation-test"]
        app.launch()
        let citation = app.buttons["rag-citation-3"]
        XCTAssertTrue(citation.waitForExistence(timeout: 30))
        citation.tap()
        let page = app.staticTexts["rag-editor-selected-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let correctPage = NSPredicate(format: "label == %@", "RAG page 3")
        expectation(for: correctPage, evaluatedWith: page)
        waitForExpectations(timeout: 10)
    }
    func testRetrievalStatusExplainsEvidenceAndUnknownStatusStaysHidden() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        for status in ["grounded", "partial", "insufficient", "clarification", "fallback", "future-state"] {
            app.launchArguments = ["--note-ai-chat-ui-test", "--note-ai-chat-auto-open", "--rag-citation-test", "--rag-status-test=\(status)"]
            app.launch()
            XCTAssertTrue(app.buttons["rag-citation-3"].waitForExistence(timeout: 30))
            if status == "future-state" {
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "rag-status-")).firstMatch.exists)
            } else {
                let notice = app.staticTexts["rag-status-\(status)"]
                XCTAssertTrue(notice.waitForExistence(timeout: 10))
                XCTAssertFalse(notice.label.isEmpty)
            }
            app.terminate()
        }
    }

}
