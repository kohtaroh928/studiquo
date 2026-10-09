import Foundation
import PDFKit
import UIKit

enum PDFImportService {
    typealias RenderedPage = (imageData: Data, width: Double, height: Double, text: String)

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
        guard let document = PDFDocument(url: url) else { return [] }
        // Unlock whenever a password is supplied, not only when PDFKit calls
        // the document locked — its `isLocked` is unreliable and leaving a
        // still-encrypted document renders every page blank.
        if let password {
            _ = document.unlock(withPassword: password)
        }
        var results: [RenderedPage] = []
        let total = document.pageCount

        for index in 0..<total {
            if Task.isCancelled { return [] }
            // Each page is a large bitmap; drain the temporaries per page so a
            // long PDF does not pile them all up before the loop ends.
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { return }
                let pageScale = effectiveScale(for: bounds.size, requested: scale)
                let pixelSize = CGSize(width: bounds.width * pageScale, height: bounds.height * pageScale)

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
                    results.append((data, bounds.width, bounds.height, page.string ?? ""))
                }
            }
            onPage?(index + 1, total)
        }
        return results
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
        let work = Task.detached(priority: .userInitiated) {
            extractPages(from: url, password: password, scale: scale, onPage: onPage)
        }
        // A detached task does not inherit its caller's cancellation, so pass it on.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
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
