import AppKit
import KeyChordCore

/// A bounded, searchable course list. Unit headings replace repeated prefixes in a giant menu.
final class LessonBrowserView: NSView, NSSearchFieldDelegate {
    var onSelect: ((Int) -> Void)?
    private let language = NSSegmentedControl(labels: ["English", "C++"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let progressLabel = PracticeUI.label("", size: 12)
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private var selectedIndex = 0
    private var completed: Set<String> = []
    private var lessonButtons: [Int: NSButton] = [:]
    private var shouldRevealCurrentLesson = true

    init(selectedIndex: Int, completed: Set<String>) {
        super.init(frame: .zero)
        let title = PracticeUI.label("Course", size: 18, weight: .semibold)
        title.textColor = .labelColor
        language.target = self; language.action = #selector(languageChanged)
        language.setAccessibilityLabel("Lesson language")
        PracticeUI.styleSegments(language)
        search.placeholderString = "Find a lesson"
        search.font = .systemFont(ofSize: 13)
        search.controlSize = .large
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.setAccessibilityLabel("Find a lesson")
        search.heightAnchor.constraint(equalToConstant: 34).isActive = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = PracticeDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        document.addSubview(rows)
        let header = PracticeUI.column([title, language, search, progressLabel], spacing: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header); addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        reload(selectedIndex: selectedIndex, completed: completed)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(selectedIndex: Int, completed: Set<String>) {
        let changedLanguage = Course.steps[self.selectedIndex].mode != Course.steps[selectedIndex].mode
        self.selectedIndex = selectedIndex; self.completed = completed
        language.selectedSegment = Course.steps[selectedIndex].mode == .english ? 0 : 1
        if changedLanguage { search.stringValue = "" }
        rebuildRows()
        shouldRevealCurrentLesson = true
    }

    private func rebuildRows() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        lessonButtons.removeAll()
        let mode: SubMode = language.selectedSegment == 0 ? .english : .cpp
        let all = Course.steps.indices.filter { Course.steps[$0].mode == mode }
        progressLabel.stringValue = "\(all.filter { completed.contains(Course.steps[$0].id) }.count) of \(all.count) lessons practiced"
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var unitShown: Int?
        for index in all {
            let step = Course.steps[index], placement = Course.position(of: index)
            let unit = Course.units[placement.unit].title
            guard query.isEmpty || (unit + " " + step.title).localizedCaseInsensitiveContains(query) else { continue }
            if unitShown != placement.unit {
                let label = PracticeUI.label(unit.uppercased(), size: 10, weight: .semibold)
                let header = PracticeUI.column([label], spacing: 0)
                header.edgeInsets = NSEdgeInsets(top: unitShown == nil ? 0 : 16, left: 10, bottom: 6, right: 0)
                append(header)
                unitShown = placement.unit
            }
            let button = NSButton(title: step.title, target: self, action: #selector(selectLesson(_:)))
            let cell = LessonRowCell(textCell: step.title)
            cell.completed = completed.contains(step.id)
            cell.number = placement.step + 1
            button.cell = cell
            button.title = step.title; button.target = self; button.action = #selector(selectLesson(_:))
            button.setButtonType(.momentaryPushIn)
            button.tag = index; button.state = index == selectedIndex ? .on : .off
            button.toolTip = unit + " · " + step.title
            button.setAccessibilityLabel(step.title + (cell.completed ? ", practiced" : "") + (index == selectedIndex ? ", current lesson" : ""))
            button.heightAnchor.constraint(equalToConstant: 60).isActive = true
            append(button); lessonButtons[index] = button
        }
        if lessonButtons.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No matching lessons. Try another search.")
            empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
            append(empty)
        }
    }
    private func append(_ view: NSView) {
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    func revealCurrentLesson() {
        layoutSubtreeIfNeeded()
        guard let document = scroll.documentView, let button = lessonButtons[selectedIndex] else { return }
        document.layoutSubtreeIfNeeded()
        let rect = button.convert(button.bounds, to: document)
        let clip = scroll.contentView
        let y = max(0, min(rect.midY - clip.bounds.height / 2, document.bounds.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
    }
    override func layout() {
        super.layout()
        if shouldRevealCurrentLesson, scroll.contentView.bounds.height > 0, scroll.contentView.bounds.width > 0,
           lessonButtons[selectedIndex] != nil {
            shouldRevealCurrentLesson = false
            DispatchQueue.main.async { [weak self] in self?.revealCurrentLesson() }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        shouldRevealCurrentLesson = false
        rebuildRows()
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func selectLesson(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func languageChanged() {
        search.stringValue = ""
        let mode: SubMode = language.selectedSegment == 0 ? .english : .cpp
        if let index = Course.steps.firstIndex(where: { $0.mode == mode }) { onSelect?(index) }
    }
}

private final class LessonRowCell: NSButtonCell {
    var completed = false
    var number = 1
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let rect = cellFrame.insetBy(dx: 1, dy: 1)
        let selected = state == .on
        if selected || isHighlighted {
            PracticeUI.accentColor.withAlphaComponent(selected ? 0.15 : 0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        let badgeRect = NSRect(x: rect.minX + 9, y: rect.midY - 11, width: 22, height: 22)
        let badge = NSBezierPath(ovalIn: badgeRect)
        (completed ? PracticeUI.accentColor.withAlphaComponent(0.15) : NSColor.secondaryLabelColor.withAlphaComponent(0.08)).setFill(); badge.fill()
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        ((completed ? "✓" : String(number)) as NSString).draw(in: badgeRect.offsetBy(dx: 0, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: completed ? PracticeUI.accentColor : NSColor.secondaryLabelColor, .paragraphStyle: centered])
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let width = max(0, rect.width - 54)
        let size = (title as NSString).boundingRect(with: NSSize(width: width, height: 42), options: [.usesLineFragmentOrigin], attributes: attributes).size
        (title as NSString).draw(in: NSRect(x: rect.minX + 42, y: rect.midY - min(42, size.height) / 2, width: width, height: min(42, size.height)), withAttributes: attributes)
        if let button = controlView as? NSButton, button.window?.firstResponder === button {
            PracticeUI.accentColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).stroke()
        }
    }
}
