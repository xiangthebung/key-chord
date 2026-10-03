// Wiring Check window: runs the fixed list of rounds that settle what the keyboard wiring leaves open.
// Keys are recorded only here while the window is focused, like the Matrix Scan.

import AppKit
import KeyChordCore

final class WiringCheckWindowController: NSWindowController, NSWindowDelegate {
    private var session: WiringCheckSession
    private let name: String
    private var data: EngineData
    private let store: DataStore
    private let onFocus: (Bool) -> Void
    private var monitor: Any?
    private let hardware = MatrixScanWindowController.hardwareDescription()
    private var reportWindow: TextWindowController?

    private let progressLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let keyboard = KeyboardDiagramView()
    private let backButton = NSButton(title: "◀ Back", target: nil, action: nil)
    private let forwardButton = NSButton(title: "Skip Round ▶", target: nil, action: nil)

    /// The current check; earlier checks' results are kept in their own files.
    static let plan = DefaultData.wiringCheck2MacBookPro18
    static let earlierPlans = ["1"]

    init?(data: EngineData, store: DataStore, onFocus: @escaping (Bool) -> Void) {
        guard let plan = try? WiringCheckPlan.parseNamed(Self.plan, layout: data.layout), !plan.rounds.isEmpty else { return nil }
        let rounds = plan.rounds
        name = plan.name
        self.data = data
        self.store = store
        self.onFocus = onFocus
        let saved = store.readWiringCheck(plan.name).flatMap { try? MatrixScanReport.parse($0, layout: data.layout) }?.sweeps ?? []
        session = WiringCheckSession(layout: data.layout, rounds: Self.ordered(rounds, layout: data.layout), results: saved)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Wiring Check \(plan.name)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 500)
        super.init(window: w)
        w.delegate = self
        buildUI()
        w.center()
        refresh()
        if !saved.isEmpty { messageLabel.stringValue = "Resumed: \(session.done.count) rounds already done." }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Taps in keyboard order (row by row, left to right); the round's last key, which ends it, stays last.
    private static func ordered(_ rounds: [WiringCheckRound], layout: Layout) -> [WiringCheckRound] {
        let rank = Dictionary(uniqueKeysWithValues: MatrixScanWindowController.tapOrder(layout).enumerated().map { ($1, $0) })
        return rounds.map { r in
            guard let end = r.taps.last else { return r }
            var t = Array(r.taps.dropLast()).sorted { (rank[$0] ?? 999) < (rank[$1] ?? 999) }
            t.append(end)
            return WiringCheckRound(pair: r.pair, taps: t)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        instructionLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.font = .systemFont(ofSize: 13)
        keyboard.layout = data.layout
        keyboard.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString:
            "Only 3-key combinations nothing before has tested. Hold the two keys shown with one hand and tap the "
            + "highlighted key with the other; the highlight moves on by itself. If a key stays dark, it's blocked: "
            + "tap the next one. A red key you only missed turns green when you tap it again. Letting go pauses. "
            + "About \(max(1, (session.tapsLeft + 30) / 60)) min; you can stop any time and copy what's done.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        for (b, a) in [(backButton, #selector(back)), (forwardButton, #selector(forward))] {
            b.target = self
            b.action = a
        }
        backButton.toolTip = "Restart the round in progress, or redo the previous round."
        forwardButton.toolTip = "Leave this round for later; it comes back at the end."
        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport))
        let show = NSButton(title: "Show Report", target: self, action: #selector(showReport))
        let row = NSStackView(views: [backButton, forwardButton, copy, show])

        let stack = NSStackView(views: [intro, progressLabel, instructionLabel, detailLabel, keyboard, messageLabel, row])
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

    private func label(_ code: KeyCode) -> String {
        let name = session.name(code), printed = KeyboardDiagramView.name(for: code)
        return printed == name || printed.hasPrefix("key ") ? name : "\(printed) (\(name))"
    }

    private func refresh() {
        let s = session
        backButton.isEnabled = s.canGoBack
        forwardButton.isEnabled = s.canGoForward
        let minutes = max(1, Int((Double(s.tapsLeft) * 0.8 + Double(s.rounds.count - s.done.count) * 4) / 60 + 0.5))
        progressLabel.stringValue = "Round \(min(s.index + 1, s.rounds.count)) of \(s.rounds.count)   ·   "
            + "\(s.done.count) done   ·   \(s.tapsLeft) taps left" + (s.phase == .finished ? "" : ", about \(minutes) min")
        keyboard.current = nil
        keyboard.passed = s.registeredKeys
        keyboard.failed = s.missedKeys
        keyboard.held = s.down
        guard let r = s.round else {
            instructionLabel.stringValue = "Check finished."
            detailLabel.stringValue = "Copy the report and paste it into the chat."
            keyboard.target = []
            messageLabel.stringValue = s.message
            return
        }
        let pairText = "\(label(r.pair.a)) + \(label(r.pair.b))"
        let held = s.down.contains(r.pair.a) && s.down.contains(r.pair.b)
        if s.phase == .hold || !held {
            let others = s.down.subtracting([r.pair.a, r.pair.b])
            instructionLabel.stringValue = !others.isEmpty && !held
                ? "Let go of " + others.sorted().map(label).joined(separator: ", ") + "."
                : "Hold \(pairText) with one hand."
            detailLabel.stringValue = s.status.isEmpty
                ? "Then tap the highlighted key with your other hand. \(r.taps.count) keys this round."
                : "Carry on where you stopped: \(s.unresolved.count) keys to go."
        } else if let c = s.current {
            instructionLabel.stringValue = "\(pairText) + \(label(c))"
            let next = s.unresolved.dropFirst().prefix(3).map(label)
            var d = "\(s.unresolved.count) left this round." + (next.isEmpty ? "" : " Next: " + next.joined(separator: ", ") + ".")
                + " If it stays dark, it's blocked: tap the next one."
            if s.unresolved.count <= 2, let f = s.finishKey {
                d += " If the last one stays dark, tap \(label(f)) again to finish."
            }
            detailLabel.stringValue = d
            keyboard.current = c
        } else {
            instructionLabel.stringValue = "Round done. Let go of \(pairText)."
            detailLabel.stringValue = s.missedKeys.isEmpty ? "Nothing blocked." : "\(s.missedKeys.count) blocked."
        }
        keyboard.target = Set(s.unresolved).union([r.pair.a, r.pair.b])
        keyboard.setAccessibilityLabel("Hold \(pairText). " + (s.current.map { "Tap \(label($0)) next." } ?? ""))
        messageLabel.stringValue = s.message
    }

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
            if e.modifierFlags.contains(.command) { return e }
            let before = self.session.done.count
            if e.type == .keyDown {
                if !e.isARepeat { self.session.keyDown(e.keyCode) }
            } else {
                self.session.keyUp(e.keyCode)
            }
            if self.session.done.count != before { self.save() }
            self.refresh()
            return nil
        }
    }

    private func reportText() -> String {
        let layout = data.layout
        let bundled = KeyboardDiagramView.geometry.kind == .ansi ? DefaultData.wiringMacBookPro18ANSI
            : DefaultData.wiringMacBookPro18
        let wiring = store.readWiring().flatMap { try? KeyboardWiring.parse($0, layout: layout) }
            ?? (try? KeyboardWiring.parse(bundled, layout: layout))
        let scan = store.readMatrixScan().flatMap { try? MatrixScanReport.parse($0, layout: layout) }
        let earlier = Self.earlierPlans.flatMap { n in
            store.readWiringCheck(n).flatMap { try? MatrixScanReport.parse($0, layout: layout) }?.sweeps ?? []
        }
        return session.report(hardware: hardware, wiring: wiring, scan: (scan?.sweeps ?? []) + earlier,
                              scanCombos: scan?.combos ?? [], title: "Wiring Check \(name)")
    }

    private func save() {
        do { try store.writeWiringCheck(name, reportText()) } catch {
            messageLabel.stringValue = "Could not save: \(error.localizedDescription)"
        }
    }

    @objc private func back() { session.back(); save(); refresh() }
    @objc private func forward() { session.forward(); refresh() }

    @objc private func copyReport() {
        let text = reportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        save()
        messageLabel.stringValue = "Report copied (\(session.done.count) of \(session.rounds.count) rounds)."
    }

    @objc private func showReport() {
        if reportWindow == nil { reportWindow = TextWindowController(title: "Wiring Check Report") }
        reportWindow?.show(text: reportText())
    }

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
}
