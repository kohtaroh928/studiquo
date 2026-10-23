import XCTest

/// 向きを変えられなかったことを、スキップではなく失敗として知らせるためのエラー。
/// スキップにすると、回転できない環境では横向きの検証が黙って抜けたまま緑になる。
struct OrientationUnavailableError: Error, CustomStringConvertible {
    let wantsLandscape: Bool
    let windowFrame: CGRect

    var description: String {
        "シミュレータが\(wantsLandscape ? "横" : "縦")向きになりません(ウィンドウ \(windowFrame))。向きに依存するテストの検証が抜けるため、スキップせず失敗にしています。"
    }
}

extension XCUIDevice {
    /// 向きの変更は少し遅れて反映されるので、実際のウィンドウの形が合うまで繰り返し頼む。
    /// 合わなければ `OrientationUnavailableError` を投げる(スキップはしない)。
    func requireOrientation(_ orientation: UIDeviceOrientation, window: XCUIElement, timeout: TimeInterval = 15) throws {
        let wantsLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = window.frame
            if (frame.width > frame.height) == wantsLandscape { return }
            self.orientation = orientation
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw OrientationUnavailableError(wantsLandscape: wantsLandscape, windowFrame: window.frame)
    }
}
