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
/// The OpenAI cases are logical names the Worker resolves to whatever model
/// it's currently configured with (`OPENAI_*_MODEL`) — the client never needs
/// to know (or update to track) the real OpenAI model ID.
enum AIModelID: String, CaseIterable, Identifiable, Codable {
    case geminiFlashLite = "gemini-3.5-flash-lite"
    case claudeSonnet = "claude-sonnet-5-5"
    case openAILuna = "openai-luna"
    case openAITerra = "openai-terra"
    case openAISol = "openai-sol"
    case claudeOpus = "claude-opus-5-5"
    case openAIAstra = "openai-astra"

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
    /// AI credits one chat turn on this model uses — the Worker's
    /// `MODEL_CREDITS` (`mcp-server/src/ai-credits.js`), hand-synced.
    let credits: Int
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
        AIModelInfo(id: .geminiFlashLite, displayName: "Gemini 3.5 Flash-Lite", providerName: "Google", requiredPlan: .standard, credits: 4),
        AIModelInfo(id: .claudeSonnet, displayName: "Claude Sonnet 5.5", providerName: "Anthropic", requiredPlan: .plus, credits: 20),
        AIModelInfo(id: .openAILuna, displayName: "ChatGPT Luna", providerName: "OpenAI", requiredPlan: .plus, credits: 1),
        AIModelInfo(id: .openAITerra, displayName: "ChatGPT Terra", providerName: "OpenAI", requiredPlan: .plus, credits: 22),
        AIModelInfo(id: .openAISol, displayName: "ChatGPT Sol", providerName: "OpenAI", requiredPlan: .plus, credits: 20),
        AIModelInfo(id: .claudeOpus, displayName: "Claude Opus 5.5", providerName: "Anthropic", requiredPlan: .pro, credits: 40),
        AIModelInfo(id: .openAIAstra, displayName: "ChatGPT Astra", providerName: "OpenAI", requiredPlan: .pro, credits: 100),
    ]

    /// Always selectable, on every plan — what a freshly-installed app (or a
    /// chat thread that never had a model explicitly chosen) falls back to.
    static let defaultModel = AIModelID.geminiFlashLite

    /// Whether models from Anthropic and OpenAI are offered at all. Off until the
    /// AI disclosure names those providers, `AIDataDisclosure.currentVersion`
    /// is bumped to match the Worker's consent version, and the Worker's
    /// `AI_PROVIDER_APPROVED` review covers them. While it is off the app
    /// behaves as the initial single-processor (Google) release.
    static let thirdPartyModelsEnabled = false

    /// What the picker and the plan screen offer. The initial release offers
    /// one processor; the rest stay catalogued but hidden until
    /// `thirdPartyModelsEnabled`.
    static var offered: [AIModelInfo] {
        thirdPartyModelsEnabled ? all : all.filter { $0.id == defaultModel }
    }

    static func info(for id: AIModelID) -> AIModelInfo? {
        all.first { $0.id == id }
    }

    /// Every model `plan` is entitled to call. `StudiquoPlan`'s raw-value
    /// ordering (free < standard < plus < pro) means a higher plan always
    /// includes every model a lower plan has.
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
            // Only a model that is currently offered can be the choice, so a
            // saved selection can never reach a provider that is switched off.
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let id = AIModelID(rawValue: raw),
               AIModelCatalog.offered.contains(where: { $0.id == id }) {
                return id
            }
            return AIModelCatalog.defaultModel
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
