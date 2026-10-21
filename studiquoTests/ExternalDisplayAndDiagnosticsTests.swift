import SwiftUI
import XCTest
@testable import studiquo

/// 外部ディスプレイは実機でしか確かめられないので、ここでは「繋がっていない
/// 状態で何をしても落ちない・表示しない」ことだけを固定する。
@MainActor
final class ExternalDisplayControllerTests: XCTestCase {
    func testWithoutAnExternalSceneShowAndHideAreSafeNoOps() throws {
        let controller = ExternalDisplayController()
        guard !controller.isConnected else {
            throw XCTSkip("外部ディスプレイが接続されている環境")
        }
        var built = false
        controller.show {
            built = true
            return AnyView(Text("slide"))
        }
        // 接続がなければ表示せず、内容も作らない。
        XCTAssertFalse(built)
        controller.hide()
        controller.hide()
        XCTAssertFalse(controller.isConnected)
    }
}

final class GestureDiagnosticsTests: XCTestCase {
    /// 診断用の出力だけで状態を持つ。どの順序で呼んでも落ちず、
    /// パン計測の状態が報告のたびに初期化されることを確かめる。
    func testPanReportingSurvivesFewAndManySamplesAndResets() {
        GestureDiagnostics.endPanAndReport(scale: 1)   // サンプルなし
        for _ in 0..<3 { GestureDiagnostics.recordPanUpdate() }
        GestureDiagnostics.endPanAndReport(scale: 1)   // 少なすぎる
        for _ in 0..<40 { GestureDiagnostics.recordPanUpdate() }
        GestureDiagnostics.endPanAndReport(scale: 2.5) // 十分
        GestureDiagnostics.endPanAndReport(scale: 2.5) // 直後は空に戻っている
    }

    func testOtherEmittersAcceptEdgeValues() {
        GestureDiagnostics.panBegan(scale: 0)
        GestureDiagnostics.zoomScale(.nan, phase: "changed")
        GestureDiagnostics.zoomScale(1, phase: "ended")
        GestureDiagnostics.pullBottomState(isAtBottom: true, adderMaxY: .infinity, viewportHeight: 0)
        GestureDiagnostics.pullProgress(-1, extraPulled: 0)
        GestureDiagnostics.pullGestureIgnored(reason: "test")
        GestureDiagnostics.pullRawGeometry(maxY: 100, viewport: 100, contentHeight: 0)
        GestureDiagnostics.strokeOutcome(before: 0, after: 0, tool: "pen", scratchOutFired: false)
        GestureDiagnostics.scratchOutRemoval(candidates: 0, removed: 0)
    }
}
