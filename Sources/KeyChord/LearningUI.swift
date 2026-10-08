import AppKit
import KeyChordCore

/// A real table complements the drawn keyboard: VoiceOver can read each key, and arrow keys can
/// select rows. Physical labels remain first regardless of the diagram's label preference.
final class PracticeKeyboardTextView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var rows: [String] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .lineBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")))
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 4, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Physical keyboard keys, meanings, roles, and current state")
        table.setAccessibilityHelp("Use the Up and Down arrow keys to read keys. Target means press next; held means currently down.")
        documentView = table
        heightAnchor.constraint(equalToConstant: 156).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(layout: Layout, meanings: KeyMeanings?, target: Set<KeyCode>, held: Set<KeyCode>) {
        let codes = Set(layout.keys.map(\.code)).union(target).union(held).union([56, 60, 61])
        rows = KeyboardDiagramView.geometry.keys.filter { codes.contains($0.code) }.map { key in
            let value = meanings?.keys[key.code]
            let meaning = value.map { $0.label + " · " + Self.role($0.role) }
                ?? meanings.flatMap { _ in KeyMeanings.modifiers[key.code] } ?? "Physical key"
            let targetLabel = target.contains(key.code)
                ? ([56, 60].contains(key.code) && target.contains(56) && target.contains(60) ? "Target alternative: either Shift · " : "Target · ") : ""
            let state = targetLabel + (held.contains(key.code) ? "Held down" : "Released")
            return KeyboardDiagramView.physicalName(for: key.code) + ": " + meaning + ". " + state
        }
        let selected = table.selectedRow
        table.reloadData()
        if rows.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
    }
    static func role(_ role: KeyMeanings.Role) -> String {
        switch role {
        case .onset: return "start"
        case .vowel: return "vowel"
        case .coda: return "end"
        case .spell: return "spelling"
        case .special: return "action"
        case .number: return "number"
        case .space: return "joining"
        }
    }
    func focusTable() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(wrappingLabelWithString: rows[row])
        cell.font = .systemFont(ofSize: 12)
        cell.textColor = .labelColor
        cell.setAccessibilityLabel(rows[row])
        return cell
    }
}

/// A button owns its action, so rebuilt course cards never leave dangling targets.
final class PracticeActionButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke)
        bezelStyle = .rounded
        font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.label), weight: .semibold)
        heightAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.actionHeight)).isActive = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    @objc private func invoke() { handler() }
    required init?(coder: NSCoder) { fatalError() }
}

/// One large click target, with a title and a short description rather than hidden menu choices.
private final class PracticeTopicCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: CGFloat(DesignSystem.Metrics.cardPadding), dy: 0), in: controlView)
    }
}

private final class PracticeTopicButton: NSButton {
    // NSButton's cell paints its title and symbol in draw(_:). A layer-only update hides both.
    override var wantsUpdateLayer: Bool { false }
    private let handler: () -> Void
    init(title: String, detail: String, symbol: String, actionLabel: String? = nil, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        cell = PracticeTopicCell(textCell: "")
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(invoke)
        bezelStyle = .regularSquare
        isBordered = false
        alignment = .left
        wantsLayer = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.size = NSSize(width: 26, height: 26)
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleNone
        contentTintColor = PracticeUI.accentColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        let text = NSMutableAttributedString(string: title + (detail.isEmpty ? "" : "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(DesignSystem.Typography.cardTitle), weight: .semibold), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(DesignSystem.Typography.caption)), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        if let actionLabel {
            text.append(NSAttributedString(string: "\n" + actionLabel + " ›", attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(DesignSystem.Typography.caption), weight: .semibold), .foregroundColor: PracticeUI.accentColor,
                .paragraphStyle: paragraph,
            ]))
        }
        attributedTitle = text
        setAccessibilityLabel(title + ", " + detail + (actionLabel.map { ", " + $0 } ?? ""))
    }
    @objc private func invoke() { handler() }
    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignSystem.Metrics.radius)
        let surface = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (isHighlighted ? PracticeUI.accentColor.withAlphaComponent(0.15) : .controlBackgroundColor).setFill()
        surface.fill()
        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : NSColor.separatorColor.withAlphaComponent(0.55)).setStroke()
        surface.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        surface.stroke()
        super.draw(dirtyRect)
    }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Two columns on a wide window, one at phone widths. The same reading order works in both.
private final class PracticeCardGrid: NSView {
    private let cards: [NSView]
    private var columns = 1
    private let cardHeight = CGFloat(DesignSystem.Metrics.topicHeight)
    private let gap = CGFloat(DesignSystem.Metrics.cardGap)
    override var isFlipped: Bool { true }
    init(_ cards: [NSView]) {
        self.cards = cards
        super.init(frame: .zero)
        cards.forEach { addSubview($0) }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    override var intrinsicContentSize: NSSize {
        let rows = CGFloat((cards.count + columns - 1) / columns)
        return NSSize(width: NSView.noIntrinsicMetric, height: rows * cardHeight + max(0, rows - 1) * gap)
    }
    override func layout() {
        super.layout()
        let count = max(1, min(cards.count, bounds.width >= CGFloat(DesignSystem.Metrics.topicBreakpoint) ? 2 : 1))
        if columns != count {
            columns = count
            invalidateIntrinsicContentSize()
        }
        let width = max(0, (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: CGFloat(index % columns) * (width + gap),
                                y: CGFloat(index / columns) * (cardHeight + gap), width: width, height: cardHeight)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PracticeCourseOverview: NSView {
    var onLesson: ((Int) -> Void)?
    var onContinue: (() -> Void)?
    var onReview: (() -> Void)?
    var onDelayedCheck: (() -> Void)?
    private var completed = Set<String>()
    private var resume = 0
    private var dueReviewCount = 0
    private var unassisted: Set<String> = []
    private var retained: Set<String> = []
    private var dueLessonChecks = 0
    private var unit: Int?
    private var stack: NSStackView?

    init() {
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(completed: Set<String>, resume: Int, dueReviewCount: Int = 0, unassisted: Set<String> = [],
                retained: Set<String> = [], dueLessonChecks: Int = 0) {
        guard completed != self.completed || resume != self.resume || dueReviewCount != self.dueReviewCount
            || unassisted != self.unassisted || retained != self.retained || dueLessonChecks != self.dueLessonChecks else { return }
        self.completed = completed
        self.resume = resume
        self.dueReviewCount = dueReviewCount
        self.unassisted = unassisted
        self.retained = retained
        self.dueLessonChecks = dueLessonChecks
        rebuild()
    }

    func showHome() {
        unit = nil
        rebuild()
    }

    private func rebuild() {
        stack?.removeFromSuperview()
        let content: [NSView]
        if let unit {
            let section = Course.units[unit]
            let heading = PracticeUI.label(section.title, size: CGFloat(DesignSystem.Typography.title), weight: .bold)
            heading.textColor = .labelColor
            let back = PracticeActionButton("‹ All units") { [weak self] in self?.showHome() }
            back.isBordered = false
            back.alignment = .left
            let first = Course.units.prefix(unit).reduce(0) { $0 + $1.steps.count }
            let rows: [NSView] = section.steps.enumerated().map { offset, step in
                let index = first + offset
                let done = completed.contains(step.id)
                return PracticeTopicButton(title: "\(offset + 1). \(step.title)",
                                           detail: retained.contains(step.id) ? "Retained"
                                               : unassisted.contains(step.id) ? "Passed"
                                               : done ? "Practiced" : "",
                                           symbol: done ? "checkmark.circle.fill" : "play.circle") { [weak self] in
                    self?.onLesson?(index)
                }
            }
            content = [back, heading, PracticeUI.label("\(section.steps.count) short lessons"),
                       PracticeCardGrid(rows)]
        } else {
            let heading = PracticeUI.label(DesignSystem.Labels.sections["learn"]!, size: CGFloat(DesignSystem.Typography.title), weight: .bold)
            heading.textColor = .labelColor
            let step = Course.steps[resume]
            let (unit, place) = Course.position(of: resume)
            let unitName = Course.units[unit].title
            let next = PracticeUI.label(step.title, size: CGFloat(DesignSystem.Typography.title), weight: .semibold)
            next.textColor = .labelColor
            next.lineBreakMode = .byWordWrapping
            next.maximumNumberOfLines = 2
            next.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let continueButton = PracticeActionButton("Continue") { [weak self] in self?.onContinue?() }
            continueButton.bezelColor = PracticeUI.accentColor
            let due = PracticeActionButton("Review due · \(dueReviewCount) chords") { [weak self] in self?.onReview?() }
            due.isHidden = dueReviewCount == 0
            let lessonChecks = PracticeActionButton("Delayed check due · \(dueLessonChecks) lessons") { [weak self] in self?.onDelayedCheck?() }
            lessonChecks.isHidden = dueLessonChecks == 0
            let hero = PracticeUI.surface(PracticeUI.column([
                next, PracticeUI.label("\(unitName) · Lesson \(place + 1) of \(Course.units[unit].steps.count)"),
                PracticeUI.row([continueButton, PracticeUI.spacer()]), lessonChecks, due,
            ], spacing: CGFloat(DesignSystem.Metrics.rowGap)), accented: true)
            let english = Course.steps.filter { $0.mode == .english }
            let count = english.filter { completed.contains($0.id) }.count
            let progress = NSProgressIndicator()
            progress.isIndeterminate = false
            progress.style = .bar
            progress.minValue = 0
            progress.maxValue = Double(english.count)
            progress.doubleValue = Double(count)
            progress.setAccessibilityLabel("English course progress: \(count) of \(english.count) lessons practiced")
            let courseTitle = PracticeUI.label("All course units", size: 18, weight: .semibold)
            courseTitle.textColor = .labelColor
            let courseHeader = PracticeUI.row([courseTitle, PracticeUI.spacer(),
                                               PracticeUI.label("English · \(count) / \(english.count) practiced")])
            let symbols = ["waveform", "square.stack", "textformat", "text.bubble", "book.closed", "link",
                           "number", "chevron.left.forwardslash.chevron.right"]
            let cards: [NSView] = Course.units.enumerated().map { index, unit in
                let done = unit.steps.filter { completed.contains($0.id) }.count
                let optional = unit.steps.allSatisfy { $0.mode == .cpp } ? "Optional · " : ""
                return PracticeTopicButton(title: "\(index + 1). \(unit.title)",
                                           detail: "\(optional)\(unit.steps.count) lessons · \(done) practiced", symbol: symbols[index],
                                           actionLabel: "View lessons") { [weak self] in
                    self?.unit = index
                    self?.rebuild()
                }
            }
            content = [heading, hero, courseHeader,
                       progress, PracticeCardGrid(cards)]
        }
        let column = PracticeUI.column(content, spacing: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack = column
    }
}

final class PracticeLibraryView: NSView {
    var onTopic: ((Int) -> Void)?
    var onListen: (() -> Void)?
    var onWordSprint: (() -> Void)?
    init(review: NSButton, importButton: NSButton) {
        super.init(frame: .zero)
        let heading = PracticeUI.label(DesignSystem.Labels.sections["practice"]!, size: CGFloat(DesignSystem.Typography.title), weight: .bold)
        heading.textColor = .labelColor
        let symbols = ["waveform", "square.stack", "book.closed", "textformat.abc", "textformat",
                       "link", "number", "chevron.left.forwardslash.chevron.right"]
        let cards: [NSView] = Lessons.all.indices.map { index in
            let topic = Lessons.all[index]
            let button = PracticeTopicButton(title: topic.title, detail: "", symbol: symbols[index]) { [weak self] in
                self?.onTopic?(index)
            }
            button.toolTip = topic.summary
            button.setAccessibilityLabel(topic.title + ". " + topic.summary)
            return button
        }
        let listen = PracticeTopicButton(title: DesignSystem.Labels.sections["listen"]!, detail: "10 learned words",
                                         symbol: "speaker.wave.2") { [weak self] in self?.onListen?() }
        let sprint = PracticeTopicButton(title: "Word Sprint", detail: "Random words · speed and accuracy", symbol: "speedometer") {
            [weak self] in self?.onWordSprint?()
        }
        for button in [review, importButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: CGFloat(DesignSystem.Typography.label), weight: .semibold)
            button.heightAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.actionHeight)).isActive = true
        }
        let tools = PracticeUI.row([importButton, review, PracticeUI.spacer()])
        let column = PracticeUI.column([heading, tools, PracticeCardGrid([sprint, listen]), PracticeCardGrid(cards)], spacing: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The optional guide is a table, so commands and their explanations cannot run into each other.
final class PracticeKeyboardHelp: NSView {
    private var stack: NSStackView?
    func update(_ meanings: KeyMeanings, layout: Layout, style: KeyLabelStyle) {
        stack?.removeFromSuperview()
        func name(_ index: Int) -> String {
            let code = layout.keys[index].code
            return meanings.label(for: code, physical: KeyboardDiagramView.name(for: code), style: style)
        }
        func keys(_ set: KeySet) -> String { set.indices.map(name).joined(separator: " + ") }
        let roles: [(KeyMeanings.Role, String, String)] = [(.onset, "Start", "Start of a syllable"),
            (.vowel, "Vowel", "Middle of a syllable"), (.coda, "End", "End of a syllable"),
            (.spell, "Letter", "Spell one letter"), (.special, "Action", "Endings and punctuation")]
        var rows: [[NSView]] = roles.map { role, title, detail in
            let key = PracticeUI.label("●  " + title, weight: .semibold)
            key.textColor = KeyboardDiagramView.color(for: role)
            return [key, PracticeUI.label(detail, weight: .regular)]
        }
        var commands: [(String, String)] = [("Space + chord", "Join it to the word before")]
        if let spell = meanings.spellKey {
            commands.append((name(spell) + " + letter", "Spell that letter"))
            if let capital = meanings.capitalKey {
                commands.append((name(spell) + " + " + name(capital) + " + letter", "Spell a capital letter"))
            }
        }
        if let set = meanings.capitalizeNextKeys { commands.append((keys(set), "Capitalize the next word")) }
        if let set = meanings.undoKeys { commands.append((keys(set), "Undo the last chord")) }
        commands.append(("Right Option", "Turn chord typing on or off"))
        for (command, description) in commands {
            let key = NSTextField(wrappingLabelWithString: command)
            key.font = .systemFont(ofSize: 12, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: description)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            for label in [key, detail] { label.setContentCompressionResistancePriority(.required, for: .vertical) }
            rows.append([key, detail])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.xPlacement = .leading
        grid.yPlacement = .center
        grid.column(at: 0).width = 155
        let heading = PracticeUI.label("Keyboard guide", size: 16, weight: .semibold)
        heading.textColor = .labelColor
        let column = PracticeUI.column([heading, grid], spacing: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack = column
    }
}
