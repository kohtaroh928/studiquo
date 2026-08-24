import UIKit

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
        case rectangle, ellipse, line
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
    var isEraser = false {
        didSet { if !isEraser { hideEraserCursor() } }
    }
    var isLasso = false {
        didSet {
            if !isLasso { clearLassoSelection() }
        }
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
    /// Fired once the pencil lifts (or the touch is cancelled), whatever the
    /// outcome — a committed stroke, an erase, or nothing. The representable
    /// uses this to let ancestor scroll views move again once it's safe.
    var onStrokeEnded: (() -> Void)?
    /// Fired after a dragged shape is committed, so the owner can return to
    /// the pen tool instead of leaving the shape tool silently armed.
    var onShapeCommitted: (() -> Void)?
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
    private let eraserCursorLayer = CAShapeLayer()

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
        eraserCursorLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.10).cgColor
        eraserCursorLayer.strokeColor = UIColor.systemGray.withAlphaComponent(0.85).cgColor
        eraserCursorLayer.lineWidth = 1.2
        eraserCursorLayer.isHidden = true
        layer.addSublayer(eraserCursorLayer)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleEraserHover(_:))))
        addInteraction(UIDragInteraction(delegate: self))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        committedContainer.frame = bounds
        liveLayer.frame = bounds
        selectionLayer.frame = bounds
        eraserCursorLayer.frame = bounds
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first, touch.type == .pencil else { return }
        guard rawPoints.isEmpty, shapeDragStart == nil else { return } // ignore a second finger/pencil mid-stroke

        if let kind = pendingShapeKind {
            onStrokeBegan?()
            let location = touch.location(in: self)
            shapeDragStart = location
            shapeDragCurrent = location
            updateShapePreview(kind: kind)
            return
        }

        if isLasso {
            onStrokeBegan?()
            beginLasso(at: touch.location(in: self))
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
        let location = touch.location(in: self)
        strokeStartLocation = location
        lastMovementLocation = location
        rawPoints = [InkPoint(location: location, force: normalizedForce(touch), timeOffset: 0)]

        if isEraser {
            showEraserCursor(at: location)
            eraseParts(along: [location])
        } else {
            updateLiveLayer()
            startHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }

        if let kind = pendingShapeKind, shapeDragStart != nil {
            shapeDragCurrent = touch.location(in: self)
            updateShapePreview(kind: kind)
            return
        }


        if isLasso {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            moveLasso(to: samples.map { $0.location(in: self) })
            return
        }

        guard strokeStartedAt != nil else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let previousEraserLocation = rawPoints.last?.location
        for sample in samples {
            appendSample(sample)
        }
        if isEraser {
            let path = [previousEraserLocation].compactMap { $0 } + samples.map { $0.location(in: self) }
            if let location = path.last { showEraserCursor(at: location) }
            eraseParts(along: path)
        } else if !isStraightened && !isEllipseLocked && !isRectangleLocked
                    && !isTriangleLocked && !isParabolaLocked {
            updateLiveLayer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }

        if let kind = pendingShapeKind, let start = shapeDragStart {
            let end = touch.location(in: self)
            commitShape(kind: kind, from: start, to: end)
            shapeDragStart = nil
            shapeDragCurrent = nil
            liveLayer.path = nil
            onStrokeEnded?()
            onShapeCommitted?()
            return
        }

        if isLasso {
            endLasso(at: touch.location(in: self))
            onStrokeEnded?()
            return
        }

        guard strokeStartedAt != nil else { return }
        let previousEraserLocation = rawPoints.last?.location
        appendSample(touch)
        if isEraser {
            let path = [previousEraserLocation, Optional(touch.location(in: self))].compactMap { $0 }
            eraseParts(along: path)
            hideEraserCursor()
        }
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func appendSample(_ touch: UITouch) {
        guard let start = strokeStartedAt else { return }
        let location = touch.location(in: self)
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
            if !bounds.contains(location) {
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
            for id in selectedStrokeIDs { strokeLayers[id]?.setAffineTransform(.identity) }
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

    private func selectionPreview() -> (image: UIImage, screenSize: CGSize)? {
        let selected = InkDrawing(strokes: drawing.strokes.filter { selectedStrokeIDs.contains($0.id) })
        guard let first = selected.strokes.first else { return nil }
        let inkBounds = selected.strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        guard inkBounds.width > 0, inkBounds.height > 0 else { return nil }
        let topLeft = convert(CGPoint(x: inkBounds.minX, y: inkBounds.minY), to: nil)
        let bottomRight = convert(CGPoint(x: inkBounds.maxX, y: inkBounds.maxY), to: nil)
        let screenSize = CGSize(
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        return (selected.image(from: inkBounds, scale: 2), screenSize)
    }

    // MARK: Cross-pane selection drag

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let location = session.location(in: self)
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
        let stroke = InkStroke(points: shapePoints(kind: kind, from: start, to: end), colorHex: strokeColorHex, width: strokeWidth)
        drawing.strokes.append(stroke)
        withoutImplicitAnimations { addCommittedLayer(for: stroke) }
    }

    private func shapePoints(kind: ShapeKind, from start: CGPoint, to end: CGPoint) -> [InkPoint] {
        switch kind {
        case .line:
            return [
                InkPoint(location: start, force: 0.6, timeOffset: 0),
                InkPoint(location: end, force: 0.6, timeOffset: 1),
            ]
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

        var stroke = InkStroke(
            points: rawPoints,
            colorHex: strokeColorHex,
            width: strokeWidth,
            opacity: isHighlighter ? 0.45 : 1,
            isHighlighter: isHighlighter
        )
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
            // Scribble-to-erase is checked before the closed-loop ellipse
            // fallback below: a scribble that happens to loop back near its
            // own start is still a scribble, not a circle someone drew
            // fast, and erasing should win that tie — otherwise a crumple
            // gesture that closes on itself got "cleaned up" into a circle
            // instead of erasing what it was scribbled over.
            if !isHighlighter, isScratchOutEnabled, isScribble(stroke) {
                let hit = drawing.strokes.filter { strokeIsCoveredBy($0, scribble: stroke) }
                if !hit.isEmpty {
                    let hitIDs = Set(hit.map(\.id))
                    drawing.strokes.removeAll { hitIDs.contains($0.id) }
                    withoutImplicitAnimations { removeCommittedLayers(ids: hitIDs) }
                    return
                }
            }
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
            showEraserCursor(at: recognizer.location(in: self))
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

    /// A deliberate scribble doubles back over roughly the same small area
    /// many times, so its path length is a large multiple of that area's
    /// diagonal. Ordinary handwriting — even a looped character — traces its
    /// shape once and has a much lower ratio.
    private func isScribble(_ stroke: InkStroke) -> Bool {
        let bounds = stroke.bounds
        guard bounds.width >= 8, bounds.height >= 8, stroke.points.count >= 8 else { return false }
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 0 else { return false }
        let ratio = stroke.pathLength / diagonal

        // Coalesced Pencil samples can be less than a point apart. Comparing
        // every Nth stored sample therefore often produced vectors too short
        // to count, even for an obvious back-and-forth scribble. Build
        // direction vectors only after the Pencil has travelled a meaningful
        // distance so recognition is independent of the sampling rate.
        var turns = 0
        var previousVector: CGPoint?
        let points = stroke.points.map(\.location)
        var anchor = points[0]
        for point in points.dropFirst() {
            let vector = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
            let length = hypot(vector.x, vector.y)
            guard length >= 6 else { continue }
            if let previous = previousVector {
                let previousLength = hypot(previous.x, previous.y)
                let dot = (previous.x * vector.x + previous.y * vector.y) / max(previousLength * length, 0.001)
                if dot < -0.05 { turns += 1 }
            }
            previousVector = vector
            anchor = point
        }
        return turns >= 3 && ratio >= 2.0 && stroke.pathLength >= 40
    }

    private func strokeIsCoveredBy(_ stroke: InkStroke, scribble: InkStroke) -> Bool {
        guard stroke.bounds.intersects(scribble.bounds) else { return false }
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
