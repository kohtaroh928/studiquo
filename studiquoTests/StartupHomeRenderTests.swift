import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import studiquo

/// Regression for the iPad startup crash: the store opened, then building
/// ContentView.fullScreenHome's toolbar exhausted the main-thread stack.
/// Render the real home view in a window so SwiftUI evaluates that path.
@MainActor
final class StartupHomeRenderTests: XCTestCase {
    func testHomeRendersWithAnOpenedStore() async throws {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        container.mainContext.insert(Notebook(title: "Startup regression"))
        try container.mainContext.save()

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("The test host has no window scene")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let authentication = AuthenticationStore(service: "com.yabuko.studiquo.startup-render-tests")
        let root = ContentView()
            .modelContainer(container)
            .environmentObject(authentication)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        // HostingController.view alone does not force the NavigationSplitView
        // and its toolbar to render. A visible window and one update cycle do.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()

        XCTAssertNotNil(host.view.window)
        XCTAssertFalse(host.view.bounds.isEmpty)
        XCTAssertFalse(host.view.subviews.isEmpty)
    }
}
