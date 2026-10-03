// Keyboard wiring: where each key sits in the keyboard's electrical matrix, and which chords it drops.
//
// Each key connects one row wire to one column wire. With three keys held in an "L" (two on one row, and
// one of those two on a column with the third), the controller also sees the fourth corner of that
// rectangle as closed. If a real key sits at the fourth corner, it cannot tell whether that key is pressed
// too, so it drops the combination. If the fourth corner is an empty spot in the matrix, there is nothing
// to confuse, and all three keys register. Keys on one line, or with no shared line, never block.
//
// File format (wiring.txt), one grid of the matrix:
//   version 1
//   hardware MacBookPro18,1
//   columns c1 c2 ...            column names
//   row NAME cell cell ...       one cell per column: a Layout key name, "." for an empty spot, or "?" for a
//                                key that is not a chord key (Delete, Return, arrows, ...)
//   solo KEY KEY ...             keys whose lines hold no other chord key and no known corner

public struct KeyboardWiring: Sendable, Equatable {
    public struct Position: Hashable, Sendable {
        public let row: String
        public let column: String
        public init(_ row: String, _ column: String) {
            self.row = row
            self.column = column
        }
    }

    public let hardware: String
    public let rows: [String]
    public let columns: [String]
    public let position: [KeyCode: Position]
    /// Spots holding a key that is not in the Layout; they still count as fourth corners.
    public let otherKeys: Set<Position>
    public let solo: [KeyCode]

    public init(hardware: String, rows: [String], columns: [String], position: [KeyCode: Position],
                otherKeys: Set<Position>, solo: [KeyCode]) {
        self.hardware = hardware
        self.rows = rows
        self.columns = columns
        self.position = position
        self.otherKeys = otherKeys
        self.solo = solo
        occupied = Set(position.values).union(otherKeys)
    }

    let occupied: Set<Position>

    public static func == (a: KeyboardWiring, b: KeyboardWiring) -> Bool {
        a.hardware == b.hardware && a.rows == b.rows && a.columns == b.columns && a.position == b.position
            && a.otherKeys == b.otherKeys && a.solo == b.solo
    }

    public func shares(_ a: KeyCode, _ b: KeyCode) -> Bool {
        guard let p = position[a], let q = position[b] else { return false }
        return p.row == q.row || p.column == q.column
    }

    /// Whether the keyboard drops one of these three keys when they are held together.
    public func tripleBlocked(_ a: KeyCode, _ b: KeyCode, _ c: KeyCode) -> Bool {
        guard let pa = position[a], let pb = position[b], let pc = position[c] else { return false }
        for (x, y, z) in [(pa, pb, pc), (pb, pa, pc), (pc, pa, pb)] {
            let yz = y.row == z.row || y.column == z.column
            if yz { continue }
            // Corner at x: x shares its row with y and its column with z (or the other way round).
            if x.row == y.row && x.column == z.column { return occupied.contains(Position(z.row, y.column)) }
            if x.column == y.column && x.row == z.row { return occupied.contains(Position(y.row, z.column)) }
        }
        return false
    }

    /// Whether a chord contains a blocked 3-key combination.
    public func blocks(_ codes: [KeyCode]) -> Bool {
        guard codes.count >= 3 else { return false }
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count {
                for k in (j + 1)..<codes.count where tripleBlocked(codes[i], codes[j], codes[k]) { return true }
            }
        }
        return false
    }

    // MARK: Checking against a scan

    public struct Fit: Sendable {
        public var explained = 0
        public var total = 0
        public var mismatches: [String] = []
    }

    /// How many scan observations (each tapped key of each sweep, each combination) the wiring predicts.
    public func fit(sweeps: [MatrixSweep], combos: [MatrixCombo], layout: Layout) -> Fit {
        func name(_ c: KeyCode) -> String { layout.indexByCode[c].map { layout.keys[$0].name } ?? "Key\(c)" }
        let all = layout.keys.map(\.code)
        var f = Fit()
        for s in sweeps {
            let tapped = s.tapped ?? Set(all).subtracting([s.pair.a, s.pair.b])
            for x in all where tapped.contains(x) {
                f.total += 1
                let predicted = tripleBlocked(s.pair.a, s.pair.b, x), observed = s.blocked.contains(x)
                if predicted == observed { f.explained += 1; continue }
                f.mismatches.append("\(name(s.pair.a))+\(name(s.pair.b)) tap \(name(x)): "
                    + (observed ? "blocked, wiring says it registers" : "registered, wiring says blocked"))
            }
        }
        for c in combos {
            f.total += 1
            let predicted = blocks(Array(c.keys)), observed = c.outcome == .fail
            if predicted == observed { f.explained += 1; continue }
            let keys = all.filter { c.keys.contains($0) }.map(name).joined(separator: "+")
            f.mismatches.append("\(keys): " + (observed ? "failed, wiring says it works" : "worked, wiring says blocked"))
        }
        return f
    }

    // MARK: Text

    public enum ParseError: Error, Equatable {
        case malformed(line: Int)
        case unknownKey(String, line: Int)
        case wrongCellCount(line: Int)
        case duplicate(String, line: Int)
    }

    public static func parse(_ text: String, layout: Layout) throws -> KeyboardWiring {
        var hardware = ""
        var columns: [String] = []
        var rows: [String] = []
        var position: [KeyCode: Position] = [:]
        var other = Set<Position>()
        var solo: [KeyCode] = []
        func code(_ s: String, _ n: Int) throws -> KeyCode {
            guard let i = layout.indexByName[s] else { throw ParseError.unknownKey(s, line: n) }
            let c = layout.keys[i].code
            if position[c] != nil || solo.contains(c) { throw ParseError.duplicate(s, line: n) }
            return c
        }
        for (n, line) in Lex.lines(text) {
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            switch f.first {
            case "version": guard f.count == 2, f[1] == "1" else { throw ParseError.malformed(line: n) }
            case "hardware": hardware = f.dropFirst().joined(separator: " ")
            case "columns":
                guard f.count > 1, columns.isEmpty else { throw ParseError.malformed(line: n) }
                columns = Array(f.dropFirst())
            case "row":
                guard f.count >= 2, !columns.isEmpty, !rows.contains(f[1]) else { throw ParseError.malformed(line: n) }
                let cells = Array(f.dropFirst(2))
                guard cells.count == columns.count else { throw ParseError.wrongCellCount(line: n) }
                rows.append(f[1])
                for (c, cell) in cells.enumerated() {
                    let p = Position(f[1], columns[c])
                    switch cell {
                    case ".": break
                    case "?": other.insert(p)
                    default: position[try code(cell, n)] = p
                    }
                }
            case "solo":
                for s in f.dropFirst() { solo.append(try code(s, n)) }
            default: throw ParseError.malformed(line: n)
            }
        }
        // Solo keys get a row and a column of their own.
        for c in solo { position[c] = Position("solo-\(c)", "solo-\(c)") }
        return KeyboardWiring(hardware: hardware, rows: rows, columns: columns, position: position,
                              otherKeys: other, solo: solo)
    }

    /// The matrix as a table, for the report.
    public func table(layout: Layout) -> String {
        func name(_ c: KeyCode) -> String { layout.indexByCode[c].map { layout.keys[$0].name } ?? "Key\(c)" }
        var at: [Position: String] = [:]
        for (c, p) in position where !solo.contains(c) { at[p] = name(c) }
        for p in otherKeys { at[p] = "?" }
        let width = max(4, (at.values.map(\.count) + columns.map(\.count)).max() ?? 4)
        let rowWidth = max(4, rows.map(\.count).max() ?? 4)
        func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }
        var out = pad("", rowWidth) + " " + columns.map { pad($0, width) }.joined(separator: " ") + "\n"
        for r in rows {
            out += pad(r, rowWidth) + " " + columns.map { pad(at[Position(r, $0)] ?? ".", width) }.joined(separator: " ") + "\n"
        }
        if !solo.isEmpty { out += "solo: " + solo.map(name).joined(separator: " ") + "\n" }
        return out
    }
}
