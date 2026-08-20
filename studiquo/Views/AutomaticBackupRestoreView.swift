import SwiftUI

struct AutomaticBackupRestoreView: View {
    let onRestore: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backups = NotebookBackupService.automaticBackups()

    var body: some View {
        NavigationStack {
            List(backups) { backup in
                Button {
                    onRestore(backup.url)
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
                    Button("更新") { backups = NotebookBackupService.automaticBackups() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .overlay {
                if backups.isEmpty {
                    ContentUnavailableView("バックアップはまだありません", systemImage: "clock.arrow.circlepath", description: Text("ノートを編集して画面を閉じると自動保存されます"))
                }
            }
        }
    }
}
