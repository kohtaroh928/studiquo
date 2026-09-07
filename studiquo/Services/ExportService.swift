import Foundation
import UIKit
import SwiftUI

enum ExportService {
    /// A flattened, read-only rendering of an in-app note/deck/document/slide,
    /// suitable for sending to a friend in chat. The recipient's device has no
    /// access to the sender's local SwiftData store, so a live editable object
    /// can never be handed over directly — a PDF is the shared, self-contained
    /// stand-in both sides can open the same way an uploaded photo or file
    /// already is.
    static func chatAttachmentPDFData(sourceKind: String, sourceID: String, notebooks: [Notebook], flashcardDecks: [FlashcardDeck], textDocuments: [TextDocument], slideDecks: [SlideDeck]) -> Data? {
        switch sourceKind {
        case "notebook":
            guard let notebook = notebooks.first(where: { String(describing: $0.persistentModelID) == sourceID && !$0.isTrashed }) else { return nil }
            return pdfData(from: notebook)
        case "deck", "flashcards":
            guard let deck = flashcardDecks.first(where: { String(describing: $0.persistentModelID) == sourceID && !$0.isTrashed }) else { return nil }
            return pdfData(from: deck)
        case "document":
            guard let document = textDocuments.first(where: { String(describing: $0.persistentModelID) == sourceID && !$0.isTrashed }) else { return nil }
            return pdfData(from: document)
        case "slide":
            guard let deck = slideDecks.first(where: { String(describing: $0.persistentModelID) == sourceID && !$0.isTrashed }) else { return nil }
            return pdfData(from: deck)
        default:
            return nil
        }
    }

    static func pdfData(from notebook: Notebook) -> Data? {
        pdfData(pages: notebook.sortedPages)
    }

    static func pdfData(from document: TextDocument) -> Data? {
        let attributedText = DocumentBody.decode(document.bodyData)
        let pageSize = document.pageSize.size
        let margin = document.pageSize.margin
        let textRect = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            var offset = 0
            let total = attributedText.length
            repeat {
                context.beginPage()
                guard let cgContext = UIGraphicsGetCurrentContext() else { break }
                cgContext.translateBy(x: 0, y: pageSize.height)
                cgContext.scaleBy(x: 1, y: -1)

                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(offset, 0), path, nil)
                CTFrameDraw(frame, cgContext)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 { break }
                offset += visible.length
            } while offset < total

            if total == 0 { context.beginPage() }
        }
    }

    static func pdfData(from deck: SlideDeck) -> Data? {
        let size = deck.aspect.size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let theme = deck.theme
        let aspect = deck.aspect
        let ordered = deck.sortedSlides
        let family = deck.fontFamily
        let scale = CGFloat(deck.textScale)
        let bold = deck.titleIsBold
        let italic = deck.bodyIsItalic
        return renderer.pdfData { context in
            for slide in ordered {
                context.beginPage()
                let view = SlideCanvas(
                    slide: slide, theme: theme, aspect: aspect, isEditable: false,
                    fontFamily: family, textScale: scale, titleIsBold: bold, bodyIsItalic: italic
                )
                    .frame(width: size.width, height: size.height)
                let imageRenderer = ImageRenderer(content: view)
                imageRenderer.scale = 2
                if let image = imageRenderer.uiImage {
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            if ordered.isEmpty { context.beginPage() }
        }
    }

    /// Flashcards have no existing PDF export to reuse — this renders a
    /// simple one-card-per-page question/answer layout, enough for a friend
    /// to read the deck without needing the live study UI.
    static func pdfData(from deck: FlashcardDeck) -> Data? {
        let cards = deck.sortedCards
        guard !cards.isEmpty else { return nil }
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 48
        let contentWidth = pageSize.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let questionAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
            let answerAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.label
            ]
            for (index, card) in cards.enumerated() {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                ("\(index + 1) / \(cards.count)" as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: labelAttributes)
                ("Q" as NSString).draw(at: CGPoint(x: margin, y: margin + 32), withAttributes: labelAttributes)
                (card.question as NSString).draw(
                    in: CGRect(x: margin, y: margin + 56, width: contentWidth, height: 220),
                    withAttributes: questionAttributes
                )
                ("A" as NSString).draw(at: CGPoint(x: margin, y: margin + 300), withAttributes: labelAttributes)
                (card.answer as NSString).draw(
                    in: CGRect(x: margin, y: margin + 324, width: contentWidth, height: 220),
                    withAttributes: answerAttributes
                )
            }
        }
    }

    static func makePNG(from page: NotePage, notebookTitle: String) -> URL? {
        guard let data = makeImage(from: page).pngData() else { return nil }
        let safeTitle = notebookTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle)-page-\(page.order + 1).png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// The page exactly as it is drawn — background, ink and elements — at
    /// page size. Used both for PNG export and for handing a handwritten
    /// answer to the proof marker, which reads the image rather than any
    /// recognised text.
    static func makeImage(from page: NotePage, drawing drawingOverride: InkDrawing? = nil) -> UIImage {
        let size = CGSize(width: page.pageWidth, height: page.pageHeight)
        return UIGraphicsImageRenderer(size: size).image { context in
            if let bgData = page.backgroundImageData, let bgImage = UIImage(data: bgData) {
                bgImage.draw(in: CGRect(origin: .zero, size: size))
            } else {
                UIColor(hex: page.paperColorHex).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let drawing = drawingOverride ?? page.drawingData.flatMap(InkDrawing.load(from:))
            if let drawing {
                drawing.image(from: CGRect(origin: .zero, size: size), scale: 2).draw(in: CGRect(origin: .zero, size: size))
            }
            for element in page.allElements.sorted(by: { $0.layerIndex < $1.layerIndex }) {
                draw(element: element, pageSize: size)
            }
        }
    }

    static func makePDF(from notebook: Notebook) -> URL? {
        makePDF(pages: notebook.sortedPages, filename: notebook.title)
    }

    static func makePDF(from page: NotePage, notebookTitle: String) -> URL? {
        makePDF(pages: [page], filename: "\(notebookTitle)-page-\(page.order + 1)")
    }

    private static func makePDF(pages: [NotePage], filename: String) -> URL? {
        guard let data = pdfData(pages: pages) else { return nil }

        let safeFilename = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeFilename).pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func pdfData(pages: [NotePage]) -> Data? {
        guard !pages.isEmpty else { return nil }

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: .zero)
        return pdfRenderer.pdfData { context in
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

                for element in page.allElements.sorted(by: { $0.layerIndex < $1.layerIndex }) {
                    draw(element: element, pageSize: size)
                }
            }
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
