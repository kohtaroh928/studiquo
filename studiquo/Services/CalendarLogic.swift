import Foundation

/// The date arithmetic behind `CalendarHomeView`, kept out of the view so it
/// can be tested with a fixed `Calendar` instead of through SwiftUI state.
enum CalendarDayMath {
    /// Always 42 cells (6 full weeks) so the grid's height doesn't jump
    /// between months with four weeks and months with six.
    static func daysToDisplay(month: Date, calendar: Calendar = .current) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let gridStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start
        else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// Whether an entry running `start`…`end` touches `day`. Anything running
    /// *through* the day counts, not just starting on it, so a multi-day entry
    /// stays visible for its whole span.
    static func overlapsDay(start: Date, end: Date, day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return start < dayEnd && end >= dayStart
    }

    /// Which kinds land on each day, so the grid can mark a day without
    /// re-scanning every event per cell. A multi-day entry marks every day it
    /// spans (capped at a year so a bad end date can't loop for ages).
    static func kindsByDay<Kind: Hashable>(
        _ entries: [(start: Date, end: Date, kind: Kind)],
        calendar: Calendar = .current
    ) -> [Date: Set<Kind>] {
        var result: [Date: Set<Kind>] = [:]
        for entry in entries {
            var cursor = calendar.startOfDay(for: entry.start)
            let lastDay = calendar.startOfDay(for: entry.end)
            var daysWalked = 0
            while cursor <= lastDay, daysWalked < 366 {
                result[cursor, default: []].insert(entry.kind)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                daysWalked += 1
            }
        }
        return result
    }

    /// Consecutive studied days ending today, or ending yesterday if today
    /// hasn't had any study yet (so the streak doesn't read 0 every morning).
    static func studyStreak(studyDates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let studiedDays = Set(studyDates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !studiedDays.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while studiedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

/// How a study duration reads in the calendar: minutes under an hour,
/// hours + minutes from an hour up. Seconds are dropped, not rounded.
enum StudyDurationFormat {
    static func parts(_ duration: TimeInterval) -> (hours: Int, minutes: Int) {
        let minutes = max(0, Int(duration)) / 60
        return (minutes / 60, minutes % 60)
    }

    static func text(_ duration: TimeInterval) -> String {
        let p = parts(duration)
        return p.hours > 0 ? L("\(p.hours)時間\(p.minutes)分") : L("\(p.minutes)分")
    }
}

/// When an event's reminder fires and how the editor describes it.
enum EventReminderPlan {
    /// The latest instant a reminder may fire: one minute before the event.
    /// A notification at or after the thing it is reminding you about is
    /// useless, so the picker is bounded rather than merely validated.
    static func latestReminderDate(start: Date) -> Date {
        start.addingTimeInterval(-60)
    }

    static func effectiveReminderDate(requested: Date?, start: Date) -> Date {
        let latest = latestReminderDate(start: start)
        return min(requested ?? latest, latest)
    }

    static func minutesBeforeStart(start: Date, reminder: Date) -> Int {
        max(1, Int(abs(start.timeIntervalSince(reminder)) / 60))
    }

    static func summary(minutes: Int) -> String {
        if minutes < 60 { return L("予定の\(minutes)分前に通知します。") }
        if minutes < 60 * 24 { return L("予定の約\(minutes / 60)時間前に通知します。") }
        return L("予定の約\(minutes / (60 * 24))日前に通知します。")
    }

    /// The moment to schedule the notification, or `nil` for none. An explicit
    /// date wins; events saved before the editor switched to one fall back to
    /// their stored offset. Never at or after the event itself, even if the
    /// start was dragged earlier after the reminder was set.
    static func fireDate(
        explicit: Date?,
        minutesBefore: Int,
        start: Date
    ) -> Date? {
        let requested: Date?
        if let explicit {
            requested = explicit
        } else {
            let option = EventReminderOption(minutesBefore: minutesBefore)
            requested = option == .none ? nil : start.addingTimeInterval(-Double(option.rawValue) * 60)
        }
        guard let requested else { return nil }
        return min(requested, start.addingTimeInterval(-60))
    }
}

/// The bars behind the calendar's study-time chart, computed from plain
/// (start, seconds) samples so they can be tested with a fixed `Calendar`.
enum StudyBarMath {
    enum Span { case week, month, year }

    struct Sample {
        let startedAt: Date
        let seconds: TimeInterval
    }

    struct Bar: Identifiable {
        let id = UUID()
        let label: String
        let seconds: TimeInterval
        /// The day (week/month) or the month's first day (year) this bar
        /// represents — used to build the tapped-detail text.
        let date: Date
        /// The bar for the selected day / current month, drawn in full colour.
        let isHighlighted: Bool
    }

    /// Weekday short symbols rotated to the calendar's first weekday, so the
    /// labels line up with the bars.
    static func orderedWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    static func seconds(on day: Date, in samples: [Sample], calendar: Calendar) -> TimeInterval {
        samples.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.reduce(0) { $0 + $1.seconds }
    }

    /// Total study time in the month containing `day`, and how many days it has.
    static func secondsInMonth(of day: Date, in samples: [Sample], calendar: Calendar) -> (total: TimeInterval, days: Int) {
        guard let interval = calendar.dateInterval(of: .month, for: day),
              let dayCount = calendar.range(of: .day, in: .month, for: day)?.count else {
            return (0, 1)
        }
        let total = samples
            .filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }
            .reduce(0) { $0 + $1.seconds }
        return (total, max(dayCount, 1))
    }

    static func bars(span: Span, reference: Date, samples: [Sample], calendar: Calendar) -> [Bar] {
        switch span {
        case .week:
            guard let start = calendar.dateInterval(of: .weekOfYear, for: reference)?.start else { return [] }
            let symbols = orderedWeekdaySymbols(calendar: calendar)
            return (0..<7).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
                return Bar(
                    label: symbols[offset],
                    seconds: seconds(on: day, in: samples, calendar: calendar),
                    date: day,
                    isHighlighted: calendar.isDate(day, inSameDayAs: reference)
                )
            }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: reference),
                  let dayCount = calendar.range(of: .day, in: .month, for: reference)?.count else { return [] }
            return (0..<dayCount).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
                return Bar(
                    label: "\(calendar.component(.day, from: day))",
                    seconds: seconds(on: day, in: samples, calendar: calendar),
                    date: day,
                    isHighlighted: calendar.isDate(day, inSameDayAs: reference)
                )
            }
        case .year:
            let year = calendar.component(.year, from: reference)
            let selectedMonth = calendar.component(.month, from: reference)
            return (1...12).compactMap { month in
                guard let day = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
                let stats = secondsInMonth(of: day, in: samples, calendar: calendar)
                return Bar(
                    label: "\(month)",
                    seconds: stats.total / Double(stats.days), // the month's daily average
                    date: day,
                    isHighlighted: month == selectedMonth
                )
            }
        }
    }

    /// Average over the periods that actually had study, not over every bar.
    /// Dividing by all 31 days of a month made a real hour read as "0分".
    static func averageSeconds(of bars: [Bar]) -> TimeInterval {
        let active = bars.filter { $0.seconds > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.seconds } / Double(active.count)
    }

    static func totalSeconds(of bars: [Bar]) -> TimeInterval {
        bars.reduce(0) { $0 + $1.seconds }
    }
}
