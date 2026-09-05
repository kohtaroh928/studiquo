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
}
