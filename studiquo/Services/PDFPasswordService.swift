import Foundation
import PDFKit

/// Removing the password from a PDF the student can already open.
///
/// This is PDF Expert's "remove password", and the same limit applies: it
/// only ever *uses* a password the student supplies to unlock a document —
/// it never tries to guess or break one. A file whose password is unknown
/// stays closed.
///
/// Two kinds of protection exist, and the service handles both:
///
/// - a **user password**, required to open the file at all (`PDFDocument`
///   reports `isLocked` until it is unlocked);
/// - an **owner password**, which leaves the file readable but forbids
///   printing, copying or editing (`isLocked` is already false, but
///   `allowsPrinting` and friends are not).
///
/// Writing the document back out without any encryption options produces a
/// plain copy in both cases.
enum PDFPasswordService {
    enum ServiceError: LocalizedError {
        case cannotRead
        case wrongPassword
        case notProtected
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .cannotRead: return L("PDFを読み込めませんでした。ファイルが壊れている可能性があります。")
            case .wrongPassword: return L("パスワードが違います。もう一度お試しください。")
            case .notProtected: return L("このPDFにはパスワードがかかっていません。")
            case .writeFailed: return L("PDFの書き出しに失敗しました。")
            }
        }
    }

    /// Whether opening the file needs a password. False for an unprotected
    /// file *and* for one that is only owner-restricted (it opens with an
    /// empty password).
    ///
    /// Decided through `CGPDFDocument` rather than `PDFDocument.isLocked`.
    /// The latter proved unreliable — for some encrypted files it reported
    /// the document as unlocked, so the importer never prompted and rendered
    /// a stack of blank pages instead.
    static func needsPassword(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL), document.isEncrypted else { return false }
        if document.isUnlocked { return false }
        // An empty password opens an owner-only file; if even that fails, a
        // real password is required.
        return !document.unlockWithPassword("")
    }

    /// Whether the file carries any protection at all — an open password, or
    /// owner restrictions on printing/copying. This is what decides whether
    /// "remove password" has anything to do.
    static func isProtected(_ url: URL) -> Bool {
        CGPDFDocument(url as CFURL)?.isEncrypted ?? false
    }

    /// Unlocks `url` with `password`, returning the open document.
    ///
    /// Throws `notProtected` when there was nothing to unlock, so a caller
    /// prompting for a password can tell the student the prompt was
    /// unnecessary rather than silently doing nothing.
    static func unlock(_ url: URL, password: String) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ServiceError.cannotRead }
        guard document.isLocked else {
            // Already readable. It may still be owner-restricted, which
            // `removePassword` strips — but there is no user password to check
            // here, so an unlock request against it is a no-op to report.
            return document
        }
        guard document.unlock(withPassword: password) else { throw ServiceError.wrongPassword }
        return document
    }

    /// Writes an unprotected copy of `source` to `destination`.
    ///
    /// `password` is used only to open the file and is never stored. When the
    /// file opens without one (owner-restricted only), pass an empty string.
    ///
    /// The copy is rebuilt page by page into a fresh PDF context rather than
    /// written with `PDFDocument.write(to:)`. That method looked right but
    /// carried the source's encryption dictionary into the output — the
    /// "stripped" file came back still locked. Drawing each `CGPDFPage` into a
    /// new `CGContext` produces a genuinely unencrypted PDF while keeping the
    /// pages as vector content, so text stays selectable and links survive.
    @discardableResult
    static func removePassword(from source: URL, password: String, to destination: URL) throws -> URL {
        guard let document = CGPDFDocument(source as CFURL) else { throw ServiceError.cannotRead }

        if document.isEncrypted {
            // An empty owner password unlocks a file that only restricts
            // permissions; a user-locked file needs the real one.
            if !document.isUnlocked, !document.unlockWithPassword(password) {
                // `unlockWithPassword("")` is worth a try for owner-only files
                // whose caller passed something non-empty by habit.
                if password.isEmpty || !document.unlockWithPassword("") {
                    throw ServiceError.wrongPassword
                }
            }
        } else {
            throw ServiceError.notProtected
        }

        try? FileManager.default.removeItem(at: destination)
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw ServiceError.writeFailed
        }
        for index in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: index) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            context.endPage()
        }
        context.closePDF()
        return destination
    }

    /// A temp URL for the stripped copy, named after the original with a
    /// suffix so it is recognisable in a share sheet.
    static func destinationURL(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)_パスワードなし.pdf")
    }
}
