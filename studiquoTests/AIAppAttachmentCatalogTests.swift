import XCTest
@testable import studiquo

/// What the model is shown when a library item is attached to an AIトーク
/// message. The note editor and the home AI screen share this, so a document
/// must read the same wherever it is attached.
final class AIAppAttachmentCatalogTests: XCTestCase {
    private func notebook(
        title: String,
        pdfPages: [String] = [],
        typedPages: [[String]] = [],
        trashed: Bool = false
    ) -> Notebook {
        let notebook = Notebook(title: title)
        notebook.isTrashed = trashed
        for (index, text) in pdfPages.enumerated() {
            let page = NotePage(order: index, backgroundImageData: Data([1]))
            page.recognizedText = text
            page.notebook = notebook
            notebook.addPage(page)
        }
        for (index, texts) in typedPages.enumerated() {
            let page = NotePage(order: index)
            for text in texts { page.addElement(PageElement(kind: .text, text: text)) }
            page.notebook = notebook
            notebook.addPage(page)
        }
        return notebook
    }

    // MARK: Library listing

    func testOptionsListNotesThenDecksThenDocumentsThenSlidesAndSkipTrashedItems() {
        let kept = notebook(title: "ノートA", typedPages: [["本文"]])
        let trashed = notebook(title: "捨てたノート", typedPages: [["本文"]], trashed: true)
        let deck = FlashcardDeck(title: "単語帳")
        let trashedDeck = FlashcardDeck(title: "捨てた単語帳"); trashedDeck.isTrashed = true
        let document = TextDocument(title: "レポート")
        let slides = SlideDeck(title: "発表")

        let options = AIAppAttachmentCatalog.options(
            notebooks: [kept, trashed],
            flashcardDecks: [deck, trashedDeck],
            textDocuments: [document],
            slideDecks: [slides]
        )

        XCTAssertEqual(options.map(\.title), ["ノートA", "単語帳", "レポート", "発表"])
        XCTAssertEqual(options.map(\.attachment.kind), [.notebook, .flashcards, .document, .slideDeck])
        XCTAssertTrue(options[0].id.hasPrefix("notebook:"))
        XCTAssertTrue(options[1].id.hasPrefix("deck:"))
        XCTAssertTrue(options[2].id.hasPrefix("document:"))
        XCTAssertTrue(options[3].id.hasPrefix("slide:"))
        XCTAssertEqual(Set(options.map(\.id)).count, options.count, "選択肢のIDは重複しないこと")
    }

    // MARK: Notebook text

    func testPDFTextIsPreferredOverTypedText() {
        let pdf = notebook(title: "PDF", pdfPages: ["一ページ目", "二ページ目"])
        let option = try! XCTUnwrap(AIAppAttachmentCatalog.notebookAttachmentOption(pdf))
        XCTAssertEqual(option.attachment.contextText, "p.1\n一ページ目\n\np.2\n二ページ目")
    }

    func testANotebookWithoutPDFTextFallsBackToRecognisedAndTypedText() {
        let note = notebook(title: "ノート", typedPages: [["式1", "  "], ["式2"]])
        note.sortedPages[0].recognizedText = "手書きの認識結果"
        let option = try! XCTUnwrap(AIAppAttachmentCatalog.notebookAttachmentOption(note))
        XCTAssertEqual(option.attachment.contextText, "p.1\n手書きの認識結果\n式1\n\np.2\n式2")
    }

    func testAnEmptyNotebookSaysThereIsNoReadableTextYet() {
        let option = try! XCTUnwrap(AIAppAttachmentCatalog.notebookAttachmentOption(notebook(title: "空")))
        XCTAssertEqual(option.attachment.contextText, "この資料には、AIが読める抽出済みテキストがまだありません。")
    }

    func testPDFTextIsCutAtTheLimitAndCanBeLimitedToOnePage() {
        let pdf = notebook(title: "長いPDF", pdfPages: [String(repeating: "あ", count: 50), "二ページ目"])
        let cut = AIAppAttachmentCatalog.readablePDFText(in: pdf, limit: 20)
        XCTAssertEqual(cut.count, 20)
        XCTAssertTrue(cut.hasPrefix("p.1\n"))

        let secondOnly = AIAppAttachmentCatalog.readablePDFText(in: pdf, pageIndex: 1)
        XCTAssertEqual(secondOnly, "p.2\n二ページ目")
    }

    // MARK: Decks and documents

    func testFlashcardDeckIsListedAsNumberedQuestionAndAnswerPairs() {
        let deck = FlashcardDeck(title: "英単語")
        deck.addCard(Flashcard(question: "apple", answer: "りんご", order: 0))
        deck.addCard(Flashcard(question: "pear", answer: "なし", order: 1))
        let option = AIAppAttachmentCatalog.deckAttachmentOption(deck)

        XCTAssertEqual(option.subtitle, "暗記カード 2枚")
        XCTAssertEqual(option.attachment.contextText, "1. Q: apple\n   A: りんご\n\n2. Q: pear\n   A: なし")
    }

    func testEmptyDeckAndEmptyDocumentExplainThemselves() {
        XCTAssertEqual(
            AIAppAttachmentCatalog.deckAttachmentOption(FlashcardDeck(title: "空")).attachment.contextText,
            "この暗記カードにはカードがまだありません。"
        )
        XCTAssertEqual(
            AIAppAttachmentCatalog.documentAttachmentOption(TextDocument(title: "空")).attachment.contextText,
            "この文書には本文がまだありません。"
        )
    }

    func testDocumentUsesItsPlainText() {
        let document = TextDocument(title: "レポート")
        document.plainText = "  序論と本論  "
        XCTAssertEqual(AIAppAttachmentCatalog.documentAttachmentOption(document).attachment.contextText, "序論と本論")
    }

    // MARK: History sidebar

    func testHistorySidebarStartsFoldedAwayInNarrowPanes() {
        XCTAssertFalse(AIChatPane.prefersHistorySidebar(width: 359))
        XCTAssertFalse(AIChatPane.prefersHistorySidebar(width: 520), "浮かぶパネルの既定幅(最大520)では折りたたむ")
        XCTAssertFalse(AIChatPane.prefersHistorySidebar(width: 559))
        XCTAssertTrue(AIChatPane.prefersHistorySidebar(width: 560))
        XCTAssertTrue(AIChatPane.prefersHistorySidebar(width: 605), "横向きの分割ペイン(約605)では表示する")
        XCTAssertTrue(AIChatPane.prefersHistorySidebar(width: 834))
    }
}
