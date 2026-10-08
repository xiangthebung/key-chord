import Foundation
import Testing
@testable import KeyChordCore

@Suite("Lesson stages and delayed checks")
struct LearningStageTests {
    @Test("The learning sequence names all four stages")
    func sequence() {
        #expect(LearningStage.allCases.map(\.title) == ["See", "Try", "Recall", "Use"])
    }

    @Test("An initial pass and same-day repetitions never establish retention")
    func repetitions() {
        var check = CourseDelayedCheck()
        for _ in 0..<100 { check.record(cleanUnaidedPass: true, day: 100) }
        #expect(check.firstPassDay == 100)
        #expect(check.successfulDelayedChecks == 0)
        #expect(check.nextCheckDay == 101)
        #expect(!check.isRetained)
        check.record(cleanUnaidedPass: true, day: 101)
        for _ in 0..<100 { check.record(cleanUnaidedPass: true, day: 101) }
        check.record(cleanUnaidedPass: true, day: 102)
        #expect(check.successfulDelayedChecks == 1)
        #expect(check.nextCheckDay == 104)
    }

    @Test("Three later due checks can establish retention and assistance resets the claim")
    func spacing() {
        var check = CourseDelayedCheck()
        check.record(cleanUnaidedPass: true, day: 100)
        for day in [101, 104, 111] { check.record(cleanUnaidedPass: true, day: day) }
        #expect(check.successfulDelayedChecks == 3)
        #expect(check.isRetained)
        check.record(cleanUnaidedPass: false, day: 112)
        #expect(!check.isRetained)
        #expect(check.firstPassDay == 100)
        #expect(check.nextCheckDay == 113)
    }

    @Test("Clock rollback, overflow, and aggregate round-trip are conservative")
    func datesAndPersistence() throws {
        var check = CourseDelayedCheck()
        check.record(cleanUnaidedPass: true, day: 100)
        let before = check
        check.record(cleanUnaidedPass: false, day: 99)
        #expect(check == before)
        let encoded = try JSONEncoder().encode(check)
        #expect(try JSONDecoder().decode(CourseDelayedCheck.self, from: encoded) == check)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("text"))
        #expect(!json.contains("timestamp"))
        var end = CourseDelayedCheck()
        end.record(cleanUnaidedPass: true, day: Int.max)
        end.record(cleanUnaidedPass: true, day: Int.max)
        #expect(end.nextCheckDay == Int.max)
        #expect(end.successfulDelayedChecks == 0)
        #expect(!end.isRetained)
    }
}
