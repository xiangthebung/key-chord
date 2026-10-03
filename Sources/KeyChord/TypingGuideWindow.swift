// Typing Guide: a typeracer-style practice window. The passage is shown at the top, colored as you type
// into the box below it. Only the current word's chord combination is shown, and a keyboard diagram
// (the MacBook's US or Canadian French keyboard) shows the keys to press next and the keys actually held.
// The plan comes from TypingPlanner (KeyChordCore), which checks every step against the Chord_Engine.
// The text and what is typed stay in memory only; only aggregate practice performance is saved.

import AppKit
import KeyChordCore
import UniformTypeIdentifiers

/// A physical key going down or up, forwarded from the event tap before chord keys are held back.
enum RawKeyEvent {
    case down(KeyCode)
    case up(KeyCode)
}

final class TypingGuideWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    /// Called when the window becomes or stops being the key window.
    var onFocus: ((Bool) -> Void)?
    /// Asks KeyChord to forget the text before the cursor (so the first chord gets no leading space).
    var onResetContext: (() -> Void)?
    /// Puts KeyChord's output context (spacing, pending capital) where the plan expects it. Used after the
    /// user fixes a mistake: Delete resets the context, so without this the next chord would lose its space
    /// or its capital.
    var onSyncContext: ((EngineContext) -> Void)?
    /// Keeps the router's sub-mode aligned with the selected practice mode.
    var onPracticeModeChanged: ((SubMode) -> Void)?
    /// What the Matrix Scan found; blocked chords are never suggested. Takes effect on the next plan.
    var limits: KeyboardLimits?
    /// Saved course progress: finishing a step marks it done.
    var progress: CourseProgress? { didSet { rebuildLessonMenu() } }
    private let practiceSettings = Settings()
    private let performance = PracticePerformanceStore()
    private var recallMode = false
    private var hintRevealed = false
    private var displayedStep: TypingStep?
    private var promptBeganAt = ProcessInfo.processInfo.systemUptime
    private var typingMode: SubMode?
    private var reviewing = false
    private var reviewGeneration = 0
    private var reviewTargets: [PracticeChord] = []
    private struct Attempt {
        let step: TypingStep
        let target: PracticeChord
        let context: EngineContext
        let beganAt: Double
        var assisted: Bool
    }
    private var attempt: Attempt?
    private var chordShift = false
    private var scoredMistakes = 0

    // Course
    /// The course step being practiced, when the text is one.
    private(set) var courseStep: Int?
    private var wasFinished = false
    private let courseCard = NSBox()
    private let courseTitle = NSTextField(labelWithString: "")
    private let coursePosition = NSTextField(labelWithString: "")
    private let courseIntro = NSTextField(wrappingLabelWithString: "")
    /// What the step introduces, with its keys.
    private let courseNew = NSTextField(wrappingLabelWithString: "")
    private let previousButton = NSButton(title: "‹ Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next ›", target: nil, action: nil)
    /// Tags of practice texts in the lesson menu start here; course steps use their index.
    private static let practiceTagBase = 10_000

    private let tapIsRunning: () -> Bool
    private var data: EngineData
    private var rolloverLimit: Int
    private var mode: SubMode

    // Passage
    private var fileName: String?
    private var text = ""
    private var chars: [Character] = []
    private var targetUTF16: [unichar] = []
    /// UTF-16 offset of each character boundary, to map planner offsets to NSRange.
    private var utf16Offsets: [Int] = [0]
    /// Character offset where each word of the passage ends, for the word counter.
    private var wordEnds: [Int] = []
    /// The plan for the whole passage.
    private var guide: TypingGuide?
    /// The plan for the rest of the line when the typed text is not where the whole-passage plan expects it,
    /// for example after part of a word and Delete ("an" of "anything": the chords for "ything").
    private var continuation: TypingContinuation?
    /// The plan being followed at the cursor: the continuation, or the whole-passage plan.
    private var active: TypingGuide?
    /// Plans continuations on the main thread, with the same data as `guide`.
    private var continuationPlanner: TypingPlanner?
    private var generation = 0

    // Progress
    private var correctUTF16 = 0
    private var correct = 0                 // characters typed correctly from the start
    private var hasError = false
    private var editFloor = Int.max         // lowest UTF-16 offset edited since the last refresh
    private var currentStep: Int?
    private var currentGroup: Int?
    /// Steps with no visible output (commands, the Delete after a throwaway letter), confirmed by the chord.
    private var doneSteps = Set<Int>()
    private var startTime: Date?
    private var finishTime: Date?
    private var mistakes = 0
    private var lastTypedLen = 0
    private var styled = (correct: 0, typedEnd: 0, word: NSRange(location: 0, length: 0))

    // Keys
    private var held = Set<KeyCode>()
    private var chordCodes = Set<KeyCode>()
    private var monitor: Any?

    /// Planning a 300 KB file took about 1.6 s in a release build, so 1 MB stays around 5 s.
    private static let maxFileBytes = 1_000_000
    private static let modifierCodes: Set<KeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let sampleEnglish =
        "We are going to learn to type with chords. Press all the keys of a chord together, then let them go. "
        + "The first words are the hardest, but it gets easier with time."
    private static let sampleCpp = "int main() {\n    std::vector<int> values;\n    return 0;\n}"

    // UI
    private var passageView: NSTextView!
    private var inputView: NSTextView!
    private let keyboard = KeyboardDiagramView()
    private let modePopup = NSPopUpButton()
    private let lessonMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let statsLabel = NSTextField(labelWithString: "")
    private let wordLabel = NSTextField(labelWithString: "")
    private let comboLabel = NSTextField(labelWithString: "")
    /// What the current chord's keys stand for: "th (E T) · i (M) · ng (K L)".
    private let partsLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    /// Colors of the keyboard and the keys with a job of their own.
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let recallToggle = NSButton(checkboxWithTitle: "Recall mode", target: nil, action: nil)
    private let hintButton = NSButton(title: "Show Hint", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review Weak Chords", target: nil, action: nil)
    private let referenceButton = NSButton(title: "Show Reference", target: nil, action: nil)
    private let typingStatus = NSTextField(labelWithString: "Chord typing off · tap right Option to start")
    private let performanceLabel = NSTextField(labelWithString: "")
    private let reviewLabel = NSTextField(wrappingLabelWithString: "")

    init(data: EngineData, rolloverLimit: Int, mode: SubMode, tapIsRunning: @escaping () -> Bool) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.mode = mode
        self.tapIsRunning = tapIsRunning
        recallMode = practiceSettings.recallPractice
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "KeyChord Typing Practice"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 700)
        super.init(window: w)
        w.delegate = self
        buildUI()
        keyboard.layout = data.layout
        updateMeanings()
        setText(Self.sample(for: mode), name: nil)
        w.center()
    }

    /// Labels the keyboard with what each key means in the current mode, and explains the colors below it.
    private func updateMeanings() {
        let m = KeyMeanings(data: data, mode: mode)
        keyboard.meanings = m
        legendLabel.attributedStringValue = Self.legend(m, layout: data.layout)
        updatePracticeControls()
    }

    /// "● start of a syllable ● vowel ● end of a syllable ● spell ● punctuation and commands", then the keys that
    /// do something together.
    static func legend(_ m: KeyMeanings, layout: Layout) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = .secondaryLabelColor, bold: Bool = false) {
            out.append(NSAttributedString(string: s, attributes: [
                .font: bold ? NSFont.systemFont(ofSize: 12, weight: .semibold) : font, .foregroundColor: color]))
        }
        let roles: [(KeyMeanings.Role, String)] = [(.onset, "start of a syllable"), (.vowel, "vowel"),
                                                   (.coda, "end of a syllable"), (.spell, "spell a letter"),
                                                   (.special, "punctuation, endings and commands")]
        for (i, (role, text)) in roles.enumerated() {
            if i > 0 { add("    ") }
            add("● ", KeyboardDiagramView.color(for: role))
            add(text)
        }
        // Keys by the legend printed on them, as in the chords above the keyboard.
        func name(_ index: Int) -> String { KeyboardDiagramView.name(for: layout.keys[index].code) }
        func keys(_ k: KeySet) -> String { k.indices.map(name).joined(separator: " + ") }
        var combos: [(String, String)] = [("space bar + a chord", "join it to the word before")]
        if let s = m.spellKey {
            combos.append((name(s) + " + a letter", "spell that letter"))
            if let c = m.capitalKey { combos.append((name(s) + " + " + name(c) + " + a letter", "capital letter")) }
        }
        if let k = m.capitalizeNextKeys { combos.append((keys(k), "capital on the next word")) }
        if let k = m.undoKeys { combos.append((keys(k), "undo the last chord")) }
        if let k = m.modeSwitchKeys { combos.append((keys(k), "switch English / C++")) }
        combos.append(("right ⌥", "chord typing on / off"))
        add("\n")
        for (i, (k, what)) in combos.enumerated() {
            if i > 0 { add("   ·   ") }
            add(k, .labelColor, bold: true)
            add("  " + what)
        }
        return out
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func sample(for mode: SubMode) -> String { mode == .cpp ? sampleCpp : sampleEnglish }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let importButton = NSButton(title: "Import Text…", target: self, action: #selector(importFile))
        importButton.keyEquivalent = "o"
        importButton.keyEquivalentModifierMask = [.command]
        rebuildLessonMenu()
        lessonMenu.target = self
        lessonMenu.action = #selector(lessonChosen(_:))
        lessonMenu.setAccessibilityLabel("Course steps and practice texts")
        let restartButton = NSButton(title: "Restart", target: self, action: #selector(restart))
        restartButton.keyEquivalent = "r"
        restartButton.keyEquivalentModifierMask = [.command]
        modePopup.addItems(withTitles: ["English", "C++"])
        modePopup.selectItem(at: mode == .english ? 0 : 1)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.setAccessibilityLabel("Chord mode for the practice text")
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statsLabel.alignment = .right
        statsLabel.lineBreakMode = .byTruncatingHead
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [lessonMenu, importButton, restartButton, modePopup, spacer, statsLabel])
        header.orientation = .horizontal
        header.spacing = 8

        recallToggle.target = self
        recallToggle.action = #selector(recallChanged)
        recallToggle.state = recallMode ? .on : .off
        recallToggle.toolTip = "Try each chord from memory. Show Hint reveals only the current chord."
        hintButton.target = self
        hintButton.action = #selector(revealHint)
        hintButton.keyEquivalent = "h"
        hintButton.keyEquivalentModifierMask = [.command, .shift]
        hintButton.toolTip = "Reveal the current chord (⌘⇧H)."
        reviewButton.target = self
        reviewButton.action = #selector(reviewWeakChords)
        reviewButton.toolTip = "Practice the chords you miss or take longest to recall. Performance is saved locally."
        referenceButton.target = self
        referenceButton.action = #selector(toggleReference)
        let practiceSpacer = NSView()
        practiceSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let practiceControls = NSStackView(views: [recallToggle, hintButton, reviewButton, practiceSpacer, referenceButton])
        practiceControls.orientation = .horizontal
        practiceControls.spacing = 8
        reviewLabel.font = .systemFont(ofSize: 12)
        reviewLabel.textColor = .secondaryLabelColor
        reviewLabel.isHidden = true

        // Passage: the text to type, colored as it is typed.
        let passageScroll = NSTextView.scrollableTextView()
        passageView = (passageScroll.documentView as! NSTextView)
        passageView.isEditable = false
        passageView.isSelectable = false
        passageView.isRichText = false
        passageView.textContainerInset = NSSize(width: 12, height: 12)
        passageView.setAccessibilityLabel("Text to type")
        passageScroll.hasVerticalScroller = true
        passageScroll.borderType = .bezelBorder

        // Current word and its chord combination.
        wordLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboLabel.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        comboLabel.lineBreakMode = .byTruncatingTail
        comboLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboLabel.setAccessibilityLabel("Chords for the current word")
        partsLabel.font = .systemFont(ofSize: 15)
        partsLabel.lineBreakMode = .byTruncatingTail
        partsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        partsLabel.setAccessibilityLabel("What the keys of the chord stand for")
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabelColor
        let wordRow = NSStackView(views: [wordLabel, comboLabel])
        wordRow.orientation = .horizontal
        wordRow.alignment = .firstBaseline
        wordRow.spacing = 24

        // Input: where the chord output lands.
        let inputScroll = NSTextView.scrollableTextView()
        inputView = (inputScroll.documentView as! NSTextView)
        inputView.isRichText = false
        inputView.allowsUndo = true
        inputView.font = .systemFont(ofSize: 20)
        inputView.textContainerInset = NSSize(width: 8, height: 8)
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.isAutomaticTextReplacementEnabled = false
        inputView.isAutomaticSpellingCorrectionEnabled = false
        inputView.isContinuousSpellCheckingEnabled = false
        inputView.isGrammarCheckingEnabled = false
        inputView.isAutomaticTextCompletionEnabled = false
        inputView.smartInsertDeleteEnabled = false
        inputView.delegate = self
        inputView.setAccessibilityLabel("Type here")
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder

        typingStatus.font = .systemFont(ofSize: 12, weight: .medium)
        typingStatus.setContentCompressionResistancePriority(.required, for: .horizontal)
        performanceLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        performanceLabel.textColor = .secondaryLabelColor
        performanceLabel.alignment = .right
        performanceLabel.lineBreakMode = .byTruncatingHead
        performanceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inputSpacer = NSView()
        inputSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let inputHeader = NSStackView(views: [typingStatus, inputSpacer, performanceLabel])
        inputHeader.orientation = .horizontal
        inputHeader.spacing = 8

        // Course step: what it teaches and what is new, with Previous and Next.
        courseTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        courseTitle.lineBreakMode = .byTruncatingTail
        courseTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        coursePosition.font = .systemFont(ofSize: 12)
        coursePosition.textColor = .secondaryLabelColor
        courseIntro.font = .systemFont(ofSize: 13)
        previousButton.target = self
        previousButton.action = #selector(previousStep)
        previousButton.keyEquivalent = "["
        previousButton.keyEquivalentModifierMask = [.command]
        previousButton.toolTip = "Previous step (⌘[)"
        nextButton.target = self
        nextButton.action = #selector(nextStep)
        nextButton.keyEquivalent = "]"
        nextButton.keyEquivalentModifierMask = [.command]
        nextButton.toolTip = "Next step (⌘])"
        let courseSpacer = NSView()
        courseSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let courseTop = NSStackView(views: [coursePosition, courseSpacer, previousButton, nextButton])
        courseTop.orientation = .horizontal
        courseTop.alignment = .firstBaseline
        courseTop.spacing = 10
        let courseStack = NSStackView(views: [courseTitle, courseTop, courseIntro, courseNew])
        courseStack.orientation = .vertical
        courseStack.alignment = .leading
        courseStack.spacing = 5
        courseStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        for v in [courseTitle, courseTop, courseIntro, courseNew] as [NSView] {
            v.widthAnchor.constraint(equalTo: courseStack.widthAnchor, constant: -20).isActive = true
        }
        courseCard.boxType = .custom
        courseCard.cornerRadius = 8
        courseCard.borderColor = .separatorColor
        courseCard.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06)
        courseCard.contentViewMargins = .zero
        courseCard.contentView = courseStack
        // The box takes its height from the step's text.
        courseStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            courseStack.topAnchor.constraint(equalTo: courseCard.topAnchor),
            courseStack.bottomAnchor.constraint(equalTo: courseCard.bottomAnchor),
            courseStack.leadingAnchor.constraint(equalTo: courseCard.leadingAnchor),
            courseStack.trailingAnchor.constraint(equalTo: courseCard.trailingAnchor),
        ])
        courseCard.isHidden = true
        courseCard.setAccessibilityLabel("Course step")

        keyboard.showsFunctionRow = false
        let keyboardHost = NSView()
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        keyboardHost.addSubview(keyboard)
        let keyboardWidth = keyboard.widthAnchor.constraint(equalTo: keyboardHost.widthAnchor)
        keyboardWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            keyboard.centerXAnchor.constraint(equalTo: keyboardHost.centerXAnchor),
            keyboard.topAnchor.constraint(equalTo: keyboardHost.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: keyboardHost.bottomAnchor),
            keyboard.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            keyboard.widthAnchor.constraint(lessThanOrEqualTo: keyboardHost.widthAnchor),
            keyboardWidth,
            keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.compactAspect),
        ])

        let stack = NSStackView(views: [header, practiceControls, reviewLabel, courseCard, passageScroll, wordRow,
                                        partsLabel, hintLabel, inputHeader, inputScroll, keyboardHost, legendLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: passageScroll)
        stack.setCustomSpacing(4, after: wordRow)
        stack.setCustomSpacing(4, after: partsLabel)
        stack.setCustomSpacing(4, after: inputHeader)
        stack.setCustomSpacing(6, after: keyboardHost)
        content.addSubview(stack)
        for v in [header, practiceControls, reviewLabel, courseCard, passageScroll, wordRow, partsLabel, hintLabel,
                  inputHeader, inputScroll, keyboardHost, legendLabel] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        let contentWidth = stack.widthAnchor.constraint(equalTo: content.widthAnchor)
        contentWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1060),
            contentWidth,
            passageScroll.heightAnchor.constraint(equalToConstant: 110),
            inputScroll.heightAnchor.constraint(equalToConstant: 70),
        ])
    }

    /// The Course pull-down: every step by unit, checked when done, then the practice texts.
    private func rebuildLessonMenu() {
        lessonMenu.removeAllItems()
        lessonMenu.addItem(withTitle: "Course")
        lessonMenu.lastItem?.tag = -1
        guard let menu = lessonMenu.menu else { return }
        let done = progress?.completed ?? []
        var n = 0
        for unit in Course.units {
            menu.addItem(NSMenuItem.sectionHeader(title: unit.title))
            for step in unit.steps {
                let item = NSMenuItem(title: "\(n + 1). \(step.title)", action: nil, keyEquivalent: "")
                item.tag = n
                item.state = done.contains(step.id) ? .on : .off
                item.toolTip = step.intro
                item.indentationLevel = 1
                menu.addItem(item)
                n += 1
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Practice texts"))
        for (i, l) in Lessons.all.enumerated() {
            let item = NSMenuItem(title: l.title, action: nil, keyEquivalent: "")
            item.tag = Self.practiceTagBase + i
            item.toolTip = l.summary
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    // MARK: Practice controls and performance

    private var answersHidden: Bool { recallMode && !hintRevealed }

    @objc private func recallChanged() {
        recallMode = recallToggle.state == .on
        practiceSettings.recallPractice = recallMode
        hintRevealed = false
        attempt = nil
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        refreshProgress()
        returnToInput()
    }

    @objc private func revealHint() {
        guard recallMode, currentStep != nil else { return }
        hintRevealed = true
        attempt?.assisted = true
        refreshProgress()
        returnToInput()
    }

    @objc private func toggleReference() {
        practiceSettings.practiceReferenceVisible.toggle()
        updatePracticeControls()
        returnToInput()
    }

    private var promptContext: EngineContext {
        guard let g = active, let i = currentStep else { return .initial }
        return i > 0 ? g.steps[i - 1].contextAfter ?? .initial : continuation?.startContext ?? .initial
    }

    private func returnToInput() {
        window?.makeFirstResponder(inputView)
        // Clicking a control resets the router's spacing; resume the current chord's planned context.
        if !hasError { onSyncContext?(promptContext) }
    }

    private func updatePracticeControls() {
        comboLabel.isHidden = answersHidden
        partsLabel.isHidden = answersHidden || partsLabel.attributedStringValue.string.isEmpty
        courseIntro.isHidden = recallMode
        courseNew.isHidden = recallMode || courseNew.attributedStringValue.string == "New   "
        legendLabel.isHidden = answersHidden || !practiceSettings.practiceReferenceVisible
        referenceButton.title = practiceSettings.practiceReferenceVisible ? "Hide Reference" : "Show Reference"
        referenceButton.isEnabled = !answersHidden
        keyboard.meanings = answersHidden ? nil : KeyMeanings(data: data, mode: mode)
        hintButton.isEnabled = recallMode && currentStep != nil && !hintRevealed
        hintButton.title = hintRevealed ? "Hint Shown" : "Show Hint"
        reviewButton.isEnabled = !reviewing && !performance.history.weakest(mode: mode).isEmpty
        updatePerformanceLabel()
    }

    private func updatePerformanceLabel() {
        guard let g = active, let i = currentStep, i < g.steps.count,
              let chord = PracticeChord(step: g.steps[i], data: data, mode: mode),
              let saved = performance.history.performance(for: chord) else {
            performanceLabel.stringValue = ""
            return
        }
        var label = "\(saved.attempts) \(saved.attempts == 1 ? "attempt" : "attempts") · \(Int((saved.accuracy * 100).rounded()))% correct"
        if let seconds = saved.averageSeconds { label += String(format: " · %.1f s", seconds) }
        if saved.hints > 0 { label += " · \(saved.hints) assisted" }
        performanceLabel.stringValue = label
        performanceLabel.setAccessibilityLabel("Saved performance for the current chord: " + label)
    }

    /// The controller supplies the router's actual state, including permissions and Secure Input.
    func updateTypingState(availability: Availability, effectiveMode: Mode, status: String) {
        let previousMode = typingMode
        typingMode = nil
        switch availability {
        case .missingPermission, .secureInput:
            typingStatus.stringValue = status
            typingStatus.textColor = .systemOrange
        case .available:
            if case .chord(let activeMode) = effectiveMode {
                typingMode = activeMode
                if activeMode == mode {
                    typingStatus.stringValue = "Chord typing on · \(activeMode == .english ? "English" : "C++")"
                    typingStatus.textColor = .systemGreen
                } else {
                    typingStatus.stringValue = "Chord typing on · switch to \(mode == .english ? "English" : "C++") to practice"
                    typingStatus.textColor = .systemOrange
                }
            } else {
                typingStatus.stringValue = status == "Chord typing is off"
                    ? "Chord typing off · tap right Option to start" : status
                typingStatus.textColor = .secondaryLabelColor
            }
        }
        typingStatus.setAccessibilityLabel(typingStatus.stringValue)
        if previousMode != typingMode {
            attempt = nil
            promptBeganAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func clearReview() {
        reviewGeneration += 1
        reviewing = false
        reviewTargets.removeAll()
        reviewLabel.isHidden = true
        reviewButton.title = "Review Weak Chords"
    }

    @objc private func reviewWeakChords() {
        guard !reviewing, !performance.history.weakest(mode: mode).isEmpty else { return }
        reviewing = true
        reviewGeneration += 1
        let requested = reviewGeneration
        let history = performance.history, data = self.data, mode = self.mode, limit = rolloverLimit
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        reviewButton.title = "Preparing Review…"
        reviewLabel.stringValue = "Building a short review from saved performance…"
        reviewLabel.isHidden = false
        updatePracticeControls()
        DispatchQueue.global(qos: .userInitiated).async {
            let drill = PracticeReview.make(history: history, data: data, mode: mode, rolloverLimit: limit, usable: usable)
            DispatchQueue.main.async { [weak self] in
                guard let self, requested == self.reviewGeneration else { return }
                self.reviewing = false
                self.reviewButton.title = "Review Weak Chords"
                guard let drill else {
                    self.reviewLabel.stringValue = "No review examples match these chords on this keyboard yet."
                    self.updatePracticeControls()
                    return
                }
                self.courseStep = nil
                self.showCourseStep()
                self.setText(drill.text, name: "Weak chord review", planned: drill.guide)
                self.reviewTargets = drill.targets
                self.reviewLabel.stringValue = "Reviewing \(drill.targets.count) \(drill.targets.count == 1 ? "chord" : "chords") · three rounds · ranked by mistakes and recall time"
                self.reviewLabel.isHidden = false
                self.updatePracticeControls()
            }
        }
    }

    /// Opens the course where the learner left off.
    func startCourse() {
        openCourseStep(progress?.resumeIndex ?? 0)
        present()
    }

    func openCourseStep(_ i: Int) {
        guard i >= 0, i < Course.steps.count else { return }
        let step = Course.steps[i]
        progress?.lastStep = step.id
        if mode != step.mode {
            mode = step.mode
            modePopup.selectItem(at: mode == .english ? 0 : 1)
            onPracticeModeChanged?(mode)
            updateMeanings()
        }
        courseStep = i
        wasFinished = false
        showCourseStep()
        setText(step.text, name: step.title)
    }

    @objc private func previousStep() {
        if let i = courseStep, i > 0 { openCourseStep(i - 1) }
    }

    @objc private func nextStep() {
        if let i = courseStep, i + 1 < Course.steps.count { openCourseStep(i + 1) }
    }

    /// The card's text for the current step; the keys come from the current layout and dictionaries.
    private func showCourseStep() {
        guard let i = courseStep else {
            courseCard.isHidden = true
            return
        }
        let step = Course.steps[i]
        let (u, s) = Course.position(of: i)
        let unit = Course.units[u]
        courseCard.isHidden = false
        coursePosition.stringValue = "\(unit.title)  ·  step \(s + 1) of \(unit.steps.count)  ·  "
            + "\(i + 1) of \(Course.steps.count) in the course"
        courseIntro.stringValue = step.intro
        let chords = step.new.flatMap { Course.chords(for: $0, data: data, mode: step.mode) }
        courseNew.isHidden = chords.isEmpty
        let new = NSMutableAttributedString(string: "New   ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        new.append(ChordText.chords(chords, layout: data.layout, size: 14))
        courseNew.attributedStringValue = new
        courseNew.setAccessibilityLabel("New in this step: " + new.string)
        updateCourseState(finished: false)
    }

    /// Done mark and buttons; finishing the text marks the step done.
    private func updateCourseState(finished: Bool) {
        guard let i = courseStep else { return }
        let step = Course.steps[i]
        if finished && !wasFinished {
            progress?.markDone(step.id)
            rebuildLessonMenu()
        }
        wasFinished = finished
        let done = progress?.completed.contains(step.id) ?? finished
        courseTitle.stringValue = (done ? "✓ " : "") + step.title
        previousButton.isEnabled = i > 0
        nextButton.isEnabled = i + 1 < Course.steps.count
        nextButton.bezelColor = finished ? .controlAccentColor : nil
        nextButton.title = finished && i + 1 < Course.steps.count ? "Next Step ›" : "Next ›"
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputView)
        installMonitor()
    }

    /// New dictionaries from Reload Dictionaries (Req 15.6): plan again with them.
    func update(data: EngineData, rolloverLimit: Int) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        keyboard.layout = data.layout
        updateMeanings()
        showCourseStep()
        replan()
    }

    // MARK: Focus and keys

    func windowDidBecomeKey(_ notification: Notification) {
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        onFocus?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onFocus?(false)
        held.removeAll()
        chordCodes.removeAll()
        attempt = nil
        refreshKeyboard()
    }

    func windowWillClose(_ notification: Notification) {
        onFocus?(false)
        attempt = nil
        clearReview()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Without the event tap (no permission yet), key presses still reach the window in Normal mode.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow, !self.tapIsRunning() else { return e }
            if let cg = e.cgEvent, OutputEmitter.isSynthetic(cg) { return e }
            switch e.type {
            case .keyDown where !e.isARepeat: self.rawKey(.down(e.keyCode))
            case .keyUp: self.rawKey(.up(e.keyCode))
            case .flagsChanged:
                if let (_, down) = EventConversion.modifierChange(code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue)) {
                    self.rawKey(down ? .down(e.keyCode) : .up(e.keyCode))
                }
            default: break
            }
            return e
        }
    }

    func rawKey(_ e: RawKeyEvent) {
        switch e {
        case .down(let c):
            held.insert(c)
            if [54, 55, 58, 59, 61, 62, 63].contains(c) { attempt = nil }
            if !Self.modifierCodes.contains(c) {
                if chordCodes.isEmpty {
                    chordShift = held.contains(56) || held.contains(60)
                    beginAttempt(code: c)
                }
                chordCodes.insert(c)
            }
            if c == 56 || c == 60 { chordShift = true }
        case .up(let c):
            held.remove(c)
            if held.subtracting(Self.modifierCodes).isEmpty && !chordCodes.isEmpty {
                let chord = chordCodes
                chordCodes.removeAll()
                finishAttempt(codes: chord)
                chordReleased(chord)
            }
        }
        refreshKeyboard()
    }

    private func beginAttempt(code: KeyCode) {
        attempt = nil
        guard window?.isKeyWindow == true, window?.firstResponder === inputView,
              typingMode == mode, !hasError, data.layout.indexByCode[code] != nil,
              held.isDisjoint(with: [54, 55, 58, 59, 61, 62, 63]),
              let g = active, let i = currentStep, i < g.steps.count,
              let target = PracticeChord(step: g.steps[i], data: data, mode: mode) else { return }
        attempt = Attempt(step: g.steps[i], target: target, context: promptContext, beganAt: promptBeganAt,
                          assisted: !recallMode || hintRevealed)
    }

    private func finishAttempt(codes: Set<KeyCode>) {
        guard let captured = attempt else { return }
        attempt = nil
        guard typingMode == mode, window?.isKeyWindow == true, window?.firstResponder === inputView else { return }
        let correct = PracticeAssessment.matches(captured.step, codes: codes, shift: chordShift,
                                                capsLock: NSEvent.modifierFlags.contains(.capsLock),
                                                context: captured.context, data: data, mode: mode)
        let indices = codes.compactMap { data.layout.indexByCode[$0] }
        let chord = correct ? PracticeChord(keys: KeySet(indices), shift: chordShift, data: data, mode: mode) : captured.target
        performance.record(chord, correct: correct, seconds: ProcessInfo.processInfo.systemUptime - captured.beganAt,
                           hinted: captured.assisted)
        if !correct { scoredMistakes += 1 }
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        updateStats(finished: finishTime != nil)
        updatePracticeControls()
    }

    /// Steps that type nothing visible are confirmed by their chord, since the text cannot show them.
    private func chordReleased(_ chord: Set<KeyCode>) {
        guard typingMode == mode, window?.firstResponder === inputView else { return }
        guard let guide = active, let i = currentStep, i < guide.steps.count else { return }
        let step = guide.steps[i]
        guard Self.needsConfirmation(step) || step.kind == .cancelCapital else { return }
        if targetCodes(step).subtracting(Self.modifierCodes) == chord {
            doneSteps.insert(i)
            refreshProgress()
        }
    }

    private static func needsConfirmation(_ s: TypingStep) -> Bool {
        s.kind == .command || s.action == .key(.delete)
    }

    // MARK: Import, mode, restart

    @objc private func importFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a text file to practice with KeyChord."
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    private func load(_ url: URL) {
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxFileBytes else {
                showError("This file is too large", "The Typing Guide handles text files up to 1 MB.")
                return
            }
            var encoding = String.Encoding.utf8
            let s: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                s = utf8
            } else {
                s = try String(contentsOf: url, usedEncoding: &encoding)
            }
            courseStep = nil
            showCourseStep()
            setText(s, name: url.lastPathComponent)
        } catch {
            showError("Could not read the file", error.localizedDescription)
        }
    }

    private func setText(_ s: String, name: String?, planned: TypingGuide? = nil) {
        clearReview()
        fileName = name
        // Return types "\n", so line breaks are compared as "\n".
        text = String(s.map { $0 == "\r\n" || $0 == "\r" ? "\n" : $0 })
        chars = Array(text)
        targetUTF16 = Array(text.utf16)
        var offsets = [0]
        offsets.reserveCapacity(chars.count + 1)
        var ends: [Int] = []
        var u = 0
        for (i, c) in chars.enumerated() {
            u += c.utf16.count
            offsets.append(u)
            if !c.isWhitespace && (i + 1 == chars.count || chars[i + 1].isWhitespace) { ends.append(i + 1) }
        }
        utf16Offsets = offsets
        wordEnds = ends
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        passageView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
        ]))
        styled = (0, 0, NSRange(location: 0, length: 0))
        window?.title = "KeyChord Typing Practice" + (name.map { ": \($0)" } ?? "")
        if let planned {
            generation += 1
            guide = planned
            active = planned
            setContinuation(nil)
            continuationPlanner = nil
            clearInput()
            refreshProgress()
        } else {
            replan()
        }
    }

    @objc private func lessonChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag >= 0 else { return }
        if tag >= Self.practiceTagBase {
            if tag - Self.practiceTagBase < Lessons.all.count { practice(Lessons.all[tag - Self.practiceTagBase]) }
        } else {
            openCourseStep(tag)
        }
    }

    /// Opens a practice text (from the Course menu or a link in the manual) in its mode.
    func practice(_ lesson: Lesson) {
        load(lesson)
        present()
    }

    /// Puts a practice text in the window, in its mode.
    func load(_ lesson: Lesson) {
        courseStep = nil
        showCourseStep()
        if mode != lesson.mode {
            mode = lesson.mode
            modePopup.selectItem(at: mode == .english ? 0 : 1)
            onPracticeModeChanged?(mode)
            updateMeanings()
        }
        setText(lesson.text, name: lesson.title)
    }

    @objc private func modeChanged() {
        clearReview()
        mode = modePopup.indexOfSelectedItem == 1 ? .cpp : .english
        onPracticeModeChanged?(mode)
        updateMeanings()
        if fileName == nil { setText(Self.sample(for: mode), name: nil) } else { replan() }
    }

    @objc private func restart() {
        clearInput()
        refreshProgress()
    }

    private func clearInput() {
        inputView.string = ""
        inputView.undoManager?.removeAllActions()
        editFloor = 0
        startTime = nil
        finishTime = nil
        mistakes = 0
        scoredMistakes = 0
        attempt = nil
        displayedStep = nil
        hintRevealed = false
        promptBeganAt = ProcessInfo.processInfo.systemUptime
        doneSteps.removeAll()
        currentGroup = nil
        lastTypedLen = 0
        onResetContext?()
        onSyncContext?(.initial)
        window?.makeFirstResponder(inputView)
    }

    /// Plans off the main thread; a newer request supersedes older ones.
    private func replan() {
        clearReview()
        generation += 1
        let gen = generation
        let text = self.text, data = self.data, mode = self.mode, limit = rolloverLimit
        let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
        guide = nil
        active = nil
        setContinuation(nil)
        continuationPlanner = nil
        clearInput()
        refreshProgress()
        DispatchQueue.global(qos: .userInitiated).async {
            let planned = TypingPlanner(data: data, mode: mode, rolloverLimit: limit, usable: usable).plan(text)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.guide = planned
                self.editFloor = 0
                self.refreshProgress()
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window)
    }

    // MARK: Typing progress

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        editFloor = min(editFloor, range.location)
        return true
    }

    func textDidChange(_ notification: Notification) {
        if startTime == nil && inputView.string.utf16.count > 0 { startTime = Date() }
        refreshProgress()
    }

    /// Compares the typed text with the passage and updates the colors, current word, hint, and keyboard.
    private func refreshProgress() {
        let typed: NSString = inputView.textStorage?.mutableString ?? ""
        let typedLen = typed.length
        // Text before the lowest edit is unchanged, so the comparison can resume there.
        var i = max(0, min(correctUTF16, editFloor, typedLen, targetUTF16.count))
        editFloor = Int.max
        while i < typedLen && i < targetUTF16.count && typed.character(at: i) == targetUTF16[i] { i += 1 }
        correct = charIndex(forUTF16: i)
        correctUTF16 = utf16Offsets[correct]

        let wasError = hasError
        hasError = typedLen > correctUTF16
        let deleted = typedLen < lastTypedLen
        lastTypedLen = typedLen

        // The plan to follow: a continuation covers its stretch of the line, the whole-passage plan the rest.
        // Leaving a continuation at its end puts KeyChord's context back where the whole-passage plan has it.
        if let c = continuation, !(correct >= c.start && correct < c.end) {
            setContinuation(nil)
            if correct == c.end, let g = guide, let ctx = contextEnding(at: correct, in: g) { onSyncContext?(ctx) }
        }
        active = continuation?.guide ?? guide

        // A planned in-between state is not a mistake: the base of a suffix whose spelling changes
        // ("make" before + ing) or a throwaway letter before Delete.
        let tailStep = hasError ? plannedTailStep(typed) : nil
        if tailStep != nil { hasError = false }
        let finished = !chars.isEmpty && correct == chars.count && !hasError
        if finished && finishTime == nil { finishTime = Date() }
        if !finished { finishTime = nil }

        // Typed text the plan does not pass through, such as part of a word and then Delete: work out the
        // chords for the rest from here.
        if !hasError && !finished, let g = active, !isPlanned(correct, in: g) { startContinuation() }

        // Current step: the first one of the word at the cursor not yet done.
        currentStep = nil
        var wordRange = NSRange(location: correctUTF16, length: 0)
        if let guide = active, !finished, let first = guide.stepIndex(at: correct) {
            let group = guide.steps[first].group
            if group != currentGroup {
                currentGroup = group
                doneSteps.removeAll()
            }
            var end = first
            while end < guide.steps.count && guide.steps[end].group == group { end += 1 }
            var j = first
            if let t = tailStep {
                j = t + 1
                while j < end && doneSteps.contains(j) { j += 1 }
            } else {
                while j < end {
                    let s = guide.steps[j]
                    if doneSteps.contains(j) { j += 1; continue }
                    if s.textEnd > correct || (s.textEnd == correct && Self.needsConfirmation(s)) { break }
                    j += 1
                }
            }
            currentStep = min(j, guide.steps.count - 1)
            let lo = guide.steps[first..<end].map(\.source.lowerBound).min() ?? correct
            let hi = guide.steps[first..<end].map(\.source.upperBound).max() ?? correct
            wordRange = nsRange(lo..<hi)
        }
        let showError = hasError
        if showError && !wasError { mistakes += 1 }
        if wasError && !hasError, let guide = active {
            // A fixed mistake may have used up a command (such as Capitalize_Next): ask for it again.
            doneSteps = doneSteps.filter { guide.steps[$0].kind != .command }
        }
        if (deleted || (wasError && !hasError)) && !hasError, let guide = active, let cur = currentStep {
            // Delete resets KeyChord's context; put it back where the plan is, so the next chord gets its
            // leading space and capital as planned.
            var j = cur - 1
            while j >= 0 && guide.steps[j].group == guide.steps[cur].group && !doneSteps.contains(j)
                    && Self.needsConfirmation(guide.steps[j]) { j -= 1 }
            if j < 0 {
                if let c = continuation {
                    if correct == c.start { onSyncContext?(c.startContext) }
                } else if typedLen == 0 {
                    onSyncContext?(.initial)
                }
            } else if let ctx = guide.steps[j].contextAfter, typedMatches(step: guide.steps[j], typed) {
                onSyncContext?(ctx)
            }
        }

        let nextPrompt = currentStep.flatMap { i in active.flatMap { i < $0.steps.count ? $0.steps[i] : nil } }
        if nextPrompt != displayedStep {
            displayedStep = nextPrompt
            hintRevealed = false
            promptBeganAt = ProcessInfo.processInfo.systemUptime
        }
        restylePassage(typedEnd: min(typedLen, targetUTF16.count), word: wordRange,
                       scroll: wordRange != styled.word)
        updateWordPanel(finished: finished, showError: showError)
        updateCourseState(finished: finished)
        updateStats(finished: finished)
        updatePracticeControls()
        refreshKeyboard()
    }

    /// Whether the typed text is exactly the planned text after `step`.
    private func typedMatches(step: TypingStep, _ typed: NSString) -> Bool {
        let p = step.prefixEnd
        guard p >= 0, p <= correct, p < utf16Offsets.count else { return false }
        let tail = step.tail as NSString
        let start = utf16Offsets[p]
        guard typed.length == start + tail.length else { return false }
        return tail.length == 0 || typed.substring(from: start) == step.tail
    }

    /// Whether the plan passes through `offset`: the start of the text or of the continuation, or the end of a
    /// step. Inside a step typed normally, any offset counts: it is typed letter by letter.
    private func isPlanned(_ offset: Int, in g: TypingGuide) -> Bool {
        if offset == 0 || offset == continuation?.start { return true }
        guard let first = g.stepIndex(at: offset) else { return true }
        var k = max(0, first - 1)
        while k < g.steps.count && (k < first || g.steps[k].group == g.steps[first].group) {
            let s = g.steps[k]
            if s.tail.isEmpty && s.textEnd == offset { return true }
            if case .typeNormally = s.action, s.textEnd > offset, s.textEnd - s.output.count <= offset { return true }
            k += 1
        }
        return false
    }

    /// The planned context after the last step that ends exactly at `offset`.
    private func contextEnding(at offset: Int, in g: TypingGuide) -> EngineContext? {
        guard let first = g.stepIndex(at: offset) else { return g.steps.last?.contextAfter }
        var k = min(g.steps.count - 1, first + 1)
        while k >= 0 && g.steps[k].textEnd >= offset {
            if g.steps[k].textEnd == offset && g.steps[k].tail.isEmpty { return g.steps[k].contextAfter }
            k -= 1
        }
        return k >= 0 && g.steps[k].textEnd == offset ? g.steps[k].contextAfter : nil
    }

    /// The planned context at the last step boundary at or before `offset`.
    private func contextBefore(_ offset: Int, in g: TypingGuide) -> EngineContext? {
        var k = min(g.steps.count - 1, (g.stepIndex(at: offset) ?? g.steps.count - 1) + 1)
        while k >= 0 {
            let s = g.steps[k]
            if s.textEnd <= offset && s.tail.isEmpty { return s.contextAfter }
            k -= 1
        }
        return nil
    }

    private func setContinuation(_ c: TypingContinuation?) {
        continuation = c
        currentGroup = nil
        doneSteps.removeAll()
    }

    /// Plans the rest of the line from the cursor and puts KeyChord's context where that plan starts.
    private func startContinuation() {
        guard let g = guide else { return }
        if continuationPlanner == nil {
            let usable = limits.map { $0.usable(in: data.layout) } ?? { _ in true }
            continuationPlanner = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable)
        }
        let previous = (active.flatMap { contextBefore(correct, in: $0) }) ?? continuation?.startContext
            ?? contextBefore(correct, in: g)
        guard let c = continuationPlanner?.planContinuation(chars, from: correct, previous: previous),
              !c.guide.steps.isEmpty else { return }
        setContinuation(c)
        active = c.guide
        onSyncContext?(c.startContext)
    }

    /// The step whose planned in-between text (with a tail) is what has been typed, if any.
    private func plannedTailStep(_ typed: NSString) -> Int? {
        guard let guide = active, let first = guide.stepIndex(at: correct) else { return nil }
        let g = guide.steps[first].group
        var end = first
        while end < guide.steps.count && guide.steps[end].group == g { end += 1 }
        for j in stride(from: end - 1, through: max(0, first - 1), by: -1) {
            let s = guide.steps[j]
            if !s.tail.isEmpty && typedMatches(step: s, typed) { return j }
        }
        return nil
    }

    private func restylePassage(typedEnd: Int, word: NSRange, scroll: Bool) {
        guard let storage = passageView.textStorage, storage.length == targetUTF16.count else { return }
        let old = styled
        styled = (correctUTF16, max(typedEnd, correctUTF16), word)
        // Only the part that changed is restyled, so long texts stay fast.
        let lo = min(old.correct, correctUTF16, old.word.location, word.location)
        let hi = max(old.typedEnd, styled.typedEnd, NSMaxRange(old.word), NSMaxRange(word), old.correct, correctUTF16)
        let dirty = NSRange(location: lo, length: min(hi, storage.length) - lo)
        guard dirty.length > 0 || scroll else { return }
        func apply(_ r: NSRange, _ attrs: [NSAttributedString.Key: Any]) {
            let x = NSIntersectionRange(r, dirty)
            if x.length > 0 { storage.addAttributes(attrs, range: x) }
        }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: dirty)
        storage.removeAttribute(.underlineStyle, range: dirty)
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: dirty)
        apply(word, [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.thick.rawValue,
                     .underlineColor: NSColor.controlAccentColor])
        apply(NSRange(location: 0, length: correctUTF16), [.foregroundColor: NSColor.systemGreen])
        apply(NSRange(location: correctUTF16, length: styled.typedEnd - correctUTF16),
              [.foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.systemRed.withAlphaComponent(0.35)])
        storage.endEditing()
        if scroll { passageView.scrollRangeToVisible(word) }
    }

    private func updateWordPanel(finished: Bool, showError: Bool) {
        partsLabel.stringValue = ""
        guard let guide = active else {
            wordLabel.stringValue = chars.isEmpty ? "" : "…"
            comboLabel.stringValue = chars.isEmpty ? "" : "working out the chords"
            hintLabel.stringValue = chars.isEmpty ? "Import a text file to practice with." : ""
            return
        }
        if finished {
            wordLabel.stringValue = "Done"
            comboLabel.attributedStringValue = NSAttributedString(string: "")
            if let i = courseStep {
                hintLabel.stringValue = i + 1 < Course.steps.count
                    ? "Step done. Go on with Next Step (⌘]), or Restart (⌘R) to practice it again."
                    : "You finished the course. Practice with your own texts: Import Text (⌘O)."
            } else if !reviewTargets.isEmpty {
                hintLabel.stringValue = "Review finished. Restart (⌘R) to repeat it, or Review Weak Chords for updated priorities."
            } else {
                hintLabel.stringValue = "Press Restart (⌘R) to go again, or import another text (⌘O)."
            }
            return
        }
        guard let cur = currentStep else {
            wordLabel.stringValue = ""
            comboLabel.stringValue = ""
            hintLabel.stringValue = guide.steps.isEmpty ? "The text is empty." : ""
            return
        }
        let group = guide.steps[cur].group
        var first = cur, end = cur
        while first > 0 && guide.steps[first - 1].group == group { first -= 1 }
        while end < guide.steps.count && guide.steps[end].group == group { end += 1 }
        let src = guide.steps[first].source
        // In the middle of a word, the part already typed is shown in green before what is left.
        var wordStart = src.lowerBound
        if wordStart < chars.count, TypingPlanner.isWordChar(chars[wordStart]) {
            while wordStart > 0 && TypingPlanner.isWordChar(chars[wordStart - 1]) { wordStart -= 1 }
        }
        let wordFont = NSFont.systemFont(ofSize: 30, weight: .semibold)
        let word = NSMutableAttributedString()
        if wordStart < src.lowerBound {
            word.append(NSAttributedString(string: sourceText(wordStart..<src.lowerBound),
                                           attributes: [.font: wordFont, .foregroundColor: NSColor.systemGreen]))
        }
        word.append(NSAttributedString(string: Self.visible(sourceText(src)),
                                       attributes: [.font: wordFont, .foregroundColor: NSColor.labelColor]))
        wordLabel.attributedStringValue = word
        if !answersHidden { partsLabel.attributedStringValue = partsText(guide.steps[cur]) }

        if answersHidden && !showError {
            comboLabel.attributedStringValue = NSAttributedString(string: "")
            comboLabel.setAccessibilityValue("")
            hintLabel.stringValue = "Recall the next chord. Show Hint (⌘⇧H) reveals its keys."
            hintLabel.textColor = .secondaryLabelColor
            return
        }

        let combo = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        let shownSteps = recallMode ? cur..<(cur + 1) : first..<end
        for j in shownSteps {
            if j > shownSteps.lowerBound {
                combo.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            let color: NSColor = j < cur ? .tertiaryLabelColor : j == cur ? (showError ? .systemRed : .controlAccentColor) : .labelColor
            let weight: NSFont.Weight = j == cur ? .bold : .medium
            combo.append(NSAttributedString(string: combination(orderedAction(guide.steps[j])), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: weight), .foregroundColor: color,
            ]))
        }
        comboLabel.attributedStringValue = combo
        comboLabel.setAccessibilityValue(combo.string)

        if showError {
            var fix = "Not quite. Fix it with ⌫ Delete"
            if let undo = undoCombination() { fix += " or the undo chord \(undo)" }
            hintLabel.stringValue = fix + "."
            hintLabel.textColor = .systemRed
            return
        }
        hintLabel.textColor = .secondaryLabelColor
        let step = guide.steps[cur]
        switch step.action {
        case .chord(_, let shift) where shift:
            hintLabel.stringValue = "Hold ⇧ Shift with this chord to join it to the word before "
                + "(the keyboard can't take the space bar with these keys)."
        case .chord where step.parts.contains { $0.role == .join }:
            hintLabel.stringValue = "Hold the space bar with this chord to join it to the word before."
        case .typeNormally:
            hintLabel.stringValue = "No chord for this: tap right ⌥ Option, type it normally, tap right ⌥ Option again."
        default:
            hintLabel.stringValue = step.kind == .command || step.kind == .cancelCapital || step.kind == .key ? step.note : ""
        }
    }

    private func updateStats(finished: Bool) {
        let done = upperBound(wordEnds, correct)
        var s = "\(done)/\(wordEnds.count) words"
        if let start = startTime {
            let minutes = max((finishTime ?? Date()).timeIntervalSince(start) / 60, 1.0 / 60)
            s += String(format: "  ·  %.0f wpm", Double(correct) / 5 / minutes)
        }
        let totalMistakes = max(mistakes, scoredMistakes)
        s += "  ·  \(totalMistakes) \(totalMistakes == 1 ? "mistake" : "mistakes")"
        if finished { s = "Finished  ·  " + s }
        statsLabel.stringValue = s
    }

    private func refreshKeyboard() {
        var target = Set<KeyCode>()
        var caption = ""
        if let guide = active, let cur = currentStep, cur < guide.steps.count {
            let step = guide.steps[cur]
            if hasError {
                target = [51]
                caption = "Press Delete"
            } else if answersHidden {
                caption = "Recall the next chord. Use Show Hint to reveal its keys"
            } else {
                target = targetCodes(step)
                caption = "Press " + combination(orderedAction(step))
            }
        }
        keyboard.target = target
        keyboard.held = held
        let heldNames = held.sorted().map { KeyboardDiagramView.name(for: $0) }
        keyboard.setAccessibilityLabel(caption + ". Held: " + (heldNames.isEmpty ? "none" : heldNames.joined(separator: " + ")))
    }

    // MARK: Step formatting

    /// What the keys of a chord stand for: "E + T → th   ·   M → i   ·   K + L → ng", colored like the keyboard.
    private func partsText(_ step: TypingStep) -> NSAttributedString {
        guard case let .chord(_, shift) = step.action, !step.parts.isEmpty else { return NSAttributedString() }
        let out = NSMutableAttributedString()
        let keyFont = NSFont.systemFont(ofSize: 15)
        let meaningFont = NSFont.systemFont(ofSize: 15, weight: .bold)
        func add(_ keys: String, _ meaning: String, _ color: NSColor) {
            if out.length > 0 {
                out.append(NSAttributedString(string: "   ·   ", attributes: [.font: keyFont, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            out.append(NSAttributedString(string: keys + " → ", attributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]))
            out.append(NSAttributedString(string: meaning, attributes: [.font: meaningFont, .foregroundColor: color]))
        }
        if shift { add("⇧", "join", .labelColor) }
        for part in step.parts {
            let keys = part.keys.compactMap { n -> String? in
                guard let i = data.layout.indexByName[n] else { return nil }
                return KeyboardDiagramView.name(for: data.layout.keys[i].code)
            }.joined(separator: " + ")
            let role: KeyMeanings.Role?
            switch part.role {
            case .onset: role = .onset
            case .vowel: role = .vowel
            case .coda: role = .coda
            case .spell: role = .spell
            case .capital, .suffix, .symbol, .command: role = .special
            case .digit, .space, .join: role = .number
            case .word, .letter: role = nil
            }
            let meaning = part.role == .word ? part.text + " (word chord)" : Self.visible(part.text)
            add(keys, meaning, role.map(KeyboardDiagramView.color(for:)) ?? .labelColor)
        }
        return out
    }

    private func targetCodes(_ step: TypingStep) -> Set<KeyCode> {
        var codes = Set<KeyCode>()
        switch step.action {
        case let .chord(names, shift):
            for n in names { if let i = data.layout.indexByName[n] { codes.insert(data.layout.keys[i].code) } }
            if shift { codes.formUnion([56, 60]) }
        case .key(let k):
            switch k {
            case .returnKey: codes.insert(36)
            case .tab: codes.insert(48)
            case .delete: codes.insert(51)
            }
        case .typeNormally:
            codes.formUnion([58, 61])
        }
        return codes
    }

    /// The step's action with its chord keys in the order of its parts (start, vowel, end), so "thing" reads
    /// E + T + M + K + L rather than in keyboard order.
    private func orderedAction(_ step: TypingStep) -> TypingStep.Action {
        guard case let .chord(names, shift) = step.action, !step.parts.isEmpty else { return step.action }
        var ordered: [String] = []
        for p in step.parts { for k in p.keys where !ordered.contains(k) { ordered.append(k) } }
        for k in names where !ordered.contains(k) { ordered.append(k) }
        return .chord(keys: ordered, shift: shift)
    }

    /// The keys of a step as printed on the keyboard, such as "È + T + H" or "⇧ + N + M".
    private func combination(_ a: TypingStep.Action) -> String {
        switch a {
        case let .chord(names, shift):
            let keys = names.map { n -> String in
                guard let i = data.layout.indexByName[n] else { return n }
                return KeyboardDiagramView.name(for: data.layout.keys[i].code)
            }
            return ((shift ? ["⇧"] : []) + keys).joined(separator: " + ")
        case .key(let k):
            switch k {
            case .returnKey: return "↩ Return"
            case .tab: return "⇥ Tab"
            case .delete: return "⌫ Delete"
            }
        case .typeNormally(let s):
            return "⌥, type “\(Self.visible(s))”, ⌥"
        }
    }

    private func undoCombination() -> String? {
        let undo = data.shared.entries.first { if case .command(.undo) = $0.value { return true } else { return false } }
        guard let keys = undo?.key else { return nil }
        return combination(.chord(keys: data.layout.names(keys), shift: false))
    }

    static func visible(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case " ": out += "␣"
            case "\t": out += "⇥"
            case "\n", "\r\n", "\r": out += "↩"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Offsets

    private func nsRange(_ r: Range<Int>) -> NSRange {
        let lo = utf16Offsets[max(0, min(r.lowerBound, utf16Offsets.count - 1))]
        let hi = utf16Offsets[max(0, min(r.upperBound, utf16Offsets.count - 1))]
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    /// The character boundary at or before UTF-16 offset `u`.
    private func charIndex(forUTF16 u: Int) -> Int {
        var lo = 0, hi = utf16Offsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if utf16Offsets[mid] <= u { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func sourceText(_ r: Range<Int>) -> String {
        let lo = max(0, min(r.lowerBound, chars.count)), hi = max(lo, min(r.upperBound, chars.count))
        return String(chars[lo..<hi])
    }

    /// Number of elements of the sorted array `a` that are <= `x`.
    private func upperBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Keyboard diagram

/// The MacBook keyboard (`geometry`: US ANSI or Canadian French ISO). Keys to press are outlined in the accent
/// color; keys actually held are filled: green when they belong to the chord, orange when they do not. With
/// `meanings`, each key shows what it stands for (its sound, digit or job) in large type, tinted by role, with the
/// printed legend small in the corner.
final class KeyboardDiagramView: NSView {
    /// The keyboard every diagram draws and names keys by. Set on the main thread by the app controller, from the
    /// Keyboard menu or the keyboard type macOS reports; every diagram redraws when it changes. Both keyboards
    /// have the same size, so the aspect ratios below hold for either.
    static var geometry: KeyboardGeometry = .ansi {
        didSet { NotificationCenter.default.post(name: geometryDidChange, object: nil) }
    }
    static let geometryDidChange = Notification.Name("KeyChordKeyboardGeometryDidChange")

    static let aspect = KeyboardGeometry.height / KeyboardGeometry.width
    /// Height of the function row and the gap below it, in key units.
    static let functionRowHeight = 0.7
    /// Height over width without the function row.
    static let compactAspect = (KeyboardGeometry.height - functionRowHeight) / KeyboardGeometry.width

    var layout: Layout? { didSet { needsDisplay = true } }
    /// Draw Escape and the function keys. The reference overlay leaves them out to save room.
    var showsFunctionRow = true { didSet { needsDisplay = true } }
    /// Fill for held keys when nothing is targeted (default: the accent color), e.g. to mark a chord that types
    /// nothing.
    var heldColor: NSColor? { didSet { needsDisplay = true } }
    var meanings: KeyMeanings? { didSet { needsDisplay = true } }
    var target = Set<KeyCode>() { didSet { if target != oldValue { needsDisplay = true } } }
    var held = Set<KeyCode>() { didSet { if held != oldValue { needsDisplay = true } } }
    /// Matrix Scan: the key to press next (drawn strongest), keys that registered, keys that stayed dark.
    var current: KeyCode? { didSet { if current != oldValue { needsDisplay = true } } }
    var passed = Set<KeyCode>() { didSet { if passed != oldValue { needsDisplay = true } } }
    var failed = Set<KeyCode>() { didSet { if failed != oldValue { needsDisplay = true } } }

    /// The key's printed label on this keyboard, used to describe chords.
    static func name(for code: KeyCode) -> String { geometry.label(for: code) }

    /// Key position and size in key units (1 unit = one letter key), origin top left.
    static func rect(for code: KeyCode) -> NSRect? {
        geometry.key(for: code).map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: Self.geometryDidChange,
                                               object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func geometryChanged() { needsDisplay = true }

    /// The color of each kind of key when keys are labelled by meaning (also used for chord parts).
    static func color(for role: KeyMeanings.Role) -> NSColor {
        switch role {
        case .onset: return .systemBlue
        case .vowel: return .systemPurple
        case .coda: return .systemTeal
        case .spell: return .systemPink
        case .special: return .systemBrown
        case .number, .space: return .systemGray
        }
    }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        let top = showsFunctionRow ? 0 : Self.functionRowHeight
        let height = KeyboardGeometry.height - top
        let unit = min(bounds.width / KeyboardGeometry.width, bounds.height / height)
        guard unit > 6 else { return }
        // Without the function row, everything moves up by its height.
        let origin = NSPoint(x: ((bounds.width - unit * KeyboardGeometry.width) / 2).rounded(),
                             y: ((bounds.height - unit * height) / 2).rounded() - top * unit)
        let gap = max(2, unit * 0.08)
        let labelFont = NSFont.systemFont(ofSize: max(9, unit * 0.34), weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: max(7, unit * 0.2), weight: .regular)
        let chordKeys = Set(layout?.keys.map(\.code) ?? [])
        let geometry = Self.geometry

        for key in geometry.keys where key.y >= top {
            let r = NSRect(x: origin.x + key.x * unit + gap / 2, y: origin.y + key.y * unit + gap / 2,
                           width: key.width * unit - gap, height: key.height * unit - gap)
            // The ISO Return key is an L; on ANSI it is a plain key.
            let outline = key.code == KeyboardGeometry.returnCode ? geometry.returnOutline : nil
            let path = outline.map { returnPath($0, origin: origin, unit: unit, gap: gap) }
                ?? NSBezierPath(roundedRect: r, xRadius: unit * 0.1, yRadius: unit * 0.1)
            let isTarget = target.contains(key.code), isHeld = held.contains(key.code)
            let inLayout = chordKeys.contains(key.code)
            let meaning = meanings?.keys[key.code]
            // The meaning shown on the key: its sound or job, or Shift's and right Option's job while chording.
            let shown: String? = meaning.flatMap { $0.label.isEmpty ? nil : $0.label }
                ?? (meanings == nil ? nil : KeyMeanings.modifiers[key.code])
            let roleColor: NSColor? = shown == nil ? nil : meaning.map { Self.color(for: $0.role) } ?? .labelColor

            var fill: NSColor
            var stroke: NSColor
            var lineWidth: CGFloat = 1
            var text: NSColor = inLayout || key.small ? .labelColor : .secondaryLabelColor
            switch (isHeld, isTarget) {
            case (true, true):
                fill = .systemGreen; stroke = .systemGreen; text = .white
            case (true, false):
                fill = target.isEmpty ? heldColor ?? .controlAccentColor : .systemOrange; stroke = fill; text = .white
            case (false, true):
                fill = NSColor.controlAccentColor.withAlphaComponent(0.22); stroke = .controlAccentColor; lineWidth = 2.5
            case (false, false):
                if let roleColor, meaning != nil {
                    fill = roleColor.withAlphaComponent(0.12); stroke = roleColor.withAlphaComponent(0.4)
                } else {
                    fill = NSColor.labelColor.withAlphaComponent(inLayout ? 0.09 : 0.035); stroke = .separatorColor
                }
            }
            if !isHeld {
                if failed.contains(key.code) {
                    fill = NSColor.systemRed.withAlphaComponent(0.3); stroke = .systemRed; lineWidth = 1.5
                } else if passed.contains(key.code) {
                    fill = NSColor.systemGreen.withAlphaComponent(0.3); stroke = .systemGreen; lineWidth = 1
                }
                if current == key.code {
                    fill = NSColor.controlAccentColor.withAlphaComponent(0.55); stroke = .controlAccentColor
                    lineWidth = 3.5; text = .white
                }
            }
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

            let labelRect = outline != nil ? NSRect(x: r.minX, y: r.minY, width: r.width, height: unit - gap) : r

            if let shown {
                // Meaning in large type, the printed legend small in the corner, and what the key does alone
                // (when that is something else) small at the bottom.
                let bigColor = isHeld ? NSColor.white : roleColor ?? text
                let scale: CGFloat = shown.count <= 2 ? 1 : shown.count <= 4 ? 0.74 : 0.6
                let big = NSAttributedString(string: shown, attributes: [
                    .font: NSFont.systemFont(ofSize: labelFont.pointSize * scale, weight: .semibold),
                    .foregroundColor: bigColor])
                let bs = big.size()
                let alone = unit >= 30 ? meaning?.alone : nil
                let y = alone == nil ? labelRect.midY - bs.height / 2 : labelRect.midY - bs.height * 0.62
                big.draw(at: NSPoint(x: labelRect.midX - bs.width / 2, y: y))
                let dim = isHeld ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor
                if !key.label.isEmpty, unit >= 22 {
                    let corner = NSAttributedString(string: key.label, attributes: [.font: smallFont, .foregroundColor: dim])
                    corner.draw(at: NSPoint(x: labelRect.minX + unit * 0.08, y: labelRect.minY + unit * 0.04))
                }
                if let alone {
                    let a = NSAttributedString(string: alone, attributes: [.font: smallFont, .foregroundColor: dim])
                    let s = a.size()
                    a.draw(at: NSPoint(x: labelRect.midX - s.width / 2, y: labelRect.maxY - s.height - unit * 0.05))
                }
                continue
            }

            guard !key.label.isEmpty else { continue }
            let main = NSAttributedString(string: key.label, attributes: [.font: key.small ? smallFont : labelFont,
                                                                          .foregroundColor: text])
            let ms = main.size()
            if let shifted = key.shifted, unit >= 26 {
                let sub = NSAttributedString(string: shifted, attributes: [.font: smallFont, .foregroundColor: text.withAlphaComponent(0.7)])
                let ss = sub.size()
                sub.draw(at: NSPoint(x: labelRect.midX - ss.width / 2, y: labelRect.minY + labelRect.height * 0.08))
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.maxY - ms.height - labelRect.height * 0.1))
            } else {
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.midY - ms.height / 2))
            }
        }
    }

    /// The ISO Return key: 1 unit wide on the Q row, 0.75 unit on the A row.
    private func returnPath(_ outline: [(x: Double, y: Double)], origin: NSPoint, unit: CGFloat, gap: CGFloat) -> NSBezierPath {
        let g = gap / 2
        let pts = outline.map { NSPoint(x: origin.x + $0.x * unit, y: origin.y + $0.y * unit) }
        // Inset each corner toward the inside of the L by half the gap.
        let insets: [(CGFloat, CGFloat)] = [(g, g), (-g, g), (-g, -g), (g, -g), (g, -g), (g, -g)]
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = NSPoint(x: p.x + insets[i].0, y: p.y + insets[i].1)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
