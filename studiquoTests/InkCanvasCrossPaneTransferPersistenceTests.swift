import XCTest
@testable import studiquo

/// Regression coverage for "moving a lasso selection across the split-pane
/// boundary should actually persist on both sides".
///
/// The transfer produces two different `InkDrawing` shapes — strokes removed
/// on the source page (`endLasso`'s `drawing.strokes.removeAll { ... }`) and
/// newly repositioned strokes with fresh ids appended on the destination
/// page (`receiveInkSelectionTransfer`'s `transferred` strokes). Both need to
/// round-trip losslessly through the exact codec `page.drawingData` is saved
/// and reloaded with (`InkDrawing.data()` / `InkDrawing(data:)`, plain JSON)
/// — that round trip is what actually determines whether the move survives
/// quitting and relaunching the app, independent of when SwiftData chooses
/// to flush it to disk.
final class InkCanvasCrossPaneTransferPersistenceTests: XCTestCase {
    private func samplePoints() -> [InkPoint] {
        [
            InkPoint(location: CGPoint(x: 0, y: 0), force: 0.5, timeOffset: 0),
            InkPoint(location: CGPoint(x: 10, y: 10), force: 0.6, timeOffset: 0.1),
        ]
    }

    /// Mirrors the source page's state right after a successful cross-pane
    /// move: the moved stroke is gone, everything else is untouched.
    func testSourcePageDrawingAfterRemovingMovedStrokeRoundTrips() throws {
        let kept = InkStroke(points: samplePoints(), colorHex: "#000000", width: 4)
        let moved = InkStroke(points: samplePoints(), colorHex: "#FF0000", width: 6)
        var drawing = InkDrawing(strokes: [kept, moved])

        drawing.strokes.removeAll { $0.id == moved.id }

        let reloaded = try InkDrawing(data: drawing.data())

        XCTAssertEqual(
            reloaded, drawing,
            "移動元ページから移動した分のストロークを取り除いた後の状態が、保存・再読み込みを経ても完全に一致する必要があります。"
        )
        XCTAssertEqual(
            reloaded.strokes.map(\.id), [kept.id],
            "残っているはずのストロークだけが復元される必要があります。"
        )
    }

    /// Mirrors the destination page's state right after receiving a
    /// transfer: the existing ink is untouched, and the arriving stroke
    /// carries a fresh id, a rescaled width, and repositioned points.
    func testDestinationPageDrawingAfterReceivingTransferredStrokeRoundTrips() throws {
        let existing = InkStroke(points: samplePoints(), colorHex: "#000000", width: 4)
        let original = InkStroke(points: samplePoints(), colorHex: "#FF0000", width: 6)

        var transferredCopy = original
        transferredCopy.id = UUID()
        transferredCopy.width *= 1.5
        transferredCopy.points = original.points.map {
            var moved = $0
            moved.location = CGPoint(x: $0.location.x + 100, y: $0.location.y + 50)
            return moved
        }

        var drawing = InkDrawing(strokes: [existing])
        drawing.strokes.append(transferredCopy)

        let reloaded = try InkDrawing(data: drawing.data())

        XCTAssertEqual(
            reloaded, drawing,
            "受け取った側のページの状態が、保存・再読み込みを経ても完全に一致する必要があります。"
        )
        XCTAssertEqual(
            reloaded.strokes.count, 2,
            "既存のストロークと、新しく受け取ったストロークの両方が残っている必要があります。"
        )
        XCTAssertNotEqual(
            reloaded.strokes[1].id, original.id,
            "移動先では元と同じIDを使い回さず、新しいIDが付与されている必要があります。"
        )
    }

    /// A page whose only content was just moved away should reload as a
    /// clean empty page, not a corrupted or non-empty one.
    func testEmptyDrawingAfterMovingItsOnlyStrokeAwayRoundTrips() throws {
        let onlyStroke = InkStroke(points: samplePoints(), colorHex: "#000000", width: 4)
        var drawing = InkDrawing(strokes: [onlyStroke])

        drawing.strokes.removeAll { $0.id == onlyStroke.id }

        let reloaded = try InkDrawing(data: drawing.data())

        XCTAssertTrue(
            reloaded.isEmpty,
            "ページ内の唯一のストロークを移動した後、空のページとして正しく保存・復元される必要があります。"
        )
    }
}
