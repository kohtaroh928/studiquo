import SwiftData
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class PageRotationServiceTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    private func makeSolidImageData(size: CGSize) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.92)!
    }

    func testRotateClockwiseSwapsDimensionsTransformsElementsStrokesAndImageAndSupportsUndoRedo() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let notebook = Notebook(title: "回転テスト")
        let page = NotePage(
            order: 0,
            backgroundImageData: makeSolidImageData(size: CGSize(width: 200, height: 400)),
            pageWidth: 600,
            pageHeight: 800
        )
        page.notebook = notebook
        notebook.addPage(page)

        let element = PageElement(
            kind: .text,
            text: "見出し",
            centerX: 0.25,
            centerY: 0.10,
            width: 0.40,
            height: 0.15,
            rotation: 30
        )
        element.page = page
        page.addElement(element)

        let stroke = InkStroke(
            points: [
                InkPoint(location: CGPoint(x: 100, y: 200), force: 0.5, timeOffset: 0),
                InkPoint(location: CGPoint(x: 300, y: 200), force: 0.5, timeOffset: 0.1),
            ],
            colorHex: "#000000",
            width: 3
        )
        page.drawingData = try InkDrawing(strokes: [stroke]).data()

        context.insert(notebook)
        context.insert(page)
        context.insert(element)

        PageRotationService.rotateClockwise(page)

        // 1. Page dimensions swap (600x800 -> 800x600).
        XCTAssertEqual(page.pageWidth, 800, accuracy: 0.001)
        XCTAssertEqual(page.pageHeight, 600, accuracy: 0.001)

        // 2. Element position & size rotate 90° clockwise: (x, y) -> (1 - y, x), (w, h) -> (h, w), rotation + 90.
        XCTAssertEqual(element.centerX, 0.90, accuracy: 0.0001)
        XCTAssertEqual(element.centerY, 0.25, accuracy: 0.0001)
        XCTAssertEqual(element.width, 0.15, accuracy: 0.0001)
        XCTAssertEqual(element.height, 0.40, accuracy: 0.0001)
        XCTAssertEqual(element.rotation, 120, accuracy: 0.0001)

        // 3. Ink stroke points transform by (x, y) -> (oldHeight - y, x) = (800 - 200, 100) = (600, 100).
        let rotatedDrawing = try XCTUnwrap(InkDrawing.load(from: try XCTUnwrap(page.drawingData)))
        let firstPoint = try XCTUnwrap(rotatedDrawing.strokes.first?.points.first?.location)
        XCTAssertEqual(firstPoint.x, 600, accuracy: 0.01)
        XCTAssertEqual(firstPoint.y, 100, accuracy: 0.01)

        // 4. Background image aspect ratio swaps from 1:2 (portrait) to 2:1 (landscape).
        let rotatedImage = try XCTUnwrap(UIImage(data: try XCTUnwrap(page.backgroundImageData)))
        XCTAssertEqual(rotatedImage.size.width / rotatedImage.size.height, 2.0, accuracy: 0.01)

        // 5. Undo restores original state.
        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(page.pageWidth, 600, accuracy: 0.001)
        XCTAssertEqual(page.pageHeight, 800, accuracy: 0.001)
        XCTAssertEqual(element.centerX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(element.centerY, 0.10, accuracy: 0.0001)
        XCTAssertEqual(element.width, 0.40, accuracy: 0.0001)
        XCTAssertEqual(element.height, 0.15, accuracy: 0.0001)
        XCTAssertEqual(element.rotation, 30, accuracy: 0.0001)
        let undoneDrawing = try XCTUnwrap(InkDrawing.load(from: try XCTUnwrap(page.drawingData)))
        let undonePoint = try XCTUnwrap(undoneDrawing.strokes.first?.points.first?.location)
        XCTAssertEqual(undonePoint.x, 100, accuracy: 0.01)
        XCTAssertEqual(undonePoint.y, 200, accuracy: 0.01)

        // 6. Redo reapplies rotation.
        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(page.pageWidth, 800, accuracy: 0.001)
        XCTAssertEqual(page.pageHeight, 600, accuracy: 0.001)
        XCTAssertEqual(element.centerX, 0.90, accuracy: 0.0001)
        XCTAssertEqual(element.centerY, 0.25, accuracy: 0.0001)

        // Pop the entry so shared history remains clean for subsequent tests.
        NoteActionHistory.shared.undo(requestID: UUID())
    }
}
