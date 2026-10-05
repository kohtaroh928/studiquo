import XCTest
@testable import studiquo

final class NotebookBackupServiceRoundTripTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        super.tearDown()
    }

    func testExportAndRestorePreservesNotebookPageAndElementContent() throws {
        let notebook = Notebook(title: "往復テスト-\(UUID().uuidString)")
        notebook.folderName = "授業/数学"
        notebook.tagsText = "重要, 試験"

        let page = NotePage(
            order: 3,
            backgroundImageData: Data([4, 5, 6]),
            pageWidth: 1024,
            pageHeight: 768
        )
        page.drawingData = Data([1, 2, 3])
        page.pageTemplate = .grid
        page.isBookmarked = true
        page.title = "第1問"
        page.paperColorHex = "#FFF4CC"
        page.recognizedText = "認識した本文"
        page.flashcardQuestion = "問題"
        page.flashcardAnswer = "答え"
        page.flashcardMastery = 2
        page.flashcardReviewCount = 7

        let element = PageElement(
            kind: .rectangle,
            text: "枠",
            imageData: Data([7, 8, 9]),
            centerX: 0.25,
            centerY: 0.75,
            width: 0.4,
            height: 0.2,
            rotation: 0.5,
            colorHex: "#123456",
            lineWidth: 8
        )
        element.isLocked = true
        element.layerIndex = 12
        element.page = page
        page.addElement(element)
        page.notebook = notebook
        notebook.addPage(page)

        let url = try XCTUnwrap(NotebookBackupService.export(notebook))
        temporaryFiles.append(url)
        let restored = try XCTUnwrap(NotebookBackupService.restore(from: url))

        XCTAssertEqual(restored.title, notebook.title)
        XCTAssertEqual(restored.folderName, "授業/数学")
        XCTAssertEqual(restored.tagsText, "重要, 試験")
        XCTAssertEqual(restored.pageCountForLibrary, 1)
        XCTAssertTrue(restored.containsPDF)

        let restoredPage = try XCTUnwrap(restored.sortedPages.first)
        XCTAssertEqual(restoredPage.order, 0)
        XCTAssertEqual(restoredPage.drawingData, Data([1, 2, 3]))
        XCTAssertEqual(restoredPage.backgroundImageData, Data([4, 5, 6]))
        XCTAssertEqual(restoredPage.pageWidth, 1024)
        XCTAssertEqual(restoredPage.pageHeight, 768)
        XCTAssertEqual(restoredPage.pageTemplate, .grid)
        XCTAssertTrue(restoredPage.isBookmarked)
        XCTAssertEqual(restoredPage.title, "第1問")
        XCTAssertEqual(restoredPage.paperColorHex, "#FFF4CC")
        XCTAssertEqual(restoredPage.recognizedText, "認識した本文")
        XCTAssertEqual(restoredPage.flashcardQuestion, "問題")
        XCTAssertEqual(restoredPage.flashcardAnswer, "答え")
        XCTAssertEqual(restoredPage.flashcardMastery, 2)
        XCTAssertEqual(restoredPage.flashcardReviewCount, 7)
        XCTAssertTrue(restoredPage.notebook === restored)

        let restoredElement = try XCTUnwrap(restoredPage.allElements.first)
        XCTAssertEqual(restoredElement.kind, .rectangle)
        XCTAssertEqual(restoredElement.text, "枠")
        XCTAssertEqual(restoredElement.imageData, Data([7, 8, 9]))
        XCTAssertEqual(restoredElement.centerX, 0.25)
        XCTAssertEqual(restoredElement.centerY, 0.75)
        XCTAssertEqual(restoredElement.width, 0.4)
        XCTAssertEqual(restoredElement.height, 0.2)
        XCTAssertEqual(restoredElement.rotation, 0.5)
        XCTAssertEqual(restoredElement.colorHex, "#123456")
        XCTAssertEqual(restoredElement.lineWidth, 8)
        XCTAssertTrue(restoredElement.isLocked)
        XCTAssertEqual(restoredElement.layerIndex, 12)
        XCTAssertTrue(restoredElement.page === restoredPage)
    }

    func testRestoreRejectsMalformedBackup() throws {
        let url = temporaryURL(name: "malformed")
        try Data("not-json".utf8).write(to: url)

        XCTAssertNil(NotebookBackupService.restore(from: url))
    }

    func testRestoreRejectsBackupWithNoPages() throws {
        let notebook = Notebook(title: "空のノート-\(UUID().uuidString)")
        let url = try XCTUnwrap(NotebookBackupService.export(notebook))
        temporaryFiles.append(url)

        XCTAssertNil(NotebookBackupService.restore(from: url))
    }

    func testRestoreSkipsElementWithUnknownKindInsteadOfRejectingNotebook() throws {
        let archive = NotebookBackupService.Archive(
            title: "将来形式",
            folderName: "",
            tagsText: "",
            createdAt: Date(),
            pages: [NotebookBackupService.PageArchive(
                drawingData: nil,
                backgroundImageData: nil,
                width: 612,
                height: 792,
                template: PageTemplate.blank.rawValue,
                bookmark: false,
                title: "",
                paperColorHex: nil,
                recognizedText: "",
                flashcardQuestion: nil,
                flashcardAnswer: nil,
                flashcardMastery: nil,
                flashcardReviewCount: nil,
                elements: [NotebookBackupService.ElementArchive(
                    kind: "future-element",
                    text: "",
                    imageData: nil,
                    centerX: 0.5,
                    centerY: 0.5,
                    width: 0.2,
                    height: 0.2,
                    rotation: 0,
                    colorHex: "#000000",
                    isLocked: false,
                    layerIndex: 0,
                    lineWidth: nil
                )]
            )]
        )
        let url = temporaryURL(name: "unknown-element")
        try JSONEncoder().encode(archive).write(to: url)

        let restored = try XCTUnwrap(NotebookBackupService.restore(from: url))

        XCTAssertEqual(restored.sortedPages.count, 1)
        XCTAssertTrue(try XCTUnwrap(restored.sortedPages.first).allElements.isEmpty)
    }

    private func temporaryURL(name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookBackupServiceRoundTripTests-\(name)-\(UUID().uuidString).json")
        temporaryFiles.append(url)
        return url
    }
}
