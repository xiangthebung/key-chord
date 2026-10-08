import Testing
@testable import KeyChordCore

@Suite("Honest hardware provenance and short checks")
struct HardwareConfidenceTests {
    let identity = HardwareIdentity(keyboard: "My external keyboard", profile: "English · ANSI", model: "MacBookPro18,3")
    @Test("Selecting measured or derived wiring never proves the current keyboard works")
    func provenance() {
        let iso = HardwareConfidence.resolve(identity: identity, wiringText: DefaultData.wiringMacBookPro18,
                                               scanText: nil, layout: defaults.layout)
        #expect(iso.source == .bundledISO)
        #expect(!iso.associatedWithCurrentKeyboard && iso.observations == 0)
        #expect(iso.detail.contains("998 of 999"))
        let ansi = HardwareConfidence.resolve(identity: identity, wiringText: DefaultData.wiringMacBookPro18ANSI,
                                                scanText: nil, layout: defaults.layout)
        #expect(ansi.source == .derivedANSI && !ansi.associatedWithCurrentKeyboard)
        #expect(ansi.detail.contains("unknown"))
        let unchecked = HardwareConfidence.resolve(identity: identity, wiringText: "version 1\n",
                                                    scanText: nil, layout: defaults.layout)
        #expect(unchecked.source == .unchecked)
        let empty = HardwareConfidence.resolve(identity: identity, wiringText: nil,
                                                scanText: "version 1\n", layout: defaults.layout)
        #expect(empty.source == .unchecked)
    }
    @Test("Saved scan is user-observed evidence with explicit unconfirmed keyboard association")
    func savedScan() {
        let text = "version 1\nhardware An earlier keyboard\ncombo S+C+J pass\n"
        let scan = HardwareConfidence.resolve(identity: identity, wiringText: DefaultData.wiringMacBookPro18ANSI,
                                                scanText: text, layout: defaults.layout)
        #expect(scan.source == .savedObservedScan && scan.observations == 1)
        #expect(!scan.associatedWithCurrentKeyboard)
        #expect(scan.detail.contains("not been confirmed"))
        let confirmed = HardwareConfidence.resolve(identity: identity, wiringText: nil, scanText: text,
                                                     layout: defaults.layout, scanBelongsToCurrentKeyboard: true)
        #expect(confirmed.associatedWithCurrentKeyboard)
        let mismatch = HardwareConfidence.resolve(identity: identity, wiringText: nil,
            scanText: "version 1\nkeys NotThisLayout\ncombo S+C+J pass\n", layout: defaults.layout)
        #expect(mismatch.source == .unchecked)
    }
    @Test("Small relevant sequence and available capital alternatives exclude modeled failures")
    func relevant() throws {
        let wiring = try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: defaults.layout)
        let limits = KeyboardLimits(wiring: wiring)
        let first = QuickChordTarget.planned(words: ["sat", "hat", "tan"], data: defaults, limits: limits)
        #expect(first.count == 3)
        let capitals = QuickChordTarget.planned(words: ["A", "H", "J", "K"], data: defaults, limits: limits)
        #expect(capitals.count >= 4)
        #expect(capitals.contains { Set($0.keys) == Set(["N", "M"]) })
        for target in first + capitals {
            let keySet = try #require(defaults.layout.keySet(names: target.keys))
            #expect(!limits.blocks(keySet.indices.map { defaults.layout.keys[$0].code }))
        }
    }
    @Test("Observed peak must hold every target together; a union of separately tapped keys cannot pass")
    func physicalEvidence() throws {
        let target = QuickChordTarget(label: "sat", keys: ["S", "C", "J"])
        let session = QuickChordCheckSession(layout: defaults.layout, identity: identity, targets: [target, target])
        let s = code("S"), c = code("C"), j = code("J")
        session.keyDown(s); session.keyDown(c)
        #expect(session.keyUp(c, timestamp: 10) == nil)
        session.keyDown(j)
        session.keyUp(s, timestamp: 20)
        let incomplete = try #require(session.keyUp(j, timestamp: 30))
        #expect(!incomplete.allRegistered && incomplete.missing == ["J"])
        session.keyDown(s); session.keyDown(c); session.keyDown(j)
        session.keyUp(s, timestamp: 40); session.keyUp(c, timestamp: 50)
        let registered = try #require(session.keyUp(j, timestamp: 60))
        #expect(registered.allRegistered)
        #expect(session.report().contains("does not diagnose"))
        #expect(session.report().contains(identity.keyboard))
    }
    @Test("Extra evidence is retained, retry preserves evidence, skip and interruption never manufacture results")
    func extraRetry() throws {
        let target = QuickChordTarget(label: "sat", keys: ["S", "C", "J"])
        let session = QuickChordCheckSession(layout: defaults.layout, identity: identity, targets: [target, target])
        for code in [code("S"), code("C"), code("J"), UInt16(999)] { session.keyDown(code) }
        for code in [code("S"), code("C"), code("J")] { session.keyUp(code, timestamp: 10) }
        #expect(session.keyUp(998, timestamp: 10) == nil)
        let result = try #require(session.keyUp(999, timestamp: 20))
        #expect(result.extra == ["Key999"] && !result.allRegistered)
        session.skip(); #expect(session.current == nil && session.results.count == 1)
        session.retryLast(); #expect(session.current == target && session.results.count == 1)
        session.keyDown(code("S")); session.interrupt()
        #expect(session.keyUp(code("S"), timestamp: 30) == nil)
        #expect(session.results.count == 1)
    }
    @Test("Late Shift is observed while all targets are held; shortcut interruption discards pending evidence")
    func lateShiftAndShortcut() throws {
        let target = QuickChordTarget(label: "joined sat", keys: ["S", "C", "J"], shift: true)
        let session = QuickChordCheckSession(layout: defaults.layout, identity: identity, targets: [target])
        for name in target.keys { session.keyDown(code(name)) }
        session.shiftChanged(true)
        for name in target.keys.dropLast() { session.keyUp(code(name), timestamp: 10) }
        #expect(try #require(session.keyUp(code("J"), timestamp: 20)).allRegistered)
        session.retryLast()
        session.keyDown(code("S")); session.interrupt() // Native shortcut/mouse/flagsChanged adapter.
        #expect(session.keyUp(code("S"), timestamp: 30) == nil)
        #expect(session.down.isEmpty && session.results.count == 1)
    }
    private func code(_ name: String) -> KeyCode { defaults.layout.keys[defaults.layout.indexByName[name]!].code }
}
