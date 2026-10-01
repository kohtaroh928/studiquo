import Foundation

/// A conversation that can occupy either side of the note split view.
/// Keeping direct and group chats in one mutually-exclusive value prevents
/// two chat surfaces from accidentally being active in the same pane.
public enum NoteChatTarget: Equatable {
    case friend(UUID)
    case group(roomID: String)
}

public enum NoteChatPane: Equatable {
    case primary
    case secondary
}

/// What selecting a chat in the note toolbar should do to the split panel.
public enum NoteChatSplitAction: Equatable {
    /// The selected conversation is already showing — close the split,
    /// preserving the toolbar's tap-again-to-dismiss behaviour.
    case collapse
    /// No chat currently occupies the primary pane, so use the secondary.
    case openInSecondary
    /// A chat occupies the primary pane (for example after swapping panes),
    /// so replace it there rather than opening two competing chat surfaces.
    case openInPrimary
}

public enum NoteChatSplitPolicy {
    public static func action(
        forTapping target: NoteChatTarget,
        primaryTarget: NoteChatTarget?,
        secondaryTarget: NoteChatTarget?
    ) -> NoteChatSplitAction {
        if primaryTarget == target || secondaryTarget == target {
            return .collapse
        }
        return primaryTarget != nil ? .openInPrimary : .openInSecondary
    }

    /// Attachment routing is intentionally not a toggle. Selecting the chat
    /// that is already visible must keep it open and load the image, whereas
    /// tapping the normal toolbar chat entry again still collapses it.
    public static func actionForAttachment(
        to target: NoteChatTarget,
        sourcePane: NoteChatPane,
        primaryTarget: NoteChatTarget?,
        secondaryTarget: NoteChatTarget?
    ) -> NoteChatSplitAction {
        if primaryTarget == target { return .openInPrimary }
        if secondaryTarget == target { return .openInSecondary }
        return sourcePane == .primary ? .openInSecondary : .openInPrimary
    }
}

// Compatibility wrapper for callers and regression tests that still express
// the older friend-only rule. New note-toolbar code uses NoteChatSplitPolicy.
public typealias FriendChatSplitAction = NoteChatSplitAction

public enum FriendChatSplitPolicy {
    public static func action(
        forTapping friendID: UUID,
        primaryFriendChatID: UUID?,
        secondaryFriendChatID: UUID?
    ) -> FriendChatSplitAction {
        NoteChatSplitPolicy.action(
            forTapping: .friend(friendID),
            primaryTarget: primaryFriendChatID.map(NoteChatTarget.friend),
            secondaryTarget: secondaryFriendChatID.map(NoteChatTarget.friend)
        )
    }
}
