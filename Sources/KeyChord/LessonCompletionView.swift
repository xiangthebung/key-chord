import AppKit

/// A completion dialog attached to the viewport, so it stays centered even in a scrolled lesson.
final class LessonCompletionView: NSView {
    var onContinue: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
    let continueButton: NSButton
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)
    private let closeButton = NSButton()

    init(lesson: String, language: String, completed: Int, total: Int, nextTitle: String?, nextUnit: String?) {
        continueButton = NSButton(title: nextTitle == nil ? "Back to course" : "Next lesson", target: nil, action: nil)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("Lesson complete")
        setAccessibilityModal(true)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Completed")
        check.contentTintColor = .systemGreen
        check.imageScaling = .scaleProportionallyUpOrDown
        check.widthAnchor.constraint(equalToConstant: 56).isActive = true
        check.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let badge = NSView()
        check.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(check)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 56),
            check.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        let title = PracticeUI.label(completed == total ? "Course complete!" : "Lesson complete!", size: 26, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: lesson)
        detail.font = .systemFont(ofSize: 15, weight: .medium)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let count = PracticeUI.label("\(completed) of \(total) \(language) lessons practiced", size: 12)
        count.alignment = .center
        let progress = LessonProgressView()
        progress.fraction = total == 0 ? 0 : Double(completed) / Double(total)
        progress.heightAnchor.constraint(equalToConstant: 6).isActive = true
        progress.setAccessibilityLabel("\(language) course progress")
        let nextLabel = PracticeUI.label(nextTitle == nil ? "KEEP PRACTICING" : "UP NEXT", size: 10, weight: .semibold)
        let next = NSTextField(wrappingLabelWithString: nextTitle ?? "You've reached the end of the \(language) course.")
        next.font = .systemFont(ofSize: 17, weight: .semibold)
        next.textColor = .labelColor
        let unit = PracticeUI.label(nextUnit ?? "Revisit any lesson from the course browser.", size: 12)
        let recommendation = PracticeUI.surface(PracticeUI.column([nextLabel, next, unit], spacing: 8), padding: 16, accented: true)

        continueButton.target = self; continueButton.action = #selector(continueLesson)
        continueButton.keyEquivalent = "\r"; continueButton.keyEquivalentModifierMask = []
        continueButton.toolTip = nextTitle == nil ? "Back to course · Return" : "Next lesson · Return or ⌘Return"
        retryButton.target = self; retryButton.action = #selector(tryAgain)
        retryButton.keyEquivalent = "r"; retryButton.keyEquivalentModifierMask = [.command]
        retryButton.toolTip = "Restart this lesson · ⌘R"
        PracticeUI.styleButton(continueButton, primary: true)
        PracticeUI.styleButton(retryButton)
        closeButton.target = self; closeButton.action = #selector(dismiss)
        closeButton.keyEquivalent = "\u{1b}"; closeButton.keyEquivalentModifierMask = []
        PracticeUI.icon(closeButton, symbol: "xmark", label: "Close results · Escape")
        let actions = PracticeUI.row([retryButton, PracticeUI.spacer(), continueButton])
        let column = PracticeUI.column([
            badge,
            title, detail, PracticeUI.column([count, progress], spacing: 10), recommendation, actions
        ], spacing: 18)
        let card = PracticeUI.surface(column, padding: 28)
        card.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.addSubview(closeButton)
        let width = card.widthAnchor.constraint(equalToConstant: 460)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width, card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)
        ])
        // Keep Tab and Shift-Tab within the dialog while the underlying input is read-only.
        continueButton.nextKeyView = retryButton
        retryButton.nextKeyView = closeButton
        closeButton.nextKeyView = continueButton
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    @objc private func continueLesson() { onContinue?() }
    @objc private func tryAgain() { onRetry?() }
    @objc private func dismiss() { onDismiss?() }
}
