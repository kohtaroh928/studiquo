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

/// Wires the picker sheet, the running-import progress card, the "choose
/// later" banner and the skipped-files notice onto `ContentView` in one
/// modifier, keeping that view's already-long body chain from growing.
struct SharedImportHost: ViewModifier {
    @ObservedObject var coordinator: SharedImportCoordinator
    @Binding var skippedNames: [String]
    let onCreateFolder: (_ parent: Folder?, _ name: String) -> Folder?
    let onImport: (_ destination: Folder?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $coordinator.isPickingDestination) {
                ShareDestinationPickerView(
                    itemCount: coordinator.pending.count,
                    onCreateFolder: onCreateFolder,
                    onConfirm: onImport,
                    onCancel: coordinator.dismissPicker
                )
                .presentationDetents([.large])
            }
            .overlay(alignment: .top) { statusCard }
            .animation(.easeInOut, value: coordinator.progress)
            .animation(.easeInOut, value: coordinator.pending.count)
            .alert("取り込めなかったファイル", isPresented: Binding(
                get: { !skippedNames.isEmpty },
                set: { if !$0 { skippedNames = [] } }
            )) {
                Button("OK", role: .cancel) { skippedNames = [] }
            } message: {
                Text("対応していない形式のため、取り込みませんでした。\n" + skippedNames.joined(separator: "\n"))
            }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let progress = coordinator.progress {
            VStack(alignment: .leading, spacing: 8) {
                Text("取り込み中 \(min(progress.completed + 1, progress.total))/\(progress.total)")
                    .font(.headline)
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text(progress.currentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if !coordinator.pending.isEmpty && !coordinator.isPickingDestination {
            Button(action: coordinator.presentPicker) {
                Label("保存先を選んでいないファイルが\(coordinator.pending.count)件あります", systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("shared-import-pending-banner")
        }
    }
}
