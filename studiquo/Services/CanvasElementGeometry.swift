import Foundation
import CoreGraphics

/// Which edge or corner a resize handle is pinned to, as unit offsets from
/// the element's centre. Mirrors `NoteEditorView.swift`'s own private
/// `ResizeAnchor` exactly (same eight handles, same unit-offset meaning) —
/// kept as a separate type there rather than switched over to this one, so
/// this file can be added without touching that already-working, tested
/// code at all. See `CanvasElementGeometry`'s doc comment for why.
enum ResizeHandleAnchor: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: String { rawValue }

    var unitX: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    var unitY: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .left, .right: 0
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }
}

/// Pure drag-to-frame math for a positioned canvas element (drag/resize/
/// rotate), factored out of `NoteEditorView.swift`'s `EditablePageElement`
/// so the new slide canvas editor (design step 4) can use the exact same,
/// already-proven behaviour instead of a second, independently-written
/// implementation.
///
/// This is a *narrower* extraction than design step 4 originally proposed:
/// the real `EditablePageElement` turned out to be tightly woven together
/// with note-specific concerns that have no slide equivalent at all — lasso
/// selection, cross-page/pane photo dragging, the ink layer's touch
/// passthrough, study-tape/page-link tap behaviour. Turning that whole view
/// into one generic component shared by both features would mean a risky
/// rewrite of an already-working, well-tested piece of the notes editor for
/// comparatively little benefit. What *is* safely and usefully shared is
/// this file: the actual resize/rotate coordinate math, which never touched
/// any of those note-specific concerns to begin with. `EditablePageElement`
/// itself is intentionally left exactly as it was — not migrated to call
/// this — so this change carries zero risk to the notes feature.
enum CanvasElementGeometry {
    struct Frame: Equatable {
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
    }

    /// The new frame (fractional 0-1 canvas coordinates) for a resize-handle
    /// drag — the same math `EditablePageElement.applyResize` uses.
    /// `translation` is the raw screen-space drag delta (rotation not yet
    /// removed); `rotationDegrees` is the element's own current rotation,
    /// used to translate that screen-space delta into the element's own,
    /// possibly-tilted axes, so a handle on a rotated element still grows
    /// the edge it's attached to rather than whichever edge happens to face
    /// that way on screen.
    static func resized(
        from origin: Frame,
        anchor: ResizeHandleAnchor,
        translation: CGSize,
        canvasSize: CGSize,
        rotationDegrees: Double,
        minWidthPoints: CGFloat = 32,
        minHeightPoints: CGFloat = 24
    ) -> Frame {
        let canvasWidth = max(canvasSize.width, 1)
        let canvasHeight = max(canvasSize.height, 1)
        let radians = rotationDegrees * .pi / 180

        let localDX = translation.width * cos(radians) + translation.height * sin(radians)
        let localDY = -translation.width * sin(radians) + translation.height * cos(radians)

        let originWidth = origin.width * canvasWidth
        let originHeight = origin.height * canvasHeight

        var newWidth = originWidth
        var newHeight = originHeight
        if anchor.unitX != 0 {
            newWidth = min(max(originWidth + anchor.unitX * localDX, minWidthPoints), canvasWidth)
        }
        if anchor.unitY != 0 {
            newHeight = min(max(originHeight + anchor.unitY * localDY, minHeightPoints), canvasHeight)
        }

        // The opposite edge stays pinned: the centre moves by half of
        // whatever the dragged side gained, along the element's own axes.
        let shiftX = anchor.unitX * (newWidth - originWidth) / 2
        let shiftY = anchor.unitY * (newHeight - originHeight) / 2
        let canvasShiftX = shiftX * cos(radians) - shiftY * sin(radians)
        let canvasShiftY = shiftX * sin(radians) + shiftY * cos(radians)

        return Frame(
            centerX: min(max(origin.centerX + canvasShiftX / canvasWidth, 0.02), 0.98),
            centerY: min(max(origin.centerY + canvasShiftY / canvasHeight, 0.02), 0.98),
            width: newWidth / canvasWidth,
            height: newHeight / canvasHeight
        )
    }

    /// The rotation angle (degrees) for a rotation-handle drag, given the
    /// element's centre and the current touch point in the same coordinate
    /// space — the same math `EditablePageElement`'s rotation gesture uses.
    /// The handle sits above the element, so pointing straight up must read
    /// as zero degrees, hence the quarter turn added to `atan2`'s result.
    static func rotation(center: CGPoint, touch: CGPoint) -> Double {
        let angle = atan2(touch.y - center.y, touch.x - center.x)
        return angle * 180 / .pi + 90
    }

    /// The new centre (fractional 0-1 canvas coordinates) for a plain move
    /// drag, clamped to keep the element's centre from leaving the canvas
    /// entirely — the same clamp `EditablePageElement.moveGesture` applies.
    static func moved(from origin: CGPoint, translation: CGSize, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(origin.x + translation.width / max(canvasSize.width, 1), 0.03), 0.97),
            y: min(max(origin.y + translation.height / max(canvasSize.height, 1), 0.03), 0.97)
        )
    }

    // MARK: Align / distribute (design step 4's multi-selection commands)

    enum HorizontalAlignment { case left, center, right }
    enum VerticalAlignment { case top, center, bottom }

    /// New `centerX` values, one per `frames` entry in the same order, that
    /// line every frame up to a shared edge or center — PowerPoint's own
    /// "left/center/right align": everything moves to meet the outermost
    /// frame's edge (or the group's average center), not to one arbitrarily
    /// chosen "anchor" frame.
    static func aligned(_ frames: [Frame], horizontally alignment: HorizontalAlignment) -> [Double] {
        guard !frames.isEmpty else { return [] }
        switch alignment {
        case .left:
            let target = frames.map { $0.centerX - $0.width / 2 }.min() ?? 0
            return frames.map { target + $0.width / 2 }
        case .right:
            let target = frames.map { $0.centerX + $0.width / 2 }.max() ?? 0
            return frames.map { target - $0.width / 2 }
        case .center:
            let target = frames.map(\.centerX).reduce(0, +) / Double(frames.count)
            return frames.map { _ in target }
        }
    }

    static func aligned(_ frames: [Frame], vertically alignment: VerticalAlignment) -> [Double] {
        guard !frames.isEmpty else { return [] }
        switch alignment {
        case .top:
            let target = frames.map { $0.centerY - $0.height / 2 }.min() ?? 0
            return frames.map { target + $0.height / 2 }
        case .bottom:
            let target = frames.map { $0.centerY + $0.height / 2 }.max() ?? 0
            return frames.map { target - $0.height / 2 }
        case .center:
            let target = frames.map(\.centerY).reduce(0, +) / Double(frames.count)
            return frames.map { _ in target }
        }
    }

    /// New `centerX` values, one per `frames` entry in the same *input*
    /// order (not sorted order — each result lines up with its original
    /// index), that space every frame's center evenly between the
    /// leftmost and rightmost frame's own centers. Distributing only means
    /// something for 3 or more frames (2 are already evenly spaced by
    /// definition); fewer than that returns each frame's own center
    /// unchanged.
    static func distributedHorizontally(_ frames: [Frame]) -> [Double] {
        guard frames.count >= 3 else { return frames.map(\.centerX) }
        let sortedIndices = frames.indices.sorted { frames[$0].centerX < frames[$1].centerX }
        let first = frames[sortedIndices.first!].centerX
        let last = frames[sortedIndices.last!].centerX
        let step = (last - first) / Double(sortedIndices.count - 1)
        var result = [Double](repeating: 0, count: frames.count)
        for (rank, index) in sortedIndices.enumerated() {
            result[index] = first + step * Double(rank)
        }
        return result
    }

    /// One of the nine standard slide positions a single element can be
    /// snapped to with one tap — top/middle/bottom crossed with
    /// left/center/right, matching PowerPoint's own "Align" quick picks
    /// applied to the slide itself rather than to other elements (that's
    /// what `aligned(_:horizontally:)`/`(_:vertically:)` above already
    /// cover).
    enum QuickPosition: CaseIterable, Hashable {
        case topLeft, topCenter, topRight
        case middleLeft, center, middleRight
        case bottomLeft, bottomCenter, bottomRight
    }

    /// The new center for `frame` at `position`, keeping its current
    /// width/height — `margin` (a fraction of the canvas) is the gap left
    /// between the element and the slide's own edge for any position that
    /// isn't dead-center on that axis.
    static func quickPosition(_ position: QuickPosition, for frame: Frame, margin: Double = 0.04) -> (centerX: Double, centerY: Double) {
        let left = frame.width / 2 + margin
        let right = 1 - frame.width / 2 - margin
        let top = frame.height / 2 + margin
        let bottom = 1 - frame.height / 2 - margin

        let centerX: Double
        switch position {
        case .topLeft, .middleLeft, .bottomLeft: centerX = left
        case .topCenter, .center, .bottomCenter: centerX = 0.5
        case .topRight, .middleRight, .bottomRight: centerX = right
        }
        let centerY: Double
        switch position {
        case .topLeft, .topCenter, .topRight: centerY = top
        case .middleLeft, .center, .middleRight: centerY = 0.5
        case .bottomLeft, .bottomCenter, .bottomRight: centerY = bottom
        }
        return (centerX, centerY)
    }

    /// Whether `frame`'s unrotated bounding box (converted to screen points
    /// via `canvasSize`) overlaps `rect` — the rubber-band multi-select hit
    /// test (design step 4's remaining piece, `SlideElementsLayer`'s own
    /// drag-to-select gesture). Ignores rotation, the same simplification
    /// that gesture's own doc comment already discloses — a rotated
    /// element's true bounds are a tighter shape than this box, so this
    /// can occasionally select an element whose actual (rotated) silhouette
    /// the rubber band doesn't quite touch, never the other way around.
    static func frameIntersects(_ frame: Frame, rect: CGRect, canvasSize: CGSize) -> Bool {
        let screenFrame = CGRect(
            x: (frame.centerX - frame.width / 2) * canvasSize.width,
            y: (frame.centerY - frame.height / 2) * canvasSize.height,
            width: frame.width * canvasSize.width,
            height: frame.height * canvasSize.height
        )
        return screenFrame.intersects(rect)
    }

    static func distributedVertically(_ frames: [Frame]) -> [Double] {
        guard frames.count >= 3 else { return frames.map(\.centerY) }
        let sortedIndices = frames.indices.sorted { frames[$0].centerY < frames[$1].centerY }
        let first = frames[sortedIndices.first!].centerY
        let last = frames[sortedIndices.last!].centerY
        let step = (last - first) / Double(sortedIndices.count - 1)
        var result = [Double](repeating: 0, count: frames.count)
        for (rank, index) in sortedIndices.enumerated() {
            result[index] = first + step * Double(rank)
        }
        return result
    }

    // MARK: Smart guides (design step 4's last piece)

    struct SmartGuideResult: Equatable {
        var frame: Frame
        /// The canvas-fractional x of the vertical guide line to draw, if
        /// a horizontal-axis snap happened this call.
        var verticalGuideX: Double?
        /// The canvas-fractional y of the horizontal guide line to draw, if
        /// a vertical-axis snap happened this call.
        var horizontalGuideY: Double?
    }

    private static func candidatesX(_ frame: Frame) -> [Double] {
        [frame.centerX - frame.width / 2, frame.centerX, frame.centerX + frame.width / 2]
    }

    private static func candidatesY(_ frame: Frame) -> [Double] {
        [frame.centerY - frame.height / 2, frame.centerY, frame.centerY + frame.height / 2]
    }

    /// The closest (target, own) pair within `tolerance`, or `nil` if none
    /// qualifies. `own` is whichever of `ownCandidates` matched, so the
    /// caller can shift the whole frame by `target - own` rather than
    /// snapping only the matched edge in isolation.
    private static func closestMatch(_ ownCandidates: [Double], _ targets: [Double], tolerance: Double) -> (target: Double, own: Double)? {
        var best: (target: Double, own: Double, distance: Double)?
        for own in ownCandidates {
            for target in targets {
                let distance = abs(target - own)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance {
                    best = (target, own, distance)
                }
            }
        }
        return best.map { ($0.target, $0.own) }
    }

    /// Nudges `frame` to align with `others` (or the canvas's own center
    /// line) whenever it's already within `toleranceScreenPoints` of a
    /// match — PowerPoint's "smart guides": drag near alignment and it
    /// snaps the rest of the way, with a guide line marking what it
    /// snapped to. Matches on edge-to-edge, edge-to-center, or
    /// center-to-center on each axis independently; the closest match
    /// within tolerance wins. Returns `frame` unchanged (no guides) when
    /// nothing is close enough.
    static func smartGuided(
        _ frame: Frame,
        against others: [Frame],
        canvasSize: CGSize,
        toleranceScreenPoints: CGFloat = 6
    ) -> SmartGuideResult {
        let toleranceX = Double(toleranceScreenPoints) / Double(max(canvasSize.width, 1))
        let toleranceY = Double(toleranceScreenPoints) / Double(max(canvasSize.height, 1))

        let targetsX = others.flatMap(candidatesX) + [0.5]
        let targetsY = others.flatMap(candidatesY) + [0.5]

        var result = frame
        var guideX: Double?
        var guideY: Double?

        if let match = closestMatch(candidatesX(frame), targetsX, tolerance: toleranceX) {
            result.centerX += match.target - match.own
            guideX = match.target
        }
        if let match = closestMatch(candidatesY(frame), targetsY, tolerance: toleranceY) {
            result.centerY += match.target - match.own
            guideY = match.target
        }

        return SmartGuideResult(frame: result, verticalGuideX: guideX, horizontalGuideY: guideY)
    }
}
