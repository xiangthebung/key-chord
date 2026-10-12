import Foundation
import Testing
@testable import KeyChordCore

private func custom(_ spec: String, text: String = "hello", id: String = "one",
                    scope: CustomChordScope = .english, spacing: CustomChordSpacing = .words) -> CustomChord {
    CustomChord(id: id, keyCodes: keys(spec).indices.map { defaults.layout.keys[$0].code },
                text: text, scope: scope, spacing: spacing)
}

@Suite("Custom chords") struct CustomChordTests {
    @Test func overrideAndRemovalRestoreTheInstalledMapping() throws {
        let chord = custom("S+C+J", text: "a phrase")
        let edited = CustomChords.applying([chord], to: defaults)
        let english = Driver(.english, data: edited)
        try english.chord("S+C+J")
        #expect(english.buffer.text == "a phrase")
        let cpp = Driver(.cpp, data: edited)
        try cpp.chord("S+C+J")
        #expect(cpp.buffer.text == "sat")
        let restored = Driver(data: CustomChords.applying([], to: defaults))
        try restored.chord("S+C+J")
        #expect(restored.buffer.text == "sat")
    }

    @Test func bothLanguagesOverrideTheirOwnEntriesBeforeSharedEntries() throws {
        let chord = custom("Period", text: "Thanks!", scope: .both)
        let data = CustomChords.applying([chord], to: defaults)
        for mode in SubMode.allCases {
            let driver = Driver(mode, data: data)
            try driver.chord("Period")
            #expect(driver.buffer.text == "Thanks!")
        }
        #expect(data.shared.entries == defaults.shared.entries)
    }

    @Test func separateLanguageChordsCanUseTheSameKeys() throws {
        let english = custom("S+C+J", text: "hello", id: "english")
        let cpp = custom("S+C+J", text: "return", id: "cpp", scope: .cpp)
        #expect(CustomChords.issue(for: english, among: [cpp], base: defaults) == nil)
        let data = CustomChords.applying([english, cpp], to: defaults)
        #expect(data.english[keys("S+C+J")] == .text(english.entry))
        #expect(data.cpp[keys("S+C+J")] == .text(cpp.entry))
        let both = custom("S+C+J", id: "both", scope: .both)
        #expect(CustomChords.issue(for: both, among: [english], base: defaults) == .duplicate)
    }

    @Test func wordSpacingAndExactTextUseTheRealEngine() throws {
        for spacing in CustomChordSpacing.allCases {
            let chord = custom("S+C+J", text: "Hello", spacing: spacing)
            let driver = Driver(data: CustomChords.applying([chord], to: defaults))
            try driver.chord("S+C+J")
            try driver.chord("S+C+J")
            #expect(driver.buffer.text == (spacing == .words ? "Hello Hello" : "HelloHello"))
        }
        let literal = "quoted \"text\"\\path\n你好 | cursor # comment"
        let driver = Driver(data: CustomChords.applying([custom("S+C+J", text: literal, spacing: .exact)], to: defaults))
        try driver.chord("S+C+J")
        #expect(driver.buffer.text == literal)
    }

    @Test func actionsAndSpaceAreProtected() {
        for spec in ["Backslash", "LBracket+RBracket", "N+M"] {
            #expect(CustomChords.issue(for: custom(spec, scope: .both), among: [], base: defaults) == .reservedCommand)
        }
        for spec in ["Space", "S+Space"] {
            #expect(CustomChords.issue(for: custom(spec), among: [], base: defaults) == .space)
        }
    }

    @Test func incompleteAndUnsupportedChordsCannotShadowWorkingKeys() {
        let empty = CustomChord(id: "empty", keyCodes: [], text: "hello")
        #expect(CustomChords.issue(for: empty, among: [], base: defaults) == .missingKeys)
        let option = CustomChord(id: "option", keyCodes: [61], text: "hello")
        #expect(CustomChords.issue(for: option, among: [], base: defaults) == .unknownKeys)
        let blank = custom("S+C+J", text: " \n\t")
        #expect(CustomChords.issue(for: blank, among: [], base: defaults) == .missingText)
        let chord = custom("S+C+J")
        #expect(CustomChords.issue(for: chord, among: [], base: defaults, rolloverLimit: 2) == .tooManyKeys(2))
        #expect(CustomChords.issue(for: chord, among: [], base: defaults, usable: { _ in false }) == .blocked)
        let data = CustomChords.applying([blank, option], to: defaults)
        #expect(data.english.entries == defaults.english.entries)
    }

    @Test func duplicateSavedIdentitiesAndScopesAreInactive() {
        let first = custom("S+C+J")
        let second = custom("E+C+J")
        #expect(CustomChords.issue(for: first, among: [second], base: defaults) == .identity)
        let duplicate = custom("S+C+J", id: "two")
        let data = CustomChords.applying([first, duplicate], to: defaults)
        #expect(data.english.entries == defaults.english.entries)
    }

    @Test func localRefreshKeepsInputModeAndDiscardsIncompleteChords() {
        let practice = LocalChordPractice(data: defaults)
        practice.setFocus(true, globalCaptureSuspended: true)
        _ = practice.handle(.keyDown(code: 1, isRepeat: false, flags: [], time: 0))
        practice.replaceData(CustomChords.applying([custom("S+C+J")], to: defaults))
        #expect(practice.chordEnabled)
        #expect(practice.heldKeys.isEmpty)
        #expect(practice.handle(.keyUp(code: 1, flags: [], time: 1)).routed.actions.isEmpty)
        for code: KeyCode in [1, 8, 38] { _ = practice.handle(.keyDown(code: code, isRepeat: false, flags: [], time: 2)) }
        var output: LocalChordOutput?
        for code: KeyCode in [1, 8, 38] { output = practice.handle(.keyUp(code: code, flags: [], time: 3)) }
        #expect(output?.routed.actions == [.insert("hello")])
        practice.setChordEnabled(false)
        practice.replaceData(defaults)
        #expect(!practice.chordEnabled)
    }

    @Test func disablingRestoresOriginalAndReenablingChecksActiveAssignments() throws {
        var paused = custom("S+C+J", scope: .both)
        paused.isEnabled = false
        let restored = Driver(data: CustomChords.applying([paused], to: defaults))
        try restored.chord("S+C+J")
        #expect(restored.text == "sat")
        let active = custom("S+C+J", text: "new", id: "two")
        #expect(CustomChords.issue(for: active, among: [paused], base: defaults) == nil)
        let driver = Driver(data: CustomChords.applying([paused, active], to: defaults))
        try driver.chord("S+C+J")
        #expect(driver.text == "new")
        paused.isEnabled = true
        #expect(CustomChords.issue(for: paused, among: [active], base: defaults) == .duplicate)
        let reenabled = Driver(data: CustomChords.applying([paused], to: defaults))
        try reenabled.chord("S+C+J")
        #expect(reenabled.text == "hello")
    }

    @Test func legacyCustomizationsLoadEnabledAndPausedChordsRoundTrip() throws {
        let legacy = #"{"id":"legacy","keyCodes":[1,8,38],"text":"hello","scope":"english","spacing":"exact"}"#
        let chord = try JSONDecoder().decode(CustomChord.self, from: Data(legacy.utf8))
        #expect(chord.isEnabled && chord.spacing == .exact)
        var paused = chord; paused.isEnabled = false
        let roundTrip = try JSONDecoder().decode(CustomChord.self, from: JSONEncoder().encode(paused))
        #expect(roundTrip == paused && !roundTrip.isEnabled)
    }

    @Test func unusedSuggestionsDoNotStealGeneratedChordsOrActionsInEitherLanguage() throws {
        let limits = macBookLimits.usable(in: defaults.layout)
        let options = CustomChords.suggestions(scope: .both, among: [], base: defaults, usable: limits)
        #expect(options.count == 3 && Set(options).count == 3)
        for keys in options {
            #expect(keys.count <= 3 && !keys.contains(defaults.layout.spaceIndex!))
            #expect(limits(keys))
            for mode in SubMode.allCases {
                let original = ChordEngine(data: defaults, subMode: mode)
                #expect(try original.translate(keys, join: false).signal == .untranslatable)
            }
        }
        let shorter = CustomChords.suggestions(scope: .both, among: [], base: defaults, rolloverLimit: 1)
        #expect(shorter.allSatisfy { $0.count == 1 })
        #expect(options == CustomChords.suggestions(scope: .both, among: [], base: defaults, usable: limits))
    }

    @Test func suggestionsRespectScopesActiveCustomizationsExclusionsAndLimits() throws {
        let chosen = try #require(CustomChords.suggestions(scope: .both, among: [], base: defaults, limit: 1).first)
        let active = CustomChord(id: "active", keyCodes: chosen.indices.map { defaults.layout.keys[$0].code }, text: "hello")
        #expect(!CustomChords.suggestions(scope: .english, among: [active], base: defaults, limit: 50).contains(chosen))
        #expect(CustomChords.suggestions(scope: .cpp, among: [active], base: defaults, limit: 50).contains(chosen))
        var paused = active; paused.isEnabled = false
        #expect(CustomChords.suggestions(scope: .both, among: [paused], base: defaults, limit: 1) == [chosen])
        #expect(!CustomChords.suggestions(scope: .english, among: [], base: defaults, excluding: [chosen], limit: 50).contains(chosen))
        #expect(CustomChords.suggestions(scope: .english, among: [], base: defaults, usable: { _ in false }).isEmpty)
        #expect(CustomChords.suggestions(scope: .english, among: [], base: defaults, rolloverLimit: 0).isEmpty)
        #expect(CustomChords.suggestions(scope: .english, among: [], base: defaults, limit: 0).isEmpty)
        var cppOnly = defaults
        cppOnly.cpp.entries[chosen] = .text(TextEntry(text: "taken in C++"))
        #expect(CustomChords.suggestions(scope: .english, among: [], base: cppOnly, limit: 50).contains(chosen))
        #expect(!CustomChords.suggestions(scope: .both, among: [], base: cppOnly, limit: 50).contains(chosen))
    }

    @Test func noAddedSpacesKeepsCapsLockBehavior() throws {
        let driver = Driver(data: CustomChords.applying([custom("S+C+J", text: "Hello", spacing: .exact)], to: defaults))
        try driver.chord("S+C+J")
        try driver.chord("S+C+J", capsLock: true)
        #expect(driver.text == "HelloHELLO")
    }
}
