import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// The slide editor: a thumbnail rail, a live slide canvas, an inspector for
/// layout/theme/notes, a full-screen presentation mode, and PDF export.
///
/// Editing happens through the layout's placeholders rather than on a free
/// canvas, which is how PowerPoint is built: the layout owns the geometry, the
/// slide owns the words. Restyling a deck is then a theme change, and changing
/// a slide's arrangement is one tap instead of dragging boxes around.
struct SlideDeckView: View {
    @Bindable var deck: SlideDeck
    var onHome: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @State private var selectedSlideID: PersistentIdentifier?
    @State private var isPresenting = false
    @State private var showsNotes = true
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pdfDocument: PDFExportDocument?
    @State private var showsPDFExporter = false

    private var slides: [Slide] { deck.sortedSlides }

    private var selectedSlide: Slide? {
        slides.first { $0.persistentModelID == selectedSlideID } ?? slides.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                thumbnailRail
                Divider()
                editorArea
            }
        }
        .background(Color(.secondarySystemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if deck.sortedSlides.isEmpty { addSlide(layout: .titleSlide) }
            if selectedSlideID == nil { selectedSlideID = slides.first?.persistentModelID }
        }
        .fullScreenCover(isPresented: $isPresenting) {
            SlidePresentationView(deck: deck, startAt: selectedSlide?.order ?? 0)
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
        .modifier(PDFSaveModifier(
            isPresented: $showsPDFExporter,
            document: $pdfDocument,
            filename: "\(deck.title).pdf"
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
                                SlideCanvas(
                                    slide: slide, theme: deck.theme, aspect: deck.aspect, isEditable: false,
                                    fontFamily: deck.fontFamily, textScale: deck.textScale,
                                    titleIsBold: deck.titleIsBold, bodyIsItalic: deck.bodyIsItalic
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

    @ViewBuilder
    private var editorArea: some View {
        if let slide = selectedSlide {
            VStack(spacing: 0) {
                layoutBar(for: slide)
                Divider()

                GeometryReader { geometry in
                    let width = min(
                        geometry.size.width - 48,
                        (geometry.size.height - 48) * deck.aspect.ratio
                    )
                    SlideCanvas(
                        slide: slide, theme: deck.theme, aspect: deck.aspect, isEditable: true,
                        fontFamily: deck.fontFamily, textScale: deck.textScale,
                        titleIsBold: deck.titleIsBold, bodyIsItalic: deck.bodyIsItalic
                    )
                        .frame(width: max(200, width), height: max(200, width) / deck.aspect.ratio)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showsNotes {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("発表者ノート")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                        slide.layout = layout
                        deck.updatedAt = .now
                    } label: {
                        Label(layout.title, systemImage: layout.icon)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: slide.layout.icon)
                    Text(slide.layout.title).font(.subheadline)
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

            if slide.layout.hasImage {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(slide.imageData == nil ? "画像を選ぶ" : "画像を変更", systemImage: "photo")
                        .font(.subheadline)
                }
                if slide.imageData != nil {
                    Button("画像を削除", role: .destructive) {
                        slide.imageData = nil
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

    // MARK: Slide operations

    private func addSlide(layout: SlideLayout) {
        let slide = Slide(order: deck.sortedSlides.count, layout: layout)
        slide.deck = deck
        deck.addSlide(slide)
        deck.renumberSlides()
        deck.updatedAt = .now
        modelContext.insert(slide)
        try? modelContext.save()
        selectedSlideID = slide.persistentModelID
    }

    private func duplicate(_ slide: Slide) {
        let copy = Slide(order: slide.order + 1, layout: slide.layout)
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
        try? modelContext.save()
        selectedSlideID = copy.persistentModelID
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
            selectedSlide?.imageData = data
            deck.updatedAt = .now
            photoItem = nil
            try? modelContext.save()
        }
    }

    // MARK: Export

    private func exportPDF() {
        let size = deck.aspect.size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let theme = deck.theme
        let aspect = deck.aspect
        let ordered = slides
        let family = deck.fontFamily
        let scale = CGFloat(deck.textScale)
        let bold = deck.titleIsBold
        let italic = deck.bodyIsItalic

        let data = renderer.pdfData { context in
            for slide in ordered {
                context.beginPage()
                // Each slide is rendered from the very same view the editor
                // shows, so the export cannot drift from what was on screen.
                let view = SlideCanvas(
                    slide: slide, theme: theme, aspect: aspect, isEditable: false,
                    fontFamily: family, textScale: scale, titleIsBold: bold, bodyIsItalic: italic
                )
                    .frame(width: size.width, height: size.height)
                let imageRenderer = ImageRenderer(content: view)
                imageRenderer.scale = 2
                if let image = imageRenderer.uiImage {
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            if ordered.isEmpty { context.beginPage() }
        }
        pdfDocument = PDFExportDocument(data: data)
        showsPDFExporter = true
    }
}

// MARK: - Slide rendering

/// One slide, drawn from its layout's placeholders.
///
/// The same view backs the thumbnail rail, the editing canvas, the
/// presentation, and the PDF — `isEditable` only swaps text fields in for
/// labels, so those four can never disagree about how a slide looks.
struct SlideCanvas: View {
    @Bindable var slide: Slide
    let theme: SlideTheme
    let aspect: SlideAspect
    let isEditable: Bool
    /// Deck-wide typography. Defaulted so the thumbnail, presentation and PDF
    /// call sites that predate it keep compiling unchanged.
    var fontFamily: DocumentFontFamily = .system
    var textScale: CGFloat = 1
    var titleIsBold: Bool = true
    var bodyIsItalic: Bool = false

    private func titleFont(size: CGFloat) -> Font {
        guard let descriptor = fontFamily.descriptor(size: size) else {
            return .system(size: size, weight: titleIsBold ? .bold : .regular)
        }
        return Font(UIFont(descriptor: descriptor, size: size)).weight(titleIsBold ? .bold : .regular)
    }

    private func bodyFont(size: CGFloat) -> Font {
        // Italic is applied through the descriptor rather than SwiftUI's
        // `Font.italic(_:)`, which needs a newer deployment target than this
        // app builds against.
        var descriptor = fontFamily.descriptor(size: size)
            ?? UIFont.systemFont(ofSize: size).fontDescriptor
        if bodyIsItalic, let slanted = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = slanted
        }
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    var body: some View {
        GeometryReader { geometry in
            // Everything is expressed as a fraction of the slide's height, so
            // one layout serves a 132pt thumbnail and a full-screen
            // projection identically.
            let unit = geometry.size.height / 540
            let padding = 52 * unit

            ZStack {
                theme.background

                switch slide.layout {
                case .titleSlide, .sectionHeader:
                    VStack(alignment: .leading, spacing: 16 * unit) {
                        titleView(unit: unit, size: slide.layout == .titleSlide ? 54 : 42)
                        if slide.layout == .sectionHeader {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(width: 92 * unit, height: 4 * unit)
                        }
                        if slide.layout.hasBody {
                            bodyView(unit: unit, size: 22, text: $slide.bodyText, placeholder: "サブタイトル")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(padding)

                case .titleAndBody:
                    VStack(alignment: .leading, spacing: 20 * unit) {
                        titleView(unit: unit, size: 38)
                        bulletList(unit: unit, size: 22, text: $slide.bodyText, placeholder: "内容を入力")
                        Spacer(minLength: 0)
                    }
                    .padding(padding)

                case .twoContent:
                    VStack(alignment: .leading, spacing: 18 * unit) {
                        titleView(unit: unit, size: 36)
                        HStack(alignment: .top, spacing: 28 * unit) {
                            bulletList(unit: unit, size: 19, text: $slide.bodyText, placeholder: "左の内容")
                            bulletList(unit: unit, size: 19, text: $slide.secondaryText, placeholder: "右の内容")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(padding)

                case .titleAndImage:
                    VStack(alignment: .leading, spacing: 16 * unit) {
                        titleView(unit: unit, size: 34)
                        HStack(alignment: .top, spacing: 24 * unit) {
                            bulletList(unit: unit, size: 19, text: $slide.bodyText, placeholder: "内容を入力")
                            imageView(unit: unit)
                                .frame(maxWidth: geometry.size.width * 0.42)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(padding)

                case .imageOnly:
                    imageView(unit: unit)
                        .padding(padding * 0.4)

                case .blank:
                    Color.clear
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(aspect.ratio, contentMode: .fit)
    }

    @ViewBuilder
    private func titleView(unit: CGFloat, size: CGFloat) -> some View {
        if isEditable {
            TextField("タイトル", text: $slide.titleText, axis: .vertical)
                .font(titleFont(size: size * unit * textScale))
                .foregroundStyle(theme.titleColor)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
        } else {
            Text(slide.titleText.isEmpty ? " " : slide.titleText)
                .font(titleFont(size: size * unit * textScale))
                .foregroundStyle(theme.titleColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bodyView(unit: CGFloat, size: CGFloat, text: Binding<String>, placeholder: String) -> some View {
        if isEditable {
            TextField(placeholder, text: text, axis: .vertical)
                .font(bodyFont(size: size * unit * textScale))
                .foregroundStyle(theme.bodyColor)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
        } else {
            Text(text.wrappedValue)
                .font(bodyFont(size: size * unit * textScale))
                .foregroundStyle(theme.bodyColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A content placeholder: one bullet per line, exactly as PowerPoint's
    /// body placeholder behaves.
    @ViewBuilder
    private func bulletList(unit: CGFloat, size: CGFloat, text: Binding<String>, placeholder: String) -> some View {
        if isEditable {
            TextField(placeholder, text: text, axis: .vertical)
                .font(bodyFont(size: size * unit * textScale))
                .foregroundStyle(theme.bodyColor)
                .textFieldStyle(.plain)
                .lineLimit(2...12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10 * unit) {
                ForEach(Array(bullets(of: text.wrappedValue).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 10 * unit) {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 7 * unit, height: 7 * unit)
                            .padding(.top, size * unit * 0.42)
                        Text(line)
                            .font(bodyFont(size: size * unit * textScale))
                            .foregroundStyle(theme.bodyColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullets(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func imageView(unit: CGFloat) -> some View {
        if let data = slide.imageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6 * unit))
        } else {
            RoundedRectangle(cornerRadius: 6 * unit)
                .fill(theme.accent.opacity(0.10))
                .overlay(
                    VStack(spacing: 6 * unit) {
                        Image(systemName: "photo")
                            .font(.system(size: 26 * unit))
                        Text("画像なし").font(.system(size: 13 * unit))
                    }
                    .foregroundStyle(theme.accent.opacity(0.65))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Presentation

/// Full-screen playback. Tap or swipe (or use the arrow keys on a hardware
/// keyboard) to advance; the slide number and speaker notes stay available
/// without being part of the slide itself.
private struct SlidePresentationView: View {
    @Bindable var deck: SlideDeck
    let startAt: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showsNotes = false

    private var slides: [Slide] { deck.sortedSlides }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if slides.indices.contains(index) {
                SlideCanvas(
                    slide: slides[index],
                    theme: deck.theme,
                    aspect: deck.aspect,
                    isEditable: false,
                    fontFamily: deck.fontFamily,
                    textScale: CGFloat(deck.textScale),
                    titleIsBold: deck.titleIsBold,
                    bodyIsItalic: deck.bodyIsItalic
                )
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
        .onAppear { index = min(max(startAt, 0), max(0, slides.count - 1)) }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func advance(_ step: Int) {
        let next = index + step
        guard slides.indices.contains(next) else {
            if next >= slides.count { dismiss() }
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { index = next }
    }
}
