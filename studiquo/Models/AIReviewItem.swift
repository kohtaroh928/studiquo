import Foundation
import SwiftData

/// A piece of review material the AI put together from a question asked in
/// AIトーク, surfaced to the student the day after they asked it.
///
/// Only created for questions the AI judged worth reviewing (see
/// `AIReviewService`) — idle chat never produces one of these. The
/// student can choose to keep the explanation as a `TextDocument`
/// (`explanationDocument`, filed in the AI復習 folder) when the review
/// notification arrives; until then, and if they decline, no document exists.
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
    /// Set once the student has chosen to keep or not keep the explanation as
    /// a 文書. Kept means `explanationDocument != nil`; nil here means the
    /// choice is still open (the review screen asks).
    var documentDecidedAt: Date?
    var explanationDocument: TextDocument?

    var needsDocumentDecision: Bool { documentDecidedAt == nil && explanationDocument == nil }

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
