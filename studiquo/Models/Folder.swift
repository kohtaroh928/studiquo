import Foundation
import SwiftData

/// A user-created folder for organizing notebooks, flashcard decks, text
/// documents and slide decks. Folders nest inside one another via
/// `parent`/`children`, replacing the older scheme where a folder was just a
/// "/"-joined path string stored on each item's now-legacy `folderName` (see
/// `FolderMigrationService`, which converts existing data into this shape).
@Model
final class Folder {
    var name: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isFavorite: Bool = false
    /// Manual ordering within the parent folder; unused until drag-to-reorder
    /// lands, but present now so it doesn't need its own later migration.
    var sortIndex: Int = 0

    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder]?

    @Relationship(deleteRule: .nullify, inverse: \Notebook.folder)
    var notebooks: [Notebook]?
    @Relationship(deleteRule: .nullify, inverse: \FlashcardDeck.folder)
    var flashcardDecks: [FlashcardDeck]?
    @Relationship(deleteRule: .nullify, inverse: \TextDocument.folder)
    var textDocuments: [TextDocument]?
    @Relationship(deleteRule: .nullify, inverse: \SlideDeck.folder)
    var slideDecks: [SlideDeck]?

    init(name: String, parent: Folder? = nil) {
        self.name = name
        self.parent = parent
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Root-to-this path, joined the same way the legacy `folderName` strings
    /// were, for anything still displaying or matching against that format.
    var pathComponents: [String] {
        (parent?.pathComponents ?? []) + [name]
    }

    var legacyPath: String {
        pathComponents.joined(separator: "/")
    }

    /// Whether moving this folder into `newParent` would create a cycle
    /// (i.e. `newParent` is this folder itself, or already sits somewhere
    /// underneath it) — checked before any folder-into-folder drag-and-drop
    /// move is committed.
    func wouldCreateCycle(ifMovedInto newParent: Folder) -> Bool {
        var current: Folder? = newParent
        while let folder = current {
            if folder === self { return true }
            current = folder.parent
        }
        return false
    }
}
