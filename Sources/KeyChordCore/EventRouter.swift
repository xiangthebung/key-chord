// Event_Router: decides for every keyboard event whether it is passed through, suppressed,
// or sent to the Chord_Engine (Req 1, 2, 3.8, 3.9, 9.7, 18.2, 18.4, 18.5, 18.8).
// Platform independent; the macOS layer converts CGEvents into RouterInput values.

public struct ModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = ModifierFlags(rawValue: 1)
    public static let control = ModifierFlags(rawValue: 2)
    public static let option = ModifierFlags(rawValue: 4)
    public static let command = ModifierFlags(rawValue: 8)
    /// Caps Lock is on (a lock state, not a held key).
    public static let capsLock = ModifierFlags(rawValue: 16)
}

public enum ModifierKey: Sendable, Equatable {
    case shift, control, option, command, capsLock, function
}

public enum RouterInput: Sendable, Equatable {
    /// Non-modifier key press. `time` is in milliseconds.
    case keyDown(code: KeyCode, isRepeat: Bool, flags: ModifierFlags, time: UInt64)
    case keyUp(code: KeyCode, flags: ModifierFlags, time: UInt64)
    case modifierDown(code: KeyCode, key: ModifierKey, time: UInt64)
    case modifierUp(code: KeyCode, key: ModifierKey, time: UInt64)
    case mouseDown(time: UInt64)
}

public enum Decision: Sendable, Equatable {
    case pass, suppress
}

public enum Mode: Sendable, Equatable {
    case normal
    case chord(SubMode)
}

/// Why chord typing is not available, for the Mode_Indicator.
public enum Availability: Sendable, Equatable {
    case available
    case missingPermission
    case secureInput
}

public enum RouterEvent: Sendable, Equatable {
    case modeChanged(Mode)
    case untranslatable
    case undoEmpty
    /// An internal error forced Normal_Mode (Req 18.8).
    case failSafe
}

public struct RouterOutput: Sendable, Equatable {
    public var decision: Decision
    public var actions: [OutputAction] = []
    public var events: [RouterEvent] = []

    public init(decision: Decision, actions: [OutputAction] = [], events: [RouterEvent] = []) {
        self.decision = decision
        self.actions = actions
        self.events = events
    }
}

public final class EventRouter {
    public let engine: ChordEngine
    public var tapTimeoutMs: UInt64

    /// The user's chosen mode. The effective mode is Normal while unavailable.
    public private(set) var selectedMode: Mode = .normal     // Req 1.1
    public private(set) var lastSubMode: SubMode
    public private(set) var permissionsGranted = true
    public private(set) var secureInput = false
    public private(set) var probeActive = false

    private var heldNonModifiers = Set<KeyCode>()
    private enum PressRoute { case passed, suppressed, engine(Int) }
    private var pressRoute: [KeyCode: PressRoute] = [:]
    private var optionPending: (code: KeyCode, time: UInt64)?
    /// Only the right Option key (code 61) toggles Chord mode; the left one behaves as a plain modifier.
    private let rightOptionCode: KeyCode = 61

    public init(data: EngineData, lastSubMode: SubMode = .english, tapTimeoutMs: UInt64 = 400) {
        self.engine = ChordEngine(data: data, subMode: lastSubMode)
        self.lastSubMode = lastSubMode
        self.tapTimeoutMs = tapTimeoutMs
    }

    public var availability: Availability {
        if !permissionsGranted { return .missingPermission }
        if secureInput { return .secureInput }
        return .available
    }

    public var effectiveMode: Mode {
        availability == .available && !probeActive ? selectedMode : .normal
    }

    /// The mode shown on the indicator (the probe does not change it).
    public var displayedMode: Mode { availability == .available ? selectedMode : .normal }

    // MARK: Event handling

    public func handle(_ input: RouterInput) -> RouterOutput {
        do {
            return try route(input)
        } catch {
            return failSafe()
        }
    }

    private func route(_ input: RouterInput) throws -> RouterOutput {
        switch input {
        case let .keyDown(code, isRepeat, flags, _):
            optionPending = nil                                        // Req 1.5
            if isRepeat {                                              // Req 3.5: same handling as the press
                switch pressRoute[code] {
                case .suppressed?, .engine?: return RouterOutput(decision: .suppress)
                default: return RouterOutput(decision: .pass)
                }
            }
            heldNonModifiers.insert(code)
            guard case .chord = effectiveMode else {
                pressRoute[code] = .passed
                return RouterOutput(decision: .pass)                   // Req 2.1
            }
            if !flags.intersection([.command, .control, .option]).isEmpty {
                // Req 2.4: shortcut, passed through and not part of a chord. The shortcut can change
                // the text around the cursor, so the context is no longer trustworthy.
                pressRoute[code] = .passed
                engine.discardChord()
                engine.contextReset()
                return RouterOutput(decision: .pass)
            }
            if let idx = engine.data.layout.indexByCode[code] {
                pressRoute[code] = .engine(idx)                        // Req 2.2
                engine.keyDown(idx, shift: flags.contains(.shift))
                return RouterOutput(decision: .suppress)
            }
            pressRoute[code] = .passed                                 // Req 2.3, 3.9, 9.7
            engine.discardChord()
            engine.contextReset()
            return RouterOutput(decision: .pass)

        case let .keyUp(code, flags, _):
            heldNonModifiers.remove(code)
            switch pressRoute.removeValue(forKey: code) {              // Req 2.5
            case .engine(let idx)?:
                var out = RouterOutput(decision: .suppress)
                // Req 9.10: Caps Lock as it is when the chord completes.
                if let r = try engine.keyUp(idx, capsLock: flags.contains(.capsLock)) { absorb(r, into: &out) }
                return out
            case .suppressed?:
                return RouterOutput(decision: .suppress)
            default:
                return RouterOutput(decision: .pass)
            }

        case let .modifierDown(code, key, time):
            if key == .option {
                if optionPending != nil {
                    optionPending = nil                                // the other Option key: not a tap
                } else if code == rightOptionCode && heldNonModifiers.isEmpty
                            && availability == .available && !probeActive {
                    optionPending = (code, time)                       // Req 1.6: only the right Option toggles
                }
            } else {
                optionPending = nil                                    // Req 1.5
            }
            switch key {
            case .shift: engine.joinPressed()                          // Req 3.6
            case .option, .command, .control: engine.discardChord()    // Req 3.8
            default: break
            }
            return RouterOutput(decision: .pass)                       // Req 1.8, 2.3

        case let .modifierUp(code, key, time):
            var out = RouterOutput(decision: .pass)
            if key == .option, let p = optionPending {
                optionPending = nil
                if p.code == code && time >= p.time && time - p.time <= tapTimeoutMs {   // Req 1.7
                    toggleChordMode(into: &out)
                }
            }
            return out

        case .mouseDown:
            optionPending = nil                                        // Req 1.5
            engine.contextReset()                                      // Req 9.7
            return RouterOutput(decision: .pass)
        }
    }

    private func absorb(_ r: EngineResult, into out: inout RouterOutput) {
        out.actions += r.actions
        switch r.signal {
        case .untranslatable?: out.events.append(.untranslatable)
        case .undoEmpty?: out.events.append(.undoEmpty)
        case nil: break
        }
        if r.modeSwitched {
            lastSubMode = engine.subMode
            selectedMode = .chord(engine.subMode)
            out.events.append(.modeChanged(effectiveMode))
        }
    }

    private func toggleChordMode(into out: inout RouterOutput) {
        if case .chord = selectedMode {
            setSelected(.normal, into: &out)                          // Req 1.3
        } else {
            setSelected(.chord(lastSubMode), into: &out)              // Req 1.2
        }
    }

    private func setSelected(_ m: Mode, into out: inout RouterOutput) {
        guard m != selectedMode else { return }
        if case .chord = m, availability != .available { return }   // Req 18.2
        selectedMode = m
        if case .chord(let s) = m {
            lastSubMode = s
            if engine.subMode != s { engine.setSubMode(s) }
        }
        engine.discardChord()                                          // Req 1.10
        engine.contextReset()
        out.events.append(.modeChanged(effectiveMode))
    }

    private func failSafe() -> RouterOutput {
        selectedMode = .normal
        engine.discardChord()
        engine.contextReset()
        optionPending = nil
        return RouterOutput(decision: .pass, events: [.failSafe, .modeChanged(.normal)])
    }

    // MARK: Platform notifications

    /// Menu: toggle Chord_Mode.
    public func toggleChordMode() -> [RouterEvent] {
        var out = RouterOutput(decision: .pass)
        toggleChordMode(into: &out)
        return out.events
    }

    /// Menu: select a sub-mode (enters Chord_Mode).
    public func selectSubMode(_ s: SubMode) -> [RouterEvent] {
        var out = RouterOutput(decision: .pass)
        if availability != .available {
            lastSubMode = s
            if engine.subMode != s { engine.setSubMode(s) }
            return []
        }
        if selectedMode == .chord(s) { return [] }
        if case .chord = selectedMode {
            selectedMode = .normal   // force a real change below
        }
        setSelected(.chord(s), into: &out)
        return out.events
    }

    public func forceNormal() -> [RouterEvent] {
        var out = RouterOutput(decision: .pass)
        setSelected(.normal, into: &out)
        return out.events
    }

    /// Frontmost application changed (Req 9.7).
    public func contextReset() {
        engine.contextReset()
    }

    /// macOS disabled the event tap and it was re-enabled (Req 2.8).
    public func tapReenabled() {
        optionPending = nil
        engine.discardChord()
        engine.contextReset()
    }

    /// Req 18.4, 18.5, 9.7. The selected mode is kept and resumes when Secure_Input turns off.
    public func setSecureInput(_ on: Bool) -> [RouterEvent] {
        guard on != secureInput else { return [] }
        secureInput = on
        optionPending = nil
        engine.discardChord()
        engine.contextReset()
        return [.modeChanged(effectiveMode)]
    }

    /// Req 18.2: while a permission is missing, stay in Normal_Mode.
    public func setPermissionsGranted(_ ok: Bool) -> [RouterEvent] {
        guard ok != permissionsGranted else { return [] }
        permissionsGranted = ok
        if !ok { selectedMode = .normal }
        engine.discardChord()
        engine.contextReset()
        return [.modeChanged(effectiveMode)]
    }

    /// Req 5.3: while the probe window has focus, no chords or Option_Taps are interpreted.
    public func setProbeActive(_ on: Bool) {
        guard on != probeActive else { return }
        probeActive = on
        optionPending = nil
        engine.discardChord()
        engine.contextReset()
    }

    /// Req 3.11: `physicallyHeld` is the set of key codes the hardware reports as down.
    public func syncPhysicalKeys(_ physicallyHeld: Set<KeyCode>) {
        heldNonModifiers.formIntersection(physicallyHeld)
        let layout = engine.data.layout
        engine.syncPhysical(held: Set(physicallyHeld.compactMap { layout.indexByCode[$0] }))
    }

    /// New data from Reload Dictionaries (Req 15.6).
    public func replaceData(_ data: EngineData) {
        engine.replaceData(data)
        // Presses already routed to the engine keep being suppressed on release (Req 2.5).
        for (code, route) in pressRoute { if case .engine = route { pressRoute[code] = .suppressed } }
    }
}
