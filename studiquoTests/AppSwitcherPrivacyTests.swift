import UIKit
import XCTest
@testable import studiquo

@MainActor
final class AppSwitcherPrivacyTests: XCTestCase {
    func testRegistryCountsSensitiveViewsPerScene() {
        let registry = SensitiveScreenRegistry()
        XCTAssertFalse(registry.hasSensitiveContent(scene: "a"))

        registry.add(scene: "a")
        registry.add(scene: "a")
        registry.add(scene: "b")
        XCTAssertTrue(registry.hasSensitiveContent(scene: "a"))

        registry.remove(scene: "a")
        XCTAssertTrue(registry.hasSensitiveContent(scene: "a"), "one of the two is still on screen")
        registry.remove(scene: "a")
        XCTAssertFalse(registry.hasSensitiveContent(scene: "a"))
        XCTAssertTrue(registry.hasSensitiveContent(scene: "b"), "another window is not affected")
    }

    func testRemovingMoreThanWasAddedNeverGoesNegative() {
        let registry = SensitiveScreenRegistry()
        registry.remove(scene: "a")
        registry.add(scene: "a")
        XCTAssertTrue(registry.hasSensitiveContent(scene: "a"))
        registry.remove(scene: "a")
        registry.remove(scene: "a")
        XCTAssertFalse(registry.hasSensitiveContent(scene: "a"))
    }

    func testCoverIsInstalledOnlyWhenTheSceneHasASensitiveScreen() {
        let registry = SensitiveScreenRegistry()
        let controller = AppSwitcherPrivacyCover(registry: registry)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        controller.cover(windows: [window], sceneID: "plain")
        XCTAssertFalse(PrivacyCover.isCovered(window), "an ordinary screen is left as it is")

        registry.add(scene: "secret")
        controller.cover(windows: [window], sceneID: "other")
        XCTAssertFalse(PrivacyCover.isCovered(window), "another scene's sensitive screen does not cover this one")

        controller.cover(windows: [window], sceneID: "secret")
        XCTAssertTrue(PrivacyCover.isCovered(window))
    }

    func testCoverIsIdempotentOpaqueFullSizeAndRemovable() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.addSubview(UIView())

        PrivacyCover.install(on: window)
        PrivacyCover.install(on: window)

        let covers = window.subviews.filter { $0.tag == PrivacyCover.tag }
        XCTAssertEqual(covers.count, 1)
        let cover = try XCTUnwrap(covers.first)
        XCTAssertEqual(cover.frame, window.bounds)
        XCTAssertEqual(window.subviews.last, cover, "the cover is in front of everything")
        XCTAssertEqual(cover.backgroundColor, .systemBackground)
        XCTAssertEqual(cover.alpha, 1)

        PrivacyCover.remove(from: window)
        XCTAssertFalse(PrivacyCover.isCovered(window))
        XCTAssertEqual(window.subviews.count, 1, "the window's own content is untouched")
    }

    func testCoveringEveryWindowOfAScene() {
        let registry = SensitiveScreenRegistry()
        registry.add(scene: "s")
        let controller = AppSwitcherPrivacyCover(registry: registry)
        let windows = [UIWindow(frame: .zero), UIWindow(frame: .zero)]

        controller.cover(windows: windows, sceneID: "s")

        XCTAssertTrue(windows.allSatisfy { PrivacyCover.isCovered($0) })
    }
}

final class SecretPasteboardTests: XCTestCase {
    private final class RecordingPasteboard: PasteboardWriting {
        var items: [[String: Any]] = []
        var options: [UIPasteboard.OptionsKey: Any] = [:]
        func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
            self.items = items
            self.options = options
        }
    }

    func testASecretIsCopiedForThisDeviceOnlyAndExpires() throws {
        let pasteboard = RecordingPasteboard()
        let now = Date(timeIntervalSince1970: 1_000_000)

        SecretPasteboard.copy("secret-token", to: pasteboard, now: now)

        XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, true, "not sent to other devices by Universal Clipboard")
        XCTAssertEqual(pasteboard.options[.expirationDate] as? Date, now.addingTimeInterval(60))
        XCTAssertEqual(pasteboard.items.count, 1)
        XCTAssertEqual(pasteboard.items.first?["public.utf8-plain-text"] as? String, "secret-token")
    }

    func testTheLifetimeIsAMinute() {
        XCTAssertEqual(SecretPasteboard.lifetime, 60)
    }

    func testAPairingCodeCanSyncAcrossDevicesAndExpiresWithTheCode() {
        let pasteboard = RecordingPasteboard()
        let expiresAt = Date(timeIntervalSince1970: 1_000_300)

        SecretPasteboard.copy("ABCD1234EFGH", localOnly: false, expiresAt: expiresAt, to: pasteboard)

        XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, false, "allows Universal Clipboard to Mac")
        XCTAssertEqual(pasteboard.options[.expirationDate] as? Date, expiresAt)
        XCTAssertEqual(pasteboard.items.first?["public.utf8-plain-text"] as? String, "ABCD1234EFGH")
    }

    func testCrossDeviceCopyWithoutExplicitExpirationFallsBackToDefaultLifetime() {
        let pasteboard = RecordingPasteboard()
        let now = Date(timeIntervalSince1970: 2_000_000)

        SecretPasteboard.copy("PAIR5678", localOnly: false, expiresAt: nil, to: pasteboard, now: now)

        XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, false)
        XCTAssertEqual(pasteboard.options[.expirationDate] as? Date, now.addingTimeInterval(SecretPasteboard.lifetime))
        XCTAssertEqual(pasteboard.items.first?["public.utf8-plain-text"] as? String, "PAIR5678")
    }

    func testARealPasteboardReadsTheSecretBackAsAString() {
        let pasteboard = UIPasteboard.withUniqueName()
        SecretPasteboard.copy("secret-token", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "secret-token")
        UIPasteboard.remove(withName: pasteboard.name)
    }
}
