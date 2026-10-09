#if DEBUG
import CoreGraphics
import Foundation

/// Puts a known set of files into the shared inbox so UI tests can drive the
/// real "choose a destination → import → result" flow without the Files app.
///
/// Debug builds only, switched on by `--ui-test-seed-shared-inbox`. It leaves:
/// - one *held* leftover (`held-leftover.pdf`) — what an earlier failed import
///   or a cancelled picker leaves behind;
/// - one *new* share of four files: two good PDFs (`lecture-a`, `lecture-b`), a
///   file that is not a real PDF (`broken.pdf`) and a format the library cannot
///   import (`notes.xyz`).
enum SharedInboxUITestSeed {
    static let argument = "--ui-test-seed-shared-inbox"

    private static var didSeed = false

    /// Once per process. SwiftUI may build the test root's `init` several times;
    /// re-seeding would delete files the running screen already knows about.
    static func seed() {
        guard !didSeed, let inbox = SharedInbox.standard() else { return }
        didSeed = true
        try? FileManager.default.removeItem(at: inbox.root)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInboxUITestSeed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // Older share, set aside.
        inbox.enqueue(copying: [pdf("held-leftover.pdf", pages: 2, in: scratch)])
        if let batch = inbox.pendingBatches().first { inbox.hold(batch) }

        // The share that has just arrived.
        let brokenURL = scratch.appendingPathComponent("broken.pdf")
        try? Data("this is not a pdf".utf8).write(to: brokenURL)
        let unsupportedURL = scratch.appendingPathComponent("notes.xyz")
        try? Data("x".utf8).write(to: unsupportedURL)
        inbox.enqueue(copying: [
            pdf("lecture-a.pdf", pages: 3, in: scratch),
            pdf("lecture-b.pdf", pages: 2, in: scratch),
            brokenURL,
            unsupportedURL,
        ])
    }

    private static func pdf(_ name: String, pages: Int, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(red: 0.9, green: 0.95, blue: 1, alpha: 1))
            context.fill(box)
            context.endPage()
        }
        context.closePDF()
        return url
    }
}
#endif
