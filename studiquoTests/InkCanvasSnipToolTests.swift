import XCTest
@testable import studiquo

/// Coverage for the スニップ (snip) tool: a single rectangle drag that
/// crops out a region of the page as an image (a printed question, a proof
/// written by hand) to drop into the AI chat.
///
/// Note: the 5-item checklist this was requested against ("交差しても正しく
/// 選択されるか", "同じ画面内でつまんで動かせるか", "別の画面へドラッグして
/// 移動できるか", "範囲の外をタップして選択解除できるか") describes the
/// 選択ツール(なげなわ), not スニップ — スニップ has no loop, no
/// after-the-fact move, no cross-pane drag, and no persistent selection to
/// deselect; it's a single drag that captures immediately on lift (see
/// `finishSnip()`/`onSnipCaptured` in `InkCanvasView.swift`). The tests
/// below instead cover what the snip tool actually does, item by item.
final class InkCanvasSnipToolTests: XCTestCase {
    // MARK: - 1: a normal drag captures the dragged rectangle

    func testDraggingTopLeftToBottomRightCapturesThatRectangle() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 130), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 30, width: 100, height: 100), "通常のドラッグでは、始点と終点で決まる四角形がそのまま切り取られる必要があります。")
    }

    // MARK: - 2: a tap or sliver drag is ignored, not reported as a selection

    func testATapWithNoMovementCapturesNothing() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertNil(rect, "動かさずにタップしただけの場合は、何も切り取られてはいけません。")
    }

    func testADragSmallerThanTheMinimumSizeCapturesNothing() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 50, y: 50), to: CGPoint(x: 55, y: 55), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertNil(rect, "小さすぎるドラッグ(意図しない揺れなど)は、選択とみなされてはいけません。")
    }

    func testADragExactlyAtTheMinimumSizeCapturesSuccessfully() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 16, y: 16), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 16, height: 16), "最小サイズちょうどのドラッグは、切り取りが成功する必要があります。")
    }

    // MARK: - 3: the rectangle is normalized regardless of drag direction

    func testDraggingInAnyDirectionProducesTheSameNormalizedRectangle() {
        let canvasSize = CGSize(width: 500, height: 500)
        let topLeft = CGPoint(x: 20, y: 30)
        let bottomRight = CGPoint(x: 120, y: 130)
        let expected = CGRect(x: 20, y: 30, width: 100, height: 100)

        XCTAssertEqual(
            InkCanvasView.snipCaptureRect(from: topLeft, to: bottomRight, canvasSize: canvasSize), expected,
            "左上から右下へのドラッグは、そのままの矩形になる必要があります。"
        )
        XCTAssertEqual(
            InkCanvasView.snipCaptureRect(from: bottomRight, to: topLeft, canvasSize: canvasSize), expected,
            "右下から左上へ逆向きにドラッグしても、同じ矩形になる必要があります。"
        )
        XCTAssertEqual(
            InkCanvasView.snipCaptureRect(from: CGPoint(x: 120, y: 30), to: CGPoint(x: 20, y: 130), canvasSize: canvasSize),
            expected, "右上から左下へドラッグしても、同じ矩形になる必要があります。"
        )
        XCTAssertEqual(
            InkCanvasView.snipCaptureRect(from: CGPoint(x: 20, y: 130), to: CGPoint(x: 120, y: 30), canvasSize: canvasSize),
            expected, "左下から右上へドラッグしても、同じ矩形になる必要があります。"
        )
    }

    // MARK: - 4: the captured rectangle never extends past the page's edge

    func testDraggingPastTheRightAndBottomEdgeClipsToThePage() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 400, y: 400), to: CGPoint(x: 600, y: 600), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(rect, CGRect(x: 400, y: 400, width: 100, height: 100), "ページの右端・下端をはみ出しても、実際に切り取られる範囲はページ内に収まる必要があります。")
    }

    func testDraggingPastTheLeftAndTopEdgeClipsToThePage() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: -50, y: -50), to: CGPoint(x: 50, y: 50), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 50, height: 50), "ページの左端・上端をはみ出しても、実際に切り取られる範囲はページ内に収まる必要があります。")
    }

    func testDraggingEntirelyOutsideThePageCapturesAnEmptyRectangle() {
        let rect = InkCanvasView.snipCaptureRect(
            from: CGPoint(x: 600, y: 600), to: CGPoint(x: 700, y: 700), canvasSize: CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(rect?.isEmpty, true, "ページの外だけをドラッグした場合、切り取り範囲はページと重ならず空になる必要があります。")
    }

    // MARK: - 5: the live preview rectangle (unclipped) matches the drag exactly

    func testTheLivePreviewRectangleIsNotClippedToThePage() {
        // Unlike the final capture, the dashed preview shown mid-drag must
        // stay glued to the pencil even past the page's edge — only the
        // rectangle actually reported on lift is clipped.
        let rect = InkCanvasView.snipDragRect(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 600, y: 600))
        XCTAssertEqual(rect, CGRect(x: 400, y: 400, width: 200, height: 200), "ドラッグ中のプレビュー枠は、ページの外にはみ出していてもそのままの大きさで表示される必要があります。")
    }

    func testTheLivePreviewRectangleTracksEachIntermediatePositionDuringTheDrag() {
        // `touchesMoved` recomputes the preview from the start point and
        // whatever the pencil's current position is on every sample — this
        // walks a drag through several positions and checks each one
        // updates independently, the way "指の動きに追従する" requires.
        let start = CGPoint(x: 50, y: 50)
        let waypoints: [(current: CGPoint, expected: CGRect)] = [
            (CGPoint(x: 60, y: 60), CGRect(x: 50, y: 50, width: 10, height: 10)),
            (CGPoint(x: 90, y: 70), CGRect(x: 50, y: 50, width: 40, height: 20)),
            (CGPoint(x: 30, y: 100), CGRect(x: 30, y: 50, width: 20, height: 50)),
            (CGPoint(x: 150, y: 40), CGRect(x: 50, y: 40, width: 100, height: 10)),
        ]
        for (current, expected) in waypoints {
            XCTAssertEqual(
                InkCanvasView.snipDragRect(from: start, to: current), expected,
                "ドラッグ中に指(ペン先)が動くたびに、プレビュー枠はその時点の位置に合わせて更新される必要があります。"
            )
        }
    }
}
