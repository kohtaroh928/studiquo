import XCTest
@testable import studiquo

/// Coverage for two 蛍光ペン (highlighter) spec changes:
/// 1. The pen's hold-to-correct machinery (straighten, snap to
///    ellipse/rectangle/triangle/parabola/curve) must never engage for a
///    highlighter stroke — a highlight is meant to stay freehand.
/// 2. The tool-size slider's heading should say "蛍光ペンの太さ" while the
///    highlighter is active, not the generic "ペンの太さ".
final class InkCanvasHighlighterSpecTests: XCTestCase {
    // MARK: - shouldConsiderHoldCorrection

    func testHoldCorrectionIsConsideredForAnOrdinaryPenStroke() {
        XCTAssertTrue(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: false, isHighlighter: false, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "通常のペンでの描画中は、形への補正を検討してよい必要があります。"
        )
    }

    /// The core regression test: even with nothing else locked, a
    /// highlighter stroke must never proceed to shape correction.
    func testHoldCorrectionIsNeverConsideredForAHighlighterStroke() {
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: false, isHighlighter: true, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "蛍光ペンで描いているときは、直線や図形への補正を検討してはいけません。"
        )
    }

    func testHoldCorrectionIsNotConsideredWhileErasing() {
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: true, isHighlighter: false, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "消しゴム操作中は、形への補正を検討してはいけません(既存の挙動)。"
        )
    }

    func testHoldCorrectionIsNotConsideredWhenAlreadyStraightened() {
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: false, isHighlighter: false, isStraightened: true, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "すでに直線に補正済みのときは、重ねて検討してはいけません(既存の挙動)。"
        )
    }

    func testHoldCorrectionIsNotConsideredWhenAlreadyLockedToAnyShape() {
        let lockedFlags: [(ellipse: Bool, rectangle: Bool, triangle: Bool, parabola: Bool)] = [
            (true, false, false, false), (false, true, false, false),
            (false, false, true, false), (false, false, false, true),
        ]
        for flags in lockedFlags {
            XCTAssertFalse(
                InkCanvasView.shouldConsiderHoldCorrection(
                    isEraser: false, isHighlighter: false, isStraightened: false,
                    isEllipseLocked: flags.ellipse, isRectangleLocked: flags.rectangle,
                    isTriangleLocked: flags.triangle, isParabolaLocked: flags.parabola
                ),
                "すでに何らかの図形に補正済みのときは、重ねて検討してはいけません(既存の挙動)。"
            )
        }
    }

    /// A highlighter stroke must be rejected even when combined with every
    /// other disqualifying flag at once — the highlighter check can't be
    /// accidentally short-circuited by the others.
    func testHoldCorrectionIsNeverConsideredForAHighlighterStrokeEvenCombinedWithOtherFlags() {
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: true, isHighlighter: true, isStraightened: true, isEllipseLocked: true,
                isRectangleLocked: true, isTriangleLocked: true, isParabolaLocked: true
            ),
            "他の条件と組み合わさっていても、蛍光ペンでの補正はやはり無効である必要があります。"
        )
    }

    // MARK: - DrawingToolKind.sizeLabel

    func testPenSizeLabelIsGeneric() {
        XCTAssertEqual(DrawingToolKind.pen.sizeLabel, "ペンの太さ", "ペン選択時の見出しは「ペンの太さ」である必要があります。")
    }

    func testHighlighterSizeLabelIsItsOwn() {
        XCTAssertEqual(
            DrawingToolKind.highlighter.sizeLabel, "蛍光ペンの太さ",
            "蛍光ペン選択時の見出しは「蛍光ペンの太さ」であり、ペンと同じ表記になってはいけません。"
        )
    }

    func testEraserSizeLabelIsUnaffected() {
        XCTAssertEqual(DrawingToolKind.eraser.sizeLabel, "消しゴムの大きさ", "消しゴム選択時の見出しは、今回の変更後も従来通りである必要があります。")
    }
}
