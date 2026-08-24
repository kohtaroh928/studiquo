import Foundation
import Vision

enum HandwritingRecognitionService {
    static func recognize(drawingData: Data?, pageSize: CGSize) async -> String {
        guard let drawingData,
              let drawing = InkDrawing.load(from: drawingData),
              !drawing.strokes.isEmpty else { return "" }

        let bounds = CGRect(origin: .zero, size: pageSize)
        return await recognize(drawing: drawing, bounds: bounds)
    }

    /// Recognises only the strokes selected by the lasso. Cropping before
    /// rasterising keeps both Vision's input and the work it performs small,
    /// regardless of how many pages the notebook contains.
    static func recognize(drawing: InkDrawing) async -> String {
        guard let first = drawing.strokes.first else { return "" }
        let inkBounds = drawing.strokes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let padding = max(12, min(32, max(inkBounds.width, inkBounds.height) * 0.06))
        return await recognize(drawing: drawing, bounds: inkBounds.insetBy(dx: -padding, dy: -padding))
    }

    private static func recognize(drawing: InkDrawing, bounds: CGRect) async -> String {
        let image = drawing.image(from: bounds, scale: 2)
        guard let cgImage = image.cgImage else { return "" }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, _ in
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            }
        }
    }
}
