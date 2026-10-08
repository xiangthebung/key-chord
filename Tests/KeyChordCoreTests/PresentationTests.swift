import Foundation
import Testing
@testable import KeyChordCore

@Suite("Shared presentation contract")
struct PresentationTests {
    private func resource(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Resources/\(name).json"))) as? [String: Any])
    }
    private func source() throws -> [String: Any] { try resource("presentation") }
    private func stage(_ id: String) -> FirstChordStage {
        ["see": .see, "try": .tryIt, "undo": .recover, "recall": .recall, "finished": .finished][id]!
    }
    private func recovery(_ id: String) -> FirstChordJourney.Recovery {
        ["mistake": .makeMistake, "undo": .undoMistake, "repair": .repair][id]!
    }

    @Test
    func testEveryViewAndTransitionMatchesDeclarativeSource() throws {
        let spec = try source()
        let flow = try #require(spec["firstChord"] as? [String: Any])
        let stages = try #require(flow["stages"] as? [String: [String: Any]])
        let recoveries = try #require(flow["recovery"] as? [String: [String: Any]])
        let demo = try #require(flow["demonstration"] as? [[String: Any]])
        let states = try #require(flow["states"] as? [[String: Any]])
        #expect(KeyChordPresentation.guidedWords == (flow["guidedWords"] as? [String]))
        #expect(KeyChordPresentation.recallWords == (flow["recallWords"] as? [String]))
        #expect(KeyChordPresentation.stageOrder == (flow["stageOrder"] as? [String]))
        for state in states {
            let id = state["id"] as! String
            let stageID = state["stage"] as! String
            let nativeStage = stage(stageID)
            let index = state["wordIndex"] as! Int
            let nativeRecovery = recovery(state["recovery"] as! String)
            let actualState = KeyChordPresentation.firstChordState(stage: nativeStage, wordIndex: index, recovery: nativeRecovery)
            #expect(actualState.id == (id))
            #expect(actualState.target == (state["target"] as? String))
            #expect(actualState.completion == (state["completion"] as? String))
            let next = KeyChordPresentation.nextFirstChordState(stage: nativeStage, wordIndex: index, recovery: nativeRecovery)
            #expect(next?.id == (state["next"] as? String))
            var content = stages[stageID]!
            if stageID == "undo" { content.merge(recoveries[state["recovery"] as! String]!) { _, new in new } }
            if stageID == "see" { content.merge(demo[0]) { _, new in new } }
            for reveal in [false, true] {
                let view = KeyChordPresentation.firstChord(stage: nativeStage, wordIndex: index,
                    recovery: nativeRecovery, hintRevealed: reveal)
                let target = state["target"] as? String
                #expect(view.stageID == (stageID))
                #expect(view.label == (content["label"] as? String))
                #expect(view.title == ((content["title"] as! String).replacingOccurrences(of: "{word}", with: target ?? "")))
                #expect(view.target == (target))
                #expect(view.instruction == (content["instruction"] as? String))
                #expect(view.primaryAction == (content["primaryAction"] as? String))
                #expect(view.placeholder == (content["placeholder"] as? String ?? flow["placeholder"] as! String))
                #expect(view.hintsVisible == ((content["hintsVisible"] as! Bool) || reveal))
                #expect(view.physicalReleaseRequired == (content["physicalReleaseRequired"] as? Bool))
                #expect(view.nextStageID == (content["nextStageID"] as? String))
            }
        }
    }

    @Test
    func testDemonstrationCommitsOnlyAfterFinalRelease() throws {
        let flow = try #require(try source()["firstChord"] as? [String: Any])
        let phases = try #require(flow["demonstration"] as? [[String: Any]])
        #expect(KeyChordPresentation.firstChordDemonstrationCount == (phases.count))
        for (index, expected) in phases.enumerated() {
            let phase = KeyChordPresentation.firstChordDemonstration(step: index)
            let view = KeyChordPresentation.firstChord(stage: .see, demonstrationIndex: index)
            #expect(phase.id == (expected["id"] as? String))
            #expect(phase.held == (expected["held"] as? String))
            #expect(phase.output == (expected["output"] as? String))
            #expect(view.instruction == (phase.instruction))
            #expect(view.primaryAction == (phase.primaryAction))
            #expect(view.primaryActionID == (index == phases.count - 1 ? "start" : "demonstrate"))
            #expect(view.placeholder == (""))
            if index < phases.count - 1 { #expect(phase.output == nil) }
        }
    }

    @Test
    func testJourneyUsesTheSameOrderedCompletionContract() throws {
        let flow = try #require(try source()["firstChord"] as? [String: Any])
        let states = try #require(flow["states"] as? [[String: Any]])
        var journey = FirstChordJourney()
        journey.startTrying()
        for expected in states.dropFirst().dropLast() {
            let current = KeyChordPresentation.firstChordState(stage: journey.stage,
                wordIndex: journey.wordIndex, recovery: journey.recovery)
            #expect(current.id == (expected["id"] as? String))
            #expect(journey.target == (current.target))
            let undo = current.completion == "physicalUndo"
            let actions: [OutputAction] = undo ? [.deleteBackward(3)] : [.insert(current.target!)]
            let attempt = LocalChordAttempt(keys: KeySet(), actions: actions, signal: nil, wasUndo: undo)
            let accepted = journey.observe(attempt, resultingText: current.target ?? "")
            #expect(accepted)
        }
        #expect(journey.stage == (.finished))
        #expect(journey.target == nil)
        #expect(KeyChordPresentation.nextFirstChordState(stage: journey.stage) == nil)
    }

    @Test
    func testLessonPresentationMatchesSource() throws {
        let lessons = try #require(try source()["lessons"] as? [String: [String: String]])
        for stage in LearningStage.allCases {
            let id = stage == .tryIt ? "try" : stage.rawValue
            let view = KeyChordPresentation.lesson(stage: stage)
            #expect(view.title == (lessons[id]?["title"]))
            #expect(view.instruction == (lessons[id]?["instruction"]))
            #expect(view.primaryAction == (lessons[id]?["primaryAction"]))
        }
    }

    @Test
    func testNativeVisualValuesMatchTheSamePaletteAndExerciseMetrics() throws {
        let design = try resource("design-system")
        let palette = try #require(design["palette"] as? [String: [String: String]])
        let roles = try #require(design["rolePalette"] as? [String: [String: String]])
        let metrics = try #require(design["metrics"] as? [String: Double])
        #expect(DesignSystem.Palette.light == palette["light"])
        #expect(DesignSystem.Palette.dark == palette["dark"])
        #expect(DesignSystem.RolePalette.light == roles["light"])
        #expect(DesignSystem.RolePalette.dark == roles["dark"])
        #expect(DesignSystem.Metrics.exerciseWidth == metrics["exerciseWidth"])
        #expect(DesignSystem.Metrics.keyboardWidth == metrics["keyboardWidth"])
        #expect(DesignSystem.Metrics.contentWidth == metrics["contentWidth"])
        #expect(DesignSystem.Metrics.actionHeight == metrics["actionHeight"])
        #expect(DesignSystem.Metrics.radius == metrics["radius"])
        #expect(DesignSystem.Palette.light["key"] != DesignSystem.Palette.light["guide"])
        #expect(DesignSystem.Palette.dark["key"] != DesignSystem.Palette.dark["guide"])
    }
}
