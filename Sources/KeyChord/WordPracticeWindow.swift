import AppKit
import KeyChordCore

/// Responder-chain input uses the existing local chord engine and focus lease.
/// Bulk native insertions and drag/drop cannot turn a pasted passage into a typing result.
final class WordPracticeInputView: LocalChordInputView {
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

final class WordPracticeWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onLocalFocus: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let data: EngineData
    private let rolloverLimit: Int
    private let usable: (KeySet) -> Bool
    private let clock: () -> Double
    private let seed: () -> UInt64
    private let wordSource: [String]?
    private let input: WordPracticeInputView
    private(set) var session: WordPracticeSession!
    private var timer: Timer?
    private let vocabularyPopup = NSPopUpButton()
    private let goalControl = NSSegmentedControl(labels: ["Time", "Words"], trackingMode: .selectOne, target: nil, action: nil)
    private let lengthPopup = NSPopUpButton()
    private let inputMode = NSSegmentedControl(labels: ["Chords", "Keyboard"], trackingMode: .selectOne, target: nil, action: nil)
    private let guideButton = NSButton(checkboxWithTitle: "Show chord guide", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let passage = NSTextView()
    private let passageScroll = NSScrollView()
    private let resultTitle = PracticeUI.label("Test complete", size: 20, weight: .semibold)
    private let resultDetail = NSTextField(wrappingLabelWithString: "")
    private let characterDetail = NSTextField(wrappingLabelWithString: "")
    private let chart = WordPracticeChartView()
    private var resultCard: NSBox!
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let keyboard = KeyboardDiagramView()
    private var guideCard: NSStackView!
    private var metricLabels: [NSTextField] = []
    private let planningQueue = DispatchQueue(label: "KeyChord.word-sprint-planning", qos: .userInitiated)
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
         focus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true }, wordSource: [String]? = nil) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.usable = usable
        self.defaults = defaults
        self.clock = clock
        self.seed = seed
        self.wordSource = wordSource
        input = WordPracticeInputView(data: data, focus: focus, globalSuspended: globalSuspended)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 810),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyChord · Word Sprint"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 620)
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName("KeyChordWordSprint")
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        buildUI()
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
        input.onCursorChange = { [weak self] in self?.syncContext() }
        input.onWillApplyOutput = { [weak self] output in self?.verifyChordPreview(output) }
        input.onOutput = { [weak self] output in
            guard let self else { return }
            if output.routed.events.contains(where: { if case .modeChanged = $0 { return true }; return false }) { self.syncContext() }
            self.updateInputMode()
            self.render()
        }
        input.onBlockedPaste = { [weak self] in self?.status.stringValue = "Paste is disabled during a typing test." }
        newTest()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = PracticeUI.label("Word Sprint", size: 28, weight: .bold)
        title.textColor = .labelColor
        let subtitle = NSTextField(wrappingLabelWithString: "Choose a vocabulary and type. The test starts on your first character.")
        subtitle.textColor = .secondaryLabelColor
        vocabularyPopup.addItems(withTitles: WordPracticeVocabulary.allCases.map(\.title))
        let savedVocabulary = defaults.string(forKey: "wordSprintVocabulary").flatMap(WordPracticeVocabulary.init(rawValue:)) ?? .english5k
        vocabularyPopup.selectItem(at: WordPracticeVocabulary.allCases.firstIndex(of: savedVocabulary)!)
        vocabularyPopup.target = self
        vocabularyPopup.action = #selector(configurationChanged)
        vocabularyPopup.setAccessibilityLabel("Word vocabulary")
        vocabularyPopup.toolTip = "English: 200 words · English 5k: 5,000 · English 25k: 24,141 curated words"
        goalControl.selectedSegment = defaults.string(forKey: "wordSprintGoal") == "words" ? 1 : 0
        goalControl.target = self
        goalControl.action = #selector(goalChanged)
        goalControl.setAccessibilityLabel("Test mode")
        lengthPopup.target = self
        lengthPopup.action = #selector(configurationChanged)
        lengthPopup.setAccessibilityLabel("Test length")
        updateLengths()
        inputMode.selectedSegment = defaults.bool(forKey: "wordSprintKeyboard") ? 1 : 0
        inputMode.target = self
        inputMode.action = #selector(inputMethodChanged)
        inputMode.setAccessibilityLabel("Typing method")
        guideButton.state = defaults.bool(forKey: "wordSprintGuide") ? .on : .off
        guideButton.target = self
        guideButton.action = #selector(guideChanged)
        let options = PracticeUI.row([vocabularyPopup, PracticeUI.spacer(), goalControl, lengthPopup])
        let methods = PracticeUI.row([inputMode, guideButton, PracticeUI.spacer()])
        let metricTips = [
            "Correctly completed words and the correct current prefix, divided by five characters per word and elapsed minutes.",
            "All characters currently entered, including errors and spaces, divided by five and elapsed minutes. Deleted characters are excluded.",
            "Correct inserted characters divided by all inserted characters. Verified intermediate chord bases count as correct. Correcting a mistake does not erase the attempt.",
            "Steadiness of characters entered per second: 100 × (1 − standard deviation / mean), clamped to 0–100. Available after two seconds.",
            "Time remaining, or words completed. The timer keeps running while this window is out of focus."
        ]
        let stats: [NSView] = ["WPM", "Raw WPM", "Accuracy", "Consistency", "Remaining"].enumerated().map { index, name in
            let value = PracticeUI.label("—", size: 28, weight: .medium)
            value.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
            value.textColor = index == 0 ? PracticeUI.accentColor : .labelColor
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.toolTip = metricTips[index]
            metricLabels.append(value)
            let label = PracticeUI.label(name, size: 11)
            let column = PracticeUI.column([label, value], spacing: 4)
            column.toolTip = metricTips[index]
            return column
        }
        let metricRow = PracticeUI.row(stats, spacing: 12)
        metricRow.distribution = .fillEqually
        passage.isEditable = false
        passage.isSelectable = false
        passage.isRichText = false
        passage.drawsBackground = false
        passage.isVerticallyResizable = true
        passage.isHorizontallyResizable = false
        passage.autoresizingMask = .width
        passage.minSize = NSSize(width: 0, height: 184)
        passage.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        passage.frame = NSRect(x: 0, y: 0, width: 800, height: 184)
        passage.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        passage.textContainer?.widthTracksTextView = true
        passage.textContainerInset = NSSize(width: 2, height: 10)
        passage.setAccessibilityLabel("Words to type")
        passageScroll.documentView = passage
        passageScroll.hasVerticalScroller = true
        passageScroll.autohidesScrollers = true
        passageScroll.drawsBackground = false
        passageScroll.heightAnchor.constraint(equalToConstant: 184).isActive = true
        input.font = .monospacedSystemFont(ofSize: CGFloat(Settings(defaults: defaults).practiceTextSize), weight: .regular)
        input.placeholder = "Click here and start typing…"
        input.setAccessibilityLabel("Word Sprint typing input")
        input.allowsUndo = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.isContinuousSpellCheckingEnabled = false
        input.isGrammarCheckingEnabled = false
        input.unregisterDraggedTypes()
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = .width
        input.minSize = NSSize(width: 0, height: 104)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.frame = NSRect(x: 0, y: 0, width: 800, height: 104)
        let inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.heightAnchor.constraint(equalToConstant: 104).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let next = NSButton(title: "New test", target: self, action: #selector(newTest))
        next.bezelStyle = .rounded
        next.bezelColor = PracticeUI.accentColor
        next.keyEquivalent = "\r"
        next.keyEquivalentModifierMask = [.command]
        next.toolTip = "New words · ⌘Return"
        let retry = NSButton(title: "Retry these words", target: self, action: #selector(retryTest))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "r"
        retry.keyEquivalentModifierMask = [.command]
        retry.toolTip = "Restart the same words · ⌘R"
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
        keyboard.heightAnchor.constraint(equalToConstant: 220).isActive = true
        guideCard = PracticeUI.column([hint, keyboard], spacing: 10)
        let column = PracticeUI.column([title, subtitle, options, methods, PracticeUI.surface(metricRow),
            PracticeUI.surface(passageScroll), PracticeUI.surface(inputScroll, padding: 4), status, actions, resultCard, guideCard], spacing: 16)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let width = column.widthAnchor.constraint(equalToConstant: 800)
        width.priority = .init(490)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -48),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 800), width,
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
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
        lengthPopup.selectItem(at: choices.firstIndex(of: saved) ?? 1)
    }
    @objc private func goalChanged() { updateLengths(); configurationChanged() }
    @objc private func configurationChanged() {
        defaults.set(vocabulary.rawValue, forKey: "wordSprintVocabulary")
        defaults.set(goalControl.selectedSegment == 0 ? "time" : "words", forKey: "wordSprintGoal")
        switch goal {
        case .time(let seconds): defaults.set(seconds, forKey: "wordSprintSeconds")
        case .words(let count): defaults.set(count, forKey: "wordSprintWords")
        }
        defaults.set(inputMode.selectedSegment == 1, forKey: "wordSprintKeyboard")
        newTest()
    }
    @objc private func guideChanged() {
        defaults.set(guideButton.state == .on, forKey: "wordSprintGuide")
        if guideButton.state == .on, session.startedAt != nil { usedGuide = true }
        render()
        window?.makeFirstResponder(input)
    }
    @objc private func inputMethodChanged() {
        defaults.set(inputMode.selectedSegment == 1, forKey: "wordSprintKeyboard")
        input.practice.setChordEnabled(inputMode.selectedSegment == 0)
        window?.makeFirstResponder(input)
        input.refreshFocus()
        syncContext()
        plannedFor = ""
        render()
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
        usedChords = false; usedKeyboard = false; usedGuide = false; announcedFinish = false
        planRequest += 1; plannedFor = ""
        verifiedChordPreview = false; intermediateWord = nil
        chart.samples = []
        resultDetail.stringValue = ""
        characterDetail.stringValue = ""
        input.isEditable = true
        input.clearForTask()
        input.practice.setChordEnabled(inputMode.selectedSegment == 0)
        render()
        if window?.isVisible == true { window?.makeFirstResponder(input); input.refreshFocus() }
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
            usedGuide = usedGuide || (guideButton.state == .on && input.practice.chordEnabled)
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
        inputMode.selectedSegment = input.practice.chordEnabled ? 0 : 1
        guideButton.isEnabled = inputMode.selectedSegment == 0
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
        metricLabels[1].stringValue = started ? String(format: "%.0f", metrics.rawWPM) : "—"
        metricLabels[2].stringValue = String(format: "%.0f%%", metrics.accuracy)
        metricLabels[3].stringValue = metrics.elapsed >= 2 ? String(format: "%.0f%%", metrics.consistency) : "—"
        switch session.goal {
        case .time(let limit): metricLabels[4].stringValue = "\(max(0, Int((Double(limit) - metrics.elapsed).rounded(.up))))s"
        case .words(let limit): metricLabels[4].stringValue = "\(max(0, limit - metrics.completedWords))"
        }
        for (index, title) in ["WPM", "Raw WPM", "Accuracy", "Consistency", "Remaining"].enumerated() {
            metricLabels[index].setAccessibilityLabel(title + ": " + metricLabels[index].stringValue)
        }
        renderPassage()
        keyboard.held = Set(input.practice.heldKeys.indices.map { data.layout.keys[$0].code })
        resultCard.isHidden = !session.isFinished
        guideButton.isEnabled = inputMode.selectedSegment == 0
        guideCard.isHidden = guideButton.state != .on || inputMode.selectedSegment != 0 || session.isFinished
        if session.isFinished {
            timer?.invalidate(); timer = nil
            input.isEditable = false
            input.relinquishFocus()
            let method = usedChords && usedKeyboard ? "Chords + keyboard" : usedChords ? "Chords" : "Keyboard"
            resultDetail.stringValue = "\(session.vocabulary.title) · \(session.goal.title) · \(method)\(usedGuide ? " · guided" : "") · \(String(format: "%.1f", metrics.elapsed))s"
            characterDetail.stringValue = "Characters: \(metrics.correct) correct / \(metrics.incorrect) incorrect / \(metrics.extra) extra / \(metrics.missed) missed\n\(metrics.correctWords) correct words · \(metrics.mistakes) mistyped characters, including corrected mistakes"
            chart.samples = session.samples
            status.stringValue = "Test complete. Start a new test, or retry the same words."
            if !announcedFinish {
                announcedFinish = true
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Test complete. \(metricLabels[0].stringValue) words per minute. \(metricLabels[2].stringValue) accuracy.",
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        } else {
            status.stringValue = started ? "\(metrics.completedWords) words complete · Space moves on · Backspace corrects mistakes"
                : inputMode.selectedSegment == 0 ? "Chord words as usual; spaces between words are automatic. Tap right Option to switch to keyboard typing."
                : "Type the highlighted words. Space moves on; Backspace corrects mistakes."
            if !guideCard.isHidden { updateGuide() }
        }
    }

    private func renderPassage() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        let output = NSMutableAttributedString(string: "")
        let actual = session.typedWords
        let current = session.currentWordIndex
        var cursor = 0
        // Keep long timed sessions bounded in the view; the session retains the targets for scoring.
        let first = max(0, current - 12)
        let last = min(session.targetWords.count, current + 40)
        for index in first..<last {
            if index > first { output.append(NSAttributedString(string: " ")) }
            let expected = Array(session.targetWords[index])
            let entered = index < actual.count ? Array(actual[index]) : []
            if index == current { cursor = output.length + min(entered.count, expected.count) }
            for (position, character) in expected.enumerated() {
                var color: NSColor = .tertiaryLabelColor
                if position < entered.count {
                    let preview = intermediateWord.map { $0.index == index && $0.text == String(entered) } == true
                    color = preview || character == entered[position] ? .labelColor : .systemRed
                }
                else if index < current { color = .systemRed }
                else if index == current { color = .secondaryLabelColor }
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
        }
        if output.length > 0 {
            output.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: CGFloat(Settings(defaults: defaults).practiceTextSize), weight: .regular),
                                  .paragraphStyle: paragraph], range: NSRange(location: 0, length: output.length))
        }
        passage.textStorage?.setAttributedString(output)
        passage.scrollRangeToVisible(NSRange(location: min(cursor, output.length), length: 0))
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
        let suffix = String(word.dropFirst(token.count))
            + (index + 1 < session.targetWords.count ? " " + session.targetWords[index + 1] : "")
        let data = data, limit = rolloverLimit, usable = usable
        hint.stringValue = "Preparing chord guide…"
        planningQueue.async { [weak self] in
            let planner = TypingPlanner(data: data, mode: .english, rolloverLimit: limit, usable: usable)
            let plan = planner.planContinuation(typed + suffix, from: typed.count)
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.planRequest, !self.session.isFinished else { return }
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
            hint.stringValue = "\(TypingGuideWindowController.visible(step.output)): " + codes.map { KeyboardDiagramView.name(for: $0) }.joined(separator: " + ") + (shift ? " + Shift" : "")
        case .typeNormally(let text): hint.stringValue = "Tap right Option and type \(text)."; keyboard.target = []
        case .key: hint.stringValue = "Press Space to continue."; keyboard.target = []
        }
    }

    func present() {
        tick()
        startTimerIfNeeded()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
        input.refreshFocus()
    }
    func windowDidBecomeKey(_ notification: Notification) { input.refreshFocus(); syncContext() }
    func windowDidResignKey(_ notification: Notification) { input.relinquishFocus() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; input.relinquishFocus() }
}

/// Cumulative speed and per-sample errors, drawn natively with adaptive colors.
final class WordPracticeChartView: NSView {
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
