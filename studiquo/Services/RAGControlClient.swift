import Foundation

/// Management requests contain no account identifier; bearer authentication chooses the owner.
@MainActor
struct RAGControlClient {
    typealias RequestFactory = (String, [String: Any], Bool) throws -> URLRequest
    let transport: RAGIndexingService.Transport
    let requestFactory: RequestFactory
    init(transport: @escaping RAGIndexingService.Transport = { try await URLSession.shared.data(for: $0) },
         requestFactory: @escaping RequestFactory = { try WorkerAIProvider().request(path: $0, body: $1, requiresAIConsent: $2) }) {
        self.transport = transport; self.requestFactory = requestFactory
    }
    func supportsStructuredIngest() async throws -> Bool {
        struct Reply: Decodable { let enabled: Bool; let structuredIngestVersion: Int? }
        let reply: Reply = try await request("api/rag/status", method: "GET")
        return reply.enabled && reply.structuredIngestVersion == 1
    }
    struct Consent: Codable { let enabled: Bool; let consentEpoch: Int; var available: Bool?; var managed: Bool? }
    struct Document: Codable {
        let documentId: String?
        let state: String?
        let generation: Int
        let consentEpoch: Int?
        let sourceId: String?
        let sourceHash: String?
        let requestId: String?
    }
    func request<T: Decodable>(_ path: String, body: [String: Any] = [:], method: String = "POST", consent: Bool = false) async throws -> T {
        var request = try requestFactory(path, body, consent)
        request.httpMethod = method
        if method == "GET" { request.httpBody = nil }
        request.timeoutInterval = 30
        request.setValue(RAGConsent.version, forHTTPHeaderField: "X-Studiquo-RAG-Consent")
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw WorkerAIProvider.ProviderError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 502, message: "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func consent() async throws -> Consent { try await request("api/rag/consent", method: "GET") }
    func setConsent(enabled: Bool, epoch: Int) async throws -> Consent {
        try await request("api/rag/consent", body: ["enabled": enabled, "expectedEpoch": epoch], consent: enabled)
    }
    func document(_ id: String) async throws -> Document { try await request("api/rag/documents/\(id)/state", method: "GET") }
    func invalidate(_ id: String, state: String, generation: Int, epoch: Int) async throws -> Document {
        try await request("api/rag/documents/\(id)/state", body: ["state": state, "expectedGeneration": generation, "consentEpoch": epoch])
    }
    func prepare(_ id: String, requestId: String, generation: Int, epoch: Int, hash: String, title: String, folder: String?, total: Int) async throws -> Document {
        try await request("api/rag/documents/prepare", body: ["documentId": id, "requestId": requestId,
            "expectedGeneration": generation, "consentEpoch": epoch, "sourceHash": hash, "title": title,
            "folderId": folder as Any? ?? NSNull(), "totalPages": total], consent: true)
    }
    struct Readiness: Decodable { let state: String; let sourceHash: String? }
    func readiness(_ sourceId: String) async throws -> Readiness {
        try await request("api/rag/sources/\(sourceId)/readiness", method: "GET", consent: true)
    }
    func upload(_ body: [String: Any]) async throws {
        var request = try requestFactory("api/rag/index", body, true)
        guard (request.httpBody?.count ?? Int.max) <= 512_000 else { throw RAGIndexingService.IndexError.oversized }
        request.setValue(RAGConsent.version, forHTTPHeaderField: "X-Studiquo-RAG-Consent")
        let (_, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw WorkerAIProvider.ProviderError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 502, message: "")
        }
    }
}
