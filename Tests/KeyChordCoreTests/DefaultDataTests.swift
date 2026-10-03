import Testing
@testable import KeyChordCore

@Suite("Default layout and dictionaries")
struct DefaultDataTests {
    let l = defaults.layout

    func entry(_ d: ChordDictionary, text: String) -> [(KeySet, TextEntry)] {
        d.entries.compactMap { k, e in
            if case .text(let t) = e, t.text == text { return (k, t) }
            return nil
        }
    }

    func command(_ d: ChordDictionary, _ c: Command) -> KeySet? {
        d.entries.first { $0.value == .command(c) }?.key
    }

    @Test func loadsWithoutProblems() {
        let o = defaultOutcome()
        #expect(o.problems.isEmpty)
        #expect(o.fallbacks.isEmpty)
        #expect(Set(o.acceptedSources.keys) == Set(DataFile.allCases))
    }

    @Test("Req 4.2, 4.3, 4.4: banks on the MacBook keyboard, space bar, no modifiers")
    func layoutPlacement() {
        func role(_ code: KeyCode) -> KeyRole? { l.indexByCode[code].map { l.keys[$0].role } }
        #expect(role(49) == .space)
        for c: KeyCode in [8, 9, 45, 46] { #expect(role(c) == .bank(.vowel)) }        // C V N M
        for c: KeyCode in [12, 13, 14, 15, 17, 0, 1, 2, 3, 5] { #expect(role(c) == .bank(.onset)) }
        for c: KeyCode in [16, 32, 34, 31, 35, 4, 38, 40, 37] { #expect(role(c) == .bank(.coda)) }
        let digitCodes: [KeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, c) in digitCodes.enumerated() {
            #expect(role(c) == .number(Character(String((i + 1) % 10))))
        }
        for c in LayoutParser.forbiddenCodes { #expect(l.indexByCode[c] == nil) }
    }

    @Test("Req 4.6, 4.7: every chord fits the rollover limit")
    func rolloverLimit() {
        let sizes = Bank.allCases.map { l.largestClusterSize($0) }
        #expect(sizes.reduce(0, +) <= 6)
        for (_, chord, _) in DictionaryLoader.allChords(defaults) { #expect(chord.count <= 6) }
    }

    @Test("Req 7.5 - 7.8: required clusters")
    func clusters() {
        let consonants = "bcdfghjklmnpqrstvwxyz".map(String.init)
        let onset = Set(l.clusters[.onset]!.values), vowel = Set(l.clusters[.vowel]!.values), coda = Set(l.clusters[.coda]!.values)
        for c in consonants {
            #expect(onset.contains(c), "onset \(c)")
            #expect(coda.contains(c), "coda \(c)")
        }
        for v in ["a", "e", "i", "o", "u", "ea", "ee", "oo", "ou"] { #expect(vowel.contains(v), "vowel \(v)") }
        for o in ["bl", "br", "ch", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "sh", "sk", "sl", "sm",
                  "sn", "sp", "st", "sw", "th", "tr", "wh"] { #expect(onset.contains(o), "onset \(o)") }
        for c in ["ch", "ck", "ct", "ft", "ld", "ll", "lt", "mp", "nd", "ng", "nk", "nt", "rd", "rt", "sh", "ss",
                  "st", "th"] { #expect(coda.contains(c), "coda \(c)") }
    }

    @Test("Req 8.1: fingerspell every letter, both cases, in both modes")
    func fingerspelling() throws {
        for mode in SubMode.allCases {
            for letter in "abcdefghijklmnopqrstuvwxyz" {
                for s in [String(letter), String(letter).uppercased()] {
                    let k = try #require(l.fingerspelling.first { $0.value == s }?.key)
                    var chord = k
                    chord.insert(l.spellIndex!)
                    #expect(chord.count <= 6)
                    let r = try ChordEngine(data: defaults, subMode: mode).translate(chord, join: false)
                    #expect(r.actions == [.insert(s)], "\(mode) \(s)")
                }
            }
        }
    }

    @Test("Req 8.2: each digit is one number key")
    func digits() throws {
        for d in 0...9 {
            let k = try #require(l.keys.firstIndex { $0.role == .number(Character(String(d))) })
            for mode in SubMode.allCases {
                let r = try ChordEngine(data: defaults, subMode: mode).translate(KeySet([k]), join: false)
                #expect(r.actions == [.insert(String(d))])
            }
        }
    }

    @Test("Req 8.4: the 100 most frequent words are single chords")
    func top100Words() {
        #expect(top100.count == 100)
        #expect(Set(top100).count == 100)
        for w in top100 { #expect(chordProducing(w) != nil, "no chord for \(w)") }
    }

    @Test("Req 8.5: brief for I")
    func briefI() throws {
        let k = try #require(entry(defaults.english, text: "I").first)
        #expect(try ChordEngine(data: defaults).translate(k.0, join: false).actions == [.insert("I")])
    }

    @Test("Req 9.5, 9.6: English punctuation and its attachment")
    func englishPunctuation() throws {
        func one(_ text: String) throws -> TextEntry {
            let e = entry(defaults.english, text: text)
            try #require(!e.isEmpty, "missing \(text)")
            return e[0].1
        }
        for p in [".", ",", "?", "!", ":", ";"] {
            let t = try one(p)
            #expect(t.attachLeft && !t.attachRight, "\(p)")
        }
        for p in ["'", "-"] {
            let t = try one(p)
            #expect(t.attachLeft && t.attachRight, "\(p)")
        }
        let quotes = entry(defaults.english, text: "\"").map(\.1)
        #expect(quotes.count == 2)
        #expect(quotes.contains { $0.attachRight && !$0.attachLeft })
        #expect(quotes.contains { $0.attachLeft && !$0.attachRight })
        let open = try one("("), close = try one(")")
        #expect(open.attachRight && !open.attachLeft)
        #expect(close.attachLeft && !close.attachRight)
        // Sentence ends capitalize the next word; the Quote variants (abbreviations, "Mr. and") do not.
        for p in [".", "?", "!"] {
            let all = entry(defaults.english, text: p)
            #expect(all.count == 2, "\(p)")
            #expect(all.contains { $0.1.capitalizeNext && !$0.0.contains(defaults.layout.spellIndex!) }, "\(p)")
            #expect(all.contains { !$0.1.capitalizeNext && $0.0.contains(defaults.layout.spellIndex!) }, "\(p)")
        }
    }

    @Test("Req 10.10, 10.11: suffixes and exceptions")
    func suffixes() {
        for s in ["s", "ed", "ing", "er", "est", "ly", "ness", "ment", "able", "ful"] {
            #expect(entry(defaults.english, text: s).contains { $0.1.kind == .suffix }, "suffix \(s)")
        }
        #expect(defaults.orthographyExceptions["be+ing"] == "being")
        #expect(defaults.orthographyExceptions["begin+ing"] == "beginning")
        #expect(defaults.orthographyExceptions["tie+ing"] == "tying")
    }

    @Test("Req 11.1, 1.9: shared Undo and Mode_Switch reachable in both modes")
    func sharedCommands() throws {
        for c in [Command.undo, .modeSwitch, .capitalizeNext] {
            let k = try #require(command(defaults.shared, c))
            #expect(defaults.english[k] == nil)
            #expect(defaults.cpp[k] == nil)
        }
    }

    @Test("Req 12.1 - 12.7: C++ symbols and spacing flags")
    func cppSymbols() throws {
        let d = defaults.cpp
        let required = ["::", "->", ".", ",", ";", ":", "?", "=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*",
                        "/", "%", "+=", "-=", "*=", "/=", "++", "--", "&&", "||", "!", "&", "|", "^", "~", "<<",
                        ">>", "#", "(", ")", "[", "]", "{", "}"]
        for s in required { #expect(!entry(d, text: s).isEmpty, "missing \(s)") }

        func flags(_ t: TextEntry) -> String {
            (t.attachLeft ? "L" : "") + (t.attachRight ? "R" : "") + (t.wordAttach ? "W" : "")
        }
        func forms(_ s: String) -> Set<String> { Set(entry(d, text: s).map { flags($0.1) }) }

        for s in ["=", "==", "!=", "<=", ">=", "+", "/", "%", "+=", "-=", "*=", "/=", "&&", "||", "|", "^", "<<", ">>"] {
            #expect(forms(s) == [""], "binary \(s)")
        }
        for s in ["::", "->", "."] { #expect(forms(s) == ["LR"], "\(s)") }
        for s in ["(", "["] { #expect(forms(s) == ["RW"], "\(s)") }
        for s in [")", "]", ",", ";"] { #expect(forms(s) == ["L"], "\(s)") }
        for s in ["!", "~", "#"] { #expect(forms(s) == ["R"], "\(s)") }
        // Req 12.2: binary and unary forms; prefix/postfix; comparison/template brackets.
        for s in ["*", "&", "-"] { #expect(forms(s) == ["", "R"], "\(s)") }
        for s in ["++", "--"] { #expect(forms(s) == ["R", "L"], "\(s)") }
        #expect(forms("<") == ["", "RW"])
        #expect(forms(">") == ["", "L"])
    }

    @Test("Req 13.1 - 13.4, 14.1: keywords, snippets, casing chords")
    func cppKeywordsAndSnippets() throws {
        let d = defaults.cpp
        let keywords = ["auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default",
                        "delete", "double", "else", "enum", "false", "float", "int", "namespace", "new", "nullptr",
                        "override", "return", "sizeof", "static", "struct", "template", "this", "true",
                        "typename", "unsigned", "using", "virtual", "void"]
        for k in keywords {
            let e = entry(d, text: k)
            #expect(e.count == 1 && e[0].1.kind == .word, "\(k)")
            if let c = e.first { #expect(try ChordEngine(data: defaults, subMode: .cpp).translate(c.0, join: false).actions == [.insert(k)]) }
        }
        for k in ["private:", "protected:", "public:", "std::"] {
            let e = entry(d, text: k)
            #expect(e.count == 1 && e[0].1.kind == .symbol, "\(k)")
        }
        #expect(entry(d, text: "std::").first?.1.attachRight == true)

        let snippets: [(String, Int)] = [("#include <>", 1), ("#include \"\"", 1), ("static_cast<>(", 2),
                                         ("std::vector<>", 1), ("template <typename >", 1), ("if ()", 1),
                                         ("for ()", 1), ("while ()", 1), ("switch ()", 1), ("\"\"", 1), ("''", 1)]
        for (text, tail) in snippets {
            let e = entry(d, text: text)
            #expect(e.count == 1 && e[0].1.cursorFromEnd == tail, "\(text)")
        }
        for m in CasingMode.allCases { #expect(command(d, .casing(m)) != nil) }
        #expect(command(d, .endIdentifier) != nil)
        #expect(command(d, .snippetExit) != nil)
    }

    @Test("Req 4.8: layout reference lists roles and tables")
    func layoutReference() {
        let s = LayoutReference.render(l)
        #expect(s.contains("SPELL"))
        #expect(s.contains("vowel"))
        #expect(s.contains("T+S = st"))   // chord keys are listed in layout order
        #expect(s.contains("V+B = ea"))
        #expect(s.contains("Single letters (press Quote together with the keys)"))
    }
}
