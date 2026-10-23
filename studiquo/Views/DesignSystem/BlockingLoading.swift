import SwiftUI

/// When the spinner appears and how long it stays, so that a fast response
/// does not flash a dim screen and a slow one does not blink away.
enum BlockingLoadingTiming {
    /// Requests that finish sooner than this never show the dimmed screen.
    static let showDelay: Duration = .milliseconds(250)
    /// Once shown, the spinner stays at least this long.
    static let minimumDisplay: TimeInterval = 0.4
    /// After this long a line explains that the server is slow.
    static let slowNoticeDelay: Duration = .seconds(15)

    /// How long the dimming takes to fade out after the request ends.
    static let fadeOut: Duration = .milliseconds(150)

    static func remainingMinimumDisplay(shownAt: Date, now: Date) -> TimeInterval {
        max(0, minimumDisplay - now.timeIntervalSince(shownAt))
    }
}

/// Which views draw an overlay for a source, so that a view nested in the
/// same presentation does not dim the screen a second time.
enum BlockingLoadingScope {
    /// A view whose ancestor already covers `source` stays quiet. A sheet or
    /// full-screen cover is a new presentation the ancestor's overlay cannot
    /// reach, so its root (`presentationRoot`) always draws its own.
    static func isCovered(source: String, presentationRoot: Bool, ancestors: Set<String>) -> Bool {
        !presentationRoot && ancestors.contains(source)
    }

    /// The sources covered for the views inside this one.
    static func sourcesCovered(source: String, presentationRoot: Bool, ancestors: Set<String>) -> Set<String> {
        presentationRoot ? [source] : ancestors.union([source])
    }
}

/// Which sources already have an overlay on an ancestor view, so that a view
/// nested inside the same presentation does not dim the screen a second time.
private struct BlockingLoadingSourcesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

private extension EnvironmentValues {
    var blockingLoadingSources: Set<String> {
        get { self[BlockingLoadingSourcesKey.self] }
        set { self[BlockingLoadingSourcesKey.self] = newValue }
    }
}

/// Dims the screen and shows a spinner at its center. The content below
/// cannot be touched while `isActive` is true, even during the short delay
/// before the dimming appears.
private struct BlockingLoadingModifier: ViewModifier {
    let isActive: Bool
    let source: String
    let presentationRoot: Bool
    @Environment(\.blockingLoadingSources) private var coveredSources
    @State private var isShown = false
    @State private var shownAt = Date.distantPast
    @State private var isSlow = false
    @State private var isFadingOut = false

    private var isCoveredByAncestor: Bool {
        BlockingLoadingScope.isCovered(source: source, presentationRoot: presentationRoot, ancestors: coveredSources)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.blockingLoadingSources, BlockingLoadingScope.sourcesCovered(source: source, presentationRoot: presentationRoot, ancestors: coveredSources))
            .accessibilityHidden(isShown)
            .overlay {
                if !isCoveredByAncestor && (isActive || isShown || isFadingOut) {
                    ZStack {
                        // Swallows touches from the first moment.
                        Color.clear.contentShape(Rectangle())
                        Color.black.opacity(isShown ? 0.35 : 0)
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            if isSlow {
                                Text("通信に時間がかかっています")
                                    .font(.footnote)
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(24)
                        .background(.ultraThinMaterial.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        .opacity(isShown ? 1 : 0)
                        .accessibilityHidden(!isShown)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("読み込み中"))
                        .accessibilityAddTraits(.updatesFrequently)
                    }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("blockingLoadingOverlay")
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isShown)
            .task(id: isActive) { await follow(isActive) }
    }

    @MainActor
    private func follow(_ active: Bool) async {
        // The ancestor's overlay does the work (announcement, keyboard,
        // hiding the content); doing it again here would repeat all of it.
        guard !isCoveredByAncestor else { return }
        if active {
            isSlow = false
            // Active again while the previous overlay is still up (waiting out
            // its minimum display): keep it, and only restart the slow notice.
            let wasShown = isShown
            if !wasShown {
                try? await Task.sleep(for: BlockingLoadingTiming.showDelay)
                guard !Task.isCancelled else { return }
                shownAt = Date()
                isShown = true
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                UIAccessibility.post(notification: .announcement, argument: L("読み込み中"))
            }
            try? await Task.sleep(for: wasShown
                ? BlockingLoadingTiming.slowNoticeDelay
                : BlockingLoadingTiming.slowNoticeDelay - BlockingLoadingTiming.showDelay)
            guard !Task.isCancelled else { return }
            isSlow = true
        } else if isShown {
            let wait = BlockingLoadingTiming.remainingMinimumDisplay(shownAt: shownAt, now: Date())
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // A new request may have started while waiting; the task is
            // cancelled then and the overlay stays up.
            guard !Task.isCancelled else { return }
            isFadingOut = true
            defer { isFadingOut = false }
            isShown = false
            isSlow = false
            try? await Task.sleep(for: BlockingLoadingTiming.fadeOut)
        }
    }
}

extension View {
    /// Blocks interaction and shows a dimmed spinner while `isActive`.
    ///
    /// Sheets and full-screen covers are separate presentations: put this on
    /// the presentation's root content with `presentationRoot: true`. Views
    /// nested in the same presentation that share a `source` with an ancestor
    /// do not draw a second overlay.
    func blockingLoading(_ isActive: Bool, source: String = "default", presentationRoot: Bool = false) -> some View {
        modifier(BlockingLoadingModifier(isActive: isActive, source: source, presentationRoot: presentationRoot))
    }
}
