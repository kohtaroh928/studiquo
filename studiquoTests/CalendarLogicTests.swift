import XCTest
@testable import studiquo

final class CalendarLogicTests: XCTestCase {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar(firstWeekday: 1).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: 月グリッド

    func testMonthGridAlwaysHas42ConsecutiveDays() {
        let calendar = calendar(firstWeekday: 1)
        for month in 1...12 {
            let days = CalendarDayMath.daysToDisplay(month: date(2026, month, 15), calendar: calendar)
            XCTAssertEqual(days.count, 42, "month \(month)")
            for (previous, next) in zip(days, days.dropFirst()) {
                XCTAssertEqual(calendar.dateComponents([.day], from: previous, to: next).day, 1)
            }
        }
    }

    func testMonthGridStartsOnTheFirstWeekdayOfTheWeekContainingTheFirst() {
        // 2026-10-01 は木曜。日曜始まりなら 9/27、月曜始まりなら 9/28 から。
        let sunday = CalendarDayMath.daysToDisplay(month: date(2026, 10, 20), calendar: calendar(firstWeekday: 1))
        XCTAssertEqual(sunday.first, date(2026, 9, 27))
        XCTAssertEqual(sunday.last, date(2026, 11, 7))

        let monday = CalendarDayMath.daysToDisplay(month: date(2026, 10, 20), calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(monday.first, date(2026, 9, 28))
    }

    func testMonthGridStartsOnTheFirstWhenItFallsOnTheFirstWeekday() {
        // 2027-02-01 は月曜。月曜始まりなら前月の日を含まない。
        let days = CalendarDayMath.daysToDisplay(month: date(2027, 2, 10), calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(days.first, date(2027, 2, 1))
        XCTAssertEqual(days.last, date(2027, 3, 14))
    }

    // MARK: 予定が日にかかるか

    func testEntryOverlapsEveryDayItRunsThrough() {
        let calendar = calendar(firstWeekday: 1)
        let start = date(2026, 10, 20, 23)
        let end = date(2026, 10, 22, 1)
        XCTAssertFalse(CalendarDayMath.overlapsDay(start: start, end: end, day: date(2026, 10, 19, 12), calendar: calendar))
        XCTAssertTrue(CalendarDayMath.overlapsDay(start: start, end: end, day: date(2026, 10, 20, 12), calendar: calendar))
        XCTAssertTrue(CalendarDayMath.overlapsDay(start: start, end: end, day: date(2026, 10, 21, 12), calendar: calendar))
        XCTAssertTrue(CalendarDayMath.overlapsDay(start: start, end: end, day: date(2026, 10, 22, 12), calendar: calendar))
        XCTAssertFalse(CalendarDayMath.overlapsDay(start: start, end: end, day: date(2026, 10, 23, 12), calendar: calendar))
    }

    func testEntryEndingExactlyAtMidnightStillCountsForThatDayButStartingAtNextMidnightDoesNot() {
        let calendar = calendar(firstWeekday: 1)
        let day = date(2026, 10, 22, 15)
        // 終了がちょうど 10/22 0:00 → その日に含める(end >= dayStart)
        XCTAssertTrue(CalendarDayMath.overlapsDay(start: date(2026, 10, 21, 22), end: date(2026, 10, 22), day: day, calendar: calendar))
        // 開始がちょうど 10/23 0:00 → その日に含めない
        XCTAssertFalse(CalendarDayMath.overlapsDay(start: date(2026, 10, 23), end: date(2026, 10, 23, 1), day: day, calendar: calendar))
    }

    // MARK: 日ごとの種別

    func testKindsByDayMarksEverySpannedDayAndMergesKinds() {
        let calendar = calendar(firstWeekday: 1)
        let result = CalendarDayMath.kindsByDay([
            (start: date(2026, 10, 20, 23), end: date(2026, 10, 22, 1), kind: "試験"),
            (start: date(2026, 10, 21, 9), end: date(2026, 10, 21, 10), kind: "授業")
        ], calendar: calendar)

        XCTAssertEqual(result[date(2026, 10, 20)], ["試験"])
        XCTAssertEqual(result[date(2026, 10, 21)], ["試験", "授業"])
        XCTAssertEqual(result[date(2026, 10, 22)], ["試験"])
        XCTAssertNil(result[date(2026, 10, 23)])
        XCTAssertEqual(result.count, 3)
    }

    func testKindsByDayStopsAfterAYearForARunawayEndDate() {
        let calendar = calendar(firstWeekday: 1)
        let result = CalendarDayMath.kindsByDay([
            (start: date(2026, 1, 1), end: date(2040, 1, 1), kind: 1)
        ], calendar: calendar)
        XCTAssertEqual(result.count, 366)
    }

    func testKindsByDayWithEndBeforeStartMarksNothing() {
        let result = CalendarDayMath.kindsByDay([
            (start: date(2026, 10, 22), end: date(2026, 10, 20), kind: 1)
        ], calendar: calendar(firstWeekday: 1))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: 連続学習日数

    func testStreakCountsConsecutiveDaysEndingToday() {
        let now = date(2026, 10, 22, 12)
        let studied = [date(2026, 10, 22, 8), date(2026, 10, 22, 20), date(2026, 10, 21, 9), date(2026, 10, 20, 9), date(2026, 10, 18, 9)]
        XCTAssertEqual(CalendarDayMath.studyStreak(studyDates: studied, now: now, calendar: calendar(firstWeekday: 1)), 3)
    }

    func testStreakKeepsYesterdaysRunWhenNothingStudiedYetToday() {
        let now = date(2026, 10, 22, 7)
        let studied = [date(2026, 10, 21, 9), date(2026, 10, 20, 9)]
        XCTAssertEqual(CalendarDayMath.studyStreak(studyDates: studied, now: now, calendar: calendar(firstWeekday: 1)), 2)
    }

    func testStreakIsZeroAfterAMissedDayOrWithNoStudy() {
        let now = date(2026, 10, 22, 12)
        let calendar = calendar(firstWeekday: 1)
        XCTAssertEqual(CalendarDayMath.studyStreak(studyDates: [date(2026, 10, 20, 9)], now: now, calendar: calendar), 0)
        XCTAssertEqual(CalendarDayMath.studyStreak(studyDates: [], now: now, calendar: calendar), 0)
    }

    // MARK: 学習時間の表記

    func testDurationDropsSecondsAndSwitchesToHoursAtSixtyMinutes() {
        XCTAssertEqual(StudyDurationFormat.text(0), L("0分"))
        XCTAssertEqual(StudyDurationFormat.text(59.9), L("0分"))
        XCTAssertEqual(StudyDurationFormat.text(3_599), L("59分"))
        XCTAssertEqual(StudyDurationFormat.text(3_600), L("1時間0分"))
        XCTAssertEqual(StudyDurationFormat.text(5_400), L("1時間30分"))
        XCTAssertEqual(StudyDurationFormat.text(7_325), L("2時間2分"))
    }

    func testNegativeDurationReadsAsZero() {
        XCTAssertEqual(StudyDurationFormat.text(-120), L("0分"))
        XCTAssertEqual(StudyDurationFormat.parts(-120).minutes, 0)
    }

    // MARK: 通知時刻

    func testReminderIsNeverLaterThanOneMinuteBeforeStart() {
        let start = date(2026, 10, 22, 9)
        let latest = start.addingTimeInterval(-60)
        XCTAssertEqual(EventReminderPlan.latestReminderDate(start: start), latest)
        XCTAssertEqual(EventReminderPlan.effectiveReminderDate(requested: nil, start: start), latest)
        XCTAssertEqual(EventReminderPlan.effectiveReminderDate(requested: start.addingTimeInterval(500), start: start), latest)
        XCTAssertEqual(EventReminderPlan.effectiveReminderDate(requested: start, start: start), latest)
        let early = start.addingTimeInterval(-3_600)
        XCTAssertEqual(EventReminderPlan.effectiveReminderDate(requested: early, start: start), early)
    }

    func testMinutesBeforeStartIsAtLeastOne() {
        let start = date(2026, 10, 22, 9)
        XCTAssertEqual(EventReminderPlan.minutesBeforeStart(start: start, reminder: start.addingTimeInterval(-60)), 1)
        XCTAssertEqual(EventReminderPlan.minutesBeforeStart(start: start, reminder: start.addingTimeInterval(-30)), 1)
        XCTAssertEqual(EventReminderPlan.minutesBeforeStart(start: start, reminder: start.addingTimeInterval(-3_600)), 60)
    }

    func testReminderSummaryUsesMinutesHoursOrDays() {
        XCTAssertEqual(EventReminderPlan.summary(minutes: 1), L("予定の1分前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 59), L("予定の59分前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 60), L("予定の約1時間前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 90), L("予定の約1時間前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 1_439), L("予定の約23時間前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 1_440), L("予定の約1日前に通知します。"))
        XCTAssertEqual(EventReminderPlan.summary(minutes: 4_000), L("予定の約2日前に通知します。"))
    }

    func testFireDateUsesExplicitDateAndClampsItBeforeStart() {
        let start = date(2026, 10, 22, 9)
        let early = start.addingTimeInterval(-7_200)
        XCTAssertEqual(EventReminderPlan.fireDate(explicit: early, minutesBefore: 30, start: start), early)
        XCTAssertEqual(
            EventReminderPlan.fireDate(explicit: start.addingTimeInterval(500), minutesBefore: 30, start: start),
            start.addingTimeInterval(-60),
            "開始後に設定された通知は開始の1分前に寄せる"
        )
    }

    func testFireDateFallsBackToStoredOffsetForOlderEvents() {
        let start = date(2026, 10, 22, 9)
        XCTAssertEqual(EventReminderPlan.fireDate(explicit: nil, minutesBefore: 30, start: start), start.addingTimeInterval(-1_800))
        XCTAssertEqual(EventReminderPlan.fireDate(explicit: nil, minutesBefore: 1_440, start: start), start.addingTimeInterval(-86_400))
        XCTAssertEqual(EventReminderPlan.fireDate(explicit: nil, minutesBefore: 0, start: start), start.addingTimeInterval(-60), "開始時刻ちょうどは1分前に寄せる")
    }

    func testFireDateIsNilWhenRemindersAreOffOrOffsetIsUnknown() {
        let start = date(2026, 10, 22, 9)
        XCTAssertNil(EventReminderPlan.fireDate(explicit: nil, minutesBefore: -1, start: start))
        XCTAssertNil(EventReminderPlan.fireDate(explicit: nil, minutesBefore: 7, start: start))
    }
}
