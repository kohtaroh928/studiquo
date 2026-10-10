import CoreGraphics
import PDFKit
import XCTest
@testable import studiquo

final class PDFImportServiceTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        workDir = nil
        super.tearDown()
    }

    private func makePDF(name: String, userPassword: String? = nil, pageCount: Int = 2) -> URL {
        let url = workDir.appendingPathComponent(name)
        var auxInfo: [String: Any] = [:]
        if let userPassword {
            auxInfo[kCGPDFContextUserPassword as String] = userPassword
            auxInfo[kCGPDFContextOwnerPassword as String] = "owner-pw"
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            XCTFail("Failed to create PDF context for \(name)")
            return url
        }
        for _ in 0..<pageCount {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(mediaBox)
            context.endPage()
        }
        context.closePDF()
        return url
    }

    func testExtractPages_returnsAllPagesForUnprotectedPDF() {
        let url = makePDF(name: "plain.pdf", pageCount: 3)
        let pages = PDFImportService.extractPages(from: url)
        XCTAssertEqual(pages.count, 3)
    }

    /// Regression test for the bug found in review: `extractPages` used to
    /// call `document.unlock(withPassword:)` only when `document.isLocked`
    /// was true, but `isLocked` is documented (in PDFPasswordService) as
    /// unreliable for some encrypted files — leaving them still encrypted
    /// and rendering blank pages even with the correct password supplied.
    /// The fix calls unlock unconditionally whenever a password is given.
    func testExtractPages_unlocksProtectedPDFWithCorrectPassword() {
        let url = makePDF(name: "locked.pdf", userPassword: "correct-pw", pageCount: 2)
        let pages = PDFImportService.extractPages(from: url, password: "correct-pw")
        XCTAssertEqual(pages.count, 2, "a correctly-unlocked document must still render every page")
        for page in pages {
            XCTAssertFalse(page.imageData.isEmpty)
        }
    }

    func testExtractPages_returnsEmptyForMissingFile() {
        let missing = workDir.appendingPathComponent("does-not-exist.pdf")
        let pages = PDFImportService.extractPages(from: missing)
        XCTAssertTrue(pages.isEmpty)
    }

    // MARK: Image size and format

    private enum PageLook { case flatText, smoothGradient }

    /// A one-page PDF with the given size and look: a page of plain text (what a
    /// lecture handout is) or a smooth multi-colour gradient (what a photo or
    /// shaded slide background compresses like).
    private func makeStyledPDF(name: String, width: CGFloat, height: CGFloat, look: PageLook) -> URL {
        let url = workDir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF context for \(name)")
            return url
        }
        context.beginPage(mediaBox: &mediaBox)
        switch look {
        case .flatText:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            UIGraphicsPushContext(context)
            let text = String(repeating: "Lecture notes: the quick brown fox jumps over the lazy dog. ", count: 40)
            (text as NSString).draw(in: mediaBox.insetBy(dx: 36, dy: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
            UIGraphicsPopContext()
        case .smoothGradient:
            let colors = [
                CGColor(red: 0.05, green: 0.2, blue: 0.6, alpha: 1),
                CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1),
                CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1),
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: width / 2, y: height / 2), startRadius: 0,
                                       endCenter: CGPoint(x: width / 2, y: height / 2), endRadius: min(width, height) / 2, options: [])
        }
        context.endPage()
        context.closePDF()
        return url
    }

    private func pixelSize(of data: Data) -> CGSize {
        // `UIImage(data:)` reports scale 1, so `size` is the pixel size.
        UIImage(data: data)?.size ?? .zero
    }

    private func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
    private func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

    /// The bug: the renderer's own screen-scale multiplied the requested scale,
    /// so a 2× import produced 4× the pixels on an iPad (2448×3168 for a
    /// US-letter page) and filled iCloud and the device with oversized images.
    func testExtractPages_rendersAtTwoPixelsPerPointNotFour() throws {
        let url = makeStyledPDF(name: "letter.pdf", width: 612, height: 792, look: .flatText)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        XCTAssertEqual(pixelSize(of: page.imageData), CGSize(width: 1224, height: 1584))
        XCTAssertEqual(page.width, 612)
        XCTAssertEqual(page.height, 792, "page size in points is what the editor lays the page out with")
    }

    func testExtractPages_keepsPlainTextPagesAsCrispPNG() throws {
        let url = makeStyledPDF(name: "text.pdf", width: 612, height: 792, look: .flatText)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        XCTAssertTrue(isPNG(page.imageData), "text edges must not be smudged by JPEG")
    }

    func testExtractPages_usesJPEGForPhotoLikePages() throws {
        let url = makeStyledPDF(name: "gradient.pdf", width: 960, height: 540, look: .smoothGradient)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        XCTAssertTrue(isJPEG(page.imageData))
        XCTAssertEqual(pixelSize(of: page.imageData), CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(UIImage(data: page.imageData), "stored background must decode like any other")
    }

    func testExtractPages_photoLikePageIsFarSmallerThanItsPNG() throws {
        let url = makeStyledPDF(name: "gradient.pdf", width: 960, height: 540, look: .smoothGradient)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        let png = try XCTUnwrap(UIImage(data: page.imageData)?.pngData())
        XCTAssertLessThan(Double(page.imageData.count), Double(png.count) * 0.25)
    }

    func testExtractPages_capsTheLongestSideOfAHugePage() throws {
        let url = makeStyledPDF(name: "poster.pdf", width: 5000, height: 3000, look: .flatText)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        let size = pixelSize(of: page.imageData)
        XCTAssertLessThanOrEqual(max(size.width, size.height), PDFImportService.maxPixelEdge)
        XCTAssertEqual(page.width, 5000, "the page's size in points is unchanged by the pixel cap")
    }

    func testEffectiveScale() {
        XCTAssertEqual(PDFImportService.effectiveScale(for: CGSize(width: 612, height: 792), requested: 2), 2)
        XCTAssertEqual(PDFImportService.effectiveScale(for: CGSize(width: 4096, height: 100), requested: 2), 1, accuracy: 0.0001)
    }

    // MARK: Rotated pages

    /// A portrait page (200×400) whose upper half is red and lower half blue,
    /// saved with the given `/Rotate`. Slides exported from PowerPoint or a
    /// scanner often look like this: a portrait MediaBox plus `/Rotate 90`.
    private func makeRotatedPDF(name: String, rotation: Int) throws -> URL {
        let source = workDir.appendingPathComponent("unrotated-\(name)")
        var box = CGRect(x: 0, y: 0, width: 200, height: 400)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPage(mediaBox: &box)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 200, width: 200, height: 200))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.endPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: source))
        try XCTUnwrap(document.page(at: 0)).rotation = rotation
        let url = workDir.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    /// The colour of the pixel at `(x, y)` (top-left origin) as 0-255 RGB.
    private func rgb(of data: Data, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func isReddish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g < 60 && c.b < 60 }
    private func isBluish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 200 && c.r < 60 && c.g < 60 }

    /// The bug: a landscape slide stored as a portrait page with `/Rotate 90`
    /// was drawn into a bitmap sized from the unrotated box, so only part of it
    /// showed and the rest of the canvas stayed white.
    func testExtractPages_rotated90UsesTheRotatedSizeAndShowsTheWholePage() throws {
        let url = try makeRotatedPDF(name: "rotate90.pdf", rotation: 90)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url, scale: 1).first)
        XCTAssertEqual(page.width, 400)
        XCTAssertEqual(page.height, 200, "the page is stored at the size it is displayed")
        XCTAssertEqual(pixelSize(of: page.imageData), CGSize(width: 400, height: 200))
        // Rotating clockwise turns the red top to the right and the blue bottom
        // to the left, and nothing is left white.
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 5, y: 5)))
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 195, y: 195)))
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 205, y: 5)))
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 395, y: 195)))
    }

    func testExtractPages_rotated270UsesTheRotatedSizeAndShowsTheWholePage() throws {
        let url = try makeRotatedPDF(name: "rotate270.pdf", rotation: 270)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url, scale: 1).first)
        XCTAssertEqual(page.width, 400)
        XCTAssertEqual(page.height, 200)
        XCTAssertEqual(pixelSize(of: page.imageData), CGSize(width: 400, height: 200))
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 5, y: 5)))
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 195, y: 195)))
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 205, y: 5)))
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 395, y: 195)))
    }

    func testExtractPages_rotated180KeepsTheSizeAndTurnsThePageUpsideDown() throws {
        let url = try makeRotatedPDF(name: "rotate180.pdf", rotation: 180)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url, scale: 1).first)
        XCTAssertEqual(page.width, 200)
        XCTAssertEqual(page.height, 400)
        XCTAssertEqual(pixelSize(of: page.imageData), CGSize(width: 200, height: 400))
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 100, y: 10)))
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 100, y: 390)))
    }

    func testExtractPages_unrotatedPageIsUnchanged() throws {
        let url = try makeRotatedPDF(name: "rotate0.pdf", rotation: 0)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url, scale: 1).first)
        XCTAssertEqual(page.width, 200)
        XCTAssertEqual(page.height, 400)
        XCTAssertTrue(isReddish(try rgb(of: page.imageData, x: 100, y: 10)))
        XCTAssertTrue(isBluish(try rgb(of: page.imageData, x: 100, y: 390)))
    }

    /// The shape of the real handout that broke: A4 portrait boxes with
    /// `/Rotate 90` on every page, drawn as landscape slides. Each page has a
    /// green bar along its displayed right edge and a black bar along the top,
    /// the two regions the bug cut off.
    func testExtractPages_everyPageOfAnA4RotatedHandoutKeepsItsEdges() throws {
        let source = workDir.appendingPathComponent("a4-source.pdf")
        var box = CGRect(x: 0, y: 0, width: 595.22, height: 842)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPage(mediaBox: &box)
            // Unrotated page space: displayed right edge = top (y near 842),
            // displayed top edge = left (x near 0), for a clockwise /Rotate 90.
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 812, width: 595.22, height: 30))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 842))
            context.endPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source))
        for index in 0..<document.pageCount { document.page(at: index)?.rotation = 90 }
        let url = workDir.appendingPathComponent("a4-rotated.pdf")
        XCTAssertTrue(document.write(to: url))

        let pages = PDFImportService.extractPages(from: url, scale: 1)
        XCTAssertEqual(pages.count, 3)
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.width, 842, accuracy: 0.01, "page \(index)")
            XCTAssertEqual(page.height, 595.22, accuracy: 0.01, "page \(index)")
            let size = pixelSize(of: page.imageData)
            XCTAssertEqual(size.width, 842, accuracy: 1, "page \(index)")
            XCTAssertEqual(size.height, 595, accuracy: 1, "page \(index)")
            let rightEdge = try rgb(of: page.imageData, x: Int(size.width) - 10, y: Int(size.height) / 2)
            XCTAssertTrue(rightEdge.g > 200 && rightEdge.r < 60 && rightEdge.b < 60, "right edge lost on page \(index)")
            let topEdge = try rgb(of: page.imageData, x: Int(size.width) / 2, y: 10)
            XCTAssertTrue(topEdge.r < 60 && topEdge.g < 60 && topEdge.b < 60, "top edge lost on page \(index)")
        }
    }

    func testDisplaySize_swapsWidthAndHeightForQuarterTurns() throws {
        for (rotation, swapped) in [(0, false), (90, true), (180, false), (270, true)] {
            let url = try makeRotatedPDF(name: "size\(rotation).pdf", rotation: rotation)
            let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
            XCTAssertEqual(
                PDFImportService.displaySize(of: page),
                swapped ? CGSize(width: 400, height: 200) : CGSize(width: 200, height: 400),
                "rotation \(rotation)"
            )
        }
    }

    // MARK: Background rendering

    /// Collects progress reports from the rendering thread.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(done: Int, total: Int)] = []
        func record(_ done: Int, _ total: Int) { lock.lock(); entries.append((done, total)); lock.unlock() }
        var all: [(done: Int, total: Int)] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    private func makeLongPDF(name: String, pages: Int) -> URL {
        let url = workDir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF context for \(name)")
            return url
        }
        for index in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            UIGraphicsPushContext(context)
            let text = String(repeating: "Page \(index + 1): the quick brown fox jumps over the lazy dog. ", count: 40)
            (text as NSString).draw(in: mediaBox.insetBy(dx: 36, dy: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
            UIGraphicsPopContext()
            context.endPage()
        }
        context.closePDF()
        return url
    }

    func testExtractPagesAsync_returnsTheSamePagesAsTheSyncVersion() async throws {
        let url = makeLongPDF(name: "same.pdf", pages: 5)
        let sync = PDFImportService.extractPages(from: url)
        let async = await PDFImportService.extractPagesAsync(from: url)
        XCTAssertEqual(async.count, sync.count)
        XCTAssertEqual(async.map(\.text), sync.map(\.text))
        XCTAssertEqual(async.map(\.imageData.count), sync.map(\.imageData.count))
    }

    func testExtractPagesAsync_reportsEveryPageInOrder() async throws {
        let url = makeLongPDF(name: "progress.pdf", pages: 6)
        let log = ProgressLog()
        _ = await PDFImportService.extractPagesAsync(from: url) { done, total in log.record(done, total) }
        XCTAssertEqual(log.all.map(\.done), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(log.all.allSatisfy { $0.total == 6 })
    }

    /// The reported problem: importing several long PDFs froze the screen for
    /// seconds because every page was rendered on the main thread, so taps,
    /// scrolling and the progress bar all stalled. While the async version
    /// renders, the main thread must keep getting turns.
    @MainActor
    func testExtractPagesAsync_keepsTheMainThreadResponsive() async throws {
        let url = makeLongPDF(name: "long.pdf", pages: 150)

        // Baseline: how long the same work blocks the thread when run directly.
        let baselineStart = Date()
        _ = PDFImportService.extractPages(from: url)
        let blockedFor = Date().timeIntervalSince(baselineStart)
        try XCTSkipIf(blockedFor < 0.6, "machine too fast for the comparison to mean anything (\(blockedFor)s)")

        var finished = false
        let work = Task { @MainActor in
            _ = await PDFImportService.extractPagesAsync(from: url)
            finished = true
        }
        var longestGap: TimeInterval = 0
        var last = Date()
        while !finished {
            try await Task.sleep(for: .milliseconds(10))
            let now = Date()
            longestGap = max(longestGap, now.timeIntervalSince(last))
            last = now
        }
        await work.value
        XCTAssertLessThan(longestGap, blockedFor / 3,
                          "main thread was stalled for \(longestGap)s while the same work blocks it for \(blockedFor)s when run directly")
        XCTAssertLessThan(longestGap, 0.4)
    }

    func testExtractPagesAsync_cancelledWorkReturnsNothingRatherThanAHalfRenderedPDF() async throws {
        let url = makeLongPDF(name: "cancel.pdf", pages: 40)
        let work = Task { await PDFImportService.extractPagesAsync(from: url) }
        work.cancel()
        let pages = await work.value
        XCTAssertTrue(pages.isEmpty)
    }

    // MARK: Size budget (problem 2: PDFs used up the sync/storage allowance)

    func testTheDefaultScaleIsTwoPixelsPerPoint() {
        XCTAssertEqual(PDFImportService.defaultScale, 2)
    }

    /// Before the fix a 10-slide deck of shaded slides came to hundreds of MB.
    func testAMultiPageDeckOfShadedSlidesStaysSmall() throws {
        let url = workDir.appendingPathComponent("deck.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 960, height: 540)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1), CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        for _ in 0..<10 {
            context.beginPage(mediaBox: &mediaBox)
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 960, y: 540), options: [])
            context.endPage()
        }
        context.closePDF()

        let pages = PDFImportService.extractPages(from: url)
        let total = pages.reduce(0) { $0 + $1.imageData.count }
        XCTAssertEqual(pages.count, 10)
        XCTAssertLessThan(total, 3_000_000, "10 shaded slides should be a few MB at most, not hundreds")
    }

    func testNoPageIsEverMoreThanFourMillionPixelsWide() throws {
        // The cap that stops a poster-sized PDF becoming a bitmap of tens of megapixels.
        let url = makeStyledPDF(name: "banner.pdf", width: 20000, height: 400, look: .flatText)
        let page = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        let size = pixelSize(of: page.imageData)
        XCTAssertLessThanOrEqual(size.width * size.height, 4096 * 4096)
    }
}
