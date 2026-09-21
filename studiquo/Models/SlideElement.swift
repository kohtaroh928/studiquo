import Foundation
import SwiftData
import UIKit

// MARK: - Master / layout / placeholder

/// A deck's design source of truth — background/text colours, the
/// heading/body font pair, and the set of layouts a slide can be built
/// from. One per `SlideDeck`. Editing a master (or one of its layouts'
/// placeholders) is what makes "fix it once, every slide updates" actually
/// work — see `SlidePlaceholder` and `SlideElement`'s doc comments for how
/// an individual slide's content inherits from here until someone moves it.
@Model
final class SlideMaster {
    var backgroundColorHex: String = "#FFFFFF"
    var titleColorHex: String = "#1C1C1E"
    var bodyColorHex: String = "#3A3A3C"
    var accentColorHex: String = "#0A84FF"
    var headingFontFamilyRawValue: String = "system"
    var bodyFontFamilyRawValue: String = "system"
    @Relationship(deleteRule: .cascade, inverse: \SlideLayoutTemplate.master)
    var layouts: [SlideLayoutTemplate]?
    var deck: SlideDeck?

    init(
        backgroundColorHex: String = "#FFFFFF",
        titleColorHex: String = "#1C1C1E",
        bodyColorHex: String = "#3A3A3C",
        accentColorHex: String = "#0A84FF"
    ) {
        self.backgroundColorHex = backgroundColorHex
        self.titleColorHex = titleColorHex
        self.bodyColorHex = bodyColorHex
        self.accentColorHex = accentColorHex
    }

    var headingFontFamily: DocumentFontFamily {
        get { DocumentFontFamily(rawValue: headingFontFamilyRawValue) ?? .system }
        set { headingFontFamilyRawValue = newValue.rawValue }
    }

    var bodyFontFamily: DocumentFontFamily {
        get { DocumentFontFamily(rawValue: bodyFontFamilyRawValue) ?? .system }
        set { bodyFontFamilyRawValue = newValue.rawValue }
    }

    var sortedLayouts: [SlideLayoutTemplate] {
        (layouts ?? []).sorted { $0.order < $1.order }
    }

    @discardableResult
    func addLayout(name: String) -> SlideLayoutTemplate {
        let layout = SlideLayoutTemplate(name: name, order: sortedLayouts.count)
        layout.master = self
        layouts = (layouts ?? []) + [layout]
        return layout
    }

    /// Detaches every `SlideElement` still inheriting from one of
    /// `layout`'s placeholders (baking in each one's current resolved
    /// geometry first) and removes `layout` from this master — design step
    /// 5's master editor calls this rather than deleting the SwiftData
    /// object directly, so a cascade-deleted placeholder never silently
    /// discards a slide's position/size. The caller still owns telling
    /// `modelContext` to delete `layout` itself; this only handles the
    /// data-integrity part removing it requires. No-op (returns `false`)
    /// if `layout` isn't actually one of this master's own.
    @discardableResult
    func removeLayout(_ layout: SlideLayoutTemplate) -> Bool {
        guard layouts?.contains(where: { $0 === layout }) == true else { return false }
        for placeholder in layout.sortedPlaceholders {
            placeholder.detachSourceElements()
        }
        layouts?.removeAll { $0 === layout }
        return true
    }

    /// A new layout on this master named `"<original>のコピー"`, with an
    /// independent copy of every placeholder (position/size/role/kind/
    /// default text style) — design step 5 master editor's "duplicate"
    /// action. The copy is fully independent: editing it afterward never
    /// touches `layout`, and vice versa.
    @discardableResult
    func duplicateLayout(_ layout: SlideLayoutTemplate) -> SlideLayoutTemplate {
        let copy = addLayout(name: layout.name + "のコピー")
        for placeholder in layout.sortedPlaceholders {
            let newPlaceholder = copy.addPlaceholder(
                role: placeholder.role, kind: placeholder.kind,
                centerX: placeholder.centerX, centerY: placeholder.centerY,
                width: placeholder.width, height: placeholder.height
            )
            newPlaceholder.defaultFontSize = placeholder.defaultFontSize
            newPlaceholder.defaultIsBold = placeholder.defaultIsBold
            newPlaceholder.rotation = placeholder.rotation
        }
        return copy
    }

    /// The standard starter set every new deck (and every migrated legacy
    /// deck — see `SlideBlockMigration`) gets, matching the seven layouts
    /// the old fixed `SlideLayout` enum offered. Unlike that enum, these are
    /// now real, independently editable data — a user can rename, restyle,
    /// duplicate or delete any of them afterward.
    static func makeDefault() -> SlideMaster {
        let master = SlideMaster()

        let titleSlide = master.addLayout(name: "タイトル スライド")
        titleSlide.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.42, width: 0.8, height: 0.18)
        titleSlide.addPlaceholder(role: .subtitle, kind: .text, centerX: 0.5, centerY: 0.6, width: 0.7, height: 0.1)

        let titleAndBody = master.addLayout(name: "タイトルと内容")
        titleAndBody.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.12, width: 0.86, height: 0.14)
        titleAndBody.addPlaceholder(role: .body, kind: .text, centerX: 0.5, centerY: 0.58, width: 0.86, height: 0.62)

        let twoContent = master.addLayout(name: "2つの内容")
        twoContent.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.12, width: 0.86, height: 0.14)
        twoContent.addPlaceholder(role: .body, kind: .text, centerX: 0.27, centerY: 0.58, width: 0.4, height: 0.62)
        twoContent.addPlaceholder(role: .secondaryBody, kind: .text, centerX: 0.73, centerY: 0.58, width: 0.4, height: 0.62)

        let sectionHeader = master.addLayout(name: "セクション見出し")
        sectionHeader.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.42, width: 0.8, height: 0.18)
        sectionHeader.addPlaceholder(role: .body, kind: .text, centerX: 0.5, centerY: 0.6, width: 0.7, height: 0.12)

        let titleAndImage = master.addLayout(name: "タイトルと画像")
        titleAndImage.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.12, width: 0.86, height: 0.14)
        titleAndImage.addPlaceholder(role: .image, kind: .image, centerX: 0.5, centerY: 0.58, width: 0.7, height: 0.62)

        let imageOnly = master.addLayout(name: "画像のみ")
        imageOnly.addPlaceholder(role: .image, kind: .image, centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.86)

        master.addLayout(name: "白紙")

        return master
    }
}

/// One editable layout within a `SlideMaster` — a named arrangement of
/// `SlidePlaceholder`s. Choosing this layout for a `Slide` seeds it with
/// matching elements at the placeholder positions; editing a placeholder
/// here moves every slide still inheriting from it (see `SlideElement`).
@Model
final class SlideLayoutTemplate {
    var name: String = ""
    var order: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \SlidePlaceholder.layout)
    var placeholders: [SlidePlaceholder]?
    var master: SlideMaster?
    // Not cascade-deleted from this side, for the same reason
    // `SlidePlaceholder.sourceElements` isn't: deleting a layout must not
    // delete the slides using it (see `changeLayout(to:)` and design step 5).
    @Relationship(inverse: \Slide.layout)
    var slides: [Slide]?

    init(name: String, order: Int) {
        self.name = name
        self.order = order
    }

    var sortedPlaceholders: [SlidePlaceholder] {
        (placeholders ?? []).sorted { $0.order < $1.order }
    }

    @discardableResult
    func addPlaceholder(
        role: SlidePlaceholderRole, kind: SlideElementKind,
        centerX: Double, centerY: Double, width: Double, height: Double
    ) -> SlidePlaceholder {
        let placeholder = SlidePlaceholder(
            role: role, kind: kind, order: sortedPlaceholders.count,
            centerX: centerX, centerY: centerY, width: width, height: height
        )
        placeholder.layout = self
        placeholders = (placeholders ?? []) + [placeholder]
        return placeholder
    }

    func placeholder(for role: SlidePlaceholderRole) -> SlidePlaceholder? {
        sortedPlaceholders.first { $0.role == role }
    }

    /// Same detach-then-remove step as `SlideMaster.removeLayout(_:)`,
    /// scoped to a single placeholder within this layout. No-op (returns
    /// `false`) if `placeholder` isn't actually one of this layout's own.
    @discardableResult
    func removePlaceholder(_ placeholder: SlidePlaceholder) -> Bool {
        guard placeholders?.contains(where: { $0 === placeholder }) == true else { return false }
        placeholder.detachSourceElements()
        placeholders?.removeAll { $0 === placeholder }
        return true
    }
}

enum SlidePlaceholderRole: String, CaseIterable, Identifiable {
    case title, subtitle, body, secondaryBody, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "タイトル"
        case .subtitle: "サブタイトル"
        case .body: "本文"
        case .secondaryBody: "本文2"
        case .image: "画像"
        }
    }
}

/// A named "slot" in a layout — not itself something rendered directly, but
/// the default position/size/text style a `SlideElement` inherits from for
/// as long as nobody has moved or restyled it on its own slide. See
/// `SlideElement`'s doc comment for the inherit/override mechanics.
@Model
final class SlidePlaceholder {
    var order: Int = 0
    var roleRawValue: String = SlidePlaceholderRole.body.rawValue
    var kindRawValue: String = SlideElementKind.text.rawValue
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.5
    var height: Double = 0.2
    var rotation: Double = 0
    /// Seeds the initial rich-text formatting when a slide first adopts
    /// this placeholder — direct formatting a user later applies to the
    /// text always wins over a subsequent change here, the same
    /// "direct formatting beats inherited style" rule Word/PowerPoint both
    /// follow, so this is only ever a *starting point*.
    var defaultFontSize: Double = 18
    var defaultIsBold: Bool = false
    var layout: SlideLayoutTemplate?
    // Not cascade-deleted from this side — deleting a placeholder must not
    // silently delete real slide content. See `SlideLayoutTemplate`'s
    // deletion path (design step 5): geometry/style are baked into any
    // still-inheriting element *before* the placeholder itself goes away.
    @Relationship(inverse: \SlideElement.sourcePlaceholder)
    var sourceElements: [SlideElement]?

    init(
        role: SlidePlaceholderRole, kind: SlideElementKind, order: Int,
        centerX: Double, centerY: Double, width: Double, height: Double
    ) {
        self.roleRawValue = role.rawValue
        self.kindRawValue = kind.rawValue
        self.order = order
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    var role: SlidePlaceholderRole {
        get { SlidePlaceholderRole(rawValue: roleRawValue) ?? .body }
        set { roleRawValue = newValue.rawValue }
    }

    var kind: SlideElementKind {
        get { SlideElementKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }

    /// `ObjectIdentifier`, not `PersistentIdentifier` — a placeholder freshly
    /// added in the master editor (design step 5) has no reliable
    /// persistent id until the next save, the same reason `SlideElement`
    /// and `DocumentSegment` use `ObjectIdentifier` for `ForEach`/selection.
    var stableID: ObjectIdentifier { ObjectIdentifier(self) }

    /// Bakes in the current resolved geometry for every `SlideElement`
    /// still inheriting from this placeholder, then detaches it — forced
    /// the same way `bakeInGeometryIfNeeded()` normally only runs on a
    /// user's own drag, because this placeholder is about to disappear and
    /// there'll be nothing left to inherit from.
    func detachSourceElements() {
        for element in sourceElements ?? [] {
            element.bakeInGeometryIfNeeded()
            element.sourcePlaceholder = nil
        }
    }
}

// MARK: - Slide element (the canvas object)

enum SlideElementKind: String, CaseIterable, Identifiable {
    case text, image, rectangle, ellipse, line, group

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "テキスト"
        case .image: "画像"
        case .rectangle: "四角形"
        case .ellipse: "円・楕円"
        case .line: "直線"
        case .group: "グループ"
        }
    }
}

enum SlideVerticalAlignment: String, CaseIterable, Identifiable {
    case top, middle, bottom
    var id: String { rawValue }
}

enum SlideAnimationKind: String, CaseIterable, Identifiable {
    case none, fadeIn, slideInFromLeft, slideInFromRight, slideInFromTop, slideInFromBottom, zoomIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "なし"
        case .fadeIn: "フェードイン"
        case .slideInFromLeft: "左からスライドイン"
        case .slideInFromRight: "右からスライドイン"
        case .slideInFromTop: "上からスライドイン"
        case .slideInFromBottom: "下からスライドイン"
        case .zoomIn: "ズームイン"
        }
    }
}

/// How a slide transitions *in* during presentation playback — a much
/// smaller set than PowerPoint's own (dozens of transition styles); design
/// step 6 covers the three that matter most: no transition, a cross-fade,
/// and a directional push.
enum SlideTransitionKind: String, CaseIterable, Identifiable {
    case none, fade, push

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "切り替えなし"
        case .fade: "フェード"
        case .push: "プッシュ"
        }
    }
}

enum SlideAnimationTrigger: String, CaseIterable, Identifiable {
    case onClick, withPrevious, afterPrevious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onClick: "クリック時"
        case .withPrevious: "直前と同時に"
        case .afterPrevious: "直前の後に自動で"
        }
    }
}

/// One object on a slide's canvas — a text box, image, shape, or a group of
/// other elements. Position/size/rotation are *optional*: while every
/// override field is `nil`, this element tracks `sourcePlaceholder`'s
/// values live, so restyling a layout in the master editor (design step 5)
/// moves every slide still using it. The first drag, resize, or rotation on
/// this specific slide calls `bakeInGeometryIfNeeded()`, which copies the
/// currently-resolved values into the override fields — from that point on
/// this element is detached from the placeholder's position (though it
/// keeps the relationship, e.g. for layout-switch role matching) and stays
/// exactly where it was put, matching PowerPoint's own placeholder
/// behaviour.
///
/// An element with no `sourcePlaceholder` at all (freely added beyond
/// whatever the layout provides) always uses its own override fields —
/// there is nothing to inherit from.
@Model
final class SlideElement {
    var kindRawValue: String = SlideElementKind.text.rawValue
    /// Archived `NSAttributedString` (via `DocumentBody`, the same
    /// encoding the text-document feature uses) — `.text` kind only.
    @Attribute(.externalStorage) var bodyData: Data?
    /// `.image` kind only.
    @Attribute(.externalStorage) var imageData: Data?
    /// Fill/stroke colour for `.rectangle`/`.ellipse`/`.line`.
    var colorHex: String = "#1C1C1E"
    var lineWidth: Double = 3
    var verticalAlignmentRawValue: String = SlideVerticalAlignment.top.rawValue

    var overrideCenterX: Double?
    var overrideCenterY: Double?
    var overrideWidth: Double?
    var overrideHeight: Double?
    var overrideRotation: Double?

    var layerIndex: Double = 0
    var isLocked: Bool = false

    var animationKindRawValue: String = SlideAnimationKind.none.rawValue
    var animationTriggerRawValue: String = SlideAnimationTrigger.onClick.rawValue
    /// This slide's play order among elements that have an animation —
    /// meaningless (and ignored) while `animationKind == .none`.
    var animationOrder: Int = 0
    var animationDuration: Double = 0.5

    var sourcePlaceholder: SlidePlaceholder?

    @Relationship(deleteRule: .cascade, inverse: \SlideElement.parentGroup)
    var groupMembers: [SlideElement]?
    var parentGroup: SlideElement?

    var slide: Slide?

    init(kind: SlideElementKind, layerIndex: Double = 0) {
        self.kindRawValue = kind.rawValue
        self.layerIndex = layerIndex
    }

    var kind: SlideElementKind {
        get { SlideElementKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }

    /// A `ForEach`-safe identity — `persistentModelID` isn't reliably
    /// distinct for a `SlideElement` that hasn't been inserted into a
    /// `ModelContext` yet (freshly created this editing session), the same
    /// pitfall `DocumentSegment.id` was changed to `ObjectIdentifier` to
    /// avoid. Reference identity has no such gap.
    var stableID: ObjectIdentifier { ObjectIdentifier(self) }

    var verticalAlignment: SlideVerticalAlignment {
        get { SlideVerticalAlignment(rawValue: verticalAlignmentRawValue) ?? .top }
        set { verticalAlignmentRawValue = newValue.rawValue }
    }

    /// The rich text for `.text` kind, via the same `DocumentBody` archiving
    /// the text-document feature uses — bold/italic/underline/colour/font
    /// size are all plain `NSAttributedString` attributes already; only
    /// per-paragraph bullet level needs the extra handling in
    /// `SlideListText` below.
    var body: NSAttributedString {
        get { DocumentBody.decode(bodyData) }
        set { bodyData = DocumentBody.encode(newValue) }
    }

    /// The formatting a brand-new run of text in this element should start
    /// with — from `sourcePlaceholder`'s default size/weight when linked to
    /// one, or a plain readable default for a free text box. Seeds the
    /// *initial* look only: once the user directly formats any of this
    /// text, that formatting is what's archived in `bodyData` and this
    /// default is never consulted again for it (see `SlidePlaceholder`'s
    /// doc comment on why a placeholder default never overrides direct
    /// formatting).
    func defaultTextAttributes() -> [NSAttributedString.Key: Any] {
        let size = sourcePlaceholder?.defaultFontSize ?? 18
        let isBold = sourcePlaceholder?.defaultIsBold ?? false
        let font = isBold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
    }

    var animationKind: SlideAnimationKind {
        get { SlideAnimationKind(rawValue: animationKindRawValue) ?? .none }
        set { animationKindRawValue = newValue.rawValue }
    }

    var animationTrigger: SlideAnimationTrigger {
        get { SlideAnimationTrigger(rawValue: animationTriggerRawValue) ?? .onClick }
        set { animationTriggerRawValue = newValue.rawValue }
    }

    // Resolved geometry: this element's own override once it has one,
    // otherwise the linked placeholder's current value, otherwise a safe
    // fallback for a free element that somehow has neither yet.
    var centerX: Double { overrideCenterX ?? sourcePlaceholder?.centerX ?? 0.5 }
    var centerY: Double { overrideCenterY ?? sourcePlaceholder?.centerY ?? 0.5 }
    var width: Double { overrideWidth ?? sourcePlaceholder?.width ?? 0.3 }
    var height: Double { overrideHeight ?? sourcePlaceholder?.height ?? 0.1 }
    var rotation: Double { overrideRotation ?? sourcePlaceholder?.rotation ?? 0 }

    var isInheritingGeometry: Bool {
        sourcePlaceholder != nil && overrideCenterX == nil && overrideCenterY == nil
            && overrideWidth == nil && overrideHeight == nil && overrideRotation == nil
    }

    /// Detaches this element from its placeholder's *position*, freezing
    /// in whatever is currently resolved — called on the first drag/resize/
    /// rotate a user performs on this element. Safe to call repeatedly:
    /// only fields still `nil` are filled in, so it never clobbers an
    /// override already in place.
    func bakeInGeometryIfNeeded() {
        if overrideCenterX == nil { overrideCenterX = centerX }
        if overrideCenterY == nil { overrideCenterY = centerY }
        if overrideWidth == nil { overrideWidth = width }
        if overrideHeight == nil { overrideHeight = height }
        if overrideRotation == nil { overrideRotation = rotation }
    }

    /// Moves every member of this group by the same delta, in the group's
    /// own coordinate space (0-1 fractions of the slide) — called instead
    /// of setting a member's geometry directly, so dragging a group moves
    /// its contents together rather than only the invisible group frame.
    func moveGroup(dx: Double, dy: Double) {
        bakeInGeometryIfNeeded()
        overrideCenterX = (overrideCenterX ?? centerX) + dx
        overrideCenterY = (overrideCenterY ?? centerY) + dy
        for member in groupMembers ?? [] {
            member.bakeInGeometryIfNeeded()
            member.overrideCenterX = (member.overrideCenterX ?? member.centerX) + dx
            member.overrideCenterY = (member.overrideCenterY ?? member.centerY) + dy
        }
    }
}

// MARK: - Bullet/numbered lists within a text element

/// Bullet/numbered list handling for a `SlideElement`'s rich text.
///
/// Unlike the text-document feature — where list membership is a property
/// of a whole `DocumentBlock` — a slide text box's bullet points are
/// paragraphs *within one `NSAttributedString`*, so list level is stored as
/// a custom attribute per paragraph instead of on a separate model object.
/// Reuses `DocumentListKind` (bulleted/numbered) rather than inventing a
/// second enum for the same idea.
enum SlideListText {
    /// NSNumber (Int) — the paragraph's indent level (0 = top level).
    /// Absent on a paragraph means "not a list item."
    static let listLevelAttribute = NSAttributedString.Key("studiquo.slideListLevel")
    /// NSString (`DocumentListKind.rawValue`) — only meaningful alongside
    /// `listLevelAttribute`; a paragraph with a level but no explicit kind
    /// attribute is treated as `.bulleted`.
    static let listKindAttribute = NSAttributedString.Key("studiquo.slideListKind")

    static func listKind(at index: Int, in text: NSAttributedString) -> DocumentListKind? {
        guard text.length > 0, index < text.length else { return nil }
        if let raw = text.attribute(listKindAttribute, at: index, effectiveRange: nil) as? String,
           let kind = DocumentListKind(rawValue: raw) {
            return kind
        }
        return (text.attribute(listLevelAttribute, at: index, effectiveRange: nil) as? Int) != nil ? .bulleted : nil
    }

    static func listLevel(at index: Int, in text: NSAttributedString) -> Int {
        guard text.length > 0, index < text.length else { return 0 }
        return (text.attribute(listLevelAttribute, at: index, effectiveRange: nil) as? Int) ?? 0
    }

    /// Marks every paragraph touching `range` as a list item of `kind` at
    /// `level` (clamped to 0...2, matching `marker(kind:level:position:)`'s
    /// glyph table), or clears list formatting entirely when `kind` is `nil`.
    static func setListKind(_ kind: DocumentListKind?, level: Int, forRange range: NSRange, in text: NSMutableAttributedString) {
        let nsString = text.string as NSString
        let paragraphRange = nsString.paragraphRange(for: range)
        guard paragraphRange.length > 0 else { return }
        if let kind {
            text.addAttribute(listKindAttribute, value: kind.rawValue as NSString, range: paragraphRange)
            text.addAttribute(listLevelAttribute, value: max(0, min(2, level)) as NSNumber, range: paragraphRange)
        } else {
            text.removeAttribute(listKindAttribute, range: paragraphRange)
            text.removeAttribute(listLevelAttribute, range: paragraphRange)
        }
    }

    /// The marker glyph/number for a list item at `level`, given how many
    /// consecutive same-kind-same-level items immediately precede it
    /// (`position`, 1-based). The same glyph/numbering rules
    /// `TextDocument.listMarker(for:)` uses for block-based lists, just
    /// driven by an explicit position instead of scanning sibling blocks.
    static func marker(kind: DocumentListKind, level: Int, position: Int) -> String {
        switch kind {
        case .bulleted:
            let glyphs = ["•", "◦", "▪"]
            return glyphs[min(level, glyphs.count - 1)]
        case .numbered:
            switch level {
            case 0: return "\(position)."
            case 1: return "\(lowercaseLetter(for: position))."
            default: return "\(lowercaseRoman(for: position))."
            }
        }
    }

    /// Every paragraph in `text`, paired with its list marker (`nil` for a
    /// non-list paragraph) — what `renderedForDisplay` below walks to
    /// prepend markers and apply per-level indent.
    static func markers(for text: NSAttributedString) -> [(paragraphRange: NSRange, marker: String?)] {
        let nsString = text.string as NSString
        var paragraphRanges: [NSRange] = []
        var location = 0
        repeat {
            let range = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphRanges.append(range)
            let next = range.location + range.length
            guard next > location else { break }
            location = next
        } while location < nsString.length

        return paragraphRanges.enumerated().map { index, range in
            guard let kind = listKind(at: range.location, in: text) else { return (range, nil) }
            let level = listLevel(at: range.location, in: text)
            var position = 1
            var i = index - 1
            while i >= 0,
                  listKind(at: paragraphRanges[i].location, in: text) == kind,
                  listLevel(at: paragraphRanges[i].location, in: text) == level {
                position += 1
                i -= 1
            }
            return (range, marker(kind: kind, level: level, position: position))
        }
    }

    /// A *display* copy of `text` with each list paragraph's marker
    /// prepended and a hanging indent applied via `NSParagraphStyle` — the
    /// same technique `DocumentBody`'s markup parser uses for a bullet's
    /// indent. `text` itself is never modified; the stored form stays the
    /// structured (marker-free) attributes `markers(for:)` reads, so
    /// re-deriving this display string after an edit never drifts from
    /// what's actually saved.
    static func renderedForDisplay(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (range, marker) in markers(for: text) {
            guard range.location + range.length <= text.length else { continue }
            let paragraph = text.attributedSubstring(from: range)
            guard let marker else {
                result.append(paragraph)
                continue
            }
            let mutable = NSMutableAttributedString(attributedString: paragraph)
            let level = listLevel(at: range.location, in: text)
            let indent: CGFloat = 16 + CGFloat(level) * 18
            let markerAttributes: [NSAttributedString.Key: Any] = mutable.length > 0
                ? mutable.attributes(at: 0, effectiveRange: nil)
                : [:]
            mutable.insert(NSAttributedString(string: "\(marker)\t", attributes: markerAttributes), at: 0)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = indent
            paragraphStyle.firstLineHeadIndent = max(0, indent - 18)
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: mutable.length))
            result.append(mutable)
        }
        return result
    }

    /// 1 → "a", 2 → "b", …, 27 → "aa" — mirrors
    /// `TextDocument.lowercaseLetter(for:)` exactly (level-2 numbered style).
    private static func lowercaseLetter(for position: Int) -> String {
        var n = position
        var result = ""
        while n > 0 {
            n -= 1
            let scalar = UnicodeScalar(UnicodeScalar("a").value + UInt32(n % 26))!
            result = String(Character(scalar)) + result
            n /= 26
        }
        return result
    }

    private static func lowercaseRoman(for position: Int) -> String {
        let values: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var n = position
        var result = ""
        for (value, symbol) in values {
            while n >= value {
                result += symbol
                n -= value
            }
        }
        return result
    }
}

// MARK: - Migration from the legacy fixed-layout model

/// Converts a `SlideDeck`'s legacy flat fields — `theme`/`fontFamily`, and
/// each `Slide`'s `titleText`/`bodyText`/`secondaryText`/`imageData`/
/// `legacyLayout` — into the canvas-based `master`/`elements` structure
/// (design step 9). Mirrors `DocumentBlockMigration` exactly: safe to call
/// on every load, and legacy fields are never cleared even after a
/// successful migration, so they remain a fallback.
///
/// Deliberately *two* independent idempotency checks, not one:
/// `deck.master == nil` gates creating the master (once per deck, ever),
/// while each `slide.layout == nil` gates that one slide's own migration —
/// so a slide added to an already-migrated deck (still via the legacy
/// `Slide(order:layout:)` initializer, until every slide-creation call site
/// is updated to build `elements` directly) is still picked up the next
/// time this runs, rather than being silently skipped forever because the
/// *deck* had already been migrated once.
enum SlideBlockMigration {
    static func migrateIfNeeded(_ deck: SlideDeck) {
        if deck.master == nil {
            let created = SlideMaster.makeDefault()
            seedAppearance(created, from: deck)
            created.deck = deck
            deck.master = created
        }
        guard let master = deck.master else { return }
        for slide in deck.sortedSlides where slide.layout == nil {
            migrateSlide(slide, master: master)
        }
        deck.isMigratedToElements = true
    }

    private static func seedAppearance(_ master: SlideMaster, from deck: SlideDeck) {
        let theme = deck.theme
        master.backgroundColorHex = UIColor(theme.background).toHex()
        master.titleColorHex = UIColor(theme.titleColor).toHex()
        master.bodyColorHex = UIColor(theme.bodyColor).toHex()
        master.accentColorHex = UIColor(theme.accent).toHex()
        master.headingFontFamilyRawValue = deck.fontFamilyRawValue
        master.bodyFontFamilyRawValue = deck.fontFamilyRawValue
    }

    /// `SlideMaster.makeDefault()`'s seven layouts are named after exactly
    /// the legacy `SlideLayout` cases' own `.title` strings, so the match
    /// is a plain name lookup rather than a second, separately-maintained
    /// mapping table that could drift from the first.
    private static func migrateSlide(_ slide: Slide, master: SlideMaster) {
        let legacy = slide.legacyLayout
        guard let template = master.sortedLayouts.first(where: { $0.name == legacy.title }) ?? master.sortedLayouts.first else { return }
        slide.layout = template

        var layerIndex = 0.0
        if legacy.hasTitle, !slide.titleText.isEmpty, let placeholder = template.placeholder(for: .title) {
            appendTextElement(slide.titleText, bulletLines: nil, placeholder: placeholder, to: slide, layerIndex: &layerIndex)
        }
        // `legacy.hasBody` is false for `.titleSlide` — its "サブタイトル"
        // placeholder string in the old UI's `bodyView` call was dead code,
        // never actually reachable there (only `.sectionHeader` shares that
        // branch and *is* in `hasBody`). The new model gives titleSlide a
        // real, working subtitle placeholder, so migration surfaces any
        // `bodyText` it already has (e.g. from AI-generated content) rather
        // than reproducing that old dead end.
        if (legacy.hasBody || legacy == .titleSlide), !slide.bodyText.isEmpty {
            // The old UI rendered titleSlide/sectionHeader's body as a plain
            // subtitle line (`bodyView`), and every other layout's as a real
            // bulleted list (`bulletList`) — see SlideDeckView.swift.
            // Migration must match each rendering, not treat them alike.
            let isPlainSubtitle = legacy == .titleSlide || legacy == .sectionHeader
            let role: SlidePlaceholderRole = legacy == .titleSlide ? .subtitle : .body
            if let placeholder = template.placeholder(for: role) {
                appendTextElement(
                    slide.bodyText, bulletLines: isPlainSubtitle ? nil : slide.bullets,
                    placeholder: placeholder, to: slide, layerIndex: &layerIndex
                )
            }
        }
        if legacy.hasSecondary, !slide.secondaryText.isEmpty, let placeholder = template.placeholder(for: .secondaryBody) {
            appendTextElement(slide.secondaryText, bulletLines: slide.secondaryBullets, placeholder: placeholder, to: slide, layerIndex: &layerIndex)
        }
        if legacy.hasImage, let imageData = slide.imageData, let placeholder = template.placeholder(for: .image) {
            let element = SlideElement(kind: .image, layerIndex: layerIndex)
            layerIndex += 1
            element.sourcePlaceholder = placeholder
            element.imageData = imageData
            slide.addElement(element)
        }
    }

    /// `bulletLines`, when given, marks every line as a level-0 bulleted
    /// item — matching the old `bulletList` UI's "one bullet per line"
    /// behaviour, so a migrated body reads as a real list from the moment
    /// migration finishes, not as unstructured plain text.
    private static func appendTextElement(
        _ text: String, bulletLines: [String]?,
        placeholder: SlidePlaceholder, to slide: Slide, layerIndex: inout Double
    ) {
        let element = SlideElement(kind: .text, layerIndex: layerIndex)
        layerIndex += 1
        element.sourcePlaceholder = placeholder
        // When there are bullet lines, the stored text is built from those
        // (already blank-line-filtered by `Slide.bullets`/`secondaryBullets`)
        // rather than the raw field — so the character ranges computed below
        // line up exactly with what's actually in `combined`.
        let baseText = bulletLines?.joined(separator: "\n") ?? text
        let combined = NSMutableAttributedString(string: baseText, attributes: element.defaultTextAttributes())
        if let bulletLines {
            var location = 0
            for line in bulletLines {
                let length = (line as NSString).length
                SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: location, length: length), in: combined)
                location += length + 1
            }
        }
        element.body = combined
        slide.addElement(element)
    }
}
