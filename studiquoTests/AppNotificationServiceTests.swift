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

// MARK: - Study reminders

/// `StudyReminderPlanner` decides what is scheduled for the next days. The
/// point of planning ahead: a reminder scheduled only for today never fires on
/// a day the app is not opened, which is the day it is for.
final class StudyReminderPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func plan(studied: [Date], now: Date, streak: Bool = true, start: Bool = true, horizon: Int = 3) -> [PlannedStudyReminder] {
        StudyReminderPlanner.plan(studiedDays: studied, now: now, calendar: calendar, streakEnabled: streak, startEnabled: start, horizonDays: horizon)
    }

    func testAStreakIsRemindedAtEightAndAnUnstartedDayAtSix() {
        // Studied on the 3rd and 4th; it is the morning of the 5th.
        let result = plan(studied: [date(3, 10), date(4, 10)], now: date(5, 9))
        XCTAssertEqual(result.first, PlannedStudyReminder(day: date(5), fireDate: date(5, 20), kind: .streak(days: 2)))
    }

    func testDaysAheadAreScheduledSoTheyFireEvenIfTheAppIsNeverOpened() {
        // Studied yesterday only. Today protects the streak; once a day passes
        // unopened the streak is gone, so the following days are start reminders.
        let result = plan(studied: [date(4, 10)], now: date(5, 9))
        XCTAssertEqual(result.map(\.kind), [.streak(days: 1), .start, .start])
        XCTAssertEqual(result.map(\.fireDate), [date(5, 20), date(6, 18), date(7, 18)])
    }

    func testADayAlreadyStudiedGetsNothingAndTomorrowCountsToday() {
        let result = plan(studied: [date(4, 10), date(5, 8)], now: date(5, 9))
        XCTAssertEqual(result.first?.day, date(6), "今日学習済みなら、今日の分は予約しません。")
        XCTAssertEqual(result.first?.kind, .streak(days: 2), "明日の連続日数には今日が含まれます。")
    }

    func testATimeThatHasAlreadyPassedIsSkipped() {
        let result = plan(studied: [date(4, 10)], now: date(5, 21))
        XCTAssertEqual(result.map(\.day), [date(6), date(7)], "20時を過ぎたら今日の分は予約しません。")
    }

    func testOnlyOneNotificationPerDay() {
        let result = plan(studied: [date(4, 10)], now: date(5, 9), horizon: 5)
        XCTAssertEqual(Set(result.map(\.day)).count, result.count)
    }

    func testEachKindCanBeTurnedOffSeparately() {
        let studied = [date(4, 10)]
        XCTAssertEqual(plan(studied: studied, now: date(5, 9), streak: false).map(\.kind), [.start, .start], "連続学習をオフにすると、連続の日は何も出ません。")
        XCTAssertEqual(plan(studied: studied, now: date(5, 9), start: false).map(\.kind), [.streak(days: 1)], "開始リマインドをオフにすると、連続がない日は何も出ません。")
        XCTAssertTrue(plan(studied: studied, now: date(5, 9), streak: false, start: false).isEmpty)
    }

    func testNothingStudiedAtAllStartsWithTheStartReminder() {
        let result = plan(studied: [], now: date(5, 9))
        XCTAssertEqual(result.map(\.kind), [.start, .start, .start])
        XCTAssertEqual(result.first?.fireDate, date(5, 18))
    }

    func testTheHorizonBoundsHowManyDaysAreScheduled() {
        XCTAssertEqual(plan(studied: [], now: date(5, 9), horizon: 2).count, 2)
        XCTAssertTrue(plan(studied: [], now: date(5, 9), horizon: 0).isEmpty)
    }

    func testAKindHasItsOwnPreferenceAndCategory() {
        XCTAssertEqual(AppNotificationKind.studyReminder.categoryIdentifier, "studiquo.studyReminder")
        XCTAssertEqual(AppNotificationKind.studyReminder.defaultsKey, "notification.studyReminder.enabled")
    }
}
