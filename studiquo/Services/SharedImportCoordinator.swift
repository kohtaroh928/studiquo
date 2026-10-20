import Foundation

/// Tracks what is waiting in the `SharedInbox` and which of it the destination
/// picker should offer.
///
/// Files are grouped by share (a "batch") and fall into two kinds:
/// - **fresh** — arrived and not yet answered. The picker imports exactly these.
/// - **held** — the student cancelled the picker, or an import could not finish
///   them. They stay on disk but are never mixed into a new share; the student
///   retries or discards them from their own banner.
///
/// Mixing them was the original bug: one new PDF used to drag every leftover
/// from earlier failures into its import.
@MainActor
final class SharedImportCoordinator: ObservableObject {
    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var currentName: String
        /// Pages of the current file rendered so far, and its page count; both
        /// 0 until the file reports them (non-PDFs never do).
        var pageDone = 0
        var pageTotal = 0

        /// 0...1 over the whole batch, counting the current file's pages.
        var fraction: Double {
            guard total > 0 else { return 0 }
            let filePart = pageTotal > 0 ? Double(pageDone) / Double(pageTotal) : 0
            return min(1, (Double(completed) + filePart) / Double(total))
        }
    }

    /// What the picker is currently importing.
    enum PickerSource: Equatable {
        case fresh
        case held
    }

    /// How long a held batch is kept before it is cleaned up.
    static let heldRetention: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var freshBatches: [SharedInbox.PendingBatch] = []
    @Published private(set) var heldBatches: [SharedInbox.PendingBatch] = []
    @Published var isPickingDestination = false
    @Published private(set) var pickerSource: PickerSource = .fresh
    @Published private(set) var progress: Progress?

    private let inbox: SharedInbox?

    var isImporting: Bool { progress != nil }

    /// The files the picker would import right now.
    var pickerItems: [SharedInbox.Item] {
        (pickerSource == .fresh ? freshBatches : heldBatches).flatMap(\.items)
    }

    var heldItems: [SharedInbox.Item] { heldBatches.flatMap(\.items) }

    init(inbox: SharedInbox? = SharedInbox.standard()) {
        self.inbox = inbox
    }

    /// Re-reads the inbox. Presents the picker when something new has arrived.
    func refresh(now: Date = Date()) {
        guard !isImporting else { return }
        inbox?.discardHeld(olderThan: now.addingTimeInterval(-Self.heldRetention))
        reload()
        if !freshBatches.isEmpty && !isPickingDestination {
            pickerSource = .fresh
            isPickingDestination = true
        }
    }

    /// "Open in…" hands the app file URLs directly; park them in the inbox so
    /// they go through the same destination picker as a share-sheet batch.
    func receive(fileURLs: [URL]) {
        inbox?.enqueue(copying: fileURLs)
        refresh()
    }

    /// Cancelled: keep the files, but set them aside so they are not offered
    /// again with the next share.
    func dismissPicker() {
        if pickerSource == .fresh {
            freshBatches.forEach { inbox?.hold($0) }
        }
        isPickingDestination = false
        reload()
    }

    /// The student chose "retry" on the held-files banner.
    func presentHeldPicker() {
        guard !heldBatches.isEmpty else { return }
        pickerSource = .held
        isPickingDestination = true
    }

    /// The student chose to throw the held files away.
    func discardHeld() {
        heldBatches.forEach { inbox?.discard($0) }
        reload()
    }

    func begin(total: Int) {
        isPickingDestination = false
        progress = Progress(completed: 0, total: total, currentName: "")
    }

    func advance(completed: Int, currentName: String) {
        guard var current = progress else { return }
        current.completed = completed
        current.currentName = currentName
        current.pageDone = 0
        current.pageTotal = 0
        progress = current
    }

    /// Page-level progress inside the current file.
    func advancePage(done: Int, of total: Int) {
        guard var current = progress else { return }
        current.pageDone = done
        current.pageTotal = total
        progress = current
    }

    /// Done with `item`, imported or not — drops it from the inbox.
    func finish(_ item: SharedInbox.Item) {
        inbox?.remove(item)
    }

    /// Ends an import. Whatever of `attempted` is still on disk could not be
    /// imported, so its batch is held for a later retry instead of staying
    /// "new".
    func end(attempted: [SharedInbox.Item]) {
        progress = nil
        let folders = Set(attempted.map { $0.url.deletingLastPathComponent() })
        for batch in inbox?.pendingBatches() ?? [] where folders.contains(batch.folder) {
            inbox?.hold(batch)
        }
        reload()
    }

    private func reload() {
        let batches = inbox?.pendingBatches() ?? []
        freshBatches = batches.filter { !$0.isHeld }
        heldBatches = batches.filter(\.isHeld)
    }
}
