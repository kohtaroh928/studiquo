import XCTest
import SwiftData
@testable import studiquo

/// Regression coverage for a real privacy bug: `saveAutomaticBackup(for:)`
/// used to write a locked notebook's ink, background images, and OCR text
/// to a plain-JSON file every time the app backgrounded or the editor
/// closed — silently defeating the Face ID lock, since nothing about the
/// automatic backup path checked `notebook.isLocked`. This is a first,
/// minimal fix (stop leaking further, and clean up what already leaked);
/// real encryption of a locked notebook's own SwiftData storage is tracked
/// separately.
@MainActor
final class NotebookBackupServiceLockTests: XCTestCase {
    private var storeURLs: [URL] = []

    /// Notebooks must actually be inserted into a `ModelContext` before
    /// `persistentModelID` is a stable, unique value — an un-inserted
    /// model's id isn't guaranteed distinct, which is exactly what made
    /// `testDeletingOneNotebooksBackupsDoesNotTouchAnothers` fail the first
    /// time this file was written (two un-inserted notebooks collided on
    /// the same backup-file prefix). Every real notebook in the app is
    /// inserted immediately after creation (see `ContentView.createBlankNotebook`),
    /// so this context mirrors that rather than working around it.
    private func makeNotebook(title: String, locked: Bool) -> Notebook {
        let schema = Schema([Notebook.self, NotePage.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotebookBackupServiceLockTests-\(UUID().uuidString).sqlite")
        storeURLs.append(url)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let notebook = Notebook(title: title)
        notebook.isLocked = locked
        let page = NotePage(order: 0, pageWidth: 612, pageHeight: 792)
        page.drawingData = "秘密の手書きデータ".data(using: .utf8)
        page.recognizedText = "秘密のノート内容"
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        try? context.save()
        return notebook
    }

    private func backupFiles(matching notebook: Notebook) throws -> [URL] {
        let manager = FileManager.default
        let root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("studiquo/AutoBackups", isDirectory: true)
        let identifier = String(describing: notebook.persistentModelID)
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        guard let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.lastPathComponent.hasPrefix(identifier + "-") }
    }

    override func tearDown() {
        // Automatic backups persist in the real Application Support
        // directory (these functions take no injectable location), so tests
        // clean up after themselves rather than leaving files for the next
        // run or the app itself to trip over.
        for notebook in createdNotebooks {
            for url in (try? backupFiles(matching: notebook)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        createdNotebooks = []
        for url in storeURLs { try? FileManager.default.removeItem(at: url) }
        storeURLs = []
        super.tearDown()
    }

    private var createdNotebooks: [Notebook] = []

    func testLockedNotebookNeverGetsAnAutomaticBackupWritten() throws {
        let notebook = makeNotebook(title: "ロックされたノート", locked: true)
        createdNotebooks.append(notebook)

        NotebookBackupService.saveAutomaticBackup(for: notebook)

        XCTAssertTrue(try backupFiles(matching: notebook).isEmpty, "ロックされたノートの自動バックアップが平文で書き出されてはいけません。")
    }

    func testUnlockedNotebookStillGetsAnAutomaticBackupWritten() throws {
        let notebook = makeNotebook(title: "通常のノート", locked: false)
        createdNotebooks.append(notebook)

        NotebookBackupService.saveAutomaticBackup(for: notebook)

        XCTAssertEqual(try backupFiles(matching: notebook).count, 1, "ロックされていないノートの自動バックアップは今まで通り作られる必要があります。")
    }

    /// The moment a notebook is locked (ContentView's 保護 toggle), any
    /// backups made while it was still unlocked must be removed — otherwise
    /// the lock's protection has a gap dated to before the toggle was
    /// flipped.
    func testLockingANotebookDeletesItsPreExistingAutomaticBackups() throws {
        let notebook = makeNotebook(title: "後でロックするノート", locked: false)
        createdNotebooks.append(notebook)
        NotebookBackupService.saveAutomaticBackup(for: notebook)
        XCTAssertEqual(try backupFiles(matching: notebook).count, 1)

        notebook.isLocked = true
        NotebookBackupService.deleteAutomaticBackups(for: notebook)

        XCTAssertTrue(try backupFiles(matching: notebook).isEmpty)
    }

    /// Deleting backups for one notebook must never touch another
    /// notebook's — they're distinguished only by a filename prefix built
    /// from `persistentModelID`, so a prefix-matching bug here would be easy
    /// to introduce silently.
    func testDeletingOneNotebooksBackupsDoesNotTouchAnothers() throws {
        let locked = makeNotebook(title: "ロックするノート", locked: false)
        let other = makeNotebook(title: "別のノート", locked: false)
        createdNotebooks.append(contentsOf: [locked, other])
        NotebookBackupService.saveAutomaticBackup(for: locked)
        NotebookBackupService.saveAutomaticBackup(for: other)

        NotebookBackupService.deleteAutomaticBackups(for: locked)

        XCTAssertTrue(try backupFiles(matching: locked).isEmpty)
        XCTAssertEqual(try backupFiles(matching: other).count, 1, "無関係なノートのバックアップまで消えてはいけません。")
    }
}
