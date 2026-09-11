import XCTest
@testable import studiquo

/// Regression coverage for the day-after AIトーク review feature: a question
/// judged worth reviewing is scheduled for a fixed hour the next day, and its
/// quiz round-trips through `AIReviewItem`'s JSON-encoded storage.
final class AIReviewItemTests: XCTestCase {
    func testNextReviewDateFallsOnTheFollowingDayAtNineAM() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 5
        components.hour = 14; components.minute = 32
        let askedAt = Calendar.current.date(from: components)!

        let reviewDate = AIReviewService.nextReviewDate(after: askedAt)

        let result = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reviewDate)
        XCTAssertEqual(result.year, 2026)
        XCTAssertEqual(result.month, 3)
        XCTAssertEqual(result.day, 6)
        XCTAssertEqual(result.hour, 9)
        XCTAssertEqual(result.minute, 0)
    }

    func testNextReviewDateCrossesAMonthBoundaryCorrectly() {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 31
        components.hour = 23; components.minute = 50
        let askedAt = Calendar.current.date(from: components)!

        let reviewDate = AIReviewService.nextReviewDate(after: askedAt)

        let result = Calendar.current.dateComponents([.year, .month, .day, .hour], from: reviewDate)
        XCTAssertEqual(result.month, 2)
        XCTAssertEqual(result.day, 1)
        XCTAssertEqual(result.hour, 9)
    }

    /// `AIReviewItem.quiz` decodes whatever was encoded at init — a mismatch
    /// here would silently drop the quiz the review screen shows.
    func testQuizRoundTripsThroughJSONEncodedStorage() {
        let quiz = [
            AIQuizQuestion(question: "sin(a+b) の展開は？", answer: "sin a cos b + cos a sin b"),
            AIQuizQuestion(question: "cos(a+b) の展開は？", answer: "cos a cos b - sin a sin b"),
        ]
        let item = AIReviewItem(
            questionText: "加法定理を教えて",
            threadTitle: "数学の質問",
            createdAt: .now,
            reviewDate: .now,
            explanationMarkdown: "# 加法定理\n- sin(a+b) = ...",
            quiz: quiz
        )

        XCTAssertEqual(item.quiz, quiz)
    }

    func testQuizIsEmptyRatherThanCrashingWhenNoQuizWasGenerated() {
        let item = AIReviewItem(
            questionText: "質問",
            threadTitle: "スレッド",
            createdAt: .now,
            reviewDate: .now,
            explanationMarkdown: "解説",
            quiz: []
        )

        XCTAssertEqual(item.quiz, [])
    }
}
