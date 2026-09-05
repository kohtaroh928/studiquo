import CoreImage.CIFilterBuiltins
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
                    TextField("自己紹介", text: $bio, axis: .vertical).lineLimit(3...6)
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
    @Published var activeFriendID: UUID?
    @Published var myCode: String
    @Published var errorMessage = ""
    private let client: FriendChatClient
    private let defaults: UserDefaults
    private let friendsKey = "studiquoFriends"
    private let messagesKey = "studiquoFriendMessages"
    private let unreadCountsKey = "studiquoFriendUnreadCounts"
    private static let codePattern = /^[A-Z0-9]{6,32}$/
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
        if let data = defaults.data(forKey: friendsKey) {
            friends = (try? JSONDecoder().decode([FriendRecord].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: messagesKey) {
            if let decoded = try? JSONDecoder().decode([FriendMessage].self, from: data) {
                messages = decoded
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
        if autoRefresh { Task { await refresh() } }
    }

    var invitationURL: URL { URL(string: "studiquo://friend/add?code=\(myCode)")! }

    /// False only during the narrow window on a brand-new install before the
    /// first registration completes — sharing/scanning a QR code before this
    /// is true would encode the placeholder text instead of a real code.
    var isCodeReady: Bool { myCode != Self.placeholderCode }

    func refresh() async {
        do {
            let name = defaults.string(forKey: "profileName") ?? "Studiquoユーザー"
            let identity = try await client.register(name: name, todayStudySeconds: nil, studyDate: nil)
            myCode = identity.code
            defaults.set(myCode, forKey: "studiquoFriendCode")
            let remote = try await client.friends()
            friends = Self.mergedFriends(existing: friends, remote: remote)
            errorMessage = ""
        } catch {
            errorMessage = "フレンドサーバーに接続できません。"
        }
        await refreshIncomingRequests()
        await refreshOutgoingRequests()
    }

    /// Refreshes just the friends list, skipping the register() call that
    /// `refresh()` also makes — cheap enough to poll periodically so a
    /// friend who just accepted this user's request shows up without
    /// waiting for a full refresh() (app relaunch, or another add()).
    func refreshFriends() async {
        guard let remote = try? await client.friends() else {
            notePollResult("friends", succeeded: false)
            return
        }
        notePollResult("friends", succeeded: true)
        friends = Self.mergedFriends(existing: friends, remote: remote)
    }

    /// Consecutive-failure counts for each background polling loop, keyed by
    /// a name unique to that loop. A single transient blip shouldn't nag the
    /// user, but a sustained failure (e.g. no connectivity at all) used to
    /// go on forever with nothing ever telling them why the screen had gone
    /// stale — this surfaces `errorMessage` once failures persist. It
    /// doesn't auto-clear on recovery, since `errorMessage` is shared with
    /// other flows (add/accept/reject) and blowing away whatever's there
    /// the moment polling happens to succeed again could dismiss an
    /// unrelated alert the user hasn't even seen yet; dismissal stays the
    /// user tapping OK, same as every other use of this field.
    private var consecutivePollFailures: [String: Int] = [:]
    private static let pollFailureAlertThreshold = 3

    private func notePollResult(_ key: String, succeeded: Bool) {
        if succeeded {
            consecutivePollFailures[key] = 0
            return
        }
        let count = (consecutivePollFailures[key] ?? 0) + 1
        consecutivePollFailures[key] = count
        if count == Self.pollFailureAlertThreshold {
            errorMessage = "フレンドサーバーに接続できません。"
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
    func reportMyStudyTime(_ seconds: TimeInterval) {
        Task {
            let name = defaults.string(forKey: "profileName") ?? "Studiquoユーザー"
            _ = try? await client.register(name: name, todayStudySeconds: Int(seconds), studyDate: Self.todayDateKey())
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
            let freshSeconds = item.studyDate == today ? (item.todayStudySeconds ?? 0) : 0
            if let match = existing.first(where: { $0.isDemo != true && $0.code == item.code }) {
                var updated = match
                updated.name = item.name
                updated.roomID = item.roomID
                updated.todayStudySeconds = freshSeconds
                return updated
            }
            return FriendRecord(id: UUID(), name: item.name, code: item.code, todayStudySeconds: freshSeconds, roomID: item.roomID, isDemo: false)
        }
        return demos + mapped
    }

    func refreshIncomingRequests() async {
        guard let remote = try? await client.incomingRequests() else {
            notePollResult("incomingRequests", succeeded: false)
            return
        }
        notePollResult("incomingRequests", succeeded: true)
        incomingRequests = remote.map {
            IncomingFriendRequest(code: $0.code, name: $0.name, requestedAt: Date(timeIntervalSince1970: $0.requestedAt / 1_000))
        }
    }

    /// The requests this user has sent that are still awaiting the
    /// recipient's approval — shown in the add-friend screen so sending a
    /// request doesn't feel like it vanished into nothing.
    func refreshOutgoingRequests() async {
        guard let remote = try? await client.outgoingRequests() else {
            notePollResult("outgoingRequests", succeeded: false)
            return
        }
        notePollResult("outgoingRequests", succeeded: true)
        outgoingRequests = remote.map {
            OutgoingFriendRequest(code: $0.code, name: $0.name, requestedAt: Date(timeIntervalSince1970: $0.requestedAt / 1_000))
        }
    }

    /// Sends a one-directional request; the recipient must accept it (see
    /// `accept`) before they become a mutual friend. Fire-and-forget — for a
    /// caller that wants to know whether it actually succeeded (the
    /// add-friend sheet, so it can wait before dismissing), use `addAndWait`.
    func add(code raw: String) {
        Task { _ = await addAndWait(code: raw) }
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
                    friends.append(FriendRecord(id: UUID(), name: friend.name, code: friend.code, todayStudySeconds: 0, roomID: friend.roomID, isDemo: false))
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
        default:
            return fallback
        }
    }

    func addDemoFriend() {
        guard !friends.contains(where: { $0.isDemo == true }) else { return }
        friends.append(FriendRecord(id: UUID(), name: "デモフレンド", code: "DEMO123", todayStudySeconds: 3_600, roomID: nil, isDemo: true))
    }

    func add(url: URL) {
        guard url.scheme?.lowercased() == "studiquo",
              url.host?.lowercased() == "friend",
              url.path == "/add",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        add(code: code)
    }

    func send(_ text: String, to friend: FriendRecord) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard friends.contains(where: { $0.id == friend.id }), Self.hasVisibleContent(cleaned) else { return }
        let messageText = String(cleaned.prefix(Self.maximumMessageLength))
        let messageID = UUID()
        var working = messages
        working.append(FriendMessage(
            id: messageID, friendID: friend.id,
            text: messageText, sentAt: Date(), isMine: true, isCanceled: false
        ))
        let (trimmedMessages, evicted) = Self.trimmed(working, for: friend.id)
        messages = trimmedMessages
        Self.deleteLocalAttachmentFiles(for: evicted)
        if friend.isDemo == true {
            Task {
                try? await Task.sleep(for: .seconds(1))
                messages.append(FriendMessage(id: UUID(), friendID: friend.id, text: "メッセージを受け取りました！これはデモ返信です。", sentAt: Date(), isMine: false, isCanceled: false))
                // Mirrors how a real incoming message affects unreadCounts
                // in refreshMessages — without this, the demo reply never
                // showed up as unread even while its chat wasn't open.
                if activeFriendID == friend.id {
                    unreadCounts[friend.id] = 0
                } else {
                    unreadCounts[friend.id, default: 0] += 1
                }
            }
        } else if let roomID = friend.roomID {
            Task {
                do {
                    let sent = try await client.send(messageText, roomID: roomID, clientMessageID: messageID.uuidString)
                    // There's no way to actually stop an HTTP request that's
                    // already been issued — but if the user canceled this
                    // message while it was still in flight (see `cancel`),
                    // it now has the serverID needed to retract it for
                    // real, the moment it exists, instead of silently
                    // letting it reach the recipient uncanceled.
                    if pendingCancellations.remove(messageID) != nil {
                        _ = try? await client.cancelMessage(roomID: roomID, messageID: sent.id)
                    }
                } catch is FriendChatService.RateLimitedError {
                    pendingCancellations.remove(messageID)
                    errorMessage = "メッセージの送信回数が上限に達しました。しばらくしてからもう一度お試しください。"
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].sendFailed = true
                    }
                } catch {
                    pendingCancellations.remove(messageID)
                    errorMessage = "メッセージを送信できませんでした。"
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].sendFailed = true
                    }
                }
            }
        }
    }

    /// Message ids canceled while still in flight (no `serverID` yet) — see
    /// `cancel`. Checked once the pending `send` Task above actually
    /// completes, so the retraction still happens for real once there's a
    /// serverID to retract.
    private var pendingCancellations: Set<UUID> = []

    func markRead(_ friend: FriendRecord) {
        unreadCounts[friend.id] = 0
        activeFriendID = friend.id
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

    func stopReading(_ friend: FriendRecord) {
        if activeFriendID == friend.id { activeFriendID = nil }
    }

    var totalUnreadCount: Int {
        unreadCounts.values.reduce(0, +)
    }

    func messages(for friend: FriendRecord) -> [FriendMessage] {
        messages.filter { $0.friendID == friend.id }.sorted { $0.sentAt < $1.sentAt }
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
        guard friend.isDemo != true, let roomID = friend.roomID else { return }
        let latestKnownServerID = messages(for: friend).compactMap(\.serverID).max() ?? 0
        let after = max(0, latestKnownServerID - Self.recentReconcileWindow)
        guard let remote = try? await client.messages(roomID: roomID, after: after) else {
            notePollResult("messages", succeeded: false)
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
            if item.isMine, let index = working.firstIndex(where: {
                guard $0.friendID == friend.id, $0.isMine, $0.serverID == nil else { return false }
                // Matching by the client-generated id the message was sent
                // with is exact and order-independent; falling back to text
                // equality only covers a message sent before this existed
                // (or a request whose response never made it back with the
                // id echoed) — and even then is no worse than the old
                // behavior, which always matched by text alone. Matching by
                // text alone is what let two in-flight messages with
                // identical content get reconciled in the wrong order (the
                // network doesn't guarantee two concurrent sends arrive at
                // the server in the same order they were issued locally).
                if let clientMessageID = item.clientMessageID {
                    return $0.id.uuidString == clientMessageID
                }
                return $0.text == item.text
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
                working[index].sentAt = Date(timeIntervalSince1970: item.sentAt / 1_000)
                continue
            }
            if let index = working.firstIndex(where: { $0.friendID == friend.id && $0.serverID == item.id }) {
                // Already known — but the server's copy may have been
                // retracted since the last time this device saw it. Without
                // this, a cancellation would only ever be visible to a
                // device that hadn't fetched the message yet, defeating the
                // whole point of retracting it for the recipient.
                if item.isCanceled == true, working[index].isCanceled != true {
                    working[index].text = ""
                    working[index].isCanceled = true
                }
                continue
            }
            working.append(FriendMessage(
                id: UUID(), friendID: friend.id, text: item.text,
                sentAt: Date(timeIntervalSince1970: item.sentAt / 1_000),
                isMine: item.isMine, isCanceled: item.isCanceled == true, serverID: item.id
            ))
            if !item.isMine { newIncomingCount += 1 }
        }
        let (trimmedMessages, evicted) = Self.trimmed(working, for: friend.id)
        messages = trimmedMessages
        Self.deleteLocalAttachmentFiles(for: evicted)

        if activeFriendID == friend.id {
            unreadCounts[friend.id] = 0
        } else if newIncomingCount > 0 {
            unreadCounts[friend.id, default: 0] += newIncomingCount
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
    @State private var showsAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("今日の勉強時間") {
                    LabeledContent("あなた", value: duration(myStudySeconds))
                }
                if !store.incomingRequests.isEmpty {
                    Section("フレンド申請") {
                        ForEach(store.incomingRequests) { request in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(request.name)
                                    Text(request.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.pendingRequestActions.contains(request.code) {
                                    ProgressView()
                                } else {
                                    Button("承認") { store.accept(request) }
                                        .buttonStyle(.borderedProminent)
                                    Button("拒否", role: .destructive) { store.reject(request) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                Section("フレンド") {
                    ForEach(store.friends) { friend in
                        NavigationLink {
                            FriendChatView(friend: friend, store: store, appAttachments: appAttachments)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(friend.name)
                                    Text("今日 \(duration(friend.todayStudySeconds))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.friends.isEmpty {
                        ContentUnavailableView("フレンドがいません", systemImage: "person.2", description: Text("右上の追加ボタンから招待できます。"))
                    }
                }
            }
            .navigationTitle("フレンド")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showsAdd = true } label: { Image(systemName: "person.badge.plus") } } }
            .sheet(isPresented: $showsAdd) { AddFriendView(store: store) }
            .task {
                store.reportMyStudyTime(myStudySeconds)
                while !Task.isCancelled {
                    await store.refreshIncomingRequests()
                    // Without this, a friend who just accepted this user's
                    // outgoing request never appears here — nothing else
                    // re-fetches the friends list while this screen is open.
                    await store.refreshFriends()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            // `myStudySeconds` is a plain `let` recomputed by the parent on
            // every render, not something the long-running .task above would
            // ever see update on its own — onChange is what actually reports
            // a newly-finished study session instead of a stale snapshot.
            .onChange(of: myStudySeconds) { _, newValue in
                store.reportMyStudyTime(newValue)
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
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
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
                    try? await Task.sleep(for: .seconds(2))
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

struct FriendChatView: View {
    let friend: FriendRecord
    @ObservedObject var store: FriendStore
    var appAttachments: [FriendMessageAttachment] = []
    var onAttachDroppedTab: (String) -> FriendMessageAttachment? = { _ in nil }
    var onPaneDrop: (String) -> Bool = { _ in false }
    var onOpenAttachment: ((FriendMessageAttachment) -> Void)?
    @State private var draft = ""
    @State private var attachments: [FriendMessageAttachment] = []
    @State private var isDropTargeted = false
    @State private var isComposerDropTargeted = false
    @State private var isImportingFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsCameraScanner = false
    @State private var partialCopyText: PartialCopyText?

    var body: some View {
        VStack(spacing: 0) {
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
                }.padding()
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
                                    attachments.append(item)
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
            store.markRead(friend)
            guard friend.isDemo != true else { return }
            while !Task.isCancelled {
                await store.refreshMessages(for: friend)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { store.stopReading(friend) }
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
        store.friends.first(where: { $0.id == friend.id }) ?? friend
    }

    private var chatRows: [FriendChatRow] {
        var rows: [FriendChatRow] = []
        var previousDay: Date?
        let calendar = Calendar.current
        for message in store.messages(for: friend) {
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
        if !body.isEmpty {
            store.send(body, to: friend)
        }
        // Sent as one message per attachment, not combined into a single
        // message with the body — combining multiple attachments (or even
        // one alongside a long body) risked the joined payload exceeding
        // the message length limit. `FriendStore.send` truncates anything
        // over that limit, which silently cut an attachment's encoded
        // reference mid-string and corrupted it into garbled visible text.
        // A single attachment's own line stays comfortably under the limit
        // on its own, so sending each separately can't hit this at all.
        for attachment in attachments {
            store.send(attachment.messageLine, to: friend)
        }
        draft = ""
        attachments = []
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
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
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
            .background(Color.black.opacity(0.16), in: Capsule())
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
            .foregroundStyle(.primary)
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
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
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
