import UIKit

extension UIColor {
    /// Parses a `#RRGGBB` or `#RGB` string; falls back to black for anything
    /// unparseable rather than crashing on bad stored data.
    convenience init(inkHex hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }

        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)

        let red, green, blue: CGFloat
        switch hexString.count {
        case 3:
            red = CGFloat((value >> 8) & 0xF) / 15
            green = CGFloat((value >> 4) & 0xF) / 15
            blue = CGFloat(value & 0xF) / 15
        case 6:
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
        default:
            red = 0; green = 0; blue = 0
        }
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    func toHex() -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())
        )
    }
}
