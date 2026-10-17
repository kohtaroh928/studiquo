// Compile with the shared app service through extract-material-pdf.mjs. No document text logs.
import Foundation
import PDFKit
import AppKit
import Vision
import Darwin

enum ExtractionError: Error { case invalidArguments, invalidPDF, limitExceeded, outputExists, writeFailed }

// Exclusive creation protects existing files and makes text private from its first byte.
func writePrivateNewFile(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw ExtractionError.outputExists }
    var identity = stat()
    var success = false
    let hasIdentity = fstat(descriptor, &identity) == 0
    defer {
        close(descriptor)
        if !success && hasIdentity {
            var current = stat()
            if lstat(url.path, &current) == 0 && current.st_ino == identity.st_ino && current.st_dev == identity.st_dev {
                unlink(url.path)
            }
        }
    }
    guard hasIdentity else { throw ExtractionError.writeFailed }
    try data.withUnsafeBytes { bytes in
        guard let start = bytes.baseAddress else { return }
        var completed = 0
        while completed < bytes.count {
            let count = Darwin.write(descriptor, start.advanced(by: completed), bytes.count - completed)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ExtractionError.writeFailed }
            completed += count
        }
    }
    guard fsync(descriptor) == 0 else { throw ExtractionError.writeFailed }
    success = true
}

do {
    guard CommandLine.arguments.count == 3 else { throw ExtractionError.invalidArguments }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw ExtractionError.outputExists }
    let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 100 * 1024 * 1024 else {
        throw ExtractionError.limitExceeded
    }
    guard let pdf = PDFDocument(url: input), (1...1000).contains(pdf.pageCount) else {
        throw ExtractionError.invalidPDF
    }
    var records: [[String: Any]] = []
    var ocrCount = 0
    for index in 0..<pdf.pageCount {
        guard let page = pdf.page(at: index) else { throw ExtractionError.invalidPDF }
        let native = page.string ?? ""
        let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ExtractionError.invalidPDF }
        let started = Date()
        let recognition = await RAGDocumentTextExtractionService.recognize(cg)
        let result = RAGDocumentTextExtractionService.merge(nativeText: native, recognition: recognition)
        ocrCount += 1
        guard result.text.count <= 100_000 else { throw ExtractionError.limitExceeded }
        records.append(["pageNumber": index + 1, "text": result.text, "ocrUsed": true,
                        "nativePresent": !native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "supplementedLines": result.supplementedLines, "rejectedLines": result.rejectedLines,
                        "needsReview": result.needsReview, "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)])
    }
    let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    guard data.count <= 32 * 1024 * 1024 else { throw ExtractionError.limitExceeded }
    try writePrivateNewFile(data, to: output)
    print("Extracted \(pdf.pageCount) pages; OCR checked \(ocrCount).")
} catch {
    fputs("PDF extraction failed. Check arguments, limits and a new output path. No document details logged.\n", stderr)
    exit(1)
}
