import SwiftUI
import SwiftData

// MARK: - Master slide editor (design step 5)

/// "Fix it once, every slide updates" — mirrors PowerPoint's Slide Master
/// view. Edits a deck's `SlideMaster` (background/text colors, heading/body
/// fonts) and each of its `SlideLayoutTemplate`s (name, and the
/// `SlidePlaceholder`s a slide choosing that layout starts from). A
/// placeholder's position/size here is exactly what `SlideElement.centerX`
/// etc. inherit from until a user drags their own copy on an actual slide
/// — see that type's doc comment for the inherit/override mechanics this
/// screen is the other end of.
struct SlideMasterEditorView: View {
    @Bindable var master: SlideMaster

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLayoutID: PersistentIdentifier?
    @State private var selectedPlaceholderID: ObjectIdentifier?
    @State private var isRenamingLayout = false
    @State private var renameDraft = ""

    private var layouts: [SlideLayoutTemplate] { master.sortedLayouts }

    private var selectedLayout: SlideLayoutTemplate? {
        layouts.first { $0.persistentModelID == selectedLayoutID } ?? layouts.first
    }

    private var selectedPlaceholder: SlidePlaceholder? {
        selectedLayout?.sortedPlaceholders.first { $0.stableID == selectedPlaceholderID }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                layoutList
                Divider()
                VStack(spacing: 0) {
                    appearanceBar
                    Divider()
                    if let layout = selectedLayout {
                        layoutEditor(for: layout)
                    } else {
                        ContentUnavailableView(
                            "レイアウトがありません",
                            systemImage: "rectangle.on.rectangle",
                            description: Text("左下の「レイアウトを追加」から作成してください")
                        )
                    }
                }
            }
            .navigationTitle("マスタースライドを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .alert("レイアウト名を変更", isPresented: $isRenamingLayout) {
                TextField("レイアウト名", text: $renameDraft)
                Button("キャンセル", role: .cancel) {}
                Button("変更") {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let layout = selectedLayout { layout.name = trimmed }
                    try? modelContext.save()
                }
            }
            .onAppear { if selectedLayoutID == nil { selectedLayoutID = layouts.first?.persistentModelID } }
            .onChange(of: selectedLayoutID) { _, _ in selectedPlaceholderID = nil }
        }
    }

    // MARK: Layout list

    private var layoutList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { selectedLayoutID },
                set: { selectedLayoutID = $0 }
            )) {
                ForEach(layouts, id: \.persistentModelID) { layout in
                    Text(layout.name)
                        .tag(layout.persistentModelID as PersistentIdentifier?)
                        .contextMenu {
                            Button("名前を変更", systemImage: "pencil") {
                                renameDraft = layout.name
                                isRenamingLayout = true
                            }
                            Button("複製", systemImage: "plus.square.on.square") { duplicate(layout) }
                            Button("削除", systemImage: "trash", role: .destructive) { delete(layout) }
                        }
                }
            }
            .listStyle(.plain)

            Divider()

            Button {
                addLayout()
            } label: {
                Label("レイアウトを追加", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
        .background(Color(.systemBackground))
    }

    // MARK: Appearance (master-level colors/fonts)

    private var appearanceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                colorSwatch("背景", hex: Binding(
                    get: { master.backgroundColorHex },
                    set: { master.backgroundColorHex = $0; try? modelContext.save() }
                ))
                colorSwatch("タイトル文字", hex: Binding(
                    get: { master.titleColorHex },
                    set: { master.titleColorHex = $0; try? modelContext.save() }
                ))
                colorSwatch("本文文字", hex: Binding(
                    get: { master.bodyColorHex },
                    set: { master.bodyColorHex = $0; try? modelContext.save() }
                ))
                colorSwatch("アクセント", hex: Binding(
                    get: { master.accentColorHex },
                    set: { master.accentColorHex = $0; try? modelContext.save() }
                ))

                Divider().frame(height: 24)

                Menu {
                    ForEach(DocumentFontFamily.allCases) { family in
                        Button(family.title) { master.headingFontFamily = family; try? modelContext.save() }
                    }
                } label: {
                    Label("見出し: \(master.headingFontFamily.title)", systemImage: "textformat")
                        .font(.subheadline)
                }

                Menu {
                    ForEach(DocumentFontFamily.allCases) { family in
                        Button(family.title) { master.bodyFontFamily = family; try? modelContext.save() }
                    }
                } label: {
                    Label("本文: \(master.bodyFontFamily.title)", systemImage: "textformat")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
        .background(.bar)
    }

    private func colorSwatch(_ title: String, hex: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ColorPicker(selection: Binding(
                get: { Color(UIColor(inkHex: hex.wrappedValue)) },
                set: { hex.wrappedValue = UIColor($0).toHex() }
            ), supportsOpacity: false) {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Layout editor

    private func layoutEditor(for layout: SlideLayoutTemplate) -> some View {
        VStack(spacing: 0) {
            layoutToolBar(for: layout)
            Divider()

            GeometryReader { geometry in
                let width = min(geometry.size.width - 48, (geometry.size.height - 48) * 16 / 9)
                let displaySize = CGSize(width: max(200, width), height: max(200, width) * 9 / 16)
                PlaceholderCanvasLayer(
                    layout: layout, master: master, slideSize: displaySize,
                    selectedPlaceholderID: $selectedPlaceholderID,
                    onChange: { try? modelContext.save() }
                )
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let placeholder = selectedPlaceholder {
                Divider()
                placeholderInspector(for: placeholder, in: layout)
            }
        }
    }

    private func layoutToolBar(for layout: SlideLayoutTemplate) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(unusedRoles(in: layout)) { role in
                    Button(role.title) { addPlaceholder(role: role, to: layout) }
                }
            } label: {
                Label("プレースホルダーを追加", systemImage: "plus.square.on.square").font(.subheadline)
            }
            .disabled(unusedRoles(in: layout).isEmpty)

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color(.systemBackground))
    }

    private func placeholderInspector(for placeholder: SlidePlaceholder, in layout: SlideLayoutTemplate) -> some View {
        HStack(spacing: 16) {
            Text(placeholder.role.title).font(.subheadline.weight(.semibold))

            Divider().frame(height: 20)

            Stepper(
                "文字サイズ \(Int(placeholder.defaultFontSize))",
                value: Binding(
                    get: { placeholder.defaultFontSize },
                    set: { placeholder.defaultFontSize = $0; try? modelContext.save() }
                ),
                in: 10...72
            )
            .font(.subheadline)
            .fixedSize()

            Toggle(isOn: Binding(
                get: { placeholder.defaultIsBold },
                set: { placeholder.defaultIsBold = $0; try? modelContext.save() }
            )) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)

            Spacer()

            Button(role: .destructive) {
                deletePlaceholder(placeholder, from: layout)
            } label: {
                Label("削除", systemImage: "trash").font(.subheadline)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.bar)
    }

    private func unusedRoles(in layout: SlideLayoutTemplate) -> [SlidePlaceholderRole] {
        let used = Set(layout.sortedPlaceholders.map(\.role))
        return SlidePlaceholderRole.allCases.filter { !used.contains($0) }
    }

    // MARK: Actions

    private func addLayout() {
        let layout = master.addLayout(name: "新しいレイアウト")
        try? modelContext.save()
        selectedLayoutID = layout.persistentModelID
    }

    private func duplicate(_ layout: SlideLayoutTemplate) {
        let copy = master.duplicateLayout(layout)
        try? modelContext.save()
        selectedLayoutID = copy.persistentModelID
    }

    /// Slides that had picked this layout simply fall back to a
    /// free-floating canvas (`slide.layout` nullifies automatically; see
    /// `SlideLayoutTemplate.slides`'s doc comment). The data-integrity part
    /// — baking in and detaching any still-inheriting `SlideElement` first
    /// — is `SlideMaster.removeLayout(_:)`'s job, so it's covered by tests
    /// independent of this view.
    private func delete(_ layout: SlideLayoutTemplate) {
        guard master.removeLayout(layout) else { return }
        modelContext.delete(layout)
        try? modelContext.save()
        if selectedLayoutID == layout.persistentModelID {
            selectedLayoutID = master.sortedLayouts.first?.persistentModelID
        }
    }

    private func addPlaceholder(role: SlidePlaceholderRole, to layout: SlideLayoutTemplate) {
        let kind: SlideElementKind = role == .image ? .image : .text
        let placeholder = layout.addPlaceholder(role: role, kind: kind, centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.2)
        try? modelContext.save()
        selectedPlaceholderID = placeholder.stableID
    }

    private func deletePlaceholder(_ placeholder: SlidePlaceholder, from layout: SlideLayoutTemplate) {
        guard layout.removePlaceholder(placeholder) else { return }
        modelContext.delete(placeholder)
        selectedPlaceholderID = nil
        try? modelContext.save()
    }
}

// MARK: - Placeholder canvas

/// A simplified, single-selection sibling of `SlideElementsLayer` — drags
/// and resizes `SlidePlaceholder`s (not `SlideElement`s) using the same
/// pure `CanvasElementGeometry` math. No rotation, multi-select, or
/// smart guides here: a layout's placeholders are a small, deliberately
/// simple set, and this screen is about *where things start*, not the
/// richer manipulation a real slide's canvas needs.
private struct PlaceholderCanvasLayer: View {
    @Bindable var layout: SlideLayoutTemplate
    let master: SlideMaster
    let slideSize: CGSize
    @Binding var selectedPlaceholderID: ObjectIdentifier?
    let onChange: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(UIColor(inkHex: master.backgroundColorHex))
                .frame(width: slideSize.width, height: slideSize.height)

            Color.clear
                .frame(width: slideSize.width, height: slideSize.height)
                .contentShape(Rectangle())
                .onTapGesture { selectedPlaceholderID = nil }

            ForEach(layout.sortedPlaceholders, id: \.stableID) { placeholder in
                EditablePlaceholderBox(
                    placeholder: placeholder,
                    slideSize: slideSize,
                    selectedPlaceholderID: $selectedPlaceholderID,
                    onChange: onChange
                )
            }
        }
        .frame(width: slideSize.width, height: slideSize.height)
        .clipped()
    }
}

private struct EditablePlaceholderBox: View {
    @Bindable var placeholder: SlidePlaceholder
    let slideSize: CGSize
    @Binding var selectedPlaceholderID: ObjectIdentifier?
    let onChange: () -> Void

    @State private var dragOrigin: CGPoint?
    @State private var handleOrigin: CanvasElementGeometry.Frame?

    private var isSelected: Bool { selectedPlaceholderID == placeholder.stableID }

    private var boxSize: CGSize {
        CGSize(
            width: max(44, slideSize.width * placeholder.width),
            height: max(28, slideSize.height * placeholder.height)
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
                isSelected ? Color.accentColor : Color.secondary,
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [5, 3])
            )
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(isSelected ? 0.1 : 0.04)))
            .overlay(
                Text(placeholder.role.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
            .frame(width: boxSize.width, height: boxSize.height)
            .contentShape(Rectangle())
            .overlay { if isSelected { selectionHandles } }
            .position(x: slideSize.width * placeholder.centerX, y: slideSize.height * placeholder.centerY)
            .onTapGesture { selectedPlaceholderID = isSelected ? nil : placeholder.stableID }
            .gesture(isSelected ? moveGesture : nil)
    }

    private var selectionHandles: some View {
        ZStack {
            ForEach(ResizeHandleAnchor.allCases) { anchor in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(
                        x: boxSize.width / 2 + anchor.unitX * boxSize.width / 2,
                        y: boxSize.height / 2 + anchor.unitY * boxSize.height / 2
                    )
                    .gesture(resizeHandleGesture(anchor))
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = CGPoint(x: placeholder.centerX, y: placeholder.centerY) }
                guard let origin = dragOrigin else { return }
                let moved = CanvasElementGeometry.moved(from: origin, translation: value.translation, canvasSize: slideSize)
                placeholder.centerX = moved.x
                placeholder.centerY = moved.y
            }
            .onEnded { _ in dragOrigin = nil; onChange() }
    }

    private func resizeHandleGesture(_ anchor: ResizeHandleAnchor) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if handleOrigin == nil {
                    handleOrigin = CanvasElementGeometry.Frame(
                        centerX: placeholder.centerX, centerY: placeholder.centerY,
                        width: placeholder.width, height: placeholder.height
                    )
                }
                guard let origin = handleOrigin else { return }
                let result = CanvasElementGeometry.resized(
                    from: origin, anchor: anchor, translation: value.translation,
                    canvasSize: slideSize, rotationDegrees: placeholder.rotation
                )
                placeholder.centerX = result.centerX
                placeholder.centerY = result.centerY
                placeholder.width = result.width
                placeholder.height = result.height
            }
            .onEnded { _ in handleOrigin = nil; onChange() }
    }
}
