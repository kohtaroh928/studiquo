import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Local page OCR only. Native text is retained; mathematical OCR is never a correction.
enum RAGDocumentTextExtractionService {
    struct Line: Sendable {
        let text: String
        let confidence: Float
    }
    struct Recognition: Sendable {
        let lines: [Line]
        let failed: Bool
    }
    struct Result: Sendable {
        let text: String
        let supplementedLines: Int
        let rejectedLines: Int
        let needsReview: Bool
    }
    typealias Recognizer = (CGImage) async -> Recognition

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ] as CFDictionary)
    }
    static func recognize(_ image: CGImage) async -> Recognition {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                // Preserve the existing Japanese OCR setting. Formula candidates
                // are review-only below, never used as corrected native text.
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    continuation.resume(returning: Recognition(lines: (request.results ?? []).compactMap {
                        guard let candidate = $0.topCandidates(1).first else { return nil }
                        return Line(text: candidate.string, confidence: candidate.confidence)
                    }, failed: false))
                } catch {
                    continuation.resume(returning: Recognition(lines: [], failed: true))
                }
            }
        }
    }
    static func extract(nativeText: String, imageData: Data, recognizer: Recognizer = recognize) async -> Result {
        guard let image = image(from: imageData) else {
            return Result(text: nativeText, supplementedLines: 0, rejectedLines: 0, needsReview: true)
        }
        return merge(nativeText: nativeText, recognition: await recognizer(image))
    }
    static func isMathematical(_ text: String) -> Bool {
        text.range(of: "[=＝<>≤≥≠≈∑∫√∂∆Δα-ωΑ-Ω⁰-⁹₀-₉]|[A-Za-z0-9]\\s*[+×÷^/−－-]\\s*[A-Za-z0-9]|^[A-Za-z]{1,2}$", options: .regularExpression) != nil
    }
    static func merge(nativeText: String, recognition: Recognition) -> Result {
        // Comparison only: no compatibility normalization of output or superscripts.
        let compact: (String) -> String = { $0.filter { !$0.isWhitespace }.lowercased() }
        let native = compact(nativeText)
        let scanned = native.isEmpty
        let grams: (String) -> Set<String> = { value in
            let chars = Array(value)
            return chars.count < 2 ? Set([value]) : Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let nativeGrams = grams(native)
        var seen = Set<String>()
        var extra: [String] = []
        var rejected = 0
        var review = recognition.failed || isMathematical(nativeText)
        for line in recognition.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = compact(text)
            guard !key.isEmpty else { continue }
            if native.contains(key) || seen.contains(key) { continue }
            if isMathematical(text) { review = true; rejected += 1; continue }
            guard line.confidence.isFinite, line.confidence >= 0, text.count <= 1000 else {
                review = true; rejected += 1; continue
            }
            if line.confidence < 0.90 {
                review = true
                if !scanned { rejected += 1; continue }
            }
            // Isolated equation numbers/variables are not missing prose. They
            // otherwise create extra chunks and displace relevant native hits.
            let japanese = text.unicodeScalars.filter {
                (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            }.count
            let words = text.components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 4 && $0 != $0.uppercased() }
            if !scanned && japanese < 6 && words.count < 3 {
                review = true; rejected += 1; continue
            }
            // Near-duplicates are potential misreads, not missing sentences.
            let wanted = grams(key)
            if !native.isEmpty && Double(wanted.intersection(nativeGrams).count) / Double(max(1, wanted.count)) >= 0.6 {
                review = true; rejected += 1; continue
            }
            guard (scanned || key.count >= 4), extra.reduce(0, { $0 + $1.count }) + text.count <= 20_000 else {
                review = true; rejected += 1; continue
            }
            extra.append(text)
            seen.insert(key)
        }
        let text = extra.isEmpty ? nativeText : nativeText + (nativeText.isEmpty ? "" : "\n") + extra.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { review = true }
        return Result(text: text, supplementedLines: extra.count, rejectedLines: rejected, needsReview: review)
    }
}
