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
///
/// Generating a review does NOT create a 文書: the student decides when the
/// review notification arrives (action buttons or the review screen) whether
/// to keep the explanation as a document in the "AI復習" folder
/// (`keepAsDocument`) or not (`declineDocument`).
enum AIReviewService {
    /// The 文書 folder every generated explanation is filed into, so they
    /// stay together in the student's own library rather than scattered
    /// loose at the top level.
    static let reviewFolderName = "AI復習"

    /// Backs the "AIトークの翌日復習を作成する" toggle in `AppSettingsView`.
    /// A new key avoids treating a legacy implicit-on preference as consent.
    static let isEnabledDefaultsKey = "aiTalkDayAfterReviewOptInV2"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool) ?? false
    }

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
        guard isEnabled, AIDataDisclosure.hasBeenAcknowledged else { return }
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, AI.provider.isConfigured else { return }

        guard let result = try? await AI.provider.researchReview(question: question, context: ""),
              isEnabled, AIDataDisclosure.hasBeenAcknowledged,
              result.isStudyRelevant,
              !result.explanationMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let item = AIReviewItem(
            questionText: question,
            threadTitle: threadTitle,
            createdAt: askedAt,
            reviewDate: nextReviewDate(after: askedAt),
            explanationMarkdown: result.explanationMarkdown,
            quiz: result.quiz
        )
        modelContext.insert(item)
        try? modelContext.save()

        await scheduleNotification(item)
    }

    /// Files the explanation as a 文書 in the AI復習 folder. Idempotent: an
    /// item that already has a document returns it unchanged.
    @MainActor
    @discardableResult
    static func keepAsDocument(_ item: AIReviewItem, modelContext: ModelContext) -> TextDocument {
        if let existing = item.explanationDocument {
            item.documentDecidedAt = item.documentDecidedAt ?? .now
            return existing
        }
        let document = makeDocument(for: item)
        let folder = AIReviewFolder.ensure(in: modelContext)
        document.folder = folder
        document.folderName = folder.legacyPath
        modelContext.insert(document)
        item.explanationDocument = document
        item.documentDecidedAt = .now
        try? modelContext.save()
        return document
    }

    /// The student chose not to keep a document. The review itself stays
    /// readable from its own screen.
    @MainActor
    static func declineDocument(_ item: AIReviewItem, modelContext: ModelContext) {
        guard item.explanationDocument == nil else { return }
        item.documentDecidedAt = .now
        try? modelContext.save()
    }

    /// A document that is not inserted anywhere, for PDF export of a review
    /// the student did not keep.
    static func makeDocument(for item: AIReviewItem) -> TextDocument {
        let document = TextDocument(title: reviewDocumentTitle(for: item.questionText))
        let attributed = DocumentBody.attributedString(
            // A document is plain formatted text, so formulas become readable text.
            fromMarkup: MathTextFormatter.readableText(from: item.explanationMarkdown)
        )
        document.bodyData = DocumentBody.encode(attributed)
        document.plainText = attributed.string
        return document
    }

    /// Applies decisions made on a notification button while the app had no
    /// UI to act on, and adopts documents filed before the folder existed.
    @MainActor
    static func reconcile(modelContext: ModelContext) {
        let pending = AIReviewDecisionQueue.drain()
        if !pending.isEmpty,
           let items = try? modelContext.fetch(FetchDescriptor<AIReviewItem>()) {
            for (id, keep) in pending {
                guard let item = items.first(where: { $0.id == id }) else { continue }
                if keep { keepAsDocument(item, modelContext: modelContext) }
                else { declineDocument(item, modelContext: modelContext) }
            }
        }
        AIReviewFolder.adoptOrphanedDocuments(in: modelContext)
    }

    static func reviewDocumentTitle(for question: String) -> String {
        let snippet = question.count > 20 ? String(question.prefix(20)) + "…" : question
        return "復習: \(snippet)"
    }

    /// The next day, at a fixed mid-morning hour rather than whatever minute
    /// the question happened to be asked — a review at 2:13am is not useful.
    ///
    /// `calendar` defaults to `.current` in production; tests pass one in a
    /// specific, DST-observing time zone to pin down that a spring-forward
    /// or fall-back transition between `askedAt` and the next day doesn't
    /// shift the result off the intended local hour — `bySettingHour`
    /// re-derives the wall-clock hour from `calendar`'s own time zone rather
    /// than from a raw 24-hour offset, which is what makes that safe.
    static func nextReviewDate(after askedAt: Date, hour: Int = 9, calendar: Calendar = .current) -> Date {
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
    static let keepActionIdentifier = "ai-review-keep-document"
    static let declineActionIdentifier = "ai-review-decline-document"

    static func schedule(for item: AIReviewItem) async {
        let identifier = identifierPrefix + item.id.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard AppNotificationPreferences.isEnabled(.aiReview) else { return }
        await UniversityCalendar.requestNotificationPermission()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        guard item.reviewDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = L("復習の時間です")
        content.body = L("昨日の質問「\(item.questionText.prefix(40))」を復習できます")
        AppNotificationPreferences.applyPresentation(to: content, kind: .aiReview)
        // Which review to open when the notification is tapped.
        content.userInfo = ["route": AppNotificationKind.aiReview.rawValue, "reviewID": item.id.uuidString]

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

/// The AI復習 folder in the 文書 library. A real `Folder` plus the local
/// folder-list metadata the library views read, so it shows up in the list,
/// the sidebar and "フォルダへ移動" like a folder the student made.
enum AIReviewFolder {
    @MainActor
    static func ensure(in context: ModelContext) -> Folder {
        let name = AIReviewService.reviewFolderName
        let roots = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let folder: Folder
        if let existing = roots.first(where: { $0.parent == nil && $0.name == name }) {
            folder = existing
        } else {
            folder = Folder(name: name)
            context.insert(folder)
        }
        register(path: folder.legacyPath, createdAt: folder.createdAt)
        return folder
    }

    /// Adds the path to the AppStorage-backed lists (`libraryFolderNames`,
    /// `libraryFolderCreatedAt`) that the library views still filter by.
    static func register(path: String, createdAt: Date, defaults: UserDefaults = .standard) {
        var names = Set((defaults.string(forKey: "libraryFolderNames") ?? "").split(separator: "\n").map(String.init))
        guard names.insert(path).inserted else { return }
        defaults.set(names.sorted().joined(separator: "\n"), forKey: "libraryFolderNames")
        var dates: [String: TimeInterval] = [:]
        if let data = (defaults.string(forKey: "libraryFolderCreatedAt") ?? "{}").data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            dates = decoded
        }
        if dates[path] == nil { dates[path] = createdAt.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(dates), let value = String(data: data, encoding: .utf8) {
            defaults.set(value, forKey: "libraryFolderCreatedAt")
        }
    }

    /// Documents filed by earlier versions only carried the "AI復習" path
    /// string, with no folder behind it, so they were hidden everywhere.
    @MainActor
    static func adoptOrphanedDocuments(in context: ModelContext) {
        let name = AIReviewService.reviewFolderName
        let descriptor = FetchDescriptor<TextDocument>(predicate: #Predicate { $0.folderName == name })
        guard let documents = try? context.fetch(descriptor) else { return }
        let orphans = documents.filter { $0.folder == nil }
        guard !orphans.isEmpty else { return }
        let folder = ensure(in: context)
        for document in orphans { document.folder = folder }
        try? context.save()
    }
}

/// Keep/decline taps on a review notification arrive in the app delegate,
/// which has no model context (and may run with no UI at all). They are
/// parked here and applied by `AIReviewService.reconcile`.
enum AIReviewDecisionQueue {
    private static let key = "aiReviewPendingDocumentDecisions"
    static let didChange = Notification.Name("StudiquoAIReviewDecisionQueued")

    static func enqueue(reviewID: UUID, keep: Bool, defaults: UserDefaults = .standard) {
        var entries = defaults.stringArray(forKey: key) ?? []
        entries.append("\(keep ? "1" : "0"):\(reviewID.uuidString)")
        defaults.set(entries, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func drain(defaults: UserDefaults = .standard) -> [(UUID, Bool)] {
        let entries = defaults.stringArray(forKey: key) ?? []
        defaults.removeObject(forKey: key)
        return entries.compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            return (id, parts[0] == "1")
        }
    }
}
