import Foundation
import SwiftData

@Model
final class CalendarEvent {
    var title: String
    var startDate: Date
    var endDate: Date
    var kindRawValue: String
    var notes: String
    var createdAt: Date
    var externalID: String?
    var externalSource: String?
    var externalSourceName: String?
    var notificationID: String?
    var reminderMinutesBefore: Int
    var notificationsEnabled: Bool

    init(
        title: String,
        startDate: Date,
        endDate: Date,
        kind: CalendarEventKind,
        notes: String = "",
        externalID: String? = nil,
        externalSource: String? = nil,
        externalSourceName: String? = nil,
        notificationID: String? = nil,
        reminderMinutesBefore: Int = 30,
        notificationsEnabled: Bool = true
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.kindRawValue = kind.rawValue
        self.notes = notes
        self.createdAt = .now
        self.externalID = externalID
        self.externalSource = externalSource
        self.externalSourceName = externalSourceName
        self.notificationID = notificationID
        self.reminderMinutesBefore = reminderMinutesBefore
        self.notificationsEnabled = notificationsEnabled
    }

    var kind: CalendarEventKind {
        get { CalendarEventKind(rawValue: kindRawValue) ?? .other }
        set { kindRawValue = newValue.rawValue }
    }
}

enum CalendarEventKind: String, CaseIterable, Identifiable {
    case test
    case classLesson
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .test: "テスト"
        case .classLesson: "授業"
        case .other: "その他"
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
