import SwiftUI
import UIKit

/// Design tokens (docs/UI_DESIGN_TOKENS.md). Screens read these names instead of
/// hard-coding colors, sizes and radii, so the look can change in one place.
enum Theme {
    // MARK: Color

    enum Palette {
        static let canvas = dynamic(light: 0xF7F7F8, dark: 0x101113)
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1B1E)
        static let surfaceSunken = dynamic(light: 0xEFEFF1, dark: 0x0B0B0C)
        static let line = dynamic(light: 0xE2E3E6, dark: 0x2A2B2F)

        static let textPrimary = dynamic(light: 0x1B1C1F, dark: 0xECEDEF)
        static let textSecondary = dynamic(light: 0x5F6168, dark: 0xA1A3A9)
        /// Low contrast: only for non-essential notes, never for content users must read.
        static let textTertiary = dynamic(light: 0x8E9096, dark: 0x6E7077)

        static let accent = dynamic(light: 0x2954A1, dark: 0x7FA2E6)
        static let accentSoft = dynamic(light: 0xE6ECF7, dark: 0x1D2A44)

        static let danger = dynamic(light: 0xC23A32, dark: 0xF07068)
        static let success = dynamic(light: 0x2E7D4F, dark: 0x6CC590)
        static let warning = dynamic(light: 0xB26A00, dark: 0xE8A33D)

        /// Text/icon color placed on top of `accent` fills.
        static let onAccent = Color.white

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(uiColor: UIColor { traits in
                UIColor(rgbHex: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    // MARK: Typography (Dynamic Type text styles)

    enum Typography {
        static let titleLarge = Font.title2.weight(.semibold)
        static let title = Font.title3.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let bodyStrong = Font.body.weight(.semibold)
        static let label = Font.subheadline
        static let caption = Font.caption
        static let numeric = Font.subheadline.monospacedDigit()
        static let numericCaption = Font.caption.monospacedDigit()
    }

    // MARK: Spacing (4pt grid)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Stroke

    enum Stroke {
        /// Hairline border for surfaces (replaces drop shadows on flat cards).
        static let hairline: CGFloat = 0.5
    }

    // MARK: Elevation (only for floating elements: popovers, floating toolbars)

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    static let floatingShadow = Shadow(color: .black.opacity(0.08), radius: 12, y: 4)

    // MARK: Motion

    enum Motion {
        static let standard = Animation.easeOut(duration: 0.2)
        static let large = Animation.easeOut(duration: 0.3)
        static let reduced = Animation.easeOut(duration: 0.15)
    }
}

private extension UIColor {
    convenience init(rgbHex: UInt32) {
        self.init(
            red: CGFloat((rgbHex >> 16) & 0xFF) / 255,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255,
            blue: CGFloat(rgbHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// Animation that falls back to a short fade when Reduce Motion is on.
    func themeAnimation<V: Equatable>(_ value: V, large: Bool = false) -> some View {
        modifier(ThemeAnimationModifier(value: value, large: large))
    }

    /// Replaces the system grouped-list gray behind a List/Form with the canvas color.
    func themeScreenBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.Palette.canvas)
    }

    func floatingShadow() -> some View {
        shadow(
            color: Theme.floatingShadow.color,
            radius: Theme.floatingShadow.radius,
            y: Theme.floatingShadow.y
        )
    }
}

private struct ThemeAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    let large: Bool

    func body(content: Content) -> some View {
        content.animation(
            reduceMotion ? Theme.Motion.reduced : (large ? Theme.Motion.large : Theme.Motion.standard),
            value: value
        )
    }
}
