import SwiftData
import SwiftUI

/// "共有の招待": invitations to someone else's collaborative document. Accepting
/// seats this person in the room and imports the room's text as a new local
/// document (see `CollabInviteImporter`); declining just tells the server.
struct CollabInvitesSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [TextDocument]

    @State private var invites: [DocumentCollabService.PendingInvite] = []
    /// Accepted on the server but not imported yet (the state fetch failed):
    /// kept so the person can retry instead of being seated with no document.
    @State private var acceptedNotImported: [DocumentCollabService.PendingInvite] = []
    @State private var busyRoomIDs: Set<String> = []
    @State private var notice: String?
    @State private var loadFailed = false
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !invites.isEmpty || !acceptedNotImported.isEmpty || notice != nil || loadFailed {
                Section("共有の招待") {
                    ForEach(invites) { invite in row(invite, accepted: false) }
                    ForEach(acceptedNotImported) { invite in row(invite, accepted: true) }
                    if loadFailed {
                        Text("共有の招待を読み込めませんでした。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await reload() }
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
                if busyRoomIDs.contains(invite.roomID) { ProgressView() }
            }
            if !busyRoomIDs.contains(invite.roomID) {
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

    private func reload() async {
        do {
            let list = try await DocumentCollabService.pendingInvites()
            await MainActor.run {
                invites = list
                loadFailed = false
                hasLoaded = true
            }
        } catch {
            await MainActor.run { loadFailed = hasLoaded ? loadFailed : true }
        }
    }

    private func accept(_ invite: DocumentCollabService.PendingInvite) async {
        busyRoomIDs.insert(invite.roomID)
        defer { busyRoomIDs.remove(invite.roomID) }
        do {
            _ = try await DocumentCollabService.acceptInvite(roomID: invite.roomID)
        } catch {
            notice = L("承認できませんでした。通信環境を確認してください。")
            return
        }
        invites.removeAll { $0.roomID == invite.roomID }
        await importDocument(invite, alreadyBusy: true)
    }

    private func decline(_ invite: DocumentCollabService.PendingInvite) async {
        busyRoomIDs.insert(invite.roomID)
        defer { busyRoomIDs.remove(invite.roomID) }
        do {
            _ = try await DocumentCollabService.declineInvite(roomID: invite.roomID)
            invites.removeAll { $0.roomID == invite.roomID }
            notice = nil
        } catch {
            notice = L("辞退できませんでした。通信環境を確認してください。")
        }
    }

    private func importDocument(_ invite: DocumentCollabService.PendingInvite, alreadyBusy: Bool = false) async {
        if !alreadyBusy { busyRoomIDs.insert(invite.roomID) }
        defer { if !alreadyBusy { busyRoomIDs.remove(invite.roomID) } }
        // Never create a second copy for a room this device already has.
        if documents.contains(where: { $0.collabRoomID == invite.roomID }) {
            acceptedNotImported.removeAll { $0.roomID == invite.roomID }
            notice = L("共有された文書は、すでにライブラリにあります。")
            return
        }
        do {
            let state = try await DocumentCollabService.state(roomID: invite.roomID)
            let document = CollabInviteImporter.makeDocument(
                roomID: invite.roomID, inviterName: invite.inviterName, state: state
            )
            modelContext.insert(document)
            try modelContext.save()
            acceptedNotImported.removeAll { $0.roomID == invite.roomID }
            notice = L("共有された文書をライブラリに追加しました。")
        } catch {
            if !acceptedNotImported.contains(where: { $0.roomID == invite.roomID }) {
                acceptedNotImported.append(invite)
            }
            notice = L("承認しましたが、文書を取り込めませんでした。「もう一度取り込む」を押してください。")
        }
    }
}
