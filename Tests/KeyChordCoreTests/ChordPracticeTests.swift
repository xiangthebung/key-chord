import Foundation
import Testing
@testable import KeyChordCore

@Suite("Chord practice")
struct ChordPracticeTests {
    private func chord(_ text: String, mode: SubMode = .english) throws -> (TypingStep, PracticeChord) {
        let first = TypingPlanner(data: defaults, mode: mode).plan(text).steps.first { $0.isChord }
        let step = try #require(first)
        return (step, try #require(PracticeChord(step: step, data: defaults, mode: mode)))
    }

    @Test("Performance survives encoding with aggregate data only; idle time is excluded")
    func aggregatePersistence() throws {
        let (_, id) = try chord("cat")
        var history = PracticeHistory()
        history.record(id, correct: false, seconds: 2, hinted: false)
        history.record(id, correct: true, seconds: 1, hinted: true)
        history.record(id, correct: true, seconds: 90, hinted: false)
        history.record(id, correct: false, seconds: .nan, hinted: false)
        let encoded = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(PracticeHistory.self, from: encoded)
        let result = try #require(restored.performance(for: id))
        #expect(result.attempts == 4)
        #expect(result.mistakes == 2)
        #expect(result.hints == 1)
        #expect(result.accuracy == 0.5)
        #expect(result.averageSeconds == 1.5)
        #expect(result.timedAttempts == 2)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("cat"))
        #expect(!json.contains("output"))
        #expect(!json.contains("timestamp"))
    }

    @Test("Mistakes rank ahead of slow and fast chords; successful review reduces priority")
    func priorities() throws {
        let (_, missed) = try chord("cat"), (_, slow) = try chord("dog"), (_, fast) = try chord("sit")
        var history = PracticeHistory()
        history.record(missed, correct: false, seconds: 1, hinted: false)
        history.record(slow, correct: true, seconds: 6, hinted: false)
        history.record(fast, correct: true, seconds: 0.5, hinted: false)
        #expect(history.weakest(mode: .english).map(\.chord) == [missed, slow, fast])
        let before = try #require(history.performance(for: missed)).reviewPriority
        for _ in 0..<12 { history.record(missed, correct: true, seconds: 0.5, hinted: false) }
        #expect(try #require(history.performance(for: missed)).reviewPriority < before)
        #expect(history.weakest(mode: .english).first?.chord == slow)
        #expect(history.weakest(mode: .cpp).isEmpty)
    }

    @Test("A changed mapping starts fresh; Shift and mode remain separate")
    func identities() throws {
        let (_, original) = try chord("cat")
        let keys = try #require(original.keys(in: defaults, mode: .english, usable: { _ in true }))
        #expect(original != PracticeChord(keys: keys, shift: true, data: defaults, mode: .english))
        #expect(original != PracticeChord(keys: keys, shift: false, data: defaults, mode: .cpp))
        var changed = defaults
        changed.english.entries[keys] = .text(TextEntry(text: "different"))
        #expect(original.keys(in: changed, mode: .english, usable: { _ in true }) == nil)
        #expect(original.keys(in: defaults, mode: .english, usable: { _ in false }) == nil)
        changed.english.entries[keys] = .text(TextEntry(text: "cat", capitalizeNext: true))
        #expect(original.keys(in: changed, mode: .english, usable: { _ in true }) == nil)
    }

    @Test("Assessment accepts correct output, rejects extra keys and untranslatable chords")
    func assessment() throws {
        let (step, id) = try chord("cat")
        #expect(PracticeAssessment.matches(step, codes: Set(id.codes), shift: id.shift, context: .initial,
                                           data: defaults, mode: .english))
        #expect(!PracticeAssessment.matches(step, codes: Set(id.codes + [36]), shift: false, context: .initial,
                                            data: defaults, mode: .english))
        #expect(!PracticeAssessment.matches(step, codes: [], shift: false, context: .initial,
                                            data: defaults, mode: .english))
        var alternative = defaults
        alternative.english.entries[keys("F")] = .text(TextEntry(text: "cat"))
        let otherCodes = keys("F").indices.map { defaults.layout.keys[$0].code }
        #expect(PracticeAssessment.matches(step, codes: Set(otherCodes), shift: false, context: .initial,
                                           data: alternative, mode: .english))
        let spelled = TypingStep(action: .chord(keys: ["Quote", "A"], shift: false), kind: .fingerspell,
                                output: "a", note: "", source: 0..<1, group: 0)
        let vowel = Set(keys("C").indices.map { defaults.layout.keys[$0].code })
        #expect(!PracticeAssessment.matches(spelled, codes: vowel, shift: false, context: .initial,
                                            data: defaults, mode: .english))
    }

    @Test("Review contains the weak chords, repeats three times, and replays exactly", arguments: [SubMode.english, .cpp])
    func targetedReview(mode: SubMode) throws {
        let text = mode == .english ? "cat making anything" : "int count = max_size;"
        let plan = TypingPlanner(data: defaults, mode: mode).plan(text)
        let targets = Array(Set(plan.steps.compactMap { PracticeChord(step: $0, data: defaults, mode: mode) }))
        var history = PracticeHistory()
        for target in targets { history.record(target, correct: false, seconds: 2, hinted: false) }
        let review = try #require(PracticeReview.make(history: history, data: defaults, mode: mode, limit: 3))
        #expect(review.targets.count == min(targets.count, 3))
        #expect(review.guide.normalCount == 0)
        #expect(try replay(review.guide) == review.text)
        let included = review.guide.steps.compactMap { PracticeChord(step: $0, data: defaults, mode: mode) }
        for target in review.targets { #expect(included.filter { $0 == target }.count >= 3) }
        #expect(review.text.split(separator: "\n").count % 3 == 0)
    }

    @Test("Empty history and blocked or stale chords produce no review")
    func unavailableReview() throws {
        #expect(PracticeReview.make(history: PracticeHistory(), data: defaults, mode: .english) == nil)
        let (_, id) = try chord("cat")
        var history = PracticeHistory()
        history.record(id, correct: false, seconds: 2, hinted: false)
        #expect(PracticeReview.make(history: history, data: defaults, mode: .english, usable: { _ in false }) == nil)
        #expect(PracticeReview.make(history: history, data: defaults, mode: .cpp) == nil)
        var changed = defaults
        let chordKeys = try #require(id.keys(in: defaults, mode: .english, usable: { _ in true }))
        changed.english.entries[chordKeys] = .text(TextEntry(text: "different"))
        #expect(PracticeReview.make(history: history, data: changed, mode: .english) == nil)
    }

    @Test("Suffixes and joined syllables keep the word context they need", arguments: ["making", "anything"])
    func contextualReview(text: String) throws {
        let usable = macBookLimits.usable(in: defaults.layout)
        let plan = TypingPlanner(data: defaults, mode: .english, usable: usable).plan(text)
        let last = plan.steps.last { $0.isChord }
        let step = try #require(last)
        let target = try #require(PracticeChord(step: step, data: defaults, mode: .english))
        var history = PracticeHistory()
        history.record(target, correct: false, seconds: 2, hinted: false)
        let drill = try #require(PracticeReview.make(history: history, data: defaults, mode: .english, usable: usable))
        #expect(drill.targets == [target])
        #expect(try replay(drill.guide) == drill.text)
        #expect(drill.guide.steps.filter { PracticeChord(step: $0, data: defaults, mode: .english) == target }.count >= 3)
    }
}
