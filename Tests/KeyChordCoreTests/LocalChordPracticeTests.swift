import Testing
@testable import KeyChordCore

private func ownedLocalPractice() -> LocalChordPractice {
    let practice = LocalChordPractice(data: defaults)
    practice.setFocus(true, globalCaptureSuspended: true)
    return practice
}

@discardableResult
private func releaseChord(_ spec: String, in practice: LocalChordPractice, flags: ModifierFlags = []) -> LocalChordOutput {
    let chord = keys(spec)
    for index in chord.indices {
        _ = practice.handle(.keyDown(code: defaults.layout.keys[index].code, isRepeat: false, flags: flags, time: 1))
    }
    var output = LocalChordOutput(routed: RouterOutput(decision: .pass))
    for index in chord.indices {
        output = practice.handle(.keyUp(code: defaults.layout.keys[index].code, flags: flags, time: 2))
    }
    return output
}

@Test func localCompositionRequiresBothFocusAndExclusiveCapture() {
    let practice = LocalChordPractice(data: defaults)
    #expect(releaseChord("S+C+J", in: practice).routed.actions.isEmpty)
    practice.setFocus(true, globalCaptureSuspended: false)
    #expect(releaseChord("S+C+J", in: practice).routed.decision == .pass)
    #expect(!practice.ownsInput)
    practice.setFocus(true, globalCaptureSuspended: true)
    #expect(releaseChord("S+C+J", in: practice).attempt?.insertedText == "sat")
}

@Test func localChordCommitsOnlyAfterEveryCapturedKeyIsUp() {
    let practice = ownedLocalPractice()
    for code: KeyCode in [1, 8, 38] {
        let down = practice.handle(.keyDown(code: code, isRepeat: false, flags: [], time: 0))
        #expect(down.routed.decision == .suppress)
        #expect(down.routed.actions.isEmpty)
    }
    #expect(practice.heldKeys == keys("S+C+J"))
    #expect(practice.handle(.keyDown(code: 8, isRepeat: true, flags: [], time: 1)).attempt == nil)
    #expect(practice.handle(.keyUp(code: 1, flags: [], time: 2)).attempt == nil)
    #expect(practice.heldKeys == keys("C+J"))
    #expect(practice.handle(.keyUp(code: 38, flags: [], time: 2)).routed.actions.isEmpty)
    let complete = practice.handle(.keyUp(code: 8, flags: [], time: 3))
    #expect(complete.routed.actions == [.insert("sat")])
    #expect(complete.attempt?.keys == keys("S+C+J"))
    #expect(practice.heldKeys.isEmpty)
    #expect(practice.handle(.keyUp(code: 8, flags: [], time: 4)).attempt == nil)
}

@Test func localFocusLossAndCaptureCollisionAbandonPendingOutput() {
    for losesFocus in [true, false] {
        let practice = ownedLocalPractice()
        _ = practice.handle(.keyDown(code: 1, isRepeat: false, flags: [], time: 1))
        _ = practice.handle(.keyDown(code: 8, isRepeat: false, flags: [], time: 1))
        practice.setFocus(!losesFocus, globalCaptureSuspended: false)
        #expect(practice.heldKeys.isEmpty)
        #expect(practice.undoDepth == 0)
        let abandoned = practice.handle(.keyUp(code: 8, flags: [], time: 2))
        #expect(abandoned.routed.actions.isEmpty)
        #expect(abandoned.attempt == nil)
        practice.setFocus(true, globalCaptureSuspended: true)
        #expect(practice.handle(.keyUp(code: 1, flags: [], time: 3)).attempt == nil)
        #expect(releaseChord("E+C+J", in: practice).attempt?.insertedText == "hat")
    }
}

@Test func localNormalModeAndShortcutsPreserveOrdinaryEditing() {
    let practice = ownedLocalPractice()
    _ = practice.handle(.modifierDown(code: 61, key: .option, time: 1))
    _ = practice.handle(.modifierUp(code: 61, key: .option, time: 100))
    #expect(!practice.chordEnabled)
    #expect(releaseChord("S+C+J", in: practice).routed.decision == .pass)
    practice.setChordEnabled(true)
    _ = releaseChord("S+C+J", in: practice)
    #expect(practice.undoDepth == 1)
    let paste = practice.handle(.keyDown(code: 9, isRepeat: false, flags: .command, time: 200))
    #expect(paste.routed.decision == .pass)
    #expect(paste.attempt == nil)
    #expect(practice.undoDepth == 0)
    #expect(releaseChord("Backslash", in: practice).attempt?.signal == .undoEmpty)
    _ = releaseChord("E+C+J", in: practice)
    practice.ordinaryEdit() // Delete, selection replacement, native Undo, or cursor movement.
    #expect(practice.undoDepth == 0)
    #expect(releaseChord("S+C+J", in: practice).attempt?.insertedText == "sat")
}

@Test func localUnknownKeyCancelsChordAndCapsLockUsesEngineSemantics() {
    let practice = ownedLocalPractice()
    _ = practice.handle(.keyDown(code: 1, isRepeat: false, flags: [], time: 1))
    let arrow = practice.handle(.keyDown(code: 123, isRepeat: false, flags: [], time: 2))
    #expect(arrow.routed.decision == .pass)
    #expect(practice.heldKeys.isEmpty)
    #expect(practice.handle(.keyUp(code: 1, flags: [], time: 3)).attempt == nil)
    #expect(releaseChord("S+C+J", in: practice, flags: .capsLock).attempt?.insertedText == "SAT")
}

@Test func localShiftPressedDuringChordJoinsExactlyLikeGlobalEngine() {
    let practice = ownedLocalPractice()
    _ = releaseChord("S+C+J", in: practice)
    for code: KeyCode in [14, 8, 38] {
        _ = practice.handle(.keyDown(code: code, isRepeat: false, flags: [], time: 1))
    }
    _ = practice.handle(.modifierDown(code: 56, key: .shift, time: 2))
    var output: LocalChordOutput?
    for code: KeyCode in [14, 8, 38] {
        output = practice.handle(.keyUp(code: code, flags: .shift, time: 3))
    }
    #expect(output?.routed.actions == [.insert("hat")])
    #expect(output?.attempt?.keys == keys("E+C+J"))
}

@Test func localRejectedModeSwitchCanResumeEnglishWithRightOption() {
    let practice = ownedLocalPractice()
    let rejected = releaseChord("LBracket+RBracket", in: practice)
    #expect(rejected.routed.actions.isEmpty)
    #expect(rejected.routed.events == [.modeChanged(.normal)])
    #expect(!practice.chordEnabled)
    _ = practice.handle(.modifierDown(code: 61, key: .option, time: 10))
    let resumed = practice.handle(.modifierUp(code: 61, key: .option, time: 100))
    #expect(resumed.routed.events == [.modeChanged(.chord(.english))])
    #expect(practice.chordEnabled)
    #expect(releaseChord("S+C+J", in: practice).routed.actions == [.insert("sat")])
}

@Test func localCppLessonsRetainTheirLanguageAcrossFocusAndRightOption() {
    let practice = LocalChordPractice(data: defaults, mode: .cpp)
    practice.setFocus(true, globalCaptureSuspended: true)
    let lesson = Course.steps.first { $0.mode == .cpp }!
    let guide = TypingPlanner(data: defaults, mode: .cpp).plan(lesson.text)
    guard case .chord(let names, _) = guide.steps[0].action else { Issue.record("expected a C++ chord"); return }
    #expect(!releaseChord(names.joined(separator: "+"), in: practice).routed.actions.isEmpty)
    practice.setFocus(false, globalCaptureSuspended: false)
    practice.setFocus(true, globalCaptureSuspended: true)
    #expect(practice.chordEnabled)
    _ = practice.handle(.modifierDown(code: 61, key: .option, time: 10))
    _ = practice.handle(.modifierUp(code: 61, key: .option, time: 100))
    #expect(!practice.chordEnabled)
    _ = practice.handle(.modifierDown(code: 61, key: .option, time: 110))
    let resumed = practice.handle(.modifierUp(code: 61, key: .option, time: 200))
    #expect(resumed.routed.events == [.modeChanged(.chord(.cpp))])
    practice.setMode(.english)
    #expect(releaseChord("S+C+J", in: practice).attempt?.insertedText == "sat")
}

@Test func localEvidenceReportsOnlyCapturedDifferences() throws {
    let output = releaseChord("S+C", in: ownedLocalPractice())
    let evidence = try #require(output.attempt)
    let difference = evidence.capturedDifference(from: keys("S+C+J"))
    #expect(difference.notCaptured == keys("J"))
    #expect(difference.extraCaptured.isEmpty)
    #expect(evidence.insertedText == "sa")
    // An incomplete capture is evidence of sa; it is not a stored hardware diagnosis.
}

@Test func onboardingRecipesReplayCurrentMappingAndRespectLimits() throws {
    let expected = ["sat": "S+C+J", "hat": "E+C+J", "tan": "T+C+H"]
    for word in FirstChordJourney.words {
        let recipe = try #require(FirstChordRecipe(word: word, data: defaults))
        #expect(recipe.keys == keys(expected[word]!))
        #expect(recipe.parts.map(\.role) == [.onset, .vowel, .coda])
        let result = try ChordEngine(data: defaults).translate(recipe.keys, join: recipe.shift)
        #expect(result.actions == [.insert(word)])
        #expect(FirstChordRecipe(word: word, data: defaults, rolloverLimit: 2) == nil)
        #expect(FirstChordRecipe(word: word, data: defaults, usable: { _ in false }) == nil)
    }
}

@Test func onboardingRequiresActualUndoAndChordEvidenceBeforeRecall() {
    var journey = FirstChordJourney()
    let practice = ownedLocalPractice()
    let sat = releaseChord("S+C+J", in: practice).attempt!
    var advanced = journey.observe(sat, resultingText: "sat")
    #expect(!advanced) // See is instructional only.
    journey.startTrying()
    let ordinary = LocalChordAttempt(keys: KeySet(), actions: [], signal: nil, wasUndo: false)
    advanced = journey.observe(ordinary, resultingText: "sat")
    #expect(!advanced)
    advanced = journey.observe(sat, resultingText: "sat pasted suffix")
    #expect(!advanced)
    advanced = journey.observe(sat, resultingText: "sat")
    #expect(advanced)
    practice.reset()
    advanced = journey.observe(releaseChord("E+C+J", in: practice).attempt!, resultingText: "hat")
    #expect(advanced)
    practice.reset()
    advanced = journey.observe(releaseChord("T+C+H", in: practice).attempt!, resultingText: "tan")
    #expect(advanced)
    #expect(journey.stage == .recover)
    practice.reset()
    advanced = journey.observe(releaseChord("E+C+J", in: practice).attempt!, resultingText: "hat")
    #expect(advanced)
    #expect(journey.recovery == .undoMistake)
    let deletion = LocalChordAttempt(keys: KeySet(), actions: [.deleteBackward(3)], signal: nil, wasUndo: false)
    advanced = journey.observe(deletion, resultingText: "")
    #expect(!advanced)
    let undo = releaseChord("Backslash", in: practice).attempt!
    #expect(undo.wasUndo)
    #expect(undo.actions == [.deleteBackward(3)])
    advanced = journey.observe(undo, resultingText: "")
    #expect(advanced)
    #expect(journey.recovery == .repair)
    advanced = journey.observe(releaseChord("S+C+J", in: practice).attempt!, resultingText: "sat")
    #expect(advanced)
    #expect(journey.stage == .recall)
    journey.revealHint()
    for spec in ["T+C+H", "S+C+J", "E+C+J"] {
        let target = journey.target!
        practice.reset()
        advanced = journey.observe(releaseChord(spec, in: practice).attempt!, resultingText: target)
        #expect(advanced)
    }
    #expect(journey.stage == .finished)
    #expect(journey.recallUsedHint)
}

@Test func onboardingSkipResumeAndLegacyLaunchAreConservative() {
    #expect(OnboardingLaunch.decide(savedStage: nil, dismissed: false, legacyInstallation: false) == .begin)
    #expect(OnboardingLaunch.decide(savedStage: nil, dismissed: false, legacyInstallation: true) == .skip)
    #expect(OnboardingLaunch.decide(savedStage: .recover, dismissed: false, legacyInstallation: false) == .resume(.recover))
    #expect(OnboardingLaunch.decide(savedStage: .finished, dismissed: false, legacyInstallation: false) == .skip)
    #expect(OnboardingLaunch.decide(savedStage: .recall, dismissed: true, legacyInstallation: false) == .skip)
}
