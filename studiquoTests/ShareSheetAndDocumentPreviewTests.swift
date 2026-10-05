import QuickLook
import XCTest
@testable import studiquo

@MainActor
final class ShareSheetAndDocumentPreviewTests: XCTestCase {
    func testShareSheetCreatesActivityControllerWithProvidedItems() {
        let url = URL(fileURLWithPath: "/tmp/notes.pdf")

        let controller = ShareSheet.makeController(items: ["共有テキスト", url])

        XCTAssertNotNil(controller.view)
        // Creating the controller without an exception verifies that mixed
        // text/file items are accepted by the actual UIKit share surface.
    }

    func testDocumentPreviewCoordinatorProvidesExactlyOneURL() {
        let url = URL(fileURLWithPath: "/tmp/lecture.pdf")
        let coordinator = DocumentPreview.Coordinator(url: url)
        let controller = QLPreviewController()

        XCTAssertEqual(coordinator.numberOfPreviewItems(in: controller), 1)
        XCTAssertEqual(
            coordinator.previewController(controller, previewItemAt: 0).previewItemURL,
            url
        )
    }

    func testDocumentPreviewControllerUsesItsCoordinatorAsDataSource() {
        let preview = DocumentPreview(url: URL(fileURLWithPath: "/tmp/first.pdf"))
        let coordinator = preview.makeCoordinator()

        let controller = DocumentPreview.makeController(coordinator: coordinator)

        XCTAssertTrue(controller.dataSource === coordinator)
    }

    func testDocumentPreviewUpdateReplacesCoordinatorURL() {
        let original = DocumentPreview(url: URL(fileURLWithPath: "/tmp/first.pdf"))
        let coordinator = original.makeCoordinator()
        let controller = DocumentPreview.makeController(coordinator: coordinator)
        let updatedURL = URL(fileURLWithPath: "/tmp/second.pdf")

        DocumentPreview.update(controller, coordinator: coordinator, url: updatedURL)

        XCTAssertEqual(coordinator.url, updatedURL)
    }
}
