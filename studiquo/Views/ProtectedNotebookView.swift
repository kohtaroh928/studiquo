import SwiftUI

extension Notification.Name {
    /// Carries a `PDFPasswordVerifiedEvent` — posted whenever typing a
    /// notebook's retained PDF password successfully gets past
    /// `NotebookLockGate`, so `ContentView` can offer the same "パスワード
    /// を削除しますか？" sheet it shows right after import. `ContentView`
    /// owns that sheet's state (`pdfRemovalOffer`), but the gate that can
    /// now also trigger it lives in a different view entirely.
    static let studiquoPDFPasswordVerified = Notification.Name("StudiquoPDFPasswordVerified")
}

/// What `NotebookLockGate` hands `ContentView` after a successful PDF
/// password check — everything `PendingRemoval` needs to offer removing
/// that password, without the gate needing to know `PendingRemoval` exists.
struct PDFPasswordVerifiedEvent {
    let notebook: Notebook
    let sourceURL: URL
    let password: String
}

/// No gate of its own: `NoteEditorView`'s primary pane wraps its own content
/// in `NotebookLockGate` (see NoteEditorView.swift), so the toolbar, tab
/// bar, and every other piece of chrome around the pane always renders
/// normally — only the pane's content area itself shows the lock
/// placeholder. Wrapping the *entire* `NoteEditorView` here instead (as
/// this used to do) replaced all of that chrome with the placeholder too,
/// which looked nothing like a normal note screen while gated.
struct ProtectedNotebookView: View {
    @Bindable var notebook: Notebook
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onHome: () -> Void

    var body: some View {
        NoteEditorView(
            notebook: notebook,
            columnVisibility: $columnVisibility,
            onHome: onHome
        )
    }
}

/// Gates any notebook-displaying content behind this notebook's own
/// protections: Face ID/Touch ID when `notebook.isLocked` ("ノートを保護"),
/// and the original PDF's password when `notebook.hasLockedPDFToUnlock` (a
/// password-protected PDF import whose password hasn't been removed yet —
/// see `Notebook.lockedPDFData`). Composed in that order: Face ID first
/// when both apply.
///
/// Used at every point a notebook's content is actually rendered — the
/// top-level detail pane (via `ProtectedNotebookView` above) and the split
/// editor's primary-override/secondary panes in `NoteEditorView.swift` — so
/// switching tabs inside an already-open split can't bypass either gate.
/// Before this existed, `ProtectedNotebookView` only wrapped the top-level
/// pane, so a locked notebook picked into the split's secondary pane (or
/// swapped into the primary pane by a tab/"資料を選ぶ" switch) rendered
/// with no authentication at all.
///
/// Verifying the PDF password here only unlocks *viewing* for this one
/// gate instance (reset the moment a different notebook replaces this one,
/// or the view is torn down) — it never touches `notebook.lockedPDFData`.
/// Only the library long-press "PDFのパスワードを削除" action removes that
/// permanently.
struct NotebookLockGate<Content: View>: View {
    @Bindable var notebook: Notebook
    @ViewBuilder var content: () -> Content

    @State private var isFaceIDUnlocked = false
    @State private var isPDFPasswordVerified = false
    @State private var pdfPasswordEntry = ""
    @State private var pdfPasswordError: String?
    @State private var isShowingPDFPasswordPrompt = false
    @State private var faceIDMessage = "認証してノートを開いてください"

    private var needsFaceID: Bool { notebook.isLocked && !isFaceIDUnlocked }
    private var needsPDFPassword: Bool { notebook.hasLockedPDFToUnlock && !isPDFPasswordVerified }
    private var isGated: Bool { needsFaceID || needsPDFPassword }

    var body: some View {
        Group {
            if isGated {
                lockPlaceholder
            } else {
                content()
            }
        }
        .onAppear { requestUnlockIfNeeded() }
        .onChange(of: notebook.persistentModelID) { _, _ in
            isFaceIDUnlocked = false
            isPDFPasswordVerified = false
            requestUnlockIfNeeded()
        }
        .alert("PDFのパスワード", isPresented: $isShowingPDFPasswordPrompt) {
            SecureField("パスワード", text: $pdfPasswordEntry)
            Button("OK", action: verifyPDFPassword)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(pdfPasswordError ?? "このノートの元のPDFにはパスワードがかかっています。開くパスワードを入力してください。")
        }
    }

    private var lockPlaceholder: some View {
        ContentUnavailableView {
            Label(needsFaceID ? "ロックされたノート" : "パスワードが必要です", systemImage: "lock.fill")
        } description: {
            Text(needsFaceID ? faceIDMessage : "このノートの元のPDFを開くパスワードを入力してください。")
        } actions: {
            Button(needsFaceID ? "ロックを解除" : "パスワードを入力") {
                requestUnlockIfNeeded()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func requestUnlockIfNeeded() {
        if needsFaceID {
            authenticateFaceID()
        } else if needsPDFPassword {
            pdfPasswordEntry = ""
            pdfPasswordError = nil
            isShowingPDFPasswordPrompt = true
        }
    }

    private func authenticateFaceID() {
        Task {
            // The content itself is sealed at rest whenever this notebook
            // isn't actively being viewed (see NotebookEncryptionService) —
            // Face ID alone only proves who is asking; it still needs
            // decrypting before there's anything for `content()` to show.
            let success = await DeviceAuthentication.authenticate(reason: "「\(notebook.title)」を開きます")
            let decrypted = success && NotebookEncryptionService.unlock(notebook)
            isFaceIDUnlocked = decrypted
            if !success {
                faceIDMessage = "認証できませんでした。もう一度お試しください"
            } else if !decrypted {
                faceIDMessage = "ノートの内容を復号できませんでした"
            } else {
                // Face ID cleared — chain straight into the PDF-password
                // prompt if this notebook also needs that, rather than
                // leaving the student looking at an unlocked-but-still-
                // gated placeholder until they tap again.
                requestUnlockIfNeeded()
            }
        }
    }

    private func verifyPDFPassword() {
        guard let data = notebook.lockedPDFData else {
            isPDFPasswordVerified = true
            return
        }
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            let sourceURL = tempFolder.appendingPathComponent("\(notebook.title).pdf")
            try data.write(to: sourceURL)
            _ = try PDFPasswordService.unlock(sourceURL, password: pdfPasswordEntry)
            isPDFPasswordVerified = true
            NotificationCenter.default.post(
                name: .studiquoPDFPasswordVerified,
                object: PDFPasswordVerifiedEvent(notebook: notebook, sourceURL: sourceURL, password: pdfPasswordEntry)
            )
        } catch {
            pdfPasswordError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isShowingPDFPasswordPrompt = true
        }
    }
}
