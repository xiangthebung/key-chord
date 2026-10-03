// Matrix Scan window. Stage 1 maps 3-key combinations with sweeps (hold a pair, tap the outlined keys);
// stage 2 checks 4-6 key layout chords the map predicts to work. The report shows the inferred wiring grid
// and which chords are blocked. Key events are recorded only here while the window is focused, like the
// Rollover Probe.

import AppKit
import Carbon
import KeyChordCore

final class MatrixScanWindowController: NSWindowController, NSWindowDelegate {
    private var session: MatrixScanSession
    private var data: EngineData
    private let store: DataStore
    private let onFocus: (Bool) -> Void
    private var monitor: Any?
    private lazy var hardware = Self.hardwareDescription()
    private var reportWindow: TextWindowController?

    private let instructionLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let keyboard = KeyboardDiagramView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let pairField = NSTextField(string: "")
    private let backButton = NSButton(title: "◀ Back", target: nil, action: nil)
    private let forwardButton = NSButton(title: "Forward ▶", target: nil, action: nil)
    private let stageButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: "Awkward to Hold, Skip", target: nil, action: nil)

    /// The combination that failed for the user: a good first pair to hold.
    private static let startPairs = [("J", "M"), ("J", "H"), ("H", "M")]

    init(data: EngineData, store: DataStore, onFocus: @escaping (Bool) -> Void) {
        self.data = data
        self.store = store
        self.onFocus = onFocus
        var loadNote = ""
        session = Self.makeSession(data: data, saved: store.readMatrixScan(), note: &loadNote)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Matrix Scan"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 520)
        super.init(window: w)
        w.delegate = self
        buildUI()
        w.center()
        refresh()
        if !loadNote.isEmpty { messageLabel.stringValue = loadNote }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeSession(data: EngineData, saved: String?, note: inout String) -> MatrixScanSession {
        let layout = data.layout
        var sweeps: [MatrixSweep] = []
        var combos: [MatrixCombo] = []
        if let saved {
            do {
                if let s = try MatrixScanReport.parse(saved, layout: layout) {
                    (sweeps, combos) = s
                    if !sweeps.isEmpty || !combos.isEmpty {
                        note = "Resumed \(sweeps.count) saved sweeps and \(combos.count) combinations."
                    }
                } else {
                    note = "The saved scan was made with a different layout; starting over."
                }
            } catch {
                note = "Could not read the saved scan (\(error)); starting over."
            }
        }
        let preferred = startPairs.compactMap { a, b -> KeyPair? in
            guard let i = layout.indexByName[a], let j = layout.indexByName[b] else { return nil }
            return KeyPair(layout.keys[i].code, layout.keys[j].code)
        }
        let session = MatrixScanSession(layout: layout, sweeps: sweeps, combos: combos,
                                        candidates: MatrixScanSession.candidateChords(data),
                                        preferred: preferred, tapOrder: tapOrder(layout), canHold: canHold)
        if !combos.isEmpty { session.enterCombos() }
        if session.droppedOnLoad > 0 {
            note = "Dropped \(session.droppedOnLoad) saved sweeps in which no key registered (those weren't real results)."
                + (session.sweeps.isEmpty ? " Starting fresh." : " Resumed \(session.sweeps.count) sweeps.")
        }
        return session
    }

    /// Keyboard order: row by row, left to right, so the next key is always next to the last one.
    static func tapOrder(_ layout: Layout) -> [KeyCode] {
        layout.keys.map(\.code).sorted {
            let a = KeyboardDiagramView.rect(for: $0) ?? .zero, b = KeyboardDiagramView.rect(for: $1) ?? .zero
            return (a.minY, a.minX) < (b.minY, b.minX)
        }
    }

    /// One hand can hold two keys whose edges are at most three key widths apart.
    static func canHold(_ a: KeyCode, _ b: KeyCode) -> Bool {
        guard let r = KeyboardDiagramView.rect(for: a), let s = KeyboardDiagramView.rect(for: b) else { return false }
        let dx = max(0, max(r.minX, s.minX) - min(r.maxX, s.maxX))
        let dy = max(0, max(r.minY, s.minY) - min(r.maxY, s.maxY))
        return (dx * dx + dy * dy).squareRoot() <= 3.0
    }

    func update(data: EngineData) {
        let keysChanged = data.layout.keys.map(\.code) != self.data.layout.keys.map(\.code)
        self.data = data
        guard keysChanged else { return }
        var note = ""
        session = Self.makeSession(data: data, saved: store.readMatrixScan(), note: &note)
        keyboard.layout = data.layout
        refresh()
        messageLabel.stringValue = "The layout changed. " + note
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        instructionLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.font = .systemFont(ofSize: 13)
        keyboard.layout = data.layout
        keyboard.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString:
            "Every test is a 3-key combination: two keys held with one hand, plus the highlighted key tapped with "
            + "the other. Tap the highlighted keys once each, in order; the highlight moves by itself. Green: all "
            + "three registered. Red: blocked, the keyboard dropped it. If a key stays dark, just tap the next one. "
            + "Later rounds only ask for keys whose result isn't known yet, so they get short. Then a few 4-6 key "
            + "chords to confirm the map. About 10 minutes in all; progress is saved as you go.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        pairField.placeholderString = "e.g. J M"
        pairField.setAccessibilityLabel("Pair of keys to hold")
        pairField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        pairField.target = self
        pairField.action = #selector(useCustomPair)

        func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
        for (b, a) in [(backButton, #selector(back)), (forwardButton, #selector(forward)),
                       (stageButton, #selector(switchStage)), (skipButton, #selector(skipPair))] {
            b.target = self
            b.action = a
        }
        backButton.toolTip = "Undo the last step: restart the sweep in progress, or take back the last recorded result."
        forwardButton.toolTip = "Put back a result taken back with Back, or skip to the next combination."
        let navRow = NSStackView(views: [backButton, forwardButton, skipButton, stageButton])
        let sweepRow = NSStackView(views: [NSTextField(labelWithString: "Test with a specific held pair:"), pairField,
                                           button("Use", #selector(useCustomPair))])
        let reportRow = NSStackView(views: [button("Copy Report", #selector(copyReport)),
                                            button("Show Report", #selector(showReport)),
                                            button("Start Over…", #selector(startOver))])

        let stack = NSStackView(views: [intro, instructionLabel, detailLabel, keyboard, statusLabel, messageLabel,
                                        navRow, sweepRow, reportRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            keyboard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            keyboard.heightAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: KeyboardDiagramView.aspect),
        ])
        for l in [intro, instructionLabel, detailLabel, messageLabel] {
            l.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
    }

    /// The printed key label, with the Layout name when it differs (for example "È (Quote)").
    private func label(_ code: KeyCode) -> String {
        let name = session.name(code)
        let printed = KeyboardDiagramView.name(for: code)
        return printed == name || printed.hasPrefix("key ") ? name : "\(printed) (\(name))"
    }

    private func refresh() {
        let s = session
        backButton.isEnabled = s.canGoBack
        forwardButton.isEnabled = s.canGoForward
        skipButton.isHidden = s.stage != .sweeps
        stageButton.title = s.stage == .sweeps ? "Go to 4-6 Key Check" : "Back to 3-Key Sweeps"
        if s.stage == .combos { refreshCombos() } else { refreshSweeps() }
        let m = s.model
        let known = m.totalPairs - m.unknownPairs
        let pct = m.totalPairs == 0 ? 100 : known * 100 / m.totalPairs
        var status = "3-key combinations tested: \(s.tripleTests)   Map: \(pct)% known"
        if !m.inconsistent.isEmpty { status += " (\(m.inconsistent.count) rounds left out)" }
        status += "   4-6 key chords: \(s.combos.count) tested"
        if s.stage == .combos { status += ", \(s.remainingCombos) to go" }
        statusLabel.stringValue = status
        messageLabel.stringValue = s.message
    }

    private func refreshCombos() {
        let s = session
        if let t = s.currentCombo {
            let names = t.sorted { (s.model.index[$0] ?? 0) < (s.model.index[$1] ?? 0) }.map(label)
            instructionLabel.stringValue = "Press together: " + names.joined(separator: " + ")
            detailLabel.stringValue = "Hold all \(t.count) outlined keys at once, then release them all. "
                + "A key that doesn't light up is what we're looking for."
            keyboard.current = nil; keyboard.passed = []; keyboard.failed = []
            keyboard.target = t
            keyboard.held = s.down
            keyboard.setAccessibilityLabel("Press together: " + names.joined(separator: ", "))
        } else {
            instructionLabel.stringValue = "Scan finished."
            detailLabel.stringValue = "Copy the report and paste it into the chat."
            keyboard.current = nil; keyboard.passed = []; keyboard.failed = []
            keyboard.target = []
            keyboard.held = s.down
            keyboard.setAccessibilityLabel("Keyboard")
        }
    }

    private func refreshSweeps() {
        let s = session
        keyboard.current = nil
        keyboard.passed = []
        keyboard.failed = []
        guard let p = s.pair else {
            instructionLabel.stringValue = "3-key map finished."
            detailLabel.stringValue = "Go to the 4-6 key check, or hold a specific pair below."
            keyboard.target = []
            keyboard.held = s.down
            keyboard.setAccessibilityLabel("Keyboard")
            return
        }
        let pairText = "\(label(p.a)) + \(label(p.b))"
        let held = s.down.contains(p.a) && s.down.contains(p.b)
        let others = s.down.subtracting([p.a, p.b])
        let left = s.unresolved.count
        if s.phase == .hold || !held {
            if !others.isEmpty && !held {
                instructionLabel.stringValue = "Let go of " + others.sorted().map(label).joined(separator: ", ") + "."
            } else {
                instructionLabel.stringValue = "Hold \(pairText) with one hand."
            }
            detailLabel.stringValue = s.rechecking != nil
                ? "Re-check: tap the highlighted keys again. Keys that stay dark this time really are blocked."
                : s.status.isEmpty
                    ? "Then tap the highlighted key with your other hand. \(s.order.count) keys this round."
                    : "Carry on where you stopped: \(left) keys to go."
        } else if let c = s.current {
            instructionLabel.stringValue = "\(pairText) + \(label(c))"
            let next = s.unresolved.dropFirst().prefix(3).map(label)
            var d = "\(left) left this round." + (next.isEmpty ? "" : " Next: " + next.joined(separator: ", ") + ".")
                + " If it stays dark, it's blocked: tap the next one."
            if !s.endsOnKnownKey, s.canFinishWithKey, let f = s.finishKey {
                d += " If the last ones stay dark, tap \(label(f)) again to finish."
            }
            detailLabel.stringValue = d
        } else {
            instructionLabel.stringValue = "Round done. Let go of \(pairText)."
            detailLabel.stringValue = s.missedKeys.isEmpty ? "Nothing was blocked with this pair."
                : "\(s.missedKeys.count) of \(s.order.count) combinations were blocked."
        }
        keyboard.target = Set(s.unresolved).union([p.a, p.b])
        keyboard.current = held ? s.current : nil
        keyboard.passed = s.registeredKeys
        keyboard.failed = s.missedKeys
        keyboard.held = s.down
        keyboard.setAccessibilityLabel("Hold \(pairText). " + (s.current.map { "Tap \(label($0)) next." } ?? ""))
    }

    // MARK: Keys

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        installMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow else { return e }
            // Typing a pair into the text field, or a Command shortcut.
            if w.firstResponder is NSTextView || e.modifierFlags.contains(.command) { return e }
            let before = (self.session.sweeps.count, self.session.combos.count)
            if e.type == .keyDown {
                if !e.isARepeat { self.session.keyDown(e.keyCode) }
            } else {
                self.session.keyUp(e.keyCode)
            }
            if self.session.sweeps.count != before.0 || self.session.combos.count != before.1 { self.autosave() }
            self.refresh()
            return nil
        }
    }

    private func reportText() -> String {
        let wiring = store.readWiring().flatMap { try? KeyboardWiring.parse($0, layout: data.layout) }
        return MatrixScanReport.serialize(model: session.model, combos: session.combos, layout: data.layout,
                                          hardware: hardware, data: data, wiring: wiring)
    }

    private func autosave() {
        do {
            try store.writeMatrixScan(reportText())
        } catch {
            messageLabel.stringValue = "Could not save the scan: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    @objc private func skipPair() { session.skipPair(); refresh() }

    @objc private func back() {
        session.back()
        autosave()
        refresh()
    }

    @objc private func forward() {
        session.forward()
        autosave()
        refresh()
    }

    @objc private func switchStage() {
        if session.stage == .sweeps { session.enterCombos() } else { session.returnToSweeps() }
        refresh()
    }

    @objc private func useCustomPair() {
        let parts = pairField.stringValue.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "," }).map(String.init)
        let layout = data.layout
        func code(_ s: String) -> KeyCode? {
            if let i = layout.indexByName[s] ?? layout.keys.firstIndex(where: { $0.name.lowercased() == s.lowercased() }) {
                return layout.keys[i].code
            }
            // Printed labels on this keyboard, for example "È".
            return layout.keys.first { KeyboardDiagramView.name(for: $0.code).lowercased() == s.lowercased() }?.code
        }
        guard parts.count == 2, let a = code(parts[0]), let b = code(parts[1]), a != b else {
            messageLabel.stringValue = "Type two different key names from the layout, for example \"J M\" or \"Quote Semicolon\"."
            return
        }
        session.choose(a, b)
        window?.makeFirstResponder(nil)
        refresh()
    }

    @objc private func copyReport() {
        let text = reportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        autosave()
        messageLabel.stringValue = "Report copied (\(session.sweeps.count) sweeps, \(session.combos.count) combinations). Also saved to \(store.matrixScanURL.path)."
    }

    @objc private func showReport() {
        if reportWindow == nil { reportWindow = TextWindowController(title: "Matrix Scan Report") }
        reportWindow?.show(text: reportText())
    }

    @objc private func startOver() {
        let alert = NSAlert()
        alert.messageText = "Delete all \(session.sweeps.count) sweeps and \(session.combos.count) combinations and start over?"
        alert.informativeText = "The saved scan file is overwritten. This can't be undone."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            self.session.resetAll()
            self.autosave()
            self.refresh()
        }
    }

    // MARK: Focus

    func windowDidBecomeKey(_ notification: Notification) { onFocus(true) }

    func windowDidResignKey(_ notification: Notification) {
        onFocus(false)
        session.interrupt()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        onFocus(false)
        session.interrupt()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Hardware

    /// For example "MacBookPro18,3 Apple M1 Pro, ISO keyboard".
    static func hardwareDescription() -> String {
        "\(Hardware.model) \(Hardware.chip), \(Hardware.keyboardType) keyboard"
    }
}
