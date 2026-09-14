import XCTest
@testable import studiquo

/// Regression coverage for a real gap: the app sends note content, answer
/// photos, and chat questions to Google's Gemini (and, for the optional
/// bring-your-own-key features, Anthropic) with no disclosure anywhere in
/// the app. `AIDataDisclosure` backs both the first-launch consent screen
/// (`AIDataDisclosureGate`) and the always-available explanation in
/// 設定 → プライバシー.
final class AIDataDisclosureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AIDataDisclosure.acknowledgedDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AIDataDisclosure.acknowledgedDefaultsKey)
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
}
