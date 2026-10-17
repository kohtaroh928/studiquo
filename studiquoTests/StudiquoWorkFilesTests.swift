import XCTest
@testable import studiquo

final class StudiquoWorkFilesTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("work-files-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testFoldersAndFilesLiveInsideTheWorkFolderOnly() {
        let folder = StudiquoWorkFiles.makeFolder(base: base)
        let file = StudiquoWorkFiles.file(named: "ノート.pdf", base: base)
        let work = StudiquoWorkFiles.directory(base: base)
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, work.standardizedFileURL)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, work.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the folder exists, ready to be written into")
        XCTAssertNotEqual(folder, StudiquoWorkFiles.makeFolder(base: base), "each piece of work gets its own folder")
    }

    func testSweepEmptiesTheWorkFolderAndTouchesNothingElse() throws {
        let folder = StudiquoWorkFiles.makeFolder(base: base)
        try Data("secret".utf8).write(to: folder.appendingPathComponent("a.pdf"))
        try Data("secret".utf8).write(to: StudiquoWorkFiles.file(named: "b.json", base: base))
        let other = base.appendingPathComponent("someone-elses-file.txt")
        try Data("keep".utf8).write(to: other)

        StudiquoWorkFiles.sweep(base: base)

        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: StudiquoWorkFiles.directory(base: base).path))?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "files outside the work folder are not ours to delete")
    }

    func testSweepOnAFolderThatDoesNotExistYetIsHarmless() {
        StudiquoWorkFiles.sweep(base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(StudiquoWorkFiles.folderName).path))
    }
}
