import SwiftData
import SwiftUI

/// Holds the pending collaboration invites. Owned by the screen that shows
/// `CollabInvitesSection` and loaded from that screen's own `.task`: the section
/// is hidden while it has nothing to show, so it cannot be what triggers the load.
@MainActor
final class CollabInviteInbox: ObservableObject {
    @Published var invites: [DocumentCollabService.PendingInvite] = []
    /// Accepted on the server but not imported yet (the state fetch failed):
    /// kept so the person can retry instead of being seated with no document.
    @Published var acceptedNotImported: [DocumentCollabService.PendingInvite] = []
    @Published var busyRoomIDs: Set<String> = []
    @Published var notice: String?
    @Published var loadFailed = false
    private var hasLoaded = false
    private let load: () async throws -> [DocumentCollabService.PendingInvite]

    init(load: @escaping () async throws -> [DocumentCollabService.PendingInvite] = { try await DocumentCollabService.pendingInvites() }) {
        self.load = load
    }

    func reload() async {
        do {
            invites = try await load()
            loadFailed = false
            hasLoaded = true
        } catch {
            if !hasLoaded { loadFailed = true }
        }
    }
}

/// "共有の招待": invitations to someone else's collaborative document. Accepting
/// seats this person in the room and imports the room's text as a new local
/// document (see `CollabInviteImporter`); declining just tells the server.
struct CollabInvitesSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [TextDocument]

    @ObservedObject var inbox: CollabInviteInbox

    var body: some View {
        Group {
            if !inbox.invites.isEmpty || !inbox.acceptedNotImported.isEmpty || inbox.notice != nil || inbox.loadFailed {
                Section("共有の招待") {
                    ForEach(inbox.invites) { invite in row(invite, accepted: false) }
                    ForEach(inbox.acceptedNotImported) { invite in row(invite, accepted: true) }
                    if inbox.loadFailed {
                        Text("共有の招待を読み込めませんでした。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = inbox.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ invite: DocumentCollabService.PendingInvite, accepted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(CollabInviteImporter.title(inviterName: invite.inviterName))
                    Text(roleLabel(invite.role)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if inbox.busyRoomIDs.contains(invite.roomID) { ProgressView() }
            }
            if !inbox.busyRoomIDs.contains(invite.roomID) {
                HStack {
                    if accepted {
                        Button("もう一度取り込む") { Task { await importDocument(invite) } }
                            .buttonStyle(.themePrimary)
                    } else {
                        Button("承認") { Task { await accept(invite) } }
                            .buttonStyle(.themePrimary)
                        Button("辞退", role: .destructive) { Task { await decline(invite) } }
                            .buttonStyle(.themeSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func roleLabel(_ role: String) -> String {
        role == "reviewer" ? L("レビュアーとして招待") : L("編集者として招待")
    }

    private func accept(_ invite: DocumentCollabService.PendingInvite) async {
        inbox.busyRoomIDs.insert(invite.roomID)
        defer { inbox.busyRoomIDs.remove(invite.roomID) }
        do {
            _ = try await DocumentCollabService.acceptInvite(roomID: invite.roomID)
        } catch {
            inbox.notice = L("承認できませんでした。通信環境を確認してください。")
            return
        }
        inbox.invites.removeAll { $0.roomID == invite.roomID }
        await importDocument(invite, alreadyBusy: true)
    }

    private func decline(_ invite: DocumentCollabService.PendingInvite) async {
        inbox.busyRoomIDs.insert(invite.roomID)
        defer { inbox.busyRoomIDs.remove(invite.roomID) }
        do {
            _ = try await DocumentCollabService.declineInvite(roomID: invite.roomID)
            inbox.invites.removeAll { $0.roomID == invite.roomID }
            inbox.notice = nil
        } catch {
            inbox.notice = L("辞退できませんでした。通信環境を確認してください。")
        }
    }

    private func importDocument(_ invite: DocumentCollabService.PendingInvite, alreadyBusy: Bool = false) async {
        if !alreadyBusy { inbox.busyRoomIDs.insert(invite.roomID) }
        defer { if !alreadyBusy { inbox.busyRoomIDs.remove(invite.roomID) } }
        // Never create a second copy for a room this device already has.
        if documents.contains(where: { $0.collabRoomID == invite.roomID }) {
            inbox.acceptedNotImported.removeAll { $0.roomID == invite.roomID }
            inbox.notice = L("共有された文書は、すでにライブラリにあります。")
            return
        }
        do {
            let document: TextDocument
            let reply = try await DocumentCollabService.snapshot(roomID: invite.roomID, since: -1)
            if reply.revision > 0, let text = reply.snapshot, let snapshot = DocumentSnapshot.decoded(Data(text.utf8)) {
                var assets: [String: Data] = [:]
                for hash in Set(snapshot.blocks.compactMap(\.imageHash)) {
                    if let data = try await DocumentCollabService.asset(roomID: invite.roomID, hash: hash) { assets[hash] = data }
                }
                document = CollabInviteImporter.makeDocument(
                    roomID: invite.roomID, inviterName: invite.inviterName, snapshot: snapshot, revision: reply.revision, assets: assets
                )
            } else {
                // The owner has not synced yet (an older version of the app): start from the text the room holds.
                let state = try await DocumentCollabService.state(roomID: invite.roomID)
                document = CollabInviteImporter.makeDocument(roomID: invite.roomID, inviterName: invite.inviterName, state: state)
            }
            modelContext.insert(document)
            try modelContext.save()
            inbox.acceptedNotImported.removeAll { $0.roomID == invite.roomID }
            inbox.notice = L("共有された文書をライブラリに追加しました。")
        } catch {
            if !inbox.acceptedNotImported.contains(where: { $0.roomID == invite.roomID }) {
                inbox.acceptedNotImported.append(invite)
            }
            inbox.notice = L("承認しましたが、文書を取り込めませんでした。「もう一度取り込む」を押してください。")
        }
    }
}
