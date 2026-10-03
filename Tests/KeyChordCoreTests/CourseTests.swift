import Foundation
import Testing
@testable import KeyChordCore

@Suite("Course")
struct CourseTests {
    static let keyboards: [(name: String, usable: (KeySet) -> Bool)] = [
        ("any keyboard", { _ in true }),
        ("MacBook Pro 2021", macBookLimits.usable(in: defaults.layout)),
        ("MacBook Pro 2021 US", macBookUSLimits.usable(in: defaults.layout)),
    ]

    /// What is wrong with step `i` on each keyboard (Normal mode, something not taught yet, a plan that types
    /// something else), and the skills its text uses.
    static func check(_ i: Int) throws -> (problems: [String], used: Set<Course.Skill>) {
        let step = Course.steps[i]
        let taught = Course.taught(through: i, data: defaults)
        let chars = Array(step.text)
        var problems: [String] = []
        var used = Set<Course.Skill>()
        for (name, usable) in keyboards {
            let g = TypingPlanner(data: defaults, mode: step.mode, usable: usable).plan(step.text)
            if try replay(g) != normalizedNewlines(step.text) { problems.append("\(name): the plan types something else") }
            for s in g.steps {
                let lo = max(0, min(s.source.lowerBound, chars.count)), hi = max(lo, min(s.source.upperBound, chars.count))
                let word = String(chars[lo..<hi])
                guard Course.isAllowed(s) else {
                    problems.append("\(name): “\(word)” needs \(s.action)")
                    continue
                }
                let skills = Course.skills(of: s, data: defaults, mode: step.mode)
                used.formUnion(skills)
                let missing = skills.subtracting(taught).map { "\($0)" }.sorted()
                if !missing.isEmpty {
                    problems.append("\(name): “\(word)” uses \(missing.joined(separator: ", ")) in \(s.action)")
                }
            }
        }
        return (problems, used)
    }

    @Test("Every step is typed with chords only and needs nothing the course hasn't taught yet",
          arguments: Array(Course.steps.indices))
    func cumulative(index: Int) throws {
        let p = try Self.check(index)
        #expect(p.problems.isEmpty, "\(Course.steps[index].id):\n\(p.problems.joined(separator: "\n"))")
    }

    @Test("Every step practices what it introduces", arguments: Array(Course.steps.indices))
    func practicesWhatItIntroduces(index: Int) throws {
        let step = Course.steps[index]
        let used = try Self.check(index).used
        for skill in step.new where !Course.explainedOnly.contains(skill) {
            let practiced: Bool
            if case .pairs(let bank) = skill {
                let pairs = Set(Course.pairClusters(bank, data: defaults).map { Course.Skill.sound(bank, $0.text) })
                practiced = !used.isDisjoint(with: pairs)
            } else {
                practiced = used.contains(skill)
            }
            #expect(practiced, "\(step.id) never uses \(skill)")
        }
    }

    @Test("Every new item has keys on the default layout; ids are unique; nothing is introduced twice")
    func structure() {
        #expect(Set(Course.steps.map(\.id)).count == Course.steps.count)
        var seen: [SubMode: Set<Course.Skill>] = [:]
        for step in Course.steps {
            #expect(!step.text.isEmpty && !step.intro.isEmpty, "\(step.id)")
            for skill in step.new {
                #expect(!Course.chords(for: skill, data: defaults, mode: step.mode).isEmpty, "\(step.id): \(skill)")
                #expect(seen[step.mode, default: []].insert(skill).inserted, "\(step.id) introduces \(skill) again")
            }
        }
    }

    @Test("Pairs of known sounds count as taught; sounds with keys of their own don't")
    func pairsAreDerived() throws {
        let before = Course.taught(through: try #require(Course.index(of: "start-pairs")) - 1, data: defaults)
        let after = Course.taught(through: try #require(Course.index(of: "start-pairs")), data: defaults)
        #expect(!before.contains(.sound(.onset, "th")))
        #expect(after.contains(.sound(.onset, "th")) && after.contains(.sound(.onset, "st")))
        #expect(!after.contains(.sound(.onset, "ch")) && !after.contains(.sound(.onset, "m")))
        // English punctuation is not taught for C++.
        let cpp = try #require(Course.steps.firstIndex { $0.mode == .cpp })
        #expect(!Course.taught(through: cpp, data: defaults).contains(.symbol(";")))
        #expect(Course.taught(through: cpp, data: defaults).contains(.sound(.onset, "th")))
    }

    @Test func chordsForSkills() {
        func show(_ s: Course.Skill, _ mode: SubMode = .english) -> [String] {
            Course.chords(for: s, data: defaults, mode: mode).map {
                $0.label + "=" + defaults.layout.chordString($0.keys) + ($0.note.map { " (\($0))" } ?? "")
            }
        }
        #expect(show(.sound(.onset, "m")) == ["m=F+G"])
        #expect(show(.ending("ing")) == ["-ing=K+L"])
        #expect(show(.symbol(".")) == [".=Period"])
        #expect(show(.abbreviation(".")) == [".=Quote+Period (no capital after it)"])
        #expect(show(.symbol("\"")) == ["\"=LBracket+Quote (opening)", "\"=RBracket+Quote (closing)"])
        #expect(show(.command(.capitalizeNext)) == ["capital on the next word=N+M"])
        #expect(show(.symbol(";"), .cpp) == [";=Semicolon"])
        #expect(show(.pairs(.onset)).contains("th=E+T"))
    }

    /// Prints, for each English step, dictionary words typed with only what the course has taught by then and
    /// using something new: KEYCHORD_COURSE_WORDS=1. Reads /usr/share/dict/words.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYCHORD_COURSE_WORDS"] != nil))
    func candidateWords() throws {
        let dict = Set(try String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { $0.allSatisfy(\.isLowercase) })
        for (i, step) in Course.steps.enumerated() where step.mode == .english {
            let taught = Course.taught(through: i, data: defaults)
            let fresh = taught.subtracting(i > 0 ? Course.taught(through: i - 1, data: defaults) : [])
            func sounds(_ b: Bank) -> [String] {
                [""] + taught.compactMap { if case .sound(b, let t) = $0 { return t } else { return nil } }
            }
            var words = Set<String>()
            for o in sounds(.onset) {
                for v in sounds(.vowel) {
                    for c in sounds(.coda) where dict.contains(o + v + c) && (o + v + c).count >= 2 { words.insert(o + v + c) }
                }
            }
            var ok: [String] = []
            for w in words.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
                var good = true, usesNew = false
                for (_, usable) in Self.keyboards {
                    for s in TypingPlanner(data: defaults, mode: .english, usable: usable).plan(w).steps {
                        let sk = Course.skills(of: s, data: defaults, mode: .english)
                        if !Course.isAllowed(s) || !sk.isSubset(of: taught) { good = false }
                        if !sk.isDisjoint(with: fresh) { usesNew = true }
                    }
                }
                if good && usesNew { ok.append(w) }
            }
            print("[\(i)] \(step.id) (\(ok.count)): \(ok.joined(separator: " "))")
        }
    }
}
