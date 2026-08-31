import Foundation
import Security
import UIKit

/// Talks to the Claude Messages API on the student's behalf.
///
/// Swift has no official Anthropic SDK, so this is a direct HTTPS client
/// against `POST /v1/messages`. Responses are streamed: a tutoring answer can
/// run long, and watching it arrive is the difference between the chat
/// feeling alive and feeling broken.
///
/// The API key is the user's own, held in the keychain and never written to
/// logs, notes, or the MCP snapshot.
enum ClaudeChatService {
    static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    // MARK: Credentials

    private static let keychainService = "com.yabuko.studiquo.claude-api"
    private static let keychainAccount = "api-key"

    static var apiKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static var hasAPIKey: Bool { apiKey != nil }

    static func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removeAPIKey() { saveAPIKey("") }

    // MARK: Conversation

    struct Turn {
        enum Role: String { case user, assistant }
        let role: Role
        let text: String
    }

    enum ServiceError: LocalizedError {
        case missingKey
        case http(status: Int, message: String)
        case refused(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return L("AIのAPIキーが設定されていません。トーク画面の設定から登録してください。")
            case .http(let status, let message):
                if status == 401 {
                    return L("APIキーが正しくないようです。設定を確認してください。")
                }
                if status == 429 {
                    return L("リクエストが多すぎます。少し待ってからもう一度試してください。")
                }
                return L("AIに接続できませんでした（\(status)）。\(message)")
            case .refused(let reason):
                return reason
            case .transport(let message):
                return L("通信に失敗しました：\(message)")
            }
        }
    }

    /// What Claude is told it is doing here. Deliberately a study partner
    /// rather than an answer machine — the app is for learning, so working a
    /// problem through beats handing over the result.
    static func systemPrompt(noteContext: String) -> String {
        var prompt = """
        あなたは学習アプリ「Studiquo」に組み込まれた学習パートナーです。相手は勉強中の学生です。

        - 答えだけを渡さず、考え方の筋道を示してから答えに導いてください。
        - 相手が解いている途中なら、次の一手をひとつだけ示すこと。
        - 用語は定義してから使うこと。
        - 数式は簡潔に、必要なら箇条書きで段階を分けること。
        - わからないことは推測せず、わからないと言うこと。
        - 返答は日本語で、簡潔に。長い前置きは書かないこと。
        """
        let trimmed = noteContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prompt += """


            参考として、学生がいま開いているノートの本文を渡します。質問がこの内容に関係する場合はこれを踏まえて答えてください。関係しない場合は無視してください。

            <note>
            \(String(trimmed.prefix(8000)))
            </note>
            """
        }
        return prompt
    }

    /// Streams a reply, calling `onDelta` on the main actor for each chunk of
    /// text as it arrives.
    @MainActor
    static func streamReply(
        turns: [Turn],
        noteContext: String,
        images: [UIImage] = [],
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard let key = apiKey else { throw ServiceError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let messages = turns.enumerated().map { index, turn -> [String: Any] in
            guard !images.isEmpty, index == turns.indices.last, turn.role == .user else {
                return ["role": turn.role.rawValue, "content": turn.text]
            }
            var content: [[String: Any]] = [["type": "text", "text": turn.text]]
            for image in images.prefix(4) {
                guard let data = encoded(image) else { continue }
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": data,
                    ],
                ])
            }
            return ["role": turn.role.rawValue, "content": content]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "stream": true,
            "system": systemPrompt(noteContext: noteContext),
            // Adaptive thinking: explaining a topic well is exactly the kind
            // of work that benefits, and `medium` effort keeps a chat reply
            // from taking longer than a student will wait.
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "medium"],
            // Routes around a safety refusal instead of returning nothing.
            "betas": ["server-side-fallback-2026-07-01"],
            "fallbacks": "default",
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServiceError.transport(L("応答を読み取れませんでした。"))
            }
            guard 200..<300 ~= http.statusCode else {
                // An error response is JSON, not SSE — drain it for the
                // message the API put in it.
                var raw = Data()
                for try await byte in stream { raw.append(byte) }
                throw ServiceError.http(status: http.statusCode, message: errorMessage(from: raw))
            }

            for try await line in stream.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }

                switch type {
                case "content_block_delta":
                    // Only `text_delta` is rendered. Thinking arrives as its
                    // own delta type and is not part of the answer.
                    guard let delta = event["delta"] as? [String: Any],
                          delta["type"] as? String == "text_delta",
                          let text = delta["text"] as? String else { continue }
                    onDelta(text)
                case "message_delta":
                    guard let delta = event["delta"] as? [String: Any],
                          delta["stop_reason"] as? String == "refusal" else { continue }
                    throw ServiceError.refused(
                        L("この内容には回答できませんでした。質問を変えて試してください。")
                    )
                case "error":
                    let message = (event["error"] as? [String: Any])?["message"] as? String
                    throw ServiceError.transport(message ?? L("不明なエラー"))
                default:
                    continue
                }
            }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.transport(error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }

    private static func encoded(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1400
        let longest = max(image.size.width, image.size.height)
        let target: CGSize
        if longest > maxSide {
            let ratio = maxSide / longest
            target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        } else {
            target = image.size
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.pngData()?.base64EncodedString()
    }
}
