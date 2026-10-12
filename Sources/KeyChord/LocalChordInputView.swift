import AppKit
import KeyChordCore

/// An NSTextView receives local NSEvents through the responder chain. It never monitors another
/// window, requests a permission, posts a system event, or accepts a global output-emitter result.
class LocalChordInputView: NSTextView {
    let practice: LocalChordPractice
    var onFocus: ((Bool) -> Void)?
    var onReadinessChanged: (() -> Void)?
    var onOutput: ((LocalChordOutput) -> Void)?
    var onWillApplyOutput: ((LocalChordOutput) -> Void)?
    var onOrdinaryEdit: (() -> Void)?
    private let focusOverride: (() -> Bool)?
    private var applyingOutput = false
    /// Local practice adapters can distinguish a multi-character chord from paste or native editing.
    var isApplyingChordOutput: Bool { applyingOutput }
    private var lease = false
    private var suppressionAvailable: () -> Bool
    var placeholder = "" { didSet { needsDisplay = true } }
    /// Hidden practice sections cannot reacquire a lease through a queued responder callback.
    var allowsLocalFocus = true {
        didSet { if !allowsLocalFocus { relinquishFocus() } }
    }
    /// NSTextView's designated initializer uses the caller's text system. Keep its storage
    /// alive; it owns the layout manager and container used for native editing and Undo.
    private let localTextStorage: NSTextStorage

    init(data: EngineData, focus: (() -> Bool)? = nil, globalSuspended: @escaping () -> Bool = { true }) {
        practice = LocalChordPractice(data: data)
        focusOverride = focus
        suppressionAvailable = globalSuspended
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        localTextStorage = storage
        super.init(frame: .zero, textContainer: container)
        container.widthTracksTextView = true
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        font = .systemFont(ofSize: 28)
        textContainerInset = NSSize(width: 12, height: 14)
        backgroundColor = .textBackgroundColor
        setAccessibilityLabel("Local chord practice input")
    }
    required init?(coder: NSCoder) { fatalError() }

    var ownsLocalInput: Bool {
        allowsLocalFocus && isEditable && (focusOverride?() ?? (window?.isKeyWindow == true && window?.firstResponder === self))
    }

    /// AppController's lease callback pauses its router synchronously before any local composition.
    func refreshFocus() {
        let focused = ownsLocalInput
        let previouslyOwned = practice.ownsInput
        if focused != lease { lease = focused; onFocus?(focused) }
        practice.setFocus(focused, globalCaptureSuspended: focused && suppressionAvailable())
        if previouslyOwned != practice.ownsInput { onReadinessChanged?() }
    }

    func relinquishFocus() {
        let previouslyOwned = practice.ownsInput
        if lease { lease = false; onFocus?(false) }
        practice.setFocus(false, globalCaptureSuspended: false)
        if previouslyOwned != practice.ownsInput { onReadinessChanged?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // During the responder transition the window still points at the previous responder.
        if accepted { DispatchQueue.main.async { [weak self] in self?.refreshFocus() } }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { relinquishFocus() }
        return accepted
    }

    /// Also used by the native no-global-input checks; the caller supplies a local event value.
    @discardableResult
    func process(_ input: RouterInput) -> LocalChordOutput {
        refreshFocus()
        let output = practice.handle(input)
        onWillApplyOutput?(output)
        if !output.routed.actions.isEmpty { apply(output.routed.actions) }
        onOutput?(output)
        return output
    }

    override func keyDown(with event: NSEvent) {
        let out = process(.keyDown(code: event.keyCode, isRepeat: event.isARepeat,
                                   flags: Self.flags(event), time: EventConversion.nowMs()))
        if out.routed.decision == .pass { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        let out = process(.keyUp(code: event.keyCode, flags: Self.flags(event), time: EventConversion.nowMs()))
        if out.routed.decision == .pass { super.keyUp(with: event) }
    }
    override func flagsChanged(with event: NSEvent) {
        if let (key, down) = EventConversion.modifierChange(code: event.keyCode,
                                                          flags: UInt64(event.modifierFlags.rawValue)) {
            let input: RouterInput = down
                ? .modifierDown(code: event.keyCode, key: key, time: EventConversion.nowMs())
                : .modifierUp(code: event.keyCode, key: key, time: EventConversion.nowMs())
            _ = process(input)
        }
        super.flagsChanged(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        practice.ordinaryEdit()
        super.mouseDown(with: event)
        refreshFocus()
    }

    override func didChangeText() {
        super.didChangeText()
        if !applyingOutput { practice.ordinaryEdit(); onOrdinaryEdit?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: CGFloat(DesignSystem.Typography.practice)),
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !applyingOutput && selectedRanges != ranges { practice.ordinaryEdit() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    func clearForTask() {
        applyingOutput = true
        string = ""
        setSelectedRange(NSRange(location: 0, length: 0))
        undoManager?.removeAllActions()
        applyingOutput = false
        practice.reset()
    }

    private func apply(_ actions: [OutputAction]) {
        guard practice.ownsInput, ownsLocalInput else { return }
        applyingOutput = true
        undoManager?.beginUndoGrouping()
        for action in actions {
            switch action {
            case .insert(let text): insertText(text, replacementRange: selectedRange())
            case .deleteBackward(let count): for _ in 0..<count { deleteBackward(nil) }
            case .deleteForward(let count): for _ in 0..<count { deleteForward(nil) }
            case .moveLeft(let count): for _ in 0..<count { moveLeft(nil) }
            case .moveRight(let count): for _ in 0..<count { moveRight(nil) }
            }
        }
        undoManager?.endUndoGrouping()
        applyingOutput = false
    }

    private static func flags(_ event: NSEvent) -> ModifierFlags {
        EventConversion.flags(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
    }
}
