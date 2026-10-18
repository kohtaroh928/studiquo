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

    // MARK: Keys are never replaced

    private func keys(_ service: String) -> [NotebookEncryptionKeyStore.StoredKey] {
        NotebookEncryptionKeyStore.allKeys(service: service)
    }

    /// The whole point: the sealed notebook reaches a new device before its key
    /// does. Opening it there must fail without making a key, so nothing can be
    /// overwritten; and once the key arrives the same notebook opens.
    func testUnlockWithoutTheKeyFailsCreatesNothingAndSucceedsOnceTheKeyArrives() throws {
        let service = uniqueKeyService()
        let (notebook, page1, _) = makeNotebook()
        NotebookEncryptionService.lock(notebook, keyService: service)
        let original = try XCTUnwrap(keys(service).first)
        NotebookEncryptionKeyStore.deleteKey(service: service) // this device has not received the key yet

        XCTAssertFalse(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertTrue(keys(service).isEmpty, "opening must never create a key")

        XCTAssertTrue(NotebookEncryptionKeyStore.addKey(id: original.id, key: original.key, service: service)) // the key syncs in
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(page1.recognizedText, "微分積分の基礎")
    }

    /// Two devices each make a key before either has synced. When they sync,
    /// both keys exist and every notebook still opens: nothing was overwritten.
    func testTwoKeysMadeBeforeSyncingBothKeepOpeningTheirNotebooks() throws {
        let service = uniqueKeyService()
        let (notebookA, pageA, _) = makeNotebook()
        NotebookEncryptionService.lock(notebookA, keyService: service)
        let keyA = try XCTUnwrap(keys(service).first)
        NotebookEncryptionKeyStore.deleteKey(service: service) // device B starts without it

        let (notebookB, pageB, _) = makeNotebook()
        NotebookEncryptionService.lock(notebookB, keyService: service) // B makes its own key
        XCTAssertEqual(keys(service).count, 1)
        XCTAssertNotEqual(keys(service).first?.id, keyA.id)

        XCTAssertTrue(NotebookEncryptionKeyStore.addKey(id: keyA.id, key: keyA.key, service: service)) // A's key syncs in
        XCTAssertEqual(keys(service).count, 2)
        XCTAssertTrue(NotebookEncryptionService.unlock(notebookA, keyService: service))
        XCTAssertTrue(NotebookEncryptionService.unlock(notebookB, keyService: service))
        XCTAssertEqual(pageA.recognizedText, "微分積分の基礎")
        XCTAssertEqual(pageB.recognizedText, "微分積分の基礎")
    }

    func testLockingNeverRemovesAnExistingKeyAndReusesTheNewestOne() throws {
        let service = uniqueKeyService()
        let older = SymmetricKey(size: .bits256)
        XCTAssertTrue(NotebookEncryptionKeyStore.addKey(id: "00112233445566778899aabbccddeeff", key: older, service: service))
        let (first, _, _) = makeNotebook()
        let (second, _, _) = makeNotebook()

        NotebookEncryptionService.lock(first, keyService: service)
        NotebookEncryptionService.lock(second, keyService: service)

        XCTAssertEqual(keys(service).count, 1, "an existing key is used, not replaced or added to")
        XCTAssertEqual(rawBytes(try XCTUnwrap(keys(service).first).key), rawBytes(older))
        XCTAssertTrue(NotebookEncryptionService.unlock(first, keyService: service))
        XCTAssertTrue(NotebookEncryptionService.unlock(second, keyService: service))
    }

    /// Notebooks sealed by builds from before this change have no key id and
    /// were sealed with the single original key. They must still open, the
    /// original key must survive, and re-sealing with it keeps the old format.
    func testNotebooksSealedByTheOldFormatStillOpenAndTheOldKeySurvives() throws {
        let service = uniqueKeyService()
        let legacyKey = SymmetricKey(size: .bits256)
        XCTAssertTrue(NotebookEncryptionKeyStore.addKey(id: nil, key: legacyKey, service: service))
        let (notebook, page1, _) = makeNotebook()

        NotebookEncryptionService.lock(notebook, keyService: service)
        let blob = try XCTUnwrap(notebook.encryptedContent)
        XCTAssertNotEqual(Array(blob.prefix(4)), Array("SQK1".utf8), "sealed with the id-less key stays in the old format")
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(page1.recognizedText, "微分積分の基礎")
        XCTAssertEqual(keys(service).count, 1)
        XCTAssertNil(keys(service).first?.id)
        XCTAssertEqual(rawBytes(try XCTUnwrap(keys(service).first).key), rawBytes(legacyKey))
    }

    func testANewKeyBlobNamesItsKeyAndAWrongKeyWithTheSameIdDoesNotOpenIt() throws {
        let service = uniqueKeyService()
        let (notebook, _, _) = makeNotebook()
        NotebookEncryptionService.lock(notebook, keyService: service)
        let blob = try XCTUnwrap(notebook.encryptedContent)
        XCTAssertEqual(Array(blob.prefix(4)), Array("SQK1".utf8))
        let id = try XCTUnwrap(keys(service).first?.id)

        NotebookEncryptionKeyStore.deleteKey(service: service)
        XCTAssertTrue(NotebookEncryptionKeyStore.addKey(id: id, key: SymmetricKey(size: .bits256), service: service))

        XCTAssertFalse(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(notebook.encryptedContent, blob)
    }

    /// A notebook whose key has not reached this device stays sealed. Putting it
    /// away again must not overwrite the sealed content with its empty fields.
    func testLockingAnAlreadySealedNotebookLeavesTheSealedContentAlone() throws {
        let service = uniqueKeyService()
        let (notebook, page1, _) = makeNotebook()
        XCTAssertTrue(NotebookEncryptionService.lock(notebook, keyService: service))
        let sealed = try XCTUnwrap(notebook.encryptedContent)
        let key = try XCTUnwrap(keys(service).first)
        NotebookEncryptionKeyStore.deleteKey(service: service)
        XCTAssertFalse(NotebookEncryptionService.unlock(notebook, keyService: service)) // key not here yet

        XCTAssertTrue(NotebookEncryptionService.lock(notebook, keyService: service))

        XCTAssertEqual(notebook.encryptedContent, sealed)
        XCTAssertTrue(keys(service).isEmpty, "locking an already-sealed notebook makes no key")
        NotebookEncryptionKeyStore.addKey(id: key.id, key: key.key, service: service)
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(page1.recognizedText, "微分積分の基礎")
    }

    func testLockReportsSuccess() {
        let (notebook, _, _) = makeNotebook()
        XCTAssertTrue(NotebookEncryptionService.lock(notebook, keyService: uniqueKeyService()))
        XCTAssertNotNil(notebook.encryptedContent)
    }

    func testWrapRefusesAKeyIdThatIsNotValid() {
        XCTAssertNil(SealedBlob.wrap(Data([1, 2, 3]), keyID: "not-hex"))
        XCTAssertEqual(SealedBlob.wrap(Data([1, 2, 3]), keyID: nil), Data([1, 2, 3]))
        XCTAssertNotNil(SealedBlob.wrap(Data([1, 2, 3]), keyID: SealedBlob.newKeyID()))
    }
}
