import Foundation

enum NotebookBackupService {
    struct Archive: Codable {
        var title: String
        var folderName: String
        var tagsText: String
        var createdAt: Date?
        var pages: [PageArchive]
    }

    struct PageArchive: Codable {
        var drawingData: Data?
        var backgroundImageData: Data?
        var width: Double
        var height: Double
        var template: String
        var bookmark: Bool
        var title: String
        var paperColorHex: String?
        var recognizedText: String
        var flashcardQuestion: String?
        var flashcardAnswer: String?
        var flashcardMastery: Int?
        var flashcardReviewCount: Int?
        var elements: [ElementArchive]
    }

    struct ElementArchive: Codable {
        var kind: String
        var text: String
        var imageData: Data?
        var centerX, centerY, width, height, rotation: Double
        var colorHex: String
        var isLocked: Bool
        var layerIndex: Double
    }

    struct AutomaticBackup: Identifiable {
        let url: URL
        let title: String
        let date: Date
        var id: URL { url }
    }

    private static func makeArchive(_ notebook: Notebook) -> Archive {
        Archive(
            title: notebook.title,
            folderName: notebook.folderName,
            tagsText: notebook.tagsText,
            createdAt: .now,
            pages: notebook.sortedPages.map { page in
                PageArchive(
                    drawingData: page.drawingData,
                    backgroundImageData: page.backgroundImageData,
                    width: page.pageWidth,
                    height: page.pageHeight,
                    template: page.templateRawValue,
                    bookmark: page.isBookmarked,
                    title: page.title,
                    paperColorHex: page.paperColorHex,
                    recognizedText: page.recognizedText,
                    flashcardQuestion: page.flashcardQuestion,
                    flashcardAnswer: page.flashcardAnswer,
                    flashcardMastery: page.flashcardMastery,
                    flashcardReviewCount: page.flashcardReviewCount,
                    elements: page.allElements.map { element in
                        ElementArchive(kind: element.kindRawValue, text: element.text, imageData: element.imageData, centerX: element.centerX, centerY: element.centerY, width: element.width, height: element.height, rotation: element.rotation, colorHex: element.colorHex, isLocked: element.isLocked, layerIndex: element.layerIndex)
                    }
                )
            }
        )
    }

    static func export(_ notebook: Notebook) -> URL? {
        let archive = makeArchive(notebook)
        guard let data = try? JSONEncoder().encode(archive) else { return nil }
        let safeName = notebook.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).gnbackup.json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    static func saveAutomaticBackup(for notebook: Notebook) {
        guard let data = try? JSONEncoder().encode(makeArchive(notebook)) else { return }
        let manager = FileManager.default
        guard let root = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("studiquo/AutoBackups", isDirectory: true) else { return }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        let identifier = String(describing: notebook.persistentModelID).replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = root.appendingPathComponent("\(identifier)-\(stamp).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        let matching = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix(identifier + "-") }
            .sorted { modificationDate($0) > modificationDate($1) } ?? []
        for url in matching.dropFirst(5) { try? manager.removeItem(at: url) }
    }

    static func automaticBackups() -> [AutomaticBackup] {
        let manager = FileManager.default
        guard let root = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("studiquo/AutoBackups", isDirectory: true),
              let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return nil }
            return AutomaticBackup(url: url, title: archive.title, date: archive.createdAt ?? modificationDate(url))
        }
        .sorted { $0.date > $1.date }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func restore(from url: URL) -> Notebook? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return nil }
        let notebook = Notebook(title: archive.title)
        notebook.folderName = archive.folderName
        notebook.tagsText = archive.tagsText
        for (index, storedPage) in archive.pages.enumerated() {
            let page = NotePage(order: index, backgroundImageData: storedPage.backgroundImageData, pageWidth: storedPage.width, pageHeight: storedPage.height)
            page.drawingData = storedPage.drawingData
            page.templateRawValue = storedPage.template
            page.isBookmarked = storedPage.bookmark
            page.title = storedPage.title
            page.paperColorHex = storedPage.paperColorHex ?? "#FFFFFF"
            page.recognizedText = storedPage.recognizedText
            page.flashcardQuestion = storedPage.flashcardQuestion ?? ""
            page.flashcardAnswer = storedPage.flashcardAnswer ?? ""
            page.flashcardMastery = storedPage.flashcardMastery ?? 0
            page.flashcardReviewCount = storedPage.flashcardReviewCount ?? 0
            for storedElement in storedPage.elements {
                guard let kind = PageElementKind(rawValue: storedElement.kind) else { continue }
                let element = PageElement(kind: kind, text: storedElement.text, imageData: storedElement.imageData, centerX: storedElement.centerX, centerY: storedElement.centerY, width: storedElement.width, height: storedElement.height, rotation: storedElement.rotation, colorHex: storedElement.colorHex)
                element.isLocked = storedElement.isLocked
                element.layerIndex = storedElement.layerIndex
                element.page = page
                page.addElement(element)
            }
            page.notebook = notebook
            notebook.addPage(page)
        }
        notebook.refreshLibraryMetadata()
        return notebook.sortedPages.isEmpty ? nil : notebook
    }
}
