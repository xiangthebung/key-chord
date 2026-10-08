// Run with scripts/test-practice-ui.sh. Uses the real AppKit practice controller without showing
// a window or sending system keystrokes. Aggregate writes use a disposable defaults suite.
import AppKit
import KeyChordCore

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
var sources: [DataFile: String?] = [:]
for file in DataFile.allCases { sources[file] = file.defaultSource }
let outcome = DictionaryLoader.load(sources: sources, rolloverLimit: 6)
precondition(outcome.problems.isEmpty)
let data = outcome.data
let suiteName = "KeyChordUIChecks." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suiteName)!
defer { testDefaults.removePersistentDomain(forName: suiteName) }
var practiceFocused = true
var testDay = 200
var engine = ChordEngine(data: data)
let controller = TypingGuideWindowController(data: data, rolloverLimit: 6, mode: .english,
                                            tapIsRunning: { false }, defaults: testDefaults, practiceFocus: { practiceFocused },
                                            practiceDay: { testDay })
controller.onResetContext = { engine.contextReset() }
controller.onSyncContext = { engine.restore($0) }

// Read progress for assertions while keeping the controller's state private in production.
func state<T>(_ name: String) -> T? {
    Mirror(reflecting: controller).children.first { $0.label == name }?.value as? T
}
func textViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
}
let progress = CourseProgress(defaults: testDefaults)
controller.progress = progress
let input = textViews(controller.window!.contentView!).first { $0.isEditable }!
let keyboards: [KeyboardLimits?] = [nil,
    KeyboardLimits(wiringText: DefaultData.wiringMacBookPro18, scanText: nil, layout: data.layout),
    KeyboardLimits(wiringText: DefaultData.wiringMacBookPro18ANSI, scanText: nil, layout: data.layout)]
var checkedPassages = 0
var checkedChords = 0

func prepare(_ text: String, mode: SubMode, limits: KeyboardLimits?) -> TypingGuide {
    engine = ChordEngine(data: data, subMode: mode)
    controller.limits = limits
    controller.load(Lesson(title: "UI regression", summary: "", text: text, mode: mode))
    let deadline = Date(timeIntervalSinceNow: 10)
    while (state("guide") as TypingGuide?) == nil && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    guard let guide: TypingGuide = state("guide") else { fatalError("planning timed out: \(text)") }
    controller.updateTypingState(availability: .available, effectiveMode: .chord(mode), status: "")
    controller.window!.makeFirstResponder(input)
    return guide
}

func check(_ text: String, mode: SubMode, limits: KeyboardLimits?) throws {
    let guide = prepare(text, mode: mode, limits: limits)
    let target = Array(text)
    for (i, step) in guide.steps.enumerated() {
        switch step.action {
        case let .chord(names, shift):
            let keys = data.layout.keySet(names: names)!
            if shift { controller.rawKey(.down(56)) }
            for key in keys.indices {
                controller.rawKey(.down(data.layout.keys[key].code))
                engine.keyDown(key, shift: shift)
            }
            var result: EngineResult?
            for key in keys.indices {
                if let translated = try engine.keyUp(key) { result = translated }
                controller.rawKey(.up(data.layout.keys[key].code))
            }
            if shift { controller.rawKey(.up(56)) }
            guard let result, result.signal == nil else { fatalError("untranslatable: \(names)") }
            // Production receiveOutput queues this exact method outside the event tap.
            if !result.actions.isEmpty { controller.applyChordOutput(result.actions) }
            checkedChords += 1
        case .key(let key):
            engine.contextReset()
            switch key {
            case .returnKey: input.insertNewline(nil)
            case .tab: input.insertTab(nil)
            case .delete:
                input.deleteBackward(nil)
                controller.rawKey(.down(51))
                controller.rawKey(.up(51))
            }
        case .typeNormally(let value):
            engine.contextReset()
            input.insertText(value, replacementRange: input.selectedRange())
            engine.contextReset()
        }
        let expected = String(target.prefix(step.prefixEnd)) + step.tail
        precondition(input.string == expected,
                     "\(text), step \(i): expected \(expected), got \(input.string)")
        precondition(state("hasError") as Bool? == false, "planned text was marked wrong: \(expected)")
        precondition((state("continuation") as TypingContinuation?) == nil,
                     "planned text reset the engine: \(expected)")
        precondition(state("mistakes") as Int? == 0, "planned text was counted as a mistake: \(expected)")
    }
    precondition(input.string == text, "expected \(text), got \(input.string)")
    checkedPassages += 1
}

func chordOutput(_ step: TypingStep) throws {
    guard case let .chord(names, shift) = step.action else { fatalError("expected a chord") }
    let keys = data.layout.keySet(names: names)!
    if shift { controller.rawKey(.down(56)) }
    for key in keys.indices {
        controller.rawKey(.down(data.layout.keys[key].code))
        engine.keyDown(key, shift: shift)
    }
    var output: EngineResult?
    for key in keys.indices {
        if let result = try engine.keyUp(key) { output = result }
        controller.rawKey(.up(data.layout.keys[key].code))
    }
    if shift { controller.rawKey(.up(56)) }
    guard let output, output.signal == nil else { fatalError("invalid test chord") }
    controller.applyChordOutput(output.actions)
}

// Legacy completion stays practice-only, expands safely to split lessons, and never implies recall.
let migrationSuite = "KeyChordUIMigration." + UUID().uuidString
let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
migrationDefaults.set(["first-chord", "cpp-mode"], forKey: "courseCompleted")
let migrated = CourseProgress(defaults: migrationDefaults)
precondition(migrated.completed.contains("first-ends"))
precondition(migrated.completed.contains("cpp-more-keywords"))
precondition(migrated.unassisted.isEmpty)
precondition(migrationDefaults.integer(forKey: "courseCurriculumVersion") == Course.curriculumVersion)
migrated.markDone("first-chord", unassisted: true)
precondition(migrated.unassisted == ["first-chord"])
precondition(!migrated.unassisted.contains("first-ends"))
migrationDefaults.removePersistentDomain(forName: migrationSuite)
precondition(Settings(defaults: testDefaults).keyLabelStyle == .both)
testDefaults.set("invalid", forKey: "keyLabelStyle")
precondition(Settings(defaults: testDefaults).keyLabelStyle == .both)

func setRecall(_ enabled: Bool) {
    let control: NSSegmentedControl = state("practiceMode")!
    control.selectedSegment = enabled ? 1 : 0
    precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
}
func refreshInput() { controller.textDidChange(Notification(name: NSText.didChangeNotification, object: input)) }
func send(_ button: NSButton) { precondition(NSApp.sendAction(button.action!, to: button.target, from: button)) }
func waitForExercise() -> TypingGuide {
    let deadline = Date(timeIntervalSinceNow: 15)
    while ((state("preparingExercise") as Bool?) == true || (state("guide") as TypingGuide?) == nil) && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    precondition(state("preparingExercise") as Bool? == false)
    return state("guide")!
}
func selectStage(_ stage: LearningStage) -> TypingGuide {
    let control: NSSegmentedControl = state("learningStages")!
    control.selectedSegment = LearningStage.allCases.firstIndex(of: stage)!
    precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
    return waitForExercise()
}
func selectImportLanguage(_ index: Int) -> TypingGuide {
    let control: NSPopUpButton = state("importLanguagePopup")!
    control.selectItem(at: index)
    precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
    return waitForExercise()
}

// Imported language overrides preserve the actual target, Unicode draft, selection, and input origins.
// Built-in passages keep the explicit language supplied by the lesson.
controller.importText("int count = 1;", name: "ambiguous.txt")
_ = waitForExercise()
precondition(state("mode") as SubMode? == .cpp)
input.insertText("draft 😀", replacementRange: input.selectedRange())
input.setSelectedRange(NSRange(location: 2, length: 2))
_ = selectImportLanguage(1)
precondition(state("mode") as SubMode? == .english)
precondition(state("text") as String? == "int count = 1;")
precondition(input.string == "draft 😀")
precondition(input.selectedRange() == NSRange(location: 2, length: 2))
precondition(!controller.qualifiesForChordCredit)
_ = selectImportLanguage(0)
precondition(state("mode") as SubMode? == .cpp)
precondition(input.string == "draft 😀")
controller.importText("sat cat", name: "words.cpp")
_ = waitForExercise()
let imported = selectImportLanguage(1)
controller.updateTypingState(availability: .available, effectiveMode: .chord(.english), status: "")
engine = ChordEngine(data: data)
setRecall(true)
try chordOutput(imported.steps[0])
let preservedPrefix = input.string
precondition(controller.qualifiesForChordCredit)
_ = selectImportLanguage(2)
precondition(input.string == preservedPrefix)
precondition(!controller.qualifiesForChordCredit, "English provenance cannot earn C++ credit")
_ = selectImportLanguage(1)
precondition(input.string == preservedPrefix)
precondition(controller.qualifiesForChordCredit, "switching back must preserve the original provenance")
_ = prepare("int", mode: .cpp, limits: nil)
_ = selectImportLanguage(1)
precondition(state("mode") as SubMode? == .cpp)
precondition(state("importedText") as Bool? == false)
let importRow: NSStackView = state("importLanguageRow")!
precondition(importRow.isHidden)

// Text size persists in a bounded range and changes fonts without clearing the draft or its provenance.
let sized = prepare("sat cat", mode: .english, limits: nil)
// The task remains a single vertical flow, with the guide below typing rather than beside it.
let exerciseLayout: NSStackView = state("exerciseContent")!
let targetCard: NSBox = state("passageCard")!
let typingCard: NSStackView = state("practiceCard")!
let primaryRow: NSStackView = state("primaryActions")!
let bottomKeyboard: NSStackView = state("keyboardCard")!
precondition(exerciseLayout.arrangedSubviews.firstIndex(of: targetCard)! < exerciseLayout.arrangedSubviews.firstIndex(of: typingCard)!)
precondition(exerciseLayout.arrangedSubviews.last === bottomKeyboard)
precondition(primaryRow.arrangedSubviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count == 1)
setRecall(true)
try chordOutput(sized.steps[0])
let beforeSize = input.string
let beforeSelection = input.selectedRange()
let sizeControl: NSPopUpButton = state("textSizePopup")!
sizeControl.selectItem(at: Settings.practiceTextSizeRange.upperBound - Settings.practiceTextSizeRange.lowerBound)
precondition(NSApp.sendAction(sizeControl.action!, to: sizeControl.target, from: sizeControl))
precondition(Settings(defaults: testDefaults).practiceTextSize == 30)
precondition(input.font?.pointSize == 30)
precondition(input.string == beforeSize && input.selectedRange() == beforeSelection)
precondition(controller.qualifiesForChordCredit)
let settings = Settings(defaults: testDefaults)
settings.practiceTextSize = 500
precondition(settings.practiceTextSize == 30)
settings.practiceTextSize = -1
precondition(settings.practiceTextSize == 16)
settings.practiceTextSize = 20

// The keyboard has navigable per-key accessibility elements in addition to its textual table.
let diagram = KeyboardDiagramView()
diagram.layout = data.layout
diagram.meanings = KeyMeanings(data: data, mode: .english)
diagram.target = [0, 56, 60]
diagram.held = [0, 56]
let accessibleKeys = diagram.accessibilityChildren()!.compactMap { $0 as? NSAccessibilityElement }
precondition(diagram.accessibilityRole() == .group)
precondition(accessibleKeys.count > 20)
let leftShift = accessibleKeys.first { $0.accessibilityLabel()?.hasPrefix("Left Shift") == true }!
let rightShift = accessibleKeys.first { $0.accessibilityLabel()?.hasPrefix("Right Shift") == true }!
precondition((leftShift.accessibilityValue() as? String)?.contains("Held down") == true)
precondition((rightShift.accessibilityValue() as? String)?.contains("hold either Shift") == true)
precondition(KeyboardDiagramView.physicalName(for: 36) == "Return")
precondition(KeyboardDiagramView.physicalName(for: 48) == "Tab")

// Losing input focus cannot contribute an attempt or a speed/credit claim.
let unfocused = prepare("sat", mode: .english, limits: nil)
setRecall(true)
practiceFocused = false
try chordOutput(unfocused.steps[0])
precondition(state("capturedChordAttempts") as Int? == 0)
precondition(!controller.qualifiesForChordCredit)
practiceFocused = true

// The actual controller accepts a genuine alternative that emits the same text and engine context.
let originalSat = TypingPlanner(data: data, mode: .english).plan("sat").steps[0]
var alternativeData = data
alternativeData.english.entries[data.layout.keySet(names: ["F"])!] = .text(TextEntry(text: "sat"))
controller.update(data: alternativeData, rolloverLimit: 6)
controller.load(Lesson(title: "Alternative regression", summary: "", text: "sat", mode: .english))
_ = waitForExercise()
controller.updateTypingState(availability: .available, effectiveMode: .chord(.english), status: "")
engine = ChordEngine(data: alternativeData)
setRecall(true)
try chordOutput(originalSat)
precondition(input.string == "sat")
precondition(controller.qualifiesForChordCredit)
precondition(state("scoredMistakes") as Int? == 0)
controller.update(data: data, rolloverLimit: 6)
_ = waitForExercise()

// Ordinary typing, paste, mixed input, and chord output received while chord mode is off cannot qualify.
for chordMode in [false, true] {
    _ = prepare("sat", mode: .english, limits: nil)
    controller.updateTypingState(availability: .available, effectiveMode: chordMode ? .chord(.english) : .normal, status: "")
    input.insertText("sat", replacementRange: input.selectedRange())
    refreshInput()
    precondition(!controller.qualifiesForChordCredit)
    let stats: NSTextField = state("statsLabel")!
    precondition(!stats.stringValue.contains("chord wpm"))
}
let mixed = prepare("sat cat", mode: .english, limits: nil)
setRecall(true)
try chordOutput(mixed.steps[0])
input.insertText(" cat", replacementRange: input.selectedRange())
refreshInput()
precondition(!controller.qualifiesForChordCredit)
let off = prepare("sat", mode: .english, limits: nil)
controller.updateTypingState(availability: .available, effectiveMode: .normal, status: "")
try chordOutput(off.steps[0])
precondition(!controller.qualifiesForChordCredit)

// Untouched chord output has credit; explicit hints and Guided mode classify assistance immediately.
let unassisted = prepare("sat", mode: .english, limits: nil)
setRecall(true)
try chordOutput(unassisted.steps[0])
precondition(controller.qualifiesForChordCredit)
precondition(state("usedAssistance") as Bool? == false)
let chordStats: NSTextField = state("statsLabel")!
precondition(chordStats.stringValue.contains("chord wpm"))
let guided = prepare("sat", mode: .english, limits: nil)
setRecall(false)
try chordOutput(guided.steps[0])
precondition(controller.qualifiesForChordCredit)
precondition(state("usedAssistance") as Bool? == true)
precondition(!chordStats.stringValue.contains("chord wpm"))
let hinted = prepare("sat", mode: .english, limits: nil)
setRecall(true)
let hint: NSButton = state("hintButton")!
precondition(NSApp.sendAction(hint.action!, to: hint.target, from: hint))
precondition(state("usedAssistance") as Bool? == true)
try chordOutput(hinted.steps[0])
precondition(controller.qualifiesForChordCredit)
precondition(!chordStats.stringValue.contains("chord wpm"))

// Actual Return and Tab retain structural provenance; inserting identical whitespace as text does not.
try check("sat\n\tcat", mode: .english, limits: nil)
precondition(controller.qualifiesForChordCredit)
let pastedWhitespace = prepare("sat\ncat", mode: .english, limits: nil)
try chordOutput(pastedWhitespace.steps[0])
input.insertText("\n", replacementRange: input.selectedRange())
refreshInput()
try chordOutput(pastedWhitespace.steps.last!)
precondition(!controller.qualifiesForChordCredit)

// Course See cannot emit text or credit. Try earns practice. Recall uses different text from the
// guided exercise; revealing assistance cannot earn a pass, and Use stays separate from measurement.
testDefaults.set(true, forKey: "recallPractice")
controller.openCourseStep(0)
let seeGuide = waitForExercise()
precondition(state("recallMode") as Bool? == false)
precondition(state("courseStage") as LearningStage? == .see)
precondition(!input.isEditable)
engine = ChordEngine(data: data)
controller.updateTypingState(availability: .available, effectiveMode: .chord(.english), status: "")
try chordOutput(seeGuide.steps[0])
precondition(input.string.isEmpty)
precondition(!controller.qualifiesForChordCredit)
precondition(!progress.completed.contains(Course.steps[0].id))
let demo: NSButton = state("demonstrateButton")!
send(demo)
precondition(state("demonstrationReleased") as Bool? == true)
let demoDetail: NSTextField = state("learningDetail")!
precondition(demoDetail.stringValue.contains("All keys are up") && demoDetail.stringValue.contains("The chord types"))
precondition(!demoDetail.stringValue.contains("onset") && !demoDetail.stringValue.contains("coda"))
let courseGuide = selectStage(.tryIt)
let guidedText: String = state("text")!
precondition(input.isEditable)
engine = ChordEngine(data: data)
for step in courseGuide.steps { try chordOutput(step) }
precondition(progress.completed.contains(Course.steps[0].id))
precondition(!progress.unassisted.contains(Course.steps[0].id))
let retry: NSButton = state("completionNext")!
send(retry)
let assistedRecall = waitForExercise()
precondition(state("courseStage") as LearningStage? == .recall)
precondition(state("text") as String? != guidedText)
let courseKeys: NSTextField = state("courseNew")!
precondition(courseKeys.isHidden)
let freshRecallIntro: NSTextField = state("courseIntro")!
precondition(freshRecallIntro.stringValue != Course.steps[0].intro,
             "async generation must not restore answer-bearing teaching before the first key event")
precondition(freshRecallIntro.stringValue.contains("from memory"))
precondition(state("lessonDetailsVisible") as Bool? == false)
send(hint)
engine = ChordEngine(data: data)
for step in assistedRecall.steps { try chordOutput(step) }
precondition(!progress.unassisted.contains(Course.steps[0].id))
send(retry)
_ = waitForExercise()
// Lesson details survive a restart by choice. Their visible teaching remains assistance at reset,
// capture, and output, so retrying cannot earn a clean Recall pass or start delayed-check evidence.
let lessonDetails: NSButton = state("lessonDetailsButton")!
send(lessonDetails)
let lessonIntro: NSTextField = state("courseIntro")!
precondition(state("lessonDetailsVisible") as Bool? == true)
precondition(lessonIntro.stringValue == Course.steps[0].intro && !lessonIntro.isHidden)
precondition(NSApp.sendAction(NSSelectorFromString("restart"), to: controller, from: nil))
let detailsRetry = waitForExercise()
precondition(state("lessonDetailsVisible") as Bool? == true)
precondition(state("usedAssistance") as Bool? == true)
precondition(lessonIntro.stringValue == Course.steps[0].intro && !lessonIntro.isHidden)
engine = ChordEngine(data: data)
for step in detailsRetry.steps { try chordOutput(step) }
precondition(controller.qualifiesForChordCredit)
precondition(!progress.unassisted.contains(Course.steps[0].id))
let detailMappings: [Int: UInt64] = state("lessonMappingCache")!
precondition(progress.delayedCheck(Course.steps[0].id, mapping: detailMappings[0]!).firstPassDay == nil)
precondition(progress.delayedCheck(Course.steps[0].id, mapping: detailMappings[0]!).successfulDelayedChecks == 0)
send(retry)
let retryGuide = waitForExercise()
engine = ChordEngine(data: data)
for step in retryGuide.steps { try chordOutput(step) }
precondition(progress.unassisted.contains(Course.steps[0].id))
let mappings: [Int: UInt64] = state("lessonMappingCache")!
let lessonID = Course.steps[0].id, lessonMapping = mappings[0]!
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).firstPassDay == testDay)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).successfulDelayedChecks == 0)
precondition(!progress.delayedCheck(lessonID, mapping: lessonMapping).isRetained)
var editorRequests = 0
controller.onUseInEditor = { editorRequests += 1 }
send(retry)
precondition(state("courseStage") as LearningStage? == .use)
send(state("stageNextButton")!)
precondition(editorRequests == 1)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).successfulDelayedChecks == 0)

func finishFreshRecall(day: Int, assisted: Bool = false) throws {
    testDay = day
    let guide = selectStage(.recall)
    controller.updateTypingState(availability: .available, effectiveMode: .chord(.english), status: "")
    engine = ChordEngine(data: data)
    if assisted { send(hint) }
    for step in guide.steps { try chordOutput(step) }
}
try finishFreshRecall(day: 200)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).successfulDelayedChecks == 0)
// A visible reference and textual keys are assisted; restarting Recall replaces the seen exercise,
// hides both answer surfaces, and avoids penalizing preferences whose content is now hidden.
_ = selectStage(.recall)
send(hint)
let keyboardReference: NSButton = state("referenceButton")!
if !Settings(defaults: testDefaults).practiceReferenceVisible { send(keyboardReference) }
let textKeysButton: NSButton = state("keyboardTextButton")!
if state("keyboardTextVisible") as Bool? != true { send(textKeysButton) }
let referenceCard: NSStackView = state("keyboardCard")!
let textKeys: PracticeKeyboardTextView = state("keyboardText")!
precondition(!referenceCard.isHidden && !textKeys.isHidden)
precondition(state("usedAssistance") as Bool? == true)
let seenReferenceText: String = state("text")!
precondition(NSApp.sendAction(NSSelectorFromString("restart"), to: controller, from: nil))
let hiddenReferenceRetry = waitForExercise()
precondition(state("text") as String? != seenReferenceText)
precondition(referenceCard.isHidden)
precondition(state("usedAssistance") as Bool? == false)
engine = ChordEngine(data: data)
for step in hiddenReferenceRetry.steps { try chordOutput(step) }
precondition(state("usedAssistance") as Bool? == false)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).successfulDelayedChecks == 0)
for day in [201, 204, 211] { try finishFreshRecall(day: day) }
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).isRetained)
try finishFreshRecall(day: 212, assisted: true)
precondition(progress.unassisted.contains(lessonID), "assistance must preserve the historical pass")
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).firstPassDay == 200)
precondition(!progress.delayedCheck(lessonID, mapping: lessonMapping).isRetained)
// Ordinary completion of an actual Recall exercise cannot create or advance delayed evidence.
let ordinaryRecall = selectStage(.recall)
precondition(!ordinaryRecall.steps.isEmpty)
input.insertText(state("text") as String? ?? "", replacementRange: input.selectedRange())
refreshInput()
precondition(!controller.qualifiesForChordCredit)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).successfulDelayedChecks == 0)
// A changed mapping discards delayed evidence while keeping the aggregate under its old identity.
var remapped = data
remapped.english.entries[data.layout.keySet(names: ["F"])!] = .text(TextEntry(text: "changed"))
controller.update(data: remapped, rolloverLimit: 6)
_ = waitForExercise()
let changedMappings: [Int: UInt64] = state("lessonMappingCache")!
precondition(changedMappings[0] != lessonMapping)
precondition(progress.delayedCheck(lessonID, mapping: changedMappings[0]!).firstPassDay == nil)
precondition(progress.delayedCheck(lessonID, mapping: lessonMapping).firstPassDay == 200)
controller.update(data: data, rolloverLimit: 6)
_ = waitForExercise()
// Optional test-out bypasses See/Try but still uses a fresh unaided exercise.
controller.startCourseTestOut(presentWindow: false)
_ = waitForExercise()
precondition(state("courseStage") as LearningStage? == .recall)
precondition(state("recallMode") as Bool? == true)

// Real physical Delete still resets the engine and replans genuine partial words; correcting a
// mistake back to the planned "make" base must restore its suffix context instead.
for limits in keyboards {
    let guide = prepare("making tea", mode: .english, limits: limits)
    try chordOutput(guide.steps[0])
    input.insertText("x", replacementRange: input.selectedRange())
    precondition(state("hasError") as Bool? == true)
    engine.contextReset()
    input.deleteBackward(nil)
    precondition(input.string == "make")
    precondition(state("hasError") as Bool? == false)
    try chordOutput(guide.steps[1])
    try chordOutput(guide.steps[2])
    precondition(input.string == "making tea", "correcting a typo lost the suffix context")
    precondition(controller.qualifiesForChordCredit, "corrected ordinary typo must not taint remaining chord text")

    let partial = prepare("making tea", mode: .english, limits: limits)
    try chordOutput(partial.steps[0])
    engine.contextReset()
    input.deleteBackward(nil)
    precondition(input.string == "mak")
    guard let continuation: TypingContinuation = state("continuation") else {
        fatalError("a genuine partial word must get a continuation")
    }
    for step in continuation.guide.steps { try chordOutput(step) }
    precondition(input.string == "making tea", "partial-word continuation did not finish the passage")
    precondition(controller.qualifiesForChordCredit, "suffix continuation must preserve provenance")
}

for limits in keyboards {
    for text in ["making tea", "sam tried making tea he runs faster the nicest thing is a good book she reads slowly",
                 "hoping happier happiness lying tying stopping running swimming", "happier making tried tea"] {
        try check(text, mode: .english, limits: limits)
    }
    for step in Course.steps { try check(step.text, mode: step.mode, limits: limits) }
    for lesson in Lessons.all { try check(lesson.text, mode: lesson.mode, limits: limits) }
    let listening = ListeningPractice(data: data, usable: limits?.usable(in: data.layout) ?? { _ in true })
    var random = SystemRandomNumberGenerator()
    var seen = Set<String>()
    // One complete shuffled bag covers every usable listening word before the first repeat.
    while let prompt = listening.next(using: &random), seen.insert(prompt.text).inserted {
        try check(prompt.text, mode: .english, limits: limits)
    }
}
// A permission block exposes one actionable control, including after the exercise refreshes.
_ = prepare("sat", mode: .english, limits: nil)
controller.updateTypingState(availability: .missingPermission, effectiveMode: .normal, status: "Allow Accessibility access.")
let startButton: NSButton = state("practiceActiveButton")!
let permissionButton: NSButton = state("enableOtherAppsButton")!
precondition(startButton.isHidden && !permissionButton.isHidden)
input.insertText("s", replacementRange: input.selectedRange())
precondition(startButton.isHidden && !permissionButton.isHidden)
controller.updateTypingState(availability: .available, effectiveMode: .normal, status: "Chord typing is off")
precondition(!startButton.isHidden && permissionButton.isHidden)
print("AppKit practice checks passed: \(checkedPassages) passages, \(checkedChords) chords, three keyboards.")
