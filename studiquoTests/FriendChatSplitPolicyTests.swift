import XCTest
import UIKit
@testable import studiquo

final class FriendChatSplitPolicyTests: XCTestCase {
    private func pixel(of image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
        return (bytes[0], bytes[1], bytes[2])
    }

    // Regression coverage for "picking a different friend closes the panel
    // instead of switching to them": with Alice already open in secondary,
    // picking Bob must switch the panel to Bob, not close it.
    func testPickingADifferentFriendWhileOneIsAlreadyOpenSwitchesRatherThanClosing() {
        let alice = UUID()
        let bob = UUID()

        let action = FriendChatSplitPolicy.action(forTapping: bob, primaryFriendChatID: nil, secondaryFriendChatID: alice)

        XCTAssertEqual(action, .openInSecondary)
    }

    /// Re-tapping the same friend already open must still close the panel —
    /// the toggle-to-close behavior this policy replaced must keep working.
    func testTappingTheSameFriendAlreadyOpenInSecondaryCollapses() {
        let alice = UUID()

        let action = FriendChatSplitPolicy.action(forTapping: alice, primaryFriendChatID: nil, secondaryFriendChatID: alice)

        XCTAssertEqual(action, .collapse)
    }

    func testTappingTheSameFriendAlreadyOpenInPrimaryCollapses() {
        let alice = UUID()

        let action = FriendChatSplitPolicy.action(forTapping: alice, primaryFriendChatID: alice, secondaryFriendChatID: nil)

        XCTAssertEqual(action, .collapse)
    }

    /// After swapSplitPanes() moves a friend chat into the primary pane,
    /// picking a different friend must replace it there — not open a second,
    /// competing friend chat in secondary alongside it.
    func testPickingADifferentFriendWhileOneIsOpenInPrimaryReplacesPrimary() {
        let alice = UUID()
        let bob = UUID()

        let action = FriendChatSplitPolicy.action(forTapping: bob, primaryFriendChatID: alice, secondaryFriendChatID: nil)

        XCTAssertEqual(action, .openInPrimary)
    }

    func testPickingAFriendWithNoChatCurrentlyOpenAnywhereOpensInSecondary() {
        let alice = UUID()

        let action = FriendChatSplitPolicy.action(forTapping: alice, primaryFriendChatID: nil, secondaryFriendChatID: nil)

        XCTAssertEqual(action, .openInSecondary)
    }

    func testPickingAGroupWithNoChatOpenUsesSecondaryPane() {
        let action = NoteChatSplitPolicy.action(
            forTapping: .group(roomID: "study-group"),
            primaryTarget: nil,
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInSecondary)
    }

    func testPickingTheSameGroupAgainCollapsesTheSplit() {
        let group = NoteChatTarget.group(roomID: "study-group")

        let action = NoteChatSplitPolicy.action(
            forTapping: group,
            primaryTarget: nil,
            secondaryTarget: group
        )

        XCTAssertEqual(action, .collapse)
    }

    func testSwitchingFromFriendToGroupReplacesSecondaryChat() {
        let action = NoteChatSplitPolicy.action(
            forTapping: .group(roomID: "study-group"),
            primaryTarget: nil,
            secondaryTarget: .friend(UUID())
        )

        XCTAssertEqual(action, .openInSecondary)
    }

    func testSwitchingFromGroupToFriendAfterPaneSwapReplacesPrimaryChat() {
        let action = NoteChatSplitPolicy.action(
            forTapping: .friend(UUID()),
            primaryTarget: .group(roomID: "study-group"),
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInPrimary)
    }

    func testAttachingToVisibleChatDoesNotCollapseIt() {
        let target = NoteChatTarget.group(roomID: "study-group")

        let action = NoteChatSplitPolicy.actionForAttachment(
            to: target,
            sourcePane: .primary,
            primaryTarget: nil,
            secondaryTarget: target
        )

        XCTAssertEqual(action, .openInSecondary)
    }

    func testAttachingToVisiblePrimaryFriendKeepsPrimaryOpen() {
        let friendID = UUID()
        let target = NoteChatTarget.friend(friendID)

        let action = NoteChatSplitPolicy.actionForAttachment(
            to: target,
            sourcePane: .secondary,
            primaryTarget: target,
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInPrimary)
    }

    func testAttachmentFromPrimaryReplacesDifferentSecondaryChat() {
        let destination = NoteChatTarget.group(roomID: "destination-group")

        let action = NoteChatSplitPolicy.actionForAttachment(
            to: destination,
            sourcePane: .primary,
            primaryTarget: nil,
            secondaryTarget: .friend(UUID())
        )

        XCTAssertEqual(action, .openInSecondary)
    }

    func testAttachmentFromSecondaryReplacesDifferentPrimaryChat() {
        let destination = NoteChatTarget.friend(UUID())

        let action = NoteChatSplitPolicy.actionForAttachment(
            to: destination,
            sourcePane: .secondary,
            primaryTarget: .group(roomID: "old-group"),
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInPrimary)
    }

    func testAttachmentOpensOppositeThePrimarySourcePane() {
        let action = NoteChatSplitPolicy.actionForAttachment(
            to: .friend(UUID()),
            sourcePane: .primary,
            primaryTarget: nil,
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInSecondary)
    }

    func testAttachmentOpensOppositeTheSecondarySourcePane() {
        let action = NoteChatSplitPolicy.actionForAttachment(
            to: .group(roomID: "study-group"),
            sourcePane: .secondary,
            primaryTarget: nil,
            secondaryTarget: nil
        )

        XCTAssertEqual(action, .openInPrimary)
    }

    @MainActor
    func testChatSnippetEncoderResizesLargeCropWithinUploadLimit() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2_600, height: 2_200)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_600, height: 2_200))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 2_400, height: 2_000))
        }
        let snippet = PageSnippet(pngData: try XCTUnwrap(source.pngData()), sourceLabel: "1ページ")

        let encoded = try XCTUnwrap(ChatSnippetImageEncoder.jpegData(for: snippet))
        let decoded = try XCTUnwrap(UIImage(data: encoded))

        XCTAssertLessThanOrEqual(encoded.count, ChatSnippetImageEncoder.maximumBytes)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), ChatSnippetImageEncoder.maximumDimension)
    }

    func testPageSnippetCodableRoundTripPreservesDragPayload() throws {
        let original = PageSnippet(
            id: UUID(),
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            sourceLabel: "ドラッグ回帰"
        )

        let decoded = try JSONDecoder().decode(
            PageSnippet.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    @MainActor
    func testChatSnippetEncoderRejectsInvalidImageData() {
        let invalid = PageSnippet(
            pngData: Data("not-an-image".utf8),
            sourceLabel: "破損画像"
        )

        XCTAssertNil(ChatSnippetImageEncoder.jpegData(for: invalid))
    }

    @MainActor
    func testChatSnippetEncoderKeepsSmallReadableImagesAtTheirOriginalDimensions() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 30, width: 200, height: 20))
            context.fill(CGRect(x: 20, y: 70, width: 140, height: 20))
        }
        let sourceData = try XCTUnwrap(source.pngData())
        let sourceDecoded = try XCTUnwrap(UIImage(data: sourceData))
        let snippet = PageSnippet(pngData: sourceData, sourceLabel: "文字")

        let encoded = try XCTUnwrap(ChatSnippetImageEncoder.jpegData(for: snippet))
        let decoded = try XCTUnwrap(UIImage(data: encoded))
        let cgImage = try XCTUnwrap(decoded.cgImage)
        let ink = try XCTUnwrap(pixel(of: decoded, x: cgImage.width / 2, y: cgImage.height / 3))
        let paper = try XCTUnwrap(pixel(of: decoded, x: cgImage.width / 2, y: cgImage.height / 12))

        XCTAssertEqual(decoded.size.width, sourceDecoded.size.width, accuracy: 1)
        XCTAssertEqual(decoded.size.height, sourceDecoded.size.height, accuracy: 1)
        XCTAssertLessThan(Int(ink.r) + Int(ink.g) + Int(ink.b), 120, "黒い文字相当の線が圧縮後も判読できる必要があります。")
        XCTAssertGreaterThan(Int(paper.r) + Int(paper.g) + Int(paper.b), 650, "白い背景とのコントラストが圧縮後も保たれる必要があります。")
    }

    func testRapidDuplicateSnippetClaimsOnlyOneAttachmentSlot() {
        let snippetID = UUID()
        var tracker = ChatSnippetAttachmentTracker()

        XCTAssertTrue(tracker.begin(snippetID))
        XCTAssertFalse(tracker.begin(snippetID), "同じ切り抜きの連打や二重配送で、添付を重複作成してはいけません。")
    }

    func testFailedSnippetCanBeRetried() {
        let snippetID = UUID()
        var tracker = ChatSnippetAttachmentTracker()

        XCTAssertTrue(tracker.begin(snippetID))
        tracker.fail(snippetID)

        XCTAssertTrue(tracker.begin(snippetID), "通信失敗後は同じ切り抜きを再試行できる必要があります。")
    }

    func testRemovingAnAttachmentReleasesOnlyItsOwnSnippet() {
        let first = UUID()
        let second = UUID()
        var tracker = ChatSnippetAttachmentTracker()
        XCTAssertTrue(tracker.begin(first))
        tracker.complete(first, attachmentID: "attachment-1")
        XCTAssertTrue(tracker.begin(second))
        tracker.complete(second, attachmentID: "attachment-2")

        tracker.removeAttachment("attachment-1")

        XCTAssertTrue(tracker.begin(first), "削除した画像は再び添付できる必要があります。")
        XCTAssertFalse(tracker.begin(second), "別の画像の重複防止状態まで解除してはいけません。")
    }

    func testSuccessfulSendReleasesSentSnippetsButKeepsFailedOnesForRemovalOrRetry() {
        let sent = UUID()
        let failed = UUID()
        var tracker = ChatSnippetAttachmentTracker()
        XCTAssertTrue(tracker.begin(sent))
        tracker.complete(sent, attachmentID: "sent")
        XCTAssertTrue(tracker.begin(failed))
        tracker.complete(failed, attachmentID: "failed")

        tracker.retainAttachments(withIDs: ["failed"])

        XCTAssertTrue(tracker.begin(sent), "送信済み画像の一時状態は残してはいけません。")
        XCTAssertFalse(tracker.begin(failed), "送信失敗した画像は入力欄に残り、重複追加を防ぐ必要があります。")
    }

    func testPendingSnippetDoesNotLeakWhenSwitchingToAnotherChat() {
        let intendedFriend = NoteChatTarget.friend(UUID())
        let otherGroup = NoteChatTarget.group(roomID: "other-group")
        let snippet = PageSnippet(pngData: Data([1, 2, 3]), sourceLabel: "切り替え")
        let pending = PendingChatSnippet(target: intendedFriend, snippet: snippet)

        XCTAssertEqual(pending.snippet(for: intendedFriend), snippet)
        XCTAssertNil(pending.snippet(for: otherGroup), "添付中にチャットを切り替えても、別の入力欄へ画像を引き継いではいけません。")
        XCTAssertFalse(
            pending.matchesConsumption(snippetID: snippet.id, target: otherGroup),
            "別チャットの表示完了通知で、元チャットの保留画像を消してはいけません。"
        )
    }
}
