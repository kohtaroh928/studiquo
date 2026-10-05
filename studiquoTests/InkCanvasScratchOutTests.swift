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
}
