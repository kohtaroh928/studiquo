import XCTest
import UIKit
@testable import studiquo

final class NoteImagePipelineTests: XCTestCase {
    func testLargePhotoIsStoredWithinThePixelLimit() throws {
        let source = imageData(size: CGSize(width: 4_200, height: 2_800))

        let optimized = try XCTUnwrap(NoteImagePipeline.optimizedStorageData(from: source))
        let size = try XCTUnwrap(NoteImagePipeline.pixelSize(of: optimized))

        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(NoteImagePipeline.maximumStoredPixelSize))
        XCTAssertTrue(NoteImagePipeline.needsStorageOptimization(source))
        XCTAssertFalse(NoteImagePipeline.needsStorageOptimization(optimized))
    }

    func testPreviewDownsamplingDoesNotDecodeAtOriginalCameraResolution() throws {
        let source = imageData(size: CGSize(width: 4_000, height: 3_000))

        let preview = try XCTUnwrap(NoteImagePipeline.downsampledImage(from: source, maximumPixelSize: 1_024))

        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 1_024)
    }

    func testCacheReusesTheDecodedPreviewForRepeatedScrollEvaluations() async throws {
        let source = imageData(size: CGSize(width: 1_600, height: 1_200))
        let key = NoteImagePipeline.cacheKey(elementID: "element-1", data: source, thumbnailPixelSize: 512)

        let first = await NoteImageCache.shared.image(for: key, data: source, maximumPixelSize: 512)
        let second = await NoteImageCache.shared.image(for: key, data: source, maximumPixelSize: 512)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "the same element must reuse its decoded image instead of decoding on every body update")
    }

    func testReplacementImageGetsADifferentCacheKeyEvenWhenItsByteCountMatches() {
        let first = Data(repeating: 1, count: 100)
        let replacement = Data(repeating: 2, count: 100)

        XCTAssertNotEqual(
            NoteImagePipeline.cacheKey(elementID: "element-1", data: first),
            NoteImagePipeline.cacheKey(elementID: "element-1", data: replacement)
        )
    }

    func testDisplayedSizeSelectsTheSmallestSufficientThumbnailTier() {
        XCTAssertEqual(
            NoteImagePipeline.thumbnailTier(
                forDisplayedSize: CGSize(width: 200, height: 100), displayScale: 1, zoomScale: 1
            ),
            .small
        )
        XCTAssertEqual(
            NoteImagePipeline.thumbnailTier(
                forDisplayedSize: CGSize(width: 430, height: 200), displayScale: 1, zoomScale: 1
            ),
            .medium
        )
    }

    func testThumbnailTierIncludesRetinaAndZoomScale() {
        XCTAssertEqual(
            NoteImagePipeline.thumbnailTier(
                forDisplayedSize: CGSize(width: 200, height: 120), displayScale: 2, zoomScale: 2
            ),
            .large
        )
    }

    func testThumbnailTierIsCappedAtExtraLarge() {
        XCTAssertEqual(
            NoteImagePipeline.thumbnailTier(
                forDisplayedSize: CGSize(width: 2_000, height: 1_000), displayScale: 3, zoomScale: 5
            ),
            .extraLarge
        )
    }

    func testThumbnailTierDoesNotChangeWithinTheSameBucket() {
        let first = NoteImagePipeline.thumbnailTier(
            forDisplayedSize: CGSize(width: 300, height: 200), displayScale: 1, zoomScale: 1
        )
        let resized = NoteImagePipeline.thumbnailTier(
            forDisplayedSize: CGSize(width: 500, height: 300), displayScale: 1, zoomScale: 1
        )

        XCTAssertEqual(first, .medium)
        XCTAssertEqual(first, resized)
    }

    func testDifferentThumbnailTiersHaveDifferentCacheKeys() {
        let source = Data(repeating: 3, count: 100)

        XCTAssertNotEqual(
            NoteImagePipeline.cacheKey(elementID: "element-1", data: source, thumbnailPixelSize: 256),
            NoteImagePipeline.cacheKey(elementID: "element-1", data: source, thumbnailPixelSize: 512)
        )
    }

    private func imageData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.95)!
    }
}
