import SwiftUI
import LocalAuthentication

struct ProtectedNotebookView: View {
    @Bindable var notebook: Notebook
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onHome: () -> Void
    @State private var isUnlocked = false
    @State private var message = "認証してノートを開いてください"

    var body: some View {
        Group {
            if !notebook.isLocked || isUnlocked {
                NoteEditorView(
                    notebook: notebook,
                    columnVisibility: $columnVisibility,
                    onHome: onHome
                )
            } else {
                ContentUnavailableView {
                    Label("ロックされたノート", systemImage: "lock.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("ロックを解除", action: authenticate)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            if notebook.isLocked { authenticate() }
        }
        .onChange(of: notebook.persistentModelID) { _, _ in
            isUnlocked = false
            if notebook.isLocked { authenticate() }
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "この端末では本人確認を利用できません"
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "「\(notebook.title)」を開きます") { success, _ in
            DispatchQueue.main.async {
                isUnlocked = success
                if !success { message = "認証できませんでした。もう一度お試しください" }
            }
        }
    }
}
