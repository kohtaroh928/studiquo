import CoreGraphics
import XCTest
@testable import studiquo

final class ScribbleClassifierTests: XCTestCase {
    func testEmptyAndTinyInputNeverQualifies() {
        XCTAssertFalse(ScribbleClassifier.analyze([]).qualifies)
        XCTAssertFalse(ScribbleClassifier.analyze([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2, y: 1),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 6, y: 1),
        ]).qualifies)
    }

    func testStraightStrokeIsNotMistakenForScratchOut() {
        let points = stride(from: CGFloat.zero, through: 120, by: 2).map {
            CGPoint(x: $0, y: 30)
        }

        let result = ScribbleClassifier.analyze(points)

        XCTAssertFalse(result.qualifies)
        XCTAssertEqual(result.axisReversals, 0)
        XCTAssertEqual(result.selfIntersections, 0)
    }

    func testSingleCircleIsNotMistakenForScratchOut() {
        let points = (0...64).map { index -> CGPoint in
            let angle = CGFloat(index) / 64 * .pi * 2
            return CGPoint(x: 50 + cos(angle) * 30, y: 50 + sin(angle) * 30)
        }

        let result = ScribbleClassifier.analyze(points)

        XCTAssertFalse(result.qualifies)
        XCTAssertLessThan(result.absoluteTurning, .pi * 2.75)
    }

    func testBackAndForthStrokeQualifiesAsScratchOut() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 45, y: 18),
            CGPoint(x: 0, y: 36),
            CGPoint(x: 45, y: 54),
            CGPoint(x: 0, y: 72),
        ]

        let result = ScribbleClassifier.analyze(points)

        XCTAssertTrue(result.qualifies)
        XCTAssertGreaterThanOrEqual(result.axisReversals, 2)
        XCTAssertGreaterThanOrEqual(result.directionChanges, 2)
        XCTAssertGreaterThanOrEqual(result.lengthRatio, 1.4)
    }

    func testClassificationDoesNotDependOnTouchSamplingDensity() {
        let sparse = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 45, y: 18),
            CGPoint(x: 0, y: 36),
            CGPoint(x: 45, y: 54),
            CGPoint(x: 0, y: 72),
        ]
        let dense = denselySampled(sparse, samplesPerSegment: 30)

        let sparseResult = ScribbleClassifier.analyze(sparse)
        let denseResult = ScribbleClassifier.analyze(dense)

        XCTAssertTrue(sparseResult.qualifies)
        XCTAssertEqual(denseResult.qualifies, sparseResult.qualifies)
        XCTAssertEqual(denseResult.axisReversals, sparseResult.axisReversals)
        XCTAssertEqual(denseResult.directionChanges, sparseResult.directionChanges)
    }

    private func denselySampled(_ vertices: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
        guard let first = vertices.first else { return [] }
        var points = [first]
        for (start, end) in zip(vertices, vertices.dropFirst()) {
            for sample in 1...samplesPerSegment {
                let progress = CGFloat(sample) / CGFloat(samplesPerSegment)
                points.append(CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                ))
            }
        }
        return points
    }
}
