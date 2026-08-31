import Foundation
import SwiftData
import SwiftUI

// MARK: - Word-style text document

/// A flowing text document, alongside the app's handwritten notes.
///
/// The body is a real `NSAttributedString` archived to `Data` rather than a
/// bespoke block model. That is what makes character-level formatting —
/// mixed bold/italic inside one paragraph, per-run colour and size, inline
/// images — behave the way a word processor's does, and it hands paragraph
/// styles, list rendering and pagination to TextKit instead of reimplementing
/// them.
@Model
final class TextDocument {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var folderName: String = ""
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    /// Archived `NSAttributedString` (see `DocumentBody`).
    @Attribute(.externalStorage) var bodyData: Data?
    /// Kept in sync on every save so the library can show a preview and the
    /// MCP snapshot has something readable without unarchiving.
    var plainText: String = ""
    var pageSizeRawValue: String = DocumentPageSize.a4.rawValue

    init(title: String = "無題の文書") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var pageSize: DocumentPageSize {
        get { DocumentPageSize(rawValue: pageSizeRawValue) ?? .a4 }
        set { pageSizeRawValue = newValue.rawValue }
    }

    var wordCount: Int {
        plainText.split { $0.isWhitespace || $0.isNewline }.count
    }

    var characterCount: Int {
        plainText.replacingOccurrences(of: "\n", with: "").count
    }
}

enum DocumentPageSize: String, CaseIterable, Identifiable {
    case a4, letter, b5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "レター"
        case .b5: "B5"
        }
    }

    /// In points, at 72 dpi — the unit `UIGraphicsPDFRenderer` works in.
    var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .letter: CGSize(width: 612, height: 792)
        case .b5: CGSize(width: 516, height: 729)
        }
    }

    /// Word's default margin is one inch; this matches it.
    var margin: CGFloat { 72 }
}

/// The paragraph styles offered in the style menu, mirroring the ones a word
/// processor puts at the front of its gallery. Each carries the concrete
/// typography it applies, so applying a style is one assignment rather than a
/// scattering of attribute writes.
enum DocumentParagraphStyle: String, CaseIterable, Identifiable {
    case title, heading1, heading2, heading3, body, quote, caption

    var id: String { rawValue }

    var title2: String {
        switch self {
        case .title: "タイトル"
        case .heading1: "見出し 1"
        case .heading2: "見出し 2"
        case .heading3: "見出し 3"
        case .body: "本文"
        case .quote: "引用"
        case .caption: "キャプション"
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .title: 28
        case .heading1: 22
        case .heading2: 18
        case .heading3: 16
        case .body: 13
        case .quote: 13
        case .caption: 11
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .title: .bold
        case .heading1, .heading2, .heading3: .semibold
        default: .regular
        }
    }

    var spacingBefore: CGFloat {
        switch self {
        case .title: 0
        case .heading1: 14
        case .heading2, .heading3: 10
        default: 0
        }
    }

    var spacingAfter: CGFloat {
        switch self {
        case .title: 12
        case .heading1, .heading2, .heading3: 6
        case .caption: 8
        default: 6
        }
    }

    var isItalic: Bool { self == .quote }

    var headIndent: CGFloat { self == .quote ? 22 : 0 }
}

// MARK: - PowerPoint-style slide deck

/// A slide deck.
///
/// Slides are built from *layout placeholders* rather than a free-form
/// canvas, which is how PowerPoint itself is structured: a layout decides
/// which boxes exist and where, and the content fills them. That keeps a deck
/// visually consistent, makes changing a slide's layout a one-tap operation,
/// and means a theme can restyle every slide at once.
@Model
final class SlideDeck {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var folderName: String = ""
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    var themeRawValue: String = SlideTheme.classic.rawValue
    var aspectRawValue: String = SlideAspect.widescreen.rawValue
    /// Deck-wide typography, the way a PowerPoint theme carries a font pair
    /// rather than each box choosing for itself.
    var fontFamilyRawValue: String = "system"
    /// Multiplies every placeholder's size, so one control scales a whole
    /// deck instead of retyping sizes per slide.
    var textScale: Double = 1.0
    var titleIsBold: Bool = true
    var bodyIsItalic: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Slide.deck)
    var slides: [Slide] = []

    init(title: String = "無題のスライド") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var theme: SlideTheme {
        get { SlideTheme(rawValue: themeRawValue) ?? .classic }
        set { themeRawValue = newValue.rawValue }
    }

    var aspect: SlideAspect {
        get { SlideAspect(rawValue: aspectRawValue) ?? .widescreen }
        set { aspectRawValue = newValue.rawValue }
    }

    var fontFamily: DocumentFontFamily {
        get { DocumentFontFamily(rawValue: fontFamilyRawValue) ?? .system }
        set { fontFamilyRawValue = newValue.rawValue }
    }

    var sortedSlides: [Slide] {
        slides.sorted { $0.order < $1.order }
    }

    func renumberSlides() {
        for (index, slide) in sortedSlides.enumerated() { slide.order = index }
    }
}

@Model
final class Slide {
    var order: Int
    var layoutRawValue: String = SlideLayout.titleAndBody.rawValue
    var titleText: String = ""
    /// One bullet per line, the way a content placeholder behaves.
    var bodyText: String = ""
    /// The second column of a two-content layout.
    var secondaryText: String = ""
    /// Speaker notes — shown to the presenter, never on the slide.
    var notes: String = ""
    @Attribute(.externalStorage) var imageData: Data?
    var deck: SlideDeck?

    init(order: Int, layout: SlideLayout = .titleAndBody) {
        self.order = order
        self.layoutRawValue = layout.rawValue
    }

    var layout: SlideLayout {
        get { SlideLayout(rawValue: layoutRawValue) ?? .titleAndBody }
        set { layoutRawValue = newValue.rawValue }
    }

    /// Bullets, with blank lines dropped so a trailing newline doesn't render
    /// as an empty bullet.
    var bullets: [String] {
        bodyText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var secondaryBullets: [String] {
        secondaryText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

enum SlideAspect: String, CaseIterable, Identifiable {
    case widescreen, standard

    var id: String { rawValue }
    var title: String { self == .widescreen ? "16:9" : "4:3" }
    var ratio: CGFloat { self == .widescreen ? 16.0 / 9.0 : 4.0 / 3.0 }
    /// PowerPoint's own point dimensions for the two sizes.
    var size: CGSize {
        self == .widescreen ? CGSize(width: 960, height: 540) : CGSize(width: 720, height: 540)
    }
}

/// The placeholder arrangements offered when adding or restyling a slide.
enum SlideLayout: String, CaseIterable, Identifiable {
    case titleSlide, titleAndBody, twoContent, sectionHeader, titleAndImage, imageOnly, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleSlide: "タイトル スライド"
        case .titleAndBody: "タイトルと内容"
        case .twoContent: "2つの内容"
        case .sectionHeader: "セクション見出し"
        case .titleAndImage: "タイトルと画像"
        case .imageOnly: "画像のみ"
        case .blank: "白紙"
        }
    }

    var icon: String {
        switch self {
        case .titleSlide: "textformat.size"
        case .titleAndBody: "list.bullet.rectangle"
        case .twoContent: "rectangle.split.2x1"
        case .sectionHeader: "text.aligncenter"
        case .titleAndImage: "photo.on.rectangle"
        case .imageOnly: "photo"
        case .blank: "rectangle"
        }
    }

    var hasTitle: Bool { self != .blank && self != .imageOnly }
    var hasBody: Bool {
        switch self {
        case .titleAndBody, .twoContent, .sectionHeader, .titleAndImage: true
        default: false
        }
    }
    var hasSecondary: Bool { self == .twoContent }
    var hasImage: Bool { self == .titleAndImage || self == .imageOnly }
    /// Title slides and section headers centre their text; content layouts
    /// run it top-left.
    var centersContent: Bool { self == .titleSlide || self == .sectionHeader }
}

/// A theme restyles every slide at once — background, title colour, body
/// colour and the accent used for bullets and rules.
enum SlideTheme: String, CaseIterable, Identifiable {
    case classic, midnight, paper, ocean, sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "クラシック"
        case .midnight: "ミッドナイト"
        case .paper: "ペーパー"
        case .ocean: "オーシャン"
        case .sunset: "サンセット"
        }
    }

    var background: Color {
        switch self {
        case .classic: .white
        case .midnight: Color(red: 0.09, green: 0.11, blue: 0.18)
        case .paper: Color(red: 0.98, green: 0.96, blue: 0.91)
        case .ocean: Color(red: 0.93, green: 0.97, blue: 1.0)
        case .sunset: Color(red: 1.0, green: 0.96, blue: 0.93)
        }
    }

    var titleColor: Color {
        switch self {
        case .classic: Color(red: 0.10, green: 0.12, blue: 0.16)
        case .midnight: .white
        case .paper: Color(red: 0.22, green: 0.17, blue: 0.11)
        case .ocean: Color(red: 0.06, green: 0.24, blue: 0.44)
        case .sunset: Color(red: 0.42, green: 0.16, blue: 0.10)
        }
    }

    var bodyColor: Color {
        switch self {
        case .classic: Color(red: 0.24, green: 0.26, blue: 0.30)
        case .midnight: Color(white: 0.86)
        case .paper: Color(red: 0.34, green: 0.29, blue: 0.23)
        case .ocean: Color(red: 0.16, green: 0.32, blue: 0.46)
        case .sunset: Color(red: 0.46, green: 0.30, blue: 0.24)
        }
    }

    var accent: Color {
        switch self {
        case .classic: Color(red: 0.16, green: 0.33, blue: 0.63)
        case .midnight: Color(red: 0.42, green: 0.66, blue: 1.0)
        case .paper: Color(red: 0.70, green: 0.45, blue: 0.16)
        case .ocean: Color(red: 0.0, green: 0.55, blue: 0.75)
        case .sunset: Color(red: 0.90, green: 0.42, blue: 0.24)
        }
    }
}
