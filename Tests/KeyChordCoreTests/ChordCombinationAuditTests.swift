import Testing
@testable import KeyChordCore

@Suite("All mapped chord combinations")
struct ChordCombinationAuditTests {
    /// Every supported composition, spelling, number, dictionary, and Space-joined chord within
    /// the six-key limit. Other key subsets have no mapping and cannot appear in a typing guide.
    static let combinations: [KeySet] = {
        let layout = defaults.layout
        var combinations = Set(DictionaryLoader.allChords(defaults).map { $0.1 })
        func clusters(_ bank: Bank) -> [KeySet] {
            [KeySet()] + Array((layout.clusters[bank] ?? [:]).keys)
        }
        for onset in clusters(.onset) {
            for vowel in clusters(.vowel) {
                for coda in clusters(.coda) {
                    let chord = onset.union(vowel).union(coda)
                    if !chord.isEmpty && chord.count <= 6 { combinations.insert(chord) }
                }
            }
        }
        if let spell = layout.spellIndex {
            for letters in layout.fingerspelling.keys { combinations.insert(letters.union(KeySet([spell]))) }
        }
        let digits = layout.numberMask.indices
        for bits in 1..<(1 << digits.count) {
            let chord = KeySet(digits.indices.filter { bits & (1 << $0) != 0 }.map { digits[$0] })
            if chord.count <= 6 { combinations.insert(chord) }
        }
        if let space = layout.spaceIndex {
            let joined = combinations.map { $0.union(KeySet([space])) }.filter { $0.count <= 6 }
            combinations.formUnion(joined)
            combinations.insert(KeySet([space]))
        }
        return combinations.sorted { ($0.count, $0.bits) < ($1.count, $1.bits) }
    }()

    @Test("Every mapped chord's shown meaning agrees with its actual output, with and without Shift",
          arguments: SubMode.allCases)
    func meanings(mode: SubMode) throws {
        let layout = defaults.layout
        for chord in Self.combinations {
            for shift in [false, true] {
                let reading = ChordReading(chord, shift: shift, data: defaults, mode: mode)
                let result = try ChordEngine(data: defaults, subMode: mode).translate(chord, join: shift)
                let label = layout.chordString(chord) + (shift ? " + Shift" : "")
                #expect(Set(reading.parts.flatMap(\.keys)) == Set(layout.names(chord)), "\(mode): \(label)")
                switch reading.outcome {
                case .nothing:
                    #expect(result.signal == .untranslatable, "\(mode): \(label)")
                case .command:
                    #expect(result.actions.isEmpty, "\(mode): \(label)")
                case .text(let shown):
                    #expect(result.signal == nil, "\(mode): \(label)")
                    var lookup = chord
                    if let space = layout.spaceIndex, chord.count > 1 { lookup.remove(space) }
                    let expected: String
                    if case .text(let entry)? = defaults.dictionary(for: mode)[lookup] ?? defaults.shared[lookup] {
                        expected = entry.text // Suffixes and snippet markers have special display labels.
                    } else { expected = shown }
                    let inserted = result.actions.compactMap { action -> String? in
                        if case .insert(let text) = action { return text }
                        return nil
                    }.joined()
                    #expect(inserted == expected, "\(mode): \(label) shows \(shown), types \(inserted)")
                }
            }
        }
        print("Audited \(Self.combinations.count) mapped combinations in \(mode.rawValue), twice for Shift.")
    }

    @Test("Every suffix on bundled word bases preserves practice progress on all supported keyboards",
          arguments: Array(CourseTests.keyboards.indices))
    func suffixProgress(keyboard: Int) throws {
        var bases = Set<String>()
        for entry in defaults.english.entries.values {
            if case .text(let word) = entry, word.kind == .word, word.text.allSatisfy(\.isLetter) {
                bases.insert(word.text.lowercased())
            }
        }
        for text in Course.steps.filter({ $0.mode == .english }).map(\.text)
            + Lessons.all.filter({ $0.mode == .english }).map(\.text) {
            bases.formUnion(text.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() })
        }
        for key in defaults.orthographyExceptions.keys { bases.insert(String(key.split(separator: "+")[0])) }
        let suffixes = Set(defaults.english.entries.values.compactMap { entry -> String? in
            if case .text(let text) = entry, text.kind == .suffix { return text.text }
            return nil
        })
        let forms = Set(bases.flatMap { word in
            suffixes.map { Orthography.attach(word: word, suffix: $0, exceptions: defaults.orthographyExceptions) }
        })
        let planner = TypingPlanner(data: defaults, mode: .english, usable: CourseTests.keyboards[keyboard].usable)
        // This checks progress and emitted text; artificial combinations are not an English vocabulary test.
        for word in forms.sorted() {
            let text = "the \(word) tea"
            try replayPractice(planner.plan(text), text: text)
        }
        print("Audited \(forms.count) suffix forms on \(CourseTests.keyboards[keyboard].name).")
    }
}
