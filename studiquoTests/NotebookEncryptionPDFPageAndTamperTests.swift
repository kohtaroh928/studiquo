import CryptoKit
import Foundation
import XCTest
@testable import studiquo

@MainActor
final class NotebookEncryptionPDFPageAndTamperTests: XCTestCase {
    private var keyServices: [String] = []

    override func tearDown() {
        for service in keyServices {
            NotebookEncryptionKeyStore.deleteKey(service: service)
        }
        keyServices = []
        super.tearDown()
    }

    private func uniqueKeyService() -> String {
        let service = "NotebookEncryptionPDFPageTests-\(UUID().uuidString)"
        keyServices.append(service)
        return service
    }

    // MARK: - 1. One-page PDF (backgroundPDFData) encryption, plaintext non-leakage, and restoration

    func testLockSealsAndWipesPagePDFDataWithoutPlaintextLeakAndUnlockRestoresItExactly() throws {
        let service = uniqueKeyService()
        let notebook = Notebook(title: "解析学PDFノート")
        let page = NotePage(order: 0, backgroundImageData: Data([0x89, 0x50, 0x4E, 0x47]))
        page.title = "コーシー列の定義"
        page.recognizedText = "任意の正数 ε に対して番号 N が存在する"
        let secretPDF = Data("%PDF-1.4 CauchySequenceSecretWord ConvergenceCriterion".utf8)
        page.backgroundPDFData = secretPDF
        page.notebook = notebook
        notebook.addPage(page)

        NotebookEncryptionService.lock(notebook, keyService: service)

        // Live fields including backgroundPDFData must be wiped while locked:
        let ciphertext = try XCTUnwrap(notebook.encryptedContent)
        XCTAssertNil(page.backgroundPDFData, "backgroundPDFData must be wiped when notebook is locked")
        XCTAssertNil(page.backgroundImageData)
        XCTAssertEqual(page.recognizedText, "")
        XCTAssertEqual(page.title, "")

        // Ciphertext must not contain plaintext UTF-8 bytes of the PDF words or recognizedText:
        XCTAssertNil(ciphertext.range(of: Data("CauchySequenceSecretWord".utf8)))
        XCTAssertNil(ciphertext.range(of: Data("ConvergenceCriterion".utf8)))
        XCTAssertNil(ciphertext.range(of: Data("任意の正数".utf8)))

        // Unlock restores backgroundPDFData identically:
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertNil(notebook.encryptedContent)
        XCTAssertEqual(page.backgroundPDFData, secretPDF)
        XCTAssertEqual(page.title, "コーシー列の定義")
        XCTAssertEqual(page.recognizedText, "任意の正数 ε に対して番号 N が存在する")
    }

    // MARK: - 2. Backward compatibility with legacy sealed payloads that predate backgroundPDFData

    func testUnlockAcceptsLegacyEncryptedPayloadWithoutBackgroundPDFDataField() throws {
        let service = uniqueKeyService()
        let notebook = Notebook(title: "旧形式の保護ノート")
        let page = NotePage(order: 0)
        let element = PageElement(kind: .text, text: "")
        element.layerIndex = 1
        page.addElement(element)
        page.notebook = notebook
        notebook.addPage(page)

        // Build a legacy JSON payload that omits `backgroundPDFData` completely:
        let legacyJSON = """
        {
          "pages": [
            {
              "drawingData": "\(Data("legacy-ink".utf8).base64EncodedString())",
              "backgroundImageData": "\(Data("legacy-bg".utf8).base64EncodedString())",
              "title": "旧ページのタイトル",
              "recognizedText": "旧バージョンのOCR本文",
              "flashcardQuestion": "旧問題",
              "flashcardAnswer": "旧解答",
              "elements": [
                {
                  "layerIndex": 1,
                  "text": "旧要素テキスト"
                }
              ]
            }
          ]
        }
        """
        let key = NotebookEncryptionKeyStore.loadOrCreateKey(service: service)
        let sealed = try AES.GCM.seal(Data(legacyJSON.utf8), using: key)
        notebook.encryptedContent = try XCTUnwrap(sealed.combined)

        let unlocked = NotebookEncryptionService.unlock(notebook, keyService: service)

        XCTAssertTrue(unlocked, "Legacy sealed notebooks without backgroundPDFData key must unlock cleanly")
        XCTAssertNil(notebook.encryptedContent)
        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.drawingData, Data("legacy-ink".utf8))
        XCTAssertEqual(page.backgroundImageData, Data("legacy-bg".utf8))
        XCTAssertEqual(page.title, "旧ページのタイトル")
        XCTAssertEqual(page.recognizedText, "旧バージョンのOCR本文")
        XCTAssertEqual(page.allElements.first?.text, "旧要素テキスト")
    }

    // MARK: - 3. Tampered or truncated ciphertext fails closed without losing sealed data

    func testUnlockFailsClosedWhenCiphertextIsTamperedOrTruncated() throws {
        let service = uniqueKeyService()
        let notebook = Notebook(title: "改ざん検知テスト")
        let page = NotePage(order: 0)
        page.recognizedText = "保護された本文"
        page.backgroundPDFData = Data("%PDF-1.4 word".utf8)
        page.notebook = notebook
        notebook.addPage(page)

        NotebookEncryptionService.lock(notebook, keyService: service)
        let validCiphertext = try XCTUnwrap(notebook.encryptedContent)

        // Flip a bit in the GCM authentication tag (last byte):
        var tampered = validCiphertext
        tampered[tampered.count - 1] ^= 0xFF
        notebook.encryptedContent = tampered

        XCTAssertFalse(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(notebook.encryptedContent, tampered, "Failed unlock must not wipe encryptedContent")
        XCTAssertNil(page.backgroundPDFData)
        XCTAssertEqual(page.recognizedText, "")

        // Truncated ciphertext also fails closed:
        let truncated = Data(validCiphertext.prefix(8))
        notebook.encryptedContent = truncated
        XCTAssertFalse(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(notebook.encryptedContent, truncated)

        // Restoring the valid ciphertext allows unlock to succeed:
        notebook.encryptedContent = validCiphertext
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(page.recognizedText, "保護された本文")
        XCTAssertNotNil(page.backgroundPDFData)
    }
}
