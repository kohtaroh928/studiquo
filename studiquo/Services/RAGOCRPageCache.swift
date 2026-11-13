import Foundation
import CryptoKit

/// Device-local cache of per-page text reading results so an interrupted registration resumes
/// instead of re-reading every page. The directory is keyed by account and by the notebook
/// fingerprint (which covers the page images and text), so a changed PDF never reuses old text.
/// It lives in Caches (not backed up, purgeable by the system), is never uploaded, and is removed
/// when registration completes, access is revoked, a PDF is excluded, or it has not been used for a week.
struct RAGOCRPageCache: Sendable {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RAGOCR", isDirectory: true)
    }
    private let ownerDirectory: URL
    private let directory: URL

    init(root: URL = RAGOCRPageCache.defaultRoot, owner: String, fingerprint: String) {
        ownerDirectory = Self.ownerDirectory(root: root, owner: owner)
        directory = ownerDirectory.appendingPathComponent(String(fingerprint.prefix(64)), isDirectory: true)
    }
    private static func ownerDirectory(root: URL, owner: String) -> URL {
        let name = SHA256.hash(data: Data(owner.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }
    private func file(_ offset: Int) -> URL { directory.appendingPathComponent("p\(offset).txt") }

    func read(_ offset: Int) -> String? {
        guard let data = try? Data(contentsOf: file(offset)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Best effort: a failed write only means the page is read again next time.
    func write(_ text: String, offset: Int) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try Data(text.utf8).write(to: file(offset), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {}
    }
    /// Removes this notebook's cache.
    func removeAll() { try? FileManager.default.removeItem(at: directory) }
    /// Removes caches that have not been touched for a long time (abandoned or edited PDFs). Other PDFs
    /// that are still being registered are never removed by age alone.
    func pruneStale(olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = Date()) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: ownerDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where item != directory {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: item) }
        }
    }
    static func removeAll(root: URL = RAGOCRPageCache.defaultRoot, owner: String) {
        try? FileManager.default.removeItem(at: ownerDirectory(root: root, owner: owner))
    }
}
