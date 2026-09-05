import Foundation

/// Copies a picked file into the app's own temp area so it outlives a
/// document picker's short-lived copy, and so later use doesn't depend on
/// security-scoped access that may already have been stopped.
enum PDFStableCopyService {
    /// Returns `nil` on failure rather than the original `url`: that URL's
    /// access may no longer be valid by the time a caller uses the result
    /// (e.g. after a security-scope `defer` has already run), so handing it
    /// back would only defer the failure to a later, more confusing point.
    static func copy(_ url: URL, fileManager: FileManager = .default) -> URL? {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = url.lastPathComponent.isEmpty
            ? UUID().uuidString + "." + (url.pathExtension.isEmpty ? "pdf" : url.pathExtension)
            : url.lastPathComponent
        let destination = folder.appendingPathComponent(filename)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: folder)
            return nil
        }
    }
}
