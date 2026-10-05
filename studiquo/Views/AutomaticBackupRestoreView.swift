import SwiftUI

struct AutomaticBackupRestoreState {
    private(set) var backups: [NotebookBackupService.AutomaticBackup]

    init(load: () -> [NotebookBackupService.AutomaticBackup] = NotebookBackupService.automaticBackups) {
        backups = load()
    }

    mutating func refresh(load: () -> [NotebookBackupService.AutomaticBackup] = NotebookBackupService.automaticBackups) {
        backups = load()
    }

    func restoreURL(for backup: NotebookBackupService.AutomaticBackup) -> URL? {
        backups.contains { $0.id == backup.id } ? backup.url : nil
    }
}

struct AutomaticBackupRestoreView: View {
    let onRestore: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state = AutomaticBackupRestoreState()

    var body: some View {
        NavigationStack {
            List(state.backups) { backup in
                Button {
                    guard let url = state.restoreURL(for: backup) else { return }
                    onRestore(url)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backup.title).foregroundStyle(.primary)
                        Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("自動バックアップ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("更新") { state.refresh() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .overlay {
                if state.backups.isEmpty {
                    ContentUnavailableView("バックアップはまだありません", systemImage: "clock.arrow.circlepath", description: Text("ノートを編集して画面を閉じると自動保存されます"))
                }
            }
        }
    }
}
