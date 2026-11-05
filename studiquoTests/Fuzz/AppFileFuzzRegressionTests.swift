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

    // MARK: DOCX

    private func docxWithTableRows(_ rows: Int) throws -> Data {
        let xml = "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:tbl>"
            + String(repeating: "<w:tr><w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr>", count: rows) + "</w:tbl></w:body></w:document>"
        return try DocxZip.write([.init(path: "word/document.xml", data: Data(xml.utf8))])
    }

    /// Building the rows linked each row to its table twice, and that grew with the square of the row
    /// count: 40,000 rows took 7 s, 10,000 took 0.7 s. The check is on the growth, not on a time.
    func testDocxTableRowsAreBuiltInLinearTime() throws {
        func seconds(_ rows: Int) throws -> Double {
            let data = try docxWithTableRows(rows)
            let began = Date()
            _ = try DocxReader.read(from: data)
            return Date().timeIntervalSince(began)
        }
        _ = try seconds(2_000) // warm up
        let small = try seconds(10_000), large = try seconds(40_000)
        XCTAssertLessThan(large / max(small, 0.001), 7, "4x the rows took \(large / max(small, 0.001))x the time (linear is about 4)")
    }

    func testDocxTableKeepsItsRowsAndTheirOrder() throws {
        let result = try DocxReader.read(from: docxWithTableRows(300))
        let table = try XCTUnwrap(result.blocks.first { $0.kind == .table })
        let rows = table.sortedTableRows
        XCTAssertEqual(rows.count, 300)
        XCTAssertTrue(rows.allSatisfy { $0.block === table })
        XCTAssertEqual(rows.map(\.order), Array(0..<300))
    }

    func testDocxWithAnOversizedBodyPartIsRefused() throws {
        let filler = String(repeating: "<w:p/>", count: ImportLimits.maxDocxDocumentXMLBytes / 6 + 1)
        let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(filler)</w:body></w:document>"
        let data = try DocxZip.write([.init(path: "word/document.xml", data: Data(xml.utf8))])
        XCTAssertThrowsError(try DocxReader.read(from: data)) { XCTAssertEqual($0 as? DocxReader.ReadError, .archiveTooLarge) }
    }

    // MARK: Text and math

    /// A few thousand nested braces used up the stack: the app crashed (SIGSEGV) instead of showing the text.
    func testMathExpressionParserSurvivesDeepNesting() {
        for opener in ["{", "\\frac{", "\\sqrt{", "{{"] {
            let expression = MathExpressionParser.parse(String(repeating: opener, count: 200_000) + "x")
            XCTAssertNotNil(expression)
        }
        XCTAssertEqual(MathExpressionParser.parse("x^{2}"), .sequence([.superscript(.text("x"), .sequence([.text("2")]))]))
    }

    /// Every backtick of an unclosed run re-counted the rest of the run: 47,000 of them took 35 seconds.
    func testLongUnclosedBacktickRunIsLinear() {
        let source = "a " + String(repeating: "`", count: 40_000) // not at the start of a line, so not a code fence
        let began = Date()
        let segments = MathSegmenter.segments(in: source)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        XCTAssertEqual(segments, [.text(source)])
    }

    func testBacktickCodeStillWorks() {
        XCTAssertEqual(MathSegmenter.segments(in: "a `b` c"), [.text("a "), .code("`b`"), .text(" c")])
        XCTAssertEqual(MathSegmenter.segments(in: "``a`b``"), [.code("``a`b``")])
        XCTAssertEqual(MathSegmenter.segments(in: "`open"), [.text("`open")])
    }

    /// Looking for the end of the paragraph at every dollar sign made a long paragraph of prices slow.
    func testManyDollarSignsInOneParagraphAreLinear() {
        let source = String(repeating: "$5 ", count: 30_000)
        let began = Date()
        _ = MathSegmenter.segments(in: source)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testInlineMathAndParagraphBreaksStillSegment() {
        XCTAssertEqual(MathSegmenter.segments(in: "x $a+b$ y"), [.text("x "), .inlineMath("a+b"), .text(" y")])
        // a blank line ends the paragraph, so a dollar in the next one does not close it
        let broken = MathSegmenter.segments(in: "$a^2\n\nb$")
        XCTAssertFalse(broken.contains(.inlineMath("a^2\n\nb")))
    }
}
