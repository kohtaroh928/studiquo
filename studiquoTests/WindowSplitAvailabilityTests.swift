import XCTest
import UIKit
@testable import studiquo

final class WindowSplitAvailabilityTests: XCTestCase {
    func testHalfWidthAndSmallerWindowsCannotSplitAcrossIPadSizes() {
        for displayWidth: CGFloat in [744, 768, 834, 1024, 1194, 1366] {
            XCTAssertFalse(WindowSplitAvailability.allowsSplit(
                windowWidth: displayWidth / 2, displayWidth: displayWidth
            ))
            XCTAssertFalse(WindowSplitAvailability.allowsSplit(
                windowWidth: displayWidth / 3, displayWidth: displayWidth
            ))
        }
    }

    func testFullWidthAndTwoThirdsWindowsCanSplit() {
        for displayWidth: CGFloat in [744, 768, 834, 1024, 1194, 1366] {
            XCTAssertTrue(WindowSplitAvailability.allowsSplit(
                windowWidth: displayWidth, displayWidth: displayWidth
            ))
            XCTAssertTrue(WindowSplitAvailability.allowsSplit(
                windowWidth: displayWidth * 2 / 3, displayWidth: displayWidth
            ))
        }
    }

    func testResizingFromFullToHalfAndBackUpdatesAvailability() {
        let widths: [CGFloat] = [1366, 900, 683, 450, 683, 900, 1366]
        XCTAssertEqual(widths.map {
            WindowSplitAvailability.allowsSplit(windowWidth: $0, displayWidth: 1366)
        }, [true, true, false, false, false, true, true])
    }

    func testHalfWidthRoundingAndInvalidGeometryCannotEnableSplit() {
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 699, displayWidth: 1366))
        XCTAssertTrue(WindowSplitAvailability.allowsSplit(windowWidth: 700, displayWidth: 1366))
        for width: CGFloat in [0, -1, .infinity, .nan] {
            XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: width, displayWidth: 1366))
            XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 1366, displayWidth: width))
        }
    }

    @MainActor
    func testProbeTracksWindowResizingInsteadOfItsOwnContentWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.screen.bounds.size
        let displayWidth = scene.interfaceOrientation.isLandscape
            ? max(size.width, size.height) : min(size.width, size.height)
        let window = UIWindow(windowScene: scene)
        let probe = WindowSplitAvailabilityProbe(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.frame = CGRect(x: 0, y: 0, width: displayWidth, height: 600)
        let full = expectation(description: "A narrow content view inside a full window allows splitting")
        probe.onChange = { available in
            XCTAssertTrue(available)
            full.fulfill()
        }
        window.addSubview(probe)
        await fulfillment(of: [full], timeout: 2)

        let half = expectation(description: "Shrinking the actual window disables splitting")
        probe.onChange = { available in
            XCTAssertFalse(available)
            half.fulfill()
        }
        window.frame.size.width = displayWidth / 2
        probe.setNeedsLayout()
        probe.layoutIfNeeded()
        await fulfillment(of: [half], timeout: 2)

        let restored = expectation(description: "Expanding the window enables splitting again")
        probe.onChange = { available in
            XCTAssertTrue(available)
            restored.fulfill()
        }
        window.frame.size.width = displayWidth
        probe.setNeedsLayout()
        probe.layoutIfNeeded()
        await fulfillment(of: [restored], timeout: 2)
        probe.onChange = nil
    }
}
