import SwiftData
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class ProofGradingAndRubricLifecycleTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var consentSuiteName = ""

    override func setUp() {
        super.setUp()
        consentSuiteName = "ProofGradingLifecycleTests-\(UUID().uuidString)"
        AIDataDisclosure.defaults = UserDefaults(suiteName: consentSuiteName)!
        AIDataDisclosure.acknowledge(ageBand: .adult)
        AIReviewService.scheduleNotification = { _ in }
    }

    override func tearDown() async throws {
        try? await Task.sleep(for: .milliseconds(80))
        AI.provider = WorkerAIProvider()
        AIReviewService.scheduleNotification = { await AIReviewNotifications.schedule(for: $0) }
        AIDataDisclosure.defaults.removePersistentDomain(forName: consentSuiteName)
        AIDataDisclosure.defaults = .standard
        try await super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Notebook.self,
            NotePage.self,
            PageElement.self,
            AIChatThread.self,
            AIChatMessage.self,
            TextDocument.self,
            AIReviewItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        Self.retainedContainers.append(container)
        return ModelContext(container)
    }

    // MARK: - 1. Two-stage proof grading order and cancellation between stages

    func testSubmitProofRunsBuildRubricBeforeGradeAndPassesConstructedRubric() async throws {
        let context = try makeContext()
        let store = AIChatStore(modelContext: context)

        var callOrder: [String] = []
        let expectedRubric = ProofRubric(criteria: [
            ProofCriterion(name: "基底段階", maxPoints: 30, requirement: "n=1 の成立を示す"),
            ProofCriterion(name: "帰納段階", maxPoints: 70, requirement: "n=k を仮定し n=k+1 を示す"),
        ])

        let provider = StageTrackingAIProvider(
            onBuildRubric: { submission in
                callOrder.append("buildRubric:\(submission.questionText)")
                return expectedRubric
            },
            onGrade: { submission, rubric in
                callOrder.append("grade:\(submission.answerText):\(rubric.totalPoints)")
                XCTAssertEqual(rubric, expectedRubric)
                return ProofReviewResult(
                    score: 85,
                    maxScore: 100,
                    verdict: "帰納法の骨格は正しいですが、n=k+1 の式変形に1箇所説明不足があります。",
                    criteria: [
                        ProofCriterionResult(name: "基底段階", earnedPoints: 30, maxPoints: 30, comment: "明確です"),
                        ProofCriterionResult(name: "帰納段階", earnedPoints: 55, maxPoints: 70, comment: "途中の等号の根拠が必要"),
                    ],
                    issues: [
                        ProofIssue(
                            step: 2,
                            kindRawValue: ProofIssue.Kind.logicalGap.rawValue,
                            excerpt: "よって成り立つ",
                            explanation: "左辺から右辺への変形が省略されています",
                            suggestion: "帰納法の仮定を代入した式を1行明記しましょう"
                        ),
                    ]
                )
            }
        )
        AI.provider = provider

        store.submitProof(ProofSubmission(questionText: "数学的帰納法で示せ", answerText: "n=1のとき成立。よって成り立つ"))

        let deadline = Date().addingTimeInterval(3)
        while !store.respondingThreadIDs.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(callOrder, [
            "buildRubric:数学的帰納法で示せ",
            "grade:n=1のとき成立。よって成り立つ:100",
        ])
        let report = try XCTUnwrap(store.selectedThread?.sortedMessages.last?.text)
        XCTAssertTrue(report.contains("【85 / 100点】"))
        XCTAssertTrue(report.contains("・基底段階　30/30点"))
        XCTAssertTrue(report.contains("・[論理の飛躍] よって成り立つ"))
        XCTAssertTrue(report.contains("→ 帰納法の仮定を代入した式を1行明記しましょう"))
    }

    func testCancellingSubmitProofDuringRubricStageSkipsGradeAndMarksInterrupted() async throws {
        let context = try makeContext()
        let store = AIChatStore(modelContext: context)

        var gradeCalled = false
        let provider = StageTrackingAIProvider(
            onBuildRubric: { _ in
                try await Task.sleep(for: .seconds(30))
                return ProofRubric(criteria: [])
            },
            onGrade: { _, _ in
                gradeCalled = true
                return ProofReviewResult(score: 0, maxScore: 100, verdict: "", criteria: [], issues: [])
            }
        )
        AI.provider = provider

        store.submitProof(ProofSubmission(questionText: "問題", answerText: "解答"))
        let thread = try XCTUnwrap(store.selectedThread)
        XCTAssertTrue(store.isResponding(thread))

        store.cancelResponse()

        let deadline = Date().addingTimeInterval(3)
        while thread.sortedMessages.last?.text != "（中断しました）" && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(gradeCalled, "Cancelling during Stage 1 (buildRubric) must never invoke Stage 2 (grade)")
        XCTAssertEqual(thread.sortedMessages.last?.text, "（中断しました）")
    }

    // MARK: - 2. NotePage proof rubric cache and source-hash invalidation

    func testNotePageProofRubricCacheIsInvalidatedWhenModelAnswerChanges() throws {
        let context = try makeContext()
        let page = NotePage(order: 0)
        context.insert(page)

        let originalAnswer = "背理法により √2 = p/q (互いに素) とおくと矛盾する。"
        let rubric = ProofRubric(criteria: [
            ProofCriterion(name: "互いに素の設定", maxPoints: 40, requirement: "既約分数でおく"),
            ProofCriterion(name: "偶奇の矛盾", maxPoints: 60, requirement: "p, q がともに偶数となり矛盾"),
        ])

        page.proofQuestion = "√2 が無理数であることを証明せよ"
        page.proofModelAnswer = originalAnswer
        page.proofRubricData = try JSONEncoder().encode(rubric)
        page.proofRubricSourceHash = originalAnswer.hashValue

        let review = ProofReviewResult(score: 90, maxScore: 100, verdict: "良好", criteria: [], issues: [])
        page.proofReviewData = try JSONEncoder().encode(review)
        page.proofReviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try context.save()

        // Cache hit when modelAnswer is unchanged:
        XCTAssertEqual(page.proofModelAnswer.hashValue, page.proofRubricSourceHash)
        let decodedRubric = try JSONDecoder().decode(ProofRubric.self, from: XCTUnwrap(page.proofRubricData))
        XCTAssertEqual(decodedRubric.totalPoints, 100)
        XCTAssertEqual(decodedRubric.criteria.count, 2)

        // Editing the model answer changes its hash so the cached rubric is detected as stale:
        let editedAnswer = "素因数分解の一意性を用いて 2q^2 = p^2 の2の指数を比較する。"
        page.proofModelAnswer = editedAnswer
        XCTAssertNotEqual(
            page.proofModelAnswer.hashValue,
            page.proofRubricSourceHash,
            "Modifying proofModelAnswer must mismatch proofRubricSourceHash so stale rubric is invalidated"
        )
    }

    // MARK: - 3. All ProofIssue.Kind classifications, percentage edge cases, and report formatting

    func testAllProofIssueKindsPercentagesAndSubmissionSummaries() {
        let expectedTitlesAndTints: [(ProofIssue.Kind, String, String)] = [
            (.logicalGap, "論理の飛躍", "orange"),
            (.counterexample, "反例あり", "red"),
            (.definitionError, "定義の誤り", "red"),
            (.calculationError, "計算ミス", "orange"),
            (.unjustifiedAssumption, "根拠のない仮定", "orange"),
            (.presentation, "書き方", "gray"),
        ]
        XCTAssertEqual(ProofIssue.Kind.allCases.count, expectedTitlesAndTints.count)
        for (kind, expectedTitle, expectedTint) in expectedTitlesAndTints {
            XCTAssertEqual(kind.title, expectedTitle)
            XCTAssertEqual(kind.tint, expectedTint)
        }

        // Unknown raw value falls back safely to .logicalGap:
        let unknownIssue = ProofIssue(
            step: 1,
            kindRawValue: "future_unknown_kind",
            excerpt: "x > 0",
            explanation: "理由不明",
            suggestion: ""
        )
        XCTAssertEqual(unknownIssue.kind, .logicalGap)
        XCTAssertTrue(unknownIssue.id.hasPrefix("1-future_unknown_kind-x > 0"))

        // Percentage calculation handles zero maxScore and rounds properly:
        let zeroMax = ProofReviewResult(score: 0, maxScore: 0, verdict: "", criteria: [], issues: [])
        XCTAssertEqual(zeroMax.percentage, 0)

        let rounded = ProofReviewResult(score: 2, maxScore: 3, verdict: "", criteria: [], issues: [])
        XCTAssertEqual(rounded.percentage, 67)

        // Submission summary prefers typed text over image placeholder when both exist:
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        let mixedSummary = AIChatFormatting.submissionSummary(
            ProofSubmission(questionText: "問題テキスト", questionImage: image, answerText: "", answerImage: image)
        )
        XCTAssertTrue(mixedSummary.contains("【問題】\n問題テキスト"))
        XCTAssertTrue(mixedSummary.contains("【解答】画像を添付しました。"))
    }
}

private final class StageTrackingAIProvider: AIProvider {
    var isConfigured = true
    var displayName = "StageTracking"

    let onBuildRubric: (ProofSubmission) async throws -> ProofRubric
    let onGrade: (ProofSubmission, ProofRubric) async throws -> ProofReviewResult

    init(
        onBuildRubric: @escaping (ProofSubmission) async throws -> ProofRubric,
        onGrade: @escaping (ProofSubmission, ProofRubric) async throws -> ProofReviewResult
    ) {
        self.onBuildRubric = onBuildRubric
        self.onGrade = onGrade
    }

    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage],
        expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {}

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        try await onBuildRubric(submission)
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        try await onGrade(submission, rubric)
    }

    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    }
}
