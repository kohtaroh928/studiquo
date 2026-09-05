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
