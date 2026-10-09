import CoreGraphics

/// What the "open a file from the Files app" pane should show.
///
/// The pane is built from three outside facts that can each go wrong on their
/// own — the saved bookmark, the file itself, and (for cloud providers) whether
/// its bytes are on the device — so the decision lives in one pure function
/// instead of being re-derived in the view.
public enum ExternalFilePaneState: Equatable {
    /// Picking a file.
    case browsing
    /// The file is known but not readable yet (cloud download in progress).
    case loading
    case ready
    /// The bookmark resolved to nothing, or the file is gone.
    case missing
    /// The file is there but the app may not read it.
    case accessDenied
}

public enum ExternalFileBookmarkResolution: Equatable {
    case resolved
    /// Resolved, but the stored bookmark was stale and has been re-created.
    case refreshed
    case failed
}

public enum ExternalFileDownloadStatus: Equatable {
    /// Not a cloud item, or fully downloaded.
    case local
    case notDownloaded
    case downloading
}

public enum ExternalFilePanePolicy {
    /// Below this width the Files browser has no room for its sidebar and list
    /// side by side, so the pane shows a "choose a file" button instead and
    /// presents the picker modally.
    public static let minimumEmbeddedBrowserWidth: CGFloat = 320

    public static func usesEmbeddedBrowser(paneWidth: CGFloat) -> Bool {
        paneWidth >= minimumEmbeddedBrowserWidth
    }

    public static func state(
        resolution: ExternalFileBookmarkResolution,
        fileExists: Bool,
        isReadable: Bool,
        downloadStatus: ExternalFileDownloadStatus
    ) -> ExternalFilePaneState {
        guard resolution != .failed else { return .missing }
        // A cloud item that is not on the device yet reports as missing on disk
        // in some providers, so the download status is checked first.
        switch downloadStatus {
        case .notDownloaded, .downloading:
            return .loading
        case .local:
            break
        }
        guard fileExists else { return .missing }
        guard isReadable else { return .accessDenied }
        return .ready
    }
}
