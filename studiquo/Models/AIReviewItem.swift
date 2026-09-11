import Foundation
import SwiftData

/// A piece of review material the AI put together from a question asked in
/// AIトーク, surfaced to the student the day after they asked it.
///
/// Only created for questions the AI judged worth reviewing (see
/// `AIReviewService`) — idle chat never produces one of these. The
/// explanation is also saved as a `TextDocument` (`explanationDocument`) so
/// it lives in the student's own 文書 library and can be exported as a PDF
/// through the existing `ExportService` path, rather than being a piece of
/// content only this feature knows how to show.
@Model
final class AIReviewItem {
    /// Stable identifier independent of `persistentModelID`, used to key this
    /// item's scheduled local notification (`AIReviewNotifications`) and its
    /// entry in the notification bell feed.
    var id: UUID = UUID()
    var questionText: String = ""
    /// The AIトーク thread the question came from, kept only for display
    /// ("〇〇での質問" on the review screen) — not a relationship, since the
    /// review must keep making sense even if the thread is later deleted.
    var threadTitle: String = ""
    var createdAt: Date = Date.now
    /// When the review should surface — the day after `createdAt`.
    var reviewDate: Date = Date.now
    var explanationMarkdown: String = ""
    /// JSON-encoded `[AIQuizQuestion]`.
    @Attribute(.externalStorage) var quizData: Data?
    var explanationDocument: TextDocument?

    init(
        questionText: String,
        threadTitle: String,
        createdAt: Date,
        reviewDate: Date,
        explanationMarkdown: String,
        quiz: [AIQuizQuestion]
    ) {
        self.questionText = questionText
        self.threadTitle = threadTitle
        self.createdAt = createdAt
        self.reviewDate = reviewDate
        self.explanationMarkdown = explanationMarkdown
        self.quizData = try? JSONEncoder().encode(quiz)
    }

    var quiz: [AIQuizQuestion] {
        guard let quizData, let decoded = try? JSONDecoder().decode([AIQuizQuestion].self, from: quizData) else {
            return []
        }
        return decoded
    }
}

struct AIQuizQuestion: Codable, Equatable {
    let question: String
    let answer: String
}
