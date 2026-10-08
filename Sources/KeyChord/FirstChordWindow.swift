import AppKit
import KeyChordCore

/// An NSTextView receives local NSEvents through the responder chain. It never monitors another
/// window, requests a permission, posts a system event, or accepts a global output-emitter result.
final class LocalChordInputView: NSTextView {
    let practice: LocalChordPractice
    var onFocus: ((Bool) -> Void)?
    var onReadinessChanged: (() -> Void)?
    var onOutput: ((LocalChordOutput) -> Void)?
    var onOrdinaryEdit: (() -> Void)?
    private let focusOverride: (() -> Bool)?
    private var applyingOutput = false
    private var lease = false
    private var suppressionAvailable: () -> Bool
    var placeholder = "" { didSet { needsDisplay = true } }
    /// NSTextView's designated initializer uses the caller's text system. Keep its storage
    /// alive; it owns the layout manager and container used for native editing and Undo.
    private let localTextStorage: NSTextStorage

    init(data: EngineData, focus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true }) {
        practice = LocalChordPractice(data: data)
        focusOverride = focus
        suppressionAvailable = globalSuspended
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        localTextStorage = storage
        super.init(frame: .zero, textContainer: container)
        container.widthTracksTextView = true
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        font = .systemFont(ofSize: 28)
        textContainerInset = NSSize(width: 12, height: 14)
        backgroundColor = .textBackgroundColor
        setAccessibilityLabel("Local chord practice input")
    }
    required init?(coder: NSCoder) { fatalError() }

    var ownsLocalInput: Bool {
        isEditable && (focusOverride?() ?? (window?.isKeyWindow == true && window?.firstResponder === self))
    }

    /// AppController's lease callback pauses its router synchronously before any local composition.
    func refreshFocus() {
        let focused = ownsLocalInput
        let previouslyOwned = practice.ownsInput
        if focused != lease { lease = focused; onFocus?(focused) }
        practice.setFocus(focused, globalCaptureSuspended: focused && suppressionAvailable())
        if previouslyOwned != practice.ownsInput { onReadinessChanged?() }
    }

    func relinquishFocus() {
        let previouslyOwned = practice.ownsInput
        if lease { lease = false; onFocus?(false) }
        practice.setFocus(false, globalCaptureSuspended: false)
        if previouslyOwned != practice.ownsInput { onReadinessChanged?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // During the responder transition the window still points at the previous responder.
        if accepted { DispatchQueue.main.async { [weak self] in self?.refreshFocus() } }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { relinquishFocus() }
        return accepted
    }

    /// Also used by the native no-global-input checks; the caller supplies a local event value.
    @discardableResult
    func process(_ input: RouterInput) -> LocalChordOutput {
        refreshFocus()
        let output = practice.handle(input)
        if !output.routed.actions.isEmpty { apply(output.routed.actions) }
        onOutput?(output)
        return output
    }

    override func keyDown(with event: NSEvent) {
        let out = process(.keyDown(code: event.keyCode, isRepeat: event.isARepeat,
                                   flags: Self.flags(event), time: EventConversion.nowMs()))
        if out.routed.decision == .pass { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        let out = process(.keyUp(code: event.keyCode, flags: Self.flags(event), time: EventConversion.nowMs()))
        if out.routed.decision == .pass { super.keyUp(with: event) }
    }
    override func flagsChanged(with event: NSEvent) {
        if let (key, down) = EventConversion.modifierChange(code: event.keyCode,
                                                          flags: UInt64(event.modifierFlags.rawValue)) {
            let input: RouterInput = down
                ? .modifierDown(code: event.keyCode, key: key, time: EventConversion.nowMs())
                : .modifierUp(code: event.keyCode, key: key, time: EventConversion.nowMs())
            _ = process(input)
        }
        super.flagsChanged(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        practice.ordinaryEdit()
        super.mouseDown(with: event)
        refreshFocus()
    }

    override func didChangeText() {
        super.didChangeText()
        if !applyingOutput { practice.ordinaryEdit(); onOrdinaryEdit?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: CGFloat(DesignSystem.Typography.practice)),
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !applyingOutput && selectedRanges != ranges { practice.ordinaryEdit() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    func clearForTask() {
        applyingOutput = true
        string = ""
        setSelectedRange(NSRange(location: 0, length: 0))
        undoManager?.removeAllActions()
        applyingOutput = false
        practice.reset()
    }

    func showDemonstration(_ text: String) {
        applyingOutput = true
        string = text
        setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        undoManager?.removeAllActions()
        applyingOutput = false
    }

    private func apply(_ actions: [OutputAction]) {
        guard practice.ownsInput, ownsLocalInput else { return }
        applyingOutput = true
        undoManager?.beginUndoGrouping()
        for action in actions {
            switch action {
            case .insert(let text): insertText(text, replacementRange: selectedRange())
            case .deleteBackward(let count): for _ in 0..<count { deleteBackward(nil) }
            case .deleteForward(let count): for _ in 0..<count { deleteForward(nil) }
            case .moveLeft(let count): for _ in 0..<count { moveLeft(nil) }
            case .moveRight(let count): for _ in 0..<count { moveRight(nil) }
            }
        }
        undoManager?.endUndoGrouping()
        applyingOutput = false
    }

    private static func flags(_ event: NSEvent) -> ModifierFlags {
        EventConversion.flags(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
    }
}

final class FirstChordWindowController: NSWindowController, NSWindowDelegate {
    var onLocalFocus: ((Bool) -> Void)?
    var onContinueCourse: (() -> Void)?
    var onTestOut: (() -> Void)?
    var onUseInEditor: (() -> Void)?
    private let data: EngineData
    private let store: LearningJourneyStore
    private let recipes: [String: FirstChordRecipe]
    private let undoKeys: KeySet?
    private var journey: FirstChordJourney
    private var demonstration = 0
    private var hintForCurrent = false
    private var latestFeedback = ""
    let input: LocalChordInputView
    private let stageLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let answer = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let readiness = NSTextField(wrappingLabelWithString: "")
    private let keyboard = KeyboardDiagramView()
    private var keyboardHost: NSView!
    private var inputSurface: NSBox!
    private var course: PracticeActionButton!
    private var testOut: PracticeActionButton!
    private var inputScroll: NSScrollView!
    private var nextDemo: PracticeActionButton!
    private var start: PracticeActionButton!
    private var hint: PracticeActionButton!
    private var restart: PracticeActionButton!
    private var use: PracticeActionButton!

    init(data: EngineData, rolloverLimit: Int = 6, usable: @escaping (KeySet) -> Bool = { _ in true },
         store: LearningJourneyStore, stage: FirstChordStage = .see,
         focus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true }) {
        self.data = data
        self.store = store
        journey = FirstChordJourney(stage: stage)
        var recipes: [String: FirstChordRecipe] = [:]
        for word in FirstChordJourney.words {
            recipes[word] = FirstChordRecipe(word: word, data: data, rolloverLimit: rolloverLimit, usable: usable)
        }
        self.recipes = recipes
        let undo = KeyMeanings(data: data, mode: .english).undoKeys
        undoKeys = undo.flatMap { $0.count <= rolloverLimit && usable($0) ? $0 : nil }
        input = LocalChordInputView(data: data, focus: focus, globalSuspended: globalSuspended)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyChord · Your first chord"
        window.minSize = NSSize(width: 580, height: 500)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        input.onFocus = { [weak self] focused in self?.focusChanged(focused) }
        input.onReadinessChanged = { [weak self] in self?.render() }
        input.onOutput = { [weak self] output in self?.received(output) }
        input.onOrdinaryEdit = { [weak self] in self?.ordinaryEdit() }
        render()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    var ownsLocalInput: Bool { input.ownsLocalInput }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if journey.stage != .see && journey.stage != .finished { window?.makeFirstResponder(input) }
        input.refreshFocus()
        render()
    }
    func windowDidBecomeKey(_ notification: Notification) { input.refreshFocus(); render() }
    func windowDidResignKey(_ notification: Notification) { input.relinquishFocus(); render() }
    func windowWillClose(_ notification: Notification) { input.relinquishFocus(); store.dismiss() }

    private func buildUI() {
        stageLabel.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.caption), weight: .semibold)
        stageLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.title), weight: .bold)
        instructions.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.body))
        answer.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.label))
        answer.textColor = .secondaryLabelColor
        feedback.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.caption))
        readiness.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.caption))
        readiness.textColor = .secondaryLabelColor
        for label in [instructions, answer, feedback, readiness] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        keyboard.layout = data.layout
        keyboard.showsFunctionRow = false
        keyboard.emphasizesCurrentChord = true
        // The first lesson always names printed keys in its text, independent of expert preferences.
        keyboard.meanings = nil
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.compactAspect).isActive = true
        keyboardHost = NSView()
        keyboardHost.addSubview(keyboard)
        let keyboardWidth = keyboard.widthAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.keyboardWidth))
        keyboardWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            keyboard.centerXAnchor.constraint(equalTo: keyboardHost.centerXAnchor),
            keyboard.topAnchor.constraint(equalTo: keyboardHost.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: keyboardHost.bottomAnchor),
            keyboard.widthAnchor.constraint(lessThanOrEqualTo: keyboardHost.widthAnchor),
            keyboard.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(DesignSystem.Metrics.keyboardWidth)),
            keyboardWidth,
        ])
        inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .noBorder
        input.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.practice))
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = .width
        input.textContainer?.widthTracksTextView = true
        inputScroll.heightAnchor.constraint(equalToConstant: 60).isActive = true
        nextDemo = PracticeActionButton("Replay") { [weak self] in self?.demonstration = 0; self?.render() }
        start = PracticeActionButton("") { [weak self] in self?.performPrimaryAction() }
        start.bezelColor = PracticeUI.accentColor
        hint = PracticeActionButton("Show keys") { [weak self] in
            guard let self else { return }
            self.hintForCurrent = true
            self.journey.revealHint()
            self.render()
            self.window?.makeFirstResponder(self.input)
            self.input.refreshFocus()
        }
        hint.toolTip = "Recall with revealed keys is recorded as assisted."
        restart = PracticeActionButton("Restart") { [weak self] in self?.restartTask() }
        use = PracticeActionButton("Try in TextEdit…") { [weak self] in
            self?.input.relinquishFocus()
            self?.onUseInEditor?()
        }
        course = PracticeActionButton("Skip introduction") { [weak self] in
            self?.store.dismiss(); self?.close(); self?.onContinueCourse?()
        }
        testOut = PracticeActionButton("Test from memory…") { [weak self] in
            self?.store.dismiss(); self?.close(); self?.onTestOut?()
        }
        use.toolTip = "Typing in other apps requires Accessibility."
        for button in [nextDemo!, hint!, restart!, course!, testOut!, use!] {
            button.isBordered = false
            button.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.caption))
        }
        let actions = PracticeUI.row([start!, nextDemo!, hint!, restart!, PracticeUI.spacer()])
        let footer = PracticeUI.row([course!, testOut!, use!, PracticeUI.spacer()])
        inputSurface = PracticeUI.surface(inputScroll!, padding: 0)
        let column = PracticeUI.column([stageLabel, titleLabel, instructions,
                                       inputSurface!, readiness, feedback,
                                       actions, keyboardHost!, answer, footer])
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window!.contentView!.addSubview(scroll)
        let preferredWidth = column.widthAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.exerciseWidth))
        preferredWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -CGFloat(DesignSystem.Metrics.pagePadding * 2)),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(DesignSystem.Metrics.exerciseWidth)),
            preferredWidth,
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: CGFloat(DesignSystem.Metrics.pagePadding)),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -CGFloat(DesignSystem.Metrics.pagePadding)),
        ])
    }

    private var available: Bool { recipes.count == FirstChordJourney.words.count && undoKeys != nil }
    private func physical(_ keys: KeySet) -> String {
        keys.indices.map { KeyboardDiagramView.name(for: data.layout.keys[$0].code) }.joined(separator: " + ")
    }
    private func keyCodes(_ keys: KeySet) -> Set<KeyCode> { Set(keys.indices.map { data.layout.keys[$0].code }) }
    private func recipeText(_ recipe: FirstChordRecipe) -> String {
        let parts = recipe.parts.map { part -> String in
            let printed = part.keys.compactMap { data.layout.indexByName[$0] }.map {
                KeyboardDiagramView.name(for: data.layout.keys[$0].code)
            }.joined(separator: " + ")
            return "\(printed) → \(part.text)"
        }
        return parts.joined(separator: "   ·   ") + (recipe.shift ? "   ·   Hold Shift" : "")
    }

    private func render() {
        let stage = journey.stage
        let presentation = KeyChordPresentation.firstChord(stage: stage, wordIndex: journey.wordIndex,
                                                           recovery: journey.recovery, hintRevealed: hintForCurrent,
                                                           demonstrationIndex: demonstration)
        let phase = KeyChordPresentation.firstChordDemonstration(step: demonstration)
        let number = (KeyChordPresentation.stageOrder.firstIndex(of: presentation.stageID) ?? 3) + 1
        stageLabel.stringValue = "\(number) · \(presentation.label)"
        stageLabel.isHidden = stage == .finished
        titleLabel.stringValue = presentation.title
        instructions.stringValue = presentation.instruction
        input.placeholder = presentation.placeholder
        nextDemo.isHidden = stage != .see || demonstration != KeyChordPresentation.firstChordDemonstrationCount - 1
        start.title = presentation.primaryAction
        start.isHidden = stage != .see && stage != .finished
        start.isEnabled = available || stage == .finished
        hint.isHidden = stage != .recall || hintForCurrent
        restart.isHidden = stage == .see || stage == .finished
        use.isHidden = stage != .finished
        course.isHidden = stage == .finished
        course.title = available ? "Skip introduction" : KeyChordPresentation.firstChord(stage: .finished).primaryAction
        testOut.isHidden = stage == .finished
        inputSurface.isHidden = stage == .finished || !available
        input.isEditable = stage != .see && !inputSurface.isHidden
        input.isSelectable = input.isEditable
        if stage == .see { input.showDemonstration(phase.output ?? "") }
        input.setAccessibilityLabel(stage == .see ? "Demonstration output" : "Local chord practice input")
        answer.stringValue = ""
        keyboardHost.isHidden = stage == .finished || !presentation.hintsVisible
        keyboard.target = []
        keyboard.held = []
        if stage == .recover && journey.recovery == .undoMistake, let undoKeys {
            answer.stringValue = "Undo: \(physical(undoKeys))"
            keyboard.target = keyCodes(undoKeys)
        } else if presentation.hintsVisible, let target = journey.target, let recipe = recipes[target] {
            answer.stringValue = recipeText(recipe)
            keyboard.target = keyCodes(recipe.keys)
            if stage == .see {
                if phase.held == "all" { keyboard.held = keyCodes(recipe.keys) }
                if phase.held == "last" { keyboard.held = Set(recipe.keys.indices.suffix(1).map { data.layout.keys[$0].code }) }
            }
        }
        answer.isHidden = answer.stringValue.isEmpty
        keyboard.setAccessibilityLabel(stage == .see ? "Example keyboard demonstration" : "Printed chord keys")
        keyboard.setAccessibilityValue(stage == .see ? instructions.stringValue : answer.stringValue)
        if stage != .see { keyboard.held = keyCodes(input.practice.heldKeys) }
        readiness.isHidden = stage == .see || stage == .finished || !available
            || (input.practice.chordEnabled && input.practice.heldKeys.isEmpty)
        if !input.practice.ownsInput {
            readiness.stringValue = "Click the practice field to continue."
        } else if !input.practice.chordEnabled {
            readiness.stringValue = "Ordinary typing · right Option resumes chords"
        } else if !input.practice.heldKeys.isEmpty {
            readiness.stringValue = "Held: \(physical(input.practice.heldKeys)) · release every key"
        } else {
            readiness.stringValue = "Local chords are on · right Option switches to ordinary typing"
        }
        feedback.stringValue = latestFeedback
        feedback.isHidden = latestFeedback.isEmpty
        if !available {
            instructions.stringValue = "This mapping cannot make all the example chords. Continue lessons for your current layout."
            nextDemo.isEnabled = false
        }
    }

    private func performPrimaryAction() {
        if journey.stage == .finished {
            store.dismiss(); close(); onContinueCourse?()
        } else if demonstration < KeyChordPresentation.firstChordDemonstrationCount - 1 {
            advanceDemo()
        } else {
            startTrying()
        }
    }

    private func advanceDemo() {
        demonstration = min(demonstration + 1, KeyChordPresentation.firstChordDemonstrationCount - 1)
        render()
    }
    private func focusChanged(_ focused: Bool) {
        onLocalFocus?(focused)
        if !focused && journey.stage == .recover && journey.recovery == .undoMistake {
            // The local engine deliberately forgets Undo when focus leaves its field. Restart
            // this controlled exercise rather than presenting an impossible Undo instruction.
            journey.restartRecovery()
            input.clearForTask()
            latestFeedback = "Focus changed. Chord hat again to restart Undo."
            render()
        }
    }
    private func startTrying() {
        guard available, demonstration == KeyChordPresentation.firstChordDemonstrationCount - 1 else { return }
        journey.startTrying()
        store.save(stage: journey.stage)
        input.clearForTask()
        latestFeedback = ""
        render()
        window?.makeFirstResponder(input)
        input.refreshFocus()
        render()
    }
    private func restartTask() {
        if journey.stage == .recover { journey.restartRecovery() }
        input.clearForTask()
        input.practice.setChordEnabled(true)
        latestFeedback = "Restarted."
        render()
        window?.makeFirstResponder(input)
        input.refreshFocus()
        render()
    }
    private func ordinaryEdit() {
        latestFeedback = "Complete the word with a chord."
        if journey.stage == .recover && journey.recovery == .undoMistake {
            latestFeedback = "Ordinary editing cleared chord Undo. Restart this task."
        }
        render()
    }
    private func received(_ output: LocalChordOutput) {
        if let attempt = output.attempt {
            let previousStage = journey.stage
            let previousRecovery = journey.recovery
            if journey.observe(attempt, resultingText: input.string) {
                latestFeedback = ""
                store.save(stage: journey.stage)
                hintForCurrent = false
                // Preserve the engine's undo record and actual mistaken text for the Undo task.
                if !(previousStage == .recover && previousRecovery == .makeMistake) { input.clearForTask() }
                if journey.stage == .finished { input.relinquishFocus() }
            } else if attempt.signal == .undoEmpty {
                latestFeedback = "Nothing to undo. Restart this task."
            } else if journey.stage == .recall && !hintForCurrent {
                latestFeedback = "Correct the word, or show the keys."
            } else {
                var message = "Recorded: \(physical(attempt.keys)). "
                if let target = journey.target, let expected = recipes[target]?.keys {
                    let difference = attempt.capturedDifference(from: expected)
                    if !difference.notCaptured.isEmpty { message += "Missing: \(physical(difference.notCaptured)). " }
                    if !difference.extraCaptured.isEmpty { message += "Extra: \(physical(difference.extraCaptured)). " }
                }
                message += "Correct the text or restart."
                latestFeedback = message
            }
        }
        render()
    }
}
