import XCTest
import SwiftMath
@testable import studiquo

/// Step 1 spike: how far does SwiftMath get on the AI-output corpus, how does
/// it behave on half-streamed input and extreme widths, and how fast is it?
/// Prints a report (search the log for "SPIKE") and asserts only the things
/// the design relies on: it never crashes and failures are detectable.
final class SwiftMathSpikeTests: XCTestCase {
    private func mathSegments(of sample: AIMathSample) -> [String] {
        MathSpikeSegmenter.segments(in: sample.text).compactMap {
            switch $0 {
            case .inline(let m), .display(let m): return m
            case .text: return nil
            }
        }
    }

    func testCoverageOfTheCorpus() {
        var perCategory: [AIMathSample.Category: (total: Int, failed: Int)] = [:]
        var failures: [String] = []
        for sample in AIMathSamples.all where !sample.isPartial && sample.category != .falsePositive {
            for math in mathSegments(of: sample) {
                var entry = perCategory[sample.category] ?? (0, 0)
                entry.total += 1
                if let error = MathSpikeSegmenter.parseError(math) {
                    entry.failed += 1
                    failures.append("\(sample.id): \(error)  <= \(math.prefix(60))")
                }
                perCategory[sample.category] = entry
            }
        }
        var lines = ["SPIKE coverage (parse failures / math segments)"]
        var total = 0, failed = 0
        for category in AIMathSample.Category.allCases {
            guard let e = perCategory[category] else { continue }
            lines.append(String(format: "SPIKE   %-18@ %2d / %2d", category.rawValue as NSString, e.failed, e.total))
            total += e.total; failed += e.failed
        }
        lines.append("SPIKE   TOTAL              \(failed) / \(total)")
        lines.append(contentsOf: failures.map { "SPIKE   FAIL \($0)" })
        print(lines.joined(separator: "\n"))

        // Outside the deliberately unsupported samples, only these commands
        // are missing from SwiftMath. Step 2/4 maps them (∴ ∵ ■) or drops them
        // (\hline); anything else failing here is news.
        let knownGaps: Set<String> = ["\\blacksquare", "\\because", "\\therefore", "\\hline"]
        for sample in AIMathSamples.all where !sample.isPartial && ![.unsupported, .falsePositive].contains(sample.category) {
            for math in mathSegments(of: sample) {
                guard let error = MathSpikeSegmenter.parseError(math) else { continue }
                let command = error.replacingOccurrences(of: "Invalid command ", with: "")
                XCTAssertTrue(knownGaps.contains(command), "\(sample): 想定外の未対応: \(error)")
            }
        }
        XCTAssertGreaterThan(perCategory[.unsupported]?.failed ?? 0, 0, "未対応のサンプルが検出できること")
        // The spike's headline number: share of math segments SwiftMath can draw.
        XCTAssertGreaterThan(Double(total - failed) / Double(total), 0.9)
    }

    func testMixedProseLinesParse() {
        var failed: [String] = []
        var total = 0
        for sample in AIMathSamples.all where !sample.isPartial && sample.category != .falsePositive {
            for block in MathSpikeSegmenter.blocks(for: sample.text) {
                guard case .line(let latex) = block else { continue }
                total += 1
                if let error = MathSpikeSegmenter.parseError(latex) { failed.append("\(sample.id): \(error)") }
            }
        }
        print("SPIKE mixed prose lines: \(failed.count) failed of \(total)\n" + failed.map { "SPIKE   FAIL \($0)" }.joined(separator: "\n"))
    }

    /// Every state a streaming reply passes through must be safe to hand to
    /// the parser and the typesetter.
    func testEveryStreamingPrefixIsSafe() {
        var count = 0
        var errors = 0
        let start = CFAbsoluteTimeGetCurrent()
        for sample in AIMathSamples.all {
            for prefix in AIMathSamples.streamingPrefixes(of: sample.text, step: 5) {
                for block in MathSpikeSegmenter.blocks(for: prefix) {
                    let latex: String
                    switch block {
                    case .line(let l), .display(let l): latex = l
                    case .gap: continue
                    }
                    count += 1
                    if MathSpikeSegmenter.parseError(latex) != nil { errors += 1; continue }
                    let label = MTMathUILabel()
                    label.fontSize = 17
                    label.preferredMaxLayoutWidth = 340
                    label.latex = latex
                    _ = label.sizeThatFits(CGSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
                }
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("SPIKE streaming prefixes: \(count) blocks, \(errors) not parseable (shown as plain text until complete), \(Int(ms)) ms total")
    }

    func testExtremeWidthsDoNotCrash() {
        let widths: [CGFloat] = [0, 1, 20, 120, 340, 760, 4000]
        var typeset = 0
        let start = CFAbsoluteTimeGetCurrent()
        for sample in AIMathSamples.all where !sample.isPartial {
            for block in MathSpikeSegmenter.blocks(for: sample.text) {
                let latex: String
                switch block {
                case .line(let l), .display(let l): latex = l
                case .gap: continue
                }
                guard MathSpikeSegmenter.parseError(latex) == nil else { continue }
                for width in widths {
                    let label = MTMathUILabel()
                    label.fontSize = 17
                    label.preferredMaxLayoutWidth = width
                    label.latex = latex
                    let size = label.sizeThatFits(CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude))
                    XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                    typeset += 1
                }
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("SPIKE extreme widths: \(typeset) typesets, \(Int(ms)) ms (\(String(format: "%.2f", ms / Double(max(typeset, 1)))) ms each)")
    }

    func testTypesettingCostOfALongConversation() {
        // About 300 formulas, like a long conversation shown at once.
        let replies = AIMathSamples.all.filter { $0.category == .fullReply || $0.hasInlineMath }
        var blocks: [String] = []
        while blocks.count < 300 {
            for sample in replies {
                for block in MathSpikeSegmenter.blocks(for: sample.text) {
                    if case .line(let l) = block, MathSpikeSegmenter.parseError(l) == nil { blocks.append(l) }
                }
            }
        }
        blocks = Array(blocks.prefix(300))
        let start = CFAbsoluteTimeGetCurrent()
        for latex in blocks {
            let label = MTMathUILabel()
            label.fontSize = 17
            label.preferredMaxLayoutWidth = 640
            label.latex = latex
            _ = label.sizeThatFits(CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("SPIKE 300 prose lines typeset: \(Int(ms)) ms (\(String(format: "%.2f", ms / 300)) ms each)")
    }
}
