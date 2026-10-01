import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class StorageUsageEstimatorTests: XCTestCase {
    // Keep in-memory containers alive for the test host's lifetime — see
    // LibraryFolderMoveTests' own copy of this comment on why: SwiftData
    // teardown can otherwise wait indefinitely for the app's unrelated
    // CloudKit store to finish its initial setup.
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    // MARK: Full-scan totals

    func testTotalBytesSumsEveryExternalStorageFieldAcrossTheWholeSchema() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let notebook = Notebook(title: "ノート")
        notebook.encryptedContent = Data(repeating: 1, count: 10)
        notebook.lockedPDFData = Data(repeating: 1, count: 15)
        context.insert(notebook)

        let page = NotePage(order: 0)
        page.drawingData = Data(repeating: 2, count: 20)
        page.backgroundImageData = Data(repeating: 3, count: 30)
        page.proofReviewData = Data(repeating: 4, count: 40)
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(page)

        let element = PageElement(kind: .image, imageData: Data(repeating: 5, count: 50))
        element.page = page
        page.addElement(element)
        context.insert(element)

        let document = TextDocument(title: "文書")
        document.bodyData = Data(repeating: 6, count: 60)
        context.insert(document)

        let block = DocumentBlock(order: 0)
        block.bodyData = Data(repeating: 7, count: 70)
        block.document = document
        document.blocks = [block]
        context.insert(block)

        let row = DocumentTableRow(order: 0)
        row.block = block
        context.insert(row)

        let cell = DocumentTableCell(order: 0)
        cell.bodyData = Data(repeating: 8, count: 80)
        cell.row = row
        row.cells = [cell]
        context.insert(cell)

        let headerFooter = DocumentHeaderFooter(kind: .header)
        headerFooter.bodyData = Data(repeating: 9, count: 90)
        headerFooter.document = document
        document.headerFooters = [headerFooter]
        context.insert(headerFooter)

        let deck = SlideDeck(title: "スライド")
        context.insert(deck)

        let slide = Slide(order: 0)
        slide.imageData = Data(repeating: 10, count: 100)
        slide.deck = deck
        deck.addSlide(slide)
        context.insert(slide)

        let slideElement = slide.addElement(SlideElement(kind: .image))
        slideElement.imageData = Data(repeating: 11, count: 110)
        slideElement.bodyData = Data(repeating: 12, count: 120)
        context.insert(slideElement)

        let reviewItem = AIReviewItem(
            questionText: "質問", threadTitle: "スレッド", createdAt: .now, reviewDate: .now,
            explanationMarkdown: "説明", quiz: [AIQuizQuestion(question: "Q", answer: "A")]
        )
        context.insert(reviewItem)
        let quizBytes = reviewItem.quizData?.count ?? 0

        try context.save()

        let expected = 10 + 15 + 20 + 30 + 40 + 50 + 60 + 70 + 80 + 90 + 100 + 110 + 120 + quizBytes
        XCTAssertEqual(try StorageUsageEstimator.totalBytes(in: context), expected)
    }

    func testTotalBytesIsZeroForAnEmptyLibrary() throws {
        let container = try makeContainer()
        XCTAssertEqual(try StorageUsageEstimator.totalBytes(in: container.mainContext), 0)
    }

    // MARK: Plan limits — pure arithmetic

    func testWouldExceedLimitIsFalseExactlyAtTheLimit() {
        XCTAssertFalse(StorageUsageEstimator.wouldExceedLimit(
            currentTotalBytes: 0,
            additionalBytes: StorageUsageEstimator.plusPlanLimitBytes,
            plan: .plus
        ))
    }

    func testWouldExceedLimitIsTrueOneByteOverTheLimit() {
        XCTAssertTrue(StorageUsageEstimator.wouldExceedLimit(
            currentTotalBytes: 1,
            additionalBytes: StorageUsageEstimator.plusPlanLimitBytes,
            plan: .plus
        ))
    }

    func testWouldExceedLimitIsFalseWellUnderTheLimit() {
        XCTAssertFalse(StorageUsageEstimator.wouldExceedLimit(
            currentTotalBytes: 1024,
            additionalBytes: 1024,
            plan: .standard
        ))
    }

    func testPlanLimitsAreOrderedStandardLessThanPlusLessThanPro() {
        XCTAssertLessThan(StorageUsageEstimator.limitBytes(for: .standard), StorageUsageEstimator.limitBytes(for: .plus))
        XCTAssertLessThan(StorageUsageEstimator.limitBytes(for: .plus), StorageUsageEstimator.limitBytes(for: .pro))
    }

    // MARK: StorageUsageCache

    func testCacheSeedsFromAFullScanOnTheFirstCheckThenReusesIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        notebook.encryptedContent = Data(repeating: 1, count: 1_000)
        context.insert(notebook)
        try context.save()

        let cache = StorageUsageCache.shared
        cache.resetForTesting()

        // Still under the standard limit — must not exceed.
        XCTAssertFalse(cache.wouldExceedLimit(addingBytes: 100, plan: .standard, in: context))
        XCTAssertEqual(cache.cachedTotalBytes, 1_000)

        // A second check reuses the seeded cache rather than rescanning —
        // adding content after the scan without going through `adjust(by:)`
        // must not retroactively appear.
        notebook.encryptedContent = Data(repeating: 1, count: 1_000_000)
        try context.save()
        XCTAssertEqual(cache.cachedTotalBytes, 1_000)
    }

    func testCacheAdjustTracksIncrementalWritesWithoutRescanning() throws {
        let container = try makeContainer()
        let cache = StorageUsageCache.shared
        cache.resetForTesting()
        cache.refresh(in: container.mainContext)
        XCTAssertEqual(cache.cachedTotalBytes, 0)

        cache.adjust(by: 500)
        XCTAssertEqual(cache.cachedTotalBytes, 500)

        cache.adjust(by: -200)
        XCTAssertEqual(cache.cachedTotalBytes, 300)

        // Never goes negative, even if a caller over-subtracts.
        cache.adjust(by: -10_000)
        XCTAssertEqual(cache.cachedTotalBytes, 0)
    }
}
