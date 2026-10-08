import Testing
@testable import KeyChordCore

@Suite("Generated practice")
struct PracticeGeneratorTests {
    @Test("Fresh course exercises preserve taught skills and replay exactly", arguments: Array(Course.steps.indices))
    func course(index: Int) throws {
        let step = Course.steps[index]
        for usable in [{ (_: KeySet) in true }, macBookLimits.usable(in: defaults.layout),
                       macBookUSLimits.usable(in: defaults.layout)] {
            let generator = try #require(PracticeGenerator(source: .course(index), data: defaults, usable: usable))
            var previous: String?
            for seed: UInt64 in [1, 19, 2026] {
                let drill = try #require(generator.next(seed: seed, avoiding: previous), "\(step.id)")
                #expect(drill.text != previous)
                #expect(try replayPractice(drill.guide, text: drill.text) == drill.text)
                let taught = Course.taught(through: index, data: defaults)
                let used = Set(drill.guide.steps.flatMap { Course.skills(of: $0, data: defaults, mode: step.mode) })
                #expect(used.isSubset(of: taught), "\(step.id): \(used.subtracting(taught))")
                #expect(drill.guide.steps.allSatisfy(Course.isAllowed))
                for skill in step.new where !Course.explainedOnly.contains(skill) {
                    if case .pairs(let bank) = skill {
                        let pairs = Set(Course.pairClusters(bank, data: defaults).map { Course.Skill.sound(bank, $0.text) })
                        #expect(!used.isDisjoint(with: pairs))
                    } else if skill == .shiftJoin {
                        #expect(used.contains(.shiftJoin) || used.contains(.join))
                    } else {
                        #expect(used.contains(skill), "\(step.id) must practice \(skill)")
                    }
                }
                previous = drill.text
            }
        }
    }

    @Test("Topic practice varies beyond a fixed list and respects keyboard limits", arguments: Array(Lessons.all.indices))
    func topics(index: Int) throws {
        let generator = try #require(PracticeGenerator(source: .topic(index), data: defaults,
                                                       usable: macBookUSLimits.usable(in: defaults.layout)))
        var passages = Set<String>()
        var previous: String?
        for seed in 0..<16 {
            let drill = try #require(generator.next(seed: UInt64(seed), avoiding: previous))
            #expect(drill.text != previous)
            #expect(try replayPractice(drill.guide, text: drill.text) == drill.text)
            #expect(drill.guide.steps.allSatisfy(Course.isAllowed))
            passages.insert(drill.text)
            previous = drill.text
        }
        #expect(passages.count >= 8)
    }

    @Test func deterministicAndInvalidSources() throws {
        let generator = try #require(PracticeGenerator(source: .topic(0), data: defaults))
        #expect(generator.next(seed: 123)?.text == generator.next(seed: 123)?.text)
        #expect(PracticeGenerator(source: .course(-1), data: defaults) == nil)
        #expect(PracticeGenerator(source: .topic(99), data: defaults) == nil)
        let blocked = try #require(PracticeGenerator(source: .topic(0), data: defaults, usable: { _ in false }))
        #expect(blocked.next(seed: 1) == nil)
    }

    @Test("Early word drills avoid adjacent repeated words when the pool has alternatives")
    func nearbyRepeats() throws {
        let index = try #require(Course.index(of: "first-chord"))
        let generator = try #require(PracticeGenerator(source: .course(index), data: defaults))
        for seed: UInt64 in 0..<64 {
            let drill = try #require(generator.next(seed: seed))
            let words = drill.text.split(separator: " ")
            #expect(words.count >= 8 && words.count <= 12)
            #expect(zip(words, words.dropFirst()).allSatisfy { $0 != $1 })
            #expect(Set(words).isSubset(of: ["a", "at", "hat", "sat"]))
        }
    }

    @Test("Word drill vocabulary keeps spellings intact when removing surrounding punctuation")
    func punctuatedWordCandidates() {
        #expect(PracticeGenerator.drillWord(in: "\"cat,\"") == "cat")
        #expect(PracticeGenerator.drillWord(in: "(return);") == "return")
        #expect(PracticeGenerator.drillWord(in: "max_size;") == "max_size")
        for token: Substring in ["well-made", "cat's", "dog’s", "10:30", "\"well-made,\"", "..."] {
            #expect(PracticeGenerator.drillWord(in: token) == nil, "Must not invent a word from \(token)")
        }
    }
}
