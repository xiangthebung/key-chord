// Show Layout / problem windows (Req 4.8, 15.5) and the Rollover_Probe window (Req 5).

import AppKit
import KeyChordCore

// MARK: - Read-only text window

final class TextWindowController: NSWindowController {
    private let textView = NSTextView()

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        textView.frame = scroll.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        w.contentView?.addSubview(scroll)
        super.init(window: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String) {
        textView.string = text
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Rollover probe

final class ProbeWindowController: NSWindowController, NSWindowDelegate {
    private var session: ProbeSession
    private var data: EngineData
    private var rolloverLimit: Int
    private let onFocus: (Bool) -> Void
    private let onSave: (ProbeReport) -> String
    private var monitor: Any?

    private let heldLabel = NSTextField(labelWithString: "")
    private let modsLabel = NSTextField(labelWithString: "")
    private let maxLabel = NSTextField(labelWithString: "")
    private let sourcePopup = NSPopUpButton()
    private let countField = NSTextField(string: "20")
    private let targetLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let ghostButton = NSButton(title: "Record as Ghosting", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let backButton = NSButton(title: "◀ Back", target: nil, action: nil)
    private let forwardButton = NSButton(title: "Forward ▶", target: nil, action: nil)

    private static let modifierNames: [KeyCode: String] = [
        56: "Left Shift", 60: "Right Shift", 59: "Left Control", 62: "Right Control", 58: "Left Option",
        61: "Right Option", 55: "Left Command", 54: "Right Command", 57: "Caps Lock", 63: "Fn",
    ]

    init(data: EngineData, rolloverLimit: Int, onFocus: @escaping (Bool) -> Void, onSave: @escaping (ProbeReport) -> String) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        self.session = ProbeSession(layout: data.layout)
        self.onFocus = onFocus
        self.onSave = onSave
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Rollover Probe"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        buildUI()
        w.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(data: EngineData, rolloverLimit: Int) {
        self.data = data
        self.rolloverLimit = rolloverLimit
        if !session.guidedActive && session.results.isEmpty {
            session = ProbeSession(layout: data.layout)
            refresh()
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        for l in [heldLabel, modsLabel, maxLabel, targetLabel, resultLabel, summaryLabel] {
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 3
            l.preferredMaxLayoutWidth = 580
        }
        heldLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        targetLabel.font = .monospacedSystemFont(ofSize: 20, weight: .bold)

        sourcePopup.addItems(withTitles: ["Layout tables (clusters + fingerspelling)", "All dictionary chords",
                                          "Random syllables using the rollover limit"])
        countField.frame.size.width = 60
        countField.setAccessibilityLabel("Number of random combinations")
        let start = NSButton(title: "Start Guided Test", target: self, action: #selector(startGuided))
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopGuided))
        let save = NSButton(title: "Save Report", target: self, action: #selector(saveReport))
        let reset = NSButton(title: "Reset Maximum", target: self, action: #selector(resetSession))
        retryButton.target = self; retryButton.action = #selector(retry)
        ghostButton.target = self; ghostButton.action = #selector(ghost)
        skipButton.target = self; skipButton.action = #selector(skip)
        backButton.target = self; backButton.action = #selector(back)
        forwardButton.target = self; forwardButton.action = #selector(forward)
        backButton.toolTip = "Go back to the previous combination and try it again. The new attempt replaces the old result."
        forwardButton.toolTip = "Go to the next combination, keeping its result."

        let intro = NSTextField(wrappingLabelWithString:
            "While this window is focused, keys are only recorded here: no chords, no Option taps, and nothing reaches other apps. Command shortcuts still work.")
        let countLabel = NSTextField(labelWithString: "Random count:")
        let sourceRow = NSStackView(views: [sourcePopup, countLabel, countField])
        let buttonRow = NSStackView(views: [start, stop, reset, save])
        let decisionRow = NSStackView(views: [backButton, forwardButton, retryButton, ghostButton, skipButton])

        let stack = NSStackView(views: [intro, heldLabel, modsLabel, maxLabel, sourceRow, buttonRow, targetLabel,
                                        resultLabel, decisionRow, summaryLabel])
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
        ])
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow else { return e }
            switch e.type {
            case .keyDown:
                if e.modifierFlags.contains(.command) { return e }
                if !e.isARepeat { self.session.keyDown(e.keyCode) }
                self.refresh()
                return nil
            case .keyUp:
                if let r = self.session.keyUp(e.keyCode, time: Self.nowEpochMs()) { self.show(result: r) }
                self.refresh()
                return nil
            case .flagsChanged:
                // NSEvent flags use the same bit values as CGEventFlags, including device bits.
                let raw = UInt64(e.modifierFlags.rawValue)
                if let (_, down) = EventConversion.modifierChange(code: e.keyCode, flags: raw) {
                    if down { self.session.modifierDown(e.keyCode) } else { self.session.modifierUp(e.keyCode) }
                }
                self.refresh()
                return e
            default:
                return e
            }
        }
    }

    static func nowEpochMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func show(result r: ProbeResult) {
        let t = r.target.joined(separator: "+")
        switch r.outcome {
        case .pass: resultLabel.stringValue = "✓ Passed: \(t)"
        case .fail: resultLabel.stringValue = "✗ Failed: \(t), missing \(r.detail.joined(separator: ", "))"
        case .extra: resultLabel.stringValue = "! Extra keys for \(t): \(r.detail.joined(separator: ", ")). Retry, record as ghosting, or skip."
        case .ghost: resultLabel.stringValue = "✗ Ghosting: \(t)"
        }
    }

    private func refresh() {
        let held = session.names(session.heldKeys)
        heldLabel.stringValue = "Held keys (\(held.count)): " + (held.isEmpty ? "none" : held.joined(separator: " + "))
        let mods = session.heldModifiers.map { Self.modifierNames[$0] ?? "Key\($0)" }
        modsLabel.stringValue = "Held modifiers: " + (mods.isEmpty ? "none" : mods.joined(separator: ", "))
        maxLabel.stringValue = "Most non-modifier keys held at once: \(session.maxHeld)"
        if let t = session.currentTarget {
            targetLabel.stringValue = "Press together: " + session.targetNames(t).joined(separator: " + ")
                + "   (\(session.targetIndex + 1) of \(session.targets.count))"
            if let r = session.currentResult, !session.awaitingExtraDecision {
                resultLabel.stringValue = "Earlier result: \(r.outcome.rawValue). Press it again to replace it, or go Forward to keep it."
            }
        } else {
            targetLabel.stringValue = session.targets.isEmpty ? "No guided test running." : "Guided test finished."
        }
        let counts = Dictionary(grouping: session.results, by: \.outcome).mapValues(\.count)
        summaryLabel.stringValue = "Results: \(counts[.pass] ?? 0) passed, \(counts[.fail] ?? 0) failed, "
            + "\(counts[.extra] ?? 0) extra, \(counts[.ghost] ?? 0) ghosting"
        let deciding = session.awaitingExtraDecision
        retryButton.isEnabled = deciding
        ghostButton.isEnabled = deciding
        skipButton.isEnabled = session.guidedActive
        backButton.isEnabled = session.canGoBack
        forwardButton.isEnabled = session.canGoForward
    }

    @objc private func startGuided() {
        let source: ProbeSource = [.layoutTables, .dictionaries, .randomSyllables][max(0, sourcePopup.indexOfSelectedItem)]
        var rng = SystemRandomNumberGenerator()
        let count = max(1, Int(countField.stringValue) ?? 20)
        let targets = ProbeSession.targets(source: source, data: data, rolloverLimit: rolloverLimit, count: count, using: &rng)
        session.startGuided(targets)
        resultLabel.stringValue = targets.isEmpty ? "No combinations for this source." : ""
        refresh()
    }

    @objc private func stopGuided() { session.stopGuided(); refresh() }
    @objc private func retry() { session.retry(); resultLabel.stringValue = "Try again."; refresh() }
    @objc private func ghost() { session.recordGhost(); resultLabel.stringValue = "Recorded as ghosting."; refresh() }
    @objc private func skip() { session.skip(); resultLabel.stringValue = ""; refresh() }
    @objc private func back() { session.back(); resultLabel.stringValue = ""; refresh() }
    @objc private func forward() { session.forward(); resultLabel.stringValue = ""; refresh() }

    @objc private func resetSession() {
        session = ProbeSession(layout: data.layout)
        resultLabel.stringValue = ""
        refresh()
    }

    @objc private func saveReport() {
        resultLabel.stringValue = onSave(session.report(created: Self.nowEpochMs()))
    }

    // MARK: Focus (Req 5.3)

    func windowDidBecomeKey(_ notification: Notification) { onFocus(true) }
    func windowDidResignKey(_ notification: Notification) { onFocus(false) }
    func windowWillClose(_ notification: Notification) {
        onFocus(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
