import SwiftUI
import UIKit
import QuickLook

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.makeController(items: items)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func makeController(items: [Any]) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
}

struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        Self.makeController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        Self.update(uiViewController, coordinator: context.coordinator, url: url)
    }

    static func makeController(coordinator: Coordinator) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = coordinator
        return controller
    }

    static func update(_ controller: QLPreviewController, coordinator: Coordinator, url: URL) {
        coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
