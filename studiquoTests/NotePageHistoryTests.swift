import SwiftData
import XCTest
@testable import studiquo

/// ページの追加・削除が「元に戻す／やり直す」に対応していることの確認。
/// `NoteActionHistory`はシングルトンなので、各テストは自分が積んだ履歴だけを
/// すぐに取り出して検証する。
@MainActor
final class NotePageHistoryTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeNotebook(pageCount: Int) throws -> (Notebook, ModelContext) {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        context.insert(notebook)
        for index in 0..<pageCount {
            let page = NotePage(order: index)
            page.title = "p\(index)"
            page.notebook = notebook
            if !(notebook.pages ?? []).contains(where: { $0 === page }) { notebook.addPage(page) }
            context.insert(page)
        }
        return (notebook, context)
    }

    private func titles(_ notebook: Notebook) -> [String] { notebook.sortedPages.map(\.title) }
    private func orders(_ notebook: Notebook) -> [Int] { notebook.sortedPages.map(\.order) }

    private func appendPage(to notebook: Notebook, context: ModelContext, title: String) -> NotePage {
        let page = NotePage(order: notebook.sortedPages.count)
        page.title = title
        page.notebook = notebook
        if !(notebook.pages ?? []).contains(where: { $0 === page }) { notebook.addPage(page) }
        context.insert(page)
        return page
    }

    func testUndoingAPageAdditionRemovesItAndRedoBringsItBack() throws {
        let (notebook, context) = try makeNotebook(pageCount: 2)
        let added = appendPage(to: notebook, context: context, title: "new")
        NotePageHistory.recordAddition(of: [added], in: notebook, context: context)
        XCTAssertEqual(titles(notebook), ["p0", "p1", "new"])

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p1"], "追加直後の前戻りで、追加したページが消える必要があります。")

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p1", "new"])
        XCTAssertEqual(orders(notebook), [0, 1, 2])
    }

    func testUndoingAPageDeletionRestoresItAtItsOldPosition() throws {
        let (notebook, context) = try makeNotebook(pageCount: 4)
        let doomed = notebook.sortedPages[1]
        NotePageHistory.recordRemoval(of: [doomed], in: notebook, context: context)
        notebook.pages?.removeAll { $0 === doomed }
        doomed.notebook = nil
        context.delete(doomed)
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }
        XCTAssertEqual(titles(notebook), ["p0", "p2", "p3"])

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p1", "p2", "p3"], "削除したページが元の位置に戻る必要があります。")
        XCTAssertEqual(orders(notebook), [0, 1, 2, 3])

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p2", "p3"])
        XCTAssertEqual(orders(notebook), [0, 1, 2])
    }

    func testMultiPageDeletionIsOneUndoStep() throws {
        let (notebook, context) = try makeNotebook(pageCount: 5)
        let doomed = [notebook.sortedPages[1], notebook.sortedPages[3]]
        NotePageHistory.recordRemoval(of: doomed, in: notebook, context: context)
        notebook.pages?.removeAll { page in doomed.contains { $0 === page } }
        doomed.forEach { $0.notebook = nil; context.delete($0) }
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }
        XCTAssertEqual(titles(notebook), ["p0", "p2", "p4"])

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p1", "p2", "p3", "p4"])
        XCTAssertEqual(orders(notebook), [0, 1, 2, 3, 4])
    }

    func testUndoingAPrependedPageRenumbersTheRest() throws {
        let (notebook, context) = try makeNotebook(pageCount: 2)
        for page in notebook.sortedPages { page.order += 1 }
        let top = NotePage(order: 0)
        top.title = "top"
        top.notebook = notebook
        if !(notebook.pages ?? []).contains(where: { $0 === top }) { notebook.addPage(top) }
        context.insert(top)
        NotePageHistory.recordAddition(of: [top], in: notebook, context: context)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "p1"])
        XCTAssertEqual(orders(notebook), [0, 1])

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["top", "p0", "p1"])
        XCTAssertEqual(orders(notebook), [0, 1, 2])
    }

    func testContentDrawnOnAnAddedPageSurvivesUndoAndRedo() throws {
        let (notebook, context) = try makeNotebook(pageCount: 1)
        let added = appendPage(to: notebook, context: context, title: "new")
        NotePageHistory.recordAddition(of: [added], in: notebook, context: context)
        added.recognizedText = "あとから書いた"

        NoteActionHistory.shared.undo(requestID: UUID())
        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(notebook.sortedPages.last?.recognizedText, "あとから書いた")
    }

    func testRestoredPageKeepsItsElementsOnceAndItsFlags() throws {
        let (notebook, context) = try makeNotebook(pageCount: 2)
        let doomed = notebook.sortedPages[0]
        doomed.isBookmarked = true
        let element = PageElement(kind: .text, text: "メモ")
        element.page = doomed
        if !(doomed.elements ?? []).contains(where: { $0 === element }) { doomed.addElement(element) }
        context.insert(element)

        NotePageHistory.recordRemoval(of: [doomed], in: notebook, context: context)
        notebook.pages?.removeAll { $0 === doomed }
        doomed.notebook = nil
        context.delete(doomed)
        for (order, page) in notebook.sortedPages.enumerated() { page.order = order }

        NoteActionHistory.shared.undo(requestID: UUID())
        let restored = try XCTUnwrap(notebook.sortedPages.first)
        XCTAssertEqual(restored.title, "p0")
        XCTAssertTrue(restored.isBookmarked)
        XCTAssertEqual(restored.elements?.count, 1, "要素が二重登録されてはいけません。")
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotePage>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PageElement>()).count, 1)
    }

    func testDuplicatedPagesUndoAndRedoAsOneStep() throws {
        let (notebook, context) = try makeNotebook(pageCount: 1)
        let a = appendPage(to: notebook, context: context, title: "a")
        let b = appendPage(to: notebook, context: context, title: "b")
        NotePageHistory.recordAddition(of: [a, b], in: notebook, context: context)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotePage>()).count, 1)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(titles(notebook), ["p0", "a", "b"])
    }
}
