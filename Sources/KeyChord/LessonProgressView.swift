import AppKit

/// A quiet, determinate lesson bar that uses the same accent as the course controls.
final class LessonProgressView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityValue() -> Any? { min(100, max(0, fraction * 100)) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 100 }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let amount = min(1, max(0, fraction))
        guard amount > 0 else { return }
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * amount, height: bounds.height)
        PracticeUI.accentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
