import Foundation
import SwiftData

@Model
final class FlashcardDeck {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool = false
    var folderName: String = ""
    var reversesQuestionAndAnswer: Bool = false
    var orderModeRawValue: String = FlashcardOrderMode.creation.rawValue
    /// How many times the deck has been studied end to end.
    var studySessionCount: Int = 0
    /// Every graded answer ever given in this deck, and how many were right.
    /// Kept as running totals rather than derived from the cards so the
    /// average survives cards being edited or deleted.
    var totalAnswered: Int = 0
    var totalCorrect: Int = 0
    var lastStudiedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Flashcard.deck)
    var cards: [Flashcard] = []

    init(title: String) {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedCards: [Flashcard] {
        cards.sorted { $0.order < $1.order }
    }

    var orderMode: FlashcardOrderMode {
        get { FlashcardOrderMode(rawValue: orderModeRawValue) ?? .creation }
        set { orderModeRawValue = newValue.rawValue }
    }

    /// Percent, 0–100. `nil` until the deck has been answered at least once,
    /// so the UI can say "—" instead of a misleading 0%.
    var averageAccuracy: Int? {
        guard totalAnswered > 0 else { return nil }
        return Int((Double(totalCorrect) / Double(totalAnswered) * 100).rounded())
    }

    var accuracyText: String {
        averageAccuracy.map { "\($0)%" } ?? "—"
    }
}

@Model
final class Flashcard {
    var question: String
    var answer: String
    var order: Int
    var createdAt: Date
    var mastery: Int = 0
    var reviewCount: Int = 0
    var lastReviewedAt: Date?
    var deck: FlashcardDeck?

    init(question: String, answer: String, order: Int) {
        self.question = question
        self.answer = answer
        self.order = order
        self.createdAt = .now
    }
}

enum FlashcardOrderMode: String, CaseIterable, Identifiable {
    case creation
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .creation: "作成順"
        case .random: "ランダム"
        }
    }
}
