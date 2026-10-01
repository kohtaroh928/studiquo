import Foundation
import ImageIO
import UIKit

/// Keeps note photos cheap to display. ImageIO creates a thumbnail directly
/// from compressed bytes, avoiding the full-size decode that `UIImage(data:)`
/// performs before SwiftUI scales an image down to its on-page rectangle.
enum NoteImagePipeline {
    enum ThumbnailTier: Int, CaseIterable, Sendable {
        case small = 256
        case medium = 512
        case large = 1_024
        case extraLarge = 2_048

        var maximumPixelSize: Int { rawValue }
    }

    static let maximumStoredPixelSize = 3_072
    static let maximumPreviewPixelSize = 3_072
    static let jpegQuality: CGFloat = 0.86

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func needsStorageOptimization(_ data: Data) -> Bool {
        guard let size = pixelSize(of: data) else { return false }
        return max(size.width, size.height) > CGFloat(maximumStoredPixelSize)
    }

    static func downsampledImage(from data: Data, maximumPixelSize: Int = maximumPreviewPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func optimizedStorageData(from data: Data) -> Data? {
        guard let image = downsampledImage(from: data, maximumPixelSize: maximumStoredPixelSize),
              let cgImage = image.cgImage else { return nil }
        let alpha = cgImage.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        return hasAlpha ? image.pngData() : image.jpegData(compressionQuality: jpegQuality)
    }

    static func optimizedStorageDataAsync(from data: Data) async -> Data? {
        await Task.detached(priority: .utility) { optimizedStorageData(from: data) }.value
    }

    /// Chooses the smallest useful decoded image for the element's current
    /// on-screen footprint. A bounded set of tiers prevents resize and pinch
    /// gestures from producing a new thumbnail for every intermediate point.
    static func thumbnailTier(
        forDisplayedSize displayedSize: CGSize,
        displayScale: CGFloat,
        zoomScale: CGFloat
    ) -> ThumbnailTier {
        let longestSide = max(displayedSize.width, displayedSize.height)
        let requiredPixels = max(1, longestSide * max(displayScale, 1) * max(zoomScale, 1))
        return ThumbnailTier.allCases.first { CGFloat($0.maximumPixelSize) >= requiredPixels } ?? .extraLarge
    }

    static func cacheKey(
        elementID: String,
        data: Data,
        thumbnailPixelSize: Int = maximumPreviewPixelSize
    ) -> String {
        // Reading a short prefix distinguishes replacement images without
        // hashing a multi-megabyte blob on the scrolling/main thread.
        let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(elementID):\(data.count):\(prefix):thumbnail-\(thumbnailPixelSize)"
    }
}

actor NoteImageCache {
    static let shared = NoteImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for key: String, data: Data, maximumPixelSize: Int = NoteImagePipeline.maximumPreviewPixelSize) async -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) {
            NoteImagePipeline.downsampledImage(from: data, maximumPixelSize: maximumPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }
}

/// Existing notebooks are upgraded only as their photos become visible and
/// only a few times per launch, avoiding a large CloudKit/write spike.
actor NoteImageMigrationBudget {
    static let shared = NoteImageMigrationBudget()
    private var claimed: Set<String> = []
    private var remaining = 4

    func claim(_ key: String) -> Bool {
        guard remaining > 0, claimed.insert(key).inserted else { return false }
        remaining -= 1
        return true
    }
}

/// Mutable geometry that deliberately does not publish changes. Scrolling
/// updates the page's global frame every display frame, but that must not
/// invalidate and rebuild every photo view merely to keep drag hand-off data
/// current.
final class PageGlobalFrameTracker {
    var frame: CGRect = .zero
}
