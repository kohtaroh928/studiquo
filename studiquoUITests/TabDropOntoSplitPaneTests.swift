import XCTest

/// Dropping a tab onto a split pane must switch that pane to the dropped material,
/// whatever the pane currently shows — an AI chat, a group chat, a friend chat or the
/// Web. The fixture (`--tab-drop-ui-test`, or the snippet fixtures with
/// `--ui-test-tab-drag-sources`) hosts the real note editor under a bar of chips that
/// carry the same payload as the real tabs.
///
/// Reported failure: with a split screen whose other half is the AI chat, dropping a
/// tab anywhere but the prompt field did not switch that half. The group chat and the
/// Web pane had the same fault, and the friend chat ignored document tabs.
final class TabDropOntoSplitPaneTests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Launching

    private func launch(_ arguments: [String], orientation: UIDeviceOrientation = .portrait) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = arguments
        app.launch()
        try waitForOrientation(orientation)
    }

    /// The simulator rotates a moment after being asked, and some cannot rotate from a
    /// test at all. A "landscape" test run in a portrait window would drop on the wrong
    /// pane and prove nothing, so wait for the real shape — and skip, not pass, if it
    /// never arrives.
    private func waitForOrientation(_ orientation: UIDeviceOrientation) throws {
        let wantsLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let frame = window.frame
            if (frame.width > frame.height) == wantsLandscape { return }
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw XCTSkip("This simulator would not rotate to \(wantsLandscape ? "landscape" : "portrait") (window \(window.frame)); the test needs the real layout.")
    }

    // MARK: Gestures

    private enum Dropped { case notebook, document }

    private func chip(_ kind: Dropped) -> XCUIElement {
        app.descendants(matching: .any)[kind == .notebook ? "tab-drag-source-notebook" : "tab-drag-source-document"].firstMatch
    }

    private func drag(_ kind: Dropped = .notebook, to coordinate: XCUICoordinate) {
        let source = chip(kind)
        XCTAssertTrue(source.waitForExistence(timeout: 15), "the draggable tab chip is missing")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: coordinate, withVelocity: .slow, thenHoldForDuration: 1)
    }

    /// A point inside the second pane, `depth` of the way down it (0 = top edge,
    /// 1 = bottom). The composer sits at the very bottom of a chat pane: stay above it.
    private func otherPaneCoordinate(orientation: UIDeviceOrientation, depth: CGFloat = 0.4) -> XCUICoordinate {
        let window = app.windows.firstMatch
        if orientation == .portrait {
            // Top/bottom split: the second pane is the lower part of the window.
            return window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60 + 0.30 * depth))
        }
        // Side by side: the second pane is the right half, below the tool strip.
        return window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.20 + 0.65 * depth))
    }

    // MARK: Assertions

    private func assertSwitchedToDroppedNotebook(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["ドロップ先ノート"].waitForExistence(timeout: 8), message, file: file, line: line)
    }

    private func assertSwitchedToDroppedDocument(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.descendants(matching: .any)["split-pane-secondary-document-ドロップ先文書"].waitForExistence(timeout: 8),
            message, file: file, line: line
        )
    }

    // MARK: Opening each kind of pane

    private var aiDraft: XCUIElement {
        app.textViews["ai-chat-draft"].exists ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
    }

    private func openAIChatPane() {
        let button = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "AI button missing")
        button.tap()
        XCTAssertTrue(aiDraft.waitForExistence(timeout: 10), "AI pane did not open")
    }

    private var webAddressField: XCUIElement { app.textFields["検索、またはURLを入力"] }

    private func openWebPane() {
        let split = app.buttons["画面分割"]
        XCTAssertTrue(split.waitForExistence(timeout: 15), "split menu missing")
        // The tool strip scrolls sideways; bring the button into view first.
        let window = app.windows.firstMatch
        for _ in 0..<6 where split.frame.midX > window.frame.width - 30 {
            let y = max(0.02, min(0.2, split.frame.midY / max(window.frame.height, 1)))
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y)))
        }
        XCTAssertLessThan(split.frame.midX, window.frame.width, "could not scroll the split menu into view")
        split.tap()
        let web = app.buttons["Google検索と2分割"]
        XCTAssertTrue(web.waitForExistence(timeout: 5), "web split option missing")
        web.tap()
        XCTAssertTrue(webAddressField.waitForExistence(timeout: 10), "web pane did not open")
    }

    // MARK: AI chat

    private func assertAIChatPaneSwitches(orientation: UIDeviceOrientation, depth: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        try launch(["--tab-drop-ui-test"], orientation: orientation)
        openAIChatPane()
        drag(to: otherPaneCoordinate(orientation: orientation, depth: depth))
        assertSwitchedToDroppedNotebook(
            "Dropping a tab on the AI chat pane (\(Int(depth * 100))% down) did not switch it",
            file: file, line: line
        )
        XCTAssertFalse(aiDraft.exists, "the AI chat should have been replaced", file: file, line: line)
    }

    func testAIChatPaneSwitchesWhenATabIsDroppedNearItsTopInPortrait() throws { try assertAIChatPaneSwitches(orientation: .portrait, depth: 0.1) }
    func testAIChatPaneSwitchesWhenATabIsDroppedInItsMiddleInPortrait() throws { try assertAIChatPaneSwitches(orientation: .portrait, depth: 0.45) }
    func testAIChatPaneSwitchesWhenATabIsDroppedJustAboveTheComposerInPortrait() throws { try assertAIChatPaneSwitches(orientation: .portrait, depth: 0.8) }
    func testAIChatPaneSwitchesWhenATabIsDroppedNearItsTopInLandscape() throws { try assertAIChatPaneSwitches(orientation: .landscapeLeft, depth: 0.1) }
    func testAIChatPaneSwitchesWhenATabIsDroppedInItsMiddleInLandscape() throws { try assertAIChatPaneSwitches(orientation: .landscapeLeft, depth: 0.45) }
    func testAIChatPaneSwitchesWhenATabIsDroppedJustAboveTheComposerInLandscape() throws { try assertAIChatPaneSwitches(orientation: .landscapeLeft, depth: 0.8) }

    func testAIChatPaneSwitchesToADroppedDocument() throws {
        try launch(["--tab-drop-ui-test"])
        openAIChatPane()
        drag(.document, to: otherPaneCoordinate(orientation: .portrait))
        assertSwitchedToDroppedDocument("Dropping a document tab on the AI chat pane did not switch it")
    }

    // MARK: Group chat

    func testGroupChatPaneSwitchesWhenATabIsDropped() throws {
        try launch(["--note-snippet-group-ui-test", "--ui-test-tab-drag-sources"])
        XCTAssertTrue(app.descendants(matching: .any)["group-chat-draft"].waitForExistence(timeout: 15), "group chat pane did not open")
        drag(to: otherPaneCoordinate(orientation: .portrait))
        assertSwitchedToDroppedNotebook("Dropping a tab on the group chat pane did not switch it")
        XCTAssertFalse(app.descendants(matching: .any)["group-chat-draft"].exists)
    }

    func testGroupChatPaneSwitchesToADroppedDocument() throws {
        try launch(["--note-snippet-group-ui-test", "--ui-test-tab-drag-sources"])
        XCTAssertTrue(app.descendants(matching: .any)["group-chat-draft"].waitForExistence(timeout: 15), "group chat pane did not open")
        drag(.document, to: otherPaneCoordinate(orientation: .portrait))
        assertSwitchedToDroppedDocument("Dropping a document tab on the group chat pane did not switch it")
    }

    // MARK: Friend chat

    func testFriendChatPaneSwitchesWhenATabIsDropped() throws {
        try launch(["--note-snippet-friend-ui-test", "--ui-test-tab-drag-sources"])
        XCTAssertTrue(app.descendants(matching: .any)["friend-chat-draft"].waitForExistence(timeout: 15), "friend chat pane did not open")
        drag(to: otherPaneCoordinate(orientation: .portrait))
        assertSwitchedToDroppedNotebook("Dropping a tab on the friend chat pane did not switch it")
        XCTAssertFalse(app.descendants(matching: .any)["friend-chat-draft"].exists)
    }

    /// The friend chat once recognised only some kinds of tab: a document
    /// dropped on it was ignored although a notebook switched it.
    func testFriendChatPaneSwitchesToADroppedDocument() throws {
        try launch(["--note-snippet-friend-ui-test", "--ui-test-tab-drag-sources"])
        XCTAssertTrue(app.descendants(matching: .any)["friend-chat-draft"].waitForExistence(timeout: 15), "friend chat pane did not open")
        drag(.document, to: otherPaneCoordinate(orientation: .portrait))
        assertSwitchedToDroppedDocument("Dropping a document tab on the friend chat pane did not switch it")
    }

    // MARK: Web

    /// On the address-bar strip, just beside the text field (the field itself takes text).
    private func webStripCoordinate() -> XCUICoordinate {
        let address = webAddressField
        return app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(
            dx: (address.frame.minX - 5) / max(app.windows.firstMatch.frame.width, 1),
            dy: address.frame.midY / max(app.windows.firstMatch.frame.height, 1)
        ))
    }

    /// In the middle of the page itself.
    private func webPageCoordinate() -> XCUICoordinate {
        let page = app.webViews.firstMatch.frame
        let window = app.windows.firstMatch.frame
        return app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(
            dx: page.midX / max(window.width, 1), dy: page.midY / max(window.height, 1)
        ))
    }

    func testWebPaneSwitchesWhenATabIsDroppedOnItsAddressBar() throws {
        try launch(["--tab-drop-ui-test"])
        openWebPane()
        drag(to: webStripCoordinate())
        assertSwitchedToDroppedNotebook("Dropping a tab on the Web pane's address bar did not switch it")
        XCTAssertFalse(webAddressField.exists, "the Web pane should have been replaced")
    }

    /// The web view takes dropped text for itself, so this is the hard case.
    func testWebPaneSwitchesWhenATabIsDroppedOnThePage() throws {
        try launch(["--tab-drop-ui-test"])
        openWebPane()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "the web page view is missing")
        drag(to: webPageCoordinate())
        assertSwitchedToDroppedNotebook("Dropping a tab on the Web page did not switch the pane")
        XCTAssertFalse(webAddressField.exists, "the Web pane should have been replaced")
    }

    func testWebPaneSwitchesToADroppedDocument() throws {
        try launch(["--tab-drop-ui-test"])
        openWebPane()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "the web page view is missing")
        drag(.document, to: webPageCoordinate())
        assertSwitchedToDroppedDocument("Dropping a document tab on the Web page did not switch the pane")
    }

    // MARK: The real tab bar

    /// The other tests drag a stand-in chip. This one drags a real tab from the app's own
    /// tab bar (in portrait, so the top/bottom split): it proves the tab bar's drag source,
    /// not just the receiving panes, still delivers.
    func testARealDocumentTabDroppedOnASplitPaneSwitchesIt() throws {
        try launch(["--library-drop-ui-test", "--resource-types-fixture"])

        let documentRow = app.descendants(matching: .any)["library-entry-Document"]
        XCTAssertTrue(documentRow.waitForExistence(timeout: 20), "Document row missing")
        documentRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tab-document-Document"].firstMatch.waitForExistence(timeout: 10), "the document tab did not appear")
        app.buttons["ホームへ戻る"].tap()

        let notebookRow = app.descendants(matching: .any)["library-entry-Drag me"]
        XCTAssertTrue(notebookRow.waitForExistence(timeout: 15), "Drag me row missing")
        notebookRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-open-notebook-Drag me"].waitForExistence(timeout: 10))

        let split = app.buttons["画面分割"]
        XCTAssertTrue(split.waitForExistence(timeout: 10), "split menu missing")
        app.scrollToolStrip(toReveal: split)
        split.tap()
        let vertical = app.buttons["上下に2分割"]
        XCTAssertTrue(vertical.waitForExistence(timeout: 5), "top/bottom split option missing")
        vertical.tap()
        // The picker lists the notes as rows of text. "Drag me" is also the name of the
        // note's own tab, which the picker covers: tap the row that can be pressed.
        let rows = app.staticTexts.matching(NSPredicate(format: "label == 'Drag me'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "split source picker did not appear")
        Thread.sleep(forTimeInterval: 0.5)
        guard let source = rows.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no pressable \"Drag me\" row in the split source picker")
        }
        source.tap()

        let tab = app.descendants(matching: .any)["tab-document-Document"].firstMatch
        let secondary = app.descendants(matching: .any)["split-pane-secondary"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        XCTAssertTrue(secondary.waitForExistence(timeout: 10))
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: secondary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 1)

        XCTAssertTrue(
            app.descendants(matching: .any)["split-pane-secondary-document-Document"].waitForExistence(timeout: 8),
            "Dropping a real document tab on the split pane did not switch it"
        )
    }
}
