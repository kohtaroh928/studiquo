import Foundation

/// Decides what a scanned QR code's raw text means: one of studiquo's own
/// invite links (the https:// Universal Link, or the older studiquo://
/// custom scheme — see `FriendStore.add(url:)`), or something else that
/// should fall back to the manual-code entry path instead. Pulled out of
/// `AddFriendView` (a private SwiftUI view, not directly testable) into its
/// own pure function, the same way `SplitPaneResizeRenderPolicy` is.
public enum QRScanRoutingPolicy {
    public static func isInviteLink(_ scannedValue: String) -> Bool {
        guard let url = URL(string: scannedValue), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "studiquo" || scheme == "https"
    }
}
