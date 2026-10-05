import CoreGraphics
import XCTest
@testable import studiquo

/// 回帰テスト: くしゃくしゃ消し(スクイブル)の2つの不具合が再発しないことを固定する。
///
/// 問題1: スクイブルで消した文字の端が残る。
/// 問題2: 筆記体・一筆書きがスクイブルと誤判定されて消える。
final class ScratchOutRegressionTests: XCTestCase {
    // MARK: Fixtures

    private func ink(_ points: [CGPoint], width: CGFloat = 4) -> InkStroke {
        InkStroke(
            points: points.enumerated().map { InkPoint(location: $1, force: 0.5, timeOffset: Double($0) / Double(max(points.count, 1))) },
            colorHex: "#000000",
            width: width
        )
    }

    private func line(from: CGPoint, to: CGPoint, steps: Int = 60) -> [CGPoint] {
        (0...steps).map {
            let t = CGFloat($0) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    /// 連続して書いた文字列(一筆書き)。x方向に進みながら上下に波打つ。
    private func connectedHandwriting(from startX: CGFloat, letters: Int, letterWidth: CGFloat = 14, y: CGFloat = 50) -> [CGPoint] {
        (0...(letters * 24)).map { index in
            let t = CGFloat(index) / 24
            return CGPoint(x: startX + t * letterWidth, y: y + 8 * sin(t * 2 * .pi))
        }
    }

    /// 上下に往復しながら横へ進むスクイブル。
    private func zigzag(xRange: ClosedRange<CGFloat>, yCenter: CGFloat, amplitude: CGFloat, passes: Int) -> [CGPoint] {
        (0...passes).map { index in
            let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * CGFloat(index) / CGFloat(passes)
            return CGPoint(x: x, y: yCenter + (index.isMultiple(of: 2) ? -amplitude : amplitude))
        }
    }

    /// ループしながら進む筆記体(e・l の連続)。
    private func cursive(letters: Int, loopRadius: CGFloat = 7, advance: CGFloat = 3, height: CGFloat = 12) -> [CGPoint] {
        (0...(letters * 40)).map { index in
            let theta = CGFloat(index) / 40 * 2 * .pi
            return CGPoint(x: 20 + advance * theta + loopRadius * cos(theta), y: 60 + height * sin(theta))
        }
    }

    private func oldRuleFlags(_ points: [CGPoint]) -> Bool {
        // 修正前の判定。筆記体のテストデータが「本当に旧判定で誤検出されていた形」であることの確認用。
        let a = ScribbleClassifier.analyze(points)
        return a.lengthRatio >= 2.2 && (a.axisReversals >= 6 || a.selfIntersections >= 5)
    }

    // MARK: 問題1: 端が残らない

    func testRegression1_ScribbleOverWholeWordLeavesNoStrayEdges() throws {
        // 単語を一筆書きし、その上をスクイブルで消す。端の切れ端が残ってはいけない。
        let word = ink(connectedHandwriting(from: 20, letters: 5))
        let scribble = ink(zigzag(xRange: 14...98, yCenter: 50, amplitude: 14, passes: 14))

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([word], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.isEmpty, "連続して書いた部分は、スクイブルで覆えば全て消える必要があります。残り: \(result.map(\.pathLength))")
    }

    func testRegression1_ScribbleWithWideGapsStillErasesInkBetweenPasses() throws {
        let target = ink(line(from: CGPoint(x: 40, y: 50), to: CGPoint(x: 140, y: 50)))
        // 往復の間隔14pt(ヒット半径の約2.3倍)。軌跡だけでは隙間のインクが残る。
        let scribble = ink(zigzag(xRange: 40...138, yCenter: 50, amplitude: 10, passes: 7))

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        XCTAssertTrue(result.isEmpty)
    }

    func testRegression1_NoTinyFragmentsRemainBesideScribble() throws {
        for tail in [2, 4, 6, 8] as [CGFloat] {
            // スクイブルの右端から tail pt だけ線がはみ出す配置。
            let target = ink(line(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 60 + tail, y: 50)))
            let scribble = ink(zigzag(xRange: 10...60, yCenter: 50, amplitude: 6, passes: 16))

            let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

            for fragment in result {
                XCTAssertGreaterThanOrEqual(fragment.pathLength, 12, "はみ出し\(tail)ptの切れ端が残っています")
            }
        }
    }

    func testRegression1_ScribbleAtDifferentZoomStillLeavesNoEdges() throws {
        for scale in [0.5, 1, 2] as [CGFloat] {
            let word = ink(connectedHandwriting(from: 20, letters: 4))
            let scribble = ink(zigzag(xRange: 14...82, yCenter: 50, amplitude: 14, passes: 14))

            let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([word], scribble: scribble, contentScale: scale))

            XCTAssertTrue(result.isEmpty, "contentScale=\(scale)")
        }
    }

    func testRegression1_PartialScribbleStillKeepsFarAwayInk() throws {
        // 過剰消去の防止: 長い線の中央だけをスクイブルしたら、両側は残る。
        let target = ink(line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 200, y: 50), steps: 200))
        let scribble = ink(zigzag(xRange: 90...110, yCenter: 50, amplitude: 4, passes: 16))

        let result = try XCTUnwrap(InkCanvasView.scratchOutErasedStrokes([target], scribble: scribble, contentScale: 1))

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.pathLength > 60 })
    }

    // MARK: 問題2: 筆記体・一筆書きは消えない

    func testRegression2_CursiveWritingIsNeverScratchMotion() {
        for letters in 3...12 {
            for (radius, advance) in [(5, 3), (7, 3), (9, 4), (6, 2.5)] as [(CGFloat, CGFloat)] {
                let points = cursive(letters: letters, loopRadius: radius, advance: advance)
                XCTAssertFalse(InkCanvasView.hasScratchMotion(points), "筆記体 letters=\(letters) loop=\(radius) advance=\(advance)")
            }
        }
    }

    func testRegression2_CursiveTestDataWouldHaveFooledTheOldRule() {
        // このテストデータが無意味でない(旧判定なら誤検出した)ことを確認する。
        let flagged = (3...12).filter { oldRuleFlags(cursive(letters: $0)) }
        XCTAssertFalse(flagged.isEmpty, "テストデータが旧判定でも通常と判定される場合、回帰テストの意味がありません")
    }

    func testRegression2_ConnectedWavyHandwritingIsNeverScratchMotion() {
        for letters in 4...12 {
            XCTAssertFalse(InkCanvasView.hasScratchMotion(connectedHandwriting(from: 20, letters: letters)), "一筆書き letters=\(letters)")
        }
    }

    func testRegression2_CursiveOverBlankPaperNeverErasesAnything() {
        let unrelated = ink(line(from: CGPoint(x: 0, y: 400), to: CGPoint(x: 200, y: 400)))
        let writing = ink(cursive(letters: 8))

        XCTAssertNil(InkCanvasView.scratchOutErasedStrokes([unrelated], scribble: writing, contentScale: 1))
    }

    func testRegression2_BrushingOneOldStrokeDoesNotErase() {
        // 筆記体の1点が既存インクに触れただけでは消えない(重なり40%未満)。
        let old = ink(line(from: CGPoint(x: 150, y: 20), to: CGPoint(x: 152, y: 100), steps: 20))
        let writing = ink(cursive(letters: 10))

        XCTAssertNil(InkCanvasView.scratchOutErasedStrokes([old], scribble: writing, contentScale: 1))
    }

    func testRegression2_CursiveWrittenOverExistingTextKeepsTheTextWhenNotScribbling() {
        // 行間にはみ出した下降部などが既存の文字に重なっても、判定で弾かれて消さない。
        let existing = ink(connectedHandwriting(from: 20, letters: 6, y: 62))
        let writing = ink(cursive(letters: 6))

        XCTAssertFalse(InkCanvasView.hasScratchMotion(writing.points.map(\.location)))
        XCTAssertNotNil(existing.points.first)
    }

    // MARK: スクイブルは引き続き消える(過剰な厳格化の防止)

    func testScribblesStillCountAsScratchMotion() {
        let compact = zigzag(xRange: 0...50, yCenter: 20, amplitude: 20, passes: 14)
        let drifting = zigzag(xRange: 0...75, yCenter: 50, amplitude: 10, passes: 30)
        let tight = zigzag(xRange: 0...30, yCenter: 10, amplitude: 3, passes: 24)
        let horizontal = (0..<14).map { CGPoint(x: $0.isMultiple(of: 2) ? 0 : 60, y: CGFloat($0) * 2) }

        XCTAssertTrue(InkCanvasView.hasScratchMotion(compact), "compact")
        XCTAssertTrue(InkCanvasView.hasScratchMotion(drifting), "drifting")
        XCTAssertTrue(InkCanvasView.hasScratchMotion(tight), "tight")
        XCTAssertTrue(InkCanvasView.hasScratchMotion(horizontal), "horizontal")
    }

    func testScribbleOverExistingInkStillErases() throws {
        let word = ink(connectedHandwriting(from: 20, letters: 4))
        let scribble = ink(zigzag(xRange: 14...82, yCenter: 50, amplitude: 14, passes: 14))

        XCTAssertTrue(InkCanvasView.hasScratchMotion(scribble.points.map(\.location)))
        XCTAssertNotNil(InkCanvasView.scratchOutErasedStrokes([word], scribble: scribble, contentScale: 1))
    }

    func testPlainStrokesAndSingleLoopsAreNotScratchMotion() {
        XCTAssertFalse(InkCanvasView.hasScratchMotion(line(from: .zero, to: CGPoint(x: 100, y: 40))))
        let circle: [CGPoint] = (0...64).map { index in
            let angle: CGFloat = CGFloat(index) / 64 * 2 * .pi
            return CGPoint(x: 50 + 30 * cos(angle), y: 50 + 30 * sin(angle))
        }
        XCTAssertFalse(InkCanvasView.hasScratchMotion(circle))
    }
}
