import SwiftUI
import UIKit
import XCTest
@testable import studiquo

/// Regression for the Terms of Use feature: `TermsOfUseView` and
/// `PrivacyPolicyView` were made non-`private` in ContentView.swift
/// specifically so `SubscriptionPlansView` (a different file) could present
/// them next to the purchase buttons, per App Store Review Guideline 3.1.2.
/// Constructing them from this file — itself a different file from
/// ContentView.swift — fails to compile if either is ever re-marked
/// `private`/`fileprivate`, which only restricts access to its own file.
@MainActor
final class LegalDocumentViewsTests: XCTestCase {
    func testTermsOfUseViewRendersWithoutCrashing() async throws {
        try await assertRendersWithoutCrashing(TermsOfUseView())
    }

    func testPrivacyPolicyViewRendersWithoutCrashing() async throws {
        try await assertRendersWithoutCrashing(PrivacyPolicyView())
    }

    /// `SubscriptionPlansView` injects `TermsOfUseView`/`PrivacyPolicyView`
    /// as sheets beside its purchase buttons — hosting it (with its
    /// required `SubscriptionStore` environment object) catches a
    /// regression where that wiring, or the environment object
    /// requirement itself, breaks.
    func testSubscriptionPlansViewRendersWithSubscriptionStoreInjected() async throws {
        try await assertRendersWithoutCrashing(
            SubscriptionPlansView().environmentObject(SubscriptionStore())
        )
    }

    private func assertRendersWithoutCrashing(_ view: some View) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("The test host has no window scene")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()

        XCTAssertNotNil(host.view.window)
        XCTAssertFalse(host.view.bounds.isEmpty)
        XCTAssertFalse(host.view.subviews.isEmpty)
    }
}
