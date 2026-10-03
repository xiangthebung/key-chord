import Foundation
import Testing
@testable import KeyChordCore

/// Plans a real book chapter and replays it. The text is not part of the repository: set KEYCHORD_BOOK to a
/// plain-text file (default ~/Downloads/hp1.txt); the test is skipped when the file is missing.
@Suite("Book chapter")
struct BookChapterTests {
    static let path = ProcessInfo.processInfo.environment["KEYCHORD_BOOK"]
        ?? NSHomeDirectory() + "/Downloads/hp1.txt"

    /// The first chapter: from the start up to the line that begins the second one.
    static var chapter: String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.hasPrefix("CHAPTER ") }) else { return text }
        return lines[..<end].joined(separator: "\n")
    }

    @Test(.enabled(if: chapter != nil))
    func firstChapterRoundTrips() throws {
        let text = try #require(Self.chapter)
        let g = plan(text)
        #expect(try replay(g) == normalizedNewlines(text))
        let normal = g.steps.compactMap { s -> String? in if case .typeNormally(let t) = s.action { return t } else { return nil } }
        let counts = Dictionary(grouping: normal, by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }
        #expect(try routerReplay(g) == normalizedNewlines(text))
        #expect(try replayWithMistakes(g, every: 7) == normalizedNewlines(text))
        print("chapter 1: \(text.count) characters, \(g.chordCount) chords, \(g.normalCount) normal-mode runs")
        print("typed normally: \(counts.prefix(40).map { "\($0.key.debugDescription)×\($0.value)" }.joined(separator: " "))")
    }
}

/// Plays a guide through the Event_Router with real key events, the way the app receives them: Shift as a
/// modifier event plus key flags, Delete / Return / Tab as pass-through keys, right Option taps around
/// Normal_Mode typing.
func routerReplay(_ guide: TypingGuide, data: EngineData = defaults) throws -> String {
    let h = RouterHarness(sub: guide.mode)
    h.optionTap(ROPT)
    #expect(h.router.effectiveMode == .chord(guide.mode))
    for step in guide.steps {
        switch step.action {
        case let .chord(names, shift):
            let k = try #require(data.layout.keySet(names: names))
            let codes = k.indices.map { data.layout.keys[$0].code }
            let f: ModifierFlags = shift ? [.shift] : []
            if shift { h.send(.modifierDown(code: LSHIFT, key: .shift, time: h.time)) }
            for c in codes { #expect(h.down(c, f) == .suppress) }
            for c in codes { #expect(h.up(c, f) == .suppress) }
            if shift { h.send(.modifierUp(code: LSHIFT, key: .shift, time: h.time)) }
        case .key(let key):
            let code: KeyCode = key == .returnKey ? 36 : key == .tab ? 48 : 51
            #expect(h.down(code) == .pass)
            h.up(code)
            // The app applies a passed key itself.
            switch key {
            case .returnKey: try h.buffer.apply(.insert("\n"))
            case .tab: try h.buffer.apply(.insert("\t"))
            case .delete: try h.buffer.apply(.deleteBackward(1))
            }
        case .typeNormally(let s):
            h.optionTap(ROPT)
            #expect(h.router.effectiveMode == .normal)
            try h.buffer.apply(.insert(s))          // typed by the user; passed through
            h.optionTap(ROPT)
            #expect(h.router.effectiveMode == .chord(guide.mode))
        }
        if h.buffer.chars.count != step.textEnd {
            Issue.record("router replay diverged at \(step.action): typed \(String(h.buffer.chars.suffix(30)).debugDescription)")
            return h.buffer.text
        }
    }
    return h.buffer.text
}

/// Replays a guide, but every `every` chords types a wrong word first, deletes it with Delete (which resets
/// the engine's context), and puts the context back from the previous step, as the Typing Guide window does.
func replayWithMistakes(_ guide: TypingGuide, every: Int, restore: Bool = true, data: EngineData = defaults) throws -> String {
    let engine = ChordEngine(data: data, subMode: guide.mode)
    var buffer = TextBuffer()
    let wrong = try #require(data.layout.keySet(names: ["T", "C"]))       // "ta", a plain syllable
    func chord(_ k: KeySet, _ shift: Bool) throws {
        for (n, i) in k.indices.enumerated() { engine.keyDown(i, shift: shift && n == 0) }
        var result: EngineResult?
        for i in k.indices { if let r = try engine.keyUp(i) { result = r } }
        try buffer.apply(try #require(result).actions)
    }
    var n = 0
    var previous: TypingStep?
    for step in guide.steps {
        if case .chord = step.action, let prev = previous, prev.tail.isEmpty, let ctx = prev.contextAfter {
            n += 1
            if n % every == 0 {
                let before = buffer.chars.count
                try chord(wrong, false)
                for _ in before..<buffer.chars.count {
                    try buffer.apply(.deleteBackward(1))
                    engine.contextReset()                 // Delete is a pass-through key
                }
                if restore { engine.restore(ctx) }
            }
        }
        switch step.action {
        case let .chord(names, shift):
            try chord(try #require(data.layout.keySet(names: names)), shift)
        case .key(.returnKey):
            try buffer.apply(.insert("\n")); engine.contextReset()
        case .key(.tab):
            try buffer.apply(.insert("\t")); engine.contextReset()
        case .key(.delete):
            try buffer.apply(.deleteBackward(1)); engine.contextReset()
        case .typeNormally(let s):
            engine.contextReset(); try buffer.apply(.insert(s)); engine.contextReset()
        }
        if buffer.chars.count != step.textEnd {
            Issue.record("diverged after a fixed mistake at \(step.action): \(String(buffer.chars.suffix(30)).debugDescription)")
            return buffer.text
        }
        previous = step
    }
    return buffer.text
}

@Suite("Mistake recovery")
struct MistakeRecoveryTests {
    @Test func englishSample() throws {
        let text = "Mr. and Mrs. Dursley, of number four, Privet Drive, were proud to say that they were perfectly normal.\n"
            + "\"Hello,\" she said. It's making them happier; e.g. this is lowercase. McGonagall's cat sat."
        let g = plan(text)
        for every in [1, 2, 3, 5] { #expect(try replayWithMistakes(g, every: every) == text) }
        #expect(try routerReplay(g) == text)
        // Without putting the context back, the chord after a fixed mistake loses its space or capital.
        withKnownIssue { _ = try replayWithMistakes(g, every: 1, restore: false) }
    }

    @Test func cppSample() throws {
        let text = "int main() {\n    const auto max_size = MAX_VALUE;\n    return getUserName(x) != nullptr;\n}"
        let g = plan(text, .cpp)
        for every in [1, 3] { #expect(try replayWithMistakes(g, every: every) == text) }
    }
}
