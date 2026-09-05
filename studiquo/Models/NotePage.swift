import Foundation
import SwiftData

@Model
final class NotePage {
    var order: Int = 0
    @Attribute(.externalStorage) var drawingData: Data?
    @Attribute(.externalStorage) var backgroundImageData: Data?
    var pageWidth: Double = 612
    var pageHeight: Double = 792
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
    /// Width, in the coordinate space `drawingData`'s stroke points are
    /// expressed in.
    ///
    /// Ink used to be stored in whatever size the canvas happened to be on
    /// screen when it was drawn, so opening the same page at a different
    /// width — splitting the editor, most obviously — drew every stroke at
    /// the wrong scale and spilled it past the edge of the page. It also made
    /// PDF export and thumbnails, which render against the page rectangle,
    /// disagree with what was on screen.
    ///
    /// Strokes are now kept in page units, so this settles at `pageWidth`.
    /// `0` marks a page written before the change, whose ink is converted the
    /// first time it is opened (see `normalizeInkCoordinateSpace`).
    var inkReferenceWidth: Double = 0

    // MARK: Proof marking

    /// The exercise this page is an answer to, and the answer it is marked
    /// against. Held per page so "添削" is a single tap on every re-run.
    var proofQuestion: String = ""
    var proofModelAnswer: String = ""
    /// The cached marking scheme, JSON-encoded `ProofRubric`. Built from the
    /// model answer alone, before the student's work is read — see
    /// `ProofGradingService`. Rebuilt whenever the model answer changes.
    var proofRubricData: Data?
    /// Which model answer `proofRubricData` was derived from, so an edited
    /// answer invalidates the cached scheme instead of silently marking
    /// against the old one.
    var proofRubricSourceHash: Int = 0
    /// The most recent marking result, JSON-encoded `ProofReviewResult`.
    @Attribute(.externalStorage) var proofReviewData: Data?
    var proofReviewedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \PageElement.page)
    var elements: [PageElement]?

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

    /// Non-optional read access to the CloudKit-required optional
    /// relationship. Callers sort/filter this themselves — unlike the other
    /// to-many relationships, elements don't have one canonical order.
    var allElements: [PageElement] {
        elements ?? []
    }

    /// Appends to the CloudKit-required optional relationship, creating the
    /// backing array on first use.
    func addElement(_ element: PageElement) {
        if elements == nil { elements = [] }
        elements?.append(element)
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
