// Aggregate practice performance, never a log of typed text or individual key events.
// Standard library only; the macOS layer handles persistence and the practice UI.

public struct PracticeChord: Hashable, Codable, Sendable {
    public let mode: String
    public let codes: [KeyCode]
    public let shift: Bool
    /// A fingerprint of the current meaning, so remapping a chord starts fresh performance data.
    public let meaning: UInt64

    public init?(step: TypingStep, data: EngineData, mode: SubMode) {
        guard case let .chord(names, shift) = step.action,
              let keys = data.layout.keySet(names: names), !keys.isEmpty else { return nil }
        self.init(keys: keys, shift: shift, data: data, mode: mode)
    }

    public init(keys: KeySet, shift: Bool, data: EngineData, mode: SubMode) {
        self.mode = mode.rawValue
        codes = keys.indices.map { data.layout.keys[$0].code }.sorted()
        self.shift = shift
        let reading = ChordReading(keys, shift: shift, data: data, mode: mode)
        var description: String
        switch reading.outcome {
        case .text(let text): description = "text:" + text
        case .command(let command): description = "command:" + command
        case .nothing: description = "nothing"
        }
        var entryKeys = keys
        if let space = data.layout.spaceIndex, entryKeys.count > 1 { entryKeys.remove(space) }
        if case .text(let entry)? = data.dictionary(for: mode)[entryKeys] ?? data.shared[entryKeys] {
            description += ":\(entry.kind.rawValue):\(entry.attachLeft):\(entry.attachRight):\(entry.wordAttach)"
                + ":\(entry.glue):\(entry.capitalizeNext):\(entry.cursorFromEnd.map(String.init) ?? "none")"
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in description.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        meaning = hash
    }

    /// Returns nil for an old mapping, a different mode, or a chord the keyboard can no longer type.
    public func keys(in data: EngineData, mode: SubMode, usable: (KeySet) -> Bool) -> KeySet? {
        guard self.mode == mode.rawValue, !codes.isEmpty else { return nil }
        let indices = codes.compactMap { data.layout.indexByCode[$0] }
        guard indices.count == codes.count else { return nil }
        let keys = KeySet(indices)
        guard usable(keys), self == PracticeChord(keys: keys, shift: shift, data: data, mode: mode) else { return nil }
        return keys
    }
}

public struct ChordPerformance: Codable, Equatable, Sendable {
    public let chord: PracticeChord
    public private(set) var attempts = 0
    public private(set) var mistakes = 0
    public private(set) var hints = 0
    public private(set) var timedAttempts = 0
    public private(set) var totalSeconds = 0.0
    /// Recent performance lets successful review reduce a chord's priority.
    public private(set) var recentErrorRate = 0.0
    public private(set) var recentSeconds = 0.0

    public init(chord: PracticeChord) { self.chord = chord }

    public var accuracy: Double { attempts == 0 ? 1 : Double(attempts - mistakes) / Double(attempts) }
    public var averageSeconds: Double? { timedAttempts == 0 ? nil : totalSeconds / Double(timedAttempts) }
    public var reviewPriority: Double {
        recentErrorRate * 6 + min(recentSeconds / 3, 2) + (attempts == 0 ? 0 : Double(hints) / Double(attempts))
    }

    public mutating func record(correct: Bool, seconds: Double, hinted: Bool) {
        attempts += 1
        if !correct { mistakes += 1 }
        if hinted { hints += 1 }
        let error = correct ? 0.0 : 1.0
        recentErrorRate = attempts == 1 ? error : recentErrorRate * 0.75 + error * 0.25
        // Long pauses are not typing speed; unsuccessful attempts are still counted.
        if seconds.isFinite && seconds > 0 && seconds <= 30 {
            timedAttempts += 1
            totalSeconds += seconds
            recentSeconds = timedAttempts == 1 ? seconds : recentSeconds * 0.75 + seconds * 0.25
        }
    }
}

public struct PracticeHistory: Codable, Sendable {
    public private(set) var records: [ChordPerformance]

    public init(records: [ChordPerformance] = []) { self.records = records }

    public func performance(for chord: PracticeChord) -> ChordPerformance? {
        records.first { $0.chord == chord }
    }

    public mutating func record(_ chord: PracticeChord, correct: Bool, seconds: Double, hinted: Bool) {
        if let i = records.firstIndex(where: { $0.chord == chord }) {
            records[i].record(correct: correct, seconds: seconds, hinted: hinted)
        } else {
            var performance = ChordPerformance(chord: chord)
            performance.record(correct: correct, seconds: seconds, hinted: hinted)
            records.append(performance)
        }
    }

    public func weakest(mode: SubMode) -> [ChordPerformance] {
        records.filter { $0.chord.mode == mode.rawValue && $0.attempts > 0 }.sorted {
            if $0.reviewPriority != $1.reviewPriority { return $0.reviewPriority > $1.reviewPriority }
            if $0.attempts != $1.attempts { return $0.attempts > $1.attempts }
            if $0.chord.codes != $1.chord.codes { return $0.chord.codes.lexicographicallyPrecedes($1.chord.codes) }
            return !$0.chord.shift && $1.chord.shift
        }
    }
}

public enum PracticeAssessment {
    /// Accept another chord that produces the same output and context, as well as the suggested chord.
    public static func matches(_ step: TypingStep, codes: Set<KeyCode>, shift: Bool, capsLock: Bool = false,
                               context: EngineContext, data: EngineData, mode: SubMode) -> Bool {
        guard case let .chord(names, expectedShift) = step.action,
              let expectedKeys = data.layout.keySet(names: names) else { return false }
        let indices = codes.compactMap { data.layout.indexByCode[$0] }
        guard indices.count == codes.count else { return false }
        let expected = ChordEngine(data: data, subMode: mode)
        expected.restore(context)
        let actual = ChordEngine(data: data, subMode: mode)
        actual.restore(context)
        guard let wanted = try? expected.translate(expectedKeys, join: expectedShift), wanted.signal == nil,
              let result = try? actual.translate(KeySet(indices), join: shift, capsLock: capsLock),
              result == wanted else { return false }
        return actual.currentContext == expected.currentContext
    }
}

public struct ReviewDrill: Sendable {
    public let text: String
    public let guide: TypingGuide
    public let targets: [PracticeChord]
}

public enum PracticeReview {
    /// Builds short, repeatable drills from built-in examples and the active dictionary. Imported passages
    /// are never saved or used as a persistent review catalog. Every selected chord is checked in its plan.
    public static func make(history: PracticeHistory, data: EngineData, mode: SubMode, rolloverLimit: Int = 6,
                            usable: @escaping (KeySet) -> Bool = { _ in true }, limit: Int = 5) -> ReviewDrill? {
        guard limit > 0 else { return nil }
        let weak = history.weakest(mode: mode).filter {
            $0.chord.codes.count <= rolloverLimit && $0.chord.keys(in: data, mode: mode, usable: usable) != nil
        }
        guard !weak.isEmpty else { return nil }
        let wanted = Set(weak.map(\.chord))
        let sources = Course.steps.filter { $0.mode == mode }.map(\.text)
            + Lessons.all.filter { $0.mode == mode }.map(\.text)
        var candidates = Set<String>()
        for source in sources {
            for line in source.split(separator: "\n") {
                candidates.insert(String(line))
                let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                for i in words.indices {
                    candidates.insert(words[i])
                    candidates.insert(words[max(0, i - 1)...min(words.count - 1, i + 1)].joined(separator: " "))
                }
            }
        }
        for dictionary in [data.shared, data.dictionary(for: mode)] {
            for entry in dictionary.entries.values {
                if case .text(let t) = entry, !t.isSnippet, t.kind != .suffix, !t.text.isEmpty, t.text.count <= 80 {
                    candidates.insert(t.text)
                }
            }
        }
        for record in weak {
            guard let keys = record.chord.keys(in: data, mode: mode, usable: usable) else { continue }
            if case .text(let text) = ChordReading(keys, shift: record.chord.shift, data: data, mode: mode).outcome,
               !text.hasPrefix("-"), !text.isEmpty {
                candidates.insert(text)
            }
        }
        let planner = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
        var examples: [PracticeChord: String] = [:]
        for candidate in candidates.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            let plan = planner.plan(candidate)
            guard plan.normalCount == 0, !plan.steps.contains(where: { $0.kind == .cancelCapital }) else { continue }
            for step in plan.steps {
                if let chord = PracticeChord(step: step, data: data, mode: mode), wanted.contains(chord), examples[chord] == nil {
                    examples[chord] = candidate
                }
            }
            if examples.count == wanted.count { break }
        }
        let targets = Array(weak.map(\.chord).filter { examples[$0] != nil }.prefix(limit))
        guard !targets.isEmpty else { return nil }
        var lines: [String] = []
        for target in targets { if let text = examples[target], !lines.contains(text) { lines.append(text) } }
        let text = (0..<3).flatMap { _ in lines }.joined(separator: "\n")
        let guide = planner.plan(text)
        let included = Set(guide.steps.compactMap { PracticeChord(step: $0, data: data, mode: mode) })
        guard guide.normalCount == 0, targets.allSatisfy(included.contains) else { return nil }
        return ReviewDrill(text: text, guide: guide, targets: targets)
    }
}
