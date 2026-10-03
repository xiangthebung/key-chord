import Testing
@testable import KeyChordCore

/// The planned context at the last step boundary at or before `offset`, as the Typing Guide passes it on.
func contextBefore(_ offset: Int, in guide: TypingGuide) -> EngineContext? {
    guide.steps.last { $0.textEnd <= offset && $0.tail.isEmpty }?.contextAfter
}

/// Plans the rest of the line from `offset` and replays it after `text[..<offset]`; returns the replayed text
/// and the expected text.
func continueTyping(_ text: String, from offset: Int, mode: SubMode = .english, full: TypingGuide? = nil,
                    maxLength: Int = 2000) throws -> (typed: String, expected: String, continuation: TypingContinuation) {
    let planner = TypingPlanner(data: defaults, mode: mode)
    let g = full ?? planner.plan(text)
    let c = planner.planContinuation(text, from: offset, previous: contextBefore(offset, in: g), maxLength: maxLength)
    let chars = Array(text)
    let typed = try replay(c.guide, prefix: String(chars[..<c.start]), context: c.startContext)
    return (typed, String(chars[..<c.end]), c)
}

@Suite("Typing guide: continuing from anywhere")
struct TypingContinuationTests {
    @Test("Part of a word typed: the rest of the word, then the rest of the line")
    func restOfWord() throws {
        let text = "I want anything you like."
        let offset = Array(text).firstIndex(of: "y")!                  // "an" of "anything" typed
        let r = try continueTyping(text, from: offset)
        #expect(r.typed == text)
        let first = try #require(r.continuation.guide.steps.first)
        #expect(first.output.hasPrefix("y"))                           // no space in the middle of the word
        #expect(first.source.lowerBound == offset)                     // the guide shows "ything"
        #expect(r.continuation.guide.normalCount == 0)
    }

    @Test("Every position of a text continues to the end of its line", arguments: [SubMode.english, .cpp])
    func everyOffset(mode: SubMode) throws {
        let text = mode == .english
            ? "Mr. and Mrs. Dursley, of number four, were proud to say that they were perfectly normal.\n"
                + "\"Hello,\" she said. It's making them happier; McGonagall's cat sat at 12:30."
            : "int main() {\n    const auto max_size = MAX_VALUE;\n    return getUserName(x) != nullptr;\n}"
        let full = TypingPlanner(data: defaults, mode: mode).plan(text)
        let chars = Array(text)
        for offset in 0..<chars.count where !TypingPlanner.isLineBreak(chars[offset]) {
            let r = try continueTyping(text, from: offset, mode: mode, full: full)
            #expect(r.typed == r.expected, "from \(offset): \(String(chars[..<offset]).suffix(20).debugDescription)")
        }
    }

    @Test("Very long lines stop at a word end")
    func longLine() throws {
        let text = String(repeating: "the cat sat on the mat and ", count: 80)
        let r = try continueTyping(text, from: 5, maxLength: 100)
        #expect(r.continuation.end > 105 && r.continuation.end < 120)
        #expect(Array(text)[r.continuation.end] == " ")
        #expect(r.typed == r.expected)
    }

    @Test("At the end of a word, the next word gets its space as usual")
    func wordEnd() throws {
        let text = "the cat"
        let r = try continueTyping(text, from: 3)
        #expect(r.typed == text)
        #expect(r.continuation.guide.chordCount == 1)                    // " cat": no separate Space chord
    }
}

@Suite("What keys and chords mean")
struct KeyMeaningTests {
    func code(_ name: String) -> KeyCode { defaults.layout.keys[defaults.layout.indexByName[name]!].code }

    @Test func englishKeys() {
        let m = KeyMeanings(data: defaults, mode: .english)
        func meaning(_ n: String) -> KeyMeanings.Meaning? { m.keys[code(n)] }
        #expect(meaning("E") == .init(role: .onset, label: "h", alone: nil))
        #expect(meaning("C") == .init(role: .vowel, label: "a", alone: nil))
        #expect(meaning("M") == .init(role: .vowel, label: "i", alone: "I"))
        #expect(meaning("O") == .init(role: .coda, label: "d", alone: "-ed"))
        #expect(meaning("Semicolon") == .init(role: .coda, label: "s", alone: "-s"))
        #expect(meaning("Quote") == .init(role: .spell, label: "spell", alone: "'"))
        #expect(meaning("Backslash") == .init(role: .special, label: "undo", alone: nil))
        #expect(meaning("LBracket") == .init(role: .special, label: "(", alone: nil))
        #expect(meaning("Equal") == .init(role: .special, label: "", alone: nil))
        #expect(meaning("Space") == .init(role: .space, label: "join", alone: "space"))
        #expect(meaning("7") == .init(role: .number, label: "7", alone: nil))
        let l = defaults.layout
        #expect(m.capitalKey == l.indexByName["Semicolon"])
        #expect(m.capitalizeNextKeys == l.keySet(names: ["N", "M"]))
        #expect(m.undoKeys == l.keySet(names: ["Backslash"]))
        #expect(m.modeSwitchKeys == l.keySet(names: ["LBracket", "RBracket"]))
    }

    @Test func cppKeys() {
        let m = KeyMeanings(data: defaults, mode: .cpp)
        #expect(m.keys[code("Semicolon")] == .init(role: .coda, label: "s", alone: ";"))
        #expect(m.keys[code("Equal")] == .init(role: .special, label: "=", alone: nil))
        #expect(m.keys[code("Grave")] == .init(role: .special, label: "end", alone: nil))
        #expect(m.keys[code("Quote")] == .init(role: .spell, label: "spell", alone: "'…'"))
        #expect(m.keys[code("M")] == .init(role: .vowel, label: "i", alone: nil))
    }

    func parts(_ s: TypingStep) -> [String] { s.parts.map { "\($0.role.rawValue):\($0.text)=\($0.keys.joined(separator: "+"))" } }

    @Test func chordParts() throws {
        let thing = plan("thing").steps
        #expect(thing.count == 1)
        #expect(parts(thing[0]) == ["onset:th=E+T", "vowel:i=M", "coda:ng=K+L"])

        let api = plan("API").steps
        #expect(api.allSatisfy { $0.kind == .fingerspell })
        #expect(parts(api[0]) == ["spell:spell=Quote", "capital:capital=Semicolon", "letter:a=A"])

        let digits = plan("12").steps
        #expect(parts(digits[0]) == ["digit:1=1", "digit:2=2"])

        let making = plan("making").steps
        #expect(parts(try #require(making.last)) == ["suffix:-ing=K+L"])

        let about = plan("about").steps
        #expect(parts(about[0]) == ["word:about=A+Quote+B"])

        let period = plan("I.").steps
        #expect(parts(try #require(period.last)) == ["symbol:.=Period"])

        for s in plan("Mr. and Mrs. Dursley, of number four. It's 12 o'clock!").steps where s.isChord {
            #expect(!s.parts.isEmpty, "\(s.action) has no parts")
            let union = Set(s.parts.flatMap(\.keys))
            if case let .chord(keys, _) = s.action { #expect(union == Set(keys), "\(s.action): \(parts(s))") }
        }
    }
}
