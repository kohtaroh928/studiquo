import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class ImportedPDFPasswordSessionTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeIDs() throws -> (PersistentIdentifier, PersistentIdentifier) {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        let first = TextDocument(title: "一冊目")
        let second = TextDocument(title: "二冊目")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        return (first.persistentModelID, second.persistentModelID)
    }

    func testAVerifiedNotebookIsConsumedExactlyOnce() throws {
        let (id, _) = try makeIDs()
        ImportedPDFPasswordSession.markVerified(id)
        XCTAssertTrue(ImportedPDFPasswordSession.consume(id), "取り込み直後の最初の表示ではパスワードを再入力させない")
        XCTAssertFalse(ImportedPDFPasswordSession.consume(id), "2回目以降は通常どおり確認する")
    }

    func testConsumingANotebookThatWasNeverVerifiedIsFalse() throws {
        let (id, _) = try makeIDs()
        XCTAssertFalse(ImportedPDFPasswordSession.consume(id))
    }

    func testVerificationIsTrackedPerNotebook() throws {
        let (first, second) = try makeIDs()
        ImportedPDFPasswordSession.markVerified(first)
        XCTAssertFalse(ImportedPDFPasswordSession.consume(second))
        XCTAssertTrue(ImportedPDFPasswordSession.consume(first))
    }

    func testMarkingTwiceStillConsumesOnce() throws {
        let (id, _) = try makeIDs()
        ImportedPDFPasswordSession.markVerified(id)
        ImportedPDFPasswordSession.markVerified(id)
        XCTAssertTrue(ImportedPDFPasswordSession.consume(id))
        XCTAssertFalse(ImportedPDFPasswordSession.consume(id))
    }
}
