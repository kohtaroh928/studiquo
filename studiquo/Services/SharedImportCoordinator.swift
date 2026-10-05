import Foundation

/// Tracks what is waiting in the `SharedInbox` and whether the destination
/// picker should be on screen for it.
///
/// Cancelling the picker keeps the files (nothing is lost) but must not
/// re-present it on every return to the foreground, so cancelled items are
/// remembered and only *new* arrivals pop the picker again. The leftover count
/// stays visible through `pending` for a "choose later" banner.
@MainActor
final class SharedImportCoordinator: ObservableObject {
    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var currentName: String
    }

    @Published private(set) var pending: [SharedInbox.Item] = []
    @Published var isPickingDestination = false
    @Published private(set) var progress: Progress?

    private let inbox: SharedInbox?
    private var dismissed: Set<URL> = []

    var isImporting: Bool { progress != nil }

    init(inbox: SharedInbox? = SharedInbox.standard()) {
        self.inbox = inbox
    }

    /// Re-reads the inbox. Presents the picker only when something has arrived
    /// that the student has not already dismissed.
    func refresh() {
        guard !isImporting else { return }
        pending = inbox?.pendingItems() ?? []
        dismissed.formIntersection(pending.map(\.url))
        if pending.contains(where: { !dismissed.contains($0.url) }) {
            isPickingDestination = true
        }
    }

    /// "Open in…" hands the app file URLs directly; park them in the inbox so
    /// they go through the same destination picker as a share-sheet batch.
    func receive(fileURLs: [URL]) {
        inbox?.enqueue(copying: fileURLs)
        refresh()
    }

    /// Cancelled: keep the files, stop auto-presenting them.
    func dismissPicker() {
        dismissed.formUnion(pending.map(\.url))
        isPickingDestination = false
    }

    /// The student chose "choose later" from the banner.
    func presentPicker() {
        guard !pending.isEmpty else { return }
        dismissed.subtract(pending.map(\.url))
        isPickingDestination = true
    }

    func begin(total: Int) {
        isPickingDestination = false
        progress = Progress(completed: 0, total: total, currentName: "")
    }

    func advance(completed: Int, currentName: String) {
        guard var current = progress else { return }
        current.completed = completed
        current.currentName = currentName
        progress = current
    }

    /// Done with `item`, imported or not — drops it from the inbox.
    func finish(_ item: SharedInbox.Item) {
        inbox?.remove(item)
        pending.removeAll { $0 == item }
    }

    func end() {
        progress = nil
        pending = inbox?.pendingItems() ?? []
    }
}
