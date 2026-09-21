import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

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
    @AppStorage("profileName") private var profileName = ""

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
    @State private var docxDocument: DocxExportDocument?
    @State private var showsDocxExporter = false
    @State private var saveTask: Task<Void, Never>?
    @State private var showsInsertTableSheet = false
    @State private var newTableRows = 2
    @State private var newTableColumns = 2
    @State private var auxiliarySaveTask: Task<Void, Never>?
    @State private var activeSegmentID: ObjectIdentifier?
    /// Set by `activateSegment` (a tap on a previously-inactive segment),
    /// never by `load`'s initial activation — so `RichTextEditor` knows to
    /// bring up the keyboard right after a deliberate tap-to-edit, but
    /// opening the document itself doesn't yank focus before anyone asked
    /// for it.
    @State private var justActivatedSegmentID: ObjectIdentifier?
    @State private var showsChangeHistory = false
    @State private var showsCollabSheet = false
    @State private var showsInsertEquationSheet = false
    @State private var equationDraft = ""
    @State private var showsLinkSheet = false
    @State private var linkURLDraft = ""
    @State private var linkTargetRange = NSRange(location: 0, length: 0)
    @State private var showsSearch = false
    @State private var searchQuery = ""
    @State private var replaceText = ""
    @State private var searchMatches: [DocumentSearchMatch] = []
    @State private var currentMatchIndex = 0
    @State private var scrollTarget: ObjectIdentifier?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsSearch {
                searchBar
                Divider()
            }
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
        .modifier(DocxSaveModifier(
            isPresented: $showsDocxExporter,
            document: $docxDocument,
            filename: "\(document.title).docx"
        ))
        .sheet(isPresented: $showsInsertTableSheet) {
            InsertTableSheet(rows: $newTableRows, columns: $newTableColumns) {
                insertTable(rows: newTableRows, columns: newTableColumns)
                showsInsertTableSheet = false
            }
        }
        .sheet(isPresented: $showsInsertEquationSheet) {
            EquationEditSheet(source: $equationDraft) {
                insertEquation(source: equationDraft)
                showsInsertEquationSheet = false
            }
        }
        .sheet(isPresented: $showsLinkSheet) {
            LinkEditSheet(
                urlString: $linkURLDraft,
                onSave: { applyLink(urlString: linkURLDraft); showsLinkSheet = false },
                onRemove: existingLinkRange != nil ? { removeLink(); showsLinkSheet = false } : nil
            )
        }
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

            Button {
                showsSearch.toggle()
                if showsSearch { refreshSearchMatches() } else { searchMatches = [] }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("検索")

            Button {
                showsChangeHistory = true
            } label: {
                let pendingCount = document.pendingChangeRecords.count
                Image(systemName: "clock.arrow.circlepath")
                    .overlay(alignment: .topTrailing) {
                        if pendingCount > 0 {
                            Text("\(pendingCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            .accessibilityLabel("変更履歴")
            .sheet(isPresented: $showsChangeHistory) {
                ChangeHistorySheet(document: document, onChange: { try? modelContext.save() })
            }

            Button {
                flushSave()
                showsCollabSheet = true
            } label: {
                Image(systemName: "person.2")
            }
            .accessibilityLabel("共同編集")
            .sheet(isPresented: $showsCollabSheet) {
                CollabSheet(document: document, onChange: { try? modelContext.save() })
            }

            Menu {
                Picker("用紙サイズ", selection: Binding(
                    get: { document.pageSize },
                    set: { document.pageSize = $0; document.updatedAt = .now }
                )) {
                    ForEach(DocumentPageSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("段組み", selection: Binding(
                    get: { document.columnCount },
                    set: { document.columnCount = $0; document.updatedAt = .now }
                )) {
                    Text("1列").tag(1)
                    Text("2列").tag(2)
                    Text("3列").tag(3)
                }
                Divider()
                Button("目次を挿入", systemImage: "list.bullet.indent", action: insertTableOfContents)
                Divider()
                Button("PDFで書き出す", systemImage: "square.and.arrow.down", action: exportPDF)
                Button("Wordで書き出す(.docx)", systemImage: "doc.richtext", action: exportDocx)
                Button("印刷", systemImage: "printer") {
                    flushSave()
                    PrintService.printDocument(document)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("検索", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: searchQuery) { _, _ in refreshSearchMatches() }
                if !searchMatches.isEmpty {
                    Text("\(currentMatchIndex + 1)/\(searchMatches.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !searchQuery.isEmpty {
                    Text("見つかりません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button { goToPreviousMatch() } label: { Image(systemName: "chevron.up") }
                    .disabled(searchMatches.isEmpty)
                Button { goToNextMatch() } label: { Image(systemName: "chevron.down") }
                    .disabled(searchMatches.isEmpty)
            }
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                TextField("置換後の文字列", text: $replaceText)
                    .textFieldStyle(.plain)
                Button("置換") { replaceCurrentMatch() }
                    .disabled(searchMatches.isEmpty)
                Button("すべて置換") { replaceAllMatches() }
                    .disabled(searchMatches.isEmpty)
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

                Button { showsInsertTableSheet = true } label: { Image(systemName: "table") }
                    .accessibilityLabel("表を挿入")

                Button { equationDraft = ""; showsInsertEquationSheet = true } label: { Image(systemName: "function") }
                    .accessibilityLabel("数式を挿入")

                Button { beginEditingLink() } label: { Image(systemName: existingLinkRange != nil ? "link.circle.fill" : "link") }
                    .disabled(effectiveRange.length == 0 && existingLinkRange == nil)
                    .accessibilityLabel("リンクを追加")

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
            ScrollViewReader { scrollProxy in
            ScrollView {
                let width = min(document.pageSize.size.width, max(280, geometry.size.width - 48))
                VStack(spacing: 0) {
                    PullToAddStrip(direction: .top, label: "引っ張って段落を追加", armedLabel: "離して段落を追加") {
                        addBlankParagraph(atStart: true)
                    }
                    .padding(.bottom, 6)

                    headerFooterField(kind: .header, placeholder: "ヘッダーを追加")
                        .padding(.bottom, 10)

                    // The document as a sequence of segments (see
                    // `DocumentSegment`) rather than one continuous text
                    // view: this is what lets a table sit between two
                    // paragraphs instead of only ever below all the text.
                    // Only the active segment is a live `RichTextEditor`;
                    // every other text segment renders its saved content
                    // read-only until tapped, at which point it becomes the
                    // active one (see `activateSegment`).
                    ForEach(document.segments) { segment in
                        HStack(alignment: .top, spacing: 6) {
                            Group {
                                switch segment.kind {
                                case .table:
                                    if let block = segment.blocks.first {
                                        DocumentTableBlockView(block: block, onChange: scheduleAuxiliarySave)
                                            .padding(.vertical, 12)
                                    }
                                case .equation:
                                    if let block = segment.blocks.first {
                                        DocumentEquationBlockView(block: block, onChange: scheduleAuxiliarySave)
                                            .padding(.vertical, 8)
                                    }
                                case .tableOfContents:
                                    if let block = segment.blocks.first {
                                        DocumentTableOfContentsBlockView(block: block, document: document)
                                            .padding(.vertical, 8)
                                    }
                                case .text:
                                    if segment.id == activeSegmentID {
                                        RichTextEditor(
                                            attributedText: $attributedText,
                                            selectedRange: $selectedRange,
                                            externalRevision: externalRevision,
                                            shouldFocusOnAppear: justActivatedSegmentID == segment.id,
                                            onFormattingChange: { formatting = $0 }
                                        )
                                        .frame(minHeight: 26, alignment: .top)
                                    } else {
                                        TextSegmentPreview(blocks: segment.blocks, document: document)
                                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                                            .contentShape(Rectangle())
                                            .onTapGesture { activateSegment(segment) }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            SegmentCommentButton(
                                blocks: segment.blocks,
                                targetBlock: segment.id == activeSegmentID ? (currentParagraphBlock() ?? segment.commentAnchor) : segment.commentAnchor,
                                onChange: scheduleAuxiliarySave
                            )
                                .padding(.top, 4)

                            SegmentFootnoteButton(block: segment.commentAnchor, document: document, onChange: scheduleAuxiliarySave)
                                .padding(.top, 4)
                        }
                        .id(segment.id)
                    }

                    if !(document.footnotes ?? []).isEmpty {
                        Divider().padding(.vertical, 12)
                        FootnotesListView(document: document)
                    }

                    headerFooterField(kind: .footer, placeholder: "フッターを追加")
                        .padding(.top, 10)

                    PullToAddStrip(direction: .bottom, label: "引っ張って段落を追加", armedLabel: "離して段落を追加") {
                        addBlankParagraph(atStart: false)
                    }
                    .padding(.top, 6)
                }
                .frame(minHeight: document.pageSize.size.height * 0.6, alignment: .top)
                .frame(width: width)
                .padding(document.pageSize.margin * (width / document.pageSize.size.width))
                .background(.white)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { scrollProxy.scrollTo(target, anchor: .center) }
            }
            }
        }
    }

    // MARK: Header & footer

    /// A tap target in the page's own margin, matching how a word processor
    /// lets you edit a header/footer directly where it's shown — rather than
    /// a separate toggle or sheet — but backed by `DocumentHeaderFooter`,
    /// lazily created (`TextDocument.headerFooter(_:)`) the moment someone
    /// actually types into it.
    private func headerFooterField(kind: DocumentHeaderFooterKind, placeholder: String) -> some View {
        let existing = kind == .header ? document.header : document.footer
        return HStack(spacing: 8) {
            TextField(placeholder, text: Binding(
                get: { existing?.text ?? "" },
                set: { document.headerFooter(kind).text = $0; scheduleAuxiliarySave() }
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                let target = document.headerFooter(kind)
                target.showsPageNumber.toggle()
                scheduleAuxiliarySave()
            } label: {
                Image(systemName: existing?.showsPageNumber == true ? "number.circle.fill" : "number.circle")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("ページ番号を\(kind == .header ? "ヘッダー" : "フッター")に表示")
        }
    }

    // MARK: Tables

    /// Splits the active segment at the cursor and inserts the table
    /// between the two halves (see `TextDocument.insertTable`), then makes
    /// the half after the table the new active segment — same as where a
    /// word processor leaves your cursor right after inserting something.
    private func insertTable(rows: Int, columns: Int) {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return }
        let result = document.insertTable(
            rows: rows, columns: columns,
            splitting: segment, liveText: attributedText, at: selectedRange.location
        )
        activeSegmentID = result.after.id
        attributedText = DocumentBlockText.joinedText(of: result.after.blocks)
        selectedRange = NSRange(location: 0, length: 0)
        externalRevision += 1
        document.updatedAt = .now
        try? modelContext.save()
    }

    /// Same insertion flow as `insertTable`, for a formula instead of a
    /// table.
    private func insertEquation(source: String) {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return }
        let result = document.insertEquation(
            source: source, splitting: segment, liveText: attributedText, at: selectedRange.location
        )
        activeSegmentID = result.after.id
        attributedText = DocumentBlockText.joinedText(of: result.after.blocks)
        selectedRange = NSRange(location: 0, length: 0)
        externalRevision += 1
        document.updatedAt = .now
        try? modelContext.save()
    }

    private func insertTableOfContents() {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return }
        let result = document.insertTableOfContents(splitting: segment, liveText: attributedText, at: selectedRange.location)
        activeSegmentID = result.after.id
        attributedText = DocumentBlockText.joinedText(of: result.after.blocks)
        selectedRange = NSRange(location: 0, length: 0)
        externalRevision += 1
        document.updatedAt = .now
        try? modelContext.save()
    }

    /// Commits the active segment's live text, then switches which segment
    /// is "live" — the tapped one takes over `attributedText`/
    /// `selectedRange`, and the previously active one starts rendering its
    /// saved content read-only instead.
    // MARK: Search & replace

    /// Commits the active segment (so every block reflects live edits, not
    /// just whichever were last saved) and recomputes `searchMatches`, then
    /// jumps to the first one.
    private func refreshSearchMatches() {
        commitActiveSegment(withText: attributedText)
        searchMatches = document.searchMatches(for: searchQuery)
        currentMatchIndex = 0
        if let first = searchMatches.first { navigateToMatch(first) }
    }

    private func goToNextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        navigateToMatch(searchMatches[currentMatchIndex])
    }

    private func goToPreviousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        navigateToMatch(searchMatches[currentMatchIndex])
    }

    /// Inserts a blank paragraph at the very start/end of the document
    /// (the "pull past the page edge" gesture) and jumps straight to it,
    /// ready to type — the document equivalent of a notebook's "pull to
    /// add a page."
    private func addBlankParagraph(atStart: Bool) {
        let block = document.insertBlankParagraph(atStart: atStart)
        scheduleAuxiliarySave()
        guard let segment = document.segments.first(where: { seg in seg.blocks.contains(where: { $0 === block }) }) else { return }
        activateSegment(segment)
        scrollTarget = segment.id
    }

    /// Activates `match`'s segment if it isn't already, then selects the
    /// match within it and scrolls it into view — the outer page is one
    /// long `ScrollView`, so bringing a match on-screen needs
    /// `ScrollViewReader`, not anything the (non-scrolling) `RichTextEditor`
    /// itself can do.
    private func navigateToMatch(_ match: DocumentSearchMatch) {
        guard let segment = document.segments.first(where: { seg in seg.blocks.contains(where: { $0 === match.block }) }) else { return }
        if segment.id != activeSegmentID {
            activateSegment(segment)
        }
        guard let blockIndex = segment.blocks.firstIndex(where: { $0 === match.block }) else { return }
        var offset = 0
        for i in 0..<blockIndex {
            offset += DocumentBody.decode(segment.blocks[i].bodyData).length + 1 // +1 for the "\n" joiner
        }
        selectedRange = NSRange(location: offset + match.range.location, length: match.range.length)
        externalRevision += 1
        scrollTarget = segment.id
    }

    /// Replaces the current match, then re-searches — simplest way to keep
    /// every other match's stored range valid, since a replacement can
    /// change the text's length. `currentMatchIndex` naturally now points at
    /// what used to be the next match.
    private func replaceCurrentMatch() {
        guard currentMatchIndex < searchMatches.count else { return }
        let match = searchMatches[currentMatchIndex]
        document.replaceMatch(match, with: replaceText)
        reloadActiveSegmentIfNeeded(containing: match.block)
        try? modelContext.save()
        let indexToKeep = currentMatchIndex
        searchMatches = document.searchMatches(for: searchQuery)
        currentMatchIndex = min(indexToKeep, max(0, searchMatches.count - 1))
        if currentMatchIndex < searchMatches.count { navigateToMatch(searchMatches[currentMatchIndex]) }
    }

    private func replaceAllMatches() {
        guard !searchMatches.isEmpty else { return }
        document.replaceAllMatches(searchMatches, with: replaceText)
        if let activeID = activeSegmentID, let segment = document.segments.first(where: { $0.id == activeID }) {
            attributedText = DocumentBlockText.joinedText(of: segment.blocks)
            externalRevision += 1
        }
        try? modelContext.save()
        searchMatches = []
        currentMatchIndex = 0
    }

    /// After a direct block edit (search/replace bypasses the live editor,
    /// see `TextDocument.replaceMatch`'s doc comment), the active segment's
    /// `attributedText` needs reloading if the edit touched one of its
    /// blocks — otherwise the on-screen text would still show the
    /// pre-replacement wording until the segment was left and reopened.
    private func reloadActiveSegmentIfNeeded(containing block: DocumentBlock) {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }),
              segment.blocks.contains(where: { $0 === block }) else { return }
        attributedText = DocumentBlockText.joinedText(of: segment.blocks)
        externalRevision += 1
    }

    private func activateSegment(_ segment: DocumentSegment) {
        guard segment.id != activeSegmentID else { return }
        commitActiveSegment(withText: attributedText)
        activeSegmentID = segment.id
        justActivatedSegmentID = segment.id
        attributedText = DocumentBlockText.joinedText(of: segment.blocks)
        selectedRange = NSRange(location: attributedText.length, length: 0)
        externalRevision += 1
    }

    /// Writes the active segment's current live text back into its own
    /// blocks — called when switching to a different segment or inserting a
    /// table (both need every segment's `blocks` up to date to compute
    /// correctly), and from `flushSave`. Deliberately *not* called from the
    /// per-keystroke debounced save (`scheduleSave`/`persist`) — see
    /// `wholeDocumentText`'s doc comment.
    private func commitActiveSegment(withText text: NSAttributedString) {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return }
        let previousText = DocumentBlockText.joinedText(of: segment.blocks).string
        let newRun = document.replaceParagraphRun(segment.blocks, with: text)
        if previousText != text.string {
            recordParagraphChanges(previousText: previousText, newRun: newRun)
        }
    }

    /// Records one `DocumentChangeRecord` per paragraph that actually
    /// changed within the committed segment, each anchored to its own new
    /// block — not one record for the whole segment anchored only to its
    /// first paragraph, which would misattribute every edit in a
    /// multi-paragraph segment to paragraph one and (via `recordChange`'s
    /// collaboration hook) propose the whole segment's text as a single
    /// change to the wrong block order.
    ///
    /// Paragraphs are compared by position — old paragraph *i* against new
    /// paragraph *i* — the same index-based correspondence
    /// `DocumentBlockText.carryOverListMetadata` already relies on
    /// elsewhere. A real diff (recognizing an inserted or deleted paragraph
    /// and shifting later comparisons to compensate) is more than a
    /// per-paragraph change history needs; worst case here is a paragraph
    /// insertion/deletion showing every later paragraph as "changed" too,
    /// same as that existing simplification already accepts.
    private func recordParagraphChanges(previousText: String, newRun: [DocumentBlock]) {
        let oldParagraphs = previousText.components(separatedBy: "\n")
        let newParagraphs = newRun.map { DocumentBody.decode($0.bodyData).string }
        for index in 0..<max(oldParagraphs.count, newParagraphs.count) {
            let old = index < oldParagraphs.count ? oldParagraphs[index] : ""
            let new = index < newParagraphs.count ? newParagraphs[index] : ""
            guard old != new else { continue }
            recordChange(previousText: old, newText: new, anchorBlock: index < newRun.count ? newRun[index] : newRun.last)
        }
    }

    /// Logs one `DocumentChangeRecord`, attributed to the profile name set
    /// in Profile & Friends — same source `CommentThreadSheet` uses for a
    /// comment's author. When this document has collaboration turned on,
    /// also proposes the edit to the room in the background — see
    /// `CollabSheet`'s doc comment for what that does and doesn't cover.
    private func recordChange(previousText: String, newText: String, anchorBlock: DocumentBlock?) {
        let record = DocumentChangeRecord(
            author: profileName.isEmpty ? "Studiquoユーザー" : profileName,
            kind: .edit, previousText: previousText, newText: newText, anchorBlock: anchorBlock
        )
        record.document = document
        document.changeRecords = (document.changeRecords ?? []) + [record]

        if let roomID = document.collabRoomID, let blockOrder = anchorBlock?.order {
            Task {
                guard let result = try? await DocumentCollabService.propose(
                    roomID: roomID, blockOrder: blockOrder, previousText: previousText, newText: newText
                ) else { return }
                await MainActor.run { record.collabChangeID = result.id }
            }
        }
    }

    /// The whole document's flowing text, for `bodyData`/`plainText` — every
    /// `.paragraph` block in reading order (tables are skipped; those two
    /// fields are a best-effort text-only projection for legacy readers —
    /// the MCP tool surface, chat's AI context, the library preview — that
    /// have no notion of a table), substituting `activeText` for whichever
    /// segment is currently live rather than that segment's last-committed
    /// `blocks`.
    ///
    /// Reading `activeText` here instead of always calling
    /// `commitActiveSegment` first is what keeps ordinary typing cheap: the
    /// debounced autosave that calls this runs every ~400ms while someone is
    /// typing, and committing the active segment on every one of those would
    /// mean rebuilding its `DocumentBlock`s (and, with CloudKit syncing,
    /// pushing that churn to the server) at the same frequency.
    private func wholeDocumentText(activeText: NSAttributedString) -> NSAttributedString {
        let whole = NSMutableAttributedString()
        var previousEndAttributes: [NSAttributedString.Key: Any]?
        for segment in document.segments where segment.kind == .text {
            let text = segment.id == activeSegmentID ? activeText : DocumentBlockText.joinedText(of: segment.blocks)
            if let previousEndAttributes {
                whole.append(NSAttributedString(string: "\n", attributes: previousEndAttributes))
            }
            whole.append(text)
            previousEndAttributes = text.length > 0
                ? text.attributes(at: text.length - 1, effectiveRange: nil)
                : DocumentBody.defaultAttributes()
        }
        return whole
    }

    /// Debounced the same way `scheduleSave` debounces text edits, but much
    /// cheaper: a table-cell keystroke only needs `modelContext.save()`, not
    /// the paragraph-block resync `flushSave` also does — that resync reads
    /// `attributedText`, which a table edit never touches.
    private func scheduleAuxiliarySave() {
        auxiliarySaveTask?.cancel()
        document.updatedAt = .now
        auxiliarySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { try? modelContext.save() }
        }
    }

    // MARK: Persistence

    private func load() {
        guard !hasLoaded else { return }
        // Populates `document.blocks` from the legacy `bodyData` blob the
        // first time this document is opened after the block-based model
        // shipped, so there's a first text segment to activate below.
        DocumentBlockMigration.migrateIfNeeded(document)
        guard let firstTextSegment = document.segments.first(where: { $0.kind == .text }) else {
            // Every document has at least one paragraph block after
            // migration, so this shouldn't happen — but fail into an empty,
            // still-usable editor rather than a blank screen.
            attributedText = NSAttributedString(string: "", attributes: DocumentBody.defaultAttributes())
            hasLoaded = true
            return
        }
        activeSegmentID = firstTextSegment.id
        attributedText = DocumentBlockText.joinedText(of: firstTextSegment.blocks)
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
        auxiliarySaveTask?.cancel()
        auxiliarySaveTask = nil
        commitActiveSegment(withText: attributedText)
        persist(attributedText)
        try? modelContext.save()
    }

    private func persist(_ text: NSAttributedString) {
        let whole = wholeDocumentText(activeText: text)
        document.bodyData = DocumentBody.encode(whole)
        document.plainText = whole.string
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

    // MARK: Hyperlinks

    /// The full extent of an existing link the caret sits inside (or the
    /// selection overlaps), if any — wider than `effectiveRange` on
    /// purpose: editing or removing a link should act on the *whole* linked
    /// run, not just wherever the caret happens to be within it.
    private var existingLinkRange: NSRange? {
        let text = attributedText
        guard text.length > 0 else { return nil }
        let location = min(max(selectedRange.location, 0), text.length - 1)
        guard text.attribute(.link, at: location, effectiveRange: nil) != nil else { return nil }
        var range = NSRange(location: 0, length: 0)
        _ = text.attribute(.link, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length))
        return range
    }

    private func beginEditingLink() {
        if let range = existingLinkRange {
            linkTargetRange = range
            linkURLDraft = (attributedText.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString ?? ""
        } else {
            linkTargetRange = effectiveRange
            linkURLDraft = ""
        }
        showsLinkSheet = true
    }

    private func applyLink(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare domain like "example.com" is a common thing to type and
        // clearly meant as a link, but has no scheme for `URL` to parse
        // correctly as one — default it to https rather than rejecting it.
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else { return }
        mutateRange(linkTargetRange) { text, range in
            text.addAttribute(.link, value: url, range: range)
            text.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    private func removeLink() {
        mutateRange(linkTargetRange) { text, range in
            text.removeAttribute(.link, range: range)
            text.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            text.removeAttribute(.underlineStyle, range: range)
        }
    }

    /// Same commit-and-reapply shape as `mutate`, but for a range captured
    /// earlier (`linkTargetRange`) rather than the current selection —
    /// `beginEditingLink` already resolved which range this edit targets
    /// before the link sheet opened, and the selection can't be trusted to
    /// still describe it by the time the sheet's Save button runs.
    private func mutateRange(_ range: NSRange, _ body: (NSMutableAttributedString, NSRange) -> Void) {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let clamped = clamp(range, in: mutable)
        guard clamped.length > 0 else { return }
        body(mutable, clamped)
        attributedText = mutable
        selectedRange = NSRange(location: clamped.location + clamped.length, length: 0)
        externalRevision += 1
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

    /// The block, among the active segment's, that the caret (or the start
    /// of the current selection) currently falls in — `nil` before the
    /// first load or if there's no active segment.
    private func currentParagraphBlock() -> DocumentBlock? {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return nil }
        let nsString = attributedText.string as NSString
        let caret = min(max(selectedRange.location, 0), nsString.length)
        let paragraphIndex = nsString.substring(to: caret).components(separatedBy: "\n").count - 1
        guard paragraphIndex >= 0, paragraphIndex < segment.blocks.count else { return nil }
        return segment.blocks[paragraphIndex]
    }

    /// Toggles the current paragraph's list state — set `.bulleted`/
    /// `.numbered` if it wasn't already that kind, or plain again if it was.
    /// Sets it directly on the block object currently backing the active
    /// segment; `DocumentBlockText.carryOverListMetadata` is what keeps this
    /// alive across the next commit, which replaces that very object (see
    /// its doc comment).
    private func applyList(_ kind: DocumentListKind) {
        guard let block = currentParagraphBlock() else { return }
        block.listKind = block.listKind == kind ? nil : kind
        scheduleAuxiliarySave()
    }

    private func changeIndent(by delta: CGFloat) {
        if let block = currentParagraphBlock(), block.listKind != nil {
            block.listLevel = max(0, min(2, block.listLevel + (delta > 0 ? 1 : -1)))
            scheduleAuxiliarySave()
        }
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

    /// The blocks, among the active segment's, that `effectiveRange`'s
    /// paragraph range spans — mirrors what the visual formatting below
    /// affects, so tagging a block's real `paragraphStyle` (for the table of
    /// contents) stays consistent with what actually got reformatted, for a
    /// multi-paragraph selection too.
    private func affectedParagraphBlocks() -> [DocumentBlock] {
        guard let activeID = activeSegmentID,
              let segment = document.segments.first(where: { $0.id == activeID }) else { return [] }
        let nsString = attributedText.string as NSString
        let range = clamp(effectiveRange, in: attributedText)
        let paragraphRange = nsString.paragraphRange(for: range)
        let startIndex = nsString.substring(to: paragraphRange.location).components(separatedBy: "\n").count - 1
        let endIndex = nsString.substring(to: paragraphRange.location + paragraphRange.length).components(separatedBy: "\n").count - 1
        guard startIndex >= 0, startIndex < segment.blocks.count else { return [] }
        let clampedEnd = min(endIndex, segment.blocks.count - 1)
        guard startIndex <= clampedEnd else { return [] }
        return Array(segment.blocks[startIndex...clampedEnd])
    }

    private func apply(style: DocumentParagraphStyle) {
        for block in affectedParagraphBlocks() {
            block.paragraphStyle = style
        }
        scheduleAuxiliarySave()
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

    /// Delegates to `ExportService.pdfData(from:)` — the shared renderer
    /// `PrintService` and chat's "share as PDF" also use — rather than
    /// rendering its own PDF here. This used to have its own inline copy of
    /// the rendering loop, which only ever drew `attributedText` (the
    /// *active segment's* text alone): since the document became a sequence
    /// of segments, that copy silently stopped exporting anything outside
    /// whichever segment happened to be focused — no tables, no other text
    /// segments, no equations. Found while wiring up print, which pointed
    /// at `ExportService` from the start and made the mismatch obvious.
    private func exportPDF() {
        flushSave()
        guard let data = ExportService.pdfData(from: document) else { return }
        pdfDocument = PDFExportDocument(data: data)
        showsPDFExporter = true
    }

    private func exportDocx() {
        flushSave()
        guard let data = DocxWriter.makeDocxData(from: document) else { return }
        docxDocument = DocxExportDocument(data: data)
        showsDocxExporter = true
    }
}

struct DocxExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "docx") ?? .data]
    }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct DocxSaveModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var document: DocxExportDocument?
    let filename: String

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: $isPresented,
            document: document,
            contentType: UTType(filenameExtension: "docx") ?? .data,
            defaultFilename: filename
        ) { _ in
            document = nil
        }
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
///
/// Not document-specific despite living in this file — it only knows about
/// `NSAttributedString`/`NSRange`/`SelectionFormatting`, so the slide
/// canvas's own rich-text editing (design fix item 5) reuses this exact
/// type directly for each text box, rather than a second, independently
/// written bridge.
struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selectedRange: NSRange
    /// Incremented by the owner when it has rewritten `attributedText` and
    /// the change must be pushed into the view. Typing travels the other way.
    var externalRevision: Int
    /// True exactly when this view is being mounted for a segment the user
    /// just tapped to activate (see `TextDocumentView.justActivatedSegmentID`)
    /// — not for the segment `load()` activates by default when the
    /// document first opens. `makeUIView` only runs once per mount, so this
    /// is read once and never needs resetting.
    var shouldFocusOnAppear: Bool
    /// What a caret in genuinely empty text starts typing with — defaults
    /// to the document editor's own default, but the slide canvas passes
    /// `SlideElement.defaultTextAttributes()` instead so a brand-new,
    /// empty text box starts at its placeholder's own size rather than the
    /// document feature's.
    var defaultTypingAttributes: [NSAttributedString.Key: Any] = DocumentBody.defaultAttributes()
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
        view.typingAttributes = defaultTypingAttributes
        context.coordinator.lastRevision = externalRevision
        if shouldFocusOnAppear {
            // Not yet in the window hierarchy at this point in makeUIView,
            // so becomeFirstResponder() here would silently no-op — defer
            // to the next run loop turn, after SwiftUI has inserted it.
            DispatchQueue.main.async { [weak view] in
                view?.becomeFirstResponder()
            }
        }
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

// MARK: - Text segment preview

/// Read-only rendering of an inactive `.text` segment's blocks, one row per
/// paragraph rather than a single flowing `Text` — what lets a list item
/// show its marker (see `TextDocument.listMarker(for:)`) in its own gutter
/// column instead of as literal characters inside the paragraph, the way
/// the editor used to write "• "/"1. " directly into the text.
///
/// The active segment (being edited live in a `RichTextEditor`) doesn't get
/// this treatment — injecting a marker into text a `UITextView` is actively
/// editing, then having to strip it back out again on every save without
/// ever mismatching, is a lot of fragile bookkeeping for what's fundamentally
/// a display concern. A list item's marker simply isn't shown while you're
/// actively typing that exact paragraph; it appears the moment you tap away.
private struct TextSegmentPreview: View {
    let blocks: [DocumentBlock]
    let document: TextDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let marker = document.listMarker(for: block) {
                        Text(marker)
                            .frame(minWidth: 22, alignment: .trailing)
                    }
                    Text(AttributedString(DocumentBody.decode(block.bodyData)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Table insertion sheet

private struct InsertTableSheet: View {
    @Binding var rows: Int
    @Binding var columns: Int
    let onInsert: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Stepper("行: \(rows)", value: $rows, in: 1...20)
                Stepper("列: \(columns)", value: $columns, in: 1...10)
            }
            .navigationTitle("表を挿入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("挿入", action: onInsert)
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}

// MARK: - Link editing sheet

/// A URL field for the selected text — pre-filled and offering a "リンクを削除"
/// option when the caret was already inside an existing link
/// (`onRemove != nil`), or empty for adding a new one.
private struct LinkEditSheet: View {
    @Binding var urlString: String
    let onSave: () -> Void
    let onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com", text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let onRemove {
                    Button("リンクを削除", role: .destructive, action: onRemove)
                }
            }
            .navigationTitle("リンク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}

// MARK: - Table of contents block view

/// Renders one `.tableOfContents` block: every current heading in the
/// document (`document.tableOfContentsLines`, recomputed fresh — see its
/// doc comment), indented by level. There's nothing to edit here — the
/// content always reflects whatever headings exist right now, so unlike
/// Word's TOC there's no separate "refresh" action needed.
private struct DocumentTableOfContentsBlockView: View {
    let block: DocumentBlock
    let document: TextDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("目次", systemImage: "list.bullet.indent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("削除", role: .destructive) {
                    block.document?.blocks?.removeAll { $0 === block }
                }
                .font(.caption)
            }
            let lines = document.tableOfContentsLines
            if lines.isEmpty {
                Text("見出し(タイトル/見出し1〜3)を設定すると、ここに一覧が表示されます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 15 - CGFloat(line.level)))
                        .padding(.leading, CGFloat(line.level) * 16)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Equation editing sheet

/// A source text field (the small LaTeX-like syntax `MathExpressionParser`
/// reads) with a live-rendered preview below it — used both for inserting a
/// new equation and, via `DocumentEquationBlockView`'s tap gesture, for
/// editing an existing one in place.
private struct EquationEditSheet: View {
    @Binding var source: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("入力(LaTeX風の記法)") {
                    TextField("例: x^2 + \\frac{1}{2}", text: $source, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                }
                Section("プレビュー") {
                    ScrollView(.horizontal) {
                        MathExpressionView(expression: MathExpressionParser.parse(source), fontSize: 22)
                            .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("数式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Renders one `.equation` block inline, tappable to edit its source via
/// `EquationEditSheet`.
private struct DocumentEquationBlockView: View {
    @Bindable var block: DocumentBlock
    let onChange: () -> Void
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        MathExpressionView(expression: MathExpressionParser.parse(block.equationSource), fontSize: 20)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                draft = block.equationSource
                isEditing = true
            }
            .sheet(isPresented: $isEditing) {
                EquationEditSheet(source: $draft) {
                    block.equationSource = draft
                    onChange()
                    isEditing = false
                }
            }
    }
}

// MARK: - Table block view

/// Renders one `.table` block as an editable grid, and its own add/remove
/// row/column/table controls. Both `DocumentTableCell.columnSpan` (merge
/// right) and `rowSpan` (merge down) are editable here, via each cell's
/// context menu — see `DocumentBlock.tableGridRows` for how a row whose cell
/// was absorbed by a merge above it still renders a blank placeholder in
/// that cell's place, so every row's columns stay aligned.
private struct DocumentTableBlockView: View {
    @Bindable var block: DocumentBlock
    let onChange: () -> Void

    private let cellWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 1) {
                let rows = block.sortedTableRows
                let gridRows = block.tableGridRows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 1) {
                        let slots = rowIndex < gridRows.count ? gridRows[rowIndex] : []
                        let cellCountInRow = row.sortedCells.count
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                            switch slot {
                            case .cell(let cell):
                                let cellIndex = row.sortedCells.firstIndex(where: { $0 === cell }) ?? 0
                                TextField("", text: Binding(
                                    get: { cell.text },
                                    set: { cell.text = $0; onChange() }
                                ), axis: .vertical)
                                .font(.system(size: 14))
                                .padding(8)
                                // A merged cell's size scales with its
                                // columnSpan/rowSpan (plus the 1pt row
                                // spacing each absorbed column/row would
                                // otherwise have had), so it visually covers
                                // the slots the cells it merged with used to
                                // occupy — those cells no longer exist in
                                // `row.cells` at all, see
                                // `mergeCellWithRight`/`mergeCellWithBelow`.
                                .frame(
                                    width: cellWidth * CGFloat(cell.columnSpan) + CGFloat(cell.columnSpan - 1),
                                    alignment: .topLeading
                                )
                                .background(Color(.secondarySystemBackground))
                                .contextMenu {
                                    if cellIndex < cellCountInRow - 1 {
                                        Button("右のセルと結合") {
                                            block.mergeCellWithRight(row: row, cellIndex: cellIndex)
                                            onChange()
                                        }
                                    }
                                    if rowIndex < rows.count - 1 {
                                        Button("下のセルと結合") {
                                            block.mergeCellWithBelow(row: row, cellIndex: cellIndex)
                                            onChange()
                                        }
                                    }
                                }
                            case .covered(let columnSpan):
                                // Blank space a cell above already covers
                                // via its rowSpan — keeps this row's other
                                // cells aligned under the same columns as
                                // the rows above and below them.
                                Color.clear
                                    .frame(width: cellWidth * CGFloat(columnSpan) + CGFloat(columnSpan - 1))
                            }
                        }
                    }
                }
            }
            .background(Color(.separator))
            .border(Color(.separator))

            HStack(spacing: 16) {
                Button("行を追加") { block.addTableRow(); onChange() }
                Button("列を追加") { block.addTableColumn(); onChange() }
                Button("最後の行を削除") { block.removeLastTableRow(); onChange() }
                Button("最後の列を削除") { block.removeLastTableColumn(); onChange() }
                Spacer()
                Button("表を削除", role: .destructive) {
                    block.document?.blocks?.removeAll { $0 === block }
                    onChange()
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Comments

/// A comment thread across every block in one text segment — every comment
/// on any of those blocks, oldest first, a field to add another, and a
/// resolve/reopen toggle per comment. A *new* comment attaches to
/// `targetBlock` specifically (the paragraph under the cursor when the
/// segment is the live one, or its first paragraph otherwise — see the call
/// site in `page`), not always the segment's first paragraph, so a comment
/// on paragraph 3 of a 5-paragraph segment doesn't silently attach to
/// paragraph 1. Existing comments keep whichever block they were already
/// anchored to; each row shows a "段落N" label when the segment has more
/// than one paragraph, so it stays clear which one a given comment is on.
private struct CommentThreadSheet: View {
    let blocks: [DocumentBlock]
    @Bindable var targetBlock: DocumentBlock
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("profileName") private var profileName = ""
    @State private var draft = ""

    private var allComments: [DocumentComment] {
        blocks.flatMap(\.sortedAnchoredComments).sorted { $0.createdAt < $1.createdAt }
    }

    private func paragraphLabel(for comment: DocumentComment) -> String? {
        guard blocks.count > 1,
              let anchor = comment.anchorBlock,
              let index = blocks.firstIndex(where: { $0 === anchor }) else { return nil }
        return "段落\(index + 1)"
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(allComments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.author).font(.subheadline.weight(.semibold))
                            if let label = paragraphLabel(for: comment) {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                            }
                            Spacer()
                            Text(comment.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(comment.text)
                            .strikethrough(comment.isResolved)
                            .foregroundStyle(comment.isResolved ? .secondary : .primary)
                    }
                    .swipeActions {
                        Button(comment.isResolved ? "未解決に戻す" : "解決済みにする") {
                            comment.isResolved.toggle()
                            onChange()
                        }
                        .tint(comment.isResolved ? .orange : .green)
                    }
                }
            }
            .overlay {
                if allComments.isEmpty {
                    ContentUnavailableView("コメントはまだありません", systemImage: "bubble.left")
                }
            }
            .navigationTitle("コメント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("コメントを追加", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("送信") {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        targetBlock.addComment(author: profileName.isEmpty ? "Studiquoユーザー" : profileName, text: trimmed)
                        draft = ""
                        onChange()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The small comment-count button shown next to every segment — opens
/// `CommentThreadSheet` across every block in `blocks`, with `targetBlock`
/// as where a new comment attaches. Shown for every segment (not just ones
/// that already have comments), the way a word processor lets you comment
/// on any selection rather than only revisiting existing threads.
private struct SegmentCommentButton: View {
    let blocks: [DocumentBlock]
    let targetBlock: DocumentBlock?
    let onChange: () -> Void
    @State private var isShowingThread = false

    private var allComments: [DocumentComment] {
        blocks.flatMap(\.sortedAnchoredComments)
    }

    var body: some View {
        if let targetBlock {
            Button {
                isShowingThread = true
            } label: {
                let count = allComments.count
                Image(systemName: count > 0 ? "bubble.left.fill" : "bubble.left")
                    .foregroundStyle(blocks.contains { $0.hasUnresolvedComments } ? Color.orange : Color.secondary)
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShowingThread) {
                CommentThreadSheet(blocks: blocks, targetBlock: targetBlock, onChange: onChange)
            }
        }
    }
}

// MARK: - Footnotes

/// The per-segment footnote button, next to `SegmentCommentButton` — adds a
/// footnote anchored to this segment, or opens the ones it already has for
/// editing/removal.
private struct SegmentFootnoteButton: View {
    let block: DocumentBlock?
    let document: TextDocument
    let onChange: () -> Void
    @State private var isShowingSheet = false

    var body: some View {
        if let block {
            Button {
                isShowingSheet = true
            } label: {
                let count = (block.anchoredFootnotes ?? []).count
                Image(systemName: count > 0 ? "text.append" : "text.badge.plus")
                    .foregroundStyle(count > 0 ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("脚注")
            .sheet(isPresented: $isShowingSheet) {
                FootnoteEditSheet(block: block, document: document, onChange: onChange)
            }
        }
    }
}

/// Lists this block's own footnotes (if any) with their document-wide
/// number, and a field to add another.
private struct FootnoteEditSheet: View {
    @Bindable var block: DocumentBlock
    let document: TextDocument
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(block.anchoredFootnotes ?? []) { footnote in
                    HStack(alignment: .top) {
                        Text("\(document.footnoteNumber(for: footnote) ?? 0)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(footnote.text)
                    }
                    .swipeActions {
                        Button("削除", role: .destructive) {
                            block.anchoredFootnotes?.removeAll { $0 === footnote }
                            onChange()
                        }
                    }
                }
                Section {
                    TextField("脚注を追加", text: $draft, axis: .vertical)
                    Button("追加") {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        block.addFootnote(text: trimmed)
                        draft = ""
                        onChange()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("脚注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The end-of-document footnote list — every footnote in the document, in
/// order, each labeled with the same number `SegmentFootnoteButton`/
/// `FootnoteEditSheet` show next to its paragraph. Endnote-style placement,
/// not true per-page footnotes — see `DocumentFootnote`'s doc comment.
private struct FootnotesListView: View {
    @Bindable var document: TextDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(document.sortedFootnotes) { footnote in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(document.footnoteNumber(for: footnote) ?? 0).")
                        .foregroundStyle(.secondary)
                    Text(footnote.text)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Change history

/// Every edit made to this document, newest first — pending ones first, so
/// what needs a decision surfaces before settled history. Accepting just
/// records the decision (the text is already applied — see
/// `DocumentChangeRecord`'s doc comment on why this isn't held-back
/// real-time track changes yet); rejecting reverts the block's text back to
/// what it was before that edit.
private struct ChangeHistorySheet: View {
    @Bindable var document: TextDocument
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var sortedRecords: [DocumentChangeRecord] {
        (document.changeRecords ?? []).sorted { lhs, rhs in
            if lhs.status == .pending && rhs.status != .pending { return true }
            if lhs.status != .pending && rhs.status == .pending { return false }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedRecords) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.author).font(.subheadline.weight(.semibold))
                            statusBadge(record.status)
                            Spacer()
                            Text(record.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        if record.previousText != record.newText {
                            if !record.previousText.isEmpty {
                                Text(record.previousText)
                                    .font(.caption)
                                    .strikethrough()
                                    .foregroundStyle(.red)
                            }
                            Text(record.newText.isEmpty ? "(空にした)" : record.newText)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .swipeActions {
                        if record.status == .pending {
                            Button("承認") { accept(record) }.tint(.green)
                            Button("却下", role: .destructive) { reject(record) }
                        }
                    }
                }
            }
            .overlay {
                if sortedRecords.isEmpty {
                    ContentUnavailableView("変更履歴はまだありません", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("変更履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                if !document.pendingChangeRecords.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("すべて承認") {
                            for record in document.pendingChangeRecords { accept(record) }
                        }
                    }
                }
            }
            .alert("共同編集の反映に失敗しました", isPresented: Binding(get: { syncErrorMessage != nil }, set: { if !$0 { syncErrorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(syncErrorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    @State private var syncErrorMessage: String?

    /// Marks a record accepted locally, and — when it's tied to this
    /// document's collaboration room — asks the room's reviewer-only
    /// `review` endpoint to accept it there too. A caller without reviewer
    /// standing in the room gets a 403 back; the local status still flips
    /// (this device's own view of the record), but the room's canonical
    /// text won't move, so the failure is surfaced rather than hidden.
    private func accept(_ record: DocumentChangeRecord) {
        record.status = .accepted
        onChange()
        syncToRoomIfNeeded(record, decision: "accept")
    }

    private func reject(_ record: DocumentChangeRecord) {
        record.reject()
        onChange()
        syncToRoomIfNeeded(record, decision: "reject")
    }

    private func syncToRoomIfNeeded(_ record: DocumentChangeRecord, decision: String) {
        guard let roomID = document.collabRoomID, let changeID = record.collabChangeID else { return }
        Task {
            do {
                _ = try await DocumentCollabService.review(roomID: roomID, changeID: changeID, decision: decision)
            } catch {
                await MainActor.run { syncErrorMessage = "この端末はこの文書のレビュー権限がないか、通信に失敗しました。" }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: DocumentChangeStatus) -> some View {
        switch status {
        case .pending:
            Text("未承認").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        case .accepted:
            Text("承認済み").font(.caption2).foregroundStyle(.secondary)
        case .rejected:
            Text("却下済み").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Manages this document's collaboration room (see `DocumentCollabService`):
/// turning it on, inviting friends as editors/reviewers, and pulling in
/// change proposals other participants have made since this device last
/// checked.
///
/// Scope note: the room only ever knows about `.paragraph` blocks' plain
/// text, keyed by their `order` in `document.sortedBlocks`. Only text a
/// participant edits through the normal editor is proposed — inserting a
/// table, an image, or a new paragraph is a purely local, structural change
/// and never reaches the room. Every synced pending change appears in the
/// same "変更履歴" sheet as this device's own local edits, so there's one
/// place to review everything rather than two parallel review UIs.
private struct CollabSheet: View {
    @Bindable var document: TextDocument
    let onChange: () -> Void
    @EnvironmentObject private var friendStore: FriendStore
    @Environment(\.dismiss) private var dismiss

    @State private var isStarting = false
    @State private var isSyncing = false
    @State private var participants: [DocumentCollabService.Participant] = []
    @State private var selectedFriendCode = ""
    @State private var selectedRole = "editor"
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let roomID = document.collabRoomID {
                    activeRoomBody(roomID: roomID)
                } else {
                    startBody
                }
            }
            .navigationTitle("共同編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.medium, .large])
        .task {
            if document.collabRoomID != nil { await refreshParticipants() }
        }
    }

    private var startBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("友達を編集者やレビュアーとして招待し、内容の変更を提案・承認できるようにします。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await startCollaboration() }
            } label: {
                if isStarting { ProgressView() } else { Text("共同編集を開始") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
        }
        .padding()
    }

    @ViewBuilder
    private func activeRoomBody(roomID: String) -> some View {
        List {
            Section("参加者") {
                ForEach(participants) { participant in
                    HStack {
                        Text(participant.name ?? "招待中のメンバー")
                        Spacer()
                        Text(roleLabel(participant.role)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if participants.isEmpty {
                    Text("自分のみ参加中です").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("友達を招待") {
                if friendStore.friends.isEmpty {
                    Text("友達がまだいません。「友達」画面から追加してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("友達", selection: $selectedFriendCode) {
                        Text("選択してください").tag("")
                        ForEach(friendStore.friends) { friend in
                            Text(friend.name).tag(friend.code)
                        }
                    }
                    Picker("役割", selection: $selectedRole) {
                        Text("編集者(提案できる)").tag("editor")
                        Text("レビュアー(承認・却下できる)").tag("reviewer")
                    }
                    Button("招待する") { Task { await invite(roomID: roomID) } }
                        .disabled(selectedFriendCode.isEmpty)
                }
            }
            Section {
                Button {
                    Task { await syncPendingChanges(roomID: roomID) }
                } label: {
                    if isSyncing { ProgressView() } else { Label("変更を同期", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(isSyncing)
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "owner": return "作成者"
        case "editor": return "編集者"
        case "reviewer": return "レビュアー"
        default: return role
        }
    }

    private func startCollaboration() async {
        isStarting = true
        defer { isStarting = false }
        let roomID = DocumentCollabService.mintRoomID()
        let blocks = document.sortedBlocks.map { block -> DocumentCollabService.Block in
            DocumentCollabService.Block(
                order: block.order,
                kind: block.kindRawValue,
                text: block.kind == .paragraph ? DocumentBlockText.joinedText(of: [block]).string : "",
                listKind: block.listKindRawValue,
                listLevel: block.listLevel,
                paragraphStyle: block.paragraphStyleRawValue
            )
        }
        do {
            _ = try await DocumentCollabService.initialize(roomID: roomID, blocks: blocks)
            await MainActor.run {
                document.collabRoomID = roomID
                onChange()
            }
            await refreshParticipants()
        } catch {
            await MainActor.run { errorMessage = "共同編集の開始に失敗しました。通信環境を確認してください。" }
        }
    }

    private func refreshParticipants() async {
        guard let roomID = document.collabRoomID else { return }
        guard let result = try? await DocumentCollabService.participants(roomID: roomID) else { return }
        await MainActor.run { participants = result }
    }

    private func invite(roomID: String) async {
        guard !selectedFriendCode.isEmpty else { return }
        do {
            _ = try await DocumentCollabService.invite(roomID: roomID, code: selectedFriendCode, role: selectedRole)
            selectedFriendCode = ""
            await refreshParticipants()
        } catch {
            await MainActor.run { errorMessage = "招待に失敗しました。相手が友達登録されているか確認してください。" }
        }
    }

    /// Pulls the room's still-open proposals and mirrors any this device
    /// hasn't seen yet as local `DocumentChangeRecord`s, anchored to
    /// whichever local block currently sits at the same `order` — so they
    /// show up in "変更履歴" alongside this device's own pending edits. A
    /// proposal whose block order no longer matches any local block (a
    /// structural edit shifted things since it was proposed) is skipped
    /// rather than guessed at.
    private func syncPendingChanges(roomID: String) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let state = try await DocumentCollabService.state(roomID: roomID)
            let people = try? await DocumentCollabService.participants(roomID: roomID)
            if let people { await MainActor.run { participants = people } }

            var nameByKey: [String: String] = [:]
            for person in people ?? [] { if let name = person.name { nameByKey[person.userKey] = name } }
            var blocksByOrder: [Int: DocumentBlock] = [:]
            for block in document.sortedBlocks { blocksByOrder[block.order] = block }
            let existingIDs = Set((document.changeRecords ?? []).compactMap(\.collabChangeID))

            var addedCount = 0
            for change in state.pendingChanges where !existingIDs.contains(change.id) {
                guard let anchor = blocksByOrder[change.blockOrder] else { continue }
                let record = DocumentChangeRecord(
                    author: nameByKey[change.authorKey] ?? "共同編集メンバー",
                    kind: .edit, previousText: change.previousText, newText: change.newText, anchorBlock: anchor
                )
                record.collabChangeID = change.id
                record.document = document
                document.changeRecords = (document.changeRecords ?? []) + [record]
                addedCount += 1
            }
            await MainActor.run {
                if addedCount > 0 { onChange() }
                statusMessage = addedCount > 0 ? "\(addedCount)件の新しい変更提案を取り込みました。" : "新しい変更提案はありませんでした。"
            }
        } catch {
            await MainActor.run { errorMessage = "同期に失敗しました。通信環境を確認してください。" }
        }
    }
}
