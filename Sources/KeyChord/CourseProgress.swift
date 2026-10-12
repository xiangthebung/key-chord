import Foundation
import KeyChordCore

/// Reuses the original lesson identifiers and defaults so existing progress survives the new UI.
/// Only lesson identifiers are saved; passages and input remain in memory.
final class CourseProgress {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var completed: Set<String> {
        let saved = Set(defaults.stringArray(forKey: "courseCompleted") ?? [])
        let migrated = Course.migratedCompletedIDs(saved, fromVersion: defaults.integer(forKey: "courseCurriculumVersion"))
        if migrated != saved { defaults.set(migrated.sorted(), forKey: "courseCompleted") }
        defaults.set(Course.curriculumVersion, forKey: "courseCurriculumVersion")
        return migrated
    }

    var lastStep: String? {
        get { defaults.string(forKey: "courseLastStep") }
        set { defaults.set(newValue, forKey: "courseLastStep") }
    }

    var resumeIndex: Int {
        let done = completed
        let last = lastStep.flatMap(Course.index(of:)) ?? 0
        if !done.contains(Course.steps[last].id) { return last }
        let order = Array(last..<Course.steps.count) + Array(0..<last)
        return order.first { Course.steps[$0].mode == Course.steps[last].mode && !done.contains(Course.steps[$0].id) } ?? last
    }

    func markDone(_ id: String) {
        var done = completed
        done.insert(id)
        defaults.set(done.sorted(), forKey: "courseCompleted")
    }
}
