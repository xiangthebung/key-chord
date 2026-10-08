import Testing
@testable import KeyChordCore

@Suite("Word Sprint")
struct WordPracticeTests {
    @Test("The named offline vocabularies preserve distinct ASCII English spellings")
    func vocabularies() {
        for (vocabulary, count) in [(WordPracticeVocabulary.english, 200), (.english5k, 5_000), (.english25k, 24_141)] {
            let words = vocabulary.words
            #expect(words.count == count)
            #expect(Set(words).count == count)
            #expect(words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLetter } })
        }
    }

    @Test("Seeded generation covers the chosen vocabulary without adjacent repeats")
    func generation() {
        var first = WordPracticeWordStream(words: ["cat", "dog", "hat", "sun"], seed: 123)
        var second = WordPracticeWordStream(words: ["cat", "dog", "hat", "sun"], seed: 123)
        var seen = Set<String>(), previous: String?
        for _ in 0..<300 {
            let word = first.next()
            #expect(word == second.next())
            #expect(word != previous)
            previous = word
            seen.insert(word)
        }
        #expect(seen.count == 4)
        var single = WordPracticeWordStream(words: ["cat"], seed: 1)
        #expect(single.next() == "cat" && single.next() == "cat")
    }

    @Test("A timed test waits for the first character and ends exactly at its deadline")
    func deadline() {
        let session = WordPracticeSession(goal: .time(15), seed: 1, words: ["cat"])
        session.advance(to: 100)
        #expect(session.startedAt == nil && !session.isFinished)
        #expect(session.edit(range: 0..<0, replacement: "cat", at: 100))
        session.advance(to: 114.9)
        #expect(!session.isFinished)
        session.advance(to: 120)
        #expect(session.finishedAt == 115)
        #expect(session.metrics(at: 999).elapsed == 15)
        #expect(!session.edit(range: 3..<3, replacement: " ", at: 121))
        #expect(session.typedText == "cat")
        #expect(session.samples.last?.seconds == 15)
    }

    @Test("Input arriving at the deadline cannot inflate the final result")
    func lateEdit() {
        let session = WordPracticeSession(goal: .time(15), seed: 1, words: ["cat"])
        session.edit(range: 0..<0, replacement: "c", at: 20)
        #expect(!session.edit(range: 1..<1, replacement: "at", at: 35))
        #expect(session.typedText == "c")
        #expect(session.metrics(at: 35).rawWPM == 0.8)
    }

    @Test("Deleting and correcting an error does not restore perfect accuracy")
    func correctedMistakes() {
        let session = WordPracticeSession(goal: .time(30), seed: 1, words: ["cat"])
        session.edit(range: 0..<0, replacement: "x", at: 0)
        session.edit(range: 0..<1, replacement: "", at: 1)
        session.edit(range: 0..<0, replacement: "cat", at: 2)
        let metrics = session.metrics(at: 3)
        #expect(metrics.accuracy == 75)
        #expect(metrics.mistakes == 1)
        #expect(metrics.correct == 3 && metrics.incorrect == 0)
        #expect(metrics.rawWPM == 12)
    }

    @Test("WPM credits correct words; character details report errors, extras, and omissions")
    func scoring() {
        let session = WordPracticeSession(goal: .time(60), seed: 1, words: ["cat"])
        session.edit(range: 0..<0, replacement: "cat car catx c ", at: 0)
        let metrics = session.metrics(at: 30)
        #expect(metrics.wpm == 1.6) // one correct word plus its space = four credited characters
        #expect(metrics.rawWPM == 6)
        #expect(metrics.correct == 10)
        #expect(metrics.incorrect == 1 && metrics.extra == 1 && metrics.missed == 2)
        #expect(metrics.completedWords == 4 && metrics.correctWords == 1)
        #expect(metrics.mistakes == 2)
    }

    @Test("Words mode finishes without a final space, while an incorrect last word can be submitted")
    func wordCompletion() {
        let correct = WordPracticeSession(goal: .words(2), seed: 1, words: ["cat"])
        correct.edit(range: 0..<0, replacement: "cat ", at: 0)
        #expect(!correct.isFinished)
        correct.edit(range: 4..<4, replacement: "cat", at: 5)
        #expect(correct.isFinished)
        #expect(correct.metrics(at: 500).completedWords == 2)
        #expect(correct.metrics(at: 500).wpm == 16.8)
        #expect(correct.samples.last?.wpm == correct.metrics(at: 500).wpm)
        let wrong = WordPracticeSession(goal: .words(2), seed: 1, words: ["cat"])
        wrong.edit(range: 0..<0, replacement: "cat ", at: 0)
        wrong.edit(range: 4..<4, replacement: "car", at: 4)
        #expect(!wrong.isFinished)
        wrong.edit(range: 7..<7, replacement: " ", at: 5)
        #expect(wrong.isFinished)
        #expect(wrong.metrics(at: 5).completedWords == 2 && wrong.metrics(at: 5).correctWords == 1)
    }

    @Test("A timed test supplies more words as the typist progresses, and retry reproduces the stream")
    func extendingAndRetrying() {
        let session = WordPracticeSession(goal: .time(120), seed: 321)
        let initial = session.targetWords
        let passage = initial.prefix(45).joined(separator: " ") + " "
        session.edit(range: 0..<0, replacement: passage, at: 10)
        #expect(session.targetWords.count == 100)
        #expect(Array(session.targetWords.prefix(50)) == initial)
        let retry = session.restarted()
        #expect(retry.targetWords == initial)
        #expect(retry.typedText.isEmpty && retry.startedAt == nil && retry.samples.isEmpty)
        retry.edit(range: 0..<0, replacement: passage, at: 20)
        #expect(retry.targetWords == session.targetWords)
    }

    @Test("Uniform speed has high consistency, and idle seconds reduce it")
    func consistency() {
        let session = WordPracticeSession(goal: .time(30), seed: 1, words: ["abcd"])
        for second in 0..<4 {
            let end = session.typedText.count
            session.edit(range: end..<end, replacement: "abcd ", at: Double(second))
        }
        session.advance(to: 4)
        #expect(session.metrics(at: 4).consistency == 100)
        session.advance(to: 8)
        #expect(session.metrics(at: 8).consistency == 0)
        #expect(session.samples.last?.seconds == 8)
    }

    @Test("Replacement edits use current positions without clearing attempt history")
    func selectionReplacement() {
        let session = WordPracticeSession(goal: .time(30), seed: 1, words: ["cat"])
        session.edit(range: 0..<0, replacement: "car cat", at: 0)
        session.edit(range: 2..<3, replacement: "t", at: 1)
        let metrics = session.metrics(at: 2)
        #expect(session.typedText == "cat cat")
        #expect(metrics.accuracy == 87.5)
        #expect(metrics.wpm == 42)
        #expect(!session.edit(range: 9..<10, replacement: "x", at: 2))
        #expect(!session.edit(range: 0..<0, replacement: "\n", at: 2))
    }

    @Test("Verified chord intermediates are correct attempts, while an ordinary wrong letter still counts")
    func chordIntermediates() {
        let chords = WordPracticeSession(goal: .time(30), seed: 1, words: ["making"])
        chords.edit(range: 0..<0, replacement: "make", at: 0, verifiedChordPreview: true)
        chords.edit(range: 3..<4, replacement: "ing", at: 1, verifiedChordPreview: true)
        #expect(chords.typedText == "making")
        #expect(chords.metrics(at: 2).accuracy == 100 && chords.metrics(at: 2).mistakes == 0)
        let keyboard = WordPracticeSession(goal: .time(30), seed: 1, words: ["making"])
        keyboard.edit(range: 0..<0, replacement: "make", at: 0)
        #expect(keyboard.metrics(at: 1).mistakes == 1)
    }

    @Test("Floating point seconds do not turn an even typing rhythm into a zero consistency score")
    func fractionalSecondBoundaries() {
        let session = WordPracticeSession(goal: .words(10), seed: 1, words: ["abcd"])
        let text = session.targetWords.joined(separator: " ")
        var now = 100.0
        for char in text {
            let end = session.typedText.count
            session.edit(range: end..<end, replacement: String(char), at: now)
            now += 0.2
        }
        #expect(session.isFinished)
        #expect(session.metrics(at: now).consistency > 80)
    }
}
