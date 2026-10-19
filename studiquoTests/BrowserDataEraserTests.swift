import WebKit
import XCTest
@testable import studiquo

@MainActor
final class BrowserDataEraserTests: XCTestCase {
    /// A real WebKit data store (kept in memory only), with a real cookie in it.
    func testEraseAllRemovesCookiesAndSiteData() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "lms.example", .path: "/", .name: "session", .value: "abc", .secure: "TRUE",
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let before = await store.httpCookieStore.allCookies()
        XCTAssertEqual(before.count, 1, "the test needs a cookie to erase")

        await BrowserDataEraser.eraseAll(store: store, center: NotificationCenter())

        let after = await store.httpCookieStore.allCookies()
        XCTAssertTrue(after.isEmpty)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        XCTAssertTrue(records.isEmpty)
    }

    func testEraseAllTellsOpenBrowsersToDropTheirPage() async {
        let center = NotificationCenter()
        var told = 0
        let observer = center.addObserver(forName: .studiquoBrowserDataErased, object: nil, queue: .main) { _ in told += 1 }
        defer { center.removeObserver(observer) }

        await BrowserDataEraser.eraseAll(store: .nonPersistent(), center: center)

        XCTAssertEqual(told, 1)
    }
}

@MainActor
final class BrowserDataErasedOnSignOutTests: XCTestCase {
    private func makeStore(erase: @escaping @MainActor () async -> Void) -> AuthenticationStore {
        AuthenticationStore(
            service: "BrowserDataErasedOnSignOutTests-\(UUID().uuidString)",
            defaults: UserDefaults(suiteName: "BrowserDataErasedOnSignOutTests-\(UUID().uuidString)")!,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            deleteAccountOnServer: {},
            eraseBrowserData: erase,
            passkeyRegistered: { nil }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testSigningOutErasesTheBrowsersData() async {
        var erased = 0
        let store = makeStore { erased += 1 }

        store.logout()
        await waitUntil { erased > 0 }

        XCTAssertEqual(erased, 1)
    }

    func testFinishingAnAccountDeletionErasesTheBrowsersData() async {
        var erased = 0
        let store = makeStore { erased += 1 }

        store.finishAccountDeletion()
        await waitUntil { erased > 0 }

        XCTAssertEqual(erased, 1)
    }
}

@MainActor
final class WebBrowserModelEraseTests: XCTestCase {
    func testAnEraseGivesTheBrowserANewWebViewWithNoPage() async {
        let model = WebBrowserModel()
        let old = model.webView
        model.address = "https://lms.example/home"
        let generation = model.generation

        await BrowserDataEraser.eraseAll(store: .nonPersistent())

        XCTAssertFalse(model.webView === old, "the old page, its history and its caches go with the old web view")
        XCTAssertNil(old.navigationDelegate)
        XCTAssertEqual(model.address, "")
        XCTAssertFalse(model.canGoBack)
        XCTAssertEqual(model.generation, generation + 1)
    }

    func testAnEraseDoesNotCreateAWebViewForABrowserThatWasNeverUsed() async {
        let model = WebBrowserModel()
        let generation = model.generation

        await BrowserDataEraser.eraseAll(store: .nonPersistent())

        XCTAssertEqual(model.generation, generation, "nothing to discard")
    }
}
