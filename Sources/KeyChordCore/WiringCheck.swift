// Wiring check: a fixed list of rounds ("hold these two keys, tap these") that settles what the keyboard
// wiring leaves open. Same tapping as the Matrix Scan: one highlighted key at a time, a key passed over
// stays dark (blocked), a red key tapped again turns green, letting go of the pair pauses the round.
//
// Plan format:
//   version 1
//   hardware MacBookPro18,1
//   name 2                       which check this is (results are saved per check)
//   round A+B : K K K ...        hold A and B, tap the keys in order

public struct WiringCheckRound: Equatable, Sendable {
    public var pair: KeyPair
    /// Keys to tap, in order.
    public var taps: [KeyCode]
    public init(pair: KeyPair, taps: [KeyCode]) {
        self.pair = pair
        self.taps = taps
    }
}

public enum WiringCheckPlan {
    public enum ParseError: Error, Equatable { case malformed(line: Int), unknownKey(String, line: Int) }

    public static func parse(_ text: String, layout: Layout) throws -> [WiringCheckRound] {
        try parseNamed(text, layout: layout).rounds
    }

    public static func parseNamed(_ text: String, layout: Layout) throws -> (name: String, rounds: [WiringCheckRound]) {
        var name = "1"
        var rounds: [WiringCheckRound] = []
        for (n, line) in Lex.lines(text) {
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            switch f.first {
            case "version": guard f.count == 2, f[1] == "1" else { throw ParseError.malformed(line: n) }
            case "hardware": break
            case "name":
                guard f.count == 2 else { throw ParseError.malformed(line: n) }
                name = f[1]
            case "round":
                guard f.count >= 4, f[2] == ":" else { throw ParseError.malformed(line: n) }
                func code(_ s: String) throws -> KeyCode {
                    guard let i = layout.indexByName[s] else { throw ParseError.unknownKey(s, line: n) }
                    return layout.keys[i].code
                }
                let p = f[1].split(separator: "+").map(String.init)
                guard p.count == 2 else { throw ParseError.malformed(line: n) }
                let a = try code(p[0]), b = try code(p[1])
                var taps: [KeyCode] = []
                for s in f.dropFirst(3) {
                    let c = try code(s)
                    guard c != a, c != b, !taps.contains(c) else { throw ParseError.malformed(line: n) }
                    taps.append(c)
                }
                rounds.append(WiringCheckRound(pair: KeyPair(a, b), taps: taps))
            default: throw ParseError.malformed(line: n)
            }
        }
        return (name, rounds)
    }
}

public final class WiringCheckSession {
    public enum Phase: Equatable, Sendable { case hold, tapping, finished }

    public let layout: Layout
    public let rounds: [WiringCheckRound]
    /// One result per round; nil until the round is done.
    public private(set) var results: [MatrixSweep?]
    public private(set) var index = 0
    public private(set) var phase: Phase = .hold
    public private(set) var status: [KeyCode: MatrixScanSession.TapStatus] = [:]
    public private(set) var down = Set<KeyCode>()
    public private(set) var message = ""
    private let known: Set<KeyCode>

    public init(layout: Layout, rounds: [WiringCheckRound], results: [MatrixSweep] = []) {
        self.layout = layout
        self.rounds = rounds
        known = Set(layout.keys.map(\.code))
        var r: [MatrixSweep?] = Array(repeating: nil, count: rounds.count)
        // Saved results go back to their rounds (matched by pair and keys).
        for s in results {
            if let i = rounds.indices.first(where: { r[$0] == nil && rounds[$0].pair == s.pair && Set(rounds[$0].taps) == s.tapped }) {
                r[i] = s
            }
        }
        self.results = r
        index = r.firstIndex(where: { $0 == nil }) ?? rounds.count
        phase = index < rounds.count ? .hold : .finished
    }

    public var round: WiringCheckRound? { index < rounds.count ? rounds[index] : nil }
    public var done: [MatrixSweep] { results.compactMap { $0 } }
    public var unresolved: [KeyCode] { round?.taps.filter { status[$0] == nil } ?? [] }
    public var current: KeyCode? { unresolved.first }
    public var registeredKeys: Set<KeyCode> { Set(status.filter { $0.value == .registered }.keys) }
    public var missedKeys: Set<KeyCode> { Set(status.filter { $0.value == .missed }.keys) }
    /// A key that registered this round: tapping it again says the remaining keys stayed dark.
    public var finishKey: KeyCode? { round?.taps.first { status[$0] == .registered } }
    public var tapsLeft: Int {
        rounds.indices.filter { results[$0] == nil }.reduce(0) { $0 + rounds[$1].taps.count } - status.count
    }

    public func name(_ c: KeyCode) -> String { layout.indexByCode[c].map { layout.keys[$0].name } ?? "Key\(c)" }

    // MARK: Keys

    public func keyDown(_ code: KeyCode) {
        guard known.contains(code), let r = round else { return }
        down.insert(code)
        switch phase {
        case .hold:
            if down == [r.pair.a, r.pair.b] { phase = .tapping }
        case .tapping:
            guard code != r.pair.a, code != r.pair.b, down.contains(r.pair.a), down.contains(r.pair.b),
                  r.taps.contains(code) else { return }
            switch status[code] {
            case .missed?:
                status[code] = .registered
                message = "\(name(code)) registered after all."
            case .registered?:
                // Tapping a green key again: the keys still waiting were tapped and stayed dark.
                if !unresolved.isEmpty { for k in unresolved { status[k] = .missed } }
            case nil:
                let u = unresolved
                if let i = u.firstIndex(of: code) { for k in u[..<i] { status[k] = .missed } }
                status[code] = .registered
                message = ""
            }
        case .finished:
            break
        }
    }

    public func keyUp(_ code: KeyCode) {
        guard known.contains(code) else { return }
        down.remove(code)
        guard let r = round else { return }
        switch phase {
        case .hold:
            if down == [r.pair.a, r.pair.b] { phase = .tapping }
        case .tapping:
            guard !down.contains(r.pair.a) && !down.contains(r.pair.b) else { return }
            phase = .hold
            if registeredKeys.isEmpty {
                status.removeAll()
                message = "Nothing registered. Hold \(name(r.pair.a)) + \(name(r.pair.b)) and tap the highlighted key with your other hand."
            } else if unresolved.isEmpty {
                record()
            } else {
                message = "Paused: \(unresolved.count) keys to go. Hold the pair again to carry on."
            }
        case .finished:
            break
        }
    }

    private func record() {
        guard let r = round else { return }
        let blocked = missedKeys
        results[index] = MatrixSweep(pair: r.pair, blocked: blocked, tapped: Set(r.taps))
        message = "\(name(r.pair.a)) + \(name(r.pair.b)): " + (blocked.isEmpty ? "all registered." : "\(blocked.count) blocked.")
        status.removeAll()
        advance()
    }

    private func advance() {
        while index < rounds.count && results[index] != nil { index += 1 }
        phase = index < rounds.count ? (down == round.map { [$0.pair.a, $0.pair.b] } ? .tapping : .hold) : .finished
    }

    /// Window lost focus: forget held keys; the round continues when the pair is held again.
    public func interrupt() {
        down.removeAll()
        if phase == .tapping { phase = .hold }
    }

    // MARK: Back and forward

    public var canGoBack: Bool { !status.isEmpty || (0..<index).contains { results[$0] != nil } }
    public var canGoForward: Bool { status.isEmpty && index < rounds.count }

    /// Restarts the round in progress, or reopens the previous round (its result is kept until redone).
    public func back() {
        if !status.isEmpty {
            status.removeAll()
            message = "Round restarted."
            return
        }
        guard let i = (0..<index).last(where: { results[$0] != nil }) else { return }
        index = i
        results[i] = nil
        phase = .hold
        message = "Redo this round."
    }

    /// Skips the current round for now (it stays in the list).
    public func forward() {
        guard canGoForward else { return }
        status.removeAll()
        var i = index + 1
        while i < rounds.count && results[i] != nil { i += 1 }
        if i >= rounds.count, let first = rounds.indices.first(where: { results[$0] == nil && $0 != index }) { i = first }
        if i < rounds.count { index = i }
        phase = .hold
        message = "Skipped; it comes back at the end."
    }

    // MARK: Report

    /// The results as scan lines, plus how the wiring does on them.
    public func report(hardware: String, wiring: KeyboardWiring?, scan: [MatrixSweep] = [], scanCombos: [MatrixCombo] = [],
                       title: String = "Wiring Check") -> String {
        func names(_ s: Set<KeyCode>) -> [String] { layout.keys.map(\.code).filter { s.contains($0) }.map(name) }
        var s = "# KeyChord \(title)\n"
        s += "# sweep A+B blocked <keys> tapped <keys>: A and B held, the tapped keys tapped once each.\n"
        s += "version 1\nhardware \(hardware)\n"
        s += "keys " + layout.keys.map(\.name).joined(separator: " ") + "\n"
        for r in done {
            let b = names(r.blocked)
            s += "sweep \(name(r.pair.a))+\(name(r.pair.b)) blocked " + (b.isEmpty ? "-" : b.joined(separator: " "))
            s += " tapped " + names(r.tapped ?? []).joined(separator: " ") + "\n"
        }
        s += "# --- analysis ---\n"
        s += "# rounds done \(done.count) of \(rounds.count)\n"
        if let wiring {
            let fit = wiring.fit(sweeps: done, combos: [], layout: layout)
            s += "# wiring (\(wiring.hardware)) predicts \(fit.explained) of \(fit.total) taps of this check\n"
            for m in fit.mismatches { s += "#   " + m + "\n" }
            if !scan.isEmpty {
                let all = wiring.fit(sweeps: scan + done, combos: scanCombos, layout: layout)
                s += "# with everything before it: \(all.explained) of \(all.total)\n"
                for m in all.mismatches where !fit.mismatches.contains(m) { s += "#   earlier: " + m + "\n" }
            }
        }
        return s
    }
}
