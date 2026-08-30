import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// One sample taken from the pencil as it moves.
struct InkPoint: Equatable, Codable {
    var location: CGPoint
    /// Normalised 0...1. Falls back to 0.5 for inputs with no force.
    var force: CGFloat
    /// Seconds since the stroke began.
    var timeOffset: TimeInterval
}

/// A single continuous mark.
///
/// Deliberately a value type holding raw samples: the renderer derives the
/// outline each time it draws, so a stroke can be transformed (straightened,
/// for instance) by swapping its points without any other state to keep in
/// sync — the failure mode that dogged the PencilKit implementation.
struct InkStroke: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var points: [InkPoint]
    var colorHex: String
    /// Nominal width in points, before pressure is applied.
    var width: CGFloat
    var opacity: CGFloat
    var isHighlighter: Bool

    init(
        id: UUID = UUID(),
        points: [InkPoint] = [],
        colorHex: String,
        width: CGFloat,
        opacity: CGFloat = 1,
        isHighlighter: Bool = false
    ) {
        self.id = id
        self.points = points
        self.colorHex = colorHex
        self.width = width
        self.opacity = opacity
        self.isHighlighter = isHighlighter
    }

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first.location, size: .zero)
        for point in points.dropFirst() {
            rect = rect.union(CGRect(origin: point.location, size: .zero))
        }
        return rect.insetBy(dx: -width, dy: -width)
    }

    /// Total distance travelled — used to tell a deliberate scribble (which
    /// doubles back over itself many times) from ordinary handwriting.
    var pathLength: CGFloat {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + hypot(pair.1.location.x - pair.0.location.x, pair.1.location.y - pair.0.location.y)
        }
    }

    /// Replaces the samples with an evenly spaced run between the two ends,
    /// keeping the original pressure profile flat so the line reads as
    /// deliberate rather than hand-drawn.
    func straightened() -> InkStroke {
        guard let first = points.first, let last = points.last else { return self }
        let steps = 48
        let averageForce = points.reduce(0) { $0 + $1.force } / CGFloat(points.count)
        let duration = last.timeOffset
        var copy = self
        copy.points = (0...steps).map { step in
            let progress = CGFloat(step) / CGFloat(steps)
            return InkPoint(
                location: CGPoint(
                    x: first.location.x + (last.location.x - first.location.x) * progress,
                    y: first.location.y + (last.location.y - first.location.y) * progress
                ),
                force: averageForce,
                timeOffset: duration * Double(progress)
            )
        }
        return copy
    }
}

/// The full contents of one page.
struct InkDrawing: Equatable, Codable {
    var strokes: [InkStroke] = []

    var isEmpty: Bool { strokes.isEmpty }

    func data() throws -> Data { try JSONEncoder().encode(self) }

    init(strokes: [InkStroke] = []) { self.strokes = strokes }

    init(data: Data) throws { self = try JSONDecoder().decode(InkDrawing.self, from: data) }

    /// Applies a transform (page rotation, notably) to every stroke's points.
    func transformed(by transform: CGAffineTransform) -> InkDrawing {
        InkDrawing(strokes: strokes.map { stroke in
            var copy = stroke
            copy.points = stroke.points.map { point in
                var updated = point
                updated.location = point.location.applying(transform)
                return updated
            }
            return copy
        })
    }

    /// Uniformly rescales the whole drawing, stroke widths included.
    ///
    /// `transformed(by:)` deliberately leaves widths alone because its caller
    /// is page rotation, which must not change how thick a line is. Moving
    /// ink between coordinate spaces has to carry the widths across too, or
    /// a converted page comes back with hairlines.
    func scaled(by factor: CGFloat) -> InkDrawing {
        guard factor > 0, abs(factor - 1) > 0.0001 else { return self }
        return InkDrawing(strokes: strokes.map { stroke in
            var copy = stroke
            copy.width = stroke.width * factor
            copy.points = stroke.points.map { point in
                var updated = point
                updated.location = CGPoint(
                    x: point.location.x * factor,
                    y: point.location.y * factor
                )
                return updated
            }
            return copy
        })
    }

    /// Loads either format transparently: the new JSON encoding, or — for
    /// pages drawn before the engine switch — the old PencilKit binary
    /// format, converted on the fly so existing ink isn't lost.
    static func load(from data: Data) -> InkDrawing? {
        if let native = try? InkDrawing(data: data) { return native }
        if let legacy = try? PKDrawing(data: data) { return InkDrawing(migratingFrom: legacy) }
        return nil
    }

    /// Rasterises the drawing, mirroring `PKDrawing.image(from:scale:)` so
    /// the call sites that used to read PencilKit's output (thumbnails, PDF
    /// and PNG export) only had to swap the type they call it on.
    func image(from rect: CGRect, scale: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { context in
            context.cgContext.translateBy(x: -rect.minX * scale, y: -rect.minY * scale)
            context.cgContext.scaleBy(x: scale, y: scale)
            for stroke in strokes {
                let path = InkCanvasView.ribbon(for: stroke)
                UIColor(inkHex: stroke.colorHex).withAlphaComponent(stroke.opacity).setFill()
                path.fill()
            }
        }
    }

    /// Best-effort conversion from a PencilKit drawing. Curved/masked
    /// erasing detail doesn't carry over — PencilKit doesn't expose it — but
    /// every stroke's shape, color and pressure profile does.
    init(migratingFrom pkDrawing: PKDrawing) {
        strokes = pkDrawing.strokes.map { stroke in
            let points = Array(stroke.path).map { point in
                InkPoint(location: point.location, force: point.force, timeOffset: point.timeOffset)
            }
            let uiColor = (stroke.ink.color)
            var alpha: CGFloat = 1
            uiColor.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            return InkStroke(
                points: points,
                colorHex: uiColor.toHex(),
                width: stroke.ink.inkType == .marker ? 8 : 4,
                opacity: alpha,
                isHighlighter: stroke.ink.inkType == .marker
            )
        }
    }
}
