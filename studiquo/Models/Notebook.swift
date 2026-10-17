import Foundation
import SwiftData

@Model
final class Notebook {
    /// Stable cross-device identity for cloud retrieval; CloudKit-compatible default.
    var ragDocumentID: String = ""
    var ragID: String = ""
    var ragPreviousSourceIDs: String = ""

    /// Server deletion tombstones an ID permanently; retain aliases for historical citations.
    func retireRAGSource(preservingCitations: Bool = true) -> String {
        ensureRAGIdentity()
        let previous = ragID
        if preservingCitations {
            ragPreviousSourceIDs += (ragPreviousSourceIDs.isEmpty ? "" : ",") + previous
        } else { ragPreviousSourceIDs = "" }
        ragID = UUID().uuidString
        return previous
    }
    func matchesRAGSource(_ sourceId: String) -> Bool {
        ragID == sourceId || ragPreviousSourceIDs.split(separator: ",").contains(Substring(sourceId))
    }
    var title: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    /// Legacy "/"-joined folder path, kept as a migration fallback — see
    /// `FolderMigrationService`. `folder` is the source of truth now.
    var folderName: String = ""
    var folder: Folder?
    var tagsText: String = ""
    var isLocked: Bool = false
    /// Every page and element's content, AES-GCM encrypted, whenever this
    /// notebook is protected and not currently being viewed — see
    /// `NotebookEncryptionService`. `nil` means the content is presently
    /// live in the ordinary (plaintext) page/element fields, either because
    /// the notebook isn't locked at all, or because it's the one currently
    /// open in the editor.
    @Attribute(.externalStorage) var encryptedContent: Data?
    /// The original, still-encrypted PDF bytes, kept only when this notebook
    /// was imported from a password-protected PDF (see `importPDF` in
    /// ContentView.swift) — so "PDFのパスワードを解除" can operate on it
    /// later from the library's long-press menu without asking the student
    /// to re-locate the original file. Cleared once the password has
    /// actually been removed (either from that menu or from the
    /// post-import "save a password-free copy too?" offer).
    @Attribute(.externalStorage) var lockedPDFData: Data?
    /// Verified Docling index package; protected with notebook content when locked.
    @Attribute(.externalStorage) var ragStructuredData: Data?
    var ragStructuredFingerprint: String?
    var ragOriginalPDFHash: String?
    var cachedPageCount: Int = 0
    var cachedContainsPDF: Bool = false
    var libraryMetadataVersion: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \NotePage.notebook)
    var pages: [NotePage]?

    init(title: String) {
        self.ragID = UUID().uuidString
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.libraryMetadataVersion = 1
    }

    func ensureRAGIdentity() {
        if ragID.isEmpty { ragID = UUID().uuidString }
        if ragDocumentID.isEmpty { ragDocumentID = UUID().uuidString }
    }

    /// Appends to the CloudKit-required optional relationship, creating the
    /// backing array on first use.
    func addPage(_ page: NotePage) {
        if pages == nil { pages = [] }
        pages?.append(page)
    }

    var sortedPages: [NotePage] {
        (pages ?? []).sorted { $0.order < $1.order }
    }

    var containsPDF: Bool {
        cachedContainsPDF
    }

    var hasLockedPDFToUnlock: Bool {
        lockedPDFData != nil
    }

    var pageCountForLibrary: Int {
        cachedPageCount
    }

    func refreshLibraryMetadata() {
        cachedPageCount = sortedPages.count
        cachedContainsPDF = sortedPages.contains { $0.backgroundImageData != nil }
        libraryMetadataVersion = 1
    }

    var tags: [String] {
        get {
            tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsText = Array(Set(newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
                .sorted()
                .joined(separator: ", ")
        }
    }
}
