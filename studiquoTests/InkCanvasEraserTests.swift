import XCTest
@testable import studiquo

/// Coverage for the eraser tool: bitmap-style erasing (only the touched
/// portion of a stroke is removed, splitting it into fragments where
/// needed), the cursor that previews its reach, and width changes. These
/// are pure functions of the strokes/eraser path involved, so exact,
/// hand-built geometry can exercise them without a live canvas.
final class InkCanvasEraserTests: XCTestCase {
    /// A straight horizontal line from (0, y) to (100, y), densely sampled
    /// so smoothing/resampling inside `erasedStrokes` has enough points to
    /// work with without distorting the line.
    private func horizontalLineStroke(y: CGFloat = 50, width: CGFloat = 4, isHighlighter: Bool = false) -> InkStroke {
        InkStroke(
            points: (0...50).map { i in
                InkPoint(location: CGPoint(x: CGFloat(i) * 2, y: y), force: 0.5, timeOffset: Double(i) / 50)
            },
            colorHex: "#000000",
            width: width,
            isHighlighter: isHighlighter
        )
    }

    // MARK: - 1 & 6: only the touched portion is erased, the rest survives as separate pieces

    func testErasingTheMiddleOfALineSplitsItIntoTwoRemainingFragments() {
        let stroke = horizontalLineStroke()
        // A short eraser pass centered on x=50, wide enough (radius 6) to
        // cut a clean gap out of the middle of the 0...100 line.
        let eraserPath = [CGPoint(x: 47, y: 50), CGPoint(x: 53, y: 50)]

        let result = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 12)

        XCTAssertNotNil(result, "線の途中を消したときは、何かが変化した結果が返る必要があります。")
        guard let result else { return }
        XCTAssertEqual(result.count, 2, "線の真ん中を消したときは、左右2つの破片に分かれて残る必要があります。")
        for fragment in result {
            let maxX = fragment.points.map(\.location.x).max() ?? 0
            let minX = fragment.points.map(\.location.x).min() ?? 0
            XCTAssertFalse(
                (minX...maxX).contains(50) && maxX - minX > 12,
                "消しゴムが触れた範囲をまたいで1つの破片が残ってはいけません。"
            )
        }
    }

    func testErasingOneEndOfALineLeavesASingleShorterFragment() {
        let stroke = horizontalLineStroke()
        // Erase only the left end (x around 0...10).
        let eraserPath = [CGPoint(x: 0, y: 50), CGPoint(x: 10, y: 50)]

        let result = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 12)

        XCTAssertNotNil(result, "端を消したときも、何かが変化した結果が返る必要があります。")
        guard let result else { return }
        XCTAssertEqual(result.count, 1, "片方の端だけを消したときは、残った側が1つの破片として残る必要があります。")
        if let remaining = result.first {
            XCTAssertGreaterThan(
                remaining.points.map(\.location.x).min() ?? 0, 10,
                "消した端の部分は、残った破片に含まれてはいけません。"
            )
        }
    }

    func testErasingTheEntireLineRemovesItCompletely() {
        let stroke = horizontalLineStroke()
        let eraserPath = [CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)]

        let result = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 12)

        XCTAssertNotNil(result, "線全体を消したときも、何かが変化した結果が返る必要があります。")
        XCTAssertEqual(result?.count, 0, "消しゴムの通り道が線全体を覆っているときは、何も残ってはいけません。")
    }

    func testEraserPathThatMissesTheLineLeavesItUntouched() {
        let stroke = horizontalLineStroke()
        // Far away from y=50.
        let eraserPath = [CGPoint(x: 50, y: 500), CGPoint(x: 55, y: 500)]

        let result = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 12)

        XCTAssertNil(result, "消しゴムが触れていない線は、変化なし(nil)として扱われる必要があります。")
    }

    // MARK: - 2: eraser width is reflected

    func testEraserRadiusScalesWithEraserWidth() {
        XCTAssertEqual(InkCanvasView.eraserRadius(for: 10), 5, "消しゴムの半径は、太さの半分になる必要があります。")
        XCTAssertEqual(InkCanvasView.eraserRadius(for: 40), 20, "消しゴムを太くしたら、半径もそれに応じて大きくなる必要があります。")
    }

    func testEraserRadiusNeverGoesBelowOnePoint() {
        XCTAssertEqual(InkCanvasView.eraserRadius(for: 0), 1, "消しゴムの太さがゼロに近くても、消せる範囲が完全になくなってはいけません。")
    }

    func testWiderEraserRemovesMoreOfTheLineThanANarrowerOne() {
        let stroke = horizontalLineStroke()
        let eraserPath = [CGPoint(x: 47, y: 50), CGPoint(x: 53, y: 50)]

        let narrowResult = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 4) ?? [stroke]
        let wideResult = InkCanvasView.erasedStrokes([stroke], eraserPath: eraserPath, eraserWidth: 40) ?? [stroke]

        let narrowRemainingLength = narrowResult.reduce(0) { $0 + ($1.points.map(\.location.x).max() ?? 0) - ($1.points.map(\.location.x).min() ?? 0) }
        let wideRemainingLength = wideResult.reduce(0) { $0 + ($1.points.map(\.location.x).max() ?? 0) - ($1.points.map(\.location.x).min() ?? 0) }

        XCTAssertLessThan(
            wideRemainingLength, narrowRemainingLength,
            "太い消しゴムを使ったときは、細い消しゴムよりも多くの部分が消えている必要があります。"
        )
    }

    // MARK: - 3: cursor position and size track the actual erase reach

    func testEraserCursorIsCenteredOnItsLocation() {
        let rect = InkCanvasView.eraserCursorRect(at: CGPoint(x: 40, y: 60), eraserWidth: 20)
        XCTAssertEqual(rect.midX, 40, accuracy: 0.001, "カーソルの中心は、指定した位置のX座標と一致する必要があります。")
        XCTAssertEqual(rect.midY, 60, accuracy: 0.001, "カーソルの中心は、指定した位置のY座標と一致する必要があります。")
    }

    func testEraserCursorSizeMatchesTheActualEraseRadius() {
        let eraserWidth: CGFloat = 20
        let rect = InkCanvasView.eraserCursorRect(at: .zero, eraserWidth: eraserWidth)
        let expectedDiameter = InkCanvasView.eraserRadius(for: eraserWidth) * 2
        XCTAssertEqual(rect.width, expectedDiameter, accuracy: 0.001, "カーソルの大きさは、実際に消える範囲の直径と一致する必要があります。")
        XCTAssertEqual(rect.height, expectedDiameter, accuracy: 0.001, "カーソルの大きさは、実際に消える範囲の直径と一致する必要があります。")
    }

    // MARK: - 4: slow eraser movement never triggers pen straightening (regression, see InkCanvasHighlighterSpecTests)

    func testHoldCorrectionIsNeverConsideredWhileErasingRegardlessOfOtherFlags() {
        // The same guard that stops the highlighter from snapping into a
        // shape already excludes the eraser too — this is the fix for
        // "消しゴムをゆっくり動かすと直線に補正されてしまう". Verified again
        // here alongside the rest of the eraser's own behavior.
        XCTAssertFalse(
            InkCanvasView.shouldConsiderHoldCorrection(
                isEraser: true, isHighlighter: false, isStraightened: false, isEllipseLocked: false,
                isRectangleLocked: false, isTriangleLocked: false, isParabolaLocked: false
            ),
            "消しゴム操作中は、どれだけゆっくり動かしても直線などへの補正を検討してはいけません。"
        )
    }

    // MARK: - 5: highlighter strokes erase the same way as pen strokes

    func testHighlighterStrokeErasesTheSameWayAsAPenStroke() {
        let highlighterStroke = horizontalLineStroke(isHighlighter: true)
        let eraserPath = [CGPoint(x: 47, y: 50), CGPoint(x: 53, y: 50)]

        let result = InkCanvasView.erasedStrokes([highlighterStroke], eraserPath: eraserPath, eraserWidth: 12)

        XCTAssertNotNil(result, "蛍光ペンの線も、なぞった部分は消える必要があります。")
        XCTAssertEqual(result?.count, 2, "蛍光ペンの線も、ペンと同じように真ん中を消せば2つの破片に分かれる必要があります。")
    }

    // MARK: - 7: erasing works the same at the edge of the page

    func testErasingAtTheOriginCornerOfThePageWorksTheSameAsAnywhereElse() {
        // A line running right along the page's top-left corner, rather
        // than comfortably inside the page.
        let cornerStroke = InkStroke(
            points: (0...20).map { i in InkPoint(location: CGPoint(x: CGFloat(i), y: 0), force: 0.5, timeOffset: 0) },
            colorHex: "#000000",
            width: 4
        )
        let eraserPath = [CGPoint(x: 8, y: 0), CGPoint(x: 12, y: 0)]

        let result = InkCanvasView.erasedStrokes([cornerStroke], eraserPath: eraserPath, eraserWidth: 8)

        XCTAssertNotNil(result, "ページの端(角)にある線でも、なぞれば消える必要があります。")
    }

    // MARK: - Regression: one continuous eraser drag must be exactly one undo step
    //
    // Erasing a line used to report every small step of a single drag as
    // its own change, so "元に戻す" only restored a sliver of the erased
    // line per press instead of the whole thing at once. The fix batches a
    // drag's changes and reports them once, when the eraser lifts.

    func testChangesDuringAnEraserDragAreNeverReportedImmediately() {
        XCTAssertFalse(
            InkCanvasView.shouldReportDrawingChangeImmediately(isMidEraserGesture: true),
            "消しゴムでなぞっている最中の細かい変化は、その都度、元に戻す機能へ報告されてはいけません。"
        )
    }

    func testChangesOutsideAnEraserDragAreStillReportedImmediately() {
        // Ordinary drawing, lasso moves, and cross-pane transfers must keep
        // reporting the instant they happen — only the eraser's own
        // mid-drag steps are held back.
        XCTAssertTrue(
            InkCanvasView.shouldReportDrawingChangeImmediately(isMidEraserGesture: false),
            "消しゴム操作中でなければ、これまで通り変化はすぐに報告される必要があります。"
        )
    }

    func testAnEraserGestureThatActuallyErasedSomethingReportsOnceWhenItEnds() {
        let untouched = InkDrawing(strokes: [horizontalLineStroke()])
        var erased = untouched
        erased.strokes = []

        XCTAssertTrue(
            InkCanvasView.eraserGestureShouldReportOnEnd(start: untouched, current: erased),
            "消しゴムのドラッグ全体で何かが実際に消えた場合は、指を離した時点で1回報告される必要があります。"
        )
    }

    func testAnEraserGestureThatMissedEverythingReportsNothingWhenItEnds() {
        let unchanged = InkDrawing(strokes: [horizontalLineStroke()])

        XCTAssertFalse(
            InkCanvasView.eraserGestureShouldReportOnEnd(start: unchanged, current: unchanged),
            "何もなぞって消せなかった(空振りだった)場合は、元に戻すべき変化がないので報告されてはいけません。"
        )
    }

    func testAnEraserGestureWithNoTrackedStartReportsNothing() {
        // No gesture was ever begun (start is nil) — nothing to compare
        // against, so nothing should be reported, regardless of the
        // current drawing's content.
        let current = InkDrawing(strokes: [horizontalLineStroke()])
        XCTAssertFalse(
            InkCanvasView.eraserGestureShouldReportOnEnd(start: nil, current: current),
            "追跡していたドラッグ開始時点の状態がない場合は、報告してはいけません。"
        )
    }
}
