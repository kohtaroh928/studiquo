import Foundation
import SwiftData

@Model
final class CalendarEvent {
    /// Stable identifier for this event, independent of SwiftData's own
    /// `persistentModelID` — used to key its scheduled reminder notification
    /// so it can be found again to reschedule or cancel.
    var id: UUID = UUID()
    var title: String
    var startDate: Date
    var endDate: Date
    var kindRawValue: String
    var notes: String
    var createdAt: Date
    var externalID: String?
    var externalSource: String?
    /// Display name of the institution an imported entry came from, so the
    /// calendar and the notification list can say where it originated.
    var externalSourceName: String?
    /// Minutes before `startDate` to send a reminder notification, or
    /// `EventReminderOption.none.rawValue` (-1) for no reminder.
    var reminderMinutesBefore: Int = EventReminderOption.thirtyMinutes.rawValue

    init(title: String, startDate: Date, endDate: Date, kind: CalendarEventKind, notes: String = "") {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.kindRawValue = kind.rawValue
        self.notes = notes
        self.createdAt = .now
        self.externalID = nil
        self.externalSource = nil
        self.externalSourceName = nil
    }

    var kind: CalendarEventKind {
        get { CalendarEventKind(rawValue: kindRawValue) ?? .other }
        set { kindRawValue = newValue.rawValue }
    }
}

@Model
final class StudyActivity {
    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var sourceTitle: String = ""
    var correctCount: Int = 0
    var totalCount: Int = 0

    init(startedAt: Date, endedAt: Date, sourceTitle: String, correctCount: Int = 0, totalCount: Int = 0) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sourceTitle = sourceTitle
        self.correctCount = correctCount
        self.totalCount = totalCount
    }

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

@Model
final class AIChatThread {
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AIChatMessage.thread)
    var messages: [AIChatMessage] = []

    init(title: String = "新しいトーク") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedMessages: [AIChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
final class AIChatMessage {
    var text: String
    var createdAt: Date
    var roleRawValue: String
    var thread: AIChatThread?

    init(text: String, role: AIChatRole, createdAt: Date = .now) {
        self.text = text
        self.createdAt = createdAt
        self.roleRawValue = role.rawValue
    }

    var role: AIChatRole {
        get { AIChatRole(rawValue: roleRawValue) ?? .user }
        set { roleRawValue = newValue.rawValue }
    }
}

enum AIChatRole: String {
    case user
    case assistant
}

enum CalendarEventKind: String, CaseIterable, Identifiable {
    case test
    case classLesson
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .test: L("テスト")
        case .classLesson: L("授業")
        case .other: L("その他")
        }
    }

    var icon: String {
        switch self {
        case .test: "pencil.and.list.clipboard"
        case .classLesson: "graduationcap.fill"
        case .other: "calendar.badge.clock"
        }
    }
}

/// How long before an event's start time to send a reminder notification.
/// Stored on `CalendarEvent.reminderMinutesBefore` as its raw minute count.
enum EventReminderOption: Int, CaseIterable, Identifiable {
    case none = -1
    case atStartTime = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case oneDay = 1440

    var id: Int { rawValue }

    init(minutesBefore: Int) {
        self = EventReminderOption(rawValue: minutesBefore) ?? .none
    }

    var title: String {
        switch self {
        case .none: L("通知しない")
        case .atStartTime: L("開始時刻")
        case .fiveMinutes: L("5分前")
        case .tenMinutes: L("10分前")
        case .fifteenMinutes: L("15分前")
        case .thirtyMinutes: L("30分前")
        case .oneHour: L("1時間前")
        case .oneDay: L("1日前")
        }
    }
}
