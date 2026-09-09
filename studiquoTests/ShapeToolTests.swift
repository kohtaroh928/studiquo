import XCTest
@testable import studiquo

/// Coverage for the 図形ツール(四角形・楕円): a drag defines a bounding
/// box, and lifting commits it — not as ink, but as a movable/resizable
/// `PageElement` (see `addShapeElement` in `NoteEditorView.swift`), the same
/// kind of object a photo is. That distinction matters for two of the five
/// checklist items:
///
/// - Item 3 ("現在の色・太さの設定が図形にも反映されるか"): the CURRENT
///   COLOR does carry over (`colorHex: drawingColorHex`), but the current
///   PEN WIDTH does not — `ExportService.draw(element:pageSize:)` always
///   strokes a rectangle/ellipse element at a fixed `lineWidth = 3`,
///   regardless of `strokeWidth`. The live drag preview, by contrast, *does*
///   use the current pen width (`updateShapePreview` builds its preview
///   stroke with `width: strokeWidth`) — so the border can visibly change
///   thickness the instant the pencil lifts. This is reported as a finding,
///   not "fixed", since it may be a deliberate legibility choice (every
///   shape/photo frame in the app uses the same fixed border) rather than a
///   bug; a test below pins down the *current* behavior either way.
/// - Item 5 ("通常のストロークとして扱われ、消しゴムで消せるか"): shapes are
///   deliberately NOT ink strokes after commit (that's what lets them be
///   dragged/resized/rotated afterwards, per the comment on
///   `addShapeElement`) — but a dedicated compatibility path
///   (`eraseShapeElements`/`shapeOutline`) makes the eraser rub them out
///   along their outline anyway, so the *visible* behavior still matches
///   "the eraser can remove it."
final class ShapeToolTests: XCTestCase {
    // MARK: - 1: the shape is drawn at exactly the dragged size and position

    func testDraggingARectangleCommitsExactlyThatBoundingBox() {
        let rect = InkCanvasView.committedShapeRect(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 130))
        XCTAssertEqual(rect, CGRect(x: 20, y: 30, width: 100, height: 100), "ドラッグした範囲は、そのまま図形の外接矩形になる必要があります。")
    }

    func testShapeElementGeometryRoundTripsBackToTheDraggedRectangleInPageSpace() {
        let pageRect = CGRect(x: 40, y: 60, width: 200, height: 100)
        let geometry = PageCanvasContainer.shapeElementGeometry(for: pageRect, pageWidth: 600, pageHeight: 800)

        // Reconstruct the on-page rectangle from the normalized geometry,
        // the same way `ExportService.draw(element:)` and `shapeOutline`
        // do, and confirm it lands back on the original drag.
        let reconstructed = CGRect(
            x: geometry.centerX * 600 - geometry.width * 600 / 2,
            y: geometry.centerY * 800 - geometry.height * 800 / 2,
            width: geometry.width * 600,
            height: geometry.height * 800
        )
        XCTAssertEqual(reconstructed.origin.x, pageRect.origin.x, accuracy: 0.01, "ドラッグした位置と、実際に配置される図形の位置が一致する必要があります。")
        XCTAssertEqual(reconstructed.origin.y, pageRect.origin.y, accuracy: 0.01, "ドラッグした位置と、実際に配置される図形の位置が一致する必要があります。")
        XCTAssertEqual(reconstructed.width, pageRect.width, accuracy: 0.01, "ドラッグした大きさと、実際に配置される図形の大きさが一致する必要があります。")
        XCTAssertEqual(reconstructed.height, pageRect.height, accuracy: 0.01, "ドラッグした大きさと、実際に配置される図形の大きさが一致する必要があります。")
    }

    func testAnExtremelyTinyDragIsFlooredToAMinimumVisibleSize() {
        // A near-zero drag would otherwise commit an invisible shape.
        let geometry = PageCanvasContainer.shapeElementGeometry(
            for: CGRect(x: 100, y: 100, width: 1, height: 1), pageWidth: 600, pageHeight: 800
        )
        XCTAssertEqual(geometry.width, 0.02, "ごく小さいドラッグでも、図形の大きさは見える最小サイズ未満にはならない必要があります。")
        XCTAssertEqual(geometry.height, 0.02, "ごく小さいドラッグでも、図形の大きさは見える最小サイズ未満にはならない必要があります。")
    }

    func testATapShorterThanTheMinimumDragCommitsNoShapeAtAll() {
        let rect = InkCanvasView.committedShapeRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 52, y: 52))
        XCTAssertNil(rect, "ほとんど動かさないタップは、誤操作として図形を確定させてはいけません。")
    }

    // MARK: - 2: dragging the opposite corner while the start point stays anchored

    func testTheStartPointRemainsOneCornerOfTheShapeRegardlessOfDragDirection() throws {
        let start = CGPoint(x: 100, y: 100)
        let farCorners: [CGPoint] = [
            CGPoint(x: 200, y: 200), // down-right
            CGPoint(x: 20, y: 20),   // up-left
            CGPoint(x: 200, y: 20),  // up-right
            CGPoint(x: 20, y: 200),  // down-left
        ]
        for end in farCorners {
            let rect = try XCTUnwrap(InkCanvasView.committedShapeRect(from: start, to: end))
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            ]
            XCTAssertTrue(
                corners.contains(start),
                "開始点(\(start))は、反対側のどちらへドラッグしても、図形の角の1つであり続ける必要があります(終点 \(end) への場合)。"
            )
        }
    }

    func testResizingByMovingTheFarCornerKeepsTheShapeGrowingFromTheSameStart() throws {
        let start = CGPoint(x: 100, y: 100)
        let smaller = try XCTUnwrap(InkCanvasView.committedShapeRect(from: start, to: CGPoint(x: 150, y: 150)))
        let larger = try XCTUnwrap(InkCanvasView.committedShapeRect(from: start, to: CGPoint(x: 300, y: 250)))

        XCTAssertEqual(smaller.origin, start, "開始点を固定した場合、図形の基準となる角は開始点のままである必要があります。")
        XCTAssertEqual(larger.origin, start, "反対側をさらに大きくドラッグしても、開始点は動いてはいけません。")
        XCTAssertGreaterThan(larger.width, smaller.width, "反対側を遠くへドラッグするほど、図形は大きくなる必要があります。")
        XCTAssertGreaterThan(larger.height, smaller.height, "反対側を遠くへドラッグするほど、図形は大きくなる必要があります。")
    }

    // MARK: - 3: current color and width — color carries over, width currently does not (see header note)

    /// Samples a pixel's RGBA by drawing the image into a 1×1 bitmap
    /// context, independent of the source image's own bitmap layout.
    private func pixel(of image: UIImage, atPixelX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let cgImage = image.cgImage else { return nil }
        var buffer: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    /// Counts how many pixels along a vertical run straddling a rectangle's
    /// top edge are actually dark — a stand-in for measuring the rendered
    /// border's thickness without depending on exact anti-aliasing pixels.
    private func darkPixelCount(atPageX pageX: Int, fromPageY: Int, toPageY: Int, in image: UIImage) -> Int {
        let scale = Int(image.scale)
        var count = 0
        for pageY in fromPageY...toPageY {
            guard let color = pixel(of: image, atPixelX: pageX * scale, y: pageY * scale) else { continue }
            if color.r < 128, color.g < 128, color.b < 128 { count += 1 }
        }
        return count
    }

    func testCommittedShapesRenderWithTheirOwnStoredLineWidthNotAFixedOne() {
        // The fix for "太さの設定が図形に反映されない": a wider `lineWidth`
        // must actually produce a visibly thicker rendered border than a
        // narrower one, on the same shape.
        let thin = PageElement(kind: .rectangle, centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.6, colorHex: "#000000", lineWidth: 2)
        let thinPage = NotePage(order: 0, pageWidth: 200, pageHeight: 200)
        thinPage.addElement(thin)
        let thinImage = ExportService.makeImage(from: thinPage)
        let thinCount = darkPixelCount(atPageX: 100, fromPageY: 20, toPageY: 60, in: thinImage)

        let thick = PageElement(kind: .rectangle, centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.6, colorHex: "#000000", lineWidth: 16)
        let thickPage = NotePage(order: 0, pageWidth: 200, pageHeight: 200)
        thickPage.addElement(thick)
        let thickImage = ExportService.makeImage(from: thickPage)
        let thickCount = darkPixelCount(atPageX: 100, fromPageY: 20, toPageY: 60, in: thickImage)

        XCTAssertGreaterThan(thickCount, thinCount, "太さの設定を大きくした図形は、細い設定の図形よりも枠線が太く(=濃い部分が多く)描かれる必要があります。")
    }

    func testShapeElementsDefaultToTheOriginalFixedBorderWidth() {
        // Shapes drawn before this feature existed carry no `lineWidth` of
        // their own — the default must match the old hardcoded value (3) so
        // they keep rendering exactly as before.
        let element = PageElement(kind: .rectangle)
        XCTAssertEqual(element.lineWidth, 3, "太さの指定がない(=以前からある)図形は、これまで通りの太さで描かれる必要があります。")
    }

    func testTheCommittedShapesLineWidthMatchesTheCurrentPenWidth() {
        // `addShapeElement` passes `lineWidth: drawingWidth` straight
        // through with no substitution — a single property passthrough,
        // the same trivial contract as the color test above.
        let element = PageElement(kind: .rectangle, lineWidth: 11)
        XCTAssertEqual(element.lineWidth, 11, "図形の太さは、確定時点で選ばれていたペンの太さである必要があります。")
    }

    func testTheCommittedShapesColorMatchesTheCurrentDrawingColor() {
        // `addShapeElement` passes `colorHex: drawingColorHex` straight
        // through with no substitution — trivial enough (a single property
        // passthrough) that this documents the contract rather than testing
        // meaningful logic.
        let element = PageElement(kind: .rectangle, colorHex: "#FF3B30")
        XCTAssertEqual(element.colorHex, "#FF3B30", "図形の色は、確定時点で選ばれていた描画色である必要があります。")
    }

    // MARK: - 4: the live preview, before commit, matches the drag so far

    func testTheRectanglePreviewTracksEachIntermediatePositionDuringTheDrag() {
        let start = CGPoint(x: 50, y: 50)
        let waypoints: [(current: CGPoint, expectedBounds: CGRect)] = [
            (CGPoint(x: 60, y: 60), CGRect(x: 50, y: 50, width: 10, height: 10)),
            (CGPoint(x: 90, y: 70), CGRect(x: 50, y: 50, width: 40, height: 20)),
            (CGPoint(x: 30, y: 100), CGRect(x: 30, y: 50, width: 20, height: 50)),
        ]
        for (current, expectedBounds) in waypoints {
            let points = InkCanvasView.shapePoints(kind: .rectangle, from: start, to: current)
            let xs = points.map(\.location.x)
            let ys = points.map(\.location.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            XCTAssertEqual(bounds, expectedBounds, "ドラッグ中のプレビューは、その時点でのドラッグ範囲と一致する必要があります。")
        }
    }

    func testTheRectanglePreviewIsAClosedFourCornerOutline() {
        let points = InkCanvasView.shapePoints(kind: .rectangle, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50))
        XCTAssertEqual(points.first?.location, points.last?.location, "四角形のプレビューの輪郭は、始点と終点が同じ点で閉じている必要があります。")
        XCTAssertEqual(Set(points.map(\.location)).count, 4, "四角形のプレビューは、4つの角を持つ必要があります。")
    }

    func testTheEllipsePreviewStaysWithinTheDraggedBoundingBox() {
        let rect = CGRect(x: 20, y: 20, width: 100, height: 60)
        let points = InkCanvasView.shapePoints(kind: .ellipse, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        for point in points {
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(point.location), "楕円のプレビューは、ドラッグした外接矩形の中に収まる必要があります。")
        }
    }

    // MARK: - 5: after committing, the eraser can still remove the shape (via its outline, not as ink)

    func testEraserSweepingThroughARectanglesEdgeRemovesIt() {
        let page = NotePage(order: 0, pageWidth: 600, pageHeight: 800)
        let element = PageElement(kind: .rectangle, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.1)
        // The rectangle's top edge, in page units, is at y = (0.5 - 0.05) * 800 = 360,
        // spanning x = (0.5 - 0.1)*600 = 240 to (0.5 + 0.1)*600 = 360.
        let sweepAlongTopEdge = [CGPoint(x: 300, y: 360)]

        let swept = PageCanvasContainer.shapeElementsSwept(by: sweepAlongTopEdge, radius: 6, among: [element], on: page)

        XCTAssertEqual(swept.map(\.id), [element.id], "図形の輪郭をなぞった場合、消しゴムでその図形が消えるべきです。")
    }

    func testEraserSweepingThroughTheMiddleOfAShapeLeavesItAlone() {
        // The defining behavior that made this a dedicated outline check
        // rather than a bounding-box check: passing through a circle's
        // interior must not erase it, the same as it wouldn't for hand-drawn
        // ink.
        let page = NotePage(order: 0, pageWidth: 600, pageHeight: 800)
        let element = PageElement(kind: .ellipse, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.1)
        let sweepThroughCenter = [CGPoint(x: 300, y: 400)]

        let swept = PageCanvasContainer.shapeElementsSwept(by: sweepThroughCenter, radius: 6, among: [element], on: page)

        XCTAssertTrue(swept.isEmpty, "図形の内側(輪郭に触れていない部分)をなぞっただけでは、消えてはいけません。")
    }

    func testEraserDoesNotRemoveALockedShape() {
        let page = NotePage(order: 0, pageWidth: 600, pageHeight: 800)
        let element = PageElement(kind: .rectangle, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.1)
        element.isLocked = true
        let sweepAlongTopEdge = [CGPoint(x: 300, y: 360)]

        let swept = PageCanvasContainer.shapeElementsSwept(by: sweepAlongTopEdge, radius: 6, among: [element], on: page)

        XCTAssertTrue(swept.isEmpty, "ロックされた図形は、輪郭をなぞっても消しゴムで消えてはいけません。")
    }

    func testEraserDoesNotRemoveNonShapeElementsLikePhotosOrText() {
        let page = NotePage(order: 0, pageWidth: 600, pageHeight: 800)
        let text = PageElement(kind: .text, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.1)
        let sweepAtItsLocation = [CGPoint(x: 300, y: 400)]

        let swept = PageCanvasContainer.shapeElementsSwept(by: sweepAtItsLocation, radius: 20, among: [text], on: page)

        XCTAssertTrue(swept.isEmpty, "消しゴムは四角形・楕円以外の要素(写真やテキストなど)には効いてはいけません。")
    }
}
