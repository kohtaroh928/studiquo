import XCTest
@testable import studiquo

final class PlanAllowanceTests: XCTestCase {
    /// The Worker's `DEFAULT_AI_LIMITS.plans` (`mcp-server/src/ai-limits.ts`).
    func testAllowancesMatchTheWorkersBudgets() {
        XCTAssertEqual(PlanAllowance.forPlan(.standard), PlanAllowance(weeklyCredits: 30, fiveHourCredits: 10, callsPerMinute: 5))
        XCTAssertEqual(PlanAllowance.forPlan(.plus), PlanAllowance(weeklyCredits: 350, fiveHourCredits: 100, callsPerMinute: 10))
        XCTAssertEqual(PlanAllowance.forPlan(.pro), PlanAllowance(weeklyCredits: 920, fiveHourCredits: 250, callsPerMinute: 20))
        XCTAssertEqual(PlanAllowance.forPlan(.free).weeklyCredits, 0)
    }

    func testWeeklyTurnsPerModel() {
        let plus = PlanAllowance.forPlan(.plus)
        let pro = PlanAllowance.forPlan(.pro)
        XCTAssertEqual(plus.weeklyTurns(creditsPerTurn: 20), 17)    // Sol
        XCTAssertEqual(plus.weeklyTurns(creditsPerTurn: 1), 350)    // Luna
        XCTAssertEqual(pro.weeklyTurns(creditsPerTurn: 22), 41)     // Terra
        XCTAssertEqual(pro.weeklyTurns(creditsPerTurn: 100), 9)     // Astra
        XCTAssertEqual(PlanAllowance.forPlan(.standard).weeklyTurns(creditsPerTurn: 1), 30) // Luna
        XCTAssertEqual(plus.weeklyTurns(creditsPerTurn: 0), 0)
    }

    func testHigherPlansNeverAllowLessInAnyWindow() {
        let plans: [StudiquoPlan] = [.free, .standard, .plus, .pro]
        for (lower, higher) in zip(plans, plans.dropFirst()) {
            let a = PlanAllowance.forPlan(lower), b = PlanAllowance.forPlan(higher)
            XCTAssertLessThanOrEqual(a.weeklyCredits, b.weeklyCredits)
            XCTAssertLessThanOrEqual(a.fiveHourCredits, b.fiveHourCredits)
            XCTAssertLessThanOrEqual(a.callsPerMinute, b.callsPerMinute)
        }
    }

    /// A week's allowance cannot be spent within one 5-hour window.
    func testFiveHoursIsLessThanTheWeek() {
        for plan in [StudiquoPlan.standard, .plus, .pro] {
            let allowance = PlanAllowance.forPlan(plan)
            XCTAssertLessThan(allowance.fiveHourCredits, allowance.weeklyCredits)
        }
    }
}
