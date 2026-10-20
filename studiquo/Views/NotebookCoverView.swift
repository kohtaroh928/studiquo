import SwiftData
import SwiftUI

/// A PDF notebook's first page, fitted into a `size` box — or the usual red
/// PDF symbol while it loads, when the page cannot be decoded, and for a
/// protected notebook (see `NotebookCover.isEligible`).
///
/// Decoding happens off the main thread through `NoteImageCache`, and only
/// once the view appears, so a lazy grid of long PDFs does not decode them all.
struct NotebookCoverView: View {
    let notebook: Notebook
    let size: CGSize

    @Environment(\.modelContext) private var modelContext
    @State private var image: UIImage?
    @State private var loadedNotebook: PersistentIdentifier?

    private struct LoadID: Hashable {
        let notebook: PersistentIdentifier
        let updatedAt: Date
        let isLocked: Bool
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .accessibilityIdentifier("notebook-cover-image-\(notebook.title)")
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: min(size.width, size.height) * 0.5))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("notebook-cover-placeholder-\(notebook.title)")
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: LoadID(notebook: notebook.persistentModelID, updatedAt: notebook.updatedAt, isLocked: notebook.isLocked)) {
            await load()
        }
    }

    private func load() async {
        let id = notebook.persistentModelID
        // A cell reused for another notebook must not show the old cover while
        // the new one loads.
        if loadedNotebook != id {
            image = nil
            loadedNotebook = nil
        }
        // Eligibility is decided here, on the main actor, before anything is read.
        guard NotebookCover.isEligible(notebook) else {
            image = nil
            return
        }
        let container = modelContext.container
        // The file behind the page's image is read on a context of its own, off
        // the main thread, so a screen of long PDFs does not stall scrolling.
        let data = await Task.detached(priority: .userInitiated) {
            NotebookCover.firstPageImageData(ofNotebookWithID: id, in: ModelContext(container))
        }.value
        guard let data else {
            if !Task.isCancelled { image = nil }
            return
        }
        let key = NotebookCover.cacheKey(for: notebook, data: data)
        let loaded = await NoteImageCache.shared.image(for: key, data: data, maximumPixelSize: NotebookCover.pixelSize)
        if !Task.isCancelled {
            image = loaded
            loadedNotebook = loaded == nil ? nil : id
        }
    }
}
