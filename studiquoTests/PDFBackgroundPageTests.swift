import CryptoKit
import PDFKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import studiquo

/// A PDF page is shown in a `PDFView` (so its words can be selected), beside
/// the bitmap kept for thumbnails and export. These pin the places where the
/// two must stay in step: protection, backup, undo, replacing the background,
/// turning the page — and the pinned scale that lets the editor's pinch zoom
/// the whole page instead of the text alone.
@MainActor
final class PDFBackgroundPageTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var keyServices: [String] = []
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for service in keyServices { NotebookEncryptionKeyStore.deleteKey(service: service) }
        keyServices = []
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    private func uniqueKeyService() -> String {
        let service = "PDFBackgroundPageTests-\(UUID().uuidString)"
        keyServices.append(service)
        return service
    }

    private func makeTextPDF(_ text: String = "photosynthesis converts light", size: CGSize = CGSize(width: 300, height: 400)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            (text as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
    }

    private func makeBlankPDF(size: CGSize = CGSize(width: 300, height: 400)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A page that carries both descriptions of one PDF page: the bitmap and the one-page PDF.
    private func makePDFPage(in notebook: Notebook, pdf: Data? = nil) -> NotePage {
        let page = NotePage(order: notebook.sortedPages.count, backgroundImageData: Data([1, 2, 3]), pageWidth: 600, pageHeight: 800)
        page.backgroundPDFData = pdf ?? makeTextPDF()
        page.notebook = notebook
        notebook.addPage(page)
        return page
    }

    // MARK: A. Protected notebooks

    func testLockingRemovesThePagePDFAndUnlockingRestoresItExactly() {
        let service = uniqueKeyService()
        let notebook = Notebook(title: "保護PDF")
        let pdf = makeTextPDF("secret formula")
        let page = makePDFPage(in: notebook, pdf: pdf)

        NotebookEncryptionService.lock(notebook, keyService: service)

        XCTAssertNil(page.backgroundPDFData, "the page PDF carries the page's text and must not stay readable")
        let sealed = notebook.encryptedContent ?? Data()
        XCTAssertNil(sealed.range(of: Data("%PDF".utf8)), "the sealed content must not hold the PDF in the clear")

        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(page.backgroundPDFData, pdf)
    }

    func testUnlockAcceptsASealedPayloadFromBeforePagePDFsExisted() throws {
        let service = uniqueKeyService()
        let notebook = Notebook(title: "旧形式")
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.addPage(page)
        let legacyJSON = """
        {"pages":[{"drawingData":null,"backgroundImageData":"\(Data("bg".utf8).base64EncodedString())",
        "title":"旧","recognizedText":"本文","flashcardQuestion":"","flashcardAnswer":"","elements":[]}]}
        """
        let key = NotebookEncryptionKeyStore.loadOrCreateKey(service: service)
        notebook.encryptedContent = try XCTUnwrap(AES.GCM.seal(Data(legacyJSON.utf8), using: key).combined)

        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.backgroundImageData, Data("bg".utf8))
    }

    // MARK: A. Backup

    func testBackupRoundTripKeepsThePagePDF() throws {
        let notebook = Notebook(title: "往復-\(UUID().uuidString)")
        let pdf = makeTextPDF()
        _ = makePDFPage(in: notebook, pdf: pdf)

        let url = try XCTUnwrap(NotebookBackupService.export(notebook))
        temporaryFiles.append(url)
        let restored = try XCTUnwrap(NotebookBackupService.restore(from: url))

        XCTAssertEqual(restored.sortedPages.first?.backgroundPDFData, pdf)
    }

    func testRestoringAnArchiveFromBeforePagePDFsLeavesItNil() throws {
        let json = """
        {"title":"旧","folderName":"","tagsText":"","pages":[{"width":595,"height":842,"template":"blank",
        "bookmark":false,"title":"","recognizedText":"","elements":[]}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        temporaryFiles.append(url)
        try Data(json.utf8).write(to: url)

        let restored = try XCTUnwrap(NotebookBackupService.restore(from: url))
        XCTAssertNil(restored.sortedPages.first?.backgroundPDFData)
    }

    // MARK: A. Undo of a page deletion

    func testRestoringADeletedPageBringsBackItsPDF() throws {
        let container = try makeContainer()
        let notebook = Notebook(title: "削除の取り消し")
        let pdf = makeTextPDF()
        let page = makePDFPage(in: notebook, pdf: pdf)
        container.mainContext.insert(notebook)

        let snapshot = NotePageSnapshot(page)
        XCTAssertEqual(snapshot.backgroundPDFData, pdf)

        let restored = snapshot.makePage(in: container.mainContext, notebook: notebook)
        XCTAssertEqual(restored.backgroundPDFData, pdf)
    }

    // MARK: A. Replacing or removing the background

    func testRemovingTheBackgroundClearsTheBitmapAndThePDFTogether() {
        let page = makePDFPage(in: Notebook(title: "n"))

        page.removeBackground()

        XCTAssertNil(page.backgroundImageData)
        XCTAssertNil(page.backgroundPDFData, "a stale PDF would keep showing text that the page no longer has")
    }

    func testReplacingTheBackgroundWithAPhotoClearsThePDFDataAndResizesThePage() {
        let page = makePDFPage(in: Notebook(title: "n"))
        let photo = Data([9, 9, 9])

        page.replaceBackground(imageData: photo, width: 1000, height: 500)

        XCTAssertEqual(page.backgroundImageData, photo)
        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.pageWidth, 1000)
        XCTAssertEqual(page.pageHeight, 500)
    }

    // MARK: B. Import

    func testImportKeepsAOnePagePDFOnlyForPagesThatHaveText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-\(UUID().uuidString).pdf")
        temporaryFiles.append(url)
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFDocument(data: makeTextPDF("mitochondria"))?.page(at: 0)), at: 0)
        document.insert(try XCTUnwrap(PDFDocument(data: makeBlankPDF())?.page(at: 0)), at: 1)
        XCTAssertTrue(document.write(to: url))

        let pages = PDFImportService.extractPages(from: url)

        XCTAssertEqual(pages.count, 2)
        let first = try XCTUnwrap(pages[0].pagePDF)
        XCTAssertEqual(PDFDocument(data: first)?.pageCount, 1, "each page is kept on its own")
        XCTAssertTrue(PDFDocument(data: first)?.page(at: 0)?.string?.contains("mitochondria") == true)
        XCTAssertNil(pages[1].pagePDF, "a page with no text gains nothing from a PDF wrapper")
    }

    func testThePagePDFOfAPasswordProtectedFileIsReadableWithoutThePassword() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString).pdf")
        temporaryFiles.append(url)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let aux: [String: Any] = [kCGPDFContextUserPassword as String: "pw", kCGPDFContextOwnerPassword as String: "owner"]
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary))
        context.beginPage(mediaBox: &box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "chlorophyll", attributes: [.font: UIFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(line, context)
        context.endPage()
        context.closePDF()

        let pages = PDFImportService.extractPages(from: url, password: "pw")

        let data = try XCTUnwrap(pages.first?.pagePDF)
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse(reopened.isLocked, "the stored page must open without the file's password")
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("chlorophyll") == true)
    }

    func testThePagePDFOfARotatedPageHasTheSameShapeAsItsBitmap() throws {
        let source = try XCTUnwrap(PDFDocument(data: makeTextPDF("rotated words", size: CGSize(width: 300, height: 400))))
        source.page(at: 0)?.rotation = 90
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID().uuidString).pdf")
        temporaryFiles.append(url)
        XCTAssertTrue(source.write(to: url))

        let rendered = try XCTUnwrap(PDFImportService.extractPages(from: url).first)
        let page = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(rendered.pagePDF))?.page(at: 0))

        let size = PDFImportService.displaySize(of: page)
        XCTAssertEqual(size.width, rendered.width, accuracy: 0.5)
        XCTAssertEqual(size.height, rendered.height, accuracy: 0.5)
    }

    // MARK: E. Turning the page

    func testRotatingAPageTurnsItsPagePDFSoItStillMatchesTheBitmap() throws {
        let container = try makeContainer()
        let notebook = Notebook(title: "回転PDF")
        let page = makePDFPage(in: notebook)
        container.mainContext.insert(notebook)

        PageRotationService.rotateClockwise(page)
        defer { NoteActionHistory.shared.undo(requestID: UUID()) }

        let turned = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(page.backgroundPDFData))?.page(at: 0))
        XCTAssertEqual(turned.rotation, 90)
        XCTAssertTrue(turned.string?.contains("photosynthesis") == true, "turning must not lose the text")
        let size = PDFImportService.displaySize(of: turned)
        XCTAssertEqual(size.width / size.height, page.pageWidth / page.pageHeight, accuracy: 0.01)
    }

    func testUndoingARotationRestoresThePagePDF() throws {
        let container = try makeContainer()
        let notebook = Notebook(title: "回転の取り消し")
        let pdf = makeTextPDF()
        let page = makePDFPage(in: notebook, pdf: pdf)
        container.mainContext.insert(notebook)

        PageRotationService.rotateClockwise(page)
        NoteActionHistory.shared.undo(requestID: UUID())

        XCTAssertEqual(page.backgroundPDFData, pdf)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: try XCTUnwrap(page.backgroundPDFData))?.page(at: 0)).rotation, 90)

        NoteActionHistory.shared.undo(requestID: UUID())
    }

    func testRotatingAPageWithoutPDFDataStillWorks() throws {
        let container = try makeContainer()
        let notebook = Notebook(title: "画像だけ")
        let page = NotePage(order: 0, backgroundImageData: nil, pageWidth: 600, pageHeight: 800)
        page.notebook = notebook
        notebook.addPage(page)
        container.mainContext.insert(notebook)

        PageRotationService.rotateClockwise(page)
        defer { NoteActionHistory.shared.undo(requestID: UUID()) }

        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.pageWidth, 800)
    }

    // MARK: C. Zoom stays with the editor

    private func host<V: View>(_ view: V, size: CGSize, body: (UIWindow, UIView) throws -> Void) throws {
        // Pinned to the window's size and clear of the safe area, so the view under
        // test has exactly the frame the test names.
        let controller = UIHostingController(rootView: view.frame(width: size.width, height: size.height).ignoresSafeArea())
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.layoutIfNeeded()
        try body(window, controller.view)
    }

    private func findPDFView(in root: UIView) -> PDFView? {
        if let found = root as? PDFView { return found }
        for subview in root.subviews { if let found = findPDFView(in: subview) { return found } }
        return nil
    }

    private func enabledPinchRecognizers(in view: UIView) -> Int {
        let own = (view.gestureRecognizers ?? []).filter { $0 is UIPinchGestureRecognizer && $0.isEnabled }.count
        return own + view.subviews.reduce(0) { $0 + enabledPinchRecognizers(in: $1) }
    }

    func testThePDFViewIsPinnedToTheFitScaleSoOnlyTheEditorZooms() throws {
        try host(PageNativePDFView(pdfData: makeTextPDF()), size: CGSize(width: 300, height: 400)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            XCTAssertFalse(pdfView.autoScales)
            XCTAssertEqual(pdfView.scaleFactor, 1.0, accuracy: 0.001, "a 300×400 page in a 300×400 frame shows at 1×")
            XCTAssertEqual(pdfView.minScaleFactor, pdfView.scaleFactor, accuracy: 0.001)
            XCTAssertEqual(pdfView.maxScaleFactor, pdfView.scaleFactor, accuracy: 0.001,
                           "a PDFView that can zoom on its own scales the text inside the page while the ink stays put")
        }
    }

    /// The bitmap is drawn from the media box; a PDF whose crop box is smaller
    /// would otherwise show a different part of the page than the image and the
    /// ink laid over it.
    func testThePDFViewShowsTheMediaBoxEvenWhenTheCropBoxIsSmaller() throws {
        let document = try XCTUnwrap(PDFDocument(data: makeTextPDF(size: CGSize(width: 300, height: 400))))
        document.page(at: 0)?.setBounds(CGRect(x: 50, y: 50, width: 100, height: 100), for: .cropBox)
        let data = try XCTUnwrap(document.dataRepresentation())

        try host(PageNativePDFView(pdfData: data), size: CGSize(width: 300, height: 400)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            XCTAssertEqual(pdfView.displayBox, .mediaBox)
            XCTAssertEqual(pdfView.scaleFactor, 1.0, accuracy: 0.001)
        }
    }

    func testThePDFViewShowsOnePageAndLeavesScrollingToTheEditor() throws {
        try host(PageNativePDFView(pdfData: makeTextPDF("Native PDF Layer", size: CGSize(width: 200, height: 260))), size: CGSize(width: 200, height: 260)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            XCTAssertEqual(pdfView.displayMode, .singlePage)
            XCTAssertFalse(pdfView.displaysPageBreaks)
            XCTAssertEqual(pdfView.document?.pageCount, 1)
            let innerScrollViews = pdfView.subviews.compactMap { $0 as? UIScrollView }
            XCTAssertFalse(innerScrollViews.isEmpty)
            for scroll in innerScrollViews {
                XCTAssertFalse(scroll.isScrollEnabled, "Inner PDFView scroll view must be disabled so editor scrolling works")
            }
        }
    }

    func testThePDFViewSwitchesOffEveryPinchRecognizerInsideIt() throws {
        try host(PageNativePDFView(pdfData: makeTextPDF()), size: CGSize(width: 300, height: 400)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            XCTAssertEqual(enabledPinchRecognizers(in: pdfView), 0)
        }
    }

    func testThePDFViewRefitsWhenItsSizeChanges() throws {
        try host(PageNativePDFView(pdfData: makeTextPDF()), size: CGSize(width: 300, height: 400)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            let before = pdfView.scaleFactor

            pdfView.superview?.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
            pdfView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
            pdfView.layoutIfNeeded()

            XCTAssertEqual(pdfView.scaleFactor, 2.0, accuracy: 0.001, "the page must fill the 600-wide frame exactly")
            XCTAssertGreaterThan(pdfView.scaleFactor, before, "a larger view (split-screen off, rotation) must show the page larger")
            XCTAssertEqual(pdfView.minScaleFactor, pdfView.maxScaleFactor, accuracy: 0.001)
        }
    }

    func testThePDFViewShowsTheNewPageWhenItsDataChanges() throws {
        final class Box: ObservableObject { @Published var data: Data; init(_ data: Data) { self.data = data } }
        struct Wrapper: View {
            @ObservedObject var box: Box
            var body: some View { PageNativePDFView(pdfData: box.data) }
        }
        let first = makeTextPDF("alpha")
        let second = makeTextPDF("omega")
        let box = Box(first)
        try host(Wrapper(box: box), size: CGSize(width: 300, height: 400)) { _, root in
            let pdfView = try XCTUnwrap(findPDFView(in: root))
            XCTAssertTrue(pdfView.document?.page(at: 0)?.string?.contains("alpha") == true)

            box.data = second
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            XCTAssertTrue(pdfView.document?.page(at: 0)?.string?.contains("omega") == true)
        }
    }
}
