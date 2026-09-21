import SwiftUI
import SwiftData

// MARK: - Slide canvas editor

/// Renders every `SlideElement` on a slide, painted over the deck's master
/// background — the canvas-based editor design step 4 called for. Used in
/// three places, switching `isEditable` off for the latter two:
/// - the live editor (`SlideDeckView.editorArea`), editable;
/// - `SlidePresentationView`, read-only;
/// - `ExportService.pdfData(from: SlideDeck)`, read-only, snapshotted via
///   `ImageRenderer` into each PDF page exactly the way the old
///   `SlideCanvas` was.
///
/// Uses `CanvasElementGeometry` for its drag/resize/rotate math — the same
/// implementation `EditablePageElement` (notes) uses, factored out as pure
/// functions rather than shared view code; see that type's doc comment for
/// why. This view's own gesture/selection/chrome code is new and
/// independent of `EditablePageElement`.
///
/// Selection supports PowerPoint-style multi-select: a rubber-band drag on
/// empty canvas selects every element it overlaps, and dragging any
/// selected element while 2+ are selected moves the whole selection
/// together. `selectedElementIDs` is owned by the caller (`SlideDeckView`)
/// so its own toolbar can offer align/distribute/group/delete on the
/// current selection; read-only call sites simply don't pass a binding.
struct SlideElementsLayer: View {
    @Bindable var slide: Slide
    let slideSize: CGSize
    var isEditable: Bool = true
    @Binding var selectedElementIDs: Set<ObjectIdentifier>
    /// Which animated elements presentation playback (design step 6) has
    /// revealed so far — `nil` (the default) means "show everything,
    /// ignore animation settings entirely," which is what the editor,
    /// thumbnail rail, and PDF export all want: only
    /// `SlidePresentationView` ever passes a real set.
    var revealedElementIDs: Set<ObjectIdentifier>?
    let onChange: () -> Void

    /// `ObjectIdentifier`, not `PersistentIdentifier` — a `SlideElement`
    /// freshly created in this editing session (e.g. by the add-element
    /// toolbar) has no reliable persistent id until the next save, the
    /// same reason `DocumentSegment.id` uses `ObjectIdentifier`.
    init(
        slide: Slide,
        slideSize: CGSize,
        isEditable: Bool = true,
        selectedElementIDs: Binding<Set<ObjectIdentifier>> = .constant([]),
        revealedElementIDs: Set<ObjectIdentifier>? = nil,
        onChange: @escaping () -> Void
    ) {
        self.slide = slide
        self.slideSize = slideSize
        self.isEditable = isEditable
        self._selectedElementIDs = selectedElementIDs
        self.revealedElementIDs = revealedElementIDs
        self.onChange = onChange
    }

    @State private var selectionRect: CGRect?
    @State private var multiMoveLastTranslation: CGSize = .zero
    /// The active smart-guide lines (canvas-fractional position), reported
    /// by whichever solo-selected element is currently being dragged —
    /// `nil` when nothing is snapping right now.
    @State private var guideX: Double?
    @State private var guideY: Double?

    static let coordinateSpace = "studiquoSlideElements"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: slide.deck?.master?.backgroundColorHex ?? "#FFFFFF")
                .frame(width: slideSize.width, height: slideSize.height)

            if isEditable {
                Color.clear
                    .frame(width: slideSize.width, height: slideSize.height)
                    .contentShape(Rectangle())
                    .gesture(selectionDragGesture)
            }

            ForEach(slide.sortedElements, id: \.stableID) { element in
                EditableSlideElement(
                    element: element,
                    slideSize: slideSize,
                    isEditable: isEditable,
                    selectedElementIDs: $selectedElementIDs,
                    revealedElementIDs: revealedElementIDs,
                    otherElementFrames: otherFrames(excluding: element.stableID),
                    onChange: onChange,
                    onMoveSelection: { moveSelection(by: $0) },
                    onMoveSelectionEnded: { onChange() },
                    onGuidesChanged: { x, y in guideX = x; guideY = y }
                )
                .zIndex(selectedElementIDs.contains(element.stableID) ? 1_000_000 : element.layerIndex)
            }

            if let selectionRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
                    .allowsHitTesting(false)
            }

            if let guideX {
                Rectangle().fill(Color.pink)
                    .frame(width: 1, height: slideSize.height)
                    .position(x: guideX * slideSize.width, y: slideSize.height / 2)
                    .allowsHitTesting(false)
            }
            if let guideY {
                Rectangle().fill(Color.pink)
                    .frame(width: slideSize.width, height: 1)
                    .position(x: slideSize.width / 2, y: guideY * slideSize.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: slideSize.width, height: slideSize.height)
        .clipped()
        .coordinateSpace(name: Self.coordinateSpace)
    }

    /// A drag on empty canvas: a near-zero-distance drag (a tap) clears the
    /// selection, anything past that threshold draws a rubber-band rect and
    /// selects every element whose unrotated bounding box it overlaps.
    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                selectionRect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
            }
            .onEnded { value in
                defer { selectionRect = nil }
                let distance = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                guard distance > 4 else {
                    selectedElementIDs = []
                    return
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                let hits = slide.sortedElements.filter { elementIntersects($0, rect: rect) }
                selectedElementIDs = Set(hits.map(\.stableID))
            }
    }

    /// Snapshot of every other element's current frame, for the smart-guide
    /// match against whichever element is being dragged. Computed fresh
    /// per render rather than cached — cheap given typical per-slide
    /// element counts, and it means a drag always compares against the
    /// siblings' latest saved positions.
    private func otherFrames(excluding id: ObjectIdentifier) -> [CanvasElementGeometry.Frame] {
        slide.sortedElements
            .filter { $0.stableID != id }
            .map { CanvasElementGeometry.Frame(centerX: $0.centerX, centerY: $0.centerY, width: $0.width, height: $0.height) }
    }

    private func elementIntersects(_ element: SlideElement, rect: CGRect) -> Bool {
        CanvasElementGeometry.frameIntersects(
            CanvasElementGeometry.Frame(centerX: element.centerX, centerY: element.centerY, width: element.width, height: element.height),
            rect: rect, canvasSize: slideSize
        )
    }

    /// Moves every currently-selected element by the same incremental
    /// screen-space delta — called from whichever selected element the drag
    /// actually started on. Group elements use `moveGroup` (so their
    /// members travel with them); everything else bakes in its geometry
    /// then nudges its own override center, exactly like a solo drag.
    private func moveSelection(by delta: CGSize) {
        for target in slide.sortedElements where selectedElementIDs.contains(target.stableID) {
            guard !target.isLocked else { continue }
            if target.kind == .group {
                target.moveGroup(
                    dx: delta.width / max(slideSize.width, 1),
                    dy: delta.height / max(slideSize.height, 1)
                )
            } else {
                target.bakeInGeometryIfNeeded()
                let moved = CanvasElementGeometry.moved(
                    from: CGPoint(x: target.centerX, y: target.centerY),
                    translation: delta,
                    canvasSize: slideSize
                )
                target.overrideCenterX = moved.x
                target.overrideCenterY = moved.y
            }
        }
    }
}

private enum ElementColorPreset: String, CaseIterable, Identifiable {
    case ink, red, orange, yellow, green, blue

    var id: String { rawValue }
    var hex: String {
        switch self {
        case .ink: "#1C1C1E"
        case .red: "#FF3B30"
        case .orange: "#FF9500"
        case .yellow: "#FFCC00"
        case .green: "#34C759"
        case .blue: "#0A84FF"
        }
    }
    var title: String {
        switch self {
        case .ink: "インク"
        case .red: "赤"
        case .orange: "オレンジ"
        case .yellow: "黄"
        case .green: "緑"
        case .blue: "青"
        }
    }
}

private struct EditableSlideElement: View {
    @Bindable var element: SlideElement
    let slideSize: CGSize
    var isEditable: Bool = true
    @Binding var selectedElementIDs: Set<ObjectIdentifier>
    var revealedElementIDs: Set<ObjectIdentifier>?
    var otherElementFrames: [CanvasElementGeometry.Frame] = []
    let onChange: () -> Void
    let onMoveSelection: (CGSize) -> Void
    let onMoveSelectionEnded: () -> Void
    var onGuidesChanged: (Double?, Double?) -> Void = { _, _ in }

    @State private var dragOrigin: CGPoint?
    @State private var lastGroupTranslation: CGSize = .zero
    @State private var handleOrigin: CanvasElementGeometry.Frame?
    @State private var isEditingText = false
    @State private var editedText = ""

    private var elementSize: CGSize {
        CGSize(
            width: max(44, slideSize.width * element.width),
            height: max(28, slideSize.height * element.height)
        )
    }

    private var isSelected: Bool { isEditable && selectedElementIDs.contains(element.stableID) }
    /// Resize/rotate handles and the per-element context menu only make
    /// sense when exactly this one element is selected — a multi-selection
    /// gets the simplified border-only chrome below plus the shared
    /// align/distribute/group/delete toolbar in `SlideDeckView` instead.
    private var isSoleSelection: Bool { isSelected && selectedElementIDs.count == 1 }

    var body: some View {
        Group {
            if isEditable {
                elementContent
                    .frame(width: elementSize.width, height: elementSize.height)
                    .contentShape(Rectangle())
                    .overlay { if isSelected { selectionChrome } }
                    .rotationEffect(.degrees(element.rotation))
                    .position(x: slideSize.width * element.centerX, y: slideSize.height * element.centerY)
                    .onTapGesture { handleTap() }
                    .gesture(isSelected ? moveGesture : nil)
                    .simultaneousGesture(isSoleSelection && element.kind != .group ? rotationGesture : nil)
                    .contextMenu { if selectedElementIDs.count <= 1 { contextMenuContent } }
                    .alert("テキストを編集", isPresented: $isEditingText) {
                        TextField("文字を入力", text: $editedText, axis: .vertical)
                        Button("キャンセル", role: .cancel) {}
                        Button("保存") {
                            element.body = NSAttributedString(string: editedText, attributes: element.defaultTextAttributes())
                            onChange()
                        }
                    }
            } else {
                // Read-only rendering (presentation mode, PDF export): no
                // hit-testing, no selection chrome, no gestures at all.
                // `revealedElementIDs` (only ever non-nil in presentation
                // playback) additionally hides an animated element and its
                // entrance offset until its reveal step has been reached —
                // see `Slide.animationSteps`'s doc comment.
                let isRevealed = element.animationKind == .none || revealedElementIDs?.contains(element.stableID) ?? true
                elementContent
                    .frame(width: elementSize.width, height: elementSize.height)
                    .opacity(isRevealed ? 1 : 0)
                    .scaleEffect(!isRevealed && element.animationKind == .zoomIn ? 0.5 : 1)
                    .offset(hiddenEntranceOffset(isRevealed: isRevealed))
                    .rotationEffect(.degrees(element.rotation))
                    .position(x: slideSize.width * element.centerX, y: slideSize.height * element.centerY)
                    .animation(.easeOut(duration: element.animationDuration), value: isRevealed)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Tapping an unselected element selects only it. Tapping the sole
    /// selected element deselects it. Tapping an element that's already
    /// part of a multi-selection leaves the whole selection alone, so the
    /// same tap-and-hold can turn straight into a shared drag without
    /// collapsing back down to one element first.
    private func handleTap() {
        if isSelected {
            if selectedElementIDs.count == 1 { selectedElementIDs = [] }
        } else {
            selectedElementIDs = [element.stableID]
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if element.kind == .text {
            Button {
                editedText = element.body.string
                isEditingText = true
            } label: {
                Label("テキストを編集", systemImage: "pencil")
            }
        }
        if element.kind != .group {
            Menu {
                ForEach(ElementColorPreset.allCases) { preset in
                    Button {
                        element.colorHex = preset.hex
                        onChange()
                    } label: {
                        Label(preset.title, systemImage: element.colorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Label("色を変更", systemImage: "paintpalette")
            }
        }
        Menu {
            ForEach(SlideAnimationKind.allCases) { kind in
                Button {
                    setAnimationKind(kind)
                } label: {
                    Label(kind.title, systemImage: element.animationKind == kind ? "checkmark.circle.fill" : "circle")
                }
            }
        } label: {
            Label("アニメーション: \(element.animationKind.title)", systemImage: "wand.and.stars")
        }
        if element.animationKind != .none {
            Menu {
                ForEach(SlideAnimationTrigger.allCases) { trigger in
                    Button {
                        element.animationTrigger = trigger
                        onChange()
                    } label: {
                        Label(trigger.title, systemImage: element.animationTrigger == trigger ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Label("タイミング: \(element.animationTrigger.title)", systemImage: "hand.tap")
            }
            Menu {
                Button("速い (0.3秒)") { element.animationDuration = 0.3; onChange() }
                Button("普通 (0.5秒)") { element.animationDuration = 0.5; onChange() }
                Button("ゆっくり (1.0秒)") { element.animationDuration = 1.0; onChange() }
            } label: {
                Label("速さ", systemImage: "timer")
            }
        }
        Button {
            element.isLocked.toggle()
            onChange()
        } label: {
            Label(element.isLocked ? "ロックを解除" : "位置をロック", systemImage: element.isLocked ? "lock.open" : "lock")
        }
        Button { bringToFront() } label: { Label("最前面へ", systemImage: "square.3.layers.3d.top.filled") }
        Button { sendToBack() } label: { Label("最背面へ", systemImage: "square.3.layers.3d.bottom.filled") }
        Button(role: .destructive) { delete() } label: { Label("削除", systemImage: "trash") }
    }

    @ViewBuilder
    private var elementContent: some View {
        let color = Color(hex: element.colorHex)
        switch element.kind {
        case .text:
            Text(AttributedString(SlideListText.renderedForDisplay(element.body)))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: verticalFrameAlignment)
        case .image:
            if let data = element.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            }
        case .rectangle:
            RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: element.lineWidth)
        case .ellipse:
            Ellipse().stroke(color, lineWidth: element.lineWidth)
        case .line:
            Rectangle().fill(color).frame(height: max(1, element.lineWidth))
        case .group:
            // A group has no visible content of its own — its members
            // render independently at their own (already group-relative)
            // resolved positions; this is only a selectable/draggable
            // bounding indicator.
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private var verticalFrameAlignment: Alignment {
        switch element.verticalAlignment {
        case .top: .topLeading
        case .middle: .leading
        case .bottom: .bottomLeading
        }
    }

    /// The pre-reveal offset for a slide-in animation — zero once revealed,
    /// and zero for any kind that isn't directional (fade/zoom/none use
    /// opacity/scale alone, applied at the call site).
    private func hiddenEntranceOffset(isRevealed: Bool) -> CGSize {
        guard !isRevealed else { return .zero }
        switch element.animationKind {
        case .slideInFromLeft: return CGSize(width: -slideSize.width * 0.25, height: 0)
        case .slideInFromRight: return CGSize(width: slideSize.width * 0.25, height: 0)
        case .slideInFromTop: return CGSize(width: 0, height: -slideSize.height * 0.25)
        case .slideInFromBottom: return CGSize(width: 0, height: slideSize.height * 0.25)
        case .none, .fadeIn, .zoomIn: return .zero
        }
    }

    private let handleDiameter: CGFloat = 13

    private var selectionChrome: some View {
        let margin: CGFloat = 28
        let showsHandles = isSoleSelection && element.kind != .group
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: elementSize.width, height: elementSize.height)

            if showsHandles {
                ForEach(ResizeHandleAnchor.allCases) { anchor in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: handleDiameter, height: handleDiameter)
                        .position(
                            x: elementSize.width / 2 + anchor.unitX * elementSize.width / 2,
                            y: elementSize.height / 2 + anchor.unitY * elementSize.height / 2
                        )
                        .gesture(resizeHandleGesture(anchor))
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: handleDiameter, height: handleDiameter)
                    .position(x: elementSize.width / 2, y: -20)
                    .gesture(rotationGesture)
            }
        }
        .frame(width: elementSize.width + margin, height: elementSize.height + margin)
        .allowsHitTesting(!element.isLocked)
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard !element.isLocked else { return }
                if selectedElementIDs.count > 1 {
                    let delta = CGSize(
                        width: value.translation.width - lastGroupTranslation.width,
                        height: value.translation.height - lastGroupTranslation.height
                    )
                    onMoveSelection(delta)
                    lastGroupTranslation = value.translation
                    return
                }
                if element.kind == .group {
                    let deltaWidth = value.translation.width - lastGroupTranslation.width
                    let deltaHeight = value.translation.height - lastGroupTranslation.height
                    element.moveGroup(
                        dx: deltaWidth / max(slideSize.width, 1),
                        dy: deltaHeight / max(slideSize.height, 1)
                    )
                    lastGroupTranslation = value.translation
                    return
                }
                if dragOrigin == nil {
                    element.bakeInGeometryIfNeeded()
                    dragOrigin = CGPoint(x: element.centerX, y: element.centerY)
                }
                guard let origin = dragOrigin else { return }
                let moved = CanvasElementGeometry.moved(from: origin, translation: value.translation, canvasSize: slideSize)
                // Smart guides (design step 4's last piece): snap toward
                // alignment with a sibling element or the canvas's own
                // center whenever already close, and surface the matching
                // guide line(s) for the parent to draw.
                let guided = CanvasElementGeometry.smartGuided(
                    CanvasElementGeometry.Frame(centerX: moved.x, centerY: moved.y, width: element.width, height: element.height),
                    against: otherElementFrames,
                    canvasSize: slideSize
                )
                element.overrideCenterX = guided.frame.centerX
                element.overrideCenterY = guided.frame.centerY
                onGuidesChanged(guided.verticalGuideX, guided.horizontalGuideY)
            }
            .onEnded { _ in
                if selectedElementIDs.count > 1 {
                    lastGroupTranslation = .zero
                    onMoveSelectionEnded()
                    return
                }
                dragOrigin = nil
                lastGroupTranslation = .zero
                onGuidesChanged(nil, nil)
                onChange()
            }
    }

    private func resizeHandleGesture(_ anchor: ResizeHandleAnchor) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !element.isLocked else { return }
                if handleOrigin == nil {
                    element.bakeInGeometryIfNeeded()
                    handleOrigin = CanvasElementGeometry.Frame(
                        centerX: element.centerX, centerY: element.centerY,
                        width: element.width, height: element.height
                    )
                }
                guard let origin = handleOrigin else { return }
                let result = CanvasElementGeometry.resized(
                    from: origin, anchor: anchor, translation: value.translation,
                    canvasSize: slideSize, rotationDegrees: element.rotation
                )
                element.overrideCenterX = result.centerX
                element.overrideCenterY = result.centerY
                element.overrideWidth = result.width
                element.overrideHeight = result.height
            }
            .onEnded { _ in
                handleOrigin = nil
                onChange()
            }
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(SlideElementsLayer.coordinateSpace))
            .onChanged { value in
                guard !element.isLocked else { return }
                element.bakeInGeometryIfNeeded()
                let center = CGPoint(x: slideSize.width * element.centerX, y: slideSize.height * element.centerY)
                element.overrideRotation = CanvasElementGeometry.rotation(center: center, touch: value.location)
            }
            .onEnded { _ in onChange() }
    }

    // MARK: Actions

    private func bringToFront() {
        let maxLayer = (element.slide?.sortedElements.map(\.layerIndex).max() ?? 0)
        element.layerIndex = maxLayer + 1
        onChange()
    }

    private func sendToBack() {
        let minLayer = (element.slide?.sortedElements.map(\.layerIndex).min() ?? 0)
        element.layerIndex = minLayer - 1
        onChange()
    }

    private func delete() {
        selectedElementIDs.remove(element.stableID)
        element.slide?.elements?.removeAll { $0 === element }
        onChange()
    }

    /// Assigns the next `animationOrder` (after every already-animated
    /// element on this slide) the first time an element gains an
    /// animation, so a newly-animated element always plays last by default
    /// — matching PowerPoint's own "new animations append to the end of
    /// the sequence" behaviour — without needing a manual reorder UI.
    private func setAnimationKind(_ kind: SlideAnimationKind) {
        let wasNone = element.animationKind == .none
        element.animationKind = kind
        if wasNone, kind != .none {
            element.animationOrder = element.slide?.nextAnimationOrder() ?? 0
        }
        onChange()
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue: Double
        if cleaned.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        } else {
            red = 0.11; green = 0.11; blue = 0.12
        }
        self.init(red: red, green: green, blue: blue)
    }
}

#if DEBUG
/// An Xcode canvas preview — this app's login screen (Sign in with Apple/
/// Google/passkey) has no test credentials available in this environment,
/// so this is the only way `SlideElementsLayer` has actually been visually
/// checked so far, rather than through the running app itself.
#Preview("Slide canvas editor") {
    let slide = Slide(order: 0)
    let title = SlideElement(kind: .text, layerIndex: 0)
    title.overrideCenterX = 0.5; title.overrideCenterY = 0.15
    title.overrideWidth = 0.8; title.overrideHeight = 0.15
    title.body = NSAttributedString(string: "テストタイトル", attributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
    slide.addElement(title)

    let body = SlideElement(kind: .text, layerIndex: 1)
    body.overrideCenterX = 0.5; body.overrideCenterY = 0.45
    body.overrideWidth = 0.8; body.overrideHeight = 0.3
    let bodyText = NSMutableAttributedString(string: "見出しの下の説明\n一つ目の項目\n二つ目の項目\n")
    SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: 10, length: 5), in: bodyText)
    SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: 16, length: 5), in: bodyText)
    body.body = bodyText
    slide.addElement(body)

    let rect = SlideElement(kind: .rectangle, layerIndex: 2)
    rect.overrideCenterX = 0.75; rect.overrideCenterY = 0.75
    rect.overrideWidth = 0.2; rect.overrideHeight = 0.15
    rect.colorHex = "#FF3B30"
    slide.addElement(rect)

    return SlideElementsLayer(slide: slide, slideSize: CGSize(width: 960, height: 540), onChange: {})
        .background(Color.white)
        .border(Color.gray)
        .padding()
}
#endif
