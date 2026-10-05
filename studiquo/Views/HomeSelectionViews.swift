import SwiftUI

/// The empty white circle (or blue circle with a check) shown on every
/// selectable folder and item while the home screen is in multi-select mode.
struct HomeSelectionCircle: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.white)
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.6), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        .accessibilityHidden(true)
    }
}

/// Turns a folder row/tile or an item row/tile into a selectable one while
/// multi-select mode is on, and leaves it untouched otherwise.
///
/// While selecting, the original content is shown with hit testing off, so
/// opening, long-press menus, drag-and-drop and its own buttons stop
/// reacting; tapping anywhere on it only toggles the selection. Folders also
/// get a separate "open" button, so the student can still browse into a
/// folder (keeping the selection) without selecting it.
struct HomeSelectableModifier: ViewModifier {
    enum Layout {
        case row
        case tile
    }

    let isSelecting: Bool
    let isSelected: Bool
    let layout: Layout
    let label: String
    let toggle: () -> Void
    var open: (() -> Void)?
    /// Space before the circle in `.row` layout. Rows that already sit inside
    /// their own horizontal padding pass less so the circles line up.
    var leadingInset: CGFloat = 12

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelecting {
            switch layout {
            case .row: rowBody(content)
            case .tile: tileBody(content)
            }
        } else {
            content
        }
    }

    private func rowBody(_ content: Content) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                HomeSelectionCircle(isSelected: isSelected)
                    .padding(.leading, leadingInset)
                // A stack of its own: a `Divider` inside the row's content
                // takes its direction from the nearest enclosing stack, and
                // would otherwise turn into a vertical line in this HStack.
                VStack(spacing: 0) {
                    content
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .modifier(SelectableAccessibility(isSelected: isSelected, label: label))
            if let open {
                openButton(open)
                    .padding(.trailing, 8)
            }
        }
    }

    private func tileBody(_ content: Content) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                content
                    .allowsHitTesting(false)
                HomeSelectionCircle(isSelected: isSelected)
                    .padding(4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .modifier(SelectableAccessibility(isSelected: isSelected, label: label))
            if let open {
                openButton(open)
            }
        }
    }

    private func openButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)を開く")
        .accessibilityIdentifier("library-open-\(label)")
    }
}

/// VoiceOver reads a selectable row as one button whose state is
/// "selected"/"not selected"; the identifier lets UI tests find it by title.
private struct SelectableAccessibility: ViewModifier {
    let isSelected: Bool
    let label: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(isSelected ? Text("選択済み") : Text("未選択"))
            .accessibilityIdentifier("library-select-\(label)")
    }
}

/// The bar pinned to the bottom of the home screen while selecting. Outside
/// the trash it offers move and delete; in the trash, restore and delete
/// forever (items there cannot be moved).
struct HomeSelectionActionBar: View {
    let isTrash: Bool
    let count: Int
    let onPrimary: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPrimary) {
                Label(isTrash ? "復元" : "移動", systemImage: isTrash ? "arrow.uturn.backward" : "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(isTrash ? "library-selection-restore" : "library-selection-move")

            Button(role: .destructive, action: onDelete) {
                Label(isTrash ? "完全に削除" : "削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(isTrash ? "library-selection-permanent-delete" : "library-selection-delete")
        }
        .controlSize(.large)
        .disabled(count == 0)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Wording for one of the confirmation dialogs.
struct HomeSelectionConfirmation {
    let title: String
    let message: String
    let confirmTitle: String
}

/// The sheet and dialogs the multi-select actions open. Kept as a modifier of
/// its own so the already very large home screen body does not have to type
/// check them inline.
struct HomeSelectionPresentations<Sheet: View>: ViewModifier {
    @Binding var showsMoveSheet: Bool
    @Binding var showsTrashConfirmation: Bool
    @Binding var showsPermanentDeleteConfirmation: Bool
    @Binding var resultMessage: String?
    let trashConfirmation: HomeSelectionConfirmation
    let permanentDeleteConfirmation: HomeSelectionConfirmation
    let onTrash: () -> Void
    let onPermanentDelete: () -> Void
    @ViewBuilder let moveSheet: () -> Sheet

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsMoveSheet) { moveSheet() }
            .confirmationDialog(
                trashConfirmation.title,
                isPresented: $showsTrashConfirmation,
                titleVisibility: .visible
            ) {
                Button(trashConfirmation.confirmTitle, role: .destructive, action: onTrash)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(trashConfirmation.message)
            }
            .confirmationDialog(
                permanentDeleteConfirmation.title,
                isPresented: $showsPermanentDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(permanentDeleteConfirmation.confirmTitle, role: .destructive, action: onPermanentDelete)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(permanentDeleteConfirmation.message)
            }
            .alert(
                "お知らせ",
                isPresented: Binding(
                    get: { resultMessage != nil },
                    set: { if !$0 { resultMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
    }
}

/// "移動" destination picker: the folder hierarchy, browsed one level at a
/// time like the Files app. The top level is "ホーム" (no folder).
struct HomeMoveDestinationView: View {
    let selectedCount: Int
    /// The folder the home screen is currently showing; moving there is a no-op.
    let currentPath: String?
    /// Selected folders: neither they nor anything beneath them is a valid target.
    let movingFolderPaths: [String]
    /// Every folder path, already sorted for display.
    let folderPaths: [String]
    let onMove: (String?) -> Void
    let onCreateFolder: (String?, String) -> Void
    let onCancel: () -> Void

    @State private var stack: [String] = []

    var body: some View {
        NavigationStack(path: $stack) {
            HomeMoveDestinationLevel(host: self, location: nil)
                .navigationDestination(for: String.self) { path in
                    HomeMoveDestinationLevel(host: self, location: path)
                }
        }
    }
}

private struct HomeMoveDestinationLevel: View {
    let host: HomeMoveDestinationView
    let location: String?

    @State private var showsNewFolderAlert = false
    @State private var newFolderName = ""

    private var children: [String] {
        host.folderPaths.filter { parent(of: $0) == location }
    }

    private var isCurrentLocation: Bool { location == host.currentPath }

    private var isBlocked: Bool {
        HomeSelectionRules.isMoveDestinationBlocked(location, movingFolderPaths: host.movingFolderPaths)
    }

    var body: some View {
        List {
            Section {
                ForEach(children, id: \.self) { path in
                    row(for: path)
                }
                if children.isEmpty {
                    Text("このフォルダにはフォルダがありません")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(host.selectedCount)件の移動先を選んでください")
            }
        }
        .navigationTitle(location.map(displayName) ?? L("ホーム"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル", action: host.onCancel)
                    .accessibilityIdentifier("library-move-cancel")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newFolderName = ""
                    showsNewFolderAlert = true
                } label: {
                    Label("新規フォルダ", systemImage: "folder.badge.plus")
                }
                .disabled(isBlocked)
                .accessibilityIdentifier("library-move-new-folder")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                host.onMove(location)
            } label: {
                Text(isCurrentLocation ? "現在地です" : "ここに移動")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCurrentLocation || isBlocked)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("library-move-here")
        }
        .alert("新規フォルダ", isPresented: $showsNewFolderAlert) {
            TextField("フォルダ名", text: $newFolderName)
            Button("キャンセル", role: .cancel) {}
            Button("作成") { host.onCreateFolder(location, newFolderName) }
        }
    }

    @ViewBuilder
    private func row(for path: String) -> some View {
        let blocked = HomeSelectionRules.isMoveDestinationBlocked(path, movingFolderPaths: host.movingFolderPaths)
        if blocked {
            Label(displayName(path), systemImage: "folder.fill")
                .foregroundStyle(.secondary)
                .accessibilityHint(Text("移動中のフォルダの中には移動できません"))
                .accessibilityIdentifier("library-move-folder-\(path)")
        } else {
            NavigationLink(value: path) {
                HStack {
                    Label(displayName(path), systemImage: "folder.fill")
                    if path == host.currentPath {
                        Spacer()
                        Text("現在地")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("library-move-folder-\(path)")
        }
    }

    private func parent(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private func displayName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
