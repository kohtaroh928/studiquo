import XCTest
import SwiftData
@testable import studiquo

/// Regression coverage for a real bug: `AIReviewItem.explanationDocument`
/// was added with no inverse relationship on `TextDocument`. CloudKit
/// integration requires every relationship to have one, so `StudiquoApp`'s
/// real container — built with `cloudKitDatabase: .automatic` — failed this
/// validation on *every* launch. Because `init()` catches that failure and
/// silently falls back to a local-only store, the app kept working and
/// nothing crashed; it just stopped syncing to iCloud for every model in the
/// schema, not only the one with the missing inverse. A `try!` deeper in a
/// SwiftData test container surfaced it as a crash — these tests catch it
/// directly, without needing a crash to notice.
final class AppSchemaCloudKitCompatibilityTests: XCTestCase {
    /// Mirrors the exact `Schema([...])` in `StudiquoApp.init()`. Keep this
    /// list in sync with that one — the whole point is to validate the real
    /// app's schema, not a stand-in for it.
    private static let fullAppSchema = Schema([
        Notebook.self, NotePage.self, PageElement.self,
        FlashcardDeck.self, Flashcard.self, CalendarEvent.self, StudyActivity.self,
        AIChatThread.self, AIChatMessage.self,
        TextDocument.self, SlideDeck.self, Slide.self,
        SlideMaster.self, SlideLayoutTemplate.self, SlidePlaceholder.self, SlideElement.self,
        DocumentBlock.self, DocumentTableRow.self, DocumentTableCell.self,
        DocumentHeaderFooter.self, DocumentComment.self, DocumentChangeRecord.self, DocumentFootnote.self,
        AIReviewItem.self,
        Folder.self,
    ])

    /// A schema with a missing inverse fails here, synchronously and without
    /// touching the network or requiring an iCloud account — this is a
    /// schema-shape check, not a live CloudKit round trip.
    func testTheFullAppSchemaPassesCloudKitRelationshipValidation() throws {
        let configuration = ModelConfiguration(schema: Self.fullAppSchema, cloudKitDatabase: .automatic)
        XCTAssertNoThrow(try ModelContainer(for: Self.fullAppSchema, configurations: configuration))
    }

    /// Narrower than the full-schema check above: isolates the one
    /// relationship pair that actually broke, so a future regression here
    /// fails with a smaller, faster, more specific test rather than only the
    /// full-schema one.
    func testAIReviewItemAndTextDocumentHaveAMutualInverseRelationship() throws {
        let schema = Schema([TextDocument.self, AIReviewItem.self])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: configuration))
    }

    /// Same check for the block-based document structure added alongside
    /// `TextDocument`: each of these has its own inverse back to
    /// `TextDocument` (or, for `DocumentTableRow`/`DocumentTableCell`, back
    /// to their own parent), and `DocumentBlock.tableRows` needs one too.
    func testDocumentBlockStructureHasMutualInverseRelationships() throws {
        let schema = Schema([
            TextDocument.self,
            DocumentBlock.self, DocumentTableRow.self, DocumentTableCell.self,
            DocumentHeaderFooter.self, DocumentComment.self, DocumentChangeRecord.self, DocumentFootnote.self,
        ])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: configuration))
    }

    /// Same check for the canvas-based slide structure (design steps 2/4):
    /// `SlideDeck.master`, the master→layout→placeholder cascade, `Slide.elements`,
    /// `SlidePlaceholder.sourceElements` (deliberately non-cascade — see its
    /// doc comment), and `SlideElement`'s self-referencing group relationship
    /// all need their own inverse.
    func testSlideElementStructureHasMutualInverseRelationships() throws {
        let schema = Schema([
            SlideDeck.self, Slide.self,
            SlideMaster.self, SlideLayoutTemplate.self, SlidePlaceholder.self, SlideElement.self,
        ])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: configuration))
    }

    /// `Folder` has a self-referencing `parent`/`children` pair plus one
    /// inverse back from each of the four item types it can contain — all
    /// five need to validate on their own, not just as part of the full
    /// schema above.
    func testFolderStructureHasMutualInverseRelationships() throws {
        let schema = Schema([
            Folder.self, Notebook.self, FlashcardDeck.self, TextDocument.self, SlideDeck.self,
        ])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: configuration))
    }
}
