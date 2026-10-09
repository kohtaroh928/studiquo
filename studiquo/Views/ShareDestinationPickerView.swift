import SwiftUI
import SwiftData

/// Shown when files arrive from outside (Files app share sheet, "Open in…"):
/// the student walks the folder tree, optionally makes a new folder on the
/// spot, and confirms where the files should be imported.
///
/// Creating a folder is delegated to `onCreateFolder` because the library
/// keeps a parallel legacy path list that only `ContentView` maintains.
struct ShareDestinationPickerView: View {
    let itemCount: Int
    let onCreateFolder: (_ parent: Folder?, _ name: String) -> Folder?
    let onConfirm: (_ destination: Folder?) -> Void
    let onCancel: () -> Void

    @Query private var allFolders: [Folder]
    @State private var current: Folder?
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    private var children: [Folder] {
        allFolders
            .filter { $0.parent?.persistentModelID == current?.persistentModelID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var currentTitle: String {
        current?.pathComponents.joined(separator: " / ") ?? L("ライブラリ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(currentTitle, systemImage: current == nil ? "books.vertical" : "folder.fill")
                        .font(.headline)
                        .accessibilityIdentifier("share-destination-current")
                    if let current {
                        Button {
                            self.current = current.parent
                        } label: {
                            Label("上の階層へ", systemImage: "chevron.backward")
                        }
                    }
                } footer: {
                    Text("\(itemCount)件のファイルを、ここに取り込みます。")
                }

                Section("フォルダ") {
                    if children.isEmpty {
                        Text("このフォルダにフォルダはありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(children) { folder in
                        Button {
                            current = folder
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier("share-destination-folder-\(folder.name)")
                    }
                }
            }
            .navigationTitle("保存先を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        isNamingFolder = true
                    } label: {
                        Label("新しいフォルダ", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("share-destination-new-folder")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm(current)
                } label: {
                    Text("ここに取り込む(\(itemCount)件)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("share-destination-confirm")
            }
            .alert("新しいフォルダ", isPresented: $isNamingFolder) {
                TextField("フォルダ名", text: $newFolderName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") { createFolder() }
            } message: {
                Text("「\(currentTitle)」の中に作成します。")
            }
        }
        .interactiveDismissDisabled()
    }

    /// The new folder becomes the selected destination straight away, so
    /// "make a folder for this course, put the files in it" is two taps.
    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let created = onCreateFolder(current, name) else { return }
        current = created
    }
}

/// What a shared import did, shown once it finishes if anything needs
/// the student's attention.
struct SharedImportSummary: Equatable {
    var imported: Int
    /// Formats the library cannot import; these were dropped.
    var unsupported: [String]
    /// Files that could not be imported this time (e.g. over the cloud sync
    /// limit). They are kept and can be retried.
    var held: [String]

    var needsAttention: Bool { !unsupported.isEmpty || !held.isEmpty }

    var message: String {
        var lines = [L("\(imported)件を取り込みました。")]
        if !held.isEmpty {
            lines.append(L("\(held.count)件は取り込めませんでした(クラウド同期の容量上限など)。あとから「再試行」できます。"))
            lines.append(Self.names(held))
        }
        if !unsupported.isEmpty {
            lines.append(L("対応していない形式のため、取り込みませんでした。"))
            lines.append(Self.names(unsupported))
        }
        return lines.joined(separator: "\n")
    }

    private static func names(_ list: [String]) -> String {
        let shown = list.prefix(5).joined(separator: "\n")
        return list.count > 5 ? shown + "\n" + L("ほか\(list.count - 5)件") : shown
    }
}

/// Wires the picker sheet, the running-import progress card, the held-files
/// banner and the result notice onto `ContentView` in one modifier, keeping
/// that view's already-long body chain from growing.
struct SharedImportHost: ViewModifier {
    @ObservedObject var coordinator: SharedImportCoordinator
    @Binding var summary: SharedImportSummary?
    let onCreateFolder: (_ parent: Folder?, _ name: String) -> Folder?
    let onImport: (_ destination: Folder?) -> Void

    @State private var confirmingDiscard = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.isPickingDestination) {
                ShareDestinationPickerView(
                    itemCount: coordinator.pickerItems.count,
                    onCreateFolder: onCreateFolder,
                    onConfirm: onImport,
                    onCancel: coordinator.dismissPicker
                )
                .presentationDetents([.large])
            }
            .overlay(alignment: .top) { statusCard }
            .animation(.easeInOut, value: coordinator.progress)
            .animation(.easeInOut, value: coordinator.heldItems.count)
            .alert("取り込み結果", isPresented: Binding(
                get: { summary?.needsAttention == true },
                set: { if !$0 { summary = nil } }
            )) {
                Button("OK", role: .cancel) { summary = nil }
            } message: {
                Text(summary?.message ?? "")
            }
            .confirmationDialog(
                "取り込めなかったファイルを破棄しますか?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("\(coordinator.heldItems.count)件を破棄", role: .destructive) { coordinator.discardHeld() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("元のファイルは、ファイルアプリや写真に残ります。")
            }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let progress = coordinator.progress {
            VStack(alignment: .leading, spacing: 8) {
                Text("取り込み中 \(min(progress.completed + 1, progress.total))/\(progress.total)")
                    .font(.headline)
                ProgressView(value: progress.fraction)
                Text(progress.pageTotal > 1
                     ? "\(progress.currentName)(\(progress.pageDone)/\(progress.pageTotal)ページ)"
                     : progress.currentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if !coordinator.heldItems.isEmpty && !coordinator.isPickingDestination {
            HStack(spacing: 12) {
                Label("取り込めなかったファイルが\(coordinator.heldItems.count)件あります", systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                Button("再試行", action: coordinator.presentHeldPicker)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shared-import-retry")
                Button("破棄", role: .destructive) { confirmingDiscard = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shared-import-discard")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
