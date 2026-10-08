// Explicit, local English experiment. Never installs a brief in the user's dictionaries.
public enum ErgonomicRoute: String, CaseIterable, Sendable { case current, proposed }
public enum ErgonomicContext: String, CaseIterable, Sendable { case fresh, afterWord }

public struct ErgonomicCandidate: Equatable, Sendable {
    public let word: String
    public let keys: [String]
    public static let proposals = [ErgonomicCandidate(word: "use", keys: ["Quote", "U", "S"]),
                                   ErgonomicCandidate(word: "you", keys: ["Quote", "Y", "O"])]
}

public struct ErgonomicCompatibility: Equatable, Sendable {
    public let word: String
    public let problems: [String]
    public let hardwareNote: String
    public var allowed: Bool { problems.isEmpty }
}

public struct ErgonomicTrial: Equatable, Sendable {
    public let word: String
    public let route: ErgonomicRoute
    public let context: ErgonomicContext
    public let repetition: Int
    public let steps: [TypingStep]
    public let expectedOutput: String
    public let startContext: EngineContext
    public var keyActivations: Int {
        steps.reduce(0) { count, step in
            if case let .chord(keys, shift) = step.action { return count + keys.count + (shift ? 1 : 0) }
            return count
        }
    }
}

public struct ErgonomicMeasurement: Equatable, Sendable {
    public let trial: ErgonomicTrial
    /// Milliseconds from first physical press through successful completion, including correction/retry time.
    public let elapsedMilliseconds: Int64
    public let corrections: Int
    /// User-rated comfort, 1 (uncomfortable) through 5 (comfortable).
    public let comfort: Int
    public init?(trial: ErgonomicTrial, elapsedMilliseconds: Int64, corrections: Int, comfort: Int) {
        guard elapsedMilliseconds > 0, corrections >= 0, (1...5).contains(comfort) else { return nil }
        self.trial = trial; self.elapsedMilliseconds = elapsedMilliseconds
        self.corrections = corrections; self.comfort = comfort
    }
}

public struct ErgonomicSummary: Equatable, Sendable {
    public let word: String
    public let route: ErgonomicRoute
    public let attempts: Int
    public let meanMilliseconds: Double?
    public let corrections: Int
    public let meanComfort: Double?
    public init(word: String, route: ErgonomicRoute, measurements: [ErgonomicMeasurement]) {
        let matching = measurements.filter { $0.trial.word == word && $0.trial.route == route }
        self.word = word; self.route = route; attempts = matching.count
        corrections = matching.reduce(0) { $0 + $1.corrections }
        meanMilliseconds = matching.isEmpty ? nil : Double(matching.reduce(Int64(0)) { $0 + $1.elapsedMilliseconds }) / Double(matching.count)
        meanComfort = matching.isEmpty ? nil : Double(matching.reduce(0) { $0 + $1.comfort }) / Double(matching.count)
    }
}

public enum ErgonomicExperiment {
    public static func compatibility(_ candidate: ErgonomicCandidate, data: EngineData,
                                     mode: SubMode = .english, limits: KeyboardLimits? = nil,
                                     rolloverLimit: Int = 6) -> ErgonomicCompatibility {
        var problems: [String] = []
        if mode != .english { problems.append("This experiment is English only. Quote+U+S keeps its C++ meaning, ‘using’.") }
        guard let keys = data.layout.keySet(names: candidate.keys), !keys.isEmpty else {
            return ErgonomicCompatibility(word: candidate.word, problems: problems + ["The proposed keys are absent from this layout."], hardwareNote: "Unchecked")
        }
        if data.english[keys] != nil || data.shared[keys] != nil
            || ChordReading(keys, data: data, mode: .english).outcome != .nothing {
            problems.append("The proposed chord already has a meaning in this English profile.")
        }
        if keys.count > rolloverLimit { problems.append("The proposed chord exceeds the selected key limit.") }
        let codes = keys.indices.map { data.layout.keys[$0].code }
        if limits?.blocks(codes) == true { problems.append("The selected keyboard limits exclude the proposed chord.") }
        // Replay both fresh text and text after a word with the isolated English brief.
        var local = data
        local.english.entries[keys] = .text(TextEntry(text: candidate.word))
        for context in ErgonomicContext.allCases {
            let engine = ChordEngine(data: local, subMode: .english)
            if context == .afterWord {
                guard let prefix = data.layout.keySet(names: ["S", "C", "J"]),
                      (try? engine.translate(prefix, join: false))?.actions == [.insert("sat")] else {
                    problems.append("The baseline context is incompatible with this profile."); continue
                }
            }
            let expected = (context == .afterWord ? " " : "") + candidate.word
            if (try? engine.translate(keys, join: false))?.actions != [.insert(expected)] {
                problems.append("The proposed route failed exact output and spacing validation.")
            }
        }
        return ErgonomicCompatibility(word: candidate.word, problems: problems,
            hardwareNote: limits == nil ? "Hardware unchecked; test locally before drawing conclusions."
                : "Selected limits permit this candidate; this is a prediction until physically tested.")
    }

    /// A value copy for the local sandbox only. All other profiles and the C++ dictionary stay intact.
    public static func isolatedData(data: EngineData, optedIn: Bool, mode: SubMode = .english,
                                    limits: KeyboardLimits? = nil, rolloverLimit: Int = 6) -> EngineData? {
        guard optedIn, mode == .english else { return nil }
        var local = data
        var added = false
        for candidate in ErgonomicCandidate.proposals where compatibility(candidate, data: data, limits: limits,
                                                                          rolloverLimit: rolloverLimit).allowed {
            guard let keys = data.layout.keySet(names: candidate.keys) else { continue }
            local.english.entries[keys] = .text(TextEntry(text: candidate.word)); added = true
        }
        return added ? local : nil
    }

    /// Two repetitions in each of two contexts. Route order alternates to expose order/learning effects.
    public static func trials(data: EngineData, limits: KeyboardLimits?, optedIn: Bool,
                              rolloverLimit: Int = 6) -> [ErgonomicTrial] {
        guard let local = isolatedData(data: data, optedIn: optedIn, limits: limits,
                                       rolloverLimit: rolloverLimit) else { return [] }
        let usable: (KeySet) -> Bool = { !(limits?.blocks($0.indices.map { data.layout.keys[$0].code }) ?? false) }
        var trials: [ErgonomicTrial] = []
        for repetition in 1...2 {
            for context in ErgonomicContext.allCases {
                for candidate in ErgonomicCandidate.proposals where compatibility(candidate, data: data, limits: limits,
                                                                                  rolloverLimit: rolloverLimit).allowed {
                    let order: [ErgonomicRoute] = repetition == 1 ? [.current, .proposed] : [.proposed, .current]
                    var pairedTrials: [ErgonomicTrial] = []
                    for route in order {
                        let routeData = route == .current ? data : local
                        let text = context == .fresh ? candidate.word : "sat " + candidate.word
                        let guide = TypingPlanner(data: routeData, mode: .english, rolloverLimit: rolloverLimit, usable: usable).plan(text)
                        let steps = guide.steps.filter { $0.source.lowerBound >= (context == .fresh ? 0 : 4) }
                        guard !steps.isEmpty, steps.allSatisfy(\.isChord) else { continue }
                        let engine = ChordEngine(data: routeData, subMode: .english)
                        if context == .afterWord {
                            guard let prefix = data.layout.keySet(names: ["S", "C", "J"]),
                                  (try? engine.translate(prefix, join: false))?.actions == [.insert("sat")] else { continue }
                        }
                        let start = engine.currentContext
                        var buffer = context == .afterWord ? "sat" : ""
                        var replayed = true
                        for step in steps {
                            guard case let .chord(names, shift) = step.action,
                                  let keys = data.layout.keySet(names: names),
                                  let result = try? engine.translate(keys, join: shift), result.signal == nil else {
                                replayed = false; break
                            }
                            for action in result.actions {
                                switch action {
                                case .insert(let text): buffer += text
                                case .deleteBackward(let count):
                                    if count <= buffer.count { buffer = String(buffer.dropLast(count)) }
                                    else { replayed = false }
                                default: replayed = false
                                }
                            }
                        }
                        guard replayed, buffer == text else { continue }
                        pairedTrials.append(ErgonomicTrial(word: candidate.word, route: route, context: context,
                                                     repetition: repetition, steps: steps,
                                                     expectedOutput: text, startContext: start))
                    }
                    // An executable proposal alone cannot be compared with an unavailable baseline.
                    if pairedTrials.count == 2 { trials += pairedTrials }
                }
            }
        }
        return trials
    }

    public static func report(identity: HardwareIdentity, measurements: [ErgonomicMeasurement]) -> String {
        var text = "# KeyChord opt-in English ergonomic trial\nversion 1\n" + identity.reportHeader
        text += "# User-local physical trials only; time includes retries. Comfort is self-rated 1–5. No global preference or frequency claim.\n"
        if measurements.isEmpty { text += "# No human measurements have been collected. Model compatibility is not comfort or speed evidence.\n" }
        for measurement in measurements {
            let trial = measurement.trial
            text += "observed word=\(trial.word) route=\(trial.route.rawValue) context=\(trial.context.rawValue) repetition=\(trial.repetition) "
            text += "milliseconds=\(measurement.elapsedMilliseconds) corrections=\(measurement.corrections) comfort=\(measurement.comfort)\n"
            let route = trial.steps.compactMap { step -> String? in
                guard case let .chord(keys, shift) = step.action else { return nil }
                return (shift ? ["Shift"] + keys : keys).joined(separator: "+")
            }.joined(separator: ",")
            text += "route-chords \(route) key-activations=\(trial.keyActivations)\n"
        }
        for word in ErgonomicCandidate.proposals.map(\.word) {
            for route in ErgonomicRoute.allCases {
                let s = ErgonomicSummary(word: word, route: route, measurements: measurements)
                text += "summary word=\(word) route=\(route.rawValue) attempts=\(s.attempts) mean-ms=\(s.meanMilliseconds.map(String.init(describing:)) ?? "unmeasured") corrections=\(s.corrections) comfort=\(s.meanComfort.map(String.init(describing:)) ?? "unmeasured")\n"
            }
        }
        return text + "# Compare matched contexts and repetitions. Practice/order effects and hand preference remain; no automatic winner is inferred.\n"
    }
}

/// Executes prevalidated routes in an isolated buffer. Only physical, nonrepeat events advance a route.
public final class ErgonomicTrialSession {
    public let data: EngineData
    public let trials: [ErgonomicTrial]
    public private(set) var index = 0
    public private(set) var stepIndex = 0
    public private(set) var measurements: [ErgonomicMeasurement] = []
    public private(set) var corrections = 0
    public private(set) var pendingMilliseconds: Int64?
    public private(set) var down = Set<KeyCode>()
    private var seen = Set<KeyCode>()
    private var shifted = false
    private var started: Int64?
    private var engine: ChordEngine
    private var buffer = ""
    public var current: ErgonomicTrial? { index < trials.count ? trials[index] : nil }
    public var currentStep: TypingStep? {
        guard let trial = current, trial.steps.indices.contains(stepIndex) else { return nil }
        return trial.steps[stepIndex]
    }
    public init(data: EngineData, trials: [ErgonomicTrial]) {
        self.data = data; self.trials = trials; engine = ChordEngine(data: data, subMode: .english)
        resetRoute()
    }
    private func resetRoute() {
        down.removeAll(); seen.removeAll(); shifted = false; stepIndex = 0
        engine = ChordEngine(data: data, subMode: .english)
        engine.restore(current?.startContext ?? .initial)
        buffer = current?.context == .afterWord ? "sat" : ""
    }
    public func keyDown(_ code: KeyCode, timestamp: Int64, shift: Bool = false, isRepeat: Bool = false) {
        guard !isRepeat, pendingMilliseconds == nil, current != nil, down.insert(code).inserted else { return }
        if started == nil { started = timestamp }
        seen.insert(code); shifted = shifted || shift
    }
    public func shiftChanged(_ isDown: Bool) {
        if !down.isEmpty && isDown { shifted = true }
    }
    @discardableResult public func keyUp(_ code: KeyCode, timestamp: Int64) -> Bool {
        guard down.remove(code) != nil, down.isEmpty, !seen.isEmpty, pendingMilliseconds == nil,
              let trial = current, let step = currentStep, case let .chord(names, shift) = step.action,
              let keys = data.layout.keySet(names: names) else { return false }
        let target = Set(keys.indices.map { data.layout.keys[$0].code })
        guard seen == target, shifted == shift,
              let result = try? engine.translate(keys, join: shift), result.signal == nil else {
            corrections += 1; resetRoute(); return false
        }
        seen.removeAll(); shifted = false
        for action in result.actions {
            switch action {
            case .insert(let text): buffer += text
            case .deleteBackward(let count) where count <= buffer.count: buffer = String(buffer.dropLast(count))
            default: corrections += 1; resetRoute(); return false
            }
        }
        stepIndex += 1
        guard stepIndex == trial.steps.count else { return false }
        guard buffer == trial.expectedOutput, let started, timestamp > started else {
            corrections += 1; resetRoute(); return false
        }
        pendingMilliseconds = timestamp - started
        return true
    }
    @discardableResult public func rateComfort(_ comfort: Int) -> Bool {
        guard let trial = current, let elapsed = pendingMilliseconds,
              let measurement = ErgonomicMeasurement(trial: trial, elapsedMilliseconds: elapsed,
                                                       corrections: corrections, comfort: comfort) else { return false }
        measurements.append(measurement); index += 1
        pendingMilliseconds = nil; started = nil; corrections = 0; resetRoute()
        return true
    }
    public func retry() {
        if started != nil { corrections += 1 }
        pendingMilliseconds = nil; resetRoute()
    }
    /// Focus loss cannot produce a successful trial; discard its timing as well as its chord.
    public func interrupt() {
        pendingMilliseconds = nil; started = nil; corrections = 0; resetRoute()
    }
}
