import XCTest
@testable import studiquo

final class SharedInboxTests: XCTestCase {
    private var sandbox: URL!
    private var inbox: SharedInbox!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        inbox = SharedInbox(root: sandbox.appendingPathComponent("Inbox", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeSource(_ name: String, in folder: String = "src", contents: String = "x") throws -> URL {
        let directory = sandbox.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testEnqueueCopiesFilesAndLeavesOriginalsInPlace() throws {
        let a = try makeSource("a.pdf", contents: "A")
        let result = inbox.enqueue(copying: [a])

        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(try String(contentsOf: result.items[0].url, encoding: .utf8), "A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "the share must not move the student's original")
    }

    func testSameNameFromDifferentFoldersDoesNotOverwrite() throws {
        let first = try makeSource("notes.pdf", in: "one", contents: "1")
        let second = try makeSource("notes.pdf", in: "two", contents: "2")
        let result = inbox.enqueue(copying: [first, second])

        XCTAssertEqual(result.items.map(\.displayName), ["notes.pdf", "notes 2.pdf"])
        XCTAssertEqual(try String(contentsOf: result.items[1].url, encoding: .utf8), "2")
    }

    func testFolderSourceIsReportedAsFailedWithoutAbortingTheRest() throws {
        let good = try makeSource("good.pdf")
        let folder = sandbox.appendingPathComponent("a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = inbox.enqueue(copying: [folder, good])

        XCTAssertEqual(result.items.map(\.displayName), ["good.pdf"])
        XCTAssertEqual(result.failed, [folder])
    }

    func testBatchFolderIsRemovedWhenNothingCouldBeCopied() throws {
        let folder = sandbox.appendingPathComponent("only-a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        inbox.enqueue(copying: [folder])

        XCTAssertTrue(inbox.pendingItems().isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: inbox.root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testPendingItemsAreSortedNaturallyWithinABatch() throws {
        let sources = try ["ch10.pdf", "ch2.pdf", "ch1.pdf"].map { try makeSource($0) }
        inbox.enqueue(copying: sources)

        XCTAssertEqual(inbox.pendingItems().map(\.displayName), ["ch1.pdf", "ch2.pdf", "ch10.pdf"])
    }

    func testOlderBatchComesFirst() throws {
        let older = inbox.enqueue(copying: [try makeSource("z-first.pdf")]).items[0]
        let batch = older.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: batch.path)
        inbox.enqueue(copying: [try makeSource("a-second.pdf")])

        XCTAssertEqual(inbox.pendingItems().map(\.displayName), ["z-first.pdf", "a-second.pdf"])
    }

    func testRemoveDeletesTheFileAndEmptyBatchFolder() throws {
        let a = try makeSource("a.pdf")
        let b = try makeSource("b.pdf")
        let items = inbox.enqueue(copying: [a, b]).items
        let batch = items[0].url.deletingLastPathComponent()

        inbox.remove(items[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.path), "batch stays while a file remains")
        inbox.remove(items[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testMissingInboxFolderMeansNothingPending() {
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }
}

@MainActor
final class SharedImportCoordinatorTests: XCTestCase {
    private var sandbox: URL!
    private var inbox: SharedInbox!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        inbox = SharedInbox(root: sandbox.appendingPathComponent("Inbox", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func drop(_ name: String) throws {
        let url = sandbox.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        inbox.enqueue(copying: [url])
    }

    func testRefreshPresentsThePickerWhenFilesArrive() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        coordinator.refresh()
        XCTAssertFalse(coordinator.isPickingDestination)

        try drop("a.pdf")
        coordinator.refresh()
        XCTAssertTrue(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.pending.count, 1)
    }

    func testCancelledFilesAreKeptButDoNotRePresentTheirPicker() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try drop("a.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()
        XCTAssertFalse(coordinator.isPickingDestination)

        coordinator.refresh() // e.g. the app returning to the foreground
        XCTAssertFalse(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.pending.count, 1, "cancelling must not delete the student's files")

        try drop("b.pdf")
        coordinator.refresh()
        XCTAssertTrue(coordinator.isPickingDestination, "a new arrival asks again")
    }

    func testPresentPickerReopensDismissedFiles() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try drop("a.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()

        coordinator.presentPicker()
        XCTAssertTrue(coordinator.isPickingDestination)
    }

    func testFinishRemovesTheFileFromDiskAndPending() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try drop("a.pdf")
        coordinator.refresh()
        let item = try XCTUnwrap(coordinator.pending.first)

        coordinator.finish(item)
        XCTAssertTrue(coordinator.pending.isEmpty)
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testRefreshIsIgnoredWhileImporting() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try drop("a.pdf")
        coordinator.refresh()
        coordinator.begin(total: 1)
        XCTAssertFalse(coordinator.isPickingDestination)

        try drop("b.pdf")
        coordinator.refresh()
        XCTAssertFalse(coordinator.isPickingDestination, "must not stack a picker over a running import")
        coordinator.end()
        XCTAssertEqual(coordinator.pending.count, 2)
    }
}
