import Foundation
import Testing
@testable import KeyChordCore

func sources(_ overrides: [DataFile: String] = [:]) -> [DataFile: String?] {
    var s: [DataFile: String?] = [:]
    for f in DataFile.allCases { s[f] = overrides[f] ?? f.defaultSource }
    return s
}

@Suite("Dictionary loader")
struct LoaderTests {
    func problems(_ file: DataFile, _ text: String, limit: Int = 6) -> [LoadProblem] {
        DictionaryLoader.load(sources: sources([file: text]), rolloverLimit: limit).problems
    }

    @Test("Req 15.4: each kind of problem is reported with file and entry")
    func validation() {
        let cases: [(String, String)] = [
            ("T+E", "syntax"),                           // no '='
            ("T+Nope = \"x\"", "unknown key"),
            ("Q+W+E+R+T+A+S = \"x\"", "rollover"),
            ("T+E = \"a|b|c\"", "cursor marker"),
            ("T+E = \"x\" sparkly", "unknown flag"),
            ("T+E = frobnicate", "unknown command"),
            ("T+E = \"unterminated", "unterminated"),
        ]
        for (line, what) in cases {
            let p = problems(.english, line)
            #expect(p.count == 1, "\(what)")
            #expect(p.first?.file == "english.dict")
            #expect(p.first?.line == 1)
            #expect(p.first?.entry == line)
        }
        let dup = problems(.cpp, "T+E = \"a\"\nE+T = \"b\"")
        #expect(dup.count == 1 && dup[0].message.contains("duplicate") && dup[0].line == 2)
    }

    @Test("Req 15.4: layout validation, including the cluster-table limit")
    func layoutValidation() {
        let tooBig = DataFile.layout.defaultSource.replacingFirst("[vowel]\n", with: "[vowel]\nC+V+N = \"eau\"\n")
        let p = problems(.layout, tooBig)
        #expect(p.contains { $0.message.contains("rollover limit") && $0.file == "layout.txt" })
        let forbidden = DataFile.layout.defaultSource.replacingFirst("[keys]\n", with: "[keys]\nCaps 57 onset\n")
        #expect(problems(.layout, forbidden).contains { $0.message.contains("Caps Lock") })
        let wrongBank = DataFile.layout.defaultSource.replacingFirst("[onset]\n", with: "[onset]\nJ = \"j\"\n")
        #expect(problems(.layout, wrongBank).contains { $0.message.contains("not in the onset bank") })
        // Lowering the rollover limit makes the defaults invalid.
        #expect(!DictionaryLoader.load(sources: sources(), rolloverLimit: 5).problems.isEmpty)
    }

    @Test("Req 15.5: invalid files fall back to last valid, then to defaults")
    func fallback() {
        let custom = "Backslash = undo\nLBracket+RBracket = mode-switch\nT+E+N = \"thee\"\n"
        let o1 = DictionaryLoader.load(sources: sources([.shared: custom]), rolloverLimit: 6)
        #expect(o1.problems.isEmpty)
        #expect(o1.acceptedSources[.shared] == custom)

        let broken = "Backslash = undo\nnonsense\n"
        let o2 = DictionaryLoader.load(sources: sources([.shared: broken]), lastValid: o1.acceptedSources, rolloverLimit: 6)
        #expect(o2.problems.count == 1)
        #expect(o2.fallbacks == [.shared])
        #expect(o2.acceptedSources[.shared] == custom)

        let o3 = DictionaryLoader.load(sources: sources([.shared: broken]), rolloverLimit: 6)
        #expect(o3.acceptedSources[.shared] == DataFile.shared.defaultSource)

        var missing = sources()
        missing[.english] = .some(nil)
        let o4 = DictionaryLoader.load(sources: missing, rolloverLimit: 6)
        #expect(o4.acceptedSources[.english] == DataFile.english.defaultSource)
    }

    @Test("Req 5.10: warnings for chords containing a failed combination")
    func probeWarnings() {
        let report = ProbeReport(created: 1, maxHeld: 5, results: [
            ProbeResult(timestamp: 2, target: ["T", "E"], outcome: .fail, detail: ["E"]),
            ProbeResult(timestamp: 3, target: ["S", "D"], outcome: .pass),
        ])
        let o = DictionaryLoader.load(sources: sources(), rolloverLimit: 6, probeReport: report.serialized())
        #expect(!o.warnings.isEmpty)
        #expect(o.warnings.contains { $0.file == "layout.txt" && $0.entry?.hasPrefix("E+T =") == true })
        #expect(o.warnings.allSatisfy { $0.entry?.contains("T") == true && $0.entry?.contains("E") == true })
        #expect(!o.warnings.contains { $0.entry?.hasPrefix("S+D =") == true })
    }
}

@Suite("Rollover probe")
struct ProbeTests {
    let l = defaults.layout

    @Test("Req 5.1, 5.2: held keys and maximum")
    func held() {
        let p = ProbeSession(layout: l)
        p.keyDown(17); p.keyDown(14); p.modifierDown(56)
        #expect(p.names(p.heldKeys) == ["T", "E"])
        #expect(p.heldModifiers == [56])
        p.keyUp(17, time: 1)
        p.keyDown(45)
        #expect(p.maxHeld == 2)
    }

    @Test("Req 5.5, 5.6: pass, fail, extra, retry, ghost")
    func guided() {
        let p = ProbeSession(layout: l)
        p.startGuided([keys("T+E"), keys("T+E+N"), keys("S+D")])
        p.keyDown(17); p.keyDown(14)
        p.keyUp(17, time: 1)
        #expect(p.keyUp(14, time: 2)?.outcome == .pass)
        p.keyDown(17); p.keyDown(14)
        p.keyUp(17, time: 3)
        let f = p.keyUp(14, time: 4)
        #expect(f?.outcome == .fail && f?.detail == ["N"])
        p.keyDown(1); p.keyDown(2); p.keyDown(3)
        p.keyUp(1, time: 5); p.keyUp(2, time: 5)
        let x = p.keyUp(3, time: 6)
        #expect(x?.outcome == .extra && x?.detail == ["F"])
        #expect(p.awaitingExtraDecision)
        p.retry()
        #expect(p.results.count == 2 && p.currentTarget == keys("S+D"))
        p.keyDown(1); p.keyDown(2); p.keyDown(3)
        p.keyUp(1, time: 7); p.keyUp(2, time: 7); p.keyUp(3, time: 7)
        p.recordGhost()
        #expect(p.results.last?.outcome == .ghost)
        #expect(!p.guidedActive)
    }

    @Test("Back and forward: a mistyped attempt is redone without starting over")
    func backForward() {
        let p = ProbeSession(layout: l)
        p.startGuided([keys("T+E+N"), keys("S+D+F"), keys("Q+W+E")])
        p.keyDown(17); p.keyDown(14); p.keyUp(17, time: 1); p.keyUp(14, time: 1)   // N forgotten
        #expect(p.results.map(\.outcome) == [.fail])
        #expect(p.currentTarget == keys("S+D+F"))
        p.back()
        #expect(p.currentTarget == keys("T+E+N") && p.currentResult?.outcome == .fail)
        p.keyDown(17); p.keyDown(14); p.keyDown(45)
        p.keyUp(17, time: 2); p.keyUp(14, time: 2); p.keyUp(45, time: 2)
        #expect(p.results.map(\.outcome) == [.pass])
        p.forward()                                                              // S+D+F left untested
        #expect(p.currentTarget == keys("Q+W+E"))
        p.back(); p.back()
        #expect(p.currentTarget == keys("T+E+N") && !p.canGoBack)
        p.forward(); p.forward(); p.forward()
        #expect(!p.guidedActive && p.results.count == 1)
        // An unexpected-keys attempt: Back discards it and stays.
        p.back()
        p.keyDown(12); p.keyDown(13); p.keyDown(14); p.keyDown(15)
        p.keyUp(12, time: 3); p.keyUp(13, time: 3); p.keyUp(14, time: 3); p.keyUp(15, time: 3)
        #expect(p.awaitingExtraDecision)
        p.back()
        #expect(!p.awaitingExtraDecision && p.currentTarget == keys("Q+W+E") && p.currentResult == nil)
    }

    @Test("Req 5.4: target sources")
    func targets() throws {
        var rng = SplitMix64(seed: 5)
        let tables = ProbeSession.targets(source: .layoutTables, data: defaults, rolloverLimit: 6, count: 0, using: &rng)
        let expectedTables = Bank.allCases.map { l.clusters[$0]!.count }.reduce(0, +) + l.fingerspelling.count
        #expect(tables.count <= expectedTables && tables.count > 20)
        let dict = ProbeSession.targets(source: .dictionaries, data: defaults, rolloverLimit: 6, count: 0, using: &rng)
        #expect(dict.count > 50)
        // One and two key combinations always work, so they are never tested.
        #expect((tables + dict).allSatisfy { $0.count >= 3 })
        let random = ProbeSession.targets(source: .randomSyllables, data: defaults, rolloverLimit: 6, count: 40, using: &rng)
        #expect(random.count == 40)
        for k in random {
            #expect(k.count == 6)
            #expect(k.isSubset(of: l.allBanksMask))
            #expect(try ChordEngine(data: defaults).translate(k, join: false).signal == nil)
        }
    }

    @Test("Req 5.8, 5.9: report round-trip, no typed text")
    func roundTrip() throws {
        var rng = SplitMix64(seed: 17)
        let names = l.keys.map(\.name)
        for _ in 0..<200 {
            let results = (0..<Int.random(in: 0...20, using: &rng)).map { _ -> ProbeResult in
                let target = Array(names.shuffled(using: &rng).prefix(Int.random(in: 1...6, using: &rng)))
                let outcome = ProbeOutcome.allCases.randomElement(using: &rng)!
                let detail = outcome == .pass ? [] : Array(names.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)))
                return ProbeResult(timestamp: Int64.random(in: 0...Int64.max, using: &rng), target: target, outcome: outcome, detail: detail)
            }
            let r = ProbeReport(created: Int64.random(in: 0...Int64.max, using: &rng), maxHeld: Int.random(in: 0...12, using: &rng), results: results)
            #expect(try ProbeReport.parse(r.serialized()) == r)
        }
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let r = range(of: target) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
