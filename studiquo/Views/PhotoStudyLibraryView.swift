import SwiftUI
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

struct PhotoStudyAsset: Identifiable, Equatable {
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
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
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var updated: [PhotoStudyAsset] = []
        updated.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            updated.append(
                PhotoStudyAsset(
                    id: asset.localIdentifier,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate
                )
            )
        }
        assets = updated
    }

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
        case .assetUnavailable: "この写真は利用できません。"
        case .loadFailed: "写真を読み込めませんでした。"
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
        .background(Color(uiColor: .systemBackground))
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
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
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
                    "表示できる写真がありません",
                    systemImage: "photo",
                    description: Text(model.access == .limited
                        ? "「選択を管理」から表示する写真を追加できます。"
                        : "写真ライブラリに写真を追加すると、ここに表示されます。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.assets) { asset in
                            Button {
                                onSelect(asset.id)
                            } label: {
                                PhotoStudyThumbnailView(asset: asset)
                                    .aspectRatio(1, contentMode: .fit)
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
        guard let date = asset.creationDate else { return "写真" }
        return "写真、\(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct PhotoStudyThumbnailView: View {
    let asset: PhotoStudyAsset

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipped()
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

/// Displays the selected photo inside the Photo Study split pane. Keeping the
/// viewer here (instead of overlaying NoteEditorView) preserves the other half
/// of the screen for the notebook while the photo is enlarged and zoomed.
struct PhotoStudyPaneViewer: View {
    let assetIdentifier: String
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.black

            if let image {
                ZoomableStudyPhoto(image: image)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("写真を表示できません", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("再試行", action: load)
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 14) {
                    ProgressView(value: progress > 0 ? progress : nil)
                        .tint(.white)
                    Text("写真を読み込み中…")
                        .foregroundStyle(.white)
                }
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Label("写真一覧に戻る", systemImage: "chevron.backward")
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

    private func cancel() {
        PhotoStudyImageManager.shared.cancel(requestID)
        requestID = nil
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
