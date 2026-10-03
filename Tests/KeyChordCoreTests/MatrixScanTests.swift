import Testing
@testable import KeyChordCore

/// A simulated keyboard: every key sits on one (row, column) cell of an electrical grid.
struct SimulatedMatrix {
    var cell: [KeyCode: (Int, Int)]

    init<G: RandomNumberGenerator>(keys: [KeyCode], rows: Int, cols: Int, using rng: inout G) {
        var cells = (0..<(rows * cols)).map { ($0 / cols, $0 % cols) }
        cells.shuffle(using: &rng)
        cell = [:]
        for (i, k) in keys.enumerated() { cell[k] = cells[i] }
    }

    init(cells: [KeyCode: (Int, Int)]) { cell = cells }

    func shares(_ a: KeyCode, _ b: KeyCode) -> Bool {
        let x = cell[a]!, y = cell[b]!
        return x.0 == y.0 || x.1 == y.1
    }

    func blocked(_ a: KeyCode, _ b: KeyCode, _ c: KeyCode) -> Bool {
        [shares(a, b), shares(a, c), shares(b, c)].filter { $0 }.count == 2
    }

    func sweep(_ p: KeyPair, keys: [KeyCode], tapped: Set<KeyCode>? = nil) -> MatrixSweep {
        let t = tapped.map { $0.count == keys.count - 2 ? nil : $0 } ?? nil
        return MatrixSweep(pair: p, blocked: Set(keys.filter {
            $0 != p.a && $0 != p.b && t?.contains($0) != false && blocked(p.a, p.b, $0)
        }), tapped: t)
    }
}

/// Deterministic generator so failures can be reproduced.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Matrix scan")
struct MatrixScanTests {
    let layout = defaults.layout
    var codes: [KeyCode] { layout.keys.map(\.code) }

    /// Runs the planner against a simulated keyboard until it has nothing left to ask.
    func runScan(_ sim: SimulatedMatrix, canHold: (KeyCode, KeyCode) -> Bool = { _, _ in true },
                 maxSweeps: Int = 120) -> MatrixModel {
        let model = MatrixModel(keys: codes)
        let start = [KeyPair(code("J"), code("M"))]
        while model.sweeps.count < maxSweeps,
              let p = MatrixPlanner.nextPair(model: model, preferred: start, canHold: canHold) {
            model.add(sim.sweep(p, keys: codes, tapped: model.usefulTaps(p)))
        }
        return model
    }

    func code(_ name: String) -> KeyCode { layout.keys[layout.indexByName[name]!].code }

    /// Everything the model claims must match the simulated keyboard.
    func expectSound(_ model: MatrixModel, _ sim: SimulatedMatrix, allowLeftOut: Bool = false) {
        if !allowLeftOut { #expect(model.inconsistent.isEmpty) }
        for a in codes {
            for b in codes where a < b {
                if let s = model.shares(a, b) { #expect(s == sim.shares(a, b), "pair \(a) \(b)") }
            }
        }
    }

    @Test("Triple rule: an L is blocked, a line or scattered keys are not")
    func tripleRule() {
        let sim = SimulatedMatrix(cells: [1: (0, 0), 2: (0, 1), 3: (1, 0), 4: (0, 2), 5: (2, 2)])
        #expect(sim.blocked(1, 2, 3))          // L with corner 1
        #expect(!sim.blocked(1, 2, 4))         // one row
        #expect(!sim.blocked(3, 4, 2))         // only one sharing pair
        #expect(!sim.blocked(1, 5, 3))         // only one sharing pair
        #expect(MatrixModel.tripleBlocked(1, 1, 0) == true)
        #expect(MatrixModel.tripleBlocked(1, 1, 1) == false)
        #expect(MatrixModel.tripleBlocked(1, 1, -1) == nil)
        #expect(MatrixModel.tripleBlocked(0, 0, -1) == false)
    }

    @Test("Random grids are reconstructed exactly", arguments: [1, 2, 3] as [UInt64])
    func reconstruct(seed: UInt64) {
        var rng = SplitMix(state: seed)
        let shapes = [(8, 16), (6, 18), (10, 12)]
        let (rows, cols) = shapes[Int(seed) % shapes.count]
        let sim = SimulatedMatrix(keys: codes, rows: rows, cols: cols, using: &rng)
        let clock = ContinuousClock()
        var model: MatrixModel!
        let elapsed = clock.measure { model = runScan(sim) }
        print("grid \(rows)x\(cols) seed \(seed): \(model.sweeps.count) sweeps, \(elapsed)")
        expectSound(model, sim)
        #expect(model.unknownPairs == 0)
        #expect(model.sweeps.count <= 45, "took \(model.sweeps.count) sweeps")
        #expect(!model.lines().conflict)
        // Every triple prediction matches.
        for _ in 0..<500 {
            let t = codes.shuffled(using: &rng).prefix(3)
            let (a, b, c) = (t[t.startIndex], t[t.startIndex + 1], t[t.startIndex + 2])
            #expect(model.tripleBlocked(a, b, c) == sim.blocked(a, b, c))
        }
    }

    @Test("Only one-hand pairs: still sound, and most pairs known", arguments: [11, 12] as [UInt64])
    func holdableOnly(seed: UInt64) {
        var rng = SplitMix(state: seed)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        // Approximate physical positions: number row, Q row, A row, Z row.
        let rows: [[String]] = [["Grave", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "Minus", "Equal"],
                                ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "LBracket", "RBracket", "Backslash"],
                                ["A", "S", "D", "F", "G", "H", "J", "K", "L", "Semicolon", "Quote"],
                                ["Z", "X", "C", "V", "B", "N", "M", "Comma", "Period", "Slash"]]
        var pos: [KeyCode: (Double, Double)] = [code("Space"): (6, 4)]
        for (y, r) in rows.enumerated() {
            for (x, n) in r.enumerated() { pos[code(n)] = (Double(x) + [0, 0.5, 0.75, 1.25][y], Double(y)) }
        }
        let canHold: (KeyCode, KeyCode) -> Bool = { a, b in
            let p = pos[a]!, q = pos[b]!
            let dx = a == code("Space") || b == code("Space") ? max(0, abs(p.0 - q.0) - 2.5) : abs(p.0 - q.0)
            return dx <= 4 && abs(p.1 - q.1) <= 3
        }
        let model = runScan(sim, canHold: canHold)
        print("one-hand seed \(seed): \(model.sweeps.count) sweeps, unknown \(model.unknownPairs)")
        expectSound(model, sim)
        #expect(model.unknownPairs * 10 <= model.totalPairs, "unknown \(model.unknownPairs), sweeps \(model.sweeps.count)")
    }

    @Test("A sweep that contradicts the others is left out")
    func contradiction() {
        var rng = SplitMix(state: 99)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let model = runScan(sim)
        #expect(model.unknownPairs == 0)
        // A fully known model predicts every sweep; flip one key to fake a mistake.
        let p = KeyPair(code("Q"), code("P"))
        var s = sim.sweep(p, keys: codes)
        let x = code("A")
        if s.blocked.contains(x) { s.blocked.remove(x) } else { s.blocked.insert(x) }
        #expect(model.add(s) == false)
        #expect(model.inconsistent == [model.sweeps.count - 1])
        expectSound(model, sim, allowLeftOut: true)
    }

    /// Plays one round the way a person does: hold the pair, tap every highlighted key once in order (blocked
    /// ones produce no event), tap the finish key if the last ones stayed dark, let go. `forget` are keys the
    /// person passes over by accident. Returns the number of taps.
    @discardableResult
    func userRound(_ s: MatrixScanSession, _ sim: SimulatedMatrix, forget: Set<KeyCode> = []) -> Int {
        guard let p = s.pair else { return 0 }
        var taps = 0
        s.keyDown(p.a); s.keyDown(p.b)
        for k in s.order {
            taps += 1
            if !forget.contains(k) && !sim.blocked(p.a, p.b, k) { s.keyDown(k); s.keyUp(k) }
        }
        if !s.unresolved.isEmpty, let f = s.finishKey { taps += 1; s.keyDown(f); s.keyUp(f) }
        s.keyUp(p.a); s.keyUp(p.b)
        return taps
    }

    @Test("One tap per combination: the full map with no second pass")
    func sessionSinglePass() {
        var rng = SplitMix(state: 5)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let s = MatrixScanSession(layout: layout, preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        #expect(s.pair == KeyPair(code("J"), code("M")))
        var taps = 0, rounds = 0
        while s.stage == .sweeps, s.pair != nil, rounds < 60 {
            taps += userRound(s, sim)
            rounds += 1
        }
        #expect(s.model.unknownPairs == 0)
        #expect(s.model.inconsistent.isEmpty)
        for sw in s.sweeps { #expect(sw.blocked == sim.sweep(sw.pair, keys: codes, tapped: sw.tapped).blocked) }
        // Each tap is one 3-key test; the only extra taps are the finish taps.
        #expect(taps <= s.tripleTests + rounds)
        print("single pass: \(rounds) rounds, \(taps) taps")
    }

    @Test("A key passed over by accident: only the dark keys are asked again")
    func sessionRecheck() {
        var rng = SplitMix(state: 6)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let s = MatrixScanSession(layout: layout, preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        // Map most of the keyboard first, so a wrong result is noticed.
        for _ in 0..<12 where s.pair != nil { userRound(s, sim) }
        guard let p = s.pair else { Issue.record("finished early"); return }
        // Forget a key that should register and whose result the model can check.
        let forgettable = s.order.filter { !sim.blocked(p.a, p.b, $0) && $0 != s.order.last }
        guard let k = forgettable.first(where: { x in
            let m = MatrixModel(keys: codes, sweeps: s.sweeps)
            var t = sim.sweep(p, keys: codes, tapped: Set(s.order))
            t.blocked.insert(x)
            return !m.add(t)
        }) else { Issue.record("no checkable key in this round"); return }
        let before = s.sweeps.count
        userRound(s, sim, forget: [k])
        #expect(s.rechecking != nil)
        #expect(s.sweeps.count == before)
        #expect(s.order.contains(k))
        print("recheck asks for \(s.order.count) keys")
        let recheckTaps = userRound(s, sim)
        #expect(s.rechecking == nil && s.sweeps.count == before + 1)
        #expect(s.sweeps.last?.blocked.contains(k) == false)
        #expect(recheckTaps < 20)
    }

    @Test("A red key tapped again turns green")
    func sessionRetapRed() {
        let s = MatrixScanSession(layout: layout, preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        let p = s.pair!
        s.keyDown(p.a); s.keyDown(p.b)
        let o = s.order
        s.keyDown(o[2]); s.keyUp(o[2])                // passed over o[0] and o[1]
        #expect(s.missedKeys == [o[0], o[1]])
        s.keyDown(o[0]); s.keyUp(o[0])                // it was a slip
        #expect(s.missedKeys == [o[1]] && s.registeredKeys.contains(o[0]))
        #expect(s.current == o[3])
    }

    @Test("Letting go of the pair pauses; releasing without tapping records nothing")
    func sessionPause() {
        let s = MatrixScanSession(layout: layout, preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        let p = s.pair!
        s.keyDown(p.a); s.keyDown(p.b); s.keyUp(p.a); s.keyUp(p.b)
        #expect(s.sweeps.isEmpty && s.status.isEmpty)
        s.keyDown(p.a); s.keyDown(p.b)
        let o = s.order
        s.keyDown(o[0]); s.keyUp(o[0])
        s.keyUp(p.b)                                  // lifted: taps don't count
        s.keyDown(o[1]); s.keyUp(o[1])
        #expect(s.status[o[1]] == nil)
        s.keyUp(p.a)
        #expect(s.sweeps.isEmpty && s.status[o[0]] == .registered)
        s.keyDown(p.a); s.keyDown(p.b)
        #expect(s.phase == .tapping && s.current == o[1])
    }

    @Test("Session waits until only the pair is held")
    func sessionOtherKeyHeld() {
        let s = MatrixScanSession(layout: layout, preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        s.keyDown(code("Q")); s.keyDown(code("J")); s.keyDown(code("M"))
        #expect(s.phase == .hold)
        s.keyUp(code("Q"))
        #expect(s.phase == .tapping)
    }

    @Test("Saved rounds where nothing registered are dropped on load")
    func dropEmptyRounds() {
        let all = Set(codes)
        let bad = [MatrixSweep(pair: KeyPair(code("J"), code("M")), blocked: all.subtracting([code("J"), code("M")])),
                   MatrixSweep(pair: KeyPair(code("4"), code("J")), blocked: all.subtracting([code("4"), code("J")]))]
        let s = MatrixScanSession(layout: layout, sweeps: bad, canHold: { _, _ in true })
        #expect(s.droppedOnLoad == 2 && s.sweeps.isEmpty)
    }

    @Test("Report round-trips its sweeps")
    func reportRoundTrip() throws {
        var rng = SplitMix(state: 3)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let model = runScan(sim, maxSweeps: 20)
        #expect(model.sweeps.contains { $0.tapped != nil })
        let combos = [MatrixCombo(keys: [code("T"), code("E"), code("N"), code("S")], outcome: .fail, missing: [code("N")]),
                      MatrixCombo(keys: [code("Q"), code("W"), code("C"), code("Y")], outcome: .pass)]
        let text = MatrixScanReport.serialize(model: model, combos: combos, layout: layout, hardware: "Test1,1", data: defaults)
        #expect(text.contains("# wiring:"))
        let back = try MatrixScanReport.parse(text, layout: layout)
        #expect(back?.sweeps == model.sweeps)
        #expect(back?.combos == combos)
        // A different key list is not reloaded.
        #expect(try MatrixScanReport.parse("version 1\nkeys A B\n", layout: layout) == nil)
    }

    @Test("Wiring grid: every key sits where its two lines cross")
    func wiringGrid() {
        var rng = SplitMix(state: 31)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        // Build the fully known model directly from the simulated keyboard.
        let model = MatrixModel(keys: codes)
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count { model.state.set(i, j, sim.shares(codes[i], codes[j]) ? 1 : 0) }
        }
        #expect(model.unknownPairs == 0)
        #expect(!model.lines().conflict)
        let text = MatrixScanReport.wiring(model: model, name: { layout.keys[layout.indexByCode[$0]!].name })
        // Every pair of keys shares a table row or column exactly when it shares a line.
        var place: [String: (Int, Int)] = [:]
        let table = text.split(separator: "\n").filter { $0.hasPrefix("# A") && $0.dropFirst(3).first?.isNumber == true }
        for (r, line) in table.enumerated() {
            for (c, cellText) in line.split(separator: " ").dropFirst(2).enumerated() where cellText != "." {
                place[String(cellText)] = (r, c)
            }
        }
        #expect(place.count == codes.count)
        for a in codes {
            for b in codes where a < b {
                let na = layout.keys[layout.indexByCode[a]!].name, nb = layout.keys[layout.indexByCode[b]!].name
                guard let pa = place[na], let pb = place[nb] else { continue }
                #expect((pa.0 == pb.0 || pa.1 == pb.1) == sim.shares(a, b), "\(na) \(nb)")
            }
        }
    }

    @Test("Keyboard limits from a saved scan block exactly the bad chords")
    func limits() throws {
        var rng = SplitMix(state: 41)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let model = MatrixModel(keys: codes)
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count { model.state.set(i, j, sim.shares(codes[i], codes[j]) ? 1 : 0) }
        }
        let bad4 = Set([code("Q"), code("W"), code("O"), code("P")])
        let lim = KeyboardLimits(model: model, combos: [MatrixCombo(keys: bad4, outcome: .fail, missing: [code("P")])])
        for _ in 0..<300 {
            let t = Array(codes.shuffled(using: &rng).prefix(3))
            #expect(lim.blocks(t) == (sim.blocked(t[0], t[1], t[2]) || false))
        }
        #expect(lim.blocks(Array(bad4) + [code("Space")]))
        #expect(!lim.blocks([code("Q"), code("W")]))
        #expect(KeyboardLimits(scanText: nil, layout: layout) == nil)
    }

    @Test("Wiring grid for the J/H/M example")
    func wiringExample() {
        let sim = SimulatedMatrix(cells: [code("J"): (0, 0), code("H"): (0, 1), code("M"): (1, 0)])
        let three = [code("J"), code("H"), code("M")]
        let model = MatrixModel(keys: three)
        for i in 0..<3 { for j in (i + 1)..<3 { model.state.set(i, j, sim.shares(three[i], three[j]) ? 1 : 0) } }
        #expect(model.tripleBlocked(code("J"), code("H"), code("M")) == true)
    }

    /// Drives stage 2 against a simulated keyboard: the keys that register are those not blocked.
    func pressCombo(_ s: MatrixScanSession, _ registers: (Set<KeyCode>) -> Set<KeyCode>) {
        guard let t = s.currentCombo else { return }
        let ok = registers(t)
        for k in t.sorted() where ok.contains(k) { s.keyDown(k) }
        for k in t.sorted() where ok.contains(k) { s.keyUp(k) }
    }

    @Test("4-6 key check: all predicted-safe chords pass on a plain grid, blocked ones are never asked")
    func combosPlainGrid() {
        var rng = SplitMix(state: 21)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let model = runScan(sim)
        let s = MatrixScanSession(layout: layout, sweeps: model.sweeps, candidates: MatrixScanSession.candidateChords(defaults),
                                  canHold: { _, _ in true })
        s.enterCombos()
        #expect(s.stage == .combos)
        var asked = 0
        while let t = s.currentCombo, asked < 100 {
            #expect(model.chordBlocked(Array(t)) == false)
            #expect((4...6).contains(t.count))
            pressCombo(s) { $0 }
            asked += 1
        }
        #expect(asked == 3 * MatrixScanSession.combosPerSize)
        #expect(s.combos.allSatisfy { $0.outcome == .pass })
    }

    @Test("4-6 key check: an unexpected failure is narrowed down and its supersets are skipped")
    func combosNarrowing() {
        var rng = SplitMix(state: 22)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let model = runScan(sim)
        let s = MatrixScanSession(layout: layout, sweeps: model.sweeps, candidates: MatrixScanSession.candidateChords(defaults),
                                  canHold: { _, _ in true })
        s.enterCombos()
        guard let first = s.currentCombo else { Issue.record("no combos"); return }
        // A non-grid rule: this 4-key subset of the first chord drops one key.
        let bad = Set(first.sorted().prefix(4))
        let dropped = bad.sorted().last!
        let registers: (Set<KeyCode>) -> Set<KeyCode> = { t in bad.isSubset(of: t) ? t.subtracting([dropped]) : t }
        pressCombo(s, registers)
        var n = 0
        while s.currentCombo != nil, n < 100 { pressCombo(s, registers); n += 1 }
        let fails = s.combos.filter { $0.outcome == .fail }.map(\.keys)
        #expect(fails.contains(bad))
        // The smallest failing combination found is `bad`: its 3-key subsets were tested and passed.
        #expect(s.combos.contains { $0.keys.count == 3 && $0.keys.contains(dropped) && $0.outcome == .pass })
        #expect(!fails.contains { $0.isStrictSubset(of: bad) })
        // Nothing asked after the failure contained `bad`, except the first chord itself.
        #expect(s.combos.filter { bad.isSubset(of: $0.keys) }.count <= 2)
        let text = MatrixScanReport.serialize(model: s.model, combos: s.combos, layout: layout, hardware: "T", data: defaults)
        #expect(text.contains("combos the grid model got wrong"))
    }

    @Test("Back and forward through sweeps and combinations")
    func backForward() {
        var rng = SplitMix(state: 23)
        let sim = SimulatedMatrix(keys: codes, rows: 8, cols: 16, using: &rng)
        let s = MatrixScanSession(layout: layout, candidates: MatrixScanSession.candidateChords(defaults),
                                  preferred: [KeyPair(code("J"), code("M"))], canHold: { _, _ in true })
        func doSweep() { userRound(s, sim) }
        doSweep(); doSweep()
        #expect(s.sweeps.count == 2)
        let second = s.sweeps[1]
        s.back()
        #expect(s.sweeps.count == 1 && s.pair == second.pair && s.canGoForward)
        s.forward()
        #expect(s.sweeps.count == 2 && s.sweeps[1] == second)
        // Back in the middle of a sweep restarts it.
        let p = s.pair!
        s.keyDown(p.a); s.keyDown(p.b)
        s.keyDown(s.order[0]); s.keyUp(s.order[0])
        s.back()
        #expect(s.status.isEmpty && s.sweeps.count == 2)
        s.keyUp(p.a); s.keyUp(p.b)

        s.enterCombos()
        let t0 = s.currentCombo!
        pressCombo(s) { $0.subtracting([$0.sorted()[0]]) }             // mistyped: one key forgotten
        #expect(s.combos.first?.outcome == .fail)
        s.back()
        #expect(s.currentCombo == t0)
        pressCombo(s) { $0 }
        #expect(s.combos.first { $0.keys == t0 }?.outcome == .pass)
        #expect(s.combos.filter { $0.keys == t0 }.count == 1)
    }
}
