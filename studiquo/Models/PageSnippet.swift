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

/// Produces a chat-safe image from a page crop. Chat attachments are capped
/// at 3 MB by the server, while a full-resolution PNG crop can easily exceed
/// that even when the selected rectangle looks small on screen.
enum ChatSnippetImageEncoder {
    static let maximumBytes = 3 * 1024 * 1024
    static let maximumDimension: CGFloat = 2_048

    static func jpegData(for snippet: PageSnippet) -> Data? {
        guard let source = snippet.image else { return nil }
        let longest = max(source.size.width, source.size.height)
        let scale = longest > maximumDimension ? maximumDimension / longest : 1
        let targetSize = CGSize(
            width: max(1, source.size.width * scale),
            height: max(1, source.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            source.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        for quality in [0.82, 0.70, 0.58, 0.45, 0.32] {
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                return data
            }
        }
        return nil
    }
}

/// Tracks snippet-to-composer handoffs independently for each chat surface.
///
/// A snippet can arrive through both the pending-item task and a drop event
/// during a rapid pane update. Treating `begin` as an atomic claim prevents
/// duplicate attachment chips and duplicate sends, while `fail`/`remove`
/// deliberately release that claim so the user can retry.
struct ChatSnippetAttachmentTracker: Equatable {
    private(set) var acceptedSnippetIDs: Set<UUID> = []
    private(set) var attachmentIDBySnippetID: [UUID: String] = [:]

    mutating func begin(_ snippetID: UUID) -> Bool {
        acceptedSnippetIDs.insert(snippetID).inserted
    }

    mutating func complete(_ snippetID: UUID, attachmentID: String) {
        acceptedSnippetIDs.insert(snippetID)
        attachmentIDBySnippetID[snippetID] = attachmentID
    }

    mutating func fail(_ snippetID: UUID) {
        acceptedSnippetIDs.remove(snippetID)
        attachmentIDBySnippetID[snippetID] = nil
    }

    mutating func removeAttachment(_ attachmentID: String) {
        let snippetIDs = attachmentIDBySnippetID.compactMap {
            $0.value == attachmentID ? $0.key : nil
        }
        for snippetID in snippetIDs { fail(snippetID) }
    }

    mutating func retainAttachments(withIDs remainingAttachmentIDs: Set<String>) {
        let removedSnippetIDs = attachmentIDBySnippetID.compactMap {
            remainingAttachmentIDs.contains($0.value) ? nil : $0.key
        }
        for snippetID in removedSnippetIDs { fail(snippetID) }
    }
}
