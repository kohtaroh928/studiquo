import XCTest
@testable import studiquo

/// Regression coverage for the confirmation quiz's results screen
/// (`AIReviewQuizView`'s percentage ring) — category 5 ("復習画面・クイズ画面")
/// of the test plan: correct rounding, and no divide-by-zero if a quiz is
/// somehow shown with zero questions.
final class AIReviewQuizScoringTests: XCTestCase {
    func testAllCorrectIsOneHundredPercent() {
        XCTAssertEqual(quizScorePercentage(correct: 5, total: 5), 100)
    }

    func testAllIncorrectIsZeroPercent() {
        XCTAssertEqual(quizScorePercentage(correct: 0, total: 5), 0)
    }

    func testPartialScoreRoundsToTheNearestPercent() {
        // 2/3 = 66.66...% — must round to 67, not truncate to 66.
        XCTAssertEqual(quizScorePercentage(correct: 2, total: 3), 67)
        // 1/3 = 33.33...% — rounds down to 33.
        XCTAssertEqual(quizScorePercentage(correct: 1, total: 3), 33)
    }

    /// `AIReviewDetailView` only shows the クイズを受ける button when
    /// `item.quiz` is non-empty, so this shouldn't be reachable in the app —
    /// but the underlying formula divides by `total`, so it must not crash
    /// if it's ever called with zero anyway.
    func testZeroQuestionsDoesNotDivideByZero() {
        XCTAssertEqual(quizScorePercentage(correct: 0, total: 0), 0)
    }

    func testASingleQuestionAnsweredCorrectlyIsOneHundredPercent() {
        XCTAssertEqual(quizScorePercentage(correct: 1, total: 1), 100)
    }

    func testProofSubmissionAcceptsTypedOrImageQuestionAndAnswer() {
        XCTAssertTrue(ProofSubmission(questionText: "証明せよ", answerText: "証明").hasQuestion)
        XCTAssertTrue(ProofSubmission(questionText: "証明せよ", answerText: "証明").hasAnswer)

        let image = UIImage(systemName: "doc.text")
        XCTAssertTrue(ProofSubmission(questionImage: image, answerImage: image).hasQuestion)
        XCTAssertTrue(ProofSubmission(questionImage: image, answerImage: image).hasAnswer)
        XCTAssertFalse(ProofSubmission().hasQuestion)
        XCTAssertFalse(ProofSubmission().hasAnswer)
    }

    func testProofSubmissionSummaryShowsBothSelectedImages() {
        let image = UIImage(systemName: "doc.text")
        let summary = NoteEditorView.submissionSummary(
            ProofSubmission(questionImage: image, answerImage: image)
        )

        XCTAssertTrue(summary.contains("この証明を添削してください。"))
        XCTAssertTrue(summary.contains("【問題】画像を添付しました。"))
        XCTAssertTrue(summary.contains("【解答】画像を添付しました。"))
    }

    func testMarkingReportDisplaysScoreBreakdownIssuesAndAICaution() {
        let review = ProofReviewResult(
            score: 7,
            maxScore: 10,
            verdict: "概ね正しいです。",
            criteria: [
                ProofCriterionResult(name: "論理", earnedPoints: 4, maxPoints: 5, comment: "一段補足してください。")
            ],
            issues: [
                ProofIssue(
                    step: 2,
                    kindRawValue: ProofIssue.Kind.logicalGap.rawValue,
                    excerpt: "したがって",
                    explanation: "根拠が省略されています。",
                    suggestion: "使った定理を書いてください。"
                )
            ]
        )

        let report = NoteEditorView.markingReport(review)

        XCTAssertTrue(report.contains("【7 / 10点】"))
        XCTAssertTrue(report.contains("論理　4/5点"))
        XCTAssertTrue(report.contains("[論理の飛躍] したがって"))
        XCTAssertTrue(report.contains("AIによるものです"), "AI採点結果には注意書きを必ず表示する必要があります。")
    }
}
