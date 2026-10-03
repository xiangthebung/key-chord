// Chord_Engine: chord detection (Req 3), translation (Req 6-8), spacing and capitalization (Req 9),
// suffixes (Req 10), undo (Req 11), C++ snippets and casing (Req 12-14).
// Deterministic and free of platform dependencies (Req 19.1, 19.2).

public enum EngineSignal: Equatable, Sendable {
    case untranslatable
    case undoEmpty
}

public struct EngineResult: Equatable, Sendable {
    public var actions: [OutputAction] = []
    public var signal: EngineSignal?
    /// True when a Mode_Switch chord changed the sub-mode.
    public var modeSwitched = false

    public init(actions: [OutputAction] = [], signal: EngineSignal? = nil, modeSwitched: Bool = false) {
        self.actions = actions
        self.signal = signal
        self.modeSwitched = modeSwitched
    }
}

public enum EngineError: Error, Equatable {
    case invariant(String)
}

/// What the engine knows about its recent output (Glossary: Output_Context).
struct OutputContext: Equatable, Sendable {
    struct Last: Equatable, Sendable {
        var kind: OutputKind
        var attachRight: Bool
        var glue: Bool
    }
    struct Snippet: Equatable, Sendable {
        /// Characters of the snippet text that are after the cursor.
        var tail: Int
        var attachRight: Bool
        var kind: OutputKind
    }
    struct Casing: Equatable, Sendable {
        var mode: CasingMode
        var words = 0
    }

    /// True until the first output after a Context_Reset.
    var atStart = true
    var last: Last?
    var pendingCap = false
    var casing: Casing?
    /// Open snippets, innermost last.
    var snippets: [Snippet] = []
    /// The previous output was a Snippet: the next one goes at the cursor with no leading space.
    var afterSnippet = false
    /// The word before the cursor, for Orthography_Rules; nil if unknown.
    var prevWord: String?
}

/// A snapshot of the engine's output context (spacing, pending capital, casing, open snippets). The Typing
/// Guide stores the planned context after each step, so the engine can be put back on the plan after the
/// user fixes a mistake with Delete (which resets the context).
public struct EngineContext: Equatable, Sendable {
    let value: OutputContext
    init(_ v: OutputContext) { value = v }
    /// The context of a fresh engine: start of text, no pending capital.
    public static let initial = EngineContext(OutputContext())
}

/// One translated chord's effect, enough to reverse it exactly (Req 11.2, 11.3).
struct UndoRecord: Equatable {
    var before: OutputContext
    var deleted = ""
    var insertedBefore = 0
    var insertedAfter = 0
    var movedRight = 0
}

public final class ChordEngine {
    public static let undoCapacity = 100

    public private(set) var data: EngineData
    public private(set) var subMode: SubMode

    // In-progress chord.
    private var held = Set<Int>()
    private var chordKeys = KeySet()
    private var join = false

    var context = OutputContext()
    private(set) var history: [UndoRecord] = []

    public init(data: EngineData, subMode: SubMode = .english) {
        self.data = data
        self.subMode = subMode
    }

    public var chordInProgress: Bool { !chordKeys.isEmpty }
    public var heldChordKeys: Set<Int> { held }
    public var undoDepth: Int { history.count }

    // MARK: Configuration

    public func replaceData(_ d: EngineData) {
        data = d
        discardChord()
        contextReset()
    }

    /// Changes the sub-mode (menu or router). Discards the chord and resets context (Req 1.10).
    public func setSubMode(_ m: SubMode) {
        discardChord()
        subMode = m
        contextReset()
    }

    // MARK: Chord detection (Req 3)

    /// A Chord_Key press. Auto-repeat events must not be passed here (Req 3.5).
    public func keyDown(_ index: Int, shift: Bool) {
        held.insert(index)
        chordKeys.insert(index)
        if shift { join = true }
    }

    /// The Join_Modifier was pressed; sets the Join flag of an in-progress chord (Req 3.6).
    public func joinPressed() {
        if chordInProgress { join = true }
    }

    /// A Chord_Key release. Returns the translation when the chord completes (Req 3.3).
    /// `capsLock`: whether Caps Lock is on at this moment (Req 9.10).
    public func keyUp(_ index: Int, capsLock: Bool = false) throws -> EngineResult? {
        guard held.remove(index) != nil else { return nil }   // Req 3.10
        guard held.isEmpty else { return nil }
        let keys = chordKeys
        let j = join
        chordKeys = KeySet()
        join = false
        return try translate(keys, join: j, capsLock: capsLock)
    }

    public func discardChord() {
        held.removeAll()
        chordKeys = KeySet()
        join = false
    }

    /// Req 3.11: discard the chord if none of its held keys is physically down.
    public func syncPhysical(held physical: Set<Int>) {
        if chordInProgress && held.isDisjoint(with: physical) { discardChord() }
    }

    public var currentContext: EngineContext { EngineContext(context) }

    /// Replaces the output context; the undo history is kept.
    public func restore(_ c: EngineContext) { context = c.value }

    /// Req 9.8 / 9.9.
    public func contextReset() {
        let cap = context.pendingCap
        context = OutputContext()
        context.pendingCap = cap
        history.removeAll()
    }

    // MARK: Translation (Req 6)

    /// `capsLock`: output the text in uppercase, as Caps Lock does for typed letters (Req 9.10).
    public func translate(_ chord: KeySet, join: Bool, capsLock: Bool = false) throws -> EngineResult {
        let layout = data.layout
        var keys = chord
        var join = join
        if let sp = layout.spaceIndex, keys.contains(sp) {
            if keys.count == 1 {
                return try emit(TextEntry(text: " ", attachLeft: true, attachRight: true, kind: .symbol),
                                join: join, capsLock: capsLock)
            }
            // Req 3.6: the space bar held with other keys joins the chord onto the previous output.
            keys.remove(sp)
            join = true
        }
        guard !keys.isEmpty else { return untranslatable() }

        if let e = data.dictionary(for: subMode)[keys] ?? data.shared[keys] {
            switch e {
            case .text(let t): return try emit(t, join: join, capsLock: capsLock)
            case .command(let c): return try run(c)
            }
        }
        if let s = layout.spellIndex, keys.contains(s) {
            guard let letter = layout.fingerspelling[keys.subtracting(KeySet([s]))] else { return untranslatable() }
            return try emit(TextEntry(text: letter, glue: true, kind: .word), join: join, capsLock: capsLock)
        }
        if keys.isSubset(of: layout.numberMask) {
            var digits = ""
            for i in keys.indices { if case .number(let d) = layout.keys[i].role { digits.append(d) } }
            return try emit(TextEntry(text: digits, glue: true, kind: .word), join: join, capsLock: capsLock)
        }
        if keys.isSubset(of: layout.allBanksMask) {
            var text = ""
            for bank in [Bank.onset, .vowel, .coda] {
                let part = keys.intersection(layout.bankMasks[bank]!)
                if part.isEmpty { continue }
                guard let s = layout.clusters[bank]?[part] else { return untranslatable() }
                text += s
            }
            return try emit(TextEntry(text: text, kind: .word), join: join, capsLock: capsLock)
        }
        return untranslatable()
    }

    private func untranslatable() -> EngineResult { EngineResult(signal: .untranslatable) }

    private func record(_ r: UndoRecord) {
        history.append(r)
        if history.count > Self.undoCapacity { history.removeFirst(history.count - Self.undoCapacity) }
    }

    // MARK: Commands

    private func run(_ c: Command) throws -> EngineResult {
        switch c {
        case .undo:
            guard let r = history.popLast() else { return EngineResult(signal: .undoEmpty) }
            guard r.insertedBefore >= 0, r.insertedAfter >= 0, r.movedRight >= 0 else {
                throw EngineError.invariant("corrupt undo record")
            }
            var a: [OutputAction] = []
            if r.movedRight > 0 { a.append(.moveLeft(r.movedRight)) }
            if r.insertedAfter > 0 { a.append(.deleteForward(r.insertedAfter)) }
            if r.insertedBefore > 0 { a.append(.deleteBackward(r.insertedBefore)) }
            if !r.deleted.isEmpty { a.append(.insert(r.deleted)) }
            context = r.before
            return EngineResult(actions: a)

        case .modeSwitch:
            subMode = subMode == .english ? .cpp : .english
            contextReset()
            return EngineResult(modeSwitched: true)

        case .capitalizeNext:
            record(UndoRecord(before: context))
            context.pendingCap = true
            return EngineResult()

        case .casing(let m):
            record(UndoRecord(before: context))
            context.casing = OutputContext.Casing(mode: m)
            return EngineResult()

        case .endIdentifier:
            record(UndoRecord(before: context))
            context.casing = nil
            return EngineResult()

        case .snippetExit:
            let before = context
            guard let f = context.snippets.popLast() else { return untranslatable() }
            context.last = OutputContext.Last(kind: f.kind, attachRight: f.attachRight, glue: false)
            context.afterSnippet = false
            context.casing = nil
            context.prevWord = nil
            record(UndoRecord(before: before, movedRight: f.tail))
            return EngineResult(actions: f.tail > 0 ? [.moveRight(f.tail)] : [])
        }
    }

    // MARK: Text output

    /// Req 9.1 plus 13.6: whether a single space goes before this output.
    private func needsSpace(_ e: TextEntry, join: Bool) -> Bool {
        if context.atStart || context.afterSnippet { return false }
        guard let last = context.last else { return false }
        if last.attachRight || e.attachLeft || join { return false }
        if e.wordAttach && (last.kind == .word || last.kind == .suffix) { return false }
        if e.glue && last.glue { return false }
        return true
    }

    static func capitalizeFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func lowercaseFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// Req 9.10: with Caps Lock on, the text a chord types comes out in uppercase.
    private func emit(_ e: TextEntry, join: Bool, capsLock: Bool = false) throws -> EngineResult {
        let before = context
        var rec = UndoRecord(before: before)
        var actions: [OutputAction] = []

        if e.kind == .suffix {
            // Req 10.1, 10.2, 10.9: attach to the previous word without a space.
            var inserted = capsLock ? e.text.uppercased() : e.text
            if let prev = context.prevWord {
                let word = Orthography.attach(word: prev, suffix: e.text, exceptions: data.orthographyExceptions)
                let p = Self.commonPrefix(prev, word)
                rec.deleted = String(prev.dropFirst(p))
                inserted = String(word.dropFirst(p))
                if capsLock { inserted = inserted.uppercased() }   // only what this chord types
                context.prevWord = String(word.prefix(p)) + inserted
            } else {
                context.prevWord = nil
            }
            if !rec.deleted.isEmpty { actions.append(.deleteBackward(rec.deleted.count)) }
            if !inserted.isEmpty { actions.append(.insert(inserted)) }
            rec.insertedBefore = inserted.count
            context.last = OutputContext.Last(kind: .suffix, attachRight: e.attachRight, glue: false)
            context.atStart = false
            context.afterSnippet = false
            record(rec)
            return EngineResult(actions: actions)
        }

        if e.kind == .symbol { context.casing = nil }   // Req 14.9
        let spaced = needsSpace(e, join: join)
        var text = e.text
        var cursorFromEnd = e.cursorFromEnd
        var separator = spaced ? " " : ""
        /// A word output that continues the previous word (for Orthography_Rules).
        var continuesWord = false

        if e.kind == .word {
            if context.pendingCap {
                text = Self.capitalizeFirst(text)
                context.pendingCap = false
            }
            if var c = context.casing {
                // Req 14.3 - 14.8. Join and Glue runs continue the current word; digits append.
                let continuing = c.words > 0 && (join || (e.glue && before.last?.glue == true))
                let digits = c.words > 0 && !text.isEmpty && text.allSatisfy(\.isNumber)
                let newWord = !continuing && !digits
                switch c.mode {
                case .snake: text = text.lowercased()
                case .screamingSnake: text = text.uppercased()
                case .camel: if newWord { text = c.words == 0 ? Self.lowercaseFirst(text) : Self.capitalizeFirst(text) }
                case .pascal: if newWord { text = Self.capitalizeFirst(text) }
                }
                if c.words > 0 {
                    separator = newWord && (c.mode == .snake || c.mode == .screamingSnake) ? "_" : ""
                }
                continuesWord = !newWord
                if newWord { c.words += 1 }
                context.casing = c
            } else {
                continuesWord = !spaced && !before.afterSnippet &&
                    (before.last?.kind == .word || before.last?.kind == .suffix)
            }
        }
        if capsLock {
            // Uppercasing can change the length ("ß" -> "SS"), so the cursor offset is recounted.
            if let k = cursorFromEnd { cursorFromEnd = String(text.suffix(k)).uppercased().count }
            text = text.uppercased()
        }
        if e.kind == .word {
            context.prevWord = continuesWord ? (context.prevWord ?? "") + text : text
        } else {
            context.prevWord = nil
        }

        let full = separator + text
        actions.append(.insert(full))
        if let k = cursorFromEnd {
            guard k <= text.count else { throw EngineError.invariant("cursor marker outside text") }
            if k > 0 { actions.append(.moveLeft(k)) }
            context.snippets.append(OutputContext.Snippet(tail: k, attachRight: e.attachRight, kind: e.kind))
            context.afterSnippet = true
            rec.insertedBefore = full.count - k
            rec.insertedAfter = k
        } else {
            context.afterSnippet = false
            rec.insertedBefore = full.count
        }
        context.last = OutputContext.Last(kind: e.kind, attachRight: e.attachRight, glue: e.glue)
        context.atStart = false
        if e.capitalizeNext && subMode == .english { context.pendingCap = true }   // Req 9.2, 9.4
        record(rec)
        return EngineResult(actions: actions)
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            if x != y { break }
            n += 1
        }
        return n
    }
}
