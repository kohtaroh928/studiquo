import XCTest
@testable import studiquo

/// Regression tests for the batch import's rules, one per reported failure:
///
/// 1. Importing several PDFs at once misbehaved — files must go strictly one
///    after another, with the screen able to follow along (progress).
/// 2. (see `PDFImportServiceTests`: oversized page images filled iCloud.)
/// 3. Files that could not be imported stayed forever and were silently pulled
///    into the next, unrelated import — a new import must touch only its own
///    files, and leftovers must be held for an explicit retry or discard.
@MainActor
final class SharedImportRunnerTests: XCTestCase {
    private var sandbox: URL!
    private var inbox: SharedInbox!
    private var coordinator: SharedImportCoordinator!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedImportRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        inbox = SharedInbox(root: sandbox.appendingPathComponent("Inbox", isDirectory: true))
        coordinator = SharedImportCoordinator(inbox: inbox)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// One share that brings these files in together.
    @discardableResult
    private func share(_ names: String...) throws -> [SharedInbox.Item] {
        let folder = sandbox.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        return inbox.enqueue(copying: urls).items
    }

    /// What the screen does when the student confirms: begin synchronously, then run.
    private func run(
        _ items: [SharedInbox.Item]? = nil,
        importer: (SharedInbox.Item) async -> SharedImportRunner.Outcome
    ) async -> SharedImportSummary? {
        coordinator.refresh()
        let batch = items ?? coordinator.pickerItems
        coordinator.begin(total: batch.count)
        return await SharedImportRunner.run(items: batch, coordinator: coordinator, importer: importer)
    }

    // MARK: Problem 3 — leftovers must not be dragged into the next import

    func testANewImportTouchesOnlyItsOwnFilesNeverEarlierLeftovers() async throws {
        try share("old-1.pdf", "old-2.pdf")
        coordinator.refresh()
        coordinator.dismissPicker() // the student cancelled: these are now held
        try share("new.pdf")

        var seen: [String] = []
        let summary = await run { item in seen.append(item.displayName); return .imported }

        XCTAssertEqual(seen, ["new.pdf"], "the leftovers must not ride along with an unrelated import")
        XCTAssertEqual(summary?.imported, 1)
        XCTAssertEqual(Set(coordinator.heldItems.map(\.displayName)), ["old-1.pdf", "old-2.pdf"], "and they must still be there")
    }

    func testOneFileFailingDoesNotStopTheOthers() async throws {
        try share("a.pdf", "b.pdf", "c.pdf")

        var seen: [String] = []
        let summary = await run { item in
            seen.append(item.displayName)
            return item.displayName == "b.pdf" ? .failed : .imported
        }

        XCTAssertEqual(seen, ["a.pdf", "b.pdf", "c.pdf"], "c.pdf must still be tried after b.pdf fails")
        XCTAssertEqual(summary?.imported, 2)
        XCTAssertEqual(summary?.held, ["b.pdf"])
    }

    func testFilesThatFailAreHeldNotLeftAsNewOnes() async throws {
        try share("ok.pdf", "bad.pdf")
        _ = await run { $0.displayName == "bad.pdf" ? .failed : .imported }

        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["bad.pdf"])
        XCTAssertTrue(coordinator.freshBatches.isEmpty, "a failed file must not look like a new share")
        XCTAssertEqual(inbox.pendingItems().map(\.displayName), ["bad.pdf"], "imported files leave the inbox")
    }

    func testAFailedFileIsNotPulledIntoTheNextShareButCanBeRetriedOnItsOwn() async throws {
        try share("bad.pdf")
        _ = await run { _ in .failed }
        try share("next.pdf")

        var firstSeen: [String] = []
        _ = await run { item in firstSeen.append(item.displayName); return .imported }
        XCTAssertEqual(firstSeen, ["next.pdf"])

        coordinator.presentHeldPicker()
        var retried: [String] = []
        let summary = await run { item in retried.append(item.displayName); return .imported }
        XCTAssertEqual(retried, ["bad.pdf"])
        XCTAssertEqual(summary?.imported, 1)
        XCTAssertTrue(coordinator.heldItems.isEmpty, "a retry that succeeds clears the leftovers")
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    func testARetryThatFailsAgainKeepsTheFileHeld() async throws {
        try share("bad.pdf")
        _ = await run { _ in .failed }
        coordinator.presentHeldPicker()
        _ = await run { _ in .failed }
        XCTAssertEqual(coordinator.heldItems.map(\.displayName), ["bad.pdf"])
    }

    func testFormatsTheLibraryCannotImportAreReportedAndDropped() async throws {
        try share("slides.pdf", "notes.xyz")
        var seen: [String] = []
        let summary = await run { item in seen.append(item.displayName); return .imported }

        XCTAssertEqual(seen, ["slides.pdf"], "an unsupported file is never handed to the importer")
        XCTAssertEqual(summary?.unsupported, ["notes.xyz"])
        XCTAssertEqual(summary?.imported, 1)
        XCTAssertTrue(inbox.pendingItems().isEmpty, "an unsupported file would only fail again, so it is not kept")
    }

    func testTheSummaryAddsUp() async throws {
        try share("ok-1.pdf", "ok-2.pdf", "bad.pdf", "what.xyz")
        let result = await run { $0.displayName == "bad.pdf" ? .failed : .imported }
        let summary = try XCTUnwrap(result)
        XCTAssertEqual(summary.imported + summary.held.count + summary.unsupported.count, 4)
        XCTAssertEqual(summary.imported, 2)
        XCTAssertTrue(summary.needsAttention)
    }

    func testACleanImportNeedsNoAttention() async throws {
        try share("a.pdf", "b.pdf")
        let result = await run { _ in .imported }
        let summary = try XCTUnwrap(result)
        XCTAssertFalse(summary.needsAttention, "no alert when everything simply worked")
        XCTAssertTrue(inbox.pendingItems().isEmpty)
    }

    // MARK: Problem 1 — one at a time, with progress the screen can show

    func testFilesAreImportedStrictlyOneAfterAnother() async throws {
        try share("1.pdf", "2.pdf", "3.pdf", "4.pdf")
        var running = 0
        var mostAtOnce = 0
        var order: [String] = []
        _ = await run { item in
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            order.append(item.displayName)
            try? await Task.sleep(for: .milliseconds(15)) // a render that takes a moment
            running -= 1
            return .imported
        }
        XCTAssertEqual(mostAtOnce, 1, "two PDFs rendering at once is what exhausted memory and froze the screen")
        XCTAssertEqual(order, ["1.pdf", "2.pdf", "3.pdf", "4.pdf"])
    }

    func testTheNextFileWaitsForTheCurrentOneToFinishCompletely() async throws {
        // Names sort in this order, so the locked file comes first.
        try share("1-locked.pdf", "2-after.pdf")
        var lockedFinished = false
        var afterStartedBeforeLockedFinished = false
        var afterRan = false
        _ = await run { item in
            if item.displayName == "1-locked.pdf" {
                // e.g. waiting on a password prompt
                try? await Task.sleep(for: .milliseconds(60))
                lockedFinished = true
            } else {
                afterRan = true
                if !lockedFinished { afterStartedBeforeLockedFinished = true }
            }
            return .imported
        }
        XCTAssertTrue(afterRan)
        XCTAssertFalse(afterStartedBeforeLockedFinished)
    }

    func testProgressNamesTheFileBeingImportedAndCountsFinishedOnes() async throws {
        try share("a.pdf", "b.pdf", "c.pdf")
        var snapshots: [SharedImportCoordinator.Progress] = []
        _ = await run { _ in
            if let progress = self.coordinator.progress { snapshots.append(progress) }
            return .imported
        }
        XCTAssertEqual(snapshots.map(\.currentName), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(snapshots.map(\.completed), [0, 1, 2])
        XCTAssertTrue(snapshots.allSatisfy { $0.total == 3 })
    }

    func testProgressIsClearedWhenTheImportEnds() async throws {
        try share("a.pdf")
        _ = await run { _ in .imported }
        XCTAssertNil(coordinator.progress)
        XCTAssertFalse(coordinator.isImporting, "or the next share could never start")
    }

    func testPageProgressRestartsForEachFile() async throws {
        try share("a.pdf", "b.pdf")
        var firstSeen: [Int] = []
        _ = await run { item in
            self.coordinator.advancePage(done: 7, of: 10)
            firstSeen.append(self.coordinator.progress?.pageDone ?? -1)
            return .imported
        }
        // Each file starts from page 0 (the importer reported 7 itself afterwards).
        XCTAssertEqual(firstSeen, [7, 7])
    }

    func testARunThatWasNeverBegunDoesNothing() async throws {
        try share("a.pdf")
        coordinator.refresh()
        var called = false
        let summary = await SharedImportRunner.run(items: coordinator.pickerItems, coordinator: coordinator) { _ in
            called = true
            return .imported
        }
        XCTAssertNil(summary, "begin() must come first, in the tap's own step, so a second tap cannot start a second run")
        XCTAssertFalse(called)
        XCTAssertEqual(inbox.pendingItems().count, 1)
    }
}
