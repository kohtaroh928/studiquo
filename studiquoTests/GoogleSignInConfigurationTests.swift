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

    @MainActor
    func testLogoutPreservesPasskeyKnownFlagWhileAccountDeletionClearsOnlyCurrentEnvironmentFlag() {
        let currentKey = LaunchStoreEnvironment.namespaced("authenticationPasskeyKnownOnDevice")
        let otherKey = currentKey.hasSuffix(".staging") ? "authenticationPasskeyKnownOnDevice" : "authenticationPasskeyKnownOnDevice.staging"
        let suite = "passkey-flag-lifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: currentKey)
        defaults.set(true, forKey: otherKey)
        let store = AuthenticationStore(service: "test.\(UUID().uuidString)", defaults: defaults)
        XCTAssertTrue(store.knowsPasskeyOnThisDevice)

        store.logout()
        XCTAssertTrue(store.knowsPasskeyOnThisDevice, "logout must keep the device passkey hint so the login screen offers passkey sign-in")
        XCTAssertTrue(defaults.bool(forKey: otherKey))

        store.finishAccountDeletion()
        XCTAssertFalse(store.knowsPasskeyOnThisDevice, "account deletion clears the current environment passkey hint")
        XCTAssertTrue(defaults.bool(forKey: otherKey), "account deletion in one environment must not wipe the other environment's passkey hint")
    }

    func testUnexpandedOrNonStringServerClientIDIsRejected() {
        XCTAssertFalse(GoogleSignInService.isConfigured([
            "GIDClientID": "123.apps.googleusercontent.com",
            "GIDServerClientID": "$(STUDIQUO_GOOGLE_WEB_CLIENT_ID)",
        ]))
        XCTAssertFalse(GoogleSignInService.isConfigured([
            "GIDClientID": "123.apps.googleusercontent.com",
            "GIDServerClientID": 999,
        ]))
    }

    @MainActor
    func testCheckPasskeyRequirementUpdatesOnlyCurrentEnvironmentKnownFlag() async {
        let currentKey = LaunchStoreEnvironment.namespaced("authenticationPasskeyKnownOnDevice")
        let otherKey = currentKey.hasSuffix(".staging") ? "authenticationPasskeyKnownOnDevice" : "authenticationPasskeyKnownOnDevice.staging"
        let onboardingKey = LaunchStoreEnvironment.namespaced("authenticationOnboardingComplete")
        let suite = "passkey-check-env-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let serviceName = "test.auth.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName] as CFDictionary)
        }

        defaults.set(true, forKey: onboardingKey)
        defaults.set(true, forKey: otherKey)
        KeychainCredentialFixtures.seedSignedInDevice(service: serviceName, email: "user@example.com")
        var remoteRegistered: Bool? = true
        let store = AuthenticationStore(
            service: serviceName,
            defaults: defaults,
            passkeyRegistered: { remoteRegistered }
        )

        await store.checkPasskeyRequirement()
        XCTAssertTrue(store.knowsPasskeyOnThisDevice, "remote true sets the current environment flag")
        XCTAssertFalse(store.needsPasskeyEnrollment)
        XCTAssertTrue(defaults.bool(forKey: otherKey))

        // Offline (nil) preserves the current flag without clearing it.
        remoteRegistered = nil
        await store.checkPasskeyRequirement()
        XCTAssertTrue(store.knowsPasskeyOnThisDevice)

        // Remote false (e.g. after a password reset removed passkeys) clears only the current environment's flag.
        remoteRegistered = false
        await store.checkPasskeyRequirement()
        XCTAssertFalse(store.knowsPasskeyOnThisDevice)
        XCTAssertTrue(store.needsPasskeyEnrollment)
        XCTAssertTrue(defaults.bool(forKey: otherKey), "other environment's passkey flag must remain untouched")
    }
}
