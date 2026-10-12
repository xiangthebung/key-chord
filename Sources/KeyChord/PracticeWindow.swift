import AppKit
import KeyChordCore

enum PracticeSection: String, CaseIterable {
    case lessons, words, voice

    var title: String {
        switch self {
        case .lessons: return "Lessons"
        case .words: return "Words"
        case .voice: return "Voice Practice"
        }
    }
}

enum PracticeShortcut {
    case hints, replay, new, retry
}

/// Shortcuts belong to this window, so they also work while the typing field owns focus.
final class PracticeWindow: NSWindow {
    var onShortcut: ((PracticeShortcut) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shortcut: PracticeShortcut?
        if flags == [.command, .shift], key == "h" { shortcut = .hints }
        else if flags == [.command, .shift], key == "r" { shortcut = .replay }
        else if flags == [.command], key == "r" { shortcut = .retry }
        else if flags == [.command], key == "\r" { shortcut = .new }
        else { shortcut = nil }
        if let shortcut, let onShortcut {
            if !event.isARepeat { onShortcut(shortcut) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Responder-chain input uses the existing local chord engine and focus lease.
/// Bulk native insertions and drag/drop cannot turn a pasted passage into a typing result.
final class PracticeTypingInputView: LocalChordInputView {
    var onBlockedPaste: (() -> Void)?
    var onCursorChange: (() -> Void)?
    override func paste(_ sender: Any?) { onBlockedPaste?() }
    override func pasteAsPlainText(_ sender: Any?) { onBlockedPaste?() }
    override func pasteAsRichText(_ sender: Any?) { onBlockedPaste?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onBlockedPaste?(); return false }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let changed = selectedRanges != ranges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if changed, !isApplyingChordOutput { onCursorChange?() }
    }
}

final class PracticeWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onLocalFocus: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private var data: EngineData
    private var rolloverLimit: Int
    private var usable: (KeySet) -> Bool
    private let clock: () -> Double
    private let seed: () -> UInt64
    private let wordSource: [String]?
    private let input: PracticeTypingInputView
    private let lessonPane: GuidedPracticePane
    private let voicePane: GuidedPracticePane
    private let heading = PracticeUI.label("Words", size: 28, weight: .bold)
    private var wordContent: NSStackView!
    private(set) var section: PracticeSection = .words
    private(set) var session: WordPracticeSession!
    private var timer: Timer?
    private let vocabularyPopup = PracticePopUpButton()
    private let goalControl = NSSegmentedControl(labels: ["Time", "Words"], trackingMode: .selectOne, target: nil, action: nil)
    private let lengthPopup = PracticePopUpButton()
    private var chordEnabled: Bool
    private let guideButton = NSButton(title: "Hint ⇧⌘H", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let passage = PracticePassageView()
    private let passageScroll = PracticePassageScrollView()
    private let resultTitle = PracticeUI.label("Practice complete", size: 20, weight: .semibold)
    private let resultDetail = NSTextField(wrappingLabelWithString: "")
    private let characterDetail = NSTextField(wrappingLabelWithString: "")
    private let chart = PracticeChartView()
    private var resultCard: NSBox!
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let hintCaption = PracticeUI.label("KEYBOARD", size: 10, weight: .semibold)
    private let keyboard = KeyboardDiagramView()
    private var guideCard: NSStackView!
    private var hintedWord: Int?
    private var metricLabels: [NSTextField] = []
    private let planningQueue = DispatchQueue(label: "KeyChord.practice-planning", qos: .userInitiated)
    private var planRequest = 0
    private var plannedFor = ""
    private var usedChords = false
    private var usedKeyboard = false
    private var usedGuide = false
    private var announcedFinish = false
    private var verifiedChordPreview = false
    private var intermediateWord: (index: Int, text: String, nextStep: TypingStep?, context: EngineContext?)?
    private var wordPlans: [String: TypingGuide] = [:]
    private lazy var wordPlanner = TypingPlanner(data: data, mode: .english, rolloverLimit: rolloverLimit, usable: usable)
    private static let times = [15, 30, 60, 120]
    private static let counts = [10, 25, 50, 100]

    init(data: EngineData, rolloverLimit: Int = 6, usable: @escaping (KeySet) -> Bool = { _ in true },
         defaults: UserDefaults = .standard, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         seed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) },
         focus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true }, wordSource: [String]? = nil,
         makeSpeaker: () -> PracticeSpeaking = { PracticeSpeaker() }) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.usable = usable
        self.defaults = defaults
        self.clock = clock
        self.seed = seed
        self.wordSource = wordSource
        chordEnabled = !defaults.bool(forKey: "wordSprintKeyboard")
        input = PracticeTypingInputView(data: data, focus: focus, globalSuspended: globalSuspended)
        lessonPane = GuidedPracticePane(kind: .lessons, data: data, rolloverLimit: rolloverLimit, usable: usable,
            defaults: defaults, focus: focus, globalSuspended: globalSuspended, speaker: makeSpeaker())
        voicePane = GuidedPracticePane(kind: .voice, data: data, rolloverLimit: rolloverLimit, usable: usable,
            defaults: defaults, focus: focus, globalSuspended: globalSuspended, speaker: makeSpeaker())
        let window = PracticeWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 810),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyChord · Practice"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 760)
        window.backgroundColor = PracticeUI.pageColor
        window.setFrameAutosaveName("KeyChordPractice")
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        window.onShortcut = { [weak self] shortcut in self?.perform(shortcut) }
        buildUI()
        lessonPane.onLocalFocus = { [weak self] focused in self?.onLocalFocus?(focused) }
        voicePane.onLocalFocus = { [weak self] focused in self?.onLocalFocus?(focused) }
        input.delegate = self
        input.onFocus = { [weak self] focused in
            self?.onLocalFocus?(focused)
        }
        input.onReadinessChanged = { [weak self] in self?.syncContext(); self?.updateInputMode() }
        input.onOrdinaryEdit = { [weak self] in
            guard let self else { return }
            self.intermediateWord = nil
            self.plannedFor = ""
            self.syncContext()
            self.render()
        }
        input.onCursorChange = { [weak self] in self?.syncContext(); self?.plannedFor = ""; self?.render() }
        input.onWillApplyOutput = { [weak self] output in self?.verifyChordPreview(output) }
        input.onOutput = { [weak self] output in
            guard let self else { return }
            if output.routed.events.contains(where: { if case .modeChanged = $0 { return true }; return false }) { self.syncContext() }
            self.updateInputMode()
            self.render()
        }
        input.onBlockedPaste = { [weak self] in self?.status.stringValue = "Type the words to practice; paste is disabled." }
        newTest()
        selectSection(defaults.string(forKey: "practiceSection").flatMap(PracticeSection.init(rawValue:)) ?? .words)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        heading.textColor = .labelColor
        vocabularyPopup.addItems(withTitles: WordPracticeVocabulary.allCases.map(\.title))
        let savedVocabulary = defaults.string(forKey: "wordSprintVocabulary").flatMap(WordPracticeVocabulary.init(rawValue:)) ?? .english
        vocabularyPopup.selectItem(at: WordPracticeVocabulary.allCases.firstIndex(of: savedVocabulary)!)
        vocabularyPopup.target = self
        vocabularyPopup.action = #selector(configurationChanged)
        vocabularyPopup.setAccessibilityLabel("Word vocabulary")
        vocabularyPopup.toolTip = "English: 200 words · English 5k: 5,000 · English 25k: 24,141 curated words"
        goalControl.selectedSegment = defaults.string(forKey: "wordSprintGoal") == "time" ? 0 : 1
        goalControl.target = self
        goalControl.action = #selector(goalChanged)
        goalControl.setAccessibilityLabel("Test mode")
        PracticeUI.styleSegments(goalControl)
        lengthPopup.target = self
        lengthPopup.action = #selector(configurationChanged)
        lengthPopup.setAccessibilityLabel("Test length")
        updateLengths()
        guideButton.target = self
        guideButton.action = #selector(guideChanged)
        guideButton.keyEquivalent = "h"
        guideButton.keyEquivalentModifierMask = [.command, .shift]
        guideButton.toolTip = "Reveal the chords for this word · ⇧⌘H"
        PracticeUI.styleButton(guideButton)
        guideButton.setAccessibilityLabel("Hint for this word")
        let vocabularyOptions = PracticeUI.column([PracticeUI.label("VOCABULARY", size: 10, weight: .semibold), vocabularyPopup], spacing: 8)
        let sessionOptions = PracticeUI.column([PracticeUI.label("SESSION", size: 10, weight: .semibold),
            PracticeUI.row([goalControl, lengthPopup], spacing: 12)], spacing: 8)
        let options = PracticeUI.row([vocabularyOptions, PracticeUI.spacer(), sessionOptions], spacing: 20)
        let metricTips = [
            "Correct characters divided by five and elapsed minutes.",
            "Correct inserted characters divided by all inserted characters, including corrected mistakes.",
            "Time remaining, or words left to type."
        ]
        let stats: [NSView] = ["WPM", "Accuracy", "Remaining"].enumerated().map { index, name in
            let value = PracticeUI.label("—", size: 26, weight: .medium)
            value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
            value.textColor = index == 0 ? PracticeUI.accentColor : .labelColor
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.toolTip = metricTips[index]
            metricLabels.append(value)
            let label = PracticeUI.label(name, size: 11)
            return PracticeUI.column([label, value], spacing: 4)
        }
        let metricRow = PracticeUI.row(stats, spacing: 12)
        metricRow.distribution = .fillEqually
        passage.frame = NSRect(x: 0, y: 0, width: 800, height: 110)
        passage.setAccessibilityLabel("Words to type")
        passageScroll.documentView = passage
        passageScroll.hasVerticalScroller = true
        passageScroll.autohidesScrollers = true
        passageScroll.drawsBackground = false
        passageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let passageHeight = passageScroll.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.145)
        passageHeight.priority = .init(491)
        input.font = .monospacedSystemFont(ofSize: CGFloat(Settings(defaults: defaults).practiceTextSize), weight: .regular)
        input.placeholder = "Click here and start typing…"
        input.setAccessibilityLabel("Practice typing input")
        input.allowsUndo = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.isContinuousSpellCheckingEnabled = false
        input.isGrammarCheckingEnabled = false
        input.unregisterDraggedTypes()
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = .width
        input.minSize = NSSize(width: 0, height: 80)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        input.backgroundColor = PracticeUI.surfaceColor
        let inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.backgroundColor = PracticeUI.surfaceColor
        inputScroll.borderType = .noBorder
        inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let inputHeight = inputScroll.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.10)
        inputHeight.priority = .init(490)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let next = NSButton(title: "New words", target: self, action: #selector(newTest))
        next.bezelStyle = .rounded
        next.bezelColor = PracticeUI.accentColor
        next.keyEquivalent = "\r"
        next.keyEquivalentModifierMask = [.command]
        next.toolTip = "New words · ⌘Return"
        let retry = NSButton(title: "Retry", target: self, action: #selector(retryTest))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "r"
        retry.keyEquivalentModifierMask = [.command]
        retry.toolTip = "Restart the same words · ⌘R"
        PracticeUI.styleButton(next, primary: true)
        PracticeUI.styleButton(retry)
        let actions = PracticeUI.row([next, retry, PracticeUI.spacer()])
        resultTitle.textColor = .labelColor
        resultDetail.font = .systemFont(ofSize: 13)
        characterDetail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        characterDetail.textColor = .secondaryLabelColor
        chart.heightAnchor.constraint(equalToConstant: 164).isActive = true
        resultCard = PracticeUI.surface(PracticeUI.column([resultTitle, resultDetail, characterDetail, chart], spacing: 12))
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        keyboard.layout = data.layout
        keyboard.meanings = KeyMeanings(data: data, mode: .english)
        keyboard.emphasizesCurrentChord = true
        keyboard.showsFunctionRow = false
        let keyboardHeight = keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.compactAspect)
        keyboardHeight.priority = .init(491); keyboardHeight.isActive = true
        let keyboardViewportHeight = keyboard.heightAnchor.constraint(lessThanOrEqualTo: content.heightAnchor, multiplier: 0.22)
        guideCard = PracticeHints.keyboardGuide(caption: hintCaption, hint: hint, button: guideButton, keyboard: keyboard)
        let passageCard = PracticeUI.surface(PracticeUI.column([
            PracticeUI.label("WORDS TO TYPE", size: 10, weight: .semibold), passageScroll], spacing: 12), padding: 16)
        wordContent = PracticeUI.column([options, passageCard, PracticeUI.surface(inputScroll, padding: 4),
            guideCard, status, metricRow, actions, resultCard], spacing: 12)
        lessonPane.isHidden = true
        voicePane.isHidden = true
        let column = PracticeUI.column([heading, wordContent, lessonPane, voicePane], spacing: 20)
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = PracticeUI.pageColor
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        NSLayoutConstraint.activate([
            passageHeight, inputHeight, keyboardViewportHeight,
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            column.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor, constant: -48)
        ])
    }

    func selectSection(_ section: PracticeSection) {
        input.allowsLocalFocus = section == .words
        input.relinquishFocus()
        lessonPane.deactivate()
        voicePane.deactivate()
        self.section = section
        defaults.set(section.rawValue, forKey: "practiceSection")
        heading.stringValue = section.title
        window?.title = "KeyChord · " + section.title
        wordContent.isHidden = section != .words
        lessonPane.isHidden = section != .lessons
        voicePane.isHidden = section != .voice
        switch section {
        case .words:
            if window?.isVisible == true { window?.makeFirstResponder(input); input.refreshFocus(); syncContext() }
        case .lessons: lessonPane.activate()
        case .voice: voicePane.activate()
        }
    }

    private func perform(_ shortcut: PracticeShortcut) {
        let pane = section == .lessons ? lessonPane : voicePane
        switch shortcut {
        case .hints:
            if section == .words {
                guard guideButton.isEnabled else { return }
                guideChanged()
            } else { pane.requestHint() }
        case .replay: if section == .voice { voicePane.replayPrompt() }
        case .retry: if section == .words { retryTest() } else { pane.retry() }
        case .new: if section == .words { newTest() } else { pane.nextLesson() }
        }
    }

    private var vocabulary: WordPracticeVocabulary { WordPracticeVocabulary.allCases[vocabularyPopup.indexOfSelectedItem] }
    private var goal: WordPracticeGoal {
        goalControl.selectedSegment == 0 ? .time(Self.times[lengthPopup.indexOfSelectedItem]) : .words(Self.counts[lengthPopup.indexOfSelectedItem])
    }
    private func updateLengths() {
        let timed = goalControl.selectedSegment == 0
        let choices = timed ? Self.times : Self.counts
        let saved = defaults.integer(forKey: timed ? "wordSprintSeconds" : "wordSprintWords")
        lengthPopup.removeAllItems()
        lengthPopup.addItems(withTitles: choices.map { "\($0) \(timed ? "s" : "words")" })
        lengthPopup.selectItem(at: choices.firstIndex(of: saved) ?? (timed ? 1 : 0))
    }
    @objc private func goalChanged() { updateLengths(); configurationChanged() }
    @objc private func configurationChanged() {
        defaults.set(vocabulary.rawValue, forKey: "wordSprintVocabulary")
        defaults.set(goalControl.selectedSegment == 0 ? "time" : "words", forKey: "wordSprintGoal")
        switch goal {
        case .time(let seconds): defaults.set(seconds, forKey: "wordSprintSeconds")
        case .words(let count): defaults.set(count, forKey: "wordSprintWords")
        }
        newTest()
    }
    @objc private func guideChanged() {
        guard chordEnabled, !session.isFinished else { return }
        hintedWord = session.currentWordIndex
        plannedFor = ""
        usedGuide = true
        render()
        window?.makeFirstResponder(input)
    }
    @objc func newTest() {
        let previous = session?.targetWords.first
        session = WordPracticeSession(vocabulary: vocabulary, goal: goal, seed: seed(), words: wordSource)
        if session.targetWords.first == previous { session = WordPracticeSession(vocabulary: vocabulary, goal: goal, seed: seed() &+ 1, words: wordSource) }
        resetInput()
    }
    @objc func retryTest() {
        session = session.restarted()
        resetInput()
    }
    private func resetInput() {
        timer?.invalidate()
        timer = nil
        usedChords = false; usedKeyboard = false; usedGuide = false; announcedFinish = false
        hintedWord = nil
        planRequest += 1; plannedFor = ""
        verifiedChordPreview = false; intermediateWord = nil
        chart.samples = []
        resultDetail.stringValue = ""
        characterDetail.stringValue = ""
        input.isEditable = true
        input.clearForTask()
        input.practice.setChordEnabled(chordEnabled)
        render()
        if section == .words, window?.isVisible == true { window?.makeFirstResponder(input); input.refreshFocus() }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard textView === input, let replacement = replacementString, let stringRange = Range(range, in: input.string) else { return false }
        if !input.isApplyingChordOutput, replacement.count > 1 { input.onBlockedPaste?(); return false }
        let start = input.string.distance(from: input.string.startIndex, to: stringRange.lowerBound)
        let end = input.string.distance(from: input.string.startIndex, to: stringRange.upperBound)
        guard session.edit(range: start..<end, replacement: replacement, at: clock(),
                           verifiedChordPreview: input.isApplyingChordOutput && verifiedChordPreview) else { return false }
        if !replacement.isEmpty {
            usedChords = usedChords || input.isApplyingChordOutput
            usedKeyboard = usedKeyboard || !input.isApplyingChordOutput
            usedGuide = usedGuide || (hintedWord != nil && input.practice.chordEnabled)
        }
        startTimerIfNeeded()
        return true
    }
    func textDidChange(_ notification: Notification) {
        if !input.isApplyingChordOutput { render() }
    }
    func tick() { session.advance(to: clock()); render() }
    private func startTimerIfNeeded() {
        guard timer == nil, session.startedAt != nil, !session.isFinished else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateInputMode() {
        guard input.practice.ownsInput else { return }
        if chordEnabled != input.practice.chordEnabled {
            chordEnabled = input.practice.chordEnabled
            defaults.set(!chordEnabled, forKey: "wordSprintKeyboard")
        }
        if !chordEnabled { hintedWord = nil }
        guideButton.isEnabled = chordEnabled && !session.isFinished
    }

    /// Correct suffix chords can temporarily spell a base differently from the final word:
    /// make → making, happy → happiest. Replay the real planner's intermediate states so
    /// these required edits do not register as mistyped characters.
    private func verifyChordPreview(_ output: LocalChordOutput) {
        verifiedChordPreview = false
        guard let attempt = output.attempt, attempt.signal == nil,
              input.selectedRange().length == 0, input.selectedRange().location == input.string.utf16.count else { return }
        var buffer = Array(input.string)
        for action in output.routed.actions {
            switch action {
            case .insert(let text): buffer.append(contentsOf: text)
            case .deleteBackward(let count):
                guard count <= buffer.count else { return }
                buffer.removeLast(count)
            case .deleteForward, .moveLeft, .moveRight: return
            }
        }
        let projected = String(buffer)
        let index = projected.filter { $0 == " " }.count
        guard index < session.targetWords.count else { return }
        let word = session.targetWords[index]
        let token = projected.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let plan: TypingGuide
        if let cached = wordPlans[word] { plan = cached }
        else { plan = wordPlanner.plan(word); wordPlans[word] = plan }
        let chars = Array(word)
        for (stepIndex, step) in plan.steps.enumerated() {
            guard case .chord(let names, _) = step.action,
                  data.layout.keySet(names: names) == attempt.keys,
                  String(chars.prefix(step.prefixEnd)) + step.tail == token else { continue }
            verifiedChordPreview = true
            intermediateWord = (index, token, stepIndex + 1 < plan.steps.count ? plan.steps[stepIndex + 1] : nil, step.contextAfter)
            plannedFor = ""
            planRequest += 1
            return
        }
        intermediateWord = nil
    }
    private func syncContext() {
        guard session != nil, !session.isFinished else { return }
        let offset = input.selectedRange().location
        let prefix = (input.string as NSString).substring(to: min(offset, input.string.utf16.count))
        let index = prefix.filter { $0 == " " }.count
        let token = prefix.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if offset == input.string.utf16.count, let preview = intermediateWord,
           preview.index == index, preview.text == token, let context = preview.context {
            input.practice.restoreContext(context)
            return
        }
        let atEnd = index < session.targetWords.count && token == session.targetWords[index]
        input.practice.restoreContext(atEnd ? .afterWord : .initial)
    }

    private func render() {
        guard session != nil else { return }
        let metrics = session.metrics(at: clock())
        let started = session.startedAt != nil
        metricLabels[0].stringValue = started ? String(format: "%.0f", metrics.wpm) : "—"
        metricLabels[1].stringValue = String(format: "%.0f%%", metrics.accuracy)
        switch session.goal {
        case .time(let limit): metricLabels[2].stringValue = "\(max(0, Int((Double(limit) - metrics.elapsed).rounded(.up))))s"
        case .words(let limit): metricLabels[2].stringValue = "\(max(0, limit - metrics.completedWords))"
        }
        for (index, title) in ["WPM", "Accuracy", "Remaining"].enumerated() {
            metricLabels[index].setAccessibilityLabel(title + ": " + metricLabels[index].stringValue)
        }
        renderPassage()
        keyboard.held = Set(input.practice.heldKeys.indices.map { data.layout.keys[$0].code })
        resultCard.isHidden = !session.isFinished
        guideButton.isEnabled = chordEnabled && !session.isFinished
        if hintedWord != session.currentWordIndex || !chordEnabled || session.isFinished {
            hintedWord = nil
            planRequest += 1; plannedFor = ""
            keyboard.target = []
        }
        hintCaption.stringValue = hintedWord == nil ? "KEYBOARD" : "THIS WORD"
        hint.textColor = hintedWord == nil ? .secondaryLabelColor : .labelColor
        if session.isFinished {
            timer?.invalidate(); timer = nil
            input.isEditable = false
            input.relinquishFocus()
            let method = usedChords && usedKeyboard ? "Chords + keyboard" : usedChords ? "Chords" : "Keyboard"
            resultDetail.stringValue = "\(session.vocabulary.title) · \(session.goal.title) · \(method)\(usedGuide ? " · guided" : "") · \(String(format: "%.1f", metrics.elapsed))s"
            characterDetail.stringValue = "\(metrics.correctWords) correct words · \(metrics.mistakes) \(metrics.mistakes == 1 ? "mistake" : "mistakes") · \(String(format: "%.0f", metrics.rawWPM)) raw WPM"
            chart.samples = session.samples
            status.stringValue = "Practice complete. Try new words or retry."
            hint.stringValue = "Start new words or retry to keep practicing."
            keyboard.held = []
            if !announcedFinish {
                announcedFinish = true
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Practice complete. \(metricLabels[0].stringValue) words per minute. \(metricLabels[1].stringValue) accuracy.",
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        } else {
            status.stringValue = started ? "\(metrics.completedWords) words complete · Space moves on · Backspace corrects mistakes"
                : chordEnabled ? "Hold the chord keys together, then release. Right Option switches to ordinary typing."
                : "Type the words. Right Option switches to chords."
            if hintedWord != nil { updateGuide() }
            else { hint.stringValue = chordEnabled ? "Reveal the combination for this word with Hint or ⇧⌘H."
                                                   : "Tap right Option to use chords." }
        }
    }

    private func renderPassage() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        let output = NSMutableAttributedString(string: "")
        let actual = session.typedWords
        let current = session.currentWordIndex
        var activeRange: NSRange?
        var lastRange = NSRange(location: 0, length: 0)
        // Keep long timed sessions bounded in the view; the session retains the targets for scoring.
        let first = max(0, current - 12)
        let last = min(session.targetWords.count, current + 40)
        for index in first..<last {
            if index > first { output.append(NSAttributedString(string: " ")) }
            let wordStart = output.length
            let expected = Array(session.targetWords[index])
            let entered = index < actual.count ? Array(actual[index]) : []
            for (position, character) in expected.enumerated() {
                var color: NSColor = .secondaryLabelColor
                if position < entered.count {
                    let preview = intermediateWord.map { $0.index == index && $0.text == String(entered) } == true
                    color = preview || character == entered[position] ? .labelColor : .systemRed
                }
                else if index < current { color = .systemRed }
                else if index == current { color = .labelColor }
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if index == current, position == entered.count, !session.isFinished {
                    attributes[.backgroundColor] = PracticeUI.accentColor.withAlphaComponent(0.18)
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = PracticeUI.accentColor
                }
                output.append(NSAttributedString(string: String(character), attributes: attributes))
            }
            if entered.count > expected.count {
                output.append(NSAttributedString(string: String(entered.dropFirst(expected.count)), attributes: [.foregroundColor: NSColor.systemRed]))
            }
            lastRange = NSRange(location: wordStart, length: output.length - wordStart)
            if index == current { activeRange = lastRange }
        }
        if output.length > 0 {
            output.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: CGFloat(Settings(defaults: defaults).practiceTextSize), weight: .regular),
                                  .paragraphStyle: paragraph], range: NSRange(location: 0, length: output.length))
        }
        passage.activeWordRange = activeRange ?? lastRange
        passage.textStorage.setAttributedString(output)
        passage.followActiveWord()
    }

    private func updateGuide() {
        let key = input.string + "|\(input.selectedRange().location)"
        guard key != plannedFor else { return }
        plannedFor = key
        planRequest += 1
        let request = planRequest, typed = input.string
        let index = session.currentWordIndex
        guard index < session.targetWords.count else { return }
        let token = session.typedWords.last ?? ""
        let word = session.targetWords[index]
        guard input.selectedRange().location == typed.utf16.count else {
            hint.stringValue = "Move to the end of your input to see the next chord."
            keyboard.target = []
            return
        }
        if let preview = intermediateWord, preview.index == index, preview.text == token, let step = preview.nextStep {
            showHint(step)
            return
        }
        guard word.hasPrefix(token) else {
            hint.stringValue = "Correct the red letters, or press Space to move on."
            keyboard.target = []
            return
        }
        guard token != word else {
            hint.stringValue = "Press Space to continue."
            keyboard.target = [49]
            return
        }
        let suffix = String(word.dropFirst(token.count))
            + (index + 1 < session.targetWords.count ? " " + session.targetWords[index + 1] : "")
        let data = data, limit = rolloverLimit, usable = usable
        hint.stringValue = "Finding the next chord…"
        planningQueue.async { [weak self] in
            let planner = TypingPlanner(data: data, mode: .english, rolloverLimit: limit, usable: usable)
            let plan = planner.planContinuation(typed + suffix, from: typed.count)
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.planRequest, self.hintedWord == index,
                      self.chordEnabled, !self.session.isFinished else { return }
                guard let step = plan.guide.steps.first else { self.hint.stringValue = ""; self.keyboard.target = []; return }
                self.showHint(step)
            }
        }
    }

    private func showHint(_ step: TypingStep) {
        switch step.action {
        case .chord(let names, let shift):
            let codes = names.compactMap { data.layout.indexByName[$0] }.map { data.layout.keys[$0].code }
            keyboard.target = Set(codes + (shift ? [56] : []))
            hint.stringValue = "\(ChordDisplay.visible(step.output)): " + codes.map { KeyboardDiagramView.name(for: $0) }.joined(separator: " + ") + (shift ? " + Shift" : "")
        case .typeNormally(let text): hint.stringValue = "Tap right Option and type \(text)."; keyboard.target = []
        case .key: hint.stringValue = "Press Space to continue."; keyboard.target = []
        }
    }

    /// A customization refreshes the engine and hints while retaining the passage, input and results.
    func update(data: EngineData, rolloverLimit: Int, usable: @escaping (KeySet) -> Bool) {
        self.data = data; self.rolloverLimit = rolloverLimit; self.usable = usable
        input.practice.replaceData(data)
        wordPlanner = TypingPlanner(data: data, mode: .english, rolloverLimit: rolloverLimit, usable: usable)
        wordPlans.removeAll(); planRequest += 1; plannedFor = ""; intermediateWord = nil
        keyboard.layout = data.layout; keyboard.meanings = KeyMeanings(data: data, mode: .english)
        lessonPane.update(data: data, rolloverLimit: rolloverLimit, usable: usable)
        voicePane.update(data: data, rolloverLimit: rolloverLimit, usable: usable)
        syncContext(); render()
    }

    func present() {
        tick()
        startTimerIfNeeded()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusCurrentSection()
    }
    private func focusCurrentSection() {
        switch section {
        case .words: window?.makeFirstResponder(input); input.refreshFocus(); syncContext()
        case .lessons: lessonPane.activate()
        case .voice: voicePane.activate()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { focusCurrentSection() }
    func windowDidResignKey(_ notification: Notification) { input.relinquishFocus(); lessonPane.deactivate(); voicePane.deactivate() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        input.relinquishFocus(); lessonPane.deactivate(); voicePane.deactivate()
    }
}

/// Cumulative speed and per-sample errors, drawn natively with adaptive colors.
final class PracticeChartView: NSView {
    var samples: [WordPracticeSample] = [] { didSet { needsDisplay = true } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Typing speed over time. Blue: WPM. Gray: raw WPM. Red marks: errors." }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let last = samples.last, last.seconds > 0 else { return }
        let plot = bounds.insetBy(dx: 36, dy: 26)
        let maximum = max(20, (samples.map { max($0.wpm, $0.rawWPM) }.max() ?? 20).rounded(.up))
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for tick in 0...2 {
            let y = plot.minY + plot.height * CGFloat(tick) / 2
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.setStroke(); line.stroke()
            NSAttributedString(string: "\(Int(maximum * Double(tick) / 2))", attributes: style).draw(at: NSPoint(x: 0, y: y - 5))
        }
        for raw in [true, false] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: plot.minY))
            for sample in samples {
                path.line(to: NSPoint(x: plot.minX + plot.width * sample.seconds / last.seconds,
                                      y: plot.minY + plot.height * (raw ? sample.rawWPM : sample.wpm) / maximum))
            }
            (raw ? NSColor.secondaryLabelColor : PracticeUI.accentColor).setStroke()
            path.lineWidth = raw ? 1.5 : 2.5
            path.stroke()
        }
        NSColor.systemRed.setFill()
        for sample in samples where sample.errors > 0 {
            let x = plot.minX + plot.width * sample.seconds / last.seconds
            NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: plot.minY - 2.5, width: 5, height: 5)).fill()
        }
        NSAttributedString(string: "0s", attributes: style).draw(at: NSPoint(x: plot.minX, y: 3))
        NSAttributedString(string: String(format: "%.1fs", last.seconds), attributes: style).draw(at: NSPoint(x: plot.maxX - 40, y: 3))
        NSAttributedString(string: "WPM  ·  raw  ·  errors", attributes: style).draw(at: NSPoint(x: plot.minX + 60, y: 3))
    }
}
