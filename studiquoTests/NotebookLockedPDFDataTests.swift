import XCTest
@testable import studiquo

/// Coverage for `Notebook.lockedPDFData`/`hasLockedPDFToUnlock` — the flag
/// the library's long-press "PDFのパスワードを解除" menu item (grid tile's
/// `.contextMenu` and `notebookActions`, both in ContentView.swift) switches
/// on. A notebook imported from an unprotected PDF, or not from a PDF at
/// all, must never show that item; one imported from a password-protected
/// PDF must show it until the password is actually removed.
final class NotebookLockedPDFDataTests: XCTestCase {
    func testHasLockedPDFToUnlockIsFalseForAnOrdinaryNotebook() {
        let notebook = Notebook(title: "ノート")
        XCTAssertFalse(notebook.hasLockedPDFToUnlock, "PDFから取り込んだのでもパスワード付きでもないノートに、PDFのパスワード解除ボタンを出してはいけません。")
    }

    func testHasLockedPDFToUnlockIsTrueOnceLockedPDFDataIsSet() {
        let notebook = Notebook(title: "ノート")
        notebook.lockedPDFData = Data(repeating: 1, count: 10)
        XCTAssertTrue(notebook.hasLockedPDFToUnlock, "パスワード付きPDFの元データを保持している間は、長押しメニューに解除ボタンが出る必要があります。")
    }

    func testHasLockedPDFToUnlockReturnsToFalseOnceThePasswordIsRemoved() {
        let notebook = Notebook(title: "ノート")
        notebook.lockedPDFData = Data(repeating: 1, count: 10)
        // Mirrors what ContentView does right after a successful
        // PDFPasswordService.removePassword — the encrypted bytes are no
        // longer needed, and the menu item should disappear with them.
        notebook.lockedPDFData = nil
        XCTAssertFalse(notebook.hasLockedPDFToUnlock, "パスワードを解除した後は、もう一度解除する必要がないので長押しメニューの項目も消える必要があります。")
    }
}
