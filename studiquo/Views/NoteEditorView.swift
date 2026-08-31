import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import WebKit
import AudioToolbox
import JavaScriptCore
import UniformTypeIdentifiers
import VisionKit
import Speech
import AVFoundation

extension Notification.Name {
    static let studiquoOpenPageLink = Notification.Name("StudiquoOpenPageLink")
    static let studiquoUndoDrawing = Notification.Name("StudiquoUndoDrawing")
    static let studiquoRedoDrawing = Notification.Name("StudiquoRedoDrawing")
    static let studiquoOpenNotebookTab = Notification.Name("StudiquoOpenNotebookTab")
    static let studiquoRecognizedSelection = Notification.Name("StudiquoRecognizedSelection")
    /// A plain tap landed on the page background. Raised by the ink canvas —
    /// a recogniser there sees both finger and pencil taps without taking
    /// touches away from drawing, which a SwiftUI tap-catcher laid over the
    /// canvas would have done.
    static let studiquoCanvasTapped = Notification.Name("StudiquoCanvasTapped")
    static let studiquoSelectionDropped = Notification.Name("StudiquoSelectionDropped")
    /// Carries a `PageSnippet` the snip tool just cut out of a page.
    static let studiquoPageSnipped = Notification.Name("StudiquoPageSnipped")
    /// Carries the `PersistentIdentifier` of an element that should come up
    /// already showing its resize/rotate chrome.
    static let studiquoSelectPageElement = Notification.Name("StudiquoSelectPageElement")
    /// Editor → ContentView: this conversation is open, give it a tab.
    static let studiquoOpenAIChatTab = Notification.Name("StudiquoOpenAIChatTab")
    /// Editor → ContentView: this conversation is gone, drop its tab.
    static let studiquoCloseAIChatTab = Notification.Name("StudiquoCloseAIChatTab")
    /// ContentView → editor: bring this conversation to the front.
    static let studiquoSelectAIChatTab = Notification.Name("StudiquoSelectAIChatTab")
    /// Broadcasts freshly drawn or erased ink so that a second canvas
    /// showing the *same* page — the split-screen-onto-one-notebook case —
    /// updates live instead of holding a stale copy until it reloads.
    static let studiquoDrawingSynced = Notification.Name("StudiquoDrawingSynced")
}

/// False while both split panes show the same notebook. Dragging a lasso
/// selection from one canvas to another moves the ink — removing it from the
/// source and adding it to the destination — which is incoherent when the
/// two canvases are two views of one notebook, so the transfer is switched
/// off there. Read by `PageCanvasContainer`, set once by `NoteEditorView`.
private struct AllowsInkSelectionTransferKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var allowsInkSelectionTransfer: Bool {
        get { self[AllowsInkSelectionTransferKey.self] }
        set { self[AllowsInkSelectionTransferKey.self] = newValue }
    }
}

private struct AIChatAttachment: Identifiable, Hashable {
    enum Kind: String {
        case file
        case folder
        case camera
        case notebook
        case flashcards
        case document
        case slideDeck
        /// A rectangle cut out of a page — see `PageSnippet`.
        case snippet

        var label: String {
            switch self {
            case .file: return L("ファイル")
            case .folder: return L("フォルダー")
            case .camera: return L("撮影画像")
            case .notebook: return L("ノート・PDF")
            case .flashcards: return L("暗記カード")
            case .document: return L("文書")
            case .slideDeck: return L("スライド")
            case .snippet: return L("切り抜き")
            }
        }

    var icon: String {
        switch self {
        case .file: return "doc"
            case .folder: return "folder"
            case .camera: return "camera"
            case .notebook: return "doc.richtext"
            case .flashcards: return "rectangle.on.rectangle.angled"
            case .document: return "doc.text"
            case .slideDeck: return "rectangle.on.rectangle"
            case .snippet: return "rectangle.dashed"
            }
        }
    }

    /// What a dropped snippet is, as far as the marker is concerned.
    ///
    /// One question and one answer is what turns an ordinary chat message
    /// into a marking request; anything else is just a picture to talk about.
    enum ProofRole: String, CaseIterable, Identifiable {
        case none
        case question
        case answer

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return L("画像として送る")
            case .question: return L("問題")
            case .answer: return L("解答")
            }
        }

        var tint: Color {
            switch self {
            case .none: return .secondary
            case .question: return .indigo
            case .answer: return .teal
            }
        }
    }

    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
    var snippet: PageSnippet?
    var imageData: Data?
    var contextText: String = ""
    var proofRole: ProofRole = .none

    var image: UIImage? {
        if let snippet { return snippet.image }
        if let imageData { return UIImage(data: imageData) }
        return nil
    }
}

struct StudiquoSelectionDrop {
    let text: String
    let screenPoint: CGPoint
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
    case ai(PersistentIdentifier)
    case friend(UUID)
}

/// A web split, once opened, is announced under this name so ContentView can
/// surface it as a tab like any other open notebook/deck.
struct WebTabInfo: Identifiable, Equatable {
    let id: String
    var title: String
    var homeURL: String
}

/// One AI conversation, as the tab bar sees it.
///
/// Each thread gets its own tab rather than all of them sharing one "AI" tab:
/// a conversation about integration and a conversation about a proof are as
/// separate as two notebooks, and switching between them should not mean
/// hunting through a history list.
struct AIChatTabInfo: Identifiable, Equatable {
    let id: PersistentIdentifier
    var title: String
}

private struct AppAttachmentOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let attachment: AIChatAttachment
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
    @Query(sort: \TextDocument.updatedAt, order: .reverse) private var textDocuments: [TextDocument]
    @Query(sort: \SlideDeck.updatedAt, order: .reverse) private var slideDecks: [SlideDeck]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var splitState: EditorSplitState
    @EnvironmentObject private var friendStore: FriendStore
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
    @State private var isPortraitLayout = false
    /// Orientation at the previous layout pass; `nil` until the first one.
    /// Lets `updateOrientation` tell a genuine rotation apart from a plain
    /// re-layout — see the collapse rule there.
    @State private var lastKnownPortrait: Bool?
    /// The page the pencil last touched. Undo/redo target this rather than
    /// whichever page the scroll position happens to have centred, which in
    /// continuous mode is regularly a different page from the one just
    /// drawn on.
    @State private var lastActivePage: NotePage?
    @State private var recognizedSelectionDragText = ""
    @State private var selectionTransferImage: UIImage?
    @State private var selectionTransferSize: CGSize?
    @State private var selectionTransferPoint: CGPoint?
    @State private var activePane: ActivePane = .primary
    @State private var pendingSplitMode: SplitMode?
    @State private var showsSplitSourcePicker = false
    @State private var primaryShowsAIChat = false
    @State private var secondaryShowsWeb = false
    @State private var secondaryShowsAIChat = false
    @State private var primaryFriendChatID: UUID?
    @State private var secondaryFriendChatID: UUID?
    @State private var showsTemporaryAIChat = false
    @State private var aiChatThreads: [AIChatThread] = []
    @State private var selectedAIChatThread: AIChatThread?
    @State private var aiChatDrafts: [String: String] = [:]
    @State private var aiChatAttachments: [String: [AIChatAttachment]] = [:]
    @State private var aiChatContextOverrides: [String: String] = [:]
    /// Regions cut out with the snip tool, waiting to be dragged into a chat.
    @State private var snippetTray: [PageSnippet] = []
    @State private var pendingProofQuestionSnippet: PageSnippet?
    @State private var pendingProofAnswerSnippet: PageSnippet?
    @State private var aiChatRespondingThreadIDs: Set<String> = []
    @State private var aiChatTasks: [String: Task<Void, Never>] = [:]
    @State private var secondaryFlashcardDeck: FlashcardDeck?
    @State private var showsDeletePagePicker = false
    @State private var notebookPendingTrash: Notebook?
    @State private var notebookPendingNewPage: Notebook?
    @State private var pdfExportDocument: PDFExportDocument?
    @State private var pdfExportFilename = "ノート.pdf"
    @State private var showsPDFExporter = false
    @State private var showsPageSidebar = false
    @State private var usesDarkPageDisplay = false
    @State private var isShowingTextAlert = false
    @State private var textToInsert = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedBackgroundPhotoItem: PhotosPickerItem?
    @State private var isRecognizingHandwriting = false
    @State private var recognitionProgress = ""
    @State private var isFocusMode = false
    @State private var showsStudySession = false
    @State private var showsOutline = false
    @State private var showsTimeTool = false
    @State private var timeToolModel = TimeToolModel()
    @State private var showsCalculator = false
    @State private var calculatorExpression = ""
    @State private var calculatorResult = "0"
    @State private var calculatorCenter: CGPoint?
    @State private var calculatorDragOrigin: CGPoint?
    @State private var temporaryAIChatCenter: CGPoint?
    @State private var temporaryAIChatDragOrigin: CGPoint?
    @State private var temporaryAIChatSize: CGSize?
    @State private var temporaryAIChatResizeOrigin: CGSize?
    // The pen bar's position now lives inside `FloatingDrawingToolbar`, so a
    // drag no longer invalidates this whole view.
    /// True while a finger is on the size slider. The slider sits inside the
    /// toolbar's own `ScrollView`, so without this its drag was ambiguous
    /// with the ScrollView's pan gesture — moving the slider could instead
    /// scroll the toolbar's contents out from under the thumb.
    @State private var isAdjustingToolSize = false
    @State private var showsToolSizePopover = false
    @AppStorage("readOnlyMode") private var isReadOnlyMode = false
    @AppStorage("leftHandedMode") private var isLeftHandedMode = false
    @AppStorage("drawingToolbarPosition") private var drawingToolbarPosition = "bottom"
    @AppStorage("showDrawingToolbar") private var showsDrawingToolbar = true
    @AppStorage("drawingTool") private var drawingToolRaw = DrawingToolKind.pen.rawValue
    @AppStorage("drawingColor") private var drawingColorHex = "#1C1C1E"
    @AppStorage("drawingWidth") private var drawingWidth = 4.0
    @AppStorage("eraserWidth") private var eraserWidth = 24.0
    @AppStorage("lineCorrectionEnabled") private var isLineCorrectionEnabled = true
    @AppStorage("ellipseCorrectionEnabled") private var isEllipseCorrectionEnabled = true
    @AppStorage("rectangleCorrectionEnabled") private var isRectangleCorrectionEnabled = true
    @AppStorage("triangleCorrectionEnabled") private var isTriangleCorrectionEnabled = true
    @AppStorage("parabolaCorrectionEnabled") private var isParabolaCorrectionEnabled = true
    @AppStorage("curveCorrectionEnabled") private var isCurveCorrectionEnabled = true
    /// Armed shape kind ("" for none) for the drag-to-create shape tool.
    /// Shared via the same `@AppStorage` key with `PageCanvasContainer`, the
    /// same pattern `drawingToolRaw` already uses to reach the active page's
    /// canvas without a direct reference to it.
    @AppStorage("pendingShapeKind") private var pendingShapeKindRaw = ""
    @AppStorage("selectedElementColor") private var selectedElementColorHex = "#1C1C1E"

    var body: some View {
        GeometryReader { geometry in
            let editorFrame = geometry.frame(in: .global)
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
                    workspace(in: workspaceSize(in: geometry.size))
                        .environment(\.allowsInkSelectionTransfer, !panesShowSameNotebook)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                // Kept in the hierarchy and shown by opacity rather than
                // inserted by an `if`, so toggling it doesn't re-lay out
                // the ZStack — and so the toolbar beside it isn't rebuilt —
                // on every show and hide.
                let showsSizePreview = isAdjustingToolSize && showsToolSizeControl
                toolSizePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .opacity(showsSizePreview ? 1 : 0)
                    .scaleEffect(showsSizePreview ? 1 : 0.92)
                    .animation(.easeOut(duration: 0.15), value: showsSizePreview)
                    .zIndex(2500)

                if !recognizedSelectionDragText.isEmpty {
                    recognizedSelectionDragChip
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .zIndex(1000)
                }

                if let image = selectionTransferImage,
                   let size = selectionTransferSize,
                   let point = selectionTransferPoint {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .position(x: point.x - editorFrame.minX, y: point.y - editorFrame.minY)
                        .allowsHitTesting(false)
                        .zIndex(2000)
                }

                if showsCalculator {
                    ScientificCalculatorPanel(
                        expression: $calculatorExpression,
                        result: $calculatorResult,
                        center: $calculatorCenter,
                        containerSize: geometry.size,
                        onClose: { showsCalculator = false }
                    )
                        .zIndex(3000)
                }

                if showsTemporaryAIChat {
                    temporaryAIChatPanel(in: geometry.size)
                        .zIndex(3100)
                }
            }
            .clipped()
            .onAppear { updateOrientation(for: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in
                updateOrientation(for: newSize)
            }
        }
        .navigationTitle(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isFocusMode { editorToolStrip }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoRecognizedSelection)) { notification in
            recognizedSelectionDragText = notification.object as? String ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoSelectionDragMoved"))) { notification in
            selectionTransferImage = notification.object as? UIImage
            selectionTransferPoint = (notification.userInfo?["point"] as? NSValue)?.cgPointValue
            selectionTransferSize = (notification.userInfo?["size"] as? NSValue)?.cgSizeValue
        }
        .modifier(PDFSaveModifier(
            isPresented: $showsPDFExporter,
            document: $pdfExportDocument,
            filename: pdfExportFilename
        ))
        .sheet(isPresented: $showsStudySession) {
            StudySessionView(notebook: notebook)
        }
        .sheet(isPresented: $showsOutline) {
            NotebookOutlineView(notebook: notebook, currentPageIndex: $primaryPageIndex)
        }
        .sheet(isPresented: $showsTimeTool) {
            TimeToolView(model: timeToolModel)
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
                secondaryShowsAIChat = false
                secondaryPageIndex = 0
                completeSplitSelection(object: selected)
            }, onSelectDeck: { deck in
                secondaryNotebook = nil
                secondaryFlashcardDeck = deck
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
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
        .sheet(
            isPresented: Binding(
                get: { notebookPendingNewPage != nil },
                set: { if !$0 { notebookPendingNewPage = nil } }
            )
        ) {
            PageTemplatePickerSheet(
                title: "ページ追加",
                subtitle: "追加するページの用紙を選んでください。",
                selectedTemplate: notebookPendingNewPage?.sortedPages.last?.pageTemplate ?? .ruled,
                selectedPaperColorHex: notebookPendingNewPage?.sortedPages.last?.paperColorHex
                    ?? PaperColorChoice.white.hex,
                confirmTitle: "追加",
                onCancel: { notebookPendingNewPage = nil },
                onSelect: { template, colorHex in
                    addPendingPage(template: template, paperColorHex: colorHex)
                }
            )
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
            lastActivePage = page
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
        .onAppear {
            splitState.isSplit = splitMode != .single
            loadAIChatThreads()
        }
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
        .modifier(SnippetTrayModifier(
            snippets: $snippetTray,
            pendingQuestion: $pendingProofQuestionSnippet,
            pendingAnswer: $pendingProofAnswerSnippet,
            onAskAI: askAIAboutSnippet,
            onProofRoleSelected: handleProofSnippet
        ))
        .modifier(AIChatTabSyncModifier(
            openThreadID: selectedAIChatThread?.persistentModelID,
            onAnnounce: { if let thread = selectedAIChatThread { announceAIChatTab(thread) } },
            onSelect: openAIChatThread
        ))
    }

    /// The floating pen bar, rendered by a child view that owns its own
    /// position state.
    ///
    /// Dragging it used to write `drawingToolbarCenter` on `NoteEditorView`,
    /// which re-ran this whole screen's `body` — page canvases, split panes
    /// and all — on every touch sample. That is why the bar lagged behind the
    /// finger. Keeping the live position inside `FloatingDrawingToolbar`
    /// confines each drag update to the bar itself, and only the settled
    /// position is handed back here.
    private func sharedDrawingToolbar(in size: CGSize, identity: String) -> some View {
        FloatingDrawingToolbar(
            identity: identity,
            paneSize: size,
            prefersTopEdge: drawingToolbarPosition == "top",
            isLeftHanded: isLeftHandedMode,
            isAdjustingToolSize: isAdjustingToolSize,
            showsSizeControl: showsToolSizeControl,
            controls: { isVertical in
                AnyView(sharedDrawingToolbarControls(isVertical: isVertical))
            },
            sizeControl: { isVertical in
                AnyView(toolSizeControl(isVertical: isVertical))
            }
        )
    }

    private func temporaryAIChatPanel(in size: CGSize) -> some View {
        let panelSize = resolvedTemporaryAIChatSize(in: size)

        return ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Label("AIトーク", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(temporaryAIChatDragGesture(in: size, panelSize: panelSize))
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showsTemporaryAIChat = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial)

                AIChatPane(
                    threads: aiChatThreads,
                    selectedThread: selectedAIChatThread,
                    draft: activeAIChatDraft,
                    attachments: activeAIChatAttachments,
                    onSelectThread: { selectedAIChatThread = $0 },
                    onNewThread: {
                        selectedAIChatThread = nil
                        aiChatDrafts["new"] = ""
                        aiChatAttachments["new"] = []
                        aiChatContextOverrides["new"] = nil
                    },
                    onDeleteThread: deleteAIChatThread,
                    onSend: { sendAIChatMessage() },
                    respondingThreadIDs: aiChatRespondingThreadIDs,
                    onCancel: cancelAIChatResponse,
                    onGradeProof: gradeProof,
                    onInsertAssistantMessage: insertAIResponseOnPage,
                    onAttachDroppedTab: attachmentForDroppedTab,
                    onSelectAppAttachment: appAttachmentOptions,
                    onPaneDrop: { handlePaneDrop($0, target: .secondary) }
                )
            }

            temporaryAIChatResizeHandles(in: size, panelSize: panelSize)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .position(resolvedTemporaryAIChatCenter(in: size, panelSize: panelSize))
        .transaction { transaction in
            if temporaryAIChatDragOrigin != nil || temporaryAIChatResizeOrigin != nil {
                transaction.animation = nil
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onAppear {
            if temporaryAIChatCenter == nil {
                temporaryAIChatCenter = clampedTemporaryAIChatCenter(
                    CGPoint(x: size.width - panelSize.width / 2 - 18, y: size.height - panelSize.height / 2 - 18),
                    in: size,
                    panelSize: panelSize
                )
            }
        }
    }

    private func temporaryAIChatResizeHandles(in containerSize: CGSize, panelSize: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 18)
                .contentShape(Rectangle())
                .gesture(temporaryAIChatResizeGesture(in: containerSize, panelSize: panelSize, axes: [.horizontal]))
                .accessibilityLabel("AIトークの幅を変更")
                .frame(maxWidth: .infinity, maxHeight: max(44, panelSize.height - 54), alignment: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            Rectangle()
                .fill(Color.clear)
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(temporaryAIChatResizeGesture(in: containerSize, panelSize: panelSize, axes: [.vertical]))
                .accessibilityLabel("AIトークの高さを変更")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.34))
                .frame(width: 30, height: 4)
                .rotationEffect(.degrees(-45))
                .padding(12)
                .contentShape(Rectangle())
                .gesture(temporaryAIChatResizeGesture(in: containerSize, panelSize: panelSize, axes: [.horizontal, .vertical]))
                .accessibilityLabel("AIトークの大きさを変更")
        }
    }

    private func temporaryAIChatResizeGesture(
        in containerSize: CGSize,
        panelSize: CGSize,
        axes: Axis.Set
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let initial = temporaryAIChatResizeOrigin ?? panelSize
                if temporaryAIChatResizeOrigin == nil { temporaryAIChatResizeOrigin = initial }
                let resized = clampedTemporaryAIChatSize(
                    CGSize(
                        width: initial.width + (axes.contains(.horizontal) ? value.translation.width : 0),
                        height: initial.height + (axes.contains(.vertical) ? value.translation.height : 0)
                    ),
                    in: containerSize
                )
                temporaryAIChatSize = resized
                temporaryAIChatCenter = clampedTemporaryAIChatCenter(
                    resolvedTemporaryAIChatCenter(in: containerSize, panelSize: resized),
                    in: containerSize,
                    panelSize: resized
                )
            }
            .onEnded { _ in temporaryAIChatResizeOrigin = nil }
    }

    private func temporaryAIChatDragGesture(in containerSize: CGSize, panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let initial = temporaryAIChatDragOrigin ?? temporaryAIChatCenter
                    ?? resolvedTemporaryAIChatCenter(in: containerSize, panelSize: panelSize)
                if temporaryAIChatDragOrigin == nil { temporaryAIChatDragOrigin = initial }
                temporaryAIChatCenter = clampedTemporaryAIChatCenter(
                    CGPoint(
                        x: initial.x + value.translation.width,
                        y: initial.y + value.translation.height
                    ),
                    in: containerSize,
                    panelSize: panelSize,
                    margin: 18
                )
            }
            .onEnded { _ in
                if let center = temporaryAIChatCenter {
                    temporaryAIChatCenter = clampedTemporaryAIChatCenter(
                        center,
                        in: containerSize,
                        panelSize: panelSize
                    )
                }
                temporaryAIChatDragOrigin = nil
            }
    }

    private func resolvedTemporaryAIChatSize(in containerSize: CGSize) -> CGSize {
        clampedTemporaryAIChatSize(
            temporaryAIChatSize ?? CGSize(
                width: min(520, max(360, containerSize.width * 0.42)),
                height: min(620, max(420, containerSize.height * 0.74))
            ),
            in: containerSize
        )
    }

    private func clampedTemporaryAIChatSize(_ panelSize: CGSize, in containerSize: CGSize) -> CGSize {
        let maxWidth = max(320, containerSize.width - 24)
        let maxHeight = max(360, containerSize.height - 24)
        return CGSize(
            width: min(max(panelSize.width, min(320, maxWidth)), maxWidth),
            height: min(max(panelSize.height, min(360, maxHeight)), maxHeight)
        )
    }

    private func resolvedTemporaryAIChatCenter(in containerSize: CGSize, panelSize: CGSize) -> CGPoint {
        clampedTemporaryAIChatCenter(
            temporaryAIChatCenter ?? CGPoint(
                x: containerSize.width - panelSize.width / 2 - 18,
                y: containerSize.height - panelSize.height / 2 - 18
            ),
            in: containerSize,
            panelSize: panelSize
        )
    }

    private func clampedTemporaryAIChatCenter(
        _ point: CGPoint,
        in containerSize: CGSize,
        panelSize: CGSize,
        margin: CGFloat = 0
    ) -> CGPoint {
        let halfWidth = min(panelSize.width / 2, containerSize.width / 2) - margin
        let halfHeight = min(panelSize.height / 2, containerSize.height / 2) - margin
        let minX = max(0, halfWidth)
        let minY = max(0, halfHeight)
        let maxX = max(minX, containerSize.width - minX)
        let maxY = max(minY, containerSize.height - minY)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    @ViewBuilder
    private func sharedDrawingToolbarControls(isVertical: Bool) -> some View {
        Button {
            postDrawingHistoryRequest(.studiquoUndoDrawing)
        } label: { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }

        Button {
            postDrawingHistoryRequest(.studiquoRedoDrawing)
        } label: { Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 28) }

        Divider().frame(width: isVertical ? 28 : nil, height: isVertical ? 1 : 24)

        // Shape correction is configured from the "補正設定" menu in the top
        // tool strip. It was duplicated here too, which only crowded a bar
        // whose whole job is the handful of controls used mid-stroke.

        ForEach(DrawingToolKind.toolbarCases, id: \.rawValue) { tool in
            Button {
                pendingShapeKindRaw = ""
                drawingToolRaw = (drawingTool == tool ? DrawingToolKind.none : tool).rawValue
            } label: {
                Image(systemName: tool.icon)
                    .foregroundStyle(drawingTool == tool ? Color.accentColor : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(toolChipBackground(cornerRadius: 7, isActive: drawingTool == tool))
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
    }

    /// The lasso has no thickness to set — it traces a selection rather than
    /// laying down ink — so the size slider (and the preview it drives) is
    /// dropped from the bar entirely while it's the active tool, instead of
    /// sitting there adjusting a pen the user isn't holding.
    private var showsToolSizeControl: Bool {
        drawingTool != .lasso
    }

    private var shouldShowDrawingToolbarInPrimaryPane: Bool {
        !isReadOnlyMode && showsDrawingToolbar && primaryFlashcardDeck == nil
    }

    private var shouldShowDrawingToolbarInSecondaryPane: Bool {
        splitMode != .single
            && !isReadOnlyMode
            && showsDrawingToolbar
            && secondaryNotebook != nil
            && secondaryFlashcardDeck == nil
            && !secondaryShowsWeb
            && !secondaryShowsAIChat
    }

    /// Bound straight to `$eraserWidth` / `$drawingWidth` rather than to one
    /// merged `Binding(get:set:)` computed property. A hand-built Binding is
    /// rebuilt with fresh closures on every `body` pass, so each value change
    /// during a drag made SwiftUI treat the `Slider` as a different view and
    /// reconstruct it mid-interaction — losing the in-flight drag, and with
    /// it the closing `onEditingChanged(false)` that hides the size preview.
    /// The projected bindings of the `@AppStorage` properties are stable, so
    /// the slider survives the whole drag and reports its own end.
    @ViewBuilder
    private var toolSizeSlider: some View {
        if drawingTool == .eraser {
            Slider(value: $eraserWidth, in: ToolSizeScale.eraser.range, step: ToolSizeScale.eraser.step,
                   onEditingChanged: setToolSizeAdjusting)
        } else {
            Slider(value: $drawingWidth, in: ToolSizeScale.pen.range, step: ToolSizeScale.pen.step,
                   onEditingChanged: setToolSizeAdjusting)
        }
    }

    private func setToolSizeAdjusting(_ editing: Bool) {
        if editing {
            isAdjustingToolSize = true
            return
        }
        // Deferred deliberately. Clearing the flag synchronously from
        // inside the slider's own editing-ended callback rebuilds the
        // slider while the lifting touch is still being delivered, and the
        // rebuilt slider then picks that touch up as a new interaction and
        // reports editing-began roughly a millisecond later — which is why
        // the preview appeared never to hide. Waiting a turn lets the touch
        // finish first, and it also lands after any such stray began, so
        // the preview ends up hidden either way.
        DispatchQueue.main.async { isAdjustingToolSize = false }
    }

    private var currentToolSizeLabel: String {
        drawingTool == .eraser ? "消しゴムの大きさ" : "ペンの太さ"
    }

    /// The stored value, in points — what the ink is actually drawn with.
    private var currentToolSizeValue: Double {
        drawingTool == .eraser ? eraserWidth : drawingWidth
    }

    /// The number shown beside the slider, always 0–100.
    ///
    /// The scale is presentational: a pen is only usable across a few points
    /// of real width and a 100pt nib would be a blot, so 0–100 is mapped onto
    /// each tool's own sensible point range rather than used as a width.
    private var currentToolSizePercent: Int {
        (drawingTool == .eraser ? ToolSizeScale.eraser : ToolSizeScale.pen)
            .percent(forPoints: currentToolSizeValue)
    }

    /// Shown centered over the page while the size slider is being dragged,
    /// scaling with it, so the number on the slider translates into an
    /// actual sense of how thick the pen or how big the eraser will be.
    private var toolSizePreview: some View {
        let diameter = max(currentToolSizeValue, 6)
        return VStack(spacing: 10) {
            Circle()
                .fill(drawingTool == .eraser ? Color(.systemGray3) : Color(hex: drawingColorHex))
                .frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 90, height: 90)
            Text("\(currentToolSizePercent)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    @ViewBuilder
    private func toolSizeControl(isVertical: Bool) -> some View {
        if isVertical {
            Button {
                showsToolSizePopover.toggle()
            } label: {
                Image(systemName: "lineweight")
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .popover(isPresented: $showsToolSizePopover) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(currentToolSizeLabel)
                            .font(.headline)
                        Spacer()
                        Text("\(currentToolSizePercent)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    toolSizeSlider
                }
                .padding(18)
                .frame(width: 280)
            }
            .accessibilityLabel(currentToolSizeLabel)
            .accessibilityValue("\(currentToolSizePercent)")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .foregroundStyle(.primary)
                toolSizeSlider
                    .frame(width: 96)
                Text("\(currentToolSizePercent)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(height: 36)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(currentToolSizeLabel)
            .accessibilityValue("\(currentToolSizePercent)")
        }
    }

    private func clampedDrawingToolbarCenter(_ center: CGPoint, in size: CGSize, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(center.x, width / 2 + 6), max(width / 2 + 6, size.width - width / 2 - 6)),
            y: min(max(center.y, height / 2 + 6), max(height / 2 + 6, size.height - height / 2 - 6))
        )
    }

    private var recognizedSelectionDragChip: some View {
        Label(recognizedSelectionDragText, systemImage: "hand.draw")
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .draggable(recognizedSelectionDragText)
            .accessibilityLabel("認識した文字。暗記カードへドラッグできます")
    }

    /// Both panes are two views onto one notebook. Ink drawn in either is
    /// mirrored into the other (see `studiquoDrawingSynced`), so moving a
    /// lasso selection across is switched off — it would be moving ink out
    /// of a page and into that same page.
    private var panesShowSameNotebook: Bool {
        splitMode != .single
            && primaryFlashcardDeck == nil
            && secondaryFlashcardDeck == nil
            && !secondaryShowsWeb
            && !secondaryShowsAIChat
            && primaryFriendChatID == nil
            && secondaryFriendChatID == nil
            && secondaryNotebook === displayedPrimaryNotebook
    }

    private func sidebarWidth(in size: CGSize) -> CGFloat {
        showsPageSidebar ? min(260, size.width * 0.28) : 0
    }

    private func workspaceSize(in size: CGSize) -> CGSize {
        CGSize(width: size.width - sidebarWidth(in: size), height: size.height)
    }

    /// primaryPane is always the leading (horizontal split) or top
    /// (vertical split) slice of `workspace` — matching the sizing done
    /// there keeps the drawing toolbar's confinement in step with it.
    private func primaryPaneSize(in size: CGSize) -> CGSize {
        let workspace = workspaceSize(in: size)
        switch splitMode {
        case .single:
            return workspace
        case .horizontal:
            return CGSize(width: max(260, workspace.width * splitRatio - 5), height: workspace.height)
        case .vertical:
            return CGSize(width: workspace.width, height: max(220, workspace.height * splitRatio - 5))
        }
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
        Group {
            if primaryShowsAIChat {
                AIChatPane(
                    threads: aiChatThreads,
                    selectedThread: selectedAIChatThread,
                    draft: activeAIChatDraft,
                    attachments: activeAIChatAttachments,
                    onSelectThread: { thread in
                        selectedAIChatThread = thread
                    },
                    onNewThread: {
                        selectedAIChatThread = nil
                        aiChatDrafts["new"] = ""
                        aiChatAttachments["new"] = []
                        aiChatContextOverrides["new"] = nil
                    },
                    onDeleteThread: deleteAIChatThread,
                    onSend: { sendAIChatMessage() },
                    respondingThreadIDs: aiChatRespondingThreadIDs,
                    onCancel: cancelAIChatResponse,
                    onGradeProof: gradeProof,
                    onInsertAssistantMessage: insertAIResponseOnPage,
                    onAttachDroppedTab: attachmentForDroppedTab,
                    onSelectAppAttachment: appAttachmentOptions,
                    onPaneDrop: { handlePaneDrop($0, target: .primary) }
                )
            } else if let primaryFriend = primaryFriendChat {
                FriendChatView(
                    friend: primaryFriend,
                    store: friendStore,
                    appAttachments: friendMessageAttachmentOptions()
                )
            } else if let primaryFlashcardDeck {
                FlashcardPaneView(deck: primaryFlashcardDeck, onHome: onHome)
            } else {
                GeometryReader { geometry in
                    ZStack {
                        ZoomableWorkspace(size: geometry.size) {
                            NotebookPaneView(
                                notebook: displayedPrimaryNotebook,
                                currentPageIndex: $primaryPageIndex,
                                showsTitle: splitMode != .single || displayedPrimaryNotebook.containsPDF,
                                usesDarkPageDisplay: usesDarkPageDisplay,
                                onRequestAddPage: { requestPageAddition(to: displayedPrimaryNotebook) },
                                onSummarizeCurrentPDFPage: {
                                    summarizePDFPage(in: displayedPrimaryNotebook, pageIndex: primaryPageIndex)
                                },
                                onSummarizeAllPDFPages: {
                                    summarizePDFDocument(displayedPrimaryNotebook)
                                },
                                onQuickAddPage: { quickAddPage(to: displayedPrimaryNotebook) },
                                onQuickAddPageAtTop: { quickAddPageAtTop(to: displayedPrimaryNotebook) }
                            )
                        }

                        if shouldShowDrawingToolbarInPrimaryPane {
                            sharedDrawingToolbar(in: geometry.size, identity: "primary")
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { activePane = .primary })
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first else { return false }
            guard splitMode != .single || value.hasPrefix("ai:") || value.hasPrefix("friend:") else { return false }
            return handlePaneDrop(value, target: .primary)
        }
    }

    @ViewBuilder
    private var secondaryPane: some View {
        if secondaryShowsWeb {
            WebSearchPane(browser: webBrowser)
        } else if secondaryShowsAIChat {
            AIChatPane(
                threads: aiChatThreads,
                selectedThread: selectedAIChatThread,
                draft: activeAIChatDraft,
                attachments: activeAIChatAttachments,
                onSelectThread: { thread in
                    selectedAIChatThread = thread
                },
                onNewThread: {
                    selectedAIChatThread = nil
                    aiChatDrafts["new"] = ""
                    aiChatAttachments["new"] = []
                    aiChatContextOverrides["new"] = nil
                },
                onDeleteThread: deleteAIChatThread,
                onSend: { sendAIChatMessage() },
                respondingThreadIDs: aiChatRespondingThreadIDs,
                onCancel: cancelAIChatResponse,
                onGradeProof: gradeProof,
                onInsertAssistantMessage: insertAIResponseOnPage,
                onAttachDroppedTab: attachmentForDroppedTab,
                onSelectAppAttachment: appAttachmentOptions,
                onPaneDrop: { handlePaneDrop($0, target: .secondary) }
            )
        } else if let secondaryFriend = secondaryFriendChat {
            FriendChatView(
                friend: secondaryFriend,
                store: friendStore,
                appAttachments: friendMessageAttachmentOptions()
            )
        } else if let secondaryFlashcardDeck {
            FlashcardPaneView(deck: secondaryFlashcardDeck, onHome: onHome)
                .simultaneousGesture(TapGesture().onEnded { activePane = .secondary })
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first else { return false }
                    return handlePaneDrop(value, target: .secondary)
                }
        } else if let secondaryNotebook {
            GeometryReader { geometry in
                ZStack {
                    ZoomableWorkspace(size: geometry.size) {
                        NotebookPaneView(
                            notebook: secondaryNotebook,
                            currentPageIndex: $secondaryPageIndex,
                            showsTitle: true,
                            onRequestAddPage: { requestPageAddition(to: secondaryNotebook) },
                            onSummarizeCurrentPDFPage: {
                                summarizePDFPage(in: secondaryNotebook, pageIndex: secondaryPageIndex)
                            },
                            onSummarizeAllPDFPages: {
                                summarizePDFDocument(secondaryNotebook)
                            },
                            onQuickAddPage: { quickAddPage(to: secondaryNotebook) },
                            onQuickAddPageAtTop: { quickAddPageAtTop(to: secondaryNotebook) }
                        )
                    }

                    if shouldShowDrawingToolbarInSecondaryPane {
                        sharedDrawingToolbar(in: geometry.size, identity: "secondary")
                    }
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
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first else { return false }
                return handlePaneDrop(value, target: .secondary)
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
                ForEach([PageElementKind.rectangle, .ellipse]) { kind in
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
                .disabled(isPortraitLayout)
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
                requestPageAddition(to: activeNotebook)
            } label: {
                Label("ページ追加", systemImage: "plus.rectangle.on.rectangle")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Menu {
                Button("全ページ", systemImage: "doc.on.doc") { exportAllPagesAsPDF() }
                Button("このページ", systemImage: "doc") { exportCurrentPageAsPDF() }
                    .disabled(activePage == nil)
            } label: {
                Label("PDF出力", systemImage: "square.and.arrow.down.on.square")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        }
    }

    private var editorToolStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                toolStripButton("ホームへ戻る", icon: "house.fill", action: onHome)
                // The sidebar toggle used to sit here. Opening another note
                // is now the "+" in the tab bar above, which lists the same
                // notes and decks the home screen does — so the sidebar had
                // nothing left to offer that the tabs don't.
                // In split mode each pane shows its own title below its
                // toolbar (see NotebookPaneView's showsTitle) instead —
                // showing it a second time up here as well as down there
                // was redundant, and this copy didn't exist for the
                // secondary pane anyway.
                if splitMode == .single {
                    Text(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                        .accessibilityLabel("現在のノート \(primaryFlashcardDeck?.title ?? displayedPrimaryNotebook.title)")
                }

                Divider()
                    .frame(height: 26)

                toolStripButton("元に戻す", icon: "arrow.uturn.backward") {
                    postDrawingHistoryRequest(.studiquoUndoDrawing)
                }
                toolStripButton("やり直す", icon: "arrow.uturn.forward") {
                    postDrawingHistoryRequest(.studiquoRedoDrawing)
                }
                toolStripButton("AIトーク", icon: "sparkles", isActive: primaryShowsAIChat || secondaryShowsAIChat || showsTemporaryAIChat) {
                    presentAIChat()
                }
                toolStripButton("フレンドチャット", icon: "person.crop.circle", isActive: isFriendChatVisibleInSplit) {
                    presentFriendChat()
                }
                toolStripButton("ペン", icon: "pencil.tip", isActive: drawingTool == .pen && !isReadOnlyMode, action: selectPen)
                    .disabled(primaryFlashcardDeck != nil)
                toolStripButton("消しゴム", icon: "eraser", isActive: drawingTool == .eraser && !isReadOnlyMode, action: selectEraser)
                    .disabled(primaryFlashcardDeck != nil)
                toolStripButton("選択", icon: "lasso", isActive: drawingTool == .lasso && !isReadOnlyMode, action: selectLasso)
                    .disabled(primaryFlashcardDeck != nil)
                toolStripButton("時間", icon: "timer") {
                    showsTimeTool = true
                }
                toolStripButton("関数電卓", icon: "123.rectangle.fill", isActive: showsCalculator) {
                    showsCalculator.toggle()
                }
                if timeToolModel.showsToolbarTime {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Button {
                            timeToolModel.toggleFromToolbar()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: timeToolModel.isRunning ? "pause.fill" : "play.fill")
                                Text(timeToolModel.toolbarText(at: context.date))
                            }
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(timeToolModel.mode == .timer ? .orange : .indigo)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Menu {
                    ForEach([PageElementKind.rectangle, .ellipse]) { kind in
                        Button { addShapeElement(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                    }
                    Button { addShapeElement(.studyTape) } label: { Label("暗記テープ", systemImage: "rectangle.fill") }
                } label: { toolStripLabel("図形", icon: "square.on.circle", isActive: pendingShapeKindRaw != "") }

                toolStripButton("テキスト", icon: "textformat", action: addTextElement)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    toolStripLabel("写真", icon: "photo")
                }
                toolStripButton("明暗表示", icon: usesDarkPageDisplay ? "sun.max" : "moon", isActive: usesDarkPageDisplay) { usesDarkPageDisplay.toggle() }
                Menu {
                    Toggle("直線補正", isOn: $isLineCorrectionEnabled)
                    Toggle("円・楕円補正", isOn: $isEllipseCorrectionEnabled)
                    Toggle("正方形・長方形補正", isOn: $isRectangleCorrectionEnabled)
                    Toggle("三角形補正", isOn: $isTriangleCorrectionEnabled)
                    Toggle("二次関数補正", isOn: $isParabolaCorrectionEnabled)
                    Toggle("曲線補正", isOn: $isCurveCorrectionEnabled)
                } label: {
                    toolStripLabel(
                        "補正設定",
                        icon: "wand.and.stars",
                        isActive: isLineCorrectionEnabled || isEllipseCorrectionEnabled
                            || isRectangleCorrectionEnabled || isTriangleCorrectionEnabled
                            || isParabolaCorrectionEnabled || isCurveCorrectionEnabled
                    )
                }
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

                Menu {
                    Button("1画面", systemImage: "rectangle") { splitMode = .single }
                    Button("左右に2分割", systemImage: "rectangle.split.2x1") {
                        prepareSplit(.horizontal)
                    }
                    .disabled(isPortraitLayout)
                    Button("上下に2分割", systemImage: "rectangle.split.1x2") {
                        prepareSplit(.vertical)
                    }
                    Divider()
                    Button("Google検索と2分割", systemImage: "globe") {
                        openWebSplit(title: "Google検索", homeURL: "https://www.google.com")
                    }
                } label: { toolStripLabel("画面分割", icon: splitMode.icon, isActive: splitMode != .single) }

                if splitMode != .single {
                    Menu {
                        Menu("ノート・PDF") {
                            ForEach(notebooks) { candidate in
                                Button(candidate.title) {
                                    secondaryNotebook = candidate
                                    secondaryFlashcardDeck = nil
                                    secondaryShowsWeb = false
                                    secondaryShowsAIChat = false
                                    secondaryPageIndex = 0
                                }
                            }
                        }
                        Menu("暗記カード") {
                            ForEach(flashcardDecks) { deck in
                                Button(deck.title) {
                                    secondaryFlashcardDeck = deck
                                    secondaryNotebook = nil
                                    secondaryShowsWeb = false
                                    secondaryShowsAIChat = false
                                }
                            }
                        }
                        Button("白紙ノートを作る", systemImage: "square.and.pencil") {
                            secondaryNotebook = createCompanionNotebook()
                            secondaryFlashcardDeck = nil
                            secondaryShowsWeb = false
                            secondaryShowsAIChat = false
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

                // Targets whichever pane was last touched, so in a split the
                // page lands in the note the user was actually working in
                // rather than always in the left/top one.
                toolStripButton("ページ追加", icon: "plus.rectangle.on.rectangle") {
                    requestPageAddition(to: activeNotebook)
                }
                    .disabled(activePaneShowsFlashcards)

                Menu {
                    Button("全ページ", systemImage: "doc.on.doc") { exportAllPagesAsPDF() }
                    Button("このページ", systemImage: "doc") { exportCurrentPageAsPDF() }
                        .disabled(activePage == nil)
                } label: { toolStripLabel("PDF出力", icon: "square.and.arrow.down.on.square") }
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

    /// The highlight behind an active tool icon.
    ///
    /// Fill and border come from the same rounded rectangle, and the stroke
    /// is drawn at double width then clipped to that shape. Drawn as a
    /// separate inset `strokeBorder` the fill showed through outside the
    /// line — widest at the corners, which is what made them look cut off.
    private func toolChipBackground(cornerRadius: CGFloat, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(shape.stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 3))
            .clipShape(shape)
    }

    private func toolStripLabel(_ title: String, icon: String, isActive: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: 34, height: 34)
            .background(toolChipBackground(cornerRadius: 8, isActive: isActive))
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func openWebSplit(title: String, homeURL: String) {
        webBrowser.openHomeIfNeeded(homeURL)
        secondaryNotebook = nil
        secondaryFlashcardDeck = nil
        secondaryShowsWeb = true
        secondaryShowsAIChat = false
        secondaryFriendChatID = nil
        splitMode = isPortraitLayout ? .vertical : .horizontal
        splitRatio = 0.5
        activePane = .primary
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoOpenWebTab"),
            object: WebTabInfo(id: homeURL, title: title, homeURL: homeURL)
        )
    }

    private func presentFriendChat() {
        guard let friend = friendStore.friends.first else { return }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoOpenFriendChatTab"),
            object: FriendChatTabInfo(id: friend.id, title: friend.name)
        )
        if isFriendChatVisibleInSplit {
            collapseSplit()
            return
        }
        secondaryNotebook = nil
        secondaryFlashcardDeck = nil
        secondaryShowsWeb = false
        secondaryShowsAIChat = false
        secondaryFriendChatID = friend.id
        splitMode = isPortraitLayout ? .vertical : .horizontal
        splitRatio = 0.5
        activePane = .primary
    }

    /// Tells the tab bar that this conversation is open, and what to call it.
    ///
    /// Sent again after each exchange because a thread is titled from its
    /// first message — without the repeat, every tab would read
    /// "新しいトーク" forever.
    private func announceAIChatTab(_ thread: AIChatThread) {
        NotificationCenter.default.post(
            name: .studiquoOpenAIChatTab,
            object: AIChatTabInfo(id: thread.persistentModelID, title: thread.title)
        )
    }

    /// Brings a conversation to the front, opening the chat pane if the
    /// editor is not already showing one.
    private func openAIChatThread(_ id: PersistentIdentifier) {
        loadAIChatThreads()
        guard let thread = aiChatThreads.first(where: { $0.persistentModelID == id }) else { return }
        selectedAIChatThread = thread
        if isAIChatVisibleInSplit {
            showsTemporaryAIChat = false
            announceAIChatTab(thread)
        } else if splitMode == .single {
            openAIChatSplit()
        } else {
            presentTemporaryAIChat()
        }
    }

    private func presentAIChat() {
        if isAIChatVisibleInSplit {
            showsTemporaryAIChat = false
            collapseSplit()
            return
        }
        if splitMode == .single && !secondaryShowsAIChat {
            openAIChatSplit()
        } else {
            presentTemporaryAIChat()
        }
    }

    private func presentTemporaryAIChat() {
        loadAIChatThreads()
        selectedAIChatThread = selectedAIChatThread ?? aiChatThreads.first
        if let thread = selectedAIChatThread { announceAIChatTab(thread) }
        guard !isAIChatVisibleInSplit else {
            showsTemporaryAIChat = false
            return
        }
        showsTemporaryAIChat = true
    }

    private func openAIChatSplit() {
        loadAIChatThreads()
        selectedAIChatThread = selectedAIChatThread ?? aiChatThreads.first
        if let thread = selectedAIChatThread { announceAIChatTab(thread) }
        showsTemporaryAIChat = false
        secondaryNotebook = nil
        secondaryFlashcardDeck = nil
        secondaryShowsWeb = false
        secondaryShowsAIChat = true
        splitMode = isPortraitLayout ? .vertical : .horizontal
        splitRatio = 0.5
        activePane = .primary
    }

    private var isAIChatVisibleInSplit: Bool {
        splitMode != .single && (primaryShowsAIChat || secondaryShowsAIChat)
    }

    private var primaryFriendChat: FriendRecord? {
        guard let primaryFriendChatID else { return nil }
        return friendStore.friends.first { $0.id == primaryFriendChatID }
    }

    private var secondaryFriendChat: FriendRecord? {
        guard let secondaryFriendChatID else { return nil }
        return friendStore.friends.first { $0.id == secondaryFriendChatID }
    }

    private var isFriendChatVisibleInSplit: Bool {
        splitMode != .single && (primaryFriendChatID != nil || secondaryFriendChatID != nil)
    }

    private func friendMessageAttachmentOptions() -> [FriendMessageAttachment] {
        var options: [FriendMessageAttachment] = []
        options.append(contentsOf: notebooks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "notebook-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: $0.containsPDF ? "PDF" : "ノート",
                icon: $0.containsPDF ? "doc.richtext" : "note.text"
            )
        })
        options.append(contentsOf: flashcardDecks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "deck-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "暗記カード",
                icon: "rectangle.on.rectangle.angled"
            )
        })
        options.append(contentsOf: textDocuments.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "document-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "文書",
                icon: "doc.text"
            )
        })
        options.append(contentsOf: slideDecks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "slide-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "スライド",
                icon: "rectangle.on.rectangle"
            )
        })
        return options
    }

    private func loadAIChatThreads() {
        let descriptor = FetchDescriptor<AIChatThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        aiChatThreads = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !$0.sortedMessages.isEmpty }
    }

    private var activeAIChatDraft: Binding<String> {
        Binding(
            get: {
                aiChatDrafts[activeAIChatDraftKey] ?? ""
            },
            set: { newValue in
                aiChatDrafts[activeAIChatDraftKey] = newValue
            }
        )
    }

    private var activeAIChatAttachments: Binding<[AIChatAttachment]> {
        Binding(
            get: {
                aiChatAttachments[activeAIChatDraftKey] ?? []
            },
            set: { newValue in
                aiChatAttachments[activeAIChatDraftKey] = newValue
            }
        )
    }

    private var activeAIChatDraftKey: String {
        selectedAIChatThread.map(aiChatThreadKey) ?? "new"
    }

    private func aiChatThreadKey(_ thread: AIChatThread) -> String {
        String(describing: thread.persistentModelID)
    }

    private func aiChatThreadForSending() -> AIChatThread {
        if let selectedAIChatThread { return selectedAIChatThread }
        let thread = AIChatThread()
        modelContext.insert(thread)
        selectedAIChatThread = thread
        return thread
    }

    private func sendAIChatMessage(
        draftKey overrideDraftKey: String? = nil,
        text overrideText: String? = nil,
        attachments overrideAttachments: [AIChatAttachment]? = nil
    ) {
        let draftKey = overrideDraftKey ?? activeAIChatDraftKey
        let trimmed = (overrideText ?? aiChatDrafts[draftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attachments = overrideAttachments ?? aiChatAttachments[draftKey] ?? []
        let thread = aiChatThreadForSending()
        let threadKey = aiChatThreadKey(thread)
        guard !aiChatRespondingThreadIDs.contains(threadKey) else { return }

        let userMessage = AIChatMessage(text: messageText(trimmed, with: attachments), role: .user)
        userMessage.thread = thread
        thread.messages.append(userMessage)

        if thread.sortedMessages.filter({ $0.role == .user }).count == 1 {
            thread.title = String(trimmed.prefix(24))
        }

        // The reply is appended empty and filled in as the stream arrives, so
        // the answer appears as it is written instead of after a blank wait.
        let reply = AIChatMessage(text: "", role: .assistant)
        reply.thread = thread
        thread.messages.append(reply)
        thread.updatedAt = .now
        aiChatDrafts[draftKey] = ""
        aiChatDrafts[aiChatThreadKey(thread)] = ""
        aiChatAttachments[draftKey] = []
        aiChatAttachments[aiChatThreadKey(thread)] = []
        let contextOverride = aiChatContextOverrides[draftKey] ?? aiChatContextOverrides[threadKey] ?? ""
        let attachmentContext = attachments
            .map { attachment -> String in
                let text = attachment.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return "" }
                return "【\(attachment.name)】\n\(text)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        aiChatContextOverrides[draftKey] = nil
        aiChatContextOverrides[threadKey] = nil
        try? modelContext.save()
        loadAIChatThreads()
        selectedAIChatThread = thread
        announceAIChatTab(thread)

        let history = thread.sortedMessages
            .filter { $0 !== reply }
            .map { AITurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
            .filter { !$0.text.isEmpty }
        let context = [aiChatNoteContext(), contextOverride, attachmentContext]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let images = attachments.compactMap(\.image)
        let expectsImages = attachments.contains { $0.kind == .snippet || $0.kind == .camera }

        aiChatRespondingThreadIDs.insert(threadKey)
        aiChatTasks[threadKey] = Task { @MainActor in
            defer {
                aiChatRespondingThreadIDs.remove(threadKey)
                aiChatTasks[threadKey] = nil
            }
            do {
                try await AI.provider.streamChat(
                    turns: history,
                    noteContext: context,
                    images: images,
                    expectsImages: expectsImages
                ) { delta in
                    reply.text += delta
                }
                if reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reply.text = L("返答が空でした。もう一度試してください。")
                }
            } catch is CancellationError {
                reply.text += reply.text.isEmpty ? L("（中断しました）") : L("（中断しました）")
            } catch {
                reply.text = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            thread.updatedAt = .now
            try? modelContext.save()
        }
    }

    private func askAIAboutSnippet(_ snippet: PageSnippet) {
        presentAIChat()
        let key = activeAIChatDraftKey
        let snippetAttachment = AIChatAttachment(
            name: snippet.sourceLabel,
            path: "",
            kind: .snippet,
            snippet: snippet
        )
        // Do not rely on SwiftUI state propagation here. The "AIに質問する"
        // button sends immediately after adding the crop, and reading the
        // binding on the same pass can see the pre-update attachment list,
        // which means the Worker receives text but no image. Pass the crop
        // straight into the send path instead.
        sendAIChatMessage(
            draftKey: key,
            text: L("この切り抜きについて説明してください。"),
            attachments: [snippetAttachment]
        )
    }

    private func summarizePDFPage(in notebook: Notebook, pageIndex: Int) {
        let source = readablePDFTextForAI(in: notebook, pageIndex: pageIndex)
        guard !source.isEmpty else { return }
        presentAIForPDFSummary()
        let key = activeAIChatDraftKey
        aiChatContextOverrides[key] = pdfContextPrompt(source)
        sendAIChatMessage(
            draftKey: key,
            text: """
            いま表示しているPDFのこのページだけを、わかりやすく要約してください。

            条件:
            - 重要ポイントを短く整理する
            - 難しい語句はかんたんに説明する
            - 復習で見るべき点も最後に書く
            - ページ番号を入れる
            """
        )
    }

    private func summarizePDFDocument(_ notebook: Notebook) {
        let source = readablePDFTextForAI(in: notebook)
        guard !source.isEmpty else { return }
        presentAIForPDFSummary()
        let key = activeAIChatDraftKey
        aiChatContextOverrides[key] = pdfContextPrompt(source)
        sendAIChatMessage(
            draftKey: key,
            text: """
            このPDF全体を、初めて読む人にもわかるように要約してください。

            条件:
            - まず全体像を短く説明する
            - 次に章・流れごとに要点を整理する
            - 重要語句を抜き出して説明する
            - 最後に復習チェックポイントを作る
            - 根拠になるページ番号をできるだけ入れる
            """
        )
    }

    private func presentAIForPDFSummary() {
        if isAIChatVisibleInSplit {
            showsTemporaryAIChat = false
        } else if splitMode == .single {
            openAIChatSplit()
        } else {
            presentTemporaryAIChat()
        }
    }

    private func pdfContextPrompt(_ source: String) -> String {
        """
        以下はユーザーが開いているPDF本文です。回答では必要に応じてページ番号を示してください。

        【PDF本文】
        \(source)
        """
    }

    private func insertAIResponseOnPage(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !activePaneShowsFlashcards, let page = activePage ?? currentPrimaryPage else { return }
        let lineCount = max(1, value.components(separatedBy: .newlines).count)
        let estimatedRows = min(18, max(6, lineCount + value.count / 44))
        let element = PageElement(
            kind: .text,
            text: value,
            centerY: 0.46,
            width: 0.78,
            height: min(0.58, max(0.28, Double(estimatedRows) * 0.032)),
            colorHex: selectedElementColorHex
        )
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        recordElementAddition(element, on: page)
        page.notebook?.updatedAt = .now
        try? modelContext.save()
        NotificationCenter.default.post(
            name: .studiquoSelectPageElement,
            object: element.persistentModelID
        )
    }

    private func readablePDFTextForAI(in notebook: Notebook, pageIndex: Int? = nil, limit: Int = 24_000) -> String {
        let pages = notebook.sortedPages
        var remaining = limit
        var chunks: [String] = []
        for (index, page) in pages.enumerated() {
            if let pageIndex, index != pageIndex { continue }
            guard page.backgroundImageData != nil else { continue }
            let text = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let heading = "p.\(index + 1)"
            let full = "\(heading)\n\(text)"
            guard remaining > 0 else { break }
            if full.count <= remaining {
                chunks.append(full)
                remaining -= full.count
            } else {
                chunks.append(String(full.prefix(remaining)))
                break
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    private func readableNotebookTextForAI(in notebook: Notebook, limit: Int = 24_000) -> String {
        var remaining = limit
        var chunks: [String] = []
        for (index, page) in notebook.sortedPages.enumerated() {
            guard remaining > 0 else { break }
            var parts: [String] = []
            let recognized = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recognized.isEmpty { parts.append(recognized) }
            let typed = page.elements
                .filter { $0.kind == .text }
                .map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            parts.append(contentsOf: typed)
            let text = parts.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            let full = "p.\(index + 1)\n\(text)"
            if full.count <= remaining {
                chunks.append(full)
                remaining -= full.count
            } else {
                chunks.append(String(full.prefix(remaining)))
                break
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    private func attachmentForDroppedTab(_ value: String) -> AIChatAttachment? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0] == "notebook",
              let targetNotebook = notebooks.first(where: {
                  String(describing: $0.persistentModelID) == parts[1] && !$0.isTrashed
              }) else { return nil }

        let pdfText = readablePDFTextForAI(in: targetNotebook)
        let noteText = pdfText.isEmpty ? readableNotebookTextForAI(in: targetNotebook) : pdfText
        let contextText = noteText.isEmpty
            ? L("この資料には、AIが読める抽出済みテキストがまだありません。")
            : noteText
        return AIChatAttachment(
            name: targetNotebook.title,
            path: "",
            kind: .notebook,
            contextText: contextText
        )
    }

    private func appAttachmentOptions() -> [AppAttachmentOption] {
        let noteOptions = notebooks
            .filter { !$0.isTrashed }
            .compactMap { notebookAttachmentOption($0) }
        let deckOptions = flashcardDecks
            .filter { !$0.isTrashed }
            .map { deckAttachmentOption($0) }
        let documentOptions = textDocuments
            .filter { !$0.isTrashed }
            .map { documentAttachmentOption($0) }
        let slideOptions = slideDecks
            .filter { !$0.isTrashed }
            .map { slideDeckAttachmentOption($0) }
        return noteOptions + deckOptions + documentOptions + slideOptions
    }

    private func notebookAttachmentOption(_ notebook: Notebook) -> AppAttachmentOption? {
        let pdfText = readablePDFTextForAI(in: notebook)
        let noteText = pdfText.isEmpty ? readableNotebookTextForAI(in: notebook) : pdfText
        let contextText = noteText.isEmpty
            ? L("この資料には、AIが読める抽出済みテキストがまだありません。")
            : noteText
        let attachment = AIChatAttachment(
            name: notebook.title,
            path: "",
            kind: .notebook,
            contextText: contextText
        )
        return AppAttachmentOption(
            id: "notebook:\(String(describing: notebook.persistentModelID))",
            title: notebook.title,
            subtitle: notebook.containsPDF ? L("PDF") : L("ノート"),
            icon: notebook.containsPDF ? "doc.richtext" : "note.text",
            attachment: attachment
        )
    }

    private func deckAttachmentOption(_ deck: FlashcardDeck) -> AppAttachmentOption {
        let lines = deck.sortedCards.enumerated().map { index, card in
            """
            \(index + 1). Q: \(card.question)
               A: \(card.answer)
            """
        }
        let contextText = lines.isEmpty
            ? L("この暗記カードにはカードがまだありません。")
            : lines.joined(separator: "\n\n")
        return AppAttachmentOption(
            id: "deck:\(String(describing: deck.persistentModelID))",
            title: deck.title,
            subtitle: L("暗記カード \(deck.cards.count)枚"),
            icon: "rectangle.on.rectangle.angled",
            attachment: AIChatAttachment(name: deck.title, path: "", kind: .flashcards, contextText: contextText)
        )
    }

    private func documentAttachmentOption(_ document: TextDocument) -> AppAttachmentOption {
        let text = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextText = text.isEmpty ? L("この文書には本文がまだありません。") : text
        return AppAttachmentOption(
            id: "document:\(String(describing: document.persistentModelID))",
            title: document.title,
            subtitle: L("文書"),
            icon: "doc.text",
            attachment: AIChatAttachment(name: document.title, path: "", kind: .document, contextText: contextText)
        )
    }

    private func slideDeckAttachmentOption(_ deck: SlideDeck) -> AppAttachmentOption {
        let slides = deck.sortedSlides.enumerated().map { index, slide in
            var parts = ["スライド \(index + 1)"]
            if !slide.titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("タイトル: \(slide.titleText)")
            }
            if !slide.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("本文: \(slide.bodyText)")
            }
            if !slide.secondaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("補足: \(slide.secondaryText)")
            }
            if !slide.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("発表ノート: \(slide.notes)")
            }
            return parts.joined(separator: "\n")
        }
        let contextText = slides.isEmpty ? L("このスライドには内容がまだありません。") : slides.joined(separator: "\n\n")
        return AppAttachmentOption(
            id: "slide:\(String(describing: deck.persistentModelID))",
            title: deck.title,
            subtitle: L("スライド \(deck.slides.count)枚"),
            icon: "rectangle.on.rectangle",
            attachment: AIChatAttachment(name: deck.title, path: "", kind: .slideDeck, contextText: contextText)
        )
    }

    private func handleProofSnippet(_ snippet: PageSnippet, role: AIChatAttachment.ProofRole) {
        switch role {
        case .question:
            pendingProofQuestionSnippet = snippet
        case .answer:
            pendingProofAnswerSnippet = snippet
        case .none:
            return
        }

        if let question = pendingProofQuestionSnippet,
           let answer = pendingProofAnswerSnippet {
            presentAIChat()
            gradeProof(ProofSubmission(
                questionText: "",
                questionImage: question.image,
                answerText: "",
                answerImage: answer.image
            ))
            pendingProofQuestionSnippet = nil
            pendingProofAnswerSnippet = nil
        }
    }

    /// Marks a proof, from whatever the student handed over.
    ///
    /// It runs as a normal exchange in the thread — a question from the
    /// student, an answer from the AI — so the marking stays in the
    /// conversation and can be asked about afterwards ("なぜここが減点なの？").
    ///
    /// Two calls, deliberately. A rubric is derived from the question alone
    /// first, and only then is the student's work looked at. Asking for a
    /// score in one shot makes the result drift between runs; fixing the
    /// criteria before the answer is visible is what makes two runs of the
    /// same page agree.
    private func gradeProof(_ submission: ProofSubmission) {
        guard submission.hasQuestion, submission.hasAnswer else { return }
        let thread = aiChatThreadForSending()
        let threadKey = aiChatThreadKey(thread)
        guard !aiChatRespondingThreadIDs.contains(threadKey) else { return }

        let userMessage = AIChatMessage(text: Self.submissionSummary(submission), role: .user)
        userMessage.thread = thread
        thread.messages.append(userMessage)

        if thread.sortedMessages.filter({ $0.role == .user }).count == 1 {
            thread.title = L("証明の添削")
        }

        let reply = AIChatMessage(text: L("採点基準を作っています…"), role: .assistant)
        reply.thread = thread
        thread.messages.append(reply)
        thread.updatedAt = .now
        try? modelContext.save()
        loadAIChatThreads()
        selectedAIChatThread = thread
        announceAIChatTab(thread)

        aiChatRespondingThreadIDs.insert(threadKey)
        aiChatTasks[threadKey] = Task { @MainActor in
            defer {
                aiChatRespondingThreadIDs.remove(threadKey)
                aiChatTasks[threadKey] = nil
            }
            do {
                let rubric = try await AI.provider.buildRubric(for: submission)
                try Task.checkCancellation()
                reply.text = L("答案を読んでいます…")
                let review = try await AI.provider.grade(submission, rubric: rubric)
                reply.text = Self.markingReport(review)
            } catch is CancellationError {
                reply.text = L("（中断しました）")
            } catch {
                reply.text = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            thread.updatedAt = .now
            try? modelContext.save()
        }
    }

    /// What the student's side of the exchange says, so the thread reads as a
    /// conversation rather than starting with an answer to an invisible
    /// question.
    private static func submissionSummary(_ submission: ProofSubmission) -> String {
        // Text halves are quoted; image halves are described in words rather
        // than left as a bare "（画像）" placeholder, so the student's bubble
        // reads like a request.
        func describe(text: String, image: Bool, label: String) -> String {
            if !text.isEmpty { return "【\(label)】\n\(text)" }
            if image { return L("【\(label)】画像を添付しました。") }
            return ""
        }
        var lines = [L("この証明を添削してください。"), ""]
        let question = describe(text: submission.questionText, image: submission.questionImage != nil, label: L("問題"))
        let answer = describe(text: submission.answerText, image: submission.answerImage != nil, label: L("解答"))
        if !question.isEmpty { lines.append(question); lines.append("") }
        if !answer.isEmpty { lines.append(answer) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lays the marking out as text, so it renders in an ordinary chat
    /// bubble and stays in the thread's history like any other reply.
    private static func markingReport(_ review: ProofReviewResult) -> String {
        var lines = ["【\(review.score) / \(review.maxScore)点】", "", review.verdict, ""]
        lines.append(L("■ 採点内訳"))
        for item in review.criteria {
            lines.append("・\(item.name)　\(item.earnedPoints)/\(item.maxPoints)点")
            if !item.comment.isEmpty { lines.append("　　\(item.comment)") }
        }
        if !review.issues.isEmpty {
            lines.append("")
            lines.append(L("■ 指摘"))
            for issue in review.issues {
                lines.append("・[\(issue.kind.title)] \(issue.excerpt)")
                lines.append("　　\(issue.explanation)")
                if !issue.suggestion.isEmpty { lines.append(L("　　→ \(issue.suggestion)")) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func cancelAIChatResponse() {
        guard let selectedAIChatThread else { return }
        let threadKey = aiChatThreadKey(selectedAIChatThread)
        aiChatTasks[threadKey]?.cancel()
        aiChatTasks[threadKey] = nil
        aiChatRespondingThreadIDs.remove(threadKey)
    }

    private func deleteAIChatThread(_ thread: AIChatThread) {
        NotificationCenter.default.post(
            name: .studiquoCloseAIChatTab,
            object: thread.persistentModelID
        )
        let threadKey = aiChatThreadKey(thread)
        aiChatTasks[threadKey]?.cancel()
        aiChatTasks[threadKey] = nil
        aiChatRespondingThreadIDs.remove(threadKey)
        aiChatDrafts[threadKey] = nil
        aiChatAttachments[threadKey] = nil
        aiChatContextOverrides[threadKey] = nil

        if selectedAIChatThread?.persistentModelID == thread.persistentModelID {
            selectedAIChatThread = nil
        }

        modelContext.delete(thread)
        try? modelContext.save()
        loadAIChatThreads()

        if selectedAIChatThread == nil {
            selectedAIChatThread = aiChatThreads.first
        }
    }

    private func messageText(_ text: String, with attachments: [AIChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let attachmentLines = attachments.map { attachment in
            "- \(attachment.kind.label): \(attachment.name)"
        }.joined(separator: "\n")
        return """
        \(text)

        \(L("添付された資料"))
        \(attachmentLines)
        """
    }

    /// Hands the model the text of the page the student is looking at, so
    /// "この問題" and the like have something to refer to. Handwriting reaches
    /// it once the page has been through text recognition; typed elements are
    /// always available.
    private func aiChatNoteContext() -> String {
        guard let page = drawingHistoryPage ?? currentPrimaryPage else { return "" }
        var parts: [String] = []
        let recognized = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recognized.isEmpty { parts.append(recognized) }
        let typed = page.elements
            .filter { $0.kind == .text }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        parts.append(contentsOf: typed)
        return parts.joined(separator: "\n")
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
                primaryShowsAIChat = false
                primaryFriendChatID = nil
                primaryPageIndex = 0
            } else {
                secondaryNotebook = targetNotebook
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
                secondaryFriendChatID = nil
                secondaryPageIndex = 0
            }
        case .flashcardDeck(let deck):
            if pane == .primary {
                primaryFlashcardDeck = deck
                primaryOverrideNotebook = nil
                primaryShowsAIChat = false
                primaryFriendChatID = nil
            } else {
                secondaryFlashcardDeck = deck
                secondaryNotebook = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
                secondaryFriendChatID = nil
            }
        case .web(_, let homeURL):
            // WebSearchPane only ever renders in the secondary slot today;
            // route there regardless so a web tab never silently no-ops.
            webBrowser.openHomeIfNeeded(homeURL)
            secondaryNotebook = nil
            secondaryFlashcardDeck = nil
            secondaryShowsWeb = true
            secondaryShowsAIChat = false
            secondaryFriendChatID = nil
            if splitMode == .single { splitMode = isPortraitLayout ? .vertical : .horizontal }
            activePane = .secondary
            return
        case .ai(let id):
            loadAIChatThreads()
            guard let thread = aiChatThreads.first(where: { $0.persistentModelID == id }) else { return }
            selectedAIChatThread = thread
            announceAIChatTab(thread)
            showsTemporaryAIChat = false
            if isAIChatVisibleInSplit {
                activePane = primaryShowsAIChat ? .primary : .secondary
                return
            }
            if pane == .primary {
                primaryOverrideNotebook = nil
                primaryFlashcardDeck = nil
                primaryShowsAIChat = true
                primaryFriendChatID = nil
            } else {
                secondaryNotebook = nil
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = true
                secondaryFriendChatID = nil
            }
        case .friend(let id):
            guard let friend = friendStore.friends.first(where: { $0.id == id }) else { return }
            NotificationCenter.default.post(
                name: Notification.Name("StudiquoOpenFriendChatTab"),
                object: FriendChatTabInfo(id: friend.id, title: friend.name)
            )
            if pane == .primary {
                primaryOverrideNotebook = nil
                primaryFlashcardDeck = nil
                primaryShowsAIChat = false
                primaryFriendChatID = id
            } else {
                secondaryNotebook = nil
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
                secondaryFriendChatID = id
            }
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

    private func selectLasso() {
        isReadOnlyMode = false
        pendingShapeKindRaw = ""
        if drawingTool == .lasso {
            drawingToolRaw = DrawingToolKind.none.rawValue
            showsDrawingToolbar = false
        } else {
            drawingToolRaw = DrawingToolKind.lasso.rawValue
            showsDrawingToolbar = true
        }
    }

    private func prepareSplit(_ mode: SplitMode) {
        pendingSplitMode = isPortraitLayout ? .vertical : mode
        showsSplitSourcePicker = true
    }

    private func updateOrientation(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let portrait = size.height > size.width
        isPortraitLayout = portrait
        let wasPortrait = lastKnownPortrait
        lastKnownPortrait = portrait

        // Turning the iPad upright used to fold a side-by-side split into a
        // stacked one, which squeezed both notes into half-height strips
        // that were near-unusable. Rotating into portrait now returns to a
        // single note instead.
        //
        // Only the *transition* collapses it: reacting to `portrait` alone
        // would also tear down a split the user deliberately opened while
        // already upright, on the very next layout pass. `wasPortrait` is
        // nil until the first pass, so launching in portrait isn't mistaken
        // for a rotation into it.
        if portrait, wasPortrait == false, splitMode != .single {
            collapseSplit()
        }
        if portrait, pendingSplitMode == .horizontal {
            pendingSplitMode = .vertical
        }
    }

    /// Returns to a single pane and discards whatever the secondary pane was
    /// showing, so the closed split leaves nothing half-alive behind it.
    private func collapseSplit() {
        splitMode = .single
        splitRatio = 0.5
        primaryShowsAIChat = false
        primaryFriendChatID = nil
        secondaryNotebook = nil
        secondaryFlashcardDeck = nil
        secondaryShowsWeb = false
        secondaryShowsAIChat = false
        secondaryFriendChatID = nil
        pendingSplitMode = nil
        activePane = .primary
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
                primaryShowsAIChat = false
            } else {
                secondaryFlashcardDeck = deck
                secondaryNotebook = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
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

        if parts[0] == "ai" {
            loadAIChatThreads()
            guard let thread = aiChatThreads.first(where: {
                String(describing: $0.persistentModelID) == parts[1]
            }) else { return false }
            selectedAIChatThread = thread
            announceAIChatTab(thread)
            showsTemporaryAIChat = false
            if isAIChatVisibleInSplit {
                activePane = primaryShowsAIChat ? .primary : .secondary
                return true
            }
            if target == .primary {
                primaryOverrideNotebook = nil
                primaryFlashcardDeck = nil
                primaryShowsAIChat = true
                activePane = .primary
            } else {
                secondaryNotebook = nil
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = true
                activePane = .secondary
            }
            return true
        }

        if parts[0] == "friend", let friendID = UUID(uuidString: parts[1]) {
            guard friendStore.friends.contains(where: { $0.id == friendID }) else { return false }
            if target == .primary {
                primaryOverrideNotebook = nil
                primaryFlashcardDeck = nil
                primaryShowsAIChat = false
                primaryFriendChatID = friendID
                activePane = .primary
            } else {
                secondaryNotebook = nil
                secondaryFlashcardDeck = nil
                secondaryShowsWeb = false
                secondaryShowsAIChat = false
                secondaryFriendChatID = friendID
                activePane = .secondary
            }
            if let friend = friendStore.friends.first(where: { $0.id == friendID }) {
                NotificationCenter.default.post(
                    name: Notification.Name("StudiquoOpenFriendChatTab"),
                    object: FriendChatTabInfo(id: friend.id, title: friend.name)
                )
            }
            return true
        }

        guard parts[0] == "notebook",
              let targetNotebook = notebooks.first(where: {
                  String(describing: $0.persistentModelID) == parts[1] && !$0.isTrashed
              }) else { return false }
        if target == .primary {
            primaryOverrideNotebook = targetNotebook
            primaryFlashcardDeck = nil
            primaryShowsAIChat = false
            primaryFriendChatID = nil
            primaryPageIndex = 0
        } else {
            secondaryNotebook = targetNotebook
            secondaryFlashcardDeck = nil
            secondaryShowsWeb = false
            secondaryShowsAIChat = false
            secondaryFriendChatID = nil
            secondaryPageIndex = 0
        }
        activePane = target == .primary ? .primary : .secondary
        return true
    }

    private func completeSplitSelection(object: Any) {
        splitMode = isPortraitLayout ? .vertical : (pendingSplitMode ?? .horizontal)
        splitRatio = 0.5
        activePane = .secondary
        NotificationCenter.default.post(name: .studiquoOpenNotebookTab, object: object)
        showsSplitSourcePicker = false
    }

    private var activeNotebook: Notebook {
        activePane == .secondary ? (secondaryNotebook ?? displayedPrimaryNotebook) : displayedPrimaryNotebook
    }

    /// True when the pane the user last touched is a flashcard deck, which
    /// has no pages for the page-level tools to act on.
    private var activePaneShowsFlashcards: Bool {
        activePane == .secondary ? secondaryFlashcardDeck != nil : primaryFlashcardDeck != nil
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
        recordPageRemoval(page, in: target)
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
            splitMode = .single
            activePane = .primary
        } else if target === notebook {
            onHome()
        }
    }

    private func createCompanionNotebook() -> Notebook {
        let companion = Notebook(title: "\(notebook.title) ノート")
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
        for page in target.sortedPages { page.order += 1 }
        let newPage = NotePage(order: 0)
        newPage.pageTemplate = template
        // A prepend always creates a genuinely empty model. Spell these out
        // so future initializer changes cannot accidentally clone content
        // from the previous first page.
        newPage.drawingData = nil
        newPage.backgroundImageData = nil
        newPage.elements = []
        newPage.title = ""
        newPage.recognizedText = ""
        newPage.flashcardQuestion = ""
        newPage.flashcardAnswer = ""
        modelContext.insert(newPage)
        newPage.notebook = target
        if !target.pages.contains(where: { $0 === newPage }) {
            target.pages.append(newPage)
        }
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        try? modelContext.save()
        if target === secondaryNotebook {
            secondaryPageIndex = 0
            activePane = .secondary
        } else {
            primaryPageIndex = 0
            activePane = .primary
        }
    }

    private func addPendingPage(template: PageTemplate, paperColorHex: String) {
        guard let target = notebookPendingNewPage else { return }
        let newPage = NotePage(order: target.pages.count)
        newPage.pageTemplate = template
        newPage.paperColorHex = paperColorHex
        newPage.notebook = target
        target.pages.append(newPage)
        target.refreshLibraryMetadata()
        target.updatedAt = .now
        recordPageAddition(newPage, in: target)
        if target === secondaryNotebook {
            secondaryPageIndex = target.pages.count - 1
            activePane = .secondary
        } else {
            primaryPageIndex = target.pages.count - 1
            activePane = .primary
        }
        notebookPendingNewPage = nil
    }

    /// Makes a freshly added page undoable.
    ///
    /// The page is carried in a slot rather than captured directly: undo
    /// deletes it, and redo has to insert a new one, so anything holding a
    /// direct reference would be pointing at a deleted object the second time
    /// around.
    private func recordPageAddition(_ page: NotePage, in notebook: Notebook) {
        let slot = PageSlot(page)
        let snapshot = NotePageSnapshot(page)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak notebook] in
                guard let notebook, let page = slot.page else { return }
                notebook.pages.removeAll { $0 === page }
                context.delete(page)
                slot.page = nil
                notebook.refreshLibraryMetadata()
            },
            redo: { [weak notebook] in
                guard let notebook else { return }
                let restored = snapshot.makePage(in: context, notebook: notebook)
                notebook.pages.append(restored)
                slot.page = restored
                notebook.refreshLibraryMetadata()
            }
        )
    }

    /// The mirror image, for a page about to be deleted. Call before removing
    /// it, while there is still something to snapshot.
    private func recordPageRemoval(_ page: NotePage, in notebook: Notebook) {
        let slot = PageSlot(page)
        let snapshot = NotePageSnapshot(page)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak notebook] in
                guard let notebook else { return }
                let restored = snapshot.makePage(in: context, notebook: notebook)
                notebook.pages.append(restored)
                slot.page = restored
                notebook.refreshLibraryMetadata()
            },
            redo: { [weak notebook] in
                guard let notebook, let page = slot.page else { return }
                notebook.pages.removeAll { $0 === page }
                context.delete(page)
                slot.page = nil
                notebook.refreshLibraryMetadata()
            }
        )
    }

    /// Makes a newly placed element — a shape, a photo, a text box, a tape —
    /// undoable.
    private func recordElementAddition(_ element: PageElement, on page: NotePage) {
        let slot = ElementSlot(element)
        let snapshot = PageElementSnapshot(element)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak page] in
                guard let page, let element = slot.element else { return }
                page.elements.removeAll { $0 === element }
                context.delete(element)
                slot.element = nil
            },
            redo: { [weak page] in
                guard let page else { return }
                let restored = snapshot.makeElement()
                restored.page = page
                page.elements.append(restored)
                context.insert(restored)
                slot.element = restored
            }
        )
    }

    private func recordElementRemoval(_ element: PageElement, on page: NotePage) {
        let slot = ElementSlot(element)
        let snapshot = PageElementSnapshot(element)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak page] in
                guard let page else { return }
                let restored = snapshot.makeElement()
                restored.page = page
                page.elements.append(restored)
                context.insert(restored)
                slot.element = restored
            },
            redo: { [weak page] in
                guard let page, let element = slot.element else { return }
                page.elements.removeAll { $0 === element }
                context.delete(element)
                slot.element = nil
            }
        )
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

    /// Which page undo/redo act on. Only the canvas that was actually drawn
    /// on holds the matching stroke history, and in continuous scrolling the
    /// page under the pencil is often *not* the one the scroll position has
    /// centred — so targeting `currentPrimaryPage` regularly sent the
    /// notification to a canvas with an empty history, and the button did
    /// nothing. The last activated page is checked against the notebooks on
    /// screen so a page left over from a previously open note is ignored.
    private var drawingHistoryPage: NotePage? {
        if let lastActivePage,
           lastActivePage.notebook === displayedPrimaryNotebook
            || lastActivePage.notebook === secondaryNotebook {
            return lastActivePage
        }
        return activePage ?? currentPrimaryPage
    }

    /// Every undo/redo carries a fresh id so the shared history can tell one
    /// press apart from the next, and so two canvases showing the same page
    /// don't both pop the stack for a single press.
    /// Sends one undo (or redo) to whichever history holds the more recent
    /// step.
    ///
    /// Strokes and everything else are tracked separately — see
    /// `NoteActionHistory` for why — but the button has to behave as though
    /// there is a single history, so the two are compared by time here and
    /// only one of them acts.
    private func postDrawingHistoryRequest(_ name: Notification.Name) {
        let isUndo = name == .studiquoUndoDrawing
        let page = drawingHistoryPage
        let inkDate = page.flatMap {
            isUndo
                ? DrawingHistoryStore.shared.lastUndoDate(for: $0.persistentModelID)
                : DrawingHistoryStore.shared.lastRedoDate(for: $0.persistentModelID)
        }
        let actionDate = isUndo
            ? NoteActionHistory.shared.lastUndoDate
            : NoteActionHistory.shared.lastRedoDate

        if let actionDate, inkDate == nil || actionDate > inkDate! {
            let request = UUID()
            if isUndo {
                NoteActionHistory.shared.undo(requestID: request)
            } else {
                NoteActionHistory.shared.redo(requestID: request)
            }
            notebook.updatedAt = .now
            try? modelContext.save()
            return
        }

        guard let page else { return }
        NotificationCenter.default.post(
            name: name,
            object: page,
            userInfo: ["request": UUID()]
        )
    }

    private func addTextElement() {
        guard !activePaneShowsFlashcards, let page = activePage ?? currentPrimaryPage else { return }
        let value = textToInsert.trimmingCharacters(in: .whitespacesAndNewlines)
        let element = PageElement(kind: .text, text: value, width: 0.42, height: 0.12, colorHex: selectedElementColorHex)
        element.layerIndex = nextLayerIndex(on: page)
        element.page = page
        page.elements.append(element)
        recordElementAddition(element, on: page)
        page.notebook?.updatedAt = .now
        textToInsert = ""
        NotificationCenter.default.post(
            name: .studiquoSelectPageElement,
            object: element.persistentModelID
        )
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
        if [.rectangle, .ellipse].contains(kind) {
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
        recordElementRemoval(element, on: page)
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

    private func exportAllPagesAsPDF() {
        guard let url = ExportService.makePDF(from: activeNotebook) else { return }
        presentPDFExporter(url: url)
    }

    private func exportCurrentPageAsPDF() {
        guard let page = activePage,
              let url = ExportService.makePDF(from: page, notebookTitle: activeNotebook.title) else { return }
        presentPDFExporter(url: url)
    }

    private func presentPDFExporter(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        pdfExportDocument = PDFExportDocument(data: data)
        pdfExportFilename = url.lastPathComponent
        showsPDFExporter = true
    }
}

struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
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

struct PDFSaveModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var document: PDFExportDocument?
    let filename: String

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: $isPresented,
            document: document,
            contentType: .pdf,
            defaultFilename: filename
        ) { _ in
            document = nil
        }
    }
}

private struct ScientificCalculatorPanel: View {
    @Binding var expression: String
    @Binding var result: String
    @Binding var center: CGPoint?
    let containerSize: CGSize
    let onClose: () -> Void
    @State private var dragOrigin: CGPoint?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
    private let keys = [
        "sin", "cos", "tan", "AC",
        "ln", "log", "sqrt", "⌫",
        "(", ")", "^", "÷",
        "7", "8", "9", "×",
        "4", "5", "6", "−",
        "1", "2", "3", "+",
        "π", "0", ".", "=",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("関数電卓", systemImage: "function")
                    .font(.headline)
                Spacer()
                Text("DEG").font(.caption2.bold()).foregroundStyle(.secondary)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.indigo.opacity(0.16))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        let initial = dragOrigin ?? resolvedCenter
                        if dragOrigin == nil { dragOrigin = initial }
                        center = clamped(CGPoint(
                            x: initial.x + value.translation.width,
                            y: initial.y + value.translation.height
                        ))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )

            VStack(alignment: .trailing, spacing: 6) {
                Text(expression.isEmpty ? "0" : expression)
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(result)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(14)
            .background(Color(.secondarySystemBackground))

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(keys, id: \.self) { key in
                    Button { handle(key) } label: {
                        Text(key == "sqrt" ? "√" : key)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(keyColor(key), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(keyForeground(key))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 350, height: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.indigo.opacity(0.35)))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 7)
        .position(resolvedCenter)
        .onAppear {
            if center == nil { center = clamped(CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)) }
        }
    }

    private var resolvedCenter: CGPoint {
        clamped(center ?? CGPoint(x: containerSize.width / 2, y: containerSize.height / 2))
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let halfWidth: CGFloat = min(175, containerSize.width / 2)
        let halfHeight: CGFloat = min(250, containerSize.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, containerSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, containerSize.height - halfHeight))
        )
    }

    private func keyColor(_ key: String) -> Color {
        if key == "=" { return .indigo }
        if ["÷", "×", "−", "+", "^"].contains(key) { return .orange.opacity(0.82) }
        if ["sin", "cos", "tan", "ln", "log", "sqrt", "(", ")", "π"].contains(key) {
            return .teal.opacity(0.18)
        }
        if key == "AC" || key == "⌫" { return .red.opacity(0.16) }
        return Color(.tertiarySystemFill)
    }

    private func keyForeground(_ key: String) -> Color {
        if key == "=" || ["÷", "×", "−", "+", "^"].contains(key) { return .white }
        if key == "AC" || key == "⌫" { return .red }
        return .primary
    }

    private func handle(_ key: String) {
        switch key {
        case "AC":
            expression = ""
            result = "0"
        case "⌫":
            if !expression.isEmpty { expression.removeLast() }
        case "=":
            evaluate()
        case "sin", "cos", "tan", "ln", "log", "sqrt":
            expression += "\(key)("
        case "÷": expression += "/"
        case "×": expression += "*"
        case "−": expression += "-"
        case "^": expression += "^"
        case "π": expression += "π"
        default: expression += key
        }
    }

    private func evaluate() {
        guard !expression.isEmpty else { return }
        let transformed = expression
            .replacingOccurrences(of: "π", with: "Math.PI")
            .replacingOccurrences(of: "^", with: "**")
        let script = """
        const sin = x => Math.sin(x * Math.PI / 180);
        const cos = x => Math.cos(x * Math.PI / 180);
        const tan = x => Math.tan(x * Math.PI / 180);
        const ln = x => Math.log(x);
        const log = x => Math.log10(x);
        const sqrt = x => Math.sqrt(x);
        \(transformed)
        """
        guard let value = JSContext()?.evaluateScript(script), !value.isUndefined else {
            result = "エラー"
            return
        }
        let number = value.toDouble()
        guard number.isFinite else { result = "エラー"; return }
        result = number.rounded() == number
            ? String(format: "%.0f", number)
            : String(format: "%.10g", number)
    }
}

private enum TimeToolMode: String, CaseIterable, Identifiable {
    case stopwatch = "ストップウォッチ"
    case timer = "タイマー"
    var id: String { rawValue }
}

@MainActor
@Observable
private final class TimeToolModel {
    var mode: TimeToolMode = .stopwatch
    var stopwatchRunning = false
    var stopwatchStartedAt: Date?
    var stopwatchAccumulated: TimeInterval = 0
    var timerDuration: TimeInterval
    var timerRemaining: TimeInterval
    var timerRunning = false
    var timerEndDate: Date?
    @ObservationIgnored private var alarmTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.double(forKey: "studiquoLastTimerDuration")
        let initial = saved > 0 ? saved : 300
        timerDuration = initial
        timerRemaining = initial
    }

    var isRunning: Bool {
        mode == .stopwatch ? stopwatchRunning : timerRunning
    }

    var showsToolbarTime: Bool {
        switch mode {
        case .stopwatch:
            stopwatchRunning || stopwatchAccumulated > 0
        case .timer:
            timerRunning || (timerRemaining > 0 && timerRemaining < timerDuration)
        }
    }

    func stopwatchValue(at date: Date) -> TimeInterval {
        stopwatchAccumulated + (stopwatchRunning ? date.timeIntervalSince(stopwatchStartedAt ?? date) : 0)
    }

    func timerValue(at date: Date) -> TimeInterval {
        timerRunning ? max(0, timerEndDate?.timeIntervalSince(date) ?? timerRemaining) : timerRemaining
    }

    func toolbarText(at date: Date) -> String {
        let value = mode == .stopwatch ? stopwatchValue(at: date) : timerValue(at: date)
        let safe = max(0, value)
        let hours = Int(safe) / 3600
        let minutes = Int(safe) / 60 % 60
        let seconds = Int(safe) % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    func setTimerDuration(_ duration: TimeInterval) {
        let safe = max(0, duration)
        timerDuration = safe
        timerRemaining = safe
        timerEndDate = nil
        UserDefaults.standard.set(safe, forKey: "studiquoLastTimerDuration")
    }

    func startTimer() {
        guard timerRemaining > 0 else { return }
        timerRunning = true
        let end = Date.now.addingTimeInterval(timerRemaining)
        timerEndDate = end
        alarmTask?.cancel()
        alarmTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            } catch { return }
            guard let self, self.timerRunning, self.timerEndDate == end else { return }
            self.timerRemaining = 0
            self.timerRunning = false
            self.timerEndDate = nil
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
    }

    func pauseTimer() {
        timerRemaining = timerValue(at: .now)
        timerRunning = false
        timerEndDate = nil
        alarmTask?.cancel()
        alarmTask = nil
    }

    func resetTimer() {
        timerRunning = false
        timerEndDate = nil
        timerRemaining = timerDuration
        alarmTask?.cancel()
        alarmTask = nil
    }

    func toggleFromToolbar() {
        switch mode {
        case .stopwatch:
            if stopwatchRunning {
                stopwatchAccumulated = stopwatchValue(at: .now)
                stopwatchStartedAt = nil
                stopwatchRunning = false
            } else {
                stopwatchStartedAt = .now
                stopwatchRunning = true
            }
        case .timer:
            if timerRunning { pauseTimer() }
            else { startTimer() }
        }
    }
}

private struct TimeToolView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TimeToolModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("時間ツール", selection: $model.mode) {
                    ForEach(TimeToolMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Spacer()

                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let value = model.mode == .stopwatch
                        ? model.stopwatchValue(at: context.date)
                        : model.timerValue(at: context.date)
                    Text(formattedTime(value, showsTenths: model.mode == .stopwatch))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(model.mode == .stopwatch ? Color.indigo : Color.orange)
                        .minimumScaleFactor(0.65)
                }

                if model.mode == .stopwatch { stopwatchControls }
                else { timerControls }

                Spacer()
            }
            .padding(24)
            .background(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.10), Color.orange.opacity(0.07), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .navigationTitle("時間")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var stopwatchControls: some View {
        HStack(spacing: 14) {
            Button("リセット", systemImage: "arrow.counterclockwise", action: resetStopwatch)
                .buttonStyle(.bordered)
                .disabled(model.stopwatchRunning || model.stopwatchAccumulated == 0)
            Button(model.stopwatchRunning ? "一時停止" : "スタート",
                   systemImage: model.stopwatchRunning ? "pause.fill" : "play.fill",
                   action: toggleStopwatch)
                .buttonStyle(.borderedProminent)
                .tint(model.stopwatchRunning ? .orange : .indigo)
        }
        .controlSize(.large)
    }

    private var timerControls: some View {
        VStack(spacing: 18) {
            if !model.timerRunning {
                timerAdjustment
            }
            HStack(spacing: 14) {
                Button("リセット", systemImage: "arrow.counterclockwise", action: resetTimer)
                    .buttonStyle(.bordered)
                Button(model.timerRunning ? "一時停止" : "スタート",
                       systemImage: model.timerRunning ? "pause.fill" : "play.fill",
                       action: toggleTimer)
                    .buttonStyle(.borderedProminent)
                    .tint(model.timerRunning ? .orange : .green)
                    .disabled(!model.timerRunning && model.timerRemaining <= 0)
            }
            .controlSize(.large)
        }
    }

    private var timerAdjustment: some View {
        HStack(spacing: 8) {
            timePicker("時間", range: 0...23, value: Binding(
                get: { Int(model.timerRemaining) / 3600 },
                set: { updateTimer(hours: $0) }
            ))
            timePicker("分", range: 0...59, value: Binding(
                get: { Int(model.timerRemaining) / 60 % 60 },
                set: { updateTimer(minutes: $0) }
            ))
            timePicker("秒", range: 0...59, value: Binding(
                get: { Int(model.timerRemaining) % 60 },
                set: { updateTimer(seconds: $0) }
            ))
        }
        .frame(height: 105)
    }

    private func timePicker(_ label: String, range: ClosedRange<Int>, value: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Picker(label, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(width: 72)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func updateTimer(hours: Int? = nil, minutes: Int? = nil, seconds: Int? = nil) {
        let current = Int(model.timerRemaining)
        let h = hours ?? current / 3600
        let m = minutes ?? current / 60 % 60
        let s = seconds ?? current % 60
        model.setTimerDuration(TimeInterval(h * 3600 + m * 60 + s))
    }

    private func toggleStopwatch() {
        if model.stopwatchRunning {
            model.stopwatchAccumulated = model.stopwatchValue(at: .now)
            model.stopwatchStartedAt = nil
        } else {
            model.stopwatchStartedAt = .now
            dismiss()
        }
        model.stopwatchRunning.toggle()
    }

    private func resetStopwatch() {
        model.stopwatchRunning = false
        model.stopwatchStartedAt = nil
        model.stopwatchAccumulated = 0
    }

    private func toggleTimer() {
        if model.timerRunning {
            model.pauseTimer()
        } else {
            guard model.timerRemaining > 0 else { return }
            model.startTimer()
            dismiss()
        }
    }

    private func resetTimer() {
        model.resetTimer()
    }

    private func formattedTime(_ interval: TimeInterval, showsTenths: Bool) -> String {
        let safe = max(0, interval)
        let hours = Int(safe) / 3600
        let minutes = Int(safe) / 60 % 60
        let seconds = Int(safe) % 60
        if showsTenths {
            let tenths = Int(safe * 10) % 10
            return hours > 0
                ? String(format: "%02d:%02d:%02d.%d", hours, minutes, seconds, tenths)
                : String(format: "%02d:%02d.%d", minutes, seconds, tenths)
        }
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
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
/// The draggable pen bar.
///
/// Deliberately a separate view: its position is `@State` here rather than on
/// `NoteEditorView`, so a drag invalidates only this small subtree instead of
/// the entire editor. The bar tracks the finger exactly as a result.
private struct FloatingDrawingToolbar: View {
    let identity: String
    let paneSize: CGSize
    let prefersTopEdge: Bool
    let isLeftHanded: Bool
    let isAdjustingToolSize: Bool
    let showsSizeControl: Bool
    let controls: (Bool) -> AnyView
    let sizeControl: (Bool) -> AnyView

    /// `nil` until the bar has been moved, so it keeps following the pane's
    /// default edge while it is left where it started.
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var isVertical = false

    private var barWidth: CGFloat {
        isVertical ? 54 : min(760, max(54, paneSize.width - 16))
    }

    private var barHeight: CGFloat {
        isVertical ? min(680, max(54, paneSize.height - 16)) : max(42, 54 * horizontalScale)
    }

    /// The full horizontal control row is about this wide at normal size.
    /// In split panes the available width is often smaller, so the row is
    /// scaled down instead of becoming horizontally scrollable.
    private var idealHorizontalContentWidth: CGFloat { showsSizeControl ? 720 : 470 }

    private var horizontalScale: CGFloat {
        guard !isVertical else { return 1 }
        return min(1, max(0.36, (barWidth - 18) / idealHorizontalContentWidth))
    }

    private var resolvedCenter: CGPoint {
        let defaultY = prefersTopEdge
            ? barHeight / 2 + 8
            : paneSize.height - barHeight / 2 - 8
        let proposed = center ?? CGPoint(x: paneSize.width / 2, y: defaultY)
        return clamped(proposed)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let halfWidth = barWidth / 2 + 6
        let halfHeight = barHeight / 2 + 6
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, paneSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, paneSize.height - halfHeight))
        )
    }

    var body: some View {
        Group {
            if isVertical {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        controls(true)
                        if showsSizeControl {
                            Divider().frame(width: 28, height: 1)
                            sizeControl(true)
                        }
                    }
                    .padding(.vertical, 9)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(isAdjustingToolSize)
            } else {
                HStack(spacing: 8) {
                    controls(false)
                    if showsSizeControl {
                        Divider().frame(width: 1, height: 24)
                        sizeControl(false)
                    }
                }
                .padding(.horizontal, 9)
                .frame(width: idealHorizontalContentWidth, height: 54)
                .scaleEffect(horizontalScale, anchor: .center)
                .frame(width: max(1, barWidth - 10), height: barHeight)
                .clipped()
            }
        }
        .buttonStyle(.borderless)
        .frame(width: barWidth, height: barHeight)
        .clipped()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .environment(\.layoutDirection, isLeftHanded ? .rightToLeft : .leftToRight)
        .position(resolvedCenter)
        .gesture(toolbarDragGesture)
        .id(identity)
        .accessibilityLabel("描画バー")
        .accessibilityHint("ドラッグすると、ノートの好きな位置へ動かせます。左右の端に寄せると縦並びになります")
    }

    /// Dragging the bar around the page.
    ///
    /// Measured in global coordinates on purpose. A `DragGesture` reports its
    /// translation in the dragged view's *own* space by default, and this bar
    /// moves as it is dragged — so each frame's translation was measured
    /// against a frame that had already shifted by the previous one. That
    /// feedback is what made the bar shudder under the pencil instead of
    /// tracking it.
    private var toolbarDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !isAdjustingToolSize else {
                    dragOrigin = nil
                    return
                }
                moveToolbar(with: value)
            }
            .onEnded { _ in
                finishToolbarDrag()
            }
    }

    private func moveToolbar(with value: DragGesture.Value) {
        let origin = dragOrigin ?? resolvedCenter
        if dragOrigin == nil { dragOrigin = origin }
        let candidate = CGPoint(
            x: origin.x + value.translation.width,
            y: origin.y + value.translation.height
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let edgeThreshold: CGFloat = 100
            isVertical = candidate.x <= edgeThreshold
                || candidate.x >= paneSize.width - edgeThreshold
            center = candidate
        }
    }

    private func finishToolbarDrag() {
        dragOrigin = nil
        guard isVertical, let current = center else { return }
        let snappedX: CGFloat = current.x < paneSize.width / 2
            ? barWidth / 2 + 6
            : paneSize.width - barWidth / 2 - 6
        withAnimation(.easeOut(duration: 0.18)) {
            center = CGPoint(x: snappedX, y: current.y)
        }
    }
}

/// Maps the 0–100 the size slider shows onto the point widths the ink engine
/// works in. Each tool gets its own point range, so "50" means a sensible
/// middle for both a pen and an eraser even though those are very different
/// numbers of points.
enum ToolSizeScale {
    case pen, eraser

    var minimumPoints: Double { self == .pen ? 0.5 : 4 }
    var maximumPoints: Double { self == .pen ? 24 : 90 }

    var range: ClosedRange<Double> { minimumPoints...maximumPoints }

    /// One step per unit of the displayed 0–100 scale.
    var step: Double { (maximumPoints - minimumPoints) / 100 }

    func percent(forPoints points: Double) -> Int {
        let span = maximumPoints - minimumPoints
        guard span > 0 else { return 0 }
        let ratio = (points - minimumPoints) / span
        return Int((min(max(ratio, 0), 1) * 100).rounded())
    }
}

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

@MainActor
private final class SpeechInputController: ObservableObject {
    @Published var isRecording = false
    @Published var isCallMode = false
    @Published var statusText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var baseText = ""

    func toggleDictation(draft: Binding<String>) {
        if isRecording {
            stop()
        } else {
            start(draft: draft, callMode: false)
        }
    }

    func toggleCall(draft: Binding<String>) {
        if isRecording && isCallMode {
            stop()
        } else {
            start(draft: draft, callMode: true)
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        isCallMode = false
        statusText = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(draft: Binding<String>, callMode: Bool) {
        Task {
            let authorized = await requestAuthorization()
            guard authorized else {
                statusText = L("マイクまたは音声認識の許可が必要です。")
                return
            }
            do {
                try beginRecognition(draft: draft, callMode: callMode)
            } catch {
                statusText = L("音声入力を開始できませんでした：\(error.localizedDescription)")
                stop()
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let micAllowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        return speechAllowed && micAllowed
    }

    private func beginRecognition(draft: Binding<String>, callMode: Bool) throws {
        stop()
        baseText = draft.wrappedValue

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        request = newRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
            newRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        isCallMode = callMode
        statusText = callMode ? L("通話モードで聞き取っています…") : L("文字起こし中…")

        task = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString {
                    let separator = self.baseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                    draft.wrappedValue = self.baseText + separator + text
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }
}

private struct AppAttachmentPicker: View {
    let options: [AppAttachmentOption]
    let onSelect: (AppAttachmentOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [AppAttachmentOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredOptions) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if options.isEmpty {
                    ContentUnavailableView(
                        L("追加できる資料がありません"),
                        systemImage: "tray",
                        description: Text(L("ホーム画面で資料を作成すると、ここからAIトークに追加できます。"))
                    )
                }
            }
            .navigationTitle(L("資料を追加"))
            .searchable(text: $searchText, prompt: L("資料を検索"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる")) { dismiss() }
                }
            }
        }
    }
}

private struct AIChatPane: View {
    let threads: [AIChatThread]
    let selectedThread: AIChatThread?
    @Binding var draft: String
    @Binding var attachments: [AIChatAttachment]
    let onSelectThread: (AIChatThread) -> Void
    let onNewThread: () -> Void
    let onDeleteThread: (AIChatThread) -> Void
    let onSend: () -> Void
    let respondingThreadIDs: Set<String>
    let onCancel: () -> Void
    /// Runs the two-stage marker over whatever the marking box collected.
    let onGradeProof: (ProofSubmission) -> Void
    let onInsertAssistantMessage: (String) -> Void
    let onAttachDroppedTab: (String) -> AIChatAttachment?
    let onSelectAppAttachment: () -> [AppAttachmentOption]
    let onPaneDrop: (String) -> Bool

    /// Whether the app knows where its AI server is. The API key itself lives
    /// on that server, so there is nothing for the student to enter.
    @State private var hasKey = AI.provider.isConfigured
    @State private var isHistorySidebarVisible = true
    @State private var pendingDeleteThread: AIChatThread?
    @State private var attachmentPickerMode: AttachmentPickerMode?
    @State private var isDropTargeted = false
    @State private var isComposerDropTargeted = false
    /// The marking box, opened from the composer's + menu.
    @State private var isMarkingBoxOpen = false
    @State private var showsAppAttachmentPicker = false
    @State private var markingQuestionText = ""
    @State private var markingAnswerText = ""
    @State private var markingQuestionSnippet: PageSnippet?
    @State private var markingAnswerSnippet: PageSnippet?
    @State private var showsCameraScanner = false
    @StateObject private var speechInput = SpeechInputController()

    private enum AttachmentPickerMode: Identifiable {
        case files
        case folder

        var id: String {
            switch self {
            case .files: return "files"
            case .folder: return "folder"
            }
        }

        var allowedContentTypes: [UTType] {
            switch self {
            case .files: return [.item]
            case .folder: return [.folder]
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isHistorySidebarVisible {
                    historySidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isHistorySidebarVisible.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isHistorySidebarVisible ? L("履歴を閉じる") : L("履歴を開く"))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedThread?.title ?? L("新しいトーク"))
                                .font(.headline)
                                .lineLimit(1)
                            Text(hasKey ? AI.provider.displayName : L("AIサーバー未設定"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: hasKey ? "sparkles" : "exclamationmark.triangle")
                            .foregroundStyle(hasKey ? Color.accentColor : Color.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                if messages.isEmpty {
                                    VStack(spacing: 12) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 34))
                                            .foregroundStyle(Color.accentColor)
                                        Text("何を手伝いましょうか？")
                                            .font(.title3.weight(.semibold))
                                        Text(hasKey
                                             ? L("開いているページの内容も踏まえて答えます。わからないところを聞いてみてください。")
                                             : L("AIサーバーのURLが設定されていません。ホーム画面の設定からMCPクラウド連携を確認してください。"))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 30)
                                    }
                                    .padding(.top, 60)
                                    .frame(maxWidth: .infinity)
                                }

                                ForEach(messages) { message in
                                    AIChatBubble(
                                        message: message,
                                        onInsertOnPage: { onInsertAssistantMessage(message.text) }
                                    )
                                        .id(message.persistentModelID)
                                }
                            }
                            .padding(18)
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if !attachments.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(attachments) { attachment in
                                        attachmentChip(attachment)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                            .scrollIndicators(.hidden)
                        }

                        if isMarkingBoxOpen { markingBox }

                        HStack(alignment: .bottom, spacing: 10) {
                            Menu {
                                Button {
                                    showsAppAttachmentPicker = true
                                } label: {
                                    Label(L("アプリ内の資料を追加"), systemImage: "square.grid.2x2")
                                }

                                Divider()

                                Button {
                                    attachmentPickerMode = .files
                                } label: {
                                    Label(L("ファイルを追加"), systemImage: "doc.badge.plus")
                                }

                                Button {
                                    attachmentPickerMode = .folder
                                } label: {
                                    Label(L("フォルダーを追加"), systemImage: "folder.badge.plus")
                                }

                                Button {
                                    showsCameraScanner = true
                                } label: {
                                    Label(L("カメラで撮影"), systemImage: "camera")
                                }
                                .disabled(!VNDocumentCameraViewController.isSupported)

                                Button {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        isMarkingBoxOpen = true
                                    }
                                } label: {
                                    Label(L("AI採点"), systemImage: "checkmark.seal")
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .accessibilityLabel(L("ファイルやフォルダーを追加"))

                            TextField("メッセージを入力", text: $draft, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                                .submitLabel(.send)
                                .onSubmit(onSend)

                            Button {
                                speechInput.toggleDictation(draft: $draft)
                            } label: {
                                Image(systemName: speechInput.isRecording && !speechInput.isCallMode ? "waveform.circle.fill" : "waveform")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(speechInput.isRecording && !speechInput.isCallMode ? Color.accentColor : .primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("文字起こし"))

                            Button {
                                speechInput.toggleCall(draft: $draft)
                            } label: {
                                Image(systemName: speechInput.isRecording && speechInput.isCallMode ? "phone.circle.fill" : "phone")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(speechInput.isRecording && speechInput.isCallMode ? Color.green : .primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("通話"))

                            // Turns into a stop button while a reply is streaming, so
                            // a long answer can be cut short.
                            Button(action: isResponding ? onCancel : onSend) {
                                Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(sendButtonColor, in: Circle())
                            }
                            .disabled(!isResponding && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(isResponding ? L("生成を止める") : L("送信"))
                        }

                        if !speechInput.statusText.isEmpty {
                            Text(speechInput.statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 44)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .scaleEffect(isComposerDropTargeted ? 1.04 : 1.0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isComposerDropTargeted)
                    .dropDestination(for: String.self) { items, _ in
                        guard let value = items.first else { return false }
                        if let attachment = onAttachDroppedTab(value) {
                            attachments.append(attachment)
                            return true
                        }
                        return onPaneDrop(value)
                    } isTargeted: { targeted in
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                            isComposerDropTargeted = targeted
                        }
                    }
                    .overlay {
                        if isComposerDropTargeted {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                                Image(systemName: "plus")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }

            if let pendingDeleteThread {
                deleteConfirmationCard(for: pendingDeleteThread)
            }
        }
        .background(Color(uiColor: .systemBackground))
        // The whole pane accepts crops, not just the composer — aiming a
        // drag at a text field on a split screen is fiddly, and there is
        // nothing else here a page snippet could mean.
        .dropDestination(for: PageSnippet.self) { snippets, _ in
            for snippet in snippets { accept(snippet) }
            return !snippets.isEmpty
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first else { return false }
            return onPaneDrop(value)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: attachmentPickerBinding,
            allowedContentTypes: attachmentPickerMode?.allowedContentTypes ?? [.item],
            allowsMultipleSelection: attachmentPickerMode == .files
        ) { result in
            guard let mode = attachmentPickerMode else { return }
            if case .success(let urls) = result {
                let kind: AIChatAttachment.Kind = mode == .folder ? .folder : .file
                attachments.append(contentsOf: urls.map {
                    AIChatAttachment(name: $0.lastPathComponent, path: $0.path, kind: kind)
                })
            }
            attachmentPickerMode = nil
        }
        .sheet(isPresented: $showsCameraScanner) {
            DocumentScannerView { images in
                attachments.append(contentsOf: images.enumerated().compactMap { index, image in
                    guard let data = image.pngData() else { return nil }
                    return AIChatAttachment(
                        name: L("撮影画像 \(index + 1)"),
                        path: "",
                        kind: .camera,
                        imageData: data
                    )
                })
            }
        }
        .sheet(isPresented: $showsAppAttachmentPicker) {
            AppAttachmentPicker(
                options: onSelectAppAttachment(),
                onSelect: { option in
                    attachments.append(option.attachment)
                    showsAppAttachmentPicker = false
                }
            )
        }
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onNewThread) {
                Label("新しいトーク", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Text("履歴")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            List {
                ForEach(threads) { thread in
                    Button {
                        onSelectThread(thread)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "message")
                                .foregroundStyle(.secondary)
                            Text(thread.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isResponding(thread) {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            isSelected(thread)
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteThread = thread
                        } label: {
                            Label(L("削除"), systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
        .frame(width: 210)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var messages: [AIChatMessage] {
        selectedThread?.sortedMessages ?? []
    }

    private var isResponding: Bool {
        guard let selectedThread else { return false }
        return isResponding(selectedThread)
    }

    private func isResponding(_ thread: AIChatThread) -> Bool {
        respondingThreadIDs.contains(String(describing: thread.persistentModelID))
    }

    private func isSelected(_ thread: AIChatThread) -> Bool {
        selectedThread?.persistentModelID == thread.persistentModelID
    }

    private func deleteConfirmationCard(for thread: AIChatThread) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingDeleteThread = nil
                }

            VStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.red)

                VStack(spacing: 6) {
                    Text(L("このトークを削除しますか？"))
                        .font(.headline)
                    Text(L("削除すると、このトーク履歴は元に戻せません。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        pendingDeleteThread = nil
                    } label: {
                        Text(L("いいえ"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        onDeleteThread(thread)
                        pendingDeleteThread = nil
                    } label: {
                        Text(L("はい"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .padding(24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(20)
    }

    private var attachmentPickerBinding: Binding<Bool> {
        Binding(
            get: { attachmentPickerMode != nil },
            set: { isPresented in
                if !isPresented {
                    attachmentPickerMode = nil
                }
            }
        )
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: AIChatAttachment) -> some View {
        if attachment.kind == .snippet, let snippet = attachment.snippet {
            snippetChip(attachment, snippet: snippet)
        } else {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind.icon)
                    .foregroundStyle(.secondary)
                Text(attachment.name)
                    .lineLimit(1)
                Button {
                    attachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("添付を削除"))
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
    }

    /// A dropped crop, with the role picker that decides whether this is a
    /// marking request or just an image to talk about.
    private func snippetChip(_ attachment: AIChatAttachment, snippet: PageSnippet) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = snippet.image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 104, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Menu {
                Picker(L("役割"), selection: roleBinding(for: attachment)) {
                    ForEach(AIChatAttachment.ProofRole.allCases) { role in
                        Text(role.label).tag(role)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(attachment.proofRole.label)
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(attachment.proofRole.tint)
            }
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(attachment.proofRole == .none ? .clear : attachment.proofRole.tint, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel(L("添付を削除"))
        }
    }

    private func roleBinding(for attachment: AIChatAttachment) -> Binding<AIChatAttachment.ProofRole> {
        Binding(
            get: { attachments.first { $0.id == attachment.id }?.proofRole ?? .none },
            set: { newRole in
                guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
                // Only one crop can be the question and only one the answer,
                // so claiming a role takes it off whoever held it.
                if newRole != .none {
                    for other in attachments.indices where attachments[other].proofRole == newRole {
                        attachments[other].proofRole = .none
                    }
                }
                attachments[index].proofRole = newRole
                // Tagging a crop is the same intent as opening the box from
                // the menu, so the box comes out to receive it.
                if newRole != .none { adoptTaggedSnippets() }
            }
        )
    }

    /// Moves crops the student has tagged into the marking box's slots.
    private func adoptTaggedSnippets() {
        if let question = attachments.first(where: { $0.proofRole == .question })?.snippet {
            markingQuestionSnippet = question
        }
        if let answer = attachments.first(where: { $0.proofRole == .answer })?.snippet {
            markingAnswerSnippet = answer
        }
        attachments.removeAll { $0.kind == .snippet && $0.proofRole != .none }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { isMarkingBoxOpen = true }
    }

    /// Files a dropped crop.
    ///
    /// While the marking box is open a drop fills its empty slot, which is
    /// what makes "問題をドラッグ、解答をドラッグ、採点" work without any
    /// tagging. Otherwise it lands in the composer as a taggable chip.
    private func accept(_ snippet: PageSnippet) {
        if isMarkingBoxOpen {
            if markingQuestionSnippet == nil {
                markingQuestionSnippet = snippet
            } else {
                markingAnswerSnippet = snippet
            }
            return
        }
        let taken = Set(attachments.map(\.proofRole))
        let role: AIChatAttachment.ProofRole =
            !taken.contains(.question) ? .question : (!taken.contains(.answer) ? .answer : .none)
        attachments.append(AIChatAttachment(
            name: snippet.sourceLabel,
            path: "",
            kind: .snippet,
            snippet: snippet,
            proofRole: role
        ))
    }

    // MARK: Marking box

    private var markingSubmission: ProofSubmission {
        ProofSubmission(
            questionText: markingQuestionText.trimmingCharacters(in: .whitespacesAndNewlines),
            questionImage: markingQuestionSnippet?.image,
            answerText: markingAnswerText.trimmingCharacters(in: .whitespacesAndNewlines),
            answerImage: markingAnswerSnippet?.image
        )
    }

    /// Where a proof is handed over for marking.
    ///
    /// Each half takes typing or a dropped crop, because a question is
    /// usually printed in a PDF while the working is often quicker to type
    /// than to photograph — and either can be the other way round.
    private var markingBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                Text("AI採点")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { closeMarkingBox() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("採点をやめる"))
            }

            markingSlot(
                title: L("問題"),
                placeholder: L("問題文を入力、またはページを切り抜いてドラッグ"),
                tint: .indigo,
                text: $markingQuestionText,
                snippet: $markingQuestionSnippet
            )
            markingSlot(
                title: L("解答"),
                placeholder: L("自分の証明を入力、またはページを切り抜いてドラッグ"),
                tint: .teal,
                text: $markingAnswerText,
                snippet: $markingAnswerSnippet
            )

            Button {
                let submission = markingSubmission
                onGradeProof(submission)
                withAnimation(.easeOut(duration: 0.2)) { closeMarkingBox() }
            } label: {
                Label(L("採点する"), systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(canMark ? Color.accentColor : Color.secondary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(canMark ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canMark)
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var canMark: Bool {
        !isResponding && markingSubmission.hasQuestion && markingSubmission.hasAnswer
    }

    private func closeMarkingBox() {
        isMarkingBoxOpen = false
        markingQuestionText = ""
        markingAnswerText = ""
        markingQuestionSnippet = nil
        markingAnswerSnippet = nil
    }

    private func markingSlot(
        title: String,
        placeholder: String,
        tint: Color,
        text: Binding<String>,
        snippet: Binding<PageSnippet?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)

            if let image = snippet.wrappedValue?.image {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 1))

                    Button {
                        snippet.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .background(Circle().fill(Color.black.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("画像を外す"))
                    .offset(x: 7, y: -7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }

            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...6)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .dropDestination(for: PageSnippet.self) { items, _ in
            guard let dropped = items.first else { return false }
            snippet.wrappedValue = dropped
            return true
        }
    }

    private var sendButtonColor: Color {
        if isResponding { return .red }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .accentColor
    }
}

/// Shows what the snip tool has cut out, and takes delivery of new crops.
///
/// A tray rather than a chip pinned to the page: the question is usually on a
/// different page from the answer, so a crop has to survive scrolling away
/// from where it was taken. It lives in its own modifier because the editor's
/// body is already at the limit of what the type-checker will chew through.
/// Keeps the tab bar's AI tabs in step with the conversation on screen.
///
/// Split out of the editor's body for the same reason the snippet tray was:
/// that body is long enough that two more chained modifiers put the
/// type-checker over its budget.
private struct AIChatTabSyncModifier: ViewModifier {
    let openThreadID: PersistentIdentifier?
    let onAnnounce: () -> Void
    let onSelect: (PersistentIdentifier) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: openThreadID) { _, id in
                if id != nil { onAnnounce() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .studiquoSelectAIChatTab)) { note in
                guard let id = note.object as? PersistentIdentifier else { return }
                onSelect(id)
            }
    }
}

private struct SnippetTrayModifier: ViewModifier {
    @Binding var snippets: [PageSnippet]
    @Binding var pendingQuestion: PageSnippet?
    @Binding var pendingAnswer: PageSnippet?
    let onAskAI: (PageSnippet) -> Void
    let onProofRoleSelected: (PageSnippet, AIChatAttachment.ProofRole) -> Void
    @State private var isSelectingProofSnippets = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) { tray }
            .onReceive(NotificationCenter.default.publisher(for: .studiquoPageSnipped)) { note in
                guard let snippet = note.object as? PageSnippet else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    snippets.append(snippet)
                }
            }
    }

    @ViewBuilder
    private var tray: some View {
        if !snippets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed")
                    Text("切り抜き")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Button {
                        withAnimation {
                            snippets.removeAll()
                            pendingQuestion = nil
                            pendingAnswer = nil
                            isSelectingProofSnippets = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(snippets) { snippet in
                        thumbnail(snippet)
                    }
                }

                if let latest = snippets.last {
                    HStack(spacing: 8) {
                        Button {
                            onAskAI(latest)
                            withAnimation { snippets.removeAll { $0.id == latest.id } }
                        } label: {
                            Label("AIに質問する", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                pendingQuestion = nil
                                pendingAnswer = nil
                                isSelectingProofSnippets = true
                            }
                        } label: {
                            Label("AIに採点する", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))

                    if isSelectingProofSnippets {
                        Text(pendingQuestion == nil ? "問題の切り抜き画像をタップしてください" : "解答の切り抜き画像をタップしてください")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.leading, 14)
            .padding(.bottom, 14)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private func thumbnail(_ snippet: PageSnippet) -> some View {
        Group {
            if let image = snippet.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 92, height: 62)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            Text(snippet.sourceLabel)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.thinMaterial, in: Capsule())
                .padding(3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { snippets.removeAll { $0.id == snippet.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(L("切り抜きを削除"))
        }
        .draggable(snippet) {
            // The lift preview. Without an explicit one the drag picks up the
            // chrome above as well, which reads as dragging the whole tray.
            Group {
                if let image = snippet.image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.secondary
                }
            }
            .frame(width: 120, height: 80)
        }
        .contextMenu {
            Button(role: .destructive) {
                withAnimation { snippets.removeAll { $0.id == snippet.id } }
            } label: {
                Label(L("削除"), systemImage: "trash")
            }
        }
        .overlay(alignment: .topLeading) {
            if pendingQuestion?.id == snippet.id || pendingAnswer?.id == snippet.id {
                Text(pendingQuestion?.id == snippet.id ? L("問題") : L("解答"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(pendingQuestion?.id == snippet.id ? Color.indigo : Color.teal, in: Capsule())
                    .padding(3)
            }
        }
        .onTapGesture {
            guard isSelectingProofSnippets else { return }
            selectProofSnippet(snippet)
        }
    }

    private func selectProofSnippet(_ snippet: PageSnippet) {
        if pendingQuestion == nil || pendingQuestion?.id == snippet.id {
            pendingQuestion = snippet
            if pendingAnswer?.id == snippet.id { pendingAnswer = nil }
            return
        }

        pendingAnswer = snippet
        if let question = pendingQuestion {
            onProofRoleSelected(question, .question)
            onProofRoleSelected(snippet, .answer)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                snippets.removeAll { $0.id == question.id || $0.id == snippet.id }
                pendingQuestion = nil
                pendingAnswer = nil
                isSelectingProofSnippets = false
            }
        }
    }
}

private struct AIChatBubble: View {
    let message: AIChatMessage
    let onInsertOnPage: () -> Void

    var body: some View {
        if message.role == .assistant {
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button(action: onInsertOnPage) {
                        Label(L("ページに貼り付け"), systemImage: "text.badge.plus")
                    }
                }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: 40)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

    /// The notebook already open in the primary pane is deliberately kept in
    /// this list. Opening one notebook in both panes is a supported way to
    /// work — two pages of it side by side — and ink drawn in either pane is
    /// mirrored into the other, so excluding it only made that arrangement
    /// harder to reach.
    private var available: [Notebook] { notebooks.filter { !$0.isTrashed } }

    var body: some View {
        NavigationStack {
            List {
                Section("ノート・PDF") {
                    ForEach(available) { notebook in
                        Button {
                            onSelectNotebook(notebook)
                        } label: {
                            HStack {
                                Label(notebook.title, systemImage: notebook.containsPDF ? "doc.richtext" : "note.text")
                                if notebook === primaryNotebook {
                                    Spacer()
                                    Text("表示中")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                            Label("新規暗記カード", systemImage: "rectangle.on.rectangle.angled")
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
        .alert("新規暗記カード", isPresented: $showsNewDeckAlert) {
            TextField("暗記カード名", text: $newItemName)
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
        let deck = FlashcardDeck(title: title.isEmpty ? "新しい暗記カード" : title)
        modelContext.insert(deck)
        onSelectDeck(deck)
    }
}

private struct FlashcardPaneView: View {
    @Bindable var deck: FlashcardDeck
    let onHome: () -> Void
    @State private var mode: FlashcardPaneMode

    init(deck: FlashcardDeck, onHome: @escaping () -> Void) {
        self.deck = deck
        self.onHome = onHome
        _mode = State(initialValue: deck.cards.isEmpty ? .create : .study)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if mode == .study {
                    Text("\(deck.cards.count)枚")
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
            } else {
                FlashcardStudyContent(deck: deck, onHome: onHome)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var creator: some View {
        FlashcardEditorContent(deck: deck)
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
    var onSummarizeCurrentPDFPage: () -> Void = {}
    var onSummarizeAllPDFPages: () -> Void = {}
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
                    if notebook.containsPDF {
                        Menu {
                            Button(action: onSummarizeCurrentPDFPage) {
                                Label(L("このページ"), systemImage: "doc")
                            }
                            .disabled(!currentPageHasReadablePDFText(in: pages))
                            Button(action: onSummarizeAllPDFPages) {
                                Label(L("全て"), systemImage: "doc.on.doc")
                            }
                            .disabled(!notebookHasReadablePDFText)
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel(L("PDF要約"))
                    }
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

    private var notebookHasReadablePDFText: Bool {
        notebook.pages.contains {
            $0.backgroundImageData != nil
                && !$0.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func currentPageHasReadablePDFText(in pages: [NotePage]) -> Bool {
        guard pages.indices.contains(currentPageIndex) else { return false }
        let page = pages[currentPageIndex]
        return page.backgroundImageData != nil
            && !page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func pageContent(_ pages: [NotePage]) -> some View {
        switch pageViewMode {
        case .continuous:
            ContinuousPagesView(
                notebook: notebook,
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

/// Passively observes the actual UIKit scroll offset. SwiftUI geometry
/// preferences do not update reliably while the top rubber band is stretched
/// on device, which left the prepend-page action permanently at zero. KVO
/// observes the existing scroll view without installing a competing gesture,
/// so Apple Pencil drawing remains untouched.
private struct TopOverscrollObserver: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onChange = onChange
        uiView.attachWhenReady()
    }

    final class ObserverView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachWhenReady()
        }

        func attachWhenReady() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            var candidate: UIView? = superview
            while let view = candidate, !(view is UIScrollView) { candidate = view.superview }
            guard let scrollView = candidate as? UIScrollView, scrollView !== observedScrollView else { return }
            observation = nil
            observedScrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                let overscroll = max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
                self.onChange?(overscroll)
            }
        }
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
    @Bindable var notebook: Notebook
    @Binding var currentPageIndex: Int
    let usesDarkPageDisplay: Bool
    let onAddPage: () -> Void
    var onAddPageAtTop: () -> Void = {}

    @State private var scrollTarget: PersistentIdentifier?
    @State private var bottomPullProgress: CGFloat = 0
    @State private var hasTriggeredPageAdd = false
    @State private var pullHoldStartedAt: Date?
    @State private var topPullProgress: CGFloat = 0
    @State private var hasTriggeredTopPageAdd = false
    @State private var contentHeight: CGFloat = 0
    @State private var pageNumberRevision = 0
    @State private var knownFirstPageID = ""
    /// Rubber-band overscroll needed to fill the gauge. UIKit damps
    /// overscroll heavily, so this is deliberately smaller than the finger
    /// travel it corresponds to.
    private static let pullThreshold: CGFloat = 150
    /// How long the gauge must stay full before a page is added.
    private static let pullHoldDuration: TimeInterval = 0.2
    private static let contentBottomPadding: CGFloat = 18

    var body: some View {
        let pages = notebook.sortedPages
        GeometryReader { geometry in
            let availableWidth = max(240, geometry.size.width - 32)

            ScrollView(.vertical) {
                LazyVStack(spacing: 18) {
                    TopPageAdder(
                        progress: topPullProgress,
                        holdDuration: Self.pullHoldDuration,
                        onThresholdReached: triggerTopPageAddition
                    )
                        .contentShape(Rectangle())
                        .onTapGesture { onAddPageAtTop() }
                        .background(
                            ZStack {
                                // UIKit offset observation is the primary
                                // source. Geometry is retained as a fallback
                                // for split/zoom hosting arrangements where
                                // the representable is not attached directly
                                // beneath the page-list UIScrollView.
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TopAdderMinYPreferenceKey.self,
                                        value: proxy.frame(in: .named("notePagesScroll")).minY
                                    )
                                }
                                TopOverscrollObserver { overscroll in
                                    updateTopPull(overscroll: overscroll)
                                }
                            }
                        )
                    ForEach(Array(pages.enumerated()), id: \.element.persistentModelID) { index, page in
                        let aspect = max(page.pageWidth / page.pageHeight, 0.1)
                        // At 100%, fit the whole page within the current pane.
                        // This intentionally leaves blank space beside a
                        // portrait page when the pane is wider than the page.
                        let fittedWidth = min(
                            availableWidth,
                            max(120, geometry.size.height - 48) * aspect
                        )

                        VStack(spacing: 6) {
                            PageCanvasContainer(page: page, usesDarkPageDisplay: usesDarkPageDisplay)
                                .id(page.persistentModelID)
                                .frame(width: fittedWidth, height: fittedWidth / aspect)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .onTapGesture {
                                    currentPageIndex = index
                                    scrollTarget = page.persistentModelID
                                }

                            LivePageNumberLabel(
                                notebook: notebook,
                                page: page,
                                displayIndex: index,
                                revision: pageNumberRevision
                            )
                        }
                        .id(page.persistentModelID)
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
                let index = min(max(currentPageIndex, 0), max(0, pages.count - 1))
                scrollTarget = pages.indices.contains(index) ? pages[index].persistentModelID : nil
                knownFirstPageID = pages.first.map { String(describing: $0.persistentModelID) } ?? ""
            }
            .onChange(of: scrollTarget) { _, target in
                if let target,
                   let index = pages.firstIndex(where: { $0.persistentModelID == target }),
                   index != currentPageIndex {
                    currentPageIndex = index
                }
            }
            .onChange(of: currentPageIndex) { _, index in
                guard pages.indices.contains(index) else { return }
                let target = pages[index].persistentModelID
                guard scrollTarget != target else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollTarget = target
                }
            }
            .onChange(of: pages.count) { oldCount, newCount in
                pageNumberRevision &+= 1
                let oldFirstID = knownFirstPageID
                let newFirstID = pages.first.map { String(describing: $0.persistentModelID) } ?? ""
                let wasPrepended = !knownFirstPageID.isEmpty && newFirstID != knownFirstPageID
                knownFirstPageID = newFirstID
                guard newCount > oldCount, wasPrepended, newCount > 1,
                      let oldFirstPage = pages.first(where: {
                          String(describing: $0.persistentModelID) == oldFirstID
                      }),
                      let newFirstPage = pages.first else { return }

                // Keep the old first page (now index 1) visually in place for
                // one layout pass, then slide to the newly inserted index 0.
                // This makes the successful prepend obvious instead of
                // appearing as if nothing changed beneath the user's finger.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    currentPageIndex = pages.firstIndex(where: { $0 === oldFirstPage }) ?? 1
                    scrollTarget = oldFirstPage.persistentModelID
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        currentPageIndex = 0
                        scrollTarget = newFirstPage.persistentModelID
                    }
                }
            }
            .onPreferenceChange(PagesContentHeightPreferenceKey.self) { contentHeight = $0 }
            .onPreferenceChange(TopAdderMinYPreferenceKey.self) { minY in
                guard minY.isFinite else { return }
                let geometryOverscroll = max(0, minY - Self.contentBottomPadding)
                updateTopPull(overscroll: geometryOverscroll)
            }
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
        }
        .background(Color(.secondarySystemBackground))
    }

    private func updateTopPull(overscroll: CGFloat) {
        // Exactly the same measured threshold as the bottom-page adder.
        let progress = min(max(overscroll, 0) / Self.pullThreshold, 1)
        if abs(topPullProgress - progress) > 0.001 { topPullProgress = progress }
        if progress == 0 { hasTriggeredTopPageAdd = false }
    }

    private func triggerTopPageAddition() {
        guard !hasTriggeredTopPageAdd else { return }
        hasTriggeredTopPageAdd = true
        onAddPageAtTop()
    }
}

/// Resolves both values from the current relationship every time the label
/// renders. It deliberately does not trust a captured ForEach index or cached
/// metadata, both of which can be stale for already-visible LazyVStack cells
/// after a page is prepended or deleted.
private struct LivePageNumberLabel: View {
    @Bindable var notebook: Notebook
    let page: NotePage
    let displayIndex: Int
    let revision: Int

    var body: some View {
        let pages = notebook.sortedPages
        let pageID = page.persistentModelID
        // `displayIndex` comes from the final sorted array used by this exact
        // LazyVStack cell. Looking the model up again here can observe an
        // intermediate order while a prepended page is animating into place,
        // causing the new first page to be labelled as page 2.
        let currentNumber = pages.isEmpty ? 0 : min(max(displayIndex + 1, 1), pages.count)
        Text("\(currentNumber) / \(pages.count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .id("live-page-number-\(pageID)-\(pages.count)-\(displayIndex)-\(revision)")
    }
}

private struct TopPageAdder: View {
    let progress: CGFloat
    let holdDuration: TimeInterval
    let onThresholdReached: () -> Void

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
        .task(id: progress >= 1) {
            guard progress >= 1 else { return }
            // This task is cancelled automatically if the pull drops below
            // full before the same 0.2-second hold used at the bottom elapses.
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled, progress >= 1 else { return }
            onThresholdReached()
        }
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

/// Per-page undo/redo stacks, kept outside the canvas views that use them.
///
/// They used to be `@State` on `PageCanvasContainer`. In continuous
/// scrolling those views sit in a `LazyVStack`, so scrolling a page out of
/// sight and back destroys and rebuilds the canvas — taking its whole
/// history with it and leaving Undo with nothing to pop. Keyed by page here,
/// the history outlives any individual canvas.
@MainActor
final class DrawingHistoryStore {
    static let shared = DrawingHistoryStore()

    private var undoStacks: [PersistentIdentifier: [InkDrawing]] = [:]
    private var redoStacks: [PersistentIdentifier: [InkDrawing]] = [:]
    /// Pages in least-recently-touched-first order, so the memory held by
    /// notebooks the user has moved on from is eventually released.
    private var recency: [PersistentIdentifier] = []
    /// When each page's newest undoable (and redoable) step happened, so the
    /// button can tell whether a stroke or some other edit came last — see
    /// `NoteActionHistory`.
    private var undoDates: [PersistentIdentifier: [Date]] = [:]
    private var redoDates: [PersistentIdentifier: [Date]] = [:]
    /// The last undo/redo request acted on. Two canvases can show the same
    /// page (a split of one notebook), and both answer the notification —
    /// without this the second one would pop the shared stack a second time
    /// and skip a step. The loser instead picks the new drawing up from the
    /// sync broadcast, exactly as it does for freshly drawn ink.
    private var lastHandledRequest: UUID?

    private static let depthLimit = 80
    private static let pageLimit = 12

    private init() {}

    func lastUndoDate(for page: PersistentIdentifier) -> Date? { undoDates[page]?.last }
    func lastRedoDate(for page: PersistentIdentifier) -> Date? { redoDates[page]?.last }

    func recordChange(from oldValue: InkDrawing, for page: PersistentIdentifier) {
        var stack = undoStacks[page] ?? []
        stack.append(oldValue)
        var dates = undoDates[page] ?? []
        dates.append(.now)
        if stack.count > Self.depthLimit {
            stack.removeFirst()
            dates.removeFirst()
        }
        undoStacks[page] = stack
        undoDates[page] = dates
        redoStacks[page] = []
        redoDates[page] = []
        touch(page)
    }

    func popUndo(requestID: UUID, page: PersistentIdentifier, current: InkDrawing) -> InkDrawing? {
        guard claim(requestID) else { return nil }
        guard var stack = undoStacks[page], let previous = stack.popLast() else { return nil }
        undoStacks[page] = stack
        undoDates[page]?.removeLast()
        redoStacks[page, default: []].append(current)
        redoDates[page, default: []].append(.now)
        touch(page)
        return previous
    }

    func popRedo(requestID: UUID, page: PersistentIdentifier, current: InkDrawing) -> InkDrawing? {
        guard claim(requestID) else { return nil }
        guard var stack = redoStacks[page], let next = stack.popLast() else { return nil }
        redoStacks[page] = stack
        redoDates[page]?.removeLast()
        undoStacks[page, default: []].append(current)
        undoDates[page, default: []].append(.now)
        touch(page)
        return next
    }

    private func claim(_ requestID: UUID) -> Bool {
        guard lastHandledRequest != requestID else { return false }
        lastHandledRequest = requestID
        return true
    }

    private func touch(_ page: PersistentIdentifier) {
        recency.removeAll { $0 == page }
        recency.append(page)
        while recency.count > Self.pageLimit {
            let evicted = recency.removeFirst()
            undoStacks[evicted] = nil
            redoStacks[evicted] = nil
            undoDates[evicted] = nil
            redoDates[evicted] = nil
        }
    }
}

struct PageCanvasContainer: View {
    @Bindable var page: NotePage
    @Environment(\.modelContext) private var modelContext
    @Environment(\.allowsInkSelectionTransfer) private var allowsInkSelectionTransfer
    var usesDarkPageDisplay = false
    @State private var drawing = InkDrawing()
    @State private var hasLoadedDrawing = false
    /// Distinguishes this canvas from any other canvas showing the same
    /// page, so a sync broadcast isn't re-applied by the canvas that sent it.
    @State private var canvasID = UUID()
    /// Set while applying ink that arrived from the other pane, so the
    /// change isn't echoed straight back out again.
    @State private var isApplyingSyncedDrawing = false
    /// Incremented only when this view deliberately swaps `drawing` out, so
    /// InkCanvasRepresentable knows to push it into the canvas. Never bumped
    /// for ink the user just drew — that already lives in the canvas.
    @State private var drawingVersion = 0
    @State private var isApplyingHistory = false
    @State private var drawingSaveTask: Task<Void, Never>?
    @State private var canvasDisplaySize: CGSize = .zero
    @State private var backgroundImage: UIImage?
    @State private var loadedBackgroundImageData: Data?
    @State private var recognizedSelectionText = ""
    @State private var isRecognizingSelection = false
    @State private var selectionRecognitionID = UUID()
    @AppStorage("drawingTool") private var drawingToolRaw = DrawingToolKind.pen.rawValue
    @AppStorage("drawingColor") private var drawingColorHex = "#1C1C1E"
    @AppStorage("drawingWidth") private var drawingWidth = 4.0
    @AppStorage("eraserWidth") private var eraserWidth = 24.0
    @AppStorage("readOnlyMode") private var isReadOnlyMode = false
    @AppStorage("lineCorrectionEnabled") private var isLineCorrectionEnabled = true
    @AppStorage("ellipseCorrectionEnabled") private var isEllipseCorrectionEnabled = true
    @AppStorage("rectangleCorrectionEnabled") private var isRectangleCorrectionEnabled = true
    @AppStorage("triangleCorrectionEnabled") private var isTriangleCorrectionEnabled = true
    @AppStorage("parabolaCorrectionEnabled") private var isParabolaCorrectionEnabled = true
    @AppStorage("curveCorrectionEnabled") private var isCurveCorrectionEnabled = true
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
                            contentScale: displaySize.width / max(page.pageWidth, 1),
                            isLineCorrectionEnabled: isLineCorrectionEnabled,
                            isEllipseCorrectionEnabled: isEllipseCorrectionEnabled,
                            isRectangleCorrectionEnabled: isRectangleCorrectionEnabled,
                            isTriangleCorrectionEnabled: isTriangleCorrectionEnabled,
                            isParabolaCorrectionEnabled: isParabolaCorrectionEnabled,
                            isCurveCorrectionEnabled: isCurveCorrectionEnabled,
                            pendingShapeKind: pendingShapeKind,
                            onActivate: {
                                NotificationCenter.default.post(
                                    name: Notification.Name("StudiquoPageActivated"),
                                    object: page
                                )
                            },
                            onBackgroundTap: {
                                NotificationCenter.default.post(
                                    name: .studiquoCanvasTapped,
                                    object: page
                                )
                            },
                            onShapeCommitted: { kind, rect in
                                addShapeElement(kind: kind, pageRect: rect, on: page)
                                pendingShapeKindRaw = ""
                                drawingToolRaw = DrawingToolKind.pen.rawValue
                            },
                            onSelectionChanged: { selection in
                                recognizeSelection(selection)
                            },
                            selectionDragText: recognizedSelectionText,
                            allowsSelectionTransfer: allowsInkSelectionTransfer,
                            onSelectionDragMoved: { image, size, point in
                                NotificationCenter.default.post(
                                    name: Notification.Name("StudiquoSelectionDragMoved"),
                                    object: image,
                                    userInfo: {
                                        guard let point, let size else { return nil }
                                        return [
                                            "point": NSValue(cgPoint: point),
                                            "size": NSValue(cgSize: size),
                                        ]
                                    }()
                                )
                            },
                            onSelectionDropped: { text, point in
                                NotificationCenter.default.post(
                                    name: .studiquoSelectionDropped,
                                    object: StudiquoSelectionDrop(text: text, screenPoint: point)
                                )
                            },
                            onSnipCaptured: { rect in
                                // The canvas knows only where the rectangle
                                // is; the page's background and elements live
                                // out here, so the crop is rendered here too.
                                guard let snippet = PageSnippetRenderer.snippet(
                                    of: page,
                                    rect: rect,
                                    label: L("\(page.order + 1)ページ"),
                                    drawing: drawing
                                ) else { return }
                                NotificationCenter.default.post(
                                    name: .studiquoPageSnipped,
                                    object: snippet
                                )
                            },
                            onEraseSwept: { path, radius in
                                eraseShapeElements(along: path, radius: radius, on: page)
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
                normalizeInkCoordinateSpace(displayWidth: displaySize.width)
            }
            .onChange(of: displaySize) { _, newSize in
                canvasDisplaySize = newSize
                normalizeInkCoordinateSpace(displayWidth: newSize.width)
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
            hasLoadedDrawing = true
            normalizeInkCoordinateSpace(displayWidth: canvasDisplaySize.width)
            convertLegacyShapesIfNeeded()
        }
        .onChange(of: page.backgroundImageData) { _, _ in updateBackgroundImageIfNeeded() }
        .onChange(of: drawing) { oldValue, newValue in
            guard hasLoadedDrawing else { return }
            if isApplyingSyncedDrawing {
                // The canvas that originated this already recorded it in the
                // shared per-page history, so recording it again here would
                // double-count the step. Nor is it re-broadcast, which would
                // bounce it back and forth.
                isApplyingSyncedDrawing = false
            } else if isApplyingHistory {
                isApplyingHistory = false
            } else if oldValue != newValue {
                DrawingHistoryStore.shared.recordChange(from: oldValue, for: page.persistentModelID)
                NotificationCenter.default.post(
                    name: .studiquoDrawingSynced,
                    object: page,
                    userInfo: ["drawing": newValue, "sender": canvasID]
                )
            }
            // An erase must never be visibly undone by anything but the Undo
            // button. Flushing it to `page.drawingData` immediately (instead
            // of the normal debounce used to batch rapid pen samples) closes
            // the window where switching tools right after erasing could
            // observe/reload the pre-erase drawing.
            let removedWholeStrokes = newValue.strokes.count < oldValue.strokes.count
            let mustSaveImmediately = drawingTool.wrappedValue == .eraser || removedWholeStrokes
            scheduleDrawingSave(newValue, delay: mustSaveImmediately ? .zero : .milliseconds(180))
        }
        .onDisappear { scheduleDrawingSave(drawing, delay: .zero) }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoUndoDrawing)) { notification in
            guard let targetPage = notification.object as? NotePage, targetPage === page,
                  let requestID = notification.userInfo?["request"] as? UUID else { return }
            undoDrawing(requestID: requestID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoRedoDrawing)) { notification in
            guard let targetPage = notification.object as? NotePage, targetPage === page,
                  let requestID = notification.userInfo?["request"] as? UUID else { return }
            redoDrawing(requestID: requestID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoDrawingSynced)) { notification in
            guard hasLoadedDrawing,
                  let targetPage = notification.object as? NotePage, targetPage === page,
                  let sender = notification.userInfo?["sender"] as? UUID, sender != canvasID,
                  let synced = notification.userInfo?["drawing"] as? InkDrawing,
                  synced != drawing else { return }
            isApplyingSyncedDrawing = true
            drawing = synced
            // Bumped so InkCanvasRepresentable actually pushes this into the
            // canvas: ink normally travels canvas → state, and only a
            // version change sends it back the other way.
            drawingVersion += 1
        }
    }

    private func recognizeSelection(_ selection: InkDrawing?) {
        let requestID = UUID()
        selectionRecognitionID = requestID
        guard let selection, !selection.isEmpty else {
            isRecognizingSelection = false
            recognizedSelectionText = ""
            NotificationCenter.default.post(name: .studiquoRecognizedSelection, object: "")
            return
        }
        isRecognizingSelection = true
        recognizedSelectionText = ""
        Task {
            let text = await HandwritingRecognitionService.recognize(drawing: selection)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard selectionRecognitionID == requestID else { return }
            recognizedSelectionText = text
            isRecognizingSelection = false
            NotificationCenter.default.post(name: .studiquoRecognizedSelection, object: text)
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

    /// Moves this page's ink into page coordinates, once.
    ///
    /// Strokes used to be written in whatever size the canvas happened to be
    /// on screen. `page.inkReferenceWidth` records the space the stored data
    /// is in; a page that predates the field carries `0`, and the width it is
    /// being shown at right now is the best available guess — exact for the
    /// common case of reopening a note at the size it was written at.
    /// Turns a dragged shape into a page element rather than ink.
    ///
    /// Drawn as strokes a shape was final the moment the pencil lifted — the
    /// only way to change it was to erase it and draw it again. As an element
    /// it gets the same blue frame a photo does, so it can be moved, resized,
    /// rotated and deleted afterwards.
    private func addShapeElement(kind: InkCanvasView.ShapeKind, pageRect: CGRect, on page: NotePage) {
        let elementKind: PageElementKind
        switch kind {
        case .rectangle: elementKind = .rectangle
        case .ellipse: elementKind = .ellipse
        }
        let pageWidth = max(page.pageWidth, 1)
        let pageHeight = max(page.pageHeight, 1)
        let element = PageElement(
            kind: elementKind,
            centerX: pageRect.midX / pageWidth,
            centerY: pageRect.midY / pageHeight,
            width: max(pageRect.width / pageWidth, 0.02),
            height: max(pageRect.height / pageHeight, 0.02),
            colorHex: drawingColorHex
        )
        element.layerIndex = (page.elements.map(\.layerIndex).max() ?? 0) + 1
        element.page = page
        page.elements.append(element)
        modelContext.insert(element)
        recordShapeAddition(element, on: page)
        try? modelContext.save()
        // Comes up already selected, so the handles are there to drag without
        // having to find and tap the shape first.
        NotificationCenter.default.post(
            name: .studiquoSelectPageElement,
            object: element.persistentModelID
        )
    }

    /// Lets the eraser rub out drawn shapes.
    ///
    /// Shapes became page elements so they could be moved and rotated after
    /// the fact, and elements are not ink — so the eraser passed straight
    /// through them. This closes that gap: a shape erases like a pen stroke
    /// even though it is stored as something else.
    ///
    /// The test is against the shape's *outline*, not its box, so sweeping
    /// through the middle of a circle leaves it alone — exactly as it would
    /// if the circle had been drawn with the pen.
    private func eraseShapeElements(along path: [CGPoint], radius: CGFloat, on page: NotePage) {
        guard !path.isEmpty else { return }
        let doomed = page.elements.filter { element in
            guard element.kind == .rectangle || element.kind == .ellipse, !element.isLocked else {
                return false
            }
            let outline = shapeOutline(for: element, on: page)
            return path.contains { point in
                outline.contains { hypot($0.x - point.x, $0.y - point.y) <= radius + 4 }
            }
        }
        guard !doomed.isEmpty else { return }
        for element in doomed {
            recordShapeRemoval(element, on: page)
            page.elements.removeAll { $0 === element }
            modelContext.delete(element)
        }
        try? modelContext.save()
    }

    /// The undo entry for a shape the eraser has just taken out.
    private func recordShapeRemoval(_ element: PageElement, on page: NotePage) {
        let slot = ElementSlot(element)
        let snapshot = PageElementSnapshot(element)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak page] in
                guard let page else { return }
                let restored = snapshot.makeElement()
                restored.page = page
                page.elements.append(restored)
                context.insert(restored)
                slot.element = restored
            },
            redo: { [weak page] in
                guard let page, let element = slot.element else { return }
                page.elements.removeAll { $0 === element }
                context.delete(element)
                slot.element = nil
            }
        )
    }

    /// The element's outline as points in page units, rotation included.
    private func shapeOutline(for element: PageElement, on page: NotePage) -> [CGPoint] {
        let center = CGPoint(x: element.centerX * page.pageWidth, y: element.centerY * page.pageHeight)
        let halfWidth = element.width * page.pageWidth / 2
        let halfHeight = element.height * page.pageHeight / 2
        let angle = CGFloat(element.rotation) * .pi / 180

        let local: [CGPoint]
        switch element.kind {
        case .ellipse:
            local = (0..<64).map { step in
                let theta = CGFloat(step) / 64 * 2 * .pi
                return CGPoint(x: cos(theta) * halfWidth, y: sin(theta) * halfHeight)
            }
        default:
            let corners = [
                CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
                CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: halfHeight),
            ]
            local = corners.indices.flatMap { index -> [CGPoint] in
                let from = corners[index], to = corners[(index + 1) % corners.count]
                return (0..<16).map { step in
                    let t = CGFloat(step) / 16
                    return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                }
            }
        }

        guard angle != 0 else {
            return local.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
        }
        let cosine = cos(angle), sine = sin(angle)
        return local.map { point in
            CGPoint(
                x: center.x + point.x * cosine - point.y * sine,
                y: center.y + point.x * sine + point.y * cosine
            )
        }
    }

    /// Puts a drawn shape on the undo stack.
    ///
    /// Shapes used to be ink, and the ink history covered them for free. Now
    /// that they are elements — so they can be moved and rotated afterwards —
    /// they need recording explicitly, or the undo button would ignore the
    /// last thing the student did.
    private func recordShapeAddition(_ element: PageElement, on page: NotePage) {
        let slot = ElementSlot(element)
        let snapshot = PageElementSnapshot(element)
        let context = modelContext
        NoteActionHistory.shared.record(
            undo: { [weak page] in
                guard let page, let element = slot.element else { return }
                page.elements.removeAll { $0 === element }
                context.delete(element)
                slot.element = nil
            },
            redo: { [weak page] in
                guard let page else { return }
                let restored = snapshot.makeElement()
                restored.page = page
                page.elements.append(restored)
                context.insert(restored)
                slot.element = restored
            }
        )
    }

    private func normalizeInkCoordinateSpace(displayWidth: CGFloat) {
        guard hasLoadedDrawing, displayWidth > 1, page.pageWidth > 1 else { return }
        let target = page.pageWidth
        let source = page.inkReferenceWidth > 1 ? page.inkReferenceWidth : Double(displayWidth)
        guard abs(source - target) > 0.5 else {
            if page.inkReferenceWidth != target { page.inkReferenceWidth = target }
            return
        }
        page.inkReferenceWidth = target
        guard !drawing.isEmpty else { return }
        isApplyingHistory = true
        drawing = drawing.scaled(by: CGFloat(target / source))
        drawingVersion += 1
        scheduleDrawingSave(drawing, delay: .zero)
    }

    private func undoDrawing(requestID: UUID) {
        guard let previous = DrawingHistoryStore.shared.popUndo(
            requestID: requestID,
            page: page.persistentModelID,
            current: drawing
        ) else { return }
        applyHistory(previous)
    }

    private func redoDrawing(requestID: UUID) {
        guard let next = DrawingHistoryStore.shared.popRedo(
            requestID: requestID,
            page: page.persistentModelID,
            current: drawing
        ) else { return }
        applyHistory(next)
    }

    /// Swaps in a state from the history and tells any other canvas on this
    /// page to follow. The other canvas is deliberately shut out of the pop
    /// itself (see `DrawingHistoryStore.claim`), so this broadcast is how it
    /// stays in step.
    private func applyHistory(_ value: InkDrawing) {
        isApplyingHistory = true
        drawing = value
        drawingVersion += 1
        NotificationCenter.default.post(
            name: .studiquoDrawingSynced,
            object: page,
            userInfo: ["drawing": value, "sender": canvasID]
        )
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

    /// At most one element carries the resize/rotate chrome at a time, so
    /// the state lives here rather than in each element.
    @State private var selectedElementID: PersistentIdentifier?

    /// The rotation handle needs the touch point in page coordinates to work
    /// out an angle from the element's centre; a named space is the only way
    /// to read it from inside a view the page has already rotated.
    static let coordinateSpace = "studiquoPageElements"

    var body: some View {
        GeometryReader { geometry in
            ForEach(page.elements) { element in
                EditablePageElement(
                    element: element,
                    pageSize: geometry.size,
                    isDark: isDark,
                    selectedElementID: $selectedElementID
                )
                // A selected element floats above the rest so its handles
                // are never buried under a neighbour that happens to sit on
                // a higher layer.
                .zIndex(selectedElementID == element.persistentModelID ? 1_000_000 : element.layerIndex)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onReceive(NotificationCenter.default.publisher(for: .studiquoSelectPageElement)) { note in
            guard let id = note.object as? PersistentIdentifier,
                  page.elements.contains(where: { $0.persistentModelID == id }) else { return }
            selectedElementID = id
        }
    }
}

/// Which edge or corner a resize handle is pinned to, as unit offsets from
/// the element's centre.
private enum ResizeAnchor: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: String { rawValue }

    var unitX: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    var unitY: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .left, .right: 0
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }
}

/// An element's position and size at the moment a handle drag began, so each
/// drag update is computed from the starting frame rather than accumulating
/// rounding error across the drag.
private struct ElementFrame {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
}

private struct EditablePageElement: View {
    @Bindable var element: PageElement
    @Environment(\.modelContext) private var modelContext
    let pageSize: CGSize
    let isDark: Bool

    @Binding var selectedElementID: PersistentIdentifier?

    @State private var dragOrigin: CGPoint?
    @State private var sizeOrigin: CGSize?
    @State private var isEditingText = false
    @State private var editedText = ""
    @State private var rotationOrigin: Double?
    @State private var isStudyTapeRevealed = false
    @State private var handleOrigin: ElementFrame?

    private var elementSize: CGSize {
        CGSize(
            width: max(44, pageSize.width * element.width),
            height: max(28, pageSize.height * element.height)
        )
    }

    private var isSelected: Bool {
        selectedElementID == element.persistentModelID
    }

    /// Study tape and page links answer a tap with their own behaviour
    /// (reveal, navigate), so they keep it rather than trading it for a
    /// selection box.
    private var supportsSelection: Bool {
        element.kind != .studyTape && element.kind != .pageLink
    }

    var body: some View {
        elementContent
            .frame(width: elementSize.width, height: elementSize.height)
            .contentShape(Rectangle())
            .overlay { if isSelected { selectionChrome } }
            .rotationEffect(.degrees(element.rotation))
            .position(x: pageSize.width * element.centerX, y: pageSize.height * element.centerY)
            .onTapGesture {
                guard supportsSelection else { return }
                selectedElementID = isSelected ? nil : element.persistentModelID
            }
            // Tapping the page anywhere outside the box puts the element down
            // and clears the handles, so a photo can be "committed" in place
            // without hunting for the exact element again. The canvas raises
            // this for both a finger and a pencil tap.
            .onReceive(NotificationCenter.default.publisher(for: .studiquoCanvasTapped)) { notification in
                guard isSelected,
                      let page = notification.object as? NotePage,
                      page === element.page else { return }
                selectedElementID = nil
            }
            .gesture(isSelected ? moveGesture : nil)
            .simultaneousGesture(isSelected ? resizeGesture : nil)
            .simultaneousGesture(isSelected ? rotationGesture : nil)
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
                Button("保存") {
                    element.text = editedText
                    markUpdated()
                }
            }
    }

    @ViewBuilder
    private var elementContent: some View {
        let color = Color(hex: element.colorHex)
        switch element.kind {
        case .text:
            let textSize = min(20, max(12, elementSize.height * 0.16))
            Text(element.text.isEmpty ? "テキスト" : element.text)
                .font(.system(size: textSize))
                .foregroundStyle(element.text.isEmpty ? Color.secondary : (isDark && element.colorHex == "#1C1C1E" ? .white : color))
                .multilineTextAlignment(.leading)
                .padding(10)
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

    /// The Word-style selection box: a blue outline, eight resize handles
    /// and a rotation grip above the top edge. It lives inside the element's
    /// `rotationEffect`, so the whole box turns with the photo and each
    /// handle stays attached to the edge it resizes.
    private var selectionChrome: some View {
        let handleDiameter: CGFloat = 13
        // An overlay only hit-tests within its own bounds. Sized tightly to
        // the element, the rotation grip above the top edge — and the outer
        // half of every handle straddling the border — drew fine but could
        // not be touched at all. The chrome is therefore given room around
        // the element, with the outline pinned back to the element's size.
        let margin: CGFloat = 60

        return ZStack {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: elementSize.width, height: elementSize.height)

            ForEach(ResizeAnchor.allCases) { anchor in
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: handleDiameter, height: handleDiameter)
                    // Enlarged past the dot that's drawn so the handles stay
                    // grabbable with a fingertip, but not so far that the
                    // top-centre one swallows touches meant for the rotation
                    // grip above it.
                    .contentShape(Circle().inset(by: -6))
                    .offset(
                        x: anchor.unitX * elementSize.width / 2,
                        y: anchor.unitY * elementSize.height / 2
                    )
                    .highPriorityGesture(resizeHandleGesture(anchor))
            }

            // Drawn last, and held well clear of the top-centre resize
            // handle: at a shorter stem the two hit areas overlapped, and
            // the resize handle took every touch aimed at the grip.
            VStack(spacing: 0) {
                Image(systemName: "arrow.trianglehead.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    // Sized for a fingertip. At the old 20pt it was a pencil
                    // target, and a finger kept missing it — Apple's own
                    // minimum for a touch target is 44pt, which the enlarged
                    // hit shape below reaches.
                    .contentShape(Circle().inset(by: -6))
                    // High priority so the grip beats both the element's own
                    // move gesture and the long press that opens its context
                    // menu — otherwise a slow, deliberate drag on a handle
                    // dragged the whole element or popped the menu instead.
                    .highPriorityGesture(rotationHandleGesture)
                    .accessibilityLabel("回転")
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 20)
            }
            .offset(y: -elementSize.height / 2 - 27)

            // Delete, parked just off the top-right corner where it cannot be
            // confused with a resize handle.
            Button(role: .destructive) {
                deleteElement()
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
            .offset(
                x: elementSize.width / 2 + 26,
                y: -elementSize.height / 2 - 20
            )
            .accessibilityLabel("この要素を削除")
        }
        .frame(
            width: elementSize.width + margin * 2,
            height: elementSize.height + margin * 2
        )
        .allowsHitTesting(!element.isLocked)
    }

    private func resizeHandleGesture(_ anchor: ResizeAnchor) -> some Gesture {
        // `minimumDistance: 0` claims the touch the instant it lands, which
        // is what stops the element's context-menu long press from winning a
        // slow, deliberate drag on a handle — that press would otherwise pop
        // the menu and hand the movement to the element's own drag gesture,
        // so the box moved instead of resizing.
        //
        // Measured in the global space rather than the element's own: the
        // element is inside a `rotationEffect`, and a raw screen delta is
        // the one reading that stays predictable when it's turned. The
        // rotation is undone explicitly below.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !element.isLocked else { return }
                if handleOrigin == nil {
                    handleOrigin = ElementFrame(
                        centerX: element.centerX,
                        centerY: element.centerY,
                        width: element.width,
                        height: element.height
                    )
                }
                guard let origin = handleOrigin else { return }
                applyResize(anchor: anchor, from: origin, translation: value.translation)
            }
            .onEnded { _ in
                handleOrigin = nil
                markUpdated()
            }
    }

    private func applyResize(anchor: ResizeAnchor, from origin: ElementFrame, translation: CGSize) {
        let pageWidth = max(pageSize.width, 1)
        let pageHeight = max(pageSize.height, 1)
        let radians = element.rotation * .pi / 180

        // Screen-space drag rotated back into the element's own axes, so a
        // handle on a tilted photo still grows the edge it is attached to
        // instead of the one that happens to face that way on screen.
        let localDX = translation.width * cos(radians) + translation.height * sin(radians)
        let localDY = -translation.width * sin(radians) + translation.height * cos(radians)

        let originWidth = origin.width * pageWidth
        let originHeight = origin.height * pageHeight

        var newWidth = originWidth
        var newHeight = originHeight
        if anchor.unitX != 0 {
            newWidth = min(max(originWidth + anchor.unitX * localDX, 32), pageWidth)
        }
        if anchor.unitY != 0 {
            newHeight = min(max(originHeight + anchor.unitY * localDY, 24), pageHeight)
        }

        // The opposite edge stays pinned: the centre moves by half of
        // whatever the dragged side gained, along the element's own axes.
        let shiftX = anchor.unitX * (newWidth - originWidth) / 2
        let shiftY = anchor.unitY * (newHeight - originHeight) / 2
        let pageShiftX = shiftX * cos(radians) - shiftY * sin(radians)
        let pageShiftY = shiftX * sin(radians) + shiftY * cos(radians)

        element.width = newWidth / pageWidth
        element.height = newHeight / pageHeight
        element.centerX = min(max(origin.centerX + pageShiftX / pageWidth, 0.02), 0.98)
        element.centerY = min(max(origin.centerY + pageShiftY / pageHeight, 0.02), 0.98)
        markUpdated()
    }

    /// Follows the finger around the element's centre. The grip sits above
    /// the box, so pointing straight up has to read as zero degrees — hence
    /// the quarter-turn added to `atan2`'s result.
    private var rotationHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PageElementsLayer.coordinateSpace))
            .onChanged { value in
                guard !element.isLocked else { return }
                let center = CGPoint(
                    x: pageSize.width * element.centerX,
                    y: pageSize.height * element.centerY
                )
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                element.rotation = angle * 180 / .pi + 90
                markUpdated()
            }
            .onEnded { _ in markUpdated() }
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
        if isSelected { selectedElementID = nil }
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

struct PageTemplateBackground: View {
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
