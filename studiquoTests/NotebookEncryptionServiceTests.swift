import XCTest
import CryptoKit
@testable import studiquo

/// Regression coverage for real-at-rest encryption of a locked notebook —
/// the follow-up to `NotebookBackupServiceLockTests`, which only closed the
/// automatic-backup leak. `lock`/`unlock` are what actually make a locked
/// notebook's content unreadable while it's put away, not just hidden
/// behind a navigation gate.
///
/// Each test uses its own unique Keychain service (never the app's real
/// `NotebookEncryptionKeyStore.defaultService`), and cleans it up in
/// `tearDown` — this really does touch the Simulator's Keychain, the same
/// way `KeychainCredentialFixtures` already does for auth tests.
@MainActor
final class NotebookEncryptionServiceTests: XCTestCase {
    private var keyServices: [String] = []

    override func tearDown() {
        for service in keyServices { NotebookEncryptionKeyStore.deleteKey(service: service) }
        keyServices = []
        super.tearDown()
    }

    private func uniqueKeyService() -> String {
        let service = "NotebookEncryptionServiceTests-\(UUID().uuidString)"
        keyServices.append(service)
        return service
    }

    private func makeNotebook() -> (notebook: Notebook, page1: NotePage, page2: NotePage) {
        let notebook = Notebook(title: "数学")
        let page1 = NotePage(order: 0)
        page1.drawingData = "ink-1".data(using: .utf8)
        page1.backgroundImageData = "bg-1".data(using: .utf8)
        page1.title = "第1回"
        page1.recognizedText = "微分積分の基礎"
        page1.flashcardQuestion = "導関数とは？"
        page1.flashcardAnswer = "瞬間の変化率"
        page1.notebook = notebook

        let elementA = PageElement(kind: .text, text: "テキストA")
        elementA.layerIndex = 2
        let elementB = PageElement(kind: .image, imageData: "photo-b".data(using: .utf8))
        elementB.layerIndex = 0
        page1.addElement(elementA)
        page1.addElement(elementB)

        let page2 = NotePage(order: 1)
        page2.recognizedText = "積分の応用"
        page2.notebook = notebook

        notebook.addPage(page1)
        notebook.addPage(page2)
        return (notebook, page1, page2)
    }

    func testLockClearsLiveFieldsAndUnlockRestoresThemExactly() {
        let service = uniqueKeyService()
        let (notebook, page1, page2) = makeNotebook()

        NotebookEncryptionService.lock(notebook, keyService: service)

        XCTAssertNotNil(notebook.encryptedContent)
        XCTAssertNil(page1.drawingData)
        XCTAssertNil(page1.backgroundImageData)
        XCTAssertEqual(page1.title, "")
        XCTAssertEqual(page1.recognizedText, "")
        XCTAssertEqual(page1.flashcardQuestion, "")
        XCTAssertEqual(page1.flashcardAnswer, "")
        XCTAssertTrue(page1.allElements.allSatisfy { $0.text.isEmpty && $0.imageData == nil })
        XCTAssertEqual(page2.recognizedText, "")

        let succeeded = NotebookEncryptionService.unlock(notebook, keyService: service)

        XCTAssertTrue(succeeded)
        XCTAssertNil(notebook.encryptedContent)
        XCTAssertEqual(page1.drawingData, "ink-1".data(using: .utf8))
        XCTAssertEqual(page1.backgroundImageData, "bg-1".data(using: .utf8))
        XCTAssertEqual(page1.title, "第1回")
        XCTAssertEqual(page1.recognizedText, "微分積分の基礎")
        XCTAssertEqual(page1.flashcardQuestion, "導関数とは？")
        XCTAssertEqual(page1.flashcardAnswer, "瞬間の変化率")
        XCTAssertEqual(page2.recognizedText, "積分の応用")

        let textElement = page1.allElements.first { $0.kind == .text }
        XCTAssertEqual(textElement?.text, "テキストA")
        let imageElement = page1.allElements.first { $0.kind == .image }
        XCTAssertEqual(imageElement?.imageData, "photo-b".data(using: .utf8))
    }

    /// `NotePage.allElements` makes no ordering guarantee — this pins down
    /// that unlock matches each element's content back up by `layerIndex`,
    /// not by whatever position it happens to be at in the array.
    func testElementsAreMatchedBackByLayerIndexEvenIfTheArrayReorders() {
        let service = uniqueKeyService()
        let (notebook, page1, _) = makeNotebook()

        NotebookEncryptionService.lock(notebook, keyService: service)
        // Simulate the array coming back in a different order than it was
        // in when locked (SwiftData gives no ordering guarantee here).
        page1.elements?.reverse()

        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))

        let textElement = page1.allElements.first { $0.layerIndex == 2 }
        XCTAssertEqual(textElement?.text, "テキストA")
        let imageElement = page1.allElements.first { $0.layerIndex == 0 }
        XCTAssertEqual(imageElement?.imageData, "photo-b".data(using: .utf8))
    }

    func testUnlockOnANeverLockedNotebookIsANoOpThatSucceeds() {
        let (notebook, page1, _) = makeNotebook()
        let originalDrawingData = page1.drawingData

        let succeeded = NotebookEncryptionService.unlock(notebook, keyService: uniqueKeyService())

        XCTAssertTrue(succeeded)
        XCTAssertEqual(page1.drawingData, originalDrawingData, "nothing should change for a notebook that was never locked")
    }

    /// A wrong (or since-rotated) key must fail closed: the notebook stays
    /// sealed rather than the student silently losing their content, and
    /// this must not be something retrying the same Face ID prompt fixes.
    func testUnlockFailsAndLeavesContentSealedWhenTheKeyIsWrong() {
        let lockService = uniqueKeyService()
        let wrongService = uniqueKeyService()
        let (notebook, page1, _) = makeNotebook()

        NotebookEncryptionService.lock(notebook, keyService: lockService)
        let sealedContent = notebook.encryptedContent

        let succeeded = NotebookEncryptionService.unlock(notebook, keyService: wrongService)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(notebook.encryptedContent, sealedContent, "the sealed content must be untouched after a failed unlock")
        XCTAssertEqual(page1.recognizedText, "", "must not partially restore content on failure")
    }

    func testLoadOrCreateKeyIsStableAcrossCallsButDistinctPerService() {
        let serviceA = uniqueKeyService()
        let serviceB = uniqueKeyService()

        let first = rawBytes(NotebookEncryptionKeyStore.loadOrCreateKey(service: serviceA))
        let second = rawBytes(NotebookEncryptionKeyStore.loadOrCreateKey(service: serviceA))
        let other = rawBytes(NotebookEncryptionKeyStore.loadOrCreateKey(service: serviceB))

        XCTAssertEqual(first, second, "the same service must always return the same key")
        XCTAssertNotEqual(first, other, "different services must never share a key")
    }

    private func rawBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
