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

    /// The room tracks a document's header and footer as two extra blocks under
    /// these reserved orders, far above any paragraph's. The server accepts any
    /// non-negative order, so no server change is needed.
    static let headerBlockOrder = 1_000_000
    static let footerBlockOrder = 1_000_001
    static func blockOrder(forTarget target: String?) -> Int? {
        switch target {
        case "header": return headerBlockOrder
        case "footer": return footerBlockOrder
        default: return nil
        }
    }
    static func target(forBlockOrder order: Int) -> String? {
        switch order {
        case headerBlockOrder: return "header"
        case footerBlockOrder: return "footer"
        default: return nil
        }
    }

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
    /// the same way adding a chat friend resolves a code. The answer is
    /// `pending`: the friend joins only after accepting.
    static func invite(roomID: String, code: String, role: String) async throws -> StatusResult {
        try await request(path: "api/document/rooms/\(roomID)/invite", method: "POST", body: ["code": code, "role": role])
    }

    /// An offer to join someone's document room. It seats nobody until the
    /// invited person accepts it (see mcp-server/src/document-collab.js).
    struct PendingInvite: Codable, Identifiable, Equatable {
        var roomID: String
        var role: String
        var inviterName: String?
        var createdAt: Double
        var id: String { roomID }
    }
    struct InviteAnswer: Codable { let status: String; let role: String? }

    /// The invitations waiting for this person's answer.
    static func pendingInvites() async throws -> [PendingInvite] {
        try await request(path: "api/document/invites", method: "GET", body: Optional<String>.none)
    }

    static func acceptInvite(roomID: String) async throws -> InviteAnswer {
        try await request(path: "api/document/rooms/\(roomID)/invite/accept", method: "POST", body: [String: String]())
    }

    static func declineInvite(roomID: String) async throws -> InviteAnswer {
        try await request(path: "api/document/rooms/\(roomID)/invite/decline", method: "POST", body: [String: String]())
    }

    // MARK: Whole-document sync

    struct SnapshotReply: Codable {
        let revision: Int
        let snapshot: String?
        let unchanged: Bool?
    }
    struct RevisionReply: Codable { let revision: Int }
    struct MissingReply: Codable { let missing: [String] }
    struct AssetReply: Codable { let data: String }
    /// The room has moved on since the revision this device last saw.
    struct RevisionConflict: Error { let currentRevision: Int }

    static func snapshot(roomID: String, since: Int) async throws -> SnapshotReply {
        try await request(path: "api/document/rooms/\(roomID)/snapshot?since=\(since)", method: "GET", body: Optional<String>.none)
    }

    static func putSnapshot(roomID: String, baseRevision: Int, snapshot: String) async throws -> Int {
        struct Body: Encodable { let baseRevision: Int; let snapshot: String }
        do {
            let reply: RevisionReply = try await request(
                path: "api/document/rooms/\(roomID)/snapshot", method: "PUT", body: Body(baseRevision: baseRevision, snapshot: snapshot)
            )
            return reply.revision
        } catch let error as ServerError where error.status == 409 {
            throw RevisionConflict(currentRevision: -1)
        }
    }

    static func missingAssets(roomID: String, hashes: [String]) async throws -> [String] {
        let reply: MissingReply = try await request(
            path: "api/document/rooms/\(roomID)/assets/missing", method: "POST", body: ["hashes": hashes]
        )
        return reply.missing
    }

    static func putAsset(roomID: String, hash: String, data: Data) async throws {
        let _: [String: String] = try await request(
            path: "api/document/rooms/\(roomID)/assets/\(hash)", method: "PUT", body: ["data": data.base64EncodedString()]
        )
    }

    static func asset(roomID: String, hash: String) async throws -> Data? {
        do {
            let reply: AssetReply = try await request(path: "api/document/rooms/\(roomID)/assets/\(hash)", method: "GET", body: Optional<String>.none)
            return Data(base64Encoded: reply.data)
        } catch let error as ServerError where error.status == 404 {
            return nil
        }
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
        guard let endpoint = MCPCloudCredentials.configuredEndpoint() else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.dataNoticing(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 { throw RateLimitedError() }
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            // A definitive rejection of this device's own token, not
            // something a retry could fix — see .studiquoAuthFailed.
            if http.statusCode == 401 { NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil) }
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
