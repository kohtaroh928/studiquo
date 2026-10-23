import Foundation
import PDFKit
import UIKit

enum PDFImportService {
    typealias RenderedPage = (imageData: Data, width: Double, height: Double, text: String, pagePDF: Data?)

    /// Pixels per PDF point. 2 is sharp on an iPad at normal zoom and leaves
    /// room to zoom in without the page going soft.
    static let defaultScale: CGFloat = 2.0

    /// Longest side a rendered page may have, in pixels. A poster-sized PDF
    /// would otherwise become a bitmap of tens of megapixels.
    static let maxPixelEdge: CGFloat = 4096

    /// JPEG is used for a page only when it is at most this fraction of the PNG.
    /// Photos and gradients shrink to a few percent; text and flat slides come
    /// out about the same size or larger, and JPEG would only smudge their edges.
    static let jpegWorthItRatio = 0.5
    static let jpegQuality: CGFloat = 0.85

    /// Renders each page of a PDF at the given URL into a NotePage-compatible
    /// (imageData, width, height) tuple so it can be used as page background.
    ///
    /// A `password` unlocks a protected file first. A locked document that is
    /// never unlocked renders nothing — `PDFPage.draw` produces blank pages —
    /// so the caller must supply the password for a protected PDF.
    ///
    /// `scale` is pixels per point of the PDF page.
    ///
    /// `onPage` is told how many pages are done out of the total after each one,
    /// from whichever thread is rendering. Returning `[]` for a cancelled task
    /// is deliberate: a half-rendered PDF must never be imported as if complete.
    static func extractPages(
        from url: URL,
        password: String? = nil,
        scale: CGFloat = defaultScale,
        onPage: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) -> [RenderedPage] {
        extractPagesChecked(from: url, password: password, scale: scale, onPage: onPage).pages
    }

    /// What `extractPagesChecked` produced: the pages, or, when the file is past
    /// `ImportLimits`, no pages and the reason. Both empty means the file could
    /// not be read (or the task was cancelled).
    struct Extraction {
        var pages: [RenderedPage] = []
        var rejection: ImportLimits.Rejection?
    }

    /// `extractPages`, but refusing a PDF with too many pages up front and
    /// stopping when the rendered pages together outgrow `maxRenderedBytes`
    /// (every page is held in memory until the notebook is built). A refused
    /// import returns no pages at all: half a PDF must never look complete.
    static func extractPagesChecked(
        from url: URL,
        password: String? = nil,
        scale: CGFloat = defaultScale,
        maxPages: Int = ImportLimits.maxPDFPages,
        maxRenderedBytes: Int = ImportLimits.maxRenderedPDFBytes,
        onPage: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) -> Extraction {
        guard let document = PDFDocument(url: url) else { return Extraction() }
        // Unlock whenever a password is supplied, not only when PDFKit calls
        // the document locked — its `isLocked` is unreliable and leaving a
        // still-encrypted document renders every page blank.
        if let password {
            _ = document.unlock(withPassword: password)
        }
        var results: [RenderedPage] = []
        var renderedBytes = 0
        let total = document.pageCount
        if total > maxPages { return Extraction(rejection: .tooManyPages(limit: maxPages)) }

        for index in 0..<total {
            if Task.isCancelled { return Extraction() }
            if renderedBytes > maxRenderedBytes { return Extraction(rejection: .renderedPagesTooLarge) }
            // Each page is a large bitmap; drain the temporaries per page so a
            // long PDF does not pile them all up before the loop ends.
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let pageSize = displaySize(of: page)
                guard pageSize.width > 0, pageSize.height > 0 else { return }
                let pageScale = effectiveScale(for: pageSize, requested: scale)
                let pixelSize = CGSize(width: pageSize.width * pageScale, height: pageSize.height * pageScale)

                // The default format multiplies the size by the screen scale
                // (2 on iPad), which silently made every page 4× the intended
                // pixel count. `scale = 1` makes `pixelSize` the real size.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
                let image = renderer.image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: pixelSize))
                    ctx.cgContext.translateBy(x: 0, y: pixelSize.height)
                    ctx.cgContext.scaleBy(x: pageScale, y: -pageScale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                if let data = encodedPageData(image) {
                    let pagePDF = singlePagePDF(page)
                    // The single-page PDF is kept in memory next to the image, so it counts toward the same limit.
                    renderedBytes += data.count + (pagePDF?.count ?? 0)
                    results.append((data, pageSize.width, pageSize.height, page.string ?? "", pagePDF))
                }
            }
            onPage?(index + 1, total)
        }
        // The last page can be the one that crossed the line.
        if renderedBytes > maxRenderedBytes { return Extraction(rejection: .renderedPagesTooLarge) }
        return Extraction(pages: results)
    }

    /// This page as a one-page PDF, or `nil` when it has no text to select
    /// (a scan) — a bitmap in a PDF wrapper gains nothing over the image.
    static func singlePagePDF(_ page: PDFPage) -> Data? {
        guard let text = page.string, !text.isEmpty, let copy = page.copy() as? PDFPage else { return nil }
        let single = PDFDocument()
        single.insert(copy, at: 0)
        return single.dataRepresentation()
    }

    /// `extractPages` on a background thread, so a long PDF does not freeze the
    /// screen: rendering a 231-page document takes seconds, and on the main
    /// thread that is seconds of no scrolling, no taps and a progress bar that
    /// cannot move. The `PDFDocument` is opened and used inside that one task
    /// and never shared, since PDFKit documents are not thread-safe.
    static func extractPagesAsync(
        from url: URL,
        password: String? = nil,
        scale: CGFloat = defaultScale,
        onPage: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> [RenderedPage] {
        await extractPagesCheckedAsync(from: url, password: password, scale: scale, onPage: onPage).pages
    }

    /// `extractPagesAsync`, saying why when the PDF was refused (see `extractPagesChecked`).
    static func extractPagesCheckedAsync(
        from url: URL,
        password: String? = nil,
        scale: CGFloat = defaultScale,
        onPage: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> Extraction {
        let work = Task.detached(priority: .userInitiated) {
            extractPagesChecked(from: url, password: password, scale: scale, onPage: onPage)
        }
        // A detached task does not inherit its caller's cancellation, so pass it on.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// The size the page appears at once its `/Rotate` is applied. `bounds(for:)`
    /// is the box as stored, so a landscape slide saved as a portrait page with
    /// `/Rotate 90` reports 595×842 while `draw(with:to:)` paints it 842×595.
    /// Sizing the bitmap from the stored box clipped such a page on the right
    /// and left blank space above it.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        let quarterTurns = ((page.rotation / 90) % 4 + 4) % 4
        return quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// `requested`, lowered when the page would exceed `maxPixelEdge`.
    static func effectiveScale(for pageSize: CGSize, requested: CGFloat) -> CGFloat {
        let longest = max(pageSize.width, pageSize.height)
        guard longest > 0 else { return requested }
        return min(requested, maxPixelEdge / longest)
    }

    /// PNG or JPEG, whichever suits the page — see `jpegWorthItRatio`.
    static func encodedPageData(_ image: UIImage) -> Data? {
        guard let png = image.pngData() else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: jpegQuality),
              Double(jpeg.count) < Double(png.count) * jpegWorthItRatio else { return png }
        return jpeg
    }
}
