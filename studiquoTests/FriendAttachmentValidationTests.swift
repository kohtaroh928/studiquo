import XCTest
@testable import studiquo

/// Regression coverage for a real gap: `downloadAndPreviewFriendAttachment`
/// (`ContentView.swift`) used to write whatever bytes a friend's room
/// returned straight to disk and hand them to QuickLook, with no size cap
/// and no check that the bytes actually matched the attachment's declared
/// kind — both the kind and the file extension are read from the sender's
/// own message payload, not verified server-side.
final class FriendAttachmentValidationTests: XCTestCase {
    private let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0])
    private let pdfHeader = Data("%PDF-1.7".utf8)
    private let notAnImage = Data("これは画像ではありません".utf8)

    // MARK: サイズの上限

    func testAnOversizedAttachmentIsRejectedRegardlessOfKind() {
        let oversized = Data(repeating: 0, count: maximumFriendAttachmentBytes + 1)
        XCTAssertFalse(isValidFriendAttachment(sourceKind: "file", data: oversized))
        XCTAssertFalse(isValidFriendAttachment(sourceKind: "photo", data: jpegHeader + oversized))
    }

    func testAnAttachmentExactlyAtTheSizeLimitIsAccepted() {
        let exact = Data(repeating: 0, count: maximumFriendAttachmentBytes)
        XCTAssertTrue(isValidFriendAttachment(sourceKind: "file", data: exact))
    }

    func testAnEmptyAttachmentIsRejected() {
        XCTAssertFalse(isValidFriendAttachment(sourceKind: "file", data: Data()))
    }

    // MARK: 種類ごとのマジックバイト検証

    func testAGenuineJPEGDeclaredAsPhotoIsAccepted() {
        XCTAssertTrue(isValidFriendAttachment(sourceKind: "photo", data: jpegHeader))
    }

    func testNonImageBytesDeclaredAsPhotoAreRejected() {
        XCTAssertFalse(isValidFriendAttachment(sourceKind: "photo", data: notAnImage))
    }

    func testAGenuinePDFDeclaredAsPdfIsAccepted() {
        XCTAssertTrue(isValidFriendAttachment(sourceKind: "pdf", data: pdfHeader))
    }

    /// The core scenario the earlier review flagged: a sender declares
    /// "pdf" but the bytes are something else entirely (e.g. a JPEG, or
    /// bytes crafted to exploit a specific parser) — this must not be
    /// silently handed to the PDF-handling path.
    func testBytesThatDoNotMatchTheDeclaredPdfKindAreRejected() {
        XCTAssertFalse(isValidFriendAttachment(sourceKind: "pdf", data: jpegHeader))
    }

    /// A generic "file" kind has no single expected signature — arbitrary
    /// well-formed bytes under the size cap are accepted, same as before
    /// this fix, since only size and photo/PDF magic bytes are checked here.
    func testAGenericFileKindIsOnlyBoundedBySize() {
        XCTAssertTrue(isValidFriendAttachment(sourceKind: "file", data: notAnImage))
    }
}
