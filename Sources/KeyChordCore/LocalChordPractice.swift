// Local first-chord input. Uses the same router and engine as typing in other apps, but has
// no event tap, output emitter, permission checks, clocks, or storage of its own.

public struct LocalChordAttempt: Equatable, Sendable {
    public let keys: KeySet
    public let actions: [OutputAction]
    public let signal: EngineSignal?
    public let wasUndo: Bool

    public init(keys: KeySet, actions: [OutputAction], signal: EngineSignal?, wasUndo: Bool) {
        self.keys = keys
        self.actions = actions
        self.signal = signal
        self.wasUndo = wasUndo
    }

    /// Insertion from one completed physical chord, without an ordinary-input prefix or suffix.
    public var insertedText: String? {
        guard signal == nil, !actions.isEmpty else { return nil }
        var text = ""
        for action in actions {
            guard case .insert(let value) = action else { return nil }
            text += value
        }
        return text
    }

    /// These are differences in captured events, not a diagnosis of a keyboard failure.
    public func capturedDifference(from expected: KeySet) -> (notCaptured: KeySet, extraCaptured: KeySet) {
        (expected.subtracting(keys), keys.subtracting(expected))
    }
}

public struct LocalChordOutput: Equatable, Sendable {
    public let routed: RouterOutput
    public let attempt: LocalChordAttempt?
    public init(routed: RouterOutput, attempt: LocalChordAttempt? = nil) {
        self.routed = routed
        self.attempt = attempt
    }
}

/// The owner must hold a focus lease and suspend global interception before passing local events.
/// Losing either lease discards an unfinished chord and its undo context. Key-up events cannot then
/// emit abandoned output, and local/global engines can never both handle the same owned event.
public final class LocalChordPractice {
    private var router: EventRouter
    private let data: EngineData
    private var captured = KeySet()
    private var wantsChord = true
    public private(set) var focused = false
    public private(set) var globalCaptureSuspended = false

    public init(data: EngineData) {
        self.data = data
        router = EventRouter(data: data)
    }

    public var ownsInput: Bool { focused && globalCaptureSuspended }
    public var chordEnabled: Bool { ownsInput && router.effectiveMode == .chord(.english) }
    public var heldKeys: KeySet { KeySet(router.engine.heldChordKeys) }
    public var capturedKeys: KeySet { captured }
    public var undoDepth: Int { router.engine.undoDepth }

    public func setFocus(_ focused: Bool, globalCaptureSuspended: Bool) {
        let previouslyOwned = ownsInput
        self.focused = focused
        self.globalCaptureSuspended = globalCaptureSuspended
        guard ownsInput != previouslyOwned else { return }
        // A fresh router also forgets per-press routing and pending Option taps.
        router = EventRouter(data: data)
        captured = KeySet()
        if ownsInput && wantsChord { _ = router.selectSubMode(.english) }
    }

    public func setChordEnabled(_ enabled: Bool) {
        wantsChord = enabled
        captured = KeySet()
        if ownsInput {
            _ = enabled ? router.selectSubMode(.english) : router.forceNormal()
        }
    }

    /// Reset after a correction, paste, native Undo, or cursor move. Ordinary edits remain fully
    /// available through NSTextView; only the engine's no-longer-known context is forgotten.
    public func ordinaryEdit() {
        router.tapReenabled()
        captured = KeySet()
    }

    /// A local exercise may restore the planner's spacing after an ordinary correction or refocus.
    /// This changes output context without changing the held keys or the chord Undo stack.
    public func restoreContext(_ context: EngineContext) {
        router.engine.restore(context)
    }

    public func reset() {
        router = EventRouter(data: data)
        captured = KeySet()
        if ownsInput && wantsChord { _ = router.selectSubMode(.english) }
    }

    public func handle(_ input: RouterInput) -> LocalChordOutput {
        guard ownsInput else { return LocalChordOutput(routed: RouterOutput(decision: .pass)) }
        let wasInProgress = router.engine.chordInProgress
        let beforeMode = router.engine.subMode
        var output = router.handle(input)
        var attempt: LocalChordAttempt?

        switch input {
        case let .keyDown(code, isRepeat, _, _):
            if !isRepeat, output.decision == .suppress, router.engine.chordInProgress,
               let index = data.layout.indexByCode[code] { captured.insert(index) }
            if !router.engine.chordInProgress { captured = KeySet() }
        case .keyUp:
            if wasInProgress, output.decision == .suppress, !router.engine.chordInProgress, !captured.isEmpty {
                let entry = data.dictionary(for: beforeMode)[captured] ?? data.shared[captured]
                let signal: EngineSignal? = output.events.contains(.untranslatable) ? .untranslatable
                    : output.events.contains(.undoEmpty) ? .undoEmpty : nil
                attempt = LocalChordAttempt(keys: captured, actions: output.actions, signal: signal,
                                            wasUndo: entry == .command(.undo))
                captured = KeySet()
            }
        case .modifierDown, .modifierUp, .mouseDown:
            if !router.engine.chordInProgress { captured = KeySet() }
        }
        // Onboarding stays in English. A user-entered mode-switch chord stops local chording
        // rather than silently changing the lesson's mapping.
        if router.engine.subMode != .english {
            // forceNormal alone retains lastSubMode=C++, making every subsequent right Option
            // tap re-enter the rejected mode. Start with English selected for the next local tap.
            router = EventRouter(data: data, lastSubMode: .english)
            wantsChord = false
            output.events.removeAll { if case .modeChanged = $0 { return true }; return false }
            output.events.append(.modeChanged(.normal))
        } else {
            wantsChord = router.selectedMode == .chord(.english)
        }
        return LocalChordOutput(routed: output, attempt: attempt)
    }
}

public enum FirstChordStage: String, Sendable, CaseIterable {
    case see, tryIt, recover, recall, finished
}

/// A demonstrated single chord is replayed by TypingPlanner against the current files and limits.
/// An edited mapping may therefore change the printed keys or make this short sandbox unavailable.
public struct FirstChordRecipe: Equatable, Sendable {
    public let word: String
    public let keys: KeySet
    public let shift: Bool
    public let parts: [TypingStep.Part]

    public init?(word: String, data: EngineData, rolloverLimit: Int = 6,
                 usable: @escaping (KeySet) -> Bool = { _ in true }) {
        let guide = TypingPlanner(data: data, mode: .english, rolloverLimit: rolloverLimit, usable: usable).plan(word)
        guard guide.steps.count == 1, let step = guide.steps.first,
              case let .chord(names, shift) = step.action, step.output == word,
              let keys = data.layout.keySet(names: names) else { return nil }
        self.word = word
        self.keys = keys
        self.shift = shift
        parts = step.parts
    }
}

public enum OnboardingLaunch: Equatable, Sendable {
    case begin, resume(FirstChordStage), skip

    public static func decide(savedStage: FirstChordStage?, dismissed: Bool, legacyInstallation: Bool) -> Self {
        if dismissed || savedStage == .finished { return .skip }
        if let savedStage { return .resume(savedStage) }
        return legacyInstallation ? .skip : .begin
    }
}

/// A short See → Try → Undo → Recall sequence; immediate recall does not establish delayed retention.
/// Completion is based on a released physical chord and the actual resulting local field text.
public struct FirstChordJourney: Equatable, Sendable {
    public enum Recovery: Equatable, Sendable { case makeMistake, undoMistake, repair }
    public private(set) var stage: FirstChordStage
    public private(set) var wordIndex = 0
    public private(set) var recovery: Recovery = .makeMistake
    public private(set) var recallUsedHint = false
    public static let words = KeyChordPresentation.guidedWords

    public init(stage: FirstChordStage = .see) { self.stage = stage }
    public var target: String? {
        KeyChordPresentation.firstChordState(stage: stage, wordIndex: wordIndex, recovery: recovery).target
    }

    public mutating func startTrying() {
        apply(KeyChordPresentation.nextFirstChordState(stage: .see)!)
    }
    public mutating func startRecall() {
        apply(KeyChordPresentation.firstChordState(stage: .recall))
        recallUsedHint = false
    }
    public mutating func revealHint() { if stage == .recall { recallUsedHint = true } }
    public mutating func restartRecovery() { recovery = .makeMistake }

    /// Returns true only when the current task was fulfilled; the view then clears for the next task.
    public mutating func observe(_ attempt: LocalChordAttempt, resultingText: String) -> Bool {
        let state = KeyChordPresentation.firstChordState(stage: stage, wordIndex: wordIndex, recovery: recovery)
        switch state.completion {
        case "physicalUndo":
            guard attempt.wasUndo, attempt.signal == nil, !attempt.actions.isEmpty, resultingText.isEmpty else { return false }
        case "physicalWord":
            guard let target = state.target, attempt.insertedText == target, resultingText == target else { return false }
        default: return false
        }
        guard let next = KeyChordPresentation.nextFirstChordState(stage: stage, wordIndex: wordIndex, recovery: recovery) else { return false }
        if stage != .recall && next.stage == .recall { recallUsedHint = false }
        apply(next)
        return true
    }

    private mutating func apply(_ state: FirstChordFlowState) {
        stage = state.stage
        wordIndex = state.wordIndex
        recovery = state.recovery
    }
}
