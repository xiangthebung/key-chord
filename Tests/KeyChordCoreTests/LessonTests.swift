import Testing
@testable import KeyChordCore

let macBookLimits = KeyboardLimits(wiringText: DefaultData.wiringMacBookPro18, scanText: nil, layout: defaults.layout)!
/// The US (ANSI) MacBook Pro 2021: the ISO wiring without Grave and Backslash (derived, not measured).
let macBookUSLimits = KeyboardLimits(wiringText: DefaultData.wiringMacBookPro18ANSI, scanText: nil, layout: defaults.layout)!

@Suite("Lessons")
struct LessonTests {
    @Test("Every lesson is typed with chords only, on any Mac and on both MacBook Pro 2021 keyboards",
          arguments: Array(Lessons.all.indices))
    func chordsOnly(index: Int) throws {
        let lesson = Lessons.all[index]
        for usable in [{ (_: KeySet) in true }, macBookLimits.usable(in: defaults.layout),
                       macBookUSLimits.usable(in: defaults.layout)] {
            let g = TypingPlanner(data: defaults, mode: lesson.mode, usable: usable).plan(lesson.text)
            #expect(g.normalCount == 0, "\(lesson.title) needs Normal mode")
            #expect(try replay(g) == lesson.text)
        }
    }

    @Test("The first lesson uses one key per sound, one chord per word")
    func firstLesson() {
        let g = plan(Lessons.all[0].text)
        for s in g.steps where s.isChord {
            #expect(s.kind == .syllable)
            #expect(s.parts.allSatisfy { $0.keys.count == 1 }, "\(s.action)")
        }
        #expect(Set(g.steps.map(\.group)).count == g.steps.count)
    }
}
