// Practice texts for the Typing Guide, in the order the manual teaches them. Every lesson can be typed
// entirely with chords on the default layout (checked in the tests). Standard library only.

public struct Lesson: Equatable, Sendable {
    public let title: String
    /// What the lesson practices, in one sentence.
    public let summary: String
    public let text: String
    public let mode: SubMode

    public init(title: String, summary: String, text: String, mode: SubMode) {
        self.title = title
        self.summary = summary
        self.text = text
        self.mode = mode
    }
}

public enum Lessons {
    public static let all: [Lesson] = [
        Lesson(title: "One key for each sound",
               summary: "Words where every sound is a single key: one for the start, one for the vowel, one for the end.",
               text: "sit hit fit set get wet sun fun run rat sat hat red bed led tip dip lip hot dot lot",
               mode: .english),
        Lesson(title: "Two-key sounds",
               summary: "Vowel pairs such as ea and oo, and starts and ends such as th, sh, st, nd and ng.",
               text: "sea tea read seed feed out loud food good rain tail "
                   + "the ship, the sheep, a fresh plant, a black stamp, trust and thank, click and crash",
               mode: .english),
        Lesson(title: "Common words",
               summary: "Words with a chord of their own, like their, people and because.",
               text: "I think people like their work because it is important. "
                   + "We have other things to do after that, but only for a little time.",
               mode: .english),
        Lesson(title: "Capitals and punctuation",
               summary: "Automatic capitals after a full stop, a capital on the next word, quotes, brackets and more.",
               text: "Is this Anna's book? Yes! She said: \"Thank you.\" Tom (my friend) is here; he likes it.",
               mode: .english),
        Lesson(title: "Endings",
               summary: "Add s, ing, ed, er, est, ly, ness, ment, able or ful to the word before; KeyChord fixes the spelling.",
               text: "She tried making tea. The boxes are the biggest. He runs faster and reads slowly. "
                   + "Kindness is useful.",
               mode: .english),
        Lesson(title: "Long words",
               summary: "Words that take more than one chord: hold Shift to join a chord onto the one before.",
               text: "Anything is possible. Everybody wants something wonderful. Understanding takes time.",
               mode: .english),
        Lesson(title: "Letters and numbers",
               summary: "Spell a word letter by letter, add capitals, and type numbers on the number row.",
               text: "The NASA team met at 10:30 in room 12. Spell it: q u i z. The code is 2468.",
               mode: .english),
        Lesson(title: "C++",
               summary: "Keywords, operators and brackets in C++ mode.",
               text: "int main() {\n    int count = 0;\n    return count;\n}",
               mode: .cpp),
    ]
}
