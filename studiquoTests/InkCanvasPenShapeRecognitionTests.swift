import XCTest
@testable import studiquo

/// Coverage for the pen tool's "hold still to snap into a shape" recognizers.
/// Each recognizer takes the stroke drawn so far and either returns a
/// corrected replacement (rectangle corners, triangle vertices, a fitted
/// parabola/curve) or `nil` if the stroke doesn't clearly look like that
/// shape yet. These are pure functions of the stroke's points, so exact,
/// hand-built geometry can exercise them directly without a live canvas.
final class InkCanvasPenShapeRecognitionTests: XCTestCase {
    private func stroke(_ points: [CGPoint], width: CGFloat = 4) -> InkStroke {
        InkStroke(
            points: points.enumerated().map { index, point in
                InkPoint(location: point, force: 0.5, timeOffset: Double(index) / 10)
            },
            colorHex: "#000000",
            width: width
        )
    }

    // MARK: - looksLikeClosedLoop

    private func circlePoints(center: CGPoint, radius: CGFloat, count: Int, closeGapDegrees: CGFloat = 0) -> [CGPoint] {
        let sweep = 360 - closeGapDegrees
        return (0...count).map { i in
            let angle = CGFloat(i) / CGFloat(count) * sweep * .pi / 180
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    func testClosedCircleLoopIsRecognizedAsClosed() {
        let points = circlePoints(center: CGPoint(x: 50, y: 50), radius: 30, count: 24)
        XCTAssertTrue(
            InkCanvasView.looksLikeClosedLoop(
                points: points, width: 4, start: points.first!, current: points.last!
            ),
            "始点近くまで戻ってきた、十分な大きさの輪は「閉じた輪」として認識される必要があります。"
        )
    }

    func testOpenArcIsNotRecognizedAsClosedLoop() {
        // A three-quarter circle: stops well short of coming back to the start.
        let points = circlePoints(center: CGPoint(x: 50, y: 50), radius: 30, count: 24, closeGapDegrees: 90)
        XCTAssertFalse(
            InkCanvasView.looksLikeClosedLoop(
                points: points, width: 4, start: points.first!, current: points.last!
            ),
            "始点まで戻ってきていない、開いた弧は「閉じた輪」として認識されてはいけません。"
        )
    }

    func testTooFewPointsIsNotClosedLoop() {
        let points = circlePoints(center: CGPoint(x: 50, y: 50), radius: 30, count: 6)
        XCTAssertFalse(
            InkCanvasView.looksLikeClosedLoop(
                points: points, width: 4, start: points.first!, current: points.last!
            ),
            "点の数が足りない場合は、閉じた輪として認識されてはいけません。"
        )
    }

    func testTooSmallLoopIsNotClosedLoop() {
        let points = circlePoints(center: CGPoint(x: 50, y: 50), radius: 5, count: 24)
        XCTAssertFalse(
            InkCanvasView.looksLikeClosedLoop(
                points: points, width: 4, start: points.first!, current: points.last!
            ),
            "小さすぎる輪は、閉じた輪として認識されてはいけません。"
        )
    }

    // MARK: - rectangleIfClosedLoop

    /// Walks the perimeter of `rect`, `perSide` points per edge, back to the
    /// start — an idealized hand-drawn rectangle with no rounding error.
    private func rectanglePerimeterPoints(_ rect: CGRect, perSide: Int = 8) -> [CGPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY),
        ]
        var points: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for step in 0..<perSide {
                let t = CGFloat(step) / CGFloat(perSide)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(corners.last!)
        return points
    }

    func testExactRectanglePerimeterIsRecognized() {
        // 100x60: aspect ratio 1.67, well outside the 0.8...1.25 band that
        // `correctedRectangleBounds` squares up, so the recognized shape's
        // bounds should come back unchanged from the original rectangle.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let result = InkCanvasView.rectangleIfClosedLoop(stroke(rectanglePerimeterPoints(rect)))
        XCTAssertNotNil(result, "各辺・各角にきちんと点が乗っている四角形は、四角形として認識される必要があります。")
        if let result {
            let bounds = result.points.map(\.location).reduce(CGRect(origin: result.points[0].location, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            XCTAssertEqual(bounds.width, rect.width, accuracy: 1, "認識された四角形の幅は、元の輪の幅と一致する必要があります。")
            XCTAssertEqual(bounds.height, rect.height, accuracy: 1, "認識された四角形の高さは、元の輪の高さと一致する必要があります。")
        }
    }

    func testTooFewPointsIsNotRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let points = Array(rectanglePerimeterPoints(rect).prefix(6))
        XCTAssertNil(
            InkCanvasView.rectangleIfClosedLoop(stroke(points)),
            "点の数が足りない場合は、四角形として認識されてはいけません。"
        )
    }

    func testOpenLoopIsNotRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        // Drop the closing run back to the start, leaving the loop open.
        let points = Array(rectanglePerimeterPoints(rect).dropLast(8))
        XCTAssertNil(
            InkCanvasView.rectangleIfClosedLoop(stroke(points)),
            "始点まで戻ってきていない開いた輪は、四角形として認識されてはいけません。"
        )
    }

    func testTooSmallLoopIsNotRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 6)
        XCTAssertNil(
            InkCanvasView.rectangleIfClosedLoop(stroke(rectanglePerimeterPoints(rect))),
            "小さすぎる輪は、四角形として認識されてはいけません。"
        )
    }

    // MARK: - triangleIfClosedLoop

    private func trianglePerimeterPoints(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, perSide: Int = 8) -> [CGPoint] {
        let corners = [a, b, c, a]
        var points: [CGPoint] = []
        for (from, to) in zip(corners, corners.dropFirst()) {
            for step in 0..<perSide {
                let t = CGFloat(step) / CGFloat(perSide)
                points.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        points.append(corners.last!)
        return points
    }

    func testExactTrianglePerimeterIsRecognized() {
        let points = trianglePerimeterPoints(
            CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 90), CGPoint(x: 0, y: 90)
        )
        XCTAssertNotNil(
            InkCanvasView.triangleIfClosedLoop(stroke(points)),
            "各辺にきちんと点が乗っている三角形は、三角形として認識される必要があります。"
        )
    }

    func testTooFewPointsIsNotTriangle() {
        let points = Array(trianglePerimeterPoints(
            CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 90), CGPoint(x: 0, y: 90)
        ).prefix(6))
        XCTAssertNil(
            InkCanvasView.triangleIfClosedLoop(stroke(points)),
            "点の数が足りない場合は、三角形として認識されてはいけません。"
        )
    }

    func testOpenLoopIsNotTriangle() {
        let points = Array(trianglePerimeterPoints(
            CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 90), CGPoint(x: 0, y: 90)
        ).dropLast(8))
        XCTAssertNil(
            InkCanvasView.triangleIfClosedLoop(stroke(points)),
            "始点まで戻ってきていない開いた輪は、三角形として認識されてはいけません。"
        )
    }

    // MARK: - parabolaIfRecognized

    /// Points lying exactly on `y = a*t^2 + b*t + c` in the same normalized
    /// space the recognizer itself fits in, mapped out to real page-space
    /// coordinates — so the recovered fit should reproduce `a`/`b` exactly.
    private func parabolaPoints(a: CGFloat, b: CGFloat, c: CGFloat, midX: CGFloat = 50, halfWidth: CGFloat = 50, minY: CGFloat = 0, height: CGFloat = 100, count: Int = 21) -> [CGPoint] {
        (0..<count).map { i in
            let t = -1 + 2 * CGFloat(i) / CGFloat(count - 1)
            let x = midX + t * halfWidth
            let y = minY + (a * t * t + b * t + c) * height
            return CGPoint(x: x, y: y)
        }
    }

    func testExactUpwardParabolaIsRecognized() {
        // f(t) = t^2: spans exactly [0, 1], so the generated points' own
        // min/max reproduce `minY`/`height` exactly and the fit is perfect.
        let points = parabolaPoints(a: 1, b: 0, c: 0)
        XCTAssertNotNil(
            InkCanvasView.parabolaIfRecognized(stroke(points)),
            "きれいな放物線を描いたときは、放物線として認識される必要があります。"
        )
    }

    func testStraightLineIsNotRecognizedAsParabola() {
        // f(t) = (t + 1) / 2: perfectly linear, curvature (a) is zero.
        let points = parabolaPoints(a: 0, b: 0.5, c: 0.5)
        XCTAssertNil(
            InkCanvasView.parabolaIfRecognized(stroke(points)),
            "直線には曲がりがないため、放物線として認識されてはいけません。"
        )
    }

    func testTooFewPointsIsNotParabola() {
        let points = Array(parabolaPoints(a: 1, b: 0, c: 0).prefix(6))
        XCTAssertNil(
            InkCanvasView.parabolaIfRecognized(stroke(points)),
            "点の数が足りない場合は、放物線として認識されてはいけません。"
        )
    }

    // MARK: - curveIfRecognized

    func testSineWaveIsRecognizedAsCurve() {
        // An exact sine, well clear of the vertical-line and straightness
        // guards: monotonic in x by construction, and visibly bowed rather
        // than straight.
        let points = (0..<40).map { i -> CGPoint in
            let t = CGFloat(i) / 39 * 2 - 1
            return CGPoint(x: 50 + t * 50, y: sin(1.6 * t) * 50)
        }
        XCTAssertNotNil(
            InkCanvasView.curveIfRecognized(stroke(points)),
            "きれいな波型の曲線を描いたときは、曲線として認識される必要があります。"
        )
    }

    func testStraightLineIsNotRecognizedAsCurve() {
        let points = (0..<20).map { i in
            CGPoint(x: CGFloat(i) * 5, y: CGFloat(i) * 5)
        }
        XCTAssertNil(
            InkCanvasView.curveIfRecognized(stroke(points)),
            "直線には曲がりがないため、曲線として認識されてはいけません(直線補正に任せる必要があります)。"
        )
    }

    func testTooFewPointsIsNotCurve() {
        let points = (0..<6).map { i in CGPoint(x: CGFloat(i) * 5, y: sin(CGFloat(i)) * 50) }
        XCTAssertNil(
            InkCanvasView.curveIfRecognized(stroke(points)),
            "点の数が足りない場合は、曲線として認識されてはいけません。"
        )
    }

    func testStrokeThatDoublesBackOnItselfIsNotRecognizedAsCurve() {
        // Goes right, then back left — fails the vertical-line test a
        // function y = f(x) requires.
        let outAndBack = (0..<10).map { CGPoint(x: CGFloat($0) * 10, y: 0) }
            + (0..<10).map { CGPoint(x: CGFloat(90 - $0 * 10), y: 20) }
        XCTAssertNil(
            InkCanvasView.curveIfRecognized(stroke(outAndBack)),
            "x方向に行ったり来たりする(関数として表せない)線は、曲線として認識されてはいけません。"
        )
    }

    // MARK: - correctedRectangleBounds (used by the rectangle/square snap)

    func testNearSquareBoundsAreSquared() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 90) // ratio 1.11, inside 0.8...1.25
        let corrected = InkCanvasView.correctedRectangleBounds(bounds)
        XCTAssertEqual(corrected.width, corrected.height, accuracy: 0.01, "正方形に近い比率の四角形は、きれいな正方形に補正される必要があります。")
    }

    func testNonSquareBoundsAreLeftUnchanged() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 40) // ratio 2.5, outside 0.8...1.25
        let corrected = InkCanvasView.correctedRectangleBounds(bounds)
        XCTAssertEqual(corrected, bounds, "はっきり長方形の比率のものは、正方形に補正されず元の形のままである必要があります。")
    }
}
