import Foundation
import Vision

enum HandwritingRecognitionService {
    static func recognize(drawingData: Data?, pageSize: CGSize) async -> String {
        guard let drawingData,
              let drawing = InkDrawing.load(from: drawingData),
              !drawing.strokes.isEmpty else { return "" }

        let bounds = CGRect(origin: .zero, size: pageSize)
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
