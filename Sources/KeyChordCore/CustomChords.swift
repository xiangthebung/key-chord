// User-created text chords are applied over the installed mapping. Removing one restores that mapping.

public enum CustomChordScope: String, Codable, CaseIterable, Sendable {
    case english, cpp, both

    public var title: String {
        switch self {
        case .english: return "English"
        case .cpp: return "C++"
        case .both: return "Both"
        }
    }

    public var modes: [SubMode] {
        switch self {
        case .english: return [.english]
        case .cpp: return [.cpp]
        case .both: return [.english, .cpp]
        }
    }
}

public enum CustomChordSpacing: String, Codable, CaseIterable, Sendable {
    case words, exact
}

public struct CustomChord: Codable, Equatable, Sendable {
    public var id: String
    /// Physical codes survive a change between ANSI and ISO key labels.
    public var keyCodes: [KeyCode]
    public var text: String
    public var scope: CustomChordScope
    public var spacing: CustomChordSpacing
    public var isEnabled: Bool

    public init(id: String, keyCodes: [KeyCode], text: String, scope: CustomChordScope = .english,
                spacing: CustomChordSpacing = .words, isEnabled: Bool = true) {
        self.id = id
        self.keyCodes = Array(Set(keyCodes)).sorted()
        self.text = text
        self.scope = scope
        self.spacing = spacing
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, keyCodes, text, scope, spacing, isEnabled }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        // Keep malformed saved keys intact so validation can report them in the editor.
        keyCodes = try values.decode([KeyCode].self, forKey: .keyCodes)
        text = try values.decode(String.self, forKey: .text)
        scope = try values.decode(CustomChordScope.self, forKey: .scope)
        spacing = try values.decode(CustomChordSpacing.self, forKey: .spacing)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func keys(in layout: Layout) -> KeySet? {
        let indices = keyCodes.compactMap { layout.indexByCode[$0] }
        guard indices.count == keyCodes.count else { return nil }
        return KeySet(indices)
    }

    public var entry: TextEntry {
        spacing == .words ? TextEntry(text: text, kind: .word)
            : TextEntry(text: text, attachLeft: true, attachRight: true, kind: .symbol)
    }
}

public enum CustomChordIssue: Equatable, Sendable {
    case identity, missingKeys, unknownKeys, space, tooManyKeys(Int), missingText, reservedCommand, duplicate, blocked

    public var message: String {
        switch self {
        case .identity: return "This saved chord has an invalid identity."
        case .missingKeys: return "Record the keys you want to press together."
        case .unknownKeys: return "Use keys from the chord keyboard, without Shift, Option, Command, or Control."
        case .space: return "Space joins words. Choose a chord without Space."
        case .tooManyKeys(let limit): return "Use at most \(limit) keys in one chord."
        case .missingText: return "Enter the text this chord should type."
        case .reservedCommand: return "These keys perform a built-in action. Choose different keys to keep that action available."
        case .duplicate: return "You already have a chord with these keys in this language. Edit it or choose different keys."
        case .blocked: return "This keyboard cannot register these keys together. Choose a different combination."
        }
    }
}

public enum CustomChords {
    public static func issue(for chord: CustomChord, among others: [CustomChord], base: EngineData,
                             rolloverLimit: Int = 6, usable: (KeySet) -> Bool = { _ in true }) -> CustomChordIssue? {
        guard !chord.id.isEmpty, !others.contains(where: { $0.id == chord.id }) else { return .identity }
        guard !chord.keyCodes.isEmpty else { return .missingKeys }
        guard Set(chord.keyCodes).count == chord.keyCodes.count,
              let keys = chord.keys(in: base.layout) else { return .unknownKeys }
        if let space = base.layout.spaceIndex, keys.contains(space) { return .space }
        guard keys.count <= rolloverLimit else { return .tooManyKeys(rolloverLimit) }
        guard chord.text.contains(where: { !$0.isWhitespace }) else { return .missingText }
        for mode in chord.scope.modes {
            if case .command? = base.dictionary(for: mode)[keys] ?? base.shared[keys] { return .reservedCommand }
        }
        if chord.isEnabled && others.contains(where: { other in
            other.isEnabled && other.keys(in: base.layout) == keys && other.scope.modes.contains(where: chord.scope.modes.contains)
        }) { return .duplicate }
        guard usable(keys) else { return .blocked }
        return nil
    }

    /// Invalid saved entries stay in the editor for repair but never shadow a working chord.
    public static func applying(_ chords: [CustomChord], to base: EngineData, rolloverLimit: Int = 6,
                                usable: (KeySet) -> Bool = { _ in true }) -> EngineData {
        var result = base
        for (index, chord) in chords.enumerated() {
            guard chord.isEnabled else { continue }
            let others = chords.enumerated().filter { $0.offset != index }.map(\.element)
            guard issue(for: chord, among: others, base: base, rolloverLimit: rolloverLimit, usable: usable) == nil,
                  let keys = chord.keys(in: base.layout) else { continue }
            for mode in chord.scope.modes {
                if mode == .english { result.english.entries[keys] = .text(chord.entry) }
                else { result.cpp.entries[keys] = .text(chord.entry) }
            }
        }
        return result
    }

    /// Search short chords only, so even a layout with 64 keys has a bounded, interactive search.
    /// Dictionary entries, generated syllables, letters and numbers all count as occupied.
    public static func suggestions(scope: CustomChordScope, among chords: [CustomChord], base: EngineData,
                                   rolloverLimit: Int = 6, usable: (KeySet) -> Bool = { _ in true },
                                   geometry: KeyboardGeometry = .ansi, excluding: Set<KeySet> = [],
                                   limit: Int = 3) -> [KeySet] {
        guard limit > 0, rolloverLimit > 0 else { return [] }
        let indices = base.layout.keys.indices.filter { $0 != base.layout.spaceIndex }
        guard !indices.isEmpty else { return [] }
        let occupied = Set(chords.filter {
            $0.isEnabled && $0.scope.modes.contains(where: scope.modes.contains)
        }.compactMap { $0.keys(in: base.layout) })
        var result: [KeySet] = []

        // A convenience heuristic: prefer the home row and less travel within each hand.
        // It does not promise physical comfort or hardware reliability.
        func reach(_ keys: KeySet) -> Double {
            let positions = keys.indices.compactMap { geometry.key(for: base.layout.keys[$0].code) }
            var score = Double(keys.count - positions.count) * 100
            for key in positions { score += abs(key.y - 2.7) }
            for hand in [positions.filter { $0.x + $0.width / 2 < 7 }, positions.filter { $0.x + $0.width / 2 >= 7 }] {
                if let left = hand.map(\.x).min(), let right = hand.map(\.x).max() { score += right - left }
                if let top = hand.map(\.y).min(), let bottom = hand.map(\.y).max() { score += (bottom - top) * 3 }
            }
            return score
        }

        for size in 1...min(3, rolloverLimit, indices.count) {
            var candidates: [(keys: KeySet, reach: Double)] = []
            func visit(_ start: Int, _ keys: KeySet) {
                if keys.count == size {
                    guard !excluding.contains(keys), !occupied.contains(keys), usable(keys),
                          scope.modes.allSatisfy({ ChordReading(keys, data: base, mode: $0).outcome == .nothing }) else { return }
                    candidates.append((keys, reach(keys)))
                    return
                }
                let last = indices.count - (size - keys.count)
                guard start <= last else { return }
                for offset in start...last {
                    var next = keys
                    next.insert(indices[offset])
                    visit(offset + 1, next)
                }
            }
            visit(0, KeySet())
            candidates.sort { ($0.reach, $0.keys.bits) < ($1.reach, $1.keys.bits) }
            result += candidates.prefix(limit - result.count).map(\.keys)
            if result.count == limit { break }
        }
        return result
    }
}
