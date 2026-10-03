// What each chord key means in a sub-mode, worked out from the Layout and the dictionaries: the sound it adds
// inside a syllable chord, and what it does pressed alone. The Typing Guide's keyboard and the manual label
// keys with these, so that people learn keys by meaning rather than by the letter printed on them.
// Standard library only.

public struct KeyMeanings: Sendable {
    public enum Role: String, Sendable, CaseIterable {
        /// Starting consonants (left hand), vowels (thumbs), ending consonants (right hand).
        case onset, vowel, coda
        case number, spell, space
        /// Punctuation, commands and endings, but no syllable sound.
        case special
    }

    public struct Meaning: Equatable, Sendable {
        public let role: Role
        /// Short label for a key picture: the key's sound ("h"), its digit, "spell", "space", or what it does
        /// pressed alone ("undo", "(").
        public let label: String
        /// What the key does pressed alone, when that differs from `label`: "-ed" on the d key, "I" on i.
        public let alone: String?
    }

    /// Meaning of each Layout key, by key code.
    public let keys: [KeyCode: Meaning]
    /// Keys outside the Layout that matter while chording: Shift joins (for chords that can't take the space bar),
    /// right Option turns chord typing on and off.
    public static let modifiers: [KeyCode: String] = [56: "join", 60: "join", 61: "on/off"]

    /// The key that turns a spelled letter into a capital (spell + this key + letter), if every letter
    /// uses the same one.
    public let capitalKey: Int?
    public let spellKey: Int?
    public let undoKeys: KeySet?
    public let capitalizeNextKeys: KeySet?
    public let modeSwitchKeys: KeySet?

    public init(data: EngineData, mode: SubMode) {
        let layout = data.layout
        var effective = data.shared.entries
        for (k, e) in data.dictionary(for: mode).entries { effective[k] = e }

        var out: [KeyCode: Meaning] = [:]
        for (i, key) in layout.keys.enumerated() {
            let single = KeySet([i])
            let alone = effective[single].map(Self.display)
            switch key.role {
            case .bank(let bank):
                let role: Role = bank == .onset ? .onset : bank == .vowel ? .vowel : .coda
                if let sound = layout.clusters[bank]?[single], !sound.isEmpty {
                    out[key.code] = Meaning(role: role, label: sound, alone: alone == sound ? nil : alone)
                } else {
                    out[key.code] = Meaning(role: .special, label: alone ?? "", alone: nil)
                }
            case .number(let d):
                out[key.code] = Meaning(role: .number, label: String(d), alone: nil)
            case .spell:
                out[key.code] = Meaning(role: .spell, label: "spell", alone: alone)
            case .space:
                // Held with a chord it joins the chord to the word before; alone it types a space.
                out[key.code] = Meaning(role: .space, label: "join", alone: "space")
            }
        }
        keys = out
        spellKey = layout.spellIndex

        func commandKeys(_ c: Command) -> KeySet? {
            effective.filter { $0.value == .command(c) }.map(\.key).min { ($0.count, $0.bits) < ($1.count, $1.bits) }
        }
        undoKeys = commandKeys(.undo)
        capitalizeNextKeys = commandKeys(.capitalizeNext)
        modeSwitchKeys = commandKeys(.modeSwitch)

        // Capital letters: spell + the lowercase letter's keys + one extra key, the same for every letter.
        var extra: Set<Int> = []
        var capitals = 0
        for (k, letter) in layout.fingerspelling where letter.count == 1 && letter.uppercased() == letter
                                                         && letter.lowercased() != letter {
            guard let lower = layout.fingerspelling.first(where: { $0.value == letter.lowercased() })?.key,
                  k.isSuperset(of: lower), k.subtracting(lower).count == 1 else { extra.insert(-1); continue }
            extra.insert(k.subtracting(lower).indices[0])
            capitals += 1
        }
        capitalKey = capitals > 0 && extra.count == 1 ? extra.first : nil
    }

    /// How an entry reads on a key: "-ed" for a suffix, "undo" for a command, "'…'" for a snippet.
    public static func display(_ e: Entry) -> String {
        switch e {
        case .text(let t):
            if t.kind == .suffix { return "-" + t.text }
            if let k = t.cursorFromEnd {
                return String(t.text.dropLast(k)) + "…" + String(t.text.suffix(k))
            }
            return t.text
        case .command(let c):
            switch c {
            case .undo: return "undo"
            case .modeSwitch: return "mode"
            case .capitalizeNext: return "Cap"
            case .snippetExit: return "exit"
            case .casing(.snake): return "snake"
            case .casing(.camel): return "camel"
            case .casing(.pascal): return "Pascal"
            case .casing(.screamingSnake): return "SNAKE"
            case .endIdentifier: return "end"
            }
        }
    }
}
