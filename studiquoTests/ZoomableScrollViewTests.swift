import SwiftUI
import XCTest
@testable import studiquo

@MainActor
final class ZoomableScrollViewTests: XCTestCase {
    func testCoordinatorReturnsHostedViewAsZoomTarget() {
        let coordinator = ZoomableScrollView<Text>.Coordinator(onZoomChange: { _ in })
        let host = UIHostingController(rootView: Text("ノート"))
        coordinator.hostingController = host

        XCTAssertTrue(coordinator.viewForZooming(in: UIScrollView()) === host.view)
    }

    func testZoomingAtMinimumScaleClearsCenteringInsetsAndReportsScale() {
        var reportedScale: CGFloat?
        let coordinator = ZoomableScrollView<Text>.Coordinator { reportedScale = $0 }
        let host = UIHostingController(rootView: Text("ノート"))
        coordinator.hostingController = host
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.zoomScale = 1
        scrollView.contentInset = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        coordinator.scrollViewDidZoom(scrollView)

        XCTAssertEqual(scrollView.contentInset, .zero)
        XCTAssertEqual(reportedScale, 1)
    }

    func testEndingZoomReportsFinalScale() {
        var reportedScale: CGFloat?
        let coordinator = ZoomableScrollView<Text>.Coordinator { reportedScale = $0 }
        let scrollView = UIScrollView()

        coordinator.scrollViewDidEndZooming(scrollView, with: nil, atScale: 2.75)

        XCTAssertEqual(reportedScale, 2.75)
    }

    func testBoundsTrackerReportsOnlyActualSizeChanges() {
        let scrollView = ZoomableScrollView<Text>.BoundsTrackingScrollView()
        var sizes: [CGSize] = []
        scrollView.onBoundsSizeChange = { sizes.append($0) }

        scrollView.bounds.size = CGSize(width: 400, height: 300)
        scrollView.layoutSubviews()
        scrollView.layoutSubviews()
        scrollView.bounds.size = CGSize(width: 600, height: 300)
        scrollView.layoutSubviews()

        XCTAssertEqual(sizes, [CGSize(width: 400, height: 300), CGSize(width: 600, height: 300)])
    }
}
