import Testing
@testable import KeyChordCore

@Suite("Listen and type")
struct ListeningPracticeTests {
    @Test("Spoken words replay exactly with each supported keyboard")
    func playableWords() throws {
        for usable in [{ (_: KeySet) in true }, macBookLimits.usable(in: defaults.layout),
                       macBookUSLimits.usable(in: defaults.layout)] {
            let session = ListeningPractice(data: defaults, usable: usable)
            var random = ListeningTestRandom()
            var seen = Set<String>()
            var previous: String?
            var hasMultipleChords = false
            // Several complete vocabulary cycles: the session never runs out of prompts.
            for _ in 0..<500 {
                let prompt = try #require(session.next(using: &random))
                #expect(prompt.text != previous)
                #expect(prompt.text.allSatisfy { $0.isLetter && $0.isLowercase })
                #expect(prompt.guide.mode == .english)
                #expect(prompt.guide.steps.allSatisfy(Course.isAllowed))
                #expect(try replayPractice(prompt.guide, text: prompt.text) == prompt.text)
                hasMultipleChords = hasMultipleChords || prompt.guide.steps.count > 1
                seen.insert(prompt.text)
                previous = prompt.text
            }
            #expect(seen.count >= 100)
            #expect(hasMultipleChords)
        }
    }

    @Test("Partial and incorrect answers keep the same word; a correct answer counts once")
    func answersAndHints() throws {
        let session = ListeningPractice(data: defaults)
        var random = ListeningTestRandom()
        let first = try #require(session.next(using: &random))
        #expect(!session.check(String(first.text.dropLast())))
        #expect(!session.check(first.text + "x"))
        #expect(!session.check(first.text + " "))
        #expect(session.prompt?.text == first.text)
        #expect(session.completedWords == 0)
        #expect(session.revealHint())
        #expect(session.check(first.text))
        #expect(!session.check(first.text))
        #expect(session.completedWords == 1)
        #expect(session.assistedWords == 1)
        let second = try #require(session.next(using: &random))
        #expect(second.text != first.text)
        #expect(!session.hintRevealed)
        #expect(session.check(second.text))
        #expect(session.completedWords == 2)
        #expect(session.assistedWords == 1)
    }

    @Test("Unavailable keyboard chords never produce an untypeable prompt")
    func unavailable() {
        let session = ListeningPractice(data: defaults, usable: { _ in false })
        var random = ListeningTestRandom()
        #expect(!session.isAvailable)
        #expect(session.next(using: &random) == nil)
        #expect(!session.check("cat"))
        #expect(!session.revealHint())
    }

    @Test("Early learned sets can listen, using only the actual completed lessons", arguments: Array(Course.steps.indices))
    func learnedWords(index: Int) throws {
        guard Course.steps[index].mode == .english else { return }
        let learned = Course.taught(through: index, data: defaults)
        for usable in [{ (_: KeySet) in true }, macBookLimits.usable(in: defaults.layout),
                       macBookUSLimits.usable(in: defaults.layout)] {
            let session = ListeningPractice(data: defaults, usable: usable, learnedSkills: learned, sessionLength: 10)
            #expect(session.isAvailable)
            var random = ListeningTestRandom()
            var previous: String?
            for _ in 0..<10 {
                let prompt = try #require(session.next(using: &random))
                #expect(prompt.text != previous)
                let used = Set(prompt.guide.steps.flatMap { Course.skills(of: $0, data: defaults, mode: .english) })
                #expect(used.isSubset(of: learned))
                #expect(try replayPractice(prompt.guide, text: prompt.text) == prompt.text)
                #expect(session.check(prompt.text))
                previous = prompt.text
            }
            #expect(session.isSessionComplete)
        }
    }

    @Test("Finite sessions wait for the learner and terminate after the goal")
    func finiteSession() throws {
        let session = ListeningPractice(data: defaults, sessionLength: 2)
        var random = ListeningTestRandom()
        let first = try #require(session.next(using: &random))
        #expect(!session.canAdvance && !session.isSessionComplete)
        #expect(session.next(using: &random)?.text == first.text)
        #expect(!session.check(first.text + "x"))
        #expect(session.completedWords == 0)
        #expect(session.check(first.text))
        #expect(session.canAdvance && !session.isSessionComplete)
        let second = try #require(session.next(using: &random))
        #expect(second.text != first.text)
        #expect(!session.canAdvance)
        #expect(session.revealHint())
        #expect(session.check(second.text))
        #expect(session.isComplete && session.isSessionComplete)
        #expect(!session.canAdvance)
        #expect(session.next(using: &random) == nil)
        #expect(session.prompt?.text == second.text)
        #expect(!session.check(second.text))
        #expect(!session.revealHint())
        #expect(session.completedWords == 2 && session.assistedWords == 1)
    }

    @Test("Empty learned sets yield no prompts; nil preserves unrestricted vocabulary")
    func emptyAndUnrestricted() throws {
        var random = ListeningTestRandom()
        let empty = ListeningPractice(data: defaults, learnedSkills: [])
        #expect(!empty.isAvailable)
        #expect(empty.next(using: &random) == nil)
        let unlimited = ListeningPractice(data: defaults)
        #expect(unlimited.sessionLength == nil)
        let first = try #require(unlimited.next(using: &random))
        #expect(unlimited.next(using: &random)?.text != first.text)
        #expect(!unlimited.isSessionComplete)
        let zero = ListeningPractice(data: defaults, sessionLength: 0)
        #expect(zero.isSessionComplete)
        #expect(zero.next(using: &random) == nil)
    }

    @Test("An early completed lesson excludes later vocabulary across a full finite session")
    func sparseLearnedVocabulary() throws {
        let learned = Course.learnedSkills(completedIDs: ["first-chord", "cpp-mode", "unknown-id"], data: defaults)
        let expected: Set<Course.Skill> = [.sound(.onset, "s"), .sound(.onset, "h"),
                                          .sound(.vowel, "a"), .sound(.coda, "t"), .command(.modeSwitch)]
        #expect(learned == expected)
        for usable in [{ (_: KeySet) in true }, macBookLimits.usable(in: defaults.layout),
                       macBookUSLimits.usable(in: defaults.layout)] {
            let session = ListeningPractice(data: defaults, usable: usable, learnedSkills: learned, sessionLength: 12)
            var random = ListeningTestRandom()
            var seen = Set<String>()
            for _ in 0..<12 {
                let prompt = try #require(session.next(using: &random))
                #expect(["at", "hat", "sat"].contains(prompt.text))
                #expect(prompt.guide.steps.allSatisfy(Course.isAllowed))
                #expect(try replayPractice(prompt.guide, text: prompt.text) == prompt.text)
                #expect(session.check(prompt.text))
                seen.insert(prompt.text)
            }
            #expect(seen == ["at", "hat", "sat"])
            #expect(session.isSessionComplete && !session.canAdvance)
            #expect(session.next(using: &random) == nil)
            #expect(session.completedWords == 12 && session.assistedWords == 0)
        }
    }

    @Test("A single available word repeats safely and cannot count twice at a session endpoint")
    func singleWordSession() throws {
        let session = ListeningPractice(data: defaults, learnedSkills: [.sound(.vowel, "a"), .sound(.coda, "t")],
                                        sessionLength: 2)
        var random = ListeningTestRandom()
        #expect(!session.canAdvance)
        #expect(try #require(session.next(using: &random)).text == "at")
        #expect(session.revealHint())
        #expect(session.next(using: &random)?.text == "at")
        #expect(session.hintRevealed)
        #expect(session.check("at"))
        #expect(!session.check("at"))
        #expect(session.completedWords == 1 && session.assistedWords == 1)
        #expect(session.canAdvance)
        #expect(try #require(session.next(using: &random)).text == "at")
        #expect(!session.hintRevealed && !session.isComplete)
        #expect(session.check("at"))
        #expect(session.isSessionComplete && !session.canAdvance)
        #expect(session.next(using: &random) == nil)
        #expect(!session.check("at") && !session.revealHint())
        #expect(session.completedWords == 2 && session.assistedWords == 1)
        let negative = ListeningPractice(data: defaults, sessionLength: -1)
        #expect(negative.sessionLength == 0 && negative.isSessionComplete)
        #expect(negative.next(using: &random) == nil)
    }
}

private struct ListeningTestRandom: RandomNumberGenerator {
    var state: UInt64 = 21
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
