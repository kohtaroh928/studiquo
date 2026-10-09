import XCTest

extension XCUIApplication {
    /// The note screen's tool strip scrolls sideways. On a narrower iPad, or in
    /// portrait, controls such as "画面分割" sit past the right edge: the element
    /// exists but has no hit point. Drags the strip until `element` is inside
    /// the window, or gives up after a few tries.
    func scrollToolStrip(toReveal element: XCUIElement) {
        let window = windows.firstMatch
        var drags = 0
        while element.frame.maxX > window.frame.maxX - 8, drags < 6 {
            let y = max(0.02, min(0.2, element.frame.midY / max(window.frame.height, 1)))
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y)))
            drags += 1
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
}
