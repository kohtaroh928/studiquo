import XCTest
@testable import studiquo

/// Regression coverage for two lasso-drag bugs, both about deciding whether
/// a drag/lift should be treated as having left this canvas:
///
/// 1. "非常に素早いフリック操作で境界をまたぐと、外に落としたはずなのに
///    中に置いたことにされる" — a fast flick that crosses the split-pane
///    boundary could in theory lift with zero intervening `moveLasso`
///    calls, leaving `isSelectionOutsideCanvas` stale at `false` even
///    though the lift itself landed outside the canvas. `endLasso` used to
///    trust that flag alone; it now also checks the lift's own location
///    directly via `InkCanvasView.isLassoLiftOutsideCanvas`.
/// 2. "両方の画面に同じノートを開いていると、境界の外まで運んだ後に
///    指を離すと元の位置へ引き戻される" — with nowhere to actually hand a
///    selection off to (`allowsSelectionTransfer == false`), treating a
///    drag/lift past this canvas's edge as "outside" produced a floating
///    preview (or a failed transfer at drop) that only ever unwinds itself,
///    which reads as a pointless snap-back. Both decision points now stay
///    "inside" whenever `allowsSelectionTransfer` is false.
final class InkCanvasLassoLiftOutsideCanvasTests: XCTestCase {
    private let canvasSize = CGSize(width: 100, height: 100)

    // MARK: - isLassoLiftOutsideCanvas (at touch-up)

    func testLiftInsideCanvasWithFlagNeverSetIsNotTreatedAsOutside() {
        XCTAssertFalse(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: 50, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: false, allowsSelectionTransfer: true
            ),
            "キャンバスの内側で指を離した、普通のドロップは内側の移動として扱われる必要があります。"
        )
    }

    /// The fast-flick regression case: the flag never caught up (no
    /// intervening move event reported leaving the canvas), but the lift
    /// itself is physically outside — this must still be treated as a drop
    /// outside the canvas, not a plain in-canvas move.
    func testLiftOutsideCanvasIsTreatedAsOutsideEvenWhenTheFlagWasNeverUpdated() {
        XCTAssertTrue(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: 150, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: false, allowsSelectionTransfer: true
            ),
            "境界の外で指を離した場合、直前の移動中の判定が追いついていなくても、外側への移動として扱われる必要があります。"
        )
    }

    func testLiftInsideCanvasIsStillTreatedAsOutsideWhenTheFlagWasAlreadySet() {
        XCTAssertTrue(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: 50, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: true, allowsSelectionTransfer: true
            ),
            "境界の外に一度出ていた場合は、最後に内側へ戻った瞬間の判定が間に合っていなくても、外側への移動として扱われる必要があります。"
        )
    }

    func testLiftOutsideCanvasWithFlagAlreadySetIsTreatedAsOutside() {
        XCTAssertTrue(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: -20, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: true, allowsSelectionTransfer: true
            ),
            "フラグと実際の位置の両方が外側と一致している、通常のケースでも外側への移動として扱われる必要があります。"
        )
    }

    /// The core regression test for "同じノートを両方の画面に開いている場合":
    /// with no pane to hand off to, a lift past the edge must never be
    /// treated as outside — otherwise the drop attempts (and fails) a
    /// hand-off, unwinding the drag back to its starting position instead
    /// of simply committing the in-canvas move.
    func testLiftOutsideCanvasIsNotTreatedAsOutsideWhenTransferIsNotAllowed() {
        XCTAssertFalse(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: 150, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: false, allowsSelectionTransfer: false
            ),
            "渡す機能が無効なときは、境界の外で指を離しても外側への移動として扱ってはいけません。"
        )
    }

    /// Even if some earlier frame had (incorrectly, or from before transfer
    /// was disabled) set the flag, a disallowed transfer must still win —
    /// there is nowhere for this drop to go but back into this canvas.
    func testLiftIsNotTreatedAsOutsideWhenTransferIsNotAllowedEvenIfTheFlagWasAlreadySet() {
        XCTAssertFalse(
            InkCanvasView.isLassoLiftOutsideCanvas(
                location: CGPoint(x: -20, y: 50), canvasSize: canvasSize,
                wasAlreadyOutside: true, allowsSelectionTransfer: false
            ),
            "渡す機能が無効なときは、直前のフラグが立っていても外側への移動として扱ってはいけません。"
        )
    }

    // MARK: - lassoDragShouldLeaveCanvas (while dragging)

    func testDragInsideCanvasDoesNotLeaveCanvas() {
        XCTAssertFalse(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 50, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: true
            ),
            "キャンバスの内側をドラッグしている間は、外側に出た扱いにしてはいけません。"
        )
    }

    func testDragPastCanvasEdgeLeavesCanvasWhenTransferIsAllowed() {
        XCTAssertTrue(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 150, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: true
            ),
            "渡す機能が有効なときは、境界の外へドラッグした時点で外側に出た扱いにする必要があります。"
        )
    }

    /// The other half of the same-notebook regression: while still
    /// dragging (not just at lift), wandering past this canvas's edge must
    /// not hide the content or start a floating preview, since there is no
    /// other pane to receive it.
    func testDragPastCanvasEdgeDoesNotLeaveCanvasWhenTransferIsNotAllowed() {
        XCTAssertFalse(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 150, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: false
            ),
            "渡す機能が無効なときは、境界の外へドラッグしても外側に出た扱いにしてはいけません。"
        )
    }

    // MARK: - lassoDragShouldLeaveCanvas, driven by the selection's own bounds
    //
    // Regression coverage for "円の端がページの端と余白の間に潜り込む": a
    // selection larger than the touch point can have its far edge cross the
    // canvas boundary before the touch itself does — the page clips
    // anything past its own rectangle, so until this switches over to the
    // unclipped floating preview, that overhanging edge is invisibly cut
    // away rather than riding along with the rest of the drag.

    /// The touch is still comfortably inside, and so is the selection's own
    /// (moved) bounds — nothing here should trigger "left the canvas."
    func testDragStaysInsideWhenBothTheTouchAndTheSelectionsBoundsAreInside() {
        XCTAssertFalse(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 50, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: true,
                movedSelectionBounds: CGRect(x: 40, y: 40, width: 20, height: 20)
            ),
            "選択範囲自体もまだキャンバスの内側に収まっているときは、外側に出た扱いにしてはいけません。"
        )
    }

    /// The core regression case: the touch itself is still inside the
    /// canvas, but the (larger) selection being dragged already has its far
    /// edge poking out past the boundary.
    func testDragLeavesCanvasWhenTheSelectionsBoundsPokeOutEvenThoughTheTouchIsStillInside() {
        XCTAssertTrue(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 90, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: true,
                movedSelectionBounds: CGRect(x: 70, y: 30, width: 40, height: 40)
            ),
            "指自体はまだキャンバスの内側でも、ドラッグしている選択範囲の端がすでにはみ出しているなら、外側に出た扱いにする必要があります。"
        )
    }

    /// Even with a selection whose bounds poke out, a disallowed transfer
    /// (e.g. the same notebook open in both panes) must still never trigger
    /// "left the canvas" — there is nowhere for it to go.
    func testSelectionBoundsPokingOutIsIgnoredWhenTransferIsNotAllowed() {
        XCTAssertFalse(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 90, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: false,
                movedSelectionBounds: CGRect(x: 70, y: 30, width: 40, height: 40)
            ),
            "渡す機能が無効なときは、選択範囲の端がはみ出していても外側に出た扱いにしてはいけません。"
        )
    }

    /// Omitting `movedSelectionBounds` entirely (its default) must fall back
    /// to exactly the old, touch-only behavior — every call site that
    /// predates this and doesn't yet compute a selection's bounds keeps
    /// working unchanged.
    func testOmittingMovedSelectionBoundsFallsBackToTouchOnlyBehavior() {
        XCTAssertFalse(
            InkCanvasView.lassoDragShouldLeaveCanvas(
                location: CGPoint(x: 50, y: 50), canvasSize: canvasSize, allowsSelectionTransfer: true
            ),
            "選択範囲の情報を渡さない場合は、これまで通り指の位置だけで判定される必要があります。"
        )
    }

    // MARK: - movedBounds(of:offset:)

    func testMovedBoundsTranslatesThePointsBoundingBoxByTheOffset() {
        let points: [CGPoint] = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)]
        let bounds = InkCanvasView.movedBounds(of: points, offset: CGPoint(x: 5, y: -5))
        XCTAssertEqual(bounds, CGRect(x: 15, y: 5, width: 20, height: 30), "点の集まりの外接矩形が、ずらした分だけ正しく平行移動している必要があります。")
    }

    func testMovedBoundsOfZeroOffsetMatchesTheOriginalBoundingBox() {
        let points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)]
        let bounds = InkCanvasView.movedBounds(of: points, offset: .zero)
        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testMovedBoundsOfEmptyPointsIsNil() {
        XCTAssertNil(InkCanvasView.movedBounds(of: [], offset: CGPoint(x: 10, y: 10)), "点が1つもない場合は、外接矩形を計算できないためnilになる必要があります。")
    }

    // MARK: - viewPoint(forPageSpace:contentScale:)
    //
    // Regression coverage for "境界を越えた瞬間、点線・プレビューの位置がガクッ
    // とズレる": the floating cross-pane preview's on-screen position was
    // computed by handing a page-space point straight to `convert(_:to:)`,
    // which interprets its argument as already being in this view's own
    // (view-point) coordinate space. The two never actually match unless
    // `contentScale` happens to be exactly 1 — which is essentially never
    // true in practice, since a page is displayed at some fitted size, not
    // its own native page-unit dimensions.

    func testViewPointScalesAPageSpacePointUpByAGreaterThanOneContentScale() {
        let converted = InkCanvasView.viewPoint(forPageSpace: CGPoint(x: 100, y: 50), contentScale: 2)
        XCTAssertEqual(converted, CGPoint(x: 200, y: 100), "ページの単位の座標は、表示倍率をかけた分だけ大きくなる必要があります。")
    }

    /// The typical split-pane case: the page is shown at roughly half its
    /// full-screen size, so a page-space point must shrink accordingly to
    /// land at the correct on-screen spot — this is exactly the scale at
    /// which skipping the conversion produced the most visible jump.
    func testViewPointShrinksAPageSpacePointByAFractionalContentScale() {
        let converted = InkCanvasView.viewPoint(forPageSpace: CGPoint(x: 100, y: 50), contentScale: 0.5)
        XCTAssertEqual(converted, CGPoint(x: 50, y: 25), "ページの単位の座標は、表示倍率が1より小さいときは、その分だけ小さくなる必要があります。")
    }

    /// At exactly `contentScale == 1`, page-space and view-space coincide —
    /// this is the one case where the old bug (handing the page-space point
    /// straight to `convert(_:to:)`) would have accidentally looked correct,
    /// which is exactly why it went unnoticed.
    func testViewPointAtContentScaleOneLeavesThePointUnchanged() {
        let converted = InkCanvasView.viewPoint(forPageSpace: CGPoint(x: 100, y: 50), contentScale: 1)
        XCTAssertEqual(converted, CGPoint(x: 100, y: 50))
    }
}
