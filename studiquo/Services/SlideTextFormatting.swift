import Foundation
import UIKit

/// The character/paragraph-attribute mutations behind the slide text box's
/// formatting bar (design fix item 5) — factored out of `SlideDeckView` as
/// plain functions over `(NSMutableAttributedString, NSRange)` so they're
/// unit-testable independent of any SwiftUI state (the live selection, the
/// element being edited, `modelContext`, …), which is what actually calls
/// these from `SlideDeckView.mutateEditingText(_:)`.
///
/// Mirrors `TextDocumentView`'s own equivalent functions (`toggleTrait`,
/// `apply(family:)`, `setFontSize`, `apply(alignment:)`) closely — this is
/// the same job, just for a single free-floating text box instead of a
/// flowing multi-segment document.
enum SlideTextFormatting {
    /// Flips a symbolic trait (bold/italic) on every font run touching
    /// `range`, preserving each run's own size.
    static func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits, in text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: 18)
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return }
            text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: subrange)
        }
    }

    static func setUnderline(_ isOn: Bool, in text: NSMutableAttributedString, range: NSRange) {
        text.addAttribute(.underlineStyle, value: isOn ? NSUnderlineStyle.single.rawValue : 0, range: range)
    }

    /// Changes every font run touching `range` by `delta` points, clamped
    /// to 8–96pt — the same floor/ceiling the document editor's own font
    /// size control uses.
    static func changeFontSize(by delta: CGFloat, in text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: 18)
            text.addAttribute(.font, value: font.withSize(min(max(font.pointSize + delta, 8), 96)), range: subrange)
        }
    }

    /// Expands to the whole paragraph `range` touches, the way a word
    /// processor's alignment buttons do — a caret in the middle of a line
    /// still reformats that entire line, not just the character beside it.
    /// Keeps whatever other paragraph-style properties (line spacing,
    /// indent, …) the paragraph already had.
    static func applyAlignment(_ alignment: NSTextAlignment, in text: NSMutableAttributedString, range: NSRange) {
        let paragraphRange = (text.string as NSString).paragraphRange(for: range)
        let style = NSMutableParagraphStyle()
        if let existing = text.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle {
            style.setParagraphStyle(existing)
        }
        style.alignment = alignment
        text.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
    }

    /// Swaps the typeface on every font run touching `range` while keeping
    /// each run's own size and bold/italic traits — same behavior as
    /// `TextDocumentView.apply(family:)`.
    static func applyFontFamily(_ family: DocumentFontFamily, in text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = (value as? UIFont) ?? UIFont.systemFont(ofSize: 18)
            let traits = current.fontDescriptor.symbolicTraits
            guard let descriptor = family.descriptor(size: current.pointSize)?
                .withSymbolicTraits(traits) ?? family.descriptor(size: current.pointSize) else { return }
            text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: subrange)
        }
    }
}
