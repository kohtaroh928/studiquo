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
            fetch: { request in seen = request; return self.response(200, body: #"{"libraryID":"\#(self.alice)"}"#) }
        )
        XCTAssertEqual(recorded, alice)
        XCTAssertEqual(seen?.url?.absoluteString, "https://api.studiquo.app/api/account/library-id")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(store.load().lastActiveAccountID, alice)
    }

    func testRefreshChangesNothingWhenTheAnswerCannotBeTrusted() async {
        let endpoint = URL(string: "https://api.studiquo.app")
        func attempt(_ fetch: @escaping LibraryIdentityService.Fetch, token: String? = "t") async -> String? {
            await LibraryIdentityService.refresh(token: token, endpoint: endpoint, store: store, fetch: fetch)
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
}
