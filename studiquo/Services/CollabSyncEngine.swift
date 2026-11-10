import Foundation

/// What the sync needs from the server. `LiveDocumentSnapshotClient` talks to
/// the worker; tests use an in-memory room with the same revision rule.
protocol DocumentSnapshotClient {
    func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply
    /// Throws `DocumentCollabService.RevisionConflict` when the room has moved on.
    func putSnapshot(roomID: String, baseRevision: Int, snapshot: String, assets: [String]) async throws -> Int
    func missingAssets(roomID: String, hashes: [String]) async throws -> [String]
    func putAsset(roomID: String, hash: String, data: Data) async throws
    func asset(roomID: String, hash: String) async throws -> Data?
}

struct LiveDocumentSnapshotClient: DocumentSnapshotClient {
    func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply {
        try await DocumentCollabService.snapshot(roomID: roomID, since: since)
    }
    func putSnapshot(roomID: String, baseRevision: Int, snapshot: String, assets: [String]) async throws -> Int {
        try await DocumentCollabService.putSnapshot(roomID: roomID, baseRevision: baseRevision, snapshot: snapshot, assets: assets)
    }
    func missingAssets(roomID: String, hashes: [String]) async throws -> [String] {
        try await DocumentCollabService.missingAssets(roomID: roomID, hashes: hashes)
    }
    func putAsset(roomID: String, hash: String, data: Data) async throws {
        try await DocumentCollabService.putAsset(roomID: roomID, hash: hash, data: data)
    }
    func asset(roomID: String, hash: String) async throws -> Data? {
        try await DocumentCollabService.asset(roomID: roomID, hash: hash)
    }
}

/// What "the person has not edited since" means for a sync round: the live
/// editor text and the document's content. `updatedAt` is deliberately not part
/// of it — every autosave bumps it, which once made nearly every round look
/// "edited" and be dropped, so nothing was ever sent.
struct CollabEditMarker: Equatable {
    /// The editor's whole live text with its formatting, not just the characters:
    /// a bold applied while the network call ran must count as an edit too.
    var live: NSAttributedString
    var snapshot: DocumentSnapshot

    static func == (lhs: CollabEditMarker, rhs: CollabEditMarker) -> Bool {
        lhs.live.isEqual(to: rhs.live) && lhs.snapshot == rhs.snapshot
    }

    @MainActor
    static func capture(of document: TextDocument, live: NSAttributedString) -> CollabEditMarker {
        CollabEditMarker(live: live, snapshot: DocumentSnapshotCodec.make(from: document).snapshot)
    }
}

/// Keeps a shared document in step with its room: pulls what others changed,
/// merges it with what was changed here, applies the result and pushes it back.
/// Runs on the main actor because it reads and writes the SwiftData models.
@MainActor
enum CollabSyncEngine {
    enum Outcome: Equatable {
        /// Nothing to send and nothing new.
        case upToDate
        /// This device's changes were sent.
        case pushed
        /// Others' changes were applied here (and ours, if any, sent).
        case pulled(conflicts: Int)
        /// Another edit happened while the network call ran; try again soon.
        case skipped
        case tooLarge
    }

    private static let maxAttempts = 4

    /// - Parameters:
    ///   - canWrite: the owner and editors write; a reviewer only follows along.
    ///   - flush: commits the editor's live text into the blocks before reading them.
    ///   - stillCurrent: false if the person kept editing while the network call ran;
    ///     applying the room's version then could overwrite their typing, so the round
    ///     is dropped and retried on the next tick.
    ///   - didApply: tells the editor to reload from the blocks.
    static func sync(
        document: TextDocument,
        canWrite: Bool,
        client: DocumentSnapshotClient,
        flush: () -> Void,
        stillCurrent: () -> Bool,
        didApply: () -> Void,
        save: () -> Void
    ) async throws -> Outcome {
        guard let roomID = document.collabRoomID else { return .upToDate }
        flush()
        var appliedRemote = false
        var conflicts = 0
        for _ in 0..<maxAttempts {
            let (local, localAssets) = DocumentSnapshotCodec.make(from: document)
            let base = DocumentSnapshot.decoded(document.collabBaseSnapshot)
            let reply = try await client.snapshot(roomID: roomID, since: document.collabRevision)
            guard stillCurrent() else { return .skipped }

            // The room has no snapshot yet: the owner's (or an editor's) version becomes it.
            if reply.revision == 0 {
                guard canWrite else { return .upToDate }
                switch try await push(local, assets: localAssets, base: 0, roomID: roomID, client: client, document: document, save: save) {
                case .done: return .pushed
                case .conflict: continue
                case .tooLarge: return .tooLarge
                case .notReady: return .upToDate
                }
            }

            // Nothing new in the room.
            if reply.unchanged == true {
                if let base, local == base { return appliedRemote ? .pulled(conflicts: conflicts) : .upToDate }
                guard canWrite else {
                    // A reviewer's edits never leave the device: put the room's version back,
                    // fetching the pictures of that version that this device no longer has.
                    if let base {
                        var assets = localAssets
                        for hash in Set(base.blocks.compactMap(\.imageHash)) where assets[hash] == nil {
                            if let data = try await client.asset(roomID: roomID, hash: hash) { assets[hash] = data }
                        }
                        guard stillCurrent() else { return .skipped }
                        DocumentSnapshotCodec.apply(base, to: document, assets: assets); didApply(); save()
                    }
                    return .pulled(conflicts: 0)
                }
                switch try await push(local, assets: localAssets, base: document.collabRevision, roomID: roomID, client: client, document: document, save: save) {
                case .done: return appliedRemote ? .pulled(conflicts: conflicts) : .pushed
                case .conflict: continue
                case .tooLarge: return .tooLarge
                case .notReady: return .upToDate
                }
            }

            // The room moved on.
            guard let text = reply.snapshot, let written = DocumentSnapshot.decodedUnchecked(Data(text.utf8)) else { return .upToDate }
            // The room holds more than this app accepts (DocumentSnapshot.Limits). Nothing
            // of it is applied, and nothing is sent on top of it: say so instead of
            // reporting the document as in step with the room.
            guard let remote = written.validated() else { return .tooLarge }
            var assets = localAssets
            for hash in Set(remote.blocks.compactMap(\.imageHash)) where assets[hash] == nil {
                if let data = try await client.asset(roomID: roomID, hash: hash) { assets[hash] = data }
            }
            guard stillCurrent() else { return .skipped }

            let target: DocumentSnapshot
            if !canWrite || base == nil {
                target = remote
            } else {
                let merged = DocumentSnapshotMerge.merge(base: base!, local: local, remote: remote)
                conflicts += merged.conflicts
                target = merged.snapshot
            }
            // Two versions that each fit can merge into one that does not. Stop before
            // anything is applied or recorded, so neither side's additions are lost.
            guard target.isWithinLimits else { return .tooLarge }
            if target != local {
                DocumentSnapshotCodec.apply(target, to: document, assets: assets)
                didApply()
                appliedRemote = true
            }
            // Whatever happens next, this device now contains everything up to this
            // revision of the room, so that is the version to merge against next time.
            document.collabBaseSnapshot = remote.encoded()
            document.collabRevision = reply.revision
            save()

            if canWrite, target != remote {
                let (_, targetAssets) = DocumentSnapshotCodec.make(from: document)
                switch try await push(target, assets: targetAssets.merging(assets) { first, _ in first }, base: reply.revision,
                                      roomID: roomID, client: client, document: document, save: save) {
                case .done: return .pulled(conflicts: conflicts)
                case .conflict: continue
                case .tooLarge: return .tooLarge
                case .notReady: return .pulled(conflicts: conflicts)
                }
            }
            return .pulled(conflicts: conflicts)
        }
        return .skipped
    }

    private enum PushResult { case done, conflict, tooLarge, notReady }

    private static func push(
        _ snapshot: DocumentSnapshot, assets: [String: Data], base: Int, roomID: String,
        client: DocumentSnapshotClient, document: TextDocument, save: () -> Void
    ) async throws -> PushResult {
        // What the other members' devices would refuse is not sent at all.
        guard snapshot.isWithinLimits else { return .tooLarge }
        let hashes = Array(Set(snapshot.blocks.compactMap(\.imageHash)))
        if !hashes.isEmpty {
            for batch in stride(from: 0, to: hashes.count, by: 100).map({ Array(hashes[$0..<min($0 + 100, hashes.count)]) }) {
                for hash in try await client.missingAssets(roomID: roomID, hashes: batch) {
                    if let data = assets[hash] { try await client.putAsset(roomID: roomID, hash: hash, data: data) }
                }
            }
        }
        guard let data = snapshot.encoded(), let text = String(data: data, encoding: .utf8) else { return .tooLarge }
        do {
            let revision = try await client.putSnapshot(roomID: roomID, baseRevision: base, snapshot: text, assets: hashes)
            document.collabBaseSnapshot = data
            document.collabRevision = revision
            save()
            return .done
        } catch is DocumentCollabService.RevisionConflict {
            return .conflict
        } catch is DocumentCollabService.RoomNotReady {
            return .notReady
        } catch let error as DocumentCollabService.ServerError where error.status == 413 {
            return .tooLarge
        }
    }
}
