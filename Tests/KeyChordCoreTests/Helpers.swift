import Testing
@testable import KeyChordCore

/// Loads the bundled defaults and fails the test if they have problems.
func defaultOutcome(limit: Int = 6) -> LoadOutcome {
    var sources: [DataFile: String?] = [:]
    for f in DataFile.allCases { sources[f] = f.defaultSource }
    return DictionaryLoader.load(sources: sources, rolloverLimit: limit)
}

let defaults: EngineData = {
    let o = defaultOutcome()
    precondition(o.problems.isEmpty, "default data has problems: \(o.problems)")
    return o.data
}()

func keys(_ spec: String, _ layout: Layout = defaults.layout) -> KeySet {
    let names = spec.split(separator: "+").map(String.init)
    guard let k = layout.keySet(names: names) else { fatalError("unknown keys in \(spec)") }
    return k
}

/// Text buffer simulator that applies Output_Actions (Req 19.3).
struct TextBuffer: Equatable, CustomStringConvertible {
    var chars: [Character]
    var cursor: Int

    init(_ text: String = "", cursor: Int? = nil) {
        chars = Array(text)
        self.cursor = cursor ?? chars.count
    }

    enum Failure: Error { case outOfRange(OutputAction) }

    mutating func apply(_ a: OutputAction) throws {
        switch a {
        case .insert(let s):
            let c = Array(s)
            chars.insert(contentsOf: c, at: cursor)
            cursor += c.count
        case .deleteBackward(let n):
            guard n <= cursor else { throw Failure.outOfRange(a) }
            chars.removeSubrange((cursor - n)..<cursor)
            cursor -= n
        case .deleteForward(let n):
            guard cursor + n <= chars.count else { throw Failure.outOfRange(a) }
            chars.removeSubrange(cursor..<(cursor + n))
        case .moveLeft(let n):
            guard n <= cursor else { throw Failure.outOfRange(a) }
            cursor -= n
        case .moveRight(let n):
            guard cursor + n <= chars.count else { throw Failure.outOfRange(a) }
            cursor += n
        }
    }

    mutating func apply(_ actions: [OutputAction]) throws {
        for a in actions { try apply(a) }
    }

    var text: String { String(chars) }
    /// Text with "|" at the cursor.
    var description: String { String(chars[0..<cursor]) + "|" + String(chars[cursor...]) }
}

/// Drives a ChordEngine chord by chord and keeps a text buffer.
final class Driver {
    let engine: ChordEngine
    var buffer = TextBuffer()
    var signals: [EngineSignal] = []

    init(_ mode: SubMode = .english, data: EngineData = defaults) {
        engine = ChordEngine(data: data, subMode: mode)
    }

    /// Presses the keys in order and releases them in the same order.
    @discardableResult
    func chord(_ spec: String, join: Bool = false, capsLock: Bool = false) throws -> EngineResult {
        let k = keys(spec, engine.data.layout)
        for (n, i) in k.indices.enumerated() { engine.keyDown(i, shift: join && n == 0) }
        var result: EngineResult?
        for i in k.indices { if let r = try engine.keyUp(i, capsLock: capsLock) { result = r } }
        let r = try #require(result)
        try buffer.apply(r.actions)
        if let s = r.signal { signals.append(s) }
        return r
    }

    func chords(_ specs: String...) throws {
        for s in specs { try chord(s) }
    }

    var text: String { buffer.text }
}

/// Deterministic PRNG for property tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The 100 most frequent English words (Oxford English Corpus).
let top100 = """
the be to of and a in that have I it for not on with he as you do at this but his by from they we say her she \
or an will my one all would there their what so up out if about who get which go me when make can like time no \
just him know take people into year your good some could them see other than then now look only come its over \
think also back after use two how our work first well way even new want because any these give day most us
""".split(separator: " ").map(String.init)

/// Candidate single chords for `word`: dictionary entries and syllable compositions.
func candidateChords(_ word: String, mode: SubMode = .english, data: EngineData = defaults) -> [KeySet] {
    var out: [KeySet] = []
    for d in [data.dictionary(for: mode), data.shared] {
        for (k, e) in d.entries {
            if case .text(let t) = e, t.text == word, t.cursorFromEnd == nil { out.append(k) }
        }
    }
    let l = data.layout
    func options(_ b: Bank) -> [(KeySet, String)] { [(KeySet(), "")] + (l.clusters[b] ?? [:]).map { ($0.key, $0.value) } }
    for (ok, ov) in options(.onset) where word.hasPrefix(ov) {
        let rest1 = String(word.dropFirst(ov.count))
        for (vk, vv) in options(.vowel) where rest1.hasPrefix(vv) {
            let rest2 = String(rest1.dropFirst(vv.count))
            for (ck, cv) in options(.coda) where rest2 == cv {
                let k = ok.union(vk).union(ck)
                if !k.isEmpty { out.append(k) }
            }
        }
    }
    return out
}

/// A chord that really produces exactly `word` from a fresh engine.
func chordProducing(_ word: String, mode: SubMode = .english, data: EngineData = defaults) -> KeySet? {
    candidateChords(word, mode: mode, data: data).first { k in
        let e = ChordEngine(data: data, subMode: mode)
        return (try? e.translate(k, join: false))?.actions == [.insert(word)]
    }
}
