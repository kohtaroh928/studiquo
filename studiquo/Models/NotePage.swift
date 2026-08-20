import Foundation
import SwiftData

@Model
final class NotePage {
    var order: Int
    @Attribute(.externalStorage) var drawingData: Data?
    @Attribute(.externalStorage) var backgroundImageData: Data?
    var pageWidth: Double
    var pageHeight: Double
    var notebook: Notebook?
    var templateRawValue: String = PageTemplate.blank.rawValue
    var isBookmarked: Bool = false
    var title: String = ""
    var paperColorHex: String = "#FFFFFF"
    var recognizedText: String = ""
    var textRecognitionDate: Date?
    var flashcardQuestion: String = ""
    var flashcardAnswer: String = ""
    var flashcardMastery: Int = 0
    var flashcardReviewCount: Int = 0
    var flashcardLastReviewedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \PageElement.page)
    var elements: [PageElement] = []

    init(order: Int, backgroundImageData: Data? = nil, pageWidth: Double = 612, pageHeight: Double = 792) {
        self.order = order
        self.backgroundImageData = backgroundImageData
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }

    var pageTemplate: PageTemplate {
        get { PageTemplate(rawValue: templateRawValue) ?? .blank }
        set { templateRawValue = newValue.rawValue }
    }
}

enum PageTemplate: String, CaseIterable, Identifiable {
    case blank
    case ruled
    case grid
    case dotted
    case cornell
    case weekly
    case monthly
    case checklist
    case musicStaff

    var id: String { rawValue }

    var name: String {
        switch self {
        case .blank: "白紙"
        case .ruled: "横罫"
        case .grid: "方眼"
        case .dotted: "ドット"
        case .cornell: "コーネル"
        case .weekly: "週間予定"
        case .monthly: "月間カレンダー"
        case .checklist: "チェックリスト"
        case .musicStaff: "五線譜"
        }
    }

    var icon: String {
        switch self {
        case .blank: "doc"
        case .ruled: "line.3.horizontal"
        case .grid: "grid"
        case .dotted: "circle.grid.3x3"
        case .cornell: "rectangle.split.2x1"
        case .weekly: "calendar.day.timeline.leading"
        case .monthly: "calendar"
        case .checklist: "checklist"
        case .musicStaff: "music.note.list"
        }
    }
}
