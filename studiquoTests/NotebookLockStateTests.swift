import XCTest
@testable import studiquo

final class NotebookLockStateTests: XCTestCase {
    func testUnprotectedNotebookNeedsNoAuthentication() {
        let state = NotebookLockState()
        XCTAssertEqual(state.requirement(isLocked: false, hasLockedPDF: false), .none)
    }

    func testFaceIDIsRequiredBeforePDFPasswordWhenBothProtectionsExist() {
        var state = NotebookLockState()
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: true), .faceID)

        XCTAssertTrue(state.recordFaceID(success: true, decrypted: true))
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: true), .pdfPassword)

        state.recordPDFPasswordVerified()
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: true), .none)
    }

    func testPDFOnlyNotebookRequestsPasswordDirectly() {
        var state = NotebookLockState()
        XCTAssertEqual(state.requirement(isLocked: false, hasLockedPDF: true), .pdfPassword)
        state.recordPDFPasswordVerified()
        XCTAssertEqual(state.requirement(isLocked: false, hasLockedPDF: true), .none)
    }

    func testFaceIDOnlyNotebookUnlocksAfterSuccessfulDecryption() {
        var state = NotebookLockState()
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: false), .faceID)
        XCTAssertTrue(state.recordFaceID(success: true, decrypted: true))
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: false), .none)
    }

    func testAuthenticationFailureKeepsNotebookLockedWithRetryMessage() {
        var state = NotebookLockState()
        XCTAssertFalse(state.recordFaceID(success: false, decrypted: false))
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: false), .faceID)
        XCTAssertEqual(state.faceIDMessage, "認証できませんでした。もう一度お試しください")
    }

    func testDecryptionFailureKeepsNotebookLockedWithSpecificMessage() {
        var state = NotebookLockState()
        XCTAssertFalse(state.recordFaceID(success: true, decrypted: false))
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: false), .faceID)
        XCTAssertEqual(state.faceIDMessage, "ノートの内容を復号できませんでした")
    }

    func testChangingNotebookResetsEveryUnlock() {
        var state = NotebookLockState()
        _ = state.recordFaceID(success: true, decrypted: true)
        state.recordPDFPasswordVerified()
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: true), .none)

        state.notebookDidChange()

        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: true), .faceID)
        XCTAssertEqual(state.faceIDMessage, "認証してノートを開いてください")
    }
}
