import SwiftData
import XCTest
@testable import studiquo

/// 分割画面の資料選択で、資料の種類ごとの並べ方、フォルダの辿り方と、並べ方の保存値の扱いの確認。
@MainActor
final class SplitSourcePickerTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    private func notebook(_ title: String, isPDF: Bool = false, in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: title)
        let page = NotePage(order: 0, backgroundImageData: isPDF ? Data([0]) : nil)
        page.notebook = notebook
        notebook.addPage(page)
        notebook.refreshLibraryMetadata()
        context.insert(notebook)
        return notebook
    }

    private func items(
        _ notebooks: [Notebook] = [], _ decks: [FlashcardDeck] = [], primary: Notebook? = nil
    ) -> [SplitSourceItem] {
        SplitSourceCatalog.items(notebooks: notebooks, flashcardDecks: decks, primaryNotebook: primary)
    }

    func testNoMaterialsGivesNoItems() {
        XCTAssertTrue(items().isEmpty)
    }

    func testNotesPdfsAndDecksKeepTheirKind() throws {
        let context = try makeContext()
        let note = notebook("ノートA", in: context)
        let pdf = notebook("PDF-A", isPDF: true, in: context)
        let deck = FlashcardDeck(title: "暗記A")
        context.insert(deck)

        let all = items([pdf, note], [deck])
        XCTAssertEqual(all.map(\.title), ["ノートA", "PDF-A", "暗記A"], "notes, then PDFs, then decks")
        XCTAssertEqual(all.map(\.kind), [.note, .pdf, .deck])
    }

    func testTrashedMaterialsAreLeftOut() throws {
        let context = try makeContext()
        let kept = notebook("残す", in: context)
        let trashed = notebook("捨てた", in: context)
        trashed.isTrashed = true
        let trashedDeck = FlashcardDeck(title: "捨てた暗記")
        trashedDeck.isTrashed = true
        context.insert(trashedDeck)

        XCTAssertEqual(items([kept, trashed], [trashedDeck]).map(\.title), ["残す"])
    }

    func testOrderWithinAKindFollowsTheInputOrder() throws {
        let context = try makeContext()
        let b = notebook("B", in: context)
        let a = notebook("A", in: context)
        XCTAssertEqual(items([b, a]).map(\.title), ["B", "A"])
    }

    func testOnlyThePrimaryNotebookIsMarkedAsDisplayedAndStaysListed() throws {
        let context = try makeContext()
        let open = notebook("表示中のノート", in: context)
        let other = notebook("別のノート", in: context)
        let all = items([open, other], primary: open)
        XCTAssertEqual(all.filter(\.isDisplayed).map(\.title), ["表示中のノート"])
        XCTAssertEqual(all.count, 2)
    }

    func testItemIdsAreUnique() throws {
        let context = try makeContext()
        let first = notebook("同名", in: context)
        let second = notebook("同名", in: context)
        XCTAssertEqual(Set(items([first, second]).map(\.id)).count, 2)
    }

    func testStoredLayoutFallsBackToListWhenUnknown() {
        XCTAssertEqual(SplitSourceLayout(storedValue: "icon"), .icon)
        XCTAssertEqual(SplitSourceLayout(storedValue: "column"), .column)
        XCTAssertEqual(SplitSourceLayout(storedValue: "list"), .list)
        XCTAssertEqual(SplitSourceLayout(storedValue: ""), .list)
        XCTAssertEqual(SplitSourceLayout(storedValue: "grid"), .list)
    }

    func testLayoutButtonsOfferListIconColumnWithHomeScreenSymbols() {
        XCTAssertEqual(SplitSourceLayout.allCases, [.list, .icon, .column, .kind])
        XCTAssertEqual(
            SplitSourceLayout.allCases.map(\.systemImage),
            ["list.bullet", "square.grid.2x2", "rectangle.split.3x1", "square.stack.3d.up"]
        )
        XCTAssertEqual(SplitSourceLayout.kind.title, "種類")
        XCTAssertEqual(SplitSourceLayout(storedValue: "kind"), .kind)
    }

    // MARK: フォルダ階層(カラム)

    func testChainHasOneEntryPerOpenColumn() {
        XCTAssertEqual(SplitSourceCatalog.chain(endingAt: nil), [])
        XCTAssertEqual(SplitSourceCatalog.chain(endingAt: ""), [])
        XCTAssertEqual(SplitSourceCatalog.chain(endingAt: "科目"), ["科目"])
        XCTAssertEqual(SplitSourceCatalog.chain(endingAt: "科目/数学/代数"), ["科目", "科目/数学", "科目/数学/代数"])
    }

    func testParentAndDisplayNameOfAPath() {
        XCTAssertNil(SplitSourceCatalog.parentPath(of: "科目"))
        XCTAssertEqual(SplitSourceCatalog.parentPath(of: "科目/数学"), "科目")
        XCTAssertEqual(SplitSourceCatalog.displayName(of: "科目/数学"), "数学")
        XCTAssertEqual(SplitSourceCatalog.displayName(of: "科目"), "科目")
    }

    func testFolderPathsIncludeAncestorsAndFoldersOnlyReferencedByItems() {
        let paths = SplitSourceCatalog.folderPaths(folderPaths: ["科目"], itemPaths: ["", "趣味/音楽", "科目"])
        XCTAssertEqual(paths, ["科目", "趣味", "趣味/音楽"])
        XCTAssertFalse(paths.contains(""))
    }

    func testFolderPathsAreOrderedNaturally() {
        let paths = SplitSourceCatalog.folderPaths(folderPaths: ["第10章", "第2章", "第1章"], itemPaths: [])
        XCTAssertEqual(paths, ["第1章", "第2章", "第10章"])
    }

    func testSubfoldersAreOnlyTheDirectChildren() {
        let paths = ["科目", "科目/数学", "科目/数学/代数", "趣味"]
        XCTAssertEqual(SplitSourceCatalog.subfolders(of: nil, in: paths), ["科目", "趣味"])
        XCTAssertEqual(SplitSourceCatalog.subfolders(of: "科目", in: paths), ["科目/数学"])
        XCTAssertEqual(SplitSourceCatalog.subfolders(of: "科目/数学/代数", in: paths), [])
    }

    func testItemsAreFilteredByFolderAndKeepKindOrder() throws {
        let context = try makeContext()
        let rootNote = notebook("ルートのノート", in: context)
        let subjectPDF = notebook("科目のPDF", isPDF: true, in: context)
        subjectPDF.folderName = "科目"
        let subjectNote = notebook("科目のノート", in: context)
        subjectNote.folderName = "科目"
        let mathDeck = FlashcardDeck(title: "数学の暗記")
        mathDeck.folderName = "科目/数学"
        context.insert(mathDeck)

        let all = items([rootNote, subjectPDF, subjectNote], [mathDeck])
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: nil, from: all).map(\.title), ["ルートのノート"])
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: "科目", from: all).map(\.title), ["科目のノート", "科目のPDF"])
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: "科目/数学", from: all).map(\.title), ["数学の暗記"])
        XCTAssertTrue(SplitSourceCatalog.items(inFolder: "なし", from: all).isEmpty)
        XCTAssertEqual(SplitSourceCatalog.itemCount(inFolderTree: "科目", from: all), 3)
        XCTAssertEqual(SplitSourceCatalog.itemCount(inFolderTree: "科目/数学", from: all), 1)
        XCTAssertEqual(SplitSourceCatalog.itemCount(inFolderTree: "科", from: all), 0, "a prefix of the name is not the folder")
    }

    func testItemIdIsThePersistentIdentityNotTheTitle() throws {
        let context = try makeContext()
        let first = notebook("同名", in: context)
        try context.save()
        let before = items([first])[0].id
        let after = items([first])[0].id
        XCTAssertEqual(before, after)
        XCTAssertEqual(before, .notebook(first.persistentModelID))
    }

    func testTextDocumentsAreOfferedAsTheirOwnKind() throws {
        let context = try makeContext()
        let document = TextDocument(title: "文書A")
        document.folderName = "科目"
        context.insert(document)
        let trashed = TextDocument(title: "捨てた文書")
        trashed.isTrashed = true
        context.insert(trashed)

        let all = SplitSourceCatalog.items(notebooks: [], flashcardDecks: [], textDocuments: [document, trashed], primaryNotebook: nil)
        XCTAssertEqual(all.map(\.title), ["文書A"])
        XCTAssertEqual(all.first?.kind, .document)
        XCTAssertEqual(all.first?.id, .document(document.persistentModelID))
    }

    func testSearchMatchesTitlesIgnoringCaseAndSurroundingSpaces() throws {
        let context = try makeContext()
        let a = notebook("Algebra", in: context)
        let b = notebook("歴史", in: context)
        let all = items([a, b])
        XCTAssertEqual(SplitSourceCatalog.items(all, matchingSearch: " alg ").map(\.title), ["Algebra"])
        XCTAssertEqual(SplitSourceCatalog.items(all, matchingSearch: "歴").map(\.title), ["歴史"])
        XCTAssertEqual(SplitSourceCatalog.items(all, matchingSearch: "  ").count, 2)
        XCTAssertTrue(SplitSourceCatalog.items(all, matchingSearch: "なし").isEmpty)
    }
}
