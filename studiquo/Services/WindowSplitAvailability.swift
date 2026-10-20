import SwiftUI
import UIKit

/// Compare the actual app window with its display, not the editor's content
/// area: a sidebar or keyboard must not disable splitting in a full window.
enum WindowSplitAvailability {
    static func allowsSplit(windowWidth: CGFloat, displayWidth: CGFloat) -> Bool {
        guard windowWidth.isFinite, displayWidth.isFinite,
              windowWidth > 0, displayWidth > 0 else { return false }
        // Allow for the system divider and rounding around a half-width window.
        return windowWidth > displayWidth / 2 + 16
    }
}

/// Reads only the window containing this editor, including in multi-window use.
struct WindowSplitAvailabilityReader: UIViewRepresentable {
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> WindowSplitAvailabilityProbe {
        let view = WindowSplitAvailabilityProbe()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: WindowSplitAvailabilityProbe, context: Context) {
        uiView.onChange = onChange
        uiView.setNeedsLayout()
    }
}

final class WindowSplitAvailabilityProbe: UIView {
    var onChange: ((Bool) -> Void)?
    private var lastAvailability: Bool?
    private var updateQueued = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportAvailability()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportAvailability()
    }

    private func reportAvailability() {
        guard !updateQueued else { return }
        updateQueued = true
        // Do not mutate SwiftUI state during a layout/update pass. Read the
        // latest geometry when delivered, so rapid resizes cannot apply stale state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateQueued = false
            guard let window = self.window, let scene = window.windowScene else { return }
            let displaySize = scene.screen.bounds.size
            let displayWidth: CGFloat
            if scene.interfaceOrientation.isLandscape {
                displayWidth = max(displaySize.width, displaySize.height)
            } else if scene.interfaceOrientation.isPortrait {
                displayWidth = min(displaySize.width, displaySize.height)
            } else {
                displayWidth = displaySize.width
            }
            var available = WindowSplitAvailability.allowsSplit(
                windowWidth: window.bounds.width,
                displayWidth: displayWidth
            )
            #if DEBUG
            // UI fixtures exercise the half-window controls without touching
            // the simulator's system multitasking interface. Geometry policy
            // and the real window probe are covered separately by unit tests.
            if ProcessInfo.processInfo.arguments.contains("--half-width-window-ui-test") {
                available = false
            }
            #endif
            guard available != self.lastAvailability else { return }
            self.lastAvailability = available
            self.onChange?(available)
        }
    }
}
