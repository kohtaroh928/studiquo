import XCTest
@testable import studiquo

/// Regression coverage for the AI復習 entries in the bell-icon notification
/// feed (`aiReviewStudyNotifications`, extracted from
/// `ContentView.makeStudyNotifications` specifically so it's testable here).
final class AIReviewNotificationFeedTests: XCTestCase {
    private func item(questionText: String = "質問", reviewDate: Date) -> AIReviewItem {
        AIReviewItem(
            questionText: questionText,
            threadTitle: "スレッド",
            createdAt: reviewDate.addingTimeInterval(-86_400),
            reviewDate: reviewDate,
            explanationMarkdown: "解説",
            quiz: []
        )
    }

    func testAReviewNotDueYetDoesNotAppearInTheFeed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let notDueYet = item(reviewDate: now.addingTimeInterval(3_600))

        let notifications = aiReviewStudyNotifications(from: [notDueYet], now: now)

        XCTAssertTrue(notifications.isEmpty)
    }

    func testAReviewWhoseDateHasArrivedAppearsInTheFeed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let due = item(questionText: "加法定理を教えて", reviewDate: now.addingTimeInterval(-60))

        let notifications = aiReviewStudyNotifications(from: [due], now: now)

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.destination, .aiReview)
        XCTAssertTrue(notifications.first?.message.contains("加法定理") ?? false)
    }

    /// A review becomes due exactly at `reviewDate`, not strictly after it —
    /// matters because the notification and the bell entry are meant to
    /// surface at the same moment.
    func testAReviewDueExactlyNowAppearsInTheFeed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let dueNow = item(reviewDate: now)

        let notifications = aiReviewStudyNotifications(from: [dueNow], now: now)

        XCTAssertEqual(notifications.count, 1)
    }

    /// Each item gets its own id from its own UUID, so two reviews due the
    /// same day don't collide or overwrite each other's read state.
    func testTwoDueReviewsGetDistinctFeedIDs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = item(questionText: "質問A", reviewDate: now)
        let second = item(questionText: "質問B", reviewDate: now)

        let notifications = aiReviewStudyNotifications(from: [first, second], now: now)

        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(Set(notifications.map(\.id)).count, 2)
    }

    func testFeedIDsCarryTheSharedAIReviewPrefixSoOpenNotificationCanParseThemBack() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let due = item(reviewDate: now)

        let notification = aiReviewStudyNotifications(from: [due], now: now).first

        XCTAssertEqual(notification?.id, aiReviewNotificationID(for: due))
        XCTAssertTrue(notification?.id.hasPrefix(aiReviewNotificationIDPrefix) ?? false)
        let uuidPart = notification?.id.dropFirst(aiReviewNotificationIDPrefix.count)
        XCTAssertEqual(uuidPart.flatMap { UUID(uuidString: String($0)) }, due.id)
    }
}
