import Foundation

/// Files handed to studiquo from outside — the Files app's share sheet, or
/// "Open in…" — wait here until the student has picked where they should go.
///
/// Layout is `<root>/<batch UUID>/<original file name>`: everything that
/// arrived in one share lives in one folder, so two files that happen to share
/// a name never overwrite each other.
///
/// This file is compiled into both the app and the share extension, so it must
/// stay free of SwiftData/SwiftUI. The extension only ever *copies files in*;
/// converting them (PDF page rendering is far above an extension's memory
/// limit) is the app's job.
struct SharedInbox {
    static let appGroupIdentifier = "group.com.yabuko.studiquo"

    struct Item: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var displayName: String { url.lastPathComponent }
    }

    struct EnqueueResult {
        var items: [Item]
        /// Sources that could not be copied (a folder, an unreadable file).
        var failed: [URL]
    }

    /// What `ContentView.importFile(from:)` knows how to turn into library
    /// items. Anything else would be silently dropped there, so the batch
    /// import checks this first and tells the student what it skipped.
    static let importableExtensions: Set<String> = [
        "pdf", "docx", "pptx", "txt", "tsv", "csv", "json",
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp"
    ]

    static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }

    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// Only the App Group container — what the share extension must use. A
    /// fallback folder inside the extension's own sandbox would be invisible
    /// to the app, so a missing group has to be an error there, not a silent
    /// success.
    static func sharedGroup(fileManager: FileManager = .default) -> SharedInbox? {
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        return SharedInbox(root: group.appendingPathComponent("Inbox", isDirectory: true), fileManager: fileManager)
    }

    /// The App Group container when this build carries the entitlement, so the
    /// share extension and the app see the same folder. Without it (before the
    /// extension ships, or in a build lacking the capability) it falls back to
    /// the app's own Application Support, which is enough for "Open in…".
    static func standard(fileManager: FileManager = .default) -> SharedInbox? {
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return SharedInbox(root: group.appendingPathComponent("Inbox", isDirectory: true), fileManager: fileManager)
        }
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return SharedInbox(root: support.appendingPathComponent("SharedInbox", isDirectory: true), fileManager: fileManager)
    }

    /// One share's worth of files. The share extension fills a batch as each
    /// attachment finishes loading, then the app imports it as a unit.
    struct Batch {
        let folder: URL
    }

    func makeBatch() -> Batch? {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return Batch(folder: folder)
    }

    /// Copies one file into `batch`; nil if it is a folder or cannot be read.
    func add(_ source: URL, to batch: Batch) -> Item? {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let destination = uniqueDestination(for: source.lastPathComponent, in: batch.folder)
        do {
            try fileManager.copyItem(at: source, to: destination)
            return Item(url: destination)
        } catch {
            return nil
        }
    }

    /// Drops a batch that ended up with nothing in it.
    func discardIfEmpty(_ batch: Batch) {
        let remaining = (try? fileManager.contentsOfDirectory(atPath: batch.folder.path)) ?? []
        if remaining.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fileManager.removeItem(at: batch.folder)
        }
    }

    /// Copies `sources` into a fresh batch folder. A source that cannot be
    /// copied is reported in `failed` rather than aborting the rest — one bad
    /// file out of 28 should not lose the other 27.
    @discardableResult
    func enqueue(copying sources: [URL]) -> EnqueueResult {
        guard let batch = makeBatch() else { return EnqueueResult(items: [], failed: sources) }
        var result = EnqueueResult(items: [], failed: [])
        for source in sources {
            if let item = add(source, to: batch) {
                result.items.append(item)
            } else {
                result.failed.append(source)
            }
        }
        discardIfEmpty(batch)
        return result
    }

    /// Everything still waiting, oldest share first, each batch in name order.
    func pendingItems() -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let batches = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let orderedBatches = batches
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l < r
            }
        return orderedBatches.flatMap { batch -> [Item] in
            let files = (try? fileManager.contentsOfDirectory(
                at: batch, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            return files
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(Item.init)
        }
    }

    /// Deletes an imported (or abandoned) item, and its batch folder once the
    /// last file in it is gone.
    func remove(_ item: Item) {
        try? fileManager.removeItem(at: item.url)
        let batch = item.url.deletingLastPathComponent()
        guard batch.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: batch.path)) ?? []
        if remaining.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fileManager.removeItem(at: batch)
        }
    }

    /// "name.pdf", then "name 2.pdf", "name 3.pdf"… inside one batch.
    private func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }
}
