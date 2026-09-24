import Foundation

enum FriendChatService {
    private static var endpoint: URL {
        MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
    }

    struct Friend: Codable {
        let code: String
        let name: String
        let roomID: String
        /// Not present in every response (e.g. accept/reject don't include
        /// it) — Optional rather than a default, since Codable's synthesized
        /// decoding only falls back to a default for missing keys when the
        /// property is Optional.
        var todayStudySeconds: Double? = nil
        var studyDate: String? = nil
        /// When this friend's server-side avatar was last replaced (ms since
        /// epoch), or nil if they've never uploaded one. Rides along
        /// `friends()`'s existing "live" per-friend lookup so the client can
        /// tell, without downloading every friend's photo on every poll,
        /// whether the one it already has cached is still current — see
        /// `FriendStore.syncFriendAvatarsIfNeeded`.
        var avatarUpdatedAt: Double? = nil
    }
    struct Identity: Codable {
        let code: String
        let name: String
        /// A second, separate code — only ever embedded in a shareable
        /// invite link/QR, never typed manually — that redeems for an
        /// immediate, no-approval friendship. Deliberately not the same
        /// value as `code`: if it were, anyone could type `code` by hand
        /// and skip the approval step manual entry is supposed to require.
        /// Optional purely for decoding safety against an older server
        /// response; every real response includes it.
        var linkToken: String? = nil
        var avatarUpdatedAt: Double? = nil
    }
    struct AvatarUploadResult: Codable { let avatarUpdatedAt: Double }
    struct Message: Codable {
        let id: Int
        let text: String
        let sentAt: Double
        let isMine: Bool
        /// The opaque token the sender's client attached at send time, if
        /// any — round-tripped unchanged so the sender can reconcile its
        /// own optimistic local copy with this exact server echo, rather
        /// than guessing by text content (which two in-flight messages can
        /// share). Optional since older/foreign senders may not set it.
        var clientMessageID: String? = nil
        /// True once the sender has actually retracted this message
        /// server-side — the text has already been cleared to "" by the
        /// server in that case, for every reader of the room, not just the
        /// sender's own device.
        var isCanceled: Bool? = nil
    }
    struct AddFriendResult: Codable { let status: String }
    /// `status` is `"added"` for a brand-new friendship or `"already_friends"`
    /// if the two were already friends (a harmless no-op, not an error) —
    /// either way `code`/`name`/`roomID` describe the link owner, the same
    /// shape `Friend` uses, so the caller can build a `FriendRecord` from it
    /// exactly like it does for `acceptRequest`'s response.
    struct LinkAddResult: Codable { let status: String; let code: String; let name: String; let roomID: String }
    struct IncomingRequest: Codable { let code: String; let name: String; let requestedAt: Double }
    struct OutgoingRequest: Codable { let code: String; let name: String; let requestedAt: Double }
    struct RejectResult: Codable { let status: String }
    struct AttachmentUploadResult: Codable { let id: String }
    struct CancelMessageResult: Codable { let status: String }
    struct EditMessageResult: Codable { let status: String }
    struct BlockResult: Codable { let status: String }
    struct BlockStatus: Codable { let blockedByMe: Bool; let blockedByOther: Bool }
    struct ReportResult: Codable { let status: String }
    struct RateLimitedError: Error {}
    /// Carries the server's own `{"error": "..."}` message through to the
    /// caller instead of collapsing every non-2xx response into the same
    /// generic network error.
    struct ServerError: Error {
        let status: Int
        let message: String
    }
    private struct ErrorPayload: Decodable { let error: String }

    private struct MeRequestBody: Encodable {
        let name: String
        var todayStudySeconds: Int? = nil
        var studyDate: String? = nil
    }

    static func register(name: String, todayStudySeconds: Int? = nil, studyDate: String? = nil) async throws -> Identity {
        try await request(
            path: "api/chat/me", method: "POST",
            body: MeRequestBody(name: name, todayStudySeconds: todayStudySeconds, studyDate: studyDate)
        )
    }

    static func friends() async throws -> [Friend] {
        try await request(path: "api/chat/friends", method: "GET", body: Optional<String>.none)
    }

    /// Uploads the caller's own profile photo so it can be shown to their
    /// friends, mirroring `uploadAttachment` below. `contentType` must be
    /// `image/jpeg` or `image/png` — anything else is rejected server-side.
    static func uploadAvatar(contentType: String, data: Data) async throws -> AvatarUploadResult {
        try await request(
            path: "api/chat/me/avatar", method: "POST",
            body: ["contentType": contentType, "data": data.base64EncodedString()]
        )
    }

    /// Downloads a friend's (or the caller's own) uploaded profile photo by
    /// their friend code. Mirrors `downloadAttachment` below, except this
    /// isn't scoped to a room — the server instead checks that the caller is
    /// either `code` themselves or an established friend of theirs.
    static func downloadAvatar(code: String) async throws -> Data {
        var request = URLRequest(url: endpoint.appending(path: "api/chat/avatar/\(code)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 { throw RateLimitedError() }
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            throw ServerError(status: http.statusCode, message: payload.error)
        }
        return data
    }

    /// Sends a one-directional friend request; the recipient must accept it
    /// (see `acceptRequest`) before a mutual friendship or chat room exists.
    static func add(code: String) async throws -> AddFriendResult {
        try await request(path: "api/chat/friends", method: "POST", body: ["code": code])
    }

    /// Redeems the *other* person's invite-link token for an immediate,
    /// mutual friendship — no pending request, no approval step on either
    /// side. `token` is only ever obtained by actually receiving the
    /// invite link/QR (see `Identity.linkToken`'s doc comment); receiving
    /// it at all is treated as consent enough, unlike a manually typed
    /// friend code, which still always goes through `add(code:)` and a
    /// real accept/reject step.
    static func addViaLink(token: String) async throws -> LinkAddResult {
        try await request(path: "api/chat/friends/link-add", method: "POST", body: ["token": token])
    }

    static func incomingRequests() async throws -> [IncomingRequest] {
        try await request(path: "api/chat/friends/requests", method: "GET", body: Optional<String>.none)
    }

    /// The caller's own not-yet-answered outgoing requests.
    static func outgoingRequests() async throws -> [OutgoingRequest] {
        try await request(path: "api/chat/friends/outgoing", method: "GET", body: Optional<String>.none)
    }

    static func acceptRequest(code: String) async throws -> Friend {
        try await request(path: "api/chat/friends/requests/accept", method: "POST", body: ["code": code])
    }

    static func rejectRequest(code: String) async throws -> RejectResult {
        try await request(path: "api/chat/friends/requests/reject", method: "POST", body: ["code": code])
    }

    static func messages(roomID: String, after: Int = 0) async throws -> [Message] {
        try await request(url: messageListURL(roomID: roomID, after: after, baseURL: endpoint), method: "GET", body: Optional<String>.none)
    }

    /// URL.appending(path:) escapes `?` as part of the path. Build the cursor
    /// as a real query item so the Worker matches its messages route.
    static func messageListURL(roomID: String, after: Int, baseURL: URL) -> URL {
        let pathURL = baseURL.appending(path: "api/chat/rooms/\(roomID)/messages")
        var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        return components.url!
    }

    static func send(_ text: String, roomID: String, clientMessageID: String) async throws -> Message {
        try await request(
            path: "api/chat/rooms/\(roomID)/messages", method: "POST",
            body: ["text": text, "clientMessageID": clientMessageID]
        )
    }

    /// Retracts one of the caller's own messages for real — the server
    /// clears its stored text, so every reader of the room stops seeing it,
    /// not just this device.
    static func cancelMessage(roomID: String, messageID: Int) async throws -> CancelMessageResult {
        try await request(path: "api/chat/rooms/\(roomID)/messages/\(messageID)/cancel", method: "POST", body: Optional<String>.none)
    }

    /// Rewrites one of the caller's own already-sent messages in place — used
    /// to repair a legacy chat attachment reference (one that only ever
    /// carried a local, off-device id, from before attachments could be
    /// uploaded) once its material has been re-rendered and re-uploaded
    /// under the newer, shareable scheme. Reaches every reader of the room,
    /// not just this device.
    static func editMessage(roomID: String, messageID: Int, text: String) async throws -> EditMessageResult {
        try await request(
            path: "api/chat/rooms/\(roomID)/messages/\(messageID)/edit", method: "POST", body: ["text": text]
        )
    }

    /// Looks up the current text for specific message ids, regardless of how
    /// old they are relative to the room's latest message — `messages(roomID:after:)`
    /// only reconciles a rolling window of recent ids (see `FriendStore.refreshMessages`),
    /// which would never surface an `editMessage` repair to a message old
    /// enough to have scrolled out of that window.
    static func messages(roomID: String, ids: [Int]) async throws -> [Message] {
        try await request(path: "api/chat/rooms/\(roomID)/messages/lookup", method: "POST", body: ["ids": ids])
    }

    /// Blocks the other participant in this room — from then on, the server
    /// rejects anything they try to send here, without telling them why.
    static func block(roomID: String) async throws -> BlockResult {
        try await request(path: "api/chat/rooms/\(roomID)/block", method: "POST", body: Optional<String>.none)
    }

    static func unblock(roomID: String) async throws -> BlockResult {
        try await request(path: "api/chat/rooms/\(roomID)/unblock", method: "POST", body: Optional<String>.none)
    }

    static func blockStatus(roomID: String) async throws -> BlockStatus {
        try await request(path: "api/chat/rooms/\(roomID)/block-status", method: "GET", body: Optional<String>.none)
    }

    /// Records a report for manual review — there is no in-app moderation
    /// queue yet, so this only tells the server to persist the report
    /// somewhere the developer can look at later; it doesn't hide the
    /// message or notify anyone automatically.
    static func report(roomID: String, messageID: Int, reason: String) async throws -> ReportResult {
        try await request(path: "api/chat/rooms/\(roomID)/messages/\(messageID)/report", method: "POST", body: ["reason": reason])
    }

    /// Uploads an attachment's actual bytes to the room, so the other
    /// participant — who has no access to the sender's local filesystem or
    /// app database — can retrieve them too.
    static func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> AttachmentUploadResult {
        try await request(
            path: "api/chat/rooms/\(roomID)/attachments", method: "POST",
            body: ["contentType": contentType, "data": data.base64EncodedString()]
        )
    }

    /// Downloads an attachment's raw bytes from the room. Used when the
    /// local copy isn't available — e.g. the recipient's device, which never
    /// had the file locally in the first place.
    static func downloadAttachment(roomID: String, id: String) async throws -> Data {
        var request = URLRequest(url: endpoint.appending(path: "api/chat/rooms/\(roomID)/attachments/\(id)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 { throw RateLimitedError() }
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            throw ServerError(status: http.statusCode, message: payload.error)
        }
        return data
    }

    private static func request<Response: Decodable, Body: Encodable>(
        path: String, method: String, body: Body?
    ) async throws -> Response {
        try await request(url: endpoint.appending(path: path), method: method, body: body)
    }

    private static func request<Response: Decodable, Body: Encodable>(
        url: URL, method: String, body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 { throw RateLimitedError() }
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            throw ServerError(status: http.statusCode, message: payload.error)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

protocol FriendChatClient {
    func register(name: String, todayStudySeconds: Int?, studyDate: String?) async throws -> FriendChatService.Identity
    func friends() async throws -> [FriendChatService.Friend]
    func uploadAvatar(contentType: String, data: Data) async throws -> FriendChatService.AvatarUploadResult
    func downloadAvatar(code: String) async throws -> Data
    func add(code: String) async throws -> FriendChatService.AddFriendResult
    func addViaLink(token: String) async throws -> FriendChatService.LinkAddResult
    func incomingRequests() async throws -> [FriendChatService.IncomingRequest]
    func outgoingRequests() async throws -> [FriendChatService.OutgoingRequest]
    func accept(code: String) async throws -> FriendChatService.Friend
    func reject(code: String) async throws -> FriendChatService.RejectResult
    func messages(roomID: String, after: Int) async throws -> [FriendChatService.Message]
    func send(_ text: String, roomID: String, clientMessageID: String) async throws -> FriendChatService.Message
    func cancelMessage(roomID: String, messageID: Int) async throws -> FriendChatService.CancelMessageResult
    func editMessage(roomID: String, messageID: Int, text: String) async throws -> FriendChatService.EditMessageResult
    func messages(roomID: String, ids: [Int]) async throws -> [FriendChatService.Message]
    func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.AttachmentUploadResult
    func downloadAttachment(roomID: String, id: String) async throws -> Data
    func block(roomID: String) async throws -> FriendChatService.BlockResult
    func unblock(roomID: String) async throws -> FriendChatService.BlockResult
    func blockStatus(roomID: String) async throws -> FriendChatService.BlockStatus
    func report(roomID: String, messageID: Int, reason: String) async throws -> FriendChatService.ReportResult
}

struct LiveFriendChatClient: FriendChatClient {
    func register(name: String, todayStudySeconds: Int?, studyDate: String?) async throws -> FriendChatService.Identity {
        try await FriendChatService.register(name: name, todayStudySeconds: todayStudySeconds, studyDate: studyDate)
    }

    func friends() async throws -> [FriendChatService.Friend] {
        try await FriendChatService.friends()
    }

    func uploadAvatar(contentType: String, data: Data) async throws -> FriendChatService.AvatarUploadResult {
        try await FriendChatService.uploadAvatar(contentType: contentType, data: data)
    }

    func downloadAvatar(code: String) async throws -> Data {
        try await FriendChatService.downloadAvatar(code: code)
    }

    func add(code: String) async throws -> FriendChatService.AddFriendResult {
        try await FriendChatService.add(code: code)
    }

    func addViaLink(token: String) async throws -> FriendChatService.LinkAddResult {
        try await FriendChatService.addViaLink(token: token)
    }

    func incomingRequests() async throws -> [FriendChatService.IncomingRequest] {
        try await FriendChatService.incomingRequests()
    }

    func outgoingRequests() async throws -> [FriendChatService.OutgoingRequest] {
        try await FriendChatService.outgoingRequests()
    }

    func accept(code: String) async throws -> FriendChatService.Friend {
        try await FriendChatService.acceptRequest(code: code)
    }

    func reject(code: String) async throws -> FriendChatService.RejectResult {
        try await FriendChatService.rejectRequest(code: code)
    }

    func messages(roomID: String, after: Int = 0) async throws -> [FriendChatService.Message] {
        try await FriendChatService.messages(roomID: roomID, after: after)
    }

    func send(_ text: String, roomID: String, clientMessageID: String) async throws -> FriendChatService.Message {
        try await FriendChatService.send(text, roomID: roomID, clientMessageID: clientMessageID)
    }

    func cancelMessage(roomID: String, messageID: Int) async throws -> FriendChatService.CancelMessageResult {
        try await FriendChatService.cancelMessage(roomID: roomID, messageID: messageID)
    }

    func editMessage(roomID: String, messageID: Int, text: String) async throws -> FriendChatService.EditMessageResult {
        try await FriendChatService.editMessage(roomID: roomID, messageID: messageID, text: text)
    }

    func messages(roomID: String, ids: [Int]) async throws -> [FriendChatService.Message] {
        try await FriendChatService.messages(roomID: roomID, ids: ids)
    }

    func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.AttachmentUploadResult {
        try await FriendChatService.uploadAttachment(roomID: roomID, contentType: contentType, data: data)
    }

    func downloadAttachment(roomID: String, id: String) async throws -> Data {
        try await FriendChatService.downloadAttachment(roomID: roomID, id: id)
    }

    func block(roomID: String) async throws -> FriendChatService.BlockResult {
        try await FriendChatService.block(roomID: roomID)
    }

    func unblock(roomID: String) async throws -> FriendChatService.BlockResult {
        try await FriendChatService.unblock(roomID: roomID)
    }

    func blockStatus(roomID: String) async throws -> FriendChatService.BlockStatus {
        try await FriendChatService.blockStatus(roomID: roomID)
    }

    func report(roomID: String, messageID: Int, reason: String) async throws -> FriendChatService.ReportResult {
        try await FriendChatService.report(roomID: roomID, messageID: messageID, reason: reason)
    }
}
