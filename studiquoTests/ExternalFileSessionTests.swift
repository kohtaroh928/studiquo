import XCTest
@testable import studiquo

@MainActor
final class ExternalFileSessionTests: XCTestCase {
    private var directory: URL!
    private var staleBookmarks: Set<Data> = []

    private struct Unresolvable: Error {}

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ExternalFileBookmarkStore {
        ExternalFileBookmarkStore(
            fileURL: directory.appendingPathComponent("bookmarks.json"),
            bookmarking: ExternalFileBookmarking(
                makeBookmark: { Data($0.path.utf8) },
                resolve: { [unowned self] data in
                    if staleBookmarks.contains(data) { throw Unresolvable() }
                    return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
                }
            )
        )
    }

    private func makeFile(_ name: String = "note.pdf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("sample".utf8).write(to: url)
        return url
    }

    func testPickingReadableFileBecomesReady() throws {
        let session = ExternalFileSession(store: makeStore())
        let url = try makeFile()
        session.open(pickedURL: url)
        XCTAssertEqual(session.state, .ready, "読めるファイルを選んだら、表示できる状態になる必要があります。")
        XCTAssertEqual(session.fileURL, url)
        XCTAssertEqual(session.fileName, "note.pdf")
    }

    func testPickedFileIsRemembered() throws {
        let store = makeStore()
        let session = ExternalFileSession(store: store)
        session.open(pickedURL: try makeFile())
        XCTAssertEqual(session.recents.map(\.displayName), ["note.pdf"], "開いたファイルは「最近開いたファイル」に載る必要があります。")
    }

    func testDeletedFileIsMissing() throws {
        let session = ExternalFileSession(store: makeStore())
        let url = try makeFile()
        try FileManager.default.removeItem(at: url)
        session.open(pickedURL: url)
        XCTAssertEqual(session.state, .missing, "消えたファイルは「見つかりません」になる必要があります。")
        XCTAssertNil(session.fileURL)
    }

    func testBackToBrowserResetsEverything() throws {
        let session = ExternalFileSession(store: makeStore())
        session.open(pickedURL: try makeFile())
        session.backToBrowser()
        XCTAssertEqual(session.state, .browsing)
        XCTAssertNil(session.fileURL, "選び直すときは、前のファイルを開いたままにしてはいけません。")
        XCTAssertEqual(session.fileName, "")
    }

    func testCloseLeavesNothingToShowAgain() throws {
        let session = ExternalFileSession(store: makeStore())
        session.open(pickedURL: try makeFile())
        session.close()
        XCTAssertEqual(session.state, .browsing, "閉じたセッションが、読めないファイルを表示する状態のまま残ってはいけません。")
        XCTAssertNil(session.fileURL)
    }

    func testReopeningFromRecentsWorks() throws {
        let store = makeStore()
        let first = ExternalFileSession(store: store)
        first.open(pickedURL: try makeFile())
        let entry = try XCTUnwrap(first.recents.first)
        first.close()

        let session = ExternalFileSession(store: store)
        session.open(entry: entry)
        XCTAssertEqual(session.state, .ready, "履歴から、同じファイルを開き直せる必要があります。")
    }

    func testUnresolvableEntryIsMissingAndForgotten() throws {
        let store = makeStore()
        let first = ExternalFileSession(store: store)
        first.open(pickedURL: try makeFile())
        let entry = try XCTUnwrap(first.recents.first)
        staleBookmarks = [entry.bookmarkData]

        let session = ExternalFileSession(store: store)
        session.open(entry: entry)
        XCTAssertEqual(session.state, .missing, "解決できない履歴は「見つかりません」になる必要があります。")
        XCTAssertTrue(session.recents.isEmpty, "二度と開けない履歴を、一覧に残してはいけません。")
    }
}
