import XCTest
@testable import studiquo

final class ExternalFileBookmarkStoreTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL { directory.appendingPathComponent("bookmarks.json") }

    /// Bookmarks here are the file's path as bytes, so tests need no real files.
    private var staleURLs: Set<URL> = []
    private var unresolvable: Set<Data> = []
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var generation = 0

    private struct Unresolvable: Error {}

    private func bookmarking() -> ExternalFileBookmarking {
        ExternalFileBookmarking(
            // "<path>#<n>": the number changes on every call, so a re-created
            // bookmark can be told apart from the one it replaces.
            makeBookmark: { [unowned self] in
                generation += 1
                return Data("\($0.path)#\(generation)".utf8)
            },
            resolve: { [unowned self] data in
                if unresolvable.contains(data) { throw Unresolvable() }
                let path = String(decoding: data, as: UTF8.self).split(separator: "#").first.map(String.init) ?? ""
                let url = URL(fileURLWithPath: path)
                return (url, staleURLs.contains(url))
            }
        )
    }

    private func makeStore() -> ExternalFileBookmarkStore {
        ExternalFileBookmarkStore(fileURL: storeURL, bookmarking: bookmarking(), now: { [unowned self] in clock })
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddedEntrySurvivesRelaunch() throws {
        let url = URL(fileURLWithPath: "/files/a.pdf")
        let entry = try XCTUnwrap(makeStore().add(url: url))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.map(\.id), [entry.id], "保存したファイルは、アプリを再起動しても残っている必要があります。")
        XCTAssertEqual(reloaded.entries.first?.displayName, "a.pdf")
    }

    func testOpeningSameFileAgainMovesItToFrontWithoutDuplicating() {
        let store = makeStore()
        let a = URL(fileURLWithPath: "/files/a.pdf")
        store.add(url: a)
        clock = clock.addingTimeInterval(10)
        store.add(url: URL(fileURLWithPath: "/files/b.pdf"))
        clock = clock.addingTimeInterval(10)
        store.add(url: a)
        XCTAssertEqual(store.entries.map(\.displayName), ["a.pdf", "b.pdf"], "同じファイルを開き直したら、重複させず先頭へ移す必要があります。")
        XCTAssertEqual(store.entries.first?.lastOpened, clock)
    }

    func testEntriesAreCappedAtMaximum() {
        let store = makeStore()
        for index in 0..<(ExternalFileBookmarkStore.maximumEntries + 5) {
            store.add(url: URL(fileURLWithPath: "/files/\(index).pdf"))
        }
        XCTAssertEqual(store.entries.count, ExternalFileBookmarkStore.maximumEntries, "履歴は上限件数を超えて増やしてはいけません。")
        XCTAssertEqual(store.entries.first?.displayName, "\(ExternalFileBookmarkStore.maximumEntries + 4).pdf", "新しいものを残し、古いものから捨てる必要があります。")
    }

    func testResolveReturnsURL() throws {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/files/a.pdf")
        let entry = try XCTUnwrap(store.add(url: url))
        XCTAssertEqual(store.resolve(entry), .resolved(url), "保存したブックマークから、元のURLに戻せる必要があります。")
    }

    func testStaleBookmarkIsRefreshedAndKeptUsable() throws {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/files/a.pdf")
        let entry = try XCTUnwrap(store.add(url: url))
        staleURLs = [url]
        XCTAssertEqual(store.resolve(entry), .resolved(url), "古くなったブックマークでも、解決できたなら開ける必要があります。")
        XCTAssertEqual(store.entries.count, 1, "作り直しで履歴が増えてはいけません。")
        XCTAssertNotEqual(store.entries.first?.bookmarkData, entry.bookmarkData, "古くなったブックマークは、解決できた時点で作り直して保存する必要があります。")
        XCTAssertEqual(makeStore().entries.first?.bookmarkData, store.entries.first?.bookmarkData, "作り直したブックマークは、再起動後も残る必要があります。")
    }

    func testUnresolvableBookmarkFails() throws {
        let store = makeStore()
        let entry = try XCTUnwrap(store.add(url: URL(fileURLWithPath: "/files/a.pdf")))
        unresolvable = [entry.bookmarkData]
        XCTAssertEqual(store.resolve(entry), .failed, "解決できないブックマークは失敗として返す必要があります(見つかりません表示の元)。")
    }

    func testRemoveDeletesEntryPersistently() throws {
        let store = makeStore()
        let entry = try XCTUnwrap(store.add(url: URL(fileURLWithPath: "/files/a.pdf")))
        store.remove(id: entry.id)
        XCTAssertTrue(makeStore().entries.isEmpty, "削除した履歴は、再起動後も復活してはいけません。")
    }

    func testBookmarkCreationFailureAddsNothing() {
        let failing = ExternalFileBookmarking(makeBookmark: { _ in throw Unresolvable() }, resolve: { _ in throw Unresolvable() })
        let store = ExternalFileBookmarkStore(fileURL: storeURL, bookmarking: failing)
        XCTAssertNil(store.add(url: URL(fileURLWithPath: "/files/a.pdf")), "ブックマークを作れなかったときは、履歴に追加してはいけません。")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testStoreFileIsExcludedFromBackup() throws {
        makeStore().add(url: URL(fileURLWithPath: "/files/a.pdf"))
        let values = try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "ブックマークは端末固有なので、バックアップ対象から外す必要があります。")
    }
}
