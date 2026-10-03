import Testing
@testable import KeyChordCore

/// Plays a guide back through a fresh engine the way a user would type it, and returns the text.
/// `prefix` is text already typed, and `context` the engine's context at that point.
func replay(_ guide: TypingGuide, data: EngineData = defaults, prefix: String = "",
            context: EngineContext? = nil) throws -> String {
    let engine = ChordEngine(data: data, subMode: guide.mode)
    if let context { engine.restore(context) }
    var buffer = TextBuffer(prefix)
    for step in guide.steps {
        switch step.action {
        case let .chord(names, shift):
            let k = try #require(data.layout.keySet(names: names), "unknown keys \(names)")
            for (n, i) in k.indices.enumerated() { engine.keyDown(i, shift: shift && n == 0) }
            var result: EngineResult?
            for i in k.indices { if let r = try engine.keyUp(i) { result = r } }
            let r = try #require(result)
            #expect(r.signal == nil, "chord \(names) signalled \(String(describing: r.signal))")
            try buffer.apply(r.actions)
        case .key(.returnKey):
            try buffer.apply(.insert("\n"))
            engine.contextReset()
        case .key(.tab):
            try buffer.apply(.insert("\t"))
            engine.contextReset()
        case .key(.delete):
            try buffer.apply(.deleteBackward(1))
            engine.contextReset()
        case .typeNormally(let s):
            engine.contextReset()        // Option tap into Normal_Mode
            try buffer.apply(.insert(s))
            engine.contextReset()        // Option tap back into Chord_Mode
        }
        #expect(buffer.cursor == buffer.chars.count, "cursor moved away from the end")
        #expect(buffer.chars.count == step.textEnd, "textEnd of \(step.action) is \(step.textEnd), typed \(buffer.chars.count)")
    }
    return buffer.text
}

func normalizedNewlines(_ s: String) -> String {
    String(s.map { TypingPlanner.isLineBreak($0) ? "\n" : $0 })
}

func plan(_ text: String, _ mode: SubMode = .english) -> TypingGuide {
    TypingPlanner(data: defaults, mode: mode).plan(text)
}

/// A chord spec in the planner's key order (Layout order).
func ks(_ spec: String) -> String { defaults.layout.chordString(keys(spec)) }

func chords(_ g: TypingGuide) -> [String] {
    g.steps.compactMap {
        guard case let .chord(keys, shift) = $0.action else { return nil }
        return (shift ? "^" : "") + keys.joined(separator: "+")
    }
}

@Suite("Typing guide planner")
struct TypingPlannerTests {
    @Test func englishRoundTrip() throws {
        let text = """
        The quick brown fox jumps over the lazy dog. It's a well-known sentence!
        "Hello," she said (quietly); I replied: making, tried, boxes, stopping, happiness.
        e.g. this is lowercase after a period.  Two spaces, and a\ttab.
        Numbers: 123, 321, 2026 and 10.
          Indented line with trailing spaces   \r
        Symbols like @ and café fall back to normal typing.

        Last line after a blank one
        """
        let g = plan(text)
        #expect(try replay(g) == normalizedNewlines(text))
        #expect(g.chordCount > 0)
        #expect(g.normalCount > 0)
    }

    @Test func cppRoundTrip() throws {
        let text = """
        #include <vector>
        int main() {
            std::vector<int> values;
            for (int i = 0; i < 10; ++i) { values.push_back(i * 2); }
            const auto max_size = MAX_VALUE;
            return getUserName(x) != nullptr && a->b == c::d;
        }
        """
        let g = plan(text, .cpp)
        #expect(try replay(g) == text)
    }

    @Test func capitalizedFirstWordUsesCapitalizeNext() {
        let g = plan("The cat")
        #expect(chords(g) == [ks("N+M"), ks(THE), ks(CAT)])
        #expect(g.steps[0].kind == .command)
        #expect(g.steps[2].output == " cat")
    }

    @Test func automaticCapitalAfterPeriod() throws {
        let g = plan("the cat. The cat")
        // No Capitalize_Next needed after the period.
        #expect(!g.steps.contains { $0.kind == .command })
        #expect(try replay(g) == "the cat. The cat")
    }

    @Test func lowercaseAfterPeriodUsesTheAbbreviationPeriod() throws {
        let g = plan("the. cat")
        #expect(chords(g).contains(ks("Quote+Period")))
        #expect(!g.steps.contains { $0.kind == .cancelCapital })
        #expect(g.normalCount == 0)
        #expect(try replay(g) == "the. cat")
        // "Mr. and" needs no throwaway letter; "Mr. Dursley" keeps the automatic capital.
        let mr = plan("Mr. and Mrs. Dursley")
        #expect(chords(mr).filter { $0 == ks("Quote+Period") }.count == 1)
        #expect(chords(mr).filter { $0 == "Period" }.count == 1)
        #expect(!mr.steps.contains { $0.kind == .cancelCapital || $0.kind == .command && $0.source.lowerBound > 0 })
        #expect(try replay(mr) == "Mr. and Mrs. Dursley")
        // Without the abbreviation chord, the throwaway letter still works.
        var noAbbrev = defaults
        noAbbrev.english.entries[keys("Quote+Period")] = nil
        let old = TypingPlanner(data: noAbbrev, mode: .english).plan("the. cat")
        #expect(old.steps.contains { $0.kind == .cancelCapital })
        #expect(old.steps.contains { $0.action == .key(.delete) })
        #expect(try replay(old, data: noAbbrev) == "the. cat")
        // Single letters between periods are cheaper to cancel than to type in Normal mode.
        let eg = plan("e.g. this")
        #expect(eg.normalCount == 0)
        #expect(try replay(eg) == "e.g. this")
    }

    @Test("Steps record the planned in-between text and the context")
    func tailsAndContexts() throws {
        let g = plan("making")
        let base = try #require(g.steps.first)
        #expect(base.output == "make" && base.tail == "e" && base.prefixEnd == 3)
        #expect(g.steps.last?.tail == "")
        #expect(g.steps.allSatisfy { $0.contextAfter != nil })
    }

    @Test("Blocked chords from the matrix scan are never planned")
    func usablePredicate() throws {
        let banned = keys("U+F+G")
        let text = "Mr. and Mrs. Dursley made drills"
        #expect(chords(plan(text)).contains(defaults.layout.chordString(banned)))
        let g = TypingPlanner(data: defaults, mode: .english, usable: { !$0.isSuperset(of: KeySet([banned.indices[0], banned.indices[1]])) || $0.count < 3 }).plan(text)
        for c in chords(g) {
            let k = try #require(defaults.layout.keySet(names: c.replacingOccurrences(of: "^", with: "").split(separator: "+").map(String.init)))
            #expect(k.count < 3 || !k.isSuperset(of: KeySet([banned.indices[0], banned.indices[1]])), "\(c)")
        }
        #expect(try replay(g) == text)
    }

    @Test func suffixes() throws {
        let g = plan("making jumps")
        let kinds = g.steps.map(\.kind)
        #expect(kinds.filter { $0 == .suffix }.count == 2)
        #expect(g.chordCount == 4)
        #expect(try replay(g) == "making jumps")
        // The guide teaches the real base word.
        let tried = plan("tried")
        #expect(tried.steps.last?.note == "suffix: try + ed → tried")
    }

    @Test func briefsAndFingerspelling() throws {
        let g = plan("I think about people")
        #expect(g.steps.first?.action == .chord(keys: ["M"], shift: false))
        #expect(chords(g).contains(ks("Quote+A+B")))
        #expect(try replay(g) == "I think about people")
        let spelled = plan("xyzzy")
        #expect(try replay(spelled) == "xyzzy")
    }

    @Test("Joins use the space bar, and Shift only where the keyboard can't take it")
    func joinUsesTheSpaceBar() throws {
        let g = plan("hello")
        #expect(g.chordCount == 2)
        let last = try #require(g.steps.last)
        guard case let .chord(keys, shift) = last.action else { Issue.record("not a chord"); return }
        #expect(keys.contains("Space") && !shift)
        #expect(last.parts.first == TypingStep.Part(text: "join", keys: ["Space"], role: .join))
        #expect(try replay(g) == "hello")

        // "dow" in "window" can't take the space bar on the MacBook Pro 2021 (Y, I and Space make a ghost), so it
        // is joined with Shift there, and with the space bar on a keyboard without that limit.
        func usesShift(_ g: TypingGuide) -> Bool {
            g.steps.contains { if case .chord(_, true) = $0.action { return true } else { return false } }
        }
        let usable = macBookLimits.usable(in: defaults.layout)
        let window = TypingPlanner(data: defaults, mode: .english, usable: usable).plan("window")
        #expect(usesShift(window))
        #expect(try replay(window) == "window")
        #expect(!usesShift(plan("window")))
        // Where another split avoids the ghost, the planner takes it: "sorry" is sor + ry, joined with the space bar.
        #expect(!usesShift(TypingPlanner(data: defaults, mode: .english, usable: usable).plan("sorry")))
        // Every chord planned with the space bar is one the keyboard registers.
        let text = "Everybody wants something wonderful, understanding and possible. Sorry, hurry."
        for s in TypingPlanner(data: defaults, mode: .english, usable: usable).plan(text).steps {
            if case let .chord(keys, _) = s.action, keys.count > 1, keys.contains("Space") {
                #expect(usable(try #require(defaults.layout.keySet(names: keys))), "\(keys)")
                #expect(keys.count <= 6)
            }
        }
    }

    @Test func digits() throws {
        let g = plan("123 321")
        // 1+2+3 is one chord; 3, 2, 1 must be separate chords (keyboard order). Digits glue together,
        // so the space between the numbers needs the Space key.
        #expect(chords(g) == ["1+2+3", "Space", "3", "2", "1"])
        #expect(try replay(g) == "123 321")
    }

    @Test func spacesAndLines() throws {
        let text = "a  b\n\n  c \tz"
        let g = plan(text)
        // Two between a and b, two indenting c, one trailing space before the tab.
        #expect(g.steps.filter { $0.kind == .space }.count == 5)
        #expect(g.steps.filter { $0.action == .key(.returnKey) }.count == 2)
        #expect(g.steps.filter { $0.action == .key(.tab) }.count == 1)
        #expect(try replay(g) == text)
    }

    @Test func unsupportedCharactersAreTypedNormally() throws {
        let g = plan("mail me@example")
        let normal = g.steps.compactMap { if case .typeNormally(let s) = $0.action { return s } else { return nil } }
        #expect(normal == ["@"])
        #expect(try replay(g) == "mail me@example")
    }

    @Test func snakeCaseUsesCasingMode() throws {
        let g = plan("max_size = 1", .cpp)
        #expect(chords(g).first == ks("Grave+S"))
        #expect(g.normalCount == 0)
        #expect(try replay(g) == "max_size = 1")
    }

    @Test func sourceRangesAndLookup() throws {
        let text = "the cat\nsat"
        let g = plan(text)
        for s in g.steps { #expect(s.source.lowerBound >= 0 && s.source.upperBound <= text.count) }
        let catStep = try #require(g.stepIndex(at: 5))
        #expect(g.steps[catStep].source == 4..<7)
        let satStep = try #require(g.stepIndex(at: 9))
        #expect(g.steps[satStep].source == 8..<11)
        #expect(plan("").steps.isEmpty)
    }

    @Test("Random text always round-trips", arguments: SubMode.allCases)
    func randomRoundTrip(mode: SubMode) throws {
        var rng = SplitMix64(seed: mode == .english ? 7 : 11)
        let pieces = ["the", "The", "cat", "making", "I", "x", "Q", "hello", "world", "a", "123", "7", "0",
                      ".", ",", "!", "?", "'", "\"", "(", ")", "-", ":", ";", "@", "#", "é", "_", "::", "->",
                      "{", "}", "==", "*", "&", " ", " ", " ", "  ", "\n", "\t", "std", "int", "max_size", "ABC"]
        for _ in 0..<60 {
            var text = ""
            for _ in 0..<Int.random(in: 1...25, using: &rng) { text += pieces.randomElement(using: &rng)! }
            let g = TypingPlanner(data: defaults, mode: mode).plan(text)
            #expect(try replay(g) == text, "\(mode): \(text.debugDescription)")
        }
    }
}
