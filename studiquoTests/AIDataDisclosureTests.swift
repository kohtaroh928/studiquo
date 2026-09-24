import XCTest
@testable import studiquo

/// Regression coverage for a real gap: the app sends note content, answer
/// photos, and chat questions to Google's Gemini (and, for the optional
/// bring-your-own-key features, Anthropic) with no disclosure anywhere in
/// the app. `AIDataDisclosure` backs both the first-launch consent screen
/// (`AIDataDisclosureGate`) and the always-available explanation in
/// 設定 → プライバシー.
final class AIDataDisclosureTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        // An isolated suite, not `.standard` — `.standard` is shared with
        // any other copy of the app running on the same simulator, and a
        // manual run that really acknowledges the disclosure would leave
        // this `true` for whichever test happens to run next.
        suiteName = "com.yabuko.studiquo.tests.\(UUID().uuidString)"
        AIDataDisclosure.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        AIDataDisclosure.defaults.removePersistentDomain(forName: suiteName)
        AIDataDisclosure.defaults = .standard
        super.tearDown()
    }

    /// Covers both a brand-new install and an existing install updating to
    /// the version that first added this screen — neither has acknowledged
    /// anything yet, so both must see the disclosure.
    func testAnUntouchedInstallHasNotAcknowledgedTheDisclosure() {
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
    }

    func testAcknowledgingPersistsSoItIsNotShownAgain() {
        AIDataDisclosure.acknowledge()
        XCTAssertTrue(AIDataDisclosure.hasBeenAcknowledged)
    }

    /// Regression coverage for a real failure this session: this test used
    /// to read/write `hasBeenAcknowledged` straight through
    /// `UserDefaults.standard`, real shared app state. A manually-run copy
    /// of the app on the same simulator that actually acknowledges the
    /// disclosure — as happened this session — permanently sets that flag,
    /// and `testAnUntouchedInstallHasNotAcknowledgedTheDisclosure` above
    /// then fails with nothing wrong in the app itself. `AIDataDisclosure`
    /// now reads/writes a swappable `defaults`, and this proves a poisoned
    /// `.standard` — exactly what a manual app run leaves behind — can no
    /// longer reach a test pointed at its own isolated suite.
    func testHasBeenAcknowledgedIgnoresAStaleFlagLeftInSharedUserDefaultsByAnotherAppInstance() {
        UserDefaults.standard.set(true, forKey: AIDataDisclosure.acknowledgedDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AIDataDisclosure.acknowledgedDefaultsKey) }

        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
    }
}
