import SwiftUI
import UIKit

/// Keeps what is on screen out of the app switcher.
///
/// iOS takes a picture of each window as the app leaves the foreground and
/// shows it in the app switcher (and keeps it on disk for a while). A protected
/// notebook the student has open, a connection token they have revealed, or the
/// sign-in form would all be in it. Only those screens are covered: a view marks
/// itself with `.hidesInAppSwitcher(when:)`, and when its scene stops being
/// active a plain cover is put over that scene's windows until it is active again.
/// Ordinary notes are left as they are.
///
/// Per scene, because an iPad can show the app in several windows and only the
/// one with a sensitive screen needs covering.

/// How many sensitive views each scene is showing right now.
@MainActor
final class SensitiveScreenRegistry {
    static let shared = SensitiveScreenRegistry()
    private var counts: [String: Int] = [:]

    func add(scene: String) { counts[scene, default: 0] += 1 }

    func remove(scene: String) {
        guard let count = counts[scene] else { return }
        counts[scene] = count > 1 ? count - 1 : nil
    }

    func hasSensitiveContent(scene: String) -> Bool { counts[scene] != nil }
}

/// The cover itself: an opaque view over a whole window.
enum PrivacyCover {
    static let tag = 0x5351_5043

    /// Idempotent; always ends up as the front-most subview.
    static func install(on window: UIWindow) {
        remove(from: window)
        let cover = UIView(frame: window.bounds)
        cover.tag = tag
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .systemBackground
        cover.isUserInteractionEnabled = false
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        icon.center = CGPoint(x: cover.bounds.midX, y: cover.bounds.midY)
        icon.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        cover.addSubview(icon)
        window.addSubview(cover)
    }

    static func remove(from window: UIWindow) {
        window.subviews.filter { $0.tag == tag }.forEach { $0.removeFromSuperview() }
    }

    static func isCovered(_ window: UIWindow) -> Bool {
        window.subviews.contains { $0.tag == tag }
    }
}

/// Puts the cover on when a scene with a sensitive screen stops being active,
/// and takes it off when it is active again.
@MainActor
final class AppSwitcherPrivacyCover {
    static let shared = AppSwitcherPrivacyCover()
    private var observers: [NSObjectProtocol] = []
    private let registry: SensitiveScreenRegistry

    init(registry: SensitiveScreenRegistry = .shared) { self.registry = registry }

    func start(center: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        // willDeactivate comes before the picture is taken; didEnterBackground is
        // the backstop for a scene that goes straight there.
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let scene = note.object as? UIWindowScene else { return }
                    self?.cover(windows: scene.windows, sceneID: scene.session.persistentIdentifier)
                }
            })
        }
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIWindowScene else { return }
                scene.windows.forEach { PrivacyCover.remove(from: $0) }
            }
        })
    }

    /// Covers `windows` when the scene has a sensitive screen showing.
    func cover(windows: [UIWindow], sceneID: String) {
        guard registry.hasSensitiveContent(scene: sceneID) else { return }
        windows.forEach { PrivacyCover.install(on: $0) }
    }
}

/// Reports to the registry while it is in a window, which is what makes the
/// view it sits behind "on screen".
private struct SensitiveScreenReporter: UIViewRepresentable {
    func makeUIView(context: Context) -> ReporterView { ReporterView() }
    func updateUIView(_ uiView: ReporterView, context: Context) {}

    final class ReporterView: UIView {
        private var registeredScene: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            unregister()
            register(in: newWindow)
        }

        /// Tried again once the view is in the window: the window may not know its
        /// scene yet at `willMove`, and a view that never registered would leave
        /// its scene uncovered.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if registeredScene == nil { register(in: window) }
        }

        private func register(in window: UIWindow?) {
            guard let scene = window?.windowScene?.session.persistentIdentifier else { return }
            MainActor.assumeIsolated { SensitiveScreenRegistry.shared.add(scene: scene) }
            registeredScene = scene
        }

        private func unregister() {
            guard let scene = registeredScene else { return }
            MainActor.assumeIsolated { SensitiveScreenRegistry.shared.remove(scene: scene) }
            registeredScene = nil
        }

        deinit {
            if let scene = registeredScene {
                Task { @MainActor in SensitiveScreenRegistry.shared.remove(scene: scene) }
            }
        }
    }
}

extension View {
    /// While `isSensitive` and on screen, this scene is covered in the app switcher.
    func hidesInAppSwitcher(when isSensitive: Bool = true) -> some View {
        background { if isSensitive { SensitiveScreenReporter() } }
    }
}
