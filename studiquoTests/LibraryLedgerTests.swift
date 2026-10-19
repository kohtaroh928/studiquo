import XCTest
@testable import studiquo

final class LibraryLedgerTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryLedgerStore!
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-test-\(UUID().uuidString)", isDirectory: true)
        store = LibraryLedgerStore(fileURL: directory.appendingPathComponent("studiquo/LibraryLedger.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlyAServerSizedLowercaseHexIDIsRecorded() {
        var ledger = LibraryLedger()
        for bad in ["", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63), "apple:alice"] {
            XCTAssertFalse(ledger.recordSignIn(accountID: bad, at: Date()), bad)
        }
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertNil(ledger.lastActiveAccountID)
    }

    func testSigningInAgainUpdatesTheSameEntryAndTracksTheLatestAccount() {
        var ledger = LibraryLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        ledger.recordSignIn(accountID: alice, at: first)
        ledger.recordSignIn(accountID: bob, at: first)
        ledger.recordSignIn(accountID: alice, at: later)
        XCTAssertEqual(ledger.entries.map(\.accountID), [alice, bob])
        XCTAssertEqual(ledger.entries[0].firstSeenAt, first)
        XCTAssertEqual(ledger.entries[0].lastSeenAt, later)
        XCTAssertEqual(ledger.lastActiveAccountID, alice)
    }

    func testTheLedgerSurvivesBeingSavedAndLoaded() {
        var ledger = LibraryLedger()
        ledger.recordSignIn(accountID: alice, at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(store.save(ledger))
        XCTAssertEqual(store.load(), ledger)
    }

    func testAMissingFileIsAnEmptyLedger() {
        XCTAssertEqual(store.load(), LibraryLedger())
    }

    func testAnUnreadableFileIsSetAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), LibraryLedger())
        let files = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertTrue(files.contains { $0.hasPrefix("LibraryLedger.unreadable-") }, "the old file is kept for inspection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    private func response(_ status: Int, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.studiquo.app")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testRefreshAsksTheServerWithTheTokenAndRecordsTheAnswer() async {
        var seen: URLRequest?
        let recorded = await LibraryIdentityService.refresh(
            token: "token-123", endpoint: URL(string: "https://api.studiquo.app"), store: store, now: Date(timeIntervalSince1970: 5),
            currentToken: { "token-123" },
            fetch: { request in seen = request; return self.response(200, body: #"{"libraryID":"\#(self.alice)"}"#) }
        )
        XCTAssertEqual(recorded, alice)
        XCTAssertEqual(seen?.url?.absoluteString, "https://api.studiquo.app/api/account/library-id")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(store.load()?.lastActiveAccountID, alice)
    }

    func testRefreshChangesNothingWhenTheAnswerCannotBeTrusted() async {
        let endpoint = URL(string: "https://api.studiquo.app")
        func attempt(_ fetch: @escaping LibraryIdentityService.Fetch, token: String? = "t") async -> String? {
            await LibraryIdentityService.refresh(token: token, endpoint: endpoint, store: store, currentToken: { token }, fetch: fetch)
        }
        let notSignedIn = await attempt({ _ in self.response(200, body: "{}") }, token: nil)
        XCTAssertNil(notSignedIn)
        let unauthorized = await attempt({ _ in self.response(401, body: #"{"error":"x"}"#) })
        XCTAssertNil(unauthorized)
        let oldServer = await attempt({ _ in self.response(404, body: "") })
        XCTAssertNil(oldServer)
        let garbage = await attempt({ _ in self.response(200, body: #"{"libraryID":"apple:alice"}"#) })
        XCTAssertNil(garbage)
        let offline = await attempt({ _ in throw URLError(.notConnectedToInternet) })
        XCTAssertNil(offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "no ledger was even written")
    }

    func testAnIdFromAnAnswerThatArrivesAfterASignOutIsNotRecorded() async {
        var tokenNow: String? = "token-A"
        let recorded = await LibraryIdentityService.refresh(
            token: "token-A", endpoint: URL(string: "https://api.studiquo.app"), store: store,
            currentToken: { tokenNow },
            fetch: { _ in
                tokenNow = "token-B"   // signed out and in as someone else while waiting
                return self.response(200, body: #"{"libraryID":"\#(self.alice)"}"#)
            }
        )
        XCTAssertNil(recorded)
        XCTAssertEqual(store.load(), LibraryLedger(), "nothing was written")
    }

    func testEditedLedgerEntriesAreDroppedOnLoad() throws {
        var good = LibraryLedger()
        good.recordSignIn(accountID: alice, at: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(store.save(good))
        // Someone edits the file: a path-like id, and a "last active" account that is not listed.
        var text = try String(contentsOf: store.fileURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"entries\" : [", with: "\"entries\" : [ {\"accountID\":\"../../Documents/x\",\"firstSeenAt\":\"1970-01-01T00:00:01Z\",\"lastSeenAt\":\"1970-01-01T00:00:01Z\"},")
        text = text.replacingOccurrences(of: "\"lastActiveAccountID\" : \"\(alice)\"", with: "\"lastActiveAccountID\" : \"../x\"")
        try text.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.entries.map(\.accountID), [alice])
        XCTAssertNil(loaded.lastActiveAccountID)
    }

    func testALedgerThatCannotBeReadIsNeverReplacedByAnEmptyOne() throws {
        var ledger = LibraryLedger()
        ledger.recordSignIn(accountID: alice, at: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(store.save(ledger))
        // A directory where the file should be: it exists, but cannot be read as a file.
        let original = try Data(contentsOf: store.fileURL)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertNil(store.load(), "unreadable is not the same as missing")
        XCTAssertNil(store.update { $0.recordSignIn(accountID: self.bob, at: Date()) }, "and nothing is written over it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(original.isEmpty)
    }

    func testTwoDamagedFilesInTheSameSecondAreBothKept() throws {
        for _ in 0..<2 {
            try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: store.fileURL)
            XCTAssertEqual(store.load(), LibraryLedger())
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(files.filter { $0.hasPrefix("LibraryLedger.unreadable-") }.count, 2)
    }

    func testTwoUpdatesAtOnceDoNotLoseAnEntry() async {
        await withTaskGroup(of: Void.self) { group in
            for id in [alice, bob] {
                group.addTask { _ = self.store.update { $0.recordSignIn(accountID: id, at: Date()) } }
            }
        }
        XCTAssertEqual(Set(store.load()?.entries.map(\.accountID) ?? []), [alice, bob])
    }
}
