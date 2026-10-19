import PDFKit
import SwiftUI

/// Shows one page's PDF in a `PDFView`, so its text is selectable with the
/// system's own handles, highlight and menu (including 調べる).
/// Scrolling and zooming belong to the editor, so the view's own are off.
struct PageNativePDFView: UIViewRepresentable {
    let pdfData: Data

    func makeUIView(context: Context) -> PDFView {
        let view = FixedScalePDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displayBox = .mediaBox
        view.displaysPageBreaks = false
        view.pageBreakMargins = .zero
        view.backgroundColor = .white
        view.document = PDFDocument(data: pdfData)
        context.coordinator.loadedData = pdfData
        Self.disableInnerScrolling(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedData != pdfData {
            view.document = PDFDocument(data: pdfData)
            context.coordinator.loadedData = pdfData
        }
        Self.disableInnerScrolling(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loadedData: Data? }

    /// A `PDFView` that always shows its page at the size that fills the view.
    ///
    /// Its own pinch would zoom the page's text inside the frame while the ink
    /// and elements stayed put; zooming belongs to the editor's
    /// `ZoomableScrollView`, which scales the whole page together. So the
    /// scale is pinned to that size and every pinch recognizer inside is
    /// switched off, leaving the pinch to reach the editor.
    final class FixedScalePDFView: PDFView {
        override func layoutSubviews() {
            super.layoutSubviews()
            lockScale()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            lockScale()
        }

        private func lockScale() {
            autoScales = false
            // Fill the frame exactly, from the same media box the page bitmap
            // was drawn from. `scaleFactorForSizeToFit` leaves a margin, which
            // would shift the printed text away from the ink drawn over it.
            if let page = document?.page(at: 0), bounds.width > 0, bounds.height > 0 {
                let size = PDFImportService.displaySize(of: page)
                if size.width > 0, size.height > 0 {
                    let fill = min(bounds.width / size.width, bounds.height / size.height)
                    minScaleFactor = fill
                    maxScaleFactor = fill
                    if abs(scaleFactor - fill) > 0.0001 { scaleFactor = fill }
                }
            }
            Self.disablePinch(in: self)
        }

        private static func disablePinch(in view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UIPinchGestureRecognizer {
                recognizer.isEnabled = false
            }
            for subview in view.subviews { disablePinch(in: subview) }
        }
    }

    /// PDFView hosts its own scroll view; leaving it live would fight the
    /// editor's page list and zoom container for every drag.
    private static func disableInnerScrolling(_ view: PDFView) {
        for case let scroll as UIScrollView in view.subviews {
            scroll.isScrollEnabled = false
            scroll.pinchGestureRecognizer?.isEnabled = false
        }
    }
}
