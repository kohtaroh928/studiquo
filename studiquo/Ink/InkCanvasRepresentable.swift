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
    /// When set, a pencil drag on the canvas defines this shape's bounding
    /// box instead of drawing freehand ink; lifting commits it and calls
    /// `onShapeCommitted`.
    var pendingShapeKind: InkCanvasView.ShapeKind?
    var onActivate: () -> Void = {}
    var onShapeCommitted: () -> Void = {}

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
            coordinator.freezeAncestorScrolling()
        }
        view.onStrokeEnded = { [coordinator = context.coordinator] in
            coordinator.unfreezeAncestorScrolling()
        }
        view.onShapeCommitted = { [coordinator = context.coordinator] in
            coordinator.parent.onShapeCommitted()
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
                coordinator.ancestorScrollViews.append(scrollView)
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
        view.pendingShapeKind = pendingShapeKind
        view.isDrawingEnabled = selectedTool == .pen || selectedTool == .highlighter || selectedTool == .eraser || pendingShapeKind != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: InkCanvasRepresentable
        var lastSyncedVersion = -1
        var hasPatchedAncestors = false
        /// The page list's scroll view and the pinch-zoom container,
        /// discovered once by walking up from the canvas.
        var ancestorScrollViews: [UIScrollView] = []
        init(_ parent: InkCanvasRepresentable) { self.parent = parent }

        /// Stops the page from moving under the pencil for as long as a
        /// stroke is in progress. Pencil touches are excluded from these
        /// scroll views' pan recognisers (see above) so they can drive ink
        /// instead of panning — but that exclusion also means a pencil
        /// touch can never "catch" a scroll view that's still coasting from
        /// a previous finger swipe, the way a normal touch-down would. Left
        /// alone, that residual momentum (or an in-flight zoom bounce) kept
        /// sliding the page under a stationary pencil, so the stroke being
        /// drawn came out shifted and blurred instead of following the tip.
        func freezeAncestorScrolling() {
            for scrollView in ancestorScrollViews {
                scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                scrollView.setZoomScale(scrollView.zoomScale, animated: false)
                scrollView.isScrollEnabled = false
            }
        }

        func unfreezeAncestorScrolling() {
            for scrollView in ancestorScrollViews {
                scrollView.isScrollEnabled = true
            }
        }
    }
}
