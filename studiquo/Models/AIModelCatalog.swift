import Foundation

/// Which cloud AI model AIトーク (and marking/review) can be pointed at, and
/// which plan unlocks it.
///
/// The raw values are the exact strings the Worker expects in the `"model"`
/// field of `/api/ai/chat`, `/api/ai/rubric`, `/api/ai/grade`, and
/// `/api/ai/review` (see `mcp-server/src/ai.js`'s `PLAN_MODELS` table). The
/// two tables are hand-synced, the same "two places kept in step by hand"
/// pattern `legal.js`'s own doc comment describes for policy text — adding a
/// model on only one side either leaves it unselectable here, or lets it be
/// requested but rejected with 403 the moment it's actually sent. Keep the
/// ID strings identical on both sides.
///
/// OpenAI's real model IDs aren't finalized yet, so `openAIMid`/
/// `openAIFlagship` are logical names the Worker resolves to whatever model
/// it's currently configured with — the client never needs to know (or
/// update to track) the real OpenAI model ID.
enum AIModelID: String, CaseIterable, Identifiable, Codable {
    case geminiFlashLite = "gemini-3.5-flash-lite"
    case claudeHaiku = "claude-haiku-4-5-20251001"
    case claudeSonnet = "claude-sonnet-5"
    case claudeOpus = "claude-opus-5-5"
    case openAIMid = "openai-mid"
    case openAIFlagship = "openai-flagship"

    var id: String { rawValue }
}

/// Display metadata for one `AIModelID` — everything the model picker and
/// the plan comparison screen need, besides the plan-gate check itself
/// (which the Worker is the actual source of truth for; see
/// `AIModelCatalog.isAvailable`'s doc comment).
struct AIModelInfo: Identifiable, Equatable {
    let id: AIModelID
    let displayName: String
    let providerName: String
    let requiredPlan: StudiquoPlan
}

/// The studiquo-side mirror of the Worker's `PLAN_MODELS` table.
///
/// This only drives what the UI *offers* and which locked models show an
/// upgrade prompt — the Worker enforces the real gate server-side (403 for a
/// model outside the caller's plan), so a stale or tampered client can never
/// grant itself a model it hasn't paid for.
enum AIModelCatalog {
    /// Every model the app can ask for, in the order shown in the picker.
    static let all: [AIModelInfo] = [
        AIModelInfo(id: .geminiFlashLite, displayName: "Gemini 3.5 Flash-Lite", providerName: "Google", requiredPlan: .standard),
        AIModelInfo(id: .claudeHaiku, displayName: "Claude Haiku 4.5", providerName: "Anthropic", requiredPlan: .plus),
        AIModelInfo(id: .claudeSonnet, displayName: "Claude Sonnet 5", providerName: "Anthropic", requiredPlan: .plus),
        AIModelInfo(id: .openAIMid, displayName: "GPT-5.1 mini", providerName: "OpenAI", requiredPlan: .plus),
        AIModelInfo(id: .claudeOpus, displayName: "Claude Opus 5.5", providerName: "Anthropic", requiredPlan: .pro),
        AIModelInfo(id: .openAIFlagship, displayName: "GPT-5.1", providerName: "OpenAI", requiredPlan: .pro),
    ]

    /// Always selectable, on every plan — what a freshly-installed app (or a
    /// chat thread that never had a model explicitly chosen) falls back to.
    static let defaultModel = AIModelID.geminiFlashLite

    /// Initial release offers one processor. Metadata for other models is kept
    /// for compatibility; enabling them requires a new disclosure and approval.
    static var offered: [AIModelInfo] { all.filter { $0.id == defaultModel } }

    static func info(for id: AIModelID) -> AIModelInfo? {
        all.first { $0.id == id }
    }

    /// Every model `plan` is entitled to call. `StudiquoPlan`'s raw-value
    /// ordering (standard < plus < pro) means a higher plan always includes
    /// every model a lower plan has.
    static func availableModels(for plan: StudiquoPlan) -> [AIModelInfo] {
        all.filter { $0.requiredPlan <= plan }
    }

    static func isAvailable(_ id: AIModelID, for plan: StudiquoPlan) -> Bool {
        guard let info = info(for: id) else { return false }
        return info.requiredPlan <= plan
    }
}

/// The model AIトーク (and marking/review) currently asks for — persisted
/// across launches via `UserDefaults`, the same lightweight pattern
/// `AIReviewService.isEnabled` uses for its own toggle rather than a full
/// `@AppStorage`-backed model, since this is read from plain Swift code
/// (`WorkerAIProvider`) with no SwiftUI environment to pull from.
///
/// This only remembers the student's *choice* — it never grants anything by
/// itself. The Worker is the real gate: it rejects a `model` outside the
/// caller's plan with 403 regardless of what's stored here. The model
/// picker UI is expected to only ever write a model `AIModelCatalog
/// .isAvailable` already says the current plan allows.
enum AIModelSelection {
    static let defaultsKey = "selectedAIModelID"

    static var current: AIModelID {
        get {
            AIModelCatalog.defaultModel
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
