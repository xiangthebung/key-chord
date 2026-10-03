import Testing
@testable import KeyChordCore

@Suite("Wiring check")
struct WiringCheckTests {
    let layout = defaults.layout
    func code(_ n: String) -> KeyCode { layout.keys[layout.indexByName[n]!].code }
    var rounds: [WiringCheckRound] { get throws { try WiringCheckPlan.parse(DefaultData.wiringCheckMacBookPro18, layout: layout) } }
    var wiring: KeyboardWiring { get throws { try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: layout) } }
    /// The first check was planned against the wiring before it.
    var wiringBefore: KeyboardWiring { get throws { try KeyboardWiring.parse(wiringBeforeCheck, layout: layout) } }
    var check1: [MatrixSweep] { get throws { try #require(try MatrixScanReport.parse(macBookPro18Check1, layout: layout)).sweeps } }
    var rounds2: [WiringCheckRound] { get throws { try WiringCheckPlan.parse(DefaultData.wiringCheck2MacBookPro18, layout: layout) } }
    var scan: (sweeps: [MatrixSweep], combos: [MatrixCombo]) { get throws { try #require(try MatrixScanReport.parse(macBookPro18Scan, layout: layout)) } }

    func triples(_ s: MatrixSweep) -> [Set<KeyCode>] {
        let tapped = s.tapped ?? Set(layout.keys.map(\.code)).subtracting([s.pair.a, s.pair.b])
        return tapped.map { [s.pair.a, s.pair.b, $0] }
    }

    @Test("Nothing from the first scan is asked again")
    func noRepeats() throws {
        let before = Set(try scan.sweeps.flatMap(triples))
        let heldBefore = Set(try scan.sweeps.map(\.pair))
        let r = try rounds
        #expect(r.count == 41)
        for round in r {
            #expect(!heldBefore.contains(round.pair), "\(round.pair) was held in the first scan")
            for x in round.taps { #expect(!before.contains([round.pair.a, round.pair.b, x])) }
        }
        let asked = r.flatMap { rd in rd.taps.map { Set([rd.pair.a, rd.pair.b, $0]) } }
        #expect(Set(asked).count == asked.count, "a combination is asked twice")
        print("check: \(r.count) rounds, \(asked.count) taps")
    }

    @Test("Every triple of the eight untested keys is covered")
    func soloTriples() throws {
        let asked = Set(try rounds.flatMap { rd in rd.taps.map { Set([rd.pair.a, rd.pair.b, $0]) } })
        let solo = try wiringBefore.solo
        #expect(solo.count == 8)
        for i in 0..<solo.count {
            for j in (i + 1)..<solo.count {
                for k in (j + 1)..<solo.count { #expect(asked.contains([solo[i], solo[j], solo[k]])) }
            }
        }
    }

    @Test("Check 1 covered every corner the earlier wiring relied on; check 2 every corner the current one does",
          arguments: [1, 2])
    func corners(check: Int) throws {
        let w = check == 1 ? try wiringBefore : try wiring
        let observed = try scan.sweeps.flatMap(triples) + (try scan.combos.map(\.keys))
            + (check == 2 ? try check1.flatMap(triples) : [])
        let plan = check == 1 ? try rounds : try rounds2
        let asked = plan.flatMap { rd in rd.taps.map { Set([rd.pair.a, rd.pair.b, $0]) } }
        func corner(_ t: Set<KeyCode>) -> KeyboardWiring.Position? {
            let a = Array(t)
            guard a.count == 3, let p = a.compactMap({ w.position[$0] }) as [KeyboardWiring.Position]?, p.count == 3 else { return nil }
            for (x, y, z) in [(p[0], p[1], p[2]), (p[1], p[0], p[2]), (p[2], p[0], p[1])] {
                if y.row == z.row || y.column == z.column { continue }
                if x.row == y.row && x.column == z.column { return .init(z.row, y.column) }
                if x.column == y.column && x.row == z.row { return .init(y.row, z.column) }
            }
            return nil
        }
        let known = layout.keys.map(\.code).filter { !w.solo.contains($0) }
        var needed = Set<KeyboardWiring.Position>()
        for i in 0..<known.count {
            for j in (i + 1)..<known.count {
                for k in (j + 1)..<known.count {
                    if let c = corner([known[i], known[j], known[k]]), !w.occupied.contains(c) { needed.insert(c) }
                }
            }
        }
        // Every 3-key part of a 4-6 key combination was observed too.
        func parts(_ t: Set<KeyCode>) -> [Set<KeyCode>] {
            let a = Array(t)
            var out: [Set<KeyCode>] = []
            for i in 0..<a.count { for j in (i + 1)..<a.count { for k in (j + 1)..<a.count { out.append([a[i], a[j], a[k]]) } } }
            return out
        }
        let seen = Set(observed.flatMap(parts).compactMap(corner))
        let checked = Set(asked.compactMap(corner))
        let open = needed.subtracting(seen).subtracting(checked)
        #expect(open.isEmpty, "unchecked corners: \(open)")
    }

    /// Plays the check against a keyboard that follows `truth`.
    func run(_ truth: KeyboardWiring) throws -> WiringCheckSession {
        let s = WiringCheckSession(layout: layout, rounds: try rounds)
        var guardCount = 0
        while let r = s.round, guardCount < 100 {
            guardCount += 1
            s.keyDown(r.pair.a); s.keyDown(r.pair.b)
            for k in r.taps where !truth.tripleBlocked(r.pair.a, r.pair.b, k) { s.keyDown(k); s.keyUp(k) }
            if !s.unresolved.isEmpty, let f = s.finishKey { s.keyDown(f); s.keyUp(f) }
            s.keyUp(r.pair.a); s.keyUp(r.pair.b)
        }
        return s
    }

    @Test("Check 2 repeats nothing from the scan or check 1")
    func check2New() throws {
        let before = Set(try scan.sweeps.flatMap(triples) + (try check1.flatMap(triples)))
        let heldBefore = Set(try scan.sweeps.map(\.pair) + (try check1.map(\.pair)))
        let r = try rounds2
        #expect(r.count == 4 && r.reduce(0) { $0 + $1.taps.count } == 23)
        for round in r {
            #expect(!heldBefore.contains(round.pair))
            for x in round.taps { #expect(!before.contains([round.pair.a, round.pair.b, x])) }
            // The last key ends the round and always registers.
            #expect(try !wiring.tripleBlocked(round.pair.a, round.pair.b, round.taps.last!))
        }
        let plan = try WiringCheckPlan.parseNamed(DefaultData.wiringCheck2MacBookPro18, layout: layout)
        #expect(plan.name == "2")
        #expect(try WiringCheckPlan.parseNamed(DefaultData.wiringCheckMacBookPro18, layout: layout).name == "1")
    }

    @Test("On the wiring as written, every round finishes and nothing is a surprise")
    func matchesWiring() throws {
        let s = try run(try wiring)
        #expect(s.phase == .finished && s.done.count == 41)
        let fit = try wiring.fit(sweeps: s.done, combos: [], layout: layout)
        #expect(fit.explained == fit.total)
    }

    @Test("A hidden wire between two of the eight keys shows up")
    func findsHiddenWire() throws {
        // Suppose W and S share a column wire of their own, W on the top row and S on the home row.
        var text = wiringBeforeCheck.replacingOccurrences(of: "solo W E R S D G V B", with: "solo E R D G V B")
        text = text.replacingOccurrences(of: "columns k1 k2 k3 k4 k5 k6 k7 k8 k9 k0 kEq kBs", with: "columns k1 k2 k3 k4 k5 k6 k7 k8 k9 k0 kEq kBs kW")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("row ") else { return String(line) }
            let name = line.split(separator: " ")[1]
            return line + (name == "top" ? " W" : name == "home" ? " S" : " .")
        }
        let truth = try KeyboardWiring.parse(lines.joined(separator: "\n"), layout: layout)
        #expect(truth.tripleBlocked(code("W"), code("S"), code("Q")))      // corner at W: Q's column has A on the home row
        let s = try run(truth)
        let fit = try wiringBefore.fit(sweeps: s.done, combos: [], layout: layout)
        #expect(fit.explained < fit.total)
        print("hidden W-S wire: \(fit.total - fit.explained) surprises, e.g. \(fit.mismatches.prefix(3))")
    }

    @Test("Back redoes a round, Skip leaves it for the end, results survive a reload")
    func navigation() throws {
        let r = try rounds
        let s = WiringCheckSession(layout: layout, rounds: r)
        func play() {
            let rd = s.round!
            s.keyDown(rd.pair.a); s.keyDown(rd.pair.b)
            for k in rd.taps { s.keyDown(k); s.keyUp(k) }
            s.keyUp(rd.pair.a); s.keyUp(rd.pair.b)
        }
        play()
        #expect(s.done.count == 1 && s.index == 1)
        s.forward()
        #expect(s.index == 2)
        play()
        #expect(s.done.count == 2)
        s.back()
        #expect(s.index == 2 && s.done.count == 1)
        play()
        let reloaded = WiringCheckSession(layout: layout, rounds: r, results: s.done)
        #expect(reloaded.done.count == 2 && reloaded.index == 1)
        let text = s.report(hardware: "T", wiring: try wiring, scan: try scan.sweeps, scanCombos: try scan.combos)
        #expect(try MatrixScanReport.parse(text, layout: layout)?.sweeps.count == 2)
        #expect(text.contains("with everything before it"))
    }
}
