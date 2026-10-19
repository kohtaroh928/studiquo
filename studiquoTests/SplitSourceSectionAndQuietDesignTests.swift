import SwiftUI
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class SplitSourceSectionAndQuietDesignTests: XCTestCase {
    // MARK: - 1. SplitSourceSection top-level tab metadata (Materials / AI / Friends)

    func testSplitSourceSectionCasesTitlesAndSymbols() {
        XCTAssertEqual(SplitSourceSection.allCases, [.materials, .ai, .friends])
        XCTAssertEqual(SplitSourceSection.materials.id, "materials")
        XCTAssertEqual(SplitSourceSection.ai.id, "ai")
        XCTAssertEqual(SplitSourceSection.friends.id, "friends")

        XCTAssertEqual(SplitSourceSection.materials.title, "資料")
        XCTAssertEqual(SplitSourceSection.ai.title, "AI")
        XCTAssertEqual(SplitSourceSection.friends.title, "フレンド")

        XCTAssertEqual(SplitSourceSection.materials.systemImage, "folder")
        XCTAssertEqual(SplitSourceSection.ai.systemImage, "sparkles")
        XCTAssertEqual(SplitSourceSection.friends.systemImage, "person.2")
    }

    // MARK: - 2. PhotoStudyLibraryView & PhotoStudyPaneViewer headerAccessory support

    func testPhotoStudyViewsAcceptOptionalHeaderAccessoryForPaneReplaceButton() {
        let accessory = AnyView(Button("資料を入れ替える") {})
        let libraryView = PhotoStudyLibraryView(
            onSelect: { _ in },
            onClose: {},
            headerAccessory: accessory
        )
        XCTAssertNotNil(libraryView.headerAccessory)

        let viewer = PhotoStudyPaneViewer(
            assetIdentifier: "test-asset-id",
            onClose: {},
            headerAccessory: accessory
        )
        XCTAssertNotNil(viewer.headerAccessory)
    }

    // MARK: - 3. WindowSplitAvailability boundary conditions

    func testWindowSplitAvailabilityRejectsHalfWidthSlideOverAndNonFiniteDimensions() {
        let displayWidth: CGFloat = 1024
        // Exactly half width or half width + 16pt divider allowance must not allow split
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 512, displayWidth: displayWidth))
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 512 + 16, displayWidth: displayWidth))

        // 2/3 Split View and Full Screen allow in-app split
        XCTAssertTrue(WindowSplitAvailability.allowsSplit(windowWidth: 512 + 17, displayWidth: displayWidth))
        XCTAssertTrue(WindowSplitAvailability.allowsSplit(windowWidth: 680, displayWidth: displayWidth))
        XCTAssertTrue(WindowSplitAvailability.allowsSplit(windowWidth: 1024, displayWidth: displayWidth))

        // Invalid or non-finite values fail closed
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 0, displayWidth: displayWidth))
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: -100, displayWidth: displayWidth))
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: .nan, displayWidth: displayWidth))
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: .infinity, displayWidth: displayWidth))
        XCTAssertFalse(WindowSplitAvailability.allowsSplit(windowWidth: 800, displayWidth: 0))
    }
}
