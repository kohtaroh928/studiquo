import XCTest
@testable import studiquo

/// Coverage for `PageSnippetRenderer`, the piece the スニップ tool actually
/// hands the dragged rectangle to: it renders the *whole* page (印刷された
/// PDF背景 + インク + other elements, exactly as `ExportService.makeImage`
/// composites them) and crops out just the requested region. These tests
/// cover items 1 (exact region), 2 (printed/background content is included,
/// not just ink), and a defense-in-depth check for a degenerate region —
/// items already covered at the `InkCanvasView` level (small/out-of-bounds
/// drags) are not repeated here.
final class PageSnippetRendererTests: XCTestCase {
    /// A page whose "printed" background is red on the left half and blue
    /// on the right half — standing in for a rasterized PDF page, the way
    /// `NotePage.backgroundImageData` actually holds one (see
    /// `PageRotationService`, PDF import).
    private func pageWithSplitBackground(width: CGFloat = 200, height: CGFloat = 200) -> NotePage {
        let bgImage = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        return NotePage(order: 0, backgroundImageData: bgImage.pngData(), pageWidth: width, pageHeight: height)
    }

    /// A thick, pure-color horizontal stroke, wide enough that sampling
    /// anywhere near its vertical center is solidly stroke-colored despite
    /// anti-aliasing at its edges.
    private func horizontalStroke(y: CGFloat, colorHex: String, width: CGFloat = 20) -> InkStroke {
        InkStroke(
            points: [InkPoint(location: CGPoint(x: -50, y: y), force: 0.5, timeOffset: 0),
                     InkPoint(location: CGPoint(x: 250, y: y), force: 0.5, timeOffset: 1)],
            colorHex: colorHex,
            width: width
        )
    }

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

    // MARK: - 1: the dragged region, and only it, is captured

    func testSnippetCapturesExactlyTheLeftHalfWhenThatIsWhatWasDragged() throws {
        let page = pageWithSplitBackground()
        let snippet = try XCTUnwrap(
            PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 0, y: 0, width: 100, height: 200), label: "test")
        )
        let image = try XCTUnwrap(snippet.image)
        let cg = try XCTUnwrap(image.cgImage)
        // Sample well inside the crop, away from any edge, so scaling
        // rounding can't land on the wrong side of red/blue.
        let color = try XCTUnwrap(pixel(of: image, atPixelX: Int(Double(cg.width) * 0.25), y: Int(Double(cg.height) * 0.5)))
        XCTAssertGreaterThan(color.r, 200, "左半分だけをドラッグした場合、切り取られた画像は赤色の領域だけを含む必要があります。")
        XCTAssertLessThan(color.b, 50, "左半分をドラッグしたのに青色が写っている場合、範囲がずれています。")
    }

    func testSnippetCapturesExactlyTheRightHalfWhenThatIsWhatWasDragged() throws {
        let page = pageWithSplitBackground()
        let snippet = try XCTUnwrap(
            PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 100, y: 0, width: 100, height: 200), label: "test")
        )
        let image = try XCTUnwrap(snippet.image)
        let cg = try XCTUnwrap(image.cgImage)
        let color = try XCTUnwrap(pixel(of: image, atPixelX: Int(Double(cg.width) * 0.75), y: Int(Double(cg.height) * 0.5)))
        XCTAssertGreaterThan(color.b, 200, "右半分だけをドラッグした場合、切り取られた画像は青色の領域だけを含む必要があります。")
        XCTAssertLessThan(color.r, 50, "右半分をドラッグしたのに赤色が写っている場合、範囲がずれています。")
    }

    func testSnippetDimensionsMatchTheDraggedRectanglesAspectRatio() throws {
        let page = pageWithSplitBackground(width: 200, height: 200)
        let snippet = try XCTUnwrap(
            PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 0, y: 0, width: 50, height: 100), label: "test")
        )
        let image = try XCTUnwrap(snippet.image)
        XCTAssertEqual(image.size.width / image.size.height, 0.5, accuracy: 0.02, "切り取った画像の縦横比は、ドラッグした範囲の縦横比と一致する必要があります。")
    }

    // MARK: - 2: printed (PDF) background content is captured, not just ink

    func testSnippetIncludesThePrintedBackgroundEvenWithNoInkAtAll() throws {
        let page = pageWithSplitBackground()
        let snippet = try XCTUnwrap(
            PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 0, y: 0, width: 100, height: 200), label: "test", drawing: InkDrawing())
        )
        let image = try XCTUnwrap(snippet.image)
        let cg = try XCTUnwrap(image.cgImage)
        let color = try XCTUnwrap(pixel(of: image, atPixelX: Int(Double(cg.width) * 0.5), y: Int(Double(cg.height) * 0.5)))
        XCTAssertGreaterThan(color.r, 200, "インクが一切なくても、印刷された(PDFの)背景内容だけで切り抜きが作られる必要があります。")
    }

    func testSnippetCombinesPrintedBackgroundAndInkTogether() throws {
        let page = pageWithSplitBackground()
        // A green stroke drawn across the crop, well away from its top/bottom
        // edges so both the stroke band and the untouched background survive
        // in the same crop.
        let drawing = InkDrawing(strokes: [horizontalStroke(y: 100, colorHex: "#00FF00")])
        let snippet = try XCTUnwrap(
            PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 0, y: 0, width: 100, height: 200), label: "test", drawing: drawing)
        )
        let image = try XCTUnwrap(snippet.image)
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width
        let onStroke = try XCTUnwrap(pixel(of: image, atPixelX: width / 2, y: Int(Double(cg.height) * 0.5)))
        let offStroke = try XCTUnwrap(pixel(of: image, atPixelX: width / 2, y: Int(Double(cg.height) * 0.1)))
        XCTAssertGreaterThan(onStroke.g, 150, "ペンで書いた部分は、緑色のインクが写る必要があります。")
        XCTAssertGreaterThan(offStroke.r, 150, "ペンが通っていない部分では、背景(印刷された内容)がそのまま透けて見える必要があります。")
    }

    // MARK: - defense in depth: a degenerate region never produces a corrupt image

    func testSnippetOfAZeroWidthRegionReturnsNilRatherThanACorruptImage() {
        let page = pageWithSplitBackground()
        let snippet = PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 50, y: 50, width: 0, height: 100), label: "test")
        XCTAssertNil(snippet, "幅がゼロの範囲からは、壊れた画像を作らずnilを返す必要があります。")
    }

    func testSnippetOfARegionEntirelyOutsideThePageReturnsNil() {
        let page = pageWithSplitBackground()
        let snippet = PageSnippetRenderer.snippet(of: page, rect: CGRect(x: 500, y: 500, width: 100, height: 100), label: "test")
        XCTAssertNil(snippet, "ページの外側だけの範囲からは、壊れた画像を作らずnilを返す必要があります。")
    }
}
