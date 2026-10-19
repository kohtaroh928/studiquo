import CoreGraphics
import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class PageCanvasShapeAndElementGeometryTests: XCTestCase {
    // MARK: - Shape creation & lasso movement geometry

    func testShapeElementGeometryNormalizesToPageUnitsAndClampsTinyDragsToTwoPercent() {
        let normal = PageCanvasContainer.shapeElementGeometry(
            for: CGRect(x: 100, y: 200, width: 200, height: 100),
            pageWidth: 1000,
            pageHeight: 1000
        )
        XCTAssertEqual(normal.centerX, 0.20, accuracy: 0.0001)
        XCTAssertEqual(normal.centerY, 0.25, accuracy: 0.0001)
        XCTAssertEqual(normal.width, 0.20, accuracy: 0.0001)
        XCTAssertEqual(normal.height, 0.10, accuracy: 0.0001)

        // Hairline drag (1x1 pt on a 1000x1000 page) clamps to 0.02 so an invisible shape is never committed.
        let hairline = PageCanvasContainer.shapeElementGeometry(
            for: CGRect(x: 500, y: 500, width: 1, height: 1),
            pageWidth: 1000,
            pageHeight: 1000
        )
        XCTAssertEqual(hairline.width, 0.02, accuracy: 0.0001)
        XCTAssertEqual(hairline.height, 0.02, accuracy: 0.0001)
    }

    func testMovedShapeCenterAndScaledSelectionOffsetKeepShapesInStepWithInkInSplitView() {
        let moved = PageCanvasContainer.movedShapeCenter(
            centerX: 0.5,
            centerY: 0.4,
            offset: CGPoint(x: 60, y: -80),
            pageWidth: 600,
            pageHeight: 800
        )
        XCTAssertEqual(moved.centerX, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.centerY, 0.3, accuracy: 0.0001)

        let displayOffset = PageCanvasContainer.scaledShapeSelectionOffset(
            CGPoint(x: 40, y: -20),
            contentScale: 0.75
        )
        XCTAssertEqual(displayOffset, CGPoint(x: 30, y: -15))
    }

    // MARK: - Cross-pane shape transfer & direct element drop

    func testTransferredShapeGeometryMapsAcrossDifferentlySizedPagesInSplitPanes() {
        // Source page: 600x800, shape at center (300, 400), size 120x80 (0.2 x 0.1).
        // Transferred with 1.5x scale to destination page (1200x1600) at localCenter (600, 800).
        let transferred = PageCanvasContainer.transferredShapeGeometry(
            sourceCenterX: 0.5,
            sourceCenterY: 0.5,
            sourceWidth: 0.2,
            sourceHeight: 0.1,
            sourcePageWidth: 600,
            sourcePageHeight: 800,
            localCenter: CGPoint(x: 600, y: 800),
            sourceCenter: CGPoint(x: 300, y: 400),
            scaleX: 1.5,
            scaleY: 1.5,
            destinationPageWidth: 1200,
            destinationPageHeight: 1600
        )
        XCTAssertEqual(transferred.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(transferred.centerY, 0.5, accuracy: 0.0001)
        // Physical width 120 * 1.5 = 180 on a 1200pt page -> 0.15.
        XCTAssertEqual(transferred.width, 0.15, accuracy: 0.0001)
        XCTAssertEqual(transferred.height, 0.075, accuracy: 0.0001)
    }

    func testDroppedElementGeometryPreservesPhysicalSizeAndClampsCenterWithinPageMargins() {
        let frame = CGRect(x: 100, y: 50, width: 500, height: 700)
        // Drop near the extreme top-left outside the 3% margin -> clamped to 0.03.
        let clamped = PageCanvasContainer.droppedElementGeometry(
            screenPoint: CGPoint(x: 101, y: 51),
            destinationPageGlobalFrame: frame,
            sourceWidth: 0.4,
            sourceHeight: 0.25,
            sourcePageWidth: 600,
            sourcePageHeight: 800,
            destinationPageWidth: 1200,
            destinationPageHeight: 1600
        )
        XCTAssertEqual(clamped.centerX, 0.03, accuracy: 0.0001)
        XCTAssertEqual(clamped.centerY, 0.03, accuracy: 0.0001)
        // Physical size 240x200 on a 1200x1600 destination page -> 0.20 x 0.125.
        XCTAssertEqual(clamped.width, 0.20, accuracy: 0.0001)
        XCTAssertEqual(clamped.height, 0.125, accuracy: 0.0001)
    }

    // MARK: - Eraser outline hit-testing & lock/tool policies

    func testShapeElementsSweptErasesOnlyUnlockedShapesTouchedOnTheirOutlineNotThroughTheirEmptyCenter() {
        let page = NotePage(order: 0, pageWidth: 1000, pageHeight: 1000)
        // Circle centered at (500, 500) with radius 200 (width = 0.4, height = 0.4).
        let circle = PageElement(kind: .ellipse, centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.4)
        let lockedCircle = PageElement(kind: .ellipse, centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.4)
        lockedCircle.isLocked = true
        let photo = PageElement(kind: .image, centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.4)

        // 1. Sweeping right through the empty center (500, 500) must leave the circle untouched.
        let centerSweep = PageCanvasContainer.shapeElementsSwept(
            by: [CGPoint(x: 500, y: 500), CGPoint(x: 510, y: 510)],
            radius: 12,
            among: [circle, lockedCircle, photo],
            on: page
        )
        XCTAssertTrue(centerSweep.isEmpty, "Sweeping inside the hollow interior of a circle must not erase it")

        // 2. Sweeping across the rightmost edge at (700, 500) hits the unlocked circle's outline,
        //    but ignores the locked circle and the photo element.
        let edgeSweep = PageCanvasContainer.shapeElementsSwept(
            by: [CGPoint(x: 700, y: 500)],
            radius: 12,
            among: [circle, lockedCircle, photo],
            on: page
        )
        XCTAssertEqual(edgeSweep.count, 1)
        XCTAssertTrue(edgeSweep.first === circle)
    }

    func testLassoSelectabilityAndToolTouchSuppressionPolicies() {
        let rect = PageElement(kind: .rectangle)
        let ellipse = PageElement(kind: .ellipse)
        let lockedRect = PageElement(kind: .rectangle)
        lockedRect.isLocked = true
        let image = PageElement(kind: .image)
        let text = PageElement(kind: .text)

        XCTAssertTrue(PageCanvasContainer.isSelectableViaLasso(rect))
        XCTAssertTrue(PageCanvasContainer.isSelectableViaLasso(ellipse))
        XCTAssertFalse(PageCanvasContainer.isSelectableViaLasso(lockedRect))
        XCTAssertFalse(PageCanvasContainer.isSelectableViaLasso(image))
        XCTAssertFalse(PageCanvasContainer.isSelectableViaLasso(text))

        XCTAssertTrue(PageCanvasContainer.stopsElementTouches(for: .lasso))
        XCTAssertTrue(PageCanvasContainer.stopsElementTouches(for: .snip))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .pen))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .eraser))
        XCTAssertFalse(PageCanvasContainer.stopsElementTouches(for: .none))
    }
}
