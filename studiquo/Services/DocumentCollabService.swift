import Foundation

/// Networking for the collaborative document review rooms the server hosts
/// (see mcp-server/src/document-room.js and document-collab.js). Mirrors
/// FriendChatService's shape: a bearer-token-authenticated JSON API against
/// the same worker, one static function per endpoint.
///
/// Scope note: a room only tracks plain paragraph text per block, keyed by
/// that block's `order` at the moment collaboration was turned on or a block
/// was last synced. It is not a full structural sync — inserting/deleting
/// paragraphs, tables, or images locally is never proposed to the room, only
/// edits to an existing paragraph's text. See `CollabSheet`'s doc comment in
/// TextDocumentView.swift for how the editor surfaces that boundary.
enum DocumentCollabService {
    private static let endpoint = URL(string: "https://studiquo-mcp.studiquo-mcp-server.workers.dev")!

    struct Block: Codable {
        var order: Int
        var kind: String
        var text: String
        var listKind: String?
        var listLevel: Int
        var paragraphStyle: String?
    }
    struct PendingChange: Codable, Identifiable {
        var id: Int
        var authorKey: String
        var blockOrder: Int
        var previousText: String
        var newText: String
        var createdAt: Double
    }
    struct RoomState: Codable {
        var blocks: [Block]
        var pendingChanges: [PendingChange]
    }
    struct Participant: Codable, Identifiable {
        var userKey: String
        var role: String
        var name: String?
        var id: String { userKey }
    }
    struct StatusResult: Codable { let status: String }
    struct ProposeResult: Codable { let id: Int; let status: String }
    struct RateLimitedError: Error {}
    /// Carries the server's own `{"error": "..."}` message through to the
    /// caller instead of collapsing every non-2xx response into the same
    /// generic network error — same convention as FriendChatService.ServerError.
    struct ServerError: Error {
        let status: Int
        let message: String
    }
    private struct ErrorPayload: Decodable { let error: String }

    /// A fresh 64-lowercase-hex-character room id, the shape the server's
    /// route regex requires. Minted client-side (unlike a chat room's id,
    /// which the server derives from exactly two participants' keys) since a
    /// document room can gain any number of invited editors/reviewers.
    static func mintRoomID() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func initialize(roomID: String, blocks: [Block]) async throws -> StatusResult {
        try await request(path: "api/document/rooms/\(roomID)/init", method: "POST", body: ["blocks": blocks])
    }

    /// `code` is the invitee's friend code (as shown in the existing friend
    /// list) — the server resolves it to that person's room-participant key,
    /// the same way adding a chat friend resolves a code.
    static func invite(roomID: String, code: String, role: String) async throws -> StatusResult {
        try await request(path: "api/document/rooms/\(roomID)/invite", method: "POST", body: ["code": code, "role": role])
    }

    static func participants(roomID: String) async throws -> [Participant] {
        try await request(path: "api/document/rooms/\(roomID)/participants", method: "GET", body: Optional<String>.none)
    }

    static func state(roomID: String) async throws -> RoomState {
        try await request(path: "api/document/rooms/\(roomID)/state", method: "GET", body: Optional<String>.none)
    }

    private struct ProposeBody: Encodable {
        let blockOrder: Int
        let previousText: String
        let newText: String
    }

    static func propose(roomID: String, blockOrder: Int, previousText: String, newText: String) async throws -> ProposeResult {
        try await request(
            path: "api/document/rooms/\(roomID)/propose", method: "POST",
            body: ProposeBody(blockOrder: blockOrder, previousText: previousText, newText: newText)
        )
    }

    static func review(roomID: String, changeID: Int, decision: String) async throws -> StatusResult {
        try await request(path: "api/document/rooms/\(roomID)/changes/\(changeID)/review", method: "POST", body: ["decision": decision])
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

protocol DocumentCollabClient {
    func initialize(roomID: String, blocks: [DocumentCollabService.Block]) async throws -> DocumentCollabService.StatusResult
    func invite(roomID: String, code: String, role: String) async throws -> DocumentCollabService.StatusResult
    func participants(roomID: String) async throws -> [DocumentCollabService.Participant]
    func state(roomID: String) async throws -> DocumentCollabService.RoomState
    func propose(roomID: String, blockOrder: Int, previousText: String, newText: String) async throws -> DocumentCollabService.ProposeResult
    func review(roomID: String, changeID: Int, decision: String) async throws -> DocumentCollabService.StatusResult
}

struct LiveDocumentCollabClient: DocumentCollabClient {
    func initialize(roomID: String, blocks: [DocumentCollabService.Block]) async throws -> DocumentCollabService.StatusResult {
        try await DocumentCollabService.initialize(roomID: roomID, blocks: blocks)
    }
    func invite(roomID: String, code: String, role: String) async throws -> DocumentCollabService.StatusResult {
        try await DocumentCollabService.invite(roomID: roomID, code: code, role: role)
    }
    func participants(roomID: String) async throws -> [DocumentCollabService.Participant] {
        try await DocumentCollabService.participants(roomID: roomID)
    }
    func state(roomID: String) async throws -> DocumentCollabService.RoomState {
        try await DocumentCollabService.state(roomID: roomID)
    }
    func propose(roomID: String, blockOrder: Int, previousText: String, newText: String) async throws -> DocumentCollabService.ProposeResult {
        try await DocumentCollabService.propose(roomID: roomID, blockOrder: blockOrder, previousText: previousText, newText: newText)
    }
    func review(roomID: String, changeID: Int, decision: String) async throws -> DocumentCollabService.StatusResult {
        try await DocumentCollabService.review(roomID: roomID, changeID: changeID, decision: decision)
    }
}
