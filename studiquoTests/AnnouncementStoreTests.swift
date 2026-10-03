import XCTest
@testable import studiquo

@MainActor
final class AnnouncementStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AnnouncementStoreTests")!
        defaults.removePersistentDomain(forName: "AnnouncementStoreTests")
    }

    private func json(_ items: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["announcements": items])
    }

    private func item(_ id: String, kind: String = "update", link: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "kind": kind, "title": "T\(id)", "body": "B\(id)", "lang": "en",
            "publishedAt": 1_700_000_000_000,
        ]
        if let link { value["link"] = link }
        return value
    }

    private func store(returning data: Data, status: Int = 200, requests: @escaping (URLRequest) -> Void = { _ in }) -> AnnouncementStore {
        AnnouncementStore(
            defaults: defaults,
            fetch: { request in
                requests(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            endpoint: { URL(string: "https://example.test")! },
            languageCode: { "pt-BR" },
            appVersion: { "1.4" }
        )
    }

    func testRefreshSendsLanguageAndVersionAndDecodesItems() async {
        var seen: URLRequest?
        let store = store(returning: json([item("a")])) { seen = $0 }
        await store.refresh()
        let query = URLComponents(url: seen!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "lang" }?.value, "pt-BR")
        XCTAssertEqual(query.first { $0.name == "appVersion" }?.value, "1.4")
        XCTAssertEqual(seen?.url?.path, "/api/announcements")
        XCTAssertEqual(store.announcements.map(\.id), ["a"])
        XCTAssertEqual(store.announcements.first?.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testUnreadCountAndMarkRead() async {
        let store = store(returning: json([item("a"), item("b")]))
        await store.refresh()
        XCTAssertEqual(store.unreadCount, 2)
        store.markRead(store.announcements[0])
        XCTAssertEqual(store.unreadCount, 1)
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testReadStateSurvivesRelaunchAndIsPrunedWhenServerDropsItems() async {
        let first = store(returning: json([item("a"), item("b")]))
        await first.refresh()
        first.markAllRead()

        let second = store(returning: json([item("b"), item("c")]))
        XCTAssertEqual(second.announcements.map(\.id), ["a", "b"], "前回の一覧がキャッシュとして先に表示されます。")
        await second.refresh()
        XCTAssertEqual(second.unreadCount, 1, "既読のbは維持され、新しいcだけが未読になります。")
        XCTAssertFalse(second.readIDs.contains("a"), "サーバーから消えたお知らせの既読記録は破棄されます。")
    }

    func testFailureKeepsTheCachedList() async {
        let ok = store(returning: json([item("a")]))
        await ok.refresh()
        let failing = store(returning: Data(), status: 500)
        await failing.refresh()
        XCTAssertTrue(failing.loadFailed)
        XCTAssertEqual(failing.announcements.map(\.id), ["a"])
    }

    func testUnknownKindFallsBackToNewsAndOnlyHttpsLinksOpen() throws {
        let list = try Announcement.decodeList(from: json([
            item("a", kind: "brand-new-kind", link: "https://apps.apple.com/app/x"),
            item("b", link: "http://insecure.example"),
            item("c", link: "javascript:alert(1)"),
        ]))
        XCTAssertEqual(list[0].kindValue, .news)
        XCTAssertNotNil(list[0].linkURL)
        XCTAssertNil(list[1].linkURL)
        XCTAssertNil(list[2].linkURL)
    }
}
