import SwiftUI

enum DrawingToolKind: String, CaseIterable {
    case pen, highlighter, eraser, lasso
    /// No tool selected: the canvas doesn't intercept touches at all, so
    /// both finger and Pencil input fall through to the page scroller.
    case none

    /// The tools shown as selectable buttons in the drawing toolbar. `.none`
    /// isn't one of them — it's reached only by tapping the active tool
    /// again to deselect it.
    static let toolbarCases: [DrawingToolKind] = [.pen, .highlighter, .eraser, .lasso]

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .none: "hand.point.up.left"
        }
    }
}

/// SwiftUI bridge for `InkCanvasView`. Mirrors the shape of the old
/// PencilKit-backed `PencilCanvasView` fairly closely so the call site in
/// `PageCanvasContainer` didn't need to change much.
struct InkCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: InkDrawing
    @Binding var selectedTool: DrawingToolKind
    var color: UIColor
    var width: CGFloat
    var eraserWidth: CGFloat = 24
    /// Bumped by the owner whenever it deliberately replaces `drawing`
    /// (initial load, undo/redo). Only then is the value pushed into the
    /// canvas — see `updateUIView`. Live drawing flows the other way, via
    /// `onDrawingChanged`, and never needs this.
    var drawingVersion: Int = 0
    var isScratchOutEnabled: Bool
    var onActivate: () -> Void = {}

    func makeUIView(context: Context) -> InkCanvasView {
        let view = InkCanvasView()
        view.setDrawing(drawing)
        context.coordinator.lastSyncedVersion = drawingVersion
        applyConfiguration(to: view)
        view.onDrawingChanged = { [coordinator = context.coordinator] newValue in
            coordinator.parent.drawing = newValue
        }
        view.onStrokeBegan = { [coordinator = context.coordinator] in
            coordinator.parent.onActivate()
        }
        return view
    }

    func updateUIView(_ view: InkCanvasView, context: Context) {
        restrictAncestorScrollViewsToFingerTouches(from: view, coordinator: context.coordinator)
        context.coordinator.parent = self
        if context.coordinator.lastSyncedVersion != drawingVersion {
            view.setDrawing(drawing)
            context.coordinator.lastSyncedVersion = drawingVersion
        }
        applyConfiguration(to: view)
    }

    /// Ancestor scroll views (the page list, and the pinch-zoom container)
    /// accept Apple Pencil touches for panning by default. If one of them
    /// wins the gesture arbitration, the pencil pans the page instead of
    /// drawing on it — restricting them to finger touches keeps the pencil
    /// exclusively for ink.
    private func restrictAncestorScrollViewsToFingerTouches(from view: UIView, coordinator: Coordinator) {
        guard !coordinator.hasPatchedAncestors else { return }
        var patched = 0
        var current: UIView? = view.superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView {
                scrollView.panGestureRecognizer.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue)
                ]
                scrollView.delaysContentTouches = false
                patched += 1
            }
            current = candidate.superview
        }
        if patched > 0 { coordinator.hasPatchedAncestors = true }
    }

    private func applyConfiguration(to view: InkCanvasView) {
        view.strokeColorHex = color.toHex()
        view.strokeWidth = width
        view.eraserWidth = eraserWidth
        view.isScratchOutEnabled = isScratchOutEnabled
        view.isHighlighter = selectedTool == .highlighter
        view.isEraser = selectedTool == .eraser
        view.isDrawingEnabled = selectedTool == .pen || selectedTool == .highlighter || selectedTool == .eraser
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: InkCanvasRepresentable
        var lastSyncedVersion = -1
        var hasPatchedAncestors = false
        init(_ parent: InkCanvasRepresentable) { self.parent = parent }
    }
}
