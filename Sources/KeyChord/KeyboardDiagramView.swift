import AppKit
import KeyChordCore

/// Physical keys forwarded to the reference overlay.
enum RawKeyEvent {
    case down(KeyCode)
    case up(KeyCode)
}

// MARK: - Keyboard diagram

/// The MacBook keyboard (`geometry`: US ANSI or Canadian French ISO). Keys to press are outlined in the accent
/// color; keys actually held are filled: green when they belong to the chord, orange when they do not. With
/// `meanings`, each key shows what it stands for (its sound, digit or job) in large type, tinted by role, with the
/// printed legend small in the corner.
final class KeyboardDiagramView: NSView {
    /// The keyboard every diagram draws and names keys by. Set on the main thread by the app controller, from the
    /// Keyboard menu or the keyboard type macOS reports; every diagram redraws when it changes. Both keyboards
    /// have the same size, so the aspect ratios below hold for either.
    static var geometry: KeyboardGeometry = .ansi {
        didSet { NotificationCenter.default.post(name: geometryDidChange, object: nil) }
    }
    static let geometryDidChange = Notification.Name("KeyChordKeyboardGeometryDidChange")

    static let aspect = KeyboardGeometry.height / KeyboardGeometry.width
    /// Height of the function row and the gap below it, in key units.
    static let functionRowHeight = 0.7
    /// Height over width without the function row.
    static let compactAspect = (KeyboardGeometry.height - functionRowHeight) / KeyboardGeometry.width

    var layout: Layout? { didSet { needsDisplay = true } }
    /// Draw Escape and the function keys. The reference overlay leaves them out to save room.
    var showsFunctionRow = true { didSet { needsDisplay = true } }
    /// Exercises emphasize the current chord; the complete colored mapping remains in reference views.
    var emphasizesCurrentChord = false { didSet { needsDisplay = true } }
    /// Fill for held keys when nothing is targeted (default: the accent color), e.g. to mark a chord that types
    /// nothing.
    var heldColor: NSColor? { didSet { needsDisplay = true } }
    var meanings: KeyMeanings? { didSet { needsDisplay = true } }
    var target = Set<KeyCode>() { didSet { if target != oldValue { needsDisplay = true } } }
    var held = Set<KeyCode>() { didSet { if held != oldValue { needsDisplay = true } } }
    /// Matrix Scan: the key to press next (drawn strongest), keys that registered, keys that stayed dark.
    var current: KeyCode? { didSet { if current != oldValue { needsDisplay = true } } }
    var passed = Set<KeyCode>() { didSet { if passed != oldValue { needsDisplay = true } } }
    var failed = Set<KeyCode>() { didSet { if failed != oldValue { needsDisplay = true } } }
    private var keyAccessibilityElements: [KeyCode: NSAccessibilityElement] = [:]

    /// The key's printed label on this keyboard, used to describe chords.
    static func name(for code: KeyCode) -> String { geometry.label(for: code) }
    static func physicalName(for code: KeyCode) -> String {
        let actions: [KeyCode: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            54: "Right Command", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock", 58: "Left Option",
            59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 63: "Function"]
        return actions[code] ?? name(for: code)
    }

    /// Key position and size in key units (1 unit = one letter key), origin top left.
    static func rect(for code: KeyCode) -> NSRect? {
        geometry.key(for: code).map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: Self.geometryDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: Settings.keyLabelsDidChange,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(geometryChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func geometryChanged() { needsDisplay = true }

    static func legend() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = .secondaryLabelColor, bold: Bool = false) {
            out.append(NSAttributedString(string: s, attributes: [
                .font: bold ? NSFont.systemFont(ofSize: 12, weight: .semibold) : font, .foregroundColor: color]))
        }
        let roles: [(KeyMeanings.Role, String)] = [(.onset, "start"), (.vowel, "vowel"),
                                                   (.coda, "end"), (.spell, "letter"), (.special, "action")]
        for (i, (role, text)) in roles.enumerated() {
            if i > 0 { add("    ") }
            add("● ", KeyboardDiagramView.color(for: role))
            add(text)
        }
        add("\nSpace + chord", .labelColor, bold: true)
        add("  joins a word    ")
        add("Right Option", .labelColor, bold: true)
        add("  turns chord typing on or off")
        return out
    }

    static func roleName(_ role: KeyMeanings.Role) -> String {
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

    /// The color of each kind of key when keys are labelled by meaning (also used for chord parts).
    static func color(for role: KeyMeanings.Role) -> NSColor {
        PracticeUI.roleColor(role)
    }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        let top = showsFunctionRow ? 0 : Self.functionRowHeight
        let unit = min(bounds.width / KeyboardGeometry.width, bounds.height / (KeyboardGeometry.height - top))
        let origin = NSPoint(x: (bounds.width - unit * KeyboardGeometry.width) / 2,
                             y: (bounds.height - unit * (KeyboardGeometry.height - top)) / 2 - top * unit)
        return Self.geometry.keys.filter { $0.y >= top }.map { key in
            let element = keyAccessibilityElements[key.code] ?? NSAccessibilityElement()
            keyAccessibilityElements[key.code] = element
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            let meaning = meanings?.keys[key.code]
            let semantic = meaning.map { $0.label + ", " + Self.roleName($0.role) }
                ?? meanings.flatMap { _ in KeyMeanings.modifiers[key.code] } ?? "physical key"
            element.setAccessibilityLabel(Self.physicalName(for: key.code) + ", " + semantic)
            var state = held.contains(key.code) ? "Held down" : "Released"
            if target.contains(key.code) {
                state += [56, 60].contains(key.code) && target.contains(56) && target.contains(60)
                    ? ", target alternative: hold either Shift" : ", target: press next"
            }
            if current == key.code { state += ", current check" }
            if passed.contains(key.code) { state += ", registered" }
            if failed.contains(key.code) { state += ", did not register" }
            element.setAccessibilityValue(state)
            element.setAccessibilityFrameInParentSpace(NSRect(x: origin.x + key.x * unit, y: origin.y + key.y * unit,
                width: key.width * unit, height: key.height * unit))
            return element
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        let top = showsFunctionRow ? 0 : Self.functionRowHeight
        let height = KeyboardGeometry.height - top
        let unit = min(bounds.width / KeyboardGeometry.width, bounds.height / height)
        guard unit > 6 else { return }
        // Without the function row, everything moves up by its height.
        let origin = NSPoint(x: ((bounds.width - unit * KeyboardGeometry.width) / 2).rounded(),
                             y: ((bounds.height - unit * height) / 2).rounded() - top * unit)
        let gap = max(2, unit * 0.08)
        let labelFont = NSFont.systemFont(ofSize: max(9, unit * 0.34), weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: max(7, unit * 0.2), weight: .regular)
        let chordKeys = Set(layout?.keys.map(\.code) ?? [])
        let geometry = Self.geometry
        let labelStyle = Settings().keyLabelStyle
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        for key in geometry.keys where key.y >= top {
            let r = NSRect(x: origin.x + key.x * unit + gap / 2, y: origin.y + key.y * unit + gap / 2,
                           width: key.width * unit - gap, height: key.height * unit - gap)
            // The ISO Return key is an L; on ANSI it is a plain key.
            let outline = key.code == KeyboardGeometry.returnCode ? geometry.returnOutline : nil
            let path = outline.map { returnPath($0, origin: origin, unit: unit, gap: gap) }
                ?? NSBezierPath(roundedRect: r, xRadius: unit * 0.1, yRadius: unit * 0.1)
            let isTarget = target.contains(key.code), isHeld = held.contains(key.code)
            let inLayout = chordKeys.contains(key.code)
            let meaning = meanings?.keys[key.code]
            // The meaning shown on the key: its sound or job, or Shift's and right Option's job while chording.
            let semantic: String? = meaning.flatMap { $0.label.isEmpty ? nil : $0.label }
                ?? (meanings == nil ? nil : KeyMeanings.modifiers[key.code])
            let shown = labelStyle == .physical || emphasizesCurrentChord && !isTarget && !isHeld ? nil : semantic
            let roleColor: NSColor? = semantic == nil ? nil : contrast ? .labelColor
                : emphasizesCurrentChord ? (isTarget || isHeld ? PracticeUI.accentColor : .secondaryLabelColor)
                : meaning.map { Self.color(for: $0.role) } ?? .labelColor

            var fill: NSColor
            var stroke: NSColor
            var lineWidth: CGFloat = 1
            var text: NSColor = inLayout || key.small ? .labelColor : .secondaryLabelColor
            switch (isHeld, isTarget) {
            case (true, true):
                fill = emphasizesCurrentChord ? PracticeUI.accentColor : .systemGreen; stroke = fill; text = .white
            case (true, false):
                fill = target.isEmpty ? heldColor ?? PracticeUI.accentColor : .systemOrange; stroke = fill; text = .white
            case (false, true):
                fill = PracticeUI.accentColor.withAlphaComponent(0.12); stroke = PracticeUI.accentColor; lineWidth = 2.5
            case (false, false):
                if emphasizesCurrentChord {
                    fill = .controlBackgroundColor; stroke = .separatorColor
                } else if let roleColor, meaning != nil {
                    fill = roleColor.withAlphaComponent(0.08); stroke = roleColor.withAlphaComponent(0.22)
                } else {
                    fill = NSColor.labelColor.withAlphaComponent(inLayout ? 0.09 : 0.035); stroke = .separatorColor
                }
            }
            if !isHeld {
                if failed.contains(key.code) {
                    fill = NSColor.systemRed.withAlphaComponent(0.3); stroke = .systemRed; lineWidth = 1.5
                } else if passed.contains(key.code) {
                    fill = NSColor.systemGreen.withAlphaComponent(0.3); stroke = .systemGreen; lineWidth = 1
                }
                if current == key.code {
                    fill = NSColor.controlAccentColor.withAlphaComponent(0.55); stroke = .controlAccentColor
                    lineWidth = 3.5; text = .white
                }
            }
            if contrast {
                fill = isHeld ? .labelColor : .controlBackgroundColor
                stroke = .labelColor
                text = isHeld ? .controlBackgroundColor : .labelColor
                lineWidth = isTarget || isHeld || current == key.code ? 3.5 : 1.5
            }
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

            let labelRect = outline != nil ? NSRect(x: r.minX, y: r.minY, width: r.width, height: unit - gap) : r
            let cue = isHeld ? "↓" : failed.contains(key.code) ? "×" : passed.contains(key.code) ? "✓" : isTarget ? "○" : ""
            if !cue.isEmpty {
                let marker = NSAttributedString(string: cue, attributes: [.font: smallFont, .foregroundColor: text])
                marker.draw(at: NSPoint(x: labelRect.maxX - marker.size().width - 2, y: labelRect.minY + 1))
            }

            if let shown, labelStyle == .both {
                let main = NSAttributedString(string: key.label, attributes: [.font: key.small ? smallFont : labelFont,
                                                                              .foregroundColor: text])
                let ms = main.size()
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.midY - ms.height * 0.8))
                if unit >= 22 {
                    let secondary = NSAttributedString(string: shown, attributes: [.font: smallFont,
                        .foregroundColor: isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white.withAlphaComponent(0.9)) : roleColor ?? .secondaryLabelColor])
                    let ss = secondary.size()
                    secondary.draw(at: NSPoint(x: labelRect.midX - ss.width / 2, y: labelRect.maxY - ss.height - unit * 0.05))
                }
                continue
            }
            if let shown {
                // Meaning in large type, the printed legend small in the corner, and what the key does alone
                // (when that is something else) small at the bottom.
                let bigColor = isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white) : roleColor ?? text
                let scale: CGFloat = shown.count <= 2 ? 1 : shown.count <= 4 ? 0.74 : 0.6
                let big = NSAttributedString(string: shown, attributes: [
                    .font: NSFont.systemFont(ofSize: labelFont.pointSize * scale, weight: .semibold),
                    .foregroundColor: bigColor])
                let bs = big.size()
                let alone = unit >= 30 ? meaning?.alone : nil
                let y = alone == nil ? labelRect.midY - bs.height / 2 : labelRect.midY - bs.height * 0.62
                big.draw(at: NSPoint(x: labelRect.midX - bs.width / 2, y: y))
                let dim = isHeld ? (contrast ? NSColor.controlBackgroundColor : NSColor.white.withAlphaComponent(0.85)) : NSColor.secondaryLabelColor
                if labelStyle == .both, !key.label.isEmpty, unit >= 22 {
                    let corner = NSAttributedString(string: key.label, attributes: [.font: smallFont, .foregroundColor: dim])
                    corner.draw(at: NSPoint(x: labelRect.minX + unit * 0.08, y: labelRect.minY + unit * 0.04))
                }
                if let alone {
                    let a = NSAttributedString(string: alone, attributes: [.font: smallFont, .foregroundColor: dim])
                    let s = a.size()
                    a.draw(at: NSPoint(x: labelRect.midX - s.width / 2, y: labelRect.maxY - s.height - unit * 0.05))
                }
                continue
            }

            guard !key.label.isEmpty else { continue }
            let main = NSAttributedString(string: key.label, attributes: [.font: key.small ? smallFont : labelFont,
                                                                          .foregroundColor: text])
            let ms = main.size()
            if let shifted = key.shifted, unit >= 26 {
                let sub = NSAttributedString(string: shifted, attributes: [.font: smallFont, .foregroundColor: text.withAlphaComponent(0.7)])
                let ss = sub.size()
                sub.draw(at: NSPoint(x: labelRect.midX - ss.width / 2, y: labelRect.minY + labelRect.height * 0.08))
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.maxY - ms.height - labelRect.height * 0.1))
            } else {
                main.draw(at: NSPoint(x: labelRect.midX - ms.width / 2, y: labelRect.midY - ms.height / 2))
            }
        }
    }

    /// The ISO Return key: 1 unit wide on the Q row, 0.75 unit on the A row.
    private func returnPath(_ outline: [(x: Double, y: Double)], origin: NSPoint, unit: CGFloat, gap: CGFloat) -> NSBezierPath {
        let g = gap / 2
        let pts = outline.map { NSPoint(x: origin.x + $0.x * unit, y: origin.y + $0.y * unit) }
        // Inset each corner toward the inside of the L by half the gap.
        let insets: [(CGFloat, CGFloat)] = [(g, g), (-g, g), (-g, -g), (g, -g), (g, -g), (g, -g)]
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = NSPoint(x: p.x + insets[i].0, y: p.y + insets[i].1)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
