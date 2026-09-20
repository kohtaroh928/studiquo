import Foundation
import SwiftData

/// Turns a test plus whatever folders the student points at it into a
/// proposed day-by-day study schedule, and — once the student picks which
/// sessions to keep — writes them as ordinary `CalendarEvent`s.
///
/// Deliberately two separate steps rather than one: `generatePlan` only
/// calls the AI and hands back a plain result for a preview screen;
/// `applySessions` is what actually touches the student's calendar, and
/// only for the sessions they chose to keep.
enum AIStudyPlanService {
    /// Mirrors the server's own caps (`ai.js`'s `MAX_PLAN_*` constants) —
    /// keeping the request small client-side too, not just relying on the
    /// server to trim what's sent.
    static let maxNotes = 10
    static let maxDecks = 5
    static let maxDocuments = 5
    static let maxEvents = 30
    /// Total characters across every note or document text block combined.
    static let materialCharacterBudget = 12_000

    /// A folder "matches" a selection if it *is* one of the selected
    /// folders, or is nested under one (this app's folders nest via a
    /// `/`-delimited path in `folderName`) — picking a parent folder should
    /// pull in everything organized underneath it.
    static func matchesSelectedFolders(_ folderName: String, selectedFolders: [String]) -> Bool {
        guard !selectedFolders.isEmpty else { return false }
        return selectedFolders.contains { selected in
            !selected.isEmpty && (folderName == selected || folderName.hasPrefix(selected + "/"))
        }
    }

    /// Locked notebooks are silently excluded — their content is encrypted
    /// (`NotebookEncryptionService`) whenever they aren't the one currently
    /// open, so there is nothing readable to send even if they matched.
    static func notes(from notebooks: [Notebook], selectedFolders: [String], characterBudget: Int = materialCharacterBudget) -> [AIStudyPlanRequest.Note] {
        let candidates = notebooks
            .filter { !$0.isTrashed && !$0.isLocked && matchesSelectedFolders($0.folderName, selectedFolders: selectedFolders) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxNotes)

        var remaining = characterBudget
        var result: [AIStudyPlanRequest.Note] = []
        for notebook in candidates {
            guard remaining > 0 else { break }
            let fullText = notebook.sortedPages.map(\.recognizedText).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !fullText.isEmpty else { continue }
            let text = String(fullText.prefix(remaining))
            remaining -= text.count
            result.append(AIStudyPlanRequest.Note(title: notebook.title, text: text))
        }
        return result
    }

    /// Sorted so the weakest (lowest accuracy, or never studied at all)
    /// decks come first — those are the ones most worth the model's
    /// attention when only `maxDecks` fit.
    static func decks(from decks: [FlashcardDeck], selectedFolders: [String]) -> [AIStudyPlanRequest.Deck] {
        decks
            .filter { !$0.isTrashed && matchesSelectedFolders($0.folderName, selectedFolders: selectedFolders) }
            .sorted { ($0.averageAccuracy ?? -1) < ($1.averageAccuracy ?? -1) }
            .prefix(maxDecks)
            .map {
                AIStudyPlanRequest.Deck(
                    title: $0.title, cardCount: $0.sortedCards.count,
                    averageAccuracyPercent: $0.averageAccuracy, lastStudiedAt: $0.lastStudiedAt
                )
            }
    }

    static func documents(from documents: [TextDocument], selectedFolders: [String], characterBudget: Int = materialCharacterBudget) -> [AIStudyPlanRequest.Document] {
        let candidates = documents
            .filter { !$0.isTrashed && matchesSelectedFolders($0.folderName, selectedFolders: selectedFolders) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxDocuments)

        var remaining = characterBudget
        var result: [AIStudyPlanRequest.Document] = []
        for document in candidates {
            guard remaining > 0, !document.plainText.isEmpty else { continue }
            let text = String(document.plainText.prefix(remaining))
            remaining -= text.count
            result.append(AIStudyPlanRequest.Document(title: document.title, text: text))
        }
        return result
    }

    /// Only the shape of existing events (title/kind/time), never their
    /// `notes` — keeps unrelated personal event details out of the request.
    static func existingEvents(from events: [CalendarEvent], from today: Date, to testDate: Date) -> [AIStudyPlanRequest.ExistingEvent] {
        events
            .filter { $0.startDate >= today && $0.startDate <= testDate }
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)
            .map { AIStudyPlanRequest.ExistingEvent(title: $0.title, kind: $0.kind.rawValue, startDate: $0.startDate, endDate: $0.endDate) }
    }

    static func makeRequest(
        test: CalendarEvent,
        selectedFolders: [String],
        notebooks: [Notebook],
        flashcardDecks: [FlashcardDeck],
        textDocuments: [TextDocument],
        calendarEvents: [CalendarEvent],
        today: Date = .now
    ) -> AIStudyPlanRequest {
        AIStudyPlanRequest(
            testTitle: test.title,
            testDate: test.startDate,
            today: today,
            notes: notes(from: notebooks, selectedFolders: selectedFolders),
            decks: decks(from: flashcardDecks, selectedFolders: selectedFolders),
            documents: documents(from: textDocuments, selectedFolders: selectedFolders),
            existingEvents: existingEvents(from: calendarEvents, from: today, to: test.startDate)
        )
    }

    static func generatePlan(for request: AIStudyPlanRequest) async throws -> AIStudyPlanResult {
        try await AI.provider.planStudySessions(request)
    }

    /// Swappable seam, same shape as `AIReviewService.scheduleNotification`:
    /// the real path touches `UNUserNotificationCenter`, which hangs
    /// indefinitely inside an XCTest unit-test host. Tests substitute a
    /// no-op; production never touches this.
    static var scheduleNotification: (CalendarEvent) async -> Void = { await EventReminderNotifications.schedule(for: $0) }

    /// Parses `"YYYY-MM-DD"` + `"HH:mm"` in the current calendar/time zone.
    /// A session the model returned in a format that doesn't parse is
    /// dropped rather than crashing or guessing — better to silently omit
    /// one proposed session than to schedule something at the wrong time.
    static func sessionStartDate(date: String, startTime: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(startTime)")
    }

    /// Creates and inserts a `CalendarEvent` for each session, grouped under
    /// one new `planID` and linked back to `test`, then schedules each
    /// one's reminder the same way a manually created event would.
    @MainActor
    @discardableResult
    static func applySessions(
        _ sessions: [AIStudyPlanResult.Session],
        test: CalendarEvent,
        modelContext: ModelContext
    ) async -> [CalendarEvent] {
        let planID = UUID()
        var created: [CalendarEvent] = []
        for session in sessions {
            guard let start = sessionStartDate(date: session.date, startTime: session.startTime) else { continue }
            let end = start.addingTimeInterval(TimeInterval(max(session.durationMinutes, 1) * 60))
            let event = CalendarEvent(title: session.focus, startDate: start, endDate: end, kind: .studySession, notes: session.reason)
            event.externalSource = "ai-plan"
            event.planID = planID
            event.linkedTestEventID = test.id
            event.reminderDate = start.addingTimeInterval(-30 * 60)
            modelContext.insert(event)
            created.append(event)
        }
        try? modelContext.save()
        for event in created {
            await scheduleNotification(event)
        }
        return created
    }

    /// Removes every session belonging to `planID` — used to discard or
    /// regenerate a plan.
    static func deletePlan(_ planID: UUID, events: [CalendarEvent], modelContext: ModelContext) {
        for event in events where event.planID == planID {
            EventReminderNotifications.cancel(for: event)
            modelContext.delete(event)
        }
    }
}
