import Testing
@testable import KeyChordCore

@Suite("Keyboard geometry: US (ANSI) and Canadian French (ISO)")
struct KeyboardGeometryTests {
    let layout = defaults.layout

    @Test("Every chord key is drawn, inside the keyboard, with no two keys overlapping", arguments: KeyboardGeometry.Kind.allCases)
    func complete(kind: KeyboardGeometry.Kind) {
        let g = KeyboardGeometry.of(kind)
        #expect(g.kind == kind)
        for k in layout.keys { #expect(g.key(for: k.code) != nil, "\(k.name) is not drawn") }
        for k in g.keys {
            #expect(k.x >= 0 && k.y >= 0, "\(k.label)")
            #expect(k.x + k.width <= KeyboardGeometry.width + 1e-9 && k.y + k.height <= KeyboardGeometry.height + 1e-9,
                    "\(k.label) sticks out")
        }
        // The ISO Return key is an L: its bounding box reaches over the key left of it on the A row.
        let boxes = g.keys.filter { g.returnOutline == nil || $0.code != KeyboardGeometry.returnCode }
        for (i, a) in boxes.enumerated() {
            for b in boxes[(i + 1)...] {
                let overlap = a.x < b.x + b.width - 1e-9 && b.x < a.x + a.width - 1e-9
                    && a.y < b.y + b.height - 1e-9 && b.y < a.y + a.height - 1e-9
                #expect(!overlap, "\(a.label) (\(a.code)) and \(b.label) (\(b.code)) overlap")
            }
        }
    }

    @Test("Where the two layouts differ")
    func differences() throws {
        let us = KeyboardGeometry.ansi, iso = KeyboardGeometry.iso
        /// x, y, width, height.
        func at(_ g: KeyboardGeometry, _ code: KeyCode) throws -> [Double] {
            let k = try #require(g.key(for: code))
            return [k.x, k.y, k.width, k.height]
        }
        // US: ` left of 1, \ at the end of the Q row, Return one row tall, no section key, wide left Shift.
        #expect(try at(us, 50) == [0, 0.7, 1, 1])
        #expect(try at(us, 42) == [13.5, 1.7, 1, 1])
        #expect(try at(us, KeyboardGeometry.returnCode) == [12.75, 2.7, 1.75, 1])
        #expect(try at(us, 56) == [0, 3.7, 2.25, 1])
        #expect(us.key(for: 10) == nil)
        #expect(us.returnOutline == nil)
        // ISO: ` between left Shift and Z, \ left of Return, the section key left of 1, an L-shaped Return.
        #expect(try at(iso, 50) == [1.25, 3.7, 1, 1])
        #expect(try at(iso, 42) == [12.75, 2.7, 1, 1])
        #expect(try at(iso, 10) == [0, 0.7, 1, 1])
        #expect(iso.returnOutline?.count == 6)
        // Every other chord key is in the same place on both.
        for k in layout.keys where k.code != 50 && k.code != 42 {
            #expect(try at(us, k.code) == at(iso, k.code), "\(k.name)")
        }
    }

    @Test("Chords are named by the legends of the keyboard")
    func legends() {
        let us = KeyboardGeometry.ansi, iso = KeyboardGeometry.iso
        let expected: [(KeyCode, String, String)] = [(50, "`", "Ù"), (42, "\\", "À"), (39, "'", "È"), (44, "/", "É"),
                                                     (33, "[", "^"), (30, "]", "Ç"), (41, ";", ";"), (0, "A", "A"),
                                                     (49, "Space", "Space")]
        for (code, a, i) in expected {
            #expect(us.label(for: code) == a)
            #expect(iso.label(for: code) == i)
        }
        #expect(us.key(for: 22)?.shifted == "^")
        #expect(iso.key(for: 22)?.shifted == "?")
        #expect(us.name == "US (ANSI)")
    }

    @Test("The manual shows the keyboard it is given")
    func manual() {
        let us = Manual.html(data: defaults, keyboard: .ansi)
        let iso = Manual.html(data: defaults, keyboard: .iso)
        #expect(us.contains("show the MacBook Pro's US keyboard"))
        #expect(iso.contains("show the MacBook Pro's Canadian French keyboard"))
        // The ISO Return key is drawn as an L; the spell key (Quote) is named by its legend.
        #expect(iso.contains("<polygon") && !us.contains("<polygon"))
        #expect(us.contains(">'</kbd>") && !us.contains(">È</kbd>"))
        #expect(iso.contains(">È</kbd>"))
    }
}

@Suite("US (ANSI) wiring of the MacBook Pro 2021")
struct ANSIWiringTests {
    let layout = defaults.layout
    func code(_ n: String) -> KeyCode { layout.keys[layout.indexByName[n]!].code }
    var iso: KeyboardWiring { get throws { try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: layout) } }
    var us: KeyboardWiring { get throws { try KeyboardWiring.parse(DefaultData.wiringMacBookPro18ANSI, layout: layout) } }

    @Test("The ISO wiring without Grave and Backslash, their spots still counted as keys")
    func derived() throws {
        let iso = try iso, us = try us
        #expect(us.rows == iso.rows && us.columns == iso.columns)
        #expect(us.solo.isEmpty)
        let moved: Set<KeyCode> = [code("Grave"), code("Backslash")]
        for c in moved { #expect(us.position[c] == nil) }
        for k in layout.keys where !moved.contains(k.code) { #expect(us.position[k.code] == iso.position[k.code], "\(k.name)") }
        #expect(us.occupied == iso.occupied)
        #expect(us.otherKeys == iso.otherKeys.union(moved.compactMap { iso.position[$0] }))
        #expect(us.hardware.contains("not measured"))
    }

    @Test("Same results as ISO for every 3 keys without Grave or Backslash; those never drop")
    func sameResults() throws {
        let iso = try iso, us = try us
        let moved: Set<KeyCode> = [code("Grave"), code("Backslash")]
        let shared = layout.keys.map(\.code).filter { !moved.contains($0) }
        var dropped = 0
        for i in 0..<shared.count {
            for j in (i + 1)..<shared.count {
                for k in (j + 1)..<shared.count {
                    let a = shared[i], b = shared[j], c = shared[k]
                    let d = us.tripleBlocked(a, b, c)
                    #expect(d == iso.tripleBlocked(a, b, c))
                    if d { dropped += 1 }
                }
            }
        }
        #expect(dropped == 607)   // as macbook-keyboard-matrix's derived US data says
        // Dropped on ISO because ` or \ sits at the fourth corner; still predicted to drop on US.
        #expect(us.tripleBlocked(code("Q"), code("Y"), code("Space")))
        #expect(us.tripleBlocked(code("T"), code("Y"), code("RBracket")))
        // Not placed, so never predicted to drop (on ISO, V+B+Backslash drops).
        #expect(iso.tripleBlocked(code("V"), code("B"), code("Backslash")))
        #expect(!us.tripleBlocked(code("V"), code("B"), code("Backslash")))
    }

    @Test("No default chord is dropped, and the same capitals as on ISO need Capitalize Next")
    func defaultsOnUS() throws {
        let w = try us
        func codes(_ k: KeySet) -> [KeyCode] { k.indices.map { layout.keys[$0].code } }
        for bank in Bank.allCases {
            for (k, text) in layout.clusters[bank] ?? [:] { #expect(!w.blocks(codes(k)), "\(bank) \(text)") }
        }
        for (label, d) in [("shared", defaults.shared), ("english", defaults.english), ("c++", defaults.cpp)] {
            for (k, e) in d.entries { #expect(!w.blocks(codes(k)), "\(label) \(layout.chordString(k)) \(e)") }
        }
        var capitals: [String] = []
        for (k, letter) in layout.fingerspelling {
            var c = k
            c.insert(layout.spellIndex!)
            if w.blocks(codes(c)) { capitals.append(letter) }
        }
        #expect(capitals.sorted() == ["A", "H", "J", "K"])
        var sources: [DataFile: String?] = [:]
        for f in DataFile.allCases { sources[f] = f.defaultSource }
        #expect(DictionaryLoader.load(sources: sources, rolloverLimit: 6, wiring: DefaultData.wiringMacBookPro18ANSI)
            .droppedChords.isEmpty)
    }

    @Test("The bundled wiring follows the Mac model and the keyboard layout")
    func bundled() {
        #expect(DefaultData.bundledWiring(model: "MacBookPro18,1", keyboard: .iso) == DefaultData.wiringMacBookPro18)
        #expect(DefaultData.bundledWiring(model: "MacBookPro18,3", keyboard: .ansi) == DefaultData.wiringMacBookPro18ANSI)
        #expect(DefaultData.bundledWiring(model: "MacBookPro18,2", keyboard: nil) == nil)    // JIS or unknown
        #expect(DefaultData.bundledWiring(model: "MacBookPro17,1", keyboard: .ansi) == nil)  // another keyboard
        #expect(DefaultData.bundledWirings.contains(DefaultData.wiringMacBookPro18))
        #expect(DefaultData.bundledWirings.contains(DefaultData.wiringMacBookPro18ANSI))
    }
}
