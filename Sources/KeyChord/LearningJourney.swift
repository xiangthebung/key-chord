import Foundation
import KeyChordCore

/// Only stage names and opt-in/self-report flags are persisted. No text, key events, or attempt
/// history is written. Disposable UserDefaults can be injected by native checks and previews.
final class LearningJourneyStore {
    private let defaults: UserDefaults
    private let prefix = "learningJourney.v1."
    let launch: OnboardingLaunch

    init(defaults: UserDefaults = .standard, hasExistingDataFiles: Bool = false) {
        self.defaults = defaults
        let legacyKeys = ["lastSubMode", "tapTimeoutMs", "rolloverLimit", "keyboard", "overlayVisible",
                          "courseCompleted", "courseLastStep", "courseUnassisted.v1", "chordPracticePerformance.v1",
                          "recallPractice", "practiceReferenceVisible", "keyLabelStyle"]
        let legacy = defaults.bool(forKey: prefix + "legacy")
            || (defaults.object(forKey: prefix + "initialized") == nil
                && (hasExistingDataFiles || legacyKeys.contains { defaults.object(forKey: $0) != nil }))
        let stage = defaults.string(forKey: prefix + "stage").flatMap(FirstChordStage.init(rawValue:))
        launch = .decide(savedStage: stage, dismissed: defaults.bool(forKey: prefix + "dismissed"),
                         legacyInstallation: legacy)
        defaults.set(true, forKey: prefix + "initialized")
        defaults.set(legacy, forKey: prefix + "legacy")
    }

    var permitsGlobalTyping: Bool {
        defaults.bool(forKey: prefix + "legacy") || defaults.bool(forKey: prefix + "otherAppsChosen")
    }
    var editorPracticeReported: Bool { defaults.bool(forKey: prefix + "editorPracticeReported") }
    func save(stage: FirstChordStage) { defaults.set(stage.rawValue, forKey: prefix + "stage") }
    func dismiss() { defaults.set(true, forKey: prefix + "dismissed") }
    func chooseOtherApps() { defaults.set(true, forKey: prefix + "otherAppsChosen") }
    func reportEditorPractice() { defaults.set(true, forKey: prefix + "editorPracticeReported") }
}
