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
}
