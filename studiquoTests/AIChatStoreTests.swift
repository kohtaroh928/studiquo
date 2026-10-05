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
        store.deliverCompletion = { [weak self] thread in self?.delivered.append(thread.title) }
        store.clearCompletion = { [weak self] thread in self?.cleared.append(thread.title) }
        return (store, context)
    }

    private var announced: [String] = []
    private var closedTabs = 0
    /// Titles of conversations an "answer ready" notification was sent for / taken back.
    private var delivered: [String] = []
    private var cleared: [String] = []

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

    func testOnlyExplicitlySelectedContextIsSentAndOpenNoteIsExcluded() async {
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
        XCTAssertEqual(seenContext, "追加の文脈\n\n【資料】\n添付の中身")
        XCTAssertFalse(seenContext.contains("ページの文章"))
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

    // MARK: Is anyone looking?

    /// Starts a conversation and leaves it selected.
    private func startThread(_ store: AIChatStore, _ text: String) async -> AIChatThread {
        provider.chat = { _, _, _, _, onDelta in onDelta("返答") }
        store.activeDraft = text
        store.send()
        await settle(store)
        return store.selectedThread!
    }

    func testNothingIsViewedWhileNoChatScreenIsOnDisplay() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        let thread = await startThread(store, "質問")

        XCTAssertNil(store.viewedThread, "選択中でも、表示している画面がなければ見ていない")
        XCTAssertFalse(store.isViewing(thread))
    }

    func testAThreadIsViewedOnlyWhileAChatScreenShowsItAndTheAppIsInFront() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        let thread = await startThread(store, "質問")
        let screen = UUID()

        store.surfaceDidAppear(screen)
        XCTAssertTrue(store.isViewing(thread))
        XCTAssertTrue(store.viewedThread === thread)

        store.isAppActive = false
        XCTAssertFalse(store.isViewing(thread), "画面ロック・別アプリ・バックグラウンドでは見ていない")
        store.isAppActive = true
        XCTAssertTrue(store.isViewing(thread))

        store.surfaceDidDisappear(screen)
        XCTAssertFalse(store.isViewing(thread), "画面が消えたら見ていない")
    }

    func testOnlyTheSelectedThreadIsViewed() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        let first = await startThread(store, "一つ目")
        store.startNewThread()
        let second = await startThread(store, "二つ目")
        store.surfaceDidAppear(UUID())

        XCTAssertTrue(store.isViewing(second))
        XCTAssertFalse(store.isViewing(first), "画面に出ているのは選択中の会話だけ")

        store.select(first)
        XCTAssertTrue(store.isViewing(first))
        XCTAssertFalse(store.isViewing(second))

        store.startNewThread()
        XCTAssertFalse(store.isViewing(first), "新しいトークを表示中は、どの会話も見ていない")
        XCTAssertNil(store.viewedThread)
    }

    func testTheConversationStaysViewedUntilEveryScreenShowingItIsGone() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        let thread = await startThread(store, "質問")
        let home = UUID(), editor = UUID()

        store.surfaceDidAppear(home)
        store.surfaceDidAppear(editor)
        store.surfaceDidAppear(editor) // appearing twice must not count twice
        store.surfaceDidDisappear(home)
        XCTAssertTrue(store.isViewing(thread), "もう一方の画面にまだ出ている")

        store.surfaceDidDisappear(editor)
        XCTAssertFalse(store.isViewing(thread))
        XCTAssertTrue(store.visibleSurfaces.isEmpty)
    }

    func testTheStoreFollowsTheAppsActiveState() {
        let (store, _) = makeStore()
        store.isAppActive = true

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(store.isAppActive)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(store.isAppActive)
    }

    // MARK: Answer-ready notifications

    /// Gives the "answer ready" task a moment to run (it is spawned, not awaited).
    private func letNotificationTasksRun() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    func testAnAnswerFinishingWhileNobodyIsLookingIsAnnouncedOnce() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        provider.chat = { _, _, _, _, onDelta in onDelta("答え") }
        store.activeDraft = "質問です"
        store.send()
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertEqual(delivered, ["質問です"])
    }

    func testNoNotificationWhenTheStudentIsLookingAtTheConversation() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        store.surfaceDidAppear(UUID())
        provider.chat = { _, _, _, _, onDelta in onDelta("答え") }
        store.activeDraft = "質問"
        store.send()
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertTrue(delivered.isEmpty, "見ている最中は通知しない")
    }

    func testAnAnswerFinishingInTheBackgroundIsAnnouncedEvenIfTheChatIsOnScreen() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        store.surfaceDidAppear(UUID())
        provider.chat = { _, _, _, _, onDelta in
            try await Task.sleep(for: .milliseconds(150))
            onDelta("答え")
        }
        store.activeDraft = "質問"
        store.send()
        store.isAppActive = false // locked / another app in front
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertEqual(delivered, ["質問"])
    }

    func testAnAnswerForAConversationThatIsNoLongerShownIsAnnounced() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        store.surfaceDidAppear(UUID())
        provider.chat = { _, _, _, _, onDelta in
            try await Task.sleep(for: .milliseconds(150))
            onDelta("答え")
        }
        store.activeDraft = "最初の質問"
        store.send()
        store.startNewThread() // the student moved on to a new talk meanwhile
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertEqual(delivered, ["最初の質問"])
    }

    func testCancelledFailedAndEmptyAnswersAreNotAnnounced() async {
        struct Boom: LocalizedError { var errorDescription: String? { "失敗" } }
        let (store, _) = makeStore()
        store.isAppActive = true

        provider.chat = { _, _, _, _, _ in throw Boom() }
        store.activeDraft = "失敗する"; store.send(); await settle(store)

        store.startNewThread()
        provider.chat = { _, _, _, _, _ in }
        store.activeDraft = "空の返答"; store.send(); await settle(store)

        store.startNewThread()
        provider.chat = { _, _, _, _, onDelta in
            onDelta("途中")
            try await Task.sleep(for: .seconds(30))
        }
        store.activeDraft = "中断する"; store.send()
        store.cancelResponse()
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertTrue(delivered.isEmpty)
    }

    func testAFinishedMarkingIsAnnounced() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        provider.review = ProofReviewResult(score: 9, maxScore: 10, verdict: "良い", criteria: [], issues: [])
        store.submitProof(ProofSubmission(questionText: "問題", answerText: "解答"))
        await settle(store)
        await letNotificationTasksRun()

        XCTAssertEqual(delivered, ["証明の添削"])
    }

    func testBringingAConversationIntoViewTakesItsNotificationAway() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        let first = await startThread(store, "一つ目")
        store.startNewThread()
        let second = await startThread(store, "二つ目")
        cleared = []

        store.surfaceDidAppear(UUID())
        XCTAssertEqual(cleared, ["二つ目"], "表示した会話の通知を消す")

        store.select(first)
        XCTAssertEqual(cleared, ["二つ目", "一つ目"], "表示する会話を切り替えたら、その会話の通知を消す")

        store.select(first)
        XCTAssertEqual(cleared.count, 2, "同じ会話を見続けている間は何度も消さない")
        _ = second
    }

    func testReturningToTheAppWhileViewingClearsTheNotification() async {
        let (store, _) = makeStore()
        store.isAppActive = true
        _ = await startThread(store, "質問")
        store.surfaceDidAppear(UUID())
        store.isAppActive = false
        cleared = []

        store.isAppActive = true

        XCTAssertEqual(cleared, ["質問"], "別アプリから戻って見える状態になったら通知を消す")
    }

    func testSelectingAConversationByTheKeyInANotification() async {
        let (store, _) = makeStore()
        let first = await startThread(store, "一つ目")
        let firstKey = AIChatStore.threadKey(first)
        store.startNewThread()
        _ = await startThread(store, "二つ目")

        XCTAssertTrue(store.selectThread(withKey: firstKey))
        XCTAssertTrue(store.selectedThread === first)

        XCTAssertFalse(store.selectThread(withKey: "消えた会話"))
        XCTAssertTrue(store.selectedThread === first, "存在しない会話ではそのまま")
    }

    func testNotificationIdentifierIsPerConversationAndCarriesTheKeyForTheTap() {
        XCTAssertEqual(AICompletionNotifications.identifier(forThreadKey: "k1"), "ai-complete-k1")
        XCTAssertNotEqual(
            AICompletionNotifications.identifier(forThreadKey: "k1"),
            AICompletionNotifications.identifier(forThreadKey: "k2"),
            "会話ごとに別の通知(同じ会話は置き換わる)"
        )
        XCTAssertEqual(AICompletionNotifications.threadKey(from: ["threadKey": "k1"]), "k1")
        XCTAssertNil(AICompletionNotifications.threadKey(from: ["route": "aiTaskComplete"]))
        XCTAssertNil(AICompletionNotifications.threadKey(from: nil))
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
