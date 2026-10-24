import UIKit
import XCTest
@testable import studiquo

final class UIColorHexTests: XCTestCase {
    private func rgba(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func assertColor(_ hex: String, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        let c = rgba(UIColor(inkHex: hex))
        XCTAssertEqual(c.r, r, accuracy: 0.001, "red of \(hex)", file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: 0.001, "green of \(hex)", file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: 0.001, "blue of \(hex)", file: file, line: line)
        XCTAssertEqual(c.a, 1, accuracy: 0.001, "alpha of \(hex)", file: file, line: line)
    }

    func testSixDigitWithAndWithoutHash() {
        assertColor("#FF0000", 1, 0, 0)
        assertColor("00FF00", 0, 1, 0)
        assertColor("#0000FF", 0, 0, 1)
        assertColor("#336699", 0x33 / 255, 0x66 / 255, 0x99 / 255)
    }

    func testThreeDigitExpandsEachNibble() {
        assertColor("#F00", 1, 0, 0)
        assertColor("0F0", 0, 1, 0)
        assertColor("#ABC", 0xA / 15, 0xB / 15, 0xC / 15)
    }

    func testLowercaseAndSurroundingWhitespace() {
        assertColor("#ff8000", 1, 0x80 / 255, 0)
        assertColor("  #FF0000\n", 1, 0, 0)
    }

    func testUnparseableInputFallsBackToBlack() {
        for bad in ["", "#", "#12", "#1234", "#12345", "#1234567", "#FF000080", "ZZZZZZ", "#GGG", "red"] {
            assertColor(bad, 0, 0, 0)
        }
    }

    func testToHexUsesUppercaseSixDigits() {
        XCTAssertEqual(UIColor(red: 1, green: 0, blue: 0, alpha: 1).toHex(), "#FF0000")
        XCTAssertEqual(UIColor(red: 0, green: 0, blue: 0, alpha: 1).toHex(), "#000000")
        XCTAssertEqual(UIColor(red: 0, green: 1, blue: 0.5, alpha: 1).toHex(), "#00FF80")
    }

    func testToHexIgnoresAlpha() {
        XCTAssertEqual(UIColor(red: 1, green: 1, blue: 1, alpha: 0.2).toHex(), "#FFFFFF")
    }

    func testRoundTripForSixDigitValues() {
        for hex in ["#000000", "#FFFFFF", "#123456", "#ABCDEF", "#FE0102"] {
            XCTAssertEqual(UIColor(inkHex: hex).toHex(), hex)
        }
    }

    func testThreeDigitRoundTripsToExpandedForm() {
        XCTAssertEqual(UIColor(inkHex: "#ABC").toHex(), "#AABBCC")
    }
}
