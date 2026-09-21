import SwiftUI
import UIKit

// MARK: - Generic "pull past the edge to add" gauge + overscroll detection
//
// A faithful, feature-agnostic port of the notebook feature's own
// `ContinuousPagesView` mechanism (`Views/NoteEditorView.swift`, see that
// type's doc comments for the original) — reused here by the slide deck
// and document features' own continuous-scroll views rather than copied a
// second and third time. Deliberately NOT wired into `NoteEditorView.swift`
// itself: that feature's own implementation is left completely untouched,
// the same "borrow the proven approach, don't touch the working original"
// choice `CanvasElementGeometry` made for the notes canvas's own
// drag/resize/rotate math (see that type's doc comment).
//
// One deliberate simplification versus the original: notes uses two
// different *primary* mechanisms for its two edges (KVO for the top; pure
// geometry for the bottom), pairing the top one with a geometry fallback.
// Here both edges use the same pairing uniformly — `ScrollOverscrollObserver`
// (KVO) plus `PullEdgeGeometryReader` (layout-driven), both feeding the same
// `update...Pull(overscroll:)` function at each call site, the same way
// notes' own `updateTopPull` takes readings from either source. Both halves
// are passive (neither installs a gesture, so neither competes with
// in-canvas touches such as a text box's own drag); one shared pairing for
// both edges is easier to keep correct across three features than deciding,
// per edge, which single source is reliable enough on its own.

/// Passively observes a real `UIScrollView` ancestor's scroll offset and
/// reports how far past `edge` the content has been pulled (rubber-band
/// overscroll) — installs no gesture, so it never competes with whatever
/// touch handling already lives inside the scrolled content.
struct ScrollOverscrollObserver: UIViewRepresentable {
    enum Edge { case top, bottom }
    let edge: Edge
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.edge = edge
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.edge = edge
        uiView.onChange = onChange
        uiView.attachWhenReady()
    }

    final class ObserverView: UIView {
        var edge: Edge = .top
        var onChange: ((CGFloat) -> Void)?
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachWhenReady()
        }

        func attachWhenReady() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            var candidate: UIView? = superview
            while let view = candidate, !(view is UIScrollView) { candidate = view.superview }
            guard let scrollView = candidate as? UIScrollView, scrollView !== observedScrollView else { return }
            observation = nil
            observedScrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                self.onChange?(self.overscroll(for: scrollView))
            }
        }

        private func overscroll(for scrollView: UIScrollView) -> CGFloat {
            switch edge {
            case .top:
                return max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
            case .bottom:
                let bottomEdge = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
                return max(0, bottomEdge - scrollView.contentSize.height)
            }
        }
    }
}

/// The pull-past-the-edge gauge itself — a progress ring, a "+" glyph, and
/// a caption, used identically at both edges (only the label text
/// differs). Purely a display component: whether a pull actually adds
/// something lives in `PullHoldTracker`, driven by whichever call site
/// owns the underlying `ScrollOverscrollObserver`/`PullEdgeGeometryReader`
/// pair — this view doesn't decide that itself.
struct PullToAddGauge: View {
    let progress: CGFloat
    let label: String
    let armedLabel: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        progress >= 1 ? Color.accentColor : Color.secondary,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(progress >= 1 ? Color.accentColor : .secondary)
                    .scaleEffect(progress >= 1 ? 1.12 : 1)
            }
            .frame(width: 48, height: 48)
            Text(progress >= 1 ? armedLabel : label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: 92)
        .opacity(progress > 0.001 ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: progress)
    }
}

/// Decides whether a pull gauge has been held at full progress long enough
/// to fire — an explicit, wall-clock check, deliberately matching the exact
/// numbers and shape of the notebook feature's own bottom-edge gauge
/// (`ContinuousPagesView`'s `pullHoldStartedAt`/`hasTriggeredPageAdd`
/// pair, in `onPreferenceChange(BottomAdderMaxYPreferenceKey.self)`):
/// `holdDuration` should always be passed the same `0.2` seconds notes
/// itself uses. An earlier version of this file instead fired the instant
/// progress returned to rest with no hold requirement at all, on the
/// theory that a fixed hold didn't match how people naturally release a
/// pull — but that was a guess made without being able to reproduce the
/// gesture on a real device, and it diverged from the one mechanism that's
/// actually proven correct in production. A caller owns one of these per
/// edge (as `@State`, since it's a value type) and calls `update(progress:
/// holdDuration:)` on every new overscroll reading from
/// `ScrollOverscrollObserver`/`PullEdgeGeometryReader`; it returns `true`
/// exactly once, the instant the hold duration is reached, and `false`
/// every other time — including every call after that, until progress
/// drops back below 1 and rises to full again (so a single sustained pull
/// only ever adds one thing).
struct PullHoldTracker {
    private var startedAt: Date?
    private var hasTriggered = false

    mutating func update(progress: CGFloat, holdDuration: TimeInterval, now: Date = .now) -> Bool {
        guard progress >= 1 else {
            startedAt = nil
            hasTriggered = false
            return false
        }
        if startedAt == nil { startedAt = now }
        guard !hasTriggered, let startedAt, now.timeIntervalSince(startedAt) >= holdDuration else { return false }
        hasTriggered = true
        return true
    }
}

/// A companion to `ScrollOverscrollObserver`: reads a pull gauge's own
/// position in the scroll view's *named* coordinate space on every ordinary
/// SwiftUI layout pass, rather than from `UIScrollView` value-change
/// notifications. `contentOffset` KVO only fires when that value actually
/// changes, so pairing it with a second, layout-driven reading means a
/// pull's progress is never missed just because a given moment produced no
/// new KVO tick. The notebook feature's own top-edge tracking pairs the same two sources
/// for the same reason ("Geometry is retained as a fallback… where the
/// representable is not attached directly beneath the page-list
/// `UIScrollView`" — `TopOverscrollObserver`'s doc comment); here both
/// edges get the pairing, not just the top one.
///
/// Requires the scroll view itself to carry `.coordinateSpace(name:)` with
/// a matching `spaceName`, and the host to turn the published minY/maxY
/// into an overscroll distance the same way `ScrollOverscrollObserver`
/// does — see `PullTopMinYPreferenceKey`/`PullBottomMaxYPreferenceKey`.
struct PullEdgeGeometryReader: View {
    enum Edge { case top, bottom }
    let edge: Edge
    let spaceName: String

    var body: some View {
        GeometryReader { proxy in
            switch edge {
            case .top:
                Color.clear.preference(key: PullTopMinYPreferenceKey.self, value: proxy.frame(in: .named(spaceName)).minY)
            case .bottom:
                Color.clear.preference(key: PullBottomMaxYPreferenceKey.self, value: proxy.frame(in: .named(spaceName)).maxY)
            }
        }
    }
}

/// The top pull gauge's own minY within the scroll view's named coordinate
/// space. At rest this equals the content's top padding; pulling down
/// past the edge increases it further, so `minY - topContentPadding` is the
/// overscroll distance — the same arithmetic the notebook feature's own
/// `TopAdderMinYPreferenceKey` uses. `min`, not a plain assignment: exactly
/// one gauge in the tree ever really publishes this, but SwiftUI folds the
/// key over the *whole* subtree, and every other view contributes the
/// default — `min` lets the one real reading through regardless of publish
/// order.
struct PullTopMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// The bottom pull gauge's own maxY within the scroll view's named
/// coordinate space. At rest this equals the viewport height minus the
/// content's bottom padding; pulling up past the edge decreases it, so
/// `restingMaxY - maxY` is the overscroll distance — the same arithmetic
/// the notebook feature's own `BottomAdderMaxYPreferenceKey` uses. `max`,
/// mirroring `PullTopMinYPreferenceKey`'s own reasoning for `min`.
struct PullBottomMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = -.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Publishes how tall a `LazyVStack`'s content actually is, so a host can
/// guard "only allow the pull gauge to engage when there's more content
/// than fits the viewport" — otherwise a short list would treat any touch
/// as a pull. `reduce` must be `max`, not a plain assignment: SwiftUI folds
/// this key over the whole subtree, and a branch that never sets it
/// contributes the default `0` — a plain assignment lets one of those
/// zeros land last and silently wipe out the real measurement, which is
/// exactly what happened in the notebook feature's own first version of
/// this and permanently disabled its pull-to-add gesture.
struct ScrollContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
