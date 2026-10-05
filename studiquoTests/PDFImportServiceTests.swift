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
}
