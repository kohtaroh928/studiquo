import UIKit

private extension Notification.Name {
    static let studiquoInkSelectionTransfer = Notification.Name("StudiquoInkSelectionTransfer")
}

/// Broadcast when a lasso selection is dropped outside the canvas it was
/// drawn on. Every `InkCanvasView` on screen — both split panes — observes
/// this, and whichever one's bounds contain the drop point claims it by
/// setting `wasAccepted`; the source canvas checks that flag afterward to
/// know whether to actually remove the strokes it sent.
private final class InkSelectionTransfer {
    let drawing: InkDrawing
    let screenPoint: CGPoint
    let screenSize: CGSize
    var wasAccepted = false

    init(drawing: InkDrawing, screenPoint: CGPoint, screenSize: CGSize) {
        self.drawing = drawing
        self.screenPoint = screenPoint
        self.screenSize = screenSize
    }
}

/// A from-scratch drawing surface: this app's own engine, replacing
/// PencilKit for the pen tool.
///
/// Built because PencilKit gives no access to an in-progress stroke, so
/// "hold still and it snaps straight" could only ever apply after the pencil
/// lifted. Owning capture and rendering means the straighten (and the
/// scribble-to-erase hit test) can run live, against the actual stroke, while
/// the pencil is still down — matching the reference video instead of
/// approximating it.
final class InkCanvasView: UIView, UIDragInteractionDelegate {
    enum ShapeKind: String {
        // A straight line is what the line-correction already produces from
        // an ordinary pencil stroke, so a separate tool for it was one more
        // thing in the menu that did nothing new.
        case rectangle, ellipse
    }

    // MARK: Configuration

    var strokeColorHex: String = "#1C1C1E"
    var strokeWidth: CGFloat = 4
    var isHighlighter = false
    var isScratchOutEnabled = true
    var isLineCorrectionEnabled = true
    var isEllipseCorrectionEnabled = true
    var isRectangleCorrectionEnabled = true
    var isTriangleCorrectionEnabled = true
    var isParabolaCorrectionEnabled = true
    /// Fits the stroke to the closest ordinary function — cubic, sine,
    /// exponential, logarithm, reciprocal — for curves a parabola cannot
    /// describe. Convex arcs are caught by the parabola check before this
    /// one runs, so they stay quadratic.
    var isCurveCorrectionEnabled = true
    var isEraser = false {
        didSet { if !isEraser { hideEraserCursor() } }
    }
    var isLasso = false {
        didSet {
            if !isLasso { clearLassoSelection() }
        }
    }
    /// Rectangular region select. Unlike the lasso, which picks out strokes,
    /// this cuts out a picture of whatever the page shows there — printed
    /// PDF text included — so it works on imported material the app never
    /// drew.
    var isSnipping = false {
        didSet { if !isSnipping { cancelSnip() } }
    }
    var eraserWidth: CGFloat = 24 {
        didSet {
            if let eraserCursorLocation { showEraserCursor(at: eraserCursorLocation) }
        }
    }
    /// When set, a pencil drag defines the shape's bounding box live —
    /// instead of freehand ink — and lifting commits it. Takes priority over
    /// every other tool state while non-nil.
    var pendingShapeKind: ShapeKind? {
        didSet {
            guard pendingShapeKind != oldValue else { return }
            shapeDragStart = nil
            shapeDragCurrent = nil
            liveLayer.path = nil
        }
    }
    /// When false the view takes no touches at all — the "no tool selected,
    /// just scroll" state.
    var isDrawingEnabled = true {
        didSet { isUserInteractionEnabled = isDrawingEnabled }
    }

    /// How long the pencil must stay put at a stroke's end for it to snap to
    /// a straight line, with the snap visible immediately, live, while the
    /// pencil is still down.
    var straightenHoldDuration: TimeInterval = 0.4

    var onDrawingChanged: ((InkDrawing) -> Void)?
    var onStrokeBegan: (() -> Void)?
    /// A tap that produced no stroke — see the recogniser in `commonInit`.
    var onBackgroundTap: (() -> Void)?
    /// Fired once the pencil lifts (or the touch is cancelled), whatever the
    /// outcome — a committed stroke, an erase, or nothing. The representable
    /// uses this to let ancestor scroll views move again once it's safe.
    var onStrokeEnded: (() -> Void)?
    /// Fired after a dragged shape is committed, with the kind and its
    /// bounding box in page units.
    ///
    /// The canvas no longer draws the shape itself. A shape the student can
    /// still move, resize and rotate afterwards has to be a page element, and
    /// elements live outside this view — so the canvas reports the geometry
    /// and the owner builds the element. The owner also uses this to return
    /// to the pen instead of leaving the shape tool silently armed.
    var onShapeCommitted: ((ShapeKind, CGRect) -> Void)?
    /// The rectangle the snip tool just drew, in page units. The canvas
    /// reports the geometry only — it holds ink, not the page background, so
    /// it is in no position to render the crop itself.
    var onSnipCaptured: ((CGRect) -> Void)?
    /// Where the eraser has just passed, in page units, with its radius.
    ///
    /// Shapes are page elements now, and elements are not this view's to
    /// erase — so the sweep is reported and the owner decides which of them
    /// the eraser touched.
    var onEraseSwept: (([CGPoint], CGFloat) -> Void)?
    /// Supplies only the currently lasso-selected strokes. The SwiftUI owner
    /// uses this small drawing for on-device OCR and never scans the rest of
    /// the notebook.
    var onSelectionChanged: ((InkDrawing?) -> Void)?
    var onSelectionDragMoved: ((UIImage?, CGSize?, CGPoint?) -> Void)?
    var onSelectionDropped: ((String, CGPoint) -> Void)?
    /// OCR text exported when the retained lasso selection is lifted into an
    /// iPad system drag. Using UIDragInteraction lets the preview leave this
    /// clipped page and cross into the other split pane.
    var selectionDragText = ""
    /// Turned off when both split panes show the same notebook: moving ink
    /// from one canvas to the other would take it out of a page and put it
    /// back into that same page, which has no coherent meaning.
    var allowsSelectionTransfer = true

    /// Display points per page unit.
    ///
    /// Stroke data lives in the page's own coordinate space, not in whatever
    /// size this view happens to be. Touches are divided by this on the way
    /// in and the ink layers are scaled by it on the way out, so the same
    /// page renders identically at any width — full screen, in a split pane,
    /// or rasterised for export. Before this existed, ink was stored in
    /// on-screen points and splitting the editor threw every stroke off the
    /// page.
    var contentScale: CGFloat = 1 {
        didSet {
            guard abs(contentScale - oldValue) > 0.0001 else { return }
            setNeedsLayout()
        }
    }

    /// The page-space size this view covers at the current scale.
    private var canvasSize: CGSize {
        let scale = max(contentScale, 0.0001)
        return CGSize(width: bounds.width / scale, height: bounds.height / scale)
    }

    /// Screen point -> page point. Every touch location must go through this.
    private func pagePoint(_ point: CGPoint) -> CGPoint {
        let scale = max(contentScale, 0.0001)
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    /// Page point -> this view's own coordinates, for the two places that
    /// have to hand ink positions to UIKit (`convert(_:to:)` for the drag
    /// preview, and the incoming cross-pane transfer).
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * contentScale, y: point.y * contentScale)
    }

    private(set) var drawing = InkDrawing() {
        didSet { onDrawingChanged?(drawing) }
    }

    /// Replaces the drawing without notifying `onDrawingChanged` — for
    /// loading from disk or undo/redo, where echoing back out would be
    /// redundant (and, for undo/redo, actively wrong).
    func setDrawing(_ newValue: InkDrawing) {
        clearLassoSelection()
        drawing = newValue
        rebuildCommittedLayers()
    }

    // MARK: Layers

    /// One sublayer per finished stroke, each with its own colour — strokes
    /// are drawn in different colours, so a single flattened path (and one
    /// `fillColor`) can't represent them. Rebuilt only when a stroke is
    /// added, removed, or replaced — not on every touch move, so
    /// panning/zooming the page never has to re-rasterise old ink.
    private let committedContainer = CALayer()
    private var strokeLayers: [UUID: CAShapeLayer] = [:]
    /// The stroke currently being drawn, on its own layer so committing it
    /// never has to touch — or repaint — anything already on the page.
    private let liveLayer = CAShapeLayer()
    /// Dashed freehand outline while lassoing, retained around the selected
    /// strokes until their following move finishes.
    private let selectionLayer = CAShapeLayer()
    /// The snip tool's marquee. Kept separate from `selectionLayer` so
    /// switching between the two tools can't leave one tool's outline behind
    /// on the other's canvas.
    private let snipLayer = CAShapeLayer()
    private let eraserCursorLayer = CAShapeLayer()

    private var snipStart: CGPoint?
    private var snipCurrent: CGPoint?

    /// Wholesale rebuild — for loading a page and undo/redo, where every
    /// stroke is legitimately new to this view. NOT used for a normal
    /// draw-a-stroke commit: reassigning `.path` on every *other* stroke's
    /// layer (even to the same value it already had) still counts as a
    /// change to CAShapeLayer's implicitly-animatable `path` property, so
    /// the whole page would flash on every single stroke.
    private func rebuildCommittedLayers() {
        withoutImplicitAnimations {
            for shapeLayer in strokeLayers.values { shapeLayer.removeFromSuperlayer() }
            strokeLayers.removeAll()
            for stroke in drawing.strokes { addCommittedLayer(for: stroke) }
        }
    }

    /// Disables CAShapeLayer's default implicit fade so committing a stroke
    /// (or removing one) is instant rather than a brief cross-fade — this is
    /// what "flickers" when it isn't disabled.
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    @discardableResult
    private func addCommittedLayer(for stroke: InkStroke) -> CAShapeLayer {
        let shapeLayer = CAShapeLayer()
        shapeLayer.fillRule = .nonZero
        shapeLayer.path = Self.ribbon(for: stroke).cgPath
        shapeLayer.fillColor = UIColor(inkHex: stroke.colorHex).cgColor
        shapeLayer.opacity = Float(stroke.opacity)
        committedContainer.addSublayer(shapeLayer)
        strokeLayers[stroke.id] = shapeLayer
        return shapeLayer
    }

    private func removeCommittedLayers(ids: Set<UUID>) {
        for id in ids {
            strokeLayers[id]?.removeFromSuperlayer()
            strokeLayers.removeValue(forKey: id)
        }
    }

    // MARK: Live stroke state

    private var rawPoints: [InkPoint] = []
    private var strokeStartedAt: Date?
    private var lastMovementAt: Date?
    private var lastMovementLocation: CGPoint?
    private var isStraightened = false
    private var isEllipseLocked = false
    private var isRectangleLocked = false
    private var isTriangleLocked = false
    private var isParabolaLocked = false
    private var lockedShapeBounds: CGRect?
    private var lockedShapeFixedCorner: CGPoint?
    private var lockedNormalizedPoints: [InkPoint]?
    private var holdTimer: Timer?
    private var strokeStartLocation: CGPoint?
    private var shapeDragStart: CGPoint?
    private var shapeDragCurrent: CGPoint?
    private var lassoPoints: [CGPoint] = []
    private var selectionPolygon: [CGPoint] = []
    private var selectedStrokeIDs: Set<UUID> = []
    private var selectionDragStart: CGPoint?
    private var selectionDragOffset: CGPoint = .zero
    private var isSelectionOutsideCanvas = false
    private var eraserCursorLocation: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        liveLayer.fillRule = .nonZero
        layer.addSublayer(committedContainer)
        layer.addSublayer(liveLayer)
        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineCap = .round
        selectionLayer.lineJoin = .round
        selectionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(selectionLayer)
        snipLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
        snipLayer.strokeColor = UIColor.systemBlue.cgColor
        snipLayer.lineWidth = 1.5
        snipLayer.lineDashPattern = [6, 4]
        layer.addSublayer(snipLayer)
        eraserCursorLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.10).cgColor
        eraserCursorLayer.strokeColor = UIColor.systemGray.withAlphaComponent(0.85).cgColor
        eraserCursorLayer.lineWidth = 1.2
        eraserCursorLayer.isHidden = true
        layer.addSublayer(eraserCursorLayer)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleEraserHover(_:))))
        // A tap on the page, distinct from a stroke. Used to put a selected
        // photo or text box down; it never cancels drawing, because a tap by
        // definition involves no movement.
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        backgroundTap.cancelsTouchesInView = false
        addGestureRecognizer(backgroundTap)
        addInteraction(UIDragInteraction(delegate: self))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(receiveInkSelectionTransfer(_:)),
            name: .studiquoInkSelectionTransfer,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The ink layers are laid out in page units and then scaled up to
        // fill the view, so every path in them — strokes, the lasso marquee,
        // the eraser cursor — can be built from page coordinates directly.
        let pageBounds = CGRect(origin: .zero, size: canvasSize)
        let scale = CATransform3DMakeScale(max(contentScale, 0.0001), max(contentScale, 0.0001), 1)
        for inkLayer in [committedContainer, liveLayer, selectionLayer, snipLayer, eraserCursorLayer] {
            // Anchored top-left so the scale grows away from the page origin
            // rather than out from the middle of the view.
            inkLayer.anchorPoint = .zero
            inkLayer.bounds = pageBounds
            inkLayer.position = .zero
            inkLayer.transform = scale
        }
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The snip tool is pencil-only. A finger must stay free for page
        // scrolling, otherwise a normal scroll can accidentally become a
        // question/answer crop.
        if isSnipping, let touch = touches.first, touch.type == .pencil {
            onStrokeBegan?()
            let location = pagePoint(touch.location(in: self))
            snipStart = location
            snipCurrent = location
            updateSnipPreview()
            return
        }

        guard isDrawingEnabled, let touch = touches.first, touch.type == .pencil else { return }
        guard rawPoints.isEmpty, shapeDragStart == nil else { return } // ignore a second finger/pencil mid-stroke

        if let kind = pendingShapeKind {
            onStrokeBegan?()
            let location = pagePoint(touch.location(in: self))
            shapeDragStart = location
            shapeDragCurrent = location
            updateShapePreview(kind: kind)
            return
        }

        if isLasso {
            onStrokeBegan?()
            beginLasso(at: pagePoint(touch.location(in: self)))
            return
        }

        onStrokeBegan?()
        let now = Date()
        strokeStartedAt = now
        lastMovementAt = now
        isStraightened = false
        isEllipseLocked = false
        isRectangleLocked = false
        isTriangleLocked = false
        isParabolaLocked = false
        lockedShapeBounds = nil
        lockedShapeFixedCorner = nil
        lockedNormalizedPoints = nil
        let location = pagePoint(touch.location(in: self))
        strokeStartLocation = location
        lastMovementLocation = location
        rawPoints = [InkPoint(location: location, force: normalizedForce(touch), timeOffset: 0)]

        if isEraser {
            showEraserCursor(at: location)
            eraseParts(along: [location])
            onEraseSwept?([location], eraserWidth / 2)
        } else {
            updateLiveLayer()
            startHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isSnipping, snipStart != nil, let touch = touches.first, touch.type == .pencil {
            snipCurrent = pagePoint(touch.location(in: self))
            updateSnipPreview()
            return
        }

        guard let touch = touches.first, touch.type == .pencil else { return }

        if let kind = pendingShapeKind, shapeDragStart != nil {
            shapeDragCurrent = pagePoint(touch.location(in: self))
            updateShapePreview(kind: kind)
            return
        }


        if isLasso {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            moveLasso(to: samples.map { pagePoint($0.location(in: self)) })
            return
        }

        guard strokeStartedAt != nil else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let previousEraserLocation = rawPoints.last?.location
        for sample in samples {
            appendSample(sample)
        }
        if isEraser {
            let path = [previousEraserLocation].compactMap { $0 } + samples.map { pagePoint($0.location(in: self)) }
            if let location = path.last { showEraserCursor(at: location) }
            eraseParts(along: path)
            onEraseSwept?(path, eraserWidth / 2)
        } else if !isStraightened && !isEllipseLocked && !isRectangleLocked
                    && !isTriangleLocked && !isParabolaLocked {
            updateLiveLayer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isSnipping, snipStart != nil {
            if let touch = touches.first, touch.type == .pencil {
                snipCurrent = pagePoint(touch.location(in: self))
            }
            finishSnip()
            onStrokeEnded?()
            return
        }

        guard let touch = touches.first, touch.type == .pencil else { return }

        if let kind = pendingShapeKind, let start = shapeDragStart {
            let end = pagePoint(touch.location(in: self))
            commitShape(kind: kind, from: start, to: end)
            shapeDragStart = nil
            shapeDragCurrent = nil
            liveLayer.path = nil
            onStrokeEnded?()
            return
        }

        if isLasso {
            endLasso(at: pagePoint(touch.location(in: self)))
            onStrokeEnded?()
            return
        }

        guard strokeStartedAt != nil else { return }
        let previousEraserLocation = rawPoints.last?.location
        appendSample(touch)
        if isEraser {
            let path = [previousEraserLocation, Optional(pagePoint(touch.location(in: self)))].compactMap { $0 }
            eraseParts(along: path)
            hideEraserCursor()
        }
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Rectangular snip

    private var snipRect: CGRect? {
        guard let start = snipStart, let current = snipCurrent else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func updateSnipPreview() {
        guard let rect = snipRect else { return }
        withoutImplicitAnimations { snipLayer.path = UIBezierPath(rect: rect).cgPath }
    }

    private func finishSnip() {
        defer { cancelSnip() }
        guard let rect = snipRect else { return }
        // A tap, or a sliver, is a miss rather than a selection — reporting
        // it would hand the AI a few blank pixels.
        guard rect.width >= 16, rect.height >= 16 else { return }
        onSnipCaptured?(rect.intersection(CGRect(origin: .zero, size: canvasSize)))
    }

    private func cancelSnip() {
        snipStart = nil
        snipCurrent = nil
        withoutImplicitAnimations { snipLayer.path = nil }
    }

    private func appendSample(_ touch: UITouch) {
        guard let start = strokeStartedAt else { return }
        let location = pagePoint(touch.location(in: self))
        rawPoints.append(InkPoint(
            location: location,
            force: normalizedForce(touch),
            timeOffset: Date().timeIntervalSince(start)
        ))

        let moved = lastMovementLocation.map { hypot(location.x - $0.x, location.y - $0.y) > 6 } ?? true
        if moved {
            lastMovementLocation = location
            lastMovementAt = Date()
            if isStraightened {
                // The pencil moved on after snapping: keep it a straight
                // line, just extend the far end to follow, ruler-style.
                emitStraightPreview(to: location)
            } else if isEllipseLocked {
                updateLockedShapeBounds(to: location, snapToSquare: false)
                emitEllipsePreview()
            } else if isRectangleLocked {
                updateLockedShapeBounds(to: location, snapToSquare: true)
                emitRectanglePreview()
            } else if isTriangleLocked || isParabolaLocked {
                updateLockedShapeBounds(to: location, snapToSquare: false)
                emitNormalizedShapePreview()
            } else {
                startHoldTimer()
            }
        }
    }

    // MARK: Lasso selection

    private func beginLasso(at location: CGPoint) {
        if !selectedStrokeIDs.isEmpty, Self.point(location, isInside: selectionPolygon) {
            selectionDragStart = location
            selectionDragOffset = .zero
            return
        }
        clearLassoSelection()
        lassoPoints = [location]
        updateLassoPath(lassoPoints)
    }

    private func moveLasso(to locations: [CGPoint]) {
        guard !locations.isEmpty else { return }
        if let start = selectionDragStart {
            guard let location = locations.last else { return }
            selectionDragOffset = CGPoint(x: location.x - start.x, y: location.y - start.y)
            if !CGRect(origin: .zero, size: canvasSize).contains(location) {
                isSelectionOutsideCanvas = true
                withoutImplicitAnimations {
                    for id in selectedStrokeIDs {
                        strokeLayers[id]?.setAffineTransform(.identity)
                        strokeLayers[id]?.isHidden = true
                    }
                }
                let preview = selectionPreview()
                onSelectionDragMoved?(preview?.image, preview?.screenSize, convert(location, to: nil))
                return
            }
            if isSelectionOutsideCanvas {
                isSelectionOutsideCanvas = false
                withoutImplicitAnimations {
                    for id in selectedStrokeIDs { strokeLayers[id]?.isHidden = false }
                }
                onSelectionDragMoved?(nil, nil, nil)
            }
            let transform = CGAffineTransform(translationX: selectionDragOffset.x, y: selectionDragOffset.y)
            withoutImplicitAnimations {
                for id in selectedStrokeIDs { strokeLayers[id]?.setAffineTransform(transform) }
            }
            let movedOutline = selectionPolygon.map {
                CGPoint(x: $0.x + selectionDragOffset.x, y: $0.y + selectionDragOffset.y)
            }
            updateLassoPath(movedOutline)
        } else {
            for location in locations {
                if let last = lassoPoints.last, hypot(location.x - last.x, location.y - last.y) < 1 { continue }
                lassoPoints.append(location)
            }
            updateLassoPath(lassoPoints)
        }
    }

    private func endLasso(at location: CGPoint) {
        if selectionDragStart != nil {
            if isSelectionOutsideCanvas {
                let screenPoint = convert(location, to: nil)
                let preview = selectionPreview()
                if allowsSelectionTransfer, let preview {
                    let transfer = InkSelectionTransfer(
                        drawing: InkDrawing(strokes: drawing.strokes.filter { selectedStrokeIDs.contains($0.id) }),
                        screenPoint: screenPoint,
                        screenSize: preview.screenSize
                    )
                    NotificationCenter.default.post(name: .studiquoInkSelectionTransfer, object: transfer)
                    if transfer.wasAccepted {
                        drawing.strokes.removeAll { selectedStrokeIDs.contains($0.id) }
                        rebuildCommittedLayers()
                    }
                }
                onSelectionDragMoved?(nil, nil, nil)
                if !selectionDragText.isEmpty {
                    onSelectionDropped?(selectionDragText, screenPoint)
                }
                clearLassoSelection()
                return
            }
            commitSelectionMove()
            return
        }

        if let last = lassoPoints.last, hypot(location.x - last.x, location.y - last.y) >= 1 {
            lassoPoints.append(location)
        }
        guard lassoPoints.count >= 8,
              let first = lassoPoints.first, let last = lassoPoints.last else {
            clearLassoSelection()
            return
        }
        let bounds = lassoPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        let closureTolerance = max(18, hypot(bounds.width, bounds.height) * 0.18)
        guard bounds.width >= 12, bounds.height >= 12,
              hypot(last.x - first.x, last.y - first.y) <= closureTolerance else {
            clearLassoSelection()
            return
        }

        selectionPolygon = lassoPoints + [first]
        selectedStrokeIDs = Set(drawing.strokes.compactMap { stroke in
            // Sample along every segment, not only at the stored touch
            // points. A corrected straight line may contain just its two end
            // points; enclosing the middle must still select the whole line.
            let samples = Self.selectionSamples(for: stroke.points)
            guard !samples.isEmpty else { return nil }
            return samples.contains { Self.point($0, isInside: selectionPolygon) } ? stroke.id : nil
        })
        guard !selectedStrokeIDs.isEmpty else {
            clearLassoSelection()
            return
        }
        lassoPoints = []
        updateLassoPath(selectionPolygon)
        onSelectionChanged?(InkDrawing(strokes: drawing.strokes.filter { selectedStrokeIDs.contains($0.id) }))
    }

    private func commitSelectionMove() {
        let offset = selectionDragOffset
        withoutImplicitAnimations {
            for id in selectedStrokeIDs { strokeLayers[id]?.setAffineTransform(.identity) }
            for id in selectedStrokeIDs { strokeLayers[id]?.isHidden = false }
        }
        if abs(offset.x) > 0.01 || abs(offset.y) > 0.01 {
            var movedDrawing = drawing
            movedDrawing.strokes = drawing.strokes.map { stroke in
                guard selectedStrokeIDs.contains(stroke.id) else { return stroke }
                var moved = stroke
                moved.points = stroke.points.map { point in
                    var copy = point
                    copy.location = CGPoint(x: point.location.x + offset.x, y: point.location.y + offset.y)
                    return copy
                }
                return moved
            }
            drawing = movedDrawing
            rebuildCommittedLayers()
        }
        clearLassoSelection()
    }

    private func updateLassoPath(_ points: [CGPoint]) {
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        withoutImplicitAnimations { selectionLayer.path = path.cgPath }
    }

    private func clearLassoSelection() {
        let hadSelection = !selectedStrokeIDs.isEmpty
        withoutImplicitAnimations {
            // Dragging outside the canvas hides these layers (see
            // `moveLasso`) so the ghost preview reads as "lifted off the
            // page." If the drop lands nowhere that accepts it, that hide
            // must still be undone here — otherwise the strokes stay
            // invisible (though still present in `drawing`) until something
            // else forces a full relayout.
            for id in selectedStrokeIDs {
                strokeLayers[id]?.setAffineTransform(.identity)
                strokeLayers[id]?.isHidden = false
            }
            selectionLayer.setAffineTransform(.identity)
            selectionLayer.path = nil
        }
        lassoPoints = []
        selectionPolygon = []
        selectedStrokeIDs = []
        selectionDragStart = nil
        selectionDragOffset = .zero
        isSelectionOutsideCanvas = false
        if hadSelection { onSelectionChanged?(nil) }
    }

    /// Fires on every `InkCanvasView` when a lasso selection is dropped
    /// outside its source canvas — this one claims it only if the drop point
    /// actually lands inside its own bounds, converting the strokes' scale
    /// and position from the source's coordinate space into its own so the
    /// drawing lands where the ghost preview was released, not where it
    /// happens to fall in raw source coordinates.
    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        onBackgroundTap?()
    }

    @objc private func receiveInkSelectionTransfer(_ notification: Notification) {
        guard allowsSelectionTransfer,
              let transfer = notification.object as? InkSelectionTransfer,
              !transfer.wasAccepted,
              window != nil else { return }
        let localCenter = pagePoint(convert(transfer.screenPoint, from: nil))
        guard CGRect(origin: .zero, size: canvasSize).contains(localCenter),
              let first = transfer.drawing.strokes.first else { return }

        let sourceBounds = transfer.drawing.strokes.dropFirst().reduce(first.bounds) {
            $0.union($1.bounds)
        }
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return }
        let screenTopLeft = CGPoint(
            x: transfer.screenPoint.x - transfer.screenSize.width / 2,
            y: transfer.screenPoint.y - transfer.screenSize.height / 2
        )
        let screenBottomRight = CGPoint(
            x: transfer.screenPoint.x + transfer.screenSize.width / 2,
            y: transfer.screenPoint.y + transfer.screenSize.height / 2
        )
        let localTopLeft = pagePoint(convert(screenTopLeft, from: nil))
        let localBottomRight = pagePoint(convert(screenBottomRight, from: nil))
        let scaleX = abs(localBottomRight.x - localTopLeft.x) / sourceBounds.width
        let scaleY = abs(localBottomRight.y - localTopLeft.y) / sourceBounds.height
        let sourceCenter = CGPoint(x: sourceBounds.midX, y: sourceBounds.midY)
        let widthScale = max(0.01, (scaleX + scaleY) / 2)

        let transferred = transfer.drawing.strokes.map { stroke -> InkStroke in
            var copy = stroke
            copy.id = UUID()
            copy.width *= widthScale
            copy.points = stroke.points.map { point in
                var moved = point
                moved.location = CGPoint(
                    x: localCenter.x + (point.location.x - sourceCenter.x) * scaleX,
                    y: localCenter.y + (point.location.y - sourceCenter.y) * scaleY
                )
                return moved
            }
            return copy
        }
        drawing.strokes.append(contentsOf: transferred)
        rebuildCommittedLayers()
        transfer.wasAccepted = true
    }

    private func selectionPreview() -> (image: UIImage, screenSize: CGSize)? {
        let selected = InkDrawing(strokes: drawing.strokes.filter { selectedStrokeIDs.contains($0.id) })
        guard let first = selected.strokes.first else { return nil }
        let inkBounds = selected.strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        guard inkBounds.width > 0, inkBounds.height > 0 else { return nil }
        let topLeft = convert(viewPoint(CGPoint(x: inkBounds.minX, y: inkBounds.minY)), to: nil)
        let bottomRight = convert(viewPoint(CGPoint(x: inkBounds.maxX, y: inkBounds.maxY)), to: nil)
        let screenSize = CGSize(
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        return (selected.image(from: inkBounds, scale: 2), screenSize)
    }

    // MARK: Cross-pane selection drag

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let location = pagePoint(session.location(in: self))
        guard !selectedStrokeIDs.isEmpty,
              Self.point(location, isInside: selectionPolygon),
              !selectionDragText.isEmpty else { return [] }
        let provider = NSItemProvider(object: selectionDragText as NSString)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = selectionDragText
        return [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: UIDragSession
    ) -> UITargetedDragPreview? {
        let selected = InkDrawing(strokes: drawing.strokes.filter { selectedStrokeIDs.contains($0.id) })
        guard let first = selected.strokes.first else { return nil }
        let inkBounds = selected.strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        guard inkBounds.width > 0, inkBounds.height > 0 else { return nil }
        let imageView = UIImageView(image: selected.image(from: inkBounds, scale: 2))
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: inkBounds.size)
        imageView.backgroundColor = .clear
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedDragPreview(view: imageView, parameters: parameters)
    }

    private static func point(_ point: CGPoint, isInside polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let intersectionX = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < intersectionX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func selectionSamples(for points: [InkPoint]) -> [CGPoint] {
        guard let first = points.first?.location else { return [] }
        guard points.count > 1 else { return [first] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            let steps = max(1, Int(ceil(distance / 4)))
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(
                    x: a.location.x + (b.location.x - a.location.x) * progress,
                    y: a.location.y + (b.location.y - a.location.y) * progress
                ))
            }
        }
        return result
    }

    // MARK: Straighten / circle (live, both triggered by holding still)

    /// Fires `straightenHoldDuration` after the pencil last moved. Which
    /// shape it locks to depends on where it's holding: near the stroke's
    /// own start (the loop has come back around) means a circle; anywhere
    /// else means a straight line to that point.
    private func startHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let since = self.lastMovementAt,
                  !self.isStraightened, !self.isEllipseLocked, !self.isRectangleLocked,
                  !self.isTriangleLocked, !self.isParabolaLocked else { return }
            guard Date().timeIntervalSince(since) >= self.straightenHoldDuration else { return }
            guard let start = self.strokeStartLocation, let current = self.lastMovementLocation else { return }
            let distanceFromStart = hypot(current.x - start.x, current.y - start.y)

            // A scribble is an erase gesture, not a shape to correct. Skip
            // the hold-to-straighten lock so the scribble reaches the erase
            // check on lift instead of being committed as a straightened line.
            if !self.isHighlighter, self.isScratchOutEnabled,
               self.isScribble(self.previewStroke()) {
                return
            }

            if self.isRectangleCorrectionEnabled,
               self.rectangleIfClosedLoop(self.previewStroke()) != nil {
                self.isRectangleLocked = true
                self.prepareLockedShape(at: current, snapToSquare: true)
                self.emitRectanglePreview()
                self.triggerCorrectionFeedback(at: current)
            } else if self.isTriangleCorrectionEnabled,
                      let triangle = self.triangleIfClosedLoop(self.previewStroke()) {
                self.isTriangleLocked = true
                self.prepareLockedNormalizedShape(points: triangle.points, at: current)
                self.emitNormalizedShapePreview()
                self.triggerCorrectionFeedback(at: current)
            } else if self.isParabolaCorrectionEnabled,
                      let parabola = self.parabolaIfRecognized(self.previewStroke()) {
                self.isParabolaLocked = true
                self.prepareLockedNormalizedShape(points: parabola.points, at: current)
                self.emitNormalizedShapePreview()
                self.triggerCorrectionFeedback(at: current)
            } else if self.isCurveCorrectionEnabled,
                      let curve = self.curveIfRecognized(self.previewStroke()) {
                self.isParabolaLocked = true
                self.prepareLockedNormalizedShape(points: curve.points, at: current)
                self.emitNormalizedShapePreview()
                self.triggerCorrectionFeedback(at: current)
            } else if self.isLineCorrectionEnabled,
                      distanceFromStart > 16, !self.looksLikeClosedLoop() {
                self.isStraightened = true
                self.emitStraightPreview(to: current)
                self.triggerCorrectionFeedback(at: current)
            } else if self.isEllipseCorrectionEnabled, self.looksLikeClosedLoop() {
                self.isEllipseLocked = true
                self.prepareLockedShape(at: current, snapToSquare: false)
                self.emitEllipsePreview()
                self.triggerCorrectionFeedback(at: current)
            }
        }
    }

    /// Felt as a snap through the pencil itself: `UICanvasFeedbackGenerator`
    /// is UIKit's canvas-alignment feedback API, which drives Apple Pencil
    /// Pro's haptic engine directly when one is connected. Older iOS falls
    /// back to the device's own Taptic Engine, same as before.
    private func triggerCorrectionFeedback(at point: CGPoint) {
        if #available(iOS 17.5, *) {
            UICanvasFeedbackGenerator(view: self).alignmentOccurred(at: point)
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// True once the stroke drawn so far forms a loop that has come back
    /// close to its own start — the "closing the circle" moment.
    private func looksLikeClosedLoop() -> Bool {
        guard rawPoints.count >= 12, let start = strokeStartLocation, let current = lastMovementLocation else { return false }
        let bounds = InkStroke(points: rawPoints, colorHex: strokeColorHex, width: strokeWidth).bounds
        guard bounds.width >= 24, bounds.height >= 24 else { return false }
        let diagonal = hypot(bounds.width, bounds.height)
        let closureGap = hypot(current.x - start.x, current.y - start.y)
        return closureGap <= diagonal * 0.35
    }

    private func emitEllipsePreview() {
        let bounds = lockedShapeBounds ?? previewStroke().bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let preview = InkStroke(
            points: Self.ellipsePoints(in: bounds),
            colorHex: strokeColorHex,
            width: strokeWidth,
            opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex)
            .withAlphaComponent(isHighlighter ? 0.45 : 1)
            .cgColor
    }

    private func emitRectanglePreview() {
        let bounds = lockedShapeBounds ?? Self.correctedRectangleBounds(
            previewStroke().bounds.insetBy(dx: strokeWidth, dy: strokeWidth))
        guard bounds.width > 0, bounds.height > 0 else { return }
        let preview = InkStroke(
            points: Self.rectanglePoints(in: bounds), colorHex: strokeColorHex,
            width: strokeWidth, opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex)
            .withAlphaComponent(isHighlighter ? 0.45 : 1).cgColor
    }

    private func previewStroke() -> InkStroke {
        InkStroke(points: rawPoints, colorHex: strokeColorHex, width: strokeWidth,
                  opacity: isHighlighter ? 0.45 : 1, isHighlighter: isHighlighter)
    }

    /// Once a closed shape snaps, the corner opposite the Pencil is fixed.
    /// Continuing to drag moves the Pencil-side corner, allowing a circle to
    /// become an ellipse (and back), or a square to become a rectangle.
    private func prepareLockedShape(at pencilLocation: CGPoint, snapToSquare: Bool) {
        var bounds = previewStroke().bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
        if snapToSquare { bounds = Self.correctedRectangleBounds(bounds) }
        lockedShapeBounds = bounds
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        lockedShapeFixedCorner = corners.max {
            hypot($0.x - pencilLocation.x, $0.y - pencilLocation.y)
                < hypot($1.x - pencilLocation.x, $1.y - pencilLocation.y)
        }
    }

    private func updateLockedShapeBounds(to pencilLocation: CGPoint, snapToSquare: Bool) {
        guard let fixed = lockedShapeFixedCorner else { return }
        var bounds = CGRect(
            x: min(fixed.x, pencilLocation.x), y: min(fixed.y, pencilLocation.y),
            width: abs(pencilLocation.x - fixed.x), height: abs(pencilLocation.y - fixed.y)
        )
        guard bounds.width >= 4, bounds.height >= 4 else { return }
        if snapToSquare { bounds = Self.correctedRectangleBounds(bounds) }
        lockedShapeBounds = bounds
    }

    private func prepareLockedNormalizedShape(points: [InkPoint], at pencilLocation: CGPoint) {
        guard let first = points.first else { return }
        let bounds = points.dropFirst().reduce(CGRect(origin: first.location, size: .zero)) {
            $0.union(CGRect(origin: $1.location, size: .zero))
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        lockedShapeBounds = bounds
        lockedNormalizedPoints = points.map { point in
            InkPoint(
                location: CGPoint(x: (point.location.x - bounds.minX) / bounds.width,
                                  y: (point.location.y - bounds.minY) / bounds.height),
                force: point.force, timeOffset: point.timeOffset
            )
        }
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        lockedShapeFixedCorner = corners.max {
            hypot($0.x - pencilLocation.x, $0.y - pencilLocation.y)
                < hypot($1.x - pencilLocation.x, $1.y - pencilLocation.y)
        }
    }

    private func lockedShapePoints() -> [InkPoint] {
        guard let bounds = lockedShapeBounds, let normalized = lockedNormalizedPoints else { return [] }
        return normalized.map { point in
            InkPoint(
                location: CGPoint(x: bounds.minX + point.location.x * bounds.width,
                                  y: bounds.minY + point.location.y * bounds.height),
                force: point.force, timeOffset: point.timeOffset
            )
        }
    }

    private func emitNormalizedShapePreview() {
        let points = lockedShapePoints()
        guard points.count > 1 else { return }
        let preview = InkStroke(points: points, colorHex: strokeColorHex, width: strokeWidth,
                                opacity: isHighlighter ? 0.45 : 1, isHighlighter: isHighlighter)
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex)
            .withAlphaComponent(isHighlighter ? 0.45 : 1).cgColor
    }

    private static func rectanglePoints(in rect: CGRect) -> [InkPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY),
        ]
        return corners.enumerated().map { index, point in
            InkPoint(location: point, force: 0.5, timeOffset: Double(index) / 4)
        }
    }

    private static func correctedRectangleBounds(_ bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let ratio = bounds.width / bounds.height
        guard (0.8...1.25).contains(ratio) else { return bounds }
        let side = (bounds.width + bounds.height) / 2
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                      width: side, height: side)
    }

    private static func ellipsePoints(in bounds: CGRect, steps: Int = 72) -> [InkPoint] {
        let cx = bounds.midX, cy = bounds.midY
        let rx = max(bounds.width / 2, 1), ry = max(bounds.height / 2, 1)
        return (0...steps).map { step in
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            return InkPoint(
                location: CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry),
                force: 0.5,
                timeOffset: TimeInterval(step) / Double(steps)
            )
        }
    }

    private func emitStraightPreview(to endpoint: CGPoint) {
        guard let start = strokeStartLocation else { return }
        let preview = InkStroke(
            points: [
                InkPoint(location: start, force: 0.5, timeOffset: 0),
                InkPoint(location: endpoint, force: 0.5, timeOffset: 1),
            ],
            colorHex: strokeColorHex,
            width: strokeWidth,
            opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex)
            .withAlphaComponent(isHighlighter ? 0.45 : 1)
            .cgColor
    }

    // MARK: Shape tool (drag to create)

    private func updateShapePreview(kind: ShapeKind) {
        guard let start = shapeDragStart, let current = shapeDragCurrent else { return }
        let preview = InkStroke(points: shapePoints(kind: kind, from: start, to: current), colorHex: strokeColorHex, width: strokeWidth)
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex).cgColor
    }

    /// Commits the dragged shape as an ordinary stroke — same undo/erase/
    /// export handling as anything drawn by hand. A drag shorter than this
    /// is treated as an accidental tap rather than a degenerate sliver of a
    /// shape.
    private func commitShape(kind: ShapeKind, from start: CGPoint, to end: CGPoint) {
        guard hypot(end.x - start.x, end.y - start.y) > 8 else { return }
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        onShapeCommitted?(kind, rect)
    }

    private func shapePoints(kind: ShapeKind, from start: CGPoint, to end: CGPoint) -> [InkPoint] {
        switch kind {
        case .rectangle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY),
            ]
            return corners.enumerated().map { index, point in
                InkPoint(location: point, force: 0.6, timeOffset: TimeInterval(index) / 4)
            }
        case .ellipse:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return Self.ellipsePoints(in: rect)
        }
    }

    private func updateLiveLayer() {
        guard rawPoints.count > 1 else { return }
        let preview = InkStroke(
            points: rawPoints,
            colorHex: strokeColorHex,
            width: strokeWidth,
            opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )
        liveLayer.path = Self.path(for: [preview]).cgPath
        liveLayer.fillColor = UIColor(inkHex: strokeColorHex)
            .withAlphaComponent(isHighlighter ? 0.45 : 1)
            .cgColor
    }

    private func finishStroke() {
        holdTimer?.invalidate()
        holdTimer = nil
        defer {
            rawPoints = []
            strokeStartedAt = nil
            strokeStartLocation = nil
            lastMovementLocation = nil
            lastMovementAt = nil
            isStraightened = false
            isEllipseLocked = false
            isRectangleLocked = false
            isTriangleLocked = false
            isParabolaLocked = false
            lockedShapeBounds = nil
            lockedShapeFixedCorner = nil
            lockedNormalizedPoints = nil
            liveLayer.path = nil
            onStrokeEnded?()
        }

        guard !isEraser else { return }

        guard rawPoints.count > 1 else { return }

        let rawStroke = InkStroke(
            points: rawPoints,
            colorHex: strokeColorHex,
            width: strokeWidth,
            opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )

        // Scribble-to-erase is checked first, against the raw points, so a
        // scribble erases even when the hold timer already locked a shape
        // mid-stroke. A scribble that loops back near its own start is still
        // a scribble, not a circle someone drew fast.
        if !isHighlighter, isScratchOutEnabled, isScribble(rawStroke, emitsDiagnostics: true) {
            // Classify first, then run the comparatively expensive hit test.
            // Keeping these stages ordered also prevents an ordinary line
            // which merely touches old ink from entering the erase path.
            let hit = drawing.strokes.filter { strokeIsCoveredBy($0, scribble: rawStroke) }
            GestureDiagnostics.scratchOutRemoval(candidates: drawing.strokes.count, removed: hit.count)
            if !hit.isEmpty {
                let hitIDs = Set(hit.map(\.id))
                drawing.strokes.removeAll { hitIDs.contains($0.id) }
                withoutImplicitAnimations { removeCommittedLayers(ids: hitIDs) }
                return
            }
        }

        var stroke = rawStroke
        if isStraightened, let start = strokeStartLocation, let end = lastMovementLocation {
            stroke.points = [
                InkPoint(location: start, force: 0.5, timeOffset: 0),
                InkPoint(location: end, force: 0.5, timeOffset: 1),
            ]
        } else if isRectangleLocked {
            let bounds = lockedShapeBounds ?? Self.correctedRectangleBounds(
                stroke.bounds.insetBy(dx: strokeWidth, dy: strokeWidth))
            stroke.points = Self.rectanglePoints(in: bounds)
        } else if isEllipseLocked {
            // Locked live, while the pencil was still down — use the exact
            // same fit the on-screen preview was already showing.
            let bounds = lockedShapeBounds ?? stroke.bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
            stroke.points = Self.ellipsePoints(in: bounds)
        } else if isTriangleLocked || isParabolaLocked {
            stroke.points = lockedShapePoints()
        } else {
            // Closed shapes are intentionally not corrected on lift. Like
            // straight lines, they only snap after the Pencil has remained
            // down and still for `straightenHoldDuration`.
        }

        drawing.strokes.append(stroke)
        withoutImplicitAnimations { addCommittedLayer(for: stroke) }
    }

    // MARK: Eraser (bitmap-style: only the touched portions are removed)

    @objc private func handleEraserHover(_ recognizer: UIHoverGestureRecognizer) {
        guard isEraser else { hideEraserCursor(); return }
        switch recognizer.state {
        case .began, .changed:
            showEraserCursor(at: pagePoint(recognizer.location(in: self)))
        default:
            hideEraserCursor()
        }
    }

    private func showEraserCursor(at location: CGPoint) {
        eraserCursorLocation = location
        let radius = max(1, eraserWidth / 2)
        let path = UIBezierPath(ovalIn: CGRect(
            x: location.x - radius, y: location.y - radius,
            width: radius * 2, height: radius * 2
        ))
        withoutImplicitAnimations {
            eraserCursorLayer.path = path.cgPath
            eraserCursorLayer.isHidden = false
        }
    }

    private func hideEraserCursor() {
        eraserCursorLocation = nil
        withoutImplicitAnimations {
            eraserCursorLayer.isHidden = true
            eraserCursorLayer.path = nil
        }
    }

    /// Applies each newly travelled Pencil segment immediately. There is no
    /// faded preview and no work deferred until lift: the visible drawing is
    /// replaced in the same move event in which the eraser crosses it.
    private func eraseParts(along eraserPath: [CGPoint]) {
        guard !eraserPath.isEmpty else { return }
        let radius = max(1, eraserWidth / 2)
        let eraserBounds = eraserPath.dropFirst().reduce(
            CGRect(origin: eraserPath[0], size: .zero)
        ) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -radius - strokeWidth, dy: -radius - strokeWidth)
        var changed = false
        var result: [InkStroke] = []

        for stroke in drawing.strokes {
            guard stroke.bounds.intersects(eraserBounds) else {
                result.append(stroke)
                continue
            }
            let source = Self.isGeneratedPolygon(stroke.points) ? stroke.points : Self.smoothed(stroke.points)
            // Corrected lines store only their two endpoints. Linear
            // resampling makes the entire segment hittable, including its
            // middle, instead of testing only those endpoints.
            let samples = Self.linearlyResampled(source, maxSpacing: max(1, radius * 0.25))
            var runs: [[InkPoint]] = []
            var run: [InkPoint] = []
            for sample in samples {
                let erased = Self.distance(from: sample.location, to: eraserPath) <= radius + stroke.width / 2
                if erased {
                    changed = true
                    if run.count > 1 { runs.append(run) }
                    run = []
                } else {
                    run.append(sample)
                }
            }
            if run.count > 1 { runs.append(run) }

            if runs.isEmpty {
                if !samples.isEmpty && !samples.allSatisfy({ Self.distance(from: $0.location, to: eraserPath) <= radius + stroke.width / 2 }) {
                    result.append(stroke)
                }
            } else if runs.count == 1 && runs[0].count == samples.count {
                result.append(stroke)
            } else {
                for points in runs {
                    var fragment = stroke
                    fragment.id = UUID()
                    fragment.points = points
                    result.append(fragment)
                }
            }
        }

        guard changed else { return }
        drawing.strokes = result
        rebuildCommittedLayers()
    }

    private static func distance(from point: CGPoint, to polyline: [CGPoint]) -> CGFloat {
        guard let first = polyline.first else { return .greatestFiniteMagnitude }
        guard polyline.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
            best = min(best, hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t)))
        }
        return best
    }

    private static func linearlyResampled(_ points: [InkPoint], maxSpacing: CGFloat) -> [InkPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [first] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            let steps = max(1, Int(ceil(distance / maxSpacing)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(InkPoint(
                    location: CGPoint(x: a.location.x + (b.location.x - a.location.x) * t,
                                      y: a.location.y + (b.location.y - a.location.y) * t),
                    force: a.force + (b.force - a.force) * t,
                    timeOffset: a.timeOffset + (b.timeOffset - a.timeOffset) * Double(t)
                ))
            }
        }
        return result
    }

    // MARK: Shape recognition (circle/ellipse)

    /// Recognised on lift (unlike the straight line, a closed loop has no
    /// natural "hold here" point to trigger on live): if the stroke closes
    /// back near where it started and every point sits close to the ellipse
    /// inscribed in its own bounding box, it's replaced with a clean one.
    private func ellipseIfClosedLoop(_ stroke: InkStroke) -> InkStroke? {
        let points = stroke.points.map(\.location)
        guard points.count >= 12, let first = points.first, let last = points.last else { return nil }

        let bounds = stroke.bounds
        guard bounds.width >= 24, bounds.height >= 24 else { return nil }
        let diagonal = hypot(bounds.width, bounds.height)

        let closureGap = hypot(last.x - first.x, last.y - first.y)
        guard closureGap <= diagonal * 0.35 else { return nil }

        let cx = bounds.midX, cy = bounds.midY
        let rx = max(bounds.width / 2, 1), ry = max(bounds.height / 2, 1)
        let deviation = points.reduce(CGFloat(0)) { total, point in
            let dx = (point.x - cx) / rx
            let dy = (point.y - cy) / ry
            return total + abs(sqrt(dx * dx + dy * dy) - 1)
        } / CGFloat(points.count)
        guard deviation <= 0.22 else { return nil }

        let steps = 72
        let ellipsePoints = (0...steps).map { step -> InkPoint in
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            return InkPoint(
                location: CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry),
                force: 0.5,
                timeOffset: TimeInterval(step) / Double(steps)
            )
        }
        var result = stroke
        result.points = ellipsePoints
        return result
    }

    private func rectangleIfClosedLoop(_ stroke: InkStroke) -> InkStroke? {
        let points = stroke.points.map(\.location)
        guard points.count >= 12, let first = points.first, let last = points.last else { return nil }
        let bounds = stroke.bounds.insetBy(dx: stroke.width, dy: stroke.width)
        guard bounds.width >= 24, bounds.height >= 24 else { return nil }
        let diagonal = hypot(bounds.width, bounds.height)
        guard hypot(last.x - first.x, last.y - first.y) <= diagonal * 0.35 else { return nil }

        let cornerRadius = min(bounds.width, bounds.height) * 0.24
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        guard corners.allSatisfy({ corner in
            points.contains { hypot($0.x - corner.x, $0.y - corner.y) <= cornerRadius }
        }) else { return nil }

        let averageEdgeDistance = points.reduce(CGFloat.zero) { total, point in
            total + min(abs(point.x - bounds.minX), abs(point.x - bounds.maxX),
                        abs(point.y - bounds.minY), abs(point.y - bounds.maxY))
        } / CGFloat(points.count)
        guard averageEdgeDistance <= min(bounds.width, bounds.height) * 0.12 else { return nil }
        var result = stroke
        result.points = Self.rectanglePoints(in: Self.correctedRectangleBounds(bounds))
        return result
    }

    private func triangleIfClosedLoop(_ stroke: InkStroke) -> InkStroke? {
        let points = stroke.points.map(\.location)
        guard points.count >= 10, let first = points.first, let last = points.last else { return nil }
        let bounds = stroke.bounds.insetBy(dx: stroke.width, dy: stroke.width)
        let diagonal = hypot(bounds.width, bounds.height)
        guard bounds.width >= 24, bounds.height >= 24,
              hypot(last.x - first.x, last.y - first.y) <= diagonal * 0.35 else { return nil }

        let hull = Self.convexHull(points)
        guard hull.count >= 3 else { return nil }
        var best: (CGPoint, CGPoint, CGPoint)?
        var bestArea: CGFloat = 0
        for i in 0..<(hull.count - 2) {
            for j in (i + 1)..<(hull.count - 1) {
                for k in (j + 1)..<hull.count {
                    let area = abs(Self.cross(hull[i], hull[j], hull[k]))
                    if area > bestArea {
                        bestArea = area
                        best = (hull[i], hull[j], hull[k])
                    }
                }
            }
        }
        guard let best, bestArea >= bounds.width * bounds.height * 0.35 else { return nil }
        let center = CGPoint(x: (best.0.x + best.1.x + best.2.x) / 3,
                             y: (best.0.y + best.1.y + best.2.y) / 3)
        let vertices = [best.0, best.1, best.2].sorted {
            atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
        }
        let averageDeviation = points.reduce(CGFloat.zero) { total, point in
            let edgeDistance = min(
                Self.distanceToSegment(point, vertices[0], vertices[1]),
                Self.distanceToSegment(point, vertices[1], vertices[2]),
                Self.distanceToSegment(point, vertices[2], vertices[0])
            )
            return total + edgeDistance
        } / CGFloat(points.count)
        guard averageDeviation <= diagonal * 0.075 else { return nil }

        let closed = vertices + [vertices[0]]
        var result = stroke
        result.points = closed.enumerated().map { index, point in
            InkPoint(location: point, force: 0.5, timeOffset: Double(index) / 3)
        }
        return result
    }

    /// Fits a vertical quadratic using least squares in normalized
    /// coordinates. Both U and inverted-U strokes are accepted, while near
    /// straight lines and shapes whose vertex lies outside the drawn span are
    /// rejected.
    private func parabolaIfRecognized(_ stroke: InkStroke) -> InkStroke? {
        let points = stroke.points.map(\.location)
        guard points.count >= 10 else { return nil }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        let width = maxX - minX, height = maxY - minY
        guard width >= 30, height >= 20 else { return nil }

        let midX = (minX + maxX) / 2
        let normalized = points.map { point in
            (x: (point.x - midX) / (width / 2), y: (point.y - minY) / height)
        }
        var s1 = CGFloat.zero, s2 = CGFloat.zero, s3 = CGFloat.zero, s4 = CGFloat.zero
        var sy = CGFloat.zero, sxy = CGFloat.zero, sx2y = CGFloat.zero
        for point in normalized {
            let x2 = point.x * point.x
            s1 += point.x; s2 += x2; s3 += x2 * point.x; s4 += x2 * x2
            sy += point.y; sxy += point.x * point.y; sx2y += x2 * point.y
        }
        let matrix: [[CGFloat]] = [
            [s4, s3, s2, sx2y], [s3, s2, s1, sxy],
            [s2, s1, CGFloat(normalized.count), sy],
        ]
        guard let solution = Self.solve3x3(matrix) else { return nil }
        let a = solution[0], b = solution[1], c = solution[2]
        guard abs(a) >= 0.22 else { return nil }
        let vertexX = -b / (2 * a)
        guard abs(vertexX) <= 1.15 else { return nil }
        let rmse = sqrt(normalized.reduce(CGFloat.zero) { total, point in
            let error = point.y - (a * point.x * point.x + b * point.x + c)
            return total + error * error
        } / CGFloat(normalized.count))
        guard rmse <= 0.14 else { return nil }

        let fitted = (0...64).map { index -> InkPoint in
            let nx = -1 + 2 * CGFloat(index) / 64
            let ny = a * nx * nx + b * nx + c
            return InkPoint(location: CGPoint(x: midX + nx * width / 2, y: minY + ny * height),
                            force: 0.5, timeOffset: Double(index) / 64)
        }
        var result = stroke
        result.points = fitted
        return result
    }

    // MARK: General curve fitting

    /// One candidate shape for a stroke: how to evaluate it, and how many
    /// coefficients it cost to fit.
    private struct CurveCandidate {
        let evaluate: (CGFloat) -> CGFloat
        let rmse: CGFloat
        let terms: Int

        /// What the candidates are ranked by.
        ///
        /// Raw error alone always favours the most flexible model — a cubic
        /// can shadow a straight line and win by a rounding error. The
        /// penalty per coefficient means a more complicated function has to
        /// fit *noticeably* better before it is preferred, which is what
        /// keeps a gentle arc from being redrawn as a wave.
        var score: CGFloat { rmse + 0.006 * CGFloat(terms) }
    }

    /// Redraws a stroke as the ordinary function it most nearly traces.
    ///
    /// Only strokes that pass a vertical-line test are eligible: `y = f(x)`
    /// cannot describe a shape that doubles back, and forcing one onto a loop
    /// produces nonsense. Convex arcs never reach here — the parabola check
    /// runs first and claims them.
    private func curveIfRecognized(_ stroke: InkStroke) -> InkStroke? {
        let raw = stroke.points.map(\.location)
        guard raw.count >= 12 else { return nil }
        let minX = raw.map(\.x).min() ?? 0, maxX = raw.map(\.x).max() ?? 0
        let minY = raw.map(\.y).min() ?? 0, maxY = raw.map(\.y).max() ?? 0
        let width = maxX - minX, height = maxY - minY
        guard width >= 40, height >= 12 else { return nil }

        // Left to right, however it was drawn, and thinned so the grid
        // searches below stay cheap enough to run inside the hold timer.
        let ordered = raw.sorted { $0.x < $1.x }
        let stride = max(1, ordered.count / 60)
        let sampled = Swift.stride(from: 0, to: ordered.count, by: stride).map { ordered[$0] }
        guard sampled.count >= 10 else { return nil }

        // The vertical-line test: after sorting by x, a function's y values
        // follow the original stroke order. If the stroke doubled back, the
        // sorted sequence zig-zags instead.
        guard Self.passesVerticalLineTest(raw) else { return nil }

        // Anything close to straight belongs to the line correction. Without
        // this the fitter claimed it first and drew a barely-bent curve where
        // the student plainly wanted a ruler line — a curve of very large
        // radius fits a straight stroke about as well as a line does, so
        // error alone never settles it. Straightness has to be ruled out
        // before the families are even tried.
        guard Self.bend(of: raw) > 0.055 else { return nil }

        let midX = (minX + maxX) / 2
        let points = sampled.map { point in
            (x: (point.x - midX) / (width / 2), y: (point.y - minY) / height)
        }

        var best: CurveCandidate?
        func consider(_ candidate: CurveCandidate?) {
            guard let candidate else { return }
            if best == nil || candidate.score < best!.score { best = candidate }
        }

        // Polynomials.
        consider(Self.fit(points, basis: [{ $0 * $0 }, { $0 }, { _ in 1 }]))
        consider(Self.fit(points, basis: [{ $0 * $0 * $0 }, { $0 * $0 }, { $0 }, { _ in 1 }]))

        // Waves. The frequency is searched over; amplitude and phase fall out
        // of the linear fit as the sine and cosine coefficients.
        for step in 0...30 {
            let omega = 0.6 + CGFloat(step) * 0.25
            consider(Self.fit(points, basis: [
                { sin(omega * $0) }, { cos(omega * $0) }, { _ in 1 },
            ]))
        }

        // Growth and decay.
        for step in 0...24 {
            let k = -6 + CGFloat(step) * 0.5
            guard abs(k) > 0.4 else { continue }
            consider(Self.fit(points, basis: [{ exp(k * $0) }, { _ in 1 }]))
        }

        // Logarithms and square roots, shifted so the domain covers [-1, 1].
        for shift in [CGFloat(1.02), 1.05, 1.1, 1.25, 1.5, 2, 3, 5] {
            consider(Self.fit(points, basis: [{ log($0 + shift) }, { _ in 1 }]))
            consider(Self.fit(points, basis: [{ sqrt($0 + shift) }, { _ in 1 }]))
        }

        // Reciprocals, with the pole kept outside the drawn range.
        for magnitude in [CGFloat(1.02), 1.05, 1.15, 1.35, 1.7, 2.4, 4] {
            for pole in [magnitude, -magnitude] {
                consider(Self.fit(points, basis: [{ 1 / ($0 - pole) }, { _ in 1 }]))
            }
        }

        guard let winner = best, winner.rmse <= 0.11 else { return nil }
        // A second, stricter guard in the fitted space: if a plain line
        // explains the stroke nearly as well, it is a line.
        if let line = Self.fit(points, basis: [{ $0 }, { _ in 1 }]),
           line.rmse <= winner.rmse * 1.6 {
            return nil
        }

        let fitted = (0...96).map { index -> InkPoint in
            let nx = -1 + 2 * CGFloat(index) / 96
            let ny = winner.evaluate(nx)
            return InkPoint(
                location: CGPoint(x: midX + nx * width / 2, y: minY + ny * height),
                force: 0.5,
                timeOffset: Double(index) / 96
            )
        }
        var result = stroke
        result.points = fitted
        return result
    }

    /// How far the stroke strays from the straight line joining its ends,
    /// as a fraction of that line's length.
    ///
    /// Scale-free on purpose: a 40pt flick and a full-page sweep with the
    /// same shape should be judged the same way.
    private static func bend(of points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        let dx = last.x - first.x, dy = last.y - first.y
        let length = hypot(dx, dy)
        guard length > 1 else { return 0 }
        let deviation = points.reduce(CGFloat.zero) { worst, point in
            let cross = abs(dx * (point.y - first.y) - dy * (point.x - first.x))
            return max(worst, cross / length)
        }
        return deviation / length
    }

    /// Whether the stroke advances in one direction along x.
    ///
    /// A little backtracking is normal — a hand shakes, and the pencil
    /// reports every wobble — so this measures the share of steps going the
    /// dominant way rather than demanding strict monotonicity.
    private static func passesVerticalLineTest(_ points: [CGPoint]) -> Bool {
        let deltas = zip(points, points.dropFirst()).map { $1.x - $0.x }
        let travelled = deltas.reduce(CGFloat.zero) { $0 + abs($1) }
        guard travelled > 0 else { return false }
        let net = abs(deltas.reduce(CGFloat.zero, +))
        return net / travelled >= 0.86
    }

    /// Least squares over a fixed set of basis functions.
    ///
    /// Every family above is linear in its coefficients once its shape
    /// parameter is chosen, so one solver covers all of them and the grid
    /// searches only have to supply the basis.
    private static func fit(
        _ points: [(x: CGFloat, y: CGFloat)],
        basis: [(CGFloat) -> CGFloat]
    ) -> CurveCandidate? {
        let terms = basis.count
        var normal = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: terms + 1), count: terms)
        for point in points {
            let row = basis.map { $0(point.x) }
            guard row.allSatisfy({ $0.isFinite }) else { return nil }
            for i in 0..<terms {
                for j in 0..<terms { normal[i][j] += row[i] * row[j] }
                normal[i][terms] += row[i] * point.y
            }
        }
        guard let coefficients = solve(normal) else { return nil }

        let evaluate: (CGFloat) -> CGFloat = { x in
            zip(coefficients, basis).reduce(CGFloat.zero) { $0 + $1.0 * $1.1(x) }
        }
        var total = CGFloat.zero
        for point in points {
            let error = point.y - evaluate(point.x)
            guard error.isFinite else { return nil }
            total += error * error
        }
        return CurveCandidate(
            evaluate: evaluate,
            rmse: sqrt(total / CGFloat(points.count)),
            terms: terms
        )
    }

    /// Gauss-Jordan with partial pivoting, on an augmented matrix.
    private static func solve(_ matrix: [[CGFloat]]) -> [CGFloat]? {
        var m = matrix
        let n = m.count
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                  abs(m[pivot][column]) > 1e-9 else { return nil }
            m.swapAt(column, pivot)
            let divisor = m[column][column]
            for index in column...n { m[column][index] /= divisor }
            for row in 0..<n where row != column {
                let factor = m[row][column]
                guard factor != 0 else { continue }
                for index in column...n { m[row][index] -= factor * m[column][index] }
            }
        }
        return (0..<n).map { m[$0][n] }
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
        return hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t))
    }

    private static func solve3x3(_ input: [[CGFloat]]) -> [CGFloat]? {
        var matrix = input
        for column in 0..<3 {
            guard let pivot = (column..<3).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 0.000_001 else { return nil }
            matrix.swapAt(column, pivot)
            let divisor = matrix[column][column]
            for j in column..<4 { matrix[column][j] /= divisor }
            for row in 0..<3 where row != column {
                let factor = matrix[row][column]
                for j in column..<4 { matrix[row][j] -= factor * matrix[column][j] }
            }
        }
        return [matrix[0][3], matrix[1][3], matrix[2][3]]
    }

    // MARK: Scribble-to-erase

    /// A deliberate scratch-out gesture is messy, compact ink drawn over an
    /// existing stroke. It might be a zig-zag, a tight circular scribble, or
    /// a small back-and-forth hatch, so don't rely on just one signal.
    private func isScribble(_ stroke: InkStroke, emitsDiagnostics: Bool = false) -> Bool {
        let analysis = ScribbleClassifier.analyze(stroke.points.map(\.location))
        if emitsDiagnostics {
            GestureDiagnostics.scratchOutCheck(
                points: stroke.points.count,
                directionChanges: analysis.directionChanges,
                reversals: analysis.axisReversals,
                intersections: analysis.selfIntersections,
                lengthRatio: analysis.lengthRatio,
                qualifies: analysis.qualifies
            )
        }
        return analysis.qualifies
    }

    private func strokeIsCoveredBy(_ stroke: InkStroke, scribble: InkStroke) -> Bool {
        guard stroke.bounds.insetBy(dx: -18, dy: -18).intersects(scribble.bounds) else { return false }
        let scribblePoints = scribble.points.map(\.location)
        guard scribblePoints.count > 1 else { return false }
        // Resample the whole target path, including the middle of corrected
        // lines that are stored with only two endpoints.
        let samples = Self.linearlyResampled(stroke.points, maxSpacing: 6).map(\.location)
        guard !samples.isEmpty else { return false }
        let radius = max(14, stroke.width + scribble.width + 8)
        // A scribble over any part of a stroke removes that stroke. Requiring
        // a percentage of the *whole* stroke made long corrected lines nearly
        // impossible to erase because a local scribble covered too little of
        // their total length.
        return samples.contains { sample in
            Self.distance(from: sample, to: scribblePoints) <= radius
        }
    }

    // MARK: Force

    private func normalizedForce(_ touch: UITouch) -> CGFloat {
        guard touch.maximumPossibleForce > 0 else { return 0.5 }
        return min(max(touch.force / touch.maximumPossibleForce, 0.15), 1)
    }

    // MARK: Path building

    /// Builds a filled ribbon for each stroke — offsetting every sample
    /// perpendicular to the path's direction by a pressure-scaled half-width
    /// — rather than a constant-width stroked line, so pressure still reads
    /// visually the way it did under PencilKit.
    static func path(for strokes: [InkStroke]) -> UIBezierPath {
        let combined = UIBezierPath()
        for stroke in strokes {
            combined.append(ribbon(for: stroke))
        }
        return combined
    }

    static func ribbon(for stroke: InkStroke) -> UIBezierPath {
        let rawPoints = stroke.points
        guard rawPoints.count > 1 else {
            let path = UIBezierPath()
            if let point = rawPoints.first {
                appendDab(to: path, center: point.location, radius: stroke.width / 2)
            }
            return path
        }

        // Raw touch samples are noisy and unevenly spaced, which is what
        // made the old point-to-point ribbon look faceted rather than
        // drawn — PencilKit hides the same sensor jitter internally. Pass
        // 1 damps that jitter; pass 2 fits a curve through the result and
        // resamples it densely, so the outline traces a curve instead of a
        // polyline of raw samples. Spacing is tied to the stroke's own
        // width rather than a fixed sample count, so a fast flick with a
        // thin pen still gets enough samples to stay solid.
        let maxSpacing = max(0.75, stroke.width * 0.25)
        // Corrected/tool-created rectangles are stored as exactly four
        // axis-aligned corners plus the repeated first corner. Running those
        // sparse corner points through Catmull-Rom treats every 90° corner as
        // part of a broad curve, producing the teardrop-like shape seen on
        // screen. Keep generated polygon edges exact; freehand ink and
        // ellipses still use the smoothing pipeline.
        let points = isGeneratedPolygon(rawPoints)
            ? rawPoints
            : resampled(smoothed(rawPoints), maxSpacing: maxSpacing)

        // Build one Core Graphics stroked outline. The previous renderer
        // appended independently wound quads and circles to one fill path;
        // where their winding directions opposed each other Core Animation
        // treated the overlap as a hole (the white beads in handwriting and
        // white crescents at line ends). A single round-cap/round-join stroke
        // has one coherent outline, so overlaps can never cancel its fill.
        let centerline = UIBezierPath()
        centerline.move(to: points[0].location)
        for point in points.dropFirst() { centerline.addLine(to: point.location) }
        let outline = centerline.cgPath.copy(
            strokingWithWidth: stroke.width,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 2
        )
        return UIBezierPath(cgPath: outline)
    }

    private static func isGeneratedRectangle(_ points: [InkPoint]) -> Bool {
        guard points.count == 5,
              let first = points.first?.location,
              let last = points.last?.location,
              hypot(first.x - last.x, first.y - last.y) < 0.01 else { return false }

        for (a, b) in zip(points, points.dropFirst()) {
            let dx = abs(a.location.x - b.location.x)
            let dy = abs(a.location.y - b.location.y)
            guard (dx < 0.01 && dy > 0.01) || (dy < 0.01 && dx > 0.01) else { return false }
        }
        return true
    }

    private static func isGeneratedPolygon(_ points: [InkPoint]) -> Bool {
        if isGeneratedRectangle(points) { return true }
        guard points.count == 4,
              let first = points.first?.location,
              let last = points.last?.location,
              hypot(first.x - last.x, first.y - last.y) < 0.01 else { return false }
        return zip(points, points.dropFirst()).allSatisfy {
            hypot($0.location.x - $1.location.x, $0.location.y - $1.location.y) > 0.01
        }
    }

    private static func appendDab(to path: UIBezierPath, center: CGPoint, radius: CGFloat) {
        path.append(UIBezierPath(ovalIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        )))
    }

    /// Light jitter reduction: each interior point is pulled toward the
    /// midpoint of its neighbours. Endpoints are left untouched so a stroke
    /// still starts and ends exactly where the pencil touched down and
    /// lifted.
    private static func smoothed(_ points: [InkPoint]) -> [InkPoint] {
        guard points.count > 2 else { return points }
        var result = points
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1].location
            let current = points[index].location
            let next = points[index + 1].location
            result[index].location = CGPoint(
                x: current.x * 0.5 + (previous.x + next.x) * 0.25,
                y: current.y * 0.5 + (previous.y + next.y) * 0.25
            )
        }
        return result
    }

    /// Fits a Catmull-Rom spline through the (already jitter-reduced)
    /// samples and resamples it so consecutive samples are never farther
    /// apart than `maxSpacing` — the same technique PencilKit's ink uses —
    /// instead of straight segments between raw touch events. Subdividing
    /// by distance rather than a fixed count per segment keeps dabs
    /// overlapping (no gaps) even where a fast flick left raw samples far
    /// apart, without over-subdividing slow, closely-spaced segments.
    private static func resampled(_ points: [InkPoint], maxSpacing: CGFloat) -> [InkPoint] {
        guard points.count > 2 else { return points }
        var result: [InkPoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let segmentLength = hypot(p2.location.x - p1.location.x, p2.location.y - p1.location.y)
            let steps = max(1, Int((segmentLength / maxSpacing).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(catmullRom(p0, p1, p2, p3, t))
            }
        }
        return result
    }

    private static func catmullRom(_ p0: InkPoint, _ p1: InkPoint, _ p2: InkPoint, _ p3: InkPoint, _ t: CGFloat) -> InkPoint {
        let t2 = t * t
        let t3 = t2 * t
        func interpolate(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (
                (2 * b)
                + (-a + c) * t
                + (2 * a - 5 * b + 4 * c - d) * t2
                + (-a + 3 * b - 3 * c + d) * t3
            )
        }
        return InkPoint(
            location: CGPoint(
                x: interpolate(p0.location.x, p1.location.x, p2.location.x, p3.location.x),
                y: interpolate(p0.location.y, p1.location.y, p2.location.y, p3.location.y)
            ),
            force: interpolate(p0.force, p1.force, p2.force, p3.force),
            timeOffset: TimeInterval(interpolate(
                CGFloat(p0.timeOffset), CGFloat(p1.timeOffset), CGFloat(p2.timeOffset), CGFloat(p3.timeOffset)
            ))
        )
    }
}
