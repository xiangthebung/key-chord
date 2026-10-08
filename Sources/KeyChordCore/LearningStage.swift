// The course separates seeing a model, guided practice, fresh recall, and voluntary use in an editor.
// A pass is current performance; retention needs successful checks on later scheduled days.

public enum LearningStage: String, CaseIterable, Sendable {
    case see, tryIt, recall, use

    public var title: String {
        let id = self == .tryIt ? "try" : rawValue
        return DesignSystem.Labels.stages[id]!
    }
}

/// Lesson-level aggregates contain no exercise text, key events, or exact times. An initial clean
/// unaided pass starts the schedule; it is not itself a delayed check. Same-day practice cannot add one.
public struct CourseDelayedCheck: Codable, Equatable, Sendable {
    public private(set) var firstPassDay: Int?
    public private(set) var lastActivityDay: Int?
    public private(set) var lastCheckDay: Int?
    public private(set) var firstDelayedCheckDay: Int?
    public private(set) var nextCheckDay: Int?
    public private(set) var successfulDelayedChecks = 0

    public init() {}

    public var isRetained: Bool {
        guard successfulDelayedChecks >= 3, let first = firstDelayedCheckDay, let last = lastCheckDay else { return false }
        let span = last.subtractingReportingOverflow(first)
        return !span.overflow && span.partialValue >= 4
    }

    public func isDue(day: Int) -> Bool { nextCheckDay.map { day >= $0 } ?? false }

    /// Only a fresh completed passage with chord provenance, no assistance, and no errors qualifies.
    /// Assisted/errorful completions restart the delayed streak while preserving the earlier pass.
    /// Clock rollback adds no evidence.
    public mutating func record(cleanUnaidedPass: Bool, day: Int) {
        guard lastActivityDay.map({ day >= $0 }) ?? true else { return }
        lastActivityDay = day
        guard cleanUnaidedPass else {
            lastCheckDay = nil
            firstDelayedCheckDay = nil
            successfulDelayedChecks = 0
            nextCheckDay = firstPassDay.map { _ in Self.after(day, days: 1) }
            return
        }
        guard firstPassDay != nil else {
            firstPassDay = day
            nextCheckDay = Self.after(day, days: 1)
            return
        }
        guard isDue(day: day), lastCheckDay != day, day > firstPassDay! else { return }
        if firstDelayedCheckDay == nil { firstDelayedCheckDay = day }
        lastCheckDay = day
        successfulDelayedChecks = min(successfulDelayedChecks + 1, 5)
        let intervals = [3, 7, 14, 30, 30]
        nextCheckDay = Self.after(day, days: intervals[successfulDelayedChecks - 1])
    }

    private static func after(_ day: Int, days: Int) -> Int {
        let sum = day.addingReportingOverflow(days)
        return sum.overflow ? Int.max : sum.partialValue
    }
}
