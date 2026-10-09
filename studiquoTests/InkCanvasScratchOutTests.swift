import XCTest
@testable import studiquo

final class InkCanvasScratchOutTests: XCTestCase {
    private func horizontalStroke(y: CGFloat, width: CGFloat = 4) -> InkStroke {
        InkStroke(
            points: (0...50).map { index in
                InkPoint(location: CGPoint(x: CGFloat(index) * 2, y: y), force: 0.5, timeOffset: Double(index) / 50)
            },
            colorHex: "#000000",
            width: width
        )
    }

    private func denseScribble(centerY: CGFloat = 50, width: CGFloat = 4) -> InkStroke {
        let points = (0..<36).map { index -> InkPoint in
            let x = 40 + CGFloat(index % 6) * 4
            let y = centerY + (index.isMultiple(of: 2) ? -2 : 2)
            return InkPoint(location: CGPoint(x: x, y: y), force: 0.5, timeOffset: Double(index) / 36)
        }
        return InkStroke(points: points, colorHex: "#000000", width: width)
    }

    func testScratchOutCoversStrokeItActuallyTouches() {
        let target = horizontalStroke(y: 50)
        let scribble = denseScribble(centerY: 50)

        XCTAssertTrue(InkCanvasView.scratchOutCoversStroke(target, scribble: scribble, contentScale: 1))
    }

    func testScratchOutDoesNotEraseNearbyUntouchedStroke() {
        let nearbyButUntouched = horizontalStroke(y: 62)
        let scribble = denseScribble(centerY: 50)

        XCTAssertFalse(
            InkCanvasView.scratchOutCoversStroke(nearbyButUntouched, scribble: scribble, contentScale: 1),
            "くしゃくしゃ消しは、実際に触れた線だけを対象にし、近くにあるだけの線を巻き込んではいけません。"
        )
    }


    func testScratchOutOnlyRemovesTouchedPartOfStroke() throws {
        let target = horizontalStroke(y: 50)
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        XCTAssertEqual(result.count, 2, "線の中央だけをくしゃくしゃした場合、線全体ではなく左右の断片が残る必要があります。")
        XCTAssertTrue(result.contains { stroke in stroke.points.contains { $0.location.x < 30 } })
        XCTAssertTrue(result.contains { stroke in stroke.points.contains { $0.location.x > 70 } })
        XCTAssertFalse(
            result.flatMap(\.points).contains { (40...60).contains($0.location.x) },
            "くしゃくしゃが重なった中央部分だけが消えて、触れていない端は残る必要があります。"
        )
    }

    func testScratchOutPartialEraseKeepsNearbyUntouchedStroke() throws {
        let target = horizontalStroke(y: 50)
        let nearbyButUntouched = horizontalStroke(y: 62)
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target, nearbyButUntouched], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.contains { $0.id == nearbyButUntouched.id }, "近くにあるだけでくしゃくしゃが触れていない線は、そのまま残る必要があります。")
        XCTAssertEqual(result.filter { $0.id != nearbyButUntouched.id }.count, 2)
    }

    func testScratchOutIgnoresStrokeThatOnlyLiesInsideTheHitMargin() throws {
        // The scribble's ink (half-width 2) ends at y=54; this line's ink starts
        // at y=55, so the two never overlap even though the line sits inside the
        // hit radius (6pt). It must be left alone.
        let almostTouching = horizontalStroke(y: 57)
        let touched = horizontalStroke(y: 50)
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([touched, almostTouching], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.contains { $0.id == almostTouching.id }, "ペンの線が少しも重なっていないストロークは、消してはいけません。")
        XCTAssertFalse(InkCanvasView.scratchOutCoversStroke(almostTouching, scribble: scribble, contentScale: 1))
    }

    func testScratchOutIgnoresStrokeEnclosedBetweenPassesButNeverCrossed() throws {
        // Zig-zag passes 14pt apart (y 40 <-> 60). The short line at y=50
        // sits in the gap between two diagonals: closing the footprint would
        // swallow it, but the pen line never overlaps it.
        let scribble = InkStroke(points: (0..<8).map { index in
            InkPoint(location: CGPoint(x: 40 + CGFloat(index) * 14, y: index.isMultiple(of: 2) ? 40 : 60),
                     force: 0.5, timeOffset: Double(index) / 8)
        }, colorHex: "#000000", width: 1)
        let enclosed = InkStroke(points: (51...57).map {
            InkPoint(location: CGPoint(x: CGFloat($0), y: 50), force: 0.5, timeOffset: 0)
        }, colorHex: "#000000", width: 1)
        let crossed = InkStroke(points: (0...100).map {
            InkPoint(location: CGPoint(x: 40 + CGFloat($0), y: 50), force: 0.5, timeOffset: 0)
        }, colorHex: "#000000", width: 1)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([crossed, enclosed], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.contains { $0.id == enclosed.id }, "パスの間に囲まれていても、ペンの線が重なっていないストロークは残す必要があります。")
        XCTAssertEqual(result.map(\.id), [enclosed.id], "ペンの線が横切ったストロークだけが消え、断片も残らない必要があります。")
    }

    func testScratchOutMarginShrinksInPageUnitsWhenZoomedIn() throws {
        let line = horizontalStroke(y: 50)
        let scribble = denseScribble(centerY: 50)

        func remaining(at scale: CGFloat) throws -> [CGPoint] {
            try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([line], scribble: scribble, contentScale: scale)).flatMap(\.points).map(\.location)
        }

        XCTAssertFalse(try remaining(at: 1).contains { $0.x > 34 && $0.x < 36 }, "等倍では約6pt分の余白が消える")
        XCTAssertTrue(try remaining(at: 4).contains { $0.x > 34 && $0.x < 38 }, "4倍ズームでは余白が画面上で同じ大きさのまま、ページ上では狭くなる")
    }

    func testScratchOutTouchGateDoesNotDependOnContentScale() throws {
        let almostTouching = horizontalStroke(y: 57)
        let scribble = denseScribble(centerY: 50)

        for scale: CGFloat in [0.5, 2, 4] {
            let result = InkCanvasView.scratchOutErasedStrokes([horizontalStroke(y: 50), almostTouching], scribble: scribble, contentScale: scale)
            XCTAssertTrue(try XCTUnwrap(result).contains { $0.id == almostTouching.id }, "scale \(scale)")
        }
    }

    func testScratchOutRadiusTracksStrokeAndScribbleWidthWithoutLargeFixedHalo() {
        let radius = InkCanvasView.scratchOutHitRadius(strokeWidth: 4, scribbleWidth: 4, contentScale: 1)

        XCTAssertLessThan(radius, 10)
    }

    func testScratchOutRemovesStrokeItMostlyCovers() throws {
        let target = InkStroke(
            points: (0...20).map { InkPoint(location: CGPoint(x: 40 + CGFloat($0), y: 50), force: 0.5, timeOffset: Double($0) / 20) },
            colorHex: "#000000",
            width: 4
        )
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.isEmpty, "くしゃくしゃが大部分を覆った線は、端だけを残さず全体を消す必要があります。")
    }

    func testScratchOutLeavesNoTinySliverBesideScribble() throws {
        // Ink extends 6pt past the scribble on the right: too short to be worth keeping.
        let target = InkStroke(
            points: (0...30).map { InkPoint(location: CGPoint(x: 20 + CGFloat($0) * 2, y: 50), force: 0.5, timeOffset: Double($0) / 30) },
            colorHex: "#000000",
            width: 4
        )
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        for stroke in result {
            XCTAssertGreaterThanOrEqual(stroke.pathLength, 12, "くしゃくしゃのすぐ脇に短い切れ端を残してはいけません。")
        }
    }

    func testScratchOutClosesGapsBetweenWidelySpacedPasses() throws {
        // Passes 14pt apart leave gaps wider than the hit radius.
        let points = (0..<8).map { index -> InkPoint in
            let x = 40 + CGFloat(index) * 14
            let y: CGFloat = index.isMultiple(of: 2) ? 40 : 60
            return InkPoint(location: CGPoint(x: x, y: y), force: 0.5, timeOffset: Double(index) / 8)
        }
        let scribble = InkStroke(points: points, colorHex: "#000000", width: 4)
        let target = InkStroke(
            points: (0...100).map { InkPoint(location: CGPoint(x: 40 + CGFloat($0), y: 50), force: 0.5, timeOffset: Double($0) / 100) },
            colorHex: "#000000",
            width: 4
        )

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Cursive vs scribble

    private func cursiveWord(letters: Int) -> [CGPoint] {
        let steps = letters * 40
        return (0...steps).map { index in
            let theta = CGFloat(index) / 40 * 2 * .pi
            return CGPoint(x: 20 + 3 * theta + 7 * cos(theta), y: 60 + 12 * sin(theta))
        }
    }

    func testCursiveOneStrokeWritingIsNotScratchMotion() {
        for letters in [4, 6, 9] {
            XCTAssertFalse(InkCanvasView.hasScratchMotion(cursiveWord(letters: letters)), "\(letters)文字の筆記体")
        }
    }

    func testCompactZigZagIsScratchMotion() {
        let points = (0..<14).map { index in
            CGPoint(x: index.isMultiple(of: 2) ? 0 : 50, y: CGFloat(index) * 2)
        }
        XCTAssertTrue(InkCanvasView.hasScratchMotion(points))
    }

    func testDriftingDenseZigZagIsScratchMotion() {
        let points = (0..<30).map { index in
            CGPoint(x: CGFloat(index) * 2.5, y: index.isMultiple(of: 2) ? 40 : 60)
        }
        XCTAssertTrue(InkCanvasView.hasScratchMotion(points))
    }

    func testScribbleOverBlankPaperDoesNotErase() {
        let faraway = horizontalStroke(y: 300)
        XCTAssertNil(InkCanvasView.scratchOutErasedStrokes([faraway], scribble: denseScribble(centerY: 50), contentScale: 1))
    }

    // MARK: - Touch gate: boundaries and shapes

    private func line(y: CGFloat, width: CGFloat) -> InkStroke {
        InkStroke(points: (0...50).map { InkPoint(location: CGPoint(x: CGFloat($0) * 2, y: y), force: 0.5, timeOffset: 0) },
                  colorHex: "#000000", width: width)
    }

    func testTouchGateBoundaryIsExactlyTheSumOfHalfWidths() {
        let target = line(y: 50, width: 4)          // half 2
        let reachY: CGFloat = 54                      // + scribble half 2

        XCTAssertTrue(InkCanvasView.scratchOutTouches(target, scribblePath: [CGPoint(x: 0, y: reachY), CGPoint(x: 100, y: reachY)], scribbleWidth: 4))
        XCTAssertFalse(InkCanvasView.scratchOutTouches(target, scribblePath: [CGPoint(x: 0, y: reachY + 0.1), CGPoint(x: 100, y: reachY + 0.1)], scribbleWidth: 4))
    }

    func testTouchGateBoundaryFollowsBothWidths() {
        let path: (CGFloat) -> [CGPoint] = { y in [CGPoint(x: 0, y: y), CGPoint(x: 100, y: y)] }

        // Thick line (half 5) + thin pen (half 1): reaches 6.
        let thick = line(y: 50, width: 10)
        XCTAssertTrue(InkCanvasView.scratchOutTouches(thick, scribblePath: path(56), scribbleWidth: 2))
        XCTAssertFalse(InkCanvasView.scratchOutTouches(thick, scribblePath: path(56.5), scribbleWidth: 2))

        // Thin line (half 0.5) + thick pen (half 5): reaches 5.5.
        let thin = line(y: 50, width: 1)
        XCTAssertTrue(InkCanvasView.scratchOutTouches(thin, scribblePath: path(55.5), scribbleWidth: 10))
        XCTAssertFalse(InkCanvasView.scratchOutTouches(thin, scribblePath: path(56), scribbleWidth: 10))
    }

    func testTouchGateOnCorrectedRectangleOnlyCountsItsEdges() {
        let corners = [(20, 20), (80, 20), (80, 80), (20, 80), (20, 20)]
        let rectangle = InkStroke(points: corners.map { InkPoint(location: CGPoint(x: $0.0, y: $0.1), force: 0.5, timeOffset: 0) },
                                  colorHex: "#000000", width: 2)

        let inside = [CGPoint(x: 30, y: 50), CGPoint(x: 70, y: 50)]
        let crossingEdge = [CGPoint(x: 10, y: 50), CGPoint(x: 30, y: 50)]

        XCTAssertFalse(InkCanvasView.scratchOutTouches(rectangle, scribblePath: inside, scribbleWidth: 2), "枠の内側をなぞっただけでは、辺に触れていないので対象外です。")
        XCTAssertTrue(InkCanvasView.scratchOutTouches(rectangle, scribblePath: crossingEdge, scribbleWidth: 2))
    }

    func testTouchGateOnSinglePointDot() {
        let dot = InkStroke(points: [InkPoint(location: CGPoint(x: 50, y: 50), force: 0.5, timeOffset: 0)], colorHex: "#000000", width: 4)

        XCTAssertTrue(InkCanvasView.scratchOutTouches(dot, scribblePath: [CGPoint(x: 40, y: 50), CGPoint(x: 60, y: 50)], scribbleWidth: 4))
        XCTAssertFalse(InkCanvasView.scratchOutTouches(dot, scribblePath: [CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 60)], scribbleWidth: 4))
    }

    func testTouchGateOnTwoPointLineChecksItsMiddle() {
        let corrected = InkStroke(points: [InkPoint(location: CGPoint(x: 0, y: 50), force: 0.5, timeOffset: 0),
                                           InkPoint(location: CGPoint(x: 100, y: 50), force: 0.5, timeOffset: 1)],
                                  colorHex: "#000000", width: 4)

        XCTAssertTrue(InkCanvasView.scratchOutTouches(corrected, scribblePath: [CGPoint(x: 50, y: 40), CGPoint(x: 50, y: 60)], scribbleWidth: 4), "補正済みの直線は端点だけでなく中央でも触れ判定になる必要があります。")
        XCTAssertFalse(InkCanvasView.scratchOutTouches(corrected, scribblePath: [CGPoint(x: 50, y: 70), CGPoint(x: 50, y: 90)], scribbleWidth: 4))
    }

    func testOnlyTheTouchedStrokeOfSeveralNearbyOnesIsChanged() throws {
        let touched = horizontalStroke(y: 50)
        let above = horizontalStroke(y: 43)
        let below = horizontalStroke(y: 57)
        let scribble = denseScribble(centerY: 50)

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([above, touched, below], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.contains { $0.id == above.id })
        XCTAssertTrue(result.contains { $0.id == below.id })
        XCTAssertEqual(result.first { $0.id == above.id }?.points.count, above.points.count, "触れていない線の点は一つも削られてはいけません。")
        XCTAssertEqual(result.first { $0.id == below.id }?.points.count, below.points.count)
        XCTAssertFalse(result.contains { $0.id == touched.id })
    }

    func testScribbleThatTouchesNothingReturnsNilEvenNextToInk() {
        // Within the loose ink-proximity gate but never overlapping.
        XCTAssertNil(InkCanvasView.scratchOutErasedStrokes([horizontalStroke(y: 57)], scribble: denseScribble(centerY: 50), contentScale: 1))
    }

    // MARK: - Hold-to-shape suppression

    func testHoldSuppressionIgnoresStrokeWithinOldMarginAtEveryScale() {
        let touched = horizontalStroke(y: 50)
        let almost = horizontalStroke(y: 57) // inside the old 6pt margin, ink gap of 1pt
        let scribble = denseScribble(centerY: 50)

        for scale: CGFloat in [0.5, 1, 2, 4] {
            XCTAssertTrue(InkCanvasView.scratchOutCoversStroke(touched, scribble: scribble, contentScale: scale), "scale \(scale)")
            XCTAssertFalse(InkCanvasView.scratchOutCoversStroke(almost, scribble: scribble, contentScale: scale), "scale \(scale)")
        }
    }

    // MARK: - Pen-up integration, zoom, performance

    private var zigZagScribble: [CGPoint] {
        (0..<30).map { CGPoint(x: CGFloat($0) * 2.5, y: $0.isMultiple(of: 2) ? 40 : 60) }
    }

    @MainActor
    private func canvas(zoom: CGFloat, contentScale: CGFloat = 1, strokes: [InkStroke]) -> (InkCanvasView, UIView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let canvas = InkCanvasView(frame: container.bounds)
        canvas.contentScale = contentScale
        canvas.strokeWidth = 4
        canvas.setDrawing(InkDrawing(strokes: strokes))
        container.addSubview(canvas)
        container.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        window.addSubview(container)
        window.isHidden = false
        return (canvas, container, window)
    }

    @MainActor
    func testScribbleOverBlankPaperStaysAsOrdinaryInkWhenPenLifts() {
        let (canvas, _, window) = canvas(zoom: 1, strokes: [horizontalStroke(y: 57)])
        _ = window

        // Swings 40...52: its ink ends at y=54, one point short of the line's ink (y=55...59).
        canvas.commitPenStrokeForTesting((0..<30).map { CGPoint(x: CGFloat($0) * 2.5, y: $0.isMultiple(of: 2) ? 40 : 52) })

        XCTAssertEqual(canvas.drawing.strokes.count, 2, "何にも触れないスクラッチは、消去ではなく通常のストロークとして残る必要があります。")
        XCTAssertEqual(canvas.drawing.strokes.first?.points.count, horizontalStroke(y: 57).points.count)
    }

    @MainActor
    func testScribbleThatTouchesInkErasesItWhenPenLifts() {
        let (canvas, _, window) = canvas(zoom: 1, strokes: [horizontalStroke(y: 50)])
        _ = window

        canvas.commitPenStrokeForTesting(zigZagScribble)

        XCTAssertFalse(canvas.drawing.strokes.contains { $0.colorHex == "#000000" && $0.points.count == 51 && $0.points.first?.location.x == 0 && $0.points.last?.location.x == 100 }, "触れた線は元のまま残ってはいけません。")
    }

    @MainActor
    func testOnScreenScaleMultipliesContentScaleByPinchZoom() {
        let (canvas, _, window) = canvas(zoom: 4, contentScale: 2, strokes: [])
        _ = window
        XCTAssertEqual(canvas.onScreenScale, 8, accuracy: 0.001)
    }

    @MainActor
    func testOnScreenScaleFallsBackToContentScaleWithoutAWindow() {
        let canvas = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        canvas.contentScale = 1.5
        XCTAssertEqual(canvas.onScreenScale, 1.5, accuracy: 0.001)
    }

    @MainActor
    func testOnScreenScaleStaysPositiveForRotatedMirroredOrDegenerateTransforms() {
        let (canvas, container, window) = canvas(zoom: 1, contentScale: 2, strokes: [])
        _ = window

        container.transform = CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: 3, y: 3)
        XCTAssertEqual(canvas.onScreenScale, 6, accuracy: 0.001)

        container.transform = CGAffineTransform(scaleX: -3, y: 3)
        XCTAssertEqual(canvas.onScreenScale, 6, accuracy: 0.001, "反転していても倍率は正の値になる必要があります。")

        container.transform = CGAffineTransform(scaleX: 0, y: 0)
        XCTAssertEqual(canvas.onScreenScale, 2, accuracy: 0.001, "縮退した変換でも 0 や NaN にならず、幅に合わせた倍率へ戻る必要があります。")
    }

    @MainActor
    func testZoomKeepsTheScratchOutMarginTheSameOnScreen() {
        func survivingX(zoom: CGFloat) -> [CGFloat] {
            let target = InkStroke(points: (0...50).map { InkPoint(location: CGPoint(x: CGFloat($0) * 2, y: 50), force: 0.5, timeOffset: 0) },
                                   colorHex: "#000000", width: 4)
            let (canvas, _, window) = canvas(zoom: zoom, strokes: [target])
            _ = window
            canvas.commitPenStrokeForTesting(zigZagScribble)
            return canvas.drawing.strokes.flatMap(\.points).map(\.location.x).filter { $0 > 75 && $0 < 78 }
        }

        XCTAssertTrue(survivingX(zoom: 1).isEmpty, "等倍では余白(約6pt)ぶん先まで消える")
        XCTAssertFalse(survivingX(zoom: 4).isEmpty, "4倍ズームでは余白がページ上で狭くなり、離れて見える部分は残る")
    }

    func testTouchGateIsFastForManyLongStrokesThatNeverTouch() {
        let strokes = (0..<60).map { _ in
            InkStroke(points: (0...500).map { InkPoint(location: CGPoint(x: CGFloat($0) * 2, y: 66), force: 0.5, timeOffset: 0) },
                      colorHex: "#000000", width: 4)
        }
        let scribble = InkStroke(points: (0..<500).map { InkPoint(location: CGPoint(x: CGFloat($0) * 0.5, y: $0.isMultiple(of: 2) ? 40 : 60), force: 0.5, timeOffset: 0) },
                                 colorHex: "#000000", width: 4)

        let start = Date()
        XCTAssertNil(InkCanvasView.scratchOutErasedStrokes(strokes, scribble: scribble, contentScale: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "触れない長い線が多くても、ペンを上げた処理が長引いてはいけません。")
    }
}
