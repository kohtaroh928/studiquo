import CoreGraphics
import PDFKit
import XCTest
@testable import studiquo

final class PDFPasswordServiceTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        workDir = nil
        super.tearDown()
    }

    // MARK: - Fixture builders
    //
    // Real encrypted PDFs, built through CGContext's own encryption support
    // (the same mechanism PDFKit reads), rather than hand-rolled files. This
    // exercises the actual PDFKit/CoreGraphics unlock path instead of a
    // stand-in for it.

    private func makePDF(name: String, userPassword: String? = nil, ownerPassword: String? = nil, pageCount: Int = 2) -> URL {
        let url = workDir.appendingPathComponent(name)
        var auxInfo: [String: Any] = [:]
        if let userPassword { auxInfo[kCGPDFContextUserPassword as String] = userPassword }
        if let ownerPassword { auxInfo[kCGPDFContextOwnerPassword as String] = ownerPassword }
        if ownerPassword != nil {
            auxInfo[kCGPDFContextAllowsPrinting as String] = false
            auxInfo[kCGPDFContextAllowsCopying as String] = false
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            XCTFail("Failed to create PDF context for \(name)")
            return url
        }
        for _ in 0..<pageCount {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(mediaBox)
            context.endPage()
        }
        context.closePDF()
        return url
    }

    private func unprotectedPDF(pageCount: Int = 2) -> URL {
        makePDF(name: "plain.pdf", pageCount: pageCount)
    }

    private func userPasswordPDF(password: String = "s3cret", pageCount: Int = 2) -> URL {
        // An owner password is also set, matching how real-world protected
        // PDFs are produced (open password + a separate admin password) and
        // avoiding degenerate single-password encryption edge cases.
        makePDF(name: "user-locked.pdf", userPassword: password, ownerPassword: "owner-pw", pageCount: pageCount)
    }

    private func ownerOnlyPDF(pageCount: Int = 2) -> URL {
        makePDF(name: "owner-only.pdf", ownerPassword: "owner-pw", pageCount: pageCount)
    }

    // MARK: - needsPassword / isProtected

    func testNeedsPassword_falseForUnprotectedPDF() {
        XCTAssertFalse(PDFPasswordService.needsPassword(unprotectedPDF()))
    }

    func testNeedsPassword_trueForUserPasswordProtectedPDF() {
        XCTAssertTrue(PDFPasswordService.needsPassword(userPasswordPDF()))
    }

    func testNeedsPassword_falseForOwnerOnlyRestrictedPDF() {
        // Opens with an empty password; nothing to prompt the student for.
        XCTAssertFalse(PDFPasswordService.needsPassword(ownerOnlyPDF()))
    }

    func testIsProtected_trueForUserPasswordProtectedPDF() {
        XCTAssertTrue(PDFPasswordService.isProtected(userPasswordPDF()))
    }

    func testIsProtected_trueForOwnerOnlyRestrictedPDF() {
        XCTAssertTrue(PDFPasswordService.isProtected(ownerOnlyPDF()))
    }

    func testIsProtected_falseForUnprotectedPDF() {
        XCTAssertFalse(PDFPasswordService.isProtected(unprotectedPDF()))
    }

    // MARK: - removalOutcome
    //
    // Regression coverage for a UX bug found in review: the "remove
    // password" flow used to route an unprotected PDF into the very same
    // pending state as a real password prompt (`pdfPendingUnlock` in
    // ContentView), so its "not protected" notice reused the password
    // dialog's SecureField/OK/Cancel alert — pressing OK silently re-ran the
    // same failing removal forever. The fix funnels the decision through
    // this single, pure switch point so the three outcomes can never again
    // be wired to the wrong view state by a stray edit to a nested if/guard
    // chain.

    func testRemovalOutcome_notProtectedForPlainPDF() {
        XCTAssertEqual(PDFPasswordService.removalOutcome(for: unprotectedPDF()), .notProtected)
    }

    func testRemovalOutcome_needsPasswordForUserPasswordProtectedPDF() {
        XCTAssertEqual(PDFPasswordService.removalOutcome(for: userPasswordPDF()), .needsPassword)
    }

    func testRemovalOutcome_readyToStripImmediatelyForOwnerOnlyRestrictedPDF() {
        XCTAssertEqual(PDFPasswordService.removalOutcome(for: ownerOnlyPDF()), .readyToStripImmediately)
    }

    /// Pins the specific case the bug was about: an unprotected file must
    /// never be classified the same as one that genuinely needs a password,
    /// which is what let it slip into the password-prompt pending state.
    func testRemovalOutcome_notProtectedIsDistinctFromNeedsPassword() {
        let outcome = PDFPasswordService.removalOutcome(for: unprotectedPDF())
        XCTAssertNotEqual(outcome, .needsPassword)
    }

    // MARK: - unlock
    //
    // `unlock` used to decide whether a password check was even necessary by
    // reading `PDFDocument.isLocked`, which the code's own comments say
    // misreports `false` for some encrypted files — silently skipping
    // password validation. It now asks `needsPassword` (CGPDFDocument-based)
    // instead. These tests pin the resulting contract.

    func testUnlock_succeedsWithCorrectPassword() throws {
        let url = userPasswordPDF(password: "correct-pw")
        let document = try PDFPasswordService.unlock(url, password: "correct-pw")
        XCTAssertFalse(document.isLocked)
    }

    func testUnlock_throwsWrongPasswordForIncorrectPassword() {
        let url = userPasswordPDF(password: "correct-pw")
        XCTAssertThrowsError(try PDFPasswordService.unlock(url, password: "incorrect-pw")) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .wrongPassword)
        }
    }

    func testUnlock_isNoOpForUnprotectedPDF() throws {
        let url = unprotectedPDF()
        // No real password to check, so any string — including one that is
        // wrong for nothing — is accepted without validation.
        let document = try PDFPasswordService.unlock(url, password: "anything")
        XCTAssertFalse(document.isLocked)
    }

    func testUnlock_isNoOpForOwnerOnlyRestrictedPDF() throws {
        let url = ownerOnlyPDF()
        let document = try PDFPasswordService.unlock(url, password: "anything")
        XCTAssertFalse(document.isLocked)
    }

    func testUnlock_throwsCannotReadForMissingFile() {
        let missing = workDir.appendingPathComponent("does-not-exist.pdf")
        XCTAssertThrowsError(try PDFPasswordService.unlock(missing, password: "x")) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .cannotRead)
        }
    }

    func testUnlock_throwsCannotReadForNonPDFFile() throws {
        let notAPDF = workDir.appendingPathComponent("not-a.pdf")
        try Data("hello world".utf8).write(to: notAPDF)
        XCTAssertThrowsError(try PDFPasswordService.unlock(notAPDF, password: "x")) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .cannotRead)
        }
    }

    // MARK: - removePassword

    func testRemovePassword_stripsUserPasswordAndPreservesPageCount() throws {
        let source = userPasswordPDF(password: "correct-pw", pageCount: 3)
        let destination = PDFPasswordService.destinationURL(for: source)

        let output = try PDFPasswordService.removePassword(from: source, password: "correct-pw", to: destination)

        XCTAssertFalse(PDFPasswordService.isProtected(output))
        let stripped = PDFDocument(url: output)
        XCTAssertEqual(stripped?.pageCount, 3)
        XCTAssertFalse(stripped?.isLocked ?? true)
    }

    func testRemovePassword_stripsOwnerOnlyRestrictions() throws {
        let source = ownerOnlyPDF(pageCount: 2)
        let destination = PDFPasswordService.destinationURL(for: source)

        let output = try PDFPasswordService.removePassword(from: source, password: "", to: destination)

        XCTAssertFalse(PDFPasswordService.isProtected(output))
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 2)
    }

    func testRemovePassword_wrongPasswordThrowsAndLeavesDestinationUntouched() {
        let source = userPasswordPDF(password: "correct-pw")
        let destination = PDFPasswordService.destinationURL(for: source)

        XCTAssertThrowsError(
            try PDFPasswordService.removePassword(from: source, password: "wrong-pw", to: destination)
        ) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                        "A failed unlock must not leave a partial file behind")
    }

    func testRemovePassword_throwsNotProtectedForPlainPDF() {
        let source = unprotectedPDF()
        let destination = PDFPasswordService.destinationURL(for: source)

        XCTAssertThrowsError(
            try PDFPasswordService.removePassword(from: source, password: "", to: destination)
        ) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .notProtected)
        }
    }

    func testRemovePassword_throwsCannotReadForMissingFile() {
        let missing = workDir.appendingPathComponent("does-not-exist.pdf")
        let destination = PDFPasswordService.destinationURL(for: missing)
        XCTAssertThrowsError(
            try PDFPasswordService.removePassword(from: missing, password: "x", to: destination)
        ) { error in
            XCTAssertEqual(error as? PDFPasswordService.ServiceError, .cannotRead)
        }
    }

    /// Characterizes a real quirk found during review: once a document is
    /// already readable (owner-restricted only), `removePassword` never
    /// checks the password string at all — any value, right or wrong, is
    /// accepted. This pins the current behavior; if the app's threat model
    /// ever requires rejecting a wrong password here too, this test should
    /// change alongside the fix.
    func testRemovePassword_ownerOnlyFileAcceptsAnyPasswordString() throws {
        let source = ownerOnlyPDF()
        let destination = PDFPasswordService.destinationURL(for: source)
        let output = try PDFPasswordService.removePassword(from: source, password: "definitely-not-the-owner-password", to: destination)
        XCTAssertFalse(PDFPasswordService.isProtected(output))
    }

    // MARK: - destinationURL

    func testDestinationURL_isUniqueAndWritable() {
        let source = workDir.appendingPathComponent("original-name.pdf")
        let first = PDFPasswordService.destinationURL(for: source)
        let second = PDFPasswordService.destinationURL(for: source)

        XCTAssertEqual(first.lastPathComponent, "original-name.pdf")
        XCTAssertNotEqual(first, second, "each call must get its own folder so concurrent imports can't collide")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
    }
}
