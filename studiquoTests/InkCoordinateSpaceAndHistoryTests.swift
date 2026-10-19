import CoreGraphics
import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class InkCoordinateSpaceAndHistoryTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    private func sampleDrawing(at point: CGPoint, width: CGFloat = 4) -> InkDrawing {
        InkDrawing(strokes: [
            InkStroke(
                points: [
                    InkPoint(location: point, force: 0.6, timeOffset: 0),
                    InkPoint(location: CGPoint(x: point.x + 40, y: point.y + 20), force: 0.8, timeOffset: 0.1),
                ],
                colorHex: "#1C1C1E",
                width: width
            )
        ])
    }

    // MARK: - Ink coordinate space scaling (`inkReferenceWidth` & `InkDrawing.scaled(by:)`)

    func testInkDrawingScaledUniformlyScalesBothPointsAndStrokeWidthsAcrossSplitWidths() {
        // Suppose a legacy page was drawn at a 1024pt canvas width and is now
        // normalized to a 612pt PDF/page width (factor = 612 / 1024 = 0.59765625).
        let sourceWidth: CGFloat = 1024
        let targetPageWidth: CGFloat = 612
        let factor = targetPageWidth / sourceWidth

        let original = sampleDrawing(at: CGPoint(x: 512, y: 256), width: 8)
        let scaled = original.scaled(by: factor)

        let stroke = scaled.strokes[0]
        XCTAssertEqual(stroke.width, 8 * factor, accuracy: 0.0001, "Stroke width must scale with the coordinate space so lines do not turn into hairlines or thick bars")
        XCTAssertEqual(stroke.points[0].location.x, 512 * factor, accuracy: 0.0001, "Midpoint on a 1024pt canvas must stay at the midpoint (306pt) of a 612pt page")
        XCTAssertEqual(stroke.points[0].location.y, 256 * factor, accuracy: 0.0001)
        XCTAssertEqual(stroke.points[0].force, 0.6, accuracy: 0.0001, "Pressure force must remain unchanged")
    }

    func testInkDrawingScaledReturnsUnchangedDrawingForUnityOrNonPositiveFactors() {
        let original = sampleDrawing(at: CGPoint(x: 100, y: 200), width: 5)
        XCTAssertEqual(original.scaled(by: 1.0), original)
        XCTAssertEqual(original.scaled(by: 1.00005), original)
        XCTAssertEqual(original.scaled(by: 0), original)
        XCTAssertEqual(original.scaled(by: -2), original)
    }

    func testNotePageSnapshotPreservesAndRestoresInkReferenceWidthOnLegacyAndNormalizedPages() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "座標系テスト")
        let page = NotePage(order: 0, pageWidth: 612, pageHeight: 792)
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        context.insert(page)

        // Legacy page starts at 0.
        XCTAssertEqual(page.inkReferenceWidth, 0)
        let legacySnapshot = NotePageSnapshot(page)
        XCTAssertEqual(legacySnapshot.inkReferenceWidth, 0)

        // After normalization, inkReferenceWidth settles at pageWidth (612).
        page.inkReferenceWidth = page.pageWidth
        let normalizedSnapshot = NotePageSnapshot(page)
        XCTAssertEqual(normalizedSnapshot.inkReferenceWidth, 612, accuracy: 0.001)

        let restoredFromLegacy = legacySnapshot.makePage(in: context, notebook: notebook)
        XCTAssertEqual(restoredFromLegacy.inkReferenceWidth, 0)

        let restoredFromNormalized = normalizedSnapshot.makePage(in: context, notebook: notebook)
        XCTAssertEqual(restoredFromNormalized.inkReferenceWidth, 612, accuracy: 0.001)
    }

    // MARK: - DrawingHistoryStore per-page undo/redo, split-pane deduplication, and LRU limits

    func testDrawingHistoryStoreSupportsPerPageUndoRedoAndDeduplicatesSplitPaneRequestIDs() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let page = NotePage(order: 0)
        context.insert(page)
        try context.save()
        let pid = page.persistentModelID

        let d0 = InkDrawing()
        let d1 = sampleDrawing(at: CGPoint(x: 10, y: 10))
        let d2 = sampleDrawing(at: CGPoint(x: 50, y: 50))

        DrawingHistoryStore.shared.recordChange(from: d0, for: pid)
        DrawingHistoryStore.shared.recordChange(from: d1, for: pid)
        XCTAssertNotNil(DrawingHistoryStore.shared.lastUndoDate(for: pid))
        XCTAssertNil(DrawingHistoryStore.shared.lastRedoDate(for: pid))

        // When the same page is open in two split panes, both canvases receive the same requestID.
        // The first canvas pops d1; the second canvas with the same requestID must get nil.
        let undoRequest = UUID()
        let firstUndo = DrawingHistoryStore.shared.popUndo(requestID: undoRequest, page: pid, current: d2)
        let duplicateUndo = DrawingHistoryStore.shared.popUndo(requestID: undoRequest, page: pid, current: d1)
        XCTAssertEqual(firstUndo, d1)
        XCTAssertNil(duplicateUndo, "Second pane handling the same requestID must not pop a second step")
        XCTAssertNotNil(DrawingHistoryStore.shared.lastRedoDate(for: pid))

        // Redo also deduplicates by requestID.
        let redoRequest = UUID()
        let firstRedo = DrawingHistoryStore.shared.popRedo(requestID: redoRequest, page: pid, current: d1)
        let duplicateRedo = DrawingHistoryStore.shared.popRedo(requestID: redoRequest, page: pid, current: d2)
        XCTAssertEqual(firstRedo, d2)
        XCTAssertNil(duplicateRedo)

        // Recording a new stroke clears the redo stack.
        _ = DrawingHistoryStore.shared.popUndo(requestID: UUID(), page: pid, current: d2)
        XCTAssertNotNil(DrawingHistoryStore.shared.lastRedoDate(for: pid))
        DrawingHistoryStore.shared.recordChange(from: d1, for: pid)
        XCTAssertNil(DrawingHistoryStore.shared.lastRedoDate(for: pid))
    }

    func testDrawingHistoryStoreEvictsLeastRecentlyTouchedPageBeyondTwelvePages() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var pages: [NotePage] = []
        for index in 0..<13 {
            let page = NotePage(order: index)
            context.insert(page)
            pages.append(page)
        }
        try context.save()

        for (index, page) in pages.enumerated() {
            DrawingHistoryStore.shared.recordChange(
                from: sampleDrawing(at: CGPoint(x: CGFloat(index), y: 0)),
                for: page.persistentModelID
            )
        }

        // The 1st page (index 0) was touched 13 pages ago (> pageLimit = 12) and must be evicted.
        XCTAssertNil(DrawingHistoryStore.shared.lastUndoDate(for: pages[0].persistentModelID))
        // The 13th page (index 12) is still retained.
        XCTAssertNotNil(DrawingHistoryStore.shared.lastUndoDate(for: pages[12].persistentModelID))
    }
}
