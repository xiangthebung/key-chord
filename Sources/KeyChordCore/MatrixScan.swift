// Matrix_Scan session and report. The macOS window feeds raw key events to the session and renders it.
//
// Stage 1, sweeps (3-key combinations): hold the suggested pair, tap every outlined key once, release the
// pair. Keys that did not register are asked for again in a short second pass, so a key the user simply
// missed is not recorded as blocked. Keys missing in both passes are the blocked ones. Each tapped key
// tests one 3-key combination, and the grid model predicts every larger combination from them.
//
// Stage 2, combination check (4, 5 and 6 keys): real layout chords that the model predicts to work are
// pressed together. Chords containing a known-bad 3-key combination, or a combination that failed here,
// are never asked for. An unexpected failure is narrowed down by testing its sub-combinations.

/// A tested 4-6 key combination.
public struct MatrixCombo: Equatable, Sendable {
    public enum Outcome: String, Sendable { case pass, fail }
    public var keys: Set<KeyCode>
    public var outcome: Outcome
    /// Target keys that were never held together with the others.
    public var missing: Set<KeyCode>
    public init(keys: Set<KeyCode>, outcome: Outcome, missing: Set<KeyCode> = []) {
        self.keys = keys
        self.outcome = outcome
        self.missing = missing
    }
}

public final class MatrixScanSession {
    public enum Stage: Equatable, Sendable { case sweeps, combos }

    public enum Phase: Equatable, Sendable {
        /// No pair selected (the planner has nothing left to suggest).
        case idle
        /// Waiting for exactly the pair to be held.
        case hold
        /// The pair is held (or was, and one of its keys was lifted): taps are being recorded.
        case tapping
    }

    /// What a tapped key did while the pair was held.
    public enum TapStatus: Equatable, Sendable { case registered, missed }

    /// Combinations of each size (4, 5, 6) asked for in the combination check, not counting narrowing tests.
    public static let combosPerSize = 8
    /// When this few keys are left, the window explains how to finish if they all stay dark.
    public static let skipWindow = 3

    public let layout: Layout
    /// Scan keys in Layout order: every key of the Layout.
    public let keys: [KeyCode]
    public private(set) var model: MatrixModel
    public private(set) var stage: Stage = .sweeps
    public private(set) var phase: Phase = .idle
    public private(set) var pair: KeyPair?
    /// Keys to tap in this sweep, in the order they are asked for.
    public private(set) var order: [KeyCode] = []
    /// Result of each key tapped so far in this sweep.
    public private(set) var status: [KeyCode: TapStatus] = [:]
    /// Set while re-checking the dark keys of a sweep that did not fit the others.
    public private(set) var rechecking: MatrixSweep?
    /// Scan keys physically registered as held right now.
    public private(set) var down = Set<KeyCode>()
    public private(set) var skipped = Set<KeyPair>()
    /// Short status for the window.
    public private(set) var message = ""
    /// Saved sweeps dropped on load because no tapped key registered (the pair was released without tapping).
    public let droppedOnLoad: Int
    /// Sweeps taken back with Back, most recent last; Forward puts them back.
    private var redo: [MatrixSweep] = []

    // Combination check.
    public private(set) var comboTargets: [Set<KeyCode>] = []
    public private(set) var comboSlots: [MatrixCombo?] = []
    public private(set) var comboIndex = 0
    /// Most target keys registered as held at the same moment during the current attempt.
    public private(set) var comboPeak = Set<KeyCode>()
    private var comboExtra = false
    private var comboTouched = false
    private let candidates: [Set<KeyCode>]

    private let canHold: (KeyCode, KeyCode) -> Bool
    private let preferred: [KeyPair]
    private let rank: [KeyCode: Int]

    /// - `tapOrder`: keys in the order they are asked for (for example row by row, left to right).
    public init(layout: Layout, sweeps: [MatrixSweep] = [], combos: [MatrixCombo] = [],
                candidates: [Set<KeyCode>] = [], preferred: [KeyPair] = [], tapOrder: [KeyCode] = [],
                canHold: @escaping (KeyCode, KeyCode) -> Bool) {
        self.layout = layout
        keys = layout.keys.map(\.code)
        self.canHold = canHold
        self.preferred = preferred
        self.candidates = candidates
        var r: [KeyCode: Int] = [:]
        for (i, k) in (tapOrder + keys).enumerated() where r[k] == nil { r[k] = i }
        rank = r
        let usable = sweeps.filter { !Self.nothingRegistered($0, keyCount: layout.keys.count) }
        droppedOnLoad = sweeps.count - usable.count
        model = MatrixModel(keys: keys, sweeps: usable)
        comboTargets = combos.map(\.keys)
        comboSlots = combos
        suggestNext()
    }

    /// A sweep in which no tapped key registered: the keys were not tapped, so it says nothing.
    public static func nothingRegistered(_ s: MatrixSweep, keyCount: Int) -> Bool {
        let tapped = s.tapped?.count ?? (keyCount - 2)
        return tapped > 0 && s.blocked.count >= tapped
    }

    public func name(_ code: KeyCode) -> String {
        layout.indexByCode[code].map { layout.keys[$0].name } ?? "Key\(code)"
    }

    public var sweeps: [MatrixSweep] { model.sweeps }
    public var combos: [MatrixCombo] { comboSlots.compactMap { $0 } }

    // MARK: Current sweep

    /// Keys of the sweep not tapped yet, in order.
    public var unresolved: [KeyCode] { order.filter { status[$0] == nil } }
    /// The last key of the round is known to register: tapping it finishes the round.
    public var endsOnKnownKey: Bool {
        guard let p = pair, let last = order.last else { return false }
        return rechecking != nil || model.tripleBlocked(p.a, p.b, last) == false
    }
    /// The key to tap next.
    public var current: KeyCode? { order.first { status[$0] == nil } }
    public var registeredKeys: Set<KeyCode> { Set(status.filter { $0.value == .registered }.keys) }
    public var missedKeys: Set<KeyCode> { Set(status.filter { $0.value == .missed }.keys) }
    /// A key that registered in this sweep: tapping it again after the last keys marks those as blocked.
    public var finishKey: KeyCode? { order.first { status[$0] == .registered } }
    /// The last few keys may all be dark; tapping `finishKey` again then says they were tapped.
    public var canFinishWithKey: Bool {
        let u = unresolved.count
        return u > 0 && u <= Self.skipWindow && finishKey != nil
    }
    /// Every key of the sweep has a result; releasing the pair records it.
    public var sweepComplete: Bool { !order.isEmpty && unresolved.isEmpty }
    /// Total 3-key combinations tested so far.
    public var tripleTests: Int {
        model.sweeps.reduce(0) { $0 + ($1.tapped?.count ?? (keys.count - 2)) }
    }

    // MARK: Pair selection

    /// Picks the planner's next pair and waits for it to be held.
    public func suggestNext() {
        let p = MatrixPlanner.nextPair(model: model, skipped: skipped, preferred: preferred, canHold: canHold)
        select(p)
        if p == nil { message = model.unknownPairs == 0 ? "The 3-key map is complete." : "No holdable pair can teach anything new." }
    }

    /// Holds a specific pair next (for example a pair requested in the chat).
    public func choose(_ a: KeyCode, _ b: KeyCode) {
        guard a != b, model.index[a] != nil, model.index[b] != nil else { return }
        stage = .sweeps
        select(KeyPair(a, b))
    }

    /// The suggested pair is awkward to hold: never suggest it again.
    public func skipPair() {
        if let pair { skipped.insert(pair) }
        suggestNext()
    }

    /// Starts the current sweep again from its first key.
    public func restartSweep() {
        status.removeAll()
        if case .tapping = phase { phase = .hold }
        if let p = pair, down == [p.a, p.b] { phase = .tapping }
    }

    public func resetAll() {
        model = MatrixModel(keys: keys)
        skipped.removeAll()
        redo.removeAll()
        comboTargets = []
        comboSlots = []
        comboIndex = 0
        stage = .sweeps
        suggestNext()
    }

    private func sorted(_ s: Set<KeyCode>) -> [KeyCode] {
        s.sorted { (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1) }
    }

    private func select(_ p: KeyPair?) {
        pair = p
        status.removeAll()
        rechecking = nil
        guard let p else { phase = .idle; order = []; return }
        // Only keys whose result is not predictable yet; all of them if the pair teaches nothing new.
        let useful = model.usefulTaps(p)
        order = sorted(useful.isEmpty ? Set(keys).subtracting([p.a, p.b]) : useful)
        // End on a key known to register with this pair, so the round finishes even if the last keys are dark.
        if let end = sorted(Set(keys).subtracting(order).subtracting([p.a, p.b])
            .filter { model.tripleBlocked(p.a, p.b, $0) == false }).last {
            order.append(end)
        }
        phase = down == [p.a, p.b] ? .tapping : .hold
        message = ""
    }

    /// Asks again for the dark keys of `sweep`, starting with one that registered (so the check can end).
    private func startRecheck(_ sweep: MatrixSweep) {
        let tapped = sweep.tapped ?? Set(keys).subtracting([sweep.pair.a, sweep.pair.b])
        guard let anchor = sorted(tapped.subtracting(sweep.blocked)).first else { return }
        pair = sweep.pair
        rechecking = sweep
        status.removeAll()
        order = sorted(sweep.blocked) + [anchor]
        phase = down == [sweep.pair.a, sweep.pair.b] ? .tapping : .hold
    }

    private var sweepInProgress: Bool { !status.isEmpty || rechecking != nil }

    // MARK: Back and forward

    public var canGoBack: Bool {
        switch stage {
        case .sweeps: return sweepInProgress || !model.sweeps.isEmpty
        case .combos: return true
        }
    }

    public var canGoForward: Bool {
        switch stage {
        case .sweeps: return !redo.isEmpty && !sweepInProgress
        case .combos: return comboIndex < comboTargets.count
        }
    }

    /// Undo the last step: the sweep in progress, else the last recorded sweep or combination.
    public func back() {
        switch stage {
        case .sweeps:
            if sweepInProgress {
                if rechecking != nil { select(pair) } else { restartSweep() }
                message = "Sweep restarted."
                return
            }
            guard let last = model.sweeps.last else { return }
            redo.append(last)
            model = MatrixModel(keys: keys, sweeps: Array(model.sweeps.dropLast()))
            select(last.pair)
            message = "Back to \(name(last.pair.a)) + \(name(last.pair.b)). Redo it, or press Forward to keep the old result."
        case .combos:
            if comboTouched {
                resetAttempt()
                message = "Attempt discarded."
                return
            }
            if let i = (0..<comboIndex).last(where: { !isPruned($0) }) {
                comboIndex = i
                message = comboSlots[i] == nil ? "" : "Press it again to replace the earlier result, or Forward to keep it."
            } else {
                returnToSweeps()
            }
        }
    }

    /// Redo a sweep taken back, or move to the next combination keeping the current one's result.
    public func forward() {
        switch stage {
        case .sweeps:
            guard !sweepInProgress, let s = redo.popLast() else { return }
            model.add(s)
            suggestNext()
            message = "Kept \(name(s.pair.a)) + \(name(s.pair.b))."
        case .combos:
            guard comboIndex < comboTargets.count else { return }
            resetAttempt()
            advance()
        }
    }

    // MARK: Stages

    /// Starts (or resumes) the 4-6 key combination check.
    public func enterCombos() {
        stage = .combos
        resetAttempt()
        let failed = combos.filter { $0.outcome == .fail }.map(\.keys)
        let picks = Self.pickCombos(model: model, candidates: candidates, existing: comboTargets, failed: failed,
                                    perSize: Self.combosPerSize)
        comboTargets += picks
        comboSlots += Array(repeating: nil, count: picks.count)
        comboIndex = comboSlots.firstIndex(where: { $0 == nil }) ?? comboTargets.count
        while comboIndex < comboTargets.count && isPruned(comboIndex) { comboIndex += 1 }
        message = comboTargets.isEmpty ? "No 4-6 key layout chords to check." : ""
    }

    public func returnToSweeps() {
        stage = .sweeps
        resetAttempt()
        if pair == nil || order.isEmpty { suggestNext() }
    }

    public var currentCombo: Set<KeyCode>? {
        stage == .combos && comboIndex < comboTargets.count ? comboTargets[comboIndex] : nil
    }

    /// Untested combinations that contain one that failed: they would fail too, so they are skipped.
    public func isPruned(_ i: Int) -> Bool {
        guard comboSlots[i] == nil else { return false }
        let t = comboTargets[i]
        return comboSlots.contains { c in c?.outcome == .fail && c!.keys.isStrictSubset(of: t) }
            || model.chordBlocked(Array(t)) == true
    }

    public var remainingCombos: Int {
        (comboIndex..<comboTargets.count).filter { comboSlots[$0] == nil && !isPruned($0) }.count
    }

    private func advance() {
        comboIndex += 1
        while comboIndex < comboTargets.count && isPruned(comboIndex) { comboIndex += 1 }
    }

    private func resetAttempt() {
        comboPeak.removeAll()
        comboExtra = false
        comboTouched = false
    }

    /// Key events stopped arriving (the window lost focus): forget held keys; the sweep continues when the
    /// pair is held again.
    public func interrupt() {
        down.removeAll()
        resetAttempt()
        if case .tapping = phase { phase = .hold }
    }

    // MARK: Raw events

    public func keyDown(_ code: KeyCode) {
        guard model.index[code] != nil else { return }
        down.insert(code)
        if stage == .combos {
            guard let t = currentCombo else { return }
            comboTouched = true
            if !t.contains(code) { comboExtra = true }
            let now = down.intersection(t)
            if now.count > comboPeak.count { comboPeak = now }
            return
        }
        guard let p = pair else { return }
        switch phase {
        case .hold:
            if down == [p.a, p.b] { phase = .tapping }
        case .tapping:
            // A tap only counts while both keys of the pair are held.
            if code != p.a && code != p.b && down.contains(p.a) && down.contains(p.b) { tap(code) }
        case .idle:
            break
        }
    }

    private func tap(_ code: KeyCode) {
        guard order.contains(code) else { return }
        switch status[code] {
        case .missed?:
            status[code] = .registered
            message = "\(name(code)) registered after all."
        case .registered?:
            if canFinishWithKey {
                for k in unresolved { status[k] = .missed }
            }
        case nil:
            let u = unresolved
            if let i = u.firstIndex(of: code) {
                // Keys passed over were tapped and stayed dark. A red key tapped again turns green.
                for k in u[..<i] { status[k] = .missed }
            }
            status[code] = .registered
            message = ""
        }
    }

    public func keyUp(_ code: KeyCode) {
        guard model.index[code] != nil else { return }
        down.remove(code)
        if stage == .combos {
            if down.isEmpty && comboTouched { endCombo() }
            return
        }
        guard let p = pair else { return }
        switch phase {
        case .hold:
            // Another key was released and now exactly the pair is held.
            if down == [p.a, p.b] { phase = .tapping }
        case .tapping:
            if !down.contains(p.a) && !down.contains(p.b) { released(p) }
        case .idle:
            break
        }
    }

    private func released(_ p: KeyPair) {
        phase = .hold
        let pairText = "\(name(p.a)) + \(name(p.b))"
        if registeredKeys.isEmpty {
            status.removeAll()
            message = "Nothing registered. Hold \(pairText) and, while holding, tap the highlighted key with your other hand."
            return
        }
        guard sweepComplete else {
            message = "Paused: \(unresolved.count) keys to go. Hold \(pairText) again to carry on."
            return
        }
        finish(p)
    }

    private func finish(_ p: KeyPair) {
        let pairText = "\(name(p.a)) + \(name(p.b))"
        let dark = missedKeys
        if let old = rechecking {
            // Keys that registered now were missed taps the first time.
            let sweep = MatrixSweep(pair: p, blocked: old.blocked.intersection(dark), tapped: old.tapped)
            let ok = model.add(sweep)
            redo.removeAll()
            suggestNext()
            message = ok ? "\(pairText): fixed, \(sweep.blocked.count) blocked."
                : "\(pairText) still doesn't fit the other results, so it's left out of the map. Back takes it away."
            afterSweep()
            return
        }
        let all = order.count == keys.count - 2
        let sweep = MatrixSweep(pair: p, blocked: dark, tapped: all ? nil : Set(order))
        if model.add(sweep) {
            redo.removeAll()
            suggestNext()
            message = "\(pairText): \(order.count) tested, " + (dark.isEmpty ? "nothing blocked." : "\(dark.count) blocked.")
            afterSweep()
        } else if !dark.isEmpty {
            // Most likely a key was passed over by accident: ask for just the dark ones again.
            model.dropLastSweep()
            startRecheck(sweep)
            message = "That doesn't fit the other results. Hold \(pairText) again and tap just the \(dark.count) keys that stayed dark."
        } else {
            redo.removeAll()
            suggestNext()
            message = "\(pairText) doesn't fit the other results, so it's left out of the map. Back takes it away."
            afterSweep()
        }
    }

    private func afterSweep() {
        if pair == nil && model.unknownPairs == 0 {
            enterCombos()
            message += " The 3-key map is complete; now a few 4-6 key chords."
        }
    }

    private func endCombo() {
        guard let t = currentCombo else { return }
        defer { resetAttempt() }
        if comboExtra {
            message = "Other keys were pressed too. Press only the outlined keys."
            return
        }
        let missing = t.subtracting(comboPeak)
        let result = MatrixCombo(keys: t, outcome: missing.isEmpty ? .pass : .fail, missing: missing)
        let predicted = model.chordBlocked(Array(t))
        comboSlots[comboIndex] = result
        let label = t.sorted { (model.index[$0] ?? 0) < (model.index[$1] ?? 0) }.map(name).joined(separator: "+")
        if result.outcome == .pass {
            message = "✓ \(label) registered."
        } else {
            message = "✗ \(label): " + missing.sorted().map(name).joined(separator: ", ") + " did not register."
            if predicted != true && t.count > 3 {
                // Unexpected: narrow it down with the sub-combinations that still contain a missing key.
                var subs: [Set<KeyCode>] = []
                for k in t.sorted() where !(missing.count == 1 && missing.contains(k)) {
                    let sub = t.subtracting([k])
                    if !comboTargets.contains(sub) { subs.append(sub) }
                }
                comboTargets.insert(contentsOf: subs, at: comboIndex + 1)
                comboSlots.insert(contentsOf: Array(repeating: nil, count: subs.count), at: comboIndex + 1)
                if !subs.isEmpty { message += " The grid model expected it to work; \(subs.count) smaller combinations follow to narrow it down." }
            }
        }
        advance()
        if comboIndex >= comboTargets.count { message += " Combination check finished: copy the report." }
    }

    // MARK: Picking combinations

    /// Layout chords with 4 to 6 keys: syllable compositions, fingerspelling and dictionary chords.
    public static func candidateChords(_ data: EngineData) -> [Set<KeyCode>] {
        let l = data.layout
        var seen = Set<KeySet>()
        func add(_ k: KeySet) { if (4...6).contains(k.count) { seen.insert(k) } }
        func options(_ b: Bank) -> [KeySet] { [KeySet()] + (l.clusters[b] ?? [:]).keys }
        for o in options(.onset) { for v in options(.vowel) { for c in options(.coda) { add(o.union(v).union(c)) } } }
        for (k, _) in l.fingerspelling {
            var c = k
            if let s = l.spellIndex { c.insert(s) }
            add(c)
        }
        for d in [data.shared, data.english, data.cpp] { for k in d.entries.keys { add(k) } }
        return seen.sorted { $0.bits < $1.bits }.map { Set($0.indices.map { l.keys[$0].code }) }
    }

    /// Greedy choice of combinations the model does not rule out, covering as many different key pairs as
    /// possible, `perSize` for each size (counting those already in `existing`).
    static func pickCombos(model: MatrixModel, candidates: [Set<KeyCode>], existing: [Set<KeyCode>],
                           failed: [Set<KeyCode>], perSize: Int) -> [Set<KeyCode>] {
        var covered = Set<KeyPair>()
        func pairs(_ s: Set<KeyCode>) -> [KeyPair] {
            let a = s.sorted()
            var out: [KeyPair] = []
            for i in 0..<a.count { for j in (i + 1)..<a.count { out.append(KeyPair(a[i], a[j])) } }
            return out
        }
        for e in existing { covered.formUnion(pairs(e)) }
        let taken = Set(existing)
        var picks: [Set<KeyCode>] = []
        for size in 4...6 {
            var need = perSize - existing.filter { $0.count == size }.count
            var pool = candidates.filter { c in
                c.count == size && !taken.contains(c) && !failed.contains { $0.isSubset(of: c) }
                    && model.chordBlocked(Array(c)) != true
            }.map { ($0, pairs($0)) }
            while need > 0, !pool.isEmpty {
                var best = 0, bestGain = -1
                for (i, c) in pool.enumerated() {
                    let gain = c.1.reduce(0) { $0 + (covered.contains($1) ? 0 : 1) }
                    if gain > bestGain { best = i; bestGain = gain }
                }
                let (c, ps) = pool.remove(at: best)
                picks.append(c)
                covered.formUnion(ps)
                need -= 1
            }
        }
        return picks
    }
}

// MARK: - Report

public enum MatrixScanReport {
    public enum ParseError: Error, Equatable { case malformed(line: Int), unknownKey(String, line: Int) }

    /// Text for the chat: the raw results (reloadable) followed by the analysis as comments.
    public static func serialize(model: MatrixModel, combos: [MatrixCombo] = [], layout: Layout, hardware: String,
                                 data: EngineData? = nil, wiring: KeyboardWiring? = nil) -> String {
        func name(_ c: KeyCode) -> String { layout.indexByCode[c].map { layout.keys[$0].name } ?? "Key\(c)" }
        func ordered(_ s: Set<KeyCode>) -> [KeyCode] { model.keys.filter { s.contains($0) } }
        var s = "# KeyChord Matrix Scan\n"
        s += "# sweep A+B blocked <keys> [untested <keys> | tapped <keys>]: A and B held; every other key was tapped,\n"
        s += "# except the untested ones (or only the tapped ones). Blocked keys never registered.\n"
        s += "# combo <keys> pass|fail [missing <keys>]: the keys pressed together.\n"
        s += "version 1\nhardware \(hardware)\n"
        s += "keys " + model.keys.map(name).joined(separator: " ") + "\n"
        for (i, sw) in model.sweeps.enumerated() {
            let blocked = ordered(sw.blocked).map(name)
            s += "sweep \(name(sw.pair.a))+\(name(sw.pair.b)) blocked " + (blocked.isEmpty ? "-" : blocked.joined(separator: " "))
            if let tapped = sw.tapped {
                // Whichever list is shorter.
                let untested = model.keys.filter { $0 != sw.pair.a && $0 != sw.pair.b && !tapped.contains($0) }.map(name)
                let only = ordered(tapped).map(name)
                if only.count < untested.count {
                    s += " tapped " + only.joined(separator: " ")
                } else if !untested.isEmpty {
                    s += " untested " + untested.joined(separator: " ")
                }
            }
            s += model.inconsistent.contains(i) ? "   # contradicts earlier sweeps, not used\n" : "\n"
        }
        for c in combos {
            s += "combo " + ordered(c.keys).map(name).joined(separator: "+") + " \(c.outcome.rawValue)"
            if !c.missing.isEmpty { s += " missing " + ordered(c.missing).map(name).joined(separator: " ") }
            s += "\n"
        }
        s += "# --- analysis ---\n"
        s += "# sweeps \(model.sweeps.count), left out \(model.inconsistent.count); "
        s += "3-key combinations known: \(model.totalPairs - model.unknownPairs) of \(model.totalPairs) key pairs\n"
        if let wiring {
            let fit = wiring.fit(sweeps: model.sweeps, combos: combos, layout: layout)
            s += "# wiring file (\(wiring.hardware)) explains \(fit.explained) of \(fit.total) observations\n"
            for m in fit.mismatches.prefix(30) { s += "#   " + m + "\n" }
            s += "# rule: three keys in an L are dropped only when the fourth corner of the rectangle holds a key\n"
            s += wiring.table(layout: layout).split(separator: "\n").map { "#   " + $0 }.joined(separator: "\n") + "\n"
        } else {
            s += Self.wiring(model: model, name: name)
        }
        let partial = model.keys.filter { model.unknownCount($0) > 0 }
        if !partial.isEmpty {
            s += "# not fully known: " + partial.map { "\(name($0))(\(model.unknownCount($0)))" }.joined(separator: " ") + "\n"
        }
        s += comboSummary(model: model, combos: combos, name: name, ordered: ordered)
        if let data { s += blockedChords(model: model, data: data, wiring: wiring) }
        return s
    }

    /// The inferred wiring as a grid: each key sits where its A line (table row) crosses its B line (column).
    static func wiring(model: MatrixModel, name: (KeyCode) -> String) -> String {
        let lines = model.lines()
        var out = "# wiring: keys in the same table row, or in the same column, share an electrical line.\n"
        out += "# Three keys block when two of them share a row and one of those shares a column with the third (an L).\n"
        out += "# A and B are the two line directions; which one is the physical row can't be observed.\n"
        if lines.conflict { out += "# WARNING: the known lines do not fit a grid, so the keyboard is not a plain matrix.\n" }
        var rowOf: [KeyCode: Int] = [:], colOf: [KeyCode: Int] = [:]
        for (i, l) in lines.a.enumerated() { for k in l { rowOf[k] = i } }
        for (j, l) in lines.b.enumerated() { for k in l { colOf[k] = j } }
        // Keys alone on a line get a row or column of their own.
        var rows = lines.a.count, cols = lines.b.count
        let known = model.keys.filter { model.unknownCount($0) == 0 || rowOf[$0] != nil || colOf[$0] != nil }
        for k in known where rowOf[k] == nil { rowOf[k] = rows; rows += 1 }
        for k in known where colOf[k] == nil { colOf[k] = cols; cols += 1 }
        guard rows > 0, cols > 0 else { return out }
        var cell = Array(repeating: Array(repeating: "", count: cols), count: rows)
        for k in known {
            let r = rowOf[k]!, c = colOf[k]!
            cell[r][c] = cell[r][c].isEmpty ? name(k) : cell[r][c] + "/" + name(k)
        }
        let width = max(3, cell.flatMap { $0 }.map(\.count).max() ?? 3)
        func pad(_ t: String) -> String { t + String(repeating: " ", count: width - t.count) }
        out += "#      " + (0..<cols).map { pad("B\($0 + 1)") }.joined(separator: " ") + "\n"
        for r in 0..<rows {
            let label = "A\(r + 1)"
            out += "# " + label + String(repeating: " ", count: max(1, 5 - label.count))
                + cell[r].map { pad($0.isEmpty ? "." : $0) }.joined(separator: " ") + "\n"
        }
        return out
    }

    static func comboSummary(model: MatrixModel, combos: [MatrixCombo], name: (KeyCode) -> String,
                             ordered: (Set<KeyCode>) -> [KeyCode]) -> String {
        guard !combos.isEmpty else { return "# 4-6 key check: not run\n" }
        var out = ""
        for size in 3...6 {
            let c = combos.filter { $0.keys.count == size }
            guard !c.isEmpty else { continue }
            out += "# \(size)-key combos: \(c.filter { $0.outcome == .pass }.count) of \(c.count) passed\n"
        }
        let surprises = combos.filter { c in
            let predicted = model.chordBlocked(Array(c.keys))
            return predicted != nil && predicted! != (c.outcome == .fail)
        }
        if surprises.isEmpty {
            out += "# every combo matched the grid model's prediction\n"
        } else {
            out += "# combos the grid model got wrong (\(surprises.count)):\n"
            for c in surprises {
                out += "#   " + ordered(c.keys).map(name).joined(separator: "+") + " \(c.outcome.rawValue)"
                    + (c.missing.isEmpty ? "" : ", missing " + ordered(c.missing).map(name).joined(separator: " ")) + "\n"
            }
            // Smallest failing sets: failures with no failing sub-combination.
            let fails = combos.filter { $0.outcome == .fail }.map(\.keys)
            let minimal = fails.filter { f in !fails.contains { $0.isStrictSubset(of: f) } }
            out += "#   smallest failing combos: " + minimal.map { ordered($0).map(name).joined(separator: "+") }.joined(separator: "  ") + "\n"
        }
        return out
    }

    /// Layout and dictionary chords that contain a blocked triple.
    static func blockedChords(model: MatrixModel, data: EngineData, limit: Int = 60, wiring: KeyboardWiring? = nil) -> String {
        let l = data.layout
        var groups: [(String, [(KeySet, String)])] = []
        for bank in Bank.allCases {
            groups.append(("\(bank.rawValue) clusters", (l.clusters[bank] ?? [:]).map { ($0.key, $0.value) }))
        }
        groups.append(("fingerspelling", l.fingerspelling.map { k, v in
            var c = k
            if let s = l.spellIndex { c.insert(s) }
            return (c, v)
        }))
        for (label, d) in [("shared", data.shared), ("english", data.english), ("c++", data.cpp)] {
            groups.append(("\(label) dictionary", d.entries.map { k, e in
                switch e {
                case .text(let t): return (k, t.text)
                case .command(let c): return (k, "{\(c)}")
                }
            }))
        }
        var out = ""
        var shown = 0
        for (label, items) in groups {
            var blocked: [(KeySet, String)] = []
            var unknown = 0
            for (k, text) in items where k.count >= 3 {
                let codes = k.indices.map { l.keys[$0].code }
                switch wiring.map({ $0.blocks(codes) }) ?? model.chordBlocked(codes) {
                case true?: blocked.append((k, text))
                case nil: unknown += 1
                default: break
                }
            }
            blocked.sort { $0.0.bits < $1.0.bits }
            out += "# \(label): \(blocked.count) blocked" + (unknown > 0 ? ", \(unknown) unknown" : "") + "\n"
            for (k, text) in blocked where shown < limit {
                out += "#   \(l.chordString(k)) \"\(text)\"\n"
                shown += 1
            }
        }
        if shown >= limit { out += "#   (list truncated at \(limit))\n" }
        out += syllableSummary(model: model, layout: l, wiring: wiring)
        return out
    }

    /// Syllable_Composition chords (onset + vowel + coda clusters) that contain a blocked triple, and the
    /// key triples responsible for most of them.
    static func syllableSummary(model: MatrixModel, layout l: Layout, top: Int = 15, wiring: KeyboardWiring? = nil) -> String {
        func options(_ b: Bank) -> [KeySet] { [KeySet()] + (l.clusters[b] ?? [:]).keys.sorted { $0.bits < $1.bits } }
        let code = l.keys.map(\.code)
        var total = 0, blocked = 0, unknown = 0
        var culprits: [[Int]: Int] = [:]
        for o in options(.onset) {
            for v in options(.vowel) {
                for c in options(.coda) {
                    let k = o.union(v).union(c).indices
                    guard k.count >= 3 else { continue }
                    total += 1
                    var isBlocked = false, isUnknown = false
                    for i in 0..<k.count {
                        for j in (i + 1)..<k.count {
                            for m in (j + 1)..<k.count {
                                let a = code[k[i]], b = code[k[j]], c = code[k[m]]
                                switch wiring.map({ $0.tripleBlocked(a, b, c) }) ?? model.tripleBlocked(a, b, c) {
                                case true?:
                                    isBlocked = true
                                    culprits[[k[i], k[j], k[m]], default: 0] += 1
                                case nil: isUnknown = true
                                default: break
                                }
                            }
                        }
                    }
                    if isBlocked { blocked += 1 } else if isUnknown { unknown += 1 }
                }
            }
        }
        var out = "# syllables (onset+vowel+coda, 3+ keys): \(blocked) of \(total) blocked"
            + (unknown > 0 ? ", \(unknown) unknown" : "") + "\n"
        let worst = culprits.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key) }
        if !worst.isEmpty {
            out += "#   triples blocking the most syllables: "
                + worst.prefix(top).map { "\($0.key.map { l.keys[$0].name }.joined(separator: "+"))(\($0.value))" }.joined(separator: " ")
                + "\n"
        }
        return out
    }

    /// Reads the results back. Returns nil when the file was made with a different key list.
    public static func parse(_ text: String, layout: Layout) throws -> (sweeps: [MatrixSweep], combos: [MatrixCombo])? {
        var sweeps: [MatrixSweep] = []
        var combos: [MatrixCombo] = []
        let expectedKeys = layout.keys.map(\.name)
        for (n, rawLine) in Lex.lines(text) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let head = f.first else { continue }
            func code(_ s: String) throws -> KeyCode {
                guard let i = layout.indexByName[s] else { throw ParseError.unknownKey(s, line: n) }
                return layout.keys[i].code
            }
            switch head {
            case "version":
                guard f.count == 2, f[1] == "1" else { throw ParseError.malformed(line: n) }
            case "hardware":
                break
            case "keys":
                if Array(f.dropFirst()) != expectedKeys { return nil }
            case "sweep":
                guard f.count >= 4, f[2] == "blocked" else { throw ParseError.malformed(line: n) }
                let pairNames = f[1].split(separator: "+").map(String.init)
                guard pairNames.count == 2 else { throw ParseError.malformed(line: n) }
                let a = try code(pairNames[0]), b = try code(pairNames[1])
                let rest = Array(f.dropFirst(3))
                let split = rest.firstIndex { $0 == "untested" || $0 == "tapped" } ?? rest.count
                let blockedNames = Array(rest[..<split])
                let blocked = blockedNames == ["-"] ? [] : try blockedNames.map(code)
                var tapped: Set<KeyCode>?
                if split < rest.count {
                    let listed = Set(try rest[(split + 1)...].map(code))
                    tapped = rest[split] == "tapped" ? listed
                        : Set(layout.keys.map(\.code)).subtracting(listed).subtracting([a, b])
                }
                sweeps.append(MatrixSweep(pair: KeyPair(a, b), blocked: Set(blocked), tapped: tapped))
            case "combo":
                guard f.count >= 3, let outcome = MatrixCombo.Outcome(rawValue: f[2]) else { throw ParseError.malformed(line: n) }
                let k = Set(try f[1].split(separator: "+").map { try code(String($0)) })
                var missing = Set<KeyCode>()
                if f.count > 3 {
                    guard f[3] == "missing" else { throw ParseError.malformed(line: n) }
                    missing = Set(try f[4...].map(code))
                }
                combos.append(MatrixCombo(keys: k, outcome: outcome, missing: missing))
            default:
                throw ParseError.malformed(line: n)
            }
        }
        return (sweeps, combos)
    }
}

// MARK: - Keyboard limits

/// What the Matrix Scan found, as a thread-safe snapshot: chords the keyboard is known to block are those
/// with a blocked 3-key combination, or containing a 4-6 key combination that failed.
public struct KeyboardLimits: Sendable {
    let shares: [KeyPair: Bool]
    let failed: [Set<KeyCode>]
    /// The keyboard's wiring. When known, it decides which chords are blocked instead of the scan's
    /// inferred lines (which assume every L blocks, and that is not how this keyboard behaves).
    public private(set) var wiring: KeyboardWiring?

    public init(wiring: KeyboardWiring, combos: [MatrixCombo] = []) {
        shares = [:]
        let fails = combos.filter { $0.outcome == .fail }.map(\.keys)
        failed = fails.filter { f in !fails.contains { $0.isStrictSubset(of: f) } }
        self.wiring = wiring
    }

    /// The wiring file if there is one (plus any failed combinations from the scan), else the scan alone.
    public init?(wiringText: String?, scanText: String?, layout: Layout) {
        let combos = scanText.flatMap { try? MatrixScanReport.parse($0, layout: layout) }?.combos ?? []
        if let wiringText, let w = try? KeyboardWiring.parse(wiringText, layout: layout) {
            self.init(wiring: w, combos: combos)
        } else {
            self.init(scanText: scanText, layout: layout)
        }
    }

    public init(model: MatrixModel, combos: [MatrixCombo]) {
        var s: [KeyPair: Bool] = [:]
        for a in model.keys {
            for b in model.keys where a < b {
                if let v = model.shares(a, b) { s[KeyPair(a, b)] = v }
            }
        }
        shares = s
        let fails = combos.filter { $0.outcome == .fail }.map(\.keys)
        failed = fails.filter { f in !fails.contains { $0.isStrictSubset(of: f) } }
    }

    /// Reads a saved scan; nil if there is none or it was made with a different layout.
    public init?(scanText: String?, layout: Layout) {
        guard let scanText, let parsed = try? MatrixScanReport.parse(scanText, layout: layout),
              !parsed.sweeps.isEmpty || !parsed.combos.isEmpty else { return nil }
        let sweeps = parsed.sweeps.filter { !MatrixScanSession.nothingRegistered($0, keyCount: layout.keys.count) }
        self.init(model: MatrixModel(keys: layout.keys.map(\.code), sweeps: sweeps), combos: parsed.combos)
    }

    public var isEmpty: Bool { wiring == nil && !shares.values.contains(true) && failed.isEmpty }

    /// True when the scan shows the keyboard cannot register all these keys at once.
    public func blocks(_ codes: [KeyCode]) -> Bool {
        if codes.count < 3 { return false }
        let set = Set(codes)
        if failed.contains(where: { $0.isSubset(of: set) }) { return true }
        if let wiring { return wiring.blocks(codes) }
        func sh(_ x: KeyCode, _ y: KeyCode) -> Int8 { shares[KeyPair(x, y)].map { $0 ? 1 : 0 } ?? -1 }
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count {
                for k in (j + 1)..<codes.count
                where MatrixModel.tripleBlocked(sh(codes[i], codes[j]), sh(codes[i], codes[k]), sh(codes[j], codes[k])) == true {
                    return true
                }
            }
        }
        return false
    }

    /// Predicate for the TypingPlanner.
    public func usable(in layout: Layout) -> (KeySet) -> Bool {
        let codes = layout.keys.map(\.code)
        return { k in !self.blocks(k.indices.map { codes[$0] }) }
    }
}
