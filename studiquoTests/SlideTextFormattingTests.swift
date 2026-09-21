import XCTest
@testable import studiquo

/// Coverage for `SlideTextFormatting` — the mutations behind the slide
/// text box's formatting bar (design fix item 5), extracted so they're
/// testable without any live selection/SwiftUI state.
final class SlideTextFormattingTests: XCTestCase {
    private func text(_ string: String, size: CGFloat = 18, bold: Bool = false, italic: Bool = false) -> NSMutableAttributedString {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size)
        let font = traits.isEmpty ? base : UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor, size: size)
        return NSMutableAttributedString(string: string, attributes: [.font: font])
    }

    private func font(_ text: NSAttributedString, at index: Int = 0) -> UIFont {
        (text.attribute(.font, at: index, effectiveRange: nil) as? UIFont) ?? UIFont.systemFont(ofSize: 18)
    }

    // MARK: toggleTrait

    func testTogglingBoldOnPlainTextAddsTheBoldTrait() {
        let body = text("こんにちは")
        SlideTextFormatting.toggleTrait(.traitBold, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertTrue(font(body).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testTogglingBoldTwiceReturnsToPlain() {
        let body = text("こんにちは")
        let range = NSRange(location: 0, length: body.length)
        SlideTextFormatting.toggleTrait(.traitBold, in: body, range: range)
        SlideTextFormatting.toggleTrait(.traitBold, in: body, range: range)
        XCTAssertFalse(font(body).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testTogglingBoldPreservesTheExistingFontSize() {
        let body = text("見出し", size: 32)
        SlideTextFormatting.toggleTrait(.traitBold, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).pointSize, 32, accuracy: 0.01)
    }

    func testTogglingItalicDoesNotAffectAnExistingBoldTrait() {
        let body = text("装飾文字", bold: true)
        SlideTextFormatting.toggleTrait(.traitItalic, in: body, range: NSRange(location: 0, length: body.length))
        let traits = font(body).fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.traitBold))
        XCTAssertTrue(traits.contains(.traitItalic))
    }

    func testToggleOnlyAffectsTheGivenRangeNotTheWholeString() {
        let body = text("前半後半")
        SlideTextFormatting.toggleTrait(.traitBold, in: body, range: NSRange(location: 0, length: 2))
        XCTAssertTrue(font(body, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(font(body, at: 2).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    // MARK: setUnderline

    func testSetUnderlineOnAddsTheAttribute() {
        let body = text("下線")
        SlideTextFormatting.setUnderline(true, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(body.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testSetUnderlineOffRemovesIt() {
        let body = text("下線")
        let range = NSRange(location: 0, length: body.length)
        SlideTextFormatting.setUnderline(true, in: body, range: range)
        SlideTextFormatting.setUnderline(false, in: body, range: range)
        XCTAssertEqual(body.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
    }

    // MARK: changeFontSize

    func testChangeFontSizeIncreasesByTheGivenDelta() {
        let body = text("文字", size: 18)
        SlideTextFormatting.changeFontSize(by: 4, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).pointSize, 22, accuracy: 0.01)
    }

    func testChangeFontSizeIsClampedToTheFloor() {
        let body = text("文字", size: 9)
        SlideTextFormatting.changeFontSize(by: -10, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).pointSize, 8, accuracy: 0.01, "must never shrink below the 8pt floor")
    }

    func testChangeFontSizeIsClampedToTheCeiling() {
        let body = text("文字", size: 90)
        SlideTextFormatting.changeFontSize(by: 20, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).pointSize, 96, accuracy: 0.01, "must never grow past the 96pt ceiling")
    }

    func testChangeFontSizePreservesBoldTrait() {
        let body = text("太字", size: 18, bold: true)
        SlideTextFormatting.changeFontSize(by: 2, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertTrue(font(body).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    // MARK: applyAlignment

    func testApplyAlignmentSetsTheParagraphStyle() {
        let body = text("中央揃え")
        SlideTextFormatting.applyAlignment(.center, in: body, range: NSRange(location: 0, length: body.length))
        let style = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
    }

    func testApplyAlignmentExpandsToTheWholeParagraphNotJustTheCaretRange() {
        let body = text("一行目の文章")
        // A zero-length "caret" range in the middle of the line.
        SlideTextFormatting.applyAlignment(.right, in: body, range: NSRange(location: 3, length: 0))
        let style = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .right, "the whole line must reformat, not nothing")
    }

    func testApplyAlignmentOnOneParagraphDoesNotAffectAnother() {
        let body = text("一行目\n二行目")
        let firstLineRange = NSRange(location: 0, length: 3)
        SlideTextFormatting.applyAlignment(.center, in: body, range: firstLineRange)
        let secondLineStyle = body.attribute(.paragraphStyle, at: body.length - 1, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(secondLineStyle?.alignment, .center)
    }

    func testApplyAlignmentPreservesOtherParagraphStyleProperties() {
        let body = text("行間")
        let existing = NSMutableParagraphStyle()
        existing.lineSpacing = 6
        body.addAttribute(.paragraphStyle, value: existing, range: NSRange(location: 0, length: body.length))

        SlideTextFormatting.applyAlignment(.center, in: body, range: NSRange(location: 0, length: body.length))

        let style = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        XCTAssertEqual(style?.lineSpacing ?? .nan, 6, accuracy: 0.01, "changing alignment must not discard line spacing already set")
    }

    // MARK: applyFontFamily

    func testApplyFontFamilyChangesTheFontName() {
        let body = text("Georgia")
        SlideTextFormatting.applyFontFamily(.georgia, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).fontName, "Georgia")
    }

    func testApplyFontFamilyPreservesTheExistingSize() {
        let body = text("大きな文字", size: 40)
        SlideTextFormatting.applyFontFamily(.georgia, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(font(body).pointSize, 40, accuracy: 0.01)
    }

    func testApplyFontFamilyPreservesBoldTrait() {
        let body = text("太字", bold: true)
        SlideTextFormatting.applyFontFamily(.georgia, in: body, range: NSRange(location: 0, length: body.length))
        XCTAssertTrue(font(body).fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
