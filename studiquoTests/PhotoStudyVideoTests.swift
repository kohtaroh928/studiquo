import AVFoundation
import Photos
import XCTest
@testable import studiquo

/// 写真アプリと2分割するペインで、写真に加えて動画も一覧・再生できることの確認。
final class PhotoStudyVideoTests: XCTestCase {
    func testDurationIsFormattedLikeThePhotosApp() {
        XCTAssertEqual(PhotoStudyDuration.string(from: 0), "0:00")
        XCTAssertEqual(PhotoStudyDuration.string(from: 7.9), "0:07")
        XCTAssertEqual(PhotoStudyDuration.string(from: 59), "0:59")
        XCTAssertEqual(PhotoStudyDuration.string(from: 60), "1:00")
        XCTAssertEqual(PhotoStudyDuration.string(from: 754), "12:34")
        XCTAssertEqual(PhotoStudyDuration.string(from: 3723), "1:02:03")
    }

    func testDurationToleratesInvalidValues() {
        XCTAssertEqual(PhotoStudyDuration.string(from: -5), "0:00")
        XCTAssertEqual(PhotoStudyDuration.string(from: .nan), "0:00")
        XCTAssertEqual(PhotoStudyDuration.string(from: .infinity), "0:00")
    }

    func testMediaKindMapsPhotoKitMediaType() {
        XCTAssertEqual(PhotoStudyMediaKind(.video), .video)
        XCTAssertEqual(PhotoStudyMediaKind(.image), .photo)
        XCTAssertEqual(PhotoStudyMediaKind(.audio), .photo)
        XCTAssertEqual(PhotoStudyMediaKind(.unknown), .photo)
    }

    func testAssetDefaultsToAPhoto() {
        let asset = PhotoStudyAsset(id: "a", pixelWidth: 1, pixelHeight: 1, creationDate: nil)
        XCTAssertEqual(asset.kind, .photo)
        XCTAssertEqual(asset.duration, 0)
    }

    @MainActor
    func testLibraryQueryIncludesPhotosAndVideosOnly() {
        let predicate = PhotoStudyLibraryModel.mediaPredicate
        XCTAssertTrue(predicate.evaluate(with: ["mediaType": PHAssetMediaType.image.rawValue]))
        XCTAssertTrue(predicate.evaluate(with: ["mediaType": PHAssetMediaType.video.rawValue]))
        XCTAssertFalse(predicate.evaluate(with: ["mediaType": PHAssetMediaType.audio.rawValue]))
        XCTAssertFalse(predicate.evaluate(with: ["mediaType": PHAssetMediaType.unknown.rawValue]))
    }

    // MARK: - 再生の後始末(PhotoKitの遅延コールバック)

    private final class Fake {
        var completion: ((AVPlayerItem?, Error?) -> Void)?
        var cancelled: [PHImageRequestID?] = []
        var activated = 0
        var deactivated = 0
    }

    @MainActor
    private func makePlayback(_ fake: Fake) -> PhotoStudyVideoPlayback {
        PhotoStudyVideoPlayback(
            request: { _, _, completion in
                fake.completion = completion
                return 7
            },
            cancelRequest: { fake.cancelled.append($0) },
            activateAudio: { fake.activated += 1 },
            deactivateAudio: { fake.deactivated += 1 }
        )
    }

    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor
    func testItemDeliveredAfterStopNeverStartsPlayback() async {
        let fake = Fake()
        let playback = makePlayback(fake)
        playback.start(identifier: "a")
        playback.stop()
        fake.completion?(item(), nil)
        await settle()
        XCTAssertNil(playback.player, "ペインを閉じたあとに届いた動画で再生が始まってはいけません。")
        XCTAssertEqual(fake.activated, 0)
        XCTAssertEqual(fake.cancelled.count, 2)
    }

    @MainActor
    func testItemFromASupersededRequestIsDroppedAfterRetry() async {
        let fake = Fake()
        let playback = makePlayback(fake)
        playback.start(identifier: "a")
        let first = fake.completion
        playback.start(identifier: "a")
        first?(item(), nil)
        await settle()
        XCTAssertNil(playback.player, "再試行前の要求の結果で再生してはいけません。")
        fake.completion?(item(), nil)
        await settle()
        XCTAssertNotNil(playback.player)
        XCTAssertEqual(fake.activated, 1)
    }

    @MainActor
    func testStopReleasesPlayerAndAudioSession() async {
        let fake = Fake()
        let playback = makePlayback(fake)
        playback.start(identifier: "a")
        fake.completion?(item(), nil)
        await settle()
        XCTAssertNotNil(playback.player)
        playback.stop()
        XCTAssertNil(playback.player)
        XCTAssertEqual(fake.deactivated, 1)
        playback.stop()
        XCTAssertEqual(fake.deactivated, 1, "再生していないときに音声セッションを解放し直してはいけません。")
    }

    @MainActor
    func testFailureIsReportedAndRetryClearsIt() async {
        let fake = Fake()
        let playback = makePlayback(fake)
        playback.start(identifier: "a")
        fake.completion?(nil, nil)
        await settle()
        XCTAssertNil(playback.player)
        XCTAssertNotNil(playback.errorMessage)
        playback.start(identifier: "a")
        XCTAssertNil(playback.errorMessage)
    }

    private func librarySource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/PhotoStudyLibraryView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 動画が分割ペインから抜けたあとも音だけ鳴り続けない、ペインの外へ全画面化しない、
    /// という契約は実機の画面でしか観測できないため、実装の構造で守る。
    func testVideoPlaybackStopsWhenTheViewerLeavesTheScreen() throws {
        let source = try librarySource()
        let viewerStart = try XCTUnwrap(source.range(of: "struct PhotoStudyPaneViewer"))
        let viewer = source[viewerStart.lowerBound...]
        XCTAssertTrue(viewer.contains(".onDisappear(perform: cancel)"))
        XCTAssertTrue(viewer.contains("playback.stop()"), "ビューアが消えたら再生を止めてください。")
        XCTAssertTrue(viewer.contains("entersFullScreenWhenPlaybackBegins = false"), "再生開始でノート側まで覆う全画面にしてはいけません。")
    }
}
