// What a chord means pressed on its own, read the way the Chord_Engine reads it (Req 6): what each group of its
// keys stands for, and what the chord types or does. The reference overlay shows this while keys are held, so a
// learner can check a chord before letting go, and see why a chord typed nothing. Standard library only.

public struct ChordReading: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// What the chord types at the start of a line, before the automatic space and capital. Endings read
        /// "-ing" and snippets "(…)", as on the keyboard picture.
        case text(String)
        /// A command, described: "undo the last chord".
        case command(String)
        /// No entry, letter, digit or syllable for these keys.
        case nothing
    }

    /// What each group of keys stands for: start, vowel and end of a syllable; spell, capital and letter; digits;
    /// or the whole chord as a word, ending, symbol or command. Keys that mean nothing together read "?".
    public let parts: [TypingStep.Part]
    public let outcome: Outcome
    /// The chord joins onto the previous output: the space bar or Shift is held with it.
    public let joins: Bool

    public init(parts: [TypingStep.Part], outcome: Outcome, joins: Bool) {
        self.parts = parts
        self.outcome = outcome
        self.joins = joins
    }

    /// Reads `chord` (Layout key indices) in `mode`, in the order ChordEngine.translate tries: the space bar,
    /// the dictionaries, the Spell_Key, digits, then Syllable_Composition. `shift`: the Join_Modifier is held.
    public init(_ chord: KeySet, shift: Bool = false, data: EngineData, mode: SubMode) {
        typealias Part = TypingStep.Part
        let layout = data.layout
        func names(_ k: KeySet) -> [String] { layout.names(k) }
        var keys = chord
        var parts: [Part] = []
        var joins = shift

        if let sp = layout.spaceIndex, keys.contains(sp) {
            if keys.count == 1 {
                self.init(parts: [Part(text: "space", keys: names(keys), role: .space)], outcome: .text(" "), joins: false)
                return
            }
            // Held with other keys, the space bar joins the chord to the previous output (Req 3.6, 6.1).
            keys.remove(sp)
            joins = true
            parts.append(Part(text: "join", keys: names(KeySet([sp])), role: .join))
        }
        guard !keys.isEmpty else {
            self.init(parts: parts, outcome: .nothing, joins: joins)
            return
        }

        if let entry = data.dictionary(for: mode)[keys] ?? data.shared[keys] {
            switch entry {
            case .text(let t):
                let shown = KeyMeanings.display(entry)
                let role: Part.Role = t.kind == .suffix ? .suffix : t.kind == .symbol ? .symbol : .word
                parts.append(Part(text: shown, keys: names(keys), role: role))
                self.init(parts: parts, outcome: .text(shown), joins: joins)
            case .command(let c):
                let what = KeyMeanings.describe(c)
                parts.append(Part(text: what, keys: names(keys), role: .command))
                self.init(parts: parts, outcome: .command(what), joins: joins)
            }
            return
        }

        if let s = layout.spellIndex, keys.contains(s) {
            let rest = keys.subtracting(KeySet([s]))
            parts.append(Part(text: "spell", keys: names(KeySet([s])), role: .spell))
            guard let letter = layout.fingerspelling[rest] else {
                if !rest.isEmpty { parts.append(Part(text: "?", keys: names(rest), role: .letter)) }
                self.init(parts: parts, outcome: .nothing, joins: joins)
                return
            }
            // A capital reads as the capital key plus the lowercase letter's keys, when it is built that way.
            let lower = letter.lowercased()
            if lower != letter, let lowerKeys = layout.fingerspelling.first(where: { $0.value == lower })?.key,
               rest.isSuperset(of: lowerKeys), !rest.subtracting(lowerKeys).isEmpty {
                parts.append(Part(text: "capital", keys: names(rest.subtracting(lowerKeys)), role: .capital))
                parts.append(Part(text: lower, keys: names(lowerKeys), role: .letter))
            } else {
                parts.append(Part(text: letter, keys: names(rest), role: .letter))
            }
            self.init(parts: parts, outcome: .text(letter), joins: joins)
            return
        }

        // Digits in left-to-right keyboard order (Req 6.6), syllables start + vowel + end (Req 7.1). Keys from
        // both groups make no chord, but each group still says what it would mean.
        var text = ""
        var ok = keys.isSubset(of: layout.numberMask) || keys.isSubset(of: layout.allBanksMask)
        for i in keys.intersection(layout.numberMask).indices {
            if case .number(let d) = layout.keys[i].role {
                parts.append(Part(text: String(d), keys: names(KeySet([i])), role: .digit))
                text.append(d)
            }
        }
        for bank in Bank.allCases {
            let part = keys.intersection(layout.bankMasks[bank] ?? KeySet())
            if part.isEmpty { continue }
            let role: Part.Role = bank == .onset ? .onset : bank == .vowel ? .vowel : .coda
            if let sound = layout.clusters[bank]?[part] {
                parts.append(Part(text: sound, keys: names(part), role: role))
                text += sound
            } else {
                parts.append(Part(text: "?", keys: names(part), role: role))
                ok = false
            }
        }
        self.init(parts: parts, outcome: ok && !text.isEmpty ? .text(text) : .nothing, joins: joins)
    }
}

extension KeyMeanings {
    /// What a command does, in a few words.
    public static func describe(_ c: Command) -> String {
        switch c {
        case .undo: return "undo the last chord"
        case .modeSwitch: return "switch between English and C++"
        case .capitalizeNext: return "capital on the next word"
        case .snippetExit: return "jump out of the brackets or quotes"
        case .casing(.snake): return "start a snake_case name"
        case .casing(.camel): return "start a camelCase name"
        case .casing(.pascal): return "start a PascalCase name"
        case .casing(.screamingSnake): return "start a SCREAMING_SNAKE_CASE name"
        case .endIdentifier: return "end the name"
        }
    }

    /// A sound that takes several keys of one bank.
    public struct Sound: Equatable, Sendable {
        public let text: String
        public let keys: KeySet
        public let bank: Bank
    }

    /// The sounds a learner can't read off the keyboard picture: those whose keys are not just the keys of their
    /// letters (d + g = ch, f + g = m), per bank, single letters first. Sounds made of their keys' own sounds,
    /// such as s + t = st or n + d = nd, are left out: "press both keys" covers them.
    public static func multiKeySounds(_ layout: Layout) -> [Bank: [Sound]] {
        var out: [Bank: [Sound]] = [:]
        for bank in Bank.allCases {
            let table = layout.clusters[bank] ?? [:]
            var sounds: [Sound] = []
            for (keys, text) in table where keys.count > 1 && !text.isEmpty && !isMadeOfItsKeys(keys, text, in: table) {
                sounds.append(Sound(text: text, keys: keys, bank: bank))
            }
            out[bank] = sounds.sorted { ($0.text.count, $0.text, $0.keys.bits) < ($1.text.count, $1.text, $1.keys.bits) }
        }
        return out
    }

    /// The other multi-key sounds: those whose keys are the keys of their letters (s + t = st), per bank.
    public static func pairSounds(_ layout: Layout) -> [Bank: [Sound]] {
        var out: [Bank: [Sound]] = [:]
        for bank in Bank.allCases {
            let table = layout.clusters[bank] ?? [:]
            out[bank] = table.filter { isMadeOfItsKeys($0.key, $0.value, in: table) }
                .map { Sound(text: $0.value, keys: $0.key, bank: bank) }
                .sorted { ($0.text, $0.keys.bits) < ($1.text, $1.keys.bits) }
        }
        return out
    }

    /// Whether a cluster of several keys is just its keys' own sounds put together, in some order (s + t = st).
    static func isMadeOfItsKeys(_ keys: KeySet, _ text: String, in table: [KeySet: String]) -> Bool {
        let singles = keys.indices.compactMap { table[KeySet([$0])] }
        return keys.count > 1 && singles.count == keys.count && spells(text, from: singles)
    }

    /// Whether some order of `pieces` spells `text`.
    private static func spells(_ text: String, from pieces: [String]) -> Bool {
        if pieces.isEmpty { return text.isEmpty }
        for (i, p) in pieces.enumerated() where !p.isEmpty && text.hasPrefix(p) {
            var rest = pieces
            rest.remove(at: i)
            if spells(String(text.dropFirst(p.count)), from: rest) { return true }
        }
        return false
    }
}
