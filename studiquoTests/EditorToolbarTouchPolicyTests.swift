import XCTest
@testable import studiquo

final class EditorToolbarTouchPolicyTests: XCTestCase {
    func testToolbarScrollViewDeliversTouchesImmediatelyToPickerAndMenuControls() {
        let scrollView = UIScrollView()
        scrollView.delaysContentTouches = true

        configureEditorToolbarScrollView(scrollView)

        XCTAssertFalse(
            scrollView.delaysContentTouches,
            "The editor tool strip must not delay touches, otherwise PhotosPicker and Menu tools can look unresponsive inside the horizontal toolbar."
        )
    }

    func testToolbarTouchPolicyFindsAncestorScrollView() {
        let scrollView = UIScrollView()
        scrollView.delaysContentTouches = true
        let container = UIView()
        let marker = UIView()
        scrollView.addSubview(container)
        container.addSubview(marker)

        ToolbarScrollTouchPolicy.apply(from: marker)

        XCTAssertFalse(scrollView.delaysContentTouches)
    }

    @MainActor
    func testCanvasCoordinatorRestoresScrollAndZoomContainerAfterAStrokeEnds() {
        let representable = InkCanvasRepresentable(
            drawing: .constant(InkDrawing()),
            selectedTool: .constant(.pen),
            color: .black,
            width: 3
        )
        let coordinator = InkCanvasRepresentable.Coordinator(representable)
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 4
        scrollView.zoomScale = 2
        // An empty UIScrollView may clamp the requested value back to 1;
        // what matters here is that the coordinator preserves whichever
        // scale the real zoom container had when the stroke began.
        let initialZoomScale = scrollView.zoomScale
        coordinator.ancestorScrollViews = [scrollView]

        coordinator.freezeAncestorScrolling()
        XCTAssertFalse(scrollView.isScrollEnabled)

        coordinator.unfreezeAncestorScrolling()
        XCTAssertTrue(scrollView.isScrollEnabled, "描画や切り抜きの終了後は、ページのスクロールとピンチ拡大縮小を再開する必要があります。")
        XCTAssertEqual(scrollView.zoomScale, initialZoomScale, "操作モードの切り替えで利用者の拡大率を失ってはいけません。")
    }
}
