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
final class InkCanvasView: UIView {
    enum ShapeKind: String {
        case rectangle, ellipse, line
    }

    // MARK: Configuration

    var strokeColorHex: String = "#1C1C1E"
    var strokeWidth: CGFloat = 4
    var isHighlighter = false
    var isScratchOutEnabled = true
    var isEraser = false
    var eraserWidth: CGFloat = 24
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

    private(set) var drawing = InkDrawing() {
        didSet { onDrawingChanged?(drawing) }
    }

    /// Replaces the drawing without notifying `onDrawingChanged` — for
    /// loading from disk or undo/redo, where echoing back out would be
    /// redundant (and, for undo/redo, actively wrong).
    func setDrawing(_ newValue: InkDrawing) {
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
    private var holdTimer: Timer?
    private var strokeStartLocation: CGPoint?
    private var shapeDragStart: CGPoint?
    private var shapeDragCurrent: CGPoint?

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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        committedContainer.frame = bounds
        liveLayer.frame = bounds
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

        onStrokeBegan?()
        let now = Date()
        strokeStartedAt = now
        lastMovementAt = now
        isStraightened = false
        isEllipseLocked = false
        isRectangleLocked = false
        let location = touch.location(in: self)
        strokeStartLocation = location
        lastMovementLocation = location
        rawPoints = [InkPoint(location: location, force: normalizedForce(touch), timeOffset: 0)]

        if isEraser {
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

        guard strokeStartedAt != nil else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let previousEraserLocation = rawPoints.last?.location
        for sample in samples {
            appendSample(sample)
        }
        if isEraser {
            let path = [previousEraserLocation].compactMap { $0 } + samples.map { $0.location(in: self) }
            eraseParts(along: path)
        } else if !isStraightened && !isEllipseLocked && !isRectangleLocked {
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

        guard strokeStartedAt != nil else { return }
        let previousEraserLocation = rawPoints.last?.location
        appendSample(touch)
        if isEraser {
            let path = [previousEraserLocation, Optional(touch.location(in: self))].compactMap { $0 }
            eraseParts(along: path)
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
                // Likewise, keep refitting the ellipse to the growing path.
                emitEllipsePreview()
            } else if isRectangleLocked {
                emitRectanglePreview()
            } else {
                startHoldTimer()
            }
        }
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
                  !self.isStraightened, !self.isEllipseLocked, !self.isRectangleLocked else { return }
            guard Date().timeIntervalSince(since) >= self.straightenHoldDuration else { return }
            guard let start = self.strokeStartLocation, let current = self.lastMovementLocation else { return }
            let distanceFromStart = hypot(current.x - start.x, current.y - start.y)

            if self.rectangleIfClosedLoop(self.previewStroke()) != nil {
                self.isRectangleLocked = true
                self.emitRectanglePreview()
                self.triggerCorrectionFeedback(at: current)
            } else if distanceFromStart > 16, !self.looksLikeClosedLoop() {
                self.isStraightened = true
                self.emitStraightPreview(to: current)
                self.triggerCorrectionFeedback(at: current)
            } else if self.looksLikeClosedLoop() {
                self.isEllipseLocked = true
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
        let bounds = InkStroke(points: rawPoints, colorHex: strokeColorHex, width: strokeWidth).bounds
            .insetBy(dx: strokeWidth, dy: strokeWidth) // `bounds` already pads by width; undo the double pad
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
        let bounds = Self.correctedRectangleBounds(
            previewStroke().bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
        )
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
            let bounds = Self.correctedRectangleBounds(
                stroke.bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
            )
            stroke.points = Self.rectanglePoints(in: bounds)
        } else if isEllipseLocked {
            // Locked live, while the pencil was still down — use the exact
            // same fit the on-screen preview was already showing.
            let bounds = stroke.bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
            stroke.points = Self.ellipsePoints(in: bounds)
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
            if !isHighlighter, let rectangle = rectangleIfClosedLoop(stroke) {
                stroke = rectangle
            } else if !isHighlighter, let ellipse = ellipseIfClosedLoop(stroke) {
                // Fallback for a circle drawn fast enough that the pencil
                // never paused: recognised from the finished shape instead
                // of live.
                stroke = ellipse
            }
        }

        drawing.strokes.append(stroke)
        withoutImplicitAnimations { addCommittedLayer(for: stroke) }
    }

    // MARK: Eraser (bitmap-style: only the touched portions are removed)

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
            let source = Self.isGeneratedRectangle(stroke.points) ? stroke.points : Self.smoothed(stroke.points)
            let samples = Self.resampled(source, maxSpacing: max(1, radius * 0.25))
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

        var turns = 0
        var previousVector: CGPoint?
        let points = stroke.points.map(\.location)
        for index in stride(from: 3, to: points.count, by: 3) {
            let vector = CGPoint(x: points[index].x - points[index - 3].x, y: points[index].y - points[index - 3].y)
            let length = hypot(vector.x, vector.y)
            guard length > 2 else { continue }
            if let previous = previousVector {
                let previousLength = hypot(previous.x, previous.y)
                let dot = (previous.x * vector.x + previous.y * vector.y) / max(previousLength * length, 0.001)
                if dot < 0.2 { turns += 1 }
            }
            previousVector = vector
        }
        return turns >= 2 && ratio >= 1.3
    }

    private func strokeIsCoveredBy(_ stroke: InkStroke, scribble: InkStroke) -> Bool {
        guard stroke.bounds.intersects(scribble.bounds) else { return false }
        let scribblePoints = scribble.points.map(\.location)
        let strokePoints = stroke.points.map(\.location)
        guard !strokePoints.isEmpty else { return false }
        let sampleStep = max(1, strokePoints.count / 24)
        let samples = stride(from: 0, to: strokePoints.count, by: sampleStep).map { strokePoints[$0] }
        let radius: CGFloat = 18
        let covered = samples.filter { sample in
            scribblePoints.contains { hypot($0.x - sample.x, $0.y - sample.y) <= radius }
        }.count
        return Double(covered) / Double(samples.count) >= 0.12
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
        let points = isGeneratedRectangle(rawPoints)
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
