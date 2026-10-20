import Foundation

/// State of the home screen's multi-select mode.
///
/// An item is identified by the same "type:id" string the drag-and-drop code
/// already uses (`notebook:`, `deck:`, `document:`, `folder:`), so a
/// selection can be handed straight to the existing move code and survives the
/// student navigating from one folder into another while selecting.
struct HomeSelection: Equatable {
    private(set) var isActive = false
    private(set) var tokens: Set<String> = []

    var count: Int { tokens.count }
    var isEmpty: Bool { tokens.isEmpty }

    func contains(_ token: String) -> Bool { tokens.contains(token) }

    mutating func begin() {
        isActive = true
    }

    /// Leaves selection mode and forgets what was selected.
    mutating func end() {
        isActive = false
        tokens.removeAll()
    }

    mutating func toggle(_ token: String) {
        if tokens.contains(token) {
            tokens.remove(token)
        } else {
            tokens.insert(token)
        }
    }

    /// "全てを選択": adds everything currently on screen to the selection.
    mutating func select(_ newTokens: some Sequence<String>) {
        tokens.formUnion(newTokens)
    }

    /// "選択を解除": deselects everything but stays in selection mode.
    mutating func clear() {
        tokens.removeAll()
    }

    /// Drops selected items that no longer exist, e.g. deleted on another
    /// device while the student was selecting.
    mutating func prune(keeping validTokens: Set<String>) {
        tokens.formIntersection(validTokens)
    }
}

/// Path rules shared by moving and deleting a mixed selection of folders and
/// items. Folders are addressed by their "/"-joined path, as in the rest of
/// the home screen.
enum HomeSelectionRules {
    /// Whether `path` is `root` itself or lies somewhere below it.
    static func isInside(_ path: String, orEqualTo root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// The selected folders that are not nested inside another selected
    /// folder. Acting on these already covers everything beneath them.
    static func topLevelFolderPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            !paths.contains { other in other != path && isInside(path, orEqualTo: other) }
        }
    }

    /// Whether an item or folder at `path` travels along with one of the
    /// selected `roots`, and so must not be moved or deleted a second time.
    static func isCovered(_ path: String, byFolderRoots roots: [String]) -> Bool {
        !path.isEmpty && roots.contains { isInside(path, orEqualTo: $0) }
    }

    /// A folder cannot be moved into itself or into anything beneath itself.
    /// `destination == nil` is the top level, which is always allowed.
    static func isMoveDestinationBlocked(_ destination: String?, movingFolderPaths: [String]) -> Bool {
        guard let destination else { return false }
        return movingFolderPaths.contains { isInside(destination, orEqualTo: $0) }
    }
}
