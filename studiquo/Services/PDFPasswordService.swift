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
    enum ServiceError: LocalizedError, Equatable {
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
    /// Returns the document untouched when there was nothing to unlock — no
    /// user password, only owner restrictions, which `removePassword` strips
    /// but which this call has no password to check.
    static func unlock(_ url: URL, password: String) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ServiceError.cannotRead }
        // Whether a real password is needed is decided through `needsPassword`
        // rather than `PDFDocument.isLocked` — the latter proved unreliable,
        // misreporting `false` for some encrypted files (see `needsPassword`),
        // which let a wrong password through unchecked here.
        guard needsPassword(url) else { return document }
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

    /// What the "remove password" flow should do next for `url`, decided
    /// purely from the file's protection state so the routing itself is
    /// testable without any view state.
    ///
    /// Keeping this a single switch point (rather than nested guards each
    /// touching their own piece of view state) is what stops the
    /// not-protected case from ever being wired to the same pending state as
    /// a real password prompt again.
    enum RemovalOutcome: Equatable {
        /// Nothing to remove — a dead end to report, not a password prompt.
        case notProtected
        /// A user password gates the file; prompt for it.
        case needsPassword
        /// Only owner restrictions; strip immediately with an empty password.
        case readyToStripImmediately
    }

    static func removalOutcome(for url: URL) -> RemovalOutcome {
        guard isProtected(url) else { return .notProtected }
        return needsPassword(url) ? .needsPassword : .readyToStripImmediately
    }

    /// A temp URL for the stripped copy. It lives in its own temporary folder
    /// so the visible filename can stay exactly the same as the original PDF.
    static func destinationURL(for source: URL) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(source.lastPathComponent)
    }
}
