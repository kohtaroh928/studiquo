import XCTest
@testable import studiquo

/// Inputs the fuzzer found, kept as small fixed cases (seed 20261105).
final class AppFileFuzzRegressionTests: XCTestCase {
    /// 66 nested `\begin{align}` with fractions never finished: every level rendered its body twice.
    func testNestedAlignEnvironmentsFinishQuickly() {
        let source = String(repeating: "\\begin{align}\\frac{", count: 66) + "x"
        let began = Date()
        _ = MathTextFormatter.readableText(from: "$$" + source + "$$")
        _ = MathTextFormatter.plainText(from: "$$" + source + "$$")
        _ = MathTextFormatter.readableMath(from: source)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testNestedCasesEnvironmentsFinishQuickly() {
        let source = String(repeating: "\\begin{cases}", count: 66) + "x"
        let began = Date()
        _ = MathTextFormatter.readableMath(from: source)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testAlignStillFormatsRows() {
        XCTAssertEqual(MathTextFormatter.readableMath(from: "\\begin{aligned}a&=1\\\\b&=2\\end{aligned}").contains("\n"), true)
    }

    /// Restoring links each page to its notebook in time that grows with the square of the page count.
    func testBackupWithTooManyPagesIsRefusedBeforeBuildingAnything() throws {
        let page = NotebookBackupService.PageArchive(
            drawingData: nil, backgroundImageData: nil, width: 1, height: 1, template: "blank", bookmark: false, title: "", paperColorHex: nil,
            recognizedText: "", backgroundPDFData: nil, flashcardQuestion: nil, flashcardAnswer: nil, flashcardMastery: nil, flashcardReviewCount: nil, elements: [])
        let archive = NotebookBackupService.Archive(title: "t", folderName: "", tagsText: "", createdAt: nil,
                                                    pages: Array(repeating: page, count: ImportLimits.maxBackupPages + 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("too-many-pages-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(archive).write(to: url)
        let began = Date()
        XCTAssertNil(NotebookBackupService.restore(from: url))
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testBackupAtThePageLimitIsStillRestored() throws {
        let page = NotebookBackupService.PageArchive(
            drawingData: nil, backgroundImageData: nil, width: 1, height: 1, template: "blank", bookmark: false, title: "", paperColorHex: nil,
            recognizedText: "", backgroundPDFData: nil, flashcardQuestion: nil, flashcardAnswer: nil, flashcardMastery: nil, flashcardReviewCount: nil, elements: [])
        let archive = NotebookBackupService.Archive(title: "t", folderName: "", tagsText: "", createdAt: nil, pages: Array(repeating: page, count: 50))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ok-pages-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(archive).write(to: url)
        XCTAssertEqual(NotebookBackupService.restore(from: url)?.sortedPages.count, 50)
    }
}
