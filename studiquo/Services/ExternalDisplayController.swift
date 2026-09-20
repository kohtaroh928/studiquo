import SwiftUI
import UIKit
import Combine

/// Watches for a connected external display — a cable, or AirPlay "Screen
/// Mirroring" started from Control Center, which iOS exposes as a regular
/// extra `UIScreen` the same as a physical monitor, so no `AVRoutePickerView`
/// wiring is needed to detect one — and hosts a SwiftUI view on it via a
/// plain `UIWindow` (no multi-scene `Info.plist` setup required; assigning
/// `.screen` directly is still the standard, supported way to do this for a
/// single-scene app). `SlidePresentationView` uses this for design step 7's
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
        isConnected = UIScreen.screens.count > 1
        NotificationCenter.default.publisher(for: UIScreen.didConnectNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIScreen.didDisconnectNotification))
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        isConnected = UIScreen.screens.count > 1
        if !isConnected { window = nil }
    }

    /// Mounts (or, if already showing, updates in place) `content` on the
    /// first connected non-main screen. Safe to call on every slide/reveal
    /// change — reuses the existing hosting controller's `rootView` rather
    /// than tearing the window down each time, so the external screen
    /// doesn't flash between updates.
    func show(@ViewBuilder content: () -> AnyView) {
        guard let externalScreen = UIScreen.screens.first(where: { $0 !== UIScreen.main }) else { return }
        if let hosting = window?.rootViewController as? UIHostingController<AnyView> {
            hosting.rootView = content()
            return
        }
        let hosting = UIHostingController(rootView: content())
        let newWindow = window ?? UIWindow(frame: externalScreen.bounds)
        newWindow.screen = externalScreen
        newWindow.rootViewController = hosting
        newWindow.isHidden = false
        window = newWindow
    }

    func hide() {
        window = nil
    }
}
