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
    // MARK: Configuration

    var strokeColorHex: String = "#1C1C1E"
    var strokeWidth: CGFloat = 4
    var isHighlighter = false
    var isScratchOutEnabled = true
    var isEraser = false
    var eraserWidth: CGFloat = 24
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
    private var holdTimer: Timer?
    private var strokeStartLocation: CGPoint?
    private var currentEraseTargets: Set<UUID> = []

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
        guard rawPoints.isEmpty else { return } // ignore a second finger/pencil mid-stroke

        onStrokeBegan?()
        let now = Date()
        strokeStartedAt = now
        lastMovementAt = now
        isStraightened = false
        isEllipseLocked = false
        currentEraseTargets = []
        let location = touch.location(in: self)
        strokeStartLocation = location
        lastMovementLocation = location
        rawPoints = [InkPoint(location: location, force: normalizedForce(touch), timeOffset: 0)]

        if isEraser {
            eraseIfTouching(location)
        } else {
            updateLiveLayer()
            startHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil, strokeStartedAt != nil else { return }

        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            appendSample(sample)
        }
        if isEraser {
            if let last = rawPoints.last?.location { eraseIfTouching(last) }
        } else if !isStraightened && !isEllipseLocked {
            updateLiveLayer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil, strokeStartedAt != nil else { return }
        appendSample(touch)
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
            guard let since = self.lastMovementAt, !self.isStraightened, !self.isEllipseLocked else { return }
            guard Date().timeIntervalSince(since) >= self.straightenHoldDuration else { return }
            guard let start = self.strokeStartLocation, let current = self.lastMovementLocation else { return }
            let distanceFromStart = hypot(current.x - start.x, current.y - start.y)

            if distanceFromStart > 16, !self.looksLikeClosedLoop() {
                self.isStraightened = true
                self.emitStraightPreview(to: current)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if self.looksLikeClosedLoop() {
                self.isEllipseLocked = true
                self.emitEllipsePreview()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
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
            liveLayer.path = nil
            currentEraseTargets = []
        }

        guard !isEraser else {
            if !currentEraseTargets.isEmpty {
                drawing.strokes.removeAll { currentEraseTargets.contains($0.id) }
                withoutImplicitAnimations { removeCommittedLayers(ids: currentEraseTargets) }
            }
            return
        }

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
        } else if isEllipseLocked {
            // Locked live, while the pencil was still down — use the exact
            // same fit the on-screen preview was already showing.
            let bounds = stroke.bounds.insetBy(dx: strokeWidth, dy: strokeWidth)
            stroke.points = Self.ellipsePoints(in: bounds)
        } else if !isHighlighter, let ellipse = ellipseIfClosedLoop(stroke) {
            // Fallback for a circle drawn fast enough that the pencil never
            // paused: recognised from the finished shape instead of live.
            stroke = ellipse
        } else if !isHighlighter, isScratchOutEnabled, isScribble(stroke) {
            let hit = drawing.strokes.filter { strokeIsCoveredBy($0, scribble: stroke) }
            if !hit.isEmpty {
                let hitIDs = Set(hit.map(\.id))
                drawing.strokes.removeAll { hitIDs.contains($0.id) }
                withoutImplicitAnimations { removeCommittedLayers(ids: hitIDs) }
                return
            }
        }

        drawing.strokes.append(stroke)
        withoutImplicitAnimations { addCommittedLayer(for: stroke) }
    }

    // MARK: Eraser (bitmap-style: touched strokes are removed on lift)

    private func eraseIfTouching(_ location: CGPoint) {
        for stroke in drawing.strokes where !currentEraseTargets.contains(stroke.id) {
            guard stroke.bounds.insetBy(dx: -eraserWidth, dy: -eraserWidth).contains(location) else { continue }
            guard stroke.points.contains(where: {
                hypot($0.location.x - location.x, $0.location.y - location.y) <= eraserWidth
            }) else { continue }
            currentEraseTargets.insert(stroke.id)
            // Fade the touched stroke immediately so erasing reads as live —
            // it's actually removed (and the layer discarded) on lift.
            strokeLayers[stroke.id]?.opacity = 0.15
        }
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
        let path = UIBezierPath()
        let points = stroke.points
        guard points.count > 1 else {
            if let point = points.first {
                let radius = stroke.width * max(point.force, 0.4) / 2
                path.append(UIBezierPath(ovalIn: CGRect(
                    x: point.location.x - radius, y: point.location.y - radius,
                    width: radius * 2, height: radius * 2
                )))
            }
            return path
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in points.indices {
            let point = points[index]
            let previous = points[max(0, index - 1)].location
            let next = points[min(points.count - 1, index + 1)].location
            var direction = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
            let length = hypot(direction.x, direction.y)
            if length > 0.001 {
                direction = CGPoint(x: direction.x / length, y: direction.y / length)
            } else {
                direction = CGPoint(x: 1, y: 0)
            }
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let halfWidth = stroke.width * max(point.force, 0.35) / 2
            left.append(CGPoint(x: point.location.x + normal.x * halfWidth, y: point.location.y + normal.y * halfWidth))
            right.append(CGPoint(x: point.location.x - normal.x * halfWidth, y: point.location.y - normal.y * halfWidth))
        }

        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.close()
        return path
    }
}
