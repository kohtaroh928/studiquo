import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// The slide editor: a thumbnail rail, a live slide canvas, an inspector for
/// layout/theme/notes, a full-screen presentation mode, and PDF export.
///
/// Slides are a real canvas (`SlideElementsLayer`) of freely positioned
/// `SlideElement`s — text boxes, images, shapes — each optionally linked to
/// a placeholder in the deck's `master` for "fix the layout once, every
/// slide using it updates" (design steps 2 and 4). Every slide's content
/// still starts out from `SlideBlockMigration`, which converts the app's
/// older fixed-placeholder fields the first time a deck is opened.
struct SlideDeckView: View {
    @Bindable var deck: SlideDeck
    var onHome: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @State private var selectedSlideID: PersistentIdentifier?
    @State private var selectedElementIDs: Set<ObjectIdentifier> = []
    @State private var isPresenting = false
    @State private var showsNotes = true
    @State private var showsThumbnailRail = true
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pdfDocument: PDFExportDocument?
    @State private var showsPDFExporter = false
    @State private var pptxDocument: PptxExportDocument?
    @State private var showsPptxExporter = false
    @State private var showsMasterEditor = false
    @State private var showsQuickPositionPicker = false
    /// Whether "drag on empty canvas to rubber-band-select multiple
    /// elements" is currently live — off by default, toggled from
    /// `canvasToolBar`. See `SlideElementsLayer.selectionDragGesture`'s doc
    /// comment for why this has to be an explicit mode rather than
    /// always-on: it's what actually lets the slide canvas scroll normally
    /// the rest of the time.
    @State private var isSelectingMultiple = false
    /// Design fix item 5's live rich-text editing state — which text
    /// element (if any) is currently being edited in place, its live
    /// cursor/selection, a revision counter bumped whenever the formatting
    /// bar rewrites the text externally, and the formatting the caret is
    /// currently sitting in (drives the bar's button states). See
    /// `SlideElementsLayer`'s matching properties.
    @State private var editingElementID: ObjectIdentifier?
    @State private var editSelectedRange = NSRange(location: 0, length: 0)
    @State private var editRevision = 0
    @State private var editFormatting = SelectionFormatting()

    private var slides: [Slide] { deck.sortedSlides }

    private var selectedSlide: Slide? {
        slides.first { $0.persistentModelID == selectedSlideID } ?? slides.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if showsThumbnailRail {
                    thumbnailRail
                    Divider()
                } else {
                    collapsedRailHandle
                    Divider()
                }
                editorArea
            }
        }
        .background(Color(.secondarySystemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if deck.sortedSlides.isEmpty { addSlide(layout: .titleSlide) }
            SlideBlockMigration.migrateIfNeeded(deck)
            if selectedSlideID == nil { selectedSlideID = slides.first?.persistentModelID }
        }
        .fullScreenCover(isPresented: $isPresenting) {
            SlidePresentationView(deck: deck, startAt: selectedSlide?.order ?? 0)
        }
        .sheet(isPresented: $showsMasterEditor) {
            if let master = deck.master {
                SlideMasterEditorView(master: master)
            }
        }
        .alert("スライド名を変更", isPresented: $isRenaming) {
            TextField("スライド名", text: $renameDraft)
            Button("キャンセル", role: .cancel) {}
            Button("変更") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { deck.title = trimmed; deck.updatedAt = .now }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await attachImage(from: item) }
        }
        .onChange(of: selectedSlideID) { _, _ in selectedElementIDs = [] }
        .onChange(of: selectedElementIDs) { _, newValue in
            // Ends the live text-edit session the instant selection moves
            // away from that element — tapping the background, tapping a
            // different element, deleting the selection, all funnel
            // through here rather than each needing their own explicit
            // "stop editing" call.
            if let editingElementID, !newValue.contains(editingElementID) {
                self.editingElementID = nil
            }
        }
        .modifier(PDFSaveModifier(
            isPresented: $showsPDFExporter,
            document: $pdfDocument,
            filename: "\(deck.title).pdf"
        ))
        .modifier(PptxSaveModifier(
            isPresented: $showsPptxExporter,
            document: $pptxDocument,
            filename: "\(deck.title).pptx"
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
                renameDraft = deck.title
                isRenaming = true
            } label: {
                Label(deck.title, systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(slides.count) 枚")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Picker("テーマ", selection: Binding(
                    get: { deck.theme },
                    set: { deck.theme = $0; deck.updatedAt = .now }
                )) {
                    ForEach(SlideTheme.allCases) { Text($0.title).tag($0) }
                }
                Picker("画面比率", selection: Binding(
                    get: { deck.aspect },
                    set: { deck.aspect = $0; deck.updatedAt = .now }
                )) {
                    ForEach(SlideAspect.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle("発表者ノートを表示", isOn: $showsNotes)
                Button("PDFで書き出す", systemImage: "square.and.arrow.down", action: exportPDF)
                Button("PowerPointで書き出す(.pptx)", systemImage: "square.and.arrow.down", action: exportPptx)
                Divider()
                Button("マスタースライドを編集", systemImage: "rectangle.3.group") {
                    if deck.master == nil { deck.master = SlideMaster.makeDefault() }
                    showsMasterEditor = true
                }
            } label: {
                Image(systemName: "paintbrush")
            }

            Button {
                isPresenting = true
            } label: {
                Label("再生", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(slides.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private var thumbnailRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text("スライド")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsThumbnailRail = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("スライド一覧を閉じる")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(slides.enumerated()), id: \.element.persistentModelID) { index, slide in
                        Button {
                            selectedSlideID = slide.persistentModelID
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                SlideElementsLayer(
                                    slide: slide, slideSize: CGSize(width: 132, height: 132 / deck.aspect.ratio),
                                    isEditable: false, onChange: {}
                                )
                                    .frame(width: 132, height: 132 / deck.aspect.ratio)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(
                                                slide.persistentModelID == selectedSlide?.persistentModelID
                                                    ? Color.accentColor : Color.black.opacity(0.15),
                                                lineWidth: slide.persistentModelID == selectedSlide?.persistentModelID ? 2.5 : 1
                                            )
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("複製", systemImage: "plus.square.on.square") { duplicate(slide) }
                            Button("上へ移動", systemImage: "arrow.up") { move(slide, by: -1) }
                            Button("下へ移動", systemImage: "arrow.down") { move(slide, by: 1) }
                            Divider()
                            Button("削除", systemImage: "trash", role: .destructive) { delete(slide) }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            Menu {
                ForEach(SlideLayout.allCases) { layout in
                    Button {
                        addSlide(layout: layout)
                    } label: {
                        Label(layout.title, systemImage: layout.icon)
                    }
                }
            } label: {
                Label("スライドを追加", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
        }
        .frame(width: 186)
        .background(Color(.systemBackground))
    }

    /// Shown instead of `thumbnailRail` while it's collapsed — a thin
    /// always-visible strip so there's still an obvious way to bring it
    /// back.
    private var collapsedRailHandle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsThumbnailRail = true }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .background(Color(.systemBackground))
        .accessibilityLabel("スライド一覧を開く")
    }

    @ViewBuilder
    private var editorArea: some View {
        if let slide = selectedSlide {
            VStack(spacing: 0) {
                layoutBar(for: slide)
                Divider()
                if editingElementID != nil {
                    textFormattingBar
                } else {
                    canvasToolBar(for: slide)
                }
                Divider()

                ContinuousSlidesView(
                    deck: deck,
                    isSelectionModeActive: isSelectingMultiple,
                    selectedSlideID: $selectedSlideID,
                    selectedElementIDs: $selectedElementIDs,
                    editingElementID: editingElementID,
                    editSelectedRange: $editSelectedRange,
                    editRevision: editRevision,
                    onBeginEditingText: { beginEditingText($0) },
                    onFormattingChange: { editFormatting = $0 },
                    onChange: { deck.updatedAt = .now },
                    onInsertSlideAtTop: insertSlideAtTop,
                    onInsertSlideAtBottom: insertSlideAtBottom
                )

                Divider()
                if showsNotes {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("発表者ノート")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { showsNotes = false }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("発表者ノートを閉じる")
                        }
                        TextEditor(text: Binding(
                            get: { slide.notes },
                            set: { slide.notes = $0; deck.updatedAt = .now }
                        ))
                        .font(.subheadline)
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showsNotes = true }
                    } label: {
                        HStack {
                            Text("発表者ノート")
                            Spacer()
                            Image(systemName: "chevron.up")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color(.systemBackground))
                    .accessibilityLabel("発表者ノートを開く")
                }
            }
        } else {
            ContentUnavailableView(
                "スライドがありません",
                systemImage: "rectangle.on.rectangle",
                description: Text("左下の「スライドを追加」から作成してください")
            )
        }
    }

    private func layoutBar(for slide: Slide) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(SlideLayout.allCases) { layout in
                    Button {
                        // The legacy field is kept in sync purely for this
                        // button's own display (below) and as a fallback —
                        // `changeLayout(to:)` is what actually re-links this
                        // slide's `SlideElement`s (role-matched, so existing
                        // content survives the switch — design step 5).
                        slide.legacyLayout = layout
                        if let newTemplate = deck.master?.sortedLayouts.first(where: { $0.name == layout.title }) {
                            slide.changeLayout(to: newTemplate)
                        }
                        deck.updatedAt = .now
                    } label: {
                        Label(layout.title, systemImage: layout.icon)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: slide.legacyLayout.icon)
                    Text(slide.legacyLayout.title).font(.subheadline)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }

            Divider().frame(height: 20)

            Menu {
                ForEach(DocumentFontFamily.allCases) { family in
                    Button(family.title) {
                        deck.fontFamily = family
                        deck.updatedAt = .now
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(deck.fontFamily.title).font(.subheadline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: 150)
            }

            Button { changeTextScale(by: -0.1) } label: { Image(systemName: "textformat.size.smaller") }
            Text("\(Int(deck.textScale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
            Button { changeTextScale(by: 0.1) } label: { Image(systemName: "textformat.size.larger") }

            Toggle(isOn: Binding(
                get: { deck.titleIsBold },
                set: { deck.titleIsBold = $0; deck.updatedAt = .now }
            )) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)

            Toggle(isOn: Binding(
                get: { deck.bodyIsItalic },
                set: { deck.bodyIsItalic = $0; deck.updatedAt = .now }
            )) {
                Image(systemName: "italic")
            }
            .toggleStyle(.button)

            Divider().frame(height: 20)

            Menu {
                ForEach(SlideTransitionKind.allCases) { kind in
                    Button {
                        slide.transition = kind
                        deck.updatedAt = .now
                    } label: {
                        Label(kind.title, systemImage: slide.transition == kind ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Label("切り替え: \(slide.transition.title)", systemImage: "rectangle.stack.badge.play")
                    .font(.subheadline)
            }

            Divider().frame(height: 20)

            if slide.legacyLayout.hasImage {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(slide.element(for: .image) == nil ? "画像を選ぶ" : "画像を変更", systemImage: "photo")
                        .font(.subheadline)
                }
                if slide.element(for: .image) != nil {
                    Button("画像を削除", role: .destructive) {
                        slide.imageData = nil
                        if let element = slide.element(for: .image) {
                            slide.elements?.removeAll { $0 === element }
                        }
                        deck.updatedAt = .now
                    }
                    .font(.subheadline)
                }
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.bar)
    }

    private func changeTextScale(by delta: Double) {
        deck.textScale = min(max(deck.textScale + delta, 0.6), 1.8)
        deck.updatedAt = .now
    }

    /// Add-element buttons (always available) plus, once something's
    /// selected, the multi-selection actions — align/distribute (2+),
    /// group (2+), ungroup (a sole selected group), delete (1+). Design
    /// step 4's "remaining piece": a real add-element toolbar and a
    /// PowerPoint-style selection action bar instead of only the
    /// per-element context menu.
    private func canvasToolBar(for slide: Slide) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("テキストボックス", systemImage: "textformat") { addElement(.text, to: slide) }
                Button("四角形", systemImage: "rectangle") { addElement(.rectangle, to: slide) }
                Button("楕円", systemImage: "circle") { addElement(.ellipse, to: slide) }
                Button("線", systemImage: "line.diagonal") { addElement(.line, to: slide) }
            } label: {
                Label("要素を追加", systemImage: "plus.square.on.square").font(.subheadline)
            }

            Divider().frame(height: 20)

            // Rubber-band multi-select only exists on the canvas while this
            // is on (see `SlideElementsLayer.selectionDragGesture`'s doc
            // comment) — the same "explicit tool, not an always-on
            // gesture" shape the notebook feature's own lasso selection
            // tool uses, so ordinary scrolling never has anything to
            // contend with the rest of the time.
            Toggle(isOn: $isSelectingMultiple) {
                Label("複数選択", systemImage: "lasso")
            }
            .toggleStyle(.button)
            .tint(isSelectingMultiple ? Color.accentColor : nil)

            if selectedElementIDs.count >= 2 {
                Divider().frame(height: 20)

                Menu {
                    Button("左揃え", systemImage: "align.horizontal.left") { align(slide, .left) }
                    Button("中央揃え(横)", systemImage: "align.horizontal.center") { align(slide, .centerHorizontal) }
                    Button("右揃え", systemImage: "align.horizontal.right") { align(slide, .right) }
                    Divider()
                    Button("上揃え", systemImage: "align.vertical.top") { align(slide, .top) }
                    Button("中央揃え(縦)", systemImage: "align.vertical.center") { align(slide, .centerVertical) }
                    Button("下揃え", systemImage: "align.vertical.bottom") { align(slide, .bottom) }
                    if selectedElementIDs.count >= 3 {
                        Divider()
                        Button("左右に整列", systemImage: "square.split.3x1") { distributeHorizontally(slide) }
                        Button("上下に整列", systemImage: "square.split.1x3") { distributeVertically(slide) }
                    }
                } label: {
                    Label("整列", systemImage: "align.horizontal.left").font(.subheadline)
                }

                Button { groupSelection(slide) } label: {
                    Label("グループ化", systemImage: "square.on.square").font(.subheadline)
                }
            }

            if selectedElementIDs.count == 1, let sole = selectedElements(slide).first {
                Button { showsQuickPositionPicker = true } label: {
                    Label("位置", systemImage: "square.grid.3x3").font(.subheadline)
                }
                .popover(isPresented: $showsQuickPositionPicker) {
                    QuickPositionPicker { position in
                        applyQuickPosition(position, to: sole)
                        showsQuickPositionPicker = false
                    }
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
                }

                if sole.kind == .group {
                    Button { ungroupSelection(slide, group: sole) } label: {
                        Label("グループ解除", systemImage: "square.slash").font(.subheadline)
                    }
                }
            }

            if !selectedElementIDs.isEmpty {
                Button(role: .destructive) { deleteSelection(slide) } label: {
                    Label("削除", systemImage: "trash").font(.subheadline)
                }
            }

            Spacer()

            if !selectedElementIDs.isEmpty {
                Text("\(selectedElementIDs.count)個選択中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color(.systemBackground))
    }

    /// Replaces `canvasToolBar` while a text box is being live-edited
    /// (design fix item 5) — font size, bold/italic/underline, paragraph
    /// alignment, and font family, all applied to the current selection
    /// within that one box. A deliberately narrower set than the document
    /// editor's own bar (no highlight color, line spacing, links, table/
    /// equation insertion, …) — a slide text box doesn't need those, and
    /// this bar only ever edits one box at a time, never a whole document.
    private var textFormattingBar: some View {
        HStack(spacing: 10) {
            Button { changeEditingFontSize(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
            Text("\(Int(editFormatting.fontSize))").font(.caption.monospacedDigit()).frame(width: 28)
            Button { changeEditingFontSize(by: 1) } label: { Image(systemName: "textformat.size.larger") }

            Divider().frame(height: 20)

            Toggle(isOn: Binding(get: { editFormatting.isBold }, set: { _ in toggleEditingTrait(.traitBold) })) {
                Image(systemName: "bold")
            }.toggleStyle(.button)
            Toggle(isOn: Binding(get: { editFormatting.isItalic }, set: { _ in toggleEditingTrait(.traitItalic) })) {
                Image(systemName: "italic")
            }.toggleStyle(.button)
            Toggle(isOn: Binding(get: { editFormatting.isUnderlined }, set: { _ in toggleEditingUnderline() })) {
                Image(systemName: "underline")
            }.toggleStyle(.button)

            Divider().frame(height: 20)

            Button { applyEditingAlignment(.left) } label: { Image(systemName: "text.alignleft") }
            Button { applyEditingAlignment(.center) } label: { Image(systemName: "text.aligncenter") }
            Button { applyEditingAlignment(.right) } label: { Image(systemName: "text.alignright") }

            Divider().frame(height: 20)

            Menu {
                ForEach(DocumentFontFamily.allCases) { family in
                    Button(family.title) { applyEditingFontFamily(family) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(editFormatting.familyName).font(.caption).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: 130)
            }

            Spacer()

            Button("完了") { editingElementID = nil }
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color(.systemBackground))
    }

    private enum AlignKind { case left, centerHorizontal, right, top, centerVertical, bottom }

    private func selectedElements(_ slide: Slide) -> [SlideElement] {
        slide.sortedElements.filter { selectedElementIDs.contains($0.stableID) }
    }

    private func addElement(_ kind: SlideElementKind, to slide: Slide) {
        let element = SlideElement(kind: kind, layerIndex: Double(slide.sortedElements.count))
        element.overrideCenterX = 0.5
        element.overrideCenterY = 0.5
        switch kind {
        case .text:
            element.overrideWidth = 0.5
            element.overrideHeight = 0.15
            element.body = NSAttributedString(string: "テキスト", attributes: element.defaultTextAttributes())
        case .line:
            element.overrideWidth = 0.4
            element.overrideHeight = 0.02
        default:
            element.overrideWidth = 0.3
            element.overrideHeight = 0.3
        }
        slide.addElement(element)
        deck.updatedAt = .now
        selectedElementIDs = [element.stableID]
        try? modelContext.save()
    }

    private func align(_ slide: Slide, _ kind: AlignKind) {
        let elements = selectedElements(slide)
        guard elements.count >= 2 else { return }
        for element in elements { element.bakeInGeometryIfNeeded() }
        let frames = elements.map {
            CanvasElementGeometry.Frame(centerX: $0.centerX, centerY: $0.centerY, width: $0.width, height: $0.height)
        }
        switch kind {
        case .left, .centerHorizontal, .right:
            let alignment: CanvasElementGeometry.HorizontalAlignment = switch kind {
            case .left: .left
            case .right: .right
            default: .center
            }
            let results = CanvasElementGeometry.aligned(frames, horizontally: alignment)
            for (element, value) in zip(elements, results) { element.overrideCenterX = value }
        case .top, .centerVertical, .bottom:
            let alignment: CanvasElementGeometry.VerticalAlignment = switch kind {
            case .top: .top
            case .bottom: .bottom
            default: .center
            }
            let results = CanvasElementGeometry.aligned(frames, vertically: alignment)
            for (element, value) in zip(elements, results) { element.overrideCenterY = value }
        }
        deck.updatedAt = .now
        try? modelContext.save()
    }

    private func distributeHorizontally(_ slide: Slide) {
        let elements = selectedElements(slide)
        guard elements.count >= 3 else { return }
        for element in elements { element.bakeInGeometryIfNeeded() }
        let frames = elements.map {
            CanvasElementGeometry.Frame(centerX: $0.centerX, centerY: $0.centerY, width: $0.width, height: $0.height)
        }
        let results = CanvasElementGeometry.distributedHorizontally(frames)
        for (element, value) in zip(elements, results) { element.overrideCenterX = value }
        deck.updatedAt = .now
        try? modelContext.save()
    }

    private func distributeVertically(_ slide: Slide) {
        let elements = selectedElements(slide)
        guard elements.count >= 3 else { return }
        for element in elements { element.bakeInGeometryIfNeeded() }
        let frames = elements.map {
            CanvasElementGeometry.Frame(centerX: $0.centerX, centerY: $0.centerY, width: $0.width, height: $0.height)
        }
        let results = CanvasElementGeometry.distributedVertically(frames)
        for (element, value) in zip(elements, results) { element.overrideCenterY = value }
        deck.updatedAt = .now
        try? modelContext.save()
    }

    private func groupSelection(_ slide: Slide) {
        let elements = selectedElements(slide)
        guard let group = slide.group(elements) else { return }
        deck.updatedAt = .now
        selectedElementIDs = [group.stableID]
        try? modelContext.save()
    }

    private func ungroupSelection(_ slide: Slide, group: SlideElement) {
        slide.ungroup(group)
        deck.updatedAt = .now
        selectedElementIDs = []
        try? modelContext.save()
    }

    private func applyQuickPosition(_ position: CanvasElementGeometry.QuickPosition, to element: SlideElement) {
        element.bakeInGeometryIfNeeded()
        let frame = CanvasElementGeometry.Frame(centerX: element.centerX, centerY: element.centerY, width: element.width, height: element.height)
        let result = CanvasElementGeometry.quickPosition(position, for: frame)
        element.overrideCenterX = result.centerX
        element.overrideCenterY = result.centerY
        deck.updatedAt = .now
        try? modelContext.save()
    }

    // MARK: Live rich-text editing (design fix item 5)

    private func beginEditingText(_ element: SlideElement) {
        editingElementID = element.stableID
        editSelectedRange = NSRange(location: element.body.length, length: 0)
        editFormatting = SelectionFormatting(attributes: element.defaultTextAttributes())
    }

    private var editingElement: SlideElement? {
        guard let editingElementID, let slide = selectedSlide else { return nil }
        return slide.sortedElements.first { $0.stableID == editingElementID }
    }

    /// The same shape as the document editor's own `mutate(_:)`: build a
    /// mutable copy of the element being edited, hand it (and the current
    /// selection, clamped to its length) to `body`, then write the result
    /// back and bump `editRevision` so `RichTextEditor` picks the rewrite
    /// up. No-ops when nothing is actually selected — unlike the document
    /// editor, this doesn't also reach for the "composed character
    /// sequence around the caret" when the selection is empty; a simpler,
    /// deliberately narrower rule for a text box this small.
    private func mutateEditingText(_ body: (NSMutableAttributedString, NSRange) -> Void) {
        guard let element = editingElement else { return }
        let mutable = NSMutableAttributedString(attributedString: element.body)
        var range = editSelectedRange
        range.location = min(range.location, mutable.length)
        range.length = min(range.length, mutable.length - range.location)
        guard range.length > 0 else { return }
        body(mutable, range)
        element.body = mutable
        editRevision += 1
        deck.updatedAt = .now
        try? modelContext.save()
    }

    private func toggleEditingTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        mutateEditingText { text, range in SlideTextFormatting.toggleTrait(trait, in: text, range: range) }
    }

    private func toggleEditingUnderline() {
        let turnOn = !editFormatting.isUnderlined
        mutateEditingText { text, range in SlideTextFormatting.setUnderline(turnOn, in: text, range: range) }
    }

    private func changeEditingFontSize(by delta: CGFloat) {
        mutateEditingText { text, range in SlideTextFormatting.changeFontSize(by: delta, in: text, range: range) }
    }

    private func applyEditingAlignment(_ alignment: NSTextAlignment) {
        mutateEditingText { text, range in SlideTextFormatting.applyAlignment(alignment, in: text, range: range) }
    }

    private func applyEditingFontFamily(_ family: DocumentFontFamily) {
        mutateEditingText { text, range in SlideTextFormatting.applyFontFamily(family, in: text, range: range) }
    }

    private func deleteSelection(_ slide: Slide) {
        for element in selectedElements(slide) {
            slide.elements?.removeAll { $0 === element }
        }
        deck.updatedAt = .now
        selectedElementIDs = []
        try? modelContext.save()
    }

    // MARK: Slide operations

    private func addSlide(layout: SlideLayout) {
        let slide = Slide(order: deck.sortedSlides.count, layout: layout)
        slide.deck = deck
        deck.addSlide(slide)
        deck.renumberSlides()
        deck.updatedAt = .now
        modelContext.insert(slide)
        // `migrateIfNeeded` is safe (and cheap) to call again here — its
        // per-slide `slide.layout == nil` check means it only ever touches
        // this brand-new slide, not the rest of the deck. Without this, a
        // freshly added slide would render as an empty canvas (no `layout`/
        // `elements` yet) until the view happened to reappear and its
        // `.onAppear` ran migration again.
        SlideBlockMigration.migrateIfNeeded(deck)
        try? modelContext.save()
        selectedSlideID = slide.persistentModelID
    }

    private func duplicate(_ slide: Slide) {
        let copy = Slide(order: slide.order + 1, layout: slide.legacyLayout)
        copy.titleText = slide.titleText
        copy.bodyText = slide.bodyText
        copy.secondaryText = slide.secondaryText
        copy.notes = slide.notes
        copy.imageData = slide.imageData
        copy.deck = deck
        for later in deck.sortedSlides where later.order > slide.order { later.order += 1 }
        deck.addSlide(copy)
        deck.renumberSlides()
        deck.updatedAt = .now
        modelContext.insert(copy)
        SlideBlockMigration.migrateIfNeeded(deck) // see addSlide's comment
        try? modelContext.save()
        selectedSlideID = copy.persistentModelID
    }

    /// A blank new slide right before/after `reference`, and switches to
    /// it — what pulling past the top/bottom edge of the main canvas
    /// triggers (the "pull to add a page" gesture, matching the one
    /// notebooks already have).
    private func insertSlide(adjacentTo reference: Slide, before: Bool) {
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.deck = deck
        deck.insertSlide(slide, adjacentTo: reference, before: before)
        deck.updatedAt = .now
        modelContext.insert(slide)
        SlideBlockMigration.migrateIfNeeded(deck) // see addSlide's comment
        try? modelContext.save()
        selectedSlideID = slide.persistentModelID
    }

    /// The vertical-swipe half of "scroll between slides" (matching the
    /// notebook feature's own gesture): moves to the previous/next slide
    /// when one exists, or — swiping past the very first/last slide —
    /// inserts a new blank one there instead, the same as pulling on the
    /// dedicated strip above/below the canvas does.
    /// Pulling past the very top/bottom of the continuous slide canvas —
    /// design fix "make it really scroll like notes": inserts before the
    /// first slide, or after the last, or (an empty deck) just makes a
    /// first one.
    private func insertSlideAtTop() {
        if let first = slides.first {
            insertSlide(adjacentTo: first, before: true)
        } else {
            addSlide(layout: .titleSlide)
        }
    }

    private func insertSlideAtBottom() {
        if let last = slides.last {
            insertSlide(adjacentTo: last, before: false)
        } else {
            addSlide(layout: .titleSlide)
        }
    }

    private func delete(_ slide: Slide) {
        let removedOrder = slide.order
        deck.slides?.removeAll { $0.persistentModelID == slide.persistentModelID }
        slide.deck = nil
        modelContext.delete(slide)
        deck.renumberSlides()
        deck.updatedAt = .now
        try? modelContext.save()
        let remaining = deck.sortedSlides
        selectedSlideID = remaining.indices.contains(removedOrder)
            ? remaining[removedOrder].persistentModelID
            : remaining.last?.persistentModelID
    }

    private func move(_ slide: Slide, by offset: Int) {
        let ordered = deck.sortedSlides
        guard let index = ordered.firstIndex(where: { $0.persistentModelID == slide.persistentModelID }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        var rearranged = ordered
        rearranged.swapAt(index, target)
        for (position, item) in rearranged.enumerated() { item.order = position }
        deck.updatedAt = .now
        try? modelContext.save()
    }

    private func attachImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await MainActor.run {
            guard let slide = selectedSlide else { return }
            slide.imageData = data // legacy fallback field, kept in sync
            if let existing = slide.element(for: .image) {
                existing.imageData = data
            } else if let placeholder = slide.layout?.placeholder(for: .image) {
                let element = SlideElement(kind: .image, layerIndex: Double(slide.sortedElements.count))
                element.sourcePlaceholder = placeholder
                element.imageData = data
                slide.addElement(element)
            } else {
                // This slide's layout has no image placeholder to link to —
                // add a free-floating element instead, roughly centered.
                // There's no add-element toolbar yet (design step 4's
                // remaining work) to place it more deliberately.
                let element = SlideElement(kind: .image, layerIndex: Double(slide.sortedElements.count))
                element.overrideCenterX = 0.5; element.overrideCenterY = 0.6
                element.overrideWidth = 0.6; element.overrideHeight = 0.5
                element.imageData = data
                slide.addElement(element)
            }
            deck.updatedAt = .now
            photoItem = nil
            try? modelContext.save()
        }
    }

    // MARK: Export

    private func exportPDF() {
        guard let data = ExportService.pdfData(from: deck) else { return }
        pdfDocument = PDFExportDocument(data: data)
        showsPDFExporter = true
    }

    private func exportPptx() {
        guard let data = PptxWriter.makeData(from: deck) else { return }
        pptxDocument = PptxExportDocument(data: data)
        showsPptxExporter = true
    }
}

/// A 3×3 grid of the nine standard slide positions (design fix item 7) —
/// top/middle/bottom × left/center/right, matching PowerPoint's own quick
/// "position on slide" picker. Tapping a cell calls `onSelect` with that
/// `CanvasElementGeometry.QuickPosition`; the caller applies it and closes
/// the popover.
/// The slide editor's main canvas — design fix "make it really scroll like
/// notes": every slide shown as one continuous, fully-interactive vertical
/// scroll (each one directly draggable/editable, no separate "select this
/// slide first" step — the same way a notebook page can be drawn on
/// without tapping to activate it first), with a pull-past-the-edge gauge
/// at the very top/bottom to insert a new blank slide there. A direct port
/// of the notebook feature's own `ContinuousPagesView`
/// (`Views/NoteEditorView.swift`) built on the shared primitives in
/// `Services/ContinuousScrollPullToAdd.swift` — see that file's doc
/// comment for what's reused as-is and what's deliberately simplified.
private struct ContinuousSlidesView: View {
    @Bindable var deck: SlideDeck
    var isSelectionModeActive: Bool
    @Binding var selectedSlideID: PersistentIdentifier?
    @Binding var selectedElementIDs: Set<ObjectIdentifier>
    var editingElementID: ObjectIdentifier?
    @Binding var editSelectedRange: NSRange
    var editRevision: Int
    let onBeginEditingText: (SlideElement) -> Void
    let onFormattingChange: (SelectionFormatting) -> Void
    let onChange: () -> Void
    let onInsertSlideAtTop: () -> Void
    let onInsertSlideAtBottom: () -> Void

    @State private var scrollTarget: PersistentIdentifier?
    @State private var topPullProgress: CGFloat = 0
    @State private var bottomPullProgress: CGFloat = 0
    @State private var topHoldTracker = PullHoldTracker()
    @State private var bottomHoldTracker = PullHoldTracker()

    // Both numbers deliberately identical to the notebook feature's own
    // `ContinuousPagesView` — see `PullHoldTracker`'s doc comment.
    private static let pullThreshold: CGFloat = 150
    private static let pullHoldDuration: TimeInterval = 0.2
    private static let contentPadding: CGFloat = 18
    private static let coordinateSpaceName = "studiquoContinuousSlidesScroll"

    /// Shared by `ScrollOverscrollObserver`'s KVO reading and
    /// `PullEdgeGeometryReader`'s layout-driven one — see
    /// `PullEdgeGeometryReader`'s doc comment for why both feed the same
    /// tracker instead of picking one source.
    private func updateTopPull(overscroll: CGFloat) {
        let progress = min(overscroll / Self.pullThreshold, 1)
        topPullProgress = progress
        if topHoldTracker.update(progress: progress, holdDuration: Self.pullHoldDuration) {
            onInsertSlideAtTop()
        }
    }

    private func updateBottomPull(overscroll: CGFloat) {
        let progress = min(overscroll / Self.pullThreshold, 1)
        bottomPullProgress = progress
        if bottomHoldTracker.update(progress: progress, holdDuration: Self.pullHoldDuration) {
            onInsertSlideAtBottom()
        }
    }

    var body: some View {
        let slides = deck.sortedSlides
        GeometryReader { geometry in
            let availableWidth = max(240, geometry.size.width - 32)
            // Every slide fitted to the same size, the smaller of "as wide
            // as the pane allows" or "as tall as the pane allows, at this
            // deck's aspect ratio" — mirrors how the notebook feature fits
            // each of its own (possibly differently-sized) pages.
            let width = min(availableWidth, max(160, geometry.size.height - 48) * deck.aspect.ratio)
            let displaySize = CGSize(width: width, height: width / deck.aspect.ratio)

            ScrollView(.vertical) {
                LazyVStack(spacing: 18) {
                    PullToAddGauge(
                        progress: topPullProgress,
                        label: "さらに引っ張ってスライドを追加", armedLabel: "指を離してスライドを追加"
                    )
                    .background(
                        ZStack {
                            ScrollOverscrollObserver(edge: .top) { updateTopPull(overscroll: $0) }
                            PullEdgeGeometryReader(edge: .top, spaceName: Self.coordinateSpaceName)
                        }
                    )

                    ForEach(slides, id: \.persistentModelID) { slide in
                        SlideElementsLayer(
                            slide: slide, slideSize: displaySize,
                            isSelectionModeActive: isSelectionModeActive,
                            selectedElementIDs: $selectedElementIDs,
                            editingElementID: editingElementID,
                            editSelectedRange: $editSelectedRange,
                            editRevision: editRevision,
                            onBeginEditingText: onBeginEditingText,
                            onFormattingChange: onFormattingChange,
                            onChange: onChange
                        )
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        .id(slide.persistentModelID)
                    }

                    PullToAddGauge(
                        progress: bottomPullProgress,
                        label: "さらに引っ張ってスライドを追加", armedLabel: "指を離してスライドを追加"
                    )
                    .background(
                        ZStack {
                            ScrollOverscrollObserver(edge: .bottom) { updateBottomPull(overscroll: $0) }
                            PullEdgeGeometryReader(edge: .bottom, spaceName: Self.coordinateSpaceName)
                        }
                    )
                }
                .scrollTargetLayout()
                .padding(.vertical, Self.contentPadding)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
            .onPreferenceChange(PullTopMinYPreferenceKey.self) { minY in
                guard minY.isFinite else { return }
                updateTopPull(overscroll: max(0, minY - Self.contentPadding))
            }
            .onPreferenceChange(PullBottomMaxYPreferenceKey.self) { maxY in
                guard maxY.isFinite else { return }
                let restingMaxY = geometry.size.height - Self.contentPadding
                updateBottomPull(overscroll: max(0, restingMaxY - maxY))
            }
            .scrollPosition(id: $scrollTarget, anchor: .center)
            .onAppear {
                if scrollTarget == nil { scrollTarget = selectedSlideID ?? slides.first?.persistentModelID }
            }
            // Scroll → selection: whichever slide ends up nearest the
            // anchor becomes "current," the same way `currentPageIndex`
            // tracks scroll position in the notebook feature.
            .onChange(of: scrollTarget) { _, target in
                guard let target, target != selectedSlideID else { return }
                selectedSlideID = target
            }
            // Selection → scroll: picking a slide from the thumbnail rail
            // still scrolls this view to it.
            .onChange(of: selectedSlideID) { _, target in
                guard let target, target != scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.25)) { scrollTarget = target }
            }
        }
    }
}

private struct QuickPositionPicker: View {
    let onSelect: (CanvasElementGeometry.QuickPosition) -> Void

    private static let rows: [[CanvasElementGeometry.QuickPosition]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, .center, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 4) {
            Text("位置を選択").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { position in
                            Button { onSelect(position) } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
                                    .frame(width: 36, height: 24)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct PptxExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "pptx") ?? .data]
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

struct PptxSaveModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var document: PptxExportDocument?
    let filename: String

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: $isPresented,
            document: document,
            contentType: UTType(filenameExtension: "pptx") ?? .data,
            defaultFilename: filename
        ) { _ in
            document = nil
        }
    }
}

// MARK: - Presentation

/// Letterboxes a single slide (or nothing, if `slide` is `nil`) into
/// whatever space it's given, preserving `aspect`'s ratio — the one
/// GeometryReader+`SlideElementsLayer` pattern shared by the audience
/// view, the presenter view's two previews, and the external-display
/// mirror, so there's exactly one place that math lives.
private struct SlideStage: View {
    let slide: Slide?
    let aspect: SlideAspect
    var revealedElementIDs: Set<ObjectIdentifier>? = nil

    var body: some View {
        GeometryReader { geometry in
            if let slide {
                let width = min(geometry.size.width, geometry.size.height * aspect.ratio)
                let displaySize = CGSize(width: width, height: width / aspect.ratio)
                SlideElementsLayer(
                    slide: slide, slideSize: displaySize, isEditable: false,
                    revealedElementIDs: revealedElementIDs, onChange: {}
                )
                    .frame(width: displaySize.width, height: displaySize.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}

/// Pure `mm:ss` formatting for the presenter view's elapsed-time clock,
/// split out so it's unit-testable without needing a live `Timer`.
enum PresentationElapsedTime {
    static func formatted(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Full-screen playback. Tap or swipe (or use the arrow keys on a hardware
/// keyboard) to advance; the slide number and speaker notes stay available
/// without being part of the slide itself. When a second screen connects
/// (design step 7), switches to a presenter layout on-device while the
/// audience-facing slide alone goes to that screen — see
/// `ExternalDisplayController`.
private struct SlidePresentationView: View {
    @Bindable var deck: SlideDeck
    let startAt: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showsNotes = false
    /// Which of the current slide's animated elements have been revealed
    /// so far, and how many click-steps that represents — see
    /// `Slide.animationSteps`'s doc comment. Reset on every slide change.
    @State private var revealedElementIDs: Set<ObjectIdentifier> = []
    @State private var revealStepIndex = 0
    /// The direction of the last slide-to-slide navigation, so a "push"
    /// transition slides in from the correct edge in either direction.
    @State private var lastSlideStep = 1
    @State private var startedAt = Date.now
    /// Design step 7's presenter mode: while a second screen is connected
    /// (cable or AirPlay), the audience-facing slide goes there alone and
    /// this device switches to `presenterLayout` instead of `audienceLayout`.
    @StateObject private var externalDisplay = ExternalDisplayController()

    private var slides: [Slide] { deck.sortedSlides }

    var body: some View {
        Group {
            if externalDisplay.isConnected {
                presenterLayout
            } else {
                audienceLayout
            }
        }
        .onAppear {
            index = min(max(startAt, 0), max(0, slides.count - 1))
            if slides.indices.contains(index) { resetReveal(for: slides[index]) }
            startedAt = .now
            updateExternalDisplay()
        }
        .onChange(of: index) { _, _ in updateExternalDisplay() }
        .onChange(of: revealedElementIDs) { _, _ in updateExternalDisplay() }
        .onDisappear { externalDisplay.hide() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// The original single-slide, tap-through view — unchanged behavior,
    /// still what's shown on the device itself whenever no external screen
    /// is connected (the overwhelmingly common case).
    private var audienceLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if slides.indices.contains(index) {
                SlideStage(slide: slides[index], aspect: deck.aspect, revealedElementIDs: revealedElementIDs)
                    .id(slides[index].persistentModelID)
                    .transition(transitionStyle(for: slides[index]))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if !(slides.indices.contains(index) && slides[index].notes.isEmpty) {
                        Button { showsNotes.toggle() } label: {
                            Image(systemName: showsNotes ? "note.text.badge.plus" : "note.text")
                                .font(.headline)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .padding()

                Spacer()

                if showsNotes, slides.indices.contains(index), !slides[index].notes.isEmpty {
                    Text(slides[index].notes)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: 640, alignment: .leading)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 8)
                }

                Text("\(index + 1) / \(slides.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, 14)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advance(1) }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    advance(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    /// Design step 7's presenter view: the current slide, a preview of
    /// what's coming next, speaker notes, and an elapsed-time clock — none
    /// of which the audience (on the external screen) ever sees. The next
    /// slide's preview always shows its final, fully-revealed state
    /// (`revealedElementIDs: nil`) — a presenter needs to see what's
    /// coming, not its own build-up animation.
    private var presenterLayout: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("現在のスライド").font(.caption).foregroundStyle(.secondary)
                    SlideStage(
                        slide: slides.indices.contains(index) ? slides[index] : nil,
                        aspect: deck.aspect, revealedElementIDs: revealedElementIDs
                    )
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("次のスライド").font(.caption).foregroundStyle(.secondary)
                    SlideStage(slide: slides.indices.contains(index + 1) ? slides[index + 1] : nil, aspect: deck.aspect)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            if !slides.indices.contains(index + 1) {
                                Text("最後のスライドです")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                }
            }
            .padding(.horizontal)
            .frame(maxHeight: .infinity)

            if slides.indices.contains(index), !slides[index].notes.isEmpty {
                ScrollView {
                    Text(slides[index].notes)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 160)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }

            HStack {
                Button { dismiss() } label: { Label("終了", systemImage: "xmark") }
                Spacer()
                Text("\(index + 1) / \(slides.count)")
                    .font(.subheadline.monospacedDigit())
                Spacer()
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Label(PresentationElapsedTime.formatted(from: startedAt, to: context.date), systemImage: "clock")
                        .font(.subheadline.monospacedDigit())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture { advance(1) }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    advance(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    /// Mirrors the current slide (respecting reveal progress, same as the
    /// audience would see it) onto the external screen, if one is
    /// connected — a no-op otherwise.
    private func updateExternalDisplay() {
        guard slides.indices.contains(index) else { return }
        let slide = slides[index]
        let revealed = revealedElementIDs
        let aspect = deck.aspect
        externalDisplay.show {
            AnyView(
                ZStack {
                    Color.black
                    SlideStage(slide: slide, aspect: aspect, revealedElementIDs: revealed)
                }
                .ignoresSafeArea()
            )
        }
    }

    /// Forward taps reveal this slide's animations one click-step at a
    /// time before moving on to the next slide; backward swipes always go
    /// straight to the previous slide, without stepping animations back
    /// down first — real PowerPoint's own "previous" is more nuanced than
    /// that, but this covers the common case at far less complexity.
    private func advance(_ step: Int) {
        if step > 0, slides.indices.contains(index) {
            let steps = slides[index].animationSteps
            if revealStepIndex < steps.count - 1 {
                revealStepIndex += 1
                revealedElementIDs.formUnion(steps[revealStepIndex].map(\.stableID))
                return
            }
        }
        let next = index + step
        guard slides.indices.contains(next) else {
            if next >= slides.count { dismiss() }
            return
        }
        lastSlideStep = step
        withAnimation(.easeInOut(duration: 0.35)) { index = next }
        resetReveal(for: slides[next])
    }

    private func resetReveal(for slide: Slide) {
        let steps = slide.animationSteps
        revealStepIndex = 0
        revealedElementIDs = Set(steps.first?.map(\.stableID) ?? [])
    }

    private func transitionStyle(for slide: Slide) -> AnyTransition {
        switch slide.transition {
        case .none: return .identity
        case .fade: return .opacity
        case .push:
            let insertionEdge: Edge = lastSlideStep >= 0 ? .trailing : .leading
            let removalEdge: Edge = lastSlideStep >= 0 ? .leading : .trailing
            return .asymmetric(insertion: .move(edge: insertionEdge), removal: .move(edge: removalEdge))
        }
    }
}
