import XCTest
@testable import studiquo

/// Regression coverage for a real bug: the 用紙 tool on an *existing* page
/// used to open a plain text `Menu` instead of the same image-thumbnail
/// grid (`PageTemplatePickerSheet`) shown when *creating* a page. The fix
/// reuses `PageTemplatePickerSheet` for both flows — these tests pin down
/// the one behavioral difference between them (how many paper colours are
/// offered) so a future edit can't silently collapse the existing-page tool
/// back down to the smaller creation-time palette, or vice versa.
@MainActor
final class PageTemplatePickerSheetTests: XCTestCase {
    func testExistingPagePaletteOffersAllFiveColors() {
        let palette = PaperColorOption.existingPagePalette

        XCTAssertEqual(palette.map(\.title), ["白", "クリーム", "淡い青", "淡いグレー", "淡い緑"])
        XCTAssertEqual(palette.map(\.hex), ["#FFFFFF", "#FFF8E7", "#EEF7FF", "#F3F4F6", "#F0FAF2"])
    }

    /// `PageTemplatePickerSheet`'s own default (used when a caller doesn't
    /// pass `paperColorOptions`, as the page-creation flow doesn't) must
    /// stay the three quick choices — not the five-colour existing-page
    /// palette above.
    func testPageCreationDefaultsToTheThreeQuickColorsNotTheFullPalette() {
        let sheet = PageTemplatePickerSheet(
            title: "ページ追加",
            selectedTemplate: .ruled,
            confirmTitle: "追加",
            onCancel: {},
            onSelect: { _, _ in }
        )

        XCTAssertEqual(sheet.paperColorOptions.map(\.title), ["白", "肌色", "水色"])
        XCTAssertEqual(sheet.paperColorOptions.map(\.hex), PaperColorChoice.allCases.map(\.hex))
    }

    /// If someone ever makes these two palettes identical again (e.g. by
    /// having one default to the other), the existing-page tool has quietly
    /// lost the colours only it used to offer.
    func testExistingPagePaletteHasMoreColorsThanTheCreationDefault() {
        let creationDefault = PageTemplatePickerSheet(
            title: "t", selectedTemplate: .blank, confirmTitle: "c", onCancel: {}, onSelect: { _, _ in }
        ).paperColorOptions

        XCTAssertGreaterThan(PaperColorOption.existingPagePalette.count, creationDefault.count)
    }

    /// A caller can still explicitly pass the existing-page palette in (as
    /// NoteEditorView's "用紙を変更" sheet does) — this is the one point in
    /// the app where that actually happens, so pin down that the sheet
    /// simply stores whatever it's given rather than silently substituting
    /// its own default.
    func testASheetConstructedWithTheExistingPagePaletteKeepsAllFiveColors() {
        let sheet = PageTemplatePickerSheet(
            title: "用紙を変更",
            selectedTemplate: .blank,
            selectedPaperColorHex: "#FFFFFF",
            paperColorOptions: PaperColorOption.existingPagePalette,
            confirmTitle: "適用",
            onCancel: {},
            onSelect: { _, _ in }
        )

        XCTAssertEqual(sheet.paperColorOptions.count, 5)
    }
}
