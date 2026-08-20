import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var allNotebooks: [Notebook]
    @Query(sort: \FlashcardDeck.updatedAt, order: .reverse) private var flashcardDecks: [FlashcardDeck]
    @AppStorage("libraryFolderNames") private var folderNamesStorage = ""
    @AppStorage("libraryFolderCreatedAt") private var folderCreatedAtStorage = "{}"
    @AppStorage("favoriteFolderPaths") private var favoriteFolderPathsStorage = ""
    @AppStorage("notebookLibraryMetadataVersion") private var notebookLibraryMetadataVersion = 0

    @State private var selectedNotebook: Notebook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var libraryMode: LibraryMode = .documents
    @State private var selectedFolder: String?
    @State private var sortOption: NotebookSortOption = .updatedNewest
    @State private var searchText = ""
    @State private var isImportingPDF = false
    @State private var isImportingBackup = false
    @State private var backupURL: IdentifiableURL?
    @State private var isShowingScanner = false
    @State private var openNotebooks: [Notebook] = []
    @State private var openStudyNotebooks: [Notebook] = []
    @State private var openFlashcardDecks: [FlashcardDeck] = []
    @State private var openWebTabs: [WebTabInfo] = []
    @StateObject private var editorSplitState = EditorSplitState()
    @State private var showsAutomaticBackups = false
    @State private var newNotebookName = ""
    @State private var isShowingNewNotebookAlert = false
    @State private var notebookToRename: Notebook?
    @State private var renameText = ""
    @State private var showsEmptyTrashConfirmation = false
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var notebookToEditTags: Notebook?
    @State private var tagsText = ""
    @State private var expandedSidebarFolders: Set<String> = []
    @State private var studyNotebook: Notebook?
    @State private var activeFlashcardDeck: FlashcardDeck?
    @State private var isShowingNewFlashcardDeckAlert = false
    @State private var newFlashcardDeckName = ""

    private var folderNames: [String] {
        folderNamesStorage.split(separator: "\n").map(String.init)
    }

    private var folderCreatedAt: [String: TimeInterval] {
        guard let data = folderCreatedAtStorage.data(using: .utf8),
              let dates = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return dates
    }

    private var favoriteFolderPaths: Set<String> {
        Set(favoriteFolderPathsStorage.split(separator: "\n").map(String.init))
    }

    private var sortedFolderNames: [String] {
        folderNames.sorted { first, second in
            switch sortOption {
            case .createdNewest:
                return (folderCreatedAt[first] ?? 0) > (folderCreatedAt[second] ?? 0)
            case .createdOldest:
                return (folderCreatedAt[first] ?? 0) < (folderCreatedAt[second] ?? 0)
            case .nameDescending:
                return first.localizedStandardCompare(second) == .orderedDescending
            default:
                return first.localizedStandardCompare(second) == .orderedAscending
            }
        }
    }

    private var visibleFolderPaths: [String] {
        sortedFolderNames.filter { parentFolder(of: $0) == selectedFolder }
    }

    private func parentFolder(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private func folderDisplayName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var isHomeScreen: Bool {
        libraryMode == .documents && selectedFolder == nil
    }

    private var homeNotebooks: [Notebook] {
        allNotebooks
            .filter { !$0.isTrashed && $0.folderName.isEmpty }
            .filter { notebook in
                searchText.isEmpty
                    || notebook.title.localizedCaseInsensitiveContains(searchText)
                    || notebook.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted(by: sortOption.comparator)
    }

    private var visibleNotebooks: [Notebook] {
        let filtered = allNotebooks.filter { notebook in
            let belongsToMode: Bool
            if let selectedFolder {
                belongsToMode = !notebook.isTrashed && notebook.folderName == selectedFolder
            } else {
                switch libraryMode {
                case .documents: belongsToMode = !notebook.isTrashed
                case .favorites: belongsToMode = !notebook.isTrashed && notebook.isFavorite
                case .pdfs: belongsToMode = !notebook.isTrashed && notebook.containsPDF
                case .studyCards: belongsToMode = false
                case .trash: belongsToMode = notebook.isTrashed
                }
            }
            let matchesSearch = searchText.isEmpty
                || notebook.title.localizedCaseInsensitiveContains(searchText)
                || notebook.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return belongsToMode && matchesSearch
        }
        return filtered.sorted(by: sortOption.comparator)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                if selectedNotebook != nil {
                    Section {
                        Button {
                            returnToHome()
                        } label: {
                            Label("ホーム", systemImage: "house.fill")
                        }
                        .buttonStyle(.plain)
                    }

                    Section("フォルダ") {
                        if sortedFolderNames.isEmpty {
                            Text("フォルダはまだありません")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sortedFolderNames, id: \.self) { folder in
                                DisclosureGroup(
                                    isExpanded: sidebarFolderBinding(folder),
                                    content: {
                                        let folderNotebooks = notebooksInFolder(folder)
                                        if folderNotebooks.isEmpty {
                                            Text("このフォルダは空です")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            ForEach(folderNotebooks) { notebook in
                                                sidebarNotebookButton(notebook)
                                            }
                                        }
                                    },
                                    label: {
                                        Label(folder, systemImage: "folder.fill")
                                    }
                                )
                            }
                        }
                    }

                    Section("ノート") {
                        if homeNotebooks.isEmpty {
                            Text("フォルダ外のノートはありません")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(homeNotebooks) { notebook in
                                sidebarNotebookButton(notebook)
                            }
                        }
                    }
                } else {
                    Section("ライブラリ") {
                        ForEach(LibraryMode.allCases) { mode in
                            Button {
                                libraryMode = mode
                                selectedFolder = nil
                            } label: {
                                HStack {
                                    Label(mode.title, systemImage: mode.icon)
                                    Spacer()
                                    if libraryMode == mode {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section {
                        ForEach(visibleFolderPaths, id: \.self) { folder in
                            Button {
                                selectedFolder = folder
                                libraryMode = .documents
                            } label: {
                                HStack {
                                    Label(folderDisplayName(folder), systemImage: "folder")
                                    Spacer()
                                    if selectedFolder == folder {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("フォルダ")
                            Spacer()
                            Button { isShowingNewFolderAlert = true } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("ノート")
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.86, green: 0.93, blue: 1.0))
        } detail: {
            if let selectedNotebook, !selectedNotebook.isTrashed {
                VStack(spacing: 0) {
                    notebookTabBar
                    Divider()
                    ProtectedNotebookView(
                        notebook: selectedNotebook,
                        columnVisibility: $columnVisibility,
                        onHome: returnToHome
                    )
                        .id(selectedNotebook.persistentModelID)
                        .environmentObject(editorSplitState)
                }
            } else {
                fullScreenHome
            }
        }
        .alert("新規ノート", isPresented: $isShowingNewNotebookAlert) {
            TextField("ノート名", text: $newNotebookName)
            Button("キャンセル", role: .cancel) { newNotebookName = "" }
            Button("作成") { createBlankNotebook() }
        }
        .alert("新規フォルダ", isPresented: $isShowingNewFolderAlert) {
            TextField("フォルダ名", text: $newFolderName)
            Button("キャンセル", role: .cancel) { newFolderName = "" }
            Button("作成") { createFolder() }
        }
        .alert("新規暗記帳", isPresented: $isShowingNewFlashcardDeckAlert) {
            TextField("暗記帳の名前", text: $newFlashcardDeckName)
            Button("キャンセル", role: .cancel) { newFlashcardDeckName = "" }
            Button("作成") { createFlashcardDeck() }
        } message: {
            Text("作成後、1枚目の問題と答えを入力します。")
        }
        .alert("名前を変更", isPresented: Binding(
            get: { notebookToRename != nil },
            set: { if !$0 { notebookToRename = nil } }
        )) {
            TextField("ノート名", text: $renameText)
            Button("キャンセル", role: .cancel) { notebookToRename = nil }
            Button("変更") { renameNotebook() }
        }
        .alert("タグを編集", isPresented: Binding(
            get: { notebookToEditTags != nil },
            set: { if !$0 { notebookToEditTags = nil } }
        )) {
            TextField("例：数学, 授業, 重要", text: $tagsText)
            Button("キャンセル", role: .cancel) { notebookToEditTags = nil }
            Button("保存") { saveTags() }
        } message: {
            Text("複数のタグはカンマで区切ってください。")
        }
        .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach(importPDF)
            }
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let notebook = NotebookBackupService.restore(from: url) {
                        modelContext.insert(notebook)
                        selectedNotebook = notebook
                    }
                }
            }
        }
        .sheet(item: $backupURL) { wrapped in
            ShareSheet(items: [wrapped.url])
        }
        .sheet(isPresented: $showsAutomaticBackups) {
            AutomaticBackupRestoreView { url in
                if let notebook = NotebookBackupService.restore(from: url) {
                    modelContext.insert(notebook)
                    selectedNotebook = notebook
                }
            }
        }
        .sheet(item: $studyNotebook) { notebook in
            StudySessionView(notebook: notebook)
        }
        .sheet(item: $activeFlashcardDeck) { deck in
            FlashcardDeckView(deck: deck)
        }
        .fullScreenCover(isPresented: $isShowingScanner) {
            DocumentScannerView(onComplete: createScannedNotebook)
                .ignoresSafeArea()
        }
        .onChange(of: libraryMode) { _, _ in
            if selectedFolder == nil { selectedNotebook = nil }
            searchText = ""
        }
        .onChange(of: selectedNotebook) { _, notebook in
            guard let notebook, !notebook.isTrashed else {
                columnVisibility = .detailOnly
                return
            }
            if !openNotebooks.contains(where: { $0 === notebook }) {
                openNotebooks.append(notebook)
                if openNotebooks.count > 6 { openNotebooks.removeFirst() }
            }
            columnVisibility = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GoodNotesFreeOpenNotebookTab"))) { notification in
            if let deck = notification.object as? FlashcardDeck {
                if !openFlashcardDecks.contains(where: { $0 === deck }) { openFlashcardDecks.append(deck) }
            } else if let notebook = notification.object as? Notebook,
                      !openNotebooks.contains(where: { $0 === notebook }) {
                openNotebooks.append(notebook)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GoodNotesFreeOpenWebTab"))) { notification in
            guard let tab = notification.object as? WebTabInfo else { return }
            if let index = openWebTabs.firstIndex(where: { $0.id == tab.id }) {
                openWebTabs[index] = tab
            } else {
                openWebTabs.append(tab)
            }
        }
        .onAppear {
            if selectedNotebook == nil { columnVisibility = .detailOnly }
        }
        .task {
            await rebuildLibraryMetadataIfNeeded()
        }
    }

    private var notebookTabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(openNotebooks) { notebook in
                    HStack(spacing: 5) {
                        Button {
                            selectNotebookTab(notebook)
                        } label: {
                            Label(notebook.title, systemImage: notebook.isLocked ? "lock.fill" : "note.text")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            closeTab(notebook)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(selectedNotebook === notebook ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .draggable("notebook:\(notebookID(notebook))")
                }
                ForEach(openStudyNotebooks) { notebook in
                    HStack(spacing: 5) {
                        Button {
                            studyNotebook = notebook
                        } label: {
                            Label("\(notebook.title)・暗記カード", systemImage: "rectangle.on.rectangle.angled")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            openStudyNotebooks.removeAll { $0 === notebook }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("flashcards:\(notebookID(notebook))")
                }
                ForEach(openFlashcardDecks) { deck in
                    HStack(spacing: 5) {
                        Button { selectFlashcardTab(deck) } label: {
                            Label(deck.title, systemImage: "rectangle.on.rectangle.angled").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button { openFlashcardDecks.removeAll { $0 === deck } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("deck:\(deckID(deck))")
                }
                ForEach(openWebTabs) { tab in
                    HStack(spacing: 5) {
                        Button { selectWebTab(tab) } label: {
                            Label(tab.title, systemImage: "globe").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button { openWebTabs.removeAll { $0.id == tab.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("web:\(tab.title)|\(tab.homeURL)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    /// While an editor is already open, every tab tap routes into whichever
    /// split pane the user didn't last touch instead of tearing the editor
    /// down and rebuilding it (which `selectedNotebook`'s `.id()` would do,
    /// discarding any active split). Only the very first tab tap — opening
    /// an editor from the home screen — still goes through `selectedNotebook`.
    private func selectNotebookTab(_ notebook: Notebook) {
        // With no split on screen there is only one pane, so just swap the
        // selected notebook — that rebuilds the editor and is the reliable
        // path. Routing through the pane-switch notification is reserved for
        // split mode, where rebuilding would discard the other pane.
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            selectedNotebook = notebook
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("GoodNotesFreeSwitchPaneTarget"),
            object: PaneSwitchTarget.notebook(notebook)
        )
    }

    private func selectFlashcardTab(_ deck: FlashcardDeck) {
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            activeFlashcardDeck = deck
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("GoodNotesFreeSwitchPaneTarget"),
            object: PaneSwitchTarget.flashcardDeck(deck)
        )
    }

    private func selectWebTab(_ tab: WebTabInfo) {
        guard selectedNotebook != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("GoodNotesFreeSwitchPaneTarget"),
            object: PaneSwitchTarget.web(title: tab.title, homeURL: tab.homeURL)
        )
    }

    private func closeTab(_ notebook: Notebook) {
        guard let index = openNotebooks.firstIndex(where: { $0 === notebook }) else { return }
        let wasSelected = selectedNotebook === notebook
        openNotebooks.remove(at: index)
        if wasSelected {
            selectedNotebook = openNotebooks.indices.contains(index) ? openNotebooks[index] : openNotebooks.last
        }
    }

    private func returnToHome() {
        selectedNotebook = nil
        selectedFolder = nil
        libraryMode = .documents
        searchText = ""
        columnVisibility = .detailOnly
    }

    private func notebookID(_ notebook: Notebook) -> String {
        String(describing: notebook.persistentModelID)
    }

    private func deckID(_ deck: FlashcardDeck) -> String {
        String(describing: deck.persistentModelID)
    }

    private func handleTabDrop(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if parts[0] == "deck", let deck = flashcardDecks.first(where: { deckID($0) == parts[1] }) {
            activeFlashcardDeck = deck
            return true
        }
        guard let notebook = allNotebooks.first(where: { notebookID($0) == parts[1] && !$0.isTrashed }) else { return false }
        if parts[0] == "flashcards" {
            studyNotebook = notebook
        } else {
            selectedNotebook = notebook
        }
        return true
    }

    private func notebooksInFolder(_ folder: String) -> [Notebook] {
        allNotebooks
            .filter { !$0.isTrashed && $0.folderName == folder }
            .sorted(by: sortOption.comparator)
    }

    private func sidebarFolderBinding(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { expandedSidebarFolders.contains(folder) },
            set: { isExpanded in
                if isExpanded { expandedSidebarFolders.insert(folder) }
                else { expandedSidebarFolders.remove(folder) }
            }
        )
    }

    private func sidebarNotebookButton(_ notebook: Notebook) -> some View {
        Button {
            selectedNotebook = notebook
            columnVisibility = .detailOnly
        } label: {
            HStack(spacing: 8) {
                Image(systemName: notebook.containsPDF ? "doc.richtext" : "note.text")
                    .foregroundStyle(notebook.containsPDF ? .red : .blue)
                Text(notebook.title)
                    .lineLimit(1)
                Spacer()
                if selectedNotebook === notebook {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fullScreenHome: some View {
        let notebookCounts = Dictionary(
            grouping: allNotebooks.filter { !$0.isTrashed },
            by: \.folderName
        ).mapValues(\.count)
        let deckCounts = Dictionary(grouping: flashcardDecks, by: \.folderName).mapValues(\.count)

        return List(selection: $selectedNotebook) {
            if libraryMode == .documents {
                Section("フォルダ") {
                    if visibleFolderPaths.isEmpty {
                        Text("フォルダはまだありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleFolderPaths, id: \.self) { folder in
                            HStack(spacing: 10) {
                                Button {
                                    selectedFolder = folder
                                } label: {
                                    HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folderDisplayName(folder)).font(.headline)
                                        Text("\(notebookCounts[folder, default: 0])冊のノート・\(deckCounts[folder, default: 0])個の暗記帳")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { toggleFolderFavorite(folder) } label: {
                                    Image(systemName: favoriteFolderPaths.contains(folder) ? "star.fill" : "star")
                                        .foregroundStyle(favoriteFolderPaths.contains(folder) ? .yellow : .secondary)
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section(selectedFolder == nil ? "フォルダ外のノート" : "このフォルダのノート") {
                    let displayedNotebooks = selectedFolder == nil ? homeNotebooks : visibleNotebooks
                    if displayedNotebooks.isEmpty {
                        Text(selectedFolder == nil ? "フォルダ外のノートはありません" : "このフォルダにノートはありません")
                            .foregroundStyle(.secondary)
                    } else {
                        notebookRows(displayedNotebooks)
                    }
                }
                studyCardRows
            } else if libraryMode == .studyCards && selectedFolder == nil {
                studyCardRows
            } else if libraryMode == .favorites && selectedFolder == nil {
                favoriteRows
            } else {
                notebookRows(visibleNotebooks)
            }
        }
        .navigationTitle(selectedFolder.map(folderDisplayName) ?? (isHomeScreen ? "ホーム" : libraryMode.title))
        .searchable(text: $searchText, prompt: "ノートを検索")
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.98, green: 0.95, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack {
                    if selectedFolder != nil {
                        Button {
                            goBackOneFolder()
                        } label: {
                            Label("一つ前のフォルダへ戻る", systemImage: "chevron.left")
                        }
                        Button {
                            selectedFolder = nil
                            libraryMode = .documents
                        } label: {
                            Label("ホームへ戻る", systemImage: "house.fill")
                        }
                    }
                    Menu {
                        Picker("並べ替え", selection: $sortOption) {
                            ForEach(NotebookSortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("並べ替え", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if libraryMode == .studyCards && selectedFolder == nil {
                    Button {
                        isShowingNewFlashcardDeckAlert = true
                    } label: {
                        Label("新規暗記カードを作成", systemImage: "plus")
                    }
                } else if libraryMode == .trash && selectedFolder == nil {
                    Button("空にする", role: .destructive) {
                        showsEmptyTrashConfirmation = true
                    }
                    .disabled(visibleNotebooks.isEmpty)
                } else {
                    createMenu
                }
            }
        }
        .confirmationDialog("ゴミ箱を空にしますか？", isPresented: $showsEmptyTrashConfirmation, titleVisibility: .visible) {
            Button("完全に削除", role: .destructive) { emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
        .overlay {
            if libraryMode == .studyCards && selectedFolder == nil && flashcardDecks.isEmpty {
                ContentUnavailableView(
                    "暗記カードがありません",
                    systemImage: "rectangle.on.rectangle.angled",
                    description: Text("右上の＋から新しい暗記帳を作成してください")
                )
            } else if !isHomeScreen
                        && visibleNotebooks.isEmpty
                        && displayedFlashcardDecks.isEmpty
                        && !(libraryMode == .favorites && hasFavoriteNonNotebookItems) {
                ContentUnavailableView(
                    searchText.isEmpty ? (selectedFolder == nil ? libraryMode.emptyTitle : "このフォルダは空です") : "見つかりません",
                    systemImage: searchText.isEmpty ? (selectedFolder == nil ? libraryMode.icon : "folder") : "magnifyingglass",
                    description: Text(searchText.isEmpty ? (selectedFolder == nil ? libraryMode.emptyMessage : "このフォルダにはまだノートや暗記帳がありません。") : "別の言葉で検索してください")
                )
            }
        }
    }

    private var studyCardCount: Int {
        flashcardDecks.reduce(0) { $0 + $1.cards.count }
    }

    private var displayedFlashcardDecks: [FlashcardDeck] {
        if libraryMode == .documents {
            return flashcardDecks.filter { $0.folderName == (selectedFolder ?? "") }
        }
        return flashcardDecks
    }

    @ViewBuilder
    private var studyCardRows: some View {
        Section(libraryMode == .documents ? (selectedFolder == nil ? "フォルダ外の暗記帳" : "このフォルダの暗記帳") : "暗記帳") {
            if displayedFlashcardDecks.isEmpty {
                Text(libraryMode == .documents && selectedFolder == nil ? "フォルダ外の暗記帳はありません" : "暗記帳はありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(displayedFlashcardDecks) { deck in
                HStack(spacing: 10) {
                    Button { activeFlashcardDeck = deck } label: {
                        HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deck.title).font(.headline).lineLimit(1)
                            Text("\(deck.cards.count)枚 ・ \(deck.orderMode.title)\(deck.reversesQuestionAndAnswer ? " ・ 逆向き" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { deck.isFavorite.toggle(); deck.updatedAt = .now } label: {
                        Image(systemName: deck.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(deck.isFavorite ? .yellow : .secondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }
                .swipeActions {
                    Button("削除", role: .destructive) { modelContext.delete(deck) }
                }
            }
        }
    }

    private var hasFavoriteNonNotebookItems: Bool {
        !favoriteFolderPaths.isEmpty || flashcardDecks.contains(where: \.isFavorite)
    }

    @ViewBuilder
    private var favoriteRows: some View {
        let folders = sortedFolderNames.filter { favoriteFolderPaths.contains($0) }
        if !folders.isEmpty {
            Section("フォルダ") {
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Button {
                            selectedFolder = folder
                            libraryMode = .documents
                        } label: {
                            Label(folderDisplayName(folder), systemImage: "folder.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { toggleFolderFavorite(folder) } label: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !visibleNotebooks.isEmpty {
            Section("ノート・PDF") { notebookRows(visibleNotebooks) }
        }
        let decks = flashcardDecks.filter(\.isFavorite)
        if !decks.isEmpty {
            Section("暗記帳") {
                ForEach(decks) { deck in
                    HStack {
                        Button { activeFlashcardDeck = deck } label: {
                            Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { deck.isFavorite = false } label: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleFolderFavorite(_ folder: String) {
        var favorites = favoriteFolderPaths
        if favorites.contains(folder) { favorites.remove(folder) }
        else { favorites.insert(folder) }
        favoriteFolderPathsStorage = favorites.sorted().joined(separator: "\n")
    }

    private func createFlashcardDeck() {
        let title = newFlashcardDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = FlashcardDeck(title: title.isEmpty ? "新しい暗記帳" : title)
        deck.folderName = selectedFolder ?? ""
        modelContext.insert(deck)
        newFlashcardDeckName = ""
        activeFlashcardDeck = deck
    }

    private var createMenu: some View {
        Menu {
            Button {
                isShowingNewNotebookAlert = true
            } label: {
                Label("新規ノート", systemImage: "square.and.pencil")
            }
            Button {
                isShowingNewFolderAlert = true
            } label: {
                Label("新規フォルダ", systemImage: "folder.badge.plus")
            }
            Button {
                isShowingNewFlashcardDeckAlert = true
            } label: {
                Label("新規暗記カードを作成", systemImage: "rectangle.on.rectangle.angled")
            }
            Button {
                isImportingPDF = true
            } label: {
                Label("PDFを読み込む", systemImage: "doc.badge.plus")
            }
            Button {
                isImportingBackup = true
            } label: {
                Label("バックアップを復元", systemImage: "externaldrive.badge.plus")
            }
            Button {
                showsAutomaticBackups = true
            } label: {
                Label("自動バックアップを復元", systemImage: "clock.arrow.circlepath")
            }
            Button {
                isShowingScanner = true
            } label: {
                Label("書類をスキャン", systemImage: "doc.viewfinder")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    @ViewBuilder
    private func notebookActions(_ notebook: Notebook) -> some View {
        if notebook.isTrashed {
            Button { restore(notebook) } label: { Label("復元", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { permanentlyDelete(notebook) } label: { Label("完全に削除", systemImage: "trash") }
        } else {
            Button { notebook.isFavorite.toggle() } label: {
                Label(notebook.isFavorite ? "お気に入りを解除" : "お気に入り", systemImage: notebook.isFavorite ? "star.slash" : "star")
            }
            Button { beginRename(notebook) } label: { Label("名前を変更", systemImage: "pencil") }
            Button { beginTagEditing(notebook) } label: { Label("タグを編集", systemImage: "tag") }
            Button {
                notebook.isLocked.toggle()
                notebook.updatedAt = .now
            } label: {
                Label(notebook.isLocked ? "保護を解除" : "ノートを保護", systemImage: notebook.isLocked ? "lock.open" : "lock")
            }
            Button {
                backupURL = NotebookBackupService.export(notebook).map(IdentifiableURL.init(url:))
            } label: { Label("バックアップを書き出す", systemImage: "externaldrive") }
            Menu {
                Button { notebook.folderName = "" } label: { Label("フォルダから外す", systemImage: "tray") }
                ForEach(sortedFolderNames, id: \.self) { folder in
                    Button { notebook.folderName = folder } label: {
                        if notebook.folderName == folder { Label(folder, systemImage: "checkmark") }
                        else { Text(folder) }
                    }
                }
            } label: { Label("フォルダへ移動", systemImage: "folder") }
            Button { duplicate(notebook) } label: { Label("複製", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { moveToTrash(notebook) } label: { Label("ゴミ箱に移動", systemImage: "trash") }
        }
    }

    private func createBlankNotebook() {
        let title = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: title.isEmpty ? "無題のノート" : title)
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.pages.append(page)
        notebook.refreshLibraryMetadata()
        notebook.folderName = selectedFolder ?? ""
        modelContext.insert(notebook)
        newNotebookName = ""
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func importPDF(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        let notebook = Notebook(title: url.deletingPathExtension().lastPathComponent)
        notebook.folderName = selectedFolder ?? ""
        for (index, pageData) in PDFImportService.extractPages(from: url).enumerated() {
            let page = NotePage(order: index, backgroundImageData: pageData.imageData, pageWidth: pageData.width, pageHeight: pageData.height)
            page.recognizedText = pageData.text
            page.textRecognitionDate = .now
            page.notebook = notebook
            notebook.pages.append(page)
        }
        guard !notebook.pages.isEmpty else { return }
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func createScannedNotebook(from images: [UIImage]) {
        guard !images.isEmpty else { return }
        let notebook = Notebook(title: "スキャン \(Date.now.formatted(date: .numeric, time: .shortened))")
        notebook.folderName = selectedFolder ?? ""
        for (index, image) in images.enumerated() {
            let size = image.size
            let page = NotePage(order: index, backgroundImageData: image.jpegData(compressionQuality: 0.88), pageWidth: size.width, pageHeight: size.height)
            page.notebook = notebook
            notebook.pages.append(page)
        }
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func beginRename(_ notebook: Notebook) {
        renameText = notebook.title
        notebookToRename = notebook
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = selectedFolder.map { "\($0)/\(name)" } ?? name
        var names = Set(folderNames)
        names.insert(path)
        folderNamesStorage = names.sorted().joined(separator: "\n")
        var dates = folderCreatedAt
        if dates[path] == nil { dates[path] = Date.now.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(dates), let value = String(data: data, encoding: .utf8) {
            folderCreatedAtStorage = value
        }
        selectedFolder = path
        libraryMode = .documents
        newFolderName = ""
    }

    private func goBackOneFolder() {
        guard let selectedFolder else { return }
        self.selectedFolder = parentFolder(of: selectedFolder)
        selectedNotebook = nil
        libraryMode = .documents
    }

    private func beginTagEditing(_ notebook: Notebook) {
        tagsText = notebook.tagsText
        notebookToEditTags = notebook
    }

    private func saveTags() {
        guard let notebookToEditTags else { return }
        notebookToEditTags.tags = tagsText.split(separator: ",").map(String.init)
        notebookToEditTags.updatedAt = .now
        self.notebookToEditTags = nil
    }

    private func renameNotebook() {
        guard let notebookToRename else { return }
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            notebookToRename.title = value
            notebookToRename.updatedAt = .now
        }
        self.notebookToRename = nil
    }

    private func duplicate(_ source: Notebook) {
        let copy = Notebook(title: "\(source.title) のコピー")
        copy.isFavorite = source.isFavorite
        for original in source.sortedPages {
            let page = NotePage(
                order: original.order,
                backgroundImageData: original.backgroundImageData,
                pageWidth: original.pageWidth,
                pageHeight: original.pageHeight
            )
            page.drawingData = original.drawingData
            page.templateRawValue = original.templateRawValue
            page.isBookmarked = original.isBookmarked
            page.title = original.title
            for originalElement in original.elements {
                let element = cloneElement(originalElement)
                element.page = page
                page.elements.append(element)
            }
            page.notebook = copy
            copy.pages.append(page)
        }
        copy.refreshLibraryMetadata()
        modelContext.insert(copy)
        selectedNotebook = copy
    }

    private func moveToTrash(_ notebook: Notebook) {
        notebook.isTrashed = true
        notebook.trashedAt = .now
        if selectedNotebook === notebook { selectedNotebook = nil }
    }

    private func restore(_ notebook: Notebook) {
        notebook.isTrashed = false
        notebook.trashedAt = nil
        libraryMode = .documents
        selectedNotebook = notebook
    }

    private func permanentlyDelete(_ notebook: Notebook) {
        if selectedNotebook === notebook { selectedNotebook = nil }
        modelContext.delete(notebook)
    }

    private func emptyTrash() {
        allNotebooks.filter(\.isTrashed).forEach(modelContext.delete)
        selectedNotebook = nil
    }

    @MainActor
    private func rebuildLibraryMetadataIfNeeded() async {
        let staleNotebooks = allNotebooks.filter { $0.libraryMetadataVersion < 1 }
        guard notebookLibraryMetadataVersion < 1 || !staleNotebooks.isEmpty else { return }

        try? await Task.sleep(nanoseconds: 350_000_000)
        for notebook in staleNotebooks {
            notebook.refreshLibraryMetadata()
            await Task.yield()
        }
        try? modelContext.save()
        notebookLibraryMetadataVersion = 1
    }

    private func cloneElement(_ source: PageElement) -> PageElement {
        let element = PageElement(
            kind: source.kind,
            text: source.text,
            imageData: source.imageData,
            centerX: source.centerX,
            centerY: source.centerY,
            width: source.width,
            height: source.height,
            rotation: source.rotation,
            colorHex: source.colorHex
        )
        element.isLocked = source.isLocked
        element.layerIndex = source.layerIndex
        return element
    }

    @ViewBuilder
    private func notebookRows(_ notebooks: [Notebook]) -> some View {
        ForEach(notebooks) { notebook in
            NavigationLink(value: notebook) {
                NotebookRow(notebook: notebook)
            }
            .contextMenu {
                notebookActions(notebook)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !notebook.isTrashed {
                    Button {
                        notebook.isFavorite.toggle()
                    } label: {
                        Label(notebook.isFavorite ? "解除" : "お気に入り", systemImage: notebook.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if notebook.isTrashed {
                    Button("復元") { restore(notebook) }
                        .tint(.green)
                    Button("削除", role: .destructive) { permanentlyDelete(notebook) }
                } else {
                    Button("ゴミ箱", role: .destructive) { moveToTrash(notebook) }
                }
            }
        }
    }
}

private struct NotebookRow: View {
    @Bindable var notebook: Notebook

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notebook.containsPDF ? "doc.richtext" : "note.text")
                .font(.title2)
                .foregroundStyle(notebook.containsPDF ? .red : .blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(notebook.title).font(.headline).lineLimit(1)
                    if notebook.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    }
                }
                Text("\(notebook.pageCountForLibrary)ページ ・ \(notebook.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !notebook.tags.isEmpty {
                    Text(notebook.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                notebook.isFavorite.toggle()
                notebook.updatedAt = .now
            } label: {
                Image(systemName: notebook.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(notebook.isFavorite ? .yellow : .secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private enum NotebookSortOption: String, CaseIterable, Identifiable {
    case updatedNewest, updatedOldest, createdNewest, createdOldest, nameAscending, nameDescending, pageCount
    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedNewest: "更新日が新しい順"
        case .updatedOldest: "更新日が古い順"
        case .createdNewest: "作成日が新しい順"
        case .createdOldest: "作成日が古い順"
        case .nameAscending: "名前 A–Z"
        case .nameDescending: "名前 Z–A"
        case .pageCount: "ページ数が多い順"
        }
    }

    var comparator: (Notebook, Notebook) -> Bool {
        switch self {
        case .updatedNewest: { $0.updatedAt > $1.updatedAt }
        case .updatedOldest: { $0.updatedAt < $1.updatedAt }
        case .createdNewest: { $0.createdAt > $1.createdAt }
        case .createdOldest: { $0.createdAt < $1.createdAt }
        case .nameAscending: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDescending: { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .pageCount: { $0.pageCountForLibrary > $1.pageCountForLibrary }
        }
    }
}

private enum LibraryMode: String, CaseIterable, Identifiable {
    case documents, favorites, pdfs, studyCards, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: "すべて"
        case .favorites: "お気に入り"
        case .pdfs: "PDF"
        case .studyCards: "暗記カード"
        case .trash: "ゴミ箱"
        }
    }

    var icon: String {
        switch self {
        case .documents: "square.grid.2x2"
        case .favorites: "star"
        case .pdfs: "doc.richtext"
        case .studyCards: "rectangle.on.rectangle.angled"
        case .trash: "trash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .documents: "ノートがありません"
        case .favorites: "お気に入りはありません"
        case .pdfs: "PDFはありません"
        case .studyCards: "暗記カードはありません"
        case .trash: "ゴミ箱は空です"
        }
    }

    var emptyMessage: String {
        switch self {
        case .documents: "＋からノートを作るかPDFを読み込んでください"
        case .favorites: "ノートを左へスワイプして登録できます"
        case .pdfs: "＋からPDFを読み込んでください"
        case .studyCards: "＋からノートを選んで暗記カードを作成してください"
        case .trash: "削除したノートがここに表示されます"
        }
    }
}
