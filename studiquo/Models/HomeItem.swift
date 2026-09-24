import Foundation
import SwiftData
import SwiftUI

/// The four kinds of item shown on the home screen, alongside folders.
enum HomeItemKind: String, Codable {
    case notebook, flashcardDeck, textDocument, slideDeck
}

/// Common shape shared by `Notebook`, `FlashcardDeck`, `TextDocument` and
/// `SlideDeck`, so the home screen's icon/list/column views and their shared
/// sorting, filtering and drag-and-drop code can work with one type instead
/// of hand-rolling the same logic four times.
protocol HomeItem: AnyObject {
    var title: String { get set }
    var createdAt: Date { get }
    var updatedAt: Date { get set }
    var isFavorite: Bool { get set }
    var isTrashed: Bool { get set }
    var folder: Folder? { get set }
    /// Legacy "/"-joined path, kept in sync with `folder` by
    /// `ContentView.assign(_:toLegacyPath:)` — see that method's doc comment.
    var folderName: String { get set }
    var itemKind: HomeItemKind { get }
}

extension Notebook: HomeItem {
    var itemKind: HomeItemKind { .notebook }
}
extension FlashcardDeck: HomeItem {
    var itemKind: HomeItemKind { .flashcardDeck }
}
extension TextDocument: HomeItem {
    var itemKind: HomeItemKind { .textDocument }
}
extension SlideDeck: HomeItem {
    var itemKind: HomeItemKind { .slideDeck }
}

/// The same move is used by list, column, icon and sidebar drop targets.
/// Keep the relationship and the legacy path together: columns read the
/// relationship, while the other library views still filter by folderName.
enum LibraryFolderMove {
    static func canMove(_ item: any HomeItem, into folder: Folder?) -> Bool {
        !item.isTrashed && (item.folder !== folder || item.folderName != (folder?.legacyPath ?? ""))
    }

    @discardableResult
    static func move(_ item: any HomeItem, into folder: Folder?) -> Bool {
        guard canMove(item, into: folder) else { return false }
        item.folder = folder
        item.folderName = folder?.legacyPath ?? ""
        item.updatedAt = .now
        return true
    }
}

/// A single home-screen entry, wrapping whichever of the four concrete
/// SwiftData model types it holds. Exists because SwiftData's `@Query`
/// fetches each model type separately — this is what lets the icon/list/
/// column views, sorting and drag-and-drop treat all four as one flat,
/// homogeneous collection instead of merging four arrays by hand at every
/// call site.
enum HomeEntry: Identifiable {
    case notebook(Notebook)
    case flashcardDeck(FlashcardDeck)
    case textDocument(TextDocument)
    case slideDeck(SlideDeck)

    var underlying: any HomeItem {
        switch self {
        case .notebook(let value): return value
        case .flashcardDeck(let value): return value
        case .textDocument(let value): return value
        case .slideDeck(let value): return value
        }
    }

    var id: PersistentIdentifier {
        switch self {
        case .notebook(let value): return value.persistentModelID
        case .flashcardDeck(let value): return value.persistentModelID
        case .textDocument(let value): return value.persistentModelID
        case .slideDeck(let value): return value.persistentModelID
        }
    }

    var title: String { underlying.title }
    var createdAt: Date { underlying.createdAt }
    var updatedAt: Date { underlying.updatedAt }
    var isFavorite: Bool { underlying.isFavorite }
    var isTrashed: Bool { underlying.isTrashed }
    var itemKind: HomeItemKind { underlying.itemKind }
    var folder: Folder? {
        get { underlying.folder }
        set { underlying.folder = newValue }
    }

    var iconName: String {
        switch self {
        case .notebook(let value): return value.containsPDF ? "doc.richtext" : "note.text"
        case .flashcardDeck: return "rectangle.on.rectangle.angled"
        case .textDocument: return "doc.text"
        case .slideDeck: return "rectangle.on.rectangle"
        }
    }

    /// Matches the color each kind already used in the pre-existing list
    /// rows (`studyCardRows`, `documentRows`, `slideRows`, `NotebookRow`), so
    /// the icon grid and column view read as the same visual language.
    var tintColor: Color {
        switch self {
        case .notebook(let value): return value.containsPDF ? .red : .blue
        case .flashcardDeck: return .indigo
        case .textDocument: return .teal
        case .slideDeck: return .orange
        }
    }
}
