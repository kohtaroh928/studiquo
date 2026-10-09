import Foundation

/// Holds security-scoped access to one file the user picked from outside the
/// app, for exactly as long as the object is alive.
///
/// Every other security-scoped call in the app starts and stops inside one
/// function while it copies the file in. Opening a file in place keeps the
/// access open for as long as the pane shows it, so the start/stop pairing is
/// owned by this type: it starts in `init`, and stops once — in `release()` or
/// at the latest in `deinit` — however the pane goes away.
final class ScopedFileAccess {
    let url: URL
    private var isAccessing: Bool
    private let stop: (URL) -> Void

    init(
        url: URL,
        start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.url = url
        self.isAccessing = start(url)
        self.stop = stop
    }

    /// Whether the system granted scoped access. A URL that is not
    /// security-scoped (a file inside the app's own container) reports false
    /// and is still readable, so this is informational, not an error.
    var hasScopedAccess: Bool { isAccessing }

    /// Stops access. Safe to call more than once.
    func release() {
        guard isAccessing else { return }
        isAccessing = false
        stop(url)
    }

    deinit {
        release()
    }
}
