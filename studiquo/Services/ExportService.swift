import Foundation
import UIKit

enum ExportService {
    static func makePNG(from page: NotePage, notebookTitle: String) -> URL? {
        let size = CGSize(width: page.pageWidth, height: page.pageHeight)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if let bgData = page.backgroundImageData, let bgImage = UIImage(data: bgData) {
                bgImage.draw(in: CGRect(origin: .zero, size: size))
            } else {
                UIColor(hex: page.paperColorHex).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            if let data = page.drawingData, let drawing = InkDrawing.load(from: data) {
                drawing.image(from: CGRect(origin: .zero, size: size), scale: 2).draw(in: CGRect(origin: .zero, size: size))
            }
            for element in page.elements.sorted(by: { $0.layerIndex < $1.layerIndex }) {
                draw(element: element, pageSize: size)
            }
        }
        guard let data = image.pngData() else { return nil }
        let safeTitle = notebookTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle)-page-\(page.order + 1).png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    static func makePDF(from notebook: Notebook) -> URL? {
        makePDF(pages: notebook.sortedPages, filename: notebook.title)
    }

    static func makePDF(from page: NotePage, notebookTitle: String) -> URL? {
        makePDF(pages: [page], filename: "\(notebookTitle)-page-\(page.order + 1)")
    }

    private static func makePDF(pages: [NotePage], filename: String) -> URL? {
        guard !pages.isEmpty else { return nil }

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: .zero)
        let data = pdfRenderer.pdfData { context in
            for page in pages {
                let size = CGSize(width: page.pageWidth, height: page.pageHeight)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])

                if let bgData = page.backgroundImageData, let bgImage = UIImage(data: bgData) {
                    bgImage.draw(in: CGRect(origin: .zero, size: size))
                } else {
                    UIColor(hex: page.paperColorHex).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }

                if let drawingData = page.drawingData,
                   let drawing = InkDrawing.load(from: drawingData) {
                    let drawingImage = drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)
                    drawingImage.draw(in: CGRect(origin: .zero, size: size))
                }

                for element in page.elements.sorted(by: { $0.layerIndex < $1.layerIndex }) {
                    draw(element: element, pageSize: size)
                }
            }
        }

        let safeFilename = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeFilename).pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func draw(element: PageElement, pageSize: CGSize) {
        let rect = CGRect(
            x: pageSize.width * element.centerX - pageSize.width * element.width / 2,
            y: pageSize.height * element.centerY - pageSize.height * element.height / 2,
            width: pageSize.width * element.width,
            height: pageSize.height * element.height
        )
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: element.rotation * .pi / 180)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        let color = UIColor(hex: element.colorHex)
        switch element.kind {
        case .text:
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(12, rect.height * 0.42)),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            (element.text as NSString).draw(in: rect.insetBy(dx: 4, dy: 4), withAttributes: attributes)
        case .image:
            if let data = element.imageData, let image = UIImage(data: data) {
                image.draw(in: rect)
            }
        case .rectangle:
            color.setStroke()
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            path.lineWidth = 3
            path.stroke()
        case .ellipse:
            color.setStroke()
            let path = UIBezierPath(ovalIn: rect)
            path.lineWidth = 3
            path.stroke()
        case .line:
            color.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.lineWidth = 3
            path.stroke()
        case .studyTape:
            color.withAlphaComponent(0.92).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 5).fill()
        case .pageLink:
            let parts = element.text.split(separator: "|", maxSplits: 1)
            let title = parts.count > 1 ? String(parts[1]) : "ページへ移動"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(12, rect.height * 0.42), weight: .semibold),
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            (("リンク: " + title) as NSString).draw(in: rect.insetBy(dx: 4, dy: 4), withAttributes: attributes)
        }
        context.restoreGState()
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
