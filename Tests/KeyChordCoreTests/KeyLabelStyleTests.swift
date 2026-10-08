import Testing
@testable import KeyChordCore

@Suite("Key label preferences")
struct KeyLabelStyleTests {
    let meanings = KeyMeanings(data: defaults, mode: .english)

    @Test("Sounds stay consistent inside chords even when a key alone produces an ending")
    func soundsAndActions() {
        #expect(meanings.label(for: 14, physical: "E", style: .meaning) == "h")
        #expect(meanings.label(for: 8, physical: "C", style: .meaning) == "a")
        #expect(meanings.keys[32]?.alone == "-er")
        #expect(meanings.label(for: 32, physical: "U", style: .meaning) == "r")
        #expect(meanings.label(for: 49, physical: "Space", style: .meaning) == "join")
        #expect(meanings.label(for: 56, physical: "⇧", style: .meaning) == "join")
    }

    @Test("Printed labels follow the selected keyboard, including ISO punctuation positions")
    func physicalKeyboard() {
        #expect(meanings.label(for: 44, physical: "/", style: .physical) == "/")
        #expect(meanings.label(for: 44, physical: "É", style: .physical) == "É")
        #expect(meanings.label(for: 44, physical: "É", style: .both) == "É (e)")
        #expect(meanings.label(for: 14, physical: "E", style: .both) == "E (h)")
    }

    @Test("Numbers and keys without chord meanings do not gain redundant labels")
    func unchangedLabels() {
        #expect(meanings.label(for: 18, physical: "1", style: .both) == "1")
        for style in KeyLabelStyle.allCases {
            #expect(meanings.label(for: 126, physical: "↑", style: style) == "↑")
        }
    }
}
