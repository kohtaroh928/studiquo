import XCTest
import SwiftData
@testable import studiquo

/// Guards the shape of the on-disk library. A careless model change (a
/// required attribute with no default, a unique constraint, a non-optional
/// relationship, a dropped entity) is exactly what makes an upgrade slow,
/// fail, or lose data, and breaks iCloud sync.
final class StoreSchemaTests: XCTestCase {
    /// Removing or renaming an entity discards its stored records on upgrade,
    /// so a change here must be deliberate: update this list in the same change.
    func testEntitySetOnlyChangesDeliberately() {
        let names = Set(studiquoSchema.entities.map(\.name))
        let expected: Set<String> = [
            "Notebook", "NotePage", "PageElement", "FlashcardDeck", "Flashcard", "CalendarEvent",
            "StudyActivity", "AIChatThread", "AIChatMessage", "TextDocument", "SlideDeck", "Slide",
            "SlideMaster", "SlideLayoutTemplate", "SlidePlaceholder", "SlideElement", "DocumentBlock",
            "DocumentTableRow", "DocumentTableCell", "DocumentHeaderFooter", "DocumentComment",
            "DocumentChangeRecord", "DocumentFootnote", "AIReviewItem", "Folder", "MCPImportReceipt",
        ]
        XCTAssertTrue(expected.isSubset(of: names), "entities removed from the schema: \(expected.subtracting(names).sorted())")
    }

    /// iCloud sync (CloudKit) rejects unique constraints, and an upgrade can
    /// only fill a new attribute from a default or nil.
    func testEveryEntityIsCloudKitAndUpgradeCompatible() {
        XCTAssertGreaterThan(studiquoSchema.entities.count, 20, "the schema looks empty; the checks below would prove nothing")
        for entity in studiquoSchema.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty, "\(entity.name) has a unique constraint")
            for attribute in entity.attributes where !attribute.isOptional {
                XCTAssertNotNil(attribute.defaultValue, "\(entity.name).\(attribute.name) is required but has no default")
            }
            for relationship in entity.relationships {
                XCTAssertTrue(relationship.isOptional, "\(entity.name).\(relationship.name) must be an optional relationship")
            }
        }
    }

    /// Launch decisions made before the first frame must be instant.
    func testResolvingTheSyncPreferenceAtLaunchIsInstant() {
        let started = Date()
        _ = ICloudSyncPreference.resolveAtLaunch()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }
}
