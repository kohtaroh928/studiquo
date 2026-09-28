import XCTest
@testable import studiquo

/// Coverage for two 蛍光ペン (highlighter) spec points:
/// 1. The hold-to-correct machinery (straighten, snap to
///    ellipse/rectangle/triangle/parabola/curve) engages for a highlighter
///    stroke exactly the same as it does for the pen — a straight
///    underline or a boxed-in region is just as easy to draw with either.
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

    /// The core regression test: with nothing else excluding it, a
    /// highlighter stroke must be just as eligible for shape correction as
    /// an ordinary pen stroke.
    func testHoldCorrectionIsConsideredForAHighlighterStrokeJustLikeAPenStroke() {
        XCTAssertTrue(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: false, isHighlighter: true, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "蛍光ペンで描いているときも、ペンと同様に直線や図形への補正を検討してよい必要があります。"
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

    /// Being a highlighter stroke no longer disqualifies correction on its
    /// own — only the other, still-genuine exclusions (erasing, or a shape
    /// already locked) do, exactly as for the pen.
    func testHighlighterFlagAloneNeverDisqualifiesHoldCorrection() {
        XCTAssertTrue(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: false, isHighlighter: true, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "蛍光ペンであること自体は、もはや補正の可否に影響しない必要があります。"
        )
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: true, isHighlighter: true, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "蛍光ペンであっても、消しゴム操作中であれば従来通り補正を検討してはいけません。"
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
