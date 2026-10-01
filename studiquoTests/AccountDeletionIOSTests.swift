import Security
import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class AccountDeletionIOSTests: XCTestCase {
    private var defaultsName = ""
    private var defaults: UserDefaults!
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        defaultsName = "com.yabuko.studiquo.account-deletion-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        keychainService = "com.yabuko.studiquo.account-deletion-tests.\(UUID().uuidString)"
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

    private func makeStore(delete: @escaping () async throws -> Void = {}) -> AuthenticationStore {
        AuthenticationStore(
            service: keychainService,
            defaults: defaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            deleteAccountOnServer: delete
        )
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: studiquoSchema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: studiquoSchema, configurations: configuration)
    }

    func test57SettingsExposeTheAccountDeletionAction() {
        XCTAssertEqual(AccountDeletionUI.accountButtonTitle, "アカウントを削除")
    }

    func test58DeleteButtonRequiresTheExactConfirmationText() {
        for invalid in ["", "delete", "削 除", "削除 ", "完全に削除"] {
            XCTAssertFalse(AccountDeletionUI.canSubmit(confirmation: invalid, isBusy: false))
        }
        XCTAssertTrue(AccountDeletionUI.canSubmit(confirmation: "削除", isBusy: false))
        XCTAssertFalse(AccountDeletionUI.canSubmit(confirmation: "削除", isBusy: true))
    }

    func test59NetworkFailureDoesNotEraseLocalMaterials() async throws {
        enum Offline: Error { case unavailable }
        var erased = false
        let store = makeStore { throw Offline.unavailable }
        let result = await AccountDeletionWorkflow.run(
            authentication: store,
            eraseLocalData: { erased = true }
        )
        XCTAssertEqual(result, .serverFailure)
        XCTAssertFalse(erased)
    }

    func test60SuccessfulServerDeletionErasesEverySwiftDataModel() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        seedEveryModel(in: context)
        try context.save()

        let store = makeStore()
        let result = await AccountDeletionWorkflow.run(
            authentication: store,
            eraseLocalData: { try AccountDataEraser.eraseAll(from: context) },
            clearPreferences: {}
        )

        XCTAssertEqual(result, .success)
        try assertEveryModelIsEmpty(in: context)
    }

    func test61TrashContentsAreDeletedToo() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let notebook = Notebook(title: "ゴミ箱のノート")
        notebook.isTrashed = true
        notebook.trashedAt = .now
        let document = TextDocument(title: "ゴミ箱の文書")
        document.isTrashed = true
        document.trashedAt = .now
        let deck = FlashcardDeck(title: "ゴミ箱の暗記帳")
        deck.isTrashed = true
        deck.trashedAt = .now
        context.insert(notebook)
        context.insert(document)
        context.insert(deck)
        try context.save()

        try AccountDataEraser.eraseAll(from: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TextDocument>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FlashcardDeck>()).count, 0)
    }

    func test62ProfileChatCachesAndStudyPreferencesAreCleared() {
        let accountKeys = ["profileName", "profileOccupation", "profileBio", "profileImage", "friendShareStudyTime", "readStudyNotificationIDs", "studyTimeTrackingEnabled", "leftHandedMode", AIReviewService.isEnabledDefaultsKey]
        for key in accountKeys {
            defaults.set("stored", forKey: key)
        }
        AccountLocalPreferences.clear(defaults: defaults)
        for key in accountKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func test63OnlyLanguagePreferenceIsPreserved() {
        defaults.set("english", forKey: "appLanguage")
        defaults.set("Yamada", forKey: "profileName")
        defaults.set(false, forKey: "studyTimeTrackingEnabled")
        AccountLocalPreferences.clear(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "english")
        XCTAssertNil(defaults.object(forKey: "profileName"))
        XCTAssertNil(defaults.object(forKey: "studyTimeTrackingEnabled"))
        // The simulator process injects Apple/NS/XCTest defaults into every
        // suite. Verify only app-owned settings: language survives and the
        // account-owned keys do not.
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains("profileName"))
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains("studyTimeTrackingEnabled"))
    }

    func test64SessionIdentityAndCloudTokenAreRemovedFromKeychain() {
        KeychainCredentialFixtures.seedAllAccountCredentials(service: keychainService, email: "deleted@example.com")
        MCPCloudCredentials.save("1234567890.abcdefghijklmnopqrstuvwxyz123456")
        let store = makeStore()

        store.finishAccountDeletion()

        for account in ["session", "passkey-identity", "oauth-identity"] {
            XCTAssertFalse(KeychainCredentialFixtures.containsItem(service: keychainService, account: account), account)
        }
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    func test65SuccessfulDeletionReturnsToLoginState() {
        KeychainCredentialFixtures.seedSignedInDevice(service: keychainService, email: "deleted@example.com")
        let store = makeStore()
        XCTAssertNotEqual(store.state, .needsLogin)
        store.finishAccountDeletion()
        XCTAssertEqual(store.state, .needsLogin)
    }

    func test66DeletedMaterialsDoNotReturnAfterAStoreRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "account-deletion-\(UUID().uuidString).store")
        let container = try makeContainer(url: url)
        let context = ModelContext(container)
        context.insert(Notebook(title: "再起動後に戻ってはいけない"))
        try context.save()
        try AccountDataEraser.eraseAll(from: context)

        let relaunchedContext = ModelContext(container)
        XCTAssertEqual(try relaunchedContext.fetch(FetchDescriptor<Notebook>()).count, 0)
    }

    func test67SavedCloudBackedDeletionRemainsEmptyWhenObservedByAnotherContext() throws {
        let container = try makeContainer()
        let firstDeviceContext = ModelContext(container)
        firstDeviceContext.insert(Notebook(title: "CloudKit同期対象"))
        try firstDeviceContext.save()
        try AccountDataEraser.eraseAll(from: firstDeviceContext)

        let secondDeviceViewOfStore = ModelContext(container)
        XCTAssertEqual(try secondDeviceViewOfStore.fetch(FetchDescriptor<Notebook>()).count, 0)
    }

    func test68DeletionCannotDismissOrRunTwiceWhileInProgress() async {
        let gate = AsyncGate()
        let started = expectation(description: "server deletion started")
        let store = makeStore {
            started.fulfill()
            await gate.wait()
        }
        let first = Task { await store.requestAccountDeletion() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertTrue(store.isAccountDeletionBusy)
        XCTAssertFalse(AccountDeletionUI.canDismiss(isBusy: store.isAccountDeletionBusy))
        let duplicateResult = await store.requestAccountDeletion()
        XCTAssertFalse(duplicateResult)
        await gate.open()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
    }

    func test69LocalEraseFailureReturnsTheSpecificRecoveryMessage() async {
        enum LocalFailure: Error { case disk }
        var finishedPreferences = false
        let result = await AccountDeletionWorkflow.run(
            authentication: makeStore(),
            eraseLocalData: { throw LocalFailure.disk },
            clearPreferences: { finishedPreferences = true }
        )
        XCTAssertEqual(result, .localFailure(AccountDeletionUI.localEraseFailureMessage))
        XCTAssertFalse(finishedPreferences)
    }

    func test70SubscriptionManagementLinkTargetsTheAppStoreSubscriptionsPage() {
        let url = AccountDeletionUI.subscriptionManagementURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "apps.apple.com")
        XCTAssertEqual(url.path, "/account/subscriptions")
    }

    private func seedEveryModel(in context: ModelContext) {
        let notebook = Notebook(title: "note")
        let page = NotePage(order: 0)
        let pageElement = PageElement(kind: .text)
        let deck = FlashcardDeck(title: "cards")
        let card = Flashcard(question: "q", answer: "a", order: 0)
        let event = CalendarEvent(title: "event", startDate: .now, endDate: .now, kind: .other)
        let activity = StudyActivity(startedAt: .now, endedAt: .now, sourceTitle: "study")
        let thread = AIChatThread(title: "chat")
        let message = AIChatMessage(text: "message", role: .user)
        let document = TextDocument(title: "doc")
        let block = DocumentBlock(order: 0)
        let row = DocumentTableRow(order: 0)
        let cell = DocumentTableCell(order: 0)
        let header = DocumentHeaderFooter(kind: .header)
        let comment = DocumentComment(author: "a", text: "c", anchorBlock: block)
        let change = DocumentChangeRecord(author: "a", kind: .edit, previousText: "a", newText: "b", anchorBlock: block)
        let footnote = DocumentFootnote(text: "f", anchorBlock: block)
        let slideDeck = SlideDeck(title: "slides")
        let slide = Slide(order: 0)
        let master = SlideMaster()
        let layout = SlideLayoutTemplate(name: "layout", order: 0)
        let placeholder = SlidePlaceholder(role: .body, kind: .text, order: 0, centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.2)
        let slideElement = SlideElement(kind: .text)
        let review = AIReviewItem(questionText: "q", threadTitle: "t", createdAt: .now, reviewDate: .now, explanationMarkdown: "e", quiz: [])
        let folder = Folder(name: "folder")
        let receipt = MCPImportReceipt(id: "id", title: "title", kind: "document", source: "test")
        for model in [notebook, page, pageElement, deck, card, event, activity, thread, message, document, block, row, cell, header, comment, change, footnote, slideDeck, slide, master, layout, placeholder, slideElement, review, folder, receipt] as [any PersistentModel] {
            context.insert(model)
        }
    }

    private func assertEveryModelIsEmpty(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotePage>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PageElement>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FlashcardDeck>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Flashcard>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CalendarEvent>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StudyActivity>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIChatThread>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIChatMessage>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TextDocument>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentBlock>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentTableRow>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentTableCell>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentHeaderFooter>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentComment>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentChangeRecord>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentFootnote>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SlideDeck>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Slide>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SlideMaster>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SlideLayoutTemplate>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SlidePlaceholder>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SlideElement>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIReviewItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MCPImportReceipt>()).count, 0)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
