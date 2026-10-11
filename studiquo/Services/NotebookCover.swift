import Foundation
import SwiftData

/// Which image stands in for a PDF notebook in the library and the pickers:
/// its first page, as imported (`NotePage.backgroundImageData`).
enum NotebookCover {
    /// Longest side, in pixels, of the decoded cover. Covers are shown at most
    /// ~100pt wide, so one small tier is enough and keeps many of them cheap.
    static let pixelSize = NoteImagePipeline.ThumbnailTier.small.maximumPixelSize

    /// Only a PDF notebook gets a cover; a plain note keeps its symbol. A
    /// protected notebook never does: its pages are sealed while it is
    /// closed, and what is on them must not show in a list.
    static func isEligible(_ notebook: Notebook) -> Bool {
        notebook.containsPDF && !notebook.isLocked
    }

    /// The first page by `order`, which is not necessarily `pages.first` and
    /// can start above 0 once pages were deleted or reordered.
    static func firstPage(of pages: [NotePage]) -> NotePage? {
        pages.min { $0.order < $1.order }
    }

    /// The first page's image bytes, or nil when the notebook has no cover.
    static func imageData(of notebook: Notebook, in context: ModelContext) -> Data? {
        guard isEligible(notebook) else { return nil }
        return firstPageImageData(ofNotebookWithID: notebook.persistentModelID, in: context)
    }

    /// Fetches that one page instead of reading `notebook.pages`, which would
    /// fault in every page of a long PDF just to show one thumbnail. It does
    /// not check `isEligible`: the caller must, because a protected notebook's
    /// cover must never be read.
    ///
    /// Pass a context of its own (`ModelContext(container)`) from a background
    /// task, so reading the image file does not happen on the main thread.
    static func firstPageImageData(ofNotebookWithID id: PersistentIdentifier, in context: ModelContext) -> Data? {
        var descriptor = FetchDescriptor<NotePage>(
            predicate: #Predicate { $0.notebook?.persistentModelID == id },
            sortBy: [SortDescriptor(\.order)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.backgroundImageData
    }

    /// Distinguishes notebooks, and a replaced first page of the same notebook.
    static func cacheKey(for notebook: Notebook, data: Data) -> String {
        NoteImagePipeline.cacheKey(
            elementID: "cover:\(notebook.persistentModelID.hashValue)",
            data: data,
            thumbnailPixelSize: pixelSize
        )
    }
}
