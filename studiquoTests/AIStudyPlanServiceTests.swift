import XCTest
import SwiftData
@testable import studiquo

@MainActor
final class AIStudyPlanServiceTests: XCTestCase {
    // MARK: Folder matching

    func testMatchesSelectedFoldersExactAndSubfolder() {
        XCTAssertTrue(AIStudyPlanService.matchesSelectedFolders("数学", selectedFolders: ["数学"]))
        XCTAssertTrue(AIStudyPlanService.matchesSelectedFolders("数学/微積分", selectedFolders: ["数学"]), "サブフォルダも含める")
        XCTAssertFalse(AIStudyPlanService.matchesSelectedFolders("数学英語", selectedFolders: ["数学"]), "前方一致だが別フォルダは含めない")
        XCTAssertFalse(AIStudyPlanService.matchesSelectedFolders("英語", selectedFolders: ["数学"]))
        XCTAssertFalse(AIStudyPlanService.matchesSelectedFolders("数学", selectedFolders: []))
    }

    // MARK: Notes

    private func makeNotebook(title: String, folderName: String, updatedAt: Date, text: String, isLocked: Bool = false, isTrashed: Bool = false) -> Notebook {
        let notebook = Notebook(title: title)
        notebook.folderName = folderName
        notebook.updatedAt = updatedAt
        notebook.isLocked = isLocked
        notebook.isTrashed = isTrashed
        let page = NotePage(order: 0)
        page.recognizedText = text
        page.notebook = notebook
        notebook.addPage(page)
        return notebook
    }

    func testNotesExcludesLockedAndTrashedAndUnrelatedFolders() {
        let target = makeNotebook(title: "対象", folderName: "数学", updatedAt: .now, text: "本文")
        let locked = makeNotebook(title: "ロック", folderName: "数学", updatedAt: .now, text: "秘密", isLocked: true)
        let trashed = makeNotebook(title: "ゴミ箱", folderName: "数学", updatedAt: .now, text: "消えた", isTrashed: true)
        let other = makeNotebook(title: "他教科", folderName: "英語", updatedAt: .now, text: "無関係")

        let notes = AIStudyPlanService.notes(from: [target, locked, trashed, other], selectedFolders: ["数学"])

        XCTAssertEqual(notes.map(\.title), ["対象"])
    }

    func testNotesSortsByMostRecentlyUpdatedFirst() {
        let old = makeNotebook(title: "古い", folderName: "数学", updatedAt: .now.addingTimeInterval(-86_400), text: "old")
        let new = makeNotebook(title: "新しい", folderName: "数学", updatedAt: .now, text: "new")

        let notes = AIStudyPlanService.notes(from: [old, new], selectedFolders: ["数学"])

        XCTAssertEqual(notes.map(\.title), ["新しい", "古い"])
    }

    func testNotesRespectsTheCharacterBudgetAcrossMultipleNotebooks() {
        let first = makeNotebook(title: "1冊目", folderName: "数学", updatedAt: .now, text: String(repeating: "あ", count: 100))
        let second = makeNotebook(title: "2冊目", folderName: "数学", updatedAt: .now.addingTimeInterval(-10), text: String(repeating: "い", count: 100))

        let notes = AIStudyPlanService.notes(from: [first, second], selectedFolders: ["数学"], characterBudget: 150)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].text.count, 100, "予算内に収まる1冊目は全文")
        XCTAssertEqual(notes[1].text.count, 50, "残り予算だけ2冊目に割り当てられ、途中で切られる")
    }

    // MARK: Decks

    private func makeDeck(title: String, folderName: String, totalAnswered: Int, totalCorrect: Int, isTrashed: Bool = false) -> FlashcardDeck {
        let deck = FlashcardDeck(title: title)
        deck.folderName = folderName
        deck.totalAnswered = totalAnswered
        deck.totalCorrect = totalCorrect
        deck.isTrashed = isTrashed
        return deck
    }

    func testDecksSortsByLowestAccuracyFirstAndNeverStudiedIsTreatedAsWeakest() {
        let high = makeDeck(title: "高正答率", folderName: "数学", totalAnswered: 10, totalCorrect: 9)
        let low = makeDeck(title: "低正答率", folderName: "数学", totalAnswered: 10, totalCorrect: 2)
        let neverStudied = makeDeck(title: "未実施", folderName: "数学", totalAnswered: 0, totalCorrect: 0)

        let decks = AIStudyPlanService.decks(from: [high, low, neverStudied], selectedFolders: ["数学"])

        XCTAssertEqual(decks.map(\.title), ["未実施", "低正答率", "高正答率"])
        XCTAssertNil(decks[0].averageAccuracyPercent)
        XCTAssertEqual(decks[1].averageAccuracyPercent, 20)
    }

    func testDecksExcludesTrashedAndUnrelatedFolders() {
        let target = makeDeck(title: "対象", folderName: "数学", totalAnswered: 1, totalCorrect: 1)
        let trashed = makeDeck(title: "ゴミ箱", folderName: "数学", totalAnswered: 1, totalCorrect: 1, isTrashed: true)
        let other = makeDeck(title: "他教科", folderName: "英語", totalAnswered: 1, totalCorrect: 1)

        let decks = AIStudyPlanService.decks(from: [target, trashed, other], selectedFolders: ["数学"])

        XCTAssertEqual(decks.map(\.title), ["対象"])
    }

    // MARK: Documents

    func testDocumentsRespectsTheCharacterBudget() {
        let document = TextDocument(title: "文書")
        document.folderName = "数学"
        document.plainText = String(repeating: "う", count: 100)

        let documents = AIStudyPlanService.documents(from: [document], selectedFolders: ["数学"], characterBudget: 40)

        XCTAssertEqual(documents.first?.text.count, 40)
    }

    // MARK: Existing events

    func testExistingEventsFiltersToBetweenTodayAndTheTestDate() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 20
        let today = Calendar.current.date(from: components)!
        let testDate = Calendar.current.date(byAdding: .day, value: 10, to: today)!

        let before = CalendarEvent(title: "過去", startDate: today.addingTimeInterval(-86_400), endDate: today, kind: .other)
        let within = CalendarEvent(title: "範囲内", startDate: today.addingTimeInterval(3_600), endDate: today.addingTimeInterval(7_200), kind: .classLesson)
        let after = CalendarEvent(title: "テスト後", startDate: testDate.addingTimeInterval(86_400), endDate: testDate.addingTimeInterval(90_000), kind: .other)

        let events = AIStudyPlanService.existingEvents(from: [before, within, after], from: today, to: testDate)

        XCTAssertEqual(events.map(\.title), ["範囲内"])
        XCTAssertEqual(events.first?.kind, "classLesson")
    }

    // MARK: Date/time parsing

    func testSessionStartDateParsesAValidDateAndTime() {
        let date = AIStudyPlanService.sessionStartDate(date: "2026-09-22", startTime: "19:00")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try! XCTUnwrap(date))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 22)
        XCTAssertEqual(components.hour, 19)
        XCTAssertEqual(components.minute, 0)
    }

    func testSessionStartDateReturnsNilForMalformedInput() {
        XCTAssertNil(AIStudyPlanService.sessionStartDate(date: "来週", startTime: "夜"))
        XCTAssertNil(AIStudyPlanService.sessionStartDate(date: "", startTime: ""))
    }

    // MARK: Applying / deleting a plan

    private var storeURLs: [URL] = []

    override func setUp() {
        super.setUp()
        AIStudyPlanService.scheduleNotification = { _ in }
    }

    override func tearDown() {
        AIStudyPlanService.scheduleNotification = { await EventReminderNotifications.schedule(for: $0) }
        for url in storeURLs { try? FileManager.default.removeItem(at: url) }
        storeURLs = []
        super.tearDown()
    }

    private func makeContext() -> ModelContext {
        let schema = Schema([CalendarEvent.self])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AIStudyPlanServiceTests-\(UUID().uuidString).sqlite")
        storeURLs.append(url)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: configuration)
        return ModelContext(container)
    }

    func testApplySessionsCreatesLinkedEventsSharingOnePlanIDAndCallsTheNotificationSeam() async throws {
        var scheduledTitles: [String] = []
        AIStudyPlanService.scheduleNotification = { scheduledTitles.append($0.title) }

        let context = makeContext()
        let test = CalendarEvent(title: "期末試験", startDate: Date(timeIntervalSince1970: 2_000_000_000), endDate: Date(timeIntervalSince1970: 2_000_003_600), kind: .test)
        context.insert(test)

        let sessions = [
            AIStudyPlanResult.Session(date: "2026-09-22", startTime: "19:00", durationMinutes: 60, focus: "積分", reason: "正答率が低い"),
            AIStudyPlanResult.Session(date: "2026-09-23", startTime: "20:00", durationMinutes: 45, focus: "微分", reason: "分量が多い"),
        ]

        let created = await AIStudyPlanService.applySessions(sessions, test: test, modelContext: context)

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(Set(created.map { $0.planID }).count, 1, "同じ計画のセッションは同じplanIDを共有する")
        XCTAssertTrue(created.allSatisfy { $0.linkedTestEventID == test.id })
        XCTAssertTrue(created.allSatisfy { $0.kind == .studySession })
        XCTAssertTrue(created.allSatisfy { $0.externalSource == "ai-plan" })
        XCTAssertEqual(scheduledTitles.sorted(), ["微分", "積分"])

        let saved = try context.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(saved.count, 3, "テスト本体 + セッション2件")
    }

    func testApplySessionsSkipsASessionWithAnUnparseableDate() async throws {
        let context = makeContext()
        let test = CalendarEvent(title: "テスト", startDate: .now, endDate: .now, kind: .test)
        context.insert(test)

        let sessions = [
            AIStudyPlanResult.Session(date: "invalid", startTime: "invalid", durationMinutes: 30, focus: "壊れたセッション", reason: "テスト"),
        ]

        let created = await AIStudyPlanService.applySessions(sessions, test: test, modelContext: context)

        XCTAssertTrue(created.isEmpty)
    }

    func testDeletePlanRemovesOnlyThatPlansEvents() throws {
        let context = makeContext()
        let planA = UUID()
        let planB = UUID()
        let eventA1 = CalendarEvent(title: "A1", startDate: .now, endDate: .now, kind: .studySession)
        eventA1.planID = planA
        let eventA2 = CalendarEvent(title: "A2", startDate: .now, endDate: .now, kind: .studySession)
        eventA2.planID = planA
        let eventB = CalendarEvent(title: "B1", startDate: .now, endDate: .now, kind: .studySession)
        eventB.planID = planB
        [eventA1, eventA2, eventB].forEach(context.insert)
        try context.save()

        AIStudyPlanService.deletePlan(planA, events: [eventA1, eventA2, eventB], modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CalendarEvent>())
        XCTAssertEqual(remaining.map(\.title), ["B1"])
    }
}
