import XCTest
@testable import studiquo

/// Coverage for carrying shape elements (rectangles/ellipses) along with
/// ink when a lasso selection is dragged across the split-pane boundary —
/// the follow-up to `LassoShapeSelectionTests`, which only covered
/// same-canvas selection and movement. Three pieces make this work:
/// 1. `InkCanvasView.selectionPreviewBounds` — sizing the floating preview
///    (and, on the receiving side, computing the landing scale) from ink,
///    shapes, or both together, since a shape-only selection has no
///    `InkStroke` to measure a bounding box from.
/// 2. `InkCanvasView.selectionTransferGeometry` — the scale/center shared by
///    every piece of a transfer (ink points, the outline, and now shapes).
/// 3. `PageCanvasContainer.transferredShapeGeometry` — re-expressing a
///    shape's rescaled/recentered position as the destination page's own
///    normalized geometry, since the two pages can differ in size.
final class LassoShapeCrossPaneTransferTests: XCTestCase {
    private func stroke(_ points: [CGPoint], width: CGFloat = 4) -> InkStroke {
        InkStroke(points: points.map { InkPoint(location: $0, force: 0.5, timeOffset: 0) }, colorHex: "#000000", width: width)
    }

    // MARK: - InkCanvasView.selectionPreviewBounds

    func testBoundsCombineInkAndTheSelectionOutlineWhenThereAreNoShapes() {
        let ink = [stroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])]
        let outline: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)]

        let bounds = InkCanvasView.selectionPreviewBounds(inkStrokes: ink, shapeOutlinePoints: [], selectionPolygon: outline)

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 30, height: 30), "インクだけの選択では、線と点線の輪郭を合わせた範囲になる必要があります。")
    }

    func testBoundsFallBackToShapesAndTheOutlineWhenThereIsNoInkAtAll() {
        let shapeOutline: [CGPoint] = [CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 60)]
        let selectionOutline: [CGPoint] = [CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 70)]

        let bounds = InkCanvasView.selectionPreviewBounds(inkStrokes: [], shapeOutlinePoints: shapeOutline, selectionPolygon: selectionOutline)

        XCTAssertEqual(bounds, CGRect(x: 30, y: 30, width: 40, height: 40), "図形だけの選択(インクなし)でも、図形の輪郭と点線の輪郭を合わせた範囲が計算される必要があります。")
    }

    func testBoundsCombineInkShapesAndTheOutlineAllTogether() {
        let ink = [stroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])]
        let shapeOutline: [CGPoint] = [CGPoint(x: 90, y: 90)]
        let selectionOutline: [CGPoint] = [CGPoint(x: 0, y: 0)]

        let bounds = InkCanvasView.selectionPreviewBounds(inkStrokes: ink, shapeOutlinePoints: shapeOutline, selectionPolygon: selectionOutline)

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 90, height: 90), "インクと図形が両方選ばれているときは、両方(と輪郭)を合わせた範囲になる必要があります。")
    }

    func testBoundsAreNilWhenNothingAtAllIsSelected() {
        let bounds = InkCanvasView.selectionPreviewBounds(inkStrokes: [], shapeOutlinePoints: [], selectionPolygon: [])
        XCTAssertNil(bounds, "インクも図形も何もない場合は、範囲を計算できないためnilになる必要があります。")
    }

    // MARK: - InkCanvasView.selectionTransferGeometry

    func testGeometryComputesEqualScaleWhenSourceAndDestinationSizesMatch() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let geometry = InkCanvasView.selectionTransferGeometry(
            combinedSourceBounds: bounds, localTopLeft: CGPoint(x: 0, y: 0), localBottomRight: CGPoint(x: 100, y: 100)
        )
        XCTAssertEqual(geometry.scaleX, 1, accuracy: 0.001, "元と同じ大きさで受け取った場合、拡大率は1である必要があります。")
        XCTAssertEqual(geometry.scaleY, 1, accuracy: 0.001)
        XCTAssertEqual(geometry.sourceCenter, CGPoint(x: 50, y: 50), "基準点は、選択範囲全体の中心である必要があります。")
        XCTAssertEqual(geometry.widthScale, 1, accuracy: 0.001)
    }

    func testGeometryScalesUpWhenTheDestinationPreviewIsLarger() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let geometry = InkCanvasView.selectionTransferGeometry(
            combinedSourceBounds: bounds, localTopLeft: CGPoint(x: 0, y: 0), localBottomRight: CGPoint(x: 200, y: 100)
        )
        XCTAssertEqual(geometry.scaleX, 2, accuracy: 0.001, "受け取り側で2倍の大きさだった場合、X方向の拡大率は2である必要があります。")
        XCTAssertEqual(geometry.scaleY, 2, accuracy: 0.001, "受け取り側で2倍の大きさだった場合、Y方向の拡大率も2である必要があります。")
        XCTAssertEqual(geometry.widthScale, 2, accuracy: 0.001, "線の太さの拡大率は、X・Yの拡大率の平均になる必要があります。")
    }

    func testGeometryNeverProducesAZeroWidthScale() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let geometry = InkCanvasView.selectionTransferGeometry(
            combinedSourceBounds: bounds, localTopLeft: .zero, localBottomRight: .zero
        )
        XCTAssertGreaterThanOrEqual(geometry.widthScale, 0.01, "極端に小さい受け渡しでも、線の太さがゼロになってはいけません。")
    }

    // MARK: - InkCanvasView.shapeSelectionResetOnClear (regression: a shape stuck
    // mid-drag when a cross-pane drop is rejected)

    /// The core regression test: before this fix, a shape whose cross-pane
    /// drag ended without landing anywhere had no way to hear that the drag
    /// was over, and its `EditablePageElement` overlay stayed visually
    /// offset at wherever the drag last left it — even though its real,
    /// stored position never changed. `clearLassoSelection` now always
    /// reports a zero-offset reset for any still-selected shapes, which is
    /// exactly what snaps the overlay back.
    func testClearingASelectionThatStillHasShapesReportsAZeroOffsetResetForAllOfThem() {
        let shapeIDs: Set<AnyHashable> = [AnyHashable("shape-1"), AnyHashable("shape-2")]

        let reset = InkCanvasView.shapeSelectionResetOnClear(selectedShapeIDs: shapeIDs)

        XCTAssertEqual(reset?.ids, shapeIDs, "選択に含まれていたすべての図形が、リセットの対象になる必要があります。")
        XCTAssertEqual(reset?.offset, .zero, "リセット時のずれは常にゼロで、図形は実際の(変わっていない)位置に戻る必要があります。")
    }

    func testClearingASelectionWithNoShapesReportsNoResetAtAll() {
        // An ink-only selection has nothing for this mechanism to do —
        // `onShapeSelectionMoved` must not fire (and so must not touch
        // `PageCanvasContainer`'s live-drag-offset state) when there was
        // never a shape involved in the first place.
        let reset = InkCanvasView.shapeSelectionResetOnClear(selectedShapeIDs: [])
        XCTAssertNil(reset, "図形が選択に含まれていない場合は、リセット自体が発生してはいけません。")
    }

    // MARK: - PageCanvasContainer.transferredShapeGeometry

    func testShapeLandsAtTheSameRelativePositionWhenPagesAreTheSameSize() {
        // A shape centered on a 600×800 source page, transferred 1:1 (no
        // scale change) to a same-sized destination page, landing exactly
        // where the drop point (also the source center here) says.
        let geometry = PageCanvasContainer.transferredShapeGeometry(
            sourceCenterX: 0.5, sourceCenterY: 0.5, sourceWidth: 0.2, sourceHeight: 0.1,
            sourcePageWidth: 600, sourcePageHeight: 800,
            localCenter: CGPoint(x: 300, y: 400), sourceCenter: CGPoint(x: 300, y: 400), scaleX: 1, scaleY: 1,
            destinationPageWidth: 600, destinationPageHeight: 800
        )
        XCTAssertEqual(geometry.centerX, 0.5, accuracy: 0.001, "拡大率1・同じページサイズなら、中心の位置は変わらない必要があります。")
        XCTAssertEqual(geometry.centerY, 0.5, accuracy: 0.001)
        XCTAssertEqual(geometry.width, 0.2, accuracy: 0.001, "拡大率1なら、大きさも変わらない必要があります。")
        XCTAssertEqual(geometry.height, 0.1, accuracy: 0.001)
    }

    func testShapeSizeAdjustsToTheDestinationPagesDimensions() {
        // Same absolute on-screen size, but the destination page is twice
        // as wide/tall in page units — the normalized (fractional) size
        // must shrink accordingly to still cover the same physical area.
        let geometry = PageCanvasContainer.transferredShapeGeometry(
            sourceCenterX: 0.5, sourceCenterY: 0.5, sourceWidth: 0.2, sourceHeight: 0.2,
            sourcePageWidth: 300, sourcePageHeight: 300,
            localCenter: CGPoint(x: 300, y: 300), sourceCenter: CGPoint(x: 150, y: 150), scaleX: 1, scaleY: 1,
            destinationPageWidth: 600, destinationPageHeight: 600
        )
        XCTAssertEqual(geometry.width, 0.1, accuracy: 0.001, "移動先のページが2倍の大きさなら、正規化した幅は半分になる必要があります。")
        XCTAssertEqual(geometry.height, 0.1, accuracy: 0.001)
    }

    func testShapeLandsAtTheDropPointWhenItWasExactlyAtTheSelectionsCenter() {
        let geometry = PageCanvasContainer.transferredShapeGeometry(
            sourceCenterX: 0.5, sourceCenterY: 0.5, sourceWidth: 0.1, sourceHeight: 0.1,
            sourcePageWidth: 400, sourcePageHeight: 400,
            localCenter: CGPoint(x: 123, y: 77), sourceCenter: CGPoint(x: 200, y: 200), scaleX: 1, scaleY: 1,
            destinationPageWidth: 400, destinationPageHeight: 400
        )
        XCTAssertEqual(geometry.centerX, 123.0 / 400.0, accuracy: 0.001, "選択の中心にあった図形は、ドロップした地点にそのまま着地する必要があります。")
        XCTAssertEqual(geometry.centerY, 77.0 / 400.0, accuracy: 0.001)
    }

    func testATinyShapeIsFlooredToAMinimumVisibleSizeOnArrival() {
        let geometry = PageCanvasContainer.transferredShapeGeometry(
            sourceCenterX: 0.5, sourceCenterY: 0.5, sourceWidth: 0.001, sourceHeight: 0.001,
            sourcePageWidth: 600, sourcePageHeight: 800,
            localCenter: CGPoint(x: 300, y: 400), sourceCenter: CGPoint(x: 300, y: 400), scaleX: 1, scaleY: 1,
            destinationPageWidth: 600, destinationPageHeight: 800
        )
        XCTAssertEqual(geometry.width, 0.02, "極端に縮小されても、届いた図形の大きさは見える最小サイズ未満にはならない必要があります。")
        XCTAssertEqual(geometry.height, 0.02)
    }
}
