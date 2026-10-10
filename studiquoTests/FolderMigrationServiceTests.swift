import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class FolderMigrationServiceTests: XCTestCase {
    private static let migrationKey = "didMigrateFoldersToHierarchy"

    // Retaining the containers avoids SwiftData teardown racing the app's
    // unrelated CloudKit-backed container in the simulator test host.
    private static var retainedContainers: [ModelContainer] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.migrationKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.migrationKey)
        super.tearDown()
    }

    func testMigratesHierarchyMetadataAndEveryResourceKind() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let flashcards = FlashcardDeck(title: "暗記帳")
        let document = TextDocument(title: "文書")
        notebook.folderName = "授業/数学"
        flashcards.folderName = "授業"
        document.folderName = "資料"
        context.insert(notebook)
        context.insert(flashcards)
        context.insert(document)

        let mathCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAtStorage = try String(
            decoding: JSONEncoder().encode(["授業/数学": mathCreatedAt.timeIntervalSince1970]),
            as: UTF8.self
        )

        await FolderMigrationService.migrateIfNeeded(
            context: context,
            folderNamesStorage: "授業\n授業/数学\n資料",
            folderCreatedAtStorage: createdAtStorage,
            favoriteFolderPathsStorage: "授業/数学\n資料",
            notebooks: [notebook],
            flashcardDecks: [flashcards],
            textDocuments: [document]
        )

        let folders = try context.fetch(FetchDescriptor<Folder>())
        let byPath = Dictionary(uniqueKeysWithValues: folders.map { ($0.legacyPath, $0) })
        XCTAssertEqual(Set(byPath.keys), ["授業", "授業/数学", "資料"])
        XCTAssertTrue(byPath["授業/数学"]?.parent === byPath["授業"])
        XCTAssertEqual(try XCTUnwrap(byPath["授業/数学"]?.createdAt).timeIntervalSince1970,
                       mathCreatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(byPath["授業"]?.isFavorite, false)
        XCTAssertEqual(byPath["授業/数学"]?.isFavorite, true)
        XCTAssertEqual(byPath["資料"]?.isFavorite, true)

        XCTAssertTrue(notebook.folder === byPath["授業/数学"])
        XCTAssertTrue(flashcards.folder === byPath["授業"])
        XCTAssertTrue(document.folder === byPath["資料"])
        XCTAssertEqual(notebook.folderName, "授業/数学", "The legacy fallback must be retained")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.migrationKey))

        // The relationships must survive a save/reload, not merely exist on
        // the in-memory objects passed to the migration.
        let readContext = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<Notebook>()).first).folder?.legacyPath, "授業/数学")
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<FlashcardDeck>()).first).folder?.legacyPath, "授業")
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<TextDocument>()).first).folder?.legacyPath, "資料")
    }

    func testReferencedPathMissingFromFolderListCreatesEveryAncestor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "力学ノート")
        notebook.folderName = "講義/物理/力学"
        context.insert(notebook)

        await migrate(context: context, notebooks: [notebook])

        let paths = try context.fetch(FetchDescriptor<Folder>()).map(\.legacyPath)
        XCTAssertEqual(Set(paths), ["講義", "講義/物理", "講義/物理/力学"])
        XCTAssertEqual(notebook.folder?.legacyPath, "講義/物理/力学")
    }

    func testNoLegacyFoldersMarksMigrationCompleteWithoutCreatingRows() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        await migrate(context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Folder>()).isEmpty)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.migrationKey))
    }

    func testMigrationRunsOnlyOnceAndDoesNotCreateDuplicates() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let first = Notebook(title: "最初")
        first.folderName = "既存"
        context.insert(first)
        await migrate(context: context, notebooks: [first])

        let later = Notebook(title: "後から渡された資料")
        later.folderName = "新規"
        context.insert(later)
        await migrate(
            context: context,
            folderNamesStorage: "既存\n新規",
            notebooks: [first, later]
        )

        let folders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(folders.map(\.legacyPath), ["既存"])
        XCTAssertEqual(first.folder?.legacyPath, "既存")
        XCTAssertNil(later.folder)
    }

    func testMigrationCheckpointsAndFinishesMoreThanOneBatch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebooks = (0..<205).map { index in
            let notebook = Notebook(title: "ノート\(index)")
            notebook.folderName = "大量/移行先"
            context.insert(notebook)
            return notebook
        }

        await migrate(context: context, notebooks: notebooks)

        XCTAssertTrue(notebooks.allSatisfy { $0.folder?.legacyPath == "大量/移行先" })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 205)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Folder>()).map(\.legacyPath)),
                       ["大量", "大量/移行先"])
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.migrationKey))
    }

    private func migrate(
        context: ModelContext,
        folderNamesStorage: String = "",
        folderCreatedAtStorage: String = "",
        favoriteFolderPathsStorage: String = "",
        notebooks: [Notebook] = [],
        flashcardDecks: [FlashcardDeck] = [],
        textDocuments: [TextDocument] = []
    ) async {
        await FolderMigrationService.migrateIfNeeded(
            context: context,
            folderNamesStorage: folderNamesStorage,
            folderCreatedAtStorage: folderCreatedAtStorage,
            favoriteFolderPathsStorage: favoriteFolderPathsStorage,
            notebooks: notebooks,
            flashcardDecks: flashcardDecks,
            textDocuments: textDocuments
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: studiquoSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }
}
