import SwiftData
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class AIConsentGateAndNormalFeaturesTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var consentSuiteName = ""

    override func setUp() {
        super.setUp()
        consentSuiteName = "AIConsentGateTests-\(UUID().uuidString)"
        AIDataDisclosure.defaults = UserDefaults(suiteName: consentSuiteName)!
        AIReviewService.scheduleNotification = { _ in }
    }

    override func tearDown() async throws {
        try? await Task.sleep(for: .milliseconds(80))
        AI.provider = WorkerAIProvider()
        AIReviewService.scheduleNotification = { await AIReviewNotifications.schedule(for: $0) }
        UserDefaults.standard.removeObject(forKey: AIReviewService.isEnabledDefaultsKey)
        AIDataDisclosure.defaults.removePersistentDomain(forName: consentSuiteName)
        AIDataDisclosure.defaults = .standard
        try await super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Notebook.self,
            NotePage.self,
            PageElement.self,
            FlashcardDeck.self,
            Flashcard.self,
            TextDocument.self,
            AIReviewItem.self,
            Folder.self,
            AIChatThread.self,
            AIChatMessage.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        Self.retainedContainers.append(container)
        return ModelContext(container)
    }

    // MARK: - 1. WorkerAIProvider blocks all endpoints before network when consent is missing/revoked

    func testAllWorkerAIProviderRoutesRejectBeforeNetworkWhenConsentIsUnacknowledgedOrRevoked() async {
        AIDataDisclosure.revoke()
        let worker = WorkerAIProvider()
        let sampleSubmission = ProofSubmission(questionText: "x^2 >= 0 を示せ", answerText: "実数の平方は非負", modelAnswer: "実数の性質より")
        let sampleRubric = ProofRubric(criteria: [ProofCriterion(name: "平方非負", maxPoints: 100, requirement: "実数の平方 >= 0")])

        do {
            try await worker.streamChat(
                turns: [AITurn(role: .user, text: "質問")],
                noteContext: "",
                images: [],
                expectsImages: false,
                onDelta: { _ in XCTFail("Delta must not be emitted without consent") }
            )
            XCTFail("streamChat must throw consentRequired")
        } catch WorkerAIProvider.ProviderError.consentRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error from streamChat: \(error)")
        }

        do {
            _ = try await worker.buildRubric(for: sampleSubmission)
            XCTFail("buildRubric must throw consentRequired")
        } catch WorkerAIProvider.ProviderError.consentRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error from buildRubric: \(error)")
        }

        do {
            _ = try await worker.grade(sampleSubmission, rubric: sampleRubric)
            XCTFail("grade must throw consentRequired")
        } catch WorkerAIProvider.ProviderError.consentRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error from grade: \(error)")
        }

        do {
            _ = try await worker.researchReview(question: "微分とは", context: "")
            XCTFail("researchReview must throw consentRequired")
        } catch WorkerAIProvider.ProviderError.consentRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error from researchReview: \(error)")
        }

        let usage = await worker.usage()
        XCTAssertNil(usage, "usage() must return nil without network call when consent is not granted")
    }

    // MARK: - 2. Proof grading consent gate in AIChatStore

    func testSubmitProofGatedOnConsentHoldsSubmissionUntilAllowedOrRecordsErrorOnDecline() async throws {
        AIDataDisclosure.revoke()
        let context = try makeContext()
        let store = AIChatStore(modelContext: context)

        var rubricCalls = 0
        var gradeCalls = 0
        let mock = ClosureAIProvider(
            onBuildRubric: { _ in
                rubricCalls += 1
                return ProofRubric(criteria: [ProofCriterion(name: "論理", maxPoints: 10, requirement: "筋道")])
            },
            onGrade: { _, _ in
                gradeCalls += 1
                return ProofReviewResult(score: 10, maxScore: 10, verdict: "完璧です。", criteria: [], issues: [])
            }
        )
        AI.provider = mock

        let submission = ProofSubmission(questionText: "命題Pを示せ", answerText: "仮定よりPが成り立つ")
        store.submitProof(submission)

        // Before consent decision: held in pendingConsentSend, nothing sent or saved.
        XCTAssertNotNil(store.pendingConsentSend)
        XCTAssertNil(store.selectedThread)
        XCTAssertEqual(rubricCalls, 0)
        XCTAssertEqual(gradeCalls, 0)

        // Allowing resumes the proof submission and completes both stages.
        store.allowPendingSend(ageBand: .adult)
        XCTAssertNil(store.pendingConsentSend)
        XCTAssertTrue(AIDataDisclosure.hasBeenAcknowledged)

        let deadline = Date().addingTimeInterval(3)
        while !store.respondingThreadIDs.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rubricCalls, 1)
        XCTAssertEqual(gradeCalls, 1)
        XCTAssertTrue(store.selectedThread?.sortedMessages.last?.text.contains("【10 / 10点】") ?? false)

        // Now revoke and test declining in chat on a fresh store with WorkerAIProvider.
        AIDataDisclosure.revoke()
        AI.provider = WorkerAIProvider()
        let store2 = AIChatStore(modelContext: context)
        store2.submitProof(submission)
        XCTAssertNotNil(store2.pendingConsentSend)

        store2.declinePendingSend()
        XCTAssertNil(store2.pendingConsentSend)
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)

        let deadline2 = Date().addingTimeInterval(3)
        while !store2.respondingThreadIDs.isEmpty && Date() < deadline2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            store2.selectedThread?.sortedMessages.last?.text,
            WorkerAIProvider.ProviderError.consentRequired.errorDescription
        )
    }

    // MARK: - 3. In-flight consent revocation during AIReviewService.considerForReview

    func testRevokingConsentWhileReviewResearchIsInFlightDiscardsResultAndSkipsPersistence() async throws {
        AIDataDisclosure.acknowledge(ageBand: .adult)
        UserDefaults.standard.set(true, forKey: AIReviewService.isEnabledDefaultsKey)
        let context = try makeContext()

        var notificationsScheduled = 0
        AIReviewService.scheduleNotification = { _ in notificationsScheduled += 1 }

        let mock = ClosureAIProvider(
            onResearchReview: { _, _ in
                // User revokes AI consent while the network request is in flight.
                AIDataDisclosure.revoke()
                return AIReviewResult(
                    isStudyRelevant: true,
                    explanationMarkdown: "# 重要定理\n解説本文",
                    quiz: [AIQuizQuestion(question: "Q", answer: "A")]
                )
            }
        )
        AI.provider = mock

        await AIReviewService.considerForReview(
            questionText: "中間値の定理とは？",
            threadTitle: "解析学",
            askedAt: .now,
            modelContext: context
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIReviewItem>()), 0, "In-flight consent revocation must prevent saving AIReviewItem")
        XCTAssertEqual(notificationsScheduled, 0, "In-flight consent revocation must prevent scheduling review notification")
    }

    // MARK: - 4. Declining AI consent never restricts normal non-AI study features

    func testNormalNoteFlashcardHandwritingAndMathFeaturesWorkNormallyWhenAIConsentIsDeclined() async throws {
        AIDataDisclosure.revoke()
        AIDataDisclosure.declineInChat()
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)

        let context = try makeContext()

        // 1. Notebook & Page creation + editing
        let notebook = Notebook(title: "線形代数ノート")
        let page = NotePage(order: 0, pageWidth: 612, pageHeight: 792)
        page.notebook = notebook
        notebook.addPage(page)
        let stroke = InkStroke(
            points: [
                InkPoint(location: CGPoint(x: 40, y: 50), force: 1, timeOffset: 0),
                InkPoint(location: CGPoint(x: 140, y: 90), force: 1, timeOffset: 0.1),
            ],
            colorHex: "#000000",
            width: 4
        )
        let drawing = InkDrawing(strokes: [stroke])
        page.drawingData = try drawing.data()
        context.insert(notebook)
        context.insert(page)

        // 2. On-device handwriting recognition seam works without AI consent
        let recognized = await HandwritingRecognitionService.recognize(drawing: drawing) { cgImage in
            XCTAssertGreaterThan(cgImage.width, 0)
            return "det(A) != 0"
        }
        XCTAssertEqual(recognized, "det(A) != 0")

        // 3. Flashcard deck creation & study ordering
        let deck = FlashcardDeck(title: "基本公式")
        let card = Flashcard(question: "オイラーの公式", answer: "e^{iθ} = cosθ + i sinθ", order: 0)
        deck.addCard(card)
        context.insert(deck)
        context.insert(card)
        try context.save()
        XCTAssertEqual(deck.sortedCards.count, 1)

        // 4. Local math segmentation & formatting
        let segments = MathSegmenter.segments(in: "公式は $e^{i\\theta} = \\cos\\theta + i\\sin\\theta$ です。")
        XCTAssertEqual(segments, [
            .text("公式は "),
            .inlineMath("e^{i\\theta} = \\cos\\theta + i\\sin\\theta"),
            .text(" です。"),
        ])
        XCTAssertEqual(MathTextFormatter.readableMath(from: #"x^2 + 1 = 0"#), "x² + 1 = 0")
    }

    // MARK: - 5. Locked/protected notebooks never leak text into AI attachment catalog

    func testLockedNotebookDoesNotLeakSealedTextIntoAIAttachmentCatalog() throws {
        let context = try makeContext()
        let keyService = "com.yabuko.studiquo.test.ai-attachment-lock.\(UUID().uuidString)"
        defer { NotebookEncryptionKeyStore.deleteKey(service: keyService) }

        let notebook = Notebook(title: "秘密のノート")
        notebook.isLocked = true
        let page = NotePage(order: 0, backgroundImageData: Data([0x01, 0x02]))
        page.recognizedText = "極秘の証明テキスト"
        page.addElement(PageElement(kind: .text, text: "極秘のテキストボックス"))
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        context.insert(page)

        NotebookEncryptionService.lock(notebook, keyService: keyService)

        let option = try XCTUnwrap(AIAppAttachmentCatalog.notebookAttachmentOption(notebook))
        XCTAssertFalse(option.attachment.contextText.contains("極秘"), "Sealed notebook text must never leak into AI attachment context")
        XCTAssertEqual(option.attachment.contextText, "この資料には、AIが読める抽出済みテキストがまだありません。")
    }
}

private final class ClosureAIProvider: AIProvider {
    var isConfigured = true
    var displayName = "ClosureMock"

    var onBuildRubric: ((ProofSubmission) async throws -> ProofRubric)?
    var onGrade: ((ProofSubmission, ProofRubric) async throws -> ProofReviewResult)?
    var onResearchReview: ((String, String) async throws -> AIReviewResult)?

    init(
        onBuildRubric: ((ProofSubmission) async throws -> ProofRubric)? = nil,
        onGrade: ((ProofSubmission, ProofRubric) async throws -> ProofReviewResult)? = nil,
        onResearchReview: ((String, String) async throws -> AIReviewResult)? = nil
    ) {
        self.onBuildRubric = onBuildRubric
        self.onGrade = onGrade
        self.onResearchReview = onResearchReview
    }

    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage],
        expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        onDelta("ok")
    }

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        if let onBuildRubric { return try await onBuildRubric(submission) }
        return ProofRubric(criteria: [])
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        if let onGrade { return try await onGrade(submission, rubric) }
        return ProofReviewResult(score: 0, maxScore: 0, verdict: "", criteria: [], issues: [])
    }

    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        if let onResearchReview { return try await onResearchReview(question, context) }
        return AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    }
}
