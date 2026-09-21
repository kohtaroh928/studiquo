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
    /// Design fix item 5's live rich-text editing — see
    /// `EditableSlideElement`'s matching properties for what each one does.
    /// Owned by the caller (`SlideDeckView`) the same way
    /// `selectedElementIDs` is, so its own formatting bar can drive them;
    /// read-only call sites simply don't pass any of this.
    var editingElementID: ObjectIdentifier?
    @Binding var editSelectedRange: NSRange
    var editRevision: Int = 0
    var onBeginEditingText: (SlideElement) -> Void = { _ in }
    var onFormattingChange: (SelectionFormatting) -> Void = { _ in }

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
        editingElementID: ObjectIdentifier? = nil,
        editSelectedRange: Binding<NSRange> = .constant(NSRange()),
        editRevision: Int = 0,
        onBeginEditingText: @escaping (SlideElement) -> Void = { _ in },
        onFormattingChange: @escaping (SelectionFormatting) -> Void = { _ in },
        onChange: @escaping () -> Void
    ) {
        self.slide = slide
        self.slideSize = slideSize
        self.isEditable = isEditable
        self._selectedElementIDs = selectedElementIDs
        self.revealedElementIDs = revealedElementIDs
        self.editingElementID = editingElementID
        self._editSelectedRange = editSelectedRange
        self.editRevision = editRevision
        self.onBeginEditingText = onBeginEditingText
        self.onFormattingChange = onFormattingChange
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
                    editingElementID: editingElementID,
                    editSelectedRange: $editSelectedRange,
                    editRevision: editRevision,
                    revealedElementIDs: revealedElementIDs,
                    otherElementFrames: otherFrames(excluding: element.stableID),
                    onChange: onChange,
                    onMoveSelection: { moveSelection(by: $0) },
                    onMoveSelectionEnded: { onChange() },
                    onGuidesChanged: { x, y in guideX = x; guideY = y },
                    onBeginEditingText: onBeginEditingText,
                    onFormattingChange: onFormattingChange
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
    /// Which text element (if any) is live-being-edited right now — design
    /// fix item 5's real, in-place rich-text editing, replacing the old
    /// popup that rebuilt the whole box's text from plain `String` on every
    /// save (destroying any per-character formatting). Owned by
    /// `SlideDeckView`, alongside `editSelectedRange`/`editRevision`, so its
    /// own formatting bar can read/drive the same live text.
    var editingElementID: ObjectIdentifier?
    @Binding var editSelectedRange: NSRange
    var editRevision: Int = 0
    var revealedElementIDs: Set<ObjectIdentifier>?
    var otherElementFrames: [CanvasElementGeometry.Frame] = []
    let onChange: () -> Void
    let onMoveSelection: (CGSize) -> Void
    let onMoveSelectionEnded: () -> Void
    var onGuidesChanged: (Double?, Double?) -> Void = { _, _ in }
    var onBeginEditingText: (SlideElement) -> Void = { _ in }
    var onFormattingChange: (SelectionFormatting) -> Void = { _ in }

    @State private var dragOrigin: CGPoint?
    @State private var lastGroupTranslation: CGSize = .zero
    @State private var handleOrigin: CanvasElementGeometry.Frame?
    @State private var rotationStart: (touchAngle: Double, elementRotation: Double)?

    /// How much of the raw finger movement actually reaches move/rotate —
    /// under 1 on purpose, so dragging and turning an element both feel
    /// calmer than a strict 1:1 follow. Resizing is left at full speed
    /// (not part of what felt too sensitive).
    private static let moveDamping: CGFloat = 0.6
    private static let rotationDamping: Double = 0.6

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
    private var isEditingThisElement: Bool { isEditable && editingElementID == element.stableID }

    var body: some View {
        Group {
            if isEditable {
                if isEditingThisElement {
                    // A live text-edit session: no move/rotate/resize
                    // gestures and no selection handles while typing — a
                    // plain accent-colored outline instead, matching a
                    // word processor's "click to edit text, click away to
                    // reposition" split between the two modes. Every other
                    // element's own gestures are unaffected; only taps
                    // that land *outside* this box (handled elsewhere,
                    // changing `selectedElementIDs`) end the session, via
                    // `SlideDeckView`'s own `onChange(of: selectedElementIDs)`.
                    RichTextEditor(
                        attributedText: $element.body,
                        selectedRange: $editSelectedRange,
                        externalRevision: editRevision,
                        shouldFocusOnAppear: true,
                        defaultTypingAttributes: element.defaultTextAttributes(),
                        onFormattingChange: { formatting in
                            onFormattingChange(formatting)
                            onChange()
                        }
                    )
                    .frame(width: elementSize.width, height: elementSize.height)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5))
                    .rotationEffect(.degrees(element.rotation))
                    .position(x: slideSize.width * element.centerX, y: slideSize.height * element.centerY)
                } else {
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
    /// selected element a second time either starts editing its text (a
    /// `.text` element — the same "click to select, click again to edit"
    /// two-step PowerPoint itself uses) or deselects it (anything else,
    /// the prior behavior). Tapping an element that's already part of a
    /// multi-selection leaves the whole selection alone, so the same
    /// tap-and-hold can turn straight into a shared drag without
    /// collapsing back down to one element first.
    private func handleTap() {
        if isSelected {
            guard selectedElementIDs.count == 1 else { return }
            if element.kind == .text {
                onBeginEditingText(element)
            } else {
                selectedElementIDs = []
            }
        } else {
            selectedElementIDs = [element.stableID]
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if element.kind == .text {
            Button {
                onBeginEditingText(element)
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

            // Delete, parked just off the top-right corner — the same
            // position and styling as the notes canvas's own per-element
            // delete button, so it's not confused with a resize handle.
            Button(role: .destructive) {
                delete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.red, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .contentShape(Circle().inset(by: -6))
            // Handle positions above are relative to the element's own
            // (0,0)-top-left-to-(width,height)-bottom-right box — e.g. the
            // `.topRight` resize handle lands at (width, 0) exactly — so
            // "just off the top-right corner" is (width + 26, 0 - 20).
            .position(x: elementSize.width + 26, y: -20)
            .accessibilityLabel("この要素を削除")
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
                        width: (value.translation.width - lastGroupTranslation.width) * Self.moveDamping,
                        height: (value.translation.height - lastGroupTranslation.height) * Self.moveDamping
                    )
                    onMoveSelection(delta)
                    lastGroupTranslation = value.translation
                    return
                }
                if element.kind == .group {
                    let deltaWidth = (value.translation.width - lastGroupTranslation.width) * Self.moveDamping
                    let deltaHeight = (value.translation.height - lastGroupTranslation.height) * Self.moveDamping
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
                let dampedTranslation = CGSize(width: value.translation.width * Self.moveDamping, height: value.translation.height * Self.moveDamping)
                let moved = CanvasElementGeometry.moved(from: origin, translation: dampedTranslation, canvasSize: slideSize)
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

    /// Delta-based and damped, rather than jumping straight to the raw
    /// touch-to-center angle every frame: right at the pivot, a tiny
    /// finger movement used to swing the angle wildly, since that raw
    /// angle is inherently more sensitive the closer the touch is to the
    /// center. Tracking how far the angle has moved *since the drag
    /// started*, then only applying a damped fraction of that change on
    /// top of the element's rotation at that moment, makes the whole drag
    /// feel calmer regardless of exactly where on the handle it started.
    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(SlideElementsLayer.coordinateSpace))
            .onChanged { value in
                guard !element.isLocked else { return }
                element.bakeInGeometryIfNeeded()
                let center = CGPoint(x: slideSize.width * element.centerX, y: slideSize.height * element.centerY)
                let touchAngle = CanvasElementGeometry.rotation(center: center, touch: value.location)
                if rotationStart == nil {
                    rotationStart = (touchAngle: touchAngle, elementRotation: element.rotation)
                }
                guard let start = rotationStart else { return }
                var angleDelta = touchAngle - start.touchAngle
                // Keep the shortest way around — otherwise crossing the
                // 0°/360° seam would register as a near-360° jump instead
                // of a small step.
                if angleDelta > 180 { angleDelta -= 360 }
                if angleDelta < -180 { angleDelta += 360 }
                element.overrideRotation = start.elementRotation + angleDelta * Self.rotationDamping
            }
            .onEnded { _ in
                rotationStart = nil
                onChange()
            }
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
