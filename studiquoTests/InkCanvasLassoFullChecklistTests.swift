import XCTest
@testable import studiquo

/// A run-through of the 選択ツール(なげなわ) checklist as a whole, on top
/// of the deeper coverage already in `InkCanvasLassoSelectionTests` (the
/// winding-number fix), `InkCanvasLassoLiftOutsideCanvasTests`, and
/// `InkCanvasCrossPaneTransferPersistenceTests` (the cross-pane fix):
/// 1. A normal, non-crossing loop selects exactly what it encloses.
/// 2. A self-crossing loop still selects correctly (already fixed/tested).
/// 3. Moving a selection within the same canvas translates it correctly.
/// 4. Cross-pane drag with the outline traveling (already fixed/tested).
/// 5. Tapping outside the selection deselects.
final class InkCanvasLassoFullChecklistTests: XCTestCase {
    private func stroke(_ points: [CGPoint], width: CGFloat = 4) -> InkStroke {
        InkStroke(
            points: points.map { InkPoint(location: $0, force: 0.5, timeOffset: 0) },
            colorHex: "#000000",
            width: width
        )
    }

    // MARK: - 1: a normal (non-crossing) loop selects what it encloses

    func testNormalLoopSelectsOnlyTheStrokeInsideIt() {
        let inside = stroke([CGPoint(x: 45, y: 45), CGPoint(x: 55, y: 55)])
        let outside = stroke([CGPoint(x: 200, y: 200), CGPoint(x: 210, y: 210)])
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]

        let selected = InkCanvasView.strokesEnclosed(by: square, in: [inside, outside])

        XCTAssertEqual(selected, [inside.id], "輪の内側にある線だけが選択され、外側の線は選択されてはいけません。")
    }

    func testNormalLoopSelectsMultipleEnclosedStrokesTogether() {
        let a = stroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
        let b = stroke([CGPoint(x: 80, y: 80), CGPoint(x: 90, y: 90)])
        let outside = stroke([CGPoint(x: 500, y: 500), CGPoint(x: 510, y: 510)])
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]

        let selected = InkCanvasView.strokesEnclosed(by: square, in: [a, b, outside])

        XCTAssertEqual(selected, [a.id, b.id], "輪の中にある線は、複数あってもすべて選択される必要があります。")
    }

    func testLoopEnclosingNothingSelectsNoStrokes() {
        let outside = stroke([CGPoint(x: 500, y: 500), CGPoint(x: 510, y: 510)])
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]

        let selected = InkCanvasView.strokesEnclosed(by: square, in: [outside])

        XCTAssertTrue(selected.isEmpty, "何も囲んでいないときは、何も選択されてはいけません。")
    }

    // MARK: - 2: a self-crossing loop still selects correctly (regression, see InkCanvasLassoSelectionTests)

    func testSelfCrossingLoopStillSelectsTheStrokeItEncloses() {
        let inside = stroke([CGPoint(x: 45, y: 45), CGPoint(x: 55, y: 55)])
        // A doubly-wound square outline (traces the same square twice in the
        // same rotational direction) — the shape a dashed selection line
        // makes when the drawing gesture crosses over itself.
        let doublyWound: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 0),
        ]

        let selected = InkCanvasView.strokesEnclosed(by: doublyWound, in: [inside])

        XCTAssertEqual(selected, [inside.id], "点線が交差する自己交差ループでも、囲んだ線は正しく選択される必要があります。")
    }

    // MARK: - 3: moving a selection within the same canvas

    func testMovingASelectionTranslatesOnlyTheSelectedStrokes() {
        let selected = stroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
        let untouched = stroke([CGPoint(x: 200, y: 200), CGPoint(x: 210, y: 210)])
        let offset = CGPoint(x: 30, y: -15)

        let result = InkCanvasView.movedStrokes([selected, untouched], selectedIDs: [selected.id], offset: offset)

        let movedSelected = result.first { $0.id == selected.id }
        let stillUntouched = result.first { $0.id == untouched.id }
        XCTAssertEqual(movedSelected?.points.map(\.location.x), [40, 50], "選択した線のX座標は、ドラッグした分だけ移動する必要があります。")
        XCTAssertEqual(movedSelected?.points.map(\.location.y), [-5, 5], "選択した線のY座標は、ドラッグした分だけ移動する必要があります。")
        XCTAssertEqual(stillUntouched?.points.map(\.location), untouched.points.map(\.location), "選択されていない線は、位置が変わってはいけません。")
    }

    func testMovingASelectionByZeroOffsetLeavesPointsUnchanged() {
        let selected = stroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])

        let result = InkCanvasView.movedStrokes([selected], selectedIDs: [selected.id], offset: .zero)

        XCTAssertEqual(result.first?.points.map(\.location), selected.points.map(\.location), "移動量がゼロのときは、線の位置は変わらない必要があります。")
    }

    // MARK: - 4: cross-pane drag with the outline traveling (already covered)

    // See `InkCanvasLassoLiftOutsideCanvasTests` (isLassoLiftOutsideCanvas /
    // lassoDragShouldLeaveCanvas) and `InkCanvasCrossPaneTransferPersistenceTests`
    // (the outline surviving a save/load round trip) — both exercise this
    // item already; no further test is added here to avoid duplicating them.

    // MARK: - 5: tapping outside the selection deselects

    func testTappingOutsideTheSelectionPolygonDoesNotCountAsReselecting() {
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]
        let outsideTap = CGPoint(x: 500, y: 500)

        // `beginLasso` only continues an existing drag when the tap lands
        // inside the current selection polygon; this is exactly the
        // predicate it relies on, already exhaustively tested at the
        // `point(_:isInside:)` level — this confirms it agrees for the tap
        // that must fall through to "start a new lasso" (which itself first
        // clears the selection).
        XCTAssertFalse(
            InkCanvasView.point(outsideTap, isInside: square),
            "選択範囲の外をタップした場合は、選択の内側と判定されてはいけません(=選択解除して新しい輪の描き始めとして扱われます)。"
        )
    }

    func testTappingInsideTheSelectionPolygonCountsAsContinuingTheDrag() {
        let square: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0),
        ]
        let insideTap = CGPoint(x: 50, y: 50)

        XCTAssertTrue(
            InkCanvasView.point(insideTap, isInside: square),
            "選択範囲の内側をタップした場合は、選択の内側と判定される必要があります(=つまんで移動する操作として扱われます)。"
        )
    }
}
