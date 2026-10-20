import Foundation

/// A file the user opened from the Files app, remembered so it can be opened
/// again after the app restarts.
///
/// The bookmark and the name are the user's own data about where their files
/// live. They stay on this device (a bookmark does not resolve on another one)
/// and are never written to logs or error reports.
struct ExternalFileEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var bookmarkData: Data
    var displayName: String
    var lastOpened: Date
}

/// The two system calls the store needs, so tests can replace them.
struct ExternalFileBookmarking {
    var makeBookmark: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)

    static let system = ExternalFileBookmarking(
        // iOS bookmarks carry the security scope on their own; the
        // `.withSecurityScope` option is macOS-only.
        makeBookmark: { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { data in
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return (url, isStale)
        }
    )
}

enum ExternalFileResolveResult: Equatable {
    case resolved(URL)
    case failed
}

/// Recently opened external files, newest first.
final class ExternalFileBookmarkStore {
    static let maximumEntries = 20

    private let fileURL: URL
    private let bookmarking: ExternalFileBookmarking
    private let now: () -> Date
    private(set) var entries: [ExternalFileEntry]

    init(
        fileURL: URL,
        bookmarking: ExternalFileBookmarking = .system,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.bookmarking = bookmarking
        self.now = now
        self.entries = Self.load(from: fileURL)
    }

    /// Default location: Application Support, excluded from backups because a
    /// bookmark is meaningless on another device.
    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Inside the app's own folder so account deletion can erase it with the
        // other app-managed data (see `AccountFileEraser`).
        return base.appendingPathComponent("studiquo/ExternalFileBookmarks.json")
    }

    /// Remembers `url`, which the caller must already have scoped access to.
    /// Opening the same file again moves its entry to the front instead of
    /// adding a second one.
    @discardableResult
    func add(url: URL) -> ExternalFileEntry? {
        guard let data = try? bookmarking.makeBookmark(url) else { return nil }
        let name = url.lastPathComponent
        if let index = entries.firstIndex(where: { sameFile($0, as: url) }) {
            var entry = entries.remove(at: index)
            entry.bookmarkData = data
            entry.displayName = name
            entry.lastOpened = now()
            entries.insert(entry, at: 0)
            save()
            return entry
        }
        let entry = ExternalFileEntry(id: UUID(), bookmarkData: data, displayName: name, lastOpened: now())
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        save()
        return entry
    }

    /// Turns a saved entry back into a URL. A stale bookmark is re-created from
    /// the URL it resolved to, which needs scoped access to that URL.
    func resolve(_ entry: ExternalFileEntry) -> ExternalFileResolveResult {
        guard let resolved = try? bookmarking.resolve(entry.bookmarkData) else { return .failed }
        if resolved.isStale {
            let access = ScopedFileAccess(url: resolved.url)
            defer { access.release() }
            if let fresh = try? bookmarking.makeBookmark(resolved.url),
               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].bookmarkData = fresh
                save()
            }
        }
        return .resolved(resolved.url)
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func sameFile(_ entry: ExternalFileEntry, as url: URL) -> Bool {
        guard let resolved = try? bookmarking.resolve(entry.bookmarkData) else { return false }
        return resolved.url.standardizedFileURL == url.standardizedFileURL
    }

    private static func load(from url: URL) -> [ExternalFileEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ExternalFileEntry].self, from: data) else { return [] }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = fileURL
        try? excluded.setResourceValues(values)
    }
}
