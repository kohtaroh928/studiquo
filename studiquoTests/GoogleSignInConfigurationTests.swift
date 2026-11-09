import XCTest
@testable import studiquo

final class GoogleSignInConfigurationTests: XCTestCase {
    func testABuildWithBothClientIDsIsConfigured() {
        XCTAssertTrue(GoogleSignInService.isConfigured(["GIDClientID": "123.apps.googleusercontent.com", "GIDServerClientID": "456.apps.googleusercontent.com"]))
    }

    /// A Staging build without `Staging.local.xcconfig` carries empty strings, or the unexpanded `$(…)`.
    func testEmptyMissingOrUnexpandedClientIDsAreNotConfigured() {
        XCTAssertFalse(GoogleSignInService.isConfigured(nil))
        XCTAssertFalse(GoogleSignInService.isConfigured([:]))
        XCTAssertFalse(GoogleSignInService.isConfigured(["GIDClientID": "", "GIDServerClientID": "456"]))
        XCTAssertFalse(GoogleSignInService.isConfigured(["GIDClientID": "123", "GIDServerClientID": "   "]))
        XCTAssertFalse(GoogleSignInService.isConfigured(["GIDClientID": "$(STUDIQUO_GOOGLE_IOS_CLIENT_ID)", "GIDServerClientID": "456"]))
        XCTAssertFalse(GoogleSignInService.isConfigured(["GIDClientID": 123, "GIDServerClientID": "456"]))
    }

    func testTheErrorSaysWhatIsMissing() {
        XCTAssertEqual(GoogleSignInServiceError.notConfigured.errorDescription, "このビルドではGoogleサインインが設定されていません。")
    }

    @MainActor
    func testThePasskeyKnownFlagIsKeptPerEnvironment() {
        // Staging and production builds share one UserDefaults domain on a device: the flag name carries the environment.
        let name = LaunchStoreEnvironment.namespaced("authenticationPasskeyKnownOnDevice")
        XCTAssertTrue(name == "authenticationPasskeyKnownOnDevice" || name == "authenticationPasskeyKnownOnDevice.staging")
        let suite = "passkey-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: name)
        let store = AuthenticationStore(service: "test.\(UUID().uuidString)", defaults: defaults)
        XCTAssertTrue(store.knowsPasskeyOnThisDevice)
        // The other environment's flag is not read.
        let other = name.hasSuffix(".staging") ? "authenticationPasskeyKnownOnDevice" : "authenticationPasskeyKnownOnDevice.staging"
        let otherSuite = "passkey-flag-other-\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        otherDefaults.set(true, forKey: other)
        XCTAssertFalse(AuthenticationStore(service: "test.\(UUID().uuidString)", defaults: otherDefaults).knowsPasskeyOnThisDevice)
    }
}
