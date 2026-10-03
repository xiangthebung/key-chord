import Testing
@testable import KeyChordCore

/// The Matrix Scan from a MacBookPro18,1 (M1 Pro, ISO), as pasted in the chat. Key names only.
let macBookPro18Scan = #"""
# KeyChord Matrix Scan
version 1
hardware MacBookPro18,1 Apple M1 Pro, ISO keyboard
keys Grave 1 2 3 4 5 6 7 8 9 0 Minus Equal Q W E R T Y U I O P LBracket RBracket Backslash A S D F G H J K L Semicolon Quote Z X C V B N M Comma Period Slash Space
sweep J+M blocked A H K L Semicolon Z N Comma Period Slash
sweep H+J blocked Grave 6 7 Y U RBracket N M Space
sweep H+N blocked A K L Semicolon Z Comma Period Slash tapped Grave 6 7 Y U RBracket A K L Semicolon Z B Comma Period Slash Space
sweep N+M blocked 6 7 Y U RBracket Space tapped Grave 6 7 Y U RBracket A K L Semicolon Z B Comma Period Slash Space
sweep H+6 blocked 1 4 7 8 9 0 A F J K L Semicolon
sweep L+K blocked 8 9 Minus I O LBracket Comma Period untested Grave 6 7 Y U RBracket A H J Semicolon N M
sweep K+Semicolon blocked 8 0 I P LBracket Quote Comma Slash untested Grave 6 7 Y U RBracket A H J L N M
sweep 8+I blocked 5 Q T Y U O P untested 1 4 6 7 9 0 LBracket A F H J K L Semicolon Z N M Comma Period
sweep 5+I blocked - untested 6 7 8 9 0 Minus Q T Y U O P LBracket H J K L Semicolon Quote N M Comma Period
sweep Q+5 blocked 1 untested 6 7 8 9 0 Minus T Y U I O P LBracket H J K L Semicolon Quote N M Comma Period
sweep T+5 blocked - tapped Grave 2 3 4 Equal W E R RBracket Backslash A S D F G Z X C V B Slash Space
sweep 8+LBracket blocked 3 RBracket Backslash tapped Grave 2 3 Minus Equal W E R RBracket Backslash S D G Quote X C V B Slash Space
sweep LBracket+Backslash blocked - tapped Grave 2 4 Minus Equal W E R A S D F G Quote Z X C V B Slash Space
sweep 9+Minus blocked 2 3 Equal tapped Grave 2 3 Equal W E R S D G Quote X C V B Slash Space
sweep 2+3 blocked X C tapped Grave 4 W E R A S D F G Quote Z X C V B Slash Space
sweep X+2 blocked Z Slash tapped Grave 4 W E R A S D F G Quote Z V B Slash Space
sweep C+2 blocked - tapped Grave 4 W E R A S D F G Quote Z V B Slash Space
sweep Equal+Minus blocked - tapped Grave 4 W E R A S D F G Quote Z V B Slash Space
sweep X+C blocked - tapped Grave 4 W E R A S D F G Quote Z V B Slash Space
sweep 1+4 blocked A tapped W E R A S D G Z V B Space
sweep 0+Quote blocked Grave Space tapped Grave W E R S D G V B Slash Space
sweep RBracket+LBracket blocked 6 Y H N Space tapped Grave 6 7 Y U H J N M Slash Space
sweep F+1 blocked - tapped W E R S D G Z V B Space
sweep E+N blocked - tapped Z Space
sweep R+N blocked - tapped Z Space
sweep D+N blocked - tapped Z Space
sweep G+N blocked - tapped Z Space
sweep V+N blocked - tapped Z Space
sweep B+N blocked - tapped Z Space
combo Q+W+Y+U pass
combo E+R+Y+I pass
combo E+T+U+O pass
combo W+T+I+P pass
combo T+I+P pass
combo W+I+P pass
combo W+T+P pass
combo W+T+I pass
combo Q+I+O+A fail missing Q I A
combo Q+I+O pass
combo I+O+A pass
combo Q+I+A fail missing Q I
combo Q+O+A fail missing Q A
combo R+U+P+S pass
combo Y+P+A+D pass
combo Y+O+S+F pass
combo U+I+D+F+C pass
combo W+R+O+H+C pass
combo T+Y+G+J+C pass
combo Q+E+P+K+C pass
combo A+S+L+Semicolon+C pass
combo U+A+G+H+V pass
combo W+S+J+K+V pass
combo O+P+Z+X+V pass
combo O+D+G+K+N+M pass
combo R+T+L+V+N+Slash pass
combo R+T+L+N+Slash pass
combo T+L+V+N+Slash pass
combo R+L+V+N+Slash pass
combo R+T+V+N+Slash pass
combo R+T+L+V+N pass
combo R+T+L+V+Slash pass
combo E+F+H+Semicolon+V+M pass
combo I+S+X+C+M+Slash pass
combo U+J+Z+X+C+N pass
combo P+A+L+B+N+M pass
combo Q+I+D+H+V+N pass
combo R+Y+K+C+V+B pass
"""#

/// Results of the first Wiring Check on the same keyboard, as pasted in the chat.
let macBookPro18Check1 = #"""
# KeyChord Wiring Check
version 1
hardware MacBookPro18,1 Apple M1 Pro, ISO keyboard
keys Grave 1 2 3 4 5 6 7 8 9 0 Minus Equal Q W E R T Y U I O P LBracket RBracket Backslash A S D F G H J K L Semicolon Quote Z X C V B N M Comma Period Slash Space
sweep W+E blocked - tapped Grave 1 2 3 4 5 Minus Equal R O LBracket Backslash L
sweep W+R blocked 2 4 tapped Grave 1 2 4 5 Minus Equal O Backslash S
sweep S+W blocked - tapped Grave 1 2 3 4 5 Minus Equal Q E RBracket Backslash K
sweep D+W blocked - tapped Grave 1 2 3 4 5 Minus Equal E O LBracket Backslash L
sweep G+W blocked - tapped Grave 1 2 3 4 5 Minus Equal E O RBracket Backslash L
sweep V+W blocked - tapped Grave 1 2 3 4 5 Minus Equal E O LBracket Backslash K
sweep B+W blocked - tapped 1 2 3 4 5 7 Minus Equal E Y LBracket Backslash L Semicolon
sweep E+R blocked - tapped 1 2 3 4 5 Minus Equal I LBracket Backslash S Semicolon
sweep S+E blocked - tapped Grave 1 2 3 4 5 Minus Equal I LBracket Backslash D G L
sweep D+E blocked - tapped Grave 1 2 3 4 5 Minus Equal R O LBracket Backslash G J L
sweep G+E blocked - tapped Grave 1 2 3 4 5 Minus Equal R I LBracket Backslash K L V
sweep V+E blocked - tapped Grave 1 2 3 4 5 Minus Equal R Y Backslash S J
sweep B+E blocked - tapped Grave 1 2 3 4 5 7 9 0 Minus Equal R I RBracket S L
sweep S+R blocked - tapped Grave 1 2 3 4 5 Minus Equal P RBracket Backslash D G
sweep D+R blocked - tapped Grave 1 2 3 4 5 Minus Equal W U Backslash G L Semicolon V Period
sweep G+R blocked - tapped Grave 1 2 3 4 5 Minus Equal W O LBracket Backslash L V B
sweep V+R blocked - tapped Grave 1 2 4 5 Minus Equal W Backslash S L B
sweep B+R blocked - tapped 1 2 4 5 Equal W O LBracket Backslash S D K
sweep S+D blocked - tapped Grave 1 2 3 4 5 Minus Equal W U LBracket Backslash G L
sweep S+G blocked 2 5 tapped Grave 1 2 3 4 5 Minus Equal W U RBracket Backslash L V B
sweep S+V blocked - tapped 1 2 3 4 5 Minus Equal W I LBracket Backslash D K B
sweep S+B blocked - tapped Grave 1 2 3 4 5 Minus Equal W U RBracket Backslash D L
sweep D+G blocked - tapped Grave 1 2 3 4 5 Minus Equal W Backslash K V B
sweep D+V blocked 3 4 tapped Grave 1 2 3 4 5 7 Minus Equal W E I Backslash B
sweep D+B blocked 3 5 Backslash tapped Grave 1 2 3 4 5 0 Minus Equal W E U RBracket Backslash L
sweep G+V blocked - tapped 1 2 3 4 5 Minus Equal W LBracket Backslash Semicolon B
sweep G+B blocked - tapped 1 2 3 4 5 Minus Equal W E U RBracket Backslash L Semicolon
sweep V+B blocked 4 5 Backslash tapped Grave 1 2 4 5 7 Minus Equal W E Backslash K
sweep 6+Space blocked 1 2 3 5 tapped 1 2 3 4 5 9 Equal L
sweep Minus+O blocked Q U P tapped Q T Y U P L
sweep RBracket+Backslash blocked Y Space tapped Y H L N Space
sweep 9+O blocked - tapped 2 3 4 Equal L
sweep 9+L blocked - tapped 2 3 5 Equal I
sweep Y+T blocked RBracket tapped RBracket L N
sweep LBracket+K blocked F tapped O A F
sweep Semicolon+Slash blocked - tapped O F
sweep Minus+L blocked - tapped I F
sweep Equal+Slash blocked - tapped 0 L
sweep Equal+RBracket blocked - tapped 6 L
sweep LBracket+Comma blocked - tapped L X
sweep Space+Grave blocked 6 Y H N tapped 6 7 Y U P H J N M
"""#

/// The wiring as it was before the first Wiring Check (W E R S D G V B unplaced, Backslash and Grave misplaced).
let wiringBeforeCheck = #"""
# KeyChord keyboard wiring: the electrical matrix of the built-in keyboard.
# A cell is a Layout key name, "." for an empty spot (or one not known to hold a key),
# or "?" for a key that is not a chord key (Delete, Return, Tab, arrows...). Rows and columns are wires.
#
# Three keys in an L (two on a row, one of those on a column with the third) are dropped only when the
# fourth corner of the rectangle holds a key. The right-hand block below is full, so every L in it blocks;
# the left side has gaps, so most Ls there are fine.
#
# Columns are named after the number-row key on them.
version 1
hardware MacBookPro18,1
columns k1 k2 k3 k4 k5 k6 k7 k8 k9 k0 kEq kBs
row num      1  2  3  4  5  6        7     8        9      0         Equal ?
row top      Q  .  .  .  T  Y        U     I        O      P         .     .
row home     A  .  .  F  .  H        J     K        L      Semicolon .     .
row bottom   Z  X  C  .  .  N        M     Comma    Period Slash     .     .
row space    .  .  .  .  .  Space    Grave ?        .      Quote     .     .
row bracket  .  .  ?  .  .  RBracket ?     LBracket ?      ?         .     Backslash
row minus    .  ?  ?  .  .  .        .     ?        Minus  .         ?     .
# These never blocked anything in the scan: no other chord key shares a line with them where it matters.
solo W E R S D G V B
"""#

@Suite("Keyboard wiring")
struct KeyboardWiringTests {
    let layout = defaults.layout
    func code(_ n: String) -> KeyCode { layout.keys[layout.indexByName[n]!].code }
    func codes(_ spec: String) -> [KeyCode] { spec.split(separator: "+").map { code(String($0)) } }
    var wiring: KeyboardWiring { get throws { try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: layout) } }

    @Test("The MacBook Pro 2021 wiring explains the scan and the first check")
    func fitsTheScan() throws {
        let w = try wiring
        let scan = try #require(try MatrixScanReport.parse(macBookPro18Scan, layout: layout))
        let check = try #require(try MatrixScanReport.parse(macBookPro18Check1, layout: layout))
        let fit = w.fit(sweeps: scan.sweeps + check.sweeps, combos: scan.combos, layout: layout)
        print("wiring explains \(fit.explained) of \(fit.total)")
        for m in fit.mismatches { print("  " + m) }
        #expect(fit.total == 999)
        #expect(fit.explained == 998)
        // Grave sits on the far-left column (next to Z), so this one result from the first scan is off.
        #expect(fit.mismatches == ["H+J tap Grave: blocked, wiring says it registers"])
        // The wiring before the check got 27 of the check's taps wrong.
        let before = try KeyboardWiring.parse(wiringBeforeCheck, layout: layout)
        #expect(before.fit(sweeps: check.sweeps, combos: [], layout: layout).mismatches.count == 27)
    }

    @Test("The combinations that failed while typing, and the ones the old model got wrong")
    func knownCombinations() throws {
        let w = try wiring
        // Reported while typing the sample text.
        for bad in ["U+H+N+A+C", "W+K+J+M", "J+H+M"] { #expect(w.blocks(codes(bad)), "\(bad)") }
        // Found by the check: W and R share a row of their own, as do S and G, and D, V and B.
        #expect(w.tripleBlocked(code("W"), code("R"), code("2")))
        #expect(w.tripleBlocked(code("S"), code("G"), code("5")))
        #expect(w.tripleBlocked(code("D"), code("V"), code("3")))
        #expect(w.tripleBlocked(code("V"), code("B"), code("Backslash")))
        #expect(!w.tripleBlocked(code("W"), code("E"), code("3")))
        // An L whose fourth corner is empty registers (J+M+X: nothing at home row, column 2)...
        #expect(!w.tripleBlocked(code("J"), code("M"), code("X")))
        // ...and an L with a key at the fourth corner does not (Q+I+A: K is there).
        #expect(w.tripleBlocked(code("Q"), code("I"), code("A")))
        #expect(w.tripleBlocked(code("Q"), code("O"), code("A")))
        #expect(!w.blocks(codes("Q+I+O")))
        // Keys on one line never block.
        #expect(!w.blocks(codes("Y+U+I+O+P")))
    }

    @Test("Wiring text round trip and errors")
    func parsing() throws {
        let w = try wiring
        #expect(w.rows.count == 11 && w.columns.count == 11)
        #expect(w.solo.isEmpty)
        // Every chord key has a place.
        for k in layout.keys where k.name != "Space" || true { #expect(w.position[k.code] != nil, "\(k.name)") }
        #expect(w.table(layout: layout).contains("Semicolon"))
        #expect(throws: KeyboardWiring.ParseError.self) {
            try KeyboardWiring.parse("version 1\ncolumns a b\nrow r J\n", layout: layout)
        }
        #expect(throws: KeyboardWiring.ParseError.self) {
            try KeyboardWiring.parse("version 1\ncolumns a b\nrow r J J\n", layout: layout)
        }
    }

    @Test("Keyboard limits use the wiring")
    func limits() throws {
        let lim = try #require(KeyboardLimits(wiringText: DefaultData.wiringMacBookPro18, scanText: macBookPro18Scan,
                                              layout: layout))
        #expect(lim.wiring != nil)
        #expect(lim.blocks(codes("J+H+M")))
        #expect(!lim.blocks(codes("J+M+X")))
    }

    @Test("The scan report checks the wiring and lists blocked chords with it")
    func report() throws {
        let scan = try #require(try MatrixScanReport.parse(macBookPro18Scan, layout: layout))
        let model = MatrixModel(keys: layout.keys.map(\.code), sweeps: scan.sweeps)
        let text = MatrixScanReport.serialize(model: model, combos: scan.combos, layout: layout, hardware: "T",
                                              data: defaults, wiring: try wiring)
        #expect(text.contains("explains 565 of 566"))
        #expect(text.contains("syllables (onset+vowel+coda, 3+ keys):"))
        print(text.split(separator: "\n").filter { $0.hasPrefix("# syllables") || $0.contains("triples blocking") }.joined(separator: "\n"))
    }
}

@Suite("Default layout on the MacBook Pro 2021 keyboard")
struct DefaultsOnWiringTests {
    let layout = defaults.layout
    var wiring: KeyboardWiring { get throws { try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: layout) } }
    func codes(_ k: KeySet) -> [KeyCode] { k.indices.map { layout.keys[$0].code } }

    @Test("No cluster or dictionary chord is dropped")
    func nothingDropped() throws {
        let w = try wiring
        for bank in Bank.allCases {
            for (k, text) in layout.clusters[bank] ?? [:] { #expect(!w.blocks(codes(k)), "\(bank) \(text)") }
        }
        for (label, d) in [("shared", defaults.shared), ("english", defaults.english), ("c++", defaults.cpp)] {
            for (k, e) in d.entries { #expect(!w.blocks(codes(k)), "\(label) \(layout.chordString(k)) \(e)") }
        }
        // Fingerspelling: only the capitals of the four home-row letters that share the spell key's wires
        // (the Typing Guide uses Capitalize Next for those).
        var dropped: [String] = []
        for (k, letter) in layout.fingerspelling {
            var c = k
            c.insert(layout.spellIndex!)
            if w.blocks(codes(c)) { dropped.append(letter) }
        }
        #expect(dropped.sorted() == ["A", "H", "J", "K"])
    }

    @Test("Few syllable compositions are dropped, none with the most common vowels on the left thumb")
    func syllables() throws {
        let w = try wiring
        func opts(_ b: Bank) -> [KeySet] { [KeySet()] + (layout.clusters[b] ?? [:]).keys }
        var total = 0, dropped = 0
        for o in opts(.onset) {
            for v in opts(.vowel) {
                for c in opts(.coda) {
                    let k = o.union(v).union(c)
                    guard k.count >= 3 else { continue }
                    total += 1
                    if w.blocks(codes(k)) { dropped += 1 }
                }
            }
        }
        print("syllable compositions dropped: \(dropped) of \(total)")
        #expect(total == 35379)
        #expect(dropped == 3744)          // was 7143 before the retune
        // a, o and e (C, V, B) never share a wire with a right-hand key.
        for name in ["C", "V", "B"] {
            let v = layout.keySet(names: [name])!
            for (c, text) in layout.clusters[.coda] ?? [:] { #expect(!w.blocks(codes(v.union(c))), "\(name) + \(text)") }
        }
    }
}

@Suite("Dictionary warnings from the wiring")
struct WiringWarningTests {
    @Test("Defaults give no warnings; an edited chord the keyboard drops does")
    func warnings() {
        let clean = DictionaryLoader.load(sources: sources(), rolloverLimit: 6, wiring: DefaultData.wiringMacBookPro18)
        #expect(clean.problems.isEmpty)
        #expect(clean.droppedChords.isEmpty)
        let edited = DataFile.english.defaultSource + "\nJ+H+M = \"jhm\" word\n"
        let o = DictionaryLoader.load(sources: sources([.english: edited]), rolloverLimit: 6, wiring: DefaultData.wiringMacBookPro18)
        #expect(o.problems.isEmpty)
        #expect(o.droppedChords.count == 1)
        #expect(o.droppedChords.first?.file == "english.dict")
        #expect(o.droppedChords.first?.entry?.contains("jhm") == true)
        // No wiring file: no keyboard warnings; an unreadable one is reported.
        #expect(DictionaryLoader.load(sources: sources(), rolloverLimit: 6).droppedChords.isEmpty)
        #expect(DictionaryLoader.load(sources: sources(), rolloverLimit: 6, wiring: "nonsense").droppedChords.count == 1)
    }
}
