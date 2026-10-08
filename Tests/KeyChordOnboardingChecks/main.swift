// Uses real NSTextView editing and local event values. Never displays a window, installs a global
// event tap, accesses the system pasteboard, requests Accessibility, or posts synthetic system keys.
import AppKit
import KeyChordCore

NSApplication.shared.setActivationPolicy(.prohibited)
let outcome = DictionaryLoader.load(sources: Dictionary(uniqueKeysWithValues: DataFile.allCases.map {
    ($0, Optional($0.defaultSource))
}), rolloverLimit: 6)
precondition(outcome.problems.isEmpty)
let data = outcome.data
let suite = "KeyChordOnboardingChecks." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

let store = LearningJourneyStore(defaults: defaults)
precondition(store.launch == .begin)
precondition(!store.permitsGlobalTyping)
store.save(stage: .recall)
precondition(LearningJourneyStore(defaults: defaults, hasExistingDataFiles: true).launch == .resume(.recall))
store.dismiss()
precondition(LearningJourneyStore(defaults: defaults).launch == .skip)
store.chooseOtherApps()
store.reportEditorPractice()
precondition(store.permitsGlobalTyping && store.editorPracticeReported)
let allowed = Set(["initialized", "legacy", "stage", "dismissed", "otherAppsChosen", "editorPracticeReported"])
let persisted = defaults.persistentDomain(forName: suite)!
precondition(Set(persisted.keys) == Set(allowed.map { "learningJourney.v1." + $0 }))
precondition(persisted["learningJourney.v1.stage"] as? String == "recall")

for legacyEvidence in ["courseCompleted", "lastSubMode", "existingFiles"] {
    let legacySuite = suite + "." + legacyEvidence
    let legacyDefaults = UserDefaults(suiteName: legacySuite)!
    if legacyEvidence == "courseCompleted" { legacyDefaults.set(["first-chord"], forKey: legacyEvidence) }
    if legacyEvidence == "lastSubMode" { legacyDefaults.set("cpp", forKey: legacyEvidence) }
    let legacy = LearningJourneyStore(defaults: legacyDefaults, hasExistingDataFiles: legacyEvidence == "existingFiles")
    precondition(legacy.launch == .skip && legacy.permitsGlobalTyping)
    legacyDefaults.removePersistentDomain(forName: legacySuite)
}

var focused = true
var globalSuspended = true
let input = LocalChordInputView(data: data, focus: { focused }, globalSuspended: { globalSuspended })
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.documentView = input
window.contentView!.addSubview(scroll)
input.refreshFocus()
var attempts = 0
input.onOutput = { if $0.attempt != nil { attempts += 1 } }

@discardableResult
func chord(_ names: [String], flags: ModifierFlags = []) -> LocalChordOutput {
    let keys = data.layout.keySet(names: names)!
    for index in keys.indices {
        _ = input.process(.keyDown(code: data.layout.keys[index].code, isRepeat: false, flags: flags, time: 1))
    }
    var output = LocalChordOutput(routed: RouterOutput(decision: .pass))
    for index in keys.indices {
        output = input.process(.keyUp(code: data.layout.keys[index].code, flags: flags, time: 2))
    }
    return output
}

_ = input.process(.keyDown(code: 1, isRepeat: false, flags: [], time: 0))
_ = input.process(.keyDown(code: 8, isRepeat: false, flags: [], time: 0))
_ = input.process(.keyDown(code: 38, isRepeat: false, flags: [], time: 0))
_ = input.process(.keyUp(code: 1, flags: [], time: 1))
precondition(input.string.isEmpty && attempts == 0)
_ = input.process(.keyUp(code: 38, flags: [], time: 1))
precondition(input.string.isEmpty && input.practice.heldKeys.count == 1)
_ = input.process(.keyUp(code: 8, flags: [], time: 2))
precondition(input.string == "sat" && attempts == 1,
             "Released sat: text=" + input.string + "; attempts=" + String(attempts)
                + "; owns=" + String(input.practice.ownsInput)
                + "; storage=" + String(input.textStorage != nil))
precondition(input.practice.undoDepth == 1)
_ = chord(["Backslash"])
precondition(input.string.isEmpty && attempts == 2)
_ = chord(["E", "C", "J"])
precondition(input.string == "hat")
input.deleteBackward(nil)
precondition(input.string == "ha" && input.practice.undoDepth == 0,
             "Ordinary Delete: text=" + input.string + "; undoDepth=" + String(input.practice.undoDepth))
input.clearForTask()

// Command-V is passed to NSTextView. InsertText exercises its ordinary insertion path without
// taking or changing the user's pasteboard. Matching ordinary text never creates an attempt.
let beforePaste = attempts
precondition(input.process(.keyDown(code: 9, isRepeat: false, flags: .command, time: 3)).routed.decision == .pass)
input.insertText("sat", replacementRange: NSRange(location: 0, length: 0))
precondition(input.string == "sat" && attempts == beforePaste && input.practice.undoDepth == 0)
input.setSelectedRange(NSRange(location: 0, length: 3))
input.insertText("hat", replacementRange: input.selectedRange())
precondition(input.string == "hat" && attempts == beforePaste && input.practice.undoDepth == 0)
input.clearForTask()
_ = chord(["S", "C", "J"])
input.setSelectedRange(NSRange(location: 1, length: 0))
precondition(input.practice.undoDepth == 0)
input.insertText("x", replacementRange: input.selectedRange())
precondition(input.string == "sxat")

input.clearForTask()
_ = input.process(.keyDown(code: 1, isRepeat: false, flags: [], time: 0))
focused = false
input.refreshFocus()
precondition(input.process(.keyUp(code: 1, flags: [], time: 1)).routed.actions.isEmpty)
precondition(input.string.isEmpty)
focused = true
globalSuspended = false
input.refreshFocus()
let beforeCollision = attempts
_ = chord(["S", "C", "J"])
precondition(input.string.isEmpty && attempts == beforeCollision)
globalSuspended = true
input.refreshFocus()
_ = chord(["S", "C", "J"], flags: .capsLock)
precondition(input.string == "SAT")

// The local lesson rejects C++ mode without leaving right Option stuck toggling C++ forever.
input.clearForTask()
let rejectedSwitch = chord(["LBracket", "RBracket"])
precondition(input.string.isEmpty && rejectedSwitch.routed.events == [.modeChanged(.normal)])
precondition(!input.practice.chordEnabled)
_ = input.process(.modifierDown(code: 61, key: .option, time: 10))
let resumedEnglish = input.process(.modifierUp(code: 61, key: .option, time: 100))
precondition(resumedEnglish.routed.events == [.modeChanged(.chord(.english))] && input.practice.chordEnabled)
_ = chord(["S", "C", "J"])
precondition(input.string == "sat")

// The actual recovery controller must rearm the task after focus loss clears its Undo context.
let recoveryStore = LearningJourneyStore(defaults: defaults)

// The demonstration has one primary action and produces text only after the final release.
// It cannot accept local physical attempts until Try begins, and demo output is cleared first.
let demonstration = FirstChordWindowController(data: data, store: recoveryStore, focus: { true })
let demoPrimary = Mirror(reflecting: demonstration).children.first { $0.label == "start" }!.value as! PracticeActionButton
precondition(!demonstration.input.isEditable && demonstration.input.string.isEmpty)
for phaseIndex in 0..<(KeyChordPresentation.firstChordDemonstrationCount - 1) {
    let phase = KeyChordPresentation.firstChordDemonstration(step: phaseIndex)
    precondition(demoPrimary.title == phase.primaryAction)
    demoPrimary.performClick(nil)
    let nextPhase = KeyChordPresentation.firstChordDemonstration(step: phaseIndex + 1)
    precondition(demonstration.input.string == (nextPhase.output ?? ""))
    precondition(!demonstration.input.isEditable)
}
precondition(demoPrimary.title == KeyChordPresentation.firstChordDemonstration(step: KeyChordPresentation.firstChordDemonstrationCount - 1).primaryAction)
demoPrimary.performClick(nil)
let demoJourney = Mirror(reflecting: demonstration).children.first { $0.label == "journey" }!.value as! FirstChordJourney
precondition(demoJourney.stage == .tryIt && demonstration.input.isEditable && demonstration.input.string.isEmpty)

var recoveryFocused = true
let recovery = FirstChordWindowController(data: data, store: recoveryStore, stage: .recover,
                                           focus: { recoveryFocused })
func journey() -> FirstChordJourney {
    Mirror(reflecting: recovery).children.first { $0.label == "journey" }!.value as! FirstChordJourney
}
func recoveryChord(_ names: [String]) {
    let keys = data.layout.keySet(names: names)!
    for index in keys.indices {
        _ = recovery.input.process(.keyDown(code: data.layout.keys[index].code, isRepeat: false, flags: [], time: 1))
    }
    for index in keys.indices { _ = recovery.input.process(.keyUp(code: data.layout.keys[index].code, flags: [], time: 2)) }
}
recoveryChord(["E", "C", "J"])
precondition(journey().recovery == .undoMistake && recovery.input.string == "hat")
recoveryFocused = false
recovery.input.refreshFocus()
precondition(journey().recovery == .makeMistake && recovery.input.string.isEmpty)
let recoveryReadiness = Mirror(reflecting: recovery).children.first { $0.label == "readiness" }!.value as! NSTextField
precondition(recoveryReadiness.stringValue.contains("Click the practice field"), recoveryReadiness.stringValue)
recoveryFocused = true
recovery.input.refreshFocus()
precondition(recoveryReadiness.stringValue.contains("Local chords are on"), recoveryReadiness.stringValue)
recoveryChord(["E", "C", "J"])
recoveryChord(["Backslash"])
precondition(journey().recovery == .repair && recovery.input.string.isEmpty)
recoveryChord(["S", "C", "J"])
precondition(journey().stage == .recall)

// An unusable customized mapping cannot earn a sandbox completion by skipping its missing recipe.
let unavailable = FirstChordWindowController(data: data, usable: { _ in false }, store: recoveryStore, stage: .tryIt,
                                              focus: { true })
precondition(!unavailable.input.isEditable)
precondition(!unavailable.input.ownsLocalInput)
print("Onboarding native checks passed: local press/release, Undo, correction, ordinary paste/selection/cursor, focus loss, collision, mode recovery, Caps Lock, progress privacy and legacy launch.")
