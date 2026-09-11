import Foundation
import SwiftData
import UserNotifications

/// Turns a question asked in AIトーク into tomorrow's review material.
///
/// Called once, fire-and-forget, right after a chat reply finishes streaming
/// successfully (see `NoteEditorView.sendAIChatMessage`). A failed or
/// irrelevant call is silently dropped — the student already has their normal
/// chat reply, and missing tomorrow's review material for one question isn't
/// worth surfacing an error for.
enum AIReviewService {
    /// The 文書 folder every generated explanation is filed into, so they
    /// stay together in the student's own library rather than scattered
    /// loose at the top level.
    static let reviewFolderName = "AI復習"

    /// Swappable seam, same shape as `AI.provider`: the real notification
    /// call goes through `UNUserNotificationCenter`, which hangs indefinitely
    /// inside an XCTest unit-test host process (there's no interactive UI to
    /// resolve a permission prompt against) — a real run of this suite hung
    /// on exactly that. Tests substitute a no-op; production never touches this.
    static var scheduleNotification: (AIReviewItem) async -> Void = { await AIReviewNotifications.schedule(for: $0) }

    @MainActor
    static func considerForReview(
        questionText: String,
        threadTitle: String,
        askedAt: Date,
        modelContext: ModelContext
    ) async {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, AI.provider.isConfigured else { return }

        guard let result = try? await AI.provider.researchReview(question: question, context: ""),
              result.isStudyRelevant,
              !result.explanationMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let document = TextDocument(title: reviewDocumentTitle(for: question))
        document.folderName = reviewFolderName
        let attributed = DocumentBody.attributedString(fromMarkup: result.explanationMarkdown)
        document.bodyData = DocumentBody.encode(attributed)
        document.plainText = attributed.string
        modelContext.insert(document)

        let item = AIReviewItem(
            questionText: question,
            threadTitle: threadTitle,
            createdAt: askedAt,
            reviewDate: nextReviewDate(after: askedAt),
            explanationMarkdown: result.explanationMarkdown,
            quiz: result.quiz
        )
        item.explanationDocument = document
        modelContext.insert(item)
        try? modelContext.save()

        await scheduleNotification(item)
    }

    private static func reviewDocumentTitle(for question: String) -> String {
        let snippet = question.count > 20 ? String(question.prefix(20)) + "…" : question
        return "復習: \(snippet)"
    }

    /// The next day, at a fixed mid-morning hour rather than whatever minute
    /// the question happened to be asked — a review at 2:13am is not useful.
    static func nextReviewDate(after askedAt: Date, hour: Int = 9) -> Date {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: askedAt) ?? askedAt.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: nextDay) ?? nextDay
    }
}

/// Local notification fired when an `AIReviewItem`'s `reviewDate` arrives.
///
/// Mirrors `EventReminderNotifications` (`CalendarHomeView.swift`): a
/// `UNCalendarNotificationTrigger` scheduled the moment the content is ready,
/// rather than any recurring background job checking for due reviews.
enum AIReviewNotifications {
    private static let identifierPrefix = "ai-review-"

    static func schedule(for item: AIReviewItem) async {
        let identifier = identifierPrefix + item.id.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        await UniversityCalendar.requestNotificationPermission()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        guard item.reviewDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = L("復習の時間です")
        content.body = L("昨日の質問「\(item.questionText.prefix(40))」を復習できます")
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.reviewDate),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancel(for item: AIReviewItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifierPrefix + item.id.uuidString]
        )
    }
}
