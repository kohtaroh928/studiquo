import SwiftData
import UIKit
import XCTest
@testable import studiquo

/// PDFのアイコンに使う「1ページ目の画像」の選び方。
@MainActor
final class NotebookCoverTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    private func png(_ color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// A notebook with one page per entry of `orders`, each with its own image.
    private func notebook(
        _ title: String, pageOrders orders: [Int], images: [Data?]? = nil, in context: ModelContext
    ) -> Notebook {
        let notebook = Notebook(title: title)
        for (index, order) in orders.enumerated() {
            let page = NotePage(order: order, backgroundImageData: images?[index])
            page.notebook = notebook
            notebook.addPage(page)
        }
        notebook.refreshLibraryMetadata()
        context.insert(notebook)
        return notebook
    }

    func testFirstPageIsTheLowestOrderNotTheFirstStored() {
        let late = NotePage(order: 7)
        let early = NotePage(order: 2)
        let middle = NotePage(order: 4)
        XCTAssertTrue(NotebookCover.firstPage(of: [late, early, middle]) === early)
        XCTAssertNil(NotebookCover.firstPage(of: []))
    }

    func testCoverIsTheFirstPagesImageEvenWhenPagesAreStoredOutOfOrder() throws {
        let context = try makeContext()
        let red = png(.red), blue = png(.blue)
        // Stored second page first, and orders that start above 0.
        let pdf = notebook("PDF", pageOrders: [5, 3], images: [blue, red], in: context)
        XCTAssertEqual(NotebookCover.imageData(of: pdf, in: context), red)
    }

    func testPlainNoteHasNoCover() throws {
        let context = try makeContext()
        let note = notebook("ノート", pageOrders: [0], in: context)
        XCTAssertFalse(NotebookCover.isEligible(note))
        XCTAssertNil(NotebookCover.imageData(of: note, in: context))
    }

    func testProtectedPDFNeverExposesItsFirstPage() throws {
        let context = try makeContext()
        let pdf = notebook("保護PDF", pageOrders: [0], images: [png(.red)], in: context)
        XCTAssertTrue(NotebookCover.isEligible(pdf))
        pdf.isLocked = true
        XCTAssertFalse(NotebookCover.isEligible(pdf))
        XCTAssertNil(NotebookCover.imageData(of: pdf, in: context))
    }

    func testCoverDoesNotMixUpTwoNotebooks() throws {
        let context = try makeContext()
        let red = png(.red), blue = png(.blue)
        let first = notebook("A", pageOrders: [0], images: [red], in: context)
        let second = notebook("B", pageOrders: [0], images: [blue], in: context)
        XCTAssertEqual(NotebookCover.imageData(of: first, in: context), red)
        XCTAssertEqual(NotebookCover.imageData(of: second, in: context), blue)
    }

    func testCacheKeyChangesWhenTheFirstPageIsReplacedOrTheNotebookDiffers() throws {
        let context = try makeContext()
        let red = png(.red), blue = png(.blue)
        let first = notebook("A", pageOrders: [0], images: [red], in: context)
        let second = notebook("B", pageOrders: [0], images: [red], in: context)
        XCTAssertEqual(NotebookCover.cacheKey(for: first, data: red), NotebookCover.cacheKey(for: first, data: red))
        XCTAssertNotEqual(NotebookCover.cacheKey(for: first, data: red), NotebookCover.cacheKey(for: first, data: blue))
        XCTAssertNotEqual(NotebookCover.cacheKey(for: first, data: red), NotebookCover.cacheKey(for: second, data: red))
    }

    func testCoverIsDecodedAsASmallImage() throws {
        let context = try makeContext()
        let pdf = notebook("PDF", pageOrders: [0], images: [png(.red)], in: context)
        let data = try XCTUnwrap(NotebookCover.imageData(of: pdf, in: context))
        let image = try XCTUnwrap(NoteImagePipeline.downsampledImage(from: data, maximumPixelSize: NotebookCover.pixelSize))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(NotebookCover.pixelSize))
    }
}
