import XCTest
import PDFKit
@testable import studiquo

/// Coverage for `ExportService.pdfData(from: TextDocument)`'s header/footer
/// rendering. The band placement math here is easy to get backwards (header
/// and footer swapped, or the reserved space subtracted from the wrong edge)
/// without anything catching it, since a build error can't tell you two
/// bands are on the wrong side of the page — only actually rendering and
/// reading the PDF back can.
final class ExportServiceHeaderFooterTests: XCTestCase {
    private func makeDocument(bodyText: String = "本文") -> TextDocument {
        let document = TextDocument(title: "テスト")
        document.bodyData = DocumentBody.encode(NSAttributedString(string: bodyText, attributes: DocumentBody.defaultAttributes()))
        return document
    }

    func testDocumentWithNoHeaderOrFooterStillExports() {
        let document = makeDocument()
        let data = ExportService.pdfData(from: document)
        XCTAssertNotNil(data)
        XCTAssertEqual(PDFDocument(data: data!)?.pageCount, 1)
    }

    func testHeaderTextAppearsOnThePage() {
        let document = makeDocument()
        document.headerFooter(.header).text = "第一章 序論"

        let data = ExportService.pdfData(from: document)
        let page = PDFDocument(data: data!)?.page(at: 0)

        XCTAssertTrue(page?.string?.contains("第一章 序論") ?? false)
    }

    func testFooterTextAppearsOnThePage() {
        let document = makeDocument()
        document.headerFooter(.footer).text = "社外秘"

        let data = ExportService.pdfData(from: document)
        let page = PDFDocument(data: data!)?.page(at: 0)

        XCTAssertTrue(page?.string?.contains("社外秘") ?? false)
    }

    /// The regression this guards: an earlier version of this method placed
    /// the header text near the bottom of the page and the footer near the
    /// top — it "worked" in that both strings appeared somewhere on the
    /// page, so a text-containment check alone wouldn't have caught it. This
    /// compares each string's own vertical position instead.
    func testHeaderRendersAboveFooterOnThePage() {
        let document = makeDocument()
        document.headerFooter(.header).text = "ヘッダー文言"
        document.headerFooter(.footer).text = "フッター文言"

        let data = ExportService.pdfData(from: document)
        guard let page = PDFDocument(data: data!)?.page(at: 0) else {
            return XCTFail("no page rendered")
        }
        guard let headerSelection = page.selection(for: page.bounds(for: .mediaBox))?
            .selectionsByLine()
            .first(where: { $0.string?.contains("ヘッダー文言") == true }),
            let footerSelection = page.selection(for: page.bounds(for: .mediaBox))?
                .selectionsByLine()
                .first(where: { $0.string?.contains("フッター文言") == true })
        else {
            return XCTFail("header or footer text not found on the page")
        }

        // PDFKit's page space has its origin at the bottom-left, same as the
        // renderer's own coordinate system — so a larger minY is higher up
        // the page.
        let headerY = headerSelection.bounds(for: page).minY
        let footerY = footerSelection.bounds(for: page).minY
        XCTAssertGreaterThan(headerY, footerY, "the header must render above the footer, not below it")
    }

    func testPageNumberIsAppendedWhenEnabled() {
        let document = makeDocument()
        let footer = document.headerFooter(.footer)
        footer.text = "ページ"
        footer.showsPageNumber = true

        let data = ExportService.pdfData(from: document)
        let page = PDFDocument(data: data!)?.page(at: 0)

        XCTAssertTrue(page?.string?.contains("ページ") ?? false)
        XCTAssertTrue(page?.string?.contains("1") ?? false)
    }

    /// Multi-page pagination predates header/footer support — this just
    /// confirms that loop still terminates and produces multiple pages
    /// after the band-reservation change, for a document with neither.
    func testLongDocumentWithNoHeaderOrFooterStillPaginates() {
        let longText = String(repeating: "行\n", count: 400)
        let document = makeDocument(bodyText: longText)

        let data = ExportService.pdfData(from: document)
        let pageCount = PDFDocument(data: data!)?.pageCount ?? 0

        XCTAssertGreaterThan(pageCount, 1)
    }

    // MARK: columnCount

    func testSingleColumnIsTheDefaultAndMatchesPriorBehavior() {
        let document = makeDocument()
        XCTAssertEqual(document.columnCount, 1)
    }

    /// The behavior actually worth verifying for multi-column layout: two
    /// columns must fit strictly more text per page than one, which can
    /// only be true if the second column's rectangle is genuinely being
    /// rendered into — not just a cosmetic setting that's ignored.
    func testTwoColumnsFitMoreTextPerPageThanOneColumn() {
        let longText = String(repeating: "本文のテスト行です。\n", count: 150)

        let singleColumn = makeDocument(bodyText: longText)
        singleColumn.columnCount = 1
        let singleColumnPages = PDFDocument(data: ExportService.pdfData(from: singleColumn)!)?.pageCount ?? 0

        let twoColumn = makeDocument(bodyText: longText)
        twoColumn.columnCount = 2
        let twoColumnPages = PDFDocument(data: ExportService.pdfData(from: twoColumn)!)?.pageCount ?? 0

        XCTAssertGreaterThan(singleColumnPages, 1, "the fixture should already need more than one page at a single column")
        XCTAssertLessThan(twoColumnPages, singleColumnPages, "two columns should fit more text per page, needing fewer pages for the same content")
    }

    /// Values outside 1-3 must not crash or produce a degenerate (zero or
    /// negative width) column rect.
    func testOutOfRangeColumnCountIsClamped() {
        let document = makeDocument(bodyText: "本文")
        document.columnCount = 99

        let data = ExportService.pdfData(from: document)

        XCTAssertNotNil(data)
        XCTAssertEqual(PDFDocument(data: data!)?.pageCount, 1)
    }
}
