import Foundation
import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class NotebookBackupPDFPageAndRetentionTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var temporaryFiles: [URL] = []
    private var createdNotebooks: [Notebook] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        for notebook in createdNotebooks {
            NotebookBackupService.deleteAutomaticBackups(for: notebook)
        }
        createdNotebooks = []
        super.tearDown()
    }

    private func autoBackupDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("studiquo/AutoBackups", isDirectory: true)
    }

    private func backupIdentifier(for notebook: Notebook) -> String {
        String(describing: notebook.persistentModelID)
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    // MARK: - 1. Round-trip export and restore of the one-page PDF (backgroundPDFData) across multi-page notebooks

    func testExportAndRestorePreservesPagePDFDataAcrossPages() throws {
        let notebook = Notebook(title: "PDFページバックアップ-\(UUID().uuidString)")
        let pagePDF = Data("%PDF-1.4 eigenvalue eigenvector".utf8)

        let pdfPage = NotePage(order: 0, backgroundImageData: Data([0x89, 0x50, 0x4E, 0x47]), pageWidth: 612, pageHeight: 792)
        pdfPage.backgroundPDFData = pagePDF
        pdfPage.recognizedText = "eigenvalue eigenvector"
        pdfPage.notebook = notebook
        notebook.addPage(pdfPage)

        let plainPage = NotePage(order: 1, backgroundImageData: nil, pageWidth: 612, pageHeight: 792)
        plainPage.drawingData = Data([0x01, 0x02, 0x03])
        plainPage.notebook = notebook
        notebook.addPage(plainPage)

        let exportedURL = try XCTUnwrap(NotebookBackupService.export(notebook))
        temporaryFiles.append(exportedURL)

        let restored = try XCTUnwrap(NotebookBackupService.restore(from: exportedURL))
        let restoredPages = restored.sortedPages
        XCTAssertEqual(restoredPages.count, 2)

        let restoredPDFPage = restoredPages[0]
        XCTAssertEqual(restoredPDFPage.backgroundPDFData, pagePDF)
        XCTAssertEqual(restoredPDFPage.recognizedText, "eigenvalue eigenvector")

        let restoredPlainPage = restoredPages[1]
        XCTAssertNil(restoredPlainPage.backgroundPDFData)
        XCTAssertEqual(restoredPlainPage.drawingData, Data([0x01, 0x02, 0x03]))
    }

    // MARK: - 2. Legacy backup archive without backgroundPDFData, paperColorHex, or lineWidth

    func testRestoreAcceptsLegacyBackupJSONMissingOptionalPageAndElementFields() throws {
        let legacyArchiveJSON = """
        {
          "title": "旧バックアップノート",
          "folderName": "物理",
          "tagsText": "力学",
          "pages": [
            {
              "width": 595,
              "height": 842,
              "template": "ruled",
              "bookmark": false,
              "title": "運動方程式",
              "recognizedText": "F = ma",
              "elements": [
                {
                  "kind": "ellipse",
                  "text": "",
                  "centerX": 0.5,
                  "centerY": 0.5,
                  "width": 0.3,
                  "height": 0.2,
                  "rotation": 0,
                  "colorHex": "#FF3B30",
                  "isLocked": false,
                  "layerIndex": 1
                }
              ]
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-backup-\(UUID().uuidString).gnbackup.json")
        temporaryFiles.append(url)
        try Data(legacyArchiveJSON.utf8).write(to: url)

        let restored = try XCTUnwrap(NotebookBackupService.restore(from: url))
        XCTAssertEqual(restored.title, "旧バックアップノート")
        let page = try XCTUnwrap(restored.sortedPages.first)
        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.paperColorHex, "#FFFFFF", "Missing paperColorHex in legacy archive must default to #FFFFFF")
        XCTAssertEqual(page.flashcardQuestion, "")
        XCTAssertEqual(page.flashcardAnswer, "")
        XCTAssertEqual(page.flashcardMastery, 0)
        XCTAssertEqual(page.flashcardReviewCount, 0)

        let element = try XCTUnwrap(page.allElements.first)
        XCTAssertEqual(element.kind, .ellipse)
        XCTAssertEqual(element.lineWidth, 3, "Missing lineWidth in legacy archive must default to 3")
    }

    // MARK: - 3. Automatic backup retention caps at 5 newest files per notebook

    func testAutomaticBackupRetentionPrunesOldestBackupsBeyondFive() throws {
        let schema = Schema([Notebook.self, NotePage.self, PageElement.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        Self.retainedContainers.append(container)
        let context = ModelContext(container)

        let notebook = Notebook(title: "世代管理テスト-\(UUID().uuidString)")
        let page = NotePage(order: 0)
        page.recognizedText = "自動バックアップ対象"
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        context.insert(page)
        try context.save()
        createdNotebooks.append(notebook)

        let root = try autoBackupDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let idPrefix = backupIdentifier(for: notebook)

        // Seed 6 historical backup files with distinct modification dates for this notebook:
        for index in 0..<6 {
            let fileURL = root.appendingPathComponent("\(idPrefix)-2026-10-0\(index + 1)T00-00-00Z.json")
            let archive = NotebookBackupService.Archive(
                title: "\(notebook.title)-\(index)",
                folderName: "",
                tagsText: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60)),
                pages: []
            )
            try JSONEncoder().encode(archive).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60))],
                ofItemAtPath: fileURL.path
            )
        }

        // Saving a new automatic backup (7th total) must prune the oldest 2 so only 5 remain:
        NotebookBackupService.saveAutomaticBackup(for: notebook)

        let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(idPrefix + "-") }
        XCTAssertEqual(remaining.count, 5, "saveAutomaticBackup must keep only the 5 most recent backups per notebook")

        let listed = NotebookBackupService.automaticBackups().filter { $0.title.hasPrefix("世代管理テスト-") }
        XCTAssertFalse(listed.isEmpty)
    }
}
