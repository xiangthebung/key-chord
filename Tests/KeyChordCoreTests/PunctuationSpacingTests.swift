import Testing
@testable import KeyChordCore

@Suite("Punctuation spacing")
struct PunctuationSpacingTests {
    @Test("Either quote chord closes quoted text without a leading space",
          arguments: ["Quote+LBracket", "Quote+RBracket"])
    func closingQuote(_ closing: String) throws {
        let d = Driver()
        try d.chords(THE, "Quote+LBracket", CAT, closing, THE)
        #expect(d.text == "the \"cat\" the")
    }

    @Test("Closing a quote after sentence punctuation keeps the next word's capital")
    func closingQuoteAfterPunctuation() throws {
        let d = Driver()
        try d.chords("Quote+LBracket", CAT, "Period", "Quote+LBracket", THE)
        #expect(d.text == "\"cat.\" The")
    }

    @Test("Opening quotes keep the word gap, and repeated quotes can form an empty pair")
    func openingQuotes() throws {
        let d = Driver()
        try d.chords(THE, "Quote+LBracket", "Quote+LBracket", CAT,
                     "Quote+LBracket", THE, "Quote+RBracket")
        #expect(d.text == "the \"\" cat \"the\"")
    }

    @Test("Undo and context restoration preserve whether a quote is open")
    func quoteContext() throws {
        let d = Driver()
        try d.chords("Quote+LBracket", CAT)
        let open = d.engine.currentContext
        try d.chords("Quote+LBracket", UNDO, "Quote+LBracket", THE)
        #expect(d.text == "\"cat\" the")
        let restored = Driver()
        restored.buffer = TextBuffer("\"cat")
        restored.engine.restore(open)
        #expect(try restored.chord("Quote+LBracket").actions == [.insert("\"")])
        #expect(restored.text == "\"cat\"")

        d.engine.contextReset()
        try d.chords("Quote+LBracket", CAT, "Quote+LBracket")
        #expect(d.text.hasSuffix("\"cat\""))
    }

    @Test("C++ calls and subscripts attach after closing delimiters",
          arguments: ["RBracket", "RBracket+P", "Period+RBracket"])
    func cppChainedDelimiters(_ closing: String) throws {
        let d = Driver(.cpp)
        let opening = closing == "RBracket" ? "LBracket" : closing == "RBracket+P" ? "LBracket+P" : "Comma+LBracket"
        try d.chords(GET, opening, THE, closing, "LBracket", CAT, "RBracket", "LBracket+P", "1", "RBracket+P")
        let opener = closing == "RBracket" ? "(" : closing == "RBracket+P" ? "[" : "<"
        let delimiter = closing == "RBracket" ? ")" : closing == "RBracket+P" ? "]" : ">"
        #expect(d.text == "get" + opener + "the" + delimiter + "(cat)[1]")
    }

    @Test("A call after exiting a snippet attaches to its closing delimiter")
    func cppSnippetDelimiters() throws {
        let d = Driver(.cpp)
        try d.chords("Quote+V+C", "Quote+I+N", EXIT, "LBracket", "1", "RBracket", "LBracket+P", "1", "RBracket+P")
        #expect(d.text == "std::vector<int>(1)[1]")
    }

    @Test("Comparison operators keep their space before a grouped expression")
    func cppComparisonSpacing() throws {
        let d = Driver(.cpp)
        try d.chords(THE, "Quote+Period", "LBracket", CAT, "RBracket")
        #expect(d.text == "the > (cat)")
    }

    @Test("Literal whitespace prevents an extra automatic space on either side",
          arguments: [" ", "\t", "\n"])
    func literalWhitespace(_ whitespace: String) throws {
        var data = defaults
        data.english.entries[keys("Quote+Z+X")] = .text(TextEntry(text: "hello" + whitespace))
        data.english.entries[keys("Quote+Z+Y")] = .text(TextEntry(text: whitespace + "hello"))
        let trailing = Driver(data: data)
        try trailing.chords("Quote+Z+X", "Quote+LBracket", CAT, "Quote+RBracket", THE)
        #expect(trailing.text == "hello" + whitespace + "\"cat\" the")
        let leading = Driver(data: data)
        try leading.chords(THE, "Quote+Z+Y", CAT)
        #expect(leading.text == "the" + whitespace + "hello cat")
    }
}
