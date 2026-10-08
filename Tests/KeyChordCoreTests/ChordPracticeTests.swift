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

    @Test("Review practices weak chords three times in curated contexts and replays exactly", arguments: [SubMode.english, .cpp])
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
        #expect(history.dueCount(mode: .english, day: 100, data: changed) == 0)
        #expect(history.dueCount(mode: .english, day: 100, data: defaults, usable: { _ in false }) == 0)
        #expect(history.dueCount(mode: .english, day: 100, data: defaults, rolloverLimit: 1) == 0)
        #expect(history.dueCount(mode: .english, day: 100, data: defaults) == 1)
    }

    @Test("Due badges and review skip obsolete, blocked, and upcoming records together")
    func filteredDueRecords() throws {
        let (_, due) = try chord("cat"), (_, stale) = try chord("dog"), (_, upcoming) = try chord("sit")
        let (_, otherMode) = try chord("int", mode: .cpp)
        var history = PracticeHistory()
        history.record(due, correct: false, seconds: 1, hinted: false, day: 100)
        history.record(stale, correct: false, seconds: 1, hinted: false, day: 100)
        history.record(upcoming, correct: true, seconds: 1, hinted: false, day: 100)
        history.record(otherMode, correct: false, seconds: 1, hinted: false, day: 100)
        var data = defaults
        let oldKeys = try #require(stale.keys(in: defaults, mode: .english, usable: { _ in true }))
        data.english.entries[oldKeys] = .text(TextEntry(text: "obsolete"))
        #expect(history.dueCount(mode: .english, day: 100) == 2)
        #expect(history.dueCount(mode: .english, day: 100, data: data) == 1)
        let dueKeys = try #require(due.keys(in: data, mode: .english, usable: { _ in true }))
        #expect(history.dueCount(mode: .english, day: 100, data: data, usable: { $0 != dueKeys }) == 0)
        let review = try #require(PracticeReview.make(history: history, data: data, mode: .english, limit: 1, day: 100))
        #expect(review.targets == [due])
        #expect(try replay(review.guide, data: data) == review.text)
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

    @Test("Legacy JSON preserves aggregates without inventing dated recall evidence")
    func legacyMigration() throws {
        let (_, id) = try chord("cat")
        let encodedChord = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let legacy = """
            {"records":[{"chord":\(encodedChord),"attempts":12,"mistakes":1,"hints":8,
            "timedAttempts":11,"totalSeconds":22,"recentErrorRate":0.1,"recentSeconds":2}]}
            """
        var history = try JSONDecoder().decode(PracticeHistory.self, from: Data(legacy.utf8))
        let old = try #require(history.performance(for: id))
        #expect(old.attempts == 12)
        #expect(old.averageSeconds == 2)
        #expect(old.recentHintRate == Double(8) / Double(12))
        #expect(old.recentRecallRate == 0)
        #expect(!old.isRecalled && !old.isRetained)
        #expect(old.nextReviewDay == nil)
        #expect(history.dueCount(mode: .english, day: 100) == 1)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 100)
        let migrated = try #require(history.performance(for: id))
        #expect(migrated.nextReviewDay == 101)
        #expect(migrated.spacedRecallDays == 1)
        #expect(try JSONDecoder().decode(PracticeHistory.self, from: JSONEncoder().encode(history))
            .performance(for: id) == migrated)
    }

    @Test("Only spaced unaided recalls extend the conservative schedule")
    func spacedRecall() throws {
        let (_, id) = try chord("cat")
        var history = PracticeHistory()
        for _ in 0..<12 { history.record(id, correct: true, seconds: 1, hinted: false, day: 100) }
        var result = try #require(history.performance(for: id))
        #expect(result.isRecalled && !result.isRetained)
        #expect(result.spacedRecallDays == 1)
        #expect(result.nextReviewDay == 101)
        #expect(history.dueCount(mode: .english, day: 100) == 0)
        #expect(history.dueCount(mode: .english, day: 101) == 1)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 101)
        #expect(history.performance(for: id)?.nextReviewDay == 104)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 102)
        #expect(history.performance(for: id)?.nextReviewDay == 104)
        #expect(history.performance(for: id)?.spacedRecallDays == 2)
        #expect(history.performance(for: id)?.isRetained == false)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 104)
        result = try #require(history.performance(for: id))
        #expect(result.isRetained)
        #expect(result.nextReviewDay == 111)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 111)
        #expect(history.performance(for: id)?.nextReviewDay == 125)
        history.record(id, correct: true, seconds: 1, hinted: false, day: 125)
        #expect(history.performance(for: id)?.nextReviewDay == 155)
        // An incorrect local clock cannot turn a previous date into another spaced check.
        history.record(id, correct: true, seconds: 1, hinted: false, day: 80)
        #expect(history.performance(for: id)?.lastPracticedDay == 125)
        #expect(history.performance(for: id)?.nextReviewDay == 155)
    }

    @Test("Hints and failures require new recall evidence; recent assistance can recover")
    func assistedRecall() throws {
        let (_, id) = try chord("cat")
        var history = PracticeHistory()
        for _ in 0..<6 { history.record(id, correct: true, seconds: 1, hinted: true, day: 100) }
        var result = try #require(history.performance(for: id))
        #expect(result.recentHintRate == 1)
        #expect(result.recentRecallRate == 0)
        #expect(!result.isRecalled && !result.isRetained)
        #expect(result.nextReviewDay == 100)
        for day in [100, 101, 104] { history.record(id, correct: true, seconds: 1, hinted: false, day: day) }
        #expect(history.performance(for: id)?.isRetained == true)
        history.record(id, correct: true, seconds: 1, hinted: true, day: 105)
        result = try #require(history.performance(for: id))
        #expect(!result.isRecalled && !result.isRetained)
        #expect(result.spacedRecallDays == 0)
        #expect(result.nextReviewDay == 105)
        for _ in 0..<12 { history.record(id, correct: true, seconds: 1, hinted: false, day: 105) }
        result = try #require(history.performance(for: id))
        #expect(result.recentHintRate < 0.03)
        #expect(result.recentRecallRate > 0.97)
        #expect(result.isRecalled && !result.isRetained)
        #expect(result.nextReviewDay == 106)
        history.record(id, correct: false, seconds: 1, hinted: false, day: 106)
        #expect(history.performance(for: id)?.nextReviewDay == 106)
        #expect(history.performance(for: id)?.spacedRecallDays == 0)
        #expect(history.performance(for: id)?.isRecalled == false)
        // Undated legacy-compatible calls cannot fabricate delayed retention either.
        for _ in 0..<6 { history.record(id, correct: true, seconds: 1, hinted: false) }
        #expect(history.performance(for: id)?.isRecalled == true)
        #expect(history.performance(for: id)?.isRetained == false)
    }

    @Test("Due work precedes weak upcoming work and respects mode")
    func dueReviewOrdering() throws {
        let (_, due) = try chord("cat"), (_, upcoming) = try chord("dog")
        var history = PracticeHistory()
        history.record(due, correct: true, seconds: 0.5, hinted: false, day: 100)
        history.record(upcoming, correct: false, seconds: 15, hinted: true, day: 101)
        history.record(upcoming, correct: true, seconds: 15, hinted: false, day: 101)
        #expect(history.weakest(mode: .english).first?.chord == upcoming)
        #expect(history.recordsForReview(mode: .english, day: 101).first?.chord == due)
        #expect(history.dueCount(mode: .english, day: 101) == 1)
        #expect(history.dueCount(mode: .cpp, day: 101) == 0)
        let review = try #require(PracticeReview.make(history: history, data: defaults, mode: .english,
                                                     limit: 1, day: 101))
        #expect(review.targets == [due])
        #expect(try replay(review.guide) == review.text)
        // No due work still permits the explicit personal-review action to practice weak items.
        #expect(PracticeReview.make(history: history, data: defaults, mode: .english, limit: 1, day: 100) != nil)
    }

    @Test("Review does not turn editable mapping outputs into ordinary vocabulary")
    func arbitraryOutputIsNotVocabulary() throws {
        var data = defaults
        data.english.entries[keys("F")] = .text(TextEntry(text: "zxqv"))
        let id = PracticeChord(keys: keys("F"), shift: false, data: data, mode: .english)
        var history = PracticeHistory()
        history.record(id, correct: false, seconds: 1, hinted: false, day: 100)
        #expect(PracticeReview.make(history: history, data: data, mode: .english) == nil)
    }

    @Test("Joined and suffix-base fragments appear only inside curated whole words", arguments: ["looked", "needed", "wanted", "possible", "making"])
    func wholeWordReview(text: String) throws {
        let plan = TypingPlanner(data: defaults, mode: .english).plan(text)
        var history = PracticeHistory()
        for step in plan.steps {
            if let target = PracticeChord(step: step, data: defaults, mode: .english) {
                history.record(target, correct: false, seconds: 1, hinted: false)
            }
        }
        let drill = try #require(PracticeReview.make(history: history, data: defaults, mode: .english))
        #expect(drill.guide.steps.allSatisfy(Course.isAllowed))
        let words = drill.text.split(whereSeparator: \.isWhitespace)
        #expect(!words.contains("looke"))
        #expect(!words.contains("neede"))
        #expect(try replay(drill.guide) == drill.text)
        // Rotating contexts must not silently lose any requested target in the final plan.
        for target in drill.targets {
            #expect(drill.guide.steps.filter { PracticeChord(step: $0, data: defaults, mode: .english) == target }.count >= 3)
        }
    }


    @Test("Optional learned skills keep review within a beginner's taught mappings")
    func learnedReview() throws {
        let (_, id) = try chord("sat")
        var history = PracticeHistory()
        history.record(id, correct: false, seconds: 1, hinted: false, day: 100)
        let learned = Course.taught(through: 0, data: defaults)
        let drill = try #require(PracticeReview.make(history: history, data: defaults, mode: .english,
                                                     day: 100, learnedSkills: learned))
        #expect(drill.targets == [id])
        #expect(drill.guide.steps.allSatisfy {
            Course.skills(of: $0, data: defaults, mode: .english).isSubset(of: learned)
        })
        #expect(try replay(drill.guide) == drill.text)
        #expect(PracticeReview.make(history: history, data: defaults, mode: .english,
                                   learnedSkills: []) == nil)
    }

}
