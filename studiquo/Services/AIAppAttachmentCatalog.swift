import Foundation

/// One library item the student can attach to an AIトーク message, with the
/// text the model is given in its place.
struct AppAttachmentOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let attachment: AIChatAttachment
}

/// Builds what the model is shown for notebooks, flashcard decks, documents
/// and slide decks. Shared by the note editor's chat and the home AI screen,
/// so a document reads the same wherever it is attached.
enum AIAppAttachmentCatalog {
    static func readablePDFText(in notebook: Notebook, pageIndex: Int? = nil, limit: Int = 24_000) -> String {
        let pages = notebook.sortedPages
        var remaining = limit
        var chunks: [String] = []
        for (index, page) in pages.enumerated() {
            if let pageIndex, index != pageIndex { continue }
            guard page.backgroundImageData != nil else { continue }
            let text = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let heading = "p.\(index + 1)"
            let full = "\(heading)\n\(text)"
            guard remaining > 0 else { break }
            if full.count <= remaining {
                chunks.append(full)
                remaining -= full.count
            } else {
                chunks.append(String(full.prefix(remaining)))
                break
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    static func readableNotebookText(in notebook: Notebook, limit: Int = 24_000) -> String {
        var remaining = limit
        var chunks: [String] = []
        for (index, page) in notebook.sortedPages.enumerated() {
            guard remaining > 0 else { break }
            var parts: [String] = []
            let recognized = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recognized.isEmpty { parts.append(recognized) }
            let typed = page.allElements
                .filter { $0.kind == .text }
                .map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            parts.append(contentsOf: typed)
            let text = parts.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            let full = "p.\(index + 1)\n\(text)"
            if full.count <= remaining {
                chunks.append(full)
                remaining -= full.count
            } else {
                chunks.append(String(full.prefix(remaining)))
                break
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    /// Everything in the library that can be attached to a message, trashed
    /// items excluded.
    static func options(
        notebooks: [Notebook],
        flashcardDecks: [FlashcardDeck],
        textDocuments: [TextDocument],
        slideDecks: [SlideDeck]
    ) -> [AppAttachmentOption] {
        let noteOptions = notebooks
            .filter { !$0.isTrashed }
            .compactMap { notebookAttachmentOption($0) }
        let deckOptions = flashcardDecks
            .filter { !$0.isTrashed }
            .map { deckAttachmentOption($0) }
        let documentOptions = textDocuments
            .filter { !$0.isTrashed }
            .map { documentAttachmentOption($0) }
        let slideOptions = slideDecks
            .filter { !$0.isTrashed }
            .map { slideDeckAttachmentOption($0) }
        return noteOptions + deckOptions + documentOptions + slideOptions
    }

    static func notebookAttachmentOption(_ notebook: Notebook) -> AppAttachmentOption? {
        let pdfText = readablePDFText(in: notebook)
        let noteText = pdfText.isEmpty ? readableNotebookText(in: notebook) : pdfText
        let contextText = noteText.isEmpty
            ? L("この資料には、AIが読める抽出済みテキストがまだありません。")
            : noteText
        let attachment = AIChatAttachment(
            name: notebook.title,
            path: "",
            kind: .notebook,
            sourceID: "notebook:\(String(describing: notebook.persistentModelID))",
            contextText: contextText
        )
        return AppAttachmentOption(
            id: "notebook:\(String(describing: notebook.persistentModelID))",
            title: notebook.title,
            subtitle: notebook.containsPDF ? L("PDF") : L("ノート"),
            icon: notebook.containsPDF ? "doc.richtext" : "note.text",
            attachment: attachment
        )
    }

    static func deckAttachmentOption(_ deck: FlashcardDeck) -> AppAttachmentOption {
        let lines = deck.sortedCards.enumerated().map { index, card in
            """
            \(index + 1). Q: \(card.question)
               A: \(card.answer)
            """
        }
        let contextText = lines.isEmpty
            ? L("この暗記カードにはカードがまだありません。")
            : lines.joined(separator: "\n\n")
        return AppAttachmentOption(
            id: "deck:\(String(describing: deck.persistentModelID))",
            title: deck.title,
            subtitle: L("暗記カード \(deck.sortedCards.count)枚"),
            icon: "rectangle.on.rectangle.angled",
            attachment: AIChatAttachment(
                name: deck.title,
                path: "",
                kind: .flashcards,
                sourceID: "deck:\(String(describing: deck.persistentModelID))",
                contextText: contextText
            )
        )
    }

    static func documentAttachmentOption(_ document: TextDocument) -> AppAttachmentOption {
        let text = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextText = text.isEmpty ? L("この文書には本文がまだありません。") : text
        return AppAttachmentOption(
            id: "document:\(String(describing: document.persistentModelID))",
            title: document.title,
            subtitle: L("文書"),
            icon: "doc.text",
            attachment: AIChatAttachment(
                name: document.title,
                path: "",
                kind: .document,
                sourceID: "document:\(String(describing: document.persistentModelID))",
                contextText: contextText
            )
        )
    }

    static func slideDeckAttachmentOption(_ deck: SlideDeck) -> AppAttachmentOption {
        let slides = deck.sortedSlides.enumerated().map { index, slide in
            var parts = ["スライド \(index + 1)"]
            if !slide.titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("タイトル: \(slide.titleText)")
            }
            if !slide.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("本文: \(slide.bodyText)")
            }
            if !slide.secondaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("補足: \(slide.secondaryText)")
            }
            if !slide.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("発表ノート: \(slide.notes)")
            }
            return parts.joined(separator: "\n")
        }
        let contextText = slides.isEmpty ? L("このスライドには内容がまだありません。") : slides.joined(separator: "\n\n")
        return AppAttachmentOption(
            id: "slide:\(String(describing: deck.persistentModelID))",
            title: deck.title,
            subtitle: L("スライド \(deck.sortedSlides.count)枚"),
            icon: "rectangle.on.rectangle",
            attachment: AIChatAttachment(
                name: deck.title,
                path: "",
                kind: .slideDeck,
                sourceID: "slide:\(String(describing: deck.persistentModelID))",
                contextText: contextText
            )
        )
    }
}
