// Typing guide planner (Typing Guide window): works out which chords type a given text.
//
// Each line is split into tokens: the spaces before a piece of text, then a run of letters, digits
// and underscores, or a run of other symbols. For each token the planner searches for the cheapest
// chord sequences (briefs, syllables, suffixes, fingerspelling, digits, punctuation) and replays them
// through a real ChordEngine. A sequence is only used when the engine produces exactly the text, so the
// guide never shows chords that would type something else. Anything no chord can produce is typed in
// Normal_Mode (tap right Option, type it, tap right Option).
//
// Standard library only, like the rest of KeyChordCore (Req 19.1).

public struct TypingStep: Equatable, Sendable {
    public enum PassKey: String, Sendable {
        case returnKey = "Return"
        case tab = "Tab"
        case delete = "Delete"
    }

    public enum Action: Equatable, Sendable {
        /// Press these keys together, then release them. The Space_Key among other keys joins the chord to the
        /// previous output; `shift`: hold Shift instead, for chords that can't take the space bar.
        case chord(keys: [String], shift: Bool)
        /// Press a pass-through key.
        case key(PassKey)
        /// Tap right Option (Normal_Mode), type the text as usual, tap right Option again.
        case typeNormally(String)
    }

    public enum Kind: String, Sendable {
        case brief, syllable, fingerspell, digits, suffix, symbol, space, command, cancelCapital, key, normal
    }

    public var action: Action
    public var kind: Kind
    /// Text this step inserts, including an automatic leading space. Empty for commands.
    public var output: String
    /// Short explanation for the guide.
    public var note: String
    /// Character offsets (extended grapheme clusters) of the source text this step belongs to.
    public var source: Range<Int>
    /// Steps that type the same piece of text share a group number.
    public var group: Int
    /// Length of the typed text (in characters, from the start of the whole text) once this step is done.
    public var textEnd: Int
    /// Typed text after this step that differs from the passage and a later step fixes: the base of a suffix
    /// whose spelling changes ("make" before "ing") or a throwaway letter before Delete. Usually empty.
    /// The typed text after the step is the passage up to `textEnd - tail.count`, followed by `tail`.
    public var tail = ""
    /// The engine's planned output context after this step.
    public var contextAfter: EngineContext?

    /// What a chord's keys stand for, such as th (E+T), i (M) and ng (K+L) in "thing". Empty for other steps.
    public struct Part: Equatable, Sendable {
        public enum Role: String, Sendable {
            case onset, vowel, coda, word, spell, capital, letter, digit, suffix, symbol, space, command
            /// The space bar held with the chord: no space before it.
            case join
        }
        /// The sound, letter, word or command: "th", "spell", "-ing", "capitalize the next word".
        public var text: String
        /// Layout key names.
        public var keys: [String]
        public var role: Role

        public init(text: String, keys: [String], role: Role) {
            self.text = text
            self.keys = keys
            self.role = role
        }
    }
    public var parts: [Part] = []

    public init(action: Action, kind: Kind, output: String, note: String, source: Range<Int>, group: Int,
                textEnd: Int = 0) {
        self.action = action
        self.kind = kind
        self.output = output
        self.note = note
        self.source = source
        self.group = group
        self.textEnd = textEnd
    }

    /// Characters of the passage the typed text matches after this step.
    public var prefixEnd: Int { textEnd - tail.count }

    public var isChord: Bool {
        if case .chord = action { return true }
        return false
    }
}

public struct TypingGuide: Sendable {
    public let mode: SubMode
    public let steps: [TypingStep]

    public init(mode: SubMode, steps: [TypingStep]) {
        self.mode = mode
        self.steps = steps
    }

    public var chordCount: Int { steps.filter(\.isChord).count }

    public var normalCount: Int {
        steps.filter { if case .typeNormally = $0.action { return true } else { return false } }.count
    }

    /// The first step of the group that covers the character `offset`, or the next group after it.
    public func stepIndex(at offset: Int) -> Int? {
        guard !steps.isEmpty else { return nil }
        var lo = 0, hi = steps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if steps[mid].source.upperBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        var i = min(lo, steps.count - 1)
        while i > 0 && steps[i - 1].group == steps[i].group { i -= 1 }
        return i
    }

    /// Whether the current text is on this plan. `tailStep` is a step whose complete intermediate
    /// text has been matched, including its temporary tail (for example "make" before "making").
    /// `start` is the character offset where a continuation begins.
    public func isPlanned(at offset: Int, tailStep: Int? = nil, start: Int = 0) -> Bool {
        // A suffix base can differ from the passage before its chord completes. Keep the context of
        // that base; replanning from just the matching prefix would lose the word the suffix must edit.
        if let tailStep, steps.indices.contains(tailStep), !steps[tailStep].tail.isEmpty { return true }
        if offset == 0 || offset == start { return true }
        guard let first = stepIndex(at: offset) else { return true }
        var k = max(0, first - 1)
        while k < steps.count && (k < first || steps[k].group == steps[first].group) {
            let s = steps[k]
            if s.tail.isEmpty && s.textEnd == offset { return true }
            if case .typeNormally = s.action, s.textEnd > offset, s.textEnd - s.output.count <= offset { return true }
            k += 1
        }
        return false
    }
}

/// A plan for the rest of a line from wherever the typist is, however they got there.
public struct TypingContinuation: Sendable {
    /// Steps for the text from `start` to `end`.
    public let guide: TypingGuide
    public let start: Int
    /// The end of the line, or of a word further on for very long lines.
    public let end: Int
    /// The output context the steps start from: put KeyChord in it before the first chord.
    public let startContext: EngineContext
}

public final class TypingPlanner {
    public let data: EngineData
    public let mode: SubMode
    public let rolloverLimit: Int
    /// Chords the keyboard can register. Chords it blocks (from the Matrix Scan or the Rollover Probe) are
    /// never planned.
    public let usable: (KeySet) -> Bool

    /// Longest run of letters and digits the planner searches; longer runs are typed in Normal_Mode.
    static let maxWordLength = 48
    static let normalNote = "no chord for this: tap right Option, type it, tap right Option"

    // Costs: fewer chords first, then less Shift, then fewer keys. Normal_Mode typing is a last resort.
    // Joining with the space bar costs its key plus a little; Shift, which moves the hand, much more.
    static let chordCost = 100
    static let shiftCost = 10
    static let spaceJoinCost = 2
    static let normalCost = 1000
    /// Preference for a suffix base the spelling rules change (try + ed → tried over tri + ed).
    static let naturalBaseBonus = 2

    private static func cost(_ k: KeySet) -> Int { chordCost + k.count }

    /// What part of a chord's keys stand for (see TypingStep.Part).
    private struct PartSpec {
        var text: String
        var keys: KeySet
        var role: TypingStep.Part.Role
    }

    private enum Seg {
        /// `parts`: how the single chord in `alts` breaks down; nil when the whole chord means `text`.
        case out(alts: [KeySet], text: String, kind: TypingStep.Kind, note: String, parts: [PartSpec]?)
        case command(keys: KeySet, note: String)
        /// Fingerspell a throwaway letter to use up an automatic capital, then press Delete.
        case cancel(keys: KeySet, letter: String)
        case suffix(keys: KeySet, suffix: String, base: String, result: String)
        case normal(String)
    }

    /// What the previous output of a word was, for estimating Shift use.
    private enum Last: Int { case start, glue, word, reset }
    private typealias Plan = (cost: Int, segs: [Seg])
    private typealias Cluster = (text: [Character], keys: [KeySet])

    private let layout: Layout
    /// The entry the engine uses for each chord in this mode (mode dictionary, then shared).
    private let effective: [KeySet: Entry]

    private var clusters: [Bank: [Character: [Cluster]]] = [:]
    private var briefs: [Character: [(text: [Character], keys: KeySet, entry: TextEntry)]] = [:]
    private var symbols: [Character: [(text: [Character], alts: [KeySet])]] = [:]
    private var mixed: [(text: [Character], alts: [KeySet])] = []
    private var suffixes: [(text: String, keys: KeySet)] = []
    private var exceptionBases: [String: [(base: String, suffix: String)]] = [:]
    private var fingerspell: [Character: KeySet] = [:]
    private var digitKey: [Character: Int] = [:]
    private var capNextKeys: KeySet?
    private var snakeKeys: KeySet?
    private var screamingKeys: KeySet?
    private var endIdentifierKeys: KeySet?
    private var spaceKeys: KeySet?

    // Planning state.
    private var engine: ChordEngine
    private var target: [Character] = []
    private var buffer: [Character] = []
    private var lineOffset = 0
    private var steps: [TypingStep] = []
    private var group = 0
    private var currentSource = 0..<0
    /// Buffer offset up to which the buffer is known to match the target line.
    private var matchedUpTo = 0
    private var wordCache: [String: [Plan]] = [:]
    private var usableCache: [KeySet: Bool] = [:]

    private func isUsable(_ k: KeySet) -> Bool {
        if let v = usableCache[k] { return v }
        let v = usable(k)
        usableCache[k] = v
        return v
    }

    public init(data: EngineData, mode: SubMode, rolloverLimit: Int = 6, usable: @escaping (KeySet) -> Bool = { _ in true }) {
        self.data = data
        self.mode = mode
        self.rolloverLimit = rolloverLimit
        self.usable = usable
        layout = data.layout
        var eff = data.shared.entries
        for (k, e) in data.dictionary(for: mode).entries { eff[k] = e }
        effective = eff
        engine = ChordEngine(data: data, subMode: mode)
        buildInventory()
    }

    // MARK: Inventory

    public static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    static func lower(_ c: Character) -> Character {
        let s = String(c).lowercased()
        return s.count == 1 ? s.first! : c
    }

    static func isLineBreak(_ c: Character) -> Bool { c == "\n" || c == "\r\n" || c == "\r" }

    private static func byKeys<T>(_ a: (key: KeySet, value: T), _ b: (key: KeySet, value: T)) -> Bool {
        (a.key.count, a.key.bits) < (b.key.count, b.key.bits)
    }

    private func buildInventory() {
        var symbolAlts: [String: [KeySet]] = [:]
        var mixedAlts: [String: [KeySet]] = [:]
        for (k, e) in effective.sorted(by: Self.byKeys) where isUsable(k) {
            switch e {
            case .command(let c):
                switch c {
                case .capitalizeNext: if capNextKeys == nil { capNextKeys = k }
                case .casing(.snake): if snakeKeys == nil { snakeKeys = k }
                case .casing(.screamingSnake): if screamingKeys == nil { screamingKeys = k }
                case .endIdentifier: if endIdentifierKeys == nil { endIdentifierKeys = k }
                default: break
                }
            case .text(let t):
                // Snippets move the cursor; the planner only uses text that ends at the cursor.
                guard !t.isSnippet, !t.text.isEmpty,
                      !t.text.contains(where: { $0 == " " || $0 == "\t" || $0.isNewline }) else { continue }
                if t.kind == .suffix {
                    if t.text.allSatisfy(\.isLetter) { suffixes.append((t.text, k)) }
                    continue
                }
                let chars = Array(t.text)
                if chars.allSatisfy(Self.isWordChar) {
                    if t.kind == .word { briefs[Self.lower(chars[0]), default: []].append((chars, k, t)) }
                } else if !chars.contains(where: Self.isWordChar) {
                    symbolAlts[t.text, default: []].append(k)
                } else {
                    mixedAlts[t.text, default: []].append(k)
                }
            }
        }
        for (text, alts) in symbolAlts.sorted(by: { $0.key < $1.key }) {
            let c = Array(text)
            symbols[c[0], default: []].append((c, alts))
        }
        // Longest first, so "std::" wins over a shorter entry with the same start.
        mixed = mixedAlts.map { (text: Array($0.key), alts: $0.value) }
            .sorted { ($1.text.count, String($0.text)) < ($0.text.count, String($1.text)) }

        for (key, result) in data.orthographyExceptions.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "+", maxSplits: 1).map(String.init)
            if parts.count == 2 { exceptionBases[result, default: []].append((parts[0], parts[1])) }
        }

        if let s = layout.spellIndex {
            for (k, letter) in layout.fingerspelling.sorted(by: Self.byKeys) {
                var chord = k
                chord.insert(s)
                guard effective[chord] == nil, isUsable(chord), letter.count == 1, let c = letter.first,
                      fingerspell[c] == nil else { continue }
                fingerspell[c] = chord
            }
        }
        for (i, key) in layout.keys.enumerated() {
            if case .number(let d) = key.role, digitKey[d] == nil { digitKey[d] = i }
        }
        for bank in Bank.allCases {
            var byText: [String: [KeySet]] = [:]
            for (k, text) in (layout.clusters[bank] ?? [:]).sorted(by: Self.byKeys) where !text.isEmpty {
                byText[text, default: []].append(k)
            }
            var index: [Character: [Cluster]] = [:]
            for (text, keys) in byText.sorted(by: { $0.key < $1.key }) {
                let c = Array(text)
                index[Self.lower(c[0]), default: []].append((c, keys))
            }
            clusters[bank] = index
        }
        spaceKeys = layout.spaceIndex.map { KeySet([$0]) }
        if let sp = spaceKeys, !isUsable(sp) { spaceKeys = nil }
    }

    // MARK: Planning

    public func plan(_ text: String) -> TypingGuide {
        engine = ChordEngine(data: data, subMode: mode)
        steps = []
        group = 0
        let chars = Array(text)
        var lineStart = 0
        var i = 0
        while i <= chars.count {
            if i == chars.count || Self.isLineBreak(chars[i]) {
                target = Array(chars[lineStart..<i])
                buffer = []
                buffer.reserveCapacity(target.count)
                lineOffset = lineStart
                planLine()
                if i == chars.count { break }
                // Return is a pass-through key: it types the new line and resets the context (Req 9.7).
                group += 1
                currentSource = i..<(i + 1)
                engine.contextReset()
                addStep(.key(.returnKey), .key, "\n", "new line", textEnd: i + 1)
                lineStart = i + 1
            }
            i += 1
        }
        return TypingGuide(mode: mode, steps: Self.mergeNormalSteps(steps))
    }

    /// Plans the rest of the line from character `offset`, for someone who has typed `text[..<offset]` by any
    /// route, for example part of a word and then Delete. The first chord continues right at `offset`: it gets
    /// no leading space in the middle of a word or after a space. `previous` is the planned context at the last
    /// step boundary before `offset`, which says whether a capital is pending. Very long lines are planned up to
    /// the end of a word about `maxLength` characters on; the full plan takes over from there.
    public func planContinuation(_ text: String, from offset: Int, previous: EngineContext? = nil,
                                 maxLength: Int = 2000) -> TypingContinuation {
        planContinuation(Array(text), from: offset, previous: previous, maxLength: maxLength)
    }

    public func planContinuation(_ chars: [Character], from offset: Int, previous: EngineContext? = nil,
                                 maxLength: Int = 2000) -> TypingContinuation {
        let start = max(0, min(offset, chars.count))
        var lineStart = start
        while lineStart > 0 && !Self.isLineBreak(chars[lineStart - 1]) { lineStart -= 1 }
        var lineEnd = start
        while lineEnd < chars.count && !Self.isLineBreak(chars[lineEnd]) { lineEnd += 1 }
        var end = lineEnd
        if lineEnd - start > maxLength {
            var e = start + maxLength
            while e < lineEnd && !(chars[e] == " " && chars[e - 1] != " ") { e += 1 }
            end = e
        }

        var ctx = OutputContext()
        let before: Character? = start > lineStart ? chars[start - 1] : nil
        let here: Character? = start < lineEnd ? chars[start] : nil
        if let b = before, b != " ", b != "\t", let h = here, h == " " {
            // At the end of a word whose space is still to come: the next chord gets its space as usual.
            ctx.atStart = false
            ctx.last = OutputContext.Last(kind: .word, attachRight: false, glue: false)
        }
        let midWord = before.map(Self.isWordChar) == true && here.map(Self.isWordChar) == true
        ctx.pendingCap = midWord ? false : previous?.value.pendingCap ?? false

        engine = ChordEngine(data: data, subMode: mode)
        engine.context = ctx
        steps = []
        group = 0
        target = Array(chars[lineStart..<lineEnd])
        buffer = Array(target[0..<(start - lineStart)])
        lineOffset = lineStart
        planLine(from: start - lineStart, to: end - lineStart)
        return TypingContinuation(guide: TypingGuide(mode: mode, steps: Self.mergeNormalSteps(steps)),
                                  start: start, end: end, startContext: EngineContext(ctx))
    }

    /// Plans `target` from `start` (the buffer already holds the text before it) up to the token end `limit`.
    private func planLine(from start: Int = 0, to limit: Int? = nil) {
        let n = target.count
        let stop = min(limit ?? n, n)
        var p = start
        while p < stop {
            group += 1
            if target[p] == "\t" {
                currentSource = global(p..<(p + 1))
                matchedUpTo = buffer.count
                buffer.append("\t")
                engine.contextReset()
                addStep(.key(.tab), .key, "\t", "Tab key")
                p += 1
                continue
            }
            var q = p
            while q < n && target[q] == " " { q += 1 }
            if q == n || target[q] == "\t" {
                typeSpaces(from: p, count: q - p)
                p = q
                continue
            }
            let e = runEnd(from: q)
            currentSource = global(q..<e)
            var done = false
            for (segs, end) in candidates(at: q, runEnd: e) {
                currentSource = global(q..<end)
                if run(segs, gapStart: p, gap: q - p, end: end) {
                    p = end
                    done = true
                    break
                }
            }
            if !done {
                // Always succeeds: the engine does not see Normal_Mode typing.
                currentSource = global(q..<e)
                _ = run([.normal(String(target[q..<e]))], gapStart: p, gap: q - p, end: e)
                p = e
            }
        }
    }

    private func global(_ r: Range<Int>) -> Range<Int> { (lineOffset + r.lowerBound)..<(lineOffset + r.upperBound) }

    private func runEnd(from q: Int) -> Int {
        let word = Self.isWordChar(target[q])
        var e = q + 1
        while e < target.count {
            let c = target[e]
            if c == " " || c == "\t" || Self.isWordChar(c) != word { break }
            e += 1
        }
        return e
    }

    private func typeSpaces(from p: Int, count: Int) {
        guard count > 0 else { return }
        matchedUpTo = buffer.count
        currentSource = global(p..<(p + count))
        for _ in 0..<count {
            if let sp = spaceKeys, let out = tryAppend(sp, join: false, expect: [" "]) {
                addStep(.chord(keys: layout.names(sp), shift: false), .space, out, "space",
                        parts: [PartSpec(text: "space", keys: sp, role: .space)])
            } else {
                buffer.append(" ")
                engine.contextReset()
                addStep(.typeNormally(" "), .normal, " ", Self.normalNote)
            }
        }
    }

    /// Candidate chord sequences for the token at `q`, best first, with the offset where each ends.
    private func candidates(at q: Int, runEnd e: Int) -> [([Seg], Int)] {
        var out: [([Seg], Int)] = []
        let n = target.count
        // Entries that mix letters and symbols, such as "std::" or "public:".
        for m in mixed where q + m.text.count <= n && target[q..<(q + m.text.count)].elementsEqual(m.text) {
            let end = q + m.text.count
            if end == n || Self.isWordChar(target[end]) != Self.isWordChar(target[end - 1]) || target[end] == " " {
                out.append(([.out(alts: m.alts, text: String(m.text), kind: .brief, note: "brief", parts: nil)], end))
                break
            }
        }
        let token = Array(target[q..<e])
        if Self.isWordChar(target[q]) {
            // A following space means a word may come next, which would continue the identifier.
            if token.contains("_"), let c = casingPlan(token, endIdentifier: e < n && target[e] == " ") {
                out.append((c.segs, e))
            }
            for c in wordCandidates(token, cap: engine.context.pendingCap) { out.append((c.segs, e)) }
        } else if let s = symbolPlan(token) {
            out.append((s.segs, e))
        }
        return out
    }

    // MARK: Words

    private func wordCandidates(_ w: [Character], cap: Bool) -> [Plan] {
        let key = (cap ? "1" : "0") + String(w)
        if let c = wordCache[key] { return c }
        let plans = Array(wordPlans(w, cap: cap, depth: 2).prefix(4))
        wordCache[key] = plans
        return plans
    }

    /// Direct segmentations and base + suffix plans (up to `depth` suffixes), cheapest first.
    private func wordPlans(_ w: [Character], cap: Bool, depth: Int) -> [Plan] {
        var out: [Plan] = []
        if let d = segment(w, cap: cap) { out.append(d) }
        if depth > 0, w.count >= 3, w.count <= Self.maxWordLength, w.allSatisfy(\.isLetter) {
            let word = String(w)
            let lowered = word.lowercased()
            let isException = exceptionBases[lowered] != nil
            // The rules always leave the suffix at the end of the word; only exceptions (say + ed = said) do not.
            for (sfx, keys) in suffixes where w.count > sfx.count && (isException || lowered.hasSuffix(sfx.lowercased())) {
                for base in baseCandidates(word, sfx)
                where Orthography.attach(word: base, suffix: sfx, exceptions: data.orthographyExceptions) == word {
                    guard let b = wordPlans(Array(base), cap: cap, depth: depth - 1).first else { continue }
                    let bonus = base + sfx == word ? 0 : Self.naturalBaseBonus
                    out.append((b.cost + Self.cost(keys) - bonus,
                                b.segs + [.suffix(keys: keys, suffix: sfx, base: base, result: word)]))
                }
            }
        }
        return out.enumerated().sorted { ($0.element.cost, $0.offset) < ($1.element.cost, $1.offset) }.map(\.element)
    }

    /// Words that could give `word` when `sfx` is attached; the caller checks with Orthography.attach.
    private func baseCandidates(_ word: String, _ sfx: String) -> [String] {
        var out = Set<String>()
        let w = Array(word)
        for k in [sfx.count, sfx.count + 1] where w.count > k {
            let stem = String(w.dropLast(k))
            out.insert(stem)
            out.insert(stem + "e")
            if stem.last == "i" { out.insert(String(stem.dropLast()) + "y") }
            if stem.last == "I" { out.insert(String(stem.dropLast()) + "Y") }
        }
        for (base, s) in exceptionBases[word.lowercased()] ?? [] where s == sfx.lowercased() {
            out.insert(word.first?.isUppercase == true ? ChordEngine.capitalizeFirst(base) : base)
        }
        out.remove("")
        return out.sorted()
    }

    private func matches(_ t: [Character], _ w: [Character], at pos: Int, cap: Bool) -> Bool {
        guard !t.isEmpty, pos + t.count <= w.count else { return false }
        if cap {
            guard String(w[pos]) == String(t[0]).uppercased() else { return false }
        } else {
            guard w[pos] == t[0] else { return false }
        }
        var j = 1
        while j < t.count {
            if w[pos + j] != t[j] { return false }
            j += 1
        }
        return true
    }

    private func produced(_ t: [Character], cap: Bool) -> String {
        cap ? ChordEngine.capitalizeFirst(String(t)) : String(t)
    }

    private func clusterMatches(_ bank: Bank, _ w: [Character], _ pos: Int, cap: Bool) -> [Cluster] {
        guard pos < w.count else { return [] }
        return (clusters[bank]?[Self.lower(w[pos])] ?? []).filter { matches($0.text, w, at: pos, cap: cap) }
    }

    /// A syllable chord from one key subset per bank that the dictionaries do not take over, with the subsets.
    private func composeKeys(_ o: [KeySet], _ v: [KeySet], _ c: [KeySet])
        -> (keys: KeySet, onset: KeySet, vowel: KeySet, coda: KeySet)? {
        for a in o {
            for b in v {
                for d in c {
                    let u = a.union(b).union(d)
                    if effective[u] == nil && u.count <= rolloverLimit && isUsable(u) { return (u, a, b, d) }
                }
            }
        }
        return nil
    }

    /// Spell key, then the letter's keys, split into capital key + lowercase letter for a capital.
    private func fingerspellParts(_ chord: KeySet, output: Character) -> [PartSpec] {
        var parts: [PartSpec] = []
        var rest = chord
        if let s = layout.spellIndex, rest.contains(s) {
            rest.remove(s)
            parts.append(PartSpec(text: "spell", keys: KeySet([s]), role: .spell))
        }
        let letter = layout.fingerspelling[rest] ?? String(output)
        let lower = letter.lowercased()
        if lower != letter, let lc = lower.first, var lk = fingerspell[lc] {
            if let s = layout.spellIndex { lk.remove(s) }
            if rest.isSuperset(of: lk) && !rest.subtracting(lk).isEmpty {
                parts.append(PartSpec(text: "capital", keys: rest.subtracting(lk), role: .capital))
                parts.append(PartSpec(text: lower, keys: lk, role: .letter))
                return parts
            }
        }
        parts.append(PartSpec(text: letter, keys: rest, role: .letter))
        return parts
    }

    /// A fingerspelling chord whose output (after a pending capital) is `c`, with the fewest keys.
    private func fingerspellChord(_ c: Character, cap: Bool) -> KeySet? {
        var options: [KeySet] = []
        if let k = fingerspell[c], !cap || String(c).uppercased() == String(c) { options.append(k) }
        if cap, c.isUppercase {
            let lc = Self.lower(c)
            if lc != c, String(lc).uppercased() == String(c), let k = fingerspell[lc] { options.append(k) }
        }
        return options.min { $0.count < $1.count }
    }

    private func cancelChord(_ c: Character) -> (KeySet, String)? {
        if let k = fingerspell[c] { return (k, ChordEngine.capitalizeFirst(String(c))) }
        for l in "abcdefghijklmnopqrstuvwxyz" {
            if let k = fingerspell[l] { return (k, String(l).uppercased()) }
        }
        return nil
    }

    private static let noCluster: [Cluster] = [([], [KeySet()])]

    /// Cheapest split of a letter/digit run into chords, tracking the engine's pending capital.
    /// Dynamic programming over (position, capital pending, previous output); segments are only built
    /// for choices that win.
    private func segment(_ w: [Character], cap startCap: Bool) -> Plan? {
        let n = w.count
        guard n > 0, n <= Self.maxWordLength else { return nil }
        let lw = w.map(Self.lower)
        let impossible = Int.max, unknown = -1
        func stateKey(_ i: Int, _ cap: Bool, _ last: Last) -> Int { (i * 2 + (cap ? 1 : 0)) * 4 + last.rawValue }
        var costs = [Int](repeating: unknown, count: (n + 1) * 8)
        var choices = [(seg: Seg, next: Int)?](repeating: nil, count: (n + 1) * 8)

        /// Cost of joining chord `k` onto the previous output, if it has to be joined.
        func join(_ k: KeySet, _ last: Last, glue: Bool) -> Int {
            guard last == .word || (last == .glue && !glue) else { return 0 }
            return spaceJoined(k) != nil ? Self.spaceJoinCost : Self.shiftCost
        }

        func clusterList(_ bank: Bank, _ pos: Int) -> [Cluster] {
            pos < n ? clusters[bank]?[lw[pos]] ?? [] : []
        }

        @discardableResult
        func solve(_ i: Int, _ cap: Bool, _ last: Last) -> Int {
            if i == n { return 0 }
            let key = stateKey(i, cap, last)
            if costs[key] != unknown { return costs[key] }
            costs[key] = impossible   // no cycles are possible, but never recurse into an open state
            var best = impossible
            var choice: (seg: Seg, next: Int)?
            func consider(_ cost: Int, _ ni: Int, _ ncap: Bool, _ nlast: Last, _ make: () -> Seg) {
                let rest = solve(ni, ncap, nlast)
                guard rest != impossible, cost + rest < best else { return }
                best = cost + rest
                choice = (make(), ni == n ? -1 : stateKey(ni, ncap, nlast))
            }
            let c = w[i]

            // Capitalize_Next before an uppercase letter (Req 9.3).
            if !cap, c.isUppercase, let k = capNextKeys {
                consider(Self.cost(k), i, true, last) { .command(keys: k, note: "capitalize the next word") }
            }
            // A pending capital before a lowercase letter: use it up on a throwaway letter.
            if cap, c.isLowercase, let throwaway = cancelChord(c) {
                consider(Self.cost(throwaway.0) + Self.chordCost + join(throwaway.0, last, glue: true), i, false, .reset) {
                    .cancel(keys: throwaway.0, letter: throwaway.1)
                }
            }
            if let k = fingerspellChord(c, cap: cap) {
                consider(Self.cost(k) + join(k, last, glue: true), i + 1, false, .glue) {
                    .out(alts: [k], text: String(c), kind: .fingerspell, note: "fingerspelled letter",
                         parts: fingerspellParts(k, output: c))
                }
            }
            // Digits: one chord types number keys in left-to-right keyboard order (Req 6.6).
            if let d0 = digitKey[c] {
                var keys = KeySet([d0])
                var lastIndex = d0
                var j = i + 1
                while true {
                    if effective[keys] == nil && isUsable(keys) {
                        let k = keys, end = j
                        consider(Self.cost(k) + join(k, last, glue: true), end, false, .glue) {
                            let parts = k.indices.compactMap { idx -> PartSpec? in
                                guard case .number(let d) = layout.keys[idx].role else { return nil }
                                return PartSpec(text: String(d), keys: KeySet([idx]), role: .digit)
                            }
                            return .out(alts: [k], text: String(w[i..<end]), kind: .digits, note: "digits", parts: parts)
                        }
                    }
                    guard j < n, keys.count < rolloverLimit, let d = digitKey[w[j]], d > lastIndex else { break }
                    keys.insert(d)
                    lastIndex = d
                    j += 1
                }
            }
            for b in briefs[lw[i]] ?? [] where matches(b.text, w, at: i, cap: cap) {
                let glue = b.entry.glue
                let nextCap = b.entry.capitalizeNext && mode == .english
                consider(Self.cost(b.keys) + join(b.keys, last, glue: glue), i + b.text.count, nextCap, glue ? .glue : .word) {
                    .out(alts: [b.keys], text: produced(b.text, cap: cap), kind: .brief, note: "brief", parts: nil)
                }
            }
            // Syllable_Composition: onset + vowel + coda (Req 7).
            for o in Self.noCluster + clusterList(.onset, i) where o.text.isEmpty || matches(o.text, w, at: i, cap: cap) {
                let p1 = i + o.text.count, capV = cap && o.text.isEmpty
                // Vowel clusters before "no vowel", so "the" uses the vowel key rather than a silent-e coda.
                for v in clusterList(.vowel, p1) + Self.noCluster
                where v.text.isEmpty || matches(v.text, w, at: p1, cap: capV) {
                    let p2 = p1 + v.text.count, capC = capV && v.text.isEmpty
                    for cd in Self.noCluster + clusterList(.coda, p2)
                    where cd.text.isEmpty || matches(cd.text, w, at: p2, cap: capC) {
                        let end = p2 + cd.text.count
                        guard end > i, let chosen = composeKeys(o.keys, v.keys, cd.keys) else { continue }
                        let k = chosen.keys
                        consider(Self.cost(k) + join(k, last, glue: false), end, false, .word) {
                            let texts = [o.text, v.text, cd.text].filter { !$0.isEmpty }.map { String($0) }
                            let parts = [PartSpec(text: String(o.text), keys: chosen.onset, role: .onset),
                                         PartSpec(text: String(v.text), keys: chosen.vowel, role: .vowel),
                                         PartSpec(text: String(cd.text), keys: chosen.coda, role: .coda)]
                                .filter { !$0.text.isEmpty }
                            return .out(alts: [k], text: produced(o.text + v.text + cd.text, cap: cap), kind: .syllable,
                                        note: "syllable: " + texts.joined(separator: " + "), parts: parts)
                        }
                    }
                }
            }
            consider(Self.normalCost, i + 1, cap, .reset) { .normal(String(c)) }
            costs[key] = best
            choices[key] = choice
            return best
        }

        let total = solve(0, startCap, .start)
        guard total != impossible else { return nil }
        var segs: [Seg] = []
        var key = stateKey(0, startCap, .start)
        while key >= 0, let c = choices[key] {
            segs.append(c.seg)
            key = c.next
        }
        return (total, Self.mergeNormals(segs))
    }

    /// snake_case and SCREAMING_SNAKE_CASE identifiers through a Casing_Mode (Req 14).
    private func casingPlan(_ w: [Character], endIdentifier: Bool) -> Plan? {
        let parts = w.split(separator: "_", omittingEmptySubsequences: false).map(Array.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), w.count <= Self.maxWordLength else { return nil }
        let upper: Bool
        if !w.contains(where: \.isUppercase) { upper = false }
        else if !w.contains(where: \.isLowercase) { upper = true }
        else { return nil }
        guard let start = upper ? screamingKeys : snakeKeys else { return nil }
        var segs: [Seg] = [.command(keys: start, note: upper ? "start a SCREAMING_SNAKE_CASE identifier"
                                                              : "start a snake_case identifier")]
        var cost = Self.cost(start)
        for (pi, part) in parts.enumerated() {
            // A word made only of digits is appended without "_" (Req 14.7).
            if pi > 0 && part.allSatisfy(\.isNumber) { return nil }
            guard let plan = segment(part.map(Self.lower), cap: false) else { return nil }
            cost += plan.cost
            for (si, s) in plan.segs.enumerated() {
                guard case let .out(alts, text, kind, note, parts) = s else { return nil }
                var t = upper ? text.uppercased() : text
                if pi > 0 && si == 0 { t = "_" + t }
                segs.append(.out(alts: alts, text: t, kind: kind, note: note, parts: parts))
            }
        }
        if endIdentifier {
            guard let e = endIdentifierKeys else { return nil }
            segs.append(.command(keys: e, note: "end the identifier"))
            cost += Self.cost(e)
        }
        return (cost, segs)
    }

    // MARK: Symbols

    private func symbolPlan(_ w: [Character]) -> Plan? {
        let n = w.count
        var best = [Plan?](repeating: nil, count: n + 1)
        best[n] = (0, [])
        for i in stride(from: n - 1, through: 0, by: -1) {
            var b: Plan?
            for s in symbols[w[i]] ?? [] where i + s.text.count <= n && w[i..<(i + s.text.count)].elementsEqual(s.text) {
                let c = Self.cost(s.alts[0])
                if let next = best[i + s.text.count], b == nil || c + next.cost < b!.cost {
                    b = (c + next.cost, [.out(alts: s.alts, text: String(s.text), kind: .symbol, note: "symbol", parts: nil)]
                         + next.segs)
                }
            }
            if let next = best[i + 1], b == nil || Self.normalCost + next.cost < b!.cost {
                b = (Self.normalCost + next.cost, [.normal(String(w[i]))] + next.segs)
            }
            best[i] = b
        }
        return best[0].map { ($0.cost, Self.mergeNormals($0.segs)) }
    }

    private static func mergeNormals(_ segs: [Seg]) -> [Seg] {
        var out: [Seg] = []
        for s in segs {
            if case .normal(let b) = s, case .normal(let a)? = out.last {
                out[out.count - 1] = .normal(a + b)
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Simulation

    private func addStep(_ action: TypingStep.Action, _ kind: TypingStep.Kind, _ output: String, _ note: String,
                         textEnd: Int? = nil, parts: [PartSpec] = []) {
        var step = TypingStep(action: action, kind: kind, output: output, note: note, source: currentSource, group: group,
                              textEnd: textEnd ?? lineOffset + buffer.count)
        step.parts = parts.map { TypingStep.Part(text: $0.text, keys: layout.names($0.keys), role: $0.role) }
        if textEnd == nil {
            var l = min(matchedUpTo, buffer.count)
            while l < buffer.count && l < target.count && buffer[l] == target[l] { l += 1 }
            step.tail = String(buffer[l...])
        }
        step.contextAfter = engine.currentContext
        steps.append(step)
    }

    private func chordAction(_ k: KeySet, join: Bool) -> TypingStep.Action {
        .chord(keys: layout.names(k), shift: join)
    }

    /// The chord with the Space_Key added, which joins it, if the keyboard can register that.
    private func spaceJoined(_ k: KeySet) -> KeySet? {
        guard let sp = spaceKeys, !k.isEmpty, !k.isSuperset(of: sp), k.count + sp.count <= rolloverLimit else { return nil }
        let joined = k.union(sp)
        return isUsable(joined) ? joined : nil
    }

    /// Translates a chord; keeps the result only if it inserts exactly `expect` at the end of the buffer.
    private func tryAppend(_ k: KeySet, join: Bool, expect: [Character]) -> String? {
        let saved = engine.context
        guard let r = try? engine.translate(k, join: join), r.signal == nil, !r.modeSwitched else {
            engine.context = saved
            return nil
        }
        var out: [Character] = []
        for a in r.actions {
            guard case .insert(let s) = a else { engine.context = saved; return nil }
            out += s
        }
        guard out == expect else { engine.context = saved; return nil }
        buffer += out
        return String(out)
    }

    /// Alternatives for the same text (such as opening and closing quotes), ordered so that the one whose
    /// attach-right flag matches what follows in the text is tried first.
    private func ordered(_ alts: [KeySet], after count: Int) -> [KeySet] {
        guard alts.count > 1 else { return alts }
        let pos = buffer.count + count
        let wantAttachRight = pos < target.count && target[pos] != " " && target[pos] != "\t"
        func attachesRight(_ k: KeySet) -> Bool {
            if case .text(let t)? = effective[k] { return t.attachRight }
            return false
        }
        func capNext(_ k: KeySet) -> Bool {
            if case .text(let t)? = effective[k] { return t.capitalizeNext && mode == .english }
            return false
        }
        // Sentence punctuation with and without the automatic capital ("." and the abbreviation "."):
        // capitalize only when the next letter on the line is uppercase ("Mr. and" but "Mr. Dursley").
        var p = pos
        while p < target.count && !target[p].isLetter && !target[p].isNumber { p += 1 }
        let wantCap = p < target.count ? target[p].isUppercase : true
        return alts.sorted {
            let a = (attachesRight($0) != wantAttachRight ? 1 : 0, capNext($0) != wantCap ? 1 : 0)
            let b = (attachesRight($1) != wantAttachRight ? 1 : 0, capNext($1) != wantCap ? 1 : 0)
            return a < b
        }
    }

    /// Emits text, producing the pending gap of spaces with the automatic space, Shift, or Space chords.
    private func emitText(_ alts: [KeySet], _ text: [Character], gapLeft: inout Int,
                          kind: TypingStep.Kind, note: String, parts: [PartSpec]? = nil) -> Bool {
        for pass in 0..<2 {
            if pass == 1 {
                // The engine's spacing does not give the gap: type the spaces with the Space_Key.
                guard gapLeft > 0, let sp = spaceKeys else { return false }
                for _ in 0..<gapLeft {
                    guard let out = tryAppend(sp, join: false, expect: [" "]) else { return false }
                    addStep(chordAction(sp, join: false), .space, out, "space",
                            parts: [PartSpec(text: "space", keys: sp, role: .space)])
                }
                gapLeft = 0
            }
            let expect = Array(repeating: Character(" "), count: gapLeft) + text
            let alternatives = ordered(alts, after: expect.count)
            // As it is; joined by holding the space bar with it; joined with Shift, for chords that can't take the
            // space bar (one key too many, or a combination the keyboard drops).
            for how in 0..<3 {
                for k in alternatives {
                    let chord = how == 1 ? spaceJoined(k) : k
                    guard let chord, let out = tryAppend(chord, join: how == 2, expect: expect) else { continue }
                    let role: TypingStep.Part.Role = kind == .symbol ? .symbol : .word
                    var p = parts ?? [PartSpec(text: String(text), keys: k, role: role)]
                    if how == 1 { p.insert(PartSpec(text: "join", keys: chord.subtracting(k), role: .join), at: 0) }
                    addStep(chordAction(chord, join: how == 2), kind, out, note, parts: p)
                    gapLeft = 0
                    return true
                }
            }
            if gapLeft == 0 { return false }
        }
        return false
    }

    /// Runs a candidate for the token that starts at `gapStart` (with `gap` spaces before its text).
    /// On failure, restores the engine, buffer, and steps and returns false.
    private func run(_ segs: [Seg], gapStart: Int, gap: Int, end: Int) -> Bool {
        let savedContext = engine.context
        let savedSteps = steps.count
        let wordStart = gapStart + gap
        var gapLeft = gap
        func fail() -> Bool {
            engine.context = savedContext
            buffer.removeSubrange(gapStart...)
            steps.removeSubrange(savedSteps...)
            return false
        }
        precondition(buffer.count == gapStart)
        matchedUpTo = gapStart

        for seg in segs {
            switch seg {
            case let .command(keys, note):
                guard let r = try? engine.translate(keys, join: false), r.signal == nil, r.actions.isEmpty,
                      !r.modeSwitched else { return fail() }
                addStep(chordAction(keys, join: false), .command, "", note,
                        parts: [PartSpec(text: note, keys: keys, role: .command)])

            case let .out(alts, text, kind, note, parts):
                guard emitText(alts, Array(text), gapLeft: &gapLeft, kind: kind, note: note, parts: parts) else {
                    return fail()
                }

            case let .cancel(keys, letter):
                guard emitText([keys], Array(letter), gapLeft: &gapLeft, kind: .cancelCapital,
                               note: "throwaway letter: uses up the automatic capital",
                               parts: fingerspellParts(keys, output: letter.first ?? " ")),
                      buffer.count > wordStart else { return fail() }
                // Delete is a pass-through key: it removes the letter and resets the context (Req 9.7, 9.9).
                buffer.removeLast()
                engine.contextReset()
                addStep(.key(.delete), .key, "", "delete the throwaway letter")

            case let .suffix(keys, sfx, base, result):
                guard gapLeft == 0, let r = try? engine.translate(keys, join: false), r.signal == nil else { return fail() }
                var deleted = 0
                var inserted: [Character] = []
                for a in r.actions {
                    switch a {
                    case .deleteBackward(let k) where inserted.isEmpty: deleted += k
                    case .insert(let s): inserted += s
                    default: return fail()
                    }
                }
                guard deleted <= buffer.count - wordStart else { return fail() }
                buffer.removeLast(deleted)
                buffer += inserted
                guard buffer[wordStart...].elementsEqual(result) else { return fail() }
                addStep(chordAction(keys, join: false), .suffix, String(inserted), "suffix: \(base) + \(sfx) → \(result)",
                        parts: [PartSpec(text: "-" + sfx, keys: keys, role: .suffix)])

            case let .normal(text):
                // Leaving and re-entering chord mode resets the context (Req 1.10).
                let s = String(repeating: " ", count: gapLeft) + text
                gapLeft = 0
                buffer += s
                engine.contextReset()
                addStep(.typeNormally(s), .normal, s, Self.normalNote)
            }
        }
        guard gapLeft == 0, buffer.count == end, buffer[gapStart..<end].elementsEqual(target[gapStart..<end]) else {
            return fail()
        }
        return true
    }

    /// Joins consecutive Normal_Mode steps so the guide says "tap Option" once for a run of them.
    private static func mergeNormalSteps(_ steps: [TypingStep]) -> [TypingStep] {
        var out: [TypingStep] = []
        out.reserveCapacity(steps.count)
        for s in steps {
            if case .typeNormally(let b) = s.action, let last = out.last, case .typeNormally(let a) = last.action {
                var m = last
                m.action = .typeNormally(a + b)
                m.output = a + b
                m.source = min(last.source.lowerBound, s.source.lowerBound)..<max(last.source.upperBound, s.source.upperBound)
                m.textEnd = s.textEnd
                m.tail = s.tail
                m.contextAfter = s.contextAfter
                out[out.count - 1] = m
            } else {
                out.append(s)
            }
        }
        return out
    }
}
