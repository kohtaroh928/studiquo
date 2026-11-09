import Foundation

/// What a device remembers about its last sync with a room: the room revision it
/// was in step with, and the snapshot of that moment (the common ancestor a merge
/// is made against). It is kept on this device only, deliberately outside the
/// SwiftData model: that model syncs through iCloud, and a base that arrives from
/// another of the person's devices does not describe *this* device's content, so a
/// merge against it could send someone else's edits back as if they were new.
protocol CollabStateStore: AnyObject {
    func revision(forKey key: String) -> Int
    func setRevision(_ revision: Int, forKey key: String)
    func base(forKey key: String) -> Data?
    func setBase(_ data: Data?, forKey key: String)
}

enum CollabLocalState {
    nonisolated(unsafe) static var store: CollabStateStore = FileCollabStateStore()
    /// How a document is named in the store. Tests replace it to tell apart two
    /// documents that stand for two devices.
    nonisolated(unsafe) static var keyProvider: (TextDocument) -> String? = { document in
        guard let room = document.collabRoomID else { return nil }
        return "\(room)|\(Int(document.createdAt.timeIntervalSinceReferenceDate * 1000))"
    }
}

extension TextDocument {
    /// The room revision this device last saw for this document (0 before the first sync).
    var collabRevision: Int {
        get { CollabLocalState.keyProvider(self).map { CollabLocalState.store.revision(forKey: $0) } ?? 0 }
        set { if let key = CollabLocalState.keyProvider(self) { CollabLocalState.store.setRevision(newValue, forKey: key) } }
    }

    var collabBaseSnapshot: Data? {
        get { CollabLocalState.keyProvider(self).flatMap { CollabLocalState.store.base(forKey: $0) } }
        set { if let key = CollabLocalState.keyProvider(self) { CollabLocalState.store.setBase(newValue, forKey: key) } }
    }
}

/// The real store: revisions in UserDefaults, base snapshots as files under
/// Application Support (they can be megabytes, and are excluded from backups).
final class FileCollabStateStore: CollabStateStore {
    private let defaults = UserDefaults.standard
    private func fileURL(_ key: String) -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let directory = support.appendingPathComponent("collab-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = key.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(name.prefix(120)) + ".json")
    }
    func revision(forKey key: String) -> Int { defaults.integer(forKey: "collab.revision.\(key)") }
    func setRevision(_ revision: Int, forKey key: String) { defaults.set(revision, forKey: "collab.revision.\(key)") }
    func base(forKey key: String) -> Data? { fileURL(key).flatMap { try? Data(contentsOf: $0) } }
    func setBase(_ data: Data?, forKey key: String) {
        guard var url = fileURL(key) else { return }
        if let data {
            try? data.write(to: url, options: .atomic)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// For tests.
final class InMemoryCollabStateStore: CollabStateStore {
    private var revisions: [String: Int] = [:]
    private var bases: [String: Data] = [:]
    func revision(forKey key: String) -> Int { revisions[key] ?? 0 }
    func setRevision(_ revision: Int, forKey key: String) { revisions[key] = revision }
    func base(forKey key: String) -> Data? { bases[key] }
    func setBase(_ data: Data?, forKey key: String) { bases[key] = data }
}
