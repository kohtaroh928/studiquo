import Foundation
import CryptoKit
import PDFKit
import UIKit
import SwiftData

/// Verified package content shares the notebook's storage/encryption lifecycle.
@MainActor
enum RAGStructuredAttachment {
    static func fingerprint(_ notebook: Notebook) -> String {
        var hash = SHA256()
        func add(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for page in notebook.sortedPages {
            add(Data("\(page.order):\(page.pageWidth):\(page.pageHeight)".utf8))
            add(page.backgroundImageData ?? Data()); add(page.drawingData ?? Data())
            add(Data(page.recognizedText.utf8))
            for element in page.allElements {
                add(Data(element.text.utf8)); add(element.imageData ?? Data())
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Editing invalidates the attachment; never send an old package instead of new ink/text.
    static func prepared(_ notebook: Notebook) throws -> RAGStructuredDocument? {
        guard !notebook.isLocked, notebook.encryptedContent == nil, notebook.lockedPDFData == nil, !notebook.isTrashed,
              let data = notebook.ragStructuredData, let pdfHash = notebook.ragOriginalPDFHash,
              notebook.ragStructuredFingerprint == fingerprint(notebook) else { return nil }
        let value = try RAGStructuredDocument(manifestData: data, expectedPDFSHA256: pdfHash)
        guard value.pages.count == notebook.sortedPages.count else { throw RAGStructuredDocument.ValidationError.invalidPreparedDocument }
        return value
    }

    static func pagePayloads(_ document: RAGStructuredDocument) -> [Int: [String: Any]] {
        var output: [Int: [String: Any]] = [:]
        for batch in document.batches {
            for page in batch["pages"] as? [[String: Any]] ?? [] {
                if let number = page["pageNumber"] as? Int { output[number] = page }
            }
        }
        return output
    }

    /// Import only a new PDF notebook bound to the exact bytes that Docling parsed.
    /// No network or model calls; callers explicitly choose both files.
    static func importNotebook(pdfData: Data, manifestData: Data, title: String) throws -> Notebook {
        let document = try RAGStructuredDocument(manifestData: manifestData, originalPDFData: pdfData)
        guard let pdf = PDFDocument(data: pdfData), !pdf.isLocked, pdf.pageCount == document.pages.count else {
            throw RAGStructuredDocument.ValidationError.invalidPreparedDocument
        }
        // Bound rendering separately from the package's wider validation limit.
        guard pdf.pageCount <= 100 else { throw RAGStructuredDocument.ValidationError.invalidPreparedDocument }
        let notebook = Notebook(title: String(title.prefix(300)))
        var imageBytes = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let original = pdf.page(at: index) else { throw RAGStructuredDocument.ValidationError.invalidPreparedDocument }
            let bounds = original.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 1, bounds.height >= 1, bounds.width <= 4096, bounds.height <= 4096,
                  bounds.width * bounds.height <= 4_000_000 else { throw RAGStructuredDocument.ValidationError.invalidPreparedDocument }
            let imageData: Data? = autoreleasepool {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
                    UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: bounds.size))
                    renderer.cgContext.translateBy(x: 0, y: bounds.height)
                    renderer.cgContext.scaleBy(x: 1, y: -1)
                    original.draw(with: .mediaBox, to: renderer.cgContext)
                }.pngData()
            }
            guard let imageData, imageData.count <= 128 * 1024 * 1024 - imageBytes else { throw RAGStructuredDocument.ValidationError.invalidPreparedDocument }
            imageBytes += imageData.count
            let page = NotePage(order: index, backgroundImageData: imageData, pageWidth: bounds.width, pageHeight: bounds.height)
            page.recognizedText = original.string ?? ""; page.textRecognitionDate = .now; page.notebook = notebook
            notebook.addPage(page)
        }
        notebook.refreshLibraryMetadata()
        notebook.ragStructuredData = try document.manifestData
        notebook.ragOriginalPDFHash = document.pdfSHA256
        notebook.ragStructuredFingerprint = fingerprint(notebook)
        return notebook
    }
}
