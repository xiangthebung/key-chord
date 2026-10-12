// The KeyChord manual, as an HTML page. The text is written here; the keyboard picture, the tables and every
// example chord come from the current layout and dictionaries, and the examples from the TypingPlanner, so the
// reference always shows chords that type what it says. Links open the one Practice window.
// Standard library only.

public enum Manual {
    /// `keyboard` is the keyboard the pictures show and whose legends name the keys.
    public static func html(data: EngineData, rolloverLimit: Int = 6, usable: @escaping (KeySet) -> Bool = { _ in true },
                            keyboard: KeyboardGeometry = .ansi) -> String {
        Builder(data: data, rolloverLimit: rolloverLimit, usable: usable, geometry: keyboard).page()
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    private struct Builder {
        let data: EngineData
        let layout: Layout
        let english: KeyMeanings
        let cpp: KeyMeanings
        let englishPlanner: TypingPlanner
        let cppPlanner: TypingPlanner
        let usable: (KeySet) -> Bool
        let geometry: KeyboardGeometry

        init(data: EngineData, rolloverLimit: Int, usable: @escaping (KeySet) -> Bool, geometry: KeyboardGeometry) {
            self.data = data
            self.usable = usable
            self.geometry = geometry
            layout = data.layout
            english = KeyMeanings(data: data, mode: .english)
            cpp = KeyMeanings(data: data, mode: .cpp)
            englishPlanner = TypingPlanner(data: data, mode: .english, rolloverLimit: rolloverLimit, usable: usable)
            cppPlanner = TypingPlanner(data: data, mode: .cpp, rolloverLimit: rolloverLimit, usable: usable)
        }

        // MARK: Pieces

        func code(_ index: Int) -> KeyCode { layout.keys[index].code }
        func legend(_ index: Int) -> String { geometry.label(for: code(index)) }
        func index(_ name: String) -> Int? { layout.indexByName[name] }

        func kbd(_ index: Int, role: String? = nil) -> String {
            let r = role ?? english.keys[code(index)]?.role.rawValue ?? "special"
            return "<kbd class=\"\(r)\">\(esc(legend(index)))</kbd>"
        }

        func keys(_ set: KeySet, role: String? = nil) -> String {
            set.indices.map { kbd($0, role: role) }.joined()
        }

        func keysByName(_ names: [String], role: String?) -> String {
            names.compactMap(index).map { kbd($0, role: role) }.joined()
        }

        func part(_ keysHTML: String, _ means: String, _ role: String) -> String {
            "<span class=\"part\"><span class=\"keys\">\(keysHTML)</span><span class=\"means \(role)\">\(esc(means))</span></span>"
        }

        func chord(_ parts: [String]) -> String {
            "<span class=\"chord\">" + parts.joined(separator: "<span class=\"plus\">+</span>") + "</span>"
        }

        func exampleBox(_ text: String, _ chords: [String]) -> String {
            "<div class=\"example\"><span class=\"word\">\(esc(text))</span><span class=\"eq\">=</span>"
                + chords.joined(separator: "<span class=\"then\">then</span>") + "</div>"
        }

        /// The chords that type `text`, each broken into what its keys stand for, then the result.
        func example(_ text: String, mode: SubMode = .english) -> String {
            let g = (mode == .english ? englishPlanner : cppPlanner).plan(text)
            var chords: [String] = []
            for s in g.steps {
                switch s.action {
                case let .chord(names, shift):
                    var parts = s.parts.map { p -> String in
                        let role = partRole(p.role)
                        return part(keysByName(p.keys, role: role), p.text == " " ? "space" : p.text, role)
                    }
                    if parts.isEmpty { parts = [keysByName(names, role: nil)] }
                    if shift { parts.insert(part("<kbd class=\"mod\">⇧</kbd>", "join", "plain"), at: 0) }
                    chords.append(chord(parts))
                case .key(let k):
                    let label = k == .returnKey ? "↩" : k == .tab ? "⇥" : "⌫"
                    chords.append("<span class=\"chord\"><span class=\"part\"><span class=\"keys\"><kbd class=\"mod\">\(label)</kbd></span>"
                                  + "<span class=\"means\">\(esc(k.rawValue))</span></span></span>")
                case .typeNormally(let t):
                    chords.append("<span class=\"chord\">type “\(esc(t))” normally</span>")
                }
            }
            return exampleBox(text, chords)
        }

        /// The first of `words` that can be spelled letter by letter on this keyboard, spelled that way:
        /// spell + the letter's key for each letter (with the capital key for capitals), checked with the engine.
        func spelled(_ words: [String]) -> String {
            guard let spell = layout.spellIndex else { return "" }
            candidates: for word in words {
                let engine = ChordEngine(data: data, subMode: .english)
                var typed = "", chords: [String] = []
                for c in word {
                    guard let letterKeys = layout.fingerspelling.first(where: { $0.value == String(c) })?.key else {
                        continue candidates
                    }
                    var k = letterKeys
                    k.insert(spell)
                    guard usable(k), let r = try? engine.translate(k, join: false) else { continue candidates }
                    for a in r.actions { if case .insert(let t) = a { typed += t } }
                    var parts = [part(kbd(spell, role: "spell"), "spell", "spell")]
                    let lower = String(c).lowercased()
                    if lower != String(c), let capital = english.capitalKey, letterKeys.contains(capital) {
                        parts.append(part(kbd(capital, role: "special"), "capital", "special"))
                        parts.append(part(keys(letterKeys.subtracting(KeySet([capital])), role: "plain"), lower, "plain"))
                    } else {
                        parts.append(part(keys(letterKeys, role: "plain"), String(c), "plain"))
                    }
                    chords.append(chord(parts))
                }
                if typed == word { return exampleBox(word, chords) }
            }
            return ""
        }

        func partRole(_ r: TypingStep.Part.Role) -> String {
            switch r {
            case .onset, .vowel, .coda, .spell: return r.rawValue
            case .capital, .suffix, .symbol, .command: return "special"
            case .digit, .space, .join: return "number"
            case .word, .letter: return "plain"
            }
        }

        /// A table of chords: keys, then what they type or do.
        func table(_ rows: [(KeySet, String)], role: String? = nil, wide: Bool = false) -> String {
            let cells = rows.map { "<div class=\"cell\"><span class=\"keys\">\(keys($0.0, role: role))</span><span class=\"out\">\(esc($0.1))</span></div>" }
            return "<div class=\"grid\(wide ? " wide" : "")\">" + cells.joined() + "</div>"
        }

        func entries(_ d: ChordDictionary, _ keep: (TextEntry) -> Bool) -> [(KeySet, TextEntry)] {
            d.entries.compactMap { k, e -> (KeySet, TextEntry)? in
                if case .text(let t) = e, keep(t) { return (k, t) }
                return nil
            }.sorted { ($0.1.text.lowercased(), $0.0.count, $0.0.bits) < ($1.1.text.lowercased(), $1.0.count, $1.0.bits) }
        }

        func commands(_ d: ChordDictionary) -> [(KeySet, String)] {
            d.entries.compactMap { k, e -> (KeySet, String)? in
                guard case .command(let c) = e else { return nil }
                return (k, KeyMeanings.describe(c))
            }.sorted { ($0.0.count, $0.0.bits) < ($1.0.count, $1.0.bits) }
        }

        func clusters(_ bank: Bank) -> [(KeySet, String)] {
            (layout.clusters[bank] ?? [:]).map { ($0.key, $0.value) }
                .sorted { ($0.0.count, $0.1) < ($1.0.count, $1.1) }
        }

        func name(_ set: KeySet?) -> String { set.map { keys($0) } ?? "" }

        // MARK: Keyboard picture

        func keyboard(_ m: KeyMeanings) -> String {
            let u = 46.0, pad = 4.0
            let w = KeyboardGeometry.width * u + 2 * pad, h = KeyboardGeometry.height * u + 2 * pad
            var out = "<svg class=\"keyboard\" viewBox=\"0 0 \(Int(w)) \(Int(h))\" role=\"img\" aria-label=\"The keyboard, each key labelled with what it means\">"
            for k in geometry.keys {
                let x = pad + k.x * u + 2, y = pad + k.y * u + 2, kw = k.width * u - 4, kh = k.height * u - 4
                let meaning = m.keys[k.code]
                let shown = meaning.flatMap { $0.label.isEmpty ? nil : $0.label } ?? KeyMeanings.modifiers[k.code]
                let role = meaning.map { shown == nil ? "idle" : $0.role.rawValue } ?? (shown == nil ? "idle" : "mod")
                if k.code == KeyboardGeometry.returnCode, let outline = geometry.returnOutline {
                    let pts = outline.map { "\(pad + $0.x * u),\(pad + $0.y * u)" }.joined(separator: " ")
                    out += "<polygon class=\"key idle\" points=\"\(pts)\"/>"
                    out += text(x + kw / 2, y + 0.5 * u - 2, k.label, cls: "legend-only")
                    continue
                }
                out += "<rect class=\"key \(role)\" x=\"\(x)\" y=\"\(y)\" width=\"\(kw)\" height=\"\(kh)\" rx=\"5\"/>"
                if let shown {
                    let size = shown.count <= 2 ? 17.0 : shown.count <= 4 ? 12.5 : 10.5
                    let alone = meaning?.alone
                    out += text(x + kw / 2, y + kh / 2 + (alone == nil ? 5 : 1), shown, cls: "meaning \(role)", size: size)
                    if !k.label.isEmpty { out += text(x + 4, y + 10, k.label, cls: "legend", anchor: "start") }
                    if let alone { out += text(x + kw / 2, y + kh - 4, alone, cls: "alone") }
                } else if !k.label.isEmpty {
                    out += text(x + kw / 2, y + kh / 2 + 4, k.label, cls: "legend-only")
                }
            }
            return out + "</svg>"
        }

        func text(_ x: Double, _ y: Double, _ s: String, cls: String, size: Double? = nil, anchor: String = "middle") -> String {
            let style = size.map { " style=\"font-size:\($0)px\"" } ?? ""
            return "<text class=\"\(cls)\" x=\"\(x)\" y=\"\(y)\" text-anchor=\"\(anchor)\"\(style)>\(esc(s))</text>"
        }

        // MARK: Page

        func page() -> String {
            let spell = layout.spellIndex
            let spellKey = spell.map { kbd($0) } ?? ""
            let capitalKey = english.capitalKey.map { kbd($0) } ?? ""
            let undo = name(english.undoKeys)
            let capNext = name(english.capitalizeNextKeys)
            let modeSwitch = name(english.modeSwitchKeys)
            let space = layout.spaceIndex.map { kbd($0) } ?? "the space bar"
            let abbreviation = entries(data.english) { $0.text == "." && !$0.capitalizeNext }.first?.0
            let suffixes = entries(data.english) { $0.kind == .suffix }
            let briefs = entries(data.english) { $0.kind == .word && !$0.isSnippet }
            let punctuation = entries(data.english) { $0.kind == .symbol && !$0.isSnippet }
            let cppSymbols = entries(data.cpp) { $0.kind == .symbol && !$0.isSnippet }
            let cppWords = entries(data.cpp) { $0.kind == .word }
            let snippets = entries(data.cpp) { $0.isSnippet }

            var h = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            h += "<meta name=\"color-scheme\" content=\"light dark\"><title>KeyChord Reference</title><style>\(Manual.css)</style></head><body><main>"

            h += """
            <h1>KeyChord Reference</h1>
            <p class="lead">Press chord keys together, then release them to type a syllable or word.</p>
            <p class="callout"><a href="keychord://practice">Open Practice</a> to try chords with hints.
            The keyboard overlay in Settings keeps the mapping visible while you type in other apps.</p>

            <h2 id="start">Getting started</h2>
            <ol>
            <li><b>Open Practice</b> to type locally with hints. No permissions are needed.
            To type in other apps, choose <b>Enable Typing in Other Apps</b> in the menu and allow Accessibility access.</li>
            <li><b>Tap the right ⌥ Option key</b> to turn chord typing on. The menu bar shows <i>English</i> next to
            the keyboard icon. Tap it again to type normally.</li>
            <li><b>Press all the keys of a chord, then let go.</b> You don't need to press them at exactly the same
            moment: a chord is everything you press before all keys are up. KeyChord adds the space before each word.</li>
            </ol>
            \(example("the"))
            <p>Keyboard shortcuts with ⌘, ⌃ or ⌥ always work as usual, and chord typing pauses by itself in password fields.</p>

            <h2 id="keyboard">The keyboard</h2>
            <p>Every key has a meaning, shown in large type below; the letter printed on the key is in the corner.
            A syllable is its <span class="t onset">start</span>, its <span class="t vowel">vowel</span> and its
            <span class="t coda">end</span>, pressed together:</p>
            <ul>
            <li>the <span class="t onset">left hand</span> plays the consonants at the start,</li>
            <li>the <span class="t vowel">thumbs</span> play the vowel on the bottom row,</li>
            <li>the <span class="t coda">right hand</span> plays the consonants at the end.</li>
            </ul>
            \(keyboard(english))
            <p class="small">Small type at the bottom of a key says what it does when pressed alone, when that is
            something else: \(index("O").map { kbd($0) } ?? "") alone adds the ending “ed”, for example. The pictures
            show the MacBook Pro's \(geometry.kind == .ansi ? "US" : "Canadian French") keyboard; with another layout,
            use the key in the same place.</p>

            <h2 id="syllables">Syllables</h2>
            <p>Use the word's spelling: combine its start letters, vowel and end letters in one chord.
            Leave out the parts a word doesn't have. Release every key before starting the next chord.</p>
            \(example("sat"))\(example("stop"))\(example("thing"))\(example("rain"))
            <p>Some letters and letter groups take two keys. The full reference is below:</p>
            <h3><span class="t onset">Start</span> letters</h3>\(table(clusters(.onset)))
            <h3><span class="t vowel">Vowels</span></h3>\(table(clusters(.vowel)))
            <h3><span class="t coda">End</span> letters</h3>\(table(clusters(.coda)))

            <h2 id="words">Common words</h2>
            <p>Some frequent words have a chord of their own, often \(spellKey) with a few of the word's letters.
            “I” is the \(index("M").map { kbd($0) } ?? "") vowel key alone.</p>
            \(table(briefs.map { ($0.0, $0.1.text) }))

            <h2 id="capitals">Capitals and punctuation</h2>
            <ul>
            <li>After . ? and ! the next word gets a capital by itself.</li>
            <li>\(capNext), pressed together as one chord, gives the next word a capital, for names:</li>
            </ul>
            \(example("Anna"))
            <ul>
            """
            if let abbreviation {
                h += "<li>\(keys(abbreviation)) is a full stop without the capital after it, for “Mr. and Mrs.”</li>"
            }
            h += """
            <li>With Caps Lock on, everything you chord comes out in capitals.</li>
            </ul>
            <p>Punctuation attaches to the word before it, and opening brackets and quotes to the word after.
            The opening double-quote chord also closes an open quote, without adding a space before it:</p>
            \(table(punctuation.map { ($0.0, $0.1.text + ($0.1.capitalizeNext ? "  then a capital" : "")) }))

            <h2 id="endings">Endings</h2>
            <p>Type the word, then the ending as a chord of its own. KeyChord joins it to the word and fixes the
            spelling: it doubles letters, drops a silent e and turns y into i where English does.</p>
            \(table(suffixes.map { ($0.0, "-" + $0.1.text) }))
            \(example("stopping"))\(example("making"))\(example("tried"))\(example("boxes"))

            <h2 id="long">Long words</h2>
            <p>A long word takes a chord for each part. KeyChord puts a space before every chord, so press the space
            bar (\(space)) together with each chord after the first: that chord joins onto the word instead.
            Whichever thumb isn't on a vowel presses it.</p>
            \(example("anything"))\(example("possible"))
            <p class="small">A few chords can't take the space bar, because they already use six keys or the keyboard
            would drop that combination. Hold <kbd class="mod">⇧</kbd> Shift instead for those; Practice
            says when.</p>

            <h2 id="letters">Letters and numbers</h2>
            <p>Any word can be spelled letter by letter: \(spellKey) plus the key printed with the letter. Add
            \(capitalKey) for a capital. Letters join together without spaces.</p>
            \(spelled(["key", "yes", "quiz"]))\(spelled(["OK", "USA", "NASA", "TV", "BBC"]))
            <p>The number row types digits. Several digits go in one chord when they read left to right on the
            keyboard, and the next chord joins on:</p>
            \(example("1234"))\(example("2026"))

            <h2 id="mistakes">Fixing mistakes</h2>
            <p>\(undo) undoes the last chord, and you can press it again to go further back. ⌫ Delete works as
            usual.</p>

            <h2 id="normal">Typing without chords</h2>
            <p>Tap the right ⌥ Option key, type as usual, and tap it again to go back to chords. The space bar
            (\(space)) pressed alone types a space in both. Practice says when a piece of text has no chord.</p>

            <h2 id="cpp">Programming in C++</h2>
            <p>\(modeSwitch) switches between English and C++; the menu bar shows which one is on. In C++ mode,
            operators get spaces around them, brackets and semicolons attach where they belong, and there is no
            automatic capital after a full stop.</p>
            \(example("int count = 0;", mode: .cpp))
            <h3>Symbols and operators</h3>\(table(cppSymbols.map { ($0.0, $0.1.text) }))
            <h3>Keywords</h3>\(table(cppWords.map { ($0.0, $0.1.text) }))
            <h3>Snippets</h3><p>These type a pair and put the cursor in between; \(name(commandKeys(.snippetExit, in: data.cpp))) jumps past the end.</p>
            \(table(snippets.map { ($0.0, Manual.snippetText($0.1)) }, wide: true))
            <h3>Names and commands</h3>\(table(commands(data.cpp) + commands(data.shared), wide: true))

            <h2 id="practice">Practice</h2>
            <p>Choose Words, Lessons, or Voice Practice from the <b>Practice</b> submenu in the menu bar.
            <a href="keychord://practice">Open Practice</a> resumes your last activity.
            Lessons teach the English and C++ course and keep your saved progress. Words offers short word sessions or a timer.
            The keyboard stays below the typing box. Press <b>Hint</b> or <b>⇧⌘H</b> to reveal the current word's keys;
            hints clear on the next word. Lessons automatically introduce each new combination on its first use.
            Right Option switches between chords and ordinary typing.</p>
            <p>Voice reads a word, waits for your typed chord answer, gives spoken feedback, and moves on after a correct answer.
            Use <b>⇧⌘R</b> to hear it again and <b>⇧⌘H</b> to hear the chord keys. No microphone is needed.</p>

            <h2 id="custom">Custom chords</h2>
            <p>Open <a href="keychord://custom-chords">Custom Chords</a> to give a word, phrase, or symbol your own
            key combination. Record keys or choose <b>Find unused chord</b>, enter the text, and choose a language.
            The before-and-after preview shows each affected combination and language, including its original meaning.
            <b>Try chord</b> tests the unsaved draft locally; press it twice to check spacing, or choose English or C++ when using both.</p>
            <p><b>Save chord</b> or <b>Replace chord</b> applies your changes. Turn off <b>Enabled when saved</b> and save to
            restore the original mapping while keeping your customization. Remove also restores the original mapping.
            The library labels chords On, Off, or Needs repair; select a chord to see why it needs attention.</p>
            <p>Choose <b>Words &amp; phrases</b> for normal word spacing and capitalization, or <b>No added spaces</b> for
            text that attaches on both sides without extra spaces. Caps Lock still applies. Built-in actions and Space keep their existing jobs.</p>

            <h2 id="limits">When a chord doesn't work</h2>
            <p>Some keyboards cannot detect certain keys held together. Practice suggests alternatives for
            combinations that the available keyboard model predicts will fail. Custom Chords checks these
            combinations before saving. Other keyboards may behave differently; if a chord doesn't register,
            try fewer keys or choose a different combination.</p>
            </main></body></html>
            """
            return h
        }

        func commandKeys(_ c: Command, in d: ChordDictionary) -> KeySet? {
            d.entries.first { $0.value == .command(c) }?.key
        }
    }

    static func snippetText(_ t: TextEntry) -> String {
        guard let k = t.cursorFromEnd else { return t.text }
        return String(t.text.dropLast(k)) + "…" + String(t.text.suffix(k))
    }

    static let css = """
    :root { --fg:#1f2328; --muted:#59636e; --bg:#fff; --line:#d0d7de; --panel:#f6f8fa;
      --onset:#0a66d8; --vowel:#8250df; --coda:#0f8a8a; --spell:#c2185b; --special:#8a5a2b; --number:#6e7781; --mod:#57606a; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#e6edf3; --muted:#9da7b3; --bg:#1e1f22; --line:#3d444d; --panel:#26282c;
        --onset:#5aa3ff; --vowel:#b692ff; --coda:#4fd1c5; --spell:#ff6fa6; --special:#d8a26a; --number:#9da7b3; --mod:#9da7b3; }
    }
    body { margin:0; font:15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color:var(--fg); background:var(--bg); }
    main { max-width: 860px; margin: 0 auto; padding: 24px 28px 48px; }
    h1 { font-size: 28px; margin: 0 0 6px; }
    h2 { font-size: 20px; margin: 34px 0 8px; padding-top: 12px; border-top: 1px solid var(--line); }
    h3 { font-size: 15px; margin: 18px 0 6px; }
    .lead { font-size: 16px; color: var(--muted); }
    .callout { padding: 10px 12px; border-radius: 8px; background: var(--panel); border-left: 3px solid var(--onset); }
    .small { color: var(--muted); font-size: 13px; }
    a { color: var(--onset); }
    .t { font-weight: 600; }
    .t.onset, .means.onset { color: var(--onset); } .t.vowel, .means.vowel { color: var(--vowel); }
    .t.coda, .means.coda { color: var(--coda); } .means.spell { color: var(--spell); } .means.special { color: var(--special); }
    kbd { display:inline-block; min-width: 1.35em; padding: 1px 5px; margin: 0 1px; border-radius: 5px; text-align:center;
      font: 600 13px/1.35 -apple-system, sans-serif; border: 1px solid var(--line); background: var(--panel); color: var(--fg); }
    kbd.onset { border-color: var(--onset); } kbd.vowel { border-color: var(--vowel); } kbd.coda { border-color: var(--coda); }
    kbd.spell { border-color: var(--spell); } kbd.special { border-color: var(--special); }
    .example { display:flex; flex-wrap:wrap; align-items:center; gap: 6px 8px; margin: 10px 0; padding: 10px 12px;
      background: var(--panel); border-radius: 8px; }
    .example .word { font-size: 20px; font-weight: 700; margin-right: 2px; }
    .eq, .then, .plus { color: var(--muted); font-size: 13px; }
    .chord { display:inline-flex; align-items:flex-start; gap: 4px; padding: 4px 6px; border: 1px solid var(--line);
      border-radius: 7px; background: var(--bg); }
    .part { display:inline-flex; flex-direction:column; align-items:center; }
    .part .means { font-size: 13px; font-weight: 700; }
    .grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 4px 14px; margin: 6px 0 10px; }
    .grid.wide { grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); }
    .cell { display:flex; align-items:center; gap: 8px; padding: 3px 0; border-bottom: 1px solid var(--line); }
    .cell .keys { white-space: nowrap; }
    .cell .out { font-weight: 600; white-space: pre-wrap; }
    .practice { display:inline-block; margin: 8px 12px 0 0; font-weight: 600; text-decoration: none; }
    svg.keyboard { width: 100%; height: auto; margin: 8px 0; }
    svg .key { fill: var(--panel); stroke: var(--line); stroke-width: 1; }
    svg .key.onset { fill: color-mix(in srgb, var(--onset) 14%, var(--bg)); stroke: var(--onset); }
    svg .key.vowel { fill: color-mix(in srgb, var(--vowel) 14%, var(--bg)); stroke: var(--vowel); }
    svg .key.coda { fill: color-mix(in srgb, var(--coda) 14%, var(--bg)); stroke: var(--coda); }
    svg .key.spell { fill: color-mix(in srgb, var(--spell) 14%, var(--bg)); stroke: var(--spell); }
    svg .key.special { fill: color-mix(in srgb, var(--special) 12%, var(--bg)); stroke: var(--special); }
    svg .key.idle { fill: var(--bg); stroke: var(--line); }
    svg text { font-family: -apple-system, sans-serif; fill: var(--fg); }
    svg .meaning { font-weight: 700; font-size: 17px; }
    svg .meaning.onset { fill: var(--onset); } svg .meaning.vowel { fill: var(--vowel); } svg .meaning.coda { fill: var(--coda); }
    svg .meaning.spell { fill: var(--spell); } svg .meaning.special { fill: var(--special); }
    svg .meaning.number, svg .meaning.space, svg .meaning.mod { fill: var(--mod); }
    svg .legend { font-size: 8.5px; fill: var(--muted); }
    svg .alone { font-size: 9px; fill: var(--muted); }
    svg .legend-only { font-size: 10px; fill: var(--muted); }
    """
}
