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
}
