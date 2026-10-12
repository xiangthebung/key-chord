import AppKit
import KeyChordCore

enum PracticeUI {
    static let accentColor = adaptiveColor("on", light: DesignSystem.Palette.light, dark: DesignSystem.Palette.dark)
    static let pageColor = adaptiveColor("bg", light: DesignSystem.Palette.light, dark: DesignSystem.Palette.dark)
    static let surfaceColor = adaptiveColor("key", light: DesignSystem.Palette.light, dark: DesignSystem.Palette.dark)
    static let borderColor = adaptiveColor("line", light: DesignSystem.Palette.light, dark: DesignSystem.Palette.dark)
    private static let roleColors = Dictionary(uniqueKeysWithValues: KeyMeanings.Role.allCases.map {
        ($0, adaptiveColor($0.rawValue, light: DesignSystem.RolePalette.light, dark: DesignSystem.RolePalette.dark))
    })

    static func roleColor(_ role: KeyMeanings.Role) -> NSColor { roleColors[role]! }

    private static func adaptiveColor(_ token: String, light: [String: String], dark: [String: String]) -> NSColor {
        NSColor(name: NSColor.Name("KeyChord." + token)) { appearance in
            let palette = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let digits = String(palette[token]!.dropFirst())
            let full = digits.count == 3 ? digits.map { String(repeating: String($0), count: 2) }.joined() : digits
            let rgb = UInt32(full, radix: 16)!
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    static func label(_ text: String, size: CGFloat = CGFloat(DesignSystem.Typography.caption), weight: NSFont.Weight = .medium) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    static func styleButton(_ button: NSButton, primary: Bool = false, toggle: Bool = false) {
        let title = button.title, state = button.state
        let target = button.target, action = button.action
        let key = button.keyEquivalent, modifiers = button.keyEquivalentModifierMask
        let cell = PracticeButtonCell(textCell: title)
        cell.prominent = primary
        button.cell = cell
        button.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        button.title = title
        button.state = state
        button.target = target; button.action = action
        button.keyEquivalent = key; button.keyEquivalentModifierMask = modifiers
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let textWidth = (title as NSString).size(withAttributes: [.font: button.font!]).width
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(textWidth) + 32).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityLabel(title)
    }

    static func styleSegments(_ control: NSSegmentedControl) {
        control.segmentStyle = .rounded
        control.controlSize = .large
        control.font = .systemFont(ofSize: 13, weight: .medium)
        control.heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    static func row(_ views: [NSView], spacing: CGFloat = CGFloat(DesignSystem.Metrics.rowGap)) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.setHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)
        for view in views {
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            if let label = view as? NSTextField {
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(label.intrinsicContentSize.height)).isActive = true
            }
        }
        return row
    }

    static func column(_ views: [NSView], spacing: CGFloat = CGFloat(DesignSystem.Metrics.columnGap)) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        for view in views {
            if let button = view as? NSButton {
                button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        return stack
    }

    static func surface(_ view: NSView, padding: CGFloat = CGFloat(DesignSystem.Metrics.cardPadding), accented: Bool = false) -> NSBox {
        let box = PracticeSurfaceBox(accented: accented)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 12
        box.borderWidth = 1
        box.refreshContrast()
        box.contentViewMargins = .zero
        let host = NSView()
        box.contentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: box.topAnchor),
            host.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: padding),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -padding),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -padding),
        ])
        return box
    }

    static func icon(_ button: NSButton, symbol: String, label: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.iconSize)).isActive = true
        button.heightAnchor.constraint(equalToConstant: CGFloat(DesignSystem.Metrics.iconSize)).isActive = true
    }
}

private final class PracticeSurfaceBox: NSBox {
    private let accented: Bool
    init(accented: Bool) {
        self.accented = accented
        super.init(frame: .zero)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshContrast),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func refreshContrast() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        borderColor = contrast ? .labelColor : accented ? PracticeUI.accentColor.withAlphaComponent(0.25)
                                                       : PracticeUI.borderColor.withAlphaComponent(0.5)
        borderWidth = contrast ? 2 : 1
        fillColor = contrast ? .controlBackgroundColor : accented ? PracticeUI.accentColor.withAlphaComponent(0.06)
                                                                : PracticeUI.surfaceColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshContrast()
    }
}

final class PracticeDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Retains native popup keyboard navigation and accessibility, with a quieter control face.
final class PracticePopUpButton: NSPopUpButton {
    init() {
        super.init(frame: .zero, pullsDown: false)
        cell = PracticePopUpCell(textCell: "", pullsDown: false)
        font = .systemFont(ofSize: 13, weight: .medium)
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class PracticePopUpCell: NSPopUpButtonCell {
    override var cellSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return NSSize(width: width + 48, height: 38)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        PracticeUI.surfaceColor.setFill(); path.fill()
        (isHighlighted ? PracticeUI.accentColor : PracticeUI.borderColor.withAlphaComponent(0.6)).setStroke(); path.stroke()
        let text: String = (controlView as? NSPopUpButton)?.titleOfSelectedItem ?? (title ?? "")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor, .paragraphStyle: paragraph]
        (text as NSString).draw(in: NSRect(x: rect.minX + 13, y: rect.midY - 8, width: max(0, rect.width - 42), height: 18), withAttributes: attributes)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: rect.maxX - 23, y: rect.midY - 2))
        arrow.line(to: NSPoint(x: rect.maxX - 19, y: rect.midY + 2))
        arrow.line(to: NSPoint(x: rect.maxX - 15, y: rect.midY - 2))
        arrow.lineWidth = 1.5; NSColor.secondaryLabelColor.setStroke(); arrow.stroke()
    }
}

private final class PracticeButtonCell: NSButtonCell {
    var prominent = false
    override var cellSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        return NSSize(width: width + 32, height: 38)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let selected = state == .on
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let fill = prominent ? PracticeUI.accentColor : selected ? PracticeUI.accentColor.withAlphaComponent(0.15) : PracticeUI.surfaceColor
        fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? (isHighlighted ? 0.7 : 1) : 0.45)).setFill(); path.fill()
        (prominent || selected ? PracticeUI.accentColor : PracticeUI.borderColor.withAlphaComponent(0.6)).setStroke(); path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: !isEnabled ? NSColor.disabledControlTextColor : prominent ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: paragraph]
        (title as NSString).draw(in: NSRect(x: rect.minX + 10, y: rect.midY - 8, width: max(0, rect.width - 20), height: 18), withAttributes: attributes)
        if let button = controlView as? NSButton, button.window?.firstResponder === button {
            PracticeUI.accentColor.withAlphaComponent(0.5).setStroke()
            let focus = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            focus.lineWidth = 2; focus.stroke()
        }
    }
}

/// Owns the read-only text layout so viewport updates cannot omit wrapped lines.
/// Reflows first, then scrolls the active word inside its own viewport, including after a resize.
final class PracticePassageScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let passage = documentView as? PracticePassageView, contentView.bounds.width > 0 else { return }
        if abs(passage.frame.width - contentView.bounds.width) > 0.5 {
            passage.setFrameSize(NSSize(width: contentView.bounds.width, height: passage.frame.height))
        }
    }
}

final class PracticePassageView: NSView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
    let textContainerOrigin = NSPoint(x: 2, y: 10)
    var string: String { textStorage.string }
    var minimumHeight: CGFloat = 110
    var activeWordRange = NSRange(location: 0, length: 0)
    private var followingWord = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { string }

    func followActiveWord() {
        guard !followingWord, frame.width > 0 else { return }
        followingWord = true
        defer { followingWord = false }
        textContainer.containerSize = NSSize(width: max(1, frame.width - textContainerOrigin.x * 2), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = max(minimumHeight, ceil(layoutManager.usedRect(for: textContainer).maxY + textContainerOrigin.y * 2))
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
        guard activeWordRange.location < textStorage.length, let clip = enclosingScrollView?.contentView else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: activeWordRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
        let desiredY = rect.minY - max(10, (clip.bounds.height - rect.height) / 3)
        let y = max(0, min(desiredY, bounds.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: textContainerOrigin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        followActiveWord()
    }
}
