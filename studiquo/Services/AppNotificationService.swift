import Foundation
import Security
import SwiftData
import UIKit
import UserNotifications

extension Notification.Name {
    static let studiquoNotificationRoute = Notification.Name("StudiquoNotificationRoute")
}

enum AppNotificationKind: String, CaseIterable, Codable, Identifiable {
    case calendarDeadline
    case friendMessage
    case friendRequest
    case groupInvite
    case shareInvite
    case flashcardReview
    case aiTaskComplete
    case studyStreak
    case newDeviceLogin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendarDeadline: "カレンダーの予定・提出期限"
        case .friendMessage: "フレンドチャットの新着"
        case .friendRequest: "フレンド申請"
        case .groupInvite: "グループ招待"
        case .shareInvite: "共有招待"
        case .flashcardReview: "暗記カードの復習時期"
        case .aiTaskComplete: "AI回答・長時間処理の完了"
        case .studyStreak: "連続学習記録"
        case .newDeviceLogin: "新しい端末からのログイン"
        }
    }

    var defaultsKey: String { "notification.\(rawValue).enabled" }
    var categoryIdentifier: String { "studiquo.\(rawValue)" }
}

enum AppNotificationPreferences {
    static let masterDefaultsKey = "notification.master.enabled"

    static var masterEnabled: Bool {
        (UserDefaults.standard.object(forKey: masterDefaultsKey) as? Bool) ?? true
    }

    static func isEnabled(_ kind: AppNotificationKind) -> Bool {
        guard masterEnabled else { return false }
        return (UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool) ?? true
    }

    static var serverPayload: [String: Bool] {
        Dictionary(uniqueKeysWithValues: AppNotificationKind.allCases.map { ($0.rawValue, isEnabled($0)) })
    }

    static func registerCategories() {
        let categories = Set(AppNotificationKind.allCases.map {
            UNNotificationCategory(identifier: $0.categoryIdentifier, actions: [], intentIdentifiers: [])
        })
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    static func cancelPending(for kind: AppNotificationKind) {
        let prefixes: [String]
        switch kind {
        case .calendarDeadline:
            prefixes = ["event-reminder-", "university-deadline-"]
        case .flashcardReview:
            prefixes = ["flashcard-review-"]
        case .studyStreak:
            prefixes = ["study-streak-"]
        case .aiTaskComplete:
            prefixes = ["ai-complete-"]
        default:
            return
        }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    static func synchronizeRemoteDevice() {
        Task { @MainActor in
            await PushNotificationRegistration.updateCurrentDevicePreferences()
        }
    }
}

enum NotificationInstallationIdentity {
    private static let service = "com.yabuko.studiquo.notification-installation"
    private static let account = "installation-id"

    static var id: String {
        if let existing = read() { return existing }
        let created = UUID().uuidString.lowercased()
        save(created)
        return created
    }

    static var deviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? UIDevice.current.model : name).prefix(80))
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum FlashcardReviewNotifications {
    private static let identifierPrefix = "flashcard-review-"

    static func nextReviewDate(after date: Date, mastery: Int, correct: Bool, calendar: Calendar = .current) -> Date {
        let days: Int
        if !correct { days = 1 }
        else {
            switch mastery {
            case ...1: days = 3
            case 2: days = 7
            case 3: days = 14
            default: days = 30
            }
        }
        let day = calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    @MainActor
    static func reschedule(decks: [FlashcardDeck], now: Date = .now, calendar: Calendar = .current) async {
        cancelAll()
        guard AppNotificationPreferences.isEnabled(.flashcardReview) else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let cards = decks.filter { !$0.isTrashed }.flatMap(\.sortedCards)
        var counts: [Date: Int] = [:]
        for card in cards {
            let due = card.nextReviewAt
                ?? card.lastReviewedAt.map { nextReviewDate(after: $0, mastery: card.mastery, correct: card.mastery > 0, calendar: calendar) }
            guard let due else { continue }
            let day = calendar.startOfDay(for: max(due, now))
            counts[day, default: 0] += 1
        }

        for (day, count) in counts.sorted(by: { $0.key < $1.key }).prefix(60) {
            var fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            if fireDate <= now { fireDate = now.addingTimeInterval(60) }
            let content = UNMutableNotificationContent()
            content.title = L("暗記カードの復習")
            content.body = L("今日の復習対象が\(count)枚あります")
            content.sound = .default
            content.categoryIdentifier = AppNotificationKind.flashcardReview.categoryIdentifier
            content.userInfo = ["route": AppNotificationKind.flashcardReview.rawValue]
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let id = identifierPrefix + String(Int(day.timeIntervalSince1970))
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            )
        }
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum StudyStreakNotifications {
    private static let identifierPrefix = "study-streak-"

    @MainActor
    static func reschedule(activities: [StudyActivity], now: Date = .now, calendar: Calendar = .current) async {
        cancelAll()
        guard AppNotificationPreferences.isEnabled(.studyStreak),
              (UserDefaults.standard.object(forKey: "studyTimeTrackingEnabled") as? Bool) ?? true else { return }
        let today = calendar.startOfDay(for: now)
        let studiedDays = Set(activities.map { calendar.startOfDay(for: $0.startedAt) })
        guard !studiedDays.contains(today),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              studiedDays.contains(yesterday) else { return }

        var streak = 0
        var cursor = yesterday
        while studiedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        guard streak > 0,
              let fireDate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today),
              fireDate > now else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L("連続学習を続けましょう")
        content.body = L("現在\(streak)日連続です。今日の学習を記録すると継続できます。")
        content.sound = .default
        content.categoryIdentifier = AppNotificationKind.studyStreak.categoryIdentifier
        content.userInfo = ["route": AppNotificationKind.studyStreak.rawValue]
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifierPrefix + String(Int(today.timeIntervalSince1970)), content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        )
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum AICompletionNotifications {
    static func deliver(threadTitle: String) async {
        guard AppNotificationPreferences.isEnabled(.aiTaskComplete) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L("AIの回答が完成しました")
        content.body = threadTitle
        content.sound = .default
        content.categoryIdentifier = AppNotificationKind.aiTaskComplete.categoryIdentifier
        content.userInfo = ["route": AppNotificationKind.aiTaskComplete.rawValue]
        try? await center.add(UNNotificationRequest(identifier: "ai-complete-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
