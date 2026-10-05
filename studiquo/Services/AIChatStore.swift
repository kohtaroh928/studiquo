import Foundation
import SwiftData
import UIKit

/// Text builders for AIトーク messages. Pure, so both the store and the note
/// editor (which still forwards to these) share one wording.
enum AIChatFormatting {
    /// The user-visible message text, with a list of what was attached.
    static func messageText(_ text: String, with attachments: [AIChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let attachmentLines = attachments.map { attachment in
            "- \(attachment.kind.label): \(attachment.name)"
        }.joined(separator: "\n")
        return """
        \(text)

        \(L("添付された資料"))
        \(attachmentLines)
        """
    }

    /// What the student's side of the exchange says, so the thread reads as a
    /// conversation rather than starting with an answer to an invisible
    /// question.
    static func submissionSummary(_ submission: ProofSubmission) -> String {
        // Text halves are quoted; image halves are described in words rather
        // than left as a bare "（画像）" placeholder, so the student's bubble
        // reads like a request.
        func describe(text: String, image: Bool, label: String) -> String {
            if !text.isEmpty { return "【\(label)】\n\(text)" }
            if image { return L("【\(label)】画像を添付しました。") }
            return ""
        }
        var lines = [L("この証明を添削してください。"), ""]
        let question = describe(text: submission.questionText, image: submission.questionImage != nil, label: L("問題"))
        let answer = describe(text: submission.answerText, image: submission.answerImage != nil, label: L("解答"))
        if !question.isEmpty { lines.append(question); lines.append("") }
        if !answer.isEmpty { lines.append(answer) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lays the marking out as text, so it renders in an ordinary chat
    /// bubble and stays in the thread's history like any other reply.
    static func markingReport(_ review: ProofReviewResult) -> String {
        var lines = ["【\(review.score) / \(review.maxScore)点】", "", review.verdict, ""]
        // AI-generated grading can be wrong — a logically valid proof marked
        // down, or a flawed one marked correct — so every report says so up
        // front, not just once in a settings screen the student may never
        // open, before the score itself might be taken at face value.
        lines.append(L("※ この採点はAIによるものです。誤りを含むことがあるため、参考としてご利用ください。"))
        lines.append("")
        lines.append(L("■ 採点内訳"))
        for item in review.criteria {
            lines.append("・\(item.name)　\(item.earnedPoints)/\(item.maxPoints)点")
            if !item.comment.isEmpty { lines.append("　　\(item.comment)") }
        }
        if !review.issues.isEmpty {
            lines.append("")
            lines.append(L("■ 指摘"))
            for issue in review.issues {
                lines.append("・[\(issue.kind.title)] \(issue.excerpt)")
                lines.append("　　\(issue.explanation)")
                if !issue.suggestion.isEmpty { lines.append(L("　　→ \(issue.suggestion)")) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The state and logic of the AIトーク conversation, independent of any one
/// screen.
///
/// The note editor's chat pane, its floating panel and the home AI screen all
/// show the same conversations, drafts and "is replying" state, so that state
/// lives here once rather than in each view. The store knows nothing about
/// notes: the text of the page being looked at is handed to `send` by the
/// caller, and so is anything else that is specific to one screen.
@MainActor
final class AIChatStore: ObservableObject {
    /// Conversations that have at least one message, newest first.
    @Published private(set) var threads: [AIChatThread] = []
    /// The conversation on screen. `nil` means a new, not yet started one.
    @Published var selectedThread: AIChatThread? {
        didSet { refreshViewing() }
    }
    @Published private(set) var drafts: [String: String] = [:]
    @Published private(set) var attachments: [String: [AIChatAttachment]] = [:]
    @Published private(set) var contextOverrides: [String: String] = [:]
    /// Keys (see `threadKey`) of conversations that are being answered.
    @Published private(set) var respondingThreadIDs: Set<String> = []

    /// Tells the tab bar that this conversation is open, and what to call it.
    ///
    /// Sent again after each exchange because a thread is titled from its
    /// first message — without the repeat, every tab would read
    /// "新しいトーク" forever.
    var announceThread: (AIChatThread) -> Void = { thread in
        NotificationCenter.default.post(
            name: .studiquoOpenAIChatTab,
            object: AIChatTabInfo(id: thread.persistentModelID, title: thread.title)
        )
    }
    /// Tells the tab bar a conversation is gone.
    var closeThreadTab: (AIChatThread) -> Void = { thread in
        NotificationCenter.default.post(name: .studiquoCloseAIChatTab, object: thread.persistentModelID)
    }

    // MARK: Is anyone looking?

    /// The screens currently showing the conversation (the home AI tab, the
    /// editor's chat pane, its floating panel). Only a screen that is really
    /// on display is in here: a tab that merely exists in the tab bar, or a
    /// chat pane that is not the pane on screen, is not.
    @Published private(set) var visibleSurfaces: Set<UUID> = [] {
        didSet { refreshViewing() }
    }
    /// False while the app is in the background, the screen is locked or
    /// another app is in front.
    @Published var isAppActive: Bool {
        didSet { refreshViewing() }
    }

    /// Called when an answer finishes while nobody is looking at that
    /// conversation. Replaced in tests.
    var deliverCompletion: (AIChatThread) async -> Void = { thread in
        await AICompletionNotifications.deliver(
            threadTitle: thread.title,
            threadKey: AIChatStore.threadKey(thread)
        )
    }
    /// Called when a conversation comes into view, to take its "answer ready"
    /// notification away. Replaced in tests.
    var clearCompletion: (AIChatThread) -> Void = { thread in
        AICompletionNotifications.clear(threadKey: AIChatStore.threadKey(thread))
    }

    private let modelContext: ModelContext
    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastViewedKey: String?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// One store per model context, so every screen of the app that shares a
    /// container (the note editor's chat, the floating panel, the home AI
    /// screen) sees the same conversations, drafts and "replying" state.
    private static let registry = NSMapTable<ModelContext, AIChatStore>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func shared(for modelContext: ModelContext) -> AIChatStore {
        if let existing = registry.object(forKey: modelContext) { return existing }
        let store = AIChatStore(modelContext: modelContext)
        registry.setObject(store, forKey: modelContext)
        return store
    }

    /// The draft key used before any conversation exists.
    static let newThreadKey = "new"

    init(modelContext: ModelContext, isAppActive: Bool? = nil) {
        self.modelContext = modelContext
        self.isAppActive = isAppActive ?? (UIApplication.shared.applicationState == .active)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAppActive = true }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAppActive = false }
            },
        ]
    }

    deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Visibility

    func surfaceDidAppear(_ id: UUID) {
        visibleSurfaces.insert(id)
    }

    func surfaceDidDisappear(_ id: UUID) {
        visibleSurfaces.remove(id)
    }

    /// The conversation the student can actually see right now, if any: one
    /// is selected, a chat screen is on display, and the app is in front.
    var viewedThread: AIChatThread? {
        guard isAppActive, !visibleSurfaces.isEmpty else { return nil }
        return selectedThread
    }

    /// Runs whenever what could be on screen changes: the moment a
    /// conversation comes into view, its notification is no longer needed.
    private func refreshViewing() {
        guard let thread = viewedThread else {
            lastViewedKey = nil
            return
        }
        let key = Self.threadKey(thread)
        guard key != lastViewedKey else { return }
        lastViewedKey = key
        clearCompletion(thread)
    }

    /// An answer is ready. Tell the student unless they are looking at it.
    private func answerFinished(in thread: AIChatThread) {
        guard !isViewing(thread) else { return }
        let deliver = deliverCompletion
        Task { await deliver(thread) }
    }

    /// Whether `thread` is on screen in front of the student. A reply that
    /// finishes while this is false is worth a notification.
    func isViewing(_ thread: AIChatThread) -> Bool {
        viewedThread?.persistentModelID == thread.persistentModelID
    }

    #if DEBUG
    /// What UI tests read to see the real screens register and unregister.
    var debugViewingDescription: String {
        "screens=\(visibleSurfaces.count);viewing=\(viewedThread?.title ?? "-")"
    }
    #endif

    // MARK: Keys and per-conversation state

    static func threadKey(_ thread: AIChatThread) -> String {
        String(describing: thread.persistentModelID)
    }

    var activeDraftKey: String {
        selectedThread.map(Self.threadKey) ?? Self.newThreadKey
    }

    var activeDraft: String {
        get { drafts[activeDraftKey] ?? "" }
        set { drafts[activeDraftKey] = newValue }
    }

    var activeAttachments: [AIChatAttachment] {
        get { attachments[activeDraftKey] ?? [] }
        set { attachments[activeDraftKey] = newValue }
    }

    func setContextOverride(_ text: String?, forKey key: String) {
        contextOverrides[key] = text
    }

    func isResponding(_ thread: AIChatThread) -> Bool {
        respondingThreadIDs.contains(Self.threadKey(thread))
    }

    // MARK: Conversations

    func loadThreads() {
        let descriptor = FetchDescriptor<AIChatThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        threads = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !$0.sortedMessages.isEmpty }
    }

    func select(_ thread: AIChatThread) {
        selectedThread = thread
    }

    /// Selects the conversation a notification was about. Returns false when
    /// it no longer exists (it was deleted), leaving the selection unchanged.
    @discardableResult
    func selectThread(withKey key: String) -> Bool {
        loadThreads()
        guard let thread = threads.first(where: { Self.threadKey($0) == key }) else { return false }
        selectedThread = thread
        return true
    }

    /// Called when a screen showing the conversations appears: refreshes the
    /// list and, if nothing is selected, picks up the most recent one, the
    /// same way the note editor does when its chat opens.
    func prepareForDisplay() {
        loadThreads()
        if selectedThread == nil { selectedThread = threads.first }
    }

    /// Leaves the current conversation and starts an empty one.
    func startNewThread() {
        selectedThread = nil
        drafts[Self.newThreadKey] = ""
        attachments[Self.newThreadKey] = []
        contextOverrides[Self.newThreadKey] = nil
    }

    private func threadForSending() -> AIChatThread {
        if let selectedThread { return selectedThread }
        let thread = AIChatThread()
        modelContext.insert(thread)
        // A new model has a temporary identifier until it is first saved.
        // Every key below (replying, drafts, tasks) is derived from it, so
        // save now; otherwise the keys recorded while the reply streams no
        // longer match the saved thread — the stop button never appeared and
        // a second message could be sent mid-reply.
        try? modelContext.save()
        selectedThread = thread
        return thread
    }

    // MARK: Sending

    /// Sends the draft (or `text`) to the selected conversation, creating one
    /// if none is selected, and streams the reply into it.
    ///
    /// `noteContext` is whatever the calling screen knows about what the
    /// student is looking at — the home screen passes nothing.
    func send(
        draftKey overrideDraftKey: String? = nil,
        text overrideText: String? = nil,
        attachments overrideAttachments: [AIChatAttachment]? = nil,
        noteContext: String = ""
    ) {
        let draftKey = overrideDraftKey ?? activeDraftKey
        let trimmed = (overrideText ?? drafts[draftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sentAttachments = overrideAttachments ?? attachments[draftKey] ?? []
        let thread = threadForSending()
        let threadKey = Self.threadKey(thread)
        guard !respondingThreadIDs.contains(threadKey) else { return }

        let userMessage = AIChatMessage(text: AIChatFormatting.messageText(trimmed, with: sentAttachments), role: .user)
        userMessage.thread = thread
        thread.addMessage(userMessage)

        if thread.sortedMessages.filter({ $0.role == .user }).count == 1 {
            thread.title = String(trimmed.prefix(24))
        }

        // The reply is appended empty and filled in as the stream arrives, so
        // the answer appears as it is written instead of after a blank wait.
        let reply = AIChatMessage(text: "", role: .assistant)
        reply.thread = thread
        thread.addMessage(reply)
        thread.updatedAt = .now
        drafts[draftKey] = ""
        drafts[threadKey] = ""
        attachments[draftKey] = []
        attachments[threadKey] = []
        let contextOverride = contextOverrides[draftKey] ?? contextOverrides[threadKey] ?? ""
        let attachmentContext = sentAttachments
            .map { attachment -> String in
                let text = attachment.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return "" }
                return "【\(attachment.name)】\n\(text)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        contextOverrides[draftKey] = nil
        contextOverrides[threadKey] = nil
        try? modelContext.save()
        loadThreads()
        selectedThread = thread
        announceThread(thread)

        let history = thread.sortedMessages
            .filter { $0 !== reply }
            .map { AITurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
            .filter { !$0.text.isEmpty }
        // Only material explicitly attached or selected for this message leaves
        // the device. Merely opening a note does not authorize uploading it.
        let context = [contextOverride, attachmentContext]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let images = sentAttachments.compactMap(\.image)
        let expectsImages = sentAttachments.contains { $0.kind == .snippet || $0.kind == .camera }

        respondingThreadIDs.insert(threadKey)
        tasks[threadKey] = Task { @MainActor in
            defer {
                respondingThreadIDs.remove(threadKey)
                tasks[threadKey] = nil
            }
            do {
                try await AI.provider.streamChat(
                    turns: history,
                    noteContext: context,
                    images: images,
                    expectsImages: expectsImages
                ) { delta in
                    reply.text += delta
                }
                if reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reply.text = L("返答が空でした。もう一度試してください。")
                } else {
                    answerFinished(in: thread)
                }
                // Fire-and-forget: researches whether this question is worth
                // reviewing tomorrow, independently of this task so it never
                // delays clearing `respondingThreadIDs` above.
                Task { @MainActor in
                    await AIReviewService.considerForReview(
                        questionText: trimmed,
                        threadTitle: thread.title,
                        askedAt: userMessage.createdAt,
                        modelContext: modelContext
                    )
                }
            } catch is CancellationError {
                reply.text += reply.text.isEmpty ? L("（中断しました）") : L("（中断しました）")
            } catch {
                reply.text = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            thread.updatedAt = .now
            try? modelContext.save()
        }
    }

    /// Marks a proof, from whatever the student handed over.
    ///
    /// It runs as a normal exchange in the thread — a question from the
    /// student, an answer from the AI — so the marking stays in the
    /// conversation and can be asked about afterwards ("なぜここが減点なの？").
    ///
    /// Two calls, deliberately. A rubric is derived from the question alone
    /// first, and only then is the student's work looked at. Asking for a
    /// score in one shot makes the result drift between runs; fixing the
    /// criteria before the answer is visible is what makes two runs of the
    /// same page agree.
    func submitProof(_ submission: ProofSubmission) {
        guard submission.hasQuestion, submission.hasAnswer else { return }
        let thread = threadForSending()
        let threadKey = Self.threadKey(thread)
        guard !respondingThreadIDs.contains(threadKey) else { return }

        let userMessage = AIChatMessage(text: AIChatFormatting.submissionSummary(submission), role: .user)
        userMessage.thread = thread
        thread.addMessage(userMessage)

        if thread.sortedMessages.filter({ $0.role == .user }).count == 1 {
            thread.title = L("証明の添削")
        }

        let reply = AIChatMessage(text: L("採点基準を作っています…"), role: .assistant)
        reply.thread = thread
        thread.addMessage(reply)
        thread.updatedAt = .now
        try? modelContext.save()
        loadThreads()
        selectedThread = thread
        announceThread(thread)

        respondingThreadIDs.insert(threadKey)
        tasks[threadKey] = Task { @MainActor in
            defer {
                respondingThreadIDs.remove(threadKey)
                tasks[threadKey] = nil
            }
            do {
                let rubric = try await AI.provider.buildRubric(for: submission)
                try Task.checkCancellation()
                reply.text = L("答案を読んでいます…")
                let review = try await AI.provider.grade(submission, rubric: rubric)
                reply.text = AIChatFormatting.markingReport(review)
                answerFinished(in: thread)
            } catch is CancellationError {
                reply.text = L("（中断しました）")
            } catch {
                reply.text = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            thread.updatedAt = .now
            try? modelContext.save()
        }
    }

    // MARK: Stopping and deleting

    /// Stops the reply being written to the selected conversation.
    func cancelResponse() {
        guard let selectedThread else { return }
        let threadKey = Self.threadKey(selectedThread)
        tasks[threadKey]?.cancel()
        tasks[threadKey] = nil
        respondingThreadIDs.remove(threadKey)
    }

    func delete(_ thread: AIChatThread) {
        closeThreadTab(thread)
        let threadKey = Self.threadKey(thread)
        tasks[threadKey]?.cancel()
        tasks[threadKey] = nil
        respondingThreadIDs.remove(threadKey)
        drafts[threadKey] = nil
        attachments[threadKey] = nil
        contextOverrides[threadKey] = nil

        if selectedThread?.persistentModelID == thread.persistentModelID {
            selectedThread = nil
        }

        modelContext.delete(thread)
        try? modelContext.save()
        loadThreads()

        if selectedThread == nil {
            selectedThread = threads.first
        }
    }
}
