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
    }

    override func tearDown() {
        AI.provider = WorkerAIProvider()
        AIReviewService.scheduleNotification = { await AIReviewNotifications.schedule(for: $0) }
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
