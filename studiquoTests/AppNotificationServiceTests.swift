import XCTest
@testable import studiquo

final class AppNotificationServiceTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testIncorrectFlashcardIsDueTheNextMorning() throws {
        let reviewed = Date(timeIntervalSince1970: 1_800_000_000)
        let due = FlashcardReviewNotifications.nextReviewDate(
            after: reviewed,
            mastery: 0,
            correct: false,
            calendar: utcCalendar
        )

        XCTAssertEqual(utcCalendar.dateComponents([.day], from: utcCalendar.startOfDay(for: reviewed), to: utcCalendar.startOfDay(for: due)).day, 1)
        XCTAssertEqual(utcCalendar.component(.hour, from: due), 9)
    }

    func testMasteredFlashcardUsesThirtyDayInterval() {
        let reviewed = Date(timeIntervalSince1970: 1_800_000_000)
        let due = FlashcardReviewNotifications.nextReviewDate(
            after: reviewed,
            mastery: 4,
            correct: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(utcCalendar.dateComponents([.day], from: utcCalendar.startOfDay(for: reviewed), to: utcCalendar.startOfDay(for: due)).day, 30)
    }

    func testEveryNotificationKindHasAUniquePreferenceAndCategoryIdentifier() {
        XCTAssertEqual(Set(AppNotificationKind.allCases.map(\.defaultsKey)).count, AppNotificationKind.allCases.count)
        XCTAssertEqual(Set(AppNotificationKind.allCases.map(\.categoryIdentifier)).count, AppNotificationKind.allCases.count)
    }

    /// The server filters a push by `device.preferences[category]`, and the
    /// category in the APNs payload is `studiquo.<rawValue>` — so these two
    /// names must match what mcp-server/src/announcements.js sends.
    func testAnnouncementKindMatchesTheServersCategory() {
        XCTAssertEqual(AppNotificationKind.announcement.rawValue, "announcement")
        XCTAssertEqual(AppNotificationKind.announcement.categoryIdentifier, "studiquo.announcement")
        XCTAssertNotNil(AppNotificationPreferences.serverPayload["announcement"])
    }
}
