import XCTest
@testable import studiquo

/// How the pen's hold-to-correct recognisers rank against each other.
///
/// The per-recogniser tests in `InkCanvasPenShapeRecognitionTests` feed each
/// one a clean shape in isolation. What goes wrong in use is two of them both
/// claiming the same stroke, so these run the whole ordering
/// (`InkCanvasView.classifyHold`) on hand-drawn-looking strokes: seeded jitter,
/// rounded corners, uneven sizes.
final class PenShapeBoundaryTests: XCTestCase {
    typealias Kind = InkCanvasView.HoldCorrection

    // MARK: Stroke generation

    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        mutating func signed() -> CGFloat { next() * 2 - 1 }
    }

    /// Walks `vertices` at about `spacing` points per sample, rounds each
    /// interior corner by `round` of the adjacent side, and adds `jitter`.
    private func walk(_ vertices: [CGPoint], round: CGFloat = 0, spacing: CGFloat = 5,
                      jitter: CGFloat, seed: UInt64) -> [CGPoint] {
        var rng = SeededRandom(state: seed)
        var path = vertices
        if round > 0, vertices.count > 2 {
            path = [vertices[0]]
            for k in 1..<(vertices.count - 1) {
                let a = vertices[k - 1], b = vertices[k], c = vertices[k + 1]
                let into = CGPoint(x: b.x + (a.x - b.x) * round, y: b.y + (a.y - b.y) * round)
                let out = CGPoint(x: b.x + (c.x - b.x) * round, y: b.y + (c.y - b.y) * round)
                // Quadratic Bezier from `into` to `out` with `b` as control:
                // the corner is cut, never reached.
                path.append(into)
                for step in 1..<6 {
                    let t = CGFloat(step) / 6, u = 1 - t
                    path.append(CGPoint(x: u*u*into.x + 2*u*t*b.x + t*t*out.x,
                                        y: u*u*into.y + 2*u*t*b.y + t*t*out.y))
                }
                path.append(out)
            }
            path.append(vertices.last!)
        }
        var points: [CGPoint] = []
        for (a, b) in zip(path, path.dropFirst()) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / spacing))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + rng.signed() * jitter,
                                      y: a.y + (b.y - a.y) * t + rng.signed() * jitter))
            }
        }
        points.append(path.last!)
        return points
    }

    private func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, turns: CGFloat = 1.0,
                         tilt: CGFloat = 0, wobble amount: CGFloat = 0.04, squash: CGFloat = 0, jitter: CGFloat, seed: UInt64) -> [CGPoint] {
        var rng = SeededRandom(state: seed)
        let count = max(24, Int(2 * .pi * max(rx, ry) / 5))
        let phase = rng.next() * 2 * .pi
        return (0...Int(CGFloat(count) * turns)).map { i in
            let angle = phase + CGFloat(i) / CGFloat(count) * 2 * .pi
            // Hand-drawn loops are never perfectly regular: radius wobbles.
            let wobble = 1 + amount * sin(angle * 2 + phase) + amount * 0.6 * sin(angle * 3 + 2 * phase)
            // `squash` flattens one side, the egg/D shape of a quickly drawn loop.
            let flat = 1 - squash * max(0, sin(angle))
            let x = cos(angle) * rx * wobble, y = sin(angle) * ry * wobble * flat
            return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt) + rng.signed() * jitter,
                           y: center.y + x * sin(tilt) + y * cos(tilt) + rng.signed() * jitter)
        }
    }

    private func stroke(_ points: [CGPoint]) -> InkStroke {
        InkStroke(points: points.enumerated().map { InkPoint(location: $1, force: 0.5, timeOffset: Double($0) / 60) },
                  colorHex: "#000000", width: 3)
    }

    private func classify(_ points: [CGPoint]) -> Kind? {
        guard let first = points.first, let last = points.last else { return nil }
        return InkCanvasView.classifyHold(
            stroke(points), start: first, current: last,
            enabled: [.rectangle, .triangle, .polyline, .parabola, .curve, .line, .ellipse])?.kind
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Sample sets

    private struct Sample { let name: String; let expected: Set<Kind?>; let points: [CGPoint] }

    private func samples() -> [Sample] {
        var all: [Sample] = []
        var seed: UInt64 = 1
        for jitter in [CGFloat(0.5), 1.2] {
            for scale in [CGFloat(0.6), 1.0, 2.2] {
                for round in [CGFloat(0.0), 0.12] {
                    seed += 1
                    let s = scale
                    let tag = "j\(jitter) s\(scale) r\(round)"
                    func shape(_ name: String, _ expected: Set<Kind?>, _ v: [CGPoint]) {
                        seed += 1
                        all.append(Sample(name: "\(name) \(tag)", expected: expected,
                                          points: walk(v, round: round, jitter: jitter, seed: seed)))
                    }
                    // Closed polygons.
                    shape("triangle-isosceles", [.triangle], [p(100*s,0), p(200*s,170*s), p(0,170*s), p(100*s,0)])
                    shape("triangle-right", [.triangle], [p(0,0), p(0,160*s), p(190*s,160*s), p(0,0)])
                    shape("triangle-flat", [.triangle], [p(40*s,0), p(220*s,90*s), p(0,90*s), p(40*s,0)])
                    shape("square", [.rectangle], [p(0,0), p(150*s,0), p(150*s,150*s), p(0,150*s), p(0,0)])
                    shape("rect-wide", [.rectangle], [p(0,0), p(240*s,0), p(240*s,110*s), p(0,110*s), p(0,0)])
                    // Open polylines.
                    shape("V", [.polyline], [p(0,0), p(80*s,150*s), p(160*s,0)])
                    shape("Z", [.polyline], [p(0,0), p(140*s,0), p(0,140*s), p(140*s,140*s)])
                    shape("L", [.polyline, nil], [p(0,0), p(0,150*s), p(120*s,150*s)])
                    shape("check", [.polyline], [p(0,70*s), p(50*s,130*s), p(180*s,0)])
                    shape("zigzag", [.polyline], [p(0,100*s), p(60*s,0), p(120*s,100*s), p(180*s,0)])
                    shape("tri-open", [.polyline, .triangle], [p(100*s,0), p(200*s,170*s), p(0,170*s)])
                    shape("line", [.line], [p(0,0), p(200*s,40*s)])
                    shape("line-flat", [.line], [p(0,0), p(220*s,3*s)])
                }
                // Loops and curves, drawn with the same jitter.
                seed += 1
                let c = p(120 * scale, 120 * scale)
                let tag = "j\(jitter) s\(scale)"
                all.append(Sample(name: "circle \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, jitter: jitter, seed: seed)))
                all.append(Sample(name: "circle-overshoot \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, turns: 1.08, jitter: jitter, seed: seed + 1)))
                all.append(Sample(name: "ellipse-1.5 \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 110*scale, ry: 72*scale, jitter: jitter, seed: seed + 2)))
                all.append(Sample(name: "ellipse-2.2 \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 140*scale, ry: 62*scale, jitter: jitter, seed: seed + 3)))
                all.append(Sample(name: "ellipse-tilted \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 120*scale, ry: 60*scale, tilt: .pi / 5, jitter: jitter, seed: seed + 4)))
                // Arcs and waves.
                var rng = SeededRandom(state: seed + 9)
                func curve(_ name: String, _ expected: Set<Kind?>, _ f: (CGFloat) -> CGFloat, xs: ClosedRange<CGFloat>) {
                    let n = 60
                    let pts = (0...n).map { i -> CGPoint in
                        let x = xs.lowerBound + (xs.upperBound - xs.lowerBound) * CGFloat(i) / CGFloat(n)
                        return p(x * scale, f(x) * scale + rng.signed() * jitter)
                    }
                    all.append(Sample(name: "\(name) \(tag)", expected: expected, points: pts))
                }
                curve("U", [.parabola], { x in 0.011 * (x - 100) * (x - 100) }, xs: 0...200)
                curve("cap", [.parabola], { x in 110 - 0.011 * (x - 100) * (x - 100) }, xs: 0...200)
                curve("half-U", [.parabola, .curve], { x in 0.0055 * x * x }, xs: 0...200)
                curve("sine", [.curve], { x in 60 * sin(x / 32) }, xs: 0...300)
                curve("exp", [.curve, .parabola, .polyline], { x in 8 * exp(x / 60) }, xs: 0...200)
                curve("log", [.curve, .parabola, .polyline], { x in 70 * log(1 + x / 20) }, xs: 0...200)
                curve("gentle-arc", [.parabola, .curve, .line], { x in 0.0012 * (x - 100) * (x - 100) }, xs: 0...200)
            }
        }

        // Stress sets: the shapes a real hand produces near each boundary.
        for jitter in [CGFloat(0.6), 1.3] {
            for scale in [CGFloat(0.7), 1.4] {
                seed += 7
                let c = p(120 * scale, 120 * scale)
                let tag = "j\(jitter) s\(scale)"
                for (k, wob) in [CGFloat(0.06), 0.10, 0.14].enumerated() {
                    all.append(Sample(name: "circle-wobbly\(k) \(tag)", expected: [.ellipse],
                                      points: ellipse(center: c, rx: 80*scale, ry: 80*scale, turns: 1.05,
                                                      wobble: wob, jitter: jitter, seed: seed + UInt64(k))))
                }
                all.append(Sample(name: "circle-egg \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, squash: 0.18, jitter: jitter, seed: seed + 5)))
                all.append(Sample(name: "circle-D \(tag)", expected: [.ellipse],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, squash: 0.3, jitter: jitter, seed: seed + 6)))
                for (k, round) in [CGFloat(0.22), 0.32].enumerated() {
                    let s = scale
                    all.append(Sample(name: "triangle-rounded\(k) \(tag)", expected: [.triangle],
                                      points: walk([p(100*s,0), p(200*s,170*s), p(0,170*s), p(100*s,0)],
                                                   round: round, jitter: jitter, seed: seed + 10 + UInt64(k))))
                    all.append(Sample(name: "square-rounded\(k) \(tag)", expected: [.rectangle, .ellipse],
                                      points: walk([p(0,0), p(150*s,0), p(150*s,150*s), p(0,150*s), p(0,0)],
                                                   round: round, jitter: jitter, seed: seed + 20 + UInt64(k))))
                    all.append(Sample(name: "V-rounded\(k) \(tag)", expected: [.polyline, .parabola],
                                      points: walk([p(0,0), p(80*s,150*s), p(160*s,0)],
                                                   round: round, jitter: jitter, seed: seed + 30 + UInt64(k))))
                    all.append(Sample(name: "Z-rounded\(k) \(tag)", expected: [.polyline, .curve, nil],
                                      points: walk([p(0,0), p(140*s,0), p(0,140*s), p(140*s,140*s)],
                                                   round: round, jitter: jitter, seed: seed + 40 + UInt64(k))))
                }
                // Closed shapes that are none of the three: better left alone
                // than redrawn as something else.
                let d = 90 * scale
                all.append(Sample(name: "diamond \(tag)", expected: [nil, .ellipse],
                                  points: walk([p(d,0), p(2*d,d), p(d,2*d), p(0,d), p(d,0)], round: 0.08, jitter: jitter, seed: seed + 60)))
                all.append(Sample(name: "figure-8 \(tag)", expected: [nil],
                                  points: (0...80).map { i -> CGPoint in
                                      let t = CGFloat(i) / 80 * 2 * .pi
                                      return p(d + sin(t) * d, d + sin(2 * t) * d * 0.5)
                                  }))
                // Open loops: stopped well short of closing.
                all.append(Sample(name: "arc-3/4 \(tag)", expected: [.curve, .parabola, nil],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, turns: 0.72, jitter: jitter, seed: seed + 50)))
                all.append(Sample(name: "arc-half \(tag)", expected: [.parabola, .curve, nil],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, turns: 0.5, jitter: jitter, seed: seed + 51).map { p($0.x, 240*scale - $0.y) }))
                all.append(Sample(name: "arc-quarter \(tag)", expected: [.parabola, .curve, nil],
                                  points: ellipse(center: c, rx: 80*scale, ry: 80*scale, turns: 0.25, jitter: jitter, seed: seed + 52)))
                // Tall narrow U / cap, and a shallow wave.
                var rng = SeededRandom(state: seed + 60)
                func curve(_ name: String, _ expected: Set<Kind?>, _ f: (CGFloat) -> CGFloat, xs: ClosedRange<CGFloat>) {
                    let pts = (0...60).map { i -> CGPoint in
                        let x = xs.lowerBound + (xs.upperBound - xs.lowerBound) * CGFloat(i) / 60
                        return p(x * scale, f(x) * scale + rng.signed() * jitter)
                    }
                    all.append(Sample(name: "\(name) \(tag)", expected: expected, points: pts))
                }
                curve("U-narrow", [.parabola], { x in 0.04 * (x - 40) * (x - 40) }, xs: 0...80)
                curve("U-wide", [.parabola], { x in 0.004 * (x - 150) * (x - 150) }, xs: 0...300)
                curve("wave-shallow", [.curve], { x in 22 * sin(x / 28) }, xs: 0...280)
                curve("S", [.curve, .polyline], { x in 90 / (1 + exp(-(x - 100) / 18)) }, xs: 0...200)
            }
        }
        return all
    }

    /// Prints the confusion table, then fails for every stroke given the wrong
    /// correction.
    func testNoStrokeIsClaimedByTheWrongRecogniser() {
        var wrong: [String] = []
        var table: [String: [String: Int]] = [:]
        for sample in samples() {
            let got = classify(sample.points)
            let family = String(sample.name.split(separator: " ")[0])
            table[family, default: [:]][got.map { "\($0)" } ?? "none", default: 0] += 1
            if !sample.expected.contains(got) {
                wrong.append("\(sample.name): expected \(sample.expected.map { $0.map { "\($0)" } ?? "none" }.sorted()), got \(got.map { "\($0)" } ?? "none")")
            }
        }
        for family in table.keys.sorted() {
            print("BOUNDARY \(family): \(table[family]!.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) strokes were corrected to the wrong shape:\n" + wrong.joined(separator: "\n"))
    }
}
