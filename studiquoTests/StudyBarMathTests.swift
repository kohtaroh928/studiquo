import XCTest
@testable import studiquo

final class StudyBarMathTests: XCTestCase {
    private func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar().date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func sample(_ start: Date, _ seconds: TimeInterval) -> StudyBarMath.Sample {
        .init(startedAt: start, seconds: seconds)
    }

    /// 2026-10-21 は水曜。10月の合計は 3600 + 3600 + 5200 = 12400 秒。
    private var samples: [StudyBarMath.Sample] {
        [
            sample(date(2026, 10, 18, 9), 3_600),
            sample(date(2026, 10, 21, 9), 1_800),
            sample(date(2026, 10, 21, 20), 1_800),
            sample(date(2026, 10, 25, 9), 5_200),
            sample(date(2026, 2, 3, 9), 2_800)
        ]
    }

    private let reference = Date(timeIntervalSince1970: 1_792_576_800) // 2026-10-21 10:00 UTC

    func testReferenceDateIsTheWednesdayThisTestAssumes() {
        XCTAssertEqual(calendar().component(.weekday, from: reference), 4)
        XCTAssertEqual(calendar().component(.day, from: reference), 21)
    }

    // MARK: 曜日ラベル

    func testWeekdaySymbolsRotateToTheFirstWeekday() {
        XCTAssertEqual(StudyBarMath.orderedWeekdaySymbols(calendar: calendar(firstWeekday: 1)), ["S", "M", "T", "W", "T", "F", "S"])
        XCTAssertEqual(StudyBarMath.orderedWeekdaySymbols(calendar: calendar(firstWeekday: 2)), ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(StudyBarMath.orderedWeekdaySymbols(calendar: calendar(firstWeekday: 7)), ["S", "S", "M", "T", "W", "T", "F"])
    }

    // MARK: 週

    func testWeekHasSevenBarsSummingThatDaysSessionsAndHighlightingTheReferenceDay() {
        let bars = StudyBarMath.bars(span: .week, reference: reference, samples: samples, calendar: calendar())
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.map(\.seconds), [3_600, 0, 0, 3_600, 0, 0, 0])
        XCTAssertEqual(bars.map(\.isHighlighted), [false, false, false, true, false, false, false])
        XCTAssertEqual(bars.first?.date, date(2026, 10, 18))
        XCTAssertEqual(bars.last?.date, date(2026, 10, 24))
    }

    func testWeekFollowsTheCalendarsFirstWeekday() {
        let bars = StudyBarMath.bars(span: .week, reference: reference, samples: samples, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(bars.first?.date, date(2026, 10, 19), "月曜始まりなら10/18(日)は前の週")
        XCTAssertEqual(bars.first?.label, "M")
        XCTAssertEqual(bars.map(\.seconds), [0, 0, 3_600, 0, 0, 0, 5_200], "10/25(日)が週末に入る")
    }

    // MARK: 月

    func testMonthHasOneBarPerDayLabelledByDayNumber() {
        let bars = StudyBarMath.bars(span: .month, reference: reference, samples: samples, calendar: calendar())
        XCTAssertEqual(bars.count, 31)
        XCTAssertEqual(bars.first?.label, "1")
        XCTAssertEqual(bars.last?.label, "31")
        XCTAssertEqual(bars[17].seconds, 3_600)
        XCTAssertEqual(bars[20].seconds, 3_600)
        XCTAssertEqual(bars[24].seconds, 5_200)
        XCTAssertEqual(bars.filter(\.isHighlighted).map(\.label), ["21"])
        XCTAssertEqual(StudyBarMath.totalSeconds(of: bars), 12_400)
    }

    func testMonthLengthFollowsTheMonth() {
        XCTAssertEqual(StudyBarMath.bars(span: .month, reference: date(2026, 2, 10), samples: [], calendar: calendar()).count, 28)
        XCTAssertEqual(StudyBarMath.bars(span: .month, reference: date(2028, 2, 10), samples: [], calendar: calendar()).count, 29)
        XCTAssertEqual(StudyBarMath.bars(span: .month, reference: date(2026, 4, 10), samples: [], calendar: calendar()).count, 30)
    }

    // MARK: 年

    func testYearHasTwelveBarsEachTheMonthsDailyAverage() {
        let bars = StudyBarMath.bars(span: .year, reference: reference, samples: samples, calendar: calendar())
        XCTAssertEqual(bars.count, 12)
        XCTAssertEqual(bars.map(\.label), (1...12).map(String.init))
        XCTAssertEqual(bars[9].seconds, 12_400.0 / 31.0, accuracy: 0.001)   // 10月
        XCTAssertEqual(bars[1].seconds, 2_800.0 / 28.0, accuracy: 0.001)    // 2月は28日
        XCTAssertEqual(bars[0].seconds, 0)
        XCTAssertEqual(bars.filter(\.isHighlighted).map(\.label), ["10"])
    }

    func testMonthBoundaryBelongsToTheNextMonth() {
        let samples = [
            sample(date(2026, 10, 31, 23, 59), 600),
            sample(date(2026, 11, 1, 0, 0), 900)
        ]
        let stats = StudyBarMath.secondsInMonth(of: reference, in: samples, calendar: calendar())
        XCTAssertEqual(stats.total, 600)
        XCTAssertEqual(stats.days, 31)
    }

    // MARK: 平均・合計

    func testAverageIgnoresBarsWithoutStudy() {
        let bars = StudyBarMath.bars(span: .week, reference: reference, samples: samples, calendar: calendar())
        XCTAssertEqual(StudyBarMath.totalSeconds(of: bars), 7_200)
        XCTAssertEqual(StudyBarMath.averageSeconds(of: bars), 3_600, "7日で割らず、学習した2日で割る")

        let monthBars = StudyBarMath.bars(span: .month, reference: reference, samples: samples, calendar: calendar())
        XCTAssertEqual(StudyBarMath.averageSeconds(of: monthBars), 12_400.0 / 3.0, accuracy: 0.001)
    }

    func testNoStudyGivesZeroEverywhere() {
        for span in [StudyBarMath.Span.week, .month, .year] {
            let bars = StudyBarMath.bars(span: span, reference: reference, samples: [], calendar: calendar())
            XCTAssertFalse(bars.isEmpty)
            XCTAssertEqual(StudyBarMath.totalSeconds(of: bars), 0)
            XCTAssertEqual(StudyBarMath.averageSeconds(of: bars), 0)
        }
    }
}
