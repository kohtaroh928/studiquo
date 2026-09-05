import XCTest
@testable import studiquo

final class PDFStableCopyServiceTests: XCTestCase {
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

    func testCopy_succeedsAndPreservesFilenameAndContent() throws {
        let source = workDir.appendingPathComponent("report.pdf")
        try Data("fake pdf bytes".utf8).write(to: source)

        let result = PDFStableCopyService.copy(source)

        let copied = try XCTUnwrap(result)
        XCTAssertEqual(copied.lastPathComponent, "report.pdf")
        XCTAssertNotEqual(copied, source, "must live in its own folder, not overwrite or alias the source")
        XCTAssertEqual(try Data(contentsOf: copied), Data("fake pdf bytes".utf8))
    }

    func testCopy_eachCallGetsItsOwnFolder() throws {
        let source = workDir.appendingPathComponent("report.pdf")
        try Data("bytes".utf8).write(to: source)

        let first = try XCTUnwrap(PDFStableCopyService.copy(source))
        let second = try XCTUnwrap(PDFStableCopyService.copy(source))

        XCTAssertNotEqual(first, second, "concurrent or repeated imports of the same file must not collide")
    }

    /// The regression this service exists for: a caller stashes whatever
    /// `copy` returns and uses it after the source's own access may have
    /// expired (e.g. a security-scoped `defer` already ran). Returning the
    /// original `url` on failure would silently hand back something that
    /// looks fine now but fails later with a misleading error. `nil` forces
    /// the caller to fail immediately, while the real cause is still known.
    func testCopy_returnsNilRatherThanTheOriginalURLWhenSourceIsUnreadable() {
        let missingSource = workDir.appendingPathComponent("does-not-exist.pdf")

        let result = PDFStableCopyService.copy(missingSource)

        XCTAssertNil(result)
    }

    func testCopy_leavesNoPartialFileWhenSourceIsUnreadable() {
        let missingSource = workDir.appendingPathComponent("does-not-exist.pdf")
        let before = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil).count

        _ = PDFStableCopyService.copy(missingSource)

        let after = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil).count
        XCTAssertEqual(before, after, "a failed copy must not leave an orphaned destination folder behind")
    }
}
