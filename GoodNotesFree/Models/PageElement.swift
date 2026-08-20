import Foundation
import SwiftData

@Model
final class PageElement {
    var kindRawValue: String
    var text: String
    @Attribute(.externalStorage) var imageData: Data?
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var colorHex: String
    var isLocked: Bool = false
    var layerIndex: Double = 0
    var page: NotePage?

    init(
        kind: PageElementKind,
        text: String = "",
        imageData: Data? = nil,
        centerX: Double = 0.5,
        centerY: Double = 0.35,
        width: Double = 0.35,
        height: Double = 0.12,
        rotation: Double = 0,
        colorHex: String = "#1C1C1E"
    ) {
        self.kindRawValue = kind.rawValue
        self.text = text
        self.imageData = imageData
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.colorHex = colorHex
    }

    var kind: PageElementKind {
        get { PageElementKind(rawValue: kindRawValue) ?? .text }
        set { kindRawValue = newValue.rawValue }
    }
}

enum PageElementKind: String, CaseIterable, Identifiable {
    case text
    case image
    case rectangle
    case ellipse
    case line
    case studyTape
    case pageLink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "テキスト"
        case .image: "写真"
        case .rectangle: "四角形"
        case .ellipse: "円・楕円"
        case .line: "直線"
        case .studyTape: "暗記テープ"
        case .pageLink: "ページリンク"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .image: "photo"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .studyTape: "rectangle.fill"
        case .pageLink: "link"
        }
    }
}
