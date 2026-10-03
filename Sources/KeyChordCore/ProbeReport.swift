// Probe_Report model and text serialization (Req 5.7 - 5.9).
// The report contains only key names, results, and timestamps; never typed text (Req 5.8).
//
// Format:
//   # KeyChord Probe Report
//   version 1
//   created <ms since 1970>
//   max-held <n>
//   result <ms> <pass|fail|extra|ghost> <KEY+KEY...> [KEY+KEY...]
// The optional last field lists missing keys (fail) or unexpected keys (extra/ghost).

public enum ProbeOutcome: String, Sendable, CaseIterable {
    case pass, fail, extra, ghost
}

public struct ProbeResult: Equatable, Sendable {
    public var timestamp: Int64
    public var target: [String]
    public var outcome: ProbeOutcome
    /// Missing keys for `fail`, unexpected keys for `extra` / `ghost`.
    public var detail: [String]

    public init(timestamp: Int64, target: [String], outcome: ProbeOutcome, detail: [String] = []) {
        self.timestamp = timestamp
        self.target = target
        self.outcome = outcome
        self.detail = detail
    }

    /// Combinations the hardware cannot be trusted with (Req 5.10).
    public var isFailure: Bool { outcome == .fail || outcome == .ghost }
}

public struct ProbeReport: Equatable, Sendable {
    public var created: Int64
    public var maxHeld: Int
    public var results: [ProbeResult]

    public init(created: Int64, maxHeld: Int, results: [ProbeResult]) {
        self.created = created
        self.maxHeld = maxHeld
        self.results = results
    }

    public func serialized() -> String {
        var s = "# KeyChord Probe Report\nversion 1\ncreated \(created)\nmax-held \(maxHeld)\n"
        for r in results {
            s += "result \(r.timestamp) \(r.outcome.rawValue) \(r.target.joined(separator: "+"))"
            if !r.detail.isEmpty { s += " " + r.detail.joined(separator: "+") }
            s += "\n"
        }
        return s
    }

    public enum ParseError: Error, Equatable { case malformed(line: Int) }

    public static func parse(_ text: String) throws -> ProbeReport {
        var created: Int64 = 0
        var maxHeld = 0
        var results: [ProbeResult] = []
        func names(_ s: Substring) -> [String] { s.split(separator: "+").map(String.init) }
        for (n, line) in Lex.lines(text) {
            let f = line.split(whereSeparator: { $0.isWhitespace })
            switch f.first {
            case "version": guard f.count == 2, f[1] == "1" else { throw ParseError.malformed(line: n) }
            case "created":
                guard f.count == 2, let v = Int64(f[1]) else { throw ParseError.malformed(line: n) }
                created = v
            case "max-held":
                guard f.count == 2, let v = Int(f[1]) else { throw ParseError.malformed(line: n) }
                maxHeld = v
            case "result":
                guard f.count == 4 || f.count == 5, let t = Int64(f[1]),
                      let o = ProbeOutcome(rawValue: String(f[2])) else { throw ParseError.malformed(line: n) }
                results.append(ProbeResult(timestamp: t, target: names(f[3]), outcome: o,
                                           detail: f.count == 5 ? names(f[4]) : []))
            default: throw ParseError.malformed(line: n)
            }
        }
        return ProbeReport(created: created, maxHeld: maxHeld, results: results)
    }
}
