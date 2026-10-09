import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system file picker, placed inside a pane.
///
/// The document browser (`UIDocumentBrowserViewController`) is meant for
/// document-based apps and only showed this app's own folder here. The picker
/// shows everything the Files app does — iCloud Drive, On My iPad, other
/// providers, Downloads. `asCopy: false` hands back the file in place.
struct ExternalFileBrowserRepresentable: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        /// The picker's own close button. Embedded in a pane there is nothing
        /// for it to dismiss, so it closes the pane instead.
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

/// A pane that browses the Files app and shows the chosen file in place.
struct ExternalFilePaneView: View {
    @ObservedObject var session: ExternalFileSession
    /// Closes the whole pane (the picker's own close button asks for this).
    let onClose: () -> Void
    @State private var showsImporter = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                subHeader
                Divider()
                content(width: proxy.size.width)
            }
        }
        .accessibilityIdentifier("external-file-pane")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { session.open(pickedURL: url) }
        }
    }

    private var subHeader: some View {
        HStack(spacing: 8) {
            if session.state != .browsing {
                Button {
                    session.backToBrowser()
                } label: {
                    Label("ファイルを選び直す", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("ファイル選択に戻る")
                .accessibilityIdentifier("external-file-pane-back")
            }
            Group {
                if session.state == .browsing {
                    Text("ファイルを選択")
                } else {
                    // A file name, not a phrase to translate.
                    Text(verbatim: session.fileName)
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
            if session.state == .browsing, !session.recents.isEmpty {
                Menu {
                    ForEach(session.recents) { entry in
                        Button(entry.displayName) { session.open(entry: entry) }
                    }
                } label: {
                    Label("最近開いたファイル", systemImage: "clock")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("最近開いたファイル")
                .accessibilityIdentifier("external-file-pane-recents")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch session.state {
        case .browsing:
            if ExternalFilePanePolicy.usesEmbeddedBrowser(paneWidth: width) {
                ExternalFileBrowserRepresentable(onPick: { session.open(pickedURL: $0) }, onCancel: onClose)
                    .accessibilityIdentifier("external-file-pane-browser")
            } else {
                message(icon: "folder", text: "ファイルアプリから資料を選びます。") {
                    Button("ファイルを選ぶ") { showsImporter = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("external-file-pane-choose")
                }
            }
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("ファイルを読み込み中です…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("external-file-pane-loading")
        case .ready:
            if let url = session.fileURL {
                DocumentPreview(url: url)
                    .id(url)
                    .accessibilityIdentifier("external-file-pane-viewer")
            }
        case .missing:
            message(icon: "questionmark.folder", text: "ファイルが見つかりません。移動または削除された可能性があります。") {
                reselectButton
            }
            .accessibilityIdentifier("external-file-pane-missing")
        case .accessDenied:
            message(icon: "lock", text: "このファイルを開けませんでした。権限が無いか、読み込みに失敗しました。") {
                reselectButton
            }
            .accessibilityIdentifier("external-file-pane-denied")
        }
    }

    private var reselectButton: some View {
        Button("ファイルを選び直す") { session.backToBrowser() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("external-file-pane-reselect")
    }

    private func message<Actions: View>(icon: String, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
