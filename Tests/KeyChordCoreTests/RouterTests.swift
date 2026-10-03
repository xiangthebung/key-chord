import Testing
@testable import KeyChordCore

let LOPT: KeyCode = 58, ROPT: KeyCode = 61, LSHIFT: KeyCode = 56, LCMD: KeyCode = 55
let codeT: KeyCode = 17, codeE: KeyCode = 14, codeB: KeyCode = 11, codeReturn: KeyCode = 36

final class RouterHarness {
    let router: EventRouter
    var time: UInt64 = 1000
    var buffer = TextBuffer()
    var events: [RouterEvent] = []

    init(sub: SubMode = .english) { router = EventRouter(data: defaults, lastSubMode: sub) }

    @discardableResult
    func send(_ i: RouterInput) -> Decision {
        let o = router.handle(i)
        try? buffer.apply(o.actions)
        events += o.events
        return o.decision
    }

    func tick(_ ms: UInt64 = 50) { time += ms }

    func optionTap(_ code: KeyCode = ROPT, hold: UInt64 = 100) {
        send(.modifierDown(code: code, key: .option, time: time))
        tick(hold)
        send(.modifierUp(code: code, key: .option, time: time))
        tick()
    }

    @discardableResult
    func down(_ c: KeyCode, _ f: ModifierFlags = []) -> Decision { tick(5); return send(.keyDown(code: c, isRepeat: false, flags: f, time: time)) }
    @discardableResult
    func up(_ c: KeyCode, _ f: ModifierFlags = []) -> Decision { tick(5); return send(.keyUp(code: c, flags: f, time: time)) }

    func chord(_ codes: [KeyCode]) {
        for c in codes { down(c) }
        for c in codes { up(c) }
    }
}

@Suite("Event router")
struct RouterTests {
    @Test("Req 1.1 - 1.4: only the right Option tap toggles")
    func optionTap() {
        let h = RouterHarness()
        #expect(h.router.effectiveMode == .normal)
        h.optionTap(LOPT)                                                // left Option: no toggle
        #expect(h.router.effectiveMode == .normal)
        h.optionTap(ROPT)
        #expect(h.router.effectiveMode == .chord(.english))
        #expect(h.events.last == .modeChanged(.chord(.english)))
        h.optionTap(LOPT)                                                // still no toggle from left
        #expect(h.router.effectiveMode == .chord(.english))
        h.optionTap(ROPT)
        #expect(h.router.effectiveMode == .normal)
    }

    @Test("Req 1.5 - 1.7: not a tap")
    func notTaps() {
        let h = RouterHarness()
        h.optionTap(hold: 401)                                           // too long
        #expect(h.router.effectiveMode == .normal)

        h.send(.modifierDown(code: ROPT, key: .option, time: h.time))    // key pressed in between
        h.down(codeT, [.option]); h.up(codeT, [.option])
        h.send(.modifierUp(code: ROPT, key: .option, time: h.time))
        #expect(h.router.effectiveMode == .normal)

        h.send(.modifierDown(code: ROPT, key: .option, time: h.time))    // another modifier
        h.send(.modifierDown(code: LCMD, key: .command, time: h.time))
        h.send(.modifierUp(code: LCMD, key: .command, time: h.time))
        h.send(.modifierUp(code: ROPT, key: .option, time: h.time))
        #expect(h.router.effectiveMode == .normal)

        h.send(.modifierDown(code: ROPT, key: .option, time: h.time))    // both Option keys
        h.send(.modifierDown(code: LOPT, key: .option, time: h.time))
        h.send(.modifierUp(code: LOPT, key: .option, time: h.time))
        h.send(.modifierUp(code: ROPT, key: .option, time: h.time))
        #expect(h.router.effectiveMode == .normal)

        h.send(.modifierDown(code: ROPT, key: .option, time: h.time))    // mouse button
        h.send(.mouseDown(time: h.time))
        h.send(.modifierUp(code: ROPT, key: .option, time: h.time))
        #expect(h.router.effectiveMode == .normal)

        h.down(codeT)                                                    // key held when Option pressed
        h.optionTap()
        h.up(codeT)
        #expect(h.router.effectiveMode == .normal)

        h.optionTap(hold: 400)                                           // exactly the timeout still counts
        #expect(h.router.effectiveMode == .chord(.english))
    }

    @Test("Req 1.8: Option events always pass")
    func optionPasses() {
        let h = RouterHarness()
        #expect(h.send(.modifierDown(code: LOPT, key: .option, time: 0)) == .pass)
        #expect(h.send(.modifierUp(code: LOPT, key: .option, time: 10)) == .pass)
        #expect(h.send(.modifierDown(code: LOPT, key: .option, time: 20)) == .pass)
        #expect(h.send(.modifierUp(code: LOPT, key: .option, time: 30)) == .pass)
    }

    @Test("Req 2.2, 2.3, 16: chord keys suppressed and translated, others pass")
    func chordMode() {
        let h = RouterHarness()
        h.optionTap()
        #expect(h.down(codeT) == .suppress)
        #expect(h.down(codeE) == .suppress)
        #expect(h.send(.keyDown(code: codeE, isRepeat: true, flags: [], time: h.time)) == .suppress)
        #expect(h.down(codeB) == .suppress)
        h.up(codeT); h.up(codeE); h.up(codeB)
        #expect(h.buffer.text == "the")
        #expect(h.down(codeReturn) == .pass)     // pass-through key
        #expect(h.up(codeReturn) == .pass)
        h.chord([codeT, codeE, codeB])
        #expect(h.buffer.text == "thethe")       // Context_Reset after Return: no leading space
    }

    @Test("Req 2.4, 3.8: shortcuts pass through and discard the chord")
    func shortcuts() {
        let h = RouterHarness()
        h.optionTap()
        #expect(h.down(codeT, [.command]) == .pass)
        #expect(h.up(codeT, [.command]) == .pass)
        h.down(codeT)
        h.send(.modifierDown(code: LCMD, key: .command, time: h.time))
        h.send(.modifierUp(code: LCMD, key: .command, time: h.time))
        #expect(h.up(codeT) == .suppress)
        #expect(h.buffer.text == "")
    }

    @Test("Req 3.6: Shift sets Join")
    func shiftJoin() {
        let h = RouterHarness()
        h.optionTap()
        h.chord([codeT, codeE, codeB])
        h.down(codeT)
        h.send(.modifierDown(code: LSHIFT, key: .shift, time: h.time))
        h.down(codeE); h.down(codeB)
        h.send(.modifierUp(code: LSHIFT, key: .shift, time: h.time))
        h.up(codeT); h.up(codeE); h.up(codeB)
        #expect(h.buffer.text == "thethe")
    }

    @Test("Req 9.10: Caps Lock as it is when the chord completes")
    func capsLock() {
        let h = RouterHarness()
        h.optionTap()
        for c in [codeT, codeE, codeB] { h.down(c, [.capsLock]) }
        for c in [codeT, codeE, codeB] { h.up(c, [.capsLock]) }
        h.chord([codeT, codeE, codeB])                                    // Caps Lock off
        #expect(h.buffer.text == "THE the")
        h.down(codeT)
        #expect(h.send(.modifierDown(code: 57, key: .capsLock, time: h.time)) == .pass)   // turned on mid-chord
        h.down(codeE); h.down(codeB)
        for c in [codeT, codeE, codeB] { h.up(c, [.capsLock]) }
        #expect(h.buffer.text == "THE the THE")
    }

    @Test("Req 3.6, 6.2: the space bar joins when held with a chord and types a space alone")
    func spaceBarJoins() {
        let h = RouterHarness()
        h.optionTap()
        let space: KeyCode = 49
        h.chord([codeT, codeE, codeB])
        #expect(h.down(space) == .suppress)                           // thumb first
        h.down(codeT); h.down(codeE); h.down(codeB)
        h.up(codeT); h.up(space); h.up(codeE); h.up(codeB)
        h.down(codeT); h.down(codeE); h.down(codeB); h.down(space)   // thumb last
        h.up(space); h.up(codeT); h.up(codeE); h.up(codeB)
        h.chord([space])
        h.chord([codeT, codeE, codeB])
        #expect(h.buffer.text == "thethethe the")
    }

    @Test("Req 3.9: pass-through key discards the chord")
    func passThroughDiscards() {
        let h = RouterHarness()
        h.optionTap()
        h.down(codeT)
        h.down(codeReturn); h.up(codeReturn)
        #expect(h.up(codeT) == .suppress)
        #expect(h.buffer.text == "")
    }

    @Test("Req 2.5: release handled like its press across mode changes")
    func releaseMatchesPress() {
        let h = RouterHarness()
        h.optionTap()
        h.down(codeT)
        _ = h.router.toggleChordMode()          // to Normal while T is held
        #expect(h.up(codeT) == .suppress)
        h.down(codeE)
        _ = h.router.toggleChordMode()          // to Chord while E is held
        #expect(h.up(codeE) == .pass)
    }

    @Test("Req 1.10: mode change discards chord and resets context")
    func modeChangeResets() {
        let h = RouterHarness()
        h.optionTap()
        h.chord([codeT, codeE, codeB])
        h.optionTap(); h.optionTap()
        h.chord([codeT, codeE, codeB])
        #expect(h.buffer.text == "thethe")
        #expect(h.router.lastSubMode == .english)
    }

    @Test("Req 1.2, 1.9: Mode_Switch chord and remembered sub-mode")
    func subModes() {
        let h = RouterHarness()
        h.optionTap()
        h.chord([33, 30])                        // LBracket+RBracket
        #expect(h.router.effectiveMode == .chord(.cpp))
        #expect(h.events.last == .modeChanged(.chord(.cpp)))
        h.optionTap(); h.optionTap()
        #expect(h.router.effectiveMode == .chord(.cpp))
        _ = h.router.selectSubMode(.english)
        #expect(h.router.effectiveMode == .chord(.english))
    }

    @Test("Req 18.2, 18.4, 18.5: permissions and secure input")
    func availability() {
        let h = RouterHarness()
        _ = h.router.setPermissionsGranted(false)
        h.optionTap()
        #expect(h.router.effectiveMode == .normal)
        #expect(h.router.availability == .missingPermission)
        _ = h.router.setPermissionsGranted(true)
        h.optionTap()
        #expect(h.router.effectiveMode == .chord(.english))
        _ = h.router.setSecureInput(true)
        #expect(h.router.effectiveMode == .normal)
        #expect(h.down(codeT) == .pass)
        h.up(codeT)
        _ = h.router.setSecureInput(false)
        #expect(h.router.effectiveMode == .chord(.english))
    }

    @Test("Req 5.3: probe focus disables chords and taps")
    func probe() {
        let h = RouterHarness()
        h.optionTap()
        h.router.setProbeActive(true)
        #expect(h.down(codeT) == .pass)
        h.up(codeT)
        h.optionTap()
        h.router.setProbeActive(false)
        #expect(h.router.effectiveMode == .chord(.english))
    }

    @Test("Req 3.11: physical sync discards stuck chords")
    func physicalSync() {
        let h = RouterHarness()
        h.optionTap()
        h.down(codeT)
        h.router.syncPhysicalKeys([])
        #expect(!h.router.engine.chordInProgress)
    }

    @Test("Req 19.4: Normal_Mode passes every event without an Option tap")
    func normalModePassesEverything() {
        var rng = SplitMix64(seed: 99)
        let codes: [KeyCode] = Array(0...50) + [53, 117, 123, 124, 125, 126]
        let mods: [(KeyCode, ModifierKey)] = [(56, .shift), (60, .shift), (59, .control), (55, .command), (57, .capsLock), (63, .function)]
        for _ in 0..<50 {
            let r = EventRouter(data: defaults)
            var t: UInt64 = 0
            for _ in 0..<300 {
                t += UInt64.random(in: 0...200, using: &rng)
                let input: RouterInput
                switch Int.random(in: 0..<6, using: &rng) {
                case 0, 1:
                    input = .keyDown(code: codes.randomElement(using: &rng)!, isRepeat: Bool.random(using: &rng),
                                     flags: ModifierFlags(rawValue: UInt8.random(in: 0...15, using: &rng)), time: t)
                case 2, 3:
                    input = .keyUp(code: codes.randomElement(using: &rng)!, flags: [], time: t)
                case 4:
                    let m = mods.randomElement(using: &rng)!
                    input = Bool.random(using: &rng) ? .modifierDown(code: m.0, key: m.1, time: t) : .modifierUp(code: m.0, key: m.1, time: t)
                default:
                    input = .mouseDown(time: t)
                }
                let o = r.handle(input)
                #expect(o.decision == .pass && o.actions.isEmpty)
            }
            #expect(r.effectiveMode == .normal)
        }
    }
}
