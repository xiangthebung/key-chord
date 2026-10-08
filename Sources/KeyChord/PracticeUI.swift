import AppKit
import KeyChordCore

enum PracticeUI {
    static let accentColor = adaptiveColor("on", light: DesignSystem.Palette.light, dark: DesignSystem.Palette.dark)
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
        box.cornerRadius = CGFloat(DesignSystem.Metrics.radius)
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
                                                       : NSColor.separatorColor.withAlphaComponent(0.45)
        borderWidth = contrast ? 2 : 1
        fillColor = contrast ? .controlBackgroundColor : accented ? PracticeUI.accentColor.withAlphaComponent(0.06)
                                                                : .controlBackgroundColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshContrast()
    }
}

final class PracticeDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class PracticeInputView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// Set only by explicit Return/Tab actions; pasted whitespace uses insertText and cannot earn credit.
    private(set) var structuralInput: String?
    override func insertNewline(_ sender: Any?) {
        structuralInput = "\n"
        defer { structuralInput = nil }
        super.insertNewline(sender)
    }
    override func insertTab(_ sender: Any?) {
        structuralInput = "\t"
        defer { structuralInput = nil }
        super.insertTab(sender)
    }
    var placeholder = "Type the passage here…" { didSet { needsDisplay = true } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            NSAttributedString(string: placeholder, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.placeholderTextColor,
            ]).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
        }
    }
}
