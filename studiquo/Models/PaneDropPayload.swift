import SwiftUI

/// What can be dropped on a chat pane: a region cut out of a page, or a tab
/// dragged from the top tab bar.
///
/// A pane must take both through ONE `dropDestination`. Stacking one destination
/// per payload type on the same view does not work: only one of them is consulted,
/// so the other kind of drop is silently ignored — which is how dropping a tab on
/// the AI chat pane stopped switching it the moment page crops were accepted there.
/// (A destination further out does not help either; the innermost one on the view
/// under the finger claims the drag.)
enum PaneDropPayload: Transferable {
    /// How every tab in the top tab bar starts its drag payload. One list, so a pane
    /// cannot quietly stop recognising a kind of tab (the friend chat once did not
    /// know documents, slides or groups, and ignored them).
    static let tabPrefixes = ["notebook:", "deck:", "flashcards:", "document:", "web:", "ai:", "friend:", "group:"]

    static func isTab(_ value: String) -> Bool {
        tabPrefixes.contains { value.hasPrefix($0) }
    }

    case snippet(PageSnippet)
    /// The tab's drag payload, e.g. `notebook:<id>` — see `NoteEditorView.handlePaneDrop`.
    case tab(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (snippet: PageSnippet) in PaneDropPayload.snippet(snippet) })
        ProxyRepresentation(importing: { (value: String) in PaneDropPayload.tab(value) })
    }
}

/// "A tab from the top tab bar is being dragged right now."
///
/// A transparent layer over the Web pane (`TabDropShield`) must catch a tab dropped on
/// the page, but it must NOT catch anything else dragged there — text selected on the
/// page, or a recognised handwriting selection dragged into a field on the page — or
/// those stop working. At the moment UIKit decides which view a drag belongs to, the
/// drag's contents cannot be read, so the only reliable signal is the tab bar saying so
/// when it starts the drag (see `tabDraggable`).
///
/// A drag that is cancelled never reports its end, so the flag also lapses on its own.
final class TabDragState: @unchecked Sendable {
    static let shared = TabDragState()

    private let lock = NSLock()
    private var startedAt: Date?
    private let lifetime: TimeInterval
    private let now: () -> Date

    init(lifetime: TimeInterval = 20, now: @escaping () -> Date = Date.init) {
        self.lifetime = lifetime
        self.now = now
    }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        startedAt = now()
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        startedAt = nil
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt else { return false }
        return now().timeIntervalSince(startedAt) < lifetime
    }
}

extension View {
    /// Makes a tab draggable with the same plain-text payload `.draggable(_:)` would
    /// carry, and tells `TabDragState` that a tab drag has started.
    func tabDraggable(_ payload: String) -> some View {
        onDrag {
            TabDragState.shared.begin()
            return NSItemProvider(object: payload as NSString)
        }
    }
}
