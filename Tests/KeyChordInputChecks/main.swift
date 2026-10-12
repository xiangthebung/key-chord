// Real local input, hidden windows, and isolated permission preferences.
import AppKit
import KeyChordCore

NSApplication.shared.setActivationPolicy(.prohibited)
let outcome = DictionaryLoader.load(sources: Dictionary(uniqueKeysWithValues: DataFile.allCases.map {
    ($0, Optional($0.defaultSource))
}), rolloverLimit: 6)
precondition(outcome.problems.isEmpty)
let data = outcome.data
let suite = "KeyChordInputChecks." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let access = TypingAccessStore(defaults: defaults)
precondition(access.showPracticeAtLaunch && !access.permitsGlobalTyping)
precondition(!TypingAccessStore(defaults: defaults, hasExistingDataFiles: true).showPracticeAtLaunch)
precondition(!TypingAccessStore(defaults: defaults, hasExistingDataFiles: true).permitsGlobalTyping)
access.chooseOtherApps()
precondition(TypingAccessStore(defaults: defaults).permitsGlobalTyping)
precondition(Set(defaults.persistentDomain(forName: suite)!.keys) == ["typingAccess.v1.initialized", "typingAccess.v1.otherAppsChosen"])

// Old onboarding and pre-onboarding profiles preserve their explicit global-typing choice.
for profile in ["local", "dismissed", "opted-in", "legacy", "pre-onboarding", "unfinished"] {
    let oldSuite = suite + "." + profile
    let oldDefaults = UserDefaults(suiteName: oldSuite)!
    if profile != "pre-onboarding" { oldDefaults.set(true, forKey: "learningJourney.v1.initialized") }
    if profile == "dismissed" { oldDefaults.set(true, forKey: "learningJourney.v1.dismissed") }
    if profile == "opted-in" { oldDefaults.set(true, forKey: "learningJourney.v1.otherAppsChosen") }
    if profile == "legacy" { oldDefaults.set(true, forKey: "learningJourney.v1.legacy") }
    if profile == "pre-onboarding" { oldDefaults.set("cpp", forKey: "lastSubMode") }
    if profile == "unfinished" { oldDefaults.set("recall", forKey: "learningJourney.v1.stage") }
    let migrated = TypingAccessStore(defaults: oldDefaults, hasExistingDataFiles: true)
    precondition(migrated.permitsGlobalTyping == ["opted-in", "legacy", "pre-onboarding"].contains(profile))
    precondition(migrated.showPracticeAtLaunch == ["local", "opted-in", "unfinished"].contains(profile))
    precondition(!TypingAccessStore(defaults: oldDefaults).showPracticeAtLaunch)
    oldDefaults.removePersistentDomain(forName: oldSuite)
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

// The local practice rejects C++ mode without leaving right Option stuck toggling C++ forever.
input.clearForTask()
let rejectedSwitch = chord(["LBracket", "RBracket"])
precondition(input.string.isEmpty && rejectedSwitch.routed.events == [.modeChanged(.normal)])
precondition(!input.practice.chordEnabled)
_ = input.process(.modifierDown(code: 61, key: .option, time: 10))
let resumedEnglish = input.process(.modifierUp(code: 61, key: .option, time: 100))
precondition(resumedEnglish.routed.events == [.modeChanged(.chord(.english))] && input.practice.chordEnabled)
_ = chord(["S", "C", "J"])
precondition(input.string == "sat")

print("Native local-input checks passed: permission migration, final-release composition, undo, ordinary edits, focus loss, and global capture exclusion.")
