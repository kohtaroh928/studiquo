import SwiftData
import SwiftUI

/// How the split-screen source picker lays its materials out.
enum SplitSourceLayout: String, CaseIterable, Identifiable {
    case list, icon, column

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "リスト"
        case .icon: "アイコン"
        case .column: "カラム"
        }
    }

    /// Same symbols as the home screen's view-mode buttons.
    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .icon: "square.grid.2x2"
        case .column: "rectangle.split.3x1"
        }
    }

    /// An unknown or missing stored value falls back to the list.
    init(storedValue: String) {
        self = SplitSourceLayout(rawValue: storedValue) ?? .list
    }
}

enum SplitSourceKind: CaseIterable, Identifiable {
    case note, pdf, deck

    var id: Self { self }

    var title: String {
        switch self {
        case .note: "ノート"
        case .pdf: "PDF"
        case .deck: "暗記カード"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .pdf: "doc.richtext"
        case .deck: "rectangle.on.rectangle.angled"
        }
    }

    var tint: Color {
        switch self {
        case .note: .blue
        case .pdf: .red
        case .deck: .indigo
        }
    }
}

struct SplitSourceItem: Identifiable {
    enum Source {
        case notebook(Notebook)
        case deck(FlashcardDeck)
    }

    /// The model's own persistent identity, so a row keeps its identity (and
    /// the list its scroll position and selection) when SwiftData refetches.
    enum ID: Hashable {
        case notebook(PersistentIdentifier)
        case deck(PersistentIdentifier)
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
}

struct SplitSourceGroup: Identifiable {
    let kind: SplitSourceKind
    let items: [SplitSourceItem]

    var id: SplitSourceKind { kind }
}

enum SplitSourceCatalog {
    /// One group per kind, always in the same order, so the layouts agree on
    /// what is shown. Trashed materials are left out; the notebook already
    /// open in the primary pane stays in (and is marked) because opening it
    /// in both panes is a supported arrangement.
    static func groups(
        notebooks: [Notebook],
        flashcardDecks: [FlashcardDeck],
        primaryNotebook: Notebook?
    ) -> [SplitSourceGroup] {
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
        let all = notebookItems + deckItems
        return SplitSourceKind.allCases.map { kind in
            SplitSourceGroup(kind: kind, items: all.filter { $0.kind == kind })
        }
    }
}

extension SplitSourceCatalog {
    /// Folder paths for the column layout: every real folder, every folder an
    /// item points at (even without a `Folder` object behind it) and all of
    /// their ancestors, so no column is unreachable. Never contains "".
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

    /// Items directly inside `path` (nil = top level), notes first, then PDFs,
    /// then decks, each in the order they were given.
    static func items(inFolder path: String?, from groups: [SplitSourceGroup]) -> [SplitSourceItem] {
        groups.flatMap(\.items).filter { $0.folderPath == (path ?? "") }
    }
}

struct SplitSourcePicker: View {
    let notebooks: [Notebook]
    let flashcardDecks: [FlashcardDeck]
    let primaryNotebook: Notebook
    let onSelectNotebook: (Notebook) -> Void
    let onSelectDeck: (FlashcardDeck) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("splitSourcePickerLayout") private var storedLayout = SplitSourceLayout.list.rawValue
    @Query private var folders: [Folder]
    @State private var openFolderPath: String?
    @State private var showsNewNotebookAlert = false
    @State private var showsNewDeckAlert = false
    @State private var newItemName = ""

    private var layout: SplitSourceLayout { SplitSourceLayout(storedValue: storedLayout) }

    private var groups: [SplitSourceGroup] {
        SplitSourceCatalog.groups(
            notebooks: notebooks,
            flashcardDecks: flashcardDecks,
            primaryNotebook: primaryNotebook
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                layoutBar
                Divider()
                content
            }
                .navigationTitle("分割して開くものを選択")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: .constant(""), prompt: "ノート、PDF、暗記カード")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { createMenu }
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
                            layout == option ? Color.accentColor.opacity(0.18) : Color.clear,
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

    private var createMenu: some View {
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

    // MARK: Layouts

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .list: listLayout
        case .icon: iconLayout
        case .column: columnLayout
        }
    }

    private var listLayout: some View {
        List {
            ForEach(groups) { group in
                Section {
                    if group.items.isEmpty {
                        Text("\(group.kind.title)はありません").foregroundStyle(.secondary)
                    }
                    ForEach(group.items) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind.systemImage).foregroundStyle(item.kind.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                displayedBadge(item)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("split-source-item-\(item.title)")
                    }
                } header: {
                    Text(group.kind.title)
                }
            }
        }
        .accessibilityIdentifier("split-source-list")
    }

    private var iconLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.kind.title).font(.headline)
                        if group.items.isEmpty {
                            Text("\(group.kind.title)はありません")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 18)],
                                alignment: .leading,
                                spacing: 22
                            ) {
                                ForEach(group.items) { item in
                                    Button { select(item) } label: { tile(item) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("split-source-item-\(item.title)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("split-source-icons")
    }

    private func tile(_ item: SplitSourceItem) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 38))
                .foregroundStyle(item.kind.tint)
                .frame(width: 84, height: 84)
                .background(item.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            Text(item.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(item.isDisplayed ? "表示中" : item.detail)
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
        let groups = groups
        let paths = SplitSourceCatalog.folderPaths(
            folderPaths: folders.map(\.legacyPath),
            itemPaths: groups.flatMap(\.items).map(\.folderPath)
        )
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
                                    paths: paths,
                                    groups: groups
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

    private func column(parent: String?, highlighted: String?, paths: [String], groups: [SplitSourceGroup]) -> some View {
        let subfolders = SplitSourceCatalog.subfolders(of: parent, in: paths)
        let items = SplitSourceCatalog.items(inFolder: parent, from: groups)
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
                            .background(path == highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("split-source-folder-\(path)")
                        Divider().padding(.leading, 16)
                    }
                    ForEach(items) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.kind.systemImage).foregroundStyle(item.kind.tint)
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
