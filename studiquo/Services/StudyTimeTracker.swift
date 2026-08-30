import Foundation
import SwiftData
import SwiftUI

/// Records how long the app is actually used, so "今日の勉強時間" and the
/// study streak reflect real activity.
///
/// `StudyActivity` rows existed but nothing ever wrote one, which is why both
/// figures sat at zero. Time is accrued while the app is in the foreground and
/// folded into a single row per day rather than one per session — a day's
/// worth of app switches would otherwise leave hundreds of rows behind, and
/// the streak only cares whether a day has any activity at all.
@MainActor
final class StudyTimeTracker {
    static let shared = StudyTimeTracker()

    /// Source title of the row this tracker owns. Sessions logged by the
    /// flashcard/study screens use their own titles and are left alone.
    static let appUsageTitle = "アプリの利用"

    /// Spans shorter than this are dropped: opening the app to check one
    /// thing is not studying, and rounding it up would inflate the streak.
    private static let minimumSpan: TimeInterval = 20
    /// How often an uninterrupted session is written out, so time survives
    /// the app being killed rather than only being saved on backgrounding.
    private static let flushInterval: TimeInterval = 60

    private var context: ModelContext?
    private var segmentStart: Date?
    private var flushTimer: Timer?

    private init() {}

    func configure(context: ModelContext) {
        self.context = context
    }

    /// Drive from `scenePhase`: the app is only "in use" while active.
    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active: begin()
        case .inactive, .background: end()
        @unknown default: end()
        }
    }

    private func begin() {
        guard segmentStart == nil else { return }
        segmentStart = .now
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { _ in
            Task { @MainActor in self.flush() }
        }
    }

    private func end() {
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
        segmentStart = nil
    }

    /// Banks whatever has accrued since the last flush and restarts the
    /// clock, so repeated calls never double-count the same seconds.
    private func flush() {
        guard let start = segmentStart else { return }
        let now = Date.now
        let elapsed = now.timeIntervalSince(start)
        segmentStart = now
        guard elapsed >= Self.minimumSpan, let context else { return }
        record(seconds: elapsed, in: context)
    }

    private func record(seconds: TimeInterval, in context: ModelContext) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let title = Self.appUsageTitle
        let descriptor = FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.sourceTitle == title && $0.startedAt >= dayStart }
        )
        if let existing = try? context.fetch(descriptor).first {
            // The row's span *is* the day's total: pushing `endedAt` out by
            // the elapsed seconds keeps `duration` correct without a separate
            // accumulator field.
            existing.endedAt = existing.endedAt.addingTimeInterval(seconds)
        } else {
            let activity = StudyActivity(
                startedAt: .now,
                endedAt: Date.now.addingTimeInterval(seconds),
                sourceTitle: title
            )
            context.insert(activity)
        }
        try? context.save()
    }
}
