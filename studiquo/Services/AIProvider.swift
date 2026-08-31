import Foundation
import UIKit

/// One turn of a conversation, independent of which model is behind it.
struct AITurn {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

/// Everything the app asks an AI to do.
///
/// The app talks only to this protocol, so changing model or vendor is one
/// line in `AI.provider` rather than an edit at every call site. Two
/// implementations exist today: the Worker proxy (Gemini, the shipping path)
/// and the direct Claude client kept from the earlier build.
protocol AIProvider {
    /// True when the provider is configured well enough to be worth calling.
    var isConfigured: Bool { get }
    /// Shown in the chat header so the student can see what they are talking to.
    var displayName: String { get }

    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage],
        expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws

    /// Derives the marking scheme before the student's work is looked at.
    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult
}

/// One thing to mark.
///
/// Both halves can arrive either way round: the question typed out or cropped
/// off a PDF, the answer typed into the chat or photographed from the page.
/// Keeping them in one value means adding a third form later doesn't ripple
/// through every signature.
struct ProofSubmission {
    var questionText: String = ""
    var questionImage: UIImage?
    var answerText: String = ""
    var answerImage: UIImage?
    /// Optional. When absent the marker works out for itself what a correct
    /// proof needs, from the question alone.
    var modelAnswer: String = ""

    var hasQuestion: Bool { questionImage != nil || !questionText.isEmpty }
    var hasAnswer: Bool { answerImage != nil || !answerText.isEmpty }
}

/// Which provider the app is using.
///
/// Swap the assignment to move the whole app to a different model. The Worker
/// path is the default because the API key lives on the server there, so
/// nothing secret ships inside the app.
enum AI {
    static var provider: AIProvider = WorkerAIProvider()
}

// MARK: - Worker-backed provider

/// Talks to the app's own Cloudflare Worker, which holds the Gemini key.
///
/// The app authenticates with the same device token the MCP sync already
/// uses, so there is nothing extra for the student to set up — the AI is
/// connected the moment the app is installed.
final class WorkerAIProvider: AIProvider {
    /// Where the Worker lives when the user has never touched the setting.
    ///
    /// `@AppStorage` does not write its default into `UserDefaults` until the
    /// value is actually changed, so reading the key on a fresh install comes
    /// back nil — which is why the chat reported "未設定" even though the
    /// endpoint was right there in settings. The default is repeated here so
    /// both paths agree.
    static let defaultEndpoint = "https://studiquo-mcp.studiquo-mcp-server.workers.dev"

    /// Read fresh each call so changing the endpoint in settings takes effect
    /// without restarting.
    private var baseURL: URL? {
        var raw = (UserDefaults.standard.string(forKey: "mcpCloudEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = Self.defaultEndpoint }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var isConfigured: Bool { baseURL != nil }

    var displayName: String { L("Studiquo AI") }

    enum ProviderError: LocalizedError {
        case notConfigured
        case http(status: Int, message: String)
        case malformedResponse
        case transport(String)
        case imageEncodingFailed
        case imageNotReceived

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return L("AIサーバーのURLが設定されていません。設定のMCPクラウド連携を確認してください。")
            case .http(let status, let message):
                if status == 429 { return message.isEmpty ? L("利用回数の上限に達しました。") : message }
                if status == 401 { return L("この端末はまだAIサーバーに認証されていません。") }
                return message.isEmpty ? L("AIに接続できませんでした（\(status)）。") : message
            case .malformedResponse:
                return L("応答を読み取れませんでした。もう一度試してください。")
            case .transport(let message):
                return L("通信に失敗しました：\(message)")
            case .imageEncodingFailed:
                return L("切り抜き画像を送信用データに変換できませんでした。もう一度切り抜いてください。")
            case .imageNotReceived:
                return L("AIサーバーが切り抜き画像を受信できませんでした。サーバーを更新して、もう一度お試しください。")
            }
        }
    }

    private func request(path: String, body: [String: Any]) throws -> URLRequest {
        guard let baseURL else { throw ProviderError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func message(from data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
    }

    // MARK: Chat

    @MainActor
    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage] = [],
        expectsImages: Bool = false,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let encodedImages = images.compactMap(Self.encoded)
        if expectsImages && encodedImages.count != images.count {
            throw ProviderError.imageEncodingFailed
        }
        if expectsImages && encodedImages.isEmpty {
            throw ProviderError.imageEncodingFailed
        }
        let payload: [String: Any] = [
            "messages": turns.map { ["role": $0.role.rawValue, "text": $0.text] },
            "noteContext": noteContext,
            "images": encodedImages,
            "requiresImage": expectsImages,
        ]
        let request = try request(path: "api/ai/chat", body: payload)

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport(L("応答を読み取れませんでした。"))
            }
            guard 200..<300 ~= http.statusCode else {
                var raw = Data()
                for try await byte in stream { raw.append(byte) }
                throw ProviderError.http(status: http.statusCode, message: message(from: raw))
            }
            if expectsImages,
               let received = http.value(forHTTPHeaderField: "X-Studiquo-Images-Received"),
               Int(received) != encodedImages.count {
                throw ProviderError.imageNotReceived
            }
            // The Worker normalises Gemini's event envelope down to
            // `data: {"text": "..."}`, so there is only one shape to parse.
            for try await line in stream.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty,
                      let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = event["text"] as? String else { continue }
                onDelta(text)
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }

    // MARK: Proof marking

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        var body: [String: Any] = [
            "question": submission.questionText,
            "modelAnswer": submission.modelAnswer,
        ]
        if let png = Self.encoded(submission.questionImage) {
            body["questionImageBase64"] = png
        }
        return try await streamedResult(path: "api/ai/rubric", body: body)
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        var body: [String: Any] = [
            "question": submission.questionText,
            "answerText": submission.answerText,
            "criteria": rubric.criteria.map {
                ["name": $0.name, "maxPoints": $0.maxPoints, "requirement": $0.requirement]
            },
        ]
        if let png = Self.encoded(submission.answerImage) { body["imageBase64"] = png }
        if let png = Self.encoded(submission.questionImage) { body["questionImageBase64"] = png }
        return try await streamedResult(path: "api/ai/grade", body: body)
    }

    private static func encoded(_ image: UIImage?) -> String? {
        guard let image, let png = downscaled(image).pngData() else { return nil }
        return png.base64EncodedString()
    }

    /// Reads one of the Worker's marking streams and decodes its final event.
    ///
    /// Marking takes about a minute — long enough that a plain request came
    /// back as a Cloudflare 524 before the model had finished reading. The
    /// Worker sends `{"phase":"working"}` every ten seconds while it waits and
    /// `{"result":…}` at the end, so the connection never looks idle. Only the
    /// last event carries anything; the rest exist to keep the socket alive.
    private func streamedResult<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        let request = try request(path: path, body: body)

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport(L("応答を読み取れませんでした。"))
            }
            guard 200..<300 ~= http.statusCode else {
                var raw = Data()
                for try await byte in stream { raw.append(byte) }
                throw ProviderError.http(status: http.statusCode, message: message(from: raw))
            }

            for try await line in stream.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let failure = event["error"] as? String {
                    throw ProviderError.http(status: 502, message: failure)
                }
                guard let result = event["result"] else { continue } // A heartbeat.
                let encoded = try JSONSerialization.data(withJSONObject: result)
                guard let decoded = try? JSONDecoder().decode(T.self, from: encoded) else {
                    throw ProviderError.malformedResponse
                }
                return decoded
            }
            // The stream closed without ever sending a result.
            throw ProviderError.malformedResponse
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }

    /// Caps the long edge before upload.
    ///
    /// A full-resolution page is several megabytes once base64-encoded, and the
    /// model downsamples it anyway — sending it whole only adds upload time to
    /// a request that is already slow. Handwriting stays legible well below the
    /// native size.
    private static func downscaled(_ image: UIImage, longEdge: CGFloat = 1_600) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longEdge, longest > 0 else { return image }
        let scale = longEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return format
        }()).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let request = try request(path: path, body: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport(L("応答を読み取れませんでした。"))
            }
            guard 200..<300 ~= http.statusCode else {
                throw ProviderError.http(status: http.statusCode, message: message(from: data))
            }
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Direct Claude provider

/// The earlier build's path: the app holds an Anthropic key and calls the API
/// itself. Kept so switching back is a one-line change in `AI.provider`, and
/// so a developer can compare the two models on the same content.
final class ClaudeDirectProvider: AIProvider {
    var isConfigured: Bool { ClaudeChatService.hasAPIKey }
    var displayName: String { "Claude \(ClaudeChatService.model)" }

    @MainActor
    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage] = [],
        expectsImages: Bool = false,
        onDelta: @escaping (String) -> Void
    ) async throws {
        if expectsImages && images.isEmpty {
            throw WorkerAIProvider.ProviderError.imageEncodingFailed
        }
        try await ClaudeChatService.streamReply(
            turns: turns.map {
                ClaudeChatService.Turn(role: $0.role == .user ? .user : .assistant, text: $0.text)
            },
            noteContext: noteContext,
            images: images,
            onDelta: onDelta
        )
    }

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        try await ProofGradingService.buildRubric(
            question: submission.questionText,
            modelAnswer: submission.modelAnswer
        )
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        guard let answerImage = submission.answerImage else {
            throw ProofGradingService.GradingError.missingModelAnswer
        }
        return try await ProofGradingService.grade(
            answerImage: answerImage,
            question: submission.questionText,
            rubric: rubric
        )
    }
}
