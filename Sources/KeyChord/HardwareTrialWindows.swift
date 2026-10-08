// Local physical checks. The focus callback suspends global routing; no system events are synthesized.
import AppKit
import KeyChordCore

final class AggregateHardwareReportStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func saveHardware(_ text: String) throws { try save(text, name: "quick-chord-check.txt") }
    func saveErgonomics(_ text: String) throws { try save(text, name: "ergonomic-trial.txt") }
    private func save(_ text: String, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

private final class HardwareTrialDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum HardwareTrialUI {
    static func window(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 420)
        return window
    }
    static func label(size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    static func build(window: NSWindow?, views: [NSView]) {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = 14; stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = HardwareTrialDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); scroll.documentView = document; content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        for label in views.compactMap({ $0 as? NSTextField }) {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
    }
    static func timestamp() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    static func printed(_ names: [String], layout: Layout, shift: Bool = false) -> String {
        (shift ? ["Shift"] : []).joined(separator: "") + (shift ? " + " : "") + names.map { name in
            guard let index = layout.indexByName[name] else { return name }
            let legend = KeyboardDiagramView.name(for: layout.keys[index].code)
            return legend == name ? name : "\(legend) (\(name))"
        }.joined(separator: " + ")
    }
}

final class HardwareCheckWindowController: NSWindowController, NSWindowDelegate {
    private let data: EngineData
    private let limits: KeyboardLimits?
    private let identity: HardwareIdentity
    private let confidence: HardwareConfidence
    private let onFocus: (Bool) -> Void
    private let onSave: (String) throws -> Void
    private var session: QuickChordCheckSession
    private var requestedWords: [String]
    private var monitor: Any?
    private var running = true
    private let provenance = HardwareTrialUI.label(size: 13)
    private let instruction = HardwareTrialUI.label(size: 25, weight: .semibold)
    private let evidence = HardwareTrialUI.label(size: 15)
    private let status = HardwareTrialUI.label(size: 13)
    private let choice = NSPopUpButton(frame: .zero, pullsDown: false)

    init(data: EngineData, limits: KeyboardLimits?, identity: HardwareIdentity, requested: [String]? = nil,
         confidence: HardwareConfidence? = nil, onFocus: @escaping (Bool) -> Void,
         onSave: @escaping (String) throws -> Void) {
        self.data = data; self.limits = limits; self.identity = identity
        self.confidence = confidence ?? .resolve(identity: identity, wiringText: nil, scanText: nil, layout: data.layout)
        self.onFocus = onFocus; self.onSave = onSave; requestedWords = requested ?? ["sat", "hat", "tan"]
        session = QuickChordCheckSession(layout: data.layout, identity: identity,
            targets: QuickChordTarget.planned(words: requestedWords, data: data, limits: limits))
        super.init(window: HardwareTrialUI.window(title: "Short keyboard check"))
        window?.delegate = self
        let intro = HardwareTrialUI.label()
        intro.stringValue = "Hold every printed key shown, then release all keys. This short check records missing or extra key evidence. If an attempt is incomplete, retry: one attempt cannot diagnose a keyboard matrix."
        provenance.stringValue = self.confidence.title + "\n" + self.confidence.detail + "\nKeyboard: \(identity.keyboard) · Profile: \(identity.profile)"
        choice.addItems(withTitles: ["First words: sat, hat, tan", "Capital alternatives: A, H, J, K"])
        if requested != nil { choice.addItem(withTitle: "Requested practice chords"); choice.selectItem(at: 2) }
        choice.target = self; choice.action = #selector(newCheck)
        let buttons = NSStackView(views: [button("New / Reset", #selector(newCheck)), button("Retry last", #selector(retry)),
                                          button("Skip", #selector(skip)), button("Cancel", #selector(cancel))])
        let reports = NSStackView(views: [button("Save results", #selector(save)), button("Copy report", #selector(copyReport))])
        let focus = button("Focus chord input", #selector(focusInput))
        focus.toolTip = "Resume physical chord input after using Tab to navigate controls."
        HardwareTrialUI.build(window: window, views: [provenance, intro, choice, focus, instruction, evidence, status, buttons, reports])
        refresh(); window?.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func present() {
        NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, self.running else { return event }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.session.interrupt(); self.refresh(); return event
                }
                if !event.modifierFlags.intersection([.command, .control, .option, .capsLock]).isEmpty {
                    self.session.interrupt(); self.refresh(); return event
                }
                if event.type == .flagsChanged {
                    self.session.shiftChanged(event.modifierFlags.contains(.shift)); self.refresh(); return event
                }
                if self.window?.firstResponder is NSControl { return event }
                if event.keyCode == 48 { self.session.interrupt(); return event } // Tab navigates controls.
                if event.keyCode == 53 { self.cancel(); return nil }
                if event.type == .keyDown {
                    if !event.isARepeat { self.session.keyDown(event.keyCode, shift: event.modifierFlags.contains(.shift)) }
                } else if let result = self.session.keyUp(event.keyCode, timestamp: Int64(Date().timeIntervalSince1970 * 1000)) {
                    self.evidence.stringValue = result.allRegistered ? "Observed: all target keys registered together."
                        : "Observed: missing \(result.missing.isEmpty ? "none" : result.missing.joined(separator: ", ")); extra \(result.extra.isEmpty ? "none" : result.extra.joined(separator: ", ")). Retry before drawing a hardware conclusion."
                }
                self.refresh(); return nil
            }
        }
    }
    private func refresh() {
        if !running { instruction.stringValue = "Check cancelled. Choose New / Reset to begin again."; return }
        if let target = session.current {
            instruction.stringValue = "\(session.index + 1) of \(session.targets.count) · \(target.label)\n" + HardwareTrialUI.printed(target.keys, layout: data.layout, shift: target.shift)
            status.stringValue = session.down.isEmpty ? "Ready · hold the keys, then release all."
                : "Holding: " + session.down.sorted().map { code in data.layout.indexByCode[code].map { data.layout.keys[$0].name } ?? "Key\(code)" }.joined(separator: " + ")
        } else {
            instruction.stringValue = "Short check finished."
            status.stringValue = "\(session.results.count) observed attempts; \(session.results.filter(\.allRegistered).count) registered all target keys. Other chords remain unchecked."
        }
    }
    @objc private func newCheck() {
        let words = choice.indexOfSelectedItem == 1 ? ["A", "H", "J", "K"]
            : choice.indexOfSelectedItem == 2 ? requestedWords : ["sat", "hat", "tan"]
        session = QuickChordCheckSession(layout: data.layout, identity: identity,
                                         targets: QuickChordTarget.planned(words: words, data: data, limits: limits))
        running = true; evidence.stringValue = "No observations in this check yet."; focusInput(); refresh()
    }
    @objc private func focusInput() { window?.makeFirstResponder(nil); session.interrupt() }
    @objc private func retry() { running = true; session.retryLast(); focusInput(); refresh() }
    @objc private func skip() { session.skip(); refresh() }
    @objc private func cancel() { running = false; session.interrupt(); refresh() }
    private func report() -> String { "# Model source: \(confidence.title)\n" + session.report() }
    @objc private func save() {
        do { try onSave(report()); status.stringValue = "Aggregate results saved locally." }
        catch { status.stringValue = "Could not save results: \(error.localizedDescription)" }
    }
    @objc private func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report(), forType: .string)
        status.stringValue = "Aggregate report copied."
    }
    func windowDidBecomeKey(_ notification: Notification) { onFocus(true) }
    func windowDidResignKey(_ notification: Notification) { session.interrupt(); onFocus(false); refresh() }
    func windowWillClose(_ notification: Notification) {
        session.interrupt(); onFocus(false); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
}

final class ErgonomicTrialWindowController: NSWindowController, NSWindowDelegate {
    private let data: EngineData
    private let limits: KeyboardLimits?
    private let identity: HardwareIdentity
    private let rolloverLimit: Int
    private let onFocus: (Bool) -> Void
    private let onSave: (String) throws -> Void
    private var session: ErgonomicTrialSession?
    private var running = false
    private var monitor: Any?
    private let instruction = HardwareTrialUI.label(size: 24, weight: .semibold)
    private let detail = HardwareTrialUI.label()
    private let summary = HardwareTrialUI.label(size: 13)
    private let status = HardwareTrialUI.label(size: 13)
    private let startButton = NSButton(title: "Opt in and start local trial", target: nil, action: nil)
    private let comfort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rateButton = NSButton(title: "Record comfort and continue", target: nil, action: nil)
    init(data: EngineData, limits: KeyboardLimits?, identity: HardwareIdentity, rolloverLimit: Int = 6,
         onFocus: @escaping (Bool) -> Void, onSave: @escaping (String) throws -> Void) {
        self.data = data; self.limits = limits; self.identity = identity; self.rolloverLimit = rolloverLimit
        self.onFocus = onFocus; self.onSave = onSave
        super.init(window: HardwareTrialUI.window(title: "English comfort experiment")); window?.delegate = self
        let intro = HardwareTrialUI.label()
        intro.stringValue = "Compare your current ‘use’ and ‘you’ routes with Quote+U+S and Quote+Y+O. Proposed shortcuts exist only inside this opt-in English sandbox. C++ Quote+U+S still means ‘using’. Nothing is installed in your dictionaries.\n\nTwo repetitions in fresh text and after ‘sat’, with route order reversed on the second repetition. Local trial time includes retries; corrections and your comfort rating stay separate. This small experiment cannot establish a globally best route."
        let compatible = ErgonomicCandidate.proposals.map { candidate -> String in
            let check = ErgonomicExperiment.compatibility(candidate, data: data, limits: limits, rolloverLimit: rolloverLimit)
            return "\(candidate.word): " + (check.allowed ? check.hardwareNote : check.problems.joined(separator: " "))
        }
        let hardware = HardwareTrialUI.label(size: 13)
        hardware.stringValue = "Keyboard: \(identity.keyboard) · Profile: \(identity.profile)\n" + compatible.joined(separator: "\n")
        startButton.target = self; startButton.action = #selector(start)
        comfort.addItems(withTitles: ["Choose comfort…", "1 · uncomfortable", "2", "3 · neutral", "4", "5 · comfortable"])
        rateButton.target = self; rateButton.action = #selector(rate)
        let ratings = NSStackView(views: [comfort, rateButton])
        let actions = NSStackView(views: [NSButton(title: "Retry route", target: self, action: #selector(retry)),
                                          NSButton(title: "Cancel", target: self, action: #selector(cancel))])
        let reports = NSStackView(views: [NSButton(title: "Save results", target: self, action: #selector(save)),
                                          NSButton(title: "Copy report", target: self, action: #selector(copyReport))])
        let focus = NSButton(title: "Focus chord input", target: self, action: #selector(focusInput))
        focus.toolTip = "Resume physical chord input after using Tab to navigate controls."
        HardwareTrialUI.build(window: window, views: [intro, hardware, startButton, focus, instruction, detail, ratings, actions, summary, status, reports])
        refresh(); window?.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, self.running, let session = self.session,
                      session.current != nil, session.pendingMilliseconds == nil else { return event }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    session.interrupt(); self.refresh(); return event
                }
                if !event.modifierFlags.intersection([.command, .option, .control, .capsLock]).isEmpty {
                    session.interrupt(); self.refresh(); return event
                }
                if event.type == .flagsChanged {
                    session.shiftChanged(event.modifierFlags.contains(.shift)); self.refresh(); return event
                }
                if self.window?.firstResponder is NSControl { return event }
                if event.keyCode == 48 { session.interrupt(); return event }
                if event.keyCode == 53 { self.cancel(); return nil }
                if event.type == .keyDown {
                    session.keyDown(event.keyCode, timestamp: HardwareTrialUI.timestamp(),
                                    shift: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat)
                } else { session.keyUp(event.keyCode, timestamp: HardwareTrialUI.timestamp()) }
                self.refresh(); return nil
            }
        }
    }
    @objc private func start() {
        guard let local = ErgonomicExperiment.isolatedData(data: data, optedIn: true, limits: limits,
                                                          rolloverLimit: rolloverLimit) else {
            status.stringValue = "No compatible candidate in this profile; the trial cannot start."; return
        }
        let trials = ErgonomicExperiment.trials(data: data, limits: limits, optedIn: true, rolloverLimit: rolloverLimit)
        session = ErgonomicTrialSession(data: local, trials: trials); running = true
        status.stringValue = "Local English experiment started."; window?.makeFirstResponder(nil)
        comfort.selectItem(at: 0); refresh()
    }
    private func refresh() {
        startButton.title = session == nil ? "Opt in and start local trial" : "New / Reset local trial"
        comfort.isEnabled = running && session?.pendingMilliseconds != nil; rateButton.isEnabled = comfort.isEnabled
        guard let session else {
            instruction.stringValue = "No physical measurements yet."
            detail.stringValue = "Start when you want to compare these two routes on your keyboard."
            summary.stringValue = "Model compatibility does not establish speed or comfort."; return
        }
        if !running {
            instruction.stringValue = "Local trial cancelled."
            detail.stringValue = "Completed measurements remain below. Choose New / Reset to begin another trial."
        } else if let trial = session.current {
            instruction.stringValue = "\(session.index + 1) of \(session.trials.count) · \(trial.word) · \(trial.route.rawValue) route"
            if let elapsed = session.pendingMilliseconds {
                detail.stringValue = "Completed locally in \(String(format: "%.2f", Double(elapsed) / 1000)) s, including \(session.corrections) correction(s). Rate comfort from 1 to 5, then continue."
            } else {
                let route = trial.steps.compactMap { step -> String? in
                    guard case let .chord(keys, shift) = step.action else { return nil }
                    return HardwareTrialUI.printed(keys, layout: data.layout, shift: shift)
                }.joined(separator: " → release all → ")
                let currentKeys: String
                if let step = session.currentStep, case let .chord(keys, shift) = step.action {
                    currentKeys = HardwareTrialUI.printed(keys, layout: data.layout, shift: shift)
                } else { currentKeys = "" }
                detail.stringValue = "Context: \(trial.context == .fresh ? "start of text" : "after ‘sat’") · repetition \(trial.repetition)\nCurrent step \(session.stepIndex + 1) of \(trial.steps.count): \(currentKeys)\nHold those keys, then release all. Timer starts on your first press. Corrections: \(session.corrections).\nComplete route: \(route)"
            }
        } else { instruction.stringValue = "Local trial finished."; detail.stringValue = "Compare your results below; order and practice can affect these measurements." }
        summary.stringValue = ErgonomicCandidate.proposals.flatMap { candidate in
            ErgonomicRoute.allCases.map { route in
                let summary = ErgonomicSummary(word: candidate.word, route: route, measurements: session.measurements)
                let time = summary.meanMilliseconds.map { String(format: "%.2f s", $0 / 1000) } ?? "unmeasured"
                let comfort = summary.meanComfort.map { String(format: "%.1f / 5", $0) } ?? "unrated"
                return "\(candidate.word) · \(route.rawValue): \(summary.attempts) trials · mean \(time) · \(summary.corrections) corrections · comfort \(comfort)"
            }
        }.joined(separator: "\n") + "\nYour local results; no preferred route is automatically inferred."
    }
    @objc private func rate() {
        if session?.rateComfort(comfort.indexOfSelectedItem) == true {
            comfort.selectItem(at: 0); window?.makeFirstResponder(nil); refresh()
        }
        else { status.stringValue = "Choose a comfort rating from 1 to 5." }
    }
    @objc private func focusInput() { window?.makeFirstResponder(nil); session?.interrupt(); refresh() }
    @objc private func retry() { running = true; session?.retry(); comfort.selectItem(at: 0); window?.makeFirstResponder(nil); refresh() }
    @objc private func cancel() { session?.interrupt(); running = false; status.stringValue = "Trial cancelled; completed measurements can still be saved."; refresh() }
    private func report() -> String { ErgonomicExperiment.report(identity: identity, measurements: session?.measurements ?? []) }
    @objc private func save() {
        do { try onSave(report()); status.stringValue = "Aggregate local results saved." }
        catch { status.stringValue = "Could not save results: \(error.localizedDescription)" }
    }
    @objc private func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report(), forType: .string)
        status.stringValue = "Aggregate local report copied."
    }
    func windowDidBecomeKey(_ notification: Notification) { onFocus(true) }
    func windowDidResignKey(_ notification: Notification) { session?.interrupt(); onFocus(false); refresh() }
    func windowWillClose(_ notification: Notification) {
        session?.interrupt(); onFocus(false); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
}
