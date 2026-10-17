import Foundation

/// Which accounts have used this device, and (in later stages) where each
/// account's library lives. Stage 1 only records who signed in: nothing about
/// where the library is stored, or what is shown, depends on it yet.
///
/// The ids are the server's opaque account ids (`GET api/account/library-id`),
/// the same for one person whichever way they sign in. They are hashes, not
/// emails or provider ids, and are not secrets.
struct LibraryLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var accountID: String
        var firstSeenAt: Date
        var lastSeenAt: Date
    }

    var version = 1
    var entries: [Entry] = []
    /// The account that signed in most recently on this device.
    var lastActiveAccountID: String?

    /// A server id is 64 lowercase hex characters; anything else is not recorded.
    static func isValidAccountID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Drops anything that is not a well-formed account id, and a "last active"
    /// account that is not in the list.
    mutating func sanitize() {
        entries = entries.filter { Self.isValidAccountID($0.accountID) }
        if let last = lastActiveAccountID, !entries.contains(where: { $0.accountID == last }) { lastActiveAccountID = nil }
    }

    @discardableResult
    mutating func recordSignIn(accountID: String, at date: Date) -> Bool {
        guard Self.isValidAccountID(accountID) else { return false }
        if let index = entries.firstIndex(where: { $0.accountID == accountID }) {
            entries[index].lastSeenAt = date
        } else {
            entries.append(Entry(accountID: accountID, firstSeenAt: date, lastSeenAt: date))
        }
        lastActiveAccountID = accountID
        return true
    }
}

/// Keeps the ledger in one small file next to the library. Writes are atomic
/// and, like the automatic backups, readable while the file is open even if the
/// iPad locks a moment later.
struct LibraryLedgerStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static var `default`: LibraryLedgerStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return LibraryLedgerStore(fileURL: base.appendingPathComponent("studiquo/LibraryLedger.json"))
    }

    /// One process-wide lock: a read-change-write must not interleave with another.
    private static let lock = NSLock()

    /// What was found: an empty ledger when there is none yet, `nil` when there
    /// is one that cannot be read right now (the iPad is locked, a read error) or
    /// that is damaged and could not be set aside. A caller that gets `nil` must
    /// not write: a ledger that exists must never be replaced by an empty one.
    ///
    /// A damaged file is moved aside (never silently overwritten, since later
    /// stages rely on it). Entries that are not valid account ids are dropped,
    /// because an id may become a folder name and the file can be edited.
    func load() -> LibraryLedger? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return LibraryLedger() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if var ledger = try? JSONDecoder.ledger.decode(LibraryLedger.self, from: data) {
            ledger.sanitize()
            return ledger
        }
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("LibraryLedger.unreadable-\(UUID().uuidString).json")
        do { try fileManager.moveItem(at: fileURL, to: aside) } catch { return nil }
        return LibraryLedger()
    }

    /// Reads, changes and writes under one lock. Returns the saved ledger, or nil
    /// when it could not be read (nothing is written) or written.
    @discardableResult
    func update(_ change: (inout LibraryLedger) -> Bool) -> LibraryLedger? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var ledger = load() else { return nil }
        guard change(&ledger) else { return nil }
        return save(ledger) ? ledger : nil
    }

    @discardableResult
    func save(_ ledger: LibraryLedger) -> Bool {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.ledger.encode(ledger)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch {
            return false
        }
    }
}

private extension JSONEncoder {
    static var ledger: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

private extension JSONDecoder {
    static var ledger: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Asks the server which account this device is signed in as, and records it.
enum LibraryIdentityService {
    private struct Answer: Decodable { let libraryID: String }

    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// Returns the account id that was recorded, or nil when it could not be
    /// learned (no session, offline, an old server, an unexpected answer). A nil
    /// changes nothing: it is tried again the next time.
    @discardableResult
    static func refresh(
        token: String? = MCPCloudCredentials.currentToken(),
        endpoint: URL? = MCPCloudCredentials.configuredEndpoint(),
        store: LibraryLedgerStore = .default,
        now: Date = Date(),
        currentToken: () -> String? = { MCPCloudCredentials.currentToken() },
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async -> String? {
        guard let token, !token.isEmpty, let endpoint else { return nil }
        var request = URLRequest(url: endpoint.appending(path: "api/account/library-id"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await fetch(request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              LibraryLedger.isValidAccountID(answer.libraryID) else { return nil }
        // The answer is about the account that held this token when it was asked.
        // If the person signed out (or in as someone else) meanwhile, it is not
        // recorded as the current account.
        guard currentToken() == token else { return nil }
        let saved = store.update { $0.recordSignIn(accountID: answer.libraryID, at: now) }
        return saved == nil ? nil : answer.libraryID
    }
}
