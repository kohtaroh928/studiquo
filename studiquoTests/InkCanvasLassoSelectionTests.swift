import XCTest
@testable import studiquo

/// Regression coverage for "囲んだ線が自分自身と交差すると、何も選択されない".
///
/// `InkCanvasView.point(_:isInside:)` used to decide inside/outside by
/// counting how many times a ray from the point crosses the lasso's edges
/// (even-odd parity). A hand-drawn loop that crosses itself can enclose a
/// region with an *even* crossing count even though it visibly encloses
/// content, so that content silently dropped out of the selection. The fix
/// switched to a nonzero winding-number test, which tracks each crossing's
/// direction instead of just counting them.
final class InkCanvasLassoSelectionTests: XCTestCase {
    private let square: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
    ]

    private let counterClockwiseSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0),
    ]

    /// The same square boundary traced twice around, in the same rotational
    /// direction — the shape a self-crossing hand-drawn lasso reduces to:
    /// every interior point is crossed by the boundary an even number of
    /// times (four, here), which is exactly what used to read as "outside"
    /// under the old even-odd rule.
    private let doubleWoundSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
        CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
    ]

    func testSimpleSquareContainsItsCenterPoint() {
        XCTAssertTrue(
            InkCanvasView.point(CGPoint(x: 5, y: 5), isInside: square),
            "単純な四角形の中心は、内側と判定される必要があります。"
        )
    }

    func testSimpleSquareExcludesAPointOutsideIt() {
        XCTAssertFalse(
            InkCanvasView.point(CGPoint(x: 20, y: 20), isInside: square),
            "四角形の外側の点は、外側と判定される必要があります。"
        )
    }

    func testCounterClockwiseSquareStillContainsItsCenterPoint() {
        XCTAssertTrue(
            InkCanvasView.point(CGPoint(x: 5, y: 5), isInside: counterClockwiseSquare),
            "反時計回りに囲んだ場合でも、内側の点は内側と判定される必要があります(囲む向きによって結果が変わってはいけません)。"
        )
    }

    /// The core regression test: before the winding-number fix, this exact
    /// case (a loop that crosses itself while still winding the same way
    /// around its own content) returned false — the reported "選択ツールで
    /// 囲ったものが交差すると、何も選択されない" bug.
    func testSelfCrossingDoubleWoundLoopStillContainsItsCenterPoint() {
        XCTAssertTrue(
            InkCanvasView.point(CGPoint(x: 5, y: 5), isInside: doubleWoundSquare),
            "囲んだ点線が自分自身と交差していても、二重に囲まれた内側の点は内側と判定される必要があります。"
        )
    }

    func testSelfCrossingDoubleWoundLoopExcludesAPointOutsideIt() {
        XCTAssertFalse(
            InkCanvasView.point(CGPoint(x: 20, y: 20), isInside: doubleWoundSquare),
            "交差したループの外側にある点は、引き続き外側と判定される必要があります。"
        )
    }

    func testPolygonWithFewerThanThreePointsIsNeverInside() {
        XCTAssertFalse(
            InkCanvasView.point(CGPoint(x: 5, y: 5), isInside: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]),
            "頂点が3つ未満の図形は、閉じた領域を作れないため常に外側扱いになる必要があります。"
        )
    }
}
