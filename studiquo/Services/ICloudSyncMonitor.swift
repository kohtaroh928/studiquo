import CloudKit
import CoreData
import Foundation

enum ICloudSyncError {
    /// Whether `error` means the student's iCloud storage is full.
    ///
    /// Core Data wraps CloudKit failures: a full account usually arrives as a
    /// partial failure whose per-record errors, or an underlying error, carry
    /// the real `quotaExceeded`. So this looks inside, not just at the top.
    static func isQuotaExceeded(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain, nsError.code == CKError.Code.quotaExceeded.rawValue { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isQuotaExceeded(underlying, depth: depth + 1) { return true }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           partial.values.contains(where: { isQuotaExceeded($0, depth: depth + 1) }) { return true }
        if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [Error],
           detailed.contains(where: { isQuotaExceeded($0, depth: depth + 1) }) { return true }
        return false
    }
}

/// Tells the UI when iCloud is full.
///
/// A full iCloud is not an app failure: notes keep saving on this device and
/// CloudKit retries by itself, so uploads resume once space is freed. What the
/// student needs is to be told why new notes are not reaching their other
/// devices, and a way to stop the retries.
@MainActor
final class ICloudSyncMonitor: ObservableObject {
    static let shared = ICloudSyncMonitor()

    @Published private(set) var isQuotaExceeded = false
    /// The banner was closed for the current "full" episode.
    @Published private(set) var isBannerDismissed = false

    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        self.center = center
        observer = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event, event.endDate != nil else { return }
            let isExport = event.type == .export
            let error = event.error
            Task { @MainActor in self?.record(isExport: isExport, error: error) }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// A finished sync event. A successful upload means there is room again.
    func record(isExport: Bool, error: Error?) {
        if let error {
            if ICloudSyncError.isQuotaExceeded(error), !isQuotaExceeded { isQuotaExceeded = true }
        } else if isExport, isQuotaExceeded {
            isQuotaExceeded = false
            isBannerDismissed = false
        }
    }

    func dismissBanner() { isBannerDismissed = true }
}
