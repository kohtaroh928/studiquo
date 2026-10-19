import Foundation
import CryptoKit
import Security

/// Where a locked notebook's encryption keys live.
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
///
/// **A key is never replaced.** The notebook (sealed, in CloudKit) can reach a
/// new device before the key reaches its Keychain. Creating "the" key there, as
/// one fixed Keychain item, would sync out and overwrite the real one on every
/// device, and every locked notebook would become unreadable for good. So:
/// - every key is its own Keychain item, named by a random id, and a key is only
///   ever *added*, never deleted or overwritten;
/// - a sealed blob records the id of the key that sealed it (`SealedBlob`), so
///   opening it asks for exactly that key, and a key that has not arrived yet is
///   a failure to try again later, not a reason to make a new one;
/// - a key is created only to seal, and only when this device has no key at all.
///   Two devices that each create one before syncing simply end up holding both.
/// Blobs sealed before this (no id) use the one original item, `legacyAccount`,
/// which is read but never written.
enum NotebookEncryptionKeyStore {
    /// Internal (not `private`) so tests can pass a unique service string
    /// into `NotebookEncryptionService.lock`/`unlock` instead of touching
    /// this same key the real app uses.
    static let defaultService = "com.yabuko.studiquo.notebook-encryption"
    private static let legacyAccount = "content-key"
    private static let accountPrefix = "content-key-"

    struct StoredKey {
        /// nil for the original, id-less key.
        let id: String?
        let key: SymmetricKey
        let created: Date
    }

    /// The key a sealed blob names (`nil` = the original one), or nil when this
    /// device does not have it (yet).
    static func key(withID id: String?, service: String = defaultService) -> SymmetricKey? {
        lookup(service: service)?.first { $0.id == id }?.key
    }

    /// The key to seal new content with: the newest one this device holds, or a
    /// new one when it holds none. nil only if the Keychain refuses to store it.
    /// nil as well when the Keychain cannot be read right now (the device was just
    /// locked, say): that is "unknown", and a key must not be made for it.
    static func keyForSealing(service: String = defaultService) -> StoredKey? {
        guard let keys = lookup(service: service) else { return nil }
        if let newest = keys.max(by: { $0.created < $1.created }) { return newest }
        return create(service: service)
    }

    /// Kept for callers that only need "a key to use": the sealing key.
    static func loadOrCreateKey(service: String = defaultService) -> SymmetricKey {
        keyForSealing(service: service)?.key ?? SymmetricKey(size: .bits256)
    }

    /// Test-only: removes every key of `service` so a test doesn't leak Keychain
    /// state into the next one (or into the real app's own keys, if a test ever
    /// forgot to pass a unique `service`).
    static func deleteKey(service: String) {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
    }

    /// Test-only: adds a key under a chosen id (nil = the original item).
    @discardableResult
    static func addKey(id: String?, key: SymmetricKey, service: String) -> Bool {
        add(account: id.map { accountPrefix + $0 } ?? legacyAccount, key: key, service: service)
    }

    static func allKeys(service: String) -> [StoredKey] { lookup(service: service) ?? [] }

    /// Every key of `service`. Empty only when the Keychain says there is none;
    /// nil when it could not be read (any other status), which is not the same.
    private static func lookup(service: String) -> [StoredKey]? {
        var attributes = baseQuery(service: service)
        attributes[kSecReturnData as String] = true
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data, data.count == 32 else { return nil }
            let id: String?
            if account == legacyAccount { id = nil }
            else if account.hasPrefix(accountPrefix) { id = String(account.dropFirst(accountPrefix.count)) }
            else { return nil }
            return StoredKey(id: id, key: SymmetricKey(data: data), created: item[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
    }

    private static func create(service: String) -> StoredKey? {
        let id = SealedBlob.newKeyID()
        let key = SymmetricKey(size: .bits256)
        guard add(account: accountPrefix + id, key: key, service: service) else { return nil }
        return StoredKey(id: id, key: key, created: Date())
    }

    /// Add only. A duplicate is an error here, never a reason to delete the
    /// existing item: that deletion is what used to reach every device.
    private static func add(account: String, key: SymmetricKey, service: String) -> Bool {
        var item = baseQuery(service: service)
        item[kSecAttrAccount as String] = account
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Must be a non-"ThisDeviceOnly" accessibility class — only those
        // are eligible to sync via iCloud Keychain at all.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: true,
        ]
    }
}

/// A sealed notebook as stored in `Notebook.encryptedContent`: a marker, the id
/// of the key that sealed it, then the AES-GCM combined box. A blob sealed by an
/// older build has no marker and is the box alone; it opens with the original
/// key. A (1 in 4 billion) older blob whose first bytes happen to equal the
/// marker is still tried as an old blob when the marked reading fails.
enum SealedBlob {
    private static let marker = Data("SQK1".utf8)
    private static let idLength = 16

    static func newKeyID() -> String {
        (0..<idLength).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// nil for an id that is not a valid key id: an unmarked blob sealed with a
    /// new key would only open with the original key, so it must not be written.
    static func wrap(_ box: Data, keyID: String?) -> Data? {
        guard let keyID else { return box }
        guard let idBytes = bytes(fromHex: keyID) else { return nil }
        return marker + idBytes + box
    }

    /// The readings of `blob` worth trying, most likely first.
    static func readings(of blob: Data) -> [(keyID: String?, box: Data)] {
        var out: [(keyID: String?, box: Data)] = []
        if blob.count > marker.count + idLength, blob.prefix(marker.count) == marker {
            let idBytes = blob.dropFirst(marker.count).prefix(idLength)
            out.append((idBytes.map { String(format: "%02x", $0) }.joined(), Data(blob.dropFirst(marker.count + idLength))))
        }
        out.append((nil, blob))
        return out
    }

    private static func bytes(fromHex hex: String) -> Data? {
        guard hex.count == idLength * 2 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
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
            /// Optional so content sealed before this field existed still opens.
            var backgroundPDFData: Data?
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
    /// Returns whether the notebook is now sealed. `false` means nothing was
    /// changed and the content is still readable: the caller must not mark the
    /// notebook protected.
    @discardableResult
    static func lock(_ notebook: Notebook, keyService: String = NotebookEncryptionKeyStore.defaultService) -> Bool {
        // Already sealed (for example its key has not reached this device, so it
        // could not be opened): the live fields are empty, and sealing them again
        // would overwrite the real content with nothing.
        guard notebook.encryptedContent == nil else { return true }
        let pages = notebook.sortedPages
        let content = EncryptedContent(pages: pages.map { page in
            EncryptedContent.Page(
                drawingData: page.drawingData,
                backgroundImageData: page.backgroundImageData,
                title: page.title,
                recognizedText: page.recognizedText,
                backgroundPDFData: page.backgroundPDFData,
                flashcardQuestion: page.flashcardQuestion,
                flashcardAnswer: page.flashcardAnswer,
                elements: page.allElements.map {
                    EncryptedContent.Element(layerIndex: $0.layerIndex, text: $0.text, imageData: $0.imageData)
                }
            )
        })
        guard let plainData = try? JSONEncoder().encode(content),
              let sealingKey = NotebookEncryptionKeyStore.keyForSealing(service: keyService),
              let sealed = try? AES.GCM.seal(plainData, using: sealingKey.key),
              let combined = sealed.combined,
              let blob = SealedBlob.wrap(combined, keyID: sealingKey.id) else { return false }

        // Content that was sealed with the original (id-less) key stays in the
        // old format, so a build from before this change can still open it.
        notebook.encryptedContent = blob
        for page in pages {
            page.drawingData = nil
            page.backgroundImageData = nil
            page.title = ""
            page.recognizedText = ""
            page.backgroundPDFData = nil
            page.flashcardQuestion = ""
            page.flashcardAnswer = ""
            for element in page.allElements {
                element.text = ""
                element.imageData = nil
            }
        }
        return true
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
        // Opens with the key the blob names and never creates one: a key that has
        // not reached this device yet is a failure to retry later, not a reason
        // to make a new key (see `NotebookEncryptionKeyStore`).
        guard let content = openedContent(encrypted, keyService: keyService) else { return false }

        let pages = notebook.sortedPages
        guard pages.count == content.pages.count else { return false }
        for (page, pageContent) in zip(pages, content.pages) {
            page.drawingData = pageContent.drawingData
            page.backgroundImageData = pageContent.backgroundImageData
            page.title = pageContent.title
            page.recognizedText = pageContent.recognizedText
            page.backgroundPDFData = pageContent.backgroundPDFData
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

    private static func openedContent(_ blob: Data, keyService: String) -> EncryptedContent? {
        for reading in SealedBlob.readings(of: blob) {
            guard let key = NotebookEncryptionKeyStore.key(withID: reading.keyID, service: keyService),
                  let box = try? AES.GCM.SealedBox(combined: reading.box),
                  let plain = try? AES.GCM.open(box, using: key),
                  let content = try? JSONDecoder().decode(EncryptedContent.self, from: plain) else { continue }
            return content
        }
        return nil
    }
}
