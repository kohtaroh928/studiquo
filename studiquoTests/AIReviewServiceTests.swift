import XCTest
import SwiftData
import UIKit
@testable import studiquo

/// Regression coverage for `AIReviewService.considerForReview`: the fire-
/// and-forget call made right after an AIトーク reply finishes, which turns
/// a question into tomorrow's review material — but only when the AI judges
/// it worth reviewing.
///
/// Two mutable static seams make this testable without touching the network
/// or the real notification system: `AI.provider` (tests swap in
/// `FakeAIProvider`) and `AIReviewService.scheduleNotification` (tests swap
/// in a no-op — the real path goes through `UNUserNotificationCenter`, which
/// was found to hang indefinitely inside an XCTest unit-test host; there's no
/// interactive UI in that process for a permission prompt to resolve
/// against, and a real run of this suite hung on exactly that until the seam
/// was added).
@MainActor
final class AIReviewServiceTests: XCTestCase {
    private var storeURLs: [URL] = []

    override func setUp() {
        super.setUp()
        AIReviewService.scheduleNotification = { _ in }
        UserDefaults.standard.removeObject(forKey: AIReviewService.isEnabledDefaultsKey)
    }

    override func tearDown() {
        AI.provider = WorkerAIProvider()
        AIReviewService.scheduleNotification = { await AIReviewNotifications.schedule(for: $0) }
        UserDefaults.standard.removeObject(forKey: AIReviewService.isEnabledDefaultsKey)
        for url in storeURLs { try? FileManager.default.removeItem(at: url) }
        storeURLs = []
        super.tearDown()
    }

    /// A real, file-backed store rather than `isStoredInMemoryOnly: true` —
    /// both models here have an `@Attribute(.externalStorage)` field
    /// (`TextDocument.bodyData`, `AIReviewItem.quizData`), and this keeps
    /// them on the same footing as the app's real on-disk store rather than
    /// relying on in-memory external-storage handling being equivalent. A
    /// unique temp file per test keeps tests isolated from each other.
    private func makeContext() -> ModelContext {
        let schema = Schema([TextDocument.self, AIReviewItem.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AIReviewServiceTests-\(UUID().uuidString).sqlite")
        storeURLs.append(url)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        return ModelContext(container)
    }

    // MARK: 設定でのオン・オフ（回帰テスト）

    /// Regression coverage for a real gap: this feature shipped with no way
    /// to turn it off — every AIトーク reply silently triggered a second AI
    /// call and saved a document. `AppSettingsView`'s "翌日復習を作成する"
    /// toggle writes `AIReviewService.isEnabledDefaultsKey` to UserDefaults;
    /// this proves `considerForReview` actually honors it, and does so
    /// before ever touching the network.
    func testTogglingTheSettingOffSkipsEverythingIncludingTheProviderCall() async throws {
        UserDefaults.standard.set(false, forKey: AIReviewService.isEnabledDefaultsKey)
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "加法定理を教えて", threadTitle: "数学", askedAt: .now, modelContext: context
        )

        XCTAssertEqual(fake.researchCallCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextDocument>()), 0)
    }

    /// The setting has never been touched (fresh install / no UserDefaults
    /// entry yet) — the feature already shipped enabled, so a missing key
    /// must default to `true`, not `false`.
    func testAnUntouchedSettingDefaultsToEnabled() {
        UserDefaults.standard.removeObject(forKey: AIReviewService.isEnabledDefaultsKey)
        XCTAssertTrue(AIReviewService.isEnabled)
    }

    func testExplicitlyEnabledSettingStillRunsNormally() async throws {
        UserDefaults.standard.set(true, forKey: AIReviewService.isEnabledDefaultsKey)
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問", threadTitle: "スレッド", askedAt: .now, modelContext: context
        )

        XCTAssertEqual(fake.researchCallCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 1)
    }

    // MARK: Category 1 — AIの判定

    func testIdleChatProducesNoReviewItemOrDocument() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "ありがとう！",
            threadTitle: "雑談",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextDocument>()), 0)
    }

    func testAWhitespaceOnlyQuestionIsNeverSentToTheProvider() async throws {
        let fake = FakeAIProvider()
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "   \n  ",
            threadTitle: "スレッド",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(fake.researchCallCount, 0)
    }

    func testANotConfiguredProviderSkipsTheCallEntirely() async throws {
        let fake = FakeAIProvider()
        fake.isConfigured = false
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "加法定理を教えて",
            threadTitle: "数学",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(fake.researchCallCount, 0)
    }

    // MARK: Category 2 — 生成される内容

    func testAStudyQuestionSavesTheExplanationAsADocumentInTheReviewFolder() async throws {
        let fake = FakeAIProvider()
        let quiz = [
            AIQuizQuestion(question: "sin(a+b) の展開は？", answer: "sin a cos b + cos a sin b"),
            AIQuizQuestion(question: "cos(a+b) の展開は？", answer: "cos a cos b - sin a sin b"),
        ]
        fake.reviewResult = .success(AIReviewResult(
            isStudyRelevant: true,
            explanationMarkdown: "# 加法定理\n- sin(a+b) = sin a cos b + cos a sin b",
            quiz: quiz
        ))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "加法定理の証明を教えて",
            threadTitle: "数学の質問",
            askedAt: .now,
            modelContext: context
        )

        let documents = try context.fetch(FetchDescriptor<TextDocument>())
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.folderName, AIReviewService.reviewFolderName)
        // The markup parser turns "# " into a heading and strips the marker,
        // so the plain-text mirror should carry the heading text without it.
        XCTAssertEqual(documents.first?.plainText.contains("加法定理"), true)
        XCTAssertEqual(documents.first?.plainText.contains("# "), false)

        let items = try context.fetch(FetchDescriptor<AIReviewItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.quiz, quiz)
        XCTAssertEqual(items.first?.questionText, "加法定理の証明を教えて")
        XCTAssertNotNil(items.first?.explanationDocument)
        XCTAssertEqual(items.first?.explanationDocument?.persistentModelID, documents.first?.persistentModelID)
    }

    /// The saved document's title is built from the question text — this
    /// pins down the truncation rule (`reviewDocumentTitle(for:)`,
    /// `AIReviewService.swift`) via its one observable effect, the saved
    /// `TextDocument.title`, rather than by exposing the `private` helper
    /// itself.
    func testShortQuestionTitleIsNotTruncated() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "積分って何？", threadTitle: "数学", askedAt: .now, modelContext: context
        )

        let document = try XCTUnwrap(try context.fetch(FetchDescriptor<TextDocument>()).first)
        XCTAssertEqual(document.title, "復習: 積分って何？")
        XCTAssertFalse(document.title.contains("…"))
    }

    /// Exactly 20 characters is the boundary the truncation check uses
    /// (`question.count > 20`) — at exactly 20 it must NOT truncate, only
    /// once it exceeds 20.
    func testQuestionTitleExactlyAtTheTruncationBoundaryIsNotTruncated() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        let question = String(repeating: "あ", count: 20)
        XCTAssertEqual(question.count, 20)

        await AIReviewService.considerForReview(
            questionText: question, threadTitle: "スレッド", askedAt: .now, modelContext: context
        )

        let document = try XCTUnwrap(try context.fetch(FetchDescriptor<TextDocument>()).first)
        XCTAssertEqual(document.title, "復習: " + question)
        XCTAssertFalse(document.title.contains("…"))
    }

    func testLongQuestionTitleIsTruncatedToTwentyCharactersWithAnEllipsis() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        let question = "三角関数の加法定理の証明について、二通りの方法を詳しく教えてください。単位円を使う方法と回転行列を使う方法の両方を知りたいです。"
        XCTAssertGreaterThan(question.count, 20)

        await AIReviewService.considerForReview(
            questionText: question, threadTitle: "スレッド", askedAt: .now, modelContext: context
        )

        let document = try XCTUnwrap(try context.fetch(FetchDescriptor<TextDocument>()).first)
        let expectedSnippet = String(question.prefix(20))
        XCTAssertEqual(document.title, "復習: \(expectedSnippet)…")
        // The title must actually be shorter than the full question, not
        // just have an ellipsis tacked onto the whole thing.
        XCTAssertLessThan(document.title.count, question.count)
    }

    /// Asking the same question twice in a day (the student re-sends it, or
    /// asks it in two different threads) must not merge/dedupe into one
    /// review — each occurrence gets its own document and its own review
    /// item, independently. Nothing in `considerForReview` looks at
    /// existing items before saving a new one, so this pins down that this
    /// is deliberate rather than untested.
    func testAskingTheSameQuestionTwiceCreatesTwoIndependentReviewsAndDocuments() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "微分の連鎖律を教えて", threadTitle: "数学", askedAt: .now, modelContext: context
        )
        await AIReviewService.considerForReview(
            questionText: "微分の連鎖律を教えて", threadTitle: "数学", askedAt: .now, modelContext: context
        )

        let items = try context.fetch(FetchDescriptor<AIReviewItem>())
        let documents = try context.fetch(FetchDescriptor<TextDocument>())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(documents.count, 2)
        // Two independent pairs, not one item pointing at both documents or
        // two items sharing one document.
        XCTAssertEqual(Set(items.compactMap { $0.explanationDocument?.persistentModelID }).count, 2)
        XCTAssertNotEqual(items[0].persistentModelID, items[1].persistentModelID)
    }

    func testTheReviewDateIsTheDayAfterTheQuestionWasAsked() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 10; components.hour = 20
        let askedAt = Calendar.current.date(from: components)!

        await AIReviewService.considerForReview(
            questionText: "質問",
            threadTitle: "スレッド",
            askedAt: askedAt,
            modelContext: context
        )

        let item = try context.fetch(FetchDescriptor<AIReviewItem>()).first
        let reviewComponents = Calendar.current.dateComponents([.year, .month, .day, .hour], from: item?.reviewDate ?? .now)
        XCTAssertEqual(reviewComponents.day, 11)
        XCTAssertEqual(reviewComponents.hour, 9)
    }

    /// The prompt tells the AI to leave `explanationMarkdown` empty when the
    /// question isn't worth reviewing — this guards against a reply that
    /// says `isStudyRelevant: true` but forgot the content.
    func testAStudyRelevantFlagWithNoActualExplanationIsNotSavedEither() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "   ", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問",
            threadTitle: "スレッド",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextDocument>()), 0)
    }

    // MARK: 通知予約の呼び出し（回帰テスト）

    /// Regression coverage for a real bug: `considerForReview` used to call
    /// `AIReviewNotifications.schedule(for:)` directly, which goes through
    /// `UNUserNotificationCenter` — a real test run hung forever on this,
    /// because there's no interactive UI in an XCTest host for a permission
    /// prompt to resolve against. The fix routes the call through the
    /// swappable `AIReviewService.scheduleNotification` seam instead. This
    /// test proves the seam is actually wired into the saved-review path —
    /// not just that it exists — so a future refactor that calls
    /// `UNUserNotificationCenter` directly again (bypassing the seam) is
    /// caught here rather than reappearing as a silent test hang.
    func testASavedReviewCallsTheNotificationSeamWithThatExactItem() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        var scheduledItems: [AIReviewItem] = []
        AIReviewService.scheduleNotification = { scheduledItems.append($0) }

        await AIReviewService.considerForReview(
            questionText: "加法定理を教えて",
            threadTitle: "数学",
            askedAt: .now,
            modelContext: context
        )

        let savedItem = try context.fetch(FetchDescriptor<AIReviewItem>()).first
        XCTAssertEqual(scheduledItems.count, 1)
        XCTAssertEqual(scheduledItems.first?.persistentModelID, savedItem?.persistentModelID)
    }

    /// The mirror image of the test above: when nothing is saved (idle
    /// chat), nothing should be scheduled either.
    func testAnIrrelevantQuestionNeverCallsTheNotificationSeam() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: []))
        AI.provider = fake
        let context = makeContext()

        var scheduleCallCount = 0
        AIReviewService.scheduleNotification = { _ in scheduleCallCount += 1 }

        await AIReviewService.considerForReview(
            questionText: "ありがとう",
            threadTitle: "雑談",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(scheduleCallCount, 0)
    }

    // MARK: 文書が削除・ゴミ箱に入った場合

    /// If the student later deletes the generated 文書 outright (not just
    /// trashes it), `AIReviewItem.explanationDocument` has no explicit
    /// `@Relationship(deleteRule:)`, so SwiftData's default `.nullify`
    /// should clear the reference rather than leaving a dangling pointer.
    /// The review screen's fallback (showing `item.explanationMarkdown`
    /// when `explanationDocument` is nil) depends on this actually becoming
    /// nil instead of a stale/unfaultable reference.
    func testDeletingTheLinkedDocumentNullifiesTheReviewItemsReference() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(isStudyRelevant: true, explanationMarkdown: "解説", quiz: []))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問", threadTitle: "スレッド", askedAt: .now, modelContext: context
        )

        let item = try XCTUnwrap(try context.fetch(FetchDescriptor<AIReviewItem>()).first)
        let document = try XCTUnwrap(item.explanationDocument)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextDocument>()), 1)

        context.delete(document)
        try context.save()

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<AIReviewItem>()).first)
        XCTAssertNil(reloaded.explanationDocument)
        // The review's own copy of the text survives the document's
        // deletion — this is what the fallback in AIReviewDetailView reads.
        XCTAssertEqual(reloaded.explanationMarkdown, "解説")
    }

    /// Trashing (a soft delete via `TextDocument.isTrashed`, recoverable
    /// from the library's trash) is different from deleting outright: the
    /// document object and its `bodyData` still exist, so the review
    /// screen's PDF-export button — enabled whenever `explanationDocument`
    /// is non-nil — must still produce real PDF bytes rather than silently
    /// exporting an empty file.
    func testATrashedButNotDeletedDocumentStillExportsRealPDFData() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .success(AIReviewResult(
            isStudyRelevant: true, explanationMarkdown: "# 加法定理\n- sin(a+b) = ...", quiz: []
        ))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問", threadTitle: "スレッド", askedAt: .now, modelContext: context
        )

        let item = try XCTUnwrap(try context.fetch(FetchDescriptor<AIReviewItem>()).first)
        let document = try XCTUnwrap(item.explanationDocument)

        document.isTrashed = true
        document.trashedAt = .now
        try context.save()

        XCTAssertNotNil(item.explanationDocument, "ゴミ箱に入れただけでは参照が失われてはいけません。")
        let pdfData = ExportService.pdfData(from: document)
        XCTAssertNotNil(pdfData)
        XCTAssertGreaterThan(pdfData?.count ?? 0, 0)
    }

    // MARK: Category 6 — 障害時の挙動

    func testANetworkFailureIsSwallowedRatherThanCrashingOrLeavingPartialState() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .failure(URLError(.notConnectedToInternet))
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問",
            threadTitle: "スレッド",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TextDocument>()), 0)
    }

    func testAMalformedResultFromTheProviderIsSwallowedTooNotJustNetworkErrors() async throws {
        let fake = FakeAIProvider()
        fake.reviewResult = .failure(WorkerAIProvider.ProviderError.malformedResponse)
        AI.provider = fake
        let context = makeContext()

        await AIReviewService.considerForReview(
            questionText: "質問",
            threadTitle: "スレッド",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0)
    }
}

/// A controllable stand-in for `AI.provider`. Only `researchReview` matters
/// to these tests; the chat/proof-marking methods are never expected to be
/// called from `AIReviewService` and fail loudly if they are.
private final class FakeAIProvider: AIProvider {
    var isConfigured = true
    var displayName = "Fake"
    var reviewResult: Result<AIReviewResult, Error> = .success(
        AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    )
    private(set) var researchCallCount = 0

    func streamChat(
        turns: [AITurn], noteContext: String, images: [UIImage], expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        XCTFail("AIReviewService should never call streamChat")
    }

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        XCTFail("AIReviewService should never call buildRubric")
        throw WorkerAIProvider.ProviderError.malformedResponse
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        XCTFail("AIReviewService should never call grade")
        throw WorkerAIProvider.ProviderError.malformedResponse
    }

    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        researchCallCount += 1
        return try reviewResult.get()
    }
}
