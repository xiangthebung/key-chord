import Testing
@testable import KeyChordCore

@Suite("Automatic practice language")
struct PracticeLanguageTests {
    @Test func recognizesCodeFiles() {
        for name in ["lesson.cpp", "HEADER.HPP", "sample.cxx", "main.cc", "math.h"] {
            #expect(PracticeLanguage.detect("// a comment", fileName: name) == .cpp)
        }
    }

    @Test func recognizesPastedCode() {
        for text in ["int main() { return 0; }", "std::vector<int> values;", "#include <iostream>",
                     "int count = 0;", "if (count == 2) { return count; }"] {
            #expect(PracticeLanguage.detect(text, fileName: "practice.txt") == .cpp)
        }
    }

    @Test func keepsEnglishInEnglish() {
        for text in ["", "If we return early, we can go home.", "The word int is a keyword.",
                     "Auto repair is useful; we know that.", "Use {braces} in your notes; if needed."] {
            #expect(PracticeLanguage.detect(text) == .english)
        }
    }
}
