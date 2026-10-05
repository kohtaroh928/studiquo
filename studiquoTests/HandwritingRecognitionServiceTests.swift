import XCTest
@testable import studiquo

final class HandwritingRecognitionServiceTests: XCTestCase {
    private func stroke() -> InkStroke {
        InkStroke(
            points: [
                InkPoint(location: CGPoint(x: 100, y: 100), force: 0.5, timeOffset: 0),
                InkPoint(location: CGPoint(x: 200, y: 100), force: 0.5, timeOffset: 1)
            ],
            colorHex: "#000000",
            width: 4
        )
    }

    func testNilDrawingDataReturnsEmptyWithoutInvokingRecognizer() async {
        let result = await HandwritingRecognitionService.recognize(
            drawingData: nil,
            pageSize: CGSize(width: 200, height: 300)
        ) { _ in
            XCTFail("空データでは認識処理を呼び出してはいけません")
            return "unexpected"
        }

        XCTAssertEqual(result, "")
    }

    func testMalformedDrawingDataReturnsEmptyWithoutInvokingRecognizer() async {
        let result = await HandwritingRecognitionService.recognize(
            drawingData: Data("not-an-ink-drawing".utf8),
            pageSize: CGSize(width: 200, height: 300)
        ) { _ in
            XCTFail("破損データでは認識処理を呼び出してはいけません")
            return "unexpected"
        }

        XCTAssertEqual(result, "")
    }

    func testEmptyDrawingReturnsEmptyWithoutInvokingRecognizer() async throws {
        let result = await HandwritingRecognitionService.recognize(
            drawingData: try InkDrawing().data(),
            pageSize: CGSize(width: 200, height: 300)
        ) { _ in
            XCTFail("空の描画では認識処理を呼び出してはいけません")
            return "unexpected"
        }

        XCTAssertEqual(result, "")
    }

    func testWholePageRasterizesAtTwiceThePageSizeAndReturnsRecognizerText() async throws {
        let result = await HandwritingRecognitionService.recognize(
            drawingData: try InkDrawing(strokes: [stroke()]).data(),
            pageSize: CGSize(width: 200, height: 300)
        ) { image in
            let displayScale = UIGraphicsImageRendererFormat.default().scale
            XCTAssertEqual(image.width, Int(400 * displayScale))
            XCTAssertEqual(image.height, Int(600 * displayScale))
            return "手書き認識結果"
        }

        XCTAssertEqual(result, "手書き認識結果")
    }

    func testSelectionRasterizesOnlyPaddedInkBounds() async {
        let result = await HandwritingRecognitionService.recognize(
            drawing: InkDrawing(strokes: [stroke()])
        ) { image in
            // Stroke bounds are 108×8. Adding the minimum 12 pt padding on
            // every side produces 132×32, rasterized at 2×.
            let displayScale = UIGraphicsImageRendererFormat.default().scale
            XCTAssertEqual(image.width, Int(264 * displayScale))
            XCTAssertEqual(image.height, Int(64 * displayScale))
            return "選択範囲"
        }

        XCTAssertEqual(result, "選択範囲")
    }

    func testEmptySelectionReturnsEmptyWithoutInvokingRecognizer() async {
        let result = await HandwritingRecognitionService.recognize(drawing: InkDrawing()) { _ in
            XCTFail("空の選択範囲では認識処理を呼び出してはいけません")
            return "unexpected"
        }

        XCTAssertEqual(result, "")
    }
}
