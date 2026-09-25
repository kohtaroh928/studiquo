import XCTest
import UIKit

final class LibraryDropInteractionTests: XCTestCase {
    func testFriendChatRemainsLightAndReadableWhenDeviceUsesDarkAppearance() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }

        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--friend-chat-ui-test"]
        app.launch()

        let scheme = app.staticTexts["friend-chat-color-scheme"]
        XCTAssertTrue(scheme.waitForExistence(timeout: 10))
        XCTAssertEqual(scheme.label, "light")
        let incomingMessage = app.staticTexts["可読性テスト"]
        XCTAssertTrue(incomingMessage.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            darkPixelCount(in: incomingMessage.frame, of: app.screenshot().image, appFrame: app.frame),
            30,
            "受信メッセージが白い吹き出し上で白文字になっていないこと"
        )
    }

    func testFailedFriendChatSendClearsDraftAndKeepsMessageInFailedBubble() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--friend-chat-ui-test"]
        app.launch()

        let draft = app.descendants(matching: .any)["friend-chat-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("送信できなかった文章")
        app.buttons["friend-chat-send"].tap()

        XCTAssertTrue(app.staticTexts["送信できませんでした"].waitForExistence(timeout: 5))
        if app.alerts["エラー"].exists { app.alerts.buttons["OK"].tap() }
        XCTAssertFalse(draft.valueString.contains("送信できなかった文章"))
        XCTAssertTrue(app.staticTexts["送信できなかった文章"].exists)
    }

    func testSendingScrollsToNewestMessage() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--friend-chat-ui-test", "--friend-chat-scroll-test"]
        app.launch()

        let draft = app.descendants(matching: .any)["friend-chat-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let list = app.scrollViews.firstMatch
        for _ in 0..<5 { list.swipeDown() }
        draft.tap()
        draft.typeText("最新の送信メッセージ")
        app.buttons["friend-chat-send"].tap()
        if app.alerts["エラー"].waitForExistence(timeout: 2) {
            app.alerts.buttons["OK"].tap()
        }
        XCTAssertFalse(draft.valueString.contains("最新の送信メッセージ"))
        let newest = app.staticTexts["最新の送信メッセージ"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    func testCalendarEventNotesStayVisibleAndSave() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--startup-ui-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 20))
        app.buttons["カレンダー"].tap()
        XCTAssertTrue(app.staticTexts["カレンダー"].waitForExistence(timeout: 5))

        app.buttons["予定を追加"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["予定を追加"].waitForExistence(timeout: 5))

        let title = app.textFields["calendar-event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("メモ保持テスト")

        let notes = app.textViews["calendar-event-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("教室A 持ち物あり")
        XCTAssertTrue(notes.valueString.contains("教室A 持ち物あり"), "The note field cleared while editing")

        // Moving focus away from the notes field causes the form to redraw in
        // the same place where the old vertical TextField used to lose its
        // draft value. Keep this check before saving so the regression catches
        // the disappearing-text bug directly, not only failed persistence.
        title.tap()
        XCTAssertTrue(notes.valueString.contains("教室A 持ち物あり"), "The note field cleared after the editor refreshed")

        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["教室A 持ち物あり"].waitForExistence(timeout: 5), "Saved event notes were not shown in the event list")
    }

    func testDelayedStartupEventuallyShowsHome() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--startup-ui-test"]
        app.launch()

        let home = app.staticTexts["ホーム"]
        XCTAssertTrue(home.waitForExistence(timeout: 20), "The app never advanced past startup")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    }


    func testFolderDropsIntoAnotherFolderWithContents() {
        exerciseFolderMoveWithContents(arguments: ["--library-drop-ui-test"])
    }

    func testFolderDropsIntoAnotherFolderWithContentsInIconMode() {
        exerciseFolderMoveWithContents(arguments: ["--library-drop-ui-test"], viewMode: "icon")
    }

    func testFolderDropsIntoAnotherFolderWithContentsInColumnMode() {
        exerciseFolderMoveWithContents(arguments: ["--library-drop-ui-test", "--column-mode"])
    }

    func testColumnSourceCanBeTapped() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--column-mode"]
        app.launch()
        let source = app.buttons["library-entry-Drag me"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertTrue(source.isHittable)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(source.waitForExistence(timeout: 3))
    }

    func testListRowDropsIntoFolder() {
        exerciseDrop(mode: "list")
    }

    func testListResourceRowsKeepTheirSpacing() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test"]
        app.launch()
        let notebook = app.descendants(matching: .any)["library-entry-Drag me"]
        let slideTitle = app.staticTexts["Y"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 15))
        XCTAssertTrue(slideTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(notebook.frame.height, 58)
        XCTAssertGreaterThan(slideTitle.frame.minY, notebook.frame.maxY)
    }

    func testColumnRowDropsIntoFolder() {
        exerciseDrop(mode: "column")
    }

    func testColumnUsesTheSameFolderPathsAsListAndIcon() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--column-mode"]
        app.launch()

        let folder = app.buttons["library-folder-Target"]
        let rootItem = app.buttons["library-entry-Stale relationship"]
        let nestedItem = app.buttons["library-entry-Path only"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        XCTAssertTrue(rootItem.exists)
        XCTAssertFalse(nestedItem.exists)

        folder.tap()
        XCTAssertTrue(nestedItem.waitForExistence(timeout: 5))
        XCTAssertLessThan(rootItem.frame.minX, nestedItem.frame.minX)
    }

    func testAllFourResourceKindsDropInListAndColumn() {
        for mode in ["list", "column"] {
            let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
            app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
                + (mode == "column" ? ["--column-mode"] : [])
            app.launch()
            let folder = app.descendants(matching: .any)["library-folder-Target"]
            XCTAssertTrue(folder.waitForExistence(timeout: 15))

            for title in ["Drag me", "Cards", "Document", "Y"] {
                let source = app.descendants(matching: .any)["library-entry-\(title)"]
                XCTAssertTrue(source.waitForExistence(timeout: 5), "\(title) is missing in \(mode)")
                drag(source, to: folder)
                XCTAssertFalse(source.waitForExistence(timeout: 2), "\(title) did not leave the root in \(mode)")
            }

            folder.tap()
            for title in ["Drag me", "Cards", "Document", "Y"] {
                XCTAssertTrue(app.descendants(matching: .any)["library-entry-\(title)"].waitForExistence(timeout: 5),
                              "\(title) did not appear in the folder in \(mode)")
            }
            app.terminate()
        }
    }

    func testFolderHoverShowsAddCueInListAndColumn() {
        for mode in ["list", "column"] {
            let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
            app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
                + (mode == "column" ? ["--column-mode"] : [])
            app.launch()
            let hover = app.staticTexts["library-folder-drop-hover"]
            let source = app.descendants(matching: .any)["library-entry-Drag me"]
            let folder = app.descendants(matching: .any)["library-folder-Target"]
            XCTAssertTrue(hover.waitForExistence(timeout: 15))
            XCTAssertEqual(hover.label, "hidden")
            XCTAssertTrue(source.exists)
            XCTAssertTrue(folder.exists)
            drag(source, to: folder)
            XCTAssertEqual(hover.label, "shown", "The add cue never appeared in \(mode) view")
            app.terminate()
        }
    }

    func testColumnMovesIntoSiblingFolder() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--column-mode"]
        app.launch()
        let parent = app.buttons["library-folder-Parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let sourceFolder = app.buttons["library-folder-Parent/Source"]
        XCTAssertTrue(sourceFolder.waitForExistence(timeout: 5))
        sourceFolder.tap()

        let source = app.buttons["library-entry-Source note"]
        let destination = app.buttons["library-folder-Parent/Destination"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.isHittable)
        drag(source, to: destination)
        XCTAssertFalse(source.waitForExistence(timeout: 2))
        destination.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
    }

    func testColumnEmptyPaneAcceptsDropAtItsLevel() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--column-mode"]
        app.launch()
        let parent = app.buttons["library-folder-Parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()
        let emptyFolder = app.buttons["library-folder-Parent/Empty"]
        XCTAssertTrue(emptyFolder.waitForExistence(timeout: 5))
        emptyFolder.tap()

        let source = app.buttons["library-entry-Parent note"]
        let emptyPane = app.descendants(matching: .any)["library-empty-Parent/Empty"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyPane.waitForExistence(timeout: 5))
        drag(source, to: emptyPane)
        XCTAssertGreaterThan(source.frame.minX, emptyFolder.frame.minX)
    }

    func testDroppingIntoCurrentFolderOrOutsideLeavesItemInPlace() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--column-mode"]
        app.launch()
        let folder = app.buttons["library-folder-Target"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        folder.tap()
        let source = app.buttons["library-entry-Already there"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        drag(source, to: folder)
        XCTAssertTrue(source.exists)
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(source.exists)
    }

    func testMoveSurvivesAppRelaunch() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        let storeID = UUID().uuidString
        app.launchArguments = ["--library-drop-ui-test", "--persistent-drop-store=\(storeID)"]
        app.launch()
        let source = app.descendants(matching: .any)["library-entry-Drag me"]
        let folder = app.descendants(matching: .any)["library-folder-Target"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertTrue(folder.exists)
        drag(source, to: folder)
        XCTAssertFalse(source.waitForExistence(timeout: 2))
        app.terminate()

        app.launch()
        let reopenedFolder = app.descendants(matching: .any)["library-folder-Target"]
        XCTAssertTrue(reopenedFolder.waitForExistence(timeout: 15))
        reopenedFolder.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Drag me"].waitForExistence(timeout: 5))
    }

    func testMovedItemAppearsInSameFolderAfterSwitchingViews() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        let source = app.descendants(matching: .any)["library-entry-Drag me"]
        let folder = app.descendants(matching: .any)["library-folder-Target"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        drag(source, to: folder)
        XCTAssertFalse(source.waitForExistence(timeout: 2))
        folder.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))

        for mode in ["icon", "column", "list"] {
            let modeButton = app.buttons["library-view-\(mode)"]
            XCTAssertTrue(modeButton.waitForExistence(timeout: 5))
            modeButton.tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5), "Moved item missing in \(mode) view")
        }
    }

    func testListRowsForAllFourKindsStaySeparate() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        let rows = ["Drag me", "Cards", "Document", "Y"].map {
            app.descendants(matching: .any)["library-entry-\($0)"]
        }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 15)) }
        for pair in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThan(pair.1.frame.minY, pair.0.frame.minY + 48)
        }
    }

    func testListFavoriteToggleAndCancelledDragKeepNavigationWorking() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        let source = app.descendants(matching: .any)["library-entry-Drag me"]
        let favorite = app.buttons["library-favorite-Drag me"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertTrue(favorite.exists)
        XCTAssertEqual(favorite.value as? String, "off")
        favorite.tap()
        XCTAssertEqual(favorite.value as? String, "on")

        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(source.exists)
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-open-notebook-Drag me"].waitForExistence(timeout: 5))
    }

    /// Regression test: `notebookRows` used to wrap each row in
    /// `NavigationLink(value:)`, which only opens something when it sits
    /// inside a `List(selection:)` or a matching `.navigationDestination`.
    /// The all-files screen renders in a plain `ScrollView` (so folder rows
    /// can receive drops), so the tap silently did nothing in list mode.
    /// Icon and column mode were unaffected because they already open
    /// notebooks with a direct `Button { open(...) }` tap; this test covers
    /// all three so a future change to any of them is caught the same way.
    func testNotebookOpensFromEveryViewModeOnTheAllFilesScreen() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()

        let title = "Drag me"
        openNotebookRow(titled: title, in: app) // list mode (the default fixture mode)
        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 5))
        app.buttons["ホームへ戻る"].tap()

        for mode in ["icon", "column"] {
            let modeButton = app.buttons["library-view-\(mode)"]
            XCTAssertTrue(modeButton.waitForExistence(timeout: 5))
            modeButton.tap()
            openNotebookRow(titled: title, in: app)
            XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 5), "Could not get back from \(mode) mode")
            app.buttons["ホームへ戻る"].tap()
        }
    }

    func testDocumentAndSlideTabsDropIntoSplitPane() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()

        openLibraryEntry(titled: "Document", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["tab-document-Document"].waitForExistence(timeout: 5))
        app.buttons["ホームへ戻る"].tap()

        openLibraryEntry(titled: "Y", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["tab-slide-Y"].waitForExistence(timeout: 5))
        app.buttons["ホームへ戻る"].tap()

        openNotebookRow(titled: "Drag me", in: app)
        openHorizontalSplit(in: app)

        let documentTab = app.descendants(matching: .any)["tab-document-Document"]
        let secondaryPane = app.descendants(matching: .any)["split-pane-secondary"]
        XCTAssertTrue(documentTab.waitForExistence(timeout: 5))
        XCTAssertTrue(secondaryPane.waitForExistence(timeout: 5))
        drag(documentTab, to: secondaryPane)

        let documentPane = app.descendants(matching: .any)["split-pane-secondary-document-Document"]
        XCTAssertTrue(documentPane.waitForExistence(timeout: 5), "Dropping a document tab did not switch the secondary pane")

        let slideTab = app.descendants(matching: .any)["tab-slide-Y"]
        XCTAssertTrue(slideTab.waitForExistence(timeout: 5))
        drag(slideTab, to: documentPane)

        XCTAssertTrue(
            app.descendants(matching: .any)["split-pane-secondary-slide-Y"].waitForExistence(timeout: 5),
            "Dropping a slide tab onto an existing document pane did not switch the secondary pane"
        )
    }


    private func exerciseFolderMoveWithContents(arguments: [String], viewMode: String? = nil) {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = arguments
        app.launch()

        if let viewMode {
            let modeButton = app.buttons["library-view-\(viewMode)"]
            XCTAssertTrue(modeButton.waitForExistence(timeout: 15))
            modeButton.tap()
        }

        let parent = app.buttons["library-folder-Parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        parent.tap()

        let source = app.buttons["library-folder-Parent/Source"]
        let destination = app.buttons["library-folder-Parent/Destination"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        drag(source, to: destination)

        XCTAssertFalse(source.waitForExistence(timeout: 2), "Moved folder should leave its old parent")
        destination.tap()
        let nestedSource = app.buttons["library-folder-Parent/Destination/Source"]
        XCTAssertTrue(nestedSource.waitForExistence(timeout: 5), "Moved folder did not appear inside destination")
        nestedSource.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library-entry-Source note"].waitForExistence(timeout: 5),
            "Folder contents did not move with the folder"
        )
    }

    private func openNotebookRow(titled title: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["library-entry-\(title)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(title) row did not appear")
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library-open-notebook-\(title)"].waitForExistence(timeout: 5),
            "Notebook did not open after tapping its row"
        )
    }

    private func openLibraryEntry(titled title: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["library-entry-\(title)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(title) row did not appear")
        row.tap()
        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 5), "\(title) did not open")
    }

    private func openHorizontalSplit(in app: XCUIApplication) {
        let splitButton = app.buttons["画面分割"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "Split control did not appear")
        splitButton.tap()
        let horizontal = app.buttons["左右に2分割"]
        XCTAssertTrue(horizontal.waitForExistence(timeout: 5), "Horizontal split option did not appear")
        horizontal.tap()
        let source = app.buttons["Drag me"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "Split source picker did not appear")
        source.tap()
    }

    private func drag(_ source: XCUIElement, to target: XCUIElement) {
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
    }

    private func exerciseDrop(mode: String) {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test"] + (mode == "column" ? ["--column-mode"] : [])
        app.launch()

        let source = app.descendants(matching: .any)["library-entry-Drag me"]
        let folder = app.descendants(matching: .any)["library-folder-Target"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), "The source row did not render in \(mode) mode")
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "The destination folder did not render in \(mode) mode")
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(folder.isHittable)
        let sourcePoint = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let folderPoint = folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sourcePoint.press(forDuration: 1, thenDragTo: folderPoint, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertFalse(source.waitForExistence(timeout: 2), "The source remained outside the folder in \(mode) mode")
        folder.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5), "The source did not appear inside the folder in \(mode) mode")
    }
}


private extension XCUIElement {
    var valueString: String {
        (value as? String) ?? ""
    }
}

private func darkPixelCount(in elementFrame: CGRect, of image: UIImage, appFrame: CGRect) -> Int {
    guard let cgImage = image.cgImage, appFrame.width > 0, appFrame.height > 0 else { return 0 }
    let scaleX = CGFloat(cgImage.width) / appFrame.width
    let scaleY = CGFloat(cgImage.height) / appFrame.height
    let crop = CGRect(
        x: (elementFrame.minX - appFrame.minX) * scaleX,
        y: (elementFrame.minY - appFrame.minY) * scaleY,
        width: elementFrame.width * scaleX,
        height: elementFrame.height * scaleY
    ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard !crop.isNull, let region = cgImage.cropping(to: crop) else { return 0 }

    let width = region.width
    let height = region.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return }
        context.draw(region, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, index in
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        return count + ((red < 100 && green < 100 && blue < 100) ? 1 : 0)
    }
}
