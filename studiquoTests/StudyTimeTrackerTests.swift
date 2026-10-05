import SwiftData
import SwiftUI
import XCTest
@testable import studiquo

@MainActor
final class StudyTimeTrackerTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    private let enabledKey = "studyTimeTrackingEnabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    func testRecordsOnlyWhileSceneIsActiveAndStudySurfaceIsOpen() throws {
        let (tracker, clock, context) = try makeTracker()

        tracker.setStudying(true)
        clock.advance(by: 40)
        XCTAssertTrue(try activities(in: context).isEmpty)

        tracker.handle(scenePhase: .active)
        clock.advance(by: 45)
        tracker.handle(scenePhase: .inactive)

        let activity = try XCTUnwrap(activities(in: context).first)
        XCTAssertEqual(activity.sourceTitle, StudyTimeTracker.appUsageTitle)
        XCTAssertEqual(activity.duration, 45, accuracy: 0.001)
    }

    func testSpanShorterThanTwentySecondsIsDiscarded() throws {
        let (tracker, clock, context) = try makeTracker()
        tracker.handle(scenePhase: .active)
        tracker.setStudying(true)

        clock.advance(by: 19)
        tracker.setStudying(false)

        XCTAssertTrue(try activities(in: context).isEmpty)
    }

    func testDisabledSettingPreventsRecording() throws {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let (tracker, clock, context) = try makeTracker()

        tracker.handle(scenePhase: .active)
        tracker.setStudying(true)
        clock.advance(by: 120)
        tracker.handle(scenePhase: .background)

        XCTAssertTrue(try activities(in: context).isEmpty)
    }

    func testMultipleSessionsAccumulateIntoOneDailyRow() throws {
        let (tracker, clock, context) = try makeTracker()
        tracker.handle(scenePhase: .active)
        tracker.setStudying(true)
        clock.advance(by: 30)
        tracker.handle(scenePhase: .inactive)

        clock.advance(by: 10)
        tracker.handle(scenePhase: .active)
        clock.advance(by: 25)
        tracker.setStudying(false)

        let rows = try activities(in: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first).duration, 55, accuracy: 0.001)
    }

    func testRepeatedStateUpdatesDoNotResetOrDoubleCountSegment() throws {
        let (tracker, clock, context) = try makeTracker()
        tracker.handle(scenePhase: .active)
        tracker.setStudying(true)
        clock.advance(by: 10)

        tracker.handle(scenePhase: .active)
        tracker.setStudying(true)
        clock.advance(by: 15)
        tracker.handle(scenePhase: .inactive)

        let activity = try XCTUnwrap(activities(in: context).first)
        XCTAssertEqual(activity.duration, 25, accuracy: 0.001)
    }

    private func makeTracker() throws -> (StudyTimeTracker, TestClock, ModelContext) {
        let container = try makeContainer()
        let context = container.mainContext
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let tracker = StudyTimeTracker(now: { clock.date }, schedulesFlushTimer: false)
        tracker.configure(context: context)
        return (tracker, clock, context)
    }

    private func activities(in context: ModelContext) throws -> [StudyActivity] {
        try context.fetch(FetchDescriptor<StudyActivity>())
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: studiquoSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }
}

private final class TestClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }

    func advance(by interval: TimeInterval) {
        date = date.addingTimeInterval(interval)
    }
}
