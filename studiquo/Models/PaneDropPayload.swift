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
    static let tabPrefixes = ["notebook:", "deck:", "document:", "slide:", "web:", "ai:", "friend:", "group:"]

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
