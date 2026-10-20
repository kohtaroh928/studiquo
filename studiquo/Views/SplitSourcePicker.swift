import SwiftData
import SwiftUI

/// How the split-screen source picker lays its materials out.
enum SplitSourceLayout: String, CaseIterable, Identifiable {
    /// `kind` is not a home-screen mode: it sets the folders aside and sorts
    /// every material under its kind (note, PDF, deck, document).
    case list, icon, column, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "リスト"
        case .icon: "アイコン"
        case .column: "カラム"
        case .kind: "種類"
        }
    }

    /// The first three use the home screen's view-mode symbols.
    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .icon: "square.grid.2x2"
        case .column: "rectangle.split.3x1"
        case .kind: "square.stack.3d.up"
        }
    }

    /// An unknown or missing stored value falls back to the list.
    init(storedValue: String) {
        self = SplitSourceLayout(rawValue: storedValue) ?? .list
    }
}

/// The picker's top-level tabs. 資料 is the file browser; AI and フレンド list
/// conversations in a sidebar and appear only when the owner can open them.
enum SplitSourceSection: String, CaseIterable, Identifiable {
    case materials, ai, friends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .materials: "資料"
        case .ai: "AI"
        case .friends: "フレンド"
        }
    }

    var systemImage: String {
        switch self {
        case .materials: "folder"
        case .ai: "sparkles"
        case .friends: "person.2"
        }
    }
}

enum SplitSourceKind: CaseIterable, Identifiable {
    case note, pdf, deck, document

    var id: Self { self }

    var title: String {
        switch self {
        case .note: "ノート"
        case .pdf: "PDF"
        case .deck: "暗記カード"
        case .document: "文書"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .pdf: "doc.richtext"
        case .deck: "rectangle.on.rectangle.angled"
        case .document: "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .note: .blue
        case .pdf: .red
        case .deck: .indigo
        case .document: .teal
        }
    }
}

struct SplitSourceItem: Identifiable {
    enum Source {
        case notebook(Notebook)
        case deck(FlashcardDeck)
        case document(TextDocument)
    }

    /// The model's own persistent identity, so a row keeps its identity (and
    /// the list its scroll position and selection) when SwiftData refetches.
    enum ID: Hashable {
        case notebook(PersistentIdentifier)
        case deck(PersistentIdentifier)
        case document(PersistentIdentifier)
    }

    let id: ID
    let kind: SplitSourceKind
    /// "/"-joined folder path, "" for the top level — the same value the home
    /// screen's folder views match on.
    let folderPath: String
    let title: String
    let detail: String
    let isDisplayed: Bool
    let source: Source

    /// The notebook whose first page can stand in for this item's icon.
    var coverNotebook: Notebook? {
        if kind == .pdf, case .notebook(let notebook) = source { return notebook }
        return nil
    }
}

enum SplitSourceCatalog {
    /// Every selectable material, notes first, then PDFs, then decks, each in
    /// the order they were given. Trashed materials are left out; the notebook
    /// already open in the primary pane stays in (and is marked) because
    /// opening it in both panes is a supported arrangement.
    static func items(
        notebooks: [Notebook],
        flashcardDecks: [FlashcardDeck],
        textDocuments: [TextDocument] = [],
        primaryNotebook: Notebook?
    ) -> [SplitSourceItem] {
        let notebookItems = notebooks.filter { !$0.isTrashed }.map { notebook in
            SplitSourceItem(
                id: .notebook(notebook.persistentModelID),
                kind: notebook.containsPDF ? .pdf : .note,
                folderPath: notebook.folderName,
                title: notebook.title,
                detail: "\(notebook.sortedPages.count)ページ",
                isDisplayed: notebook === primaryNotebook,
                source: .notebook(notebook)
            )
        }
        let deckItems = flashcardDecks.filter { !$0.isTrashed }.map { deck in
            SplitSourceItem(
                id: .deck(deck.persistentModelID),
                kind: .deck,
                folderPath: deck.folderName,
                title: deck.title,
                detail: "\(deck.sortedCards.count)枚",
                isDisplayed: false,
                source: .deck(deck)
            )
        }
        let documentItems = textDocuments.filter { !$0.isTrashed }.map { document in
            SplitSourceItem(
                id: .document(document.persistentModelID),
                kind: .document,
                folderPath: document.folderName,
                title: document.title,
                detail: "文書",
                isDisplayed: false,
                source: .document(document)
            )
        }
        let all = notebookItems + deckItems + documentItems
        return SplitSourceKind.allCases.flatMap { kind in all.filter { $0.kind == kind } }
    }

    /// Items whose title contains `query`, ignoring case. An empty query
    /// matches everything.
    static func items(_ items: [SplitSourceItem], matchingSearch query: String) -> [SplitSourceItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

extension SplitSourceCatalog {
    /// Folder paths to browse: every real folder, every folder an item points
    /// at (even without a `Folder` object behind it) and all of their
    /// ancestors, so none is unreachable. Never contains "".
    static func folderPaths(folderPaths: [String], itemPaths: [String]) -> [String] {
        var all = Set<String>()
        for path in folderPaths + itemPaths where !path.isEmpty {
            for ancestor in chain(endingAt: path) { all.insert(ancestor) }
        }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The folders directly inside `parent` (nil = top level).
    static func subfolders(of parent: String?, in paths: [String]) -> [String] {
        paths.filter { parentPath(of: $0) == parent }
    }

    static func parentPath(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    static func displayName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// "a/b/c" -> ["a", "a/b", "a/b/c"]: one entry per column that is open.
    static func chain(endingAt path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let components = path.split(separator: "/").map(String.init)
        return components.indices.map { components[0...$0].joined(separator: "/") }
    }

    /// Items directly inside `path` (nil = top level), in the order given.
    static func items(inFolder path: String?, from items: [SplitSourceItem]) -> [SplitSourceItem] {
        items.filter { $0.folderPath == (path ?? "") }
    }

    /// How many items sit in `path` or anywhere below it.
    static func itemCount(inFolderTree path: String, from items: [SplitSourceItem]) -> Int {
        items.filter { $0.folderPath == path || $0.folderPath.hasPrefix(path + "/") }.count
    }

}

struct SplitSourcePicker: View {
    let notebooks: [Notebook]
    let flashcardDecks: [FlashcardDeck]
    /// Text documents are offered only when `onSelectDocument` is given (the
    /// split view cannot show them; the tab bar can).
    var textDocuments: [TextDocument] = []
    var primaryNotebook: Notebook?
    var title = "分割して開くものを選択"
    let onSelectNotebook: (Notebook) -> Void
    let onSelectDeck: (FlashcardDeck) -> Void
    var onSelectDocument: ((TextDocument) -> Void)?
    /// When given, "新規作成" hands the kind to the owner (which presents its
    /// own name entry) instead of creating the item in the picker itself.
    var onCreate: ((SplitSourceKind) -> Void)?
    /// The AI tab is offered only when this is given.
    var onSelectAIChat: ((PersistentIdentifier) -> Void)?
    /// The フレンド tab is offered only when the store and both handlers are given.
    var friendStore: FriendStore?
    var onSelectFriend: ((FriendRecord) -> Void)?
    var onSelectGroup: ((FriendChatService.Group) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("splitSourcePickerLayout") private var storedLayout = SplitSourceLayout.list.rawValue
    @Query private var folders: [Folder]
    /// Shared by all three layouts, so switching layout keeps the place.
    @State private var openFolderPath: String?
    @State private var showsNewNotebookAlert = false
    @State private var showsNewDeckAlert = false
    @State private var newItemName = ""
    @State private var searchText = ""
    @State private var section = SplitSourceSection.materials

    private var availableSections: [SplitSourceSection] {
        var sections: [SplitSourceSection] = [.materials]
        if onSelectAIChat != nil { sections.append(.ai) }
        if friendStore != nil, onSelectFriend != nil, onSelectGroup != nil { sections.append(.friends) }
        return sections
    }

    private var layout: SplitSourceLayout { SplitSourceLayout(storedValue: storedLayout) }

    private var allItems: [SplitSourceItem] {
        SplitSourceCatalog.items(
            notebooks: notebooks,
            flashcardDecks: flashcardDecks,
            textDocuments: onSelectDocument == nil ? [] : textDocuments,
            primaryNotebook: primaryNotebook
        )
    }

    /// Every material, and the folders that lead to them.
    private struct Browse {
        let items: [SplitSourceItem]
        let paths: [String]
    }

    private var browse: Browse {
        let all = allItems
        return Browse(
            items: all,
            paths: SplitSourceCatalog.folderPaths(folderPaths: folders.map(\.legacyPath), itemPaths: all.map(\.folderPath))
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if availableSections.count > 1 {
                    sectionBar
                    Divider()
                }
                switch section {
                case .materials:
                    materialsBody
                case .ai:
                    if let onSelectAIChat {
                        SplitSourceAIChatSidebar(onSelect: onSelectAIChat)
                    }
                case .friends:
                    if let friendStore, let onSelectFriend, let onSelectGroup {
                        SplitSourceFriendSidebar(store: friendStore, onSelectFriend: onSelectFriend, onSelectGroup: onSelectGroup)
                    }
                }
            }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .modifier(SplitSourceSearchable(isEnabled: section == .materials, text: $searchText))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if section == .materials { createMenu }
                    }
                }
        }
        .modifier(FixedSheetSize(shape: .page))
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

    private var materialsBody: some View {
        VStack(spacing: 0) {
            layoutBar
            Divider()
            if searchText.isEmpty {
                if layout == .list || layout == .icon { locationBar }
                content
            } else {
                searchResults
            }
        }
    }

    private var sectionBar: some View {
        Picker("種類", selection: $section) {
            ForEach(availableSections) { option in
                Label(option.title, systemImage: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("split-source-section")
    }

    // MARK: Layout switcher

    /// Sits at the top of the content, below the title, so the title stays
    /// visible and the three buttons have the full width on a narrow sheet.
    private var layoutBar: some View {
        HStack(spacing: 4) {
            Spacer()
            ForEach(SplitSourceLayout.allCases) { option in
                Button {
                    storedLayout = option.rawValue
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(layout == option ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            layout == option ? Theme.Palette.accent.opacity(0.18) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("split-source-layout-\(option.rawValue)")
                .accessibilityAddTraits(layout == option ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// List and icon layouts show one folder at a time; this names it and
    /// goes back up. (The column layout shows the whole path instead.)
    @ViewBuilder
    private var locationBar: some View {
        if let path = openFolderPath {
            HStack(spacing: 8) {
                Button {
                    openFolderPath = SplitSourceCatalog.parentPath(of: path)
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("split-source-back")
                Text(path.replacingOccurrences(of: "/", with: " ▸ "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(.bar)
            Divider()
        }
    }

    private var createMenu: some View {
        Menu {
            Button {
                requestCreate(.note)
            } label: {
                Label("新規ノート", systemImage: "note.text.badge.plus")
            }
            Button {
                requestCreate(.deck)
            } label: {
                Label("新規暗記カード", systemImage: "rectangle.on.rectangle.angled")
            }
            if onSelectDocument != nil {
                Button {
                    requestCreate(.document)
                } label: {
                    Label("新規文書", systemImage: "doc.text")
                }
            }
        } label: {
            Label("新規作成", systemImage: "plus")
        }
    }

    private func requestCreate(_ kind: SplitSourceKind) {
        if let onCreate {
            onCreate(kind)
            return
        }
        newItemName = ""
        switch kind {
        case .deck: showsNewDeckAlert = true
        default: showsNewNotebookAlert = true
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .list: listLayout
        case .icon: iconLayout
        case .column: columnLayout
        case .kind: kindLayout
        }
    }

    private var emptyText: String {
        openFolderPath != nil ? "このフォルダは空です" : "資料はありません"
    }

    /// While searching, folders are ignored: every matching material (of the
    /// chosen kind) is listed, wherever it lives.
    private var searchResults: some View {
        let matches = SplitSourceCatalog.items(allItems, matchingSearch: searchText)
        return List {
            if matches.isEmpty {
                Text("該当する資料はありません").foregroundStyle(.secondary)
            }
            ForEach(matches) { item in
                itemRow(item)
            }
        }
        .accessibilityIdentifier("split-source-search-results")
    }

    /// A PDF's icon is its first page where `showsCover` is set (the "種類"
    /// layout); the plain list and the search results keep the kind symbol.
    private func itemRow(_ item: SplitSourceItem, showsFolder: Bool = false, showsCover: Bool = false) -> some View {
        Button { select(item) } label: {
            HStack(spacing: 12) {
                itemIcon(item, showsCover: showsCover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(itemCaption(item, showsFolder: showsFolder))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                displayedBadge(item)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("split-source-item-\(item.title)")
    }

    /// Folders set aside: one section per kind, each listing every material
    /// of that kind wherever it lives (the folder is shown beside it).
    private var kindLayout: some View {
        let all = allItems
        let kinds = SplitSourceKind.allCases.filter { $0 != .document || onSelectDocument != nil }
        return List {
            ForEach(kinds) { kind in
                let items = all.filter { $0.kind == kind }
                Section {
                    if items.isEmpty {
                        Text("\(kind.title)はありません").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        itemRow(item, showsFolder: true, showsCover: true)
                    }
                } header: {
                    Label(kind.title, systemImage: kind.systemImage)
                        .foregroundStyle(kind.tint)
                }
            }
        }
        .accessibilityIdentifier("split-source-kinds")
    }

    @ViewBuilder
    private func itemIcon(_ item: SplitSourceItem, showsCover: Bool) -> some View {
        if showsCover, let notebook = item.coverNotebook {
            NotebookCoverView(notebook: notebook, size: CGSize(width: 28, height: 36))
        } else {
            Image(systemName: item.kind.systemImage).foregroundStyle(item.kind.tint)
        }
    }

    private func itemCaption(_ item: SplitSourceItem, showsFolder: Bool) -> String {
        if showsFolder {
            return item.folderPath.isEmpty ? item.detail : "\(item.detail) · \(item.folderPath)"
        }
        return "\(item.kind.title) · \(item.detail)"
    }

    private var listLayout: some View {
        let browse = browse
        let subfolders = SplitSourceCatalog.subfolders(of: openFolderPath, in: browse.paths)
        let items = SplitSourceCatalog.items(inFolder: openFolderPath, from: browse.items)
        return List {
            if subfolders.isEmpty && items.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(subfolders, id: \.self) { path in
                Button { openFolderPath = path } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SplitSourceCatalog.displayName(of: path)).lineLimit(1)
                            Text("\(SplitSourceCatalog.itemCount(inFolderTree: path, from: browse.items))件")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("split-source-folder-\(path)")
            }
            ForEach(items) { item in
                itemRow(item)
            }
        }
        .accessibilityIdentifier("split-source-list")
    }

    private var iconLayout: some View {
        let browse = browse
        let subfolders = SplitSourceCatalog.subfolders(of: openFolderPath, in: browse.paths)
        let items = SplitSourceCatalog.items(inFolder: openFolderPath, from: browse.items)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if subfolders.isEmpty && items.isEmpty {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 18)],
                        alignment: .leading,
                        spacing: 22
                    ) {
                        ForEach(subfolders, id: \.self) { path in
                            Button { openFolderPath = path } label: {
                                tile(
                                    systemImage: "folder.fill",
                                    tint: .accentColor,
                                    title: SplitSourceCatalog.displayName(of: path),
                                    caption: "\(SplitSourceCatalog.itemCount(inFolderTree: path, from: browse.items))件"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("split-source-folder-\(path)")
                        }
                        ForEach(items) { item in
                            Button { select(item) } label: {
                                tile(
                                    systemImage: item.kind.systemImage,
                                    tint: item.kind.tint,
                                    title: item.title,
                                    caption: item.isDisplayed ? "表示中" : item.detail,
                                    cover: item.coverNotebook
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("split-source-item-\(item.title)")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("split-source-icons")
    }

    private func tile(
        systemImage: String, tint: Color, title: String, caption: String, cover: Notebook? = nil
    ) -> some View {
        VStack(spacing: 8) {
            if let cover {
                NotebookCoverView(notebook: cover, size: CGSize(width: 84, height: 84))
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 38))
                    .foregroundStyle(tint)
                    .frame(width: 84, height: 84)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            }
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Finder-style columns, as on the home screen: the top level first, and
    /// each folder you open adds a column to its right. When the columns are
    /// wider than the sheet the row scrolls sideways (and follows the newest
    /// column); each column scrolls on its own vertically.
    private var columnLayout: some View {
        let browse = browse
        let chain = SplitSourceCatalog.chain(endingAt: openFolderPath)
        return GeometryReader { geometry in
            let columnWidth: CGFloat = horizontalSizeClass == .compact
                ? max(geometry.size.width - 56, 220)
                : 300
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0...chain.count, id: \.self) { level in
                            HStack(spacing: 0) {
                                column(
                                    parent: level == 0 ? nil : chain[level - 1],
                                    highlighted: level < chain.count ? chain[level] : nil,
                                    browse: browse
                                )
                                .frame(width: columnWidth)
                                Divider()
                            }
                            .id(level)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .onChange(of: chain.count) { _, newCount in
                    withAnimation { proxy.scrollTo(newCount, anchor: .trailing) }
                }
                .accessibilityIdentifier("split-source-columns")
            }
        }
    }

    private func column(parent: String?, highlighted: String?, browse: Browse) -> some View {
        let subfolders = SplitSourceCatalog.subfolders(of: parent, in: browse.paths)
        let items = SplitSourceCatalog.items(inFolder: parent, from: browse.items)
        return VStack(spacing: 0) {
            Label(
                parent.map(SplitSourceCatalog.displayName(of:)) ?? "ホーム",
                systemImage: parent == nil ? "house" : "folder"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(.bar)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if subfolders.isEmpty && items.isEmpty {
                        Text(parent == nil ? "資料はありません" : "このフォルダは空です")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    ForEach(subfolders, id: \.self) { path in
                        Button { openFolderPath = path } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                Text(SplitSourceCatalog.displayName(of: path)).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .padding(.horizontal, 16)
                            .background(path == highlighted ? Theme.Palette.accent.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("split-source-folder-\(path)")
                        Divider().padding(.leading, 16)
                    }
                    ForEach(items) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 10) {
                                itemIcon(item, showsCover: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text("\(item.kind.title) · \(item.detail)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                displayedBadge(item)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("split-source-item-\(item.title)")
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func displayedBadge(_ item: SplitSourceItem) -> some View {
        if item.isDisplayed {
            Text("表示中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func select(_ item: SplitSourceItem) {
        switch item.source {
        case .notebook(let notebook): onSelectNotebook(notebook)
        case .deck(let deck): onSelectDeck(deck)
        case .document(let document): onSelectDocument?(document)
        }
    }

    private func createNotebook() {
        let title = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: title.isEmpty ? "新しいノート" : title)
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.addPage(page)
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

/// Search belongs to the material browser only; the conversation sidebars
/// are short enough to scan.
private struct SplitSourceSearchable: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, prompt: "名前で検索")
        } else {
            content
        }
    }
}

/// The AI tab: the conversation names as a sidebar. Threads with no message
/// are left out, matching what the AI chat itself lists.
private struct SplitSourceAIChatSidebar: View {
    @Query(sort: \AIChatThread.updatedAt, order: .reverse) private var allThreads: [AIChatThread]
    let onSelect: (PersistentIdentifier) -> Void

    var body: some View {
        let threads = allThreads.filter { !$0.sortedMessages.isEmpty }
        List {
            if threads.isEmpty {
                Label("AIチャットはありません", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
            ForEach(threads) { thread in
                Button { onSelect(thread.persistentModelID) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title).lineLimit(1)
                            Text(thread.updatedAt, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("split-source-ai-\(thread.title)")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("split-source-ai-list")
    }
}

/// The フレンド tab: friends and groups as a sidebar.
private struct SplitSourceFriendSidebar: View {
    @ObservedObject var store: FriendStore
    let onSelectFriend: (FriendRecord) -> Void
    let onSelectGroup: (FriendChatService.Group) -> Void

    var body: some View {
        List {
            Section("フレンド") {
                if store.friends.isEmpty {
                    Label("フレンドがいません", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.friends) { friend in
                    Button { onSelectFriend(friend) } label: {
                        row(title: friend.name, icon: "person.crop.circle.fill", unread: store.unreadCounts[friend.id, default: 0])
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("split-source-friend-\(friend.name)")
                }
            }
            Section("グループ") {
                if store.groups.isEmpty {
                    Label("参加中のグループがありません", systemImage: "person.3")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.groups, id: \.roomID) { group in
                    Button { onSelectGroup(group) } label: {
                        row(title: group.name, icon: "person.3.fill", unread: store.groupUnreadCounts[group.roomID, default: 0])
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("split-source-group-\(group.name)")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("split-source-friend-list")
    }

    private func row(title: String, icon: String, unread: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(title).lineLimit(1)
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }
}
