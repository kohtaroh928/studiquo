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
