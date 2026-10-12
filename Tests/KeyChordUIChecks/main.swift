// Real AppKit practice, hidden windows, disposable defaults, and local events only.
import AppKit
import KeyChordCore

NSApplication.shared.setActivationPolicy(.prohibited)
let outcome = DictionaryLoader.load(sources: Dictionary(uniqueKeysWithValues: DataFile.allCases.map {
    ($0, Optional($0.defaultSource))
}), rolloverLimit: 6)
precondition(outcome.problems.isEmpty)
let data = outcome.data
let suiteName = "KeyChordUIChecks." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suiteName)!
defer { testDefaults.removePersistentDomain(forName: suiteName) }
func textViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
}
func state<T>(_ controller: Any, _ name: String) -> T {
    Mirror(reflecting: controller).children.first { $0.label == name }!.value as! T
}

// The editor writes only a separate overrides file and restores the installed mapping on removal.
let customDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyChordCustomChecks." + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: customDirectory) }
let customStore = DataStore(directory: customDirectory)
let initiallySavedChords = try customStore.readCustomChords()
precondition(initiallySavedChords.isEmpty)
var savedChords: [CustomChord] = []
var testLease = true
let customEditor = CustomChordsWindowController(base: data, chords: [], testFocus: { true }, globalSuspended: { testLease }) { chords in
    try customStore.writeCustomChords(chords)
    savedChords = chords
}
let customText: NSTextView = state(customEditor, "text")
let customSave: NSButton = state(customEditor, "saveButton")
let customScope: NSPopUpButton = state(customEditor, "scope")
let customSpacing: NSPopUpButton = state(customEditor, "spacing")
let customRemove: NSButton = state(customEditor, "removeButton")
let customUndoRemove: NSButton = state(customEditor, "undoRemoveButton")
let customSearch: NSSearchField = state(customEditor, "search")
let customTable: NSTableView = state(customEditor, "table")
let customFeedback: NSTextField = state(customEditor, "feedback")
let customPreview: NSTextField = state(customEditor, "previewText")
let customPreviewTitle: NSTextField = state(customEditor, "previewTitle")
let customEnabled: NSButton = state(customEditor, "enabledButton")
let customTest: LocalChordInputView = state(customEditor, "testInput")
let customTestMode: NSPopUpButton = state(customEditor, "testMode")
let customClearTest: NSButton = state(customEditor, "clearTestButton")
func draftTestChord(_ spec: String, in input: LocalChordInputView, flags: ModifierFlags = []) {
    let codes = data.layout.keySet(names: spec.split(separator: "+").map(String.init))!.indices.map { data.layout.keys[$0].code }
    for code in codes { input.process(.keyDown(code: code, isRepeat: false, flags: flags, time: 0)) }
    for code in codes { input.process(.keyUp(code: code, flags: flags, time: 1)) }
}
func labels(_ view: NSView) -> [String] {
    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
}
precondition(!customSave.isEnabled)
customEditor.recorder.beginRecording()
for code: KeyCode in [1, 8, 38] { customEditor.recorder.receive(.down(code)) }
customEditor.recorder.receive(.up(1)); customEditor.recorder.receive(.up(38))
precondition(customEditor.recorder.isRecording && !customSave.isEnabled)
customEditor.recorder.receive(.up(8))
precondition(!customEditor.recorder.isRecording && customEditor.recorder.codes == [1, 8, 38])
precondition(customPreview.stringValue.contains("sat") && customPreview.stringValue.contains("Enter text"), "the original meaning is visible before entering text")
customText.string = "hello"
customEditor.textDidChange(Notification(name: NSText.didChangeNotification, object: customText))
precondition(customSave.title == "Replace chord" && customPreviewTitle.stringValue.contains("Replaces"))
precondition(customPreview.stringValue.contains("sat") && customPreview.stringValue.contains("hello"))
for code: KeyCode in [1, 8, 38] { customTest.process(.keyDown(code: code, isRepeat: false, flags: [], time: 0)) }
customTest.process(.keyUp(code: 1, flags: [], time: 1)); customTest.process(.keyUp(code: 8, flags: [], time: 1))
precondition(customTest.string.isEmpty, "draft testing waits for all keys to be released")
customTest.process(.keyUp(code: 38, flags: [], time: 1))
draftTestChord("S+C+J", in: customTest)
precondition(customTest.string == "hello hello")
draftTestChord("Backslash", in: customTest)
precondition(customTest.string == "hello", "the test uses the real chord Undo")
testLease = false
draftTestChord("S+C+J", in: customTest)
precondition(customTest.string == "hello" && !customTest.practice.ownsInput, "draft testing requires global capture to be suspended")
testLease = true
customClearTest.performClick(nil)
draftTestChord("S+C+J", in: customTest)
draftTestChord("Period", in: customTest)
draftTestChord("S+C+J", in: customTest)
precondition(customTest.string == "hello. Hello", "neighboring punctuation and capitalization are tested in context")
customSpacing.selectItem(at: 1); _ = NSApp.sendAction(customSpacing.action!, to: customSpacing.target, from: customSpacing)
precondition(customSpacing.titleOfSelectedItem == "No added spaces" && customTest.string.isEmpty)
draftTestChord("S+C+J", in: customTest)
draftTestChord("S+C+J", in: customTest, flags: .capsLock)
precondition(customTest.string == "helloHELLO")
precondition(savedChords.isEmpty && !FileManager.default.fileExists(atPath: customStore.customChordsURL.path), "trying a draft never writes or applies it globally")
customText.string = "Thanks for your help!\n你好 | # \\\""
customEditor.textDidChange(Notification(name: NSText.didChangeNotification, object: customText))
customScope.selectItem(at: 2); _ = NSApp.sendAction(customScope.action!, to: customScope.target, from: customScope)
customSpacing.selectItem(at: 1); _ = NSApp.sendAction(customSpacing.action!, to: customSpacing.target, from: customSpacing)
precondition(customSave.isEnabled && customPreviewTitle.stringValue.contains("Replaces"))
precondition(customPreview.stringValue.contains("English") && customPreview.stringValue.contains("C++"))
customTestMode.selectItem(at: 1); _ = NSApp.sendAction(customTestMode.action!, to: customTestMode.target, from: customTestMode)
draftTestChord("S+C+J", in: customTest)
precondition(customTest.string == customText.string, "Both drafts can be tested in C++ without saving")
precondition(customEditor.saveChord())
let roundTrip = try customStore.readCustomChords()
precondition(roundTrip == savedChords && roundTrip.count == 1 && roundTrip[0].text == customText.string)
precondition(roundTrip[0].scope == .both && roundTrip[0].spacing == .exact && !customSave.isEnabled)
precondition(!FileManager.default.fileExists(atPath: customStore.url(.english).path), "installed files are never rewritten")
customEnabled.state = .off; _ = NSApp.sendAction(customEnabled.action!, to: customEnabled.target, from: customEnabled)
precondition(customSave.isEnabled && customPreview.stringValue.contains("sat"))
precondition(savedChords[0].isEnabled, "the enable checkbox participates in the explicit save flow")
draftTestChord("S+C+J", in: customTest)
precondition(customTest.string == "sat", "the disabled draft previews the restored mapping")
precondition(customEditor.saveChord())
let pausedRoundTrip = try customStore.readCustomChords()
precondition(pausedRoundTrip.count == 1 && !pausedRoundTrip[0].isEnabled && pausedRoundTrip[0].text == roundTrip[0].text)
let pausedCell = customEditor.tableView(customTable, viewFor: customTable.tableColumns[0], row: 0)!
precondition(labels(pausedCell).contains("Off"))
customEnabled.state = .on; _ = NSApp.sendAction(customEnabled.action!, to: customEnabled.target, from: customEnabled)
precondition(customEditor.saveChord() && savedChords == roundTrip)
customEditor.recorder.beginRecording(); customEditor.recorder.receive(.down(14)); customEditor.recorder.stopRecording()
customEditor.recorder.receive(.up(14))
precondition(customEditor.recorder.codes == roundTrip[0].keyCodes, "canceling recording preserves the original chord")
customSearch.stringValue = "nothing matches"; customEditor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: customSearch))
precondition(customTable.numberOfRows == 0)
customSearch.stringValue = "Thanks"; customEditor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: customSearch))
precondition(customTable.numberOfRows == 1)
customRemove.performClick(nil)
let afterRemoval = try customStore.readCustomChords()
precondition(savedChords.isEmpty && !customUndoRemove.isHidden && afterRemoval.isEmpty)
customUndoRemove.performClick(nil)
precondition(savedChords == roundTrip)

// Suggestions are opt-in, can be cycled, and only change the unsaved draft.
var suggestionSaves = 0
let suggestionEditor = CustomChordsWindowController(base: data, chords: []) { _ in suggestionSaves += 1 }
let suggest: NSButton = state(suggestionEditor, "suggestionButton")
let choices: NSStackView = state(suggestionEditor, "suggestionChoices")
suggest.performClick(nil)
let firstSuggestions: [KeySet] = state(suggestionEditor, "suggestedKeys")
precondition(firstSuggestions.count == 3 && !choices.isHidden)
suggest.performClick(nil)
let nextSuggestions: [KeySet] = state(suggestionEditor, "suggestedKeys")
precondition(Set(firstSuggestions).isDisjoint(with: nextSuggestions))
(choices.arrangedSubviews[0] as! NSButton).performClick(nil)
precondition(suggestionEditor.recorder.codes == nextSuggestions[0].indices.map { data.layout.keys[$0].code }.sorted())
let suggestionPreview: NSTextField = state(suggestionEditor, "previewText")
precondition(suggestionPreview.stringValue.contains("No output") && suggestionSaves == 0)

// Protected actions are identified even before a user enters replacement text.
let protectedEditor = CustomChordsWindowController(base: data, chords: []) { _ in preconditionFailure("reserved actions cannot be saved") }
protectedEditor.recorder.beginRecording(); protectedEditor.recorder.receive(.down(42)); protectedEditor.recorder.receive(.up(42))
let protectedTitle: NSTextField = state(protectedEditor, "previewTitle")
let protectedSave: NSButton = state(protectedEditor, "saveButton")
let protectedTest: NSButton = state(protectedEditor, "tryButton")
precondition(protectedTitle.stringValue == "Built-in action is protected" && !protectedSave.isEnabled && !protectedTest.isEnabled)

// Changing language scope or keys previews the mappings that will be restored as well as replaced.
var languageData = data
let satKeys = data.layout.keySet(names: ["S", "C", "J"])!
languageData.cpp.entries[satKeys] = .text(TextEntry(text: "C++ original"))
let savedBoth = CustomChord(id: "preview", keyCodes: [1, 8, 38], text: "greeting", scope: .both)
let scopeEditor = CustomChordsWindowController(base: languageData, chords: [savedBoth]) { _ in }
let previewScope: NSPopUpButton = state(scopeEditor, "scope")
previewScope.selectItem(at: 0); _ = NSApp.sendAction(previewScope.action!, to: previewScope.target, from: previewScope)
let languagePreview: NSTextField = state(scopeEditor, "previewText")
precondition(languagePreview.stringValue.contains("greeting") && languagePreview.stringValue.contains("C++ original"))
scopeEditor.recorder.beginRecording()
for code: KeyCode in [14, 8, 38] { scopeEditor.recorder.receive(.down(code)) }
for code: KeyCode in [14, 8, 38] { scopeEditor.recorder.receive(.up(code)) }
precondition(languagePreview.stringValue.contains("sat") && languagePreview.stringValue.contains("greeting"))

// Invalid saved mappings remain visible and can be switched off for later repair.
var repairedChord: CustomChord?
let repairEditor = CustomChordsWindowController(base: data, chords: [savedBoth], usable: { _ in false }) { repairedChord = $0.first }
let repairTable: NSTableView = state(repairEditor, "table")
let repairCell = repairEditor.tableView(repairTable, viewFor: repairTable.tableColumns[0], row: 0)!
precondition(labels(repairCell).contains("Needs repair"))
let repairFeedback: NSTextField = state(repairEditor, "feedback")
precondition(repairFeedback.stringValue.contains("cannot register"))
let repairEnabled: NSButton = state(repairEditor, "enabledButton")
repairEnabled.state = .off; _ = NSApp.sendAction(repairEnabled.action!, to: repairEnabled.target, from: repairEnabled)
precondition(repairEditor.saveChord() && repairedChord?.isEnabled == false && repairedChord?.text == savedBoth.text)

// Version 1 files migrate as enabled, while version 2 persists Off and is rejected by older readers.
let legacyStore = DataStore(directory: customDirectory.appendingPathComponent("legacy"))
try FileManager.default.createDirectory(at: legacyStore.directory, withIntermediateDirectories: true)
try Data(#"{"version":1,"chords":[{"id":"legacy","keyCodes":[1,8,38],"text":"hello","scope":"english","spacing":"exact"}]}"#.utf8).write(to: legacyStore.customChordsURL)
let legacyChords = try legacyStore.readCustomChords()
precondition(legacyChords.count == 1 && legacyChords[0].isEnabled)
var pausedLegacy = legacyChords[0]; pausedLegacy.isEnabled = false
try legacyStore.writeCustomChords([pausedLegacy])
let persistedVersion = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyStore.customChordsURL)) as! [String: Any]
let persistedLegacy = try legacyStore.readCustomChords()
precondition(persistedVersion["version"] as? Int == 2 && persistedLegacy == [pausedLegacy])
// An I/O failure keeps the draft and leaves the Save action available for a retry.
let failingEditor = CustomChordsWindowController(base: data, chords: roundTrip) { _ in
    throw NSError(domain: "CustomChordChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk full"])
}
let failingText: NSTextView = state(failingEditor, "text")
failingText.string = "Unsaved change"
failingEditor.textDidChange(Notification(name: NSText.didChangeNotification, object: failingText))
precondition(!failingEditor.saveChord())
let failingSave: NSButton = state(failingEditor, "saveButton")
let failingFeedback: NSTextField = state(failingEditor, "feedback")
precondition(failingSave.isEnabled && failingText.string == "Unsaved change" && failingFeedback.stringValue.contains("Disk full"))
try Data("{not valid JSON}".utf8).write(to: customStore.customChordsURL)
do { _ = try customStore.readCustomChords(); preconditionFailure("malformed storage must be reported") } catch {}

// Practice is one menu entry, with activities chosen before opening the window.
let menuController = AppController()
let practiceMenu = menuController.practiceMenuItem(wordShortcut: "o")
precondition(practiceMenu.title == "Practice" && practiceMenu.submenu != nil)
precondition(practiceMenu.submenu!.items.map(\.title) == ["Words", "Lessons", "Voice Practice"])
precondition(practiceMenu.submenu!.items.map(\.action) == [NSSelectorFromString("openWords"), NSSelectorFromString("openLessons"), NSSelectorFromString("openVoicePractice")])
precondition(practiceMenu.submenu!.items[0].keyEquivalent == "o")

// Word practice stays immediately usable, alongside restored lessons and spoken practice.
testDefaults.set(true, forKey: "wordSprintGuide") // The old persistent toggle must not reveal every word.
let firstPractice = PracticeWindowController(data: data, defaults: testDefaults, seed: { 42 }, focus: { true })
precondition(firstPractice.window!.title == "KeyChord · Words")
precondition(firstPractice.session.vocabulary == .english && firstPractice.session.goal == .words(10))
let firstInput = textViews(firstPractice.window!.contentView!).compactMap { $0 as? PracticeTypingInputView }.first!
firstInput.refreshFocus()
let hints: NSButton = state(firstPractice, "guideButton")
let guideCard: NSStackView = state(firstPractice, "guideCard")
precondition(firstInput.practice.chordEnabled && !guideCard.isHidden)
let keyboard: KeyboardDiagramView = state(firstPractice, "keyboard")
precondition(keyboard.target.isEmpty, "the keyboard stays visible without revealing an answer")
func awaitWordHint(_ keyboard: KeyboardDiagramView) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while keyboard.target.isEmpty && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    precondition(!keyboard.target.isEmpty, "a requested hint must finish planning")
}
hints.performClick(nil)
awaitWordHint(keyboard)
precondition(!keyboard.target.isEmpty, "the first practice word must have a usable chord hint")
precondition(firstPractice.session.startedAt == nil, "showing hints does not start a session")
// Right Option replaces a second input-mode selector and switches the actual local engine.
firstInput.process(.modifierDown(code: 61, key: .option, time: 10))
firstInput.process(.modifierUp(code: 61, key: .option, time: 100))
precondition(!firstInput.practice.chordEnabled && !guideCard.isHidden && keyboard.target.isEmpty && testDefaults.bool(forKey: "wordSprintKeyboard"))
firstInput.process(.modifierDown(code: 61, key: .option, time: 110))
firstInput.process(.modifierUp(code: 61, key: .option, time: 200))
precondition(firstInput.practice.chordEnabled && !guideCard.isHidden)
precondition(keyboard.target.isEmpty, "returning to chords does not restore a permanent hint toggle")
hints.performClick(nil)
awaitWordHint(keyboard)
let revealedKeys = keyboard.target
hints.performClick(nil)
awaitWordHint(keyboard)
precondition(keyboard.target == revealedKeys && firstPractice.session.startedAt == nil,
             "Hint is an action, and repeating it does not hide the keyboard or start the clock")
let firstWord = firstPractice.session.targetWords[0]
for character in firstWord + " " { firstInput.insertText(String(character), replacementRange: firstInput.selectedRange()) }
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
precondition(firstPractice.session.currentWordIndex == 1 && keyboard.target.isEmpty && !guideCard.isHidden,
             "a hint clears on the next word, even if an old asynchronous plan returns")
firstPractice.retryTest()
hints.performClick(nil); awaitWordHint(keyboard)
firstInput.relinquishFocus()

// Practice drives the real local NSTextView and scoring delegate, with no global events.
testDefaults.set("english", forKey: "wordSprintVocabulary")
testDefaults.set("words", forKey: "wordSprintGoal")
testDefaults.set(10, forKey: "wordSprintWords")
testDefaults.set(true, forKey: "wordSprintKeyboard")
var sprintNow = 100.0
var sprintFocused = true
var sprintLease = false
let sprint = PracticeWindowController(data: data, defaults: testDefaults, clock: { sprintNow }, seed: { 42 },
    focus: { sprintFocused }, globalSuspended: { sprintLease })
sprint.onLocalFocus = { sprintLease = $0 }
let sprintInput = textViews(sprint.window!.contentView!).compactMap { $0 as? PracticeTypingInputView }.first!
// Optional visual QA renders actual AppKit views, with no visible window or screen capture.
func sprintSnapshot(_ controller: PracticeWindowController, name: String, width: CGFloat = 940, height: CGFloat = 810,
                    appearance: NSAppearance.Name = .darkAqua) throws {
    guard let directory = ProcessInfo.processInfo.environment["KEYCHORD_PRACTICE_SNAPSHOTS"] else { return }
    controller.window!.setContentSize(NSSize(width: width, height: height))
    let view = controller.window!.contentView!
    view.layoutSubtreeIfNeeded()
    let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
    let document = scroll.documentView!
    controller.window!.appearance = NSAppearance(named: appearance)
    document.layoutSubtreeIfNeeded()
    if controller.section == .lessons {
        let pane: GuidedPracticePane = state(controller, "lessonPane")
        let workspace: NSStackView = state(pane, "workspace")
        let sidebar: NSBox? = state(pane, "browserSurface")
        precondition(abs(workspace.bounds.width - (pane.bounds.width - (sidebar!.isHidden ? 0 : 312))) < 1,
                     "the lesson workspace fills the width beside its course browser")
    }
    let pane: Any = controller.section == .words ? controller : state(controller, controller.section == .lessons ? "lessonPane" : "voicePane") as GuidedPracticePane
    let keyboard: KeyboardDiagramView = state(pane, "keyboard")
    let typing: PracticeTypingInputView = state(pane, "input")
    let inputRect = typing.enclosingScrollView!.convert(typing.enclosingScrollView!.bounds, to: document)
    let keyboardRect = keyboard.convert(keyboard.bounds, to: document)
    precondition(!keyboard.isHidden && keyboardRect.minY >= inputRect.maxY,
                 "every practice keyboard stays visible below the typing box")
    var captureView = document
    if controller.section == .lessons {
        let pane: GuidedPracticePane = state(controller, "lessonPane")
        if (state(pane, "completionOverlay") as LessonCompletionView?) != nil { captureView = view }
    }
    let size = captureView.bounds.size
    guard size.width > 0, size.height > 0,
          let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else { fatalError("empty sprint layout") }
    captureView.effectiveAppearance.performAsCurrentDrawingAppearance {
        document.wantsLayer = true
        document.layer?.backgroundColor = PracticeUI.pageColor.cgColor
        captureView.displayIfNeeded()
        captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
try sprintSnapshot(firstPractice, name: "practice-hints")
try sprintSnapshot(firstPractice, name: "practice-hints-narrow", width: 620)
try sprintSnapshot(sprint, name: "ready")
try sprintSnapshot(sprint, name: "ready-narrow", width: 620)
// Render the actual editor at normal and minimum widths for visual review.
if let directory = ProcessInfo.processInfo.environment["KEYCHORD_PRACTICE_SNAPSHOTS"] {
    func customSnapshot(_ controller: CustomChordsWindowController, name: String, width: Double = 980,
                        height: Double = 780, testing: Bool = false) throws {
        controller.window!.setContentSize(NSSize(width: width, height: height))
        if controller.window!.appearance == nil { controller.window!.appearance = NSAppearance(named: .aqua) }
        let view = controller.window!.contentView!
        view.layoutSubtreeIfNeeded()
        let form: NSScrollView = state(controller, "formScroll")
        form.documentView!.layoutSubtreeIfNeeded()
        if testing {
            let tryButton: NSButton = state(controller, "tryButton")
            tryButton.performClick(nil)
        } else {
            form.contentView.scroll(to: .zero); form.reflectScrolledClipView(form.contentView)
        }
        for name in ["saveButton", "tryButton", "cancelButton", "removeButton"] {
            let button: NSButton = state(controller, name)
            if !button.isHidden {
                let rect = button.convert(button.bounds, to: view)
                precondition(rect.minX >= 0 && rect.maxX <= view.bounds.width && rect.minY >= 0 && rect.maxY <= view.bounds.height,
                             "custom editor actions remain visible at the minimum size")
            }
        }
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            view.displayIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
    let showcase = CustomChordsWindowController(base: data, chords: [], testFocus: { true }) { _ in }
    showcase.recorder.beginRecording()
    for code: KeyCode in [1, 8, 38] { showcase.recorder.receive(.down(code)) }
    for code: KeyCode in [1, 8, 38] { showcase.recorder.receive(.up(code)) }
    let showcaseText: NSTextView = state(showcase, "text")
    showcaseText.string = "hello"
    showcase.textDidChange(Notification(name: NSText.didChangeNotification, object: showcaseText))
    let showcaseInput: LocalChordInputView = state(showcase, "testInput")
    draftTestChord("S+C+J", in: showcaseInput); draftTestChord("S+C+J", in: showcaseInput)
    try customSnapshot(showcase, name: "custom-chords")
    try customSnapshot(showcase, name: "custom-chords-narrow", width: 820, height: 620)
    try customSnapshot(showcase, name: "custom-chords-try", testing: true)
    try customSnapshot(showcase, name: "custom-chords-try-narrow", width: 820, height: 620, testing: true)
    showcase.window!.appearance = NSAppearance(named: .darkAqua)
    try customSnapshot(showcase, name: "custom-chords-dark")
    let pausedShowcase = CustomChordsWindowController(base: data, chords: [CustomChord(id: "paused", keyCodes: [1, 8, 38], text: "hello", isEnabled: false)]) { _ in }
    try customSnapshot(pausedShowcase, name: "custom-chords-off-narrow", width: 820, height: 620)
    let suggestShowcase = CustomChordsWindowController(base: data, chords: []) { _ in }
    let suggestButton: NSButton = state(suggestShowcase, "suggestionButton")
    suggestButton.performClick(nil)
    try customSnapshot(suggestShowcase, name: "custom-chords-suggestions")
}
sprintInput.refreshFocus()
precondition(sprintLease && sprintInput.practice.ownsInput && !sprintInput.practice.chordEnabled)
let sprintWords = sprint.session.targetWords
// A custom-chord save updates hints and input without restarting a passage or losing a result.
sprint.update(data: CustomChords.applying(roundTrip, to: data), rolloverLimit: 6, usable: { _ in true })
precondition(sprint.session.targetWords == sprintWords && !sprintInput.practice.chordEnabled)
sprintInput.insertText("x", replacementRange: sprintInput.selectedRange())
precondition(sprint.session.startedAt == sprintNow && sprint.session.typedText == "x")
sprintInput.deleteBackward(nil)
precondition(sprint.session.typedText.isEmpty && sprint.session.metrics(at: sprintNow).mistakes == 1)
sprintInput.paste(nil)
sprintInput.insertText(sprintWords.joined(separator: " "), replacementRange: sprintInput.selectedRange())
precondition(sprint.session.typedText.isEmpty, "bulk native insertion cannot earn a sprint result")
for character in sprintWords.joined(separator: " ") {
    sprintNow += 0.2
    sprintInput.insertText(String(character), replacementRange: sprintInput.selectedRange())
}
precondition(sprint.session.isFinished && !sprintInput.isEditable && !sprintLease)
precondition(sprint.session.metrics(at: sprintNow).correctWords == 10)
precondition(sprint.session.metrics(at: sprintNow).accuracy < 100)
precondition(!sprint.session.samples.isEmpty)
sprint.update(data: data, rolloverLimit: 6, usable: { _ in true })
precondition(sprint.session.isFinished && sprint.session.metrics(at: sprintNow).correctWords == 10)
try sprintSnapshot(sprint, name: "results")
try sprintSnapshot(sprint, name: "results-narrow", width: 620)
sprint.retryTest()
precondition(sprint.session.targetWords == sprintWords && sprintInput.string.isEmpty && sprintInput.isEditable)
precondition(sprint.session.startedAt == nil && sprint.session.metrics(at: sprintNow).mistakes == 0)

// A long passage follows the whole active word after edits, backtracking and window reflow.
func assertVisibleWord(_ controller: PracticeWindowController, width: CGFloat) {
    controller.window!.setContentSize(NSSize(width: width, height: 810))
    let content = controller.window!.contentView!
    content.layoutSubtreeIfNeeded()
    let outer = content.subviews.compactMap { $0 as? NSScrollView }.first!
    outer.documentView!.layoutSubtreeIfNeeded()
    let column = outer.documentView!.subviews.compactMap { $0 as? NSStackView }.first!
    precondition(abs(column.frame.width - (outer.contentView.bounds.width - 48)) < 1, "practice fills the available window width")
    let passage: PracticePassageView = state(controller, "passage")
    let clip = passage.enclosingScrollView!.contentView
    let manager = passage.layoutManager, container = passage.textContainer
    manager.ensureLayout(for: container)
    let range = passage.activeWordRange
    let visibleWord = (passage.string as NSString).substring(with: range)
    let index = min(controller.session.currentWordIndex, controller.session.targetWords.count - 1)
    precondition(visibleWord == controller.session.targetWords[index], "the viewport follows the current target word")
    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: passage.textContainerOrigin.x, dy: passage.textContainerOrigin.y)
    precondition(rect.minY >= clip.bounds.minY - 1 && rect.maxY <= clip.bounds.maxY + 1, "the active word stays fully visible vertically: \(rect), clip \(clip.bounds)")
    precondition(rect.minX >= -1 && rect.maxX <= clip.bounds.width + 1, "words wrap inside the viewport")
    precondition(passage.frame.width <= clip.bounds.width + 1 && container.containerSize.width <= clip.bounds.width + 1,
                 "the passage document fits its viewport: \(passage.frame), clip \(clip.bounds), container \(container.containerSize)")
}
let layoutSuite = "KeyChordWordLayoutChecks." + UUID().uuidString
let layoutDefaults = UserDefaults(suiteName: layoutSuite)!
defer { layoutDefaults.removePersistentDomain(forName: layoutSuite) }
layoutDefaults.set(true, forKey: "wordSprintKeyboard")
layoutDefaults.set(100, forKey: "wordSprintWords")
layoutDefaults.set(120, forKey: "wordSprintSeconds")
for size in [16, 30] {
    layoutDefaults.set(size, forKey: "practiceTextSize")
    for goal in ["words", "time"] {
        layoutDefaults.set(goal, forKey: "wordSprintGoal")
        var layoutNow = 100.0
        let longPractice = PracticeWindowController(data: data, defaults: layoutDefaults, clock: { layoutNow }, seed: { 42 }, focus: { true })
        let longInput: PracticeTypingInputView = state(longPractice, "input")
        assertVisibleWord(longPractice, width: 620)
        for index in 0..<(goal == "time" ? 160 : 100) {
            let word = longPractice.session.targetWords[index]
            for character in word + " " where !longPractice.session.isFinished {
                layoutNow += 0.01
                longInput.insertText(String(character), replacementRange: longInput.selectedRange())
            }
            if [10, 30, 74, 98, 149].contains(index) {
                for width: CGFloat in [620, 1655, 940, 620] { assertVisibleWord(longPractice, width: width) }
                if size == 30 && index == 74 {
                    try sprintSnapshot(longPractice, name: "words-\(goal)-in-progress-narrow", width: 620)
                    try sprintSnapshot(longPractice, name: "words-\(goal)-in-progress-wide", width: 1655, height: 1081)
                }
            }
        }
        assertVisibleWord(longPractice, width: 620)
        if goal == "time" {
            longInput.deleteBackward(nil)
            assertVisibleWord(longPractice, width: 620)
        } else { precondition(longPractice.session.isFinished) }
    }
}

// A delayed timer callback still finishes at the original deadline, including time out of focus.
testDefaults.set("time", forKey: "wordSprintGoal")
testDefaults.set(15, forKey: "wordSprintSeconds")
let timedSprint = PracticeWindowController(data: data, defaults: testDefaults, clock: { sprintNow }, seed: { 12 },
    focus: { sprintFocused })
let timedInput = textViews(timedSprint.window!.contentView!).compactMap { $0 as? PracticeTypingInputView }.first!
timedInput.insertText("x", replacementRange: timedInput.selectedRange())
let beganSprint = sprintNow
sprintFocused = false
timedInput.relinquishFocus()
sprintNow += 20
timedSprint.tick()
precondition(timedSprint.session.finishedAt == beganSprint + 15 && !timedInput.isEditable)

// Restarting an in-progress timed session must install a fresh timer and finish while idle.
timedSprint.newTest()
timedInput.insertText("x", replacementRange: timedInput.selectedRange())
timedSprint.newTest()
timedInput.insertText("x", replacementRange: timedInput.selectedRange())
let restartedAt = sprintNow
sprintNow += 20
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
precondition(timedSprint.session.finishedAt == restartedAt + 15 && !timedInput.isEditable)

// Replay the native planner through local key-down/up events, including multi-character word chords.
testDefaults.set("words", forKey: "wordSprintGoal")
testDefaults.set(false, forKey: "wordSprintKeyboard")
sprintFocused = true
var chordLease = false
let chordSprint = PracticeWindowController(data: data, defaults: testDefaults, clock: { sprintNow }, seed: { 99 },
    focus: { sprintFocused }, globalSuspended: { chordLease }, wordSource: ["making", "happiest", "tried", "lying", "stopping"])
chordSprint.onLocalFocus = { chordLease = $0 }
let chordInput = textViews(chordSprint.window!.contentView!).compactMap { $0 as? PracticeTypingInputView }.first!
chordInput.refreshFocus()
let chordHint: NSButton = state(chordSprint, "guideButton")
let chordKeyboard: KeyboardDiagramView = state(chordSprint, "keyboard")
chordHint.performClick(nil); awaitWordHint(chordKeyboard)
let sprintText = chordSprint.session.targetWords.joined(separator: " ")
let sprintPlan = TypingPlanner(data: data, mode: .english).plan(sprintText)
var refocusedChordPreview = false
for step in sprintPlan.steps {
    sprintNow += 0.3
    switch step.action {
    case .chord(let names, let shift):
        let chord = data.layout.keySet(names: names)!
        if shift { chordInput.process(.modifierDown(code: 56, key: .shift, time: UInt64(sprintNow * 1000))) }
        for index in chord.indices {
            chordInput.process(.keyDown(code: data.layout.keys[index].code, isRepeat: false, flags: [], time: UInt64(sprintNow * 1000)))
        }
        for index in chord.indices {
            chordInput.process(.keyUp(code: data.layout.keys[index].code, flags: [], time: UInt64(sprintNow * 1000)))
        }
        if shift { chordInput.process(.modifierUp(code: 56, key: .shift, time: UInt64(sprintNow * 1000))) }
    case .typeNormally(let text):
        for character in text { chordInput.insertText(String(character), replacementRange: chordInput.selectedRange()) }
    case .key(let key):
        if key == .delete { chordInput.deleteBackward(nil) }
    }
    if !step.tail.isEmpty && !chordSprint.session.isFinished {
        sprintFocused = false
        chordInput.relinquishFocus()
        precondition(!chordLease)
        sprintFocused = true
        chordInput.refreshFocus()
        refocusedChordPreview = true
    }
    if chordSprint.session.currentWordIndex > 0 {
        precondition((state(chordSprint, "hintedWord") as Int?) == nil && chordKeyboard.target.isEmpty,
                     "suffix and multi-chord hints do not carry into the next word")
    }
}
precondition(chordInput.string == sprintText && chordSprint.session.isFinished, "local chord test must match the target and finish")
precondition(chordSprint.session.metrics(at: sprintNow).accuracy == 100)
precondition(refocusedChordPreview, "suffix previews must continue correctly after refocusing")
precondition(!chordLease)

// Exercise real window shortcuts while the typing view owns focus. Speech is injected and silent.
final class RecordingSpeaker: PracticeSpeaking {
    var isAvailable = true
    var utterances: [String] = []
    var stops = 0
    func speak(_ text: String) -> Bool {
        guard isAvailable else { return false }
        utterances.append(text)
        return true
    }
    func stop() { stops += 1 }
}
func shortcut(_ controller: PracticeWindowController, key: String, flags: NSEvent.ModifierFlags, code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
        windowNumber: controller.window!.windowNumber, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    precondition(controller.window!.performKeyEquivalent(with: event))
}
func awaitPlan(_ pane: GuidedPracticePane) {
    let deadline = Date(timeIntervalSinceNow: 30)
    while (state(pane, "preparing") as Bool) && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    precondition(!(state(pane, "preparing") as Bool) && pane.guide != nil, "practice must finish planning")
}
func playGuide(_ guide: TypingGuide, into input: PracticeTypingInputView, afterStep: ((TypingStep) -> Void)? = nil) {
    for step in guide.steps {
        switch step.action {
        case .chord(let names, let shift):
            let keys = data.layout.keySet(names: names)!
            if shift { input.process(.modifierDown(code: 56, key: .shift, time: 1)) }
            for index in keys.indices { input.process(.keyDown(code: data.layout.keys[index].code, isRepeat: false, flags: shift ? .shift : [], time: 2)) }
            for index in keys.indices { input.process(.keyUp(code: data.layout.keys[index].code, flags: shift ? .shift : [], time: 3)) }
            if shift { input.process(.modifierUp(code: 56, key: .shift, time: 4)) }
        case .key(.returnKey): input.insertText("\n", replacementRange: input.selectedRange())
        case .key(.tab): input.insertText("\t", replacementRange: input.selectedRange())
        case .key(.delete): input.deleteBackward(nil)
        case .typeNormally: preconditionFailure("lessons and listening should be available through chords")
        }
        afterStep?(step)
    }
}
// A one-word hint includes punctuation attached to that word, even when the planner
// splits it into separate syllable, suffix and punctuation groups.
let punctuatedHintText = "It's well-made; (hello) end."
let punctuatedHintPlan = TypingPlanner(data: data, mode: .english).plan(punctuatedHintText)
var hintedTokens: Set<String> = []
for step in punctuatedHintPlan.steps {
    let range = PracticeHints.wordRange(for: step, in: punctuatedHintText)
    let token = String(Array(punctuatedHintText)[range])
    precondition(["It's", "well-made;", "(hello)", "end."].contains(token),
                 "hints cover exactly one visible word, including its punctuation")
    hintedTokens.insert(token)
}
precondition(hintedTokens == ["It's", "well-made;", "(hello)", "end."])
let lessonsSuite = "KeyChordLessonChecks." + UUID().uuidString
let lessonsDefaults = UserDefaults(suiteName: lessonsSuite)!
defer { lessonsDefaults.removePersistentDomain(forName: lessonsSuite) }
lessonsDefaults.set(["first-chord"], forKey: "courseCompleted")
lessonsDefaults.set("first-chord", forKey: "courseLastStep")
let spoken = RecordingSpeaker()
var guidedFocused = true
let restored = PracticeWindowController(data: data, defaults: lessonsDefaults, seed: { 42 },
    focus: { guidedFocused }, makeSpeaker: { spoken })
let restoredInput: PracticeTypingInputView = state(restored, "input")
restoredInput.refreshFocus()
shortcut(restored, key: "H", flags: [.command, .shift], code: 4)
let restoredKeyboard: KeyboardDiagramView = state(restored, "keyboard")
awaitWordHint(restoredKeyboard)
precondition(restoredInput.string.isEmpty && restored.session.startedAt == nil)
shortcut(restored, key: "H", flags: [.command, .shift], code: 4)
awaitWordHint(restoredKeyboard)
precondition(!restoredKeyboard.target.isEmpty)
restored.selectSection(.lessons)
let lessons: GuidedPracticePane = state(restored, "lessonPane")
awaitPlan(lessons)
precondition(restored.section == .lessons && Course.steps[lessons.courseIndex].id == "vowels")
precondition(restored.window!.title == "KeyChord · Lessons")
precondition(CourseProgress(defaults: lessonsDefaults).completed.contains("first-ends"), "legacy progress must migrate and resume")
precondition(!restoredInput.practice.ownsInput, "switching sections releases the previous local lease")
// Collapsing the course gives the lesson the entire workspace and survives resizing and navigation.
let lessonInput: PracticeTypingInputView = state(lessons, "input")
let courseToggle: NSButton = state(lessons, "browseButton")
let sidebar: NSBox? = state(lessons, "browserSurface")
restored.window!.setContentSize(NSSize(width: 1655, height: 1081))
restored.window!.contentView!.layoutSubtreeIfNeeded()
precondition(!sidebar!.isHidden && !courseToggle.isHidden)
lessonInput.insertText("x", replacementRange: lessonInput.selectedRange())
let courseBeforeCollapse = lessons.courseIndex
courseToggle.performClick(nil)
precondition(sidebar!.isHidden && lessonInput.string == "x" && lessons.courseIndex == courseBeforeCollapse)
precondition(lessonsDefaults.bool(forKey: "lessonSidebarCollapsed"))
try sprintSnapshot(restored, name: "practice-lessons-collapsed", width: 1655, height: 1081)
restored.window!.setContentSize(NSSize(width: 620, height: 810))
restored.window!.contentView!.layoutSubtreeIfNeeded()
restored.window!.setContentSize(NSSize(width: 1655, height: 1081))
restored.window!.contentView!.layoutSubtreeIfNeeded()
precondition(sidebar!.isHidden, "resizing must not reopen a collapsed course")
courseToggle.performClick(nil)
precondition(!sidebar!.isHidden && !lessonsDefaults.bool(forKey: "lessonSidebarCollapsed"))
lessonInput.deleteBackward(nil)
let browser: LessonBrowserView = state(lessons, "lessonBrowser")
let lessonSearch: NSSearchField = state(browser, "search")
lessonSearch.stringValue = "COLON"
browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lessonSearch))
let lessonRows: NSStackView = state(browser, "rows")
let foundLessons = lessonRows.arrangedSubviews.compactMap { $0 as? NSButton }
precondition(foundLessons.count == 1 && foundLessons[0].title.contains("Colon"), "the course browser finds lessons without opening a giant dropdown")
foundLessons[0].performClick(nil)
awaitPlan(lessons)
precondition(lessons.courseIndex == foundLessons[0].tag)
lessonSearch.stringValue = ""
browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lessonSearch))
let lessonLanguage: NSSegmentedControl = state(browser, "language")
lessonLanguage.selectedSegment = 1
_ = NSApp.sendAction(lessonLanguage.action!, to: lessonLanguage.target, from: lessonLanguage)
awaitPlan(lessons)
precondition(Course.steps[lessons.courseIndex].mode == .cpp)
lessons.openLesson(0)
awaitPlan(lessons)
let lessonResults: NSButton = state(lessons, "resultsButton")
precondition(lessonResults.isHidden && (state(lessons, "completionOverlay") as LessonCompletionView?) == nil)
shortcut(restored, key: "\r", flags: [.command], code: 36)
precondition(lessons.courseIndex == 0, "Next lesson is available only after finishing")
playGuide(lessons.guide!, into: lessonInput)
precondition(lessons.isFinished && lessonInput.string == Course.steps[0].text && !lessonInput.isEditable)
precondition(CourseProgress(defaults: lessonsDefaults).completed.contains("first-chord"))
let lessonKeyboard: KeyboardDiagramView = state(lessons, "keyboard")
let lessonCard: NSStackView = state(lessons, "guideCard")
precondition(!lessonCard.isHidden && lessonKeyboard.target.isEmpty,
             "completing a lesson keeps the keyboard visible and clears its answer")
let completedLesson: LessonCompletionView? = state(lessons, "completionOverlay")
precondition(completedLesson != nil && !lessonResults.isHidden)
precondition(restored.window!.firstResponder === completedLesson!.continueButton && !lessonInput.practice.ownsInput,
             "completion hands focus to the dialog and releases chord capture")
precondition((state(lessons, "lessonProgress") as LessonProgressView).fraction == 1)
try sprintSnapshot(restored, name: "practice-lesson-complete", width: 1655, height: 1081)
try sprintSnapshot(restored, name: "practice-lesson-complete-narrow", width: 620)
try sprintSnapshot(restored, name: "practice-lesson-complete-light", width: 940, appearance: .aqua)
shortcut(restored, key: "\u{1b}", flags: [], code: 53)
precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil && lessons.isFinished)
lessonResults.performClick(nil)
let reopenedResults: LessonCompletionView? = state(lessons, "completionOverlay")
precondition(reopenedResults != nil)
let tryAgain: NSButton = state(reopenedResults!, "retryButton")
tryAgain.performClick(nil)
awaitPlan(lessons)
precondition(lessons.courseIndex == 0 && lessonInput.string.isEmpty && !lessons.isFinished && lessonResults.isHidden)
precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil)
playGuide(lessons.guide!, into: lessonInput)
shortcut(restored, key: "\r", flags: [.command], code: 36)
awaitPlan(lessons)
precondition(lessons.courseIndex == 1 && lessonInput.string.isEmpty && lessonInput.isEditable)
shortcut(restored, key: "H", flags: [.command, .shift], code: 4)
precondition(lessons.isHintRevealed && lessonInput.string.isEmpty && !lessonKeyboard.target.isEmpty)
playGuide(lessons.guide!, into: lessonInput) { _ in
    if lessonInput.string == "a" {
        precondition((state(lessons, "hintedWord") as Range<Int>?) == nil,
                     "the known word request expires before a following automatic introduction")
    }
}

// Only the first use of each newly taught combination is shown automatically.
lessonsDefaults.set(true, forKey: "lessonPracticeHints")
lessons.openLesson(Course.index(of: "vowels")!)
awaitPlan(lessons)
precondition(lessons.isHintRevealed && !lessonKeyboard.target.isEmpty)
var introductionChecks = 0
playGuide(lessons.guide!, into: lessonInput) { _ in
    switch lessonInput.string {
    case "he", "he set ten on":
        precondition(!lessons.isHintRevealed && lessonKeyboard.target.isEmpty,
                     "repeated combinations require another Hint request")
        introductionChecks += 1
    case "he set ten":
        precondition(lessons.isHintRevealed && !lessonKeyboard.target.isEmpty,
                     "the first o combination is introduced when it reaches the keyboard")
        introductionChecks += 1
    default: break
    }
}
precondition(introductionChecks >= 3 && lessons.isFinished)
let nextFromPopup: LessonCompletionView? = state(lessons, "completionOverlay")
precondition(nextFromPopup != nil)
let finishedIndex = lessons.courseIndex
shortcut(restored, key: "\r", flags: [], code: 36)
awaitPlan(lessons)
precondition(lessons.courseIndex == finishedIndex + 1 && !lessons.isFinished && lessonInput.string.isEmpty)
precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil)

// Review lessons have no automatic answers; a requested hint survives all chords of one word.
lessons.openLesson(Course.index(of: "syllables-review")!)
awaitPlan(lessons)
precondition(!lessons.isHintRevealed && lessonKeyboard.target.isEmpty)
let reviewWordEnd = lessons.guide!.steps[0].source.upperBound
lessons.requestHint()
precondition(lessons.isHintRevealed)
playGuide(lessons.guide!, into: lessonInput) { step in
    if step.textEnd >= reviewWordEnd {
        precondition(!lessons.isHintRevealed && lessonKeyboard.target.isEmpty,
                     "manual hints cover exactly one word in a review lesson")
    }
}
// A suffix rewrite and C++ punctuation/Return follow their own planner contexts after refocusing.
for id in ["ing-er", "cpp-symbols", "cpp-symbols-braces"] {
    if let index = Course.index(of: id) {
        lessons.openLesson(index)
        awaitPlan(lessons)
        guidedFocused = false; lessonInput.relinquishFocus()
        guidedFocused = true; lessonInput.refreshFocus()
        playGuide(lessons.guide!, into: lessonInput) { _ in
            if lessonInput.isEditable {
                guidedFocused = false; lessonInput.relinquishFocus()
                guidedFocused = true; lessonInput.refreshFocus()
            }
        }
        precondition(lessons.isFinished && lessonInput.string == Course.steps[index].text, "restored lesson must replay: " + id)
    }
}
// Finishing either language offers its course browser rather than skipping into another language.
for mode in [SubMode.english, .cpp] {
    let last = Course.steps.lastIndex { $0.mode == mode }!
    lessons.openLesson(last); awaitPlan(lessons)
    playGuide(lessons.guide!, into: lessonInput)
    let result: LessonCompletionView? = state(lessons, "completionOverlay")
    precondition(lessons.isFinished && result?.continueButton.title == "Back to course")
    try sprintSnapshot(restored, name: "practice-lesson-end-\(mode == .english ? "english" : "cpp")", width: 1655, height: 1081)
    result!.continueButton.performClick(nil)
    precondition(lessons.courseIndex == last && !sidebar!.isHidden)
    precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil)
}
// Ordinary typing can match a passage but cannot mark a lesson complete.
lessons.openLesson(2); awaitPlan(lessons)
try sprintSnapshot(restored, name: "practice-lessons-new-combination", width: 940)
let ordinaryLesson = Course.index(of: "top-row-ends")!
lessons.openLesson(ordinaryLesson); awaitPlan(lessons)
for character in lessons.targetText { lessonInput.insertText(String(character), replacementRange: lessonInput.selectedRange()) }
precondition(!lessons.isFinished && !CourseProgress(defaults: lessonsDefaults).completed.contains(Course.steps[ordinaryLesson].id))
precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil && lessonResults.isHidden,
             "ordinary text cannot show a completion dialog")
try sprintSnapshot(restored, name: "practice-lessons")
try sprintSnapshot(restored, name: "practice-lessons-narrow", width: 620)
try sprintSnapshot(restored, name: "practice-lessons-wide", width: 1655, height: 1081)
shortcut(restored, key: "H", flags: [.command, .shift], code: 4)
try sprintSnapshot(restored, name: "practice-lessons-wide-hints", width: 1655, height: 1081)
try sprintSnapshot(restored, name: "practice-lessons-wide-light", width: 1655, height: 1081, appearance: .aqua)
courseToggle.performClick(nil)
try sprintSnapshot(restored, name: "practice-lessons-collapsed-light", width: 1655, height: 1081, appearance: .aqua)
try sprintSnapshot(restored, name: "practice-lessons-collapsed-dark", width: 1655, height: 1081)
let rememberedPane = GuidedPracticePane(kind: .lessons, data: data, rolloverLimit: 6, usable: { _ in true },
    defaults: lessonsDefaults, globalSuspended: { true }, speaker: spoken)
precondition(state(rememberedPane, "sidebarCollapsed") as Bool, "a newly opened pane restores the course visibility")
courseToggle.performClick(nil)
lessons.openLesson(Course.index(of: "quotes")!); awaitPlan(lessons)
try sprintSnapshot(restored, name: "practice-quotes-sidebar", width: 1655, height: 1081)
try sprintSnapshot(restored, name: "practice-quotes-sidebar-light", width: 1655, height: 1081, appearance: .aqua)
let lessonPosition: NSTextField = state(lessons, "position")
precondition(lessonPosition.bounds.height > 10, "unit and course progress remain visible in the lesson header")
courseToggle.performClick(nil)
try sprintSnapshot(restored, name: "practice-quotes-focused", width: 1655, height: 1081)
playGuide(lessons.guide!, into: lessonInput)
try sprintSnapshot(restored, name: "practice-quotes-complete", width: 1655, height: 1081)

restored.selectSection(.voice)
precondition((state(lessons, "completionOverlay") as LessonCompletionView?) == nil,
             "changing activities removes lesson results from the window")
let voice: GuidedPracticePane = state(restored, "voicePane")
awaitPlan(voice)
let voiceInput: PracticeTypingInputView = state(voice, "input")
let voiceCard: NSStackView = state(voice, "guideCard")
let voicePassage: NSTextField = state(voice, "passage")
precondition(restored.section == .voice && !voiceCard.isHidden && voicePassage.isHidden && !voice.isHintRevealed)
precondition(spoken.utterances.last!.contains(voice.targetText))
let wordToRepeat = voice.targetText
shortcut(restored, key: "R", flags: [.command, .shift], code: 15)
precondition(spoken.utterances.last == wordToRepeat && voiceInput.string.isEmpty)
shortcut(restored, key: "H", flags: [.command, .shift], code: 4)
precondition(!voiceCard.isHidden && !voicePassage.isHidden && voice.listeningPractice!.hintRevealed)
let spokenKeyNames = spoken.utterances.last!.replacingOccurrences(of: ". ", with: ", ").components(separatedBy: ", ")
let allowedSpokenKeys = Set(data.layout.keys.map { KeyboardDiagramView.name(for: $0.code) }
    + ["Shift", "Semicolon", "Quote", "Left bracket", "Right bracket", "Backslash", "Comma", "Period", "Slash", "Equal", "Minus"])
let expectedKeyCount = voice.guide!.steps.reduce(0) { total, step in
    guard case .chord(let names, let shift) = step.action else { preconditionFailure("expected word chords") }
    return total + names.count + (shift ? 1 : 0)
}
precondition(spokenKeyNames.count == expectedKeyCount && spokenKeyNames.allSatisfy { allowedSpokenKeys.contains($0) },
    "spoken hints contain only the key names")
voiceInput.insertText("#", replacementRange: voiceInput.selectedRange())
precondition(voice.targetText == wordToRepeat && spoken.utterances.last!.contains("Not quite"))
voiceInput.deleteBackward(nil)
playGuide(voice.guide!, into: voiceInput)
precondition(voice.listeningPractice!.completedWords == 1 && voice.listeningPractice!.assistedWords == 1)
precondition(voiceInput.string.isEmpty && !voiceCard.isHidden && !voice.isHintRevealed && voicePassage.isHidden && spoken.utterances.last!.contains("Correct. Word 2"))
// Bulk insertion and ordinary text never advance a spoken session.
voiceInput.insertText(voice.targetText, replacementRange: voiceInput.selectedRange())
precondition(voiceInput.string.isEmpty)
for character in voice.targetText { voiceInput.insertText(String(character), replacementRange: voiceInput.selectedRange()) }
precondition(voice.listeningPractice!.completedWords == 1 && !voice.isFinished)
shortcut(restored, key: "r", flags: [.command], code: 15)
for _ in 1..<10 { playGuide(voice.guide!, into: voiceInput) }
precondition(voice.isFinished && voice.listeningPractice!.completedWords == 10 && !voiceInput.isEditable)
precondition(spoken.utterances.last!.contains("Voice practice complete"))
try sprintSnapshot(restored, name: "practice-voice-results")
shortcut(restored, key: "r", flags: [.command], code: 15)
awaitPlan(voice)
try sprintSnapshot(restored, name: "practice-voice")
try sprintSnapshot(restored, name: "practice-voice-narrow", width: 620)
let stopsBeforeLeaving = spoken.stops
restored.selectSection(.words)
precondition(spoken.stops > stopsBeforeLeaving && !voiceInput.practice.ownsInput && restored.section == .words)
// An unavailable voice provides explicit recovery and reveals the word instead of silently failing.
spoken.isAvailable = false
restored.selectSection(.voice)
let voiceStatus: NSTextField = state(voice, "status")
precondition(voiceStatus.stringValue.contains("No English voice") && !voicePassage.isHidden)
restored.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: restored.window))
precondition(!voiceInput.practice.ownsInput)

print("AppKit checks passed: custom chords, word scoring, focus, retries and deadlines; restored lessons, legacy progress, English/C++ plans, hint shortcuts, spoken feedback, automatic advancement and speech cleanup.")
