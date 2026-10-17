import Foundation

/// The kind of AI app an owner is about to connect. A pairing code is made for
/// one kind and the server refuses to spend it on another, so a code meant for
/// Claude cannot be used to connect some other app.
enum MCPConnectionKind: String, CaseIterable, Identifiable, Codable {
    case claude, chatgpt, codex, other

    var id: String { rawValue }

    /// Shown in the kind picker and in the connected-apps list.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .codex: return "Codex"
        case .other: return L("その他")
        }
    }
}

/// The server's answer to "make me a pairing code".
struct MCPPairingCode: Decodable, Equatable {
    let code: String
    let kind: MCPConnectionKind
    let expiresInSeconds: Int

    /// The code in groups of four, easier to read off the iPad and type.
    var groupedCode: String { MCPPairingCode.grouped(code) }

    static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: min(4, code.count - start))
            return String(code[from..<to])
        }.joined(separator: "-")
    }
}
