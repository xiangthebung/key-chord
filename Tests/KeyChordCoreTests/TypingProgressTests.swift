import Testing
@testable import KeyChordCore

/// Replays the guide with the practice screen's continuation decision between chords. An unnecessary
/// continuation changes the real engine context, so the next suffix can produce the wrong spelling.
@discardableResult
func replayPractice(_ guide: TypingGuide, text: String, data: EngineData = defaults) throws -> String {
    let target = Array(normalizedNewlines(text))
    let engine = ChordEngine(data: data, subMode: guide.mode)
    let planner = TypingPlanner(data: data, mode: guide.mode)
    var buffer = TextBuffer()
    for (i, step) in guide.steps.enumerated() {
        switch step.action {
        case let .chord(names, shift):
            let chord = try #require(data.layout.keySet(names: names))
            for (n, key) in chord.indices.enumerated() { engine.keyDown(key, shift: shift && n == 0) }
            var result: EngineResult?
            for key in chord.indices { if let r = try engine.keyUp(key) { result = r } }
            let r = try #require(result)
            #expect(r.signal == nil, "\(text): \(names)")
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
        case .typeNormally(let value):
            engine.contextReset()
            try buffer.apply(.insert(value))
            engine.contextReset()
        }
        let correct = zip(buffer.chars, target).prefix { $0 == $1 }.count
        let expected = Array(target.prefix(step.prefixEnd)) + Array(step.tail)
        #expect(buffer.chars == expected, "\(text), step \(i): expected \(String(expected)), typed \(buffer.text)")
        let tailStep = !step.tail.isEmpty && buffer.chars == expected ? i : nil
        let onPlan = guide.isPlanned(at: correct, tailStep: tailStep)
        #expect(onPlan, "\(text), step \(i): \(buffer.text) must not reset the suffix context")
        if !onPlan {
            let c = planner.planContinuation(text, from: correct, previous: contextBefore(correct, in: guide))
            engine.restore(c.startContext)
        }
    }
    #expect(buffer.text == normalizedNewlines(text), "following the shown combinations types \(buffer.text)")
    return buffer.text
}

@Suite("Typing practice progress")
struct TypingProgressTests {
    @Test("Spelling changes keep the base context until the suffix is typed",
          arguments: ["sam tried making tea", "making", "hoping", "tried", "nicest", "nicer", "happier",
                      "happiness", "stopping", "running", "swimming", "lying", "tying", "arguing"])
    func spellingChanges(text: String) throws {
        try replayPractice(plan(text), text: text)
    }

    @Test("A genuine partial word still needs a continuation")
    func partialWord() {
        let guide = plan("making tea")
        #expect(!guide.isPlanned(at: 2))
        #expect(!guide.isPlanned(at: 3)) // "mak" without the planned temporary "e"
        #expect(guide.isPlanned(at: 0))
        #expect(guide.isPlanned(at: 6))
        #expect(guide.isPlanned(at: 3, start: 3))
    }
}
