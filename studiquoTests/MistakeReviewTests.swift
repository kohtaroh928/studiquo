import XCTest
@testable import studiquo

final class MistakeReviewTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed instant

    private func card() -> Flashcard { Flashcard(question: "Q", answer: "A", order: 0) }

    private func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? -1
    }

    // MARK: Policy

    func testWrongAnswerPutsCardOnMissedListDueTomorrowAtNotificationHour() {
        let c = card()
        MistakeReviewPolicy.record(correct: false, on: c, at: now, hour: 8, calendar: calendar)
        XCTAssertTrue(c.needsReview)
        XCTAssertEqual(c.reviewStreak, 0)
        let due = try! XCTUnwrap(c.retryDueAt)
        XCTAssertEqual(days(from: now, to: due), 1)
        XCTAssertEqual(calendar.component(.hour, from: due), 8)
    }

    func testCardGraduatesAfterTwoConsecutiveCorrectAnswers() {
        let c = card()
        MistakeReviewPolicy.record(correct: false, on: c, at: now, hour: 9, calendar: calendar)
        MistakeReviewPolicy.record(correct: true, on: c, at: now, hour: 9, calendar: calendar)
        XCTAssertTrue(c.needsReview)
        XCTAssertEqual(days(from: now, to: try! XCTUnwrap(c.retryDueAt)), 3)
        MistakeReviewPolicy.record(correct: true, on: c, at: now, hour: 9, calendar: calendar)
        XCTAssertFalse(c.needsReview)
        XCTAssertNil(c.retryDueAt)
    }

    func testWrongAnswerMidwayResetsToFirstInterval() {
        let c = card()
        MistakeReviewPolicy.record(correct: false, on: c, at: now, hour: 9, calendar: calendar)
        MistakeReviewPolicy.record(correct: true, on: c, at: now, hour: 9, calendar: calendar)
        MistakeReviewPolicy.record(correct: false, on: c, at: now, hour: 9, calendar: calendar)
        XCTAssertEqual(c.reviewStreak, 0)
        XCTAssertEqual(c.retryStage, 0)
        XCTAssertEqual(days(from: now, to: try! XCTUnwrap(c.retryDueAt)), 1)
    }

    func testCorrectAnswerOnHealthyCardDoesNotAddItToMissedList() {
        let c = card()
        MistakeReviewPolicy.record(correct: true, on: c, at: now, hour: 9, calendar: calendar)
        XCTAssertFalse(c.needsReview)
        XCTAssertNil(c.retryDueAt)
    }

    func testDueCardsExcludesFutureAndHealthyCards() {
        let due = card(); due.needsReview = true; due.retryDueAt = now.addingTimeInterval(-60)
        let future = card(); future.needsReview = true; future.retryDueAt = now.addingTimeInterval(86_400)
        let healthy = card()
        let legacy = card(); legacy.needsReview = true // no date: treated as due
        let result = MistakeReviewPolicy.dueCards(in: [due, future, healthy, legacy], at: now)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: Notification plan

    private func snapshot(
        deck: String = "d1", title: String = "Deck", question: String = "What?",
        regular: Date? = nil, missed: Bool = false, retry: Date? = nil
    ) -> FlashcardReviewSnapshot {
        FlashcardReviewSnapshot(deckKey: deck, deckTitle: title, question: question, regularDue: regular, needsReview: missed, retryDueAt: retry)
    }

    private func plan(_ snapshots: [FlashcardReviewSnapshot], frequency: MistakeReviewFrequency = .daily,
                      enabled: Bool = true, showsQuestion: Bool = true) -> [PlannedFlashcardNotification] {
        FlashcardReviewNotifications.plan(
            snapshots: snapshots, now: now, calendar: calendar,
            mistakeReviewEnabled: enabled, hour: 9, frequency: frequency, showsQuestion: showsQuestion
        )
    }

    func testMissedCardsProduceOneMistakeNotificationPerDayTargetingTheDeck() {
        let tomorrow = now.addingTimeInterval(86_400)
        let result = plan([snapshot(deck: "a", missed: true, retry: tomorrow)])
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy(\.isMistakeReview))
        XCTAssertEqual(result.first?.deckKey, "a")
        XCTAssertEqual(Set(result.map(\.day)).count, result.count)
    }

    func testFewMissedCardsShowQuestionTextAndManyShowOnlyCount() {
        let detailed = plan([snapshot(question: "photosynthesis?", missed: true, retry: now)])
        XCTAssertTrue(detailed.first?.body.contains("photosynthesis?") ?? false)

        let many = (0..<4).map { _ in snapshot(question: "secret", missed: true, retry: now) }
        XCTAssertFalse(plan(many).first?.body.contains("secret") ?? true)

        XCTAssertFalse(plan([snapshot(question: "secret", missed: true, retry: now)], showsQuestion: false).first?.body.contains("secret") ?? true)
    }

    func testMistakeNotificationReplacesRegularOneOnTheSameDay() {
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400 + 3600)
        let result = plan([
            snapshot(missed: true, retry: tomorrow),
            snapshot(regular: tomorrow),
        ])
        let sameDay = result.filter { $0.day == calendar.startOfDay(for: tomorrow) }
        XCTAssertEqual(sameDay.count, 1)
        XCTAssertTrue(sameDay[0].isMistakeReview)
    }

    func testDisabledMistakeReviewFallsBackToRegularCounts() {
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400 + 3600)
        let result = plan([snapshot(regular: tomorrow, missed: true, retry: tomorrow)], enabled: false)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isMistakeReview)
    }

    func testFrequencyEveryOtherDayAndThreshold() {
        let snaps = [snapshot(missed: true, retry: now)]
        let daily = plan(snaps)
        let every = plan(snaps, frequency: .everyOtherDay)
        XCTAssertGreaterThan(daily.count, every.count)
        for pair in zip(every, every.dropFirst()) {
            XCTAssertGreaterThanOrEqual(days(from: pair.0.day, to: pair.1.day), 2)
        }
        XCTAssertTrue(plan(snaps, frequency: .whenFiveOrMore).isEmpty)
        let five = (0..<5).map { _ in snapshot(missed: true, retry: now) }
        XCTAssertFalse(plan(five, frequency: .whenFiveOrMore).isEmpty)
    }

    func testNeverSchedulesMoreThanSixtyRequests() {
        let snaps = (1...90).map { snapshot(regular: now.addingTimeInterval(Double($0) * 86_400)) }
        XCTAssertLessThanOrEqual(plan(snaps).count, 60)
    }
}
