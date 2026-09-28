import Foundation

/// What tapping a friend's chat button in the note toolbar should do to the
/// split panel, given which friend (if any) each pane currently shows.
/// Pulled out of `NoteEditorView.openFriendChat(_:)` (deeply embedded
/// `@State` on a large SwiftUI view, not directly testable) into its own
/// pure function, the same way `SplitPaneResizeRenderPolicy` is.
public enum FriendChatSplitAction: Equatable {
    /// The tapped friend is already showing (in either pane) — close the
    /// split entirely, same as tapping it again to dismiss.
    case collapse
    /// No friend chat is currently in the primary pane — put this friend's
    /// chat in the secondary pane (opening the split if it wasn't already).
    case openInSecondary
    /// A friend chat already occupies the primary pane (e.g. after swapping
    /// panes) — replace it there instead of opening a second, competing
    /// friend chat in secondary alongside it.
    case openInPrimary
}

public enum FriendChatSplitPolicy {
    public static func action(
        forTapping friendID: UUID,
        primaryFriendChatID: UUID?,
        secondaryFriendChatID: UUID?
    ) -> FriendChatSplitAction {
        if primaryFriendChatID == friendID || secondaryFriendChatID == friendID {
            return .collapse
        }
        return primaryFriendChatID != nil ? .openInPrimary : .openInSecondary
    }
}
