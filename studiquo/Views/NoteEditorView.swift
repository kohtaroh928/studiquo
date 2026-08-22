import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import WebKit

private extension Notification.Name {
    static let studiquoOpenPageLink = Notification.Name("StudiquoOpenPageLink")
    static let studiquoUndoDrawing = Notification.Name("StudiquoUndoDrawing")
    static let studiquoRedoDrawing = Notification.Name("StudiquoRedoDrawing")
    static let studiquoOpenNotebookTab = Notification.Name("StudiquoOpenNotebookTab")
}

/// True while the enclosing pane is pinch-zoomed. The page list uses it to
/// stand down its own drag handling so the zoom container's `UIScrollView`
/// can own the pan — a SwiftUI `DragGesture` with `minimumDistance: 0` on the
/// list otherwise claims the touch first and the zoomed content never moves.
private struct PaneIsZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var paneIsZoomed: Bool {
        get { self[PaneIsZoomedKey.self] }
        set { self[PaneIsZoomedKey.self] = newValue }
    }
}

private enum ActivePane { case primary, secondary }
private enum PaneDropTarget: Equatable { case primary, secondary }

/// What a top tab-bar selection (or drag) should load into a split pane.
/// Posted cross-file via `StudiquoSwitchPaneTarget` from ContentView,
/// since a tab tap must land in whichever NoteEditorView instance is
/// currently alive without recreating it (see `routeTabSelection`).
enum PaneSwitchTarget {
    case notebook(Notebook)
    case flashcardDeck(FlashcardDeck)
    case web(title: String, homeURL: String)
}

/// A web split, once opened, is announced under this name so ContentView can
/// surface it as a tab like any other open notebook/deck.
struct WebTabInfo: Identifiable, Equatable {
    let id: String
    var title: String
    var homeURL: String
}

/// Shared between ContentView (which owns the tab bar) and the live
/// NoteEditorView (which owns the split layout). ContentView needs to know
/// whether a split is currently on screen to decide how a tab tap should be
/// handled: with no split it can simply swap `selectedNotebook`, which
/// rebuilds the editor and is the reliable path; only while split must it
/// route into a pane so the other pane's work survives.
@MainActor
final class EditorSplitState: ObservableObject {
    @Published var isSplit = false
}

struct NoteEditorView: View {
    @Bindable var notebook: Notebook
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onHome: () -> Void
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \FlashcardDeck.updatedAt, order: .reverse) private var flashcardDecks: [FlashcardDeck]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var splitState: EditorSplitState
    // The browser view observes this model directly. Keeping the reference in
    // State prevents every loading-progress change from rebuilding all pages.
    @State private var webBrowser = WebBrowserModel()

    @State private var primaryPageIndex = 0
    @State private var secondaryPageIndex = 0
    @State private var primaryOverrideNotebook: Notebook?
    @State private var primaryFlashcardDeck: FlashcardDeck?
    @State private var secondaryNotebook: Notebook?
    @State private var splitMode: SplitMode = .single
    @State private var splitRatio: CGFloat = 0.5
    @State private var activePane: ActivePane = .primary
    @State private var pendingSplitMode: SplitMode?
    @State private var showsSplitSourcePicker = false
    @State private var secondaryShowsFlashcards = false
    @State private var secondaryShowsWeb = false
    @State private var secondaryFlashcardDeck: FlashcardDeck?
    @State private var showsDeletePagePicker = false
    @State private var notebookPendingTrash: Notebook?
    @State private var notebookPendingNewPage: Notebook?
    @State private var exportURL: IdentifiableURL?
    @State private var showsPageSidebar = false
    @State private var usesDarkPageDisplay = false
    @State private var isShowingTextAlert = false
    @State private var textToInsert = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedBackgroundPhotoItem: PhotosPickerItem?
    @State private var showsNotebookSearch = false
    @State private var isRecognizingHandwriting = false
    @State private var recognitionProgress = ""
    @State private var isFocusMode = false
    @State private var showsStudySession = false
    @State private var showsOutline = false
    @State private var drawingToolbarCenter: CGPoint?
    @State private var drawingToolbarDragOrigin: CGPoint?
    @State private var isDrawingToolbarVertical = false
    @AppStorage("readOnlyMode") private var isReadOnlyMode = false
    @AppStorage("leftHandedMode") private var isLeftHandedMode = false
    @AppStorage("drawingToolbarPosition") private var drawingToolbarPosition = "bottom"
    @AppStorage("showDrawingToolbar") private var showsDrawingToolbar = true
    @AppStorage("drawingTool") private var drawingToolRaw = DrawingToolKind.pen.rawValue
    @AppStorage("drawingColor") private var drawingColorHex = "#1C1C1E"
    @AppStorage("drawingWidth") private var drawingWidth = 4.0
    @AppStorage("eraserWidth") private var eraserWidth = 24.0
    // Key deliberately renamed from the old "scratchOutEnabled" so a fresh
    // default actually reaches existing installs (an @AppStorage default is
    // only used the first time a key is read, so reusing the old key would
    // have kept whatever was already stored under it). Defaults on, and
    // stays toggleable from the drawing bar.
    @AppStorage("scratchOutEnabledV2") private var isScratchOutEnabled = true
    /// Armed shape kind ("" for none) for the drag-to-create shape tool.
    /// Shared via the same `@AppStorage` key with `PageCanvasContainer`, the
    /// same pattern `drawingToolRaw` already uses to reach the active page's
    /// canvas without a direct reference to it.
    @AppStorage("pendingShapeKind") private var pendingShapeKindRaw = ""
    @AppStorage("selectedElementColor") private var selectedElementColorHex = "#1C1C1E"

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    if showsPageSidebar {
                        PageSidebar(
                            notebook: notebook,
                            currentPageIndex: $primaryPageIndex,
                            onRequestAddPage: { requestPageAddition(to: notebook) }
                        )
                            .frame(width: min(260, geometry.size.width * 0.28))
                        Divider()
                    }
                    workspace(in: CGSize(
                        width: geometry.size.width - (showsPageSidebar ? min(260, geometry.size.width * 0.28) : 0),
                        height: geometry.size.height
                    ))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                if !isReadOnlyMode && showsDrawingToolbar {
                    sharedDrawingToolbar(in: geometry.size)
                }
            }
            .clipped()
        }
        .navigationTitle(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isFocusMode { editorToolStrip }
        }
        .sheet(item: $exportURL) { wrapped in
            ShareSheet(items: [wrapped.url])
        }
        .sheet(isPresented: $showsNotebookSearch) {
            NotebookSearchView(notebook: notebook, currentPageIndex: $primaryPageIndex)
        }
        .sheet(isPresented: $showsStudySession) {
            StudySessionView(notebook: notebook)
        }
        .sheet(isPresented: $showsOutline) {
            NotebookOutlineView(notebook: notebook, currentPageIndex: $primaryPageIndex)
        }
        .sheet(isPresented: $showsSplitSourcePicker) {
            SplitSourcePicker(
                notebooks: notebooks,
                flashcardDecks: flashcardDecks,
                primaryNotebook: displayedPrimaryNotebook,
                onSelectNotebook: { selected in
                secondaryNotebook = selected
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryPageIndex = 0
                completeSplitSelection(object: selected)
            }, onSelectDeck: { deck in
                secondaryNotebook = nil
                secondaryFlashcardDeck = deck
                secondaryShowsWeb = false
                completeSplitSelection(object: deck)
            })
        }
        .sheet(isPresented: $showsDeletePagePicker) {
            PageDeletionPicker(notebook: activeNotebook, currentPageIndex: activePageIndexBinding)
        }
        .confirmationDialog(
            "「\(notebookPendingTrash?.title ?? "ノート")」をゴミ箱に移動しますか？",
            isPresented: Binding(
                get: { notebookPendingTrash != nil },
                set: { if !$0 { notebookPendingTrash = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("ノートを削除", role: .destructive) { trashPendingNotebook() }
            Button("キャンセル", role: .cancel) { notebookPendingTrash = nil }
        } message: {
            Text("ホーム画面のゴミ箱から復元できます。")
        }
        .confirmationDialog(
            "新しいページのスタイル",
            isPresented: Binding(
                get: { notebookPendingNewPage != nil },
                set: { if !$0 { notebookPendingNewPage = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(PageTemplate.allCases) { template in
                Button {
                    addPendingPage(template: template)
                } label: {
                    Label(template.name, systemImage: template.icon)
                }
            }
            Button("キャンセル", role: .cancel) { notebookPendingNewPage = nil }
        } message: {
            Text("追加するページの用紙を選んでください。")
        }
        .alert("テキストを追加", isPresented: $isShowingTextAlert) {
            TextField("文字を入力", text: $textToInsert, axis: .vertical)
            Button("キャンセル", role: .cancel) { textToInsert = "" }
            Button("追加") { addTextElement() }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await addImageElement(from: item) }
        }
        .onChange(of: selectedBackgroundPhotoItem) { _, item in
            guard let item else { return }
            Task { await applyBackgroundImage(from: item) }
        }
        .onChange(of: notebook.pages.count) { _, count in
            primaryPageIndex = clamped(primaryPageIndex, pageCount: count)
            notebook.refreshLibraryMetadata()
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoOpenPageLink)) { notification in
            guard let target = notification.object as? Int,
                  notebook.sortedPages.indices.contains(target) else { return }
            primaryPageIndex = target
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoPageActivated"))) { notification in
            guard let page = notification.object as? NotePage else { return }
            if page.notebook === secondaryNotebook { activePane = .secondary }
            else if page.notebook === notebook { activePane = .primary }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoSwitchPaneTarget"))) { notification in
            guard let target = notification.object as? PaneSwitchTarget else { return }
            routeTabSelection(target)
        }
        .onChange(of: secondaryNotebook?.pages.count) { _, count in
            secondaryPageIndex = clamped(secondaryPageIndex, pageCount: count ?? 0)
            secondaryNotebook?.refreshLibraryMetadata()
        }
        .onAppear { splitState.isSplit = splitMode != .single }
        .onChange(of: splitMode) { _, mode in splitState.isSplit = mode != .single }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                NotebookBackupService.saveAutomaticBackup(for: notebook)
            }
        }
        .onDisappear {
            NotebookBackupService.saveAutomaticBackup(for: notebook)
        }
        .overlay(alignment: .top) {
            if isRecognizingHandwriting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(recognitionProgress)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFocusMode {
                Button {
                    isFocusMode = false
                } label: {
                    Label("集中モードを終了", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private func sharedDrawingToolbar(in size: CGSize) -> some View {
        let horizontalWidth = min(620, max(54, size.width - 16))
        let verticalHeight = min(620, max(54, size.height - 16))
        let barWidth: CGFloat = isDrawingToolbarVertical ? 54 : horizontalWidth
        let barHeight: CGFloat = isDrawingToolbarVertical ? verticalHeight : 54
        let defaultY = drawingToolbarPosition == "top" ? barHeight / 2 + 8 : size.height - barHeight / 2 - 8
        let proposedCenter = drawingToolbarCenter ?? CGPoint(x: size.width / 2, y: defaultY)
        let center = clampedDrawingToolbarCenter(proposedCenter, in: size, width: barWidth, height: barHeight)

        return Group {
            if isDrawingToolbarVertical {
                ScrollView(.vertical) {
                    VStack(spacing: 8) { sharedDrawingToolbarControls(isVertical: true) }
                        .padding(.vertical, 9)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { sharedDrawingToolbarControls(isVertical: false) }
                        .padding(.horizontal, 9)
                }
                .scrollIndicators(.hidden)
            }
        }
        .buttonStyle(.borderless)
        .frame(width: barWidth, height: barHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .environment(\.layoutDirection, isLeftHandedMode ? .rightToLeft : .leftToRight)
        .position(center)
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if drawingToolbarDragOrigin == nil { drawingToolbarDragOrigin = center }
                    guard let origin = drawingToolbarDragOrigin else { return }
                    let candidate = CGPoint(
                        x: origin.x + value.translation.width,
                        y: origin.y + value.translation.height
                    )
                    let edgeThreshold: CGFloat = 100
                    isDrawingToolbarVertical = candidate.x <= edgeThreshold || candidate.x >= size.width - edgeThreshold
                    drawingToolbarCenter = candidate
                }
                .onEnded { _ in
                    drawingToolbarDragOrigin = nil
                    guard isDrawingToolbarVertical, let current = drawingToolbarCenter else { return }
                    let snappedX: CGFloat = current.x < size.width / 2 ? barWidth / 2 + 6 : size.width - barWidth / 2 - 6
                    withAnimation(.easeOut(duration: 0.18)) {
                        drawingToolbarCenter = CGPoint(x: snappedX, y: current.y)
                    }
                }
        )
        .accessibilityLabel("描画バー")
        .accessibilityHint("ドラッグして移動できます。左右端では縦並びになります")
    }

    @ViewBuilder
    private func sharedDrawingToolbarControls(isVertical: Bool) -> some View {
        Button {
            if let activePage {
                NotificationCenter.default.post(name: .studiquoUndoDrawing, object: activePage)
            }
        } label: { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }

        Button {
            if let activePage {
                NotificationCenter.default.post(name: .studiquoRedoDrawing, object: activePage)
            }
        } label: { Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 28) }

        Divider().frame(width: isVertical ? 28 : nil, height: isVertical ? 1 : 24)

        Button { isScratchOutEnabled.toggle() } label: {
            Image(systemName: "scribble.variable")
                .foregroundStyle(isScratchOutEnabled ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(isScratchOutEnabled ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isScratchOutEnabled ? Color.accentColor : .clear, lineWidth: 1.5))
        }

        ForEach(DrawingToolKind.toolbarCases, id: \.rawValue) { tool in
            Button {
                pendingShapeKindRaw = ""
                drawingToolRaw = (drawingTool == tool ? DrawingToolKind.none : tool).rawValue
            } label: {
                Image(systemName: tool.icon)
                    .foregroundStyle(drawingTool == tool ? Color.accentColor : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(drawingTool == tool ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(drawingTool == tool ? Color.accentColor : .clear, lineWidth: 1.5))
            }
        }

        Divider().frame(width: isVertical ? 28 : nil, height: isVertical ? 1 : 24)

        ForEach(["#1C1C1E", "#E53935", "#1565C0", "#2E7D32", "#F9A825"], id: \.self) { hex in
            Button {
                drawingColorHex = hex
                if drawingTool == .eraser || drawingTool == .lasso { drawingToolRaw = DrawingToolKind.pen.rawValue }
            } label: {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: drawingColorHex == hex ? 24 : 19, height: drawingColorHex == hex ? 24 : 19)
                    .overlay(Circle().stroke(.white, lineWidth: drawingColorHex == hex ? 2 : 0))
                    .frame(width: 28, height: 28)
            }
        }

        if drawingTool == .eraser {
            Menu {
                Slider(value: $eraserWidth, in: 10...60, step: 1) {
                    Text("消しゴムの大きさ")
                } minimumValueLabel: {
                    Image(systemName: "eraser").font(.caption2)
                } maximumValueLabel: {
                    Image(systemName: "eraser.fill").font(.body)
                }
                .frame(width: 220)
            } label: { Image(systemName: "eraser").frame(width: 28, height: 28) }
        } else {
            Menu {
                Picker("太さ", selection: $drawingWidth) {
                    Text("細い").tag(2.0)
                    Text("標準").tag(4.0)
                    Text("太い").tag(8.0)
                    Text("極太").tag(14.0)
                }
            } label: { Image(systemName: "lineweight").frame(width: 28, height: 28) }
        }
    }

    private func clampedDrawingToolbarCenter(_ center: CGPoint, in size: CGSize, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(center.x, width / 2 + 6), max(width / 2 + 6, size.width - width / 2 - 6)),
            y: min(max(center.y, height / 2 + 6), max(height / 2 + 6, size.height - height / 2 - 6))
        )
    }

    @ViewBuilder
    private func workspace(in size: CGSize) -> some View {
        switch splitMode {
        case .single:
            primaryPane

        case .horizontal:
            HStack(spacing: 0) {
                primaryPane
                    .frame(width: max(260, size.width * splitRatio - 5))

                SplitDivider(axis: .horizontal) { translation in
                    splitRatio = limitedRatio(splitRatio + translation / max(size.width, 1))
                }

                secondaryPane
            }

        case .vertical:
            VStack(spacing: 0) {
                primaryPane
                    .frame(height: max(220, size.height * splitRatio - 5))

                SplitDivider(axis: .vertical) { translation in
                    splitRatio = limitedRatio(splitRatio + translation / max(size.height, 1))
                }

                secondaryPane
            }
        }
    }

    @ViewBuilder
    private var primaryPane: some View {
        GeometryReader { geometry in
            ZoomableWorkspace(size: geometry.size) {
                Group {
                    if let primaryFlashcardDeck {
                        FlashcardPaneView(deck: primaryFlashcardDeck)
                    } else {
                        NotebookPaneView(
                            notebook: displayedPrimaryNotebook,
                            currentPageIndex: $primaryPageIndex,
                            usesDarkPageDisplay: usesDarkPageDisplay,
                            onRequestAddPage: { requestPageAddition(to: displayedPrimaryNotebook) },
                            onQuickAddPage: { quickAddPage(to: displayedPrimaryNotebook) },
                            onQuickAddPageAtTop: { quickAddPageAtTop(to: displayedPrimaryNotebook) }
                        )
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { activePane = .primary })
        .dropDestination(for: String.self) { items, _ in
            guard splitMode != .single, let value = items.first else { return false }
            return handlePaneDrop(value, target: .primary)
        }
    }

    @ViewBuilder
    private var secondaryPane: some View {
        if secondaryShowsWeb {
            WebSearchPane(browser: webBrowser)
        } else if let secondaryFlashcardDeck {
            GeometryReader { geometry in
                ZoomableWorkspace(size: geometry.size) {
                    FlashcardPaneView(deck: secondaryFlashcardDeck)
                }
            }
                .simultaneousGesture(TapGesture().onEnded { activePane = .secondary })
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first else { return false }
                    return handlePaneDrop(value, target: .secondary)
                }
        } else if let secondaryNotebook {
            GeometryReader { geometry in
                ZoomableWorkspace(size: geometry.size) {
                    NotebookPaneView(
                        notebook: secondaryNotebook,
                        currentPageIndex: $secondaryPageIndex,
                        showsTitle: true,
                        onRequestAddPage: { requestPageAddition(to: secondaryNotebook) },
                        onQuickAddPage: { quickAddPage(to: secondaryNotebook) },
                        onQuickAddPageAtTop: { quickAddPageAtTop(to: secondaryNotebook) }
                    )
                }
            }
            .simultaneousGesture(TapGesture().onEnded { activePane = .secondary })
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first else { return false }
                return handlePaneDrop(value, target: .secondary)
            }
        } else {
            ContentUnavailableView {
                Label("右側のノートを選択", systemImage: "rectangle.split.2x1")
            } description: {
                Text("上の「資料を選ぶ」からPDFまたはノートを選択してください")
            } actions: {
                Button("白紙ノートを作る") {
                    secondaryNotebook = createCompanionNotebook()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: onHome) {
                Label("ホームへ戻る", systemImage: "house.fill")
            }
        }

        if false {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                guard let page = currentPrimaryPage else { return }
                NotificationCenter.default.post(name: .studiquoUndoDrawing, object: page)
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(currentPrimaryPage == nil)

            Button {
                guard let page = currentPrimaryPage else { return }
                NotificationCenter.default.post(name: .studiquoRedoDrawing, object: page)
            } label: {
                Label("やり直す", systemImage: "arrow.uturn.forward")
            }
            .disabled(currentPrimaryPage == nil)

            Button(action: selectPen) {
                Label(
                    showsDrawingToolbar && drawingTool == .pen ? "ペンバーを隠す" : "ペンで書く",
                    systemImage: "pencil.tip"
                )
            }

            Button(action: selectEraser) {
                Label("消しゴム", systemImage: "eraser")
            }

            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Label(
                    columnVisibility == .detailOnly ? "サイドバーを表示" : "サイドバーを隠す",
                    systemImage: "sidebar.left"
                )
            }

            Button {
                showsNotebookSearch = true
            } label: {
                Label("ノート内検索", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)

            Button {
                showsOutline = true
            } label: {
                Label("目次", systemImage: "list.bullet")
            }

            Menu {
                Toggle(isOn: $isReadOnlyMode) {
                    Label("閲覧専用", systemImage: "eye")
                }
                Toggle(isOn: $isLeftHandedMode) {
                    Label("左利き配置", systemImage: "hand.raised")
                }
                Picker("描画バーの位置", selection: $drawingToolbarPosition) {
                    Text("画面下").tag("bottom")
                    Text("画面上").tag("top")
                }
                Button {
                    isFocusMode = true
                } label: {
                    Label("集中モード", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                PhotosPicker(selection: $selectedBackgroundPhotoItem, matching: .images) {
                    Label("写真を背景に設定", systemImage: "photo.on.rectangle")
                }
                if let page = currentPrimaryPage, page.backgroundImageData != nil {
                    Button {
                        page.backgroundImageData = nil
                        page.notebook?.refreshLibraryMetadata()
                        notebook.updatedAt = .now
                    } label: {
                        Label("背景画像を外す", systemImage: "xmark.rectangle")
                    }
                }
            } label: {
                Label("表示モード", systemImage: isReadOnlyMode ? "eye" : "pencil.and.outline")
            }

            Button {
                showsStudySession = true
            } label: {
                Label("学習モード", systemImage: "graduationcap")
            }

            Menu {
                Button {
                    recognizeCurrentPage()
                } label: {
                    Label("現在のページを認識", systemImage: "text.viewfinder")
                }
                Button {
                    recognizeAllPages()
                } label: {
                    Label("全ページを認識", systemImage: "doc.text.magnifyingglass")
                }
                if let page = currentPrimaryPage {
                    Button {
                        addRecognizedTextElement(from: page)
                    } label: {
                        Label("認識文字をテキストに変換", systemImage: "text.badge.checkmark")
                    }
                    .disabled(page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } label: {
                Label("手書き文字認識", systemImage: "character.cursor.ibeam")
            }
            .disabled(isRecognizingHandwriting)

            Button {
                showsPageSidebar.toggle()
            } label: {
                Label("ページ一覧", systemImage: "sidebar.left")
            }

            Button {
                usesDarkPageDisplay.toggle()
            } label: {
                Label("ページダーク表示", systemImage: usesDarkPageDisplay ? "sun.max" : "moon")
            }

            Menu {
                ForEach(PageTemplate.allCases) { template in
                    Button {
                        applyTemplate(template)
                    } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                }
                Divider()
                ForEach(PaperColorPreset.allCases) { preset in
                    Button {
                        if let page = currentPrimaryPage {
                            page.paperColorHex = preset.hex
                            notebook.updatedAt = .now
                        }
                    } label: {
                        Label(preset.title, systemImage: currentPrimaryPage?.paperColorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Label("用紙", systemImage: "doc.text.image")
            }

            Button {
                isShowingTextAlert = true
            } label: {
                Label("テキスト", systemImage: "textformat")
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label("写真", systemImage: "photo")
            }

            Menu {
                ForEach([PageElementKind.rectangle, .ellipse, .line]) { kind in
                    Button {
                        addShapeElement(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.icon)
                    }
                }
                Button {
                    addShapeElement(.studyTape)
                } label: {
                    Label("暗記テープ", systemImage: "rectangle.fill")
                }
            } label: {
                Label("図形", systemImage: "square.on.circle")
            }

            Menu {
                ForEach(Array(notebook.sortedPages.enumerated()), id: \.element.persistentModelID) { index, target in
                    Button {
                        addPageLink(to: index, title: target.title)
                    } label: {
                        Label(target.title.isEmpty ? "ページ \(index + 1)" : target.title, systemImage: "link")
                    }
                }
            } label: {
                Label("ページリンク", systemImage: "link")
            }

            Menu {
                ForEach(ElementColorPreset.allCases) { preset in
                    Button {
                        selectedElementColorHex = preset.hex
                    } label: {
                        Label(preset.title, systemImage: selectedElementColorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Label("色", systemImage: "paintpalette")
                    .foregroundStyle(Color(hex: selectedElementColorHex))
            }

            Menu {
                if let page = currentPrimaryPage, !page.elements.isEmpty {
                    ForEach(page.elements.sorted(by: { $0.layerIndex > $1.layerIndex })) { element in
                        Menu {
                            Button {
                                element.isLocked.toggle()
                                notebook.updatedAt = .now
                            } label: {
                                Label(element.isLocked ? "ロック解除" : "ロック", systemImage: element.isLocked ? "lock.open" : "lock")
                            }
                            Button { moveElementToFront(element, on: page) } label: { Label("最前面へ", systemImage: "square.3.layers.3d.top.filled") }
                            Button { moveElementToBack(element, on: page) } label: { Label("最背面へ", systemImage: "square.3.layers.3d.bottom.filled") }
                            Button(role: .destructive) { removeElement(element, from: page) } label: { Label("削除", systemImage: "trash") }
                        } label: {
                            Label(elementLayerTitle(element), systemImage: element.isLocked ? "lock.fill" : element.kind.icon)
                        }
                    }
                } else {
                    Text("このページに要素はありません")
                }
            } label: {
                Label("レイヤー", systemImage: "square.3.layers.3d")
            }

            Menu {
                Button {
                    splitMode = .single
                } label: {
                    Label("1画面", systemImage: "rectangle")
                }
                Button {
                    prepareSplit(.horizontal)
                } label: {
                    Label("左右に2分割", systemImage: "rectangle.split.2x1")
                }
                Button {
                    prepareSplit(.vertical)
                } label: {
                    Label("上下に2分割", systemImage: "rectangle.split.1x2")
                }
            } label: {
                Label("画面分割", systemImage: splitMode.icon)
            }

            if splitMode != .single {
                Menu {
                    ForEach(notebooks) { candidate in
                        Button {
                            secondaryNotebook = candidate
                            secondaryPageIndex = 0
                        } label: {
                            if candidate === secondaryNotebook {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                    Divider()
                    Button {
                        secondaryNotebook = createCompanionNotebook()
                        secondaryPageIndex = 0
                    } label: {
                        Label("白紙ノートを作る", systemImage: "square.and.pencil")
                    }
                    Button {
                        splitRatio = 0.5
                    } label: {
                        Label("50:50に戻す", systemImage: "equal")
                    }
                } label: {
                    Label("資料を選ぶ", systemImage: "folder")
                }
            }

            Button {
                requestPageAddition(to: displayedPrimaryNotebook)
            } label: {
                Label("ページ追加", systemImage: "plus.rectangle.on.rectangle")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Menu {
                Button {
                    if let url = ExportService.makePDF(from: notebook) {
                        exportURL = IdentifiableURL(url: url)
                    }
                } label: {
                    Label("ノート全体をPDF", systemImage: "doc.richtext")
                }
                Button {
                    if let page = currentPrimaryPage,
                       let url = ExportService.makePNG(from: page, notebookTitle: notebook.title) {
                        exportURL = IdentifiableURL(url: url)
                    }
                } label: {
                    Label("現在ページを画像", systemImage: "photo")
                }
            } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        }
    }

    private var editorToolStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                toolStripButton("ホームへ戻る", icon: "house.fill", action: onHome)
                toolStripButton(
                    columnVisibility == .detailOnly ? "サイドバーを表示" : "サイドバーを隠す",
                    icon: "sidebar.left",
                    isActive: columnVisibility != .detailOnly
                ) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
                Text(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                    .accessibilityLabel("現在のノート \(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)")

                Divider()
                    .frame(height: 26)

                toolStripButton("元に戻す", icon: "arrow.uturn.backward") {
                    guard let page = currentPrimaryPage else { return }
                    NotificationCenter.default.post(name: .studiquoUndoDrawing, object: page)
                }
                toolStripButton("やり直す", icon: "arrow.uturn.forward") {
                    guard let page = currentPrimaryPage else { return }
                    NotificationCenter.default.post(name: .studiquoRedoDrawing, object: page)
                }
                toolStripButton("ペン", icon: "pencil.tip", isActive: drawingTool == .pen && !isReadOnlyMode, action: selectPen)
                toolStripButton("消しゴム", icon: "eraser", isActive: drawingTool == .eraser && !isReadOnlyMode, action: selectEraser)
                toolStripButton("検索", icon: "magnifyingglass", isActive: showsNotebookSearch) { showsNotebookSearch = true }

                Menu {
                    Button("現在のページを認識", systemImage: "text.viewfinder", action: recognizeCurrentPage)
                    Button("全ページを認識", systemImage: "doc.text.magnifyingglass", action: recognizeAllPages)
                    if let page = currentPrimaryPage {
                        Button("認識文字をテキストに変換", systemImage: "text.badge.checkmark") {
                            addRecognizedTextElement(from: page)
                        }
                        .disabled(page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } label: { toolStripLabel("文字認識", icon: "character.cursor.ibeam", isActive: isRecognizingHandwriting) }

                toolStripButton("ページ一覧", icon: "rectangle.split.1x2", isActive: showsPageSidebar) { showsPageSidebar.toggle() }
                toolStripButton("明暗表示", icon: usesDarkPageDisplay ? "sun.max" : "moon", isActive: usesDarkPageDisplay) { usesDarkPageDisplay.toggle() }

                Menu {
                    ForEach(PageTemplate.allCases) { template in
                        Button { applyTemplate(template) } label: { Label(template.name, systemImage: template.icon) }
                    }
                    Divider()
                    ForEach(PaperColorPreset.allCases) { preset in
                        Button {
                            currentPrimaryPage?.paperColorHex = preset.hex
                            notebook.updatedAt = .now
                        } label: { Label(preset.title, systemImage: "circle.fill") }
                    }
                } label: {
                    toolStripLabel(
                        "用紙",
                        icon: "doc.text.image",
                        isActive: currentPrimaryPage?.pageTemplate != .blank || currentPrimaryPage?.paperColorHex != "#FFFFFF"
                    )
                }

                toolStripButton("テキスト", icon: "textformat") { isShowingTextAlert = true }
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    toolStripLabel("写真", icon: "photo")
                }

                Menu {
                    ForEach([PageElementKind.rectangle, .ellipse, .line]) { kind in
                        Button { addShapeElement(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                    }
                    Button { addShapeElement(.studyTape) } label: { Label("暗記テープ", systemImage: "rectangle.fill") }
                } label: { toolStripLabel("図形", icon: "square.on.circle", isActive: pendingShapeKindRaw != "") }

                Menu {
                    Button("1画面", systemImage: "rectangle") { splitMode = .single }
                    Button("左右に2分割", systemImage: "rectangle.split.2x1") { prepareSplit(.horizontal) }
                    Button("上下に2分割", systemImage: "rectangle.split.1x2") { prepareSplit(.vertical) }
                    Divider()
                    Button("Google検索と2分割", systemImage: "globe") {
                        openWebSplit(title: "Google検索", homeURL: "https://www.google.com")
                    }
                    Button("Claudeブラウザ版と2分割", systemImage: "message.fill") {
                        openWebSplit(title: "Claude", homeURL: "https://claude.ai")
                    }
                } label: { toolStripLabel("画面分割", icon: splitMode.icon, isActive: splitMode != .single) }

                if splitMode != .single {
                    Menu {
                        ForEach(notebooks) { candidate in
                            Button(candidate.title) {
                                secondaryNotebook = candidate
                                secondaryFlashcardDeck = nil
                                secondaryShowsWeb = false
                                secondaryPageIndex = 0
                            }
                        }
                        Button("白紙ノートを作る", systemImage: "square.and.pencil") {
                            secondaryNotebook = createCompanionNotebook()
                            secondaryFlashcardDeck = nil
                            secondaryShowsWeb = false
                            secondaryPageIndex = 0
                        }
                    } label: { toolStripLabel("資料", icon: "folder", isActive: true) }
                }

                Menu {
                    Button("現在のページを削除", systemImage: "doc.badge.minus", role: .destructive) {
                        deleteCurrentPage()
                    }
                    .disabled(activeNotebook.pages.count <= 1 || activePage == nil)
                    Button("選択して削除", systemImage: "checklist") {
                        showsDeletePagePicker = true
                    }
                    .disabled(activeNotebook.pages.count <= 1)
                    Divider()
                    Button("ノートを削除", systemImage: "trash", role: .destructive) {
                        notebookPendingTrash = activeNotebook
                    }
                } label: { toolStripLabel("削除", icon: "trash") }
                .disabled(
                    (activePane == .primary && primaryFlashcardDeck != nil)
                        || (activePane == .secondary && secondaryFlashcardDeck != nil)
                )

                toolStripButton("ページ追加", icon: "plus.rectangle.on.rectangle") {
                    requestPageAddition(to: displayedPrimaryNotebook)
                }
                    .disabled(primaryFlashcardDeck != nil)

                Menu {
                    Button("ノート全体をPDF", systemImage: "doc.richtext") {
                        if let url = ExportService.makePDF(from: notebook) { exportURL = IdentifiableURL(url: url) }
                    }
                    Button("現在ページを画像", systemImage: "photo") {
                        if let page = currentPrimaryPage,
                           let url = ExportService.makePNG(from: page, notebookTitle: notebook.title) {
                            exportURL = IdentifiableURL(url: url)
                        }
                    }
                } label: { toolStripLabel("書き出し", icon: "square.and.arrow.up") }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
        }
        .scrollIndicators(.hidden)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toolStripButton(
        _ title: String,
        icon: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { toolStripLabel(title, icon: icon, isActive: isActive) }
    }

    private func toolStripLabel(_ title: String, icon: String, isActive: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: 34, height: 34)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func openWebSplit(title: String, homeURL: String) {
        webBrowser.openHomeIfNeeded(homeURL)
        secondaryNotebook = nil
        secondaryFlashcardDeck = nil
        secondaryShowsWeb = true
        splitMode = .horizontal
        splitRatio = 0.5
        activePane = .primary
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoOpenWebTab"),
            object: WebTabInfo(id: homeURL, title: title, homeURL: homeURL)
        )
    }

    /// Routes a top tab-bar selection (or a drag-drop, see `handlePaneDrop`)
    /// into whichever split pane the user did NOT last touch, so switching
    /// tabs while split never disturbs the pane they're actively working
    /// in. With no split active there's only the primary pane to target.
    private func routeTabSelection(_ target: PaneSwitchTarget) {
        let destination: ActivePane = splitMode == .single
            ? .primary
            : (activePane == .primary ? .secondary : .primary)
        applyPaneTarget(target, to: destination)
        activePane = destination
    }

    private func applyPaneTarget(_ target: PaneSwitchTarget, to pane: ActivePane) {
        switch target {
        case .notebook(let targetNotebook):
            if pane == .primary {
                primaryOverrideNotebook = targetNotebook
                primaryFlashcardDeck = nil
                primaryPageIndex = 0
            } else {
                secondaryNotebook = targetNotebook
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryPageIndex = 0
            }
        case .flashcardDeck(let deck):
            if pane == .primary {
                primaryFlashcardDeck = deck
                primaryOverrideNotebook = nil
            } else {
                secondaryFlashcardDeck = deck
                secondaryNotebook = nil
                secondaryShowsWeb = false
            }
        case .web(_, let homeURL):
            // WebSearchPane only ever renders in the secondary slot today;
            // route there regardless so a web tab never silently no-ops.
            webBrowser.openHomeIfNeeded(homeURL)
            secondaryNotebook = nil
            secondaryFlashcardDeck = nil
            secondaryShowsWeb = true
            if splitMode == .single { splitMode = .horizontal }
            activePane = .secondary
            return
        }
    }

    private var drawingTool: DrawingToolKind {
        get { DrawingToolKind(rawValue: drawingToolRaw) ?? .pen }
        set { drawingToolRaw = newValue.rawValue }
    }

    private func selectPen() {
        isReadOnlyMode = false
        pendingShapeKindRaw = ""
        if drawingTool == .pen {
            drawingToolRaw = DrawingToolKind.none.rawValue
            showsDrawingToolbar = false
        } else {
            drawingToolRaw = DrawingToolKind.pen.rawValue
            showsDrawingToolbar = true
        }
    }

    private func selectEraser() {
        isReadOnlyMode = false
        pendingShapeKindRaw = ""
        if drawingTool == .eraser {
            drawingToolRaw = DrawingToolKind.none.rawValue
            showsDrawingToolbar = false
        } else {
            drawingToolRaw = DrawingToolKind.eraser.rawValue
            showsDrawingToolbar = true
        }
    }

    private func prepareSplit(_ mode: SplitMode) {
        pendingSplitMode = mode
        showsSplitSourcePicker = true
    }

    private var displayedPrimaryNotebook: Notebook {
        primaryOverrideNotebook ?? notebook
    }

    private func handlePaneDrop(_ value: String, target: PaneDropTarget) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }

        if parts[0] == "deck",
           let deck = flashcardDecks.first(where: { String(describing: $0.persistentModelID) == parts[1] }) {
            if target == .primary {
                primaryFlashcardDeck = deck
                primaryOverrideNotebook = nil
            } else {
                secondaryFlashcardDeck = deck
                secondaryNotebook = nil
                secondaryShowsWeb = false
            }
            activePane = target == .primary ? .primary : .secondary
            return true
        }

        if parts[0] == "web" {
            // WebSearchPane only ever renders in the secondary slot; reject
            // (rather than silently redirect) a drop aimed at primary.
            guard target == .secondary else { return false }
            let webParts = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            let title = webParts.first ?? "Web"
            let homeURL = webParts.count > 1 ? webParts[1] : parts[1]
            applyPaneTarget(.web(title: title, homeURL: homeURL), to: .secondary)
            return true
        }

        guard parts[0] == "notebook",
              let targetNotebook = notebooks.first(where: {
                  String(describing: $0.persistentModelID) == parts[1] && !$0.isTrashed
              }) else { return false }
        if target == .primary {
            primaryOverrideNotebook = targetNotebook
            primaryFlashcardDeck = nil
            primaryPageIndex = 0
        } else {
            secondaryNotebook = targetNotebook
            secondaryFlashcardDeck = nil
            secondaryShowsWeb = false
            secondaryPageIndex = 0
        }
        activePane = target == .primary ? .primary : .secondary
        return true
    }

    private func completeSplitSelection(object: Any) {
        splitMode = pendingSplitMode ?? .horizontal
        splitRatio = 0.5
        activePane = .secondary
        NotificationCenter.default.post(name: .studiquoOpenNotebookTab, object: object)
        showsSplitSourcePicker = false
    }

    private var activeNotebook: Notebook {
        activePane == .secondary ? (secondaryNotebook ?? displayedPrimaryNotebook) : displayedPrimaryNotebook
    }

    private var activePageIndexBinding: Binding<Int> {
        activePane == .secondary ? $secondaryPageIndex : $primaryPageIndex
    }

    private var activePage: NotePage? {
        let pages = activeNotebook.sortedPages
        let index = activePane == .secondary ? secondaryPageIndex : primaryPageIndex
        return pages.indices.contains(index) ? pages[index] : nil
    }

    private func deleteCurrentPage() {
        let target = activeNotebook
        guard target.pages.count > 1, let page = activePage else { return }
        let deletedIndex = activePane == .secondary ? secondaryPageIndex : primaryPageIndex
        let pageID = page.persistentModelID
        target.pages.removeAll { $0.persistentModelID == pageID }
        page.notebook = nil
        modelContext.delete(page)
        for (order, remaining) in target.sortedPages.enumerated() { remaining.order = order }
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        let nextIndex = min(deletedIndex, target.pages.count - 1)
        if activePane == .secondary { secondaryPageIndex = nextIndex }
        else { primaryPageIndex = nextIndex }
        try? modelContext.save()
    }

    private func trashPendingNotebook() {
        guard let target = notebookPendingTrash else { return }
        target.isTrashed = true
        target.trashedAt = .now
        target.updatedAt = .now
        notebookPendingTrash = nil
        if target === secondaryNotebook {
            secondaryNotebook = nil
            secondaryShowsFlashcards = false
            splitMode = .single
            activePane = .primary
        } else if target === notebook {
            onHome()
        }
    }

    private func createCompanionNotebook() -> Notebook {
        let companion = Notebook(title: "(notebook.title) ノート")
        let page = NotePage(order: 0)
        page.notebook = companion
        companion.pages.append(page)
        companion.refreshLibraryMetadata()
        modelContext.insert(companion)
        return companion
    }

    private func requestPageAddition(to target: Notebook) {
        notebookPendingNewPage = target
    }

    /// Appends a blank page immediately, carrying over the last page's
    /// template — matching GoodNotes' pull-past-the-bottom gesture, which
    /// never interrupts with a style picker.
    private func quickAddPage(to target: Notebook) {
        let newPage = NotePage(order: target.pages.count)
        newPage.pageTemplate = target.sortedPages.last?.pageTemplate ?? .blank
        newPage.notebook = target
        target.pages.append(newPage)
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        if target === secondaryNotebook {
            secondaryPageIndex = target.pages.count - 1
            activePane = .secondary
        } else {
            primaryPageIndex = target.pages.count - 1
            activePane = .primary
        }
    }

    /// The mirror of `quickAddPage`, for pulling past the top instead of
    /// the bottom: prepends a blank page and shifts every existing page's
    /// order down by one to make room for it at the front.
    private func quickAddPageAtTop(to target: Notebook) {
        let template = target.sortedPages.first?.pageTemplate ?? .blank
        for page in target.pages { page.order += 1 }
        let newPage = NotePage(order: 0)
        newPage.pageTemplate = template
        newPage.notebook = target
        target.pages.append(newPage)
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        if target === secondaryNotebook {
            secondaryPageIndex = 0
            activePane = .secondary
        } else {
            primaryPageIndex = 0
            activePane = .primary
        }
    }

    private func addPendingPage(template: PageTemplate) {
        guard let target = notebookPendingNewPage else { return }
        let newPage = NotePage(order: target.pages.count)
        newPage.pageTemplate = template
        newPage.notebook = target
        target.pages.append(newPage)
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        if target === secondaryNotebook {
            secondaryPageIndex = target.pages.count - 1
            activePane = .secondary
        } else {
            primaryPageIndex = target.pages.count - 1
            activePane = .primary
        }
        notebookPendingNewPage = nil
    }

    private func applyTemplate(_ template: PageTemplate) {
        let pages = notebook.sortedPages
        guard pages.indices.contains(primaryPageIndex), pages[primaryPageIndex].backgroundImageData == nil else { return }
        pages[primaryPageIndex].pageTemplate = template
        notebook.updatedAt = .now
    }

    private var currentPrimaryPage: NotePage? {
        let pages = displayedPrimaryNotebook.sortedPages
        guard pages.indices.contains(primaryPageIndex) else { return nil }
        return pages[primaryPageIndex]
    }

    private func addTextElement() {
        let value = textToInsert.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let page = currentPrimaryPage else { return }
        let element = PageElement(kind: .text, text: value, width: 0.42, height: 0.12, colorHex: selectedElementColorHex)
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        notebook.updatedAt = .now
        textToInsert = ""
    }

    private func addRecognizedTextElement(from page: NotePage) {
        let value = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let element = PageElement(kind: .text, text: value, centerY: 0.45, width: 0.62, height: 0.3, colorHex: selectedElementColorHex)
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        notebook.updatedAt = .now
    }

    @MainActor
    private func addImageElement(from item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let page = currentPrimaryPage else { return }
        let element = PageElement(kind: .image, imageData: data, width: 0.42, height: 0.28)
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        notebook.updatedAt = .now
    }

    @MainActor
    private func applyBackgroundImage(from item: PhotosPickerItem) async {
        defer { selectedBackgroundPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let page = currentPrimaryPage else { return }
        page.backgroundImageData = image.jpegData(compressionQuality: 0.92)
        page.pageWidth = max(100, image.size.width)
        page.pageHeight = max(100, image.size.height)
        page.notebook?.refreshLibraryMetadata()
        notebook.updatedAt = .now
    }

    /// Arms the shape tool for rectangle/ellipse/line: the shape itself
    /// isn't created here — `InkCanvasView` draws it live once the user
    /// drags on the canvas with the pencil, sized to that drag. `studyTape`
    /// isn't a drawn shape, so it still gets placed immediately.
    private func addShapeElement(_ kind: PageElementKind) {
        guard let page = currentPrimaryPage else { return }
        if [.rectangle, .ellipse, .line].contains(kind) {
            isReadOnlyMode = false
            pendingShapeKindRaw = kind.rawValue
            drawingToolRaw = DrawingToolKind.none.rawValue
            return
        }
        let element = PageElement(
            kind: kind,
            centerY: 0.3,
            width: kind == .line ? 0.45 : 0.3,
            height: kind == .line ? 0.04 : 0.18,
            colorHex: selectedElementColorHex
        )
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        notebook.updatedAt = .now
    }

    private func addPageLink(to pageIndex: Int, title: String) {
        guard let page = currentPrimaryPage else { return }
        let label = title.isEmpty ? "ページ \(pageIndex + 1)へ" : title
        let element = PageElement(kind: .pageLink, text: "\(pageIndex)|\(label)", width: 0.38, height: 0.08, colorHex: "#1565C0")
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        notebook.updatedAt = .now
    }

    private func nextLayerIndex(on page: NotePage) -> Double {
        (page.elements.map(\.layerIndex).max() ?? -1) + 1
    }

    private func elementLayerTitle(_ element: PageElement) -> String {
        if element.kind == .text {
            let preview = element.text.prefix(12)
            return preview.isEmpty ? "テキスト" : String(preview)
        }
        return element.kind.title
    }

    private func moveElementToFront(_ element: PageElement, on page: NotePage) {
        element.layerIndex = (page.elements.map(\.layerIndex).max() ?? 0) + 1
        notebook.updatedAt = .now
    }

    private func moveElementToBack(_ element: PageElement, on page: NotePage) {
        element.layerIndex = (page.elements.map(\.layerIndex).min() ?? 0) - 1
        notebook.updatedAt = .now
    }

    private func removeElement(_ element: PageElement, from page: NotePage) {
        page.elements.removeAll { $0 === element }
        modelContext.delete(element)
        notebook.updatedAt = .now
    }

    private func limitedRatio(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.3), 0.7)
    }

    private func clamped(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    private func recognizeCurrentPage() {
        guard let page = currentPrimaryPage else { return }
        runRecognition(for: [page])
    }

    private func recognizeAllPages() {
        runRecognition(for: notebook.sortedPages)
    }

    private func runRecognition(for pages: [NotePage]) {
        guard !pages.isEmpty, !isRecognizingHandwriting else { return }
        isRecognizingHandwriting = true
        Task {
            for (offset, page) in pages.enumerated() {
                recognitionProgress = "手書き文字を認識中… \(offset + 1)/\(pages.count)"
                page.recognizedText = await HandwritingRecognitionService.recognize(
                    drawingData: page.drawingData,
                    pageSize: CGSize(width: page.pageWidth, height: page.pageHeight)
                )
                page.textRecognitionDate = .now
            }
            notebook.updatedAt = .now
            recognitionProgress = ""
            isRecognizingHandwriting = false
        }
    }
}

/// Pinch-zoom + pan for one pane, backed by a real `UIScrollView`
/// (`ZoomableScrollView`).
///
/// This used to apply `.scaleEffect`/`.offset` driven by SwiftUI gestures.
/// Device instrumentation showed the pan gesture never fired at all — even
/// at 5× zoom — because the page list's own `UIScrollView` owns the touch and
/// a SwiftUI gesture layered outside it can't take that ownership. See
/// `ZoomableScrollView` for the full explanation.
private struct ZoomableWorkspace<Content: View>: View {
    let size: CGSize
    private let content: Content

    @State private var zoomScale: CGFloat = 1

    init(size: CGSize, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    private var isZoomed: Bool { zoomScale > 1.01 }

    var body: some View {
        ZoomableScrollView(onZoomChange: { zoomScale = $0 }) {
            content
                // The page list stays scrollable while zoomed so you can move
                // between pages without zooming back out. Two nested scroll
                // views are fine here — UIKit arbitrates them natively now
                // that no SwiftUI gesture is competing for the same touch.
                .environment(\.paneIsZoomed, isZoomed)
                .overlay(alignment: .topTrailing) {
                    if isZoomed {
                        Text("\(Int(zoomScale * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                }
        }
        .clipped()
    }
}

@MainActor
private final class WebBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.suppressesIncrementalRendering = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.scrollView.decelerationRate = .normal
        return view
    }()
    @Published var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    func prepare() {
        _ = webView
    }

    func openHomeIfNeeded(_ homeURL: String) {
        prepare()
        guard let destination = URL(string: homeURL) else { return }
        if webView.url?.host == destination.host { return }
        load(homeURL)
    }

    func load(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let url: URL?
        if let direct = URL(string: value), ["http", "https"].contains(direct.scheme?.lowercased() ?? "") {
            url = direct
        } else if !value.contains(" "), value.contains("."), let direct = URL(string: "https://\(value)") {
            url = direct
        } else {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: value)]
            url = components?.url
        }

        guard let url else { return }
        address = value
        isLoading = true
        let request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 30
        )
        webView.load(request)
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateState(from: webView)
    }

    private func updateState(from webView: WKWebView) {
        address = webView.url?.absoluteString ?? address
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

private struct WebSearchPane: View {
    @ObservedObject var browser: WebBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: browser.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!browser.canGoBack)

                Button(action: browser.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!browser.canGoForward)

                Button(action: browser.reload) {
                    Image(systemName: "arrow.clockwise")
                }

                TextField("検索、またはURLを入力", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { browser.load(browser.address) }

                Button {
                    browser.load(browser.address)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            .padding(8)
            .background(.regularMaterial)

            if browser.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            WebViewContainer(webView: browser.webView)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private enum SplitMode: Equatable {
    case single
    case horizontal
    case vertical

    var icon: String {
        switch self {
        case .single: "rectangle"
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        }
    }
}

private struct SplitSourcePicker: View {
    let notebooks: [Notebook]
    let flashcardDecks: [FlashcardDeck]
    let primaryNotebook: Notebook
    let onSelectNotebook: (Notebook) -> Void
    let onSelectDeck: (FlashcardDeck) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showsNewNotebookAlert = false
    @State private var showsNewDeckAlert = false
    @State private var newItemName = ""

    private var available: [Notebook] { notebooks.filter { !$0.isTrashed && $0 !== primaryNotebook } }

    var body: some View {
        NavigationStack {
            List {
                Section("ノート・PDF") {
                    ForEach(available) { notebook in
                        Button {
                            onSelectNotebook(notebook)
                        } label: {
                            Label(notebook.title, systemImage: notebook.containsPDF ? "doc.richtext" : "note.text")
                        }
                    }
                }
                Section("暗記カード") {
                    ForEach(flashcardDecks) { deck in
                        Button {
                            onSelectDeck(deck)
                        } label: {
                            VStack(alignment: .leading) {
                                Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                                Text("\(deck.cards.count)枚")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("分割して開くものを選択")
            .searchable(text: .constant(""), prompt: "ノート、PDF、暗記カード")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button {
                            newItemName = ""
                            showsNewNotebookAlert = true
                        } label: {
                            Label("新規ノート", systemImage: "note.text.badge.plus")
                        }
                        Button {
                            newItemName = ""
                            showsNewDeckAlert = true
                        } label: {
                            Label("新規暗記帳", systemImage: "rectangle.on.rectangle.angled")
                        }
                    } label: {
                        Label("新規作成", systemImage: "plus")
                    }
                }
            }
        }
        .alert("新規ノート", isPresented: $showsNewNotebookAlert) {
            TextField("ノート名", text: $newItemName)
            Button("キャンセル", role: .cancel) {}
            Button("作成して開く", action: createNotebook)
        }
        .alert("新規暗記帳", isPresented: $showsNewDeckAlert) {
            TextField("暗記帳名", text: $newItemName)
            Button("キャンセル", role: .cancel) {}
            Button("作成して開く", action: createDeck)
        }
    }

    private func createNotebook() {
        let title = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: title.isEmpty ? "新しいノート" : title)
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.pages.append(page)
        modelContext.insert(notebook)
        onSelectNotebook(notebook)
    }

    private func createDeck() {
        let title = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = FlashcardDeck(title: title.isEmpty ? "新しい暗記帳" : title)
        modelContext.insert(deck)
        onSelectDeck(deck)
    }
}

private struct FlashcardPaneView: View {
    @Bindable var deck: FlashcardDeck
    @Environment(\.modelContext) private var modelContext
    @State private var index = 0
    @State private var showsAnswer = false
    @State private var mode: FlashcardPaneMode = .study
    @State private var question = ""
    @State private var answer = ""

    private var cards: [Flashcard] {
        deck.sortedCards
    }

    private var canCreateCard: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if mode == .study {
                    Text(cards.isEmpty ? "0 / 0" : "\(index + 1) / \(cards.count)")
                        .font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.bar)

            Picker("モード", selection: $mode) {
                ForEach(FlashcardPaneMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if mode == .create {
                creator
            } else if cards.indices.contains(index) {
                let card = cards[index]
                VStack(spacing: 20) {
                    Text(deck.reversesQuestionAndAnswer ? card.answer : card.question).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Divider()
                    if showsAnswer {
                        Text(deck.reversesQuestionAndAnswer ? card.question : card.answer)
                            .multilineTextAlignment(.center)
                    } else {
                        Button("答えを見る") { showsAnswer = true }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()

                HStack {
                    Button { index = max(0, index - 1); showsAnswer = false } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                    Spacer()
                    Button { index = min(cards.count - 1, index + 1); showsAnswer = false } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= cards.count - 1)
                }
                .padding()
            } else {
                ContentUnavailableView("暗記カードがありません", systemImage: "rectangle.on.rectangle.angled")
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var creator: some View {
        Form {
            Section("新規暗記カード") {
                TextField("問題", text: $question, axis: .vertical)
                    .lineLimit(2...5)
                TextField("答え", text: $answer, axis: .vertical)
                    .lineLimit(2...5)
                Button("このカードを保存して次へ", action: createCard)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreateCard)
            }
            Section("作成済みカード（\(cards.count)枚）") {
                ForEach(Array(cards.enumerated()), id: \.element.persistentModelID) { cardIndex, card in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(cardIndex + 1). \(card.question)").font(.subheadline).lineLimit(1)
                        Text(card.answer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .swipeActions {
                        Button("削除", role: .destructive) { delete(card) }
                    }
                }
            }
        }
    }

    private func createCard() {
        guard canCreateCard else { return }
        let card = Flashcard(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            order: deck.cards.count
        )
        card.deck = deck
        deck.cards.append(card)
        deck.updatedAt = .now
        modelContext.insert(card)
        question = ""
        answer = ""
    }

    private func delete(_ card: Flashcard) {
        deck.cards.removeAll { $0 === card }
        modelContext.delete(card)
        for (cardIndex, remaining) in deck.sortedCards.enumerated() { remaining.order = cardIndex }
        deck.updatedAt = .now
        index = min(index, max(0, deck.cards.count - 1))
    }
}

private enum FlashcardPaneMode: String, CaseIterable, Identifiable {
    case study, create
    var id: String { rawValue }
    var title: String {
        switch self {
        case .study: "暗記する"
        case .create: "カード作成"
        }
    }
}

private struct PageDeletionPicker: View {
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List(Array(notebook.sortedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                Button {
                    let id = pageID(page)
                    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
                } label: {
                    HStack {
                        Image(systemName: selectedIDs.contains(pageID(page)) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(page.title.isEmpty ? "ページ \(index + 1)" : page.title)
                            Text(page.isBookmarked ? "ブックマーク済み" : "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("削除するページを選択")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("削除", role: .destructive, action: deleteSelected)
                        .disabled(selectedIDs.isEmpty || selectedIDs.count >= notebook.pages.count)
                }
            }
        }
    }

    private func pageID(_ page: NotePage) -> String { String(describing: page.persistentModelID) }

    private func deleteSelected() {
        guard !selectedIDs.isEmpty, selectedIDs.count < notebook.pages.count else { return }
        let removed = notebook.pages.filter { selectedIDs.contains(pageID($0)) }
        notebook.pages.removeAll { selectedIDs.contains(pageID($0)) }
        removed.forEach {
            $0.notebook = nil
            modelContext.delete($0)
        }
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }
        notebook.refreshLibraryMetadata()
        notebook.updatedAt = .now
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
        try? modelContext.save()
        dismiss()
    }
}

private struct NotebookPaneView: View {
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    var showsTitle = false
    var usesDarkPageDisplay = false
    let onRequestAddPage: () -> Void
    var onQuickAddPage: () -> Void = {}
    var onQuickAddPageAtTop: () -> Void = {}
    @State private var pageViewMode: PageViewMode = .continuous

    var body: some View {
        let pages = notebook.sortedPages

        VStack(spacing: 0) {
            if showsTitle {
                HStack {
                    Image(systemName: notebook.pages.contains(where: { $0.backgroundImageData != nil }) ? "doc.richtext" : "note.text")
                    Text(notebook.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button(action: onRequestAddPage) {
                        Image(systemName: "plus.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help("このノートにページを追加")
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.bar)
            }

            if !pages.isEmpty {
                pageContent(pages)
            } else {
                ContentUnavailableView("ページがありません", systemImage: "doc")
            }

            pageNavigator(pages: pages)
        }
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func pageContent(_ pages: [NotePage]) -> some View {
        switch pageViewMode {
        case .continuous:
            ContinuousPagesView(
                pages: pages,
                currentPageIndex: $currentPageIndex,
                usesDarkPageDisplay: usesDarkPageDisplay,
                onAddPage: onQuickAddPage,
                onAddPageAtTop: onQuickAddPageAtTop
            )
        case .horizontal:
            HorizontalPagesView(pages: pages, currentPageIndex: $currentPageIndex, usesDarkPageDisplay: usesDarkPageDisplay)
        case .spread:
            SpreadPagesView(pages: pages, currentPageIndex: $currentPageIndex, usesDarkPageDisplay: usesDarkPageDisplay)
        case .overview2, .overview4, .overview6:
            PageOverviewView(pages: pages, currentPageIndex: $currentPageIndex, columns: pageViewMode.columnCount)
        }
    }

    private func pageNavigator(pages: [NotePage]) -> some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(PageViewMode.allCases) { mode in
                    Button {
                        pageViewMode = mode
                    } label: {
                        if pageViewMode == mode { Label(mode.title, systemImage: "checkmark") }
                        else { Label(mode.title, systemImage: mode.icon) }
                    }
                }
            } label: {
                Image(systemName: pageViewMode.icon)
            }

            Button {
                currentPageIndex = max(0, currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPageIndex == 0)

            Text("\(pages.isEmpty ? 0 : currentPageIndex + 1) / \(pages.count)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 56)

            Button {
                currentPageIndex = min(pages.count - 1, currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(pages.isEmpty || currentPageIndex >= pages.count - 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

}

private enum PageViewMode: String, CaseIterable, Identifiable {
    case continuous, horizontal, spread, overview2, overview4, overview6
    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous: "縦連続"
        case .horizontal: "横ページ送り"
        case .spread: "2ページ見開き"
        case .overview2: "2ページ一覧"
        case .overview4: "4ページ一覧"
        case .overview6: "6ページ一覧"
        }
    }

    var icon: String {
        switch self {
        case .continuous: "rectangle.stack"
        case .horizontal: "rectangle.portrait.on.rectangle.portrait"
        case .spread: "book.pages"
        case .overview2: "rectangle.split.2x1"
        case .overview4: "square.grid.2x2"
        case .overview6: "rectangle.grid.3x2"
        }
    }

    var columnCount: Int {
        switch self {
        case .overview2: 2
        case .overview4: 4
        case .overview6: 6
        default: 1
        }
    }
}

private struct BottomAdderMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct TopAdderMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = -.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PagesContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Must be `max`, not a plain assignment: SwiftUI folds this key over
        // the whole subtree, and branches that never set it contribute the
        // default 0. A plain assignment lets one of those zeros land last and
        // wipe out the real measurement — which is exactly what happened, and
        // left the "is the content taller than the viewport?" guard below
        // permanently false, so the pull-to-add gesture never armed.
        value = max(value, nextValue())
    }
}

private struct ContinuousPagesView: View {
    let pages: [NotePage]
    @Binding var currentPageIndex: Int
    let usesDarkPageDisplay: Bool
    let onAddPage: () -> Void
    var onAddPageAtTop: () -> Void = {}

    @State private var scrollTarget: Int?
    @State private var bottomPullProgress: CGFloat = 0
    @State private var hasTriggeredPageAdd = false
    @State private var pullHoldStartedAt: Date?
    @State private var topPullProgress: CGFloat = 0
    @State private var hasTriggeredTopPageAdd = false
    @State private var topPullHoldStartedAt: Date?
    @State private var contentHeight: CGFloat = 0
    /// Rubber-band overscroll needed to fill the gauge. UIKit damps
    /// overscroll heavily, so this is deliberately smaller than the finger
    /// travel it corresponds to.
    private static let pullThreshold: CGFloat = 150
    /// How long the gauge must stay full before a page is added.
    private static let pullHoldDuration: TimeInterval = 0.2
    private static let contentBottomPadding: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(240, geometry.size.width - 32)

            ScrollView(.vertical) {
                LazyVStack(spacing: 18) {
                    TopPageAdder(progress: topPullProgress)
                        .contentShape(Rectangle())
                        .onTapGesture { onAddPageAtTop() }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TopAdderMinYPreferenceKey.self,
                                    value: proxy.frame(in: .named("notePagesScroll")).minY
                                )
                            }
                        )
                    ForEach(Array(pages.enumerated()), id: \.element.persistentModelID) { index, page in
                        let aspect = max(page.pageWidth / page.pageHeight, 0.1)

                        VStack(spacing: 6) {
                            PageCanvasContainer(page: page, usesDarkPageDisplay: usesDarkPageDisplay)
                                .frame(width: availableWidth, height: availableWidth / aspect)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .onTapGesture {
                                    currentPageIndex = index
                                    scrollTarget = index
                                }

                            Text("\(index + 1) / \(pages.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .id(index)
                    }
                    BottomPageAdder(progress: bottomPullProgress)
                        .contentShape(Rectangle())
                        .onTapGesture { onAddPage() }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BottomAdderMaxYPreferenceKey.self,
                                    value: proxy.frame(in: .named("notePagesScroll")).maxY
                                )
                            }
                        )
                }
                .scrollTargetLayout()
                .padding(.vertical, Self.contentBottomPadding)
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PagesContentHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
            }
            .coordinateSpace(name: "notePagesScroll")
            .scrollPosition(id: $scrollTarget, anchor: .center)
            .scrollIndicators(.visible)
            .onAppear {
                scrollTarget = min(max(currentPageIndex, 0), pages.count - 1)
            }
            .onChange(of: scrollTarget) { _, target in
                if let target, pages.indices.contains(target), target != currentPageIndex {
                    currentPageIndex = target
                }
            }
            .onChange(of: currentPageIndex) { _, index in
                guard pages.indices.contains(index), scrollTarget != index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollTarget = index
                }
            }
            .onPreferenceChange(PagesContentHeightPreferenceKey.self) { contentHeight = $0 }
            .onPreferenceChange(BottomAdderMaxYPreferenceKey.self) { maxY in
                // The gauge is driven purely by how far the scroll view has
                // rubber-banded past its natural bottom — this view installs
                // no gesture of its own.
                //
                // A SwiftUI DragGesture used to sit on this ScrollView to
                // measure the pull directly. It recognised every touch, Apple
                // Pencil included, and took them away from PencilKit
                // mid-stroke, so ink vanished on lift. Reading geometry keeps
                // the whole interaction passive.
                guard maxY.isFinite, contentHeight > geometry.size.height else {
                    if bottomPullProgress != 0 { bottomPullProgress = 0 }
                    hasTriggeredPageAdd = false
                    return
                }

                // `maxY` is the adder's bottom edge in viewport coordinates.
                // At rest it sits one bottom-padding above the viewport edge;
                // pulling further drives it upward, and that gap is the
                // overscroll.
                let restingMaxY = geometry.size.height - Self.contentBottomPadding
                let overscroll = max(0, restingMaxY - maxY)
                let progress = min(overscroll / Self.pullThreshold, 1)
                bottomPullProgress = progress

                // Momentum from a fast scroll slams into the bottom and
                // rebounds within a few frames. A deliberate pull, by
                // contrast, is *held* there. Requiring the gauge to stay full
                // briefly tells the two apart, so coasting to the last page
                // no longer conjures a new one.
                if progress >= 1 {
                    if pullHoldStartedAt == nil { pullHoldStartedAt = Date() }
                    if let started = pullHoldStartedAt,
                       Date().timeIntervalSince(started) >= Self.pullHoldDuration,
                       !hasTriggeredPageAdd {
                        hasTriggeredPageAdd = true
                        onAddPage()
                    }
                } else {
                    pullHoldStartedAt = nil
                    if progress == 0 { hasTriggeredPageAdd = false }
                }
            }
            .onPreferenceChange(TopAdderMinYPreferenceKey.self) { minY in
                // Mirrors the bottom gauge above, but for pulling past the
                // top: the adder is the first thing in the stack, so at
                // rest its top edge sits one top-padding below the
                // viewport's top edge, and pulling down past the top
                // rubber-bands it further down from there.
                guard minY.isFinite, contentHeight > geometry.size.height else {
                    if topPullProgress != 0 { topPullProgress = 0 }
                    hasTriggeredTopPageAdd = false
                    topPullHoldStartedAt = nil
                    return
                }

                let restingMinY = Self.contentBottomPadding
                let overscroll = max(0, minY - restingMinY)
                let progress = min(overscroll / Self.pullThreshold, 1)
                topPullProgress = progress

                if progress >= 1 {
                    attemptTopPageAddIfHeld()
                } else {
                    topPullHoldStartedAt = nil
                    if progress == 0 { hasTriggeredTopPageAdd = false }
                }
            }
            // A steady hold at the top can stop producing new scroll
            // geometry entirely — no finger jitter, no rubber-band spring
            // still settling — so `onPreferenceChange` above may never
            // fire again to notice the hold duration has elapsed. Pulling
            // to the *bottom* usually arrives with a bit of scroll
            // momentum that keeps the rubber band gently springing for a
            // moment, which is enough incidental jitter to re-fire that
            // handler; a deliberate pull-then-hold at the top has no such
            // momentum. Polling here catches the hold either way.
            .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
                guard topPullProgress >= 1 else { return }
                attemptTopPageAddIfHeld()
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func attemptTopPageAddIfHeld() {
        guard !hasTriggeredTopPageAdd else { return }
        if topPullHoldStartedAt == nil { topPullHoldStartedAt = Date() }
        if let started = topPullHoldStartedAt, Date().timeIntervalSince(started) >= Self.pullHoldDuration {
            hasTriggeredTopPageAdd = true
            onAddPageAtTop()
        }
    }
}

private struct TopPageAdder: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(progress >= 1 ? Color.accentColor : Color.secondary)
            }
            .frame(width: 48, height: 48)
            .scaleEffect(progress >= 1 ? 1.12 : 1)
            .opacity(progress > 0.02 ? 1 : 0.38)
            Text(progress >= 1 ? "指を離してページを追加" : "さらに引っ張ってページを追加")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(progress > 0.02 ? 1 : 0.65)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .opacity(progress > 0.001 ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: progress)
    }
}

private struct BottomPageAdder: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: progress >= 1 ? "plus" : "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(progress >= 1 ? Color.accentColor : Color.secondary)
            }
            .frame(width: 48, height: 48)
            .scaleEffect(progress >= 1 ? 1.12 : 1)
            .opacity(progress > 0.02 ? 1 : 0.38)
            Text(progress >= 1 ? "指を離してページを追加" : "さらに引っ張ってページを追加")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(progress > 0.02 ? 1 : 0.65)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .opacity(progress > 0.001 ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: progress)
    }
}

private struct HorizontalPagesView: View {
    let pages: [NotePage]
    @Binding var currentPageIndex: Int
    let usesDarkPageDisplay: Bool
    @State private var scrollTarget: Int?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.persistentModelID) { index, page in
                        FittedPageCanvas(page: page, containerSize: geometry.size, isDark: usesDarkPageDisplay)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollTarget, anchor: .center)
            .scrollIndicators(.hidden)
            .onAppear { scrollTarget = currentPageIndex }
            .onChange(of: scrollTarget) { _, value in
                if let value, pages.indices.contains(value) { currentPageIndex = value }
            }
            .onChange(of: currentPageIndex) { _, value in
                guard pages.indices.contains(value), scrollTarget != value else { return }
                withAnimation { scrollTarget = value }
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

private struct SpreadPagesView: View {
    let pages: [NotePage]
    @Binding var currentPageIndex: Int
    let usesDarkPageDisplay: Bool

    private var leftIndex: Int { (currentPageIndex / 2) * 2 }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                if pages.indices.contains(leftIndex) {
                    FittedPageCanvas(page: pages[leftIndex], containerSize: halfSize(geometry.size), isDark: usesDarkPageDisplay)
                        .onTapGesture { currentPageIndex = leftIndex }
                }
                if pages.indices.contains(leftIndex + 1) {
                    FittedPageCanvas(page: pages[leftIndex + 1], containerSize: halfSize(geometry.size), isDark: usesDarkPageDisplay)
                        .onTapGesture { currentPageIndex = leftIndex + 1 }
                } else {
                    Color.clear.frame(width: halfSize(geometry.size).width)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func halfSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(120, (size.width - 30) / 2), height: max(120, size.height - 20))
    }
}

private struct PageOverviewView: View {
    let pages: [NotePage]
    @Binding var currentPageIndex: Int
    let columns: Int

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 16) {
                ForEach(Array(pages.enumerated()), id: \.element.persistentModelID) { index, page in
                    Button {
                        currentPageIndex = index
                    } label: {
                        VStack(spacing: 5) {
                            PageThumbnail(page: page)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(index == currentPageIndex ? Color.accentColor : .clear, lineWidth: 3)
                                }
                            Text("\(index + 1)").font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Color(.secondarySystemBackground))
    }
}

private struct FittedPageCanvas: View {
    @Bindable var page: NotePage
    let containerSize: CGSize
    let isDark: Bool

    var body: some View {
        let pageAspect = max(page.pageWidth / page.pageHeight, 0.1)
        let containerAspect = max(containerSize.width / max(containerSize.height, 1), 0.1)
        let size = pageAspect > containerAspect
            ? CGSize(width: containerSize.width - 20, height: (containerSize.width - 20) / pageAspect)
            : CGSize(width: (containerSize.height - 20) * pageAspect, height: containerSize.height - 20)

        PageCanvasContainer(page: page, usesDarkPageDisplay: isDark)
            .frame(width: max(80, size.width), height: max(80, size.height))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitDivider: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let onChanged: (CGFloat) -> Void
    @State private var previousTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            Color(.separator)
            Capsule()
                .fill(Color.secondary)
                .frame(
                    width: axis == .horizontal ? 3 : 44,
                    height: axis == .horizontal ? 44 : 3
                )
        }
        .frame(
            width: axis == .horizontal ? 10 : nil,
            height: axis == .vertical ? 10 : nil
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    onChanged(translation - previousTranslation)
                    previousTranslation = translation
                }
                .onEnded { _ in
                    previousTranslation = 0
                }
        )
        .accessibilityLabel("分割位置")
        .accessibilityHint("ドラッグして表示比率を変更します")
    }
}

struct PageCanvasContainer: View {
    @Bindable var page: NotePage
    @Environment(\.modelContext) private var modelContext
    var usesDarkPageDisplay = false
    @State private var drawing = InkDrawing()
    @State private var hasLoadedDrawing = false
    /// Incremented only when this view deliberately swaps `drawing` out, so
    /// InkCanvasRepresentable knows to push it into the canvas. Never bumped
    /// for ink the user just drew — that already lives in the canvas.
    @State private var drawingVersion = 0
    @State private var undoHistory: [InkDrawing] = []
    @State private var redoHistory: [InkDrawing] = []
    @State private var isApplyingHistory = false
    @State private var drawingSaveTask: Task<Void, Never>?
    @State private var canvasDisplaySize: CGSize = .zero
    @State private var backgroundImage: UIImage?
    @State private var loadedBackgroundImageData: Data?
    @AppStorage("drawingTool") private var drawingToolRaw = DrawingToolKind.pen.rawValue
    @AppStorage("drawingColor") private var drawingColorHex = "#1C1C1E"
    @AppStorage("drawingWidth") private var drawingWidth = 4.0
    @AppStorage("eraserWidth") private var eraserWidth = 24.0
    @AppStorage("readOnlyMode") private var isReadOnlyMode = false
    // Key deliberately renamed from the old "scratchOutEnabled" so a fresh
    // default actually reaches existing installs (an @AppStorage default is
    // only used the first time a key is read, so reusing the old key would
    // have kept whatever was already stored under it). Defaults on, and
    // stays toggleable from the drawing bar.
    @AppStorage("scratchOutEnabledV2") private var isScratchOutEnabled = true
    /// Shares the armed shape kind with the toolbar in `NoteEditorView` via
    /// the same `@AppStorage` key — see the property there for why.
    @AppStorage("pendingShapeKind") private var pendingShapeKindRaw = ""

    private var drawingTool: Binding<DrawingToolKind> {
        Binding(
            get: { DrawingToolKind(rawValue: drawingToolRaw) ?? .pen },
            set: { drawingToolRaw = $0.rawValue }
        )
    }

    private var pendingShapeKind: InkCanvasView.ShapeKind? {
        InkCanvasView.ShapeKind(rawValue: pendingShapeKindRaw)
    }

    var body: some View {
        GeometryReader { geometry in
            let aspect = page.pageWidth / page.pageHeight
            let displaySize = fitSize(container: geometry.size, aspect: aspect)

            ZStack {
                Color(.secondarySystemBackground)
                ZStack {
                    ZStack {
                        if let backgroundImage {
                            Image(uiImage: backgroundImage)
                                .resizable()
                                .scaledToFit()
                                .modifier(ConditionalColorInvert(enabled: usesDarkPageDisplay))
                        } else {
                            PageTemplateBackground(template: page.pageTemplate, isDark: usesDarkPageDisplay, paperColorHex: page.paperColorHex)
                        }
                        InkCanvasRepresentable(
                            drawing: $drawing,
                            selectedTool: drawingTool,
                            color: UIColor(Color(hex: drawingColorHex)),
                            width: drawingWidth,
                            eraserWidth: eraserWidth,
                            drawingVersion: drawingVersion,
                            isScratchOutEnabled: isScratchOutEnabled,
                            pendingShapeKind: pendingShapeKind,
                            onActivate: {
                                NotificationCenter.default.post(
                                    name: Notification.Name("StudiquoPageActivated"),
                                    object: page
                                )
                            },
                            onShapeCommitted: {
                                pendingShapeKindRaw = ""
                                drawingToolRaw = DrawingToolKind.pen.rawValue
                            }
                        )
                            .allowsHitTesting(!isReadOnlyMode)
                            .modifier(ConditionalColorInvert(enabled: usesDarkPageDisplay))
                        PageElementsLayer(page: page, isDark: usesDarkPageDisplay)
                            .allowsHitTesting(!isReadOnlyMode)
                    }
                    .frame(width: displaySize.width, height: displaySize.height)

                }
                .frame(width: displaySize.width, height: displaySize.height)
                .background(usesDarkPageDisplay ? Color(white: 0.08) : .white)
                .clipShape(Rectangle())
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                canvasDisplaySize = displaySize
            }
            .onChange(of: displaySize) { _, newSize in
                canvasDisplaySize = newSize
                if hasLoadedDrawing { convertLegacyShapesIfNeeded() }
            }
        }
        .onAppear {
            updateBackgroundImageIfNeeded()
            guard !hasLoadedDrawing else { return }
            if let data = page.drawingData, let loaded = InkDrawing.load(from: data) {
                drawing = loaded
                drawingVersion += 1
                GestureDiagnostics.inkLoaded(strokes: loaded.strokes.count, hadData: true)
            } else {
                GestureDiagnostics.inkLoaded(strokes: 0, hadData: page.drawingData != nil)
            }
            undoHistory.removeAll()
            redoHistory.removeAll()
            hasLoadedDrawing = true
            convertLegacyShapesIfNeeded()
        }
        .onChange(of: page.backgroundImageData) { _, _ in updateBackgroundImageIfNeeded() }
        .onChange(of: drawing) { oldValue, newValue in
            guard hasLoadedDrawing else { return }
            if isApplyingHistory {
                isApplyingHistory = false
            } else if oldValue != newValue {
                undoHistory.append(oldValue)
                if undoHistory.count > 80 { undoHistory.removeFirst() }
                redoHistory.removeAll()
            }
            // An erase must never be visibly undone by anything but the Undo
            // button. Flushing it to `page.drawingData` immediately (instead
            // of the normal debounce used to batch rapid pen samples) closes
            // the window where switching tools right after erasing could
            // observe/reload the pre-erase drawing.
            scheduleDrawingSave(newValue, delay: drawingTool.wrappedValue == .eraser ? .zero : .milliseconds(180))
        }
        .onDisappear { scheduleDrawingSave(drawing, delay: .zero) }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoUndoDrawing)) { notification in
            guard let targetPage = notification.object as? NotePage, targetPage === page else { return }
            undoDrawing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoRedoDrawing)) { notification in
            guard let targetPage = notification.object as? NotePage, targetPage === page else { return }
            redoDrawing()
        }
    }

    private func updateBackgroundImageIfNeeded() {
        guard page.backgroundImageData != loadedBackgroundImageData else { return }
        loadedBackgroundImageData = page.backgroundImageData
        backgroundImage = page.backgroundImageData.flatMap(UIImage.init(data:))
    }

    private func scheduleDrawingSave(_ newDrawing: InkDrawing, delay: Duration = .milliseconds(180)) {
        drawingSaveTask?.cancel()
        drawingSaveTask = Task {
            do {
                if delay != .zero { try await Task.sleep(for: delay) }
            } catch {
                return
            }

            let data = await Task.detached(priority: .utility) {
                try? newDrawing.data()
            }.value
            guard !Task.isCancelled, let data else { return }
            page.drawingData = data
            // Deliberately NOT touching `notebook.updatedAt` here.
            //
            // NoteEditorView holds `@Query(sort: \Notebook.updatedAt)`, so
            // bumping it re-sorts that query, re-evaluates the whole editor
            // body and rebuilds the hosted page views. Doing that on every
            // ink save tore down the PKCanvasView mid-stroke, and PencilKit
            // discarded the stroke — which is why fresh ink never survived.
            // The timestamp is refreshed when the editor goes away instead
            // (see the scenePhase/onDisappear backup hooks).
        }
    }

    private func convertLegacyShapesIfNeeded() {
        guard hasLoadedDrawing, canvasDisplaySize.width > 0, canvasDisplaySize.height > 0 else { return }
        let legacyShapes = page.elements.filter { [.rectangle, .ellipse, .line].contains($0.kind) }
        guard !legacyShapes.isEmpty else { return }

        var addedStrokes: [InkStroke] = []
        for element in legacyShapes {
            if let stroke = shapeStroke(
                kind: element.kind,
                colorHex: element.colorHex,
                center: CGPoint(x: element.centerX, y: element.centerY),
                relativeSize: CGSize(width: element.width, height: element.height),
                rotation: element.rotation
            ) {
                addedStrokes.append(stroke)
            }
        }

        page.elements.removeAll { element in
            legacyShapes.contains { legacy in legacy === element }
        }
        legacyShapes.forEach(modelContext.delete)
        isApplyingHistory = true
        drawing = InkDrawing(strokes: drawing.strokes + addedStrokes)
        drawingVersion += 1
    }

    private func shapeStroke(
        kind: PageElementKind,
        colorHex: String,
        center: CGPoint,
        relativeSize: CGSize,
        rotation: Double
    ) -> InkStroke? {
        guard canvasDisplaySize.width > 0, canvasDisplaySize.height > 0 else { return nil }
        let centerPoint = CGPoint(x: center.x * canvasDisplaySize.width, y: center.y * canvasDisplaySize.height)
        let width = max(24, relativeSize.width * canvasDisplaySize.width)
        let height = max(12, relativeSize.height * canvasDisplaySize.height)
        let localPoints: [CGPoint]

        switch kind {
        case .line:
            localPoints = sampledLine(
                from: CGPoint(x: -width / 2, y: 0),
                to: CGPoint(x: width / 2, y: 0),
                count: 24
            )
        case .rectangle:
            let corners = [
                CGPoint(x: -width / 2, y: -height / 2),
                CGPoint(x: width / 2, y: -height / 2),
                CGPoint(x: width / 2, y: height / 2),
                CGPoint(x: -width / 2, y: height / 2),
                CGPoint(x: -width / 2, y: -height / 2)
            ]
            localPoints = zip(corners, corners.dropFirst()).flatMap { sampledLine(from: $0.0, to: $0.1, count: 14) }
        case .ellipse:
            localPoints = (0...72).map { index in
                let angle = CGFloat(index) / 72 * .pi * 2
                return CGPoint(x: cos(angle) * width / 2, y: sin(angle) * height / 2)
            }
        default:
            return nil
        }

        let radians = CGFloat(rotation) * .pi / 180
        let points = localPoints.map { point in
            CGPoint(
                x: centerPoint.x + point.x * cos(radians) - point.y * sin(radians),
                y: centerPoint.y + point.x * sin(radians) + point.y * cos(radians)
            )
        }
        let controlPoints = points.enumerated().map { index, point in
            InkPoint(location: point, force: 0.6, timeOffset: TimeInterval(index) * 0.008)
        }
        guard controlPoints.count >= 2 else { return nil }
        return InkStroke(points: controlPoints, colorHex: colorHex, width: 3)
    }

    private func sampledLine(from start: CGPoint, to end: CGPoint, count: Int) -> [CGPoint] {
        (0...count).map { index in
            let progress = CGFloat(index) / CGFloat(max(count, 1))
            return CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }

    private func undoDrawing() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(drawing)
        isApplyingHistory = true
        drawing = previous
        drawingVersion += 1
    }

    private func redoDrawing() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(drawing)
        isApplyingHistory = true
        drawing = next
        drawingVersion += 1
    }

    private func fitSize(container: CGSize, aspect: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            return CGSize(width: container.width, height: container.width / aspect)
        }
        return CGSize(width: container.height * aspect, height: container.height)
    }
}

private struct PageElementsLayer: View {
    @Bindable var page: NotePage
    let isDark: Bool

    var body: some View {
        GeometryReader { geometry in
            ForEach(page.elements) { element in
                EditablePageElement(element: element, pageSize: geometry.size, isDark: isDark)
                    .zIndex(element.layerIndex)
            }
        }
    }
}

private struct EditablePageElement: View {
    @Bindable var element: PageElement
    @Environment(\.modelContext) private var modelContext
    let pageSize: CGSize
    let isDark: Bool

    @State private var dragOrigin: CGPoint?
    @State private var sizeOrigin: CGSize?
    @State private var isEditingText = false
    @State private var editedText = ""
    @State private var rotationOrigin: Double?
    @State private var isStudyTapeRevealed = false

    private var elementSize: CGSize {
        CGSize(
            width: max(44, pageSize.width * element.width),
            height: max(28, pageSize.height * element.height)
        )
    }

    var body: some View {
        elementContent
            .frame(width: elementSize.width, height: elementSize.height)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(element.rotation))
            .position(x: pageSize.width * element.centerX, y: pageSize.height * element.centerY)
            .gesture(moveGesture)
            .simultaneousGesture(resizeGesture)
            .simultaneousGesture(rotationGesture)
            .contextMenu {
                if element.kind == .text {
                    Button {
                        editedText = element.text
                        isEditingText = true
                    } label: {
                        Label("テキストを編集", systemImage: "pencil")
                    }
                }
                Menu {
                    ForEach(ElementColorPreset.allCases) { preset in
                        Button {
                            element.colorHex = preset.hex
                            markUpdated()
                        } label: {
                            Label(preset.title, systemImage: element.colorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                } label: {
                    Label("色を変更", systemImage: "paintpalette")
                }
                Button {
                    element.isLocked.toggle()
                    markUpdated()
                } label: {
                    Label(element.isLocked ? "ロックを解除" : "位置をロック", systemImage: element.isLocked ? "lock.open" : "lock")
                }
                Button { bringToFront() } label: { Label("最前面へ", systemImage: "square.3.layers.3d.top.filled") }
                Button { sendToBack() } label: { Label("最背面へ", systemImage: "square.3.layers.3d.bottom.filled") }
                Button {
                    duplicateElement()
                } label: {
                    Label("複製", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    deleteElement()
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
            .alert("テキストを編集", isPresented: $isEditingText) {
                TextField("文字を入力", text: $editedText, axis: .vertical)
                Button("キャンセル", role: .cancel) {}
                Button("保存") { element.text = editedText }
            }
    }

    @ViewBuilder
    private var elementContent: some View {
        let color = Color(hex: element.colorHex)
        switch element.kind {
        case .text:
            Text(element.text)
                .font(.system(size: max(12, elementSize.height * 0.42)))
                .foregroundStyle(isDark && element.colorHex == "#1C1C1E" ? .white : color)
                .multilineTextAlignment(.leading)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.thinMaterial.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4])))
        case .image:
            if let data = element.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo.badge.exclamationmark")
            }
        case .rectangle:
            RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 3)
        case .ellipse:
            Ellipse().stroke(color, lineWidth: 3)
        case .line:
            Rectangle().fill(color).frame(height: 3)
        case .studyTape:
            RoundedRectangle(cornerRadius: 5)
                .fill(isStudyTapeRevealed ? color.opacity(0.12) : color.opacity(0.92))
                .overlay {
                    Text(isStudyTapeRevealed ? "表示中" : "タップで確認")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isStudyTapeRevealed ? color : .white)
                }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { isStudyTapeRevealed.toggle() } }
        case .pageLink:
            let link = pageLinkDetails
            Label(link.title, systemImage: "link")
                .font(.system(size: max(12, elementSize.height * 0.42), weight: .semibold))
                .foregroundStyle(color)
                .underline()
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    NotificationCenter.default.post(name: .studiquoOpenPageLink, object: link.target)
                }
        }
    }

    private var pageLinkDetails: (target: Int, title: String) {
        let parts = element.text.split(separator: "|", maxSplits: 1).map(String.init)
        let target = Int(parts.first ?? "") ?? 0
        return (target, parts.count > 1 ? parts[1] : "ページへ移動")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !element.isLocked else { return }
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: element.centerX, y: element.centerY)
                }
                guard let origin = dragOrigin else { return }
                element.centerX = min(max(origin.x + value.translation.width / max(pageSize.width, 1), 0.03), 0.97)
                element.centerY = min(max(origin.y + value.translation.height / max(pageSize.height, 1), 0.03), 0.97)
                element.page?.notebook?.updatedAt = .now
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var resizeGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !element.isLocked else { return }
                if sizeOrigin == nil {
                    sizeOrigin = CGSize(width: element.width, height: element.height)
                }
                guard let origin = sizeOrigin else { return }
                element.width = min(max(origin.width * value.magnification, 0.08), 0.9)
                element.height = min(max(origin.height * value.magnification, 0.04), 0.9)
                element.page?.notebook?.updatedAt = .now
            }
            .onEnded { _ in sizeOrigin = nil }
    }

    private var rotationGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard !element.isLocked else { return }
                if rotationOrigin == nil { rotationOrigin = element.rotation }
                element.rotation = (rotationOrigin ?? 0) + value.rotation.degrees
                markUpdated()
            }
            .onEnded { _ in rotationOrigin = nil }
    }

    private func duplicateElement() {
        guard let page = element.page else { return }
        let copy = PageElement(
            kind: element.kind,
            text: element.text,
            imageData: element.imageData,
            centerX: min(element.centerX + 0.05, 0.9),
            centerY: min(element.centerY + 0.05, 0.9),
            width: element.width,
            height: element.height,
            rotation: element.rotation,
            colorHex: element.colorHex
        )
        copy.isLocked = element.isLocked
        copy.layerIndex = (page.elements.map(\.layerIndex).max() ?? 0) + 1
        copy.page = page
        page.elements.append(copy)
        page.notebook?.updatedAt = .now
    }

    private func deleteElement() {
        guard let page = element.page else { return }
        page.elements.removeAll { $0 === element }
        modelContext.delete(element)
        page.notebook?.updatedAt = .now
    }

    private func bringToFront() {
        guard let page = element.page else { return }
        element.layerIndex = (page.elements.map(\.layerIndex).max() ?? 0) + 1
        markUpdated()
    }

    private func sendToBack() {
        guard let page = element.page else { return }
        element.layerIndex = (page.elements.map(\.layerIndex).min() ?? 0) - 1
        markUpdated()
    }

    private func markUpdated() {
        element.page?.notebook?.updatedAt = .now
    }
}

private struct NotebookOutlineView: View {
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(notebook.sortedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                Button {
                    currentPageIndex = index
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(page.title.isEmpty ? "無題のページ" : page.title)
                                .foregroundStyle(.primary)
                            if !page.recognizedText.isEmpty {
                                Text(page.recognizedText.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if page.isBookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.yellow) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("目次")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

private struct NotebookSearchView: View {
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var bookmarksOnly = false

    private var results: [(index: Int, page: NotePage)] {
        notebook.sortedPages.enumerated().compactMap { index, page in
            guard !bookmarksOnly || page.isBookmarked else { return nil }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return (index, page) }
            let searchableText = ([page.title, page.recognizedText] + page.elements.filter { $0.kind == .text }.map(\.text)).joined(separator: " ")
            return searchableText.localizedCaseInsensitiveContains(needle) ? (index, page) : nil
        }
    }

    var body: some View {
        NavigationStack {
            List(results, id: \.page.persistentModelID) { result in
                Button {
                    currentPageIndex = result.index
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        PageThumbnail(page: result.page)
                            .frame(width: 62, height: 82)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.page.title.isEmpty ? "ページ \(result.index + 1)" : result.page.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(result.index + 1)ページ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !result.page.recognizedText.isEmpty {
                                Text(result.page.recognizedText.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if result.page.isBookmarked {
                            Image(systemName: "bookmark.fill").foregroundStyle(.yellow)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "ページ名・入力した文字を検索")
            .navigationTitle("ノート内検索")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        bookmarksOnly.toggle()
                    } label: {
                        Label("ブックマーク", systemImage: bookmarksOnly ? "bookmark.fill" : "bookmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        bookmarksOnly ? "該当するブックマークはありません" : "該当するページはありません",
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }
    }
}

private struct PageSidebar: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    let onRequestAddPage: () -> Void
    @State private var pageToRename: NotePage?
    @State private var pageName = ""
    @State private var jumpText = ""
    @State private var isSelectingPages = false
    @State private var selectedPageIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ページ").font(.headline)
                Spacer()
                TextField("番号", text: $jumpText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit { jumpToPage() }
                Button(action: jumpToPage) {
                    Image(systemName: "arrow.right.circle")
                }
                Menu {
                    Button {
                        isSelectingPages.toggle()
                        if !isSelectingPages { selectedPageIDs.removeAll() }
                    } label: {
                        Label(isSelectingPages ? "選択を終了" : "複数ページを選択", systemImage: "checkmark.circle")
                    }
                    if isSelectingPages {
                        Button(action: bookmarkSelectedPages) { Label("選択ページをブックマーク", systemImage: "bookmark") }
                        Button(action: rotateSelectedPages) { Label("選択ページを回転", systemImage: "rotate.right") }
                        Button(action: duplicateSelectedPages) { Label("選択ページを複製", systemImage: "plus.square.on.square") }
                            .disabled(selectedPageIDs.isEmpty)
                        Button(role: .destructive, action: deleteSelectedPages) { Label("選択ページを削除", systemImage: "trash") }
                            .disabled(!canDeleteSelectedPages)
                        Divider()
                    }
                    Button(action: duplicateBookmarkedPages) {
                        Label("ブックマークを一括複製", systemImage: "plus.square.on.square")
                    }
                    .disabled(!notebook.pages.contains(where: \.isBookmarked))
                    Button(role: .destructive, action: deleteBookmarkedPages) {
                        Label("ブックマークを一括削除", systemImage: "trash")
                    }
                    .disabled(!canDeleteBookmarkedPages)
                } label: {
                    Image(systemName: "checklist")
                }
                EditButton()
                Button(action: onRequestAddPage) { Image(systemName: "plus") }
            }
            .padding()

            List {
                ForEach(Array(notebook.sortedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                    HStack {
                        Button {
                            if isSelectingPages {
                                toggleSelection(page)
                            } else {
                                currentPageIndex = index
                            }
                        } label: {
                            VStack(spacing: 5) {
                                ZStack(alignment: .topTrailing) {
                                    PageThumbnail(page: page)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(index == currentPageIndex ? Color.accentColor : .clear, lineWidth: 3)
                                        }
                                    if page.isBookmarked {
                                        Image(systemName: "bookmark.fill")
                                            .foregroundStyle(.yellow)
                                            .padding(5)
                                    }
                                    if selectedPageIDs.contains(pageID(page)) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.tint)
                                            .padding(5)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                    }
                                }
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                pageToRename = page
                                pageName = page.title
                            } label: { Label("ページ名を編集", systemImage: "pencil") }
                            Button { page.isBookmarked.toggle() } label: {
                                Label(page.isBookmarked ? "ブックマーク解除" : "ブックマーク", systemImage: "bookmark")
                            }
                            Button { duplicate(page) } label: { Label("複製", systemImage: "plus.square.on.square") }
                            Button { PageRotationService.rotateClockwise(page) } label: { Label("右へ90度回転", systemImage: "rotate.right") }
                            Button(role: .destructive) { delete(page) } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: movePages)
            }
            .listStyle(.plain)
        }
        .background(.bar)
        .alert("ページ名を編集", isPresented: Binding(
            get: { pageToRename != nil },
            set: { if !$0 { pageToRename = nil } }
        )) {
            TextField("例：第3回 重要事項", text: $pageName)
            Button("キャンセル", role: .cancel) { pageToRename = nil }
            Button("保存") {
                pageToRename?.title = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
                notebook.updatedAt = .now
                pageToRename = nil
            }
        }
    }

    private func jumpToPage() {
        guard let pageNumber = Int(jumpText), notebook.sortedPages.indices.contains(pageNumber - 1) else { return }
        currentPageIndex = pageNumber - 1
        jumpText = ""
    }

    private var canDeleteBookmarkedPages: Bool {
        let count = notebook.pages.filter(\.isBookmarked).count
        return count > 0 && count < notebook.pages.count
    }

    private func duplicateBookmarkedPages() {
        let sources = notebook.sortedPages.filter(\.isBookmarked)
        for source in sources { duplicate(source) }
        currentPageIndex = max(0, notebook.pages.count - sources.count)
    }

    private func deleteBookmarkedPages() {
        guard canDeleteBookmarkedPages else { return }
        let removed = notebook.pages.filter(\.isBookmarked)
        notebook.pages.removeAll(where: \.isBookmarked)
        removed.forEach {
            $0.notebook = nil
            modelContext.delete($0)
        }
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }
        notebook.refreshLibraryMetadata()
        notebook.updatedAt = .now
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
        try? modelContext.save()
    }

    private func pageID(_ page: NotePage) -> String {
        String(describing: page.persistentModelID)
    }

    private func toggleSelection(_ page: NotePage) {
        let id = pageID(page)
        if selectedPageIDs.contains(id) { selectedPageIDs.remove(id) }
        else { selectedPageIDs.insert(id) }
    }

    private var selectedPages: [NotePage] {
        notebook.sortedPages.filter { selectedPageIDs.contains(pageID($0)) }
    }

    private var canDeleteSelectedPages: Bool {
        !selectedPages.isEmpty && selectedPages.count < notebook.pages.count
    }

    private func bookmarkSelectedPages() {
        selectedPages.forEach { $0.isBookmarked = true }
        notebook.updatedAt = .now
    }

    private func rotateSelectedPages() {
        selectedPages.forEach(PageRotationService.rotateClockwise)
    }

    private func duplicateSelectedPages() {
        let pages = selectedPages
        pages.forEach(duplicate)
        selectedPageIDs.removeAll()
    }

    private func deleteSelectedPages() {
        guard canDeleteSelectedPages else { return }
        let ids = selectedPageIDs
        let removed = notebook.pages.filter { ids.contains(pageID($0)) }
        notebook.pages.removeAll { ids.contains(pageID($0)) }
        removed.forEach {
            $0.notebook = nil
            modelContext.delete($0)
        }
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }
        notebook.refreshLibraryMetadata()
        notebook.updatedAt = .now
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
        selectedPageIDs.removeAll()
        try? modelContext.save()
    }

    private func duplicate(_ source: NotePage) {
        let page = NotePage(order: notebook.pages.count, backgroundImageData: source.backgroundImageData, pageWidth: source.pageWidth, pageHeight: source.pageHeight)
        page.drawingData = source.drawingData
        page.templateRawValue = source.templateRawValue
        page.title = source.title
        for sourceElement in source.elements {
            let element = PageElement(
                kind: sourceElement.kind,
                text: sourceElement.text,
                imageData: sourceElement.imageData,
                centerX: sourceElement.centerX,
                centerY: sourceElement.centerY,
                width: sourceElement.width,
                height: sourceElement.height,
                rotation: sourceElement.rotation,
                colorHex: sourceElement.colorHex
            )
            element.isLocked = sourceElement.isLocked
            element.layerIndex = sourceElement.layerIndex
            element.page = page
            page.elements.append(element)
        }
        page.notebook = notebook
        notebook.pages.append(page)
        notebook.updatedAt = .now
        currentPageIndex = notebook.pages.count - 1
    }

    private func delete(_ page: NotePage) {
        guard notebook.pages.count > 1, let index = notebook.pages.firstIndex(where: { $0 === page }) else { return }
        notebook.pages.remove(at: index)
        for (order, remaining) in notebook.sortedPages.enumerated() { remaining.order = order }
        notebook.updatedAt = .now
        currentPageIndex = min(currentPageIndex, notebook.pages.count - 1)
    }

    private func movePages(from source: IndexSet, to destination: Int) {
        let selectedPage = notebook.sortedPages.indices.contains(currentPageIndex)
            ? notebook.sortedPages[currentPageIndex]
            : nil
        var reordered = notebook.sortedPages
        reordered.move(fromOffsets: source, toOffset: destination)
        for (order, page) in reordered.enumerated() {
            page.order = order
        }
        notebook.updatedAt = .now
        if let selectedPage,
           let newIndex = reordered.firstIndex(where: { $0 === selectedPage }) {
            currentPageIndex = newIndex
        }
    }
}

private struct PageThumbnail: View {
    @Bindable var page: NotePage

    var body: some View {
        ZStack {
            if let data = page.backgroundImageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                PageTemplateBackground(template: page.pageTemplate, isDark: false, paperColorHex: page.paperColorHex)
            }
            if let data = page.drawingData, let drawing = InkDrawing.load(from: data) {
                Image(uiImage: drawing.image(from: CGRect(x: 0, y: 0, width: page.pageWidth, height: page.pageHeight), scale: 0.3))
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(page.pageWidth / page.pageHeight, contentMode: .fit)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

private struct PageTemplateBackground: View {
    let template: PageTemplate
    let isDark: Bool
    var paperColorHex = "#FFFFFF"

    var body: some View {
        Canvas { context, size in
            let background = isDark ? Color(white: 0.08) : Color(hex: paperColorHex)
            let line = isDark ? Color.white.opacity(0.18) : Color.blue.opacity(0.18)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

            switch template {
            case .blank:
                break
            case .ruled:
                horizontalLines(context: context, size: size, color: line)
            case .grid:
                horizontalLines(context: context, size: size, color: line)
                verticalLines(context: context, size: size, color: line)
            case .dotted:
                var path = Path()
                for x in stride(from: 24.0, to: size.width, by: 24.0) {
                    for y in stride(from: 24.0, to: size.height, by: 24.0) {
                        path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    }
                }
                context.fill(path, with: .color(line))
            case .cornell:
                horizontalLines(context: context, size: size, color: line)
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.28, y: 0))
                path.addLine(to: CGPoint(x: size.width * 0.28, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * 0.82))
                path.addLine(to: CGPoint(x: size.width, y: size.height * 0.82))
                context.stroke(path, with: .color(isDark ? .white.opacity(0.35) : .red.opacity(0.3)), lineWidth: 1)
            case .weekly:
                weeklyLayout(context: context, size: size, line: line, isDark: isDark)
            case .monthly:
                monthlyLayout(context: context, size: size, line: line, isDark: isDark)
            case .checklist:
                checklistLayout(context: context, size: size, line: line)
            case .musicStaff:
                musicStaffLayout(context: context, size: size, line: line)
            }
        }
    }

    private func horizontalLines(context: GraphicsContext, size: CGSize, color: Color) {
        var path = Path()
        for y in stride(from: 28.0, to: size.height, by: 28.0) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(color), lineWidth: 0.7)
    }

    private func verticalLines(context: GraphicsContext, size: CGSize, color: Color) {
        var path = Path()
        for x in stride(from: 28.0, to: size.width, by: 28.0) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(color), lineWidth: 0.7)
    }

    private func weeklyLayout(context: GraphicsContext, size: CGSize, line: Color, isDark: Bool) {
        let headerHeight = size.height * 0.08
        let rowHeight = (size.height - headerHeight) / 7
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: size))
        for row in 0...7 {
            let y = headerHeight + CGFloat(row) * rowHeight
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        path.move(to: CGPoint(x: size.width * 0.2, y: 0))
        path.addLine(to: CGPoint(x: size.width * 0.2, y: size.height))
        context.stroke(path, with: .color(line), lineWidth: 1)
        let days = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
        for (index, day) in days.enumerated() {
            context.draw(Text(day).font(.system(size: 11, weight: .semibold)).foregroundColor(isDark ? .white.opacity(0.7) : .secondary), at: CGPoint(x: size.width * 0.1, y: headerHeight + (CGFloat(index) + 0.5) * rowHeight))
        }
    }

    private func monthlyLayout(context: GraphicsContext, size: CGSize, line: Color, isDark: Bool) {
        let headerHeight = size.height * 0.1
        let cellWidth = size.width / 7
        let cellHeight = (size.height - headerHeight) / 6
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: size))
        for column in 1..<7 {
            path.move(to: CGPoint(x: CGFloat(column) * cellWidth, y: 0))
            path.addLine(to: CGPoint(x: CGFloat(column) * cellWidth, y: size.height))
        }
        for row in 0...6 {
            let y = headerHeight + CGFloat(row) * cellHeight
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(line), lineWidth: 1)
        for (index, day) in ["M", "T", "W", "T", "F", "S", "S"].enumerated() {
            context.draw(Text(day).font(.system(size: 11, weight: .bold)).foregroundColor(isDark ? .white.opacity(0.7) : .secondary), at: CGPoint(x: (CGFloat(index) + 0.5) * cellWidth, y: headerHeight * 0.5))
        }
    }

    private func checklistLayout(context: GraphicsContext, size: CGSize, line: Color) {
        for y in stride(from: 40.0, to: size.height - 10, by: 34.0) {
            let box = CGRect(x: 20, y: y - 11, width: 16, height: 16)
            context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(line), lineWidth: 1)
            var path = Path()
            path.move(to: CGPoint(x: 50, y: y))
            path.addLine(to: CGPoint(x: size.width - 18, y: y))
            context.stroke(path, with: .color(line), lineWidth: 0.8)
        }
    }

    private func musicStaffLayout(context: GraphicsContext, size: CGSize, line: Color) {
        for top in stride(from: 42.0, to: size.height - 28, by: 94.0) {
            var path = Path()
            for offset in 0..<5 {
                let y = top + CGFloat(offset) * 10
                path.move(to: CGPoint(x: 20, y: y))
                path.addLine(to: CGPoint(x: size.width - 20, y: y))
            }
            context.stroke(path, with: .color(line), lineWidth: 0.8)
        }
    }
}

private struct ConditionalColorInvert: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.colorInvert()
        } else {
            content
        }
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

private enum PaperColorPreset: String, CaseIterable, Identifiable {
    case white, cream, blue, gray, green
    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "白"
        case .cream: "クリーム"
        case .blue: "淡い青"
        case .gray: "淡いグレー"
        case .green: "淡い緑"
        }
    }

    var hex: String {
        switch self {
        case .white: "#FFFFFF"
        case .cream: "#FFF8E7"
        case .blue: "#EEF7FF"
        case .gray: "#F3F4F6"
        case .green: "#F0FAF2"
        }
    }
}

private enum ElementColorPreset: String, CaseIterable, Identifiable {
    case ink, gray, red, orange, yellow, green, blue, purple, pink, white
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink: "黒"
        case .gray: "グレー"
        case .red: "赤"
        case .orange: "オレンジ"
        case .yellow: "黄"
        case .green: "緑"
        case .blue: "青"
        case .purple: "紫"
        case .pink: "ピンク"
        case .white: "白"
        }
    }

    var hex: String {
        switch self {
        case .ink: "#1C1C1E"
        case .gray: "#8E8E93"
        case .red: "#FF3B30"
        case .orange: "#FF9500"
        case .yellow: "#FFCC00"
        case .green: "#34C759"
        case .blue: "#007AFF"
        case .purple: "#AF52DE"
        case .pink: "#FF2D55"
        case .white: "#FFFFFF"
        }
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
