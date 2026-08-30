import CoreGraphics
import Foundation

/// Sampling-rate-independent geometry used by the pen's scratch-out gesture.
///
/// Touch events arrive at very different densities depending on Pencil speed,
/// the iPad model and whether the page is split.  Classification therefore
/// runs on an evenly spaced polyline and deliberately ignores the selected pen
/// width.  Pen width is a rendering choice; it must not decide whether the
/// same physical back-and-forth motion is a scribble.
struct ScribbleAnalysis: Equatable {
    let pathLength: CGFloat
    let diagonal: CGFloat
    let lengthRatio: CGFloat
    let directionChanges: Int
    let axisReversals: Int
    let selfIntersections: Int
    let absoluteTurning: CGFloat
    let qualifies: Bool
}

enum ScribbleClassifier {
    static func analyze(_ rawPoints: [CGPoint]) -> ScribbleAnalysis {
        let points = deduplicated(rawPoints, minimumDistance: 0.75)
        let pathLength = polylineLength(points)
        let bounds = pointBounds(points)
        let diagonal = hypot(bounds.width, bounds.height)
        let ratio = diagonal > 0 ? pathLength / diagonal : 0

        guard points.count >= 4,
              max(bounds.width, bounds.height) >= 8,
              pathLength >= 24,
              diagonal > 0 else {
            return ScribbleAnalysis(
                pathLength: pathLength,
                diagonal: diagonal,
                lengthRatio: ratio,
                directionChanges: 0,
                axisReversals: 0,
                selfIntersections: 0,
                absoluteTurning: 0,
                qualifies: false
            )
        }

        // Keep enough detail to retain tight crossings while making the
        // result independent of coalesced-touch density.
        let spacing = min(4, max(2, diagonal / 18))
        let sampled = resampled(points, spacing: spacing)
        let vectors = zip(sampled, sampled.dropFirst()).compactMap { start, end -> CGPoint? in
            let vector = CGPoint(x: end.x - start.x, y: end.y - start.y)
            return hypot(vector.x, vector.y) > 0.25 ? vector : nil
        }

        var directionChanges = 0
        var absoluteTurning: CGFloat = 0
        for (previous, current) in zip(vectors, vectors.dropFirst()) {
            let dot = previous.x * current.x + previous.y * current.y
            let cross = previous.x * current.y - previous.y * current.x
            let angle = abs(atan2(cross, dot))
            absoluteTurning += angle
            if angle >= 1.15 { directionChanges += 1 }
        }

        let axisReversals = max(
            reversalCount(vectors.map(\.x), minimumMagnitude: spacing * 0.35),
            reversalCount(vectors.map(\.y), minimumMagnitude: spacing * 0.35)
        )
        let intersections = selfIntersectionCount(sampled, limit: 4)

        // Three independent shapes count as deliberate scratch-out:
        // back-and-forth hatching, a tangled crossing, or repeated loops.
        // A single circle/ellipse is intentionally excluded; it turns only
        // about 2π and is a normal drawing operation even when it overlaps
        // older ink.
        let backAndForth = axisReversals >= 2 && directionChanges >= 2 && ratio >= 1.4
        let tangled = intersections >= 2 && ratio >= 1.25
        let repeatedLoops = absoluteTurning >= .pi * 2.75 && ratio >= 1.8
        let qualifies = backAndForth || tangled || repeatedLoops

        return ScribbleAnalysis(
            pathLength: pathLength,
            diagonal: diagonal,
            lengthRatio: ratio,
            directionChanges: directionChanges,
            axisReversals: axisReversals,
            selfIntersections: intersections,
            absoluteTurning: absoluteTurning,
            qualifies: qualifies
        )
    }

    private static func deduplicated(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() {
            guard let last = result.last,
                  hypot(point.x - last.x, point.y - last.y) >= minimumDistance else { continue }
            result.append(point)
        }
        if let last = points.last, result.last != last { result.append(last) }
        return result
    }

    private static func pointBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    private static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
    }

    private static func resampled(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [first] }
        var result = [first]
        var carried: CGFloat = 0

        for (start, end) in zip(points, points.dropFirst()) {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            var travelled = spacing - carried
            while travelled < length {
                let progress = travelled / length
                result.append(CGPoint(x: start.x + dx * progress, y: start.y + dy * progress))
                travelled += spacing
            }
            carried = max(0, length - (travelled - spacing))
            if carried >= spacing { carried.formTruncatingRemainder(dividingBy: spacing) }
        }

        if let last = points.last, result.last != last { result.append(last) }
        return result
    }

    private static func reversalCount(_ values: [CGFloat], minimumMagnitude: CGFloat) -> Int {
        var previousSign: CGFloat?
        var reversals = 0
        for value in values where abs(value) >= minimumMagnitude {
            let sign: CGFloat = value < 0 ? -1 : 1
            if let previousSign, sign != previousSign { reversals += 1 }
            previousSign = sign
        }
        return reversals
    }

    private static func selfIntersectionCount(_ points: [CGPoint], limit: Int) -> Int {
        guard points.count >= 5 else { return 0 }
        let segments = Array(zip(points, points.dropFirst()))
        var count = 0
        for firstIndex in segments.indices {
            let first = segments[firstIndex]
            for secondIndex in segments.indices.dropFirst(firstIndex + 2) {
                if firstIndex == 0 && secondIndex == segments.count - 1 { continue }
                let second = segments[secondIndex]
                if segmentsIntersect(first.0, first.1, second.0, second.1) {
                    count += 1
                    if count >= limit { return count }
                }
            }
        }
        return count
    }

    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let denominator = (d.y - c.y) * (b.x - a.x) - (d.x - c.x) * (b.y - a.y)
        guard abs(denominator) > 0.001 else { return false }
        let ua = ((d.x - c.x) * (a.y - c.y) - (d.y - c.y) * (a.x - c.x)) / denominator
        let ub = ((b.x - a.x) * (a.y - c.y) - (b.y - a.y) * (a.x - c.x)) / denominator
        return ua > 0.02 && ua < 0.98 && ub > 0.02 && ub < 0.98
    }
}
