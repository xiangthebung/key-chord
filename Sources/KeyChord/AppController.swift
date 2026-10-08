// Menu-bar app (Req 17), wiring the event tap to the Event_Router and the output emitter.

import AppKit
import KeyChordCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let store = DataStore()
    private var router: EventRouter!
    private var lastValid: [DataFile: String] = [:]
    private var tap: EventTap!
    private let emitter = OutputEmitter()
    private var statusItem: NSStatusItem!
    private var flashUntil = Date.distantPast
    private var tapCreationFailed = false
    private var tapFailures = 0
    private var relaunchNotified = false

    private var layoutWindow: TextWindowController?
    private var problemsWindow: TextWindowController?
    private var probeWindow: ProbeWindowController?
    private var matrixWindow: MatrixScanWindowController?
    private var wiringCheckWindow: WiringCheckWindowController?
    private var guideWindow: TypingGuideWindowController?
    private var wordPracticeWindow: WordPracticeWindowController?
    private var firstChordWindow: FirstChordWindowController?
    private var editorPracticeWindow: EditorPracticeWindowController?
    private var hardwareCheckWindow: HardwareCheckWindowController?
    private var ergonomicTrialWindow: ErgonomicTrialWindowController?
    private var learningJourney: LearningJourneyStore!
    private var manualWindow: ManualWindowController?
    private var overlay: ReferenceOverlayController?
    private let courseProgress = CourseProgress()
    /// Set while the Typing Guide is the key window.
    private var keyListener: ((RawKeyEvent) -> Void)?
    /// Set while the reference overlay is on screen. It only follows keys while chord typing is on.
    private var overlayListener: ((RawKeyEvent) -> Void)?

    private var permissionTimer: Timer?
    private var stateTimer: Timer?
    /// Each focused local surface owns its own pause. Losing one focus cannot release another's pause.
    private enum LocalInputOwner: Hashable { case firstChords, wordSprint, probe, matrix, wiring, hardwareCheck, ergonomicTrial }
    private var localInputOwners = Set<LocalInputOwner>()

    /// The keyboard type macOS reported at launch (nil: JIS or unknown). Read once, so that typing on an
    /// external keyboard later doesn't switch the drawing or the wiring.
    private lazy var detectedKeyboard = Hardware.detectedKeyboard

    // MARK: Keyboard

    /// The keyboard chosen in the menu, else the detected one; nil when neither is US (ANSI) or ISO.
    private var keyboardKind: KeyboardGeometry.Kind? { settings.keyboard ?? detectedKeyboard }

    /// Draws the chosen keyboard everywhere and installs its wiring.
    private func applyKeyboard() {
        KeyboardDiagramView.geometry = .of(keyboardKind ?? .ansi)
        installWiring()
    }

    /// The bundled wiring of this MacBook and keyboard (again, in case the file was deleted meanwhile).
    private func installWiring() {
        store.installBundledWiring(model: Hardware.model, keyboard: keyboardKind)
    }

    // MARK: Launch

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let firstChordWindow, firstChordWindow.ownsLocalInput { firstChordWindow.present() }
            else { openTypingGuide() }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)                 // Req 17.1: no Dock icon

        // Snapshot pre-existing files before installing defaults. Updating an older installation
        // should never force a new introduction or disable its previously enabled event tap.
        let hasExistingData = DataFile.allCases.contains { FileManager.default.fileExists(atPath: store.url($0).path) }
        learningJourney = LearningJourneyStore(hasExistingDataFiles: hasExistingData)

        let installErrors = store.installMissingDefaults()    // Req 15.2
        applyKeyboard()
        let outcome = DictionaryLoader.load(sources: store.readAll(), rolloverLimit: settings.rolloverLimit,
                                            probeReport: store.readProbeReport(), wiring: store.readWiring())
        lastValid = outcome.acceptedSources
        router = EventRouter(data: outcome.data, lastSubMode: settings.lastSubMode,
                             tapTimeoutMs: UInt64(settings.tapTimeoutMs))       // Req 17.5
        _ = router.setPermissionsGranted(false)              // until the tap is running

        tap = EventTap { [unowned self] type, event in self.handleTap(type, event) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIndicator()
        if settings.overlayVisible { showOverlay() }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostAppChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollState() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollPermissions() }

        _ = startTapIfPermitted()
        // Returning users already chose global typing. A rebuilt app may have lost its
        // Accessibility grant; explain how to renew it once, instead of silently polling.
        if learningJourney.permitsGlobalTyping && !Permissions.allGranted {
            DispatchQueue.main.async { self.explainPermissions() }
        }
        switch learningJourney.launch {
        case .begin:
            DispatchQueue.main.async { self.showFirstChords(stage: .see) }
        case .resume(let stage):
            DispatchQueue.main.async { self.showFirstChords(stage: stage) }
        case .skip: break
        }
        report(problems: outcome.problems, warnings: outcome.warnings, dropped: outcome.droppedChords, extra: installErrors)
    }

    // MARK: Event tap handling (Req 2, 16)

    private func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {   // Req 2.8
            tap.reenable()
            router.tapReenabled()
            return pass
        }
        if OutputEmitter.isSynthetic(event) { return pass }                    // Req 2.7
        // The owned local field receives the original NSEvent and applies its own engine output.
        // Skip BEFORE raw listeners and routing: neither the guide nor the global emitter sees it.
        if firstChordWindow?.ownsLocalInput == true || !localInputOwners.isEmpty { return pass }
        if keyListener != nil || overlayListener != nil {
            let guide = keyListener, overlay = overlayListener
            forwardRawKey(type, event) { e in
                guide?(e)
                overlay?(e)
            }
        }

        let now = EventConversion.nowMs()
        let input: RouterInput
        switch type {
        case .keyDown, .keyUp:
            let code = KeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let flags = EventConversion.flags(event.flags)
            if type == .keyDown {
                input = .keyDown(code: code, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                 flags: flags, time: now)
            } else {
                input = .keyUp(code: code, flags: flags, time: now)
            }
        case .flagsChanged:
            let code = KeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard let (key, down) = EventConversion.modifierChange(code: code, flags: event.flags.rawValue) else { return pass }
            input = down ? .modifierDown(code: code, key: key, time: now) : .modifierUp(code: code, key: key, time: now)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .mouseDown(time: now)
        default:
            return pass
        }

        let out = router.handle(input)
        if !out.actions.isEmpty {
            do {
                if guideWindow?.receiveOutput(out.actions) != true {
                    try emitter.emit(out.actions)                               // Req 16.1, 16.4
                }
            } catch {
                let events = router.forceNormal()                               // Req 18.8
                DispatchQueue.main.async { self.handle(events: events + [.failSafe]) }
            }
        }
        if !out.events.isEmpty {
            let events = out.events
            DispatchQueue.main.async { self.handle(events: events) }
        }
        return out.decision == .suppress ? nil : pass
    }

    /// Physical key presses for the Typing Guide's keyboard, seen before the router holds chord keys back.
    /// Delivered asynchronously so the tap never waits on the UI (Req 2.9).
    private func forwardRawKey(_ type: CGEventType, _ event: CGEvent, to listener: @escaping (RawKeyEvent) -> Void) {
        let code = KeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let e: RawKeyEvent
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            e = .down(code)
        case .keyUp:
            e = .up(code)
        case .flagsChanged:
            guard let (_, down) = EventConversion.modifierChange(code: code, flags: event.flags.rawValue) else { return }
            e = down ? .down(code) : .up(code)
        default:
            return
        }
        DispatchQueue.main.async { listener(e) }
    }

    private func handle(events: [RouterEvent]) {
        for e in events {
            switch e {
            case .modeChanged:
                settings.lastSubMode = router.lastSubMode
            case .untranslatable, .undoEmpty:
                flash()                                                         // Req 17.4
            case .failSafe:
                NSSound.beep()
            }
        }
        updateIndicator()
    }

    // MARK: Periodic state (Req 3.11, 18.3 - 18.5)

    private func pollState() {
        let events = router.setSecureInput(SecureInput.isOn)
        if !events.isEmpty { handle(events: events) }
        if router.engine.chordInProgress { router.syncPhysicalKeys(physicallyHeldKeys()) }
        updatePracticeState()
        if isFlashing && Date() > flashUntil {
            isFlashing = false
            updateIndicator()
        }
    }

    private var isFlashing = false

    private func pollPermissions() {
        guard learningJourney.permitsGlobalTyping else { return }
        if tap.isRunning {
            // A revoked permission makes chord typing unavailable (Req 18.2).
            let granted = Permissions.allGranted
            if !granted { tap.stop() }       // a tap left over from a revoked grant never delivers again
            let events = router.setPermissionsGranted(granted)
            if !events.isEmpty { handle(events: events) }
            if !granted { updateIndicator() }
            return
        }
        // Keep trying: macOS often lets the tap be created a moment after the grant, without a relaunch.
        _ = startTapIfPermitted()
    }

    @discardableResult
    private func startTapIfPermitted() -> Bool {
        // A fresh profile learns in a local field first. Merely launching or polling never opts
        // the learner into interception or a system permission prompt.
        guard learningJourney.permitsGlobalTyping else { return false }
        guard Permissions.allGranted else {
            tapFailures = 0
            if router.permissionsGranted { handle(events: router.setPermissionsGranted(false)) }
            updateIndicator()
            return false
        }
        if tap.start() {
            tapFailures = 0
            tapCreationFailed = false
            handle(events: router.setPermissionsGranted(true))
            return true
        }
        if router.permissionsGranted { handle(events: router.setPermissionsGranted(false)) }
        tapFailures += 1
        tapCreationFailed = true
        // Retried every second; only ask for a relaunch if it keeps failing (Req 18.3: within 2 s).
        if tapFailures >= 2 && !relaunchNotified {                             // Req 18.3
            relaunchNotified = true
            alert("Please relaunch KeyChord",
                  "The permissions are granted, but macOS needs KeyChord to restart before it can read the keyboard.",
                  buttons: ["Quit KeyChord", "Later"]) { if $0 == 0 { NSApp.terminate(nil) } }
        }
        updateIndicator()
        return false
    }

    @objc private func frontmostAppChanged() {                                  // Req 9.7
        router.contextReset()
    }

    // MARK: Mode indicator (Req 17.2, 17.4, 18.2, 18.4)

    /// Text next to the keyboard icon in the menu bar: the sub-mode while chord typing is on.
    private func indicatorTitle() -> String {
        if !learningJourney.permitsGlobalTyping { return "Local" }
        switch router.availability {
        case .missingPermission: return "⚠︎"
        case .secureInput: return "🔒"
        case .available:
            switch router.displayedMode {
            case .normal: return ""
            case .chord(.english): return "English"
            case .chord(.cpp): return "C++"
            }
        }
    }

    /// One line on what KeyChord is doing, for the top of the menu.
    private func statusLine() -> String {
        if !learningJourney.permitsGlobalTyping {
            return "Local practice is available · enable typing in other apps when ready"
        }
        switch router.availability {
        case .missingPermission:
            return Permissions.accessibility ? "KeyChord needs to be reopened" : "KeyChord needs Accessibility access"
        case .secureInput: return "Paused while Secure Input is on"
        case .available:
            switch router.displayedMode {
            case .normal: return "Chord typing is off"
            case .chord(.english): return "Chord typing: English"
            case .chord(.cpp): return "Chord typing: C++"
            }
        }
    }

    private func updateIndicator() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            let icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyChord")
            icon?.isTemplate = true
            button.image = icon
        }
        button.attributedTitle = NSAttributedString(string: "")
        button.title = indicatorTitle()
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
        switch router.availability {
        case .missingPermission: button.toolTip = statusLine()
        case .secureInput:
            button.toolTip = "KeyChord is paused while Secure Input is on, for example in a password field."
        case .available:
            if case .chord = router.displayedMode {
                button.toolTip = "KeyChord: \(indicatorTitle()) chord typing. Tap right Option to stop."
            } else {
                button.toolTip = "KeyChord is off. Tap right Option to start chord typing."
            }
        }
        button.setAccessibilityLabel(button.toolTip)
        updateOverlay()
        updatePracticeState()
    }

    private func updatePracticeState() {
        let status = router.availability == .available && router.probeActive
            ? "Paused while a local practice or keyboard check has focus" : statusLine()
        guideWindow?.updateTypingState(availability: router.availability, effectiveMode: router.effectiveMode,
                                       status: status)
        editorPracticeWindow?.update(availability: router.availability, optedIn: learningJourney.permitsGlobalTyping,
                                     tapRunning: tap.isRunning)
    }

    // MARK: Reference overlay

    /// Tells the overlay whether chord keys are being read, and what is going on when they are not.
    private func updateOverlay() {
        guard let overlay else { return }
        var chording = false
        if case .chord = router.effectiveMode { chording = true }
        let status: String
        switch router.availability {
        case .missingPermission:
            status = learningJourney.permitsGlobalTyping ? "KeyChord needs Accessibility access to read chords."
                : "Local practice is available. Enable typing in other apps when you are ready."
        case .secureInput: status = "Paused while Secure Input is on."
        case .available:
            if case .chord = router.displayedMode {
                status = "Paused while a keyboard test window is in front."
            } else {
                status = "Chord typing is off. Tap the right ⌥ Option key to start."
            }
        }
        var sub = router.lastSubMode
        if case .chord(let s) = router.displayedMode { sub = s }
        overlay.update(subMode: sub, chording: chording, status: status)
    }

    private func showOverlay() {
        if overlay == nil {
            let o = ReferenceOverlayController(data: router.engine.data, subMode: router.lastSubMode)
            o.onClose = { [weak self] in
                self?.settings.overlayVisible = false
                self?.overlayListener = nil
            }
            overlay = o
        }
        guard let o = overlay else { return }
        settings.overlayVisible = true
        overlayListener = { [weak o] e in o?.rawKey(e) }
        updateOverlay()
        o.present()
    }

    @objc private func toggleOverlay() {
        if overlay?.isVisible == true { overlay?.close() } else { showOverlay() }
    }

    /// A keyboard test window gained or lost focus: chords pause while it has it (Req 5.3).
    private func setProbeActive(_ on: Bool, owner: LocalInputOwner) {
        if on { localInputOwners.insert(owner) } else { localInputOwners.remove(owner) }
        router.setProbeActive(!localInputOwners.isEmpty)
        if localInputOwners.isEmpty {
            // Releases inside a local surface bypassed the global router. Forget any old
            // held-key bookkeeping before it accepts the next explicit right-Option tap.
            router.syncPhysicalKeys(physicallyHeldKeys())
        }
        updateOverlay()
        updatePracticeState()
    }

    private func flash() {
        guard let button = statusItem.button else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed,
                                                    .font: NSFont.menuBarFont(ofSize: 0)]
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: "✕ " + indicatorTitle(), attributes: attrs)
        isFlashing = true
        flashUntil = Date().addingTimeInterval(0.35)
    }

    // MARK: Menu (Req 17.3)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !learningJourney.permitsGlobalTyping {
            menu.addItem(item("Enable Typing in Other Apps…", #selector(openAccessibilitySettings)))
        } else if router.availability == .missingPermission && !Permissions.accessibility {
            menu.addItem(item("Allow Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        let available = router.availability == .available
        let chord = item("Chord Typing", #selector(toggleChord))
        chord.toolTip = "Tap right Option to start or pause chord typing."
        if case .chord = router.displayedMode { chord.state = .on }
        chord.isEnabled = available
        menu.addItem(chord)
        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let en = item("English", #selector(selectEnglish))
        en.state = router.displayedMode == .chord(.english) ? .on : .off
        let cpp = item("C++", #selector(selectCpp))
        cpp.state = router.displayedMode == .chord(.cpp) ? .on : .off
        en.isEnabled = available
        cpp.isEnabled = available
        languageMenu.addItem(en)
        languageMenu.addItem(cpp)
        language.submenu = languageMenu
        menu.addItem(language)
        menu.addItem(.separator())
        menu.addItem(item("Lessons…", #selector(openCourse)))
        menu.addItem(item("Practice…", #selector(openTypingGuide)))
        menu.addItem(item("Word Sprint…", #selector(openWordSprint)))

        let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        toolsMenu.addItem(item("First Chord Introduction…", #selector(openFirstChords)))
        toolsMenu.addItem(item("Editor…", #selector(openEditorPractice)))
        let reference = NSMenuItem(title: "Reference", action: nil, keyEquivalent: "")
        let referenceMenu = NSMenu()
        referenceMenu.addItem(item("Manual…", #selector(openManual)))
        let overlayItem = item("Keyboard Overlay", #selector(toggleOverlay))
        overlayItem.state = overlay?.isVisible == true ? .on : .off
        referenceMenu.addItem(overlayItem)
        referenceMenu.addItem(item("Layout…", #selector(showLayout)))
        reference.submenu = referenceMenu
        toolsMenu.addItem(reference)
        let hardware = NSMenuItem(title: "Keyboard Tools", action: nil, keyEquivalent: "")
        let hardwareMenu = NSMenu()
        hardwareMenu.addItem(item("Check Chords…", #selector(openHardwareCheck)))
        hardwareMenu.addItem(item("Comfort and Speed Trial…", #selector(openErgonomicTrial)))
        hardwareMenu.addItem(.separator())
        hardwareMenu.addItem(item("Rollover Probe…", #selector(openProbe)))
        hardwareMenu.addItem(item("Matrix Scan…", #selector(openMatrixScan)))
        hardwareMenu.addItem(item("Wiring Check…", #selector(openWiringCheck)))
        let rollover = NSMenuItem(title: "Rollover Limit", action: nil, keyEquivalent: "")
        let rolloverMenu = NSMenu()
        for n in 2...10 {
            let i = item("\(n) keys", #selector(setRollover(_:)))
            i.tag = n
            i.state = settings.rolloverLimit == n ? .on : .off
            rolloverMenu.addItem(i)
        }
        rollover.submenu = rolloverMenu
        hardwareMenu.addItem(rollover)
        hardware.submenu = hardwareMenu
        toolsMenu.addItem(hardware)
        tools.submenu = toolsMenu
        menu.addItem(tools)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        let timeout = NSMenuItem(title: "Option Tap Timeout", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        for ms in [200, 300, 400, 500, 600, 800] {
            let i = item("\(ms) ms", #selector(setTapTimeout(_:)))
            i.tag = ms
            i.state = settings.tapTimeoutMs == ms ? .on : .off
            tm.addItem(i)
        }
        timeout.submenu = tm
        settingsMenu.addItem(timeout)
        let keyboard = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: "")
        keyboard.toolTip = "The keyboard the Typing Guide, the overlay and the manual show, and whose wiring decides "
            + "which chords it can't register."
        let km = NSMenu()
        let detected = detectedKeyboard.map { KeyboardGeometry.of($0).name } ?? "\(Hardware.keyboardType), shown as US"
        for (title, kind) in [("Automatic: \(detected)", nil), (KeyboardGeometry.ansi.name, .ansi),
                              (KeyboardGeometry.iso.name, .iso)] as [(String, KeyboardGeometry.Kind?)] {
            let i = item(title, #selector(setKeyboard(_:)))
            i.representedObject = kind?.rawValue
            i.state = settings.keyboard == kind ? .on : .off
            km.addItem(i)
        }
        keyboard.submenu = km
        settingsMenu.addItem(keyboard)

        settingsMenu.addItem(.separator())
        settingsMenu.addItem(item("Open Dictionary Folder", #selector(openFolder)))
        settingsMenu.addItem(item("Reload Dictionaries", #selector(reloadDictionaries)))
        settingsMenu.addItem(item("Permission Status…", #selector(showPermissions)))
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit KeyChord", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openAccessibilitySettings() {
        learningJourney.chooseOtherApps()
        if !startTapIfPermitted() { Permissions.openAccessibility() }
    }
    @objc private func toggleChord() { handle(events: router.toggleChordMode()) }
    @objc private func selectEnglish() { handle(events: router.selectSubMode(.english)) }
    @objc private func selectCpp() { handle(events: router.selectSubMode(.cpp)) }

    @objc private func setTapTimeout(_ sender: NSMenuItem) {
        settings.tapTimeoutMs = sender.tag
        router.tapTimeoutMs = UInt64(sender.tag)
    }

    @objc private func setRollover(_ sender: NSMenuItem) {
        settings.rolloverLimit = sender.tag
        reloadDictionaries()
    }

    @objc private func setKeyboard(_ sender: NSMenuItem) {
        let before = keyboardKind
        settings.keyboard = (sender.representedObject as? String).flatMap(KeyboardGeometry.Kind.init(rawValue:))
        guard keyboardKind != before else { return }
        applyKeyboard()
        // The new wiring changes which chords the Typing Guide may suggest and which edited chords get a warning.
        reload(announce: false)
        if manualWindow?.window?.isVisible == true { openManual() }
    }

    @objc private func showLayout() {
        if layoutWindow == nil { layoutWindow = TextWindowController(title: "KeyChord Layout") }
        layoutWindow?.show(text: LayoutReference.render(router.engine.data.layout))
    }

    /// What this keyboard can register, from the installed wiring file or a saved Matrix Scan.
    private func keyboardLimits(for layout: Layout) -> KeyboardLimits? {
        installWiring()
        return KeyboardLimits(wiringText: store.readWiring(), scanText: store.readMatrixScan(), layout: layout)
    }

    @objc private func openManual() {
        if manualWindow == nil {
            let manual = ManualWindowController()
            manual.onLesson = { [weak self] n in
                guard n >= 0 && n < Lessons.all.count else { return }
                self?.openTypingGuide()
                self?.guideWindow?.practice(Lessons.all[n])
            }
            manual.onCourse = { [weak self] in self?.openCourse() }
            manualWindow = manual
        }
        let data = router.engine.data
        let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
        manualWindow?.show(html: Manual.html(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                                             keyboard: KeyboardDiagramView.geometry))
    }

    @objc private func openTypingGuide() {
        if guideWindow == nil {
            let guide = TypingGuideWindowController(data: router.engine.data, rolloverLimit: settings.rolloverLimit,
                                                    mode: router.lastSubMode,
                                                    tapIsRunning: { [weak self] in self?.tap.isRunning ?? false })
            guide.onFocus = { [weak self, weak guide] focused in
                self?.keyListener = focused ? { [weak guide] e in guide?.rawKey(e) } : nil
            }
            guide.onResetContext = { [weak self] in self?.router.contextReset() }
            guide.onSyncContext = { [weak self] c in self?.router.engine.restore(c) }
            guide.onPracticeModeChanged = { [weak self] mode in
                guard let self else { return }
                let wasOff = self.router.selectedMode == .normal
                var events = self.router.selectSubMode(mode)
                if wasOff && self.router.selectedMode != .normal { events += self.router.toggleChordMode() }
                self.handle(events: events)
            }
            guide.onPracticeActiveChanged = { [weak self] active, mode in
                guard let self, self.router.availability == .available else { return }
                self.handle(events: active ? self.router.selectSubMode(mode) : self.router.forceNormal())
                self.updatePracticeState()
            }
            guide.onUseInEditor = { [weak self] in
                guard let self else { return }
                self.showEditorPractice(mode: self.router.lastSubMode)
            }
            guide.onEnableOtherApps = { [weak self] in self?.enableOtherAppTyping() }
            guide.onOpenReference = { [weak self] in self?.openManual() }
            guide.onOpenKeyboardTools = { [weak self] in self?.openHardwareCheck() }
            guide.onWordSprint = { [weak self] in self?.openWordSprint() }
            guide.progress = courseProgress
            installWiring()
            guide.limits = KeyboardLimits(wiringText: store.readWiring(), scanText: store.readMatrixScan(),
                                          layout: router.engine.data.layout)
            guideWindow = guide
        }
        updatePracticeState()
        guideWindow?.present()
    }

    @objc private func openWordSprint() {
        if wordPracticeWindow == nil {
            let data = router.engine.data
            let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
            let sprint = WordPracticeWindowController(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                globalSuspended: { [weak self] in self?.localInputOwners.contains(.wordSprint) == true })
            sprint.onLocalFocus = { [weak self] on in self?.setProbeActive(on, owner: .wordSprint) }
            wordPracticeWindow = sprint
        }
        wordPracticeWindow?.tick()
        wordPracticeWindow?.present()
    }

    /// The course runs in the Typing Guide, from where the learner left off.
    @objc private func openCourse() {
        openTypingGuide()
        guideWindow?.startCourse()
    }

    @objc private func openFirstChords() { showFirstChords(stage: .see) }

    private func showFirstChords(stage: FirstChordStage) {
        firstChordWindow?.close()
        let data = router.engine.data
        let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
        let first = FirstChordWindowController(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                                               store: learningJourney, stage: stage,
                                               globalSuspended: { [weak self] in
                                                   self?.localInputOwners.contains(.firstChords) == true
                                               })
        first.onLocalFocus = { [weak self] on in self?.setProbeActive(on, owner: .firstChords) }
        first.onContinueCourse = { [weak self] in self?.openCourse() }
        first.onTestOut = { [weak self] in
            self?.openTypingGuide()
            self?.guideWindow?.startCourseTestOut()
        }
        first.onUseInEditor = { [weak self] in self?.showEditorPractice(mode: .english) }
        firstChordWindow = first
        first.present()
    }

    @objc private func openEditorPractice() { showEditorPractice(mode: router.lastSubMode) }

    private func showEditorPractice(mode: SubMode) {
        editorPracticeWindow?.close()
        let data = router.engine.data
        let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
        let editor = EditorPracticeWindowController(data: data, store: learningJourney, mode: mode,
                                                    rolloverLimit: settings.rolloverLimit, usable: usable)
        editor.onEnableOtherApps = { [weak self] in
            self?.enableOtherAppTyping()
        }
        editor.onPrepareEditor = { [weak self] in
            guard let self else { return }
            // Select the exercise's mapping but enter the document in ordinary mode. The learner
            // explicitly taps right Option there to begin, so no typed instructions are intercepted.
            var events = self.router.selectSubMode(mode)
            events += self.router.forceNormal()
            self.handle(events: events)
        }
        editor.onContinueCourse = { [weak self] in self?.openCourse() }
        editorPracticeWindow = editor
        updatePracticeState()
        editor.present()
    }

    private var hardwareIdentity: HardwareIdentity {
        let keyboard = keyboardKind.map { KeyboardGeometry.of($0).name } ?? "Unknown keyboard (shown as ANSI)"
        let mapping = DataFile.allCases.map { lastValid[$0] ?? $0.defaultSource }.joined(separator: "\n")
        let fingerprint = String(DataStore.fnv1a(mapping), radix: 16)
        let profile = (keyboardKind?.rawValue ?? "automatic-unknown") + " · mapping " + fingerprint
            + " · rollover \(settings.rolloverLimit)"
        let origin = settings.keyboard == nil ? "detected" : "selected"
        return HardwareIdentity(keyboard: "Connected keyboard unconfirmed · \(origin) " + keyboard + " geometry",
                                profile: profile, model: Hardware.model)
    }

    @objc private func openHardwareCheck() {
        if hardwareCheckWindow == nil {
            let data = router.engine.data
            let identity = hardwareIdentity
            let confidence = HardwareConfidence.resolve(identity: identity, wiringText: store.readWiring(),
                                                        scanText: store.readMatrixScan(), layout: data.layout,
                                                        scanBelongsToCurrentKeyboard: false)
            let reports = AggregateHardwareReportStore(directory: store.directory)
            hardwareCheckWindow = HardwareCheckWindowController(data: data, limits: keyboardLimits(for: data.layout),
                                                                identity: identity, confidence: confidence,
                                                                onFocus: { [weak self] on in
                                                                    self?.setProbeActive(on, owner: .hardwareCheck)
                                                                }, onSave: { try reports.saveHardware($0) })
        }
        hardwareCheckWindow?.present()
    }

    @objc private func openErgonomicTrial() {
        if ergonomicTrialWindow == nil {
            let data = router.engine.data
            let reports = AggregateHardwareReportStore(directory: store.directory)
            ergonomicTrialWindow = ErgonomicTrialWindowController(data: data, limits: keyboardLimits(for: data.layout),
                                                                  identity: hardwareIdentity, rolloverLimit: settings.rolloverLimit,
                                                                  onFocus: { [weak self] on in
                                                                      self?.setProbeActive(on, owner: .ergonomicTrial)
                                                                  }, onSave: { try reports.saveErgonomics($0) })
        }
        ergonomicTrialWindow?.present()
    }

    @objc private func openFolder() {
        _ = store.installMissingDefaults()
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func openProbe() {
        if probeWindow == nil {
            probeWindow = ProbeWindowController(
                data: router.engine.data, rolloverLimit: settings.rolloverLimit,
                onFocus: { [weak self] on in self?.setProbeActive(on, owner: .probe) },
                onSave: { [weak self] report in self?.saveProbe(report) ?? "" })
        }
        probeWindow?.present()
    }

    @objc private func openMatrixScan() {
        installWiring()   // the scan report checks the wiring
        if matrixWindow == nil {
            matrixWindow = MatrixScanWindowController(
                data: router.engine.data, store: store,
                onFocus: { [weak self] on in self?.setProbeActive(on, owner: .matrix) })
        }
        matrixWindow?.present()
    }

    @objc private func openWiringCheck() {
        if wiringCheckWindow == nil {
            wiringCheckWindow = WiringCheckWindowController(
                data: router.engine.data, store: store,
                onFocus: { [weak self] on in self?.setProbeActive(on, owner: .wiring) })
        }
        installWiring()
        guard let w = wiringCheckWindow else {
            alert("Wiring Check unavailable", "The check list doesn't match the current layout.", buttons: ["OK"]) { _ in }
            return
        }
        w.present()
    }

    private func saveProbe(_ report: ProbeReport) -> String {
        do {
            try store.writeProbeReport(report.serialized())
            reloadDictionaries()
            return "Saved \(report.results.count) results to \(store.probeReportURL.path)"
        } catch {
            return "Could not save the report: \(error.localizedDescription)"
        }
    }

    /// Req 15.6: reload without restarting. File I/O happens off the event path (Req 2.9).
    @objc private func reloadDictionaries() { reload(announce: true) }

    /// Reloads everything; `announce` says so when all files are valid.
    private func reload(announce: Bool) {
        let limit = settings.rolloverLimit
        let lastValid = self.lastValid
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DictionaryLoader.load(sources: store.readAll(), lastValid: lastValid, rolloverLimit: limit,
                                                probeReport: store.readProbeReport(), wiring: store.readWiring())
            DispatchQueue.main.async {
                self.lastValid = outcome.acceptedSources
                self.router.replaceData(outcome.data)
                let reopenFirstChords = self.firstChordWindow?.window?.isVisible == true
                self.firstChordWindow?.close()
                self.firstChordWindow = nil
                self.hardwareCheckWindow?.close()
                self.hardwareCheckWindow = nil
                self.ergonomicTrialWindow?.close()
                self.ergonomicTrialWindow = nil
                self.editorPracticeWindow?.close()
                self.editorPracticeWindow = nil
                self.wordPracticeWindow?.close()
                self.wordPracticeWindow = nil
                self.probeWindow?.update(data: outcome.data, rolloverLimit: limit)
                self.matrixWindow?.update(data: outcome.data)
                self.overlay?.update(data: outcome.data)
                self.guideWindow?.limits = KeyboardLimits(wiringText: store.readWiring(), scanText: store.readMatrixScan(),
                                                          layout: outcome.data.layout)
                self.guideWindow?.update(data: outcome.data, rolloverLimit: limit)
                if reopenFirstChords { self.showFirstChords(stage: .see) }
                if self.layoutWindow?.window?.isVisible == true { self.showLayout() }
                self.report(problems: outcome.problems, warnings: outcome.warnings, dropped: outcome.droppedChords, extra: [],
                            fallbacks: outcome.fallbacks, announceSuccess: announce)
                self.updateIndicator()
            }
        }
    }

    // MARK: Problems (Req 15.5, 5.10)

    private func report(problems: [LoadProblem], warnings: [LoadProblem], dropped: [LoadProblem] = [], extra: [String],
                        fallbacks: [DataFile] = [], announceSuccess: Bool = false) {
        if problems.isEmpty && warnings.isEmpty && dropped.isEmpty && extra.isEmpty {
            if announceSuccess {
                alert("Dictionaries reloaded", "All files are valid.", buttons: ["OK"]) { _ in }
            }
            return
        }
        var text = ""
        if !extra.isEmpty { text += extra.joined(separator: "\n") + "\n\n" }
        if !problems.isEmpty {
            text += "Problems (\(problems.count)). Files with problems were not used; KeyChord keeps the last valid version, or the bundled default.\n"
            if !fallbacks.isEmpty { text += "Using a previous version of: " + fallbacks.map(\.fileName).joined(separator: ", ") + "\n" }
            text += "\n" + problems.map(\.description).joined(separator: "\n") + "\n\n"
        }
        if !warnings.isEmpty {
            text += "Rollover probe warnings (\(warnings.count)). These chords contain a key combination that failed the probe:\n\n"
            text += warnings.map(\.description).joined(separator: "\n") + "\n"
        }
        if !dropped.isEmpty {
            text += "\nChords this keyboard can't type (\(dropped.count)). With all their keys held, the keyboard drops "
                + "one of them, so give these chords other keys. The Typing Guide won't suggest them:\n\n"
            text += dropped.map(\.description).joined(separator: "\n") + "\n"
        }
        text += "\nFiles are in \(store.directory.path)\n"
        if problemsWindow == nil { problemsWindow = TextWindowController(title: "KeyChord: Dictionary Problems") }
        problemsWindow?.show(text: text)
    }

    // MARK: Permissions (Req 18.1)

    private func enableOtherAppTyping() {
        learningJourney.chooseOtherApps()
        if !startTapIfPermitted() { explainPermissions() }
        updatePracticeState()
    }

    private func explainPermissions() {
        guard !Permissions.allGranted else { return }
        let msg = "KeyChord needs Accessibility access to read chord keys, keep them from reaching other apps, "
            + "and type the text of each chord. Until you allow it, chord typing stays off.\n\n"
            + "KeyChord keeps typed text in memory only and makes no network connections."
        alert("Allow KeyChord to use Accessibility", msg, buttons: ["Open Accessibility Settings", "Later"]) { i in
            if i == 0 { Permissions.openAccessibility() }
        }
    }

    @objc private func showPermissions() {
        func mark(_ b: Bool) -> String { b ? "granted" : "missing" }
        let text = "Accessibility: \(mark(Permissions.accessibility))\n"
            + "Input Monitoring: \(mark(Permissions.inputMonitoring)) (not required)\n"
            + "Keyboard interception: \(tap.isRunning ? "running" : tapCreationFailed ? "failed, relaunch KeyChord" : "not running")\n"
            + "App: \(Bundle.main.bundlePath)\n"
            + "Secure Input: \(SecureInput.isOn ? "on (chord typing unavailable)" : "off")"
        alert("Permission Status", text, buttons: ["OK", "Open Accessibility Settings", "Open Input Monitoring Settings"]) { i in
            if i == 1 { Permissions.openAccessibility() }
            if i == 2 { Permissions.openInputMonitoring() }
        }
    }

    private func alert(_ title: String, _ text: String, buttons: [String], completion: @escaping (Int) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        let r = a.runModal()
        completion(r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
