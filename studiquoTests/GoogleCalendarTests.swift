import XCTest
@testable import studiquo

final class GoogleCalendarTests: XCTestCase {
    override func tearDown() {
        GoogleCalendar.connectedEmail = nil
        super.tearDown()
    }

    func testConnectedEmailPersistsAndCanBeCleared() {
        GoogleCalendar.connectedEmail = "student@example.com"
        XCTAssertEqual(GoogleCalendar.connectedEmail, "student@example.com")

        GoogleCalendar.connectedEmail = nil
        XCTAssertNil(GoogleCalendar.connectedEmail)
    }

    func testCalendarListRequestUsesReadOnlyQueryAndBearerToken() throws {
        let request = GoogleCalendar.calendarListRequest(accessToken: "token-123")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(query["minAccessRole"], "reader")
        XCTAssertEqual(query["showHidden"], "false")
    }

    func testOnlySelectedCalendarsAreImported() throws {
        let data = Data(#"{"items":[{"id":"primary","summary":"Main","selected":true},{"id":"hidden","summary":"Hidden","selected":false},{"id":"default","summary":"Default"}]}"#.utf8)
        let calendars = try GoogleCalendar.decodeSelectedCalendars(from: data)

        XCTAssertEqual(calendars.map(\.id), ["primary", "default"])
    }

    func testEventsRequestContainsSyncWindowExpansionOptionsAndEncodedCalendarID() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T00:00:00Z"))
        let request = GoogleCalendar.eventsRequest(
            calendarID: "class/calendar@example.com",
            accessToken: "secret",
            timeMin: start,
            timeMax: end
        )
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertTrue(components.percentEncodedPath.contains("class%2Fcalendar@example.com"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(query["singleEvents"], "true")
        XCTAssertEqual(query["orderBy"], "startTime")
        XCTAssertNotNil(query["timeMin"])
        XCTAssertNotNil(query["timeMax"])
    }

    func testTimedEventIsDecodedWithDescriptionAndStableExternalID() throws {
        let events = try decode(#"{"items":[{"id":"event-1","summary":"Lecture","description":"Room 2","start":{"dateTime":"2026-09-21T10:00:00+09:00"},"end":{"dateTime":"2026-09-21T11:30:00+09:00"}}]}"#)
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.id, "primary:event-1")
        XCTAssertEqual(event.title, "Lecture")
        XCTAssertEqual(event.notes, "Room 2")
        XCTAssertEqual(event.calendarName, "Main")
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 90 * 60, accuracy: 0.1)
    }

    func testAllDayEventUsesExclusiveGoogleEndDate() throws {
        let events = try decode(#"{"items":[{"id":"all-day","summary":"Holiday","start":{"date":"2026-09-21"},"end":{"date":"2026-09-22"}}]}"#)
        let event = try XCTUnwrap(events.first)

        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 24 * 60 * 60 - 1, accuracy: 0.1)
    }

    func testCancelledAndInvalidEventsAreSkipped() throws {
        let events = try decode(#"{"items":[{"id":"cancelled","status":"cancelled","start":{"dateTime":"2026-09-21T10:00:00Z"},"end":{"dateTime":"2026-09-21T11:00:00Z"}},{"id":"invalid","start":{},"end":{}}]}"#)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingTitleDescriptionAndEndReceiveSafeDefaults() throws {
        let events = try decode(#"{"items":[{"id":"minimal","summary":"","start":{"dateTime":"2026-09-21T10:00:00Z"},"end":{}}]}"#)
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.title, L("無題の予定"))
        XCTAssertEqual(event.notes, "")
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 60 * 60, accuracy: 0.1)
    }

    func testImportEventPreservesCalendarEventFields() throws {
        let event = try XCTUnwrap(try decode(#"{"items":[{"id":"event-2","summary":"Exam","description":"Bring ID","start":{"dateTime":"2026-09-21T10:00:00Z"},"end":{"dateTime":"2026-09-21T12:00:00Z"}}]}"#).first)
        let imported = event.importEvent

        XCTAssertEqual(imported.id, event.id)
        XCTAssertEqual(imported.title, event.title)
        XCTAssertEqual(imported.startDate, event.startDate)
        XCTAssertEqual(imported.endDate, event.endDate)
        XCTAssertEqual(imported.notes, event.notes)
        XCTAssertEqual(imported.isAllDay, event.isAllDay)
    }

    private func decode(_ json: String) throws -> [GoogleCalendar.APIEvent] {
        try GoogleCalendar.decodeEvents(
            from: Data(json.utf8),
            calendarID: "primary",
            calendarName: "Main"
        )
    }
}
