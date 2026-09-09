import XCTest
@testable import studiquo

/// Coverage for making the 選択ツール(なげなわ) recognize shape elements
/// (rectangles/ellipses drawn with the shape tool) alongside ink, so a loop
/// drawn around a shape — or around a mix of ink and a shape — selects and
/// moves both together. Before this, the lasso only ever knew about
/// `InkStroke`s; a shape was invisible to it (see `ShapeToolTests`'s note on
/// why shapes are `PageElement`s, not ink, in the first place).
final class LassoShapeSelectionTests: XCTestCase {
    // MARK: - InkCanvasView.shapesEnclosed

    func testALoopEnclosingAShapesOutlineSelectsIt() {
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]
        let shape = SelectableShapeOutline(id: AnyHashable("shape-1"), outline: [CGPoint(x: 50, y: 50)])

        let selected = InkCanvasView.shapesEnclosed(by: square, in: [shape])

        XCTAssertEqual(selected, [AnyHashable("shape-1")], "図形の輪郭が輪の中にある場合、その図形は選択される必要があります。")
    }

    func testALoopNotReachingAShapeDoesNotSelectIt() {
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]
        let farShape = SelectableShapeOutline(id: AnyHashable("shape-far"), outline: [CGPoint(x: 500, y: 500)])

        let selected = InkCanvasView.shapesEnclosed(by: square, in: [farShape])

        XCTAssertTrue(selected.isEmpty, "輪の外にある図形は選択されてはいけません。")
    }

    func testALoopCanSelectMultipleShapesAtOnce() {
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0),
        ]
        let a = SelectableShapeOutline(id: AnyHashable("a"), outline: [CGPoint(x: 20, y: 20)])
        let b = SelectableShapeOutline(id: AnyHashable("b"), outline: [CGPoint(x: 180, y: 180)])
        let outside = SelectableShapeOutline(id: AnyHashable("outside"), outline: [CGPoint(x: 900, y: 900)])

        let selected = InkCanvasView.shapesEnclosed(by: square, in: [a, b, outside])

        XCTAssertEqual(selected, [AnyHashable("a"), AnyHashable("b")], "輪の中にある図形は、複数あってもすべて選択される必要があります。")
    }

    func testAShapeCountsAsEnclosedIfAnyPartOfItsOutlineIsInsideEvenIfTheRestIsNot() {
        // A shape larger than the loop, straddling its boundary — matches
        // how `strokesEnclosed` treats a stroke that's only partly inside.
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]
        let straddling = SelectableShapeOutline(
            id: AnyHashable("straddling"),
            outline: [CGPoint(x: 50, y: 50), CGPoint(x: 500, y: 500)]
        )

        let selected = InkCanvasView.shapesEnclosed(by: square, in: [straddling])

        XCTAssertEqual(selected, [AnyHashable("straddling")], "図形の輪郭の一部でも輪の中に入っていれば、その図形は選択される必要があります。")
    }

    // MARK: - PageCanvasContainer.movedShapeCenter

    func testMovingAShapeTranslatesItsNormalizedCenterByTheOffsetInPageUnits() {
        let moved = PageCanvasContainer.movedShapeCenter(
            centerX: 0.5, centerY: 0.5, offset: CGPoint(x: 60, y: 80), pageWidth: 600, pageHeight: 800
        )
        XCTAssertEqual(moved.centerX, 0.6, accuracy: 0.0001, "図形の中心Xは、ページ幅に対するドラッグ量の割合だけ動く必要があります。")
        XCTAssertEqual(moved.centerY, 0.6, accuracy: 0.0001, "図形の中心Yは、ページ高さに対するドラッグ量の割合だけ動く必要があります。")
    }

    func testMovingAShapeByZeroOffsetLeavesItsCenterUnchanged() {
        let moved = PageCanvasContainer.movedShapeCenter(
            centerX: 0.3, centerY: 0.7, offset: .zero, pageWidth: 600, pageHeight: 800
        )
        XCTAssertEqual(moved.centerX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.centerY, 0.7, accuracy: 0.0001)
    }

    func testMovingAShapeAndThenMovingItBackReturnsItToItsOriginalCenter() {
        let pageWidth = 600.0, pageHeight = 800.0
        let offset = CGPoint(x: 45, y: -30)
        let moved = PageCanvasContainer.movedShapeCenter(
            centerX: 0.4, centerY: 0.6, offset: offset, pageWidth: pageWidth, pageHeight: pageHeight
        )
        let movedBack = PageCanvasContainer.movedShapeCenter(
            centerX: moved.centerX, centerY: moved.centerY,
            offset: CGPoint(x: -offset.x, y: -offset.y), pageWidth: pageWidth, pageHeight: pageHeight
        )
        XCTAssertEqual(movedBack.centerX, 0.4, accuracy: 0.0001, "往復移動させれば、元の位置に戻る必要があります。")
        XCTAssertEqual(movedBack.centerY, 0.6, accuracy: 0.0001, "往復移動させれば、元の位置に戻る必要があります。")
    }

    // MARK: - PageCanvasContainer.scaledShapeSelectionOffset
    //
    // Regression coverage for a bug where a shape dragged by the lasso
    // moved independently of the selection/ink around it whenever the
    // canvas was displayed at anything other than 1:1 (any split pane or
    // zoomed view). `onShapeSelectionDragged` reports its offset in page
    // units, matching what `InkCanvasView` applies directly to its own ink
    // layers, but `EditablePageElement`'s `.position()` already works in
    // display-scaled coordinates — so the live drag offset must be scaled
    // by the same `contentScale` before being used, or the two drift apart.

    func testScaledOffsetIsUnchangedWhenContentScaleIsOne() {
        let scaled = PageCanvasContainer.scaledShapeSelectionOffset(CGPoint(x: 40, y: -20), contentScale: 1)
        XCTAssertEqual(scaled, CGPoint(x: 40, y: -20), "表示倍率が1のときは、ページ単位のオフセットがそのまま使われる必要があります。")
    }

    func testScaledOffsetShrinksWhenTheCanvasIsDisplayedSmallerThanThePage() {
        // A split-pane canvas typically renders the page at less than its
        // full page-unit size — e.g. a 600pt-wide page shown at 300 display
        // points is contentScale 0.5.
        let scaled = PageCanvasContainer.scaledShapeSelectionOffset(CGPoint(x: 100, y: 50), contentScale: 0.5)
        XCTAssertEqual(scaled, CGPoint(x: 50, y: 25), "表示倍率が0.5の場合、図形に加えるオフセットも半分にスケールされる必要があります。")
    }

    func testScaledOffsetGrowsWhenTheCanvasIsZoomedIn() {
        let scaled = PageCanvasContainer.scaledShapeSelectionOffset(CGPoint(x: 10, y: 10), contentScale: 2)
        XCTAssertEqual(scaled, CGPoint(x: 20, y: 20), "表示倍率が2の場合、図形に加えるオフセットも2倍にスケールされる必要があります。")
    }

    func testScaledOffsetOfZeroStaysZeroRegardlessOfScale() {
        let scaled = PageCanvasContainer.scaledShapeSelectionOffset(.zero, contentScale: 0.37)
        XCTAssertEqual(scaled, .zero, "ドラッグ量がゼロなら、どんな表示倍率でも結果はゼロのままである必要があります。")
    }
}
