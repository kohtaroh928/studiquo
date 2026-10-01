import Foundation
import SwiftData

/// Approximates the "personal cloud sync" capacity Plus/Pro advertise.
///
/// CloudKit sync here goes device-to-Apple directly — the app never sees a
/// server-reported usage figure, and there is no public API to ask iCloud
/// "how much does this app's container actually use." The only number this
/// app can compute itself is the sum of the `Data` it writes into every
/// `.externalStorage` field across the whole SwiftData schema, which is a
/// reasonable stand-in: those fields (ink, page/slide images, document
/// bodies, marking results, quiz data) are exactly what CloudKit is
/// uploading on this app's behalf.
enum StorageUsageEstimator {
    // MARK: Plan limits

    /// Not a committed product figure — Standard has no advertised cloud
    /// quota at all today. This exists purely as an internal safety net so a
    /// free account can't grow its CloudKit footprint without bound; raise
    /// or remove it once product settles on a real number.
    static let standardPlanLimitBytes = 500 * 1024 * 1024
    static let plusPlanLimitBytes = 5 * 1024 * 1024 * 1024
    static let proPlanLimitBytes = 50 * 1024 * 1024 * 1024

    static func limitBytes(for plan: StudiquoPlan) -> Int {
        switch plan {
        case .standard: standardPlanLimitBytes
        case .plus: plusPlanLimitBytes
        case .pro: proPlanLimitBytes
        }
    }

    // MARK: Full scan

    /// Sums every `.externalStorage` `Data` field across the whole schema,
    /// by actually fetching every instance of every model that has one.
    ///
    /// This is expensive — `.externalStorage` keeps large blobs out of the
    /// main SQLite row, but reading `.count` on each one still means SwiftData
    /// loads the blob itself, and this fetches *every* `Notebook`, `NotePage`,
    /// `PageElement`, document block, slide, and review item in the whole
    /// library. Call it only to (re)seed `StorageUsageCache`, never on a hot
    /// path like every keystroke or every autosave — callers that need an
    /// up-to-date running total after that should prefer
    /// `StorageUsageCache.adjust(by:)` with a known delta instead of calling
    /// this again.
    @MainActor
    static func totalBytes(in context: ModelContext) throws -> Int {
        var total = 0
        total += try sumExternalStorage(Notebook.self, in: context) { [$0.encryptedContent] }
        total += try sumExternalStorage(NotePage.self, in: context) { [$0.drawingData, $0.backgroundImageData, $0.proofReviewData] }
        total += try sumExternalStorage(PageElement.self, in: context) { [$0.imageData] }
        total += try sumExternalStorage(TextDocument.self, in: context) { [$0.bodyData] }
        total += try sumExternalStorage(DocumentBlock.self, in: context) { [$0.bodyData] }
        total += try sumExternalStorage(DocumentTableCell.self, in: context) { [$0.bodyData] }
        total += try sumExternalStorage(DocumentHeaderFooter.self, in: context) { [$0.bodyData] }
        total += try sumExternalStorage(Slide.self, in: context) { [$0.imageData] }
        total += try sumExternalStorage(SlideElement.self, in: context) { [$0.bodyData, $0.imageData] }
        total += try sumExternalStorage(AIReviewItem.self, in: context) { [$0.quizData] }
        return total
    }

    private static func sumExternalStorage<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext, fields: (T) -> [Data?]
    ) throws -> Int {
        try context.fetch(FetchDescriptor<T>()).reduce(0) { total, model in
            total + fields(model).reduce(0) { $0 + ($1?.count ?? 0) }
        }
    }

    // MARK: Pure arithmetic

    /// No SwiftData required — exercised directly by unit tests, and used by
    /// `StorageUsageCache` once it already has a total in hand.
    static func wouldExceedLimit(currentTotalBytes: Int, additionalBytes: Int, plan: StudiquoPlan) -> Bool {
        currentTotalBytes + additionalBytes > limitBytes(for: plan)
    }
}

/// Keeps a running total in memory so enforcement checks (before writing a
/// new image/PDF/document blob) don't pay for a full `totalBytes(in:)` scan
/// on every single save — the same "cache the expensive count, update it
/// incrementally" shape `Notebook.refreshLibraryMetadata()` uses for
/// `cachedPageCount`, just scoped to the whole library instead of one
/// notebook.
///
/// A process-lifetime cache, not persisted to disk: an app relaunch pays for
/// one fresh scan (on the first enforcement check after launch), which is an
/// acceptable cost next to how rarely a user adds enough content to matter,
/// and avoids the complexity of keeping a persisted counter from drifting
/// out of sync with the data it's counting (e.g. after an iCloud-synced
/// delete from another device).
@MainActor
final class StorageUsageCache: ObservableObject {
    static let shared = StorageUsageCache()

    @Published private(set) var cachedTotalBytes: Int?

    private init() {}

    /// Forces a full rescan — used to seed the cache, or to recover from a
    /// `nil`/stale value. Expensive; see `StorageUsageEstimator.totalBytes`'s
    /// doc comment.
    func refresh(in context: ModelContext) {
        cachedTotalBytes = try? StorageUsageEstimator.totalBytes(in: context)
    }

    /// Adjusts the cached total by a known delta instead of rescanning —
    /// call right after a save that added (positive) or removed (negative)
    /// externally-stored content, once the save has actually succeeded.
    /// A no-op while the cache hasn't been seeded yet; the next check seeds
    /// it with a real scan instead of guessing from zero.
    func adjust(by delta: Int) {
        guard let current = cachedTotalBytes else { return }
        cachedTotalBytes = max(0, current + delta)
    }

    /// Whether writing `addingBytes` more would push this account over
    /// `plan`'s limit. Seeds the cache with a full scan the first time this
    /// is called in a given app session; every call after that reuses the
    /// cached total, adjusted incrementally by `adjust(by:)`.
    func wouldExceedLimit(addingBytes: Int, plan: StudiquoPlan, in context: ModelContext) -> Bool {
        if cachedTotalBytes == nil { refresh(in: context) }
        let current = cachedTotalBytes ?? 0
        return StorageUsageEstimator.wouldExceedLimit(currentTotalBytes: current, additionalBytes: addingBytes, plan: plan)
    }

    /// Clears the cached total — this is a process-wide singleton, so tests
    /// that exercise `wouldExceedLimit`/`refresh` need a way to undo
    /// whatever an earlier test left cached before asserting on a fresh
    /// scan.
    func resetForTesting() {
        cachedTotalBytes = nil
    }
}
