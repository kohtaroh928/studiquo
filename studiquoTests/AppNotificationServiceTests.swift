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

// MARK: - Banner settings

/// Whether each kind of notification shows as a banner (with sound) or lands
/// quietly in the notification centre, and how that reaches the three places
/// that present one: the foreground, a scheduled local notification, and the
/// device registration the server pushes from.
final class NotificationBannerPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "NotificationBannerPreferenceTests")!
        defaults.removePersistentDomain(forName: "NotificationBannerPreferenceTests")
    }

    func testBannersAreOnByDefaultForEveryKind() {
        for kind in AppNotificationKind.allCases {
            XCTAssertTrue(AppNotificationPreferences.isBannerEnabled(kind, in: defaults), "\(kind) は既定でバナーが出る必要があります。")
        }
    }

    func testTurningOffTheBannerKeepsTheNotificationButMakesItQuiet() {
        defaults.set(false, forKey: AppNotificationKind.friendMessage.bannerDefaultsKey)
        XCTAssertTrue(AppNotificationPreferences.isEnabled(.friendMessage, in: defaults))
        XCTAssertFalse(AppNotificationPreferences.isBannerEnabled(.friendMessage, in: defaults))
        // Only that kind is affected.
        XCTAssertTrue(AppNotificationPreferences.isBannerEnabled(.groupInvite, in: defaults))
    }

    func testBannerIsOffWheneverTheKindOrTheMasterSwitchIsOff() {
        defaults.set(false, forKey: AppNotificationKind.studyStreak.defaultsKey)
        XCTAssertFalse(AppNotificationPreferences.isBannerEnabled(.studyStreak, in: defaults))
        defaults.set(false, forKey: AppNotificationPreferences.masterDefaultsKey)
        XCTAssertFalse(AppNotificationPreferences.isBannerEnabled(.calendarDeadline, in: defaults))
    }

    func testForegroundPresentationFollowsTheKindsSettings() {
        let category = AppNotificationKind.calendarDeadline.categoryIdentifier
        XCTAssertEqual(AppNotificationPreferences.foregroundPresentation(forCategory: category, in: defaults), [.banner, .list, .sound])

        defaults.set(false, forKey: AppNotificationKind.calendarDeadline.bannerDefaultsKey)
        XCTAssertEqual(AppNotificationPreferences.foregroundPresentation(forCategory: category, in: defaults), [.list], "バナーをオフにすると、一覧にだけ入る必要があります。")

        defaults.set(false, forKey: AppNotificationKind.calendarDeadline.defaultsKey)
        XCTAssertEqual(AppNotificationPreferences.foregroundPresentation(forCategory: category, in: defaults), [], "通知をオフにすると何も出してはいけません。")
    }

    func testAnUnknownCategoryStillShowsABanner() {
        XCTAssertEqual(AppNotificationPreferences.foregroundPresentation(forCategory: "", in: defaults), [.banner, .list, .sound])
    }

    func testABuiltNotificationIsLoudOrPassiveAccordingToTheBannerSetting() {
        let loud = UNMutableNotificationContent()
        AppNotificationPreferences.applyPresentation(to: loud, kind: .flashcardReview, in: defaults)
        XCTAssertNotNil(loud.sound)
        XCTAssertEqual(loud.interruptionLevel, .active)
        XCTAssertEqual(loud.categoryIdentifier, AppNotificationKind.flashcardReview.categoryIdentifier)

        defaults.set(false, forKey: AppNotificationKind.flashcardReview.bannerDefaultsKey)
        let quiet = UNMutableNotificationContent()
        quiet.sound = .default
        AppNotificationPreferences.applyPresentation(to: quiet, kind: .flashcardReview, in: defaults)
        XCTAssertNil(quiet.sound, "バナーがオフなら音も鳴らしてはいけません。")
        XCTAssertEqual(quiet.interruptionLevel, .passive, "静かな通知は passive にして、画面を点灯させません。")
        XCTAssertEqual(quiet.categoryIdentifier, AppNotificationKind.flashcardReview.categoryIdentifier)
    }

    func testEveryKindIsReportedToTheServerWithItsBannerChoice() {
        // The server matches these names against the categories it pushes.
        let payload = AppNotificationPreferences.serverBannerPayload
        XCTAssertEqual(Set(payload.keys), Set(AppNotificationKind.allCases.map(\.rawValue)))
    }

    func testTheAIReviewNotificationHasItsOwnKindAndCanBeCancelled() {
        XCTAssertEqual(AppNotificationKind.aiReview.categoryIdentifier, "studiquo.aiReview")
        XCTAssertEqual(AppNotificationKind.aiReview.bannerDefaultsKey, "notification.aiReview.banner")
    }
}
