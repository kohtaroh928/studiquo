import PDFKit
import UIKit

@MainActor
enum PageRotationService {
    static func rotateClockwise(_ page: NotePage) {
        let pageSlot = PageSlot(page)
        // Snapshotted before anything changes — every element keeps the
        // same identity through a rotation (nothing is added or removed,
        // only repositioned), so each gets its own slot/snapshot pair the
        // same way a grouped lasso move does.
        let elementEntries = page.allElements.map { (ElementSlot($0), PageElementSnapshot($0)) }
        let beforeDrawingData = page.drawingData
        let beforeBackgroundImageData = page.backgroundImageData
        let beforeBackgroundPDFData = page.backgroundPDFData
        let beforePageWidth = page.pageWidth
        let beforePageHeight = page.pageHeight

        let oldWidth = page.pageWidth
        let oldHeight = page.pageHeight

        if let data = page.backgroundImageData, let image = UIImage(data: data) {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: image.size.height, height: image.size.width))
            let rotated = renderer.image { context in
                context.cgContext.translateBy(x: image.size.height, y: 0)
                context.cgContext.rotate(by: .pi / 2)
                image.draw(at: .zero)
            }
            page.backgroundImageData = rotated.jpegData(compressionQuality: 0.92)
        }

        // The one-page PDF describes the same background; left alone it would
        // keep the old orientation while the bitmap turned, so the printed
        // text and the ink drawn over it would no longer line up.
        if let pdf = page.backgroundPDFData {
            page.backgroundPDFData = rotatedPDF(pdf)
        }

        if let data = page.drawingData, let drawing = InkDrawing.load(from: data) {
            let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: oldHeight, ty: 0)
            page.drawingData = try? drawing.transformed(by: transform).data()
        }

        for element in page.allElements {
            let oldX = element.centerX
            element.centerX = 1 - element.centerY
            element.centerY = oldX
            let oldElementWidth = element.width
            element.width = element.height
            element.height = oldElementWidth
            element.rotation += 90
        }
        page.pageWidth = oldHeight
        page.pageHeight = oldWidth
        page.notebook?.updatedAt = .now

        let afterElementEntries = elementEntries.compactMap { entry -> (ElementSlot, PageElementSnapshot)? in
            guard let element = entry.0.element else { return nil }
            return (entry.0, PageElementSnapshot(element))
        }
        let afterDrawingData = page.drawingData
        let afterBackgroundImageData = page.backgroundImageData
        let afterBackgroundPDFData = page.backgroundPDFData
        let afterPageWidth = page.pageWidth
        let afterPageHeight = page.pageHeight

        NoteActionHistory.shared.record(
            undo: {
                guard let page = pageSlot.page else { return }
                page.drawingData = beforeDrawingData
                page.backgroundImageData = beforeBackgroundImageData
                page.backgroundPDFData = beforeBackgroundPDFData
                page.pageWidth = beforePageWidth
                page.pageHeight = beforePageHeight
                for (slot, snapshot) in elementEntries { guard let element = slot.element else { continue }; snapshot.apply(to: element) }
                page.notebook?.updatedAt = .now
            },
            redo: {
                guard let page = pageSlot.page else { return }
                page.drawingData = afterDrawingData
                page.backgroundImageData = afterBackgroundImageData
                page.backgroundPDFData = afterBackgroundPDFData
                page.pageWidth = afterPageWidth
                page.pageHeight = afterPageHeight
                for (slot, snapshot) in afterElementEntries { guard let element = slot.element else { continue }; snapshot.apply(to: element) }
                page.notebook?.updatedAt = .now
            }
        )
    }

    /// A one-page PDF turned a quarter clockwise, or `nil` when it cannot be
    /// read — the caller then keeps the unturned PDF out of sight rather
    /// than showing it sideways against the turned bitmap.
    static func rotatedPDF(_ data: Data) -> Data? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        page.rotation = (page.rotation + 90) % 360
        return document.dataRepresentation()
    }
}
