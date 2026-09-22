import Foundation
import SwiftData

/// One-time migration from the legacy "/"-joined `folderName` path strings
/// (plus the folder list, creation dates and favorites previously kept only
/// in local `UserDefaults`) into real, CloudKit-synced `Folder` records
/// connected to each item via a SwiftData relationship.
///
/// Guarded by `didMigrateKey` so it's a no-op on every launch after the
/// first. `folderName` is left populated on every item rather than cleared,
/// as a fallback in case this ever needs to run again.
enum FolderMigrationService {
    private static let didMigrateKey = "didMigrateFoldersToHierarchy"

    static func migrateIfNeeded(
        context: ModelContext,
        folderNamesStorage: String,
        folderCreatedAtStorage: String,
        favoriteFolderPathsStorage: String,
        notebooks: [Notebook],
        flashcardDecks: [FlashcardDeck],
        textDocuments: [TextDocument],
        slideDecks: [SlideDeck]
    ) {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else { return }

        let knownPaths = Set(folderNamesStorage.split(separator: "\n").map(String.init))
        let createdAtByPath = decodeCreatedAt(folderCreatedAtStorage)
        let favoritePaths = Set(favoriteFolderPathsStorage.split(separator: "\n").map(String.init))

        // Every path actually referenced by an item, even one that never
        // made it into `libraryFolderNames` — that list is local-only and
        // could have drifted from what another device wrote into an item's
        // `folderName`.
        var allPaths = knownPaths
        let referencedPaths = notebooks.map(\.folderName)
            + flashcardDecks.map(\.folderName)
            + textDocuments.map(\.folderName)
            + slideDecks.map(\.folderName)
        for path in referencedPaths where !path.isEmpty {
            allPaths.insert(path)
        }

        // Every ancestor of every path, so "数学/代数" implies a "数学"
        // folder exists even if it was never listed on its own.
        for path in allPaths {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                allPaths.insert(components.joined(separator: "/"))
            }
        }
        guard !allPaths.isEmpty else {
            UserDefaults.standard.set(true, forKey: didMigrateKey)
            return
        }

        // Shallowest paths first, so a child's parent already exists in
        // `foldersByPath` by the time the child is created.
        let orderedPaths = allPaths.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }

        var foldersByPath: [String: Folder] = [:]
        for path in orderedPaths {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            let parentPath = components.dropLast().joined(separator: "/")
            let folder = Folder(name: name, parent: parentPath.isEmpty ? nil : foldersByPath[parentPath])
            folder.isFavorite = favoritePaths.contains(path)
            if let created = createdAtByPath[path] {
                folder.createdAt = Date(timeIntervalSince1970: created)
            }
            context.insert(folder)
            foldersByPath[path] = folder
        }

        for notebook in notebooks where !notebook.folderName.isEmpty {
            notebook.folder = foldersByPath[notebook.folderName]
        }
        for deck in flashcardDecks where !deck.folderName.isEmpty {
            deck.folder = foldersByPath[deck.folderName]
        }
        for document in textDocuments where !document.folderName.isEmpty {
            document.folder = foldersByPath[document.folderName]
        }
        for deck in slideDecks where !deck.folderName.isEmpty {
            deck.folder = foldersByPath[deck.folderName]
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: didMigrateKey)
    }

    private static func decodeCreatedAt(_ storage: String) -> [String: TimeInterval] {
        guard let data = storage.data(using: .utf8),
              let dates = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return dates
    }
}
