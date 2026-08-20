import SwiftUI
import UIKit

/// Pinch-zoom + pan container backed by a real `UIScrollView`.
///
/// The previous SwiftUI implementation stacked a `MagnifyGesture` and a
/// `DragGesture` on top of the page list and applied `.scaleEffect`/`.offset`.
/// On-device instrumentation showed the drag never fired even at 5× zoom:
/// the page list's own `UIScrollView` owns the touch, and a SwiftUI gesture
/// layered outside it cannot take that ownership away — `highPriorityGesture`
/// only orders SwiftUI gestures against each other. So panning a zoomed page
/// never actually moved the transform; it fought the scroll view instead,
/// which is what read as stutter.
///
/// Making the panner itself a `UIScrollView` removes the conflict at the
/// source: UIKit arbitrates between the outer (zoom/pan) and inner (page
/// scrolling) scroll views natively, the way GoodNotes and Notability do it.
///
/// Content is hosted at exactly viewport size. At 1× the content size equals
/// the bounds, so the outer view has nothing to scroll and touches fall
/// through to the page list underneath. Once zoomed, the content grows past
/// the bounds and the outer view takes over panning.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    var minimumZoomScale: CGFloat = 1
    var maximumZoomScale: CGFloat = 5
    /// Reports the live zoom scale so callers can disable inner scrolling or
    /// surface a zoom indicator.
    var onZoomChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minimumZoomScale
        scrollView.maximumZoomScale = maximumZoomScale
        scrollView.bouncesZoom = true
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // Apple Pencil must never drive this scroll view. Letting it do so
        // makes UIKit hand the touch to the scroll view mid-stroke, which
        // cancels PencilKit's in-progress drawing — the stroke renders while
        // the pencil is down and then vanishes on lift. Device logs caught
        // exactly that (`outerPan touches=1` during drawing, and the canvas
        // ending the gesture with no new stroke).
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        // Deliver touches to content immediately. `canCancelContentTouches`
        // is deliberately left at its default (true): setting it false stops
        // the scroll view from ever reclaiming a touch that landed on content,
        // and since the page canvas covers the whole viewport that means no
        // drag can ever scroll. The pencil is already protected by the
        // direct-touch restriction on the pan recogniser above.
        scrollView.delaysContentTouches = false
        // NOTE: never disable `isScrollEnabled` to "get out of the way" at
        // 1× — UIScrollView gates its pinch recognizer on the same flag, so
        // doing that makes zooming itself sluggish/unresponsive. At 1× the
        // content size equals the bounds, which already leaves nothing to
        // scroll.

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        context.coordinator.hostingController = host
        scrollView.addSubview(host.view)

        // Double-tap to reset, matching the old behaviour.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        guard let host = context.coordinator.hostingController else { return }
        host.rootView = content()

        let viewportSize = scrollView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        // Never re-frame the hosted view mid-gesture: UIScrollView drives it
        // with a transform while zooming, and overwriting the frame then
        // would snap the content out from under the user's fingers.
        guard !scrollView.isZooming, !scrollView.isZoomBouncing else { return }

        // Only ever resize the hosted content at 1×. Re-framing it while the
        // user is zoomed in visibly resizes the page under their finger,
        // because UIScrollView expresses zoom as a transform on this very
        // view and a frame write fights that.
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 else { return }

        if host.view.bounds.size != viewportSize {
            host.view.frame = CGRect(origin: .zero, size: viewportSize)
            scrollView.contentSize = viewportSize
            GestureDiagnostics.zoomViewLayout(
                bounds: viewportSize,
                hostFrame: host.view.frame,
                contentSize: scrollView.contentSize,
                zoom: scrollView.zoomScale
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChange: onZoomChange)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<Content>?
        var onZoomChange: (CGFloat) -> Void

        init(onZoomChange: @escaping (CGFloat) -> Void) {
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController?.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Keep the content centred while it is smaller than the viewport
            // in either axis, so zooming out doesn't pin it to a corner.
            guard let hosted = hostingController?.view else { return }
            // Centring insets are only meaningful while zoomed in. Leaving
            // them applied at 1× pushes the page inward, which reads as the
            // note having shrunk.
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
                let horizontalInset = max(0, (scrollView.bounds.width - hosted.frame.width) / 2)
                let verticalInset = max(0, (scrollView.bounds.height - hosted.frame.height) / 2)
                scrollView.contentInset = UIEdgeInsets(
                    top: verticalInset,
                    left: horizontalInset,
                    bottom: verticalInset,
                    right: horizontalInset
                )
            } else if scrollView.contentInset != .zero {
                scrollView.contentInset = .zero
            }
            onZoomChange(scrollView.zoomScale)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            onZoomChange(scale)
            GestureDiagnostics.zoomViewLayout(
                bounds: scrollView.bounds.size,
                hostFrame: view?.frame ?? .zero,
                contentSize: scrollView.contentSize,
                zoom: scale
            )
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            let target: CGFloat = scrollView.zoomScale > scrollView.minimumZoomScale
                ? scrollView.minimumZoomScale
                : min(2, scrollView.maximumZoomScale)
            scrollView.setZoomScale(target, animated: true)
        }
    }
}
