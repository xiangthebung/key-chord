// Text reference of the active Layout for the Show Layout window (Req 4.8).

public enum LayoutReference {
    /// US ANSI rows by virtual key code, for the keyboard diagram.
    static let rows: [[KeyCode]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
        [49],
    ]
    static let indent = [0, 3, 5, 7, 20]

    public static func roleLabel(_ r: KeyRole) -> String {
        switch r {
        case .bank(.onset): return "onset"
        case .bank(.vowel): return "vowel"
        case .bank(.coda): return "coda"
        case .number(let d): return "num \(d)"
        case .spell: return "SPELL"
        case .space: return "SPACE"
        }
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    public static func render(_ layout: Layout) -> String {
        var out = "KeyChord layout\n\n"
        out += "Press a syllable's keys together: its start (onset), its vowel and its end (coda).\n"
        out += "Hold the space bar with a chord to join it to the word before; alone it types a space.\n"
        out += "Each key shows its name and its part. Keys marked '-' type as usual.\n\n"
        let w = 7
        var placed = Set<KeyCode>()
        for (r, row) in rows.enumerated() {
            var top = String(repeating: " ", count: indent[r])
            var bottom = top
            for code in row {
                placed.insert(code)
                if let i = layout.indexByCode[code] {
                    let k = layout.keys[i]
                    let name = k.name.count > 5 ? abbreviation(k.name) : k.name
                    top += pad("[" + name, w - 1) + "]"
                    bottom += pad(" " + roleLabel(k.role), w)
                } else {
                    top += pad("[ -", w - 1) + "]"
                    bottom += pad("", w)
                }
            }
            out += top + "\n" + bottom + "\n"
        }
        let others = layout.keys.filter { !placed.contains($0.code) }
        if !others.isEmpty {
            out += "\nOther chord keys: " + others.map { "\($0.name) (\(roleLabel($0.role)))" }.joined(separator: ", ") + "\n"
        }
        let abbreviated = layout.keys.filter { $0.name.count > 5 }
        if !abbreviated.isEmpty {
            out += "\nAbbreviations: " + abbreviated.map { "\(abbreviation($0.name)) = \($0.name)" }.joined(separator: ", ") + "\n"
        }

        for bank in Bank.allCases {
            let table = layout.clusters[bank] ?? [:]
            switch bank {
            case .onset: out += "\nOnset: the start of a syllable\n"
            case .vowel: out += "\nVowel\n"
            case .coda: out += "\nCoda: the end of a syllable\n"
            }
            var items: [(String, String)] = table.map { (layout.chordString($0.key), $0.value) }
            items.sort { a, b in a.0.count != b.0.count ? a.0.count < b.0.count : a.0 < b.0 }
            out += columns(items)
        }
        let spell = layout.spellIndex.map { layout.keys[$0].name } ?? "(none)"
        out += "\nSingle letters (press \(spell) together with the keys)\n"
        var letters: [(String, String)] = layout.fingerspelling.map { (layout.chordString($0.key), $0.value) }
        letters.sort { a, b in a.1.lowercased() != b.1.lowercased() ? a.1.lowercased() < b.1.lowercased() : a.1 > b.1 }
        out += columns(letters)
        return out
    }

    static func abbreviation(_ name: String) -> String {
        switch name {
        case "LBracket": return "["
        case "RBracket": return "]"
        case "Backslash": return "\\"
        case "Semicolon": return ";"
        case "Quote": return "'"
        case "Comma": return ","
        case "Period": return "."
        case "Slash": return "/"
        case "Minus": return "-"
        case "Equal": return "="
        case "Grave": return "`"
        case "Space": return "Space"
        default: return String(name.prefix(5))
        }
    }

    static func columns(_ items: [(String, String)], perRow: Int = 4) -> String {
        var out = ""
        for (i, item) in items.enumerated() {
            out += pad("  \(item.0) = \(item.1)", 26)
            if i % perRow == perRow - 1 || i == items.count - 1 { out += "\n" }
        }
        return out
    }
}
