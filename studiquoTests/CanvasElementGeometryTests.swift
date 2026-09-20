import XCTest
@testable import studiquo

/// Coverage for the drag/resize/rotate math shared between the notes
/// canvas's `EditablePageElement` and the new slide canvas editor (design
/// step 4) — see `CanvasElementGeometry`'s doc comment for why this is a
/// pure-math extraction rather than a shared View.
final class CanvasElementGeometryResizeTests: XCTestCase {
    private let origin = CanvasElementGeometry.Frame(centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.2)
    private let canvas = CGSize(width: 1000, height: 1000)

    func testDraggingTheRightHandleGrowsWidthAndShiftsCenterRightByHalfTheGrowth() {
        let result = CanvasElementGeometry.resized(
            from: origin, anchor: .right, translation: CGSize(width: 50, height: 0),
            canvasSize: canvas, rotationDegrees: 0
        )
        XCTAssertEqual(result.width, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result.height, 0.2, accuracy: 0.0001, "dragging the right handle must not touch height")
        XCTAssertEqual(result.centerX, 0.525, accuracy: 0.0001, "the left edge stays pinned, so the centre moves right by half of what was gained")
        XCTAssertEqual(result.centerY, 0.5, accuracy: 0.0001)
    }

    func testDraggingTheBottomHandleGrowsHeightOnly() {
        let result = CanvasElementGeometry.resized(
            from: origin, anchor: .bottom, translation: CGSize(width: 0, height: 40),
            canvasSize: canvas, rotationDegrees: 0
        )
        XCTAssertEqual(result.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.height, 0.24, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.52, accuracy: 0.0001)
    }

    func testA90DegreeRotationTurnsAVerticalScreenDragIntoTheElementsLocalRightEdge() {
        // With the element rotated 90°, its own "right" edge points down on
        // screen — so dragging straight down must grow it exactly the way
        // an un-rotated right-handle drag would, just landing as a centreY
        // shift instead of centreX.
        let result = CanvasElementGeometry.resized(
            from: origin, anchor: .right, translation: CGSize(width: 0, height: 50),
            canvasSize: canvas, rotationDegrees: 90
        )
        XCTAssertEqual(result.width, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.5, accuracy: 0.0001, "a rotated element's right-edge growth must not leak into centreX")
        XCTAssertEqual(result.centerY, 0.525, accuracy: 0.0001)
    }

    func testWidthIsClampedToTheMinimumWhenDraggedBelowIt() {
        let small = CanvasElementGeometry.Frame(centerX: 0.5, centerY: 0.5, width: 0.05, height: 0.05)
        let result = CanvasElementGeometry.resized(
            from: small, anchor: .right, translation: CGSize(width: -40, height: 0),
            canvasSize: canvas, rotationDegrees: 0, minWidthPoints: 32
        )
        XCTAssertEqual(result.width, 0.032, accuracy: 0.0001, "must never shrink below the 32pt floor even if the drag asks for less")
    }

    func testWidthIsClampedToTheCanvasWidthWhenDraggedPastIt() {
        let large = CanvasElementGeometry.Frame(centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.9)
        let result = CanvasElementGeometry.resized(
            from: large, anchor: .right, translation: CGSize(width: 500, height: 0),
            canvasSize: canvas, rotationDegrees: 0
        )
        XCTAssertEqual(result.width, 1.0, accuracy: 0.0001, "must never grow past the canvas's own edge")
    }

    func testTheResultingCentreIsClampedSoTheElementNeverSlidesOffTheCanvas() {
        let nearEdge = CanvasElementGeometry.Frame(centerX: 0.9, centerY: 0.5, width: 0.1, height: 0.1)
        let result = CanvasElementGeometry.resized(
            from: nearEdge, anchor: .right, translation: CGSize(width: 500, height: 0),
            canvasSize: canvas, rotationDegrees: 0
        )
        XCTAssertEqual(result.centerX, 0.98, accuracy: 0.0001)
    }

    func testACornerHandleResizesBothWidthAndHeightTogether() {
        let result = CanvasElementGeometry.resized(
            from: origin, anchor: .bottomRight, translation: CGSize(width: 30, height: 20),
            canvasSize: canvas, rotationDegrees: 0
        )
        XCTAssertEqual(result.width, 0.23, accuracy: 0.0001)
        XCTAssertEqual(result.height, 0.22, accuracy: 0.0001)
    }
}

final class CanvasElementGeometryRotationTests: XCTestCase {
    let center = CGPoint(x: 100, y: 100)

    func testATouchDirectlyAboveTheCentreReadsAsZeroDegrees() {
        let angle = CanvasElementGeometry.rotation(center: center, touch: CGPoint(x: 100, y: 40))
        XCTAssertEqual(angle, 0, accuracy: 0.01)
    }

    func testATouchDirectlyRightOfTheCentreReadsAsNinetyDegrees() {
        let angle = CanvasElementGeometry.rotation(center: center, touch: CGPoint(x: 160, y: 100))
        XCTAssertEqual(angle, 90, accuracy: 0.01)
    }

    func testATouchDirectlyBelowTheCentreReadsAsOneEightyDegrees() {
        let angle = CanvasElementGeometry.rotation(center: center, touch: CGPoint(x: 100, y: 160))
        XCTAssertEqual(angle, 180, accuracy: 0.01)
    }
}

final class CanvasElementGeometryMoveTests: XCTestCase {
    func testAnOrdinaryDragOffsetsTheOriginByTheFractionalTranslation() {
        let point = CanvasElementGeometry.moved(
            from: CGPoint(x: 0.5, y: 0.5), translation: CGSize(width: 100, height: 50),
            canvasSize: CGSize(width: 1000, height: 500)
        )
        XCTAssertEqual(point.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.6, accuracy: 0.0001)
    }

    func testAMoveIsClampedSoTheCentreNeverReachesTheVeryEdge() {
        let point = CanvasElementGeometry.moved(
            from: CGPoint(x: 0.05, y: 0.05), translation: CGSize(width: -100, height: -100),
            canvasSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(point.x, 0.03, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.03, accuracy: 0.0001)
    }
}

/// Coverage for the multi-selection align/distribute commands (design step
/// 4's remaining piece).
final class CanvasElementGeometryAlignDistributeTests: XCTestCase {
    private typealias Frame = CanvasElementGeometry.Frame

    func testAligningLeftMovesEveryFrameToTheLeftmostFramesLeftEdge() {
        let frames = [
            Frame(centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.1), // left edge 0.4
            Frame(centerX: 0.2, centerY: 0.3, width: 0.1, height: 0.1), // left edge 0.15 — the leftmost
        ]
        let result = CanvasElementGeometry.aligned(frames, horizontally: .left)
        XCTAssertEqual(result[0], 0.25, accuracy: 0.0001, "left edge 0.15 + half of frame 0's own width (0.2/2)")
        XCTAssertEqual(result[1], 0.2, accuracy: 0.0001, "already at the target, unchanged")
    }

    func testAligningRightMovesEveryFrameToTheRightmostFramesRightEdge() {
        let frames = [
            Frame(centerX: 0.3, centerY: 0.5, width: 0.2, height: 0.1), // right edge 0.4
            Frame(centerX: 0.8, centerY: 0.3, width: 0.2, height: 0.1), // right edge 0.9 — the rightmost
        ]
        let result = CanvasElementGeometry.aligned(frames, horizontally: .right)
        XCTAssertEqual(result[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.8, accuracy: 0.0001)
    }

    func testAligningCenterHorizontallyUsesTheAverageOfEveryCentre() {
        let frames = [
            Frame(centerX: 0.2, centerY: 0.5, width: 0.1, height: 0.1),
            Frame(centerX: 0.6, centerY: 0.5, width: 0.1, height: 0.1),
        ]
        let result = CanvasElementGeometry.aligned(frames, horizontally: .center)
        XCTAssertEqual(result[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.4, accuracy: 0.0001)
    }

    func testAligningTopAndBottomMirrorTheHorizontalCase() {
        let frames = [
            Frame(centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.2), // top edge 0.4
            Frame(centerX: 0.5, centerY: 0.2, width: 0.1, height: 0.1), // top edge 0.15 — topmost
        ]
        let top = CanvasElementGeometry.aligned(frames, vertically: .top)
        XCTAssertEqual(top[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(top[1], 0.2, accuracy: 0.0001)
    }

    func testDistributingHorizontallyWithFewerThanThreeFramesLeavesThemUnchanged() {
        let frames = [
            Frame(centerX: 0.1, centerY: 0.5, width: 0.1, height: 0.1),
            Frame(centerX: 0.9, centerY: 0.5, width: 0.1, height: 0.1),
        ]
        let result = CanvasElementGeometry.distributedHorizontally(frames)
        XCTAssertEqual(result, [0.1, 0.9], "only 2 frames — nothing to distribute between")
    }

    func testDistributingHorizontallySpacesThreeFramesEvenlyByTheirOwnCentres() {
        // Centres at 0.1, 0.9, and an unevenly-placed 0.3 — after
        // distributing, the middle one lands exactly halfway (0.5),
        // regardless of its original position.
        let frames = [
            Frame(centerX: 0.1, centerY: 0.5, width: 0.1, height: 0.1),
            Frame(centerX: 0.9, centerY: 0.5, width: 0.1, height: 0.1),
            Frame(centerX: 0.3, centerY: 0.5, width: 0.1, height: 0.1),
        ]
        let result = CanvasElementGeometry.distributedHorizontally(frames)
        XCTAssertEqual(result[0], 0.1, accuracy: 0.0001, "the leftmost keeps its own centre as the range's start")
        XCTAssertEqual(result[1], 0.9, accuracy: 0.0001, "the rightmost keeps its own centre as the range's end")
        XCTAssertEqual(result[2], 0.5, accuracy: 0.0001, "the middle one lands exactly halfway")
    }

    func testDistributingVerticallyPreservesInputOrderNotSortedOrder() {
        // Deliberately given out of visual order (bottom-most frame first)
        // to prove the result array lines up with the *input* index, not
        // the sorted rank.
        let frames = [
            Frame(centerX: 0.5, centerY: 0.9, width: 0.1, height: 0.1), // bottom-most, given first
            Frame(centerX: 0.5, centerY: 0.1, width: 0.1, height: 0.1), // top-most, given second
            Frame(centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.1),
        ]
        let result = CanvasElementGeometry.distributedVertically(frames)
        XCTAssertEqual(result[0], 0.9, accuracy: 0.0001, "still the bottom-most frame's own slot, at index 0")
        XCTAssertEqual(result[1], 0.1, accuracy: 0.0001, "still the top-most frame's own slot, at index 1")
        XCTAssertEqual(result[2], 0.5, accuracy: 0.0001)
    }
}

/// Coverage for the drag-time snap-to-alignment ("smart guides") used by
/// design step 4's last piece — a solo element drag only, see
/// `CanvasElementGeometry.smartGuided`'s doc comment.
final class CanvasElementGeometrySmartGuideTests: XCTestCase {
    private typealias Frame = CanvasElementGeometry.Frame
    private let canvas = CGSize(width: 1000, height: 1000)

    func testDraggingWithinToleranceOfAnotherElementsCenterSnapsToItAndReportsAGuide() {
        // Different widths from the dragged element, so only the
        // centre-to-centre pair can land within tolerance — an edge-to-edge
        // match would otherwise tie with it and make the exact guide value
        // ambiguous.
        let other = Frame(centerX: 0.5, centerY: 0.2, width: 0.3, height: 0.1)
        let dragged = Frame(centerX: 0.503, centerY: 0.5, width: 0.1, height: 0.1) // 3pt off at 1000pt wide
        let result = CanvasElementGeometry.smartGuided(dragged, against: [other], canvasSize: canvas)
        XCTAssertEqual(result.frame.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.verticalGuideX ?? .nan, 0.5, accuracy: 0.0001)
    }

    func testDraggingBeyondToleranceDoesNotSnap() {
        // Positioned so none of the dragged frame's own edges/center land
        // near the other element's candidates *or* the canvas's own
        // center (0.5) — smartGuided always considers that too.
        let other = Frame(centerX: 0.2, centerY: 0.2, width: 0.1, height: 0.1)
        let dragged = Frame(centerX: 0.75, centerY: 0.5, width: 0.1, height: 0.1)
        let result = CanvasElementGeometry.smartGuided(dragged, against: [other], canvasSize: canvas)
        XCTAssertEqual(result.frame.centerX, 0.75, accuracy: 0.0001)
        XCTAssertNil(result.verticalGuideX)
    }

    func testAnElementsLeftEdgeSnapsToAnotherElementsRightEdge() {
        let other = Frame(centerX: 0.2, centerY: 0.5, width: 0.2, height: 0.1) // right edge at 0.3
        let dragged = Frame(centerX: 0.351, centerY: 0.5, width: 0.1, height: 0.1) // left edge at 0.301, 1pt off
        let result = CanvasElementGeometry.smartGuided(dragged, against: [other], canvasSize: canvas)
        XCTAssertEqual(result.frame.centerX, 0.35, accuracy: 0.0001, "left edge lands exactly on the other's right edge, keeping its own width")
        XCTAssertEqual(result.verticalGuideX ?? .nan, 0.3, accuracy: 0.0001)
    }

    func testDraggingNearTheCanvassOwnCenterSnapsToItEvenWithNoOtherElements() {
        let dragged = Frame(centerX: 0.498, centerY: 0.5, width: 0.1, height: 0.1)
        let result = CanvasElementGeometry.smartGuided(dragged, against: [], canvasSize: canvas)
        XCTAssertEqual(result.frame.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.verticalGuideX ?? .nan, 0.5, accuracy: 0.0001)
    }

    func testHorizontalAndVerticalSnapsAreIndependent() {
        let other = Frame(centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.1)
        let dragged = Frame(centerX: 0.503, centerY: 0.7, width: 0.1, height: 0.1) // x close, y far
        let result = CanvasElementGeometry.smartGuided(dragged, against: [other], canvasSize: canvas)
        XCTAssertEqual(result.frame.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.frame.centerY, 0.7, accuracy: 0.0001, "y wasn't within tolerance so it must stay put")
        XCTAssertNotNil(result.verticalGuideX)
        XCTAssertNil(result.horizontalGuideY)
    }
}
