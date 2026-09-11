import XCTest
@testable import studiquo

/// Coverage for a photo's own tap-to-select/drag handle carrying it across
/// a page or split-pane boundary (`EditablePageElement.moveGesture`) —
/// distinct from the lasso, which deliberately does NOT recognize photos
/// (see `LassoShapeSelectionTests.testPhotosAreNotSelectableViaLasso`).
final class EditablePageElementDragTests: XCTestCase {
    // MARK: - PageCanvasContainer.droppedElementGeometry

    func testElementLandsAtTheDropPointExpressedAsAFractionOfTheDestinationPage() {
        // A destination page occupying screen x: 100...500, y: 50...450
        // (400×400), dropped exactly at its center.
        let destinationFrame = CGRect(x: 100, y: 50, width: 400, height: 400)
        let geometry = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 300, y: 250), destinationPageGlobalFrame: destinationFrame,
            sourceWidth: 0.3, sourceHeight: 0.2, sourcePageWidth: 600, sourcePageHeight: 800,
            destinationPageWidth: 600, destinationPageHeight: 800
        )
        XCTAssertEqual(geometry.centerX, 0.5, accuracy: 0.001, "ドロップした画面上の位置は、移動先ページの中でのその割合の位置になる必要があります。")
        XCTAssertEqual(geometry.centerY, 0.5, accuracy: 0.001)
    }

    func testElementLandsNearTheEdgeOfTheDestinationPageWhenDroppedThere() {
        let destinationFrame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let geometry = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 40, y: 40), destinationPageGlobalFrame: destinationFrame,
            sourceWidth: 0.1, sourceHeight: 0.1, sourcePageWidth: 400, sourcePageHeight: 400,
            destinationPageWidth: 400, destinationPageHeight: 400
        )
        XCTAssertEqual(geometry.centerX, 0.1, accuracy: 0.001)
        XCTAssertEqual(geometry.centerY, 0.1, accuracy: 0.001)
    }

    func testDropPointIsClampedSoTheElementNeverLandsExactlyOnTheEdge() {
        // Right at the destination page's own top-left corner (0,0 within
        // its frame) — the same [0.03, 0.97] clamp `moveGesture` already
        // applies to an ordinary same-page move.
        let destinationFrame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let geometry = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 0, y: 0), destinationPageGlobalFrame: destinationFrame,
            sourceWidth: 0.1, sourceHeight: 0.1, sourcePageWidth: 400, sourcePageHeight: 400,
            destinationPageWidth: 400, destinationPageHeight: 400
        )
        XCTAssertEqual(geometry.centerX, 0.03, accuracy: 0.001, "移動先ページの端ぎりぎりに落としても、端そのものにははみ出さないようにする必要があります。")
        XCTAssertEqual(geometry.centerY, 0.03, accuracy: 0.001)
    }

    func testElementKeepsItsPhysicalSizeWhenTheDestinationPageIsALargerSize() {
        // Same absolute (page-unit) size, but the destination page is twice
        // as wide/tall — the normalized (fractional) size must shrink
        // accordingly to still cover the same physical area.
        let geometry = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 300, y: 300), destinationPageGlobalFrame: CGRect(x: 0, y: 0, width: 600, height: 600),
            sourceWidth: 0.2, sourceHeight: 0.2, sourcePageWidth: 300, sourcePageHeight: 300,
            destinationPageWidth: 600, destinationPageHeight: 600
        )
        XCTAssertEqual(geometry.width, 0.1, accuracy: 0.001, "移動先のページが2倍の大きさなら、正規化した幅は半分になる必要があります。")
        XCTAssertEqual(geometry.height, 0.1, accuracy: 0.001)
    }

    func testATinyElementIsFlooredToAMinimumVisibleSizeOnArrival() {
        let geometry = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 300, y: 300), destinationPageGlobalFrame: CGRect(x: 0, y: 0, width: 600, height: 600),
            sourceWidth: 0.001, sourceHeight: 0.001, sourcePageWidth: 600, sourcePageHeight: 600,
            destinationPageWidth: 600, destinationPageHeight: 600
        )
        XCTAssertEqual(geometry.width, 0.02, "極端に小さい写真でも、届いた図形と同じく最小サイズ未満にはならない必要があります。")
        XCTAssertEqual(geometry.height, 0.02)
    }

    // MARK: - PageCanvasContainer.stopsElementTouches
    //
    // Regression coverage for "AIに質問するときに囲う点線ツールが写真の青い
    // 枠内で使えない": the fix for the lasso not reaching inside a selected
    // element's own selection box only checked `isLassoActive` — the snip
    // tool (also a dashed-outline tool drawn directly over the page, used
    // to crop a region including a photo for the AI) was left out, so a
    // touch starting inside a selected photo's blue box still went to the
    // photo's own move handle instead of the snip tool underneath it.

    func testLassoStopsElementTouches() {
        XCTAssertTrue(PageCanvasContainer.stopsElementTouches(for: .lasso), "なげなわツールの最中は、部品側がタッチを奪ってはいけません。")
    }

    func testSnipStopsElementTouches() {
        XCTAssertTrue(PageCanvasContainer.stopsElementTouches(for: .snip), "スニップツールの最中も、部品側がタッチを奪ってはいけません(今回の修正の核心)。")
    }

    func testOrdinaryDrawingToolsDoNotStopElementTouches() {
        // Only tools that need to draw an enclosure/crop directly over the
        // page should take priority over an element's own handles — pen,
        // highlighter, and the eraser have no reason to reach underneath a
        // selected element's box.
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .pen))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .highlighter))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .eraser))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .none))
    }
}
