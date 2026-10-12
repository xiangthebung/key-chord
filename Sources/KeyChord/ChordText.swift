// Chords as styled text, following the key-label preference with meanings colored like the keyboard.

import AppKit
import KeyChordCore

enum ChordText {
    /// "E + T" for Layout key names.
    static func keys(_ names: [String], layout: Layout, meanings: KeyMeanings? = nil) -> String {
        let style = Settings().keyLabelStyle
        return names.map { n in
            guard let index = layout.indexByName[n] else { return n }
            let code = layout.keys[index].code
            let physical = KeyboardDiagramView.name(for: code)
            return meanings?.label(for: code, physical: physical, style: style) ?? physical
        }
            .joined(separator: " + ")
    }

    static func keys(_ set: KeySet, layout: Layout, meanings: KeyMeanings? = nil) -> String {
        keys(layout.names(set), layout: layout, meanings: meanings)
    }

    /// The color of a chord part, as on the keyboard.
    static func color(for role: TypingStep.Part.Role) -> NSColor {
        switch role {
        case .onset: return KeyboardDiagramView.color(for: .onset)
        case .vowel: return KeyboardDiagramView.color(for: .vowel)
        case .coda: return KeyboardDiagramView.color(for: .coda)
        case .spell: return KeyboardDiagramView.color(for: .spell)
        case .capital, .suffix, .symbol, .command: return KeyboardDiagramView.color(for: .special)
        case .digit, .space, .join: return KeyboardDiagramView.color(for: .number)
        case .word, .letter: return .labelColor
        }
    }

    /// "th E + T  ·  i M  ·  ng K + L   →  thing", dimmed for a chord already typed.
    static func reading(_ r: ChordReading, layout: Layout, size: CGFloat, dim: Bool = false,
                        meanings: KeyMeanings? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let alpha: CGFloat = dim ? 0.55 : 1
        func add(_ s: String, _ color: NSColor, bold: Bool = false, smaller: Bool = false) {
            let f = NSFont.systemFont(ofSize: smaller ? size * 0.85 : size, weight: bold ? .bold : .regular)
            out.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color.withAlphaComponent(alpha)]))
        }
        var parts = r.parts
        if r.joins && !parts.contains(where: { $0.role == .join }) {
            parts.insert(TypingStep.Part(text: "join", keys: ["⇧"], role: .join), at: 0)
        }
        for (i, p) in parts.enumerated() {
            if i > 0 { add("  ·  ", .tertiaryLabelColor) }
            let meaning = p.role == .command ? p.text : ChordDisplay.visible(p.text)
            add(meaning, p.text == "?" ? .systemOrange : color(for: p.role), bold: true)
            let keysText = p.keys == ["⇧"]
                ? meanings?.label(for: 56, physical: "⇧", style: Settings().keyLabelStyle) ?? "⇧"
                : keys(p.keys, layout: layout, meanings: meanings)
            add(" " + keysText, .secondaryLabelColor, smaller: true)
        }
        add("   →  ", .tertiaryLabelColor)
        switch r.outcome {
        case .text(let t): add(ChordDisplay.visible(t), .labelColor, bold: true)
        case .command(let c): add(c, KeyboardDiagramView.color(for: .special), bold: true)
        case .nothing: add("no chord for these keys", .systemOrange, bold: true)
        }
        return out
    }

    /// Items such as "th  E + T" in a row that wraps, each meaning in its color.
    static func items(_ items: [(label: String, keys: String, color: NSColor)], size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "     ", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
            out.append(NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: item.color]))
            if !item.keys.isEmpty {
                // A no-break space keeps a meaning on the same line as its keys.
                out.append(NSAttributedString(string: "\u{00A0}\u{00A0}" + item.keys.replacingOccurrences(of: " ", with: "\u{00A0}"),
                                              attributes: [.font: NSFont.systemFont(ofSize: size * 0.9),
                                                           .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        return out
    }

    /// The chords a course step introduces.
    static func chords(_ chords: [Course.Chord], layout: Layout, size: CGFloat, limit: Int = 20,
                       meanings: KeyMeanings? = nil) -> NSAttributedString {
        var list = chords.prefix(limit).map { c -> (label: String, keys: String, color: NSColor) in
            var k = c.keys.isEmpty ? "" : keys(c.keys, layout: layout, meanings: meanings)
            if c.shift {
                let join = meanings?.label(for: 56, physical: "⇧", style: Settings().keyLabelStyle) ?? "⇧"
                k = k.isEmpty ? join : join + " + " + k
            }
            if let note = c.note { k += k.isEmpty ? note : " (\(note))" }
            return (c.label, k, c.role.map(KeyboardDiagramView.color(for:)) ?? .labelColor)
        }
        if chords.count > limit { list.append(("…", "and \(chords.count - limit) more", .secondaryLabelColor)) }
        return items(list, size: size)
    }

    /// A bold heading line before a group of items.
    static func heading(_ s: String, color: NSColor = .labelColor, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                         .foregroundColor: color])
    }
}
