import XCTest
@testable import studiquo

final class FriendChatSplitPolicyTests: XCTestCase {
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
}
