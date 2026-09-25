import CoreImage.CIFilterBuiltins
import CryptoKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct UserProfileView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("profileName") private var name = ""
    @AppStorage("profileOccupation") private var occupation = ""
    @AppStorage("profileBio") private var bio = ""
    @AppStorage("profileImage") private var imageData = Data()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var passkeyAdded = false
    /// A multiline `TextField(_:text:axis:.vertical)` bound straight to an
    /// `@AppStorage` value re-triggers this `Form`'s layout (the field's own
    /// height depends on its text) on every keystroke as the write-through to
    /// UserDefaults publishes a change synchronously — which raced the
    /// field's own edit and dropped whatever had just been typed. Typing
    /// into a plain `@State` draft here, and only writing it through to
    /// `bio` on change, keeps every keystroke local to this view instead.
    @State private var bioDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 18) {
                        profileImage
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo")
                        }
                    }
                    TextField("名前", text: $name)
                    TextField("職業・身分", text: $occupation)
                    TextField("自己紹介", text: $bioDraft, axis: .vertical).lineLimit(3...6)
                    LabeledContent("メールアドレス", value: authentication.email)
                }
                Section {
                    Button {
                        Task { passkeyAdded = await authentication.addPasskey() }
                    } label: {
                        Label(
                            passkeyAdded ? "パスキーを追加しました" : "パスキーを追加",
                            systemImage: passkeyAdded ? "checkmark.circle.fill" : "person.badge.key.fill"
                        )
                    }
                    .disabled(authentication.isPasskeyBusy || passkeyAdded)
                    if !authentication.errorMessage.isEmpty {
                        Text(authentication.errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("ログイン")
                } footer: {
                    Text("パスキーはiCloudキーチェーンに安全に保存され、次回からFace IDまたはTouch IDでログインできます。")
                }
                Section {
                    Button("ログアウト", role: .destructive) { authentication.logout(); dismiss() }
                }
            }
            .navigationTitle("プロフィール")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear { bioDraft = bio }
            .onChange(of: bioDraft) { _, newValue in bio = newValue }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let normalized = Self.profileImageData(from: image) else { return }
                    imageData = normalized
                }
            }
        }
    }

    @ViewBuilder private var profileImage: some View {
        if let image = UIImage(data: imageData) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 78, height: 78).clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().frame(width: 78, height: 78).foregroundStyle(.secondary)
        }
    }

    /// Profile photos live in UserDefaults, so keep them small and strip the
    /// original file's metadata before persisting them.
    private static func profileImageData(from image: UIImage) -> Data? {
        let side: CGFloat = 512
        let scale = max(side / image.size.width, side / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

struct FriendRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var code: String
    var todayStudySeconds: TimeInterval
    var roomID: String?
    var isDemo: Bool?
    /// nil means an older persisted record that predates this flag. Treat it
    /// as shared for existing local demo/real friends so their current UI does
    /// not suddenly hide already-known study time after an update.
    var sharesStudyTime: Bool? = true
    /// This friend's profile photo, cached locally once fetched — see
    /// `FriendStore.syncFriendAvatarsIfNeeded`. Falls back to a generic icon
    /// (`FriendProfile.iconSystemName`) until/unless this is ever set.
    var avatarData: Data? = nil
    /// The `avatarUpdatedAt` last reported by the server for this friend
    /// (ms since epoch) as of when `avatarData` was cached — compared
    /// against `friends()`'s response on each poll so a friend changing
    /// their photo is picked up without re-downloading it on every poll.
    var avatarUpdatedAt: Double? = nil
}

struct FriendProfile: Identifiable, Hashable {
    var id: UUID
    var name: String
    var code: String
    var iconSystemName: String
    var avatarData: Data?
    var todayStudySeconds: TimeInterval?
    var roomID: String?
    var isDemo: Bool
    var isBlockedByMe: Bool

    init(friend: FriendRecord, blockedByMeRoomIDs: Set<String>) {
        id = friend.id
        name = friend.name
        code = friend.code
        iconSystemName = friend.isDemo == true ? "sparkles" : "person.crop.circle.fill"
        avatarData = friend.avatarData
        todayStudySeconds = friend.sharesStudyTime == false ? nil : friend.todayStudySeconds
        roomID = friend.roomID
        isDemo = friend.isDemo == true
        isBlockedByMe = friend.roomID.map { blockedByMeRoomIDs.contains($0) } ?? false
    }
}

/// A friend's photo if it's been cached locally, else a generic placeholder
/// icon — the single rendering used everywhere a friend's avatar appears
/// (sidebar row, chat list, profile popover, message bubbles), so all of
/// them pick up a newly-synced photo identically.
private struct FriendAvatarView: View {
    let avatarData: Data?
    let iconSystemName: String
    var size: CGFloat = 34

    var body: some View {
        if let avatarData, let image = UIImage(data: avatarData) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: iconSystemName)
                .font(.system(size: size * 0.72))
                .foregroundStyle(.tint)
                .frame(width: size, height: size)
        }
    }
}

struct FriendChatSummary: Identifiable, Hashable {
    var id: UUID { friend.id }
    var friend: FriendRecord
    var latestMessage: FriendMessage?
    var latestDate: Date?
    var previewText: String
    var unreadCount: Int

    static func summaries(
        friends: [FriendRecord],
        messages: [FriendMessage],
        unreadCounts: [UUID: Int]
    ) -> [FriendChatSummary] {
        friends.map { friend in
            let latest = messages
                .filter { $0.friendID == friend.id && ($0.roomID == nil || $0.roomID == friend.roomID) }
                .max { $0.sentAt < $1.sentAt }
            return FriendChatSummary(
                friend: friend,
                latestMessage: latest,
                latestDate: latest?.sentAt,
                previewText: latest.map(previewText(for:)) ?? "",
                unreadCount: unreadCounts[friend.id, default: 0]
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.latestDate, rhs.latestDate) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.friend.name.localizedStandardCompare(rhs.friend.name) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.friend.name.localizedStandardCompare(rhs.friend.name) == .orderedAscending
            }
        }
    }

    private static func previewText(for message: FriendMessage) -> String {
        if message.isCanceled == true { return "メッセージを取り消しました" }
        let parts = FriendMessageParts(text: message.text)
        if let attachment = parts.attachments.first { return attachment.title }
        return parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct IncomingFriendRequest: Identifiable, Codable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var requestedAt: Date
}

struct OutgoingFriendRequest: Identifiable, Codable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var requestedAt: Date
}

struct FriendMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var friendID: UUID
    var text: String
    var sentAt: Date
    var isMine: Bool
    var isCanceled: Bool?
    /// The server's own message id, once this message has been confirmed to
    /// exist there (nil for a not-yet-synced optimistic local send). Lets
    /// `refreshMessages` fetch only what's new instead of replacing the
    /// whole local history with the server's last-200-message window.
    var serverID: Int? = nil
    /// Set when the network send actually failed, so the bubble can show a
    /// failure indicator instead of looking identical to a delivered
    /// message. The user can still dismiss it via the existing "送信取消".
    var sendFailed: Bool? = nil
    /// Message ids are only unique within a room. Keep the room alongside
    /// each cached message so a changed friendship cannot reuse its cursor.
    var roomID: String? = nil
}

struct FriendAttachmentOpenRequest {
    let attachment: FriendMessageAttachment
}

@MainActor
final class FriendStore: ObservableObject {
    @Published var friends: [FriendRecord] = [] { didSet { persist(friends, key: friendsKey) } }
    @Published var messages: [FriendMessage] = [] { didSet { persist(messages, key: messagesKey) } }
    @Published var incomingRequests: [IncomingFriendRequest] = []
    @Published var outgoingRequests: [OutgoingFriendRequest] = []
    /// How many of `incomingRequests` haven't been shown to the user yet —
    /// drives the badge on the home screen's "フレンド" tab (`ContentView`),
    /// so a pending request is visible from anywhere in the app instead of
    /// only once this screen happens to already be open. Cleared by
    /// `markIncomingRequestsSeen()`, not by accept/reject — seeing the
    /// request and deciding on it are two different things.
    @Published private(set) var unseenIncomingRequestCount: Int = 0
    /// Codes already shown to the user at least once, persisted so a
    /// relaunch doesn't re-surface the badge for a request they've already
    /// seen (but not yet acted on).
    private var seenIncomingRequestCodes: Set<String> = [] { didSet { persist(seenIncomingRequestCodes, key: seenIncomingRequestCodesKey) } }
    /// Codes with an accept/reject network call currently in flight, so the
    /// view can disable that request's buttons — without this, a fast
    /// double-tap fires the operation twice before the first response ever
    /// comes back.
    @Published var pendingRequestActions: Set<String> = []
    /// Persisted alongside `messages` — without this, an app relaunch
    /// silently cleared every unread badge back to zero even though the
    /// underlying messages (which genuinely hadn't been read yet) were
    /// still there.
    @Published var unreadCounts: [UUID: Int] = [:] { didSet { persist(unreadCounts, key: unreadCountsKey) } }
    @Published private(set) var blockedContacts: [FriendChatService.BlockedContact] = []
    @Published private(set) var pendingRemovalCodes: Set<String> = []
    /// Groups the user has actually joined — never one they've only been
    /// invited to (see `incomingGroupInvites`).
    @Published var groups: [FriendChatService.Group] = [] { didSet { persist(groups, key: groupsKey) } }
    @Published var incomingGroupInvites: [FriendChatService.GroupInvite] = []
    /// Keyed by roomID — unlike `messages` (friend-keyed, persisted across
    /// launches, with a whole local optimistic-echo/attachment apparatus
    /// built up for 1:1 chat), a group's messages are kept only in memory
    /// for now and simply re-fetched from the server each time its chat
    /// screen is opened.
    @Published var groupMessages: [String: [FriendChatService.Message]] = [:]
    /// Room ids with a group-invite accept/reject/create/leave/remove
    /// network call currently in flight — mirrors `pendingRequestActions`'
    /// own reasoning for friend requests.
    @Published var pendingGroupActions: Set<String> = []
    @Published var activeFriendID: UUID?
    @Published var myCode: String
    /// A second code, embedded only in `invitationURL`'s link/QR — never
    /// shown for manual entry. Redeeming it (see `confirmPendingLinkAdd()`)
    /// creates an immediate, no-approval friendship; deliberately a
    /// different value from `myCode` so that shortcut can never be reached
    /// by typing a code by hand instead of actually receiving the link.
    @Published private(set) var myLinkToken: String
    @Published var errorMessage = ""
    /// Room ids (not persisted — the server is the source of truth, and this
    /// is only ever populated on demand when a chat screen asks) that *this
    /// user* has blocked the other participant in. Doesn't track
    /// `blockedByOther`; nothing in the UI currently needs that beyond what
    /// a failed send already surfaces.
    @Published var blockedByMeRoomIDs: Set<String> = []
    private let client: FriendChatClient
    private let defaults: UserDefaults
    private let friendsKey = "studiquoFriends"
    private let messagesKey = "studiquoFriendMessages"
    private let unreadCountsKey = "studiquoFriendUnreadCounts"
    private let archivedFriendsKey = "studiquoArchivedFriends"
    private var archivedFriends: [FriendRecord] = [] { didSet { persist(archivedFriends, key: archivedFriendsKey) } }
    private let groupsKey = "studiquoGroups"
    private let seenIncomingRequestCodesKey = "studiquoSeenIncomingRequestCodes"
    /// A digest of whichever `profileImage` bytes were last successfully
    /// uploaded via `syncMyAvatarIfNeeded` — compared against the profile
    /// screen's current photo on every `refresh()` so a changed (or
    /// first-ever) photo is pushed to the server without re-uploading an
    /// unchanged one on every single poll.
    private let uploadedAvatarDigestKey = "studiquoUploadedAvatarDigest"
    /// The app-wide incoming-request poll (see `handle(scenePhase:)`) — owns
    /// this instead of tying it to whichever screen happens to be open, the
    /// same reasoning `FriendsHomeView`'s own `.task` used to rely on alone.
    private var incomingRequestPollTask: Task<Void, Never>?
    private var inboxPollTask: Task<Void, Never>?
    private var groupPollTask: Task<Void, Never>?
    private var locallyRemovedCodes: Set<String> = []
    private static let codePattern = /^[A-Z0-9]{6,32}$/
    /// Shared cadence for every "list" poll below (incoming requests,
    /// groups, group invites, the friends list itself) — these used to run
    /// every 2 seconds, which (multiplied across friends()'s and groups()'s
    /// own per-item lookups, and every simultaneously active device) was
    /// enough to exhaust the account's entire daily KV operation quota in
    /// production, breaking these same features for everyone. None of these
    /// lists need to feel instant the way an open chat's own message poll
    /// does — a several-second delay noticing a new request or group is
    /// imperceptible in practice.
    private static let listPollInterval: Duration = .seconds(8)
    private static let maximumFriends = 500
    /// Enforced per friend, not as a shared total across every
    /// conversation — a bound shared across all friends meant one very
    /// active conversation could evict another, untouched friend's history
    /// even though that conversation was nowhere near this limit on its
    /// own.
    private static let maximumMessagesPerFriend = 10_000
    private static let maximumMessageLength = 2_000
    /// Shown only until the very first registration round trip ever
    /// completes (later launches start from the last persisted real code).
    private static let placeholderCode = "準備中"

    init(client: FriendChatClient = LiveFriendChatClient(), defaults: UserDefaults = .standard, autoRefresh: Bool = true) {
        self.client = client
        self.defaults = defaults
        myCode = defaults.string(forKey: "studiquoFriendCode") ?? Self.placeholderCode
        myLinkToken = defaults.string(forKey: "studiquoFriendLinkToken") ?? Self.placeholderCode
        if let data = defaults.data(forKey: friendsKey) {
            friends = (try? JSONDecoder().decode([FriendRecord].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: archivedFriendsKey) {
            archivedFriends = (try? JSONDecoder().decode([FriendRecord].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: groupsKey) {
            groups = (try? JSONDecoder().decode([FriendChatService.Group].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: messagesKey) {
            if let decoded = try? JSONDecoder().decode([FriendMessage].self, from: data) {
                let roomsByFriend = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0.roomID) })
                messages = decoded.map { message in
                    var migrated = message
                    if migrated.roomID == nil { migrated.roomID = roomsByFriend[message.friendID] ?? nil }
                    return migrated
                }
            } else {
                // Unlike `friends` (fully recoverable from the next
                // refresh()) or `unreadCounts` (self-corrects as new
                // messages arrive), a message history that fails to decode
                // has no other copy anywhere — the server only ever answers
                // a fresh fetch with each room's most recent 200 messages,
                // so anything older than that is gone for good. The user at
                // least deserves to know that happened, instead of the
                // conversation just quietly looking empty.
                errorMessage = "保存されていたメッセージ履歴を読み込めませんでした。"
            }
        }
        if let data = defaults.data(forKey: unreadCountsKey) {
            unreadCounts = (try? JSONDecoder().decode([UUID: Int].self, from: data)) ?? [:]
        }
        if let data = defaults.data(forKey: seenIncomingRequestCodesKey) {
            seenIncomingRequestCodes = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        if autoRefresh {
            Task { await refresh() }
            startIncomingRequestPolling()
            startInboxPolling()
            startGroupPolling()
        }
    }

    /// Polls for incoming friend requests for as long as this store exists
    /// (effectively the whole authenticated session — see `ContentView`),
    /// independent of whichever screen is currently showing. Without this,
    /// a request sent while the recipient wasn't already on the Friends
    /// screen was invisible until they happened to open it: nothing else in
    /// the app ever fetched this on its own. Safe to call repeatedly —
    /// a second call while already polling is a no-op.
    func startIncomingRequestPolling() {
        guard incomingRequestPollTask == nil else { return }
        incomingRequestPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIncomingRequests()
                try? await Task.sleep(for: Self.listPollInterval)
            }
        }
    }

    func stopIncomingRequestPolling() {
        incomingRequestPollTask?.cancel()
        incomingRequestPollTask = nil
    }

    func startInboxPolling() {
        guard inboxPollTask == nil else { return }
        inboxPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInbox()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }

    func stopInboxPolling() {
        inboxPollTask?.cancel()
        inboxPollTask = nil
    }

    /// Polls for both joined groups and pending group invitations — a
    /// group's own membership can change from elsewhere (invited, added,
    /// removed) the same way a friend request can, so this follows
    /// `startIncomingRequestPolling`'s exact reasoning.
    func startGroupPolling() {
        guard groupPollTask == nil else { return }
        groupPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshGroups()
                await self?.refreshGroupInvites()
                try? await Task.sleep(for: Self.listPollInterval)
            }
        }
    }

    func stopGroupPolling() {
        groupPollTask?.cancel()
        groupPollTask = nil
    }

    /// Pauses polling while backgrounded and resumes it on return to the
    /// foreground — there's no server-push delivery for friend requests
    /// (see `FriendChatService`'s doc comment), so background polling would
    /// just burn battery for a screen the user can't currently see anyway.
    /// Driven by `ContentView`'s own `scenePhase`, the app's one existing
    /// source of truth for this (mirrors `StudyTimeTracker.handle
    /// (scenePhase:)`).
    func handle(scenePhase: ScenePhase) {
        if scenePhase == .active {
            startIncomingRequestPolling()
            startInboxPolling()
            startGroupPolling()
        } else {
            stopIncomingRequestPolling()
            stopInboxPolling()
            stopGroupPolling()
        }
    }

    /// Marks every currently-known incoming request as seen, clearing the
    /// home-screen tab badge — called once the "フレンド申請" list has
    /// actually been shown to the user (`FriendsHomeView.onAppear`).
    /// Deliberately separate from accepting/rejecting: seeing a request and
    /// deciding on it are two different actions.
    func markIncomingRequestsSeen() {
        guard unseenIncomingRequestCount > 0 else { return }
        seenIncomingRequestCodes.formUnion(incomingRequests.map(\.code))
        unseenIncomingRequestCount = 0
    }

    /// `token`, not `code` — a link/QR tap redeems `myLinkToken` for an
    /// immediate, no-approval friendship (see `myLinkToken`'s doc comment
    /// and `add(url:)`), a deliberately different mechanism from typing
    /// `myCode` by hand.
    var invitationURL: URL { URL(string: "studiquo://friend/add?token=\(myLinkToken)")! }

    /// False only during the narrow window on a brand-new install before the
    /// first registration completes — sharing/scanning a QR code before this
    /// is true would encode the placeholder text instead of a real token.
    var isCodeReady: Bool { myCode != Self.placeholderCode && myLinkToken != Self.placeholderCode }

    func refresh() async {
        do {
            let name = defaults.string(forKey: "profileName") ?? "Studiquoユーザー"
            let identity = try await client.register(name: name, todayStudySeconds: nil, studyDate: nil)
            myCode = identity.code
            defaults.set(myCode, forKey: "studiquoFriendCode")
            if let linkToken = identity.linkToken {
                myLinkToken = linkToken
                defaults.set(myLinkToken, forKey: "studiquoFriendLinkToken")
            }
            let remote = try await client.friends()
            applyRemoteFriends(remote)
            await syncFriendAvatarsIfNeeded(remote: remote)
            errorMessage = ""
        } catch {
            errorMessage = Self.isAuthFailure(error) ? Self.authExpiredErrorMessage : Self.connectivityErrorMessage
        }
        await syncMyAvatarIfNeeded()
        await refreshIncomingRequests()
        await refreshOutgoingRequests()
    }

    /// Refreshes just the friends list, skipping the register() call that
    /// `refresh()` also makes — cheap enough to poll periodically so a
    /// friend who just accepted this user's request shows up without
    /// waiting for a full refresh() (app relaunch, or another add()).
    func refreshFriends() async {
        do {
            let remote = try await client.friends()
            notePollResult("friends", succeeded: true)
            applyRemoteFriends(remote)
            await syncFriendAvatarsIfNeeded(remote: remote)
        } catch {
            notePollResult("friends", succeeded: false, error: error)
        }
    }

    /// Downloads a friend's photo whenever the server's `avatarUpdatedAt`
    /// for them (this poll's fresh value, not yet written onto the merged
    /// `FriendRecord`) differs from whatever timestamp the locally cached
    /// `avatarData` was fetched for — including the very first time either
    /// side ever sees a photo at all (cached is nil, server has a value), and
    /// a friend removing their photo (server is nil, cached is not).
    private func syncFriendAvatarsIfNeeded(remote: [FriendChatService.Friend]) async {
        let needsFetch = remote.filter { item in
            guard let cached = friends.first(where: { $0.isDemo != true && $0.code == item.code }) else { return false }
            return cached.avatarUpdatedAt != item.avatarUpdatedAt
        }
        guard !needsFetch.isEmpty else { return }
        var working = friends
        for item in needsFetch {
            guard let index = working.firstIndex(where: { $0.isDemo != true && $0.code == item.code }) else { continue }
            guard item.avatarUpdatedAt != nil else {
                working[index].avatarData = nil
                working[index].avatarUpdatedAt = nil
                continue
            }
            guard let data = try? await client.downloadAvatar(code: item.code) else { continue }
            working[index].avatarData = data
            working[index].avatarUpdatedAt = item.avatarUpdatedAt
        }
        friends = working
    }

    /// Pushes the profile screen's current photo to the server whenever it's
    /// changed since the last successful upload — see
    /// `uploadedAvatarDigestKey`. Without this, a friend never learns about a
    /// new (or first-ever) profile photo no matter how many times this
    /// device polls, because nothing about it was ever sent.
    private func syncMyAvatarIfNeeded() async {
        let imageData = defaults.data(forKey: "profileImage") ?? Data()
        guard !imageData.isEmpty else { return }
        let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        guard digest != defaults.string(forKey: uploadedAvatarDigestKey) else { return }
        guard (try? await client.uploadAvatar(contentType: "image/jpeg", data: imageData)) != nil else { return }
        defaults.set(digest, forKey: uploadedAvatarDigestKey)
    }

    /// Consecutive-failure counts for each background polling loop, keyed by
    /// a name unique to that loop. A single transient blip shouldn't nag the
    /// user, but a sustained failure (e.g. no connectivity at all) used to
    /// go on forever with nothing ever telling them why the screen had gone
    /// stale — this surfaces `errorMessage` once failures persist.
    private var consecutivePollFailures: [String: Int] = [:]
    private static let pollFailureAlertThreshold = 3
    /// Set once an expired-token alert has actually been shown, and only
    /// cleared on the next successful poll (see the `succeeded` branch
    /// below) — not on every dismissal. Without this, three separate
    /// polling loops (friends, incoming requests, and — while a chat is
    /// open — messages) each independently rediscover the same still-401
    /// token roughly every 2 seconds, and `notePollResult`'s auth branch
    /// used to unconditionally reassign `errorMessage` every single time,
    /// so the alert reappeared within a second of being dismissed no matter
    /// how many times the user tapped OK. An expired token doesn't recover
    /// on its own, so there is nothing more to learn from telling the user
    /// about it twice before they've had a chance to act on the first one.
    private var hasNotifiedAuthExpired = false
    /// Also used as a marker: `notePollResult` only ever clears `errorMessage`
    /// on recovery when it currently holds exactly one of these two strings —
    /// see its own doc comment for why a blanket clear-on-any-success isn't
    /// safe.
    private static let connectivityErrorMessage = "フレンドサーバーに接続できません。"
    private static let roomAccessErrorMessage = "チャットルームにアクセスできません。フレンド情報を更新してください。"
    /// The server rejects every request with 401 once a token is expired or
    /// revoked. This used to be reported to the user as the exact same
    /// generic "can't connect" message as a real network failure — actively
    /// misleading, since retrying, rebuilding, or waiting does nothing for
    /// an expired token; only signing out and back in (which issues a fresh
    /// one) fixes it. A real report matched this exactly: the same error
    /// kept appearing no matter how many times the app was rebuilt.
    private static let authExpiredErrorMessage = "ログインの有効期限が切れています。一度サインアウトし、もう一度サインインしてください。"

    /// A 401 specifically — the one status the server only ever returns for
    /// an expired, invalid, or revoked token (see chat.js's auth gate),
    /// never for an ordinary network failure or a busy server.
    private static func isAuthFailure(_ error: Error) -> Bool {
        (error as? FriendChatService.ServerError)?.status == 401
    }

    /// On recovery, clears `errorMessage` *only* when it's still showing one
    /// of these two known messages — a stale "can't connect"/"login
    /// expired" that would otherwise sit on screen forever once the
    /// underlying problem actually resolves (a real report: the background
    /// poll every 2 seconds was succeeding the whole time, but nothing ever
    /// told the alert that). Deliberately narrower than "clear on any
    /// success": `errorMessage` is shared with other flows (add/accept/
    /// reject), and a background poll succeeding a moment later must never
    /// silently wipe out a *different*, not-yet-seen error from one of
    /// those — only these two specific messages are something a later poll
    /// success is actually evidence against.
    ///
    /// An auth failure also skips the usual "wait for `pollFailureAlertThreshold`
    /// consecutive failures before saying anything" damping that a plain
    /// connectivity blip gets: once a token is invalid, every retry fails
    /// identically, so there's nothing to be gained by waiting, and every
    /// extra attempt just delays the one thing that actually helps — the
    /// user finding out they need to re-sign in.
    private func notePollResult(_ key: String, succeeded: Bool, error: Error? = nil) {
        if succeeded {
            consecutivePollFailures[key] = 0
            hasNotifiedAuthExpired = false
            if errorMessage == Self.connectivityErrorMessage || errorMessage == Self.authExpiredErrorMessage
                || (key == "messages" && errorMessage == Self.roomAccessErrorMessage) {
                errorMessage = ""
            }
            return
        }
        if let error, Self.isAuthFailure(error) {
            guard !hasNotifiedAuthExpired else { return }
            hasNotifiedAuthExpired = true
            errorMessage = Self.authExpiredErrorMessage
            return
        }
        if let serverError = error as? FriendChatService.ServerError, serverError.status == 403 {
            errorMessage = Self.roomAccessErrorMessage
            return
        }
        let count = (consecutivePollFailures[key] ?? 0) + 1
        consecutivePollFailures[key] = count
        if count == Self.pollFailureAlertThreshold {
            errorMessage = Self.connectivityErrorMessage
        }
    }

    /// Uploads an attachment's bytes to the room so the other participant —
    /// who has no access to this device's local files or app database — can
    /// actually retrieve it. Returns nil on failure, in which case the
    /// attachment falls back to being openable only from the sender's own
    /// local copy (the same as before this existed) — surfacing an error so
    /// the sender actually learns that fallback happened, instead of
    /// believing the attachment sent normally to both sides.
    func uploadAttachment(data: Data, contentType: String, roomID: String) async -> String? {
        do {
            return try await client.uploadAttachment(roomID: roomID, contentType: contentType, data: data).id
        } catch {
            errorMessage = "添付ファイルを送信できませんでした。相手の端末では開けない可能性があります。"
            return nil
        }
    }

    /// Downloads an attachment's bytes from the room — used when the local
    /// copy isn't available (e.g. this device is the recipient, which never
    /// had the file locally). Returns nil on failure.
    func downloadAttachment(roomID: String, id: String) async -> Data? {
        try? await client.downloadAttachment(roomID: roomID, id: id)
    }

    /// Reports this device's own study time for today, so friends can see it
    /// in their own friends list. Fire-and-forget: a missed report just
    /// means friends see a stale value until the next successful one.
    func reportMyStudyTime(_ seconds: TimeInterval, sharesStudyTime: Bool = true) {
        Task {
            let name = defaults.string(forKey: "profileName") ?? "Studiquoユーザー"
            _ = try? await client.register(
                name: name,
                todayStudySeconds: sharesStudyTime ? Int(seconds) : nil,
                studyDate: sharesStudyTime ? Self.todayDateKey() : nil
            )
        }
    }

    /// The device's own local calendar day, as "yyyy-MM-dd". Used both to
    /// report this user's own study time and to decide whether a friend's
    /// reported study time is still fresh — the server just stores and
    /// relays whatever date the reporting device sent, so "is this today"
    /// is always judged from the viewer's own clock, not the server's.
    private static func todayDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Merges freshly-fetched friend data into the existing list, reusing
    /// each already-known friend's `id` instead of minting a new UUID every
    /// time. Without this, polling this repeatedly would reassign every
    /// friend a new id on each call, silently orphaning their accumulated
    /// `messages` (keyed by `friendID`) and `unreadCounts` (keyed by `id`).
    private static func mergedFriends(existing: [FriendRecord], remote: [FriendChatService.Friend]) -> [FriendRecord] {
        let today = todayDateKey()
        let demos = existing.filter { $0.isDemo == true }
        let mapped = remote.map { item -> FriendRecord in
            let hasFreshSharedStudyTime = item.studyDate == today && item.todayStudySeconds != nil
            let freshSeconds = hasFreshSharedStudyTime ? (item.todayStudySeconds ?? 0) : 0
            if let match = existing.first(where: { $0.isDemo != true && $0.code == item.code }) {
                var updated = match
                updated.name = item.name
                updated.roomID = item.roomID
                updated.todayStudySeconds = freshSeconds
                updated.sharesStudyTime = hasFreshSharedStudyTime
                // `avatarData`/`avatarUpdatedAt` deliberately untouched here:
                // they track what's actually cached, and this is a pure,
                // synchronous merge that can't make the network call a
                // changed photo would need. `syncFriendAvatarsIfNeeded`
                // compares `item.avatarUpdatedAt` (the server's current
                // value, not persisted on the record until then) against
                // what's cached and downloads the difference.
                return updated
            }
            return FriendRecord(
                id: UUID(), name: item.name, code: item.code,
                todayStudySeconds: freshSeconds, roomID: item.roomID,
                isDemo: false, sharesStudyTime: hasFreshSharedStudyTime
            )
        }
        return demos + mapped
    }

    private func applyRemoteFriends(_ remote: [FriendChatService.Friend]) {
        let serverCodes = Set(remote.map(\.code))
        locallyRemovedCodes.formIntersection(serverCodes)
        let visibleRemote = remote.filter { !locallyRemovedCodes.contains($0.code) }
        let visibleCodes = Set(visibleRemote.map(\.code))
        let removed = friends.filter { $0.isDemo != true && !visibleCodes.contains($0.code) }
        for friend in removed { archiveFriend(friend) }
        friends = Self.mergedFriends(existing: friends + archivedFriends, remote: visibleRemote)
        archivedFriends.removeAll { visibleCodes.contains($0.code) }
    }

    private func archiveFriend(_ friend: FriendRecord) {
        archivedFriends.removeAll { $0.code == friend.code }
        archivedFriends.append(friend)
        unreadCounts.removeValue(forKey: friend.id)
        if activeFriendID == friend.id { activeFriendID = nil }
        friends.removeAll { $0.id == friend.id }
    }

    func refreshBlockedContacts() async {
        do {
            let remote = try await client.blockedContacts()
            blockedContacts = remote
            blockedByMeRoomIDs = Set(remote.map(\.roomID))
        } catch {
            errorMessage = "ブロック一覧を読み込めませんでした。もう一度お試しください。"
        }
    }

    @discardableResult
    func removeFriend(_ contact: FriendChatService.BlockedContact) async -> Bool {
        guard friends.contains(where: { $0.code == contact.code }),
              !pendingRemovalCodes.contains(contact.code) else { return false }
        pendingRemovalCodes.insert(contact.code)
        defer { pendingRemovalCodes.remove(contact.code) }
        do {
            _ = try await client.removeFriend(code: contact.code)
            locallyRemovedCodes.insert(contact.code)
            if let friend = friends.first(where: { $0.code == contact.code }) {
                archiveFriend(friend)
            }
            await refreshBlockedContacts()
            return true
        } catch {
            errorMessage = "フレンドを削除できませんでした。もう一度お試しください。"
            return false
        }
    }

    func refreshInbox() async {
        guard !friends.isEmpty || !archivedFriends.isEmpty else { return }
        let states: [FriendChatService.InboxState]
        do {
            states = try await client.inbox()
        } catch {
            notePollResult("inbox", succeeded: false, error: error)
            return
        }
        notePollResult("inbox", succeeded: true)
        for state in states {
            if state.closed != true,
               let archived = archivedFriends.first(where: { $0.roomID == state.roomID }),
               locallyRemovedCodes.contains(archived.code) {
                // A new friendship reopened this retained room. Allow the
                // archived contact back even if an earlier friends-list
                // response was still showing the just-deleted relationship.
                locallyRemovedCodes.remove(archived.code)
                await refreshFriends()
            }
            guard let friend = friends.first(where: { $0.roomID == state.roomID }) else { continue }
            if state.closed == true {
                locallyRemovedCodes.insert(friend.code)
                archiveFriend(friend)
                continue
            }
            let newestLocalID = messages.filter { $0.friendID == friend.id && $0.roomID == state.roomID }
                .compactMap(\.serverID).max() ?? 0
            if state.latestID > newestLocalID { await refreshMessages(for: friend) }
            unreadCounts[friend.id] = activeFriendID == friend.id ? 0 : state.unreadCount
        }
    }

    func refreshIncomingRequests() async {
        do {
            let remote = try await client.incomingRequests()
            notePollResult("incomingRequests", succeeded: true)
            incomingRequests = remote.map {
                IncomingFriendRequest(code: $0.code, name: $0.name, requestedAt: Date(timeIntervalSince1970: $0.requestedAt / 1_000))
            }
            let currentCodes = Set(incomingRequests.map(\.code))
            unseenIncomingRequestCount = currentCodes.subtracting(seenIncomingRequestCodes).count
            // Bounded to whatever's actually still pending — otherwise this set
            // would only ever grow for the lifetime of the install.
            seenIncomingRequestCodes.formIntersection(currentCodes)
        } catch {
            notePollResult("incomingRequests", succeeded: false, error: error)
        }
    }

    /// The requests this user has sent that are still awaiting the
    /// recipient's approval — shown in the add-friend screen so sending a
    /// request doesn't feel like it vanished into nothing.
    func refreshOutgoingRequests() async {
        do {
            let remote = try await client.outgoingRequests()
            notePollResult("outgoingRequests", succeeded: true)
            outgoingRequests = remote.map {
                OutgoingFriendRequest(code: $0.code, name: $0.name, requestedAt: Date(timeIntervalSince1970: $0.requestedAt / 1_000))
            }
        } catch {
            notePollResult("outgoingRequests", succeeded: false, error: error)
        }
    }

    /// Sends a one-directional request; the recipient must accept it (see
    /// `accept`) before they become a mutual friend. Fire-and-forget — for a
    /// caller that wants to know whether it actually succeeded (the
    /// add-friend sheet, so it can wait before dismissing), use `addAndWait`.
    func add(code raw: String) {
        Task { _ = await addAndWait(code: raw) }
    }

    /// Groups this user has actually joined — never one they've only been
    /// invited to (see `refreshGroupInvites`).
    func refreshGroups() async {
        do {
            groups = try await client.groups()
            notePollResult("groups", succeeded: true)
        } catch {
            notePollResult("groups", succeeded: false, error: error)
        }
    }

    /// This user's own still-unanswered group invitations.
    func refreshGroupInvites() async {
        do {
            incomingGroupInvites = try await client.groupInvites()
            notePollResult("groupInvites", succeeded: true)
        } catch {
            notePollResult("groupInvites", succeeded: false, error: error)
        }
    }

    /// Creates a group with `memberCodes` (all of which must already be this
    /// user's own friends) — the caller joins immediately, everyone else
    /// gets a pending invite (see `acceptGroupInvite`/`rejectGroupInvite`).
    @discardableResult
    func createGroup(name: String, memberCodes: [String]) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let created = try await client.createGroup(name: trimmed, memberCodes: memberCodes)
            if !groups.contains(where: { $0.roomID == created.roomID }) { groups.append(created) }
            errorMessage = ""
            return true
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "グループを作成できませんでした。")
            return false
        } catch {
            errorMessage = "グループを作成できませんでした。"
            return false
        }
    }

    /// Invites one of this user's own friends into a group they're already
    /// in — like creation, this only ever creates a pending invite.
    @discardableResult
    func inviteToGroup(roomID: String, code: String) async -> Bool {
        do {
            _ = try await client.inviteToGroup(roomID: roomID, code: code)
            errorMessage = ""
            return true
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "招待できませんでした。")
            return false
        } catch {
            errorMessage = "招待できませんでした。"
            return false
        }
    }

    func acceptGroupInvite(_ invite: FriendChatService.GroupInvite) {
        guard !pendingGroupActions.contains(invite.roomID) else { return }
        pendingGroupActions.insert(invite.roomID)
        Task {
            defer { pendingGroupActions.remove(invite.roomID) }
            do {
                let joined = try await client.acceptGroupInvite(roomID: invite.roomID)
                if !groups.contains(where: { $0.roomID == joined.roomID }) { groups.append(joined) }
                incomingGroupInvites.removeAll { $0.roomID == invite.roomID }
                errorMessage = ""
            } catch let error as FriendChatService.ServerError {
                errorMessage = Self.message(for: error, fallback: "招待を承認できませんでした。")
            } catch {
                errorMessage = "招待を承認できませんでした。"
            }
        }
    }

    func rejectGroupInvite(_ invite: FriendChatService.GroupInvite) {
        guard !pendingGroupActions.contains(invite.roomID) else { return }
        pendingGroupActions.insert(invite.roomID)
        Task {
            defer { pendingGroupActions.remove(invite.roomID) }
            do {
                _ = try await client.rejectGroupInvite(roomID: invite.roomID)
                incomingGroupInvites.removeAll { $0.roomID == invite.roomID }
                errorMessage = ""
            } catch let error as FriendChatService.ServerError {
                errorMessage = Self.message(for: error, fallback: "招待を拒否できませんでした。")
            } catch {
                errorMessage = "招待を拒否できませんでした。"
            }
        }
    }

    @discardableResult
    func renameGroup(roomID: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await client.renameGroup(roomID: roomID, name: trimmed)
            if let index = groups.firstIndex(where: { $0.roomID == roomID }) {
                groups[index] = FriendChatService.Group(roomID: roomID, name: trimmed, members: groups[index].members)
            }
            errorMessage = ""
            return true
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "グループ名を変更できませんでした。")
            return false
        } catch {
            errorMessage = "グループ名を変更できませんでした。"
            return false
        }
    }

    /// Leaving (code == this user's own) and removing another member are the
    /// same call — any current member may do either.
    @discardableResult
    func removeGroupMember(roomID: String, code: String) async -> Bool {
        guard !pendingGroupActions.contains(roomID) else { return false }
        pendingGroupActions.insert(roomID)
        defer { pendingGroupActions.remove(roomID) }
        do {
            _ = try await client.removeGroupMember(roomID: roomID, code: code)
            if code == myCode {
                groups.removeAll { $0.roomID == roomID }
            } else if let index = groups.firstIndex(where: { $0.roomID == roomID }) {
                groups[index] = FriendChatService.Group(
                    roomID: roomID, name: groups[index].name,
                    members: groups[index].members.filter { $0.code != code }
                )
            }
            errorMessage = ""
            return true
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "メンバーを削除できませんでした。")
            return false
        } catch {
            errorMessage = "メンバーを削除できませんでした。"
            return false
        }
    }

    /// Fetches whatever's new in a group's conversation since the last
    /// fetch — called on-demand from the group chat screen (see
    /// `GroupChatView`'s own polling `.task`), not from the app-wide poll,
    /// since re-fetching every joined group's full history in the
    /// background would be wasted work for groups nobody's currently
    /// looking at.
    func refreshGroupMessages(roomID: String) async {
        do {
            let after = groupMessages[roomID]?.last?.id ?? 0
            let newOnes = try await client.messages(roomID: roomID, after: after)
            guard !newOnes.isEmpty else { return }
            var current = groupMessages[roomID] ?? []
            let existingIDs = Set(current.map(\.id))
            current.append(contentsOf: newOnes.filter { !existingIDs.contains($0.id) })
            groupMessages[roomID] = current
        } catch {
            // Deliberately silent: this polls every couple of seconds while
            // the screen is open, and a transient blip shouldn't flash an
            // alert — the next poll a moment later almost always recovers.
        }
    }

    @discardableResult
    func sendGroupMessage(_ text: String, roomID: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumMessageLength else { return false }
        do {
            let sent = try await client.send(trimmed, roomID: roomID, clientMessageID: UUID().uuidString)
            var current = groupMessages[roomID] ?? []
            if !current.contains(where: { $0.id == sent.id }) { current.append(sent) }
            groupMessages[roomID] = current
            errorMessage = ""
            return true
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "送信できませんでした。")
            return false
        } catch {
            errorMessage = "送信できませんでした。"
            return false
        }
    }

    /// Same as `add`, but awaits the result and reports whether it
    /// succeeded, instead of dismissing (or not) before the network call
    /// even returns.
    @discardableResult
    func addAndWait(code raw: String) async -> Bool {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.wholeMatch(of: Self.codePattern) != nil,
              code != myCode,
              friends.count < Self.maximumFriends,
              !friends.contains(where: { $0.code == code }) else { return false }
        do {
            _ = try await client.add(code: code)
            errorMessage = ""
            // Just the outgoing list (the new pending request) and friends
            // (in case the server reports already_friends) need updating —
            // refresh() would also needlessly re-register the profile name,
            // which hasn't changed just because a request was sent.
            await refreshOutgoingRequests()
            await refreshFriends()
            return true
        } catch is FriendChatService.RateLimitedError {
            errorMessage = "フレンド申請の送信回数が上限に達しました。しばらくしてからもう一度お試しください。"
            return false
        } catch let error as FriendChatService.ServerError {
            errorMessage = Self.message(for: error, fallback: "フレンドコードが見つかりません。")
            return false
        } catch {
            errorMessage = "フレンドコードが見つかりません。"
            return false
        }
    }

    func accept(_ request: IncomingFriendRequest) {
        guard !pendingRequestActions.contains(request.code) else { return }
        pendingRequestActions.insert(request.code)
        Task {
            defer { pendingRequestActions.remove(request.code) }
            do {
                let friend = try await client.accept(code: request.code)
                // A refresh() landing in between the request and this
                // response can result in this friend already being present
                // — don't add a second, duplicate entry.
                if !friends.contains(where: { $0.code == friend.code }) {
                    friends.append(FriendRecord(id: UUID(), name: friend.name, code: friend.code, todayStudySeconds: 0, roomID: friend.roomID, isDemo: false, sharesStudyTime: false))
                }
                incomingRequests.removeAll { $0.code == request.code }
                errorMessage = ""
            } catch let error as FriendChatService.ServerError {
                errorMessage = Self.message(for: error, fallback: "フレンド申請を承認できませんでした。")
            } catch {
                errorMessage = "フレンド申請を承認できませんでした。"
            }
        }
    }

    func reject(_ request: IncomingFriendRequest) {
        guard !pendingRequestActions.contains(request.code) else { return }
        pendingRequestActions.insert(request.code)
        Task {
            defer { pendingRequestActions.remove(request.code) }
            do {
                _ = try await client.reject(code: request.code)
                incomingRequests.removeAll { $0.code == request.code }
                errorMessage = ""
            } catch let error as FriendChatService.ServerError {
                errorMessage = Self.message(for: error, fallback: "フレンド申請を拒否できませんでした。")
            } catch {
                errorMessage = "フレンド申請を拒否できませんでした。"
            }
        }
    }

    /// Maps the server's own (English) error message to the Japanese text
    /// shown in the UI, falling back to a generic message for anything not
    /// specifically recognized (a new server-side message, a network-layer
    /// decode failure, etc.).
    private static func message(for error: FriendChatService.ServerError, fallback: String) -> String {
        switch error.message {
        case "You cannot add yourself as a friend.":
            return "自分自身をフレンドに追加することはできません。"
        case "You cannot accept a request from yourself.":
            return "自分自身の申請を承認することはできません。"
        case "Friend list is full.":
            return "フレンドの上限に達しているため追加できません。"
        case "Invalid code.":
            return "コードの形式が正しくありません。"
        case "Friend not found.", "Request not found.":
            return "フレンドコードが見つかりません。"
        case "This invite link is no longer valid.":
            return "この招待リンクは無効です。"
        case "Group name is required.":
            return "グループ名を入力してください。"
        case "You can only invite your own friends.":
            return "自分の友達だけを招待できます。"
        case "This group is full.":
            return "このグループは満員です。"
        case "Already a member of this group.":
            return "すでにこのグループのメンバーです。"
        case "Invitation not found.":
            return "招待が見つかりません。"
        case "Member not found.":
            return "メンバーが見つかりません。"
        case "You are not a member of this group.":
            return "このグループのメンバーではありません。"
        default:
            return fallback
        }
    }

    func addDemoFriend() {
        guard !friends.contains(where: { $0.isDemo == true }) else { return }
        friends.append(FriendRecord(id: UUID(), name: "デモフレンド", code: "DEMO123", todayStudySeconds: 3_600, roomID: nil, isDemo: true, sharesStudyTime: true))
    }

    /// A friend-add code carried in an *old-format* `studiquo://friend/add?code=…`
    /// link, waiting on the student's confirmation before an actual request
    /// is sent — see `add(url:)`. `nil` when there is nothing to confirm.
    /// Current links use `?token=…` instead (`pendingLinkToken`); this stays
    /// around only so a link shared before that change still works.
    @Published var pendingDeepLinkCode: String?

    /// A link/QR-only invite token (see `myLinkToken`'s doc comment) waiting
    /// on the student's confirmation before it's actually redeemed — see
    /// `add(url:)`/`confirmPendingLinkAdd()`. `nil` when there is nothing to
    /// confirm.
    @Published var pendingLinkToken: String?

    /// Opening a `studiquo://friend/add?...` link used to send the friend
    /// request immediately, with no confirmation — a link crafted by
    /// someone else (a message, a QR code) could act the instant it was
    /// tapped, before the student had any chance to see who or what it was
    /// for. Both formats only ever stage something here; `FriendsHomeView`
    /// shows a confirmation alert, and nothing happens unless the student
    /// accepts it there.
    func add(url: URL) {
        guard url.scheme?.lowercased() == "studiquo",
              url.host?.lowercased() == "friend",
              url.path == "/add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        if let token = items.first(where: { $0.name == "token" })?.value {
            pendingLinkToken = token
        } else if let code = items.first(where: { $0.name == "code" })?.value {
            pendingDeepLinkCode = code
        }
    }

    func confirmPendingDeepLinkRequest() {
        guard let code = pendingDeepLinkCode else { return }
        pendingDeepLinkCode = nil
        add(code: code)
    }

    func cancelPendingDeepLinkRequest() {
        pendingDeepLinkCode = nil
    }

    /// Redeems `pendingLinkToken` for an immediate, mutual friendship — no
    /// pending request, no separate accept step on either side; actually
    /// having received the link/QR (the only way to ever learn its token)
    /// is treated as consent enough. See `myLinkToken`'s doc comment for why
    /// this has to be a different mechanism from `confirmPendingDeepLinkRequest()`.
    func confirmPendingLinkAdd() {
        guard let token = pendingLinkToken else { return }
        pendingLinkToken = nil
        guard token != myLinkToken else {
            errorMessage = "自分自身をフレンドに追加することはできません。"
            return
        }
        Task {
            do {
                let result = try await client.addViaLink(token: token)
                if !friends.contains(where: { $0.code == result.code }) {
                    friends.append(FriendRecord(id: UUID(), name: result.name, code: result.code, todayStudySeconds: 0, roomID: result.roomID, isDemo: false, sharesStudyTime: false))
                }
                errorMessage = ""
            } catch is FriendChatService.RateLimitedError {
                errorMessage = "フレンド申請の送信回数が上限に達しました。しばらくしてからもう一度お試しください。"
            } catch let error as FriendChatService.ServerError {
                errorMessage = Self.message(for: error, fallback: "この招待リンクは無効です。")
            } catch {
                errorMessage = "この招待リンクは無効です。"
            }
        }
    }

    func cancelPendingLinkAdd() {
        pendingLinkToken = nil
    }

    @discardableResult
    func send(_ text: String, to friend: FriendRecord) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recipient = canonicalFriend(matching: friend), Self.hasVisibleContent(cleaned) else { return false }
        let messageText = String(cleaned.prefix(Self.maximumMessageLength))
        let messageID = UUID()
        var working = messages
        working.append(FriendMessage(
            id: messageID, friendID: recipient.id,
            text: messageText, sentAt: Date(), isMine: true, isCanceled: false,
            roomID: recipient.roomID
        ))
        let (trimmedMessages, evicted) = Self.trimmed(working, for: recipient.id)
        messages = trimmedMessages
        Self.deleteLocalAttachmentFiles(for: evicted)
        if recipient.isDemo == true {
            Task {
                try? await Task.sleep(for: .seconds(1))
                messages.append(FriendMessage(id: UUID(), friendID: recipient.id, text: "メッセージを受け取りました！これはデモ返信です。", sentAt: Date(), isMine: false, isCanceled: false))
                // Mirrors how a real incoming message affects unreadCounts
                // in refreshMessages — without this, the demo reply never
                // showed up as unread even while its chat wasn't open.
                if activeFriendID == recipient.id {
                    unreadCounts[recipient.id] = 0
                } else {
                    unreadCounts[recipient.id, default: 0] += 1
                }
            }
        } else {
            guard let roomID = recipient.roomID else {
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[index].sendFailed = true
                }
                errorMessage = "メッセージを送信できませんでした。フレンド情報を更新してからもう一度お試しください。"
                return true
            }
            Task {
                do {
                    let sent = try await client.send(messageText, roomID: roomID, clientMessageID: messageID.uuidString)
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].serverID = sent.id
                        messages[index].roomID = roomID
                        messages[index].sentAt = Date(timeIntervalSince1970: sent.sentAt / 1_000)
                        messages[index].text = sent.text
                        messages[index].isCanceled = sent.isCanceled == true
                        messages[index].sendFailed = nil
                    }
                    // There's no way to actually stop an HTTP request that's
                    // already been issued — but if the user canceled this
                    // message while it was still in flight (see `cancel`),
                    // it now has the serverID needed to retract it for
                    // real, the moment it exists, instead of silently
                    // letting it reach the recipient uncanceled.
                    if pendingCancellations.remove(messageID) != nil {
                        _ = try? await client.cancelMessage(roomID: roomID, messageID: sent.id)
                    }
                    await refreshMessages(for: recipient)
                } catch is FriendChatService.RateLimitedError {
                    pendingCancellations.remove(messageID)
                    errorMessage = "メッセージの送信回数が上限に達しました。しばらくしてからもう一度お試しください。"
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].sendFailed = true
                    }
                } catch let error as FriendChatService.ServerError where error.status == 403 {
                    pendingCancellations.remove(messageID)
                    errorMessage = Self.roomAccessErrorMessage
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].sendFailed = true
                    }
                    await refreshFriends()
                } catch {
                    pendingCancellations.remove(messageID)
                    errorMessage = "メッセージを送信できませんでした。"
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].sendFailed = true
                    }
                }
            }
        }
        return true
    }

    /// Message ids canceled while still in flight (no `serverID` yet) — see
    /// `cancel`. Checked once the pending `send` Task above actually
    /// completes, so the retraction still happens for real once there's a
    /// serverID to retract.
    private var pendingCancellations: Set<UUID> = []

    func markRead(_ friend: FriendRecord) {
        unreadCounts[friend.id] = 0
        activeFriendID = friend.id
        Task { await markDisplayedMessagesRead(for: friend) }
    }

    private func markDisplayedMessagesRead(for friend: FriendRecord) async {
        guard let roomID = canonicalFriend(matching: friend)?.roomID else { return }
        let latestDisplayedID = messages(for: friend).compactMap(\.serverID).max() ?? 0
        guard latestDisplayedID > 0 else { return }
        _ = try? await client.markRead(roomID: roomID, throughID: latestDisplayedID)
    }

    /// Retracts one of this user's own messages for real: once the server
    /// confirms it, the recipient (and this user's own data on a fresh
    /// install) stops being able to see the original content — not just
    /// this device's own display of it. Hides it locally right away for a
    /// responsive UI, then reverts and surfaces an error if the server call
    /// actually fails, rather than silently leaving a "canceled" bubble
    /// that the recipient can still see in full.
    ///
    /// A message that hasn't been confirmed by the server yet (no
    /// `serverID`) has nothing to retract there yet — the in-flight send
    /// itself can't actually be stopped (there's no way to un-send an HTTP
    /// request already issued), so this hides it locally now and records
    /// it as a pending cancellation; once that send completes and a
    /// serverID exists, `send`'s own completion handler retracts it
    /// server-side at that point instead of leaving it to quietly reach
    /// the recipient uncanceled.
    func cancel(_ message: FriendMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              messages[index].isMine,
              messages[index].isCanceled != true else { return }
        let originalText = messages[index].text
        let friendID = messages[index].friendID
        let serverID = messages[index].serverID
        messages[index].text = ""
        messages[index].isCanceled = true

        guard let roomID = friends.first(where: { $0.id == friendID })?.roomID else { return }
        guard let serverID else {
            pendingCancellations.insert(message.id)
            return
        }
        Task {
            do {
                _ = try await client.cancelMessage(roomID: roomID, messageID: serverID)
            } catch {
                if let revertIndex = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[revertIndex].text = originalText
                    messages[revertIndex].isCanceled = false
                }
                errorMessage = "メッセージを取り消せませんでした。もう一度お試しください。"
            }
        }
    }

    /// Refreshes whether this user currently has `friend` blocked, so the
    /// chat screen can show the right "ブロックする"/"ブロック解除する"
    /// label without waiting for a block/unblock action to find out.
    func refreshBlockStatus(for friend: FriendRecord) async {
        guard let roomID = friends.first(where: { $0.id == friend.id })?.roomID else { return }
        guard let status = try? await client.blockStatus(roomID: roomID) else { return }
        if status.blockedByMe {
            blockedByMeRoomIDs.insert(roomID)
        } else {
            blockedByMeRoomIDs.remove(roomID)
        }
    }

    func block(_ friend: FriendRecord) {
        guard let roomID = friends.first(where: { $0.id == friend.id })?.roomID else { return }
        Task {
            do {
                _ = try await client.block(roomID: roomID)
                blockedByMeRoomIDs.insert(roomID)
                await refreshBlockedContacts()
            } catch {
                errorMessage = "ブロックできませんでした。もう一度お試しください。"
            }
        }
    }

    func unblock(_ friend: FriendRecord) {
        guard let roomID = friends.first(where: { $0.id == friend.id })?.roomID else { return }
        Task {
            do {
                _ = try await client.unblock(roomID: roomID)
                blockedByMeRoomIDs.remove(roomID)
                await refreshBlockedContacts()
            } catch {
                errorMessage = "ブロックを解除できませんでした。もう一度お試しください。"
            }
        }
    }

    func unblock(_ contact: FriendChatService.BlockedContact) {
        Task {
            do {
                _ = try await client.unblock(roomID: contact.roomID)
                blockedByMeRoomIDs.remove(contact.roomID)
                blockedContacts.removeAll { $0.code == contact.code }
            } catch {
                errorMessage = "ブロックを解除できませんでした。もう一度お試しください。"
            }
        }
    }

    /// Records a report for manual review — there is no in-app moderation
    /// queue yet (see `FriendChatService.report`'s own doc comment), so this
    /// doesn't hide the message or otherwise change what either side sees;
    /// it only tells the server to persist it somewhere reviewable.
    func report(_ message: FriendMessage, reason: String) {
        guard let roomID = friends.first(where: { $0.id == message.friendID })?.roomID,
              let serverID = message.serverID else { return }
        Task {
            do {
                _ = try await client.report(roomID: roomID, messageID: serverID, reason: reason)
            } catch {
                errorMessage = "通報を送信できませんでした。もう一度お試しください。"
            }
        }
    }

    /// Attachments this user has sent that still use the pre-PDF-fix scheme
    /// — candidates `repairLegacyAttachments` can fix, provided the original
    /// material is still on this device.
    func legacyAttachmentMessages(for friend: FriendRecord) -> [(message: FriendMessage, attachment: FriendMessageAttachment)] {
        messages(for: friend).flatMap { message -> [(FriendMessage, FriendMessageAttachment)] in
            guard message.isMine, message.isCanceled != true else { return [] }
            return FriendMessageAttachment.legacyAttachments(in: message.text).map { (message, $0) }
        }
    }

    /// Repairs this user's own past messages that still reference a material
    /// only via a local, off-device id — from before attachments could be
    /// uploaded at all, so the recipient could never open them (see
    /// `legacyAttachmentMessages`). `resolve` is exactly the closure the
    /// composer already uses to turn a freshly attached material into an
    /// uploaded PDF (`resolvedAppMessageAttachment` in ContentView.swift/
    /// NoteEditorView.swift); reusing it here renders and uploads a legacy
    /// attachment exactly the same way a brand-new one would be. A material
    /// no longer on this device (deleted since) can't be repaired — `resolve`
    /// returns it unchanged in that case, and it's simply skipped.
    func repairLegacyAttachments(
        for friend: FriendRecord, resolve: (FriendMessageAttachment, FriendRecord) async -> FriendMessageAttachment
    ) async {
        guard friend.isDemo != true, let roomID = friend.roomID else { return }
        for (message, attachment) in legacyAttachmentMessages(for: friend) {
            guard let serverID = message.serverID else { continue }
            // `resolve` only knows how to re-render an in-app material
            // (notebook/deck/document/slide) — it returns anything else
            // unchanged. A legacy photo, scanned page, or imported file was
            // always just flat bytes on disk, never a SwiftData model, so
            // there's nothing for it to render: re-uploading the bytes
            // still sitting at its own `sourcePath` is the repair for those.
            var repaired = await resolve(attachment, friend)
            if repaired.remoteRoomID == nil {
                repaired = await repairedFileBackedAttachment(attachment, roomID: roomID) ?? repaired
            }
            guard repaired.remoteRoomID != nil else { continue }
            let newText = FriendMessageAttachment.textReplacingAttachment(in: message.text, id: attachment.id, with: repaired)
            guard newText != message.text,
                  (try? await client.editMessage(roomID: roomID, messageID: serverID, text: newText)) != nil
            else { continue }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].text = newText
            }
        }
    }

    /// Repairs a legacy attachment that was always just a flat file on this
    /// device — a photo, a scanned page, an imported document — by
    /// re-uploading the exact bytes still at its own `sourcePath`, with no
    /// rendering involved. `nil` if that file is gone (deleted since) or
    /// the upload itself fails, the same "can't repair, leave it" outcome
    /// `resolve` reports for a deleted in-app material.
    private func repairedFileBackedAttachment(_ attachment: FriendMessageAttachment, roomID: String) async -> FriendMessageAttachment? {
        guard let sourcePath = attachment.sourcePath, !sourcePath.isEmpty,
              FileManager.default.fileExists(atPath: sourcePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath))
        else { return nil }
        let contentType = UTType(filenameExtension: URL(fileURLWithPath: sourcePath).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        guard let remoteID = await uploadAttachment(data: data, contentType: contentType, roomID: roomID) else { return nil }
        return FriendMessageAttachment(
            id: attachment.id, title: attachment.title, kind: attachment.kind, icon: attachment.icon,
            sourceKind: attachment.resolvedSourceKind, sourceID: remoteID, sourcePath: sourcePath, remoteRoomID: roomID
        )
    }

    /// Catches this device up on repairs made to messages old enough to have
    /// scrolled out of `refreshMessages`'s normal rolling reconcile window —
    /// without this, a message repaired by its sender long ago would never
    /// be re-fetched by a recipient who already has plenty of newer messages
    /// cached. Safe to call regardless of who sent the message.
    func reconcileLegacyAttachments(for friend: FriendRecord) async {
        guard friend.isDemo != true, let roomID = friend.roomID else { return }
        let candidateIDs = messages(for: friend).compactMap { message -> Int? in
            guard let serverID = message.serverID, message.isCanceled != true,
                  !FriendMessageAttachment.legacyAttachments(in: message.text).isEmpty else { return nil }
            return serverID
        }
        guard !candidateIDs.isEmpty, let remote = try? await client.messages(roomID: roomID, ids: candidateIDs) else { return }
        var working = messages
        for item in remote {
            guard let index = working.firstIndex(where: { $0.friendID == friend.id && $0.serverID == item.id }) else { continue }
            if item.isCanceled == true, working[index].isCanceled != true {
                working[index].text = ""
                working[index].isCanceled = true
            } else if item.text != working[index].text {
                working[index].text = item.text
            }
        }
        messages = working
    }

    func stopReading(_ friend: FriendRecord) {
        if activeFriendID == friend.id { activeFriendID = nil }
    }

    var totalUnreadCount: Int {
        unreadCounts.values.reduce(0, +)
    }

    func messages(for friend: FriendRecord) -> [FriendMessage] {
        let roomID = canonicalFriend(matching: friend)?.roomID ?? friend.roomID
        return messages.filter { $0.friendID == friend.id && ($0.roomID == nil || $0.roomID == roomID) }
            .sorted { $0.sentAt < $1.sentAt }
    }

    private func canonicalFriend(matching friend: FriendRecord) -> FriendRecord? {
        friends.first(where: { $0.id == friend.id })
            ?? friends.first(where: { $0.roomID != nil && $0.roomID == friend.roomID })
            ?? friends.first(where: { $0.code == friend.code && $0.roomID != nil })
            ?? friends.first(where: { $0.code == friend.code })
    }

    /// Fetches only what's new since the last-seen server message id and
    /// merges it into the existing local history, rather than replacing the
    /// whole conversation with the server's most-recent-200 window — a
    /// conversation older than that would otherwise lose its early history
    /// on every single poll. Deliberately re-requests a small trailing
    /// window of already-known ids too (`recentReconcileWindow`), not just
    /// strictly-new ones — that's what lets a just-canceled message's
    /// retraction actually reach this device: a plain "give me anything
    /// past what I already have" fetch would never learn that an id it
    /// already stored got its text cleared after the fact.
    private static let recentReconcileWindow = 20

    func refreshMessages(for friend: FriendRecord) async {
        guard let recipient = canonicalFriend(matching: friend), recipient.isDemo != true,
              let roomID = recipient.roomID else { return }
        let latestKnownServerID = messages
            .filter { $0.friendID == recipient.id && $0.roomID == roomID }
            .compactMap(\.serverID).max() ?? 0
        let after = max(0, latestKnownServerID - Self.recentReconcileWindow)
        let remote: [FriendChatService.Message]
        do {
            remote = try await client.messages(roomID: roomID, after: after)
        } catch {
            notePollResult("messages", succeeded: false, error: error)
            return
        }
        notePollResult("messages", succeeded: true)
        guard !remote.isEmpty else { return }

        // Mutated locally and assigned back to `messages` exactly once at
        // the end, rather than through repeated `messages[index] = ...`
        // writes in the loop below. `messages`'s didSet re-encodes and
        // persists the ENTIRE array to UserDefaults on every write to it —
        // touching it once per item in a poll that reconciles or updates
        // several messages at once (e.g. catching up after being offline)
        // used to re-serialize and rewrite the whole, potentially
        // thousands-of-messages-long history that many times over.
        var working = messages
        var newIncomingCount = 0
        for item in remote {
            // Matching by the client-generated id the message was sent with
            // is exact and order-independent, and stays authoritative even
            // for a message this device already reconciled on an earlier
            // poll — unlike the `serverID`-keyed match below, it isn't
            // gated on `serverID == nil`. `send`'s own completion handler
            // (see `send(_:to:)`) reconciles a message's `serverID` as soon
            // as its own request returns, almost always before the next
            // poll — so gating this match on `serverID == nil` meant a
            // later poll's resync of `sentAt` (below) was effectively dead
            // code, along with the reassignment this specifically covers:
            // the server settling two in-flight, identical-text messages in
            // the opposite order from how this device happened to send
            // them.
            if item.isMine, let clientMessageID = item.clientMessageID,
               let index = working.firstIndex(where: { $0.friendID == recipient.id && $0.roomID == roomID && $0.id.uuidString == clientMessageID }) {
                working[index].serverID = item.id
                working[index].roomID = roomID
                working[index].sentAt = Date(timeIntervalSince1970: item.sentAt / 1_000)
                if item.isCanceled == true, working[index].isCanceled != true {
                    working[index].text = ""
                    working[index].isCanceled = true
                } else if item.isCanceled != true, item.text != working[index].text {
                    working[index].text = item.text
                }
                continue
            }
            if item.isMine, let index = working.firstIndex(where: {
                // Falls back to text equality only for a message sent
                // before `clientMessageID` existed, or whose send request's
                // response never echoed one back — no worse than the old
                // behavior, which always matched by text alone, and still
                // limited to a message not yet reconciled by anything else.
                $0.friendID == recipient.id && $0.roomID == roomID && $0.isMine && $0.serverID == nil && $0.text == item.text
            }) {
                // Reconcile the optimistic copy created by `send` with its
                // now-confirmed server id and authoritative timestamp,
                // instead of appending a duplicate. Without also adopting
                // the server's sentAt, this message would keep sorting by
                // the sender's local clock while every other message sorts
                // by the server's — a clock skew (or just latency between
                // the optimistic append and the server ack) can then flip
                // its order relative to messages that arrived in between.
                working[index].serverID = item.id
                working[index].roomID = roomID
                working[index].sentAt = Date(timeIntervalSince1970: item.sentAt / 1_000)
                continue
            }
            if let index = working.firstIndex(where: { $0.friendID == recipient.id && $0.roomID == roomID && $0.serverID == item.id }) {
                // Already known — but the server's authoritative sentAt may
                // have shifted since this device last saw it (e.g. this is
                // itself the first poll to observe it, having missed the
                // clientMessageID-keyed match above because this message
                // predates clientMessageID), and its copy may have been
                // retracted, or edited (see `FriendStore.repairLegacyAttachments`),
                // since then too. Without this, a cancellation or repair
                // would only ever be visible to a device that hadn't
                // fetched the message yet, defeating the whole point of
                // either.
                working[index].sentAt = Date(timeIntervalSince1970: item.sentAt / 1_000)
                if item.isCanceled == true, working[index].isCanceled != true {
                    working[index].text = ""
                    working[index].isCanceled = true
                } else if item.isCanceled != true, item.text != working[index].text {
                    working[index].text = item.text
                }
                continue
            }
            working.append(FriendMessage(
                id: UUID(), friendID: recipient.id, text: item.text,
                sentAt: Date(timeIntervalSince1970: item.sentAt / 1_000),
                isMine: item.isMine, isCanceled: item.isCanceled == true, serverID: item.id,
                roomID: roomID
            ))
            if !item.isMine { newIncomingCount += 1 }
        }
        let (trimmedMessages, evicted) = Self.trimmed(working, for: recipient.id)
        messages = trimmedMessages
        Self.deleteLocalAttachmentFiles(for: evicted)

        if activeFriendID == recipient.id {
            unreadCounts[recipient.id] = 0
            await markDisplayedMessagesRead(for: recipient)
        } else if newIncomingCount > 0 {
            unreadCounts[recipient.id, default: 0] += newIncomingCount
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Trims one friend's conversation down to `maximumMessagesPerFriend`,
    /// evicting only that friend's own oldest messages — every other
    /// friend's history is left untouched no matter how large this one
    /// conversation gets. Returns the possibly-trimmed array alongside
    /// whatever got evicted, so the caller can still clean up those
    /// messages' attachment files.
    private static func trimmed(_ messages: [FriendMessage], for friendID: UUID) -> (messages: [FriendMessage], evicted: [FriendMessage]) {
        let thisFriendsCount = messages.reduce(into: 0) { count, message in if message.friendID == friendID { count += 1 } }
        var excess = thisFriendsCount - Self.maximumMessagesPerFriend
        guard excess > 0 else { return (messages, []) }
        var kept: [FriendMessage] = []
        kept.reserveCapacity(messages.count)
        var evicted: [FriendMessage] = []
        for message in messages {
            if excess > 0, message.friendID == friendID {
                evicted.append(message)
                excess -= 1
            } else {
                kept.append(message)
            }
        }
        return (kept, evicted)
    }

    /// Deletes local attachment files a just-evicted message was the last
    /// reference to — both this device's own copy of something it sent
    /// (Documents/FriendChatAttachments) and any cached copy of something
    /// it downloaded (Caches/FriendChatAttachments). Without this, trimming
    /// old messages out of `messages` (see `maximumMessagesPerFriend`) freed
    /// none of the disk space those messages' attachments were using, so it
    /// grew without bound for as long as the app kept sending/receiving
    /// photos and files. Runs off the main actor since it's pure file I/O
    /// with no need to touch any published state.
    private static func deleteLocalAttachmentFiles(for evicted: [FriendMessage]) {
        guard !evicted.isEmpty else { return }
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "FriendChatAttachments", directoryHint: .isDirectory)
            let cachedFiles = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
            for message in evicted {
                for attachment in FriendMessageParts(text: message.text).attachments {
                    if let sourcePath = attachment.sourcePath, !sourcePath.isEmpty {
                        try? fileManager.removeItem(atPath: sourcePath)
                    }
                    if let sourceID = attachment.resolvedSourceID {
                        for url in cachedFiles where url.deletingPathExtension().lastPathComponent == sourceID {
                            try? fileManager.removeItem(at: url)
                        }
                    }
                }
            }
        }
    }

    /// `.whitespacesAndNewlines` doesn't include zero-width characters (zero-
    /// width space, joiners, BOM, soft hyphen, …) — Unicode's "format"
    /// category, which is invisible by definition. Without this, a message
    /// made up entirely of such characters slips past the `isEmpty` check
    /// and gets sent as a blank-looking bubble.
    private static func hasVisibleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar.properties.generalCategory != .format
        }
    }

}

struct FriendsHomeView: View {
    @ObservedObject var store: FriendStore
    let myStudySeconds: TimeInterval
    var appAttachments: [FriendMessageAttachment] = []
    var resolveAppAttachment: (FriendMessageAttachment, FriendRecord) async -> FriendMessageAttachment = { attachment, _ in attachment }
    @AppStorage("friendShareStudyTime") private var shareStudyTime = true
    // Same keys `UserProfileView` writes — see `MyFriendCardPopover`'s doc
    // comment for why this sidebar row needs its own copy rather than
    // reading them only there.
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileImage") private var profileImageData = Data()
    @State private var showsAdd = false
    @State private var showsCreateGroup = false
    @State private var selection: FriendsDetailSelection = .chats
    @State private var popover: FriendsPopover?
    @State private var pendingReportIssue: PendingIssueReport?

    private enum FriendsDetailSelection: Hashable {
        case chats
        case chat(UUID)
        case group(String)
    }

    private enum FriendsPopover: Identifiable {
        case me
        case requests
        case profile(UUID)
        case settings
        case groupInvites

        var id: String {
            switch self {
            case .me: return "me"
            case .requests: return "requests"
            case .profile(let id): return "profile-\(id.uuidString)"
            case .settings: return "settings"
            case .groupInvites: return "groupInvites"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            friendSidebar
                .navigationTitle("フレンド")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showsAdd = true } label: { Label("フレンドを追加", systemImage: "person.badge.plus") }
                            Button { showsCreateGroup = true } label: { Label("グループを作成", systemImage: "person.3") }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { popover = .settings } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("フレンド設定")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        ReportIssueButton {
                            pendingReportIssue = PendingIssueReport(screenshot: ScreenshotCapture.captureFrontWindow())
                        }
                    }
                }
        } detail: {
            friendDetail
        }
        .sheet(isPresented: $showsAdd) { AddFriendView(store: store) }
        .sheet(isPresented: $showsCreateGroup) { CreateGroupView(store: store) }
        .sheet(item: $pendingReportIssue) { pending in ReportIssueSheet(capturedScreenshot: pending.screenshot) }
        .sheet(item: $popover) { item in
            NavigationStack {
                popoverContent(for: item)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { popover = nil }
                        }
                    }
            }
        }
        // Clears the home-screen tab badge now that the requests it was
        // counting are actually visible on screen. Incoming requests
        // themselves are kept fresh by `store`'s own app-wide poll (see
        // `FriendStore.startIncomingRequestPolling()`) — no longer this
        // screen's job alone.
        .onAppear {
            store.markIncomingRequestsSeen()
            store.reportMyStudyTime(myStudySeconds, sharesStudyTime: shareStudyTime)
        }
        .onChange(of: store.incomingRequests) { _, _ in store.markIncomingRequestsSeen() }
        .task {
            while !Task.isCancelled {
                // Without this, a friend who just accepted this user's
                // outgoing request never appears here — nothing else
                // re-fetches the friends list while this screen is open.
                // 8 seconds, not 2 — friends() looks up each friend's live
                // details by a separate KV read per friend, and this ran
                // continuously while this screen was open; see
                // FriendStore.listPollInterval's own doc comment for why
                // that was enough to exhaust the account's daily KV quota.
                await store.refreshFriends()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        // `myStudySeconds` is a plain `let` recomputed by the parent on
        // every render, not something the long-running .task above would
        // ever see update on its own — onChange is what actually reports
        // a newly-finished study session instead of a stale snapshot.
        .onChange(of: myStudySeconds) { _, newValue in
            store.reportMyStudyTime(newValue, sharesStudyTime: shareStudyTime)
        }
        .onChange(of: shareStudyTime) { _, newValue in
            store.reportMyStudyTime(myStudySeconds, sharesStudyTime: newValue)
        }
        // store.errorMessage was previously set by add/accept/reject but
        // never shown anywhere — this is the first surface that renders
        // it. FriendsHomeView stays visible underneath the add-friend
        // sheet (which dismisses immediately on tapping send), so an
        // error from add() still reaches the user here.
        .alert("エラー", isPresented: Binding(
            get: { !store.errorMessage.isEmpty },
            set: { isPresented in if !isPresented { store.errorMessage = "" } }
        )) {
            Button("OK") { store.errorMessage = "" }
        } message: {
            Text(store.errorMessage)
        }
        // An old-format studiquo://friend/add?code=… link stages a code
        // here rather than sending the request immediately — see
        // `FriendStore.add(url:)`. Current links use ?token=… instead
        // (the alert just below), which skips the approval step
        // entirely rather than merely pre-filling it.
        .alert(
            "フレンド申請を送りますか？",
            isPresented: Binding(
                get: { store.pendingDeepLinkCode != nil },
                set: { isPresented in if !isPresented { store.cancelPendingDeepLinkRequest() } }
            )
        ) {
            Button("キャンセル", role: .cancel) { store.cancelPendingDeepLinkRequest() }
            Button("送信") { store.confirmPendingDeepLinkRequest() }
        } message: {
            Text("コード「\(store.pendingDeepLinkCode ?? "")」のユーザーにフレンド申請を送ります。")
        }
        // A studiquo://friend/add?token=… link (the current invite-link
        // format) redeems immediately on confirmation — no separate
        // approval step on either side, since actually receiving the
        // link is treated as consent enough. See
        // `FriendStore.confirmPendingLinkAdd()`.
        .alert(
            "フレンドになりますか？",
            isPresented: Binding(
                get: { store.pendingLinkToken != nil },
                set: { isPresented in if !isPresented { store.cancelPendingLinkAdd() } }
            )
        ) {
            Button("キャンセル", role: .cancel) { store.cancelPendingLinkAdd() }
            Button("フレンドになる") { store.confirmPendingLinkAdd() }
        } message: {
            Text("この招待リンクを送ってきた相手とフレンドになります。")
        }
    }

    private var friendSidebar: some View {
        List {
            Section {
                Button { popover = .me } label: {
                    HStack(spacing: 12) {
                        if let image = UIImage(data: profileImageData) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 34)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profileName.isEmpty ? "あなた" : profileName)
                            if shareStudyTime {
                                Text(Self.duration(myStudySeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button { popover = .requests } label: {
                    HStack {
                        Label("フレンド申請", systemImage: "person.badge.clock")
                        Spacer()
                        if !store.incomingRequests.isEmpty {
                            Text("\(store.incomingRequests.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
                Button { popover = .groupInvites } label: {
                    HStack {
                        Label("グループ招待", systemImage: "person.3.sequence")
                        Spacer()
                        if !store.incomingGroupInvites.isEmpty {
                            Text("\(store.incomingGroupInvites.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
            }

            Section("フレンド") {
                ForEach(store.friends) { friend in
                    Button { popover = .profile(friend.id) } label: {
                        FriendSidebarRow(
                            profile: FriendProfile(friend: friend, blockedByMeRoomIDs: store.blockedByMeRoomIDs),
                            unreadCount: store.unreadCounts[friend.id, default: 0]
                        )
                    }
                }
                if store.friends.isEmpty {
                    ContentUnavailableView("フレンドがいません", systemImage: "person.2", description: Text("右上の追加ボタンから招待できます。"))
                }
            }

            Section("グループ") {
                ForEach(store.groups, id: \.roomID) { group in
                    Button { selection = .group(group.roomID) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.name)
                                Text("\(group.members.count)人のメンバー")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if store.groups.isEmpty {
                    ContentUnavailableView("グループがありません", systemImage: "person.3", description: Text("右上の追加ボタンから作成できます。"))
                }
            }

        }
    }

    @ViewBuilder private var friendDetail: some View {
        switch selection {
        case .chats:
            FriendChatListView(
                summaries: FriendChatSummary.summaries(
                    friends: store.friends,
                    messages: store.messages,
                    unreadCounts: store.unreadCounts
                ),
                openChat: { selection = .chat($0.id) }
            )
        case .chat(let id):
            if let friend = store.friends.first(where: { $0.id == id }) {
                FriendChatView(
                    friend: friend,
                    store: store,
                    appAttachments: appAttachments,
                    resolveAppAttachment: resolveAppAttachment,
                    onBack: { selection = .chats }
                )
            } else {
                ContentUnavailableView("フレンドを選択してください", systemImage: "person.crop.circle")
            }
        case .group(let roomID):
            if store.groups.contains(where: { $0.roomID == roomID }) {
                GroupChatView(roomID: roomID, store: store, onBack: { selection = .chats })
            } else {
                ContentUnavailableView("グループを選択してください", systemImage: "person.3")
            }
        }
    }

    @ViewBuilder private func popoverContent(for item: FriendsPopover) -> some View {
        switch item {
        case .me:
            MyFriendCardPopover(myCode: store.myCode, myStudySeconds: myStudySeconds, sharesStudyTime: shareStudyTime)
        case .requests:
            FriendRequestsPopover(store: store)
        case .groupInvites:
            GroupInvitesPopover(store: store)
        case .profile(let id):
            if let friend = store.friends.first(where: { $0.id == id }) {
                FriendProfileView(
                    profile: FriendProfile(friend: friend, blockedByMeRoomIDs: store.blockedByMeRoomIDs),
                    friend: friend,
                    store: store,
                    openChat: {
                        popover = nil
                        selection = .chat(id)
                    }
                )
            } else {
                ContentUnavailableView("フレンドを選択してください", systemImage: "person.crop.circle")
            }
        case .settings:
            FriendPrivacySettingsView(shareStudyTime: $shareStudyTime, store: store)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }
}

private struct MyFriendCardPopover: View {
    let myCode: String
    let myStudySeconds: TimeInterval
    let sharesStudyTime: Bool

    // Reads the same `@AppStorage` keys `UserProfileView` writes, so a
    // photo or name set there shows up here immediately — this card used to
    // always render a generic person icon and the literal text "あなた"
    // regardless of what was set in the profile screen.
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileImage") private var imageData = Data()

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    if let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 70, height: 70)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(.tint)
                    }
                    Text(profileName.isEmpty ? "あなた" : profileName)
                        .font(.title.bold())
                    if sharesStudyTime {
                        Text("今日の勉強時間  \(FriendsHomeView.duration(myStudySeconds))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            Section("フレンドコード") {
                Text(myCode)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("自分のカード")
    }
}

private struct FriendRequestsPopover: View {
    @ObservedObject var store: FriendStore

    var body: some View {
        List {
            if store.incomingRequests.isEmpty {
                ContentUnavailableView("フレンド申請はありません", systemImage: "person.badge.clock")
            } else {
                Section("フレンド申請") {
                    ForEach(store.incomingRequests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(request.name)
                                    Text(request.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.pendingRequestActions.contains(request.code) {
                                    ProgressView()
                                }
                            }
                            if !store.pendingRequestActions.contains(request.code) {
                                HStack {
                                    Button("承認") { store.accept(request) }
                                        .buttonStyle(.borderedProminent)
                                    Button("拒否", role: .destructive) { store.reject(request) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("フレンド申請")
    }
}

private struct GroupInvitesPopover: View {
    @ObservedObject var store: FriendStore

    var body: some View {
        List {
            if store.incomingGroupInvites.isEmpty {
                ContentUnavailableView("グループ招待はありません", systemImage: "person.3.sequence")
            } else {
                Section("グループ招待") {
                    ForEach(store.incomingGroupInvites, id: \.roomID) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(invite.name)
                                    Text("\(invite.inviterName)さんから")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.pendingGroupActions.contains(invite.roomID) {
                                    ProgressView()
                                }
                            }
                            if !store.pendingGroupActions.contains(invite.roomID) {
                                HStack {
                                    Button("承認") { store.acceptGroupInvite(invite) }
                                        .buttonStyle(.borderedProminent)
                                    Button("拒否", role: .destructive) { store.rejectGroupInvite(invite) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("グループ招待")
    }
}

private struct FriendSidebarRow: View {
    let profile: FriendProfile
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatarView(avatarData: profile.avatarData, iconSystemName: profile.iconSystemName, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                    if profile.isBlockedByMe {
                        Image(systemName: "nosign")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let seconds = profile.todayStudySeconds {
                    Text(FriendsHomeView.duration(seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FriendChatListView: View {
    let summaries: [FriendChatSummary]
    let openChat: (FriendRecord) -> Void

    var body: some View {
        List {
            Section("メッセージ") {
                ForEach(summaries) { summary in
                    Button { openChat(summary.friend) } label: {
                        FriendChatSummaryRow(summary: summary)
                    }
                }
            }
        }
        .navigationTitle("メッセージ")
        .overlay {
            if summaries.isEmpty {
                ContentUnavailableView("メッセージがありません", systemImage: "message", description: Text("フレンドを追加すると、ここにチャットが表示されます。"))
            }
        }
    }
}

private struct FriendChatSummaryRow: View {
    let summary: FriendChatSummary

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatarView(
                avatarData: summary.friend.avatarData,
                iconSystemName: summary.friend.isDemo == true ? "sparkles" : "person.crop.circle.fill",
                size: 38
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.friend.name)
                        .font(.body.weight(.semibold))
                    Spacer()
                    if let latestDate = summary.latestDate {
                        Text(Self.timeText(for: latestDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(summary.previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if summary.unreadCount > 0 {
                        Text(summary.unreadCount > 99 ? "99+" : "\(summary.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func timeText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month().day())
    }
}

private struct FriendOverviewView: View {
    let myStudySeconds: TimeInterval
    let sharesStudyTime: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("フレンド")
                .font(.largeTitle.bold())
            if sharesStudyTime {
                Text("今日の勉強時間  \(FriendsHomeView.duration(myStudySeconds))")
                    .foregroundStyle(.secondary)
            }
            Text("左のサイドバーからフレンドを選ぶと、プロフィールとチャットを開けます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private struct FriendProfileView: View {
    let profile: FriendProfile
    let friend: FriendRecord
    @ObservedObject var store: FriendStore
    let openChat: () -> Void
    @State private var showsBlockConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    FriendAvatarView(avatarData: profile.avatarData, iconSystemName: profile.iconSystemName, size: 70)
                    Text(profile.name)
                        .font(.title.bold())
                    if let seconds = profile.todayStudySeconds {
                        Text("今日の勉強時間  \(FriendsHomeView.duration(seconds))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            Section("プロフィール") {
                LabeledContent("フレンドコード", value: profile.code)
                if profile.isDemo {
                    LabeledContent("種類", value: "デモフレンド")
                }
            }
            Section {
                Button { openChat() } label: {
                    Label("メッセージ", systemImage: "message.fill")
                }
                if profile.isBlockedByMe {
                    Button { store.unblock(friend) } label: {
                        Label("ブロックを解除する", systemImage: "checkmark.circle")
                    }
                } else {
                    Button(role: .destructive) { showsBlockConfirmation = true } label: {
                        Label("ブロックする", systemImage: "nosign")
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .confirmationDialog(
            "\(profile.name)さんをブロックしますか?",
            isPresented: $showsBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("ブロックする", role: .destructive) { store.block(friend) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ブロックすると、相手からのメッセージが届かなくなります。相手には通知されません。")
        }
        .task { await store.refreshBlockStatus(for: friend) }
    }
}

private struct FriendPrivacySettingsView: View {
    @Binding var shareStudyTime: Bool
    @ObservedObject var store: FriendStore

    var body: some View {
        Form {
            Section {
                Toggle("勉強時間をフレンドに公開", isOn: $shareStudyTime)
            } footer: {
                Text("オフにすると、あなたの今日の勉強時間はフレンドに送信されません。フレンド側では勉強時間の行は空欄になります。")
            }
            Section {
                NavigationLink {
                    BlockedContactsView(store: store)
                } label: {
                    Label("ブロック一覧", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("フレンド設定")
    }
}

private struct BlockedContactsView: View {
    @ObservedObject var store: FriendStore
    @State private var contactToRemove: FriendChatService.BlockedContact?

    var body: some View {
        List {
            ForEach(store.blockedContacts) { contact in
                HStack(spacing: 12) {
                    FriendAvatarView(
                        avatarData: store.friends.first(where: { $0.code == contact.code })?.avatarData,
                        iconSystemName: "person.crop.circle.fill"
                    )
                    Text(contact.name)
                    Spacer()
                    Menu {
                        Button("ブロックを解除") { store.unblock(contact) }
                        if store.friends.contains(where: { $0.code == contact.code }) {
                            Button("フレンドから削除", role: .destructive) { contactToRemove = contact }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(store.pendingRemovalCodes.contains(contact.code))
                    .accessibilityLabel("\(contact.name)の操作")
                }
            }
        }
        .navigationTitle("ブロック一覧")
        .overlay {
            if store.blockedContacts.isEmpty {
                ContentUnavailableView("ブロック中のユーザーはいません", systemImage: "hand.raised")
            }
        }
        .task { await store.refreshBlockedContacts() }
        .confirmationDialog(
            "フレンド関係を双方で解除しますか？",
            isPresented: Binding(
                get: { contactToRemove != nil },
                set: { if !$0 { contactToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("フレンドから削除", role: .destructive) {
                guard let contact = contactToRemove else { return }
                Task { _ = await store.removeFriend(contact) }
                contactToRemove = nil
            }
            Button("キャンセル", role: .cancel) { contactToRemove = nil }
        } message: {
            Text("双方のフレンド一覧から消えます。過去の会話とブロックは保持されます。")
        }
    }
}

private struct AddFriendView: View {
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section("あなたのQRコード") {
                    if store.isCodeReady {
                        QRCodeView(text: store.invitationURL.absoluteString).frame(width: 210, height: 210).frame(maxWidth: .infinity)
                        Text(store.myCode).font(.title3.monospaced().bold()).frame(maxWidth: .infinity)
                        ShareLink(item: store.invitationURL, subject: Text("Studiquoでフレンドになろう"), message: Text("このリンクからStudiquoのフレンドに追加できます。")) {
                            Label("LINE・Snapchatなどで共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } else {
                        // Sharing this before registration finishes would
                        // encode the placeholder text instead of a real code.
                        HStack {
                            Spacer()
                            ProgressView("コードを準備しています…")
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                }
                Section("コードで追加") {
                    TextField("フレンドコード", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: code) { _, value in
                            code = String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
                        }
                    if isSending {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Button("フレンド申請を送る") { submit(code: code) }.disabled(code.isEmpty)
                    }
                }
                Section {
                    NavigationLink { QRScannerView { value in submit(code: value) } } label: {
                        Label("QRコードを読み取る", systemImage: "qrcode.viewfinder")
                    }
                }
                if !store.outgoingRequests.isEmpty {
                    Section("送信済み") {
                        ForEach(store.outgoingRequests) { request in
                            HStack {
                                Text(request.name)
                                Spacer()
                                Text("承認待ち").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("1台で画面を確認") {
                    Button { store.addDemoFriend(); dismiss() } label: {
                        Label("デモ用フレンドを追加", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle("フレンドを追加")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task {
                // A one-shot fetch left "送信済み" stuck showing a request
                // as still pending long after the recipient actually
                // answered it, for as long as this sheet stayed open.
                while !Task.isCancelled {
                    await store.refreshOutgoingRequests()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            // Submitting used to dismiss immediately, before the network call
            // even returned — this is where a failure now actually reaches
            // the user, since the sheet stays open until we know the result.
            .alert("エラー", isPresented: Binding(
                get: { !store.errorMessage.isEmpty },
                set: { isPresented in if !isPresented { store.errorMessage = "" } }
            )) {
                Button("OK") { store.errorMessage = "" }
            } message: {
                Text(store.errorMessage)
            }
        }
    }

    /// Waits for the request to actually succeed or fail before dismissing —
    /// dismissing unconditionally right after firing it off left the sender
    /// with no way to tell whether it worked.
    private func submit(code: String) {
        isSending = true
        Task {
            let succeeded = await store.addAndWait(code: code)
            isSending = false
            if succeeded { dismiss() }
        }
    }
}

private struct CreateGroupView: View {
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedCodes: Set<String> = []
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("グループ名") {
                    TextField("グループ名", text: $name)
                }
                Section {
                    ForEach(store.friends.filter { $0.isDemo != true }) { friend in
                        Button {
                            if selectedCodes.contains(friend.code) {
                                selectedCodes.remove(friend.code)
                            } else {
                                selectedCodes.insert(friend.code)
                            }
                        } label: {
                            HStack {
                                Text(friend.name)
                                Spacer()
                                if selectedCodes.contains(friend.code) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("招待する友達")
                } footer: {
                    Text("選んだ友達には招待が届き、承認すると参加します。誰も選ばずに、自分だけでグループを作成することもできます。")
                }
                Section {
                    if isCreating {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Button("グループを作成") { submit() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("グループを作成")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .alert("エラー", isPresented: Binding(
                get: { !store.errorMessage.isEmpty },
                set: { isPresented in if !isPresented { store.errorMessage = "" } }
            )) {
                Button("OK") { store.errorMessage = "" }
            } message: {
                Text(store.errorMessage)
            }
        }
    }

    private func submit() {
        isCreating = true
        Task {
            let succeeded = await store.createGroup(name: name, memberCodes: Array(selectedCodes))
            isCreating = false
            if succeeded { dismiss() }
        }
    }
}

/// A group's own chat screen. Deliberately simpler than `FriendChatView`
/// (no attachments, no edit/cancel, no per-message read state) — those all
/// still work server-side for a group's room (see groups.js's own doc
/// comment on why message routes are reused unchanged), so this can grow
/// to match `FriendChatView` later without any server-side work; keeping
/// v1 to plain text keeps this new surface reviewable on its own.
struct GroupChatView: View {
    let roomID: String
    @ObservedObject var store: FriendStore
    var onBack: () -> Void

    @State private var draft = ""
    @State private var showsMembers = false
    @State private var showsRename = false
    @State private var renameDraft = ""

    private var group: FriendChatService.Group? {
        store.groups.first(where: { $0.roomID == roomID })
    }
    private var messages: [FriendChatService.Message] {
        store.groupMessages[roomID] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages, id: \.id) { message in
                            GroupMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastID = messages.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("メッセージを入力", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let text = draft
                    draft = ""
                    Task { await store.sendGroupMessage(text, roomID: roomID) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(group?.name ?? "グループ")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onBack() } label: { Image(systemName: "chevron.left") }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { renameDraft = group?.name ?? ""; showsRename = true } label: {
                        Label("グループ名を変更", systemImage: "pencil")
                    }
                    Button { showsMembers = true } label: {
                        Label("メンバーを管理", systemImage: "person.3")
                    }
                    Button(role: .destructive) {
                        Task {
                            if await store.removeGroupMember(roomID: roomID, code: store.myCode) { onBack() }
                        }
                    } label: {
                        Label("グループを退出", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsMembers) {
            if let group { GroupMembersView(roomID: roomID, group: group, store: store) }
        }
        .alert("グループ名を変更", isPresented: $showsRename) {
            TextField("グループ名", text: $renameDraft)
            Button("キャンセル", role: .cancel) {}
            Button("変更") { Task { await store.renameGroup(roomID: roomID, name: renameDraft) } }
        }
        .alert("エラー", isPresented: Binding(
            get: { !store.errorMessage.isEmpty },
            set: { isPresented in if !isPresented { store.errorMessage = "" } }
        )) {
            Button("OK") { store.errorMessage = "" }
        } message: {
            Text(store.errorMessage)
        }
        .task {
            while !Task.isCancelled {
                await store.refreshGroupMessages(roomID: roomID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct GroupMessageBubble: View {
    let message: FriendChatService.Message

    var body: some View {
        VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
            if !message.isMine, let senderName = message.senderName {
                Text(senderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.isCanceled == true ? "メッセージが取り消されました" : message.text)
                .italic(message.isCanceled == true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.isMine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(message.isMine ? .white : .primary)
        }
        .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
    }
}

private struct GroupMembersView: View {
    let roomID: String
    let group: FriendChatService.Group
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsInvite = false

    var body: some View {
        NavigationStack {
            List {
                Section("メンバー") {
                    ForEach(group.members, id: \.code) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            if member.code != store.myCode {
                                Button("削除", role: .destructive) {
                                    Task { await store.removeGroupMember(roomID: roomID, code: member.code) }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Button { showsInvite = true } label: {
                        Label("友達を招待", systemImage: "person.badge.plus")
                    }
                }
            }
            .navigationTitle("メンバー")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $showsInvite) {
                InviteToGroupView(roomID: roomID, existingCodes: Set(group.members.map(\.code)), store: store)
            }
        }
    }
}

private struct InviteToGroupView: View {
    let roomID: String
    let existingCodes: Set<String>
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss

    private var candidates: [FriendRecord] {
        store.friends.filter { $0.isDemo != true && !existingCodes.contains($0.code) }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView("招待できる友達がいません", systemImage: "person.badge.plus")
                } else {
                    ForEach(candidates) { friend in
                        Button(friend.name) {
                            Task {
                                if await store.inviteToGroup(roomID: roomID, code: friend.code) { dismiss() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("友達を招待")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .alert("エラー", isPresented: Binding(
                get: { !store.errorMessage.isEmpty },
                set: { isPresented in if !isPresented { store.errorMessage = "" } }
            )) {
                Button("OK") { store.errorMessage = "" }
            } message: {
                Text(store.errorMessage)
            }
        }
    }
}

@MainActor
enum FriendChatActivity {
    static func run(
        pollInterval: Duration = .seconds(2),
        refresh: @escaping @MainActor () async -> Void,
        maintenance: @escaping @MainActor () async -> Void
    ) async {
        // Attachment repair may await a slow upload. Keep it off the receive
        // loop so a newly sent message can still be fetched immediately.
        let maintenanceTask = Task { await maintenance() }
        defer { maintenanceTask.cancel() }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: pollInterval) } catch { break }
        }
    }
}

struct FriendChatView: View {
    let friend: FriendRecord
    @ObservedObject var store: FriendStore
    var appAttachments: [FriendMessageAttachment] = []
    var resolveAppAttachment: (FriendMessageAttachment, FriendRecord) async -> FriendMessageAttachment = { attachment, _ in attachment }
    var onAttachDroppedTab: (String) -> FriendMessageAttachment? = { _ in nil }
    var onPaneDrop: (String) -> Bool = { _ in false }
    var onOpenAttachment: ((FriendMessageAttachment) -> Void)?
    var onBack: (() -> Void)?
    @State private var draft = ""
    @State private var attachments: [FriendMessageAttachment] = []
    @State private var isDropTargeted = false
    @State private var isComposerDropTargeted = false
    @State private var isImportingFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsCameraScanner = false
    @State private var partialCopyText: PartialCopyText?
    @State private var isAttachingAppMaterial = false
    @State private var showsBlockConfirmation = false
    @State private var reportingMessage: FriendMessage?
    @State private var scrollRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(chatRows) { row in
                            switch row {
                            case .date(let id, let date):
                                dateSeparator(date, id: id)
                            case .message(let message):
                                messageRow(message)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding()
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: scrollRequest) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if isComposerDropTargeted {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        Text("ここに追加")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if isAttachingAppMaterial {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("資料を準備しています…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                HStack(spacing: 6) {
                                    Image(systemName: attachment.icon).foregroundStyle(.secondary)
                                    Text(attachment.title).lineLimit(1)
                                    Button {
                                        attachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    Menu {
                        Menu("アプリ内の資料を追加") {
                            ForEach(appAttachments) { item in
                                Button {
                                    isAttachingAppMaterial = true
                                    Task {
                                        let resolved = await resolveAppAttachment(item, friend)
                                        isAttachingAppMaterial = false
                                        attachments.append(resolved)
                                    }
                                } label: {
                                    Label(item.title, systemImage: item.icon)
                                }
                            }
                            if appAttachments.isEmpty {
                                Text("追加できる資料がありません")
                            }
                        }
                        Button { isImportingFiles = true } label: {
                            Label("ファイルから追加", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 34)
                            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("追加")

                    Button {
                        showsCameraScanner = true
                    } label: {
                        Image(systemName: "camera")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 34)
                            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("カメラで撮影")

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 34)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("写真から追加")

                    TextField("メッセージ", text: $draft, axis: .vertical)
                        .accessibilityIdentifier("friend-chat-draft")
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .submitLabel(.send)
                        .onSubmit(send)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .layoutPriority(1)

                    Button(action: send) {
                        Image(systemName: canSend ? "arrow.up.circle.fill" : "mic")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(canSend ? Color.accentColor : .primary)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityIdentifier("friend-chat-send")
                    .disabled(!canSend)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground))
            .scaleEffect(isComposerDropTargeted ? 1.01 : 1)
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first else { return false }
                if let attachment = onAttachDroppedTab(value) {
                    attachments.append(attachment)
                    return true
                }
                guard isDroppedPlainMessageText(value) else { return false }
                appendDroppedText(value)
                return true
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { isComposerDropTargeted = targeted }
            }
        }
        .navigationTitle(currentFriend.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Label("戻る", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if store.blockedByMeRoomIDs.contains(currentFriend.roomID ?? "") {
                        Button("ブロックを解除する") { store.unblock(currentFriend) }
                    } else {
                        Button("ブロックする", role: .destructive) { showsBlockConfirmation = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "\(currentFriend.name)さんをブロックしますか?",
            isPresented: $showsBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("ブロックする", role: .destructive) { store.block(currentFriend) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ブロックすると、相手からのメッセージが届かなくなります。相手には通知されません。")
        }
        .sheet(item: $reportingMessage) { message in
            ReportMessageSheet(onSubmit: { reason in
                store.report(message, reason: reason)
                reportingMessage = nil
            }, onCancel: { reportingMessage = nil })
        }
        .background(Color(red: 0.84, green: 0.94, blue: 1.0))
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, isPaneSwitchDrop(value) else { return false }
            return onPaneDrop(value)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .task {
            store.markRead(currentFriend)
            guard currentFriend.isDemo != true else { return }
            await FriendChatActivity.run(
                refresh: { await store.refreshMessages(for: currentFriend) },
                maintenance: {
                    // Repair once per chat open, independently of polling.
                    await store.repairLegacyAttachments(for: currentFriend, resolve: resolveAppAttachment)
                    await store.reconcileLegacyAttachments(for: currentFriend)
                    await store.refreshBlockStatus(for: currentFriend)
                }
            )
        }
        .onDisappear { store.stopReading(currentFriend) }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task {
                    for url in urls {
                        if let attachment = await saveFileAttachment(from: url) {
                            attachments.append(attachment)
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                // A library photo's original bytes are frequently HEIC (the
                // default capture format on iPhone since iOS 11), not JPEG —
                // `loadTransferable(type: Data.self)` returns whatever the
                // original encoding is. `savePhotoAttachment` always saves
                // with a ".jpg" extension and uploads with an
                // "image/jpeg" content type, so without re-encoding here
                // first, most library photos would be mislabeled as JPEG
                // while actually being HEIC bytes — a mismatch that can
                // keep either side from opening it correctly.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data),
                   let jpegData = uiImage.jpegData(compressionQuality: 0.82),
                   let attachment = await savePhotoAttachment(data: jpegData, title: "写真", icon: "photo") {
                    attachments.append(attachment)
                }
                selectedPhoto = nil
            }
        }
        .sheet(isPresented: $showsCameraScanner) {
            DocumentScannerView { images in
                Task {
                    for (index, image) in images.enumerated() {
                        guard let data = image.jpegData(compressionQuality: 0.82),
                              let attachment = await savePhotoAttachment(
                                data: data,
                                title: images.count == 1 ? "撮影した写真" : "撮影した写真 \(index + 1)",
                                icon: "camera"
                              ) else { continue }
                        attachments.append(attachment)
                    }
                }
            }
        }
        .sheet(item: $partialCopyText) { item in
            NavigationStack {
                ScrollView {
                    Text(item.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("部分コピー")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { partialCopyText = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // FriendsHomeView's alert on the same store.errorMessage only shows
        // while that view is on top of the navigation stack — while this
        // chat is pushed above it, a send failure needs its own alert here
        // to actually reach the user.
        .alert("エラー", isPresented: Binding(
            get: { !store.errorMessage.isEmpty },
            set: { isPresented in if !isPresented { store.errorMessage = "" } }
        )) {
            Button("OK") { store.errorMessage = "" }
        } message: {
            Text(store.errorMessage)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func appendDroppedText(_ value: String) {
        draft = draft.isEmpty ? value : "\(draft)\n\(value)"
    }

    private func isDroppedPlainMessageText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("[studiquo-attachment:") else { return false }
        guard !isPaneSwitchDrop(trimmed) else { return false }
        let blockedPrefixes = ["notebook-", "deck-", "document-", "slide-", "file-", "photo-"]
        guard !blockedPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return false }
        return !trimmed.contains(":")
    }

    private func isPaneSwitchDrop(_ value: String) -> Bool {
        value.hasPrefix("notebook:")
        || value.hasPrefix("deck:")
        || value.hasPrefix("flashcards:")
        || value.hasPrefix("web:")
        || value.hasPrefix("ai:")
        || value.hasPrefix("friend:")
    }

    private func openAttachment(_ attachment: FriendMessageAttachment) {
        if let onOpenAttachment {
            onOpenAttachment(attachment)
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoOpenFriendAttachment"),
            object: FriendAttachmentOpenRequest(attachment: attachment)
        )
    }

    /// `friend` is a snapshot captured when this screen was opened — it
    /// never sees later updates from `store.friends` (a rename, say) on its
    /// own. This looks the friend back up by id for anything that should
    /// stay current for as long as the chat stays open, falling back to the
    /// snapshot if it's ever no longer in the list (shouldn't normally
    /// happen, since friends are never removed).
    private var currentFriend: FriendRecord {
        store.friends.first(where: { $0.id == friend.id })
            ?? store.friends.first(where: { $0.roomID != nil && $0.roomID == friend.roomID })
            ?? store.friends.first(where: { $0.code == friend.code && $0.roomID != nil })
            ?? store.friends.first(where: { $0.code == friend.code })
            ?? friend
    }

    private var chatRows: [FriendChatRow] {
        var rows: [FriendChatRow] = []
        var previousDay: Date?
        let calendar = Calendar.current
        for message in store.messages(for: currentFriend) {
            let day = calendar.startOfDay(for: message.sentAt)
            if previousDay.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true {
                rows.append(.date(id: "date-\(day.timeIntervalSince1970)", date: day))
                previousDay = day
            }
            rows.append(.message(message))
        }
        return rows
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyWasQueued = false
        if !body.isEmpty {
            bodyWasQueued = store.send(body, to: currentFriend)
        }
        // Sent as one message per attachment, not combined into a single
        // message with the body — combining multiple attachments (or even
        // one alongside a long body) risked the joined payload exceeding
        // the message length limit. `FriendStore.send` truncates anything
        // over that limit, which silently cut an attachment's encoded
        // reference mid-string and corrupted it into garbled visible text.
        // A single attachment's own line stays comfortably under the limit
        // on its own, so sending each separately can't hit this at all.
        var unsentAttachments: [FriendMessageAttachment] = []
        for attachment in attachments {
            if !store.send(attachment.messageLine, to: currentFriend) {
                unsentAttachments.append(attachment)
            }
        }
        let sentAttachmentCount = attachments.count - unsentAttachments.count
        if bodyWasQueued { draft = "" }
        attachments = unsentAttachments
        if bodyWasQueued || sentAttachmentCount > 0 {
            scrollRequest += 1
        }
    }

    private func savePhotoAttachment(data: Data, title: String, icon: String) async -> FriendMessageAttachment? {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "FriendChatAttachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: [.atomic])
            // Kept as a fast local path for the sender's own device; the
            // upload below is what lets the *other* participant open it.
            let (remoteID, remoteRoomID) = await uploadIfPossible(data: data, contentType: "image/jpeg")
            return FriendMessageAttachment(
                id: "photo-\(url.path)-\(UUID().uuidString)",
                title: title,
                kind: "写真",
                icon: icon,
                sourceKind: "photo",
                sourceID: remoteID ?? url.path,
                sourcePath: url.path,
                remoteRoomID: remoteRoomID
            )
        } catch {
            return nil
        }
    }

    /// Uploads to the room this chat is for, unless it's a demo (no server
    /// room exists) — returns nil for both fields if there's no room to
    /// upload to, or if the upload itself failed.
    /// Mirrors chat-room.js's own MAX_ATTACHMENT_BYTES — checking here lets
    /// an oversized file fail immediately with a specific reason, instead
    /// of only finding out after a full upload attempt round-trips to the
    /// server and back with the same generic failure as any other cause.
    private static let maximumAttachmentBytes = 3 * 1024 * 1024

    private func uploadIfPossible(data: Data, contentType: String) async -> (id: String?, roomID: String?) {
        guard friend.isDemo != true, let roomID = friend.roomID else { return (nil, nil) }
        guard data.count <= Self.maximumAttachmentBytes else {
            store.errorMessage = "添付ファイルのサイズが大きすぎます（上限3MB）。相手の端末では開けません。"
            return (nil, nil)
        }
        guard let id = await store.uploadAttachment(data: data, contentType: contentType, roomID: roomID) else { return (nil, nil) }
        return (id, roomID)
    }

    private func saveFileAttachment(from sourceURL: URL) async -> FriendMessageAttachment? {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "FriendChatAttachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeFilename = FriendMessageAttachment.boundedFilename(sourceURL.lastPathComponent)
        let destination = directory.appending(path: "\(UUID().uuidString)-\(safeFilename)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            // Kept as a fast local path for the sender's own device; the
            // upload below is what lets the *other* participant open it.
            var remoteID: String?
            var remoteRoomID: String?
            let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if let fileData = try? Data(contentsOf: destination) {
                (remoteID, remoteRoomID) = await uploadIfPossible(data: fileData, contentType: contentType)
            }
            return FriendMessageAttachment(
                id: "file-\(destination.path)-\(UUID().uuidString)",
                title: safeFilename,
                kind: sourceURL.pathExtension.lowercased() == "pdf" ? "PDF" : "ファイル",
                icon: sourceURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc",
                sourceKind: sourceURL.pathExtension.lowercased() == "pdf" ? "pdf" : "file",
                sourceID: remoteID ?? destination.path,
                sourcePath: destination.path,
                remoteRoomID: remoteRoomID
            )
        } catch {
            return nil
        }
    }

    @ViewBuilder
    private func messageRow(_ message: FriendMessage) -> some View {
        if message.isCanceled == true {
            canceledMessageBubble(message)
                .frame(maxWidth: .infinity)
        } else {
            let parts = FriendMessageParts(text: message.text)
            HStack(alignment: .top, spacing: 8) {
            if message.isMine { Spacer(minLength: 54) }
            if !message.isMine {
                FriendAvatarView(avatarData: friend.avatarData, iconSystemName: "person.crop.circle.fill", size: 30)
                    .padding(.top, 4)
            }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                if !parts.body.isEmpty {
                    messageBubble(text: parts.body, isMine: message.isMine)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = copyableText(for: parts)
                            } label: {
                                Label("全てコピー", systemImage: "doc.on.doc")
                            }
                            Button {
                                partialCopyText = PartialCopyText(text: parts.body)
                            } label: {
                                Label("部分コピー", systemImage: "text.cursor")
                            }
                            if message.isMine {
                                Divider()
                                Button(role: .destructive) {
                                    store.cancel(message)
                                } label: {
                                    cancelActionLabel(for: message)
                                }
                            } else {
                                Divider()
                                Button(role: .destructive) {
                                    reportingMessage = message
                                } label: {
                                    Label("通報する", systemImage: "flag")
                                }
                            }
                        }
                }
                if message.isCanceled != true {
                    ForEach(parts.attachments) { attachment in
                        Button {
                            openAttachment(attachment)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: attachment.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(attachment.kind)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .frame(maxWidth: 260)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = attachment.title
                            } label: {
                                Label("ファイル名をコピー", systemImage: "doc.on.doc")
                            }
                            if message.isMine {
                                Button(role: .destructive) {
                                    store.cancel(message)
                                } label: {
                                    cancelActionLabel(for: message)
                                }
                            }
                        }
                    }
                }
                if message.isMine, message.sendFailed == true {
                    Label("送信できませんでした", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 280, alignment: .trailing)
                } else if message.isMine, message.serverID == nil, message.isCanceled != true,
                          message.sendFailed != true, message.roomID != nil {
                    Text("送信中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
                messageTime(message.sentAt, isMine: message.isMine)
            }
            if !message.isMine { Spacer(minLength: 54) }
            }
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
        }
    }

    private func dateSeparator(_ date: Date, id: String) -> some View {
        Text(Self.dateFormatter.string(from: date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55), in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(id)
    }

    private func messageBubble(text: String, isMine: Bool) -> some View {
        Text(text)
            .textSelection(.enabled)
            .font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(isMine ? Color(red: 0.37, green: 0.92, blue: 0.40) : .white, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(Color.black)
            .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
    }

    /// A message that already failed to send never reached anyone — there's
    /// nothing to retract, so labeling that action the same as canceling an
    /// actually-delivered message ("送信取消") would misleadingly imply the
    /// same thing happened in both cases.
    private func cancelActionLabel(for message: FriendMessage) -> some View {
        message.sendFailed == true
            ? Label("削除", systemImage: "trash")
            : Label("送信取消", systemImage: "arrow.uturn.backward.circle")
    }

    /// "全てコピー" copying only the body left attachment info completely
    /// out — despite the label implying "all" of the message's content. A
    /// human-readable mention of what was attached is appended, so pasting
    /// the copy still says something about it (unlike the message's own
    /// internal encoded payload, which isn't meant to be human-readable).
    private func copyableText(for parts: FriendMessageParts) -> String {
        var lines: [String] = []
        if !parts.body.isEmpty { lines.append(parts.body) }
        lines.append(contentsOf: parts.attachments.map { "[添付: \($0.title)]" })
        return lines.joined(separator: "\n")
    }

    private func canceledMessageBubble(_ message: FriendMessage) -> some View {
        Text(message.sendFailed == true ? "送信できなかったメッセージを削除しました" : "メッセージの送信を取り消しました")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
    }

    private func messageTime(_ sentAt: Date, isMine: Bool) -> some View {
        Text(Self.timeFormatter.string(from: sentAt))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()
}

private enum FriendChatRow: Identifiable {
    case date(id: String, date: Date)
    case message(FriendMessage)

    var id: String {
        switch self {
        case .date(let id, _): id
        case .message(let message): message.id.uuidString
        }
    }
}

private struct PartialCopyText: Identifiable {
    let id = UUID()
    let text: String
}

/// A short reason for reporting a message — there is no in-app moderation
/// queue yet (see `FriendChatService.report`'s doc comment), so this is
/// purely descriptive text for whoever reviews the report later, not a
/// category picker tied to any automated handling.
private struct ReportMessageSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("理由(任意)", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("通報の内容は運営側の確認用に記録されます。相手には通知されません。")
                }
            }
            .navigationTitle("通報する")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送信") { onSubmit(reason.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct FriendMessageAttachment: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let kind: String
    let icon: String
    var sourceKind: String? = nil
    var sourceID: String? = nil
    var sourcePath: String? = nil
    var imageData: Data? = nil
    /// When set, `sourceID` is a server-hosted attachment id inside this
    /// room, not just a local file path/database id — the other participant
    /// has no access to the sender's device, so this is what lets them
    /// actually retrieve the attachment's bytes.
    var remoteRoomID: String? = nil

    /// Bounds a filename before it's embedded in an attachment payload
    /// (used for the saved file's name, its title, and its source path/id —
    /// all three end up inside `messageLine`, so the name's cost is paid
    /// three times over). Left uncapped, a long name — especially one with
    /// non-ASCII characters, which balloon under the percent-encoding
    /// `messageLine` applies — can push the encoded payload past the
    /// 2,000-character message limit on its own, where it gets truncated
    /// mid-payload and corrupts the attachment reference. A 20-character cap
    /// keeps a single attachment's worst case (an all-non-ASCII name) around
    /// 1,500 characters, leaving room for a message body alongside it.
    static func boundedFilename(_ original: String, maxLength: Int = 20) -> String {
        String(original.prefix(maxLength))
    }

    var messageLine: String {
        let payload = [
            "id": id,
            "title": title,
            "kind": kind,
            "icon": icon,
            "sourceKind": sourceKind ?? legacySourceParts?.kind ?? "",
            "sourceID": sourceID ?? legacySourceParts?.rawID ?? "",
            "sourcePath": sourcePath ?? "",
            "remoteRoomID": remoteRoomID ?? "",
        ]
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "【\(kind)】\(title)"
        }
        return "[studiquo-attachment:\(encoded)]"
    }

    var resolvedSourceKind: String? {
        sourceKind ?? legacySourceParts?.kind
    }

    var resolvedSourceID: String? {
        sourceID ?? legacySourceParts?.rawID
    }

    private var legacySourceParts: (kind: String, rawID: String)? {
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Every attachment embedded in `text`, decoded as-is regardless of
    /// repair status — unlike `legacyAttachments(in:)`, which filters to
    /// only the still-unrepaired ones.
    static func attachments(in text: String) -> [FriendMessageAttachment] {
        FriendMessageParts(text: text).attachments
    }

    /// Attachments embedded in `text` with no `remoteRoomID` — meaning
    /// whatever bytes they refer to were never actually uploaded anywhere
    /// the recipient's device can reach, only ever a path or database id
    /// local to whichever device sent them. Covers every kind this predates
    /// (in-app materials, photos, scanned pages, imported files) alike —
    /// `sourceKind` alone can't tell a not-yet-repaired attachment apart
    /// from a legitimately-current one, since "pdf" is also the ordinary,
    /// already-working kind for an imported PDF file. Unless repaired (see
    /// `FriendStore.repairLegacyAttachments`), these are invisible to the
    /// recipient's device.
    static func legacyAttachments(in text: String) -> [FriendMessageAttachment] {
        FriendMessageParts(text: text).attachments.filter { $0.remoteRoomID == nil }
    }

    /// Rebuilds `text` with the attachment carrying `id` replaced by
    /// `repaired` — the message body and any other attachments are left
    /// untouched.
    static func textReplacingAttachment(in text: String, id: String, with repaired: FriendMessageAttachment) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { line -> String in
                guard line.hasPrefix("[studiquo-attachment:"), line.hasSuffix("]") else { return line }
                let encoded = String(line.dropFirst("[studiquo-attachment:".count).dropLast())
                guard let decoded = encoded.removingPercentEncoding,
                      let data = decoded.data(using: .utf8),
                      let payload = try? JSONDecoder().decode([String: String].self, from: data),
                      payload["id"] == id else { return line }
                return repaired.messageLine
            }
            .joined(separator: "\n")
    }
}

private struct FriendMessageParts {
    let body: String
    let attachments: [FriendMessageAttachment]

    init(text: String) {
        var lines: [String] = []
        var parsed: [FriendMessageAttachment] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("[studiquo-attachment:"),
               line.hasSuffix("]") {
                let encoded = String(line.dropFirst("[studiquo-attachment:".count).dropLast())
                if let decoded = encoded.removingPercentEncoding,
                   let data = decoded.data(using: .utf8),
                   let payload = try? JSONDecoder().decode([String: String].self, from: data),
                   let id = payload["id"],
                   let title = payload["title"],
                   let kind = payload["kind"],
                   let icon = payload["icon"] {
                    parsed.append(FriendMessageAttachment(
                        id: id,
                        title: title,
                        kind: kind,
                        icon: icon,
                        sourceKind: payload["sourceKind"].flatMap { $0.isEmpty ? nil : $0 },
                        sourceID: payload["sourceID"].flatMap { $0.isEmpty ? nil : $0 },
                        sourcePath: payload["sourcePath"].flatMap { $0.isEmpty ? nil : $0 },
                        remoteRoomID: payload["remoteRoomID"].flatMap { $0.isEmpty ? nil : $0 }
                    ))
                    continue
                }
            }
            lines.append(line)
        }
        body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = parsed
    }
}

private struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = makeImage() { Image(uiImage: image).interpolation(.none).resizable().scaledToFit() }
    }
    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(); guard let cgImage = context.createCGImage(output.transformed(by: .init(scaleX: 12, y: 12)), from: output.transformed(by: .init(scaleX: 12, y: 12)).extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
