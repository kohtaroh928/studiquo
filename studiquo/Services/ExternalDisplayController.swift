import SwiftUI
import UIKit
import Combine

/// Watches for a connected external-display scene — a cable or AirPlay —
/// and hosts a SwiftUI view in that scene. `SlidePresentationView` uses this
/// for design step 7's
/// presenter mode: the audience sees only the slide on the external screen,
/// while the device itself switches to a presenter layout.
///
/// This can only be exercised on real external-display/AirPlay hardware —
/// there is no way to simulate a second `UIScreen` in the iOS Simulator or
/// this environment, so unlike the rest of this feature's UI, this file has
/// had no live verification at all, only a build check.
@MainActor
final class ExternalDisplayController: ObservableObject {
    @Published private(set) var isConnected: Bool

    private var window: UIWindow?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        isConnected = Self.externalWindowScene() != nil
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification))
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        isConnected = Self.externalWindowScene() != nil
        if !isConnected { hide() }
    }

    /// `openSessions` is the scene-lifecycle replacement for the deprecated
    /// global `UIScreen.screens` list. Archived sessions have no live scene,
    /// so the cast also filters those out.
    private static func externalWindowScene() -> UIWindowScene? {
        UIApplication.shared.openSessions.lazy
            .filter { $0.role == .windowExternalDisplayNonInteractive }
            .compactMap { $0.scene as? UIWindowScene }
            .first
    }

    /// Mounts (or, if already showing, updates in place) `content` on the
    /// first connected non-main screen. Safe to call on every slide/reveal
    /// change — reuses the existing hosting controller's `rootView` rather
    /// than tearing the window down each time, so the external screen
    /// doesn't flash between updates.
    func show(@ViewBuilder content: () -> AnyView) {
        guard let externalScene = Self.externalWindowScene() else { return }
        if let hosting = window?.rootViewController as? UIHostingController<AnyView> {
            hosting.rootView = content()
            return
        }
        let hosting = UIHostingController(rootView: content())
        let newWindow = UIWindow(windowScene: externalScene)
        newWindow.rootViewController = hosting
        newWindow.makeKeyAndVisible()
        window = newWindow
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
