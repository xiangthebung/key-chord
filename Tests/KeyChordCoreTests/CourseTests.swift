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
            if try replayPractice(g, text: step.text) != normalizedNewlines(step.text) { problems.append("\(name): the plan types something else") }
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

    @Test("Introductions use small sets and pair examples only combine learned components")
    func stagedIntroductions() throws {
        for (index, step) in Course.steps.enumerated() {
            #expect(step.new.count <= 4, "\(step.id) introduces too many skills")
            let known = Course.taught(through: index, data: defaults)
            for skill in step.new {
                let chords = Course.introductionChords(for: skill, at: index, data: defaults)
                #expect(!chords.isEmpty)
                if case .pairs(let bank) = skill {
                    #expect(chords.count <= 3)
                    for chord in chords {
                        let pair = try #require(Course.pairClusters(bank, data: defaults).first { $0.keys == chord.keys })
                        #expect(pair.singles.allSatisfy { known.contains(.sound(bank, $0)) })
                    }
                }
            }
        }
        let index = try #require(Course.index(of: "start-pairs"))
        #expect(Course.introductionChords(for: .pairs(.onset), at: index, data: defaults).map(\.label) == ["th", "sh", "st"])
        #expect(Course.chords(for: .pairs(.onset), data: defaults, mode: .english).count > 3)
    }

    @Test("Legacy completion covers the smaller replacement lessons only during version migration")
    func progressMigration() throws {
        let currentIDs = Set(Course.steps.map(\.id))
        for (original, additions) in Course.legacyLessonExpansions {
            #expect(currentIDs.contains(original))
            #expect(additions.isSubset(of: currentIDs))
            let migrated = Course.migratedCompletedIDs([original, "unknown-old-id"], fromVersion: 1)
            #expect(migrated == additions.union([original, "unknown-old-id"]))
            #expect(Course.migratedCompletedIDs(migrated, fromVersion: Course.curriculumVersion) == migrated)
            #expect(Course.migratedCompletedIDs([original], fromVersion: Course.curriculumVersion) == [original])
        }
        #expect(Course.migratedCompletedIDs([], fromVersion: 1).isEmpty)
        // Newly completed first-chord must not silently teach the later end n.
        let first = Course.learnedSkills(completedIDs: ["first-chord"], data: defaults)
        #expect(!first.contains(.sound(.coda, "n")))
        let legacyFirst = Course.learnedSkills(completedIDs: Course.migratedCompletedIDs(["first-chord"], fromVersion: 1), data: defaults)
        #expect(legacyFirst.contains(.sound(.coda, "n")))
        #expect(legacyFirst.contains(.sound(.onset, "t")))
    }

    @Test("All 34 legacy lessons retain their identifiers and original introduced skills after migration")
    func legacySkillPreservation() throws {
        func sounds(_ bank: Bank, _ texts: [String]) -> Set<Course.Skill> { Set(texts.map { .sound(bank, $0) }) }
        func words(_ texts: [String]) -> Set<Course.Skill> { Set(texts.map { .word($0) }) }
        let original: [String: Set<Course.Skill>] = [
            "first-chord": sounds(.onset, ["s", "h", "t"]).union(sounds(.vowel, ["a"])).union(sounds(.coda, ["t", "n"])),
            "vowels": sounds(.vowel, ["o", "e", "i", "u"]).union(words(["I"])),
            "home-row": sounds(.onset, ["r", "f", "d", "l", "g"]).union(sounds(.coda, ["d", "s"])).union([.command(.undo)]),
            "start-pairs": [.pairs(.onset)],
            "top-row-ends": sounds(.coda, ["y", "r", "m", "p"]),
            "last-keys": sounds(.onset, ["w", "b", "z"]).union(sounds(.coda, ["e"])),
            "syllables-review": [],
            "two-key-starts": sounds(.onset, ["m", "n", "p", "c", "k"]),
            "more-two-key-starts": sounds(.onset, ["y", "j", "v", "ch"]),
            "end-pairs": [.pairs(.coda)],
            "two-key-ends": sounds(.coda, ["g", "b", "f", "w", "x"]),
            "end-sounds": sounds(.coda, ["ng", "ck", "ll", "sh", "ch", "th", "ss", "ft", "ct", "k", "l"]),
            "blends": sounds(.onset, ["cl", "cr", "pl", "pr", "sk", "sm", "sn", "sp", "kn", "qu"]),
            "vowel-pairs": sounds(.vowel, ["ea", "ee", "oo", "ou", "ai"]),
            "silent-e-ends": sounds(.coda, ["ve", "ce", "ge"]),
            "two-key-review": [],
            "s-ed": [.ending("s"), .ending("ed")],
            "ing-er": Set(["ing", "er", "est", "ly"].map { .ending($0) }),
            "more-endings": Set(["ness", "ment", "able", "ful"].map { .ending($0) }),
            "full-stop": [.symbol("."), .symbol(",")],
            "capitals": [.command(.capitalizeNext)],
            "questions": [.symbol("?"), .symbol("!")],
            "more-punctuation": Set([":", ";", "'", "-"].map { .symbol($0) }),
            "quotes": [.symbol("\""), .symbol("("), .symbol(")")],
            "word-chords": words(["their", "about", "people", "into", "other", "only", "over", "also", "after", "first"]),
            "more-word-chords": words(["because", "through", "before", "between", "never", "every", "little", "different", "important", "something"]),
            "join": [.join],
            "shift-join": [.shiftJoin],
            "spelling": [.spell, .capitalLetter],
            "numbers": [.digits, .space],
            "cpp-mode": words(["int", "return", "const", "auto", "void", "bool"]).union([.command(.modeSwitch)]),
            "cpp-symbols": Set(["=", "==", "+", "-", ";", "(", ")", "{", "}"].map { .symbol($0) }),
            "cpp-names": [.command(.casing(.snake)), .command(.casing(.screamingSnake)), .command(.endIdentifier)],
            "cpp-program": [.newLine],
        ]
        #expect(original.count == 34)
        #expect(Course.steps.count == 52)
        #expect(Set(Course.legacyLessonExpansions.keys).isSubset(of: Set(original.keys)))
        for (id, expected) in original {
            #expect(Course.index(of: id) != nil, "Original identifier \(id) must remain available")
            let migrated = Course.migratedCompletedIDs([id], fromVersion: 1)
            let actual = Set(Course.steps.filter { migrated.contains($0.id) }.flatMap(\.new))
            #expect(actual == expected, "\(id): replacement lessons changed the original skill set")
        }
        let allMigrated = Course.migratedCompletedIDs(Set(original.keys), fromVersion: 1)
        #expect(allMigrated == Set(Course.steps.map(\.id)))
    }

    @Test("Sparse completion derives pairs only when both components were learned")
    func sparseLearnedSkills() {
        let sparse = Course.learnedSkills(completedIDs: ["first-chord", "start-pairs", "cpp-mode"], data: defaults)
        #expect(sparse.contains(.sound(.onset, "sh")))
        #expect(!sparse.contains(.sound(.onset, "th")))
        #expect(!sparse.contains(.word("int")))
        #expect(!sparse.contains(.word("their")))
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
