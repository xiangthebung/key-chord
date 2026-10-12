import AppKit
import KeyChordCore

/// A focused responder records one local chord. It never installs a keyboard monitor or emits text.
final class ChordRecorderView: NSView {
    var onChange: (([KeyCode]) -> Void)?
    var onRecordingChanged: (() -> Void)?
    private(set) var codes: [KeyCode] = []
    private(set) var isRecording = false
    private var held = Set<KeyCode>()
    private var captured = Set<KeyCode>()
    private var beforeRecording: [KeyCode] = []
    var heldCodes: Set<KeyCode> { held }
    override var acceptsFirstResponder: Bool { true }

    func setCodes(_ codes: [KeyCode]) {
        stopRecording()
        self.codes = codes
        needsDisplay = true
    }
    func beginRecording() {
        beforeRecording = codes
        held = []; captured = []
        isRecording = true
        window?.makeFirstResponder(self)
        onRecordingChanged?()
        needsDisplay = true
    }
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        held = []; captured = []
        codes = beforeRecording
        onRecordingChanged?()
        needsDisplay = true
    }
    func receive(_ event: RawKeyEvent) {
        guard isRecording else { return }
        switch event {
        case .down(let code): held.insert(code); captured.insert(code)
        case .up(let code):
            guard held.remove(code) != nil else { return }
            if held.isEmpty {
                codes = captured.sorted()
                isRecording = false
                onChange?(codes)
            }
        }
        onRecordingChanged?()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func keyDown(with event: NSEvent) {
        if isRecording {
            if event.keyCode == 53 { stopRecording(); return }
            if event.keyCode == 48 { stopRecording(); window?.selectNextKeyView(nil); return }
            guard !event.isARepeat else { return }
            if !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
                stopRecording()
                return
            }
            receive(.down(event.keyCode))
        } else if event.keyCode == 36 || event.keyCode == 49 { beginRecording() }
        else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { if isRecording { receive(.up(event.keyCode)) } }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Record chord keys" }
    override func accessibilityValue() -> Any? {
        isRecording ? "Hold the keys together, then release. Escape cancels."
            : codes.isEmpty ? "No keys chosen" : codes.map(KeyboardDiagramView.physicalName).joined(separator: " + ")
    }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill(); path.fill()
        (isRecording ? PracticeUI.accentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1; path.stroke()
        let keys = isRecording ? captured.sorted() : codes
        let text = keys.isEmpty ? (isRecording ? "Press keys together, then release" : "Click to record keys")
            : keys.map(KeyboardDiagramView.physicalName).joined(separator: " + ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: keys.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        label.draw(in: NSRect(x: 12, y: (bounds.height - label.size().height) / 2,
                             width: bounds.width - 24, height: label.size().height))
    }
}

final class CustomChordsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                         NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    var onLocalFocus: ((Bool) -> Void)?
    private var base: EngineData
    private var chords: [CustomChord]
    private var rolloverLimit: Int
    private var usable: (KeySet) -> Bool
    private let onSave: ([CustomChord]) throws -> Void
    private let loadError: String?
    private var rows: [CustomChord] = []
    private var draft = CustomChord(id: UUID().uuidString, keyCodes: [], text: "")
    private var initialDraft: CustomChord!
    private var loadingForm = false
    private var statusOverride: String?
    private var lastRemoved: CustomChord?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let formTitle = PracticeUI.label("New chord", size: 20, weight: .semibold)
    private let scope = NSPopUpButton()
    private let spacing = NSPopUpButton()
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled when saved", target: nil, action: nil)
    let recorder = ChordRecorderView()
    private let keyboard = KeyboardDiagramView()
    private let text = NSTextView()
    private let suggestionButton = NSButton(title: "Find unused chord", target: nil, action: nil)
    private let suggestionChoices = NSStackView()
    private let suggestionNote = NSTextField(wrappingLabelWithString: "")
    private var suggestedKeys: [KeySet] = []
    private var seenSuggestions = Set<KeySet>()
    private let previewTitle = PracticeUI.label("Before → After", size: 14, weight: .semibold)
    private let previewText = NSTextField(wrappingLabelWithString: "")
    private let previewNote = NSTextField(wrappingLabelWithString: "")
    private let testInput: LocalChordInputView
    private let testMode = NSPopUpButton()
    private let tryButton = NSButton(title: "Try chord", target: nil, action: nil)
    private let clearTestButton = NSButton(title: "Clear", target: nil, action: nil)
    private let testStatus = NSTextField(wrappingLabelWithString: "")
    private var lastTestDraft: CustomChord?
    private var lastTestMode: SubMode?
    private let formScroll = NSScrollView()
    private var testSection: NSStackView!
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save chord", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove chord", target: nil, action: nil)
    private let undoRemoveButton = NSButton(title: "Undo remove", target: nil, action: nil)

    init(base: EngineData, chords: [CustomChord], rolloverLimit: Int = 6,
         usable: @escaping (KeySet) -> Bool = { _ in true }, loadError: String? = nil,
         testFocus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true },
         onSave: @escaping ([CustomChord]) throws -> Void) {
        self.base = base; self.chords = chords; self.rolloverLimit = rolloverLimit
        self.usable = usable; self.onSave = onSave; self.loadError = loadError
        testInput = LocalChordInputView(data: base, focus: testFocus, globalSuspended: globalSuspended)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KeyChord · Custom Chords"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 620)
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadDraft(chords.first)
        refreshRows()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isSaved: Bool { chords.contains { $0.id == draft.id } }
    private var hasChanges: Bool { draft != initialDraft }
    private var issue: CustomChordIssue? {
        CustomChords.issue(for: draft, among: chords.filter { $0.id != draft.id }, base: base,
                           rolloverLimit: rolloverLimit, usable: usable)
    }
    private var canSave: Bool {
        loadError == nil && hasChanges && !recorder.isRecording && (issue == nil || (isSaved && !draft.isEnabled))
    }
    private var draftData: EngineData {
        CustomChords.applying(chords.filter { $0.id != draft.id } + [draft], to: base,
                              rolloverLimit: rolloverLimit, usable: usable)
    }

    private func button(_ button: NSButton, _ action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = PracticeUI.label("Custom Chords", size: 28, weight: .bold)
        title.textColor = .labelColor
        let intro = NSTextField(wrappingLabelWithString: "Give words, phrases, or symbols a key combination of your own.")
        intro.textColor = .secondaryLabelColor
        let header = PracticeUI.column([title, intro], spacing: 6)
        search.placeholderString = "Find text or keys"
        search.delegate = self; search.setAccessibilityLabel("Search custom chords")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chord"))
        table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self
        table.rowHeight = 76; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .sourceList
        table.setAccessibilityLabel("Your custom chords")
        let list = NSScrollView()
        list.documentView = table; list.hasVerticalScroller = true; list.autohidesScrollers = true
        list.drawsBackground = false
        let add = NSButton(title: "Add chord", target: self, action: #selector(addChord))
        add.bezelStyle = .rounded; add.keyEquivalent = "n"; add.keyEquivalentModifierMask = [.command]
        button(undoRemoveButton, #selector(undoRemove)); undoRemoveButton.isHidden = true
        emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize: 12)
        let library = PracticeUI.column([PracticeUI.label("Your chords", size: 14, weight: .semibold), search,
                                        list, emptyLabel, add, undoRemoveButton], spacing: 12)
        library.widthAnchor.constraint(equalToConstant: 232).isActive = true
        list.setContentHuggingPriority(.init(1), for: .vertical)
        scope.addItems(withTitles: CustomChordScope.allCases.map(\.title))
        scope.target = self; scope.action = #selector(optionsChanged)
        scope.setAccessibilityLabel("Chord language")
        enabledButton.target = self; enabledButton.action = #selector(optionsChanged)
        enabledButton.toolTip = "Turn this off and save to restore the original mapping while keeping your chord."
        spacing.addItems(withTitles: ["Words & phrases", "No added spaces"])
        spacing.target = self; spacing.action = #selector(optionsChanged)
        spacing.setAccessibilityLabel("Chord text spacing")
        spacing.toolTip = "Words & phrases uses normal word spacing and capitalization. No added spaces attaches the text on both sides. Caps Lock still applies."
        recorder.heightAnchor.constraint(equalToConstant: 52).isActive = true
        recorder.toolTip = "Press the keys together and release them. Escape cancels recording."
        recorder.onChange = { [weak self] codes in
            guard let self else { return }
            self.draft.keyCodes = codes; self.statusOverride = nil; self.renderFeedback()
        }
        recorder.onRecordingChanged = { [weak self] in self?.renderFeedback() }
        button(suggestionButton, #selector(findUnusedChord))
        suggestionChoices.orientation = .vertical; suggestionChoices.alignment = .leading
        suggestionChoices.spacing = 6; suggestionChoices.isHidden = true
        suggestionNote.font = .systemFont(ofSize: 12); suggestionNote.textColor = .secondaryLabelColor
        suggestionNote.isHidden = true
        keyboard.layout = base.layout; keyboard.showsFunctionRow = false
        keyboard.heightAnchor.constraint(equalToConstant: 170).isActive = true
        text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: 16)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.delegate = self; text.setAccessibilityLabel("Text this chord types")
        let textScroll = NSScrollView()
        textScroll.documentView = text; textScroll.hasVerticalScroller = true; textScroll.autohidesScrollers = true
        textScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        previewTitle.textColor = .labelColor
        previewText.font = .systemFont(ofSize: 14, weight: .medium)
        previewText.setAccessibilityLabel("Chord output before and after saving")
        previewNote.font = .systemFont(ofSize: 12); previewNote.textColor = .secondaryLabelColor
        let preview = PracticeUI.surface(PracticeUI.column([previewTitle, previewText, previewNote], spacing: 8), padding: 12, accented: true)
        testMode.addItems(withTitles: ["English", "C++"])
        testMode.target = self; testMode.action = #selector(testLanguageChanged)
        testMode.setAccessibilityLabel("Test chord language")
        button(tryButton, #selector(tryChord)); button(clearTestButton, #selector(clearTest))
        testInput.font = .systemFont(ofSize: 18)
        testInput.textContainerInset = NSSize(width: 10, height: 10)
        testInput.placeholder = "Try your unsaved chord here"
        testInput.setAccessibilityLabel("Try the draft chord without saving")
        testInput.isVerticallyResizable = true; testInput.isHorizontallyResizable = false
        testInput.autoresizingMask = .width
        testInput.onOutput = { [weak self] output in self?.renderTestStatus(output) }
        testInput.onReadinessChanged = { [weak self] in self?.renderTestStatus() }
        let testScroll = NSScrollView()
        testScroll.documentView = testInput; testScroll.hasVerticalScroller = true; testScroll.autohidesScrollers = true
        testScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        testStatus.font = .systemFont(ofSize: 12); testStatus.textColor = .secondaryLabelColor
        feedback.font = .systemFont(ofSize: 12)
        feedback.setContentCompressionResistancePriority(.required, for: .vertical)
        feedback.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        button(saveButton, #selector(saveChord)); saveButton.bezelColor = PracticeUI.accentColor
        saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = [.command]
        button(cancelButton, #selector(cancelEdit))
        button(removeButton, #selector(removeChord))
        removeButton.toolTip = "Remove your customization and restore the original meaning of these keys."
        let actions = PracticeUI.row([saveButton, tryButton, cancelButton, PracticeUI.spacer(), removeButton])
        testSection = PracticeUI.column([
            PracticeUI.row([PracticeUI.label("3. Try before saving", size: 14, weight: .semibold), PracticeUI.spacer(), testMode, clearTestButton]),
            keyboard, PracticeUI.surface(testScroll, padding: 2), testStatus], spacing: 12)
        formTitle.textColor = .labelColor
        let form = PracticeUI.column([formTitle,
            PracticeUI.row([PracticeUI.label("Use in"), scope, PracticeUI.spacer(), enabledButton]),
            PracticeUI.label("1. Choose your keys", size: 14, weight: .semibold), recorder,
            PracticeUI.row([suggestionButton, PracticeUI.spacer()]), suggestionNote, suggestionChoices,
            PracticeUI.label("2. Text to type", size: 14, weight: .semibold), PracticeUI.surface(textScroll, padding: 2),
            PracticeUI.row([PracticeUI.label("Spacing"), spacing, PracticeUI.spacer()]), preview, testSection], spacing: 8)
        formScroll.hasVerticalScroller = true; formScroll.autohidesScrollers = true; formScroll.drawsBackground = false
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form); formScroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            form.topAnchor.constraint(equalTo: document.topAnchor),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        formScroll.setContentHuggingPriority(.init(1), for: .vertical)
        let editor = PracticeUI.column([formScroll, feedback, actions], spacing: 12)
        let body = PracticeUI.row([library, divider, editor], spacing: 24)
        body.alignment = .top
        library.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        divider.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        editor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        editor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -281).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false; body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header); content.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            body.leadingAnchor.constraint(equalTo: header.leadingAnchor), body.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    func update(base: EngineData, rolloverLimit: Int, usable: @escaping (KeySet) -> Bool) {
        self.base = base; self.rolloverLimit = rolloverLimit; self.usable = usable
        lastTestDraft = nil; resetSuggestions()
        keyboard.layout = base.layout; renderFeedback(); table.reloadData()
    }
    private func loadDraft(_ chord: CustomChord?) {
        loadingForm = true
        draft = chord ?? CustomChord(id: UUID().uuidString, keyCodes: [], text: "")
        initialDraft = draft; statusOverride = nil
        recorder.setCodes(draft.keyCodes)
        text.string = draft.text; text.undoManager?.removeAllActions()
        scope.selectItem(at: CustomChordScope.allCases.firstIndex(of: draft.scope)!)
        spacing.selectItem(at: draft.spacing == .words ? 0 : 1)
        enabledButton.state = draft.isEnabled ? .on : .off
        lastTestDraft = nil; resetSuggestions()
        loadingForm = false
        renderFeedback()
    }
    private func refreshRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = chords.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
                || $0.keyCodes.map(KeyboardDiagramView.physicalName).joined(separator: " + ").localizedCaseInsensitiveContains(query)
                || $0.scope.title.localizedCaseInsensitiveContains(query)
        }.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
        loadingForm = true
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == draft.id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        loadingForm = false
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = chords.isEmpty ? "No custom chords yet. Add a word or phrase you type often."
            : "No matching chords. Try different text or keys."
    }
    private func renderFeedback() {
        guard !loadingForm else { return }
        formTitle.stringValue = isSaved ? "Edit chord" : "New chord"
        saveButton.isEnabled = canSave
        cancelButton.isEnabled = hasChanges || recorder.isRecording
        removeButton.isHidden = !isSaved; removeButton.isEnabled = loadError == nil
        suggestionButton.isEnabled = !recorder.isRecording
        keyboard.target = recorder.isRecording ? [] : Set(draft.keyCodes)
        keyboard.held = recorder.heldCodes
        let after = draftData
        renderImpact(after: after)
        syncTestInput(data: after)
        feedback.textColor = .secondaryLabelColor
        if let loadError { feedback.stringValue = loadError; feedback.textColor = .systemRed; return }
        if let statusOverride { feedback.stringValue = statusOverride; return }
        if recorder.isRecording { feedback.stringValue = "Hold your keys together, then release every key. Press Escape to cancel."; return }
        if let issue {
            feedback.stringValue = issue.message
            if issue != .missingKeys && issue != .missingText { feedback.textColor = .systemRed }
            return
        }
        feedback.stringValue = hasChanges
            ? (draft.spacing == .exact && draft.isEnabled ? "No added spaces; Caps Lock still applies. Save to apply." : "Changes apply when you save.")
            : (draft.isEnabled ? "Saved chord. Edit it to make changes." : "Saved off. Re-enable and save to use this chord again.")
    }

    private func shortText(_ value: String) -> String {
        let shown = String(value.prefix(56)).replacingOccurrences(of: "\r\n", with: " ↩ ")
            .replacingOccurrences(of: "\n", with: " ↩ ").replacingOccurrences(of: "\r", with: " ↩ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
        return "“" + shown + (value.count > 56 ? "…" : "") + "”"
    }
    private func meaning(_ outcome: ChordReading.Outcome) -> String {
        switch outcome {
        case .text(let value): return shortText(value)
        case .command(let action): return "Action: " + action
        case .nothing: return "No output"
        }
    }
    private func keyNames(_ keys: KeySet) -> String {
        keys.indices.map { base.layout.keys[$0].code }.sorted().map(KeyboardDiagramView.physicalName).joined(separator: " + ")
    }
    private func renderImpact(after: EngineData) {
        let saved = chords.first { $0.id == draft.id }
        let oldKeys = saved?.keys(in: base.layout)
        let newKeys = draft.keys(in: base.layout)
        var affected: [KeySet] = []
        for keys in [oldKeys, newKeys].compactMap({ $0 }) where !keys.isEmpty && !affected.contains(keys) { affected.append(keys) }
        let before = CustomChords.applying(chords, to: base, rolloverLimit: rolloverLimit, usable: usable)
        let protected = newKeys.map { keys in
            draft.scope.modes.contains { mode in
                if case .command = ChordReading(keys, data: base, mode: mode).outcome { return true }
                return false
            }
        } ?? false
        var lines: [String] = []
        for keys in affected {
            for mode in SubMode.allCases where (keys == oldKeys && saved?.scope.modes.contains(mode) == true)
                || (keys == newKeys && draft.scope.modes.contains(mode)) {
                let current = meaning(ChordReading(keys, data: before, mode: mode).outcome)
                let next: String
                if keys == newKeys && draft.isEnabled && protected {
                    next = "Choose different keys"
                } else if keys == newKeys && draft.isEnabled && issue != nil {
                    next = draft.text.contains(where: { !$0.isWhitespace }) ? "Fix this chord before saving" : "Enter text"
                } else {
                    next = meaning(ChordReading(keys, data: after, mode: mode).outcome)
                }
                lines.append("\(mode == .english ? "English" : "C++") · \(keyNames(keys))\n\(current) → \(next)")
            }
        }
        let originals = newKeys.map { keys in
            draft.scope.modes.map { mode in
                "\(mode == .english ? "English" : "C++"): " + meaning(ChordReading(keys, data: base, mode: mode).outcome)
            }
        } ?? []
        let replaces = newKeys.map { keys in
            draft.scope.modes.contains { mode in
                if case .text = ChordReading(keys, data: base, mode: mode).outcome { return true }
                return false
            }
        } ?? false
        previewTitle.stringValue = !draft.isEnabled ? (hasChanges ? "When disabled" : "Customization is off")
            : protected ? "Built-in action is protected" : replaces ? "Replaces an existing chord" : "Before → After"
        previewText.stringValue = lines.isEmpty ? "Record keys to see what they currently type." : lines.joined(separator: "\n\n")
        previewText.setAccessibilityValue(previewText.stringValue)
        let spacingHelp = draft.spacing == .words ? "Uses normal word spacing and capitalization."
            : "Attaches on both sides without added spaces. Caps Lock still applies."
        if !draft.isEnabled {
            previewNote.stringValue = hasChanges ? "Save to turn this customization off. Its keys and text stay in your library."
                : "The original mapping is active. Your keys and text stay in the library."
        } else if protected {
            previewNote.stringValue = "Built-in actions cannot be replaced. Record other keys or find an unused chord."
        } else if replaces {
            previewNote.stringValue = "Disable or remove to restore " + originals.joined(separator: "; ") + "."
        } else {
            previewNote.stringValue = spacingHelp
        }
        saveButton.title = !draft.isEnabled ? "Save disabled chord" : replaces ? "Replace chord" : "Save chord"
    }

    private func resetSuggestions() {
        suggestedKeys = []; seenSuggestions = []
        for view in suggestionChoices.arrangedSubviews { suggestionChoices.removeArrangedSubview(view); view.removeFromSuperview() }
        suggestionChoices.isHidden = true; suggestionNote.isHidden = true
        suggestionButton.title = "Find unused chord"
    }
    @objc private func findUnusedChord() {
        let current = draft.keys(in: base.layout).map { Set([$0]) } ?? []
        suggestedKeys = CustomChords.suggestions(scope: draft.scope, among: chords,
            base: base, rolloverLimit: rolloverLimit, usable: usable, geometry: KeyboardDiagramView.geometry,
            excluding: seenSuggestions.union(current))
        if suggestedKeys.isEmpty && !seenSuggestions.isEmpty {
            seenSuggestions = []
            suggestedKeys = CustomChords.suggestions(scope: draft.scope, among: chords,
                base: base, rolloverLimit: rolloverLimit, usable: usable, geometry: KeyboardDiagramView.geometry, excluding: current)
        }
        for view in suggestionChoices.arrangedSubviews { suggestionChoices.removeArrangedSubview(view); view.removeFromSuperview() }
        seenSuggestions.formUnion(suggestedKeys)
        for (index, keys) in suggestedKeys.enumerated() {
            let choice = NSButton(title: "Use " + keyNames(keys), target: self, action: #selector(chooseSuggestion(_:)))
            choice.bezelStyle = .rounded; choice.tag = index
            choice.setAccessibilityLabel("Use unused chord " + keyNames(keys))
            suggestionChoices.addArrangedSubview(choice)
        }
        suggestionChoices.isHidden = suggestedKeys.isEmpty; suggestionNote.isHidden = false
        suggestionNote.stringValue = suggestedKeys.isEmpty
            ? "No unused combinations of up to three keys are available here. Record keys to see what they would replace."
            : "These keys have no current meaning in \(draft.scope == .both ? "English or C++" : draft.scope.title). Choose one, then try it below."
        suggestionButton.title = suggestedKeys.isEmpty ? "Find unused chord" : "More suggestions"
    }
    @objc private func chooseSuggestion(_ sender: NSButton) {
        guard suggestedKeys.indices.contains(sender.tag) else { return }
        draft.keyCodes = suggestedKeys[sender.tag].indices.map { base.layout.keys[$0].code }.sorted()
        recorder.setCodes(draft.keyCodes)
        suggestionChoices.isHidden = true; suggestionNote.isHidden = true
        suggestionButton.title = "Find unused chord"; statusOverride = nil
        renderFeedback()
    }

    private func syncTestInput(data: EngineData) {
        testMode.isHidden = draft.scope != .both
        let selected = SubMode.allCases[max(0, testMode.indexOfSelectedItem)]
        if !draft.scope.modes.contains(selected) { testMode.selectItem(at: SubMode.allCases.firstIndex(of: draft.scope.modes[0])!) }
        let mode = SubMode.allCases[testMode.indexOfSelectedItem]
        let canTest = issue == nil && !recorder.isRecording
        testInput.isEditable = canTest; testInput.allowsLocalFocus = canTest
        tryButton.isEnabled = canTest; clearTestButton.isEnabled = canTest
        if lastTestDraft != draft || lastTestMode != mode {
            lastTestDraft = draft; lastTestMode = mode
            testInput.practice.replaceData(data)
            testInput.practice.setMode(mode)
            testInput.clearForTask()
            renderTestStatus()
        } else if !canTest { renderTestStatus() }
    }
    private func renderTestStatus(_ output: LocalChordOutput? = nil) {
        testStatus.textColor = .secondaryLabelColor
        if !recorder.isRecording {
            keyboard.held = Set(testInput.practice.heldKeys.indices.map { base.layout.keys[$0].code })
        }
        if issue != nil || recorder.isRecording {
            testStatus.stringValue = "Complete a valid chord to try it here."
        } else if output?.attempt?.signal == .untranslatable {
            testStatus.stringValue = "Those keys have no output in this language. Check the keys you pressed."
            testStatus.textColor = .systemRed
        } else if testInput.practice.ownsInput && !testInput.practice.chordEnabled {
            testStatus.stringValue = "Ordinary typing is on. Tap right Option to return to chords."
        } else {
            testStatus.stringValue = draft.isEnabled
                ? "Try twice to check spacing. Right Option switches to ordinary typing. Test text stays here."
                : "This draft is off: the test uses the original mapping. Test text stays here."
        }
    }
    @objc private func testLanguageChanged() { syncTestInput(data: draftData) }
    @objc private func tryChord() {
        guard tryButton.isEnabled else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        if let document = formScroll.documentView {
            document.layoutSubtreeIfNeeded()
            document.scrollToVisible(testSection.convert(testSection.bounds, to: document))
        }
        window?.makeFirstResponder(testInput); testInput.refreshFocus()
    }
    @objc private func clearTest() {
        testInput.clearForTask(); testInput.practice.setChordEnabled(true)
        renderTestStatus(); tryChord()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let chord = rows[row]
        let value = PracticeUI.label(ChordDisplay.visible(chord.text), size: 14, weight: .medium)
        value.textColor = .labelColor; value.lineBreakMode = .byTruncatingTail
        value.maximumNumberOfLines = 1; value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keys = chord.keyCodes.map(KeyboardDiagramView.physicalName).joined(separator: " + ")
        let detail = PracticeUI.label(keys + " · " + chord.scope.title, size: 11, weight: .regular)
        detail.lineBreakMode = .byTruncatingTail; detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let problem = CustomChords.issue(for: chord, among: chords.filter { $0.id != chord.id }, base: base,
                                         rolloverLimit: rolloverLimit, usable: usable)
        let status = PracticeUI.label(!chord.isEnabled ? "Off" : problem == nil ? "On" : "Needs repair", size: 11, weight: .semibold)
        status.textColor = !chord.isEnabled ? .secondaryLabelColor : problem == nil ? PracticeUI.accentColor : .systemRed
        let cell = PracticeUI.column([value, detail, status], spacing: 4)
        cell.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        cell.toolTip = chord.text + "\n" + keys + " · " + chord.scope.title + "\n" + status.stringValue
            + (problem.map { "\n" + $0.message } ?? "")
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard !loadingForm, rows[row].id != draft.id else { return true }
        let selected = rows[row]
        guard canLeaveDraft() else { return false }
        loadDraft(selected); refreshRows()
        return false
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loadingForm, rows.indices.contains(table.selectedRow) else { return }
        loadDraft(rows[table.selectedRow])
    }
    func controlTextDidChange(_ notification: Notification) { refreshRows() }
    func textDidChange(_ notification: Notification) {
        guard !loadingForm else { return }
        draft.text = text.string; statusOverride = nil; renderFeedback()
    }
    @objc private func optionsChanged() {
        if draft.scope != CustomChordScope.allCases[scope.indexOfSelectedItem] { resetSuggestions() }
        draft.scope = CustomChordScope.allCases[scope.indexOfSelectedItem]
        draft.spacing = spacing.indexOfSelectedItem == 0 ? .words : .exact
        draft.isEnabled = enabledButton.state == .on
        statusOverride = nil; renderFeedback()
    }
    @objc private func addChord() {
        guard canLeaveDraft() else { return }
        loadDraft(nil); refreshRows(); recorder.beginRecording()
    }
    @objc private func cancelEdit() {
        loadDraft(chords.first { $0.id == draft.id }); refreshRows()
    }
    @discardableResult
    @objc func saveChord() -> Bool {
        guard canSave else { return false }
        var next = chords.filter { $0.id != draft.id }; next.append(draft)
        do { try onSave(next) }
        catch { statusOverride = "Could not save this chord: " + error.localizedDescription; renderFeedback(); return false }
        chords = next; initialDraft = draft
        statusOverride = draft.isEnabled ? "Saved. Your chord is available in Practice and typing in other apps."
            : "Saved off. The original mapping is active; your customization is kept."
        renderFeedback(); refreshRows()
        return true
    }
    @objc private func removeChord() {
        guard isSaved, loadError == nil else { return }
        let removed = chords.first { $0.id == draft.id }!
        let next = chords.filter { $0.id != draft.id }
        do { try onSave(next) }
        catch { statusOverride = "Could not remove this chord: " + error.localizedDescription; renderFeedback(); return }
        chords = next; lastRemoved = removed; undoRemoveButton.isHidden = false
        loadDraft(nil); refreshRows()
        statusOverride = "Removed. The original meaning of those keys is restored."; renderFeedback()
    }
    @objc private func undoRemove() {
        guard let removed = lastRemoved else { return }
        if removed.isEnabled, let problem = CustomChords.issue(for: removed, among: chords, base: base, rolloverLimit: rolloverLimit, usable: usable) {
            statusOverride = problem.message; renderFeedback(); return
        }
        do { try onSave(chords + [removed]) }
        catch { statusOverride = "Could not restore this chord: " + error.localizedDescription; renderFeedback(); return }
        chords.append(removed); lastRemoved = nil; undoRemoveButton.isHidden = true
        loadDraft(removed); refreshRows()
    }
    private func canLeaveDraft() -> Bool {
        recorder.stopRecording()
        guard hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your changes to this chord?"
        alert.informativeText = "Your changes have not been saved."
        let canKeep = loadError == nil && (issue == nil || (isSaved && !draft.isEnabled))
        if canKeep { alert.addButton(withTitle: "Save") }
        alert.addButton(withTitle: "Discard Changes"); alert.addButton(withTitle: "Keep Editing")
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if canKeep { return response == 0 ? saveChord() : response == 1 }
        return response == 0
    }
    func present() {
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeaveDraft() }
    func windowDidBecomeKey(_ notification: Notification) { onLocalFocus?(true); testInput.refreshFocus() }
    func windowDidResignKey(_ notification: Notification) { recorder.stopRecording(); testInput.relinquishFocus(); onLocalFocus?(false) }
    func windowWillClose(_ notification: Notification) { recorder.stopRecording(); testInput.relinquishFocus(); onLocalFocus?(false) }
}
