// Core data model shared by the Chord_Engine, Event_Router, Dictionary_Loader and probe.
// Standard library only: this module must not depend on macOS frameworks (Req 19.1).

/// macOS virtual key code. Kept as a plain integer so the core stays platform independent.
public typealias KeyCode = UInt16

/// A set of Layout key indices (at most 64 keys per Layout).
public struct KeySet: Hashable, Sendable, Sequence, CustomStringConvertible {
    public private(set) var bits: UInt64

    public init() { bits = 0 }
    public init(bits: UInt64) { self.bits = bits }
    public init<S: Sequence>(_ indices: S) where S.Element == Int {
        bits = 0
        for i in indices { insert(i) }
    }

    public var isEmpty: Bool { bits == 0 }
    public var count: Int { bits.nonzeroBitCount }
    public func contains(_ i: Int) -> Bool { i >= 0 && i < 64 && bits & (1 << UInt64(i)) != 0 }
    public mutating func insert(_ i: Int) { precondition(i >= 0 && i < 64); bits |= 1 << UInt64(i) }
    public mutating func remove(_ i: Int) { if i >= 0 && i < 64 { bits &= ~(1 << UInt64(i)) } }
    public func union(_ o: KeySet) -> KeySet { KeySet(bits: bits | o.bits) }
    public func intersection(_ o: KeySet) -> KeySet { KeySet(bits: bits & o.bits) }
    public func subtracting(_ o: KeySet) -> KeySet { KeySet(bits: bits & ~o.bits) }
    public func isSubset(of o: KeySet) -> Bool { bits & ~o.bits == 0 }
    public func isSuperset(of o: KeySet) -> Bool { o.isSubset(of: self) }

    /// Indices in ascending order (ascending Layout order).
    public var indices: [Int] {
        var out: [Int] = []
        var b = bits
        while b != 0 {
            let i = b.trailingZeroBitCount
            out.append(i)
            b &= b - 1
        }
        return out
    }

    public func makeIterator() -> IndexingIterator<[Int]> { indices.makeIterator() }
    public var description: String { "KeySet(\(indices))" }
}

public enum Bank: String, Sendable, CaseIterable {
    case onset, vowel, coda
}

public enum KeyRole: Equatable, Sendable {
    case bank(Bank)
    case number(Character)
    case spell
    case space
}

public struct KeyDef: Equatable, Sendable {
    public let name: String
    public let code: KeyCode
    public let role: KeyRole
}

/// The active Layout: key definitions, Cluster_Tables and Fingerspelling_Table.
public struct Layout: Sendable {
    public let keys: [KeyDef]
    public let indexByName: [String: Int]
    public let indexByCode: [KeyCode: Int]
    public let clusters: [Bank: [KeySet: String]]
    /// Maps key subsets (without the Spell_Key) to single letters.
    public let fingerspelling: [KeySet: String]
    public let spellIndex: Int?
    public let spaceIndex: Int?
    public let bankMasks: [Bank: KeySet]
    public let numberMask: KeySet

    public init(keys: [KeyDef], clusters: [Bank: [KeySet: String]], fingerspelling: [KeySet: String]) {
        self.keys = keys
        var byName: [String: Int] = [:]
        var byCode: [KeyCode: Int] = [:]
        var masks: [Bank: KeySet] = [.onset: KeySet(), .vowel: KeySet(), .coda: KeySet()]
        var numbers = KeySet()
        var spell: Int?
        var space: Int?
        for (i, k) in keys.enumerated() {
            byName[k.name] = i
            byCode[k.code] = i
            switch k.role {
            case .bank(let b): masks[b]!.insert(i)
            case .number: numbers.insert(i)
            case .spell: spell = i
            case .space: space = i
            }
        }
        indexByName = byName
        indexByCode = byCode
        bankMasks = masks
        numberMask = numbers
        spellIndex = spell
        spaceIndex = space
        self.clusters = clusters
        self.fingerspelling = fingerspelling
    }

    public func name(of index: Int) -> String { keys[index].name }

    public func names(_ set: KeySet) -> [String] { set.indices.map { keys[$0].name } }

    /// "A+B+C" in Layout order.
    public func chordString(_ set: KeySet) -> String { names(set).joined(separator: "+") }

    public func keySet(names: [String]) -> KeySet? {
        var s = KeySet()
        for n in names {
            guard let i = indexByName[n] else { return nil }
            s.insert(i)
        }
        return s
    }

    public var allBanksMask: KeySet {
        bankMasks[.onset]!.union(bankMasks[.vowel]!).union(bankMasks[.coda]!)
    }

    /// Largest key subset in each Bank's Cluster_Table (Req 4.7).
    public func largestClusterSize(_ bank: Bank) -> Int {
        clusters[bank]?.keys.map(\.count).max() ?? 0
    }
}

/// Output kinds from the Glossary: Word_Output, Symbol_Output, and Suffix_Entry text.
public enum OutputKind: String, Sendable {
    case word, symbol, suffix
}

public enum CasingMode: String, Sendable, CaseIterable {
    case snake, camel, pascal, screamingSnake
}

public enum Command: Hashable, Sendable {
    case undo
    case modeSwitch
    case capitalizeNext
    case snippetExit
    case casing(CasingMode)
    case endIdentifier
}

public struct TextEntry: Equatable, Sendable {
    /// Text with the Cursor_Marker removed.
    public var text: String
    /// Number of characters (grapheme clusters) after the Cursor_Marker, or nil if not a Snippet.
    public var cursorFromEnd: Int?
    public var attachLeft = false
    public var attachRight = false
    public var wordAttach = false
    public var glue = false
    public var capitalizeNext = false
    public var kind: OutputKind = .word

    public init(text: String, cursorFromEnd: Int? = nil, attachLeft: Bool = false, attachRight: Bool = false,
                wordAttach: Bool = false, glue: Bool = false, capitalizeNext: Bool = false, kind: OutputKind = .word) {
        self.text = text
        self.cursorFromEnd = cursorFromEnd
        self.attachLeft = attachLeft
        self.attachRight = attachRight
        self.wordAttach = wordAttach
        self.glue = glue
        self.capitalizeNext = capitalizeNext
        self.kind = kind
    }

    public var isSnippet: Bool { cursorFromEnd != nil }
}

public enum Entry: Equatable, Sendable {
    case text(TextEntry)
    case command(Command)
}

public struct ChordDictionary: Sendable {
    public var entries: [KeySet: Entry]
    public init(entries: [KeySet: Entry] = [:]) { self.entries = entries }
    public subscript(_ k: KeySet) -> Entry? { entries[k] }
}

public enum SubMode: String, Sendable, CaseIterable {
    case english, cpp
}

/// One instruction from the Chord_Engine. Counts are extended grapheme clusters (Req 16.6).
public enum OutputAction: Equatable, Sendable {
    case insert(String)
    case deleteBackward(Int)
    case deleteForward(Int)
    case moveLeft(Int)
    case moveRight(Int)
}

/// Everything the Chord_Engine needs, as produced by the Dictionary_Loader.
public struct EngineData: Sendable {
    public var layout: Layout
    public var shared: ChordDictionary
    public var english: ChordDictionary
    public var cpp: ChordDictionary
    /// Keyed by "word+suffix" in lowercase.
    public var orthographyExceptions: [String: String]

    public init(layout: Layout, shared: ChordDictionary, english: ChordDictionary, cpp: ChordDictionary,
                orthographyExceptions: [String: String]) {
        self.layout = layout
        self.shared = shared
        self.english = english
        self.cpp = cpp
        self.orthographyExceptions = orthographyExceptions
    }

    public func dictionary(for mode: SubMode) -> ChordDictionary {
        mode == .english ? english : cpp
    }
}
