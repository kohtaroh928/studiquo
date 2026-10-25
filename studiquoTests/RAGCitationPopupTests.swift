import XCTest
import PDFKit
import SwiftData
import SwiftUI
import UIKit
@testable import studiquo

@MainActor
final class RAGCitationPopupTests: XCTestCase {

    func testEmptyPageListReturnsNilPDFData() {
        XCTAssertNil(ExportService.pdfData(pages: []))
    }

    func testSinglePagePDFContainsOnlyTargetPageContentAndBounds() throws {
        let notebook = Notebook(title: "Synthetic Textbook")
        let page1 = NotePage(order: 0, pageWidth: 612, pageHeight: 792)
        page1.addElement(PageElement(kind: .text, text: "MarkerAlpha", centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.15))

        let page2 = NotePage(order: 1, pageWidth: 720, pageHeight: 960)
        page2.addElement(PageElement(kind: .text, text: "MarkerBeta", centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.15))

        let page3 = NotePage(order: 2, pageWidth: 612, pageHeight: 792)
        page3.addElement(PageElement(kind: .text, text: "MarkerGamma", centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.15))

        notebook.addPage(page1)
        notebook.addPage(page2)
        notebook.addPage(page3)

        let citation = RAGCitation(sourceId: notebook.ragID, title: notebook.title, pageNumber: 2, chunkId: "chunk-page-2")
        let resolved = try XCTUnwrap(RAGCitationNavigation.resolve(citation, notebooks: [notebook]))
        XCTAssertTrue(resolved.0 === notebook)
        XCTAssertEqual(resolved.1, 1)

        let data = try XCTUnwrap(ExportService.pdfData(pages: [resolved.0.sortedPages[resolved.1]]))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)

        let renderedPage = try XCTUnwrap(pdf.page(at: 0))
        let bounds = renderedPage.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 720, accuracy: 0.5)
        XCTAssertEqual(bounds.height, 960, accuracy: 0.5)

        let extractedText = renderedPage.string ?? ""
        XCTAssertTrue(extractedText.contains("MarkerBeta"))
        XCTAssertFalse(extractedText.contains("MarkerAlpha"))
        XCTAssertFalse(extractedText.contains("MarkerGamma"))
    }

    /// Regression test: previewing a cited page in the popup must not save back
    /// to the page or mutate the notebook's RAG fingerprint / sourceHash.
    func testSinglePagePDFRenderingDoesNotMutateNotebookOrFingerprint() throws {
        let notebook = Notebook(title: "Synthetic Immutable Source")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let imageData = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }

        let page1 = NotePage(order: 0, backgroundImageData: imageData, pageWidth: 612, pageHeight: 792)
        page1.recognizedText = "Page 1 OCR text"
        let stroke = InkStroke(
            points: [
                InkPoint(location: CGPoint(x: 20, y: 30), force: 0.5, timeOffset: 0),
                InkPoint(location: CGPoint(x: 120, y: 130), force: 0.5, timeOffset: 0.1),
            ],
            colorHex: "#112233",
            width: 3
        )
        page1.drawingData = try InkDrawing(strokes: [stroke]).data()
        page1.addElement(PageElement(kind: .text, text: "Annotation text", centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.1))

        let page2 = NotePage(order: 1, backgroundImageData: imageData, pageWidth: 612, pageHeight: 792)
        page2.recognizedText = "Page 2 OCR text"

        notebook.addPage(page1)
        notebook.addPage(page2)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        notebook.updatedAt = fixedDate

        let fingerprintBefore = RAGLibrarySyncService.fingerprint(notebook)
        let sourceHashBefore = try RAGIndexingService.sourceHash([
            .init(pageNumber: 1, text: page1.recognizedText),
            .init(pageNumber: 2, text: page2.recognizedText)
        ])
        let drawingBefore = page1.drawingData
        let elementsCountBefore = page1.allElements.count

        let citation = RAGCitation(sourceId: notebook.ragID, title: notebook.title, pageNumber: 1, chunkId: "chunk-1")
        for _ in 0..<2 {
            let (resolvedNotebook, index) = try XCTUnwrap(RAGCitationNavigation.resolve(citation, notebooks: [notebook]))
            let data = try XCTUnwrap(ExportService.pdfData(pages: [resolvedNotebook.sortedPages[index]]))
            XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
        }

        XCTAssertEqual(notebook.updatedAt, fixedDate)
        XCTAssertEqual(RAGLibrarySyncService.fingerprint(notebook), fingerprintBefore)
        let sourceHashAfter = try RAGIndexingService.sourceHash([
            .init(pageNumber: 1, text: page1.recognizedText),
            .init(pageNumber: 2, text: page2.recognizedText)
        ])
        XCTAssertEqual(sourceHashAfter, sourceHashBefore)
        XCTAssertEqual(page1.drawingData, drawingBefore)
        XCTAssertEqual(page1.allElements.count, elementsCountBefore)
    }

    func testCitationResolutionRejectsUnavailableTrashedLockedOrOutOfBoundsPages() {
        let notebook = Notebook(title: "Synthetic Source")
        for index in 0..<3 {
            notebook.addPage(NotePage(order: index))
        }

        // Unknown / deleted source ID
        let unknownSource = RAGCitation(sourceId: "deleted-source-id", title: notebook.title, pageNumber: 1, chunkId: "c1")
        XCTAssertNil(RAGCitationNavigation.resolve(unknownSource, notebooks: [notebook]))

        // Out-of-bounds page numbers (0, negative, > pageCount)
        for invalidPage in [0, -1, 4, 99] {
            let outOfBounds = RAGCitation(sourceId: notebook.ragID, title: notebook.title, pageNumber: invalidPage, chunkId: "c-\(invalidPage)")
            XCTAssertNil(RAGCitationNavigation.resolve(outOfBounds, notebooks: [notebook]))
        }

        let validCitation = RAGCitation(sourceId: notebook.ragID, title: notebook.title, pageNumber: 2, chunkId: "c2")
        XCTAssertEqual(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook])?.1, 1)

        // Trashed notebook
        notebook.isTrashed = true
        XCTAssertNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))
        notebook.isTrashed = false
        XCTAssertNotNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))

        // Locked notebook
        notebook.isLocked = true
        XCTAssertNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))
        notebook.isLocked = false
        XCTAssertNotNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))

        // Password-protected PDF data present
        notebook.lockedPDFData = Data([0x25, 0x50, 0x44, 0x46])
        XCTAssertNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))
        notebook.lockedPDFData = nil
        XCTAssertNotNil(RAGCitationNavigation.resolve(validCitation, notebooks: [notebook]))
    }

    func testRAGCitationLinksRendersViewHierarchyForEmptyAndPopulatedCitations() throws {
        let container = try ModelContainer(
            for: Notebook.self, NotePage.self, PageElement.self, Folder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = container.mainContext
        let notebook = Notebook(title: "Synthetic Biology")
        notebook.addPage(NotePage(order: 0))
        context.insert(notebook)
        try context.save()

        let emptyHost = UIHostingController(
            rootView: RAGCitationLinks(citations: []).modelContainer(container)
        )
        emptyHost.loadViewIfNeeded()
        XCTAssertNotNil(emptyHost.view)

        let populatedCitations = [
            RAGCitation(sourceId: notebook.ragID, title: notebook.title, pageNumber: 1, chunkId: "chunk-a"),
            RAGCitation(sourceId: "missing-source", title: "Removed PDF", pageNumber: 5, chunkId: "chunk-b")
        ]
        let populatedHost = UIHostingController(
            rootView: RAGCitationLinks(citations: populatedCitations).modelContainer(container)
        )
        populatedHost.loadViewIfNeeded()
        populatedHost.view.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
        populatedHost.view.layoutIfNeeded()
        XCTAssertNotNil(populatedHost.view)
    }
}
