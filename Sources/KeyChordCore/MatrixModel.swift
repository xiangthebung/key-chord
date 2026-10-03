// Keyboard matrix model inferred from Matrix_Scan sweeps.
//
// A laptop keyboard wires its keys in a grid of electrical rows and columns (not the printed rows).
// Two keys "share a line" when they sit on the same electrical row or column. When three held keys
// form an "L" in that grid (one key shares its row with a second key and its column with a third),
// the controller cannot tell the pattern from a phantom fourth key, so it drops the last key pressed.
//
// For any three keys, the combination is blocked exactly when two of the three pairs share a line.
// (Three sharing pairs means all three keys are on one line, which is safe.) A larger chord is safe
// when none of its triples is blocked, so the pairwise "shares a line" relation is all we need.
//
// A sweep holds two keys and taps every other scan key once. The keys that never register are the
// blocked ones, so each tapped key is one triple observation. MatrixModel turns the observations into
// knowledge about which pairs share a line, using the triple rule and the geometry of a grid.

/// An unordered pair of keys.
public struct KeyPair: Hashable, Sendable {
    public let a: KeyCode
    public let b: KeyCode
    public init(_ x: KeyCode, _ y: KeyCode) {
        a = min(x, y)
        b = max(x, y)
    }
}

/// One sweep: `pair` was held while the `tapped` keys (nil: every other scan key) were tapped once each;
/// the `blocked` ones never registered.
public struct MatrixSweep: Equatable, Sendable {
    public var pair: KeyPair
    public var blocked: Set<KeyCode>
    public var tapped: Set<KeyCode>?
    public init(pair: KeyPair, blocked: Set<KeyCode>, tapped: Set<KeyCode>? = nil) {
        self.pair = pair
        self.blocked = blocked
        self.tapped = tapped
    }
}

/// Pairwise "shares a line" knowledge: -1 unknown, 0 no, 1 yes.
struct EdgeState {
    let n: Int
    var e: [Int8]
    var changed = false
    var failed = false

    init(n: Int) {
        self.n = n
        e = Array(repeating: -1, count: n * n)
    }

    @inline(__always) func get(_ i: Int, _ j: Int) -> Int8 { e[i * n + j] }

    @inline(__always) mutating func set(_ i: Int, _ j: Int, _ v: Int8) {
        let k = i * n + j
        let cur = e[k]
        if cur == v { return }
        if cur != -1 { failed = true; return }
        e[k] = v
        e[j * n + i] = v
        changed = true
    }
}

/// One tapped key `x` during a sweep holding `a` and `b` (indices into the model's keys).
struct TripleObservation {
    let a: Int, b: Int, x: Int
    let blocked: Bool
}

public final class MatrixModel {
    public let keys: [KeyCode]
    public let index: [KeyCode: Int]
    var state: EdgeState
    private var observations: [TripleObservation] = []
    /// Number of sweeps each key was held in (hub keys are worth probing).
    private var heldCount: [Int]
    public private(set) var sweeps: [MatrixSweep] = []
    /// Indices into `sweeps` that contradicted earlier sweeps and were left out of the model.
    public private(set) var inconsistent: [Int] = []

    public init(keys: [KeyCode], sweeps: [MatrixSweep] = []) {
        self.keys = keys
        var idx: [KeyCode: Int] = [:]
        for (i, k) in keys.enumerated() { idx[k] = i }
        index = idx
        state = EdgeState(n: keys.count)
        heldCount = Array(repeating: 0, count: keys.count)
        for s in sweeps { add(s) }
    }

    public var keyCount: Int { keys.count }

    /// Adds a sweep and updates the model. Returns false (and leaves it out) if it contradicts earlier sweeps.
    @discardableResult
    public func add(_ sweep: MatrixSweep) -> Bool {
        sweeps.append(sweep)
        guard let a = index[sweep.pair.a], let b = index[sweep.pair.b], a != b else {
            inconsistent.append(sweeps.count - 1)
            return false
        }
        let backup = state, obsCount = observations.count
        for x in 0..<keys.count where x != a && x != b && sweep.tapped?.contains(keys[x]) != false {
            observations.append(TripleObservation(a: a, b: b, x: x, blocked: sweep.blocked.contains(keys[x])))
        }
        // A pair on different lines has at most two keys forming an L with it (the two missing corners
        // of their rectangle), so three or more blocked keys prove the pair shares a line.
        if sweep.blocked.count >= 3 { state.set(a, b, 1) }
        heldCount[a] += 1
        heldCount[b] += 1
        propagate(&state)
        if !state.failed { probe() }
        if state.failed {
            state = backup
            observations.removeSubrange(obsCount...)
            heldCount[a] -= 1
            heldCount[b] -= 1
            inconsistent.append(sweeps.count - 1)
            return false
        }
        return true
    }

    /// Removes the last sweep if it was left out as inconsistent (the model itself never used it).
    public func dropLastSweep() {
        guard let i = inconsistent.last, i == sweeps.count - 1 else { return }
        inconsistent.removeLast()
        sweeps.removeLast()
    }

    // MARK: Queries

    /// Whether the two keys share an electrical line; nil when not known yet.
    public func shares(_ x: KeyCode, _ y: KeyCode) -> Bool? {
        guard let i = index[x], let j = index[y], i != j else { return nil }
        switch state.get(i, j) {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    func edge(_ i: Int, _ j: Int) -> Int8 { state.get(i, j) }

    /// Keys worth tapping while holding the pair: those whose triple with the pair is not known yet.
    public func usefulTaps(_ pair: KeyPair) -> Set<KeyCode> {
        guard let a = index[pair.a], let b = index[pair.b] else { return [] }
        var out = Set<KeyCode>()
        for x in 0..<keys.count where x != a && x != b
            && Self.tripleBlocked(state.get(a, b), state.get(a, x), state.get(b, x)) == nil { out.insert(keys[x]) }
        return out
    }

    /// Number of other keys whose relation to `key` is still unknown.
    public func unknownCount(_ key: KeyCode) -> Int {
        guard let i = index[key] else { return 0 }
        return unknownCount(index: i)
    }

    func unknownCount(index i: Int) -> Int {
        var c = 0
        for j in 0..<keys.count where j != i && state.get(i, j) == -1 { c += 1 }
        return c
    }

    public var totalPairs: Int { keys.count * (keys.count - 1) / 2 }

    public var unknownPairs: Int {
        var c = 0
        for i in 0..<keys.count { for j in (i + 1)..<keys.count where state.get(i, j) == -1 { c += 1 } }
        return c
    }

    /// Whether pressing the three keys together is blocked; nil when it depends on unknown pairs.
    public func tripleBlocked(_ x: KeyCode, _ y: KeyCode, _ z: KeyCode) -> Bool? {
        guard let i = index[x], let j = index[y], let k = index[z] else { return nil }
        return Self.tripleBlocked(state.get(i, j), state.get(i, k), state.get(j, k))
    }

    static func tripleBlocked(_ u: Int8, _ v: Int8, _ w: Int8) -> Bool? {
        var answers = Set<Bool>()
        for cu: Int8 in (u == -1 ? [0, 1] : [u]) {
            for cv: Int8 in (v == -1 ? [0, 1] : [v]) {
                for cw: Int8 in (w == -1 ? [0, 1] : [w]) { answers.insert(cu + cv + cw == 2) }
            }
        }
        return answers.count == 1 ? answers.first : nil
    }

    /// Whether a chord (set of keys) contains a blocked triple: true if some triple is known blocked,
    /// false if every triple is known safe, nil otherwise.
    public func chordBlocked(_ chord: [KeyCode]) -> Bool? {
        let c = chord.compactMap { index[$0] }
        var unknown = false
        for i in 0..<c.count {
            for j in (i + 1)..<c.count {
                for k in (j + 1)..<c.count {
                    switch Self.tripleBlocked(state.get(c[i], c[j]), state.get(c[i], c[k]), state.get(c[j], c[k])) {
                    case true?: return true
                    case nil: unknown = true
                    default: break
                    }
                }
            }
        }
        return unknown ? nil : false
    }

    /// Groups of keys known to share one electrical line (each has at least two keys), split into the two
    /// line directions. Which direction is the physical row cannot be observed, so they are named A and B.
    /// `conflict` is true if the known lines cannot be split into two directions (the data does not fit a grid).
    public func lines() -> (a: [[KeyCode]], b: [[KeyCode]], conflict: Bool) {
        let n = keys.count
        var found: [[Int]] = []
        var seen = Set<[Int]>()
        for i in 0..<n {
            for j in (i + 1)..<n where state.get(i, j) == 1 {
                var line = [i, j]
                for c in 0..<n where c != i && c != j && state.get(i, c) == 1 && state.get(j, c) == 1 { line.append(c) }
                line.sort()
                if seen.insert(line).inserted { found.append(line) }
            }
        }
        // Drop partial lines contained in bigger ones.
        let sets = found.map(Set.init)
        var lines: [[Int]] = []
        for (i, l) in found.enumerated()
        where !sets.indices.contains(where: { $0 != i && sets[$0].count > sets[i].count && sets[i].isSubset(of: sets[$0]) }) {
            lines.append(l)
        }
        // Two lines through the same key run in different directions: 2-colour the lines.
        var color = Array(repeating: -1, count: lines.count)
        var conflict = false
        let lineSets = lines.map(Set.init)
        for start in lines.indices where color[start] == -1 {
            color[start] = 0
            var queue = [start]
            while let cur = queue.popLast() {
                for other in lines.indices where other != cur && !lineSets[cur].isDisjoint(with: lineSets[other]) {
                    if color[other] == -1 {
                        color[other] = 1 - color[cur]
                        queue.append(other)
                    } else if color[other] == color[cur] {
                        conflict = true
                    }
                }
            }
        }
        func codes(_ l: [Int]) -> [KeyCode] { l.map { keys[$0] } }
        func ordered(_ ls: [[Int]]) -> [[KeyCode]] {
            ls.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }.map(codes)
        }
        return (ordered(lines.indices.filter { color[$0] == 0 }.map { lines[$0] }),
                ordered(lines.indices.filter { color[$0] == 1 }.map { lines[$0] }), conflict)
    }

    // MARK: Inference

    func propagate(_ s: inout EdgeState) {
        var common: [Int] = []
        var neighbors: [Int] = []
        common.reserveCapacity(s.n)
        neighbors.reserveCapacity(s.n)
        repeat {
            s.changed = false
            applyObservations(&s)
            if s.failed { return }
            Self.applyPairRules(&s, &common)
            if s.failed { return }
            Self.applyTwoLineRule(&s, &neighbors)
            if s.failed { return }
        } while s.changed
    }

    /// Blocked means exactly two of the three pairs share a line; not blocked means 0, 1 or 3.
    private func applyObservations(_ s: inout EdgeState) {
        for o in observations {
            let u = s.get(o.a, o.b), v = s.get(o.a, o.x), w = s.get(o.b, o.x)
            let ones = (u == 1 ? 1 : 0) + (v == 1 ? 1 : 0) + (w == 1 ? 1 : 0)
            let unknown = (u == -1 ? 1 : 0) + (v == -1 ? 1 : 0) + (w == -1 ? 1 : 0)
            var fill: Int8 = -1
            if o.blocked {
                if ones > 2 || ones + unknown < 2 { s.failed = true; return }
                if unknown > 0 {
                    if ones == 2 { fill = 0 } else if ones + unknown == 2 { fill = 1 }
                }
            } else if unknown == 0 {
                if ones == 2 { s.failed = true; return }
            } else if unknown == 1 {
                if ones == 2 { fill = 1 } else if ones == 1 { fill = 0 }
            }
            if fill != -1 {
                if u == -1 { s.set(o.a, o.b, fill) }
                if v == -1 { s.set(o.a, o.x, fill) }
                if w == -1 { s.set(o.b, o.x, fill) }
                if s.failed { return }
            }
        }
    }

    /// Rules about a pair and its common neighbours (keys sharing a line with both):
    /// - sharing pair: its common neighbours are on the same line, so they all share with each other;
    /// - non-sharing pair: at most two common neighbours (the other corners of its rectangle), not sharing;
    /// - unknown pair: three common neighbours, or two that share, prove it shares; two that don't, prove it doesn't.
    private static func applyPairRules(_ s: inout EdgeState, _ common: inout [Int]) {
        let n = s.n
        for a in 0..<n {
            for b in (a + 1)..<n {
                common.removeAll(keepingCapacity: true)
                for c in 0..<n where c != a && c != b && s.get(a, c) == 1 && s.get(b, c) == 1 { common.append(c) }
                switch s.get(a, b) {
                case 1:
                    guard !common.isEmpty else { continue }
                    for i in 0..<common.count {
                        for j in (i + 1)..<common.count { s.set(common[i], common[j], 1) }
                    }
                    // A key sharing with a but not with another key on the line is on a's other line,
                    // so it does not share with b (and the same with a and b swapped).
                    for d in 0..<n where d != a && d != b {
                        let da = s.get(a, d), db = s.get(b, d)
                        if da == 1 && db == -1, common.contains(where: { $0 != d && s.get($0, d) == 0 }) { s.set(b, d, 0) }
                        if db == 1 && da == -1, common.contains(where: { $0 != d && s.get($0, d) == 0 }) { s.set(a, d, 0) }
                    }
                case 0:
                    if common.count > 2 { s.failed = true; return }
                    if common.count == 2 {
                        s.set(common[0], common[1], 0)
                        for d in 0..<n where d != a && d != b && d != common[0] && d != common[1] {
                            if s.get(a, d) == 1 && s.get(b, d) == -1 { s.set(b, d, 0) }
                            if s.get(b, d) == 1 && s.get(a, d) == -1 { s.set(a, d, 0) }
                        }
                    }
                default:
                    if common.count >= 3 {
                        s.set(a, b, 1)
                    } else if common.count == 2 {
                        let v = s.get(common[0], common[1])
                        if v != -1 { s.set(a, b, v) }
                    }
                }
                if s.failed { return }
            }
        }
    }

    /// Every key is on exactly two lines. If b and c share with a but not with each other, they are on a's two
    /// different lines, so any other key sharing with a shares with exactly one of b and c.
    private static func applyTwoLineRule(_ s: inout EdgeState, _ nb: inout [Int]) {
        let n = s.n
        for a in 0..<n {
            nb.removeAll(keepingCapacity: true)
            for c in 0..<n where c != a && s.get(a, c) == 1 { nb.append(c) }
            guard nb.count >= 2 else { continue }
            for i in 0..<nb.count {
                for j in (i + 1)..<nb.count {
                    let b = nb[i], c = nb[j]
                    guard s.get(b, c) == 0 else { continue }
                    for d in nb where d != b && d != c {
                        let db = s.get(d, b), dc = s.get(d, c)
                        if db != -1 { s.set(d, c, 1 - db) }
                        if dc != -1 { s.set(d, b, 1 - dc) }
                        if s.failed { return }
                    }
                    // b and c sit on a's two lines, so a key sharing with neither is on neither line.
                    for d in 0..<n where d != a && s.get(a, d) == -1 && s.get(d, b) == 0 && s.get(d, c) == 0 {
                        s.set(a, d, 0)
                    }
                }
            }
        }
    }

    /// Failed-literal probing on pairs involving keys held in two or more sweeps: assume each value,
    /// and keep the other one if the assumption leads to a contradiction. Also keeps conclusions that
    /// follow from both assumptions.
    private func probe() {
        let n = keys.count
        let hubs = (0..<n).filter { heldCount[$0] >= 2 }
        guard !hubs.isEmpty else { return }
        for _ in 0..<4 {
            var progress = false
            for h in hubs {
                for x in 0..<n where x != h && state.get(h, x) == -1 {
                    var t0 = state
                    t0.set(h, x, 0)
                    propagate(&t0)
                    if t0.failed {
                        state.set(h, x, 1)
                        propagate(&state)
                        if state.failed { return }
                        progress = true
                        continue
                    }
                    var t1 = state
                    t1.set(h, x, 1)
                    propagate(&t1)
                    if t1.failed {
                        t0.changed = false
                        t0.failed = false
                        state = t0
                        progress = true
                        continue
                    }
                    for k in 0..<(n * n) where state.e[k] == -1 && t0.e[k] != -1 && t0.e[k] == t1.e[k] {
                        state.e[k] = t0.e[k]
                        progress = true
                    }
                }
            }
            if !progress { return }
            propagate(&state)
            if state.failed { return }
        }
    }
}

// MARK: - Planner

public enum MatrixPlanner {
    /// The next pair to hold, or nil when no holdable pair can teach anything new.
    /// - `canHold`: whether one hand can hold both keys while the other taps.
    /// - `preferred`: pairs to try first while nothing is known (for example from a combination that failed).
    public static func nextPair(model: MatrixModel, skipped: Set<KeyPair> = [], preferred: [KeyPair] = [],
                                canHold: (KeyCode, KeyCode) -> Bool) -> KeyPair? {
        let done = Set(model.sweeps.map(\.pair))
        let n = model.keys.count
        if model.sweeps.isEmpty || model.inconsistent.count == model.sweeps.count {
            for p in preferred where !done.contains(p) && !skipped.contains(p) && canHold(p.a, p.b)
                && model.index[p.a] != nil && model.index[p.b] != nil { return p }
        }
        guard model.unknownPairs > 0 else { return nil }
        let unknown = (0..<n).map { model.unknownCount(index: $0) }
        // How often each key was blocked while the other was held: a hint that the pair shares a line.
        var evidence: [KeyPair: Int] = [:]
        for (i, s) in model.sweeps.enumerated() where !model.inconsistent.contains(i) {
            for x in s.blocked {
                evidence[KeyPair(s.pair.a, x), default: 0] += 1
                evidence[KeyPair(s.pair.b, x), default: 0] += 1
            }
        }
        var best: (score: Int, pair: KeyPair)?
        for i in 0..<n {
            for j in (i + 1)..<n {
                let p = KeyPair(model.keys[i], model.keys[j])
                guard !done.contains(p), !skipped.contains(p), canHold(p.a, p.b) else { continue }
                let ui = unknown[i], uj = unknown[j]
                guard ui + uj > 0, !model.usefulTaps(p).isEmpty else { continue }
                var score = 0
                switch model.edge(i, j) {
                case 1:
                    // Holding a sharing pair where one key is fully known reveals everything about the other.
                    if ui == 0 || uj == 0 { score = 3000 + ui + uj } else { score = 2000 + min(ui, uj) }
                case 0:
                    // A non-sharing pair only reveals the other corners of its rectangle.
                    var gain = 0
                    if ui == 0 || uj == 0 {
                        let (g, x) = ui == 0 ? (i, j) : (j, i)
                        for y in 0..<n where y != g && y != x && model.edge(g, y) == 1 && model.edge(x, y) == -1 { gain += 1 }
                    }
                    score = gain > 0 ? 1000 + gain : 0
                default:
                    // Unknown pair: worth trying when a sweep hinted that it shares a line, or when one of the
                    // keys has not been connected to anything yet.
                    let ev = evidence[p] ?? 0
                    if ev > 0 {
                        score = 500 + 50 * min(ev, 5) + (ui + uj) / 4
                    } else if ui == n - 1 || uj == n - 1 {
                        score = 100 + (ui + uj) / 8
                    }
                }
                if score > 0, best == nil || score > best!.score { best = (score, p) }
            }
        }
        return best?.pair
    }
}
