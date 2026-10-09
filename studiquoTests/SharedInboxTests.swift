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

    func testBatchAPIKeepsAllFilesOfOneShareTogether() throws {
        let batch = try XCTUnwrap(inbox.makeBatch())
        let a = try XCTUnwrap(inbox.add(try makeSource("a.pdf"), to: batch))
        let b = try XCTUnwrap(inbox.add(try makeSource("a.pdf", in: "other"), to: batch))

        XCTAssertEqual(a.url.deletingLastPathComponent(), batch.folder)
        XCTAssertEqual(b.displayName, "a 2.pdf")
        XCTAssertEqual(inbox.pendingItems().count, 2)
    }

    func testAddingAFolderToABatchFailsAndEmptyBatchIsDiscarded() throws {
        let batch = try XCTUnwrap(inbox.makeBatch())
        let folder = sandbox.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertNil(inbox.add(folder, to: batch))
        inbox.discardIfEmpty(batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.folder.path))
    }

    func testDiscardIfEmptyKeepsABatchThatHoldsFiles() throws {
        let batch = try XCTUnwrap(inbox.makeBatch())
        _ = inbox.add(try makeSource("keep.pdf"), to: batch)
        inbox.discardIfEmpty(batch)
        XCTAssertEqual(inbox.pendingItems().map(\.displayName), ["keep.pdf"])
    }

    func testMissingInboxFolderMeansNothingPending() {
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    // MARK: Held batches

    func testHeldBatchIsFlaggedAndFreshBatchIsNot() throws {
        inbox.enqueue(copying: [try makeSource("a.pdf")])
        inbox.enqueue(copying: [try makeSource("b.pdf", in: "other")])
        let batches = inbox.pendingBatches()
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { !$0.isHeld })

        inbox.hold(batches[0])
        let after = inbox.pendingBatches()
        XCTAssertEqual(after.filter(\.isHeld).count, 1)
        XCTAssertEqual(after.filter(\.isHeld).first?.items.map(\.displayName).count, 1)
    }

    func testHoldMarkerIsNotListedAsAFileAndSurvivesRemovalOfLastFile() throws {
        let item = inbox.enqueue(copying: [try makeSource("a.pdf")]).items[0]
        inbox.hold(inbox.pendingBatches()[0])
        XCTAssertEqual(inbox.pendingItems().map(\.displayName), ["a.pdf"])

        inbox.remove(item)
        XCTAssertTrue(inbox.pendingBatches().isEmpty, "removing the last file takes the whole batch folder, marker included")
    }

    func testReleaseMakesAHeldBatchFreshAgain() throws {
        inbox.enqueue(copying: [try makeSource("a.pdf")])
        let batch = inbox.pendingBatches()[0]
        inbox.hold(batch)
        inbox.release(inbox.pendingBatches()[0])
        XCTAssertFalse(inbox.pendingBatches()[0].isHeld)
    }

    func testDiscardHeldOlderThanOnlyRemovesOldHeldBatches() throws {
        inbox.enqueue(copying: [try makeSource("old.pdf")])
        inbox.enqueue(copying: [try makeSource("recent.pdf", in: "r")])
        inbox.enqueue(copying: [try makeSource("fresh.pdf", in: "f")])
        let batches = inbox.pendingBatches()
        let now = Date()
        inbox.hold(batches[0], at: now.addingTimeInterval(-10 * 86_400))
        inbox.hold(batches[1], at: now.addingTimeInterval(-1 * 86_400))

        inbox.discardHeld(olderThan: now.addingTimeInterval(-7 * 86_400))

        XCTAssertEqual(Set(inbox.pendingItems().map(\.displayName)), ["recent.pdf", "fresh.pdf"])
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

    /// One "share": a new batch holding a file of this name.
    private func share(_ name: String) throws {
        let folder = sandbox.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        inbox.enqueue(copying: [url])
    }

    func testRefreshPresentsThePickerWhenFilesArrive() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        coordinator.refresh()
        XCTAssertFalse(coordinator.isPickingDestination)

        try share("a.pdf")
        coordinator.refresh()
        XCTAssertTrue(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.pickerItems.map(\.displayName), ["a.pdf"])
    }

    func testCancelHoldsTheFilesAndAnewShareDoesNotPickThemUp() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("old.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()
        XCTAssertFalse(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["old.pdf"], "cancelling must not delete the student's files")

        coordinator.refresh() // returning to the foreground
        XCTAssertFalse(coordinator.isPickingDestination)

        try share("new.pdf")
        coordinator.refresh()
        XCTAssertTrue(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.pickerItems.map(\.displayName), ["new.pdf"],
                       "a new share must import only itself, never earlier leftovers")
        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["old.pdf"])
    }

    func testFilesLeftByAFailedImportAreHeldNotMixedIntoTheNextShare() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("big.pdf")
        try share("small.pdf")
        coordinator.refresh()
        let attempted = coordinator.pickerItems
        coordinator.begin(total: attempted.count)
        // small.pdf imports, big.pdf does not fit
        coordinator.finish(attempted.first { $0.displayName == "small.pdf" }!)
        coordinator.end(attempted: attempted.filter { $0.displayName == "big.pdf" })

        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["big.pdf"])
        XCTAssertTrue(coordinator.freshBatches.isEmpty)

        try share("one-more.pdf")
        coordinator.refresh()
        XCTAssertEqual(coordinator.pickerItems.map(\.displayName), ["one-more.pdf"])
    }

    func testRetryOffersOnlyTheHeldFiles() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("held.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()
        try share("fresh.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()
        XCTAssertEqual(Set(coordinator.heldItems.map(\.displayName)), ["held.pdf", "fresh.pdf"])

        coordinator.presentHeldPicker()
        XCTAssertTrue(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.pickerSource, .held)
        XCTAssertEqual(Set(coordinator.pickerItems.map(\.displayName)), ["held.pdf", "fresh.pdf"])
    }

    func testCancellingTheRetryPickerKeepsFilesHeld() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("a.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()
        coordinator.presentHeldPicker()
        coordinator.dismissPicker()

        XCTAssertFalse(coordinator.isPickingDestination)
        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["a.pdf"])
    }

    func testDiscardHeldDeletesFromDisk() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("a.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()

        coordinator.discardHeld()
        XCTAssertTrue(coordinator.heldItems.isEmpty)
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testHeldFilesExpireAfterAWeek() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("a.pdf")
        coordinator.refresh()
        coordinator.dismissPicker()

        coordinator.refresh(now: Date().addingTimeInterval(6 * 86_400))
        XCTAssertEqual(coordinator.heldItems.count, 1)
        coordinator.refresh(now: Date().addingTimeInterval(8 * 86_400))
        XCTAssertTrue(coordinator.heldItems.isEmpty)
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testFinishRemovesTheFileFromDisk() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("a.pdf")
        coordinator.refresh()
        let item = try XCTUnwrap(coordinator.pickerItems.first)

        coordinator.finish(item)
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testRefreshIsIgnoredWhileImporting() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        try share("a.pdf")
        coordinator.refresh()
        coordinator.begin(total: 1)
        XCTAssertFalse(coordinator.isPickingDestination)

        try share("b.pdf")
        coordinator.refresh()
        XCTAssertFalse(coordinator.isPickingDestination, "must not stack a picker over a running import")
    }

    func testProgressFractionCountsPagesOfTheCurrentFile() throws {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        coordinator.begin(total: 4)
        coordinator.advance(completed: 1, currentName: "b.pdf")
        XCTAssertEqual(try XCTUnwrap(coordinator.progress).fraction, 0.25, accuracy: 0.0001)

        coordinator.advancePage(done: 5, of: 10)
        XCTAssertEqual(try XCTUnwrap(coordinator.progress).fraction, 0.375, accuracy: 0.0001, "half of file 2 of 4")

        coordinator.advance(completed: 2, currentName: "c.pdf")
        let next = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(next.pageDone, 0, "a new file starts its page count again")
        XCTAssertEqual(next.fraction, 0.5, accuracy: 0.0001)
    }

    func testPageProgressOutsideAnImportIsIgnored() {
        let coordinator = SharedImportCoordinator(inbox: inbox)
        coordinator.advancePage(done: 3, of: 9)
        XCTAssertNil(coordinator.progress)
    }
}
