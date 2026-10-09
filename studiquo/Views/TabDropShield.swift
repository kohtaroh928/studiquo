import SwiftUI
import UIKit

/// A transparent layer over a web view that receives a tab dragged from the top tab
/// bar while leaving every touch to the page underneath.
///
/// A `WKWebView` takes dropped text for itself, so a SwiftUI `dropDestination` around
/// it never hears about a tab dropped on the page. This view sits on top instead, with
/// its own `UIDropInteraction`. It takes part only while a tab is being dragged
/// (`TabDragState`) and then only for the drag-and-drop hit test; every real touch,
/// press, scroll and hover — and any other drag, such as selected text — still reaches
/// the page underneath.
struct TabDropShield: UIViewRepresentable {
    /// Returns `true` when the tab was used.
    var onTab: (String) -> Bool

    func makeUIView(context: Context) -> ShieldView {
        let view = ShieldView()
        view.backgroundColor = .clear
        view.onTab = onTab
        view.addInteraction(UIDropInteraction(delegate: view))
        return view
    }

    func updateUIView(_ view: ShieldView, context: Context) {
        view.onTab = onTab
    }

    final class ShieldView: UIView, UIDropInteractionDelegate {
        var onTab: ((String) -> Bool)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Not a tab drag: the page owns everything, including its own text drags.
            guard TabDragState.shared.isActive else { return nil }
            if let event {
                switch event.type {
                case .touches, .presses, .scroll, .hover, .transform, .motion, .remoteControl:
                    // A real touch, scroll or hover belongs to the web page underneath.
                    return nil
                @unknown default:
                    // The drag-and-drop probe arrives with an event of a type UIKit does
                    // not document (observed: raw value 9), not with `nil`.
                    break
                }
            }
            return super.hitTest(point, with: event)
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            TabDragState.shared.end()
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            session.loadObjects(ofClass: NSString.self) { [weak self] items in
                guard let value = (items.first as? NSString).map({ $0 as String }),
                      PaneDropPayload.isTab(value) else { return }
                DispatchQueue.main.async { _ = self?.onTab?(value) }
            }
        }
    }
}
