import Foundation

/// How much AI each plan includes, as the plans screen states it. These are
/// the Worker's defaults in `mcp-server/src/ai-limits.ts` (`DEFAULT_AI_LIMITS.plans`),
/// hand-synced: the Worker is what actually enforces them, so a number changed
/// on only one side — including through the Worker's `AI_LIMITS` variable —
/// makes the screen promise something the server will not give (or refuse
/// something it would). Credits per model are `AIModelInfo.credits`.
struct PlanAllowance: Equatable {
    /// Credits per week, counted from the first use (7 days from there, not a calendar week).
    let weeklyCredits: Int
    /// Credits per 5 hours, counted from the first use (a fixed window, not a sliding one).
    let fiveHourCredits: Int
    /// Calls per minute.
    let callsPerMinute: Int

    static func forPlan(_ plan: StudiquoPlan) -> PlanAllowance {
        switch plan {
        case .free: PlanAllowance(weeklyCredits: 0, fiveHourCredits: 0, callsPerMinute: 0)
        case .standard: PlanAllowance(weeklyCredits: 30, fiveHourCredits: 10, callsPerMinute: 5)
        case .plus: PlanAllowance(weeklyCredits: 350, fiveHourCredits: 100, callsPerMinute: 10)
        case .pro: PlanAllowance(weeklyCredits: 920, fiveHourCredits: 250, callsPerMinute: 20)
        }
    }

    /// How many chat turns the weekly credits cover on a model that costs `credits` each.
    func weeklyTurns(creditsPerTurn credits: Int) -> Int {
        credits > 0 ? weeklyCredits / credits : 0
    }
}
