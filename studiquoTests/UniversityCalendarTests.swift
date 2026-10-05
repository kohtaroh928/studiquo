import XCTest
@testable import studiquo

final class UniversityCalendarTests: XCTestCase {
    func testWebcalLinksNormalizeToHTTPS() {
        XCTAssertEqual(
            UniversityCalendar.normalizedURLString("  webcal://lms.example.edu/feed.ics\n"),
            "https://lms.example.edu/feed.ics"
        )
        XCTAssertEqual(
            UniversityCalendar.normalizedURLString("WEBCALS://lms.example.edu/feed.ics"),
            "https://lms.example.edu/feed.ics"
        )
    }

    func testUniversityNameRecognizesSubdomainAndUnknownHostFallsBackToHost() {
        XCTAssertEqual(
            UniversityCalendar.universityName(forURL: "https://lms.waseda.jp/calendar"),
            "早稲田大学"
        )
        XCTAssertEqual(
            UniversityCalendar.displayName(forURL: "https://calendar.example.edu/feed"),
            "calendar.example.edu"
        )
    }

    func testTimedEventUsesTZIDDurationEscapesAndFoldedLines() throws {
        let events = try decode("""
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:event-1\r
        SUMMARY:Exam\\, Part 1\r
        DTSTART;TZID=America/New_York:20261005T090000\r
        DURATION:PT1H30M\r
        DESCRIPTION:Room 2\\nBring pencil and\r
         student ID\r
        BEGIN:VALARM\r
        DESCRIPTION:This must not replace the event description\r
        END:VALARM\r
        END:VEVENT\r
        END:VCALENDAR\r
        """)
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.id, "event-1")
        XCTAssertEqual(event.title, "Exam, Part 1")
        XCTAssertEqual(event.notes, "Room 2\nBring pencil andstudent ID")
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 90 * 60, accuracy: 0.1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(calendar.component(.hour, from: event.startDate), 9)
    }

    func testAllDayEndDateIsExclusiveAndDefaultEndCoversWholeDay() throws {
        let events = try decode("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:explicit
        SUMMARY:Explicit end
        DTSTART;VALUE=DATE:20261005
        DTEND;VALUE=DATE:20261006
        END:VEVENT
        BEGIN:VEVENT
        UID:default
        SUMMARY:Default end
        DTSTART;VALUE=DATE:20261007
        END:VEVENT
        END:VCALENDAR
        """)

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy(\.isAllDay))
        XCTAssertEqual(events[0].endDate.timeIntervalSince(events[0].startDate), 86_399, accuracy: 0.1)
        XCTAssertEqual(events[1].endDate.timeIntervalSince(events[1].startDate), 86_399, accuracy: 0.1)
    }

    func testInvalidEventsAreSkippedWithoutDiscardingValidOnes() throws {
        let events = try decode("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:no-title
        DTSTART:20261005T090000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:no-start
        SUMMARY:Missing start
        END:VEVENT
        BEGIN:VEVENT
        UID:valid
        SUMMARY:Valid
        DTSTART:20261005T090000Z
        DTEND:20261005T100000Z
        END:VEVENT
        END:VCALENDAR
        """)

        XCTAssertEqual(events.map(\.id), ["valid"])
    }

    func testNonCalendarPayloadIsRejected() {
        XCTAssertThrowsError(try UniversityCalendar.decodeEvents(from: Data("<html>login</html>".utf8))) { error in
            guard case UniversityCalendar.SyncError.notACalendar = error else {
                return XCTFail("Expected notACalendar, got \(error)")
            }
        }
    }

    func testFetchRejectsNonHTTPSAndCredentialBearingURLsBeforeNetworking() async {
        for rawURL in [
            "http://example.edu/feed.ics",
            "https://user:password@example.edu/feed.ics",
            "not a url",
        ] {
            do {
                _ = try await UniversityCalendar.fetch(from: rawURL)
                XCTFail("Expected invalidURL for \(rawURL)")
            } catch UniversityCalendar.SyncError.invalidURL {
                // Expected.
            } catch {
                XCTFail("Expected invalidURL, got \(error)")
            }
        }
    }

    private func decode(_ text: String) throws -> [UniversityCalendar.Event] {
        try UniversityCalendar.decodeEvents(from: Data(text.utf8))
    }
}
