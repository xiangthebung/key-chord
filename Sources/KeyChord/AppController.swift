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
    private var tapFailures = 0
    private var relaunchNotified = false

    private var problemsWindow: TextWindowController?
    private var practiceWindow: PracticeWindowController?
    private var typingAccess: TypingAccessStore!
    private var manualWindow: ManualWindowController?
    private var customChordsWindow: CustomChordsWindowController?
    private var baseData: EngineData!
    private var customChords: [CustomChord] = []
    private var customChordsLoadError: String?
    private var overlay: ReferenceOverlayController?
    /// Set while the reference overlay is on screen. It only follows keys while chord typing is on.
    private var overlayListener: ((RawKeyEvent) -> Void)?

    private var permissionTimer: Timer?
    private var stateTimer: Timer?
    /// Each focused local surface owns its own pause. Losing one focus cannot release another's pause.
    private enum LocalInputOwner: Hashable { case practice, customChords }
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
        if !flag { openPractice() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)                 // Req 17.1: no Dock icon

        // Snapshot pre-existing files before installing defaults. Updating an older installation
        // should never disable previously enabled global typing.
        let hasExistingData = DataFile.allCases.contains { FileManager.default.fileExists(atPath: store.url($0).path) }
        typingAccess = TypingAccessStore(hasExistingDataFiles: hasExistingData)

        let installErrors = store.installMissingDefaults()    // Req 15.2
        applyKeyboard()
        let outcome = DictionaryLoader.load(sources: store.readAll(), rolloverLimit: settings.rolloverLimit,
                                            probeReport: store.readProbeReport(), wiring: store.readWiring())
        lastValid = outcome.acceptedSources
        baseData = outcome.data
        do { customChords = try store.readCustomChords() }
        catch { customChordsLoadError = "Saved custom chords could not be read. The saved file is unchanged. " + error.localizedDescription }
        let usable = keyboardLimits(for: baseData.layout).map { $0.usable(in: baseData.layout) } ?? { _ in true }
        let data = CustomChords.applying(customChords, to: baseData, rolloverLimit: settings.rolloverLimit, usable: usable)
        router = EventRouter(data: data, lastSubMode: settings.lastSubMode,
                             tapTimeoutMs: UInt64(settings.tapTimeoutMs))       // Req 17.5
        _ = router.setPermissionsGranted(false)              // until the tap is running

        tap = EventTap { [unowned self] type, event in self.handleTap(type, event) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installMainMenu()
        updateIndicator()
        if settings.overlayVisible { showOverlay() }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostAppChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollState() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollPermissions() }

        _ = startTapIfPermitted()
        // Returning users already chose global typing. A rebuilt app may have lost its
        // Accessibility grant; explain how to renew it once, instead of silently polling.
        if typingAccess.permitsGlobalTyping && !Permissions.allGranted {
            DispatchQueue.main.async { self.explainPermissions() }
        }
        if typingAccess.showPracticeAtLaunch {
            DispatchQueue.main.async { self.openPractice() }
        }
        report(problems: outcome.problems, warnings: outcome.warnings, dropped: outcome.droppedChords,
               extra: installErrors + [customChordsLoadError].compactMap { $0 })
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
        // Local input must bypass the global router and emitter.
        if !localInputOwners.isEmpty { return pass }
        if let overlayListener { forwardRawKey(type, event, to: overlayListener) }

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
                try emitter.emit(out.actions)                                   // Req 16.1, 16.4
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

    /// Physical key presses for the reference overlay, before the router holds chord keys back.
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
        if isFlashing && Date() > flashUntil {
            isFlashing = false
            updateIndicator()
        }
    }

    private var isFlashing = false

    private func pollPermissions() {
        guard typingAccess.permitsGlobalTyping else { return }
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
        guard typingAccess.permitsGlobalTyping else { return false }
        guard Permissions.allGranted else {
            tapFailures = 0
            if router.permissionsGranted { handle(events: router.setPermissionsGranted(false)) }
            updateIndicator()
            return false
        }
        if tap.start() {
            tapFailures = 0
            handle(events: router.setPermissionsGranted(true))
            return true
        }
        if router.permissionsGranted { handle(events: router.setPermissionsGranted(false)) }
        tapFailures += 1
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
        if !typingAccess.permitsGlobalTyping { return "Local" }
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
        if !typingAccess.permitsGlobalTyping {
            return "Typing in other apps is off"
        }
        switch router.availability {
        case .missingPermission:
            return Permissions.accessibility ? "KeyChord needs to be reopened" : "KeyChord needs Accessibility access"
        case .secureInput: return "Paused while Secure Input is on"
        case .available:
            if case .chord = router.displayedMode, !localInputOwners.isEmpty {
                return localInputOwners.contains(.customChords) ? "Chord typing paused while editing chords" : "Chord typing paused in Practice"
            }
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
        if !typingAccess.permitsGlobalTyping {
            button.toolTip = "KeyChord: local practice. Open the menu to enable typing in other apps."
        } else { switch router.availability {
        case .missingPermission: button.toolTip = statusLine()
        case .secureInput:
            button.toolTip = "KeyChord is paused while Secure Input is on, for example in a password field."
        case .available:
            if case .chord = router.displayedMode {
                button.toolTip = "KeyChord: \(indicatorTitle()) chord typing. Tap right Option to stop."
            } else {
                button.toolTip = "KeyChord is off. Tap right Option to start chord typing."
            }
        } }
        button.setAccessibilityLabel(button.toolTip)
        updateOverlay()
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
            status = typingAccess.permitsGlobalTyping ? "KeyChord needs Accessibility access to read chords."
                : "Local practice is available. Enable typing in other apps when you are ready."
        case .secureInput: status = "Paused while Secure Input is on."
        case .available:
            if case .chord = router.displayedMode {
                status = localInputOwners.contains(.customChords) ? "Paused while editing custom chords."
                    : "Paused while practicing in KeyChord."
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

    /// Focused local surfaces pause global typing while they own the keyboard.
    private func setProbeActive(_ on: Bool, owner: LocalInputOwner) {
        if on { localInputOwners.insert(owner) } else { localInputOwners.remove(owner) }
        router.setProbeActive(!localInputOwners.isEmpty)
        if localInputOwners.isEmpty {
            // Releases inside a local surface bypassed the global router. Forget any old
            // held-key bookkeeping before it accepts the next explicit right-Option tap.
            router.syncPhysicalKeys(physicallyHeldKeys())
        }
        updateOverlay()
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
        if !typingAccess.permitsGlobalTyping {
            menu.addItem(item("Enable Typing in Other Apps…", #selector(openAccessibilitySettings)))
        } else if router.availability == .missingPermission && !Permissions.accessibility {
            menu.addItem(item("Allow Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        let available = router.availability == .available
        let chord = item("Chord Typing", #selector(toggleChord), key: "⌥")
        chord.keyEquivalentModifierMask = []
        chord.toolTip = "Tap the Option (⌥) key on the right of the space bar to start or pause chord typing."
        if case .chord = router.displayedMode { chord.state = .on }
        chord.isEnabled = available
        menu.addItem(chord)
        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let en = item("English", #selector(selectEnglish))
        en.state = router.lastSubMode == .english ? .on : .off
        let cpp = item("C++", #selector(selectCpp))
        cpp.state = router.lastSubMode == .cpp ? .on : .off
        en.isEnabled = available
        cpp.isEnabled = available
        languageMenu.addItem(en)
        languageMenu.addItem(cpp)
        language.submenu = languageMenu
        menu.addItem(language)
        menu.addItem(.separator())
        menu.addItem(practiceMenuItem())
        menu.addItem(item("Reference", #selector(openManual)))
        menu.addItem(item("Custom Chords", #selector(openCustomChords)))

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        let overlayItem = item("Keyboard Overlay", #selector(toggleOverlay))
        overlayItem.state = overlay?.isVisible == true ? .on : .off
        settingsMenu.addItem(overlayItem)
        settingsMenu.addItem(.separator())
        let keyboard = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: "")
        keyboard.toolTip = "The keyboard Practice and Reference show, and whose wiring decides "
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
        let labels = NSMenuItem(title: "Key Labels", action: nil, keyEquivalent: "")
        let labelsMenu = NSMenu()
        for (title, style) in [("Printed keys", KeyLabelStyle.physical), ("Chord meanings", .meaning), ("Both", .both)] {
            let choice = item(title, #selector(setKeyLabels(_:)))
            choice.representedObject = style.rawValue
            choice.state = settings.keyLabelStyle == style ? .on : .off
            labelsMenu.addItem(choice)
        }
        labels.submenu = labelsMenu
        settingsMenu.addItem(labels)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit KeyChord", #selector(quit), key: "q"))
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "KeyChord", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "KeyChord")
        appMenu.addItem(practiceMenuItem(wordShortcut: "o"))
        appMenu.addItem(item("Reference", #selector(openManual)))
        appMenu.addItem(item("Custom Chords", #selector(openCustomChords)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit KeyChord", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullscreen)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func practiceMenuItem(wordShortcut: String = "") -> NSMenuItem {
        let practice = NSMenuItem(title: "Practice", action: nil, keyEquivalent: "")
        let choices = NSMenu(title: "Practice")
        choices.addItem(item("Words", #selector(openWords), key: wordShortcut))
        choices.addItem(item("Lessons", #selector(openLessons)))
        choices.addItem(item("Voice Practice", #selector(openVoicePractice)))
        practice.submenu = choices
        return practice
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openAccessibilitySettings() {
        typingAccess.chooseOtherApps()
        if !startTapIfPermitted() { Permissions.openAccessibility() }
    }
    @objc private func toggleChord() { handle(events: router.toggleChordMode()) }
    @objc private func selectEnglish() { handle(events: router.selectSubMode(.english)) }
    @objc private func selectCpp() { handle(events: router.selectSubMode(.cpp)) }

    @objc private func setKeyLabels(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let style = KeyLabelStyle(rawValue: value) {
            settings.keyLabelStyle = style
        }
    }

    @objc private func setKeyboard(_ sender: NSMenuItem) {
        let before = keyboardKind
        settings.keyboard = (sender.representedObject as? String).flatMap(KeyboardGeometry.Kind.init(rawValue:))
        guard keyboardKind != before else { return }
        applyKeyboard()
        // The new wiring changes which chords Practice may suggest and which edited chords get a warning.
        reloadMapping()
    }

    /// What this keyboard can register, from the installed wiring file or a saved Matrix Scan.
    private func keyboardLimits(for layout: Layout) -> KeyboardLimits? {
        installWiring()
        return KeyboardLimits(wiringText: store.readWiring(), scanText: store.readMatrixScan(), layout: layout)
    }

    @objc private func openManual() {
        if manualWindow == nil {
            let manual = ManualWindowController()
            manual.onPractice = { [weak self] in self?.openPractice() }
            manual.onCustomChords = { [weak self] in self?.openCustomChords() }
            manualWindow = manual
        }
        let data = router.engine.data
        let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
        manualWindow?.show(html: Manual.html(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                                             keyboard: KeyboardDiagramView.geometry))
    }

    @objc private func openCustomChords() {
        if customChordsWindow == nil {
            let data = baseData!
            let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
            let editor = CustomChordsWindowController(base: data, chords: customChords,
                rolloverLimit: settings.rolloverLimit, usable: usable, loadError: customChordsLoadError,
                globalSuspended: { [weak self] in self?.localInputOwners.contains(.customChords) == true },
                onSave: { [unowned self] chords in
                    let base = self.baseData!
                    let usable = self.keyboardLimits(for: base.layout).map { $0.usable(in: base.layout) } ?? { _ in true }
                    for (index, chord) in chords.enumerated() where self.customChords.first(where: { $0.id == chord.id }) != chord {
                        // Disabled entries can be retained for repair, including after a layout change.
                        guard chord.isEnabled else { continue }
                        let others = chords.enumerated().filter { $0.offset != index }.map(\.element)
                        if let issue = CustomChords.issue(for: chord, among: others, base: self.baseData,
                                                         rolloverLimit: self.settings.rolloverLimit, usable: usable) {
                            throw NSError(domain: "KeyChord.CustomChords", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: issue.message])
                        }
                    }
                    try self.store.writeCustomChords(chords)
                    self.customChords = chords
                    self.refreshChordData()
                })
            editor.onLocalFocus = { [weak self] on in self?.setProbeActive(on, owner: .customChords) }
            customChordsWindow = editor
        }
        customChordsWindow?.present()
    }

    private func refreshChordData() {
        let base = baseData!
        let usable = keyboardLimits(for: base.layout).map { $0.usable(in: base.layout) } ?? { _ in true }
        let data = CustomChords.applying(customChords, to: base, rolloverLimit: settings.rolloverLimit, usable: usable)
        router.replaceData(data)
        practiceWindow?.update(data: data, rolloverLimit: settings.rolloverLimit, usable: usable)
        customChordsWindow?.update(base: base, rolloverLimit: settings.rolloverLimit, usable: usable)
        overlay?.update(data: data)
        if manualWindow?.window?.isVisible == true {
            manualWindow?.update(html: Manual.html(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                                                 keyboard: KeyboardDiagramView.geometry))
        }
        updateIndicator()
    }

    /// Menu choices open only their selected practice activity in the shared window.
    private func showPractice(section: PracticeSection? = nil) {
        if practiceWindow == nil {
            let data = router.engine.data
            let usable = keyboardLimits(for: data.layout).map { $0.usable(in: data.layout) } ?? { _ in true }
            let practice = PracticeWindowController(data: data, rolloverLimit: settings.rolloverLimit, usable: usable,
                globalSuspended: { [weak self] in self?.localInputOwners.contains(.practice) == true })
            practice.onLocalFocus = { [weak self] on in self?.setProbeActive(on, owner: .practice) }
            practiceWindow = practice
        }
        if let section, practiceWindow?.section != section { practiceWindow?.selectSection(section) }
        practiceWindow?.present()
    }

    @objc private func openPractice() { showPractice() }
    @objc private func openWords() { showPractice(section: .words) }
    @objc private func openLessons() { showPractice(section: .lessons) }
    @objc private func openVoicePractice() { showPractice(section: .voice) }

    /// Keyboard selection revalidates the installed mapping automatically.
    private func reloadMapping() {
        let limit = settings.rolloverLimit
        let lastValid = self.lastValid
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DictionaryLoader.load(sources: store.readAll(), lastValid: lastValid, rolloverLimit: limit,
                                                probeReport: store.readProbeReport(), wiring: store.readWiring())
            DispatchQueue.main.async {
                self.lastValid = outcome.acceptedSources
                self.baseData = outcome.data
                self.refreshChordData()
                self.report(problems: outcome.problems, warnings: outcome.warnings, dropped: outcome.droppedChords, extra: [],
                            fallbacks: outcome.fallbacks)
                self.updateIndicator()
            }
        }
    }

    // MARK: Problems (Req 15.5, 5.10)

    private func report(problems: [LoadProblem], warnings: [LoadProblem], dropped: [LoadProblem] = [], extra: [String],
                        fallbacks: [DataFile] = []) {
        if problems.isEmpty && warnings.isEmpty && dropped.isEmpty && extra.isEmpty {
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
                + "one of them, so give these chords other keys. Practice won't suggest them:\n\n"
            text += dropped.map(\.description).joined(separator: "\n") + "\n"
        }
        text += "\nFiles are in \(store.directory.path)\n"
        if problemsWindow == nil { problemsWindow = TextWindowController(title: "KeyChord · Chord Setup") }
        problemsWindow?.show(text: text)
    }

    // MARK: Permissions (Req 18.1)

    private func explainPermissions() {
        guard !Permissions.allGranted else { return }
        let msg = "KeyChord needs Accessibility access to read chord keys, keep them from reaching other apps, "
            + "and type the text of each chord. Until you allow it, chord typing stays off.\n\n"
            + "KeyChord keeps typed text in memory only and makes no network connections."
        alert("Allow KeyChord to use Accessibility", msg, buttons: ["Open Accessibility Settings", "Later"]) { i in
            if i == 0 { Permissions.openAccessibility() }
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
