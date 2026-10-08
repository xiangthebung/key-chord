import AppKit
import KeyChordCore

/// A learner-controlled bridge to a supported local editor. No window content, editor text, key
/// events, timing, or external completion is inspected. Return and practice are self-reported.
final class EditorPracticeWindowController: NSWindowController, NSWindowDelegate {
    var onEnableOtherApps: (() -> Void)?
    var onPrepareEditor: (() -> Void)?
    var onContinueCourse: (() -> Void)?
    private let store: LearningJourneyStore
    private let undo: String
    private let punctuation: String
    private let mode: SubMode
    private var ready = false
    private var launched = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private var enable: PracticeActionButton!
    private var openEditor: PracticeActionButton!
    private var report: PracticeActionButton!

    init(data: EngineData, store: LearningJourneyStore, mode: SubMode = .english, rolloverLimit: Int = 6,
         usable: @escaping (KeySet) -> Bool = { _ in true }) {
        self.store = store
        self.mode = mode
        let meanings = KeyMeanings(data: data, mode: mode)
        undo = meanings.undoKeys.map { keys in
            keys.indices.map { "“" + KeyboardDiagramView.name(for: data.layout.keys[$0].code) + "”" }.joined(separator: " + ")
        } ?? "your configured Undo chord"
        let period = TypingPlanner(data: data, mode: mode, rolloverLimit: rolloverLimit, usable: usable).plan(".")
        if period.steps.count == 1, case let .chord(names, _) = period.steps[0].action {
            let physical = names.compactMap { data.layout.indexByName[$0] }.map {
                "“" + KeyboardDiagramView.name(for: data.layout.keys[$0].code) + "”"
            }.joined(separator: " + ")
            punctuation = "The current period chord is \(physical). It also sets up the next capital in English."
        } else {
            punctuation = "Switch to ordinary typing to add punctuation that your current mapping cannot chord."
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyChord · Use it in an editor"
        window.minSize = NSSize(width: 550, height: 490)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func update(availability: Availability, optedIn: Bool, tapRunning: Bool) {
        ready = availability == .available && optedIn && tapRunning
        enable.isHidden = ready
        openEditor.isEnabled = ready
        switch availability {
        case .missingPermission:
            status.stringValue = "To type chords in TextEdit, choose Enable typing in other apps. Accessibility lets KeyChord read chord keys and type their output."
        case .secureInput:
            status.stringValue = "Chord typing is paused while Secure Input is on. Close the secure field to continue."
        case .available:
            status.stringValue = ready ? "Ready for TextEdit. Chord typing starts off; tap right Option in your document when you want chords."
                : "Choose Enable typing in other apps before opening the chord exercise."
        }
    }

    private var tasks: String {
        let writing = mode == .cpp
            ? "Write a small original code fragment using the chords you know. Use normal Return and Tab for indentation. Try a bracket or auto-pair, then move the cursor inside it and finish the expression."
            : "Write one short original sentence using words you can chord. Include sat, hat, or tan if they fit. Add a period. \(punctuation)"
        return "1. At the end of the scratch document, tap and release the right Option key. Check the menu bar for \(mode == .cpp ? "C++" : "English"). Press chord keys together and release all of them.\n\n"
            + "2. \(writing)\n\n"
            + "3. Intentionally type a wrong chord. Press \(undo) to undo that chord, then write the intended word. Undo works until an ordinary edit or cursor move resets its context.\n\n"
            + "4. Move the cursor into your writing and make an edit. Tap right Option for ordinary typing; use normal arrows, Delete, Return, Tab and Command-Z as needed. Tap right Option again for chords.\n\n"
            + "5. Return to KeyChord from its menu bar and report whether you tried the tasks. KeyChord does not measure this editor exercise."
    }

    private func buildUI() {
        let heading = NSTextField(wrappingLabelWithString: "Use your chords in TextEdit")
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        let summary = NSTextField(wrappingLabelWithString: "A short original-writing exercise with punctuation, cursor movement, correction, and ordinary typing.")
        summary.font = .systemFont(ofSize: 15)
        let taskLabel = NSTextField(wrappingLabelWithString: tasks)
        taskLabel.font = .systemFont(ofSize: 14)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        result.font = .systemFont(ofSize: 13)
        result.stringValue = store.editorPracticeReported ? "You previously reported trying editor practice. This is a self-report, not measured transfer or retention." : ""
        enable = PracticeActionButton("Enable typing in other apps…") { [weak self] in self?.onEnableOtherApps?() }
        openEditor = PracticeActionButton("Open scratch exercise in TextEdit") { [weak self] in self?.openScratch() }
        report = PracticeActionButton("I tried these tasks") { [weak self] in
            guard let self, self.launched else { return }
            self.store.reportEditorPractice()
            self.result.stringValue = "Editor practice self-reported. No editor text or performance was measured. Revisit the course later for a separate recall check."
        }
        report.isEnabled = false
        let returnCourse = PracticeActionButton("Continue course") { [weak self] in self?.onContinueCourse?() }
        let privacy = NSTextField(wrappingLabelWithString:
            "The scratch file contains task instructions. TextEdit owns your document; saving it saves your writing. "
            + "KeyChord never reads it and stores only your practice self-report.")
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = .secondaryLabelColor
        let column = PracticeUI.column([heading, summary, status, taskLabel, enable!, openEditor!, result,
                                       PracticeUI.row([report!, returnCourse]), privacy], spacing: 16)
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
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
    }

    private func openScratch() {
        guard ready else { return }
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            result.stringValue = "TextEdit could not be found. Open an editor you use, then follow these tasks there."
            return
        }
        do {
            // This is a new disposable instruction document, never a copy or log of user input.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyChord-" + UUID().uuidString,
                                                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let document = directory.appendingPathComponent("KeyChord editor exercise.txt")
            try ("KEYCHORD · EDITOR PRACTICE\n\n" + tasks + "\n\nWrite here (Command–Down Arrow, ⌘↓, moves to the end):\n\n")
                .write(to: document, atomically: true, encoding: .utf8)
            onPrepareEditor?()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([document], withApplicationAt: editor, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error { self.result.stringValue = "TextEdit could not open the exercise: \(error.localizedDescription)" }
                    else {
                        self.launched = true
                        self.report.isEnabled = true
                        self.result.stringValue = "The scratch exercise is open in TextEdit. Return here when you have tried the tasks."
                    }
                }
            }
        } catch {
            result.stringValue = "The scratch exercise could not be created: \(error.localizedDescription)"
        }
    }
}
