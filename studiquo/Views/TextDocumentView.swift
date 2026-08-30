import SwiftUI
import SwiftData
import UIKit
import PhotosUI

// MARK: - Attributed body storage

/// Archiving for a document body.
///
/// `NSAttributedString` is archived rather than converted to RTF so inline
/// images (`NSTextAttachment`) survive a round trip; RTF would drop them.
enum DocumentBody {
    static func decode(_ data: Data?) -> NSAttributedString {
        guard let data else { return NSAttributedString(string: "") }
        let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver?.requiresSecureCoding = false
        guard let restored = unarchiver?.decodeObject(
            of: NSAttributedString.self, forKey: NSKeyedArchiveRootObjectKey
        ) else { return NSAttributedString(string: "") }
        return restored
    }

    static func encode(_ text: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
    }

    /// Builds a formatted body from the lightweight markup an LLM is asked to
    /// emit: `#`/`##`/`###` headings and `- ` bullets, everything else body
    /// text. Deliberately not a full Markdown parser — this is the subset a
    /// generated study document actually needs, and anything unrecognised
    /// simply stays as plain text rather than being mangled.
    static func attributedString(fromMarkup markup: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for rawLine in markup.components(separatedBy: .newlines) {
            var line = rawLine
            var style = DocumentParagraphStyle.body
            if line.hasPrefix("### ") { style = .heading3; line.removeFirst(4) }
            else if line.hasPrefix("## ") { style = .heading2; line.removeFirst(3) }
            else if line.hasPrefix("# ") { style = .heading1; line.removeFirst(2) }
            else if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }

            var descriptor = UIFont.systemFont(ofSize: style.fontSize, weight: style.weight).fontDescriptor
            if style.isItalic, let italic = descriptor.withSymbolicTraits(.traitItalic) {
                descriptor = italic
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacingBefore = style.spacingBefore
            paragraph.paragraphSpacing = style.spacingAfter
            paragraph.headIndent = line.hasPrefix("• ") ? 18 : style.headIndent
            paragraph.firstLineHeadIndent = style.headIndent

            result.append(NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: UIFont(descriptor: descriptor, size: style.fontSize),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }

    /// The typography a brand-new document starts in.
    static func defaultAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = DocumentParagraphStyle.body.spacingAfter
        return [
            .font: UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }
}

// MARK: - Editor

/// A word-processor-style editor: a page with margins, a formatting bar that
/// reflects the current selection, paragraph styles, lists, and PDF export.
struct TextDocumentView: View {
    @Bindable var document: TextDocument
    var onHome: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @State private var attributedText = NSAttributedString(string: "")
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var hasLoaded = false
    @State private var formatting = SelectionFormatting()
    /// Bumped when the editor must push `attributedText` back into the text
    /// view — applying a style, inserting an image. Typing flows the other
    /// way and never needs it.
    @State private var externalRevision = 0
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pdfDocument: PDFExportDocument?
    @State private var showsPDFExporter = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formattingBar
            Divider()
            page
        }
        .background(Color(.secondarySystemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: load)
        .onDisappear { flushSave() }
        .onChange(of: attributedText) { _, _ in scheduleSave() }
        .alert("文書名を変更", isPresented: $isRenaming) {
            TextField("文書名", text: $renameDraft)
            Button("キャンセル", role: .cancel) {}
            Button("変更") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { document.title = trimmed; document.updatedAt = .now }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await insertImage(from: item) }
        }
        .modifier(PDFSaveModifier(
            isPresented: $showsPDFExporter,
            document: $pdfDocument,
            filename: "\(document.title).pdf"
        ))
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: onHome) {
                Label("ホームへ戻る", systemImage: "house.fill")
            }
            .buttonStyle(.plain)

            Divider().frame(height: 20)

            Button {
                renameDraft = document.title
                isRenaming = true
            } label: {
                Label(document.title, systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(document.wordCount) 語 ・ \(document.characterCount) 文字")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Picker("用紙サイズ", selection: Binding(
                    get: { document.pageSize },
                    set: { document.pageSize = $0; document.updatedAt = .now }
                )) {
                    ForEach(DocumentPageSize.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("PDFで書き出す", systemImage: "square.and.arrow.down", action: exportPDF)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private var formattingBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(DocumentParagraphStyle.allCases) { style in
                        Button(style.title2) { apply(style: style) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(formatting.paragraphStyle.title2)
                            .font(.subheadline)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(minWidth: 92)
                }

                Divider().frame(height: 22)

                toggle("bold", isOn: formatting.isBold) { toggleTrait(.traitBold) }
                toggle("italic", isOn: formatting.isItalic) { toggleTrait(.traitItalic) }
                toggle("underline", isOn: formatting.isUnderlined) { toggleUnderline() }
                toggle("strikethrough", isOn: formatting.isStruckThrough) { toggleStrikethrough() }

                Divider().frame(height: 22)

                Menu {
                    ForEach(DocumentFontFamily.allCases) { family in
                        Button(family.title) { apply(family: family) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(formatting.familyName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(minWidth: 96, maxWidth: 130)
                }

                Menu {
                    ForEach(DocumentFontSize.presets, id: \.self) { size in
                        Button("\(Int(size)) pt") { setFontSize(size) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(Int(formatting.fontSize))")
                            .font(.subheadline.monospacedDigit())
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(minWidth: 46)
                }

                Button { changeFontSize(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { changeFontSize(by: 1) } label: { Image(systemName: "textformat.size.larger") }

                Divider().frame(height: 22)

                Menu {
                    ForEach(DocumentTextColor.allCases) { swatch in
                        Button {
                            applyAttribute(.foregroundColor, value: swatch.uiColor)
                        } label: {
                            Label(swatch.title, systemImage: "circle.fill")
                        }
                    }
                } label: { Image(systemName: "paintpalette") }

                Menu {
                    Button("なし") { applyAttribute(.backgroundColor, value: UIColor.clear) }
                    ForEach(DocumentHighlight.allCases) { swatch in
                        Button(swatch.title) {
                            applyAttribute(.backgroundColor, value: swatch.uiColor)
                        }
                    }
                } label: { Image(systemName: "highlighter") }

                Divider().frame(height: 22)

                ForEach(DocumentAlignment.allCases) { alignment in
                    Button {
                        apply(alignment: alignment.nsAlignment)
                    } label: {
                        Image(systemName: alignment.icon)
                            .foregroundStyle(formatting.alignment == alignment.nsAlignment ? Color.accentColor : Color.primary)
                    }
                }

                Divider().frame(height: 22)

                Button { applyList(.bulleted) } label: { Image(systemName: "list.bullet") }
                Button { applyList(.numbered) } label: { Image(systemName: "list.number") }
                Button { changeIndent(by: -24) } label: { Image(systemName: "decrease.indent") }
                Button { changeIndent(by: 24) } label: { Image(systemName: "increase.indent") }

                Menu {
                    ForEach(DocumentLineSpacing.allCases) { spacing in
                        Button(spacing.title) { apply(lineSpacing: spacing) }
                    }
                } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }

                Divider().frame(height: 22)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                }

                Button { clearFormatting() } label: { Image(systemName: "eraser.line.dashed") }
                    .accessibilityLabel("書式をクリア")
            }
            .font(.system(size: 16))
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private func toggle(_ icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 30, height: 30)
                .background(isOn ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    /// The page itself, sized to the chosen paper and centred with a shadow —
    /// the layout every word processor uses so the writer can see where the
    /// line breaks will actually fall.
    private var page: some View {
        GeometryReader { geometry in
            ScrollView {
                let width = min(document.pageSize.size.width, max(280, geometry.size.width - 48))
                RichTextEditor(
                    attributedText: $attributedText,
                    selectedRange: $selectedRange,
                    externalRevision: externalRevision,
                    onFormattingChange: { formatting = $0 }
                )
                .frame(width: width)
                .frame(minHeight: document.pageSize.size.height, alignment: .top)
                .padding(document.pageSize.margin * (width / document.pageSize.size.width))
                .background(.white)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard !hasLoaded else { return }
        let restored = DocumentBody.decode(document.bodyData)
        if restored.length == 0 {
            attributedText = NSAttributedString(
                string: "",
                attributes: DocumentBody.defaultAttributes()
            )
        } else {
            attributedText = restored
        }
        externalRevision += 1
        hasLoaded = true
    }

    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        let snapshot = attributedText
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { persist(snapshot) }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        persist(attributedText)
    }

    private func persist(_ text: NSAttributedString) {
        document.bodyData = DocumentBody.encode(text)
        document.plainText = text.string
        document.updatedAt = .now
        try? modelContext.save()
    }

    // MARK: Formatting commands

    /// The range formatting applies to: the selection, or — when nothing is
    /// selected — the word around the caret, matching what a word processor
    /// does when you hit Bold with an empty selection.
    private var effectiveRange: NSRange {
        if selectedRange.length > 0 { return selectedRange }
        let text = attributedText.string as NSString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let caret = min(max(selectedRange.location, 0), text.length)
        return text.rangeOfComposedCharacterSequences(
            for: NSRange(location: max(0, caret - 1), length: caret == 0 ? 0 : 1)
        )
    }

    private func mutate(_ body: (NSMutableAttributedString, NSRange) -> Void) {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let range = clamp(effectiveRange, in: mutable)
        guard range.length > 0 || mutable.length == 0 else { return }
        body(mutable, range)
        attributedText = mutable
        externalRevision += 1
    }

    private func clamp(_ range: NSRange, in text: NSAttributedString) -> NSRange {
        let location = min(max(range.location, 0), text.length)
        let length = min(range.length, text.length - location)
        return NSRange(location: location, length: length)
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        let shouldEnable = trait == .traitBold ? !formatting.isBold : !formatting.isItalic
        mutate { text, range in
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize)
                var traits = font.fontDescriptor.symbolicTraits
                if shouldEnable { traits.insert(trait) } else { traits.remove(trait) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: subrange)
                }
            }
        }
    }

    private func toggleUnderline() {
        let value = formatting.isUnderlined ? 0 : NSUnderlineStyle.single.rawValue
        applyAttribute(.underlineStyle, value: value)
    }

    private func toggleStrikethrough() {
        let value = formatting.isStruckThrough ? 0 : NSUnderlineStyle.single.rawValue
        applyAttribute(.strikethroughStyle, value: value)
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any) {
        mutate { text, range in text.addAttribute(key, value: value, range: range) }
    }

    /// Swaps the typeface while keeping each run's own size and bold/italic
    /// traits — the way a word processor's font menu behaves.
    private func apply(family: DocumentFontFamily) {
        mutate { text, range in
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = (value as? UIFont) ?? UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize)
                let traits = current.fontDescriptor.symbolicTraits
                guard let descriptor = family.descriptor(size: current.pointSize)?
                    .withSymbolicTraits(traits) ?? family.descriptor(size: current.pointSize) else { return }
                text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: subrange)
            }
        }
    }

    private func setFontSize(_ size: CGFloat) {
        mutate { text, range in
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize)
                text.addAttribute(.font, value: font.withSize(size), range: subrange)
            }
        }
    }

    private func changeIndent(by delta: CGFloat) {
        mutate { text, range in
            let paragraphRange = (text.string as NSString).paragraphRange(for: range)
            guard paragraphRange.length > 0 else { return }
            text.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
                let paragraph = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = max(0, paragraph.firstLineHeadIndent + delta)
                paragraph.headIndent = max(0, paragraph.headIndent + delta)
                text.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
            }
        }
    }

    private func apply(lineSpacing: DocumentLineSpacing) {
        mutate { text, range in
            let paragraphRange = (text.string as NSString).paragraphRange(for: range)
            guard paragraphRange.length > 0 else { return }
            text.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
                let paragraph = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = lineSpacing.multiple
                text.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
            }
        }
    }

    /// Word's "Clear All Formatting": back to plain body text, keeping the
    /// characters themselves untouched.
    private func clearFormatting() {
        mutate { text, range in
            text.setAttributes(DocumentBody.defaultAttributes(), range: range)
        }
    }

    private func changeFontSize(by delta: CGFloat) {
        mutate { text, range in
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? UIFont) ?? UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize)
                let size = min(max(font.pointSize + delta, 8), 96)
                text.addAttribute(.font, value: font.withSize(size), range: subrange)
            }
        }
    }

    private func apply(style: DocumentParagraphStyle) {
        mutate { text, range in
            let paragraphRange = (text.string as NSString).paragraphRange(for: range)
            guard paragraphRange.length > 0 else { return }

            var descriptor = UIFont.systemFont(ofSize: style.fontSize, weight: style.weight).fontDescriptor
            if style.isItalic, let italic = descriptor.withSymbolicTraits(.traitItalic) {
                descriptor = italic
            }
            text.addAttribute(
                .font,
                value: UIFont(descriptor: descriptor, size: style.fontSize),
                range: paragraphRange
            )

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacingBefore = style.spacingBefore
            paragraph.paragraphSpacing = style.spacingAfter
            paragraph.headIndent = style.headIndent
            paragraph.firstLineHeadIndent = style.headIndent
            text.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        }
    }

    private func apply(alignment: NSTextAlignment) {
        mutate { text, range in
            let paragraphRange = (text.string as NSString).paragraphRange(for: range)
            guard paragraphRange.length > 0 else { return }
            text.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
                let paragraph = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                paragraph.alignment = alignment
                text.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
            }
        }
    }

    private enum ListKind { case bulleted, numbered }

    /// Lists are written as real prefixed paragraphs with a hanging indent.
    /// TextKit has no list object on iOS, and a hanging indent is what makes
    /// a wrapped bullet line up under its own text rather than the marker.
    private func applyList(_ kind: ListKind) {
        mutate { text, range in
            let nsString = text.string as NSString
            let paragraphRange = nsString.paragraphRange(for: range)
            let existing = nsString.substring(with: paragraphRange)
            var index = 1
            let rewritten = existing
                .components(separatedBy: "\n")
                .map { line -> String in
                    var stripped = line
                    for marker in ["• ", "- "] where stripped.hasPrefix(marker) {
                        stripped = String(stripped.dropFirst(marker.count))
                    }
                    if let dot = stripped.firstIndex(of: "."),
                       Int(stripped[stripped.startIndex..<dot]) != nil,
                       stripped.index(after: dot) < stripped.endIndex,
                       stripped[stripped.index(after: dot)] == " " {
                        stripped = String(stripped[stripped.index(dot, offsetBy: 2)...])
                    }
                    guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { return stripped }
                    let prefix = kind == .bulleted ? "• " : "\(index). "
                    index += 1
                    return prefix + stripped
                }
                .joined(separator: "\n")

            let attributes = text.attributes(at: paragraphRange.location, effectiveRange: nil)
            text.replaceCharacters(
                in: paragraphRange,
                with: NSAttributedString(string: rewritten, attributes: attributes)
            )

            let newRange = NSRange(location: paragraphRange.location, length: (rewritten as NSString).length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 4
            paragraph.headIndent = 18
            paragraph.firstLineHeadIndent = 0
            text.addAttribute(.paragraphStyle, value: paragraph, range: newRange)
        }
    }

    private func insertImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            let attachment = NSTextAttachment()
            // Scaled to the text column so a photo from the camera roll does
            // not arrive thousands of points wide.
            let maxWidth = document.pageSize.size.width - document.pageSize.margin * 2
            let scale = min(1, maxWidth / max(image.size.width, 1))
            attachment.image = image
            attachment.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: image.size.width * scale, height: image.size.height * scale)
            )
            let mutable = NSMutableAttributedString(attributedString: attributedText)
            let insertion = min(max(selectedRange.location, 0), mutable.length)
            mutable.insert(NSAttributedString(attachment: attachment), at: insertion)
            attributedText = mutable
            externalRevision += 1
            photoItem = nil
        }
    }

    // MARK: Export

    private func exportPDF() {
        flushSave()
        let pageSize = document.pageSize.size
        let margin = document.pageSize.margin
        let textRect = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { context in
            var offset = 0
            let total = attributedText.length
            repeat {
                context.beginPage()
                guard let cgContext = UIGraphicsGetCurrentContext() else { break }
                // Core Text draws bottom-up; flip so the page reads the way
                // the editor shows it.
                cgContext.translateBy(x: 0, y: pageSize.height)
                cgContext.scaleBy(x: 1, y: -1)

                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRangeMake(offset, 0), path, nil
                )
                CTFrameDraw(frame, cgContext)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 { break }
                offset += visible.length
            } while offset < total

            if total == 0 { context.beginPage() }
        }
        pdfDocument = PDFExportDocument(data: data)
        showsPDFExporter = true
    }
}

// MARK: - Formatting state

/// What the formatting bar reflects back about the current selection.
struct SelectionFormatting: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var fontSize: CGFloat = DocumentParagraphStyle.body.fontSize
    var alignment: NSTextAlignment = .natural
    var paragraphStyle: DocumentParagraphStyle = .body
    var familyName: String = DocumentFontFamily.system.title

    init() {}

    init(attributes: [NSAttributedString.Key: Any]) {
        let font = (attributes[.font] as? UIFont)
            ?? UIFont.systemFont(ofSize: DocumentParagraphStyle.body.fontSize)
        let traits = font.fontDescriptor.symbolicTraits
        isBold = traits.contains(.traitBold)
        isItalic = traits.contains(.traitItalic)
        isUnderlined = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
        isStruckThrough = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
        fontSize = font.pointSize
        familyName = DocumentFontFamily.displayName(for: font)
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        alignment = paragraph?.alignment ?? .natural
        // Inferred from the size, which is what actually distinguishes the
        // built-in styles from one another.
        paragraphStyle = DocumentParagraphStyle.allCases
            .min { abs($0.fontSize - font.pointSize) < abs($1.fontSize - font.pointSize) } ?? .body
    }
}

/// The typeface menu. Every entry is a face iOS ships, and the Japanese ones
/// are listed because this app's users write in Japanese — a Latin-only font
/// list would silently fall back for most of their text.
enum DocumentFontFamily: String, CaseIterable, Identifiable {
    case system, systemSerif, systemRounded, systemMono
    case hiraginoSans, hiraginoMincho, yuGothic, yuMincho
    case helvetica, times, georgia, courier, avenir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "システム"
        case .systemSerif: "システム（明朝）"
        case .systemRounded: "システム（丸ゴシック）"
        case .systemMono: "システム（等幅）"
        case .hiraginoSans: "ヒラギノ角ゴシック"
        case .hiraginoMincho: "ヒラギノ明朝"
        case .yuGothic: "游ゴシック"
        case .yuMincho: "游明朝"
        case .helvetica: "Helvetica Neue"
        case .times: "Times New Roman"
        case .georgia: "Georgia"
        case .courier: "Courier New"
        case .avenir: "Avenir Next"
        }
    }

    /// Named faces are looked up by PostScript name; the four system entries
    /// go through `UIFont.systemFont` so they pick up the platform's dynamic
    /// text face rather than a hard-coded one.
    private var postScriptName: String? {
        switch self {
        case .system, .systemSerif, .systemRounded, .systemMono: nil
        case .hiraginoSans: "HiraginoSans-W3"
        case .hiraginoMincho: "HiraMinProN-W3"
        case .yuGothic: "YuGothic-Medium"
        case .yuMincho: "YuMincho-Medium"
        case .helvetica: "HelveticaNeue"
        case .times: "TimesNewRomanPSMT"
        case .georgia: "Georgia"
        case .courier: "CourierNewPSMT"
        case .avenir: "AvenirNext-Regular"
        }
    }

    func descriptor(size: CGFloat) -> UIFontDescriptor? {
        if let postScriptName {
            // `UIFont(name:)` returns nil for a face that is not installed, so
            // an unavailable font falls back to the system one rather than
            // producing an invisible or default-substituted run.
            return UIFont(name: postScriptName, size: size)?.fontDescriptor
        }
        let base = UIFont.systemFont(ofSize: size).fontDescriptor
        switch self {
        case .systemSerif: return base.withDesign(.serif) ?? base
        case .systemRounded: return base.withDesign(.rounded) ?? base
        case .systemMono: return base.withDesign(.monospaced) ?? base
        default: return base
        }
    }

    static func displayName(for font: UIFont) -> String {
        if let match = allCases.first(where: { $0.postScriptName == font.fontName }) {
            return match.title
        }
        return system.title
    }
}

enum DocumentFontSize {
    /// The ladder Word offers, which is what people expect to find.
    static let presets: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]
}

enum DocumentLineSpacing: String, CaseIterable, Identifiable {
    case single, oneAndAHalf, double

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "1.0"
        case .oneAndAHalf: "1.5"
        case .double: "2.0"
        }
    }

    var multiple: CGFloat {
        switch self {
        case .single: 1.0
        case .oneAndAHalf: 1.5
        case .double: 2.0
        }
    }
}

private enum DocumentTextColor: String, CaseIterable, Identifiable {
    case primary, red, blue, green, orange, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "標準"
        case .red: "赤"
        case .blue: "青"
        case .green: "緑"
        case .orange: "オレンジ"
        case .gray: "グレー"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .primary: .label
        case .red: UIColor(red: 0.84, green: 0.18, blue: 0.16, alpha: 1)
        case .blue: UIColor(red: 0.09, green: 0.35, blue: 0.72, alpha: 1)
        case .green: UIColor(red: 0.13, green: 0.47, blue: 0.22, alpha: 1)
        case .orange: UIColor(red: 0.85, green: 0.48, blue: 0.05, alpha: 1)
        case .gray: .secondaryLabel
        }
    }
}

private enum DocumentHighlight: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: "黄"
        case .green: "緑"
        case .blue: "青"
        case .pink: "ピンク"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: UIColor.systemYellow.withAlphaComponent(0.45)
        case .green: UIColor.systemGreen.withAlphaComponent(0.32)
        case .blue: UIColor.systemBlue.withAlphaComponent(0.28)
        case .pink: UIColor.systemPink.withAlphaComponent(0.30)
        }
    }
}

private enum DocumentAlignment: String, CaseIterable, Identifiable {
    case left, center, right, justified

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }
}

// MARK: - UITextView bridge

/// Wraps `UITextView` so the document gets real TextKit editing — selection,
/// autocorrect, dictation, hardware-keyboard shortcuts, inline attachments —
/// rather than a SwiftUI `TextEditor`, which has no attributed-text support.
private struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selectedRange: NSRange
    /// Incremented by the owner when it has rewritten `attributedText` and
    /// the change must be pushed into the view. Typing travels the other way.
    var externalRevision: Int
    var onFormattingChange: (SelectionFormatting) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = false
        view.attributedText = attributedText
        view.typingAttributes = DocumentBody.defaultAttributes()
        context.coordinator.lastRevision = externalRevision
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastRevision != externalRevision else { return }
        context.coordinator.lastRevision = externalRevision
        let previous = view.selectedRange
        view.attributedText = attributedText
        view.selectedRange = NSRange(
            location: min(previous.location, view.attributedText.length),
            length: min(previous.length, max(0, view.attributedText.length - previous.location))
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var lastRevision = -1

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.attributedText = textView.attributedText
            report(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
            report(textView)
        }

        /// Reads back what the caret is sitting in so the bar can show the
        /// current state instead of guessing.
        private func report(_ textView: UITextView) {
            let attributes: [NSAttributedString.Key: Any]
            if textView.selectedRange.length > 0 {
                attributes = textView.attributedText.attributes(
                    at: min(textView.selectedRange.location, max(0, textView.attributedText.length - 1)),
                    effectiveRange: nil
                )
            } else if textView.attributedText.length > 0 {
                let index = min(
                    max(0, textView.selectedRange.location - 1),
                    textView.attributedText.length - 1
                )
                attributes = textView.attributedText.attributes(at: index, effectiveRange: nil)
            } else {
                attributes = textView.typingAttributes
            }
            parent.onFormattingChange(SelectionFormatting(attributes: attributes))
        }
    }
}
