import XCTest
@testable import studiquo

final class PlanAllowanceTests: XCTestCase {
    /// The Worker's `PLAN_BUDGETS` (`mcp-server/src/ai-credits.js`).
    func testAllowancesMatchTheWorkersBudgets() {
        XCTAssertEqual(PlanAllowance.forPlan(.standard), PlanAllowance(monthlyCredits: 120, dailyCredits: 60, fiveHourCredits: 40, callsPerMinute: 5))
        XCTAssertEqual(PlanAllowance.forPlan(.plus), PlanAllowance(monthlyCredits: 1_500, dailyCredits: 600, fiveHourCredits: 400, callsPerMinute: 10))
        XCTAssertEqual(PlanAllowance.forPlan(.pro), PlanAllowance(monthlyCredits: 4_000, dailyCredits: 1_500, fiveHourCredits: 1_000, callsPerMinute: 20))
        XCTAssertEqual(PlanAllowance.forPlan(.free).monthlyCredits, 0)
    }

    func testMonthlyTurnsPerModel() {
        let plus = PlanAllowance.forPlan(.plus)
        let pro = PlanAllowance.forPlan(.pro)
        XCTAssertEqual(plus.monthlyTurns(creditsPerTurn: 20), 75)    // Sol
        XCTAssertEqual(plus.monthlyTurns(creditsPerTurn: 1), 1_500)  // Luna
        XCTAssertEqual(pro.monthlyTurns(creditsPerTurn: 22), 181)    // Terra
        XCTAssertEqual(pro.monthlyTurns(creditsPerTurn: 100), 40)    // Astra
        XCTAssertEqual(PlanAllowance.forPlan(.standard).monthlyTurns(creditsPerTurn: 1), 120) // Luna
        XCTAssertEqual(plus.monthlyTurns(creditsPerTurn: 0), 0)
    }

    func testHigherPlansNeverAllowLessInAnyWindow() {
        let plans: [StudiquoPlan] = [.free, .standard, .plus, .pro]
        for (lower, higher) in zip(plans, plans.dropFirst()) {
            let a = PlanAllowance.forPlan(lower), b = PlanAllowance.forPlan(higher)
            XCTAssertLessThanOrEqual(a.monthlyCredits, b.monthlyCredits)
            XCTAssertLessThanOrEqual(a.dailyCredits, b.dailyCredits)
            XCTAssertLessThanOrEqual(a.fiveHourCredits, b.fiveHourCredits)
            XCTAssertLessThanOrEqual(a.callsPerMinute, b.callsPerMinute)
        }
    }
}
