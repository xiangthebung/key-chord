// Reference overlay: a small floating panel that keeps the basics on screen while you type in any app. It shows
// the keyboard with what each key means, the sounds and words that take several keys, and, while chord typing
// is on, the keys being held and what that chord types before you let go.
//
// The panel never becomes the key window, so typing always goes to the app you are in. It only follows keys
// while chord typing is on; in Normal mode it shows nothing of what you type. Nothing is stored (Req 18.6).

import AppKit
import KeyChordCore

/// A floating panel that never takes keyboard focus or activates KeyChord.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks work in a panel that is never key, so the page switch takes the first click.
private final class FirstClickSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ReferenceOverlayController: NSWindowController, NSWindowDelegate {
    /// Called when the user closes the panel.
    var onClose: (() -> Void)?

    private var data: EngineData
    private var subMode: SubMode
    /// Chord typing is on and KeyChord is reading chords, so held keys are shown.
    private var chording = false
    /// What to say when chord typing is not on.
    private var status = ""

    // The chord in progress, followed the way the Chord_Engine does: every chord key pressed until all are up.
    private var held = Set<KeyCode>()
    private var chord = KeySet()
    private var shift = false
    private var last: ChordReading?

    private let modeLabel = NSTextField(labelWithString: "")
    private let readingLabel = NSTextField(labelWithString: "")
    private let pages = FirstClickSegmentedControl(labels: ["Keys", "Sounds", "Words"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let keyboard = KeyboardDiagramView()
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let keysPage = NSStackView()
    private var soundsScroll: NSScrollView!
    private var wordsScroll: NSScrollView!

    private static let shiftCodes: Set<KeyCode> = [56, 60]
    /// Command, Option and Control: a key pressed with them is a shortcut, and they end a chord (Req 2.4, 3.8).
    private static let shortcutCodes: Set<KeyCode> = [54, 55, 58, 59, 61, 62]
    private static let lockCodes: Set<KeyCode> = [57, 63]
    private static let frameName = "KeyChordReferenceOverlay"
    private static let pageKey = "overlayPage"

    init(data: EngineData, subMode: SubMode) {
        self.data = data
        self.subMode = subMode
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 330),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = "KeyChord Reference"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false          // KeyChord is never the active app while you type elsewhere
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 440, height: 220)
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            // Bottom center of the screen, clear of the Dock.
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2, y: v.minY + 24))
        }
        panel.setFrameAutosaveName(Self.frameName)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        modeLabel.font = .systemFont(ofSize: 13, weight: .bold)
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        readingLabel.lineBreakMode = .byTruncatingTail
        readingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        readingLabel.setAccessibilityLabel("The chord you are holding")
        pages.selectedSegment = min(2, max(0, UserDefaults.standard.integer(forKey: Self.pageKey)))
        pages.target = self
        pages.action = #selector(pageChanged)
        pages.controlSize = .small
        pages.setAccessibilityLabel("Reference page")
        let header = NSStackView(views: [modeLabel, readingLabel, pages])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY

        keyboard.showsFunctionRow = false
        keyboard.setContentHuggingPriority(.init(1), for: .vertical)
        keyboard.setContentCompressionResistancePriority(.init(1), for: .vertical)
        legendLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keysPage.setViews([keyboard, legendLabel], in: .leading)
        keysPage.orientation = .vertical
        keysPage.alignment = .leading
        keysPage.spacing = 4
        for v in [keyboard, legendLabel] { v.widthAnchor.constraint(equalTo: keysPage.widthAnchor).isActive = true }

        soundsScroll = Self.textPage("Sounds that take several keys")
        wordsScroll = Self.textPage("Endings, punctuation, words and commands")

        let body = NSView()
        for v in [keysPage, soundsScroll!, wordsScroll!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        }
        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        body.setContentHuggingPriority(.init(1), for: .vertical)
        showPage()
    }

    /// A read-only, transparent text page that scrolls when it doesn't fit.
    private static func textPage(_ label: String) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = false
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 0, height: 2)
            tv.setAccessibilityLabel(label)
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func textView(of scroll: NSScrollView) -> NSTextView? { scroll.documentView as? NSTextView }

    @objc private func pageChanged() {
        UserDefaults.standard.set(pages.selectedSegment, forKey: Self.pageKey)
        showPage()
    }

    private func showPage() {
        let p = pages.selectedSegment
        keysPage.isHidden = p != 0
        soundsScroll?.isHidden = p != 1
        wordsScroll?.isHidden = p != 2
    }

    // MARK: Presenting

    /// Shows the panel without activating KeyChord or taking focus from the app in front.
    func present() {
        window?.orderFrontRegardless()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        clearChord()
        onClose?()
    }

    /// New dictionaries from Reload Dictionaries.
    func update(data: EngineData) {
        self.data = data
        clearChord()
        rebuild()
    }

    /// The mode KeyChord is in. `chording`: chord keys are being read; `status` says what is going on otherwise.
    func update(subMode: SubMode, chording: Bool, status: String) {
        let modeChanged = subMode != self.subMode
        self.subMode = subMode
        self.status = status
        if chording != self.chording || modeChanged {
            self.chording = chording
            clearChord()
            last = nil
        }
        if modeChanged { rebuild() } else { refresh() }
    }

    private func clearChord() {
        held.removeAll()
        chord = KeySet()
        shift = false
        refresh()
    }

    // MARK: Keys

    /// A physical key going down or up, from the event tap.
    func rawKey(_ e: RawKeyEvent) {
        guard chording else { return }
        let layout = data.layout
        switch e {
        case .down(let c):
            held.insert(c)
            if Self.shiftCodes.contains(c) {
                if !chord.isEmpty { shift = true }                 // the Join_Modifier (Req 3.6)
            } else if Self.shortcutCodes.contains(c) {
                chord = KeySet()                                    // Req 3.8
            } else if Self.lockCodes.contains(c) {
                break
            } else if let i = layout.indexByCode[c], held.isDisjoint(with: Self.shortcutCodes) {
                if chord.isEmpty { shift = !held.isDisjoint(with: Self.shiftCodes) }
                chord.insert(i)
            } else {
                chord = KeySet()                                    // a pass-through key or a shortcut (Req 3.9)
            }
        case .up(let c):
            held.remove(c)
            if !chord.isEmpty && !held.contains(where: { layout.indexByCode[$0] != nil }) {
                last = ChordReading(chord, shift: shift, data: data, mode: subMode)
                chord = KeySet()
                shift = false
            }
        }
        refresh()
    }

    // MARK: Drawing

    private func refresh() {
        let current = chord.isEmpty ? nil : ChordReading(chord, shift: shift, data: data, mode: subMode)
        keyboard.held = chording ? held : []
        keyboard.heldColor = current?.outcome == .nothing ? .systemOrange : nil

        switch (chording, subMode) {
        case (false, _): modeLabel.stringValue = "Off"; modeLabel.textColor = .secondaryLabelColor
        case (true, .english): modeLabel.stringValue = "English"; modeLabel.textColor = .controlAccentColor
        case (true, .cpp): modeLabel.stringValue = "C++"; modeLabel.textColor = .controlAccentColor
        }
        let size: CGFloat = 13
        if !chording {
            readingLabel.attributedStringValue = NSAttributedString(string: status, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])
        } else if let current {
            readingLabel.attributedStringValue = ChordText.reading(current, layout: data.layout, size: size)
        } else if let last {
            readingLabel.attributedStringValue = ChordText.reading(last, layout: data.layout, size: size, dim: true)
        } else {
            readingLabel.attributedStringValue = NSAttributedString(
                string: "Hold the keys of a chord to see what it types before you let go.",
                attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])
        }
        readingLabel.toolTip = readingLabel.stringValue
        let names = held.sorted().map { KeyboardDiagramView.name(for: $0) }
        keyboard.setAccessibilityLabel("Keyboard. Held: " + (names.isEmpty ? "none" : names.joined(separator: " + ")))
    }

    /// Labels and pages for the current data and mode.
    private func rebuild() {
        let m = KeyMeanings(data: data, mode: subMode)
        keyboard.layout = data.layout
        keyboard.meanings = m
        legendLabel.attributedStringValue = TypingGuideWindowController.legend(m, layout: data.layout)
        textView(of: soundsScroll)?.textStorage?.setAttributedString(soundsText())
        textView(of: wordsScroll)?.textStorage?.setAttributedString(wordsText())
        refresh()
    }

    private func soundsText() -> NSAttributedString {
        let layout = data.layout
        let size: CGFloat = 13
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "The keyboard shows the sounds with one key. These take several keys, pressed with the rest of "
                + "the chord.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        let own = KeyMeanings.multiKeySounds(layout)
        let pairs = KeyMeanings.pairSounds(layout)
        let names: [(Bank, String, KeyMeanings.Role)] = [(.onset, "Start", .onset), (.vowel, "Vowel", .vowel),
                                                        (.coda, "End", .coda)]
        for (bank, title, role) in names {
            let list = own[bank] ?? []
            guard !list.isEmpty else { continue }
            let color = KeyboardDiagramView.color(for: role)
            out.append(ChordText.heading(title, color: color, size: size))
            out.append(ChordText.items(list.map { ($0.text, ChordText.keys($0.keys, layout: layout), color) }, size: size))
            out.append(NSAttributedString(string: "\n\n"))
        }
        // Pairs need no table: two sounds that each have a key take both keys.
        let examples = Bank.allCases.flatMap { bank -> [KeyMeanings.Sound] in
            let preferred: [String] = bank == .onset ? ["st", "th", "tr"] : bank == .coda ? ["nd", "nt", "te"] : []
            let list = pairs[bank] ?? []
            let picked = preferred.compactMap { p in list.first { $0.text == p } }
            return picked.isEmpty ? Array(list.prefix(2)) : picked
        }
        if !examples.isEmpty {
            out.append(ChordText.heading("Two sounds that each have a key: press both keys", size: size))
            out.append(ChordText.items(examples.map { s in
                let role: KeyMeanings.Role = s.bank == .onset ? .onset : s.bank == .vowel ? .vowel : .coda
                return (s.text, ChordText.keys(s.keys, layout: layout), KeyboardDiagramView.color(for: role))
            }, size: size))
        }
        return out
    }

    private func wordsText() -> NSAttributedString {
        let layout = data.layout
        let size: CGFloat = 13
        var effective = data.shared.entries
        for (k, e) in data.dictionary(for: subMode).entries { effective[k] = e }
        func texts(_ keep: (TextEntry) -> Bool) -> [(KeySet, TextEntry)] {
            effective.compactMap { k, e -> (KeySet, TextEntry)? in
                if case .text(let t) = e, keep(t) { return (k, t) }
                return nil
            }.sorted { ($0.1.text.lowercased(), $0.0.count, $0.0.bits) < ($1.1.text.lowercased(), $1.0.count, $1.0.bits) }
        }
        let special = KeyboardDiagramView.color(for: .special)
        var groups: [(String, [(label: String, keys: String, color: NSColor)])] = []
        func row(_ k: KeySet, _ label: String, _ color: NSColor = special, note: String? = nil) -> (label: String, keys: String, color: NSColor) {
            (label, ChordText.keys(k, layout: layout) + (note.map { " (\($0))" } ?? ""), color)
        }
        if subMode == .english {
            groups.append(("Endings", texts { $0.kind == .suffix }.map { row($0.0, "-" + $0.1.text) }))
            groups.append(("Punctuation", texts { $0.kind == .symbol && !$0.isSnippet }.map {
                row($0.0, TypingGuideWindowController.visible($0.1.text),
                    note: [".", "?", "!"].contains($0.1.text) && !$0.1.capitalizeNext ? "no capital after" : nil)
            }))
            groups.append(("Words", texts { $0.kind == .word && !$0.isSnippet }.map { row($0.0, $0.1.text, .labelColor) }))
        } else {
            groups.append(("Symbols", texts { $0.kind == .symbol && !$0.isSnippet }.map { row($0.0, $0.1.text) }))
            groups.append(("Keywords", texts { $0.kind == .word }.map { row($0.0, $0.1.text, .labelColor) }))
            groups.append(("Snippets", texts(\.isSnippet).map { row($0.0, KeyMeanings.display(.text($0.1))) }))
        }
        let commands = effective.compactMap { k, e -> (KeySet, Command)? in
            if case .command(let c) = e { return (k, c) }
            return nil
        }.sorted { ($0.0.count, $0.0.bits) < ($1.0.count, $1.0.bits) }
        groups.append(("Commands", commands.map { row($0.0, KeyMeanings.describe($0.1)) }))

        let out = NSMutableAttributedString()
        for (title, items) in groups where !items.isEmpty {
            out.append(ChordText.heading(title, size: size))
            out.append(ChordText.items(items, size: size))
            out.append(NSAttributedString(string: "\n\n"))
        }
        return out
    }
}

