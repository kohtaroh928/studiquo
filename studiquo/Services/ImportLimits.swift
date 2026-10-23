import Foundation
import ImageIO

/// Upper bounds for files the app reads from outside — the file picker, drag
/// and drop, the share sheet. A file from a stranger can be hostile or just
/// absurdly large: a few kilobytes of ZIP that inflate to gigabytes, a PDF with
/// tens of thousands of pages, a PNG that declares 60000×60000 pixels. Each is
/// otherwise read whole into memory, and iPadOS ends the app (no message, work
/// lost) when it runs out. The limits sit far above anything a student really
/// imports, and a file past one is refused up front with a message that says why.
enum ImportLimits {
    /// A scanned textbook is a few hundred MB; past this it is not a document.
    static let maxPDFFileBytes: Int64 = 500_000_000
    static let maxPDFPages = 1_000
    /// What the rendered pages of one PDF may add up to in memory before the
    /// import stops. Every page is held until the notebook is built.
    /// Kept well under the app's memory ceiling, and small enough that the
    /// notebook's backup (JSON with base64 images, about 4/3 the size) still
    /// fits `maxBackupFileBytes`.
    static let maxRenderedPDFBytes = 400_000_000

    static let maxDocxFileBytes: Int64 = 50_000_000
    /// A `.docx` is a handful of parts plus media.
    static let maxZipEntries = 2_000
    /// All entries of one archive together, once inflated.
    static let maxZipTotalUncompressedBytes = 200_000_000

    static let maxImageFileBytes: Int64 = 100_000_000
    /// Width × height as declared in the image header, checked before any
    /// pixel is decoded. 64 megapixels is already 256 MB of RGBA; a 48 MP
    /// camera photo is well inside.
    static let maxImagePixels: Int64 = 64_000_000
    /// An animated GIF is decoded frame by frame into memory. Frames × pixels
    /// of the whole file may not pass this.
    static let maxImageTotalPixels: Int64 = 128_000_000

    /// Word lists and action files (txt, csv, tsv, json).
    static let maxTextFileBytes: Int64 = 5_000_000
    /// The app's own notebook backup: JSON with every page image inside.
    static let maxBackupFileBytes: Int64 = 600_000_000

    enum Rejection: Error, Equatable {
        case fileTooLarge(limitBytes: Int64)
        case tooManyPages(limit: Int)
        case imageTooLarge
        case imageUnreadable
        case renderedPagesTooLarge
        case archiveTooLarge

        /// Shown to the student. The wording says what to do, not just what failed.
        var message: String {
            switch self {
            case .fileTooLarge(let limit):
                return "ファイルが大きすぎます(上限 \(limit / 1_000_000) MB)。分けてから読み込んでください。"
            case .tooManyPages(let limit):
                return "ページ数が多すぎます(上限 \(limit) ページ)。分けてから読み込んでください。"
            case .imageTooLarge:
                return "画像の解像度が高すぎます。縮小してから読み込んでください。"
            case .imageUnreadable:
                return "この画像は読み込めませんでした。壊れているか、対応していない形式の可能性があります。"
            case .renderedPagesTooLarge:
                return "このPDFは読み込むと大きくなりすぎます。ページを分けてから読み込んでください。"
            case .archiveTooLarge:
                return "ファイルを展開すると大きくなりすぎます。読み込めません。"
            }
        }
    }

    /// The file's size in bytes, or nil when it cannot be read (a missing file,
    /// a cloud file not yet downloaded). A nil size is not a rejection: reading
    /// the file will fail on its own with the usual message.
    static func fileSize(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    static func checkFileSize(of url: URL, maxBytes: Int64) -> Rejection? {
        guard let size = fileSize(of: url), size > maxBytes else { return nil }
        return .fileTooLarge(limitBytes: maxBytes)
    }

    static func checkImagePixels(width: Double, height: Double) -> Rejection? {
        guard width > 0, height > 0 else { return nil }
        // Doubles so a hostile 4-billion-wide header cannot overflow.
        return width * height > Double(maxImagePixels) ? .imageTooLarge : nil
    }

    /// Judges an image from its header alone, before anything is decoded.
    /// Fails closed: bytes ImageIO cannot read are refused, not decoded anyway.
    /// Every frame counts, since `UIImage(data:)` decodes an animated GIF whole.
    static func checkImage(data: Data) -> Rejection? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .imageUnreadable }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return .imageUnreadable }
        if let rejection = checkImagePixels(width: width, height: height) { return rejection }
        return width * height * Double(frames) > Double(maxImageTotalPixels) ? .imageTooLarge : nil
    }
}
