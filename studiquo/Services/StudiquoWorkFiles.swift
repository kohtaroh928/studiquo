import Foundation

/// Where the app puts files that only exist for a moment: a PDF being
/// unlocked, an export about to be shared, the MCP snapshot. They hold the same
/// study content as the notes themselves, in the clear, so they are kept in one
/// folder of their own that
///
/// - is protected: readable only while the iPad is unlocked
///   (`NSFileProtectionComplete`), which new files inside it inherit, and
/// - is emptied at every launch, so nothing is left behind for the system to
///   get round to (the temporary folder is not cleared when the app is closed).
///
/// Nothing may rely on a file here surviving: the system may remove temporary
/// files at any time already.
enum StudiquoWorkFiles {
    static let folderName = "StudiquoWork"

    static func directory(fileManager: FileManager = .default, base: URL? = nil) -> URL {
        let url = (base ?? fileManager.temporaryDirectory).appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        // A folder that already existed (from a build before this) gets the
        // protection too.
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

    /// A new folder for one piece of work, so file names inside it can stay
    /// exactly what the person will see when they share it.
    static func makeFolder(fileManager: FileManager = .default, base: URL? = nil) -> URL {
        let url = directory(fileManager: fileManager, base: base).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return url
    }

    /// A file directly in the work folder.
    static func file(named name: String, fileManager: FileManager = .default, base: URL? = nil) -> URL {
        directory(fileManager: fileManager, base: base).appendingPathComponent(name)
    }

    /// Removes everything left in the work folder. Called once at launch, before
    /// anything can be using it.
    static func sweep(fileManager: FileManager = .default, base: URL? = nil) {
        let url = (base ?? fileManager.temporaryDirectory).appendingPathComponent(folderName, isDirectory: true)
        for item in (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: item)
        }
    }
}
