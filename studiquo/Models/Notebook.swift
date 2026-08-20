import Foundation
import SwiftData

@Model
final class Notebook {
    var title: String
    var createdAt: Date
    var updatedAt: Date
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
    var pages: [NotePage] = []

    init(title: String) {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.libraryMetadataVersion = 1
    }

    var sortedPages: [NotePage] {
        pages.sorted { $0.order < $1.order }
    }

    var containsPDF: Bool {
        cachedContainsPDF
    }

    var pageCountForLibrary: Int {
        cachedPageCount
    }

    func refreshLibraryMetadata() {
        cachedPageCount = pages.count
        cachedContainsPDF = pages.contains { $0.backgroundImageData != nil }
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
