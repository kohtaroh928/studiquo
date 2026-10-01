import Foundation

/// How the user wants "missed card" reminders delivered. Stored in
/// UserDefaults next to the other notification preferences.
enum MistakeReviewFrequency: String, CaseIterable, Identifiable {
    case daily
    case everyOtherDay
    case whenFiveOrMore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: L("毎日")
        case .everyOtherDay: L("2日に1回")
        case .whenFiveOrMore: L("5問以上たまったとき")
        }
    }
}

enum MistakeReviewPreferences {
    static let enabledKey = "notification.mistakeReview.enabled"
    static let hourKey = "notification.mistakeReview.hour"
    static let frequencyKey = "notification.mistakeReview.frequency"
    static let showsQuestionKey = "notification.mistakeReview.showsQuestion"

    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
    static var hour: Int {
        let value = (UserDefaults.standard.object(forKey: hourKey) as? Int) ?? 9
        return min(max(value, 0), 23)
    }
    static var frequency: MistakeReviewFrequency {
        MistakeReviewFrequency(rawValue: UserDefaults.standard.string(forKey: frequencyKey) ?? "") ?? .daily
    }
    static var showsQuestion: Bool { (UserDefaults.standard.object(forKey: showsQuestionKey) as? Bool) ?? true }
}

/// Pure rules for the "missed cards" list, kept free of SwiftData and
/// UserNotifications so they can be unit tested directly.
enum MistakeReviewPolicy {
    /// Consecutive correct answers needed to leave the missed list.
    static let graduationStreak = 2
    /// Days until the next retry, by stage: next day, 3 days, 7 days.
    static let retryIntervalDays = [1, 3, 7]

    static func retryDate(after date: Date, stage: Int, hour: Int, calendar: Calendar = .current) -> Date {
        let days = retryIntervalDays[min(max(stage, 0), retryIntervalDays.count - 1)]
        let day = calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// Updates the missed-list state of `card` after one graded answer.
    static func record(
        correct: Bool,
        on card: Flashcard,
        at date: Date = .now,
        hour: Int = MistakeReviewPreferences.hour,
        calendar: Calendar = .current
    ) {
        if !correct {
            card.needsReview = true
            card.reviewStreak = 0
            card.retryStage = 0
            card.retryDueAt = retryDate(after: date, stage: 0, hour: hour, calendar: calendar)
            return
        }
        guard card.needsReview else { return }
        card.reviewStreak += 1
        if card.reviewStreak >= graduationStreak {
            card.needsReview = false
            card.reviewStreak = 0
            card.retryStage = 0
            card.retryDueAt = nil
        } else {
            card.retryStage += 1
            card.retryDueAt = retryDate(after: date, stage: card.retryStage, hour: hour, calendar: calendar)
        }
    }

    /// Cards on the missed list whose retry is due at `date`. A missed card
    /// with no due date (e.g. synced from an older build) counts as due.
    static func dueCards(in cards: [Flashcard], at date: Date = .now) -> [Flashcard] {
        cards.filter { $0.needsReview && ($0.retryDueAt.map { $0 <= date } ?? true) }
    }
}
