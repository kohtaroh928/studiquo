import SwiftUI
import UniformTypeIdentifiers

/// A rectangle lifted off a page as a picture.
///
/// The snip tool cuts these out of the rendered page — printed PDF text,
/// handwriting and photos alike — and the student drags them into the AI
/// chat. A picture rather than recognised text on purpose: handwritten
/// mathematics does not survive OCR, and a marker reading a corrupted proof
/// grades the corruption.
struct PageSnippet: Codable, Transferable, Hashable, Identifiable {
    var id = UUID()
    var pngData: Data
    /// Which page it came from, shown on the chip so two similar-looking
    /// crops can be told apart.
    var sourceLabel: String

    var image: UIImage? { UIImage(data: pngData) }

    static var transferRepresentation: some TransferRepresentation {
        // The app's own type carries the label and identity through a drag.
        // PNG is offered alongside it so a snippet can also be dropped into
        // anything that takes an image.
        CodableRepresentation(contentType: .studiquoPageSnippet)
        DataRepresentation(exportedContentType: .png) { $0.pngData }
    }
}

extension UTType {
    static let studiquoPageSnippet = UTType(exportedAs: "com.studiquo.page-snippet")
}

/// Renders a region of a page as a standalone image.
enum PageSnippetRenderer {
    /// - Parameter rect: the region in page units, as the canvas reports it.
    static func snippet(
        of page: NotePage,
        rect: CGRect,
        label: String,
        drawing: InkDrawing? = nil
    ) -> PageSnippet? {
        // The editor passes its live in-memory drawing. `page.drawingData` is
        // intentionally debounced while the Pencil is moving, so rendering
        // only that persisted copy can produce a blank crop when the student
        // cuts and immediately asks about freshly written ink.
        let full = ExportService.makeImage(from: page, drawing: drawing)
        // `makeImage` renders at the page's own size but at the device scale,
        // so the backing pixels are a multiple of the page units the canvas
        // measured in.
        let scale = full.scale
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = full.cgImage?.cropping(to: pixelRect) else { return nil }
        let image = UIImage(cgImage: cropped, scale: scale, orientation: full.imageOrientation)
        guard cropped.width > 0, cropped.height > 0,
              let data = image.pngData(), !data.isEmpty else { return nil }
        GestureDiagnostics.pageSnippetCreated(
            bytes: data.count,
            pixelWidth: cropped.width,
            pixelHeight: cropped.height,
            usedLiveDrawing: drawing != nil
        )
        return PageSnippet(pngData: data, sourceLabel: label)
    }
}
