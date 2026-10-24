import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Explicit local import; selecting files never authorizes a cloud upload.
struct RAGStructuredImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pdfData: Data?
    @State private var manifestData: Data?
    @State private var title = "PDF"
    @State private var choosingPDF = false
    @State private var choosingManifest = false
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Text("元のPDFと、そのPDFから作成した解析結果を選択してください。一致を確認して新しい資料として追加します。ファイルを選ぶだけではクラウドへ送信しません。")
                Button(pdfData == nil ? "元のPDFを選択" : "PDFを選択済み") { choosingPDF = true }
                Button(manifestData == nil ? "解析結果を選択" : "解析結果を選択済み") { choosingManifest = true }
                Text("PDFは100ページまでです。内容を編集すると、解析結果は使用せず現在の本文から検索データを作成します。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("資料として追加") {
                    guard let pdfData, let manifestData else { return }
                    busy = true; failed = false
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdfData, manifestData: manifestData, title: title)
                            context.insert(notebook)
                            do { try context.save() }
                            catch { context.delete(notebook); throw error }
                            dismiss()
                        } catch { failed = true }
                    }
                }.disabled(busy || pdfData == nil || manifestData == nil)
                if busy { ProgressView() }
                if failed { Text("ファイルを確認できませんでした。元のPDFと対応する解析結果、ページ数を確認してください。") }
            }
            .navigationTitle("解析済みPDFを追加")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(busy) } }
            .disabled(busy)
        }
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $choosingPDF, allowedContentTypes: [.pdf]) { result in
            do {
                let url = try result.get()
                pdfData = try read(url, limit: 100 * 1024 * 1024)
                title = url.deletingPathExtension().lastPathComponent
            } catch { pdfData = nil; failed = true }
        }
        .fileImporter(isPresented: $choosingManifest, allowedContentTypes: [.json]) { result in
            do { manifestData = try read(result.get(), limit: 32 * 1024 * 1024) }
            catch { manifestData = nil; failed = true }
        }
        .onDisappear { pdfData = nil; manifestData = nil }
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
