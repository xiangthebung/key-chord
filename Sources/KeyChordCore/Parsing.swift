// Parsers for the user-editable data files (Req 4.1, 15.3, 15.4).
//
// Common syntax
//   - One item per line. Blank lines and lines starting with '#' are ignored.
//   - A chord is a set of logical key names joined by '+' (whitespace is also accepted).
//   - Text is a double-quoted string. Escapes: \" \\ \| (literal pipe).
//     An unescaped | is the Cursor_Marker.
//
// Dictionary line:   KEYS = "text" [flag ...]     or     KEYS = command
//   flags:    attach-left attach-right word-attach glue cap-next word symbol suffix
//   commands: undo mode-switch capitalize-next snippet-exit snake-case camel-case
//             pascal-case screaming-snake-case end-identifier
//
// Layout file sections:
//   [keys]         NAME KEYCODE ROLE [DIGIT]    roles: onset vowel coda number spell space
//   [onset] [vowel] [coda]   KEYS = "letters"
//   [fingerspell]  KEYS = "l"      (keys exclude the Spell_Key)
//
// Orthography exceptions:   word + suffix = result

public struct LoadProblem: Equatable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int?
    public var entry: String?
    public var message: String

    public init(file: String, line: Int? = nil, entry: String? = nil, message: String) {
        self.file = file
        self.line = line
        self.entry = entry
        self.message = message
    }

    public var description: String {
        var s = file
        if let line { s += ":\(line)" }
        s += ": \(message)"
        if let entry, !entry.isEmpty { s += "  [\(entry)]" }
        return s
    }
}

// MARK: - Low level helpers

enum Lex {
    static func trim(_ s: Substring) -> Substring {
        var s = s
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return s
    }

    static func trim(_ s: String) -> String { String(trim(Substring(s))) }

    /// Lines as (1-based number, trimmed content), skipping blanks and comments.
    static func lines(_ text: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var n = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            n += 1
            var line = raw
            if line.last == "\r" { line.removeLast() }
            let t = trim(line)
            if t.isEmpty || t.first == "#" { continue }
            out.append((n, String(t)))
        }
        return out
    }

    /// Splits "lhs = rhs" at the first '=' that is outside quotes.
    static func splitAssignment(_ line: String) -> (String, String)? {
        guard let idx = line.firstIndex(of: "=") else { return nil }
        let lhs = trim(line[line.startIndex..<idx])
        let rhs = trim(line[line.index(after: idx)...])
        return (String(lhs), String(rhs))
    }

    static func keyNames(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "+" || $0.isWhitespace }).map(String.init)
    }

    struct QuotedText {
        var text: String
        var markerOffsets: [Int]   // character offsets of unescaped '|'
        var rest: String
    }

    enum QuoteError: Error { case notQuoted, unterminated, badEscape(Character) }

    /// Parses a leading double-quoted string. Returns the text (markers removed),
    /// marker positions, and the remainder of the line.
    static func quoted(_ s: String) throws -> QuotedText {
        guard s.first == "\"" else { throw QuoteError.notQuoted }
        var text = ""
        var count = 0
        var markers: [Int] = []
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let n = s.index(after: i)
                guard n < s.endIndex else { throw QuoteError.unterminated }
                let e = s[n]
                switch e {
                case "\"", "\\", "|": text.append(e); count += 1
                default: throw QuoteError.badEscape(e)
                }
                i = s.index(after: n)
                continue
            }
            if c == "\"" {
                let rest = trim(s[s.index(after: i)...])
                return QuotedText(text: text, markerOffsets: markers, rest: String(rest))
            }
            if c == "|" {
                markers.append(count)
            } else {
                text.append(c)
                count += 1
            }
            i = s.index(after: i)
        }
        throw QuoteError.unterminated
    }

    static func quoteErrorMessage(_ e: Error) -> String {
        switch e as? QuoteError {
        case .notQuoted?: return "text must be a double-quoted string"
        case .unterminated?: return "unterminated string"
        case .badEscape(let c)?: return "unknown escape \\\(c)"
        case nil: return "malformed text"
        }
    }
}

// MARK: - Layout

public enum LayoutParser {
    /// Modifier / reserved key codes that may never be Chord_Keys (Req 4.4):
    /// Right Cmd 54, Left Cmd 55, Shift 56, Caps Lock 57, Option 58, Control 59,
    /// Right Shift 60, Right Option 61, Right Control 62, Fn/Globe 63.
    public static let forbiddenCodes: Set<KeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func parse(_ source: String, file: String, rolloverLimit: Int) -> (Layout?, [LoadProblem]) {
        var problems: [LoadProblem] = []
        func problem(_ line: Int?, _ entry: String?, _ msg: String) {
            problems.append(LoadProblem(file: file, line: line, entry: entry, message: msg))
        }

        var section: String?
        var keys: [KeyDef] = []
        var names = Set<String>()
        var codes = Set<KeyCode>()
        var tableLines: [String: [(Int, String)]] = [:]
        let tableSections: Set<String> = ["onset", "vowel", "coda", "fingerspell"]

        for (n, line) in Lex.lines(source) {
            if line.first == "[" {
                guard line.last == "]" else { problem(n, line, "malformed section header"); section = nil; continue }
                let name = String(line.dropFirst().dropLast()).lowercased()
                if name == "keys" || tableSections.contains(name) {
                    section = name
                } else {
                    problem(n, line, "unknown section [\(name)]")
                    section = nil
                }
                continue
            }
            guard let section else { problem(n, line, "line outside of a section"); continue }
            if section != "keys" { tableLines[section, default: []].append((n, line)); continue }

            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else {
                problem(n, line, "expected: NAME KEYCODE ROLE [DIGIT]"); continue
            }
            let name = parts[0]
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                problem(n, line, "key name may only contain letters, digits and _"); continue
            }
            guard let code = KeyCode(parts[1]) else { problem(n, line, "invalid key code \(parts[1])"); continue }
            let role: KeyRole
            switch parts[2].lowercased() {
            case "onset": role = .bank(.onset)
            case "vowel": role = .bank(.vowel)
            case "coda": role = .bank(.coda)
            case "spell": role = .spell
            case "space": role = .space
            case "number":
                guard parts.count == 4, parts[3].count == 1, let d = parts[3].first, d.isASCII, d.isNumber else {
                    problem(n, line, "number keys need a single digit, e.g. `1 18 number 1`"); continue
                }
                role = .number(d)
            default:
                problem(n, line, "unknown role \(parts[2])"); continue
            }
            if parts.count == 4, case .number = role {} else if parts.count == 4 {
                problem(n, line, "only number keys take a digit"); continue
            }
            if forbiddenCodes.contains(code) {
                problem(n, line, "key code \(code) is a modifier, Caps Lock or Fn and cannot be a chord key"); continue
            }
            if names.contains(name) { problem(n, line, "duplicate key name \(name)"); continue }
            if codes.contains(code) { problem(n, line, "duplicate key code \(code)"); continue }
            if role == .spell, keys.contains(where: { $0.role == .spell }) { problem(n, line, "more than one spell key"); continue }
            if role == .space, keys.contains(where: { $0.role == .space }) { problem(n, line, "more than one space key"); continue }
            names.insert(name)
            codes.insert(code)
            keys.append(KeyDef(name: name, code: code, role: role))
        }

        if keys.count > 64 { problem(nil, nil, "a layout may define at most 64 keys"); return (nil, problems) }
        if keys.isEmpty { problem(nil, nil, "no keys defined in [keys]"); return (nil, problems) }

        let base = Layout(keys: keys, clusters: [:], fingerspelling: [:])
        var clusters: [Bank: [KeySet: String]] = [.onset: [:], .vowel: [:], .coda: [:]]
        var finger: [KeySet: String] = [:]

        for sectionName in ["onset", "vowel", "coda", "fingerspell"] {
            for (n, line) in tableLines[sectionName] ?? [] {
                guard let (lhs, rhs) = Lex.splitAssignment(line) else { problem(n, line, "expected: KEYS = \"text\""); continue }
                let keyNames = Lex.keyNames(lhs)
                if keyNames.isEmpty { problem(n, line, "missing keys"); continue }
                let unknown = keyNames.filter { base.indexByName[$0] == nil }
                if !unknown.isEmpty { problem(n, line, "unknown key name(s): \(unknown.joined(separator: ", "))"); continue }
                let set = base.keySet(names: keyNames)!
                var value = rhs
                if rhs.first == "\"" {
                    do {
                        let q = try Lex.quoted(rhs)
                        if !q.rest.isEmpty || !q.markerOffsets.isEmpty { problem(n, line, "unexpected text after value"); continue }
                        value = q.text
                    } catch { problem(n, line, Lex.quoteErrorMessage(error)); continue }
                }
                if value.isEmpty { problem(n, line, "empty value"); continue }

                if sectionName == "fingerspell" {
                    if let s = base.spellIndex, set.contains(s) {
                        problem(n, line, "fingerspelling keys must not include the spell key"); continue
                    }
                    guard value.count == 1, value.first!.isLetter else { problem(n, line, "fingerspelling value must be one letter"); continue }
                    if finger[set] != nil { problem(n, line, "duplicate key subset in [fingerspell]"); continue }
                    if set.count + 1 > rolloverLimit {
                        problem(n, line, "needs \(set.count + 1) keys with the spell key; rollover limit is \(rolloverLimit)"); continue
                    }
                    finger[set] = value
                } else {
                    let bank = Bank(rawValue: sectionName)!
                    let outside = set.subtracting(base.bankMasks[bank]!)
                    if !outside.isEmpty {
                        problem(n, line, "key(s) \(base.names(outside).joined(separator: ", ")) are not in the \(sectionName) bank"); continue
                    }
                    if clusters[bank]![set] != nil { problem(n, line, "duplicate key subset in [\(sectionName)]"); continue }
                    clusters[bank]![set] = value
                }
            }
        }

        let layout = Layout(keys: keys, clusters: clusters, fingerspelling: finger)
        let sizes = Bank.allCases.map { layout.largestClusterSize($0) }
        if sizes.reduce(0, +) > rolloverLimit {
            problem(nil, nil, "cluster tables break the rollover limit: largest onset (\(sizes[0])) + vowel (\(sizes[1])) + coda (\(sizes[2])) subsets exceed \(rolloverLimit)")
        }
        return (problems.isEmpty ? layout : nil, problems)
    }
}

// MARK: - Dictionaries

public enum DictionaryParser {
    static let commands: [String: Command] = [
        "undo": .undo,
        "mode-switch": .modeSwitch,
        "capitalize-next": .capitalizeNext,
        "snippet-exit": .snippetExit,
        "snake-case": .casing(.snake),
        "camel-case": .casing(.camel),
        "pascal-case": .casing(.pascal),
        "screaming-snake-case": .casing(.screamingSnake),
        "end-identifier": .endIdentifier,
    ]

    /// Default kind when none is given: plain letters (and apostrophes) are words, anything else is a symbol.
    static func inferredKind(_ text: String) -> OutputKind {
        text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " }) && !text.isEmpty ? .word : .symbol
    }

    public static func parse(_ source: String, file: String, layout: Layout, rolloverLimit: Int) -> (ChordDictionary?, [LoadProblem]) {
        var problems: [LoadProblem] = []
        var entries: [KeySet: Entry] = [:]
        func problem(_ line: Int, _ entry: String, _ msg: String) {
            problems.append(LoadProblem(file: file, line: line, entry: entry, message: msg))
        }

        for (n, line) in Lex.lines(source) {
            guard let (lhs, rhs) = Lex.splitAssignment(line) else { problem(n, line, "expected: KEYS = entry"); continue }
            let names = Lex.keyNames(lhs)
            if names.isEmpty { problem(n, line, "missing keys"); continue }
            let unknown = names.filter { layout.indexByName[$0] == nil }
            if !unknown.isEmpty { problem(n, line, "unknown key name(s): \(unknown.joined(separator: ", "))"); continue }
            let set = layout.keySet(names: names)!
            if let sp = layout.spaceIndex, set.contains(sp), set.count > 1 {
                problem(n, line, "the space key is ignored in multi-key chords; remove it"); continue
            }
            if set.count > rolloverLimit {
                problem(n, line, "chord needs \(set.count) keys; rollover limit is \(rolloverLimit)"); continue
            }
            if rhs.isEmpty { problem(n, line, "missing entry"); continue }

            let entry: Entry
            if rhs.first == "\"" {
                let q: Lex.QuotedText
                do { q = try Lex.quoted(rhs) } catch { problem(n, line, Lex.quoteErrorMessage(error)); continue }
                if q.markerOffsets.count > 1 { problem(n, line, "more than one cursor marker"); continue }
                var t = TextEntry(text: q.text)
                if let m = q.markerOffsets.first { t.cursorFromEnd = q.text.count - m }
                var kind: OutputKind?
                var bad: String?
                for flag in q.rest.split(whereSeparator: { $0.isWhitespace }) {
                    switch flag {
                    case "attach-left": t.attachLeft = true
                    case "attach-right": t.attachRight = true
                    case "word-attach": t.wordAttach = true
                    case "glue": t.glue = true
                    case "cap-next": t.capitalizeNext = true
                    case "word", "symbol", "suffix":
                        if kind != nil { bad = "more than one of word/symbol/suffix" }
                        kind = OutputKind(rawValue: String(flag))
                    default: bad = "unknown flag \(flag)"
                    }
                }
                if let bad { problem(n, line, bad); continue }
                t.kind = kind ?? inferredKind(q.text)
                if t.kind == .suffix && t.isSnippet { problem(n, line, "a suffix cannot contain a cursor marker"); continue }
                if t.text.isEmpty { problem(n, line, "empty text"); continue }
                entry = .text(t)
            } else {
                guard let c = commands[rhs] else { problem(n, line, "unknown command \(rhs)"); continue }
                entry = .command(c)
            }
            if entries[set] != nil { problem(n, line, "duplicate chord \(layout.chordString(set))"); continue }
            entries[set] = entry
        }
        return (problems.isEmpty ? ChordDictionary(entries: entries) : nil, problems)
    }
}

// MARK: - Orthography exceptions

public enum OrthographyParser {
    public static func parse(_ source: String, file: String) -> ([String: String]?, [LoadProblem]) {
        var out: [String: String] = [:]
        var problems: [LoadProblem] = []
        for (n, line) in Lex.lines(source) {
            guard let (lhs, rhs) = Lex.splitAssignment(line) else {
                problems.append(LoadProblem(file: file, line: n, entry: line, message: "expected: word + suffix = result")); continue
            }
            let parts = lhs.split(separator: "+").map { Lex.trim(String($0)) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !rhs.isEmpty,
                  !rhs.contains(where: { $0.isWhitespace }) else {
                problems.append(LoadProblem(file: file, line: n, entry: line, message: "expected: word + suffix = result")); continue
            }
            let key = parts[0].lowercased() + "+" + parts[1].lowercased()
            if out[key] != nil {
                problems.append(LoadProblem(file: file, line: n, entry: line, message: "duplicate exception")); continue
            }
            out[key] = rhs.lowercased()
        }
        return (problems.isEmpty ? out : nil, problems)
    }
}
