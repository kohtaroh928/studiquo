import Foundation
import CryptoKit
import Security

/// Where a locked notebook's encryption key lives.
///
/// Synced via iCloud Keychain (`kSecAttrSynchronizable`) rather than kept
/// device-only, so a locked notebook opens on every device signed into the
/// same Apple ID, not just the one it was locked on. That rules out pairing
/// this key with a biometry-specific access control (`.biometryCurrentSet`
/// and friends are documented as incompatible with synchronizable items —
/// they tie the item to this device's current biometric enrollment, which
/// makes no sense for something meant to sync). The actual Face ID/passcode
/// gate is enforced procedurally instead, by `ProtectedNotebookView` and the
/// 保護 toggle: this key is retrievable by anything that can read the
/// signed-in user's iCloud Keychain, but nothing in this app calls
/// `unlock(_:)` without a device-owner authentication having just succeeded.
enum NotebookEncryptionKeyStore {
    /// Internal (not `private`) so tests can pass a unique service string
    /// into `NotebookEncryptionService.lock`/`unlock` instead of touching
    /// this same key the real app uses.
    static let defaultService = "com.yabuko.studiquo.notebook-encryption"
    private static let account = "content-key"

    static func loadOrCreateKey(service: String = defaultService) -> SymmetricKey {
        if let existing = load(service: service) { return existing }
        let created = SymmetricKey(size: .bits256)
        save(created, service: service)
        return created
    }

    /// Test-only: removes the key so a test doesn't leak Keychain state
    /// into the next one (or into the real app's own key, if a test ever
    /// forgot to pass a unique `service`).
    static func deleteKey(service: String = defaultService) {
        SecItemDelete(query(service: service) as CFDictionary)
    }

    private static func load(service: String) -> SymmetricKey? {
        var attributes = query(service: service)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func save(_ key: SymmetricKey, service: String) {
        let base = query(service: service)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Must be a non-"ThisDeviceOnly" accessibility class — only those
        // are eligible to sync via iCloud Keychain at all.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]
    }
}

/// Encrypts a locked notebook's content at rest, and decrypts it back for
/// viewing.
///
/// `Notebook.isLocked` is the student's standing preference ("keep this
/// protected"); `Notebook.encryptedContent` is the moment-to-moment state of
/// whether the content is presently sealed or live. The two are kept
/// separate on purpose: `lock(_:)` runs both the first time a notebook is
/// protected (from the library's 保護 toggle) *and* every time a protected
/// notebook is put away after being viewed (`NoteEditorView`'s existing
/// background/disappear hooks, alongside `NotebookBackupService`) — after
/// which `isLocked` stays `true` but the live page/element fields are wiped.
/// `unlock(_:)` is the mirror: called after `ProtectedNotebookView`'s Face
/// ID/passcode check succeeds (to actually show the notebook), and when the
/// student removes protection entirely (after the same check, closing what
/// used to be an unauthenticated "turn the lock off" action).
enum NotebookEncryptionService {
    /// Content worth actually protecting — drawn ink, images, recognized
    /// text, and anything a student typed. Deliberately not layout fields
    /// (position, color, page size) or the proof-marking cache, matching
    /// what `NotebookBackupService`'s own archive already treats as a
    /// notebook's real content rather than its formatting.
    private struct EncryptedContent: Codable {
        struct Page: Codable {
            var drawingData: Data?
            var backgroundImageData: Data?
            var title: String
            var recognizedText: String
            var flashcardQuestion: String
            var flashcardAnswer: String
            var elements: [Element]
        }
        /// Elements aren't kept in a guaranteed stable array order (see
        /// `NotePage.allElements`), so they're matched back up by
        /// `layerIndex` on unlock rather than by position.
        struct Element: Codable {
            var layerIndex: Double
            var text: String
            var imageData: Data?
        }
        var pages: [Page]
    }

    /// Seals every page/element's content into `notebook.encryptedContent`
    /// and clears the live fields. A no-op if there's nothing to protect
    /// (encryption already failed or already sealed) — silent, like
    /// `NotebookBackupService`'s own best-effort writes, since there's no
    /// good way to surface a Keychain failure from a background/disappear
    /// hook.
    static func lock(_ notebook: Notebook, keyService: String = NotebookEncryptionKeyStore.defaultService) {
        let pages = notebook.sortedPages
        let content = EncryptedContent(pages: pages.map { page in
            EncryptedContent.Page(
                drawingData: page.drawingData,
                backgroundImageData: page.backgroundImageData,
                title: page.title,
                recognizedText: page.recognizedText,
                flashcardQuestion: page.flashcardQuestion,
                flashcardAnswer: page.flashcardAnswer,
                elements: page.allElements.map {
                    EncryptedContent.Element(layerIndex: $0.layerIndex, text: $0.text, imageData: $0.imageData)
                }
            )
        })
        guard let plainData = try? JSONEncoder().encode(content),
              let sealed = try? AES.GCM.seal(plainData, using: NotebookEncryptionKeyStore.loadOrCreateKey(service: keyService)),
              let combined = sealed.combined else { return }

        notebook.encryptedContent = combined
        for page in pages {
            page.drawingData = nil
            page.backgroundImageData = nil
            page.title = ""
            page.recognizedText = ""
            page.flashcardQuestion = ""
            page.flashcardAnswer = ""
            for element in page.allElements {
                element.text = ""
                element.imageData = nil
            }
        }
    }

    /// Restores the live fields from `notebook.encryptedContent` and clears
    /// it. Returns `true` when the notebook is now viewable (including the
    /// trivial case where it was never sealed to begin with); `false` when
    /// decryption failed and the notebook stays sealed — a wrong/missing
    /// key or corrupted data, not something the student can fix by retrying
    /// the same Face ID prompt.
    @discardableResult
    static func unlock(_ notebook: Notebook, keyService: String = NotebookEncryptionKeyStore.defaultService) -> Bool {
        guard let encrypted = notebook.encryptedContent else { return true }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encrypted),
              let plainData = try? AES.GCM.open(sealedBox, using: NotebookEncryptionKeyStore.loadOrCreateKey(service: keyService)),
              let content = try? JSONDecoder().decode(EncryptedContent.self, from: plainData)
        else { return false }

        let pages = notebook.sortedPages
        guard pages.count == content.pages.count else { return false }
        for (page, pageContent) in zip(pages, content.pages) {
            page.drawingData = pageContent.drawingData
            page.backgroundImageData = pageContent.backgroundImageData
            page.title = pageContent.title
            page.recognizedText = pageContent.recognizedText
            page.flashcardQuestion = pageContent.flashcardQuestion
            page.flashcardAnswer = pageContent.flashcardAnswer
            let elements = page.allElements
            for elementContent in pageContent.elements {
                guard let element = elements.first(where: { $0.layerIndex == elementContent.layerIndex }) else { continue }
                element.text = elementContent.text
                element.imageData = elementContent.imageData
            }
        }
        notebook.encryptedContent = nil
        return true
    }
}
