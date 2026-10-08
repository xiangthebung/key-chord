import Testing
@testable import KeyChordCore

@Suite("Opt-in user-local ergonomic experiments")
struct ErgonomicExperimentTests {
    let identity = HardwareIdentity(keyboard: "Explicit test keyboard", profile: "English model profile", model: "test")
    @Test("Candidates pass both predictions, preserve mappings and require explicit English opt-in")
    func candidateConstraints() throws {
        let originalEnglish = defaults.english.entries, originalCpp = defaults.cpp.entries
        #expect(ErgonomicExperiment.isolatedData(data: defaults, optedIn: false) == nil)
        #expect(ErgonomicExperiment.isolatedData(data: defaults, optedIn: true, mode: .cpp) == nil)
        for text in DefaultData.bundledWirings {
            let wiring = try KeyboardWiring.parse(text, layout: defaults.layout)
            let limits = KeyboardLimits(wiring: wiring)
            let local = try #require(ErgonomicExperiment.isolatedData(data: defaults, optedIn: true, limits: limits))
            for candidate in ErgonomicCandidate.proposals {
                #expect(ErgonomicExperiment.compatibility(candidate, data: defaults, limits: limits).allowed)
                let chord = try #require(defaults.layout.keySet(names: candidate.keys))
                #expect(ChordReading(chord, data: defaults, mode: .english).outcome == .nothing)
                #expect(ChordReading(chord, data: local, mode: .english).outcome == .text(candidate.word))
                #expect(!limits.blocks(chord.indices.map { defaults.layout.keys[$0].code }))
            }
            #expect(local.cpp.entries == originalCpp)
            let cpp = Driver(.cpp, data: local)
            try cpp.chord("Quote+U+S"); #expect(cpp.text == "using")
        }
        #expect(defaults.english.entries == originalEnglish && defaults.cpp.entries == originalCpp)
    }
    @Test("Existing meaning, key limit, failed observed combination and C++ mode exclude candidates")
    func incompatible() throws {
        let candidate = ErgonomicCandidate.proposals[0]
        #expect(!ErgonomicExperiment.compatibility(candidate, data: defaults, mode: .cpp).allowed)
        #expect(!ErgonomicExperiment.compatibility(candidate, data: defaults, rolloverLimit: 2).allowed)
        var changed = defaults
        changed.shared.entries[keys("Quote+U+S")] = .text(TextEntry(text: "occupied"))
        #expect(!ErgonomicExperiment.compatibility(candidate, data: changed).allowed)
        let scan = "version 1\ncombo Quote+U+S fail missing U\n"
        let limits = try #require(KeyboardLimits(scanText: scan, layout: defaults.layout))
        #expect(!ErgonomicExperiment.compatibility(candidate, data: defaults, limits: limits).allowed)
        let schedule = ErgonomicExperiment.trials(data: defaults, limits: limits, optedIn: true)
        #expect(!schedule.contains { $0.word == "use" })
    }
    @Test("Routes replay exact fresh/after-word output; order alternates and model counts are not time evidence")
    func schedule() throws {
        let wiring = try KeyboardWiring.parse(DefaultData.wiringMacBookPro18, layout: defaults.layout)
        let limits = KeyboardLimits(wiring: wiring)
        #expect(ErgonomicExperiment.trials(data: defaults, limits: limits, optedIn: false).isEmpty)
        let schedule = ErgonomicExperiment.trials(data: defaults, limits: limits, optedIn: true)
        #expect(schedule.count == 16)
        #expect(schedule[0].route == .current && schedule[1].route == .proposed)
        #expect(schedule[8].route == .proposed && schedule[9].route == .current)
        let useCurrent = try #require(schedule.first { $0.word == "use" && $0.route == .current && $0.context == .fresh })
        let useProposed = try #require(schedule.first { $0.word == "use" && $0.route == .proposed && $0.context == .fresh })
        #expect(useCurrent.steps.count == 2 && useCurrent.keyActivations == 4)
        #expect(useProposed.steps.count == 1 && useProposed.keyActivations == 3)
        let local = try #require(ErgonomicExperiment.isolatedData(data: defaults, optedIn: true, limits: limits))
        let session = ErgonomicTrialSession(data: local, trials: schedule)
        var timestamp: Int64 = 100
        for trial in schedule {
            for step in trial.steps {
                guard case let .chord(names, shift) = step.action else { Issue.record("unexpected normal step"); return }
                let codes = names.map { local.layout.keys[local.layout.indexByName[$0]!].code }
                for code in codes { session.keyDown(code, timestamp: timestamp, shift: shift) }
                timestamp += 100
                for code in codes { session.keyUp(code, timestamp: timestamp) }
            }
            #expect(session.pendingMilliseconds != nil)
            #expect(session.rateComfort(3)); timestamp += 200
        }
        #expect(session.measurements.count == 16 && session.current == nil)
    }
    @Test("An unavailable baseline does not create an unpaired comparison")
    func noBaseline() {
        let layout = Layout(keys: defaults.layout.keys,
                            clusters: [.onset: [keys("S"): "s"], .vowel: [keys("C"): "a"], .coda: [keys("J"): "t"]],
                            fingerspelling: [:])
        let sparse = EngineData(layout: layout, shared: ChordDictionary(), english: ChordDictionary(),
                                cpp: defaults.cpp, orthographyExceptions: [:])
        #expect(ErgonomicExperiment.compatibility(ErgonomicCandidate.proposals[0], data: sparse).allowed)
        #expect(ErgonomicExperiment.trials(data: sparse, limits: nil, optedIn: true).isEmpty)
    }
    @Test("Non-target release, repeat, wrong keys, invalid comfort and focus interruption cannot earn a trial")
    func eventCredit() throws {
        let local = try #require(ErgonomicExperiment.isolatedData(data: defaults, optedIn: true))
        let trial = try #require(ErgonomicExperiment.trials(data: defaults, limits: nil, optedIn: true).first {
            $0.word == "you" && $0.route == .proposed && $0.context == .fresh
        })
        let session = ErgonomicTrialSession(data: local, trials: [trial])
        let codes = keys("Quote+Y+O").indices.map { local.layout.keys[$0].code }
        #expect(!session.keyUp(codes[0], timestamp: 100))
        for code in codes { session.keyDown(code, timestamp: 100, isRepeat: true) }
        for code in codes { session.keyUp(code, timestamp: 200) }
        #expect(session.pendingMilliseconds == nil)
        session.keyDown(999, timestamp: 300); session.keyUp(999, timestamp: 400)
        #expect(session.corrections == 1 && session.pendingMilliseconds == nil)
        for code in codes { session.keyDown(code, timestamp: 500) }
        for code in codes { session.keyUp(code, timestamp: 700) }
        #expect(session.pendingMilliseconds == 400)
        #expect(!session.rateComfort(0) && !session.rateComfort(6))
        session.interrupt(); #expect(session.pendingMilliseconds == nil && session.measurements.isEmpty)
        for code in codes { session.keyDown(code, timestamp: 800) }
        for code in codes { session.keyUp(code, timestamp: 1000) }
        #expect(session.rateComfort(4))
        #expect(session.measurements[0].elapsedMilliseconds == 200)
    }
    @Test("No human data means no measured speed/comfort or inferred winner")
    func honestSummary() {
        let summary = ErgonomicSummary(word: "use", route: .proposed, measurements: [])
        #expect(summary.attempts == 0 && summary.meanComfort == nil && summary.meanMilliseconds == nil)
        let report = ErgonomicExperiment.report(identity: identity, measurements: [])
        #expect(report.contains("No human measurements") && report.contains("unmeasured"))
        #expect(report.contains("no automatic winner"))
        #expect(report.contains(identity.keyboard) && report.contains(identity.profile))
    }
}
