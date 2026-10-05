import Foundation
import UserNotifications

/// Erases app-managed copies, never the original files selected from Files.
enum AccountFileEraser {
    static func erase() throws {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.deletingLastPathComponent()
        // In tests/macOS, Foundation may point to the person's home folders.
        // Refuse those paths rather than risk deleting unrelated documents.
        guard root.path.contains("/Containers/Data/Application/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try eraseOwnedFiles(in: root, manager: manager)
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.appGroupIdentifier) {
            try eraseDirectory(group.appendingPathComponent("Inbox"), manager: manager)
        }
        URLCache.shared.removeAllCachedResponses()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        ClaudeChatService.removeAPIKey()
    }

    /// Explicit sandbox root lets tests exercise cleanup without using real
    /// app storage. The SwiftData store in Library/Application Support stays.
    static func eraseOwnedFiles(in sandbox: URL, manager: FileManager = .default) throws {
        let sandbox = sandbox.resolvingSymlinksInPath().standardizedFileURL
        let targets = ["Documents", "Library/Caches", "tmp"]
        for relativePath in targets {
            let directory = sandbox.appendingPathComponent(relativePath, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            // Do not follow a directory symlink into a different container.
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
                throw CocoaError(.fileWriteNoPermission)
            }
            for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: child)
            }
        }
        for path in ["Library/Application Support/studiquo/AutoBackups", "Library/Application Support/SharedInbox"] {
            try eraseDirectory(sandbox.appendingPathComponent(path), manager: manager)
        }
    }

    private static func eraseDirectory(_ directory: URL, manager: FileManager) throws {
        guard manager.fileExists(atPath: directory.path) else { return }
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try manager.removeItem(at: directory)
    }
}
