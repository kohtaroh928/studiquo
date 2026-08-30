import SwiftUI

/// Decides when an interstitial ad should appear between study passes.
///
/// The counting and the presentation are kept apart on purpose. This type owns
/// only the rule — "every second completed pass" — and is what the app calls;
/// which ad network actually fills the slot is the `AdProvider`'s business.
/// Swapping in Google Mobile Ads later is then one conformance, with no change
/// to the flashcard screen.
@MainActor
final class InterstitialAdGate: ObservableObject {
    static let shared = InterstitialAdGate()

    /// Passes between ads. Two means the first pass is always uninterrupted,
    /// which keeps a quick review session clean.
    static let passesPerAd = 2

    private let defaultsKey = "flashcardPassesSinceAd"

    /// Set by the app at launch. Nil means no ad network is wired up yet, and
    /// the gate falls back to the built-in house placeholder so the timing can
    /// still be seen and tested.
    var provider: AdProvider?

    @Published var isShowingAd = false

    private var passesSinceAd: Int {
        get { UserDefaults.standard.integer(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private init() {}

    /// Call when the student finishes a pass through a deck.
    /// - Returns: `true` when an ad is being shown, so the caller can wait.
    @discardableResult
    func registerCompletedPass() -> Bool {
        passesSinceAd += 1
        guard passesSinceAd >= Self.passesPerAd else { return false }
        passesSinceAd = 0
        present()
        return true
    }

    private func present() {
        if let provider, provider.isReady {
            provider.presentInterstitial { [weak self] in
                self?.isShowingAd = false
            }
            isShowingAd = true
        } else {
            // No network configured (or nothing cached to show): the house
            // placeholder keeps the flow identical so the cadence is testable
            // before any SDK is added.
            isShowingAd = true
        }
    }

    func dismiss() { isShowingAd = false }
}

/// What an ad network has to provide. Implement this over Google Mobile Ads
/// (or any other SDK) and assign it to `InterstitialAdGate.shared.provider`
/// at launch; nothing else in the app needs to change.
@MainActor
protocol AdProvider: AnyObject {
    var isReady: Bool { get }
    func presentInterstitial(onDismiss: @escaping () -> Void)
}

/// Shown when no ad network is configured. Deliberately looks like a filled
/// slot rather than pretending to be a real advert.
struct InterstitialAdPlaceholder: View {
    let onDismiss: () -> Void

    @State private var remaining = 5

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                Text("広告スペース")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("2周ごとにここへ広告が表示されます。\n広告ネットワークを接続すると実際の広告に差し替わります。")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(remaining > 0 ? "閉じる（\(remaining)）" : "閉じる") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(remaining > 0)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
        .task {
            // Mirrors a real interstitial's mandatory dwell before the close
            // button becomes active.
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
        }
    }
}
