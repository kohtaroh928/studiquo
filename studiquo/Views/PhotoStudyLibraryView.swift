import SwiftUI
import AVFoundation
import AVKit
import Photos
import UIKit

enum PhotoStudyPane: Equatable {
    case primary
    case secondary

    var opposite: PhotoStudyPane {
        self == .primary ? .secondary : .primary
    }
}

/// Keeps the reference-photo pane away from the note the student is editing.
/// The policy is deliberately independent of `NoteEditorView` so its edge
/// cases can be covered without constructing the entire editor hierarchy.
enum PhotoStudyPlacementPolicy {
    static func notePane(
        lastActive: PhotoStudyPane,
        primaryCanEdit: Bool,
        secondaryCanEdit: Bool
    ) -> PhotoStudyPane {
        if lastActive == .primary, primaryCanEdit { return .primary }
        if lastActive == .secondary, secondaryCanEdit { return .secondary }
        if primaryCanEdit { return .primary }
        if secondaryCanEdit { return .secondary }
        return .primary
    }

    static func photoPane(
        lastActive: PhotoStudyPane,
        primaryCanEdit: Bool,
        secondaryCanEdit: Bool
    ) -> PhotoStudyPane {
        notePane(
            lastActive: lastActive,
            primaryCanEdit: primaryCanEdit,
            secondaryCanEdit: secondaryCanEdit
        ).opposite
    }
}

enum PhotoStudyMediaKind: Equatable {
    case photo
    case video

    init(_ mediaType: PHAssetMediaType) {
        self = mediaType == .video ? .video : .photo
    }
}

struct PhotoStudyAsset: Identifiable, Equatable {
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    var kind: PhotoStudyMediaKind = .photo
    var duration: TimeInterval = 0
}

enum PhotoStudyDuration {
    /// "0:07", "12:34", "1:02:03". Fractions are rounded down like the Photos app.
    static func string(from seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

@MainActor
final class PhotoStudyLibraryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    enum Access: Equatable {
        case notDetermined
        case authorized
        case limited
        case denied
        case restricted
    }

    @Published private(set) var access: Access
    @Published private(set) var assets: [PhotoStudyAsset] = []
    @Published private(set) var isLoading = false

    override init() {
        access = Self.access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        super.init()
        PHPhotoLibrary.shared().register(self)
        reloadIfAllowed()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func requestAccess() {
        guard access == .notDetermined else { return }
        isLoading = true
        Task { @MainActor [weak self] in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard let self else { return }
            access = Self.access(for: status)
            isLoading = false
            reloadIfAllowed()
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func manageLimitedAccess() {
        guard access == .limited,
              let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func reloadIfAllowed() {
        access = Self.access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard access == .authorized || access == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = Self.mediaPredicate
        let result = PHAsset.fetchAssets(with: options)
        var updated: [PhotoStudyAsset] = []
        updated.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            updated.append(
                PhotoStudyAsset(
                    id: asset.localIdentifier,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate,
                    kind: PhotoStudyMediaKind(asset.mediaType),
                    duration: asset.duration
                )
            )
        }
        assets = updated
    }

    /// Photos and videos are both study material.
    static let mediaPredicate = NSPredicate(
        format: "mediaType == %d OR mediaType == %d",
        PHAssetMediaType.image.rawValue,
        PHAssetMediaType.video.rawValue
    )

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.reloadIfAllowed()
        }
    }

    private static func access(for status: PHAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else { return nil }

        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

/// A single PhotoKit image manager is shared so scrolling back over recently
/// visible assets reuses decoded thumbnails instead of repeatedly expanding
/// the same photos in memory.
final class PhotoStudyImageManager {
    static let shared = PhotoStudyImageManager()
    private let manager = PHCachingImageManager()

    private init() {}

    func asset(with identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    @discardableResult
    func requestThumbnail(
        identifier: String,
        targetSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(with: identifier) else {
            completion(nil)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    @discardableResult
    func requestViewerImage(
        identifier: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (UIImage?, Bool, Error?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(with: identifier) else {
            completion(nil, false, PhotoStudyImageError.assetUnavailable)
            return nil
        }

        let maximumDimension: CGFloat = 5_120
        let sourceWidth = max(CGFloat(asset.pixelWidth), 1)
        let sourceHeight = max(CGFloat(asset.pixelHeight), 1)
        let scale = min(1, maximumDimension / max(sourceWidth, sourceHeight))
        let targetSize = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            DispatchQueue.main.async { progress(value) }
        }

        return manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            DispatchQueue.main.async {
                guard !cancelled else { return }
                completion(image, degraded, error)
            }
        }
    }

    @discardableResult
    func requestPlayerItem(
        identifier: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping (AVPlayerItem?, Error?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(with: identifier), asset.mediaType == .video else {
            completion(nil, PhotoStudyImageError.assetUnavailable)
            return nil
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            DispatchQueue.main.async { progress(value) }
        }
        return manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            DispatchQueue.main.async {
                guard !cancelled else { return }
                completion(item, error)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID?) {
        guard let requestID else { return }
        manager.cancelImageRequest(requestID)
    }
}

enum PhotoStudyImageError: LocalizedError {
    case assetUnavailable
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .assetUnavailable: "この資料は利用できません。"
        case .loadFailed: "資料を読み込めませんでした。"
        }
    }
}

struct PhotoStudyLibraryView: View {
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @StateObject private var model = PhotoStudyLibraryModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("写真資料", systemImage: "photo.stack")
                    .font(.headline)
                Spacer()
                if model.access == .limited {
                    Button("選択を管理") { model.manageLimitedAccess() }
                        .font(.subheadline)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("写真資料を閉じる")
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.regularMaterial)

            Divider()

            Group {
                switch model.access {
                case .notDetermined:
                    permissionRequest
                case .denied, .restricted:
                    permissionDenied
                case .authorized, .limited:
                    libraryGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.canvas)
        .onAppear { model.reloadIfAllowed() }
        .accessibilityIdentifier("photo-study-library")
    }

    private var permissionRequest: some View {
        ContentUnavailableView {
            Label("写真へのアクセス", systemImage: "photo.stack")
        } description: {
            Text("ノートを見ながら資料写真を表示するため、写真ライブラリへのアクセスを許可してください。")
        } actions: {
            Button("アクセスを許可") { model.requestAccess() }
                .buttonStyle(.themePrimary)
                .disabled(model.isLoading)
            if model.isLoading { ProgressView() }
        }
    }

    private var permissionDenied: some View {
        ContentUnavailableView {
            Label("写真を表示できません", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("設定でStudiquoに写真へのアクセスを許可してください。")
        } actions: {
            Button("設定を開く") { model.openSettings() }
                .buttonStyle(.themePrimary)
        }
    }

    private var libraryGrid: some View {
        GeometryReader { geometry in
            let columnCount = max(2, Int(geometry.size.width / 118))
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 3),
                count: columnCount
            )

            if model.assets.isEmpty {
                ContentUnavailableView(
                    "表示できる写真・動画がありません",
                    systemImage: "photo",
                    description: Text(model.access == .limited
                        ? "「選択を管理」から表示する写真を追加できます。"
                        : "写真ライブラリに写真や動画を追加すると、ここに表示されます。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.assets) { asset in
                            Button {
                                onSelect(asset.id)
                            } label: {
                                PhotoStudyThumbnailView(asset: asset)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: asset))
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func accessibilityLabel(for asset: PhotoStudyAsset) -> String {
        let base = asset.kind == .video
            ? "動画、長さ\(PhotoStudyDuration.string(from: asset.duration))"
            : "写真"
        guard let date = asset.creationDate else { return base }
        return "\(base)、\(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Square thumbnail cell. The base color fixes the square; the photo only
/// overlays it, so photo aspect ratios can never change the cell size.
struct PhotoStudySquareCell: View {
    let image: UIImage?

    var body: some View {
        Theme.Palette.canvas
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .clipped()
    }
}

private struct PhotoStudyThumbnailView: View {
    let asset: PhotoStudyAsset

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        PhotoStudySquareCell(image: image)
            .overlay(alignment: .bottomTrailing) {
                if asset.kind == .video {
                    Label(PhotoStudyDuration.string(from: asset.duration), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }
            }
        .onAppear(perform: load)
        .onDisappear {
            PhotoStudyImageManager.shared.cancel(requestID)
            requestID = nil
        }
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        let dimension = 180 * displayScale
        requestID = PhotoStudyImageManager.shared.requestThumbnail(
            identifier: asset.id,
            targetSize: CGSize(width: dimension, height: dimension)
        ) { loaded in
            image = loaded
        }
    }
}

/// Keeps lecture audio audible while the student writes notes next to it, and
/// hands the audio route back to other apps once the video is gone.
enum PhotoStudyAudioSession {
    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Owns the video player for one viewer. Every request carries a generation
/// number, and `stop()` bumps it, so a PhotoKit callback that was already queued
/// when the pane closed (or when the student tapped retry) is dropped instead
/// of starting playback nobody can stop.
@MainActor
final class PhotoStudyVideoPlayback: ObservableObject {
    typealias PlayerItemRequest = (
        _ identifier: String,
        _ progress: @escaping (Double) -> Void,
        _ completion: @escaping (AVPlayerItem?, Error?) -> Void
    ) -> PHImageRequestID?

    @Published private(set) var player: AVPlayer?
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?

    private let request: PlayerItemRequest
    private let cancelRequest: (PHImageRequestID?) -> Void
    private let activateAudio: () -> Void
    private let deactivateAudio: () -> Void
    private var requestID: PHImageRequestID?
    private var generation = 0

    init(
        request: @escaping PlayerItemRequest = { identifier, progress, completion in
            PhotoStudyImageManager.shared.requestPlayerItem(
                identifier: identifier, progress: progress, completion: completion
            )
        },
        cancelRequest: @escaping (PHImageRequestID?) -> Void = { PhotoStudyImageManager.shared.cancel($0) },
        activateAudio: @escaping () -> Void = PhotoStudyAudioSession.activateForPlayback,
        deactivateAudio: @escaping () -> Void = PhotoStudyAudioSession.deactivate
    ) {
        self.request = request
        self.cancelRequest = cancelRequest
        self.activateAudio = activateAudio
        self.deactivateAudio = deactivateAudio
    }

    func start(identifier: String) {
        stop()
        let token = generation
        requestID = request(
            identifier,
            { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.progress = value
                }
            },
            { [weak self] item, error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.finish(item: item, error: error)
                }
            }
        )
    }

    func stop() {
        generation += 1
        cancelRequest(requestID)
        requestID = nil
        progress = 0
        errorMessage = nil
        if let player {
            player.pause()
            player.replaceCurrentItem(with: nil)
            self.player = nil
            deactivateAudio()
        }
    }

    private func finish(item: AVPlayerItem?, error: Error?) {
        guard let item else {
            errorMessage = error?.localizedDescription
                ?? PhotoStudyImageError.loadFailed.localizedDescription
            return
        }
        activateAudio()
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        newPlayer.play()
    }
}

/// Displays the selected photo or video inside the Photo Study split pane.
/// Keeping the viewer here (instead of overlaying NoteEditorView) preserves the
/// other half of the screen for the notebook while the material is enlarged,
/// zoomed or played.
struct PhotoStudyPaneViewer: View {
    let assetIdentifier: String
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var requestID: PHImageRequestID?
    @StateObject private var playback = PhotoStudyVideoPlayback()

    private var isVideo: Bool {
        PhotoStudyImageManager.shared.asset(with: assetIdentifier)?.mediaType == .video
    }

    var body: some View {
        ZStack {
            Color.black

            if let image {
                ZoomableStudyPhoto(image: image)
            } else if let player = playback.player {
                StudyVideoPlayer(player: player)
            } else if let errorMessage = errorMessage ?? playback.errorMessage {
                ContentUnavailableView {
                    Label("資料を表示できません", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("再試行", action: load)
                        .buttonStyle(.themePrimary)
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 14) {
                    let shown = max(progress, playback.progress)
                    ProgressView(value: shown > 0 ? shown : nil)
                        .tint(.white)
                    Text("読み込み中…")
                        .foregroundStyle(.white)
                }
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Label("資料一覧に戻る", systemImage: "chevron.backward")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityIdentifier("photo-study-viewer")
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func load() {
        cancel()
        image = nil
        errorMessage = nil
        progress = 0
        if isVideo {
            loadVideo()
        } else {
            loadPhoto()
        }
    }

    private func loadPhoto() {
        requestID = PhotoStudyImageManager.shared.requestViewerImage(
            identifier: assetIdentifier,
            progress: { progress = $0 },
            completion: { loaded, degraded, error in
                if let loaded { image = loaded }
                if !degraded, loaded == nil {
                    errorMessage = error?.localizedDescription
                        ?? PhotoStudyImageError.loadFailed.localizedDescription
                }
            }
        )
    }

    private func loadVideo() {
        playback.start(identifier: assetIdentifier)
    }

    private func cancel() {
        PhotoStudyImageManager.shared.cancel(requestID)
        requestID = nil
        playback.stop()
    }
}

/// Native transport controls (scrub, skip, AirPlay) without any custom chrome.
/// It never enters full screen on its own, so playback stays inside its pane.
private struct StudyVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

private struct ZoomableStudyPhoto: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if scrollView.zoomScale == scrollView.minimumZoomScale {
            context.coordinator.imageView.frame = scrollView.bounds
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let horizontalInset = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let verticalInset = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        @objc func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let location = recognizer.location(in: imageView)
            let zoomScale = min(2.5, scrollView.maximumZoomScale)
            let width = scrollView.bounds.width / zoomScale
            let height = scrollView.bounds.height / zoomScale
            scrollView.zoom(
                to: CGRect(
                    x: location.x - width / 2,
                    y: location.y - height / 2,
                    width: width,
                    height: height
                ),
                animated: true
            )
        }
    }
}
