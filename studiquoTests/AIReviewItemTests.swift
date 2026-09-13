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

    /// `nextReviewDate` takes a `calendar` parameter specifically so a test
    /// can supply one in a DST-observing time zone rather than depending on
    /// whatever zone the test machine happens to be in. The actual
    /// transition date is asked from `TimeZone` itself
    /// (`nextDaylightSavingTimeTransition(after:)`) rather than hard-coded,
    /// so the test doesn't silently stop exercising a real transition if the
    /// US changes its DST rules again.
    private func nextDSTTransition(in timeZone: TimeZone, after searchStart: Date) throws -> Date {
        try XCTUnwrap(
            timeZone.nextDaylightSavingTimeTransition(after: searchStart),
            "Expected \(timeZone.identifier) to have a DST transition after \(searchStart)."
        )
    }

    /// Regression guard: `nextReviewDate` used to compute the next day via
    /// `Calendar.date(byAdding: .day, ...)` and then re-derive the hour with
    /// `bySettingHour`, specifically so a raw 24-hour interval add (which
    /// would drift by an hour across a DST boundary) never crept back in.
    /// This pins that down against a real transition instead of trusting
    /// the implementation not to regress silently.
    func testNextReviewDateStaysAtNineAMAcrossTheSpringForwardTransition() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let searchStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let transition = try nextDSTTransition(in: timeZone, after: searchStart)
        try assertNextReviewDateLandsAtNineAM(crossing: transition, calendar: calendar)
    }

    func testNextReviewDateStaysAtNineAMAcrossTheFallBackTransition() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Search from mid-year so this finds the fall-back transition
        // (November), not the spring-forward one already covered above.
        let searchStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        let transition = try nextDSTTransition(in: timeZone, after: searchStart)
        try assertNextReviewDateLandsAtNineAM(crossing: transition, calendar: calendar)
    }

    /// Asks a question at 8pm local time the calendar day before `transition`,
    /// so the scheduled review — the following day at 9am — lands on or
    /// after the DST change itself, and checks it's still exactly 9:00 local.
    private func assertNextReviewDateLandsAtNineAM(crossing transition: Date, calendar: Calendar) throws {
        let transitionDayStart = calendar.startOfDay(for: transition)
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: transitionDayStart))
        let askedAt = try XCTUnwrap(calendar.date(bySettingHour: 20, minute: 0, second: 0, of: dayBefore))

        let reviewDate = AIReviewService.nextReviewDate(after: askedAt, calendar: calendar)

        let components = calendar.dateComponents([.hour, .minute], from: reviewDate)
        XCTAssertEqual(components.hour, 9, "DSTの切り替えをまたいでも、現地時間の午前9時である必要があります。")
        XCTAssertEqual(components.minute, 0)

        let expectedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: askedAt)))
        XCTAssertTrue(calendar.isDate(reviewDate, inSameDayAs: expectedDay))
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
