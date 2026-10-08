// A local random-word typing test. Clocks and text editing are supplied by the UI;
// passages, edits, and the speed series live only for the current test.

public enum WordPracticeVocabulary: String, CaseIterable, Codable, Sendable {
    case english, english5k, english25k

    public var title: String {
        switch self {
        case .english: return "English"
        case .english5k: return "English 5k"
        case .english25k: return "English 25k"
        }
    }

    public var words: [String] {
        switch self {
        case .english: return EnglishWordLists.common
        case .english5k: return EnglishWordLists.fiveThousand
        case .english25k: return EnglishWordLists.twentyFiveThousand
        }
    }
}

public enum WordPracticeGoal: Equatable, Sendable {
    case time(Int), words(Int)

    public var title: String {
        switch self {
        case .time(let seconds): return "\(seconds) seconds"
        case .words(let count): return "\(count) words"
        }
    }
}

public struct WordPracticeSample: Equatable, Sendable {
    public let seconds: Double
    public let wpm: Double
    public let rawWPM: Double
    public let errors: Int
}

public struct WordPracticeMetrics: Equatable, Sendable {
    public let elapsed: Double
    public let wpm: Double
    public let rawWPM: Double
    public let accuracy: Double
    /// 100 × (1 − coefficient of variation) of characters entered per second, clamped to 0…100.
    public let consistency: Double
    public let correct: Int
    public let incorrect: Int
    public let extra: Int
    public let missed: Int
    public let completedWords: Int
    public let correctWords: Int
    public let mistakes: Int
}

/// Sampling with replacement, without consecutive duplicates. A seed supports repeatable tests.
public struct WordPracticeWordStream: Sendable {
    private let words: [String]
    private var state: UInt64
    private var previous: Int?

    public init(words: [String], seed: UInt64) {
        precondition(!words.isEmpty)
        self.words = words
        state = seed
    }

    public mutating func next() -> String {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        var index = Int(value % UInt64(words.count - (previous == nil || words.count == 1 ? 0 : 1)))
        if let previous, words.count > 1, index >= previous { index += 1 }
        previous = index
        return words[index]
    }
}

public final class WordPracticeSession {
    public let vocabulary: WordPracticeVocabulary
    public let goal: WordPracticeGoal
    public private(set) var targetWords: [String]
    public private(set) var typedText = ""
    public private(set) var startedAt: Double?
    public private(set) var finishedAt: Double?
    public private(set) var samples: [WordPracticeSample] = []
    public private(set) var insertedCharacters = 0
    public private(set) var correctInsertions = 0
    private var stream: WordPracticeWordStream
    private let initialSeed: UInt64
    private let sourceWords: [String]?
    private var lastTime = 0.0
    private var lastSampleErrors = 0
    private var nextSampleSecond = 1.0
    private var characterBins: [Int: Int] = [:]

    public init(vocabulary: WordPracticeVocabulary = .english, goal: WordPracticeGoal = .time(30),
                seed: UInt64, words: [String]? = nil) {
        switch goal {
        case .time(let seconds), .words(let seconds): precondition(seconds > 0)
        }
        self.vocabulary = vocabulary
        self.goal = goal
        initialSeed = seed
        sourceWords = words
        stream = WordPracticeWordStream(words: words ?? vocabulary.words, seed: seed)
        targetWords = []
        let count: Int
        switch goal {
        case .time: count = 50
        case .words(let limit): count = limit
        }
        for _ in 0..<count { targetWords.append(stream.next()) }
    }

    public var isFinished: Bool { finishedAt != nil }
    public var currentWordIndex: Int { typedText.filter { $0 == " " }.count }
    public var typedWords: [String] { typedText.split(separator: " ", omittingEmptySubsequences: false).map(String.init) }

    public func restarted() -> WordPracticeSession {
        WordPracticeSession(vocabulary: vocabulary, goal: goal, seed: initialSeed, words: sourceWords)
    }

    /// Character offsets, rather than UTF-16 offsets. The native adapter converts NSRange at its boundary.
    /// Only inserted characters affect accuracy; deleting an error cannot erase the original attempt.
    /// verifiedChordPreview is reserved for an adapter that verified the physical chord against a
    /// planner step and its exact intermediate output (for example make before an -ing rewrite).
    @discardableResult
    public func edit(range: Range<Int>, replacement: String, at now: Double, verifiedChordPreview: Bool = false) -> Bool {
        advance(to: now)
        guard !isFinished else { return false }
        var chars = Array(typedText)
        guard range.lowerBound >= 0, range.upperBound <= chars.count else { return false }
        guard replacement.allSatisfy({ !$0.isWhitespace || $0 == " " }) else { return false }
        if startedAt == nil, !replacement.isEmpty { startedAt = now; lastTime = now }
        chars.replaceSubrange(range, with: Array(replacement))
        typedText = String(chars)
        extendIfNeeded()
        let positions = characterCorrectness()
        for offset in range.lowerBound..<(range.lowerBound + replacement.count) {
            insertedCharacters += 1
            if verifiedChordPreview || (offset < positions.count && positions[offset]) { correctInsertions += 1 }
        }
        if let startedAt, !replacement.isEmpty {
            characterBins[Int(max(0, lastTime - startedAt) + 0.000_000_001), default: 0] += replacement.count
        }
        if case .words(let count) = goal {
            let tokens = typedWords
            if currentWordIndex >= count || (currentWordIndex == count - 1 && tokens.last == targetWords.last) {
                finish(at: lastTime)
            }
        }
        return true
    }

    /// Time tests keep their original deadline, including time spent out of focus or idle.
    public func advance(to now: Double) {
        guard let startedAt, !isFinished else { return }
        lastTime = max(lastTime, now)
        if case .time(let limit) = goal { lastTime = min(lastTime, startedAt + Double(limit)) }
        if lastTime - startedAt >= nextSampleSecond {
            addSample(at: lastTime)
            nextSampleSecond = Double(Int(lastTime - startedAt) + 1)
        }
        if case .time(let limit) = goal, lastTime >= startedAt + Double(limit) { finish(at: lastTime) }
    }

    public func metrics(at now: Double) -> WordPracticeMetrics {
        let elapsed: Double
        if let startedAt {
            var end = finishedAt ?? max(lastTime, now)
            if case .time(let limit) = goal { end = min(end, startedAt + Double(limit)) }
            elapsed = max(0, end - startedAt)
        }
        else { elapsed = 0 }
        let tokens = typedWords
        var correct = 0, incorrect = 0, extra = 0, missed = 0, correctWords = 0, credited = 0
        let completed = min(currentWordIndex, targetWords.count)
        for index in 0..<min(tokens.count, targetWords.count) {
            let expected = Array(targetWords[index]), actual = Array(tokens[index])
            let committed = index < currentWordIndex || (isFinished && actual == expected)
            for (position, character) in actual.enumerated() {
                if position >= expected.count { extra += 1 }
                else if character == expected[position] { correct += 1 }
                else { incorrect += 1 }
            }
            if committed { missed += max(0, expected.count - actual.count) }
            if actual == expected, committed {
                correctWords += 1
                credited += expected.count
                if index < currentWordIndex { credited += 1; correct += 1 }
            } else if index == currentWordIndex, expected.starts(with: actual) {
                credited += actual.count
            }
        }
        let divisor = max(elapsed, 0.001)
        // Ignore an unfinished one-second bucket in live stats. Include a substantial final
        // partial bucket, avoiding a near-zero divisor at floating-point second boundaries.
        let fullSeconds = Int((elapsed + 0.000_000_001).rounded(.down))
        let finalPartial = isFinished && elapsed - Double(fullSeconds) >= 0.25
        let bins = (0..<max(1, fullSeconds + (finalPartial ? 1 : 0))).map { index -> Double in
            let duration = min(1, max(0.001, elapsed - Double(index)))
            return Double(characterBins[index, default: 0]) / duration
        }
        let mean = bins.reduce(0, +) / Double(bins.count)
        let variance = bins.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(bins.count)
        let consistency = bins.count > 1 && mean > 0 ? max(0, 100 * (1 - variance.squareRoot() / mean)) : 0
        return WordPracticeMetrics(elapsed: elapsed, wpm: elapsed > 0 ? Double(credited) * 12 / divisor : 0,
            rawWPM: elapsed > 0 ? Double(typedText.count) * 12 / divisor : 0,
            accuracy: insertedCharacters == 0 ? 100 : Double(correctInsertions) * 100 / Double(insertedCharacters),
            consistency: consistency, correct: correct, incorrect: incorrect, extra: extra, missed: missed,
            completedWords: isFinished ? max(completed, correctWords) : completed, correctWords: correctWords,
            mistakes: insertedCharacters - correctInsertions)
    }

    private func extendIfNeeded() {
        guard case .time = goal else { return }
        while currentWordIndex >= targetWords.count - 10 {
            for _ in 0..<50 { targetWords.append(stream.next()) }
        }
    }

    private func characterCorrectness() -> [Bool] {
        var word = 0, position = 0
        var expected = Array(targetWords[0])
        return typedText.map { char in
            if char == " " {
                word += 1
                position = 0
                expected = word < targetWords.count ? Array(targetWords[word]) : []
                return word <= targetWords.count
            }
            defer { position += 1 }
            return position < expected.count && char == expected[position]
        }
    }

    private func addSample(at now: Double) {
        let metrics = metrics(at: now)
        var errors = max(0, metrics.mistakes - lastSampleErrors)
        if samples.last?.seconds == metrics.elapsed { errors += samples.removeLast().errors }
        samples.append(WordPracticeSample(seconds: metrics.elapsed, wpm: metrics.wpm, rawWPM: metrics.rawWPM, errors: errors))
        lastSampleErrors = metrics.mistakes
    }

    private func finish(at now: Double) {
        finishedAt = now
        addSample(at: now)
    }
}
