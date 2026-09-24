import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class LibraryFolderMoveTests: XCTestCase {
    // Keep in-memory containers alive for the test host's lifetime. On the
    // simulator, SwiftData teardown can otherwise wait indefinitely for the
    // app's unrelated CloudKit store to finish its initial setup.
    private static var retainedContainers: [ModelContainer] = []

    func testEveryResourceKindMovesIntoSiblingFolderAndPersists() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let parent = Folder(name: "親")
        let source = Folder(name: "元", parent: parent)
        let destination = Folder(name: "先", parent: parent)
        let notebook = Notebook(title: "ノート")
        let deck = FlashcardDeck(title: "暗記帳")
        let document = TextDocument(title: "文書")
        let slides = SlideDeck(title: "スライド")
        context.insert(parent)
        context.insert(source)
        context.insert(destination)

        let items: [any HomeItem] = [notebook, deck, document, slides]
        for item in items {
            item.folder = source
            item.folderName = source.legacyPath
        }
        context.insert(notebook)
        context.insert(deck)
        context.insert(document)
        context.insert(slides)
        try context.save()

        for item in items {
            XCTAssertTrue(LibraryFolderMove.canMove(item, into: destination))
            XCTAssertTrue(LibraryFolderMove.move(item, into: destination))
            XCTAssertTrue(item.folder === destination)
            XCTAssertEqual(item.folderName, "親/先")
        }
        try context.save()

        let readContext = ModelContext(container)
        let fetchedNotebook = try XCTUnwrap(readContext.fetch(FetchDescriptor<Notebook>()).first)
        let fetchedDeck = try XCTUnwrap(readContext.fetch(FetchDescriptor<FlashcardDeck>()).first)
        let fetchedDocument = try XCTUnwrap(readContext.fetch(FetchDescriptor<TextDocument>()).first)
        let fetchedSlides = try XCTUnwrap(readContext.fetch(FetchDescriptor<SlideDeck>()).first)
        XCTAssertEqual([fetchedNotebook.folderName, fetchedDeck.folderName,
                        fetchedDocument.folderName, fetchedSlides.folderName],
                       Array(repeating: "親/先", count: 4))
        XCTAssertEqual(fetchedNotebook.folder?.legacyPath, "親/先")
        XCTAssertEqual(fetchedDeck.folder?.legacyPath, "親/先")
        XCTAssertEqual(fetchedDocument.folder?.legacyPath, "親/先")
        XCTAssertEqual(fetchedSlides.folder?.legacyPath, "親/先")
    }

    func testMovesBetweenLevelsButRejectsCurrentFolderAndTrashedItem() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let parent = Folder(name: "親")
        let child = Folder(name: "子", parent: parent)
        let notebook = Notebook(title: "資料")
        context.insert(parent)
        context.insert(child)
        context.insert(notebook)
        notebook.folder = parent
        notebook.folderName = parent.legacyPath
        try context.save()

        XCTAssertFalse(LibraryFolderMove.canMove(notebook, into: parent))
        XCTAssertFalse(LibraryFolderMove.move(notebook, into: parent))
        // Older stores may have a legacy path without the relationship.
        // A drop must repair that mismatch rather than reject the row as
        // already being in the folder.
        notebook.folder = nil
        XCTAssertTrue(LibraryFolderMove.move(notebook, into: parent))
        XCTAssertTrue(notebook.folder === parent)
        XCTAssertTrue(LibraryFolderMove.move(notebook, into: child))
        XCTAssertEqual(notebook.folderName, "親/子")
        XCTAssertFalse(LibraryFolderMove.move(notebook, into: child))
        XCTAssertTrue(LibraryFolderMove.move(notebook, into: parent))
        XCTAssertEqual(notebook.folderName, "親")

        notebook.isTrashed = true
        XCTAssertFalse(LibraryFolderMove.canMove(notebook, into: child))
        XCTAssertFalse(LibraryFolderMove.move(notebook, into: child))
        XCTAssertTrue(notebook.folder === parent)
    }

    func testMovingToRootClearsBothFolderRepresentations() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = Folder(name: "保存先")
        let notebook = Notebook(title: "資料")
        context.insert(folder)
        context.insert(notebook)
        notebook.folder = folder
        notebook.folderName = folder.legacyPath
        try context.save()

        XCTAssertTrue(LibraryFolderMove.canMove(notebook, into: nil))
        XCTAssertTrue(LibraryFolderMove.move(notebook, into: nil))
        XCTAssertNil(notebook.folder)
        XCTAssertEqual(notebook.folderName, "")
        XCTAssertFalse(LibraryFolderMove.canMove(notebook, into: nil))
        try context.save()

        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Notebook>()).first)
        XCTAssertNil(reloaded.folder)
        XCTAssertEqual(reloaded.folderName, "")
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }
}
