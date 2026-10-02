import SwiftUI
import UIKit

/// Something the student attached to an AIトーク message: a file, a camera
/// shot, an app document, or a rectangle cut out of a page.
///
/// Shared by the note editor's chat and the home AI screen, so it lives
/// outside either view.
struct AIChatAttachment: Identifiable, Hashable {
    enum Kind: String {
        case file
        case folder
        case camera
        case notebook
        case flashcards
        case document
        case slideDeck
        /// A rectangle cut out of a page — see `PageSnippet`.
        case snippet

        var label: String {
            switch self {
            case .file: return L("ファイル")
            case .folder: return L("フォルダー")
            case .camera: return L("撮影画像")
            case .notebook: return L("ノート・PDF")
            case .flashcards: return L("暗記カード")
            case .document: return L("文書")
            case .slideDeck: return L("スライド")
            case .snippet: return L("切り抜き")
            }
        }

    var icon: String {
        switch self {
        case .file: return "doc"
            case .folder: return "folder"
            case .camera: return "camera"
            case .notebook: return "doc.richtext"
            case .flashcards: return "rectangle.on.rectangle.angled"
            case .document: return "doc.text"
            case .slideDeck: return "rectangle.on.rectangle"
            case .snippet: return "rectangle.dashed"
            }
        }
    }

    /// What a dropped snippet is, as far as the marker is concerned.
    ///
    /// One question and one answer is what turns an ordinary chat message
    /// into a marking request; anything else is just a picture to talk about.
    enum ProofRole: String, CaseIterable, Identifiable {
        case none
        case question
        case answer

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return L("画像として送る")
            case .question: return L("問題")
            case .answer: return L("解答")
            }
        }

        var tint: Color {
            switch self {
            case .none: return .secondary
            case .question: return .indigo
            case .answer: return .teal
            }
        }
    }

    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
    var sourceID: String? = nil
    var snippet: PageSnippet?
    var imageData: Data?
    var contextText: String = ""
    var proofRole: ProofRole = .none

    var image: UIImage? {
        if let snippet { return snippet.image }
        if let imageData { return UIImage(data: imageData) }
        return nil
    }
}
