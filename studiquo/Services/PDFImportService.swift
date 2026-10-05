import Foundation
import PDFKit
import UIKit

enum PDFImportService {
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
    static func extractPages(from url: URL, password: String? = nil, scale: CGFloat = defaultScale) -> [(imageData: Data, width: Double, height: Double, text: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        // Unlock whenever a password is supplied, not only when PDFKit calls
        // the document locked — its `isLocked` is unreliable and leaving a
        // still-encrypted document renders every page blank.
        if let password {
            _ = document.unlock(withPassword: password)
        }
        var results: [(Data, Double, Double, String)] = []

        for index in 0..<document.pageCount {
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
        }
        return results
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
