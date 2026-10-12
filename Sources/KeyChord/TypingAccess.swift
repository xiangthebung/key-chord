import Foundation

/// Practice works locally from the first launch. Global typing remains an explicit choice.
final class TypingAccessStore {
    private let defaults: UserDefaults
    private let prefix = "typingAccess.v1."
    let showPracticeAtLaunch: Bool

    init(defaults: UserDefaults = .standard, hasExistingDataFiles: Bool = false) {
        self.defaults = defaults
        let initialized = defaults.bool(forKey: prefix + "initialized")
        let oldPrefix = "learningJourney.v1."
        let oldInitialized = defaults.object(forKey: oldPrefix + "initialized") != nil
        let legacyKeys = ["lastSubMode", "tapTimeoutMs", "rolloverLimit", "keyboard", "overlayVisible",
                          "courseCompleted", "courseLastStep", "chordPracticePerformance.v1"]
        let legacy = defaults.bool(forKey: oldPrefix + "legacy")
            || (!oldInitialized && (hasExistingDataFiles || legacyKeys.contains { defaults.object(forKey: $0) != nil }))
        if !initialized {
            defaults.set(legacy || defaults.bool(forKey: oldPrefix + "otherAppsChosen"),
                         forKey: prefix + "otherAppsChosen")
            defaults.set(true, forKey: prefix + "initialized")
        }
        showPracticeAtLaunch = !initialized && !legacy && !defaults.bool(forKey: oldPrefix + "dismissed")
    }

    var permitsGlobalTyping: Bool { defaults.bool(forKey: prefix + "otherAppsChosen") }
    func chooseOtherApps() { defaults.set(true, forKey: prefix + "otherAppsChosen") }
}
