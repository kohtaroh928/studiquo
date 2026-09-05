import Foundation

enum FriendChatService {
    private static let endpoint = URL(string: "https://studiquo-mcp.studiquo-mcp-server.workers.dev")!

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
    }
    struct Identity: Codable { let code: String; let name: String }
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
    struct IncomingRequest: Codable { let code: String; let name: String; let requestedAt: Double }
    struct OutgoingRequest: Codable { let code: String; let name: String; let requestedAt: Double }
    struct RejectResult: Codable { let status: String }
    struct AttachmentUploadResult: Codable { let id: String }
    struct CancelMessageResult: Codable { let status: String }
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

    /// Sends a one-directional friend request; the recipient must accept it
    /// (see `acceptRequest`) before a mutual friendship or chat room exists.
    static func add(code: String) async throws -> AddFriendResult {
        try await request(path: "api/chat/friends", method: "POST", body: ["code": code])
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
        try await request(path: "api/chat/rooms/\(roomID)/messages?after=\(after)", method: "GET", body: Optional<String>.none)
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
        var request = URLRequest(url: endpoint.appending(path: path))
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
    func add(code: String) async throws -> FriendChatService.AddFriendResult
    func incomingRequests() async throws -> [FriendChatService.IncomingRequest]
    func outgoingRequests() async throws -> [FriendChatService.OutgoingRequest]
    func accept(code: String) async throws -> FriendChatService.Friend
    func reject(code: String) async throws -> FriendChatService.RejectResult
    func messages(roomID: String, after: Int) async throws -> [FriendChatService.Message]
    func send(_ text: String, roomID: String, clientMessageID: String) async throws -> FriendChatService.Message
    func cancelMessage(roomID: String, messageID: Int) async throws -> FriendChatService.CancelMessageResult
    func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.AttachmentUploadResult
    func downloadAttachment(roomID: String, id: String) async throws -> Data
}

struct LiveFriendChatClient: FriendChatClient {
    func register(name: String, todayStudySeconds: Int?, studyDate: String?) async throws -> FriendChatService.Identity {
        try await FriendChatService.register(name: name, todayStudySeconds: todayStudySeconds, studyDate: studyDate)
    }

    func friends() async throws -> [FriendChatService.Friend] {
        try await FriendChatService.friends()
    }

    func add(code: String) async throws -> FriendChatService.AddFriendResult {
        try await FriendChatService.add(code: code)
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

    func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.AttachmentUploadResult {
        try await FriendChatService.uploadAttachment(roomID: roomID, contentType: contentType, data: data)
    }

    func downloadAttachment(roomID: String, id: String) async throws -> Data {
        try await FriendChatService.downloadAttachment(roomID: roomID, id: id)
    }
}
