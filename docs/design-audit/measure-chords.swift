// Reproduce: swiftc -O Sources/KeyChordCore/*.swift docs/design-audit/measure-chords.swift -o /tmp/keychord-design-audit
// Run from the repository root: /tmp/keychord-design-audit > docs/design-audit/chord-measurements-current.json
// chord-measurements.json preserves the original audit baseline before the follow-up changes.
// Design measurements only. Does not read or change user dictionaries or performance data.
import Foundation

@main
struct DesignAudit {
    static func main() throws {
        var sources: [DataFile: String?] = [:]
        for file in DataFile.allCases { sources[file] = file.defaultSource }
        let outcome = DictionaryLoader.load(sources: sources, rolloverLimit: 6)
        precondition(outcome.problems.isEmpty)
        let data = outcome.data, layout = data.layout
        let iso = try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: layout)
        let ansi = try KeyboardWiring.parse(DefaultData.wiringMacBookPro18ANSI, layout: layout)
        func blocked(_ keys: KeySet, _ wiring: KeyboardWiring) -> Bool {
            wiring.blocks(keys.indices.map { layout.keys[$0].code })
        }
        func options(_ bank: Bank) -> [(KeySet, String)] {
            [(KeySet(), "")] + (layout.clusters[bank] ?? [:]).map { ($0.key, $0.value) }
        }
        var compositions: [KeySet: String] = [:]
        for (o, ot) in options(.onset) {
            for (v, vt) in options(.vowel) {
                for (c, ct) in options(.coda) {
                    let keys = o.union(v).union(c)
                    if !keys.isEmpty { compositions[keys] = ot + vt + ct }
                }
            }
        }
        let explicit = DictionaryLoader.allChords(data)
        let helper = try String(contentsOfFile: "Tests/KeyChordCoreTests/Helpers.swift", encoding: .utf8)
        let wordsPart = helper.components(separatedBy: "let top100 = \"\"\"")[1].components(separatedBy: "\"\"\"")[0]
        let words = wordsPart.replacingOccurrences(of: "\\", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        let examples = ["sat", "the", "and", "you", "use", "int", "thing", "important", "different", "through", "understanding", "A", "Z", "NASA"]
        var profiles: [String: Any] = [:]
        for (name, wiring) in [("no-blocking-assumed", nil), ("macbook-pro-2021-iso-model", iso), ("macbook-pro-2021-ansi-derived-model", ansi)] as [(String, KeyboardWiring?)] {
            let usable: (KeySet) -> Bool = { k in wiring.map { !blocked(k, $0) } ?? true }
            let planner = TypingPlanner(data: data, mode: .english, usable: usable)
            var chordCounts: [String: Int] = [:]
            var keyCounts: [String: Int] = [:]
            var samples: [String: Any] = [:]
            var fallbackWords: [String] = []
            var total = 0, keyPresses = 0, shiftChords = 0, sixKeyChords = 0
            for word in words {
                let plan = planner.plan(word)
                chordCounts[word] = plan.chordCount
                total += plan.chordCount
                if plan.normalCount > 0 { fallbackWords.append(word) }
                for step in plan.steps {
                    if case let .chord(keys, shift) = step.action {
                        keyPresses += keys.count + (shift ? 1 : 0)
                        if shift { shiftChords += 1 }
                        if keys.count == 6 { sixKeyChords += 1 }
                        for key in keys { keyCounts[key, default: 0] += 1 }
                    }
                }
            }
            for word in examples {
                let plan = planner.plan(word)
                samples[word] = plan.steps.map { step -> [String: Any] in
                    ["action": String(describing: step.action), "kind": step.kind.rawValue, "output": step.output]
                }
            }
            let coursePlans = Course.steps.map { step in
                TypingPlanner(data: data, mode: step.mode, usable: usable).plan(step.text)
            }
            profiles[name] = [
                "top100ItemCount": words.count,
                "top100OneChordWords": chordCounts.values.filter { $0 == 1 }.count,
                "top100TotalChords": total,
                "top100KeyPressesIncludingShift": keyPresses,
                "top100ShiftChords": shiftChords,
                "top100SixKeyChords": sixKeyChords,
                "top100NormalFallbackWords": fallbackWords,
                "top100ChordCounts": chordCounts,
                "top100KeyUse": keyCounts,
                "examples": samples,
                "courseTotalChords": coursePlans.reduce(0) { $0 + $1.chordCount },
                "courseNormalFallbackSteps": coursePlans.reduce(0) { $0 + $1.normalCount },
                "compositionCountPredictedBlocked": compositions.keys.filter { !usable($0) }.count,
                "explicitMappingsPredictedBlocked": explicit.filter { !usable($0.chord) }.map {
                    ["file": $0.file, "keys": layout.chordString($0.chord), "meaning": $0.label]
                },
            ]
        }
        let collisions = compositions.compactMap { keys, composed -> [String: String]? in
            guard let entry = data.english[keys] ?? data.shared[keys] else { return nil }
            let meaning = KeyMeanings.display(entry)
            guard meaning != composed else { return nil }
            return ["keys": layout.chordString(keys), "composed": composed, "actualDictionaryMeaning": meaning]
        }.sorted { $0["keys"]! < $1["keys"]! }
        let lessons = Course.steps.enumerated().map { index, step -> [String: Any] in
            ["id": step.id, "title": step.title, "newSkillItems": step.new.count,
             "introductoryChordItems": step.new.flatMap { Course.introductionChords(for: $0, at: index, data: data) }.count]
        }
        let briefCandidates: [[String: Any]] = [("use", ["Quote", "U", "S"]), ("you", ["Quote", "Y", "O"])].map { word, names in
            let keys = layout.keySet(names: names)!
            return ["word": word, "keys": layout.chordString(keys),
                    "currentEnglishMeaning": String(describing: ChordReading(keys, shift: false, data: data, mode: .english).outcome),
                    "currentCppMeaning": String(describing: ChordReading(keys, shift: false, data: data, mode: .cpp).outcome),
                    "predictedBlockedISO": blocked(keys, iso), "predictedBlockedANSI": blocked(keys, ansi)]
        }
        let result: [String: Any] = [
            "method": "Bundled defaults, 6-key limit. Every word in the repository's top100 test list is planned once from fresh English context; not a frequency-weighted corpus or a speed/comfort benchmark. Blocked counts are model predictions, not new hardware measurements. Composition counts include abstract/nonword combinations and intentional dictionary overrides.",
            "courseLessonCount": Course.steps.count,
            "curriculumVersion": Course.curriculumVersion,
            "clusterCounts": Dictionary(uniqueKeysWithValues: Bank.allCases.map { ($0.rawValue, (layout.clusters[$0] ?? [:]).count) }),
            "compositionCountIncludingEmptyBanksExcludingEmptyChord": compositions.count,
            "explicitMappingCount": explicit.count,
            "englishCompositionOverrides": collisions,
            "profiles": profiles,
            "lessonLoads": lessons,
            "experimentalBriefCandidates": briefCandidates,
        ]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
