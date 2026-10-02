import XCTest
import SwiftData
import UIKit
@testable import studiquo

/// Pins the conversation logic that moved out of `NoteEditorView` into
/// `AIChatStore`: sending, the reply stream, stopping, deleting and the
/// per-conversation drafts. The store runs against a scripted provider and a
/// real (temporary) SwiftData store; no network is involved.
@MainActor
final class AIChatStoreTests: XCTestCase {
    private var storeURLs: [URL] = []
    private var provider: ScriptedAIProvider!

    override func setUp() {
        super.setUp()
        provider = ScriptedAIProvider()
        AI.provider = provider
        // Keep the fire-and-forget "review tomorrow" step away from the
        // notification centre (it hangs inside an XCTest host).
        AIReviewService.scheduleNotification = { _ in }
    }

    override func tearDown() async throws {
        // Let the store's fire-and-forget tasks finish with the database
        // still in place before it is deleted.
        try? await Task.sleep(for: .milliseconds(150))
        AI.provider = WorkerAIProvider()
        AIReviewService.scheduleNotification = { await AIReviewNotifications.schedule(for: $0) }
        for url in storeURLs { try? FileManager.default.removeItem(at: url) }
        storeURLs = []
        try await super.tearDown()
    }

    private func makeStore() -> (AIChatStore, ModelContext) {
        let schema = Schema([AIChatThread.self, AIChatMessage.self, TextDocument.self, AIReviewItem.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString).sqlite")
        storeURLs.append(url)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let store = AIChatStore(modelContext: context)
        store.announceThread = { [weak self] in self?.announced.append($0.title) }
        store.closeThreadTab = { [weak self] _ in self?.closedTabs += 1 }
        return (store, context)
    }

    private var announced: [String] = []
    private var closedTabs = 0

    /// Polls the main actor until `condition` holds, so a test can wait for
    /// the store's reply task without exposing it.
    private func waitUntil(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for: \(description)")
    }

    private func settle(_ store: AIChatStore) async {
        await waitUntil("replies to finish") { store.respondingThreadIDs.isEmpty }
    }

    // MARK: Sending

    func testSendCreatesAThreadStreamsTheReplyAndTitlesItFromTheFirstMessage() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in
            onDelta("こん")
            onDelta("にちは")
        }
        store.activeDraft = "これは二十四文字をこえる長い最初の質問ですよ、ありがとう"

        store.send()

        let thread = try! XCTUnwrap(store.selectedThread)
        XCTAssertEqual(thread.title, String("これは二十四文字をこえる長い最初の質問ですよ、ありがとう".prefix(24)))
        XCTAssertEqual(thread.sortedMessages.map(\.role), [.user, .assistant])
        XCTAssertTrue(store.isResponding(thread))
        XCTAssertEqual(store.drafts[AIChatStore.threadKey(thread)], "")
        XCTAssertEqual(announced, [thread.title])

        await settle(store)
        XCTAssertEqual(thread.sortedMessages.last?.text, "こんにちは")
        XCTAssertFalse(store.isResponding(thread))
        XCTAssertEqual(store.threads.count, 1)
    }

    func testSecondMessageKeepsTheTitleAndAppendsToTheSameThread() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in onDelta("返答") }
        store.activeDraft = "最初"
        store.send()
        await settle(store)
        let thread = try! XCTUnwrap(store.selectedThread)

        store.activeDraft = "二番目"
        store.send()
        await settle(store)

        XCTAssertEqual(thread.title, "最初")
        XCTAssertEqual(thread.sortedMessages.count, 4)
        XCTAssertEqual(store.threads.count, 1)
    }

    func testHistorySentToTheProviderExcludesTheEmptyReplyAndContextIsJoined() async {
        let (store, _) = makeStore()
        var seenTurns: [AITurn] = []
        var seenContext = ""
        provider.chat = { turns, context, _, _, onDelta in
            seenTurns = turns
            seenContext = context
            onDelta("ok")
        }
        let attachment = AIChatAttachment(name: "資料", path: "", kind: .file, contextText: "添付の中身")
        store.activeDraft = "質問"
        store.activeAttachments = [attachment]
        store.setContextOverride("追加の文脈", forKey: store.activeDraftKey)

        store.send(noteContext: "ページの文章")
        await settle(store)

        XCTAssertEqual(seenTurns.count, 1)
        XCTAssertEqual(seenTurns.first?.role, .user)
        XCTAssertTrue(seenTurns.first?.text.hasPrefix("質問") ?? false)
        XCTAssertTrue(seenTurns.first?.text.contains("- ファイル: 資料") ?? false)
        XCTAssertEqual(seenContext, "ページの文章\n\n追加の文脈\n\n【資料】\n添付の中身")
    }

    func testBlankDraftSendsNothing() {
        let (store, _) = makeStore()
        store.activeDraft = "  \n "
        store.send()
        XCTAssertNil(store.selectedThread)
        XCTAssertEqual(provider.chatCallCount, 0)
    }

    func testSendingWhileTheThreadIsStillBeingAnsweredIsIgnored() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in
            onDelta("途中")
            try await Task.sleep(for: .seconds(30))
        }
        store.activeDraft = "一回目"
        store.send()
        let thread = try! XCTUnwrap(store.selectedThread)

        store.activeDraft = "二回目"
        store.send()

        XCTAssertEqual(thread.sortedMessages.count, 2, "二重送信でメッセージが増えてはいけません")
        XCTAssertEqual(store.activeDraft, "二回目", "無視した送信で下書きを消してはいけません")
        store.cancelResponse()
        await settle(store)
    }

    func testCancelStopsTheReplyAndMarksItInterrupted() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in
            onDelta("途中")
            try await Task.sleep(for: .seconds(30))
        }
        store.activeDraft = "長い質問"
        store.send()
        let thread = try! XCTUnwrap(store.selectedThread)
        await waitUntil("first delta") { thread.sortedMessages.last?.text == "途中" }

        store.cancelResponse()

        XCTAssertFalse(store.isResponding(thread), "停止した直後に返答中の表示が消えること")
        await waitUntil("interrupted marker") { thread.sortedMessages.last?.text == "途中（中断しました）" }
    }

    func testProviderErrorBecomesTheReplyText() async {
        struct Boom: LocalizedError { var errorDescription: String? { "サーバーに接続できません" } }
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, _ in throw Boom() }
        store.activeDraft = "質問"
        store.send()
        await settle(store)
        XCTAssertEqual(store.selectedThread?.sortedMessages.last?.text, "サーバーに接続できません")
    }

    func testAnEmptyReplyIsReplacedByAnExplanation() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, _ in }
        store.activeDraft = "質問"
        store.send()
        await settle(store)
        XCTAssertEqual(store.selectedThread?.sortedMessages.last?.text, "返答が空でした。もう一度試してください。")
    }

    // MARK: Conversations and drafts

    func testNewThreadDeselectsAndClearsTheNewDraft() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in onDelta("a") }
        store.activeDraft = "最初"
        store.send()
        await settle(store)
        XCTAssertNotNil(store.selectedThread)

        store.startNewThread()

        XCTAssertNil(store.selectedThread)
        XCTAssertEqual(store.activeDraftKey, AIChatStore.newThreadKey)
        XCTAssertEqual(store.activeDraft, "")
    }

    func testDraftsAndAttachmentsAreKeptPerThread() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in onDelta("a") }
        store.activeDraft = "A"; store.send(); await settle(store)
        let threadA = try! XCTUnwrap(store.selectedThread)
        store.startNewThread()
        store.activeDraft = "B"; store.send(); await settle(store)
        let threadB = try! XCTUnwrap(store.selectedThread)

        store.select(threadA)
        store.activeDraft = "Aの書きかけ"
        store.select(threadB)
        XCTAssertEqual(store.activeDraft, "")
        store.activeDraft = "Bの書きかけ"
        store.select(threadA)
        XCTAssertEqual(store.activeDraft, "Aの書きかけ")
        store.select(threadB)
        XCTAssertEqual(store.activeDraft, "Bの書きかけ")
    }

    func testLoadThreadsSkipsConversationsWithNoMessagesAndSortsNewestFirst() {
        let (store, context) = makeStore()
        let empty = AIChatThread(title: "空")
        let older = AIChatThread(title: "古い"); older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = AIChatThread(title: "新しい"); newer.updatedAt = Date(timeIntervalSince1970: 200)
        for thread in [empty, older, newer] { context.insert(thread) }
        for thread in [older, newer] {
            let message = AIChatMessage(text: "x", role: .user)
            message.thread = thread
            thread.addMessage(message)
        }
        try? context.save()

        store.loadThreads()

        XCTAssertEqual(store.threads.map(\.title), ["新しい", "古い"])
    }

    func testDeleteRemovesTheThreadCancelsItsReplyClearsItsStateAndSelectsTheNext() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in onDelta("a") }
        store.activeDraft = "残す"; store.send(); await settle(store)
        let kept = try! XCTUnwrap(store.selectedThread)
        store.startNewThread()
        provider.chat = { _, _, _, _, onDelta in
            onDelta("途中")
            try await Task.sleep(for: .seconds(30))
        }
        store.activeDraft = "消す"; store.send()
        let doomed = try! XCTUnwrap(store.selectedThread)
        store.activeDraft = "消す側の下書き"
        let doomedKey = AIChatStore.threadKey(doomed)

        store.delete(doomed)

        XCTAssertEqual(closedTabs, 1)
        XCTAssertFalse(store.respondingThreadIDs.contains(doomedKey))
        XCTAssertNil(store.drafts[doomedKey])
        XCTAssertEqual(store.threads.map(\.title), ["残す"])
        XCTAssertTrue(store.selectedThread === kept, "削除後は残った会話が選択されること")
    }

    func testDeletingANonSelectedThreadKeepsTheSelection() async {
        let (store, _) = makeStore()
        provider.chat = { _, _, _, _, onDelta in onDelta("a") }
        store.activeDraft = "一つ目"; store.send(); await settle(store)
        let first = try! XCTUnwrap(store.selectedThread)
        store.startNewThread()
        store.activeDraft = "二つ目"; store.send(); await settle(store)
        let second = try! XCTUnwrap(store.selectedThread)

        store.delete(first)

        XCTAssertTrue(store.selectedThread === second)
    }

    // MARK: Marking

    func testSubmitProofNeedsBothAQuestionAndAnAnswer() {
        let (store, _) = makeStore()
        store.submitProof(ProofSubmission(questionText: "問題だけ"))
        XCTAssertNil(store.selectedThread)
        XCTAssertEqual(provider.rubricCallCount, 0)
    }

    func testSubmitProofTitlesTheThreadAndWritesTheMarkingReport() async {
        let (store, _) = makeStore()
        provider.review = ProofReviewResult(
            score: 8, maxScore: 10, verdict: "良くできています。",
            criteria: [ProofCriterionResult(name: "論理", earnedPoints: 4, maxPoints: 5, comment: "")],
            issues: []
        )
        store.submitProof(ProofSubmission(questionText: "問題", answerText: "解答"))

        let thread = try! XCTUnwrap(store.selectedThread)
        XCTAssertEqual(thread.title, "証明の添削")
        XCTAssertEqual(thread.sortedMessages.first?.role, .user)

        await settle(store)
        let report = thread.sortedMessages.last?.text ?? ""
        XCTAssertTrue(report.contains("【8 / 10点】"), report)
        XCTAssertTrue(report.contains("AIによるものです"))
    }

    // MARK: Formatting

    func testMessageTextListsAttachmentsOnlyWhenThereAreAny() {
        XCTAssertEqual(AIChatFormatting.messageText("本文", with: []), "本文")
        let text = AIChatFormatting.messageText(
            "本文",
            with: [AIChatAttachment(name: "ノートA", path: "", kind: .notebook)]
        )
        XCTAssertTrue(text.hasPrefix("本文"))
        XCTAssertTrue(text.contains("- ノート・PDF: ノートA"))
    }
}

/// A provider whose behaviour each test scripts.
private final class ScriptedAIProvider: AIProvider {
    var isConfigured = true
    var displayName = "Scripted"
    var chat: (
        _ turns: [AITurn], _ context: String, _ images: [UIImage], _ expectsImages: Bool,
        _ onDelta: @escaping (String) -> Void
    ) async throws -> Void = { _, _, _, _, _ in }
    var review = ProofReviewResult(score: 0, maxScore: 0, verdict: "", criteria: [], issues: [])
    private(set) var chatCallCount = 0
    private(set) var rubricCallCount = 0

    func streamChat(
        turns: [AITurn], noteContext: String, images: [UIImage], expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        chatCallCount += 1
        try await chat(turns, noteContext, images, expectsImages, onDelta)
    }

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        rubricCallCount += 1
        return ProofRubric(criteria: [])
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        review
    }

    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    }
}
