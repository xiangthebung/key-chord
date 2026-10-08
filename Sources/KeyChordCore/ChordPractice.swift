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

    /// Recent assistance and recall recover as the learner improves; lifetime hints remain descriptive only.
    public private(set) var recentHintRate = 0.0
    public private(set) var recentRecallRate = 0.0
    public private(set) var unassistedStreak = 0
    /// Caller-supplied epoch days are the only stored dates. No passages or exact event times are retained.
    public private(set) var lastPracticedDay: Int?
    public private(set) var lastRecallDay: Int?
    public private(set) var nextReviewDay: Int?
    public private(set) var firstSpacedRecallDay: Int?
    public private(set) var spacedRecallDays = 0

    public init(chord: PracticeChord) { self.chord = chord }

    /// Three consecutive unaided chord successes establish current recall, not transfer to new contexts.
    public var isRecalled: Bool { unassistedStreak >= 3 }
    /// Retention needs at least three successful spaced checks, spanning at least four days.
    /// Same-day repetitions and undated legacy history cannot establish it.
    public var isRetained: Bool {
        guard isRecalled, spacedRecallDays >= 3, let first = firstSpacedRecallDay,
              let last = lastRecallDay else { return false }
        let span = last.subtractingReportingOverflow(first)
        return !span.overflow && span.partialValue >= 4
    }

    private enum CodingKeys: String, CodingKey {
        case chord, attempts, mistakes, hints, timedAttempts, totalSeconds, recentErrorRate, recentSeconds
        case recentHintRate, recentRecallRate, unassistedStreak, lastPracticedDay, lastRecallDay
        case nextReviewDay, firstSpacedRecallDay, spacedRecallDays
    }

    /// Older aggregate records contained no dated or unaided evidence. Keep their performance without
    /// inferring recall or retention from lifetime accuracy or hint counts.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chord = try values.decode(PracticeChord.self, forKey: .chord)
        attempts = try values.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        mistakes = try values.decodeIfPresent(Int.self, forKey: .mistakes) ?? 0
        hints = try values.decodeIfPresent(Int.self, forKey: .hints) ?? 0
        timedAttempts = try values.decodeIfPresent(Int.self, forKey: .timedAttempts) ?? 0
        totalSeconds = try values.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        recentErrorRate = try values.decodeIfPresent(Double.self, forKey: .recentErrorRate) ?? 0
        recentSeconds = try values.decodeIfPresent(Double.self, forKey: .recentSeconds) ?? 0
        recentHintRate = try values.decodeIfPresent(Double.self, forKey: .recentHintRate)
            ?? (attempts > 0 ? Double(hints) / Double(attempts) : 0)
        recentRecallRate = try values.decodeIfPresent(Double.self, forKey: .recentRecallRate) ?? 0
        unassistedStreak = try values.decodeIfPresent(Int.self, forKey: .unassistedStreak) ?? 0
        lastPracticedDay = try values.decodeIfPresent(Int.self, forKey: .lastPracticedDay)
        lastRecallDay = try values.decodeIfPresent(Int.self, forKey: .lastRecallDay)
        nextReviewDay = try values.decodeIfPresent(Int.self, forKey: .nextReviewDay)
        firstSpacedRecallDay = try values.decodeIfPresent(Int.self, forKey: .firstSpacedRecallDay)
        spacedRecallDays = try values.decodeIfPresent(Int.self, forKey: .spacedRecallDays) ?? 0
    }

    public var accuracy: Double { attempts == 0 ? 1 : Double(attempts - mistakes) / Double(attempts) }
    public var averageSeconds: Double? { timedAttempts == 0 ? nil : totalSeconds / Double(timedAttempts) }
    public var reviewPriority: Double {
        recentErrorRate * 6 + min(recentSeconds / 3, 2) + recentHintRate
    }

    public mutating func record(correct: Bool, seconds: Double, hinted: Bool, day: Int? = nil) {
        attempts += 1
        if !correct { mistakes += 1 }
        if hinted { hints += 1 }
        let unaided = correct && !hinted
        let assistance = hinted ? 1.0 : 0.0
        let recall = unaided ? 1.0 : 0.0
        recentHintRate = attempts == 1 ? assistance : recentHintRate * 0.75 + assistance * 0.25
        recentRecallRate = attempts == 1 ? recall : recentRecallRate * 0.75 + recall * 0.25
        unassistedStreak = unaided ? min(unassistedStreak + 1, 3) : 0
        updateSchedule(unaided: unaided, day: day)
        let error = correct ? 0.0 : 1.0
        recentErrorRate = attempts == 1 ? error : recentErrorRate * 0.75 + error * 0.25
        // Long pauses are not typing speed; unsuccessful attempts are still counted.
        if seconds.isFinite && seconds > 0 && seconds <= 30 {
            timedAttempts += 1
            totalSeconds += seconds
            recentSeconds = timedAttempts == 1 ? seconds : recentSeconds * 0.75 + seconds * 0.25
        }
    }

    private mutating func updateSchedule(unaided: Bool, day: Int?) {
        // A clock moved backwards must not move the schedule backwards or create a new recall day.
        if let day, let lastPracticedDay, day < lastPracticedDay { return }
        if let day { lastPracticedDay = day }
        if !unaided {
            spacedRecallDays = 0
            firstSpacedRecallDay = nil
            nextReviewDay = day ?? lastPracticedDay
            return
        }
        guard let day else { return }
        let previousRecallDay = lastRecallDay
        lastRecallDay = day
        guard previousRecallDay != day || spacedRecallDays == 0,
              nextReviewDay == nil || day >= nextReviewDay! else { return }
        if spacedRecallDays == 0 { firstSpacedRecallDay = day }
        spacedRecallDays = min(spacedRecallDays + 1, 5)
        let intervals = [1, 3, 7, 14, 30]
        let next = day.addingReportingOverflow(intervals[spacedRecallDays - 1])
        nextReviewDay = next.overflow ? Int.max : next.partialValue
    }
}

public struct PracticeHistory: Codable, Sendable {
    public private(set) var records: [ChordPerformance]

    public init(records: [ChordPerformance] = []) { self.records = records }

    public func performance(for chord: PracticeChord) -> ChordPerformance? {
        records.first { $0.chord == chord }
    }

    public mutating func record(_ chord: PracticeChord, correct: Bool, seconds: Double, hinted: Bool, day: Int? = nil) {
        if let i = records.firstIndex(where: { $0.chord == chord }) {
            records[i].record(correct: correct, seconds: seconds, hinted: hinted, day: day)
        } else {
            var performance = ChordPerformance(chord: chord)
            performance.record(correct: correct, seconds: seconds, hinted: hinted, day: day)
            records.append(performance)
        }
    }

    /// Undated legacy records enter review now; the first dated unaided recall starts their schedule.
    public func dueCount(mode: SubMode, day: Int) -> Int {
        records.filter { $0.chord.mode == mode.rawValue && $0.attempts > 0
            && ($0.nextReviewDay == nil || $0.nextReviewDay! <= day) }.count
    }

    /// For UI badges, exclude old mappings and combinations the current keyboard cannot register.
    /// The aggregate-only overload above remains useful without access to the active engine data.
    public func dueCount(mode: SubMode, day: Int, data: EngineData, rolloverLimit: Int = 6,
                         usable: (KeySet) -> Bool = { _ in true }) -> Int {
        records.filter { $0.chord.mode == mode.rawValue && $0.attempts > 0
            && ($0.nextReviewDay == nil || $0.nextReviewDay! <= day)
            && $0.chord.codes.count <= rolloverLimit
            && $0.chord.keys(in: data, mode: mode, usable: usable) != nil }.count
    }

    /// Due work first, oldest due day first; keep weak upcoming work as an optional fallback.
    public func recordsForReview(mode: SubMode, day: Int) -> [ChordPerformance] {
        let weak = weakest(mode: mode)
        let due = weak.enumerated().filter { $0.element.nextReviewDay == nil || $0.element.nextReviewDay! <= day }.sorted {
            let left = $0.element.nextReviewDay ?? Int.min, right = $1.element.nextReviewDay ?? Int.min
            if left != right { return left < right }
            return $0.offset < $1.offset
        }.map(\.element)
        return due + weak.filter { $0.nextReviewDay != nil && $0.nextReviewDay! > day }
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
    /// Uses whole words and phrases from curated teaching examples, never arbitrary chord output.
    /// Different rounds can revisit the same vocabulary in another order or surrounding context.
    /// Imported passages and raw chord fragments never become a persistent review catalog.
    public static func make(history: PracticeHistory, data: EngineData, mode: SubMode, rolloverLimit: Int = 6,
                            usable: @escaping (KeySet) -> Bool = { _ in true }, limit: Int = 5,
                            day: Int? = nil, learnedSkills: Set<Course.Skill>? = nil) -> ReviewDrill? {
        guard limit > 0 else { return nil }
        let ordered = day.map { history.recordsForReview(mode: mode, day: $0) } ?? history.weakest(mode: mode)
        let weak = ordered.filter {
            $0.chord.codes.count <= rolloverLimit && $0.chord.keys(in: data, mode: mode, usable: usable) != nil
        }
        guard !weak.isEmpty else { return nil }
        let wanted = Set(weak.map(\.chord))
        let sources = Course.steps.filter { $0.mode == mode }.map(\.text)
            + Lessons.all.filter { $0.mode == mode }.map(\.text)
            // Complete transformations also cover silent-e spelling bases such as the intermediate
            // "looke" before -ed. A spelling base is never itself an ordinary vocabulary target.
            + (mode == .english ? ["We looked for the book. They needed help. We wanted to try making tea."] : [])
        var candidates = Set<String>()
        for source in sources {
            for line in source.split(separator: "\n") {
                candidates.insert(String(line))
                let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                for i in words.indices {
                    // Punctuation needs a surrounding word in English; C++ tokens are intentional syntax.
                    if mode != .english || words[i].contains(where: { $0.isLetter || $0.isNumber }) {
                        candidates.insert(words[i])
                    }
                    candidates.insert(words[max(0, i - 1)...min(words.count - 1, i + 1)].joined(separator: " "))
                }
            }
        }
        let planner = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
        func allowed(_ guide: TypingGuide) -> Bool {
            guide.steps.allSatisfy(Course.isAllowed) && guide.steps.allSatisfy { step in
                learnedSkills.map { Course.skills(of: step, data: data, mode: mode).isSubset(of: $0) } ?? true
            }
        }
        var examples: [PracticeChord: [String]] = [:]
        for candidate in candidates.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            let plan = planner.plan(candidate)
            guard allowed(plan) else { continue }
            let present = Set(plan.steps.compactMap { PracticeChord(step: $0, data: data, mode: mode) })
            for chord in present where wanted.contains(chord) && (examples[chord]?.count ?? 0) < 3 {
                examples[chord, default: []].append(candidate)
            }
            if wanted.allSatisfy({ (examples[$0]?.count ?? 0) >= 3 }) { break }
        }
        let targets = Array(weak.map(\.chord).filter { examples[$0] != nil }.prefix(limit))
        guard !targets.isEmpty else { return nil }
        let separator = learnedSkills.map { $0.contains(.newLine) ? "\n" : " " } ?? "\n"
        var lines: [String] = []
        var occurrences: [PracticeChord: Int] = [:]
        for round in 0..<3 {
            // Rotate rather than repeat a fixed ordered passage. Only promise practice of the chord,
            // since curated contexts may share a word and cannot establish transfer on their own.
            for index in targets.indices {
                let target = targets[(index + round) % targets.count]
                guard let options = examples[target] else { return nil }
                var appended = false
                for optionIndex in options.indices {
                    let option = options[(optionIndex + round) % options.count]
                    var variants = [option]
                    // Return preserves pending capitalization. A sentence-ending example can make
                    // the next lowercase example require a throwaway letter and Delete. Try its
                    // sentence-case form in the actual context, retaining the same target chord.
                    if mode == .english, let first = option.firstIndex(where: \.isLetter), option[first].isLowercase {
                        var capitalized = option
                        capitalized.replaceSubrange(first..<option.index(after: first), with: String(option[first]).uppercased())
                        variants.append(capitalized)
                    }
                    for variant in variants {
                        let plan = planner.plan((lines + [variant]).joined(separator: separator))
                        guard allowed(plan) else { continue }
                        let included = plan.steps.compactMap { PracticeChord(step: $0, data: data, mode: mode) }
                        var required = occurrences
                        required[target, default: 0] += 1
                        guard required.allSatisfy({ chord, count in included.filter { $0 == chord }.count >= count }) else { continue }
                        lines.append(variant)
                        occurrences = required
                        appended = true
                        break
                    }
                    if appended { break }
                }
                guard appended else { return nil }
            }
        }
        let text = lines.joined(separator: separator)
        let guide = planner.plan(text)
        let included = guide.steps.compactMap { PracticeChord(step: $0, data: data, mode: mode) }
        guard allowed(guide), targets.allSatisfy({ target in included.filter { $0 == target }.count >= 3 }) else { return nil }
        return ReviewDrill(text: text, guide: guide, targets: targets)
    }
}
