import Foundation

/// How much AI each plan includes, as the plans screen states it. These are
/// the Worker's `PLAN_BUDGETS` (`mcp-server/src/ai-credits.js`), hand-synced:
/// the Worker is what actually enforces them, so a number changed on only one
/// side makes the screen promise something the server will not give (or
/// refuse something it would). Credits per model are `AIModelInfo.credits`.
struct PlanAllowance: Equatable {
    /// Credits per month (calendar month, Japan time).
    let monthlyCredits: Int
    /// Credits per day (Japan time).
    let dailyCredits: Int
    /// Credits per rolling 5 hours.
    let fiveHourCredits: Int
    /// Calls per minute.
    let callsPerMinute: Int

    static func forPlan(_ plan: StudiquoPlan) -> PlanAllowance {
        switch plan {
        case .free: PlanAllowance(monthlyCredits: 0, dailyCredits: 0, fiveHourCredits: 0, callsPerMinute: 0)
        case .standard: PlanAllowance(monthlyCredits: 30, dailyCredits: 15, fiveHourCredits: 10, callsPerMinute: 5)
        case .plus: PlanAllowance(monthlyCredits: 1_500, dailyCredits: 600, fiveHourCredits: 400, callsPerMinute: 10)
        case .pro: PlanAllowance(monthlyCredits: 4_000, dailyCredits: 1_500, fiveHourCredits: 1_000, callsPerMinute: 20)
        }
    }

    /// How many chat turns the monthly credits cover on a model that costs `credits` each.
    func monthlyTurns(creditsPerTurn credits: Int) -> Int {
        credits > 0 ? monthlyCredits / credits : 0
    }
}
