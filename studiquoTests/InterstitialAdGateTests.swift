import XCTest
@testable import studiquo

@MainActor
final class InterstitialAdGateTests: XCTestCase {
    private let defaultsKey = "flashcardPassesSinceAd"
    private let gate = InterstitialAdGate.shared

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        gate.provider = nil
        gate.dismiss()
    }

    override func tearDown() {
        gate.provider = nil
        gate.dismiss()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testFirstCompletedPassDoesNotInterruptStudy() {
        XCTAssertFalse(gate.registerCompletedPass())
        XCTAssertFalse(gate.isShowingAd)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: defaultsKey), 1)
    }

    func testSecondCompletedPassShowsPlaceholderAndResetsCadence() {
        XCTAssertFalse(gate.registerCompletedPass())
        XCTAssertTrue(gate.registerCompletedPass())
        XCTAssertTrue(gate.isShowingAd)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: defaultsKey), 0)

        gate.dismiss()
        XCTAssertFalse(gate.registerCompletedPass(), "The pass after an ad must start a new cadence")
    }

    func testReadyProviderIsPresentedAndItsCallbackDismissesTheCover() {
        let provider = AdProviderSpy(isReady: true)
        gate.provider = provider
        UserDefaults.standard.set(InterstitialAdGate.passesPerAd - 1, forKey: defaultsKey)

        XCTAssertTrue(gate.registerCompletedPass())
        XCTAssertEqual(provider.presentationCount, 1)
        XCTAssertTrue(gate.isShowingAd)

        provider.completePresentation()
        XCTAssertFalse(gate.isShowingAd)
    }

    func testUnavailableProviderFallsBackWithoutCallingProvider() {
        let provider = AdProviderSpy(isReady: false)
        gate.provider = provider
        UserDefaults.standard.set(InterstitialAdGate.passesPerAd - 1, forKey: defaultsKey)

        XCTAssertTrue(gate.registerCompletedPass())

        XCTAssertEqual(provider.presentationCount, 0)
        XCTAssertTrue(gate.isShowingAd)
    }
}

@MainActor
private final class AdProviderSpy: AdProvider {
    let isReady: Bool
    private(set) var presentationCount = 0
    private var onDismiss: (() -> Void)?

    init(isReady: Bool) {
        self.isReady = isReady
    }

    func presentInterstitial(onDismiss: @escaping () -> Void) {
        presentationCount += 1
        self.onDismiss = onDismiss
    }

    func completePresentation() {
        onDismiss?()
        onDismiss = nil
    }
}
