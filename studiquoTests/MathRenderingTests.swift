import XCTest
import SwiftUI
@testable import studiquo

@MainActor
final class MathRenderingTests: XCTestCase {
    // MARK: What can be typeset

    func testCommandsSwiftMathLacksAreMappedSoTheyRender() {
        for latex in [#"\therefore x=1"#, #"\because y>0"#, #"A \blacksquare"#, #"\begin{array}{c|cc} x & 0 \\ \hline y & 1 \end{array}"#, #"\mathscr{F}"#] {
            XCTAssertTrue(MathRendering.isRenderable(latex), latex)
        }
        XCTAssertEqual(MathRendering.normalized(#"\therefore x"#), #"\text{∴} x"#)
        XCTAssertEqual(MathRendering.normalized(#"a \\ \hline b"#), #"a \\  b"#)
    }

    func testUnsupportedAndUnfinishedFormulasAreNotRenderable() {
        for latex in [#"\boxed{x=1}"#, #"\ce{H2O}"#, #"\underbrace{a}_{b}"#, #"\frac{1"#, #"\left("#, #"\somethingunknown{x}"#] {
            XCTAssertFalse(MathRendering.isRenderable(latex), latex)
        }
    }

    /// Everything the corpus writes as supported math must be drawable.
    func testEveryFormulaInTheSupportedCorpusRenders() {
        for sample in AIMathSamples.all where ![.unsupported, .falsePositive, .streamingPrefix].contains(sample.category) {
            for segment in MathSegmenter.segments(in: sample.text) {
                switch segment {
                case .inlineMath(let m), .displayMath(let m):
                    XCTAssertTrue(MathRendering.isRenderable(m), "\(sample): 描画できない式: \(m.prefix(60))")
                default: break
                }
            }
        }
    }

    // MARK: Inline images

    private func ink(in image: UIImage, columns: ClosedRange<Double>, rows: ClosedRange<Double>) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        for y in Int(Double(height) * rows.lowerBound)..<Int(Double(height) * rows.upperBound) {
            for x in Int(Double(width) * columns.lowerBound)..<Int(Double(width) * columns.upperBound) where pixels[(y * width + x) * 4 + 3] > 40 {
                count += 1
            }
        }
        return count
    }

    func testAnInlineImageHasASizeADescentAndInk() throws {
        let fraction = try XCTUnwrap(MathRendering.inlineImage(latex: #"\frac{a}{b}"#, fontSize: 17, color: .black))
        XCTAssertGreaterThan(fraction.image.size.width, 5)
        XCTAssertGreaterThan(fraction.image.size.height, 17)
        XCTAssertGreaterThan(fraction.descent, 2, "分数は基準線より下にも伸びる")
        XCTAssertGreaterThan(ink(in: fraction.image, columns: 0...1, rows: 0...1), 20)
    }

    /// The image is drawn upright: in `a^{2}` the exponent is in the upper half.
    func testAnInlineImageIsNotUpsideDown() throws {
        let image = try XCTUnwrap(MathRendering.inlineImage(latex: "a^{2}", fontSize: 40, color: .black)).image
        let upper = ink(in: image, columns: 0.65...1, rows: 0...0.5)
        let lower = ink(in: image, columns: 0.65...1, rows: 0.5...1)
        XCTAssertGreaterThan(upper, lower * 2, "指数が上半分にあること(上下反転していない)")
    }

    func testAnUnrenderableFormulaGivesNoImage() {
        XCTAssertNil(MathRendering.inlineImage(latex: #"\boxed{x}"#, fontSize: 17, color: .black))
        XCTAssertNil(MathRendering.inlineImage(latex: #"\frac{1"#, fontSize: 17, color: .black))
    }

    func testImagesAreCachedPerSizeAndColor() throws {
        let a = try XCTUnwrap(MathRendering.inlineImage(latex: "x^2+y^2", fontSize: 17, color: .black))
        let b = try XCTUnwrap(MathRendering.inlineImage(latex: "x^2+y^2", fontSize: 17, color: .black))
        XCTAssertTrue(a.image === b.image)
        let bigger = try XCTUnwrap(MathRendering.inlineImage(latex: "x^2+y^2", fontSize: 24, color: .black))
        XCTAssertFalse(a.image === bigger.image)
        XCTAssertGreaterThan(bigger.image.size.width, a.image.size.width)
    }

    func testJapaneseInsideAFormulaHasInk() throws {
        let image = try XCTUnwrap(MathRendering.inlineImage(latex: #"\text{速さ}=\frac{\text{距離}}{\text{時間}}"#, fontSize: 17, color: .black)).image
        XCTAssertGreaterThan(ink(in: image, columns: 0...0.3, rows: 0...1), 30, "日本語の字形が描かれていること")
    }

    // MARK: The whole message view

    private func fittedSize(of source: String, width: CGFloat = 400) -> CGSize {
        let host = UIHostingController(rootView: RichMessageView(source: source))
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    func testEveryCorpusSampleLaysOut() {
        for sample in AIMathSamples.all {
            let size = fittedSize(of: sample.text)
            XCTAssertGreaterThan(size.height, 5, "\(sample): 高さがありません")
            XCTAssertLessThanOrEqual(size.width, 400.5, "\(sample): 幅を超えています")
        }
    }

    func testEveryStateOfAStreamingReplyLaysOut() {
        for id in ["reply-quadratic-extremum", "reply-marking-report", "table-with-math", "piecewise-cases"] {
            let text = AIMathSamples.sample(id: id)!.text
            for prefix in AIMathSamples.streamingPrefixes(of: text, step: 11) {
                _ = fittedSize(of: prefix)
            }
        }
    }

    func testALongerMessageIsTaller() {
        let short = fittedSize(of: "こんにちは")
        let long = fittedSize(of: AIMathSamples.sample(id: "reply-quadratic-extremum")!.text)
        XCTAssertGreaterThan(long.height, short.height * 5)
    }

    func testLayingOutALongReplyIsFast() {
        let text = AIMathSamples.all.filter { $0.category == .fullReply }.map(\.text).joined(separator: "\n\n")
        _ = fittedSize(of: text) // fills the caches
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { _ = fittedSize(of: text) }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 10
        print("PERF layout of \(text.count) characters: \(String(format: "%.1f", ms)) ms each")
        XCTAssertLessThan(ms, 250)
    }
}
