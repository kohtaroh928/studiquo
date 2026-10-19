import CoreGraphics
import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class PDFImportLifecycleTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var workDir: URL!

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("PDFImportLifecycle-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        workDir = nil
        super.tearDown()
    }

    private func makeEncryptedTextPDF(text: String, userPassword: String) -> URL {
        let url = workDir.appendingPathComponent("encrypted-text.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let auxInfo: [String: Any] = [
            kCGPDFContextUserPassword as String: userPassword,
            kCGPDFContextOwnerPassword as String: "owner-\(userPassword)",
        ]
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary)!
        context.beginPage(mediaBox: &mediaBox)
        UIGraphicsPushContext(context)
        (text as NSString).draw(
            at: CGPoint(x: 36, y: 60),
            withAttributes: [.font: UIFont.systemFont(ofSize: 22)]
        )
        UIGraphicsPopContext()
        context.endPage()
        context.closePDF()
        return url
    }

    func testEncryptedPDFWithCorrectPasswordExtractsBothBitmapAndPagePDF() throws {
        let url = makeEncryptedTextPDF(text: "quantum entanglement", userPassword: "open-sesame")

        // Without the password, the locked PDF must not leak its text.
        let lockedPages = PDFImportService.extractPages(from: url, password: nil)
        XCTAssertNil(lockedPages.first?.pagePDF, "Locked PDF without password must not expose a page PDF")

        // With the correct password, both image data and the one-page PDF are extracted.
        var progressUpdates: [(Int, Int)] = []
        let unlockedPages = PDFImportService.extractPages(from: url, password: "open-sesame") { done, total in
            progressUpdates.append((done, total))
        }
        XCTAssertEqual(unlockedPages.count, 1)
        XCTAssertEqual(progressUpdates.count, 1)
        XCTAssertEqual(progressUpdates.first?.0, 1)
        XCTAssertEqual(progressUpdates.first?.1, 1)

        let page = try XCTUnwrap(unlockedPages.first)
        XCTAssertFalse(page.imageData.isEmpty)
        let single = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(page.pagePDF)))
        XCTAssertEqual(single.pageCount, 1)
        XCTAssertFalse(single.isLocked, "the stored page must open without the file's password")
        XCTAssertTrue(single.page(at: 0)?.string?.contains("quantum entanglement") == true)
    }

    func testEffectiveScaleClampsPosterSizedPagesToMaxPixelEdge() {
        // Normal A4 page (595x842) keeps the requested 2.0 scale.
        let normalScale = PDFImportService.effectiveScale(
            for: CGSize(width: 595, height: 842),
            requested: PDFImportService.defaultScale
        )
        XCTAssertEqual(normalScale, 2.0, accuracy: 0.0001)

        // Poster-sized page (4096x8192 pt) must clamp scale to 4096 / 8192 = 0.5 so longest edge <= 4096px.
        let posterScale = PDFImportService.effectiveScale(
            for: CGSize(width: 4096, height: 8192),
            requested: PDFImportService.defaultScale
        )
        XCTAssertEqual(posterScale, 0.5, accuracy: 0.0001)
    }

    func testExtractPagesReturnsEmptyArrayWhenTaskIsAlreadyCancelled() async {
        let url = makeEncryptedTextPDF(text: "cancelled import", userPassword: "pw")
        let task = Task<[PDFImportService.RenderedPage], Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return PDFImportService.extractPages(from: url, password: "pw")
        }
        let result = await task.value
        XCTAssertTrue(result.isEmpty, "A cancelled PDF import must return [] rather than a half-rendered document")
    }

    func testRemovingOrReplacingPageBackgroundClearsTheStalePagePDFWhileSnapshotsPreserveIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "PDFページ")
        let page = NotePage(order: 0, backgroundImageData: Data([0x89, 0x50]), pageWidth: 612, pageHeight: 792)
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        context.insert(page)

        let pdfData = Data("%PDF-1.4 derivative".utf8)
        page.backgroundPDFData = pdfData

        // A snapshot taken before the background changes keeps both the image and its PDF.
        let beforeSnapshot = NotePageSnapshot(page)
        XCTAssertEqual(beforeSnapshot.backgroundPDFData, pdfData)

        // Removing the background clears the PDF that described it (the real code path).
        page.removeBackground()
        XCTAssertNil(page.backgroundImageData)
        XCTAssertNil(page.backgroundPDFData)

        // Restoring from the snapshot brings back both the bitmap and the PDF.
        let restoredPage = beforeSnapshot.makePage(in: context, notebook: notebook)
        XCTAssertEqual(restoredPage.backgroundImageData, Data([0x89, 0x50]))
        XCTAssertEqual(restoredPage.backgroundPDFData, pdfData)
    }
}
