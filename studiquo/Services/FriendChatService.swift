import Foundation

enum FriendChatService {
    private static let endpoint = URL(string: "https://studiquo-mcp.studiquo-mcp-server.workers.dev")!

    struct Friend: Codable { let code: String; let name: String; let roomID: String }
    struct Identity: Codable { let code: String; let name: String }
    struct Message: Codable {
        let id: Int
        let text: String
        let sentAt: Double
        let isMine: Bool
    }

    static func register(name: String) async throws -> Identity {
        try await request(path: "api/chat/me", method: "POST", body: ["name": name])
    }

    static func friends() async throws -> [Friend] {
        try await request(path: "api/chat/friends", method: "GET", body: Optional<String>.none)
    }

    static func add(code: String) async throws -> Friend {
        try await request(path: "api/chat/friends", method: "POST", body: ["code": code])
    }

    static func messages(roomID: String, after: Int = 0) async throws -> [Message] {
        try await request(path: "api/chat/rooms/\(roomID)/messages?after=\(after)", method: "GET", body: Optional<String>.none)
    }

    static func send(_ text: String, roomID: String) async throws -> Message {
        try await request(path: "api/chat/rooms/\(roomID)/messages", method: "POST", body: ["text": text])
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
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
