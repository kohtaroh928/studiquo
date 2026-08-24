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

    init(title: String, startDate: Date, endDate: Date, kind: CalendarEventKind, notes: String = "") {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.kindRawValue = kind.rawValue
        self.notes = notes
        self.createdAt = .now
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
