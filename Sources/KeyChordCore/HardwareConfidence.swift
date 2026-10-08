// Model provenance and small, local observations. A selected model is never a physical test.
public struct HardwareIdentity: Equatable, Sendable {
    public let keyboard: String
    public let profile: String
    public let model: String
    public init(keyboard: String, profile: String, model: String) {
        self.keyboard = keyboard; self.profile = profile; self.model = model
    }
    public var reportHeader: String {
        "keyboard \(Self.line(keyboard))\nprofile \(Self.line(profile))\ncomputer \(Self.line(model))\n"
    }
    static func line(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

public struct HardwareConfidence: Equatable, Sendable {
    public enum Source: String, Sendable {
        case bundledISO, derivedANSI, savedObservedScan, unchecked
    }
    public let identity: HardwareIdentity
    public let source: Source
    public let observations: Int
    public let associatedWithCurrentKeyboard: Bool
    public var title: String {
        switch source {
        case .bundledISO: return "Bundled ISO model · measured on a related MacBook"
        case .derivedANSI: return "Derived ANSI model · prediction only"
        case .savedObservedScan: return "Saved user scan · \(observations) observations"
        case .unchecked: return "Current keyboard · unchecked"
        }
    }
    public var detail: String {
        switch source {
        case .bundledISO:
            return "The ISO model was measured on a 2021 MacBook Pro (MacBookPro18,1), explaining 998 of 999 observations. Selecting it does not test this keyboard."
        case .derivedANSI:
            return "ANSI wiring is derived from the measured ISO model. It has not been measured; Grave and Backslash positions are unknown. Selecting it does not test this keyboard."
        case .savedObservedScan:
            return associatedWithCurrentKeyboard
                ? "User observations associated with this keyboard and profile. They cover only the combinations tested; other chords remain unchecked."
                : "A saved scan contains user observations. Its keyboard has not been confirmed as the currently connected keyboard; other chords remain unchecked."
        case .unchecked:
            return "There is no confirmed observation of this keyboard. A custom wiring file, if selected, is a prediction until tested."
        }
    }

    public static func resolve(identity: HardwareIdentity, wiringText: String?, scanText: String?, layout: Layout,
                               scanBelongsToCurrentKeyboard: Bool = false) -> HardwareConfidence {
        if let scanText, let scan = try? MatrixScanReport.parse(scanText, layout: layout) {
            let count = scan.combos.count + scan.sweeps.reduce(0) {
                $0 + ($1.tapped?.count ?? max(0, layout.keys.count - 2))
            }
            if count > 0 {
                return HardwareConfidence(identity: identity, source: .savedObservedScan, observations: count,
                                          associatedWithCurrentKeyboard: scanBelongsToCurrentKeyboard)
            }
        }
        let source: Source = wiringText == DefaultData.wiringMacBookPro18 ? .bundledISO
            : wiringText == DefaultData.wiringMacBookPro18ANSI ? .derivedANSI : .unchecked
        return HardwareConfidence(identity: identity, source: source, observations: 0,
                                  associatedWithCurrentKeyboard: false)
    }
}

public struct QuickChordTarget: Equatable, Sendable {
    public let label: String
    public let keys: [String]
    public let shift: Bool
    public init(label: String, keys: [String], shift: Bool = false) {
        self.label = label; self.keys = keys; self.shift = shift
    }
    /// Relevant chords only; capital checks use the planner's available alternatives.
    public static func planned(words: [String], data: EngineData, limits: KeyboardLimits?) -> [QuickChordTarget] {
        let planner = TypingPlanner(data: data, mode: .english, usable: { keys in
            !(limits?.blocks(keys.indices.map { data.layout.keys[$0].code }) ?? false)
        })
        return words.flatMap { word in
            let steps = planner.plan(word).steps
            return steps.compactMap { step -> QuickChordTarget? in
                guard case let .chord(keys, shift) = step.action else { return nil }
                return QuickChordTarget(label: "\(word) · \(step.note)", keys: keys, shift: shift)
            }
        }
    }
}

public struct QuickChordObservation: Equatable, Sendable {
    public let target: QuickChordTarget
    public let timestamp: Int64
    public let missing: [String]
    public let extra: [String]
    public var allRegistered: Bool { missing.isEmpty && extra.isEmpty }
}

/// Hold every target key, then release all. Never infer a matrix failure from an incomplete attempt.
public final class QuickChordCheckSession {
    public let layout: Layout
    public let identity: HardwareIdentity
    public let targets: [QuickChordTarget]
    public private(set) var index = 0
    public private(set) var down = Set<KeyCode>()
    public private(set) var results: [QuickChordObservation] = []
    private var seen = Set<KeyCode>()
    private var peak = Set<KeyCode>()
    private var sawShiftWithAll = false
    public var current: QuickChordTarget? { index < targets.count ? targets[index] : nil }
    public init(layout: Layout, identity: HardwareIdentity, targets: [QuickChordTarget]) {
        self.layout = layout; self.identity = identity
        self.targets = targets.filter { !$0.keys.isEmpty && layout.keySet(names: $0.keys) != nil }
    }
    private var targetCodes: Set<KeyCode> {
        Set(current?.keys.compactMap { layout.indexByName[$0].map { layout.keys[$0].code } } ?? [])
    }
    public func keyDown(_ code: KeyCode, shift: Bool = false) {
        guard current != nil, down.insert(code).inserted else { return }
        seen.insert(code)
        let simultaneous = down.intersection(targetCodes)
        if simultaneous.count > peak.count { peak = simultaneous }
        if simultaneous == targetCodes && shift { sawShiftWithAll = true }
    }
    public func shiftChanged(_ isDown: Bool) {
        if isDown && !targetCodes.isEmpty && down.isSuperset(of: targetCodes) { sawShiftWithAll = true }
    }
    @discardableResult public func keyUp(_ code: KeyCode, timestamp: Int64) -> QuickChordObservation? {
        guard down.remove(code) != nil, down.isEmpty, !seen.isEmpty, let target = current else { return nil }
        func names(_ codes: Set<KeyCode>) -> [String] {
            codes.sorted().map { code in layout.indexByCode[code].map { layout.keys[$0].name } ?? "Key\(code)" }
        }
        var missing = names(targetCodes.subtracting(peak))
        if target.shift && !sawShiftWithAll { missing.append("Shift") }
        let result = QuickChordObservation(target: target, timestamp: timestamp, missing: missing,
                                           extra: names(seen.subtracting(targetCodes)))
        results.append(result); index += 1; clearAttempt()
        return result
    }
    private func clearAttempt() { down.removeAll(); seen.removeAll(); peak.removeAll(); sawShiftWithAll = false }
    public func interrupt() { clearAttempt() }
    public func retryLast() {
        clearAttempt()
        guard index > 0 else { return }
        index -= 1 // Preserve earlier evidence, including an incomplete first attempt.
    }
    public func skip() { clearAttempt(); if current != nil { index += 1 } }
    public func report() -> String {
        var text = "# KeyChord short chord check\nversion 1\n" + identity.reportHeader
        text += "# User-observed local events; no typed text or event trace. Each result covers only this attempt.\n"
        for r in results {
            text += "observed \(r.timestamp) \(r.target.keys.joined(separator: "+")) shift=\(r.target.shift) "
            text += r.allRegistered ? "all-registered" : "incomplete"
            text += " missing=\(r.missing.isEmpty ? "-" : r.missing.joined(separator: "+"))"
            text += " extra=\(r.extra.isEmpty ? "-" : r.extra.joined(separator: "+"))\n"
        }
        return text + "# Incomplete attempts may be timing or missed keys. Repeat before investigating hardware; this does not diagnose the matrix.\n"
    }
}
