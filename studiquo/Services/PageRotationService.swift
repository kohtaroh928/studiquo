import UIKit

enum PageRotationService {
    static func rotateClockwise(_ page: NotePage) {
        let oldWidth = page.pageWidth
        let oldHeight = page.pageHeight

        if let data = page.backgroundImageData, let image = UIImage(data: data) {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: image.size.height, height: image.size.width))
            let rotated = renderer.image { context in
                context.cgContext.translateBy(x: image.size.height, y: 0)
                context.cgContext.rotate(by: .pi / 2)
                image.draw(at: .zero)
            }
            page.backgroundImageData = rotated.jpegData(compressionQuality: 0.92)
        }

        if let data = page.drawingData, let drawing = InkDrawing.load(from: data) {
            let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: oldHeight, ty: 0)
            page.drawingData = try? drawing.transformed(by: transform).data()
        }

        for element in page.elements {
            let oldX = element.centerX
            element.centerX = 1 - element.centerY
            element.centerY = oldX
            let oldElementWidth = element.width
            element.width = element.height
            element.height = oldElementWidth
            element.rotation += 90
        }
        page.pageWidth = oldHeight
        page.pageHeight = oldWidth
        page.notebook?.updatedAt = .now
    }
}
