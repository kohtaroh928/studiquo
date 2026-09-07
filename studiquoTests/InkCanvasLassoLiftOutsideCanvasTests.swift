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
}
