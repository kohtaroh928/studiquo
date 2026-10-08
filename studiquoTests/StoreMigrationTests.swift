import XCTest
import SwiftData
import SQLite3
@testable import studiquo

/// A frozen, minimal copy of an older on-disk shape: the same entities the
/// current schema has, but without the attributes added since (for example the
/// retrieval identity on notebooks and folders). Opening a store written with
/// it through `studiquoSchema` is what an upgrade does on a device that still
/// holds data from the previous version.
private enum LegacyStore {
    @Model final class Notebook {
        var title: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var isFavorite: Bool = false
        init(title: String) { self.title = title }
    }

    @Model final class Folder {
        var name: String = ""
        var createdAt: Date = Date.now
        init(name: String) { self.name = name }
    }

    @Model final class AIChatMessage {
        var text: String = ""
        var createdAt: Date = Date.now
        var roleRawValue: String = "user"
        init(text: String) { self.text = text }
    }

    static var schema: Schema { Schema([Notebook.self, Folder.self, AIChatMessage.self]) }
}

@MainActor
final class StoreMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("Library.store") }

    /// Writes the legacy store, then releases it so the next open is a cold one.
    private func writeLegacyStore(notebooks: Int, folders: Int, messages: Int) throws {
        let configuration = ModelConfiguration(schema: LegacyStore.schema, url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: LegacyStore.schema, configurations: configuration)
        let context = ModelContext(container)
        for index in 0..<notebooks {
            let notebook = LegacyStore.Notebook(title: "ノート\(index)")
            notebook.isFavorite = index % 2 == 0
            context.insert(notebook)
        }
        for index in 0..<folders { context.insert(LegacyStore.Folder(name: "フォルダ\(index)")) }
        for index in 0..<messages { context.insert(LegacyStore.AIChatMessage(text: "質問\(index)")) }
        try context.save()
    }

    /// Column names of the notebook table as stored on disk right now.
    private func notebookColumns() throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "StoreMigrationTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZNOTEBOOK)", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "StoreMigrationTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    private func openCurrentSchema() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: studiquoSchema, configurations: configuration)
    }

    func testStoreWrittenWithAnOlderShapeOpensAndKeepsEveryRecord() throws {
        try writeLegacyStore(notebooks: 5, folders: 3, messages: 4)
        let columnsBefore = try notebookColumns()

        let container = try openCurrentSchema()
        let context = ModelContext(container)
        let columnsAfter = try notebookColumns()
        XCTAssertTrue(columnsBefore.contains("ZTITLE"))
        XCTAssertTrue(columnsAfter.isSuperset(of: columnsBefore))
        XCTAssertGreaterThan(columnsAfter.count, columnsBefore.count,
                             "the fixture must really be an older shape, or this test proves nothing")

        let notebooks = try context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(notebooks.map(\.title), (0..<5).map { "ノート\($0)" })
        XCTAssertEqual(notebooks.filter(\.isFavorite).count, 3, "existing attribute values must survive the upgrade")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIChatMessage>()), 4)
    }

    func testMigratedStoreAcceptsNewRecordsAndSurvivesAReopen() throws {
        try writeLegacyStore(notebooks: 2, folders: 1, messages: 1)
        do {
            let container = try openCurrentSchema()
            let context = ModelContext(container)
            context.insert(Notebook(title: "移行後に作成"))
            try context.save()
        }

        let reopened = try openCurrentSchema()
        let titles = try ModelContext(reopened).fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.title)])).map(\.title)
        XCTAssertEqual(Set(titles), ["ノート0", "ノート1", "移行後に作成"])
    }

    /// The app opens the store behind `StartupStoreLoader`; an upgrade must
    /// reach `.ready` rather than leave the launch screen in `.loading` or
    /// `.delayed`.
    func testUpgradeReachesReadyThroughTheStartupLoaderWithinTheDeadline() async throws {
        try writeLegacyStore(notebooks: 300, folders: 20, messages: 100)
        let url = storeURL
        let ready = expectation(description: "Upgraded store becomes ready")
        var sawDelayed = false
        let loader = StartupStoreLoader<ModelContainer>(timeout: 10) {
            let configuration = ModelConfiguration(schema: studiquoSchema, url: url, cloudKitDatabase: .none)
            return try ModelContainer(for: studiquoSchema, configurations: configuration)
        }
        let subscription = loader.$state.sink { state in
            if case .delayed = state { sawDelayed = true }
            if case .ready = state { ready.fulfill() }
            if case .failed(let message) = state { XCTFail("Upgrade failed: \(message)") }
        }
        defer { subscription.cancel() }

        loader.start()
        await fulfillment(of: [ready], timeout: 30)

        XCTAssertFalse(sawDelayed, "an upgrade of a few hundred notes must not trip the slow-launch notice")
        guard case .ready(let container) = loader.state else { return XCTFail("Not ready") }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Notebook>()), 300)
    }
}
