import SwiftData
import XCTest
@testable import studiquo

/// 分割画面の資料選択で、資料が種類ごとに分かれることと、並べ方の保存値の扱いの確認。
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

    func testGroupsAreAlwaysNotePdfDeckInThatOrder() throws {
        let groups = SplitSourceCatalog.groups(notebooks: [], flashcardDecks: [], primaryNotebook: nil)
        XCTAssertEqual(groups.map(\.kind), [.note, .pdf, .deck])
        XCTAssertTrue(groups.allSatisfy { $0.items.isEmpty })
    }

    func testNotesPdfsAndDecksAreSeparatedByKind() throws {
        let context = try makeContext()
        let note = notebook("ノートA", in: context)
        let pdf = notebook("PDF-A", isPDF: true, in: context)
        let deck = FlashcardDeck(title: "暗記A")
        context.insert(deck)

        let groups = SplitSourceCatalog.groups(notebooks: [note, pdf], flashcardDecks: [deck], primaryNotebook: nil)
        XCTAssertEqual(groups[0].items.map(\.title), ["ノートA"])
        XCTAssertEqual(groups[1].items.map(\.title), ["PDF-A"])
        XCTAssertEqual(groups[2].items.map(\.title), ["暗記A"])
    }

    func testTrashedMaterialsAreLeftOut() throws {
        let context = try makeContext()
        let kept = notebook("残す", in: context)
        let trashed = notebook("捨てた", in: context)
        trashed.isTrashed = true
        let trashedDeck = FlashcardDeck(title: "捨てた暗記")
        trashedDeck.isTrashed = true
        context.insert(trashedDeck)

        let groups = SplitSourceCatalog.groups(notebooks: [kept, trashed], flashcardDecks: [trashedDeck], primaryNotebook: nil)
        XCTAssertEqual(groups.flatMap(\.items).map(\.title), ["残す"])
    }

    func testOrderWithinAKindFollowsTheInputOrder() throws {
        let context = try makeContext()
        let b = notebook("B", in: context)
        let a = notebook("A", in: context)
        let groups = SplitSourceCatalog.groups(notebooks: [b, a], flashcardDecks: [], primaryNotebook: nil)
        XCTAssertEqual(groups[0].items.map(\.title), ["B", "A"])
    }

    func testOnlyThePrimaryNotebookIsMarkedAsDisplayedAndStaysListed() throws {
        let context = try makeContext()
        let open = notebook("表示中のノート", in: context)
        let other = notebook("別のノート", in: context)
        let items = SplitSourceCatalog.groups(notebooks: [open, other], flashcardDecks: [], primaryNotebook: open)
            .flatMap(\.items)
        XCTAssertEqual(items.filter(\.isDisplayed).map(\.title), ["表示中のノート"])
        XCTAssertEqual(items.count, 2)
    }

    func testItemIdsAreUnique() throws {
        let context = try makeContext()
        let first = notebook("同名", in: context)
        let second = notebook("同名", in: context)
        let ids = SplitSourceCatalog.groups(notebooks: [first, second], flashcardDecks: [], primaryNotebook: nil)
            .flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testStoredLayoutFallsBackToListWhenUnknown() {
        XCTAssertEqual(SplitSourceLayout(storedValue: "icon"), .icon)
        XCTAssertEqual(SplitSourceLayout(storedValue: "column"), .column)
        XCTAssertEqual(SplitSourceLayout(storedValue: "list"), .list)
        XCTAssertEqual(SplitSourceLayout(storedValue: ""), .list)
        XCTAssertEqual(SplitSourceLayout(storedValue: "grid"), .list)
    }

    func testLayoutButtonsOfferListIconColumnWithHomeScreenSymbols() {
        XCTAssertEqual(SplitSourceLayout.allCases, [.list, .icon, .column])
        XCTAssertEqual(SplitSourceLayout.allCases.map(\.systemImage), ["list.bullet", "square.grid.2x2", "rectangle.split.3x1"])
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

        let groups = SplitSourceCatalog.groups(
            notebooks: [rootNote, subjectPDF, subjectNote], flashcardDecks: [mathDeck], primaryNotebook: nil
        )
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: nil, from: groups).map(\.title), ["ルートのノート"])
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: "科目", from: groups).map(\.title), ["科目のノート", "科目のPDF"])
        XCTAssertEqual(SplitSourceCatalog.items(inFolder: "科目/数学", from: groups).map(\.title), ["数学の暗記"])
        XCTAssertTrue(SplitSourceCatalog.items(inFolder: "なし", from: groups).isEmpty)
    }

    func testItemIdIsThePersistentIdentityNotTheTitle() throws {
        let context = try makeContext()
        let first = notebook("同名", in: context)
        try context.save()
        let before = SplitSourceCatalog.groups(notebooks: [first], flashcardDecks: [], primaryNotebook: nil)[0].items[0].id
        let after = SplitSourceCatalog.groups(notebooks: [first], flashcardDecks: [], primaryNotebook: nil)[0].items[0].id
        XCTAssertEqual(before, after)
        XCTAssertEqual(before, .notebook(first.persistentModelID))
    }
}
