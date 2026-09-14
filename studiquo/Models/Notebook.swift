import Foundation
import SwiftData

@Model
final class Notebook {
    var title: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    var folderName: String = ""
    var tagsText: String = ""
    var isLocked: Bool = false
    /// Every page and element's content, AES-GCM encrypted, whenever this
    /// notebook is protected and not currently being viewed — see
    /// `NotebookEncryptionService`. `nil` means the content is presently
    /// live in the ordinary (plaintext) page/element fields, either because
    /// the notebook isn't locked at all, or because it's the one currently
    /// open in the editor.
    @Attribute(.externalStorage) var encryptedContent: Data?
    var cachedPageCount: Int = 0
    var cachedContainsPDF: Bool = false
    var libraryMetadataVersion: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \NotePage.notebook)
    var pages: [NotePage]?

    init(title: String) {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.libraryMetadataVersion = 1
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
