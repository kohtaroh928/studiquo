import XCTest
import CloudKit
import CoreData
import SwiftData
@testable import studiquo

final class ICloudSyncPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ICloudSyncPreferenceTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNewInstallStartsWithSyncOff() {
        XCTAssertFalse(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: false))
    }

    func testExistingLibraryKeepsItsSync() {
        XCTAssertTrue(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: true))
    }

    func testFirstDecisionIsRememberedEvenOnceAStoreAppears() {
        // A new install creates its store file during this very launch; the
        // next launch must not mistake it for a pre-existing library.
        XCTAssertFalse(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: false))
        XCTAssertFalse(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: true))
    }

    func testAnExplicitChoiceAlwaysWins() {
        ICloudSyncPreference.setEnabled(false, defaults: defaults)
        XCTAssertFalse(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: true))
        ICloudSyncPreference.setEnabled(true, defaults: defaults)
        XCTAssertTrue(ICloudSyncPreference.resolve(defaults: defaults, existingStoreFound: false))
    }
}

final class ICloudSyncErrorTests: XCTestCase {
    private func ckError(_ code: CKError.Code) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue)
    }

    func testQuotaExceededIsRecognised() {
        XCTAssertTrue(ICloudSyncError.isQuotaExceeded(ckError(.quotaExceeded)))
    }

    func testOtherCloudKitErrorsAreNot() {
        XCTAssertFalse(ICloudSyncError.isQuotaExceeded(ckError(.networkUnavailable)))
        XCTAssertFalse(ICloudSyncError.isQuotaExceeded(ckError(.notAuthenticated)))
        XCTAssertFalse(ICloudSyncError.isQuotaExceeded(NSError(domain: NSCocoaErrorDomain, code: 25)))
    }

    func testQuotaInsideAPartialFailureIsFound() {
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "a"): ckError(.quotaExceeded)]
        ])
        XCTAssertTrue(ICloudSyncError.isQuotaExceeded(partial))
    }

    func testQuotaBehindAnUnderlyingErrorIsFound() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [NSUnderlyingErrorKey: ckError(.quotaExceeded)])
        XCTAssertTrue(ICloudSyncError.isQuotaExceeded(wrapped))
    }

    func testQuotaInsideDetailedErrorsIsFound() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [NSDetailedErrorsKey: [ckError(.quotaExceeded)]])
        XCTAssertTrue(ICloudSyncError.isQuotaExceeded(wrapped))
    }

    func testPartialFailureWithoutQuotaIsNot() {
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "a"): ckError(.serverRecordChanged)]
        ])
        XCTAssertFalse(ICloudSyncError.isQuotaExceeded(partial))
    }

    func testAFullAccountIsNotReportedAsAnAppProblem() {
        XCTAssertFalse(CloudKitErrorReporting.shouldReport(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue))
    }
}

@MainActor
final class ICloudSyncMonitorTests: XCTestCase {
    private let full = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)

    func testQuotaErrorRaisesTheFlag() {
        let monitor = ICloudSyncMonitor(center: NotificationCenter())
        XCTAssertFalse(monitor.isQuotaExceeded)
        monitor.record(isExport: true, error: full)
        XCTAssertTrue(monitor.isQuotaExceeded)
    }

    func testOtherErrorsDoNotRaiseIt() {
        let monitor = ICloudSyncMonitor(center: NotificationCenter())
        monitor.record(isExport: true, error: NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue))
        XCTAssertFalse(monitor.isQuotaExceeded)
    }

    func testASuccessfulUploadClearsItAndReopensTheBanner() {
        let monitor = ICloudSyncMonitor(center: NotificationCenter())
        monitor.record(isExport: true, error: full)
        monitor.dismissBanner()
        XCTAssertTrue(monitor.isBannerDismissed)

        monitor.record(isExport: true, error: nil)
        XCTAssertFalse(monitor.isQuotaExceeded)
        XCTAssertFalse(monitor.isBannerDismissed, "a later full episode should tell the student again")
    }

    func testADownloadSucceedingProvesNothingAboutRoomToUpload() {
        let monitor = ICloudSyncMonitor(center: NotificationCenter())
        monitor.record(isExport: true, error: full)
        monitor.record(isExport: false, error: nil)
        XCTAssertTrue(monitor.isQuotaExceeded)
    }

    func testRepeatedFullErrorsKeepADismissedBannerClosed() {
        let monitor = ICloudSyncMonitor(center: NotificationCenter())
        monitor.record(isExport: true, error: full)
        monitor.dismissBanner()
        monitor.record(isExport: true, error: full)
        XCTAssertTrue(monitor.isBannerDismissed)
    }
}

/// Switching sync on or off reopens the same store file with a different
/// CloudKit setting. A library that already exists must come through intact.
@MainActor
final class ICloudSyncStoreSwitchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudSyncStoreSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(sync: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: studiquoSchema,
            url: folder.appendingPathComponent("library.store"),
            cloudKitDatabase: sync ? .automatic : .none
        )
        return try ModelContainer(for: studiquoSchema, configurations: configuration)
    }

    private func titles(in container: ModelContainer) throws -> [String] {
        try container.mainContext.fetch(FetchDescriptor<Notebook>()).map(\.title).sorted()
    }

    func testTurningSyncOnKeepsTheExistingLibrary() throws {
        do {
            let local = try open(sync: false)
            local.mainContext.insert(Notebook(title: "授業ノート"))
            try local.mainContext.save()
        }
        let synced = try open(sync: true)
        XCTAssertEqual(try titles(in: synced), ["授業ノート"])
    }

    func testTurningSyncOffKeepsTheExistingLibrary() throws {
        do {
            let synced = try open(sync: true)
            synced.mainContext.insert(Notebook(title: "同期していたノート"))
            try synced.mainContext.save()
        }
        let local = try open(sync: false)
        XCTAssertEqual(try titles(in: local), ["同期していたノート"])
    }

    func testNotesWrittenWhileOffSurviveTurningSyncBackOn() throws {
        do {
            let synced = try open(sync: true)
            synced.mainContext.insert(Notebook(title: "前から"))
            try synced.mainContext.save()
        }
        do {
            let local = try open(sync: false)
            local.mainContext.insert(Notebook(title: "オフの間に作成"))
            try local.mainContext.save()
        }
        let again = try open(sync: true)
        XCTAssertEqual(try titles(in: again), ["オフの間に作成", "前から"])
    }
}
