import Foundation

/// One "open a file from the Files app" pane: what it is showing, and the
/// scoped access that keeps the chosen file readable while it is shown.
///
/// A reference type on purpose. The note editor can swap its two panes, and a
/// session that moves with the pane keeps its place instead of resetting to the
/// file browser. The access is released when the session is closed or freed.
@MainActor
final class ExternalFileSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var state: ExternalFilePaneState = .browsing
    @Published private(set) var fileName = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var recents: [ExternalFileEntry]

    private let store: ExternalFileBookmarkStore
    private var access: ScopedFileAccess?
    private var downloadTask: Task<Void, Never>?

    init(store: ExternalFileBookmarkStore = ExternalFileBookmarkStore.shared) {
        self.store = store
        self.recents = store.entries
    }

    /// A file just chosen in the browser or picker.
    func open(pickedURL url: URL) {
        begin(ScopedFileAccess(url: url))
    }

    /// A file remembered from an earlier launch.
    func open(entry: ExternalFileEntry) {
        switch store.resolve(entry) {
        case .failed:
            release()
            fileName = entry.displayName
            state = .missing
            // It can never open again, so it should not stay in the list.
            store.remove(id: entry.id)
            recents = store.entries
        case .resolved(let url):
            begin(ScopedFileAccess(url: url))
        }
    }

    func backToBrowser() {
        release()
        fileName = ""
        state = .browsing
    }

    /// Stops reading the file. Safe to call repeatedly.
    func close() {
        release()
        fileName = ""
        state = .browsing
    }

    private func begin(_ newAccess: ScopedFileAccess) {
        release()
        access = newAccess
        fileName = newAccess.url.lastPathComponent
        // The access is open now, which is what a bookmark of this file needs.
        store.add(url: newAccess.url)
        recents = store.entries
        evaluate()
    }

    private func release() {
        downloadTask?.cancel()
        downloadTask = nil
        access?.release()
        access = nil
        fileURL = nil
    }

    private func evaluate() {
        guard let url = access?.url else { return }
        let status = Self.downloadStatus(of: url)
        let next = ExternalFilePanePolicy.state(
            resolution: .resolved,
            fileExists: FileManager.default.fileExists(atPath: url.path),
            isReadable: FileManager.default.isReadableFile(atPath: url.path),
            downloadStatus: status
        )
        state = next
        fileURL = next == .ready ? url : nil
        if next == .loading { waitForDownload(of: url) }
    }

    /// Asks the provider to fetch the file and checks back until it arrives, so
    /// a cloud file that is not on the device yet opens by itself when ready.
    private func waitForDownload(of url: URL) {
        downloadTask?.cancel()
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        downloadTask = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                if Self.downloadStatus(of: url) == .local {
                    self.evaluate()
                    return
                }
            }
            // Gave up waiting: report it as unreadable rather than spinning,
            // and stop holding the file open.
            self?.release()
            self?.state = .accessDenied
        }
    }

    nonisolated static func downloadStatus(of url: URL) -> ExternalFileDownloadStatus {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return .local }
        switch values.ubiquitousItemDownloadingStatus {
        case .current?, .downloaded?: return .local
        default: return .notDownloaded
        }
    }
}

extension ExternalFileBookmarkStore {
    static let shared = ExternalFileBookmarkStore(fileURL: defaultFileURL())
}
