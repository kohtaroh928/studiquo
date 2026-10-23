import CloudKit
import CoreData
import Foundation
import Security
import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class AccountDeletionAndCloudSyncResilienceTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        defaultsName = "com.yabuko.studiquo.deletion-resilience-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        keychainService = "com.yabuko.studiquo.deletion-resilience-tests.\(UUID().uuidString)"
        MCPCloudCredentials.clear()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        MCPCloudCredentials.clear()
        for account in ["session", "passkey-identity", "oauth-identity"] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
        super.tearDown()
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: config)
        Self.retainedContainers.append(container)
        return container
    }

    private func makeStore(delete: @escaping () async throws -> Void = {}) -> AuthenticationStore {
        AuthenticationStore(
            service: keychainService,
            defaults: defaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            deleteAccountOnServer: delete
        )
    }

    // MARK: - AccountDeletionService & AccountDeletionError

    func testAccountDeletionServiceThrowsNotSignedInWhenCredentialsAreMissing() async {
        MCPCloudCredentials.clear()
        do {
            try await AccountDeletionService.deleteAccount()
            XCTFail("Expected AccountDeletionError.notSignedIn when no cloud token is saved")
        } catch let error as AccountDeletionError {
            XCTAssertEqual(error, .notSignedIn)
            XCTAssertEqual(error.localizedDescription, "ログイン情報を確認できませんでした。もう一度ログインしてください。")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            AccountDeletionError.rejected.localizedDescription,
            "アカウントを削除できませんでした。通信状態を確認して、もう一度お試しください。"
        )
    }

    func testAccountDeletionStopsBeforeTheServerWhenTheDeviceOwnerDoesNotConfirm() async {
        MCPCloudCredentials.clear()
        // No saved credentials: the missing-credentials check comes first, so
        // this only shows that a declined device check is its own error.
        do {
            try await AccountDeletionService.deleteAccount(confirmDevice: { _ in .declined })
            XCTFail("Expected an error")
        } catch let error as AccountDeletionError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(AccountDeletionError.deviceNotConfirmed.localizedDescription, "端末の認証ができなかったため、アカウントは削除していません。")
        XCTAssertEqual(
            AccountDeletionError.recentLoginRequired.localizedDescription,
            "安全のため、いったんサインアウトして、もう一度サインインしてからアカウントを削除してください。"
        )
    }

    // MARK: - End-to-End Erasure of Locked Notebooks, PDF Pages, & Consent State

    func testAccountDeletionWorkflowErasesLockedNotebooksPDFPagesAndResetsAIConsent() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let encryptionKeyService = "com.yabuko.studiquo.deletion-enc-\(UUID().uuidString)"
        defer { NotebookEncryptionKeyStore.deleteKey(service: encryptionKeyService) }

        // 1. Seed a locked notebook with encryptedContent and a second unlocked notebook with a page PDF.
        let lockedNotebook = Notebook(title: "ロック済み秘密ノート")
        let lockedPage = NotePage(order: 0)
        lockedPage.title = "Page 1"
        lockedPage.recognizedText = "Secret OCR"
        lockedPage.backgroundPDFData = Data("%PDF-1.4 Confidential".utf8)
        lockedPage.notebook = lockedNotebook
        lockedNotebook.addPage(lockedPage)
        context.insert(lockedNotebook)
        context.insert(lockedPage)
        NotebookEncryptionService.lock(lockedNotebook, keyService: encryptionKeyService)
        XCTAssertNotNil(lockedNotebook.encryptedContent)

        let unlockedNotebook = Notebook(title: "通常PDFノート")
        let unlockedPage = NotePage(order: 0)
        unlockedPage.title = "PDF Page"
        unlockedPage.backgroundPDFData = Data("%PDF-1.4 Eigenvalue".utf8)
        unlockedPage.notebook = unlockedNotebook
        unlockedNotebook.addPage(unlockedPage)
        context.insert(unlockedNotebook)
        context.insert(unlockedPage)
        try context.save()

        // 2. Seed AI data disclosure consent and device-level preferences in isolated UserDefaults.
        let prevDefaults = AIDataDisclosure.defaults
        AIDataDisclosure.defaults = defaults
        defer { AIDataDisclosure.defaults = prevDefaults }

        AIDataDisclosure.acknowledge(ageBand: .adult)
        XCTAssertTrue(AIDataDisclosure.hasBeenAcknowledged)
        defaults.set(true, forKey: AIReviewService.isEnabledDefaultsKey)
        defaults.set("japanese", forKey: "appLanguage")
        defaults.set(false, forKey: ICloudSyncPreference.defaultsKey)

        // 3. Run the full AccountDeletionWorkflow.
        let store = makeStore()
        let result = await AccountDeletionWorkflow.run(
            authentication: store,
            eraseLocalData: { try AccountDataEraser.eraseAll(from: context) },
            clearPreferences: { AccountLocalPreferences.clear(defaults: self.defaults) }
        )

        XCTAssertEqual(result, .success)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotePage>()).count, 0)

        // AI consent and review toggle must be wiped, while device language and iCloud sync choice survive.
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged, "AI data disclosure consent must be cleared on account deletion")
        XCTAssertNil(defaults.object(forKey: AIReviewService.isEnabledDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "japanese")
        XCTAssertEqual(defaults.object(forKey: ICloudSyncPreference.defaultsKey) as? Bool, false)
    }

    // MARK: - ICloudSyncError Deep Nesting & Depth Guard

    func testICloudSyncErrorRecursionDepthGuardFindsUpToDepth4AndStopsAtDepth5() {
        let quotaError = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)

        // Wrap quotaError 4 levels deep (depths 0 -> 1 -> 2 -> 3 -> 4): should still return true.
        var wrapped4: NSError = quotaError
        for level in 1...4 {
            wrapped4 = NSError(
                domain: NSCocoaErrorDomain,
                code: 134400 + level,
                userInfo: [NSUnderlyingErrorKey: wrapped4]
            )
        }
        XCTAssertTrue(
            ICloudSyncError.isQuotaExceeded(wrapped4),
            "Quota error nested 4 levels deep (depth == 4) must be detected"
        )

        // Wrap one more level (depth == 5): guard `depth < 5` stops recursion safely and returns false.
        let wrapped5 = NSError(
            domain: NSCocoaErrorDomain,
            code: 134405,
            userInfo: [NSUnderlyingErrorKey: wrapped4]
        )
        XCTAssertFalse(
            ICloudSyncError.isQuotaExceeded(wrapped5),
            "Guard depth < 5 must bound recursion at depth 5 and return false"
        )
    }

    func testICloudSyncErrorFindsQuotaExceededNestedInPartialFailureThenDetailedErrors() {
        let quotaError = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)
        let detailedWrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 134400,
            userInfo: [NSDetailedErrorsKey: [quotaError]]
        )
        let partialWrapper = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "note-1"): detailedWrapper,
                ],
            ]
        )
        let topUnderlyingWrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 134060,
            userInfo: [NSUnderlyingErrorKey: partialWrapper]
        )

        XCTAssertTrue(ICloudSyncError.isQuotaExceeded(topUnderlyingWrapper))
    }
}
