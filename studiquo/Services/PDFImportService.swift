import Foundation
import PDFKit
import UIKit

enum PDFImportService {
    /// Renders each page of a PDF at the given URL into a NotePage-compatible
    /// (imageData, width, height) tuple so it can be used as page background.
    ///
    /// A `password` unlocks a protected file first. A locked document that is
    /// never unlocked renders nothing — `PDFPage.draw` produces blank pages —
    /// so the caller must supply the password for a protected PDF.
    static func extractPages(from url: URL, password: String? = nil, scale: CGFloat = 2.0) -> [(imageData: Data, width: Double, height: Double, text: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        // Unlock whenever a password is supplied, not only when PDFKit calls
        // the document locked — its `isLocked` is unreliable and leaving a
        // still-encrypted document renders every page blank.
        if let password, document.isLocked {
            _ = document.unlock(withPassword: password)
        }
        var results: [(Data, Double, Double, String)] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: bounds.width * scale, height: bounds.height * scale))
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: CGSize(width: bounds.width * scale, height: bounds.height * scale)))
                ctx.cgContext.translateBy(x: 0, y: bounds.height * scale)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            if let data = image.pngData() {
                results.append((data, bounds.width, bounds.height, page.string ?? ""))
            }
        }
        return results
    }
}
