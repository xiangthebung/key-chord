// Reusable, local exercise generation. Every result is planned against the active mapping and keyboard.
// Course exercises also preserve the curriculum's skill boundaries and practice every newly taught skill.

public enum PracticeSource: Hashable, Sendable {
    case course(Int)
    case topic(Int)
}

public struct GeneratedPractice: Sendable {
    public let text: String
    public let guide: TypingGuide
}

public final class PracticeGenerator {
    public let source: PracticeSource
    public let mode: SubMode
    private let planner: TypingPlanner
    private let data: EngineData
    private let taught: Set<Course.Skill>?
    private let requirements: [Set<Course.Skill>]
    private let wordDrill: Bool
    private let original: String
    private struct Example {
        let text: String
        let skills: Set<Course.Skill>
    }
    private var examples: [Example] = []

    public init?(source: PracticeSource, data: EngineData, rolloverLimit: Int = 6,
                 usable: @escaping (KeySet) -> Bool = { _ in true }) {
        self.source = source
        self.data = data
        let sources: [String]
        switch source {
        case .course(let index):
            guard Course.steps.indices.contains(index) else { return nil }
            let step = Course.steps[index]
            mode = step.mode
            original = step.text
            let learned = Course.taught(through: index, data: data)
            taught = learned
            requirements = step.new.filter { !Course.explainedOnly.contains($0) }.map { skill in
                if case .pairs(let bank) = skill {
                    return Set(Course.pairClusters(bank, data: data).map { Course.Skill.sound(bank, $0.text) })
                        .intersection(learned)
                }
                // A keyboard that can register Space with this chord does not need the Shift alternative.
                if skill == .shiftJoin { return [.shiftJoin, .join] }
                return [skill]
            }
            wordDrill = mode == .english ? !learned.contains(.symbol("."))
                                        : ["cpp-mode", "cpp-more-keywords"].contains(step.id)
            sources = Course.steps[...index].filter { $0.mode == step.mode }.map(\.text)
        case .topic(let index):
            guard Lessons.all.indices.contains(index) else { return nil }
            let lesson = Lessons.all[index]
            mode = lesson.mode
            original = lesson.text
            taught = nil
            requirements = []
            wordDrill = index < 2
            sources = [lesson.text]
        }
        planner = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
        var candidates = Set<String>()
        if wordDrill {
            let wordSources = mode == .english
                ? sources + Course.steps.filter { $0.mode == .english }.map(\.text) + [Self.words]
                : sources
            for source in wordSources {
                for token in source.split(whereSeparator: \.isWhitespace) {
                    if let word = Self.drillWord(in: token) { candidates.insert(word) }
                }
            }
        } else if mode == .english {
            // Once sentence writing begins, earlier unpunctuated word lists are not ordinary prose.
            let sentenceSources = sources.filter { $0.contains(".") || $0.contains("?") || $0.contains("!") }
            for source in sentenceSources + Self.sentences {
                for sentence in Self.sentences(in: source) {
                    if let taught, !taught.contains(.symbol(".")) {
                        var phrase = sentence
                        while let last = phrase.last, [".", "?", "!"].contains(last) { phrase.removeLast() }
                        if !phrase.hasPrefix("I "), let first = phrase.first {
                            phrase = first.lowercased() + phrase.dropFirst()
                        }
                        candidates.insert(phrase)
                    } else {
                        candidates.insert(sentence)
                    }
                }
            }
            candidates.insert(original) // A complete example can cover a skill spanning sentence boundaries.
        }
        for text in candidates.sorted() {
            if let example = example(text) { examples.append(example) }
        }
    }

    /// Surrounding punctuation may frame a word; internal punctuation is part of its spelling.
    /// Keep names with underscores intact for C++, and reject rather than flatten joined forms.
    static func drillWord(in token: Substring) -> String? {
        let allowed: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let trimmed = token.drop(while: { !allowed($0) })
            .reversed().drop(while: { !allowed($0) }).reversed()
        guard !trimmed.isEmpty, trimmed.allSatisfy(allowed) else { return nil }
        return String(trimmed)
    }

    /// There is no session limit or fixed sequence of tests. The seed makes a result reproducible for tests;
    /// the UI supplies a new random seed and the previous passage to avoid immediate repeats.
    public func next(seed: UInt64, avoiding previous: String? = nil) -> GeneratedPractice? {
        var random = PracticeRandom(seed: seed)
        for _ in 0..<24 {
            let text: String
            if mode == .cpp && !wordDrill {
                text = code(using: &random)
            } else {
                var pool = examples.shuffled(using: &random)
                // Prefer short phrases for new skills, while review material keeps its random ordering.
                let coveragePool = wordDrill ? pool : pool.sorted { ($0.text.count > 48 ? 1 : 0) < ($1.text.count > 48 ? 1 : 0) }
                var chosen: [Example] = []
                var outstanding = requirements
                // Cover the lesson's new skills before adding varied review material.
                for candidate in coveragePool where outstanding.contains(where: { !$0.isDisjoint(with: candidate.skills) }) {
                    chosen.append(candidate)
                    outstanding.removeAll { !$0.isDisjoint(with: candidate.skills) }
                    if outstanding.isEmpty { break }
                }
                guard outstanding.isEmpty, !pool.isEmpty else { continue }
                let target = wordDrill ? 8 + random.index(5) : 3
                pool.removeAll { candidate in chosen.contains { $0.text == candidate.text } }
                while chosen.count < target {
                    if pool.isEmpty { pool = examples.shuffled(using: &random) }
                    chosen.append(pool.removeLast())
                }
                var shuffled = chosen.shuffled(using: &random)
                var ordered: [Example] = []
                while !shuffled.isEmpty {
                    // Bag refills and the final shuffle can place the same word/phrase side by side.
                    // Prefer another item whenever one remains; tiny pools may still need repeats.
                    var counts: [String: Int] = [:]
                    for item in shuffled { counts[item.text, default: 0] += 1 }
                    let options = shuffled.indices.filter { shuffled[$0].text != ordered.last?.text }
                    let index = options.max {
                        counts[shuffled[$0].text, default: 0] < counts[shuffled[$1].text, default: 0]
                    } ?? 0
                    ordered.append(shuffled.remove(at: index))
                }
                text = ordered.map(\.text).joined(separator: " ")
            }
            guard text != previous, let result = checked(text) else { continue }
            return result
        }
        return nil
    }

    private func checked(_ text: String) -> GeneratedPractice? {
        let guide = planner.plan(text)
        guard accepts(guide) else { return nil }
        let used = Set(guide.steps.flatMap { Course.skills(of: $0, data: data, mode: mode) })
        guard requirements.allSatisfy({ !$0.isDisjoint(with: used) }) else { return nil }
        return GeneratedPractice(text: text, guide: guide)
    }

    private func example(_ text: String) -> Example? {
        let guide = planner.plan(text)
        guard accepts(guide) else { return nil }
        return Example(text: text, skills: Set(guide.steps.flatMap { Course.skills(of: $0, data: data, mode: mode) }))
    }

    private func accepts(_ guide: TypingGuide) -> Bool {
        guard !guide.steps.isEmpty, guide.steps.allSatisfy(Course.isAllowed) else { return false }
        if let taught {
            return guide.steps.allSatisfy { Course.skills(of: $0, data: data, mode: mode).isSubset(of: taught) }
        }
        if case .topic(0) = source {
            return guide.steps.allSatisfy { $0.kind == .syllable && $0.parts.allSatisfy { $0.keys.count == 1 } }
        }
        if case .topic(1) = source {
            return guide.steps.allSatisfy { $0.kind == .syllable }
                && guide.steps.contains { $0.parts.contains { $0.keys.count > 1 } }
        }
        // Topic practice should still exercise its named skill, rather than only arbitrary sentences.
        if case .topic(let index) = source {
            switch index {
            case 2: return guide.steps.contains { step in
                step.kind == .brief && step.parts.contains { $0.role == .word && Self.commonWords.contains($0.text) }
            }
            case 3: return guide.steps.contains { $0.kind == .symbol }
            case 4: return guide.steps.contains { $0.kind == .suffix }
            case 5: return guide.steps.contains { $0.parts.contains { $0.role == .join } }
            case 6: return guide.steps.contains { $0.kind == .digits || $0.kind == .fingerspell }
            default: break
            }
        }
        return true
    }

    private func code(using random: inout PracticeRandom) -> String {
        let name = ["count", "score", "sum", "total"][random.index(4)]
        let first = 1 + random.index(90), second = 1 + random.index(9), third = 1 + random.index(9)
        if case .course(let index) = source {
            switch Course.steps[index].id {
            case "cpp-symbols":
                return "int \(name) = \(first); \(name) = \(name) + \(second) - \(third);"
            case "cpp-symbols-round":
                return "if (\(name) == \(first)) return \(name);"
            case "cpp-symbols-braces":
                return "if (\(name) == \(first)) { return \(name); }"
            case "cpp-names":
                let prefixes = ["max", "min", "total", "last", "first", "current"]
                let nouns = ["size", "value", "count", "score", "sum", "time", "limit", "step"]
                let variable = prefixes[random.index(prefixes.count)] + "_" + nouns[random.index(nouns.count)]
                let constant = prefixes[random.index(prefixes.count)] + "_" + nouns[random.index(nouns.count)]
                return "int \(variable) = \(constant.uppercased());"
            default: break
            }
        }
        let operation = random.index(2) == 0 ? "+" : "-"
        // A course program uses its familiar shape; free C++ practice also varies its expression.
        let expression = taught == nil ? "\(name) \(operation) \(second)" : name
        return "int main() {\n    int \(name) = \(first);\n    return \(expression);\n}"
    }

    private static func sentences(in text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = [], buffer = ""
        for (index, char) in chars.enumerated() {
            buffer.append(char)
            if [".", "?", "!"].contains(char) {
                if index + 1 < chars.count, chars[index + 1] == "\"" { continue }
                out.append(String(buffer.drop(while: \.isWhitespace)))
                buffer = ""
            } else if char == "\"", buffer.dropLast().last == "." {
                out.append(String(buffer.drop(while: \.isWhitespace)))
                buffer = ""
            }
        }
        if !buffer.allSatisfy(\.isWhitespace) { out.append(String(buffer.drop(while: \.isWhitespace))) }
        return out
    }

    private static let words = """
    sat hat tan at an as has sad had sand hand stand sit hit fit set get wet sun fun run rat red bed led tip dip lip
    hot dot lot man mat cat pat can pan pet pot kid nap cup van jet jam joy big dog dug fog fox box cab six
    book look took cook good food rain tail wait paid sea tea read seed feed tree green sleep sheep ship fresh
    plant black stamp trust thank click crash wish fish bath back song king ring long small crab clap plan
    stop trip from the then that this she they we he her him my his for day home make take like nice give
    love face page cave hope tried played jumped making nicer biggest faster slowly kindness payment
    readable careful restful darkness useful wonderful possible anything everybody understanding
    """

    private static let commonWords: Set<String> = ["their", "about", "people", "into", "other", "only", "over",
        "also", "after", "first", "because", "through", "before", "between", "never", "every", "little",
        "different", "important", "something"]

    /// Small grammar templates produce readable sentences; only examples the active lesson can type survive.
    private static let sentences: [String] = {
        let subjects = ["I", "He", "She", "We", "They", "The cat", "The dog", "The kid", "Tom", "Sam"]
        let actions = ["sat on the mat", "went home", "read a book", "had a nap", "made tea", "ran in the sun",
                       "waited in the rain", "looked at the sea", "played in the park", "tried making tea"]
        var result = subjects.flatMap { subject in actions.map { "\(subject) \($0)." } }
        result += ["He runs faster and reads slowly.", "She is making tea in the kitchen.",
                   "She is making tea.", "He runs faster.", "She reads slowly.", "He tried hoping.",
                   "The nicest thing is a good book.",
                   "The nicest thing is a warm cup of tea.", "Kindness is useful.", "The payment is due.",
                   "The note is readable.",
                   "The darkness is restful.", "Everybody wants something wonderful.", "Anything is possible.",
                   "Understanding takes time.", "People like their work because it is important.",
                   "We have other things to do after that.", "Every little thing is different.",
                   "Is it hot?", "Can we go in the sea?", "Yes, we can!", "She said: \"Thank you.\"",
                   "Tom (my friend) is here; he likes it.", "It's a well-made bed: the cat's bed is big."]
        for number in 1...30 {
            result.append("The team met at 10:30 in room \(number).")
            result.append("I have \(number) cats and 2 dogs.")
            result.append("The NASA team met the BBC in room \(number).")
        }
        return result
    }()
}

private struct PracticeRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
}
