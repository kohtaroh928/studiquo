import Foundation
import Security
import SwiftData
import UIKit
import XCTest
@testable import studiquo

@MainActor
final class IOSSecurityAuditFixesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSSecurityAuditFixesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        NoteActionHistory.shared.clearAll()
        super.tearDown()
    }

    // MARK: - DOC-1 & LINK-1: DocumentBody SecureCoding & Link Sanitization

    func testDocumentBodySafeWebURLBlocksInternalAndDangerousSchemes() {
        XCTAssertNotNil(DocumentBody.safeWebURL(from: "https://example.com/path?q=1"))
        XCTAssertNotNil(DocumentBody.safeWebURL(from: "http://example.com"))
        XCTAssertEqual(
            DocumentBody.safeWebURL(from: "example.com/notes", requireExplicitScheme: false)?.absoluteString,
            "https://example.com/notes"
        )
        XCTAssertNil(DocumentBody.safeWebURL(from: "example.com/notes", requireExplicitScheme: true))

        for dangerous in [
            "studiquo://friend?code=ABCD2345",
            "studiquo://doc?invite=INV123",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "https://user:pass@example.com/secret",
            "https:///path-without-host",
            "",
            "   ",
        ] {
            XCTAssertNil(
                DocumentBody.safeWebURL(from: dangerous, requireExplicitScheme: false),
                "Expected dangerous URL to be rejected: \(dangerous)"
            )
            XCTAssertNil(
                DocumentBody.safeWebURL(from: dangerous, requireExplicitScheme: true),
                "Expected dangerous URL to be rejected: \(dangerous)"
            )
        }
    }

    func testDocumentBodyDecodeStripsDangerousLinksAndPreservesSafeLinks() {
        let mutable = NSMutableAttributedString(string: "Safe link and dangerous link")
        mutable.addAttribute(
            .link,
            value: URL(string: "https://example.com/study")!,
            range: NSRange(location: 0, length: 9)
        )
        mutable.addAttribute(
            .link,
            value: URL(string: "studiquo://friend?code=ATTACK99")!,
            range: NSRange(location: 14, length: 14)
        )

        let encoded = DocumentBody.encode(mutable)
        let decoded = DocumentBody.decode(encoded)

        XCTAssertEqual(
            decoded.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            URL(string: "https://example.com/study")!
        )
        XCTAssertNil(
            decoded.attribute(.link, at: 14, effectiveRange: nil),
            "studiquo:// custom scheme link must be stripped on decode"
        )
    }

    // MARK: - MATH-1: TeXParser Macro Expansion Bomb Protection

    func testMathTextFormatterBoundsExponentialMacroExpansion() {
        let bomb = """
        $\\def\\a{x+x+x+x+x+x+x+x}\\def\\b{\\a\\a\\a\\a\\a\\a\\a\\a}\\def\\c{\\b\\b\\b\\b\\b\\b\\b\\b}\\def\\d{\\c\\c\\c\\c\\c\\c\\c\\c}\\def\\e{\\d\\d\\d\\d\\d\\d\\d\\d}\\def\\f{\\e\\e\\e\\e\\e\\e\\e\\e}\\f$
        """
        let start = Date()
        let rendered = MathTextFormatter.readableText(from: bomb)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(rendered.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "Exponential TeX macro expansion must terminate quickly")
        XCTAssertLessThan(rendered.count, 100_000, "Output size must stay bounded")
    }

    // MARK: - LOCK-1, LOCK-2, LOCK-3, LOCK-4: Notebook Encryption & Lock Gate

    func testNotebookEncryptionSealsAndRestoresProofReviewFieldsAndMissingPages() throws {
        let service = "com.yabuko.studiquo.tests.enc.\(UUID().uuidString)"
        defer { NotebookEncryptionKeyStore.deleteKey(service: service) }

        let notebook = Notebook(title: "証明ノート")
        let page0 = NotePage(order: 0)
        page0.title = "問1"
        page0.recognizedText = "背理法により示す"
        page0.proofQuestion = "√2が無理数であることを示せ"
        page0.proofModelAnswer = "互いに素な整数p, qとおく"
        page0.proofRubricData = Data("{\"points\":10}".utf8)
        page0.proofReviewData = Data("{\"score\":9}".utf8)
        page0.notebook = notebook
        notebook.addPage(page0)

        let page1 = NotePage(order: 1)
        page1.title = "問2"
        page1.recognizedText = "数学的帰納法"
        page1.notebook = notebook
        notebook.addPage(page1)

        XCTAssertTrue(NotebookEncryptionService.lock(notebook, keyService: service))
        XCTAssertNotNil(notebook.encryptedContent)
        XCTAssertEqual(page0.proofQuestion, "")
        XCTAssertEqual(page0.proofModelAnswer, "")
        XCTAssertNil(page0.proofRubricData)
        XCTAssertNil(page0.proofReviewData)

        // Simulate a partial sync or accidental page deletion while sealed
        notebook.pages?.removeAll { $0.order == 1 }
        XCTAssertEqual(notebook.pages?.count, 1)

        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertNil(notebook.encryptedContent)
        XCTAssertEqual(notebook.sortedPages.count, 2, "Missing page must be recreated during unlock")
        XCTAssertEqual(notebook.sortedPages[0].proofQuestion, "√2が無理数であることを示せ")
        XCTAssertEqual(notebook.sortedPages[0].proofModelAnswer, "互いに素な整数p, qとおく")
        XCTAssertEqual(notebook.sortedPages[0].proofRubricData, Data("{\"points\":10}".utf8))
        XCTAssertEqual(notebook.sortedPages[0].proofReviewData, Data("{\"score\":9}".utf8))
        XCTAssertEqual(notebook.sortedPages[1].title, "問2")
        XCTAssertEqual(notebook.sortedPages[1].recognizedText, "数学的帰納法")
    }

    func testNotebookLockStateRequiresFaceIDWheneverNotebookIsSealed() {
        var state = NotebookLockState()
        _ = state.recordFaceID(success: true, decrypted: true)
        XCTAssertEqual(state.requirement(isLocked: true, hasLockedPDF: false, isSealed: false), .none)
        XCTAssertEqual(
            state.requirement(isLocked: true, hasLockedPDF: false, isSealed: true),
            .faceID,
            "Re-sealing a notebook in background must immediately require Face ID again"
        )
    }

    func testProtectedAndPasswordPDFNotebooksAreExcludedFromCatalogCoverAndExport() {
        let locked = Notebook(title: "ロックノート")
        locked.isLocked = true
        let page1 = NotePage(order: 0, backgroundImageData: Data([0x89, 0x50, 0x4E, 0x47]))
        page1.recognizedText = "秘密テキスト"
        page1.notebook = locked
        locked.addPage(page1)

        let passwordPDF = Notebook(title: "パスワードPDFノート")
        passwordPDF.lockedPDFData = Data("%PDF-1.7 encrypted".utf8)
        let page2 = NotePage(order: 0, backgroundImageData: Data([0x89, 0x50, 0x4E, 0x47]))
        page2.recognizedText = "パスワード保護テキスト"
        page2.notebook = passwordPDF
        passwordPDF.addPage(page2)

        let normal = Notebook(title: "公開ノート")
        let page3 = NotePage(order: 0)
        page3.recognizedText = "公開テキスト"
        page3.notebook = normal
        normal.addPage(page3)

        let options = AIAppAttachmentCatalog.options(
            notebooks: [locked, passwordPDF, normal],
            flashcardDecks: [],
            textDocuments: []
        )
        XCTAssertEqual(options.map(\.title), ["公開ノート"])
        locked.refreshLibraryMetadata()
        passwordPDF.refreshLibraryMetadata()
        XCTAssertFalse(NotebookCover.isEligible(locked))
        XCTAssertFalse(NotebookCover.isEligible(passwordPDF))
        XCTAssertNil(NotebookBackupService.export(locked))
        XCTAssertNil(NotebookBackupService.export(passwordPDF))
    }

    func testNoteActionHistorySkipsSealedNotebooksAndClearsAll() throws {
        let schema = Schema([Notebook.self, NotePage.self, PageElement.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let notebook = Notebook(title: "履歴テスト")
        let page = NotePage(order: 0)
        page.recognizedText = "秘密テキスト"
        page.notebook = notebook
        notebook.addPage(page)
        context.insert(notebook)
        context.insert(page)

        NotePageHistory.recordRemoval(of: [page], in: notebook, context: context)
        notebook.pages?.removeAll()
        context.delete(page)

        // Seal the notebook: undo must not restore plaintext pages into a sealed notebook
        notebook.encryptedContent = Data("ciphertext".utf8)
        _ = NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertTrue(notebook.sortedPages.isEmpty, "Undo must not restore plaintext pages into a sealed notebook")

        NoteActionHistory.shared.clearAll()
        notebook.encryptedContent = nil
        _ = NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertTrue(notebook.sortedPages.isEmpty, "clearAll() must wipe pending undo closures")
    }

    // MARK: - CHAT-1 & CHAT-2: FriendChatService Path & Attachment Validation

    func testFriendChatServiceValidatesPathSegmentsAndAttachmentPaths() throws {
        XCTAssertTrue(FriendChatService.isValidPathSegment("ABCD2345"))
        XCTAssertTrue(FriendChatService.isValidPathSegment("room_123-abc_456"))

        for invalid in ["", ".", "..", "../secret", "a/b", "a\\b", "id?admin=1", "id#frag", "id%2f..", "room.123"] {
            XCTAssertFalse(
                FriendChatService.isValidPathSegment(invalid),
                "Expected invalid path segment to be rejected: \(invalid)"
            )
        }

        let allowedRoot = tempDir.appendingPathComponent("FriendChatAttachments", isDirectory: true)
        let outsideRoot = tempDir.appendingPathComponent("OutsideSecrets", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let validFile = allowedRoot.appendingPathComponent("note.pdf")
        let secretFile = outsideRoot.appendingPathComponent("LibraryLedger.json")
        try Data("pdf".utf8).write(to: validFile)
        try Data("secret".utf8).write(to: secretFile)

        let symlinkInAllowed = allowedRoot.appendingPathComponent("symlink.pdf")
        try FileManager.default.createSymbolicLink(at: symlinkInAllowed, withDestinationURL: secretFile)

        XCTAssertNotNil(
            FriendChatService.safeLocalAttachmentURL(sourcePath: validFile.path, allowedRoots: [allowedRoot])
        )
        XCTAssertNil(
            FriendChatService.safeLocalAttachmentURL(sourcePath: secretFile.path, allowedRoots: [allowedRoot]),
            "Files outside FriendChatAttachments must be rejected"
        )
        XCTAssertNil(
            FriendChatService.safeLocalAttachmentURL(
                sourcePath: allowedRoot.appendingPathComponent("../OutsideSecrets/LibraryLedger.json").path,
                allowedRoots: [allowedRoot]
            ),
            "Parent directory traversal must be rejected"
        )
        XCTAssertNil(
            FriendChatService.safeLocalAttachmentURL(sourcePath: symlinkInAllowed.path, allowedRoots: [allowedRoot]),
            "Symlinks escaping FriendChatAttachments must be rejected"
        )

        XCTAssertNil(
            FriendChatService.safeCachedAttachmentDestination(
                directory: allowedRoot,
                sourceKind: "notebook",
                sourceID: "../passwd",
                title: "note.pdf"
            ),
            "Invalid sourceID containing traversal must be rejected"
        )

        let cachedDest = try XCTUnwrap(
            FriendChatService.safeCachedAttachmentDestination(
                directory: allowedRoot,
                sourceKind: "../../etc",
                sourceID: "valid_id_123",
                title: "../../secret.pdf"
            )
        )
        XCTAssertEqual(
            cachedDest.deletingLastPathComponent().standardizedFileURL.path,
            allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            "Cached attachment destination must never escape its directory"
        )
    }

    func testEvictedIncomingOrOutsideAttachmentCannotDeleteLocalFilesAndStrippingLocalSourcePathsRemovesRemoteSourcePath() throws {
        let allowedRoot = tempDir.appendingPathComponent("FriendChatAttachments", isDirectory: true)
        let outsideRoot = tempDir.appendingPathComponent("OutsideSecrets", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let victimInAllowed = allowedRoot.appendingPathComponent("victim-in-allowed.pdf")
        let victimOutside = outsideRoot.appendingPathComponent("LibraryLedger.json")
        let ownedInAllowed = allowedRoot.appendingPathComponent("owned-in-allowed.pdf")
        try Data("keep-allowed".utf8).write(to: victimInAllowed)
        try Data("keep-outside".utf8).write(to: victimOutside)
        try Data("delete-me".utf8).write(to: ownedInAllowed)

        let peerSpoofedAttachment = FriendMessageAttachment(
            id: "file-peer-1",
            title: "../../notes.pdf",
            kind: "PDF",
            icon: "doc.richtext",
            sourceKind: "pdf",
            sourceID: "remote_1",
            sourcePath: victimInAllowed.path,
            remoteRoomID: "room-a"
        )
        let sanitizedLine = FriendMessageAttachment.strippingLocalSourcePaths(in: "こんにちは\n\(peerSpoofedAttachment.messageLine)")
        let sanitizedAttachments = FriendMessageAttachment.attachments(in: sanitizedLine)
        XCTAssertEqual(sanitizedAttachments.count, 1)
        XCTAssertNil(sanitizedAttachments.first?.sourcePath, "Incoming attachment payload must have local sourcePath stripped")
        XCTAssertEqual(sanitizedAttachments.first?.sourceID, "remote_1")

        let friendID = UUID()
        let incomingMessage = FriendMessage(
            id: UUID(),
            friendID: friendID,
            text: peerSpoofedAttachment.messageLine,
            sentAt: Date(),
            isMine: false,
            isCanceled: false
        )
        let outsideMineAttachment = FriendMessageAttachment(
            id: "file-outside-1",
            title: "ledger",
            kind: "PDF",
            icon: "doc.richtext",
            sourceKind: "pdf",
            sourceID: "../LibraryLedger",
            sourcePath: victimOutside.path,
            remoteRoomID: "room-a"
        )
        let outsideMineMessage = FriendMessage(
            id: UUID(),
            friendID: friendID,
            text: outsideMineAttachment.messageLine,
            sentAt: Date(),
            isMine: true,
            isCanceled: false
        )
        let validMineAttachment = FriendMessageAttachment(
            id: "file-owned-1",
            title: "owned.pdf",
            kind: "PDF",
            icon: "doc.richtext",
            sourceKind: "pdf",
            sourceID: "valid_id_1",
            sourcePath: ownedInAllowed.path,
            remoteRoomID: "room-a"
        )
        let validMineMessage = FriendMessage(
            id: UUID(),
            friendID: friendID,
            text: validMineAttachment.messageLine,
            sentAt: Date(),
            isMine: true,
            isCanceled: false
        )

        FriendStore.deleteLocalAttachmentFilesNow(
            for: [incomingMessage, outsideMineMessage, validMineMessage],
            allowedRoots: [allowedRoot]
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victimInAllowed.path),
            "Evicting an incoming (!isMine) message must never delete a local file referenced by sourcePath"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victimOutside.path),
            "Evicting a message must never delete a file outside FriendChatAttachments"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ownedInAllowed.path),
            "Evicting an own message inside FriendChatAttachments should still clean up its attachment file"
        )
        XCTAssertEqual(FriendMessageAttachment.boundedFilename("../../etc/passwd"), "____etc_passwd")
    }

    // MARK: - AUTH-1, AUTH-2, ERASE-1: Identity Isolation & Account Erasure

    func testPersistOAuthIdentityDoesNotLeakEmailAcrossDifferentAccountsAndLogoutClearsIdentity() {
        let service = "com.yabuko.studiquo.tests.auth-isolation.\(UUID().uuidString)"
        let suiteName = "com.yabuko.studiquo.tests.auth-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for account in ["session", "passkey-identity", "oauth-identity"] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
            }
        }

        let store = AuthenticationStore(
            service: service,
            defaults: defaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            eraseBrowserData: {}
        )

        // Account A signs in with Apple and provides an email on first login
        store.persistOAuthIdentity(provider: "apple", subject: "apple-user-A", email: "userA@example.com")
        XCTAssertEqual(store.email, "userA@example.com")

        // Same Account A signs in again with Apple (subsequent Apple logins have email == nil)
        store.persistOAuthIdentity(provider: "apple", subject: "apple-user-A", email: nil)
        XCTAssertEqual(store.email, "userA@example.com", "Same Apple subject should keep its previously learned email")

        // Different Account B signs in with Apple with email == nil: must NOT inherit userA's email
        store.persistOAuthIdentity(provider: "apple", subject: "apple-user-B", email: nil)
        XCTAssertEqual(store.email, "", "Different Apple subject must never inherit previous account's email")

        // Seed email again and verify logout wipes identity from Keychain
        store.persistOAuthIdentity(provider: "email", subject: "userB@example.com", email: "userB@example.com")
        XCTAssertEqual(store.email, "userB@example.com")
        store.logout()
        XCTAssertEqual(store.email, "", "logout() must clear stored OAuth/Passkey identity")
    }

    func testLogoutResetsFriendStoreAndPreventsCrossAccountFriendChatAndProfileLeakage() {
        let service = "com.yabuko.studiquo.tests.friend-logout.\(UUID().uuidString)"
        let suiteName = "com.yabuko.studiquo.tests.friend-logout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for account in ["session", "passkey-identity", "oauth-identity"] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
            }
        }

        defaults.set("USERA1", forKey: "studiquoFriendCode")
        defaults.set("TOKENA1", forKey: "studiquoFriendLinkToken")
        defaults.set("アカウントA", forKey: "profileName")
        defaults.set("アカウントAの自己紹介", forKey: "profileBio")
        defaults.set(Data("avatar-a".utf8), forKey: "profileImage")

        let authStore = AuthenticationStore(
            service: service,
            defaults: defaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            eraseBrowserData: {}
        )
        let friendStore = FriendStore(defaults: defaults, autoRefresh: false)
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 120, roomID: "room-a", isDemo: false)
        friendStore.friends = [alice]
        friendStore.messages = [
            FriendMessage(id: UUID(), friendID: alice.id, text: "Aの秘密チャット", sentAt: Date(), isMine: true, isCanceled: false, serverID: 1, roomID: "room-a")
        ]
        friendStore.unreadCounts = [alice.id: 3]

        XCTAssertEqual(friendStore.friends.count, 1)
        XCTAssertEqual(friendStore.messages.count, 1)
        XCTAssertEqual(friendStore.myCode, "USERA1")

        authStore.logout()

        XCTAssertTrue(friendStore.friends.isEmpty, "logout() must clear active friends in FriendStore")
        XCTAssertTrue(friendStore.archivedFriends.isEmpty, "logout() must clear archived friends in FriendStore")
        XCTAssertTrue(friendStore.messages.isEmpty, "logout() must clear persisted 1:1 chat history in FriendStore")
        XCTAssertTrue(friendStore.unreadCounts.isEmpty, "logout() must clear unread counts in FriendStore")
        XCTAssertEqual(friendStore.myCode, "準備中", "logout() must reset myCode to placeholder")
        XCTAssertNil(defaults.string(forKey: "profileName"), "logout() must clear profileName so next account does not register previous user's name")
        XCTAssertNil(defaults.string(forKey: "profileBio"), "logout() must clear profileBio")
        XCTAssertNil(defaults.data(forKey: "profileImage"), "logout() must clear profileImage so next account does not upload previous user's avatar")

        let secondAccountStore = FriendStore(defaults: defaults, autoRefresh: false)
        XCTAssertTrue(secondAccountStore.friends.isEmpty)
        XCTAssertTrue(secondAccountStore.archivedFriends.isEmpty)
        XCTAssertTrue(secondAccountStore.messages.isEmpty)
    }

    func testAccountFileEraserRemovesLibraryLedgerAndBookmarkStoreClearAllRemovesFile() throws {
        let sandbox = tempDir.appendingPathComponent("sandbox", isDirectory: true)
        let ledgerURL = sandbox.appendingPathComponent("Library/Application Support/studiquo/LibraryLedger.json")
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":1}".utf8).write(to: ledgerURL)

        try AccountFileEraser.eraseOwnedFiles(in: sandbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path), "LibraryLedger.json must be erased on account deletion")

        let bookmarkFile = tempDir.appendingPathComponent("Bookmarks/ExternalFileBookmarks.json")
        let sourceFile = tempDir.appendingPathComponent("sample.pdf")
        try Data("pdf".utf8).write(to: sourceFile)
        let bookmarkStore = ExternalFileBookmarkStore(
            fileURL: bookmarkFile,
            bookmarking: ExternalFileBookmarking(
                makeBookmark: { Data($0.path.utf8) },
                resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }
            )
        )
        _ = bookmarkStore.add(url: sourceFile)
        XCTAssertEqual(bookmarkStore.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarkFile.path))

        bookmarkStore.clearAll()
        XCTAssertTrue(bookmarkStore.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmarkFile.path))
    }

    // MARK: - SHARE-1 & MCP-1: SharedInbox Symlink Rejection & DocxZip Ratio Check

    func testSharedInboxRejectsSymbolicLinks() throws {
        let inboxRoot = tempDir.appendingPathComponent("Inbox", isDirectory: true)
        let inbox = SharedInbox(root: inboxRoot)
        let batch = try XCTUnwrap(inbox.makeBatch())

        let outsideSecret = tempDir.appendingPathComponent("secret.pdf")
        try Data("secret".utf8).write(to: outsideSecret)
        let symlink = tempDir.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideSecret)

        XCTAssertNil(inbox.add(symlink, to: batch), "SharedInbox must refuse symbolic links")
        XCTAssertNotNil(inbox.add(outsideSecret, to: batch), "SharedInbox must still accept regular files")
    }

    func testDocxZipRejectsImpossibleCompressionRatioWithoutLargeAllocation() {
        let tinyCompressed = Data([0x03, 0x00])
        XCTAssertThrowsError(try DocxZip.inflate(tinyCompressed, expectedSize: 50_000_000))
    }
}
