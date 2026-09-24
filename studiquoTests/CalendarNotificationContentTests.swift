import XCTest
@testable import studiquo

final class CalendarNotificationContentTests: XCTestCase {
    func testCalendarFeedNotificationUsesEventTitleAndStartEndTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(90 * 60)
        let event = CalendarEvent(title: "数学の小テスト", startDate: start, endDate: end, kind: .test, notes: "持ち物あり")

        let notification = studyNotification(forCalendarEvent: event, now: start.addingTimeInterval(-3_600))

        XCTAssertEqual(notification.title, "数学の小テスト")
        XCTAssertNotEqual(notification.title, "予定を確認しましょう")
        XCTAssertTrue(notification.message.contains(start.formatted(date: .omitted, time: .shortened)))
        XCTAssertTrue(notification.message.contains(end.formatted(date: .omitted, time: .shortened)))
        XCTAssertTrue(notification.message.contains("〜"))
    }

    func testCalendarReminderBodyContainsStartAndEndTimeOnly() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(45 * 60)
        let event = CalendarEvent(title: "英語", startDate: start, endDate: end, kind: .classLesson)

        let body = calendarEventReminderBody(for: event)

        XCTAssertTrue(body.contains(start.formatted(date: .omitted, time: .shortened)))
        XCTAssertTrue(body.contains(end.formatted(date: .omitted, time: .shortened)))
        XCTAssertFalse(body.contains("予定を確認しましょう"))
        XCTAssertFalse(body.contains("もうすぐ予定です"))
    }
}
