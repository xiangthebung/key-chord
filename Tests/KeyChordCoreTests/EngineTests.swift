import Testing
@testable import KeyChordCore

// Chord specs in the default layout.
let THE = "T+E+B"            // th + e
let CAT = "E+D+C+J"          // c + a + t
let STOP = "S+T+V+P"         // st + o + p
let MAKE = "F+G+C+K+Slash"   // m + a + ke
let TRY = "T+R+Y"            // tr + y
let BOX = "X+V+Slash+Y"      // b + o + x
let GET = "G+B+J"            // g + e + t
let ING = "K+L", S_SUFFIX = "Semicolon", ED = "O"
let UNDO = "Backslash"
let EXIT = "RBracket+Backslash"

@Suite("Chord engine")
struct EngineTests {
    @Test("Req 7: syllable composition, onset + vowel + coda")
    func composition() throws {
        let d = Driver()
        try d.chord(STOP)
        #expect(d.text == "stop")
        let e = Driver()
        try e.chord(TRY)           // empty vowel bank
        #expect(e.text == "try")
    }

    @Test("Req 7.3, 6.8: unknown bank subset is untranslatable")
    func untranslatable() throws {
        let d = Driver()
        let r = try d.chord("U+I+O")
        #expect(r.actions.isEmpty)
        #expect(r.signal == .untranslatable)
        #expect(d.engine.undoDepth == 0)
        let r2 = try d.chord("1+C")   // number + vowel: no rule applies
        #expect(r2.signal == .untranslatable)
    }

    @Test("Req 9.1, 9.2: spacing and sentence capitalization")
    func spacingAndCapitalization() throws {
        let d = Driver()
        try d.chords(THE, CAT, "Period", THE, "Comma", CAT)
        #expect(d.text == "the cat. The, cat")
    }

    @Test("Req 9.4: no automatic capitalization in C++ mode")
    func noAutoCapInCpp() throws {
        var data = defaults
        data.cpp = data.english
        let d = Driver(.cpp, data: data)
        try d.chords(THE, "Period", THE)
        #expect(d.text == "the. the")
    }

    @Test("Req 9.3: Capitalize_Next")
    func capitalizeNext() throws {
        for mode in SubMode.allCases {
            let d = Driver(mode)
            try d.chords("N+M", THE, CAT)
            #expect(d.text == "The cat")
        }
    }

    @Test("Req 9.10: Caps Lock uppercases what a chord types")
    func capsLock() throws {
        let d = Driver()
        try d.chord(THE, capsLock: true)
        try d.chord("Period", capsLock: true)
        try d.chord(CAT, capsLock: true)
        try d.chord(THE)                                   // Caps Lock off again; the sentence capital was used
        #expect(d.text == "THE. CAT the")

        let s = Driver()
        for spec in [STOP, ING, MAKE, ING, TRY, ED, BOX, S_SUFFIX] { try s.chord(spec, capsLock: true) }
        #expect(s.text == "STOPPING MAKING TRIED BOXES")

        let f = Driver()                                   // fingerspelling and digits
        for spec in ["Quote+K", "Quote+E", "1"] { try f.chord(spec, capsLock: true) }
        #expect(f.text == "KE1")

        let m = Driver()                                   // only the text the chord types changes case
        try m.chord(MAKE)
        try m.chord(ING, capsLock: true)
        #expect(m.text == "makING")

        let u = Driver()
        try u.chord(MAKE, capsLock: true)
        try u.chord(ING, capsLock: true)
        try u.chord(UNDO)
        #expect(u.text == "MAKE")
        try u.chord(UNDO)
        #expect(u.text == "")

        var data = defaults                                // uppercase that is longer: counts follow it
        data.english.entries[keys("Quote+Z+X")] = .text(TextEntry(text: "straße", kind: .word))
        let g = Driver(.english, data: data)
        try g.chord("Quote+Z+X", capsLock: true)
        #expect(g.text == "STRASSE")
        #expect(try g.chord(UNDO).actions == [.deleteBackward(7)])

        let c = Driver(.cpp)                               // snippets keep the cursor in place
        try c.chord("Quote+I+F", capsLock: true)
        #expect(c.buffer.description == "IF (|)")
        var cdata = defaults
        cdata.cpp.entries[keys("Quote+Z+X")] = .text(TextEntry(text: "ßxß", cursorFromEnd: 1, kind: .symbol))
        let t = Driver(.cpp, data: cdata)
        try t.chord("Quote+Z+X", capsLock: true)
        #expect(t.buffer.description == "SSX|SS")
        try t.chord(UNDO)
        #expect(t.buffer.description == "|")
    }

    @Test("Req 8.3, 6.5, 6.6: glue for fingerspelling and digits")
    func glue() throws {
        let d = Driver()
        try d.chords("Quote+K", "Quote+E", "Quote+Y", THE, "1", "2", "3+1")
        #expect(d.text == "key the 1213")
        let e = Driver()
        try e.chords("Quote+A+Semicolon", "Quote+B")
        #expect(e.text == "Ab")
    }

    @Test("Req 3.6, 9.1: Join flag attaches without a space")
    func join() throws {
        let d = Driver()
        try d.chord(THE)
        try d.chord(CAT, join: true)                         // Shift
        try d.chord("Space+" + THE)                          // the space bar with the chord
        #expect(d.text == "thecatthe")
    }

    @Test("Req 6.1, 6.2: space key alone types a space; with other keys it joins")
    func spaceKey() throws {
        let d = Driver()
        try d.chords(THE, "Space", CAT, "Space+" + THE, CAT)
        #expect(d.text == "the catthe cat")
        let e = Driver()
        try e.chords("Space", "Space")
        #expect(e.text == "  ")
    }

    @Test("Req 10: suffixes use orthography rules")
    func suffixes() throws {
        let d = Driver()
        try d.chords(STOP, ING, MAKE, ING, TRY, ED, BOX, S_SUFFIX)
        #expect(d.text == "stopping making tried boxes")
        let e = Driver()
        try e.chords(S_SUFFIX)        // Req 10.9: unknown previous word
        #expect(e.text == "s")
        let f = Driver()
        try f.chords(THE, "Period", MAKE, ING)
        #expect(f.text == "the. Making")
    }

    @Test("Req 10.2 - 10.8: orthography rules")
    func orthography() {
        let ex = defaults.orthographyExceptions
        func a(_ w: String, _ s: String) -> String { Orthography.attach(word: w, suffix: s, exceptions: ex) }
        #expect(a("agree", "ed") == "agreed")
        #expect(a("make", "ing") == "making")
        #expect(a("try", "ed") == "tried")
        #expect(a("try", "s") == "tries")
        #expect(a("try", "ing") == "trying")
        #expect(a("happy", "ness") == "happiness")
        #expect(a("box", "s") == "boxes")
        #expect(a("church", "s") == "churches")
        #expect(a("wish", "s") == "wishes")
        #expect(a("stop", "ing") == "stopping")
        #expect(a("big", "est") == "biggest")
        #expect(a("look", "ing") == "looking")
        #expect(a("help", "ed") == "helped")
        #expect(a("fix", "ing") == "fixing")
        #expect(a("play", "ed") == "played")
        #expect(a("see", "ing") == "seeing")
        #expect(a("stop", "s") == "stops")
        #expect(a("be", "ing") == "being")
        #expect(a("begin", "ing") == "beginning")
        #expect(a("tie", "ing") == "tying")
        #expect(a("Begin", "ing") == "Beginning")
        #expect(a("STOP", "ing") == "STOPPing")
        #expect(a("Try", "ed") == "Tried")
        #expect(a("TRY", "s") == "TRIes")
        #expect(a("Make", "ing") == "Making")
    }

    @Test("Req 11: undo reverses one chord and restores context")
    func undo() throws {
        let d = Driver()
        try d.chords(THE, CAT, "Period", UNDO, CAT)
        #expect(d.text == "the cat cat")                 // capitalization from "." was undone
        try d.chords(UNDO, UNDO, UNDO)
        #expect(d.text == "")
        let r = try d.chord(UNDO)
        #expect(r.signal == .undoEmpty && r.actions.isEmpty)   // Req 11.5
        let e = Driver()
        try e.chords(MAKE, ING, UNDO)
        #expect(e.text == "make")
        try e.chord(ED)
        #expect(e.text == "maked")
    }

    @Test("Req 11.4: keeps at least 100 records")
    func undoCapacity() throws {
        let d = Driver()
        for _ in 0..<150 { try d.chord("Quote+A") }
        #expect(d.engine.undoDepth >= 100)
        for _ in 0..<100 { try d.chord(UNDO) }
        #expect(d.text.count == 50)
    }

    @Test("Req 9.8, 9.9: context reset")
    func contextReset() throws {
        let d = Driver()
        try d.chords(THE, "Period")
        d.engine.contextReset()
        try d.chords(CAT, S_SUFFIX)
        #expect(d.text == "the.Cats")                     // no leading space, capitalization kept
        d.engine.contextReset()
        let r = try d.chord(UNDO)
        #expect(r.signal == .undoEmpty)
    }

    @Test("Req 1.9: Mode_Switch toggles the sub-mode")
    func modeSwitch() throws {
        let d = Driver()
        try d.chord(THE)
        let r = try d.chord("LBracket+RBracket")
        #expect(r.modeSwitched)
        #expect(d.engine.subMode == .cpp)
        #expect(d.engine.undoDepth == 0)
        try d.chord("LBracket+RBracket")
        #expect(d.engine.subMode == .english)
    }

    @Test("Req 12: C++ operator spacing")
    func cppSpacing() throws {
        let d = Driver(.cpp)
        try d.chords(THE, "Equal", CAT, "Semicolon", THE, "LBracket", CAT, "Comma", "Quote+8+Comma", THE,
                     "RBracket", "Period", CAT, "Minus+Period", STOP, "Quote+Minus+Semicolon+Period", "Semicolon")
        #expect(d.text == "the = cat; the(cat, *the).cat->stop++;")
        let e = Driver(.cpp)
        try e.chords("Quote+S+D", THE, "Semicolon+Comma", CAT, "Comma+LBracket", THE, "Period+RBracket", CAT)
        #expect(e.text == "std::the::cat<the> cat")
    }

    @Test("Req 13.5 - 13.8: snippets and snippet exit")
    func snippets() throws {
        let d = Driver(.cpp)
        try d.chord("Quote+I+F")
        #expect(d.buffer.description == "if (|)")
        try d.chords("Quote+X", "Equal", "1")
        #expect(d.buffer.description == "if (x = 1|)")
        try d.chord(EXIT)
        #expect(d.buffer.description == "if (x = 1)|")
        try d.chord("Quote+LBracket")
        #expect(d.buffer.description == "if (x = 1) {|")
        try d.chords(UNDO, UNDO)
        #expect(d.buffer.description == "if (x = 1|)")

        let n = Driver(.cpp)
        try n.chords("Quote+S+C+T", "M+H+J", EXIT, "Quote+X", "RBracket")
        #expect(n.buffer.description == "static_cast<int>(x)|")

        let nested = Driver(.cpp)
        try nested.chords("Quote+I+F", "Quote+LBracket+RBracket", "Quote+A", EXIT, EXIT)
        #expect(nested.buffer.description == "if (\"a\")|")

        let none = Driver(.cpp)
        let r = try none.chord(EXIT)
        #expect(r.signal == .untranslatable)
    }

    @Test("Req 14: identifier casing")
    func casing() throws {
        func run(_ mode: String, _ specs: [String]) throws -> String {
            let d = Driver(.cpp)
            try d.chord("M+H+J")         // "int", then the identifier
            try d.chord(mode)
            for s in specs { try d.chord(s) }
            return d.text
        }
        #expect(try run("Grave+S", [GET, THE, CAT]) == "int get_the_cat")
        #expect(try run("Grave+C", [GET, THE, CAT]) == "int getTheCat")
        #expect(try run("Grave+P", [GET, THE, CAT]) == "int GetTheCat")
        #expect(try run("Grave+A", [GET, THE, CAT]) == "int GET_THE_CAT")
        // Req 14.7: glue runs are one word, digits append without separator.
        #expect(try run("Grave+C", [GET, "Quote+X", "Quote+M", "Quote+L", "2"]) == "int getXml2")
        #expect(try run("Grave+S", [GET, "Quote+X", "Quote+M", "Quote+L", CAT]) == "int get_xml_cat")
        // Req 14.9: a symbol ends the identifier; End_Identifier too.
        #expect(try run("Grave+S", [GET, CAT, "Semicolon", THE, CAT]) == "int get_cat; the cat")
        #expect(try run("Grave+C", [GET, CAT, "Grave", THE]) == "int getCat the")
        // Join continues the current word.
        let d = Driver(.cpp)
        try d.chords("Grave+C", GET)
        try d.chord(CAT, join: true)
        try d.chord(THE)
        #expect(d.text == "getcatThe")
        // Context reset ends casing.
        let e = Driver(.cpp)
        try e.chords("Grave+S", GET)
        e.engine.contextReset()
        try e.chord(CAT)
        #expect(e.text == "getcat")
    }

    // MARK: Properties

    static let englishPool = [THE, CAT, STOP, MAKE, TRY, BOX, GET, "Period", "Comma", "Quote+LBracket", "Quote+RBracket",
                              "Minus", "Quote", ING, S_SUFFIX, ED, "L+Y", "Space", "Quote+K", "Quote+E+Semicolon",
                              "1", "2+3", "M", "Quote+A+B", "N+M", "Space+" + CAT]
    static let cppPool = [THE, CAT, GET, "Quote+I+F", "Quote+S+C+T", "Quote", "Quote+LBracket+RBracket", EXIT,
                          "Equal", "Semicolon", "LBracket", "RBracket", "Period", "Quote+X", "1", "Grave+S",
                          "Grave+C", "Grave+P", "Grave+A", "Grave", "Quote+3+Comma", "Quote+8+Comma", "Space"]

    @Test("Req 11.7: N chords then N undos restore text and cursor", arguments: [SubMode.english, .cpp])
    func undoProperty(mode: SubMode) throws {
        var rng = SplitMix64(seed: mode == .english ? 7 : 11)
        let pool = mode == .english ? Self.englishPool : Self.cppPool
        for _ in 0..<200 {
            let d = Driver(mode)
            d.buffer = TextBuffer("abc def", cursor: 3)
            let original = d.buffer
            let n = Int.random(in: 1...100, using: &rng)
            var recorded = 0
            while recorded < n {
                let before = d.engine.undoDepth
                try d.chord(pool.randomElement(using: &rng)!)
                recorded += d.engine.undoDepth - before
            }
            #expect(d.engine.undoDepth == n)
            for _ in 0..<n { try d.chord(UNDO) }
            #expect(d.buffer == original, "\(d.buffer)")
        }
    }

    @Test("Req 3.4, 19.5: output is independent of press/release order")
    func orderIndependence() throws {
        var rng = SplitMix64(seed: 42)
        let l = defaults.layout
        var chords = Array(defaults.english.entries.keys) + Array(defaults.cpp.entries.keys) + Array(defaults.shared.entries.keys)
        let chordKeys = (0..<l.keys.count).filter { _ in true }
        for _ in 0..<300 {
            let size = Int.random(in: 1...6, using: &rng)
            chords.append(KeySet(chordKeys.shuffled(using: &rng).prefix(size)))
        }
        for mode in SubMode.allCases {
            for chord in chords {
                let join = Bool.random(using: &rng)
                let expected = try ChordEngine(data: defaults, subMode: mode).translate(chord, join: join)
                for _ in 0..<5 {
                    let e = ChordEngine(data: defaults, subMode: mode)
                    var toPress = chord.indices.shuffled(using: &rng)
                    var held: [Int] = []
                    var result: EngineResult?
                    var first = true
                    while !toPress.isEmpty || !held.isEmpty {
                        let mustPress = held.isEmpty || (held.count == 1 && !toPress.isEmpty)
                        if !toPress.isEmpty && (mustPress || Bool.random(using: &rng)) {
                            let k = toPress.removeLast()
                            e.keyDown(k, shift: join && first)
                            first = false
                            held.append(k)
                        } else {
                            let k = held.remove(at: Int.random(in: 0..<held.count, using: &rng))
                            if let r = try e.keyUp(k) { result = r }
                        }
                    }
                    #expect(result == expected, "\(l.chordString(chord))")
                }
            }
        }
    }

    @Test("Req 14.3 - 14.6: casing modes for random word sequences")
    func casingProperty() throws {
        var rng = SplitMix64(seed: 3)
        let words: [(String, String)] = [(THE, "the"), (CAT, "cat"), (GET, "get"), (STOP, "stop"), (TRY, "try"), (BOX, "box")]
        let modes: [(String, CasingMode)] = [("Grave+S", .snake), ("Grave+C", .camel), ("Grave+P", .pascal), ("Grave+A", .screamingSnake)]
        for _ in 0..<200 {
            let (spec, mode) = modes.randomElement(using: &rng)!
            let seq = (0..<Int.random(in: 1...6, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            let d = Driver(.cpp)
            try d.chord(spec)
            for w in seq { try d.chord(w.0) }
            let parts = seq.map(\.1)
            let expected: String
            switch mode {
            case .snake: expected = parts.joined(separator: "_")
            case .screamingSnake: expected = parts.joined(separator: "_").uppercased()
            case .camel: expected = parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            case .pascal: expected = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            }
            #expect(d.text == expected)
            let n = d.engine.undoDepth
            for _ in 0..<n { try d.chord(UNDO) }
            #expect(d.text == "")
        }
    }

    @Test("Req 19.2: deterministic")
    func deterministic() throws {
        func run() throws -> [OutputAction] {
            let d = Driver()
            var all: [OutputAction] = []
            for s in Self.englishPool { all += try d.chord(s).actions }
            return all
        }
        #expect(try run() == run())
    }

    @Test("Req 16.6: counts are grapheme clusters")
    func graphemes() throws {
        var data = defaults
        data.english.entries[keys("Quote+Z+X")] = .text(TextEntry(text: "café👍🏽", kind: .word))
        let d = Driver(.english, data: data)
        try d.chord("Quote+Z+X")
        let r = try d.chord(UNDO)
        #expect(r.actions == [.deleteBackward(5)])
    }

    @Test("Req 3.8 - 3.11: discard and ignore")
    func discard() throws {
        let e = ChordEngine(data: defaults)
        let t = keys("T").indices[0], n = keys("N").indices[0]
        #expect(try e.keyUp(t) == nil)                   // release without press
        e.keyDown(t, shift: false)
        e.discardChord()
        #expect(try e.keyUp(t) == nil)
        e.keyDown(t, shift: false)
        e.keyDown(n, shift: false)
        e.syncPhysical(held: [])                          // none physically held
        #expect(!e.chordInProgress)
        e.keyDown(t, shift: false)
        e.syncPhysical(held: [t])
        #expect(e.chordInProgress)
    }
}
