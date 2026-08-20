import Foundation
import QuartzCore

/// Temporary instrumentation used to diagnose the zoom-pan stutter and the
/// pull-to-add-page gesture on a real device. Everything here is meant to be
/// deleted once both issues are pinned down — nothing in the app depends on it.
enum GestureDiagnostics {
    /// stdout so `devicectl ... --console` can stream it off the device.
    private static func emit(_ message: String) { print("[GDIAG] \(message)"); fflush(stdout) }

    // MARK: Pan frame pacing

    private final class PanState {
        var lastTimestamp: CFTimeInterval?
        var intervals: [Double] = []
        var startedAt: CFTimeInterval?
    }
    private static let pan = PanState()

    /// Called on every pan gesture update. Measures how often SwiftUI is
    /// actually able to deliver gesture frames: a healthy 120 Hz iPad should
    /// see ~8 ms between updates. Consistently long gaps mean the main thread
    /// is blocked between frames (CPU-bound). Regular short gaps with visible
    /// stutter instead point at render/compositing cost (GPU-bound).
    static func recordPanUpdate() {
        let now = CACurrentMediaTime()
        if pan.startedAt == nil { pan.startedAt = now }
        if let last = pan.lastTimestamp {
            pan.intervals.append((now - last) * 1000)
        }
        pan.lastTimestamp = now
    }

    static func endPanAndReport(scale: CGFloat) {
        defer {
            pan.lastTimestamp = nil
            pan.intervals.removeAll()
            pan.startedAt = nil
        }
        let samples = pan.intervals
        guard samples.count >= 5 else {
            emit("PAN too few samples (\(samples.count)) scale=\(String(format: "%.2f", scale))")
            return
        }
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let worst = sorted.last ?? 0
        let overBudget = samples.filter { $0 > 20 }.count
        emit("""
        PAN scale=\(String(format: "%.2f", scale)) frames=\(samples.count) \
        mean=\(String(format: "%.1f", mean))ms median=\(String(format: "%.1f", median))ms \
        p95=\(String(format: "%.1f", p95))ms worst=\(String(format: "%.1f", worst))ms \
        over20ms=\(overBudget)
        """)
    }

    // MARK: Pull-to-add-page

    static func pullBottomState(isAtBottom: Bool, adderMaxY: CGFloat, viewportHeight: CGFloat) {
        emit("""
        PULL bottomState isAtBottom=\(isAtBottom) \
        adderMaxY=\(String(format: "%.1f", adderMaxY)) viewport=\(String(format: "%.1f", viewportHeight))
        """)
    }

    static func pullProgress(_ progress: CGFloat, extraPulled: CGFloat) {
        emit("PULL progress=\(String(format: "%.2f", progress)) extraPulled=\(String(format: "%.1f", extraPulled))")
    }

    private static var lastIgnoreEmit: CFTimeInterval = 0
    static func pullGestureIgnored(reason: String) {
        // Throttled: this fires on every drag frame and would otherwise
        // drown out everything else in the log.
        let now = CACurrentMediaTime()
        guard now - lastIgnoreEmit > 0.5 else { return }
        lastIgnoreEmit = now
        emit("PULL ignored reason=\(reason)")
    }

    /// Raw geometry behind the "are we at the bottom?" decision. Logged
    /// whenever the numbers move meaningfully, so the actual values can be
    /// compared against the threshold instead of guessed at.
    private static var lastRawMaxY: CGFloat = .nan
    static func pullRawGeometry(maxY: CGFloat, viewport: CGFloat, contentHeight: CGFloat) {
        guard !lastRawMaxY.isFinite || abs(maxY - lastRawMaxY) > 8 else { return }
        lastRawMaxY = maxY
        emit("""
        PULL raw maxY=\(String(format: "%.1f", maxY)) viewport=\(String(format: "%.1f", viewport)) \
        contentH=\(String(format: "%.1f", contentHeight)) \
        contentExceedsViewport=\(contentHeight > viewport) atBottomWouldBe=\(maxY <= viewport + 1)
        """)
    }

    // MARK: Zoom

    private static var lastZoomEmit: CFTimeInterval = 0
    static func zoomScale(_ scale: CGFloat, phase: String) {
        let now = CACurrentMediaTime()
        guard phase != "changed" || now - lastZoomEmit > 0.3 else { return }
        lastZoomEmit = now
        emit("ZOOM \(phase) scale=\(String(format: "%.3f", scale))")
    }

    static func panBegan(scale: CGFloat) {
        emit("PAN began scale=\(String(format: "%.2f", scale))")
    }

    // MARK: Ink

    static func strokeOutcome(before: Int, after: Int, tool: String, scratchOutFired: Bool) {
        emit("INK tool=\(tool) strokesBefore=\(before) strokesAfter=\(after) scratchOutFired=\(scratchOutFired)")
    }

    static func straightenAttempt(points: Int, distance: CGFloat, sampledDwell: Double, wallDwell: Double, applied: Bool) {
        emit("""
        INK straighten points=\(points) distance=\(String(format: "%.0f", distance)) \
        sampledDwell=\(String(format: "%.2f", sampledDwell))s \
        wallDwell=\(String(format: "%.2f", wallDwell))s applied=\(applied)
        """)
    }

    static func scratchOutCheck(points: Int, turns: Int, lengthRatio: CGFloat, qualifies: Bool) {
        emit("INK scratchCheck points=\(points) turns=\(turns) ratio=\(String(format: "%.2f", lengthRatio)) qualifies=\(qualifies)")
    }

    static func scratchOutRemoval(candidates: Int, removed: Int) {
        emit("INK scratchRemoval candidates=\(candidates) removed=\(removed)")
    }

    static func inkLoaded(strokes: Int, hadData: Bool) {
        emit("INK loaded strokes=\(strokes) hadSavedData=\(hadData)")
    }

    static func inkSaved(strokes: Int) {
        emit("INK saved strokes=\(strokes)")
    }

    static func outerPanState(_ state: String, zoom: CGFloat, touches: Int, offset: CGPoint, contentSize: CGSize) {
        emit("""
        ZSV outerPan state=\(state) touches=\(touches) zoom=\(String(format: "%.2f", zoom)) \
        offset=\(String(format: "%.0f,%.0f", offset.x, offset.y)) \
        content=\(String(format: "%.0fx%.0f", contentSize.width, contentSize.height))
        """)
    }

    static func inkLive(_ phase: String, strokes: Int) {
        emit("INK live \(phase) strokes=\(strokes)")
    }

    static func ancestorScrollViewsPatched(_ count: Int) {
        emit("INK ancestorScrollViewsPatched=\(count)")
    }

    static func inkCanvasCreated(strokes: Int) {
        emit("INK canvas CREATED withStrokes=\(strokes)")
    }

    static func inkCanvasOverwritten(canvasStrokes: Int, incomingStrokes: Int) {
        emit("INK canvas OVERWRITTEN canvasHad=\(canvasStrokes) incoming=\(incomingStrokes)")
    }

    static func zoomedFlag(_ isZoomed: Bool, scale: CGFloat) {
        emit("ZSV isZoomedFlag=\(isZoomed) scale=\(String(format: "%.2f", scale))")
    }

    // MARK: Zoom scroll view

    static func zoomViewLayout(bounds: CGSize, hostFrame: CGRect, contentSize: CGSize, zoom: CGFloat) {
        emit("""
        ZSV layout bounds=\(String(format: "%.0fx%.0f", bounds.width, bounds.height)) \
        host=\(String(format: "%.0fx%.0f", hostFrame.width, hostFrame.height)) \
        content=\(String(format: "%.0fx%.0f", contentSize.width, contentSize.height)) \
        zoom=\(String(format: "%.2f", zoom))
        """)
    }

    private static var lastScrollEmit: CFTimeInterval = 0
    static func zoomViewDidScroll(offset: CGPoint, zoom: CGFloat, dragging: Bool) {
        let now = CACurrentMediaTime()
        guard now - lastScrollEmit > 0.25 else { return }
        lastScrollEmit = now
        emit("""
        ZSV didScroll offset=\(String(format: "%.0f,%.0f", offset.x, offset.y)) \
        zoom=\(String(format: "%.2f", zoom)) dragging=\(dragging)
        """)
    }

    static func pullFired() {
        emit("PULL FIRED -> adding page")
    }
}
