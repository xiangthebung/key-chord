import Testing
@testable import KeyChordCore

@Suite("Reading a held chord")
struct ChordReadingTests {
    func read(_ spec: String, shift: Bool = false, _ mode: SubMode = .english) -> ChordReading {
        ChordReading(keys(spec), shift: shift, data: defaults, mode: mode)
    }

    func parts(_ r: ChordReading) -> [String] {
        r.parts.map { "\($0.role.rawValue):\($0.text)=\($0.keys.joined(separator: "+"))" }
    }

    @Test func syllables() {
        let thing = read("T+E+M+K+L")
        #expect(parts(thing) == ["onset:th=E+T", "vowel:i=M", "coda:ng=K+L"])
        #expect(thing.outcome == .text("thing"))
        #expect(!thing.joins)
        // The space bar held with a chord joins it; Shift does too.
        let joined = read("Space+C+H")
        #expect(parts(joined) == ["join:join=Space", "vowel:a=C", "coda:n=H"])
        #expect(joined.outcome == .text("an") && joined.joins)
        #expect(read("C+H", shift: true).joins)
        #expect(read("Space").outcome == .text(" "))
    }

    @Test func entriesLettersAndDigits() {
        #expect(parts(read("Quote+A+B")) == ["word:about=A+Quote+B"])
        #expect(read("K+L").outcome == .text("-ing"))
        #expect(parts(read("K+L")) == ["suffix:-ing=K+L"])
        #expect(read("Period").outcome == .text("."))
        #expect(read("M").outcome == .text("I"))
        #expect(read("Backslash").outcome == .command("undo the last chord"))
        #expect(read("N+M").outcome == .command("capital on the next word"))
        #expect(parts(read("Quote+X")) == ["spell:spell=Quote", "letter:x=X"])
        #expect(parts(read("Quote+A+Semicolon")) == ["spell:spell=Quote", "capital:capital=Semicolon", "letter:a=A"])
        #expect(read("Quote+A+Semicolon").outcome == .text("A"))
        #expect(parts(read("1+2+3")) == ["digit:1=1", "digit:2=2", "digit:3=3"])
        #expect(read("1+2+3").outcome == .text("123"))
        // The same keys mean something else in C++ mode.
        #expect(read("Semicolon", .cpp).outcome == .text(";"))
        #expect(read("Quote", .cpp).outcome == .text("'…'"))
    }

    @Test("Keys that make no chord say which group is the problem")
    func nothing() {
        let r = read("E+R+T+C")
        #expect(r.outcome == .nothing)
        #expect(parts(r) == ["onset:?=E+R+T", "vowel:a=C"])
        #expect(read("1+C").outcome == .nothing)
        #expect(parts(read("Quote+A+S")) == ["spell:spell=Quote", "letter:?=A+S"])
    }

    @Test("Agrees with the engine for every chord of up to three keys", arguments: SubMode.allCases)
    func agreesWithEngine(mode: SubMode) throws {
        let layout = defaults.layout
        let n = layout.keys.count
        var checked = Set<KeySet>()
        for a in 0..<n {
            for b in a..<n {
                for c in b..<n {
                    let k = KeySet([a, b, c])
                    guard checked.insert(k).inserted else { continue }
                    let reading = ChordReading(k, data: defaults, mode: mode)
                    let r = try ChordEngine(data: defaults, subMode: mode).translate(k, join: false)
                    let typed = r.actions.compactMap { a -> String? in
                        if case .insert(let s) = a { return s } else { return nil }
                    }.joined()
                    let name = layout.chordString(k)
                    #expect(Set(reading.parts.flatMap(\.keys)) == Set(layout.names(k)), "\(name): \(parts(reading))")
                    var lookup = k
                    if let sp = layout.spaceIndex, k.count > 1 { lookup.remove(sp) }
                    let entry = defaults.dictionary(for: mode)[lookup] ?? defaults.shared[lookup]
                    switch reading.outcome {
                    case .nothing:
                        #expect(r.signal == .untranslatable, "\(name) types \(typed.debugDescription)")
                    case .command:
                        guard case .command? = entry else { Issue.record("\(name) is not a command"); continue }
                        #expect(typed.isEmpty, "\(name)")
                    case .text(let t):
                        #expect(r.signal == nil, "\(name)")
                        if case .text(let e)? = entry, e.kind == .suffix || e.isSnippet {
                            #expect(t == KeyMeanings.display(.text(e)), "\(name)")
                        } else {
                            #expect(t == typed, "\(name): reads \(t.debugDescription), types \(typed.debugDescription)")
                        }
                    }
                }
            }
        }
        #expect(checked.count > 15_000)
    }

    @Test("Sounds that can't be read off the keyboard")
    func multiKeySounds() {
        let s = KeyMeanings.multiKeySounds(defaults.layout)
        func texts(_ b: Bank) -> [String] { (s[b] ?? []).map(\.text) }
        #expect(Array(texts(.onset).prefix(9)) == ["c", "j", "k", "m", "n", "p", "v", "x", "y"])
        #expect(texts(.onset).contains("ch") && texts(.onset).contains("sp"))
        // s + t, t + h, b + r: the keys of their letters.
        #expect(!texts(.onset).contains("st") && !texts(.onset).contains("th") && !texts(.onset).contains("br"))
        #expect(texts(.vowel) == ["ea", "ee", "oo", "ou"])
        #expect(texts(.coda).contains("ng") && texts(.coda).contains("g"))
        #expect(!texts(.coda).contains("nd") && !texts(.coda).contains("te"))
        for (bank, list) in s {
            for x in list { #expect(defaults.layout.clusters[bank]?[x.keys] == x.text) }
        }
    }
}
