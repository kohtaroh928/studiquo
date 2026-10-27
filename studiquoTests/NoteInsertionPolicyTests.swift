import XCTest
@testable import studiquo

final class NoteInsertionPolicyTests: XCTestCase {
    func testOnlyNotePaneReceivesInsertionEvenWhenOtherPaneWasTouchedLast() {
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .secondary, primaryShowsNote: true, secondaryShowsNote: false),
            .primary
        )
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: false, secondaryShowsNote: true),
            .secondary
        )
    }

    func testLastTouchedNoteWinsWhenBothPanesAreNotes() {
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: true, secondaryShowsNote: true),
            .primary
        )
        XCTAssertEqual(
            NoteInsertionPolicy.targetPane(lastActive: .secondary, primaryShowsNote: true, secondaryShowsNote: true),
            .secondary
        )
    }

    func testNoTargetWhenNeitherPaneIsANote() {
        XCTAssertNil(
            NoteInsertionPolicy.targetPane(lastActive: .primary, primaryShowsNote: false, secondaryShowsNote: false)
        )
    }
}
