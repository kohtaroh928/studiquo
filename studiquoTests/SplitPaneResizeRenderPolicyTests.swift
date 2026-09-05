import XCTest
@testable import studiquo

final class SplitPaneResizeRenderPolicyTests: XCTestCase {
    func testDraggingSplitDividerUsesLightweightPlaceholder() {
        XCTAssertTrue(
            SplitPaneResizeRenderPolicy.shouldUseLightweightPlaceholder(isDragging: true),
            "境界線をドラッグ中は、ノートやPDFなどの重い画面を毎回リサイズせず、軽い表示に切り替える必要があります。"
        )
    }

    func testIdleSplitDividerUsesLivePaneContent() {
        XCTAssertFalse(
            SplitPaneResizeRenderPolicy.shouldUseLightweightPlaceholder(isDragging: false),
            "ドラッグしていないときは、通常のノート、PDF、チャットなどの本来の画面を表示する必要があります。"
        )
    }

    func testRapidResizeKeepsHeavyContentDisabledUntilDraggingEnds() {
        let dragStates = [false, true, true, true, true, false]
        let renderDecisions = dragStates.map {
            SplitPaneResizeRenderPolicy.shouldUseLightweightPlaceholder(isDragging: $0)
        }

        XCTAssertEqual(
            renderDecisions,
            [false, true, true, true, true, false],
            "境界線を素早く動かしている間は、重い画面を再計算せず、ドラッグ終了後だけ本来の画面に戻す必要があります。"
        )
    }
}
