// Rollover_Probe model (Req 5.1 - 5.7). The macOS window feeds it raw key events and renders its state.

public enum ProbeSource: String, Sendable, CaseIterable {
    /// Every key subset in the Cluster_Tables and the Fingerspelling_Table (with the Spell_Key).
    case layoutTables
    /// Every Chord in the Shared, English and C++ Dictionaries.
    case dictionaries
    /// Randomly sampled Syllable_Composition chords using exactly Rollover_Limit keys.
    case randomSyllables
}

public final class ProbeSession {
    public let layout: Layout

    /// Non-modifier keys currently held, in press order.
    public private(set) var heldKeys: [KeyCode] = []
    public private(set) var heldModifiers: [KeyCode] = []
    /// Largest number of non-modifier keys observed held at once (Req 5.2).
    public private(set) var maxHeld = 0
    /// Results of earlier guided runs.
    private var archived: [ProbeResult] = []
    /// One slot per target of the current run; going back and trying again overwrites the slot.
    public private(set) var slots: [ProbeResult?] = []
    public var results: [ProbeResult] { archived + slots.compactMap { $0 } }

    public private(set) var targets: [KeySet] = []
    public private(set) var targetIndex = 0
    /// The last result was `extra`; waiting for retry / record-as-ghost / skip (Req 5.6).
    public private(set) var awaitingExtraDecision = false
    /// Keys registered during the current guided attempt.
    public private(set) var attemptKeys = Set<KeyCode>()
    /// The most target keys registered as held at the same moment during the attempt. A blocked key can
    /// register late, after another key is lifted, so keys pressed at different times don't count together.
    private var peak = Set<KeyCode>()

    public init(layout: Layout) { self.layout = layout }

    public var guidedActive: Bool { targetIndex < targets.count }
    public var currentTarget: KeySet? { guidedActive ? targets[targetIndex] : nil }
    /// The result already recorded for the current target (after going back).
    public var currentResult: ProbeResult? { guidedActive ? slots[targetIndex] : nil }
    public var canGoBack: Bool { !targets.isEmpty && (targetIndex > 0 || awaitingExtraDecision) }
    public var canGoForward: Bool { guidedActive }

    public func name(of code: KeyCode) -> String {
        if let i = layout.indexByCode[code] { return layout.keys[i].name }
        return "Key\(code)"
    }

    public func names(_ codes: [KeyCode]) -> [String] { codes.map(name(of:)) }

    public func targetNames(_ t: KeySet) -> [String] { layout.names(t) }

    // MARK: Raw events

    public func keyDown(_ code: KeyCode) {
        guard !heldKeys.contains(code) else { return }
        heldKeys.append(code)
        maxHeld = max(maxHeld, heldKeys.count)
        if guidedActive && !awaitingExtraDecision, let target = currentTarget {
            attemptKeys.insert(code)
            let targetCodes = Set(target.indices.map { layout.keys[$0].code })
            let now = Set(heldKeys).intersection(targetCodes)
            if now.count > peak.count { peak = now }
        }
    }

    /// Returns the recorded result when a guided attempt completes (Req 5.5).
    @discardableResult
    public func keyUp(_ code: KeyCode, time: Int64) -> ProbeResult? {
        heldKeys.removeAll { $0 == code }
        guard heldKeys.isEmpty, guidedActive, !awaitingExtraDecision, !attemptKeys.isEmpty,
              let target = currentTarget else { return nil }
        let targetCodes = Set(target.indices.map { layout.keys[$0].code })
        let missing = targetCodes.subtracting(peak)
        let extra = attemptKeys.subtracting(targetCodes)
        attemptKeys.removeAll()
        peak.removeAll()
        let tNames = targetNames(target)
        let result: ProbeResult
        let index = targetIndex
        if !missing.isEmpty {
            result = ProbeResult(timestamp: time, target: tNames, outcome: .fail, detail: sortedNames(missing))
            targetIndex += 1
        } else if !extra.isEmpty {
            result = ProbeResult(timestamp: time, target: tNames, outcome: .extra, detail: sortedNames(extra))
            awaitingExtraDecision = true
        } else {
            result = ProbeResult(timestamp: time, target: tNames, outcome: .pass)
            targetIndex += 1
        }
        slots[index] = result
        return result
    }

    private func sortedNames(_ codes: Set<KeyCode>) -> [String] {
        codes.sorted { a, b in
            let ia = layout.indexByCode[a] ?? Int.max, ib = layout.indexByCode[b] ?? Int.max
            return ia != ib ? ia < ib : a < b
        }.map(name(of:))
    }

    public func modifierDown(_ code: KeyCode) {
        if !heldModifiers.contains(code) { heldModifiers.append(code) }
    }

    public func modifierUp(_ code: KeyCode) {
        heldModifiers.removeAll { $0 == code }
    }

    // MARK: Guided test

    public func startGuided(_ t: [KeySet]) {
        archived += slots.compactMap { $0 }
        targets = t
        slots = Array(repeating: nil, count: t.count)
        targetIndex = 0
        awaitingExtraDecision = false
        attemptKeys.removeAll()
        peak.removeAll()
    }

    /// Discard the `extra` result and try the same combination again.
    public func retry() {
        guard awaitingExtraDecision, guidedActive else { return }
        slots[targetIndex] = nil
        awaitingExtraDecision = false
    }

    /// Record the `extra` result as a ghosting failure and move on.
    public func recordGhost() {
        guard awaitingExtraDecision, guidedActive else { return }
        slots[targetIndex]?.outcome = .ghost
        awaitingExtraDecision = false
        targetIndex += 1
    }

    /// Keep the current result (if any) and go to the next combination.
    public func skip() {
        guard guidedActive else { return }
        awaitingExtraDecision = false
        attemptKeys.removeAll()
        peak.removeAll()
        targetIndex += 1
    }

    /// Go back one combination (for example after a mistyped attempt). Its earlier result stays until
    /// a new attempt replaces it.
    public func back() {
        guard canGoBack else { return }
        attemptKeys.removeAll()
        peak.removeAll()
        if awaitingExtraDecision {
            // Throw away the unexpected-keys attempt and stay on this combination.
            slots[targetIndex] = nil
            awaitingExtraDecision = false
            return
        }
        targetIndex -= 1
    }

    /// Go forward one combination, keeping whatever result it has.
    public func forward() {
        guard canGoForward else { return }
        if awaitingExtraDecision { slots[targetIndex] = nil }
        awaitingExtraDecision = false
        attemptKeys.removeAll()
        peak.removeAll()
        targetIndex += 1
    }

    public func stopGuided() {
        archived += slots.compactMap { $0 }
        slots = []
        targets = []
        targetIndex = 0
        awaitingExtraDecision = false
        attemptKeys.removeAll()
        peak.removeAll()
    }

    public func report(created: Int64) -> ProbeReport {
        ProbeReport(created: created, maxHeld: maxHeld, results: results)
    }

    // MARK: Target generation (Req 5.4)

    public static func targets<G: RandomNumberGenerator>(source: ProbeSource, data: EngineData, rolloverLimit: Int,
                                                         count: Int, using rng: inout G) -> [KeySet] {
        let l = data.layout
        var out: [KeySet] = []
        var seen = Set<KeySet>()
        // One and two key combinations always register on the built-in keyboard, so they are not tested.
        func add(_ k: KeySet) { if k.count >= 3 && seen.insert(k).inserted { out.append(k) } }
        switch source {
        case .layoutTables:
            for bank in Bank.allCases {
                for k in (l.clusters[bank] ?? [:]).keys.sorted(by: { $0.bits < $1.bits }) { add(k) }
            }
            for k in l.fingerspelling.keys.sorted(by: { $0.bits < $1.bits }) {
                var c = k
                if let s = l.spellIndex { c.insert(s) }
                add(c)
            }
        case .dictionaries:
            for d in [data.shared, data.english, data.cpp] {
                for k in d.entries.keys.sorted(by: { $0.bits < $1.bits }) { add(k) }
            }
        case .randomSyllables:
            func options(_ b: Bank) -> [KeySet] {
                [KeySet()] + (l.clusters[b] ?? [:]).keys.sorted(by: { $0.bits < $1.bits })
            }
            var all: [KeySet] = []
            for o in options(.onset) {
                for v in options(.vowel) where o.count + v.count <= rolloverLimit {
                    for c in options(.coda) where o.count + v.count + c.count == rolloverLimit {
                        all.append(o.union(v).union(c))
                    }
                }
            }
            all.shuffle(using: &rng)
            for k in all.prefix(max(0, count)) { add(k) }
        }
        return out
    }
}
