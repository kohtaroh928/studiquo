import Foundation
import XCTest
@testable import studiquo

final class AccountFileEraserTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUp() {
        super.setUp()
        root = manager.temporaryDirectory.appendingPathComponent("AccountFileEraserTests-\(UUID().uuidString)", isDirectory: true)
        try! manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? manager.removeItem(at: root)
        super.tearDown()
    }

    func testEraseOwnedFilesRemovesSharedInboxAndAppManagedFoldersWhileKeepingStoreFiles() throws {
        let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
        let removablePaths = [
            "Documents/note.pdf",
            "Documents/Subfolder/photo.png",
            "Library/Caches/thumb.cache",
            "tmp/scratch.tmp",
            "Library/Application Support/studiquo/AutoBackups/backup-1.zip",
            "Library/Application Support/SharedInbox/shared-doc.pdf",
            "Library/Application Support/studiquo/ExternalFileBookmarks.json",
        ]
        let preservedPaths = [
            "Library/Application Support/default.store",
            "Library/Application Support/default.store-wal",
            "Library/Preferences/com.yabuko.studiquo.plist",
        ]

        for relative in removablePaths + preservedPaths {
            let url = sandbox.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("content".utf8).write(to: url)
        }

        try AccountFileEraser.eraseOwnedFiles(in: sandbox, manager: manager)

        for relative in removablePaths {
            XCTAssertFalse(
                manager.fileExists(atPath: sandbox.appendingPathComponent(relative).path),
                "Expected \(relative) to be erased"
            )
        }
        // Top-level Documents, Library/Caches, and tmp directories themselves remain in place, emptied.
        for containerDir in ["Documents", "Library/Caches", "tmp"] {
            XCTAssertTrue(manager.fileExists(atPath: sandbox.appendingPathComponent(containerDir).path))
        }
        for relative in preservedPaths {
            XCTAssertTrue(
                manager.fileExists(atPath: sandbox.appendingPathComponent(relative).path),
                "Expected \(relative) to be preserved"
            )
        }
    }

    func testEraseOwnedFilesSucceedsWhenOptionalDirectoriesDoNotExist() throws {
        let emptySandbox = root.appendingPathComponent("empty-sandbox", isDirectory: true)
        try manager.createDirectory(at: emptySandbox, withIntermediateDirectories: true)

        XCTAssertNoThrow(try AccountFileEraser.eraseOwnedFiles(in: emptySandbox, manager: manager))
    }

    func testEraseOwnedFilesRefusesSymlinkedAutoBackupsOrSharedInboxToProtectExternalFiles() throws {
        let sandbox = root.appendingPathComponent("sandbox-symlink", isDirectory: true)
        let external = root.appendingPathComponent("external-folder", isDirectory: true)
        try manager.createDirectory(at: sandbox.appendingPathComponent("Library/Application Support/studiquo"), withIntermediateDirectories: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: true)

        let preciousFile = external.appendingPathComponent("precious.pdf")
        try Data("do-not-delete".utf8).write(to: preciousFile)

        let symlinkTarget = sandbox.appendingPathComponent("Library/Application Support/studiquo/AutoBackups")
        try manager.createSymbolicLink(at: symlinkTarget, withDestinationURL: external)

        XCTAssertThrowsError(try AccountFileEraser.eraseOwnedFiles(in: sandbox, manager: manager)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertTrue(manager.fileExists(atPath: preciousFile.path), "External file behind symlink must never be deleted")
    }
}
